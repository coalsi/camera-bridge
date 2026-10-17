import BridgeSupport
import Foundation
import Synchronization

/// The cameras' events beside the recordings: what the router's rising and falling edges say (motion, person, vehicle, doorbell, tamper, …),
/// kept whether or not video is recorded, so the box's Monitor lists every event of the recorded timeline and a restart keeps them.
///
/// Layout: `<recordings>/.events/<CAMERA-UUID>/<yyyy-MM-dd>.jsonl`, one file per camera per day (UTC) of the events' starts, mode 0600 in
/// folders of 0700. The leading dot keeps the folder out of the catalog (`CatalogLoader` skips dot names, and no camera folder can start with one).
/// A file is append-only, one JSON object per line:
///
///     {"camera":"<UUID>","id":"<start ms hex>-<8 hex>","kind":"Motion","start":<ms>,"v":1,"video":true}   an event began
///     {"end":<ms>,"id":"<the same id>","v":1}                                                            it ended (same file)
///
/// `video`: the camera's recorder was writing when it began. A line that does not parse (a torn last line after a crash, a line of a later
/// version) is skipped, and the next append starts on a new line. An event whose end never came (the bridge stopped first) has no end.
/// Retention deletes whole day files, by the recordings' rules (`ArchiveStore.pruneEvents`). Writes run on one serial queue and never wait for
/// a drive; nothing here creates the recordings folder. `.events` and the camera folders are never written, read or pruned through a link.
final class ArchiveEventLog: Sendable {
    static let directoryName = ".events"
    static let fileExtension = "jsonl"
    static let version = 1
    /// The most of one day file a read looks at (the newest part when it is larger).
    static let maximumReadBytes = 16 * 1_048_576
    /// Lines waiting for the drive (a write failed, or writes queue behind a slow drive): beyond this the oldest are dropped.
    static let maximumPending = 1_000
    static let maximumKindLength = 80
    static let dayMs: Int64 = 86_400_000

    /// One line of a day file.
    struct Line: Codable, Equatable, Sendable {
        var v: Int
        var id: String
        var camera: String?
        var kind: String?
        var start: Int64?
        var end: Int64?
        var video: Bool?
    }

    /// An event as stored: what `read` answers before the store adds whether the recordings hold it now.
    struct Stored: Sendable, Equatable {
        var id: String
        var camera: UUID
        var kind: String
        var startMs: Int64
        var endMs: Int64?
        var video: Bool
    }

    private struct Open: Sendable {
        var id: String
        var folder: URL
        var day: String
    }

    private struct Pending: Sendable {
        /// Given in order under the lock: a line leaves the queue by its number once it is written, wherever it is in the queue then.
        var sequence: UInt64
        var folder: URL
        var camera: UUID
        var day: String
        var data: Data
    }

    private struct State {
        /// The events that began and have not ended, by camera and kind.
        var open: [String: Open] = [:]
        /// Lines not on the drive yet, oldest first.
        var pending: [Pending] = []
        var nextSequence: UInt64 = 0
        /// The line being appended now: a new folder or the cap may take it out of `pending` meanwhile, but the cap never counts it as lost.
        var inFlight: UInt64?
        var writing = false
        var dropped = 0
        var failing = false
    }

    /// Appends whole lines to a day file (`ArchiveEventLog.append`; a test may slow it down or make it fail).
    typealias Append = @Sendable (_ data: Data, _ folder: URL, _ camera: UUID, _ day: String) throws -> Void

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "CameraBridge.NVR.events", qos: .utility)
    private let log: ArchiveStoreLog
    private let random: @Sendable () -> UInt32
    private let append: Append

    init(log: ArchiveStoreLog, random: @escaping @Sendable () -> UInt32 = { UInt32.random(in: .min ... .max) },
         append: @escaping Append = { try ArchiveEventLog.append($0, folder: $1, camera: $2, day: $3) }) {
        self.log = log
        self.random = random
        self.append = append
    }

    // MARK: Writing

    /// Records `edges` in `folder` (nil: no place for recordings is chosen, nothing is kept). `video(camera)`: the camera's recorder is writing.
    /// Returns at once; the lines reach the drive on the log's queue.
    func record(_ edges: [EventEdge], folder: URL?, video: (UUID) -> Bool) {
        guard !edges.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var writing: [UUID: Bool] = [:]
        for edge in edges where edge.began && writing[edge.cameraID] == nil { writing[edge.cameraID] = video(edge.cameraID) }
        let schedule = state.withLock { state -> Bool in
            // The place for recordings changed: what waited for the old one is given up, like the old place's events that have not ended.
            if let folder {
                state.pending.removeAll { $0.folder != folder }
                state.open = state.open.filter { $0.value.folder == folder }
            }
            for edge in edges {
                let key = "\(edge.cameraID.uuidString)|\(edge.kind)"
                let ms = ArchiveTime.ms(edge.date)
                let line: Line, target: (folder: URL, day: String)
                if edge.began {
                    guard let folder else { continue }
                    let id = String(format: "%llx-%08x", UInt64(max(0, ms)), random())
                    let day = Self.dayName(ms: ms)
                    state.open[key] = Open(id: id, folder: folder, day: day)
                    line = Line(v: Self.version, id: id, camera: edge.cameraID.uuidString, kind: String(edge.kind.prefix(Self.maximumKindLength)),
                                start: ms, end: nil, video: writing[edge.cameraID] ?? false)
                    target = (folder, day)
                } else {
                    guard let open = state.open.removeValue(forKey: key) else { continue }
                    line = Line(v: Self.version, id: open.id, camera: nil, kind: nil, start: nil, end: ms, video: nil)
                    target = (open.folder, open.day)
                }
                guard var data = try? encoder.encode(line) else { continue }
                data.append(0x0A)
                state.nextSequence += 1
                state.pending.append(Pending(sequence: state.nextSequence, folder: target.folder, camera: edge.cameraID, day: target.day, data: data))
            }
            let excess = state.pending.count - Self.maximumPending
            if excess > 0 {
                // The oldest go, but never the line being written: it reaches the drive, so it is not lost.
                let inFlight = state.inFlight
                var left = excess
                state.pending = state.pending.filter { line in
                    guard left > 0, line.sequence != inFlight else { return true }
                    left -= 1
                    return false
                }
                state.dropped += excess - left
            }
            guard !state.pending.isEmpty, !state.writing else { return false }
            state.writing = true
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// Writes what is pending, in order, until nothing is or a write fails (the rest waits for the next event or `retry`).
    private func drain() {
        while true {
            let next = state.withLock { state -> Pending? in
                guard let first = state.pending.first else {
                    state.writing = false
                    state.inFlight = nil
                    return nil
                }
                state.inFlight = first.sequence
                return first
            }
            guard let next else { return }
            do {
                try append(next.data, next.folder, next.camera, next.day)
                let (recovered, dropped) = state.withLock { state -> (Bool, Int) in
                    // By its number, not its place: while it was written, a new folder may have taken it out of the queue.
                    if let index = state.pending.firstIndex(where: { $0.sequence == next.sequence }) { state.pending.remove(at: index) }
                    state.inFlight = nil
                    defer { state.failing = false; state.dropped = 0 }
                    return (state.failing, state.dropped)
                }
                if recovered || dropped > 0 { log.info("Camera events are written again\(dropped > 0 ? " (\(dropped) were lost)" : "")") }
            } catch {
                let first = state.withLock { state -> Bool in
                    state.writing = false
                    state.inFlight = nil
                    defer { state.failing = true }
                    return !state.failing
                }
                if first { log.warning("Camera events could not be written (\(ArchiveErrors.brief(error))); they wait for the drive") }
                return
            }
        }
    }

    /// Tries the lines that wait again (the janitor calls it every pass).
    func retry() {
        let schedule = state.withLock { state -> Bool in
            guard !state.pending.isEmpty, !state.writing else { return false }
            state.writing = true
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// Lines not written yet (tests).
    var pendingCount: Int { state.withLock { $0.pending.count } }

    /// Waits until the queue has run what was scheduled before (tests).
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in queue.async { continuation.resume() } }
    }

    /// Appends `data` (whole lines) to the day file, making `.events` and the camera's folder when they are missing (never the recordings folder).
    /// When the file does not end in a line break (a torn last line), the new lines start on a line of their own.
    static func append(_ data: Data, folder: URL, camera: UUID, day: String) throws {
        let manager = FileManager.default
        guard folderExists(folder) else { throw CocoaError(.fileNoSuchFile) }
        let events = folder.appending(path: directoryName, directoryHint: .isDirectory)
        let cameraDirectory = events.appending(path: camera.uuidString, directoryHint: .isDirectory)
        for directory in [events, cameraDirectory] {
            switch entryType(directory) {
            case .typeDirectory?:
                continue
            case .none:
                try manager.createDirectory(atPath: ArchiveVolume.path(of: directory), withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            default:
                throw CocoaError(.fileWriteUnknown)   // a file or a link in the way: never written through
            }
        }
        let file = dayFile(folder: folder, camera: camera, day: day)
        let path = file.path(percentEncoded: false)
        switch entryType(file) {
        case .none:
            guard manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        case .typeRegular?:
            break
        default:
            throw CocoaError(.fileWriteUnknown)   // never written through a link
        }
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var bytes = Data()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { bytes.append(0x0A) }
            _ = try handle.seekToEnd()
        }
        bytes.append(data)
        try handle.write(contentsOf: bytes)
    }

    // MARK: Reading

    /// The events of `cameras` that began in `fromMs..<toMs`, newest first, a `page` of at most `limit`; `truncated` when older ones were left
    /// out. Blocking disk work (the store runs it on its read queue). Missing files are no events; a missing recordings folder is not (it throws
    /// `ArchiveUnavailable.folderMissing`), and `.events` or a camera's folder that is a link is never read through.
    static func read(folder: URL, cameras: [UUID], fromMs: Int64, toMs: Int64, limit: Int) throws -> (events: [Stored], truncated: Bool) {
        guard toMs > fromMs, limit > 0, !cameras.isEmpty else { return ([], false) }
        guard folderExists(folder) else { throw ArchiveUnavailable.folderMissing }
        let directory = folder.appending(path: directoryName, directoryHint: .isDirectory)
        guard entryType(directory) == .typeDirectory else { return ([], false) }
        let wanted = Set(cameras).filter { entryType(directory.appending(path: $0.uuidString, directoryHint: .isDirectory)) == .typeDirectory }
        var found: [Stored] = []
        let firstDay = floorDiv(fromMs, dayMs), lastDay = floorDiv(toMs - 1, dayMs)
        var day = lastDay
        // Days newest first: every event of a day began before every event of the days after it, so once what was found makes a page with
        // events left over, older days cannot change the answer.
        while day >= firstDay, day > lastDay - 400 {
            let name = dayName(ms: day * dayMs)
            for camera in wanted {
                let events = parse(dayFile(folder: folder, camera: camera, day: name), camera: camera)
                found += events.filter { $0.startMs >= fromMs && $0.startMs < toMs }
            }
            day -= 1
            if found.count > limit {
                found.sort(by: newestFirst)
                if page(found, limit: limit).count < found.count { break }
            }
        }
        found.sort(by: newestFirst)
        let events = page(found, limit: limit)
        return (events, events.count < found.count)
    }

    /// Newest first; the same moment by camera and id, so a page is the same every time.
    private static func newestFirst(_ a: Stored, _ b: Stored) -> Bool {
        a.startMs != b.startMs ? a.startMs > b.startMs : (a.camera.uuidString, a.id) < (b.camera.uuidString, b.id)
    }

    /// The first `limit` of `sorted` (newest first), never splitting a millisecond: the router stamps every edge of one publication alike (a
    /// ring and its motion, a motion and its person), so the next page, asked with `to` = the oldest start here, must find that moment whole.
    /// When `limit` would cut through one, its events wait for the next page; when they are the whole page, the page holds them all (more than
    /// `limit`), so paging always moves on.
    static func page(_ sorted: [Stored], limit: Int) -> [Stored] {
        guard limit > 0 else { return [] }
        guard sorted.count > limit else { return sorted }
        let boundary = sorted[limit - 1].startMs
        guard sorted[limit].startMs == boundary else { return Array(sorted.prefix(limit)) }
        let before = sorted.prefix { $0.startMs > boundary }
        return before.isEmpty ? Array(sorted.prefix { $0.startMs == boundary }) : Array(before)
    }

    /// The events of one day file, in file order: start lines paired with their end lines by id; lines that do not parse are skipped.
    static func parse(_ file: URL, camera: UUID) -> [Stored] {
        guard let data = readTail(file) else { return [] }
        let decoder = JSONDecoder()
        var events: [Stored] = []
        var position: [String: Int] = [:]
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let line = try? decoder.decode(Line.self, from: Data(raw)), line.v == version, !line.id.isEmpty, line.id.utf8.count <= 40 else { continue }
            if let start = line.start, let kind = line.kind, !kind.isEmpty {
                guard line.camera.flatMap(UUID.init(uuidString:)) == camera, position[line.id] == nil else { continue }
                position[line.id] = events.count
                events.append(Stored(id: line.id, camera: camera, kind: String(kind.prefix(maximumKindLength)), startMs: start, endMs: nil,
                                     video: line.video ?? false))
            } else if let end = line.end, let index = position[line.id], events[index].endMs == nil, end >= events[index].startMs {
                events[index].endMs = end
            }
        }
        return events
    }

    /// The file, or its last `maximumReadBytes` from the first whole line on; nil when it is not a regular file.
    private static func readTail(_ file: URL) -> Data? {
        guard let attributes = CatalogLoader.attributes(file), attributes.type == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard attributes.size > UInt64(maximumReadBytes) else { return try? handle.readToEnd() ?? Data() }
        guard (try? handle.seek(toOffset: attributes.size - UInt64(maximumReadBytes))) != nil,
              let tail = try? handle.read(upToCount: maximumReadBytes) else { return nil }
        guard let firstBreak = tail.firstIndex(of: 0x0A) else { return Data() }
        return tail[tail.index(after: firstBreak)...]
    }

    // MARK: Retention

    /// Deletes the day files whose whole day ended at or before `cutoffMs` (camera folders stay: a write may be making a file in one). Returns how many files went.
    /// Blocking disk work (the store runs it on its control queue). Never follows a link (`.events`, a camera's folder or a day file that is one is
    /// left alone); deletes only regular files named `yyyy-MM-dd.jsonl` in folders named by a camera's UUID.
    static func prune(folder: URL, cutoffMs: Int64, remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> Int {
        let events = folder.appending(path: directoryName, directoryHint: .isDirectory)
        guard entryType(events) == .typeDirectory, let cameras = CatalogLoader.entries(in: events) else { return 0 }
        var removed = 0
        for camera in cameras where !camera.isSymbolicLink && camera.isDirectory && UUID(uuidString: camera.name) != nil {
            guard entryType(camera.url) == .typeDirectory, let files = CatalogLoader.entries(in: camera.url) else { continue }
            for file in files where !file.isSymbolicLink && file.isRegularFile && file.name.hasSuffix("." + fileExtension) {
                let base = String(file.name.dropLast(fileExtension.count + 1))
                guard let dayStart = dayStartMs(base), dayStart + dayMs <= cutoffMs, entryType(file.url) == .typeRegular else { continue }
                if (try? remove(file.url)) != nil { removed += 1 }
            }
        }
        return removed
    }

    // MARK: Names

    static func dayFile(folder: URL, camera: UUID, day: String) -> URL {
        folder.appending(path: directoryName, directoryHint: .isDirectory).appending(path: camera.uuidString, directoryHint: .isDirectory)
            .appending(path: "\(day).\(fileExtension)", directoryHint: .notDirectory)
    }

    private static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!

    /// "2026-10-16": the UTC day of `ms`.
    static func dayName(ms: Int64) -> String {
        ArchiveCameraDirectory.dateDirectoryName(ArchiveTime.date(ms: ms), timeZone: utc)
    }

    /// The start of the UTC day a file name names; nil for any other name.
    static func dayStartMs(_ name: String) -> Int64? {
        guard ArchiveLayout.isDateDirectoryName(name) else { return nil }
        let parts = name.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])), dayName(ms: ArchiveTime.ms(date)) == name else {
            return nil
        }
        return ArchiveTime.ms(date)
    }

    private static func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
        value >= 0 ? value / divisor : -((-value + divisor - 1) / divisor)
    }

    /// The recordings folder is there (a link to one counts: it is the folder the owner chose).
    private static func folderExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// What `url` names, never following a link: lstat of the path without the trailing slash a directory URL has (with one, lstat follows a
    /// link to a directory). Nil when nothing is there.
    static func entryType(_ url: URL) -> FileAttributeType? {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
    }
}

// MARK: - The store's side: recording, reading with what the recordings hold, retention

extension ArchiveStore {
    /// The router's edges, into the current folder's event log (nothing is kept while no folder is chosen).
    func recordEvents(_ edges: [EventEdge], video: (UUID) -> Bool) {
        let folder = state.withLock { $0.folder }
        eventLog.record(edges, folder: folder, video: video)
    }

    /// Only "no place for recordings is chosen" answers no events without looking: a folder that is loading or missing throws
    /// `ArchiveUnavailable` (the Monitor keeps an empty answer for good, so it must never stand in for "cannot say now").
    func events(cameras: [UUID], range: Range<Date>, limit: Int) async throws -> ArchiveEventPage {
        let empty = ArchiveEventPage(events: [], isTruncated: false)
        let folder = try state.withLock { state -> URL? in
            guard let folder = state.folder else { return nil }
            guard state.isReady else { throw ArchiveUnavailable.loading }
            guard state.pause != .folderMissing else { throw ArchiveUnavailable.folderMissing }
            guard !state.readsStalled else { throw ArchiveError.timedOut }
            return folder
        }
        guard let folder, !cameras.isEmpty, limit > 0 else { return empty }
        let fromMs = ArchiveTime.ms(range.lowerBound), toMs = ArchiveTime.ms(range.upperBound)
        let found: (events: [ArchiveEventLog.Stored], truncated: Bool)
        do {
            found = try await reads.run { try ArchiveEventLog.read(folder: folder, cameras: cameras, fromMs: fromMs, toMs: toMs, limit: limit) }
        } catch let error as ArchiveError {
            if error == .timedOut { markReadsStalled() }
            throw error
        }
        let nowMs = ArchiveTime.ms(tuning.now())
        let spans = state.withLock { state in Dictionary(uniqueKeysWithValues: Set(cameras).map { ($0, Self.recordedSpans(camera: $0, in: state.catalog, nowMs: nowMs)) }) }
        let events = found.events.map { stored in
            let covered = Self.covers(spans[stored.camera] ?? [], stored.startMs)
            // Just begun while the recorder writes: the fragment that holds it may not be in the catalog yet.
            let beingWritten = stored.video && stored.startMs >= nowMs - Self.eventLiveGraceMs
            return ArchiveEvent(id: stored.id, camera: stored.camera, kind: stored.kind, start: ArchiveTime.date(ms: stored.startMs),
                                end: stored.endMs.map { ArchiveTime.date(ms: $0) }, hadVideo: stored.video, recorded: covered || beingWritten)
        }
        return ArchiveEventPage(events: events, isTruncated: found.truncated)
    }

    /// An event this new of a camera whose recorder was writing counts as recorded (fragments reach the catalog every 2.5 s, files every 15 min).
    static let eventLiveGraceMs: Int64 = 120_000
    /// An event this little before the first picture of a stretch still counts as recorded (a click plays from 3 s before).
    static let eventLeadMs: Int64 = 3_000

    /// The camera's recorded stretches in milliseconds, merged, in order; an open file reaches to `nowMs`.
    static func recordedSpans(camera: UUID, in catalog: CatalogState, nowMs: Int64) -> [(start: Int64, end: Int64)] {
        let list = catalog.files[camera] ?? []
        var spans: [(start: Int64, end: Int64)] = []
        for (position, file) in list.enumerated() where file.fragmentCount > 0 || file.isOpen {
            let end = file.isOpen ? max(file.endMs, nowMs) : catalog.visibleEndMs(camera: camera, position: position)
            guard end >= file.startMs else { continue }
            spans.append((file.startMs - eventLeadMs, end))
        }
        spans.sort { $0.start < $1.start }
        var merged: [(start: Int64, end: Int64)] = []
        for span in spans {
            if let last = merged.last, span.start <= last.end + Int64(ArchiveConstants.gapThreshold * 1_000) {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    static func covers(_ spans: [(start: Int64, end: Int64)], _ time: Int64) -> Bool {
        var low = 0, high = spans.count
        while low < high {   // the first span that starts after `time`
            let middle = (low + high) / 2
            if spans[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        return low > 0 && time <= spans[low - 1].end
    }

    /// Deletes the event days the recordings' rules let go: days that ended before the keep time (not while the clock looks wrong, like the age
    /// rule), and days before the newest file the size rule deleted. Then writes what waited for the drive.
    func pruneEvents(_ run: ArchiveRun) async {
        let plan = state.withLock { state -> (folder: URL, cutoffMs: Int64)? in
            guard state.isCurrent(run), state.isReady, let folder = state.folder, state.pause != .folderMissing, !state.stalled else { return nil }
            let nowMs = ArchiveTime.ms(tuning.now())
            var cutoff: Int64?
            if !(state.catalog.newestStartMs.map { $0 > nowMs + Int64(ArchiveConstants.futureFileGuard * 1_000) } ?? false) {
                cutoff = nowMs - Int64(state.keepDays) * ArchiveEventLog.dayMs
            }
            if let size = state.eventSizeCutoffMs { cutoff = max(cutoff ?? size, size) }
            return cutoff.map { (folder, $0) }
        }
        eventLog.retry()
        guard let plan else { return }
        let remove = tuning.removeFile
        let removed = await onControl { ArchiveEventLog.prune(folder: plan.folder, cutoffMs: plan.cutoffMs, remove: remove) }
        if removed > 0 { log.info("Deleted \(removed) days of old camera events") }
    }
}

extension NVRCoordinator {
    /// The router's edges (`EventRouter.setEdgeHandler`), with whether each camera's recorder is writing.
    func recordEvents(_ edges: [EventEdge]) {
        let recorders = recorders
        store.recordEvents(edges) { camera in recorders.status(for: camera)?.state == .recording }
    }
}
