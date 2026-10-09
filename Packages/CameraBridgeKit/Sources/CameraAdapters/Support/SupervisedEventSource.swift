import BridgeSupport
import Foundation
import Synchronization

/// When to reconnect an event channel.
struct ReconnectPolicy: Sendable {
    /// Delay after a session that failed or ended quickly (grows 1 s → 60 s by default).
    var backoff = Backoff()
    /// A session that stayed connected this long counts as healthy: the backoff resets and the next attempt starts at once.
    var healthyAfter: Duration = .seconds(10)
    /// Lower bound for the delay after a failed or short session (Hikvision: 10 s after a fast death).
    var minimumDelayAfterFailure: Duration = .zero
    /// Lower bound for the delay after the camera rejected the credentials (`CameraAdapterError.unauthorized`). Every
    /// attempt is a failed login, and cameras lock the client out after a few (Hikvision: ~30 min after 5–7 illegal
    /// logins, which would also block RTSP after the user fixes the password), so this is minutes, not seconds.
    var delayAfterUnauthorized: Duration = .seconds(600)
    /// Backoff for sessions that connected but ended before `healthyAfter` (a camera that accepts the subscription and then
    /// drops it: Tapo's PullPoint, which closes a request idle for 10 s). nil: the same backoff as failed attempts. Without
    /// a separate, slower one such a camera was retried every few seconds forever.
    var shortSessionBackoff: Backoff?
    /// Sessions in a row that connected and ended before `healthyAfter` (0 after a healthy one).
    var consecutiveShortSessions = 0

    /// The delay before the next attempt, after a session that `connected` (or not), lasted `lasted` and ended with
    /// `error` (nil: the camera closed the channel). Advances or resets the backoff.
    mutating func delay(connected: Bool, lasted: Duration, error: (any Error)?) -> Duration {
        if let error = error as? CameraAdapterError, error.isLoginRefusal {
            return max(delayAfterUnauthorized, backoff.next())   // never resets the backoff
        }
        if connected && lasted >= healthyAfter {
            backoff.reset()
            shortSessionBackoff?.reset()
            consecutiveShortSessions = 0
            return .zero
        }
        if connected {
            consecutiveShortSessions += 1
            if shortSessionBackoff != nil { return max(minimumDelayAfterFailure, shortSessionBackoff?.next() ?? .zero) }
        }
        return max(minimumDelayAfterFailure, backoff.next())
    }
}

/// Whether one connection attempt is connected now, and whether it ever was.
final class ConnectionState: Sendable {
    private let state = Mutex<(isConnected: Bool, everConnected: Bool)>((false, false))

    /// Sets the state; true when this call changed it.
    func set(connected: Bool) -> Bool {
        state.withLock { state in
            defer {
                state.isConnected = connected
                if connected { state.everConnected = true }
            }
            return state.isConnected != connected
        }
    }

    var isConnected: Bool { state.withLock { $0.isConnected } }
    var everConnected: Bool { state.withLock { $0.everConnected } }
}

/// Where `ReconnectLoop` reports: a camera's `Log`, or every camera sharing one connection (`HikvisionAlertHub`).
protocol EventChannelLog: Sendable {
    func debug(_ message: @autoclosure () -> String)
    func info(_ message: @autoclosure () -> String)
    func warning(_ message: @autoclosure () -> String)
}

extension Log: EventChannelLog {}

/// The reconnect loop behind `SupervisedEventSource` and `HikvisionAlertHub`: runs `attempt` (one connection's
/// lifetime) again and again until the task is cancelled, then `afterAttempt` (always, also on cancellation), then
/// waits as `policy` says. `onUnauthorized` runs after an attempt that ended with rejected credentials
/// (`CameraAdapterError.unauthorized`), after `afterAttempt` and before the (long) delay.
///
/// With a `reachability`, no attempt starts while the camera is known to be unreachable (the loop waits for the probe
/// to find it, then connects at once with a fresh backoff): attempts at a camera that is down only burden it when it
/// comes back, and a failure that says nothing answers is reported to the reachability.
enum ReconnectLoop {
    /// How often a channel that keeps failing is summarised in the log (everything else about it is debug).
    static let summaryInterval: Duration = .seconds(600)

    /// Log lines about a channel that fails again and again: the first failure of a streak is a warning, the rest are
    /// debug lines, with a summary every `summaryInterval`; the recovery is logged once.
    struct FailureLog {
        private(set) var failures = 0
        private var lastSummary: ContinuousClock.Instant?

        mutating func record(_ message: String, next delay: Duration, label: String, log: some EventChannelLog, now: ContinuousClock.Instant = .now) {
            failures += 1
            if failures == 1 {
                lastSummary = now
                log.warning(message)
            } else {
                log.debug("\(message) (failure \(failures) in a row; next attempt in \(Int(delay.timeInterval)) s)")
                if let last = lastSummary, now - last >= ReconnectLoop.summaryInterval {
                    lastSummary = now
                    log.info("\(label): the event channel has failed \(failures) times in a row; still retrying (next attempt in \(Int(delay.timeInterval)) s)")
                }
            }
        }

        mutating func recovered(label: String, log: some EventChannelLog) {
            if failures > 1 { log.info("\(label): the event channel recovered after \(failures) failed attempts") }
            failures = 0
            lastSummary = nil
        }
    }

    /// `onShortSessions`: called with the number of sessions in a row that connected but ended before `healthyAfter`,
    /// after each such session (0 once a healthy session ended).
    static func run(label: String, policy: ReconnectPolicy, log: some EventChannelLog, reachability: CameraReachability? = nil, attempt: @Sendable (ConnectionState) async throws -> Void,
                    afterAttempt: @Sendable (ConnectionState) async -> Void, onUnauthorized: @Sendable () -> Void = {},
                    onShortSessions: @Sendable (Int) -> Void = { _ in }) async {
        var policy = policy
        var failureLog = FailureLog()
        while !Task.isCancelled {
            if let reachability, reachability.isOffline {
                await reachability.waitUntilReachable()
                policy.backoff.reset()
                if Task.isCancelled { break }
            }
            let started = ContinuousClock.now
            let connection = ConnectionState()
            var failure: (any Error)?
            var message: String?
            do {
                try await attempt(connection)
                if !Task.isCancelled { message = "\(label): event channel closed by the camera" }
            } catch is CancellationError {
            } catch {
                failure = error
                if !Task.isCancelled { message = "\(label): event channel failed: \(Redact.string(String(describing: error)))" }
            }
            await afterAttempt(connection)
            if Task.isCancelled { break }
            if let failure, let reachability { reachability.report(adapterError: failure) }
            let lasted = ContinuousClock.now - started
            let delay = policy.delay(connected: connection.everConnected, lasted: lasted, error: failure)
            if connection.everConnected && lasted >= policy.healthyAfter {
                failureLog.recovered(label: label, log: log)
                if let message {
                    if failure != nil { log.warning(message) } else { log.info(message) }
                }
            } else if let message {
                failureLog.record(message, next: delay, label: label, log: log)
            }
            if connection.everConnected { onShortSessions(policy.consecutiveShortSessions) }
            if let failure = failure as? CameraAdapterError, failure.isLoginRefusal {
                log.warning("\(label): the camera rejected the credentials; next attempt in \(Int(delay.timeInterval)) s")
                onUnauthorized()
            }
            if let reachability, reachability.isOffline { continue }   // waits at the top, then connects at once
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { break }
            }
        }
    }
}

/// Handed to one connection attempt of a `SupervisedEventSource`.
final class EventSessionContext: Sendable {
    let holds: EventHoldState
    private let connection: ConnectionState
    private let emit: @Sendable (CameraEvent) -> Void

    init(holds: EventHoldState, connection: ConnectionState = ConnectionState(), emit: @escaping @Sendable (CameraEvent) -> Void) {
        self.holds = holds
        self.connection = connection
        self.emit = emit
    }

    /// Marks the event channel connected (emits `.eventChannel(connected: true)` when it was not).
    func connected() {
        if connection.set(connected: true) { emit(.eventChannel(connected: true)) }
    }

    /// Marks the event channel disconnected. Level states (sources without a hold) end first — the camera can no
    /// longer report their end, and a reconnected channel re-asserts whatever is still on — then
    /// `.eventChannel(connected: false)` is emitted (when it was connected). Pulses keep their hold and expire on their
    /// own. The supervisor calls this when a session ends; sessions that outlive a camera connection call it themselves.
    func disconnected() async {
        let wasConnected = connection.set(connected: false)
        await holds.releaseLevelSources()
        if wasConnected { emit(.eventChannel(connected: false)) }
    }

    var isConnected: Bool { connection.isConnected }

    func apply(_ signals: [EventSignal]) async {
        await holds.apply(signals)
    }
}

/// A self-reconnecting `CameraEventSource`: runs `session` (one connection's lifetime) again and again with the
/// `ReconnectPolicy` until `stop()`. Starts on the first `events()` call. Emits `.eventChannel(connected:)` when a
/// session reports `connected()` / `disconnected()` and when that session ends (level states end with the channel,
/// see `EventSessionContext.disconnected()`). A session that ends with rejected credentials emits
/// `.authenticationFailed`. Pulse holds and ring deduplication survive reconnects. `onStop` runs once, after the last
/// session ended, on `stop()` or when the source is released.
final class SupervisedEventSource: CameraEventSource, Sendable {
    typealias Session = @Sendable (EventSessionContext) async throws -> Void

    private struct State {
        var task: Task<Void, Never>?
        var stopped = false
        var onStop: (@Sendable () async -> Void)?
    }

    private let label: String
    private let policy: ReconnectPolicy
    /// Short sessions in a row after which `.eventChannelUnreliable` is emitted (nil: never).
    private let unreliableAfter: Int?
    private let session: Session
    private let log: Log
    private let reachability: CameraReachability?
    private let broadcaster = AsyncBroadcaster<CameraEvent>(bufferingNewest: 256)
    private let holds: EventHoldState
    private let state: Mutex<State>

    init(label: String, cameraID: UUID? = nil, policy: ReconnectPolicy = ReconnectPolicy(), ringDedupe: Duration = .seconds(3),
         unreliableAfterShortSessions: Int? = nil, onStop: (@Sendable () async -> Void)? = nil, reachability: CameraReachability? = nil,
         session: @escaping Session) {
        self.reachability = reachability
        self.label = label
        self.policy = policy
        self.unreliableAfter = unreliableAfterShortSessions
        self.session = session
        self.log = Log(category: "events", cameraID: cameraID)
        self.state = Mutex(State(onStop: onStop))
        let broadcaster = self.broadcaster
        self.holds = EventHoldState(ringDedupe: ringDedupe) { broadcaster.yield($0) }
    }

    deinit {
        // Dropped without stop(): end the channel (the run loop does not retain the source), then run the stop hook.
        let (task, onStop) = state.withLock { state in
            defer { state.onStop = nil }
            return (state.task, state.onStop)
        }
        task?.cancel()
        broadcaster.finish()
        if let onStop {
            Task {
                await task?.value
                await onStop()
            }
        }
    }

    func events() -> AsyncStream<CameraEvent> {
        let stream = broadcaster.subscribe()
        let (label, policy, session, log, broadcaster, holds, unreliableAfter, reachability) = (label, policy, session, log, broadcaster, holds,
                                                                                               unreliableAfter, reachability)
        let start = state.withLock { state -> Bool in
            guard !state.stopped, state.task == nil else { return false }
            state.task = Task {
                await ReconnectLoop.run(label: label, policy: policy, log: log, reachability: reachability) { connection in
                    try await session(EventSessionContext(holds: holds, connection: connection) { broadcaster.yield($0) })
                } afterAttempt: { connection in
                    await EventSessionContext(holds: holds, connection: connection) { broadcaster.yield($0) }.disconnected()
                } onUnauthorized: {
                    broadcaster.yield(.authenticationFailed)
                } onShortSessions: { count in
                    guard let unreliableAfter, count == unreliableAfter else { return }
                    log.warning("\(label): the camera's event channel ends right after it connects (\(count) times in a row); events are unreliable")
                    broadcaster.yield(.eventChannelUnreliable(shortSessions: count))
                }
            }
            return true
        }
        if start { log.debug("\(label): event channel starting") }
        return stream
    }

    func stop() async {
        let (task, onStop) = state.withLock { state in
            state.stopped = true
            defer {
                state.task = nil
                state.onStop = nil
            }
            return (state.task, state.onStop)
        }
        task?.cancel()
        await task?.value
        await holds.cancelAll()
        broadcaster.finish()
        await onStop?()
    }
}
