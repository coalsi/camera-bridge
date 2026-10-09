import BridgeSupport
import Foundation

/// Log viewer filtering. Entries arrive newest last (`BridgeEngine.recentLogs`); the viewer shows newest first.
///
/// Every layer of a camera (its runtime, HAP accessory, HomeKit camera controller, HDS and RTSP sessions, and its
/// driver: event channel, camera API and two-way audio) logs with the camera's ID, so the camera page's log
/// (`cameraID`) shows them all; elsewhere (Settings) an entry names its camera (`cameraNames`), in the viewer, the copied
/// text and the search.
struct LogFilter: Equatable {
    var minimumLevel: LogLevel = .debug
    var searchText = ""
    /// Only this camera's entries; nil = all.
    var cameraID: UUID?

    init(minimumLevel: LogLevel = .debug, searchText: String = "", cameraID: UUID? = nil) {
        self.minimumLevel = minimumLevel
        self.searchText = searchText
        self.cameraID = cameraID
    }

    /// `cameraNames`: the configured cameras' names by ID; the search matches an entry's camera name too.
    func apply(to entries: [LogEntry], cameraNames: [UUID: String] = [:]) -> [LogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.reversed().filter { entry in
            entry.level >= minimumLevel
                && (cameraID == nil || entry.cameraID == cameraID)
                && (query.isEmpty || entry.message.localizedStandardContains(query) || entry.category.localizedStandardContains(query)
                    || Self.cameraName(of: entry, in: cameraNames)?.localizedStandardContains(query) == true)
        }
    }

    /// The name of the camera `entry` belongs to, or nil for an engine-wide entry (or one of a camera that is no longer
    /// configured).
    static func cameraName(of entry: LogEntry, in cameraNames: [UUID: String]) -> String? {
        entry.cameraID.flatMap { cameraNames[$0] }
    }

    /// One line per entry, for the pasteboard: "2026-09-30 14:03:12 ERROR [RTSP] Driveway: message" (the camera's name
    /// when `cameraNames` has it).
    static func plainText(_ entries: [LogEntry], cameraNames: [UUID: String] = [:]) -> String {
        let style = Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.colon).dateTimeSeparator(.space)
        return entries.map { entry in
            let camera = cameraName(of: entry, in: cameraNames).map { "\($0): " } ?? ""
            return "\(entry.date.formatted(style)) \(levelName(entry.level).uppercased()) [\(entry.category)] \(camera)\(entry.message)"
        }
        .joined(separator: "\n")
    }

    static func levelName(_ level: LogLevel) -> String {
        switch level {
        case .debug: String(localized: "Debug")
        case .info: String(localized: "Info")
        case .notice: String(localized: "Notice")
        case .warning: String(localized: "Warning")
        case .error: String(localized: "Error")
        }
    }
}
