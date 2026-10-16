import BridgeEngine
import BridgeWeb
import CameraAdapters
import Foundation

/// The backend of `--preview`: the real one, except that it has no archive. A preview engine serves sample data and records nothing, so its
/// archive would stay "not ready" for ever and the NVR routes would answer `503 archive_unavailable` with `Retry-After` for ever; with no
/// archive they answer `503` without it, which the page takes as "this bridge has no recordings".
///
/// Every `BridgeBackend` requirement is forwarded, like `DemoDiscoveryBackend`'s; the compiler forces a new requirement to be added here too.
struct NoArchiveBackend: BridgeBackend {
    var base: any BridgeBackend

    init(wrapping base: any BridgeBackend) {
        self.base = base
    }

    func overview() async -> BridgeOverview { await base.overview() }
    func discoverCameras() async -> [DiscoveredCamera] { await base.discoverCameras() }

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
    func liveVideo(cameraID: UUID, stream: LiveVideoStream, displayWidth: Int?) async throws -> LiveVideoSubscription {
        try await base.liveVideo(cameraID: cameraID, stream: stream, displayWidth: displayWidth)
    }
    func liveVideo(cameraID: UUID, stream: LiveVideoStream, displayWidth: Int?, audio: Bool) async throws -> LiveVideoSubscription {
        try await base.liveVideo(cameraID: cameraID, stream: stream, displayWidth: displayWidth, audio: audio)
    }
    func setCameraClockShown(cameraID: UUID, shown: Bool) async throws -> CameraClockChange {
        try await base.setCameraClockShown(cameraID: cameraID, shown: shown)
    }
    func setCameraTimeZone(cameraID: UUID) async throws -> String { try await base.setCameraTimeZone(cameraID: cameraID) }
    func pluginSecret(id: String) async throws -> Data? { try await base.pluginSecret(id: id) }
    func portAnswer(host: String, port: UInt16, timeout: Duration) async -> PortAnswer { await base.portAnswer(host: host, port: port, timeout: timeout) }
    func localIPv4Addresses() async -> [String] { await base.localIPv4Addresses() }
    func setPluginSecret(id: String, _ data: Data?) async throws { try await base.setPluginSecret(id: id, data) }
    func setCleanPicture(cameraID: UUID, clean: Bool) async throws -> CleanPictureChange { try await base.setCleanPicture(cameraID: cameraID, clean: clean) }
    func cameraSetupPreview(cameraID: UUID) async throws -> CameraSetupReport { try await base.cameraSetupPreview(cameraID: cameraID) }
    func applyCameraSetup(cameraID: UUID) async throws -> CameraSetupReport { try await base.applyCameraSetup(cameraID: cameraID) }
    func restoreCameraSetup(cameraID: UUID) async throws -> CameraSetupReport { try await base.restoreCameraSetup(cameraID: cameraID) }
    func panTilt(cameraID: UUID, pan: Double, tilt: Double, zoom: Double) async throws { try await base.panTilt(cameraID: cameraID, pan: pan, tilt: tilt, zoom: zoom) }
    func triggerTestMotion(cameraID: UUID) async { await base.triggerTestMotion(cameraID: cameraID) }
    func pause() async { await base.pause() }
    func resume() async { await base.resume() }
    func diagnosticsReport(context: DiagnosticsContext) async -> String { await base.diagnosticsReport(context: context) }

    /// The one difference.
    var archive: (any ArchiveReading)? { nil }
    func inspectArchiveFolder(_ path: String) async throws -> ArchiveFolderReport { try await base.inspectArchiveFolder(path) }
    func setNVR(cameraID: UUID, enabled: Bool?, recordSound: Bool?) async throws {
        try await base.setNVR(cameraID: cameraID, enabled: enabled, recordSound: recordSound)
    }

    func optimizeForHomeKit(cameraID: UUID) async throws -> HomeKitOptimizationResult { try await base.optimizeForHomeKit(cameraID: cameraID) }
    func undoHomeKitOptimization(cameraID: UUID) async throws { try await base.undoHomeKitOptimization(cameraID: cameraID) }
}
