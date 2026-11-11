// Raw DEFLATE (RFC 1951), small and dependency-free, matching the web's CompressionStream('deflate-raw').
// The compressor uses fixed Huffman codes + LZ77 (notes are ≤ ~1 KB, so a plain search is plenty);
// the decompressor handles stored, fixed and dynamic blocks, so it reads anything a browser produces.
import Foundation

public enum RawDeflate {
    // MARK: tables
    static let lenBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lenExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let clOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    // MARK: compress
    struct BitWriter {
        var out: [UInt8] = []
        var acc: UInt32 = 0, n = 0
        mutating func bits(_ v: Int, _ count: Int) {           // LSB first
            acc |= UInt32(v) << UInt32(n); n += count
            while n >= 8 { out.append(UInt8(acc & 255)); acc >>= 8; n -= 8 }
        }
        mutating func huff(_ code: Int, _ len: Int) {           // Huffman codes go MSB first
            var r = 0; for i in 0..<len { r |= ((code >> i) & 1) << (len - 1 - i) }
            bits(r, len)
        }
        mutating func finish() -> [UInt8] { if n > 0 { out.append(UInt8(acc & 255)) }; acc = 0; n = 0; return out }
    }
    static func fixedLit(_ w: inout BitWriter, _ v: Int) {
        switch v {
        case 0...143: w.huff(0x30 + v, 8)
        case 144...255: w.huff(0x190 + v - 144, 9)
        case 256...279: w.huff(v - 256, 7)
        default: w.huff(0xC0 + v - 280, 8)
        }
    }
    public static func compress(_ data: [UInt8]) -> [UInt8] {
        var w = BitWriter()
        w.bits(1, 1); w.bits(1, 2)                               // BFINAL, BTYPE = fixed
        var i = 0
        let n = data.count
        while i < n {
            var bestLen = 0, bestDist = 0
            if i + 3 <= n {
                var j = i - 1
                let lo = max(0, i - 32768)
                while j >= lo {
                    if data[j] == data[i] && data[j + 1] == data[i + 1] && data[j + 2] == data[i + 2] {
                        var l = 3
                        while l < 258 && i + l < n && data[j + l] == data[i + l] { l += 1 }
                        if l > bestLen { bestLen = l; bestDist = i - j; if l == 258 { break } }
                    }
                    j -= 1
                }
            }
            if bestLen >= 3 {
                var c = lenBase.count - 1; while lenBase[c] > bestLen { c -= 1 }
                fixedLit(&w, 257 + c); if lenExtra[c] > 0 { w.bits(bestLen - lenBase[c], lenExtra[c]) }
                var d = distBase.count - 1; while distBase[d] > bestDist { d -= 1 }
                w.huff(d, 5); if distExtra[d] > 0 { w.bits(bestDist - distBase[d], distExtra[d]) }
                i += bestLen
            } else {
                fixedLit(&w, Int(data[i])); i += 1
            }
        }
        fixedLit(&w, 256)
        return w.finish()
    }

    // MARK: decompress
    public enum InflateError: Error { case truncated, badBlock, badCode, badDistance, tooBig }
    struct Huff { var counts = [Int](repeating: 0, count: 16); var symbols: [Int] = [] }
    static func build(_ lengths: [Int]) -> Huff {
        var h = Huff()
        for l in lengths { h.counts[l] += 1 }
        h.counts[0] = 0
        var offs = [Int](repeating: 0, count: 16)
        for l in 1..<16 { offs[l] = offs[l - 1] + h.counts[l - 1] }
        h.symbols = [Int](repeating: 0, count: lengths.count)
        var o = offs
        for (s, l) in lengths.enumerated() where l != 0 { h.symbols[o[l]] = s; o[l] += 1 }
        return h
    }
    struct Reader {
        let d: [UInt8]; var pos = 0; var acc: UInt32 = 0; var n = 0
        mutating func bits(_ c: Int) throws -> Int {
            while n < c { guard pos < d.count else { throw InflateError.truncated }; acc |= UInt32(d[pos]) << UInt32(n); pos += 1; n += 8 }
            let v = Int(acc & ((1 << UInt32(c)) - 1)); acc >>= UInt32(c); n -= c; return v
        }
        mutating func decode(_ h: Huff) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try bits(1)
                let count = h.counts[len]
                if code - count < first { return h.symbols[index + (code - first)] }
                index += count; first += count; first <<= 1; code <<= 1
            }
            throw InflateError.badCode
        }
    }
    public static func decompress(_ data: [UInt8], limit: Int = 1 << 20) throws -> [UInt8] {
        var r = Reader(d: data)
        var out: [UInt8] = []
        var final = 0
        let fixedL = build((0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 })
        let fixedD = build([Int](repeating: 5, count: 30))
        repeat {
            final = try r.bits(1)
            let type = try r.bits(2)
            switch type {
            case 0:
                r.acc = 0; r.n = 0
                guard r.pos + 4 <= data.count else { throw InflateError.truncated }
                let len = Int(data[r.pos]) | Int(data[r.pos + 1]) << 8, nlen = Int(data[r.pos + 2]) | Int(data[r.pos + 3]) << 8
                guard len == (~nlen & 0xffff) else { throw InflateError.badBlock }
                r.pos += 4
                guard r.pos + len <= data.count else { throw InflateError.truncated }
                out.append(contentsOf: data[r.pos..<(r.pos + len)]); r.pos += len
            case 1, 2:
                var lit = fixedL, dist = fixedD
                if type == 2 {
                    let hlit = try r.bits(5) + 257, hdist = try r.bits(5) + 1, hclen = try r.bits(4) + 4
                    var cl = [Int](repeating: 0, count: 19)
                    for i in 0..<hclen { cl[clOrder[i]] = try r.bits(3) }
                    let clh = build(cl)
                    var lens: [Int] = []
                    while lens.count < hlit + hdist {
                        let s = try r.decode(clh)
                        switch s {
                        case 0..<16: lens.append(s)
                        case 16: guard let last = lens.last else { throw InflateError.badBlock }; lens += [Int](repeating: last, count: 3 + (try r.bits(2)))
                        case 17: lens += [Int](repeating: 0, count: 3 + (try r.bits(3)))
                        default: lens += [Int](repeating: 0, count: 11 + (try r.bits(7)))
                        }
                    }
                    guard lens.count == hlit + hdist else { throw InflateError.badBlock }
                    lit = build(Array(lens[0..<hlit])); dist = build(Array(lens[hlit...]))
                }
                while true {
                    let s = try r.decode(lit)
                    if s < 256 { out.append(UInt8(s)) }
                    else if s == 256 { break }
                    else {
                        let li = s - 257; guard li < lenBase.count else { throw InflateError.badCode }
                        let l = lenBase[li] + (try r.bits(lenExtra[li]))
                        let di = try r.decode(dist); guard di < distBase.count else { throw InflateError.badCode }
                        let dd = distBase[di] + (try r.bits(distExtra[di]))
                        guard dd <= out.count else { throw InflateError.badDistance }
                        for _ in 0..<l { out.append(out[out.count - dd]) }
                    }
                    if out.count > limit { throw InflateError.tooBig }
                }
            default: throw InflateError.badBlock
            }
        } while final == 0
        return out
    }
}
