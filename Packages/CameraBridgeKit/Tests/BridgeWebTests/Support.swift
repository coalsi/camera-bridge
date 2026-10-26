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
        var pluginSecrets: [String: Data] = [:]
        /// The AI service's key, as the engine keeps it in the secret store.
        var aiKey: String?
        /// What saving or deleting the AI key throws, when set.
        var aiKeyError: (any Error)?
        /// The describer's state, as `GET settings` shows it (nil: none described, and a folder is needed unless one is chosen).
        var aiStatus: AIStatus?
        /// What Try it answers, after `aiTryDelay`, and the cameras it was asked for.
        var aiTry: Result<EventDescription, any Error> = .failure(AIDescriberError.noService)
        var aiTryDelay: Duration = .zero
        var aiTries: [UUID] = []
        /// What `portAnswer` says for "host:port" (default `.silent`).
        var ports: [String: PortAnswer] = [:]
        var webhookProblem: String?
        var notices: [NetworkNotice] = []
        var helperInstalled = true
        var discovered: [DiscoveredCamera] = []
        var probe: Result<CameraProbeResult, any Error> = .success(FakeBackend.sampleProbe)
        var integrationProbe: Result<CameraProbeResult, any Error> = .success(FakeBackend.sampleProbe)
        /// What the no-password check says for any address.
        var notSetUp: NotSetUp?
        var protectCameras: [UnifiProtectCamera] = []
        var snapshot: Data? = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0xD9])
        /// `original` of every `snapshotJPEG` call, in order.
        var snapshotOriginals: [Bool] = []
        var addError: (any Error)?
        var updateError: (any Error)?
        /// Runs inside `updateCamera`, once the camera is stored, with the state and the configuration that was written: what the owner does
        /// to the bridge while a write is under way.
        var afterUpdate: (@Sendable (inout State, CameraConfiguration) -> Void)?
        var statusOverrides: [UUID: CameraStatus] = [:]
        var calls: [String] = []
        /// This machine's IPv4 addresses.
        var localAddresses = ["192.0.2.10"]
        var passwords: [UUID: String] = [:]
        var probeCalls: [(vendor: CameraVendor?, host: String, username: String, password: String)] = []
        var sensorsBridge: SensorsBridgeStatus?
        var archive: (any ArchiveReading)?
        var nvrStorage: ArchiveStorageStatus?
        var folderReport: Result<ArchiveFolderReport, any Error> = .success(ArchiveFolderReport(freeBytes: 200_000_000_000, totalBytes: 500_000_000_000))
        var nvrError: (any Error)?
        var optimization: Result<HomeKitOptimizationResult, any Error> = .failure(EngineError.cameraNotRunning)
        var optimizeGate: AsyncGate?
        var undoError: (any Error)?
        /// What the camera setup's three calls answer.
        var setup: Result<CameraSetupReport, any Error> = .failure(EngineError.cameraNotRunning)
        var setupGate: AsyncGate?
        /// The choices the last run was asked with.
        var setupOptions: CameraSetupOptions?
        /// What a security check answers.
        var security: Result<CameraSecurity, any Error> = .failure(EngineError.cameraNotRunning)
        /// What "Restart the camera now" throws (nil: the camera took it).
        var restartError: (any Error)?
        /// The sky log the Sky Watcher's routes read: every camera's entries (the fake serves them for whatever night it is asked), the log's
        /// conditions, the aim and the learning it reports, and the stills by entry id.
        var skyEntries: [SkyEntry] = []
        var skyConditions: [SkyConditions] = []
        var skyCapped: [SkyCappedHour] = []
        var skyAim = SkyAimStatus(quality: .rough, planes: 0, stars: 0, residualPixels: nil, updated: nil)
        var skyLearning = SkyLearning(ready: false, planes: 0, satellites: 0)
        var skyStills: [String: Data] = [:]
        /// What the sky calls throw instead of answering, when set (a place not set, a folder not chosen, a drive that is away).
        var skyError: (any Error)?
        /// Every sky call in order: "night:<camera>:<night or latest>:<view>", "correct:<entry>:<night>:<label>", "still:<entry>:<night>", "feeds".
        var skyCalls: [String] = []
        /// The flight feeds "Find a feed" finds.
        var feeds: [URL] = []
    }

    /// The hours the fake's log covers (a night from sunset to sunrise).
    static let skyFrom = Date(timeIntervalSince1970: 1_792_890_000)
    static let skyTo = Date(timeIntervalSince1970: 1_792_925_000)

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
                           webhookProblem: state.webhookProblem, streamingHelperInstalled: state.helperInstalled, nvrStorage: state.nvrStorage)
        }
    }

    func discoverCameras() async -> [DiscoveredCamera] { read { $0.discovered } }

    func probeCamera(vendor: CameraVendor?, endpoint: CameraEndpoint, username: String, password: String, mainStreamURL: URL?,
                     subStreamURL: URL?) async throws -> CameraProbeResult {
        write { $0.probeCalls.append((vendor, endpoint.host, username, password)) }
        return try read { $0.probe }.get()
    }

    func notSetUp(endpoint: CameraEndpoint) async -> NotSetUp? { read { $0.notSetUp } }

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
            state.afterUpdate?(&state, configuration)
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

    func snapshotJPEG(cameraID: UUID, original: Bool) async -> Data? {
        box.withLock { state in
            state.snapshotOriginals.append(original)
            return state.snapshot
        }
    }
    func pluginSecret(id: String) async throws -> Data? { read { $0.pluginSecrets[id] } }
    func setPluginSecret(id: String, _ data: Data?) async throws { write { $0.pluginSecrets[id] = data } }
    func aiKeyStatus() async -> (saved: Bool, hint: String?) {
        read { state in (state.aiKey != nil, state.aiKey.flatMap { $0.count >= 8 ? String($0.suffix(4)) : nil }) }
    }
    func setAIKey(_ key: String?) async throws {
        if let error = read({ $0.aiKeyError }) { throw error }
        write { $0.aiKey = key }
    }
    func aiStatus() async -> AIStatus {
        read { $0.aiStatus ?? AIStatus(needsRecordingsFolder: $0.settings.nvrFolder == nil) }
    }
    func tryAIDescription(cameraID: UUID) async throws -> EventDescription {
        write { $0.aiTries.append(cameraID) }
        try await Task.sleep(for: read { $0.aiTryDelay })
        return try read { $0.aiTry }.get()
    }
    func portAnswer(host: String, port: UInt16, timeout: Duration) async -> PortAnswer { read { $0.ports["\(host):\(port)"] ?? .silent } }
    func localIPv4Addresses() async -> [String] { read { $0.localAddresses } }
    func triggerTestMotion(cameraID: UUID) async { write { $0.calls.append("motion") } }
    func pause() async { write { $0.state = .paused } }
    func resume() async { write { $0.state = .running } }

    func diagnosticsReport(context: DiagnosticsContext) async -> String {
        "Camera Bridge diagnostics\nApp: \(context.appName) \(context.appVersion)\n"
    }

    var archive: (any ArchiveReading)? { read { $0.archive } }

    func inspectArchiveFolder(_ path: String) async throws -> ArchiveFolderReport {
        write { $0.calls.append("inspect:\(path)") }
        return try read { $0.folderReport }.get()
    }

    func setNVR(cameraID: UUID, enabled: Bool?, recordSound: Bool?) async throws {
        if let error = read({ $0.nvrError }) { throw error }
        try box.withLock { state in
            guard let index = state.configurations.firstIndex(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
            if let enabled { state.configurations[index].nvrEnabled = enabled }
            if let recordSound { state.configurations[index].nvrRecordSound = recordSound }
            state.calls.append("setNVR")
        }
    }

    func optimizeForHomeKit(cameraID: UUID) async throws -> HomeKitOptimizationResult {
        write { $0.calls.append("optimize") }
        if let gate = read({ $0.optimizeGate }) { await gate.wait() }
        return try read { $0.optimization }.get()
    }

    func undoHomeKitOptimization(cameraID: UUID) async throws {
        write { $0.calls.append("undo") }
        if let error = read({ $0.undoError }) { throw error }
    }

    func cameraSetupPreview(cameraID: UUID) async throws -> CameraSetupReport {
        write { $0.calls.append("setupPreview") }
        return try read { $0.setup }.get()
    }

    func applyCameraSetup(cameraID: UUID) async throws -> CameraSetupReport {
        try await applyCameraSetup(cameraID: cameraID, options: CameraSetupOptions())
    }

    func applyCameraSetup(cameraID: UUID, options: CameraSetupOptions) async throws -> CameraSetupReport {
        write { $0.calls.append("setupApply"); $0.setupOptions = options }
        if let gate = read({ $0.setupGate }) { await gate.wait() }
        return try read { $0.setup }.get()
    }

    func restoreCameraSetup(cameraID: UUID) async throws -> CameraSetupReport {
        write { $0.calls.append("setupRestore") }
        return try read { $0.setup }.get()
    }

    func checkCameraSecurity(cameraID: UUID) async throws -> CameraSecurity {
        write { $0.calls.append("checkSecurity") }
        return try read { $0.security }.get()
    }

    func restartCamera(cameraID: UUID) async throws {
        write { $0.calls.append("restartCamera") }
        if let error = read({ $0.restartError }) { throw error }
    }

    func skyNightLog(cameraID: UUID, night: String?, view: SkyLogView) async throws -> SkyNightLog {
        try box.withLock { state in
            state.skyCalls.append("night:\(cameraID.uuidString):\(night ?? "latest"):\(view.rawValue)")
            if let error = state.skyError { throw error }
            guard state.configurations.contains(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
            let entries = state.skyEntries.filter { $0.camera == cameraID }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            return SkyNightLog(camera: cameraID, night: night ?? "2026-10-24", view: view, from: Self.skyFrom, to: Self.skyTo, entries: entries,
                               conditions: state.skyConditions, counts: SkyCounts(counting: entries), aim: state.skyAim, learning: state.skyLearning,
                               capped: state.skyCapped)
        }
    }

    func correctSkyEntry(cameraID: UUID, entryID: String, night: String, label: SkyCorrection) async throws -> SkyEntry {
        try box.withLock { state in
            state.skyCalls.append("correct:\(entryID):\(night):\(label.rawValue)")
            if let error = state.skyError { throw error }
            guard state.configurations.contains(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
            guard let index = state.skyEntries.firstIndex(where: { $0.id == entryID && $0.camera == cameraID }) else { throw SkyLogError.unknownEntry }
            state.skyEntries[index].correction = label
            return state.skyEntries[index]
        }
    }

    func skyStill(cameraID: UUID, night: String, entryID: String) async throws -> Data {
        try box.withLock { state in
            state.skyCalls.append("still:\(entryID):\(night)")
            if let error = state.skyError { throw error }
            guard state.configurations.contains(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
            guard let jpeg = state.skyStills[entryID] else { throw SkyLogError.noStill }
            return jpeg
        }
    }

    func findFlightFeeds() async -> [URL] {
        box.withLock { state in
            state.skyCalls.append("feeds")
            return state.feeds
        }
    }
}

/// A system that records what it was asked.
final class FakeSystem: SystemControlling {
    let calls = Box<[String]>([])
    /// The setup hotspot while the test says it is open.
    let hotspot = Box<SetupHotspot?>(nil)
    let mode: String
    /// The certificate the TLS front has (nil: this system has no TLS front), and the hosts a certificate was asked for.
    let certificate = Box<CertificateStatus?>(nil)
    let obtained = Box<[String]>([])

    init(mode: String = "installed") { self.mode = mode }

    func certificateStatus() async -> CertificateStatus? { certificate.value }

    func obtainCertificate(name: String, host: String, privateKeyPEM: String) async throws {
        obtained.update { $0.append(host) }
    }

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

    func recordingDrives() async throws -> RecordingDriveReport {
        RecordingDriveReport(state: "internal", message: "Recording to this box's own disk.",
                             drives: [InstallTarget(id: "sdb", name: "sdb", model: "Elite", sizeBytes: 4_000_000_000_000, phrase: "ERASE ALL DATA ON sdb", isRecordingDrive: false, inUse: false)])
    }

    func useRecordingDrive(targetID: String, phrase: String, keepData: Bool) async throws {
        calls.update { $0.append("drive:\(targetID):\(phrase):\(keepData)") }
        if targetID == "bad" { throw SystemError("That disk can’t be used.") }
    }

    func forgetRecordingDrive() async throws { calls.update { $0.append("drive-forget") } }

    func wifi() async -> WifiReport {
        WifiReport(state: hotspot.value == nil ? "online" : "hotspot", message: "", ssid: hotspot.value == nil ? "Home" : nil, hotspot: hotspot.value, saved: ["Home"],
                   lastError: hotspot.value == nil ? nil : "Couldn’t join “Home”.", hasWifi: true,
                   networks: [WifiNetwork(ssid: "Home", signal: 70, security: "WPA2"), WifiNetwork(ssid: "Cafe", signal: 30, security: "")])
    }

    func scanWifi() async throws -> [WifiNetwork] { await wifi().networks }

    func joinWifi(ssid: String, password: String, restart: Bool) async throws {
        calls.update { $0.append("wifi:\(ssid):\(password.count):\(restart)") }
    }

    func forgetWifi(ssid: String) async throws { calls.update { $0.append("wifi-forget:\(ssid)") } }

    func setupHotspot() -> SetupHotspot? { hotspot.value }

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
