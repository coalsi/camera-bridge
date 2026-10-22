#if canImport(Darwin)
import BridgeSupport
import Foundation
import HAPCamera
import ImageIO
import MediaCore
import PlatformApple
import Synchronization
import Testing
import TestSupport
@testable import BridgeEngine

/// A camera that is turned off stays in Apple Home with a "Camera off" picture (`CameraOffStill`, `CameraOffAccessory`).
@Suite(.serialized) struct CameraOffTests {
    private static func size(of jpeg: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    @Test func theStillIsExactlyTheSizeHomeAsksFor() throws {
        let still = CameraOffStill(codecs: AppleMediaCodecs())
        for (width, height) in [(1280, 720), (640, 360), (320, 240), (1920, 1080)] {
            let jpeg = try still.jpeg(cameraName: "Front door", width: width, height: height)
            #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
            let drawn = try #require(Self.size(of: jpeg))
            #expect(drawn == (width, height))
        }
        #expect(try Self.size(of: still.jpeg(cameraName: "x", width: 1, height: 1_000_000)).map { $0.0 >= 16 && $0.1 <= 4_096 } == true, "absurd sizes are clamped")
    }

    @Test func theStillIsMadeOncePerSizeAndName() throws {
        let made = Mutex(0)
        let still = CameraOffStill { name, width, height in
            made.withLock { $0 += 1 }
            return Data("\(name)-\(width)x\(height)".utf8)
        }
        let a = try still.jpeg(cameraName: "Door", width: 1280, height: 720)
        #expect(try still.jpeg(cameraName: "Door", width: 1280, height: 720) == a)
        #expect(made.withLock { $0 } == 1)
        _ = try still.jpeg(cameraName: "Door", width: 640, height: 360)
        _ = try still.jpeg(cameraName: "Garage", width: 1280, height: 720)   // a renamed camera gets its own
        #expect(made.withLock { $0 } == 3)
        for width in 100..<120 { _ = try still.jpeg(cameraName: "Door", width: width, height: 100) }
        #expect(made.withLock { $0 } == 23)
        _ = try still.jpeg(cameraName: "Door", width: 119, height: 100)
        #expect(made.withLock { $0 } == 23, "the newest sizes are kept")
        _ = try still.jpeg(cameraName: "Door", width: 1280, height: 720)
        #expect(made.withLock { $0 } == 24, "the oldest were let go")
    }

    @MainActor @Test(.timeLimit(.minutes(3))) func aCameraThatIsOffStaysInHomeWithTheStillAndQuietSensors() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        var camera = EngineFixture.demoCamera(name: "Front door")
        camera.isEnabled = false
        try await engine.addCamera(camera, password: nil)

        // No connection to the camera, but the accessory is up on the camera's port.
        #expect(engine.runtimes[camera.id] == nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.hapPort != nil })
        let status = try #require(fixture.status(camera.id))
        #expect(status.connection == .disabled)

        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        let ids = try await controller.cameraIDs()
        #expect(ids.recording != nil && ids.streams.count == 2, "the accessory is the same as the running camera's")

        let jpeg = try await controller.snapshot(width: 640, height: 360)
        let drawn = try #require(Self.size(of: jpeg))
        #expect(drawn == (640, 360))
        let expected = try AppleMediaCodecs().cameraOffJPEG(cameraName: "Front door", width: 640, height: 360)
        #expect(jpeg == expected, "the snapshot is the Camera off picture")

        // Sensors stay quiet, whatever is reported for the camera.
        let motion = try #require(ids.motionDetected)
        try await controller.subscribe([motion])
        await engine.triggerTestMotion(cameraID: camera.id)
        await #expect(throws: (any Error).self) { _ = try await controller.nextEvent(for: motion, timeout: .seconds(1)) }
        #expect(try await controller.readValue(motion).hapBool == false)

        // Turned on: the camera runs as before, in the same accessory (same port, still paired).
        let port = status.hapPort
        camera.isEnabled = true
        try await engine.updateCamera(camera, password: nil)
        #expect(await fixture.waitFor { engine.runtimes[camera.id] != nil && fixture.status(camera.id)?.videoSummary != nil })
        #expect(fixture.status(camera.id)?.hapPort == port)
        #expect(engine.offAccessories[camera.id] == nil)

        // And off again: the picture comes back.
        camera.isEnabled = false
        try await engine.updateCamera(camera, password: nil)
        #expect(await fixture.waitFor { engine.runtimes[camera.id] == nil && engine.offAccessories[camera.id] != nil })
        #expect(await fixture.until { await engine.offAccessories[camera.id]?.hapPort != nil })
        await controller.close()
        await fixture.tearDown()
    }
}
#endif
