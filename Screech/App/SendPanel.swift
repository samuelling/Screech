import SwiftUI

struct SendPanel: View {
    @EnvironmentObject var model: ScreechModel
    @State private var shareURL: URL?
    @State private var preparing = false
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Rule(title: "MESSAGE")
            ZStack(alignment: .topLeading) {
                if model.message.isEmpty {
                    Text("type a note…").font(Phosphor.mono(.body)).foregroundStyle(Phosphor.dim)
                        .padding(.horizontal, 12).padding(.vertical, 14).accessibilityHidden(true)
                }
                TextEditor(text: $model.message)
                    .focused($editing)
                    .font(Phosphor.mono(.body)).foregroundStyle(Phosphor.green)
                    .scrollContentBackground(.hidden).background(Color.clear)
                    .padding(6)
                    .frame(minHeight: 130)
                    .accessibilityLabel("Message")
                    .onChange(of: model.message) { _, v in
                        if v.count > ScreechModel.maxChars { model.message = String(v.prefix(ScreechModel.maxChars)) }
                    }
            }
            .overlay(Rectangle().stroke(Phosphor.dim, lineWidth: 1))
            Text("\(model.message.count)/\(ScreechModel.maxChars) CHARS · ~\(String(format: "%.1f", model.airtime)) S ON AIR")
                .font(Phosphor.mono(.caption)).phosphor(Phosphor.dim)

            if model.passphrase.isEmpty {
                Text("NO PASSPHRASE: THIS WILL BE AN OPEN NOTE. ANYONE WITH A DECODER CAN READ IT.")
                    .font(Phosphor.mono(.caption, weight: .bold)).phosphor(Phosphor.amber)
            }

            Rule(title: "SPEED")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(NoteMode.all) { m in
                    Button { model.mode = m } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(model.mode == m ? "(•)" : "( )").font(Phosphor.mono(.body, weight: .bold)).phosphor()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.name.uppercased()).font(Phosphor.mono(.body, weight: .bold)).phosphor()
                                Text(m.blurb).font(Phosphor.mono(.caption)).phosphor(Phosphor.dim)
                            }
                            Spacer()
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(model.mode == m ? [.isButton, .isSelected] : .isButton)
                }
            }
            Toggle(isOn: $model.intro) {
                Text("FAKE DIAL-UP HANDSHAKE FIRST").font(Phosphor.mono(.callout, weight: .semibold)).phosphor()
            }
            .toggleStyle(CheckboxStyle())

            HStack(spacing: 10) {
                if model.sending {
                    Button("STOP") { model.stopSending() }.buttonStyle(TermButtonStyle(prominent: true, color: Phosphor.red))
                } else {
                    Button(model.passphrase.isEmpty ? "SEND OPEN NOTE" : "SEND SECRET NOTE") { editing = false; model.send() }
                        .buttonStyle(TermButtonStyle(prominent: true))
                        .disabled(model.message.isEmpty)
                }
                Button(preparing ? "…" : "SAVE AS SOUND") {
                    editing = false; preparing = true
                    Task { shareURL = try? await model.noteFile(); preparing = false }
                }
                .buttonStyle(TermButtonStyle())
                .disabled(model.message.isEmpty || preparing)
                .accessibilityHint("Makes an audio file of the note that you can text or email.")
            }
            Text("Hold your phone a few inches from the other device and turn the volume up. Their Screech (or RetroSynths' Modem) must be listening.")
                .font(Phosphor.mono(.caption)).phosphor(Phosphor.dim)
        }
        .padding(.top, 4)
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("DONE") { editing = false } } }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
