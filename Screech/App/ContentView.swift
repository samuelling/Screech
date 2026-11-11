import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: ScreechModel
    enum Tab: String, CaseIterable { case send = "SEND", listen = "LISTEN" }
    @State private var tab: Tab = .send
    @State private var showHelp = false

    var body: some View {
        NavigationStack { screen.toolbar(.hidden, for: .navigationBar) }
    }

    private var screen: some View {
        ZStack {
            Phosphor.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                PassphraseField()
                    .padding(.horizontal, 16).padding(.top, 10)
                tabs.padding(.horizontal, 16).padding(.vertical, 10)
                ScrollView {
                    Group {
                        switch tab {
                        case .send: SendPanel()
                        case .listen: ListenPanel()
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                statusLine
            }
            Scanlines().ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .tint(Phosphor.green)
        .sheet(isPresented: $showHelp) { HelpView() }
        .onOpenURL { url in tab = .listen; model.decodeFile(url) }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text("SCREECH").font(.system(size: 30, weight: .black, design: .monospaced)).phosphor()
                    .accessibilityAddTraits(.isHeader)
                Text("SECRET NOTES BY SOUND").font(Phosphor.mono(.caption2, weight: .bold)).phosphor(Phosphor.dim)
            }
            Spacer()
            HStack(spacing: 10) {
                LED(label: "MR", on: model.listening, color: Phosphor.green, help: "Microphone listening")
                LED(label: "CD", on: model.carrier, color: Phosphor.amber, help: "Carrier detected")
                LED(label: "RD", on: model.receiveProgress != nil, color: Phosphor.green, help: "Receiving data")
                LED(label: "SD", on: model.sending, color: Phosphor.red, help: "Sending data")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.2)))
            Button { showHelp = true } label: {
                Text("?").font(Phosphor.mono(.title3, weight: .black)).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).phosphor()
            .accessibilityLabel("Help")
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    Text(t.rawValue).frame(maxWidth: .infinity)
                }
                .buttonStyle(TermButtonStyle(prominent: tab == t))
                .accessibilityAddTraits(tab == t ? .isSelected : [])
            }
        }
    }

    private var statusLine: some View {
        HStack {
            Text("> " + model.status)
                .font(Phosphor.mono(.footnote, weight: .semibold)).phosphor()
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Text("▌").font(Phosphor.mono(.footnote)).phosphor().accessibilityHidden(true)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.black)
        .overlay(Rectangle().fill(Phosphor.faint).frame(height: 1), alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(model.status)")
    }
}

struct PassphraseField: View {
    @EnvironmentObject var model: ScreechModel
    @State private var reveal = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("KEY>").font(Phosphor.mono(.body, weight: .bold)).phosphor().accessibilityHidden(true)
                Group {
                    if reveal { TextField("", text: $model.passphrase, prompt: Text("shared passphrase").foregroundColor(Phosphor.dim)) }
                    else { SecureField("", text: $model.passphrase, prompt: Text("shared passphrase").foregroundColor(Phosphor.dim)) }
                }
                .font(Phosphor.mono(.body)).foregroundStyle(Phosphor.green)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityLabel("Shared passphrase")
                .accessibilityHint("Both people use the same passphrase. It never leaves the phone.")
                Button(reveal ? "HIDE" : "SHOW") { reveal.toggle() }
                    .font(Phosphor.mono(.caption, weight: .bold)).buttonStyle(.plain).phosphor(Phosphor.dim)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(reveal ? "Hide passphrase" : "Show passphrase")
            }
            .padding(.horizontal, 10)
            .overlay(Rectangle().stroke(Phosphor.dim, lineWidth: 1))
            Toggle(isOn: $model.rememberPassphrase) {
                Text("REMEMBER ON THIS IPHONE").font(Phosphor.mono(.caption, weight: .semibold)).phosphor(Phosphor.dim)
            }
            .toggleStyle(CheckboxStyle())
        }
    }
}

/// "[x] label" checkbox
struct CheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                Text(configuration.isOn ? "[X]" : "[ ]").font(Phosphor.mono(.body, weight: .bold)).phosphor()
                configuration.label
                Spacer(minLength: 0)
            }
            .frame(minHeight: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}
