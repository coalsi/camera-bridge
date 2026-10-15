import Foundation

/// Time arithmetic of the archive. Fragment boundaries are whole milliseconds (the index stores them so); a `Date` from a caller can be a few
/// nanoseconds off a boundary it was computed from (`start + duration`), so every comparison is made in microseconds, rounded.
enum ArchiveTime {
    static func ms(_ date: Date) -> Int64 { clamped(date.timeIntervalSince1970 * 1_000) }
    static func micros(_ date: Date) -> Int64 { clamped(date.timeIntervalSince1970 * 1_000_000) }
    static func date(ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1_000) }

    private static func clamped(_ value: Double) -> Int64 {
        guard value.isFinite else { return value.isNaN ? 0 : (value < 0 ? -9_000_000_000_000_000_000 : 9_000_000_000_000_000_000) }
        return Int64(max(-9e18, min(9e18, value.rounded())))
    }
}

/// One mp4 of the archive: closed (its index was read from the sidecar, or handed over by the recorder) or open (a recorder owns it and its
/// table grows). Never holds the fragment table: that is `CatalogState.openTables` / the table cache.
struct CatalogFile: Sendable, Equatable {
    var camera: UUID
    /// "<camera directory>/<yyyy-MM-dd>/<HH-mm-ss>" (`ArchiveLayout.segment`).
    var segment: String
    var fileKey: String
    /// The file's anchor (`startWallMs`) and the end of its last fragment, in Unix epoch milliseconds.
    var startMs: Int64
    var endMs: Int64
    var initLength: UInt32
    var flags: UInt16
    /// The mp4's size (while open: the end of the last written fragment).
    var mp4Bytes: UInt64
    /// 0 while the file is open.
    var sidecarBytes: UInt64
    var fragmentCount: Int
    /// Per-minute rollups of a closed file; empty while open (activity computes them from the table).
    var rollups: [CBIndexRollup]
    var isOpen: Bool

    var bytes: UInt64 { mp4Bytes + sidecarBytes }
    var hasAudio: Bool { flags & CBIndexFormat.flagHasAudio != 0 }

    init(camera: UUID, segment: String, startMs: Int64, endMs: Int64, initLength: UInt32, flags: UInt16, mp4Bytes: UInt64, sidecarBytes: UInt64,
         fragmentCount: Int, rollups: [CBIndexRollup], isOpen: Bool) {
        self.camera = camera
        self.segment = segment
        self.fileKey = ArchiveIdentity.fileKey(forSegment: segment)
        self.startMs = startMs
        self.endMs = endMs
        self.initLength = initLength
        self.flags = flags
        self.mp4Bytes = mp4Bytes
        self.sidecarBytes = sidecarBytes
        self.fragmentCount = fragmentCount
        self.rollups = rollups
        self.isOpen = isOpen
    }

    /// A closed file from its decoded index.
    init(segment: String, index: CBIndexFile, sidecarBytes: UInt64) {
        self.init(camera: index.camera, segment: segment, startMs: index.startWallMs, endMs: index.endWallMs, initLength: index.initLength,
                  flags: index.flags, mp4Bytes: index.mp4Size, sidecarBytes: sidecarBytes, fragmentCount: index.fragments.count,
                  rollups: index.rollups, isOpen: false)
    }

    /// The end of a file whose last record is `record`, in epoch milliseconds (the arithmetic the recorder writes into the sidecar).
    static func endMs(startMs: Int64, of record: CBIndexFragmentRecord) -> Int64 {
        CBIndexRollups.endWallMs(startWallMs: startMs, last: record)
    }
}

/// A fragment table lookup that may need the table of a closed file read from its sidecar first.
enum CatalogLookup<Value: Sendable>: Sendable {
    case found(Value)
    case notFound
    /// The table of this segment is not in memory: the caller loads it (off the cooperative pool) and asks again.
    case needsTable(segment: String)
}

/// A bounded cache of the decoded fragment tables of closed files (`ArchiveConstants.tableCacheFiles`), least recently used out first.
struct CatalogTableCache: Sendable {
    private var entries: [String: (table: [CBIndexFragmentRecord], used: UInt64)] = [:]
    private var tick: UInt64 = 0
    let capacity: Int

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { entries.count }

    mutating func table(for segment: String) -> [CBIndexFragmentRecord]? {
        guard var entry = entries[segment] else { return nil }
        tick &+= 1
        entry.used = tick
        entries[segment] = entry
        return entry.table
    }

    mutating func insert(_ table: [CBIndexFragmentRecord], for segment: String) {
        tick &+= 1
        entries[segment] = (table, tick)
        while entries.count > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key { entries[oldest] = nil }
    }

    mutating func remove(_ segment: String) { entries[segment] = nil }

    mutating func removeAll() { entries = [:] }
}

/// What the archive knows: every camera's files in start order, the tables of open files, a cache of the tables of closed ones, and the
/// numbers retention and the storage status need. Pure value type: `ArchiveStore` keeps one under a lock and does all disk work outside it.
struct CatalogState: Sendable {
    /// Per camera, sorted by (`startMs`, `segment`). A later position wins an overlap.
    private(set) var files: [UUID: [CatalogFile]] = [:]
    /// The tables of open files (owned by recorders), keyed by segment.
    private(set) var openTables: [String: [CBIndexFragmentRecord]] = [:]
    private var cache = CatalogTableCache(capacity: ArchiveConstants.tableCacheFiles)
    /// Bytes of every file in the catalog (mp4 + sidecar; open files: what is written so far).
    private(set) var usedBytes: UInt64 = 0
    /// `ArchiveReading.catalogVersion`: +1 per written fragment, closed file, deletion and loaded batch.
    private(set) var version = 0

    init() {}

    var isEmpty: Bool { files.isEmpty }
    var fileCount: Int { files.values.reduce(0) { $0 + $1.count } }
    var cameras: [UUID] { Array(files.keys) }
    var cachedTableCount: Int { cache.count }

    mutating func bump() { version += 1 }

    // MARK: Changes

    /// Adds `file`, or replaces the file with the same segment. A closed file may bring its table (kept in the cache).
    mutating func insert(_ file: CatalogFile, table: [CBIndexFragmentRecord]? = nil) {
        var list = files[file.camera] ?? []
        if let existing = list.firstIndex(where: { $0.segment == file.segment }) {
            usedBytes -= min(usedBytes, list[existing].bytes)
            list.remove(at: existing)
        }
        let position = list.firstIndex { Self.precedes(file, $0) } ?? list.count
        list.insert(file, at: position)
        files[file.camera] = list
        usedBytes += file.bytes
        if let table, !file.isOpen { cache.insert(table, for: file.segment) }
    }

    /// Adds the files of a loaded batch, replacing any with the same segment, and counts it once in `version`. Linear in the batch (a folder
    /// of thousands of files is loaded in one call).
    mutating func insert(batch: [CatalogFile]) {
        for (camera, added) in Dictionary(grouping: batch, by: \.camera) {
            let segments = Set(added.map(\.segment))
            var list = files[camera] ?? []
            for file in list where segments.contains(file.segment) { usedBytes -= min(usedBytes, file.bytes) }
            list.removeAll { segments.contains($0.segment) }
            list += added
            list.sort(by: Self.precedes)
            files[camera] = list
            usedBytes += added.reduce(0) { $0 + $1.bytes }
        }
        bump()
    }

    mutating func open(_ file: CatalogFile) {
        insert(file)
        openTables[file.segment] = []
    }

    /// A recorder's fragment is in the file: readers see it from now on.
    mutating func append(_ record: CBIndexFragmentRecord, toSegment segment: String, camera: UUID) {
        // The list leaves the dictionary while it changes, so it is changed in place and not copied.
        guard var list = files.removeValue(forKey: camera) else { return }
        defer { files[camera] = list }
        guard let position = list.firstIndex(where: { $0.segment == segment && $0.isOpen }), openTables[segment] != nil else { return }
        openTables[segment]?.append(record)
        usedBytes -= min(usedBytes, list[position].bytes)
        list[position].fragmentCount = openTables[segment]?.count ?? list[position].fragmentCount
        list[position].endMs = max(list[position].endMs, CatalogFile.endMs(startMs: list[position].startMs, of: record))
        list[position].mp4Bytes = max(list[position].mp4Bytes, record.offset + UInt64(record.length))
        usedBytes += list[position].bytes
        version += 1
    }

    /// The recorder closed the file and wrote its sidecar: the open entry becomes a closed one.
    mutating func close(segment: String, index: CBIndexFile, sidecarBytes: UInt64) {
        openTables[segment] = nil
        insert(CatalogFile(segment: segment, index: index, sidecarBytes: sidecarBytes), table: index.fragments)
        version += 1
    }

    /// Removes the file with this segment (retention, an abandoned open file, a file that vanished). Returns it.
    @discardableResult
    mutating func remove(segment: String, camera: UUID) -> CatalogFile? {
        guard var list = files[camera], let position = list.firstIndex(where: { $0.segment == segment }) else { return nil }
        let removed = list.remove(at: position)
        files[camera] = list.isEmpty ? nil : list
        usedBytes -= min(usedBytes, removed.bytes)
        openTables[segment] = nil
        cache.remove(segment)
        return removed
    }

    mutating func removeAll() {
        files = [:]
        openTables = [:]
        cache.removeAll()
        usedBytes = 0
    }

    mutating func store(table: [CBIndexFragmentRecord], forSegment segment: String) {
        cache.insert(table, for: segment)
    }

    // MARK: Lookups

    func file(camera: UUID, fileKey: String) -> CatalogFile? {
        files[camera]?.first { $0.fileKey == fileKey }
    }

    func file(camera: UUID, segment: String) -> CatalogFile? {
        files[camera]?.first { $0.segment == segment }
    }

    /// The closed files of every camera (retention candidates), and the bytes of the open ones.
    var closedFiles: [CatalogFile] { files.values.flatMap { $0 }.filter { !$0.isOpen } }
    var openFiles: [CatalogFile] { files.values.flatMap { $0 }.filter(\.isOpen) }

    /// The newest start of any file (the clock-jump guard of the age rule).
    var newestStartMs: Int64? { files.values.compactMap { $0.last?.startMs }.max() }

    /// Oldest start and newest end over every camera's files that hold at least one fragment.
    var span: (oldest: Int64, newest: Int64)? {
        var oldest: Int64?
        var newest: Int64?
        for list in files.values {
            for file in list where file.fragmentCount > 0 {
                oldest = min(oldest ?? file.startMs, file.startMs)
                newest = max(newest ?? file.endMs, file.endMs)
            }
        }
        guard let oldest, let newest else { return nil }
        return (oldest, newest)
    }

    func extent(camera: UUID, typicalGOP: TimeInterval?) -> ArchiveExtent? {
        let recorded = (files[camera] ?? []).filter { $0.fragmentCount > 0 }
        guard let first = recorded.first, let newest = recorded.map(\.endMs).max() else { return nil }
        let oldest = recorded.map(\.startMs).min() ?? first.startMs
        return ArchiveExtent(oldest: ArchiveTime.date(ms: oldest), newest: ArchiveTime.date(ms: newest), typicalGOP: typicalGOP)
    }

    /// The end of file `position` as readers see it: its own end, cut where the next file (which wins an overlap) starts.
    func visibleEndMs(camera: UUID, position: Int) -> Int64 {
        guard let list = files[camera], list.indices.contains(position) else { return 0 }
        return position + 1 < list.count ? min(list[position].endMs, list[position + 1].startMs) : list[position].endMs
    }

    /// The files of `camera` that can hold video in `range` (milliseconds), with their visible end, in start order.
    func visibleFiles(camera: UUID, from startMs: Int64, to endMs: Int64) -> [(file: CatalogFile, visibleEndMs: Int64)] {
        guard let list = files[camera] else { return [] }
        var result: [(CatalogFile, Int64)] = []
        for (position, file) in list.enumerated() where file.fragmentCount > 0 && file.startMs < endMs {
            let end = visibleEndMs(camera: camera, position: position)
            if end > startMs && end > file.startMs { result.append((file, end)) }
        }
        return result
    }

    /// The table of `segment` if it is in memory (an open file's, or a cached closed file's).
    mutating func table(forSegment segment: String) -> [CBIndexFragmentRecord]? {
        if let open = openTables[segment] { return open }
        return cache.table(for: segment)
    }

    /// The fragment with `start <= time < end`; nil in a gap. The file that starts last among those that cover `time` wins.
    mutating func fragment(camera: UUID, containingMicros time: Int64) -> CatalogLookup<ArchiveFragment> {
        guard let list = files[camera], let position = lastPosition(in: list, startingAtOrBeforeMicros: time) else { return .notFound }
        let file = list[position]
        guard file.fragmentCount > 0, time < visibleEndMs(camera: camera, position: position) * 1_000 else { return .notFound }
        guard let table = table(forSegment: file.segment) else { return .needsTable(segment: file.segment) }
        guard let index = Self.lastRecord(in: table, of: file, startingAtOrBeforeMicros: time) else { return .notFound }
        return .found(Self.fragment(of: file, table: table, index: index))
    }

    /// The first fragment with `start > time`, crossing gaps and files.
    mutating func fragment(camera: UUID, startingAfterMicros time: Int64) -> CatalogLookup<ArchiveFragment> {
        guard let list = files[camera] else { return .notFound }
        var position = (lastPosition(in: list, startingAtOrBeforeMicros: time) ?? -1)
        // The file the time falls in may still have fragments after it (before the next file starts).
        if position >= 0, list[position].fragmentCount > 0 {
            let file = list[position]
            guard let table = table(forSegment: file.segment) else { return .needsTable(segment: file.segment) }
            let visibleEnd = visibleEndMs(camera: camera, position: position)
            let next = Self.lastRecord(in: table, of: file, startingAtOrBeforeMicros: time).map { $0 + 1 } ?? 0
            if next < table.count, file.startMs + Int64(table[next].wallDeltaMs) < visibleEnd {
                return .found(Self.fragment(of: file, table: table, index: next))
            }
        }
        position += 1
        while position < list.count {
            let file = list[position]
            if file.fragmentCount > 0, visibleEndMs(camera: camera, position: position) > file.startMs {
                guard let table = table(forSegment: file.segment) else { return .needsTable(segment: file.segment) }
                return .found(Self.fragment(of: file, table: table, index: 0))
            }
            position += 1
        }
        return .notFound
    }

    /// Fragment `index` of the file `fileKey` of `camera`, whatever the overlap rule says about its visibility.
    mutating func fragment(camera: UUID, fileKey: String, index: Int) -> CatalogLookup<ArchiveFragment> {
        guard let file = file(camera: camera, fileKey: fileKey), index >= 0, index < file.fragmentCount else { return .notFound }
        guard let table = table(forSegment: file.segment) else { return .needsTable(segment: file.segment) }
        guard index < table.count else { return .notFound }
        return .found(Self.fragment(of: file, table: table, index: index))
    }

    // MARK: Building fragments

    /// Fragment `index` of `file`. Boundaries are whole milliseconds and abut: a fragment ends where the next one of the file starts (the last
    /// one at the file's end), so `fragment.end` is the next fragment's `start` and no time falls between two fragments of a file.
    static func fragment(of file: CatalogFile, table: [CBIndexFragmentRecord], index: Int) -> ArchiveFragment {
        let record = table[index]
        let startMs = file.startMs + Int64(record.wallDeltaMs)
        let endMs = index + 1 < table.count ? file.startMs + Int64(table[index + 1].wallDeltaMs) : max(file.endMs, startMs)
        let keyIndex = max(0, index - Int(record.backToKey))
        let gopStartMs = file.startMs + Int64(table[keyIndex].wallDeltaMs)
        var fragment = ArchiveFragment(camera: file.camera, segment: file.segment, index: index, start: ArchiveTime.date(ms: startMs),
                                       duration: Double(max(0, endMs - startMs)) / 1_000, mediaStart: Int64(record.mediaStart),
                                       hasKeyframe: record.hasKeyframe, gopStart: ArchiveTime.date(ms: gopStartMs), backToKey: Int(record.backToKey),
                                       byteLength: Int(record.length))
        fragment.byteOffset = record.offset
        fragment.headerLength = Int(record.headerLength)
        fragment.keyLength = Int(record.keyLength)
        fragment.nonKeyBytes = Int(record.nonKeyBytes)
        fragment.samples = Int(record.samples)
        return fragment
    }

    private static func precedes(_ lhs: CatalogFile, _ rhs: CatalogFile) -> Bool {
        (lhs.startMs, lhs.segment) < (rhs.startMs, rhs.segment)
    }

    /// The position of the last file whose start is at or before `time` (microseconds).
    private func lastPosition(in list: [CatalogFile], startingAtOrBeforeMicros time: Int64) -> Int? {
        var low = 0, high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle].startMs * 1_000 <= time { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    /// The index of the last record whose start is at or before `time` (microseconds); nil when `time` is before the first.
    private static func lastRecord(in table: [CBIndexFragmentRecord], of file: CatalogFile, startingAtOrBeforeMicros time: Int64) -> Int? {
        var low = 0, high = table.count
        while low < high {
            let middle = (low + high) / 2
            if (file.startMs + Int64(table[middle].wallDeltaMs)) * 1_000 <= time { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }
}
