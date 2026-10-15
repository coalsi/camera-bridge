import BridgeSupport
import Foundation
import Synchronization

/// Runs blocking disk reads on their own threads, `width` at a time, each with a deadline (Mac spec 3 and 7: nothing on the cooperative pool
/// touches the disk). A read that is still waiting for a slot or running when its deadline passes is reported as `ArchiveError.timedOut`;
/// a waiting one is dropped, a running one finishes on its own thread (its result is discarded) and keeps its slot until it returns.
final class ArchiveReadQueue: Sendable {
    private struct Job {
        var id: UInt64
        var start: @Sendable () -> Void
        var fail: @Sendable () -> Void
    }

    private struct State {
        var nextID: UInt64 = 0
        var running = 0
        var waiting: [Job] = []
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "CameraBridge.NVR.reads", qos: .userInitiated, attributes: .concurrent)
    let width: Int
    let deadline: Duration

    init(width: Int = ArchiveConstants.maximumConcurrentReads, deadline: Duration = .seconds(ArchiveConstants.readDeadline)) {
        self.width = max(1, width)
        self.deadline = deadline
    }

    /// Reads (or runs anything blocking) with the queue's width and deadline. Throws `ArchiveError.timedOut` after the deadline, otherwise what
    /// `work` throws.
    func run<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        do {
            return try await withDeadline(deadline) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                    self.submit(Job(id: id, start: { continuation.resume(with: Result { try work() }) },
                                    fail: { continuation.resume(throwing: ArchiveError.timedOut) }))
                }
            }
        } catch is DeadlineExceeded {
            cancel(id)
            throw ArchiveError.timedOut
        }
    }

    /// Jobs running and waiting (tests).
    var load: (running: Int, waiting: Int) { state.withLock { ($0.running, $0.waiting.count) } }

    private func submit(_ job: Job) {
        let startNow = state.withLock { state -> Bool in
            if state.running < width {
                state.running += 1
                return true
            }
            state.waiting.append(job)
            return false
        }
        if startNow { launch(job) }
    }

    private func launch(_ job: Job) {
        queue.async {
            job.start()
            self.finished()
        }
    }

    private func finished() {
        let next = state.withLock { state -> Job? in
            guard !state.waiting.isEmpty else {
                state.running -= 1
                return nil
            }
            return state.waiting.removeFirst()   // the slot passes to the next job
        }
        if let next { launch(next) }
    }

    private func cancel(_ id: UInt64) {
        let dropped = state.withLock { state -> Job? in
            guard let position = state.waiting.firstIndex(where: { $0.id == id }) else { return nil }
            return state.waiting.remove(at: position)
        }
        dropped?.fail()
    }
}

/// The open read handles (at most `ArchiveConstants.maximumOpenReadHandles`), least recently used closed first. A handle stays readable after
/// its file is unlinked, so a player in the middle of a file keeps reading what retention just deleted until the handle is retired.
final class ArchiveHandleCache: Sendable {
    /// One open file. Reads on it are serial (seek, then read); `close` waits for a read in progress.
    private final class Entry: Sendable {
        private let handle: Mutex<FileHandle?>

        init(_ handle: FileHandle) { self.handle = Mutex(handle) }

        /// nil when the entry was closed (evicted) meanwhile.
        func read(offset: UInt64, count: Int) throws -> Data? {
            try handle.withLock { handle -> Data? in
                guard let handle else { return nil }
                return try Self.read(from: handle, offset: offset, count: count)
            }
        }

        func close() {
            handle.withLock { handle in
                try? handle?.close()
                handle = nil
            }
        }

        static func read(from handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
            try handle.seek(toOffset: offset)
            var data = Data()
            data.reserveCapacity(count)
            while data.count < count {
                guard let piece = try handle.read(upToCount: count - data.count), !piece.isEmpty else { break }
                data.append(piece)
            }
            return data
        }
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var order: [String] = []                       // least recently used first
        var retired: [String: ContinuousClock.Instant] = [:]
    }

    private let state = Mutex(State())
    let capacity: Int

    init(capacity: Int = ArchiveConstants.maximumOpenReadHandles) { self.capacity = max(1, capacity) }

    var openCount: Int { state.withLock { $0.entries.count } }

    func isOpen(_ segment: String) -> Bool { state.withLock { $0.entries[segment] != nil } }

    /// `count` bytes at `offset` of the file at `url` (shorter at the end of the file). Opens the file when it is not open (blocking).
    func read(segment: String, url: URL, offset: UInt64, count: Int) throws -> Data {
        let entry = try entry(for: segment, url: url)
        var first: Data?
        var failure: (any Error)?
        do { first = try entry.read(offset: offset, count: count) } catch { failure = error }
        if let first, first.count == count { return first }
        if first != nil || failure != nil {
            // Short or failed: the real end of the file, or a handle gone stale (the volume it was opened on went away and came back, and a stale handle reads
            // nothing or fails for good: the store took that for a damaged file, quarantined it, and the footage stayed unplayable until a restart). Ask again
            // through a new handle; when that does better, the cached one is replaced. When it does not, the first answer stands.
            if let fresh = try? FileHandle(forReadingFrom: url) {
                defer { try? fresh.close() }
                if let again = try? Entry.read(from: fresh, offset: offset, count: count), again.count > (first?.count ?? -1) {
                    replace(segment: segment, stale: entry)
                    return again
                }
            }
            if let failure { throw failure }
            if let first { return first }
        }
        // Closed by an eviction between the lookup and the read: a private handle for this one read.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try Entry.read(from: handle, offset: offset, count: count)
    }

    /// Drops the cached handle `stale` of `segment` (if it is still the cached one) and closes it; the next read opens the file again.
    private func replace(segment: String, stale: Entry) {
        let dropped = state.withLock { state -> Bool in
            guard let current = state.entries[segment], current === stale else { return false }
            state.entries[segment] = nil
            state.order.removeAll { $0 == segment }
            state.retired[segment] = nil
            return true
        }
        if dropped { stale.close() }
    }

    /// Closes the handle of `segment` once `grace` has passed (retention deleted the file; its space is free only when the last handle closes).
    func retire(_ segment: String) {
        state.withLock { state in
            if state.entries[segment] != nil { state.retired[segment] = .now }
        }
    }

    /// Closes the handles retired at least `grace` ago.
    func sweep(grace: Duration) {
        let expired = state.withLock { state -> [Entry] in
            let due = state.retired.filter { $0.value.duration(to: .now) >= grace }.map(\.key)
            var entries: [Entry] = []
            for segment in due {
                state.retired[segment] = nil
                state.order.removeAll { $0 == segment }
                if let entry = state.entries.removeValue(forKey: segment) { entries.append(entry) }
            }
            return entries
        }
        expired.forEach { $0.close() }
    }

    func closeAll() {
        let all = state.withLock { state -> [Entry] in
            let all = Array(state.entries.values)
            state = State()
            return all
        }
        all.forEach { $0.close() }
    }

    private func entry(for segment: String, url: URL) throws -> Entry {
        if let existing = state.withLock({ state -> Entry? in
            guard let entry = state.entries[segment] else { return nil }
            state.order.removeAll { $0 == segment }
            state.order.append(segment)
            return entry
        }) { return existing }
        let opened = Entry(try FileHandle(forReadingFrom: url))   // blocking, outside the lock
        let (entry, evicted) = state.withLock { state -> (Entry, [Entry]) in
            if let existing = state.entries[segment] { return (existing, [opened]) }   // another read opened it first
            state.entries[segment] = opened
            state.order.append(segment)
            state.retired[segment] = nil
            var evicted: [Entry] = []
            while state.entries.count > capacity, let oldest = state.order.first {
                state.order.removeFirst()
                state.retired[oldest] = nil
                if let victim = state.entries.removeValue(forKey: oldest) { evicted.append(victim) }
            }
            return (opened, evicted)
        }
        evicted.forEach { $0.close() }
        return entry
    }
}

/// Recently read fragment bytes, at most `capacity` bytes in all, least recently used out first (the 64 MB cache of Mac spec 7).
struct ArchiveBlockCache: Sendable {
    struct Key: Hashable, Sendable {
        var segment: String
        var offset: UInt64
        var length: Int
    }

    private var entries: [Key: (data: Data, used: UInt64)] = [:]
    private var tick: UInt64 = 0
    private(set) var bytes = 0
    let capacity: Int

    init(capacity: Int = ArchiveConstants.readCacheBytes) { self.capacity = max(0, capacity) }

    var count: Int { entries.count }

    mutating func data(for key: Key) -> Data? {
        guard var entry = entries[key] else { return nil }
        tick &+= 1
        entry.used = tick
        entries[key] = entry
        return entry.data
    }

    mutating func insert(_ data: Data, for key: Key) {
        guard data.count <= capacity else { return }
        if let old = entries[key] { bytes -= old.data.count }
        tick &+= 1
        entries[key] = (data, tick)
        bytes += data.count
        while bytes > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            bytes -= entries[oldest]?.data.count ?? 0
            entries[oldest] = nil
        }
    }

    /// Forgets everything cached for `segment`.
    mutating func remove(segment: String) {
        for key in entries.keys where key.segment == segment {
            bytes -= entries[key]?.data.count ?? 0
            entries[key] = nil
        }
    }

    mutating func removeAll() {
        entries = [:]
        bytes = 0
    }
}

/// How file errors become archive errors, and how they are said in the log (never with a path).
enum ArchiveErrors {
    static func map(_ error: any Error) -> ArchiveError {
        if let archive = error as? ArchiveError { return archive }
        let ns = error as NSError
        let missing = [CocoaError.Code.fileNoSuchFile.rawValue, CocoaError.Code.fileReadNoSuchFile.rawValue]
        if ns.domain == NSCocoaErrorDomain, missing.contains(ns.code) { return .fileGone }
        let posixMissing = [Int(POSIXErrorCode.ENOENT.rawValue), Int(POSIXErrorCode.ENOTDIR.rawValue)]
        if ns.domain == NSPOSIXErrorDomain, posixMissing.contains(ns.code) { return .fileGone }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain, posixMissing.contains(underlying.code) {
            return .fileGone
        }
        return .unreadable("The recordings drive reported an error.")
    }

    /// "file error 513" / "POSIX error 13": enough to look up, nothing that names a file.
    static func brief(_ error: any Error) -> String {
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain ? "POSIX error \(ns.code)" : "error \(ns.code)"
    }
}
