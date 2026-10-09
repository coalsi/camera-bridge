import Foundation

public struct VideoEncoderSettings: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrateKbps: Int
    public var profile: EncoderProfile
    public var level: EncoderLevel
    public var keyframeInterval: Duration
    public var realtime: Bool
    /// The frame rate the input is expected to have (a hint for rate control and the keyframe count), when it is known
    /// to be below `fps`; nil: `fps`. `fps` stays the output's limit: a transcoder keeps every picture of an input up to
    /// `fps`, whatever this says (a rate measured a little low must not drop pictures for the whole stream).
    public var expectedFrameRate: Int?

    public enum EncoderProfile: Sendable, Equatable { case baseline, main, high }
    public enum EncoderLevel: Sendable, Equatable { case level3_1, level3_2, level4_0, level4_1, level5_1, auto }

    public init(width: Int, height: Int, fps: Int, bitrateKbps: Int, profile: EncoderProfile = .main, level: EncoderLevel = .level4_0,
                keyframeInterval: Duration = .seconds(4), realtime: Bool = true, expectedFrameRate: Int? = nil) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateKbps = bitrateKbps
        self.profile = profile
        self.level = level
        self.keyframeInterval = keyframeInterval
        self.realtime = realtime
        self.expectedFrameRate = expectedFrameRate
    }

    /// `expectedFrameRate` within 1…`fps` (`fps` when nil).
    public var inputFrameRate: Int {
        max(1, min(max(1, fps), expectedFrameRate ?? fps))
    }
}

/// 8-bit luma image, row-major, `pixels.count == width * height` (motion detection input).
public struct GrayImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Coarse statistics of a picture's 8-bit video-range planes (Y 16...235, Cb/Cr centred on 128), sampled on a small grid:
/// enough to tell a black or "uninitialised" (all-zero, which shows green) picture from a real one. Cheap (a few
/// thousand samples), so a health check may take one per second.
public struct PictureStatistics: Sendable, Equatable {
    public var meanLuma: Double
    /// Standard deviation of the sampled luma.
    public var lumaDeviation: Double
    public var meanCb: Double
    public var meanCr: Double

    public init(meanLuma: Double, lumaDeviation: Double, meanCb: Double, meanCr: Double) {
        self.meanLuma = meanLuma
        self.lumaDeviation = lumaDeviation
        self.meanCb = meanCb
        self.meanCr = meanCr
    }

    /// Luma and both chroma planes near zero: a buffer nothing was drawn into (shows as green).
    public var isUninitialized: Bool { meanLuma < 10 && meanCb < 40 && meanCr < 40 }

    /// Flat black (video-range black is luma 16, neutral chroma).
    public var isBlack: Bool { meanLuma < 18 && lumaDeviation < 2 && !isUninitialized }

    /// Black or uninitialised: no picture.
    public var isBlank: Bool { isUninitialized || isBlack }

    /// A lot of luma detail (a textured scene: the kind of picture a starved encoder turns into blocks).
    public var isDetailed: Bool { lumaDeviation >= 25 }
}

/// A decoded picture. Apple implementation (`PlatformApple.PixelBufferFrame`) wraps a CVPixelBuffer.
public protocol DecodedVideoFrame: Sendable {
    var width: Int { get }
    var height: Int { get }
    var pts: MediaTime { get }
    /// Luma, downscaled keeping aspect to at most `maxWidth` wide (for motion detection).
    func grayThumbnail(maxWidth: Int) -> GrayImage?
    /// Statistics of the planes on a coarse grid (about 64 columns), nil when the picture cannot be read. The default is nil.
    func pictureStatistics() -> PictureStatistics?
}

public extension DecodedVideoFrame {
    func pictureStatistics() -> PictureStatistics? { nil }
}

/// What a transcoder can say about itself, for the health check and the logs (every field optional: unknown is nil).
public struct TranscoderDiagnostics: Sendable {
    /// The decoder session is VideoToolbox's hardware decoder (nil: no session yet).
    public var decoderIsHardware: Bool?
    public var encoderIsHardware: Bool?
    /// Statistics of a decoded input picture, sampled about once a second.
    public var inputPicture: PictureStatistics?
    /// Bytes and picture size of the newest keyframe the encoder produced.
    public var lastKeyframeBytes: Int?
    public var lastKeyframeWidth: Int?
    public var lastKeyframeHeight: Int?
    /// How long the last pictures took to decode and encode, per picture (nil until measured).
    public var millisecondsPerPicture: Double?

    public init() {}

    /// "decoder hardware, encoder software" (unknown parts left out).
    public var codecDescription: String {
        func word(_ hardware: Bool?) -> String? { hardware.map { $0 ? "hardware" : "software" } }
        return [word(decoderIsHardware).map { "decoder \($0)" }, word(encoderIsHardware).map { "encoder \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }
}

public protocol VideoDecoding: AnyObject, Sendable {
    func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)?
    func invalidate()
}

public protocol VideoEncoding: AnyObject, Sendable {
    func encode(_ frame: any DecodedVideoFrame, wallClock: Date, forceKeyframe: Bool) async throws -> [EncodedVideoFrame]
    func invalidate()
}

/// Decode → scale → encode H.264.
public protocol VideoTranscoding: AnyObject, Sendable {
    func transcode(_ frame: EncodedVideoFrame) async throws -> [EncodedVideoFrame]
    /// Starts the output at the newest picture of `frames` (a GOP in decode order, from a keyframe): every frame is
    /// decoded (inter prediction needs them all) but only the last picture is encoded, as a keyframe. A live view that
    /// starts in the middle of a long source GOP gets a picture of "now" at once instead of waiting for the camera's
    /// next keyframe. The default transcodes every frame and returns the last frame's output.
    func catchUp(_ frames: [EncodedVideoFrame]) async throws -> [EncodedVideoFrame]
    func requestKeyframe()
    func updateBitrate(kbps: Int)
    /// Never waits for a transcode in progress.
    func invalidate()
    /// Hardware or software codecs, a sampled input picture, the newest keyframe's size. The default says nothing.
    var diagnostics: TranscoderDiagnostics { get }
    /// Decode with the software decoder from now on (a rebuilt transcoder after the hardware decoder failed on a keyframe).
    /// The default does nothing.
    func preferSoftwareDecoding()
}

public extension VideoTranscoding {
    var diagnostics: TranscoderDiagnostics { TranscoderDiagnostics() }
    func preferSoftwareDecoding() {}

    func catchUp(_ frames: [EncodedVideoFrame]) async throws -> [EncodedVideoFrame] {
        var last: [EncodedVideoFrame] = []
        for frame in frames {
            let output = try await transcode(frame)
            if !output.isEmpty { last = output }
        }
        return last
    }
}
