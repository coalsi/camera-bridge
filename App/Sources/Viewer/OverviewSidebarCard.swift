import BridgeEngine
import SwiftUI

/// The sidebar's first card: the Overview (every camera at a glance). Looks like the Sensors Bridge and Diagnostics cards.
struct OverviewSidebarCard: View {
    let cameras: [CameraStatus]
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        let online = cameras.filter { $0.connection == .online }.count
        let subtitle = cameras.isEmpty ? String(localized: "Every camera at a glance")
            : (String(localized: "\(cameras.count) cameras") + " · " + String(localized: "\(online) online"))
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Brand.onAmber)
                    .frame(width: 44, height: 44)
                    .background(Brand.amber, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Overview")
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .brandSurface(radius: 18, highlighted: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Overview, \(subtitle)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
