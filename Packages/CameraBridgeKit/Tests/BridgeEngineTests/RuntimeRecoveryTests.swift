#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import PlatformApple
import RTP
import Synchronization
import Testing
import TestSupport
@testable import BridgeEngine

/// Records when each advertisement was made and advertises nothing.
final class TimedAdvertiser: ServiceAdvertiser {
    let records = Box<[(name: String, at: ContinuousClock.Instant)]>([])

    func advertise(_ advertisement: ServiceAdvertisement) async throws -> any AdvertisedService {
        records.update { $0.append((advertisement.name, .now)) }
        return try await NullServiceAdvertiser().advertise(advertisement)
    }

    func times(_ name: String) -> [ContinuousClock.Instant] { records.value.filter { $0.name == name }.map(\.at) }
}

/// Refuses the instance lock while `held`, and counts acquisitions and releases.
final class FakeInstanceLock: InstanceLocking {
    let held = Box(false)
    let acquisitions = Box(0)
    let releases = Box(0)

    func acquire(directory: URL) -> String? {
        acquisitions.update { $0 += 1 }
        return held.value ? "Camera Bridge is already running with this configuration." : nil
    }

    func release() { releases.update { $0 += 1 } }
}

/// Hardening plan WS-C 4, 5, 7, 8, 9, 10, 12 on the engine: what a network change, a wake, a hung camera and a flapping
/// network do, what a new install defaults to, and what the log says about it. Timings are shortened through `EngineTuning`.
@Suite(.serialized) struct RuntimeRecoveryTests {
    static var tuning: EngineTuning {
        var tuning = EngineTuning.testing
        tuning.networkSettle = .milliseconds(80)
        tuning.advertisingStagger = .milliseconds(0)
        return tuning
    }

    // MARK: - Network change and wake

    /// Audit F4 / B2: a network change reconnected every camera's stream although it did not touch the camera's path. A stream
    /// that delivers video is left connected (the event channel and the advertisement are still refreshed); a wake always
    /// reconnects.
    @MainActor @Test(.timeLimit(.minutes(1))) func aNetworkChangeLeavesAHealthyStreamConnectedButAWakeReconnectsIt() async throws {
        let driver = ScriptedEventDriver()
        var tuning = Self.tuning
        tuning.driverFactory = { _, _, _ in driver }
        let advertiser = CountingAdvertiser()
        let fixture = try await EngineFixture(tuning: tuning, advertiser: advertiser)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Lobby")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(await fixture.until { advertiser.count("Lobby") == 1 })
        try await Task.sleep(for: .milliseconds(400))   // video is flowing
        let attempts = await runtime.ingestAttempts.main

        fixture.networkChanges.fire()
        #expect(await fixture.until(.seconds(10)) { advertiser.count("Lobby") == 2 }, "advertisement refreshed")
        #expect(driver.sourcesMade.value == 1, "the event channel of a camera whose video still arrives is kept")
        #expect(await runtime.ingestAttempts.main == attempts, "the healthy stream was not reconnected")
        #expect(await fixture.waitFor { engine.recentLogs.contains { $0.message.contains("keeping the stream connected") } })
        #expect(fixture.status(camera.id)?.connection == .online)

        await engine.systemDidWake()
        #expect(await fixture.until(.seconds(10)) { await runtime.ingestAttempts.main == (attempts ?? 0) + 1 }, "a wake always reconnects the stream")
        await fixture.tearDown()
    }

    /// Audit B2: a network that keeps flapping postponed the reconnect for as long as it flapped (a trailing-edge debounce).
    /// It starts `networkSettleCap` after the burst's first change at the latest.
    @MainActor @Test(.timeLimit(.minutes(1))) func aFlappingNetworkIsReconnectedWithinTheCapAndNotOnlyWhenItSettles() async throws {
        var tuning = Self.tuning
        tuning.networkSettle = .milliseconds(300)
        tuning.networkSettleCap = .milliseconds(700)
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        try await engine.addCamera(EngineFixture.demoCamera(name: "Gate"), password: nil)
        await engine.start()
        #expect(await fixture.waitFor { engine.recentLogs.contains { $0.message.hasPrefix("Bridge running") } })

        let changes = fixture.networkChanges
        let flapping = Task {
            for _ in 0..<60 {
                changes.fire()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { flapping.cancel() }
        // Changes every 100 ms never leave 300 ms of quiet: without the cap nothing would reconnect while this runs (6 s).
        #expect(await fixture.waitFor(.seconds(3)) { engine.recentLogs.contains { $0.message.hasSuffix("reconnecting cameras") } },
                "reconnected while the network was still flapping")
        #expect(!flapping.isCancelled)
        flapping.cancel()
        await fixture.tearDown()
    }

    /// Audit A5: one camera that hangs in its reconnect held the engine's operations (allowlist, add and remove, pause) and every
    /// other camera's re-advertising. Each camera's reconnect has a deadline.
    @MainActor @Test(.timeLimit(.minutes(1))) func aCameraThatHangsInItsReconnectDoesNotBlockTheOthersOrTheEngine() async throws {
        let gate = Gate()
        let hung = EngineFixture.demoCamera(name: "Hung")
        let fine = EngineFixture.demoCamera(name: "Fine")
        var tuning = Self.tuning
        tuning.runtimeRefreshDeadline = .milliseconds(400)
        let hungID = hung.id
        tuning.beforeRuntimeRefresh = { id in
            if id == hungID { await gate.wait() }   // ignores cancellation, like a driver that never answers
        }
        let advertiser = CountingAdvertiser()
        let fixture = try await EngineFixture(tuning: tuning, advertiser: advertiser)
        let engine = fixture.engine
        try await engine.addCamera(hung, password: nil)
        try await engine.addCamera(fine, password: nil)
        await engine.start()
        #expect(await fixture.until(.seconds(10)) { advertiser.count("Hung") == 1 && advertiser.count("Fine") == 1 })

        fixture.networkChanges.fire()
        #expect(await fixture.waitFor(.seconds(10)) { engine.recentLogs.contains { $0.message.contains("Reconnecting Hung took longer") } })
        #expect(await fixture.until { advertiser.count("Fine") == 2 }, "the other camera was reconnected")
        #expect(advertiser.count("Hung") == 1)
        // The engine's operations are free again.
        let started = ContinuousClock.now
        await engine.setHomeKitAllowlist(nil, because: "a test")
        try await engine.updateSettings { $0.logLevel = .debug }
        #expect(ContinuousClock.now - started < .seconds(3))
        gate.open()
        await fixture.tearDown()
    }

    /// Audit network #6: a listener that is down waited out a backoff that doubles up to a minute, and a network change did not
    /// reset it. It listens again at the network change, not at the next retry (`HAPServerTimings.listenerRetryDelay`, 1 s).
    @MainActor @Test(.timeLimit(.minutes(1))) func aNetworkChangeBringsADownListenerBackAtOnce() async throws {
        let transport = ScriptedTransport()
        let fixture = try await EngineFixture(tuning: Self.tuning, transport: transport)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Porch")
        try await engine.addCamera(camera, password: nil)
        let port = try #require(engine.configurations.first?.hapPort)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.hapPort == port })

        // The listener stops on its own and the first retry fails; the next is a second away.
        transport.listenFailures.set([port: .failed("network is down")])
        let before = transport.listenAttempts.value[port] ?? 0
        let listener = try #require(transport.listeners.value[port])
        listener.fail()
        #expect(await fixture.until { (transport.listenAttempts.value[port] ?? 0) > before }, "the first retry came at once and failed")
        transport.listenFailures.set([:])
        let retried = transport.listenAttempts.value[port] ?? 0
        let changed = ContinuousClock.now
        fixture.networkChanges.fire()
        #expect(await fixture.until(.seconds(5)) { (transport.listenAttempts.value[port] ?? 0) > retried && fixture.status(camera.id)?.hapPort == port })
        #expect(ContinuousClock.now - changed < .milliseconds(900), "before the one-second retry would have")
        await fixture.tearDown()
    }

    /// Audit network #11: every path change re-registered all accessories at once (goodbye and probe packets race and a camera
    /// comes back renamed "Driveway (2)"). They are registered `advertisingStagger` apart.
    @MainActor @Test(.timeLimit(.minutes(1))) func camerasAreReRegisteredOneAfterAnotherAfterANetworkChange() async throws {
        var tuning = Self.tuning
        tuning.advertisingStagger = .milliseconds(400)
        let advertiser = TimedAdvertiser()
        let fixture = try await EngineFixture(tuning: tuning, advertiser: advertiser)
        let engine = fixture.engine
        let names = ["One", "Two", "Three"]
        for name in names { try await engine.addCamera(EngineFixture.demoCamera(name: name), password: nil) }
        await engine.start()
        #expect(await fixture.until(.seconds(10)) { names.allSatisfy { advertiser.times($0).count == 1 } })

        fixture.networkChanges.fire()
        #expect(await fixture.until(.seconds(10)) { names.allSatisfy { advertiser.times($0).count == 2 } })
        let second = names.map { advertiser.times($0)[1] }.sorted()
        #expect(second[1] - second[0] >= .milliseconds(300) && second[2] - second[1] >= .milliseconds(300), "registered apart: \(second)")
        await fixture.tearDown()
    }

    // MARK: - Wake

    /// Audit B4: nothing purged what a sleep left behind. A live view that was prepared and never started is ended at the wake
    /// (the camera is not left "in use"), and the sleep and the wake are in the log.
    @MainActor @Test(.timeLimit(.minutes(1))) func aWakeEndsAPreparedLiveViewAndLogsTheSleep() async throws {
        let fixture = try await EngineFixture(tuning: Self.tuning)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Yard")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.hapPort != nil })
        let status = try #require(fixture.status(camera.id))
        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        let ids = try await controller.cameraIDs()
        let receiver = try await SRTPTestReceiver.start(host: controller.localAddress, ipv6: controller.isIPv6)
        let request = ControllerTLV.SetupEndpointsRequest(sessionID: UUID(), controller: receiver.address, video: receiver.videoKeys, audio: receiver.audioKeys)
        let endpoints = try await controller.setupEndpoints(ids.streams[0], request)
        #expect(endpoints.isSuccess)
        #expect(try await controller.streamingStatus(ids.streams[0]) == .inUse)

        engine.systemWillSleep()
        await engine.systemDidWake()
        #expect(await fixture.waitFor { engine.recentLogs.contains { $0.message.hasPrefix("The Mac is going to sleep") } })
        #expect(await fixture.waitFor { engine.recentLogs.contains { $0.message.hasPrefix("The Mac woke up after") } })
        #expect(await fixture.until(.seconds(5)) { (try? await controller.streamingStatus(ids.streams[0])) == .available }, "the prepared view ended")
        #expect(await fixture.waitFor { engine.recentLogs.contains { $0.message.contains("after the wake") && $0.message.contains("never started") } })
        // The controller's connection survived a short sleep.
        #expect(try await controller.streamingStatus(ids.streams[1]) == .available)
        await receiver.stop()
        await controller.close()
        await fixture.tearDown()
    }

    // MARK: - Heartbeat

    /// Audit part D: an actor that stops answering was found by Home as "No Response" and by nothing else. Three missed
    /// heartbeats restart that camera only.
    @MainActor @Test(.timeLimit(.minutes(1))) func aRuntimeThatMissesThreeHeartbeatsIsRestartedAndTheOthersAreNot() async throws {
        let gate = Gate()
        let stuck = EngineFixture.demoCamera(name: "Stuck")
        let well = EngineFixture.demoCamera(name: "Well")
        var tuning = Self.tuning
        tuning.runtimeHeartbeatDeadline = .milliseconds(150)
        let stuckID = stuck.id
        tuning.runtimeHeartbeat = { id in
            if id == stuckID { await gate.wait() }
        }
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        try await engine.addCamera(stuck, password: nil)
        try await engine.addCamera(well, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(stuck.id)?.hapPort != nil && fixture.status(well.id)?.hapPort != nil })
        let before = try #require(engine.runtimes[stuck.id])
        let other = try #require(engine.runtimes[well.id])

        await engine.heartbeatRound()
        await engine.heartbeatRound()
        #expect(engine.runtimes[stuck.id] === before, "two misses are not enough")
        await engine.heartbeatRound()
        #expect(engine.runtimes[stuck.id] !== before, "restarted on the third")
        #expect(engine.runtimes[well.id] === other, "the camera that answers is left alone")
        #expect(engine.recentLogs.contains { $0.level == .error && $0.message.contains("Stuck did not answer 3 heartbeats in a row") })
        #expect(await fixture.waitFor { fixture.status(stuck.id)?.hapPort != nil && fixture.status(stuck.id)?.connection == .online })
        gate.open()
        await fixture.tearDown()
    }

    // MARK: - New install defaults

    private func power(hasBattery: Bool) -> RecordingPowerManager {
        let power = RecordingPowerManager()
        power.battery.set(hasBattery)
        return power
    }

    @MainActor private func engine(directory: TemporaryDirectory, power: RecordingPowerManager) -> BridgeEngine {
        var environment = BridgeEnvironment.testing(directory: directory.url)
        environment.platform.power = power
        return BridgeEngine(environment: environment, tuning: .testing)
    }

    /// Audit B3: Keep Mac Awake defaulted to off, so a Mac mini put to sleep by the energy settings took every camera offline
    /// in Home. A new installation on a Mac without a battery has it on; a laptop's stays off with a line in the log; a saved
    /// configuration is never touched.
    @MainActor @Test(.timeLimit(.minutes(1))) func keepMacAwakeDefaultsOnOnlyForNewInstallationsOnDesktopMacs() async throws {
        // New installation, desktop.
        let desktopDirectory = try TemporaryDirectory()
        defer { desktopDirectory.remove() }
        let desktopPower = power(hasBattery: false)
        let desktop = engine(directory: desktopDirectory, power: desktopPower)
        await desktop.start()
        #expect(desktop.settings.keepMacAwake)
        #expect(desktopPower.keepAwakeCalls.value == [true])
        #expect(try ConfigurationStore(directory: desktopDirectory.url).load()?.settings.keepMacAwake == true, "saved")
        #expect(desktop.recentLogs.contains { $0.message.contains("Keep Mac Awake is on for this new installation") })
        await desktop.stop()

        // The person turned it off: the next launch keeps their choice on the same desktop.
        var settings = desktop.settings
        settings.keepMacAwake = false
        try await desktop.updateSettings(settings)
        let again = engine(directory: desktopDirectory, power: self.power(hasBattery: false))
        await again.start()
        #expect(!again.settings.keepMacAwake, "an existing setting is never changed")
        await again.stop()

        // New installation, laptop: stays off, and the log says what that means.
        let laptopDirectory = try TemporaryDirectory()
        defer { laptopDirectory.remove() }
        let laptopPower = power(hasBattery: true)
        let laptop = engine(directory: laptopDirectory, power: laptopPower)
        await laptop.start()
        #expect(!laptop.settings.keepMacAwake)
        #expect(laptopPower.keepAwakeCalls.value == [false])
        #expect(await EngineFixtureLogs.waitFor(laptop) { $0.message.contains("Keep Mac Awake is off") && $0.message.contains("lid") })
        await laptop.stop()

        // A configuration file that cannot be read is no new installation either: what the person had chosen is unknown, and the
        // setting is not decided for them.
        let damagedDirectory = try TemporaryDirectory()
        defer { damagedDirectory.remove() }
        try Data("{ not json".utf8).write(to: ConfigurationStore(directory: damagedDirectory.url).fileURL)
        let damaged = engine(directory: damagedDirectory, power: power(hasBattery: false))
        await damaged.start()
        #expect(!damaged.settings.keepMacAwake, "a damaged configuration does not count as a new installation")
        await damaged.stop()

        // A saved configuration written before the setting existed: not a new installation, whatever the Mac is.
        let legacyDirectory = try TemporaryDirectory()
        defer { legacyDirectory.remove() }
        try Data(#"{"schemaVersion": \#(ConfigurationStore.currentSchemaVersion), "settings": {"basePort": 21100}, "cameras": []}"#.utf8)
            .write(to: ConfigurationStore(directory: legacyDirectory.url).fileURL)
        let legacy = engine(directory: legacyDirectory, power: power(hasBattery: false))
        await legacy.start()
        #expect(!legacy.settings.keepMacAwake, "an existing configuration without the key keeps the old default")
        await legacy.stop()
    }

    // MARK: - Allowlist log

    /// Audit A6 (e): every allowlist change is logged with its cause.
    @MainActor @Test(.timeLimit(.minutes(2))) func everyAllowlistChangeIsLoggedWithItsCause() async throws {
        let fixture = try await EngineFixture(tuning: Self.tuning)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Driveway")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.hapPort != nil })

        await engine.setHomeKitAllowlist([], because: "the camera was switched off for Home")
        #expect(engine.recentLogs.contains { $0.message == "HomeKit publishing is limited to 0 cameras (the camera was switched off for Home)" })
        #expect(await fixture.waitFor { engine.recentLogs.contains { $0.message == "Driveway is no longer published to HomeKit (the camera was switched off for Home)" } })
        await engine.setHomeKitAllowlist(nil, because: "the camera was switched back on for Home")
        #expect(engine.recentLogs.contains { $0.message == "HomeKit publishing is open to every camera (the camera was switched back on for Home)" })
        #expect(await fixture.waitFor(.seconds(20)) { engine.recentLogs.contains { $0.message == "Driveway is published to HomeKit (the camera was switched back on for Home)" } })
        await fixture.tearDown()
    }

    // MARK: - Accessory start failure

    /// Audit B6: a publish that failed (the Keychain refused, a listener failure) stopped the camera's whole runtime, ingest
    /// included. The camera keeps running; only the accessory is tried again.
    @MainActor @Test(.timeLimit(.minutes(1))) func aFailedAccessoryLeavesTheCamerasStreamRunningWhileItIsTriedAgain() async throws {
        let transport = ScriptedTransport()
        var tuning = Self.tuning
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
        })
        let runtime = try #require(engine.runtimes[camera.id], "the runtime stays")
        let running = await runtime.isRunning
        let published = await runtime.isPublished
        #expect(running && !published)
        #expect(await fixture.waitFor { (transport.listenAttempts.value[port] ?? 0) >= 3 }, "the accessory is tried again with backoff")
        #expect(await runtime.ingestAttempts.main == 1, "while the stream stays connected")
        #expect(await fixture.waitFor { fixture.status(camera.id)?.videoSummary != nil }, "and keeps delivering pictures")

        transport.listenFailures.set([:])
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online && fixture.status(camera.id)?.hapPort == port })
        #expect(engine.runtimes[camera.id] === runtime)
        #expect(await runtime.ingestAttempts.main == 1, "the stream was never reconnected")
        await fixture.tearDown()
    }

    // MARK: - Single instance

    /// Audit network #12: a second copy on the same configuration advertised the same cameras and took the next ports.
    @MainActor @Test(.timeLimit(.minutes(1))) func aSecondCopyOnTheSameConfigurationDoesNotStartTheBridge() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let lock = FakeInstanceLock()
        lock.held.set(true)
        var environment = BridgeEnvironment.testing(directory: directory.url)
        environment.platform.instanceLock = lock
        let engine = BridgeEngine(environment: environment, tuning: .testing)
        await engine.start()
        #expect(engine.state == .failed("Camera Bridge is already running with this configuration."))
        #expect(engine.runtimes.isEmpty && engine.bridge == nil)
        #expect(await EngineFixtureLogs.waitFor(engine) { $0.level == .error && $0.message.contains("already running") })

        // The other copy quit: starting works, and stopping releases the lock again.
        lock.held.set(false)
        await engine.start()
        #expect(engine.state == .running)
        await engine.stop()
        #expect(lock.releases.value >= 1)
    }
}

/// Polls `engine.recentLogs` (the status loop publishes it).
@MainActor
enum EngineFixtureLogs {
    static func waitFor(_ engine: BridgeEngine, timeout: Duration = .seconds(10), _ matches: @MainActor (LogEntry) -> Bool) async -> Bool {
        await eventually(timeout: timeout, every: .milliseconds(20)) { engine.recentLogs.contains(where: matches) }
    }
}
#endif
