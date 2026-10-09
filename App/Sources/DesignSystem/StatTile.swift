import SwiftUI

/// Compact dashboard tile: a small title with glyph (and an optional leading accessory such as a score ring), one bold
/// value and a line of detail. Pass `action` to make the whole tile a button.
struct StatTile<Accessory: View>: View {
    let title: LocalizedStringKey
    let value: String
    var detail: String?
    var systemImage: String
    var tint: Color = Brand.amber
    var action: (() -> Void)?
    var accessibilityHint: LocalizedStringKey?
    var hasAccessory = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        if let action {
            Button(action: action) { tile }
                .buttonStyle(TileButtonStyle())
                .accessibilityHint(accessibilityHint ?? "")
        } else {
            tile
        }
    }

    private var tile: some View {
        HStack(alignment: .top, spacing: 12) {
            if hasAccessory {
                accessory
            }
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(tint)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .brandSurface(radius: 16)
        .accessibilityElement(children: .combine)
    }
}

extension StatTile where Accessory == EmptyView {
    init(title: LocalizedStringKey, value: String, detail: String? = nil, systemImage: String, tint: Color = Brand.amber,
         accessibilityHint: LocalizedStringKey? = nil, action: (() -> Void)? = nil) {
        self.init(title: title, value: value, detail: detail, systemImage: systemImage, tint: tint, action: action,
                  accessibilityHint: accessibilityHint, hasAccessory: false) { EmptyView() }
    }
}

private struct TileButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if isFocused { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.9), lineWidth: 2) }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Circular score ring (0–100), green from 90, amber from 60, red below.
struct ScoreRing: View {
    let score: Int

    private var tint: Color {
        switch score {
        case 90...: Brand.live
        case 60..<90: Brand.warning
        default: Brand.recording
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(Brand.border, lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(score, 100))) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: 14, weight: .bold).monospacedDigit())
        }
        .frame(width: 46, height: 46)
        .accessibilityHidden(true)
    }
}
