import XCTest
import Foundation
@testable import ScreechCore

final class PhotoTests: XCTestCase {
    struct Fx: Decodable { struct F: Decodable { let payload: [Int]; let flags: Int }; let w: Int; let h: Int; let passphrase: String; let mode: String; let frames: [F]; let bandBytes: [[Int]] }
    func fx() throws -> Fx { try JSONDecoder().decode(Fx.self, from: Data(contentsOf: fixtures.appendingPathComponent("photo.json"))) }
    func raw(_ n: String) throws -> [UInt8] { [UInt8](try Data(contentsOf: fixtures.appendingPathComponent(n))) }
    func maxDiff(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0 }

    func testDecodesWebStripesToTheSamePixels() throws {
        let f = try fx(), ref = try raw("photo-ref.rgba")
        var out = [UInt8](repeating: 0, count: f.w * f.h * 4)
        for (i, b) in f.bandBytes.enumerated() {
            XCTAssertTrue(PhotoCodec.decodeBand(b.map { UInt8($0) }, band: i, w: f.w, h: f.h, quality: 35, gray: false, into: &out))
        }
        XCTAssertLessThanOrEqual(maxDiff(out, ref), 1)
    }
    func testSwiftEncoderMatchesWebBitstream() throws {
        // same pixels in → same stripes out (the encoders may differ only in rounding exactly-.5 coefficients)
        let f = try fx(), src = try raw("photo-src.rgba")
        let enc = PhotoCodec.encode(rgba: src, w: f.w, h: f.h, quality: 35)
        let same = zip(enc.bands, f.bandBytes).filter { $0.0 == $0.1.map { UInt8($0) } }.count
        XCTAssertGreaterThanOrEqual(same, f.bandBytes.count - 1, "stripes identical to the web encoder's")
    }
    func testUnlocksWebEncryptedTrain() throws {
        let f = try fx(), ref = try raw("photo-ref.rgba")
        let rx = PhotoReceiver(passphrase: { f.passphrase })
        var last: PhotoReceiver.Photo?
        for fr in f.frames { last = rx.feed(fr.payload.map { UInt8($0) }, flags: fr.flags, mode: f.mode) ?? last }
        let p = try XCTUnwrap(last)
        XCTAssertEqual(p.status, .done); XCTAssertEqual(p.got.count, p.bands); XCTAssertTrue(p.lost.isEmpty)
        XCTAssertLessThanOrEqual(maxDiff(p.rgba, ref), 1)
        // wrong passphrase, then the right one
        var pass = "nope"
        let rx2 = PhotoReceiver(passphrase: { pass })
        var p2: PhotoReceiver.Photo?
        for fr in f.frames { p2 = rx2.feed(fr.payload.map { UInt8($0) }, flags: fr.flags, mode: f.mode) ?? p2 }
        XCTAssertEqual(p2?.status, .wrongPassphrase)
        pass = f.passphrase
        _ = rx2.retry()
        XCTAssertEqual(p2?.status, .done)
        XCTAssertLessThanOrEqual(maxDiff(p2!.rgba, ref), 1)
    }
    func testHearsAWebPhotoOverTheAir() throws {
        let (s, rate) = try readWav(fixtures.appendingPathComponent("photo-quick.wav"))
        let f = try fx(), ref = try raw("photo-ref.rgba")
        let rx = PhotoReceiver(passphrase: { "" })
        var last: PhotoReceiver.Photo?
        let d = NoteDecoder(sampleRate: rate) { e in if case let .photo(true, mode, flags, b?) = e { last = rx.feed(b, flags: flags, mode: mode) ?? last } }
        d.push(s); d.flush(seconds: 0.5)
        let p = try XCTUnwrap(last)
        XCTAssertEqual(p.status, .done); XCTAssertEqual(p.got.count, p.bands)
        XCTAssertEqual(p.w, f.w)
        XCTAssertLessThanOrEqual(maxDiff(p.rgba, ref), 1)
    }
    func testLostStripeSmearsAndTheRestArrives() throws {
        let f = try fx()
        let rx = PhotoReceiver(passphrase: { f.passphrase })
        var last: PhotoReceiver.Photo?
        for (i, fr) in f.frames.enumerated() where i != 2 { last = rx.feed(fr.payload.map { UInt8($0) }, flags: fr.flags, mode: f.mode) ?? last }
        XCTAssertEqual(last?.lost, [1]); XCTAssertEqual(last?.status, .done)
    }
    func testSwiftTrainRoundTrip() throws {
        let f = try fx(), src = try raw("photo-src.rgba")
        let enc = PhotoCodec.encode(rgba: src, w: f.w, h: f.h, quality: 35)
        let (_, frames) = try PhotoPacker.pack(enc, passphrase: "owl")
        let (audio, marks) = PhotoPacker.render(frames, mode: .classic, sampleRate: 16000, amplitude: 0.4)
        XCTAssertEqual(marks.count, frames.count)
        let rx = PhotoReceiver(passphrase: { "owl" })
        var last: PhotoReceiver.Photo?
        let d = NoteDecoder(sampleRate: 16000) { e in if case let .photo(true, mode, flags, b?) = e { last = rx.feed(b, flags: flags, mode: mode) ?? last } }
        d.push(audio); d.flush(seconds: 0.5)
        XCTAssertEqual(last?.status, .done); XCTAssertEqual(last?.got.count, enc.bands.count)
    }
}
