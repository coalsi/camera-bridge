import Foundation
import Synchronization

/// The places for saved-clip conversions (`WebApp.processedClip`): at most `limit` ffmpeg children convert a clip at once, box-wide. The
/// clip bar starts one download for each camera ticked, and each conversion decodes, warps and encodes at full speed beside the live
/// transcoders on the box's four cores (a straightened 3840-wide clip warps 3840 × 3408 pictures), so the third waits for a place instead
/// of making everyone slower: the browser shows its download as started and the answer begins when it is the conversion's turn. Places go
/// in the order they were asked for, and a download whose browser went away while it waited leaves the queue and takes none.
final class ConversionSlots: Sendable {
    private struct Waiter {
        var id: Int
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var running = 0
        var most = 0
        var nextID = 0
        var waiters: [Waiter] = []
    }

    private let limit: Int
    private let state = Mutex(State())

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Conversions running now.
    var running: Int { state.withLock { $0.running } }
    /// Conversions waiting for a place.
    var waiting: Int { state.withLock { $0.waiters.count } }
    /// The most conversions that ever ran at once (tests).
    var mostRunning: Int { state.withLock { $0.most } }

    /// `body` with a place of its own: waits for one when `limit` conversions are running, and gives it back when `body` ends or throws.
    /// Throws `CancellationError` (without running `body`) when the caller is cancelled while it waits, or before it asks.
    func run<Value>(_ body: () async throws -> Value) async throws -> Value {
        try await acquire()
        defer { release() }
        return try await body()
    }

    /// Takes a place, waiting for one in line. Every successful call is paired with `release()`.
    func acquire() async throws {
        try Task.checkCancellation()
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case granted, cancelled, queued }
                // One decision under the lock: a cancellation that came first is seen here (the task is flagged before its handler runs),
                // one that comes later finds the waiter queued.
                let outcome = state.withLock { state -> Outcome in
                    if Task.isCancelled { return .cancelled }
                    guard state.running >= limit else {
                        state.running += 1
                        state.most = max(state.most, state.running)
                        return .granted
                    }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    return .queued
                }
                switch outcome {
                case .granted: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .queued: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Gives a place back: the conversion that has waited longest takes it over at once, else it is free.
    func release() {
        let next = state.withLock { state -> Waiter? in
            if !state.waiters.isEmpty { return state.waiters.removeFirst() }
            state.running = max(0, state.running - 1)
            return nil
        }
        next?.continuation.resume()
    }
}
