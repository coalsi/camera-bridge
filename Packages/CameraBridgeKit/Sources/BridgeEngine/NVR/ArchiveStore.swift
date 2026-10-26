import BridgeSupport
import Foundation
import Synchronization

/// Where the store's log lines go. The log is process-wide, so a test that counts what the log publishes would be disturbed by every other test's
/// lines: the store's tests use `silent`, except the one that checks what is said.
struct ArchiveStoreLog: Sendable {
    var emit: @Sendable (_ level: LogLevel, _ message: String) -> Void

    static let standard = ArchiveStoreLog { level, message in
        let logger = Log(category: "NVR")
        switch level {
        case .warning, .error: logger.warning(message)
        case .debug: logger.debug(message)
        default: logger.info(message)
        }
    }

    static let silent = ArchiveStoreLog { _, _ in }

    func debug(_ message: @autoclosure () -> String) { emit(.debug, message()) }
    func info(_ message: @autoclosure () -> String) { emit(.info, message()) }
    func warning(_ message: @autoclosure () -> String) { emit(.warning, message()) }
}

/// The numbers and seams of the store that tests replace. Everything has the production value by default.
struct ArchiveStoreTuning: Sendable {
    var log = ArchiveStoreLog.standard
    /// The clock of the age rule and the new-file rules.
    var now: @Sendable () -> Date = { Date() }
    /// How often the drive is probed, and how long a probe may be pending before the drive counts as not answering.
    var probeInterval: Duration = .seconds(ArchiveConstants.storageStatusRefresh)
    var probeStallAfter: Duration = .seconds(5)
    /// How often the storage status (used and free bytes) is refreshed at most; a pause or a new folder publishes at once.
    var statusRefresh: Duration = .seconds(ArchiveConstants.storageStatusRefresh)
    /// How often the janitor runs (it also runs at start, after each file close and after a settings change).
    var retentionInterval: Duration = .seconds(ArchiveConstants.retentionInterval)
    /// Run the janitor once the catalog is loaded (a test turns it off to run the janitor by hand).
    var retentionAtStart = true
    var readDeadline: Duration = .seconds(ArchiveConstants.readDeadline)
    /// How long a read handle on a deleted file stays open (a reader in the middle of it finishes).
    var deletedHandleGrace: Duration = .seconds(10)
    var removeFile: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    /// A camera's pictures of the sky stay under this many bytes, and its folders are measured at most this often (Ruling S27).
    var skyStillBytesPerCamera: UInt64 = SkyLightFilter.stillBytesPerCamera
    var skyStillPruneInterval: TimeInterval = SkyLightFilter.stillPruneInterval
    /// Rebuilds the index of an unowned mp4 and writes it.
    var repair: @Sendable (_ mp4: URL, _ sidecar: URL, _ camera: UUID) throws -> IndexScanOutcome = { mp4, sidecar, camera in
        try IndexScanner.repair(mp4: mp4, sidecar: sidecar, camera: camera)
    }

    // The archive drive (`ArchiveDrive.swift`, `ArchiveMover+Store.swift`).
    /// How fast a recording is copied to the archive at most, and in what pieces; the pause between two moves.
    var moveBytesPerSecond = 32 * 1_048_576
    var moveChunkBytes = 1_048_576
    var movePause: Duration = .seconds(2)
    /// The mover waits while the archive was read this recently (someone watches archived video).
    var moveGivesWayFor: Duration = .seconds(1)
    /// After `ArchiveDriveState.failureLimit` moves in a row failed on the archive's side, nothing moves for this long.
    var driveFailureBackoff: TimeInterval = 600
    /// The archive's file list in the data directory is written at most this often (and when the mover is idle).
    var driveIndexInterval: Duration = .seconds(10)
    /// Archive reads at a time (its own queue: a slow USB drive never holds up reads of the recordings drive).
    var archiveReadWidth = 4
    /// The janitor waits at most this long for the archive's own deletions of one pass (a drive that hangs never holds up the box's retention).
    var archiveDeletionDeadline: Duration = .seconds(30)
    /// The box's copy of a moved file that could not be deleted, or whose drive went away first, is tried again after this long.
    var mainRemovalRetry: Duration = .seconds(60)
    /// Tests: true stops a move after this step as if the box lost power there; the mover then stops for good.
    var moveCrash: (@Sendable (ArchiveMoveStep) -> Bool)?

    init() {}
}

/// One start of the store (and one folder): background work belongs to the run that started it and ends when the run is over.
struct ArchiveRun: Sendable, Equatable {
    var id: Int
    var generation: Int
}

/// Everything the store changes, under one lock. No disk work is done while it is held.
struct ArchiveStoreState: Sendable {
    var running = false
    var runID = 0
    /// +1 whenever the folder changes (and at each start): `ArchiveWriteState.generation`.
    var generation = 0
    var folder: URL?
    var keepDays = 7
    var maxSizeGB = 500
    /// The first load of the current folder is over (also when there is no folder or it is missing): lookups answer.
    var isReady = false
    /// The folder was missing when the catalog was to be loaded: load it when the drive returns.
    var reloadWhenFolderReturns = false
    /// The first probe, load, retention pass and keyframe measurement of the current folder are over (tests wait for it).
    var isSettled = false

    var catalog = CatalogState()
    var blocks = ArchiveBlockCache()
    /// Files a recorder has open: nothing else touches them.
    var owned: Set<ArchiveOpenFile> = []
    /// Unowned files whose index must be rebuilt once they have been quiet for `repairQuietPeriod` (segment: camera).
    var repairQueue: [String: UUID] = [:]
    /// Files retention could not delete (tried once; cleared when the folder is loaded again).
    var removalFailed: Set<String> = []
    var damagedLogged: Set<String> = []
    /// Passes of the janitor loop that have finished (not counting the one at start). A test that has woken the janitor waits for this to move, so that
    /// the pass is over, and not half-way through a folder that is being moved, before it goes on.
    var retentionPasses = 0
    /// The newest start of a file the size rule deleted in this folder: the camera events of the days before it go too (`pruneEvents`).
    var eventSizeCutoffMs: Int64?
    /// When the cameras' pictures of the sky were last measured (`pruneEvents`).
    var skyStillsPrunedAt: Date?

    var pause: ArchivePause?
    var space: VolumeMonitor.Space?
    var floorBytes: UInt64 = 0
    var folderExists = true
    var probeStartedAt: ContinuousClock.Instant?
    var stalled = false
    var readsStalled = false
    var needsWriteTest = false
    /// The probe that start-up waits for has answered: the monitor starts probing then, not before (two probes would race for the first answer).
    var firstProbeDone = false

    var lastKeyTicks: [String: UInt32] = [:]
    var keyIntervals: [UUID: [Double]] = [:]

    /// The archive drive (nil folder: the host has none).
    var drive = ArchiveDriveState()

    var status: ArchiveStorageStatus?
    var statusAt: ContinuousClock.Instant?
    var tasks: [Task<Void, Never>] = []

    func isCurrent(_ run: ArchiveRun) -> Bool { running && runID == run.id && generation == run.generation }

    /// Takes the settings of a start or a folder change: nothing of the old folder is kept.
    mutating func configure(folder: URL?, keepDays: Int, maxSizeGB: Int) {
        self.folder = folder
        self.keepDays = keepDays
        self.maxSizeGB = maxSizeGB
        catalog.removeAll()
        catalog.bump()
        blocks.removeAll()
        owned = []
        repairQueue = [:]
        removalFailed = []
        damagedLogged = []
        lastKeyTicks = [:]
        keyIntervals = [:]
        eventSizeCutoffMs = nil
        skyStillsPrunedAt = nil
        isReady = folder == nil
        isSettled = false
        reloadWhenFolderReturns = false
        pause = folder == nil ? .noFolder : nil
        space = nil
        floorBytes = 0
        folderExists = true
        probeStartedAt = nil
        stalled = false
        readsStalled = false
        needsWriteTest = false
        firstProbeDone = false
        drive.reset()
    }
}

/// The catalog, reads, retention and volume monitor of the recordings folder (Mac spec 4.5, 5, 6, 7; addendum L5.1).
///
/// `start` returns at once; the background work (probe the drive, repair unclosed files, load the catalog, run retention) belongs to a run, and
/// `isReady` turns true when the load is done. Lookups are answered from memory; reading bytes goes through `ArchiveReadQueue`, the tables of
/// closed files are read from their sidecars when a lookup needs them. A file belongs to its recorder from `recorderOpened` to
/// `recorderClosed`: no scanner, janitor or repair touches it.
final class ArchiveStore: ArchiveReading, ArchiveWriteTarget, Sendable {
    let environment: BridgeEnvironment
    let signal: ChangeSignal
    let tuning: ArchiveStoreTuning
    let log: ArchiveStoreLog
    let state = Mutex(ArchiveStoreState())
    /// Directory listing, repair and deletion.
    let control = DispatchQueue(label: "CameraBridge.NVR.control", qos: .utility)
    let reads: ArchiveReadQueue
    let handles = ArchiveHandleCache()
    let probes: ArchiveProbeQueue
    /// The archive drive's own queues: reads with their deadline, open handles, probes, and listing and deletion. Nothing of the recordings drive
    /// waits behind them.
    let archiveReads: ArchiveReadQueue
    let archiveHandles = ArchiveHandleCache()
    let driveProbes = ArchiveProbeQueue()
    let driveControl = DispatchQueue(label: "CameraBridge.NVR.archive-drive", qos: .utility)
    /// Wakes the archive's monitor (a move failed) and the mover (retention planned moves, the drive came back).
    let driveWake = ChangeSignal()
    let moveWake = ChangeSignal()
    /// The mover's own low-priority thread.
    let mover: ArchiveMoveWorker
    /// Wakes the janitor (a file closed, a limit changed) and the volume monitor (a write failed).
    let retentionWake = ChangeSignal()
    let probeWake = ChangeSignal()
    /// The cameras' events beside the recordings (`ArchiveEventLog.swift`).
    let eventLog: ArchiveEventLog
    /// The Sky Watcher's log beside the recordings (`Sky/SkyLogStore.swift`): kept with the events and deleted by the same rules.
    let skyLog: SkyLogStore

    init(environment: BridgeEnvironment, signal: ChangeSignal, tuning: ArchiveStoreTuning = ArchiveStoreTuning(),
         probes: ArchiveProbeQueue = ArchiveProbeQueue()) {
        self.environment = environment
        self.signal = signal
        self.tuning = tuning
        self.probes = probes
        log = tuning.log
        reads = ArchiveReadQueue(deadline: tuning.readDeadline)
        archiveReads = ArchiveReadQueue(width: tuning.archiveReadWidth, deadline: tuning.readDeadline)
        mover = ArchiveMoveWorker(prepare: environment.archivePolicy?.lowerThreadPriority)
        eventLog = ArchiveEventLog(log: tuning.log)
        skyLog = SkyLogStore(log: tuning.log)
        state.withLock { $0.drive.folder = environment.archiveDriveFolder }
    }

    // MARK: Lifecycle (called by NVRCoordinator)

    /// Returns at once. Repair and the catalog load run in the background; `isReady` turns true when they are done.
    func start(settings: BridgeSettings) {
        let run = state.withLock { state -> ArchiveRun? in
            guard !state.running else { return nil }
            state.running = true
            state.runID += 1
            state.generation += 1
            state.configure(folder: settings.nvrFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }, keepDays: settings.nvrKeepDays,
                            maxSizeGB: settings.nvrMaxSizeGB)
            return ArchiveRun(id: state.runID, generation: state.generation)
        }
        guard let run else { return }
        publishStatus(force: true)
        launch(run)
    }

    /// Cancels background work and closes read handles. Never waits for a call that is stuck in a drive. The catalog stays, and lookups and
    /// reads go on working (a paused bridge still shows its recordings); `start` loads it again.
    func stop() async {
        shutDown()
    }

    /// `stop()` without the `async`: for a test's teardown.
    func shutDown() {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            state.running = false
            state.runID += 1
            defer { state.tasks = [] }
            return state.tasks
        }
        tasks.forEach { $0.cancel() }
        handles.closeAll()
        archiveHandles.closeAll()
    }

    /// A changed folder reloads the catalog (and bumps `writeState.generation`); changed limits run the janitor.
    func settingsChanged(from old: BridgeSettings, to new: BridgeSettings) async {
        let change = state.withLock { state -> (run: ArchiveRun, folderChanged: Bool)? in
            guard state.running else { return nil }   // `start` takes the settings it is given
            let folder = new.nvrFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let folderChanged = folder.map(ArchiveVolume.path(of:)) != state.folder.map(ArchiveVolume.path(of:))
            if folderChanged {
                state.generation += 1
                state.configure(folder: folder, keepDays: new.nvrKeepDays, maxSizeGB: new.nvrMaxSizeGB)
            } else {
                state.keepDays = new.nvrKeepDays
                state.maxSizeGB = new.nvrMaxSizeGB
            }
            return (ArchiveRun(id: state.runID, generation: state.generation), folderChanged)
        }
        guard let change else { return }
        if change.folderChanged {
            publishStatus(force: true)
            signal.notify()
            launch(change.run)
        } else {
            retentionWake.notify()
        }
    }

    /// The run that is going on now (background work compares itself with it).
    var currentRun: ArchiveRun { state.withLock { ArchiveRun(id: $0.runID, generation: $0.generation) } }

    // MARK: Status

    /// Memory only; nil before the first measurement.
    var storageStatus: ArchiveStorageStatus? { state.withLock { $0.status } }

    var writeState: ArchiveWriteState {
        state.withLock { ArchiveWriteState(folder: $0.folder, pause: $0.pause, isReady: $0.isReady, generation: $0.generation) }
    }

    /// Publishes `storageStatus` when it changed: at most every `storageStatusRefresh` seconds unless `force` (a pause or a folder changed).
    func publishStatus(force: Bool) {
        let changed = state.withLock { state -> Bool in
            let now = ContinuousClock.now
            if !force, let last = state.statusAt, last.duration(to: now) < tuning.statusRefresh { return false }
            // A folder that has not been measured yet has no numbers to show (the status stays nil until the first probe answers).
            if state.folder != nil, state.pause == nil, state.space == nil { return false }
            let span = state.catalog.span
            var status = ArchiveStorageStatus(folder: state.folder, pause: state.pause, usedBytes: VolumeMonitor.rounded(state.catalog.usedBytes),
                                              freeBytes: VolumeMonitor.rounded(state.space?.free ?? 0), totalBytes: state.space?.total ?? 0,
                                              floorBytes: state.floorBytes, oldest: span.map { ArchiveTime.date(ms: $0.oldest) },
                                              newest: span.map { ArchiveTime.date(ms: $0.newest) })
            status.archive = Self.driveStatus(state, now: tuning.now())
            state.statusAt = now
            guard status != state.status else { return false }
            state.status = status
            return true
        }
        if changed { signal.notify() }
    }

    // MARK: ArchiveReading: the catalog

    var catalogVersion: Int { state.withLock { $0.catalog.version } }
    var isReady: Bool { state.withLock { $0.isReady } }
    /// The background work of the start is over (a test waits for it so that nothing happens behind its back).
    var isSettled: Bool { state.withLock { $0.isSettled } }

    func extent(camera: UUID) -> ArchiveExtent? {
        state.withLock { state in
            state.isReady ? state.catalog.extent(camera: camera, typicalGOP: Self.median(state.keyIntervals[camera] ?? [])) : nil
        }
    }

    func fragment(camera: UUID, containing time: Date) async -> ArchiveFragment? {
        let micros = ArchiveTime.micros(time)
        return await resolve(camera: camera) { $0.fragment(camera: camera, containingMicros: micros) }
    }

    func fragment(camera: UUID, startingAfter time: Date) async -> ArchiveFragment? {
        let micros = ArchiveTime.micros(time)
        return await resolve(camera: camera) { $0.fragment(camera: camera, startingAfterMicros: micros) }
    }

    func fragment(camera: UUID, id: String) async -> ArchiveFragment? {
        guard let parsed = ArchiveIdentity.parseFragmentID(id) else { return nil }
        return await resolve(camera: camera) { $0.fragment(camera: camera, fileKey: parsed.fileKey, index: parsed.index) }
    }

    /// Runs a lookup; when it needs the table of a closed file, reads that (off the cooperative pool) and asks again.
    private func resolve(camera: UUID, _ lookup: (inout CatalogState) -> CatalogLookup<ArchiveFragment>) async -> ArchiveFragment? {
        for _ in 0..<4 {
            let result = state.withLock { state -> CatalogLookup<ArchiveFragment> in state.isReady ? lookup(&state.catalog) : .notFound }
            switch result {
            case .found(let fragment): return fragment
            case .notFound: return nil
            case .needsTable(let segment): guard await loadTable(camera: camera, segment: segment) else { return nil }
            }
        }
        return nil
    }

    /// Reads the fragment table of a closed file from its sidecar into the cache. False when it cannot (the lookup then answers a gap).
    func loadTable(camera: UUID, segment: String) async -> Bool {
        let request = state.withLock { state -> (sidecar: URL, mp4Size: UInt64, count: Int, startMs: Int64, tier: StorageTier)? in
            guard let file = state.catalog.file(camera: camera, segment: segment), !file.isOpen,
                  let folder = Self.readableFolder(of: file.tier, in: state) else { return nil }
            return (Self.url(folder, segment, ArchiveConstants.indexExtension), file.mp4Bytes, file.fragmentCount, file.startMs, file.tier)
        }
        guard let request else { return false }
        do {
            let queue = request.tier == .archive ? archiveReads : reads
            if request.tier == .archive { noteArchiveRead() }
            let data = try await queue.run { try Data(contentsOf: request.sidecar) }
            let index = try CBIndexFile.decode(data, mp4Size: request.mp4Size)
            guard index.fragments.count == request.count, index.startWallMs == request.startMs else { throw CBIndexError.sizeMismatch }
            state.withLock { state in
                if state.catalog.file(camera: camera, segment: segment)?.tier == request.tier { state.catalog.store(table: index.fragments, forSegment: segment) }
            }
            return true
        } catch is CBIndexError {
            quarantine(camera: camera, segment: segment, reason: "its index does not match the file")
        } catch let error as ArchiveError where error == .timedOut {
            if request.tier == .archive { markArchiveReadsStalled() } else { markReadsStalled() }
        } catch {
            reconcileMissing(camera: camera, segment: segment)
        }
        return false
    }

    /// The folder files of `tier` are read from now, nil when they cannot be: no recordings folder, or the archive drive away or not answering.
    static func readableFolder(of tier: StorageTier, in state: ArchiveStoreState) -> URL? {
        switch tier {
        case .main: return state.folder
        case .archive: return state.drive.connection == .connected && !state.drive.readsStalled ? state.drive.folder : nil
        }
    }

    /// Someone read the archive just now: the mover gives way for a moment.
    func noteArchiveRead() {
        state.withLock { $0.drive.lastReadAt = .now }
    }

    // MARK: ArchiveReading: bytes

    func read(_ fragment: ArchiveFragment, _ part: ArchiveReadPart) async throws -> Data {
        struct Plan {
            var folder: URL
            var offset: UInt64
            var length: Int
            var tier: StorageTier
        }
        let plan = try state.withLock { state -> Plan in
            guard state.isReady else { throw ArchiveError.unreadable("The recordings are still loading.") }
            guard ArchiveLayout.parseSegment(fragment.segment) != nil else { throw ArchiveError.unreadable("That is not a recording of this archive.") }
            let file = state.catalog.file(camera: fragment.camera, segment: fragment.segment)
            // A file retention just deleted can still be read through a handle that is open on it (on the drive it was on); a file nobody opened cannot.
            let tier: StorageTier
            if let file {
                tier = file.tier
            } else if handles.isOpen(fragment.segment) {
                tier = .main
            } else if archiveHandles.isOpen(fragment.segment) {
                tier = .archive
            } else {
                throw ArchiveError.fileGone
            }
            switch tier {
            case .main: guard !state.readsStalled else { throw ArchiveError.timedOut }
            case .archive:
                guard state.drive.connection == .connected else { throw ArchiveError.fileGone }   // away: a gap until it is back
                guard !state.drive.readsStalled else { throw ArchiveError.timedOut }
            }
            guard let folder = tier == .main ? state.folder : state.drive.folder else { throw ArchiveError.fileGone }
            let offset: UInt64, length: Int
            switch part {
            case .initialization:
                guard let file else { throw ArchiveError.fileGone }
                (offset, length) = (0, Int(file.initLength))
            case .keyframe:
                guard fragment.hasKeyframe, fragment.keyLength > 0 else { throw ArchiveError.noKeyframe }
                guard fragment.headerLength >= 0 else { throw ArchiveError.unreadable("That part is not in the file.") }
                let (start, overflow) = fragment.byteOffset.addingReportingOverflow(UInt64(fragment.headerLength))
                guard !overflow else { throw ArchiveError.unreadable("That part is not in the file.") }
                (offset, length) = (start, fragment.keyLength)
            case .fragment:
                (offset, length) = (fragment.byteOffset, fragment.byteLength)
            case .header:
                guard fragment.headerLength > 0, fragment.headerLength <= fragment.byteLength else { throw ArchiveError.unreadable("That part is not in the file.") }
                (offset, length) = (fragment.byteOffset, fragment.headerLength)
            }
            let (end, overflow) = offset.addingReportingOverflow(UInt64(max(0, length)))
            guard length > 0, length <= max(ArchiveConstants.fragmentMaximumBytes, 1_048_576), !overflow, end <= (file?.mp4Bytes ?? .max) else {
                throw ArchiveError.unreadable("That part is not in the file.")
            }
            return Plan(folder: folder, offset: offset, length: length, tier: tier)
        }

        // The bytes of a file are the same on both drives (a move copies them exactly), so the cache does not say which drive they came from.
        let key = ArchiveBlockCache.Key(segment: fragment.segment, offset: plan.offset, length: plan.length)
        if let cached = state.withLock({ $0.blocks.data(for: key) }) { return cached }
        let url = Self.url(plan.folder, fragment.segment, ArchiveConstants.mediaExtension)
        let handles = plan.tier == .archive ? archiveHandles : handles
        let queue = plan.tier == .archive ? archiveReads : reads
        if plan.tier == .archive { noteArchiveRead() }
        let data: Data
        do {
            data = try await queue.run { try handles.read(segment: key.segment, url: url, offset: plan.offset, count: plan.length) }
        } catch let error as ArchiveError {
            if error == .timedOut { if plan.tier == .archive { markArchiveReadsStalled() } else { markReadsStalled() } }
            throw error
        } catch {
            let mapped = ArchiveErrors.map(error)
            if mapped == .fileGone { reconcileMissing(camera: fragment.camera, segment: fragment.segment) }
            throw mapped
        }
        handles.sweep(grace: tuning.deletedHandleGrace)
        guard data.count == plan.length, Self.looksRight(data, part) else {
            quarantine(camera: fragment.camera, segment: fragment.segment, reason: "a fragment is not where its index says")
            throw ArchiveError.unreadable("This part of the recording is damaged.")
        }
        state.withLock { $0.blocks.insert(data, for: key) }
        return data
    }

    /// The first bytes of what was read show the boxes the index promised: `ftyp`, `prft` (or `moof`), or a NAL unit length that fits.
    static func looksRight(_ data: Data, _ part: ArchiveReadPart) -> Bool {
        switch part {
        case .initialization:
            return data.count >= 8 && data.dropFirst(4).prefix(4) == Data("ftyp".utf8)
        case .fragment, .header:
            return data.count >= 16 && (data.dropFirst(4).prefix(4) == Data("prft".utf8) || data.dropFirst(4).prefix(4) == Data("moof".utf8))
        case .keyframe:
            guard data.count > 4 else { return false }
            let length = data.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return length > 0 && length + 4 <= UInt64(data.count)
        }
    }

    static func url(_ folder: URL, _ segment: String, _ fileExtension: String) -> URL {
        folder.appending(path: segment + "." + fileExtension, directoryHint: .notDirectory)
    }

    /// Reads fail at once from now on; the next probe that comes back (within 5 s) clears it.
    func markReadsStalled() {
        state.withLock { $0.readsStalled = true }
    }

    /// The same for the archive drive alone: reads of the recordings drive go on.
    func markArchiveReadsStalled() {
        state.withLock { $0.drive.readsStalled = true }
        driveWake.notify()
    }

    /// A file whose index or bytes are not what the catalog says: out of the catalog (readers see a gap), rebuilt from the mp4 once it has been
    /// quiet. Logged once per file.
    func quarantine(camera: UUID, segment: String, reason: String) {
        let first = state.withLock { state -> Bool in
            guard let file = state.catalog.file(camera: camera, segment: segment), !file.isOpen,
                  state.drive.moving?.segment != segment else { return false }
            state.catalog.remove(segment: segment, camera: camera)
            state.blocks.remove(segment: segment)
            state.catalog.bump()
            // A file of the recordings drive is rebuilt there once it is quiet; one of the archive drive when the drive's files are read again.
            if file.tier == .main { state.repairQueue[segment] = camera } else { state.drive.indexDirty = true }
            return state.damagedLogged.insert(segment).inserted
        }
        if first { log.warning("A recording is out of the timeline until it is repaired: \(reason)") }
        retentionWake.notify()
    }

    /// A read found the file gone. If the drive is there and the file is not, the file leaves the catalog; if the drive is gone, nothing changes.
    /// The archive drive is "there" only with its marker: the folder it is mounted on stays when it is unplugged.
    func reconcileMissing(camera: UUID, segment: String) {
        guard let (folder, tier) = state.withLock({ state -> (URL, StorageTier)? in
            guard let file = state.catalog.file(camera: camera, segment: segment), !file.isOpen else { return nil }
            let folder = file.tier == .main ? state.folder : state.drive.folder
            return folder.map { ($0, file.tier) }
        }) else { return }
        let queue = tier == .archive ? driveProbes : probes
        Task.detached { [weak self] in
            guard let self else { return }
            let gone = await queue.run { () -> Bool in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: ArchiveVolume.path(of: folder), isDirectory: &isDirectory), isDirectory.boolValue else { return false }
                if tier == .archive, ArchiveDriveMeasurement.driveID(in: folder) == nil { return false }
                return !FileManager.default.fileExists(atPath: Self.url(folder, segment, ArchiveConstants.mediaExtension).path(percentEncoded: false))
            }
            guard gone else { return }
            state.withLock { state in
                if let file = state.catalog.file(camera: camera, segment: segment), !file.isOpen, file.tier == tier, state.drive.moving?.segment != segment {
                    state.catalog.remove(segment: segment, camera: camera)
                    state.blocks.remove(segment: segment)
                    state.catalog.bump()
                    if tier == .archive { state.drive.indexDirty = true }
                }
            }
        }
    }

    // MARK: ArchiveReading: activity

    func activity(camera: UUID, range: Range<Date>, binCount: Int) async -> ArchiveActivity {
        guard isReady else {
            return ArchiveActivity(start: range.lowerBound, binDuration: 0, bins: [], typical: nil, isComplete: false)
        }
        let startMs = ArchiveTime.ms(range.lowerBound), endMs = ArchiveTime.ms(range.upperBound)
        guard binCount > 0, endMs > startMs else {
            return ArchiveActivity(start: range.lowerBound, binDuration: 0, bins: [], typical: nil, isComplete: true)
        }
        let count = min(binCount, 20_000)
        let binMs = Double(endMs - startMs) / Double(count)
        for _ in 0..<4 {
            let outcome = state.withLock { state -> (intervals: [CatalogActivity.Interval], typical: Double?, missing: [String],
                                                     away: [(start: Int64, end: Int64)])? in
                guard state.isReady else { return nil }
                var intervals: [CatalogActivity.Interval] = []
                var missing: [String] = []
                // On the archive drive while it is away: shown as such, never as recorded video that would not play.
                let visible = state.catalog.visibleFiles(camera: camera, from: startMs, to: endMs).filter { !state.catalog.isUnreachable($0.file) }
                let away = state.catalog.unreachableSpans(camera: camera, from: startMs, to: endMs)
                // Bins of a minute or more come from the rollups; finer ones from the fragment tables, unless that would read more than a few.
                let coarse = binMs >= 60_000 || visible.count > Self.maximumActivityTables
                for (file, visibleEnd) in visible {
                    if coarse {
                        intervals += CatalogActivity.intervals(rollups: Self.rollups(of: file, in: &state.catalog), fileStartMs: file.startMs,
                                                               visibleEndMs: visibleEnd)
                    } else if let table = state.catalog.table(forSegment: file.segment) {
                        intervals += CatalogActivity.intervals(table: table, fileStartMs: file.startMs, fileEndMs: file.endMs, visibleEndMs: visibleEnd)
                    } else {
                        missing.append(file.segment)
                    }
                }
                guard missing.isEmpty else { return ([], nil, missing, away) }
                return (intervals, Self.typical(camera: camera, in: &state.catalog), [], away)
            }
            guard let outcome else { break }
            if outcome.missing.isEmpty {
                var bins = CatalogActivity.bins(rangeStartMs: startMs, binMs: binMs, binCount: count, intervals: outcome.intervals)
                Self.addAway(outcome.away, to: &bins, rangeStartMs: startMs, binMs: binMs)
                return ArchiveActivity(start: range.lowerBound, binDuration: binMs / 1_000, bins: bins, typical: outcome.typical, isComplete: true)
            }
            for segment in outcome.missing { _ = await loadTable(camera: camera, segment: segment) }
        }
        // A table could not be read: its time shows as a gap.
        let bins = (0..<count).map { _ in ArchiveActivity.Bin(coverage: 0, level: 0, peak: 0) }
        return ArchiveActivity(start: range.lowerBound, binDuration: binMs / 1_000, bins: bins, typical: nil, isComplete: true)
    }

    /// The most fragment tables a request for bins finer than a minute reads; over a longer time it is answered from the rollups.
    static let maximumActivityTables = 12

    /// The share of each bin that `spans` (milliseconds) cover, as `away`.
    static func addAway(_ spans: [(start: Int64, end: Int64)], to bins: inout [ArchiveActivity.Bin], rangeStartMs: Int64, binMs: Double) {
        guard !spans.isEmpty, binMs > 0 else { return }
        for span in spans {
            let first = max(0, Int(Double(span.start - rangeStartMs) / binMs))
            let last = min(bins.count - 1, Int(Double(span.end - rangeStartMs - 1) / binMs))
            guard first <= last else { continue }
            for index in first...last {
                let binStart = Double(rangeStartMs) + Double(index) * binMs
                let overlap = min(Double(span.end), binStart + binMs) - max(Double(span.start), binStart)
                if overlap > 0 { bins[index].away = min(1, bins[index].away + overlap / binMs) }
            }
        }
    }

    func awaySpan(camera: UUID, containing time: Date) -> DateInterval? {
        let ms = ArchiveTime.ms(time)
        return state.withLock { state -> DateInterval? in
            guard state.isReady else { return nil }
            let spans = state.catalog.unreachableSpans(camera: camera, from: Int64.min / 2, to: Int64.max / 2)
            guard let span = spans.first(where: { $0.start <= ms && ms < $0.end }) else { return nil }
            return DateInterval(start: ArchiveTime.date(ms: span.start), end: ArchiveTime.date(ms: span.end))
        }
    }

    /// The rollups of `file`: its sidecar's, or (while a recorder has it open) computed from its table.
    private static func rollups(of file: CatalogFile, in catalog: inout CatalogState) -> [CBIndexRollup] {
        guard file.isOpen else { return file.rollups }
        return CBIndexRollups.make(fragments: catalog.openTables[file.segment] ?? [])
    }

    /// The median level of the recorded minutes of the 24 hours before the camera's newest video.
    private static func typical(camera: UUID, in catalog: inout CatalogState) -> Double? {
        guard let newest = catalog.files[camera]?.map(\.endMs).max() else { return nil }
        let windowStart = newest - Int64(ArchiveConstants.typicalWindow * 1_000)
        var minutes: [(coveredMs: Int, nonKeyBytes: UInt32)] = []
        for (file, visibleEnd) in catalog.visibleFiles(camera: camera, from: windowStart, to: newest) {
            for piece in CatalogActivity.intervals(rollups: rollups(of: file, in: &catalog), fileStartMs: file.startMs, visibleEndMs: visibleEnd)
            where piece.endMs > windowStart {
                minutes.append((Int(piece.endMs - piece.startMs), UInt32(min(piece.nonKeyBytes, Double(UInt32.max)))))
            }
        }
        return CatalogActivity.typical(minutes: minutes)
    }

    /// The median of the recent keyframe intervals, nil without any.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // MARK: ArchiveWriteTarget: what recorders report

    func recorderOpened(_ file: ArchiveOpenFile, startWallMs: Int64, initLength: UInt32, hasAudio: Bool) {
        state.withLock { state in
            // A new file with the name of one on the archive drive (the clock went back by days): that one stays on the drive, out of the timeline.
            if let existing = state.catalog.file(camera: file.camera, segment: file.segment), existing.tier == .archive {
                state.drive.shadowed[file.segment] = existing
            }
            state.owned.insert(file)
            state.catalog.open(CatalogFile(camera: file.camera, segment: file.segment, startMs: startWallMs, endMs: startWallMs, initLength: initLength,
                                           flags: hasAudio ? CBIndexFormat.flagHasAudio : 0, mp4Bytes: UInt64(initLength), sidecarBytes: 0,
                                           fragmentCount: 0, rollups: [], isOpen: true))
        }
    }

    func recorderWrote(_ file: ArchiveOpenFile, _ record: CBIndexFragmentRecord) {
        state.withLock { state in
            guard state.owned.contains(file) else { return }   // a recorder of a folder we left
            state.catalog.append(record, toSegment: file.segment, camera: file.camera)
            if record.hasKeyframe {
                if let previous = state.lastKeyTicks[file.segment], record.mediaStart > previous {
                    var intervals = state.keyIntervals[file.camera] ?? []
                    intervals.append(Double(record.mediaStart - previous) / Double(ArchiveConstants.videoTimescale))
                    state.keyIntervals[file.camera] = Array(intervals.suffix(16))
                }
                state.lastKeyTicks[file.segment] = record.mediaStart
            }
        }
    }

    func recorderClosed(_ file: ArchiveOpenFile, index: CBIndexFile?) {
        let accepted = state.withLock { state -> Bool in
            guard state.owned.remove(file) != nil else { return false }
            state.lastKeyTicks[file.segment] = nil
            if let index {
                let sidecarBytes = UInt64(CBIndexFile.byteCount(rollups: index.rollups.count, fragments: index.fragments.count))
                state.catalog.close(segment: file.segment, index: index, sidecarBytes: sidecarBytes)
            } else {
                // Abandoned without a sidecar (a stalled drive): gone from the timeline; rebuilt once it has been quiet.
                state.catalog.remove(segment: file.segment, camera: file.camera)
                state.catalog.bump()
                state.repairQueue[file.segment] = file.camera
            }
            return true
        }
        if accepted { retentionWake.notify() }
    }

    func recorderFailed(camera: UUID, _ message: String) {
        state.withLock { $0.needsWriteTest = true }
        log.warning("A recorder could not write: \(Redact.string(message).prefix(200))")
        probeWake.notify()
    }
}
