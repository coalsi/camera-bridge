import Foundation
import BridgeEngine
import CameraAdapters
import Testing
import TestSupport
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

    /// A camera's "Camera audio" switch is the owner's word on whether it is heard. The page never asks for the sound of a camera whose switch is off,
    /// but an Apple TV's key opens this route too, so `audio=` carries sound only for the cameras whose switch is on: one with it off, listed there
    /// all the same, is sent without sound (no error, and its picture as ever), and one with it on keeps its sound.
    @Test func soundIsOnlyAskedOfCamerasWhoseAudioSwitchIsOn() async throws {
        let harness = try Harness()
        let owner = try await harness.signIn()
        let tv = try await harness.pairAppleTV(owner: owner)
        var porch = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.20"), username: "")
        porch.audioEnabled = true
        var garage = CameraConfiguration(name: "Garage", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.21"), username: "")
        garage.audioEnabled = false
        try await harness.backend.addCamera(porch, password: nil)
        try await harness.backend.addCamera(garage, password: nil)
        let both = "\(porch.id.uuidString),\(garage.id.uuidString)"

        /// Whether sound was asked of the backend for each camera, once `start` has opened a live view of both with sound requested for both.
        func soundAsked(_ start: (String) async -> StreamCollector) async -> [UUID: Bool] {
            harness.backend.write { $0.liveCalls = [] }
            let stream = await start("/api/v1/live?cameras=\(both)&audio=\(both)")
            defer { stream.cancel() }
            #expect(stream.response.status == 200, "the camera with its switch off is no error")
            #expect(await eventually { harness.backend.read { $0.liveCalls.count } == 2 }, "both cameras are subscribed to")
            return Dictionary(harness.backend.read { $0.liveCalls }.map { ($0.camera, $0.audio) }, uniquingKeysWith: { first, _ in first })
        }

        let browser = await soundAsked { await owner.stream($0) }
        #expect(browser == [porch.id: true, garage.id: false], "the owner's page: the Porch keeps its sound, the Garage has none")
        let appleTV = await soundAsked { StreamCollector(await harness.raw("GET", $0, headers: [("Authorization", "Bearer \(tv.key)")])) }
        #expect(appleTV == [porch.id: true, garage.id: false], "an Apple TV that lists the Garage's sound gets no more than the page")
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
