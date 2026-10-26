import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
@testable import BridgeWeb

/// `GET /nvr/cameras` and `GET /nvr/activity` (contract C.5 R5, R6).
@Suite(.timeLimit(.minutes(1))) struct NVRCatalogAPITests {
    @Test func theCatalogListsTheCamerasThatHaveRecordingsAndTheServersClock() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let other = CameraConfiguration(name: "Garage", kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "")
        rig.backend.write { $0.configurations.append(other) }
        archive.files = [try rig.file(fragments: 4)]
        archive.setTypicalGOP(2.5)
        archive.bumpCatalogVersion()
        let before = Date()
        let answer = await rig.get("nvr/cameras")
        #expect(answer.status == 200)
        #expect(Set(answer.json.keys) == ["serverTime", "catalogVersion", "cameras"])
        #expect(abs(Double(answer.int("serverTime") ?? 0) / 1000 - before.timeIntervalSince1970) < 5)
        #expect(answer.int("catalogVersion") == 2)
        let cameras = answer.array("cameras")
        try #require(cameras.count == 1, "a camera with no recording is left out")
        #expect(Set(cameras[0].keys) == ["id", "oldest", "newest", "typicalGOP"])
        #expect(cameras[0]["id"] as? String == rig.cameraID)
        #expect(jsonInt(cameras[0]["oldest"]) == rig.ms(0) && jsonInt(cameras[0]["newest"]) == rig.ms(4_000))
        #expect(cameras[0]["typicalGOP"] as? Double == 2.5)
        archive.setTypicalGOP(nil)
        #expect(await rig.get("nvr/cameras").array("cameras").first?["typicalGOP"] is NSNull)
    }

    @Test func aStoreThatIsStillLoadingAnswersWithARetryHintAndNothingElseSlows() async throws {
        let archive = FakeArchiveReading()
        archive.setReady(false)
        let rig = try await NVRRig.make(archive: archive)
        let answer = await rig.get("nvr/cameras")
        #expect(answer.status == 503 && answer.json["error"] as? String == "archive_unavailable" && answer.headers["Retry-After"] == "2")
        #expect((await rig.get("nvr/storage")).status == 200, "the storage routes answer from the settings")
        #expect((await rig.get("status")).status == 200)
        archive.setReady(true)
        #expect((await rig.get("nvr/cameras")).status == 200)
    }

    @Test func aBridgeWithoutAnArchiveSaysSoWithoutARetryHint() async throws {
        let rig = try await NVRRig.make(archive: nil)
        let answer = await rig.get("nvr/cameras")
        #expect(answer.status == 503 && answer.json["error"] as? String == "archive_unavailable")
        #expect(answer.headers["Retry-After"] == nil)
    }

    // MARK: Activity

    private func activityPath(_ rig: NVRRig, cameras: String? = nil, from: String? = nil, binMs: String? = "60000", bins: String? = "10") -> String {
        var query: [String] = []
        query.append("cameras=\(cameras ?? rig.cameraID)")
        if let from { query.append("from=\(from)") } else { query.append("from=\(rig.ms(0))") }
        if let binMs { query.append("binMs=\(binMs)") }
        if let bins { query.append("bins=\(bins)") }
        return "nvr/activity?" + query.joined(separator: "&")
    }

    @Test func activityIsAskedPerCameraAndAnsweredAsCoverageAndLevel() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file(fragments: 4)]
        let answer = await rig.get(activityPath(rig, from: "\(rig.ms(12_345))"))
        #expect(answer.status == 200)
        #expect(Set(answer.json.keys) == ["from", "binMs", "bins", "serverTime", "catalogVersion", "byCamera"])
        #expect(answer.int("from") == rig.ms(0), "from is snapped down to a multiple of binMs and returned")
        #expect(answer.int("binMs") == 60_000 && answer.int("bins") == 10 && answer.int("catalogVersion") == 1)
        let camera = try #require(answer.object("byCamera")[rig.cameraID] as? [String: Any])
        #expect(Set(camera.keys) == ["typical", "complete", "coverage", "level", "away"], "no peak")
        #expect(camera["away"] as? [Int] == Array(repeating: 0, count: 10), "nothing is on an archive drive that is away")
        #expect(camera["typical"] as? Double == 1_000 && camera["complete"] as? Bool == true)
        let coverage = try #require(camera["coverage"] as? [Int]), level = try #require(camera["level"] as? [Double])
        #expect(coverage.count == 10 && level.count == 10)
        #expect(coverage.first == 7, "4 s of the first 60 s, rounded to a whole percent")
        #expect(coverage.dropFirst().allSatisfy { $0 == 0 })
        #expect(level.first == 1_000 && level.dropFirst().allSatisfy { $0 == 0 })
        let call = try #require(archive.activityCalls.first)
        #expect(call.camera == rig.camera.id && call.binCount == 10)
        #expect(call.range == WebApp.date(milliseconds: rig.ms(0))..<WebApp.date(milliseconds: rig.ms(600_000)))
    }

    @Test func requestsThatAreNotWellFormedAreRefusedBeforeTheArchiveIsAsked() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let many = (0..<17).map { _ in UUID().uuidString }.joined(separator: ",")
        let cases: [(String, String)] = [
            (activityPath(rig, cameras: ""), "cameras"), (activityPath(rig, cameras: "not-an-id"), "cameras"), (activityPath(rig, cameras: rig.cameraID + ","), "cameras"),
            (activityPath(rig, cameras: many), "cameras"),
            (activityPath(rig, from: "12"), "from"), (activityPath(rig, from: "978307199999"), "from"), (activityPath(rig, from: "4102444800001"), "from"),
            (activityPath(rig, from: "-\(rig.ms(0))"), "from"), (activityPath(rig, from: "\(rig.ms(0)).5"), "from"), (activityPath(rig, from: "1234567890123456"), "from"),
            ("nvr/activity?cameras=\(rig.cameraID)&binMs=60000&bins=10", "from"),
            (activityPath(rig, binMs: "999"), "binMs"), (activityPath(rig, binMs: "86400001"), "binMs"), (activityPath(rig, binMs: "1e3"), "binMs"),
            (activityPath(rig, binMs: nil), "binMs"), (activityPath(rig, bins: "0"), "bins"), (activityPath(rig, bins: "2001"), "bins"), (activityPath(rig, bins: nil), "bins"),
            (activityPath(rig, binMs: "86400000", bins: "32"), "bins"),
        ]
        for (path, field) in cases {
            let answer = await rig.get(path)
            #expect(answer.status == 400 && answer.json["error"] as? String == "invalid" && answer.json["field"] as? String == field, "\(path) -> \(answer.text)")
        }
        #expect(archive.activityCalls.isEmpty)
        #expect((await rig.get(activityPath(rig, binMs: "86400000", bins: "31"))).status == 200, "31 days is the most")
        #expect((await rig.get(activityPath(rig, cameras: String(repeating: rig.cameraID + ",", count: 20) + rig.cameraID))).status == 200, "a camera listed twice counts once")
        #expect(archive.activityCalls.count == 2)
    }

    /// T00 R6: the list is read as camera ids, the same camera listed again (in either letter case) is collapsed, and only then is the limit of 16 applied.
    @Test func aCameraListedAgainIsOneCameraAndTheLimitOfSixteenCountsOnlyDifferentOnes() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file(fragments: 4)]
        let id = rig.cameraID
        let others = (1...16).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        func ask(_ ids: [String]) async -> Answer { await rig.get(activityPath(rig, cameras: ids.joined(separator: ","))) }
        func calls() -> [UUID] { archive.activityCalls.map(\.camera) }

        let again = await ask([id, id, id.lowercased(), id])
        #expect(again.status == 200 && Set(again.object("byCamera").keys) == [id], "the same camera four times is one camera: \(again.text)")
        #expect(calls() == [rig.camera.id], "and the archive is asked about it once")

        let seventeenCopies = await ask(Array(repeating: id, count: 17))
        #expect(seventeenCopies.status == 200 && seventeenCopies.object("byCamera").count == 1, "17 copies of one id are one camera, not 17: \(seventeenCopies.text)")

        let sixteen = await ask([id] + others.prefix(15))
        #expect(sixteen.status == 200 && sixteen.object("byCamera").count == 16, "16 different cameras are allowed: \(sixteen.text)")
        let sixteenAndRepeats = await ask([id] + others.prefix(15) + [id, others[0], others[0].lowercased()])
        #expect(sixteenAndRepeats.status == 200 && sixteenAndRepeats.object("byCamera").count == 16, "repeats do not push 16 different cameras over the limit")

        let before = archive.activityCalls.count
        let seventeen = await ask([id] + others.prefix(16))
        #expect(seventeen.status == 400 && seventeen.json["error"] as? String == "invalid" && seventeen.json["field"] as? String == "cameras", "17 different cameras are refused: \(seventeen.text)")
        let seventeenAndRepeats = await ask(([id] + others.prefix(16)) + ([id] + others.prefix(16)))
        #expect(seventeenAndRepeats.status == 400 && seventeenAndRepeats.json["field"] as? String == "cameras", "listing each of 17 cameras twice does not make them fewer")
        #expect(archive.activityCalls.count == before, "a refused list asks the archive nothing")

        for list in [id + ",," + others[0], "," + id, "\(id);\(others[0])"] {
            let answer = await rig.get(activityPath(rig, cameras: list))
            #expect(answer.status == 400 && answer.json["field"] as? String == "cameras", "an item that is not a camera id (an empty one too) refuses the whole list: \(list)")
        }
    }

    @Test func atMostFourCamerasAreAskedAtATime() async throws {
        let archive = FakeArchiveReading()
        archive.setActivityDelay(.milliseconds(40))
        let rig = try await NVRRig.make(archive: archive)
        let ids = (0..<16).map { _ in UUID().uuidString }
        let answer = await rig.get(activityPath(rig, cameras: ids.joined(separator: ",")))
        #expect(answer.status == 200 && Set(answer.object("byCamera").keys) == Set(ids))
        #expect(archive.activityCalls.count == 16)
        #expect(archive.mostActivitiesInFlight <= 4 && archive.mostActivitiesInFlight >= 2, "\(archive.mostActivitiesInFlight)")
    }

    @Test func numbersThatCannotBeWrittenAsJSONAreSanitizedAndTheShapeNeverChanges() async throws {
        let archive = FakeArchiveReading()
        archive.setActivityProvider { _, range, _ in
            ArchiveActivity(start: range.lowerBound, binDuration: 60, bins: [.init(coverage: .nan, level: .infinity, peak: 1), .init(coverage: 1.7, level: -5, peak: 0)],
                            typical: .nan, isComplete: false)
        }
        let rig = try await NVRRig.make(archive: archive)
        let answer = await rig.get(activityPath(rig, bins: "4"))
        #expect(answer.status == 200, "\(answer.text)")
        let camera = try #require(answer.object("byCamera")[rig.cameraID] as? [String: Any])
        #expect(camera["typical"] is NSNull && camera["complete"] as? Bool == false)
        #expect(camera["coverage"] as? [Int] == [0, 100, 0, 0], "padded to the bins asked for; a coverage is 0 to 100")
        #expect(camera["level"] as? [Double] == [0, 0, 0, 0])
    }

    @Test func activityTakesASlotAndAStoreThatIsNotReadyIsNotAsked() async throws {
        let archive = FakeArchiveReading()
        archive.setReady(false)
        let rig = try await NVRRig.make(archive: archive)
        let answer = await rig.get(activityPath(rig))
        #expect(answer.status == 503 && answer.headers["Retry-After"] == "2" && archive.activityCalls.isEmpty)
        #expect(rig.harness.app.archiveSlotsInUse == 0)
    }
}
