import BridgeEngine
import Foundation

/// What a tile of the NVR page (or the viewer's picture) says when it is not simply showing video. The backdrop is dark, never a live snapshot: a
/// snapshot would be a picture of the wrong time.
enum NVRTileState: Equatable {
    case none
    /// Waiting for the first picture (the view says so after 300 ms).
    case loading
    case noRecording(at: Date?, next: Date?)
    case recordingOff
    case driveMissing
    case unreadable
    /// Live video that is not playing (offline, connecting): the Overview's overlay.
    case live(LiveOverlay)

    /// - Parameters:
    ///   - coverage: what the cell reports.
    ///   - showsPicture: a picture is on screen.
    ///   - recording: the camera's Record state (`CameraStatus.nvr.state`).
    ///   - overlay: `LiveOverlay.current(…)` for the live feed (only used while live).
    ///   - requested: the time the person asked for.
    static func make(coverage: CellCoverage, showsPicture: Bool, recording: ArchiveRecordingState, overlay: LiveOverlay, requested: Date?) -> NVRTileState {
        switch coverage {
        case .live:
            overlay == .none ? .none : .live(overlay)
        case .recorded:
            .none
        case .loading:
            showsPicture ? .none : .loading
        case .noRecording(let next, let off):
            (off || (recording == .off && next == nil)) ? .recordingOff : .noRecording(at: requested, next: next)
        case .driveMissing:
            .driveMissing
        case .unreadable:
            .unreadable
        }
    }

    var title: String? {
        switch self {
        case .none: nil
        case .loading: String(localized: "Loading…")
        case .noRecording: String(localized: "No recording")
        case .recordingOff: String(localized: "Recording is off for this camera")
        case .driveMissing: String(localized: "The recordings drive isn’t connected")
        case .unreadable: String(localized: "Can’t play this recording")
        case .live(let overlay): overlay.title
        }
    }

    var symbol: String {
        switch self {
        case .none: ""
        case .loading: "arrow.triangle.2.circlepath"
        case .noRecording, .recordingOff: "video.slash"
        case .driveMissing: "externaldrive.badge.xmark"
        case .unreadable: "exclamationmark.triangle"
        case .live(let overlay): overlay.symbol
        }
    }

    /// A second line: the time asked for and when recording resumes.
    func detail(timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard case .noRecording(let at, let next) = self else { return nil }
        let style = Date.FormatStyle(date: .omitted, time: .standard, locale: locale, timeZone: timeZone)
        switch (at, next) {
        case (let at?, let next?): return String(localized: "Nothing at \(at.formatted(style)). The next recording is at \(next.formatted(style)).")
        case (let at?, nil): return String(localized: "Nothing at \(at.formatted(style)).")
        case (nil, let next?): return String(localized: "The next recording is at \(next.formatted(style)).")
        case (nil, nil): return nil
        }
    }
}
