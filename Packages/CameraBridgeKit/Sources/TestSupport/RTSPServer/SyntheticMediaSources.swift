import BridgeSupport
import Foundation
import MediaCore
import Synchronization

/// Real-time paced synthetic H.264 / HEVC access units for transport tests. Each NAL payload encodes its frame index
/// (`frameIndex(of:)`) and never contains two consecutive zero bytes, so it cannot emulate a start code. The NAL units
/// are not decodable pictures; `format` supplies real parameter sets (e.g. from VideoToolbox).
public final class SyntheticNALSource: MediaSource {
    public struct Configuration: Sendable {
        public var format: VideoFormat
        public var fps: Int
        /// Frames per GOP (keyframe every `keyframeInterval` frames).
        public var keyframeInterval: Int
        public var keyframeSize: Int
        public var frameSize: Int
        /// PCMU / PCMA (20 ms frames) or AAC (1024-sample dummy units) interleaved with the video.
        public var audio: AudioFormat?
        /// Stop (finish the stream) after this many video frames.
        public var frameLimit: Int?

        public init(format: VideoFormat, fps: Int = 25, keyframeInterval: Int = 25, keyframeSize: Int = 6000, frameSize: Int = 800,
                    audio: AudioFormat? = nil, frameLimit: Int? = nil) {
            self.format = format
            self.fps = fps
            self.keyframeInterval = keyframeInterval
            self.keyframeSize = keyframeSize
            self.frameSize = frameSize
            self.audio = audio
            self.frameLimit = frameLimit
        }
    }

    public let displayName: String
    public let configuration: Configuration
    private let tasks = Mutex<[Task<Void, Never>]>([])

    public init(configuration: Configuration, displayName: String = "Synthetic") {
        self.configuration = configuration
        self.displayName = displayName
    }

    public func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> {
        let configuration = self.configuration
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self)
        let task = Task {
            let clock = ContinuousClock()
            let start = clock.now
            let fps = max(1, configuration.fps)
            var audioIndex = 0
            var index = 0
            while !Task.isCancelled {
                if let limit = configuration.frameLimit, index >= limit { break }
                try? await clock.sleep(until: start.advanced(by: .seconds(Double(index) / Double(fps))))
                if Task.isCancelled { break }
                let isKeyframe = index % max(1, configuration.keyframeInterval) == 0
                let frame = EncodedVideoFrame(
                    format: configuration.format,
                    nalUnits: [Self.videoNAL(index: index, isKeyframe: isKeyframe, size: isKeyframe ? configuration.keyframeSize : configuration.frameSize,
                                             codec: configuration.format.codec)],
                    isKeyframe: isKeyframe,
                    pts: MediaTime(value: Int64(index) * 90_000 / Int64(fps), timescale: 90_000),
                    wallClock: Date())
                continuation.yield(.video(frame))
                if let audio = configuration.audio {
                    let videoSeconds = Double(index + 1) / Double(fps)
                    while true {
                        let unit = Self.audioUnit(index: audioIndex, format: audio)
                        guard unit.pts.seconds < videoSeconds else { break }
                        continuation.yield(.audio(unit))
                        audioIndex += 1
                    }
                }
                index += 1
            }
            continuation.finish()
        }
        tasks.withLock { $0.append(task) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func stop() async {
        let running = tasks.withLock { tasks in
            defer { tasks.removeAll() }
            return tasks
        }
        running.forEach { $0.cancel() }
    }

    /// Deterministic NAL unit: header (IDR / non-IDR slice), 4 index bytes (7 bits each, high bit set), filler.
    public static func videoNAL(index: Int, isKeyframe: Bool, size: Int, codec: VideoCodec) -> Data {
        var nal: [UInt8]
        switch codec {
        case .h264: nal = [isKeyframe ? 0x65 : 0x41]
        case .hevc: nal = [isKeyframe ? 19 << 1 : 1 << 1, 0x01]
        }
        nal += indexBytes(index)
        let fillerCount = max(0, size - nal.count)
        nal += (0..<fillerCount).map { UInt8((index &* 7 &+ $0) % 255 + 1) }
        return Data(nal)
    }

    /// Frame index of a video frame produced by this source (nil for other frames).
    public static func frameIndex(of frame: EncodedVideoFrame) -> Int? {
        guard let nal = frame.nalUnits.first else { return nil }
        let offset = frame.format.codec == .hevc ? 2 : 1
        return decodeIndex(nal, at: offset)
    }

    /// Audio unit `index`: PCMU/PCMA 160 samples (20 ms at 8 kHz), AAC 1024 samples; payload starts with the index bytes.
    public static func audioUnit(index: Int, format: AudioFormat) -> EncodedAudioFrame {
        let samples = format.codec == .aac ? 1024 : max(1, format.sampleRate / 50)
        let size = format.codec == .aac ? 120 + index % 40 : samples * max(1, format.channels)
        var bytes = indexBytes(index)
        for offset in 0..<max(0, size - bytes.count) {
            let value: Int = (index &* 3 &+ offset) % 255 + 1
            bytes.append(UInt8(value))
        }
        return EncodedAudioFrame(format: format, data: Data(bytes), pts: MediaTime(value: Int64(index * samples), timescale: Int32(format.sampleRate)),
                                 sampleCount: samples, wallClock: Date())
    }

    /// Index of an audio unit produced by `audioUnit(index:format:)`.
    public static func audioIndex(of frame: EncodedAudioFrame) -> Int? {
        decodeIndex(frame.data, at: 0)
    }

    private static func indexBytes(_ index: Int) -> [UInt8] {
        (0..<4).map { 0x80 | UInt8((index >> (7 * (3 - $0))) & 0x7F) }
    }

    private static func decodeIndex(_ data: Data, at offset: Int) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= offset + 4 else { return nil }
        return (0..<4).reduce(0) { $0 << 7 | Int(bytes[offset + $1] & 0x7F) }
    }
}

/// Replays recorded frames (e.g. VideoToolbox output) in a loop in real time, re-stamping pts and wall clock.
public final class ReplayMediaSource: MediaSource {
    public let displayName: String
    private let frames: [EncodedVideoFrame]
    private let fps: Int
    private let loops: Bool
    private let tasks = Mutex<[Task<Void, Never>]>([])

    /// `frames` should start with a keyframe.
    public init(frames: [EncodedVideoFrame], fps: Int, loops: Bool = true, displayName: String = "Replay") {
        self.frames = frames
        self.fps = max(1, fps)
        self.loops = loops
        self.displayName = displayName
    }

    public func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> {
        let frames = self.frames
        let fps = self.fps
        let loops = self.loops
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self)
        let task = Task {
            let clock = ContinuousClock()
            let start = clock.now
            var index = 0
            while !Task.isCancelled, !frames.isEmpty, loops || index < frames.count {
                try? await clock.sleep(until: start.advanced(by: .seconds(Double(index) / Double(fps))))
                if Task.isCancelled { break }
                var frame = frames[index % frames.count]
                frame.pts = MediaTime(value: Int64(index) * 90_000 / Int64(fps), timescale: 90_000)
                frame.dts = nil
                frame.wallClock = Date()
                continuation.yield(.video(frame))
                index += 1
            }
            continuation.finish()
        }
        tasks.withLock { $0.append(task) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func stop() async {
        let running = tasks.withLock { tasks in
            defer { tasks.removeAll() }
            return tasks
        }
        running.forEach { $0.cancel() }
    }
}
