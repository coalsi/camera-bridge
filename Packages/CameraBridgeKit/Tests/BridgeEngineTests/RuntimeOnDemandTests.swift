import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

#if canImport(Darwin)
import PlatformApple

/// A camera that streams on demand (`CameraDriver.streamsOnDemand`, a battery camera): its main stream wakes once at the start, then only for
/// a viewer, a recording or a motion event, and sleeps again `onDemandIdleStop` after the last of them; built-in motion detection never runs.
@Suite(.serialized) struct RuntimeOnDemandTests {
    @MainActor @Test(.timeLimit(.minutes(2))) func anOnDemandCameraWakesForAViewerAndMotionAndSleepsWhenIdle() async throws {
        var tuning = EngineTuning.testing
        tuning.onDemandIdleStop = .milliseconds(600)
        tuning.onDemandWakeWait = .seconds(15)
        let driver = ScriptedEventDriver(streamsOnDemand: true)
        tuning.driverFactory = { _, _, _ in driver }
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        try await server.start()
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        var camera = RuntimeCameraLifecycleTests.rtspCamera("Solo", server: server)
        camera.motionSource = .cameraEvents
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor(.seconds(10)) { driver.sourcesMade.value > 0 })
        driver.emit(.eventChannel(connected: true))   // as eufy's event source says at once
        let runtime = try #require(engine.runtimes[camera.id])

        // Woken at the start (it comes online and shows its picture size), then left to sleep.
        #expect(await fixture.waitFor(.seconds(10)) { fixture.status(camera.id)?.connection == .online }, "\(String(describing: fixture.status(camera.id)?.connection))")
        #expect(await fixture.until(.seconds(5)) { !(await runtime.isMainStreamRunning) }, "sleeps once unused")
        #expect(fixture.status(camera.id)?.connection == .online, "asleep is not offline")
        #expect(!(await runtime.isSoftMotionRunning))

        // A viewer wakes it and gets a fresh picture; it sleeps again after the viewer leaves.
        let lease = await runtime.lease(preferSub: true)
        #expect(!lease.isSubStream && lease.hub === runtime.hub)
        #expect(await runtime.isMainStreamRunning)
        #expect(await runtime.hub.videoFormat?.width == 320)
        try await Task.sleep(for: tuning.onDemandIdleStop * 2)
        #expect(await runtime.isMainStreamRunning, "held while the viewer watches")
        await lease.release()
        #expect(await fixture.until(.seconds(5)) { !(await runtime.isMainStreamRunning) })

        // Motion wakes it and holds it while the event lasts; the router hears of it once the picture flows.
        driver.emit(.motion(true))
        #expect(await fixture.until(.seconds(5)) { await runtime.isMainStreamRunning })
        #expect(await fixture.waitFor(.seconds(5)) { fixture.status(camera.id)?.motionActive == true })
        try await Task.sleep(for: tuning.onDemandIdleStop * 2)
        #expect(await runtime.isMainStreamRunning, "held while the motion lasts")
        driver.emit(.motion(false))
        #expect(await fixture.until(.seconds(5)) { !(await runtime.isMainStreamRunning) })

        await fixture.tearDown()
        await server.stop()
    }
}
#endif
