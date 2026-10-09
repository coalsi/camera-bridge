import Foundation
import Observation

/// Whether anybody can see the manager window right now, so the app fetches pictures only for someone who can look at them.
///
/// Every refresh of a camera picture that the camera's snapshot API cannot serve costs a decoded keyframe (a 4K one on
/// some cameras), so pictures are refreshed only while the manager window is on screen; the log of 2026-10-02 showed a
/// keyframe decoded for each of four cameras every 10 s for hours, with nobody looking. The window reports its state
/// (`WindowVisibilityObserver`): hidden (minimised, closed, covered by other windows, the app hidden), visible while
/// another app is frontmost (`backgrounded`), or frontmost (`active`).
@MainActor
@Observable
final class WindowActivity {
    enum State: Equatable, Sendable {
        /// Nobody can see the window.
        case hidden
        /// On screen, but another app is in front: the picture may be glanced at, not watched.
        case backgrounded
        /// On screen and frontmost.
        case active
    }

    /// The one the app's views share. Starts `active`: a window that never reports (previews, tests) keeps refreshing.
    static let shared = WindowActivity()

    private(set) var state: State = .active
    @ObservationIgnored private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var nextWaiter: UInt64 = 0

    init(state: State = .active) {
        self.state = state
    }

    var isVisible: Bool { state != .hidden }

    func update(_ new: State) {
        guard new != state else { return }
        state = new
        guard new != .hidden else { return }
        let ready = waiters
        waiters = [:]
        for waiter in ready.values { waiter.resume() }
    }

    /// Returns at once while the window is visible; while it is hidden, when it becomes visible (or the task is cancelled).
    /// Nothing polls: a hidden window costs the app no wake-ups.
    func waitUntilVisible() async {
        guard !isVisible else { return }
        nextWaiter &+= 1
        let id = nextWaiter
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isVisible || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.resume() }
        }
    }
}

/// How often a picture is refreshed: by what it is (the camera page's large picture, a sidebar thumbnail) and by whether
/// the window is frontmost.
enum SnapshotRefreshPolicy {
    /// The camera page's picture.
    static let heroInterval: Duration = .seconds(10)
    static let heroMinimumInterval: TimeInterval = 8
    /// Sidebar thumbnails: a glance, not a live view.
    static let thumbnailInterval: Duration = .seconds(45)
    static let thumbnailMinimumInterval: TimeInterval = 40
    /// With another app in front the picture is only kept from going stale.
    static let backgroundedInterval: Duration = .seconds(120)

    /// The wait before the next refresh of a picture refreshed every `base` while the window is frontmost; nil while nobody can
    /// see it (nothing is fetched).
    static func wait(base: Duration, state: WindowActivity.State) -> Duration? {
        switch state {
        case .hidden: nil
        case .backgrounded: max(base, backgroundedInterval)
        case .active: base
        }
    }
}
