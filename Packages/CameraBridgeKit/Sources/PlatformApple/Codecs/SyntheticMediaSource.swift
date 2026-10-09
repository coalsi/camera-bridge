#if os(macOS)
import Foundation
import MediaCore
import Synchronization

/// The demo camera: `TestPattern` pictures encoded as H.264 (VideoToolbox) in real time at the configured frame rate
/// and keyframe interval, plus an optional 440 Hz tone in any `AudioTranscoding` output codec (AAC-LC, PCMU, …).
///
/// `samples()` starts a new session and stops the one it replaces (also when calls overlap, the earlier stream ends):
/// video PTS on the 90 kHz clock start at 0 with the first frame (a keyframe, delivered first), audio PTS on the
/// sample clock at 0 plus the audio encoder's delay compensation (see `AppleAudioTranscoder`); wall clocks follow real
/// time. `stop()` ends the stream normally. Samples are buffered up to 512 (newest kept) for a slow consumer.
final class SyntheticMediaSource: MediaSource {
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
    let configuration: Configuration
    private let session = Mutex<Session?>(nil)

    init(displayName: String, configuration: Configuration) {
        self.displayName = displayName
        self.configuration = configuration
    }

    func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> {
        await stop()
        let configuration = configuration
        guard configuration.width >= 2, configuration.height >= 2, configuration.fps > 0 else {
            throw MediaCodecError.unsupported("synthetic source \(configuration.width)×\(configuration.height) @ \(configuration.fps) fps")
        }
        let encoder = try AppleVideoEncoder(settings: VideoEncoderSettings(width: configuration.width & ~1, height: configuration.height & ~1,
                                                                           fps: configuration.fps, bitrateKbps: configuration.bitrateKbps,
                                                                           profile: .main, level: .auto, keyframeInterval: configuration.keyframeInterval))
        var tone: AppleAudioTranscoder?
        if let codec = configuration.audio {
            let rate = configuration.audioSampleRate > 0 ? configuration.audioSampleRate : (codec == .pcmu || codec == .pcma ? 8_000 : 16_000)
            tone = try AppleAudioTranscoder(input: AudioFormat(codec: .linearPCM, sampleRate: rate, channels: 1),
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
        }
        continuation.onTermination = { _ in task.cancel() }
        let replaced = session.withLock { current -> Session? in
            defer { current = Session(task: task, continuation: continuation) }
            return current
        }
        if let replaced { await Self.end(replaced) }   // a concurrent samples() stored it after our stop()
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
}

/// Generates one session's samples (runs in the session's task only).
private final class Producer: Sendable {
    let configuration: SyntheticMediaSource.Configuration
    let encoder: AppleVideoEncoder
    let tone: AppleAudioTranscoder?

    init(configuration: SyntheticMediaSource.Configuration, encoder: AppleVideoEncoder, tone: AppleAudioTranscoder?) {
        self.configuration = configuration
        self.encoder = encoder
        self.tone = tone
    }

    func run(_ continuation: AsyncThrowingStream<MediaSample, any Error>.Continuation) async throws {
        let pattern = TestPattern(width: configuration.width, height: configuration.height)
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
            let picture = try pattern.makeFrame(index: index, pts: MediaTime(value: Int64(index) * 90_000 / Int64(fps), timescale: 90_000))
            for frame in try await encoder.encode(picture, wallClock: wallClock, forceKeyframe: index == 0) {
                continuation.yield(.video(frame))
            }
            if let tone {
                // Audio up to the next video frame's time.
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
#endif
