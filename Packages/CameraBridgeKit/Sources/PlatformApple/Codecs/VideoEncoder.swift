#if os(macOS)
import BridgeSupport
import CoreMedia
import CoreVideo
import Foundation
import MediaCore
import Synchronization
import VideoToolbox

/// H.264 (HEVC internally, for tests and future tiers) encoding with a VTCompressionSession.
///
/// Settings: no frame reordering (PTS = DTS), `MaxKeyFrameInterval` = the input frame rate (`inputFrameRate`: the
/// expected rate, else fps) × keyframe interval and
/// `MaxKeyFrameIntervalDuration` = the interval (IDR cadence), `AverageBitRate` with a 1-second `DataRateLimits` cap of
/// 1.5 × the average, `ExpectedFrameRate` (the input frame rate), `RealTime`. Profile from the settings; the H.264 level is the lowest one,
/// never below the requested level, whose frame size and macroblock rate fit width × height × fps (H.264 Table A-1:
/// HomeKit may pick 1080p at level 3.1, which VideoToolbox refuses); `.auto`, sizes beyond level 5.2 and a level
/// VideoToolbox still refuses fall back to the profile's AutoLevel (logged).
/// Each `encode` submits one picture and completes it before returning (one output per input, same PTS). Pictures of
/// another size are scaled (letterboxed) first. Duplicate or slightly earlier PTS (camera jitter) are encoded as they
/// are (VideoToolbox accepts them); a PTS more than 1 s before the previous one (a new source timeline) starts a new
/// session, so that frame is an IDR. An invalidated session is recreated once per call. The async `encode` runs on
/// the encoder's own serial queue; `updateBitrate` never waits for an encode (it applies from the next picture).
final class AppleVideoEncoder: VideoEncoding {
    private final class State {
        var session: VTCompressionSession?
        var scaler: PixelScaler?
        var compositor: TimestampOverlayCompositor?
        var loggedOverlayFailure = false
        var format: VideoFormat?
        var bitrateKbps: Int
        var lastPTS: MediaTime?
        /// VideoToolbox's answer for the running session (nil: no session or no answer).
        var isHardware: Bool?
        var lastKeyframeBytes: Int?
        var lastKeyframeSize: (width: Int, height: Int)?

        init(bitrateKbps: Int) {
            self.bitrateKbps = bitrateKbps
        }
    }

    let settings: VideoEncoderSettings
    let codec: VideoCodec
    /// The timestamp overlay drawn on every picture (asked for at each one; nil: none).
    private let overlay: (any TimestampOverlayProviding)?
    private let state: Mutex<State>
    /// The bit rate `updateBitrate` asked for; applied under the lock before the next picture.
    private let requestedBitrateKbps: Atomic<Int>
    private let work = CodecWorkQueue(label: "CameraBridge.VideoEncoder")
    /// Encodes that fail with `sessionFailed(-1)` before reaching VideoToolbox (tests).
    private let injectedFailures = Atomic<Int>(0)
    private static let log = Log(category: "VideoEncoder")
    /// A PTS this far before the previous one is a new source timeline.
    private static let timelineRestart = 1.0
    /// Throws `MediaCodecError.unsupported` for invalid settings and `.sessionFailed` if VideoToolbox refuses them.
    init(settings: VideoEncoderSettings, codec: VideoCodec = .h264, overlay: (any TimestampOverlayProviding)? = nil) throws {
        guard settings.width > 0, settings.height > 0, settings.fps > 0, settings.bitrateKbps > 0 else {
            throw MediaCodecError.unsupported("encoder settings \(settings.width)×\(settings.height) @ \(settings.fps) fps, \(settings.bitrateKbps) kbit/s")
        }
        self.settings = settings
        self.codec = codec
        self.overlay = overlay
        let state = State(bitrateKbps: settings.bitrateKbps)
        state.session = try Self.makeSession(settings: settings, codec: codec, bitrateKbps: settings.bitrateKbps)
        Self.sessionCreated(state, settings: settings, codec: codec)
        self.state = Mutex(state)
        requestedBitrateKbps = Atomic(settings.bitrateKbps)
    }

    deinit {
        invalidate()
    }

    func encode(_ frame: any DecodedVideoFrame, wallClock: Date, forceKeyframe: Bool) async throws -> [EncodedVideoFrame] {
        try await work.run { try self.encodeNow(frame, wallClock: wallClock, forceKeyframe: forceKeyframe) }
    }

    /// Synchronous `encode`.
    func encodeNow(_ frame: any DecodedVideoFrame, wallClock: Date, forceKeyframe: Bool) throws -> [EncodedVideoFrame] {
        guard let picture = frame as? PixelBufferFrame else {
            throw MediaCodecError.unsupported("AppleVideoEncoder encodes PixelBufferFrame pictures only")
        }
        if injectedFailures.load(ordering: .relaxed) > 0 {
            injectedFailures.subtract(1, ordering: .relaxed)
            throw MediaCodecError.sessionFailed(-1)
        }
        return try state.withLock { state in
            let wantedKbps = requestedBitrateKbps.load(ordering: .relaxed)
            if wantedKbps != state.bitrateKbps {
                state.bitrateKbps = wantedKbps
                if let session = state.session { Self.applyBitrate(wantedKbps, to: session) }
            }
            let outputs: [VideoSampleBuffers.EncodedOutput]
            do {
                outputs = try encode(picture, wallClock: wallClock, forceKeyframe: forceKeyframe, state: state)
            } catch MediaCodecError.sessionFailed(kVTInvalidSessionErr) {
                if let session = state.session { VTCompressionSessionInvalidate(session) }
                state.session = nil
                outputs = try encode(picture, wallClock: wallClock, forceKeyframe: forceKeyframe, state: state)
            }
            let frames = outputs.compactMap { output -> EncodedVideoFrame? in
                guard !output.nalUnits.isEmpty else { return nil }
                let format = Self.format(for: output, cached: state.format, settings: settings)
                state.format = format
                return EncodedVideoFrame(format: format, nalUnits: output.nalUnits, isKeyframe: output.isKeyframe, pts: output.pts, dts: output.dts,
                                         wallClock: wallClock)
            }
            if let keyframe = frames.last(where: \.isKeyframe) {
                state.lastKeyframeBytes = keyframe.nalUnits.reduce(0) { $0 + $1.count }
                state.lastKeyframeSize = (keyframe.format.width, keyframe.format.height)
            }
            return frames
        }
    }

    /// The next `count` encodes fail (tests).
    func injectFailures(_ count: Int) { injectedFailures.store(count, ordering: .relaxed) }

    /// Takes effect from the next picture; never waits for an encode in progress.
    func updateBitrate(kbps: Int) {
        guard kbps > 0 else { return }
        requestedBitrateKbps.store(kbps, ordering: .relaxed)
    }

    func invalidate() {
        state.withLock { state in
            if let session = state.session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            state.session = nil
            state.scaler = nil
        }
    }

    // MARK: - Private

    private func encode(_ picture: PixelBufferFrame, wallClock: Date, forceKeyframe: Bool, state: State) throws -> [VideoSampleBuffers.EncodedOutput] {
        if let last = state.lastPTS, last.seconds - picture.pts.seconds > Self.timelineRestart, let session = state.session {
            // A new timeline (source reconnected): start a fresh session, so rate control restarts and this is an IDR.
            // Duplicate or slightly earlier PTS (jitter) go to the running session, which accepts them.
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            state.session = nil
        }
        let session: VTCompressionSession
        if let running = state.session {
            session = running
        } else {
            session = try Self.makeSession(settings: settings, codec: codec, bitrateKbps: state.bitrateKbps)
            state.session = session
            Self.sessionCreated(state, settings: settings, codec: codec)
        }
        state.lastPTS = picture.pts
        var image = picture.pixelBuffer
        let overlayNow = overlay?.current.flatMap { $0.settings.enabled ? $0 : nil }
        if overlayNow != nil || CVPixelBufferGetWidth(image) != settings.width || CVPixelBufferGetHeight(image) != settings.height {
            // Also a same-size copy while an overlay is drawn: the decoder's picture is shared with its reference frames.
            let scaler = try state.scaler ?? PixelScaler()
            state.scaler = scaler
            image = try scaler.scale(image, width: settings.width, height: settings.height, pool: VTCompressionSessionGetPixelBufferPool(session))
        }
        if let overlayNow {
            let compositor = state.compositor ?? TimestampOverlayCompositor()
            state.compositor = compositor
            if !compositor.apply(overlayNow.text(for: wallClock), settings: overlayNow.settings, to: image), !state.loggedOverlayFailure {
                state.loggedOverlayFailure = true
                Self.log.warning("the timestamp overlay could not be drawn on a \(settings.width)×\(settings.height) picture; the picture goes out without it")
            }
        }
        let pts = VideoSampleBuffers.cmTime(picture.pts)
        guard pts.isValid else { throw MediaCodecError.unsupported("picture without a timestamp") }
        let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let collector = EncodeOutput()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts,
                                                     duration: CMTime(value: 1, timescale: Int32(settings.inputFrameRate)), frameProperties: properties,
                                                     infoFlagsOut: nil) { status, flags, sample in
            collector.record(status: status, flags: flags, sample: sample)
        }
        guard status == noErr else { throw MediaCodecError.sessionFailed(status) }
        let completed = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
        guard completed == noErr else { throw MediaCodecError.sessionFailed(completed) }
        return try collector.outputs()
    }

    /// Reuses the previous format while the parameter sets are unchanged.
    private static func format(for output: VideoSampleBuffers.EncodedOutput, cached: VideoFormat?, settings: VideoEncoderSettings) -> VideoFormat {
        if let cached, cached.codec == output.codec, cached.parameterSets == output.parameterSets { return cached }
        let parsed: VideoFormat? = switch output.codec {
        case .h264: VideoFormat.h264(sps: output.parameterSets[0], pps: output.parameterSets[1])
        case .hevc: VideoFormat.hevc(vps: output.parameterSets[0], sps: output.parameterSets[1], pps: output.parameterSets[2])
        }
        return parsed ?? VideoFormat(codec: output.codec, width: settings.width, height: settings.height, parameterSets: output.parameterSets)
    }

    private static func makeSession(settings: VideoEncoderSettings, codec: VideoCodec, bitrateKbps: Int) throws -> VTCompressionSession {
        guard codec == .h264 else {
            return try makeSession(settings: settings, codec: codec, profileLevel: kVTProfileLevel_HEVC_Main_AutoLevel, bitrateKbps: bitrateKbps)
        }
        let size = "\(settings.width)×\(settings.height) @ \(settings.fps) fps"
        let level = fittedH264Level(width: settings.width, height: settings.height, fps: settings.fps, requested: settings.level)
        if let level, let requested = levelIDC(settings.level), level != requested {
            log.info("H.264 level \(requested) does not fit \(size); using level \(level)")
        } else if level == nil, settings.level != .auto {
            log.notice("\(size) exceeds H.264 level 5.2; letting VideoToolbox choose the level")
        }
        guard let level else {
            return try makeSession(settings: settings, codec: codec, profileLevel: profileLevel(settings.profile, levelIDC: nil), bitrateKbps: bitrateKbps)
        }
        do {
            return try makeSession(settings: settings, codec: codec, profileLevel: profileLevel(settings.profile, levelIDC: level), bitrateKbps: bitrateKbps)
        } catch MediaCodecError.sessionFailed(let status) {
            log.warning("VideoToolbox refused H.264 level \(level) for \(size) (\(status)); using AutoLevel")
            return try makeSession(settings: settings, codec: codec, profileLevel: profileLevel(settings.profile, levelIDC: nil), bitrateKbps: bitrateKbps)
        }
    }

    private static func makeSession(settings: VideoEncoderSettings, codec: VideoCodec, profileLevel: CFString, bitrateKbps: Int) throws -> VTCompressionSession {
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: settings.width,
            kCVPixelBufferHeightKey: settings.height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(settings.width), height: Int32(settings.height),
                                                codecType: codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
                                                encoderSpecification: specification, imageBufferAttributes: attributes as CFDictionary,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw MediaCodecError.sessionFailed(status) }

        let keyframeSeconds = max(settings.keyframeInterval / .seconds(1), 1.0 / Double(settings.fps))
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, settings.realtime ? kCFBooleanTrue : kCFBooleanFalse),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, profileLevel),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, max(1, Int((keyframeSeconds * Double(settings.inputFrameRate)).rounded())) as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyframeSeconds as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, settings.inputFrameRate as CFNumber),
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(session, key: key, value: value)
            guard result == noErr else {
                VTCompressionSessionInvalidate(session)
                throw MediaCodecError.sessionFailed(result)
            }
        }
        if codec == .h264, settings.profile != .baseline {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        }
        applyBitrate(bitrateKbps, to: session)
        // Tagged BT.709, the colour space of every HomeKit controller's display path.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCMFormatDescriptionColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCMFormatDescriptionTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepared == noErr else {
            VTCompressionSessionInvalidate(session)
            throw MediaCodecError.sessionFailed(prepared)
        }
        return session
    }

    /// A session was made: whether VideoToolbox runs it in hardware is logged (a software encoder cannot keep up with a
    /// large picture in real time).
    private static func sessionCreated(_ state: State, settings: VideoEncoderSettings, codec: VideoCodec) {
        state.isHardware = state.session.flatMap(usingHardware)
        let kind = state.isHardware.map { $0 ? "hardware" : "software" } ?? "hardware or software"
        log.info("\(codec == .h264 ? "H.264" : "HEVC") encoder session created: \(settings.width)×\(settings.height) @ \(settings.fps) fps, "
                 + "\(state.bitrateKbps) kbit/s (\(kind))")
    }

    private static func usingHardware(_ session: VTCompressionSession) -> Bool? {
        var value: CFTypeRef?
        let status = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &value)
        guard status == noErr, let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    /// Hardware or software encoding, and the newest keyframe's size (the transcoder's diagnostics).
    var diagnostics: (isHardware: Bool?, keyframeBytes: Int?, keyframeWidth: Int?, keyframeHeight: Int?) {
        state.withLock { ($0.isHardware, $0.lastKeyframeBytes, $0.lastKeyframeSize?.width, $0.lastKeyframeSize?.height) }
    }

    private static func applyBitrate(_ kbps: Int, to session: VTCompressionSession) {
        let bitsPerSecond = kbps * 1_000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
        let limits = [Double(bitsPerSecond) * 1.5 / 8, 1.0] as CFArray   // bytes per 1 s
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    /// The lowest H.264 level (level_idc, e.g. 40 for 4.0), not below `requested`, that fits width × height × fps
    /// (MediaCore's `H264LevelLimits`, Table A-1: frame size and macroblock rate — the two VideoToolbox enforces, failing
    /// `PrepareToEncodeFrames` with -12902 otherwise — and each dimension within √(8 × MaxFS) macroblocks). Nil for
    /// `.auto` and for sizes beyond level 5.2 (the caller uses AutoLevel).
    static func fittedH264Level(width: Int, height: Int, fps: Int, requested: VideoEncoderSettings.EncoderLevel) -> Int? {
        guard let minimum = levelIDC(requested) else { return nil }
        return H264LevelLimits.lowestLevel(width: width, height: height, fps: Double(max(1, fps)), atLeast: minimum)
    }

    private static func levelIDC(_ level: VideoEncoderSettings.EncoderLevel) -> Int? {
        switch level {
        case .level3_1: 31
        case .level3_2: 32
        case .level4_0: 40
        case .level4_1: 41
        case .level5_1: 51
        case .auto: nil
        }
    }

    /// The VideoToolbox profile-level constant; nil level → the profile's AutoLevel.
    static func profileLevel(_ profile: VideoEncoderSettings.EncoderProfile, levelIDC: Int?) -> CFString {
        switch (profile, levelIDC) {
        case (.baseline, 31): kVTProfileLevel_H264_Baseline_3_1
        case (.baseline, 32): kVTProfileLevel_H264_Baseline_3_2
        case (.baseline, 40): kVTProfileLevel_H264_Baseline_4_0
        case (.baseline, 41): kVTProfileLevel_H264_Baseline_4_1
        case (.baseline, 42): kVTProfileLevel_H264_Baseline_4_2
        case (.baseline, 50): kVTProfileLevel_H264_Baseline_5_0
        case (.baseline, 51): kVTProfileLevel_H264_Baseline_5_1
        case (.baseline, 52): kVTProfileLevel_H264_Baseline_5_2
        case (.baseline, _): kVTProfileLevel_H264_Baseline_AutoLevel
        case (.main, 31): kVTProfileLevel_H264_Main_3_1
        case (.main, 32): kVTProfileLevel_H264_Main_3_2
        case (.main, 40): kVTProfileLevel_H264_Main_4_0
        case (.main, 41): kVTProfileLevel_H264_Main_4_1
        case (.main, 42): kVTProfileLevel_H264_Main_4_2
        case (.main, 50): kVTProfileLevel_H264_Main_5_0
        case (.main, 51): kVTProfileLevel_H264_Main_5_1
        case (.main, 52): kVTProfileLevel_H264_Main_5_2
        case (.main, _): kVTProfileLevel_H264_Main_AutoLevel
        case (.high, 31): kVTProfileLevel_H264_High_3_1
        case (.high, 32): kVTProfileLevel_H264_High_3_2
        case (.high, 40): kVTProfileLevel_H264_High_4_0
        case (.high, 41): kVTProfileLevel_H264_High_4_1
        case (.high, 42): kVTProfileLevel_H264_High_4_2
        case (.high, 50): kVTProfileLevel_H264_High_5_0
        case (.high, 51): kVTProfileLevel_H264_High_5_1
        case (.high, 52): kVTProfileLevel_H264_High_5_2
        case (.high, _): kVTProfileLevel_H264_High_AutoLevel
        }
    }
}

/// Collects what an encode call's output handler reports.
private final class EncodeOutput: Sendable {
    private struct Result {
        var outputs: [VideoSampleBuffers.EncodedOutput] = []
        var error: (any Error)?
    }

    private let result = Mutex(Result())

    func record(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        guard status == noErr else {
            result.withLock { $0.error = MediaCodecError.sessionFailed(status) }
            return
        }
        guard let sample, !flags.contains(.frameDropped) else { return }
        do {
            let output = try VideoSampleBuffers.encodedOutput(sample)
            result.withLock { $0.outputs.append(output) }
        } catch {
            result.withLock { $0.error = error }
        }
    }

    func outputs() throws -> [VideoSampleBuffers.EncodedOutput] {
        try result.withLock { result in
            if let error = result.error { throw error }
            return result.outputs
        }
    }
}
#endif
