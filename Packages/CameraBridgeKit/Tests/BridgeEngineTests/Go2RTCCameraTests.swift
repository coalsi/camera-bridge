#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import PlatformApple
import Synchronization
import Testing
import TestSupport
@testable import BridgeEngine

/// A go2rtc helper that serves one local RTSP address for every stream (a test camera), and remembers what was asked.
actor LocalRTSPProvider: Go2RTCStreamProviding {
    private let address: URL
    private(set) var attached: [(streamID: String, source: Go2RTCSource)] = []
    private(set) var detached: [String] = []

    init(address: URL) {
        self.address = address
    }

    func attach(streamID: String, source: Go2RTCSource) async throws -> URL {
        attached.append((streamID, source))
        return address
    }

    func detach(streamID: String) async { detached.append(streamID) }
    func problems(streamID: String) async -> [String] { [] }
}

/// Cameras behind the go2rtc helper (Ring, Nest, Wyze, Tuya, UniFi's RTSPS): configuration, secrets, the runtime, the wizard's probe.
@Suite(.serialized) struct Go2RTCCameraTests {
    static let source = "ring:?camera_id=77&device_id=dev-1&refresh_token=RT-SECRET-31337"

    static func camera(name: String = "Front Door") -> CameraConfiguration {
        var camera = CameraConfiguration(name: name, kind: .doorbell, vendor: .go2rtc, endpoint: CameraEndpoint(host: "127.0.0.1"), username: "")
        camera.integration = IntegrationSettings(service: .ring, details: [IntegrationSettings.Key.deviceName: name])
        camera.motionSource = .softMotion
        return camera
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func theCameraRunsThroughTheHelpersRTSPAndTheHelperEndsWithIt() async throws {
        // Small and slow: this suite runs next to timing-sensitive engine tests.
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 8, gop: .seconds(1), audio: nil),
                                    transport: AppleNetworkTransport(), configuration: RTSPTestServer.Configuration())
        try await server.start()
        let provider = LocalRTSPProvider(address: server.url)
        var tuning = EngineTuning.testing
        tuning.go2rtc = provider
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        let camera = Self.camera()
        try await engine.addCamera(camera, password: Self.source)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        #expect(await fixture.waitFor { fixture.status(camera.id)?.videoSummary?.hasPrefix("H.264 320×180") == true })
        let attached = await provider.attached
        #expect(attached.count == 1)
        #expect(attached.first?.streamID == Go2RTCManager.streamName(for: camera.id) && attached.first?.source.url == Self.source)
        #expect(fixture.status(camera.id)?.vendor == .go2rtc)
        // The camera's own motion is the built-in detection.
        #expect(await fixture.until { await fixture.engine.runtimes[camera.id]?.isSoftMotionRunning == true })

        await engine.removeCamera(id: camera.id)
        #expect(await provider.detached == [Go2RTCManager.streamName(for: camera.id)])
        await fixture.tearDown()
        await server.stop()
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func theSourceIsOnlyInTheKeychainNeverInTheConfigurationFile() async throws {
        let fixture = try await EngineFixture()
        let camera = Self.camera()
        try await fixture.engine.addCamera(camera, password: Self.source)
        // Keychain (the secret store): the whole source.
        let credentials = CredentialStore(secrets: fixture.environment.platform.secrets)
        #expect(try credentials.password(for: camera.id) == Self.source)
        // config.json: the service and the camera's name; no secret of any kind.
        let file = try String(contentsOf: fixture.directory.url.appending(path: "config.json"), encoding: .utf8)
        #expect(file.contains("\"integration\"") && file.contains("\"ring\"") && file.contains("\"go2rtc\""))
        for secret in ["RT-SECRET-31337", "refresh_token", "dev-1", "camera_id"] { #expect(!file.contains(secret), "\(secret)") }
        // It survives a reload, and a configuration written before this field existed still loads.
        let reloaded = BridgeEngine(environment: fixture.environment, tuning: .testing)
        #expect(reloaded.configurations.first?.integration == camera.integration)
        let legacy = Data(#"{"id":"\#(UUID().uuidString)","name":"Old","kind":"camera","vendor":"rtsp","endpoint":{"host":"192.0.2.1","httpPort":80,"rtspPort":554,"useHTTPS":false}}"#.utf8)
        #expect(try JSONDecoder().decode(CameraConfiguration.self, from: legacy).integration == nil)
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func withoutTheHelperTheCameraSaysSo() async throws {
        let fixture = try await EngineFixture()   // the test environment has no helper programs
        let engine = fixture.engine
        let camera = Self.camera()
        try await engine.addCamera(camera, password: Self.source)
        await engine.start()
        #expect(await fixture.waitFor { if case .offline(let reason)? = fixture.status(camera.id)?.connection { reason.contains("streaming helper") } else { false } })
        #expect(engine.isStreamingHelperInstalled == false)
        await #expect(throws: Go2RTCError.helperMissing) { _ = try await engine.beginIntegrationSetup() }
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func theWizardsProbeStartsNothingAndLeavesNothingBehind() async throws {
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 8, gop: .seconds(1), audio: nil),
                                    transport: AppleNetworkTransport(), configuration: RTSPTestServer.Configuration())
        try await server.start()
        let provider = LocalRTSPProvider(address: server.url)
        var tuning = EngineTuning.testing
        tuning.go2rtc = provider
        let fixture = try await EngineFixture(tuning: tuning)
        let result = try await fixture.engine.probeIntegration(vendor: .go2rtc, integration: IntegrationSettings(service: .wyze), endpoint: CameraEndpoint(host: "127.0.0.1"),
                                                               username: "", secret: "wyze://192.168.1.20?uid=WYZEUID1234567890AB&enr=ENR&mac=AABBCCDDEEFF")
        #expect(result.vendor == .go2rtc && result.manufacturer == "Wyze" && result.mainStream?.width == 320)
        #expect(await provider.attached.count == 1)
        // The probe's driver is closed in the background; its stream is released.
        #expect(await fixture.until { await provider.detached.count == 1 })
        #expect(fixture.engine.configurations.isEmpty)
        await fixture.tearDown()
        await server.stop()
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func aBrokenSourceFailsTheProbeWithoutQuotingIt() async throws {
        let fixture = try await EngineFixture(tuning: { var tuning = EngineTuning.testing; tuning.go2rtc = LocalRTSPProvider(address: URL(string: "rtsp://127.0.0.1:1/x")!); return tuning }())
        do {
            _ = try await fixture.engine.probeIntegration(vendor: .go2rtc, integration: IntegrationSettings(service: .other), endpoint: CameraEndpoint(host: "127.0.0.1"),
                                                          username: "", secret: "exec:ffmpeg -i x refresh_token=RT-SECRET-31337")
            Issue.record("probe passed")
        } catch let error as IntegrationError {
            #expect(!error.message.contains("RT-SECRET-31337") && !error.message.contains("ffmpeg"))
        }
        await fixture.tearDown()
    }
}
#endif
