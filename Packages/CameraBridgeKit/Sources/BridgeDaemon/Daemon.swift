import BridgeEngine
import BridgeSupport
import BridgeWeb
import CameraAdapters
import Foundation
#if os(Linux)
import PlatformLinux
#endif

/// What this build of the daemon is.
public enum DaemonInfo {
    public static let product = "Camera Bridge OS"
    public static let version = "0.1"

    /// "development" unless the image says what it was built from (`CAMERA_BRIDGE_BUILD`).
    public static func build(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["CAMERA_BRIDGE_BUILD"].flatMap { $0.isEmpty ? nil : $0 } ?? "development"
    }
}

/// The engine and its web interface in one process: `start()` brings both up, `stop()` shuts both down in order.
///
/// - **Linux** (`BridgeEnvironment.linux`): the real platform services. `--dev` keeps the engine on loopback and silent.
/// - **macOS**: always `BridgeEnvironment.testing` — loopback only, nothing advertised, secrets in memory, a data directory you
///   name. A Mac is for developing the interface; the Mac app is the product there, and this never touches its data, its Keychain
///   or its ports.
@MainActor
public final class Daemon {
    public enum Failure: Error, CustomStringConvertible, Sendable {
        case needsDataDirectory
        case forbiddenDataDirectory(String)
        case cannotPrepare(String)
        case webInterface(String)

        public var description: String {
            switch self {
            case .needsDataDirectory: "On this system --data-dir is required (there is no default data directory)."
            case .forbiddenDataDirectory(let path): "\(path) belongs to the Camera Bridge app for Mac. Choose another directory."
            case .cannotPrepare(let reason): "The data directory can’t be used: \(reason)"
            case .webInterface(let reason): "The web interface can’t start: \(reason)"
            }
        }
    }

    public let options: DaemonOptions
    private let environment: [String: String]
    private let log = Log(category: "daemon")
    private var engine: BridgeEngine?
    private var web: WebService?
    private var tokens: [LogSinkToken] = []
    private var logFeed = LogFeed()
    private var started = false

    public init(options: DaemonOptions, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.options = options
        self.environment = environment
    }

    /// The port the web interface listens on; nil before `start()`.
    public private(set) var webPort: UInt16?

    public var engineState: EngineState? { engine?.state }

    // MARK: Start

    /// Starts the engine and the web interface and returns the web port. A web interface that cannot listen (the port is taken)
    /// throws; an engine that cannot start does not — the interface then shows why.
    @discardableResult
    public func start() async throws -> UInt16 {
        let directory = try Self.dataDirectory(for: options)
        do {
            try PrivateFiles.prepareDirectory(directory)
        } catch {
            throw Failure.cannotPrepare(String(describing: error))
        }
        installLogging(directory: directory)
        log.notice("Camera Bridge OS \(DaemonInfo.version) (\(DaemonInfo.build(environment: environment))) starting")

        let bridgeEnvironment = try Self.makeEnvironment(directory: directory, options: options)
        let engine = await makeEngine(environment: bridgeEnvironment)
        self.engine = engine
        if options.preview == nil { await engine.start() }

        var backend: any BridgeBackend = EngineBackend(engine: engine)
        if options.fakeDiscovery { backend = DemoDiscoveryBackend(wrapping: backend) }
        let folders = options.requestDirectories
        let system = RequestFileSystemControl(requestDirectory: folders.requests, statusDirectory: folders.status, product: DaemonInfo.product,
                                              version: DaemonInfo.version, build: DaemonInfo.build(environment: environment))
        log.notice(system.isAvailable ? "Camera Bridge OS: privileged requests go to \(folders.requests.path(percentEncoded: false))"
                                       : "no operating system underneath (\(folders.requests.path(percentEncoded: false)) is missing); updates, restarts and installs are off")
        var configuration = WebConfiguration(dataDirectory: directory, staticDirectory: options.staticDirectory ?? Self.defaultStaticDirectory(),
                                             port: options.port, loopbackOnly: options.webLoopbackOnly, allowedHosts: options.allowedHosts,
                                             setupToken: options.setupToken, product: DaemonInfo.product, version: DaemonInfo.version,
                                             build: DaemonInfo.build(environment: environment))
        configuration.offersDemoCamera = options.offersDemoCamera
        let build = DaemonInfo.build(environment: environment)
        configuration.diagnosticsContext = { launched in
            var context = DiagnosticsContext.current(appVersion: DaemonInfo.version, appBuild: build, macModel: HostInfo.hardwareModel(), launched: launched)
            context.appName = DaemonInfo.product
            context.macOSVersion = HostInfo.operatingSystemName()
            return context
        }
        let service = WebService(configuration: configuration, backend: backend, system: system, logs: logFeed, transport: bridgeEnvironment.platform.transport)
        do {
            let port = try await service.start()
            web = service
            webPort = port
            started = true
            log.notice("The web interface is at http://\(options.webLoopbackOnly ? "127.0.0.1" : "camera-bridge.local")\(port == 80 ? "" : ":\(port)")/")
            if options.staticDirectory == nil, Self.defaultStaticDirectory() == nil {
                log.warning("The web interface's files were not found; only the API is served (use --static-dir)")
            }
            return port
        } catch {
            await engine.stop()
            removeLogging()
            throw Failure.webInterface(String(describing: error))
        }
    }

    // MARK: Stop

    /// Stops the web interface (no new requests), then the engine (cameras, HomeKit accessories), within `timeout`.
    public func stop(timeout: Duration = .seconds(10)) async {
        guard started || engine != nil else { return }
        started = false
        log.notice("Camera Bridge OS is stopping")
        await web?.stop()
        web = nil
        if let engine {
            do {
                try await withDeadline(timeout) { await engine.stop() }
            } catch {
                log.warning("the engine did not stop within \(timeout)")
            }
        }
        engine = nil
        webPort = nil
        removeLogging()
    }

    /// Whether the bridge is in a state worth telling the watchdog about: the engine runs (or was paused on purpose) and the web
    /// interface still listens.
    public func isHealthy() async -> Bool {
        guard started, let web, await web.boundPort != nil, let state = engineState else { return false }
        switch state {
        case .running, .paused, .starting: return true
        case .stopped, .failed: return options.preview != nil
        }
    }

    // MARK: Engine

    private func makeEngine(environment: BridgeEnvironment) async -> BridgeEngine {
        if let scenario = options.preview.flatMap(PreviewScenario.init(rawValue:)) {
            return BridgeEngine.preview(scenario: scenario)
        }
        let engine = BridgeEngine(environment: environment)
        // Development runs keep away from ports other software on the machine may use.
        let hapBase = options.hapBasePort ?? (options.development ? 38_100 : nil)
        let sensorsPort = options.sensorsBridgePort ?? (options.development ? 0 : nil)
        if hapBase != nil || sensorsPort != nil {
            try? await engine.updateSettings { settings in
                if let hapBase { settings.basePort = hapBase }
                if let sensorsPort { settings.sensorsBridgePort = sensorsPort }
            }
        }
        return engine
    }

    /// The data directory: `--data-dir`, else `/var/lib/camera-bridge` on Linux. A Mac has no default and never accepts the Mac
    /// app's own.
    static func dataDirectory(for options: DaemonOptions) throws -> URL {
        #if os(Linux)
        let directory = options.dataDirectory ?? URL(fileURLWithPath: DaemonOptions.defaultDataDirectory, isDirectory: true)
        #else
        guard let directory = options.dataDirectory else { throw Failure.needsDataDirectory }
        #endif
        let path = directory.standardizedFileURL.path(percentEncoded: false)
        if path.contains("/Library/Application Support/CameraBridge") || path.contains("com.coreysilvia.CameraBridge") {
            throw Failure.forbiddenDataDirectory(path)
        }
        return directory
    }

    static func makeEnvironment(directory: URL, options: DaemonOptions) throws -> BridgeEnvironment {
        #if os(Linux)
        let log = Log(category: "daemon")
        let codecs = FFmpegMediaCodecs()
        do {
            // Probes ffmpeg and the GPU now, off the request path: the first use can take several seconds when the GPU stalls.
            try codecs.prepare()
            log.notice((try? codecs.capabilitySummary()) ?? "ffmpeg is ready")
        } catch {
            log.warning("ffmpeg is not usable (\(error)); video that needs transcoding will not work. Install ffmpeg.")
        }
        var environment = BridgeEnvironment.linux(dataDirectory: directory, codecs: codecs)
        if options.development {
            environment.loopbackOnly = true
            environment.advertise = false
        }
        return environment
        #elseif canImport(Darwin)
        return BridgeEnvironment.testing(directory: directory)
        #else
        throw Failure.cannotPrepare("this platform has no bridge environment yet")
        #endif
    }

    // MARK: Files

    /// Where the interface's files are: next to the installed system, or in the repository (`linux/web`) when run from a build.
    static func defaultStaticDirectory() -> URL? {
        let fileManager = FileManager.default
        func usable(_ url: URL) -> URL? {
            fileManager.fileExists(atPath: url.appending(path: "index.html").path(percentEncoded: false)) ? url : nil
        }
        if let installed = usable(URL(fileURLWithPath: "/usr/share/camera-bridge/web", isDirectory: true)) { return installed }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "", relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath))
            .standardizedFileURL
        var directory = executable.deletingLastPathComponent()
        if let beside = usable(directory.deletingLastPathComponent().appending(path: "share/camera-bridge/web", directoryHint: .isDirectory)) { return beside }
        for _ in 0..<10 {
            if let found = usable(directory.appending(path: "linux/web", directoryHint: .isDirectory)) { return found }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return usable(URL(fileURLWithPath: fileManager.currentDirectoryPath).appending(path: "linux/web", directoryHint: .isDirectory))
    }

    // MARK: Logging

    private func installLogging(directory: URL) {
        let diagnostics = DiagnosticsCenter.shared.install(directory: directory.appending(path: "Diagnostics", directoryHint: .isDirectory))
        _ = diagnostics
        logFeed = LogFeed(capacity: 2_000, minimumLevel: .info)
        tokens = [
            LogHub.addSink(StdoutLogSink(minimumLevel: options.logLevel, journal: SystemD.logsToJournal(environment: environment))),
            LogHub.addSink(logFeed),
        ]
    }

    private func removeLogging() {
        for token in tokens { LogHub.removeSink(token) }
        tokens = []
    }
}

// MARK: - Development helpers

/// The real backend, except that "find cameras" answers with three sample cameras (documentation addresses), so the Add Camera page
/// can be looked at on a machine with no cameras. `--fake-discovery`.
struct DemoDiscoveryBackend: BridgeBackend {
    var base: any BridgeBackend

    init(wrapping base: any BridgeBackend) {
        self.base = base
    }

    func overview() async -> BridgeOverview { await base.overview() }

    func discoverCameras() async -> [DiscoveredCamera] {
        try? await Task.sleep(for: .seconds(1))
        return [
            DiscoveredCamera(host: "192.0.2.21", name: "Driveway", hardware: "DS-2CD2143G2", xAddrs: [URL(string: "http://192.0.2.21/onvif/device_service")!]),
            DiscoveredCamera(host: "192.0.2.34", name: "Front Door", hardware: "RLC-811A", xAddrs: [URL(string: "http://192.0.2.34:8000/onvif/device_service")!]),
            DiscoveredCamera(host: "192.0.2.57", name: nil, hardware: "C320WS", xAddrs: [URL(string: "http://192.0.2.57:2020/onvif/device_service")!]),
        ]
    }

    func probeCamera(vendor: CameraVendor?, endpoint: CameraEndpoint, username: String, password: String, mainStreamURL: URL?,
                     subStreamURL: URL?) async throws -> CameraProbeResult {
        try await base.probeCamera(vendor: vendor, endpoint: endpoint, username: username, password: password, mainStreamURL: mainStreamURL, subStreamURL: subStreamURL)
    }

    func probeIntegration(vendor: CameraVendor, integration: IntegrationSettings, endpoint: CameraEndpoint, username: String,
                          secret: String) async throws -> CameraProbeResult {
        try await base.probeIntegration(vendor: vendor, integration: integration, endpoint: endpoint, username: username, secret: secret)
    }

    func unifiProtectCameras(endpoint: CameraEndpoint, apiKey: String) async throws -> [UnifiProtectCamera] {
        try await base.unifiProtectCameras(endpoint: endpoint, apiKey: apiKey)
    }

    func addCamera(_ configuration: CameraConfiguration, password: String?) async throws { try await base.addCamera(configuration, password: password) }
    func updateCamera(_ configuration: CameraConfiguration, password: String?) async throws { try await base.updateCamera(configuration, password: password) }
    func removeCamera(id: UUID) async { await base.removeCamera(id: id) }
    func resetPairing(cameraID: UUID) async throws { try await base.resetPairing(cameraID: cameraID) }
    func resetSensorsBridgePairing() async throws { try await base.resetSensorsBridgePairing() }
    func updateSettings(_ change: @Sendable @escaping (inout BridgeSettings) -> Void) async throws { try await base.updateSettings(change) }
    func snapshotJPEG(cameraID: UUID) async -> Data? { await base.snapshotJPEG(cameraID: cameraID) }
    func triggerTestMotion(cameraID: UUID) async { await base.triggerTestMotion(cameraID: cameraID) }
    func pause() async { await base.pause() }
    func resume() async { await base.resume() }
    func diagnosticsReport(context: DiagnosticsContext) async -> String { await base.diagnosticsReport(context: context) }
}
