import BridgeSupport
import FMP4
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// The continuity rule of the recorder (Mac spec 5): any break writes out the open group, closes the file, and the next keyframe opens a new one.
@Suite struct RecorderContinuityTests {
    @Test func aReconnectClosesTheFileAndTheNextKeyframeOpensANewOne() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder(tick: .milliseconds(20))
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<100, gop: 60), to: recorder)
        #expect(await eventually(timeout: .seconds(10)) { rig.target.openedSegments.count == 1 && rig.target.records(of: rig.target.openedSegments[0]).count >= 1 })
        await rig.hub.discontinuity()
        let before = rig.target.closedSegments.count
        _ = await eventually(timeout: .seconds(10)) { rig.target.closedSegments.count > before }
        #expect(rig.target.closedSegments.count == 1, "closed as soon as the recorder saw the counter change, before any new keyframe")
        // The reconnected camera starts a new timeline at 0.
        await rig.feed(RecorderFixtures.videoFrames(0..<100, gop: 60), to: recorder)
        await recorder.stop()                                                          // writes out the second file's only group
        let segments = rig.target.openedSegments
        #expect(segments.count == 2, "\(segments)")
        #expect(try item(segments, 0).hasSuffix("/01-46-40") && item(segments, 1).hasSuffix("/01-46-40-2"), "the second file in the same second gets -2")
        let first = try RecordedFile(rig, segment: item(segments, 0)), second = try RecordedFile(rig, segment: item(segments, 1))
        #expect(first.frameCount == 60 + 1 || first.frameCount >= 60, "everything the hub delivered before the break is in the first file")
        #expect(try second.videoFrames().first?.isKeyframe == true)
        #expect(second.frameCount == 100)
    }

    @Test func aDecodeTimeThatGoesBackOrJumpsForwardEndsTheFile() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<100, gop: 60), to: recorder)
        await rig.feed([RecorderFixtures.video(60, gop: 60)], to: recorder)                           // a keyframe whose decode time is behind the last frame
        _ = await eventually(timeout: .seconds(10)) { rig.target.closedSegments.count == 1 && rig.target.openedSegments.count >= 1 }
        await rig.feed(RecorderFixtures.videoFrames(61..<100, gop: 60), to: recorder)
        await rig.feed([RecorderFixtures.video(400, gop: 60)], to: recorder)                          // 10 s later: a GOP the hub dropped looks like this
        await rig.feed(RecorderFixtures.videoFrames(401..<450, gop: 60), to: recorder)
        await recorder.stop()
        #expect(rig.target.openedSegments.count == 3 && rig.target.closedSegments.count == 3)
    }

    private static func decodeTimes(_ file: RecordedFile) throws -> [Int64] {
        try file.videoFrames().map { ($0.dts ?? $0.pts).converted(to: 90_000).value }
    }

    @Test func aFrameAFewTicksBehindTheLastIsKeptWithATimeThatKeepsIncreasing() async throws {
        // Jitter: a frame that arrives late with the decode time of an earlier moment (0.13 s behind) does not end the file.
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<100, gop: 60), to: recorder)
        await rig.feed([RecorderFixtures.video(95, gop: 60), RecorderFixtures.video(95, gop: 60)], to: recorder)      // twice: the second is a repeat of the first
        await rig.feed(RecorderFixtures.videoFrames(101..<200, gop: 60), to: recorder)
        await recorder.stop()
        let segments = rig.target.openedSegments
        #expect(segments.count == 1 && rig.target.closedSegments.count == 1, "\(segments)")
        guard segments.count == 1 else { return }
        let file = try RecordedFile(rig, segment: item(segments, 0))
        #expect(file.frameCount == 100 + 2 + 99, "no frame is lost")
        let times = try Self.decodeTimes(file)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 }, "decode times strictly increase")
        #expect(await recorder.nudges == 2)
        #expect(try file.rescanned() == file.index)
    }

    private final class Collected: LogSink {
        let entries = Box<[LogEntry]>([])
        func record(_ entry: LogEntry) { entries.update { $0.append(entry) } }
    }

    @Test func jitterIsWarnedAboutOnceNamingTheCamera() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let sink = Collected()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<100, gop: 60), to: recorder)
        await rig.feed([RecorderFixtures.video(95, gop: 60), RecorderFixtures.video(96, gop: 60)], to: recorder)         // two nudges
        await rig.feed(RecorderFixtures.videoFrames(190..<200, gop: 60), to: recorder)                                    // and a gap
        await recorder.stop()
        let warnings = sink.entries.value.filter { $0.cameraID == rig.camera.id && $0.level == .warning && $0.message.contains("arrives unevenly") }
        #expect(warnings.count == 1 && warnings.first?.message == "Driveway: its video arrives unevenly (network?)")
    }

    @Test func aBackwardStepOverHalfASecondStillEndsTheFile() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<100, gop: 60), to: recorder)
        await rig.feed([RecorderFixtures.video(60, gop: 60)], to: recorder)                         // 1.3 s behind
        await rig.feed(RecorderFixtures.videoFrames(61..<90, gop: 60), to: recorder)
        await recorder.stop()
        #expect(rig.target.openedSegments.count == 2)
        #expect(await recorder.nudges == 0)
    }

    @Test func aGapOfAFewSecondsKeepsTheFileAndTheTimeline() async throws {
        // Lost packets: 3 s without a frame, then the stream goes on. One file; the picture before the gap lasts through it.
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<100, gop: 60), to: recorder)
        await rig.feed(RecorderFixtures.videoFrames(190..<300, gop: 60), to: recorder)             // frame 100 is at 3.3 s, 190 at 6.3 s
        await recorder.stop()
        let segments = rig.target.openedSegments
        #expect(segments.count == 1, "\(segments)")
        guard segments.count == 1 else { return }
        let file = try RecordedFile(rig, segment: item(segments, 0))
        #expect(file.frameCount == 100 + 110)
        let times = try Self.decodeTimes(file)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
        #expect((times.last ?? 0) - (times.first ?? 0) == 299 * 3_000, "the media time follows the camera's, the gap is in it")
        #expect(await recorder.gaps == 1)
        #expect(try file.rescanned() == file.index)
    }

    @Test func aGapOfSixSecondsIsAClockJump() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<100, gop: 60), to: recorder)
        await rig.feed([RecorderFixtures.video(300, gop: 60)], to: recorder)                         // 6.7 s later
        await rig.feed(RecorderFixtures.videoFrames(301..<360, gop: 60), to: recorder)
        await recorder.stop()
        #expect(rig.target.openedSegments.count == 2)
        #expect(await recorder.gaps == 0)
    }

    /// Frames `range` of a camera whose decode times started again at 0 and whose wall clock says the first of them came at `base + wallStart`.
    private static func restarted(_ range: Range<Int>, fps: Int = 30, wallStart: TimeInterval) -> [EncodedVideoFrame] {
        range.map { number in
            var frame = RecorderFixtures.video(number, fps: fps, gop: 60)
            frame.wallClock = RecorderFixtures.base.addingTimeInterval(wallStart + Double(number) / Double(fps))
            return frame
        }
    }

    @Test func aFileAfterAClockJumpStartsWhereThePreviousEndedWhenItWouldOverlapIt() async throws {
        // A camera's timestamps went back (Patio on the box): the new file's first keyframe has a wall clock 0.7 s before the end the first
        // file's media time reached. The new file starts at that end: no time is in two files and every frame is kept.
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<100, gop: 60), to: recorder)                 // 0 to 3.333 s
        await rig.feed(Self.restarted(0..<90, wallStart: 100.0 / 30 - 0.7), to: recorder)           // decode 0 again, captured at 2.633 s
        await recorder.stop()
        let segments = rig.target.openedSegments
        #expect(segments.count == 2, "\(segments)")
        guard segments.count == 2 else { return }
        let first = try RecordedFile(rig, segment: item(segments, 0)), second = try RecordedFile(rig, segment: item(segments, 1))
        #expect(first.index.endWallMs == Int64(RecorderFixtures.base.timeIntervalSince1970 * 1_000) + 3_333)
        #expect(second.index.startWallMs == first.index.endWallMs, "the second file starts where the first ended, not 700 ms inside it")
        #expect(first.frameCount == 100 && second.frameCount == 90, "every frame is kept")
        #expect(try second.rescanned() == second.index, "the mp4's own times say the same")
    }

    @Test func theFileAfterAMovedFileRollsStartsAtTheCameraTimeAgain() async throws {
        // The moved file lasts until its roll at 900 s; the next file takes the camera's time again, so the move does not follow the camera
        // from roll to roll (at a roll the format is the same and the player plays the small overlap straight through).
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<100, fps: 1, gop: 60), to: recorder)                 // 0 to 100 s
        await rig.feed(Self.restarted(0..<1_000, fps: 1, wallStart: 100 - 0.7), to: recorder)               // decode 0 again, captured at 99.3 s
        await recorder.stop()
        let segments = rig.target.openedSegments
        #expect(segments.count == 3, "\(segments)")
        guard segments.count == 3 else { return }
        let second = try RecordedFile(rig, segment: item(segments, 1)), third = try RecordedFile(rig, segment: item(segments, 2))
        let baseMs = Int64(RecorderFixtures.base.timeIntervalSince1970 * 1_000)
        #expect(second.index.startWallMs == baseMs + 100_000, "the file after the clock jump is moved to where the first ended")
        #expect(third.index.startWallMs == baseMs + 999_300, "the roll's keyframe was captured at 99.3 s + 900 s: \(third.index.startWallMs - baseMs)")
        #expect(second.frameCount == 900 && third.frameCount == 100, "every frame is kept")
    }

    @Test func aFileThatWouldOverlapThePreviousByMoreThanTheDivergenceLimitKeepsTheCameraTime() async throws {
        // More than a second back: the camera's clock really went back, and the file is not moved that far from it (the reader's rule, the
        // later file wins, decides the overlap).
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<100, gop: 60), to: recorder)
        await rig.feed(Self.restarted(0..<90, wallStart: 100.0 / 30 - 1.5), to: recorder)
        await recorder.stop()
        let segments = rig.target.openedSegments
        #expect(segments.count == 2, "\(segments)")
        guard segments.count == 2 else { return }
        let first = try RecordedFile(rig, segment: item(segments, 0)), second = try RecordedFile(rig, segment: item(segments, 1))
        #expect(second.index.startWallMs == first.index.endWallMs - 1_500)
    }

    @Test func aFileAfterAHoleKeepsTheCameraTime() async throws {
        // Frames were lost between the files: the hole is real and stays.
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<100, gop: 60), to: recorder)
        await rig.feed(Self.restarted(0..<90, wallStart: 100.0 / 30 + 0.4), to: recorder)
        await recorder.stop()
        let segments = rig.target.openedSegments
        #expect(segments.count == 2, "\(segments)")
        guard segments.count == 2 else { return }
        let first = try RecordedFile(rig, segment: item(segments, 0)), second = try RecordedFile(rig, segment: item(segments, 1))
        #expect(second.index.startWallMs == first.index.endWallMs + 400)
    }

    @Test func aSmallGapIsNotABreakAndTheLimitFollowsTheFrameInterval() async throws {
        // 30 fps: a step of 1.4 s stays under max(1.5 s, 4 frame intervals).
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<60, gop: 600), to: recorder)
        await rig.feed(RecorderFixtures.videoFrames(102..<160, gop: 600), to: recorder)  // frame 102 is 1.4 s after frame 59 (a lost burst, not a break)
        await recorder.stop()
        #expect(rig.target.openedSegments.count == 1)
        // 1 fps: the limit is 4 s, so a 3 s hole is fine and a 6 s hole is a break.
        let slow = try RecorderRig()
        defer { slow.root.remove() }
        let slowRecorder = slow.recorder()
        await slowRecorder.start()
        await slow.feed(RecorderFixtures.videoFrames(0..<10, fps: 1, gop: 600), to: slowRecorder)
        await slow.feed(RecorderFixtures.videoFrames(12..<15, fps: 1, gop: 600), to: slowRecorder)  // 3 s step
        await slow.feed([RecorderFixtures.video(21, fps: 1, gop: 21)], to: slowRecorder)  // 7 s step, a keyframe
        await slow.feed(RecorderFixtures.videoFrames(22..<25, fps: 1, gop: 600), to: slowRecorder)
        await slowRecorder.stop()
        #expect(slow.target.openedSegments.count == 2)
    }

    @Test func aParameterSetChangeEndsTheFileAtTheNextKeyframe() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<60, gop: 60), to: recorder)
        await rig.feed(RecorderFixtures.videoFrames(60..<120, gop: 60, format: RecorderFixtures.otherH264), to: recorder)
        await recorder.stop()
        let segments = rig.target.openedSegments
        #expect(segments.count == 2, "\(rig.target.events)")
        guard segments.count == 2 else { return }
        let first = try RecordedFile(rig, segment: item(segments, 0)), second = try RecordedFile(rig, segment: item(segments, 1))
        #expect(first.info.video.parameterSets[1] == RecorderFixtures.pps && second.info.video.parameterSets[1] != RecorderFixtures.pps)
        #expect(first.frameCount == 60 && second.frameCount == 60, "no frame is lost at the change")
    }

    @Test func aFileRollsAtNineHundredSecondsAtAKeyframeWithoutLosingAFrameOrOpeningAGap() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        // 1 fps with a keyframe every minute: the keyframe at 900 s is where the first file ends.
        await rig.feed(RecorderFixtures.videoFrames(0..<1_000, fps: 1, gop: 60), to: recorder)
        await recorder.stop()
        let segments = rig.target.openedSegments
        #expect(segments.count == 2)
        let first = try RecordedFile(rig, segment: item(segments, 0)), second = try RecordedFile(rig, segment: item(segments, 1))
        #expect(first.frameCount == 900 && second.frameCount == 100)
        let firstEnd = first.index.endWallMs, secondStart = second.index.startWallMs
        #expect(firstEnd == secondStart, "the last frame of the first file lasts exactly until the first frame of the second")
        #expect(first.index.rollups.count == 15)
        #expect(try first.rescanned() == first.index && second.rescanned() == second.index)
    }

    @Test func aFileRollsAtItsSizeLimitAtAKeyframe() async throws {
        var rig = try RecorderRig()
        rig.fileMaximumBytes = 30_000
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<300, gop: 30), to: recorder)  // about 12 KB per second of video: 3 000 + 29 × 300 bytes a group
        await recorder.stop()
        #expect(rig.target.openedSegments.count >= 3)
        var total = 0
        for segment in rig.target.openedSegments { total += try RecordedFile(rig, segment: segment).frameCount }
        #expect(total == 300, "every frame is in exactly one file")
    }

    @Test func framesWithReorderingKeepTheirDecodeAndPresentationTimes() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        let frames = RecorderFixtures.videoFrames(0..<200, gop: 100, reordered: true)
        await rig.feed(frames, to: recorder)
        await recorder.stop()
        let file = try RecordedFile(rig, segment: item(rig.target.openedSegments, 0))
        let out = try file.videoFrames()
        #expect(out.count == 200 && out.map(\.nalUnits) == frames.map(\.nalUnits))
        #expect(out.allSatisfy { $0.dts != nil && $0.pts.value - $0.dts!.value == 6_000 }, "pts is two frame intervals after dts")
        #expect(try file.rescanned() == file.index)
    }

    @Test func aRecorderThatStartsLateReplaysTheNewestGroupAndLosesNoFrame() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        // 100 frames arrived before anyone recorded: the hub holds the groups [0, 60) and [60, 100).
        await rig.feed(RecorderFixtures.videoFrames(0..<100, gop: 60))
        let recorder = rig.recorder()
        await recorder.start()
        #expect(await eventually(timeout: .seconds(10)) { await recorder.samplesHandled == 40 }, "the replay: the newest group, from its keyframe")
        await rig.feed(RecorderFixtures.videoFrames(100..<150, gop: 60), to: recorder)
        await recorder.stop()
        let file = try RecordedFile(rig, segment: item(rig.target.openedSegments, 0))
        let out = try file.videoFrames()
        #expect(out.map(\.nalUnits) == RecorderFixtures.videoFrames(60..<150, gop: 60).map(\.nalUnits), "from the newest keyframe on, every frame once")
        #expect(out.first?.isKeyframe == true)
    }

    @Test func fragmentsStayUnderSixteenMebibytesAndNineHundredFrames() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        // 1 MB pictures, one group of 60 at 30 fps: the byte cap cuts every 15 pictures, not the 2.5 s rule.
        let big = (0..<61).map { RecorderFixtures.video($0, gop: 1_000, size: 1_000_000) }
        await rig.feed(big, to: recorder)
        // 1 000 fps for 1 000 frames: 900 frames is the cut.
        let fast = (0..<1_000).map { RecorderFixtures.video($0, fps: 1_000, gop: 5_000, size: 20) }
        await recorder.stop()
        let records = try rig.target.records(of: item(rig.target.openedSegments, 0))
        #expect(records.count >= 4 && records.allSatisfy { Int($0.length) <= ArchiveConstants.fragmentMaximumBytes })
        #expect(records.map { Int($0.samples) }.reduce(0, +) == 61)
        let rig2 = try RecorderRig()
        defer { rig2.root.remove() }
        let recorder2 = rig2.recorder()
        await recorder2.start()
        await rig2.feed(fast, to: recorder2)
        await recorder2.stop()
        let counts = try rig2.target.records(of: item(rig2.target.openedSegments, 0)).map(\.samples)
        #expect(counts == [900, 100], "the frame cap cuts at 900 samples (0.9 s here), the tail follows")
    }

    @Test func aFrameOverSixteenMebibytesEndsTheFileAndIsNotRecorded() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<50, gop: 60), to: recorder)
        await rig.feed([RecorderFixtures.video(50, gop: 60, size: 17 * 1_048_576)], to: recorder)
        await rig.feed(RecorderFixtures.videoFrames(51..<120, gop: 60), to: recorder)
        await recorder.stop()
        #expect(rig.target.openedSegments.count == 2)
        let first = try RecordedFile(rig, segment: item(rig.target.openedSegments, 0)), second = try RecordedFile(rig, segment: item(rig.target.openedSegments, 1))
        #expect(first.frameCount == 50 && second.frameCount == 60, "frames 51...59 wait for the keyframe at 60")
    }
}
