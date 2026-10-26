import Foundation

/// What the engine cannot find out portably, supplied by the host (`BridgeEnvironment.archivePolicy`). BridgeDaemon builds one
/// from statvfs (Glibc is allowed only there); the Mac app passes none and the engine uses Foundation's volume attributes.
public struct ArchivePlatformPolicy: Sendable {
    public enum DirectoryNaming: String, Sendable, Equatable {
        /// The camera's sanitized name (the Mac), made unique with " (2)".
        case cameraName
        /// The camera's UUID in upper case (the box); `camera.json` carries the name.
        case cameraID
    }

    /// Total and free bytes of the volume `url` is on (free = what a writer may use: `f_bavail`); nil when it cannot be read.
    public var space: @Sendable (URL) -> (total: UInt64, free: UInt64)?
    /// Whether `url` is on the volume the system and the bridge's own data live on (the startup volume; the box's data partition).
    public var isSystemVolume: @Sendable (URL) -> Bool
    /// The free space below which recording on the system volume pauses, for a volume of `total` bytes.
    public var systemFloor: @Sendable (_ total: UInt64) -> UInt64
    public var directoryNaming: DirectoryNaming
    /// Whether two folders are on the same volume (the daemon compares `st_dev`). The archive drive must not be on the recordings drive; nil (the Mac
    /// app): not checked.
    public var isSameVolume: (@Sendable (URL, URL) -> Bool)?
    /// Lowers the priority of the calling thread to the least there is (CPU and disk), for the thread that moves recordings to the archive drive: on
    /// the box `nice` 19 and the idle I/O class (`ionice -c3`). nil: the thread's background quality of service is all (on a Mac it also throttles
    /// the thread's disk reads and writes).
    public var lowerThreadPriority: (@Sendable () -> Void)?

    public init(space: @escaping @Sendable (URL) -> (total: UInt64, free: UInt64)?, isSystemVolume: @escaping @Sendable (URL) -> Bool,
                systemFloor: @escaping @Sendable (_ total: UInt64) -> UInt64, directoryNaming: DirectoryNaming) {
        self.space = space
        self.isSystemVolume = isSystemVolume
        self.systemFloor = systemFloor
        self.directoryNaming = directoryNaming
    }

    /// The floor for the volume `url` is on: `systemFloor(total)` on the system volume, else `ArchiveConstants.otherVolumeFloorBytes`.
    public func floorBytes(for url: URL, total: UInt64) -> UInt64 {
        isSystemVolume(url) ? systemFloor(total) : ArchiveConstants.otherVolumeFloorBytes
    }

    /// The Mac's startup volume: max(20 GiB, 10% of the volume), but never more than 50 GiB (the owner's decision of 2026-10-11:
    /// 10% of a 926 GB startup volume is 93 GB, more than the 84 GB free there, so recording to the internal drive paused at once).
    public static func macStartupFloor(total: UInt64) -> UInt64 { max(20 * 1_073_741_824, min(total / 10, 50 * 1_073_741_824)) }

    /// The box's data partition: max(8 GiB, 5% of the partition), above `cb-update`'s 4 GB.
    public static func linuxSystemFloor(total: UInt64) -> UInt64 { max(8 * 1_073_741_824, total / 20) }
}

/// What `ArchiveFolderCheck.inspect` found out about a usable folder.
public struct ArchiveFolderReport: Sendable, Equatable {
    public var freeBytes: UInt64
    public var totalBytes: UInt64
    /// The free space below which recording pauses on this folder's volume: the same floor the store's volume monitor uses (0 when unknown).
    public var floorBytes: UInt64

    public init(freeBytes: UInt64, totalBytes: UInt64, floorBytes: UInt64 = 0) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.floorBytes = floorBytes
    }
}

/// Why a folder cannot hold recordings. The sentences are what people read (the web interface sends `localizedDescription` as `folder_rejected`).
public enum ArchiveFolderError: Error, Equatable, Sendable, LocalizedError {
    case invalidPath
    case notFound
    case notAFolder
    case cannotWrite
    /// The volume has less free space than recording needs there (its floor): choosing it would pause recording at once.
    case belowFloor(freeBytes: UInt64, floorBytes: UInt64)
    case notAnswering

    public var errorDescription: String? {
        switch self {
        case .invalidPath: "That isn’t a usable folder path."
        case .notFound: "That folder doesn’t exist. Create it first, or choose another one."
        case .notAFolder: "That isn’t a folder."
        case .cannotWrite: "Camera Bridge can’t write to that folder."
        case .belowFloor(let free, let floor): "That drive needs \(Self.gigabytes(floor)) free to record, and has \(Self.gigabytes(free))."
        case .notAnswering: "The drive isn’t answering."
        }
    }

    /// "92.6 GB": decimal gigabytes with one decimal, the unit of the settings (`ArchiveConstants.gigabyte`).
    static func gigabytes(_ bytes: UInt64) -> String {
        let tenths = Int((Double(bytes) / 100_000_000).rounded())
        return "\(tenths / 10).\(tenths % 10) GB"
    }
}
