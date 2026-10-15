import BridgeSupport
import Foundation
import Synchronization

/// One recording file on disk. The recorder never waits for the disk: every operation is queued on the camera's serial queue (shared by all the
/// files of one camera, so a file is created only after the previous one's operations ran) and returns at once, so a drive that stops answering
/// blocks one thread of one camera and nothing else. The writer tells the store what happened
/// (`ArchiveWriteTarget`: opened, wrote, closed, failed) from its queue, in order, and counts what is still queued (`pending`) so the recorder can
/// apply the stall rule (15 s or 256 MiB pending).
///
/// Order of work: `open` (folders, the file, the initialization segment), any number of `append`s, then `close` (sync, sidecar, close). After a
/// failure everything still queued is skipped; the file is cut back to its last whole fragment, a sidecar is written for them, and the store hears
/// `recorderClosed` and `recorderFailed`. After `abandon` the writer reports nothing more.
///
/// State touched by the queued work (`handle`, `written`, `records` …) is read and written only on `queue`; `accounting` is the lock-protected part
/// the recorder reads from other threads. The camera's queue is serial, so two writers of one camera never create folders or files at the same time.
final class ArchiveFileWriter: @unchecked Sendable {
    struct Request: Sendable {
        var root: URL
        var directory: ArchiveCameraDirectory
        var anchor: Date
        var timeZone: TimeZone
    }

    /// What is queued and not finished yet.
    struct Pending: Sendable, Equatable {
        var bytes: Int
        /// When the oldest unfinished operation was queued (`RecorderTuning.uptime`).
        var oldest: TimeInterval?
        var count: Int
    }

    private struct Accounting {
        var queued: [(bytes: Int, at: TimeInterval)] = []
        var abandoned = false
        var failed = false
        /// The file the store was told about with `recorderOpened`, until `recorderClosed`.
        var reported: ArchiveOpenFile?
    }

    let camera: UUID
    let id = UUID()
    private let request: Request
    private let fileSystem: any RecorderFileSystem
    private let target: any ArchiveWriteTarget
    private let uptime: @Sendable () -> TimeInterval
    private let onOpened: @Sendable (UUID) -> Void
    private let onFailure: @Sendable (UUID, String) -> Void
    private let log: Log
    private let queue: DispatchQueue
    private let accounting = Mutex(Accounting())

    // Queue-confined.
    private var handle: (any RecorderFileHandle)?
    private var file: ArchiveOpenFile?
    private var mp4: URL?
    private var sidecar: URL?
    private var startWallMs: Int64 = 0
    private var flags: UInt16 = 0
    private var initLength: UInt32 = 0
    private var written: UInt64 = 0
    private var records: [CBIndexFragmentRecord] = []

    init(camera: UUID, queue: DispatchQueue, request: Request, fileSystem: any RecorderFileSystem, target: any ArchiveWriteTarget, uptime: @escaping @Sendable () -> TimeInterval,
         log: Log, onOpened: @escaping @Sendable (UUID) -> Void, onFailure: @escaping @Sendable (UUID, String) -> Void) {
        self.camera = camera
        self.request = request
        self.fileSystem = fileSystem
        self.target = target
        self.uptime = uptime
        self.log = log
        self.onOpened = onOpened
        self.onFailure = onFailure
        self.queue = queue
    }

    var pending: Pending {
        accounting.withLock { Pending(bytes: $0.queued.reduce(0) { $0 + $1.bytes }, oldest: $0.queued.first?.at, count: $0.queued.count) }
    }

    /// Nothing queued or running: an abandoned writer whose drive answered again is idle.
    var isIdle: Bool { accounting.withLock { $0.queued.isEmpty } }

    var hasFailed: Bool { accounting.withLock { $0.failed } }

    // MARK: Queued operations

    /// Creates the camera and date folders and the file (mode 0600), writes `initialization`, then tells the store.
    func open(initialization: Data, startWallMs: Int64, hasAudio: Bool) {
        enqueue(bytes: initialization.count) { [self] in
            guard !skipped else { return }
            do {
                let directory = try request.directory.resolve(root: request.root)
                let created = try request.directory.createFile(root: request.root, directory: directory, anchor: request.anchor, timeZone: request.timeZone)
                handle = created.handle
                mp4 = created.mp4
                sidecar = created.index
                try created.handle.write(initialization)
                self.startWallMs = startWallMs
                flags = hasAudio ? CBIndexFormat.flagHasAudio : 0
                initLength = UInt32(initialization.count)
                written = UInt64(initialization.count)
                let opened = ArchiveOpenFile(camera: camera, segment: created.segment)
                file = opened
                let report = accounting.withLock { state -> Bool in
                    guard !state.abandoned else { return false }
                    state.reported = opened
                    return true
                }
                if report {
                    target.recorderOpened(opened, startWallMs: startWallMs, initLength: self.initLength, hasAudio: hasAudio)
                    log.info("Recording to \(created.segment)")
                    onOpened(id)
                }
            } catch {
                fail(error)
            }
        }
    }

    /// One whole fragment. `record` is what the index says about it; the store hears `recorderWrote` once the bytes are in the file. `synchronize`:
    /// also ask the file to reach the disk (the recorder does it every 30 s).
    func append(_ fragment: Data, record: CBIndexFragmentRecord, synchronize: Bool) {
        enqueue(bytes: fragment.count) { [self] in
            guard !skipped, let handle else { return }
            do {
                try handle.write(fragment)
                written += UInt64(fragment.count)
                records.append(record)
                if synchronize { try handle.synchronize() }
                if let file, !accounting.withLock({ $0.abandoned }) { target.recorderWrote(file, record) }
            } catch {
                fail(error)
            }
        }
    }

    /// Syncs, writes the sidecar, closes the file and tells the store (`recorderClosed` with the index, or nil when no sidecar could be written).
    func close() {
        enqueue(bytes: 0) { [self] in
            guard !accounting.withLock({ $0.abandoned || $0.failed }), handle != nil else { return }
            finishFile(synchronize: true)
        }
    }

    /// Runs `completion` on the queue once everything queued before this call has run (or been skipped) AND its accounting is settled, so
    /// `isIdle` is true when `completion` runs and nothing else was queued after the drain. The marker `enqueue` runs and is removed from
    /// `queued` first; the completion is a plain block queued behind it on the same serial queue. (Running the completion inside `enqueue`'s
    /// `work` would run it before the entry is removed: `isIdle` was still false, the recorder logged a false "drive did not answer" warning
    /// and `opensWritesAndClosesInOrderAndTellsTheStore` failed in about one Linux run in two.)
    func drain(completion: @escaping @Sendable () -> Void) {
        enqueue(bytes: 0) {}
        queue.async { completion() }
    }

    /// The drive is not answering: report the file as closed without a sidecar (repair deals with it later), let the queued work run out
    /// silently if the drive ever answers, and tell the store nothing more.
    func abandon() {
        let reported = accounting.withLock { state -> ArchiveOpenFile? in
            guard !state.abandoned else { return nil }
            state.abandoned = true
            defer { state.reported = nil }
            return state.reported
        }
        if let reported { target.recorderClosed(reported, index: nil) }
    }

    // MARK: On the queue

    private var skipped: Bool { accounting.withLock { $0.abandoned || $0.failed } }

    private func enqueue(bytes: Int, _ work: @escaping @Sendable () -> Void) {
        accounting.withLock { $0.queued.append((bytes, uptime())) }
        queue.async { [self] in
            work()
            accounting.withLock { state in if !state.queued.isEmpty { state.queued.removeFirst() } }
            if accounting.withLock({ $0.abandoned }) { cleanUpAfterAbandon() }
        }
    }

    /// The sidecar for the fragments that were written, then the file is closed and the store told.
    private func finishFile(synchronize: Bool) {
        guard let handle, let file, let sidecar else { return }
        if synchronize { try? handle.synchronize() }
        let index = CBIndexFile(flags: flags, camera: camera, startWallMs: startWallMs,
                                endWallMs: FragmentIndexer.endWallMs(startWallMs: startWallMs, records: records), mp4Size: written, initLength: initLength,
                                rollups: FragmentIndexer.rollups(startWallMs: startWallMs, records: records), fragments: records)
        var written = true
        do {
            try fileSystem.write(index.encoded(), to: sidecar)
        } catch {
            written = false
        }
        try? handle.close()
        self.handle = nil
        let reported = accounting.withLock { state -> Bool in
            defer { state.reported = nil }
            return state.reported == file
        }
        if reported { target.recorderClosed(file, index: written ? index : nil) }
        log.info("Closed \(file.segment): \(records.count) fragments")
    }

    /// The first failure: the file is cut back to its last whole fragment and closed with a sidecar for those; a file that never got its
    /// initialization segment is removed. The store hears `recorderFailed`, the recorder `onFailure`.
    private func fail(_ error: any Error) {
        let first = accounting.withLock { state -> Bool in
            guard !state.failed else { return false }
            state.failed = true
            return true
        }
        guard first else { return }
        if let handle {
            if file != nil {
                try? handle.truncate(atOffset: written)
                finishFile(synchronize: false)
            } else {
                try? handle.close()
                self.handle = nil
                if let mp4 { try? fileSystem.remove(mp4) }
            }
        }
        let message = RecorderFailure.technical(error)
        log.warning("Recording failed: \(message)")
        if !accounting.withLock({ $0.abandoned }) {
            target.recorderFailed(camera: camera, message)
            onFailure(id, RecorderFailure.sentence(for: error))
        }
    }

    /// A writer that was abandoned while blocked: when its drive answers, drop the handle (the file stays for repair).
    private func cleanUpAfterAbandon() {
        guard accounting.withLock({ $0.queued.isEmpty }) else { return }
        try? handle?.close()
        handle = nil
    }
}
