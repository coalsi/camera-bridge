import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// `status.security` on the camera resource (absent until the first check) and `POST cameras/:id/security/check`: its JSON shape, the camera
/// that is not there, a check too soon (429 with Retry-After), an unreachable camera and the demo camera.
@Suite(.timeLimit(.minutes(1))) struct CameraSecurityRoutesTests {
    static let checkedAt = Date(timeIntervalSince1970: 1_792_224_000)   // 2026-10-17T08:00:00Z

    static let security = CameraSecurity(level: .red, title: "Outside access possible",
                                         summary: "Something on this camera can let it be reached from outside your home.", findings: [
        CameraSecurityFinding(feature: .cloud, state: .on, level: .red,
                              sentence: "Hik-Connect is on and linked to an account, so the camera can be reached from outside your home.",
                              canChange: true, linked: true, service: "Hik-Connect"),
        CameraSecurityFinding(feature: .internetGuard, state: .absent, level: .green,
                              sentence: "This bridge can’t watch the camera’s internet traffic, so Camera Bridge can’t confirm that nothing gets out.",
                              canChange: false),
    ], checkedAt: checkedAt)

    private func rig(security: CameraSecurity? = nil) async throws -> NVRRig {
        let rig = try await NVRRig.make()
        rig.backend.write { state in
            state.configurations[0].vendor = .hikvision
            guard let security else { return }
            var status = CameraStatus(id: rig.camera.id, name: rig.camera.name, kind: .camera, vendor: .hikvision)
            status.security = security
            state.statusOverrides[rig.camera.id] = status
        }
        return rig
    }

    private func expectShape(_ security: [String: Any]?) throws {
        let security = try #require(security)
        #expect(security["level"] as? String == "red" && security["title"] as? String == "Outside access possible")
        #expect(security["summary"] as? String == "Something on this camera can let it be reached from outside your home.")
        #expect(security["checkedAt"] as? String == "2026-10-17T08:00:00Z")
        let findings = try #require(security["findings"] as? [[String: Any]])
        #expect(findings.count == 2)
        #expect(findings[0]["feature"] as? String == "cloud" && findings[0]["state"] as? String == "on" && findings[0]["level"] as? String == "red")
        #expect(findings[0]["canChange"] as? Bool == true && findings[0]["linked"] as? Bool == true && findings[0]["service"] as? String == "Hik-Connect")
        #expect(findings[0]["sentence"] as? String == "Hik-Connect is on and linked to an account, so the camera can be reached from outside your home.")
        #expect(findings[1]["feature"] as? String == "internetGuard" && findings[1]["state"] as? String == "absent")
        #expect(findings[1]["linked"] is NSNull && findings[1]["service"] is NSNull, "every key is always there")
    }

    @Test func theCameraCarriesItsSecurityOnceChecked() async throws {
        let unchecked = try await rig()
        let before = await unchecked.get("cameras/\(unchecked.cameraID)")
        #expect(before.status == 200 && (before.json["status"] as? [String: Any])?["security"] == nil, "absent until the first check")

        let rig = try await rig(security: Self.security)
        let camera = await rig.get("cameras/\(rig.cameraID)")
        try expectShape((camera.json["status"] as? [String: Any])?["security"] as? [String: Any])
        let list = await rig.get("cameras")
        let first = (list.array("cameras").first?["status"] as? [String: Any])?["security"] as? [String: Any]
        try expectShape(first)
    }

    @Test func aCheckAnswersTheNewLevel() async throws {
        let rig = try await rig()
        rig.backend.write { $0.security = .success(Self.security) }
        let answer = await rig.session.send("POST", "/api/v1/cameras/\(rig.cameraID)/security/check")
        #expect(answer.status == 200)
        try expectShape(answer.json)
        #expect(rig.backend.read { $0.calls } == ["checkSecurity"])
    }

    @Test func aCameraThatIsNotThereIsNotFound() async throws {
        let rig = try await rig()
        #expect((await rig.session.send("POST", "/api/v1/cameras/\(UUID().uuidString)/security/check")).status == 404)
        rig.backend.write { $0.security = .failure(EngineError.unknownCamera) }
        #expect((await rig.session.send("POST", "/api/v1/cameras/\(rig.cameraID)/security/check")).status == 404, "removed during the check")
    }

    @Test func aCheckTooSoonIsRefusedWithWhenToTryAgain() async throws {
        let rig = try await rig()
        rig.backend.write { $0.security = .failure(CameraSecurityCheckTooSoon(retryAfterSeconds: 42)) }
        let answer = await rig.session.send("POST", "/api/v1/cameras/\(rig.cameraID)/security/check")
        #expect(answer.status == 429 && answer.json["error"] as? String == "security_check_too_soon")
        #expect(answer.headers["Retry-After"] == "42")
        #expect(answer.json["message"] as? String == "This camera was checked less than a minute ago. Try again in a minute.")
    }

    @Test func anUnreachableCameraOrTheDemoCameraIsASentence() async throws {
        let rig = try await rig()
        rig.backend.write { $0.security = .failure(CameraOfflineError()) }
        let offline = await rig.session.send("POST", "/api/v1/cameras/\(rig.cameraID)/security/check")
        #expect(offline.status == 409 && offline.json["error"] as? String == "camera_offline")
        #expect(offline.json["message"] as? String == "The camera isn’t answering, so it can’t be checked now.")
        rig.backend.write { $0.security = .failure(EngineError.invalidSettings("Camera Bridge doesn’t check the demo camera")) }
        let demo = await rig.session.send("POST", "/api/v1/cameras/\(rig.cameraID)/security/check")
        #expect(demo.status == 422 && demo.json["error"] as? String == "security_check_unavailable")
        #expect(demo.json["message"] as? String == "Camera Bridge doesn’t check the demo camera.")
    }
}
