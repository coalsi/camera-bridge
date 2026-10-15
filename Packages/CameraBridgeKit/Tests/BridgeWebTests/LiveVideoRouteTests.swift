import Foundation
import BridgeEngine
import CameraAdapters
import Testing
@testable import BridgeWeb

/// `GET /api/v1/live`: the framing of its messages and what it refuses.
@Suite struct LiveVideoRouteTests {
    @Test func aMessageIsTypeCameraLengthThenThePayload() {
        let payload = Data(repeating: 7, count: 300)
        let frame = WebApp.liveFrame(.keyframe, camera: 2, payload: payload)
        #expect(Array(frame.prefix(6)) == [4, 2, 0, 0, 1, 44])
        #expect(frame.dropFirst(6) == payload)
    }

    @Test func refusesNoCamerasUnknownCamerasAndABadStream() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        #expect(await session.get("/api/v1/live").status == 400)
        #expect(await session.get("/api/v1/live?cameras=not-an-id").status == 400)
        #expect(await session.get("/api/v1/live?cameras=\(UUID().uuidString)").status == 404)
        let id = UUID().uuidString
        #expect(await session.get("/api/v1/live?cameras=\(id),\(id)").status == 400, "the same camera twice")
        let camera = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.20"), username: "")
        try await harness.backend.addCamera(camera, password: nil)
        #expect(await session.get("/api/v1/live?cameras=\(camera.id.uuidString)&stream=huge").status == 400)
    }

    @Test func needsASignedInSession() async throws {
        let harness = try Harness()
        _ = try await harness.signIn()
        #expect(await harness.send("GET", "/api/v1/live?cameras=\(UUID().uuidString)").status == 401)
    }

    /// A camera without a picture (here: a backend that has no live video) is reported in the stream, which stays open and keeps trying.
    @Test func aCameraWithoutLiveVideoSaysSoInTheStream() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let camera = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.20"), username: "")
        try await harness.backend.addCamera(camera, password: nil)
        let stream = await session.stream("/api/v1/live?cameras=\(camera.id.uuidString)")
        #expect(stream.response.status == 200)
        #expect(await stream.wait { $0.contains("\"state\":\"unavailable\"") })
        #expect(!stream.finished.value)
        stream.cancel()
    }
}

/// The bridge's time zone (the timestamp overlay and the cameras' clocks follow it).
@Suite struct TimeZoneSettingTests {
    @Test func isSavedAndAZoneThatDoesNotExistIsRefused() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        #expect(await session.send("PATCH", "/api/v1/settings", json: ["timeZone": "Mars/Olympus"]).status == 400)
        let answer = await session.send("PATCH", "/api/v1/settings", json: ["timeZone": "America/Phoenix"])
        #expect(answer.status == 200)
        #expect(answer.json["timeZone"] as? String == "America/Phoenix")
    }

    @Test func aBackendWithoutCamerasRefusesTheCameraClockRoutes() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let camera = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.20"), username: "")
        try await harness.backend.addCamera(camera, password: nil)
        #expect(await session.send("POST", "/api/v1/cameras/\(camera.id.uuidString)/camera-clock", json: ["shown": true]).status == 422)
        #expect(await session.send("POST", "/api/v1/cameras/\(camera.id.uuidString)/camera-time-zone", json: [:]).status == 422)
    }
}
