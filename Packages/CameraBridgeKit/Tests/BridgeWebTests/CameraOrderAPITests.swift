import BridgeEngine
import CameraAdapters
import Foundation
import Testing
@testable import BridgeWeb

@Suite(.timeLimit(.minutes(1))) struct CameraOrderAPITests {
    private func camera(_ name: String) -> CameraConfiguration {
        CameraConfiguration(name: name, kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.10"), username: "admin")
    }

    @Test func theOrderIsEmptyAtFirstSavedByOnePatchAndReadBack() async throws {
        let one = camera("Porch"), two = camera("Alley")
        let backend = FakeBackend()
        try await backend.addCamera(one, password: nil)
        try await backend.addCamera(two, password: nil)
        let session = try await Harness(backend: backend).signIn()
        #expect((await session.get("/api/v1/settings").json["cameraOrder"] as? [String]) == [])
        let saved = await session.send("PATCH", "/api/v1/settings", json: ["cameraOrder": [one.id.uuidString, two.id.uuidString]])
        #expect(saved.status == 200)
        #expect(saved.json["cameraOrder"] as? [String] == [one.id.uuidString, two.id.uuidString])
        #expect(await backend.overview().settings.cameraOrder == [one.id, two.id])
        #expect((await session.get("/api/v1/settings").json["cameraOrder"] as? [String]) == [one.id.uuidString, two.id.uuidString])
        let other = await session.send("PATCH", "/api/v1/settings", json: ["motionShadowTest": true])
        #expect(other.json["cameraOrder"] as? [String] == [one.id.uuidString, two.id.uuidString], "another change leaves the order alone")
    }

    @Test func idsOfCamerasThatAreGoneAndRepeatsAreLeftOut() async throws {
        let one = camera("Porch")
        let backend = FakeBackend()
        try await backend.addCamera(one, password: nil)
        let session = try await Harness(backend: backend).signIn()
        let gone = UUID()
        let saved = await session.send("PATCH", "/api/v1/settings", json: ["cameraOrder": [gone.uuidString, one.id.uuidString, one.id.uuidString]])
        #expect(saved.status == 200)
        #expect(saved.json["cameraOrder"] as? [String] == [one.id.uuidString])
        await backend.removeCamera(id: one.id)
        #expect((await session.get("/api/v1/settings").json["cameraOrder"] as? [String]) == [], "a camera removed later is not listed")
    }

    @Test func somethingThatIsNotAListOfIdsIsRefused() async throws {
        let session = try await Harness().signIn()
        let bad = await session.send("PATCH", "/api/v1/settings", json: ["cameraOrder": ["porch"]])
        #expect(bad.status == 400)
    }
}
