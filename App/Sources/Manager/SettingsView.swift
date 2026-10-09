import AppKit
import BridgeEngine
import BridgeSupport
import SwiftUI

/// The Settings window (⌘, and the sidebar's gear): the home of everything that is app-wide, one tab per area —
/// General (login item, keep awake, welcome guide), HomeKit (the bridge and its accessories), Network (Local Network
/// access, ports, this Mac's addresses), Webhook, Privacy (setup reports, camera profiles), Diagnostics (log level,
/// export, data folder), Backup and About. Per-camera options stay on the camera's page; the HomeKit tab links there.
///
/// The window follows the brand: a solid dark canvas, cards, amber accents. The toolbar tabs are the system's, and the
/// last tab used is restored.
struct SettingsView: View {
    let model: AppModel
    @AppStorage(SettingsTab.storageKey) private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            Tab(SettingsTab.general.title, systemImage: SettingsTab.general.symbol, value: SettingsTab.general) {
                GeneralSettingsTab(model: model)
            }
            Tab(SettingsTab.homeKit.title, systemImage: SettingsTab.homeKit.symbol, value: SettingsTab.homeKit) {
                HomeKitSettingsTab(model: model)
            }
            Tab(SettingsTab.network.title, systemImage: SettingsTab.network.symbol, value: SettingsTab.network) {
                NetworkSettingsTab(model: model, showWebhook: { tab = .webhook })
            }
            Tab(SettingsTab.webhook.title, systemImage: SettingsTab.webhook.symbol, value: SettingsTab.webhook) {
                WebhookSettingsTab(model: model)
            }
            Tab(SettingsTab.privacy.title, systemImage: SettingsTab.privacy.symbol, value: SettingsTab.privacy) {
                PrivacySettingsTab(model: model)
            }
            Tab(SettingsTab.diagnostics.title, systemImage: SettingsTab.diagnostics.symbol, value: SettingsTab.diagnostics) {
                DiagnosticsSettingsTab(model: model)
            }
            Tab(SettingsTab.backup.title, systemImage: SettingsTab.backup.symbol, value: SettingsTab.backup) {
                BackupSettingsTab(model: model)
            }
            Tab(SettingsTab.about.title, systemImage: SettingsTab.about.symbol, value: SettingsTab.about) {
                SettingsPage { AboutView() }
            }
        }
        .frame(width: 740, height: 640)
        .background { BrandCanvas() }
        // The brand look is dark, as in the manager window.
        .preferredColorScheme(.dark)
        .tint(Brand.amber)
        .overlay(alignment: .bottom) { SettingsNotice(text: model.notice) }
        .onAppear {
            model.refreshLoginItemStatus()   // changed in System Settings › General › Login Items meanwhile
            model.refreshCameraProfileStatus()
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    let model: AppModel

    var body: some View {
        SettingsPage {
            SectionCard(title: "Startup", systemImage: "power") {
                SettingToggleRow(title: "Launch at Login",
                                 detail: "Start Camera Bridge when you log in so your cameras stay in the Home app.",
                                 isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                switch model.loginItemStatus {
                case .requiresApproval:
                    SettingProblem(text: String(localized: "Allow Camera Bridge in System Settings › General › Login Items.")) {
                        Button("Open Login Items…") { model.openLoginItemsSettings() }
                            .buttonStyle(.brand(.secondary))
                    }
                case .unavailable:
                    SettingProblem(String(localized: "Move Camera Bridge to the Applications folder to launch it at login."))
                case .enabled, .disabled:
                    EmptyView()
                }
                SettingDivider()
                SettingToggleRow(title: "Keep Mac Awake",
                                 detail: "Prevents idle sleep so cameras keep reaching the Home app. Closing a laptop’s lid still puts it to sleep.",
                                 isOn: Binding(get: { model.keepMacAwake }, set: { on in Task { await model.setKeepMacAwake(on) } }))
            }

            SectionCard(title: "Dock and Menu Bar", systemImage: "menubar.dock.rectangle") {
                SettingToggleRow(title: "Show in Dock",
                                 detail: "Camera Bridge appears in the Dock and the ⌘-Tab app switcher. Clicking its Dock icon opens the window.",
                                 isOn: Binding(get: { model.presence.showInDock }, set: { model.setPresence(.dock, to: $0) }))
                    .disabled(!model.presence.canTurnOff(.dock) && model.presence.showInDock)
                SettingDivider()
                SettingToggleRow(title: "Show in Menu Bar",
                                 detail: "The menu bar icon shows the bridge’s status, and its menu pauses or resumes the bridge.",
                                 isOn: Binding(get: { model.presence.showInMenuBar }, set: { model.setPresence(.menuBar, to: $0) }))
                    .disabled(!model.presence.canTurnOff(.menuBar) && model.presence.showInMenuBar)
                SettingNote("Camera Bridge needs to be in the Dock or the menu bar.")
                SettingDivider()
                SettingRow(title: "Camera Bridge Window",
                           detail: "Cameras, the Sensors Bridge and diagnostics.") {
                    Button("Open Camera Bridge") { model.showManager() }
                        .buttonStyle(.brand(.secondary))
                }
            }

            UpdatesCard()

            SectionCard(title: "Welcome Guide", systemImage: "hand.wave") {
                SettingRow(title: "Revisit the Guide",
                           detail: "What Camera Bridge needs: a home hub, iCloud+ for recording, and Local Network access.") {
                    Button("Show Welcome Guide…") { model.presentOnboarding() }
                        .buttonStyle(.brand(.secondary))
                }
            }
        }
    }
}

/// Settings › General › Updates: Camera Bridge is free and updates itself with Sparkle (a signed, notarized download from the
/// project's GitHub Releases, listed in the appcast on the website).
private struct UpdatesCard: View {
    @Environment(\.appUpdater) private var updater

    var body: some View {
        @Bindable var updater = updater
        SectionCard(title: "Updates", systemImage: "arrow.triangle.2.circlepath") {
            SettingRow(title: "Camera Bridge Updates",
                       detail: "Camera Bridge is free. New versions are downloaded from camera-bridge.app, checked against a signature and installed when you agree.") {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .buttonStyle(.brand(.secondary))
                    .disabled(!updater.canCheckForUpdates)
            }
            SettingDivider()
            SettingToggleRow(title: "Check Automatically",
                             detail: "Look for a new version about once a day. The check asks the website for a list of versions and sends only the app’s name and version.",
                             isOn: $updater.automaticallyChecksForUpdates)
                .disabled(!updater.isAvailable)
            if let reason = updater.unavailableReason {
                SettingNote(LocalizedStringKey(reason))
            }
        }
    }
}

// MARK: - HomeKit

/// The bridge as a whole and the accessories it publishes. What belongs to one camera (its code, live view and recording
/// options, motion source, sensors, pairing reset) stays on its page: each row opens it.
private struct HomeKitSettingsTab: View {
    let model: AppModel

    var body: some View {
        let engine = model.engine
        SettingsPage {
            SectionCard(title: "Bridge", systemImage: "house") {
                SettingRow(verbatimTitle: String(localized: "Status"), verbatimDetail: SettingsText.cameraCount(engine.configurations)) {
                    HStack(spacing: 10) {
                        BridgeStateBadge(state: engine.state)
                        Button(StatusText.pauseResumeTitle(engine.state)) { Task { await model.toggleBridgeRunning() } }
                            .buttonStyle(.brand(.secondary))
                    }
                }
                SettingNote("Pausing stops every camera’s accessory and the sensors bridge, so the Home app shows them as not responding. Your cameras and pairings are kept.")
            }

            SectionCard(title: "Accessories in the Home App", systemImage: "homekit") {
                if engine.configurations.isEmpty {
                    SettingRow(title: "No cameras yet", detail: "Each camera you add appears in the Home app as its own accessory.") {
                        Button("Add Camera…") { model.showAddCamera() }
                            .buttonStyle(.brand(.primary))
                    }
                } else {
                    ForEach(Array(engine.configurations.enumerated()), id: \.element.id) { index, camera in
                        if index > 0 { SettingDivider() }
                        SettingRow(verbatimTitle: camera.name,
                                   verbatimDetail: SettingsText.accessorySubtitle(for: camera, status: model.status(for: camera.id))) {
                            Button("Open") { model.showManager(selecting: .camera(camera.id)) }
                                .buttonStyle(.brand(.secondary))
                                .accessibilityLabel(Text("Open \(camera.name)"))
                        }
                    }
                }
                if !engine.configurations.isEmpty { SettingDivider() }
                SettingRow(verbatimTitle: String(localized: "Camera Bridge Sensors"),
                           verbatimDetail: SettingsText.sensorsBridgeSubtitle(engine.sensorsBridge)) {
                    Button("Open") { model.showManager(selecting: .sensorsBridge) }
                        .buttonStyle(.brand(.secondary))
                        .accessibilityLabel(Text("Open Camera Bridge Sensors"))
                }
                SettingNote("The sensors bridge adds people, vehicles, day and night and similar signals to the Home app, for the cameras that provide them.")
            }

            SectionCard(title: "Per Camera", systemImage: "video") {
                SettingNote("A camera’s setup code, live view and recording streams and quality, motion source, sensors, audio and pairing reset are on its page. Open a camera above, or choose it in the sidebar. There are no app-wide defaults for new cameras: the Add Camera wizard sets each one up, and its page adjusts it afterwards.")
            }
        }
    }
}

/// "Running", "Paused", … as a colored capsule with a glyph (the color is never the only signal).
private struct BridgeStateBadge: View {
    let state: EngineState

    var body: some View {
        let style = Self.style(for: state)
        Label(StatusText.engineState(state), systemImage: style.symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(style.tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background { Capsule().fill(style.tint.opacity(0.16)) }
            .overlay { Capsule().strokeBorder(style.tint.opacity(0.35), lineWidth: 1) }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(StatusText.engineState(state)))
    }

    private static func style(for state: EngineState) -> (symbol: String, tint: Color) {
        switch state {
        case .running: ("dot.radiowaves.left.and.right", Brand.live)
        case .starting: ("arrow.triangle.2.circlepath", Brand.warning)
        case .paused: ("pause.circle", Brand.warning)
        case .stopped: ("stop.circle", Brand.neutral)
        case .failed: ("exclamationmark.triangle.fill", Brand.recording)
        }
    }
}

#Preview {
    SettingsView(model: .preview())
}
