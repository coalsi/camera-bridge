import Foundation

/// Why recording is paused. `code` is the stable name the web interface sends; `readable` is the sentence people see.
public enum ArchivePause: Sendable, Equatable {
    /// No recordings folder was chosen yet.
    case noFolder
    /// The folder is not there or cannot be read (a drive that was unplugged).
    case folderMissing
    /// Free space is below the floor (`ArchivePlatformPolicy.floorBytes`). Nothing is deleted to make room.
    case diskFull
    /// A write failed or stalled, or the folder refuses writes; the text is a sentence ("The drive isn’t answering.").
    case notWritable(String)

    public var code: String {
        switch self {
        case .noFolder: "noFolder"
        case .folderMissing: "folderMissing"
        case .diskFull: "diskFull"
        case .notWritable: "notWritable"
        }
    }

    public var readable: String {
        switch self {
        case .noFolder: "Choose where to store recordings."
        case .folderMissing: "The recordings folder isn’t available. Reconnect the drive or choose another folder."
        case .diskFull: "There isn’t enough free space on the recordings drive."
        case .notWritable(let reason): reason
        }
    }
}

public enum ArchiveRecordingState: Sendable, Equatable {
    /// Record is off for the camera.
    case off
    /// Record is on but no video is being written, and it is not a problem: "waiting for the camera".
    case waiting(String)
    case recording
    case paused(ArchivePause)
}

/// A line under a camera's recording status. At most one of each id.
public struct ArchiveNote: Sendable, Equatable, Identifiable {
    public enum ID: String, Sendable, Equatable { case sound, keyframe }

    public var id: ID
    public var text: String

    public init(id: ID, text: String) {
        self.id = id
        self.text = text
    }
}

/// `CameraStatus.nvr`: published through `EventHub` whenever it differs, so it changes rarely: no times, no byte counts, whole seconds only.
public struct CameraArchiveStatus: Sendable, Equatable {
    public var state: ArchiveRecordingState
    /// "sound could not be recorded" (id `sound`); "keyframe every 12 s: scrubbing is slow" (id `keyframe`, measured interval above 10 s).
    public var notes: [ArchiveNote]

    public init(state: ArchiveRecordingState = .off, notes: [ArchiveNote] = []) {
        self.state = state
        self.notes = notes
    }

    /// The waiting reason, or the pause's sentence; nil otherwise.
    public var detail: String? {
        switch state {
        case .off, .recording: nil
        case .waiting(let reason): reason
        case .paused(let pause): pause.readable
        }
    }
}

/// The recordings folder as numbers (`BridgeEngine.nvrStorage`): used and free are rounded to `ArchiveConstants.storageRounding` and refreshed at most every 5 s.
public struct ArchiveStorageStatus: Sendable, Equatable {
    public var folder: URL?
    public var pause: ArchivePause?
    /// Bytes of our own closed and open files (mp4 + sidecar).
    public var usedBytes: UInt64
    public var freeBytes: UInt64
    public var totalBytes: UInt64
    /// Free space below which recording pauses (`ArchivePlatformPolicy.floorBytes`).
    public var floorBytes: UInt64
    public var oldest: Date?
    public var newest: Date?

    public init(folder: URL? = nil, pause: ArchivePause? = nil, usedBytes: UInt64 = 0, freeBytes: UInt64 = 0, totalBytes: UInt64 = 0,
                floorBytes: UInt64 = 0, oldest: Date? = nil, newest: Date? = nil) {
        self.folder = folder
        self.pause = pause
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.floorBytes = floorBytes
        self.oldest = oldest
        self.newest = newest
    }

    /// Free space above the floor (what recording can still use before it pauses).
    public var spareBytes: UInt64 { freeBytes > floorBytes ? freeBytes - floorBytes : 0 }

    /// What this drive can hold of recordings: what is there plus what can still be added. Display only.
    public var roomBytes: UInt64 { usedBytes + spareBytes }

    /// The size the retention rule keeps the archive under: `min(maxSizeGB x 1e9, total - 2 x floor)`.
    public func effectiveMaximumBytes(maxSizeGB: Int) -> UInt64 {
        let chosen = UInt64(max(0, maxSizeGB)) * ArchiveConstants.gigabyte
        let reserve = floorBytes.multipliedReportingOverflow(by: 2).partialValue
        let capacity = totalBytes > reserve ? totalBytes - reserve : 0
        return min(chosen, capacity)
    }

    /// With an archive drive, the size above which the oldest recordings are deleted from this drive anyway, as without one: `total - 1.5 x
    /// floor`, always above `effectiveMaximumBytes`. Between the two they move to the archive; the half floor in between is what moves that lag
    /// behind (a slow USB drive) may use before deleting starts again, so recording never pauses because of the archive.
    public var hardMaximumBytes: UInt64 {
        let reserve = floorBytes.addingReportingOverflow(floorBytes / 2).partialValue
        return totalBytes > reserve ? totalBytes - reserve : 0
    }

    /// The archive drive (nil where the host has none: the Mac app, a box without one chosen in its image). Older recordings move there when this
    /// drive fills, instead of being deleted.
    public var archive: ArchiveDriveStatus?
}

/// The archive drive as numbers and a state (`ArchiveStorageStatus.archive`): refreshed with the storage status, at most every 5 s, bytes rounded
/// to `ArchiveConstants.storageRounding`.
public struct ArchiveDriveStatus: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        /// Plugged in, answering and in use: older recordings move here.
        case connected
        /// Not plugged in (or not chosen): what it holds shows as "on the archive drive (not connected)", and the box deletes as without one.
        case notConnected
        /// Plugged in but not answering, or writes to it fail: nothing moves for now (the box deletes as without one).
        case notAnswering
        case failing
        /// The folder is not the archive drive (it is on the box's own disk, or the recordings' drive): it is never written.
        case refused
    }

    /// A recording being moved now.
    public struct Move: Sendable, Equatable {
        public var camera: UUID
        /// When the recording starts.
        public var start: Date
        public var bytes: UInt64
        public var doneBytes: UInt64

        public init(camera: UUID, start: Date, bytes: UInt64, doneBytes: UInt64) {
            self.camera = camera
            self.start = start
            self.bytes = bytes
            self.doneBytes = doneBytes
        }
    }

    public var state: State
    /// A sentence for the state (nil while connected).
    public var message: String?
    /// Bytes of recordings on it (mp4 + sidecar), its free and total space, and the floor it keeps free (all 0 before it was first measured).
    public var usedBytes: UInt64
    public var freeBytes: UInt64
    public var totalBytes: UInt64
    public var floorBytes: UInt64
    /// How far back the archive goes, and its newest recording.
    public var oldest: Date?
    public var newest: Date?
    public var moving: Move?
    /// Recordings waiting to move, and what moved since the bridge started.
    public var waitingFiles: Int
    public var waitingBytes: UInt64
    public var movedFiles: Int
    public var movedBytes: UInt64

    public init(state: State, message: String? = nil, usedBytes: UInt64 = 0, freeBytes: UInt64 = 0, totalBytes: UInt64 = 0, floorBytes: UInt64 = 0,
                oldest: Date? = nil, newest: Date? = nil, moving: Move? = nil, waitingFiles: Int = 0, waitingBytes: UInt64 = 0, movedFiles: Int = 0,
                movedBytes: UInt64 = 0) {
        self.state = state
        self.message = message
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.floorBytes = floorBytes
        self.oldest = oldest
        self.newest = newest
        self.moving = moving
        self.waitingFiles = waitingFiles
        self.waitingBytes = waitingBytes
        self.movedFiles = movedFiles
        self.movedBytes = movedBytes
    }
}
