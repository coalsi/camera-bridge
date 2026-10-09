import BridgeSupport
import Foundation
import MediaCore

/// `MediaCodecs` over `ffmpeg` child processes (Camera Bridge OS; builds on macOS too, where it is used for tests).
///
/// | Service | How |
/// |---|---|
/// | decode H.264/HEVC | `FFmpegVideoDecoder`: one child per decoder, FLV in, raw `yuv420p` out |
/// | encode H.264 | `FFmpegVideoEncoder`: raw in, FLV out; libx264 `-preset veryfast -tune zerolatency`, or `h264_vaapi` when `/dev/dri/renderD128` exists and a probe encode works |
/// | transcode, scale, overlay | `FFmpegVideoTranscoder`: decode → rate limit → scale → `drawtext` → encode in one child |
/// | audio | `FFmpegAudioTranscoder`: AAC/AAC-ELD/Opus/G.711/PCM in; Opus (`libopus`), AAC-LC (`aac`), G.711, PCM out. No AAC-ELD encoder without non-free `libfdk_aac` |
/// | JPEG | one-shot child (`mjpeg`) from a raw picture; `resizeJPEG` likewise |
///
/// Every object owns its child processes and kills them in `invalidate()` and `deinit`. The ffmpeg program and what it supports are
/// found on first use; without ffmpeg every `make…` throws `MediaCodecError.unsupported`.
public final class FFmpegMediaCodecs: MediaCodecs {
    let runtime: FFmpegRuntime

    public convenience init(configuration: FFmpegCodecsConfiguration = FFmpegCodecsConfiguration()) {
        self.init(configuration: configuration, launcher: SystemFFmpegLauncher())
    }

    init(configuration: FFmpegCodecsConfiguration, launcher: any FFmpegProcessLaunching, executable: URL? = nil,
         deviceExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        runtime = FFmpegRuntime(launcher: launcher, configuration: configuration, executable: executable ?? configuration.resolveExecutable(), deviceExists: deviceExists)
    }

    /// Whether an ffmpeg program was found.
    public var isAvailable: Bool { runtime.executable != nil }

    /// Finds out what ffmpeg can do (it runs `ffmpeg -encoders`, `-filters` and, when a render node exists, a probe VA-API encode),
    /// which otherwise happens when the first video or audio object is made. Takes a fraction of a second, up to ~10 s when the
    /// GPU stalls: call it at start-up, off the request path. Throws like the `make…` functions when ffmpeg is missing.
    public func prepare() throws {
        _ = try runtime.capabilities()
        _ = try runtime.videoBackend()
    }

    /// A one-line description of what ffmpeg offers here (version, H.264 encoder, audio encoders) for logs and diagnostics;
    /// throws like the `make…` functions when ffmpeg is missing.
    public func capabilitySummary() throws -> String {
        let capabilities = try runtime.capabilities()
        let video = try runtime.videoBackend().description
        let audio = ["Opus": capabilities.hasOpus, "AAC-LC": capabilities.encoders.contains("aac") || capabilities.encoders.contains("libfdk_aac"),
                     "AAC-ELD": capabilities.hasAACELDEncoder].filter(\.value).keys.sorted().joined(separator: ", ")
        return "ffmpeg \(capabilities.version); H.264 encoder \(video); audio encoders \(audio.isEmpty ? "none" : audio) (G.711 and PCM always); "
            + "timestamp overlay \(runtime.overlayFont() != nil ? "available" : "unavailable")"
    }

    // MARK: Video

    public func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding {
        try FFmpegVideoDecoder(runtime: runtime, format: format)
    }

    public func makeSnapshotDecoder(format: VideoFormat) throws -> any VideoDecoding {
        try FFmpegVideoDecoder(runtime: runtime, format: format, sessionLogLevel: .debug)
    }

    public func makeProbeDecoder(format: VideoFormat) throws -> any VideoDecoding {
        try FFmpegVideoDecoder(runtime: runtime, format: format, sessionLogLevel: .debug, lowPriority: true)
    }

    public func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding {
        try FFmpegVideoEncoder(runtime: runtime, settings: settings)
    }

    public func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding {
        try FFmpegVideoTranscoder(runtime: runtime, output: output, overlay: nil)
    }

    public func makeVideoTranscoder(output: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)?) throws -> any VideoTranscoding {
        try FFmpegVideoTranscoder(runtime: runtime, output: output, overlay: overlay)
    }

    // MARK: Audio

    public func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding {
        try FFmpegAudioTranscoder(runtime: runtime, input: input, output: output)
    }

    public func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] {
        try FFmpegSilentAudio.aacLCFrames(runtime: runtime, duration: duration, sampleRate: sampleRate, channels: channels, startPTS: startPTS, wallClock: wallClock)
    }

    // MARK: Pictures

    /// Throws `MediaCodecError.unsupported` for a picture that is not a `RawVideoFrame`.
    public func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data {
        guard let picture = frame as? RawVideoFrame else { throw MediaCodecError.unsupported("JPEG from a picture that is not a RawVideoFrame") }
        return try FFmpegPictures.jpeg(from: picture, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality, runtime: runtime)
    }

    public func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data {
        try FFmpegPictures.resize(jpeg, maxWidth: maxWidth, maxHeight: maxHeight, runtime: runtime)
    }

    public func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration,
                                    audio: AudioCodec?, audioSampleRate: Int) -> any MediaSource {
        FFmpegSyntheticSource(runtime: runtime, displayName: displayName,
                              configuration: .init(width: width, height: height, fps: fps, keyframeInterval: keyframeInterval, audio: audio,
                                                   audioSampleRate: audioSampleRate))
    }
}
