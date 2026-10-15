import BridgeEngine
import BridgeSupport
import FMP4
import Foundation
import Testing
@testable import BridgeWeb

/// `GET /nvr/cameras/:id/fragments/:fid`, `.../init` and `GET /nvr/cameras/:id/keyframe` (contract C.5 R8 to R10): the bytes a browser feeds to a
/// MediaSource, checked against what the recorder's muxer wrote.
@Suite(.serialized, .timeLimit(.minutes(1))) struct NVRMediaAPITests {
    private func path(_ rig: NVRRig, _ fragment: ArchiveFragment, _ suffix: String = "") -> String {
        "nvr/cameras/\(rig.cameraID)/fragments/\(fragment.id)\(suffix)"
    }

    private func u32(_ data: Data, _ offset: Int) -> Int {
        (0..<4).reduce(0) { $0 << 8 | Int(data[data.startIndex + offset + $1]) }
    }

    @Test func aVideoOnlyFragmentIsServedAsStoredMinusItsProducerReferenceTime() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 6, framesPerFragment: 15, frameTicks: 3_003, gopFragments: 3)
        archive.files = [file]
        for (index, fragment) in file.fragments.enumerated() {
            let stored = file.stored[index]
            #expect(u32(stored, 0) == 32 && String(decoding: stored.prefix(8).suffix(4), as: UTF8.self) == "prft", "the muxer wrote a 32-byte prft first")
            let answer = await rig.get(path(rig, fragment))
            #expect(answer.status == 200 && answer.headers["Content-Type"] == "video/mp4" && answer.headers["Cache-Control"] == "no-store")
            #expect(answer.body == stored.dropFirst(32), "fragment \(index) is exactly the stored moof + mdat")
            #expect(String(decoding: answer.body.prefix(8).suffix(4), as: UTF8.self) == "moof")
        }
        #expect(archive.reads.allSatisfy { $0.part == .fragment })
    }

    @Test func aFragmentOfAFileWithSoundIsServedWithoutTheSound() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 3, audio: true)
        archive.files = [file]
        for (index, fragment) in file.fragments.enumerated() {
            let stored = try MP4BoxReader.parse(file.stored[index].dropFirst(32))
            #expect(stored.first { $0.type == "moof" }?.children(ofType: "traf").count == 2, "the stored fragment has a video and an audio track fragment")
            let answer = await rig.get(path(rig, fragment))
            #expect(answer.status == 200)
            let boxes = try MP4BoxReader.parse(answer.body)
            #expect(boxes.map(\.type) == ["moof", "mdat"], "no prft")
            let moof = try #require(boxes.first), mdat = try #require(boxes.last)
            #expect(moof.children(ofType: "traf").count == 1)
            #expect(mdat.payloadSize == file.videoBytes[index], "the video samples only")
            let trun = try #require(moof.child("traf")?.child("trun"))
            #expect(u32(answer.body, trun.payloadOffset + 8) == moof.size + 8, "the data offset points at the first video sample")
            #expect(answer.body.count < file.stored[index].count - 32)
        }
    }

    @Test func theInitSegmentIsTheFilesOwnOrItsVideoTrackAlone() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let plain = try rig.file("13-24-05", fragments: 2), withSound = try rig.file("13-24-10", offsetMs: 5_000, fragments: 2, audio: true)
        archive.files = [plain, withSound]
        let own = await rig.get(path(rig, plain.fragments[1], "/init"))
        #expect(own.status == 200 && own.headers["Content-Type"] == "video/mp4" && own.body == plain.initData, "a file without sound: its init, unchanged")
        let video = await rig.get(path(rig, withSound.fragments[0], "/init"))
        #expect(video.status == 200)
        let boxes = try MP4BoxReader.parse(video.body)
        #expect(boxes.map(\.type) == ["ftyp", "moov"])
        let moov = try #require(boxes.last)
        #expect(moov.children(ofType: "trak").count == 1 && moov.child("mvex")?.children(ofType: "trex").count == 1)
        #expect(moov.descendant(atPath: "trak/mdia/minf/stbl/stsd/avc1") != nil)
    }

    @Test func headIsRefusedOnEveryMediaRouteBeforeAnythingIsRead() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file()
        archive.files = [file]
        let paths = [path(rig, file.fragments[0]), path(rig, file.fragments[0], "/init"), "nvr/cameras/\(rig.cameraID)/keyframe?at=\(rig.ms(500))"]
        for path in paths {
            let answer = await rig.session.send("HEAD", "/api/v1/\(path)")
            #expect(answer.status == 405 && answer.json["error"] as? String == "method_not_allowed" && answer.headers["Allow"] == "GET", "\(path)")
        }
        #expect(archive.reads.isEmpty && rig.harness.app.archiveSlotsInUse == 0)
        #expect((await rig.session.send("HEAD", "/api/v1/nvr/storage")).status == 200, "a route that reads no video still answers HEAD")
    }

    @Test func aPartThatIsGoneOrUnknownIs410AndAMalformedIdIs400() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file()
        archive.files = [file]
        archive.remove(file.fragments[1].id)
        for suffix in ["", "/init"] {
            #expect((await rig.get(path(rig, file.fragments[1], suffix))).status == 410, "removed by retention")
            #expect((await rig.get("nvr/cameras/\(rig.cameraID)/fragments/aaaaaaaaaaaa.0\(suffix)")).status == 410, "never existed")
            #expect((await rig.get("nvr/cameras/\(UUID().uuidString)/fragments/\(file.fragments[0].id)\(suffix)")).status == 410, "another camera's part")
            for bad in ["nope", "AAAAAAAAAAAA.1", "aaaaaaaaaaaa.-1", "aaaaaaaaaaaa.", "aaaaaaaaaaaa.00", "aaaaaaaaaaaa.88888888", "..%2F..%2Fetc", "aaaaaaaaaaaa.1%00"] {
                let answer = await rig.get("nvr/cameras/\(rig.cameraID)/fragments/\(bad)\(suffix)")
                #expect(answer.status == 400 && answer.json["field"] as? String == "fid", "\(bad)")
            }
        }
        #expect((await rig.get("nvr/cameras/not-an-id/fragments/\(file.fragments[0].id)")).status == 404)
        #expect(archive.reads.isEmpty, "nothing was read for any of those")
    }

    @Test func theArchivesFailuresBecomeOneKindOfAnswerEach() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 4)
        archive.files = [file]
        archive.fail(file.fragments[0].id, with: .fileGone)
        archive.fail(file.fragments[1].id, with: .timedOut)
        archive.fail(file.fragments[2].id, with: .unreadable("/var/lib/camera-bridge/recordings/SECRET-CAMERA/2026-09-14/13-24-05.mp4: short read"))
        archive.fail(file.fragments[3].id, with: .noKeyframe)
        let expected: [(Int, String, Int)] = [(0, "gone", 410), (1, "drive_slow", 504), (2, "unreadable", 502), (3, "unreadable", 502)]
        for (index, code, status) in expected {
            for suffix in ["", "/init"] {
                let answer = await rig.get(path(rig, file.fragments[index], suffix))
                #expect(answer.status == status && answer.json["error"] as? String == code, "\(index)\(suffix) -> \(answer.text)")
                #expect(!answer.text.contains("SECRET") && !answer.text.contains("/var/lib") && !answer.text.contains(".mp4"), "no path in \(answer.text)")
            }
        }
        let slow = await rig.get(path(rig, file.fragments[1]))
        #expect(slow.headers["Retry-After"] == "2")
        #expect(rig.harness.app.archiveSlotsInUse == 0, "every slot was released")
    }

    @Test func aDamagedFragmentIsUnreadableForItselfAndNeighboursStillPlay() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 3)
        archive.files = [file]
        archive.corrupt(file.fragments[1].id)
        let broken = await rig.get(path(rig, file.fragments[1]))
        #expect(broken.status == 502 && broken.json["error"] as? String == "unreadable")
        let before = await rig.get(path(rig, file.fragments[0])), after = await rig.get(path(rig, file.fragments[2]))
        #expect(before.status == 200 && after.status == 200)
    }

    @Test func anUnreadableFileIsLoggedOnceWithoutTextFromTheFile() async throws {
        let capture = LogCapture()
        defer { capture.stop() }
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let first = try rig.file("13-24-05", fragments: 3), second = try rig.file("13-24-30", offsetMs: 60_000, fragments: 2)
        archive.files = [first, second]
        for fragment in first.fragments + second.fragments { archive.fail(fragment.id, with: .unreadable("/var/lib/camera-bridge/recordings/SECRET/x.mp4")) }
        for fragment in first.fragments { _ = await rig.get(path(rig, fragment)) }
        _ = await rig.get(path(rig, second.fragments[0]))
        _ = await rig.get(path(rig, second.fragments[1]))
        let lines = capture.text.filter { $0.contains("can’t be read") }
        #expect(lines.count == 2, "one line per file: \(lines)")
        #expect(lines.contains { $0.contains(first.fileKey) } && lines.contains { $0.contains(second.fileKey) })
        #expect(capture.text.allSatisfy { !$0.contains("SECRET") && !$0.contains("/var/lib") }, "nothing from the file or its path is logged")
    }

    @Test func anAnswerLargerThanTheLimitIsRefused() async throws {
        let archive = FakeArchiveReading()
        let sample = try ArchiveFixture.file(camera: UUID(), segment: "\(UUID().uuidString)/2026-09-14/13-24-05", startMs: Double(NVRRig.base), fragments: 1)
        let limit = sample.initData.count + 10   // the init fits, a fragment does not
        #expect(sample.stored[0].count - 32 > limit)
        let rig = try await NVRRig.make(archive: archive) { $0.maximumSegmentBytes = limit }
        let file = try rig.file(fragments: 2)
        archive.files = [file]
        #expect((await rig.get(path(rig, file.fragments[0], "/init"))).status == 200)
        let answer = await rig.get(path(rig, file.fragments[0]))
        #expect(answer.status == 502 && answer.json["error"] as? String == "unreadable")
        let key = await rig.get("nvr/cameras/\(rig.cameraID)/keyframe?at=\(rig.ms(100))")
        #expect(key.status == 502 && key.json["error"] as? String == "unreadable")
    }

    // MARK: Keyframe

    @Test func theKeyFragmentOfTheGroupContainingATimeComesWithItsDescription() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 6, gopFragments: 3)
        archive.files = [file]
        let answer = await rig.get("nvr/cameras/\(rig.cameraID)/keyframe?at=\(rig.ms(4_400))")   // inside fragment 4; its group starts at fragment 3
        #expect(answer.status == 200 && answer.headers["Content-Type"] == "video/mp4" && answer.headers["Cache-Control"] == "no-store")
        #expect(answer.body == file.stored[3].dropFirst(32))
        let header = try #require(answer.headers["X-CB-Part"])
        #expect(header.allSatisfy { $0.isASCII } && header.utf8.count < 400)
        let part = try #require(try JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any])
        #expect(Set(part.keys) == ["id", "file", "start", "end", "mime", "width", "height", "anchor", "initId"])
        #expect(part["id"] as? String == file.fragments[3].id && part["initId"] as? String == file.fragments[3].id && part["file"] as? String == file.fileKey)
        #expect(jsonInt(part["start"]) == rig.ms(3_000) && jsonInt(part["end"]) == rig.ms(4_000))
        #expect(part["mime"] as? String == ArchiveFixture.mimeOfTheStream && part["width"] as? Int == 640 && part["height"] as? Int == 360)
        #expect(part["anchor"] as? Double == Double(NVRRig.base))
        let key = await rig.get("nvr/cameras/\(rig.cameraID)/keyframe?at=\(rig.ms(3_000))")
        #expect(key.body == file.stored[3].dropFirst(32), "a time inside the key fragment itself")
    }

    @Test func aTimeWithNoRecordingIsAGapAndSaysWhereTheNextOneStarts() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file("13-24-05", fragments: 2), try rig.file("13-24-30", offsetMs: 20_000, fragments: 2)]
        let between = await rig.get("nvr/cameras/\(rig.cameraID)/keyframe?at=\(rig.ms(10_000))")
        #expect(between.status == 404 && between.json["error"] as? String == "gap" && between.headers["X-CB-Next"] == String(rig.ms(20_000)))
        let before = await rig.get("nvr/cameras/\(rig.cameraID)/keyframe?at=\(rig.ms(-3_000))")
        #expect(before.status == 404 && before.headers["X-CB-Next"] == String(rig.ms(0)))
        let after = await rig.get("nvr/cameras/\(rig.cameraID)/keyframe?at=\(rig.ms(30_000))")
        #expect(after.status == 404 && after.json["error"] as? String == "gap" && after.headers["X-CB-Next"] == nil, "nothing later")
        let unknown = await rig.get("nvr/cameras/\(UUID().uuidString)/keyframe?at=\(rig.ms(0))")
        #expect(unknown.status == 404 && unknown.json["error"] as? String == "gap")
    }

    @Test func aMissingOrBadTimeIsRefusedAndAGoneKeyFragmentIs410() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 4, gopFragments: 4)
        archive.files = [file]
        for query in ["", "?at=", "?at=abc", "?at=5", "?at=\(rig.ms(0)).5", "?when=\(rig.ms(0))"] {
            let answer = await rig.get("nvr/cameras/\(rig.cameraID)/keyframe\(query)")
            #expect(answer.status == 400 && answer.json["field"] as? String == "at", "\(query)")
        }
        #expect(archive.reads.isEmpty)
        archive.remove(file.fragments[0].id)
        #expect((await rig.get("nvr/cameras/\(rig.cameraID)/keyframe?at=\(rig.ms(2_500))")).status == 410)
        #expect((await rig.get("nvr/cameras/not-an-id/keyframe?at=\(rig.ms(0))")).status == 404)
    }
}
