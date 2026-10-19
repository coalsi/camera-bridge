import Foundation

/// Waiting with a hard deadline.
enum TimeLimit {
    /// Runs `operation` and returns when it finishes or when `limit` has passed, whichever comes first. Returns whether
    /// it finished in time. On timeout the operation is cancelled but not awaited, so this returns on time even when the
    /// operation never checks for cancellation (a task group would wait for it: a group always awaits its children).
    @discardableResult
    static func run(_ limit: Duration, _ operation: @escaping @MainActor () async -> Void) async -> Bool {
        let race = Race()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            race.work = Task { @MainActor in
                await operation()
                race.finish(inTime: true)
            }
            race.timer = Task { @MainActor in
                try? await Task.sleep(for: limit)
                race.finish(inTime: false)
            }
        }
    }
}

/// Resumes the caller exactly once, from whichever of the operation and the timer ends first.
@MainActor
private final class Race {
    var continuation: CheckedContinuation<Bool, Never>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?

    func finish(inTime: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        if inTime { timer?.cancel() } else { work?.cancel() }
        continuation.resume(returning: inTime)
    }
}
