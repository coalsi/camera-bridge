import Foundation
import Synchronization

/// Thrown instead of a request while the camera is known to be unreachable (`CameraReachability.isOffline`): nothing was
/// sent. Callers treat it like any other failure to reach the camera.
public struct CameraOfflineError: Error, Equatable, Sendable, CustomStringConvertible {
    public init() {}
    public var description: String { "the camera is unreachable; waiting for it to come back" }
}

/// Whether one camera answers at all, shared by everything that talks to it (video ingest, camera API, ONVIF, event
/// channel, snapshots).
///
/// A Wi-Fi doorbell that drops off the network (or reboots after a settings change) refuses or ignores every connection
/// for a while. Without a shared view each component retried on its own clock: RTSP, HTTP-FLV, the snapshot API, the
/// event poll and ONVIF, each failing at its own pace, every attempt another connection for a device that allows only a
/// handful and is trying to come back. The camera is instead in one of three phases:
///
/// - **reachable**: every component works as usual and reports what it saw (`reportReachable()` after an answer from the
///   camera, `reportUnreachable()` after a failure that says nothing is listening: refused, timed out, closed, a gateway
///   error). Any answer resets the failure count.
/// - **verifying**: `failuresBeforeOffline` unreachable reports in a row (no answer in between) make one TCP connection
///   attempt to each of the camera's ports (HTTP, RTSP) at once. If any connects the camera is there, and what failed was
///   one service (RTSP switched off, a stream path): back to reachable. `settled()` waits for the verdict.
/// - **offline**: none connected. Components stop sending (`isOffline` is read by the API client, the event loops, the
///   ingest and the snapshot provider, which serves the last picture it has) and wait in `waitUntilReachable()`. One probe
///   at a time runs on an exponential backoff from `probeInitial` to `probeMaximum`; the first that connects puts the
///   camera back to reachable and everything resumes at once. Going offline again soon after a recovery (less than
///   `stableAfter`) keeps the probe backoff where it was: a camera that flaps is probed at the slow end of it.
public final class CameraReachability: Sendable {
    public struct Timing: Sendable, Equatable {
        /// Unreachable reports in a row (no answer from the camera between them) that start the verification.
        public var failuresBeforeOffline = 3
        /// First wait before a probe, doubling (with jitter) up to `probeMaximum`.
        public var probeInitial: Duration = .seconds(2)
        public var probeMaximum: Duration = .seconds(60)
        public var probeJitter = 0.2
        /// Longest wait for a probe's TCP connection.
        public var probeTimeout: Duration = .seconds(3)
        /// Reachable this long counts as recovered: the next outage starts the probe backoff afresh.
        public var stableAfter: Duration = .seconds(30)

        public init() {}
    }

    public enum Phase: Sendable, Equatable {
        case reachable, verifying, offline
    }

    private struct Waiter {
        var continuation: CheckedContinuation<Void, Never>
        /// The phases that end the wait.
        var endsIn: @Sendable (Phase) -> Bool
    }

    private struct State {
        var phase = Phase.reachable
        var failures = 0
        var backoff: Backoff
        var probeTask: Task<Void, Never>?
        var offlineSince: ContinuousClock.Instant?
        var reachableSince: ContinuousClock.Instant?
        var probes = 0
        var nextWaiter: UInt64 = 0
        var waiters: [UInt64: Waiter] = [:]

        /// Moves to `new` and returns the waiters that wait for it.
        mutating func enter(_ new: Phase) -> [CheckedContinuation<Void, Never>] {
            phase = new
            let ready = waiters.filter { $0.value.endsIn(new) }
            for key in ready.keys { waiters[key] = nil }
            return ready.values.map(\.continuation)
        }
    }

    public let host: String
    private let ports: [UInt16]
    private let transport: any NetworkTransport
    private let timing: Timing
    private let log: Log
    private let state: Mutex<State>

    /// `ports`: where a probe connects (any one answering counts), usually the camera's HTTP and RTSP ports.
    public init(host: String, ports: [UInt16], transport: any NetworkTransport, timing: Timing = Timing(), log: Log) {
        self.host = host
        self.ports = ports
        self.transport = transport
        self.timing = timing
        self.log = log
        self.state = Mutex(State(backoff: Backoff(initial: timing.probeInitial, maximum: timing.probeMaximum, jitter: timing.probeJitter)))
    }

    deinit {
        let (task, waiters) = state.withLock { state in
            defer { state.probeTask = nil; state.waiters = [:] }
            return (state.probeTask, state.waiters.values.map(\.continuation))
        }
        task?.cancel()
        for waiter in waiters { waiter.resume() }
    }

    public var phase: Phase { state.withLock { $0.phase } }

    /// None of the camera's ports answers: send nothing, wait for `waitUntilReachable()`.
    public var isOffline: Bool { phase == .offline }

    /// Probes made since the camera went offline (0 while reachable); tests and the log.
    public var probeCount: Int { state.withLock { $0.probes } }

    /// The camera answered something: it is reachable (this ends an offline period or a verification, and resets the
    /// failure count).
    public func reportReachable() {
        let outcome: (waiters: [CheckedContinuation<Void, Never>], task: Task<Void, Never>?, downFor: Duration?, probes: Int, wasOffline: Bool)? =
            state.withLock { state in
                state.failures = 0
                guard state.phase != .reachable else {
                    if state.reachableSince == nil { state.reachableSince = .now }
                    return nil
                }
                let wasOffline = state.phase == .offline
                let downFor = state.offlineSince.map { ContinuousClock.now - $0 }
                let probes = state.probes
                state.offlineSince = nil
                state.reachableSince = .now
                state.probes = 0
                let task = state.probeTask
                state.probeTask = nil
                return (state.enter(.reachable), task, downFor, probes, wasOffline)
            }
        guard let outcome else { return }
        outcome.task?.cancel()
        for waiter in outcome.waiters { waiter.resume() }
        if outcome.wasOffline {
            log.info("\(host) is reachable again" + (outcome.downFor.map { " after \(Int($0.timeInterval.rounded())) s (\(outcome.probes) probes)" } ?? "")
                     + "; resuming")
        }
    }

    /// A request failed in a way that says nothing is listening (see `isUnreachable(_:)`). The `failuresBeforeOffline`-th
    /// in a row starts the verification (`settled()` waits for its verdict).
    public func reportUnreachable() {
        let started: Bool = state.withLock { state in
            guard state.phase == .reachable else { return false }
            state.failures += 1
            guard state.failures >= timing.failuresBeforeOffline else { return false }
            let waiters = state.enter(.verifying)
            for waiter in waiters { waiter.resume() }   // none wait for `verifying`; kept for symmetry
            state.probeTask = Task { [weak self] in await self?.verifyThenProbe() }
            return true
        }
        if started { log.info("\(host): \(timing.failuresBeforeOffline) failed connections in a row; checking whether it answers at all") }
    }

    /// Reports `error` as `isUnreachable(_:)` classifies it: unreachable, or (the camera answered, with an error) reachable.
    public func report(_ error: any Error) {
        if Self.isUnreachable(error) { reportUnreachable() } else if !(error is CameraOfflineError), !(error is CancellationError) { reportReachable() }
    }

    /// Forgets everything (the camera is stopped, or its settings changed): no probe, no failures, nobody waiting.
    public func reset() {
        let (task, waiters) = state.withLock { state in
            state.failures = 0
            state.offlineSince = nil
            state.reachableSince = nil
            state.probes = 0
            state.backoff.reset()
            let task = state.probeTask
            state.probeTask = nil
            return (task, state.enter(.reachable))
        }
        task?.cancel()
        for waiter in waiters { waiter.resume() }
    }

    /// Returns at once unless a verification is under way; then when its verdict is known (reachable or offline).
    public func settled() async {
        await wait(until: { $0 != .verifying })
    }

    /// Returns at once while the camera is not offline; while it is, when the probe finds it again (or the task is
    /// cancelled).
    public func waitUntilReachable() async {
        await wait(until: { $0 == .reachable })
    }

    private func wait(until endsIn: @escaping @Sendable (Phase) -> Bool) async {
        guard !endsIn(phase) else { return }
        let id = state.withLock { state -> UInt64 in
            state.nextWaiter &+= 1
            return state.nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if endsIn(state.phase) || Task.isCancelled { return true }
                    state.waiters[id] = Waiter(continuation: continuation, endsIn: endsIn)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume()
        }
    }

    // MARK: - Probe

    /// The verdict, then (offline) the probe loop.
    private func verifyThenProbe() async {
        if await probeOnce() {
            reportReachable()
            return
        }
        if Task.isCancelled { return }
        let (waiters, backedOff): ([CheckedContinuation<Void, Never>], Bool) = state.withLock { state in
            guard state.phase == .verifying else { return ([], false) }
            state.offlineSince = .now
            state.probes = 0
            let backedOff = state.reachableSince.map { ContinuousClock.now - $0 >= timing.stableAfter } ?? true
            if backedOff { state.backoff.reset() }
            state.reachableSince = nil
            return (state.enter(.offline), backedOff)
        }
        for waiter in waiters { waiter.resume() }
        guard phase == .offline else { return }
        log.warning("\(host) does not answer: pausing requests to it and probing with a growing delay "
                    + "(\(Int(timing.probeInitial.timeInterval.rounded())) s to \(Int(timing.probeMaximum.timeInterval.rounded())) s) until it does"
                    + (backedOff ? "" : " (it went away again soon after coming back: probing stays slow)"))
        await probeLoop()
    }

    private func probeLoop() async {
        while !Task.isCancelled {
            let delay = state.withLock { $0.backoff.next() }
            do { try await Task.sleep(for: delay) } catch { return }
            guard isOffline else { return }
            state.withLock { $0.probes += 1 }
            if await probeOnce() {
                reportReachable()
                return
            }
            log.debug("\(host) still does not answer (probe \(probeCount))")
        }
    }

    /// One TCP connect to each of the camera's ports at once; true when any connects.
    private func probeOnce() async -> Bool {
        let (host, transport, timeout) = (host, transport, timing.probeTimeout)
        return await withTaskGroup(of: Bool.self) { group in
            for port in ports {
                group.addTask {
                    do {
                        let connection = try await transport.connect(host: host, port: port, timeout: timeout)
                        connection.close()
                        return true
                    } catch {
                        return false
                    }
                }
            }
            for await answered in group where answered {
                group.cancelAll()
                return true
            }
            return false
        }
    }

    // MARK: - Classification

    /// Whether `error` says the camera did not answer (nothing listening, no reply, the link dropped), as opposed to an
    /// answer that is an error (rejected credentials, a missing resource, an API error code). Local Network privacy
    /// denials and local address clashes are not the camera's.
    public static func isUnreachable(_ error: any Error) -> Bool {
        switch error {
        case let transport as TransportError:
            switch transport {
            case .connectionRefused, .timedOut, .closed, .failed: return true
            case .localNetworkDenied, .addressInUse: return false
            }
        case is DeadlineExceeded:
            return true
        case is URLError:
            return isUnreachable(URLFreeErrors.sanitized(error))   // timed out, refused, lost, or another network failure (not a cancellation)
        default:
            return false
        }
    }

    /// An HTTP status from a camera's web server that has no service behind it (a gateway error: the camera's HTTP front
    /// end is up, the application is not, as during a reboot or under overload).
    public static func isGatewayFailure(httpStatus: Int) -> Bool {
        [502, 503, 504].contains(httpStatus)
    }
}
