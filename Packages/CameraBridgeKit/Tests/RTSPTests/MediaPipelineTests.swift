import BridgeSupport
import Foundation
import MediaCore
import RTP
import Synchronization
import Testing
@testable import RTSP

private let h264Format = RTSPSessionDescription.makeH264Format(sps: RealParameterSets.h264Main640x360.sps, pps: RealParameterSets.h264Main640x360.pps)
private let videoTrack = RTSPTrack(kind: .video, control: "v", payloadType: 96, encoding: "H264", clockRate: 90_000)
private let audioTrack = RTSPTrack(kind: .audio, control: "a", payloadType: 0, encoding: "PCMU", clockRate: 8000)
private let pcmu = AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1)

private func makePipeline(bufferLimit: Int? = nil) -> (MediaPipeline, AsyncThrowingStream<MediaSample, any Error>) {
    let policy: AsyncThrowingStream<MediaSample, any Error>.Continuation.BufferingPolicy = bufferLimit.map { .bufferingOldest($0) } ?? .unbounded
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self, bufferingPolicy: policy)
    let pipeline = MediaPipeline(plans: [
        MediaPipeline.TrackPlan(track: videoTrack, rtpChannel: 0, rtcpChannel: 1, videoFormat: h264Format, audioFormat: nil),
        MediaPipeline.TrackPlan(track: audioTrack, rtpChannel: 2, rtcpChannel: 3, videoFormat: nil, audioFormat: pcmu),
    ], continuation: continuation, log: Log(category: "test"))
    return (pipeline, stream)
}

private func videoPacket(_ index: Int, keyframeEvery: Int = 10, sequence: UInt16? = nil, isKeyframe: Bool? = nil) -> Data {
    let key = isKeyframe ?? (index % keyframeEvery == 0)
    return RTPPacket(marker: true, payloadType: 96, sequenceNumber: sequence ?? UInt16(truncatingIfNeeded: index), timestamp: UInt32(index * 3600),
                     ssrc: 1, payload: h264NAL(type: key ? 5 : 1, size: 40, seed: UInt8(index % 200))).serialized()
}

private func audioPacket(_ index: Int) -> Data {
    RTPPacket(marker: true, payloadType: 0, sequenceNumber: UInt16(truncatingIfNeeded: index), timestamp: UInt32(index * 160), ssrc: 2,
              payload: filler(160)).serialized()
}

private func senderReport() -> Data {
    var writer = ByteWriter()
    writer.write(0x80); writer.write(200); writer.writeUInt16BE(6); writer.writeUInt32BE(1)
    writer.writeUInt64BE(NTPTime.timestamp(for: Date())); writer.writeUInt32BE(0); writer.writeUInt32BE(0); writer.writeUInt32BE(0)
    return writer.data
}

@Suite struct MediaPipelineWatchdogTests {
    @Test func audioAndRTCPDoNotCountAsVideoProgress() async throws {
        let (pipeline, stream) = makePipeline()
        pipeline.handle(channel: 0, payload: videoPacket(0), arrival: Date())
        let afterVideo = pipeline.progress
        try await Task.sleep(for: .milliseconds(50))
        for i in 0..<5 {
            pipeline.handle(channel: 2, payload: audioPacket(i), arrival: Date())
            pipeline.handle(channel: 1, payload: senderReport(), arrival: Date())
            pipeline.handle(channel: 3, payload: senderReport(), arrival: Date())
        }
        let afterAudio = pipeline.progress
        #expect(afterAudio.videoPacket == afterVideo.videoPacket)
        #expect(afterAudio.videoFrame == afterVideo.videoFrame)
        pipeline.finish(throwing: nil)
        withExtendedLifetime(stream) {}
    }

    @Test func undecodableVideoRefreshesPacketsButNotFrames() async throws {
        let (pipeline, stream) = makePipeline()
        let start = pipeline.progress
        try await Task.sleep(for: .milliseconds(50))
        // Delta frames only: every one is dropped while waiting for a keyframe.
        for i in 1..<9 { pipeline.handle(channel: 0, payload: videoPacket(i), arrival: Date()) }
        let waiting = pipeline.progress
        #expect(waiting.videoPacket > start.videoPacket)
        #expect(waiting.videoFrame == start.videoFrame)
        try await Task.sleep(for: .milliseconds(20))
        pipeline.handle(channel: 0, payload: videoPacket(9, isKeyframe: true), arrival: Date())
        #expect(pipeline.progress.videoFrame > waiting.videoFrame)
        pipeline.finish(throwing: nil)
        withExtendedLifetime(stream) {}
    }
}

@Suite struct MediaPipelineDeliveryTests {
    @Test func slowConsumerBoundsTheBufferAndVideoResumesAtAKeyframe() async throws {
        let (pipeline, stream) = makePipeline(bufferLimit: 20)
        let arrival = Date()
        // 60 frames (keyframes at 0, 10, ...) with nobody reading: only the first 20 samples are buffered.
        for i in 0..<60 { pipeline.handle(channel: 0, payload: videoPacket(i), arrival: arrival) }
        #expect(pipeline.droppedSampleCount == 40)
        // The consumer catches up; later delta frames depend on dropped ones, so video restarts at the next keyframe.
        var iterator = stream.makeAsyncIterator()
        var received: [EncodedVideoFrame] = []
        for _ in 0..<20 {
            if case .video(let frame)? = try await iterator.next() { received.append(frame) }
        }
        pipeline.handle(channel: 0, payload: videoPacket(60, isKeyframe: false), arrival: arrival)
        for i in 61..<85 { pipeline.handle(channel: 0, payload: videoPacket(i), arrival: arrival) }
        pipeline.finish(throwing: nil)
        while let sample = try await iterator.next() {
            if case .video(let frame) = sample { received.append(frame) }
        }
        #expect(received.count == 20 + 15, "frames 70...84 after the drop, starting at keyframe 70")
        #expect(received.dropFirst(20).first?.isKeyframe == true)
        #expect(received.dropFirst(20).first?.pts.value == Int64(70 * 3600))
        #expect(pipeline.droppedSampleCount == 50)
    }

    @Test func audioDropsDoNotHoldBackVideo() async throws {
        let (pipeline, stream) = makePipeline(bufferLimit: 4)
        let arrival = Date()
        pipeline.handle(channel: 0, payload: videoPacket(0), arrival: arrival)
        for i in 0..<10 { pipeline.handle(channel: 2, payload: audioPacket(i), arrival: arrival) }
        #expect(pipeline.droppedSampleCount == 7)
        var iterator = stream.makeAsyncIterator()
        for _ in 0..<4 { _ = try await iterator.next() }
        pipeline.handle(channel: 0, payload: videoPacket(1), arrival: arrival)   // a delta frame: no video was dropped
        pipeline.finish(throwing: nil)
        var video = 0
        while let sample = try await iterator.next() { if case .video = sample { video += 1 } }
        #expect(video == 1)
    }
}

/// A camera whose clock runs `offset` s from the Mac's (within `TrackWallClock`'s tolerance, so its sender reports are
/// believed); times are seconds after `start` on the Mac's clock.
private struct OffsetCamera {
    static let videoBase: Int64 = 1_000_000
    static let audioBase: Int64 = 40_000

    let start = Date()
    let offset: TimeInterval

    private func timestamp(_ capture: TimeInterval, base: Int64, rate: Double) -> UInt32 {
        UInt32(truncatingIfNeeded: base + Int64((capture * rate).rounded()))
    }

    func keyframe(capture: TimeInterval) -> Data {
        RTPPacket(marker: true, payloadType: 96, sequenceNumber: 0, timestamp: timestamp(capture, base: Self.videoBase, rate: 90_000), ssrc: 1,
                  payload: h264NAL(type: 5, size: 40)).serialized()
    }

    func audioFrame(capture: TimeInterval, sequence: Int) -> Data {
        RTPPacket(marker: true, payloadType: 0, sequenceNumber: UInt16(truncatingIfNeeded: sequence), timestamp: timestamp(capture, base: Self.audioBase, rate: 8000),
                  ssrc: 2, payload: filler(160)).serialized()
    }

    /// A sender report sent at `time`: the camera's clock then, and the RTP timestamp of that instant.
    func report(video: Bool, time: TimeInterval) -> Data {
        var writer = ByteWriter()
        writer.write(0x80); writer.write(200); writer.writeUInt16BE(6); writer.writeUInt32BE(video ? 1 : 2)
        writer.writeUInt64BE(NTPTime.timestamp(for: start.addingTimeInterval(time + offset)))
        writer.writeUInt32BE(video ? timestamp(time, base: Self.videoBase, rate: 90_000) : timestamp(time, base: Self.audioBase, rate: 8000))
        writer.writeUInt32BE(0); writer.writeUInt32BE(0)
        return writer.data
    }

    /// Audio frames every 20 ms from `from` to `to` (arrival), each captured `latency` s before it arrives.
    func audio(from: TimeInterval, to: TimeInterval, latency: TimeInterval) -> [(TimeInterval, UInt8, Data)] {
        stride(from: from, to: to, by: 0.02).enumerated().map { index, arrival in
            (arrival, 2, audioFrame(capture: arrival - latency, sequence: index))
        }
    }

    /// Runs `events` (arrival, channel, payload) in arrival order; returns the pts (s) of every video and audio frame, in order.
    func allPTS(_ events: [(TimeInterval, UInt8, Data)], log: Log = Log(category: "test")) async throws -> (video: [Double], audio: [Double]) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self)
        let pipeline = MediaPipeline(plans: [
            MediaPipeline.TrackPlan(track: videoTrack, rtpChannel: 0, rtcpChannel: 1, videoFormat: h264Format, audioFormat: nil),
            MediaPipeline.TrackPlan(track: audioTrack, rtpChannel: 2, rtcpChannel: 3, videoFormat: nil, audioFormat: pcmu),
        ], continuation: continuation, log: log)
        let ordered = events.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
        for (_, (arrival, channel, payload)) in ordered { pipeline.handle(channel: channel, payload: payload, arrival: start.addingTimeInterval(arrival)) }
        pipeline.finish(throwing: nil)
        var video: [Double] = []
        var audio: [Double] = []
        for try await sample in stream {
            switch sample {
            case .video(let frame): video.append(frame.pts.seconds)
            case .audio(let frame): audio.append(frame.pts.seconds)
            }
        }
        return (video, audio)
    }

    /// Runs `events` (arrival, channel, payload) in arrival order; returns the pts (s) of the first video and audio frame.
    func firstPTS(_ events: [(TimeInterval, UInt8, Data)]) async throws -> (video: Double, audio: Double) {
        let (pipeline, stream) = makePipeline()
        let ordered = events.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
        for (_, (arrival, channel, payload)) in ordered { pipeline.handle(channel: channel, payload: payload, arrival: start.addingTimeInterval(arrival)) }
        pipeline.finish(throwing: nil)
        var video: Double?
        var audio: Double?
        for try await sample in stream {
            switch sample {
            case .video(let frame): video = video ?? frame.pts.seconds
            case .audio(let frame): audio = audio ?? frame.pts.seconds
            }
        }
        return (try #require(video), try #require(audio))
    }
}

/// Every track's origin comes from one clock: a camera clock offset must never become an A/V offset.
@Suite struct MediaPipelineAlignmentTests {
    /// Audio flows from PLAY before any sender report; video's report arrives before its first keyframe. Only one
    /// track has a report, so both are placed by arrival.
    @Test(arguments: [-2.0, -1.0, 2.5])
    func videoReportOnlyAlignsByArrival(_ offset: TimeInterval) async throws {
        let camera = OffsetCamera(offset: offset)
        var events = camera.audio(from: 0, to: 2, latency: 0.05)
        events.append((1.0, 1, camera.report(video: true, time: 1.0)))
        events.append((1.5, 0, camera.keyframe(capture: 1.3)))
        let first = try await camera.firstPTS(events)
        #expect(abs((first.video - first.audio) - 1.5) < 0.001, "video \(first.video) s, audio \(first.audio) s")
    }

    /// The keyframe arrives before any report; audio's report arrives before its first frame.
    @Test(arguments: [-2.0, 2.5])
    func audioReportOnlyAlignsByArrival(_ offset: TimeInterval) async throws {
        let camera = OffsetCamera(offset: offset)
        var events = camera.audio(from: 0.5, to: 1.5, latency: 0.05)
        events.append((0, 0, camera.keyframe(capture: -0.2)))
        events.append((0.3, 3, camera.report(video: false, time: 0.3)))
        let first = try await camera.firstPTS(events)
        #expect(abs((first.audio - first.video) - 0.5) < 0.001, "video \(first.video) s, audio \(first.audio) s")
    }

    /// Both tracks have a report when the second track starts (the first track's may arrive after its first unit):
    /// the camera's capture times place them, so different track latencies do not skew them.
    @Test(arguments: [(-2.0, false), (-2.0, true), (2.5, false), (2.5, true)])
    func reportsOnBothTracksAlignByCaptureTime(_ offset: TimeInterval, reportsFirst: Bool) async throws {
        let camera = OffsetCamera(offset: offset)
        var events = camera.audio(from: 0, to: 2, latency: 0.05)
        let reportTime = reportsFirst ? -0.5 : 0.3
        events.append((reportTime, 3, camera.report(video: false, time: reportTime)))
        events.append((1.0, 1, camera.report(video: true, time: 1.0)))
        events.append((1.5, 0, camera.keyframe(capture: 1.3)))   // 0.2 s video latency
        let first = try await camera.firstPTS(events)
        #expect(abs((first.video - first.audio) - 1.35) < 0.001, "video \(first.video) s, audio \(first.audio) s")
    }
}

/// A camera that starts a session with the keyframe it kept (captured before audio began to flow): the keyframe's capture time
/// precedes the audio's first, by the reports of both tracks. The video's first picture is at 0, so the audio that follows must
/// be placed by capture time relative to it (clamping the video at 0 and leaving the audio at 0 made the audio trail by the
/// age of that keyframe: a recording dropped every audio frame older than its first picture, which was all of them).
@Suite struct MediaPipelineEarlierVideoTests {
    /// Audio from arrival 0 (captured 50 ms before it arrives); both tracks' reports; a keyframe arriving at 1.5 s that was
    /// captured at -1.0 s, before the first audio frame (-0.05 s).
    private func events(_ camera: OffsetCamera) -> [(TimeInterval, UInt8, Data)] {
        var events = camera.audio(from: 0, to: 3, latency: 0.05)
        events.append((0.3, 3, camera.report(video: false, time: 0.3)))
        events.append((1.0, 1, camera.report(video: true, time: 1.0)))
        events.append((1.5, 0, camera.keyframe(capture: -1.0)))
        return events
    }

    @Test(arguments: [0.5, 1.0])
    func audioAfterAKeyframeCapturedBeforeItStaysAlignedWithThatVideo(_ offset: TimeInterval) async throws {
        let camera = OffsetCamera(offset: offset)
        let pts = try await camera.allPTS(events(camera))
        #expect(pts.video.first == 0)
        // Audio frame N arrives at N × 20 ms and was captured 50 ms earlier; the video's first picture was captured at -1 s.
        // From the keyframe's arrival on (frame 75), pts must be N × 20 ms + 1.0 − 0.05 (what was captured at that instant is at
        // the same time as the picture's).
        var checked = 0
        for (index, value) in pts.audio.enumerated() where index >= 76 {
            #expect(abs(value - (Double(index) * 0.02 + 0.95)) < 0.001, "audio frame \(index) at \(value) s")
            checked += 1
        }
        #expect(checked > 50)
        #expect(zip(pts.audio.dropFirst(), pts.audio).allSatisfy { $0 > $1 }, "audio times still increase")
    }

    @Test func theAlignmentIsLoggedOnce() async throws {
        final class Lines: LogSink {
            let lines = Mutex<[String]>([])
            func record(_ entry: LogEntry) { if entry.category == "AlignmentTest" { lines.withLock { $0.append(entry.message) } } }
        }
        let sink = Lines()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let camera = OffsetCamera(offset: 0.5)
        _ = try await camera.allPTS(events(camera), log: Log(category: "AlignmentTest"))
        let lines = sink.lines.withLock { $0 }
        #expect(lines.count == 1 && lines[0].contains("captured 0.95 s before the audio began") && lines[0].contains("sender reports"), "\(lines)")
    }

    /// The usual case is unchanged: audio first, video's keyframe captured after the audio began.
    @Test func aKeyframeCapturedAfterTheAudioBeganIsPlacedAfterIt() async throws {
        let camera = OffsetCamera(offset: 0.5)
        var events = camera.audio(from: 0, to: 3, latency: 0.05)
        events.append((0.3, 3, camera.report(video: false, time: 0.3)))
        events.append((1.0, 1, camera.report(video: true, time: 1.0)))
        events.append((1.5, 0, camera.keyframe(capture: 1.3)))
        let pts = try await camera.allPTS(events)
        #expect(abs(pts.video[0] - 1.35) < 0.001)
        #expect(pts.audio.enumerated().allSatisfy { abs($0.element - Double($0.offset) * 0.02) < 0.001 }, "audio keeps its own origin")
    }
}

/// A peer that never reads: every send stays pending.
private final class StalledConnection: TCPConnection {
    let id = UUID()
    var localAddress: String { "127.0.0.1" }
    var remoteAddress: String { "127.0.0.1" }
    var isIPv6: Bool { false }
    func receive(maximumLength: Int) async throws -> Data? {
        try await Task.sleep(for: .seconds(3600))
        return nil
    }
    func send(_ data: Data) async throws { try await Task.sleep(for: .seconds(3600)) }
    func close() {}
}

@Suite struct RTSPControlConnectionTests {
    @Test func interleavedSendsAreDroppedWhenThePeerStopsReading() throws {
        let connection = RTSPControlConnection(connection: StalledConnection(), log: Log(category: "test"))
        var accepted = 0
        for _ in 0..<3000 where try connection.send(Data(count: 1024)) { accepted += 1 }
        #expect(accepted == RTSPControlConnection.maxQueuedBytes / 1024)
        connection.close()
        #expect(throws: TransportError.closed) { try connection.send(Data(count: 1)) }
    }
}
