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
    /// The recordings folder as numbers; nil before the first measurement.
    public var nvrStorage: ArchiveStorageStatus?
    /// The internet guard's notice for the day (`BridgeEngine.internetGuardNotice`); nil when nothing was blocked today or there is no guard.
    public var internetGuardNotice: InternetGuardNotice?

    public init(state: EngineState, cameras: [CameraStatus], configurations: [CameraConfiguration], sensorsBridge: SensorsBridgeStatus? = nil,
                localNetworkAccess: LocalNetworkAccess = .unknown, networkNotices: [NetworkNotice] = [], settings: BridgeSettings = BridgeSettings(),
                webhookProblem: String? = nil, configurationRecovered: Bool = false, streamingHelperInstalled: Bool = false,
                nvrStorage: ArchiveStorageStatus? = nil, internetGuardNotice: InternetGuardNotice? = nil) {
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
        self.nvrStorage = nvrStorage
        self.internetGuardNotice = internetGuardNotice
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
    /// `BridgeEngine.snapshot(cameraID:original:)`: the camera's picture, straightened by its picture correction unless `original`.
    func snapshotJPEG(cameraID: UUID, original: Bool) async -> Data?
    /// `BridgeEngine.liveVideo(cameraID:stream:audio:displayWidth:)` without audio: the camera's encoded video from the newest keyframe on, for the
    /// page's live video. The default throws `EngineError.cameraNotRunning` (a backend without cameras of its own).
    func liveVideo(cameraID: UUID, stream: LiveVideoStream, displayWidth: Int?) async throws -> LiveVideoSubscription
    /// The same with the camera's sound as AAC-LC when `audio` is true (`BridgeEngine.browserLiveVideo`). The default serves video only and throws
    /// `EngineError.cameraNotRunning` when sound is asked for, so a backend written before it still compiles.
    func liveVideo(cameraID: UUID, stream: LiveVideoStream, displayWidth: Int?, audio: Bool) async throws -> LiveVideoSubscription
    /// `BridgeEngine.setCameraClockHidden(cameraID:hidden:)` with `hidden: !shown`: the camera's own date and time on its picture. Default throws.
    func setCameraClockShown(cameraID: UUID, shown: Bool) async throws -> CameraClockChange
    /// `BridgeEngine.setCameraTimeZone(cameraID:)`: the camera's clock in the bridge's time zone; returns the POSIX zone. Default throws.
    func setCameraTimeZone(cameraID: UUID) async throws -> String
    /// `BridgeEngine.setCleanPicture(cameraID:clean:)`: every label the camera draws itself off, or back. Default throws.
    func setCleanPicture(cameraID: UUID, clean: Bool) async throws -> CleanPictureChange
    /// `BridgeEngine.cameraSetupPreview(cameraID:)`: what "Set up for Camera Bridge" would change (reads the camera only). Default throws.
    func cameraSetupPreview(cameraID: UUID) async throws -> CameraSetupReport
    /// `BridgeEngine.applyCameraSetup(cameraID:)`. Default throws.
    func applyCameraSetup(cameraID: UUID) async throws -> CameraSetupReport
    /// `BridgeEngine.applyCameraSetup(cameraID:options:)`: the run with the person's choices ("Fix its address so the DNS stays"). The
    /// default runs `applyCameraSetup(cameraID:)` without any, and refuses a choice it can't make before anything is changed.
    func applyCameraSetup(cameraID: UUID, options: CameraSetupOptions) async throws -> CameraSetupReport
    /// `BridgeEngine.restoreCameraSetup(cameraID:)`. Default throws.
    func restoreCameraSetup(cameraID: UUID) async throws -> CameraSetupReport
    /// `BridgeEngine.restartCamera(id:)`: "Restart the camera now", only for a camera that waits for it. Default throws.
    func restartCamera(cameraID: UUID) async throws
    /// Moves a pan/tilt camera (`BridgeEngine.panTilt`).
    func panTilt(cameraID: UUID, pan: Double, tilt: Double, zoom: Double) async throws
    /// Sets a camera's night vision and/or lamp (`BridgeEngine.setNightVision`).
    func setNightVision(cameraID: UUID, mode: NightVisionMode?, light: Bool?) async throws
    /// `BridgeEngine.checkCameraSecurity(cameraID:)`: checks the camera now and answers its security level. Default throws.
    func checkCameraSecurity(cameraID: UUID) async throws -> CameraSecurity
    /// `BridgeEngine.localIPv4Addresses()`. The default has none.
    func localIPv4Addresses() async -> [String]
    /// `BridgeEngine.portAnswer(host:port:timeout:)`. The default never reaches anything (`.silent`).
    func portAnswer(host: String, port: UInt16, timeout: Duration) async -> PortAnswer
    /// `BridgeEngine.pluginSecret(id:)`: a plugin's stored secret. The default has none.
    func pluginSecret(id: String) async throws -> Data?
    /// `BridgeEngine.setPluginSecret(id:_:)`. The default throws `EngineError.cameraNotRunning` (a backend that keeps no secrets).
    func setPluginSecret(id: String, _ data: Data?) async throws
    /// `BridgeEngine.aiKeyStatus()`: whether the AI service's key is saved and the last four characters of it. The key itself never leaves the
    /// engine. The default has none.
    func aiKeyStatus() async -> (saved: Bool, hint: String?)
    /// `BridgeEngine.setAIKey(_:)`: saves the key, trimmed; nil deletes it. The default throws `EngineError.cameraNotRunning` (a backend that
    /// keeps no secrets).
    func setAIKey(_ key: String?) async throws
    /// `BridgeEngine.aiStatus()`: the AI descriptions' counts, limit and last failure. The default has described nothing, and needs a
    /// recordings folder while none is chosen.
    func aiStatus() async -> AIStatus
    /// `BridgeEngine.tryAIDescription(cameraID:)`: Try it. The default throws `AIDescriberError.noService` (a backend without a describer).
    func tryAIDescription(cameraID: UUID) async throws -> EventDescription
    func triggerTestMotion(cameraID: UUID) async
    func pause() async
    func resume() async
    func diagnosticsReport(context: DiagnosticsContext) async -> String
    /// Where recorded video is read from; nil when this backend has no archive (a `--preview` daemon). Synchronous and cheap: the media routes ask it on every request.
    var archive: (any ArchiveReading)? { get }
    /// `ArchiveFolderCheck.inspect` for `path` with the engine's platform policy; throws `ArchiveFolderError`.
    func inspectArchiveFolder(_ path: String) async throws -> ArchiveFolderReport
    /// `BridgeEngine.setNVR(cameraID:enabled:recordSound:)`.
    func setNVR(cameraID: UUID, enabled: Bool?, recordSound: Bool?) async throws
    /// `BridgeEngine.optimizeForHomeKit(cameraID:)`: applies the HomeKit optimizer's automatic fixes (it holds the engine's operations lock for 20 to 40 s).
    func optimizeForHomeKit(cameraID: UUID) async throws -> HomeKitOptimizationResult
    /// `BridgeEngine.undoHomeKitOptimization(cameraID:)`.
    func undoHomeKitOptimization(cameraID: UUID) async throws
}

/// The engine behind the web API.
public struct EngineBackend: BridgeBackend {
    private let engine: BridgeEngine

    public init(engine: BridgeEngine) {
        self.engine = engine
    }

    public func overview() async -> BridgeOverview {
        await MainActor.run {
            // "Change it by hand" on the findings the setup can't change goes with each camera's status (`withManualHelp`).
            BridgeOverview(state: engine.state, cameras: engine.withManualHelp(engine.cameras), configurations: engine.configurations, sensorsBridge: engine.sensorsBridge,
                           localNetworkAccess: engine.localNetworkAccess, networkNotices: engine.recentNetworkNotices, settings: engine.settings,
                           webhookProblem: engine.webhookProblem, configurationRecovered: engine.configurationRecoveredFrom != nil,
                           streamingHelperInstalled: engine.isStreamingHelperInstalled, nvrStorage: engine.nvrStorage,
                           internetGuardNotice: engine.internetGuardNotice)
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

    public func snapshotJPEG(cameraID: UUID, original: Bool) async -> Data? {
        await engine.snapshot(cameraID: cameraID, original: original)
    }

    public func liveVideo(cameraID: UUID, stream: LiveVideoStream, displayWidth: Int?) async throws -> LiveVideoSubscription {
        try await engine.liveVideo(cameraID: cameraID, stream: stream, audio: false, displayWidth: displayWidth)
    }

    public func liveVideo(cameraID: UUID, stream: LiveVideoStream, displayWidth: Int?, audio: Bool) async throws -> LiveVideoSubscription {
        try await engine.browserLiveVideo(cameraID: cameraID, stream: stream, displayWidth: displayWidth, audio: audio)
    }

    public func setCameraClockShown(cameraID: UUID, shown: Bool) async throws -> CameraClockChange {
        try await engine.setCameraClockHidden(cameraID: cameraID, hidden: !shown)
    }

    public func setCameraTimeZone(cameraID: UUID) async throws -> String {
        try await engine.setCameraTimeZone(cameraID: cameraID)
    }

    public func setCleanPicture(cameraID: UUID, clean: Bool) async throws -> CleanPictureChange {
        try await engine.setCleanPicture(cameraID: cameraID, clean: clean)
    }

    public func panTilt(cameraID: UUID, pan: Double, tilt: Double, zoom: Double) async throws {
        try await engine.panTilt(cameraID: cameraID, pan: pan, tilt: tilt, zoom: zoom)
    }

    public func setNightVision(cameraID: UUID, mode: NightVisionMode?, light: Bool?) async throws {
        try await engine.setNightVision(cameraID: cameraID, mode: mode, light: light)
    }

    public func portAnswer(host: String, port: UInt16, timeout: Duration) async -> PortAnswer {
        await engine.portAnswer(host: host, port: port, timeout: timeout)
    }

    public func localIPv4Addresses() async -> [String] {
        engine.localIPv4Addresses()
    }

    public func pluginSecret(id: String) async throws -> Data? {
        try await engine.pluginSecret(id: id)
    }

    public func setPluginSecret(id: String, _ data: Data?) async throws {
        try await engine.setPluginSecret(id: id, data)
    }

    public func aiKeyStatus() async -> (saved: Bool, hint: String?) {
        await engine.aiKeyStatus()
    }

    public func setAIKey(_ key: String?) async throws {
        try await engine.setAIKey(key)
    }

    public func aiStatus() async -> AIStatus {
        await engine.aiStatus()
    }

    public func tryAIDescription(cameraID: UUID) async throws -> EventDescription {
        try await engine.tryAIDescription(cameraID: cameraID)
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

    public var archive: (any ArchiveReading)? { engine.archive }

    public func inspectArchiveFolder(_ path: String) async throws -> ArchiveFolderReport {
        guard BridgeSettings.isValidNVRFolder(path) else { throw ArchiveFolderError.invalidPath }
        return try await engine.inspectArchiveFolder(URL(fileURLWithPath: path, isDirectory: true))
    }

    public func setNVR(cameraID: UUID, enabled: Bool?, recordSound: Bool?) async throws {
        try await engine.setNVR(cameraID: cameraID, enabled: enabled, recordSound: recordSound)
    }

    public func optimizeForHomeKit(cameraID: UUID) async throws -> HomeKitOptimizationResult {
        try await engine.optimizeForHomeKit(cameraID: cameraID)
    }

    public func undoHomeKitOptimization(cameraID: UUID) async throws {
        try await engine.undoHomeKitOptimization(cameraID: cameraID)
    }

    // The preview, the run and the check carry "Change it by hand" for the page (`BridgeEngine.withManualHelp`): the steps the camera refused
    // or does not support, the findings the setup can't change. A restore's report carries none: its help would say how to make the change
    // Restore is undoing.

    public func cameraSetupPreview(cameraID: UUID) async throws -> CameraSetupReport {
        let report = try await engine.cameraSetupPreview(cameraID: cameraID)
        return await engine.withManualHelp(report, cameraID: cameraID)
    }

    public func applyCameraSetup(cameraID: UUID) async throws -> CameraSetupReport {
        try await applyCameraSetup(cameraID: cameraID, options: CameraSetupOptions())
    }

    public func applyCameraSetup(cameraID: UUID, options: CameraSetupOptions) async throws -> CameraSetupReport {
        let report = try await engine.applyCameraSetup(cameraID: cameraID, options: options)
        return await engine.withManualHelp(report, cameraID: cameraID)
    }

    public func restoreCameraSetup(cameraID: UUID) async throws -> CameraSetupReport {
        try await engine.restoreCameraSetup(cameraID: cameraID)
    }

    public func restartCamera(cameraID: UUID) async throws {
        try await engine.restartCamera(id: cameraID)
    }

    public func checkCameraSecurity(cameraID: UUID) async throws -> CameraSecurity {
        let security = try await engine.checkCameraSecurity(cameraID: cameraID)
        return await engine.withManualHelp(security, cameraID: cameraID)
    }
}

extension BridgeBackend {
    public func pluginSecret(id: String) async throws -> Data? { nil }

    public func portAnswer(host: String, port: UInt16, timeout: Duration) async -> PortAnswer { .silent }

    public func localIPv4Addresses() async -> [String] { [] }

    public func setPluginSecret(id: String, _ data: Data?) async throws {
        throw EngineError.cameraNotRunning
    }

    public func aiKeyStatus() async -> (saved: Bool, hint: String?) { (false, nil) }

    public func setAIKey(_ key: String?) async throws {
        throw EngineError.cameraNotRunning
    }

    public func aiStatus() async -> AIStatus {
        AIStatus(needsRecordingsFolder: await overview().settings.nvrFolder == nil)
    }

    public func tryAIDescription(cameraID: UUID) async throws -> EventDescription {
        throw AIDescriberError.noService
    }

    public func liveVideo(cameraID: UUID, stream: LiveVideoStream, displayWidth: Int?) async throws -> LiveVideoSubscription {
        throw EngineError.cameraNotRunning
    }

    public func liveVideo(cameraID: UUID, stream: LiveVideoStream, displayWidth: Int?, audio: Bool) async throws -> LiveVideoSubscription {
        guard !audio else { throw EngineError.cameraNotRunning }
        return try await liveVideo(cameraID: cameraID, stream: stream, displayWidth: displayWidth)
    }

    public func setCameraClockShown(cameraID: UUID, shown: Bool) async throws -> CameraClockChange {
        throw EngineError.cameraNotRunning
    }

    public func setCameraTimeZone(cameraID: UUID) async throws -> String {
        throw EngineError.cameraNotRunning
    }

    public func setCleanPicture(cameraID: UUID, clean: Bool) async throws -> CleanPictureChange {
        throw EngineError.cameraNotRunning
    }

    public func cameraSetupPreview(cameraID: UUID) async throws -> CameraSetupReport {
        throw EngineError.cameraNotRunning
    }

    public func applyCameraSetup(cameraID: UUID) async throws -> CameraSetupReport {
        throw EngineError.cameraNotRunning
    }

    public func applyCameraSetup(cameraID: UUID, options: CameraSetupOptions) async throws -> CameraSetupReport {
        guard options == CameraSetupOptions() else { throw EngineError.invalidSettings("this bridge can’t fix a camera’s address") }
        return try await applyCameraSetup(cameraID: cameraID)
    }

    public func restoreCameraSetup(cameraID: UUID) async throws -> CameraSetupReport {
        throw EngineError.cameraNotRunning
    }

    public func restartCamera(cameraID: UUID) async throws {
        throw EngineError.cameraNotRunning
    }

    public func panTilt(cameraID: UUID, pan: Double, tilt: Double, zoom: Double) async throws {
        throw EngineError.cameraNotRunning
    }

    public func setNightVision(cameraID: UUID, mode: NightVisionMode?, light: Bool?) async throws {
        throw EngineError.cameraNotRunning
    }

    public func checkCameraSecurity(cameraID: UUID) async throws -> CameraSecurity {
        throw EngineError.cameraNotRunning
    }
}
