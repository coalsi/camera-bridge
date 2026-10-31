import BridgeSupport
import Foundation

// "Keep this": stretches of a camera's recordings the person chose to keep, that retention never deletes (the evidence of a break-in, a
// parcel that went missing). They are kept in `.kept.json` at the top of the recordings folder, beside `.events` and `.sky`; a file that
// overlaps one stays on the box (it is never moved to the archive drive) and its bytes still count against the box's limits, so the newest
// recordings make room for it. Together they may take at most a quarter of what the box keeps (`KeptRecordings.shareOfMaximum`), so recording
// never pauses because of them. The camera's event days they touch are kept too.

/// One stretch of one camera's recordings the person chose to keep.
public struct KeptRecording: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var camera: UUID
    public var start: Date
    public var end: Date
    /// The person's own words, at most `KeptRecordings.maximumNoteLength` characters.
    public var note: String
    public var created: Date

    public init(id: String, camera: UUID, start: Date, end: Date, note: String, created: Date) {
        self.id = id
        self.camera = camera
        self.start = start
        self.end = end
        self.note = note
        self.created = created
    }

    var startMs: Int64 { ArchiveTime.ms(start) }
    var endMs: Int64 { ArchiveTime.ms(end) }

    /// Whether `camera`'s recording from `startMs` to `endMs` overlaps it.
    func covers(camera: UUID, startMs: Int64, endMs: Int64) -> Bool {
        self.camera == camera && startMs < self.endMs && self.startMs < endMs
    }
}

/// A kept stretch with what it holds now.
public struct KeptRecordingStatus: Sendable, Equatable {
    public var kept: KeptRecording
    /// The bytes of the recording files it keeps (a file counts once, however many stretches touch it).
    public var bytes: UInt64
    /// Whether any recording of it is still there (retention took none, but a file can be lost to a damaged drive).
    public var hasVideo: Bool

    public init(kept: KeptRecording, bytes: UInt64, hasVideo: Bool) {
        self.kept = kept
        self.bytes = bytes
        self.hasVideo = hasVideo
    }
}

/// Why a stretch cannot be kept (or forgotten), in words for the person.
public enum KeptRecordingError: Error, Equatable, Sendable, LocalizedError {
    case noFolder
    case loading
    case badRange
    case tooLong
    case tooMany
    case nothingRecorded
    case noRoom
    case unknown
    case notSaved(String)

    public var errorDescription: String? {
        switch self {
        case .noFolder: "Recording isn’t set up, so there is nothing to keep."
        case .loading: "The recordings are still loading. Try again in a moment."
        case .badRange: "Choose when the stretch to keep begins and ends."
        case .tooLong: "A kept stretch can be at most \(Int(KeptRecordings.maximumLength / 3_600)) hours long. Keep it in parts."
        case .tooMany: "At most \(KeptRecordings.maximumCount) stretches can be kept. Let go of one you no longer need."
        case .nothingRecorded: "There is no recording of this camera then, so there is nothing to keep."
        case .noRoom: "Kept recordings can take at most a quarter of the room for recordings. Let go of one you no longer need, or keep a shorter stretch."
        case .unknown: "That kept recording isn’t there any more."
        case .notSaved(let reason): "The list of kept recordings couldn’t be saved (\(reason))."
        }
    }
}

enum KeptRecordings {
    static let fileName = ".kept.json"
    static let maximumLength: TimeInterval = 24 * 3_600
    static let maximumCount = 200
    static let maximumNoteLength = 200
    /// The most of the box's own limit (`effectiveMaximumBytes`) kept files may take together.
    static let shareOfMaximum = 0.25

    static func url(_ folder: URL) -> URL { folder.appending(path: fileName, directoryHint: .notDirectory) }

    /// What the folder keeps; an empty list when there is no file. A file that does not decode is set aside (`.kept.json.unreadable`) and read as
    /// empty, so the person sees nothing kept rather than a recordings folder that cannot load.
    static func read(folder: URL) -> [KeptRecording] {
        let file = url(folder)
        guard CatalogLoader.attributes(file)?.type == .typeRegular, let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let list = try? decoder.decode([KeptRecording].self, from: data) { return list }
        try? FileManager.default.moveItem(at: file, to: folder.appending(path: fileName + ".unreadable", directoryHint: .notDirectory))
        return []
    }

    static func write(_ list: [KeptRecording], folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try PrivateFiles.write(try encoder.encode(list), to: url(folder))
    }

    /// Whether any of `kept` covers the file.
    static func covers(_ kept: [KeptRecording], camera: UUID, startMs: Int64, endMs: Int64) -> Bool {
        kept.contains { $0.covers(camera: camera, startMs: startMs, endMs: endMs) }
    }

    /// Whether `camera`'s event day starting at `dayStartMs` (UTC) touches any of `kept`.
    static func coversDay(_ kept: [KeptRecording], camera: UUID, dayStartMs: Int64) -> Bool {
        covers(kept, camera: camera, startMs: dayStartMs, endMs: dayStartMs + ArchiveEventLog.dayMs)
    }

    /// The files `kept` covers, each once (on `tier`, or on either drive).
    static func files(_ kept: [KeptRecording], in catalog: CatalogState, tier: StorageTier? = nil) -> [CatalogFile] {
        var seen: Set<String> = []
        var found: [CatalogFile] = []
        for camera in Set(kept.map(\.camera)) {
            for file in catalog.files[camera] ?? [] where (tier == nil || file.tier == tier) && !seen.contains(file.segment) {
                guard covers(kept, camera: camera, startMs: file.startMs, endMs: file.endMs) else { continue }
                seen.insert(file.segment)
                found.append(file)
            }
        }
        return found
    }

    static func bytes(_ kept: [KeptRecording], in catalog: CatalogState, tier: StorageTier? = nil) -> UInt64 {
        files(kept, in: catalog, tier: tier).reduce(0) { $0 + $1.bytes }
    }

    static func newID() -> String {
        String(format: "%08x%08x", UInt32.random(in: .min ... .max), UInt32.random(in: .min ... .max))
    }
}

extension ArchiveStore {
    /// Every kept stretch, newest first, with what it holds now.
    func keptRecordings() async -> [KeptRecordingStatus] {
        state.withLock { state in
            state.kept.sorted { $0.start > $1.start }.map { kept in
                let files = KeptRecordings.files([kept], in: state.catalog)
                return KeptRecordingStatus(kept: kept, bytes: files.reduce(0) { $0 + $1.bytes }, hasVideo: !files.isEmpty)
            }
        }
    }

    /// Keeps `camera`'s recordings from `start` to `end`. Throws `KeptRecordingError`.
    func keep(camera: UUID, start: Date, end: Date, note: String) async throws -> KeptRecordingStatus {
        guard end > start else { throw KeptRecordingError.badRange }
        guard end.timeIntervalSince(start) <= KeptRecordings.maximumLength else { throw KeptRecordingError.tooLong }
        let kept = KeptRecording(id: KeptRecordings.newID(), camera: camera, start: start, end: end,
                                 note: String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(KeptRecordings.maximumNoteLength)), created: tuning.now())
        let (folder, list) = try state.withLock { state -> (URL, [KeptRecording]) in
            guard let folder = state.folder else { throw KeptRecordingError.noFolder }
            guard state.isReady else { throw KeptRecordingError.loading }
            guard state.kept.count < KeptRecordings.maximumCount else { throw KeptRecordingError.tooMany }
            guard KeptRecordings.bytes([kept], in: state.catalog) > 0 else { throw KeptRecordingError.nothingRecorded }
            if let space = state.space, space.total > 0 {
                let limit = ArchiveStorageStatus(totalBytes: space.total, floorBytes: state.floorBytes).effectiveMaximumBytes(maxSizeGB: state.maxSizeGB)
                let allowed = UInt64(Double(limit) * KeptRecordings.shareOfMaximum)
                guard KeptRecordings.bytes(state.kept + [kept], in: state.catalog, tier: .main) <= allowed else { throw KeptRecordingError.noRoom }
            }
            return (folder, state.kept + [kept])
        }
        try await save(list, folder: folder)
        log.info("A stretch of recording is kept from retention")
        return await keptRecordings().first { $0.kept.id == kept.id } ?? KeptRecordingStatus(kept: kept, bytes: 0, hasVideo: false)
    }

    /// Lets retention have that stretch again. Throws `KeptRecordingError`.
    func forgetKept(id: String) async throws {
        let (folder, list) = try state.withLock { state -> (URL, [KeptRecording]) in
            guard let folder = state.folder else { throw KeptRecordingError.noFolder }
            guard state.kept.contains(where: { $0.id == id }) else { throw KeptRecordingError.unknown }
            return (folder, state.kept.filter { $0.id != id })
        }
        try await save(list, folder: folder)
        retentionWake.notify()
    }

    /// Writes the list, then takes it as the store's (the folder must still be the one it was made for).
    private func save(_ list: [KeptRecording], folder: URL) async throws {
        let failure = await onControl { () -> String? in
            do {
                try KeptRecordings.write(list, folder: folder)
                return nil
            } catch {
                return ArchiveErrors.brief(error)
            }
        }
        if let failure { throw KeptRecordingError.notSaved(failure) }
        state.withLock { state in
            if state.folder == folder { state.kept = list }
        }
    }
}
