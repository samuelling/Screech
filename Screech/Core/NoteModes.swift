// Screech's over-the-air note modem — the same protocol as RetroSynths' Secret Notes (web), bit for bit.
//
// Three speeds, all built from tones on a 0.9–3.3 kHz grid where phone speakers and mics are comfortable:
//   Sturdy:  MFSK-8 at 75 baud, 3 bits/symbol (Gray-mapped). Consecutive symbols alternate between two interleaved
//            banks of 8 tones (1050–3300 Hz on a 150 Hz grid), so a symbol's echo lands in the other bank.
//   Quick:   the same at 150 baud.
//   Classic: 300 baud binary FSK whose mark/space pair hops over 4 pairs (8 tones 900–3000 Hz) — the modem sound.
// Frame: preamble (two-tone alternation) | sync word | header (version, flags, length, CRC-8) | payload + CRC-32.
// FEC: rate-1/2 K=7 convolutional code (171/133 octal), soft-decision Viterbi, PRBS9 whitening, block interleaving.

import Foundation

public struct NoteMode: Equatable, Sendable, Identifiable {
    public let key: String
    public let id: Int
    public let name: String
    public let baud: Int
    /// samples per symbol at `NoteModem.decoderRate`
    public let samplesPerSymbol: Int
    /// bits per symbol
    public let bps: Int
    /// number of interleaved tone banks (hop period)
    public let banks: Int
    public let tones: [Double]
    public let preamble: [Int]
    public let preambleSymbols: Int
    public let sync: [Int]
    public let syncThreshold: Double
    public let blurb: String

    public static let sturdy = NoteMode(key: "sturdy", id: 2, name: "Sturdy", baud: 75, samplesPerSymbol: 128, bps: 3, banks: 2,
        tones: (0..<16).map { 1050 + Double($0) * 150 }, preamble: [4, 11], preambleSymbols: 38,
        sync: [10, 5, 12, 3, 8, 15, 0, 7], syncThreshold: 0.65, blurb: "slow & sure · chiming tones")
    public static let quick = NoteMode(key: "quick", id: 1, name: "Quick", baud: 150, samplesPerSymbol: 64, bps: 3, banks: 2,
        tones: (0..<16).map { 1050 + Double($0) * 150 }, preamble: [0, 15], preambleSymbols: 75,
        sync: [2, 13, 4, 11, 6, 1, 14, 9], syncThreshold: 0.65, blurb: "twice as fast · needs a quieter room")
    public static let classic = NoteMode(key: "classic", id: 0, name: "Classic", baud: 300, samplesPerSymbol: 32, bps: 1, banks: 4,
        tones: (0..<8).map { 900 + Double($0) * 300 }, preamble: [1, 5], preambleSymbols: 150,
        sync: [0, 1, 0, 0, 1, 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0], syncThreshold: 0.32,
        blurb: "the real modem screech")

    public static let all: [NoteMode] = [.sturdy, .quick, .classic]
    public static func byId(_ id: Int) -> NoteMode? { all.first { $0.id == id } }
    public static func byKey(_ k: String) -> NoteMode? { all.first { $0.key == k } }
}

public enum NoteFlag {
    public static let encrypted = 1
    public static let deflate = 2
}

public enum NoteModem {
    /// the decoder's internal sample rate: 32 samples/symbol at 300 baud
    public static let decoderRate = 9600.0
    public static let frameVersion = 1
    static let headerBytes = 4, postSymbols = 4
    static let seedHeader = 0x1a5, seedPayload = 0x0f3
    static let interleaveHeader = 8, interleavePayload = 24
    public static let introSeconds = 1.75
    public static let maxPayload = 65535

    static var headerCodedBits: Int { (headerBytes * 8 + Conv.K - 1) * 2 }                        // 76
    static func payloadCodedBits(_ n: Int) -> Int { ((n + 4) * 8 + Conv.K - 1) * 2 }
    static func symbols(forBits bits: Int, _ m: NoteMode) -> Int { (bits + m.bps - 1) / m.bps }

    /// frame airtime in seconds (without the optional intro)
    public static func frameSeconds(bytes n: Int, mode m: NoteMode) -> Double {
        let syms = m.preambleSymbols + m.sync.count + symbols(forBits: headerCodedBits, m) + symbols(forBits: payloadCodedBits(n), m) + postSymbols
        return Double(syms) / Double(m.baud) + 0.03
    }

    static func gray(_ v: Int) -> Int { v ^ (v >> 1) }
    static func ungray(_ g: Int) -> Int { var v = g; var s = 1; while s < 8 { v ^= v >> s; s <<= 1 }; return v }
    /// symbol i carries value v: tone = gray(v) * banks + (i mod banks)
    static func mapSymbol(_ m: NoteMode, _ v: Int, _ i: Int) -> Int { gray(v) * m.banks + (i % m.banks) }

    /// tone indices for a whole frame
    public static func frameSymbols(payload: [UInt8], flags: Int, mode m: NoteMode) -> [Int] {
        precondition(payload.count <= maxPayload)
        var hdr: [UInt8] = [UInt8((frameVersion << 4) | ((m.id & 3) << 2) | (flags & 3)), UInt8(payload.count >> 8), UInt8(payload.count & 255), 0]
        hdr[3] = Checksum.crc8(hdr[0..<3])
        let hBits = Interleaver.interleave(Conv.encode(Whitening.apply(Bits.from(hdr), seed: seedHeader)), columns: interleaveHeader)
        let c = Checksum.crc32(payload)
        let body = payload + [UInt8(c >> 24), UInt8((c >> 16) & 255), UInt8((c >> 8) & 255), UInt8(c & 255)]
        let pBits = Interleaver.interleave(Conv.encode(Whitening.apply(Bits.from(body), seed: seedPayload)), columns: interleavePayload)
        var tones: [Int] = []
        tones.reserveCapacity(m.preambleSymbols + 40 + (hBits.count + pBits.count) / m.bps)
        for i in 0..<m.preambleSymbols { tones.append(m.preamble[i & 1]) }
        var idx = 0
        func put(_ bits: [UInt8]) {
            var i = 0
            while i < bits.count {
                var v = 0
                for k in 0..<m.bps { v = (v << 1) | Int(i + k < bits.count ? bits[i + k] : 0) }
                tones.append(mapSymbol(m, v, idx)); idx += 1
                i += m.bps
            }
        }
        if m.bps == 1 { put(m.sync.map { UInt8($0) }) } else { for t in m.sync { tones.append(t); idx += 1 } }
        put(hBits); put(pBits)
        for _ in 0..<postSymbols { tones.append(m.preamble[0]) }
        return tones
    }
}

// MARK: - checksums, bits, whitening

public enum Checksum {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    public static func crc32<S: Sequence>(_ b: S) -> UInt32 where S.Element == UInt8 {
        var c: UInt32 = 0xffffffff
        for x in b { c = table[Int((c ^ UInt32(x)) & 255)] ^ (c >> 8) }
        return c ^ 0xffffffff
    }
    public static func crc8<S: Sequence>(_ b: S) -> UInt8 where S.Element == UInt8 {
        var c: UInt8 = 0
        for x in b { c ^= x; for _ in 0..<8 { c = (c & 0x80) != 0 ? (c << 1) ^ 0x07 : c << 1 } }
        return c
    }
}

enum Bits {
    static func from(_ b: [UInt8]) -> [UInt8] {
        var o = [UInt8](repeating: 0, count: b.count * 8)
        for i in 0..<b.count { for k in 0..<8 { o[i * 8 + k] = (b[i] >> (7 - k)) & 1 } }
        return o
    }
    static func toBytes(_ bits: [UInt8]) -> [UInt8] {
        var o = [UInt8](repeating: 0, count: bits.count >> 3)
        for i in 0..<o.count { var v: UInt8 = 0; for k in 0..<8 { v = (v << 1) | bits[i * 8 + k] }; o[i] = v }
        return o
    }
}

/// PRBS9 (x^9 + x^5 + 1), so long runs of equal bits still make tone transitions
enum Whitening {
    static func apply(_ bits: [UInt8], seed: Int) -> [UInt8] {
        var r = seed & 511
        var o = [UInt8](repeating: 0, count: bits.count)
        for i in 0..<bits.count {
            let b = ((r >> 8) ^ (r >> 4)) & 1
            r = ((r << 1) | b) & 511
            o[i] = bits[i] ^ UInt8(b)
        }
        return o
    }
}

/// block interleaver: write row-wise (C columns), read column-wise
enum Interleaver {
    static func interleave<T>(_ a: [T], columns C: Int) -> [T] {
        let N = a.count, R = (N + C - 1) / C
        var o: [T] = []; o.reserveCapacity(N)
        for c in 0..<C { for r in 0..<R { let i = r * C + c; if i < N { o.append(a[i]) } } }
        return o
    }
    static func deinterleave(_ a: [Double], columns C: Int) -> [Double] {
        let N = a.count, R = (N + C - 1) / C
        var o = [Double](repeating: 0, count: N); var k = 0
        for c in 0..<C { for r in 0..<R { let i = r * C + c; if i < N { o[i] = a[k]; k += 1 } } }
        return o
    }
}

// MARK: - rate-1/2 K=7 convolutional code + soft Viterbi

enum Conv {
    static let K = 7, states = 64
    static let G1 = 0o171, G2 = 0o133
    static let parity: [UInt8] = (0..<128).map { i in var p = 0, x = i; while x != 0 { p ^= x & 1; x >>= 1 }; return UInt8(p) }

    /// terminated with K-1 zero bits
    static func encode(_ bits: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (bits.count + K - 1) * 2)
        var st = 0, j = 0
        for i in 0..<(bits.count + K - 1) {
            let b = i < bits.count ? Int(bits[i]) : 0
            let reg = (b << 6) | st
            out[j] = parity[reg & G1]; out[j + 1] = parity[reg & G2]; j += 2
            st = reg >> 1
        }
        return out
    }

    /// soft[i] in [-1, 1], +1 = coded bit 1. Returns nBits decoded bits (tail removed).
    static func viterbi(_ soft: [Double], bits nBits: Int) -> [UInt8] {
        let steps = nBits + K - 1
        var pm = [Double](repeating: -1e9, count: states); pm[0] = 0
        var nx = [Double](repeating: 0, count: states)
        var dec = [UInt8](repeating: 0, count: steps * states)
        var o1 = [Double](repeating: 0, count: 128), o2 = [Double](repeating: 0, count: 128)
        for r in 0..<128 { o1[r] = parity[r & G1] != 0 ? 1 : -1; o2[r] = parity[r & G2] != 0 ? 1 : -1 }
        for t in 0..<steps {
            let s1 = 2 * t < soft.count ? soft[2 * t] : 0, s2 = 2 * t + 1 < soft.count ? soft[2 * t + 1] : 0
            for ns in 0..<states {
                let r0 = ns << 1, r1 = r0 | 1
                let m0 = pm[r0 & 63] + o1[r0] * s1 + o2[r0] * s2
                let m1 = pm[r1 & 63] + o1[r1] * s1 + o2[r1] * s2
                if m1 > m0 { nx[ns] = m1; dec[t * states + ns] = 1 } else { nx[ns] = m0; dec[t * states + ns] = 0 }
            }
            swap(&pm, &nx)
        }
        var bits = [UInt8](repeating: 0, count: steps)
        var st = 0
        for t in stride(from: steps - 1, through: 0, by: -1) {
            bits[t] = UInt8(st >> 5)
            let reg = (st << 1) | Int(dec[t * states + st])
            st = reg & 63
        }
        return Array(bits[0..<nBits])
    }
}
