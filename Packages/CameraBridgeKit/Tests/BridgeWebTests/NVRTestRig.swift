import BridgeEngine
import BridgeSupport
import CameraAdapters
import FMP4
import Foundation
import Synchronization
@testable import BridgeWeb

/// A signed-in web application over a fake backend that has one camera, a recordings folder and (optionally) an archive: what every NVR route
/// test starts from.
struct NVRRig {
    static let folder = "/var/lib/camera-bridge/recordings"
    static let builtin = ArchiveLocation(id: "builtin", label: "This box’s storage", path: folder)
    /// 2026-09-14 12:00:00 UTC in epoch milliseconds: inside the range the API accepts, and far from "now" so the tests never depend on it.
    static let base: Int64 = 1_789_387_200_000

    let harness: Harness
    let backend: FakeBackend
    let session: Harness.Session
    let camera: CameraConfiguration

    var cameraID: String { camera.id.uuidString }

    static func make(archive: FakeArchiveReading? = nil, folder: String? = NVRRig.folder, locations: [ArchiveLocation] = [NVRRig.builtin],
                     modify: (inout WebConfiguration) -> Void = { _ in }) async throws -> NVRRig {
        let backend = FakeBackend()
        let camera = CameraConfiguration(name: "Porch", kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "")
        backend.write {
            $0.configurations = [camera]
            $0.settings.nvrFolder = folder
            $0.archive = archive
        }
        let harness = try Harness(backend: backend) { configuration in
            configuration.archiveLocations = locations
            modify(&configuration)
        }
        return NVRRig(harness: harness, backend: backend, session: try await harness.signIn(), camera: camera)
    }

    /// A file of the rig's camera under its UUID directory, starting `offsetMs` after `base`.
    func file(_ name: String = "13-24-05", date: String = "2026-09-14", offsetMs: Int64 = 0, fragments: Int = 4, framesPerFragment: Int = 25, frameTicks: Int64 = 3_600,
              gopFragments: Int = 1, audio: Bool = false) throws -> ArchiveFixtureFile {
        try ArchiveFixture.file(camera: camera.id, segment: "\(camera.id.uuidString)/\(date)/\(name)", startMs: Double(Self.base + offsetMs), fragments: fragments,
                                framesPerFragment: framesPerFragment, frameTicks: frameTicks, gopFragments: gopFragments, audio: audio)
    }

    func get(_ path: String) async -> Answer { await session.get("/api/v1/\(path)") }

    func ms(_ offsetMs: Int64) -> Int64 { Self.base + offsetMs }
}

/// The base media decode time (`tfdt`) of the first track fragment in `fragment`: a stored fragment (it starts with a `prft`) or a served one
/// (`moof` + `mdat`). nil when there is none.
func baseMediaDecodeTime(in fragment: Data) throws -> Int64? {
    guard let tfdt = try MP4BoxReader.parse(fragment).first(where: { $0.type == "moof" })?.child("traf")?.child("tfdt") else { return nil }
    let start = fragment.startIndex + tfdt.payloadOffset
    let width = fragment[start] == 1 ? 8 : 4   // version 1 has a 64-bit time
    return fragment[(start + 4)..<(start + 4 + width)].reduce(Int64(0)) { $0 << 8 | Int64($1) }
}

/// A JSON number as an integer, whichever number type the platform's JSON reader produced.
func jsonInt(_ value: Any?) -> Int64? {
    if let number = value as? Int64 { return number }
    if let number = value as? Int { return Int64(number) }
    return nil
}

extension Answer {
    func array(_ key: String) -> [[String: Any]] { (json[key] as? [[String: Any]]) ?? [] }
    func object(_ key: String) -> [String: Any] { (json[key] as? [String: Any]) ?? [:] }
    func int(_ key: String) -> Int64? { jsonInt(json[key]) }
}

/// Collects the log lines written while a test runs (the shared `LogHub` at debug level, so the web application's per-request line is seen).
/// Call `stop()` when done: it restores the level.
final class LogCapture: LogSink {
    private let lines = Mutex<[String]>([])
    private let token = Mutex<LogSinkToken?>(nil)
    private let previousLevel: LogLevel

    init() {
        previousLevel = LogHub.minimumLevel
        LogHub.minimumLevel = .debug
        token.withLock { $0 = LogHub.addSink(self) }
    }

    func record(_ entry: LogEntry) { lines.withLock { $0.append("\(entry.category): \(entry.message)") } }
    var text: [String] { lines.withLock { $0 } }

    func stop() {
        if let registered = token.withLock({ value -> LogSinkToken? in defer { value = nil }; return value }) { LogHub.removeSink(registered) }
        LogHub.minimumLevel = previousLevel
    }
}

/// A backend that forwards to a `FakeBackend`, counts the settings changes and the folder checks (a route makes exactly one change per request;
/// one check at a time per folder), and can hold the folder check (`folderGate`) the way a hung drive does.
final class CountingBackend: BridgeBackend {
    let base: FakeBackend
    let settingsChanges = Mutex(0)
    let folderChecks = Mutex(0)
    let folderGate = Mutex<AsyncGate?>(nil)

    init(_ base: FakeBackend) { self.base = base }

    func updateSettings(_ change: @Sendable @escaping (inout BridgeSettings) -> Void) async throws {
        settingsChanges.withLock { $0 += 1 }
        try await base.updateSettings(change)
    }

    func inspectArchiveFolder(_ path: String) async throws -> ArchiveFolderReport {
        folderChecks.withLock { $0 += 1 }
        if let gate = folderGate.withLock({ $0 }) { await gate.wait() }
        return try await base.inspectArchiveFolder(path)
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
    func unifiProtectCameras(endpoint: CameraEndpoint, apiKey: String) async throws -> [UnifiProtectCamera] { try await base.unifiProtectCameras(endpoint: endpoint, apiKey: apiKey) }
    func addCamera(_ configuration: CameraConfiguration, password: String?) async throws { try await base.addCamera(configuration, password: password) }
    func updateCamera(_ configuration: CameraConfiguration, password: String?) async throws { try await base.updateCamera(configuration, password: password) }
    func removeCamera(id: UUID) async { await base.removeCamera(id: id) }
    func resetPairing(cameraID: UUID) async throws { try await base.resetPairing(cameraID: cameraID) }
    func resetSensorsBridgePairing() async throws { try await base.resetSensorsBridgePairing() }
    func snapshotJPEG(cameraID: UUID, original: Bool) async -> Data? { await base.snapshotJPEG(cameraID: cameraID, original: original) }
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
    func aiKeyStatus() async -> (saved: Bool, hint: String?) { await base.aiKeyStatus() }
    func setAIKey(_ key: String?) async throws { try await base.setAIKey(key) }
    func setCleanPicture(cameraID: UUID, clean: Bool) async throws -> CleanPictureChange { try await base.setCleanPicture(cameraID: cameraID, clean: clean) }
    func cameraSetupPreview(cameraID: UUID) async throws -> CameraSetupReport { try await base.cameraSetupPreview(cameraID: cameraID) }
    func applyCameraSetup(cameraID: UUID) async throws -> CameraSetupReport { try await base.applyCameraSetup(cameraID: cameraID) }
    func applyCameraSetup(cameraID: UUID, options: CameraSetupOptions) async throws -> CameraSetupReport {
        try await base.applyCameraSetup(cameraID: cameraID, options: options)
    }
    func restoreCameraSetup(cameraID: UUID) async throws -> CameraSetupReport { try await base.restoreCameraSetup(cameraID: cameraID) }
    func panTilt(cameraID: UUID, pan: Double, tilt: Double, zoom: Double) async throws { try await base.panTilt(cameraID: cameraID, pan: pan, tilt: tilt, zoom: zoom) }
    func setNightVision(cameraID: UUID, mode: NightVisionMode?, light: Bool?) async throws { try await base.setNightVision(cameraID: cameraID, mode: mode, light: light) }
    func triggerTestMotion(cameraID: UUID) async { await base.triggerTestMotion(cameraID: cameraID) }
    func pause() async { await base.pause() }
    func resume() async { await base.resume() }
    func diagnosticsReport(context: DiagnosticsContext) async -> String { await base.diagnosticsReport(context: context) }
    var archive: (any ArchiveReading)? { base.archive }
    func setNVR(cameraID: UUID, enabled: Bool?, recordSound: Bool?) async throws { try await base.setNVR(cameraID: cameraID, enabled: enabled, recordSound: recordSound) }
    func optimizeForHomeKit(cameraID: UUID) async throws -> HomeKitOptimizationResult { try await base.optimizeForHomeKit(cameraID: cameraID) }
    func undoHomeKitOptimization(cameraID: UUID) async throws { try await base.undoHomeKitOptimization(cameraID: cameraID) }
}
