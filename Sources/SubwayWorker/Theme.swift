import AppKit
import SwiftUI

/// Subway Worker's look: a warm near-black, off-white type and one signal-red accent
/// (the colour of a subway line bullet). Geist for text, Geist Mono for labels and numbers.
enum Theme {
    static let background = Color(hex: 0x0F0F10)
    static let surface = Color(hex: 0x19191B)
    static let surfaceRaised = Color(hex: 0x242427)
    static let hairline = Color.white.opacity(0.08)
    static let text = Color(hex: 0xEEECE7)
    static let secondaryText = Color(hex: 0x8F8D88)
    static let tertiaryText = Color(hex: 0x5E5D59)
    static let accent = Color(hex: 0xDB2F35)
    static let onAccent = Color(hex: 0xFFFFFF)
    /// Problems are amber, so they never look like the (red) selection colour.
    static let danger = Color(hex: 0xF2A93B)

    static let radius: CGFloat = 10
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Type

extension Font {
    /// Geist. Falls back to the system font when it isn't available (e.g. `swift run`
    /// outside the app bundle, where the bundled fonts aren't registered).
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        BundledFont.font("Geist", size: size, weight: weight, fallbackDesign: .default)
    }

    /// Geist Mono, for labels, numbers and other small metadata.
    static func geistMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        BundledFont.font("GeistMono", size: size, weight: weight, fallbackDesign: .monospaced)
    }
}

private enum BundledFont {
    private static var available: [String: Bool] = [:]

    static func font(_ family: String, size: CGFloat, weight: Font.Weight, fallbackDesign: Font.Design) -> Font {
        let name = "\(family)-\(styleName(for: weight))"
        if isAvailable(name) { return .custom(name, size: size) }
        return .system(size: size, weight: weight, design: fallbackDesign)
    }

    private static func styleName(for weight: Font.Weight) -> String {
        switch weight {
        case .medium: "Medium"
        case .semibold: "SemiBold"
        case .bold, .heavy, .black: "Bold"
        default: "Regular"
        }
    }

    private static func isAvailable(_ name: String) -> Bool {
        if let known = available[name] { return known }
        let found = NSFont(name: name, size: 12) != nil
        available[name] = found
        return found
    }
}

// MARK: - Shared pieces

/// Small uppercase mono label used for section headings.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.geistMono(10.5, .medium))
            .tracking(1)
            .foregroundStyle(Theme.tertiaryText)
    }
}

/// The one loud button: solid accent.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButton(configuration: configuration)
    }

    private struct PrimaryButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.geist(13, .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(Theme.accent, in: .rect(cornerRadius: 8))
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.3)
                .contentShape(.rect(cornerRadius: 8))
        }
    }
}

/// A quiet text button that picks up a surface on hover.
struct QuietButtonStyle: ButtonStyle {
    var tint: Color = Theme.secondaryText

    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration, tint: tint)
    }

    private struct QuietButton: View {
        let configuration: Configuration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.geist(12.5, .medium))
                .foregroundStyle(isHovering ? Theme.text : tint)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(isHovering || configuration.isPressed ? Theme.surface : .clear, in: .rect(cornerRadius: 8))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(.rect(cornerRadius: 8))
                .onHover { isHovering = $0 }
        }
    }
}

/// Selected → surface + accent outline; hovered → faint surface; otherwise bare.
struct TileBackground: ViewModifier {
    let isSelected: Bool
    var isHovering = false
    var radius: CGFloat = Theme.radius

    func body(content: Content) -> some View {
        content
            .background(
                isSelected ? Theme.surface : (isHovering ? Theme.surface.opacity(0.6) : .clear),
                in: .rect(cornerRadius: radius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5)
            }
            .contentShape(.rect(cornerRadius: radius))
    }
}

extension View {
    func tileBackground(selected: Bool, hovering: Bool = false, radius: CGFloat = Theme.radius) -> some View {
        modifier(TileBackground(isSelected: selected, isHovering: hovering, radius: radius))
    }
}

/// A compact segmented control in the app's own style.
struct SegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.geist(12, .medium))
                        .foregroundStyle(isSelected ? Theme.text : Theme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(isSelected ? Theme.surfaceRaised : .clear, in: .rect(cornerRadius: 6))
                        .contentShape(.rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.surface, in: .rect(cornerRadius: 8))
    }
}
