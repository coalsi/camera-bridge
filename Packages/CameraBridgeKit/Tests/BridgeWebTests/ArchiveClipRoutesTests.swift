import BridgeEngine
import Foundation
import Synchronization
import TestSupport
import Testing
@testable import BridgeWeb

/// `GET /nvr/cameras/:id/clip-plan` and `GET /nvr/cameras/:id/clip` (export-clip design, section 6): the plan is the engine's, the download has exactly
/// the planned size, and what is wrong is told in a sentence.
@Suite(.timeLimit(.minutes(1))) struct NVRClipRoutesTests {
    private func rig() async throws -> NVRRig {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file(fragments: 8, gopFragments: 2)]
        return rig
    }

    private func query(_ rig: NVRRig, _ fromMs: Int64, _ toMs: Int64, extra: String = "") -> String {
        "from=\(rig.ms(fromMs))&to=\(rig.ms(toMs))&tz=Europe/Berlin" + extra
    }

    @Test func thePlanSaysWhatTheFileWillBeBeforeAnythingIsSent() async throws {
        let rig = try await rig()
        let plan = await rig.get("nvr/cameras/\(rig.cameraID)/clip-plan?" + query(rig, 1_500, 6_000))
        #expect(plan.status == 200, "\(plan.json)")
        guard plan.status == 200 else { return }
        let parts = plan.array("parts")
        #expect(parts.count == 1 && (jsonInt(parts[0]["bytes"]) ?? 0) > 0 && (parts[0]["fileName"] as? String)?.hasSuffix(".mp4") == true)
        #expect(jsonInt(plan.json["bytes"]) == jsonInt(parts[0]["bytes"]) && plan.json["soundOmitted"] as? Bool == false)
        #expect((jsonInt(plan.json["durationMs"]) ?? 0) >= 4_000)
    }

    @Test func theDownloadIsTheMP4TheNameAndTheSizeThePlanGave() async throws {
        let rig = try await rig()
        let plan = await rig.get("nvr/cameras/\(rig.cameraID)/clip-plan?" + query(rig, 1_500, 6_000))
        let planned = try #require(jsonInt(plan.json["bytes"]))
        let response = await rig.harness.raw("GET", "/api/v1/nvr/cameras/\(rig.cameraID)/clip?" + query(rig, 1_500, 6_000, extra: "&part=1"), cookie: rig.session.cookie)
        #expect(response.status == 200)
        guard case .stream(let body) = response.body else { Issue.record("the clip is not a stream"); return }
        let collected = Box(Data())
        try await body(ResponseStream { data in collected.update { $0.append(data) } })
        let file = collected.value
        #expect(Int64(file.count) == planned, "exactly the planned number of bytes")
        #expect(Array(file.prefix(8).suffix(4)) == Array("ftyp".utf8) && file.count > 1_000)
        #expect(response.headers["Content-Type"] == "video/mp4" && response.headers["Cache-Control"] == "no-store")
        #expect(response.headers["Content-Disposition"]?.hasPrefix("attachment; filename=\"") == true && response.headers["Content-Disposition"]?.contains("filename*=UTF-8''") == true)
    }

    @Test func badRequestsAndNothingRecordedAreAnsweredInWords() async throws {
        let rig = try await rig()
        let id = rig.cameraID
        #expect(await rig.get("nvr/cameras/\(id)/clip-plan?from=\(rig.ms(2_000))&to=\(rig.ms(1_000))").status == 400, "the end before the start")
        #expect(await rig.get("nvr/cameras/\(id)/clip-plan?from=x&to=\(rig.ms(1_000))").status == 400)
        #expect(await rig.get("nvr/cameras/\(id)/clip-plan?" + "from=\(rig.ms(1_000))&to=\(rig.ms(3_000))&tz=Nowhere/Land").status == 400)
        #expect(await rig.get("nvr/cameras/\(UUID().uuidString)/clip-plan?" + query(rig, 1_000, 3_000)).status == 404, "no such camera")
        let far = await rig.get("nvr/cameras/\(id)/clip-plan?from=\(rig.ms(9_000_000))&to=\(rig.ms(9_005_000))")
        #expect(far.status == 404 && (far.json["message"] as? String) == "Nothing was recorded in this time.")
        #expect(await rig.get("nvr/cameras/\(id)/clip?" + query(rig, 1_500, 6_000, extra: "&part=7")).status == 404, "a part the plan does not have")
    }

    @Test func theNameInTheHeaderCannotCarryAnythingButAName() {
        let header = WebApp.attachment("Back\"yard/..\\x\n é 2026.mp4")
        #expect(header.hasPrefix("attachment; filename=\"") && !header.dropFirst(22).prefix(while: { $0 != "\"" }).contains("/"))
        #expect(!header.contains("\n") && !header.contains("\r") && header.contains("filename*=UTF-8''"))
    }
}
