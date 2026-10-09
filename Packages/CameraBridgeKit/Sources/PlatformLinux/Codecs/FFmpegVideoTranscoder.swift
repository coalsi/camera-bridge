import BridgeSupport
import Foundation
import MediaCore
import Synchronization

/// Decode (H.264/HEVC) → limit frame rate → scale → timestamp overlay → encode H.264, in **one** ffmpeg child process.
///
/// Compressed pictures go into ffmpeg's stdin as FLV (the engine's 90 kHz PTS kept in a table, ffmpeg sees milliseconds),
/// encoded pictures come back as FLV on stdout. `transcode` never waits for the child: it writes the frame and returns whatever
/// the child has produced so far, so output lags the input by the pipeline's latency (a few milliseconds when warm).
///
/// Controls (ffmpeg takes none at run time, so each is one of these tricks):
/// - **Keyframe request**: the next picture is written with an odd millisecond timestamp, which `-force_key_frames` turns into an IDR.
/// - **Bit rate**: a change of 10 % or more restarts the child (at the earliest 2 s after it started); the new one is fed the GOP
///   since the last source keyframe and skips every picture but the newest (`select`), so the output continues with an IDR of "now".
///   Bit rate updates are rare (the controller reports congestion), a restart costs a few hundred milliseconds.
/// - **Catch-up** (`catchUp`): the same restart, on the frames the caller hands over.
/// - **Overlay**: `drawtext` re-reads a text file for every picture; the words are rewritten when they change. A change of the
///   overlay's position, size or presence restarts the child like a bit rate change.
/// - **Frame-rate limit**: a `select` expression with the rule of `FrameRateLimiter`.
///
/// Delta frames before the first keyframe are dropped. A parameter-set change on a keyframe starts a new child. A child that
/// dies surfaces as a thrown `MediaCodecError` (ffmpeg's last stderr lines in the message) and the transcoder starts a new one at
/// the next keyframe, so a caller that goes on gets video again; `invalidate()` (and `deinit`) kill the child.
final class FFmpegVideoTranscoder: VideoTranscoding, @unchecked Sendable {
    /// The part of the overlay that is in the filter graph; a change restarts the child.
    struct OverlayKey: Equatable {
        var position: OverlayPosition
        var size: OverlaySize
    }

    /// One ffmpeg child and the bookkeeping that belongs to it.
    private final class Run: @unchecked Sendable {
        let session: FFmpegSession
        var stream: VideoFLVStream
        var output: H264FLVOutput
        let spec: VideoPipelineSpec
        let sourceFormat: VideoFormat
        let overlayKey: OverlayKey?
        let startedAt = ContinuousClock.now
        var produced = 0

        init(session: FFmpegSession, stream: VideoFLVStream, spec: VideoPipelineSpec, sourceFormat: VideoFormat, overlayKey: OverlayKey?) {
            self.session = session
            self.stream = stream
            self.spec = spec
            self.sourceFormat = sourceFormat
            self.overlayKey = overlayKey
            output = H264FLVOutput(width: spec.settings.width, height: spec.settings.height)
        }

        deinit { session.terminate() }

        /// Everything the child has produced so far, as engine frames.
        func collect() -> [EncodedVideoFrame] {
            let packets = output.push(session.drain())
            guard let format = output.format else { return [] }
            return packets.map { packet in
                let record = stream.claim(ptsMs: packet.ptsMs)
                produced += 1
                return EncodedVideoFrame(format: format, nalUnits: packet.nalUnits, isKeyframe: packet.isKeyframe,
                                         pts: record?.pts ?? stream.fallbackTime(ptsMs: packet.ptsMs), dts: nil,
                                         wallClock: record?.wallClock ?? Date())
            }
        }
    }

    private struct State {
        var run: Run?
        /// The source frames since the last source keyframe (decode order), for a restart; empty and incomplete when too large.
        var gop: [EncodedVideoFrame] = []
        var gopBytes = 0
        var gopComplete = false
        var awaitingKeyframe = true
        var backend: FFmpegVideoBackend
        var scratch: OverlayScratch?
        /// The scratch directory for the overlay's text could not be made: no overlay (said once), and no restarts over it.
        var overlayUnavailable = false
        var lastKeyframeBytes: Int?
        var lastKeyframeSize: (width: Int, height: Int)?
    }

    /// Source frames kept for restarts: more than this and the restart waits for the next source keyframe.
    static let maximumGOPBytes = 24 << 20
    static let maximumGOPFrames = 1_500
    /// A bit rate change smaller than this fraction does not restart the child, and none within `minimumRunTime` (2 s) of a start.
    static let bitrateTolerance = 0.10
    static let defaultMinimumRunTime = Duration.seconds(2)
    /// How long `catchUp` waits for the first encoded picture.
    static let catchUpTimeout = Duration.seconds(8)

    private let runtime: FFmpegRuntime
    private let settings: VideoEncoderSettings
    private let overlay: (any TimestampOverlayProviding)?
    private let minimumRunTime: Duration
    private let state: Mutex<State>
    private let keyframeRequested = Atomic<Bool>(false)
    private let invalidatedFlag = Atomic<Bool>(false)
    private let requestedBitrate: Atomic<Int>
    private let live = Mutex<FFmpegSession?>(nil)
    private let log = Log(category: "VideoTranscoder")

    init(runtime: FFmpegRuntime, output: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)?, minimumRunTime: Duration = FFmpegVideoTranscoder.defaultMinimumRunTime) throws {
        guard output.width > 0, output.height > 0, output.fps > 0, output.bitrateKbps > 0 else {
            throw MediaCodecError.unsupported("encoder settings \(output.width)×\(output.height) @ \(output.fps) fps, \(output.bitrateKbps) kbit/s")
        }
        // The encoders need even sizes (4:2:0).
        var settings = output
        settings.width &= ~1
        settings.height &= ~1
        guard settings.width > 0, settings.height > 0 else {
            throw MediaCodecError.unsupported("encoder settings \(output.width)×\(output.height)")
        }
        _ = try runtime.requireExecutable()
        self.runtime = runtime
        self.settings = settings
        self.overlay = overlay
        self.minimumRunTime = minimumRunTime
        requestedBitrate = Atomic(settings.bitrateKbps)
        state = Mutex(State(backend: try runtime.videoBackend()))
    }

    deinit { invalidate() }

    // MARK: VideoTranscoding

    func transcode(_ frame: EncodedVideoFrame) async throws -> [EncodedVideoFrame] {
        try state.withLock { state in
            let frames = try process(frame, state: &state)
            noteKeyframes(frames, state: &state)
            return frames
        }
    }

    func catchUp(_ frames: [EncodedVideoFrame]) async throws -> [EncodedVideoFrame] {
        guard let start = frames.lastIndex(where: \.isKeyframe) else { return [] }
        let replay = Array(frames[start...])
        var collected = try state.withLock { state -> [EncodedVideoFrame] in
            guard !invalidatedFlag.load(ordering: .relaxed) else { return [] }
            _ = keyframeRequested.exchange(false, ordering: .relaxed)
            _ = endRun(&state)   // what an earlier run still held is older than the picture the caller asked for
            state.gop = []
            state.gopBytes = 0
            state.gopComplete = true
            state.awaitingKeyframe = false
            try beginRun(replay, skipBefore: replay.max { $0.pts < $1.pts }?.pts, state: &state)
            rememberGOP(replay, state: &state)
            let first = state.run?.collect() ?? []
            noteKeyframes(first, state: &state)
            return first
        }
        let deadline = ContinuousClock.now + Self.catchUpTimeout
        while collected.isEmpty {
            guard ContinuousClock.now < deadline else {
                throw MediaCodecError.unsupported("ffmpeg (video transcoder) produced no picture within \(Self.catchUpTimeout / .seconds(1)) s of the catch-up")
            }
            guard let session = state.withLock({ $0.run?.session }) else { break }
            await session.waitForOutputAsync(timeout: .milliseconds(50))
            try Task.checkCancellation()
            collected = try state.withLock { state -> [EncodedVideoFrame] in
                guard let run = state.run else { return [] }
                let frames = run.collect()
                if frames.isEmpty, run.session.exit != nil, run.session.bufferedOutputBytes == 0 {
                    let failure = run.session.failure
                    handleEnd(of: run, state: &state)
                    throw failure
                }
                noteKeyframes(frames, state: &state)
                return frames
            }
        }
        return collected
    }

    func requestKeyframe() {
        keyframeRequested.store(true, ordering: .relaxed)
    }

    func updateBitrate(kbps: Int) {
        guard kbps > 0 else { return }
        requestedBitrate.store(kbps, ordering: .relaxed)
    }

    func invalidate() {
        // Never waits for a transcode in progress: the session is reachable without the state lock.
        invalidatedFlag.store(true, ordering: .relaxed)
        live.withLock { session in
            session?.terminate()
            session = nil
        }
        state.withLockIfAvailable { state in
            state.run = nil
            state.scratch?.remove()
            state.scratch = nil
        }
    }

    /// The pictures the child has produced since the last call, without writing anything (tests wait for the tail of a stream with it;
    /// the engine's next `transcode` collects the same pictures).
    func collectAvailable() -> [EncodedVideoFrame] {
        state.withLock { state in
            let frames = state.run?.collect() ?? []
            noteKeyframes(frames, state: &state)
            return frames
        }
    }

    var diagnostics: TranscoderDiagnostics {
        var diagnostics = TranscoderDiagnostics()
        let (backend, bytes, size) = state.withLock { ($0.backend, $0.lastKeyframeBytes, $0.lastKeyframeSize) }
        diagnostics.decoderIsHardware = false
        diagnostics.encoderIsHardware = backend.isHardware
        diagnostics.lastKeyframeBytes = bytes
        diagnostics.lastKeyframeWidth = size?.width
        diagnostics.lastKeyframeHeight = size?.height
        return diagnostics
    }

    // MARK: Processing

    private func process(_ frame: EncodedVideoFrame, state: inout State) throws -> [EncodedVideoFrame] {
        guard !invalidatedFlag.load(ordering: .relaxed) else { return [] }
        var output: [EncodedVideoFrame] = []

        if let run = state.run {
            let ended = run.session.exit != nil
            if ended {
                output = run.collect()
                let failure = run.session.failure
                let fast = ContinuousClock.now - run.startedAt < .seconds(5)
                let produced = run.produced
                handleEnd(of: run, state: &state)
                if output.isEmpty || (produced == 0 && fast) { throw failure }
                log.warning("the video transcoder's ffmpeg ended (\(failure)); starting a new one at the next keyframe")
            } else if !Self.sameStream(run.sourceFormat, frame.format) {
                if frame.isKeyframe {
                    output = endRun(&state)
                    state.gop = []
                    state.gopComplete = false
                } else {
                    state.awaitingKeyframe = true
                }
            }
        }

        if state.awaitingKeyframe || state.run == nil {
            guard frame.isKeyframe else { return output }
            state.awaitingKeyframe = false
            output += endRun(&state)
            state.gop = []
            state.gopBytes = 0
            state.gopComplete = true
            _ = keyframeRequested.exchange(false, ordering: .relaxed)
            try beginRun([frame], skipBefore: nil, state: &state)
            rememberGOP([frame], state: &state)
            return output + (state.run?.collect() ?? [])
        }

        if frame.isKeyframe {
            state.gop = []
            state.gopBytes = 0
            state.gopComplete = true
        }
        // A restart for a new bit rate or overlay layout, with the GOP so far as the replay (a keyframe needs none).
        if let run = state.run, wantsRestart(run, state: state), frame.isKeyframe || state.gopComplete {
            let replay = frame.isKeyframe ? [frame] : state.gop + [frame]
            output += endRun(&state)
            _ = keyframeRequested.exchange(false, ordering: .relaxed)
            try beginRun(replay, skipBefore: frame.isKeyframe ? nil : frame.pts, state: &state)
            rememberGOP([frame], state: &state)
            return output + (state.run?.collect() ?? [])
        }

        guard let run = state.run else { return output }
        rememberGOP([frame], state: &state)
        updateOverlay(for: frame, state: state)
        let request = keyframeRequested.exchange(false, ordering: .relaxed)
        do {
            try Self.write(frame, to: run, requestKeyframe: request)
        } catch {
            if request { keyframeRequested.store(true, ordering: .relaxed) }
            output += run.collect()
            let failure = run.session.exit != nil ? run.session.failure : (error as? MediaCodecError) ?? .unsupported("\(error)")
            handleEnd(of: run, state: &state)
            if output.isEmpty { throw failure }
            return output
        }
        return output + run.collect()
    }

    private func rememberGOP(_ frames: [EncodedVideoFrame], state: inout State) {
        for frame in frames {
            guard state.gopComplete else { continue }
            let bytes = frame.nalUnits.reduce(0) { $0 + $1.count }
            state.gop.append(frame)
            state.gopBytes += bytes
            if state.gopBytes > Self.maximumGOPBytes || state.gop.count > Self.maximumGOPFrames {
                state.gop = []
                state.gopBytes = 0
                state.gopComplete = false
            }
        }
    }

    private static func sameStream(_ a: VideoFormat, _ b: VideoFormat) -> Bool {
        guard a.codec == b.codec, a.width == b.width, a.height == b.height else { return false }
        // Further parameter sets (a second PPS) are the same stream; the SPS (HEVC: VPS and SPS) must match.
        let significant = a.codec == .hevc ? 2 : 1
        return Array(a.parameterSets.prefix(significant)) == Array(b.parameterSets.prefix(significant))
    }

    private func currentOverlay() -> TimestampOverlay? {
        guard let current = overlay?.current, current.settings.enabled else { return nil }
        return current
    }

    private func overlayKey(state: State) -> OverlayKey? {
        guard let current = currentOverlay(), !state.overlayUnavailable, runtime.overlayFont() != nil else { return nil }
        return OverlayKey(position: current.settings.position, size: current.settings.size)
    }

    private func wantsRestart(_ run: Run, state: State) -> Bool {
        if overlayKey(state: state) != run.overlayKey { return true }
        let wanted = requestedBitrate.load(ordering: .relaxed)
        let applied = run.spec.bitrateKbps
        guard ContinuousClock.now - run.startedAt >= minimumRunTime else { return false }
        return Double(abs(wanted - applied)) >= Double(applied) * Self.bitrateTolerance
    }

    private func updateOverlay(for frame: EncodedVideoFrame, state: State) {
        guard let scratch = state.scratch, let current = currentOverlay() else { return }
        scratch.update(overlayLine(current.text(for: frame.wallClock)))
    }

    /// Ends the run (collecting what it already produced) and returns those pictures.
    private func endRun(_ state: inout State) -> [EncodedVideoFrame] {
        guard let run = state.run else { return [] }
        let frames = run.collect()
        run.session.terminate()
        live.withLock { $0 = nil }
        state.run = nil
        return frames
    }

    /// The child ended by itself: forget it, and wait for a keyframe to start another.
    private func handleEnd(of run: Run, state: inout State) {
        if run.produced == 0, run.spec.backend.isHardware {
            runtime.disableVAAPI(reason: run.session.exit?.summary ?? "no output")
            state.backend = (try? runtime.videoBackend()) ?? state.backend
        }
        run.session.terminate()
        live.withLock { $0 = nil }
        state.run = nil
        state.awaitingKeyframe = true
    }

    private func noteKeyframes(_ frames: [EncodedVideoFrame], state: inout State) {
        if let keyframe = frames.last(where: \.isKeyframe) {
            state.lastKeyframeBytes = keyframe.nalUnits.reduce(0) { $0 + $1.count }
            state.lastKeyframeSize = (keyframe.format.width, keyframe.format.height)
        }
    }

    // MARK: Starting a child

    private func beginRun(_ frames: [EncodedVideoFrame], skipBefore: MediaTime?, state: inout State) throws {
        guard let first = frames.first else { return }
        let executable = try runtime.requireExecutable()
        let sourceFormat = first.format
        var stream = VideoFLVStream(format: sourceFormat)
        guard let header = stream.header else {
            throw MediaCodecError.unsupported("the stream's parameter sets cannot be described to ffmpeg (\(sourceFormat.codec.rawValue), \(sourceFormat.parameterSets.count) sets)")
        }
        // Overlay: the text file exists before ffmpeg starts.
        var overlayKey: OverlayKey?
        var drawText: DrawTextOverlay?
        if let current = currentOverlay(), let font = runtime.overlayFont() {
            if state.scratch == nil, !state.overlayUnavailable {
                do {
                    state.scratch = try OverlayScratch(parent: runtime.configuration.scratchDirectory)
                } catch {
                    state.overlayUnavailable = true
                    log.warning("the timestamp overlay cannot be drawn: no scratch directory for its text (\(error.localizedDescription))")
                }
            }
            if let scratch = state.scratch, FFmpegArguments.isUsablePath(scratch.textFile.path) {
                scratch.update(overlayLine(current.text(for: first.wallClock)))
                overlayKey = OverlayKey(position: current.settings.position, size: current.settings.size)
                drawText = DrawTextOverlay(fontFile: font, textFile: scratch.textFile.path, position: current.settings.position, size: current.settings.size)
            }
        }
        // The frames' tags first: the catch-up threshold is the newest picture's millisecond.
        var tags: [Data] = []
        var skipMs: Int64?
        for frame in frames {
            let (data, ptsMs) = stream.tag(for: frame, requestKeyframe: false)
            tags.append(data)
            if let skipBefore, frame.pts == skipBefore { skipMs = ptsMs }
        }
        var spec = VideoPipelineSpec(settings: settings, bitrateKbps: requestedBitrate.load(ordering: .relaxed), backend: state.backend,
                                     sourceWidth: sourceFormat.width, sourceHeight: sourceFormat.height, overlay: drawText)
        // Half a millisecond before the newest picture's timestamp, so rounding never skips it.
        spec.skipBeforeSeconds = skipMs.map { (Double($0) - 0.5) / 1000 }
        let arguments = FFmpegArguments.transcoder(spec)
        let process = FFmpegProcessSpec(executable: executable, arguments: arguments, label: "video transcoder")
        let session = try FFmpegSession(launcher: runtime.launcher, spec: process)
        let run = Run(session: session, stream: stream, spec: spec, sourceFormat: sourceFormat, overlayKey: overlayKey)
        do {
            try session.send(header)
            for tag in tags { try session.send(tag) }
        } catch {
            let ended = session.exit
            let failure = ended != nil ? session.failure : error
            if let ended, spec.backend.isHardware {
                // The hardware encoder did not even start: the next child encodes in software.
                runtime.disableVAAPI(reason: ended.summary)
                state.backend = (try? runtime.videoBackend()) ?? state.backend
            }
            session.terminate()
            throw failure
        }
        state.run = run
        live.withLock { $0 = session }
        log.info("ffmpeg video transcoder started: \(sourceFormat.codec.rawValue) \(sourceFormat.width)×\(sourceFormat.height) → H.264 "
                 + "\(settings.width)×\(settings.height) @ \(settings.fps) fps, \(spec.bitrateKbps) kbit/s, \(spec.backend.description)"
                 + (drawText == nil ? "" : ", timestamp overlay") + (skipMs == nil ? "" : ", caught up on \(frames.count) frames"))
    }

    private static func write(_ frame: EncodedVideoFrame, to run: Run, requestKeyframe: Bool) throws {
        let (data, _) = run.stream.tag(for: frame, requestKeyframe: requestKeyframe)
        try run.session.send(data)
    }
}
