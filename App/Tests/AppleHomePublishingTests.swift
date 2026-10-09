import BridgeEngine
import CameraAdapters
import Foundation
import Testing

/// Camera Bridge is free: nothing limits how many cameras are published to Apple Home.
@MainActor @Suite(.timeLimit(.minutes(2))) struct AppleHomePublishingTests {
    private static func demoCamera(_ name: String) -> CameraConfiguration {
        CameraConfiguration(name: name, kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "")
    }

    @Test func everyCameraIsPublishedWithNoLimit() async throws {
        let cameras = (1...4).map { Self.demoCamera("Camera \($0)") }
        let fixture = try await LiveEngineFixture.withCameras(cameras, onboardingCompleted: true)
        let engine = fixture.engine

        #expect(engine.homeKitAllowlist == nil, "the app never limits what is published")
        await engine.start()
        await eventually(timeout: .seconds(30)) { cameras.allSatisfy { camera in engine.cameras.first { $0.id == camera.id }?.hapPort != nil } }
        for camera in cameras {
            #expect(engine.cameras.first { $0.id == camera.id }?.hapPort != nil, "\(camera.name) has its accessory")
        }
        #expect(engine.homeKitAllowlist == nil)
        #expect(cameras.allSatisfy { fixture.model.pairingBlocker(for: $0.id) == nil }, "no camera is held back from showing its code")
        await fixture.tearDown()
    }

    @Test func aCameraAddedLaterIsPublishedToo() async throws {
        let first = Self.demoCamera("Front")
        let fixture = try await LiveEngineFixture.withCameras([first], onboardingCompleted: true)
        let engine = fixture.engine
        await engine.start()
        let second = Self.demoCamera("Back")
        try await fixture.model.addCamera(second, password: nil)
        await eventually(timeout: .seconds(30)) { engine.cameras.first { $0.id == second.id }?.hapPort != nil }
        #expect(engine.cameras.first { $0.id == second.id }?.hapPort != nil)
        #expect(engine.homeKitAllowlist == nil)
        await fixture.tearDown()
    }
}
