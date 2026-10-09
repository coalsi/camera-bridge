import AppKit
import SwiftUI

/// Reports whether the window it sits in can be seen to `WindowActivity.shared`: on screen (not minimised, not closed, not
/// entirely covered by other windows, the app not hidden) and whether the app is frontmost. Pictures are fetched only for
/// a window somebody can look at.
struct WindowVisibilityObserver: NSViewRepresentable {
    var activity: WindowActivity = .shared

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.activity = activity
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.activity = activity
    }

    static func dismantleNSView(_ view: TrackingView, coordinator: ()) {
        view.stopObserving()
        view.activity.update(.hidden)   // the window is gone
    }

    final class TrackingView: NSView {
        var activity: WindowActivity = .shared
        private var observers: [any NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else {
                activity.update(.hidden)
                return
            }
            let center = NotificationCenter.default
            let windowNames: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                                    NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                                                    NSWindow.didChangeScreenNotification]
            for name in windowNames {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            let appNames: [Notification.Name] = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                                                 NSApplication.didHideNotification, NSApplication.didUnhideNotification]
            for name in appNames {
                observers.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }

        func stopObserving() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }

        private func report() {
            guard let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible), !NSApp.isHidden else {
                activity.update(.hidden)
                return
            }
            activity.update(NSApp.isActive ? .active : .backgrounded)
        }
    }
}
