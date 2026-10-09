import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore

/// Built-in motion detection for cameras without usable events (plan W3-1 item 6, spec §6): decodes the sub stream
/// (or the main stream when there is none), feeds a 320-pixel luma thumbnail to `SoftMotionDetector` about four times
/// a second and reports transitions to the `EventRouter` (origin `.softMotion`). When pictures stop arriving while motion
/// is on (the detector releases motion only from new pictures), the origin is reset so motion ends with its hold. The
/// detector's sampling and 10 s quiet period run on the monotonic clock (`detectorTime`): a wall clock stepped back (an
/// NTP correction after wake, a manual change) would hold motion — and HKSV recording — on for the size of the step.
///
/// A monitor made for the motion shadow test (`init(…shadow:…)`) is the same detector with a different destination: its
/// transitions go to the closure it was given and nowhere else — it holds no `EventRouter`, so it cannot move HomeKit motion.
actor SoftMotionMonitor {
    /// Where the detector's transitions go.
    private enum Output: Sendable {
        /// The camera's motion (origin `.softMotion`).
        case router(EventRouter)
        /// The shadow test: a transition is reported to the closure and nothing else.
        case shadow(@Sendable (Bool) async -> Void)
    }

    static let analysisInterval: Duration = .milliseconds(250)
    static let stallTimeout: Duration = .seconds(5)

    private let hub: MediaHub
    private let codecs: any MediaCodecs
    private let sensitivity: Double
    private let output: Output
    private let cameraID: UUID
    private let log: Log
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var detector: SoftMotionDetector
    private var motion = false
    private var lastPicture = ContinuousClock.now
    private var lastAnalysis: ContinuousClock.Instant?
    /// The detector's time origin (`detectorTime`).
    private let origin = ContinuousClock.now
    /// `stop()` was called: nothing more is reported.
    private var stopped = false
    /// Pictures analysed (tests).
    private(set) var analysed = 0

    init(hub: MediaHub, codecs: any MediaCodecs, sensitivity: Double, router: EventRouter, cameraID: UUID, log: Log) {
        self.init(hub: hub, codecs: codecs, sensitivity: sensitivity, output: .router(router), cameraID: cameraID, log: log)
    }

    /// A monitor for the motion shadow test: `report` receives every transition (motion on, motion off — also when the monitor
    /// stops or loses the picture while motion is on) and nothing reaches the event router.
    init(hub: MediaHub, codecs: any MediaCodecs, sensitivity: Double, shadow report: @escaping @Sendable (Bool) async -> Void, cameraID: UUID,
         log: Log) {
        self.init(hub: hub, codecs: codecs, sensitivity: sensitivity, output: .shadow(report), cameraID: cameraID, log: log)
    }

    private init(hub: MediaHub, codecs: any MediaCodecs, sensitivity: Double, output: Output, cameraID: UUID, log: Log) {
        self.hub = hub
        self.codecs = codecs
        self.sensitivity = min(max(sensitivity, 0), 1)
        self.output = output
        self.cameraID = cameraID
        self.log = log
        detector = SoftMotionDetector(sensitivity: min(max(sensitivity, 0), 1))
    }

    func start() {
        guard task == nil, !stopped else { return }
        lastPicture = .now
        task = Task { [weak self] in await self?.run() }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.checkStall()
            }
        }
    }

    /// Stops analysing and resets the origin. Waits for the analysis task first (a picture already decoding returns
    /// it anyway): no transition may reach the router after the reset, or a motion level would outlive the monitor.
    func stop() async {
        stopped = true
        let analysis = task
        let stall = watchdog
        task = nil
        watchdog = nil
        analysis?.cancel()
        stall?.cancel()
        await analysis?.value
        await stall?.value
        let wasActive = motion
        motion = false
        await end(wasActive: wasActive)
    }

    /// Reports a transition of the detector.
    private func report(_ active: Bool) async {
        switch output {
        case .router(let router): await router.handle(.motion(active), for: cameraID, origin: .softMotion)
        case .shadow(let sink): await sink(active)
        }
    }

    /// Motion ends without the detector's say-so (the monitor stops, the pictures stop): the router's origin is reset (its
    /// level ends and holds for the hold time); the shadow test is told that motion went off.
    private func end(wasActive: Bool) async {
        switch output {
        case .router(let router): await router.resetOrigin(.softMotion, for: cameraID)
        case .shadow(let sink): if wasActive { await sink(false) }
        }
    }

    private func run() async {
        let subscription = await hub.subscribe(from: .nextKeyframe, bufferLimit: 120)
        defer { subscription.cancel() }
        var decoder: (any VideoDecoding)?
        var decoderFormat: VideoFormat?
        var warned = false
        for await sample in subscription.samples {
            guard case .video(let frame) = sample, !Task.isCancelled else { continue }
            if decoderFormat != frame.format {
                guard frame.isKeyframe else { continue }
                decoder?.invalidate()
                decoder = try? codecs.makeVideoDecoder(format: frame.format)
                decoderFormat = frame.format
            }
            guard let decoder else { continue }
            do {
                guard let picture = try await decoder.decode(frame), !Task.isCancelled, !stopped else { continue }
                await analyse(picture)
            } catch is CancellationError {
                break
            } catch {
                if !warned { log.warning("Motion detection could not decode the stream (\(error))") }
                warned = true
                decoderFormat = nil   // start again at the next keyframe
            }
        }
        decoder?.invalidate()
    }

    private func analyse(_ picture: any DecodedVideoFrame) async {
        let now = ContinuousClock.now
        lastPicture = now
        if let lastAnalysis, now - lastAnalysis < Self.analysisInterval { return }
        lastAnalysis = now
        guard let image = picture.grayThumbnail(maxWidth: 320) else { return }
        analysed += 1
        if let changed = await detector.process(image, at: Self.detectorTime(now, origin: origin)), !Task.isCancelled, !stopped {
            motion = changed
            await report(changed)
        }
    }

    /// `instant` as the detector's time: monotonic, measured from `origin` (the detector only compares its times).
    static func detectorTime(_ instant: ContinuousClock.Instant, origin: ContinuousClock.Instant) -> Date {
        Date(timeIntervalSinceReferenceDate: (instant - origin).timeInterval)
    }

    private func checkStall() async {
        guard !stopped, motion, ContinuousClock.now - lastPicture > Self.stallTimeout else { return }
        if case .shadow = output {
            log.debug("Motion shadow test: the sub stream lost the picture; the built-in period ends")
        } else {
            log.info("Motion detection lost the picture; ending motion")
        }
        motion = false
        detector = SoftMotionDetector(sensitivity: sensitivity)
        await end(wasActive: true)
    }
}
