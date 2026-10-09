#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import PlatformApple
import Testing
import TestSupport
@testable import BridgeEngine

/// The loopback transport with scripted failures: listening on a port in `listenFailures` throws its error (another
/// process took the port as the bridge bound it, or a listener failure), connecting to a port in `connectFailures`
/// throws its error (Local Network privacy). A connection to a host in `lanHosts` (TEST-NET addresses that are never
/// routed) goes to 127.0.0.1: a "LAN" camera served on loopback, so nothing leaves the Mac.
final class ScriptedTransport: NetworkTransport {
    let base = AppleNetworkTransport()
    let lanHosts: Set<String>
    let listenFailures = Box<[UInt16: TransportError]>([:])
    let connectFailures = Box<[UInt16: TransportError]>([:])
    let listenAttempts = Box<[UInt16: Int]>([:])
    /// The latest listener handed out for each requested port.
    let listeners = Box<[UInt16: ScriptedListener]>([:])

    init(lanHosts: Set<String> = []) {
        self.lanHosts = lanHosts
    }

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        listenAttempts.update { $0[port, default: 0] += 1 }
        if let failure = listenFailures.value[port] { throw failure }
        let listener = ScriptedListener(base: try await base.listen(port: port, loopbackOnly: loopbackOnly))
        listeners.update { $0[port] = listener }
        return listener
    }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        if let failure = connectFailures.value[port] { throw failure }
        return try await base.connect(host: lanHosts.contains(host) ? "127.0.0.1" : host, port: port, timeout: timeout)
    }
}

/// A loopback listener that `fail()` stops as the platform stops one on its own (sleep/wake, an interface change): its
/// connections end without its owner closing it.
final class ScriptedListener: TCPListener {
    let base: any TCPListener
    let connections: AsyncStream<any TCPConnection>
    private let continuation: AsyncStream<any TCPConnection>.Continuation

    init(base: any TCPListener) {
        self.base = base
        let (connections, continuation) = AsyncStream.makeStream(of: (any TCPConnection).self)
        self.connections = connections
        self.continuation = continuation
        Task { [base] in
            for await connection in base.connections { continuation.yield(connection) }
            continuation.finish()
        }
    }

    var port: UInt16 { base.port }

    func close() {
        base.close()
        continuation.finish()
    }

    func fail() { close() }
}

/// Advertises nothing; the advertisements named in `denied` are refused as Local Network privacy refuses them
/// (DNS-SD -65570).
final class DenyingAdvertiser: ServiceAdvertiser {
    let denied: Set<String>
    let attempts = Box<[String]>([])

    init(denied: Set<String>) { self.denied = denied }

    func advertise(_ advertisement: ServiceAdvertisement) async throws -> any AdvertisedService {
        attempts.update { $0.append(advertisement.name) }
        if denied.contains(advertisement.name) { throw TransportError.localNetworkDenied }
        return try await NullServiceAdvertiser().advertise(advertisement)
    }
}

/// Accessories that cannot listen where they should, and Local Network denials reported by running cameras (review
/// findings W4 round 3: these paths had no test; a camera whose accessory failed to start was never tried again).
@Suite(.serialized) struct RuntimeStartFailureTests {
    /// Review finding (W4 round 3): a camera whose HAP port another service took just as the bridge bound it moves to the
    /// next free port, which is saved: a paired accessory stays on one port across launches.
    @MainActor @Test(.timeLimit(.minutes(1))) func aCameraPortTakenAtBindMovesAndIsKept() async throws {
        let transport = ScriptedTransport()
        let fixture = try await EngineFixture(transport: transport)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Gate")
        try await engine.addCamera(camera, password: nil)
        let configured = try #require(engine.configurations.first?.hapPort)
        transport.listenFailures.set([configured: .addressInUse])   // free when checked, taken when bound
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.hapPort != nil })
        let moved = try #require(fixture.status(camera.id)?.hapPort)
        #expect(moved != configured)
        #expect(engine.configurations.first?.hapPort == moved)
        #expect(try ConfigurationStore(directory: fixture.directory.url).load()?.cameras.first?.hapPort == moved, "the new port is saved")
        #expect(await fixture.waitFor { engine.recentLogs.contains { $0.message.contains("listens on HAP port \(moved)") } })

        // The next launch listens on it again, although the old port is free now.
        await engine.stop()
        transport.listenFailures.set([:])
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.hapPort != nil })
        #expect(fixture.status(camera.id)?.hapPort == moved)
        await fixture.tearDown()
    }

    /// The sensors bridge's port taken at bind: the bridge moves upward and the port is saved.
    @MainActor @Test(.timeLimit(.minutes(1))) func aSensorsBridgePortTakenAtBindMovesAndIsKept() async throws {
        let transport = ScriptedTransport()
        let fixture = try await EngineFixture(transport: transport) { $0.sensorsBridgePort = $0.basePort &+ 900 }
        let engine = fixture.engine
        let configured = engine.settings.sensorsBridgePort
        try await engine.addCamera(EngineFixture.demoCamera(name: "Yard"), password: nil)
        transport.listenFailures.set([configured: .addressInUse])
        await engine.start()
        #expect(await fixture.waitFor { engine.sensorsBridge != nil })
        let port = try #require(await engine.bridge?.server.port)
        #expect(port != configured)
        #expect(engine.settings.sensorsBridgePort == port)
        #expect(try ConfigurationStore(directory: fixture.directory.url).load()?.settings.sensorsBridgePort == port)
        await fixture.tearDown()
    }

    /// Review finding (W4 round 3): a camera whose accessory failed to start (a listener failure other than a taken
    /// port, an unreadable identity) was never tried again: no retry, not on wake or a network change, only Pause and
    /// Resume brought it back, while the app said "Offline — retrying". It is tried again with backoff.
    @MainActor @Test(.timeLimit(.minutes(1))) func anAccessoryThatCouldNotStartIsTriedAgain() async throws {
        let transport = ScriptedTransport()
        var tuning = EngineTuning.testing
        tuning.ingest.initialBackoff = .milliseconds(300)
        tuning.ingest.maximumBackoff = .milliseconds(600)
        let fixture = try await EngineFixture(tuning: tuning, transport: transport)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Porch")
        try await engine.addCamera(camera, password: nil)
        let port = try #require(engine.configurations.first?.hapPort)
        transport.listenFailures.set([port: .failed("listener failure")])
        await engine.start()
        #expect(await fixture.waitFor {
            if case .offline(let reason) = fixture.status(camera.id)?.connection { reason.hasPrefix("the Apple Home accessory could not start") } else { false }
        }, "\(String(describing: fixture.status(camera.id)?.connection))")
        #expect(await fixture.waitFor { (transport.listenAttempts.value[port] ?? 0) >= 3 }, "tried again with backoff")
        transport.listenFailures.set([:])
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online && fixture.status(camera.id)?.hapPort == port })
        #expect(engine.runtimes[camera.id] != nil)
        await fixture.tearDown()
    }

    /// A wake (or network change) tries a failed accessory again at once, without waiting out its backoff.
    @MainActor @Test(.timeLimit(.minutes(1))) func aWakeTriesAFailedAccessoryAgainAtOnce() async throws {
        let transport = ScriptedTransport()
        var tuning = EngineTuning.testing
        tuning.ingest.initialBackoff = .seconds(60)
        let fixture = try await EngineFixture(tuning: tuning, transport: transport)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Porch")
        try await engine.addCamera(camera, password: nil)
        let port = try #require(engine.configurations.first?.hapPort)
        transport.listenFailures.set([port: .failed("listener failure")])
        await engine.start()
        #expect(await fixture.waitFor { if case .offline = fixture.status(camera.id)?.connection { true } else { false } })
        transport.listenFailures.set([:])
        await engine.systemDidWake()   // tried again once the network settled after the wake (2 s), not after the 60 s backoff
        #expect(await fixture.waitFor(.seconds(10)) { fixture.status(camera.id)?.connection == .online && fixture.status(camera.id)?.hapPort == port })
        // Paused, a pending try does nothing.
        await engine.pause()
        #expect(engine.runtimes.isEmpty)
        await fixture.tearDown()
    }

    /// Review finding (W4 round 4): a sensors bridge that cannot start (its port refused) was never driven by a test. It
    /// is logged at error level, the cameras run without it (the app says the bridge is not running and points to the
    /// log), and the next wake or network change starts it again.
    @MainActor @Test(.timeLimit(.minutes(1))) func aSensorsBridgeThatCannotStartIsLoggedAndStartedAgainAtTheNextReconnect() async throws {
        let transport = ScriptedTransport()
        let port = UInt16.random(in: 28_001...28_999)
        transport.listenFailures.set([port: .failed("listener failure")])
        let fixture = try await EngineFixture(transport: transport) { $0.sensorsBridgePort = port }
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Porch")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(engine.state == .running && engine.bridge == nil && engine.sensorsBridge == nil)
        #expect(await fixture.waitFor(.seconds(5)) {
            engine.recentLogs.contains { $0.level == .error && $0.message.hasPrefix("The sensors bridge could not start") }
        })
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online }, "the cameras run without it")
        transport.listenFailures.set([:])
        fixture.networkChanges.fire()
        #expect(await fixture.waitFor(.seconds(10)) { engine.sensorsBridge != nil && engine.bridge != nil })
        #expect(await engine.bridge?.server.port == port)
        await fixture.tearDown()
    }

    // MARK: - The webhook

    /// Review finding (W4 round 3): `webhookProblem` was set only when the webhook started. A listener the platform
    /// stopped (sleep/wake, an interface change) that could not listen again (another app took the port meanwhile) was
    /// only logged: Settings looked healthy while every webhook doorbell ring and motion event was lost.
    @MainActor @Test(.timeLimit(.minutes(1))) func aWebhookThatStopsListeningAndCannotListenAgainIsReported() async throws {
        let transport = ScriptedTransport()
        let fixture = try await EngineFixture(transport: transport) { settings in
            settings.webhookEnabled = true
            settings.webhookPort = settings.basePort &+ 800
        }
        let engine = fixture.engine
        let port = engine.settings.webhookPort
        await engine.start()
        #expect(await fixture.until { await engine.webhook?.boundPort == port })
        #expect(engine.webhookProblem == nil)
        transport.listenFailures.set([port: .addressInUse])   // another app takes the port…
        try #require(transport.listeners.value[port]).fail()  // …as the platform stops the listener
        #expect(await fixture.waitFor { engine.webhookProblem?.contains("another app uses the port") == true },
                "\(String(describing: engine.webhookProblem))")
        transport.listenFailures.set([:])
        #expect(await fixture.waitFor(.seconds(10)) { engine.webhookProblem == nil }, "listening again clears it")
        #expect(await engine.webhook?.boundPort == port)

        // Try Again replaces a webhook that is still trying to listen again.
        transport.listenFailures.set([port: .addressInUse])
        try #require(transport.listeners.value[port]).fail()
        #expect(await fixture.waitFor { engine.webhookProblem != nil })
        transport.listenFailures.set([:])
        await engine.retryWebhook()
        #expect(engine.webhookProblem == nil)
        #expect(await engine.webhook?.boundPort == port)
        await fixture.tearDown()
    }

    /// Review finding (W4 round 3): webhook listen failures other than a taken port or Local Network denial showed Swift
    /// case names in Settings and in the refused change ("(timedOut)", "(failed(\"POSIXErrorCode…\"))").
    @Test func webhookListenFailuresAreSentences() {
        let errors: [any Error] = [TransportError.closed, TransportError.timedOut, CancellationError(),
                                   TransportError.failed("POSIXErrorCode(rawValue: 49): Can't assign requested address"),
                                   TransportError.addressInUse, TransportError.localNetworkDenied]
        for error in errors {
            guard case .invalidSettings(let refused) = BridgeEngine.webhookCannotListen(8080, error) else {
                Issue.record("not invalidSettings")
                continue
            }
            for text in [refused, BridgeEngine.webhookProblemText(8080, error)] {
                for caseName in ["(closed)", "timedOut", "failed(", "POSIXErrorCode", "CancellationError"] {
                    #expect(!text.contains(caseName), "\(error): \(text)")
                }
            }
        }
        #expect(BridgeEngine.webhookProblemText(8080, TransportError.addressInUse) == "The webhook cannot listen on port 8080 (another app uses the port).")
        #expect(BridgeEngine.webhookProblemText(8080, TransportError.timedOut) == "The webhook cannot listen on port 8080 (the connection timed out).")
    }

    // MARK: - Local Network, reported by running cameras

    /// Review finding (W4 round 3): Local Network denials seen by a running camera (its stream, its sub stream, its
    /// Bonjour advertisement) reached `localNetworkAccess` through code no test ran: the in-flight signal of the most
    /// common sandboxed-macOS failure. A camera on the LAN (a TEST-NET address served on loopback) whose stream is
    /// denied makes the engine report the denial, and its first stream once allowed reports access granted.
    @MainActor @Test(.timeLimit(.minutes(1))) func aStreamDeniedByLocalNetworkPrivacyIsReportedAndItsRecoveryToo() async throws {
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        try await server.start()
        let lan = "192.0.2.10"
        let transport = ScriptedTransport(lanHosts: [lan])
        transport.connectFailures.set([server.port: .localNetworkDenied])
        var tuning = EngineTuning.testing
        tuning.aspectWait = .milliseconds(300)
        tuning.ingest.initialBackoff = .milliseconds(200)
        tuning.ingest.maximumBackoff = .milliseconds(400)
        let fixture = try await EngineFixture(tuning: tuning, transport: transport)
        let engine = fixture.engine
        var camera = CameraConfiguration(name: "Drive", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: lan, rtspPort: Int(server.port)),
                                         username: "")
        camera.mainStreamURL = URL(string: "rtsp://\(lan):\(server.port)/stream")
        camera.motionSource = .webhook
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { engine.localNetworkAccess == .denied })
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .offline("Local Network access is denied") },
                "\(String(describing: fixture.status(camera.id)?.connection))")
        transport.connectFailures.set([:])   // the person allows CameraBridge in System Settings
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        #expect(await fixture.waitFor { engine.localNetworkAccess == .granted })
        await fixture.tearDown()
        await server.stop()
    }

    /// The same for a sub stream (soft motion keeps it connected).
    @MainActor @Test(.timeLimit(.minutes(1))) func aSubStreamDeniedByLocalNetworkPrivacyIsReported() async throws {
        let main = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        try await main.start()
        let transport = ScriptedTransport()
        let deniedPort: UInt16 = 9   // nothing listens: the denial answers first
        transport.connectFailures.set([deniedPort: .localNetworkDenied])
        let fixture = try await EngineFixture(transport: transport)
        let engine = fixture.engine
        var camera = RuntimeCameraLifecycleTests.rtspCamera("Side", server: main)
        camera.subStreamURL = URL(string: "rtsp://127.0.0.1:\(deniedPort)/sub")
        camera.motionSource = .softMotion
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        #expect(await fixture.waitFor { engine.localNetworkAccess == .denied })
        #expect(await fixture.waitFor { fixture.status(camera.id)?.subStreamProblem == "Local Network access is denied" },
                "\(String(describing: fixture.status(camera.id)?.subStreamProblem))")
        await fixture.tearDown()
        await main.stop()
    }

    /// The same for the camera's Bonjour advertisement (DNS-SD refuses the registration).
    @MainActor @Test(.timeLimit(.minutes(1))) func anAdvertisementDeniedByLocalNetworkPrivacyIsReported() async throws {
        let advertiser = DenyingAdvertiser(denied: ["Garden"])
        let fixture = try await EngineFixture(advertiser: advertiser)
        let engine = fixture.engine
        try await engine.addCamera(EngineFixture.demoCamera(name: "Garden"), password: nil)
        await engine.start()
        #expect(await fixture.waitFor { advertiser.attempts.value.contains("Garden") })
        #expect(await fixture.waitFor { engine.localNetworkAccess == .denied })
        await fixture.tearDown()
    }
}
#endif
