import Foundation

public enum NoteEvent: Sendable {
    case carrier(on: Bool, mode: String)
    case sync(mode: String)
    case header(mode: String, length: Int, flags: Int, seconds: Double)
    case progress(mode: String, fraction: Double)
    /// ok == false: why is "crc" (arrived damaged) or "header" (lost the frame start)
    case frame(ok: Bool, why: String, mode: String, flags: Int, bytes: [UInt8]?, quality: Double)
}

/// One mode's demodulator + frame state machine at `NoteModem.decoderRate`. A straight port of the web decoder.
final class Demod {
    enum State { case search, sync, pay }
    let m: NoteMode
    let emit: (NoteEvent) -> Void
    let T: Int, Ns: Int, B: Int, H: Int, W: Int
    // sliding DFT per tone
    let cw: UnsafeMutablePointer<Double>, sw: UnsafeMutablePointer<Double>
    let pc: UnsafeMutablePointer<Double>, ps: UnsafeMutablePointer<Double>
    let zr: UnsafeMutablePointer<Double>, zi: UnsafeMutablePointer<Double>
    let sr: UnsafeMutablePointer<Double>, si: UnsafeMutablePointer<Double>
    let E: UnsafeMutablePointer<Float>          // energy history ring, T × H
    // preamble correlator rings
    let rr: UnsafeMutablePointer<Double>, ri: UnsafeMutablePointer<Double>, rc: UnsafeMutablePointer<Double>, rb: UnsafeMutablePointer<Double>
    var Cr = 0.0, Ci = 0.0, Cc = 0.0, Cb = 0.0
    var nf = 1e-9
    var state = State.search
    var hold = 0
    // tracking
    var tau = 0.0, per = 0.0, wide = true
    var symCount = 0
    var hist: [[Float]] = []
    var cand: (s: Double, end: Int)? = nil
    var soft: [Double] = []
    var flags = 0, len = 0, need = 0, idx = 0

    init(_ m: NoteMode, emit: @escaping (NoteEvent) -> Void) {
        self.m = m; self.emit = emit
        T = m.tones.count; Ns = m.samplesPerSymbol
        B = m.bps == 1 ? 24 : 16
        H = (B + 5) * Ns
        W = 16 * Ns
        func buf<P>(_ n: Int, _ v: P) -> UnsafeMutablePointer<P> { let p = UnsafeMutablePointer<P>.allocate(capacity: n); p.initialize(repeating: v, count: n); return p }
        cw = buf(T, 0); sw = buf(T, 0)
        for k in 0..<T { cw[k] = cos(2 * Double.pi * m.tones[k] / NoteModem.decoderRate); sw[k] = sin(2 * Double.pi * m.tones[k] / NoteModem.decoderRate) }
        pc = buf(T, 1); ps = buf(T, 0)
        zr = buf(T * Ns, 0); zi = buf(T * Ns, 0); sr = buf(T, 0); si = buf(T, 0)
        E = buf(T * H, Float(0))
        rr = buf(W, 0); ri = buf(W, 0); rc = buf(W, 0); rb = buf(W, 0)
    }
    deinit {
        for p in [cw, sw, pc, ps, zr, zi, sr, si, rr, ri, rc, rb] { p.deallocate() }
        E.deallocate()
    }

    @inline(__always) func energy(_ k: Int, _ n: Int) -> Float { E[k * H + (n % H)] }

    func sample(_ x: Double, _ n: Int) {
        let slot = n % Ns, h = n % H
        var tot = 0.0
        let inv = 1.0 / Double(Ns * Ns)
        for k in 0..<T {
            let c = pc[k], s = ps[k]
            let zrv = x * c, ziv = -x * s, o = k * Ns + slot
            sr[k] += zrv - zr[o]; si[k] += ziv - zi[o]; zr[o] = zrv; zi[o] = ziv
            pc[k] = c * cw[k] - s * sw[k]; ps[k] = s * cw[k] + c * sw[k]
            let e = (sr[k] * sr[k] + si[k] * si[k]) * inv
            E[k * H + h] = Float(e); tot += e
        }
        if (n & 1023) == 1023 { renorm() }
        if n < Ns { return }
        if n == Ns { nf = tot + 1e-14 }
        if tot < nf { nf += (tot - nf) * 0.05 } else { nf *= 1.0001 }
        if nf < 1e-14 { nf = 1e-14 }
        if state == .search { acquire(n, tot) } else { track(n) }
    }

    func renorm() {
        for k in 0..<T {
            let g = 1 / (pc[k] * pc[k] + ps[k] * ps[k]).squareRoot(); pc[k] *= g; ps[k] *= g
            var a = 0.0, b = 0.0
            for i in 0..<Ns { a += zr[k * Ns + i]; b += zi[k * Ns + i] }
            sr[k] = a; si[k] = b
        }
    }

    // ---- preamble acquisition: the two preamble tones alternate at the symbol rate
    func acquire(_ n: Int, _ tot: Double) {
        let a = Double(energy(m.preamble[0], n)), b = Double(energy(m.preamble[1], n))
        let r = (a - b) / (a + b + 0.5 * (tot - a - b) + 1e-20)
        let ang = Double.pi * Double(n % (2 * Ns)) / Double(Ns), w = n % W
        let vr = r * cos(ang), vi = -r * sin(ang)
        let conc = (a + b) / (tot + 1e-20), bal = a / (a + b + 1e-20)
        Cr += vr - rr[w]; Ci += vi - ri[w]; Cc += conc - rc[w]; Cb += bal - rb[w]
        rr[w] = vr; ri[w] = vi; rc[w] = conc; rb[w] = bal
        let rho = (Cr * Cr + Ci * Ci).squareRoot() / Double(W), cm = Cc / Double(W), bm = Cb / Double(W)
        let ok = bm > 0.04 && bm < 0.96 && (cm > 0.7 || (cm > 0.33 && rho > 0.09))
        if ok { hold += 1; if hold >= 2 * Ns { lock(n) } } else { hold = 0 }
    }

    func lock(_ n: Int) {
        let twoNs = Double(2 * Ns)
        var c = -atan2(Ci, Cr) * Double(Ns) / Double.pi
        c = (c.truncatingRemainder(dividingBy: twoNs) + twoNs).truncatingRemainder(dividingBy: twoNs)
        var t = Double(n - (n % (2 * Ns))) + c
        while t <= Double(n) { t += Double(Ns) }
        tau = t; per = Double(Ns); wide = true; state = .sync; symCount = 0; hist = []; cand = nil; hold = 0
        emit(.carrier(on: true, mode: m.key))
    }

    func reset(_ reason: String) {
        state = .search; Cr = 0; Ci = 0; Cc = 0; Cb = 0
        rr.update(repeating: 0, count: W); ri.update(repeating: 0, count: W); rc.update(repeating: 0, count: W); rb.update(repeating: 0, count: W)
        hold = 0
        emit(.carrier(on: false, mode: m.key))
    }

    @inline(__always) func jsRound(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }

    // ---- symbol timing: block tracker (pick the offset within ±Ns/4 maximising each symbol's peak share)
    func track(_ n: Int) {
        let D = wide ? Ns >> 1 : Ns >> 2
        if Double(n) < (tau + Double(B - 1) * per).rounded(.up) + Double(D) { return }
        let first = wide; wide = false
        var best = -1.0, bd = 0
        var sc: [Double] = []
        for d in -D...D {
            var s = 0.0
            for i in 0..<B {
                let t = jsRound(tau + Double(i) * per) + d
                var mx: Float = 0, tot: Float = 0
                for k in 0..<T { let e = energy(k, t); tot += e; if e > mx { mx = e } }
                s += Double(mx) / (Double(tot) + 1e-20)
            }
            sc.append(s)
            if s > best { best = s; bd = d }
        }
        let k0 = bd + D
        var frac = 0.0
        if k0 > 0 && k0 < sc.count - 1 {
            let a = sc[k0 - 1], b = sc[k0], c = sc[k0 + 1], den = a - 2 * b + c
            if den < 0 { frac = max(-0.5, min(0.5, 0.5 * (a - c) / den)) }
        }
        let off = Double(bd) + frac
        var i = 0
        while i < B && state != .search {
            let t = jsRound(tau + Double(i) * per + off)
            var ev = [Float](repeating: 0, count: T)
            for k in 0..<T { ev[k] = energy(k, t) }
            symbol(ev)
            i += 1
        }
        if state == .search { return }
        if !first {
            let nsd = Double(Ns)
            per = max(nsd * 0.99, min(nsd * 1.01, per + max(-0.002 * nsd, min(0.002 * nsd, 0.35 * off / Double(B)))))
        }
        tau += Double(B) * per + off
    }

    func symbol(_ ev: [Float]) {
        let L = m.sync.count
        symCount += 1
        if state == .sync {
            hist.append(ev)
            if hist.count >= L {
                let at = hist.count - L, s = syncScore(at)
                if s > (cand?.s ?? m.syncThreshold) { cand = (s, hist.count - 1) }
            }
            let hs = NoteModem.symbols(forBits: NoteModem.headerCodedBits, m)
            if let c = cand, hist.count - 1 >= c.end + hs + 2 {
                cand = nil
                var got: (hb: [UInt8], st: Int)? = nil
                for o in [0, -1, 1, -2, 2] {
                    let st = c.end + 1 + o
                    if st < 0 || st + hs > hist.count { continue }
                    if let hb = header(Array(hist[st..<(st + hs)])) { got = (hb, st); break }
                }
                guard let g = got else {
                    hist = []
                    emit(.frame(ok: false, why: "header", mode: m.key, flags: 0, bytes: nil, quality: 0))
                    reset("header"); return
                }
                let rest = Array(hist[(g.st + hs)...]); hist = []
                emit(.sync(mode: m.key))
                startPayload(g.hb)
                for e in rest where state == .pay { data(e) }
                return
            }
            if symCount > m.preambleSymbols + L + hs + 60 { reset("nosync") }
            return
        }
        data(ev)
    }

    /// decode a header from its symbols (soft bits with the hop index after the sync word); nil if it fails
    func header(_ syms: [[Float]]) -> [UInt8]? {
        var s: [Double] = []
        for (i, ev) in syms.enumerated() { softBits(ev, m.sync.count + i, into: &s) }
        let d = Interleaver.deinterleave(Array(s.prefix(NoteModem.headerCodedBits)), columns: NoteModem.interleaveHeader)
        let hb = Bits.toBytes(Whitening.apply(Conv.viterbi(d, bits: NoteModem.headerBytes * 8), seed: NoteModem.seedHeader))
        return Checksum.crc8(hb[0..<3]) == hb[3] && Int(hb[0] >> 4) == NoteModem.frameVersion && Int((hb[0] >> 2) & 3) == m.id ? hb : nil
    }

    func startPayload(_ hb: [UInt8]) {
        flags = Int(hb[0] & 3); len = (Int(hb[1]) << 8) | Int(hb[2]); need = NoteModem.payloadCodedBits(len); soft = []
        idx = m.sync.count + NoteModem.symbols(forBits: NoteModem.headerCodedBits, m)
        emit(.header(mode: m.key, length: len, flags: flags, seconds: NoteModem.frameSeconds(bytes: len, mode: m)))
        state = .pay
    }

    func data(_ ev: [Float]) {
        softBits(ev, idx, into: &soft); idx += 1
        guard state == .pay else { return }
        if (soft.count & 63) < m.bps { emit(.progress(mode: m.key, fraction: min(1, Double(soft.count) / Double(need)))) }
        if soft.count >= need {
            let d = Interleaver.deinterleave(Array(soft.prefix(need)), columns: NoteModem.interleavePayload)
            let body = Bits.toBytes(Whitening.apply(Conv.viterbi(d, bits: (len + 4) * 8), seed: NoteModem.seedPayload))
            let pay = Array(body[0..<len])
            let c = Checksum.crc32(pay)
            let got = (UInt32(body[len]) << 24) | (UInt32(body[len + 1]) << 16) | (UInt32(body[len + 2]) << 8) | UInt32(body[len + 3])
            let ok = got == c
            let q = soft.reduce(0) { $0 + abs($1) } / Double(max(1, soft.count))
            emit(.frame(ok: ok, why: ok ? "" : "crc", mode: m.key, flags: flags, bytes: ok ? pay : nil, quality: q))
            reset("done")
        }
    }

    func syncScore(_ at: Int) -> Double {
        let L = m.sync.count
        var s = 0.0
        if m.bps == 1 {
            var pres = 0.0
            for k in 0..<L {
                let ev = hist[at + k], p = k % m.banks
                let a = Double(ev[p]).squareRoot(), b = Double(ev[p + m.banks]).squareRoot()
                var t = 0.0; for e in ev { t += Double(e) }
                s += (m.sync[k] != 0 ? b - a : a - b) / (a + b + 1e-20)
                pres += Double(ev[p] + ev[p + m.banks]) / (t + 1e-20)
            }
            return pres / Double(L) > 0.4 ? s / Double(L) : 0
        }
        for k in 0..<L {
            let ev = hist[at + k]
            var mx: Float = 0; for e in ev where e > mx { mx = e }
            s += (Double(ev[m.sync[k]]) / (Double(mx) + 1e-20)).squareRoot()
        }
        return s / Double(L)
    }

    /// soft bits from the symbol's tone bank: per bit, strongest tone with bit=1 vs strongest with bit=0 (amplitudes)
    func softBits(_ ev: [Float], _ i: Int, into out: inout [Double]) {
        let p = i % m.banks, nv = 1 << m.bps
        for j in stride(from: m.bps - 1, through: 0, by: -1) {
            var m1 = 0.0, m0 = 0.0
            for g in 0..<nv {
                let a = Double(ev[g * m.banks + p]).squareRoot()
                if (NoteModem.ungray(g) >> j) & 1 == 1 { if a > m1 { m1 = a } } else if a > m0 { m0 = a }
            }
            out.append((m1 - m0) / (m1 + m0 + 1e-20))
        }
    }
}

/// Streaming receiver: push() audio at any rate; listens for all three speeds at once.
public final class NoteDecoder {
    public let sampleRate: Double
    let step: Double
    var acc = 0.0, prev = 0.0, n = 0
    var lp: [Biquad]
    var demods: [Demod] = []
    public var onEvent: (NoteEvent) -> Void

    public init(sampleRate: Double, modes: [NoteMode] = NoteMode.all, onEvent: @escaping (NoteEvent) -> Void = { _ in }) {
        self.sampleRate = sampleRate
        step = sampleRate / NoteModem.decoderRate
        lp = [Biquad.lowpass(4000, q: 0.5412, fs: sampleRate), Biquad.lowpass(4000, q: 1.3066, fs: sampleRate)]
        self.onEvent = onEvent
        demods = modes.map { m in Demod(m) { [weak self] e in self?.onEvent(e) } }
    }

    public func push(_ x: UnsafeBufferPointer<Float>) {
        for v0 in x {
            var v = Double(v0)
            for i in 0..<lp.count { v = lp[i].process(v) }
            acc += 1
            while acc >= step {
                acc -= step
                let fr = 1 - acc
                let y = prev + (v - prev) * fr
                let nn = n; n += 1
                for d in demods { d.sample(y, nn) }
            }
            prev = v
        }
    }
    public func push(_ x: [Float]) { x.withUnsafeBufferPointer { push($0) } }
    /// feed a little silence so a note at the very end of a file completes
    public func flush(seconds: Double = 0.3) { push([Float](repeating: 0, count: Int((seconds * sampleRate).rounded()))) }
    public var busy: Bool { demods.contains { $0.state != .search } }

    /// decode a whole buffer, return the frame events
    public static func decode(_ samples: [Float], sampleRate: Double) -> [NoteEvent] {
        var out: [NoteEvent] = []
        let d = NoteDecoder(sampleRate: sampleRate) { e in if case .frame = e { out.append(e) } }
        var i = 0
        while i < samples.count { let j = min(samples.count, i + 4096); d.push(Array(samples[i..<j])); i = j }
        d.flush(seconds: 0.5)
        return out
    }
}

struct Biquad {
    var b0, b1, b2, a1, a2: Double
    var z1 = 0.0, z2 = 0.0
    static func lowpass(_ f: Double, q: Double, fs: Double) -> Biquad {
        let w = 2 * Double.pi * min(f, fs * 0.45) / fs, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
        let b0 = (1 - c) / 2 / a0
        return Biquad(b0: b0, b1: (1 - c) / a0, b2: b0, a1: -2 * c / a0, a2: (1 - al) / a0)
    }
    @inline(__always) mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
