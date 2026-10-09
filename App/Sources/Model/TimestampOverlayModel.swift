import AppKit
import BridgeEngine
import CameraAdapters
import Foundation
import MediaCore
import PlatformApple

/// The camera page's "CameraBridge Timestamp" section, without the views: the live preview (drawn by the renderer the
/// video encoder uses, so the preview is the output) and the wording of the "Hide the camera's own clock" status.
enum TimestampOverlayModel {
    /// The height the preview is drawn at: HomeKit's usual 720p live view. The overlay is sized from the picture's height,
    /// so it looks the same at every resolution the Home app asks for.
    nonisolated static let previewHeight = TimestampOverlayPreview.defaultOutputHeight

    /// `snapshot` with the overlay for `settings` at the Mac time `date`, by `PlatformApple.TimestampOverlayPreview`: the same
    /// renderer and compositor that draw the timestamp on live view and recordings. nil when the picture cannot be converted.
    nonisolated static func preview(snapshot: CGImage, settings: TimestampOverlaySettings, cameraName: String, at date: Date,
                                    locale: Locale = .current, timeZone: TimeZone = .current) -> CGImage? {
        let overlay = TimestampOverlay(settings: settings, cameraName: cameraName, clock: FixedOverlayClock(date))
        return TimestampOverlayPreview.render(image: snapshot, overlay: overlay, at: date, outputHeight: previewHeight, locale: locale, timeZone: timeZone)
    }

    /// Seconds until the next whole second of the Mac's clock (the preview redraws when the time it shows changes).
    nonisolated static func secondsUntilNextSecond(from date: Date) -> Double {
        let fraction = date.timeIntervalSinceReferenceDate - date.timeIntervalSinceReferenceDate.rounded(.down)
        return 1 - fraction + 0.02
    }

    // MARK: Hide the camera's own clock

    /// Under the toggle while the clock is hidden: how, and the case of a clock that was off already.
    nonisolated static func hiddenDescription(_ hidden: HiddenCameraClock) -> String {
        if hidden.wasShown == false { return String(localized: "The camera’s own clock was already off.") }
        return String(localized: "The camera’s own clock is hidden (through \(hidden.method.clockDisplayName)).")
    }

    /// What the toggle says before anything was changed.
    nonisolated static let hideExplanation = String(localized: "Turns off the date and time the camera draws on its own picture, so only the Camera Bridge timestamp shows. It is put back when you turn this off.")

    /// What happened to a request to hide or show the camera's own clock.
    nonisolated static func describe(_ change: CameraClockChange, hiding: Bool) -> String {
        if change.succeeded {
            return hiding ? String(localized: "Hidden (through \(change.method?.clockDisplayName ?? "the camera")).") : String(localized: "Shown again.")
        }
        if change.isUnsupported { return String(localized: "Not supported by this camera.") }
        return String(localized: "Couldn’t change the camera’s clock (\(change.summary)).")
    }
}
