import BridgeSupport
import Foundation

/// Which camera's entries the Diagnostics page shows.
enum DiagnosticsCameraScope: Hashable {
    case all
    /// Entries that belong to no camera (the engine, the webhook, the Sensors Bridge).
    case engine
    case camera(UUID)
}

/// The Diagnostics page's filters: minimum level, camera, subsystem (the log category: "LiveStream", "events", "HAP", …) and
/// a search over the message, subsystem and camera name. Entries arrive oldest first; results are newest first.
struct DiagnosticsFilter: Equatable {
    var minimumLevel: LogLevel = .debug
    var camera: DiagnosticsCameraScope = .all
    /// nil: every subsystem.
    var subsystem: String?
    var searchText = ""

    func apply(to entries: [LogEntry], cameraNames: [UUID: String] = [:], limit: Int? = nil) -> [LogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [LogEntry] = []
        for entry in entries.reversed() {
            guard entry.level >= minimumLevel, matches(camera: entry.cameraID), subsystem == nil || entry.category == subsystem else { continue }
            if !query.isEmpty, !(entry.message.localizedStandardContains(query) || entry.category.localizedStandardContains(query)
                                 || LogFilter.cameraName(of: entry, in: cameraNames)?.localizedStandardContains(query) == true) { continue }
            result.append(entry)
            if let limit, result.count >= limit { break }
        }
        return result
    }

    private func matches(camera id: UUID?) -> Bool {
        switch camera {
        case .all: true
        case .engine: id == nil
        case .camera(let wanted): id == wanted
        }
    }

    /// The subsystems that appear in `entries`, sorted.
    static func subsystems(in entries: [LogEntry]) -> [String] {
        Array(Set(entries.map(\.category))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
