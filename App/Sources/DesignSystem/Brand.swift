import SwiftUI

/// CameraBridge's brand tokens: a solid dark-gray canvas with the yellow-to-orange palette used only for accents
/// (selection outline, icons, status, focus, links and the primary button). No gradients in controls. The manager
/// window forces a dark appearance, so these are tuned for dark only; the menu and Settings keep following the system
/// and use the `AccentColor` asset instead.
enum Brand {
    static let yellow = Color(hex: 0xFFDE1A)
    static let gold = Color(hex: 0xFFCE00)
    static let amber = Color(hex: 0xFFA700)
    static let tangerine = Color(hex: 0xFF8D00)
    static let orange = Color(hex: 0xFF7400)

    /// Text and glyphs on an amber fill are always black.
    static let onAmber = Color.black

    /// Window, sidebar, cards, raised cards (selected sidebar card) and hairlines.
    static let canvas = Color(hex: 0x1C1C1E)
    static let sidebar = Color(hex: 0x171719)
    static let card = Color(hex: 0x2A2A2D)
    static let cardSelected = Color(hex: 0x343437)
    static let border = Color(hex: 0x3A3A3D)
    /// Secondary buttons (solid gray) and their hover state.
    static let control = Color(hex: 0x3A3A3D)
    static let controlHover = Color(hex: 0x47474B)

    /// Status colors, tuned for dark backgrounds (never the only signal: always with a word or glyph).
    static let live = Color(hex: 0x3DDC97)
    static let recording = Color(hex: 0xFF5A52)
    static let warning = Color(hex: 0xFFB020)
    static let neutral = Color(hex: 0x9A9AA2)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// Full-bleed background: solid dark gray.
struct BrandCanvas: View {
    var body: some View {
        Brand.canvas
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Rounded solid card surface with a hairline border (lighter under Increase Contrast). `highlighted` is the selected
/// state: a slightly lighter fill and a solid amber outline. `radius` is 16-20 pt for cards, smaller for pills.
struct BrandSurface: ViewModifier {
    var radius: CGFloat = 18
    var highlighted = false
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background { shape.fill(highlighted ? Brand.cardSelected : Brand.card) }
            .overlay {
                if highlighted {
                    shape.strokeBorder(Brand.amber, lineWidth: 2)
                } else {
                    shape.strokeBorder(contrast == .increased ? Color.white.opacity(0.5) : Brand.border, lineWidth: contrast == .increased ? 1.5 : 1)
                }
            }
    }
}

extension View {
    func brandSurface(radius: CGFloat = 18, highlighted: Bool = false) -> some View {
        modifier(BrandSurface(radius: radius, highlighted: highlighted))
    }
}

/// Row background for grouped Form sections on the brand canvas.
struct BrandRowBackground: View {
    var body: some View {
        Rectangle().fill(Brand.card)
    }
}

/// A titled card: icon + title above arbitrary content, on a `brandSurface`.
struct SectionCard<Content: View>: View {
    let title: LocalizedStringKey
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(Brand.amber)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandSurface(radius: 20)
    }
}
