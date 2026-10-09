#if os(macOS)
import Foundation
import MediaCore

/// `MediaCodecs` over VideoToolbox (H.264/HEVC decode, H.264 encode/transcode), AudioToolbox (AAC-LC, AAC-ELD, Opus;
/// G.711 in Swift) and CoreImage/ImageIO (JPEG). Stateless; every object it makes is independent and thread-safe.
public final class AppleMediaCodecs: MediaCodecs {
    public init() {}

    public func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding {
        try AppleVideoDecoder(format: format)
    }

    public func makeSnapshotDecoder(format: VideoFormat) throws -> any VideoDecoding {
        try AppleVideoDecoder(format: format, sessionLogLevel: .debug)
    }

    public func makeProbeDecoder(format: VideoFormat) throws -> any VideoDecoding {
        try AppleVideoDecoder(format: format, sessionLogLevel: .debug, lowPriority: true)
    }

    public func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding {
        try AppleVideoEncoder(settings: settings, codec: .h264)
    }

    public func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding {
        try AppleVideoTranscoder(output: output)
    }

    public func makeVideoTranscoder(output: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)?) throws -> any VideoTranscoding {
        try AppleVideoTranscoder(output: output, overlay: overlay)
    }

    public func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding {
        try AppleAudioTranscoder(input: input, output: output)
    }

    /// Throws `MediaCodecError.unsupported` for a picture that is not a `PixelBufferFrame`.
    public func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data {
        guard let picture = frame as? PixelBufferFrame else { throw MediaCodecError.unsupported("JPEG from a picture that is not a PixelBufferFrame") }
        return try JPEGSnapshot.jpeg(from: picture.pixelBuffer, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality)
    }

    public func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data {
        try JPEGSnapshot.resize(jpeg, maxWidth: maxWidth, maxHeight: maxHeight)
    }

    public func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] {
        try SilentAudio.aacLCFrames(duration: duration, sampleRate: sampleRate, channels: channels, startPTS: startPTS, wallClock: wallClock)
    }

    public func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration,
                                    audio: AudioCodec?, audioSampleRate: Int) -> any MediaSource {
        SyntheticMediaSource(displayName: displayName,
                             configuration: .init(width: width, height: height, fps: fps, keyframeInterval: keyframeInterval, audio: audio,
                                                  audioSampleRate: audioSampleRate))
    }
}
#endif
