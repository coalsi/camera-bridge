import Foundation

/// The numbers every part of the NVR agrees on: the recorder, the store, the reader, the web interface and the app. One
/// definition each; nothing else in the repository repeats them (docs/superpowers/plans/2026-10-10-nvr/T00-contracts.md).
public enum ArchiveConstants {
    // MARK: Time (Mac spec 4.3)

    /// A gap of less than this between two files is continuous (the reader holds the last frame). Recorder, reader and UI.
    public static let gapThreshold: TimeInterval = 1
    /// A fragment whose measured wall time differs this much from the time derived from media time, twice in a row, ends the file.
    public static let wallDivergenceLimit: TimeInterval = 1
    /// A first frame whose wall clock is more than this from the Mac's (or the box's) clock is stamped with that clock instead.
    public static let anchorSkewLimit: TimeInterval = 60
    /// Ticks per second of every recorded video track, of `tfdt` and of the index's media times.
    public static let videoTimescale: Int32 = 90_000

    // MARK: Fragments and files (Mac spec 4.2 and 5, addendum L5.1)

    /// A fragment is cut at every keyframe or after this much decode time, whichever comes first.
    public static let fragmentMaximumDuration: TimeInterval = 2.5
    public static let fragmentMaximumFrames = 900
    /// 16 MiB, so every fragment fits one buffered HTTP answer (the Mac spec said 32 MiB).
    public static let fragmentMaximumBytes = 16 * 1_048_576
    /// A file ends at the first keyframe after this much video, or this many bytes.
    public static let fileMaximumDuration: TimeInterval = 900
    public static let fileMaximumBytes: UInt64 = 2 * 1_073_741_824
    /// A file ends when no video arrived for this long (the recorder's 5 s tick finds it).
    public static let idleCloseAfter: TimeInterval = 15
    /// The recorder asks the file to reach the disk this often.
    public static let syncInterval: TimeInterval = 30
    /// A forward step of the decode time above max(this, `forwardStepFrameIntervals` frame intervals) ends the file.
    public static let forwardStepFloor: TimeInterval = 1.5
    public static let forwardStepFrameIntervals = 4
    /// A write that has been pending this long, or this many bytes, is a stall: the recorder drops its subscription and pauses.
    public static let stallPendingAge: TimeInterval = 15
    public static let stallPendingBytes = 256 * 1_048_576

    // MARK: Storage (Mac spec 6, addendum L5.1)

    /// Gigabytes in the settings and on screen are decimal: `nvrMaxSizeGB` x 1e9 bytes.
    public static let gigabyte: UInt64 = 1_000_000_000
    /// Free space below which recording on a volume that is not the system volume pauses.
    public static let otherVolumeFloorBytes: UInt64 = 2 * 1_073_741_824
    /// Recording resumes when free space is this much above the floor (or when the folder returns).
    public static let resumeMarginBytes: UInt64 = 1_073_741_824
    /// The low-space notice shows while free space minus the floor is below this.
    public static let lowSpaceMarginBytes: UInt64 = 5 * 1_073_741_824
    /// `ArchiveFolderCheck` refuses a folder on a volume with less free space than this.
    public static let minimumFolderFreeBytes: UInt64 = 1_000_000_000
    /// `ArchiveStorageStatus` used and free bytes are rounded to this and refreshed at most every `storageStatusRefresh`.
    public static let storageRounding: UInt64 = 10_000_000
    public static let storageStatusRefresh: TimeInterval = 5
    /// The janitor runs at start, at this interval, after each file close and after a settings change.
    public static let retentionInterval: TimeInterval = 60
    /// Age deletion is skipped while the newest file starts more than this far in the future (a clock that jumped).
    public static let futureFileGuard: TimeInterval = 300
    /// An unowned file is repaired only when it has not been written for this long.
    public static let repairQuietPeriod: TimeInterval = 60

    // MARK: Reading (Mac spec 7)

    public static let readDeadline: TimeInterval = 5
    // Raised 2026-10-14 for the 4-core / 12 GB / SSD minimum (the Mac spec said 64 MiB, 16, 6 and 256): a 16-tile grid reads in parallel.
    public static let readCacheBytes = 256 * 1_048_576
    public static let maximumOpenReadHandles = 64
    public static let maximumConcurrentReads = 16
    public static let tableCacheFiles = 1024
    /// `ArchiveActivity.typical` needs at least this much recorded video in the window, else it is nil.
    public static let typicalMinimumRecorded: TimeInterval = 1_800
    public static let typicalWindow: TimeInterval = 86_400

    // MARK: Names

    public static let mediaExtension = "mp4"
    public static let indexExtension = "cbidx"
    /// `{"id": "<camera UUID>", "name": "<camera name>"}` in every camera directory: maps the directory to the camera.
    public static let cameraManifestName = "camera.json"
}
