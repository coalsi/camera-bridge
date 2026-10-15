import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// `POST /cameras/:id/optimize` and `.../optimize/undo` (contract C.5 R11, R12): the HomeKit optimizer behind a server-side confirmation.
@Suite(.timeLimit(.minutes(1))) struct NVROptimizeAPITests {
    private func result() -> HomeKitOptimizationResult {
        let before = HomeKitReadinessReport(checks: [
            HomeKitReadinessCheck(id: "codec", title: "Main stream codec", status: .problem, explanation: "H.265"),
            HomeKitReadinessCheck(id: "keyframeInterval", title: "Keyframe interval", status: .warning, explanation: "12 s"),
            HomeKitReadinessCheck(id: "bitrate", title: "Main stream bitrate", status: .ok, explanation: "4 Mbps"),
        ])
        let after = HomeKitReadinessReport(checks: [
            HomeKitReadinessCheck(id: "codec", title: "Main stream codec", status: .ok, explanation: "H.264"),
            HomeKitReadinessCheck(id: "keyframeInterval", title: "Keyframe interval", status: .ok, explanation: "2 s"),
            HomeKitReadinessCheck(id: "bitrate", title: "Main stream bitrate", status: .ok, explanation: "4 Mbps"),
        ])
        return HomeKitOptimizationResult(before: before, after: after, appliedFixes: ["codec", "keyframeInterval"],
                                         failedFixes: [HomeKitOptimizationFailure(checkID: "bFrames", reason: "ONVIF minimal: InvalidArgVal at rtsp://admin:hunter2@192.0.2.20/main")],
                                         canUndo: true, mayNeedRecordingReEnabled: true)
    }

    @Test func theOptimizerIsNeverStartedWithoutAnExplicitConfirmation() async throws {
        let rig = try await NVRRig.make()
        let url = "/api/v1/cameras/\(rig.cameraID)/optimize"
        let bodies: [[String: Any]] = [[:], ["confirm": false], ["confirm": "yes"], ["confirm": 1], ["other": true]]
        for body in bodies {
            let answer = await rig.session.send("POST", url, json: body)
            #expect(answer.status == 400 && answer.json["error"] as? String == "invalid" && answer.json["field"] as? String == "confirm", "\(body)")
        }
        let empty = await rig.session.send("POST", url)
        #expect(empty.status == 400 && empty.json["field"] as? String == "confirm")
        #expect(rig.backend.read { !$0.calls.contains("optimize") })
    }

    @Test func anUnknownCameraIsNotFound() async throws {
        let rig = try await NVRRig.make()
        #expect((await rig.session.send("POST", "/api/v1/cameras/\(UUID().uuidString)/optimize", json: ["confirm": true])).status == 404)
        #expect((await rig.session.send("POST", "/api/v1/cameras/not-an-id/optimize", json: ["confirm": true])).status == 404)
        #expect((await rig.session.send("POST", "/api/v1/cameras/\(UUID().uuidString)/optimize/undo", json: [String: String]())).status == 404)
        #expect(rig.backend.read { $0.calls.isEmpty })
    }

    @Test func whatWasChangedIsReportedWithTheScoresAndWithoutSecrets() async throws {
        let rig = try await NVRRig.make()
        rig.backend.write { $0.optimization = .success(result()) }
        let answer = await rig.session.send("POST", "/api/v1/cameras/\(rig.cameraID)/optimize", json: ["confirm": true])
        #expect(answer.status == 200)
        #expect(Set(answer.json.keys) == ["applied", "failed", "canUndo", "mayNeedRecordingReEnabled", "scoreBefore", "scoreAfter"])
        #expect(answer.array("applied").map { $0["id"] as? String } == ["codec", "keyframeInterval"])
        #expect(answer.array("applied").map { $0["title"] as? String } == ["Main stream codec", "Keyframe interval"], "the titles of the report's checks")
        let failed = try #require(answer.array("failed").first)
        #expect(failed["id"] as? String == "bFrames" && (failed["reason"] as? String)?.contains("InvalidArgVal") == true)
        #expect(!answer.text.contains("hunter2"), "the camera's password is masked: \(answer.text)")
        #expect(answer.json["canUndo"] as? Bool == true && answer.json["mayNeedRecordingReEnabled"] as? Bool == true)
        #expect(answer.int("scoreBefore") == 50 && answer.int("scoreAfter") == 100)
        #expect(rig.backend.read { $0.calls } == ["optimize"])
    }

    @Test func aCameraThatCannotBeReachedIsExplainedAndCanBeTriedAgain() async throws {
        let rig = try await NVRRig.make()
        let url = "/api/v1/cameras/\(rig.cameraID)/optimize"
        let failed = await rig.session.send("POST", url, json: ["confirm": true])
        #expect(failed.status == 422 && failed.json["error"] as? String == "optimize_failed" && failed.json["message"] as? String == "The camera isn’t running.")
        rig.backend.write { $0.optimization = .success(result()) }
        #expect((await rig.session.send("POST", url, json: ["confirm": true])).status == 200, "a failure leaves the camera free for the next try")
    }

    @Test func whenNoMethodCanChangeTheCameraTheMethodsAndTheirReasonsAreListed() async throws {
        let rig = try await NVRRig.make()
        let attempts = [CameraConfigAttempt(method: .onvifMinimal, failure: .rejected("InvalidArgVal")), CameraConfigAttempt(method: .hikvisionISAPI, failure: .unsupported("HTTP 404"))]
        rig.backend.write { $0.optimization = .failure(CameraConfigError(attempts: attempts)) }
        let answer = await rig.session.send("POST", "/api/v1/cameras/\(rig.cameraID)/optimize", json: ["confirm": true])
        #expect(answer.status == 422 && answer.json["error"] as? String == "optimize_failed")
        #expect(answer.json["message"] as? String == "The camera didn’t accept the change: ONVIF minimal: InvalidArgVal; ISAPI: unsupported.")
    }

    @Test func onlyOneOptimizeRunsPerCameraAtATime() async throws {
        let gate = AsyncGate()
        let rig = try await NVRRig.make()
        rig.backend.write { $0.optimization = .success(result()); $0.optimizeGate = gate }
        let url = "/api/v1/cameras/\(rig.cameraID)/optimize"
        let first = Task { await rig.session.send("POST", url, json: ["confirm": true]) }
        #expect(await eventually { gate.waiting == 1 })
        let second = await rig.session.send("POST", url, json: ["confirm": true])
        #expect(second.status == 409 && second.json["error"] as? String == "optimize_busy")
        gate.open()
        #expect(await first.value.status == 200)
        #expect((await rig.session.send("POST", url, json: ["confirm": true])).status == 200, "free again")
        #expect(rig.backend.read { $0.calls } == ["optimize", "optimize"], "the refused request never reached the engine")
    }

    @Test func undoPutsTheSettingsBackAndNeedsNoBody() async throws {
        let rig = try await NVRRig.make()
        let url = "/api/v1/cameras/\(rig.cameraID)/optimize/undo"
        let done = await rig.session.send("POST", url)
        #expect(done.status == 204 && done.body.isEmpty)
        #expect((await rig.session.send("POST", url, json: [String: String]())).status == 204)
        #expect(rig.backend.read { $0.calls } == ["undo", "undo"])
    }

    @Test func nothingToUndoOrAFailureIsExplained() async throws {
        let rig = try await NVRRig.make()
        let url = "/api/v1/cameras/\(rig.cameraID)/optimize/undo"
        rig.backend.write { $0.undoError = EngineError.cameraNotRunning }
        let nothing = await rig.session.send("POST", url)
        #expect(nothing.status == 422 && nothing.json["error"] as? String == "optimize_failed" && nothing.json["message"] as? String == "There is nothing to undo for this camera.")
        rig.backend.write { $0.undoError = EngineError.configurationUnavailable("disk") }
        #expect((await rig.session.send("POST", url)).status == 422)
        rig.backend.write { $0.undoError = EngineError.unknownCamera }
        #expect((await rig.session.send("POST", url)).status == 404)
    }
}

/// The two backend requirements the routes use, on the fake and on the engine's backend.
@Suite(.timeLimit(.minutes(1))) struct NVROptimizeSeamTests {
    @Test func theFakeBackendRecordsTheOptimizerCalls() async throws {
        let backend = FakeBackend()
        let report = HomeKitReadinessReport(checks: [])
        backend.write { $0.optimization = .success(HomeKitOptimizationResult(before: report, after: report, canUndo: false)) }
        let result = try await backend.optimizeForHomeKit(cameraID: UUID())
        #expect(result.canUndo == false && result.before.score == 100)
        try await backend.undoHomeKitOptimization(cameraID: UUID())
        #expect(backend.read { $0.calls } == ["optimize", "undo"])
        backend.write { $0.undoError = EngineError.cameraNotRunning }
        await #expect(throws: EngineError.cameraNotRunning) { try await backend.undoHomeKitOptimization(cameraID: UUID()) }
    }

    @MainActor @Test func theEngineBackendForwardsToTheEngine() async throws {
        let backend = EngineBackend(engine: BridgeEngine.preview(scenario: .empty))
        await #expect(throws: EngineError.cameraNotRunning) { _ = try await backend.optimizeForHomeKit(cameraID: UUID()) }   // a preview engine's operations do nothing
        await #expect(throws: EngineError.cameraNotRunning) { try await backend.undoHomeKitOptimization(cameraID: UUID()) }
    }
}
