#if os(macOS)
import BridgeSupport
import Foundation
import MediaCore
import Synchronization

/// Decode (H.264/HEVC) → scale → encode H.264 with the output settings, keeping each picture's PTS and wall clock.
///
/// Decoded pictures are encoded in presentation order: the decoder emits them in decode order, which B-frames make
/// differ, so `PresentationOrder` holds them back as deep as the stream reorders (none for a stream that does not).
/// Every picture is encoded unless the output frame rate is lower than the input's: pictures are then skipped so the
/// output keeps at most `fps` per second of PTS (`FrameRateLimiter`), and a requested keyframe is never skipped. Delta
/// frames are skipped until the first keyframe (and again after a parameter-set change that is not just further sets,
/// or a decode error on a delta frame, which is logged instead of thrown). A decode error on a keyframe and encoder errors are thrown. The async
/// `transcode` runs on the transcoder's own serial queue; `requestKeyframe()` and `updateBitrate(kbps:)` never wait for
/// a transcode in progress.
final class AppleVideoTranscoder: VideoTranscoding {
    /// A decoded picture waiting for its turn, with its wall clock.
    private struct Picture {
        var frame: PixelBufferFrame
        var wallClock: Date
    }

    private struct State {
        var decoder: AppleVideoDecoder?
        var awaitingKeyframe = true
        var limiter: FrameRateLimiter
        var order = PresentationOrder<Picture>()
        var loggedLateDrop = false
        /// A delta frame decoded since the last keyframe.
        var deltaDecodedInGOP = false
        /// Keyframes in a row whose first delta frame failed.
        var failedGOPs = 0
        var loggedSoftwareFailure = false
        /// Keyframes in a row the decoder failed on.
        var failedKeyframes = 0
        /// Decoders are made without the hardware one (`preferSoftwareDecoding`).
        var preferSoftware = false
        /// An input picture's statistics, sampled about once a second.
        var inputPicture: PictureStatistics?
        var lastInputSample: ContinuousClock.Instant?
        /// Smoothed time per picture of a `transcode` call (ms), the calls it is made of, and whether "too slow" was logged.
        var millisecondsPerCall: Double?
        var timedCalls = 0
        var loggedSlow = false
    }

    /// Keyframes in a row after which no delta frame decoded: the hardware decoder is replaced by the software one.
    static let failedGOPsBeforeSoftware = 2
    /// Keyframes in a row the decoder failed on, after which it is replaced by the software one.
    static let failedKeyframesBeforeSoftware = 2
    /// Calls before the per-picture time says anything, and how much slower than the input's frame interval it may be.
    static let timedCallsBeforeVerdict = 60
    static let slowFactor = 1.3

    private let encoder: AppleVideoEncoder
    private let state: Mutex<State>
    private let keyframeRequested = Atomic<Bool>(false)
    private let work = CodecWorkQueue(label: "CameraBridge.VideoTranscoder")
    private let log = Log(category: "VideoTranscoder")

    init(output: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)? = nil) throws {
        encoder = try AppleVideoEncoder(settings: output, codec: .h264, overlay: overlay)
        state = Mutex(State(limiter: FrameRateLimiter(fps: output.fps)))
    }

    func transcode(_ frame: EncodedVideoFrame) async throws -> [EncodedVideoFrame] {
        try await work.run { try self.transcodeNow(frame) }
    }

    func transcodeNow(_ frame: EncodedVideoFrame) throws -> [EncodedVideoFrame] {
        let begun = ContinuousClock.now
        return try state.withLock { state in
            let due = try decode(frame, state: &state)
            var output: [EncodedVideoFrame] = []
            for picture in due {
                let time = picture.frame.pts.seconds
                guard keyframeRequested.load(ordering: .relaxed) || state.limiter.shouldEncode(time) else { continue }
                let force = keyframeRequested.exchange(false, ordering: .relaxed)
                state.limiter.didEncode(time)
                do {
                    output += try encoder.encodeNow(picture.frame, wallClock: picture.wallClock, forceKeyframe: force)
                } catch {
                    // A request that did not reach the encoder is still wanted.
                    if force { keyframeRequested.store(true, ordering: .relaxed) }
                    throw error
                }
            }
            if !due.isEmpty { noteTiming(since: begun, pictures: due.count, state: &state) }
            return output
        }
    }

    /// Keeps the smoothed per-picture time and says once when it is too slow for the input's frame rate.
    private func noteTiming(since begun: ContinuousClock.Instant, pictures: Int, state: inout State) {
        let milliseconds = Double((ContinuousClock.now - begun) / .microseconds(1)) / 1000 / Double(max(1, pictures))
        state.millisecondsPerCall = state.millisecondsPerCall.map { $0 * 0.9 + milliseconds * 0.1 } ?? milliseconds
        state.timedCalls += 1
        let interval = 1000 / Double(max(1, encoder.settings.inputFrameRate))
        guard state.timedCalls >= Self.timedCallsBeforeVerdict, !state.loggedSlow, let average = state.millisecondsPerCall,
              average > interval * Self.slowFactor else { return }
        state.loggedSlow = true
        let kinds = codecKinds(state: state)
        log.warning("live video transcoding takes \(String(format: "%.0f", average)) ms per picture, more than the \(String(format: "%.0f", interval)) ms a "
                    + "\(encoder.settings.inputFrameRate) fps picture allows (\(kinds.isEmpty ? "codecs unknown" : kinds)): the live view will lag; "
                    + "the Mac's video hardware may be busy with other streams")
    }

    private func codecKinds(state: State) -> String {
        var diagnostics = TranscoderDiagnostics()
        diagnostics.decoderIsHardware = state.decoder?.isHardware
        diagnostics.encoderIsHardware = encoder.diagnostics.isHardware
        return diagnostics.codecDescription
    }

    func catchUp(_ frames: [EncodedVideoFrame]) async throws -> [EncodedVideoFrame] {
        try await work.run { try self.catchUpNow(frames) }
    }

    /// Decodes every frame and encodes only the newest picture, as a keyframe.
    func catchUpNow(_ frames: [EncodedVideoFrame]) throws -> [EncodedVideoFrame] {
        try state.withLock { state in
            var newest: Picture?
            for frame in frames {
                for picture in try decode(frame, state: &state) where newest.map({ picture.frame.pts.seconds >= $0.frame.pts.seconds }) ?? true {
                    newest = picture
                }
            }
            // Pictures still held back for presentation order are the newest ones.
            for picture in state.order.restart() where newest.map({ picture.frame.pts.seconds >= $0.frame.pts.seconds }) ?? true {
                newest = picture
            }
            guard let newest else { return [] }
            _ = keyframeRequested.exchange(false, ordering: .relaxed)
            state.limiter.didEncode(newest.frame.pts.seconds)
            return try encoder.encodeNow(newest.frame, wallClock: newest.wallClock, forceKeyframe: true)
        }
    }

    /// Decodes `frame`; returns the pictures due for encoding (presentation order), none while waiting for a keyframe.
    private func decode(_ frame: EncodedVideoFrame, state: inout State) throws -> [Picture] {
        if let decoder = state.decoder, decoder.format.codec != frame.format.codec || decoder.format.parameterSets != frame.format.parameterSets,
           !frame.isKeyframe {
            if frame.format.extends(decoder.format) {
                // The same stream with further parameter sets (a second PPS sent in front of a P picture): what is held
                // stays valid, the decoder takes the new description and goes on.
                log.info("decoder: further parameter sets arrived with a delta frame (\(AppleVideoDecoder.describe(decoder.format)) -> "
                         + "\(AppleVideoDecoder.describe(frame.format))); decoding goes on")
            } else {
                // New stream parameters: wait for its keyframe.
                log.info("decoder: the stream's parameter sets changed on a delta frame (\(AppleVideoDecoder.describe(decoder.format)) -> "
                         + "\(AppleVideoDecoder.describe(frame.format))); waiting for the next keyframe")
                state.awaitingKeyframe = true
            }
        }
        if state.awaitingKeyframe {
            guard frame.isKeyframe else { return [] }
            state.awaitingKeyframe = false
        }
        let decoder: AppleVideoDecoder
        if let existing = state.decoder {
            decoder = existing
        } else {
            decoder = try AppleVideoDecoder(format: frame.format)
            if state.preferSoftware { decoder.useSoftwareDecoding(reason: "the pipeline asked for software decoding") }
            state.decoder = decoder
        }
        let pictures: [PixelBufferFrame]
        do {
            pictures = try decoder.decodeAllNow(frame)
        } catch where frame.isKeyframe {
            // The hardware decoder may be rejecting a keyframe a software decoder accepts: after two in a row the next
            // session is a software one (delta frame failures reach the same fallback through `failedGOPs`).
            state.failedKeyframes += 1
            log.warning("the decoder failed on a keyframe (\(error); decoding \(AppleVideoDecoder.describe(decoder.format)), "
                        + "\(state.failedKeyframes) in a row)")
            decoder.resetSession(reason: "after a keyframe it failed on (\(error))")
            state.awaitingKeyframe = true
            if state.failedKeyframes >= Self.failedKeyframesBeforeSoftware { fallBackToSoftware(decoder, state: &state, error: error, what: "keyframes") }
            throw error
        } catch where !frame.isKeyframe {
            log.warning("dropping undecodable delta frame (\(error)); waiting for the next keyframe "
                        + "(decoding \(AppleVideoDecoder.describe(decoder.format)))")
            state.awaitingKeyframe = true
            decoder.resetSession(reason: "after a delta frame it failed on (\(error)); a fresh session starts at the next keyframe")
            if !state.deltaDecodedInGOP {
                state.failedGOPs += 1
                if state.failedGOPs >= Self.failedGOPsBeforeSoftware { fallBackToSoftware(decoder, state: &state, error: error) }
            }
            return []
        }
        if frame.isKeyframe {
            state.deltaDecodedInGOP = false
            state.failedKeyframes = 0
        } else {
            state.deltaDecodedInGOP = true
            state.failedGOPs = 0
        }
        // Nothing decoded after a keyframe is presented before what was decoded ahead of it.
        var due = frame.isKeyframe ? state.order.restart() : []
        if let dts = frame.dts, dts != frame.pts { state.order.noteReordering() }
        if let first = pictures.first, state.lastInputSample.map({ ContinuousClock.now - $0 >= .seconds(1) }) ?? true {
            state.lastInputSample = .now
            state.inputPicture = first.pictureStatistics()
        }
        for picture in pictures {
            let wallClock = frame.wallClock.addingTimeInterval(picture.pts.seconds - frame.pts.seconds)
            due += state.order.push(Picture(frame: picture, wallClock: wallClock), time: picture.pts.seconds)
        }
        if state.order.droppedCount > 0, !state.loggedLateDrop {
            state.loggedLateDrop = true
            log.notice("the source reorders frames (B-frames) without saying so: dropped pictures presented before one already encoded; "
                       + "holding \(state.order.depth) pictures from now on")
        }
        return due
    }

    /// No delta frame decoded after the last `failedGOPsBeforeSoftware` keyframes: the hardware decoder may be rejecting a
    /// stream a software decoder accepts, so the next keyframe starts a software session. If that fails the same way, the
    /// stream itself is at fault (say so once; decoding goes on trying).
    private func fallBackToSoftware(_ decoder: AppleVideoDecoder, state: inout State, error: any Error, what: String = "delta frames") {
        state.failedGOPs = 0
        state.failedKeyframes = 0
        if decoder.isSoftware {
            guard !state.loggedSoftwareFailure else { return }
            state.loggedSoftwareFailure = true
            log.warning("the software decoder rejects the \(what) of \(AppleVideoDecoder.describe(decoder.format)) too (\(error)): "
                        + "the stream's parameter sets or pictures are at fault, not the hardware decoder")
        } else if what == "keyframes" {
            decoder.useSoftwareDecoding(reason: "the decoder failed on \(Self.failedKeyframesBeforeSoftware) keyframes in a row (\(error))")
        } else {
            decoder.useSoftwareDecoding(reason: "no delta frame decoded after \(Self.failedGOPsBeforeSoftware) keyframes in a row (\(error))")
        }
    }

    func preferSoftwareDecoding() {
        state.withLock { state in
            state.preferSoftware = true
            state.decoder?.useSoftwareDecoding(reason: "the pipeline asked for software decoding")
        }
    }

    /// The next `count` encodes fail (tests).
    func injectEncoderFailures(_ count: Int) { encoder.injectFailures(count) }

    /// The decoder was replaced by the software one (tests, diagnostics).
    var decoderIsSoftware: Bool { state.withLock { $0.decoder?.isSoftware ?? false } }

    var diagnostics: TranscoderDiagnostics {
        var diagnostics = TranscoderDiagnostics()
        let (decoderIsHardware, input, milliseconds) = state.withLock { state in (state.decoder?.isHardware, state.inputPicture, state.millisecondsPerCall) }
        let encoded = encoder.diagnostics
        diagnostics.decoderIsHardware = decoderIsHardware
        diagnostics.encoderIsHardware = encoded.isHardware
        diagnostics.inputPicture = input
        diagnostics.lastKeyframeBytes = encoded.keyframeBytes
        diagnostics.lastKeyframeWidth = encoded.keyframeWidth
        diagnostics.lastKeyframeHeight = encoded.keyframeHeight
        diagnostics.millisecondsPerPicture = milliseconds
        return diagnostics
    }

    func requestKeyframe() {
        keyframeRequested.store(true, ordering: .relaxed)
    }

    func updateBitrate(kbps: Int) {
        encoder.updateBitrate(kbps: kbps)
    }

    func invalidate() {
        let decoder = state.withLock { state -> AppleVideoDecoder? in
            defer { state.decoder = nil }
            return state.decoder
        }
        decoder?.invalidate()
        encoder.invalidate()
    }
}

/// Output frame-rate decimation on presentation times (seconds).
///
/// Pictures are due every 1/fps; one is encoded once its time reaches the due time less a quarter interval (jitter),
/// and the next due time advances by exactly one interval, so a 30 fps input at 15 fps keeps every other picture and
/// an input at or below `fps` keeps all. A time far from the schedule (a gap, or more than 1 s backwards: a new
/// timeline) restarts it at that picture.
struct FrameRateLimiter {
    let interval: Double
    private var due: Double?

    init(fps: Int) {
        interval = 1 / Double(max(1, fps))
    }

    func shouldEncode(_ time: Double) -> Bool {
        guard let due else { return true }
        return time >= due - interval / 4 || time < due - interval - 1
    }

    mutating func didEncode(_ time: Double) {
        if let due, time >= due - interval, time < due + interval {
            self.due = due + interval
        } else {
            due = time + interval
        }
    }
}

/// Puts decoded pictures (pushed in decode order) back into presentation order (times in seconds).
///
/// With B-frames a picture is presented before pictures decoded ahead of it, so pictures are held until `depth` later
/// ones arrived and released earliest presentation time first. `depth` starts at 0: a stream that does not reorder is
/// never held. A source that marks reordering (`noteReordering()`: a decode time other than the presentation time, as
/// FLV and the RTSP ingest give B-frames) holds at least `fallbackDepth` pictures, enough for the one to three B-frames
/// cameras send. Reordering seen in the presentation times themselves (how many of the last pictures pushed are
/// presented after the new one; at most `maximumDepth`, the H.264/H.265 decoded picture buffer) deepens it, and a
/// picture presented before one already released is dropped (`droppedCount`): sending it would step back. `restart()`
/// releases everything held; a keyframe calls for it (no picture decoded after it is presented before a picture
/// decoded ahead of it). A time more than `newTimeline` before the newest one (a reconnected source) restarts the same
/// way. The depth only grows.
struct PresentationOrder<Element> {
    static var fallbackDepth: Int { 4 }
    static var maximumDepth: Int { 16 }
    /// Seconds back that start a new timeline (as `FrameRateLimiter` and the encoder see it).
    static var newTimeline: Double { 1 }

    private(set) var depth = 0
    private(set) var droppedCount = 0
    /// Held pictures, earliest presentation time first.
    private var held: [(time: Double, element: Element)] = []
    /// Presentation times of the last pictures pushed, in decode order.
    private var recent: [Double] = []
    private var lastReleased: Double?

    /// The source says it reorders: hold at least `fallbackDepth` pictures.
    mutating func noteReordering() {
        depth = max(depth, Self.fallbackDepth)
    }

    /// Adds the next picture in decode order, presented at `time`; returns the pictures now due, in presentation order.
    mutating func push(_ element: Element, time: Double) -> [Element] {
        guard time.isFinite else { return restart() + [element] }
        var released: [Element] = []
        let newest = max(recent.max() ?? -.infinity, lastReleased ?? -.infinity)
        if time < newest - Self.newTimeline { released = restart() }
        let presentedLater = recent.count { $0 > time }
        depth = max(depth, min(presentedLater, Self.maximumDepth))
        recent.append(time)
        if recent.count > Self.maximumDepth + 1 { recent.removeFirst(recent.count - Self.maximumDepth - 1) }
        if let lastReleased, time < lastReleased {
            droppedCount += 1
            return released
        }
        let index = held.firstIndex { $0.time > time } ?? held.endIndex
        held.insert((time, element), at: index)
        while held.count > depth {
            let next = held.removeFirst()
            lastReleased = next.time
            released.append(next.element)
        }
        return released
    }

    /// Releases every held picture (presentation order) and forgets the timeline; the depth stays.
    mutating func restart() -> [Element] {
        defer {
            held.removeAll()
            recent.removeAll()
            lastReleased = nil
        }
        return held.map(\.element)
    }
}
#endif
