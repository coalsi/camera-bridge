// Camera RTP quirks as test input: access units packetized with the packetizer, then re-stamped the way some cameras send
// them (duplicate and backward-jumping RTP timestamps, marker bits on only some frames, a vendor SEI in front of each
// picture), and the path every frame takes from there: depacketizer -> MediaPipeline -> MediaHub -> VideoTranscoder.
#if os(macOS)
import BridgeSupport
import Foundation
import MediaCore
import PlatformApple
import RTP
import Testing
@testable import RTSP

/// H.264 Annex B -> access units (ITU-T H.264 7.4.1.2.3): a new picture starts at the first VCL NAL with first_mb_in_slice
/// == 0; AUD / SPS / PPS / SEI after a VCL NAL belong to the following picture.
enum AnnexBPictures {
    struct Picture {
        var nalUnits: [Data]
        var isKeyframe: Bool
    }

    static func firstMB(_ nal: Data) -> UInt32? {
        var reader = BitReader(NALUnits.removeEmulationPrevention(Data(nal.dropFirst().prefix(8))))
        return try? reader.ue()
    }

    static func split(_ stream: Data) -> [Picture] {
        var pictures: [Picture] = []
        var current: [Data] = []
        var hasVCL = false
        var keyframe = false
        func finish() {
            if hasVCL { pictures.append(Picture(nalUnits: current, isKeyframe: keyframe)) }
            current = []
            hasVCL = false
            keyframe = false
        }
        for nal in NALUnits.splitAnnexB(stream) {
            switch NALUnits.h264Type(nal) {
            case 1, 5:
                if hasVCL, firstMB(nal) == 0 { finish() }
                hasVCL = true
                if NALUnits.h264Type(nal) == 5 { keyframe = true }
            case 6, 7, 8, 9:
                if hasVCL { finish() }
            default:
                break
            }
            current.append(nal)
        }
        finish()
        return pictures
    }

    /// Pictures as frames (SPS/PPS/AUD removed: they are in `format`; the SEI stays) at `fps`.
    static func frames(_ pictures: [Picture], fps: Int) -> [EncodedVideoFrame] {
        var store = H264ParameterSetStore()
        for picture in pictures { for nal in picture.nalUnits { store.add(nal) } }
        guard let format = store.format else { return [] }
        let start = Date()
        return pictures.enumerated().map { index, picture in
            EncodedVideoFrame(format: format, nalUnits: picture.nalUnits.filter { ![7, 8, 9].contains(NALUnits.h264Type($0)) }, isKeyframe: picture.isKeyframe,
                              pts: MediaTime(value: Int64(index) * Int64(90_000 / fps), timescale: 90_000), wallClock: start.addingTimeInterval(Double(index) / Double(fps)))
        }
    }
}

/// How a camera stamps and marks its pictures (index = picture number, `step` = one frame interval in 90 kHz ticks).
struct RTPQuirk: Sendable {
    var name: String
    var timestamp: @Sendable (_ index: Int, _ frame: EncodedVideoFrame, _ step: UInt32) -> UInt32
    /// Whether the last packet of picture `index` carries the marker bit.
    var marker: @Sendable (_ index: Int, _ count: Int) -> Bool

    static let wellBehaved = RTPQuirk(name: "well-behaved", timestamp: { index, _, step in 1_000_000 + UInt32(index) * step }, marker: { _, _ in true })

    /// Every 4th picture reuses the previous picture's timestamp, and the marker bit is set only where the timestamp
    /// changes next (a camera that treats the timestamp as the access unit's identity): two pictures per "frame".
    static let duplicateTimestamps = RTPQuirk(
        name: "duplicate timestamps, marker at timestamp changes only",
        timestamp: { index, _, step in 1_000_000 + UInt32(index - index / 4) * step },
        marker: { index, count in index + 1 >= count || (index + 1) % 4 != 0 })

    /// Pictures that share a timestamp and no marker bit anywhere.
    static let noMarkers = RTPQuirk(
        name: "duplicate timestamps, no marker bits",
        timestamp: { index, _, step in 1_000_000 + UInt32(index - index / 4) * step }, marker: { _, _ in false })

    /// Keyframes stamped 7 frame intervals ahead of the delta frames' own clock, which then runs behind the keyframe's
    /// timestamp for 7 pictures (the Tapo pattern: "45000 >= 15401, 19901, ... 42401").
    static let keyframesStampedAhead = RTPQuirk(
        name: "keyframes stamped ahead, deltas catching up",
        timestamp: { index, frame, step in 1_000_000 + UInt32(index) * step + (frame.isKeyframe ? 7 * step : 0) }, marker: { _, _ in true })

    /// All of it together.
    static let everything = RTPQuirk(
        name: "ahead keyframes + duplicates + sparse markers",
        timestamp: { index, frame, step in 1_000_000 + UInt32(index - index / 5) * step + (frame.isKeyframe ? 7 * step : 0) },
        marker: { index, count in index + 1 >= count || (index + 1) % 5 != 0 })

    static let all = [wellBehaved, duplicateTimestamps, noMarkers, keyframesStampedAhead, everything]
}

enum QuirkyRTP {
    static let log = Log(category: "QuirkyRTP")

    /// The packets of `frames` stamped by `quirk`. `step`: 90 kHz ticks per picture.
    static func packets(_ frames: [EncodedVideoFrame], quirk: RTPQuirk, step: UInt32) -> [[RTPPacket]] {
        var packetizer = H264Packetizer(payloadType: 96, ssrc: 0x7a90, maxPacketSize: 1400, initialSequence: 100)
        return frames.enumerated().map { index, frame in
            var packets = packetizer.packetize(frame, rtpTimestamp: quirk.timestamp(index, frame, step))
            for packetIndex in packets.indices { packets[packetIndex].marker = packetIndex == packets.count - 1 && quirk.marker(index, frames.count) }
            return packets
        }
    }

    /// Everything the pipeline delivers for `packets` (one sub-array per picture, arriving 1/fps apart).
    static func ingest(_ packets: [[RTPPacket]], format: VideoFormat?, fps: Int) async throws -> [EncodedVideoFrame] {
        let track = RTSPTrack(kind: .video, control: "v", payloadType: 96, encoding: "H264", clockRate: 90_000)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self)
        let plan = MediaPipeline.TrackPlan(track: track, rtpChannel: 0, rtcpChannel: 1, videoFormat: format, audioFormat: nil)
        let pipeline = MediaPipeline(plans: [plan], continuation: continuation, log: log)
        let start = Date()
        for (index, group) in packets.enumerated() {
            for packet in group { pipeline.handle(channel: 0, payload: packet.serialized(), arrival: start.addingTimeInterval(Double(index) / Double(fps))) }
        }
        pipeline.finish(throwing: nil)
        var frames: [EncodedVideoFrame] = []
        for try await sample in stream {
            if case .video(let frame) = sample { frames.append(frame) }
        }
        return frames
    }

    /// `frames` through a `MediaHub` subscription that starts at a keyframe.
    static func throughHub(_ frames: [EncodedVideoFrame]) async -> [EncodedVideoFrame] {
        let hub = MediaHub(retention: .seconds(12))
        let subscription = await hub.subscribe(from: .nextKeyframe, bufferLimit: frames.count + 16)
        for frame in frames { await hub.ingest(.video(frame)) }
        subscription.cancel()
        var received: [EncodedVideoFrame] = []
        for await sample in subscription.samples {
            if case .video(let frame) = sample { received.append(frame) }
        }
        return received
    }

    /// What the transcoder makes of `frames` (decode -> scale -> encode at `fps`, so nothing is skipped), and the first
    /// failure if decoding raised one.
    static func transcode(_ frames: [EncodedVideoFrame], width: Int, height: Int, fps: Int) async throws -> [EncodedVideoFrame] {
        let transcoder = try AppleMediaCodecs().makeVideoTranscoder(output: VideoEncoderSettings(width: width, height: height, fps: fps, bitrateKbps: 2_000,
                                                                                                 keyframeInterval: .seconds(4)))
        defer { transcoder.invalidate() }
        var output: [EncodedVideoFrame] = []
        for frame in frames { output += try await transcoder.transcode(frame) }
        return output
    }

    /// Decodes every frame directly (a failing delta frame is reported, not skipped): the number of pictures decoded and
    /// the index of the first frame that failed.
    static func decode(_ frames: [EncodedVideoFrame]) async throws -> (pictures: Int, firstFailure: (index: Int, error: any Error)?) {
        guard let first = frames.first else { return (0, nil) }
        let decoder = try AppleMediaCodecs().makeVideoDecoder(format: first.format)
        defer { decoder.invalidate() }
        var pictures = 0
        for (index, frame) in frames.enumerated() {
            do {
                if try await decoder.decode(frame) != nil { pictures += 1 }
            } catch {
                return (pictures, (index, error))
            }
        }
        return (pictures, nil)
    }
}

/// The local capture of a real Tapo stream (never committed; `nil` where the file is absent).
enum TapoCapture {
    /// `Tools/captures/tapo.h264` in the repository (the captures folder is not committed), else `CAMERABRIDGE_TAPO_CAPTURE`.
    static let defaultPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Tools/captures/tapo.h264")
        .standardizedFileURL.path

    static func pictures() -> [AnnexBPictures.Picture]? {
        let path = ProcessInfo.processInfo.environment["CAMERABRIDGE_TAPO_CAPTURE"] ?? defaultPath
        guard FileManager.default.fileExists(atPath: path), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return AnnexBPictures.split(data)
    }
}
#endif
