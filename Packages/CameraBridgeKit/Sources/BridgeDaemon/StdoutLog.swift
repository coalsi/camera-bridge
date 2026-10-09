import BridgeSupport
import Foundation
import Synchronization

/// Writes the engine's log to standard output, one line per entry: what `journalctl -u camerabridged` shows. Under systemd with the
/// journal (`JOURNAL_STREAM` is set) a line carries its priority as `<n>` (syslog levels, which journald understands) and no
/// timestamp (the journal has its own); otherwise it is the diagnostics log's line with an ISO 8601 timestamp. Messages are
/// redacted again here, whatever the caller did.
public final class StdoutLogSink: LogSink, Sendable {
    private let minimumLevel: LogLevel
    private let journal: Bool
    private let write: @Sendable (String) -> Void
    private let lock = Mutex(())

    /// `write` receives each finished line including its newline (standard output by default; tests collect them).
    public init(minimumLevel: LogLevel, journal: Bool, write: (@Sendable (String) -> Void)? = nil) {
        self.minimumLevel = minimumLevel
        self.journal = journal
        self.write = write ?? { line in
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }

    public func record(_ entry: LogEntry) {
        guard entry.level >= minimumLevel else { return }
        let line = format(entry)
        lock.withLock { _ in write(line + "\n") }
    }

    func format(_ entry: LogEntry) -> String {
        let redacted = LogEntry(id: entry.id, date: entry.date, level: entry.level, category: entry.category,
                                message: Redact.string(String(entry.message.prefix(4_000))), cameraID: entry.cameraID)
        guard journal else { return DiagnosticsLog.line(for: redacted) }
        let text = redacted.message.replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
        let camera = redacted.cameraID.map { " <\($0.uuidString.prefix(8))>" } ?? ""
        return "<\(Self.priority(redacted.level))>[\(redacted.category)]\(camera) \(text)"
    }

    /// syslog(3) priorities: 3 error, 4 warning, 5 notice, 6 info, 7 debug.
    static func priority(_ level: LogLevel) -> Int {
        switch level {
        case .error: 3
        case .warning: 4
        case .notice: 5
        case .info: 6
        case .debug: 7
        }
    }
}

/// A line the daemon writes itself, outside the engine's `Log` (before logging is set up, and fatal errors).
enum Console {
    static func print(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
