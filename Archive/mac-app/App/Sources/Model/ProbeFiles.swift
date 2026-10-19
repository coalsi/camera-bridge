#if DEBUG
import BridgeEngine
import Foundation

/// Debug builds only: where a measurement run (`-isolatedEngine`) writes what it sees, `<data>/probe/`: `heartbeat.jsonl`, `events.jsonl` (JSON, one object
/// per line) and one `<scenario>.json` per probe scenario. `Tools/nvr_soak_report.py` reads them.
nonisolated struct ProbeFiles: Sendable {
    let directory: URL

    init(directory run: URL) {
        directory = run.appending(path: "probe", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func name(of state: ArchiveRecordingState) -> String {
        switch state {
        case .off: "off"
        case .waiting: "waiting"
        case .recording: "recording"
        case .paused(let pause): "paused:\(pause.code)"
        }
    }

    /// One JSON object per line (the throwing `FileHandle` calls only).
    func append(_ name: String, _ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: Self.safe(object), options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let url = directory.appending(path: "\(name).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    func write(_ name: String, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: Self.safe(object), options: [.sortedKeys, .prettyPrinted]) else { return }
        try? data.write(to: directory.appending(path: "\(name).json"), options: .atomic)
    }

    /// JSON has no NaN or infinity: they become null.
    static func safe(_ value: Any) -> Any {
        switch value {
        case let number as Double: return number.isFinite ? number : NSNull()
        case let dictionary as [String: Any]: return dictionary.mapValues(safe)
        case let array as [Any]: return array.map(safe)
        default: return value
        }
    }

    static func json(_ summary: ProbeSummary?) -> Any {
        guard let s = summary else { return NSNull() }
        return ["count": s.count, "min": s.min, "p50": s.p50, "p95": s.p95, "p99": s.p99, "max": s.max, "mean": s.mean]
    }
}
#endif
