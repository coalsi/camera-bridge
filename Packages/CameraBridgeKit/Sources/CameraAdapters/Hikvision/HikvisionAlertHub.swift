import BridgeSupport
import Foundation
import Synchronization

/// One ISAPI `alertStream` per device, shared by every camera on it: integration brief §3.3 ("one stream per device
/// IP; filter by channelID for NVRs") — NVRs cap concurrent alertStream sessions, so N channel cameras must not open
/// N streams. Hubs are keyed by scheme, host, port and credentials and reference-counted: the first `acquire`
/// connects, the last `release` disconnects. The hub owns reconnects (`HikvisionEventTiming.policy`: 10 s after a fast
/// death, long delay after rejected credentials) and the 5-minute idle watchdog; subscribers see raw alerts,
/// connection changes and rejected credentials (remembered until the next successful connection, so a camera that
/// subscribes while the hub waits out its long retry delay still learns about them).
///
/// Re-subscribing (wake, network change: each camera's event source is replaced by a new one from the same driver)
/// gives a camera with its own stream a fresh connection, but cameras sharing one would each rejoin the old, possibly
/// half-open stream. So once every current subscriber has re-subscribed since the current connection attempt began,
/// the hub drops that connection (or its retry wait) and connects again at once — one reconnect per refresh, however
/// many channels share the stream, and none when a camera merely joins. Not after rejected credentials: the long
/// retry delay protects the device's login lockout.
///
/// The stream belongs to no one camera, so what the hub logs (the stream failing, rejected credentials, reconnects)
/// goes to every subscribed camera's log: one entry per camera, tagged with its ID and naming the device (W4 review
/// round 4); untagged only while no subscriber names a camera.
final class HikvisionAlertHub: Sendable {
    enum Update: Sendable, Equatable {
        case connected(Bool)
        case alert(HikvisionAlert)
        /// The device rejected the credentials; the next attempt waits the long delay.
        case authenticationFailed
    }

    struct Key: Hashable, Sendable {
        var host: String
        var port: Int
        var useHTTPS: Bool
        var credentials: HTTPCredentials?
    }

    private struct User {
        /// When the subscriber subscribed.
        var since: ContinuousClock.Instant
        /// The camera it subscribed for (the hub's log lines go to it).
        var cameraID: UUID?
    }

    /// Logs to every subscribed camera (`ReconnectLoop` reports through it).
    private struct SubscriberLog: EventChannelLog {
        let hub: HikvisionAlertHub
        func debug(_ message: @autoclosure () -> String) { hub.log(.debug, message()) }
        func info(_ message: @autoclosure () -> String) { hub.log(.info, message()) }
        func warning(_ message: @autoclosure () -> String) { hub.log(.warning, message()) }
    }

    private struct State {
        /// The current subscribers, by subscription id.
        var users: [Int: User] = [:]
        var nextUser = 0
        var isConnected = false
        /// The last attempt ended with rejected credentials (cleared by a successful connection).
        var credentialsRejected = false
        var task: Task<Void, Never>?
        /// When the current (or last) connection attempt began; nil until the running task's first attempt.
        var attemptStarted: ContinuousClock.Instant?
    }

    /// One subscriber's hold on the hub; `release()` it exactly once.
    struct Subscription: Sendable {
        let hub: HikvisionAlertHub
        fileprivate let id: Int

        func release() { hub.release(id) }
    }

    private static let hubs = Mutex<[Key: HikvisionAlertHub]>([:])

    private let key: Key
    private let endpoint: CameraEndpoint
    private let credentials: HTTPCredentials?
    private let timing: HikvisionEventTiming
    private let broadcaster = AsyncBroadcaster<Update>(bufferingNewest: 256)
    private let state = Mutex(State())

    private init(key: Key, endpoint: CameraEndpoint, credentials: HTTPCredentials?, timing: HikvisionEventTiming) {
        self.key = key
        self.endpoint = endpoint
        self.credentials = credentials
        self.timing = timing
    }

    /// The device's hub (created and connected by the first user; its timing wins). `cameraID`: the camera subscribing
    /// (the hub's log lines go to it). `resubscribing`: this camera's events are being re-subscribed (its driver made an
    /// event source before), see the type documentation.
    static func acquire(endpoint: CameraEndpoint, credentials: HTTPCredentials?, timing: HikvisionEventTiming, cameraID: UUID? = nil,
                        resubscribing: Bool = false) -> Subscription {
        let key = Key(host: endpoint.host.lowercased(), port: endpoint.httpPort, useHTTPS: endpoint.useHTTPS, credentials: credentials)
        let (subscription, reconnecting) = hubs.withLock { hubs in
            let hub = hubs[key] ?? HikvisionAlertHub(key: key, endpoint: endpoint, credentials: credentials, timing: timing)
            hubs[key] = hub
            let (id, reconnecting) = hub.addUser(cameraID: cameraID, resubscribing: resubscribing)
            return (Subscription(hub: hub, id: id), reconnecting)
        }
        if reconnecting {
            subscription.hub.log(.info, "Hikvision \(endpoint.host): every camera re-subscribed; reconnecting the shared alertStream")
        }
        return subscription
    }

    /// Adds a subscriber; also whether its arrival reconnects the stream (every subscriber re-subscribed).
    private func addUser(cameraID: UUID?, resubscribing: Bool) -> (id: Int, reconnecting: Bool) {
        state.withLock { state in
            let id = state.nextUser
            state.nextUser += 1
            state.users[id] = User(since: .now, cameraID: cameraID)
            if state.task == nil {
                state.attemptStarted = nil
                state.task = Task { await self.run() }
            } else if resubscribing, !state.credentialsRejected, let started = state.attemptStarted,
                      state.users.values.allSatisfy({ $0.since > started }) {
                // Every subscriber re-subscribed since this connection attempt began: reconnect now. The new run starts
                // after the old one ended, so subscribers see its disconnect before the new connection.
                let previous = state.task
                previous?.cancel()
                state.attemptStarted = nil
                state.task = Task {
                    await previous?.value
                    await self.run()
                }
                return (id, true)
            }
            return (id, false)
        }
    }

    /// Logs `message` once for every camera subscribed now, tagged with its ID (once untagged when none names one).
    fileprivate func log(_ level: LogLevel, _ message: String) {
        let cameras = state.withLock { Set($0.users.values.map(\.cameraID)) }
        for camera in cameras.isEmpty ? [nil] : cameras {
            let log = Log(category: "hikvision-events", cameraID: camera)
            switch level {
            case .debug: log.debug(message)
            case .info: log.info(message)
            case .notice: log.notice(message)
            case .warning: log.warning(message)
            case .error: log.error(message)
            }
        }
    }

    /// Drops one user; the last one disconnects the stream.
    fileprivate func release(_ id: Int) {
        let task = Self.hubs.withLock { hubs -> Task<Void, Never>? in
            let (remaining, task) = state.withLock { state -> (Int, Task<Void, Never>?) in
                state.users[id] = nil
                guard state.users.isEmpty else { return (state.users.count, nil) }
                defer { state.task = nil }
                return (0, state.task)
            }
            if remaining == 0, hubs[key] === self { hubs[key] = nil }
            return task
        }
        task?.cancel()
    }

    /// The connection state now (and whether the last attempt's credentials were rejected) and every later update.
    /// Subscribe first, then read: an update racing the call shows up in the stream (a repeated `.connected` or
    /// `.authenticationFailed` is harmless).
    func subscribe() -> (connected: Bool, credentialsRejected: Bool, updates: AsyncStream<Update>) {
        let updates = broadcaster.subscribe()
        let (connected, rejected) = state.withLock { ($0.isConnected, $0.credentialsRejected) }
        return (connected, rejected, updates)
    }

    private func publish(_ update: Update) {
        switch update {
        case .connected(let connected):
            state.withLock { state in
                state.isConnected = connected
                if connected { state.credentialsRejected = false }
            }
        case .authenticationFailed:
            state.withLock { $0.credentialsRejected = true }
        case .alert:
            break
        }
        broadcaster.yield(update)
    }

    private func run() async {
        let (endpoint, credentials, timing) = (endpoint, credentials, timing)
        log(.debug, "Hikvision \(endpoint.host): shared alertStream starting")
        await ReconnectLoop.run(label: "Hikvision \(endpoint.host)", policy: timing.policy, log: SubscriberLog(hub: self)) { connection in
            self.state.withLock { $0.attemptStarted = .now }
            try await HikvisionEvents.alertSession(endpoint: endpoint, credentials: credentials, timing: timing) {
                if connection.set(connected: true) { self.publish(.connected(true)) }
            } onAlert: { alert in
                self.publish(.alert(alert))
            }
        } afterAttempt: { connection in
            if connection.set(connected: false) { self.publish(.connected(false)) }
        } onUnauthorized: {
            self.publish(.authenticationFailed)
        }
    }
}
