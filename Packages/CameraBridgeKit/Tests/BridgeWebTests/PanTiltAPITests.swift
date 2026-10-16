import BridgeEngine
import CameraAdapters
import Foundation
import Testing
@testable import BridgeWeb

/// `POST cameras/:id/pan-tilt`: values checked, unknown cameras 404, a camera that can't pan and tilt 409.
@Suite struct PanTiltAPITests {
    @Test func theRouteChecksItsValuesAndTheCamera() async throws {
        let backend = FakeBackend()
        let camera = CameraConfiguration(name: "Pan", kind: .camera, vendor: .go2rtc, endpoint: CameraEndpoint(host: "127.0.0.1"), username: "")
        backend.write { $0.configurations.append(camera) }
        let harness = try Harness(backend: backend) { _ in }
        let session = try await harness.signIn()
        #expect(await session.send("POST", "/api/v1/cameras/\(camera.id.uuidString)/pan-tilt", json: ["pan": 2, "tilt": 0]).status == 400)
        #expect(await session.send("POST", "/api/v1/cameras/\(UUID().uuidString)/pan-tilt", json: ["pan": 1, "tilt": 0]).status == 404)
        let refused = await session.send("POST", "/api/v1/cameras/\(camera.id.uuidString)/pan-tilt", json: ["pan": 1, "tilt": 0])
        #expect(refused.status == 409 && refused.json["error"] as? String == "no_pan_tilt", "\(refused.text)")
    }
}
