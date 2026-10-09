import BridgeSupport
import Foundation
import Synchronization

/// One device TwoWayAudio channel's two-way session, shared by every camera sink that talks on it.
///
/// An NVR's cameras share TwoWayAudio channel 1 (`HikvisionTalkbackSink.channel(forCamera:in:)`), and every camera has
/// its own `TalkbackBridge` and sink. Opened per sink, each open (which closes the channel first: a stale session blocks
/// the open) and each close ended the session another camera was talking on (W4 review round 4). So the camera's side
/// of the session — `PUT …/open`, the `audioData` upload, `PUT …/close` — lives here, keyed by the device (scheme,
/// host, HTTP port) and channel: the first sink's open opens it, sinks that open while its upload is up join it, and the
/// last sink's release closes it. One sink talks at a time: another sink's audio is dropped while the talking one sent
/// some within `handoverIdle` (as `TalkbackBridge` hands over between one camera's live views). Opens and closes reach
/// the camera one after another, in order. A session with no holders leaves the registry once its close is done.
final class HikvisionTwoWaySession: Sendable {
    struct Key: Hashable, Sendable {
        var host: String
        var port: Int
        var useHTTPS: Bool
        var channel: String
    }

    /// Another sink's audio is dropped while the talking sink sent some within this long.
    static let handoverIdle: Duration = .seconds(1)

    private struct State {
        /// The leases that hold the session.
        var users: Set<UUID> = []
        /// Acquires in progress (counted under the registry lock, so an idle session never leaves it under them).
        var acquiring = 0
        /// The audio upload; nil before the open and after it failed.
        var connection: (any TCPConnection)?
        /// The camera's two-way session is open: until the last holder's release closes it, also after the upload failed.
        var cameraSessionOpen = false
        /// Ends the camera's session (`PUT …/close`, from the sink that opened it).
        var closeCamera: (@Sendable () async -> Void)?
        /// The open in flight; concurrent acquires wait for it and join.
        var opening: Task<Void, any Error>?
        /// The last camera-facing operation (open or close): the next one starts after it.
        var lastOperation: Task<Void, Never>?
        /// Camera-facing operations not finished yet.
        var pendingOperations = 0
        /// The lease whose audio reaches the camera, and when it last sent some.
        var talker: (lease: UUID, lastSent: ContinuousClock.Instant)?
    }

    private static let registry = Mutex<[Key: HikvisionTwoWaySession]>([:])

    let key: Key
    private let state = Mutex(State())

    private init(key: Key) {
        self.key = key
    }

    /// Whether a session for `key` is registered (tests: idle sessions leave the registry).
    static func isRegistered(_ key: Key) -> Bool {
        registry.withLock { $0[key] != nil }
    }

    /// Holds the session of `key` for `lease`: joins it while its upload is up, else opens it with `open` (stale close,
    /// open, upload; it undoes itself when it fails) once the previous camera-facing operation finished. `close` ends the
    /// camera's session when the last holder releases it. Returns the session and whether `lease` joined an open one.
    static func acquire(_ key: Key, lease: UUID, open: @escaping @Sendable () async throws -> any TCPConnection,
                        close: @escaping @Sendable () async -> Void) async throws -> (session: HikvisionTwoWaySession, joined: Bool) {
        let session = registry.withLock { registry in
            let session = registry[key] ?? HikvisionTwoWaySession(key: key)
            registry[key] = session
            session.state.withLock { $0.acquiring += 1 }
            return session
        }
        do {
            let joined = try await session.join(lease, open: open, close: close)
            await session.finishAcquire()
            return (session, joined)
        } catch {
            await session.finishAcquire()
            throw error
        }
    }

    private func join(_ lease: UUID, open: @escaping @Sendable () async throws -> any TCPConnection,
                      close: @escaping @Sendable () async -> Void) async throws -> Bool {
        var joined = true
        while true {
            let opening = state.withLock { state -> Task<Void, any Error>? in
                if state.connection != nil {
                    state.users.insert(lease)
                    return nil
                }
                if let opening = state.opening { return opening }
                joined = false
                let previous = state.lastOperation
                state.pendingOperations += 1
                let task = Task<Void, any Error> {
                    await previous?.value
                    do {
                        let connection = try await open()
                        self.state.withLock { state in
                            state.connection = connection
                            state.cameraSessionOpen = true
                            state.closeCamera = close
                            state.opening = nil
                            state.pendingOperations -= 1
                        }
                    } catch {
                        self.state.withLock { state in
                            state.opening = nil
                            state.pendingOperations -= 1
                        }
                        throw error
                    }
                }
                state.opening = task
                state.lastOperation = Task { _ = try? await task.value }
                return task
            }
            guard let opening else { return joined }
            try await opening.value
        }
    }

    /// `lease` lets go of the session; the last holder's release closes it (the upload, then the camera's session).
    func release(_ lease: UUID) async {
        let closing = state.withLock { state -> Task<Void, Never>? in
            state.users.remove(lease)
            if state.talker?.lease == lease { state.talker = nil }
            return closeIfIdle(&state)
        }
        await closing?.value
        dropIfIdle()
    }

    private func finishAcquire() async {
        let closing = state.withLock { state -> Task<Void, Never>? in
            state.acquiring -= 1
            return closeIfIdle(&state)
        }
        await closing?.value
        dropIfIdle()
    }

    /// Under the lock: when nobody holds or acquires the session, closes the upload and the camera's session, after the
    /// previous camera-facing operation.
    private func closeIfIdle(_ state: inout State) -> Task<Void, Never>? {
        guard state.users.isEmpty, state.acquiring == 0, state.opening == nil else { return nil }
        let connection = state.connection
        let closeCamera = state.cameraSessionOpen ? state.closeCamera : nil
        state.connection = nil
        state.cameraSessionOpen = false
        state.closeCamera = nil
        state.talker = nil
        guard connection != nil || closeCamera != nil else { return nil }
        let previous = state.lastOperation
        state.pendingOperations += 1
        let task = Task {
            await previous?.value
            connection?.close()
            await closeCamera?()
            self.state.withLock { $0.pendingOperations -= 1 }
            self.dropIfIdle()
        }
        state.lastOperation = task
        return task
    }

    /// Leaves the registry when nothing holds, opens or closes the session.
    private func dropIfIdle() {
        Self.registry.withLock { registry in
            let idle = state.withLock { state in
                state.users.isEmpty && state.acquiring == 0 && state.opening == nil && state.pendingOperations == 0
                    && state.connection == nil && !state.cameraSessionOpen
            }
            if idle, registry[key] === self { registry[key] = nil }
        }
    }

    /// Sends `data` for `lease`. Returns false when it was dropped because another holder is talking; fails when the
    /// session has no upload (the failed upload is closed; the camera's session stays open until the last release or
    /// the next open, which closes it first).
    func send(_ data: Data, from lease: UUID, timeout: Duration) async throws -> Bool {
        let connection = try state.withLock { state throws -> (any TCPConnection)? in
            guard state.users.contains(lease), let connection = state.connection else {
                throw CameraAdapterError.unsupported("talkback is not open")
            }
            let now = ContinuousClock.now
            if let talker = state.talker, talker.lease != lease, now - talker.lastSent < Self.handoverIdle { return nil }
            state.talker = (lease, now)
            return connection
        }
        guard let connection else { return false }
        do {
            try await HikvisionTalkbackSink.send(data, on: connection, timeout: timeout)
            return true
        } catch {
            state.withLock { if $0.connection === connection { $0.connection = nil } }
            connection.close()
            throw error
        }
    }
}
