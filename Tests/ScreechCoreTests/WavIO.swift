import Foundation
@testable import ScreechCore

/// minimal 16-bit PCM mono WAV reader for the fixtures
func readWav(_ url: URL) throws -> (samples: [Float], rate: Double) {
    let d = [UInt8](try Data(contentsOf: url))
    func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
    var p = 12, rate = 0
    while p + 8 <= d.count {
        let id = String(decoding: d[p..<(p + 4)], as: UTF8.self), size = u32(p + 4)
        if id == "fmt " { rate = u32(p + 12) }
        if id == "data" {
            var s = [Float](repeating: 0, count: size / 2)
            for i in 0..<s.count { s[i] = Float(Int16(bitPattern: UInt16(d[p + 8 + 2 * i]) | UInt16(d[p + 9 + 2 * i]) << 8)) / 32768 }
            return (s, Double(rate))
        }
        p += 8 + size
    }
    throw NSError(domain: "wav", code: 1)
}
let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
