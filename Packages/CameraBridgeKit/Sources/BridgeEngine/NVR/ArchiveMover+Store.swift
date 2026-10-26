import BridgeSupport
import Foundation

// MARK: - The store's archive drive: its monitor, the load of its files, the mover and its status

extension ArchiveStore {
    /// Blocking work on the archive drive's own queue (listing, deletion, the clean-up after a crash): never on the recordings drive's.
    func onDriveControl<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            driveControl.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: Monitor

    /// Probes the archive drive's folder every `probeInterval` and sooner after a failed move or read. Never waits for a probe (single flight): a
    /// drive that hangs must not stop the check that says so, and nothing of the recordings drive waits for it.
    func driveLoop(_ run: ArchiveRun) async {
        while !Task.isCancelled {
            guard state.withLock({ $0.isCurrent(run) }) else { return }
            checkDriveStall(run)
            Task.detached(priority: .utility) { [weak self] in await self?.probeDrive(run) }
            await driveWake.wait(timeout: tuning.probeInterval)
        }
    }

    /// A probe of the archive pending for `probeStallAfter`: nothing moves there and its reads fail at once until a probe answers. Recording and the
    /// recordings drive go on as if there were no archive.
    func checkDriveStall(_ run: ArchiveRun) {
        let changed = state.withLock { state -> Bool in
            guard state.isCurrent(run), !state.drive.stalled, let started = state.drive.probeStartedAt,
                  started.duration(to: .now) >= tuning.probeStallAfter else { return false }
            state.drive.stalled = true
            state.drive.readsStalled = true
            return true
        }
        guard changed else { return }
        log.warning("The archive drive is not answering; older recordings are deleted as without one until it does")
        publishStatus(force: true)
        signal.notify()
    }

    /// One probe of the archive's folder (single flight) and what it means: a drive that appeared (or another drive) is loaded, one that went
    /// away leaves its files in the catalog as away.
    func probeDrive(_ run: ArchiveRun) async {
        let request = state.withLock { state -> (folder: URL, recordings: URL?, writeTest: Bool)? in
            guard state.isCurrent(run), let folder = state.drive.folder, state.drive.probeStartedAt == nil else { return nil }
            state.drive.probeStartedAt = .now
            return (folder, state.folder, state.drive.needsWriteTest || state.drive.connection != .connected)
        }
        guard let request else { return }
        let policy = environment.archivePolicy, dataDirectory = environment.dataDirectory
        let measurement = await driveProbes.run {
            ArchiveDriveMeasurement.measure(folder: request.folder, recordings: request.recordings, policy: policy, dataDirectory: dataDirectory,
                                            writeTest: request.writeTest)
        }
        enum Change { case none, changed, connected(Int), lost }
        let change = state.withLock { state -> Change in
            guard state.isCurrent(run) else { return .none }
            state.drive.probeStartedAt = nil
            let wasStalled = state.drive.stalled
            state.drive.stalled = false
            state.drive.readsStalled = false
            state.drive.space = measurement.space
            state.drive.floorBytes = measurement.floorBytes
            let before = state.drive.connection
            let after: ArchiveDriveState.Connection
            if measurement.driveID == nil {
                after = .away
            } else if let refusal = measurement.refusal {
                after = .refused(refusal)
            } else {
                after = .connected
            }
            let problemBefore = state.drive.writeProblem
            if request.writeTest, after == .connected {
                state.drive.writeProblem = measurement.writeProblem
                state.drive.needsWriteTest = measurement.writeProblem != nil   // keep testing until a write works
            }
            state.drive.connection = after
            if after == .connected, before != .connected || state.drive.driveID != measurement.driveID {
                state.drive.driveID = measurement.driveID
                state.drive.loaded = false
                state.drive.loadGeneration += 1
                state.drive.failures = 0
                state.drive.failingUntil = nil
                return .connected(state.drive.loadGeneration)
            }
            if before == .connected, after != .connected {
                state.drive.loaded = false
                state.drive.loadGeneration += 1
                state.drive.moving = nil
                state.drive.plannedMoves = []
                state.catalog.setArchiveAway(true)
                return .lost
            }
            return before != after || wasStalled || problemBefore != state.drive.writeProblem ? .changed : .none
        }
        switch change {
        case .connected(let generation):
            log.info("The archive drive is connected")
            await loadDrive(run, generation: generation)
        case .lost:
            log.info("The archive drive is not connected; its recordings show as on the drive until it is back")
            archiveHandles.closeAll()
            publishStatus(force: true)
            signal.notify()
        case .changed:
            publishStatus(force: true)
            signal.notify()
        case .none:
            publishStatus(force: false)
        }
    }

    // MARK: Loading

    /// Reads the archive drive's files into the catalog: first what moves a crash interrupted left (`ArchiveMove.cleanTemporaries`), then its
    /// folders like the recordings folder's (`CatalogLoader`), a file without a valid index rebuilt there. A file the box also has stays out until
    /// the mover compared the two (`shadowed`).
    func loadDrive(_ run: ArchiveRun, generation: Int) async {
        @Sendable func current(_ state: ArchiveStoreState) -> Bool {
            state.isCurrent(run) && state.drive.loadGeneration == generation && state.drive.connection == .connected
        }
        guard let (folder, mainFolder) = state.withLock({ state -> (URL, URL?)? in
            guard current(state), let folder = state.drive.folder else { return nil }
            return (folder, state.folder)
        }) else { return }
        if let mainFolder {
            let removed = await onDriveControl { ArchiveMove.cleanTemporaries(archiveFolder: folder, mainFolder: mainFolder) }
            if removed > 0 { log.info("Removed \(removed) pieces of moves to the archive drive that did not finish") }
        }
        let scan = await onDriveControl { [self] in CatalogLoader.scan(root: folder, isCancelled: { !self.state.withLock { current($0) } }) }
        var loaded = scan.files.map { file -> (file: CatalogFile, table: [CBIndexFragmentRecord]?) in
            var file = file
            file.tier = .archive
            return (file, nil)
        }
        for candidate in scan.needsRepair {
            let onBox = state.withLock { state in state.catalog.file(camera: candidate.camera, segment: candidate.segment)?.tier == .main }
            guard state.withLock({ current($0) }), !onBox else { continue }
            let mp4 = Self.url(folder, candidate.segment, ArchiveConstants.mediaExtension)
            let sidecar = Self.url(folder, candidate.segment, ArchiveConstants.indexExtension)
            let repair = tuning.repair
            guard tuning.now().timeIntervalSince(candidate.modified) >= ArchiveConstants.repairQuietPeriod,
                  case .indexed(let index, _, _)? = await onDriveControl({ () -> IndexScanOutcome? in try? repair(mp4, sidecar, candidate.camera) }) else { continue }
            let bytes = UInt64(CBIndexFile.byteCount(rollups: index.rollups.count, fragments: index.fragments.count))
            loaded.append((CatalogFile(segment: candidate.segment, index: index, sidecarBytes: bytes, tier: .archive), index.fragments))
        }
        let lone = state.withLock { state -> [(segment: String, camera: UUID)]? in
            guard current(state) else { return nil }
            for file in state.catalog.closedFiles(on: .archive) { state.catalog.remove(segment: file.segment, camera: file.camera) }
            var batch: [CatalogFile] = []
            for item in loaded {
                if let existing = state.catalog.file(camera: item.file.camera, segment: item.file.segment), existing.tier == .main {
                    state.drive.shadowed[item.file.segment] = item.file
                } else {
                    batch.append(item.file)
                }
            }
            state.catalog.insert(batch: batch)
            for item in loaded { if let table = item.table, state.drive.shadowed[item.file.segment] == nil { state.catalog.store(table: table, forSegment: item.file.segment) } }
            state.catalog.setArchiveAway(false)
            state.drive.loaded = true
            state.drive.indexDirty = true
            state.drive.unmovable = []
            state.drive.removalFailed = []
            state.drive.mainRemovalsWaitUntil = nil   // the box's copies left while the drive was away go now
            return Self.takeLoneSidecars(&state)
        }
        guard let lone else { return }
        await removeLoneSidecars(lone)
        if scan.unreadableDirectories > 0 { log.warning("\(scan.unreadableDirectories) folders of the archive drive could not be read") }
        log.info("The archive drive holds \(loaded.count) recordings")
        await writeDriveIndexIfDue(run, force: true)
        publishStatus(force: true)
        signal.notify()
        retentionWake.notify()
        moveWake.notify()
    }

    /// The box's sidecars without their mp4 whose recording is on the archive (a crash between the two deletions after a move): taken out of the
    /// list, for deletion.
    static func takeLoneSidecars(_ state: inout ArchiveStoreState) -> [(segment: String, camera: UUID)] {
        guard state.drive.loaded else { return [] }
        var taken: [(segment: String, camera: UUID)] = []
        for (segment, camera) in state.drive.loneMainSidecars where state.catalog.file(camera: camera, segment: segment)?.tier == .archive {
            taken.append((segment, camera))
        }
        for item in taken { state.drive.loneMainSidecars[item.segment] = nil }
        return taken
    }

    func removeLoneSidecars(_ lone: [(segment: String, camera: UUID)]) async {
        guard !lone.isEmpty, let folder = state.withLock({ $0.folder }) else { return }
        let remove = tuning.removeFile
        let removed = await onControl { () -> Int in
            var count = 0
            for item in lone {
                let sidecar = Self.url(folder, item.segment, ArchiveConstants.indexExtension)
                guard CatalogLoader.attributes(Self.url(folder, item.segment, ArchiveConstants.mediaExtension)) == nil,
                      CatalogLoader.attributes(sidecar)?.type == .typeRegular else { continue }
                if (try? remove(sidecar)) != nil { count += 1 }
            }
            return count
        }
        if removed > 0 { log.info("Removed \(removed) index files left on the box by moves that a restart interrupted") }
    }

    // MARK: The mover

    enum MoveJob: Sendable {
        /// The same segment on both drives: compare, keep one.
        case duplicate(archive: CatalogFile, mainFolder: URL, archiveFolder: URL, generation: Int)
        /// A moved file whose copy on the box is still there (the box's file as the catalog had it before the move).
        case mainRemoval(CatalogFile)
        case move(ArchiveMove.Ticket, generation: Int)
    }

    /// Takes what retention planned, one file at a time: compares the duplicates a crash left first, deletes the box's copies of moved files that
    /// could not be deleted yet, then moves (`ArchiveMove.perform` on the mover's own thread, then the catalog, then the box's copy).
    func moveLoop(_ run: ArchiveRun) async {
        while !Task.isCancelled {
            await moveWake.wait(timeout: .seconds(30))
            guard !Task.isCancelled, state.withLock({ $0.isCurrent(run) }) else { return }
            var worked = false
            while !Task.isCancelled, let job = nextMoveJob(run) {
                worked = true
                switch job {
                case .duplicate(let file, let mainFolder, let archiveFolder, let generation):
                    await resolveDuplicate(file, mainFolder: mainFolder, archiveFolder: archiveFolder, generation: generation, run: run)
                case .mainRemoval(let file):
                    await removeMainCopy(file, run: run)
                case .move(let ticket, let generation):
                    await move(ticket, generation: generation, run: run)
                }
                guard !state.withLock({ $0.drive.crashed }) else { return }
                try? await Task.sleep(for: tuning.movePause)
            }
            if worked { await writeDriveIndexIfDue(run, force: true) }
        }
    }

    /// The next thing the mover does, or nil. Marks a move's file as `moving` (retention, quarantine and reconciliation leave it alone then).
    func nextMoveJob(_ run: ArchiveRun) -> MoveJob? {
        state.withLock { state -> MoveJob? in
            guard state.isCurrent(run), state.isReady, !state.drive.crashed, state.drive.moving == nil, let mainFolder = state.folder,
                  state.pause != .folderMissing, !state.stalled else { return nil }
            // The box's copy of a file that moved, first: it goes once the archive's copy is found whole (`removeMainCopy`).
            if state.drive.mainRemovalsWaitUntil.map({ .now >= $0 }) ?? true, let (_, file) = state.drive.pendingMainRemovals.first {
                return .mainRemoval(file)
            }
            guard state.drive.isUsable(now: tuning.now()), let archiveFolder = state.drive.folder else { return nil }
            let generation = state.drive.loadGeneration
            for (segment, file) in state.drive.shadowed {
                guard let main = state.catalog.file(camera: file.camera, segment: segment), main.tier == .main else {
                    // The box's file is gone (retention took it): the archive's is a recording like any other now.
                    state.drive.shadowed[segment] = nil
                    if state.catalog.file(camera: file.camera, segment: segment) == nil {
                        state.catalog.insert(file)
                        state.catalog.bump()
                        state.drive.indexDirty = true
                    }
                    continue
                }
                guard !main.isOpen, !state.owned.contains(ArchiveOpenFile(camera: file.camera, segment: segment)) else { continue }
                state.drive.moving = (segment, ArchiveDriveStatus.Move(camera: file.camera, start: ArchiveTime.date(ms: file.startMs), bytes: file.bytes, doneBytes: 0))
                return .duplicate(archive: file, mainFolder: mainFolder, archiveFolder: archiveFolder, generation: generation)
            }
            while !state.drive.plannedMoves.isEmpty {
                let candidate = state.drive.plannedMoves.removeFirst()
                guard let file = state.catalog.file(camera: candidate.camera, segment: candidate.segment), file.tier == .main, !file.isOpen,
                      !state.owned.contains(ArchiveOpenFile(camera: file.camera, segment: file.segment)), !state.drive.unmovable.contains(file.segment),
                      state.drive.shadowed[file.segment] == nil, state.repairQueue[file.segment] == nil else { continue }
                state.drive.moving = (file.segment, ArchiveDriveStatus.Move(camera: file.camera, start: ArchiveTime.date(ms: file.startMs), bytes: file.bytes, doneBytes: 0))
                return .move(ArchiveMove.Ticket(camera: file.camera, segment: file.segment, mainFolder: mainFolder, archiveFolder: archiveFolder,
                                                mp4Bytes: file.mp4Bytes, sidecarBytes: file.sidecarBytes), generation: generation)
            }
            return nil
        }
    }

    /// The controls of the mover's copy: the store's rate and pieces, cancelled when the run or the drive changed, giving way to archive readers.
    private func moveControls(run: ArchiveRun, generation: Int, segment: String, archiveFolder: URL) -> ArchiveMove.Controls {
        let policy = environment.archivePolicy
        var controls = ArchiveMove.Controls()
        controls.chunkBytes = tuning.moveChunkBytes
        controls.bytesPerSecond = tuning.moveBytesPerSecond
        controls.crash = tuning.moveCrash
        let givesWayFor = tuning.moveGivesWayFor
        controls.isCancelled = { [weak self] in
            guard let self else { return true }
            return !state.withLock { state in
                state.isCurrent(run) && state.drive.loadGeneration == generation && state.drive.connection == .connected && !state.drive.stalled
                    && state.drive.moving?.segment == segment
            }
        }
        controls.shouldYield = { [weak self] in
            guard let self else { return false }
            return state.withLock { state in state.drive.lastReadAt.map { $0.duration(to: .now) < givesWayFor } ?? false }
        }
        controls.progress = { [weak self] done in
            self?.state.withLock { state in
                if state.drive.moving?.segment == segment { state.drive.moving?.move.doneBytes = done }
            }
        }
        controls.room = { [weak self] in
            guard let space = ArchiveVolume.space(of: archiveFolder, policy: policy), let self else { return nil }
            let floor = state.withLock { $0.drive.floorBytes }
            return (space.free, floor)
        }
        return controls
    }

    /// One move: the copy on the mover's thread, then (when it is in place and nothing changed meanwhile) the catalog points at the archive, then the
    /// box's copy is deleted. A move whose file changed under it takes its copy away again; one the archive failed counts toward the drive failing.
    func move(_ ticket: ArchiveMove.Ticket, generation: Int, run: ArchiveRun) async {
        let controls = moveControls(run: run, generation: generation, segment: ticket.segment, archiveFolder: ticket.archiveFolder)
        let outcome = await mover.run { ArchiveMove.perform(ticket, controls) }
        switch outcome {
        case .crashed:
            state.withLock { $0.drive.crashed = true }
        case .inPlace:
            let swapped = state.withLock { state -> CatalogFile? in
                defer { state.drive.moving = nil }
                guard state.isCurrent(run), state.drive.loadGeneration == generation, state.drive.connection == .connected,
                      let file = state.catalog.file(camera: ticket.camera, segment: ticket.segment), file.tier == .main, !file.isOpen,
                      file.mp4Bytes == ticket.mp4Bytes, file.sidecarBytes == ticket.sidecarBytes,
                      !state.owned.contains(ArchiveOpenFile(camera: ticket.camera, segment: ticket.segment)) else { return nil }
                state.catalog.setTier(.archive, segment: ticket.segment, camera: ticket.camera)
                state.drive.movedFiles += 1
                state.drive.movedBytes += file.bytes
                state.drive.failures = 0
                state.drive.indexDirty = true
                // Until the box's copy is deleted it is on the list, so a crash or a failed deletion cannot leave it behind for good.
                state.drive.pendingMainRemovals[ticket.segment] = file
                return file
            }
            guard let swapped else {
                // The copy is taken away only while this run and this load of the drive are current: the file changed under the move, and the box's
                // copy is the one kept. After a restart of the store or a reload of the drive another run may have found the copy and be comparing it
                // with the box's (`resolveDuplicate`): it is left to that, which keeps exactly one. (The worker runs its jobs in order, so a removal
                // decided here always runs before any later comparison.)
                let rollback = state.withLock { state in
                    state.isCurrent(run) && state.drive.loadGeneration == generation && state.drive.connection == .connected
                }
                if rollback { await mover.run { ArchiveMove.removeCopy(ticket) } }
                return
            }
            handles.retire(ticket.segment)
            if tuning.moveCrash?(.swapped) == true {
                state.withLock { $0.drive.crashed = true }
                return
            }
            await removeMainCopy(swapped, run: run)
            await writeDriveIndexIfDue(run, force: false)
            publishStatus(force: false)
        case .noRoom:
            state.withLock { state in
                state.drive.moving = nil
                state.drive.plannedMoves = []   // the plan's free space was out of date: the next pass plans again
            }
        case .collision:
            state.withLock { state in
                state.drive.moving = nil
                state.drive.unmovable.insert(ticket.segment)
            }
            log.warning("A recording was not moved: the archive drive has another file of its name")
        case .sourceProblem(let reason):
            state.withLock { state in
                state.drive.moving = nil
                state.drive.unmovable.insert(ticket.segment)
            }
            log.warning("A recording was not moved to the archive drive: \(reason)")
        case .destinationProblem(let reason):
            let failing = state.withLock { state -> Bool in
                state.drive.moving = nil
                state.drive.failures += 1
                state.drive.needsWriteTest = true
                guard state.drive.failures >= ArchiveDriveState.failureLimit else { return false }
                state.drive.failures = 0
                state.drive.failingUntil = tuning.now().addingTimeInterval(tuning.driveFailureBackoff)
                state.drive.plannedMoves = []
                return true
            }
            log.warning("A move to the archive drive failed: \(reason)")
            if failing { log.warning("Moves to the archive drive keep failing; older recordings are deleted as without one for a while") }
            driveWake.notify()
            publishStatus(force: true)
        case .cancelled:
            state.withLock { state in
                if state.drive.moving?.segment == ticket.segment { state.drive.moving = nil }
            }
        }
    }

    /// Deletes the box's copy of a moved file (`file`: the box's file as the catalog had it before the move): the mp4, then the sidecar, then an
    /// empty date folder of an earlier day. On failure it stays on the list and is tried again by the mover. First the archive's copy must still
    /// be there, whole (the box's sizes): while the drive is away the deletion waits, and a copy the drive lost (it came back without it) makes the
    /// box's copy, when it is whole, the recording again.
    func removeMainCopy(_ file: CatalogFile, run: ArchiveRun) async {
        let segment = file.segment
        guard let (folder, archiveFolder) = state.withLock({ state -> (URL, URL?)? in
            guard state.isCurrent(run), let folder = state.folder else { return nil }
            return (folder, state.drive.folder)
        }) else { return }
        enum Copy: Sendable { case whole, away, lost, neither }
        let copy = await mover.run { () -> Copy in
            @Sendable func isWhole(_ root: URL) -> Bool {
                [(ArchiveConstants.mediaExtension, file.mp4Bytes), (ArchiveConstants.indexExtension, file.sidecarBytes)].allSatisfy { item in
                    let found = CatalogLoader.attributes(ArchiveMove.url(root, segment, item.0))
                    return found?.type == .typeRegular && found?.size == item.1
                }
            }
            guard let archiveFolder, ArchiveDriveMeasurement.driveID(in: archiveFolder) != nil else { return .away }
            if isWhole(archiveFolder) { return .whole }
            return isWhole(folder) ? .lost : .neither
        }
        switch copy {
        case .whole:
            break
        case .away:
            state.withLock { state in
                if state.drive.moving?.segment == segment { state.drive.moving = nil }
                state.drive.mainRemovalsWaitUntil = .now + tuning.mainRemovalRetry
            }
            return
        case .lost, .neither:
            let restored = state.withLock { state -> Bool in
                if state.drive.moving?.segment == segment { state.drive.moving = nil }
                state.drive.pendingMainRemovals[segment] = nil
                guard copy == .lost, state.isCurrent(run) else { return false }
                if let current = state.catalog.file(camera: file.camera, segment: segment), current.tier == .main { return false }
                // The archive's file of that name (what is left of it) stays out of the catalog; its next load compares it with the box's.
                state.catalog.remove(segment: segment, camera: file.camera)
                var kept = file
                kept.tier = .main
                state.catalog.insert(kept)
                state.catalog.bump()
                state.drive.unmovable.insert(segment)
                state.drive.indexDirty = true
                return true
            }
            if restored {
                archiveHandles.retire(segment)
                log.warning("A recording’s copy on the archive drive is missing or incomplete; the box keeps its own copy")
                publishStatus(force: true)
                signal.notify()
            } else if copy == .neither {
                log.warning("A recording moved to the archive drive is incomplete on both drives; both files are left as they are")
            }
            return
        }
        let mp4 = Self.url(folder, segment, ArchiveConstants.mediaExtension)
        let sidecar = Self.url(folder, segment, ArchiveConstants.indexExtension)
        let remove = tuning.removeFile
        let crash = tuning.moveCrash
        let today = Self.dateDirectoryName(tuning.now())
        enum Outcome: Sendable { case done, failed(String), crashed }
        let outcome = await onControl { () -> Outcome in
            for (index, url) in [mp4, sidecar].enumerated() {
                do {
                    try remove(url)
                } catch where !Self.isMissing(error) {
                    return .failed(ArchiveErrors.brief(error))
                } catch {}
                if index == 0, crash?(.mainMp4Deleted) == true { return .crashed }
            }
            let dateDirectory = mp4.deletingLastPathComponent()
            if dateDirectory.lastPathComponent < today,
               let remaining = try? FileManager.default.contentsOfDirectory(atPath: ArchiveVolume.path(of: dateDirectory)), remaining.isEmpty {
                try? FileManager.default.removeItem(at: dateDirectory)
            }
            return .done
        }
        switch outcome {
        case .done:
            state.withLock { state in
                state.drive.pendingMainRemovals[segment] = nil
                state.drive.mainRemovalsWaitUntil = nil
                if state.drive.moving?.segment == segment { state.drive.moving = nil }
            }
        case .crashed:
            state.withLock { $0.drive.crashed = true }
        case .failed(let reason):
            let first = state.withLock { state -> Bool in
                if state.drive.moving?.segment == segment { state.drive.moving = nil }
                state.drive.mainRemovalsWaitUntil = .now + tuning.mainRemovalRetry
                return state.damagedLogged.insert("moved:" + segment).inserted
            }
            if first { log.warning("The box’s copy of a recording that moved to the archive drive could not be deleted (\(reason)); it is tried again") }
        }
    }

    /// A segment on both drives: the same recording (sizes, sidecars and contents equal: a move that a crash interrupted once its copy was in place)
    /// keeps the archive's copy and deletes the box's; another recording of that name keeps both files, the box's in the catalog.
    func resolveDuplicate(_ archived: CatalogFile, mainFolder: URL, archiveFolder: URL, generation: Int, run: ArchiveRun) async {
        var settings = ArchiveMove.Controls()
        settings.chunkBytes = tuning.moveChunkBytes
        let controls = settings
        let same = await mover.run { ArchiveMove.sameRecording(segment: archived.segment, mainFolder: mainFolder, archiveFolder: archiveFolder, controls: controls) }
        enum Kept { case archive(main: CatalogFile), both, nothing }
        let kept = state.withLock { state -> Kept in
            defer { if state.drive.moving?.segment == archived.segment { state.drive.moving = nil } }
            guard state.isCurrent(run), state.drive.loadGeneration == generation, state.drive.shadowed[archived.segment] != nil else { return .nothing }
            state.drive.shadowed[archived.segment] = nil
            guard same, let main = state.catalog.file(camera: archived.camera, segment: archived.segment), main.tier == .main, !main.isOpen,
                  !state.owned.contains(ArchiveOpenFile(camera: archived.camera, segment: archived.segment)) else {
                state.drive.unmovable.insert(archived.segment)
                return .both
            }
            state.catalog.insert(archived)
            state.catalog.bump()
            state.drive.indexDirty = true
            state.drive.pendingMainRemovals[archived.segment] = main
            return .archive(main: main)
        }
        switch kept {
        case .archive(let main):
            handles.retire(archived.segment)
            await removeMainCopy(main, run: run)
            log.info("A recording found on both drives after an interrupted move is kept on the archive drive")
        case .both:
            log.warning("A recording on the archive drive has the name of a different one on the box; both are kept")
        case .nothing:
            break
        }
    }

    // MARK: The index of the archive's files

    /// Writes what the archive drive holds to the data directory, when it changed and `driveIndexInterval` has passed (or `force`).
    func writeDriveIndexIfDue(_ run: ArchiveRun, force: Bool) async {
        let snapshot = state.withLock { state -> ArchiveDriveIndex? in
            guard state.isCurrent(run), state.drive.indexDirty, state.drive.loaded else { return nil }
            if !force, let written = state.drive.indexWrittenAt, written.duration(to: .now) < tuning.driveIndexInterval { return nil }
            state.drive.indexDirty = false
            state.drive.indexWrittenAt = .now
            return ArchiveDriveIndex(drive: state.drive.driveID, files: state.catalog.closedFiles(on: .archive))
        }
        guard let snapshot else { return }
        let dataDirectory = environment.dataDirectory
        let failure = await onControl { () -> String? in
            do {
                try snapshot.write(to: dataDirectory)
                return nil
            } catch {
                return ArchiveErrors.brief(error)
            }
        }
        if let failure { log.warning("The list of the archive drive’s recordings could not be saved (\(failure))") }
    }

    // MARK: Status

    static let driveAwaySentence = "The archive drive isn’t connected. Its recordings play again when it is plugged back in."
    static let driveSilentSentence = "The archive drive isn’t answering."
    static let driveFailingSentence = "Moving recordings to the archive drive failed. It is tried again in a few minutes."

    /// nil where the host has no archive folder, and while no archive drive was ever seen (none connected since the start, none remembered from an
    /// earlier one): a box without an archive drive says nothing about one.
    static func driveStatus(_ state: ArchiveStoreState, now: Date) -> ArchiveDriveStatus? {
        let drive = state.drive
        guard drive.folder != nil else { return nil }
        if drive.connection == .unknown || drive.connection == .away, drive.driveID == nil, state.catalog.archiveBytes == 0 { return nil }
        let kind: ArchiveDriveStatus.State
        var message: String?
        switch drive.connection {
        case .unknown, .away:
            kind = .notConnected
            message = driveAwaySentence
        case .refused(let sentence):
            kind = .refused
            message = sentence
        case .connected:
            if drive.stalled {
                kind = .notAnswering
                message = driveSilentSentence
            } else if let problem = drive.writeProblem {
                kind = .failing
                message = problem
            } else if drive.isFailing(now: now) {
                kind = .failing
                message = driveFailingSentence
            } else {
                kind = .connected
            }
        }
        let span = state.catalog.span(on: .archive)
        var moving = drive.moving?.move
        if let done = moving?.doneBytes { moving?.doneBytes = VolumeMonitor.rounded(done) }
        let waiting = drive.plannedMoves
        return ArchiveDriveStatus(state: kind, message: message, usedBytes: VolumeMonitor.rounded(state.catalog.archiveBytes),
                                  freeBytes: VolumeMonitor.rounded(drive.space?.free ?? 0), totalBytes: drive.space?.total ?? 0, floorBytes: drive.floorBytes,
                                  oldest: span.map { ArchiveTime.date(ms: $0.oldest) }, newest: span.map { ArchiveTime.date(ms: $0.newest) }, moving: moving,
                                  waitingFiles: waiting.count, waitingBytes: VolumeMonitor.rounded(waiting.reduce(0) { $0 + $1.bytes }),
                                  movedFiles: drive.movedFiles, movedBytes: VolumeMonitor.rounded(drive.movedBytes))
    }
}
