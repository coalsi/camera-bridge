#if os(Linux)
import BridgeSupport
import Dispatch
import Foundation
import Glibc
import Synchronization

/// Resumes a continuation at most once (a readiness event, a timeout and a close can all race to answer one wait).
final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, any Error>?>

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = Mutex(continuation)
    }

    /// True if this call resumed the continuation.
    @discardableResult
    func resume(with result: Result<Value, any Error>) -> Bool {
        let taken = continuation.withLock { state in
            defer { state = nil }
            return state
        }
        taken?.resume(with: result)
        return taken != nil
    }
}

/// swift-corelibs-libdispatch's sources are not `Sendable`; every use here is a thread-safe call (`cancel`).
final class SourceBox: @unchecked Sendable {
    let source: any DispatchSourceProtocol

    init(_ source: any DispatchSourceProtocol) {
        self.source = source
    }

    func cancel() {
        source.cancel()
    }
}

/// A non-blocking socket descriptor with the one rule that keeps descriptors safe: it is closed exactly once, by `SocketReactor`
/// after it left the epoll set (closing a descriptor under a live epoll watch lets a reused number be watched), and no system call
/// runs on it after `close()` began (calls and `close()` take the same lock, and the calls never block).
///
/// `wait(_:timeout:)` is how a call that got `EAGAIN` waits: the reactor re-arms the socket for it (no libdispatch source per wait).
final class SocketDescriptor: Sendable {
    typealias Interest = SocketReactor.Interest

    /// The shared queue of timeouts and handlers elsewhere in the Linux transport (name lookups, the listener, mDNS).
    static let queue = DispatchQueue(label: "com.coreysilvia.CameraBridge.sockets", qos: .userInitiated, attributes: .concurrent)

    private struct State {
        var descriptor: Int32
        var closing = false
    }

    private let state: Mutex<State>
    private let token: UInt64
    private let reactor: SocketReactor

    /// Takes ownership of `descriptor`.
    init(_ descriptor: Int32, reactor: SocketReactor = .shared) {
        state = Mutex(State(descriptor: descriptor))
        self.reactor = reactor
        token = reactor.register(descriptor)
    }

    deinit {
        close()
    }

    var isClosed: Bool { state.withLock { $0.closing } }

    /// Runs `body` with the descriptor, or returns nil when it is closed (or closing). `body` must not block.
    func withDescriptor<T>(_ body: (Int32) -> T) -> T? {
        state.withLock { state in
            guard state.descriptor >= 0, !state.closing else { return nil }
            return body(state.descriptor)
        }
    }

    /// Returns when the descriptor is readable/writable (or has an error or hang-up). Throws `.closed` once `close()` was
    /// called (before or during the wait) and `.timedOut` after `timeout`.
    func wait(_ interest: Interest, timeout: Duration? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = ResumeOnce(continuation)
            let deadline = timeout.map { ContinuousClock.now + $0 }
            let accepted = !isClosed && reactor.wait(token, for: interest, until: deadline) { outcome in
                switch outcome {
                case .ready: once.resume(with: .success(()))
                case .timedOut: once.resume(with: .failure(TransportError.timedOut))
                case .closed: once.resume(with: .failure(TransportError.closed))
                }
            }
            if !accepted { once.resume(with: .failure(TransportError.closed)) }
        }
    }

    /// Idempotent. Pending and later waits throw `.closed`; the peer sees an orderly shutdown.
    func close() {
        let closed = state.withLock { state -> Bool in
            guard !state.closing else { return false }
            state.closing = true
            // A FIN after what was sent. The descriptor itself stays open a little longer (the reactor's linger).
            if state.descriptor >= 0 { _ = shutdown(state.descriptor, Int32(SHUT_WR)) }
            state.descriptor = -1
            return true
        }
        if closed { reactor.close(token: token, linger: Self.lingerLimit) }
    }

    /// How long a closed connection keeps reading and dropping what the peer still sends, waiting for the peer's FIN.
    static let lingerLimit: Duration = .seconds(2)

    static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return .nanoseconds(0) }
        guard seconds < Int64(Int32.max) else { return .never }
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
#endif
