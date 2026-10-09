#if canImport(Darwin)
import BridgeSupport
import Foundation
import HAPCamera
import MediaCore
import PlatformApple
import Testing
import TestSupport
@testable import BridgeEngine

/// Regression (found by the W3-2 end-to-end live view): a live view starts with the hub's last keyframe, which is up to
/// a GOP old. Sent with its capture timestamp, the RTP timeline jumped ahead of the wall clock by that age at the next
/// keyframe — receivers that anchor playout on the first frame then hold every later frame back by as much (up to a
/// whole GOP of extra latency), and the stream reads as slower than it is. The first frame is now stamped at the moment
/// it is sent, so media time and arrival time advance together from the first frame on.
@Suite(.serialized) struct RuntimeLiveTimelineTests {
    @Test(.timeLimit(.minutes(1))) func rtpTimestampsKeepPaceWithArrivalFromTheFirstFrame() async throws {
        try await Self.checkPace(cameraClockSkew: 0)
    }

    /// Review finding (W4 round 2): the first keyframe's age was measured from its wall clock, which for RTSP is the
    /// camera's own clock (RTCP sender reports, accepted within 3 s of arrival). A camera clock ahead of the Mac's left the
    /// keyframe unmoved (up to a GOP of extra latency again), one behind moved it too far (every later frame late). The
    /// age is measured on the hub's monotonic clock now, from the keyframe's arrival.
    @Test(.timeLimit(.minutes(1)), arguments: [2.0, -2.0]) func rtpTimestampsKeepPaceWhenTheCameraClockIsOff(skew: Double) async throws {
        try await Self.checkPace(cameraClockSkew: skew)
    }

    /// Starts a live view when the hub's last keyframe is about 1.5 s old (half a 3 s GOP) on a source whose wall clocks
    /// run `cameraClockSkew` seconds off the Mac's, and checks that media time and arrival time advance together.
    static func checkPace(cameraClockSkew skew: Double) async throws {
        let source = SkewedClockSource(base: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(3), audio: nil), skew: skew)
        let setup = RuntimeLiveStreamTests.setup(source: source)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        // Start when the hub's last keyframe is about 1.5 s old (half a GOP), on the Mac's clock.
        #expect(await eventually(timeout: .seconds(6)) {
            guard let keyframe = await setup.feeder.hub.lastKeyframe else { return false }
            let age = Date().timeIntervalSince(keyframe.wallClock) + skew
            return age >= 1.4 && age < 2.2
        })
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await RuntimeLiveStreamTests.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await RuntimeLiveStreamTests.connect(receiver, to: response)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: RuntimeLiveStreamTests.video(1280, 720), audio: nil))
        #expect(await receiver.waitFor(timeout: .seconds(6)) { $0.keyframes >= 2 && $0.videoFrames >= 20 })

        let records = await receiver.frameRecords
        let keyframes = records.filter(\.isKeyframe)
        try #require(keyframes.count >= 2)
        let mediaGap = Double(Int32(bitPattern: keyframes[1].rtpTimestamp &- keyframes[0].rtpTimestamp)) / 90_000
        let arrivalGap = Self.seconds(keyframes[1].receivedAt - keyframes[0].receivedAt)
        #expect(abs(mediaGap - arrivalGap) < 0.3, "skew \(skew) s, first → next keyframe: \(mediaGap) s of media time arrived in \(arrivalGap) s")
        let first = try #require(records.first), last = try #require(records.last)
        let mediaSpan = Double(Int32(bitPattern: last.rtpTimestamp &- first.rtpTimestamp)) / 90_000
        let arrivalSpan = Self.seconds(last.receivedAt - first.receivedAt)
        #expect(abs(mediaSpan - arrivalSpan) < 0.3, "skew \(skew) s: \(mediaSpan) s of media time arrived in \(arrivalSpan) s")

        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test func theFirstFrameIsStampedWhenItIsSent() {
        let format = VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [])
        let frame = EncodedVideoFrame(format: format, nalUnits: [Data([0x65])], isKeyframe: true, pts: MediaTime(value: 90_000, timescale: 90_000),
                                      dts: MediaTime(value: 90_000, timescale: 90_000), wallClock: Date())
        let moved = LiveStreamPipeline.restampedFirstFrame(frame, age: 1.5, limit: 4)
        #expect(moved.pts == MediaTime(value: 225_000, timescale: 90_000) && moved.dts == moved.pts)
        // Never more than the limit (a GOP), never backwards; an unknown age moves nothing.
        #expect(LiveStreamPipeline.restampedFirstFrame(frame, age: 30, limit: 2).pts == MediaTime(value: 270_000, timescale: 90_000))
        #expect(LiveStreamPipeline.restampedFirstFrame(frame, age: -3, limit: 2).pts == frame.pts)
        #expect(LiveStreamPipeline.restampedFirstFrame(frame, age: .nan, limit: 2).pts == frame.pts)
    }

    /// Review finding (W4 round 3): at a new timeline the rebaser put the next frame one frame interval after the last,
    /// which is right for fMP4 decode times but removed real time from RTP: after a camera's outage (every ingest
    /// reconnect starts at 0), or from the restamped first keyframe to the next one of a GOP over 10 s, RTP time fell
    /// behind wall-clock and RTCP sender-report time for the rest of the session. Live frames carry their arrival.
    @Test func aNewTimelineKeepsPaceWithArrivalInLiveView() {
        let format = VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [])
        func frame(_ seconds: Double, key: Bool = false) -> EncodedVideoFrame {
            EncodedVideoFrame(format: format, nalUnits: [Data([key ? 0x65 : 0x41])], isKeyframe: key, pts: .seconds(seconds), wallClock: Date())
        }
        let start = ContinuousClock.now
        // A reconnect after a 20 s outage: the new source starts again at 0.
        var live = TimelineRebaser()
        _ = live.video(frame(5, key: true), arrival: start)
        let lastBefore = live.video(frame(5.1), arrival: start + .milliseconds(100))
        let firstAfter = live.video(frame(0, key: true), arrival: start + .milliseconds(20_100))
        #expect(abs((firstAfter.pts - lastBefore.pts).seconds - 20) < 0.01, "\((firstAfter.pts - lastBefore.pts).seconds) s for 20 s")
        let next = live.video(frame(0.1), arrival: start + .milliseconds(20_200))
        #expect(abs((next.pts - firstAfter.pts).seconds - 0.1) < 0.001)

        // A 12 s GOP: the first keyframe restamped by its age (1 s), the next one 11 s later.
        var longGOP = TimelineRebaser()
        let k1 = longGOP.video(frame(1, key: true), arrival: start)
        let k2 = longGOP.video(frame(12, key: true), arrival: start + .milliseconds(11_000))
        #expect(abs((k2.pts - k1.pts).seconds - 11) < 0.01, "\((k2.pts - k1.pts).seconds) s for 11 s")

        // Recordings (no arrival): one frame interval, as fMP4 decode times need.
        var recording = TimelineRebaser()
        _ = recording.video(frame(5, key: true))
        let before = recording.video(frame(5.1))
        let after = recording.video(frame(0, key: true))
        #expect(abs((after.pts - before.pts).seconds - 0.1) < 0.001)
    }

    /// The same end to end: a live view whose camera drops for 3 s and comes back on a new timeline keeps RTP time with
    /// arrival time (before the fix: 0.1 s of media time for the outage, and every later frame "late" by it).
    @Test(.timeLimit(.minutes(1))) func rtpTimeKeepsPaceAcrossACameraReconnect() async throws {
        let hub = MediaHub()
        let setup = RuntimeLiveStreamTests.setup(source: syntheticSource(width: 320, height: 180, fps: 10, gop: .seconds(1), audio: nil), hub: hub)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await RuntimeLiveStreamTests.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await RuntimeLiveStreamTests.connect(receiver, to: response)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: RuntimeLiveStreamTests.video(1280, 720), audio: nil))
        #expect(await receiver.waitFor(timeout: .seconds(6)) { $0.keyframes >= 2 && $0.videoFrames >= 15 })
        await setup.feeder.stop()
        try await Task.sleep(for: .seconds(3))
        await hub.discontinuity()   // what IngestSupervisor does after every connection
        let dropped = try #require(await receiver.frameRecords.last)
        let again = HubFeeder(source: syntheticSource(width: 320, height: 180, fps: 10, gop: .seconds(1), audio: nil), hub: hub)
        #expect(await eventually(timeout: .seconds(10)) { await receiver.frameRecords.filter { $0.receivedAt > dropped.receivedAt }.count >= 10 })
        let after = await receiver.frameRecords.filter { $0.receivedAt > dropped.receivedAt }
        let resumed = try #require(after.first)
        let mediaGap = Double(Int32(bitPattern: resumed.rtpTimestamp &- dropped.rtpTimestamp)) / 90_000
        let arrivalGap = Self.seconds(resumed.receivedAt - dropped.receivedAt)
        #expect(abs(mediaGap - arrivalGap) < 0.3, "\(mediaGap) s of media time for \(arrivalGap) s across the reconnect")
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await again.stop()
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// Shifts every sample's wall clock by `skew` seconds: an RTSP camera whose clock (RTCP sender reports) runs ahead of
/// (positive) or behind (negative) the Mac's.
final class SkewedClockSource: MediaSource {
    let base: any MediaSource
    let skew: TimeInterval
    var displayName: String { base.displayName }

    init(base: any MediaSource, skew: TimeInterval) {
        self.base = base
        self.skew = skew
    }

    func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> {
        let upstream = try await base.samples()
        let skew = skew
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self)
        let task = Task {
            do {
                for try await sample in upstream {
                    switch sample {
                    case .video(var frame):
                        frame.wallClock += skew
                        continuation.yield(.video(frame))
                    case .audio(var frame):
                        frame.wallClock += skew
                        continuation.yield(.audio(frame))
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func stop() async { await base.stop() }
}
#endif
