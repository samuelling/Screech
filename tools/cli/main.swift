// screech-cli: encode a note to WAV, or decode a WAV (used for the Swift → web compatibility check).
//   screech-cli encode <sturdy|quick|classic> <passphrase|-> <text> <out.wav> [rate] [--intro]
//   screech-cli decode <in.wav> <passphrase|->
import Foundation
import ScreechCore

let a = CommandLine.arguments
func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(2) }
guard a.count >= 2 else { die("usage: encode|decode …") }
if a[1] == "encode", a.count >= 6 {
    guard let m = NoteMode.byKey(a[2]) else { die("bad mode") }
    let pass = a[3] == "-" ? "" : a[3]
    let rate = a.count > 6 ? Int(a[6]) ?? 48000 : 48000
    let (p, f) = try NoteCrypto.pack(text: a[4], passphrase: pass, modeId: m.id)
    let s = NoteSynth.render(payload: p, flags: f, mode: m, sampleRate: Double(rate), amplitude: 0.4, intro: a.contains("--intro"))
    try NoteSynth.wav(s, sampleRate: rate).write(to: URL(fileURLWithPath: a[5]))
    print("wrote \(a[5]) \(p.count) bytes flags \(f)")
} else if a[1] == "decode", a.count >= 4 {
    let d = [UInt8](try Data(contentsOf: URL(fileURLWithPath: a[2])))
    func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
    var p = 12, rate = 48000
    var samples: [Float] = []
    while p + 8 <= d.count {
        let id = String(decoding: d[p..<(p + 4)], as: UTF8.self), size = u32(p + 4)
        if id == "fmt " { rate = u32(p + 12) }
        if id == "data" { samples = (0..<(size / 2)).map { i in Float(Int16(bitPattern: UInt16(d[p + 8 + 2 * i]) | UInt16(d[p + 9 + 2 * i]) << 8)) / 32768 }; break }
        p += 8 + size
    }
    for e in NoteDecoder.decode(samples, sampleRate: Double(rate)) {
        if case let .frame(ok, why, mode, flags, bytes, _) = e {
            if ok, let b = bytes, let m = NoteMode.byKey(mode) {
                switch NoteCrypto.unpack(b, flags: flags, passphrase: a[3] == "-" ? "" : a[3], modeId: m.id) {
                case .open(let t): print("OPEN \(mode): \(t)")
                case .secret(let t): print("SECRET \(mode): \(t)")
                case .locked: print("LOCKED \(mode)")
                case .wrongPassphrase: print("BADPASS \(mode)")
                case .garbled: print("GARBLED \(mode)")
                }
            } else { print("FAIL \(mode) \(why)") }
        }
    }
} else { die("usage") }
