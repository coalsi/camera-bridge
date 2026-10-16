import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation

/// The eufy plugin: a thin front for the `eufy-bridge` helper (`EufyBridge`), which holds the Eufy session itself (in its own folder,
/// never the password) and runs while the plugin is on. Signing in may need a captcha and an emailed code; the helper answers each step
/// with its status, and the page shows what it asks for. The account's cameras are listed from Eufy's cloud without waking them.
actor EufyPlugin {
    static let id = "eufy"

    /// The helper's `/status`.
    struct Status: Codable, Sendable, Equatable {
        struct Captcha: Codable, Sendable, Equatable {
            var id: String
            /// A `data:image/png;base64,…` URL.
            var image: String
        }

        /// `signedOut`, `signingIn`, `needsCaptcha`, `needsCode`, `signedIn`, `error`.
        var state: String
        var account: String?
        var captcha: Captcha?
        var codeSentTo: String?
        var error: String?
        var pushProblem: String?

        static let unavailable = Status(state: "signedOut")
    }

    /// A camera as the helper lists it.
    struct Device: Codable, Sendable, Equatable {
        var serial: String
        var name: String
        var model: String
        var type: Int?
        var online: Bool?
        var battery: Int?
        var charging: Bool?
        var wifiRSSI: Int?
        var firmware: String?
        var livestream: Bool?
        var codec: String?
    }

    /// One camera of the account as the page shows it.
    struct CameraRow: Sendable, Encodable {
        var serial: String
        var name: String
        var model: String
        var modelName: String
        var online: Bool
        var battery: Int?
        var charging: Bool?
        var canAdd: Bool
        var note: String?
        var cameraID: String?
    }

    struct PluginProblem: Error, CustomStringConvertible {
        var description: String
    }

    private let backend: any BridgeBackend
    private let bridge: any EufyBridgeCalling
    private let log = Log(category: "eufy")
    private var devices: [Device] = []

    init(backend: any BridgeBackend, bridge: any EufyBridgeCalling) {
        self.backend = backend
        self.bridge = bridge
    }

    /// Starts the helper when the plugin is on.
    func start() async {
        let enabled = await backend.overview().settings.plugins[Self.id]?.enabled ?? false
        await bridge.setWanted(enabled)
    }

    func setEnabled(_ on: Bool) async {
        await bridge.setWanted(on)
    }

    func isInstalled() async -> Bool { await bridge.isInstalled() }

    private func setState(_ change: @escaping @Sendable (inout PluginState) -> Void) async {
        try? await backend.updateSettings { settings in
            var state = settings.plugins[EufyPlugin.id] ?? PluginState()
            change(&state)
            settings.plugins[EufyPlugin.id] = state
        }
    }

    // MARK: Calls

    private func call<Answer: Decodable>(_ method: String, _ path: String, json: [String: String]? = nil, as type: Answer.Type) async throws -> Answer {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let (status, data) = try await bridge.request(method, path, body: body)
        if !(200..<300).contains(status) {
            let words = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw PluginProblem(description: words.map(Redact.string) ?? "The eufy helper refused the request (HTTP \(status)).")
        }
        do {
            return try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            throw PluginProblem(description: "The eufy helper gave an answer Camera Bridge can’t read.")
        }
    }

    /// The helper's status; signed out while the plugin is off.
    func status() async throws -> Status {
        let status = try await call("GET", "/status", as: Status.self)
        await remember(status)
        return status
    }

    /// Keeps the page's account line in step with the helper.
    private func remember(_ status: Status) async {
        let account = status.state == "signedIn" ? status.account : nil
        let problem = status.state == "error" ? status.error : nil
        await setState { state in
            if status.state == "signedIn" || status.state == "signedOut" { state.account = account }
            state.lastError = problem
        }
    }

    func signIn(email: String, password: String, country: String) async throws -> Status {
        await setState { $0.enabled = true }
        await bridge.setWanted(true)
        let status = try await call("POST", "/sign-in", json: ["email": email, "password": password, "country": country], as: Status.self)
        await signedIn(status)
        return status
    }

    func answerCaptcha(id: String, answer: String) async throws -> Status {
        let status = try await call("POST", "/captcha", json: ["id": id, "answer": answer], as: Status.self)
        await signedIn(status)
        return status
    }

    func verify(code: String) async throws -> Status {
        let status = try await call("POST", "/verify", json: ["code": code], as: Status.self)
        await signedIn(status)
        return status
    }

    private func signedIn(_ status: Status) async {
        await remember(status)
        if status.state == "signedIn" {
            log.notice("signed in to the eufy account")
            await setState { $0.lastSync = Date() }
        }
    }

    func signOut() async throws -> Status {
        let status = try await call("POST", "/sign-out", as: Status.self)
        devices = []
        await setState { state in
            state.account = nil
            state.lastSync = nil
            state.lastError = nil
        }
        log.notice("signed out of the eufy account")
        return status
    }

    // MARK: Cameras

    private struct DeviceList: Decodable { var devices: [Device] }

    /// The account's cameras, from Eufy's cloud (none of them wakes).
    func listDevices() async throws -> [Device] {
        devices = try await call("GET", "/devices", as: DeviceList.self).devices
        await setState { $0.lastSync = Date() }
        return devices
    }

    /// The camera with `serial` (from the last list, else a fresh one).
    func device(serial: String) async -> Device? {
        if let device = devices.first(where: { $0.serial == serial }) { return device }
        return try? await listDevices().first { $0.serial == serial }
    }

    func rows(installed: Bool, helperInstalled: Bool) async throws -> [CameraRow] {
        let listed = try await listDevices()
        let configurations = await backend.overview().configurations
        var added: [String: String] = [:]
        for config in configurations where config.integration?.service == .eufy {
            if let serial = config.integration?.details[IntegrationSettings.Key.eufySerial] { added[serial] = config.id.uuidString }
        }
        return listed.map { device in
            let online = device.online ?? true
            var note: String?
            if !installed {
                note = "This copy of Camera Bridge OS doesn’t include the eufy helper."
            } else if !helperInstalled {
                note = "This copy of Camera Bridge OS doesn’t include the streaming helper (go2rtc)."
            } else if device.livestream == false {
                note = "This eufy device has no live video."
            } else if !online {
                note = "eufy says this camera is offline."
            } else if device.type == 63 || device.battery != nil {
                note = "A battery camera: it wakes for a live view, a recording or motion, then sleeps again. Its recordings start when it wakes."
            }
            let canAdd = installed && helperInstalled && device.livestream != false && online && added[device.serial] == nil
            return CameraRow(serial: device.serial, name: device.name, model: device.model, modelName: EufyModels.name(for: device.model), online: online,
                             battery: device.battery, charging: device.charging, canAdd: canAdd, note: note, cameraID: added[device.serial])
        }
    }
}
