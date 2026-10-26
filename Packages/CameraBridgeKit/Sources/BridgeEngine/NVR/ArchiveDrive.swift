import BridgeSupport
import Foundation

// The archive drive (archive-tier brief): a second drive where older recordings move when the recordings drive fills, instead of being deleted.
// The host names its folder (`BridgeEnvironment.archiveDriveFolder`: /var/lib/camera-bridge/archive on the box, where `cb-recording-drive
// --archive` mounts it); the store probes it, loads what is on it, moves files there (`ArchiveMover+Store.swift`) and runs its own retention.
//
// Layout on the drive: the recordings folder's own (`<camera directory>/camera.json`, `<camera directory>/<yyyy-MM-dd>/<HH-mm-ss>.mp4` +
// `.cbidx`), so a file keeps its segment, file key and fragment ids when it moves; `.camera-bridge-archive` at the top (written by the OS as root:
// `{"uuid": "<file system UUID>"}`) says the drive is mounted. A folder without it (the drive is not plugged in, the read-only placeholder, a bare
// folder on the box's own disk) is never written. The Sky Watcher's log and the cameras' events never move: they stay in the recordings folder.

/// The archive drive's part of `ArchiveStoreState`.
struct ArchiveDriveState: Sendable {
    enum Connection: Sendable, Equatable {
        /// Not probed yet (at start, and after the recordings folder changed).
        case unknown
        case connected
        /// No drive there (no marker): not plugged in, or not chosen.
        case away
        /// A marker, but the folder is on the box's own disk or on the recordings drive: not the archive drive, never read or written.
        case refused(String)
    }

    var folder: URL?
    var connection = Connection.unknown
    var driveID: String?
    var space: VolumeMonitor.Space?
    var floorBytes: UInt64 = 0
    var probeStartedAt: ContinuousClock.Instant?
    /// A probe pending for `probeStallAfter`: nothing moves and archive reads fail at once until one answers.
    var stalled = false
    var readsStalled = false
    var needsWriteTest = true
    /// The last write test failed (the drive is readable but refuses writes, as ext4 does after an error): its recordings still play, nothing moves.
    var writeProblem: String?
    /// Its files were read since it connected (`loadGeneration`); moves and its retention wait for that.
    var loaded = false
    var loadGeneration = 0
    /// Moves that failed on the archive's side, in a row; after `ArchiveDriveState.failureLimit` the drive counts as failing for a while.
    var failures = 0
    var failingUntil: Date?
    /// The file being moved now.
    var moving: (segment: String, move: ArchiveDriveStatus.Move)?
    /// What the last retention pass planned to move, oldest first (the mover takes them one at a time).
    var plannedMoves: [RetentionCandidate] = []
    /// Files of the box that are not moved again (their move failed on their side), until the folder is loaded again.
    var unmovable: Set<String> = []
    /// Archive files retention could not delete (tried once).
    var removalFailed: Set<String> = []
    /// Moved files whose copy on the box is not deleted yet (segment: the box's file as the catalog had it before the move): it goes once the
    /// archive's copy was found whole, tried again on every pass while it could not be deleted or the drive was away.
    var pendingMainRemovals: [String: CatalogFile] = [:]
    /// After a failed deletion of such a copy, or while the drive is away, the next try waits until then (a new load of the drive tries at once).
    var mainRemovalsWaitUntil: ContinuousClock.Instant?
    /// Archive files with the segment of a file on the box (a move that a crash interrupted after its copy was in place, or another recording of
    /// that name): the box's copy is the one in the catalog until the mover compared the two (segment: the archive's file).
    var shadowed: [String: CatalogFile] = [:]
    /// Sidecars on the box without their mp4 (the main scan): a crash between the two deletions after a move.
    var loneMainSidecars: [String: UUID] = [:]
    var movedFiles = 0
    var movedBytes: UInt64 = 0
    var indexDirty = false
    var indexWrittenAt: ContinuousClock.Instant?
    /// When the archive was last read: the mover gives way to someone watching archived video.
    var lastReadAt: ContinuousClock.Instant?
    /// Tests: a simulated crash stopped the mover (`ArchiveStoreTuning.moveCrash`).
    var crashed = false

    static let failureLimit = 3

    func isFailing(now: Date) -> Bool { failingUntil.map { now < $0 } ?? false }

    /// Connected, loaded, answering and not failing: what moving and the archive's retention need.
    func isUsable(now: Date) -> Bool {
        connection == .connected && loaded && !stalled && writeProblem == nil && !isFailing(now: now) && (space?.total ?? 0) > 0 && !crashed
    }

    /// Forgets everything about the files (the recordings folder changed); what the drive is stays, its files are read again.
    mutating func reset() {
        connection = .unknown
        driveID = nil
        loaded = false
        loadGeneration += 1
        moving = nil
        plannedMoves = []
        unmovable = []
        removalFailed = []
        pendingMainRemovals = [:]
        shadowed = [:]
        loneMainSidecars = [:]
        indexDirty = false
        needsWriteTest = true
        writeProblem = nil
    }
}

/// What a probe of the archive drive's folder found (blocking: on the drive's own probe queue).
struct ArchiveDriveMeasurement: Sendable, Equatable {
    /// The marker's UUID ("" when it says none); nil: no marker, so no drive.
    var driveID: String?
    /// The folder is on the box's own disk or on the recordings drive: not the archive drive.
    var refusal: String?
    /// The sentence for a failed write test; nil when it passed or was not run.
    var writeProblem: String?
    var space: VolumeMonitor.Space?
    var floorBytes: UInt64

    static let markerName = ".camera-bridge-archive"
    static let onSystemDisk = "The archive drive’s folder is on the box’s own disk, so nothing is moved there."
    static let onRecordingDrive = "The archive drive’s folder is on the recordings drive, so nothing is moved there."
    static let cannotWrite = "The archive drive refuses writes."

    /// The marker's UUID, or "" for a marker without one; nil without a marker (a link is not one).
    static func driveID(in folder: URL) -> String? {
        let marker = folder.appending(path: markerName, directoryHint: .notDirectory)
        guard CatalogLoader.attributes(marker)?.type == .typeRegular else { return nil }
        guard let data = try? Data(contentsOf: marker), data.count <= 4_096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let uuid = object["uuid"] as? String else { return "" }
        return String(uuid.prefix(64))
    }

    static func measure(folder: URL, recordings: URL?, policy: ArchivePlatformPolicy?, dataDirectory: URL, writeTest: Bool) -> ArchiveDriveMeasurement {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: ArchiveVolume.path(of: folder), isDirectory: &isDirectory), isDirectory.boolValue,
              let id = driveID(in: folder) else {
            return ArchiveDriveMeasurement(driveID: nil, refusal: nil, writeProblem: nil, space: nil, floorBytes: 0)
        }
        var result = ArchiveDriveMeasurement(driveID: id, refusal: nil, writeProblem: nil, space: nil, floorBytes: 0)
        let systemVolume = policy.map { $0.isSystemVolume(folder) } ?? ArchiveVolume.sameVolume(folder, dataDirectory)
        if systemVolume {
            result.refusal = onSystemDisk
            return result
        }
        if let recordings, policy?.isSameVolume?(folder, recordings) == true {
            result.refusal = onRecordingDrive
            return result
        }
        if writeTest, ArchiveVolume.writeProblem(in: folder) != nil { result.writeProblem = cannotWrite }
        if let space = ArchiveVolume.space(of: folder, policy: policy) {
            result.space = VolumeMonitor.Space(total: space.total, free: space.free)
            result.floorBytes = ArchiveVolume.floor(for: folder, total: space.total, policy: policy, dataDirectory: dataDirectory)
        }
        return result
    }
}

/// What the box knows of the archive drive's files while it is not plugged in: kept in the data directory, written after the drive's files
/// changed (at most every `ArchiveStoreTuning.driveIndexInterval`), read at start. So a box that starts without its archive drive still shows
/// those recordings, as "on the archive drive (not connected)".
struct ArchiveDriveIndex: Codable, Sendable, Equatable {
    struct File: Codable, Sendable, Equatable {
        var camera: UUID
        var segment: String
        var start: Int64
        var end: Int64
        var mp4Bytes: UInt64
        var sidecarBytes: UInt64
        var fragments: Int
        var initLength: UInt32
        var flags: UInt16
    }

    static let fileName = "archive-drive-index.json"
    static let version = 1

    var version = ArchiveDriveIndex.version
    var drive: String?
    var files: [File]

    init(drive: String?, files: [CatalogFile]) {
        self.drive = drive
        self.files = files.map {
            File(camera: $0.camera, segment: $0.segment, start: $0.startMs, end: $0.endMs, mp4Bytes: $0.mp4Bytes, sidecarBytes: $0.sidecarBytes,
                 fragments: $0.fragmentCount, initLength: $0.initLength, flags: $0.flags)
        }
    }

    /// The catalog files it lists (tier `archive`, no rollups), leaving out entries that are not a segment of the layout.
    var catalogFiles: [CatalogFile] {
        files.compactMap { file in
            guard ArchiveLayout.parseSegment(file.segment) != nil, file.end >= file.start, file.fragments >= 0 else { return nil }
            return CatalogFile(camera: file.camera, segment: file.segment, startMs: file.start, endMs: file.end, initLength: file.initLength, flags: file.flags,
                               mp4Bytes: file.mp4Bytes, sidecarBytes: file.sidecarBytes, fragmentCount: file.fragments, rollups: [], isOpen: false,
                               tier: .archive)
        }
    }

    static func url(in dataDirectory: URL) -> URL { dataDirectory.appending(path: fileName, directoryHint: .notDirectory) }

    /// nil when there is none or it cannot be read (it is only a convenience: the drive's own files are the truth).
    static func read(from dataDirectory: URL) -> ArchiveDriveIndex? {
        let url = url(in: dataDirectory)
        guard CatalogLoader.attributes(url)?.type == .typeRegular, let data = try? Data(contentsOf: url) else { return nil }
        guard let index = try? JSONDecoder().decode(ArchiveDriveIndex.self, from: data), index.version == version else { return nil }
        return index
    }

    func write(to dataDirectory: URL) throws {
        try PrivateFiles.write(try JSONEncoder().encode(self), to: Self.url(in: dataDirectory))
    }
}
