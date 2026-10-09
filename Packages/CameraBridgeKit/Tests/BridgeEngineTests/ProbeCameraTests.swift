#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import PlatformApple
import TestSupport
import Testing
@testable import BridgeEngine

/// `probeCamera` as the Add Camera wizard and the camera's Connection sheet use it (App review findings): the ONVIF
/// port that answered is kept, a camera that can't be reached because of Local Network privacy says so (and gets a
/// second try once the person allows access), nothing answering in Automatic mode has its own error, and a configured
/// camera is probed with its stored password. Detection and drivers are fakes; connections go to `ScriptedConnectTransport`
/// (never the network).
@MainActor @Suite(.timeLimit(.minutes(1))) struct ProbeCameraTests {
    /// Records what the engine built the driver from; `probe()` fails with `failures` in turn, then succeeds.
    final class RecordingDriver: CameraDriver, Sendable {
        let vendor: CameraVendor
        let failures: Box<[any Error & Sendable]>
        let probes = Box(0)
        let closes = Box(0)

        init(vendor: CameraVendor, failures: [any Error & Sendable] = []) {
            self.vendor = vendor
            self.failures = Box(failures)
        }

        func probe() async throws -> CameraProbeResult {
            probes.update { $0 += 1 }
            if let failure = failures.update({ list -> (any Error & Sendable)? in list.isEmpty ? nil : list.removeFirst() }) { throw failure }
            return CameraProbeResult(vendor: vendor, manufacturer: "Acme", model: "Cam", serialNumber: "SN", firmware: "1")
        }

        func makeEventSource() -> (any CameraEventSource)? { nil }
        func snapshot() async throws -> Data? { nil }
        func makeTalkbackSink() -> (any TalkbackSink)? { nil }
        func close() async { closes.update { $0 += 1 } }
    }

    struct Built: Sendable {
        var camera: CameraConfiguration
        var credentials: HTTPCredentials?
    }

    private let built = Box<[Built]>([])

    private func engine(transport: any NetworkTransport, directory: TemporaryDirectory, driver: RecordingDriver,
                        detection: VendorDetection? = nil, onvifPort: Int? = nil) -> BridgeEngine {
        var tuning = EngineTuning.testing
        tuning.localNetworkAnswerWait = .milliseconds(300)
        let built = built
        tuning.driverFactory = { camera, credentials, _ in
            built.update { $0.append(Built(camera: camera, credentials: credentials)) }
            return driver
        }
        tuning.detectVendor = { _, _ in detection }
        tuning.findONVIFPort = { _ in onvifPort }
        return BridgeEngine(environment: BridgeEnvironment(dataDirectory: directory.url,
                                                           platform: PlatformServices(transport: transport, advertiser: NullServiceAdvertiser(),
                                                                                      secrets: InMemorySecretStore(),
                                                                                      networkChanges: NullNetworkChangeMonitor(), power: NullPowerManager()),
                                                           codecs: AppleMediaCodecs(), loopbackOnly: true, advertise: false),
                            tuning: tuning)
    }

    private func probe(_ engine: BridgeEngine, vendor: CameraVendor?, endpoint: CameraEndpoint = CameraEndpoint(host: "192.0.2.20"))
        async throws -> CameraProbeResult {
        try await engine.probeCamera(vendor: vendor, endpoint: endpoint, username: "admin", password: "secret", mainStreamURL: nil, subStreamURL: nil)
    }

    // MARK: ONVIF port

    @Test func automaticDetectionKeepsTheONVIFPortThatAnswered() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let engine = engine(transport: ScriptedConnectTransport([], then: .connectionRefused), directory: directory,
                            driver: RecordingDriver(vendor: .onvif), detection: VendorDetection(vendor: .onvif, onvifPort: 2020))
        let result = try await probe(engine, vendor: nil)
        #expect(result.onvifPort == 2020)
        #expect(built.value.last?.camera.endpoint.onvifPort == 2020, "the driver reaches the device service on the port that answered")
        #expect(built.value.last?.camera.vendor == .onvif)
    }

    @Test func anExplicitONVIFCameraFindsItsDeviceServicePort() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let engine = engine(transport: ScriptedConnectTransport([], then: .connectionRefused), directory: directory,
                            driver: RecordingDriver(vendor: .onvif), onvifPort: 8000)
        let result = try await probe(engine, vendor: .onvif)
        #expect(result.onvifPort == 8000 && built.value.last?.camera.endpoint.onvifPort == 8000)

        // A port the person entered is used as it is.
        let entered = try await probe(engine, vendor: .onvif, endpoint: CameraEndpoint(host: "192.0.2.20", onvifPort: 8899))
        #expect(entered.onvifPort == 8899 && built.value.last?.camera.endpoint.onvifPort == 8899)
    }

    // MARK: Nothing answers / Local Network

    @Test func automaticDetectionThatFindsNothingSaysSo() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let engine = engine(transport: ScriptedConnectTransport([], then: .connectionRefused), directory: directory,
                            driver: RecordingDriver(vendor: .hikvision))
        await #expect(throws: EngineError.noCameraAPI(host: "192.0.2.20")) { try await probe(engine, vendor: nil) }
        #expect(engine.localNetworkAccess == .granted)
    }

    @Test func automaticDetectionBlockedByLocalNetworkSaysSo() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let engine = engine(transport: ScriptedConnectTransport([], then: .localNetworkDenied), directory: directory,
                            driver: RecordingDriver(vendor: .hikvision))
        await #expect(throws: TransportError.localNetworkDenied) { try await probe(engine, vendor: nil) }
        #expect(engine.localNetworkAccess == .denied, "the bridge banner and menu bar warning follow")
    }

    @Test func aCameraUnreachableBecauseOfLocalNetworkSaysSo() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let driver = RecordingDriver(vendor: .hikvision, failures: [URLError(.notConnectedToInternet), URLError(.notConnectedToInternet)])
        let engine = engine(transport: ScriptedConnectTransport([], then: .localNetworkDenied), directory: directory, driver: driver)
        await #expect(throws: TransportError.localNetworkDenied) { try await probe(engine, vendor: .hikvision) }
        #expect(engine.localNetworkAccess == .denied)
    }

    /// The first probe raised the system's alert and was blocked; the person clicked Allow while the engine waited for
    /// the answer, so the probe runs again instead of reporting a failure.
    @Test func allowingTheAlertDuringTheProbeTriesAgain() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let driver = RecordingDriver(vendor: .hikvision, failures: [URLError(.notConnectedToInternet)])
        let engine = engine(transport: ScriptedConnectTransport([.localNetworkDenied, .localNetworkDenied], then: .connectionRefused),
                            directory: directory, driver: driver)
        let result = try await probe(engine, vendor: .hikvision)
        #expect(result.vendor == .hikvision && driver.probes.value == 2)
        #expect(engine.localNetworkAccess == .granted)
    }

    /// A camera that answered (wrong password, HTTP error) isn't a Local Network question: no check, no second try.
    @Test func aCameraThatAnsweredIsNotALocalNetworkQuestion() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let transport = ScriptedConnectTransport([], then: .localNetworkDenied)
        let driver = RecordingDriver(vendor: .hikvision, failures: [CameraAdapterError.unauthorized])
        let engine = engine(transport: transport, directory: directory, driver: driver)
        await #expect(throws: CameraAdapterError.unauthorized) { try await probe(engine, vendor: .hikvision) }
        #expect(transport.attempts.value == 0 && driver.probes.value == 1 && engine.localNetworkAccess == .unknown)
    }

    // MARK: Driver sessions

    /// Review finding (W4 round 4): the driver a probe builds was dropped without being closed, so every Add Camera or
    /// Connection check of a Reolink camera held one of its few API sessions until the login's lease ended (an hour).
    /// Each probe closes its driver, after a failure too.
    @Test func everyProbeClosesItsDriver() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let driver = RecordingDriver(vendor: .reolink, failures: [CameraAdapterError.unauthorized])
        let engine = engine(transport: ScriptedConnectTransport([], then: .connectionRefused), directory: directory, driver: driver)
        await #expect(throws: CameraAdapterError.unauthorized) { try await probe(engine, vendor: .reolink) }
        #expect(await eventually { driver.closes.value == 1 }, "a failed probe's driver is closed")
        _ = try await probe(engine, vendor: .reolink)
        #expect(await eventually { driver.closes.value == 2 }, "a probe's driver is closed once it answered")
        #expect(driver.probes.value == 2)
    }

    // MARK: Configured cameras

    /// The camera's Connection sheet checks a changed address before saving: the stored password is used, the camera
    /// keeps its identity.
    @Test func aConfiguredCameraIsProbedWithItsStoredPassword() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let engine = engine(transport: ScriptedConnectTransport([], then: .connectionRefused), directory: directory,
                            driver: RecordingDriver(vendor: .hikvision))
        let camera = CameraConfiguration(name: "Driveway", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.20"),
                                         username: "admin")
        try await engine.addCamera(camera, password: "hunter2")
        var moved = camera
        moved.endpoint = CameraEndpoint(host: "192.0.2.30", httpPort: 8080, rtspPort: 8554)
        moved.mainStreamURL = URL(string: "rtsp://192.0.2.30:8554/Streaming/Channels/101")
        let result = try await engine.probeCamera(moved, password: nil)
        #expect(result.vendor == .hikvision)
        let used = try #require(built.value.last)
        #expect(used.credentials == HTTPCredentials(username: "admin", password: "hunter2"))
        #expect(used.camera.endpoint == moved.endpoint && used.camera.mainStreamURL == moved.mainStreamURL)
        #expect(used.camera.vendor == .hikvision, "a configured camera keeps its type")

        _ = try await engine.probeCamera(moved, password: "new-password")
        #expect(built.value.last?.credentials == HTTPCredentials(username: "admin", password: "new-password"))
        #expect(engine.configurations.first?.endpoint.host == "192.0.2.20", "probing saves nothing")
    }
}
#endif
