import Foundation

/// Every platform codec service portable modules use (Apple implementation: `PlatformApple.AppleMediaCodecs`).
public protocol MediaCodecs: Sendable {
    func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding
    /// A decoder for snapshots (one keyframe now and then, kept for a while by the snapshot provider): the same decoder,
    /// whose routine session creation is logged at debug level instead of info. The default is `makeVideoDecoder`.
    func makeSnapshotDecoder(format: VideoFormat) throws -> any VideoDecoding
    /// A decoder for the live view's self-check (it decodes a few of the pictures the stream sends, to see them as the
    /// controller does): low priority, session creation logged at debug level. The default is `makeVideoDecoder`.
    func makeProbeDecoder(format: VideoFormat) throws -> any VideoDecoding
    func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding
    func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding
    /// A transcoder that also draws `overlay` (asked for at every picture; nil: none) on the pictures it encodes. The
    /// default ignores the overlay (a codec service that cannot draw one transcodes without it).
    func makeVideoTranscoder(output: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)?) throws -> any VideoTranscoding
    func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding
    func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data
    func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data
    func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame]
    /// Demo camera / tests: moving test pattern (+ optional tone), H.264 at the given fps/GOP.
    func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration,
                             audio: AudioCodec?, audioSampleRate: Int) -> any MediaSource
}

extension MediaCodecs {
    public func makeSnapshotDecoder(format: VideoFormat) throws -> any VideoDecoding { try makeVideoDecoder(format: format) }

    public func makeProbeDecoder(format: VideoFormat) throws -> any VideoDecoding { try makeVideoDecoder(format: format) }

    public func makeVideoTranscoder(output: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)?) throws -> any VideoTranscoding {
        try makeVideoTranscoder(output: output)
    }

    /// Decodes a keyframe with a fresh decoder and encodes JPEG (quality 0.8), keeping aspect within the bounds.
    /// Throws `MediaCodecError.unsupported` for a non-keyframe and `.noFrame` if the decoder produced no picture.
    public func jpeg(fromKeyframe frame: EncodedVideoFrame, maxWidth: Int?, maxHeight: Int?) async throws -> Data {
        guard frame.isKeyframe else { throw MediaCodecError.unsupported("snapshot source is not a keyframe") }
        let decoder = try makeVideoDecoder(format: frame.format)
        defer { decoder.invalidate() }
        guard let picture = try await decoder.decode(frame) else { throw MediaCodecError.noFrame }
        return try jpeg(from: picture, maxWidth: maxWidth, maxHeight: maxHeight, quality: 0.8)
    }
}

public enum MediaCodecError: Error, Equatable {
    case unsupported(String)
    /// A platform codec/CoreMedia call failed with this status.
    case sessionFailed(Int32)
    case noFrame
}
