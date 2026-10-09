import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import Synchronization
import Testing
import TestSupport
@testable import BridgeWeb

// Shared fixtures for the BridgeWeb tests: a backend that answers from memory, and a harness that talks to the application (no
// sockets) or to a server over the in-memory transport.

/// A bridge that lives in memory. Calls are recorded for the assertions.
final class FakeBackend: BridgeBackend {
    struct State {
        var state: EngineState = .running
        var configurations: [CameraConfiguration] = []
        var settings = BridgeSettings()
        var webhookProblem: String?
        var notices: [NetworkNotice] = []
        var helperInstalled = true
        var discovered: [DiscoveredCamera] = []
        var probe: Result<CameraProbeResult, any Error> = .success(FakeBackend.sampleProbe)
        var integrationProbe: Result<CameraProbeResult, any Error> = .success(FakeBackend.sampleProbe)
        var protectCameras: [UnifiProtectCamera] = []
        var snapshot: Data? = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0xD9])
        var addError: (any Error)?
        var updateError: (any Error)?
        var statusOverrides: [UUID: CameraStatus] = [:]
        var calls: [String] = []
        var passwords: [UUID: String] = [:]
        var probeCalls: [(vendor: CameraVendor?, host: String, username: String, password: String)] = []
        var sensorsBridge: SensorsBridgeStatus?
    }

    let box = Mutex(State())

    static let sampleProbe = CameraProbeResult(
        vendor: .onvif, manufacturer: "Acme", model: "Doorstep 3000", serialNumber: "SN-1234", firmware: "1.2.3",
        mainStream: StreamInfo(url: URL(string: "rtsp://192.0.2.20:554/main")!, videoCodec: .h264, width: 1920, height: 1080, fps: 25, audioCodec: .aac,
                               audioSampleRate: 16_000, audioChannels: 1),
        subStream: StreamInfo(url: URL(string: "rtsp://192.0.2.20:554/sub")!, videoCodec: .h264, width: 640, height: 360, fps: 15),
        capabilities: CameraCapabilities(events: [.motion, .person, .vehicle], twoWayAudio: true, isDoorbell: false, snapshotAPI: true), onvifPort: 8000)

    func read<T>(_ body: (State) -> T) -> T { box.withLock { body($0) } }
    func write(_ body: (inout State) -> Void) { box.withLock { body(&$0) } }

    func status(for camera: CameraConfiguration, in state: State) -> CameraStatus {
        if let override = state.statusOverrides[camera.id] { return override }
        return CameraStatus(id: camera.id, name: camera.name, kind: camera.kind, vendor: camera.vendor,
                            connection: camera.isEnabled ? .online : .disabled, videoSummary: "H.264 1920×1080 · 25 fps", isPaired: false,
                            setupCode: "12345678", setupURI: "X-HM://00GW95DQA7OSX", hapPort: camera.isEnabled ? 21_100 : nil)
    }

    func overview() async -> BridgeOverview {
        box.withLock { state in
            BridgeOverview(state: state.state, cameras: state.configurations.map { status(for: $0, in: state) }, configurations: state.configurations,
                           sensorsBridge: state.sensorsBridge, localNetworkAccess: .granted, networkNotices: state.notices, settings: state.settings,
                           webhookProblem: state.webhookProblem, streamingHelperInstalled: state.helperInstalled)
        }
    }

    func discoverCameras() async -> [DiscoveredCamera] { read { $0.discovered } }

    func probeCamera(vendor: CameraVendor?, endpoint: CameraEndpoint, username: String, password: String, mainStreamURL: URL?,
                     subStreamURL: URL?) async throws -> CameraProbeResult {
        write { $0.probeCalls.append((vendor, endpoint.host, username, password)) }
        return try read { $0.probe }.get()
    }

    func probeIntegration(vendor: CameraVendor, integration: IntegrationSettings, endpoint: CameraEndpoint, username: String,
                          secret: String) async throws -> CameraProbeResult {
        write { $0.calls.append("probeIntegration") }
        return try read { $0.integrationProbe }.get()
    }

    func unifiProtectCameras(endpoint: CameraEndpoint, apiKey: String) async throws -> [UnifiProtectCamera] { read { $0.protectCameras } }

    func addCamera(_ configuration: CameraConfiguration, password: String?) async throws {
        if let error = read({ $0.addError }) { throw error }
        write {
            $0.calls.append("add")
            $0.configurations.append(configuration)
            $0.passwords[configuration.id] = password
        }
    }

    func updateCamera(_ configuration: CameraConfiguration, password: String?) async throws {
        if let error = read({ $0.updateError }) { throw error }
        try box.withLock { state in
            guard let index = state.configurations.firstIndex(where: { $0.id == configuration.id }) else { throw EngineError.unknownCamera }
            state.configurations[index] = configuration
            state.calls.append("update")
            if let password { state.passwords[configuration.id] = password }
        }
    }

    func removeCamera(id: UUID) async {
        write {
            $0.configurations.removeAll { $0.id == id }
            $0.calls.append("remove")
        }
    }

    func resetPairing(cameraID: UUID) async throws { write { $0.calls.append("resetPairing") } }
    func resetSensorsBridgePairing() async throws { write { $0.calls.append("resetSensorsBridge") } }

    func updateSettings(_ change: @Sendable @escaping (inout BridgeSettings) -> Void) async throws {
        try box.withLock { state in
            var settings = state.settings
            change(&settings)
            if settings.webhookEnabled, settings.webhookToken.count < 16 { throw EngineError.invalidSettings("the webhook token must have at least 16 characters") }
            state.settings = settings
        }
    }

    func snapshotJPEG(cameraID: UUID) async -> Data? { read { $0.snapshot } }
    func triggerTestMotion(cameraID: UUID) async { write { $0.calls.append("motion") } }
    func pause() async { write { $0.state = .paused } }
    func resume() async { write { $0.state = .running } }

    func diagnosticsReport(context: DiagnosticsContext) async -> String {
        "Camera Bridge diagnostics\nApp: \(context.appName) \(context.appVersion)\n"
    }
}

/// A system that records what it was asked.
final class FakeSystem: SystemControlling {
    let calls = Box<[String]>([])
    let mode: String

    init(mode: String = "installed") { self.mode = mode }

    func info() async -> SystemInfo {
        SystemInfo(product: "Camera Bridge OS", version: "0.1", build: "test", mode: mode, hostname: "camera-bridge", canUpdate: true, canReboot: true,
                   canInstall: true, update: UpdateStatus(current: "0.1"), canManage: true, sshEnabled: false, automaticUpdates: true)
    }

    func checkForUpdate() async throws -> UpdateStatus {
        calls.update { $0.append("check") }
        return UpdateStatus(available: true, current: "0.1", latest: "0.2", notes: "Better.")
    }

    func applyUpdate() async throws -> UpdateStatus {
        calls.update { $0.append("apply") }
        return UpdateStatus(state: "ready", available: true, current: "0.1", latest: "0.2", rebootRequired: true)
    }

    func reboot() async throws { calls.update { $0.append("reboot") } }

    func installTargets() async throws -> [InstallTarget] {
        [InstallTarget(id: "nvme0n1", name: "nvme0n1", model: "Acme 256", sizeBytes: 256_000_000_000, phrase: "ERASE ALL DATA ON nvme0n1")]
    }

    func install(targetID: String, phrase: String, copyData: Bool) async throws {
        calls.update { $0.append("install:\(targetID):\(phrase):\(copyData)") }
        if targetID == "bad" { throw SystemError("That disk can’t be used.") }
    }

    func powerOff() async throws { calls.update { $0.append("poweroff") } }

    func setSSH(enabled: Bool, authorizedKeys: [String]) async throws {
        calls.update { $0.append("ssh:\(enabled):\(authorizedKeys.count)") }
    }

    func setAutomaticUpdates(_ enabled: Bool) async throws { calls.update { $0.append("auto-update:\(enabled)") } }

    func factoryReset() async throws { calls.update { $0.append("factory-reset") } }
}

/// An answer from the application, parsed.
struct Answer {
    var status: Int
    var headers: HTTPHeaders
    var body: Data

    var text: String { String(decoding: body, as: UTF8.self) }

    var json: [String: Any] {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
    }

    var cookie: String? {
        guard let header = headers.values(for: "Set-Cookie").first(where: { $0.hasPrefix("cb_session=") }) else { return nil }
        let value = header.split(separator: ";").first.map(String.init)
        return value == "cb_session=" ? nil : value
    }
}

/// A web application over a fake backend in a temporary directory, driven without sockets.
final class Harness: Sendable {
    let directory: TemporaryDirectory
    let backend: FakeBackend
    let system: FakeSystem
    let app: WebApp
    let logs: LogFeed
    let host: String

    init(backend: FakeBackend = FakeBackend(), setupToken: String? = nil, staticDirectory: URL? = nil, allowedHosts: [String] = [],
         eventInterval: Duration = .milliseconds(20), modify: (inout WebConfiguration) -> Void = { _ in }) throws {
        directory = try TemporaryDirectory(prefix: "cb-web")
        self.backend = backend
        system = FakeSystem()
        logs = LogFeed()
        host = "camera-bridge.local"
        var configuration = WebConfiguration(dataDirectory: directory.url, staticDirectory: staticDirectory, port: 0, loopbackOnly: true,
                                             allowedHosts: allowedHosts, setupToken: setupToken, version: "0.1", build: "test", passwordIterations: 1_000)
        configuration.eventInterval = eventInterval
        configuration.liveFrameInterval = .milliseconds(20)
        modify(&configuration)
        app = WebApp(configuration: configuration, backend: backend, system: system, logs: logs)
    }

    deinit { directory.remove() }

    func request(_ method: String, _ path: String, json: Any? = nil, rawBody: Data? = nil, cookie: String? = nil, csrf: String? = nil,
                 headers extra: [(String, String)] = [], origin: String? = nil, from address: String = "192.0.2.77") -> HTTPRequest {
        var headers = HTTPHeaders([("Host", host)])
        if let cookie { headers.add("Cookie", cookie) }
        if let csrf { headers.add("X-CSRF-Token", csrf) }
        if let origin { headers.add("Origin", origin) }
        var body = rawBody ?? Data()
        if let json {
            body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            headers.add("Content-Type", "application/json")
        } else if rawBody != nil {
            headers.add("Content-Type", "application/json")
        }
        for (name, value) in extra { headers[name] = value }
        return HTTPRequest(method: method, target: path, headers: headers, body: body, remoteAddress: address)
    }

    @discardableResult
    func send(_ method: String, _ path: String, json: Any? = nil, rawBody: Data? = nil, cookie: String? = nil, csrf: String? = nil,
              headers: [(String, String)] = [], origin: String? = nil, from address: String = "192.0.2.77") async -> Answer {
        let response = await app.handle(request(method, path, json: json, rawBody: rawBody, cookie: cookie, csrf: csrf, headers: headers, origin: origin, from: address))
        return Answer(status: response.status, headers: response.headers, body: response.bodyData ?? Data())
    }

    /// The raw answer (a stream is not run).
    func raw(_ method: String, _ path: String, cookie: String? = nil, headers: [(String, String)] = []) async -> HTTPResponse {
        await app.handle(request(method, path, cookie: cookie, headers: headers))
    }

    /// Sets the password (first-run setup) and returns the session.
    func signIn(password: String = "correct horse", name: String? = "Hallway") async throws -> Session {
        let answer = await send("POST", "/api/v1/auth/setup", json: ["password": password, "bridgeName": name as Any].compactMapValues { $0 })
        let cookie = try #require(answer.cookie, "setup should start a session: \(answer.text)")
        return Session(cookie: cookie, csrf: answer.json["csrfToken"] as? String ?? "", harness: self)
    }

    struct Session: Sendable {
        var cookie: String
        var csrf: String
        var harness: Harness

        @discardableResult
        func send(_ method: String, _ path: String, json: Any? = nil, headers: [(String, String)] = [], origin: String? = nil) async -> Answer {
            await harness.send(method, path, json: json, cookie: cookie, csrf: method == "GET" ? nil : csrf, headers: headers, origin: origin)
        }

        func get(_ path: String) async -> Answer { await send("GET", path) }

        /// Starts a streaming answer (server-sent events, live preview) and collects what it writes.
        func stream(_ path: String, headers: [(String, String)] = []) async -> StreamCollector {
            StreamCollector(await harness.raw("GET", path, cookie: cookie, headers: headers))
        }
    }
}
