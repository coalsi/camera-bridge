import BridgeEngine
import CameraAdapters
import Foundation
import MediaCore

/// A throwaway `UserDefaults` domain for one test.
final class ScratchDefaults {
    let suiteName = "com.coreysilvia.CameraBridgeTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }
}

/// Records calls; answers from canned results.
final class FakeSetupService: CameraSetupService {
    var discovered: [DiscoveredCamera] = []
    var probeResult: Result<CameraProbeResult, any Error> = .failure(FakeError.unset)
    /// Answers used first, one per probe, before `probeResult` (a camera that answers differently each time).
    var probeResults: [Result<CameraProbeResult, any Error>] = []
    var addError: (any Error)?
    var pairing: PairingCode?
    var localNetworkAccess: LocalNetworkAccess = .unknown
    /// The cameras already configured (the wizard points out one it would add again).
    var configuredCameras: [CameraConfiguration] = []
    /// Discovery and probing take this long (cancellable, like the engine's network calls).
    var discoveryDelay: Duration?
    var probeDelay: Duration?

    /// Cameras behind a service: the answer of `probeIntegration`, the Protect console's cameras, the helper and its sign-in page.
    var integrationProbeResult: Result<CameraProbeResult, any Error> = .failure(FakeError.unset)
    var protectCamerasResult: Result<[UnifiProtectCamera], any Error> = .success([])
    var isStreamingHelperInstalled = true
    var signInURL: Result<URL, any Error> = .success(URL(string: "http://127.0.0.1:41001/add.html")!)
    var nestAccess = NestDeviceAccess(transport: { _ in throw FakeError.unset })
    private(set) var integrationProbeCalls: [(vendor: CameraVendor, integration: IntegrationSettings, endpoint: CameraEndpoint, username: String,
                                              secret: String)] = []
    private(set) var protectCameraCalls: [(endpoint: CameraEndpoint, apiKey: String)] = []
    private(set) var signInBegun = 0
    private(set) var signInEnded = 0

    private(set) var discoverCalls = 0
    private(set) var probeCalls: [(vendor: CameraVendor?, endpoint: CameraEndpoint, username: String, password: String,
                                   main: URL?, sub: URL?)] = []
    private(set) var added: [(configuration: CameraConfiguration, password: String?)] = []
    private(set) var discoveryWasCancelled = false
    private(set) var probeWasCancelled = false

    func discoverCameras() async -> [DiscoveredCamera] {
        discoverCalls += 1
        if let discoveryDelay {
            do {
                try await Task.sleep(for: discoveryDelay)
            } catch {
                discoveryWasCancelled = true
                return Array(discovered.prefix(1))   // partial answer, like a cut-short WS-Discovery window
            }
        }
        return discovered
    }

    func probeCamera(vendor: CameraVendor?, endpoint: CameraEndpoint, username: String, password: String,
                     mainStreamURL: URL?, subStreamURL: URL?) async throws -> CameraProbeResult {
        probeCalls.append((vendor, endpoint, username, password, mainStreamURL, subStreamURL))
        if let probeDelay {
            do {
                try await Task.sleep(for: probeDelay)
            } catch {
                probeWasCancelled = true
                throw error
            }
        }
        if !probeResults.isEmpty { return try probeResults.removeFirst().get() }
        return try probeResult.get()
    }

    func probeIntegration(vendor: CameraVendor, integration: IntegrationSettings, endpoint: CameraEndpoint, username: String,
                          secret: String) async throws -> CameraProbeResult {
        integrationProbeCalls.append((vendor, integration, endpoint, username, secret))
        return try integrationProbeResult.get()
    }

    func unifiProtectCameras(endpoint: CameraEndpoint, apiKey: String) async throws -> [UnifiProtectCamera] {
        protectCameraCalls.append((endpoint, apiKey))
        return try protectCamerasResult.get()
    }

    func beginIntegrationSignIn() async throws -> URL {
        signInBegun += 1
        return try signInURL.get()
    }

    func endIntegrationSignIn() async {
        signInEnded += 1
    }

    func addCamera(_ configuration: CameraConfiguration, password: String?) async throws {
        if let addError { throw addError }
        added.append((configuration, password))
    }

    func pairingCode(for cameraID: UUID) -> PairingCode? { pairing }
}

/// A one-shot latch that ignores task cancellation, like an engine call that doesn't check for it.
final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resumed = waiters
        waiters = []
        for waiter in resumed { waiter.resume() }
    }
}

/// A mutable value shared with a closure.
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Lets queued main-actor work run (tasks started by the code under test), up to `limit` hops.
func settle(until condition: () -> Bool = { false }, limit: Int = 200) async {
    for _ in 0..<limit where !condition() {
        await Task.yield()
    }
}

/// Polls `condition` every 10 ms for up to `timeout` (for work that sleeps, such as a debounce).
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

enum FakeError: Error, LocalizedError {
    case unset, unreachable
    var errorDescription: String? {
        switch self {
        case .unset: "No canned result"
        case .unreachable: "The camera didn't respond."
        }
    }
}

enum Samples {
    static let hikvisionProbe = CameraProbeResult(
        vendor: .hikvision, manufacturer: "Hikvision", model: "DS-2CD2347G2-LU", serialNumber: "SN1", firmware: "V5.7.15",
        mainStream: StreamInfo(url: URL(string: "rtsp://192.0.2.21:554/ISAPI/Streaming/channels/101")!, videoCodec: .h264,
                               width: 2688, height: 1520, fps: 20, audioCodec: .aac, audioSampleRate: 16_000, audioChannels: 1),
        subStream: StreamInfo(url: URL(string: "rtsp://192.0.2.21:554/ISAPI/Streaming/channels/102")!, videoCodec: .h264,
                              width: 640, height: 360, fps: 15),
        capabilities: CameraCapabilities(events: [.motion, .person, .vehicle, .tamper, .dayNight], twoWayAudio: true, snapshotAPI: true))

    static let doorbellProbe = CameraProbeResult(
        vendor: .reolink, manufacturer: "Reolink", model: "Reolink Video Doorbell WiFi", serialNumber: "SN2", firmware: "v3",
        mainStream: StreamInfo(url: URL(string: "rtsp://192.0.2.22:554/h264Preview_01_main")!, videoCodec: .h264, width: 2560, height: 1920, fps: 15),
        capabilities: CameraCapabilities(events: [.motion, .person, .package, .doorbell], twoWayAudio: false, isDoorbell: true))

    static let plainRTSPProbe = CameraProbeResult(
        vendor: .rtsp, manufacturer: "", model: "", serialNumber: "", firmware: "",
        mainStream: StreamInfo(url: URL(string: "rtsp://192.0.2.24:8554/live")!, videoCodec: .h264, width: 1920, height: 1080, fps: 25))

    static let plainONVIFProbe = CameraProbeResult(
        vendor: .onvif, manufacturer: "Acme", model: "Porch Cam", serialNumber: "SN3", firmware: "1.0",
        mainStream: StreamInfo(url: URL(string: "rtsp://192.0.2.32:554/stream1")!, videoCodec: .h264, width: 1920, height: 1080, fps: 15),
        capabilities: CameraCapabilities(events: [.motion]))
}
