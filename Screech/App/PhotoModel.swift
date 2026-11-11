import SwiftUI
import UIKit

/// A photo being received (a snapshot of PhotoReceiver.Photo for the UI)
struct ReceivedPhoto: Identifiable, Equatable {
    let id: Int
    var date = Date()
    var mode = ""
    var w = 0, h = 0, bands = 0
    var got = 0
    var lost: [Int] = []
    var next = 0
    var status: PhotoReceiver.Status = .waiting
    var encrypted = false
    var image: CGImage?
    static func == (a: ReceivedPhoto, b: ReceivedPhoto) -> Bool {
        a.id == b.id && a.got == b.got && a.lost == b.lost && a.status == b.status && a.next == b.next && a.w == b.w
    }
}

/// what's being prepared to send
struct OutgoingPhoto {
    var encoded: PhotoCodec.Encoded
    var preview: CGImage?           // what the receiver will see (decoded from the stripes)
    var bytes: Int                   // stripes, before encryption
}

/// holds the passphrase for the photo queue (only touched on that queue)
final class PassBox { var value = "" }

enum PixelImage {
    static func cgImage(rgba: [UInt8], w: Int, h: Int) -> CGImage? {
        guard w > 0, h > 0, rgba.count >= w * h * 4, let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
    /// draw any UIImage (orientation respected) into w×h RGBA
    static func rgba(from image: UIImage, w: Int, h: Int) -> [UInt8] {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let cg = drawn.cgImage else { return px }
        px.withUnsafeMutableBytes { buf in
            if let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return px
    }
    /// a big, crisp PNG for sharing (nearest-neighbour ×scale, so the pixels stay square)
    static func png(_ img: CGImage, scale: Int = 6) -> Data? {
        let W = img.width * scale, H = img.height * scale
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        guard let big = ctx.makeImage() else { return nil }
        return UIImage(cgImage: big).pngData()
    }
}
