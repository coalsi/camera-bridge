import BridgeSupport
import CameraAdapters
import Foundation
import HAP
import HAPCore
import Testing
import TestSupport
@testable import BridgeEngine

/// `BridgeEngine.homeKitAllowlist`: which cameras may be published to HomeKit. A camera outside it runs for the app's own
/// viewers but advertises nothing; moving a camera in or out of the set publishes or unpublishes it while it runs, and the
/// camera comes back as the same accessory (same device ID, setup code and pairing).
@Suite(.serialized) struct HomeKitAllowlistTests {
    @MainActor @Test(.timeLimit(.minutes(2))) func onlyTheAllowedCameraIsPublishedAndTheOthersStillRunForTheApp() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        var first = EngineFixture.demoCamera(name: "Front")
        var second = EngineFixture.demoCamera(name: "Back")
        first.sensors.person = true
        second.sensors.person = true
        try await engine.addCamera(first, password: nil)
        try await engine.addCamera(second, password: nil)
        await engine.setHomeKitAllowlist([first.id])   // before the start: a held-back camera never advertises, not even briefly
        #expect(engine.homeKitAllowlist == [first.id])

        await engine.start()
        #expect(await fixture.waitFor { fixture.status(first.id)?.hapPort != nil && fixture.status(second.id)?.connection == .online })
        #expect(fixture.status(second.id)?.hapPort == nil, "the held-back camera has no accessory")
        #expect(await engine.runtimes[second.id]?.isPublished == false)
        #expect(await engine.runtimes[first.id]?.isPublished == true)

        // It still runs for the app: a picture, a stream summary, an event.
        #expect(await fixture.waitFor { fixture.status(second.id)?.videoSummary?.hasPrefix("H.264") == true })
        let jpeg = try #require(await engine.snapshot(cameraID: second.id))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
        await engine.triggerTestMotion(cameraID: second.id)
        #expect(await fixture.waitFor { fixture.status(second.id)?.motionActive == true })

        // Its code and pairing state are still the stored ones (the app says why it is not offered).
        #expect(await fixture.waitFor { fixture.status(second.id)?.setupURI.hasPrefix("X-HM://") == true })
        #expect(fixture.status(second.id)?.isPaired == false)

        // The sensors bridge publishes the allowed camera's sensors only.
        let published = try #require(engine.sensorsBridge?.publishedSensors)
        #expect(published[first.id]?.isEmpty == false)
        #expect(published[second.id] == nil, "a held-back camera's sensors are not bridged")
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(3))) func theAllowlistPublishesAndUnpublishesWithoutChangingThePairing() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        var camera = EngineFixture.demoCamera(name: "Driveway")
        camera.sensors.person = true
        let other = EngineFixture.demoCamera(name: "Garage")
        try await engine.addCamera(camera, password: nil)
        try await engine.addCamera(other, password: nil)
        await engine.start()   // no allowlist: everything is published
        #expect(await fixture.waitFor { fixture.status(camera.id)?.hapPort != nil && fixture.status(other.id)?.hapPort != nil })
        let status = try #require(fixture.status(camera.id))
        let port = try #require(status.hapPort)
        let setupCode = status.setupCode

        // Pair with Home (a test controller), and note the accessory's identity.
        let controller = try await HAPTestController.paired(port: port, setupCode: setupCode)
        let server = try #require(await engine.runtimes[camera.id]?.server)
        let deviceID = try await server.deviceID
        #expect(await fixture.waitFor { fixture.status(camera.id)?.isPaired == true })
        #expect(engine.sensorsBridge?.publishedSensors[camera.id]?.isEmpty == false)

        // Remove it from the allowlist: the accessory goes down, the camera keeps running, nothing about it changes.
        await engine.setHomeKitAllowlist([other.id])
        #expect(await fixture.waitFor { fixture.status(camera.id)?.hapPort == nil })
        #expect(await engine.runtimes[camera.id]?.isPublished == false)
        #expect(fixture.status(camera.id)?.connection == .online, "the camera itself keeps running")
        #expect(fixture.status(camera.id)?.setupCode == setupCode, "same setup code")
        #expect(fixture.status(camera.id)?.isPaired == true, "still paired in Home (which shows it as not responding)")
        #expect(fixture.status(other.id)?.hapPort != nil, "the other camera is untouched")
        await #expect(throws: (any Error).self) { _ = try await controller.reconnect() }   // nothing listens
        #expect(engine.sensorsBridge?.publishedSensors[camera.id] == nil)
        #expect(await fixture.until { await engine.runtimes[camera.id]?.hub.videoFormat != nil }, "ingest runs while unpublished")

        // Back in the allowlist: published again, as the same accessory the controller is paired with.
        await engine.setHomeKitAllowlist([camera.id, other.id])
        #expect(await fixture.waitFor { fixture.status(camera.id)?.hapPort != nil })
        #expect(fixture.status(camera.id)?.setupCode == setupCode)
        let again = try await controller.reconnect()
        try await again.pairVerify()   // the pairing made before is still accepted: the identity did not change
        let republished = try #require(await engine.runtimes[camera.id]?.server)
        #expect(try await republished.deviceID == deviceID)
        #expect(engine.sensorsBridge?.publishedSensors[camera.id]?.isEmpty == false, "its sensors are bridged again")
        await again.close()

        // Nil: every camera. Setting the same value again changes nothing.
        await engine.setHomeKitAllowlist(nil)
        await engine.setHomeKitAllowlist(nil)
        #expect(engine.homeKitAllowlist == nil)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.hapPort != nil && fixture.status(other.id)?.hapPort != nil })
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func aCameraAddedOutsideTheAllowlistStartsUnpublishedAndAnAllowedOneIsPublished() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let first = EngineFixture.demoCamera(name: "One")
        let second = EngineFixture.demoCamera(name: "Two")
        await engine.setHomeKitAllowlist([first.id])
        await engine.start()
        try await engine.addCamera(first, password: nil)
        try await engine.addCamera(second, password: nil)
        #expect(await fixture.waitFor { fixture.status(first.id)?.hapPort != nil && fixture.status(second.id)?.connection == .online })
        #expect(fixture.status(second.id)?.hapPort == nil, "a camera added while limited stays out of Home")

        // The rule changes to cover it: no restart, the ingest the app is watching is the one that publishes.
        let runtime = try #require(engine.runtimes[second.id])
        await engine.setHomeKitAllowlist([first.id, second.id])
        #expect(await fixture.waitFor { fixture.status(second.id)?.hapPort != nil })
        #expect(engine.runtimes[second.id] === runtime, "the camera's runtime was not restarted")
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func theAllowlistAppliesAtTheNextStartWhilePaused() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let first = EngineFixture.demoCamera(name: "One")
        let second = EngineFixture.demoCamera(name: "Two")
        try await engine.addCamera(first, password: nil)
        try await engine.addCamera(second, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(first.id)?.hapPort != nil && fixture.status(second.id)?.hapPort != nil })
        await engine.pause()
        await engine.setHomeKitAllowlist([second.id])
        await engine.resume()
        #expect(await fixture.waitFor { fixture.status(second.id)?.hapPort != nil && fixture.status(first.id)?.connection == .online })
        #expect(fixture.status(first.id)?.hapPort == nil)
        await fixture.tearDown()
    }
}
