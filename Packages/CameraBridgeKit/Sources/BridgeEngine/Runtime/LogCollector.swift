import BridgeSupport
import Foundation
import Synchronization

/// `LogHub` sink behind `BridgeEngine.recentLogs`: buffers the newest entries (any thread, cheap) and signals the
/// engine, which drains them on the main actor at its status rate: `signal` wakes its status loop (while the bridge
/// runs), `logged` its log loop (for as long as the sink is installed: also while paused or after a failed start).
final class LogCollector: LogSink {
    static let capacity = 1000

    private let buffer = Mutex<[LogEntry]>([])
    private let signal: ChangeSignal
    /// Notified with every entry (`ChangeSignal` has one consumer: the engine's log loop).
    let logged = ChangeSignal()

    init(signal: ChangeSignal) {
        self.signal = signal
    }

    /// Entries below this are not kept (the Log Level setting; the diagnostics log keeps everything).
    var minimumLevel: LogLevel {
        get { level.withLock { $0 } }
        set { level.withLock { $0 = newValue } }
    }
    private let level = Mutex(LogLevel.debug)

    func record(_ entry: LogEntry) {
        guard entry.level >= minimumLevel else { return }
        buffer.withLock { entries in
            entries.append(entry)
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }
        signal.notify()
        logged.notify()
    }

    /// Entries recorded since the last drain, oldest first.
    func drain() -> [LogEntry] {
        buffer.withLock { entries in
            defer { entries.removeAll(keepingCapacity: true) }
            return entries
        }
    }
}
