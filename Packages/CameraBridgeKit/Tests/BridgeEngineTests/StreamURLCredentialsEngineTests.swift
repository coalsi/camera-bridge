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

/// Credentials some cameras take in their stream URL's query (`?user=…&password=…`, a password `hash=`): `config.json` and the engine's
/// cameras keep the address without them, the secret store keeps them, and only the camera's RTSP sessions send them; an older
/// configuration is rewritten that way when it is loaded. No log line ever carries them.
@Suite(.serialized) struct StreamURLCredentialsEngineTests {
    static let password = "S3cretPW-7781"
    static let hash = "c0ffee00c0ffee00c0ffee00c0ffee00"

    static func camera(host: String = "192.0.2.41", port: Int = 554, main: String, sub: String? = nil, vendor: CameraVendor = .onvif)
        -> CameraConfiguration {
        var camera = CameraConfiguration(name: "Garden PTZ", kind: .camera, vendor: vendor, endpoint: CameraEndpoint(host: host, rtspPort: port),
                                         username: "admin")
        camera.mainStreamURL = URL(string: main)
        camera.subStreamURL = sub.flatMap(URL.init(string:))
        camera.motionSource = .webhook
        return camera
    }

    static func configFile(_ directory: TemporaryDirectory) throws -> String {
        try String(decoding: Data(contentsOf: directory.file(ConfigurationStore.fileName)), as: UTF8.self)
    }

    /// Log lines come from every test running meanwhile: only these values are this suite's own.
    static func expectNoSecret(in text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!text.contains(password) && !text.contains(hash), sourceLocation: sourceLocation)
    }

    static func expectCleanConfigFile(_ directory: TemporaryDirectory, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let text = try configFile(directory)
        expectNoSecret(in: text, sourceLocation: sourceLocation)
        #expect(!text.contains("user=admin"), sourceLocation: sourceLocation)
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func anAddedCameraIsSavedWithoutTheCredentialsOfItsStreamURLs() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let camera = Self.camera(main: "rtsp://192.0.2.41:554/stream0?user=admin&password=\(Self.password)&channel=1",
                                 sub: "rtsp://192.0.2.41:554/stream1?hash=\(Self.hash)")
        try await engine.addCamera(camera, password: "login-pw")
        let saved = try #require(engine.configurations.first)
        #expect(saved.mainStreamURL?.absoluteString == "rtsp://192.0.2.41:554/stream0?channel=1")
        #expect(saved.subStreamURL?.absoluteString == "rtsp://192.0.2.41:554/stream1")
        try Self.expectCleanConfigFile(fixture.directory)
        let credentials = CredentialStore(secrets: fixture.environment.platform.secrets)
        #expect(try credentials.streamCredentials(for: saved) == StreamURLCredentials(main: camera.mainStreamURL, sub: camera.subStreamURL))

        // The Connection sheet saves the address it shows (without them): they stay. A new address drops them.
        try await engine.updateCamera(saved, password: nil)
        #expect(try credentials.streamCredentials(for: try #require(engine.configurations.first)).main == camera.mainStreamURL)
        var moved = saved
        moved.mainStreamURL = URL(string: "rtsp://192.0.2.41:554/stream0?channel=2")
        try await engine.updateCamera(moved, password: nil)
        #expect(try credentials.streamCredentials(for: try #require(engine.configurations.first)) == StreamURLCredentials(sub: camera.subStreamURL))

        await engine.removeCamera(id: camera.id)
        #expect(try fixture.environment.platform.secrets.read(account: CredentialStore.streamURLsAccount(for: camera.id)) == nil)
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func anOlderConfigurationIsRewrittenWithoutThemWhenItIsLoaded() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let camera = Self.camera(main: "rtsp://192.0.2.41:554/stream0?user=admin&password=\(Self.password)&channel=1",
                                 sub: "rtsp://192.0.2.41:554/stream1?hash=\(Self.hash)")
        try ConfigurationStore(directory: directory.url).save(BridgeConfiguration(cameras: [camera]))   // as earlier builds wrote it
        #expect(try Self.configFile(directory).contains(Self.hash))
        let lines = LogLines()
        let token = LogHub.addSink(lines)
        defer { LogHub.removeSink(token) }

        let environment = BridgeEnvironment.testing(directory: directory.url)
        let engine = BridgeEngine(environment: environment, tuning: .testing)
        let loaded = try #require(engine.configurations.first)
        #expect(loaded.mainStreamURL?.absoluteString == "rtsp://192.0.2.41:554/stream0?channel=1")
        #expect(loaded.subStreamURL?.absoluteString == "rtsp://192.0.2.41:554/stream1")
        try Self.expectCleanConfigFile(directory)
        let credentials = CredentialStore(secrets: environment.platform.secrets)
        #expect(try credentials.streamCredentials(for: loaded) == StreamURLCredentials(main: camera.mainStreamURL, sub: camera.subStreamURL))
        #expect(lines.all.contains { $0.contains("Garden PTZ") && $0.contains("secret store") }, "the move is logged")
        Self.expectNoSecret(in: lines.all.joined(separator: "\n"))

        // Loaded again (the next launch): nothing more to move, the credentials are still there.
        let again = BridgeEngine(environment: environment, tuning: .testing)
        #expect(again.configurations == engine.configurations)
        #expect(try credentials.streamCredentials(for: loaded) == StreamURLCredentials(main: camera.mainStreamURL, sub: camera.subStreamURL))
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func aSecretStoreThatRefusesTheMoveLeavesTheAddressWorkingUntilItCanTakeIt() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let camera = Self.camera(main: "rtsp://192.0.2.41:554/stream0?user=admin&hash=\(Self.hash)")
        try ConfigurationStore(directory: directory.url).save(BridgeConfiguration(cameras: [camera]))
        let secrets = RuntimeEngineTests.FailingWritesSecretStore()
        secrets.failing.set(true)
        var environment = BridgeEnvironment.testing(directory: directory.url)
        environment.platform.secrets = secrets
        let refused = BridgeEngine(environment: environment, tuning: .testing)
        #expect(refused.configurations.first?.mainStreamURL == camera.mainStreamURL, "kept as it was, so the camera still connects")
        #expect(try Self.configFile(directory).contains(Self.hash), "not rewritten: the secret store has no copy")

        secrets.failing.set(false)
        let moved = BridgeEngine(environment: environment, tuning: .testing)
        #expect(moved.configurations.first?.mainStreamURL?.absoluteString == "rtsp://192.0.2.41:554/stream0")
        try Self.expectCleanConfigFile(directory)
    }

    /// The camera refuses its address without the query (`requiredQuery`) or the path (`requiredPath`) and asks for the login too (Digest).
    static func server(query: String? = nil, path: String? = nil) async throws -> RTSPTestServer {
        var configuration = RTSPTestServer.Configuration()
        configuration.credentials = HTTPCredentials(username: "admin", password: "login-pw")
        configuration.requiredQuery = query
        configuration.requiredPath = path
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 10, gop: .seconds(1), audio: nil),
                                    transport: AppleNetworkTransport(), configuration: configuration)
        try await server.start()
        return server
    }

    @MainActor @Test(.timeLimit(.minutes(2)), arguments: ["user=admin&password=\(password)", "hash=\(hash)"])
    func aCameraSavedWithoutThemStillConnectsWithTheStoredCredentials(_ query: String) async throws {
        let server = try await Self.server(query: query)
        let lines = LogLines()
        let token = LogHub.addSink(lines)
        defer { LogHub.removeSink(token) }
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let camera = Self.camera(host: "127.0.0.1", port: Int(server.port), main: "\(server.url.absoluteString)?\(query)", vendor: .rtsp)
        try await engine.addCamera(camera, password: "login-pw")
        #expect(engine.configurations.first?.mainStreamURL == server.url)

        // The Connection sheet's check of the saved camera (its driver's RTSP probe).
        let probe = try await engine.probeCamera(try #require(engine.configurations.first), password: nil)
        #expect(probe.mainStream?.url == server.url, "the probe reports the address without them")

        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let describes = server.requests.filter { $0.method == "DESCRIBE" }
        #expect(!describes.isEmpty && describes.allSatisfy { $0.uri == "\(server.url.absoluteString)?\(query)" })
        try Self.expectCleanConfigFile(fixture.directory)
        Self.expectNoSecret(in: engine.recentLogs.map(\.message).joined(separator: "\n"))
        Self.expectNoSecret(in: lines.all.joined(separator: "\n"))
        await fixture.tearDown()
        await server.stop()
    }

    /// XMEye cameras take them in the path (`/user=admin&password=…`, or joined by `_`): saved without them, connected with them.
    @MainActor @Test(.timeLimit(.minutes(2)), arguments: ["/user=admin&password=\(password)&channel=1&stream=0.sdp",
                                                          "/user=admin_password=\(password)_channel=1_stream=0.sdp"])
    func aCameraWithCredentialsInItsPathStillConnects(_ path: String) async throws {
        let server = try await Self.server(path: path)
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let full = "rtsp://127.0.0.1:\(server.port)\(path)"
        let camera = Self.camera(host: "127.0.0.1", port: Int(server.port), main: full, vendor: .rtsp)
        try await engine.addCamera(camera, password: "login-pw")
        let saved = try #require(engine.configurations.first?.mainStreamURL)
        #expect(saved.absoluteString.hasPrefix("rtsp://127.0.0.1:\(server.port)/channel=1") && !saved.absoluteString.contains("user="))
        try Self.expectCleanConfigFile(fixture.directory)

        let probe = try await engine.probeCamera(try #require(engine.configurations.first), password: nil)
        #expect(probe.mainStream?.url == saved, "the probe reports the address without them")
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let describes = server.requests.filter { $0.method == "DESCRIBE" }
        #expect(!describes.isEmpty && describes.allSatisfy { $0.uri == full })
        Self.expectNoSecret(in: engine.recentLogs.map(\.message).joined(separator: "\n"))
        await fixture.tearDown()
        await server.stop()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func aMigratedCameraStillConnects() async throws {
        let query = "user=admin&password=\(Self.password)&hash=\(Self.hash)"
        let server = try await Self.server(query: query)
        let directory = try TemporaryDirectory()
        let camera = Self.camera(host: "127.0.0.1", port: Int(server.port), main: "\(server.url.absoluteString)?\(query)", vendor: .rtsp)
        try ConfigurationStore(directory: directory.url).save(BridgeConfiguration(cameras: [camera]))
        let fixture = try await EngineFixture(directory: directory)
        let engine = fixture.engine
        try CredentialStore(secrets: fixture.environment.platform.secrets).setPassword("login-pw", for: camera.id)
        #expect(engine.configurations.first?.mainStreamURL == server.url)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        #expect(server.requests.filter { $0.method == "DESCRIBE" }.allSatisfy { $0.uri == "\(server.url.absoluteString)?\(query)" })
        try Self.expectCleanConfigFile(directory)
        await fixture.tearDown()
        await server.stop()
    }
}

/// Every message logged while it is registered (from any test running meanwhile: only the absence of a secret is checked).
private final class LogLines: LogSink {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    func record(_ entry: LogEntry) { lines.withLock { $0.append(entry.message) } }
}
#endif
