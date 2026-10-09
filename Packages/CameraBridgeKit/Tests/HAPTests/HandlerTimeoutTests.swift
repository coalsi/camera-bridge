import Foundation
import Synchronization
import Testing
@testable import HAP

/// A handler body that ignores cancellation: a continuation resumed after `duration` by a task cancellation does not reach.
private func ignoringCancellation<T: Sendable>(for duration: Duration, returning value: T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        Task.detached {
            try? await Task.sleep(for: duration)
            continuation.resume(returning: value)
        }
    }
}

/// Review finding (W4 BridgeSupport): HAP's handler timeout was a second hand-built deadline race next to
/// BridgeSupport's `withDeadline` (the package's one), and unlike it ignored the caller's cancellation. It is now built on
/// `withDeadline`, following the caller's cancellation.
@Suite(.timeLimit(.minutes(1))) struct HandlerTimeoutTests {
    @Test func returnsTheHandlersValueOrStatus() async throws {
        let value = try await HandlerTimeout.run(warning: .seconds(5), timeout: .seconds(10), description: "Read") { () async throws(HAPStatus) -> Int in 7 }
        #expect(value == 7)
        await #expect(throws: HAPStatus.resourceBusy) {
            try await HandlerTimeout.run(warning: .seconds(5), timeout: .seconds(10), description: "Read") { () async throws(HAPStatus) -> Int in
                throw .resourceBusy
            }
        }
    }

    @Test func answersOnTimeAndCancelsAHandlerThatMissesTheTimeout() async throws {
        let cancelled = Mutex(false)
        let started = ContinuousClock.now
        await #expect(throws: HAPStatus.operationTimedOut) {
            try await HandlerTimeout.run(warning: .milliseconds(50), timeout: .milliseconds(150), description: "Write") { () async throws(HAPStatus) -> Int in
                do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.withLock { $0 = true } }
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        var observed = false
        for _ in 0..<100 where !observed {
            observed = cancelled.withLock { $0 }
            if !observed { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(observed, "the abandoned handler was not cancelled")
    }

    @Test func answersOnTimeWhenTheHandlerIgnoresCancellation() async throws {
        let started = ContinuousClock.now
        await #expect(throws: HAPStatus.operationTimedOut) {
            try await HandlerTimeout.run(warning: .milliseconds(50), timeout: .milliseconds(150), description: "Snapshot") { () async throws(HAPStatus) -> Int in
                await ignoringCancellation(for: .seconds(3), returning: 1)
            }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func followsTheCallersCancellation() async throws {
        let request = Task {
            try await HandlerTimeout.run(warning: .seconds(20), timeout: .seconds(30), description: "Read") { () async throws(HAPStatus) -> Int in
                await ignoringCancellation(for: .seconds(4), returning: 1)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = ContinuousClock.now
        request.cancel()
        let result = await request.result
        #expect(ContinuousClock.now - cancelledAt < .seconds(2), "the cancelled request kept waiting for its handler")
        #expect(throws: HAPStatus.operationTimedOut) { try result.get() }
    }
}
