import Foundation

/// What a recorder takes from outside and tests replace: the clock, the time zone of the folder layout, the disk, and the polling intervals.
struct RecorderTuning: Sendable {
    /// The host's wall clock: only the anchor of a file (a camera clock more than 60 s off is replaced by it). The media timeline never reads it.
    var now: @Sendable () -> Date = { Date() }
    /// Seconds that do not jump (the system uptime, which stops in sleep and does not follow a clock step): an idle camera, a stalled write, retries.
    /// A box that sets its clock from the network at boot would otherwise see a write that is hours old.
    var uptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// File and date folder names are local time (Mac spec 4.1); the box runs in UTC.
    var timeZone: TimeZone = .current
    var fileSystem: any RecorderFileSystem = DiskFileSystem()
    /// Polling of `ArchiveWriteTarget.writeState` while a recorder waits or is paused.
    var waitingTick: Duration = .seconds(1)
    /// Polling while it records: also finds an idle camera (15 s without video) and a stalled drive.
    var recordingTick: Duration = .seconds(5)
    /// How long to wait before the next file after a failed create or write: the first, second and every later failure.
    var retryDelays: [TimeInterval] = [5, 10, 30]
    /// After three muxer failures on the first fragment of fresh files ("This stream cannot be recorded"): try again after this long.
    var unrecordableRetry: TimeInterval = 60
    /// `detach` returns within this long, whatever the drive does.
    var closeDeadline: Duration = .seconds(3)
    /// A file ends at the first keyframe after this much video or this many bytes (`ArchiveConstants`; tests make them small).
    var fileMaximumDuration: TimeInterval = ArchiveConstants.fileMaximumDuration
    var fileMaximumBytes: UInt64 = ArchiveConstants.fileMaximumBytes
    /// Pending writes beyond this many bytes mean the drive is not answering (`ArchiveConstants.stallPendingBytes`).
    var stallPendingBytes = ArchiveConstants.stallPendingBytes

    static let standard = RecorderTuning()
}

/// Errors of the recorder's own disk work and the sentences people read for them (no path, no raw system text).
enum RecorderFailure: Error, Equatable {
    case folderMissing
    case nameTaken

    static func sentence(for error: any Error) -> String {
        if let failure = error as? RecorderFailure {
            switch failure {
            case .folderMissing: return "The recordings folder isn’t available."
            case .nameTaken: return "Camera Bridge couldn’t find a free file name."
            }
        }
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteOutOfSpace: return "The recordings drive is full."
            case .fileWriteNoPermission, .fileWriteVolumeReadOnly: return "Camera Bridge can’t write to the recordings folder."
            case .fileNoSuchFile, .fileReadNoSuchFile: return "The recordings folder isn’t available."
            default: break
            }
        }
        return "Camera Bridge couldn’t write to the recordings folder."
    }

    /// For the log and `recorderFailed`: the error's domain and code, never its text (which may carry a path).
    static func technical(_ error: any Error) -> String {
        let bridged = error as NSError
        return "\(bridged.domain) \(bridged.code)"
    }
}
