#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import FMP4
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HAP
import HAPCamera
import HDS
import MediaCore
import Observation
import PlatformApple
import Synchronization
import Testing
import TestSupport
@testable import BridgeEngine

/// Network changes the test fires by hand.
final class ManualNetworkChanges: NetworkChangeMonitoring {
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (changes, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func fire() { continuation.yield(()) }
}

extension EngineTuning {
    /// Small demo streams and a fast status loop for tests.
    static var testing: EngineTuning {
        var tuning = EngineTuning()
        tuning.demoMain = DemoStream(width: 640, height: 360, fps: 15, keyframeInterval: .seconds(1))
        tuning.demoSub = DemoStream(width: 320, height: 180, fps: 10, keyframeInterval: .seconds(1))
        tuning.aspectWait = .seconds(3)
        tuning.statusInterval = .milliseconds(50)
        tuning.localNetworkRetryInterval = .milliseconds(20)
        return tuning
    }
}

/// Counts the publications of `BridgeEngine.recentLogs` (Observation).
@MainActor
final class PublicationCounter {
    let count = Box(0)

    func observe(_ engine: BridgeEngine) {
        withObservationTracking { _ = engine.recentLogs } onChange: { [count, weak self] in
            count.update { $0 += 1 }
            Task { @MainActor [weak self] in self?.observe(engine) }
        }
    }
}

/// An engine on `BridgeEnvironment.testing` (loopback, no advertising, in-memory secrets) with a recording power
/// manager and hand-fired network changes.
@MainActor
struct EngineFixture {
    let directory: TemporaryDirectory
    let engine: BridgeEngine
    let power: RecordingPowerManager
    let networkChanges: ManualNetworkChanges
    let environment: BridgeEnvironment

    /// `advertiser`: a fake that records advertisements (Bonjour stays off without one; never a real advertiser).
    /// `transport`: replaces the loopback transport (a `ScriptedTransport` over it).
    /// `secrets`: replaces the in-memory secret store (Keychain).
    init(tuning: EngineTuning = .testing, directory: TemporaryDirectory? = nil, advertiser: (any ServiceAdvertiser)? = nil,
         transport: (any NetworkTransport)? = nil, secrets: (any SecretStore)? = nil, configure: (inout BridgeSettings) -> Void = { _ in }) async throws {
        let directory = try directory ?? TemporaryDirectory()
        var environment = BridgeEnvironment.testing(directory: directory.url)
        let power = RecordingPowerManager()
        let networkChanges = ManualNetworkChanges()
        environment.platform.power = power
        environment.platform.networkChanges = networkChanges
        if let transport { environment.platform.transport = transport }
        if let secrets { environment.platform.secrets = secrets }
        if let advertiser {
            environment.platform.advertiser = advertiser
            environment.advertise = true
        }
        self.directory = directory
        self.environment = environment
        self.power = power
        self.networkChanges = networkChanges
        engine = BridgeEngine(environment: environment, tuning: tuning)
        var settings = engine.settings
        // Away from Scrypted (30000–50000), Homebridge and the ephemeral range: tests never touch other services.
        settings.basePort = UInt16.random(in: 22_000...28_000)
        settings.sensorsBridgePort = 0
        settings.webhookPort = 0
        configure(&settings)
        try await engine.updateSettings(settings)
    }

    static func demoCamera(name: String = "Demo", kind: CameraKind = .camera) -> CameraConfiguration {
        CameraConfiguration(name: name, kind: kind, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "")
    }

    func status(_ id: UUID) -> CameraStatus? { engine.cameras.first { $0.id == id } }

    func waitFor(_ timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool) async -> Bool {
        await eventually(timeout: timeout, every: .milliseconds(20), condition)
    }

    /// `waitFor` with an asynchronous condition (actor state), polled on the main actor.
    func until(_ timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async -> Bool {
        await eventually(timeout: timeout, every: .milliseconds(20), condition)
    }

    func tearDown() async {
        await engine.stop()
        directory.remove()
    }
}

/// The engine facade end to end on loopback (plan W3-1 items 1–8): demo and RTSP cameras, pairing, motion, live view,
/// HKSV recording over HDS, snapshots, settings and power, camera lifecycle, the webhook, Local Network checks (wake and
/// network changes, restarts and races: `RuntimeCameraLifecycleTests`).
@Suite(.serialized) struct RuntimeEngineTests {
    @MainActor @Test(.timeLimit(.minutes(3))) func demoCameraPairsStreamsRecordsAndReportsMotion() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera()
        try await engine.addCamera(camera, password: nil)
        #expect(engine.configurations.map(\.id) == [camera.id])
        let assigned = try #require(engine.configurations.first?.hapPort)
        #expect(assigned >= 22_000 && assigned < 30_000)
        // Not running yet: the QR code is already known.
        #expect(fixture.status(camera.id)?.setupURI.hasPrefix("X-HM://") == true)

        await engine.start()
        #expect(engine.state == .running)
        #expect(fixture.power.backgroundActivities.value.count == 1 && fixture.power.keepAwakeCalls.value == [false])
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online && fixture.status(camera.id)?.hapPort != nil })
        #expect(await fixture.waitFor { fixture.status(camera.id)?.videoSummary?.hasPrefix("H.264 640×360") == true })
        #expect(engine.sensorsBridge?.setupURI.hasPrefix("X-HM://") == true)
        #expect(await fixture.waitFor { engine.recentLogs.contains { $0.message.hasPrefix("Bridge running") } })
        let status = try #require(fixture.status(camera.id))
        #expect(status.setupCode.count == 10 && !status.isPaired && status.liveViewers == 0)

        // Pair and see motion.
        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        let ids = try await controller.cameraIDs()
        #expect(ids.streams.count == 2 && ids.recording != nil && ids.programmableSwitchEvent == nil)
        let motion = try #require(ids.motionDetected)
        try await controller.subscribe([motion])
        await engine.triggerTestMotion(cameraID: camera.id)
        #expect(try await controller.nextEvent(for: motion).value.hapBool == true)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.isPaired == true && fixture.status(camera.id)?.motionActive == true })
        #expect(fixture.status(camera.id)?.lastEvent == "Motion")

        // Live view from the main stream (720p request: the 640×360 demo stream passes through).
        let live = try await controller.startLiveStream(ids.streams[0])
        #expect(await live.receiver.waitFor(timeout: .seconds(5)) { $0.keyframes >= 1 && $0.videoFrames >= 10 && $0.audioFrames >= 5 })
        #expect(await fixture.waitFor { fixture.status(camera.id)?.liveViewers == 1 })
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(!(await runtime.isSubStreamRunning), "a 720p view uses the main stream")
        try await live.stop()
        // A Watch-sized request uses the sub stream (connected on demand).
        let small = try await controller.startLiveStream(ids.streams[1], options: LiveStreamOptions(resolution: ControllerTLV.Resolution(320, 240, 15),
                                                                                                    maxBitrateKbps: 150))
        #expect(await small.receiver.waitFor(timeout: .seconds(8)) { $0.keyframes >= 1 && $0.videoFrames >= 5 })
        #expect(await runtime.isSubStreamRunning, "the Watch-sized view connected the sub stream")
        try await small.stop()

        // Snapshot for the app.
        let jpeg = try #require(await engine.snapshot(cameraID: camera.id))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))

        // HKSV: select, enable, open over HDS → init + fragments starting with IDRs.
        let recordingIDs = try #require(ids.recording)
        let supported = try await controller.supportedRecordingConfiguration(recordingIDs)
        #expect(supported.video.codecs.first?.resolutions.contains(ControllerTLV.Resolution(1920, 1080, 30)) == true)
        try await controller.selectRecordingConfiguration(recordingIDs, try .preferred(camera: supported.camera, video: supported.video,
                                                                                      audio: supported.audio))
        try await controller.enableRecording(ids, audio: true)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.recordingEnabled == true })
        let dataStream = try await controller.openDataStream(try #require(ids.setupDataStreamTransport))
        let open = try await dataStream.openRecording(streamID: 1)
        #expect(open.isAccepted)
        let capture = try await dataStream.receiveRecording(streamID: 1, maximumFragments: 2, eventTimeout: .seconds(15))
        let initialization = try #require(capture.initialization)
        #expect(try initializationTracks(initialization).trackCount == 2)
        #expect(capture.fragments.count == 2)
        for data in capture.fragments {
            let fragment = try FragmentInfo(data)
            #expect(try fragment.firstVideoSampleNALTypes().contains(5))
            #expect(Double(try #require(fragment.video).totalDuration) / 90_000 <= 4.0 + 1.0 / 15 + 0.001, "fragmentLength plus one frame at most")
            #expect(fragment.audio != nil)
        }
        #expect(await fixture.waitFor { fixture.status(camera.id)?.recordingNow == true })
        try await dataStream.closeRecording(streamID: 1)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.recordingNow == false })
        await dataStream.close()
        await controller.close()

        await engine.stop()
        #expect(engine.state == .stopped)
        #expect(fixture.status(camera.id)?.connection == .idle && fixture.status(camera.id)?.hapPort == nil)
        #expect(fixture.status(camera.id)?.isPaired == true, "pairing survives a stop")
        fixture.directory.remove()
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func keepMacAwakeFollowsSettingsAndTheBridgeState() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let power = fixture.power
        var settings = engine.settings
        settings.keepMacAwake = true
        try await engine.updateSettings(settings)
        #expect(power.keepAwakeCalls.value.isEmpty, "a stopped bridge keeps nothing awake")
        await engine.start()
        #expect(power.keepAwakeCalls.value == [true])
        settings.keepMacAwake = false
        try await engine.updateSettings(settings)
        #expect(power.keepAwakeCalls.value == [true, false])
        settings.keepMacAwake = true
        try await engine.updateSettings(settings)
        #expect(power.keepAwakeCalls.value == [true, false, true])
        await engine.pause()
        #expect(engine.state == .paused && power.keepAwakeCalls.value == [true, false, true, false])
        #expect(power.endedActivities.value == 1, "a paused bridge lets the app nap")
        await engine.resume()
        #expect(engine.state == .running && power.keepAwakeCalls.value.last == true)
        await engine.stop()
        #expect(power.keepAwakeCalls.value.last == false)
        #expect(power.backgroundActivities.value.count == 2)

        // Settings persist; invalid ones are refused.
        let reloaded = try await EngineFixture(directory: fixture.directory) { _ in }
        #expect(reloaded.engine.settings.keepMacAwake)
        var invalid = reloaded.engine.settings
        invalid.webhookPort = 21_500
        invalid.sensorsBridgePort = 21_500
        await #expect(throws: EngineError.self) { try await reloaded.engine.updateSettings(invalid) }
        await reloaded.tearDown()
    }

    /// Review finding (W4 round 4): `recentLogs` was filled only by the status loop, which runs while the bridge runs.
    /// Paused, the log in Settings stopped updating (the Add Camera wizard's checks, the app's own warnings); after a
    /// failed start it stayed empty, although the failed-start banner and "The log in Settings has the details" send
    /// people there. The log follows the sink for as long as it is installed.
    @MainActor @Test(.timeLimit(.minutes(1))) func theLogKeepsUpdatingWhilePausedAndAfterAFailedStart() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        await engine.start()
        await engine.pause()
        #expect(engine.state == .paused)
        let marker = "Logged while paused \(UUID().uuidString)"
        Log(category: "Test").warning(marker)
        #expect(await fixture.waitFor(.seconds(5)) { engine.recentLogs.contains { $0.message == marker } }, "a line logged while paused")
        await fixture.tearDown()

        // A configuration saved by a newer version: the start fails, and why is in the log.
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try Data(#"{"schemaVersion": 99, "settings": {}, "cameras": []}"#.utf8).write(to: ConfigurationStore(directory: directory.url).fileURL)
        let failed = BridgeEngine(environment: .testing(directory: directory.url), tuning: .testing)
        await failed.start()
        guard case .failed = failed.state else {
            Issue.record("the start did not fail: \(failed.state)")
            return
        }
        #expect(await eventually(timeout: .seconds(5), every: .milliseconds(20)) {
            failed.recentLogs.contains { $0.message.hasPrefix("The configuration could not be loaded") }
        }, "the failed start's error is in the log")
        await failed.stop()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func camerasAreAddedChangedDisabledAndRemovedWhileRunning() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        await engine.start()
        var camera = EngineFixture.demoCamera(name: "Garden", kind: .doorbell)
        camera.username = "viewer"
        try await engine.addCamera(camera, password: "pa55")
        #expect(try CredentialStore(secrets: fixture.environment.platform.secrets).password(for: camera.id) == "pa55")
        #expect(fixture.status(camera.id)?.setupURI.hasPrefix("X-HM://") == true, "the QR code is there when addCamera returns")
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        await #expect(throws: EngineError.duplicateCamera) { try await engine.addCamera(camera, password: nil) }
        let firstRuntime = try #require(engine.runtimes[camera.id])

        // Sensor options do not restart the camera; a rename does.
        camera = try #require(engine.configurations.first)
        camera.sensors.person = true
        try await engine.updateCamera(camera, password: nil)
        #expect(engine.runtimes[camera.id] === firstRuntime)
        camera.name = "Garden Gate"
        try await engine.updateCamera(camera, password: nil)
        #expect(engine.runtimes[camera.id] !== firstRuntime)
        #expect(fixture.status(camera.id)?.name == "Garden Gate")
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })

        // Disable / enable.
        camera.isEnabled = false
        try await engine.updateCamera(camera, password: nil)
        #expect(engine.runtimes[camera.id] == nil)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .disabled })
        camera.isEnabled = true
        try await engine.updateCamera(camera, password: nil)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        await #expect(throws: EngineError.unknownCamera) { try await engine.updateCamera(EngineFixture.demoCamera(), password: nil) }

        // Reset pairing works on a running camera.
        try await engine.resetPairing(cameraID: camera.id)
        try await engine.resetSensorsBridgePairing()

        // Remove: configuration, password, HAP state and identity are gone.
        let hapDirectory = HAPStorage.directory(for: camera.id, in: fixture.directory.url)
        #expect(FileManager.default.fileExists(atPath: hapDirectory.path(percentEncoded: false)))
        await engine.removeCamera(id: camera.id)
        #expect(engine.configurations.isEmpty && engine.cameras.isEmpty && engine.runtimes.isEmpty)
        #expect(try CredentialStore(secrets: fixture.environment.platform.secrets).password(for: camera.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: hapDirectory.path(percentEncoded: false)))
        #expect(try ConfigurationStore(directory: fixture.directory.url).load()?.cameras.isEmpty == true)
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func rtspCameraReportsRejectedCredentialsUntilThePasswordIsFixed() async throws {
        var serverConfiguration = RTSPTestServer.Configuration()
        serverConfiguration.credentials = HTTPCredentials(username: "admin", password: "s3cret")
        serverConfiguration.audio = AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1)
        let server = RTSPTestServer(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: .pcmu, audioRate: 8_000),
                                    transport: AppleNetworkTransport(), configuration: serverConfiguration)
        try await server.start()
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        var camera = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "127.0.0.1", rtspPort: Int(server.port)),
                                         username: "admin")
        camera.mainStreamURL = server.url
        camera.motionSource = .webhook
        try await engine.addCamera(camera, password: "wrong")
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.lastError == SensorState.credentialsRejectedMessage })
        if case .offline = fixture.status(camera.id)?.connection {} else { Issue.record("expected offline") }

        try await engine.updateCamera(try #require(engine.configurations.first), password: "s3cret")
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        #expect(fixture.status(camera.id)?.lastError == nil)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.videoSummary?.hasPrefix("H.264 640×360") == true })

        // The camera drops the connection: the ingest reconnects by itself.
        let plays = server.requests.filter { $0.method == "PLAY" }.count
        server.dropConnections()
        #expect(await fixture.waitFor { server.requests.filter { $0.method == "PLAY" }.count > plays })
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        await fixture.tearDown()
        await server.stop()
    }

    /// Review finding (W4): the stream's "credentials rejected" state survived runtime restarts, so a camera that was
    /// unreachable when the person fixed its password kept blaming the new, correct password (and a paused bridge too).
    @MainActor @Test(.timeLimit(.minutes(2))) func aRestartForgetsTheStreamsRejectedCredentials() async throws {
        var serverConfiguration = RTSPTestServer.Configuration()
        serverConfiguration.credentials = HTTPCredentials(username: "admin", password: "s3cret")
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 10, gop: .seconds(1), audio: nil),
                                    transport: AppleNetworkTransport(), configuration: serverConfiguration)
        try await server.start()
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        var camera = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "127.0.0.1", rtspPort: Int(server.port)),
                                         username: "admin")
        camera.mainStreamURL = server.url
        camera.motionSource = .webhook
        try await engine.addCamera(camera, password: "wrong")
        await engine.start()
        #expect(await fixture.waitFor(.seconds(30)) { fixture.status(camera.id)?.lastError == SensorState.credentialsRejectedMessage })

        // The camera goes away; the person enters the right password meanwhile.
        await server.stop()
        try await engine.updateCamera(try #require(engine.configurations.first), password: "s3cret")
        #expect(await fixture.waitFor { fixture.status(camera.id)?.lastError != SensorState.credentialsRejectedMessage })
        #expect(await engine.router.state(for: camera.id)?.credentialsRejected == false)

        await engine.pause()
        #expect(fixture.status(camera.id)?.connection == .idle, "a paused camera is idle, not rejected")
        await fixture.tearDown()
    }

    /// Review finding (W4): when the configuration could not be saved, `removeCamera` still dropped the camera and deleted
    /// its password and HAP identity; it came back at the next launch without them.
    @MainActor @Test(.timeLimit(.minutes(1))) func aCameraWhoseRemovalCannotBeSavedStaysWithItsSecrets() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        var camera = EngineFixture.demoCamera(name: "Shed")
        camera.username = "viewer"
        try await engine.addCamera(camera, password: "secret")
        await engine.refreshStatus()
        let credentials = CredentialStore(secrets: fixture.environment.platform.secrets)
        let hapStore = HAPStorage.store(for: camera.id, dataDirectory: fixture.directory.url, secrets: fixture.environment.platform.secrets)
        #expect(try hapStore.loadIdentity() != nil)

        // The data directory becomes read-only: the configuration cannot be written.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.url.path(percentEncoded: false))
        await engine.removeCamera(id: camera.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.url.path(percentEncoded: false))

        #expect(engine.configurations.map(\.id) == [camera.id], "the camera stays: it is still in config.json")
        #expect(try credentials.password(for: camera.id) == "secret")
        #expect(try hapStore.loadIdentity() != nil)
        let reloaded = BridgeEngine(environment: fixture.environment, tuning: .testing)
        #expect(reloaded.configurations.map(\.id) == [camera.id])
        await fixture.tearDown()
    }

    /// Review finding (W4 round 2): a camera that is not running reads its setup code from its HAP store, creating the
    /// identity when there is none. With the identity gone (lost or reset login keychain) but `state.json` still holding
    /// the pairings, it showed "paired" under a new identity no controller knows, and the accessory server found an
    /// identity next to the stale pairings later. The pairings of the lost identity go with it.
    @MainActor @Test(.timeLimit(.minutes(1))) func aStoppedCameraThatLostItsIdentityIsNoLongerPaired() async throws {
        let fixture = try await EngineFixture()
        let camera = EngineFixture.demoCamera(name: "Porch")
        try await fixture.engine.addCamera(camera, password: nil)
        await fixture.engine.refreshStatus()
        let secrets = fixture.environment.platform.secrets
        let store = HAPStorage.store(for: camera.id, dataDirectory: fixture.directory.url, secrets: secrets)
        let lost = try #require(try store.loadIdentity())
        var state = try store.loadState() ?? HAPPersistentState()
        state.pairings = [Pairing(identifier: "home-hub", publicKey: Data(repeating: 1, count: 32), isAdmin: true)]
        try store.saveState(state)
        try secrets.write(nil, account: HAPStorage.account(for: camera.id))

        let reloaded = BridgeEngine(environment: fixture.environment, tuning: .testing)
        await reloaded.refreshStatus()
        let status = try #require(reloaded.cameras.first { $0.id == camera.id })
        #expect(status.isPaired == false)
        let identity = try #require(try store.loadIdentity())
        #expect(identity.deviceID != lost.deviceID)
        #expect(status.setupCode == identity.setupCode.formatted)
        #expect(try store.loadState()?.pairings.isEmpty == true)
        await fixture.tearDown()
    }

    /// Review finding (W4): the detail form sends every pause in typing or dragging, and each update restarted the whole
    /// accessory (live viewers and HKSV recordings cut). Sensitivity is applied to soft motion in place; a paired
    /// camera's rename (Home keeps its own name) needs no restart either.
    @MainActor @Test(.timeLimit(.minutes(2))) func tuningSoftMotionOrRenamingAPairedCameraKeepsItRunning() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        var camera = EngineFixture.demoCamera(name: "Yard")
        camera.motionSource = .softMotion
        camera.motionSensitivity = 0.5
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online && fixture.status(camera.id)?.hapPort != nil })
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(await runtime.softMotionSensitivity == 0.5)

        camera = try #require(engine.configurations.first)
        camera.motionSensitivity = 0.9
        try await engine.updateCamera(camera, password: nil)
        #expect(engine.runtimes[camera.id] === runtime, "a sensitivity change does not restart the camera")
        #expect(await runtime.softMotionSensitivity == 0.9)
        #expect(await runtime.isSoftMotionRunning)

        // Unpaired, a rename restarts (the advertised name is what Home shows when pairing); paired, it does not.
        let status = try #require(fixture.status(camera.id))
        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.isPaired == true })
        camera.name = "Back Yard"
        try await engine.updateCamera(camera, password: nil)
        #expect(engine.runtimes[camera.id] === runtime, "Home keeps its own name for a paired camera")
        #expect(fixture.status(camera.id)?.name == "Back Yard")
        await controller.close()
        await fixture.tearDown()
    }

    /// A `SecretStore` that notes every call made on the main thread (the Keychain blocks its caller).
    final class ThreadRecordingSecrets: SecretStore {
        let base: any SecretStore
        let mainThreadCalls = Box<[String]>([])
        init(base: any SecretStore) { self.base = base }
        func read(account: String) throws -> Data? {
            note("read \(account)")
            return try base.read(account: account)
        }
        func write(_ data: Data?, account: String) throws {
            note("write \(account)")
            try base.write(data, account: account)
        }
        private func note(_ call: String) {
            if Thread.isMainThread { mainThreadCalls.update { $0.append(call) } }
        }
    }

    /// Review finding (W4): passwords, HAP identities and the configuration file were read and written synchronously on
    /// the main actor (SecItemCopyMatching blocks; a slow securityd or a Keychain prompt froze the menu and windows).
    @MainActor @Test(.timeLimit(.minutes(1))) func secretsAreNeverReadOrWrittenOnTheMainThread() async throws {
        let directory = try TemporaryDirectory()
        var environment = BridgeEnvironment.testing(directory: directory.url)
        let secrets = ThreadRecordingSecrets(base: environment.platform.secrets)
        environment.platform.secrets = secrets
        let engine = BridgeEngine(environment: environment, tuning: .testing)
        var settings = engine.settings
        settings.basePort = UInt16.random(in: 22_000...28_000)
        settings.sensorsBridgePort = 0
        settings.webhookPort = 0
        try await engine.updateSettings(settings)
        var camera = EngineFixture.demoCamera(name: "Gate")
        camera.username = "viewer"
        try await engine.addCamera(camera, password: "pa55")   // password + the stopped camera's setup code
        var other = EngineFixture.demoCamera(name: "Side")
        other.isEnabled = false
        try await engine.addCamera(other, password: nil)
        await engine.start()
        let deadline = ContinuousClock.now + .seconds(15)
        while engine.cameras.first(where: { $0.id == camera.id })?.connection != .online, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.cameras.first { $0.id == camera.id }?.connection == .online)
        // The Connection sheet's check of a configured camera reads its stored password (review finding W4 round 2: the
        // merge fix that moved this read off the main actor had no test).
        let probed = try await engine.probeCamera(camera, password: nil)
        #expect(probed.vendor == .demo)
        camera = try #require(engine.configurations.first { $0.id == camera.id })
        camera.name = "Front Gate"
        try await engine.updateCamera(camera, password: "pa66")
        try await engine.resetPairing(cameraID: other.id)
        await engine.pause()
        await engine.removeCamera(id: other.id)
        await engine.stop()
        #expect(secrets.mainThreadCalls.value.isEmpty, "\(secrets.mainThreadCalls.value)")
        directory.remove()
    }

    /// An ONVIF-style driver: stream addresses only from `probe()`, a talkback sink, no events.
    final class ProbingDriver: CameraDriver {
        let vendor: CameraVendor = .onvif
        let streamURL: URL
        let probes = Box(0)

        init(streamURL: URL) { self.streamURL = streamURL }

        func probe() async throws -> CameraProbeResult {
            probes.update { $0 += 1 }
            return CameraProbeResult(vendor: .onvif, manufacturer: "Acme", model: "Cam", serialNumber: "SN1", firmware: "2.1",
                                     mainStream: StreamInfo(url: streamURL, videoCodec: .h264), capabilities: CameraCapabilities(twoWayAudio: true))
        }

        func makeEventSource() -> (any CameraEventSource)? { nil }
        func snapshot() async throws -> Data? { nil }
        func makeTalkbackSink() -> (any TalkbackSink)? { RuntimeLiveStreamTests.FakeTalkbackSink() }
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func streamAddressesFromTheProbeAndTwoWayAudio() async throws {
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil),
                                    transport: AppleNetworkTransport())
        try await server.start()
        let driver = ProbingDriver(streamURL: server.url)
        var tuning = EngineTuning.testing
        tuning.driverFactory = { _, _, _ in driver }
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        var camera = CameraConfiguration(name: "Garage", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "127.0.0.1"), username: "")
        camera.twoWayAudio = true
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        #expect(driver.probes.value >= 1)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.videoSummary?.hasPrefix("H.264 320×180") == true })
        // Two-way audio is offered: the accessory has a Speaker next to the Microphone.
        let status = try #require(fixture.status(camera.id))
        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        let accessory = try #require(try await controller.accessories().accessories.first)
        #expect(accessory.service(.speaker) != nil && accessory.service(.microphone) != nil)
        #expect(accessory.information(.manufacturer) == "ONVIF")
        await controller.close()
        await fixture.tearDown()
        await server.stop()
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func webhookDrivesMotionAndRingsTheDoorbell() async throws {
        let fixture = try await EngineFixture { $0.webhookEnabled = true }
        let engine = fixture.engine
        var camera = EngineFixture.demoCamera(name: "Front Door", kind: .doorbell)
        camera.motionSource = .webhook
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.hapPort != nil })
        let port = try #require(await engine.webhook?.boundPort)
        func post(_ event: String) async throws -> Int? {
            var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/cameras/\(camera.id.uuidString)/\(event)")))
            request.httpMethod = "POST"
            request.setValue("Bearer \(engine.settings.webhookToken)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        }

        // A video doorbell accessory (category 18 publishes the Doorbell service): a ring is a ProgrammableSwitchEvent
        // and a motion pulse, so the hub records it.
        let status = try #require(fixture.status(camera.id))
        #expect(status.setupURI.hasPrefix("X-HM://"))
        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        let ids = try await controller.cameraIDs()
        let ring = try #require(ids.programmableSwitchEvent)
        let motion = try #require(ids.motionDetected)
        try await controller.subscribe([ring, motion])
        #expect(try await post("doorbell") == 204)
        #expect(try await controller.nextEvent(for: ring).value == .int(0))
        #expect(try await controller.nextEvent(for: motion).value.hapBool == true)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.lastEvent == "Doorbell ring" })
        await controller.close()

        #expect(try await post("motion") == 204)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.motionActive == true })
        // Turning the webhook off closes it.
        var settings = engine.settings
        settings.webhookEnabled = false
        try await engine.updateSettings(settings)
        #expect(engine.webhook == nil)
        await fixture.tearDown()
    }

    /// Review finding (W4 round 3): the webhook answered 204 for any well-formed camera ID and the router then dropped
    /// events for unknown or disabled cameras without a trace. The engine's webhook asks the router: an ID that is not
    /// configured (never was, or removed) is 404, a disabled camera 409.
    @MainActor @Test(.timeLimit(.minutes(1))) func webhookRefusesUnknownAndDisabledCameras() async throws {
        let fixture = try await EngineFixture { $0.webhookEnabled = true }
        let engine = fixture.engine
        var camera = EngineFixture.demoCamera()
        camera.motionSource = .webhook
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        let port = try #require(await engine.webhook?.boundPort)
        func post(_ id: UUID) async throws -> Int? {
            var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/cameras/\(id.uuidString)/motion")))
            request.httpMethod = "POST"
            request.setValue("Bearer \(engine.settings.webhookToken)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        }

        #expect(try await post(UUID()) == 404, "not a configured camera")
        #expect(try await post(camera.id) == 204)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.motionActive == true })
        camera = try #require(engine.configurations.first)
        camera.isEnabled = false
        try await engine.updateCamera(camera, password: nil)
        #expect(try await post(camera.id) == 409, "a disabled camera")
        camera.isEnabled = true
        try await engine.updateCamera(camera, password: nil)
        #expect(try await post(camera.id) == 204)
        await engine.removeCamera(id: camera.id)
        #expect(try await post(camera.id) == 404, "a removed camera")
        await fixture.tearDown()
    }

    /// Review finding (W4): a webhook that could not listen (port taken by another app) was only logged; Settings showed
    /// it enabled and Home Assistant got "connection refused" with no sign in the app.
    @MainActor @Test(.timeLimit(.minutes(1))) func aWebhookThatCannotListenIsRefusedAndRolledBack() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        await engine.start()
        let held = try await AppleNetworkTransport().listen(port: 0, loopbackOnly: true)   // another app's port
        var settings = engine.settings
        settings.webhookEnabled = true
        settings.webhookPort = held.port
        await #expect(throws: EngineError.self) { try await engine.updateSettings(settings) }
        #expect(!engine.settings.webhookEnabled, "the settings are not applied")
        #expect(engine.webhook == nil)
        #expect(try ConfigurationStore(directory: fixture.directory.url).load()?.settings.webhookEnabled == false)
        // Once the port is free (the listener's close completes asynchronously) the same settings apply.
        held.close()
        #expect(await fixture.until { (try? await engine.updateSettings(settings)) != nil })
        #expect(engine.settings.webhookEnabled && engine.webhook != nil)
        await fixture.tearDown()
    }

    /// Listens on `port` for "another app", retrying while a listener that just closed still holds it.
    static func occupy(_ port: UInt16) async -> (any TCPListener)? {
        for _ in 0..<100 {
            if let listener = try? await AppleNetworkTransport().listen(port: port, loopbackOnly: true) { return listener }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Review finding (W4 round 2): the round-1 check covered only a webhook turned on while the bridge ran. Paused or
    /// stopped, the setting was saved unchecked, and a webhook that could not listen at start or resume was only logged:
    /// Settings showed it on while Frigate / Home Assistant posts reached nobody. Now the change is refused while paused
    /// or stopped too, and a start that cannot listen publishes `webhookProblem` (Settings shows it with Try Again).
    @MainActor @Test(.timeLimit(.minutes(1))) func aWebhookThatCannotListenIsRefusedWhileStoppedAndReportedAtStart() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let held = try await AppleNetworkTransport().listen(port: 0, loopbackOnly: true)   // another app's port
        let port = held.port
        var settings = engine.settings
        settings.webhookEnabled = true
        settings.webhookPort = port
        await #expect(throws: EngineError.self) { try await engine.updateSettings(settings) }
        #expect(!engine.settings.webhookEnabled, "refused while stopped, as while running")
        #expect(engine.webhookProblem == nil)

        // Free when it is turned on, taken again by the time the bridge starts.
        held.close()
        #expect(await fixture.until { (try? await engine.updateSettings(settings)) != nil })
        #expect(engine.settings.webhookEnabled && engine.webhook == nil, "a stopped bridge does not listen")
        let taken = try #require(await Self.occupy(port))
        await engine.start()
        #expect(engine.state == .running && engine.webhook == nil)
        #expect(engine.webhookProblem?.contains("another app uses the port") == true, "\(String(describing: engine.webhookProblem))")

        // Try Again once the port is free.
        taken.close()
        #expect(await fixture.until { await engine.retryWebhook(); return engine.webhookProblem == nil })
        #expect(engine.webhook != nil)

        // Resume reports it too; turning the webhook off clears it.
        await engine.pause()
        #expect(engine.webhookProblem == nil, "a paused bridge has no webhook")
        let again = try #require(await Self.occupy(port))
        await engine.resume()
        #expect(engine.webhookProblem != nil)
        settings.webhookEnabled = false
        try await engine.updateSettings(settings)
        #expect(engine.webhookProblem == nil)
        again.close()
        await fixture.tearDown()
    }

    /// Review finding (W4 round 2): "status at most 4 Hz" (plan W3-1 item 7) had no test; removing the status loop's
    /// rate limit (a refresh, which awaits every runtime and the router, for every log line) passed every suite.
    @MainActor @Test(.timeLimit(.minutes(1))) func statusIsPublishedAtMostFourTimesASecond() async throws {
        var tuning = EngineTuning.testing
        tuning.statusInterval = .milliseconds(250)
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        await engine.start()
        try await Task.sleep(for: .milliseconds(600))
        let counter = PublicationCounter()
        counter.observe(engine)
        let publications = counter.count
        let log = Log(category: "RateTest")
        let started = ContinuousClock.now
        for index in 0..<150 {
            log.notice("burst \(index)")
            try await Task.sleep(for: .milliseconds(8))
        }
        #expect(await fixture.waitFor(.seconds(3)) { engine.recentLogs.contains { $0.message == "burst 149" } })
        let elapsed = Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000
        #expect(publications.value <= Int(elapsed * 4) + 2, "\(publications.value) publications in \(elapsed) s")
        #expect(publications.value >= 2, "the logs were published")
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func localNetworkCheckMapsTransportAnswers() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        func engine(_ failure: TransportError?) -> BridgeEngine {
            let transport = failure.map { FakeTransport(connectFailure: $0) } ?? FakeTransport(busyPorts: [554])
            return BridgeEngine(environment: BridgeEnvironment(dataDirectory: directory.url,
                                                               platform: PlatformServices(transport: transport, advertiser: NullServiceAdvertiser(),
                                                                                          secrets: InMemorySecretStore(),
                                                                                          networkChanges: NullNetworkChangeMonitor(), power: NullPowerManager()),
                                                               codecs: AppleMediaCodecs(), loopbackOnly: true, advertise: false),
                                tuning: .testing)
        }
        let denied = engine(.localNetworkDenied)
        #expect(await denied.checkLocalNetworkAccess(host: "192.0.2.10", answerWait: .milliseconds(100)) == .denied)
        #expect(denied.localNetworkAccess == .denied)
        #expect(await engine(.connectionRefused).checkLocalNetworkAccess(host: "192.0.2.10") == .granted)
        #expect(await engine(nil).checkLocalNetworkAccess(host: "192.0.2.10") == .granted)
        let unknown = engine(.timedOut)
        #expect(await unknown.checkLocalNetworkAccess(host: "192.0.2.10") == .unknown && unknown.localNetworkAccess == .unknown)
        #expect(await unknown.checkLocalNetworkAccess(host: nil) == .unknown)
        #expect(await unknown.discoverCameras().isEmpty, "loopback-only environments never multicast")
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func aConfigurationFromANewerVersionFailsTheStart() async throws {
        let directory = try TemporaryDirectory()
        try Data(#"{"schemaVersion": 99, "settings": {}, "cameras": []}"#.utf8).write(to: directory.file("config.json"))
        let engine = BridgeEngine(environment: .testing(directory: directory.url), tuning: .testing)
        await engine.start()
        guard case .failed(let reason) = engine.state else {
            Issue.record("expected .failed, got \(engine.state)")
            return
        }
        // Review finding (W4 round 2): the app showed this reason as "…: unsupportedSchemaVersion(99)".
        #expect(reason == "The configuration was saved by a newer version of Camera Bridge. Update Camera Bridge to use it.")
        await engine.stop()
        directory.remove()
    }

    /// Review finding (W4 round 3): a damaged config.json was set aside and replaced with the defaults, and only the log
    /// said so: the app showed "No Cameras Yet" while Home's accessories went "No Response". The engine publishes where
    /// the damaged file went until the person dismisses it.
    @MainActor @Test(.timeLimit(.minutes(1))) func aDamagedConfigurationIsSetAsideAndSaidSo() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try Data(#"{"schemaVersion": 1, "settings": {"#.utf8).write(to: directory.file("config.json"))
        let engine = BridgeEngine(environment: .testing(directory: directory.url), tuning: .testing)
        #expect(engine.configurationRecoveredFrom == nil)
        await engine.start()
        #expect(engine.state == .running && engine.configurations.isEmpty)
        let backup = try #require(engine.configurationRecoveredFrom)
        #expect(backup.lastPathComponent.hasPrefix("config.corrupt-"))
        #expect(directory.contents().contains(backup.lastPathComponent), "the damaged file is kept: \(directory.contents())")
        await engine.acknowledgeConfigurationRecovery()
        #expect(engine.configurationRecoveredFrom == nil)
        await engine.stop()
        await engine.start()
        #expect(engine.configurationRecoveredFrom == nil, "the configuration saved since loads")
        await engine.stop()
    }

    /// Review finding (W4 round 4): the notice lived in memory only, and the configuration saved after the recovery
    /// loads normally, so after a relaunch (a login item launch stays in the menu bar) nothing said why every camera was
    /// gone. The notice is kept next to config.json until the person dismisses it.
    @MainActor @Test(.timeLimit(.minutes(1))) func aDamagedConfigurationNoticeSurvivesARelaunchUntilDismissed() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try Data(#"{"schemaVersion": 1, "settings": {"#.utf8).write(to: directory.file("config.json"))
        let first = BridgeEngine(environment: .testing(directory: directory.url), tuning: .testing)
        await first.start()
        let backup = try #require(first.configurationRecoveredFrom).lastPathComponent
        await first.stop()

        let relaunched = BridgeEngine(environment: .testing(directory: directory.url), tuning: .testing)
        #expect(relaunched.configurationRecoveredFrom?.lastPathComponent == backup, "known before the start")
        await relaunched.start()
        #expect(relaunched.state == .running && relaunched.configurationRecoveredFrom?.lastPathComponent == backup)
        await relaunched.acknowledgeConfigurationRecovery()
        #expect(relaunched.configurationRecoveredFrom == nil)
        await relaunched.stop()

        let afterDismissal = BridgeEngine(environment: .testing(directory: directory.url), tuning: .testing)
        #expect(afterDismissal.configurationRecoveredFrom == nil)
        #expect(directory.contents().contains(backup), "dismissing keeps the damaged file: \(directory.contents())")
    }

    /// Review finding (W4 round 2): engine state strings (a failed start, an accessory that could not start) are shown
    /// by the app, and carried Swift case names or NSError dumps. They are sentences; the raw error goes to the log.
    @Test func failureReasonsAreReadable() {
        let caseName = /[A-Za-z]\(|Error Domain=|UserInfo=/
        let errors: [any Error] = [
            ConfigurationStoreError.unsupportedSchemaVersion(99), ConfigurationStoreError.corrupt("not JSON"),
            PortAllocationError.noFreePort(startingAt: 21_100), TransportError.addressInUse, TransportError.localNetworkDenied,
            TransportError.failed("bind failed"), CredentialStoreError.undecodablePassword, EngineError.unknownCamera,
            CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: "/Users/someone/config.json"]),
            NSError(domain: NSPOSIXErrorDomain, code: 13), CancellationError(),
        ]
        for error in errors {
            let text = BridgeEngine.readableReason(error)
            #expect(!text.isEmpty && !text.contains(caseName), "\(error): \(text)")
        }
        #expect(BridgeEngine.readableReason(PortAllocationError.noFreePort(startingAt: 21_100)) == "no free network port was found from port 21100 upward")
        #expect(BridgeEngine.startFailure(ConfigurationStoreError.unsupportedSchemaVersion(99))
                == "The configuration was saved by a newer version of Camera Bridge. Update Camera Bridge to use it.")
        #expect(BridgeEngine.startFailure(CocoaError(.fileReadNoPermission)).hasPrefix("The configuration could not be read: "))
    }

    /// Review finding (W4 round 2): `AppModel.updateSettings` copied the settings, changed them and wrote them back; a
    /// second change made while the engine was busy started from the same copy and undid the first. A change applied
    /// inside the engine's queue starts from the settings as they are then.
    @MainActor @Test(.timeLimit(.minutes(1))) func overlappingSettingsChangesBothStick() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let token = String(repeating: "b", count: 32)
        let first = Task { try await engine.updateSettings { $0.keepMacAwake = true } }
        let second = Task { try await engine.updateSettings { $0.webhookToken = token } }
        try await first.value
        try await second.value
        #expect(engine.settings.keepMacAwake && engine.settings.webhookToken == token)
        let saved = try #require(try ConfigurationStore(directory: fixture.directory.url).load()?.settings)
        #expect(saved.keepMacAwake && saved.webhookToken == token)
        // A result that isn't valid is refused, like whole settings are.
        await #expect(throws: EngineError.self) {
            try await engine.updateSettings {
                $0.webhookEnabled = true
                $0.webhookToken = "short"
            }
        }
        #expect(!engine.settings.webhookEnabled && engine.settings.webhookToken == token)
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func previewEngineOperationsAreInert() async throws {
        let engine = BridgeEngine.preview()
        let cameras = engine.cameras
        await engine.start()
        await engine.pause()
        try await engine.addCamera(EngineFixture.demoCamera(), password: nil)
        await engine.removeCamera(id: cameras[0].id)
        #expect(engine.state == .running && engine.cameras == cameras)
        #expect(await engine.snapshot(cameraID: cameras[0].id) == nil)
    }

    /// Review finding (W4 round 4): resetting a paused sensors bridge has its own branch (nothing restarts it, so the
    /// status shown until it runs again must name the new code), which no test ran: without it the paused page kept the
    /// old, dead setup code and QR code. The old code pairs nothing once the bridge runs again.
    @MainActor @Test(.timeLimit(.minutes(1))) func resettingAPausedSensorsBridgeShowsItsNewCode() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        try await engine.addCamera(EngineFixture.demoCamera(name: "Porch"), password: nil)
        await engine.start()
        let before = try #require(engine.sensorsBridge)
        await engine.pause()
        #expect(engine.bridge == nil && engine.sensorsBridge == before, "a paused bridge's status stays shown")
        try await engine.resetSensorsBridgePairing()
        let shown = try #require(engine.sensorsBridge)
        #expect(shown.setupCode != before.setupCode && shown.setupURI != before.setupURI && !shown.isPaired, "\(before) → \(shown)")
        #expect(shown.accessoryCount == before.accessoryCount)
        await engine.resume()
        #expect(engine.sensorsBridge?.setupCode == shown.setupCode && engine.sensorsBridge?.setupURI == shown.setupURI,
                "the code shown while paused is the one the bridge runs with")
        let port = try #require(await engine.bridge?.server.port)
        await #expect(throws: (any Error).self, "the old setup code pairs nothing") {
            let old = try await HAPTestController.paired(port: port, setupCode: before.setupCode)
            await old.close()
        }
        let controller = try await HAPTestController.paired(port: port, setupCode: shown.setupCode)
        await controller.close()
        await fixture.tearDown()
    }

    /// A secret store whose writes fail while `failing` is set (a Keychain that refuses them).
    final class FailingWritesSecretStore: SecretStore {
        struct WriteRefused: Error {}
        let base = InMemorySecretStore()
        let failing = Box(false)

        func read(account: String) throws -> Data? { try base.read(account: account) }
        func write(_ data: Data?, account: String) throws {
            if failing.value { throw WriteRefused() }
            try base.write(data, account: account)
        }
    }

    /// Review finding (W4 round 4): a reset whose new identity cannot be saved stops what was running first; its error
    /// path (start the camera or the sensors bridge again with the identity it had, then throw) never ran.
    @MainActor @Test(.timeLimit(.minutes(1))) func aResetThatCannotSaveTheNewIdentityRestartsWhatWasRunning() async throws {
        let secrets = FailingWritesSecretStore()
        let fixture = try await EngineFixture(secrets: secrets)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Porch")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online && fixture.status(camera.id)?.hapPort != nil })
        let code = try #require(fixture.status(camera.id)?.setupCode)
        let bridgeCode = try #require(engine.sensorsBridge?.setupCode)
        let runtime = try #require(engine.runtimes[camera.id])
        secrets.failing.set(true)
        await #expect(throws: FailingWritesSecretStore.WriteRefused.self) { try await engine.resetPairing(cameraID: camera.id) }
        await #expect(throws: FailingWritesSecretStore.WriteRefused.self) { try await engine.resetSensorsBridgePairing() }
        secrets.failing.set(false)
        #expect(engine.runtimes[camera.id] != nil && engine.runtimes[camera.id] !== runtime, "the camera was stopped and started again")
        #expect(engine.bridge != nil && engine.sensorsBridge?.setupCode == bridgeCode, "the sensors bridge runs again with its code")
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online && fixture.status(camera.id)?.setupCode == code })
        #expect(await fixture.waitFor(.seconds(5)) {
            engine.recentLogs.contains { $0.message.hasPrefix("The HomeKit pairing of Porch could not be reset") }
                && engine.recentLogs.contains { $0.message.hasPrefix("The HomeKit pairing of the sensors bridge could not be reset") }
        })
        await fixture.tearDown()
    }
}
#endif
