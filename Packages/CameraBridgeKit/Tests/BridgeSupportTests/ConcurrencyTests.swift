import BridgeSupport
import Foundation
import Synchronization
import Testing

/// A body that ignores cancellation: a continuation without a cancellation handler, resumed after `duration` by a task
/// the caller's cancellation does not reach.
private func ignoringCancellation<T: Sendable>(for duration: Duration, returning value: T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        Task.detached {
            try? await Task.sleep(for: duration)
            continuation.resume(returning: value)
        }
    }
}

private final class Recorder<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>
    init(_ value: Value) { storage = Mutex(value) }
    var value: Value { storage.withLock { $0 } }
    func update(_ change: (inout Value) -> Void) { storage.withLock { change(&$0) } }
}

private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private struct BodyFailed: Error, Equatable {}

/// The package's one deadline race (HAPCamera's delegate calls, BridgeEngine's runtime, CameraAdapters' timeouts).
@Suite(.timeLimit(.minutes(1))) struct DeadlineTests {
    /// Regression: a timeout built on a task group returns only once the body ends (a group always awaits its children).
    @Test func returnsOnTimeWhenTheBodyIgnoresCancellation() async throws {
        let late = Recorder<Result<Int, any Error>?>(nil)
        let started = ContinuousClock.now
        await #expect(throws: DeadlineExceeded(limit: .milliseconds(100))) {
            _ = try await withDeadline(.milliseconds(100), { await ignoringCancellation(for: .seconds(2), returning: 7) },
                                       late: { result in late.update { $0 = result } })
        }
        #expect(ContinuousClock.now - started < .milliseconds(800))
        // The abandoned body finishes on its own; its result is reported as late.
        #expect(await eventually { late.value != nil })
        #expect(try late.value?.get() == 7)
    }

    @Test func abandonedBodyIsCancelled() async {
        let late = Recorder<Result<Int, any Error>?>(nil)
        await #expect(throws: DeadlineExceeded.self) {
            _ = try await withDeadline(.milliseconds(50), { try await Task.sleep(for: .seconds(30)); return 1 },
                                       late: { result in late.update { $0 = result } })
        }
        #expect(await eventually(timeout: .seconds(2)) { late.value != nil })
        #expect(throws: CancellationError.self) { try late.value?.get() }
    }

    @Test func returnsTheBodysResultOrError() async throws {
        let late = Recorder(0)
        #expect(try await withDeadline(.seconds(5), { 42 }, late: { _ in late.update { $0 += 1 } }) == 42)
        await #expect(throws: BodyFailed()) {
            _ = try await withDeadline(.seconds(5), { () async throws -> Int in throw BodyFailed() }, late: { _ in late.update { $0 += 1 } })
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(late.value == 0, "an outcome the caller received is never reported as late")
    }

    @Test func cancellingTheCallerThrowsCancellationErrorAtOnce() async {
        let started = ContinuousClock.now
        let task = Task { try await withDeadline(.seconds(30)) { await ignoringCancellation(for: .seconds(2), returning: 0) } }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .milliseconds(800))
    }

    @Test func anAlreadyCancelledCallerNeverStartsTheBody() async {
        let ran = Recorder(false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await withDeadline(.seconds(30)) { ran.update { $0 = true }; return 0 }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!ran.value)
    }

    /// Teardown (HAPCamera's `.stop`) keeps waiting for the body or the deadline when its caller is cancelled.
    @Test func withoutFollowingCancellationTheCancelledCallerStillGetsTheResult() async throws {
        let task = Task {
            try await withDeadline(.seconds(5), followsCancellation: false) {
                try await Task.sleep(for: .milliseconds(100))
                return 7
            }
        }
        task.cancel()
        #expect(try await task.value == 7)
        let started = ContinuousClock.now
        let bounded = Task {
            try await withDeadline(.milliseconds(100), followsCancellation: false) { await ignoringCancellation(for: .seconds(2), returning: 0) }
        }
        bounded.cancel()
        await #expect(throws: DeadlineExceeded.self) { _ = try await bounded.value }
        #expect(ContinuousClock.now - started < .milliseconds(800))
    }

    @Test func deadlineExceededDescribesTheLimit() {
        #expect(String(describing: DeadlineExceeded(limit: .milliseconds(2500))) == "no answer within 2.5 s")
    }
}

/// The package's one FIFO async lock (HAPCamera's stream services and controller, BridgeEngine's lifecycle operations).
@Suite(.timeLimit(.minutes(1))) struct AsyncSerialLockTests {
    @Test func runsBodiesOneAtATimeInArrivalOrder() async {
        let lock = AsyncSerialLock()
        let log = Recorder<[String]>([])
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<5 {
                group.addTask {
                    await lock.withLock {
                        log.update { $0.append("start \(index)") }
                        try? await Task.sleep(for: .milliseconds(10))
                        log.update { $0.append("end \(index)") }
                    }
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        #expect(log.value == (0..<5).flatMap { ["start \($0)", "end \($0)"] })
    }

    @Test func withLockWaitsEvenWhenTheCallerIsCancelled() async {
        let lock = AsyncSerialLock()
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let holder = Task { await lock.withLock { for await _ in gate {} } }
        #expect(await eventually { lock.isLocked })
        let ran = Recorder(false)
        let teardown = Task { await lock.withLock { ran.update { $0 = true } } }
        #expect(await eventually { lock.waiterCount == 1 })
        teardown.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(lock.waiterCount == 1 && !ran.value)
        open.finish()
        await holder.value
        await teardown.value
        #expect(ran.value)
    }

    @Test func withLockUnlessCancelledLeavesTheQueueWhenCancelled() async {
        let lock = AsyncSerialLock()
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let holder = Task { await lock.withLock { for await _ in gate {} } }
        #expect(await eventually { lock.isLocked })
        let ran = Recorder(false)
        let waiting = Task { await lock.withLockUnlessCancelled { ran.update { $0 = true } } }
        #expect(await eventually { lock.waiterCount == 1 })
        waiting.cancel()
        #expect(await waiting.value == nil)
        #expect(lock.waiterCount == 0 && !ran.value, "a cancelled waiter leaves at once, while the lock is still held")
        open.finish()
        await holder.value
        #expect(await lock.withLockUnlessCancelled { 5 } == 5)
        #expect(!lock.isLocked)
    }

    @Test func throwingBodiesReleaseTheLock() async {
        let lock = AsyncSerialLock()
        await #expect(throws: BodyFailed()) { try await lock.withLock { () async throws(BodyFailed) in throw BodyFailed() } }
        #expect(!lock.isLocked)
        #expect(await lock.withLock { 1 } == 1)
    }

    /// BridgeEngine's operations run on its main actor: the body runs on the caller's actor.
    @MainActor @Test func bodiesRunOnTheCallersActor() async {
        let lock = AsyncSerialLock()
        var count = 0
        await lock.withLock {
            MainActor.assertIsolated()
            count += 1
        }
        _ = await lock.withLockUnlessCancelled {
            MainActor.assertIsolated()
            count += 1
        }
        #expect(count == 2)
    }
}
