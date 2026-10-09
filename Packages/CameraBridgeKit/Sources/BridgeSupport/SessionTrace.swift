import Foundation
import Synchronization

/// What happened in one live view or recording session and when: the phases it went through (prepare, start, encoder
/// ready, first video packet, first RTCP, keyframes, …) as offsets from its beginning, and why it ended. Kept by the
/// `DiagnosticsCenter` so a diagnostics bundle shows exactly where a session stalled.
public struct SessionRecord: Sendable, Identifiable, Equatable {
    public struct Phase: Sendable, Equatable {
        public var name: String
        /// Seconds since the session began.
        public var offset: TimeInterval
        public var detail: String?

        public init(name: String, offset: TimeInterval, detail: String? = nil) {
            self.name = name
            self.offset = offset
            self.detail = detail
        }
    }

    public var id: UUID
    /// "live" or "recording".
    public var kind: String
    public var cameraID: UUID?
    public var started: Date
    /// What the session is (size, bit rate, passthrough or transcoded), once known.
    public var summary: String?
    public var phases: [Phase] = []
    public var endReason: String?
    /// Seconds from the start to the end; nil while it runs.
    public var duration: TimeInterval?

    public init(id: UUID, kind: String, cameraID: UUID?, started: Date, summary: String? = nil) {
        self.id = id
        self.kind = kind
        self.cameraID = cameraID
        self.started = started
        self.summary = summary
    }

    /// The offset of the first phase called `name`.
    public func offset(of name: String) -> TimeInterval? { phases.first { $0.name == name }?.offset }

    /// One line: "live 1280×720 transcoded · prepare +0 ms · start +40 ms · first video packet +388 ms · ended (controllerTimeout) +30012 ms".
    public var oneLine: String {
        var parts = ["\(kind) \(id.uuidString.prefix(8))"]
        if let summary { parts.append(summary) }
        for phase in phases {
            parts.append("\(phase.name) +\(Int((phase.offset * 1000).rounded())) ms" + (phase.detail.map { " (\($0))" } ?? ""))
        }
        if let endReason {
            parts.append("ended (\(endReason)) +\(Int(((duration ?? 0) * 1000).rounded())) ms")
        } else {
            parts.append("still running")
        }
        return parts.joined(separator: " · ")
    }
}

/// A session's phases, written as they happen. `mark` keeps the first occurrence of each phase name (later ones, such as
/// every keyframe sent, count into the detail only through the caller); at most `maximumPhases` are kept. `finish` is
/// idempotent: the first reason wins.
public final class SessionTrace: Sendable {
    public static let maximumPhases = 40

    public let id: UUID
    private let center: DiagnosticsCenter
    private let began: ContinuousClock.Instant

    init(id: UUID, kind: String, cameraID: UUID?, summary: String?, center: DiagnosticsCenter, began: ContinuousClock.Instant = .now) {
        self.id = id
        self.center = center
        self.began = began
        center.register(SessionRecord(id: id, kind: kind, cameraID: cameraID, started: Date(), summary: summary))
    }

    private var elapsed: TimeInterval { (ContinuousClock.now - began).timeInterval }

    /// Records that the session reached `phase` now (the first time only).
    public func mark(_ phase: String, _ detail: String? = nil) {
        let offset = elapsed
        center.update(id) { record in
            guard record.endReason == nil, record.phases.count < Self.maximumPhases, !record.phases.contains(where: { $0.name == phase }) else { return }
            record.phases.append(.init(name: phase, offset: offset, detail: detail))
        }
    }

    public func setSummary(_ summary: String) {
        center.update(id) { $0.summary = summary }
    }

    /// Ends the session with `reason` (the first call only).
    public func finish(_ reason: String) {
        let offset = elapsed
        center.update(id) { record in
            guard record.endReason == nil else { return }
            record.endReason = reason
            record.duration = offset
        }
    }
}

/// The process-wide diagnostics: the `DiagnosticsLog` the app installed and the recent sessions' traces (the newest
/// `maximumSessions`, finished or running).
public final class DiagnosticsCenter: Sendable {
    public static let shared = DiagnosticsCenter()
    public static let maximumSessions = 300

    private struct State {
        var records: [UUID: SessionRecord] = [:]
        var order: [UUID] = []
        var log: DiagnosticsLog?
        var token: LogSinkToken?
    }

    private let state = Mutex(State())

    public init() {}

    /// The installed log, nil until `install`.
    public var log: DiagnosticsLog? { state.withLock { $0.log } }

    /// Creates the log in `directory` (nil: memory only), registers it with `LogHub` and turns the minimum level to debug, so
    /// every subsystem's debug lines are kept. Installing again replaces the previous log.
    @discardableResult
    public func install(directory: URL?, memoryCapacity: Int = DiagnosticsLog.defaultMemoryCapacity,
                        fileCount: Int = DiagnosticsLog.defaultFileCount, fileBytes: Int = DiagnosticsLog.defaultFileBytes) -> DiagnosticsLog {
        let log = DiagnosticsLog(directory: directory, memoryCapacity: memoryCapacity, fileCount: fileCount, fileBytes: fileBytes)
        let previous = state.withLock { state -> LogSinkToken? in
            defer {
                state.log = log
                state.token = nil
            }
            return state.token
        }
        if let previous { LogHub.removeSink(previous) }
        let token = LogHub.addSink(log)
        state.withLock { $0.token = token }
        LogHub.minimumLevel = .debug
        return log
    }

    /// Starts tracing a session (its first phase, "begin", is marked at once).
    public func begin(kind: String, id: UUID, cameraID: UUID?, summary: String? = nil, began: ContinuousClock.Instant = .now) -> SessionTrace {
        SessionTrace(id: id, kind: kind, cameraID: cameraID, summary: summary, center: self, began: began)
    }

    /// The recorded sessions, oldest first; `cameraID` limits them to that camera's.
    public func sessions(cameraID: UUID? = nil) -> [SessionRecord] {
        state.withLock { state in
            state.order.compactMap { state.records[$0] }.filter { cameraID == nil || $0.cameraID == cameraID }
        }
    }

    /// Forgets every session (tests).
    public func resetSessions() {
        state.withLock { state in
            state.records.removeAll()
            state.order.removeAll()
        }
    }

    func register(_ record: SessionRecord) {
        state.withLock { state in
            if state.records[record.id] == nil { state.order.append(record.id) }
            state.records[record.id] = record
            while state.order.count > Self.maximumSessions {
                state.records.removeValue(forKey: state.order.removeFirst())
            }
        }
    }

    func update(_ id: UUID, _ change: (inout SessionRecord) -> Void) {
        state.withLock { state in
            guard var record = state.records[id] else { return }
            change(&record)
            state.records[id] = record
        }
    }
}
