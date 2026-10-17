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
    /// Does nothing without a total size for the drive (no measurement yet) or while the folder is missing.
    func runRetention(_ run: ArchiveRun) async {
        let plan = state.withLock { state -> (folder: URL, deletions: [RetentionCandidate], ageCutoffMs: Int64)? in
            guard state.isCurrent(run), state.isReady, let folder = state.folder, state.pause != .noFolder, state.pause != .folderMissing,
                  !state.stalled, let space = state.space, space.total > 0 else { return nil }
            let limits = ArchiveStorageStatus(totalBytes: space.total, floorBytes: state.floorBytes)
            let closed = state.catalog.closedFiles
                .filter { !state.owned.contains(ArchiveOpenFile(camera: $0.camera, segment: $0.segment)) && !state.removalFailed.contains($0.segment) }
                .map { RetentionCandidate(camera: $0.camera, segment: $0.segment, startMs: $0.startMs, endMs: $0.endMs, bytes: $0.bytes) }
            let input = RetentionPlanner.Input(closed: closed, openBytes: state.catalog.openFiles.reduce(0) { $0 + $1.bytes },
                                               newestStartMs: state.catalog.newestStartMs, nowMs: ArchiveTime.ms(tuning.now()),
                                               keepDays: state.keepDays, maximumBytes: limits.effectiveMaximumBytes(maxSizeGB: state.maxSizeGB))
            return (folder, RetentionPlanner.plan(input), input.nowMs - Int64(input.keepDays) * 86_400_000)
        }
        guard let plan, !plan.deletions.isEmpty else { return }
        var deleted = 0
        for candidate in plan.deletions {
            guard state.withLock({ $0.isCurrent(run) }) else { break }
            guard await delete(candidate, folder: plan.folder, run: run) else { continue }
            deleted += 1
            // A file the size rule took (it had not aged out): the events of the days before it go with it.
            if candidate.endMs >= plan.ageCutoffMs {
                state.withLock { state in
                    if state.isCurrent(run) { state.eventSizeCutoffMs = max(state.eventSizeCutoffMs ?? candidate.startMs, candidate.startMs) }
                }
            }
        }
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
    private func delete(_ candidate: RetentionCandidate, folder: URL, run: ArchiveRun) async -> Bool {
        let removed = state.withLock { state -> CatalogFile? in
            guard state.isCurrent(run), !state.owned.contains(ArchiveOpenFile(camera: candidate.camera, segment: candidate.segment)),
                  let file = state.catalog.file(camera: candidate.camera, segment: candidate.segment), !file.isOpen else { return nil }
            state.catalog.remove(segment: candidate.segment, camera: candidate.camera)
            state.blocks.remove(segment: candidate.segment)
            state.catalog.bump()
            return file
        }
        guard let removed else { return false }
        handles.retire(candidate.segment)
        let mp4 = Self.url(folder, candidate.segment, ArchiveConstants.mediaExtension)
        let sidecar = Self.url(folder, candidate.segment, ArchiveConstants.indexExtension)
        let remove = tuning.removeFile
        let today = Self.dateDirectoryName(tuning.now())
        let outcome = await onControl { () -> String? in
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
        if let failure = outcome {
            log.warning("A recording could not be deleted (\(failure)); it stays")
            state.withLock { state in
                guard state.isCurrent(run) else { return }
                state.catalog.insert(removed)
                state.catalog.bump()
                state.removalFailed.insert(candidate.segment)
            }
            return false
        }
        return true
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
