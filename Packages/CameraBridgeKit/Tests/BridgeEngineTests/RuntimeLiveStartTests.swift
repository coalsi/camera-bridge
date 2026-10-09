#if canImport(Darwin)
import BridgeSupport
import Foundation
import HAPCamera
import MediaCore
import PlatformApple
import Testing
import TestSupport
@testable import BridgeEngine

/// Field report: live views sit loading for minutes and only sometimes load. The pipeline opened with the hub's last
/// keyframe, which could be as old as a whole GOP, and then waited for the camera's NEXT keyframe before sending
/// anything else: a controller got one frame and then nothing for up to a GOP (smart codecs: a minute), gave up after
/// 30 s and retried at a new random point of the GOP. A live view must show video within a second or two of the start,
/// whatever the camera's keyframe interval is, and whenever in the GOP it starts.
@Suite(.serialized) struct RuntimeLiveStartTests {
    /// A source with a 6 s GOP, started `age` before the live view: the newest keyframe is that old and the next one far off.
    private static func agedSetup(width: Int = 640, height: Int = 360, codecs: any MediaCodecs = AppleMediaCodecs()) async throws
        -> (RuntimeLiveStreamTests.Setup, SRTPTestReceiver, UUID, PrepareStreamResponse) {
        let setup = RuntimeLiveStreamTests.setup(source: syntheticSource(width: width, height: height, fps: 15, gop: .seconds(6), audio: nil), codecs: codecs)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(20)))
        try await Task.sleep(for: .milliseconds(2_500))   // the hub's keyframe is now ~2.5 s old, the next ~3.5 s away
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await RuntimeLiveStreamTests.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await RuntimeLiveStreamTests.connect(receiver, to: response)
        return (setup, receiver, sessionID, response)
    }

    @Test(.timeLimit(.minutes(2))) func aTranscodedLiveViewShowsMovingVideoBeforeTheCamerasNextKeyframe() async throws {
        let (setup, receiver, sessionID, _) = try await Self.agedSetup()
        let started = ContinuousClock.now
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: RuntimeLiveStreamTests.video(320, 240, fps: 15, bitrate: 299), audio: nil))
        let pipeline = try #require(await setup.handler.pipeline(sessionID))
        // Before the fix: one keyframe, then nothing until the camera's next one (~3.5 s away).
        let flowing = await receiver.waitFor(timeout: .milliseconds(2_000)) { $0.keyframes >= 1 && $0.videoFrames >= 10 }
        let frameCount = await receiver.statistics.videoFrames
        #expect(flowing, "\(frameCount) frames after \(ContinuousClock.now - started)")
        #expect(pipeline.isTranscoding)
        let firstKeyframe = try #require(await receiver.firstKeyframeAt)
        #expect(firstKeyframe - started < .milliseconds(1_500), "an IDR of the present picture goes out at once")
        #expect(await receiver.statistics.incompleteVideoFrames == 0)
        // The diagnostics bundle shows each phase of the session (prepare → start → encoder ready → first packet → RTCP → end).
        #expect(await eventually { DiagnosticsCenter.shared.sessions().first { $0.id == sessionID }?.offset(of: "first RTCP received") != nil })
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        let record = try #require(DiagnosticsCenter.shared.sessions().first { $0.id == sessionID })
        let names = record.phases.map(\.name)
        for phase in ["prepare", "start", "path decided", "encoder ready", "first video packet", "keyframe sent", "first RTCP received"] {
            #expect(names.contains(phase), "\(phase) missing in \(record.oneLine)")
        }
        let offsets = record.phases.map(\.offset)
        #expect(offsets == offsets.sorted(), "phases are in order: \(record.oneLine)")
        #expect(record.endReason == "stopped" && record.summary?.hasPrefix("transcoded") == true, "\(record.oneLine)")
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test(.timeLimit(.minutes(2))) func aPassthroughLiveViewReplaysTheGOPSoTheNextFramesDecode() async throws {
        let (setup, receiver, sessionID, _) = try await Self.agedSetup()
        let started = ContinuousClock.now
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: RuntimeLiveStreamTests.video(1280, 720, fps: 30, bitrate: 800), audio: nil))
        let pipeline = try #require(await setup.handler.pipeline(sessionID))
        let flowing = await receiver.waitFor(timeout: .milliseconds(3_000)) { $0.keyframes >= 1 && $0.videoFrames >= 20 }
        let frameCount = await receiver.statistics.videoFrames
        #expect(flowing, "\(frameCount) frames after \(ContinuousClock.now - started)")
        #expect(pipeline.videoPath == .passthrough)
        // The replayed GOP is pulled together on the RTP timeline (no 2.5 s of lag), and live frames continue from it.
        let records = await receiver.frameRecords.filter(\.isComplete)
        let stamps = records.map { Int32(bitPattern: $0.rtpTimestamp &- records[0].rtpTimestamp) }
        #expect(zip(stamps, stamps.dropFirst()).allSatisfy { $1 >= $0 }, "RTP time never steps back: \(stamps.prefix(60))")
        let replayed = stamps.prefix(25).last ?? 0
        #expect(replayed < 90_000 * 3 / 2, "the replay is not spread over its \(2.5) s of age: \(replayed) ticks")
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await setup.feeder.stop()
    }

    /// Typical cameras: a 2688×1520 main stream (Tapo) asked for 1280×720 at 299 kbit/s (what iOS requests first).
    @Test(.timeLimit(.minutes(2))) func aFourMegapixelSourceTranscodedTo720pStartsQuickly() async throws {
        let (setup, receiver, sessionID, _) = try await Self.agedSetup(width: 2688, height: 1520)
        let started = ContinuousClock.now
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: RuntimeLiveStreamTests.video(1280, 720, fps: 30, bitrate: 299), audio: nil))
        let pipeline = try #require(await setup.handler.pipeline(sessionID))
        let flowing = await receiver.waitFor(timeout: .milliseconds(3_000)) { $0.keyframes >= 1 && $0.videoFrames >= 10 }
        let frameCount = await receiver.statistics.videoFrames
        #expect(flowing, "\(frameCount) frames after \(ContinuousClock.now - started)")
        #expect(pipeline.isTranscoding)
        let sizes = RuntimeLiveStreamTests.SPSSizes(receiver)
        #expect(await eventually(timeout: .seconds(3)) { sizes.sizes.value.first == "1280×720" }, "\(sizes.sizes.value)")
        sizes.stop()
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test func aReplayIsPulledTogetherInTimeAndKeepsItsLastFrame() {
        func frame(_ seconds: Double) -> EncodedVideoFrame {
            EncodedVideoFrame(format: VideoFormat(codec: .h264, width: 64, height: 64, parameterSets: [Data([0x67])]), nalUnits: [Data([0x65, 1])],
                              isKeyframe: seconds == 0, pts: .seconds(seconds, timescale: 90_000), dts: nil, wallClock: Date())
        }
        let frames = (0..<5).map { frame(Double($0) * 0.5) }   // 2 s of video
        let compressed = LiveStreamPipeline.compressedReplay(frames, spacing: 0.01)
        #expect(compressed.last?.pts == frames.last?.pts)
        let steps = zip(compressed, compressed.dropFirst()).map { ($1.pts - $0.pts).seconds }
        #expect(steps.allSatisfy { abs($0 - 0.01) < 0.0001 }, "\(steps)")
        #expect(compressed.first?.isKeyframe == true)
        // Frames already closer than the spacing are left alone.
        let tight = (0..<3).map { frame(Double($0) * 0.001) }
        #expect(LiveStreamPipeline.compressedReplay(tight, spacing: 0.01).map(\.pts) == tight.map(\.pts))
    }
}
#endif
