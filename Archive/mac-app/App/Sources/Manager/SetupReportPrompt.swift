import BridgeEngine
import SwiftUI

/// The one-time "Send this setup report?" question after an Optimize run that left failed or manual-only fixes. Shows
/// the exact JSON that would be sent; nothing is sent unless the person presses Send.
struct SetupReportPrompt: View {
    let report: SetupReport
    let send: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Send this setup report?")
                .font(.subheadline.weight(.semibold))
            Text("Some settings couldn’t be fixed automatically. Sending this helps improve support for your camera. It’s exactly what would be sent: no addresses, names, passwords, serial numbers, images or video.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(report.prettyJSON)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 110)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(Text("Setup report contents"))
            HStack {
                Spacer()
                Button("Don’t Send", action: decline)
                Button("Send", action: send)
            }
            Text("To always send reports, turn on Help improve camera support in Settings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

#Preview {
    SetupReportPrompt(report: .example, send: {}, decline: {})
        .padding()
        .frame(width: 480)
}
