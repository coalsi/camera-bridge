import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import RTSP
import Synchronization

/// One supervised upstream connection feeding a `MediaHub` (plan W3-1 item 1, spec §7, integration brief §3.7).
///
/// Connects `primary` (RTSP, HTTP-FLV or the demo source), ingests every sample into the hub and reconnects when the
/// stream ends or fails, with exponential backoff (1 s → 60 s; a stream that delivered video reconnects after the
/// first step) and a watchdog (no video frame for `watchdog`, 15 s → reconnect; audio alone keeps nothing alive). The
/// stream is `.online` from its first video frame. After `fallbackAfterFailures` consecutive attempts without video it
/// switches to `fallback` (Reolink HTTP-FLV) and back; the source that last delivered video is where the next run starts
/// (after `reconnect()` or `stop()`/`start()`: a camera with RTSP off is not taken offline by three failed RTSP attempts
/// at every wake). A switch needs those failures to have happened while the camera is reachable (a camera that answers
/// nothing fails both transports alike: switching between them would only add connections to a device that is down),
/// and at most one switch happens per `minimumSwitchInterval`.
///
/// With a `CameraReachability` (the camera's shared view of whether it answers at all) the supervisor reports what its
/// attempts show (video: reachable; refused, timed out, closed, RTSP 5xx or no answer: unreachable) and, while the
/// camera is offline, makes no attempt: it waits for the reachability's probe to find the camera again, then connects at
/// once, on the same transport. Rejected credentials wait `unauthorizedRetry` (10 min, so cameras never lock the account) and never
/// count towards the fallback (it sends the same credentials); that wait holds across `reconnect()` (wake, network
/// change: no new login) and `stop()`/`start()` (the sub stream's idle stop). Once offline, the state stays `.offline`
/// through the retries (no `.connecting` in between) until a stream delivers video again: the camera's fault and
/// reachability must not flip at every attempt (spec §7). Every reconnect calls `hub.discontinuity()`. State changes and
/// notable failures are reported through `onEvent`; reasons never contain URLs or credentials. Every sample also feeds
/// `traits` (B-frames, longest GOP).
///
/// `stop()` always wins: a `reconnect()` that is still closing the old connection when the owner stops the supervisor
/// does not connect again, and `stop()` returns only once every connection being closed is closed — or `closeGrace`
/// after the source's own stop limit, for a connection that ignores cancellation and never ends (one camera must not
/// hold the engine's operations, and with them every other camera, for good).
///
/// `reconnect(unlessDeliveringWithin:)` leaves a stream that delivered video a moment ago alone: a network change that did
/// not touch the camera's path must not cost the stream (and, on a Hikvision, another digest login).
actor IngestSupervisor {
    enum State: Sendable, Equatable {
        case idle, connecting, online, offline(String)
    }

    enum Event: Sendable, Equatable {
        case state(State)
        /// The camera rejected the credentials (RTSP 401).
        case unauthorized
        /// Local Network privacy denied the connection.
        case localNetworkDenied
    }

    struct Timing: Sendable, Equatable {
        var watchdog: Duration = .seconds(15)
        var initialBackoff: Duration = .seconds(1)
        var maximumBackoff: Duration = .seconds(60)
        var unauthorizedRetry: Duration = .seconds(600)
        var fallbackAfterFailures = 3
        /// Shortest time between two switches of transport (primary to fallback or back).
        var minimumSwitchInterval: Duration = .seconds(30)
        /// Longest wait for a source to connect.
        var connectTimeout: Duration = .seconds(30)
        /// Longest wait for a source's stop (an RTSP TEARDOWN, an HTTP-FLV request's end) to a camera that may have
        /// vanished: the camera-facing stop limit (`CameraRuntime.stopLimit`).
        var sourceStopLimit: Duration = CameraRuntime.stopLimit
        /// How much longer than `sourceStopLimit` `stop()` / `reconnect()` wait for a connection to finish closing before they
        /// leave it to finish (or hang) on its own.
        var closeGrace: Duration = .seconds(2)
    }

    struct Source: Sendable {
        var label: String
        var make: @Sendable () -> any MediaSource
    }

    enum Failure: Error, Equatable {
        case stalled(Duration)
        case ended
    }

    nonisolated let name: String
    nonisolated let traits: StreamTraits
    /// When the last video frame arrived (nil: none yet on this supervisor).
    private nonisolated let lastVideo = VideoClock()
    private let hub: MediaHub
    private let primary: Source
    private let fallback: Source?
    private let timing: Timing
    private let log: Log
    private let reachability: CameraReachability?
    private let onEvent: @Sendable (Event) -> Void
    private var loop: Task<Void, Never>?
    /// Connections being closed by `stop()` or `reconnect()`; `stop()` waits for all of them.
    private var closing: [Task<Void, Never>] = []
    /// The owner wants the supervisor running: set by `start()`, cleared by `stop()`.
    private var wanted = false
    /// Counts `stop()` calls: a `reconnect()` connects again only when none came in while it was closing.
    private var stops = 0
    private var current: (any MediaSource)?
    /// The camera rejected the credentials: no attempt before this (lockout safety; kept across runs).
    private var rejectedUntil: ContinuousClock.Instant?
    /// The fallback is the source that last delivered video: the next run starts with it.
    private var preferFallback = false
    /// The source being tried is the fallback.
    private var usingFallback = false
    /// When the transport last changed (nil: never).
    private var lastSwitch: ContinuousClock.Instant?
    private(set) var state: State = .idle
    /// The source in use (or last tried).
    private(set) var sourceLabel: String?
    /// Connection attempts made (tests).
    private(set) var attempts = 0

    init(name: String, hub: MediaHub, primary: Source, fallback: Source? = nil, timing: Timing = Timing(), traits: StreamTraits = StreamTraits(),
         log: Log, reachability: CameraReachability? = nil, onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.reachability = reachability
        self.name = name
        self.traits = traits
        self.hub = hub
        self.primary = primary
        self.fallback = fallback
        self.timing = timing
        self.log = log
        self.onEvent = onEvent
    }

    var isRunning: Bool { loop != nil }

    /// Starts supervising (no-op while running).
    func start() {
        wanted = true
        launch()
    }

    /// Stops supervising and the current source; returns once every connection being closed (also by a concurrent
    /// `reconnect()`) is closed. A `reconnect()` in flight does not connect again.
    func stop() async {
        wanted = false
        stops &+= 1
        await close()
        if loop == nil { setState(.idle) }
    }

    /// Whether the stream is online and a video frame arrived within `window`.
    func isDelivering(within window: Duration) -> Bool {
        guard case .online = state, let last = lastVideo.instant.withLock({ $0 }) else { return false }
        return ContinuousClock.now - last <= window
    }

    /// Drops the current connection and connects again at once (wake from sleep, network change). No-op when not
    /// running, and while the wait after rejected credentials runs (a new attempt would be another failed login); does
    /// not connect again when `stop()` was called while the old connection was closing. With `unlessDeliveringWithin`, a
    /// stream that delivered video within that window is left connected (false: nothing was done); a stream that stalled
    /// or is not online is reconnected as usual. Returns whether it reconnected.
    @discardableResult
    func reconnect(unlessDeliveringWithin window: Duration? = nil) async -> Bool {
        guard wanted, loop != nil else { return false }
        if let rejectedUntil, ContinuousClock.now < rejectedUntil {
            log.info("\(name): not reconnecting before the wait after rejected credentials is over")
            return false
        }
        if let window, isDelivering(within: window) {
            log.info("\(name): keeping the stream connected (video arrived within the last \(MediaFit.seconds(window)) s)")
            return false
        }
        let stopsBefore = stops
        await close()
        guard wanted, stops == stopsBefore else { return false }
        launch()
        return true
    }

    private func launch() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    /// Ends the loop and its connection (source stop bounded by `sourceStopLimit`), then waits for every connection
    /// being closed.
    private func close() async {
        if let loop {
            self.loop = nil
            loop.cancel()
            let source = current
            current = nil
            let limit = timing.sourceStopLimit
            closing.append(Task {
                if let source { await Self.stop(source, within: limit) }
                await loop.value
            })
        }
        let pending = closing
        let limit = timing.sourceStopLimit + timing.closeGrace
        for task in pending {
            do {
                try await withDeadline(limit, followsCancellation: false) { await task.value }
            } catch {
                log.warning("\(name): a connection did not finish closing within \(MediaFit.seconds(limit)) s; leaving it to end on its own")
            }
        }
        closing.removeAll { pending.contains($0) }
    }

    // MARK: - Loop

    private enum Outcome {
        case cancelled
        case finished(reason: String, gotSamples: Bool, error: (any Error)?)
    }

    private func run() async {
        var backoff = Backoff(initial: timing.initialBackoff, maximum: timing.maximumBackoff)
        var failures = 0
        var useFallback = preferFallback && fallback != nil
        if let rejectedUntil, ContinuousClock.now < rejectedUntil {
            // Started again (or reconnected) while the wait after rejected credentials runs: it goes on.
            setState(.offline(Self.describe(RTSPError.unauthorized, watchdog: timing.watchdog)))
            do {
                try await Task.sleep(until: rejectedUntil, clock: .continuous)
            } catch {
                return
            }
        }
        while !Task.isCancelled {
            if let reachability, reachability.isOffline {
                await reachability.waitUntilReachable()   // the probe finds the camera again: connect at once
                if Task.isCancelled { break }
            }
            let candidate = useFallback ? (fallback ?? primary) : primary
            usingFallback = useFallback && fallback != nil
            attempts += 1
            sourceLabel = candidate.label
            if case .offline = state {} else { setState(.connecting) }   // an offline camera stays offline while it retries
            let source = candidate.make()
            current = source
            let outcome = await consume(source)
            if current === source {
                current = nil
                await Self.stop(source, within: timing.sourceStopLimit)
            }
            await hub.discontinuity()
            traits.restart()
            guard case .finished(let reason, let gotSamples, let error) = outcome, !Task.isCancelled else { break }

            var delay: Duration
            let answer = Self.cameraAnswer(error)
            switch answer {
            case .unreachable:
                reachability?.reportUnreachable()
                await reachability?.settled()   // the verdict (the camera answers on some port, or on none) decides what follows
            case .answered: reachability?.reportReachable()
            case .neutral: break
            }
            let isOffline = reachability?.isOffline ?? false
            if Self.isUnauthorized(error) {
                // The fallback would send the same credentials: rejected attempts never count towards it, and nothing
                // shortens the wait (lockout safety): `reconnect()` and a new run keep it.
                onEvent(.unauthorized)
                delay = timing.unauthorizedRetry
                rejectedUntil = .now + delay
            } else {
                if (error as? TransportError) == .localNetworkDenied { onEvent(.localNetworkDenied) }
                if gotSamples {
                    failures = 0
                    backoff.reset()
                } else if isOffline {
                    failures = 0   // failures while the camera answers nothing say nothing about this transport
                } else {
                    failures += 1
                }
                delay = backoff.next()
            }
            if fallback != nil, failures >= timing.fallbackAfterFailures, !isOffline,
               lastSwitch.map({ ContinuousClock.now - $0 >= timing.minimumSwitchInterval }) ?? true {
                failures = 0
                lastSwitch = .now
                useFallback.toggle()
                backoff.reset()
                delay = min(delay, timing.initialBackoff)
                log.notice("\(name): switching to \(useFallback ? fallback?.label ?? primary.label : primary.label)")
            }
            setState(.offline(reason))
            if isOffline {
                log.info("\(name) (\(candidate.label)) offline: \(reason); waiting for the camera to answer before trying again")
                continue   // waits at the top for the reachability's probe
            }
            log.info("\(name) (\(candidate.label)) offline: \(reason); retrying in \(MediaFit.seconds(delay)) s")
            do {
                try await Task.sleep(for: delay)
            } catch {
                break
            }
        }
    }

    /// Runs one connection until it ends; ingests into the hub and watches for stalls. Only video counts: the first
    /// video frame takes the stream online, and the watchdog waits for video frames (audio may flow on its own while
    /// the picture is frozen or was never decodable).
    private nonisolated func consume(_ source: any MediaSource) async -> Outcome {
        let progress = IngestProgress()
        let hub = hub
        let traits = traits
        let lastVideo = lastVideo
        let watchdog = timing.watchdog
        do {
            let stream = try await withDeadline(timing.connectTimeout) { try await source.samples() }
            progress.lastSample.withLock { $0 = .now }
            return try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask { [weak self] in
                    for try await sample in stream {
                        if case .video = sample {
                            progress.lastSample.withLock { $0 = .now }
                            lastVideo.instant.withLock { $0 = .now }
                            if progress.gotSamples.withLock({ state in defer { state = true }; return !state }) {
                                await self?.firstSample()
                            }
                        }
                        traits.observe(sample)
                        await hub.ingest(sample)
                    }
                    if Task.isCancelled { return .cancelled }
                    throw Failure.ended
                }
                group.addTask {
                    let tick = min(.seconds(1), watchdog / 4)
                    while true {
                        try await Task.sleep(for: tick)
                        if ContinuousClock.now - progress.lastSample.withLock({ $0 }) > watchdog { throw Failure.stalled(watchdog) }
                    }
                }
                defer { group.cancelAll() }
                return try await group.next() ?? .cancelled
            }
        } catch {
            if Task.isCancelled { return .cancelled }
            return .finished(reason: Self.describe(error, watchdog: watchdog), gotSamples: progress.gotSamples.withLock { $0 }, error: error)
        }
    }

    /// Stops `source`, waiting at most `limit` (an RTSP TEARDOWN to a camera that vanished must not hold up a stop).
    private static func stop(_ source: any MediaSource, within limit: Duration) async {
        _ = try? await withDeadline(limit) { await source.stop() }
    }

    private func firstSample() {
        reachability?.reportReachable()
        rejectedUntil = nil
        preferFallback = usingFallback
        setState(.online)
        log.info("\(name) online (\(sourceLabel ?? "stream"))")
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onEvent(.state(new))
    }

    /// What a failed attempt says about the camera.
    enum CameraAnswer: Sendable, Equatable {
        /// Nothing answered: refused, timed out, closed, no reply, a server error (the camera is down or out of connections).
        case unreachable
        /// The camera answered, with an error (rejected credentials, no such stream).
        case answered
        /// Says nothing either way (the stream stalled or ended, a decoding problem, Local Network privacy).
        case neutral
    }

    /// `error` (a failed connection attempt or stream) as an answer, or the lack of one, from the camera.
    static func cameraAnswer(_ error: (any Error)?) -> CameraAnswer {
        switch error {
        case let transport as TransportError:
            switch transport {
            case .connectionRefused, .timedOut, .closed, .failed: return .unreachable
            case .localNetworkDenied, .addressInUse: return .neutral
            }
        case is DeadlineExceeded:
            return .unreachable
        case let rtsp as RTSPError:
            switch rtsp {
            case .timeout: return .unreachable
            case .badStatus(let status): return status >= 500 ? .unreachable : .answered
            case .unauthorized, .notFound, .protocolError, .noVideoTrack, .unsupportedCodec: return .answered
            }
        case let adapter as CameraAdapterError:
            if case .httpStatus(let status) = adapter, CameraReachability.isGatewayFailure(httpStatus: status) { return .unreachable }
            return .answered
        default:
            return .neutral
        }
    }

    /// The camera rejected the credentials (RTSP 401, or a camera API's: the ONVIF stream-address probe).
    static func isUnauthorized(_ error: (any Error)?) -> Bool {
        (error as? RTSPError) == .unauthorized || (error as? CameraAdapterError) == .unauthorized
    }

    /// A reason for the status line and the log: never a URL or credentials. The stream's own failures are worded here;
    /// every other error (RTSP, transport, camera API) the way the app words it everywhere (`BridgeEngine.readableReason`).
    static func describe(_ error: any Error, watchdog: Duration) -> String {
        switch error {
        case let failure as Failure:
            switch failure {
            case .stalled: return "no video for \(MediaFit.seconds(watchdog)) s"
            case .ended: return "the camera ended the stream"
            }
        case is DeadlineExceeded:
            return "the camera did not answer"
        case is MediaCodecError:
            return "video error"
        default:
            return BridgeEngine.readableReason(error)
        }
    }
}

/// When the last video frame arrived, shared between the consuming task and the supervisor.
private final class VideoClock: Sendable {
    let instant = Mutex<ContinuousClock.Instant?>(nil)
}

/// The ingest watchdog's two flags, in a class: the Linux compiler rejects a noncopyable `Mutex` local captured by a task group's tasks.
private final class IngestProgress: Sendable {
    let lastSample = Mutex(ContinuousClock.now)
    let gotSamples = Mutex(false)
}
