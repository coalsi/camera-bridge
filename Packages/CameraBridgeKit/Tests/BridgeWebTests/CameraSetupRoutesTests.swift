import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// `GET/POST cameras/:id/setup` and `POST cameras/:id/setup/restore`: the preview reads only, a run or a restore needs an explicit
/// confirmation, and one change at a time per camera. `POST cameras/:id/restart`: only for a camera that waits for its restart.
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

    /// "Fix its address so the DNS stays": the preview's step carries the offer (the camera's address, mask, gateway and hardware address, and
    /// what changes with it); the run takes the choice only with the address the preview showed (`keeps`), which the engine compares with the
    /// camera's before it writes. Off unless the page sends it.
    @Test func theChoiceGoesWithTheAddressThePreviewShowed() async throws {
        let rig = try await NVRRig.make()
        let keeps = CameraAddressing(address: "192.168.77.30", subnetMask: "255.255.255.0", gateway: "192.168.77.1", hardwareAddress: "02:00:00:00:00:30")
        var offered = CameraSetupStep(id: .internetWatch, title: "Watch its internet", status: .notSupported, detail: "the camera takes its address from DHCP")
        offered.fixAddress = CameraSetupFixAddress(addressing: keeps, changes: [
            CameraSetupChange(label: "Address", now: "192.168.77.30 from the router (DHCP)", after: "192.168.77.30, fixed (mask 255.255.255.0, gateway 192.168.77.1)")],
            method: .hikvisionISAPI)
        rig.backend.write { $0.setup = .success(CameraSetupReport(steps: [offered], state: nil, canRestore: false)) }
        let preview = await rig.session.send("GET", "/api/v1/cameras/\(rig.cameraID)/setup")
        let fix = try #require(preview.array("steps").first?["fixAddress"] as? [String: Any])
        let addressing = try #require(fix["addressing"] as? [String: Any])
        #expect(addressing["address"] as? String == "192.168.77.30" && addressing["subnetMask"] as? String == "255.255.255.0")
        #expect(addressing["gateway"] as? String == "192.168.77.1" && addressing["hardwareAddress"] as? String == "02:00:00:00:00:30")
        #expect((fix["changes"] as? [[String: Any]])?.first?["label"] as? String == "Address" && fix["method"] as? String == "hikvisionISAPI")

        let url = "/api/v1/cameras/\(rig.cameraID)/setup"
        let shown: [String: Any] = ["address": "192.168.77.30", "subnetMask": "255.255.255.0", "gateway": "192.168.77.1"]
        #expect((await rig.session.send("POST", url, json: ["confirm": true])).status == 200)
        #expect(rig.backend.read { $0.setupOptions } == CameraSetupOptions(), "off by default")
        let missing = await rig.session.send("POST", url, json: ["confirm": true, "fixAddress": true])
        #expect(missing.status == 400 && missing.json["field"] as? String == "keeps", "never without the address the preview showed")
        let odd = await rig.session.send("POST", url, json: ["confirm": true, "fixAddress": true, "keeps": ["address": "192.168.77.30"]])
        #expect(odd.status == 400)
        #expect((await rig.session.send("POST", url, json: ["confirm": true, "fixAddress": true, "keeps": shown])).status == 200)
        #expect(rig.backend.read { $0.setupOptions } == CameraSetupOptions(fixAddress: true, shownAddress: CameraAddressing(address: "192.168.77.30",
                                                                                                                          subnetMask: "255.255.255.0", gateway: "192.168.77.1")))
        #expect((await rig.session.send("POST", url, json: ["confirm": true, "fixAddress": false, "keeps": shown])).status == 200)
        #expect(rig.backend.read { $0.setupOptions } == CameraSetupOptions(), "not chosen: the address is not taken")
        #expect(rig.backend.read { $0.calls } == ["setupPreview", "setupApply", "setupApply", "setupApply"])
    }

    /// A camera whose setup took a change "after it restarts" says so on its resource (`restartOffered`, the engine's word), and only then
    /// does `POST cameras/:id/restart` restart it (204): any other camera is a 409, so a page left open can't restart one at will. It takes the
    /// session and the anti-forgery token like every change. The engine's half: `CameraSetupWatchRuleTests`.
    @Test func restartRequiredOffersTheButtonAndTheRoute() async throws {
        let rig = try await NVRRig.make()
        let url = "/api/v1/cameras/\(rig.cameraID)/restart"
        #expect((await rig.get("cameras/\(rig.cameraID)")).json["restartOffered"] as? Bool == false, "always there")
        let refused = await rig.session.send("POST", url)
        #expect(refused.status == 409 && refused.json["error"] as? String == "camera_restart_not_needed")
        #expect(rig.backend.read { $0.calls }.isEmpty, "nothing is asked of a camera that needs no restart")

        let now = Date(timeIntervalSince1970: 1_792_224_000)
        rig.backend.write {
            $0.configurations[0].setupState = CameraSetupState(started: now, applied: now, steps: [.init(id: .upnp, status: .done, needsRestart: true)])
        }
        #expect((await rig.get("cameras/\(rig.cameraID)")).json["restartOffered"] as? Bool == true)
        #expect((await rig.harness.send("POST", url, cookie: rig.session.cookie)).status == 403, "no anti-forgery token")
        #expect((await rig.harness.send("POST", url)).status == 401, "no session")
        #expect(rig.backend.read { $0.calls }.isEmpty)
        #expect((await rig.session.send("POST", url)).status == 204)
        #expect(rig.backend.read { $0.calls } == ["restartCamera"])

        // The engine has the last word (it may have restarted meanwhile), and a camera that refuses says why.
        rig.backend.write { $0.restartError = CameraRestartNotNeeded() }
        #expect((await rig.session.send("POST", url)).json["error"] as? String == "camera_restart_not_needed")
        rig.backend.write { $0.restartError = CameraAdapterError.notPermitted("PUT /ISAPI/System/reboot") }
        let notPermitted = await rig.session.send("POST", url)
        #expect(notPermitted.status == 422 && notPermitted.json["message"] as? String == "The account Camera Bridge uses may not change this; use an "
                + "administrator account in the camera’s settings.")
        #expect((await rig.session.send("POST", "/api/v1/cameras/\(UUID().uuidString)/restart")).status == 404)
    }
}
