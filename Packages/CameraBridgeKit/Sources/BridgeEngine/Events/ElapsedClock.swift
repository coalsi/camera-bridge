import Foundation

/// A type-erased `Clock<Duration>` that measures time as the `Duration` elapsed since it was created, so timer logic
/// can store plain durations and tests can inject a manual clock.
struct ElapsedClock: Sendable {
    /// Time elapsed since creation.
    let now: @Sendable () -> Duration
    /// Sleeps until `now()` reaches the given elapsed time (throws `CancellationError` when cancelled).
    let sleep: @Sendable (_ until: Duration) async throws -> Void

    init(_ clock: any Clock<Duration>) {
        self = Self.make(clock)
    }

    private init(now: @escaping @Sendable () -> Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    private static func make<C: Clock>(_ clock: C) -> ElapsedClock where C.Duration == Duration {
        let origin = clock.now
        return ElapsedClock(now: { origin.duration(to: clock.now) },
                            sleep: { deadline in try await clock.sleep(until: origin.advanced(by: deadline), tolerance: nil) })
    }
}
