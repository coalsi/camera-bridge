import Foundation
import MediaCore
import Synchronization

/// One camera's timestamp overlay as the running streams see it: the settings and the camera's name, changed in place
/// when the person edits them (position, size, text options take effect on the next picture, no restart; turning the
/// overlay on or off changes the video path and restarts the camera's runtime instead). Live view and recording ask a
/// per-hub `provider(for:)`, whose clock turns each picture's `wallClock` into the Mac's time with the offset that hub
/// measured (`MediaHub.wallClockOffset`).
final class TimestampOverlayControl: Sendable {
    private struct State {
        var settings: TimestampOverlaySettings
        var cameraName: String
    }

    private let state: Mutex<State>

    init(settings: TimestampOverlaySettings, cameraName: String) {
        state = Mutex(State(settings: settings, cameraName: cameraName))
    }

    var settings: TimestampOverlaySettings { state.withLock { $0.settings } }

    /// Whether the overlay is on: video must then be transcoded (`MediaFit`).
    var isEnabled: Bool { state.withLock { $0.settings.enabled } }

    func update(settings: TimestampOverlaySettings, cameraName: String) {
        state.withLock { $0 = State(settings: settings, cameraName: cameraName) }
    }

    /// The overlay for pictures that came through `hub`.
    func provider(for hub: MediaHub) -> any TimestampOverlayProviding {
        HubProvider(control: self, clock: OffsetOverlayClock(offset: { hub.wallClockOffset }))
    }

    private struct HubProvider: TimestampOverlayProviding {
        let control: TimestampOverlayControl
        let clock: OffsetOverlayClock

        var current: TimestampOverlay? {
            let snapshot = control.state.withLock { $0 }
            guard snapshot.settings.enabled else { return nil }
            return TimestampOverlay(settings: snapshot.settings, cameraName: snapshot.cameraName, clock: clock)
        }
    }
}
