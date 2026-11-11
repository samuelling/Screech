// Note packing, identical to the web's Secret Notes:
//   optional raw deflate, then (with a passphrase) AES-256-GCM.
//   Encrypted packet = version(1) | salt(16) | iv(12) | ciphertext + 16-byte tag   (45 bytes of overhead)
//   Key = PBKDF2-HMAC-SHA256(NFC passphrase, salt, 200 000 iterations), 256 bits.
//   Additional data = [1, flags & 3, modeId & 3], so the frame header can't be swapped.
// Nothing here logs passphrases or plaintext.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

public enum NoteStatus: Equatable, Sendable {
    case open(String)          // no passphrase on the note: anyone could read it
    case secret(String)        // decrypted with the passphrase
    case locked                // secret note, but no passphrase entered yet
    case wrongPassphrase
    case garbled
}

public enum NoteCrypto {
    public static let version: UInt8 = 1
    public static let iterations = 200_000
    public static let overhead = 45

    public static func pack(text: String, passphrase: String, modeId: Int) throws -> (payload: [UInt8], flags: Int) {
        var data = Array(text.utf8), flags = 0
        let z = RawDeflate.compress(data)
        if z.count + 1 < data.count { data = z; flags |= NoteFlag.deflate }
        if passphrase.isEmpty { return (data, flags) }
        flags |= NoteFlag.encrypted
        var salt = [UInt8](repeating: 0, count: 16), iv = [UInt8](repeating: 0, count: 12)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<16 { salt[i] = rng.next() }
        for i in 0..<12 { iv[i] = rng.next() }
        let key = SymmetricKey(data: deriveKey(passphrase, salt: salt))
        let box = try AES.GCM.seal(Data(data), using: key, nonce: AES.GCM.Nonce(data: Data(iv)), authenticating: Data(aad(flags, modeId)))
        return ([version] + salt + iv + Array(box.ciphertext) + Array(box.tag), flags)
    }

    public static func unpack(_ bytes: [UInt8], flags: Int, passphrase: String, modeId: Int) -> NoteStatus {
        var data = bytes
        let enc = flags & NoteFlag.encrypted != 0
        if enc {
            if passphrase.isEmpty { return .locked }
            guard bytes.count >= 1 + 16 + 12 + 16, bytes[0] == version else { return .wrongPassphrase }
            do {
                let key = SymmetricKey(data: deriveKey(passphrase, salt: Array(bytes[1..<17])))
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(bytes[17..<29])),
                                                ciphertext: Data(bytes[29..<(bytes.count - 16)]), tag: Data(bytes[(bytes.count - 16)...]))
                data = Array(try AES.GCM.open(box, using: key, authenticating: Data(aad(flags, modeId))))
            } catch { return .wrongPassphrase }
        }
        if flags & NoteFlag.deflate != 0 {
            guard let d = try? RawDeflate.decompress(data) else { return enc ? .wrongPassphrase : .garbled }
            data = d
        }
        let text = String(decoding: data, as: UTF8.self)
        return enc ? .secret(text) : .open(text)
    }

    /// bytes on air before compression, for the airtime estimate while typing
    public static func estimateBytes(_ text: String, secret: Bool) -> Int { text.utf8.count + (secret ? overhead : 0) }

    static func aad(_ flags: Int, _ modeId: Int) -> [UInt8] { [1, UInt8(flags & 3), UInt8(modeId & 3)] }

    public static func deriveKey(_ passphrase: String, salt: [UInt8], iterations: Int = iterations) -> [UInt8] {
        let pw = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        #if canImport(CommonCrypto)
        var out = [UInt8](repeating: 0, count: 32)
        let rc = pw.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: Int8.self, capacity: max(1, pw.count)) { pp in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pp, pw.count, salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, 32)
            }
        }
        precondition(rc == kCCSuccess)
        return out
        #else
        // PBKDF2-HMAC-SHA256, one 32-byte block
        let key = SymmetricKey(data: pw)
        var u = Array(HMAC<SHA256>.authenticationCode(for: salt + [0, 0, 0, 1], using: key))
        var t = u
        for _ in 1..<iterations {
            u = Array(HMAC<SHA256>.authenticationCode(for: u, using: key))
            for i in 0..<32 { t[i] ^= u[i] }
        }
        return t
        #endif
    }
}
