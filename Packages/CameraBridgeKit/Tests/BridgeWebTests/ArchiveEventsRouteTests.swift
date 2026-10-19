import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
@testable import BridgeWeb

/// `GET /nvr/events` (docs/linux/ARCHITECTURE.md): the cameras' events the archive keeps, newest first, capped, gated and admitted like the other
/// archive routes.
@Suite(.timeLimit(.minutes(1))) struct NVREventsAPITests {
    private func path(_ rig: NVRRig, cameras: String? = nil, from: Int64? = nil, to: Int64? = nil, limit: String? = nil) -> String {
        var query = ["cameras=\(cameras ?? rig.cameraID)", "from=\(from ?? rig.ms(0))", "to=\(to ?? rig.ms(3_600_000))"]
        if let limit { query.append("limit=\(limit)") }
        return "nvr/events?" + query.joined(separator: "&")
    }

    private func event(_ rig: NVRRig, _ id: String, _ kind: String, at offsetMs: Int64, endsAfter: Int64? = nil, recorded: Bool = true, camera: UUID? = nil,
                       description: EventDescription? = nil) -> ArchiveEvent {
        let start = Date(timeIntervalSince1970: Double(rig.ms(offsetMs)) / 1_000)
        return ArchiveEvent(id: id, camera: camera ?? rig.camera.id, kind: kind, start: start, end: endsAfter.map { start.addingTimeInterval(Double($0) / 1_000) },
                            hadVideo: recorded, recorded: recorded, description: description)
    }

    @Test func theEventsOfTheRangeComeNewestFirstWithTheirEndsAndWhetherTheyAreRecorded() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let other = UUID()
        archive.setEvents([
            event(rig, "a", "Motion", at: 1_000, endsAfter: 9_000),
            event(rig, "b", "Person", at: 60_000, recorded: false),
            event(rig, "c", "Doorbell ring", at: 120_000, endsAfter: 0),
            event(rig, "d", "Motion", at: 7_200_000),                 // after the range
            event(rig, "e", "Motion", at: 2_000, camera: other),      // a camera not asked for
        ])
        let before = Date()
        let answer = await rig.get(path(rig))
        #expect(answer.status == 200 && answer.headers["Cache-Control"] == "no-store")
        #expect(Set(answer.json.keys) == ["from", "to", "serverTime", "more", "events"])
        #expect(answer.int("from") == rig.ms(0) && answer.int("to") == rig.ms(3_600_000) && answer.json["more"] as? Bool == false)
        #expect(abs(Double(answer.int("serverTime") ?? 0) / 1000 - before.timeIntervalSince1970) < 5)
        let events = answer.array("events")
        #expect(events.map { $0["id"] as? String } == ["c", "b", "a"])
        #expect(Set(events[0].keys) == ["id", "cameraID", "kind", "start", "end", "recorded", "description"])
        #expect(events.allSatisfy { $0["description"] is NSNull }, "no description: null, the key is always there")
        #expect(events[0]["cameraID"] as? String == rig.cameraID && events[0]["kind"] as? String == "Doorbell ring")
        #expect(jsonInt(events[2]["start"]) == rig.ms(1_000) && jsonInt(events[2]["end"]) == rig.ms(10_000))
        #expect(events[1]["end"] is NSNull && events[1]["recorded"] as? Bool == false && events[2]["recorded"] as? Bool == true)
        let call = try #require(archive.eventCalls.last)
        #expect(call.cameras == [rig.camera.id] && call.limit == 200, "200 when no limit is given")
        #expect(call.range == Date(timeIntervalSince1970: Double(rig.ms(0)) / 1_000)..<Date(timeIntervalSince1970: Double(rig.ms(3_600_000)) / 1_000))
    }

    @Test func theEventsRouteCarriesTheDescription() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let described = EventDescription(summary: "A person in a red jacket at the door", kind: .person, concern: .unusual, model: "claude-haiku-4-5",
                                         at: Date(timeIntervalSince1970: Double(rig.ms(5_000)) / 1_000))
        let nothing = EventDescription(summary: EventDescription.nothingNotable, kind: .nothing, concern: .routine, model: "claude-haiku-4-5",
                                       at: Date(timeIntervalSince1970: Double(rig.ms(65_000)) / 1_000))
        archive.setEvents([
            event(rig, "a", "Person", at: 1_000, description: described),
            event(rig, "b", "Motion", at: 60_000, description: nothing),
            event(rig, "c", "Motion", at: 120_000),
        ])
        let answer = await rig.get(path(rig))
        #expect(answer.status == 200)
        let events = answer.array("events")
        #expect(events.map { $0["id"] as? String } == ["c", "b", "a"])
        #expect(events[0]["description"] is NSNull)
        let shown = try #require(events[2]["description"] as? [String: Any])
        #expect(Set(shown.keys) == ["summary", "kind", "concern"], "the model and the time stay on the box")
        #expect(shown["summary"] as? String == "A person in a red jacket at the door" && shown["kind"] as? String == "person" && shown["concern"] as? String == "unusual")
        let quiet = try #require(events[1]["description"] as? [String: Any])
        #expect(quiet["summary"] as? String == "Nothing notable" && quiet["kind"] as? String == "nothing" && quiet["concern"] as? String == "routine")
    }

    @Test func aLimitCutsTheOldestOffAndSaysThereIsMore() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.setEvents((0..<5).map { event(rig, "e\($0)", "Motion", at: Int64($0) * 60_000) })
        let answer = await rig.get(path(rig, limit: "2"))
        #expect(answer.array("events").map { $0["id"] as? String } == ["e4", "e3"] && answer.json["more"] as? Bool == true)
        let rest = await rig.get(path(rig, to: rig.ms(180_000), limit: "1000"))
        #expect(rest.array("events").map { $0["id"] as? String } == ["e2", "e1", "e0"] && rest.json["more"] as? Bool == false, "asked again below the oldest")
    }

    @Test func badQueriesAreRefusedBeforeASlotIsTaken() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let cases: [(String, String)] = [
            ("nvr/events?cameras=\(rig.cameraID)&to=\(rig.ms(1))", "from"),
            ("nvr/events?cameras=\(rig.cameraID)&from=\(rig.ms(0))", "to"),
            (path(rig, from: rig.ms(5_000), to: rig.ms(5_000)), "to"),
            (path(rig, from: rig.ms(0), to: rig.ms(32 * 86_400_000)), "to"),
            (path(rig, limit: "0"), "limit"),
            (path(rig, limit: "1001"), "limit"),
            (path(rig, limit: "ten"), "limit"),
            (path(rig, cameras: "not-a-camera"), "cameras"),
            (path(rig, cameras: ""), "cameras"),
            (path(rig, cameras: (0..<17).map { _ in UUID().uuidString }.joined(separator: ",")), "cameras"),
        ]
        for (query, field) in cases {
            let answer = await rig.get(query)
            #expect(answer.status == 400 && answer.json["error"] as? String == "invalid" && answer.json["field"] as? String == field, "\(query)")
        }
        #expect(archive.eventCalls.isEmpty)
        let same = await rig.get(path(rig, cameras: "\(rig.cameraID),\(rig.cameraID.lowercased())"))
        #expect(same.status == 200 && archive.eventCalls.last?.cameras == [rig.camera.id], "the same camera twice is one")
    }

    @Test func theRouteIsGatedAndAdmittedLikeTheOtherArchiveRoutes() async throws {
        let none = try await NVRRig.make(archive: nil)
        #expect((await none.get(path(none))).status == 503)

        let archive = FakeArchiveReading()
        archive.setReady(false)
        let rig = try await NVRRig.make(archive: archive)
        let loading = await rig.get(path(rig))
        #expect(loading.status == 503 && loading.json["error"] as? String == "archive_unavailable" && loading.headers["Retry-After"] == "2")
        archive.setReady(true)

        let app = rig.harness.app
        let total = app.configuration.maximumArchiveReads
        var taken = 0
        for index in 0..<total where app.takeArchiveSlot(address: "192.0.2.\(100 + index)") { taken += 1 }
        let busy = await rig.get(path(rig))
        #expect(busy.status == 429 && busy.json["error"] as? String == "busy" && busy.headers["Retry-After"] == "1")
        for index in 0..<taken { app.releaseArchiveSlot(address: "192.0.2.\(100 + index)") }

        archive.failEvents(with: ArchiveError.timedOut)
        let slow = await rig.get(path(rig))
        #expect(slow.status == 504 && slow.json["error"] as? String == "drive_slow")
        archive.failEvents(with: nil)
        #expect((await rig.get(path(rig))).status == 200 && app.archiveSlotsInUse == 0)
    }

    /// The Monitor keeps an answered range for good: an archive that cannot say now must answer "try again", never an empty page.
    @Test func anArchiveThatCannotSayNowIsUnavailableWithRetryAfterNotEmpty() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.setEvents([event(rig, "a", "Motion", at: 1_000)])
        for (failure, retry) in [(ArchiveUnavailable.loading, "2"), (ArchiveUnavailable.folderMissing, "5")] {
            archive.failEvents(with: failure)
            let answer = await rig.get(path(rig))
            #expect(answer.status == 503 && answer.json["error"] as? String == "archive_unavailable" && answer.headers["Retry-After"] == retry, "\(failure)")
            #expect(answer.json["events"] == nil && rig.harness.app.archiveSlotsInUse == 0)
        }
        archive.failEvents(with: nil)
        let back = await rig.get(path(rig))
        #expect(back.status == 200 && back.array("events").map { $0["id"] as? String } == ["a"])
    }
}
