#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

/// Record and Record sound on a running camera (the demo camera on loopback): applied in place, never a restart.
@Suite(.serialized) struct NVRRunningEngineTests {
    @MainActor @Test(.timeLimit(.minutes(2))) func togglingRecordAndRecordSoundLeavesTheCameraRunning() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Garage")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let runtime = try #require(engine.runtimes[camera.id])
        let attempts = await runtime.ingestAttempts
        #expect(attempts.main != nil)

        try await engine.setNVR(cameraID: camera.id, enabled: true)
        #expect(engine.runtimes[camera.id] === runtime, "Record on does not restart the camera")
        #expect(await fixture.waitFor { fixture.status(camera.id)?.nvr.state == .paused(.noFolder) })
        try await engine.setNVR(cameraID: camera.id, recordSound: true)
        try await engine.setNVR(cameraID: camera.id, recordSound: false)
        try await engine.setNVR(cameraID: camera.id, enabled: false)
        #expect(engine.runtimes[camera.id] === runtime, "neither does the sound switch, nor Record off")
        let after = await runtime.ingestAttempts
        #expect(after.main == attempts.main && after.sub == attempts.sub, "the ingest never reconnected")
        #expect(fixture.status(camera.id)?.nvr.state == .off)

        // An edit of another setting still restarts the camera when it should: the mask hides only the NVR fields.
        var edited = try #require(engine.configurations.first)
        edited.audioEnabled.toggle()
        try await engine.updateCamera(edited, password: nil)
        #expect(engine.runtimes[camera.id] !== runtime)
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func startAndStopWithRecordOnReturnPromptly() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        var camera = EngineFixture.demoCamera(name: "Garage")
        camera.nvrEnabled = true
        try await engine.addCamera(camera, password: nil)
        let started = ContinuousClock.now
        await engine.start()
        #expect(ContinuousClock.now - started < .seconds(30), "nothing archive-related delays engine.start()")
        #expect(engine.state == .running)
        let stopped = ContinuousClock.now
        await engine.stop()
        #expect(ContinuousClock.now - stopped < .seconds(10))
        fixture.directory.remove()
    }
}
#endif
