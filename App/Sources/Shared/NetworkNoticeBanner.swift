import BridgeEngine
import SwiftUI

/// Top-of-window banner for a VPN finding (`AppModel.networkBanner`), in the style of `BridgeIssueBanner`: an information
/// banner while nothing has failed, a warning when live view to the device failed. Learn More opens the steps; the close
/// button hides it for the day.
struct NetworkNoticeBanner: View {
    let message: NetworkNoticeMessage
    let learnMore: () -> Void
    let dismiss: () -> Void

    private var isWarning: Bool { message.severity == .warning }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isWarning ? Color.orange : Brand.amber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .font(.headline)
                Text(message.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Learn More…", action: learnMore)
                .glassButtonStyle()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide this for today")
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isWarning ? Color.orange : Brand.amber).opacity(0.12))
        .glass(in: Rectangle())
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

/// Learn More for a network finding (`NetworkHelpContent`): what happened, what CameraBridge already did and what the person can do
/// (for a VPN: on the iPhone or iPad, in NordVPN and on this Mac).
struct NetworkHelpSheet: View {
    let page: NetworkHelpPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Image(systemName: page.systemImage)
                            .font(.title)
                            .foregroundStyle(Brand.amber)
                            .accessibilityHidden(true)
                        Text(page.title)
                            .font(.title2.weight(.semibold))
                    }
                    Text(page.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(page.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(section.title, systemImage: section.systemImage)
                                .font(.headline)
                            ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(section.numbered ? "\(index + 1)." : "•")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .accessibilityHidden(!section.numbered)
                                    Text(step)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.system(size: 13))
                            }
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.brand(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(Color.black.opacity(0.25))
        }
        .frame(width: 520, height: 560)
        .background { BrandCanvas() }
        .preferredColorScheme(.dark)
        .tint(Brand.amber)
    }
}

#Preview("Device on a VPN") {
    NetworkNoticeBanner(message: NetworkNoticeMessage.make(for: .init(kind: .controllerOnVPN, cameraName: "Driveway", advertisedAddress: "10.5.0.2",
                                                                       peerAddress: "192.0.2.20", usedFallback: true))!,
                        learnMore: {}, dismiss: {})
        .frame(width: 900)
}

#Preview("Learn More: VPN") {
    NetworkHelpSheet(page: NetworkHelpContent.page(for: .controllerOnVPN))
}

#Preview("Learn More: live view not received") {
    NetworkHelpSheet(page: NetworkHelpContent.page(for: .liveViewNotReceived))
}

#Preview("Learn More: Local Network denied") {
    NetworkHelpSheet(page: NetworkHelpContent.page(for: .localNetworkDenied))
}

#Preview("Learn More: Mac on the network twice") {
    NetworkHelpSheet(page: NetworkHelpContent.page(for: .dualHomedSubnet))
}
