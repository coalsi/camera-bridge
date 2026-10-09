import Foundation
import Synchronization

// The package's one deadline race and one FIFO async lock (`package` access: shared by HAP's handler timeout,
// HAPCamera, CameraAdapters, BridgeEngine and `AuthenticatingHTTPClient`, not part of the contract).

/// Thrown by `withDeadline` when its body did not finish within `limit`.
package struct DeadlineExceeded: Error, Equatable, Sendable, CustomStringConvertible {
    package var limit: Duration

    package init(limit: Duration) {
        self.limit = limit
    }

    package var description: String { "no answer within \(String(format: "%.1f", limit.timeInterval)) s" }
}

/// Runs `body` in its own task and returns its result, or throws `DeadlineExceeded` once `limit` passes — on time even
/// when `body` ignores cancellation. Never build a timeout on a task group instead: a group always awaits its children,
/// so it returns only once such a body ends.
///
/// With `followsCancellation` (the default), cancelling the caller throws `CancellationError` at once (an already
/// cancelled caller never starts `body`); without it the caller keeps waiting for `body` or the deadline (teardown that
/// must run). An abandoned body is cancelled and left to finish on its own; `late` then receives what it eventually
/// returns. `late` is never called for an outcome the caller received.
package func withDeadline<T: Sendable>(_ limit: Duration, followsCancellation: Bool = true, _ body: @escaping @Sendable () async throws -> T,
                                       late: @escaping @Sendable (Result<T, any Error>) -> Void = { _ in }) async throws -> T {
    let race = DeadlineRace<T>()
    let run = {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            race.start(continuation, limit: limit, body: body, late: late)
        }
    }
    guard followsCancellation else { return try await run() }
    return try await withTaskCancellationHandler {
        try await run()
    } onCancel: {
        race.settle(.failure(CancellationError()), abandoning: true)
    }
}

/// The body, the timer and the caller's cancellation of one `withDeadline` call: the first outcome resumes the caller;
/// the body's outcome after that is reported as late.
private final class DeadlineRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var outcome: Result<T, any Error>?
        var abandoned = false
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }

    private let state = Mutex(State())

    func start(_ continuation: CheckedContinuation<T, any Error>, limit: Duration, body: @escaping @Sendable () async throws -> T,
               late: @escaping @Sendable (Result<T, any Error>) -> Void) {
        let early = state.withLock { state -> Result<T, any Error>? in
            if let outcome = state.outcome { return outcome }   // the caller was cancelled before it got here
            state.continuation = continuation
            return nil
        }
        if let early {
            continuation.resume(with: early)
            return
        }
        let work = Task {
            let result: Result<T, any Error>
            do {
                result = .success(try await body())
            } catch {
                result = .failure(error)
            }
            if !self.settle(result, abandoning: false) { late(result) }
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self.settle(.failure(DeadlineExceeded(limit: limit)), abandoning: true)
        }
        let settled = state.withLock { state -> (done: Bool, abandoned: Bool) in
            if state.outcome == nil {
                state.work = work
                state.timer = timer
            }
            return (state.outcome != nil, state.abandoned)
        }
        guard settled.done else { return }
        timer.cancel()
        if settled.abandoned { work.cancel() }
    }

    /// Resumes the caller with `result` if nothing did before; true if this call did. `abandoning` cancels the body.
    @discardableResult
    func settle(_ result: Result<T, any Error>, abandoning: Bool) -> Bool {
        let won = state.withLock { state -> (CheckedContinuation<T, any Error>?, Task<Void, Never>?, Task<Void, Never>?)? in
            guard state.outcome == nil else { return nil }
            state.outcome = result
            state.abandoned = abandoning
            defer {
                state.continuation = nil
                state.work = nil
                state.timer = nil
            }
            return (state.continuation, state.work, state.timer)
        }
        guard let (continuation, work, timer) = won else { return false }
        timer?.cancel()
        if abandoning { work?.cancel() }
        continuation?.resume(with: result)
        return true
    }
}

/// FIFO async mutual exclusion: bodies run one at a time, in the order their callers arrived, on the caller's actor.
/// Keeps handler + delegate sequences ordered (HAPCamera's stream services and controller) and lifecycle operations
/// serial (BridgeEngine).
///
/// `withLock` waits even when its caller is cancelled (teardown must run); `withLockUnlessCancelled` leaves the queue as
/// soon as its caller is cancelled and does not run its body then.
package final class AsyncSerialLock: Sendable {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var locked = false
        var nextWaiterID: UInt64 = 0
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    package init() {}

    package func withLock<T, E: Error>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws(E) -> T) async throws(E) -> T {
        _ = await lock(cancellable: false)
        defer { unlock() }
        return try await body()
    }

    /// nil (without running `body`) when the caller is cancelled before or as it gets the lock.
    package func withLockUnlessCancelled<T, E: Error>(isolation: isolated (any Actor)? = #isolation,
                                                      _ body: () async throws(E) -> T) async throws(E) -> T? {
        guard await lock(cancellable: true) else { return nil }
        defer { unlock() }
        guard !Task.isCancelled else { return nil }
        return try await body()
    }

    /// Callers waiting for the lock (tests).
    package var waiterCount: Int { state.withLock { $0.waiters.count } }

    /// Whether a body holds the lock (tests).
    package var isLocked: Bool { state.withLock { $0.locked } }

    /// True once the lock is held; false if a cancellable wait was cancelled (the lock is then not held).
    private func lock(cancellable: Bool) async -> Bool {
        let id = state.withLock { state -> UInt64 in
            state.nextWaiterID &+= 1
            return state.nextWaiterID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let immediate = state.withLock { state -> Bool? in
                    // Checked under the mutex, so a cancellation either sees this waiter or is seen here.
                    if cancellable, Task.isCancelled { return false }
                    guard state.locked else {
                        state.locked = true
                        return true
                    }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            guard cancellable else { return }
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(returning: false)
        }
    }

    private func unlock() {
        let next = state.withLock { state -> Waiter? in
            guard !state.waiters.isEmpty else {
                state.locked = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.continuation.resume(returning: true)
    }
}
