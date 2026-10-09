import Foundation

/// Lets one async operation at a time through, in order of arrival. A decoder or encoder waits for the picture it just fed, so two
/// overlapping calls would take each other's output; `AppleVideoDecoder` gets the same order from its serial work queue.
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer { release() }
        return try await body()
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()   // the next caller inherits `busy`
        }
    }
}
