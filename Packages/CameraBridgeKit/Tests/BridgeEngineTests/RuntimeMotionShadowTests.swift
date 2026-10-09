import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import MediaCore
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// The setting itself: off by default, saved in config.json, tolerant of older files.
@Suite struct MotionShadowSettingTests {
    @Test func theTestIsOffByDefaultAndRoundTrips() throws {
        #expect(BridgeSettings().motionShadowTest == false)
        var settings = BridgeSettings()
        settings.motionShadowTest = true
        let decoded = try JSONDecoder().decode(BridgeSettings.self, from: try JSONEncoder().encode(settings))
        #expect(decoded.motionShadowTest)
        #expect(decoded == settings)
    }

    @Test func aConfigurationWrittenBeforeTheTestExistedReadsAsOff() throws {
        let old = Data(#"{"webhookEnabled": false, "keepMacAwake": true, "basePort": 21100}"#.utf8)
        let settings = try JSONDecoder().decode(BridgeSettings.self, from: old)
        #expect(!settings.motionShadowTest && settings.keepMacAwake)
        // An unreadable value falls back to off like every other setting.
        let broken = Data(#"{"motionShadowTest": "yes"}"#.utf8)
        #expect(try JSONDecoder().decode(BridgeSettings.self, from: broken).motionShadowTest == false)
    }

    @Test func theDiagnosticsReportShowsTheSettingAndEachCamerasNumbers() {
        var configuration = CameraConfiguration(name: "Patio", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "192.0.2.44"), username: "")
        configuration.motionSensitivity = 0.7
        var status = CameraStatus(id: configuration.id, name: "Patio", kind: .camera, vendor: .onvif, connection: .online)
        status.motionShadow = MotionShadowStatus(
            state: .comparing, sensitivity: 0.7, enabledSince: Date(timeIntervalSince1970: 1_789_990_000),
            last24Hours: MotionShadowTotals(both: 5, cameraOnly: 1, builtInOnly: 2, medianDelaySeconds: 0.9),
            sinceEnabled: MotionShadowTotals(both: 6, cameraOnly: 1, builtInOnly: 2, medianDelaySeconds: 1.2), eventInProgress: true)
        var settings = BridgeSettings()
        settings.motionShadowTest = true
        let context = DiagnosticsContext(appVersion: "1.0", appBuild: "7", macOSVersion: "27", macModel: "Mac15,3", architecture: "arm64",
                                         systemUptime: 10, processUptime: 10, generated: Date(timeIntervalSince1970: 1_790_000_000), locale: "en_US")
        let text = DiagnosticsReport.render(context: context, state: .running, localNetwork: .granted, settings: settings, cameras: [status],
                                            configurations: [configuration], sessions: [], logEntries: [])
        #expect(text.contains("motion shadow test on"))
        #expect(text.contains("Motion shadow test: comparing, sensitivity 0.70"))
        #expect(text.contains("an event is being compared now"))
        #expect(text.contains("Last 24 h: 5 both, 1 camera only, 2 built-in only; median delay 0.9 s later"))
        #expect(text.contains("Since enabled: 6 both, 1 camera only, 2 built-in only; median delay 1.2 s later"))

        status.motionShadow = MotionShadowStatus(state: .paused("The camera has no sub stream"), sensitivity: 0.5, enabledSince: Date())
        let paused = DiagnosticsReport.render(context: context, state: .running, localNetwork: .granted, settings: settings, cameras: [status],
                                              configurations: [configuration], sessions: [], logEntries: [])
        #expect(paused.contains("Motion shadow test: paused (The camera has no sub stream)"))
        status.motionShadow = nil
        let off = DiagnosticsReport.render(context: context, state: .running, localNetwork: .granted, settings: BridgeSettings(), cameras: [status],
                                           configurations: [configuration], sessions: [], logEntries: [])
        #expect(off.contains("motion shadow test off") && !off.contains("Motion shadow test:"))
    }
}

#if canImport(Darwin)
import PlatformApple

/// The shadow test inside the engine: built-in motion detection runs on the sub stream next to a camera's own events, its
/// transitions reach only the test's recorder (never the router, HomeKit motion or a recording), and the setting starts
/// and stops it.
@Suite(.serialized) struct RuntimeMotionShadowTests {
    static let log = Log(category: "MotionShadowTest")

    @MainActor private static func cameraEventsCamera(_ name: String, sensitivity: Double = 1) -> CameraConfiguration {
        var camera = EngineFixture.demoCamera(name: name)
        camera.motionSource = .cameraEvents
        camera.motionSensitivity = sensitivity
        return camera
    }

    private static func tuning(_ driver: ScriptedEventDriver) -> EngineTuning {
        var tuning = EngineTuning.testing
        tuning.driverFactory = { _, _, _ in driver }
        tuning.subStreamIdleStop = .milliseconds(300)
        return tuning
    }

    // MARK: The monitor

    /// The shadow monitor is the built-in detector with a different destination. It holds no router, so what it detects can
    /// only go to its closure: not to the camera's motion, and so not to HomeKit or a recording.
    @Test(.timeLimit(.minutes(1))) func aShadowMonitorReportsOnlyToItsClosureNeverToTheRouter() async throws {
        let hub = MediaHub()
        let router = EventRouter()
        var camera = CameraConfiguration(name: "Yard", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.5"), username: "")
        camera.motionSource = .cameraEvents
        await router.register(camera)
        let routerOutputs = Box<[EventRouterOutput]>([])
        await router.setOutputHandler { output in routerOutputs.update { $0.append(output) } }
        let transitions = Box<[Bool]>([])
        let monitor = SoftMotionMonitor(hub: hub, codecs: RuntimeSoftMotionTests.SlowBandCodecs(slowIndex: -1, delay: .zero), sensitivity: 1,
                                        shadow: { active in transitions.update { $0.append(active) } }, cameraID: camera.id, log: Self.log)
        await monitor.start()
        var index = 0
        while transitions.value.isEmpty, index < 40 {   // the band moves: the built-in detector sees motion
            await hub.ingest(RuntimeSoftMotionTests.bandKeyframe(index))
            index += 1
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(transitions.value == [true], "the detector saw motion")
        #expect(await router.state(for: camera.id)?.motion == false, "the camera's motion is untouched")
        await monitor.stop()
        #expect(transitions.value == [true, false], "stopping ends the built-in period")
        let state = try #require(await router.state(for: camera.id))
        #expect(!state.motion && state.lastEvent == nil)
        #expect(routerOutputs.value.allSatisfy { if case .motion = $0 { false } else { true } }, "no motion output reached the router: \(routerOutputs.value)")
    }

    /// Pictures that stop while a built-in period is open end it (the detector releases motion only from new pictures).
    @Test(.timeLimit(.minutes(1))) func aShadowMonitorEndsItsPeriodWhenThePicturesStop() async throws {
        let hub = MediaHub()
        let transitions = Box<[Bool]>([])
        let monitor = SoftMotionMonitor(hub: hub, codecs: RuntimeSoftMotionTests.SlowBandCodecs(slowIndex: -1, delay: .zero), sensitivity: 1,
                                        shadow: { active in transitions.update { $0.append(active) } }, cameraID: UUID(), log: Self.log)
        await monitor.start()
        var index = 0
        while transitions.value.isEmpty, index < 40 {
            await hub.ingest(RuntimeSoftMotionTests.bandKeyframe(index))
            index += 1
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(transitions.value == [true])
        #expect(await eventually(timeout: SoftMotionMonitor.stallTimeout + .seconds(4)) { transitions.value == [true, false] })
        await monitor.stop()
        #expect(transitions.value == [true, false], "nothing is reported twice")
    }

    // MARK: The runtime

    /// Owner request: measure the built-in detector on a real camera without changing anything about how motion reaches Apple
    /// Home. With the test on, the demo camera's built-in detector sees its moving picture on the SUB stream, and still the
    /// camera is not in motion — not in the status, not on the router, not on the HomeKit accessory.
    @MainActor @Test(.timeLimit(.minutes(3))) func theBuiltInDetectorNeverMovesHomeKitMotionAndTheCameraEventsAreCompared() async throws {
        let driver = ScriptedEventDriver()
        let fixture = try await EngineFixture(tuning: Self.tuning(driver)) { $0.motionShadowTest = true }
        let engine = fixture.engine
        let camera = Self.cameraEventsCamera("Shadow Patio")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online && fixture.status(camera.id)?.hapPort != nil })
        #expect(await fixture.until(.seconds(10)) { await runtime.isMotionShadowRunning }, "the test starts with the camera")
        #expect(await runtime.isSubStreamRunning, "on the sub stream")
        #expect(await !runtime.isSoftMotionRunning, "the camera's motion is still its own events")

        #expect(await fixture.waitFor(.seconds(30)) { fixture.status(camera.id)?.motionShadow?.eventInProgress == true },
                "the built-in detector saw the moving picture")
        let shadow = try #require(fixture.status(camera.id)?.motionShadow)
        #expect(shadow.state == .comparing && shadow.sensitivity == 1)
        #expect(fixture.status(camera.id)?.motionActive == false, "the camera is not in motion")
        #expect(await engine.router.state(for: camera.id)?.motion == false)
        let status = try #require(fixture.status(camera.id))
        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        let ids = try await controller.cameraIDs()
        #expect(try await controller.readValue(try #require(ids.motionDetected)).hapBool == false, "HomeKit's MotionDetected stays off")
        await controller.close()

        // The camera's own event arrives next to the built-in period: one event both saw (the line is written when the test ends).
        driver.emit(.motion(true))
        #expect(await fixture.waitFor { fixture.status(camera.id)?.motionActive == true }, "the camera's own motion still reaches the router")
        driver.emit(.motion(false))
        try await engine.updateSettings { $0.motionShadowTest = false }
        #expect(await fixture.waitFor { engine.recentLogs.contains { $0.message.hasPrefix("Motion shadow test: Shadow Patio: both detected; built-in ") } },
                "the camera's period was copied to the test: \(engine.recentLogs.filter { $0.message.hasPrefix("Motion shadow test") }.map(\.message))")
        #expect(!engine.recentLogs.contains { $0.message.contains("Motion shadow test: Shadow Patio: built-in only") })
        await fixture.tearDown()
    }

    /// Toggling starts and stops the detector, holds the sub stream only while it runs, and the setting is saved.
    @MainActor @Test(.timeLimit(.minutes(2))) func togglingTheSettingStartsAndStopsTheDetector() async throws {
        let driver = ScriptedEventDriver()
        let fixture = try await EngineFixture(tuning: Self.tuning(driver))
        let engine = fixture.engine
        let camera = Self.cameraEventsCamera("Toggle Porch")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let runtime = try #require(engine.runtimes[camera.id])
        let runningAtFirst = await runtime.isMotionShadowRunning
        #expect(!runningAtFirst && fixture.status(camera.id)?.motionShadow == nil, "off by default")
        #expect(await fixture.until(.seconds(10)) { await !runtime.isSubStreamRunning }, "no sub stream for nobody")

        try await engine.updateSettings { $0.motionShadowTest = true }
        #expect(await fixture.until(.seconds(10)) { await runtime.isMotionShadowRunning })
        #expect(await runtime.isSubStreamRunning)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.motionShadow?.state == .comparing })
        #expect(await !runtime.isSoftMotionRunning)
        #expect(BridgeEngine(environment: .testing(directory: fixture.directory.url)).settings.motionShadowTest, "saved in config.json")

        // Changing the camera's sensitivity restarts only the detector, which then uses it.
        var changed = camera
        changed.motionSensitivity = 0.4
        try await engine.updateCamera(changed, password: nil)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.motionShadow?.sensitivity == 0.4 })
        #expect(await runtime.isMotionShadowRunning)

        try await engine.updateSettings { $0.motionShadowTest = false }
        #expect(await fixture.until { await !runtime.isMotionShadowRunning })
        #expect(await fixture.waitFor { fixture.status(camera.id)?.motionShadow == nil })
        #expect(await fixture.until(.seconds(10)) { await !runtime.isSubStreamRunning }, "the sub stream is let go again")
        #expect(!BridgeEngine(environment: .testing(directory: fixture.directory.url)).settings.motionShadowTest)

        try await engine.updateSettings { $0.motionShadowTest = true }
        #expect(await fixture.until(.seconds(10)) { await runtime.isMotionShadowRunning }, "and on again")
        await fixture.tearDown()
    }

    /// Pausing the bridge stops the detector and gives the sub stream back; resuming starts it again (the setting stays on).
    @MainActor @Test(.timeLimit(.minutes(2))) func theDetectorStopsWithTheCameraAndComesBackWithIt() async throws {
        let driver = ScriptedEventDriver()
        let fixture = try await EngineFixture(tuning: Self.tuning(driver)) { $0.motionShadowTest = true }
        let engine = fixture.engine
        let camera = Self.cameraEventsCamera("Pause Gate")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        let first = try #require(engine.runtimes[camera.id])
        #expect(await fixture.until(.seconds(10)) { await first.isMotionShadowRunning })
        await engine.pause()
        #expect(await !first.isMotionShadowRunning)
        #expect(await !first.isSubStreamRunning)
        await engine.resume()
        let second = try #require(engine.runtimes[camera.id])
        #expect(await fixture.until(.seconds(10)) { await second.isMotionShadowRunning })
        await fixture.tearDown()
    }

    /// A camera without a sub stream is skipped, once in the log: the main stream is never decoded for the test.
    @MainActor @Test(.timeLimit(.minutes(2))) func aCameraWithoutASubStreamIsSkippedAndLoggedOnce() async throws {
        let server = try await RuntimeCameraLifecycleTests.fourByThreeServer()
        let driver = ScriptedEventDriver()
        let fixture = try await EngineFixture(tuning: Self.tuning(driver)) { $0.motionShadowTest = true }
        let engine = fixture.engine
        var camera = RuntimeCameraLifecycleTests.rtspCamera("Single Stream Yard", server: server)
        camera.motionSource = .cameraEvents
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        #expect(await fixture.waitFor {
            fixture.status(camera.id)?.motionShadow?.state == .paused("The camera has no sub stream")
        }, "\(String(describing: fixture.status(camera.id)?.motionShadow))")
        try await Task.sleep(for: .milliseconds(600))
        let skipped = engine.recentLogs.filter { $0.cameraID == camera.id && $0.message.contains("skipped, the camera has no sub stream") }
        #expect(skipped.count == 1, "logged once: \(skipped.map(\.message))")
        #expect(skipped.first?.level == .info && skipped.first?.message.hasPrefix("Motion shadow test: Single Stream Yard: skipped") == true)
        let shadowRuns = await runtime.isMotionShadowRunning, softRuns = await runtime.isSoftMotionRunning
        #expect(!shadowRuns && !softRuns, "nothing decodes the main stream")
        #expect(fixture.status(camera.id)?.motionShadow?.last24Hours.events == 0)
        await fixture.tearDown()
        await server.stop()
    }

    /// The test compares a camera's own events with the built-in detector: it does not apply to a camera whose motion comes from
    /// the built-in detector or a webhook.
    @MainActor @Test(.timeLimit(.minutes(2))) func theTestAppliesOnlyToCamerasWithTheirOwnMotionEvents() async throws {
        let driver = ScriptedEventDriver()
        let fixture = try await EngineFixture(tuning: Self.tuning(driver)) { $0.motionShadowTest = true }
        let engine = fixture.engine
        var builtIn = EngineFixture.demoCamera(name: "Built-in Hall")
        builtIn.motionSource = .softMotion
        var webhook = EngineFixture.demoCamera(name: "Webhook Hall")
        webhook.motionSource = .webhook
        try await engine.addCamera(builtIn, password: nil)
        try await engine.addCamera(webhook, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(builtIn.id)?.connection == .online && fixture.status(webhook.id)?.connection == .online })
        let builtInRuntime = try #require(engine.runtimes[builtIn.id])
        let webhookRuntime = try #require(engine.runtimes[webhook.id])
        #expect(await fixture.until { await builtInRuntime.isSoftMotionRunning })
        let builtInShadow = await builtInRuntime.isMotionShadowRunning, webhookShadow = await webhookRuntime.isMotionShadowRunning
        #expect(!builtInShadow && !webhookShadow)
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.status(builtIn.id)?.motionShadow == nil && fixture.status(webhook.id)?.motionShadow == nil)
        await fixture.tearDown()
    }

    /// When the camera's events are unreliable the built-in detector is the camera's motion; a second one would only repeat it.
    @MainActor @Test(.timeLimit(.minutes(2))) func theTestStepsAsideWhenBuiltInDetectionTakesOver() async throws {
        let driver = ScriptedEventDriver()
        let fixture = try await EngineFixture(tuning: Self.tuning(driver)) { $0.motionShadowTest = true }
        let engine = fixture.engine
        let camera = Self.cameraEventsCamera("Unreliable Deck")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(await fixture.until(.seconds(10)) { await runtime.isMotionShadowRunning })
        driver.emit(.eventChannelUnreliable(shortSessions: 5))
        #expect(await fixture.until { await runtime.isSoftMotionRunning }, "built-in motion detection takes over")
        #expect(await fixture.until { await !runtime.isMotionShadowRunning })
        #expect(await fixture.waitFor {
            fixture.status(camera.id)?.motionShadow?.state == .paused("Built-in motion detection is already in use for this camera")
        })
        await fixture.tearDown()
    }
}
#endif
