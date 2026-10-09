import AppKit
import BridgeEngine
import SwiftUI

/// Settings › Webhook: Home Assistant, Frigate and other systems report events to CameraBridge with an HTTP request.
struct WebhookSettingsTab: View {
    let model: AppModel
    @State private var revealsToken = false
    @State private var confirmingRegenerate = false

    var body: some View {
        let engine = model.engine
        let settings = engine.settings
        let cameraPorts = engine.cameras.compactMap(\.hapPort) + engine.configurations.map(\.hapPort).filter { $0 != 0 }
        SettingsPage {
            SectionCard(title: "Webhook", systemImage: "link") {
                SettingToggleRow(title: "Enable Webhook",
                                 detail: "Lets other systems report motion, doorbell rings and detections to Camera Bridge.",
                                 isOn: Binding(get: { settings.webhookEnabled }, set: { on in
                                     Task { await model.updateSettings(String(localized: "Enable Webhook")) { $0.webhookEnabled = on } }
                                 }))
                SettingDivider()
                SettingRow(verbatimTitle: String(localized: "Status"),
                           verbatimDetail: SettingsText.webhookStatus(enabled: settings.webhookEnabled, state: engine.state,
                                                                      problem: engine.webhookProblem, port: settings.webhookPort)) { EmptyView() }
                if let problem = engine.webhookProblem {
                    // The webhook is on but not listening (another app took its port before a start or resume).
                    SettingProblem(text: problem) {
                        Button("Try Again") { Task { await model.retryWebhook() } }
                            .buttonStyle(.brand(.secondary))
                    }
                }
                SettingDivider()
                PortEditor(title: "Port", current: settings.webhookPort,
                           validate: { WebhookSettings.validatePort($0, settings: settings, cameraPorts: cameraPorts) },
                           apply: { port in Task { await model.updateSettings(String(localized: "Webhook Port")) { $0.webhookPort = port } } })
            }

            SectionCard(title: "Token", systemImage: "key") {
                SettingNote("Requests must send this token as a Bearer credential.")
                SettingCode(text: revealsToken ? settings.webhookToken : WebhookSettings.masked(settings.webhookToken), size: 13)
                HStack(spacing: 10) {
                    Button(revealsToken ? "Hide" : "Show") { revealsToken.toggle() }
                        .buttonStyle(.brand(.secondary))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(settings.webhookToken, forType: .string)
                    }
                    .buttonStyle(.brand(.secondary))
                    Button("Regenerate…") { confirmingRegenerate = true }
                        .buttonStyle(.brand(.destructive))
                }
            }

            SectionCard(title: "Sending Events", systemImage: "paperplane") {
                SettingNote("Home Assistant, Frigate and other systems can report events with POST /cameras/<camera ID>/<event>, where the event is motion, motion/stop, doorbell, person, vehicle, animal or package. Each camera’s page lists its ID and URLs.")
                SettingCode(text: WebhookSettings.exampleCommand(host: WebhookSettings.localHostName, settings: settings, cameraID: nil, event: "motion"),
                            size: 11.5)
                SettingNote("Doorbell rings work for every doorbell. Detections show as sensors in the Home app for cameras whose motion source is Webhook (turn them on in the camera’s Sensors) or that detect them too.")
            }
        }
        .confirmationDialog("Regenerate the webhook token?", isPresented: $confirmingRegenerate) {
            Button("Regenerate Token", role: .destructive) {
                Task { await model.updateSettings(String(localized: "Regenerate Token")) { $0.webhookToken = WebhookSettings.generateToken() } }
            }
        } message: {
            Text("Systems using the current token stop working until you give them the new one.")
        }
    }
}

#Preview {
    WebhookSettingsTab(model: .preview())
        .frame(width: 740, height: 620)
        .preferredColorScheme(.dark)
}
