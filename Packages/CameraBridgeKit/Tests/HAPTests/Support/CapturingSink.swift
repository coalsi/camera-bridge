import BridgeSupport
import Synchronization

/// Collects log entries (this test's sink only; removed by token).
final class CapturingSink: LogSink {
    private let entries = Mutex<[LogEntry]>([])
    func record(_ entry: LogEntry) { entries.withLock { $0.append(entry) } }
    var messages: [String] { entries.withLock { $0.map(\.message) } }
}
