import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
@testable import BridgeWeb

/// `GET /nvr/cameras/:id/fragments` (contract C.5 R7).
@Suite(.timeLimit(.minutes(1))) struct NVRFragmentPlanAPITests {
    private func plan(_ rig: NVRRig, at offset: Int64, ahead: Int? = nil) async -> Answer {
        await rig.get("nvr/cameras/\(rig.cameraID)/fragments?at=\(rig.ms(offset))" + (ahead.map { "&ahead=\($0)" } ?? ""))
    }

    private func ids(_ answer: Answer) -> [String] { answer.array("parts").compactMap { $0["id"] as? String } }

    @Test func aTimeInsideAGroupOfPicturesListsFromTheKeyframeAndThenWhatFollows() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 6, gopFragments: 3)   // keyframes in fragments 0 and 3; each fragment is 1 s
        archive.files = [file]
        let answer = await plan(rig, at: 2_500)   // inside fragment 2, the last of the first group
        #expect(answer.status == 200)
        #expect(Set(answer.json.keys) == ["serverTime", "found", "at", "exact", "targetIndex", "parts", "files"])
        #expect(answer.json["found"] as? Bool == true && answer.json["exact"] as? Bool == true)
        #expect(answer.int("at") == rig.ms(2_500) && answer.int("targetIndex") == 2)
        #expect(ids(answer) == file.fragments.prefix(5).map(\.id), "fragments 0, 1, 2 (lead-in) and 3, 4 (the two that follow)")
        let parts = answer.array("parts")
        #expect(parts.map { $0["key"] as? Bool } == [true, false, false, true, false])
        #expect(parts.map { jsonInt($0["start"]) } == (0..<5).map { rig.ms(Int64($0) * 1_000) })
        #expect(parts.map { jsonInt($0["end"]) } == (1...5).map { rig.ms(Int64($0) * 1_000) }, "each part ends where the next begins")
        #expect(parts.map { $0["file"] as? String } == Array(repeating: file.fileKey, count: 5))
        #expect(parts.map { jsonInt($0["bytes"]).map { Int($0) } } == file.fragments.prefix(5).map { $0.byteLength - 32 })
        #expect(parts.first.map { Set($0.keys) } == ["id", "file", "start", "end", "bytes", "key"])
        let info = try #require(answer.object("files")[file.fileKey] as? [String: Any])
        #expect(Set(info.keys) == ["mime", "width", "height", "anchor", "initId", "sound"])
        #expect(info["mime"] as? String == ArchiveFixture.mimeOfTheStream && info["width"] as? Int == 640 && info["height"] as? Int == 360)
        #expect(info["anchor"] as? Double == Double(NVRRig.base) && info["initId"] as? String == file.fragments[0].id && info["sound"] as? Bool == false)
    }

    @Test func aTimeInsideAKeyFragmentNeedsNoLeadIn() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file(fragments: 4, gopFragments: 1)]
        let answer = await plan(rig, at: 1_000, ahead: 0)   // exactly the start of fragment 1: `start <= t < end`
        #expect(ids(answer) == [archive.files[0].fragments[1].id] && answer.int("targetIndex") == 0)
        let defaults = await plan(rig, at: 1_000)
        #expect(ids(defaults) == archive.files[0].fragments[1...3].map(\.id), "ahead defaults to 2")
        let most = await plan(rig, at: 0, ahead: 16)
        #expect(ids(most).count == 4, "no more than the file holds")
    }

    @Test func theLookAheadCrossesIntoTheNextFile() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let first = try rig.file("13-24-05", fragments: 2), second = try rig.file("13-24-07", offsetMs: 2_000, fragments: 2)
        archive.files = [first, second]
        let answer = await plan(rig, at: 1_200, ahead: 2)
        #expect(ids(answer) == [first.fragments[1].id, second.fragments[0].id, second.fragments[1].id])
        #expect(Set(answer.object("files").keys) == [first.fileKey, second.fileKey])
        let initIds = answer.object("files").mapValues { ($0 as? [String: Any])?["initId"] as? String }
        #expect(initIds[first.fileKey] == first.fragments[1].id && initIds[second.fileKey] == second.fragments[0].id, "the first listed part of each file")
    }

    @Test func aLeadInOfMoreThanSixtyFourPartsIsNotOfferedOnlyTheKeyFragment() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 70, framesPerFragment: 2, gopFragments: 70)
        archive.files = [file]
        let long = await plan(rig, at: 66 * 80)   // fragment 66 (80 ms each at 2 frames of 25 fps)
        #expect(long.json["exact"] as? Bool == false && ids(long) == [file.fragments[0].id] && long.int("targetIndex") == 0)
        let fits = await plan(rig, at: 63 * 80, ahead: 0)
        #expect(fits.json["exact"] as? Bool == true && ids(fits).count == 64 && fits.int("targetIndex") == 63, "64 parts is still offered")
    }

    @Test func aTimeWithNoRecordingSaysWhyAndWhenTheNextOneIs() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let empty = await plan(rig, at: 0)
        #expect(empty.status == 200 && empty.json["found"] as? Bool == false && empty.json["reason"] as? String == "empty")
        #expect(empty.json["next"] is NSNull && empty.json["newest"] is NSNull)
        #expect(Set(empty.json.keys) == ["serverTime", "found", "at", "reason", "next", "newest"])
        archive.files = [try rig.file("13-24-05", fragments: 2), try rig.file("13-24-20", offsetMs: 15_000, fragments: 2)]
        let before = await plan(rig, at: -5_000)
        #expect(before.json["reason"] as? String == "beforeStart" && before.int("newest") == rig.ms(17_000))
        let gap = await plan(rig, at: 5_000)
        #expect(gap.json["reason"] as? String == "gap" && gap.int("next") == rig.ms(15_000) && gap.int("newest") == rig.ms(17_000))
        let end = await plan(rig, at: 17_000)
        #expect(end.json["reason"] as? String == "afterEnd" && end.json["next"] is NSNull, "at the end of the newest fragment is after the end")
        let other = await rig.get("nvr/cameras/\(UUID().uuidString)/fragments?at=\(rig.ms(0))")
        #expect(other.json["reason"] as? String == "empty", "an unknown camera looks like one with no recordings")
    }

    @Test func aTimeOnAnArchiveDriveThatIsAwaySaysSoAndWhereVideoPlaysAgain() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        // From 5 s to 10 s the recordings are on the archive drive, which is unplugged (the store answers no fragment there); before and after, the box's play.
        archive.files = [try rig.file("13-24-05", fragments: 2), try rig.file("13-24-20", offsetMs: 15_000, fragments: 2)]
        let date = { (offset: Int64) in Date(timeIntervalSince1970: Double(rig.ms(offset)) / 1_000) }
        archive.setAway(DateInterval(start: date(5_000), end: date(10_000)), camera: rig.camera.id)
        let away = await plan(rig, at: 6_000)
        #expect(away.status == 200 && away.json["found"] as? Bool == false && away.json["reason"] as? String == "archiveAway")
        #expect(away.int("next") == rig.ms(15_000), "where the next video that plays now begins")
        #expect(Set(away.json.keys) == ["serverTime", "found", "at", "reason", "next", "newest"])
        let gap = await plan(rig, at: 12_000)
        #expect(gap.json["reason"] as? String == "gap", "after the away stretch it is a gap again")
        #expect(await plan(rig, at: 1_000).json["found"] as? Bool == true)
    }

    @Test func aPartThatRetentionRemovedWhileAskingIsGone() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 4, gopFragments: 4)
        archive.files = [file]
        archive.remove(file.fragments[0].id)   // the keyframe of the group that contains fragment 2
        let answer = await plan(rig, at: 2_500)
        #expect(answer.status == 410 && answer.json["error"] as? String == "gone")
        archive.remove(file.fragments[1].id)
        #expect((await plan(rig, at: 3_500)).status == 410, "so is a hole in the middle of the lead-in")
    }

    @Test func afterListsTheFollowingPartsAcrossGapsAndFilesEachOnce() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        // A file, a second one that begins 0.4 ms before the first ends, and a third after a 300 ms gap (29.97 fps frames).
        let first = try rig.file("13-24-05", fragments: 3, framesPerFragment: 30, frameTicks: 3_003)
        let firstSpan: Double = 3 * 30 * 3_003 / 90   // 3,003 ms
        let secondStart = Double(NVRRig.base) + firstSpan - 0.4, thirdStart = secondStart + firstSpan + 300
        let second = try ArchiveFixture.file(camera: rig.camera.id, segment: "\(rig.cameraID)/2026-09-14/13-24-08", startMs: secondStart, fragments: 3, framesPerFragment: 30, frameTicks: 3_003)
        let third = try ArchiveFixture.file(camera: rig.camera.id, segment: "\(rig.cameraID)/2026-09-14/13-24-20", startMs: thirdStart, fragments: 2, framesPerFragment: 30, frameTicks: 3_003)
        archive.files = [first, second, third]
        let all = [first, second, third].flatMap(\.fragments)
        let answer = await rig.get("nvr/cameras/\(rig.cameraID)/fragments?after=\(first.fragments[0].id)&limit=64")
        #expect(answer.status == 200 && Set(answer.json.keys) == ["serverTime", "parts", "files"])
        #expect(ids(answer) == all.dropFirst().map(\.id), "every later fragment once, in order")
        #expect(Set(answer.object("files").keys) == [first.fileKey, second.fileKey, third.fileKey])
        let limited = await rig.get("nvr/cameras/\(rig.cameraID)/fragments?after=\(first.fragments[0].id)&limit=3")
        #expect(ids(limited) == all[1...3].map(\.id))
        let default8 = await rig.get("nvr/cameras/\(rig.cameraID)/fragments?after=\(all[0].id)")
        #expect(ids(default8).count == 7 && ids(default8) == all[1...7].map(\.id), "limit defaults to 8 in all")
        let none = await rig.get("nvr/cameras/\(rig.cameraID)/fragments?after=\(all.last!.id)")
        #expect(none.status == 200 && ids(none).isEmpty && none.object("files").isEmpty, "nothing new is an empty list")
        let gone = await rig.get("nvr/cameras/\(rig.cameraID)/fragments?after=aaaaaaaaaaaa.3")
        #expect(gone.status == 410 && gone.json["error"] as? String == "gone")
    }

    @Test func aPartStartsWhereTheTfdtInItsServedBytesPutsItGivenTheFilesAnchor() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file("13-24-05", fragments: 6, framesPerFragment: 15, frameTicks: 3_003, gopFragments: 3, audio: true),
                         try rig.file("13-24-20", offsetMs: 20_000, fragments: 6, framesPerFragment: 15, frameTicks: 3_003, gopFragments: 3)]
        let answer = await rig.get("nvr/cameras/\(rig.cameraID)/fragments?at=\(rig.ms(0))&ahead=16")
        let parts = answer.array("parts"), files = answer.object("files")
        #expect(parts.count == 12 && files.count == 2)
        for part in parts {
            let id = try #require(part["id"] as? String), key = try #require(part["file"] as? String)
            let file = try #require(files[key] as? [String: Any])
            let bytes = await rig.get("nvr/cameras/\(rig.cameraID)/fragments/\(id)").body
            let tfdt = try #require(try baseMediaDecodeTime(in: bytes))
            let anchor = try #require(file["anchor"] as? Double)
            #expect(Int64((anchor + Double(tfdt) / 90).rounded()) == jsonInt(part["start"]), "\(id): start is anchor + tfdt / 90")
        }
    }

    @Test func everyPartOfAThirtyFpsStreamAbutsTheNext() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file(fragments: 40, framesPerFragment: 15, frameTicks: 3_003, gopFragments: 4)]
        let answer = await rig.get("nvr/cameras/\(rig.cameraID)/fragments?after=\(archive.files[0].fragments[0].id)&limit=39")
        let parts = answer.array("parts")
        try #require(parts.count == 39)
        let starts = parts.map { jsonInt($0["start"]) ?? 0 }, ends = parts.map { jsonInt($0["end"]) ?? 0 }
        #expect(Array(ends.dropLast()) == Array(starts.dropFirst()), "end of each part is the start of the next, with no 1 ms gaps from rounding")
    }

    @Test func badParametersAreRefusedAndMakeNoRead() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file()]
        let id = archive.files[0].fragments[0].id
        let base = "nvr/cameras/\(rig.cameraID)/fragments"
        let cases: [(String, String)] = [
            (base, "at"), (base + "?ahead=2", "at"), (base + "?at=\(rig.ms(0))&after=\(id)", "after"), (base + "?at=abc", "at"), (base + "?at=12", "at"),
            (base + "?at=\(rig.ms(0))&ahead=17", "ahead"), (base + "?at=\(rig.ms(0))&ahead=-1", "ahead"), (base + "?at=\(rig.ms(0))&ahead=x", "ahead"),
            (base + "?after=nope", "after"), (base + "?after=ABCDEF012345.1", "after"), (base + "?after=aaaaaaaaaaaa.01", "after"), (base + "?after=aaaaaaaaaaaa.12345678", "after"),
            (base + "?after=\(id)&limit=0", "limit"), (base + "?after=\(id)&limit=65", "limit"), (base + "?after=\(id)&limit=1.5", "limit"),
        ]
        for (path, field) in cases {
            let answer = await rig.get(path)
            #expect(answer.status == 400 && answer.json["error"] as? String == "invalid" && answer.json["field"] as? String == field, "\(path) -> \(answer.text)")
        }
        #expect(archive.reads.isEmpty)
        #expect((await rig.get("nvr/cameras/not-an-id/fragments?at=\(rig.ms(0))")).status == 404, "a malformed camera id is not found")
    }

    @Test func theFileInformationIsReadOncePerFileAndRemembered() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file(fragments: 4, gopFragments: 2)]
        _ = await plan(rig, at: 500)
        _ = await plan(rig, at: 1_500)
        _ = await plan(rig, at: 2_500)
        #expect(archive.reads.filter { $0.part == .initialization }.count == 1)
        #expect(archive.reads.filter { $0.part != .initialization }.isEmpty, "planning reads no video")
        #expect(rig.harness.app.archiveState.files.count == 1)
    }

    @Test func aFileWithSoundIsPlannedAsVideoOnly() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 2, audio: true)
        archive.files = [file]
        let answer = await plan(rig, at: 0)
        let info = try #require(answer.object("files")[file.fileKey] as? [String: Any])
        #expect(info["sound"] as? Bool == true && info["mime"] as? String == ArchiveFixture.mimeOfTheStream, "the mime is the video track's")
    }

    @Test func aDriveThatDoesNotAnswerOrADamagedInitIsReportedAndNotRemembered() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 2)
        archive.files = [file]
        archive.fail(file.fragments[0].id, with: .timedOut)
        let slow = await plan(rig, at: 0)
        #expect(slow.status == 504 && slow.json["error"] as? String == "drive_slow" && slow.headers["Retry-After"] == "2")
        archive.fail(file.fragments[0].id, with: .fileGone)
        #expect((await plan(rig, at: 0)).status == 410)
        archive.fail(file.fragments[0].id, with: .unreadable("/var/lib/camera-bridge/recordings/SECRET-FILE.mp4 is short"))
        let broken = await plan(rig, at: 0)
        #expect(broken.status == 502 && broken.json["error"] as? String == "unreadable" && !broken.text.contains("SECRET") && !broken.text.contains("/var/lib"))
        #expect(rig.harness.app.archiveState.files.count == 0)
    }
}
