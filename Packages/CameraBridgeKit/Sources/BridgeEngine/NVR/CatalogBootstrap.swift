import BridgeSupport
import Foundation

// The store's background work at the start of a run and when the drive returns: probe, repair unclosed files, load the catalog, measure the
// keyframe interval. (The folder is read by `CatalogLoader`, the unclosed files rebuilt by `IndexScanner`.)

extension ArchiveStore {
    /// Runs blocking work on the control queue (directory listing, repair, deletion): never on the cooperative pool.
    func onControl<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            control.async { continuation.resume(returning: work()) }
        }
    }

    /// Starts the background work of `run` (replacing the work of an older run): the first probe and load, the drive monitor and the janitor.
    func launch(_ run: ArchiveRun) {
        let old = state.withLock { state -> [Task<Void, Never>] in
            defer { state.tasks = [] }
            return state.tasks
        }
        old.forEach { $0.cancel() }
        let tasks: [Task<Void, Never>] = [
            Task.detached(priority: .utility) { [weak self] in await self?.bootstrap(run) },
            Task.detached(priority: .utility) { [weak self] in await self?.monitorLoop(run) },
            Task.detached(priority: .utility) { [weak self] in await self?.retentionLoop(run) },
        ]
        let kept = state.withLock { state -> Bool in
            guard state.isCurrent(run) else { return false }
            state.tasks += tasks
            return true
        }
        if !kept { tasks.forEach { $0.cancel() } }
    }

    /// Probe the drive, load the catalog (repairing unclosed files first), run retention once. Recorders wait for `isReady`.
    func bootstrap(_ run: ArchiveRun) async {
        defer {
            state.withLock { state in
                if state.isCurrent(run) { state.isSettled = true }
            }
        }
        guard state.withLock({ $0.isCurrent(run) && $0.folder != nil }) else { return }
        let measurement = await probe(run)
        guard state.withLock({ $0.isCurrent(run) }) else { return }
        if measurement?.folderExists == true {
            await loadCatalog(run)
        } else {
            // The drive is not there: nothing to list. The first load happens when it returns (`probe`).
            state.withLock { state in
                guard state.isCurrent(run) else { return }
                state.isReady = true
                state.reloadWhenFolderReturns = true
            }
            signal.notify()
        }
        if tuning.retentionAtStart { await runRetention(run) }
        await seedKeyIntervals(run)
    }

    /// Reads the folder into the catalog and says it is ready. Files with a missing, stale or untrusted index are rebuilt first (nobody owns
    /// a file at this point: recorders wait for `isReady`).
    func loadCatalog(_ run: ArchiveRun) async {
        guard let folder = state.withLock({ state in state.isCurrent(run) ? state.folder : nil }) else { return }
        let scan = await onControl { [self] in CatalogLoader.scan(root: folder, isCancelled: { !self.state.withLock { $0.isCurrent(run) } }) }
        guard state.withLock({ $0.isCurrent(run) }) else { return }
        var loaded: [(file: CatalogFile, table: [CBIndexFragmentRecord]?)] = scan.files.map { ($0, nil) }
        var repaired = 0
        for candidate in scan.needsRepair {
            // A file a recorder has open is not repaired, whatever it looks like on disk.
            guard state.withLock({ $0.isCurrent(run) && !$0.owned.contains(ArchiveOpenFile(camera: candidate.camera, segment: candidate.segment)) }) else { continue }
            if let result = await rebuildIndex(segment: candidate.segment, camera: candidate.camera, folder: folder) {
                loaded.append((result.file, result.table))
                repaired += 1
            }
        }
        let done = state.withLock { state -> Bool in
            guard state.isCurrent(run) else { return false }
            // Files a recorder has open (it started meanwhile) stay; everything else is replaced by what was read.
            for file in state.catalog.closedFiles { state.catalog.remove(segment: file.segment, camera: file.camera) }
            let adopted = loaded.filter { !state.owned.contains(ArchiveOpenFile(camera: $0.file.camera, segment: $0.file.segment)) }
            state.catalog.insert(batch: adopted.map(\.file))
            for item in adopted { if let table = item.table { state.catalog.store(table: table, forSegment: item.file.segment) } }
            state.isReady = true
            state.reloadWhenFolderReturns = false
            state.removalFailed = []
            return true
        }
        guard done else { return }
        if repaired > 0 { log.info("Repaired \(repaired) recordings that were not closed properly") }
        if scan.unreadableDirectories > 0 { log.warning("\(scan.unreadableDirectories) folders of the recordings could not be read") }
        publishStatus(force: true)
        signal.notify()
    }

    /// Rebuilds the index of an unowned mp4 (cuts a torn tail, writes the sidecar). nil when there is nothing to index.
    func rebuildIndex(segment: String, camera: UUID, folder: URL) async -> (file: CatalogFile, table: [CBIndexFragmentRecord])? {
        let mp4 = Self.url(folder, segment, ArchiveConstants.mediaExtension)
        let sidecar = Self.url(folder, segment, ArchiveConstants.indexExtension)
        let repair = tuning.repair
        let outcome = await onControl { () -> IndexScanOutcome? in try? repair(mp4, sidecar, camera) }
        guard case .indexed(let index, _, _)? = outcome else { return nil }
        let sidecarBytes = UInt64(CBIndexFile.byteCount(rollups: index.rollups.count, fragments: index.fragments.count))
        return (CatalogFile(segment: segment, index: index, sidecarBytes: sidecarBytes), index.fragments)
    }

    /// The typical keyframe interval of each camera from its newest file, until live recording measures it.
    func seedKeyIntervals(_ run: ArchiveRun) async {
        let candidates = state.withLock { state -> [(camera: UUID, segment: String)] in
            guard state.isCurrent(run) else { return [] }
            return state.catalog.cameras.compactMap { camera in
                guard state.keyIntervals[camera] == nil,
                      let file = state.catalog.files[camera]?.last(where: { !$0.isOpen && $0.fragmentCount > 1 }) else { return nil }
                return (camera, file.segment)
            }
        }
        for candidate in candidates {
            guard await loadTable(camera: candidate.camera, segment: candidate.segment) else { continue }
            state.withLock { state in
                guard state.isCurrent(run), state.keyIntervals[candidate.camera] == nil,
                      let table = state.catalog.table(forSegment: candidate.segment) else { return }
                let keys = table.filter(\.hasKeyframe).map(\.mediaStart)
                let intervals = zip(keys.dropFirst(), keys).map { Double($0 - $1) / Double(ArchiveConstants.videoTimescale) }
                if !intervals.isEmpty { state.keyIntervals[candidate.camera] = Array(intervals.suffix(16)) }
            }
        }
    }
}
