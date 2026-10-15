import BridgeSupport
import Foundation

// MARK: - The store's drive monitor

extension ArchiveStore {
    /// Probes the drive every `probeInterval` (5 s; backing off to 30 s while the folder refuses writes) and sooner when a recorder reports a
    /// failure or a read timed out. Never waits for a probe: a drive that hangs must not stop the check that says so.
    func monitorLoop(_ run: ArchiveRun) async {
        var interval = tuning.probeInterval
        while !Task.isCancelled {
            await probeWake.wait(timeout: interval)
            guard !Task.isCancelled, state.withLock({ $0.isCurrent(run) }) else { return }
            checkStall(run)
            if state.withLock({ $0.firstProbeDone }) {
                Task.detached(priority: .utility) { [weak self] in await self?.probe(run) }   // single flight: nothing happens while one is pending
            }
            let refusing = state.withLock { state -> Bool in
                if case .notWritable = state.pause, !state.stalled { return true }
                return false
            }
            interval = refusing ? min(interval * 2, .seconds(30)) : tuning.probeInterval
            publishStatus(force: false)
        }
    }

    /// One probe of the drive on the probe queue (single flight: nil while another is pending, and for a run that is over), then the pause it
    /// implies. `writeTest` also creates and deletes a probe file (done anyway after a recorder's failure and while writes are refused).
    @discardableResult
    func probe(_ run: ArchiveRun, writeTest: Bool = false) async -> Measurement? {
        let request = state.withLock { state -> (folder: URL, writeTest: Bool)? in
            guard state.isCurrent(run), let folder = state.folder, state.probeStartedAt == nil else { return nil }
            state.probeStartedAt = .now
            let test = writeTest || state.needsWriteTest
            state.needsWriteTest = false
            return (folder, test)
        }
        guard let request else { return nil }
        let policy = environment.archivePolicy, dataDirectory = environment.dataDirectory
        let measurement = await probes.run {
            VolumeMonitor.measure(folder: request.folder, policy: policy, dataDirectory: dataDirectory, writeTest: request.writeTest)
        }
        let outcome = state.withLock { state -> (pause: ArchivePause?, changed: Bool, reload: Bool)? in
            guard state.isCurrent(run) else { return nil }
            state.probeStartedAt = nil
            state.firstProbeDone = true
            state.stalled = false
            state.readsStalled = false
            state.folderExists = measurement.folderExists
            state.space = measurement.space
            state.floorBytes = measurement.floorBytes
            let before = state.pause
            state.pause = VolumeMonitor.decide(previous: before, folder: state.folder, measurement: measurement, stalled: false)
            if case .notWritable = state.pause { state.needsWriteTest = true }   // keep testing until a write works
            return (state.pause, state.pause != before, measurement.folderExists && state.reloadWhenFolderReturns)
        }
        guard let outcome else { return measurement }
        if outcome.changed {
            log.info(outcome.pause.map { "Recording is paused: \($0.code)" } ?? "Recording can go on")
            publishStatus(force: true)
            signal.notify()
        } else {
            publishStatus(force: false)
        }
        if outcome.reload { await loadCatalog(run) }
        return measurement
    }

    typealias Measurement = VolumeMonitor.Measurement

    /// A probe pending for `probeStallAfter` means the drive is not answering: recording pauses and reads fail at once until a probe returns.
    func checkStall(_ run: ArchiveRun) {
        let changed = state.withLock { state -> Bool in
            guard state.isCurrent(run), !state.stalled, let started = state.probeStartedAt,
                  started.duration(to: .now) >= tuning.probeStallAfter else { return false }
            state.stalled = true
            state.readsStalled = true
            state.pause = .notWritable(VolumeMonitor.notAnswering)
            return true
        }
        guard changed else { return }
        log.warning("The recordings drive is not answering")
        publishStatus(force: true)
        signal.notify()
    }
}
