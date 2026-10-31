import Foundation

/// Pan, tilt and zoom in steps (`ONVIFPanTilt`, `HikvisionPanTilt`): steps never overlap, and only one waits behind the step under way. A
/// move that comes while one waits takes its place (the newest direction wins, and the older request answers at once), and `dropWaiting()`
/// (the button was let go) drops it, so a held button on a slow camera builds no backlog that keeps turning it after the release.
actor PanTiltSteps {
    private var busy = false
    /// The one move waiting for the step under way: resumed with true to take its step, false when a newer move or a stop replaced it.
    private var waiting: CheckedContinuation<Bool, Never>?

    /// Runs `step` when its turn comes; returns without running it when a newer move or a stop took its place.
    func run(_ step: @Sendable () async throws -> Void) async throws {
        if busy {
            waiting?.resume(returning: false)
            let go = await withCheckedContinuation { waiting = $0 }
            guard go else { return }
            // `busy` was handed over still set.
        } else {
            busy = true
        }
        defer {
            if let next = waiting {
                waiting = nil
                next.resume(returning: true)
            } else {
                busy = false
            }
        }
        try await step()
    }

    /// A step still waiting never starts.
    func dropWaiting() {
        waiting?.resume(returning: false)
        waiting = nil
    }

    /// A camera's definite no: the move or stop was refused (a fault, a 4xx, a refused login), so nothing turned.
    static func isRefusal(_ error: any Error) -> Bool {
        switch error as? CameraAdapterError {
        case .soapFault, .notPermitted: true
        case .httpStatus(let status): (400..<500).contains(status)
        case let error?: error.isLoginRefusal
        case nil: false
        }
    }

    /// `send`s a stop in a task of its own, which a cancelled request cannot cancel (a camera must not be left turning), and once more when
    /// the first got no answer.
    static func stop(_ send: @escaping @Sendable () async throws -> Void) async throws {
        try await Task {
            do {
                try await send()
            } catch where !isRefusal(error) {
                try await send()
            }
        }.value
    }
}
