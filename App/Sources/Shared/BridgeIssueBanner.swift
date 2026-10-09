import SwiftUI

/// Top-of-window banner for a problem with the whole bridge (`AppModel.bridgeIssue`), with the action that fixes it.
struct BridgeIssueBanner: View {
    let issue: BridgeIssue
    let resolve: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.headline)
                Text(issue.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(issue.actionTitle, action: resolve)
                .glassButtonStyle()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
        .glass(in: Rectangle())
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Start failed") {
    BridgeIssueBanner(issue: .startFailed("The configuration was saved by a newer version of Camera Bridge."), resolve: {})
        .frame(width: 700)
}

#Preview("Local Network denied") {
    BridgeIssueBanner(issue: .localNetworkDenied, resolve: {})
        .frame(width: 700)
}

#Preview("Configuration set aside") {
    BridgeIssueBanner(issue: .configurationRecovered(URL(fileURLWithPath: "/tmp/CameraBridge/config.corrupt-20261001T101058Z.json")), resolve: {})
        .frame(width: 700)
}
