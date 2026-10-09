import BridgeSupport
import Foundation
import MediaCore
import Synchronization

/// A moving test pattern in planar YUV 4:2:0 (limited range): a gradient background, a box bouncing across it and a strip of
/// stripes sliding along the bottom, so a frozen picture is easy to see. Pure Swift; the background is built once.
struct YUVTestPattern: Sendable {
    let width: Int
    let height: Int
    private let background: [UInt8]
    private let boxSize: Int

    init(width: Int, height: Int) {
        self.width = width & ~1
        self.height = height & ~1
        let w = self.width, h = self.height
        let chroma = RawVideoFrame.chromaSize(width: w, height: h)
        var planes = [UInt8](repeating: 0, count: RawVideoFrame.byteCount(width: w, height: h))
        for y in 0..<h {
            let row = y * w
            for x in 0..<w { planes[row + x] = UInt8(48 + x * 120 / max(1, w) + y * 40 / max(1, h)) }
        }
        let cbBase = w * h
        let crBase = cbBase + chroma.width * chroma.height
        for y in 0..<chroma.height {
            for x in 0..<chroma.width {
                planes[cbBase + y * chroma.width + x] = UInt8(96 + x * 64 / max(1, chroma.width))
                planes[crBase + y * chroma.width + x] = UInt8(96 + y * 64 / max(1, chroma.height))
            }
        }
        background = planes
        boxSize = max(8, min(w, h) / 5) & ~1
    }

    func frame(index: Int, pts: MediaTime) -> RawVideoFrame {
        var planes = background
        let w = width, h = height
        let chroma = RawVideoFrame.chromaSize(width: w, height: h)
        let cbBase = w * h
        let crBase = cbBase + chroma.width * chroma.height
        // The box bounces: a triangle wave in each axis.
        func bounce(_ step: Int, range: Int) -> Int {
            guard range > 0 else { return 0 }
            let phase = step % (2 * range)
            return phase < range ? phase : 2 * range - phase
        }
        let boxX = bounce(index * 4, range: max(0, w - boxSize)) & ~1
        let boxY = bounce(index * 2, range: max(0, h - boxSize)) & ~1
        for y in boxY..<min(h, boxY + boxSize) {
            for x in boxX..<min(w, boxX + boxSize) { planes[y * w + x] = 235 }
        }
        for y in (boxY / 2)..<min(chroma.height, (boxY + boxSize) / 2) {
            for x in (boxX / 2)..<min(chroma.width, (boxX + boxSize) / 2) {
                planes[cbBase + y * chroma.width + x] = 90
                planes[crBase + y * chroma.width + x] = 200
            }
        }
        let stripeTop = h - max(2, h / 8)
        let shift = index * 3
        for y in stripeTop..<h {
            for x in 0..<w where ((x + shift) / 16) % 2 == 0 { planes[y * w + x] = 200 }
        }
        return RawVideoFrame(width: w, height: h, pts: pts, pixels: Data(planes))
    }
}

/// The demo camera on Linux: `YUVTestPattern` pictures encoded as H.264 in real time (`FFmpegVideoEncoder`) at the configured
/// frame rate and keyframe interval, plus an optional 440 Hz tone in any `AudioTranscoding` output codec (AAC-LC, Opus, G.711).
///
/// `samples()` starts a new session and stops the one it replaces: video PTS on the 90 kHz clock start at 0 with the first frame (a
/// keyframe, delivered first), audio PTS on the sample clock at 0; wall clocks follow real time. `stop()` ends the stream.
/// Samples are buffered up to 512 (newest kept) for a slow consumer.
final class FFmpegSyntheticSource: MediaSource {
    struct Configuration: Sendable {
        var width: Int
        var height: Int
        var fps: Int
        var keyframeInterval: Duration
        var audio: AudioCodec?
        var audioSampleRate: Int

        /// About 0.1 bit per pixel per frame, clamped to 300 kbit/s … 8 Mbit/s.
        var bitrateKbps: Int { min(8_000, max(300, width * height * fps / 10_000)) }
    }

    private struct Session {
        let task: Task<Void, Never>
        let continuation: AsyncThrowingStream<MediaSample, any Error>.Continuation
    }

    let displayName: String
    private let runtime: FFmpegRuntime
    private let configuration: Configuration
    private let session = Mutex<Session?>(nil)

    init(runtime: FFmpegRuntime, displayName: String, configuration: Configuration) {
        self.runtime = runtime
        self.displayName = displayName
        self.configuration = configuration
    }

    func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> {
        await stop()
        let configuration = configuration
        guard configuration.width >= 2, configuration.height >= 2, configuration.fps > 0 else {
            throw MediaCodecError.unsupported("synthetic source \(configuration.width)×\(configuration.height) @ \(configuration.fps) fps")
        }
        let encoder = try FFmpegVideoEncoder(runtime: runtime, settings: VideoEncoderSettings(width: configuration.width & ~1, height: configuration.height & ~1,
                                                                                              fps: configuration.fps, bitrateKbps: configuration.bitrateKbps,
                                                                                              profile: .main, level: .auto, keyframeInterval: configuration.keyframeInterval))
        var tone: FFmpegAudioTranscoder?
        if let codec = configuration.audio {
            let rate = configuration.audioSampleRate > 0 ? configuration.audioSampleRate : (codec == .pcmu || codec == .pcma ? 8_000 : 16_000)
            tone = try FFmpegAudioTranscoder(runtime: runtime, input: AudioFormat(codec: .linearPCM, sampleRate: rate, channels: 1),
                                             output: AudioEncoderSettings(codec: codec, sampleRate: rate, channels: 1))
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self, bufferingPolicy: .bufferingNewest(512))
        let producer = Producer(configuration: configuration, encoder: encoder, tone: tone)
        let task = Task.detached(priority: .userInitiated) {
            do {
                try await producer.run(continuation)
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            encoder.invalidate()
            tone?.invalidate()
        }
        continuation.onTermination = { _ in task.cancel() }
        let replaced = session.withLock { current -> Session? in
            defer { current = Session(task: task, continuation: continuation) }
            return current
        }
        if let replaced { await Self.end(replaced) }
        return stream
    }

    func stop() async {
        guard let current = session.withLock({ session -> Session? in
            defer { session = nil }
            return session
        }) else { return }
        await Self.end(current)
    }

    private static func end(_ session: Session) async {
        session.task.cancel()
        session.continuation.finish()
        await session.task.value
    }

    private final class Producer: Sendable {
        let configuration: Configuration
        let encoder: FFmpegVideoEncoder
        let tone: FFmpegAudioTranscoder?

        init(configuration: Configuration, encoder: FFmpegVideoEncoder, tone: FFmpegAudioTranscoder?) {
            self.configuration = configuration
            self.encoder = encoder
            self.tone = tone
        }

        func run(_ continuation: AsyncThrowingStream<MediaSample, any Error>.Continuation) async throws {
            let pattern = YUVTestPattern(width: configuration.width, height: configuration.height)
            let fps = configuration.fps
            let clock = ContinuousClock()
            let start = clock.now
            let startDate = Date()
            let audioRate = tone?.outputFormat.sampleRate ?? 0
            var audioSamples = 0
            var index = 0
            while true {
                try await clock.sleep(until: start + .seconds(Double(index) / Double(fps)))
                let wallClock = startDate.addingTimeInterval(Double(index) / Double(fps))
                let picture = pattern.frame(index: index, pts: MediaTime(value: Int64(index) * 90_000 / Int64(fps), timescale: 90_000))
                for frame in try await encoder.encode(picture, wallClock: wallClock, forceKeyframe: index == 0) {
                    continuation.yield(.video(frame))
                }
                if let tone {
                    let target = (index + 1) * audioRate / fps
                    if target > audioSamples {
                        let pcm = (audioSamples..<target).map { Int16(3_000 * sin(2 * Double.pi * 440 * Double($0) / Double(audioRate))) }
                        let input = EncodedAudioFrame(format: AudioFormat(codec: .linearPCM, sampleRate: audioRate, channels: 1),
                                                      data: pcm.withUnsafeBufferPointer { Data(buffer: $0) },
                                                      pts: MediaTime(value: Int64(audioSamples), timescale: Int32(audioRate)), sampleCount: pcm.count,
                                                      wallClock: startDate.addingTimeInterval(Double(audioSamples) / Double(audioRate)))
                        for frame in try tone.transcode(input) { continuation.yield(.audio(frame)) }
                        audioSamples = target
                    }
                }
                index += 1
            }
        }
    }
}
