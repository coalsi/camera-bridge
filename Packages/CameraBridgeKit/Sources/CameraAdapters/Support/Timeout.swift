import BridgeSupport

/// The drivers' hard bounds: BridgeSupport's `withDeadline` (returns on time even when `body` ignores cancellation; the
/// body is cancelled and abandoned), reporting a missed deadline as `TransportError.timedOut`, which callers and the app
/// already handle ("The connection timed out."). Cancelling the caller throws `CancellationError` at once.
func withTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    do {
        return try await withDeadline(limit, body)
    } catch is DeadlineExceeded {
        throw TransportError.timedOut
    }
}
