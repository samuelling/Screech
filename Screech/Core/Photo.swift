// Screech photos — a port of js/notes-photo.js (see PHOTO.md). A tiny baseline-JPEG-style codec sent as one
// modem frame per 16-pixel stripe, so the picture paints in from the top while it arrives.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum PhotoCodec {
    public static let codecVersion: UInt8 = 1
    public static let sizes: [(key: String, name: String, longest: Int)] = [("tiny", "Tiny", 64), ("small", "Small", 96), ("large", "Large", 128)]
    public static let qualities: [(key: String, name: String, q: Int)] = [("low", "Low", 20), ("medium", "Medium", 35), ("high", "High", 55)]
    public static let gapSeconds = 0.15

    static let zz: [Int] = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]
    static let ql: [Int] = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]
    static let qc: [Int] = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99]
        + [Int](repeating: 99, count: 32)
    static func quantTable(_ base: [Int], _ quality: Int) -> [Double] {
        let q = max(1, min(100, quality)), s = q < 50 ? 5000 / q : 200 - 2 * q
        return base.map { Double(max(1, min(255, ($0 * s + 50) / 100))) }
    }
    static let cosT: [Double] = {
        var c = [Double](repeating: 0, count: 64)
        for u in 0..<8 { for x in 0..<8 { c[u * 8 + x] = (u == 0 ? 0.5.squareRoot() : 1) * 0.5 * cos(Double(2 * x + 1) * Double(u) * Double.pi / 16) } }
        return c
    }()
    static func fdct(_ b: inout [Double]) {
        var t = [Double](repeating: 0, count: 64)
        for y in 0..<8 { for u in 0..<8 { var s = 0.0; for x in 0..<8 { s += cosT[u * 8 + x] * b[y * 8 + x] }; t[y * 8 + u] = s } }
        for u in 0..<8 { for v in 0..<8 { var s = 0.0; for y in 0..<8 { s += cosT[v * 8 + y] * t[y * 8 + u] }; b[v * 8 + u] = s } }
    }
    static func idct(_ b: inout [Double]) {
        var t = [Double](repeating: 0, count: 64)
        for v in 0..<8 { for x in 0..<8 { var s = 0.0; for u in 0..<8 { s += cosT[u * 8 + x] * b[v * 8 + u] }; t[v * 8 + x] = s } }
        for x in 0..<8 { for y in 0..<8 { var s = 0.0; for v in 0..<8 { s += cosT[v * 8 + y] * t[v * 8 + x] }; b[y * 8 + x] = s } }
    }

    struct BitWriter {
        var out: [UInt8] = []; var acc = 0, n = 0
        mutating func bit(_ b: Int) { acc = (acc << 1) | b; n += 1; if n == 8 { out.append(UInt8(acc)); acc = 0; n = 0 } }
        mutating func ue(_ v: Int) { let x = v + 1; let len = Int.bitWidth - x.leadingZeroBitCount; for _ in 1..<len { bit(0) }; for i in stride(from: len - 1, through: 0, by: -1) { bit((x >> i) & 1) } }
        mutating func se(_ v: Int) { ue(v > 0 ? 2 * v - 1 : -2 * v) }
        mutating func bytes() -> [UInt8] { if n > 0 { out.append(UInt8((acc << (8 - n)) & 255)); acc = 0; n = 0 }; return out }
    }
    struct BitReader {
        let b: [UInt8]; var p = 0
        struct EOF: Error {}
        mutating func bit() throws -> Int { guard p < b.count * 8 else { throw EOF() }; let v = Int(b[p >> 3] >> (7 - UInt8(p & 7))) & 1; p += 1; return v }
        mutating func ue() throws -> Int { var z = 0; while try bit() == 0 { z += 1; if z > 24 { throw EOF() } }; var x = 1; for _ in 0..<z { x = (x << 1) | (try bit()) }; return x - 1 }
        mutating func se() throws -> Int { let m = try ue(); return m & 1 == 1 ? (m + 1) >> 1 : -(m >> 1) }
    }

    public struct Encoded { public let w: Int, h: Int, quality: Int, gray: Bool; public let bands: [[UInt8]] }

    public static func fitSize(_ w: Int, _ h: Int, longest: Int) -> (w: Int, h: Int) {
        let s = Double(longest) / Double(max(w, h))
        return (max(8, Int((Double(w) * s).rounded())), max(8, Int((Double(h) * s).rounded())))
    }
    static func pad16(_ n: Int) -> Int { (n + 15) / 16 * 16 }

    /// RGBA pixels (already at the size to send) → stripes
    public static func encode(rgba: [UInt8], w: Int, h: Int, quality: Int = 35, gray: Bool = false) -> Encoded {
        let W = pad16(w), H = pad16(h)
        var Y = [Double](repeating: 0, count: W * H), Cb = Y, Cr = Y
        for y in 0..<H { for x in 0..<W {
            let o = (min(h - 1, y) * w + min(w - 1, x)) * 4
            let r = Double(rgba[o]), g = Double(rgba[o + 1]), b = Double(rgba[o + 2]), i = y * W + x
            Y[i] = 0.299 * r + 0.587 * g + 0.114 * b
            Cb[i] = -0.168736 * r - 0.331264 * g + 0.5 * b + 128
            Cr[i] = 0.5 * r - 0.418688 * g - 0.081312 * b + 128
        } }
        let W2 = W / 2, H2 = H / 2
        var cb = [Double](repeating: 0, count: W2 * H2), cr = cb
        for y in 0..<H2 { for x in 0..<W2 {
            let i = 2 * y * W + 2 * x
            cb[y * W2 + x] = (Cb[i] + Cb[i + 1] + Cb[i + W] + Cb[i + W + 1]) / 4
            cr[y * W2 + x] = (Cr[i] + Cr[i + 1] + Cr[i + W] + Cr[i + W + 1]) / 4
        } }
        let tl = quantTable(ql, quality), tc = quantTable(qc, quality)
        var bands: [[UInt8]] = []
        for band in 0..<(H / 16) {
            var bw = BitWriter(); var pred = [0, 0, 0]
            func block(_ plane: [Double], _ pw: Int, _ x0: Int, _ y0: Int, _ q: [Double], _ comp: Int) {
                var b = [Double](repeating: 0, count: 64)
                for y in 0..<8 { for x in 0..<8 { b[y * 8 + x] = plane[(y0 + y) * pw + x0 + x] - 128 } }
                fdct(&b)
                var z = [Int](repeating: 0, count: 64)
                for k in 0..<64 { z[k] = Int((b[zz[k]] / q[zz[k]]).rounded()) }
                bw.se(z[0] - pred[comp]); pred[comp] = z[0]
                var lastK = 0
                for k in stride(from: 63, to: 0, by: -1) where z[k] != 0 { lastK = k; break }
                bw.bit(lastK > 0 ? 1 : 0)
                var run = 0
                if lastK > 0 { for k in 1...lastK {
                    if z[k] == 0 { run += 1; continue }
                    bw.ue(run); bw.ue(abs(z[k]) - 1); bw.bit(z[k] < 0 ? 1 : 0); bw.bit(k == lastK ? 1 : 0); run = 0
                } }
            }
            for m in 0..<(W / 16) {
                let x = m * 16, y = band * 16
                block(Y, W, x, y, tl, 0); block(Y, W, x + 8, y, tl, 0); block(Y, W, x, y + 8, tl, 0); block(Y, W, x + 8, y + 8, tl, 0)
                if !gray { block(cb, W2, m * 8, band * 8, tc, 1); block(cr, W2, m * 8, band * 8, tc, 2) }
            }
            bands.append(bw.bytes())
        }
        return Encoded(w: w, h: h, quality: quality, gray: gray, bands: bands)
    }

    /// decode one stripe into `rgba` (w×h×4); false if the bits don't parse
    @discardableResult
    public static func decodeBand(_ bytes: [UInt8], band: Int, w: Int, h: Int, quality: Int, gray: Bool, into rgba: inout [UInt8]) -> Bool {
        let W = pad16(w), tl = quantTable(ql, quality), tc = quantTable(qc, quality)
        var Yb = [Double](repeating: 0, count: W * 16)
        var cb = [Double](repeating: gray ? 128 : 0, count: W / 2 * 8), cr = cb
        var br = BitReader(b: bytes); var pred = [0, 0, 0]
        func block(_ plane: inout [Double], _ pw: Int, _ x0: Int, _ y0: Int, _ q: [Double], _ comp: Int) throws {
            var z = [Int](repeating: 0, count: 64)
            z[0] = pred[comp] + (try br.se()); pred[comp] = z[0]
            if try br.bit() == 1 {
                var k = 1
                while true {
                    k += try br.ue(); if k > 63 { throw BitReader.EOF() }
                    let mag = try br.ue() + 1
                    z[k] = try br.bit() == 1 ? -mag : mag; k += 1
                    if try br.bit() == 1 { break }
                    if k > 63 { throw BitReader.EOF() }
                }
            }
            var b = [Double](repeating: 0, count: 64)
            for i in 0..<64 { b[zz[i]] = Double(z[i]) * q[zz[i]] }
            idct(&b)
            for y in 0..<8 { for x in 0..<8 { plane[(y0 + y) * pw + x0 + x] = b[y * 8 + x] + 128 } }
        }
        do {
            for m in 0..<(W / 16) {
                let x = m * 16
                try block(&Yb, W, x, 0, tl, 0); try block(&Yb, W, x + 8, 0, tl, 0); try block(&Yb, W, x, 8, tl, 0); try block(&Yb, W, x + 8, 8, tl, 0)
                if !gray { try block(&cb, W / 2, m * 8, 0, tc, 1); try block(&cr, W / 2, m * 8, 0, tc, 2) }
            }
        } catch { return false }
        func clamp(_ v: Double) -> UInt8 { v < 0 ? 0 : v > 255 ? 255 : UInt8(v.rounded()) }
        for y in 0..<16 {
            let py = band * 16 + y; if py >= h { break }
            for x in 0..<w {
                let Yv = Yb[y * W + x], c = (y >> 1) * (W / 2) + (x >> 1), u = cb[c] - 128, v = cr[c] - 128, o = (py * w + x) * 4
                rgba[o] = clamp(Yv + 1.402 * v); rgba[o + 1] = clamp(Yv - 0.344136 * u - 0.714136 * v); rgba[o + 2] = clamp(Yv + 1.772 * u); rgba[o + 3] = 255
            }
        }
        return true
    }

    /// a lost stripe: smear the row above it down, with a little static
    public static func smearBand(_ band: Int, w: Int, h: Int, into rgba: inout [UInt8], seed: UInt32) {
        var s = seed == 0 ? 1 : seed
        func rnd() -> Double { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return Double(s) / 4294967296 }
        let src = band * 16 - 1
        for y in 0..<16 {
            let py = band * 16 + y; if py >= h { break }
            for x in 0..<w {
                let o = (py * w + x) * 4, so = (max(0, src) * w + min(w - 1, x + (y >> 2))) * 4, n = (rnd() - 0.5) * 60
                for c in 0..<3 { rgba[o + c] = UInt8(max(0, min(255, (src >= 0 ? Double(rgba[so + c]) : 96) + n))) }
                rgba[o + 3] = 255
            }
        }
    }
}

// MARK: - packets

public struct PhotoFrame { public let payload: [UInt8]; public let flags: Int; public let isHeader: Bool; public let index: Int }

public enum PhotoPacker {
    static func nonce(_ prefix: ArraySlice<UInt8>, _ i: Int) -> [UInt8] { Array(prefix) + [UInt8((i >> 24) & 255), UInt8((i >> 16) & 255), UInt8((i >> 8) & 255), UInt8(i & 255)] }
    static func aad(_ header: [UInt8], _ i: Int) -> [UInt8] { header + [UInt8(i)] }

    /// header · every stripe · header again
    public static func pack(_ img: PhotoCodec.Encoded, passphrase: String) throws -> (id: Int, frames: [PhotoFrame]) {
        precondition(img.bands.count <= 255)
        var rng = SystemRandomNumberGenerator()
        let id = Int(UInt16.random(in: 0...UInt16.max, using: &rng))
        var hdr: [UInt8] = [0, UInt8(id >> 8), UInt8(id & 255), PhotoCodec.codecVersion, UInt8(img.w >> 8), UInt8(img.w & 255),
                            UInt8(img.h >> 8), UInt8(img.h & 255), UInt8(img.quality), UInt8(img.bands.count), img.gray ? 1 : 0]
        var key: SymmetricKey? = nil
        if !passphrase.isEmpty {
            let salt = (0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }, prefix = (0..<8).map { _ in UInt8.random(in: 0...255, using: &rng) }
            hdr += salt + prefix
            key = SymmetricKey(data: NoteCrypto.deriveKey(passphrase, salt: salt))
        }
        let flags = key == nil ? 0 : 1
        var frames = [PhotoFrame(payload: hdr, flags: flags, isHeader: true, index: -1)]
        for (i, band) in img.bands.enumerated() {
            var body = band
            if let k = key {
                let box = try AES.GCM.seal(Data(band), using: k, nonce: AES.GCM.Nonce(data: Data(nonce(hdr[27..<35], i))), authenticating: Data(aad(hdr, i)))
                body = Array(box.ciphertext) + Array(box.tag)
            }
            frames.append(PhotoFrame(payload: [1, UInt8(id >> 8), UInt8(id & 255), UInt8(i)] + body, flags: flags, isHeader: false, index: i))
        }
        frames.append(frames[0])
        return (id, frames)
    }

    public static func seconds(_ frames: [PhotoFrame], mode: NoteMode, intro: Bool = false) -> Double {
        frames.reduce(0) { $0 + NoteModem.frameSeconds(bytes: $1.payload.count, mode: mode) + PhotoCodec.gapSeconds } + (intro ? NoteModem.introSeconds : 0)
    }

    /// the whole train as audio, plus when each frame plays (seconds) so the sender can paint along
    public static func render(_ frames: [PhotoFrame], mode: NoteMode, sampleRate fs: Double, amplitude: Double, intro: Bool = false)
        -> (audio: [Float], marks: [(start: Double, end: Double, index: Int)]) {
        var out: [Float] = [], marks: [(start: Double, end: Double, index: Int)] = []
        let gap = [Float](repeating: 0, count: Int((PhotoCodec.gapSeconds * fs).rounded()))
        for (i, f) in frames.enumerated() {
            let a = NoteSynth.render(payload: f.payload, flags: f.flags, mode: mode, sampleRate: fs, amplitude: amplitude,
                                     intro: intro && i == 0, version: NoteModem.photoFrameVersion)
            let t0 = Double(out.count) / fs
            out += a
            marks.append((start: t0, end: Double(out.count) / fs, index: f.index))
            out += gap
        }
        return (out, marks)
    }
}

// MARK: - receiver

/// Synchronous: call from one serial queue (key derivation takes a moment).
public final class PhotoReceiver {
    public enum Status: Equatable { case waiting, receiving, done, locked, wrongPassphrase }
    public final class Photo {
        public let id: Int
        public var w = 0, h = 0, quality = 0, bands = 0, gray = false, encrypted = false, mode = ""
        public var header: [UInt8]? = nil
        public var pending: [Int: [UInt8]] = [:]
        public var got = Set<Int>(), lost = Set<Int>()
        public var status = Status.waiting
        public var next = 0
        public var rgba: [UInt8] = []
        public var done = false
        var key: SymmetricKey? = nil
        init(id: Int) { self.id = id }
    }
    public var passphrase: () -> String
    public private(set) var photos: [Int: Photo] = [:]
    public init(passphrase: @escaping () -> String) { self.passphrase = passphrase }

    @discardableResult
    public func feed(_ bytes: [UInt8], flags: Int, mode: String) -> Photo? {
        guard bytes.count >= 4 else { return nil }
        let kind = bytes[0], id = Int(bytes[1]) << 8 | Int(bytes[2])
        let p = photos[id] ?? { let n = Photo(id: id); photos[id] = n; return n }()
        p.mode = mode; p.encrypted = flags & 1 != 0
        if kind == 0 {
            if p.header != nil { p.done = true; finish(p); return p }
            guard bytes[3] == PhotoCodec.codecVersion, bytes.count >= 11 else { return nil }
            let w = Int(bytes[4]) << 8 | Int(bytes[5]), h = Int(bytes[6]) << 8 | Int(bytes[7])
            guard w > 0, h > 0, w <= 1024, h <= 1024, Int(bytes[9]) == (h + 15) / 16, !p.encrypted || bytes.count >= 35 else { photos[id] = nil; return nil }
            p.header = bytes; p.w = w; p.h = h; p.quality = Int(bytes[8]); p.bands = Int(bytes[9]); p.gray = bytes[10] == 1
            p.rgba = [UInt8](repeating: 0, count: w * h * 4)
            for i in stride(from: 3, to: p.rgba.count, by: 4) { p.rgba[i] = 255 }
            p.status = .receiving
            if p.encrypted { unlock(p) }
            let late = !p.pending.isEmpty
            drain(p)
            if late { p.done = true; finish(p) }
            return p
        }
        guard kind == 1 else { return nil }
        let i = Int(bytes[3]), body = Array(bytes[4...])
        if p.header == nil || (p.encrypted && p.key == nil) { p.pending[i] = body; return p }
        band(p, i, body)
        return p
    }

    /// after the passphrase changes: try locked photos again
    public func retry() -> [Photo] {
        var out: [Photo] = []
        for p in photos.values where p.header != nil && p.encrypted && p.key == nil {
            unlock(p); drain(p); if p.done { finish(p) }; out.append(p)
        }
        return out
    }

    func drain(_ p: Photo) {
        for i in p.pending.keys.sorted() { if let b = p.pending.removeValue(forKey: i) { band(p, i, b) }; if p.encrypted && p.key == nil { break } }
    }
    func unlock(_ p: Photo) {
        let pass = passphrase()
        guard !pass.isEmpty, let h = p.header else { p.status = .locked; return }
        p.key = SymmetricKey(data: NoteCrypto.deriveKey(pass, salt: Array(h[11..<27])))
        p.status = .receiving
    }
    func band(_ p: Photo, _ i: Int, _ body: [UInt8]) {
        guard i < p.bands, !p.got.contains(i), let h = p.header else { return }
        var data = body
        if p.encrypted {
            guard let k = p.key, body.count >= 16 else { p.pending[i] = body; return }
            do {
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(PhotoPacker.nonce(h[27..<35], i))),
                                                ciphertext: Data(body[0..<(body.count - 16)]), tag: Data(body[(body.count - 16)...]))
                data = Array(try AES.GCM.open(box, using: k, authenticating: Data(PhotoPacker.aad(h, i))))
            } catch { p.key = nil; p.status = .wrongPassphrase; p.pending[i] = body; return }
        }
        if p.next < i { for j in p.next..<i where !p.got.contains(j) { p.lost.insert(j); PhotoCodec.smearBand(j, w: p.w, h: p.h, into: &p.rgba, seed: UInt32(p.id * 31 + j)) } }
        if PhotoCodec.decodeBand(data, band: i, w: p.w, h: p.h, quality: p.quality, gray: p.gray, into: &p.rgba) { p.got.insert(i); p.lost.remove(i) }
        else { p.lost.insert(i); PhotoCodec.smearBand(i, w: p.w, h: p.h, into: &p.rgba, seed: UInt32(p.id * 31 + i)) }
        p.next = max(p.next, i + 1)
        p.status = .receiving
    }
    func finish(_ p: Photo) {
        guard p.header != nil, !(p.encrypted && p.key == nil) else { return }
        for j in 0..<p.bands where !p.got.contains(j) && !p.lost.contains(j) { p.lost.insert(j); PhotoCodec.smearBand(j, w: p.w, h: p.h, into: &p.rgba, seed: UInt32(p.id * 31 + j)) }
        p.status = .done
    }
}
