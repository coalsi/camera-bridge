import BridgeSupport
import Foundation
import HAPCamera
import MediaCore

/// HAP's H.264 levels as `level_idc`. Their limits (ITU-T H.264 Table A-1) are MediaCore's `H264LevelLimits`, the
/// table the encoder uses too.
enum H264Levels {
    static func idc(_ level: H264Level) -> UInt8 {
        switch level {
        case .level3_1: 31
        case .level3_2: 32
        case .level4_0: 40
        }
    }
}

/// How one track reaches the controller: as the camera sent it, or through a codec.
enum VideoPath: Equatable, Sendable {
    case passthrough
    /// Why the source does not fit (logged).
    case transcode(String)
}

/// Recording audio (research brief §3.9, integration brief §5.2): AAC-LC at the selected rate, only while
/// RecordingAudioActive; silence when the camera has no (enabled) audio.
enum RecordingAudioPlan: Equatable, Sendable {
    case none, passthrough, transcode, silent
}

/// Passthrough-or-transcode rules for live view and HKSV recording (plan W3-1 items 3 and 5, integration brief §5.2–§5.4,
/// spec §5): a source passes through when it is H.264 in a supported profile, no larger than the selection (2 % tolerance
/// for coded sizes such as 1088 lines), within the selected level (the declared `level_idc`, or — for cameras that
/// over-declare — the actual frame size, macroblock rate and picture dimensions at the selected frame rate,
/// `H264LevelLimits`, so measured timestamp jitter above it does not count; skipped when the selected size itself
/// exceeds the selected level, as 1440p and 4K do: no offered level carries them and a transcoder would raise the level
/// too), not faster than the selected frame rate (10 % tolerance) and without B-frames (`StreamTraits.usesBFrames`).
/// Recording also needs the selected profile or a lower one and a GOP no longer than the fragment plus the fragmenter's
/// jitter allowance (min(5 %, 50 ms): a fragment is one GOP at least, and research brief §3.9 caps fragments at
/// fragmentLength; callers pass the longest recent GOP so smart-codec GOPs that only average out are caught; an unknown
/// GOP counts as fitting). Everything else is transcoded to the selection.
enum MediaFit {
    static let dimensionTolerance = 1.02
    static let frameRateTolerance = 1.10
    /// Live keyframe interval when transcoding (plan: "keyframe every 2 s").
    static let liveKeyframeInterval: Duration = .seconds(2)
    /// Requests narrower than this use the sub stream when there is one (plan: "requested width < 1280 or Watch").
    static let subStreamWidthLimit = 1280
    /// Audio packet times from this up mean a remote viewer (integration brief §5.4: "packet_time ≥ 60 means remote").
    static let remotePacketTimeMs = 60

    /// Baseline < Main < High; nil for profiles HomeKit does not offer (Extended, High 10/4:2:2/4:4:4, …).
    static func profileRank(_ profileIDC: UInt8) -> Int? {
        switch profileIDC {
        case 66: 0
        case 77: 1
        case 100: 2
        default: nil
        }
    }

    static func rank(_ profile: H264Profile) -> Int {
        switch profile {
        case .baseline: 0
        case .main: 1
        case .high: 2
        }
    }

    /// Why passthrough is refused while the timestamp overlay is on: the overlay is drawn on decoded pictures, so
    /// every picture goes through the Mac's video encoder.
    static let timestampOverlayReason = "timestamp overlay"

    /// Why passthrough is refused for a camera that sends B-frames.
    static let bFramesReason = "the camera sends B-frames (turn them off in its video settings)"

    /// `qualityMode`: `.originalWhenPossible` skips the resolution/frame-rate/level match against the hub's selected
    /// configuration (the point of the setting is to ignore a smaller request) but keeps the profile and GOP checks,
    /// which HKSV fragmenting still needs; it falls back to transcoding for HEVC or B-frame sources just like the
    /// default mode (docs/CONTRACT_CHANGES.md 2026-10-01).
    ///
    /// `timestampOverlay` (`CameraConfiguration.timestampOverlay.enabled`) always transcodes: the overlay is drawn on
    /// decoded pictures (docs/CONTRACT_CHANGES.md 2026-10-02).
    static func recording(source: VideoFormat, frameRate: Double?, gop: Duration?, bFrames: Bool = false,
                          configuration: CameraRecordingConfiguration, qualityMode: RecordingQualityMode = .matchHubRequest,
                          timestampOverlay: Bool = false) -> VideoPath {
        if timestampOverlay { return .transcode(timestampOverlayReason) }
        if qualityMode == .originalWhenPossible {
            guard source.codec == .h264 else { return .transcode("the source is \(source.codec.rawValue), not H.264") }
            if bFrames { return .transcode(bFramesReason) }
            guard let rank = profileRank(source.profile), rank <= Self.rank(configuration.videoProfile) else {
                return .transcode("profile \(source.profile) does not fit the selected \(configuration.videoProfile)")
            }
            if let gop, gop > .milliseconds(configuration.fragmentLengthMs) + recordingGOPAllowance(fragmentLengthMs: configuration.fragmentLengthMs) {
                return .transcode("GOP \(Self.seconds(gop)) s is longer than the \(configuration.fragmentLengthMs) ms fragment")
            }
            return .passthrough
        }
        let resolution = configuration.resolution
        if let reason = commonMismatch(source: source, frameRate: frameRate, width: resolution.width, height: resolution.height,
                                       fps: resolution.fps, levelIDC: H264Levels.idc(configuration.videoLevel), bFrames: bFrames) {
            return .transcode(reason)
        }
        guard let rank = profileRank(source.profile), rank <= Self.rank(configuration.videoProfile) else {
            return .transcode("profile \(source.profile) does not fit the selected \(configuration.videoProfile)")
        }
        if let gop, gop > .milliseconds(configuration.fragmentLengthMs) + recordingGOPAllowance(fragmentLengthMs: configuration.fragmentLengthMs) {
            return .transcode("GOP \(Self.seconds(gop)) s is longer than the \(configuration.fragmentLengthMs) ms fragment")
        }
        return .passthrough
    }

    /// How much longer than the fragment a passthrough GOP may measure: `GOPFragmenter`'s jitter allowance, min(5 %, 50 ms).
    static func recordingGOPAllowance(fragmentLengthMs: Int) -> Duration {
        min(.milliseconds(max(0, fragmentLengthMs)) / 20, .milliseconds(50))
    }

    /// `qualityMode`: `.originalQuality` skips the match against the controller's requested size/level (the point of
    /// the setting is to ignore a smaller or more conservative request and send the camera's own H.264 untouched) but
    /// still falls back to transcoding for HEVC or B-frame sources (docs/CONTRACT_CHANGES.md 2026-10-01).
    ///
    /// `timestampOverlay` always transcodes (see `recording`).
    static func live(source: VideoFormat, frameRate: Double?, bFrames: Bool = false, requested: SelectedVideoParameters,
                     qualityMode: LiveQualityMode = .matchHomeKitRequest, timestampOverlay: Bool = false) -> VideoPath {
        if timestampOverlay { return .transcode(timestampOverlayReason) }
        if qualityMode == .originalQuality {
            guard source.codec == .h264 else { return .transcode("the source is \(source.codec.rawValue), not H.264") }
            if bFrames { return .transcode(bFramesReason) }
            guard profileRank(source.profile) != nil else { return .transcode("profile \(source.profile) is not Baseline, Main or High") }
            return .passthrough
        }
        let resolution = requested.resolution
        if let reason = commonMismatch(source: source, frameRate: frameRate, width: resolution.width, height: resolution.height,
                                       fps: resolution.fps, levelIDC: H264Levels.idc(requested.level), bFrames: bFrames) {
            return .transcode(reason)
        }
        guard profileRank(source.profile) != nil else { return .transcode("profile \(source.profile) is not Baseline, Main or High") }
        return .passthrough
    }

    /// Live requests below 1280 pixels wide (incl. the Watch's 320×240) and remote ones (audio packet time ≥ 60 ms) prefer
    /// the sub stream, unless `mode` forces one stream for every live view of this camera. So does any request the sub stream's
    /// own picture already covers (`subStreamSize` at least as wide and as tall: a 1280×720 request is read from a 1280×720 sub
    /// stream, not decoded from the main stream's 8 MP and scaled down).
    static func prefersSubStream(for requested: SelectedVideoParameters, audio: SelectedAudioParameters?, mode: LiveStreamMode = .automatic,
                                 subStreamSize: VideoResolution? = nil) -> Bool {
        switch mode {
        case .alwaysMain: return false
        case .alwaysSub: return true
        case .automatic:
            if requested.resolution.width < subStreamWidthLimit || (audio?.packetTimeMs ?? 0) >= remotePacketTimeMs { return true }
            guard let sub = subStreamSize, sub.width > 0, sub.height > 0 else { return false }
            return sub.width >= requested.resolution.width && sub.height >= requested.resolution.height
        }
    }

    static func recordingAudio(source: AudioFormat?, audioActive: Bool, configuration: CameraRecordingConfiguration) -> RecordingAudioPlan {
        guard audioActive else { return .none }
        guard let source else { return .silent }
        let isAACLC = source.codec == .aac
            && (source.audioSpecificConfig.map { AudioSpecificConfig($0)?.objectType == AudioSpecificConfig.aacLC } ?? true)
        if isAACLC, source.sampleRate == configuration.audioSampleRate.hertz, source.channels == max(1, configuration.audioChannels) {
            return .passthrough
        }
        return .transcode
    }

    /// The encoder for a transcoded recording: the selected size, profile, level, bit rate and frame rate (the output's
    /// limit), the source's measured frame rate as the expected one (`expectedFrameRate`), keyframes every
    /// `iFrameInterval` (never beyond the fragment length).
    static func encoderSettings(for configuration: CameraRecordingConfiguration, sourceFrameRate: Double?) -> VideoEncoderSettings {
        let resolution = configuration.resolution
        let interval = max(1, min(configuration.iFrameIntervalMs > 0 ? configuration.iFrameIntervalMs : configuration.fragmentLengthMs,
                                  configuration.fragmentLengthMs > 0 ? configuration.fragmentLengthMs : 4000))
        return VideoEncoderSettings(width: resolution.width, height: resolution.height, fps: max(1, resolution.fps),
                                    bitrateKbps: max(100, configuration.videoBitrateKbps), profile: encoderProfile(configuration.videoProfile),
                                    level: encoderLevel(configuration.videoLevel), keyframeInterval: .milliseconds(interval), realtime: true,
                                    expectedFrameRate: expectedFrameRate(selected: resolution.fps, source: sourceFrameRate))
    }

    /// The encoder for a transcoded live stream: the requested size, frame rate (the output's limit) and bit rate, Main
    /// (the only profile offered), the requested level, a keyframe every 2 s, the source's measured frame rate as the
    /// expected one.
    static func encoderSettings(for requested: SelectedVideoParameters, sourceFrameRate: Double?) -> VideoEncoderSettings {
        let resolution = requested.resolution
        return VideoEncoderSettings(width: resolution.width, height: resolution.height, fps: max(1, resolution.fps),
                                    bitrateKbps: max(50, requested.maxBitrateKbps), profile: encoderProfile(requested.profile),
                                    level: encoderLevel(requested.level), keyframeInterval: liveKeyframeInterval, realtime: true,
                                    expectedFrameRate: expectedFrameRate(selected: resolution.fps, source: sourceFrameRate))
    }

    /// The encoder for a live stream that transcodes only because the timestamp overlay asked for it while the camera's
    /// original quality was wanted: the camera's own size (even), the measured frame rate and a bit rate its pictures need
    /// at that size (never below what the controller asked for), the level left to the encoder. Otherwise the requested one
    /// (`encoderSettings(for:sourceFrameRate:)`).
    static func liveEncoderSettings(for requested: SelectedVideoParameters, source: VideoFormat, sourceFrameRate: Double?,
                                    qualityMode: LiveQualityMode, timestampOverlay: Bool) -> VideoEncoderSettings {
        guard timestampOverlay, qualityMode == .originalQuality else { return encoderSettings(for: requested, sourceFrameRate: sourceFrameRate) }
        let fps = originalFrameRate(sourceFrameRate, fallback: requested.resolution.fps)
        return VideoEncoderSettings(width: max(2, source.width & ~1), height: max(2, source.height & ~1), fps: fps,
                                    bitrateKbps: max(max(50, requested.maxBitrateKbps), originalBitrateKbps(source, fps: fps)),
                                    profile: encoderProfile(requested.profile), level: .auto, keyframeInterval: liveKeyframeInterval, realtime: true,
                                    expectedFrameRate: nil)
    }

    /// As `liveEncoderSettings` for a recording (the hub's selected profile, keyframes as the selection asks).
    static func recordingEncoderSettings(for configuration: CameraRecordingConfiguration, source: VideoFormat, sourceFrameRate: Double?,
                                         qualityMode: RecordingQualityMode, timestampOverlay: Bool) -> VideoEncoderSettings {
        guard timestampOverlay, qualityMode == .originalWhenPossible else { return encoderSettings(for: configuration, sourceFrameRate: sourceFrameRate) }
        var settings = encoderSettings(for: configuration, sourceFrameRate: sourceFrameRate)
        let fps = originalFrameRate(sourceFrameRate, fallback: configuration.resolution.fps)
        settings.width = max(2, source.width & ~1)
        settings.height = max(2, source.height & ~1)
        settings.fps = fps
        settings.bitrateKbps = max(settings.bitrateKbps, originalBitrateKbps(source, fps: fps))
        settings.level = .auto
        settings.expectedFrameRate = nil
        return settings
    }

    private static func originalFrameRate(_ measured: Double?, fallback: Int) -> Int {
        guard let measured, measured.isFinite, measured >= 1 else { return max(1, fallback) }
        return min(60, Int(measured.rounded(.up)))
    }

    /// About 0.07 bit per pixel per frame (good H.264 quality for a security camera's picture), 500…12 000 kbit/s.
    private static func originalBitrateKbps(_ source: VideoFormat, fps: Int) -> Int {
        min(12_000, max(500, Int(Double(source.width * source.height) * Double(fps) * 0.07 / 1000)))
    }

    // MARK: Private

    private static func commonMismatch(source: VideoFormat, frameRate: Double?, width: Int, height: Int, fps: Int, levelIDC: UInt8,
                                       bFrames: Bool) -> String? {
        guard source.codec == .h264 else { return "the source is \(source.codec.rawValue), not H.264" }
        if bFrames { return bFramesReason }
        guard Double(source.width) <= Double(width) * dimensionTolerance, Double(source.height) <= Double(height) * dimensionTolerance else {
            return "\(source.width)×\(source.height) is larger than \(width)×\(height)"
        }
        if let frameRate, fps > 0, frameRate > Double(fps) * frameRateTolerance {
            return "\(Int(frameRate.rounded())) fps is faster than \(fps) fps"
        }
        let selectedRate = Double(max(fps, 1))
        // A selection its own level cannot carry (1440p, 4K: no offered level does) gains nothing from a transcode.
        guard H264LevelLimits.fits(width: width, height: height, fps: selectedRate, levelIDC: Int(levelIDC)) else { return nil }
        // Measured rates a little above the selected one are timestamp jitter (the frame-rate check above decides).
        let rate = min(frameRate ?? selectedRate, selectedRate)
        let declaredFits = source.level != 0 && source.level <= levelIDC
        if !declaredFits && !H264LevelLimits.fits(width: source.width, height: source.height, fps: rate, levelIDC: Int(levelIDC)) {
            return "level \(source.level) does not fit level \(levelIDC)"
        }
        return nil
    }

    /// The source's measured frame rate as an encoder hint, rounded up (a mean over the last 90 frames drops below the
    /// camera's rate when it skipped a frame or two); nil when unknown or not below the selected rate. Never a limit: the
    /// output keeps every picture up to the selected rate (a camera measured at 24.45 fps for 25 fps would otherwise
    /// lose a picture every second for the whole stream).
    private static func expectedFrameRate(selected: Int, source: Double?) -> Int? {
        guard let source, source.isFinite, source >= 1 else { return nil }
        let expected = Int(source.rounded(.up))
        return expected < max(1, selected) ? expected : nil
    }

    private static func encoderProfile(_ profile: H264Profile) -> VideoEncoderSettings.EncoderProfile {
        switch profile {
        case .baseline: .baseline
        case .main: .main
        case .high: .high
        }
    }

    private static func encoderLevel(_ level: H264Level) -> VideoEncoderSettings.EncoderLevel {
        switch level {
        case .level3_1: .level3_1
        case .level3_2: .level3_2
        case .level4_0: .level4_0
        }
    }

    static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f", duration.timeInterval)
    }
}
