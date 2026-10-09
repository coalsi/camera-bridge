import AppKit
import BridgeEngine
import CameraAdapters
import SwiftUI

/// Add Camera sheet: Discover → Connect → Check → Camera or Doorbell → Motion → Sensors and Audio → Review → QR code.
struct AddCameraWizard: View {
    let model: AppModel
    @State private var wizard: AddCameraWizardModel
    @Environment(\.dismiss) private var dismiss

    /// `wizard` lets previews and screenshot capture start from a prepared state.
    init(model: AppModel, wizard: AddCameraWizardModel? = nil) {
        self.model = model
        self.wizard = wizard ?? AddCameraWizardModel(service: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            WizardHeader(title: wizard.step.title, symbol: Self.symbol(for: wizard.step), stepNumber: wizard.stepNumber,
                         stepCount: wizard.stepCount, isFinished: wizard.step == .pairing)
            WizardPage(wizard: wizard, model: model)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 10) {
                if wizard.step != .pairing {
                    Button("Cancel", role: .cancel) {
                        wizard.cancel()
                        dismiss()
                    }
                    .buttonStyle(.brand(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .disabled(wizard.addState == .adding)
                }
                Spacer()
                if wizard.step != .cameraType && wizard.step != .pairing {
                    Button("Back") { wizard.goBack() }
                        .buttonStyle(.brand(.secondary))
                        .disabled(!wizard.canGoBack)
                }
                Button(wizard.continueTitle) {
                    if wizard.step == .pairing {
                        dismiss()
                    } else {
                        wizard.startForward()
                    }
                }
                .buttonStyle(.brand(.primary, large: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!wizard.canContinue)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color.black.opacity(0.25))
        }
        .frame(width: 640, height: 600)
        .background { BrandCanvas() }
        .preferredColorScheme(.dark)   // the brand look is dark
        .tint(Brand.amber)
        .interactiveDismissDisabled(wizard.addState == .adding)
        .onDisappear { wizard.cancel() }   // however the sheet goes away, stop probing the camera
    }

    private static func symbol(for step: WizardStep) -> String {
        switch step {
        case .cameraType: "video.badge.plus"
        case .discover: "dot.radiowaves.left.and.right"
        case .connect: "key.fill"
        case .probe: "checkmark.shield.fill"
        case .kind: "video.fill"
        case .motion: "figure.walk.motion"
        case .features: "sensor.fill"
        case .summary: "list.bullet.clipboard.fill"
        case .pairing: "qrcode"
        }
    }
}

/// Big step header: a gradient glyph tile, the step's title, "Step N of M" and a gradient progress bar.
private struct WizardHeader: View {
    let title: String
    let symbol: String
    let stepNumber: Int
    let stepCount: Int
    let isFinished: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Brand.onAmber)
                    .frame(width: 48, height: 48)
                    .background(Brand.amber, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .accessibilityAddTraits(.isHeader)
                    if !isFinished {
                        Text("Step \(stepNumber) of \(stepCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("Almost done")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            WizardProgressBar(fraction: isFinished ? 1 : Double(stepNumber) / Double(max(stepCount, 1)))
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }
}

private struct WizardProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Brand.amber).frame(width: max(8, geometry.size.width * fraction))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

private struct WizardPage: View {
    let wizard: AddCameraWizardModel
    let model: AppModel

    var body: some View {
        switch wizard.step {
        case .cameraType: CameraTypePage(wizard: wizard)
        case .discover: DiscoverPage(wizard: wizard)
        case .connect: ConnectPage(wizard: wizard)
        case .probe: ProbePage(wizard: wizard, model: model)
        case .kind: KindPage(wizard: wizard)
        case .motion:
            MotionPage(wizard: wizard,
                       webhookURL: WebhookSettings.exampleURL(host: WebhookSettings.localHostName, port: model.engine.settings.webhookPort,
                                                              cameraID: wizard.cameraID, event: "motion"),
                       webhookEnabled: model.engine.settings.webhookEnabled)
        case .features: FeaturesPage(wizard: wizard)
        case .summary:
            SummaryPage(wizard: wizard, doorbellWebhookURL: doorbellWebhookURL, webhookEnabled: model.engine.settings.webhookEnabled) { existing in
                // Close the wizard and show the camera that is already set up (Change Address… is on its page).
                wizard.cancel()
                model.isAddCameraPresented = false
                model.showManager(selecting: .camera(existing.id))
            }
        case .pairing: PairingPage(wizard: wizard, model: model, doorbellWebhookURL: doorbellWebhookURL)
        }
    }

    /// Where a doorbell without a button of its own rings (`ringsThroughWebhook`).
    private var doorbellWebhookURL: String {
        WebhookSettings.exampleURL(host: WebhookSettings.localHostName, port: model.engine.settings.webhookPort, cameraID: wizard.cameraID,
                                   event: "doorbell")
    }
}

// MARK: - Pages

private struct DiscoverPage: View {
    @Bindable var wizard: AddCameraWizardModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Camera Type", value: wizard.cameraType.title)
            } footer: {
                Text(typeFooter)
            }

            if wizard.vendorChoice != .demo && wizard.vendorChoice != .rtspURL {
                Section {
                    if wizard.discovered.isEmpty && wizard.isLocalNetworkDenied && !wizard.isDiscovering {
                        LocalNetworkDeniedRow()
                    } else if wizard.discovered.isEmpty {
                        HStack(spacing: 8) {
                            if wizard.isDiscovering {
                                ProgressView().controlSize(.small)
                                Text("Looking for ONVIF cameras… If macOS asks to let Camera Bridge find devices on your local network, click Allow.")
                            } else {
                                Text(wizard.hasDiscovered ? "No cameras answered. Enter an address below." : "Not searched yet.")
                            }
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(wizard.discovered, id: \.host) { camera in   // unique by host (see uniqueByHost)
                            DiscoveredCameraRow(name: camera.name, hardware: camera.hardware, host: camera.host,
                                                addedAs: wizard.existingCamera(at: camera.host)?.name,
                                                isSelected: wizard.selectedDiscoveredHost == camera.host) {
                                wizard.select(camera)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("On Your Network")
                        Spacer()
                        Button("Search Again") { wizard.startDiscovery() }
                            .disabled(wizard.isDiscovering)
                    }
                }

                Section {
                    TextField("Address", text: $wizard.host, prompt: Text("192.168.1.20 or camera.local"))
                } footer: {
                    if let problem = wizard.hostProblem {
                        Label(problem, systemImage: "info.circle")
                    } else {
                        Text("Pick a camera above or type its IP address or host name.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            if !wizard.hasDiscovered { await wizard.discover() }
        }
        .onChange(of: wizard.localNetworkAccess) { _, access in
            wizard.localNetworkAccessDidChange(access)   // allowed: search again
        }
    }

    private var typeFooter: String {
        switch wizard.vendorChoice {
        case .automatic: String(localized: "Camera Bridge tries Hikvision, then Reolink, then ONVIF.")
        case .rtspURL: String(localized: "You’ll enter the camera’s RTSP stream URLs on the next page. Motion comes from built-in detection or the webhook.")
        case .demo: String(localized: "The demo camera shows a test pattern and reports motion every minute. Use it to try Camera Bridge without a camera.")
        case .hikvision, .reolink, .onvif, .amcrest, .doorbird: String(localized: "Camera Bridge reads streams and events through the camera’s own interface.")
        case .unifi, .go2rtc: String(localized: "Camera Bridge reaches this camera through its streaming helper.")
        }
    }
}

/// The Discover page while Local Network access is denied: nothing on the network can answer until it is allowed (the
/// page searches again by itself then).
private struct LocalNetworkDeniedRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Local Network Access Denied", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("Camera Bridge can’t search for or reach cameras until you allow it in System Settings › Privacy & Security › Local Network. This page searches again once access is allowed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = OnboardingContent.privacySettingsURL {
                Button("Open Privacy & Security Settings…") { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DiscoveredCameraRow: View {
    let name: String?
    let hardware: String?
    let host: String
    /// The name of the configured camera at this address, if any.
    let addedAs: String?
    let isSelected: Bool
    let select: () -> Void

    private var title: String { name ?? hardware ?? host }

    private var subtitle: String {
        var parts = [hardware, host].compactMap { $0 }.filter { $0 != title }
        if let addedAs { parts.append(String(localized: "Already added as “\(addedAs)”")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: select) {
            HStack {
                Image(systemName: "video")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text("Selected"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ConnectPage: View {
    @Bindable var wizard: AddCameraWizardModel
    /// Open when a discovered camera filled in its ONVIF port, so the person sees it.
    @State private var showsAdvanced: Bool

    init(wizard: AddCameraWizardModel) {
        self.wizard = wizard
        _showsAdvanced = State(initialValue: wizard.onvifPort != nil)
    }

    var body: some View {
        if wizard.cameraType.isIntegration {
            IntegrationConnectPage(wizard: wizard) { NSWorkspace.shared.open($0) }
        } else {
            addressForm
        }
    }

    private var addressForm: some View {
        Form {
            if wizard.cameraType == .wyzeRTSP {
                WyzeRTSPConnectSection(wizard: wizard)
            } else if wizard.vendorChoice == .rtspURL {
                Section {
                    TextField("Main Stream", text: $wizard.mainStreamURLText, prompt: Text("rtsp://192.168.1.20:554/stream1"))
                    TextField("Sub Stream (Optional)", text: $wizard.subStreamURLText, prompt: Text("rtsp://192.168.1.20:554/stream2"))
                } header: {
                    Text("Streams")
                } footer: {
                    Text("A user name and password typed into a URL are moved to the fields below; URLs are saved without them.")
                }
            }

            if wizard.cameraType != .wyzeRTSP {
                Section {
                    TextField("User Name", text: $wizard.username)
                        .textContentType(.username)
                    SecureField("Password", text: $wizard.password)
                        .textContentType(.password)
                } header: {
                    Text("Sign In")
                } footer: {
                    Text("Camera Bridge keeps the password in your keychain.")
                }
            }

            if wizard.vendorChoice != .rtspURL {
                Section {
                    DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                        TextField(wizard.httpPortTitle, value: $wizard.httpPort, format: .number.grouping(.never))
                        TextField("RTSP Port", value: $wizard.rtspPort, format: .number.grouping(.never))
                        if wizard.vendorChoice == .automatic || wizard.vendorChoice == .onvif {
                            TextField("ONVIF Port", value: $wizard.onvifPort, format: .number.grouping(.never), prompt: Text("Automatic"))
                        }
                        Toggle("Use HTTPS", isOn: $wizard.useHTTPS)
                    }
                } footer: {
                    if wizard.vendorChoice == .automatic || wizard.vendorChoice == .onvif {
                        Text("Camera Bridge looks for ONVIF on the HTTP port, 8000, 8080 and 2020 unless you enter its port.")
                    }
                }
            }

            if let problem = wizard.connectionProblem {
                Section {
                    Label(problem, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if !wizard.cameraType.setupSteps.isEmpty, wizard.cameraType != .rtspURL, wizard.cameraType != .automatic {
                Section {
                    DisclosureGroup("How to Set Up \(wizard.cameraType.title)") {
                        CameraTypeDetail(type: wizard.cameraType)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProbePage: View {
    let wizard: AddCameraWizardModel
    let model: AppModel

    var body: some View {
        switch wizard.probeState {
        case .idle, .probing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Checking \(wizard.cameraType.isIntegration ? wizard.cameraType.title : (wizard.endpoint?.host ?? String(localized: "the camera")))…")
                    .font(.headline)
                Text(wizard.cameraType.isIntegration ? String(localized: "Starting the streaming helper and asking the service for video. This can take up to 40 seconds.")
                                                     : String(localized: "Detecting the camera’s type, streams and events."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Check the Camera", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { wizard.startProbe() }
            }
        case .succeeded(let result):
            ProbeResults(result: result, wizard: wizard, model: model)
        }
    }
}

private struct ProbeResults: View {
    let result: CameraProbeResult
    let wizard: AddCameraWizardModel
    let model: AppModel

    @State private var readiness: HomeKitReadinessReport?
    @State private var isLoadingReadiness = true

    var body: some View {
        Form {
            Section("Camera") {
                LabeledContent("Type", value: StatusText.vendor(result.vendor))
                if !result.manufacturer.isEmpty { LabeledContent("Manufacturer", value: result.manufacturer) }
                if !result.model.isEmpty { LabeledContent("Model", value: result.model) }
                if !result.firmware.isEmpty { LabeledContent("Firmware", value: result.firmware) }
                if !result.serialNumber.isEmpty { LabeledContent("Serial Number", value: result.serialNumber) }
            }
            Section("Streams") {
                LabeledContent("Main Stream", value: result.mainStream.map(StatusText.stream) ?? String(localized: "Not found"))
                LabeledContent("Sub Stream", value: result.subStream.map(StatusText.stream) ?? String(localized: "Not found"))
            }
            Section("Features") {
                LabeledContent("Events", value: events)
                LabeledContent("Doorbell Button", value: result.capabilities.isDoorbell ? String(localized: "Yes") : String(localized: "No"))
                LabeledContent("Two-Way Audio", value: result.capabilities.twoWayAudio ? String(localized: "Supported") : String(localized: "Not supported"))
                LabeledContent("Snapshots", value: result.capabilities.snapshotAPI ? String(localized: "From the camera") : String(localized: "From video"))
            }
            Section {
                if isLoadingReadiness {
                    HStack { ProgressView(); Text("Checking HomeKit readiness…").foregroundStyle(.secondary) }
                } else if let readiness {
                    HStack {
                        Text("\(readiness.score)% ready")
                            .font(.headline)
                        Spacer()
                    }
                    Text(readiness.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if readiness.checks.contains(where: { if case .automatic = $0.fixMethod { true } else { false } }) {
                        Text("Once this camera is added, use “Optimize for HomeKit…” on its page to apply the automatic fixes before pairing it with Home.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("HomeKit Readiness")
            }
        }
        .formStyle(.grouped)
        .task(id: result) { await loadReadiness() }
    }

    private func loadReadiness() async {
        isLoadingReadiness = true
        // Cloud cameras and consoles have no ONVIF interface to read the encoder settings from.
        guard let endpoint = wizard.endpoint, !wizard.cameraType.isIntegration else { isLoadingReadiness = false; return }
        readiness = try? await model.homeKitReadiness(vendor: result.vendor, endpoint: endpoint, username: wizard.username, password: wizard.password)
        isLoadingReadiness = false
    }

    private var events: String {
        let names = CameraEventKind.allCases.filter { result.capabilities.events.contains($0) }.map(Self.eventName)
        return names.isEmpty ? String(localized: "None") : names.formatted(.list(type: .and))
    }

    private static func eventName(_ kind: CameraEventKind) -> String {
        switch kind {
        case .motion: String(localized: "motion")
        case .person: String(localized: "people")
        case .vehicle: String(localized: "vehicles")
        case .animal: String(localized: "animals")
        case .package: String(localized: "packages")
        case .face: String(localized: "faces")
        case .doorbell: String(localized: "doorbell")
        case .tamper: String(localized: "tampering")
        case .dayNight: String(localized: "day/night")
        case .digitalInput: String(localized: "alarm inputs")
        case .temperature: String(localized: "temperature")
        case .humidity: String(localized: "humidity")
        case .audioAlarm: String(localized: "sound")
        }
    }
}

private struct KindPage: View {
    @Bindable var wizard: AddCameraWizardModel

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $wizard.name, prompt: Text("Driveway"))
            } footer: {
                Text("This is the name the Home app shows. Use letters, numbers, spaces and apostrophes.")
            }
            Section {
                Picker("Show in the Home app as", selection: $wizard.kind) {
                    Label("Camera", systemImage: "video").tag(CameraKind.camera)
                    Label("Video Doorbell", systemImage: "video.doorbell").tag(CameraKind.doorbell)
                }
                .pickerStyle(.radioGroup)
                Label(AddCameraWizardModel.kindChangeWarning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                if wizard.kind == .doorbell && wizard.capabilities?.isDoorbell == false {
                    Label("This camera didn’t report a doorbell button. Rings can come from the webhook instead; the Review page shows its URL.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct MotionPage: View {
    @Bindable var wizard: AddCameraWizardModel
    let webhookURL: String
    let webhookEnabled: Bool

    var body: some View {
        Form {
            Section {
                Picker("Motion Source", selection: $wizard.motionSource) {
                    ForEach(wizard.availableMotionSources, id: \.self) { source in
                        Text(StatusText.motionSource(source)).tag(source)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text(StatusText.motionSourceDetail(wizard.motionSource) + " " + String(localized: "Motion starts HomeKit Secure Video recordings."))
            }
            if wizard.motionSource == .softMotion {
                Section("Sensitivity") {
                    Slider(value: $wizard.motionSensitivity, in: 0...1) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Text("Low")
                    } maximumValueLabel: {
                        Text("High")
                    }
                }
            }
            if wizard.motionSource == .webhook {
                Section {
                    Text(webhookURL)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("Webhook")
                } footer: {
                    Text(webhookEnabled ? String(localized: "Send a POST request with the webhook token from Settings.")
                                        : String(localized: "Turn on the webhook in Settings before using this."))
                }
            }
            Section {
                MotionHoldRow(seconds: $wizard.motionHoldSeconds)
            } footer: {
                Text("How long motion stays on after the last detection.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct FeaturesPage: View {
    @Bindable var wizard: AddCameraWizardModel

    var body: some View {
        Form {
            Section {
                if wizard.availableSensors.isEmpty {
                    Text("This camera doesn’t report detections the sensors bridge can show. With Motion › Webhook, people, vehicles, animals and packages reported to the webhook can.")
                        .foregroundStyle(.secondary)
                }
                ForEach(wizard.availableSensors) { kind in
                    Toggle(isOn: $wizard.sensors[dynamicMember: kind.keyPath]) {
                        Label {
                            Text(kind.title)
                            Text(kind.isFromWebhook(in: wizard.capabilities, motionSource: wizard.motionSource)
                                 ? String(localized: "From the webhook · \(kind.homeAccessory)") : kind.homeAccessory)
                        } icon: {
                            Image(systemName: kind.symbol)
                        }
                    }
                }
            } header: {
                Text("Sensors")
            } footer: {
                Text("Sensors appear on the Camera Bridge Sensors bridge. They never start recordings.")
            }
            Section("Audio") {
                Toggle("Camera Audio", isOn: $wizard.audioEnabled)
                    .disabled(!wizard.hasCameraAudio)
                if wizard.canUseTwoWayAudio {
                    Toggle(isOn: $wizard.twoWayAudio) {
                        Text("Two-Way Audio")
                        Text("Talk through the camera’s speaker from the Home app.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SummaryPage: View {
    let wizard: AddCameraWizardModel
    let doorbellWebhookURL: String
    let webhookEnabled: Bool
    /// Closes the wizard and opens the camera that is already set up.
    let openExisting: (CameraConfiguration) -> Void

    var body: some View {
        Form {
            if let existing = wizard.alreadyAdded, wizard.addState != .added {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("This camera is already added as “\(existing.name)”")
                                .font(.headline)
                            Text("Adding it again makes a second accessory in the Home app, with its own connections to the camera, which may allow only a few. To use a new address, open “\(existing.name)” and choose Change Address….")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Button("Open “\(existing.name)”") { openExisting(existing) }
                }
            }
            if let config = wizard.makeConfiguration() {
                Section {
                    LabeledContent("Name", value: config.name)
                    LabeledContent("Type", value: StatusText.kind(config.kind))
                    LabeledContent("Camera", value: [StatusText.vendor(config.vendor), config.model].filter { !$0.isEmpty }.joined(separator: " "))
                    if config.vendor != .demo { LabeledContent("Address", value: config.endpoint.host) }
                    LabeledContent("Motion", value: StatusText.motionSource(config.motionSource))
                    LabeledContent("Sensors", value: sensorList(config))
                    LabeledContent("Audio", value: StatusText.audioSummary(cameraAudio: config.audioEnabled, twoWayAudio: config.twoWayAudio))
                }
            }
            if wizard.ringsThroughWebhook {
                Section {
                    Text(doorbellWebhookURL)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("Doorbell Rings")
                } footer: {
                    Text(webhookEnabled
                         ? String(localized: "This camera doesn’t report its doorbell button. Have Home Assistant or another system send a POST request to this URL, with the webhook token from Settings, when someone rings.")
                         : String(localized: "This camera doesn’t report its doorbell button. Turn on the webhook in Settings, then have Home Assistant or another system send a POST request to this URL when someone rings."))
                }
            }
            if wizard.addState == .adding {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Adding the camera…")
                    }
                }
            }
            if case .failed(let message) = wizard.addState {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func sensorList(_ config: CameraConfiguration) -> String {
        let names = SensorKind.allCases.filter { config.sensors[keyPath: $0.keyPath] }.map(\.title)
        return names.isEmpty ? String(localized: "None") : names.formatted(.list(type: .and))
    }

}

private struct PairingPage: View {
    let wizard: AddCameraWizardModel
    let model: AppModel
    let doorbellWebhookURL: String

    var body: some View {
        VStack(spacing: 16) {
            if let blocker = model.pairingBlocker(for: wizard.cameraID) {
                // Added while the bridge is paused or stopped (or turned off): nothing advertises the accessory yet.
                Image(systemName: "qrcode")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("The camera was added.")
                    .font(.headline)
                Text(blocker.message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
                if let action = blocker.action {
                    Button(action.title) { Task { await model.resolve(action) } }
                }
                Text("The code appears here, and in the camera’s details, once the camera is published.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let code = wizard.pairingCode {
                QRCodeView(uri: code.setupURI)
                    .frame(width: 200, height: 200)
                    .padding(14)
                    .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                SetupCodeText(code: code.setupCode)
                Text("On iPhone or iPad, open the Home app, tap Add (+), then Add Accessory, and scan this code. When the Home app says the accessory isn’t certified, tap Add Anyway.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
                Text("You can find this code later in the camera’s details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("Waiting for the bridge to publish the camera…")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            if wizard.ringsThroughWebhook {
                // The camera reports no doorbell button: rings come from the webhook (its page lists the URL too).
                VStack(spacing: 4) {
                    Text("Doorbell rings come from the webhook:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(doorbellWebhookURL)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .task {
            while wizard.pairingCode == nil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                wizard.refreshPairingCode()
            }
        }
    }
}

#Preview("Add Camera") {
    AddCameraWizard(model: .preview())
}
