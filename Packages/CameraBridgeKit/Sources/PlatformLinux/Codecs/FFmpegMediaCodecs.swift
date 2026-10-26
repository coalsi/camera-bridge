import BridgeSupport
import Foundation
import MediaCore

/// `MediaCodecs` over `ffmpeg` child processes (Camera Bridge OS; builds on macOS too, where it is used for tests).
///
/// | Service | How |
/// |---|---|
/// | decode H.264/HEVC | `FFmpegVideoDecoder`: one child per decoder, FLV in, raw `yuv420p` out |
/// | encode H.264 | `FFmpegVideoEncoder`: raw in, FLV out; libx264 `-preset veryfast -tune zerolatency`, or `h264_vaapi` when `/dev/dri/renderD128` exists and a probe encode works |
/// | transcode, scale, straighten, overlay | `FFmpegVideoTranscoder`: decode → rate limit → scale → `remap` (Straighten the picture) → `drawtext` → encode in one child |
/// | audio | `FFmpegAudioTranscoder`: AAC/AAC-ELD/Opus/G.711/PCM in; Opus (`libopus`), AAC-LC (`aac`), G.711, PCM out. No AAC-ELD encoder without non-free `libfdk_aac` |
/// | JPEG | one-shot child (`mjpeg`) from a raw picture; `resizeJPEG`, `croppedJPEG` (the Sky Watcher's small pictures) and `correctJPEG` (Straighten the picture) likewise |
///
/// Every object owns its child processes and kills them in `invalidate()` and `deinit`. The ffmpeg program and what it supports are
/// found on first use; without ffmpeg every `make…` throws `MediaCodecError.unsupported`.
public final class FFmpegMediaCodecs: MediaCodecs {
    let runtime: FFmpegRuntime
    /// The maps of the snapshots' straightening, kept between snapshots (`FFmpegPictures.correctJPEG`) and removed with these codecs.
    let snapshotMaps: SnapshotMapCache

    public convenience init(configuration: FFmpegCodecsConfiguration = FFmpegCodecsConfiguration()) {
        self.init(configuration: configuration, launcher: SystemFFmpegLauncher())
    }

    init(configuration: FFmpegCodecsConfiguration, launcher: any FFmpegProcessLaunching, executable: URL? = nil,
         deviceExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        runtime = FFmpegRuntime(launcher: launcher, configuration: configuration, executable: executable ?? configuration.resolveExecutable(), deviceExists: deviceExists,
                                now: now)
        snapshotMaps = SnapshotMapCache(parent: configuration.scratchDirectory)
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
            + "timestamp overlay \(runtime.overlayFont() != nil ? "available" : "unavailable"); "
            + "picture correction \(runtime.pictureCorrectionAvailable() ? "available" : "unavailable")"
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

    /// Motion detection's decoder: pictures at most `FFmpegVideoDecoder.motionPictureWidth` wide, decoded on the GPU for HEVC and anything
    /// larger than 1080p (on the reference box a 4K HEVC camera cost a whole core decoded on the CPU, 2026-10-16).
    public func makeMotionDecoder(format: VideoFormat) throws -> any VideoDecoding {
        try FFmpegVideoDecoder(runtime: runtime, format: format, sessionLogLevel: .debug, maxOutputWidth: FFmpegVideoDecoder.motionPictureWidth,
                               hardwareWhenHeavy: true)
    }

    /// The sky detector's decoder: pictures at most `maxOutputWidth` wide, a picture of every `keepEvery`th frame only (on the GPU, where the
    /// GPU takes the stream, the others are dropped before they are copied back), scaled with a good filter, under `nice -n 10`. A stream
    /// the GPU's decoder cannot take (H.264 over 4096 wide or tall) is decoded in software, and so is one the GPU fails on; the decoder
    /// says which (`VideoDecoding.decodingPlace`). The loop filter stays on: block edges would show as faint false lights in a dark sky.
    public func makeSkyDecoder(format: VideoFormat, maxOutputWidth: Int, keepEvery: Int) throws -> any VideoDecoding {
        try FFmpegVideoDecoder(runtime: runtime, format: format, sessionLogLevel: .info, maxOutputWidth: maxOutputWidth > 0 ? maxOutputWidth : nil,
                               hardwareWhenHeavy: true, keepEvery: keepEvery, niceness: FFmpegVideoDecoder.skyNiceness, highQualityScaling: true)
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

    /// Whether ffmpeg has the warp's filters (`remap`, `extractplanes`, `mergeplanes`, all built into libavfilter: Debian's and
    /// Homebrew's ffmpeg have them). Asks ffmpeg on first use, like the other capabilities (`prepare()` does it at start-up); without
    /// them the correction is off everywhere, logged once.
    public var supportsPictureCorrection: Bool { runtime.pictureCorrectionAvailable() }

    public func makeVideoTranscoder(output: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)?,
                                    correction: (any PictureCorrectionProviding)?) throws -> any VideoTranscoding {
        try FFmpegVideoTranscoder(runtime: runtime, output: output, overlay: overlay, correction: correction)
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

    /// One child with the warp's maps, kept between snapshots in a private temporary directory per picture size and correction
    /// (`SnapshotMapCache`, `FFmpegPictures.correctJPEG`). Throws
    /// `MediaCodecError.unsupported` when this ffmpeg cannot straighten (`supportsPictureCorrection` is false).
    public func correctJPEG(_ jpeg: Data, correction: PictureCorrection) throws -> Data {
        guard correction.isOff || runtime.pictureCorrectionAvailable() else {
            throw MediaCodecError.unsupported("this ffmpeg cannot straighten the picture")
        }
        return try FFmpegPictures.correctJPEG(jpeg, correction: correction, runtime: runtime, maps: snapshotMaps)
    }

    public func cameraOffJPEG(cameraName: String, width: Int, height: Int) throws -> Data {
        try FFmpegPictures.cameraOff(cameraName: cameraName, width: width, height: height, runtime: runtime)
    }

    public func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data {
        try FFmpegPictures.resize(jpeg, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality, runtime: runtime)
    }

    public func croppedJPEG(_ jpeg: Data, crop: ImageCrop?, maxWidth: Int, quality: Double) throws -> Data {
        try FFmpegPictures.crop(jpeg, to: crop, maxWidth: maxWidth, quality: quality, runtime: runtime)
    }

    public func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration,
                                    audio: AudioCodec?, audioSampleRate: Int) -> any MediaSource {
        FFmpegSyntheticSource(runtime: runtime, displayName: displayName,
                              configuration: .init(width: width, height: height, fps: fps, keyframeInterval: keyframeInterval, audio: audio,
                                                   audioSampleRate: audioSampleRate))
    }
}
