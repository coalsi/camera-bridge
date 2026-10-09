#if os(macOS)
import BridgeSupport
import CoreMedia
import CoreVideo
import Foundation
import MediaCore
import Synchronization
import VideoToolbox

/// H.264/HEVC decoding with a VTDecompressionSession into IOSurface-backed NV12 pixel buffers.
///
/// Decodes synchronously (the VideoToolbox call returns once the frame is out), so `decode` returns the picture of
/// the frame passed in. `decodeAllNow` returns every picture VideoToolbox emitted for the call, in emission order (a
/// keyframe that yields nothing flushes held frames, which can emit several); `decode` / `decodeNow` return the newest
/// of them (nil while the decoder holds frames back). A parameter-set change switches the format description (and
/// the session if it cannot accept it). An invalidated session (e.g. after sleep) is recreated once per call. Every
/// session creation (the first, a format the running one cannot take, an invalidated one) is logged with its reason, and
/// so is every format description change. The async `decode` runs on the decoder's own serial queue.
final class AppleVideoDecoder: VideoDecoding {
    private final class State {
        var session: VTDecompressionSession?
        var description: CMVideoFormatDescription
        var format: VideoFormat
        /// Sessions are made without VideoToolbox's hardware decoder (`useSoftwareDecoding`).
        var software = false
        /// Why the next session replaces one that existed (logged when it is made).
        var rebuildReason: String?
        /// Whether the running session decodes in hardware (VideoToolbox's answer after creation); nil without a session.
        var sessionIsHardware: Bool?

        init(format: VideoFormat, description: CMVideoFormatDescription) {
            self.format = format
            self.description = description
        }
    }

    private let state: Mutex<State>
    private let work: CodecWorkQueue
    private static let log = Log(category: "VideoDecoder")

    /// The level at which a session's creation, rebuild and format changes are logged: info for a live stream's decoder
    /// (rare, and worth a line), debug for a snapshot decoder (`MediaCodecs.makeSnapshotDecoder`).
    private let sessionLogLevel: LogLevel

    /// Throws `MediaCodecError.unsupported` / `.sessionFailed` if the format's parameter sets are unusable.
    /// `lowPriority`: the work queue runs at utility priority (the live view's self-check decoder).
    init(format: VideoFormat, sessionLogLevel: LogLevel = .info, lowPriority: Bool = false) throws {
        let description = try format.makeFormatDescription()
        state = Mutex(State(format: format, description: description))
        self.sessionLogLevel = sessionLogLevel
        work = CodecWorkQueue(label: "CameraBridge.VideoDecoder", qos: lowPriority ? .utility : .userInitiated)
    }

    private func logSession(_ message: @autoclosure () -> String) { Self.logSession(sessionLogLevel, message()) }

    private static func logSession(_ level: LogLevel, _ message: @autoclosure () -> String) {
        if level <= .debug { log.debug(message()) } else { log.info(message()) }
    }

    deinit {
        invalidate()
    }

    /// The format of the most recent frame (or the initial one).
    var format: VideoFormat { state.withLock { $0.format } }

    /// Whether sessions are made without the hardware decoder.
    var isSoftware: Bool { state.withLock { $0.software } }

    /// Whether the running session decodes in hardware (VideoToolbox's answer when it was made); nil before the first one.
    var isHardware: Bool? { state.withLock { $0.sessionIsHardware } }

    /// Drops the running session; the next one (at the next keyframe) is made without VideoToolbox's hardware decoder. For a
    /// stream the hardware decoder rejects (every delta frame after a keyframe fails with kVTVideoDecoderBadDataErr) though it is
    /// well formed.
    func useSoftwareDecoding(reason: String) {
        state.withLock { state in
            if let session = state.session { VTDecompressionSessionInvalidate(session) }
            state.session = nil
            state.software = true
            state.rebuildReason = "switching to software decoding, " + reason
        }
    }

    /// Drops the running session; the next one is made from the current format description. After a frame the session failed
    /// on, whose state is then unknown (a software session rejects the keyframe after a bad delta frame). The next session's
    /// creation is logged with `reason`.
    func resetSession(reason: String) {
        state.withLock { state in
            if let session = state.session { VTDecompressionSessionInvalidate(session) }
            state.session = nil
            state.rebuildReason = reason
        }
    }

    func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? {
        try await work.run { try self.decodeNow(frame) }
    }

    /// Synchronous `decode`: the newest picture of `decodeAllNow`.
    func decodeNow(_ frame: EncodedVideoFrame) throws -> PixelBufferFrame? {
        try decodeAllNow(frame).last
    }

    /// Every picture VideoToolbox emitted while decoding `frame` (the transcoder calls it under its own lock).
    func decodeAllNow(_ frame: EncodedVideoFrame) throws -> [PixelBufferFrame] {
        try state.withLock { state in
            if frame.format.codec != state.format.codec || frame.format.parameterSets != state.format.parameterSets {
                let description = try frame.format.makeFormatDescription()
                var rebuilt = false
                if let session = state.session, !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) {
                    VTDecompressionSessionInvalidate(session)
                    state.session = nil
                    rebuilt = true
                    state.rebuildReason = "the running session cannot take the new format (\(Self.describe(state.format)) -> \(Self.describe(frame.format)))"
                }
                logSession("decoder format changed: \(Self.describe(state.format)) -> \(Self.describe(frame.format)); "
                              + (rebuilt ? "the running session cannot take it: session rebuilt"
                                         : state.session == nil ? "no session yet" : "session kept, new format description"))
                state.format = frame.format
                state.description = description
            }
            guard let sample = try VideoSampleBuffers.sampleBuffer(for: frame, description: state.description) else { return [] }
            do {
                return try Self.decode(sample, isKeyframe: frame.isKeyframe, state: state, logLevel: sessionLogLevel)
            } catch MediaCodecError.sessionFailed(kVTInvalidSessionErr) {
                if let session = state.session { VTDecompressionSessionInvalidate(session) }
                state.session = nil
                state.rebuildReason = "the session was invalidated (\(kVTInvalidSessionErr), e.g. after sleep)"
                return try Self.decode(sample, isKeyframe: frame.isKeyframe, state: state, logLevel: sessionLogLevel)
            }
        }
    }

    func invalidate() {
        state.withLock { state in
            if let session = state.session { VTDecompressionSessionInvalidate(session) }
            state.session = nil
        }
    }

    private static func decode(_ sample: CMSampleBuffer, isKeyframe: Bool, state: State, logLevel: LogLevel) throws -> [PixelBufferFrame] {
        let session: VTDecompressionSession
        if let running = state.session {
            session = running
        } else {
            session = try makeSession(description: state.description, software: state.software)
            state.sessionIsHardware = usingHardware(session)
            let what = describe(state.format) + " (" + (state.sessionIsHardware.map { $0 ? "hardware" : "software" } ?? (state.software ? "software" : "hardware or software")) + ")"
            if let reason = state.rebuildReason {
                logSession(logLevel, "decoder session rebuilt for \(what): \(reason)")
            } else {
                logSession(logLevel, "decoder session created for \(what)")
            }
            state.rebuildReason = nil
        }
        state.session = session
        let output = DecodeOutput()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, flags, imageBuffer, pts, _ in
            output.record(status: status, flags: flags, imageBuffer: imageBuffer, pts: pts)
        }
        guard status == noErr else { throw MediaCodecError.sessionFailed(status) }
        if isKeyframe, output.isEmpty {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        return try output.pictures()
    }

    /// What VideoToolbox says about the session's decoder; nil when it does not say.
    private static func usingHardware(_ session: VTDecompressionSession) -> Bool? {
        var value: CFTypeRef?
        let status = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil,
                                           valueOut: &value)
        guard status == noErr, let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    /// "H.264 2688×1520, 1 SPS + 2 PPS" (what a decoder is built from).
    static func describe(_ format: VideoFormat) -> String {
        let types = format.parameterSets.map { format.codec == .h264 ? Int(NALUnits.h264Type($0)) : Int(NALUnits.hevcType($0)) }
        let counts = format.codec == .h264
            ? "\(types.filter { $0 == 7 }.count) SPS + \(types.filter { $0 == 8 }.count) PPS"
            : "\(format.parameterSets.count) parameter sets"
        return "\(format.codec == .h264 ? "H.264" : "HEVC") \(format.width)×\(format.height), \(counts)"
    }

    private static func makeSession(description: CMVideoFormatDescription, software: Bool) throws -> VTDecompressionSession {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
        ]
        let specification = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: software ? kCFBooleanFalse : kCFBooleanTrue] as CFDictionary
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: specification,
                                                  imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                                  decompressionSessionOut: &session)
        guard status == noErr, let session else { throw MediaCodecError.sessionFailed(status) }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        return session
    }
}

/// Collects what a decode call's output handler reports.
private final class DecodeOutput: Sendable {
    private struct Result {
        var frames: [PixelBufferFrame] = []
        var error: OSStatus = noErr
    }

    private let result = Mutex(Result())

    var isEmpty: Bool { result.withLock { $0.frames.isEmpty && $0.error == noErr } }

    func record(status: OSStatus, flags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, pts: CMTime) {
        let frame = imageBuffer.map { PixelBufferFrame(pixelBuffer: $0, pts: VideoSampleBuffers.mediaTime(pts)) }
        result.withLock { result in
            if status != noErr {
                result.error = status
            } else if let frame, !flags.contains(.frameDropped) {
                result.frames.append(frame)
            }
        }
    }

    /// Every picture in emission order; throws the handler's error if it produced none.
    func pictures() throws -> [PixelBufferFrame] {
        try result.withLock { result in
            if result.frames.isEmpty, result.error != noErr { throw MediaCodecError.sessionFailed(result.error) }
            return result.frames
        }
    }
}
#endif
