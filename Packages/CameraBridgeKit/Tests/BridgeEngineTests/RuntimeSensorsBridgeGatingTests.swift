#if canImport(Darwin)
import BridgeSupport
import Foundation
import Testing
@testable import BridgeEngine

/// The sensors bridge runs (and advertises) only while at least one camera is configured (plan W3-3): a fresh install
/// publishes nothing on the LAN until the person adds a camera. Advertisements go to `CountingAdvertiser` (never DNS-SD).
@Suite(.serialized) struct RuntimeSensorsBridgeGatingTests {
    @MainActor @Test(.timeLimit(.minutes(1))) func nothingIsAdvertisedUntilTheFirstCameraIsAdded() async throws {
        let advertiser = CountingAdvertiser()
        let fixture = try await EngineFixture(advertiser: advertiser)
        let engine = fixture.engine

        await engine.start()
        #expect(engine.state == .running)
        #expect(await fixture.waitFor { engine.recentLogs.contains { $0.message == "Bridge running with 0 cameras" } })
        #expect(engine.bridge == nil && engine.sensorsBridge == nil)
        // Pausing, resuming and moving the bridge's port start nothing either.
        await engine.pause()
        await engine.resume()
        var settings = engine.settings
        settings.sensorsBridgePort = UInt16.random(in: 28_001...28_999)
        try await engine.updateSettings(settings)
        settings.sensorsBridgePort = 0
        try await engine.updateSettings(settings)
        await engine.systemDidWake()
        #expect(engine.state == .running && engine.bridge == nil && engine.sensorsBridge == nil)
        #expect(advertiser.names.value.isEmpty, "a bridge without cameras publishes nothing")

        // The first camera starts the bridge (and the camera's own accessory).
        let camera = EngineFixture.demoCamera(name: "Porch")
        try await engine.addCamera(camera, password: nil)
        #expect(engine.bridge != nil)
        #expect(engine.sensorsBridge?.setupURI.hasPrefix("X-HM://") == true)
        #expect(await fixture.until { advertiser.count(SensorsBridge.bonjourServiceName) == 1 && advertiser.count("Porch") == 1 })

        // Removing the last camera stops it; nothing comes back without cameras.
        await engine.removeCamera(id: camera.id)
        #expect(engine.bridge == nil && engine.sensorsBridge == nil)
        await engine.pause()
        await engine.resume()
        #expect(engine.bridge == nil && engine.sensorsBridge == nil)
        #expect(advertiser.count(SensorsBridge.bonjourServiceName) == 1)
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func aCameraAddedWhilePausedStartsTheBridgeOnResume() async throws {
        let advertiser = CountingAdvertiser()
        let fixture = try await EngineFixture(advertiser: advertiser)
        let engine = fixture.engine
        await engine.start()
        await engine.pause()

        var camera = EngineFixture.demoCamera(name: "Shed")
        camera.isEnabled = false
        try await engine.addCamera(camera, password: nil)
        #expect(engine.bridge == nil && advertiser.names.value.isEmpty, "a paused bridge starts nothing")

        // A configured camera (even a disabled one, whose sensors show as unreachable) keeps the bridge running.
        await engine.resume()
        #expect(engine.state == .running && engine.bridge != nil && engine.sensorsBridge != nil)
        #expect(await fixture.until { advertiser.count(SensorsBridge.bonjourServiceName) == 1 })
        #expect(advertiser.count("Shed") == 0, "a disabled camera has no accessory")
        await fixture.tearDown()
    }
}
#endif
