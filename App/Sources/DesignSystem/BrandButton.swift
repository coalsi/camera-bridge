import SwiftUI

enum BrandButtonKind {
    /// Solid amber fill with black text: the one main action of a screen.
    case primary
    /// Solid gray surface with light text.
    case secondary
    /// Soft red; for removals (always behind a confirmation).
    case destructive
}

/// Large rounded button: at least 40 pt tall (46 pt with `large`), generous padding, pressed and disabled states.
struct BrandButtonStyle: ButtonStyle {
    var kind: BrandButtonKind = .secondary
    var large = false
    /// An icon button: as wide as it is tall.
    var square = false

    func makeBody(configuration: Configuration) -> some View {
        BrandButtonBody(configuration: configuration, kind: kind, large: large, square: square)
    }
}

private struct BrandButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: BrandButtonKind
    let large: Bool
    var square = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: large ? 16 : 14, style: .continuous)
        configuration.label
            .font(.system(size: large ? 15 : 14, weight: .semibold))
            .labelStyle(BrandLabelStyle())
            .foregroundStyle(foreground)
            .padding(.horizontal, square ? 0 : (large ? 22 : 16))
            .frame(width: square ? (large ? 46 : 40) : nil)
            .frame(minHeight: large ? 46 : 40)
            .background(fill, in: shape)
            .overlay {
                shape.strokeBorder(border, lineWidth: contrast == .increased ? 1.5 : 1)
            }
            .overlay {
                if isFocused { shape.strokeBorder(Color.white.opacity(0.9), lineWidth: 2).padding(-3) }
            }
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var foreground: Color {
        guard isEnabled else { return Color(hex: 0x9C9CA2) }
        switch kind {
        case .primary: return Brand.onAmber
        case .secondary: return Color(hex: 0xF2F2F5)
        case .destructive: return Color(hex: 0xFF8A80)
        }
    }

    private var border: Color {
        guard isEnabled else { return Color.white.opacity(contrast == .increased ? 0.4 : 0.12) }
        switch kind {
        case .primary: return .clear
        case .secondary: return .white.opacity(contrast == .increased ? 0.6 : 0.10)
        case .destructive: return Brand.recording.opacity(contrast == .increased ? 0.9 : 0.5)
        }
    }

    /// Solid fills only. Primary is amber, orange-ish on hover and deeper when pressed; a disabled button of any kind is
    /// a flat dark-gray tile with gray text (clearly inactive, still readable) instead of a faded version of itself.
    private var fill: Color {
        guard isEnabled else { return Color(hex: 0x2F2F32) }
        let pressed = configuration.isPressed
        switch kind {
        case .primary: return pressed ? Brand.orange : (isHovering ? Brand.tangerine : Brand.amber)
        case .secondary: return pressed ? Color(hex: 0x56565A) : (isHovering ? Brand.controlHover : Brand.control)
        case .destructive: return pressed ? Color(hex: 0x4A2A28) : (isHovering ? Color(hex: 0x40272A) : Color(hex: 0x35262A))
        }
    }
}

private struct BrandLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
            configuration.title
        }
    }
}

extension ButtonStyle where Self == BrandButtonStyle {
    static func brand(_ kind: BrandButtonKind = .secondary, large: Bool = false, square: Bool = false) -> BrandButtonStyle {
        BrandButtonStyle(kind: kind, large: large, square: square)
    }
}

/// `Button` with a title and an SF Symbol in the brand style.
struct BrandButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var kind: BrandButtonKind = .secondary
    var large = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .buttonStyle(BrandButtonStyle(kind: kind, large: large))
    }
}
