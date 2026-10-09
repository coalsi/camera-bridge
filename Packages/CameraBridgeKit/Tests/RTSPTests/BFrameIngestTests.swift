// Real H.264 with B-frames from VideoToolbox through the RTSP ingest (and the transcoder behind it), macOS only.
#if os(macOS)
import BridgeSupport
import Foundation
import MediaCore
import PlatformApple
import RTP
import Testing
@testable import RTSP

/// Review finding (B-frames over RTSP): the RTP timestamp is the presentation time (RFC 6184 §5.1), which steps back in
/// decode order. The ingest re-timed every such step, so the frames carried decode-order times (B-frames shown out of
/// order after transcoding) on a timeline running about 3× slow. It now keeps the presentation times and marks
/// reordering with increasing decode times.
@Suite(.timeLimit(.minutes(1))) struct BFrameIngestTests {
    static let fps = 25

    /// Sends `frames` (decode order) through a `MediaPipeline` as a camera does: RTP timestamp = presentation time, one
    /// access unit per frame interval.
    static func ingest(_ frames: [EncodedVideoFrame]) async throws -> [EncodedVideoFrame] {
        let track = RTSPTrack(kind: .video, control: "v", payloadType: 96, encoding: "H264", clockRate: 90_000)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self)
        let plan = MediaPipeline.TrackPlan(track: track, rtpChannel: 0, rtcpChannel: 1, videoFormat: frames.first?.format, audioFormat: nil)
        let pipeline = MediaPipeline(plans: [plan], continuation: continuation, log: Log(category: "BFrameIngestTests"))
        var packetizer = H264Packetizer(payloadType: 96, ssrc: 7, initialSequence: 1)
        let start = Date()
        for (index, frame) in frames.enumerated() {
            let timestamp = UInt32(truncatingIfNeeded: 1_000_000 + frame.pts.converted(to: 90_000).value)
            for packet in packetizer.packetize(frame, rtpTimestamp: timestamp) {
                pipeline.handle(channel: 0, payload: packet.serialized(), arrival: start.addingTimeInterval(Double(index) / Double(fps)))
            }
        }
        pipeline.finish(throwing: nil)
        var received: [EncodedVideoFrame] = []
        for try await sample in stream {
            if case .video(let frame) = sample { received.append(frame) }
        }
        return received
    }

    /// Transcodes `frames` to 640×360 at 25 fps and returns the picture number each output frame shows, in output order.
    static func transcode(_ frames: [EncodedVideoFrame]) async throws -> [Int] {
        let codecs = AppleMediaCodecs()
        let transcoder = try codecs.makeVideoTranscoder(output: VideoEncoderSettings(width: 640, height: 360, fps: fps, bitrateKbps: 2_000,
                                                                                     keyframeInterval: .seconds(4)))
        defer { transcoder.invalidate() }
        var output: [EncodedVideoFrame] = []
        for frame in frames { output += try await transcoder.transcode(frame) }
        #expect(zip(output.dropFirst(), output).allSatisfy { $0.pts > $1.pts }, "output presentation times increase")
        guard let first = output.first else { return [] }
        let decoder = try codecs.makeVideoDecoder(format: first.format)
        defer { decoder.invalidate() }
        var shown: [Int] = []
        for frame in output {
            let picture = try #require(try await decoder.decode(frame))
            shown.append(try #require(BFrameStream.index(of: picture)))
        }
        return shown
    }

    @Test func presentationTimesSurviveTheIngestWithIncreasingDecodeTimes() async throws {
        let source = try BFrameStream.encode(count: 60, fps: Self.fps, keyframes: [30])
        try #require(BFrameStream.reorders(source))
        let frames = try await Self.ingest(source)
        try #require(frames.count == source.count)
        // The camera's presentation times (relative to the first frame), B-frames included.
        let base = frames[0].pts.value
        let sourceBase = source[0].pts.value
        #expect(frames.map { $0.pts.value - base } == source.map { $0.pts.value - sourceBase })
        #expect(frames.map(\.isKeyframe) == source.map(\.isKeyframe))
        // Decode times increase strictly, and reordering is marked (StreamTraits sees B-frames on any codec).
        let decode = frames.map { ($0.dts ?? $0.pts).value }
        #expect(zip(decode.dropFirst(), decode).allSatisfy { $0 > $1 }, "\(decode)")
        #expect(frames.contains { $0.dts != nil })
        // Decode time runs at the frame rate: it ends within a few frames of the newest presentation time (the old
        // re-timing stretched the timeline about 3×).
        let newest = try #require(frames.map(\.pts.value).max())
        #expect(newest - decode[decode.count - 1] <= 4 * 3_600, "decode \(decode[decode.count - 1]) vs presentation \(newest)")
        #expect(newest - base == 59 * 3_600)
    }

    /// The verification's end-to-end path, RTSP ingest → transcoder: a recording or live view joins the running ingest at a
    /// keyframe (hub subscribers start at one), and every picture from there comes out once, in display order.
    @Test func transcodingTheIngestKeepsDisplayOrderAndEveryPicture() async throws {
        let source = try BFrameStream.encode(count: 61, fps: Self.fps, keyframes: [30, 60])
        let frames = try await Self.ingest(source)
        try #require(frames.count == source.count)
        let join = try #require(frames.indices.first { $0 > 0 && frames[$0].isKeyframe })
        let shown = try await Self.transcode(Array(frames[join...]))
        #expect(Array(shown.prefix(30)) == (30..<60).map { $0 % 50 }, "\(shown)")
        #expect(shown.count <= 31)
    }

    /// A transcoder that starts with the connection sees the first anchor before any B-frame shows the stream reorders:
    /// at most that group's B-frames are lost, and no picture goes out of order.
    @Test func transcodingFromTheFirstFrameNeverSendsPicturesOutOfOrder() async throws {
        let source = try BFrameStream.encode(count: 31, fps: Self.fps, keyframes: [30])
        let frames = try await Self.ingest(source)
        try #require(frames.count == source.count)
        let shown = try await Self.transcode(frames)
        #expect(zip(shown.dropFirst(), shown).allSatisfy { $0 > $1 }, "\(shown)")
        let missing = Set(0..<30).subtracting(shown)
        #expect(missing.count <= 3 && missing.allSatisfy { $0 < 4 }, "missing \(missing.sorted())")
    }
}
#endif
