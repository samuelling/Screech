import SwiftUI
import UniformTypeIdentifiers

struct ListenPanel: View {
    @EnvironmentObject var model: ScreechModel
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(model.listening ? "STOP LISTENING" : "LISTEN") { model.toggleListening() }
                .buttonStyle(TermButtonStyle(prominent: !model.listening, color: model.listening ? Phosphor.amber : Phosphor.green))
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.micDenied {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SCREECH NEEDS THE MICROPHONE TO HEAR NOTES. IT NEVER RECORDS OR SAVES AUDIO.")
                        .font(Phosphor.mono(.caption, weight: .bold)).phosphor(Phosphor.amber)
                    Button("OPEN SETTINGS") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
                        .buttonStyle(TermButtonStyle(color: Phosphor.amber))
                }
            }

            Rule(title: "LINE MONITOR")
            ZStack(alignment: .topLeading) {
                if let img = model.waterfall.image {
                    Image(decorative: img, scale: 1, orientation: .left)
                        .resizable().interpolation(.medium)
                        .frame(maxWidth: .infinity).frame(height: 150)
                } else { Color.black.frame(height: 150) }
                Text("3.6 kHz").font(.system(size: 9, design: .monospaced)).foregroundStyle(Phosphor.dim).padding(4)
                Text("0.6 kHz").font(.system(size: 9, design: .monospaced)).foregroundStyle(Phosphor.dim).padding(4)
                    .frame(maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(height: 150)
            .background(Color.black)
            .overlay(Rectangle().stroke(Phosphor.dim, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.carrier ? "Spectrogram: a note is coming in" : "Spectrogram of the microphone")

            HStack(spacing: 8) {
                Text("MIC").font(Phosphor.mono(.caption, weight: .bold)).phosphor(Phosphor.dim)
                GeometryReader { g in
                    let f = CGFloat(max(0, min(1, (model.levelDb + 70) / 70)))
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Phosphor.faint)
                        Rectangle().fill(model.levelDb > -6 ? Phosphor.red : Phosphor.green).frame(width: g.size.width * f)
                    }
                }
                .frame(height: 8)
                Text(model.listening ? String(format: "%4.0f dB", model.levelDb) : " OFF").font(Phosphor.mono(.caption)).phosphor(Phosphor.dim)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Microphone level")
            .accessibilityValue(model.listening ? "\(Int(model.levelDb)) decibels" : "off")

            if let p = model.receiveProgress {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RECEIVING… \(Int(p * 100))%").font(Phosphor.mono(.caption, weight: .bold)).phosphor()
                    GeometryReader { g in
                        ZStack(alignment: .leading) { Rectangle().fill(Phosphor.faint); Rectangle().fill(Phosphor.green).frame(width: g.size.width * p) }
                    }.frame(height: 8)
                }
                .accessibilityElement(children: .ignore).accessibilityLabel("Receiving").accessibilityValue("\(Int(p * 100)) percent")
            }

            Rule(title: "RECEIVED")
            if model.received.isEmpty {
                Text("NOTHING YET. NOTES YOU HEAR APPEAR HERE (THEY'RE NOT SAVED WHEN YOU CLOSE THE APP).")
                    .font(Phosphor.mono(.caption)).phosphor(Phosphor.dim)
            }
            ForEach(model.received) { n in NoteRow(note: n) }
            HStack(spacing: 10) {
                Button(model.busyDecodingFile ? "DECODING…" : "DECODE A SOUND FILE") { importing = true }
                    .buttonStyle(TermButtonStyle()).disabled(model.busyDecodingFile)
                if !model.received.isEmpty { Button("CLEAR") { model.clearReceived() }.buttonStyle(TermButtonStyle(color: Phosphor.dim)) }
            }
        }
        .padding(.top, 4)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { r in
            if case .success(let url) = r { model.decodeFile(url) }
        }
    }
}

struct NoteRow: View {
    @EnvironmentObject var model: ScreechModel
    let note: ReceivedNote
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(note.date.formatted(date: .omitted, time: .shortened).uppercased() + " · " + note.mode.name.uppercased() + " · " + (note.source == "mic" ? "MIC" : "FILE"))
                    .font(Phosphor.mono(.caption2)).phosphor(Phosphor.dim)
                Spacer()
            }
            switch note.status {
            case .secret(let t):
                Text("✓ SECRET").font(Phosphor.mono(.caption, weight: .bold)).phosphor()
                noteText(t)
            case .open(let t):
                Text("OPEN NOTE (NOT SECRET)").font(Phosphor.mono(.caption, weight: .bold)).phosphor(Phosphor.amber)
                noteText(t)
            case .locked:
                Text("🔒 SECRET NOTE. ENTER THE PASSPHRASE ABOVE, THEN:").font(Phosphor.mono(.caption, weight: .bold)).phosphor(Phosphor.amber)
                Button("TRY PASSPHRASE") { model.retry(note) }.buttonStyle(TermButtonStyle(color: Phosphor.amber))
            case .wrongPassphrase:
                Text("✗ WRONG PASSPHRASE.").font(Phosphor.mono(.caption, weight: .bold)).phosphor(Phosphor.red)
                Button("TRY AGAIN") { model.retry(note) }.buttonStyle(TermButtonStyle(color: Phosphor.red))
            case .garbled:
                Text("GARBLED.").font(Phosphor.mono(.caption, weight: .bold)).phosphor(Phosphor.red)
            }
        }
        .padding(10)
        .overlay(Rectangle().stroke(Phosphor.faint, lineWidth: 1))
    }
    @ViewBuilder func noteText(_ t: String) -> some View {
        Text(t).font(Phosphor.mono(.body)).phosphor().textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        Button("COPY") { UIPasteboard.general.string = t }
            .font(Phosphor.mono(.caption, weight: .bold)).buttonStyle(.plain).phosphor(Phosphor.dim).frame(minHeight: 32)
            .accessibilityLabel("Copy note text")
    }
}
