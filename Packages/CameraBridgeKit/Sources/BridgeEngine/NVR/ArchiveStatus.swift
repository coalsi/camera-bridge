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
}
