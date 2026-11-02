import BridgeEngine
import CameraAdapters
import Foundation
import Testing
@testable import BridgeWeb

/// `POST cameras/:id/pan-tilt`: values checked, unknown cameras 404, a camera that can't pan and tilt 409. The owner's switches for a camera
/// whose control says it pans, tilts and zooms when it can't (`PATCH cameras/:id {panTiltEnabled, zoomEnabled}`), and what the status and
/// an Apple TV are told.
@Suite struct PanTiltAPITests {
    private static let patio = CameraConfiguration(name: "Patio", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "192.0.2.30"), username: "admin")

    /// `PATCH cameras/:id` takes `panTiltEnabled` and `zoomEnabled`, true or false (null changes nothing), only from the signed-in page with its
    /// CSRF token, and saves them with the camera, whose JSON carries them once set (absent until then: as the camera's control says).
    @Test func theOwnersSwitchesAreCheckedSavedAndShown() async throws {
        let backend = FakeBackend()
        backend.write { $0.configurations = [Self.patio] }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let path = "/api/v1/cameras/\(Self.patio.id.uuidString)"
        func saved() -> [Bool?] { backend.read { state in [state.configurations.first?.panTiltEnabled, state.configurations.first?.zoomEnabled] } }

        let before = await session.get(path)
        #expect(before.status == 200 && !before.json.keys.contains("panTiltEnabled") && !before.json.keys.contains("zoomEnabled"),
                "absent until set: as the camera's control says")

        let off = await session.send("PATCH", path, json: ["panTiltEnabled": false])
        #expect(off.status == 200, "\(off.text)")
        #expect(off.json["panTiltEnabled"] as? Bool == false && !off.json.keys.contains("zoomEnabled"), "only what was sent")
        #expect(saved() == [false, nil])
        let zoomOff = await session.send("PATCH", path, json: ["zoomEnabled": false])
        #expect(zoomOff.json["panTiltEnabled"] as? Bool == false && zoomOff.json["zoomEnabled"] as? Bool == false)
        #expect(saved() == [false, false])
        #expect((await session.get(path)).json["zoomEnabled"] as? Bool == false, "and the camera shows them")

        // True gives it back to the camera's control; null changes nothing.
        let on = await session.send("PATCH", path, json: ["panTiltEnabled": true, "zoomEnabled": NSNull()])
        #expect(on.status == 200 && on.json["panTiltEnabled"] as? Bool == true && on.json["zoomEnabled"] as? Bool == false, "\(on.text)")
        #expect(saved() == [true, false])

        // Anything but true or false is refused, with the field, and nothing of the request is saved.
        let wrongs: [Any] = ["no", "false", ["on": true], [false], 0]
        for wrong in wrongs {
            let refused = await session.send("PATCH", path, json: ["panTiltEnabled": false, "zoomEnabled": wrong])
            #expect(refused.status == 400 && refused.json["field"] as? String == "zoomEnabled", "\(wrong): \(refused.text)")
        }
        #expect(saved() == [true, false])

        // Only the signed-in owner's page, with its token.
        let forged = await harness.send("PATCH", path, json: ["zoomEnabled": true], cookie: session.cookie)
        #expect(forged.status == 403 && forged.json["error"] as? String == "csrf")
        #expect(await harness.send("PATCH", path, json: ["zoomEnabled": true]).status == 401)
        #expect(saved() == [true, false])
    }

    /// The camera's status carries what is offered (`panTilt`, `zoom`: the control's word less what the owner turned off) and what the
    /// control said (`panTiltDetected`, `zoomDetected`: the page offers its switches for these); an Apple TV is told only what is offered.
    @Test func theStatusTellsWhatIsOfferedAndWhatTheControlSaid() async throws {
        let backend = FakeBackend()
        var camera = Self.patio
        camera.panTiltEnabled = false
        var status = CameraStatus(id: camera.id, name: camera.name, kind: .camera, vendor: .onvif, connection: .online)
        status.panTiltDetected = true
        status.zoomDetected = true
        status.zoom = true
        backend.write {
            $0.configurations = [camera]
            $0.statusOverrides[camera.id] = status
        }
        let session = try await Harness(backend: backend).signIn()
        let shown = try #require((await session.get("/api/v1/cameras/\(camera.id.uuidString)")).json["status"] as? [String: Any])
        #expect(shown["panTilt"] as? Bool == false && shown["panTiltDetected"] as? Bool == true)
        #expect(shown["zoom"] as? Bool == true && shown["zoomDetected"] as? Bool == true)
        let tv = try #require(((await session.get("/api/v1/viewer")).json["cameras"] as? [[String: Any]])?.first)
        #expect(tv["panTilt"] as? Bool == false && tv["zoom"] as? Bool == true, "an Apple TV offers Move only for what is offered")
        #expect(!tv.keys.contains("panTiltDetected") && !tv.keys.contains("zoomDetected"))

        // A camera whose control said nothing: all four false.
        backend.write { $0.statusOverrides[camera.id] = CameraStatus(id: camera.id, name: camera.name, kind: .camera, vendor: .onvif, connection: .online) }
        let plain = try #require((await session.get("/api/v1/cameras/\(camera.id.uuidString)")).json["status"] as? [String: Any])
        for key in ["panTilt", "zoom", "panTiltDetected", "zoomDetected"] { #expect(plain[key] as? Bool == false, "\(key)") }
    }

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

    /// A refusal keeps its one code, and its sentence says what was asked: a zoom step, or a move or a stop.
    @Test func aRefusalSaysWhetherAZoomOrAMoveWasRefused() async throws {
        let backend = FakeBackend()
        backend.write { $0.configurations = [Self.patio] }
        let session = try await Harness(backend: backend).signIn()
        let path = "/api/v1/cameras/\(Self.patio.id.uuidString)/pan-tilt"
        let cases: [([String: Any], String)] = [(["pan": 0, "tilt": 0, "zoom": 1], "This camera can’t zoom right now."),
                                                (["pan": 0, "tilt": 0, "zoom": -0.5], "This camera can’t zoom right now."),
                                                (["pan": 1, "tilt": 0], "This camera can’t pan and tilt right now."),
                                                (["pan": 0, "tilt": 0, "zoom": 0], "This camera can’t pan and tilt right now.")]
        for (body, sentence) in cases {
            let refused = await session.send("POST", path, json: body)
            #expect(refused.status == 409 && refused.json["error"] as? String == "no_pan_tilt", "\(body): \(refused.text)")
            #expect(refused.json["message"] as? String == sentence, "\(body)")
        }
    }
}
