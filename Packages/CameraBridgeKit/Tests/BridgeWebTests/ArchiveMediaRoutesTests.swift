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

    // MARK: Key picture

    private func keyframe(_ rig: NVRRig, at offsetMs: Int64, _ query: String = "") async -> Answer {
        await rig.get("nvr/cameras/\(rig.cameraID)/keyframe?at=\(rig.ms(offsetMs))\(query)")
    }

    /// The `X-CB-Part` description of a key answer.
    private func partHeader(_ answer: Answer) throws -> [String: Any] {
        let header = try #require(answer.headers["X-CB-Part"])
        return try #require(try JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any])
    }

    @Test func aKeyPictureAnswerHoldsOneFrame() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 6, gopFragments: 3)
        archive.files = [file]
        let whole = await keyframe(rig, at: 4_400)                    // inside fragment 4; its group starts at fragment 3
        let answer = await keyframe(rig, at: 4_400, "&picture=1")
        #expect(answer.status == 200 && answer.headers["Content-Type"] == "video/mp4" && answer.headers["Cache-Control"] == "no-store")
        let boxes = try MP4BoxReader.parse(answer.body)
        #expect(boxes.map(\.type) == ["moof", "mdat"])
        let trun = try #require(boxes.first?.child("traf")?.child("trun"))
        #expect(u32(answer.body, trun.payloadOffset + 4) == 1, "one sample")
        #expect(u32(answer.body, trun.payloadOffset + 8) == boxes[0].size + 8, "the data offset points at it")
        let stored = file.stored[3]                                     // the key fragment, with its prft
        let storedBoxes = try MP4BoxReader.parse(stored)
        let storedRun = try #require(storedBoxes.first { $0.type == "moof" }?.child("traf")?.child("trun")), mdat = try #require(storedBoxes.first { $0.type == "mdat" })
        let size = u32(stored, storedRun.payloadOffset + 12 + 4)
        #expect(boxes[1].payloadSize == size && answer.body.suffix(size) == stored[mdat.payloadOffset..<mdat.payloadOffset + size], "the key picture's bytes and nothing else")
        #expect(answer.body.count < whole.body.count / 3, "\(answer.body.count) bytes against \(whole.body.count)")

        // The same description, except that the part ends with its picture: one frame of 40 ms at 25 a second, not the fragment's second.
        let part = try partHeader(answer), wholePart = try partHeader(whole)
        #expect(Set(part.keys) == Set(wholePart.keys) && Set(part.keys) == ["id", "file", "start", "end", "mime", "width", "height", "anchor", "initId"])
        for key in wholePart.keys where key != "end" { #expect("\(part[key] ?? "")" == "\(wholePart[key] ?? "")", "\(key) is the key fragment's") }
        #expect(part["id"] as? String == file.fragments[3].id && part["initId"] as? String == file.fragments[3].id)
        #expect(jsonInt(part["start"]) == rig.ms(3_000) && jsonInt(part["end"]) == rig.ms(3_040), "end = start + one frame")
        #expect(jsonInt(wholePart["end"]) == rig.ms(4_000))
    }

    /// Frames 3,003 ticks apart (30000/1001) last 33.37 ms. The end is worked out as every part's is, from the file's anchor and integer ticks: the start
    /// is the fragment's own (1,001 ms into the file for fragment 2) and the end the start of the picture plus its ticks, both rounded.
    @Test func aKeyPictureEndsWhereItsOwnFrameEnds() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file(fragments: 4, framesPerFragment: 15, frameTicks: 3_003, gopFragments: 2)]
        let first = try partHeader(await keyframe(rig, at: 100, "&picture=1"))
        #expect(jsonInt(first["start"]) == rig.ms(0) && jsonInt(first["end"]) == rig.ms(33))
        let third = try partHeader(await keyframe(rig, at: 1_100, "&picture=1"))
        #expect(jsonInt(third["start"]) == rig.ms(1_001) && jsonInt(third["end"]) == rig.ms(1_034))
    }

    @Test func withoutPictureTheKeyFragmentIsUnchanged() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 6, gopFragments: 3)
        archive.files = [file]
        let plain = await keyframe(rig, at: 4_400)
        #expect(plain.status == 200 && plain.body == file.stored[3].dropFirst(32))
        let plainPart = try partHeader(plain)
        #expect(jsonInt(plainPart["end"]) == rig.ms(4_000), "the key fragment's own end")
        let zero = await keyframe(rig, at: 4_400, "&picture=0")
        #expect(zero.status == 200 && zero.body == plain.body && zero.headers["X-CB-Part"] == plain.headers["X-CB-Part"], "picture=0 is no picture=")
        #expect(zero.headers["Content-Type"] == "video/mp4" && zero.headers["Cache-Control"] == "no-store")
        let first = await rig.get("nvr/cameras/\(rig.cameraID)/keyframe?picture=0&at=\(rig.ms(4_400))")
        #expect(first.body == plain.body && first.headers["X-CB-Part"] == plain.headers["X-CB-Part"], "the order of the parameters does not matter")
    }

    @Test func pictureMustBeZeroOrOne() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file(fragments: 4, gopFragments: 2)]
        for value in ["", "2", "-1", "01", "10", "true", "false", "yes", "on", "one", "%201", "1%20", "1.0", "1,1"] {
            let answer = await keyframe(rig, at: 500, "&picture=\(value)")
            #expect(answer.status == 400 && answer.json["error"] as? String == "invalid" && answer.json["code"] as? String == "invalid" && answer.json["field"] as? String == "picture", "picture=\(value)")
        }
        #expect(archive.reads.isEmpty && rig.harness.app.archiveSlotsInUse == 0, "refused before anything was read")
        let both = await rig.get("nvr/cameras/\(rig.cameraID)/keyframe?at=abc&picture=2")
        #expect(both.status == 400 && both.json["field"] as? String == "at", "the time is looked at first")
    }

    /// A key picture meets the refusals the key fragment does: a gap with where the next recording starts, a camera the bridge does not have, HEAD, a busy
    /// bridge, a drive that does not answer, a part that cannot be read and one that is gone.
    @Test func aKeyPictureIsRefusedWhereTheKeyFragmentIs() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive) { $0.maximumArchiveReads = 1; $0.maximumArchiveReadsPerAddress = 1 }
        let file = try rig.file("13-24-05", fragments: 4, gopFragments: 4)
        archive.files = [file, try rig.file("13-24-30", offsetMs: 20_000, fragments: 2)]
        let gap = await keyframe(rig, at: 10_000, "&picture=1")
        #expect(gap.status == 404 && gap.json["error"] as? String == "gap" && gap.headers["X-CB-Next"] == String(rig.ms(20_000)))
        let unknown = await rig.get("nvr/cameras/\(UUID().uuidString)/keyframe?at=\(rig.ms(0))&picture=1")
        #expect(unknown.status == 404 && unknown.json["error"] as? String == "gap")
        let head = await rig.session.send("HEAD", "/api/v1/nvr/cameras/\(rig.cameraID)/keyframe?at=\(rig.ms(500))&picture=1")
        #expect(head.status == 405 && head.headers["Allow"] == "GET")
        #expect(archive.reads.isEmpty)

        #expect(rig.harness.app.takeArchiveSlot(address: "192.0.2.77"), "the only slot is taken")
        let busy = await keyframe(rig, at: 500, "&picture=1")
        #expect(busy.status == 429 && busy.json["error"] as? String == "busy" && busy.headers["Retry-After"] == "1")
        rig.harness.app.releaseArchiveSlot(address: "192.0.2.77")
        #expect((await keyframe(rig, at: 500, "&picture=1")).status == 200)

        archive.fail(file.fragments[0].id, with: .timedOut)
        let slow = await keyframe(rig, at: 2_500, "&picture=1")
        #expect(slow.status == 504 && slow.json["error"] as? String == "drive_slow" && slow.headers["Retry-After"] == "2")
        archive.fail(file.fragments[0].id, with: .unreadable("/var/lib/camera-bridge/recordings/SECRET/x.mp4"))
        let unreadable = await keyframe(rig, at: 2_500, "&picture=1")
        #expect(unreadable.status == 502 && unreadable.json["error"] as? String == "unreadable" && !unreadable.text.contains("SECRET"))
        archive.remove(file.fragments[0].id)
        #expect((await keyframe(rig, at: 2_500, "&picture=1")).status == 410)
        #expect(rig.harness.app.archiveSlotsInUse == 0, "every slot was released")
    }

    @Test func aKeyPictureLargerThanTheLimitIsRefused() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive) { $0.maximumSegmentBytes = 100 }
        archive.files = [try rig.file(fragments: 2)]
        let answer = await keyframe(rig, at: 100, "&picture=1")
        #expect(answer.status == 502 && answer.json["error"] as? String == "unreadable")
        #expect(rig.harness.app.archiveSlotsInUse == 0)
    }

    @Test func aFragmentThatStartsWithoutAKeyPictureIsUnreadableForItsPictureToo() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 3, gopFragments: 3)
        // The index says fragment 0 holds a key picture; its bytes say the first sample is a delta picture (a damaged file).
        let run = try #require(try MP4BoxReader.parse(file.stored[0]).first { $0.type == "moof" }?.child("traf")?.child("trun"))
        let flags = run.payloadOffset + 12 + 8                         // the first entry's sample flags
        var damaged = file
        damaged.stored[0].replaceSubrange(flags..<flags + 4, with: [0x01, 0x01, 0x00, 0x00])
        archive.files = [damaged]
        let answer = await keyframe(rig, at: 100, "&picture=1")
        #expect(answer.status == 502 && answer.json["error"] as? String == "unreadable", "\(answer.text)")
        #expect((await keyframe(rig, at: 100)).status == 200, "the whole key fragment is served as it was")
    }

    @Test func aTVsKeyMayAskForTheKeyPicture() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file(fragments: 4, gopFragments: 2)]
        let tv = try await rig.harness.pairAppleTV(owner: rig.session)
        let path = "/api/v1/nvr/cameras/\(rig.cameraID)/keyframe?at=\(rig.ms(500))&picture=1"
        let answer = await rig.harness.send("GET", path, headers: [("Authorization", "Bearer \(tv.key)")])
        #expect(answer.status == 200 && answer.headers["Content-Type"] == "video/mp4")
        let boxes = try MP4BoxReader.parse(answer.body)
        let trun = try #require(boxes.first?.child("traf")?.child("trun"))
        #expect(boxes.map(\.type) == ["moof", "mdat"] && u32(answer.body, trun.payloadOffset + 4) == 1)
    }
}
