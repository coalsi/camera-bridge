import Foundation

/// What a recorder may do right now: the store's decision, which recorders read on their tick (every second while they wait or are paused,
/// every 5 s otherwise). A recorder never decides to pause for a full or missing drive by itself; it only reports write failures.
struct ArchiveWriteState: Sendable, Equatable {
    /// The recordings folder; nil when none was chosen.
    var folder: URL?
    /// Not nil: write nothing, drop the subscription and show `paused(pause)`.
    var pause: ArchivePause?
    /// The store finished its repair and catalog load: recorders may open files (until then they wait).
    var isReady: Bool
    /// +1 whenever `folder` changes: a recorder closes its file and opens the next one in the new folder.
    var generation: Int
}

/// A file one recorder owns (nobody else truncates, rewrites or deletes it while it is open).
struct ArchiveOpenFile: Hashable, Sendable {
    var camera: UUID
    /// "<camera directory>/<yyyy-MM-dd>/<HH-mm-ss>" (`ArchiveLayout.segment`).
    var segment: String
}

/// The store as the recorders see it (`ArchiveStore` implements it; the recorder's tests use a fake).
protocol ArchiveWriteTarget: Sendable {
    var writeState: ArchiveWriteState { get }
    /// The recorder created `<segment>.mp4` and wrote its `initLength` bytes of `ftyp` + `moov`. `startWallMs` is the file's anchor.
    func recorderOpened(_ file: ArchiveOpenFile, startWallMs: Int64, initLength: UInt32, hasAudio: Bool)
    /// A fragment is in the file: the write returned. The store appends it to the open file's in-memory table (readers see it from now on)
    /// and counts it in `catalogVersion`.
    func recorderWrote(_ file: ArchiveOpenFile, _ record: CBIndexFragmentRecord)
    /// The file is closed. `index` is what the recorder wrote to the sidecar (the file is then closed and eligible for retention);
    /// nil when the file was abandoned without a sidecar (a stalled drive): the store forgets it and repair deals with it later.
    func recorderClosed(_ file: ArchiveOpenFile, index: CBIndexFile?)
    /// A create or write failed (`ENOSPC`, `EIO`, a missing folder): the store checks the volume now and pauses when it is the cause.
    func recorderFailed(camera: UUID, _ message: String)
}
