import BridgeSupport
import CameraAdapters
import FMP4
import Foundation
import HAPCamera
import MediaCore
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

// Helpers for the runtime tests (plan W3-1): fMP4 inspection, a hub fed by a media source, fakes for drivers,
// talkback sinks and power management.

/// A `MediaHub` fed by `source` until `stop()`; `traits` (when given) observes every sample first, as the ingest does.
final class HubFeeder: Sendable {
    let hub: MediaHub
    let source: any MediaSource
    private let task: Task<Void, Never>

    init(source: any MediaSource, hub: MediaHub = MediaHub(), traits: StreamTraits? = nil) {
        self.hub = hub
        self.source = source
        task = Task {
            do {
                for try await sample in try await source.samples() {
                    traits?.observe(sample)
                    await hub.ingest(sample)
                }
            } catch {}
        }
    }

    func stop() async {
        task.cancel()
        await source.stop()
    }

    /// Waits until the hub holds a keyframe and has measured a GOP (two keyframes seen).
    func waitUntilReady(timeout: Duration = .seconds(10)) async -> Bool {
        await eventually(timeout: timeout) {
            let keyframe = await self.hub.lastKeyframe
            let gop = await self.hub.measuredGOPDuration
            return keyframe != nil && gop != nil
        }
    }
}

enum RecordingFixtures {
    static func configuration(width: Int = 1280, height: Int = 720, profile: H264Profile = .main, level: H264Level = .level4_0,
                              prebufferMs: Int = 1000, fragmentMs: Int = 1000, bitrate: Int = 800) -> CameraRecordingConfiguration {
        CameraRecordingConfiguration(prebufferLengthMs: prebufferMs, eventTriggers: RecordingEventTrigger.motion, fragmentLengthMs: fragmentMs,
                                     videoProfile: profile, videoLevel: level, videoBitrateKbps: bitrate, iFrameIntervalMs: fragmentMs,
                                     resolution: VideoResolution(width, height, 30), audioCodec: .aacLC, audioChannels: 1,
                                     audioSampleRate: .khz32, audioMaxBitrateKbps: 24)
    }
}

/// One received packet with the time it arrived.
struct ReceivedPacket: Sendable {
    var packet: RecordingPacket
    var at: ContinuousClock.Instant
}

/// Reads `stream` until it ends (or `limit` packets arrived); errors end the read.
func collect(_ stream: AsyncThrowingStream<RecordingPacket, any Error>, limit: Int = .max) async -> (packets: [ReceivedPacket], error: (any Error)?) {
    var packets: [ReceivedPacket] = []
    do {
        for try await packet in stream {
            packets.append(ReceivedPacket(packet: packet, at: .now))
            if packets.count >= limit { break }
        }
        return (packets, nil)
    } catch {
        return (packets, error)
    }
}

/// A minimal fMP4 reader for recording checks (ISO/IEC 14496-12: tfhd, tfdt v0/v1, trun).
struct FragmentInfo: Sendable {
    struct Track: Sendable {
        var trackID: UInt32
        var baseDecodeTime: UInt64
        var durations: [UInt32]
        var sizes: [UInt32]
        var flags: [UInt32]
        /// Offset of the first sample's data in the fragment.
        var dataOffset: Int
        var totalDuration: UInt64 { durations.reduce(0) { $0 + UInt64($1) } }
    }

    var tracks: [Track]
    var data: Data

    var video: Track? { tracks.first { $0.trackID == 1 } }
    var audio: Track? { tracks.first { $0.trackID == 2 } }

    init(_ data: Data) throws {
        self.data = data
        let boxes = try MP4BoxReader.parse(data)
        let moof = try #require(boxes.first { $0.type == "moof" })
        #expect(boxes.contains { $0.type == "mdat" })
        var tracks: [Track] = []
        for traf in moof.children(ofType: "traf") {
            let tfhd = try #require(traf.child("tfhd"))
            let tfdt = try #require(traf.child("tfdt"))
            let trun = try #require(traf.child("trun"))
            var reader = ByteReader(data.subdata(in: tfhd.payloadOffset..<(tfhd.offset + tfhd.size)))
            try reader.skip(4)
            let trackID = try reader.readUInt32BE()
            reader = ByteReader(data.subdata(in: tfdt.payloadOffset..<(tfdt.offset + tfdt.size)))
            let version = try reader.readUInt8()
            try reader.skip(3)
            let base = version == 1 ? try reader.readUInt64BE() : UInt64(try reader.readUInt32BE())
            reader = ByteReader(data.subdata(in: trun.payloadOffset..<(trun.offset + trun.size)))
            let flags = try reader.readUInt32BE() & 0xFF_FFFF
            let count = Int(try reader.readUInt32BE())
            var dataOffset = 0
            if flags & 0x01 != 0 { dataOffset = Int(Int32(bitPattern: try reader.readUInt32BE())) }
            if flags & 0x04 != 0 { try reader.skip(4) }
            var durations: [UInt32] = [], sizes: [UInt32] = [], sampleFlags: [UInt32] = []
            for _ in 0..<count {
                if flags & 0x100 != 0 { durations.append(try reader.readUInt32BE()) }
                if flags & 0x200 != 0 { sizes.append(try reader.readUInt32BE()) }
                if flags & 0x400 != 0 { sampleFlags.append(try reader.readUInt32BE()) }
                if flags & 0x800 != 0 { try reader.skip(4) }
            }
            tracks.append(Track(trackID: trackID, baseDecodeTime: base, durations: durations, sizes: sizes, flags: sampleFlags,
                                dataOffset: moof.offset + dataOffset))
        }
        self.tracks = tracks
    }

    /// Every video sample's data (length-prefixed access units), in order.
    func videoSamples() throws -> [Data] {
        let track = try #require(video)
        var samples: [Data] = []
        var offset = track.dataOffset
        for size in track.sizes.map(Int.init) {
            try #require(offset >= 0 && offset + size <= data.count)
            samples.append(data.subdata(in: offset..<(offset + size)))
            offset += size
        }
        return samples
    }

    /// NAL unit types of the first video sample (length-prefixed).
    func firstVideoSampleNALTypes() throws -> [UInt8] {
        let track = try #require(video)
        let size = Int(try #require(track.sizes.first))
        var reader = ByteReader(data.subdata(in: track.dataOffset..<(track.dataOffset + size)))
        var types: [UInt8] = []
        while !reader.isAtEnd {
            let length = Int(try reader.readUInt32BE())
            let nal = try reader.readBytes(length)
            if let header = nal.first { types.append(header & 0x1F) }
        }
        return types
    }
}

/// Top-level box types of an initialization segment and whether it has an audio track.
func initializationTracks(_ data: Data) throws -> (types: [String], trackCount: Int) {
    let boxes = try MP4BoxReader.parse(data)
    let moov = try #require(boxes.first { $0.type == "moov" })
    return (boxes.map(\.type), moov.children(ofType: "trak").count)
}

/// The H.264 format of an initialization segment's `avcC` (ISO/IEC 14496-15 §5.3.3.1): its first SPS and PPS.
func avcCFormat(_ initialization: Data) -> VideoFormat? {
    let bytes = [UInt8](initialization)
    guard bytes.count > 4, let marker = (0..<(bytes.count - 4)).first(where: { Array(bytes[$0..<($0 + 4)]) == Array("avcC".utf8) }) else { return nil }
    var index = marker + 4 + 5   // type; configurationVersion, profile, compatibility, level, lengthSizeMinusOne
    guard index + 3 <= bytes.count, bytes[index] & 0x1F >= 1 else { return nil }
    let spsLength = Int(bytes[index + 1]) << 8 | Int(bytes[index + 2])
    index += 3
    guard index + spsLength + 3 <= bytes.count else { return nil }
    let sps = Data(bytes[index..<(index + spsLength)])
    index += spsLength
    guard bytes[index] >= 1 else { return nil }
    let ppsLength = Int(bytes[index + 1]) << 8 | Int(bytes[index + 2])
    index += 3
    guard index + ppsLength <= bytes.count else { return nil }
    return VideoFormat.h264(sps: sps, pps: Data(bytes[index..<(index + ppsLength)]))
}

/// Plays pre-encoded video frames in real time (one every 1/`fps` s, in the given order), keeping their presentation
/// and decode times; the wall clock is the delivery time. The stream finishes after the last frame.
final class PacedFrameSource: MediaSource {
    let displayName = "Paced"
    private let frames: [EncodedVideoFrame]
    private let fps: Int
    private let tasks = Mutex<[Task<Void, Never>]>([])

    init(frames: [EncodedVideoFrame], fps: Int) {
        self.frames = frames
        self.fps = max(1, fps)
    }

    func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> {
        let frames = self.frames
        let fps = self.fps
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self)
        let task = Task {
            let clock = ContinuousClock()
            let start = clock.now
            for (index, frame) in frames.enumerated() {
                try? await clock.sleep(until: start.advanced(by: .seconds(Double(index) / Double(fps))))
                if Task.isCancelled { break }
                var frame = frame
                frame.wallClock = Date()
                continuation.yield(.video(frame))
            }
            continuation.finish()
        }
        tasks.withLock { $0.append(task) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func stop() async {
        let running = tasks.withLock { tasks in
            defer { tasks.removeAll() }
            return tasks
        }
        running.forEach { $0.cancel() }
    }
}

#if canImport(Darwin)
import PlatformApple

/// A video transcoder that records what it is asked to do (bit-rate updates, frames) and fails the frames `fails`
/// names, without passing them on.
final class WatchedTranscoder: VideoTranscoding {
    struct TestFailure: Error {}

    let base: any VideoTranscoding
    let settings: VideoEncoderSettings
    let fails: @Sendable (EncodedVideoFrame) -> Bool
    let bitrates = Box<[Int]>([])
    /// Frames passed to `transcode` (failed ones included).
    let frames = Box(0)
    let invalidated = Box(false)

    init(base: any VideoTranscoding, settings: VideoEncoderSettings, fails: @escaping @Sendable (EncodedVideoFrame) -> Bool) {
        self.base = base
        self.settings = settings
        self.fails = fails
    }

    func transcode(_ frame: EncodedVideoFrame) async throws -> [EncodedVideoFrame] {
        frames.update { $0 += 1 }
        if fails(frame) { throw TestFailure() }
        return try await base.transcode(frame)
    }

    func requestKeyframe() { base.requestKeyframe() }

    func updateBitrate(kbps: Int) {
        bitrates.update { $0.append(kbps) }
        base.updateBitrate(kbps: kbps)
    }

    func invalidate() {
        invalidated.set(true)
        base.invalidate()
    }
}

/// `AppleMediaCodecs` whose video transcoders are `WatchedTranscoder`s (every one made is kept in `transcoders`).
struct WatchedTranscoderCodecs: MediaCodecs {
    let base = AppleMediaCodecs()
    let transcoders = Box<[WatchedTranscoder]>([])
    var fails: @Sendable (EncodedVideoFrame) -> Bool = { _ in false }
    /// How long making a transcoder takes (VTCompressionSessionCreate on a busy Mac); `creations` counts the calls begun.
    var creationDelay: Duration = .zero
    let creations = Box(0)

    func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding { try base.makeVideoDecoder(format: format) }
    func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { try base.makeVideoEncoder(settings: settings) }
    func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding {
        creations.update { $0 += 1 }
        if creationDelay > .zero { Thread.sleep(forTimeInterval: creationDelay.timeInterval) }
        let watched = WatchedTranscoder(base: try base.makeVideoTranscoder(output: output), settings: output, fails: fails)
        transcoders.update { $0.append(watched) }
        return watched
    }
    func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding {
        try base.makeAudioTranscoder(input: input, output: output)
    }
    func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data {
        try base.jpeg(from: frame, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality)
    }
    func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data { try base.resizeJPEG(jpeg, maxWidth: maxWidth, maxHeight: maxHeight) }
    func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] {
        try base.silentAACFrames(duration: duration, sampleRate: sampleRate, channels: channels, startPTS: startPTS, wallClock: wallClock)
    }
    func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration, audio: AudioCodec?,
                             audioSampleRate: Int) -> any MediaSource {
        base.makeSyntheticSource(displayName: displayName, width: width, height: height, fps: fps, keyframeInterval: keyframeInterval,
                                 audio: audio, audioSampleRate: audioSampleRate)
    }
}

/// Real-time synthetic H.264 (+ optional audio) from VideoToolbox.
func syntheticSource(width: Int = 640, height: Int = 360, fps: Int = 15, gop: Duration = .milliseconds(500), audio: AudioCodec? = .aac,
                     audioRate: Int = 32_000) -> any MediaSource {
    AppleMediaCodecs().makeSyntheticSource(displayName: "Test", width: width, height: height, fps: fps, keyframeInterval: gop, audio: audio,
                                           audioSampleRate: audioRate)
}
#endif

/// Records every `setKeepSystemAwake` / `beginBackgroundActivity` / `endBackgroundActivity` call.
final class RecordingPowerManager: PowerManaging {
    let keepAwakeCalls = Box<[Bool]>([])
    let backgroundActivities = Box<[String]>([])
    let endedActivities = Box(0)
    /// `PowerManaging.hasBattery`: a laptop unless a test says otherwise.
    let battery = Box(true)

    var hasBattery: Bool { battery.value }

    func beginBackgroundActivity(reason: String) { backgroundActivities.update { $0.append(reason) } }
    func endBackgroundActivity() { endedActivities.update { $0 += 1 } }
    func setKeepSystemAwake(_ awake: Bool, reason: String) { keepAwakeCalls.update { $0.append(awake) } }
}
