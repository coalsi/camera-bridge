import BridgeEngine
import Foundation

/// The Diagnostics page's motion shadow table (Settings › Diagnostics › "Compare built-in motion detection with camera
/// events"): one row per camera the test applies to, with what built-in motion detection and the camera's own events each saw.
enum MotionShadowTable {
    /// Which totals the table shows.
    enum Span: String, CaseIterable, Identifiable {
        case last24Hours, sinceEnabled

        var id: String { rawValue }

        var title: String {
            switch self {
            case .last24Hours: String(localized: "Last 24 Hours")
            case .sinceEnabled: String(localized: "Since Enabled")
            }
        }
    }

    struct Row: Identifiable, Equatable {
        var id: UUID
        var name: String
        var both: Int
        var cameraOnly: Int
        var builtInOnly: Int
        /// "0.8 s later", "1.2 s earlier", "—".
        var medianDelay: String
        /// "70 %".
        var sensitivity: String
        /// Why the comparison is not running right now, nil while it is.
        var pauseReason: String?
        /// A stretch of motion is being compared right now.
        var eventInProgress: Bool
    }

    /// The rows for the cameras the test applies to (`CameraStatus.motionShadow` is set), in the given order.
    static func rows(_ cameras: [CameraStatus], span: Span) -> [Row] {
        cameras.compactMap { camera in
            guard let shadow = camera.motionShadow else { return nil }
            let totals = span == .last24Hours ? shadow.last24Hours : shadow.sinceEnabled
            var pause: String?
            if case .paused(let reason) = shadow.state { pause = reason }
            return Row(id: camera.id, name: camera.name, both: totals.both, cameraOnly: totals.cameraOnly, builtInOnly: totals.builtInOnly,
                       medianDelay: delayText(totals.medianDelaySeconds), sensitivity: sensitivityText(shadow.sensitivity), pauseReason: pause,
                       eventInProgress: shadow.eventInProgress)
        }
    }

    /// The median start delay of built-in detection against the camera's event, in words.
    static func delayText(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let rounded = (abs(seconds) * 10).rounded() / 10
        if rounded == 0 { return String(localized: "Same time") }
        let value = rounded.formatted(.number.precision(.fractionLength(1)))
        return seconds > 0 ? String(localized: "\(value) s later") : String(localized: "\(value) s earlier")
    }

    static func sensitivityText(_ sensitivity: Double) -> String {
        (min(max(sensitivity, 0), 1)).formatted(.percent.precision(.fractionLength(0)))
    }
}
