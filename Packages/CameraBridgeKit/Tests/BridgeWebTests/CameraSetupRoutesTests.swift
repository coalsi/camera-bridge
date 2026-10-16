import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// `GET/POST cameras/:id/setup` and `POST cameras/:id/setup/restore`: the preview reads only, a run or a restore needs an explicit
/// confirmation, and one change at a time per camera.
@Suite(.timeLimit(.minutes(1))) struct CameraSetupRoutesTests {
    private func report() -> CameraSetupReport {
        CameraSetupReport(steps: [
            CameraSetupStep(id: .timeZone, title: "Time zone", status: .alreadyRight),
            CameraSetupStep(id: .cloud, title: "Cloud off (Hik-Connect)", status: .willChange,
                            changes: [CameraSetupChange(label: "Hik-Connect (the maker’s cloud)", now: "on", after: "off")]),
            CameraSetupStep(id: .timeSource, title: "Time from the bridge", status: .notOffered, detail: "Camera Bridge OS serves time to cameras; this bridge does not."),
        ], state: nil, canRestore: false)
    }

    @Test func thePreviewAnswersEveryStepWithWhatChanges() async throws {
        let rig = try await NVRRig.make()
        rig.backend.write { $0.setup = .success(report()) }
        let answer = await rig.session.send("GET", "/api/v1/cameras/\(rig.cameraID)/setup")
        #expect(answer.status == 200)
        let steps = answer.array("steps")
        #expect(steps.map { $0["id"] as? String } == ["timeZone", "cloud", "timeSource"])
        #expect(steps.map { $0["status"] as? String } == ["alreadyRight", "willChange", "notOffered"])
        let change = try #require((steps[1]["changes"] as? [[String: Any]])?.first)
        #expect(change["now"] as? String == "on" && change["after"] as? String == "off")
        #expect(answer.json["canRestore"] as? Bool == false)
        #expect(rig.backend.read { $0.calls } == ["setupPreview"])
    }

    @Test func nothingIsChangedWithoutAnExplicitConfirmation() async throws {
        let rig = try await NVRRig.make()
        rig.backend.write { $0.setup = .success(report()) }
        for path in ["setup", "setup/restore"] {
            let url = "/api/v1/cameras/\(rig.cameraID)/\(path)"
            for body: [String: Any] in [[:], ["confirm": false], ["confirm": "yes"]] {
                let answer = await rig.session.send("POST", url, json: body)
                #expect(answer.status == 400 && answer.json["field"] as? String == "confirm", "\(path) \(body)")
            }
            #expect((await rig.session.send("POST", url)).status == 400)
        }
        #expect(rig.backend.read { $0.calls }.isEmpty)
        #expect((await rig.session.send("POST", "/api/v1/cameras/\(rig.cameraID)/setup", json: ["confirm": true])).status == 200)
        #expect((await rig.session.send("POST", "/api/v1/cameras/\(rig.cameraID)/setup/restore", json: ["confirm": true])).status == 200)
        #expect(rig.backend.read { $0.calls } == ["setupApply", "setupRestore"])
    }

    @Test func anUnknownCameraIsNotFoundAndAFailureIsASentence() async throws {
        let rig = try await NVRRig.make()
        #expect((await rig.session.send("GET", "/api/v1/cameras/\(UUID().uuidString)/setup")).status == 404)
        rig.backend.write { $0.setup = .failure(EngineError.invalidSettings("Set up for Camera Bridge works with Hikvision, Reolink, Amcrest and ONVIF cameras the bridge reaches directly")) }
        let answer = await rig.session.send("GET", "/api/v1/cameras/\(rig.cameraID)/setup")
        #expect(answer.status == 422 && answer.json["error"] as? String == "camera_setup_unavailable")
        #expect(answer.json["message"] as? String == "Set up for Camera Bridge works with Hikvision, Reolink, Amcrest and ONVIF cameras the bridge reaches directly.")
    }

    @Test func oneChangeRunsPerCameraAtATime() async throws {
        let gate = AsyncGate()
        let rig = try await NVRRig.make()
        rig.backend.write { $0.setup = .success(report()); $0.setupGate = gate }
        let url = "/api/v1/cameras/\(rig.cameraID)/setup"
        let first = Task { await rig.session.send("POST", url, json: ["confirm": true]) }
        #expect(await eventually { gate.waiting == 1 })
        let second = await rig.session.send("POST", url, json: ["confirm": true])
        #expect(second.status == 409 && second.json["error"] as? String == "camera_setup_busy")
        let optimize = await rig.session.send("POST", "/api/v1/cameras/\(rig.cameraID)/optimize", json: ["confirm": true])
        #expect(optimize.status == 409, "Optimize changes the same camera: it waits too")
        gate.open()
        #expect(await first.value.status == 200)
    }
}
