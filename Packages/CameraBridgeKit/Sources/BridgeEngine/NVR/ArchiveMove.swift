import BridgeSupport
import Foundation
import Synchronization

/// The steps of a move after which a test stops it, as if the box lost power there (`ArchiveStoreTuning.moveCrash`). Every one of them leaves
/// exactly one good copy after the next start (`ArchiveMove.cleanTemporaries`, the store's duplicate check and its lone-sidecar cleanup).
enum ArchiveMoveStep: String, Sendable, CaseIterable {
    /// Half of the mp4 is in its temporary file on the archive.
    case copying
    /// Both temporary files are written, synced and checked.
    case copied
    /// The sidecar has its own name on the archive, the mp4 not yet.
    case sidecarInPlace
    /// Both have their own names on the archive (the catalog still points at the box).
    case inPlace
    /// The catalog points at the archive's copy; the box's copy is still there.
    case swapped
    /// The box's mp4 is deleted, its sidecar not yet.
    case mainMp4Deleted
}

/// Moving one recording from the recordings folder to the archive drive: the blocking part, run on the mover's own thread (`ArchiveMoveWorker`).
///
/// 1. The box's mp4 and sidecar are what the catalog says (regular files of the sizes it knows) and the archive has room above its floor.
/// 2. The camera's folder (with a copy of its `camera.json`) and the date folder are made on the archive when missing.
/// 3. Both files are copied to temporary names (`<name>.moving`, which no scan lists), a chunk at a time, at most `bytesPerSecond`, giving way
///    while someone reads the archive; each is hashed (SHA-256) as it is read and synced (`fsync`) when written.
/// 4. Both copies are read back and must have the source's size and hash.
/// 5. The sidecar takes its own name, then the mp4 (between the two the sidecar has no mp4, and no scan lists a sidecar alone), then the folder is
///    synced. Nothing of the box's copy is touched here: the store switches the catalog and then deletes it.
enum ArchiveMove {
    static let temporarySuffix = ".moving"

    struct Ticket: Sendable, Equatable {
        var camera: UUID
        var segment: String
        var mainFolder: URL
        var archiveFolder: URL
        var mp4Bytes: UInt64
        var sidecarBytes: UInt64
    }

    struct Controls: Sendable {
        var chunkBytes = 1_048_576
        /// 0: as fast as the drives go.
        var bytesPerSecond = 0
        var isCancelled: @Sendable () -> Bool = { false }
        /// True while someone reads the archive: the copy waits.
        var shouldYield: @Sendable () -> Bool = { false }
        var progress: @Sendable (UInt64) -> Void = { _ in }
        var crash: (@Sendable (ArchiveMoveStep) -> Bool)?
        /// The archive's free space and floor now; nil when it cannot be read (the copy then relies on the write failing).
        var room: @Sendable () -> (free: UInt64, floor: UInt64)? = { nil }
        var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    }

    enum Outcome: Sendable, Equatable {
        case inPlace
        /// The box's file is not what the catalog says or cannot be read: it is not tried again.
        case sourceProblem(String)
        /// The archive failed (a write, a sync, a copy that came back different): counts toward the drive failing.
        case destinationProblem(String)
        case noRoom
        /// The archive already has a file of that name.
        case collision
        case cancelled
        case crashed(ArchiveMoveStep)
    }

    private enum Failure: Error {
        case source(String)
        case destination(String)
        case cancelled
        case crashed(ArchiveMoveStep)
    }

    static func url(_ folder: URL, _ segment: String, _ fileExtension: String) -> URL {
        folder.appending(path: segment + "." + fileExtension, directoryHint: .notDirectory)
    }

    static func temporary(_ url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + temporarySuffix, directoryHint: .notDirectory)
    }

    static func perform(_ ticket: Ticket, _ controls: Controls) -> Outcome {
        let manager = FileManager.default
        let mp4 = url(ticket.mainFolder, ticket.segment, ArchiveConstants.mediaExtension)
        let sidecar = url(ticket.mainFolder, ticket.segment, ArchiveConstants.indexExtension)
        let target = url(ticket.archiveFolder, ticket.segment, ArchiveConstants.mediaExtension)
        let targetSidecar = url(ticket.archiveFolder, ticket.segment, ArchiveConstants.indexExtension)
        let partial = temporary(target), partialSidecar = temporary(targetSidecar)

        // 1. The source, and room for it.
        guard let parts = ArchiveLayout.parseSegment(ticket.segment) else { return .sourceProblem("not a recording of this layout") }
        guard let mp4Attributes = CatalogLoader.attributes(mp4), mp4Attributes.type == .typeRegular, mp4Attributes.size == ticket.mp4Bytes,
              let sidecarAttributes = CatalogLoader.attributes(sidecar), sidecarAttributes.type == .typeRegular, sidecarAttributes.size == ticket.sidecarBytes else {
            return .sourceProblem("the recording is not what its index says")
        }
        let total = ticket.mp4Bytes + ticket.sidecarBytes
        if let room = controls.room(), room.free < room.floor.addingReportingOverflow(total).partialValue { return .noRoom }

        // 2. Folders.
        let cameraFolder = ticket.archiveFolder.appending(path: parts.cameraDirectory, directoryHint: .isDirectory)
        let dateFolder = cameraFolder.appending(path: parts.dateDirectory, directoryHint: .isDirectory)
        do {
            try makeFolder(cameraFolder)
            let manifest = cameraFolder.appending(path: ArchiveConstants.cameraManifestName, directoryHint: .notDirectory)
            if CatalogLoader.attributes(manifest) == nil {
                let source = ticket.mainFolder.appending(path: parts.cameraDirectory, directoryHint: .isDirectory)
                    .appending(path: ArchiveConstants.cameraManifestName, directoryHint: .notDirectory)
                let data = (CatalogLoader.attributes(source)?.type == .typeRegular ? try? Data(contentsOf: source) : nil)
                    ?? Data(#"{"id":"\#(ticket.camera.uuidString)","name":"\#(parts.cameraDirectory)"}"#.utf8)
                try PrivateFiles.write(data, to: manifest)
            }
            try makeFolder(dateFolder)
        } catch {
            return .destinationProblem("the archive’s folders could not be made (\(ArchiveErrors.brief(error)))")
        }
        if CatalogLoader.attributes(target) != nil || CatalogLoader.attributes(targetSidecar) != nil { return .collision }

        // 3 and 4. Copy, sync, read back.
        do {
            for stale in [partial, partialSidecar] where CatalogLoader.attributes(stale) != nil { try manager.removeItem(at: stale) }
            let mp4Digest = try copy(mp4, to: partial, bytes: ticket.mp4Bytes, controls, crashHalfway: .copying)
            let sidecarDigest = try copy(sidecar, to: partialSidecar, bytes: ticket.sidecarBytes, controls, crashHalfway: nil)
            if controls.crash?(.copied) == true { return .crashed(.copied) }
            guard try digest(of: partial, controls) == mp4Digest, try digest(of: partialSidecar, controls) == sidecarDigest,
                  CatalogLoader.attributes(partial)?.size == ticket.mp4Bytes, CatalogLoader.attributes(partialSidecar)?.size == ticket.sidecarBytes else {
                throw Failure.destination("the copy on the archive is not the same as the recording")
            }
        } catch let failure as Failure {
            switch failure {
            case .crashed(let step): return .crashed(step)
            case .cancelled: removeQuietly([partial, partialSidecar]); return .cancelled
            case .source(let reason): removeQuietly([partial, partialSidecar]); return .sourceProblem(reason)
            case .destination(let reason): removeQuietly([partial, partialSidecar]); return .destinationProblem(reason)
            }
        } catch {
            removeQuietly([partial, partialSidecar])
            return .destinationProblem("the archive refused the copy (\(ArchiveErrors.brief(error)))")
        }

        // 5. In place: the sidecar first.
        do {
            try manager.moveItem(at: partialSidecar, to: targetSidecar)
            if controls.crash?(.sidecarInPlace) == true { return .crashed(.sidecarInPlace) }
            try manager.moveItem(at: partial, to: target)
        } catch {
            removeQuietly([partial, partialSidecar, targetSidecar])
            return .destinationProblem("the copy could not take its name on the archive (\(ArchiveErrors.brief(error)))")
        }
        synchronizeFolder(dateFolder)
        if controls.crash?(.inPlace) == true { return .crashed(.inPlace) }
        return .inPlace
    }

    /// Takes the archive's copy of a move away again (the catalog changed under the move): the files this move put there.
    static func removeCopy(_ ticket: Ticket) {
        let target = url(ticket.archiveFolder, ticket.segment, ArchiveConstants.mediaExtension)
        let targetSidecar = url(ticket.archiveFolder, ticket.segment, ArchiveConstants.indexExtension)
        // The mp4 first, as retention deletes: a sidecar left alone is never listed.
        removeQuietly([target, targetSidecar, temporary(target), temporary(targetSidecar)])
    }

    /// The same recording on both drives: equal sizes, equal sidecars and equal mp4 contents (SHA-256). What the duplicate check after a crash asks.
    static func sameRecording(segment: String, mainFolder: URL, archiveFolder: URL, controls: Controls = Controls()) -> Bool {
        let files = [ArchiveConstants.mediaExtension, ArchiveConstants.indexExtension].map { (url(mainFolder, segment, $0), url(archiveFolder, segment, $0)) }
        for (main, archive) in files {
            guard let left = CatalogLoader.attributes(main), let right = CatalogLoader.attributes(archive), left.type == .typeRegular, right.type == .typeRegular,
                  left.size == right.size else { return false }
            guard let one = try? digest(of: main, controls), let other = try? digest(of: archive, controls), one == other else { return false }
        }
        return true
    }

    /// After a crash, before the archive's files are read: deletes the temporary files of moves that did not finish, and a sidecar that took its
    /// name while its mp4 did not (the box still has the recording). Never follows a link; only names of the layout. Returns how many went.
    static func cleanTemporaries(archiveFolder: URL, mainFolder: URL) -> Int {
        guard let cameras = CatalogLoader.entries(in: archiveFolder) else { return 0 }
        var removed = 0
        for camera in cameras where camera.isDirectory && !camera.name.hasPrefix(".") {
            for date in CatalogLoader.entries(in: camera.url) ?? [] where date.isDirectory && ArchiveLayout.isDateDirectoryName(date.name) {
                let files = CatalogLoader.entries(in: date.url) ?? []
                let names = Set(files.map(\.name))
                for file in files where file.isRegularFile {
                    if file.name.hasSuffix(temporarySuffix) {
                        let base = String(file.name.dropLast(temporarySuffix.count))
                        guard base.hasSuffix("." + ArchiveConstants.mediaExtension) || base.hasSuffix("." + ArchiveConstants.indexExtension) else { continue }
                        if (try? FileManager.default.removeItem(at: file.url)) != nil { removed += 1 }
                    } else if file.name.hasSuffix("." + ArchiveConstants.indexExtension) {
                        let base = String(file.name.dropLast(ArchiveConstants.indexExtension.count + 1))
                        guard ArchiveLayout.isOwnFileBaseName(base), !names.contains(base + "." + ArchiveConstants.mediaExtension) else { continue }
                        let segment = ArchiveLayout.segment(cameraDirectory: camera.name, dateDirectory: date.name, baseName: base)
                        guard CatalogLoader.attributes(url(mainFolder, segment, ArchiveConstants.mediaExtension))?.type == .typeRegular else { continue }
                        if (try? FileManager.default.removeItem(at: file.url)) != nil { removed += 1 }
                    }
                }
            }
        }
        return removed
    }

    // MARK: Pieces

    private static func makeFolder(_ folder: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: ArchiveVolume.path(of: folder), isDirectory: &isDirectory) {
            guard isDirectory.boolValue, CatalogLoader.attributes(folder)?.type == .typeDirectory else { throw CocoaError(.fileWriteUnknown) }
            return
        }
        // One level: the archive's own folder is never made (a drive that is not mounted must not be re-invented on the box's disk).
        try FileManager.default.createDirectory(atPath: ArchiveVolume.path(of: folder), withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    private static func removeQuietly(_ urls: [URL]) {
        for url in urls where CatalogLoader.attributes(url) != nil { try? FileManager.default.removeItem(at: url) }
    }

    /// Asks the folder's entries to reach the disk (the renames); best effort: not every platform syncs a folder.
    private static func synchronizeFolder(_ folder: URL) {
        guard let handle = try? FileHandle(forReadingFrom: folder) else { return }
        try? handle.synchronize()
        try? handle.close()
    }

    /// Copies exactly `bytes` bytes of `source` to a new file `destination` (mode 0600), synced, and returns the SHA-256 of what was read.
    private static func copy(_ source: URL, to destination: URL, bytes: UInt64, _ controls: Controls, crashHalfway: ArchiveMoveStep?) throws -> [UInt8] {
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: source) } catch { throw Failure.source("the recording cannot be read (\(ArchiveErrors.brief(error)))") }
        defer { try? input.close() }
        guard CatalogLoader.attributes(destination) == nil,
              FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.destination("the archive refused a new file")
        }
        let output: FileHandle
        do { output = try FileHandle(forWritingTo: destination) } catch { throw Failure.destination("the archive refused a new file (\(ArchiveErrors.brief(error)))") }
        defer { try? output.close() }
        var hasher = Hashes.StreamingSHA256()
        var copied: UInt64 = 0
        var crashed = false
        let started = ContinuousClock.now
        var waited: TimeInterval = 0   // what the rate made it wait (a test's sleep does not pass)
        while copied < bytes {
            if controls.isCancelled() { throw Failure.cancelled }
            while controls.shouldYield() {
                controls.sleep(0.2)
                if controls.isCancelled() { throw Failure.cancelled }
            }
            let want = Int(min(UInt64(max(1, controls.chunkBytes)), bytes - copied))
            let piece: Data
            do { piece = try input.read(upToCount: want) ?? Data() } catch { throw Failure.source("the recording cannot be read (\(ArchiveErrors.brief(error)))") }
            guard !piece.isEmpty else { throw Failure.source("the recording is shorter than its index says") }
            hasher.update(piece)
            do { try output.write(contentsOf: piece) } catch { throw Failure.destination("a write to the archive failed (\(ArchiveErrors.brief(error)))") }
            copied += UInt64(piece.count)
            controls.progress(copied)
            if let crashHalfway, !crashed, copied * 2 >= bytes {
                crashed = true
                if controls.crash?(crashHalfway) == true {
                    try? output.synchronize()
                    throw Failure.crashed(crashHalfway)
                }
            }
            if controls.bytesPerSecond > 0 {
                let due = Double(copied) / Double(controls.bytesPerSecond)
                let spent = max(waited, started.duration(to: .now).timeInterval)
                if due > spent {
                    controls.sleep(due - spent)
                    waited += due - spent
                }
            }
        }
        let extra: Data
        do { extra = try input.read(upToCount: 1) ?? Data() } catch { throw Failure.source("the recording cannot be read (\(ArchiveErrors.brief(error)))") }
        guard extra.isEmpty else { throw Failure.source("the recording is longer than its index says") }
        do { try output.synchronize() } catch { throw Failure.destination("the archive could not save the copy (\(ArchiveErrors.brief(error)))") }
        return hasher.finalize()
    }

    /// SHA-256 of a file, read a chunk at a time.
    private static func digest(of url: URL, _ controls: Controls) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Hashes.StreamingSHA256()
        while true {
            if controls.isCancelled() { throw Failure.cancelled }
            let piece = try handle.read(upToCount: max(1, controls.chunkBytes)) ?? Data()
            if piece.isEmpty { break }
            hasher.update(piece)
        }
        return hasher.finalize()
    }
}

/// Runs the mover's blocking work on a thread of its own, one job at a time, at the lowest priority there is: background quality of service (on a
/// Mac that throttles its disk use too) and, on the box, `nice` 19 and the idle I/O class (`ArchivePlatformPolicy.lowerThreadPriority`, called once
/// on each new thread). The thread ends when nothing is queued and a new one starts with the next job, so a thread is never reused for other work
/// (Dispatch's would be: a priority set on one would stay with it).
final class ArchiveMoveWorker: Sendable {
    private struct State {
        var jobs: [@Sendable () -> Void] = []
        var running = false
    }

    private let state = Mutex(State())
    private let prepare: (@Sendable () -> Void)?

    init(prepare: (@Sendable () -> Void)?) {
        self.prepare = prepare
    }

    func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            submit { continuation.resume(returning: work()) }
        }
    }

    private func submit(_ job: @escaping @Sendable () -> Void) {
        let start = state.withLock { state -> Bool in
            state.jobs.append(job)
            guard !state.running else { return false }
            state.running = true
            return true
        }
        guard start else { return }
        let thread = Thread { [self] in drain() }
        thread.name = "CameraBridge.NVR.mover"
        thread.qualityOfService = .background
        thread.start()
    }

    private func drain() {
        prepare?()
        while true {
            let job = state.withLock { state -> (@Sendable () -> Void)? in
                guard !state.jobs.isEmpty else {
                    state.running = false
                    return nil
                }
                return state.jobs.removeFirst()
            }
            guard let job else { return }
            job()
        }
    }
}
