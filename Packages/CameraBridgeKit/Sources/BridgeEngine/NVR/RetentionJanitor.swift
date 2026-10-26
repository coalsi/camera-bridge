import BridgeSupport
import Foundation

// MARK: - The store's janitor: retention and the repair of abandoned files

extension ArchiveStore {
    /// Runs at start (after the load), every `retentionInterval`, after each file close and after a settings change.
    func retentionLoop(_ run: ArchiveRun) async {
        while !Task.isCancelled {
            await retentionWake.wait(timeout: tuning.retentionInterval)
            guard !Task.isCancelled, state.withLock({ $0.isCurrent(run) }) else { return }
            await runRetention(run)
            await pruneEvents(run)
            await repairQuiet(run)
            handles.sweep(grace: tuning.deletedHandleGrace)
            state.withLock { $0.retentionPasses += 1 }
        }
    }

    /// One pass of the two retention rules (`RetentionPlanner`) over the closed files of every camera directory that holds a `camera.json`.
    /// Does nothing without a total size for the drive (no measurement yet) or while the folder is missing. With an archive drive that is
    /// connected, loaded and answering, the size rule moves files there instead of deleting them (`RetentionPlanner.plan(_:archive:)`; the mover
    /// does the moves, one at a time, `ArchiveMover+Store.swift`), and the archive's own files go by its rules; without one it is today's pass.
    func runRetention(_ run: ArchiveRun) async {
        let plan = state.withLock { state -> (folder: URL, archiveFolder: URL?, plan: RetentionPlanner.TieredPlan, ageCutoffMs: Int64)? in
            guard state.isCurrent(run), state.isReady, let folder = state.folder, state.pause != .noFolder, state.pause != .folderMissing,
                  !state.stalled, let space = state.space, space.total > 0 else { return nil }
            let limits = ArchiveStorageStatus(totalBytes: space.total, floorBytes: state.floorBytes)
            let moving = state.drive.moving?.segment
            let closed = state.catalog.closedFiles(on: .main)
                .filter { !state.owned.contains(ArchiveOpenFile(camera: $0.camera, segment: $0.segment)) && !state.removalFailed.contains($0.segment) && $0.segment != moving }
                .map { RetentionCandidate(camera: $0.camera, segment: $0.segment, startMs: $0.startMs, endMs: $0.endMs, bytes: $0.bytes) }
            // The file being moved is no candidate, but it is on the box until the move ends (a mover stuck on a hung drive keeps it there), and so
            // is the box's copy of a moved file until it is deleted (it waits while the drive is away): their bytes count, like an open file's, so
            // the box's limits hold whatever the mover does.
            let movingBytes = state.drive.moving.flatMap { item in state.catalog.file(camera: item.move.camera, segment: item.segment) }
                .flatMap { $0.tier == .main && !$0.isOpen ? $0.bytes : nil } ?? 0
            let leftBytes = state.drive.pendingMainRemovals.values.reduce(movingBytes) { $0 + $1.bytes }
            let input = RetentionPlanner.Input(closed: closed, openBytes: state.catalog.openFiles.reduce(leftBytes) { $0 + $1.bytes },
                                               newestStartMs: state.catalog.newestStartMs, nowMs: ArchiveTime.ms(tuning.now()),
                                               keepDays: state.keepDays, maximumBytes: limits.effectiveMaximumBytes(maxSizeGB: state.maxSizeGB))
            let archive = Self.archiveInput(state, mainLimits: limits, now: tuning.now())
            let plan = RetentionPlanner.plan(input, archive: archive)
            if archive == nil { state.drive.plannedMoves = [] }
            return (folder, archive != nil ? state.drive.folder : nil, plan, input.nowMs - Int64(input.keepDays) * 86_400_000)
        }
        guard let plan else { return }
        defer {
            // The moves last: after the archive let go of what makes room for them.
            let moves = plan.plan.moves
            state.withLock { state in
                guard state.isCurrent(run) else { return }
                state.drive.plannedMoves = plan.archiveFolder != nil && state.drive.isUsable(now: tuning.now()) ? moves : []
            }
            if !moves.isEmpty { moveWake.notify() }
        }
        guard !plan.plan.deletions.isEmpty || !plan.plan.archiveDeletions.isEmpty else { return }
        let tiered = plan.archiveFolder != nil
        var deleted = 0
        var sizeDeletedStart: Int64?
        for candidate in plan.plan.deletions {
            guard state.withLock({ $0.isCurrent(run) }) else { break }
            guard await delete(candidate, folder: plan.folder, tier: .main, run: run) else { continue }
            deleted += 1
            // A file the size rule took (it had not aged out): the events of the days before it go with it.
            if candidate.endMs >= plan.ageCutoffMs { sizeDeletedStart = max(sizeDeletedStart ?? candidate.startMs, candidate.startMs) }
        }
        // The archive's own deletions, on its own queue and with a deadline: a USB drive that hangs must not hold up the next pass on the box's disk
        // (they go on by themselves if they finish later; the drive is "not answering" meanwhile and nothing more is planned for it).
        var archived = 0
        if let archiveFolder = plan.archiveFolder, !plan.plan.archiveDeletions.isEmpty {
            let ageCutoffMs = plan.ageCutoffMs
            let candidates = plan.plan.archiveDeletions
            let outcome = try? await withDeadline(tuning.archiveDeletionDeadline) { [self] () -> (count: Int, newestSizeDeleted: Int64?) in
                var count = 0
                var newest: Int64?
                for candidate in candidates {
                    guard state.withLock({ $0.isCurrent(run) && $0.drive.connection == .connected }) else { break }
                    guard await delete(candidate, folder: archiveFolder, tier: .archive, run: run) else { continue }
                    count += 1
                    if candidate.endMs >= ageCutoffMs { newest = max(newest ?? candidate.startMs, candidate.startMs) }
                }
                return (count, newest)
            }
            if let outcome {
                archived = outcome.count
                if let newest = outcome.newestSizeDeleted { sizeDeletedStart = max(sizeDeletedStart ?? newest, newest) }
            } else {
                log.warning("Deleting old recordings from the archive drive did not finish in time; the box goes on without waiting for it")
            }
        }
        if let start = sizeDeletedStart {
            state.withLock { state in
                guard state.isCurrent(run) else { return }
                // With an archive the two drives do not delete in one order (the box deletes over its hard limit while the archive keeps older
                // files): the events go only up to the oldest recording that is still kept, on either drive.
                let cutoff = tiered ? min(start, state.catalog.oldestStartMs ?? start) : start
                state.eventSizeCutoffMs = max(state.eventSizeCutoffMs ?? cutoff, cutoff)
            }
        }
        if archived > 0 {
            log.info("Deleted \(archived) old recordings from the archive drive")
            state.withLock { $0.drive.indexDirty = true }
            let grace = tuning.deletedHandleGrace
            Task.detached { [weak self] in
                try? await Task.sleep(for: grace)
                self?.archiveHandles.sweep(grace: grace)
            }
        }
        if archived > 0, deleted == 0 { publishStatus(force: true) }
        if deleted > 0 {
            log.info("Deleted \(deleted) old recordings")
            publishStatus(force: true)
            // The descriptors on the deleted files close once the grace has passed: until then a reader in the middle of one finishes.
            let grace = tuning.deletedHandleGrace
            Task.detached { [weak self] in
                try? await Task.sleep(for: grace)
                self?.handles.sweep(grace: grace)
            }
        }
    }

    /// Takes the file out of the catalog (so no reader is pointed at it), then deletes the mp4 before its sidecar and removes an empty date
    /// directory of an earlier day. A file that cannot be deleted goes back into the catalog and is not tried again until the folder is loaded again.
    /// `tier`: the drive the file is on (an archive file is deleted on the archive's own queue, so a slow USB drive holds up nothing else).
    private func delete(_ candidate: RetentionCandidate, folder: URL, tier: StorageTier, run: ArchiveRun) async -> Bool {
        let removed = state.withLock { state -> CatalogFile? in
            guard state.isCurrent(run), !state.owned.contains(ArchiveOpenFile(camera: candidate.camera, segment: candidate.segment)),
                  state.drive.moving?.segment != candidate.segment,
                  let file = state.catalog.file(camera: candidate.camera, segment: candidate.segment), !file.isOpen, file.tier == tier else { return nil }
            state.catalog.remove(segment: candidate.segment, camera: candidate.camera)
            state.blocks.remove(segment: candidate.segment)
            state.catalog.bump()
            return file
        }
        guard let removed else { return false }
        (tier == .archive ? archiveHandles : handles).retire(candidate.segment)
        let mp4 = Self.url(folder, candidate.segment, ArchiveConstants.mediaExtension)
        let sidecar = Self.url(folder, candidate.segment, ArchiveConstants.indexExtension)
        let remove = tuning.removeFile
        let today = Self.dateDirectoryName(tuning.now())
        let work = { @Sendable () -> String? in
            do {
                try remove(mp4)
            } catch where !Self.isMissing(error) {
                return ArchiveErrors.brief(error)
            } catch {}
            do { try remove(sidecar) } catch {}
            let dateDirectory = mp4.deletingLastPathComponent()
            if dateDirectory.lastPathComponent < today,
               let remaining = try? FileManager.default.contentsOfDirectory(atPath: ArchiveVolume.path(of: dateDirectory)), remaining.isEmpty {
                try? FileManager.default.removeItem(at: dateDirectory)
            }
            return nil
        }
        let outcome = tier == .archive ? await onDriveControl(work) : await onControl(work)
        if let failure = outcome {
            log.warning("A recording could not be deleted\(tier == .archive ? " from the archive drive" : "") (\(failure)); it stays")
            state.withLock { state in
                guard state.isCurrent(run) else { return }
                state.catalog.insert(removed)
                state.catalog.bump()
                if tier == .archive { state.drive.removalFailed.insert(candidate.segment) } else { state.removalFailed.insert(candidate.segment) }
            }
            return false
        }
        return true
    }

    /// What retention needs of the archive drive, or nil when there is none to use now (not chosen, away, not answering, failing, not loaded,
    /// not measured): the plan is then today's.
    static func archiveInput(_ state: ArchiveStoreState, mainLimits: ArchiveStorageStatus, now: Date) -> RetentionPlanner.ArchiveInput? {
        let drive = state.drive
        guard drive.isUsable(now: now), let space = drive.space else { return nil }
        let reserve = drive.floorBytes.multipliedReportingOverflow(by: 2).partialValue
        let closed = state.catalog.closedFiles(on: .archive).filter { !drive.removalFailed.contains($0.segment) }
            .map { RetentionCandidate(camera: $0.camera, segment: $0.segment, startMs: $0.startMs, endMs: $0.endMs, bytes: $0.bytes) }
        return RetentionPlanner.ArchiveInput(closed: closed, maximumBytes: space.total > reserve ? space.total - reserve : 0, freeBytes: space.free,
                                             floorBytes: drive.floorBytes, unmovable: drive.unmovable.union(drive.shadowed.keys),
                                             mainHardMaximumBytes: mainLimits.hardMaximumBytes)
    }

    /// Rebuilds the index of the files a recorder abandoned (or that were found damaged) once they have been quiet for `repairQuietPeriod`.
    func repairQuiet(_ run: ArchiveRun) async {
        let pending = state.withLock { state -> (folder: URL, items: [(segment: String, camera: UUID)])? in
            guard state.isCurrent(run), state.isReady, let folder = state.folder, !state.repairQueue.isEmpty, state.pause != .folderMissing,
                  !state.stalled else { return nil }
            let items = state.repairQueue.filter { !state.owned.contains(ArchiveOpenFile(camera: $0.value, segment: $0.key)) }
            return (folder, items.map { (segment: $0.key, camera: $0.value) }.sorted { $0.segment < $1.segment })
        }
        guard let pending else { return }
        for item in pending.items {
            guard state.withLock({ $0.isCurrent(run) }) else { return }
            let mp4 = Self.url(pending.folder, item.segment, ArchiveConstants.mediaExtension)
            guard let modified = await onControl({ CatalogLoader.attributes(mp4)?.modified }) else {
                // Not there. The file is gone only when its folder is still there: a drive that went away a moment ago (the recorder's failed write woke
                // this pass before the volume monitor said so) takes its files out of reach, and forgetting them hid a whole recording from the timeline
                // until the next start. They stay queued until the drive is back.
                if await folderIsReachable(pending.folder) { state.withLock { $0.repairQueue[item.segment] = nil } }   // the file is gone
                continue
            }
            guard tuning.now().timeIntervalSince(modified) >= ArchiveConstants.repairQuietPeriod else { continue }   // maybe still being written
            let result = await rebuildIndex(segment: item.segment, camera: item.camera, folder: pending.folder)
            // The same rule one step later: the drive can go away between the look at the file above and the repair, which then finds nothing to index.
            // That is the drive's doing, not the file's: the entry stays queued until the folder is back.
            if result == nil, !(await folderIsReachable(pending.folder)) { continue }
            state.withLock { state in
                state.repairQueue[item.segment] = nil
                guard state.isCurrent(run), let result, !state.owned.contains(ArchiveOpenFile(camera: item.camera, segment: item.segment)) else { return }
                state.blocks.remove(segment: item.segment)
                state.catalog.insert(result.file, table: result.table)
                state.catalog.bump()
            }
        }
    }

    /// The recordings folder is there and is a folder. While it is not, a file that cannot be found or read is out of reach with its drive, not gone.
    private func folderIsReachable(_ folder: URL) async -> Bool {
        await onControl {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: ArchiveVolume.path(of: folder), isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// "2026-10-10": the date directory of `date` in local time.
    static func dateDirectoryName(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func isMissing(_ error: any Error) -> Bool { ArchiveErrors.map(error) == .fileGone }
}
