import BridgeEngine
import Foundation

/// Which stream the camera page's live picture and the single-camera viewer read (the small quality menu).
enum LiveQuality: String, CaseIterable, Identifiable {
    /// The main stream, unless it is taller than 1440 px and the picture is shown small: then the sub stream.
    case automatic
    /// Always the main stream: the camera's full picture.
    case main
    /// Always the sub stream: less bandwidth and decoding.
    case sub

    var id: String { rawValue }

    var stream: LiveVideoStream {
        switch self {
        case .automatic: .automatic
        case .main: .main
        case .sub: .sub
        }
    }

    /// The stream the engine reads, for the "Main stream · 2688×1520" caption.
    static func caption(stream: LiveVideoStream?, status: CameraStatus) -> String? {
        guard let stream, stream != .automatic else { return nil }
        let info = stream == .sub ? status.subStreamInfo : status.mainStreamInfo
        let name = stream == .sub ? String(localized: "Sub stream") : String(localized: "Main stream")
        return info.map { "\(name) · \($0.width)×\($0.height)" } ?? name
    }
}

/// Where a saved snapshot goes by default and what it is called ("Driveway 2026-10-02 at 14.35.20.jpg").
enum SnapshotFileName {
    static func make(cameraName: String, date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d-%02d-%02d at %02d.%02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let forbidden = CharacterSet(charactersIn: "/:\\\0")
        let name = cameraName.components(separatedBy: forbidden).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name.isEmpty ? "Camera" : name) \(stamp).jpg"
    }
}
