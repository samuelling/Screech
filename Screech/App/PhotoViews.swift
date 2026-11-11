import SwiftUI
import PhotosUI

/// Send › PHOTO: pick a picture, choose size and detail, see exactly what the other side will get
struct PhotoSendSection: View {
    @EnvironmentObject var model: ScreechModel
    @State private var item: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Rule(title: "PHOTO")
            PhotosPicker(selection: $item, matching: .images) {
                Text(model.photoSource == nil ? "CHOOSE A PHOTO" : "CHOOSE ANOTHER").frame(maxWidth: .infinity)
            }
            .buttonStyle(TermButtonStyle(prominent: model.photoSource == nil))
            .onChange(of: item) { _, it in
                guard let it else { return }
                Task { if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) { model.photoSource = img } }
            }

            if let o = model.outgoing {
                PixelFrame(image: o.preview, w: o.encoded.w, h: o.encoded.h, revealRows: model.sendRevealRows, scanFraction: nil)
                    .accessibilityLabel("Preview of the photo as it will arrive, \(o.encoded.w) by \(o.encoded.h) pixels")
                Text("\(o.encoded.w)×\(o.encoded.h) PX · \(o.encoded.bands.count) STRIPES · ~\(Int(model.photoAirtime + 0.5)) S ON AIR")
                    .font(Phosphor.mono(.caption)).phosphor(Phosphor.dim)
                choice("SIZE", PhotoCodec.sizes.map { ($0.key, $0.name.uppercased()) }, $model.photoSize)
                choice("DETAIL", PhotoCodec.qualities.map { ($0.key, $0.name.uppercased()) }, $model.photoQuality)
            } else if model.photoSource != nil {
                Text("PREPARING…").font(Phosphor.mono(.caption)).phosphor(Phosphor.dim)
            } else {
                Text("Photos travel tiny (64–128 pixels) and slowly: about half a minute to a few minutes. They paint in from the top while they arrive, like the old days.")
                    .font(Phosphor.mono(.caption)).phosphor(Phosphor.dim)
            }
            if model.passphrase.isEmpty && model.outgoing != nil {
                Text("NO PASSPHRASE: ANYONE WITH A DECODER CAN SEE THIS PHOTO.").font(Phosphor.mono(.caption, weight: .bold)).phosphor(Phosphor.amber)
            }
        }
    }

    func choice(_ title: String, _ opts: [(String, String)], _ sel: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Phosphor.mono(.caption, weight: .bold)).phosphor(Phosphor.dim).frame(width: 64, alignment: .leading)
            ForEach(opts, id: \.0) { k, name in
                Button(name) { sel.wrappedValue = k }
                    .buttonStyle(TermButtonStyle(prominent: sel.wrappedValue == k))
                    .font(Phosphor.mono(.caption))
                    .accessibilityLabel("\(title.lowercased()) \(name.lowercased())")
                    .accessibilityAddTraits(sel.wrappedValue == k ? .isSelected : [])
            }
        }
    }

    /// buttons for the bottom of the Send panel
    struct Actions: View {
        @EnvironmentObject var model: ScreechModel
        @State private var shareURL: URL?
        @State private var preparing = false
        var body: some View {
            HStack(spacing: 10) {
                if model.sending {
                    Button("STOP") { model.stopSending() }.buttonStyle(TermButtonStyle(prominent: true, color: Phosphor.red))
                } else {
                    Button(model.passphrase.isEmpty ? "SEND PHOTO" : "SEND SECRET PHOTO") { model.sendPhoto() }
                        .buttonStyle(TermButtonStyle(prominent: true)).disabled(model.outgoing == nil)
                }
                Button(preparing ? "…" : "SAVE AS SOUND") {
                    preparing = true
                    Task { shareURL = try? await model.photoFile(); preparing = false }
                }
                .buttonStyle(TermButtonStyle()).disabled(model.outgoing == nil || preparing)
            }
            .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
        }
    }
}

/// a pixel-perfect picture frame; `revealRows` hides everything below that row (for the sender's paint-in),
/// `scanFraction` draws the loading line inside the next stripe (for the receiver)
struct PixelFrame: View {
    let image: CGImage?
    let w: Int, h: Int
    var revealRows: Int?
    var scanFraction: (row: Int, fraction: Double)?
    var body: some View {
        GeometryReader { g in
            let scale = min(g.size.width / CGFloat(max(1, w)), 220 / CGFloat(max(1, h)))
            let W = CGFloat(w) * scale, H = CGFloat(h) * scale
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(white: 0.06))
                if let img = image {
                    Image(decorative: img, scale: 1).resizable().interpolation(.none).frame(width: W, height: H)
                        .mask(alignment: .top) { Rectangle().frame(height: revealRows.map { CGFloat($0) * scale } ?? H) }
                }
                if let s = scanFraction, s.row < h {
                    let y = (CGFloat(s.row) + CGFloat(16 * s.fraction)) * scale
                    Rectangle().fill(Phosphor.green.opacity(0.85)).frame(width: W, height: 2).offset(y: min(H - 2, y))
                        .shadow(color: Phosphor.green, radius: 4)
                }
                if let r = revealRows, r < h {
                    Rectangle().fill(Phosphor.green.opacity(0.85)).frame(width: W, height: 2).offset(y: min(H - 2, CGFloat(r) * scale))
                }
            }
            .frame(width: W, height: H)
            .overlay(Rectangle().stroke(Phosphor.dim, lineWidth: 1))
            .frame(maxWidth: .infinity)
        }
        .frame(height: 220)
        .accessibilityElement(children: .ignore)
    }
}

/// a received photo in the LISTEN list
struct PhotoRow: View {
    @EnvironmentObject var model: ScreechModel
    let photo: ReceivedPhoto
    var isNewest: Bool
    @State private var shareURL: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(photo.date.formatted(date: .omitted, time: .shortened).uppercased() + " · PHOTO · " + photo.mode.uppercased())
                .font(Phosphor.mono(.caption2)).phosphor(Phosphor.dim)
            switch photo.status {
            case .locked:
                Text("🔒 SECRET PHOTO. ENTER THE PASSPHRASE ABOVE TO SEE IT.").font(Phosphor.mono(.caption, weight: .bold)).phosphor(Phosphor.amber)
            case .wrongPassphrase:
                Text("✗ WRONG PASSPHRASE. FIX IT ABOVE TO SEE THE PHOTO.").font(Phosphor.mono(.caption, weight: .bold)).phosphor(Phosphor.red)
            case .waiting:
                Text("STRIPES ARRIVING BEFORE THE HEADER… WAITING FOR THE END.").font(Phosphor.mono(.caption)).phosphor(Phosphor.dim)
            default:
                Text(label).font(Phosphor.mono(.caption, weight: .bold)).phosphor(photo.lost.isEmpty ? Phosphor.green : Phosphor.amber)
                PixelFrame(image: photo.image, w: photo.w, h: photo.h, revealRows: nil,
                           scanFraction: photo.status == .receiving && isNewest ? (photo.next * 16, model.incomingPhotoFraction ?? 0) : nil)
                    .accessibilityLabel(photo.status == .done ? "Received photo, \(photo.w) by \(photo.h) pixels" : "Photo arriving, \(photo.got) of \(photo.bands) stripes")
                if photo.status == .done, let img = photo.image {
                    Button("SAVE / SHARE") {
                        if let d = PixelImage.png(img) {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("screech-photo-\(photo.id).png")
                            try? d.write(to: url); shareURL = url
                        }
                    }
                    .buttonStyle(TermButtonStyle())
                }
            }
        }
        .padding(10)
        .overlay(Rectangle().stroke(Phosphor.faint, lineWidth: 1))
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
    }
    var label: String {
        switch photo.status {
        case .done: return photo.lost.isEmpty ? (photo.encrypted ? "✓ SECRET PHOTO" : "PHOTO (NOT SECRET)") : "PHOTO · \(photo.lost.count) DAMAGED STRIPE\(photo.lost.count == 1 ? "" : "S")"
        default: return "RECEIVING… STRIPE \(min(photo.bands, photo.next + 1)) OF \(photo.bands)"
        }
    }
}
