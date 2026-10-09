import AppKit
import BridgeEngine
import CameraAdapters
import SwiftUI

/// The first page of Add Camera: what kind of camera it is. ONVIF/RTSP with detection, brand presets and integrations, each with
/// what Camera Bridge gets from it and how to set it up.
struct CameraTypePage: View {
    @Bindable var wizard: AddCameraWizardModel

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding<CameraType?>(get: { wizard.cameraType }, set: { if let type = $0 { wizard.cameraType = type } })) {
                ForEach(CameraType.Group.allCases) { group in
                    Section {
                        ForEach(CameraType.allCases.filter { $0.group == group }) { type in
                            Label(type.title, systemImage: type.symbol)
                                .tag(type)
                                .accessibilityIdentifier("cameraType.\(type.rawValue)")
                        }
                    } header: {
                        Text(group.title)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 252)
            .scrollContentBackground(.hidden)
            Divider()
            ScrollView {
                CameraTypeDetail(type: wizard.cameraType)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// What the person gets with a camera type and how to set it up.
struct CameraTypeDetail: View {
    let type: CameraType

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(type.title)
                    .font(.title3.weight(.semibold))
                Text(type.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("What You Get")
                    .font(.headline)
                SupportRow(title: String(localized: "Live view"), support: type.live)
                SupportRow(title: String(localized: "HomeKit Secure Video recording"), support: type.recording)
                SupportRow(title: String(localized: "Motion and doorbell events"), support: type.events, detail: type.eventsDetail)
                if type.needsStreamingHelper {
                    Label("Uses the streaming helper (go2rtc) on this Mac", systemImage: "gearshape.2")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Set Up")
                    .font(.headline)
                ForEach(Array(type.setupSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(step)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !type.notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Good to Know")
                        .font(.headline)
                    ForEach(type.notes, id: \.self) { note in
                        Label {
                            Text(note)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "info.circle")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if let footer = type.group.footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SupportRow: View {
    let title: String
    let support: CameraType.Support
    var detail: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let text {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch support {
        case .yes: "checkmark.circle.fill"
        case .partly: "circle.lefthalf.filled"
        case .no: "xmark.circle"
        }
    }

    private var color: Color {
        switch support {
        case .yes: .green
        case .partly: .orange
        case .no: .secondary
        }
    }

    private var text: String? {
        switch support {
        case .yes: detail.isEmpty ? nil : detail
        case .partly(let note): note
        case .no: nil
        }
    }
}

// MARK: - Connect pages for services

/// The Connect page of a cloud camera or a console: what to enter, where to get it.
struct IntegrationConnectPage: View {
    @Bindable var wizard: AddCameraWizardModel
    let openURL: (URL) -> Void

    var body: some View {
        Form {
            switch wizard.cameraType {
            case .unifiProtect: UnifiSection(wizard: wizard)
            case .googleNest: NestSection(wizard: wizard, openURL: openURL)
            default: SourceSection(wizard: wizard, openURL: openURL)
            }
            if case .failed(let message) = wizard.integrationState {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let problem = wizard.connectionProblem {
                Section {
                    Label(problem, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                DisclosureGroup("How to Set Up \(wizard.cameraType.title)") {
                    CameraTypeDetail(type: wizard.cameraType)
                        .padding(.vertical, 6)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Ring, Wyze, Tuya and other go2rtc sources: paste the source, or open go2rtc's own sign-in page to get it.
private struct SourceSection: View {
    @Bindable var wizard: AddCameraWizardModel
    let openURL: (URL) -> Void

    var body: some View {
        Section {
            SecureField("Source", text: $wizard.sourceText, prompt: Text(prompt))
                .textContentType(.password)
            HStack {
                Button {
                    Task { if let url = await wizard.openSignInPage() { openURL(url) } }
                } label: {
                    Label("Open Sign-In Page", systemImage: "safari")
                }
                .disabled(wizard.integrationState == .working || !wizard.isStreamingHelperInstalled)
                if wizard.integrationState == .working { ProgressView().controlSize(.small) }
                Spacer()
                if wizard.signInPageURL != nil {
                    Button("Close Sign-In Page") { wizard.closeSignInPage() }
                }
            }
        } header: {
            Text(header)
        } footer: {
            Text("The sign-in page is go2rtc’s own, running on this Mac and closing itself after 20 minutes. Camera Bridge never sees your account or password, only the source you paste, which it keeps in your Keychain.")
        }
    }

    private var header: String {
        switch wizard.cameraType {
        case .ring: String(localized: "Ring")
        case .wyzeCloud: String(localized: "Wyze")
        case .tuya: String(localized: "Tuya")
        default: String(localized: "go2rtc Source")
        }
    }

    private var prompt: String {
        switch wizard.cameraType {
        case .ring: "ring:?camera_id=…&device_id=…&refresh_token=…"
        case .wyzeCloud: "wyze://192.168.1.20?uid=…&enr=…&mac=…&model=…"
        case .tuya: "tuya://protect-us.ismartlife.me?device_id=…&email=…&password=…"
        default: "rtspx://192.168.1.1:7441/…"
        }
    }
}

private struct UnifiSection: View {
    @Bindable var wizard: AddCameraWizardModel

    var body: some View {
        Section {
            TextField("Console Address", text: $wizard.host, prompt: Text("192.168.1.1 or unifi.local"))
            SecureField("API Key", text: $wizard.password)
                .textContentType(.password)
            HStack {
                Button("Find Cameras") { Task { await wizard.findUnifiCameras() } }
                    .disabled(wizard.integrationState == .working || HostInput(wizard.host) == nil)
                if wizard.integrationState == .working { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("Console")
        } footer: {
            Text("Create the key in UniFi Protect under Settings › Control Plane › Integrations. Camera Bridge keeps it in your Keychain.")
        }
        if !wizard.unifiCameras.isEmpty {
            Section("Camera") {
                Picker("Camera", selection: $wizard.unifiCameraID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(wizard.unifiCameras) { camera in
                        Text(camera.isConnected ? camera.name : String(localized: "\(camera.name) (offline)")).tag(Optional(camera.id))
                    }
                }
            }
        }
    }
}

private struct NestSection: View {
    @Bindable var wizard: AddCameraWizardModel
    let openURL: (URL) -> Void

    var body: some View {
        Section {
            TextField("Project ID", text: $wizard.nestProjectID, prompt: Text("From the Device Access console"))
            TextField("OAuth Client ID", text: $wizard.nestClientID, prompt: Text("….apps.googleusercontent.com"))
            SecureField("OAuth Client Secret", text: $wizard.nestClientSecret)
            HStack {
                Button("Device Access Console") { openURL(NestDeviceAccess.consoleURL) }
                Button("Google Cloud Credentials") { openURL(NestDeviceAccess.cloudCredentialsURL) }
            }
        } header: {
            Text("Google Device Access")
        } footer: {
            Text("Registering with Device Access costs a one-time US$5 and is paid to Google. In Google Cloud, create an OAuth client of type Web application and add https://www.google.com as an authorized redirect address.")
        }
        Section {
            Button {
                if let url = wizard.nestAuthorizationURL { openURL(url) }
            } label: {
                Label("Open Google’s Sign-In Link", systemImage: "safari")
            }
            .disabled(wizard.nestAuthorizationURL == nil)
            TextField("Code", text: $wizard.nestCodeText, prompt: Text("Paste the code, or the address of the page Google shows"))
            HStack {
                Button("Connect") { Task { await wizard.connectNest() } }
                    .disabled(wizard.integrationState == .working || wizard.nestCodeText.trimmingCharacters(in: .whitespaces).isEmpty)
                if wizard.integrationState == .working { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("Sign In")
        } footer: {
            Text("Sign in with the Google account that owns the cameras and allow access. Google then shows a page with a code in its address (it may say the page can’t be reached: that is expected). Copy the address or the code after “code=” and paste it here.")
        }
        if !wizard.nestCameras.isEmpty {
            Section("Camera") {
                Picker("Camera", selection: $wizard.nestDeviceID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(wizard.nestCameras) { camera in
                        Text(camera.name).tag(Optional(camera.deviceID))
                    }
                }
            }
        }
    }
}

/// The Connect page of Wyze's official RTSP: the camera's address and the RTSP user made in the Wyze app.
struct WyzeRTSPConnectSection: View {
    @Bindable var wizard: AddCameraWizardModel

    var body: some View {
        Section {
            TextField("IP Address", text: $wizard.host, prompt: Text("192.168.1.20"))
            TextField("RTSP User Name", text: $wizard.username)
                .textContentType(.username)
            SecureField("RTSP Password", text: $wizard.password)
                .textContentType(.password)
        } header: {
            Text("Camera")
        } footer: {
            Text("In the Wyze app: Settings › Advanced Settings › RTSP, turn it on and create a user name and password. Camera Bridge tries rtsp://<address>:554/stream0, then /live. If your camera shows another address, go back and choose RTSP URL.")
        }
    }
}

// MARK: - Replacing a cloud camera's source or a console's key

/// The camera page's Replace Source… / Replace Key…: a new go2rtc source (checked here) or a new Protect API key.
struct SecretReplacementSheet: View {
    enum Kind { case source, apiKey }

    let name: String
    let kind: Kind
    let onSave: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    private var problem: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch kind {
        case .source:
            do {
                _ = try Go2RTCSource(parsing: trimmed)
                return nil
            } catch let invalid as Go2RTCSource.Invalid {
                return invalid.reason
            } catch {
                return String(localized: "The source address can’t be used.")
            }
        case .apiKey:
            return trimmed.contains(where: \.isWhitespace) ? String(localized: "An API key has no spaces.") : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind == .source ? "New Source for “\(name)”" : "New API Key for “\(name)”")
                .font(.headline)
            Form {
                SecureField(kind == .source ? "Source" : "API Key", text: $text)
                    .textContentType(.password)
            }
            if let problem {
                Label(problem, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("It is stored in your keychain. The camera restarts with it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || problem != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
