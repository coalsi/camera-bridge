import AppKit
import BridgeEngine
import SwiftUI

/// Settings › Network: Local Network access (with the fix), the ports CameraBridge listens on and this Mac's name and
/// addresses.
struct NetworkSettingsTab: View {
    let model: AppModel
    /// Switches to the Webhook tab (the webhook's port is edited there, next to its token).
    let showWebhook: () -> Void
    @State private var lastCheck: LocalNetworkCheckOutcome?
    @State private var isChecking = false
    @State private var addresses: [NetworkSettings.InterfaceAddress] = []

    var body: some View {
        let engine = model.engine
        let settings = engine.settings
        let cameraPorts = engine.cameras.compactMap(\.hapPort) + engine.configurations.map(\.hapPort).filter { $0 != 0 }
        SettingsPage {
            localNetworkCard(access: engine.localNetworkAccess)

            vpnCard(engine: engine)

            liveVideoCard()

            SectionCard(title: "Ports", systemImage: "arrow.left.arrow.right") {
                PortEditor(title: "First Camera Port",
                           detail: "Cameras you add from now on get their ports from here, one each. Cameras already set up keep theirs.",
                           current: settings.basePort,
                           validate: { NetworkSettings.validatePort($0, for: .firstCameraPort, settings: settings, cameraPorts: cameraPorts) },
                           apply: { port in Task { await model.updateSettings(String(localized: "First Camera Port")) { $0.basePort = port } } })
                SettingDivider()
                PortEditor(title: "Sensors Bridge Port",
                           detail: "The sensors bridge restarts when its port changes.",
                           current: settings.sensorsBridgePort,
                           validate: { NetworkSettings.validatePort($0, for: .sensorsBridge, settings: settings, cameraPorts: cameraPorts) },
                           apply: { port in Task { await model.updateSettings(String(localized: "Sensors Bridge Port")) { $0.sensorsBridgePort = port } } })
                SettingDivider()
                SettingRow(verbatimTitle: String(localized: "Webhook Port"),
                           verbatimDetail: SettingsText.webhookStatus(enabled: settings.webhookEnabled, state: engine.state,
                                                                      problem: engine.webhookProblem, port: settings.webhookPort)) {
                    HStack(spacing: 10) {
                        Text(String(settings.webhookPort))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button("Webhook Settings…", action: showWebhook)
                            .buttonStyle(.brand(.secondary))
                    }
                }
                if !engine.configurations.isEmpty {
                    SettingDivider()
                    ForEach(engine.configurations) { camera in
                        SettingRow(verbatimTitle: camera.name) {
                            Text(SettingsText.port(of: camera, status: model.status(for: camera.id)).map { String($0) } ?? "–")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                SettingNote("Every camera is its own HomeKit accessory with its own port. Camera Bridge picks a free one from the first camera port up. There is no HTTPS port: the webhook speaks plain HTTP on your local network, with its token.")
            }

            SectionCard(title: "This Mac", systemImage: "desktopcomputer") {
                SettingRow(title: "Bonjour Name", detail: "Other devices on your network find this Mac by this name.") {
                    HStack(spacing: 8) {
                        Text(WebhookSettings.localHostName)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy") { copy(WebhookSettings.localHostName) }
                            .buttonStyle(.brand(.secondary))
                    }
                }
                SettingDivider()
                if addresses.isEmpty {
                    SettingRow(title: "Addresses", detail: "No network address found. Connect this Mac to your network.") { EmptyView() }
                } else {
                    ForEach(addresses) { item in
                        SettingRow(verbatimTitle: String(localized: "Address"), verbatimDetail: item.interface) {
                            HStack(spacing: 8) {
                                Text(item.address)
                                    .font(.system(size: 13, design: .monospaced))
                                    .textSelection(.enabled)
                                Button("Copy") { copy(item.address) }
                                    .buttonStyle(.brand(.secondary))
                                    .accessibilityLabel(Text("Copy \(item.address)"))
                            }
                        }
                    }
                }
                SettingNote("Camera Bridge listens on every network interface of this Mac and announces each accessory with Bonjour as _hap._tcp, so the Home app’s hub finds it.")
            }
        }
        .onAppear { addresses = NetworkSettings.ipv4Addresses() }
    }

    /// Whether this Mac or an Apple Home device that watches live view is on a VPN (`BridgeEngine.recentNetworkNotices`).
    private func vpnCard(engine: BridgeEngine) -> some View {
        let messages = model.networkMessages
        let mac = messages.first { $0.kind == .macOnVPN }
        let devices = messages.filter { $0.kind == .controllerOnVPN }
        return SectionCard(title: "VPN", systemImage: "network.badge.shield.half.filled") {
            SettingRow(verbatimTitle: String(localized: "This Mac"),
                       verbatimDetail: mac == nil ? String(localized: "No VPN found. Apple Home devices on your network can reach Camera Bridge.")
                                                  : String(localized: "Connected to a VPN\(engine.macVPN.map { " (\($0.interface))" } ?? ""). Apple Home devices may not be able to reach Camera Bridge.")) {
                VPNStatusLabel(isProblem: mac != nil, text: mac == nil ? String(localized: "No VPN") : String(localized: "On a VPN"))
            }
            SettingDivider()
            if devices.isEmpty {
                SettingRow(title: "Apple Home Devices",
                           detail: "No iPhone or iPad watching live view has been seen on a VPN in the last hour.") {
                    VPNStatusLabel(isProblem: false, text: String(localized: "None seen"))
                }
            } else {
                ForEach(devices) { message in
                    SettingRow(verbatimTitle: message.title, verbatimDetail: message.detail) {
                        VPNStatusLabel(isProblem: message.severity == .warning,
                                       text: message.severity == .warning ? String(localized: "Failed") : String(localized: "Seen"))
                    }
                }
            }
            if mac != nil || !devices.isEmpty {
                HStack {
                    Button("Learn More…") { model.presentVPNHelp() }
                        .buttonStyle(.brand(.secondary))
                }
            }
        }
    }

    /// What CameraBridge found about live video that is sent but does not arrive (`NetworkNotice.Kind.liveViewNotReceived`,
    /// `.localNetworkDenied`, `.dualHomedSubnet`), each with its own Learn More. Absent while there is nothing to report.
    @ViewBuilder private func liveVideoCard() -> some View {
        let kinds: [NetworkNotice.Kind] = [.liveViewNotReceived, .localNetworkDenied, .dualHomedSubnet]
        let findings = model.networkMessages.filter { kinds.contains($0.kind) }
        if !findings.isEmpty {
            SectionCard(title: "Live Video", systemImage: "video") {
                ForEach(Array(findings.enumerated()), id: \.element.id) { index, message in
                    if index > 0 { SettingDivider() }
                    SettingRow(verbatimTitle: message.title, verbatimDetail: message.detail) {
                        HStack(spacing: 10) {
                            VPNStatusLabel(isProblem: message.severity == .warning,
                                           text: message.severity == .warning ? String(localized: "Needs Attention") : String(localized: "Handled"))
                            Button("Learn More…") { model.presentNetworkHelp(for: message.kind) }
                                .buttonStyle(.brand(.secondary))
                        }
                    }
                }
            }
        }
    }

    private func localNetworkCard(access: LocalNetworkAccess) -> some View {
        SectionCard(title: "Local Network Access", systemImage: "network") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if access != .unknown {
                    Image(systemName: access == .granted ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(access == .granted ? Brand.live : Brand.recording)
                        .accessibilityHidden(true)
                }
                Text(OnboardingContent.localNetworkStatus(access, lastCheck: lastCheck))
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if access == .denied {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(OnboardingContent.localNetworkFixSteps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)")
                    }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            }
            if isChecking {
                Text(OnboardingContent.localNetworkChecking)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(access == .denied ? "Check Again" : "Check Access") {
                    Task {
                        isChecking = true
                        lastCheck = await model.checkLocalNetworkAccess()
                        isChecking = false
                    }
                }
                .buttonStyle(.brand(access == .denied ? .primary : .secondary))
                .disabled(isChecking)
                if access == .denied, let url = OnboardingContent.privacySettingsURL {
                    Button("Open Privacy & Security Settings…") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.brand(.secondary))
                }
                if isChecking { ProgressView().controlSize(.small) }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct VPNStatusLabel: View {
    let isProblem: Bool
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isProblem ? Color.orange : Brand.live)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NetworkSettingsTab(model: .preview(), showWebhook: {})
        .frame(width: 740, height: 620)
        .preferredColorScheme(.dark)
}
