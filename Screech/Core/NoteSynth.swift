import Foundation

public enum NoteSynth {
    /// Render a note at sample rate `fs`: continuous-phase tones with a short raised-cosine glide between symbols,
    /// 10 ms fades, peak `amp`. `intro` prepends a fake dial-up handshake flourish (the receiver ignores it).
    public static func render(payload: [UInt8], flags: Int, mode m: NoteMode, sampleRate fs: Double = 48000,
                              amplitude amp: Double = 0.5, intro: Bool = false) -> [Float] {
        let tones = NoteModem.frameSymbols(payload: payload, flags: flags, mode: m).map { m.tones[$0] }
        let introS = intro ? NoteModem.introSeconds : 0, lead = 0.03
        let nSym = tones.count
        let N = Int(((introS + lead + Double(nSym) / Double(m.baud) + 0.03) * fs).rounded(.up))
        var out = [Float](repeating: 0, count: N)
        var n0 = Int((lead * fs).rounded())
        if intro { renderIntro(&out, fs: fs, amp: amp, start: n0); n0 += Int((introS * fs).rounded()) }
        let spS = fs / Double(m.baud), glide = 0.08
        var ph = 0.0
        let nEnd = n0 + Int((Double(nSym) * spS).rounded()), fade = Double(Int((0.01 * fs).rounded()))
        for n in n0..<min(nEnd, N) {
            let t = Double(n - n0) / spS
            let k = min(nSym - 1, Int(t)), fr = t - Double(k)
            var f = tones[k]
            if k > 0 && fr < glide { let w = 0.5 - 0.5 * cos(Double.pi * fr / glide); f = tones[k - 1] + (f - tones[k - 1]) * w }
            ph += 2 * Double.pi * f / fs
            if ph > 2 * Double.pi { ph -= 2 * Double.pi }
            let e = min(1, Double(n - n0) / fade, Double(nEnd - n) / fade)
            out[n] = Float(amp * e * sin(ph))
        }
        return out
    }

    /// answer tone 2100 Hz with a phase reversal, a V.21 "call menu" chirp, a probe chord, then a pause
    static func renderIntro(_ out: inout [Float], fs: Double, amp: Double, start: Int) {
        var n = start
        func put(_ secs: Double, _ fn: (Double, Int) -> Double) {
            let L = Int((secs * fs).rounded())
            for i in 0..<L where n + i < out.count {
                let e = min(1, Double(i) / (0.008 * fs), Double(L - i) / (0.008 * fs))
                out[n + i] += Float(amp * 0.85 * e * fn(Double(i) / fs, i))
            }
            n += L
        }
        put(0.8) { t, _ in sin(2 * Double.pi * 2100 * t + (t > 0.45 ? Double.pi : 0)) * (1 + 0.2 * sin(2 * Double.pi * 15 * t)) }
        n += Int((0.07 * fs).rounded())
        var ph = 0.0
        var seed: UInt32 = 7
        var bits: [Int] = []
        for i in 0..<120 { seed = seed &* 1103515245 &+ 12345; bits.append(i < 10 ? 1 : Int(seed >> 31)) }
        put(0.33) { t, _ in
            let b = bits[min(bits.count - 1, Int(t * 300))]
            ph += 2 * Double.pi * (b != 0 ? 980 : 1180) / fs
            return sin(ph)
        }
        n += Int((0.05 * fs).rounded())
        put(0.28) { t, _ in
            var s = 0.0
            for k in 1...25 where ![6, 8, 12, 16].contains(k) { s += cos(2 * Double.pi * Double(k) * 150 * t + Double(k * k) * 0.7) }
            return s / 7
        }
    }

    /// 16-bit PCM mono WAV
    public static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples.count * 2)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count * 2))
        d.reserveCapacity(d.count + samples.count * 2)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        return d
    }
}
