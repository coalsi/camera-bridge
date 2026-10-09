import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import Testing
@testable import BridgeEngine
#if canImport(Darwin)
import PlatformApple
#endif

@Suite struct ConfigurationTests {
    @Test func cameraConfigurationDefaultsAndCodable() throws {
        var config = CameraConfiguration(name: "Driveway", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "10.0.0.2"), username: "admin")
        #expect(config.motionSource == .cameraEvents && config.motionHoldSeconds == 20 && config.isEnabled && config.hapPort == 0)
        config.sensors.package = true
        config.mainStreamURL = URL(string: "rtsp://10.0.0.2:554/Streaming/Channels/101")
        #expect(try JSONDecoder().decode(CameraConfiguration.self, from: JSONEncoder().encode(config)) == config)
    }

    @Test func settingsDefaults() {
        let a = BridgeSettings(), b = BridgeSettings()
        #expect(a.basePort == 21_100 && !a.webhookEnabled && a.logLevel == .info)
        #expect(a.webhookToken.count == 32 && a.webhookToken.allSatisfy(\.isHexDigit))
        #expect(a.webhookToken != b.webhookToken)
    }

    #if canImport(Darwin)   // `.testing` / `.live` exist only where PlatformApple does
    @Test func testingEnvironment() throws {
        let env = BridgeEnvironment.testing(directory: URL(filePath: "/tmp/x"))
        #expect(env.loopbackOnly && !env.advertise && env.dataDirectory == URL(filePath: "/tmp/x"))
        #expect(env.platform.transport is AppleNetworkTransport)
        #expect(env.platform.advertiser is NullServiceAdvertiser)
        #expect(env.platform.secrets is InMemorySecretStore)
        #expect(env.platform.networkChanges is NullNetworkChangeMonitor)
        #expect(env.platform.power is NullPowerManager)
        #expect(env.codecs is AppleMediaCodecs)
    }

    @Test func liveEnvironment() {
        let env = BridgeEnvironment.live()
        #expect(env.dataDirectory.lastPathComponent == "CameraBridge")
        #expect(!env.loopbackOnly && env.advertise)
        #expect(env.platform.advertiser is DNSSDServiceAdvertiser)
        #expect(env.platform.secrets is KeychainSecretStore)
        (env.platform.networkChanges as? NWPathNetworkChangeMonitor)?.cancel()
    }
    #endif

    @Test func inertEnvironmentNeverTouchesTheNetwork() async throws {
        let env = BridgeEnvironment.inert(directory: URL(filePath: "/tmp/x"))
        #expect(env.loopbackOnly && !env.advertise)
        await #expect(throws: TransportError.self) { _ = try await env.platform.transport.listen(port: 0, loopbackOnly: true) }
        await #expect(throws: TransportError.self) { _ = try await env.platform.transport.connect(host: "127.0.0.1", port: 1, timeout: .seconds(1)) }
        #expect(throws: MediaCodecError.self) { _ = try env.codecs.makeVideoDecoder(format: VideoFormat(codec: .h264, width: 1, height: 1, parameterSets: [])) }
        await #expect(throws: MediaCodecError.self) {
            _ = try await env.codecs.makeSyntheticSource(displayName: "Demo", width: 1, height: 1, fps: 1, keyframeInterval: .seconds(1),
                                                         audio: nil, audioSampleRate: 8_000).samples()
        }
    }

    @MainActor @Test func emptySnapshotEngineIsIdle() {
        let engine = BridgeEngine(environment: .inert(directory: URL(filePath: "/tmp/x")), snapshot: BridgeEngine.Snapshot())
        #expect(engine.state == .stopped && engine.cameras.isEmpty)
    }

    @MainActor @Test func snapshotSeedsPublishedState() {
        var snapshot = BridgeEngine.Snapshot()
        snapshot.state = .running
        snapshot.localNetworkAccess = .granted
        snapshot.sensorsBridge = SensorsBridgeStatus(isPaired: true, setupCode: "031-45-154", setupURI: "X-HM://00GW95DQA7OSX", accessoryCount: 3)
        snapshot.recentLogs = (0..<1_005).map { LogEntry(level: .info, category: "test", message: "\($0)") }
        var settings = BridgeSettings()
        settings.keepMacAwake = true
        snapshot.settings = settings
        let engine = BridgeEngine(environment: .inert(directory: URL(filePath: "/tmp/x")), snapshot: snapshot)
        #expect(engine.state == .running && engine.localNetworkAccess == .granted)
        #expect(engine.sensorsBridge?.accessoryCount == 3)
        #expect(engine.recentLogs.count == 1_000 && engine.recentLogs.last?.message == "1004")
        #expect(engine.settings.keepMacAwake)
    }
}

@Suite struct CredentialStoreTests {
    @Test func storesPasswordsPerCameraInTheSecretStore() throws {
        let secrets = InMemorySecretStore()
        let store = CredentialStore(secrets: secrets)
        let camera = UUID(), other = UUID()
        #expect(try store.password(for: camera) == nil)
        try store.setPassword("pa55wörd", for: camera)
        try store.setPassword("other", for: other)
        #expect(try store.password(for: camera) == "pa55wörd")
        #expect(try secrets.read(account: "camera.\(camera.uuidString)") == Data("pa55wörd".utf8))
        try store.setPassword(nil, for: camera)
        #expect(try store.password(for: camera) == nil)
        #expect(try store.password(for: other) == "other")
    }

    @Test func undecodablePasswordThrows() throws {
        let secrets = InMemorySecretStore()
        let camera = UUID()
        try secrets.write(Data([0xFF, 0xFE]), account: "camera.\(camera.uuidString)")
        #expect(throws: CredentialStoreError.self) { _ = try CredentialStore(secrets: secrets).password(for: camera) }
    }
}

@Suite struct EngineLifecycleTests {
    @MainActor @Test func systemDidWakeIsAcceptedWhileStopped() async {
        let engine = BridgeEngine(environment: .inert(directory: URL(filePath: "/tmp/x")), snapshot: BridgeEngine.Snapshot())
        await engine.systemDidWake()
        #expect(engine.state == .stopped)
    }
}
