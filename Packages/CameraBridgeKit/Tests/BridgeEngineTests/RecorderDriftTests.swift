import FMP4
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// Time and the camera: an idle camera, a camera clock that drifts or is far off, and a stream the muxer will not take (Mac spec 4.3, 5, 13).
@Suite struct RecorderDriftTests {
    @Test func fifteenSecondsWithoutVideoCloseTheFile() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder(tick: .milliseconds(20))
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<100, gop: 60), to: recorder)
        _ = await eventually(timeout: .seconds(10)) { !rig.target.openedSegments.isEmpty }
        rig.uptime.set(rig.uptime.value + 14)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.target.closedSegments.isEmpty, "14 s is not idle yet")
        #expect(recorder.status.state == .recording)
        rig.uptime.set(rig.uptime.value + 2)
        #expect(await eventually(timeout: .seconds(10)) { rig.target.closedSegments.count == 1 })
        #expect(await eventually(timeout: .seconds(10)) { recorder.status.state == .waiting("waiting for the camera") })
        let file = try RecordedFile(rig, segment: item(rig.target.closedSegments, 0))
        #expect(file.frameCount == 100, "the open group was written out, nothing lost")
        await recorder.stop()
    }

    @Test func aCameraClockThatRunsFastRollsTheFileAfterTwoBadFragments() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        // The camera's wall clock gains 5%: the derived start of a fragment and its measured wall time are 1 s apart after 20 s of video.
        await rig.feed(RecorderFixtures.videoFrames(0..<1_200, gop: 60, wallSkew: 0.05), to: recorder)
        await recorder.stop()
        let segments = rig.target.openedSegments
        #expect(segments.count == 2, "one roll in 40 s: the new file starts with a fresh anchor and is in step again")
        let first = try RecordedFile(rig, segment: item(segments, 0)), second = try RecordedFile(rig, segment: item(segments, 1))
        let seconds = Double(first.index.endWallMs - first.index.startWallMs) / 1_000
        #expect(abs(seconds - 26) < 0.01, "fragments of 2 s: 22 s and 24 s are the bad ones, the roll happens at the keyframe at 26 s: \(seconds)")
        #expect(first.frameCount + second.frameCount == 1_200)
    }

    @Test func aCameraClockThatIsMinutesOffUsesTheHostClockAndNeverRolls() async throws {
        var rig = try RecorderRig(now: RecorderFixtures.base.addingTimeInterval(600))
        rig.clockFollowsFrames = false
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<1_200, gop: 60, wallSkew: 0.05), to: recorder)
        await recorder.stop()
        #expect(rig.target.openedSegments.count == 1)
        let file = try RecordedFile(rig, segment: item(rig.target.openedSegments, 0))
        #expect(file.index.startWallMs == Int64(rig.clock.value.timeIntervalSince1970 * 1_000), "the anchor is the host's clock: the camera's was 600 s off")
    }

    @Test func aStreamTheMuxerRefusesThreeTimesIsReportedAndRetriedLater() async throws {
        var rig = try RecorderRig()
        rig.clockFollowsFrames = false
        defer { rig.root.remove() }
        let recorder = rig.recorder(tick: .milliseconds(20))
        await recorder.start()
        let broken = VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [])
        await rig.feed(RecorderFixtures.videoFrames(0..<130, gop: 30, format: broken), to: recorder)
        #expect(await eventually(timeout: .seconds(10)) { recorder.status.state == .waiting("This stream cannot be recorded: H.264 needs an SPS") })
        #expect(rig.target.openedSegments.isEmpty && rig.root.contents().isEmpty, "nothing was written, not even a folder")
        // After the retry time a good stream records.
        rig.uptime.set(rig.uptime.value + 1)                                          // the test tuning retries after 0.5 s (production: 60 s)
        #expect(await eventually(timeout: .seconds(10)) { recorder.status.state == .waiting("waiting for the camera") })
        await rig.feed(RecorderFixtures.videoFrames(150..<250, gop: 30), to: recorder)
        #expect(await eventually(timeout: .seconds(10)) { recorder.status.state == .recording })
        await recorder.stop()
    }
}
