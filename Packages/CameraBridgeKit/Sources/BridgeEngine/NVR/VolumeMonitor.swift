import BridgeSupport
import Foundation

/// What the recordings drive is doing, and what that means for recording (Mac spec 6, addendum L5.1). `measure` asks the drive (blocking: on the
/// probe queue); `decide` turns the answer into the pause recorders obey. The store runs both every 5 s.
enum VolumeMonitor {
    struct Space: Equatable, Sendable {
        var total: UInt64
        var free: UInt64
    }

    struct Measurement: Equatable, Sendable {
        /// The folder exists and is a directory.
        var folderExists: Bool
        var space: Space?
        /// The free space below which recording pauses on this volume.
        var floorBytes: UInt64
        /// The sentence for a failed write test; nil when it passed or was not run.
        var writeProblem: String?
    }

    static let notAnswering = ArchiveFolderError.notAnswering.errorDescription ?? "The drive isn’t answering."
    static let spaceUnreadable = "Camera Bridge can’t read the free space of the recordings drive."

    /// The pause for these facts, or nil to record. `previous` gives the hysteresis: a drive that was full is not trusted again until it has
    /// `resumeMarginBytes` more free space than the floor. A missing folder that returns resumes at once (when it is not full).
    static func decide(previous: ArchivePause?, folder: URL?, measurement: Measurement?, stalled: Bool) -> ArchivePause? {
        guard folder != nil else { return .noFolder }
        if stalled { return .notWritable(notAnswering) }
        guard let measurement else { return previous }
        guard measurement.folderExists else { return .folderMissing }
        guard let space = measurement.space else { return .notWritable(spaceUnreadable) }
        if let problem = measurement.writeProblem { return .notWritable(problem) }
        if space.free < measurement.floorBytes { return .diskFull }
        if previous == .diskFull, space.free < measurement.floorBytes + ArchiveConstants.resumeMarginBytes { return .diskFull }
        return nil
    }

    /// Asks the drive. Blocking: the probe queue only. `writeTest` also creates and deletes a probe file in the folder.
    static func measure(folder: URL, policy: ArchivePlatformPolicy?, dataDirectory: URL, writeTest: Bool) -> Measurement {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: ArchiveVolume.path(of: folder), isDirectory: &isDirectory), isDirectory.boolValue else {
            return Measurement(folderExists: false, space: nil, floorBytes: 0, writeProblem: nil)
        }
        let space = ArchiveVolume.space(of: folder, policy: policy).map { Space(total: $0.total, free: $0.free) }
        let floor = space.map { ArchiveVolume.floor(for: folder, total: $0.total, policy: policy, dataDirectory: dataDirectory) } ?? 0
        return Measurement(folderExists: true, space: space, floorBytes: floor, writeProblem: writeTest ? ArchiveVolume.writeProblem(in: folder) : nil)
    }

    /// A number rounded down to `ArchiveConstants.storageRounding` (the storage status shows used and free bytes to 10 MB).
    static func rounded(_ bytes: UInt64) -> UInt64 {
        bytes - bytes % ArchiveConstants.storageRounding
    }
}
