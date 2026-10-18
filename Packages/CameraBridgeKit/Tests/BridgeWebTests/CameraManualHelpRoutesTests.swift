import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// "Change it by hand" on the wire: a step of Set up for Camera Bridge that could not be done carries `manualHelp` {why, places: [{app, path,
/// action, confirmed}], values: [{label, value}], router, note, then, caveat}; a step done carries none. On the camera resource and in
/// `POST cameras/:id/security/check` every finding has the key `manualHelp`, null when there is none.
@Suite(.timeLimit(.minutes(1))) struct CameraManualHelpRoutesTests {
    static let context = CameraManualHelpText.Context(timeServer: "192.168.77.28", guardServer: "192.168.77.28", timeZone: "America/Phoenix (UTC−7:00)")

    static var watchHelp: CameraManualHelp? {
        CameraManualHelpText.step(.internetWatch, status: .refused, detail: nil, family: .reolink, context: context)
    }

    @Test func aStepThatCouldNotBeDoneCarriesItsHelp() async throws {
        let rig = try await NVRRig.make()
        let report = CameraSetupReport(steps: [
            CameraSetupStep(id: .timeZone, title: "Time zone", status: .alreadyRight),
            CameraSetupStep(id: .internetWatch, title: "Watch its internet", status: .refused, detail: "the camera kept 8.8.8.8", manualHelp: Self.watchHelp),
        ], state: nil, canRestore: true)
        rig.backend.write { $0.setup = .success(report) }
        let answer = await rig.session.send("GET", "/api/v1/cameras/\(rig.cameraID)/setup")
        #expect(answer.status == 200)
        let steps = answer.array("steps")
        #expect(steps[0]["manualHelp"] == nil, "a step already right has none")
        let help = try #require(steps[1]["manualHelp"] as? [String: Any])
        #expect(help["why"] as? String == "The camera didn’t take the change.")
        let values = try #require(help["values"] as? [[String: Any]])
        #expect(values.contains { $0["label"] as? String == "Preferred DNS server" && $0["value"] as? String == "192.168.77.28" })
        let places = try #require(help["places"] as? [[String: Any]])
        #expect(places.first?["app"] as? String == "The Reolink app" && places.first?["confirmed"] as? Bool == false)
        #expect((help["caveat"] as? String)?.hasPrefix("Menu names differ between models") == true)
        #expect((help["router"] as? String)?.contains("192.168.77.28") == true)
    }

    @Test func everyFindingHasTheKeyAndTheNotWatchedGuardCarriesTheDNSHelp() async throws {
        let rig = try await NVRRig.make()
        var guardFinding = CameraSecurityFinding(feature: .internetGuard, state: .off, level: .green,
                                                 sentence: "The Internet guard doesn’t watch this camera, so Camera Bridge can’t confirm that nothing gets out.",
                                                 canChange: false)
        guardFinding.manualHelp = Self.watchHelp
        let security = CameraSecurity(level: .green, title: "Good", summary: "Camera Bridge found no cloud turned on.", findings: [
            CameraSecurityFinding(feature: .cloud, state: .off, level: .gold, sentence: "UID is off.", canChange: true),
            guardFinding,
        ], checkedAt: Date(timeIntervalSince1970: 1_792_224_000), internetGuard: CameraGuardActivity(watched: false, today: 0, last24h: 0, names: []))
        rig.backend.write { state in
            state.configurations[0].vendor = .reolink
            var status = CameraStatus(id: rig.camera.id, name: rig.camera.name, kind: .camera, vendor: .reolink)
            status.security = security
            state.statusOverrides[rig.camera.id] = status
            state.security = .success(security)
        }
        let camera = await rig.get("cameras/\(rig.cameraID)")
        let checked = await rig.session.send("POST", "/api/v1/cameras/\(rig.cameraID)/security/check", json: [:])
        #expect(checked.status == 200)
        for findings in [((camera.json["status"] as? [String: Any])?["security"] as? [String: Any])?["findings"] as? [[String: Any]],
                         checked.json["findings"] as? [[String: Any]]] {
            let findings = try #require(findings)
            #expect(findings[0]["manualHelp"] is NSNull, "every key is always there")
            let help = try #require(findings[1]["manualHelp"] as? [String: Any])
            #expect((help["then"] as? String) == "Then press Check again on the camera’s Security card.")
        }
    }
}
