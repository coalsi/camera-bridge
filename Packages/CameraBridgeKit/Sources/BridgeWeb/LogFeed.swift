import BridgeSupport
import Foundation
import Synchronization

/// The engine's recent log for the web interface: a bounded ring of entries (redacted, like the diagnostics log) and a live
/// feed for the page's log view. Register it with `LogHub.addSink` (the daemon does); entries below `minimumLevel` are dropped,
/// so a debug-level hub does not push the interesting lines out of the ring.
public final class LogFeed: LogSink, Sendable {
    public static let maximumMessageLength = 2_000

    private let capacity: Int
    private let minimumLevel: LogLevel
    private let ring = Mutex<[LogEntry]>([])
    private let broadcaster = AsyncBroadcaster<LogEntry>(bufferingNewest: 512)

    public init(capacity: Int = 2_000, minimumLevel: LogLevel = .info) {
        self.capacity = max(10, capacity)
        self.minimumLevel = minimumLevel
    }

    public func record(_ entry: LogEntry) {
        guard entry.level >= minimumLevel else { return }
        let stored = LogEntry(id: entry.id, date: entry.date, level: entry.level, category: entry.category,
                              message: Redact.string(String(entry.message.prefix(Self.maximumMessageLength))), cameraID: entry.cameraID)
        ring.withLock { ring in
            ring.append(stored)
            if ring.count > capacity + max(32, capacity / 10) { ring.removeFirst(ring.count - capacity) }
        }
        broadcaster.yield(stored)
    }

    /// The newest `limit` entries at or above `level`, oldest first; `since` keeps only later ones.
    public func recent(limit: Int = 200, since: Date? = nil, level: LogLevel = .info) -> [LogEntry] {
        let matching = ring.withLock { ring in
            ring.filter { entry in entry.level >= level && (since.map { entry.date > $0 } ?? true) }
        }
        return Array(matching.suffix(max(0, limit)))
    }

    /// Entries recorded from now on.
    public func subscribe() -> AsyncStream<LogEntry> {
        broadcaster.subscribe()
    }

    public var count: Int { ring.withLock { $0.count } }
}
