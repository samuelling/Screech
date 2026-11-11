import SwiftUI

enum Phosphor {
    static let green = Color(red: 0.25, green: 1.0, blue: 0.45)
    static let dim = Color(red: 0.16, green: 0.64, blue: 0.31)
    static let faint = Color(red: 0.05, green: 0.22, blue: 0.10)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let red = Color(red: 1.0, green: 0.3, blue: 0.25)
    static let bg = Color(red: 0.01, green: 0.03, blue: 0.015)

    static func mono(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }
}

/// glowing phosphor text
struct Glow: ViewModifier {
    var color = Phosphor.green
    func body(content: Content) -> some View { content.foregroundStyle(color).shadow(color: color.opacity(0.55), radius: 3) }
}
extension View { func phosphor(_ c: Color = Phosphor.green) -> some View { modifier(Glow(color: c)) } }

/// "[ SEND ]" terminal buttons: outlined, inverse video when pressed or emphasised
struct TermButtonStyle: ButtonStyle {
    var prominent = false
    var color = Phosphor.green
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let inverse = prominent != configuration.isPressed
        configuration.label
            .font(Phosphor.mono(.body, weight: .bold))
            .padding(.vertical, 10).padding(.horizontal, 14)
            .frame(minHeight: 44)
            .foregroundStyle(inverse ? Color.black : color)
            .background(inverse ? color : Color.clear)
            .overlay(Rectangle().stroke(color, lineWidth: 1.5))
            .shadow(color: color.opacity(inverse ? 0.6 : 0.3), radius: 4)
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}

/// front-panel status light, like an external modem's
struct LED: View {
    let label: String, on: Bool, color: Color, help: String
    var body: some View {
        VStack(spacing: 3) {
            Circle().fill(on ? color : color.opacity(0.15))
                .frame(width: 11, height: 11)
                .shadow(color: on ? color : .clear, radius: on ? 6 : 0)
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
            Text(label).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Phosphor.dim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(help), \(on ? "on" : "off")")
    }
}

/// faint CRT scanlines over everything (purely decorative)
struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.18))); y += 3 }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// section heading in terminal style
struct Rule: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Phosphor.mono(.caption, weight: .bold)).phosphor(Phosphor.dim)
            Rectangle().fill(Phosphor.faint).frame(height: 1)
        }
        .accessibilityAddTraits(.isHeader)
    }
}
