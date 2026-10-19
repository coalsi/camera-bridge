import Foundation
import Synchronization

/// Whether the engine says the recordings folder is out of reach (`ArchivePause.folderMissing`), as the screen last told the session. The archive
/// cannot say it: while the drive is away its lookups (`extent`, `fragment`) answer nothing, exactly as they do at the end of the recordings, and only a
/// read of a fragment that was already known throws. A cell that finds nothing where the recordings must go on asks this flag before it calls
/// that the end (and the session goes live), the way the web page asks `status.nvr.pause`.
nonisolated final class DriveFlag: Sendable {
    private let missing = Mutex(false)

    var isMissing: Bool { missing.withLock { $0 } }

    func set(_ value: Bool) { missing.withLock { $0 = value } }
}
