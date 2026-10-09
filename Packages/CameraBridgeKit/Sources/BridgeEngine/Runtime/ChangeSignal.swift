import Foundation
import Synchronization

/// A coalescing change signal: `notify()` from anywhere, `wait(timeout:)` from one consumer returns at the next
/// notification (or at once if one is pending) or after `timeout`.
final class ChangeSignal: Sendable {
    private struct State {
        var pending = false
        var waiter: (id: UInt64, continuation: CheckedContinuation<Void, Never>)?
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    func notify() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let waiter = state.waiter else {
                state.pending = true
                return nil
            }
            state.waiter = nil
            return waiter.continuation
        }
        waiter?.resume()
    }

    /// Returns when notified, after `timeout`, or when the task is cancelled.
    func wait(timeout: Duration) async {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resume(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.pending || Task.isCancelled {
                        state.pending = false
                        return true
                    }
                    state.waiter = (id, continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            resume(id)
        }
        timer.cancel()
    }

    private func resume(_ id: UInt64) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let waiter = state.waiter, waiter.id == id else { return nil }
            state.waiter = nil
            return waiter.continuation
        }
        waiter?.resume()
    }
}
