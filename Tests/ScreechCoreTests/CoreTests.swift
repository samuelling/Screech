import XCTest
@testable import ScreechCore

final class CoreTests: XCTestCase {
    func testDeflateRoundTrip() throws {
        for s in ["", "a", "abcabcabcabcabcabc", String(repeating: "hammock ", count: 90), "Café ☕ 🐢 ünïcode"] {
            let z = RawDeflate.compress(Array(s.utf8))
            XCTAssertEqual(try RawDeflate.decompress(z), Array(s.utf8))
        }
    }
    func testCleanRoundTripEveryMode() throws {
        for m in NoteMode.all {
            for pass in ["", "owl"] {
                let text = "Meet at the hammocks at 4 — \(m.name)"
                let (p, f) = try NoteCrypto.pack(text: text, passphrase: pass, modeId: m.id)
                let audio = NoteSynth.render(payload: p, flags: f, mode: m, sampleRate: 48000, amplitude: 0.3, intro: m.id == 2)
                let ev = NoteDecoder.decode(audio, sampleRate: 48000)
                guard case let .frame(true, _, k, fl, b?, _)? = ev.first(where: { if case .frame(true, _, _, _, _, _) = $0 { return true }; return false }) else { XCTFail(m.name); continue }
                XCTAssertEqual(k, m.key)
                XCTAssertEqual(NoteCrypto.unpack(b, flags: fl, passphrase: pass, modeId: m.id), pass.isEmpty ? .open(text) : .secret(text))
            }
        }
    }
    func testNoisyRoomish() throws {
        // a quick sanity check: echo at -8 dB 9 ms, white noise at ~6 dB SNR, 0.4% clock skew
        var g = SystemRandomNumberGenerator()
        for m in NoteMode.all {
            let (p, f) = try NoteCrypto.pack(text: "The shed key is in the blue jar.", passphrase: "", modeId: m.id)
            let a = NoteSynth.render(payload: p, flags: f, mode: m, sampleRate: 16000, amplitude: 0.3)
            let k = 1.004; var b = [Float](repeating: 0, count: Int(Double(a.count) / k) + 8000)
            for i in 0..<(b.count - 8000) { let t = Double(i) * k, j = Int(t), fr = Float(t - Double(j)); b[i + 4000] = a[min(a.count - 1, j)] * (1 - fr) + a[min(a.count - 1, j + 1)] * fr }
            let e = b; for i in 144..<b.count { b[i] += 0.4 * e[i - 144] }
            for i in 0..<b.count { let u = Double.random(in: 0.0001..<1, using: &g), v = Double.random(in: 0..<1, using: &g); b[i] += Float(0.1 * (-2 * log(u)).squareRoot() * cos(2 * .pi * v)) }
            let ok = NoteDecoder.decode(b, sampleRate: 16000).contains { if case .frame(true, _, _, _, _, _) = $0 { return true }; return false }
            XCTAssertTrue(ok, m.name)
        }
    }
}

final class SpectrumTests: XCTestCase {
    func testToneLandsInItsBand() {
        let fs = 48000.0, sp = SpectrumAnalyzer(sampleRate: fs)
        let x = (0..<Int(fs * 0.2)).map { Float(0.3 * sin(2 * Double.pi * 2100 * Double($0) / fs)) }
        let (rows, lvl) = sp.process(x)
        XCTAssertGreaterThan(rows.count, 4)
        let r = rows[3], peak = r.indices.max { r[$0] < r[$1] }!
        let f = 600 + 3000 * Double(peak) / 47
        XCTAssertEqual(f, 2100, accuracy: 70)
        XCTAssertEqual(lvl, Float(10 * log10(0.045)), accuracy: 1)
    }
}
