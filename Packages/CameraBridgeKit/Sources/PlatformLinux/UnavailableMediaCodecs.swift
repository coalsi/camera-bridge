#if os(Linux)
import Foundation
import MediaCore

/// Placeholder `MediaCodecs` until the ffmpeg-based implementation (`Codecs/`) is wired in: every codec call throws
/// `MediaCodecError.unsupported`, so passthrough (H.264 video without transcoding) works and anything that needs a codec
/// fails with a clear error instead of at link time. `BridgeEnvironment.linux(dataDirectory:codecs:)` takes the real
/// codecs as a parameter.
public final class UnavailableMediaCodecs: MediaCodecs {
    private static let unavailable = MediaCodecError.unsupported("codecs are not available in this build")

    public init() {}

    public func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding { throw Self.unavailable }
    public func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { throw Self.unavailable }
    public func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding { throw Self.unavailable }
    public func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding { throw Self.unavailable }
    public func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data { throw Self.unavailable }
    public func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data { throw Self.unavailable }
    public func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] {
        throw Self.unavailable
    }

    public func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration,
                                    audio: AudioCodec?, audioSampleRate: Int) -> any MediaSource {
        UnavailableSource(displayName: displayName)
    }

    private final class UnavailableSource: MediaSource {
        let displayName: String

        init(displayName: String) {
            self.displayName = displayName
        }

        func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> { throw UnavailableMediaCodecs.unavailable }
        func stop() async {}
    }
}
#endif
