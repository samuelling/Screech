import Foundation

/// A small Goertzel filter bank for the waterfall and the input meter: `bands` bins from `low` to `high` Hz,
/// one row per `blockSeconds`. Pure Swift so it runs (and is tested) anywhere.
public final class SpectrumAnalyzer {
    public let bands: Int
    let coeff: [Double]
    let blockLen: Int
    var s1: [Double], s2: [Double]
    var count = 0
    var sumSq = 0.0, peak: Float = 0
    var window: [Double]
    var buf: [Double]

    public init(sampleRate fs: Double, bands: Int = 48, low: Double = 600, high: Double = 3600, blockSeconds: Double = 0.03) {
        let L = max(64, Int(fs * blockSeconds))
        self.bands = bands
        blockLen = L
        coeff = (0..<bands).map { i in
            let f = low + (high - low) * Double(i) / Double(bands - 1)
            return 2 * cos(2 * Double.pi * f / fs)
        }
        s1 = [Double](repeating: 0, count: bands); s2 = s1
        window = (0..<L).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(L - 1)) }
        buf = []; buf.reserveCapacity(L)
    }

    /// Feed samples; returns finished rows (0…1 brightness per band) and the latest level in dBFS.
    public func process(_ x: [Float]) -> (rows: [[Float]], levelDb: Float) {
        var rows: [[Float]] = []
        for v in x {
            buf.append(Double(v)); sumSq += Double(v) * Double(v)
            if buf.count == blockLen {
                var row = [Float](repeating: 0, count: bands)
                for b in 0..<bands {
                    var a = 0.0, c = 0.0
                    let k = coeff[b]
                    for i in 0..<blockLen { let s = buf[i] * window[i] + k * a - c; c = a; a = s }
                    let p = a * a + c * c - k * a * c
                    let db = 10 * log10(max(p, 1e-12) / Double(blockLen * blockLen) * 4)
                    row[b] = Float(max(0, min(1, (db + 80) / 70)))     // −80…−10 dB → 0…1
                }
                rows.append(row)
                peak = Float(10 * log10(max(sumSq / Double(blockLen), 1e-12)))
                buf.removeAll(keepingCapacity: true); sumSq = 0
            }
        }
        return (rows, peak)
    }
}
