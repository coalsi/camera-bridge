import BridgeSupport
import FMP4
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// `CameraArchiveRecorder` on a real `MediaHub` fed a synthetic timeline and real files in a temporary recordings folder.
@Suite struct RecorderTests {
    /// Waits until `fragments` fragments were written, stops the recorder (which writes out the open group and closes the file) and returns the
    /// segment of the file the target was told about.
    static func finish(_ rig: RecorderRig, _ recorder: CameraArchiveRecorder, fragments: Int? = nil) async throws -> String {
        if let fragments { #expect(await eventually(timeout: .seconds(10)) { rig.target.openedSegments.first.map { rig.target.records(of: $0).count >= fragments } ?? false }) }
        await recorder.stop()
        return try #require(rig.target.openedSegments.first)
    }

    @Test func recordsToTheLayoutWithPrivateModesAndTheCameraManifest() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<150, gop: 60), to: recorder)
        let segment = try await Self.finish(rig, recorder, fragments: 2)
        let camera = rig.camera.id.uuidString
        #expect(segment == "\(camera)/2001-09-09/01-46-40", "<camera UUID>/<yyyy-MM-dd>/<HH-mm-ss> in local time (UTC here)")
        let directory = rig.root.url.appending(path: camera)
        #expect(rig.root.contents() == [camera])
        #expect(try posixPermissions(of: directory) == 0o700 && posixPermissions(of: directory.appending(path: "2001-09-09")) == 0o700)
        let files = rig.files(segment)
        #expect(try posixPermissions(of: files.mp4) == 0o600 && posixPermissions(of: files.index) == 0o600)
        #expect(try posixPermissions(of: directory.appending(path: "camera.json")) == 0o600)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "camera.json"))) as? [String: String]
        #expect(manifest == ["id": camera, "name": "Driveway"])
        #expect(rig.target.closedSegments == [segment])
    }

    @Test func aGroupOfSixtySecondsBecomesTwentyFourFragmentsWithContinuations() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        // 60 s group (1 800 frames), then the next keyframe and two more seconds.
        await rig.feed(RecorderFixtures.videoFrames(0..<1_860, gop: 1_800), to: recorder)
        let segment = try await Self.finish(rig, recorder, fragments: 24)
        let file = try RecordedFile(rig, segment: segment)
        #expect(file.index.fragments.count == 25)
        #expect(file.index.fragments.map(\.backToKey) == Array(0..<24).map(UInt16.init) + [0], "continuations count back to the keyframe: up to 23")
        #expect(file.index.fragments.map { $0.keyLength > 0 } == [true] + Array(repeating: false, count: 23) + [true])
        #expect(file.index.fragments.dropLast().allSatisfy { $0.samples == 75 && $0.durationTicks == 225_000 }, "2.5 s of decode time at 30 fps")
        #expect(file.index.fragments.last?.samples == 60 && file.index.fragments.last?.durationTicks == 60 * 3_000, "the tail flushed at stop")
        // The index is the same as a scan of the mp4 produces.
        #expect(try file.rescanned() == file.index)
        #expect(rig.target.records(of: segment) == file.index.fragments)
    }

    @Test func everyFrameComesBackByteIdenticalWithTheTimesOfOneAnchor() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        let frames = RecorderFixtures.videoFrames(0..<400, gop: 90)
        await rig.feed(frames, to: recorder)
        let segment = try await Self.finish(rig, recorder, fragments: 5)
        let file = try RecordedFile(rig, segment: segment)
        let out = try file.videoFrames()
        #expect(out.count == 400)
        #expect(out.map(\.nalUnits) == frames.map(\.nalUnits), "byte-identical NAL units, keyframes and delta frames alike")
        #expect(out.map(\.isKeyframe) == frames.map(\.isKeyframe))
        // One anchor: the first frame's wall clock; every later frame at anchor + media time, whatever the cuts.
        #expect(file.index.startWallMs == Int64(RecorderFixtures.base.timeIntervalSince1970 * 1_000))
        for (number, frame) in out.enumerated() {
            let expected = RecorderFixtures.base.addingTimeInterval(Double(number) / 30)
            #expect(abs(frame.wallClock.timeIntervalSince(expected)) < 0.002, "frame \(number)")
        }
        // The first fragment's prft carries the derived start, not a measured wall time.
        let prft = try MovieFragmentReader.producerReferenceTime(prft: file.mp4.subdata(in: Int(file.index.fragments[1].offset)..<Int(file.index.fragments[1].offset) + 32))
        #expect(abs(prft.wallClock.timeIntervalSince(file.fragmentStart(1))) < 0.001)
        #expect(file.info.video.parameterSets == [RecorderFixtures.sps, RecorderFixtures.pps])
    }

    @Test func aFileTornAtAnyByteIsRebuiltFromItsWholeFragments() async throws {
        let rig = try RecorderRig(camera: RecorderFixtures.camera(recordSound: true))
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.interleaved(RecorderFixtures.videoFrames(0..<400, gop: 150), RecorderFixtures.audioFrames(seconds: 13)), to: recorder)
        let segment = try await Self.finish(rig, recorder)
        let file = try RecordedFile(rig, segment: segment)
        let whole = file.index.fragments
        #expect(whole.count == 6, "a group of 150 frames is two fragments of 75 frames: K C K C K C")
        let ends = whole.map { Int($0.offset) + Int($0.length) }
        // A crash leaves the file cut anywhere (and no sidecar): the scan finds exactly the fragments that are whole, and they are the sidecar's own.
        for cut in stride(from: file.info.byteCount, through: file.mp4.count, by: 211) + [file.mp4.count - 1, file.mp4.count] {
            let scanned = try RecordedFile.scan(file.mp4.prefix(cut))
            let expected = ends.filter { $0 <= cut }.count
            #expect(scanned.records == Array(whole.prefix(expected)), "cut at \(cut)")
        }
        #expect(throws: FMP4Error.self) { _ = try RecordedFile.scan(file.mp4.prefix(file.info.byteCount - 1)) }
    }

    @Test func aLongKeyframeIntervalShowsAsANoteAndAShortOneDoesNot() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        // 10 fps with a keyframe every 12 s: 100 s of video.
        await rig.feed(RecorderFixtures.videoFrames(0..<1_000, fps: 10, gop: 120), to: recorder)
        #expect(recorder.status.notes == [ArchiveNote(id: .keyframe, text: "keyframe every 12 s: scrubbing is slow")])
        #expect(recorder.status.state == .recording)
        await recorder.stop()
        let quiet = try RecorderRig()
        defer { quiet.root.remove() }
        let other = quiet.recorder()
        await other.start()
        await quiet.feed(RecorderFixtures.videoFrames(0..<600, gop: 60), to: other)
        #expect(other.status.notes.isEmpty)
        await other.stop()
    }

    @Test func theFileReachesTheDiskEveryThirtySecondsAndWhenItCloses() async throws {
        var rig = try RecorderRig()
        let disk = FaultyFileSystem()
        rig.fileSystem = disk
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<130, gop: 60), to: recorder)
        #expect(await eventually(timeout: .seconds(10)) { disk.writes >= 3 })
        #expect(disk.synchronizations == 0, "29 s of uptime would not ask yet; none has passed")
        rig.uptime.set(rig.uptime.value + 31)
        await rig.feed(RecorderFixtures.videoFrames(130..<260, gop: 60), to: recorder)
        #expect(await eventually(timeout: .seconds(10)) { disk.synchronizations == 1 }, "the next fragment after 30 s of uptime is written with a sync")
        await recorder.stop()
        #expect(disk.synchronizations == 2, "closing the file syncs it once more")
    }

    @Test func anOpenFileHasNoSidecarAndACopyOfItScansToAPrefixOfTheFinalIndex() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<400, gop: 90), to: recorder)
        #expect(await eventually(timeout: .seconds(10)) { rig.target.openedSegments.first.map { rig.target.records(of: $0).count >= 5 } ?? false })
        let segment = try #require(rig.target.openedSegments.first)
        let files = rig.files(segment)
        #expect(!FileManager.default.fileExists(atPath: files.index.path(percentEncoded: false)), "the sidecar is written when the file closes")
        // What a crash leaves: the mp4 as it is now. (The recorder may be mid-write; the scan keeps what is whole.)
        let crashed = try Data(contentsOf: files.mp4)
        await recorder.stop()
        let final = try RecordedFile(rig, segment: segment)
        let scanned = try RecordedFile.scan(crashed)
        #expect(scanned.records.count >= 5 && scanned.records == Array(final.index.fragments.prefix(scanned.records.count)))
        #expect(scanned.firstWall.map { abs($0.timeIntervalSince(final.start)) < 0.001 } == true, "the first prft carries the file's anchor")
    }

    @Test func theLogHasOneLineForAFileOpeningAndOneForItsClosingAndNoPathOrFragmentLine() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let log = CameraLogCapture.start(camera: rig.camera.id)
        defer { log.stop() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<400, gop: 90), to: recorder)
        let segment = try await Self.finish(rig, recorder)
        let lines = log.lines
        #expect(lines.count <= 4, "\(lines)")
        #expect(lines.contains("Recording to \(segment)") && lines.contains { $0.hasPrefix("Closed \(segment): ") })
        #expect(lines.allSatisfy { !$0.contains(rig.root.url.path(percentEncoded: false)) && !$0.contains("/var/") }, "a segment is a relative path; no absolute path is logged")
    }
}
