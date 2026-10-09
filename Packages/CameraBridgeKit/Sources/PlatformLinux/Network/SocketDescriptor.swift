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

/// A non-blocking socket descriptor with the one rule that keeps descriptors safe: it is closed exactly once, only after no
/// readiness source watches it any more (closing a descriptor under a live epoll watch lets a reused number be watched), and
/// no system call runs on it after `close()` began (calls and `close()` take the same lock, and the calls never block).
///
/// `wait(_:timeout:)` is how a call that got `EAGAIN` waits: one readiness source per wait, cancelled when it fires.
final class SocketDescriptor: Sendable {
    enum Interest: Sendable { case readable, writable }

    /// The shared queue of readiness handlers and timeouts: they only resume continuations.
    static let queue = DispatchQueue(label: "com.coreysilvia.CameraBridge.sockets", qos: .userInitiated, attributes: .concurrent)

    private struct State {
        var descriptor: Int32
        var closing = false
        /// Sources watching the descriptor; the descriptor is closed when the last one is gone after `close()`.
        var watchers = 0
        var nextWatcher = 0
        var cancels: [Int: @Sendable () -> Void] = [:]
    }

    private let state: Mutex<State>

    /// Takes ownership of `descriptor`.
    init(_ descriptor: Int32) {
        state = Mutex(State(descriptor: descriptor))
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
            let registered = state.withLock { state -> Bool in
                guard state.descriptor >= 0, !state.closing else { return false }
                let source: any DispatchSourceProtocol = switch interest {
                case .readable: DispatchSource.makeReadSource(fileDescriptor: state.descriptor, queue: Self.queue)
                case .writable: DispatchSource.makeWriteSource(fileDescriptor: state.descriptor, queue: Self.queue)
                }
                let box = SourceBox(source)
                state.nextWatcher += 1
                let id = state.nextWatcher
                state.watchers += 1
                state.cancels[id] = { box.cancel() }
                source.setEventHandler {
                    once.resume(with: .success(()))
                    box.cancel()
                }
                source.setCancelHandler { [self] in
                    once.resume(with: .failure(TransportError.closed))
                    watcherEnded(id)
                }
                if let timeout {
                    Self.queue.asyncAfter(deadline: .now() + Self.dispatchInterval(timeout)) {
                        if once.resume(with: .failure(TransportError.timedOut)) { box.cancel() }
                    }
                }
                source.resume()
                return true
            }
            if !registered { once.resume(with: .failure(TransportError.closed)) }
        }
    }

    private func watcherEnded(_ id: Int) {
        state.withLock { state in
            state.cancels[id] = nil
            state.watchers -= 1
            closeIfUnwatched(&state)
        }
    }

    /// Idempotent. Pending and later waits throw `.closed`; the peer sees an orderly shutdown.
    func close() {
        let cancels = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.closing else { return [] }
            state.closing = true
            // A FIN after what was sent. The descriptor itself stays open a little longer (`lingerThenClose`).
            if state.descriptor >= 0 { _ = shutdown(state.descriptor, Int32(SHUT_WR)) }
            closeIfUnwatched(&state)
            return Array(state.cancels.values)
        }
        for cancel in cancels { cancel() }
    }

    private func closeIfUnwatched(_ state: inout State) {
        guard state.closing, state.watchers == 0, state.descriptor >= 0 else { return }
        Self.lingerThenClose(state.descriptor)
        state.descriptor = -1
    }

    /// How long a closed connection keeps reading and dropping what the peer still sends, waiting for the peer's FIN.
    static let lingerLimit: Duration = .seconds(2)

    /// Closes `descriptor` the way a server closes a connection it is done with: the FIN went out (`close()`), and the descriptor
    /// stays open, its incoming data read and dropped, until the peer's FIN arrives or `lingerLimit` passes. Closing at once
    /// would answer the peer's last segments with a reset, and a reset makes the peer lose what it had received but not yet
    /// read (an acknowledgement sent right before closing).
    private static func lingerThenClose(_ descriptor: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let box = SourceBox(source)
        source.setEventHandler {
            var finished = false
            withUnsafeTemporaryAllocation(byteCount: 4096, alignment: 1) { buffer in
                for _ in 0..<64 {
                    let count = recv(descriptor, buffer.baseAddress, buffer.count, Int32(MSG_DONTWAIT))
                    if count > 0 { continue }
                    if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                    finished = true   // EOF or an error
                    return
                }
            }
            if finished { box.cancel() }
        }
        source.setCancelHandler { _ = Glibc.close(descriptor) }
        queue.asyncAfter(deadline: .now() + dispatchInterval(lingerLimit)) { box.cancel() }
        source.resume()
    }

    static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return .nanoseconds(0) }
        guard seconds < Int64(Int32.max) else { return .never }
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
#endif
