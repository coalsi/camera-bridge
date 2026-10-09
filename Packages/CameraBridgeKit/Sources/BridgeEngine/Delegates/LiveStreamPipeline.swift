import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import MediaCore
import RTP
import Synchronization

/// A media hub a live stream reads from. `release()` ends this stream's use of it (an on-demand sub stream stops
/// once nobody uses it).
struct HubLease: Sendable {
    let hub: MediaHub
    let isSubStream: Bool
    let release: @Sendable () async -> Void
    /// What the hub's ingest learned about the stream (B-frames).
    var traits = StreamTraits()
}

/// The hub for a live request: the sub stream when `preferSubStream` and the camera has one, else the main stream.
typealias HubProvider = @Sendable (_ preferSubStream: Bool) async -> HubLease

/// Sockets and SSRCs reserved by `prepareStream`, owned by the session once it starts.
struct PreparedStream: Sendable {
    var request: PrepareStreamRequest
    var videoSocket: UDPSocket
    var audioSocket: UDPSocket
    var videoSSRC: UInt32
    var audioSSRC: UInt32
    /// When `prepareStream` answered (diagnostics: prepare → start delay).
    var preparedAt = ContinuousClock.now
    /// The session's phases for the diagnostics bundle (`DiagnosticsCenter`).
    var trace: SessionTrace?
    /// The controller's SetupEndpoints address when the stream goes elsewhere (`request.controllerAddress` is where it
    /// goes; `StreamAddress.controllerRoute`).
    var advertisedControllerAddress: String?

    func close() {
        videoSocket.close()
        audioSocket.close()
    }
}

/// The pipeline's video output to the session: a GOP-aware bounded queue (`GOPQueue`) that also keeps what the health check
/// needs (when the last frame and the last keyframe went out) and hands the self-check its samples. A queue that overflows
/// (the session fell behind) loses its oldest GOP and asks for a keyframe, so what the controller decodes after the gap starts
/// on one.
final class LiveFrameOutput: Sendable {
    private struct Stats {
        var frames = 0
        var keyframes = 0
        var lastFrame: ContinuousClock.Instant?
        var lastKeyframe: ContinuousClock.Instant?
        var lastKeyframeBytes = 0
    }

    let stream: AsyncStream<EncodedVideoFrame>
    private let queue: GOPQueue<EncodedVideoFrame>
    private let stats = Mutex(Stats())
    private let plan: Mutex<LiveSelfCheckPlan>
    private let skippingToKeyframe = Mutex(false)
    private let probes: Bool
    private let probingAllowed = Mutex(true)
    private let onOverflow: @Sendable (_ dropped: Int) -> Void
    private let onSample: @Sendable ([EncodedVideoFrame]) -> Bool

    /// `capacity` frames queued at most (120: four seconds at 30 fps). `onSample`: a complete self-check sample (when `probes`).
    init(capacity: Int = 120, timing: LiveStreamTiming, probes: Bool, onOverflow: @escaping @Sendable (Int) -> Void,
         onSample: @escaping @Sendable ([EncodedVideoFrame]) -> Bool) {
        queue = GOPQueue(capacity: capacity, isKeyframe: { $0.isKeyframe })
        stream = queue.makeStream()
        plan = Mutex(LiveSelfCheckPlan(count: timing.probeCount, interval: timing.probeInterval))
        self.probes = probes
        self.onOverflow = onOverflow
        self.onSample = onSample
    }

    func yield(_ frame: EncodedVideoFrame) {
        if skippingToKeyframe.withLock({ $0 }) {
            guard frame.isKeyframe else { return }
            skippingToKeyframe.withLock { $0 = false }
        }
        let push = queue.push(frame)
        if push.awaitingKeyframe { skippingToKeyframe.withLock { $0 = true } }
        if push.overflowed { onOverflow(push.dropped) }
        guard push.queued else { return }
        let now = ContinuousClock.now
        stats.withLock { stats in
            stats.frames += 1
            stats.lastFrame = now
            if frame.isKeyframe {
                stats.keyframes += 1
                stats.lastKeyframe = now
                stats.lastKeyframeBytes = frame.nalUnits.reduce(0) { $0 + $1.count }
            }
        }
        if probes, probingAllowed.withLock({ $0 }), let sample = plan.withLock({ $0.offer(frame, at: now) }), !onSample(sample) {
            plan.withLock { $0.declined() }   // the probe slot was busy: this sample does not count
        }
    }

    func finish() {
        queue.finish()
    }

    /// The frames that follow come from another transcoder or path: a self-check sample in the making is dropped.
    func restartSampling() {
        plan.withLock { $0.restart() }
    }

    /// Whether the self-check may take samples (not of a picture too large to decode a copy of: `LiveSelfCheck.maximumPixels`).
    func allowProbing(width: Int, height: Int) {
        probingAllowed.withLock { $0 = width * height <= LiveSelfCheck.maximumPixels }
    }

    var frames: Int { stats.withLock { $0.frames } }
    var keyframes: Int { stats.withLock { $0.keyframes } }
    var lastKeyframeBytes: Int { stats.withLock { $0.lastKeyframeBytes } }
    func sinceKeyframe(_ now: ContinuousClock.Instant = .now) -> Duration? { stats.withLock { $0.lastKeyframe.map { now - $0 } } }
}

/// One live stream (plan W3-1 item 3, research brief §3.6, integration brief §5.4): a `MediaHub` subscription
/// (`.nextKeyframe`, preceded by the hub's last keyframe so the picture appears as soon as the controller listens: the
/// first frame waits up to `Context.controllerWait` for the controller's first packet, its RTCP) → `TimelineRebaser` →
/// passthrough when the H.264 source fits the request (`MediaFit.live`), else `VideoTranscoding` (Main, requested size,
/// frame rate and bit rate, keyframe every 2 s) → `LiveStreamSession` (SRTP to the controller). The path is chosen again
/// at a source keyframe whose format (codec, size, profile, level) differs from the one it was chosen for (a camera that
/// reconnected with other settings). Camera audio → `AudioTranscoding` → Opus at the requested sample rate →
/// `OpusRepacketizer` (requested packet time). PLI/FIR → `controllerAskedForKeyframe()`: a keyframe from the transcoder; a
/// passthrough stream asks the camera for one, and switches to transcoding when the controller asks twice in 10 s.
/// `reconfigure` changes the transcoder's bit rate, and for a new resolution rebuilds the path at once from the hub's newest
/// GOP (a transcoder made then gets the new bit rate). Return audio → the camera's shared `TalkbackBridge` when two-way audio is on.
///
/// Nothing fails silently (audit 2 F1-F9). A transcoder that cannot be made is retried with a backoff, never replaced by a
/// passthrough that would not fit; one that fails is rebuilt (`TranscodeFailureLadder`); one that does not answer within
/// `LiveStreamTiming.transcodeDeadline` is abandoned. A health check every second (`LiveStreamHealth`) forces a keyframe and
/// rebuilds the transcoder when no video went out although the camera delivers, and ends the stream when that does not help,
/// and a self-check (`LiveSelfCheck`) decodes samples of the outgoing stream. A stream the pipeline ends goes through
/// `LiveStreamSession.stop()`: `StreamingHandler` then ends the HomeKit session, so Home sees the stream available and retries.
final class LiveStreamPipeline: Sendable {
    struct Context: Sendable {
        var codecs: any MediaCodecs
        var cameraAudioEnabled: Bool
        /// nil: no two-way audio.
        var talkback: (@Sendable () -> (any TalkbackSink)?)?
        var controllerTimeout: Duration
        /// How long the first video waits for the controller's first packet (integration brief §5.4: up to 1 s).
        var controllerWait: Duration = .seconds(1)
        var log: Log
        /// `CameraConfiguration.liveQualityMode` (`MediaFit.live`).
        var qualityMode: LiveQualityMode = .matchHomeKitRequest
        /// The camera's timestamp overlay (nil: none). While it is on every picture is transcoded and drawn on.
        var overlay: TimestampOverlayControl?
        /// The health ladder's and the failure ladders' timings.
        var timing = LiveStreamTiming.standard
        /// Asks the camera for a fresh keyframe (ONVIF SetSynchronizationPoint, Hikvision requestKeyFrame) for the main stream
        /// (`isSubStream` false) or the sub stream, through the camera adapters' own guarded call: once per need, no retry, nothing
        /// when the camera refused its login. nil: the camera cannot be asked.
        var cameraKeyframe: (@Sendable (_ isSubStream: Bool) async -> Void)?
        /// The sub stream's picture size when the camera has one and it is known (`MediaFit.prefersSubStream`: a request the sub
        /// stream's picture already covers reads the sub stream instead of decoding the main stream's 8 MP). `StreamingHandler`
        /// asks it once per start, before it picks the stream.
        var subStreamSize: (@Sendable () async -> VideoResolution?)?
        /// The self-check decodes samples of the outgoing stream (tests that feed deliberately broken frames switch it off).
        var selfCheck = true
    }

    /// The `cameraKeyframe` closure for `driver` (`CameraDriver.requestKeyframe`): nothing is sent while `isOffline`, a camera that has
    /// no such call is left alone, and any other refusal (a rejected login included: the adapter pauses the camera's logins itself)
    /// is one line at info level, never retried here.
    static func cameraKeyframeRequest(driver: any CameraDriver, isOffline: @escaping @Sendable () -> Bool = { false },
                                      log: Log) -> @Sendable (_ isSubStream: Bool) async -> Void {
        { isSubStream in
            guard !isOffline() else { return }
            do {
                try await driver.requestKeyframe(subStream: isSubStream)
            } catch CameraAdapterError.unsupported {
                log.debug("The camera has no keyframe request")
            } catch is CancellationError {
                return
            } catch {
                log.info("The camera did not take the keyframe request (\(URLFreeErrors.describe(error))); it is not asked again for this one")
            }
        }
    }

    /// What a path decision depends on in the source's format (not its parameter-set bytes).
    struct FormatKey: Equatable, Sendable {
        var codec: VideoCodec
        var width: Int
        var height: Int
        var profile: UInt8
        var level: UInt8

        init(_ format: VideoFormat) {
            codec = format.codec
            width = format.width
            height = format.height
            profile = format.profile
            level = format.level
        }
    }

    /// A rebuild the pump carries out before its next frame (from `reconfigure`, the health check or the self-check).
    private struct RebuildRequest {
        var reason: String
        /// Decide the path again (a new resolution); else only the transcoder is made again.
        var redecide: Bool
        var software: Bool
    }

    private struct VideoControl {
        var requested: SelectedVideoParameters
        var transcoder: (any VideoTranscoding)?
        var path: VideoPath?
        /// The source format the path was chosen for.
        var decidedFor: FormatKey?
        /// Choose the path again at the next source keyframe (new resolution).
        var redecide = false
        /// Why the next path decision transcodes although the source would pass through (passthrough did not work out).
        var forceTranscode: String?
        /// Make the next transcoder decode in software.
        var softwareDecoding = false
        var rebuild: RebuildRequest?
        /// The settings the transcoder was made with.
        var settings: VideoEncoderSettings?
    }

    private struct Tasks {
        var pump: Task<Void, Never>?
        var keyframes: Task<Void, Never>?
        var watcher: Task<Void, Never>?
        var health: Task<Void, Never>?
        var returnAudio: Task<Void, Never>?
        var subscription: MediaSubscription?
        var stopped = false
    }

    /// What the pump keeps between frames.
    private struct PumpState {
        var rebaser = TimelineRebaser()
        var failures: TranscodeFailureLadder
        /// Live frames at or before this presentation time were part of the replay a transcoder was rebuilt from.
        var skipUntil: Double?
    }

    let sessionID: UUID
    /// Where the stream goes: the controller's address (scoped when link-local: `StreamAddress.controllerHost`), or the HAP
    /// connection's when the advertised one is on no network of ours (`StreamAddress.controllerRoute`).
    let controllerHost: String
    /// What the controller advertised in SetupEndpoints, when that is not where the stream goes.
    let advertisedHost: String?
    private let session: LiveStreamSession
    private let audio: SelectedAudioParameters?
    private let lease: HubLease
    private let context: Context
    private let talkback: TalkbackBridge?
    private let control: Mutex<VideoControl>
    private let tasks = Mutex(Tasks())
    private let preparedAt: ContinuousClock.Instant
    private let sessionTrace: SessionTrace?
    private let controllerVideoPort: UInt16
    private let startedAtBox = Mutex(ContinuousClock.now)
    private let packetSize: Int
    private let output: LiveFrameOutput
    /// Why the pipeline ended the stream, once it did.
    private let endedByPipeline = Mutex<String?>(nil)
    private let healthState: Mutex<LiveStreamHealth>
    /// Self-check verdicts the health check has not seen yet, and whether one passed already (the first is logged at info).
    private let probeOutcomes = Mutex<[LiveSelfCheck.Outcome]>([])
    private let loggedProbePass = Mutex(false)
    private let loggedProbeInconclusive = Mutex(false)
    /// When the controller last asked for a keyframe (PLI/FIR) while this stream passes through.
    private let passthroughKeyframeRequests = Mutex<[ContinuousClock.Instant]>([])
    private let cameraKeyframeLimit: RateLimiter
    private let outputOverflowLog = RateLimiter(interval: .seconds(10))
    private let loggedStarvedKeyframe = Mutex(false)

    /// When `start()` began.
    private var startedAt: ContinuousClock.Instant {
        get { startedAtBox.withLock { $0 } }
        set { startedAtBox.withLock { $0 = newValue } }
    }

    /// `talkback`: the camera's shared two-way audio bridge (nil: none).
    init(sessionID: UUID, prepared: PreparedStream, video: SelectedVideoParameters, audio: SelectedAudioParameters?, lease: HubLease,
         context: Context, talkback: TalkbackBridge? = nil) {
        self.sessionID = sessionID
        let request = prepared.request
        let size = Self.packetSize(mtu: video.mtu)
        let videoParameters = LiveVideoParameters(payloadType: video.payloadType, ssrc: prepared.videoSSRC, srtpKey: request.videoSRTP.masterKey,
                                                  srtpSalt: request.videoSRTP.masterSalt, maxPacketSize: size,
                                                  rtcpInterval: Self.rtcpInterval(video.rtcpIntervalSeconds))
        let usableAudio = audio.flatMap { $0.codec == .opus ? $0 : nil }
        let audioParameters = usableAudio.map {
            LiveAudioParameters(codec: .opus, payloadType: $0.payloadType, ssrc: prepared.audioSSRC, srtpKey: request.audioSRTP.masterKey,
                                srtpSalt: request.audioSRTP.masterSalt, rtpClockRate: $0.sampleRate.hertz, packetTime: .milliseconds(max(10, $0.packetTimeMs)),
                                rtcpInterval: Self.rtcpInterval($0.rtcpIntervalSeconds))
        }
        controllerHost = request.controllerAddress
        advertisedHost = prepared.advertisedControllerAddress.flatMap {
            StreamAddress.canonical($0) == StreamAddress.canonical(request.controllerAddress) ? nil : $0
        }
        preparedAt = prepared.preparedAt
        controllerVideoPort = request.controllerVideoPort
        session = LiveStreamSession(controller: SocketAddress(host: request.controllerAddress, port: request.controllerVideoPort),
                                    videoPort: request.controllerVideoPort, audioPort: request.controllerAudioPort, videoSocket: prepared.videoSocket,
                                    audioSocket: prepared.audioSocket, video: videoParameters, audio: audioParameters,
                                    controllerTimeout: context.controllerTimeout, trace: prepared.trace, advertisedController: advertisedHost)
        sessionTrace = prepared.trace
        self.audio = usableAudio
        self.lease = lease
        self.context = context
        self.talkback = talkback
        packetSize = size
        cameraKeyframeLimit = RateLimiter(interval: context.timing.cameraKeyframeSpacing)
        control = Mutex(VideoControl(requested: video))
        healthState = Mutex(LiveStreamHealth(timing: context.timing))
        let overflowLog = outputOverflowLog
        let log = context.log
        let selfCheck = context.selfCheck
        let sessionLabel = String(sessionID.uuidString.prefix(8))
        // The output's callbacks reach back into the pipeline once it exists (they only run after `start()`).
        let callbacks = OutputCallbacks()
        output = LiveFrameOutput(timing: context.timing, probes: selfCheck, onOverflow: { dropped in
            if overflowLog.allow() {
                log.warning("Live stream [\(sessionLabel)]: the session fell behind: dropped \(dropped) queued video frames (its oldest GOP); asking for a keyframe")
            }
            callbacks.overflow()
        }, onSample: { frames in callbacks.sample(frames) })
        self.callbacks = callbacks
    }

    /// Weak links from the output's callbacks to the pipeline (set once `start()` runs).
    private final class OutputCallbacks: Sendable {
        let pipeline = Mutex<WeakPipeline?>(nil)
        func overflow() { pipeline.withLock { $0?.value }?.outputOverflowed() }
        func sample(_ frames: [EncodedVideoFrame]) -> Bool { pipeline.withLock { $0?.value }?.probe(frames) ?? false }
    }

    private struct WeakPipeline: Sendable {
        weak var value: LiveStreamPipeline?
    }

    private let callbacks: OutputCallbacks

    /// Always ≤ 1200 bytes on the wire (integration brief §5.4), smaller when the controller's MTU is.
    static func packetSize(mtu: Int) -> Int {
        max(300, min(1200, mtu > 0 ? mtu : 1200))
    }

    /// The hub's last keyframe opens the stream although it arrived `age` seconds ago: it is stamped as captured now
    /// (moved forward by its age, at most `limit` — a GOP), so the frames from the next keyframe on follow it by as much
    /// media time as passes between them. Receivers anchor playout on the first frame; its capture time would hold every
    /// later frame back by its age. The age is measured on the hub's monotonic clock from the keyframe's arrival, never
    /// from its `wallClock` (for RTSP the camera's own clock, which may run seconds off the Mac's). A negative or unknown
    /// age moves nothing.
    static func restampedFirstFrame(_ frame: EncodedVideoFrame, age: TimeInterval, limit: TimeInterval) -> EncodedVideoFrame {
        guard age.isFinite, age > 0, limit.isFinite, limit > 0 else { return frame }
        let shift = min(age, limit)
        var moved = frame
        moved.pts = frame.pts + .seconds(shift, timescale: frame.pts.timescale)
        moved.dts = frame.dts.map { $0 + .seconds(shift, timescale: $0.timescale) }
        return moved
    }

    static func rtcpInterval(_ seconds: Double) -> Duration {
        guard seconds.isFinite, seconds > 0 else { return .milliseconds(500) }
        return .milliseconds(Int((min(max(seconds, 0.1), 5) * 1000).rounded()))
    }

    /// The chosen video path once the first frame was seen.
    var videoPath: VideoPath? { control.withLock { $0.path } }

    var isTranscoding: Bool { control.withLock { $0.transcoder != nil } }

    /// Why the pipeline ended this stream (the health check, a failing transcoder, the self-check), nil while it runs on.
    var endedByPipelineReason: String? { endedByPipeline.withLock { $0 } }

    /// "ok", "recovering: ...", "ended: ..." (`LiveStreamHealth.summary`): shown with the session's status.
    var healthSummary: String { healthState.withLock { $0.summary } }

    /// The source's resolution once a path has been decided (output resolution for a transcode, the camera's own
    /// picture size for passthrough), nil before the first decision (`CameraStatus`).
    var currentResolution: VideoResolution? {
        control.withLock { control in
            guard let key = control.decidedFor else { return nil }
            return control.transcoder != nil ? control.requested.resolution : VideoResolution(key.width, key.height, control.requested.resolution.fps)
        }
    }

    /// What HomeKit asked for (an approximation of the output bit rate: exact for a transcode, a ceiling for
    /// passthrough), nil before the controller selected a configuration.
    var currentBitrateKbps: Int? { control.withLock { $0.requested.maxBitrateKbps } }

    /// The session reads the camera's sub stream.
    var usesSubStream: Bool { lease.isSubStream }

    func start() async {
        startedAt = .now
        callbacks.pipeline.withLock { $0 = WeakPipeline(value: self) }
        var audioStream: AsyncStream<EncodedAudioFrame>?
        var audioContinuation: AsyncStream<EncodedAudioFrame>.Continuation?
        if audio != nil {
            let (stream, continuation) = AsyncStream.makeStream(of: EncodedAudioFrame.self, bufferingPolicy: .bufferingNewest(100))
            audioStream = stream
            audioContinuation = continuation
        }
        guard !tasks.withLock({ $0.stopped }) else { return }
        await session.start(video: output.stream, audio: audioStream)
        let pump = Task { [self] in
            await run(audio: audioContinuation)
        }
        let watcher = Task { [self] in await watchController() }
        let keyframes = Task { [self] in
            for await _ in session.keyframeRequests { controllerAskedForKeyframe() }
        }
        let health = Task { [self] in await healthLoop() }
        var returnAudio: Task<Void, Never>?
        if let talkback {
            // Never cancelled: it ends with the session's return audio (`stop()`). A cancellation would reach the camera-
            // facing send under way and break the sink every session shares. (The camera-facing open runs on its own:
            // `send` never holds this loop on it, so what the viewer says meanwhile is dropped, not played late.)
            returnAudio = Task { [self, session, sessionID] in
                for await frame in session.returnAudio {
                    if self.tasks.withLock({ $0.stopped }) { break }
                    await talkback.send(frame, from: sessionID)
                }
            }
        }
        let stoppedMeanwhile = tasks.withLock { tasks -> Bool in
            tasks.pump = pump
            tasks.watcher = watcher
            tasks.keyframes = keyframes
            tasks.health = health
            tasks.returnAudio = returnAudio
            return tasks.stopped
        }
        if stoppedMeanwhile {   // stop() ran while starting and could not see these tasks
            pump.cancel()
            watcher.cancel()
            keyframes.cancel()
            health.cancel()
            // returnAudio ends with the session's return audio (stop() stopped the session)
            return
        }
        context.log.info("Live stream started: \(describe(control.withLock { $0.requested }))\(lease.isSubStream ? " from the sub stream" : "")"
                         + (audio.map { ", Opus \($0.sampleRate.hertz) Hz / \($0.packetTimeMs) ms" } ?? ""))
        self.sessionTrace?.mark("start", describe(control.withLock { $0.requested }) + (lease.isSubStream ? ", sub stream" : ", main stream"))
        trace("start: \(Self.ms(ContinuousClock.now - startedAt)) after the start request began, \(Self.ms(ContinuousClock.now - preparedAt)) after prepare, "
              + "payload type \(control.withLock { $0.requested.payloadType }), MTU \(control.withLock { $0.requested.mtu }), "
              + "controller \(controllerHost)\(advertisedHost.map { " (advertised \($0))" } ?? "") video port \(controllerVideoPort)")
    }

    /// The bit rate applies at once. A new size rebuilds the path at once from the hub's newest GOP (the next frame the pump
    /// takes), not at the camera's next keyframe, which a long GOP puts seconds away: controllers lower size and bit rate
    /// together under congestion, when the lower rate matters most.
    func reconfigure(_ video: SelectedVideoParameters) {
        let (transcoder, resized) = control.withLock { control -> ((any VideoTranscoding)?, Bool) in
            let resized = control.requested.resolution != video.resolution
            if resized {
                control.redecide = true
                if control.path != nil { control.rebuild = RebuildRequest(reason: "the controller asked for \(video.resolution.width)×\(video.resolution.height)", redecide: true,
                                                 software: false) }
            }
            control.requested = video
            return (control.transcoder, resized)
        }
        transcoder?.updateBitrate(kbps: max(50, video.maxBitrateKbps))
        context.log.info("Live stream reconfigured: \(describe(video))" + (resized ? "; the picture is rebuilt from the camera's newest GOP at once" : ""))
    }

    /// A keyframe from the transcoder (a passthrough stream waits for the camera's next one).
    func requestKeyframe() {
        guard let transcoder = control.withLock({ $0.transcoder }) else { return }
        transcoder.requestKeyframe()
    }

    /// PLI/FIR from the controller. A transcoder makes a keyframe at once. A passthrough stream cannot: it asks the camera for
    /// one, and when the controller asks twice within `passthroughKeyframeWindow` the camera's keyframe interval is too long
    /// for it, so the stream switches to transcoding from the hub's newest GOP (audit 2 F6).
    func controllerAskedForKeyframe() {
        if let transcoder = control.withLock({ $0.transcoder }) {
            transcoder.requestKeyframe()
            return
        }
        let timing = context.timing
        let now = ContinuousClock.now
        let asks = passthroughKeyframeRequests.withLock { asks -> Int in
            asks.append(now)
            asks.removeAll { now - $0 > timing.passthroughKeyframeWindow }
            return asks.count
        }
        askCameraForKeyframe("the controller asked for a keyframe while the stream passes the camera's own through")
        guard asks >= timing.passthroughKeyframeRequests else { return }
        let switching = control.withLock { control -> Bool in
            guard control.path == .passthrough, control.forceTranscode == nil, control.rebuild == nil else { return false }
            control.forceTranscode = "the controller asked for a keyframe \(asks) times in \(LiveStreamHealth.seconds(timing.passthroughKeyframeWindow)) s "
                + "and the camera's own keyframes are too far apart"
            control.rebuild = RebuildRequest(reason: "switching to transcoding", redecide: true, software: false)
            return true
        }
        if switching {
            context.log.warning("Live stream [\(sessionID.uuidString.prefix(8))]: the controller asked for a keyframe \(asks) times in "
                                + "\(LiveStreamHealth.seconds(timing.passthroughKeyframeWindow)) s; the camera's keyframes come too rarely for passthrough, "
                                + "switching to transcoding")
        }
    }

    /// Ends the session, releases the hub and the transcoder, then this session's use of talkback (the camera-facing
    /// close is bounded by `TalkbackBridge`); returns once the sockets are closed. Idempotent.
    func stop() async {
        let current = tasks.withLock { tasks -> Tasks? in
            guard !tasks.stopped else { return nil }
            tasks.stopped = true
            return tasks
        }
        guard let current else { return }
        await session.stop()
        current.pump?.cancel()
        current.watcher?.cancel()
        current.keyframes?.cancel()
        current.health?.cancel()
        // current.returnAudio is not cancelled: it ends with the session's return audio (see `start()`)
        current.subscription?.cancel()
        let transcoder = control.withLock { control -> (any VideoTranscoding)? in
            defer { control.transcoder = nil }
            return control.transcoder
        }
        // Tearing a VideoToolbox session down can block for as long as a call inside it does: never on a cooperative thread.
        if let transcoder { CodecOffload.fireAndForget { transcoder.invalidate() } }
        output.finish()
        await lease.release()
        await talkback?.release(sessionID)
        _ = await session.waitForEnd()
    }

    func waitForEnd() async -> LiveStreamEndReason {
        await session.waitForEnd()
    }

    /// What waiting for the controller's first packet (its RTCP) came to.
    enum ControllerVerdict: Sendable, Equatable {
        /// The controller answered: video reaches it.
        case heard
        /// `timeout` passed in silence while the session ran.
        case silent
        /// The session ended before either (the viewer left): no verdict.
        case endedFirst
    }

    /// Waits up to `timeout` for the controller's first packet (`NetworkNotice.Delivery`).
    func awaitController(timeout: Duration) async -> ControllerVerdict {
        if await session.waitForController(timeout: timeout) { return .heard }
        return await session.hasEnded ? .endedFirst : .silent
    }

    // MARK: - Pump

    private struct AudioState {
        var converter: (any AudioTranscoding)?
        var input: AudioFormat?
        var failed = false
        var repacketizer: OpusRepacketizer
    }

    private var isEnded: Bool { endedByPipeline.withLock { $0 != nil } }

    private func run(audio audioOut: AsyncStream<EncodedAudioFrame>.Continuation?) async {
        // A passthrough stream waits for the controller's first packet (its RTCP: it listens; a keyframe sent earlier may be
        // lost) BEFORE it takes the hub's newest GOP: frames queued meanwhile would reach it in one burst, and its playout
        // would trail the camera by the wait for good (the receiver anchors on the first frame). A transcoder does not wait:
        // it sends a fresh keyframe once the controller is heard (`watchController`).
        if context.controllerWait > .zero, await passthroughLikely() {
            let begun = ContinuousClock.now
            let waited = await session.waitForController(timeout: context.controllerWait)
            trace("passthrough waited \(Self.ms(ContinuousClock.now - begun)) for the controller's first packet (\(waited ? "heard" : "not heard"))")
        }
        if Task.isCancelled { return }
        // The newest GOP is replayed (a keyframe and what followed it) and the stream goes on live from there, so the first
        // picture is "now", not the camera's next keyframe, which a long GOP puts seconds or minutes away. The queue holds the
        // replay on top of the live samples that arrive while it is decoded: ten seconds of them.
        let fps = await lease.hub.measuredFrameRate ?? 30
        let subscription = await lease.hub.subscribe(from: .prebuffer(.zero), bufferLimit: max(300, Int(fps * 10)))
        let subscribed = tasks.withLock { tasks -> Bool in
            guard !tasks.stopped else { return false }
            tasks.subscription = subscription
            return true
        }
        guard subscribed else {
            subscription.cancel()
            return
        }
        var state = PumpState(failures: TranscodeFailureLadder(timing: context.timing))
        var audioState = audio.map { AudioState(repacketizer: OpusRepacketizer(packetTime: .milliseconds(max(10, $0.packetTimeMs)))) }
        var iterator = subscription.samples.makeAsyncIterator()
        // The replay (the newest GOP: a keyframe and what followed) was queued before the subscription returned; audio in it
        // is stale and dropped.
        var replay: [EncodedVideoFrame] = []
        var taken = 0
        while taken < subscription.replayCount, let sample = await iterator.next() {
            taken += 1
            if case .video(let frame) = sample { replay.append(frame) }
        }
        if Task.isCancelled { return }
        if replay.isEmpty {
            trace("no GOP held by the hub yet: waiting for the camera's next keyframe")
        } else {
            await startWithReplay(replay, state: &state, rebuilt: false)
        }
        while let sample = await iterator.next() {
            if Task.isCancelled || isEnded { break }
            switch sample {
            case .video(let frame):
                await forward(frame, state: &state)
            case .audio(let frame):
                guard let audioOut, var audio = audioState, context.cameraAudioEnabled else { continue }
                for packet in convert(state.rebaser.audio(frame), state: &audio) { audioOut.yield(packet) }
                audioState = audio
            }
        }
        output.finish()
        audioOut?.finish()
    }

    /// Replay burst limits for passthrough: more than this and the transcoder (which sends one keyframe of "now") is used.
    static let maximumPassthroughReplayBytes = 400_000
    static let maximumPassthroughReplayFrames = 90
    /// Replayed passthrough frames are spread this far apart on the RTP timeline (a fast-forward of the catch-up GOP), so
    /// the receiver does not hold the live picture back by the GOP's age.
    static let replaySpacing = 1.0 / 120

    /// Opens the stream (or, after a rebuild, restarts it) with the newest GOP: transcoding decodes all of it and encodes one
    /// keyframe of the newest picture (a long source GOP costs decode time, not seconds of waiting); passthrough sends it all,
    /// compressed in time, when it is small, and the first keyframe alone otherwise (never reached: `decide` transcodes a large
    /// replay instead). `rebuilt`: `replay` comes from the hub again (a rebuild), and is put on the timeline the live frames
    /// are on without moving the rebaser, which has already seen them.
    private func startWithReplay(_ replay: [EncodedVideoFrame], state: inout PumpState, rebuilt: Bool) async {
        let begun = ContinuousClock.now
        let frames = replay.map { rebuilt ? state.rebaser.shifted($0) : state.rebaser.video($0, arrival: .now) }
        let bytes = replay.reduce(0) { $0 + $1.nalUnits.reduce(0) { $0 + $1.count } }
        let span = (frames.last?.pts.seconds ?? 0) - (frames.first?.pts.seconds ?? 0)
        trace("replay of the newest GOP: \(frames.count) frames, \(bytes) bytes, \(String(format: "%.1f", span)) s of video")
        if frames.count > context.timing.longGOPFrames || span > context.timing.longGOP.timeInterval {
            askCameraForKeyframe("the camera's newest GOP is long (\(frames.count) frames, \(String(format: "%.1f", span)) s)")
        }
        await decide(for: frames[0], replay: (frames.count, bytes))
        if isEnded { return }
        if let transcoder = control.withLock({ $0.transcoder }) {
            do {
                let encoded = try await withDeadline(context.timing.catchUpDeadline) { try await transcoder.catchUp(frames) }
                self.sessionTrace?.mark("encoder ready", "\(frames.count) frames caught up")
                trace("encoder ready: caught up on \(frames.count) frames and encoded a keyframe in \(Self.ms(ContinuousClock.now - begun)) "
                      + "(\(encoded.count) frame(s) out, \(encoded.reduce(0) { $0 + $1.nalUnits.reduce(0) { $0 + $1.count } }) bytes)")
                for frame in encoded { output.yield(frame) }
                // Not `state.failures.succeeded`: a transcoder that decodes a GOP and then fails on every live frame must
                // still run out of chances.
                if rebuilt { state.skipUntil = frames.last?.pts.seconds }
            } catch is CancellationError {
                return
            } catch {
                // Not a stream to give up on: the next frames decide again with a fresh transcoder (and the failure ladder
                // there ends one that keeps failing).
                context.log.warning("Live transcoding could not start from the newest GOP (\(error)); building a new transcoder and waiting for the "
                                    + "camera's next keyframe")
                abandonTranscoder()
            }
            return
        }
        if Task.isCancelled { return }
        let keyframeOnly = bytes > Self.maximumPassthroughReplayBytes || frames.count > Self.maximumPassthroughReplayFrames
        for frame in Self.compressedReplay(keyframeOnly ? Array(frames.prefix(1)) : frames, spacing: Self.replaySpacing) { output.yield(frame) }
        if rebuilt { state.skipUntil = frames.last?.pts.seconds }
    }

    /// `frames` (decode order, no reordering) with presentation times pulled together towards the last one: no two replayed
    /// frames are further apart than `spacing` seconds, the last keeps its time, so live frames follow it naturally.
    static func compressedReplay(_ frames: [EncodedVideoFrame], spacing: Double) -> [EncodedVideoFrame] {
        guard frames.count > 1, let last = frames.last, spacing > 0 else { return frames }
        return frames.enumerated().map { index, frame in
            let behind = Double(frames.count - 1 - index) * spacing
            let natural = (last.pts - frame.pts).seconds
            guard natural > behind else { return frame }
            var moved = frame
            moved.pts = last.pts - .seconds(behind, timescale: last.pts.timescale)
            moved.dts = frame.dts.map { _ in moved.pts }
            return moved
        }
    }

    /// The hub's newest GOP right now (a keyframe and what followed it), empty before it holds one.
    private func newestGOP() async -> [EncodedVideoFrame] {
        await lease.hub.newestGOP()
    }

    /// Whether the camera's stream would pass through as it is now (decided on the hub's newest keyframe; false before there is one).
    private func passthroughLikely() async -> Bool {
        guard let keyframe = await lease.hub.lastKeyframe else { return false }
        let fps = await lease.hub.measuredFrameRate
        let (requested, forced) = control.withLock { ($0.requested, $0.forceTranscode) }
        guard forced == nil else { return false }
        return MediaFit.live(source: keyframe.format, frameRate: fps, bFrames: lease.traits.usesBFrames, requested: requested,
                             qualityMode: context.qualityMode, timestampOverlay: context.overlay?.isEnabled ?? false) == .passthrough
    }

    /// Waits for the controller's first packet: once heard, an encoder-made keyframe goes out again (the first one may have
    /// reached it before it listened); silence for seconds asks for keyframes too and is logged, so a bundle shows it.
    private func watchController() async {
        let begun = ContinuousClock.now
        for wait in [2.0, 3.0] {
            if await session.waitForController(timeout: .seconds(wait)) {
                // Heard only after video went out: the first keyframe may have reached it before it listened.
                let timeline = await session.timeline
                if let video = timeline.firstVideoPacket, let heard = timeline.firstControllerPacket, heard > video {
                    trace("controller heard \(Self.ms(ContinuousClock.now - begun)) after the start, after the first video; asking for a fresh keyframe")
                    requestKeyframe()
                } else {
                    trace("controller heard \(Self.ms(ContinuousClock.now - begun)) after the start")
                }
                return
            }
            if Task.isCancelled { return }
            trace("no packet from the controller \(Self.ms(ContinuousClock.now - begun)) after the start; asking for a keyframe")
            requestKeyframe()
        }
        context.log.warning("Live stream to \(controllerHost)\(advertisedHost.map { " (the controller advertised \($0))" } ?? ""): the controller sent nothing for \(Self.ms(ContinuousClock.now - begun)) after the start; "
                            + "it is probably not receiving or decoding our video (check the Mac's firewall and Local Network access)")
    }

    private func trace(_ message: String) {
        context.log.info("live stream trace [\(sessionID.uuidString.prefix(8))]: \(message)")
    }

    static func ms(_ duration: Duration) -> String {
        "\(Int((duration / .milliseconds(1)).rounded())) ms"
    }

    /// Passes or transcodes one source frame onto the session's video stream.
    private func forward(_ source: EncodedVideoFrame, state: inout PumpState) async {
        let frame = state.rebaser.video(source, arrival: .now)   // live: across a new timeline, RTP time keeps pace with arrival
        if let request = control.withLock({ control -> RebuildRequest? in defer { control.rebuild = nil }; return control.rebuild }) {
            await rebuild(request, state: &state)
            if isEnded { return }
        }
        if let skip = state.skipUntil {
            if frame.pts.seconds <= skip { return }   // part of the replay the transcoder was rebuilt from
            state.skipUntil = nil
        }
        let key = FormatKey(frame.format)
        let needsDecision = control.withLock { $0.path == nil || (frame.isKeyframe && ($0.redecide || $0.decidedFor != key)) }
        if needsDecision { await decide(for: frame) }
        if isEnded { return }
        guard let transcoder = control.withLock({ $0.transcoder }) else {
            guard control.withLock({ $0.path }) != nil else { return }   // the transcoder could not be made yet: the next frame decides again
            output.yield(frame)
            return
        }
        do {
            let encoded = try await withDeadline(context.timing.transcodeDeadline) { try await transcoder.transcode(frame) }
            state.failures.succeeded(at: .now)
            for item in encoded { output.yield(item) }
            noteKeyframeSize(transcoder: transcoder, encoded: encoded)
        } catch is CancellationError {
            return
        } catch let error as DeadlineExceeded {
            context.log.warning("Live stream [\(sessionID.uuidString.prefix(8))]: the video transcoder did not answer within \(LiveStreamHealth.seconds(error.limit)) s "
                                + "(\(transcoder.diagnostics.codecDescription)); abandoning it and building a new one")
            abandonTranscoder()
            await rebuild(RebuildRequest(reason: "the transcoder did not answer", redecide: false, software: false), state: &state)
        } catch {
            let step = state.failures.failed(keyframe: frame.isKeyframe, at: .now, error: "\(error)")
            switch step {
            case .drop:
                if state.failures.isFirstOfIncident {
                    context.log.warning("Live stream [\(sessionID.uuidString.prefix(8))]: video transcoding failed for a frame (\(error)); dropping it")
                }
            case .rebuild(let software):
                context.log.warning("Live stream [\(sessionID.uuidString.prefix(8))]: video transcoding failed again (\(error)); rebuilding the transcoder"
                                    + (software ? " with a software decoder (the failing frame was a keyframe)" : ""))
                abandonTranscoder()
                await rebuild(RebuildRequest(reason: "the transcoder failed (\(error))", redecide: false, software: software), state: &state)
            case .end(let reason):
                await endSession(reason + "; decoder/encoder: \(transcoder.diagnostics.codecDescription)")
            }
        }
    }

    /// Info once when the first keyframe of a detailed picture is small: the first picture then looks blocky for a moment.
    private func noteKeyframeSize(transcoder: any VideoTranscoding, encoded: [EncodedVideoFrame]) {
        guard let keyframe = encoded.first(where: \.isKeyframe), !loggedStarvedKeyframe.withLock({ $0 }) else { return }
        loggedStarvedKeyframe.withLock { $0 = true }
        let bytes = keyframe.nalUnits.reduce(0) { $0 + $1.count }
        let pixels = max(1, keyframe.format.width * keyframe.format.height)
        let bitsPerPixel = Double(bytes * 8) / Double(pixels)
        guard bitsPerPixel < 0.02, transcoder.diagnostics.inputPicture?.isDetailed == true else { return }
        context.log.info("Live stream [\(sessionID.uuidString.prefix(8))]: the first picture is only \(bytes) bytes (\(String(format: "%.3f", bitsPerPixel)) bit per "
                         + "pixel) for a detailed scene at \(control.withLock { $0.requested.maxBitrateKbps }) kbit/s: it looks blocky until the next frames refine it")
    }

    /// Drops the transcoder without waiting for it (it may be wedged): the next decision makes a new one.
    private func abandonTranscoder() {
        let old = control.withLock { control -> (any VideoTranscoding)? in
            defer {
                control.transcoder = nil
                control.path = nil
            }
            return control.transcoder
        }
        if let old { CodecOffload.fireAndForget { old.invalidate() } }
    }

    /// Makes the path again from the hub's newest GOP, at once (`reconfigure`, the health check, the self-check, a failing or
    /// wedged transcoder): the stream does not wait for the camera's next keyframe.
    private func rebuild(_ request: RebuildRequest, state: inout PumpState) async {
        if request.software { control.withLock { $0.softwareDecoding = true } }
        if request.redecide {
            control.withLock { $0.path = nil }   // decide again (a new size, or a switch to transcoding)
        } else {
            abandonTranscoder()
        }
        context.log.info("Live stream [\(sessionID.uuidString.prefix(8))]: rebuilding the video path from the camera's newest GOP (\(request.reason))")
        let replay = await newestGOP()
        if Task.isCancelled || isEnded { return }
        guard !replay.isEmpty else {
            trace("rebuild: the hub holds no GOP yet; the next keyframe restarts the path")
            return
        }
        await startWithReplay(replay, state: &state, rebuilt: true)
    }

    /// `replay`: the newest GOP's frame count and size when this decision opens the stream (a passthrough of a large GOP
    /// would burst it at the controller: transcode instead, which sends one keyframe of "now").
    private func decide(for frame: EncodedVideoFrame, replay: (frames: Int, bytes: Int)? = nil) async {
        let fps = await lease.hub.measuredFrameRate
        let (requested, forced, software) = control.withLock { ($0.requested, $0.forceTranscode, $0.softwareDecoding) }
        let overlayOn = context.overlay?.isEnabled ?? false
        var path = MediaFit.live(source: frame.format, frameRate: fps, bFrames: lease.traits.usesBFrames, requested: requested,
                                 qualityMode: context.qualityMode, timestampOverlay: overlayOn)
        if path == .passthrough, let forced { path = .transcode(forced) }
        if path == .passthrough, let replay, replay.bytes > Self.maximumPassthroughReplayBytes || replay.frames > Self.maximumPassthroughReplayFrames {
            path = .transcode("the camera's current keyframe interval is long (\(replay.frames) frames, \(replay.bytes / 1000) kB since its last keyframe): "
                              + "sending its stream as is would delay the first picture")
        }
        var created: (any VideoTranscoding)?
        var settingsUsed: VideoEncoderSettings?
        if case .transcode(let reason) = path {
            let settings = MediaFit.liveEncoderSettings(for: requested, source: frame.format, sourceFrameRate: fps,
                                                        qualityMode: context.qualityMode, timestampOverlay: overlayOn)
            created = await makeTranscoder(settings: settings, overlay: overlayOn ? context.overlay?.provider(for: lease.hub) : nil, software: software)
            if let created {
                settingsUsed = settings
                context.log.info("Live video transcoded to \(settings.width)×\(settings.height)@\(settings.fps) at \(settings.bitrateKbps) kbit/s (\(reason))"
                                 + (created.diagnostics.codecDescription.isEmpty ? "" : "; \(created.diagnostics.codecDescription)"))
                self.sessionTrace?.setSummary("transcoded \(frame.format.width)×\(frame.format.height) → \(settings.width)×\(settings.height)@\(settings.fps) \(settings.bitrateKbps) kbit/s")
                self.sessionTrace?.mark("path decided", "transcode: \(reason)")
            } else if Task.isCancelled {
                return
            } else if passthroughIsSafe(frame, requested: requested, frameRate: fps, overlayOn: overlayOn) {
                context.log.warning("Live stream [\(sessionID.uuidString.prefix(8))]: the video cannot be transcoded; the camera's stream is sent as it is "
                                    + "(it fits what the controller asked for, and only \"\(reason)\" asked for a transcode)")
                path = .passthrough
            } else {
                await endSession("a video transcoder could not be built after \(context.timing.creationBackoff.count + 1) attempts, and the camera's own "
                                 + "stream does not fit what the controller asked for (\(reason))")
                return
            }
        }
        if created == nil {
            context.log.info("Live video passed through (\(frame.format.width)×\(frame.format.height) H.264)")
            self.sessionTrace?.setSummary("passthrough \(frame.format.width)×\(frame.format.height)")
            self.sessionTrace?.mark("path decided", "passthrough")
        }
        // A reconfigure may have come while the transcoder was being made (the Mutex is not held meanwhile; it sent its bit
        // rate to the transcoder of that moment): a new size decides again, and the new bit rate goes to the transcoder just
        // made (under the lock, so a later reconfigure's rate is never overwritten).
        output.restartSampling()
        if let settingsUsed { output.allowProbing(width: settingsUsed.width, height: settingsUsed.height) } else { output.allowProbing(width: frame.format.width, height: frame.format.height) }
        let replaced = control.withLock { control -> (any VideoTranscoding)? in
            defer {
                control.transcoder = created
                control.path = created == nil ? .passthrough : path
                control.decidedFor = FormatKey(frame.format)
                control.redecide = false
                control.settings = settingsUsed
                if control.requested.resolution != requested.resolution, control.rebuild == nil {
                    control.rebuild = RebuildRequest(reason: "the controller asked for \(control.requested.resolution.width)×\(control.requested.resolution.height) "
                                                     + "while the path was being made", redecide: true, software: false)
                }
            }
            if let created, control.requested.maxBitrateKbps != requested.maxBitrateKbps {
                created.updateBitrate(kbps: max(50, control.requested.maxBitrateKbps))
            }
            return control.transcoder
        }
        if let replaced { CodecOffload.fireAndForget { replaced.invalidate() } }
    }

    /// A transcoder for `settings`, retried after the pauses of `LiveStreamTiming.creationBackoff`; each attempt runs off the
    /// cooperative threads under a deadline. nil after the last attempt.
    private func makeTranscoder(settings: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)?, software: Bool) async -> (any VideoTranscoding)? {
        let pauses = [Duration.zero] + context.timing.creationBackoff
        var lastError: (any Error)?
        for (attempt, pause) in pauses.enumerated() {
            if pause > .zero {
                try? await Task.sleep(for: pause)
                if Task.isCancelled { return nil }
            }
            let codecs = context.codecs
            do {
                let transcoder = try await CodecOffload.run(deadline: context.timing.creationDeadline, discard: { late in late.invalidate() }) {
                    try codecs.makeVideoTranscoder(output: settings, overlay: overlay)
                }
                if software { transcoder.preferSoftwareDecoding() }
                if attempt > 0 { context.log.info("Live video: the transcoder was made on attempt \(attempt + 1)") }
                return transcoder
            } catch is CancellationError {
                return nil
            } catch {
                lastError = error
                let next = attempt + 1 < pauses.count ? "; trying again in \(Self.ms(pauses[attempt + 1]))" : ""
                context.log.warning("Live stream [\(sessionID.uuidString.prefix(8))]: the video transcoder could not be made (\(error))\(next)")
            }
        }
        context.log.error("Live stream [\(sessionID.uuidString.prefix(8))]: the video transcoder could not be made after \(pauses.count) attempts (last error: "
                          + "\(lastError.map { "\($0)" } ?? "none"))")
        return nil
    }

    /// Whether the camera's own stream may stand in for a transcoder that cannot be made: it is H.264, no overlay has to be drawn
    /// on it, and it fits what the controller asked for. Only a "transcode" decided on the length of the camera's GOP can then be
    /// passed through; a size, level, profile or codec the controller cannot take never is.
    private func passthroughIsSafe(_ frame: EncodedVideoFrame, requested: SelectedVideoParameters, frameRate: Double?, overlayOn: Bool) -> Bool {
        guard !overlayOn, frame.format.codec == .h264 else { return false }
        return MediaFit.live(source: frame.format, frameRate: frameRate, bFrames: lease.traits.usesBFrames, requested: requested,
                             qualityMode: context.qualityMode, timestampOverlay: false) == .passthrough
    }

    private func convert(_ frame: EncodedAudioFrame, state: inout AudioState) -> [EncodedAudioFrame] {
        guard let audio, !state.failed else { return [] }
        if state.converter == nil || state.input != frame.format {
            do {
                let bitrate = audio.maxBitrateKbps > 0 ? audio.maxBitrateKbps * 1000 : nil
                state.converter = try context.codecs.makeAudioTranscoder(input: frame.format,
                                                                         output: AudioEncoderSettings(codec: .opus, sampleRate: audio.sampleRate.hertz,
                                                                                                      channels: 1, bitrate: bitrate))
                state.input = frame.format
            } catch {
                state.failed = true
                context.log.warning("Camera audio (\(frame.format.codec.rawValue)) cannot be converted to Opus (\(error)); live view is silent")
                return []
            }
        }
        guard let converter = state.converter else { return [] }
        do {
            return try converter.transcode(frame).flatMap { state.repacketizer.push($0) }
        } catch {
            context.log.debug("Dropping one audio frame: \(error)")
            return []
        }
    }

    private func describe(_ video: SelectedVideoParameters) -> String {
        "\(video.resolution.width)×\(video.resolution.height)@\(video.resolution.fps) \(video.maxBitrateKbps) kbit/s"
    }

    // MARK: - Health

    /// Every `LiveStreamTiming.tick`: what the stream produced, what the camera delivered, and what the self-check found, to
    /// `LiveStreamHealth`, which says what to do (force a keyframe, rebuild the transcoder, end the stream).
    private func healthLoop() async {
        let timing = context.timing
        var lastPackets = 0
        var lastPacketAt: ContinuousClock.Instant?
        while !Task.isCancelled {
            try? await Task.sleep(for: timing.tick)
            if Task.isCancelled || isEnded { return }
            let now = ContinuousClock.now
            let packets = await session.timeline.videoPackets
            if packets != lastPackets {
                lastPackets = packets
                lastPacketAt = now
            }
            let hubArrival = await lease.hub.lastVideoArrival
            let transcoder = control.withLock { $0.transcoder }
            var metrics = LiveStreamMetrics(elapsed: now - startedAt, videoPackets: packets, sinceVideoPacket: lastPacketAt.map { now - $0 },
                                            hubAge: hubArrival.map { now - $0 }, transcoding: transcoder != nil, sinceKeyframeOut: output.sinceKeyframe(now),
                                            hubFrameRate: await lease.hub.measuredFrameRate)
            metrics.codecs = transcoder?.diagnostics.codecDescription ?? ""
            var actions = healthState.withLock { $0.evaluate(metrics) }
            for outcome in probeOutcomes.withLock({ outcomes in defer { outcomes.removeAll() }; return outcomes }) {
                actions += healthState.withLock { $0.noteProbe(outcome) }
            }
            for action in actions { await perform(action) }
        }
    }

    private func perform(_ action: LiveStreamHealth.Action) async {
        let label = "Live stream [\(sessionID.uuidString.prefix(8))]"
        switch action {
        case .info(let text):
            context.log.info("\(label): \(text)")
        case .warning(let text):
            context.log.warning("\(label): \(text)")
        case .forceKeyframe:
            if control.withLock({ $0.transcoder }) != nil {
                requestKeyframe()
            } else {
                askCameraForKeyframe("no video went out")
            }
        case .rebuild(let reason):
            control.withLock { control in
                guard control.rebuild == nil else { return }
                if control.transcoder != nil {
                    control.rebuild = RebuildRequest(reason: reason, redecide: false, software: false)
                } else {
                    control.rebuild = RebuildRequest(reason: reason, redecide: true, software: false)
                }
            }
        case .end(let reason):
            await endSession(reason, alreadyLogged: true)
        }
    }

    /// Ends this stream through its session: `StreamingHandler` then ends the HomeKit session (`sessionEnder`), so Home sees the
    /// stream available again and starts a new one.
    private func endSession(_ reason: String, alreadyLogged: Bool = false) async {
        let first = endedByPipeline.withLock { ended -> Bool in
            guard ended == nil else { return false }
            ended = reason
            return true
        }
        guard first else { return }
        if !alreadyLogged {
            context.log.error("Live stream [\(sessionID.uuidString.prefix(8))]: ending it (\(reason)); Home will start it again")
        }
        healthState.withLock { $0.noteEnded(reason) }
        sessionTrace?.mark("ended by the pipeline", reason)
        await session.end(reason: .pipelineFailed(reason))   // the log and the status say why, not "stopped"
    }

    // MARK: - Camera keyframe request, output overflow, self-check

    /// Asks the camera for a keyframe (at most once per `cameraKeyframeSpacing` per stream; the camera adapter has its own guard).
    private func askCameraForKeyframe(_ reason: String) {
        guard let ask = context.cameraKeyframe else { return }
        guard cameraKeyframeLimit.allow() else { return }
        context.log.info("Live stream [\(sessionID.uuidString.prefix(8))]: asking the camera for a fresh keyframe (\(reason))")
        let isSub = lease.isSubStream
        Task.detached { await ask(isSub) }
    }

    fileprivate func outputOverflowed() {
        if control.withLock({ $0.transcoder }) != nil {
            requestKeyframe()
        } else {
            askCameraForKeyframe("the session fell behind and lost video frames")
        }
    }

    /// A sample of the outgoing stream for the self-check: one probe at a time in the whole process, at low priority; the
    /// stream never waits for it and never sees it fail.
    fileprivate func probe(_ frames: [EncodedVideoFrame]) -> Bool {
        guard LiveSelfCheck.tryAcquire() else { return false }
        let (transcoder, requested, settings) = control.withLock { ($0.transcoder, $0.requested, $0.settings) }
        let input = transcoder?.diagnostics.inputPicture
        let expectation = LiveSelfCheck.Expectation(width: settings?.width ?? frames[0].format.width, height: settings?.height ?? frames[0].format.height,
                                                    maximumProfileRank: transcoder == nil ? nil : MediaFit.rank(requested.profile),
                                                    payloadType: requested.payloadType, maxPacketSize: packetSize, inputPicture: input,
                                                    transcoded: transcoder != nil)
        let codecs = context.codecs
        let deadline = context.timing.probeDeadline
        let label = String(sessionID.uuidString.prefix(8))
        Task.detached(priority: .utility) { [self] in
            defer { LiveSelfCheck.release() }
            let outcome = await LiveSelfCheck.run(frames: frames, expectation: expectation, codecs: codecs, deadline: deadline)
            switch outcome {
            case .passed(let detail):
                if !loggedProbePass.withLock({ let was = $0; $0 = true; return was }) {
                    context.log.info("Live stream [\(label)]: self-check passed (\(detail))")
                } else {
                    context.log.debug("Live stream [\(label)]: self-check passed (\(detail))")
                }
            case .inconclusive(let why):
                let first = !loggedProbeInconclusive.withLock { let was = $0; $0 = true; return was }
                let line = "Live stream [\(label)]: self-check inconclusive (\(why)); the stream is not affected"
                if first { context.log.info(line) } else { context.log.debug(line) }
            case .failed, .blank:
                break   // `LiveStreamHealth` logs it with what it does about it
            }
            probeOutcomes.withLock { $0.append(outcome) }
        }
        return true
    }
}
