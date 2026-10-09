import AppKit
import BridgeEngine
import BridgeSupport
import CameraAdapters
import HAPCamera
import MediaCore
import SwiftUI

/// One camera as a dashboard: hero (snapshot, name, IP, actions) and stat tiles above a tab strip — Overview (Apple Home,
/// HomeKit Readiness, audio, camera settings) · Streams · Recording · Motion & Events (motion, recent events, sensors,
/// webhook) · Advanced (name, connection, device info, log, remove). Each fact appears once. Edits go to a `CameraEditor`
/// draft, applied to the engine once they pause (and when the view goes away); engine updates merge into the draft
/// without dropping edits in progress.
struct CameraDetailView: View {
    let model: AppModel
    let cameraID: UUID
    /// The engine's configuration (source of truth).
    let configuration: CameraConfiguration
    @State private var editor: CameraEditor
    @State private var readiness = ReadinessState()
    @State private var showingCameraSettings = false
    /// Whether the readiness checklist is open, and the scroll the last tap on the dashboard asked for (its serial keeps counting
    /// across taps, so the same destination twice scrolls twice).
    @State private var isChecklistExpanded = false
    @State private var page = CameraPageState()
    /// The detail column is wide enough for the two-column dashboard and two-column tab content.
    @State private var isWide = false
    /// The last tab used is remembered (also across cameras).
    @AppStorage("cameraDetailTab") private var tab: CameraTab = .overview

    init(model: AppModel, cameraID: UUID, configuration: CameraConfiguration) {
        self.model = model
        self.cameraID = cameraID
        self.configuration = configuration
        self.editor = CameraEditor(configuration: configuration,
                                   apply: { [model] configuration, password, showsFailure in
                                       try await model.applyCameraUpdate(configuration, password: password, showsFailure: showsFailure)
                                   },
                                   current: { [model] in model.configuration(for: cameraID) })
    }

    var body: some View {
        @Bindable var editor = editor
        if let status = model.status(for: cameraID) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        CameraDashboard(model: model, cameraID: cameraID, status: status, configuration: configuration, readiness: readiness,
                                        isWide: isWide, tab: $tab, showingCameraSettings: $showingCameraSettings, navigate: navigate)
                        tabContent(status: status, editor: editor)
                            .id(CameraPageAnchor.tabContent)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                    // Content never grows past 1500 pt; the margins beyond it are canvas.
                    .frame(maxWidth: 1_500)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: page.scrollRequest) { _, request in
                    guard let request else { return }
                    // After the tab's content (and the open checklist) is laid out.
                    Task { @MainActor in
                        withAnimation(.smooth) { proxy.scrollTo(request.anchor, anchor: .top) }
                    }
                }
            }
            .onGeometryChange(for: Bool.self, of: { $0.size.width >= CameraDetailView.wideThreshold }) { isWide = $0 }
            .navigationTitle(status.name)
            #if DEBUG
            // `-demoOpenSheet optimize|cameraSettings` (UI review, screenshots): opens that sheet once the page and its readiness are up.
            .task {
                guard let sheet = UserDefaults.standard.string(forKey: "demoOpenSheet") else { return }
                try? await Task.sleep(for: .seconds(3))
                switch sheet {
                case "optimize": readiness.showingOptimizeSheet = true
                case "cameraSettings": showingCameraSettings = true
                default: break
                }
            }
            // `-cameraPageDestination readinessChecklist` (UI review): navigates as a tap on the dashboard would, once the page is up.
            .task {
                guard let name = UserDefaults.standard.string(forKey: "cameraPageDestination"),
                      let destination = CameraPageDestination.allCases.first(where: { "\($0)" == name }) else { return }
                try? await Task.sleep(for: .seconds(2))
                navigate(destination)
            }
            #endif
            .task { if configuration.hasCameraInterface { await readiness.load(model: model, cameraID: cameraID) } }   // opening the page: no new ONVIF login after a refusal
            .sheet(isPresented: $showingCameraSettings) {
                CameraSettingsSheet(model: model, cameraID: cameraID, name: status.name)
            }
            .sheet(isPresented: $readiness.showingOptimizeSheet, onDismiss: { Task { await readiness.load(model: model, cameraID: cameraID, recheck: true) } }) {
                HomeKitOptimizeSheet(model: model, cameraID: cameraID, name: status.name,
                                     report: readiness.report ?? HomeKitReadinessReport(checks: []), endpoint: configuration.endpoint,
                                     reload: { await readiness.load(model: model, cameraID: cameraID, recheck: true) })
            }
            .onChange(of: configuration) { _, updated in editor.engineDidPublish(updated) }
            .onDisappear {
                // Switching cameras within the quiet period must not drop the edit.
                guard editor.hasUnsavedEdits else { return }
                Task { await editor.applyPendingEdits() }
            }
        } else {
            // Configured, but the engine hasn't published its status yet (the bridge hasn't started).
            ContentUnavailableView("Waiting for the Bridge", systemImage: "video",
                                   description: Text("This camera’s details appear once the bridge has started."))
        }
    }

    /// Width of the detail column from which the dashboard and the tab content use two columns.
    static let wideThreshold: CGFloat = 1_200

    /// A tap on a stat tile or the Apple Home card: selects the tab, opens the checklist when that is the destination and
    /// scrolls to what it shows (`CameraPageState.show`).
    private func navigate(_ destination: CameraPageDestination) {
        page.tab = tab   // the tab strip changes it too (and it is remembered across launches)
        page.isChecklistExpanded = isChecklistExpanded
        page.show(destination)
        tab = page.tab
        isChecklistExpanded = page.isChecklistExpanded
    }

    /// The selected tab as grouped forms: one column, or two side by side when wide (each tab names what goes left and
    /// what goes right).
    @ViewBuilder private func tabContent(status: CameraStatus, editor: CameraEditor) -> some View {
        @Bindable var editor = editor
        switch tab {
        case .overview:
            TabColumns(isWide: isWide) {
                PairingSection(accessoryName: status.name, isPaired: status.isPaired, setupCode: status.setupCode, setupURI: status.setupURI,
                               blocker: model.pairingBlocker(for: cameraID),
                               resolve: { action in Task { await model.resolve(action) } },
                               onReset: { Task { await model.resetPairing(cameraID: cameraID) } })
                if configuration.hasCameraInterface {
                    HomeKitReadinessSection(readiness: readiness, isChecklistExpanded: $isChecklistExpanded)
                }
            } right: {
                AudioSection(draft: $editor.draft, capabilities: configuration.capabilities)
                if configuration.hasCameraInterface {
                    CameraSettingsLinkSection(endpoint: configuration.endpoint, showingSettings: $showingCameraSettings)
                }
            }
        case .streams:
            TabColumns(isWide: isWide) {
                StreamInfoSection(status: status)
                TimestampOverlaySection(model: model, cameraID: cameraID, configuration: configuration, draft: $editor.draft)
            } right: {
                LiveViewSection(draft: $editor.draft, status: status)
            }
        case .recording:
            TabColumns(isWide: isWide) {
                RecordingSection(draft: $editor.draft)
            } right: {
                RecordingStatusSection(status: status)
            }
        case .motion:
            TabColumns(isWide: isWide) {
                MotionSection(draft: $editor.draft,
                              motionSource: Binding(get: { editor.draft.motionSource }, set: { editor.chooseMotionSource($0) }),
                              availableSources: availableMotionSources, webhookEnabled: model.engine.settings.webhookEnabled,
                              cameraEvents: StatusText.cameraEvents(status),
                              testBlocker: model.testMotionBlocker(for: cameraID),
                              onTest: { Task { await model.triggerTestMotion(cameraID: cameraID) } })
                SensorsSection(draft: $editor.draft, capabilities: configuration.capabilities)
            } right: {
                RecentEventsSection(events: RecentEvents.newestFirst(in: status))
                WebhookSection(cameraID: cameraID,
                               urls: WebhookSettings.cameraURLs(host: WebhookSettings.localHostName, port: model.engine.settings.webhookPort,
                                                                cameraID: cameraID, kind: configuration.kind),
                               webhookEnabled: model.engine.settings.webhookEnabled,
                               notice: model.webhookNotice(for: cameraID),
                               retry: { Task { await model.retryWebhook() } })
            }
        case .advanced:
            TabColumns(isWide: isWide) {
                CameraSection(model: model, editor: editor, cameraID: cameraID, status: status, configuration: configuration)
            } right: {
                RemoveSection(model: model, cameraID: cameraID, name: status.name)
            }
        }
    }

    private var availableMotionSources: [MotionSource] {
        let hasMotionEvents = configuration.capabilities?.events.contains(.motion) ?? true
        return MotionSource.allCases.filter { $0 != .cameraEvents || hasMotionEvents || configuration.motionSource == .cameraEvents }
    }
}

/// Grouped forms for one tab. Wide: `left` and `right` side by side, top aligned, each its own form of section cards.
/// Narrow: both in one form.
private struct TabColumns<Left: View, Right: View>: View {
    let isWide: Bool
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        if isWide {
            HStack(alignment: .top, spacing: 20) {
                form { left }
                form { right }
            }
        } else {
            form { left; right }
        }
    }

    private func form<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form {
            Group { content() }
                .listRowBackground(BrandRowBackground())
                .headerProminence(.increased)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(maxWidth: .infinity)
        // The grouped form insets its cards; pull them back so the cards line up with the dashboard's edges.
        .padding(.horizontal, -20)
    }
}

/// The camera's latest events (motion, doorbell, detections) from the engine's event history, newest first.
private struct RecentEventsSection: View {
    let events: [CameraEventRecord]

    var body: some View {
        Section("Recent Events") {
            if events.isEmpty {
                Text("No recent events")
                    .foregroundStyle(.secondary)
            }
            ForEach(events) { event in
                // Redrawn every second, like Last Event: a formatted date doesn't update by itself.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LabeledContent {
                        Text(StatusText.timeAgo(event.date, now: context.date))
                            .monospacedDigit()
                    } label: {
                        Text(event.name)
                    }
                }
            }
        }
    }
}

/// "Camera Settings": the camera's own web configuration page (opened in the default browser; never with
/// credentials in the URL) and a button to the ONVIF-backed Camera Settings sheet (presented by the camera page).
private struct CameraSettingsLinkSection: View {
    let endpoint: CameraEndpoint
    @Binding var showingSettings: Bool

    private var webPageURLString: String {
        "\(endpoint.useHTTPS ? "https" : "http")://\(endpoint.host):\(endpoint.httpPort)/"
    }

    var body: some View {
        Section {
            LabeledContent("Address") {
                HStack {
                    Text(webPageURLString)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(webPageURLString, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy Address")
                }
            }
            Button("Open Camera Web Page") {
                guard let url = URL(string: webPageURLString) else { return }
                NSWorkspace.shared.open(url)
            }
            Button("Camera Settings…") { showingSettings = true }
        } header: {
            Text("Camera Settings")
        } footer: {
            Text("Open the camera’s own web page for settings Camera Bridge doesn’t offer, or use Camera Settings… for standard ONVIF video and image controls.")
        }
    }
}

/// What the camera sends: main and sub stream, as measured.
private struct StreamInfoSection: View {
    let status: CameraStatus

    var body: some View {
        Section {
            if let main = status.mainStreamInfo {
                LabeledContent("Main Stream", value: StreamsSection.describe(main))
            }
            if let sub = status.subStreamInfo {
                LabeledContent("Sub Stream", value: StreamsSection.describe(sub))
            }
            if status.mainStreamInfo == nil, status.subStreamInfo == nil {
                Text("No picture yet.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Camera Streams")
        }
    }
}

/// Live view stream and quality, and who is watching.
private struct LiveViewSection: View {
    @Binding var draft: CameraConfiguration
    let status: CameraStatus

    var body: some View {
        Section {
            Picker("Live View Stream", selection: $draft.liveStreamMode) {
                ForEach(LiveStreamMode.allCases, id: \.self) { mode in
                    Text(StreamsSection.title(mode)).tag(mode)
                }
            }
            Picker("Live View Quality", selection: $draft.liveQualityMode) {
                ForEach(LiveQualityMode.allCases, id: \.self) { mode in
                    Text(StreamsSection.title(mode)).tag(mode)
                }
            }
            if draft.liveQualityMode == .matchHomeKitRequest {
                Picker("Maximum Bit Rate", selection: $draft.liveMaxBitrateOverride) {
                    ForEach(MaxBitrateOverride.allCases, id: \.self) { override in
                        Text(StreamsSection.title(override)).tag(override)
                    }
                }
            }
            if status.liveSessions.isEmpty {
                Text("No one is watching right now.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(status.liveSessions.enumerated()), id: \.offset) { index, session in
                    LabeledContent("Viewer \(index + 1)", value: StreamsSection.describe(session))
                }
            }
        } header: {
            Text("Live View")
        } footer: {
            Text("Original Quality sends the camera’s own H.264 untouched when possible, ignoring what the Home app asked for; it falls back to matching the request for HEVC cameras or ones that use B-frames."
                 + (draft.timestampOverlay.enabled ? " " + String(localized: "The Camera Bridge timestamp is on, so live view always uses the Mac’s video encoder.") : ""))
        }
    }
}

/// Titles and descriptions shared by the stream and recording sections.
private enum StreamsSection {
    static func title(_ mode: LiveStreamMode) -> String {
        switch mode {
        case .automatic: String(localized: "Automatic")
        case .alwaysMain: String(localized: "Always Main Stream")
        case .alwaysSub: String(localized: "Always Sub Stream")
        }
    }

    static func title(_ mode: LiveQualityMode) -> String {
        switch mode {
        case .matchHomeKitRequest: String(localized: "Match Home App Request")
        case .originalQuality: String(localized: "Original Quality")
        }
    }

    static func title(_ override: MaxBitrateOverride) -> String {
        switch override {
        case .auto: String(localized: "Automatic")
        case .mbps1: String(localized: "1 Mbps")
        case .mbps2: String(localized: "2 Mbps")
        case .mbps4: String(localized: "4 Mbps")
        case .mbps6: String(localized: "6 Mbps")
        case .mbps8: String(localized: "8 Mbps")
        }
    }

    static func describe(_ info: SourceStreamInfo) -> String {
        let codec = info.codec == "h264" ? "H.264" : "H.265"
        var text = "\(codec) \(info.width)×\(info.height)"
        if let fps = info.fps { text += " · \(Int(fps.rounded())) fps" }
        return text
    }

    static func describe(_ session: LiveSessionStatus) -> String {
        var text = session.usesSubStream ? String(localized: "Sub stream") : String(localized: "Main stream")
        text += session.isPassthrough ? String(localized: ", original") : String(localized: ", transcoded")
        if let resolution = session.resolution { text += " · \(resolution.width)×\(resolution.height)" }
        if let kbps = session.bitrateKbps { text += " · \(kbps) kbit/s" }
        return text
    }
}

/// Recording stream and quality (HomeKit Secure Video).
private struct RecordingSection: View {
    @Binding var draft: CameraConfiguration

    var body: some View {
        Section {
            Picker("Recording Stream", selection: $draft.recordingStreamMode) {
                ForEach(RecordingStreamMode.allCases, id: \.self) { mode in
                    Text(RecordingSection.title(mode)).tag(mode)
                }
            }
            Picker("Recording Quality", selection: $draft.recordingQualityMode) {
                ForEach(RecordingQualityMode.allCases, id: \.self) { mode in
                    Text(RecordingSection.title(mode)).tag(mode)
                }
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("HomeKit Secure Video records motion clips. Changing the recording stream or quality changes what the Home app thinks this camera supports; you may need to turn recording off and back on for this camera in the Home app afterward."
                 + (draft.timestampOverlay.enabled ? " " + String(localized: "The Camera Bridge timestamp is on, so recordings always use the Mac’s video encoder.") : ""))
        }
    }

    static func title(_ mode: RecordingStreamMode) -> String {
        switch mode {
        case .automatic: String(localized: "Automatic (Main Stream)")
        case .main: String(localized: "Main Stream")
        case .sub: String(localized: "Sub Stream")
        }
    }

    static func title(_ mode: RecordingQualityMode) -> String {
        switch mode {
        case .matchHubRequest: String(localized: "Match Home Hub Request")
        case .originalWhenPossible: String(localized: "Original When Possible")
        }
    }

    static func describe(_ session: RecordingSessionStatus) -> String {
        var text = session.usesSubStream ? String(localized: "Sub stream") : String(localized: "Main stream")
        if let resolution = session.resolution { text += " · \(resolution.width)×\(resolution.height)" }
        if let kbps = session.bitrateKbps { text += " · \(kbps) kbit/s" }
        return text
    }
}

/// What is recording now.
private struct RecordingStatusSection: View {
    let status: CameraStatus

    var body: some View {
        Section {
            if let recording = status.recordingSession {
                LabeledContent("Recording Now", value: RecordingSection.describe(recording))
            } else {
                Text(status.recordingEnabled ? String(localized: "Recording is on. Not recording right now.")
                                             : String(localized: "Recording is off. Turn it on for this camera in the Home app."))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Status")
        }
    }
}

private struct MotionSection: View {
    @Binding var draft: CameraConfiguration
    /// Through `CameraEditor.chooseMotionSource`: sensors the new source no longer offers are turned off.
    @Binding var motionSource: MotionSource
    let availableSources: [MotionSource]
    let webhookEnabled: Bool
    let cameraEvents: String
    /// Why Test Motion is off (the accessory isn't published), else nil.
    let testBlocker: PairingBlocker?
    let onTest: () -> Void

    var body: some View {
        Section {
            LabeledContent("Camera Events", value: cameraEvents)
            Picker("Motion Source", selection: $motionSource) {
                ForEach(availableSources, id: \.self) { source in
                    Text(StatusText.motionSource(source)).tag(source)
                }
            }
            if draft.motionSource == .softMotion {
                Slider(value: $draft.motionSensitivity, in: 0...1) {
                    Text("Sensitivity")
                } minimumValueLabel: {
                    Text("Low")
                } maximumValueLabel: {
                    Text("High")
                }
            }
            if draft.motionSource == .webhook {
                Text(webhookEnabled ? String(localized: "The Webhook section below lists this camera’s URLs.")
                                    : String(localized: "Turn on the webhook in Settings."))
                    .foregroundStyle(.secondary)
            }
            MotionHoldRow(seconds: $draft.motionHoldSeconds)
            LabeledContent {
                Button("Test Motion", action: onTest)
                    .disabled(testBlocker != nil)
            } label: {
                Text("Test")
                Text(testBlocker.map(StatusText.testMotionUnavailable) ?? StatusText.testMotionExplanation)
            }
        } header: {
            Text("Motion")
        } footer: {
            Text(StatusText.motionSourceDetail(draft.motionSource) + " " + String(localized: "Motion starts HomeKit Secure Video recordings."))
        }
    }
}

/// The camera's ID and webhook URLs, whatever its motion source: the webhook takes every camera's events (a doorbell
/// that reports no button of its own rings only through it).
private struct WebhookSection: View {
    let cameraID: UUID
    let urls: [WebhookSettings.EventURL]
    let webhookEnabled: Bool
    /// The webhook isn't listening (`AppModel.webhookNotice`): shown next to the URLs, with Try Again.
    let notice: String?
    let retry: () -> Void

    var body: some View {
        Section {
            LabeledContent("Camera ID") {
                Text(cameraID.uuidString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            if webhookEnabled, let notice {
                LabeledContent {
                    Button("Try Again", action: retry)
                } label: {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if webhookEnabled {
                ForEach(urls) { entry in
                    LabeledContent(WebhookSettings.eventTitle(entry.event)) {
                        Text(entry.url)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("Turn on the webhook in Settings to report this camera’s motion, doorbell rings or detections from Home Assistant, Frigate or another system.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Webhook")
        } footer: {
            Text("Send a POST request with the webhook token from Settings. A detection appears in the Home app when its sensor is turned on under Sensors (offered when the motion source is Webhook or the camera detects it too).")
        }
    }
}

private struct SensorsSection: View {
    @Binding var draft: CameraConfiguration
    let capabilities: CameraCapabilities?

    var body: some View {
        // Every sensor the engine publishes has its toggle (also with unknown capabilities).
        let sensors = SensorKind.shown(in: capabilities, motionSource: draft.motionSource, options: draft.sensors)
        Section {
            if sensors.isEmpty {
                Text("This camera doesn’t report detections the sensors bridge can show. With Motion › Webhook, people, vehicles, animals and packages reported to the webhook can.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sensors) { kind in
                Toggle(isOn: $draft.sensors[dynamicMember: kind.keyPath]) {
                    Label {
                        Text(kind.title)
                        Text(kind.isFromWebhook(in: capabilities, motionSource: draft.motionSource)
                             ? String(localized: "From the webhook · \(kind.homeAccessory)") : kind.homeAccessory)
                    } icon: {
                        Image(systemName: kind.symbol)
                    }
                }
            }
        } header: {
            Text("Sensors")
        } footer: {
            Text("Sensors appear on the Camera Bridge Sensors bridge in the Home app. They never start recordings.")
        }

    }
}

private struct AudioSection: View {
    @Binding var draft: CameraConfiguration
    let capabilities: CameraCapabilities?

    var body: some View {
        Section("Audio") {
            Toggle("Camera Audio", isOn: $draft.audioEnabled)
            if capabilities?.twoWayAudio == true {
                Toggle(isOn: $draft.twoWayAudio) {
                    Text("Two-Way Audio")
                    Text("Talk through the camera’s speaker from the Home app.")
                }
            }
        }
    }
}

/// Name, Enabled, then the rarely needed parts in disclosure groups: connection (address, sign-in), device info, log.
private struct CameraSection: View {
    let model: AppModel
    let editor: CameraEditor
    let cameraID: UUID
    let status: CameraStatus
    let configuration: CameraConfiguration
    @State private var editingPassword = false
    @State private var editingConnection: CameraConnectionEditor?
    @State private var replacingSecret = false

    var body: some View {
        @Bindable var editor = editor
        Section {
            TextField("Name", text: $editor.draft.name)
            Toggle(isOn: $editor.draft.isEnabled) {
                Text("Enabled")
                Text("Turn off to stop streaming without removing the camera from the Home app.")
            }
            if configuration.vendor != .demo {
                DisclosureGroup("Connection") {
                    if configuration.vendor == .go2rtc {
                        // A cloud camera has no address of its own: the helper on this Mac serves it. Its source is the secret.
                        LabeledContent("Service", value: configuration.integration?.service.displayName ?? String(localized: "Cloud camera"))
                        LabeledContent("Source") {
                            Button("Replace Source…") { replacingSecret = true }
                        }
                    } else {
                        LabeledContent(configuration.vendor == .unifi ? "Console" : "Address") {
                            Button("\(editor.draft.endpoint.host) — Change…") {
                                // Checks the camera at the new address with its stored password, then saves it as the same
                                // camera through the form's editor (pending edits included).
                                editingConnection = CameraConnectionEditor(
                                    configuration: editor.draft,
                                    probe: { [model] candidate in try await model.probeConfiguredCamera(candidate) },
                                    save: { [editor] endpoint, main, sub in
                                        try await editor.changeConnection(endpoint: endpoint, mainStreamURL: main, subStreamURL: sub)
                                    })
                            }
                        }
                        if configuration.vendor == .unifi {
                            LabeledContent("API Key") {
                                Button("Replace Key…") { replacingSecret = true }
                            }
                        } else {
                            LabeledContent("Sign-In") {
                                Button("Change Password…") { editingPassword = true }
                            }
                        }
                    }
                }
            }
            DisclosureGroup("Device Info") {
                if !editor.draft.manufacturer.isEmpty { LabeledContent("Manufacturer", value: editor.draft.manufacturer) }
                if !editor.draft.model.isEmpty { LabeledContent("Model", value: editor.draft.model) }
                if !editor.draft.firmware.isEmpty { LabeledContent("Firmware", value: editor.draft.firmware) }
                if !editor.draft.serialNumber.isEmpty { LabeledContent("Serial Number", value: editor.draft.serialNumber) }
                if let hapPort = status.hapPort { LabeledContent("Accessory Port", value: String(hapPort)) }
            }
            DisclosureGroup("Log") {
                LogView(entries: model.engine.recentLogs, cameraID: cameraID)
                    .frame(minHeight: 220)
            }
        } header: {
            Text("Camera")
        }
        .sheet(isPresented: $editingPassword) {
            PasswordSheet(name: status.name, username: editor.draft.username) { newUsername, password in
                // Through the editor: saves the draft (pending edits included), after any update under way.
                Task { await editor.changeSignIn(username: newUsername, password: password) }
            }
        }
        .sheet(item: $editingConnection) { connection in
            ConnectionSheet(name: status.name, connection: connection)
        }
        .sheet(isPresented: $replacingSecret) {
            SecretReplacementSheet(name: status.name, kind: configuration.vendor == .unifi ? .apiKey : .source) { secret in
                // Through the editor, like a password: saved to the Keychain, and the camera restarts with it.
                Task { await editor.changeSignIn(username: "", password: secret) }
            }
        }
    }
}

/// Last section, destructive and confirmed.
private struct RemoveSection: View {
    let model: AppModel
    let cameraID: UUID
    let name: String
    @State private var confirmingRemoval = false

    var body: some View {
        Section {
            Button("Remove Camera…", role: .destructive) { confirmingRemoval = true }
                .buttonStyle(.brand(.destructive))
        } footer: {
            Text("Removes the camera from Camera Bridge. Remove it from the Home app as well.")
        }
        .confirmationDialog("Remove “\(name)”?", isPresented: $confirmingRemoval) {
            Button("Remove Camera", role: .destructive) {
                Task { await model.removeCamera(id: cameraID) }
            }
        } message: {
            Text("Camera Bridge stops publishing this camera and deletes its saved password. Remove it from the Home app as well.")
        }
    }
}

extension CameraConnectionEditor: Identifiable {}

/// Where the camera is reached: address, ports, HTTPS and stream URLs. Save checks the camera first.
private struct ConnectionSheet: View {
    let name: String
    @Bindable var connection: CameraConnectionEditor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection for “\(name)”")
                .font(.headline)
            Form {
                if connection.showsAddressFields {
                    Section {
                        TextField("Address", text: $connection.host, prompt: Text("192.168.1.20 or camera.local"))
                        TextField(connection.httpPortTitle, value: $connection.httpPort, format: .number.grouping(.never))
                        TextField("RTSP Port", value: $connection.rtspPort, format: .number.grouping(.never))
                        if connection.showsONVIFPort {
                            TextField("ONVIF Port", value: $connection.onvifPort, format: .number.grouping(.never), prompt: Text("Same as HTTP"))
                        }
                        Toggle("Use HTTPS", isOn: $connection.useHTTPS)
                    } footer: {
                        Text("If the camera’s address changed, enter the new one. Stream URLs on the old address follow it.")
                    }
                }
                Section {
                    TextField(connection.showsAddressFields ? "Main Stream (Optional)" : "Main Stream", text: $connection.mainStreamURLText,
                              prompt: Text("rtsp://192.168.1.20:554/stream1"))
                    TextField("Sub Stream (Optional)", text: $connection.subStreamURLText, prompt: Text("rtsp://192.168.1.20:554/stream2"))
                } header: {
                    Text("Streams")
                } footer: {
                    Text("URLs are saved without a user name or password; Change Password… holds the sign-in.")
                }
                if let message = statusMessage {
                    Section {
                        Label(message.text, systemImage: message.symbol)
                            .foregroundStyle(message.isError ? .red : .secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!connection.canEdit)   // the check saves what was entered when it started
            HStack {
                if connection.state == .checking {
                    ProgressView().controlSize(.small)
                    Text("Checking the camera…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Also while checking: the check stops and nothing is saved.
                Button("Cancel", role: .cancel) {
                    connection.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Check and Save") {
                    let saving = connection.startSave()
                    Task { if await saving.value { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!connection.canSave)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .onDisappear { connection.cancel() }   // closed any other way: nothing is saved after it is gone
    }

    private var statusMessage: (text: String, symbol: String, isError: Bool)? {
        if case .failed(let message) = connection.state { return (message, "exclamationmark.triangle.fill", true) }
        if let problem = connection.problem { return (problem, "info.circle", false) }
        return nil
    }
}

/// Updates the camera's user name and password (the password goes to the keychain through the engine).
private struct PasswordSheet: View {
    let name: String
    let onSave: (String, String) -> Void
    @State private var username: String
    @State private var password = ""
    @Environment(\.dismiss) private var dismiss

    init(name: String, username: String, onSave: @escaping (String, String) -> Void) {
        self.name = name
        self.onSave = onSave
        self.username = username
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign-In for “\(name)”")
                .font(.headline)
            Form {
                TextField("User Name", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            Text("The password is stored in your keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(username.trimmingCharacters(in: .whitespacesAndNewlines), password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// How long motion stays on after the last detection (5–300 s).
struct MotionHoldRow: View {
    @Binding var seconds: Int

    var body: some View {
        LabeledContent("Motion Hold") {
            HStack(spacing: 6) {
                Text("\(seconds) s")
                    .monospacedDigit()
                Stepper("Motion Hold", value: $seconds, in: 5...300, step: 5)
                    .labelsHidden()
            }
        }
    }
}

#Preview("Live camera") {
    let model = AppModel.preview()
    let id = model.engine.cameras[0].id
    return CameraDetailView(model: model, cameraID: id, configuration: model.engine.configurations[0])
        .frame(width: 700, height: 900)
}

#Preview("Unpaired doorbell") {
    let model = AppModel.preview()
    let id = model.engine.cameras[1].id
    return CameraDetailView(model: model, cameraID: id, configuration: model.engine.configurations[1])
        .frame(width: 700, height: 900)
}
