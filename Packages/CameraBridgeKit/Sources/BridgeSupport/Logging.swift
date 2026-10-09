import Foundation
#if canImport(os)
import os
#endif
import Synchronization

public enum LogLevel: Int, Sendable, Codable, Comparable, CaseIterable {
    case debug, info, notice, warning, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LogEntry: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    public let cameraID: UUID?

    public init(id: UUID = UUID(), date: Date = Date(), level: LogLevel, category: String, message: String, cameraID: UUID? = nil) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
        self.cameraID = cameraID
    }
}

/// Receives every log entry at or above `LogHub.minimumLevel` (e.g. the in-app log viewer).
/// `record` may be called from any thread and must return quickly.
public protocol LogSink: Sendable {
    func record(_ entry: LogEntry)
}

/// Identifies a sink registered with `LogHub.addSink(_:)`, for `LogHub.removeSink(_:)`.
public struct LogSinkToken: Sendable, Hashable {
    let rawValue: UInt64
}

/// Process-wide registry of log sinks and the minimum level (the shared `LogRouter`).
public enum LogHub {
    /// Registers `sink` for every entry at or above `minimumLevel`. Keep the token to remove just this sink.
    @discardableResult
    public static func addSink(_ sink: any LogSink) -> LogSinkToken {
        LogRouter.shared.addSink(sink)
    }

    /// Removes the sink registered with `token` (no-op if it is already gone).
    public static func removeSink(_ token: LogSinkToken) {
        LogRouter.shared.removeSink(token)
    }

    /// Removes every sink (app use; tests remove their own sink by token instead).
    public static func removeAllSinks() {
        LogRouter.shared.removeAllSinks()
    }

    /// Default `.info`.
    public static var minimumLevel: LogLevel {
        get { LogRouter.shared.minimumLevel }
        set { LogRouter.shared.minimumLevel = newValue }
    }
}

/// Sinks and minimum level behind `LogHub`. Internal so tests can route a `Log` to a private router instead of
/// changing process-wide state.
final class LogRouter: Sendable {
    static let shared = LogRouter()

    private struct State {
        var sinks: [(token: LogSinkToken, sink: any LogSink)] = []
        var nextToken: UInt64 = 0
        var minimumLevel: LogLevel = .info
    }

    private let state = Mutex(State())

    init() {}

    @discardableResult
    func addSink(_ sink: any LogSink) -> LogSinkToken {
        state.withLock { state in
            state.nextToken += 1
            let token = LogSinkToken(rawValue: state.nextToken)
            state.sinks.append((token, sink))
            return token
        }
    }

    func removeSink(_ token: LogSinkToken) {
        state.withLock { $0.sinks.removeAll { $0.token == token } }
    }

    func removeAllSinks() {
        state.withLock { $0.sinks.removeAll() }
    }

    var minimumLevel: LogLevel {
        get { state.withLock { $0.minimumLevel } }
        set { state.withLock { $0.minimumLevel = newValue } }
    }

    func dispatch(_ entry: LogEntry) {
        let sinks = state.withLock { $0.sinks.map(\.sink) }
        for sink in sinks { sink.record(entry) }
    }
}

/// Lightweight logger. Writes to the unified log (subsystem `com.coreysilvia.CameraBridge`) where `os` is available
/// and to every `LogHub` sink. Messages must never contain secrets or credentialed URLs; use `Redact`.
public struct Log: Sendable {
    public static let subsystem = "com.coreysilvia.CameraBridge"

    public let category: String
    public let cameraID: UUID?
    private let router: LogRouter
    #if canImport(os)
    private let logger: Logger
    #endif

    public init(category: String, cameraID: UUID? = nil) {
        self.init(category: category, cameraID: cameraID, router: .shared)
    }

    /// A logger that reports to `router` instead of the shared `LogHub` (tests).
    init(category: String, cameraID: UUID? = nil, router: LogRouter) {
        self.category = category
        self.cameraID = cameraID
        self.router = router
        #if canImport(os)
        self.logger = Logger(subsystem: Log.subsystem, category: category)
        #endif
    }

    public func debug(_ message: @autoclosure () -> String) { emit(.debug, message) }
    public func info(_ message: @autoclosure () -> String) { emit(.info, message) }
    public func notice(_ message: @autoclosure () -> String) { emit(.notice, message) }
    public func warning(_ message: @autoclosure () -> String) { emit(.warning, message) }
    public func error(_ message: @autoclosure () -> String) { emit(.error, message) }

    private func emit(_ level: LogLevel, _ message: () -> String) {
        guard level >= router.minimumLevel else { return }
        let text = message()
        #if canImport(os)
        let prefixed = cameraID.map { "[\($0.uuidString.prefix(8))] \(text)" } ?? text
        switch level {
        case .debug: logger.debug("\(prefixed, privacy: .public)")
        case .info: logger.info("\(prefixed, privacy: .public)")
        case .notice: logger.notice("\(prefixed, privacy: .public)")
        case .warning: logger.warning("\(prefixed, privacy: .public)")
        case .error: logger.error("\(prefixed, privacy: .public)")
        }
        #endif
        router.dispatch(LogEntry(level: level, category: category, message: text, cameraID: cameraID))
    }
}
