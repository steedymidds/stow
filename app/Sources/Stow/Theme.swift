import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}

/// Design tokens. Change the values here to restyle the whole app. Fonts are the system faces.
enum Theme {
    static let void = Color(hex: 0x111214)
    static let surface = Color(hex: 0x1b1c1f)
    static let inset = Color(hex: 0x26282c)
    static let paper = Color(hex: 0xf2f2f0)
    static let warmGrey = Color(hex: 0xc2c3c6)
    static let muted = Color(hex: 0x8f9196)
    static let olive = Color(hex: 0x6f7177)
    static let accent = Color(hex: 0x5b8def)
    static let lavender = Color(hex: 0x9a8cff)
    static let signal = Color(hex: 0xe5484d)
    static let line1 = Color(hex: 0xf3f4ee, opacity: 0.12)
    static let line2 = Color(hex: 0xf3f4ee, opacity: 0.24)
    static let line3 = Color(hex: 0xf3f4ee, opacity: 0.40)

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

/// Uppercase mono label, the page's `.mono` style.
struct MonoLabel: View {
    let text: String
    var color: Color = Theme.muted
    init(_ text: String, color: Color = Theme.muted) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(11))
            .tracking(0.9)
            .foregroundStyle(color)
    }
}

struct Chip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(Theme.mono(11)).tracking(0.9)
                .padding(.horizontal, 14).frame(height: 28)
                .foregroundStyle(on ? Theme.paper : Theme.warmGrey)
                .background(Capsule().fill(on ? Theme.inset : Color.clear))
                .overlay(Capsule().stroke(Theme.line3, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct ThemeButton: View {
    enum Kind { case primary, secondary, ghost, bin }
    let title: String
    var kind: Kind = .secondary
    var small = false
    var working = false
    let action: () -> Void
    @UIState private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if working { ProgressView().controlSize(.mini).tint(fg) }
                Text(title.uppercased())
            }
                .font(Theme.mono(11)).tracking(0.9)
                .padding(.horizontal, small ? 12 : 18)
                .frame(height: small ? 28 : 36)
                .foregroundStyle(fg)
                .background(RoundedRectangle(cornerRadius: 2).fill(bg))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(border, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .disabled(working)
    }
    private var fg: Color {
        switch kind {
        case .primary: return Theme.void
        case .bin: return hover ? Theme.signal : Theme.paper
        case .ghost: return hover ? Theme.paper : Theme.warmGrey
        case .secondary: return Theme.paper
        }
    }
    private var bg: Color {
        switch kind {
        case .primary: return hover ? Theme.accent : Theme.paper
        case .secondary, .ghost: return hover ? Theme.surface : .clear
        case .bin: return .clear
        }
    }
    private var border: Color {
        switch kind {
        case .primary, .ghost: return .clear
        case .bin: return hover ? Theme.signal : Theme.line3
        case .secondary: return Theme.line3
        }
    }
}

/// The command-line tools ship SwiftUI's @State macro without its compiler plugin,
/// so use the property-wrapper type through an alias.
typealias UIState<Value> = SwiftUI.State<Value>
