import BridgeSupport
import Foundation
import Synchronization

// In-memory `NetworkTransport` for deterministic server and connection tests (no sockets). The one copy for every test
// target: HDSTests and HAPCameraTests had drifted copies (PortabilityTests' SharedTestHelperTests keeps them from
// coming back). Purpose-built transports with other behaviour stay in their test targets under other names.

/// One direction of an in-memory byte pipe: `receive` waits for chunks, `finish` delivers EOF after the buffered
/// bytes, `shutDown` fails pending and later receives with `TransportError.closed`.
public final class FakeByteQueue: Sendable {
    private struct State {
        var chunks: [Data] = []
        var finished = false
        var shutDown = false
        var waiter: CheckedContinuation<Data?, any Error>?
    }

    private let state = Mutex(State())

    public init() {}

    /// Bytes delivered but not yet received.
    public var pendingByteCount: Int { state.withLock { $0.chunks.reduce(0) { $0 + $1.count } } }
    public var isShutDown: Bool { state.withLock { $0.shutDown } }
    public var isFinished: Bool { state.withLock { $0.finished || $0.shutDown } }

    /// False when the reading side is gone (the bytes are dropped).
    @discardableResult
    public func deliver(_ data: Data) -> Bool {
        let action: (@Sendable () -> Void)? = state.withLock { state in
            guard !state.shutDown, !state.finished else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return { waiter.resume(returning: data) }
            }
            state.chunks.append(data)
            return {}
        }
        action?()
        return action != nil
    }

    public func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<Data?, any Error>? in
            state.finished = true
            defer { state.waiter = nil }
            return state.chunks.isEmpty ? state.waiter : nil
        }
        waiter?.resume(returning: nil)
    }

    public func shutDown() {
        let waiter = state.withLock { state -> CheckedContinuation<Data?, any Error>? in
            state.shutDown = true
            state.chunks.removeAll()
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(throwing: TransportError.closed)
    }

    /// Honours cancellation like `AppleTCPConnection.receive` (throws `CancellationError`, consumes nothing), so a
    /// test client's `withTimeout` and the suite's time limit can end a receive that nothing will ever answer.
    public func receive(maximumLength: Int) async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                let action: @Sendable () -> Void = state.withLock { state in
                    if state.shutDown { return { continuation.resume(throwing: TransportError.closed) } }
                    if !state.chunks.isEmpty {
                        var chunk = state.chunks.removeFirst()
                        if chunk.count > maximumLength {
                            state.chunks.insert(chunk.suffix(from: chunk.startIndex + maximumLength), at: 0)
                            chunk = chunk.prefix(maximumLength)
                        }
                        let result = Data(chunk)
                        return { continuation.resume(returning: result) }
                    }
                    if state.finished { return { continuation.resume(returning: nil) } }
                    // Checked under the lock: a cancellation either is visible here or finds the waiter below.
                    if Task.isCancelled { return { continuation.resume(throwing: CancellationError()) } }
                    state.waiter = continuation
                    return {}
                }
                action()
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Data?, any Error>? in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

/// In-memory `TCPConnection`; `pair()` returns two connected ends. `close()` fails this end's receives with
/// `TransportError.closed` and gives the peer EOF after the bytes already sent. `stallSends()` makes this end's `send`
/// hang like a socket whose peer stopped reading (until `close()`, which fails it with `TransportError.closed`; like
/// `AppleTCPConnection.send`, cancellation does not end it).
public final class FakeTCPConnection: TCPConnection {
    private struct State {
        var closed = false
        var stalled = false
        var failing = false
        var stalledSends: [CheckedContinuation<Void, any Error>] = []
    }

    public let id = UUID()
    public let localAddress = "127.0.0.1"
    public let remoteAddress: String
    public let isIPv6 = false
    /// Bytes this end receives.
    public let inbound: FakeByteQueue
    /// Bytes the peer receives.
    private let outbound: FakeByteQueue
    private let state = Mutex(State())

    private init(inbound: FakeByteQueue, outbound: FakeByteQueue, remoteAddress: String) {
        self.inbound = inbound
        self.outbound = outbound
        self.remoteAddress = remoteAddress
    }

    /// `remoteAddress`: the address the server end reports for its peer.
    public static func pair(remoteAddress: String = "127.0.0.1") -> (client: FakeTCPConnection, server: FakeTCPConnection) {
        let toServer = FakeByteQueue()
        let toClient = FakeByteQueue()
        return (FakeTCPConnection(inbound: toClient, outbound: toServer, remoteAddress: "127.0.0.1"),
                FakeTCPConnection(inbound: toServer, outbound: toClient, remoteAddress: remoteAddress))
    }

    public var isClosed: Bool { state.withLock { $0.closed } }

    /// Sends waiting because of `stallSends()`.
    public var stalledSendCount: Int { state.withLock { $0.stalledSends.count } }

    /// From now on this end's sends wait until `close()`.
    public func stallSends() {
        state.withLock { $0.stalled = true }
    }

    /// From now on this end's sends fail with `TransportError.failed` (the peer reset the connection), while the
    /// connection stays open until `close()`.
    public func failSends() {
        state.withLock { $0.failing = true }
    }

    public func receive(maximumLength: Int) async throws -> Data? {
        try await inbound.receive(maximumLength: maximumLength)
    }

    public func send(_ data: Data) async throws {
        // Not stalled: deliver without suspending, as HDSTests' copy did (its interleaving tests were written against it).
        let stalled = try state.withLock { state throws(TransportError) -> Bool in
            if state.closed { throw TransportError.closed }
            if state.failing { throw TransportError.failed("send failed") }
            return state.stalled
        }
        if !stalled {
            guard outbound.deliver(data) else { throw TransportError.closed }
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let outcome = state.withLock { state -> Bool? in
                if state.closed { return false }
                if state.stalled {
                    state.stalledSends.append(continuation)
                    return nil
                }
                return true
            }
            switch outcome {
            case true?:
                if outbound.deliver(data) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TransportError.closed)
                }
            case false?:
                continuation.resume(throwing: TransportError.closed)
            case nil:
                break
            }
        }
    }

    public func close() {
        let stalled = state.withLock { state -> [CheckedContinuation<Void, any Error>]? in
            guard !state.closed else { return nil }
            state.closed = true
            defer { state.stalledSends.removeAll() }
            return state.stalledSends
        }
        guard let stalled else { return }
        inbound.shutDown()
        outbound.finish()
        for send in stalled { send.resume(throwing: TransportError.closed) }
    }
}

/// In-memory `TCPListener`; the test hands it server-side connection ends with `accept`.
public final class FakeTCPListener: TCPListener {
    public let port: UInt16
    public let connections: AsyncStream<any TCPConnection>
    private let continuation: AsyncStream<any TCPConnection>.Continuation
    private let state = Mutex<(closed: Bool, beforeClose: (@Sendable () -> Void)?)>((false, nil))

    public init(port: UInt16) {
        self.port = port
        (connections, continuation) = AsyncStream.makeStream(of: (any TCPConnection).self)
    }

    public var isClosed: Bool { state.withLock { $0.closed } }

    public func accept(_ connection: FakeTCPConnection) {
        continuation.yield(connection)
    }

    /// Runs once inside the next `close()`, before the stream finishes: e.g. to deliver a connection the "kernel"
    /// accepted just as the owner closed the listener.
    public func beforeClose(_ hook: @escaping @Sendable () -> Void) {
        state.withLock { $0.beforeClose = hook }
    }

    public func close() {
        let hook = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.closed else { return nil }
            state.closed = true
            defer { state.beforeClose = nil }
            return state.beforeClose ?? {}
        }
        guard let hook else { return }
        hook()
        continuation.finish()
    }

    /// Like `AppleTCPListener` when NWListener enters `.waiting`/`.failed` (e.g. on a network change): the stream
    /// finishes without the owner calling `close()`, so `isClosed` stays false.
    public func fail() {
        continuation.finish()
    }
}

/// `NetworkTransport` whose listeners are `FakeTCPListener`s (fake ports from 40000 up); `connect` is unsupported.
public final class FakeNetworkTransport: NetworkTransport {
    private let state = Mutex<(listeners: [FakeTCPListener], errors: [TransportError], listenCount: Int)>(([], [], 0))

    public init() {}

    /// Listeners bound so far (a failed `listen` adds none).
    public var listeners: [FakeTCPListener] { state.withLock { $0.listeners } }
    /// `listen` calls so far, failed ones included.
    public var listenCount: Int { state.withLock { $0.listenCount } }

    /// The next `listen` calls throw these errors (in order) before listening works again.
    public func failNextListens(_ errors: [TransportError]) {
        state.withLock { $0.errors.append(contentsOf: errors) }
    }

    public func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        try state.withLock { state in
            state.listenCount += 1
            if !state.errors.isEmpty { throw state.errors.removeFirst() }
            let listener = FakeTCPListener(port: port == 0 ? UInt16(40000 + state.listeners.count) : port)
            state.listeners.append(listener)
            return listener
        }
    }

    public func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        throw TransportError.connectionRefused
    }
}
