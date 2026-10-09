import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation

/// Everything the web API reads from the bridge at one moment (one hop to the engine's actor).
public struct BridgeOverview: Sendable {
    public var state: EngineState
    public var cameras: [CameraStatus]
    public var configurations: [CameraConfiguration]
    public var sensorsBridge: SensorsBridgeStatus?
    public var localNetworkAccess: LocalNetworkAccess
    public var networkNotices: [NetworkNotice]
    public var settings: BridgeSettings
    public var webhookProblem: String?
    /// A damaged configuration was set aside and the bridge started without it.
    public var configurationRecovered: Bool
    /// The go2rtc helper (cloud cameras, consoles) is part of this installation.
    public var streamingHelperInstalled: Bool

    public init(state: EngineState, cameras: [CameraStatus], configurations: [CameraConfiguration], sensorsBridge: SensorsBridgeStatus? = nil,
                localNetworkAccess: LocalNetworkAccess = .unknown, networkNotices: [NetworkNotice] = [], settings: BridgeSettings = BridgeSettings(),
                webhookProblem: String? = nil, configurationRecovered: Bool = false, streamingHelperInstalled: Bool = false) {
        self.state = state
        self.cameras = cameras
        self.configurations = configurations
        self.sensorsBridge = sensorsBridge
        self.localNetworkAccess = localNetworkAccess
        self.networkNotices = networkNotices
        self.settings = settings
        self.webhookProblem = webhookProblem
        self.configurationRecovered = configurationRecovered
        self.streamingHelperInstalled = streamingHelperInstalled
    }
}

/// What the web API needs from the bridge. `EngineBackend` is the real one (the engine, which lives on the main actor); tests and
/// the daemon's demo mode stand in for parts of it.
public protocol BridgeBackend: Sendable {
    func overview() async -> BridgeOverview
    func discoverCameras() async -> [DiscoveredCamera]
    func probeCamera(vendor: CameraVendor?, endpoint: CameraEndpoint, username: String, password: String, mainStreamURL: URL?,
                     subStreamURL: URL?) async throws -> CameraProbeResult
    func probeIntegration(vendor: CameraVendor, integration: IntegrationSettings, endpoint: CameraEndpoint, username: String,
                          secret: String) async throws -> CameraProbeResult
    func unifiProtectCameras(endpoint: CameraEndpoint, apiKey: String) async throws -> [UnifiProtectCamera]
    func addCamera(_ configuration: CameraConfiguration, password: String?) async throws
    func updateCamera(_ configuration: CameraConfiguration, password: String?) async throws
    func removeCamera(id: UUID) async
    func resetPairing(cameraID: UUID) async throws
    func resetSensorsBridgePairing() async throws
    func updateSettings(_ change: @Sendable @escaping (inout BridgeSettings) -> Void) async throws
    func snapshotJPEG(cameraID: UUID) async -> Data?
    func triggerTestMotion(cameraID: UUID) async
    func pause() async
    func resume() async
    func diagnosticsReport(context: DiagnosticsContext) async -> String
}

/// The engine behind the web API.
public struct EngineBackend: BridgeBackend {
    private let engine: BridgeEngine

    public init(engine: BridgeEngine) {
        self.engine = engine
    }

    public func overview() async -> BridgeOverview {
        await MainActor.run {
            BridgeOverview(state: engine.state, cameras: engine.cameras, configurations: engine.configurations, sensorsBridge: engine.sensorsBridge,
                           localNetworkAccess: engine.localNetworkAccess, networkNotices: engine.recentNetworkNotices, settings: engine.settings,
                           webhookProblem: engine.webhookProblem, configurationRecovered: engine.configurationRecoveredFrom != nil,
                           streamingHelperInstalled: engine.isStreamingHelperInstalled)
        }
    }

    public func discoverCameras() async -> [DiscoveredCamera] {
        await engine.discoverCameras()
    }

    public func probeCamera(vendor: CameraVendor?, endpoint: CameraEndpoint, username: String, password: String, mainStreamURL: URL?,
                            subStreamURL: URL?) async throws -> CameraProbeResult {
        try await engine.probeCamera(vendor: vendor, endpoint: endpoint, username: username, password: password, mainStreamURL: mainStreamURL,
                                     subStreamURL: subStreamURL)
    }

    public func probeIntegration(vendor: CameraVendor, integration: IntegrationSettings, endpoint: CameraEndpoint, username: String,
                                 secret: String) async throws -> CameraProbeResult {
        try await engine.probeIntegration(vendor: vendor, integration: integration, endpoint: endpoint, username: username, secret: secret)
    }

    public func unifiProtectCameras(endpoint: CameraEndpoint, apiKey: String) async throws -> [UnifiProtectCamera] {
        try await CameraDrivers.unifiProtectCameras(endpoint: endpoint, apiKey: apiKey)
    }

    public func addCamera(_ configuration: CameraConfiguration, password: String?) async throws {
        try await engine.addCamera(configuration, password: password)
    }

    public func updateCamera(_ configuration: CameraConfiguration, password: String?) async throws {
        try await engine.updateCamera(configuration, password: password)
    }

    public func removeCamera(id: UUID) async {
        await engine.removeCamera(id: id)
    }

    public func resetPairing(cameraID: UUID) async throws {
        try await engine.resetPairing(cameraID: cameraID)
    }

    public func resetSensorsBridgePairing() async throws {
        try await engine.resetSensorsBridgePairing()
    }

    public func updateSettings(_ change: @Sendable @escaping (inout BridgeSettings) -> Void) async throws {
        try await engine.updateSettings(change)
    }

    public func snapshotJPEG(cameraID: UUID) async -> Data? {
        await engine.snapshot(cameraID: cameraID)
    }

    public func triggerTestMotion(cameraID: UUID) async {
        await engine.triggerTestMotion(cameraID: cameraID)
    }

    public func pause() async {
        await engine.pause()
    }

    public func resume() async {
        await engine.resume()
    }

    public func diagnosticsReport(context: DiagnosticsContext) async -> String {
        await engine.diagnosticsReport(context: context)
    }
}
