import Dispatch
import Foundation
import Synchronization

/// The app's central diagnostics log: every entry of every subsystem and camera at debug level, kept in a bounded ring in
/// memory (`memoryCapacity`) and in rotating files on disk (`fileCount` files of at most `fileBytes`: the newest is
/// `diagnostics.log`, older ones `diagnostics.1.log` … ), so what happened before a restart is still there. Register it
/// as a `LogSink` (`DiagnosticsCenter.install`) and set `LogHub.minimumLevel` to `.debug`.
///
/// Every message is passed through `Redact.string` before it is stored or written (passwords, tokens, URL credentials,
/// RTSP query tokens), whatever the caller did, and lines are cut at `maximumMessageLength` characters. Files are 0600 in
/// a 0700 directory. Writing happens on a background queue: `record` never waits for the disk.
public final class DiagnosticsLog: LogSink, Sendable {
    public static let defaultMemoryCapacity = 20_000
    public static let defaultFileCount = 5
    public static let defaultFileBytes = 2 * 1024 * 1024
    public static let maximumMessageLength = 4_000

    private struct State {
        var ring: [LogEntry] = []
        /// Entries ever recorded (the UI polls it to know whether to refresh).
        var total = 0
    }

    private let memoryCapacity: Int
    private let state = Mutex(State())
    private let writer: RotatingFileWriter?

    /// `directory` nil: memory only. A directory that cannot be created leaves the log in memory only.
    public init(directory: URL?, memoryCapacity: Int = defaultMemoryCapacity, fileCount: Int = defaultFileCount, fileBytes: Int = defaultFileBytes) {
        self.memoryCapacity = max(1, memoryCapacity)
        writer = directory.flatMap { RotatingFileWriter(directory: $0, baseName: "diagnostics", fileCount: max(1, fileCount), fileBytes: max(1_024, fileBytes)) }
    }

    public func record(_ entry: LogEntry) {
        let message = Redact.string(String(entry.message.prefix(Self.maximumMessageLength)))
        let stored = LogEntry(id: entry.id, date: entry.date, level: entry.level, category: entry.category, message: message, cameraID: entry.cameraID)
        state.withLock { state in
            state.ring.append(stored)
            state.total += 1
            // Trim in chunks: amortised constant time per entry.
            if state.ring.count > memoryCapacity + max(64, memoryCapacity / 10) { state.ring.removeFirst(state.ring.count - memoryCapacity) }
        }
        writer?.append(Self.line(for: stored))
    }

    /// The entries in memory, oldest first (at most `memoryCapacity`), redacted.
    public func entries() -> [LogEntry] {
        state.withLock { state in
            state.ring.count > memoryCapacity ? Array(state.ring.suffix(memoryCapacity)) : state.ring
        }
    }

    /// The newest `limit` entries, oldest first.
    public func entries(limit: Int) -> [LogEntry] {
        state.withLock { Array($0.ring.suffix(max(0, limit))) }
    }

    /// How many entries were recorded in all (grows with every `record`).
    public var totalRecorded: Int { state.withLock { $0.total } }

    /// Waits until everything recorded so far is on disk.
    public func flush() { writer?.flush() }

    /// The log files, newest first (those that exist).
    public func fileURLs() -> [URL] { writer?.existingFiles() ?? [] }

    /// The text of the log files from before this run and of this one, oldest first, cut to the last `maximumBytes` bytes.
    public func fileText(maximumBytes: Int = 4 * 1024 * 1024) -> String {
        flush()
        var chunks: [Data] = []
        var total = 0
        for url in fileURLs() {   // newest first
            guard let data = try? Data(contentsOf: url) else { continue }
            chunks.append(data)
            total += data.count
            if total >= maximumBytes { break }
        }
        var data = chunks.reversed().reduce(into: Data()) { $0.append($1) }
        if data.count > maximumBytes { data = data.suffix(maximumBytes) }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Formatting

    /// `2026-10-01T20:22:11.123Z DEBUG [LiveStream] <ABCD1234> message` (single line), where `<…>` is the first 8 characters
    /// of the camera's ID, or `<->` for an engine-wide entry.
    public static func line(for entry: LogEntry, cameraNames: [UUID: String] = [:]) -> String {
        let camera: String
        if let id = entry.cameraID {
            let short = String(id.uuidString.prefix(8))
            camera = cameraNames[id].map { "\($0) (\(short))" } ?? short
        } else {
            camera = "-"
        }
        let text = entry.message.replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
        return "\(timestamp(entry.date)) \(levelName(entry.level)) [\(entry.category)] <\(camera)> \(text)"
    }

    public static func levelName(_ level: LogLevel) -> String {
        switch level {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .warning: "WARNING"
        case .error: "ERROR"
        }
    }

    /// ISO 8601 in UTC with milliseconds.
    public static func timestamp(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.down)
        let milliseconds = Int(((seconds - whole) * 1000).rounded(.down))
        var time = tm()
        var t = time_t(whole)
        gmtime_r(&t, &time)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", Int(time.tm_year) + 1900, Int(time.tm_mon) + 1, Int(time.tm_mday),
                      Int(time.tm_hour), Int(time.tm_min), Int(time.tm_sec), min(999, max(0, milliseconds)))
    }
}

/// Appends lines to `<base>.log` and rotates it at `fileBytes` into `<base>.1.log` … `<base>.<fileCount-1>.log`.
private final class RotatingFileWriter: Sendable {
    private struct State {
        var handle: FileHandle?
        var size = 0
        var failed = false
    }

    private let directory: URL
    private let baseName: String
    private let fileCount: Int
    private let fileBytes: Int
    private let queue = DispatchQueue(label: "CameraBridge.DiagnosticsLog.file", qos: .utility)
    private let state = Mutex(State())

    init?(directory: URL, baseName: String, fileCount: Int, fileBytes: Int) {
        self.directory = directory
        self.baseName = baseName
        self.fileCount = fileCount
        self.fileBytes = fileBytes
        do { try PrivateFiles.prepareDirectory(directory) } catch { return nil }
    }

    func url(_ index: Int) -> URL {
        directory.appending(path: index == 0 ? "\(baseName).log" : "\(baseName).\(index).log")
    }

    func existingFiles() -> [URL] {
        (0..<fileCount).map(url).filter { PrivateFiles.exists($0) }
    }

    func append(_ line: String) {
        queue.async { [self] in write(Data((line + "\n").utf8)) }
    }

    func flush() {
        queue.sync {}
    }

    private func write(_ data: Data) {
        state.withLock { state in
            if state.failed { return }
            do {
                if state.handle == nil { try open(&state) }
                if state.size + data.count > fileBytes, state.size > 0 {
                    try? state.handle?.close()
                    state.handle = nil
                    rotate()
                    try open(&state)
                }
                try state.handle?.write(contentsOf: data)
                state.size += data.count
            } catch {
                state.failed = true   // the disk is full or the directory is gone: memory only from here on
                try? state.handle?.close()
                state.handle = nil
            }
        }
    }

    private func open(_ state: inout State) throws {
        let current = url(0)
        let manager = FileManager.default
        if !manager.fileExists(atPath: current.path(percentEncoded: false)) {
            guard manager.createFile(atPath: current.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: current)
        state.size = Int(try handle.seekToEnd())
        state.handle = handle
    }

    private func rotate() {
        let manager = FileManager.default
        try? manager.removeItem(at: url(fileCount - 1))
        for index in stride(from: fileCount - 2, through: 0, by: -1) where PrivateFiles.exists(url(index)) {
            try? manager.moveItem(at: url(index), to: url(index + 1))
        }
    }
}
