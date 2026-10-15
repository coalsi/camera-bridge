import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// What a recorder tells the store (`ArchiveWriteTarget`), played by the test on a real fixture file: the file is complete on disk, the store
/// is told about it fragment by fragment, and sees only what it was told.
@Suite struct ArchiveStoreWriteTargetTests {
    static let camera = ArchiveStoreHarness.camera
    static let start: Int64 = 1_760_101_200_000

    static func open(_ result: ArchiveFixtureResult) -> ArchiveOpenFile { ArchiveOpenFile(camera: camera, segment: result.file.segment) }

    /// A started store on an empty folder, and a six-fragment file the recorder is about to "write" (no sidecar yet).
    static func recording(plan: [ArchiveFixtureFragment]? = nil, startMs: Int64 = start, base: String = "13-00-00", date: String = "2026-10-10") async throws -> (ArchiveStoreHarness, ArchiveFixtureResult) {
        let harness = try ArchiveStoreHarness()
        await harness.start()
        let result = try harness.write(date: date, base: base, startMs: startMs, fragments: plan ?? Array(repeating: ArchiveFixtureFragment(), count: 6), writesIndex: false)
        return (harness, result)
    }

    @Test func aFragmentIsVisibleToReadersFromTheMomentTheRecorderSaysItsWriteReturned() async throws {
        let (harness, result) = try await Self.recording()
        let store = harness.store, file = Self.open(result)
        store.recorderOpened(file, startWallMs: Self.start, initLength: result.index.initLength, hasAudio: false)
        let none = await harness.ids()
        #expect(store.extent(camera: Self.camera) == nil && none.isEmpty, "an open file with no fragment holds nothing")
        for position in 0..<3 {
            let before = store.catalogVersion
            store.recorderWrote(file, result.index.fragments[position])
            #expect(store.catalogVersion == before + 1, "+1 per written fragment")
        }
        let ids = await harness.ids()
        #expect(ids.count == 3, "the fourth fragment is on disk but nobody said it was written")
        #expect(store.extent(camera: Self.camera)?.newest == ArchiveTime.date(ms: Self.start + 7_500))
        let fragment = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 6_000)))
        #expect(try await store.read(fragment, .fragment) == result.fragments[2], "an open file is read through its own read handle")
        #expect(try await store.read(fragment, .initialization) == result.initData)
        #expect(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 8_000)) == nil)
        store.recorderWrote(file, result.index.fragments[3])
        #expect(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 8_000))?.index == 3)
        #expect(store.writeState.pause == nil)
    }

    @Test func closingAFileTurnsItIntoAClosedOneWithItsIndexAndKeepsItReadable() async throws {
        let (harness, result) = try await Self.recording()
        let store = harness.store, file = Self.open(result)
        store.recorderOpened(file, startWallMs: Self.start, initLength: result.index.initLength, hasAudio: false)
        for record in result.index.fragments { store.recorderWrote(file, record) }
        let ids = await harness.ids()
        try result.index.encoded().write(to: result.sidecar)   // the recorder writes the sidecar, then closes
        let version = store.catalogVersion
        store.recorderClosed(file, index: result.index)
        #expect(store.catalogVersion == version + 1)
        let closed = try #require(store.state.withLock { $0.catalog.file(camera: Self.camera, segment: file.segment) })
        #expect(!closed.isOpen && closed.rollups == result.index.rollups && closed.sidecarBytes == UInt64(result.index.encoded().count))
        #expect(await harness.ids() == ids)
        #expect(store.state.withLock { $0.owned.isEmpty && $0.catalog.openTables.isEmpty })
        let fragment = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 1)))
        #expect(try await store.read(fragment, .keyframe).count == 6_004)
        // A store that is started again finds the same file by its sidecar.
        await store.stop()
        await harness.start()
        #expect(await harness.ids() == ids)
    }

    @Test func aFileAbandonedWithoutASidecarLeavesTheTimelineAndWaitsForARepair() async throws {
        let (harness, result) = try await Self.recording()
        let store = harness.store, file = Self.open(result)
        store.recorderOpened(file, startWallMs: Self.start, initLength: result.index.initLength, hasAudio: false)
        for record in result.index.fragments.prefix(4) { store.recorderWrote(file, record) }
        let beforeIDs = await harness.ids()
        #expect(beforeIDs.count == 4)
        store.recorderClosed(file, index: nil)
        let afterIDs = await harness.ids()
        #expect(afterIDs.isEmpty && store.extent(camera: Self.camera) == nil)
        #expect(store.state.withLock { $0.repairQueue[file.segment] } == Self.camera && store.state.withLock { $0.owned.isEmpty })
    }

    /// T13 check E08 on a real unmount: the recorder's write fails, it closes the file without a sidecar, and the janitor wakes on that close before the volume
    /// monitor has noticed the drive (here the monitor never runs on its own). The file is out of reach, which is not the same as deleted: it stays queued, and the
    /// repair finds it once the drive is back. Forgetting it hid the whole file from the timeline until the next start.
    ///
    /// The close wakes the janitor, which runs on its own task. The test waits for that pass to be over before the drive goes away and the clock jumps, and
    /// makes the pass it is about by hand: a pass that was half-way when the folder moved (it had looked at the file, then read the clock) would make the
    /// outcome depend on timing (`aDriveThatGoesAwayInTheMiddleOfARepairLeavesTheFileQueued` is that case, made to happen on purpose).
    @Test func aFileOutOfReachBecauseTheDriveJustWentAwayStaysQueuedForRepair() async throws {
        let harness = try ArchiveStoreHarness(probeInterval: .seconds(3_600))   // only a report wakes the monitor
        await harness.start()
        let result = try harness.write(date: "2026-10-10", base: "13-00-00", startMs: Self.start, fragments: Array(repeating: ArchiveFixtureFragment(), count: 6), writesIndex: false)
        let store = harness.store, file = Self.open(result)
        store.recorderOpened(file, startWallMs: Self.start, initLength: result.index.initLength, hasAudio: false)
        for record in result.index.fragments.prefix(4) { store.recorderWrote(file, record) }
        let passesBefore = store.state.withLock { $0.retentionPasses }
        store.recorderClosed(file, index: nil)                        // the write failed: closed without a sidecar; this wakes the janitor, once
        #expect(await eventually(timeout: archiveStorePatience) { store.state.withLock { $0.retentionPasses } > passesBefore }, "the janitor's pass for the close is over")
        let away = harness.root.url.deletingLastPathComponent().appending(path: "away-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: harness.root.url, to: away)   // the drive goes away
        harness.clock.update { $0 = Date().addingTimeInterval(ArchiveConstants.repairQuietPeriod + 60) }   // the file has been quiet long enough
        await store.repairQuiet(harness.run)                           // the janitor's pass, while the folder is out of reach
        #expect(store.state.withLock { $0.repairQueue[file.segment] } == Self.camera, "the file is out of reach, not gone: it stays queued")
        try FileManager.default.moveItem(at: away, to: harness.root.url)   // the drive is back
        await store.repairQuiet(harness.run)
        #expect(store.state.withLock { $0.repairQueue[file.segment] } == nil, "once the folder is reachable the entry is dealt with")
        let ids = await harness.ids()
        #expect(ids.count == 6, "and the repair brought the whole file back into the timeline")
        // A file that is gone from a reachable folder is forgotten at once.
        store.state.withLock { $0.repairQueue["13-01-00"] = Self.camera }
        await store.repairQuiet(harness.run)
        #expect(store.state.withLock { $0.repairQueue["13-01-00"] } == nil, "a file that is not there in a folder that is: forgotten")
    }

    /// The other way round: the janitor has looked at the file (it is there, and quiet) and starts the repair, and the drive goes away under it, so the repair
    /// finds nothing to index. That is the drive's doing and not the file's: the entry stays queued, and the repair that runs once the drive is back brings the
    /// whole recording into the timeline. The queue entry is put in by hand, so that no wake of the janitor can run a pass of its own beside this one.
    @Test func aDriveThatGoesAwayInTheMiddleOfARepairLeavesTheFileQueued() async throws {
        let pullTheDrive = Box<(@Sendable () -> Void)?>(nil)
        let repairs = Box(0)
        let harness = try ArchiveStoreHarness(probeInterval: .seconds(3_600), repair: { mp4, sidecar, camera in
            repairs.update { $0 += 1 }
            if let pull = pullTheDrive.value {                        // the first repair: the drive goes away in the middle of it
                pullTheDrive.set(nil)
                pull()
                throw CocoaError(.fileReadNoSuchFile)
            }
            return try IndexScanner.repair(mp4: mp4, sidecar: sidecar, camera: camera)
        })
        await harness.start()
        let result = try harness.write(date: "2026-10-10", base: "13-00-00", startMs: Self.start, fragments: Array(repeating: ArchiveFixtureFragment(), count: 6), writesIndex: false)
        let store = harness.store, file = Self.open(result)
        store.state.withLock { $0.repairQueue[file.segment] = Self.camera }   // as if a recorder had abandoned it
        harness.clock.update { $0 = Date().addingTimeInterval(ArchiveConstants.repairQuietPeriod + 60) }   // quiet long enough
        let away = harness.root.url.deletingLastPathComponent().appending(path: "away-\(UUID().uuidString)")
        let root = harness.root.url
        pullTheDrive.set { try? FileManager.default.moveItem(at: root, to: away) }
        await store.repairQuiet(harness.run)
        #expect(repairs.value == 1, "the file was there and quiet: the repair was tried")
        #expect(store.state.withLock { $0.repairQueue[file.segment] } == Self.camera, "the repair found nothing because the drive went away: the file stays queued")
        try FileManager.default.moveItem(at: away, to: harness.root.url)   // the drive is back
        await store.repairQuiet(harness.run)
        #expect(repairs.value == 2 && store.state.withLock { $0.repairQueue[file.segment] } == nil, "repaired once the folder is reachable")
        let ids = await harness.ids()
        #expect(ids.count == 6, "and the whole file is in the timeline")
    }

    @Test func aRecorderThatIsNotKnownChangesNothing() async throws {
        let (harness, result) = try await Self.recording()
        let store = harness.store, file = Self.open(result)
        let version = store.catalogVersion
        store.recorderWrote(file, result.index.fragments[0])               // never opened
        store.recorderClosed(file, index: result.index)                    // never opened
        #expect(store.catalogVersion == version && store.state.withLock { $0.catalog.isEmpty })
        // A recorder that was told to leave an old folder closes its file after the folder changed: ignored.
        store.recorderOpened(file, startWallMs: Self.start, initLength: result.index.initLength, hasAudio: false)
        let other = try TemporaryDirectory()
        defer { other.remove() }
        await store.settingsChanged(from: harness.settings(), to: harness.settings(folder: other.url))
        #expect(await eventually(timeout: archiveStorePatience) { store.isReady })
        store.recorderWrote(file, result.index.fragments[0])
        store.recorderClosed(file, index: result.index)
        #expect(store.state.withLock { $0.catalog.isEmpty && $0.owned.isEmpty }, "the old folder's file is not in the new folder's catalog")
    }

    @Test func aFileOwnedByARecorderIsNeverDeletedOrRepaired() async throws {
        let (harness, result) = try await Self.recording(startMs: Self.start - 30 * 86_400_000)   // a month old
        let store = harness.store, file = Self.open(result)
        store.recorderOpened(file, startWallMs: Self.start - 30 * 86_400_000, initLength: result.index.initLength, hasAudio: false)
        for record in result.index.fragments { store.recorderWrote(file, record) }
        store.state.withLock { $0.repairQueue[file.segment] = Self.camera }   // even if something queued a repair for it
        await store.runRetention(harness.run)
        await store.repairQuiet(harness.run)
        #expect(harness.removed.value.isEmpty && FileManager.default.fileExists(atPath: result.mp4.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: result.sidecar.path(percentEncoded: false)), "no sidecar was written for the open file")
        // Closed, it is an ordinary old file.
        try result.index.encoded().write(to: result.sidecar)
        // The close wakes the janitor, which deletes the old file on its own task. Whichever of its pass and the one below finds the file first deletes it, and
        // the other finds nothing to do and returns at once, so the list of what was removed is read only after the janitor's pass is over.
        let passesBefore = store.state.withLock { $0.retentionPasses }
        store.recorderClosed(file, index: result.index)
        #expect(await eventually(timeout: archiveStorePatience) { store.state.withLock { $0.retentionPasses } > passesBefore }, "the janitor's pass for the close is over")
        await store.runRetention(harness.run)
        #expect(harness.removed.value.sorted() == ["13-00-00.cbidx", "13-00-00.mp4"])
    }

    @Test func theKeyframeIntervalIsMeasuredFromTheKeyFragmentsAsTheyArrive() async throws {
        let plan = [ArchiveFixtureFragment(), ArchiveFixtureFragment(), ArchiveFixtureFragment(startsOnKey: false), ArchiveFixtureFragment(startsOnKey: false), ArchiveFixtureFragment(startsOnKey: false), ArchiveFixtureFragment()]
        let (harness, result) = try await Self.recording(plan: plan)
        let store = harness.store, file = Self.open(result)
        store.recorderOpened(file, startWallMs: Self.start, initLength: result.index.initLength, hasAudio: false)
        store.recorderWrote(file, result.index.fragments[0])
        #expect(store.extent(camera: Self.camera)?.typicalGOP == nil, "one keyframe: no interval yet")
        for record in result.index.fragments.dropFirst() { store.recorderWrote(file, record) }
        // Keyframes at 0 s, 2.5 s and 12.5 s: intervals of 2.5 and 10 s, the median 6.25 s.
        #expect(store.extent(camera: Self.camera)?.typicalGOP == 6.25)
    }

    @Test func aWriteFailureMakesTheStoreTestTheFolderAtOnce() async throws {
        guard ProcessInfo.processInfo.userName != "root" else { return }
        let harness = try ArchiveStoreHarness(probeInterval: .seconds(3_600))   // only a report wakes the monitor
        await harness.start()
        #expect(harness.store.writeState.pause == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: harness.root.url.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: harness.root.url.path(percentEncoded: false)) }
        harness.store.recorderFailed(camera: Self.camera, "a write failed")
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.writeState.pause == .notWritable("Camera Bridge can’t write to that folder.") })
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.storageStatus?.pause == .notWritable("Camera Bridge can’t write to that folder.") })
        // The folder works again: the next test of it (writes are tested again and again while they fail) clears the pause.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: harness.root.url.path(percentEncoded: false))
        await harness.store.probe(harness.run)
        #expect(harness.store.writeState.pause == nil)
    }

    @Test func aDriveBelowTheFloorPausesAndResumesWithHysteresis() async throws {
        let harness = try ArchiveStoreHarness(free: 100 * ArchiveStoreHarness.gb)
        await harness.start()
        let floor = ArchiveConstants.otherVolumeFloorBytes
        #expect(harness.store.writeState.pause == nil)
        harness.space.set(VolumeMonitor.Space(total: 500 * ArchiveStoreHarness.gb, free: floor - 1))
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.writeState.pause == .diskFull })
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.storageStatus?.pause == .diskFull }, "the storage status says so too")
        harness.space.set(VolumeMonitor.Space(total: 500 * ArchiveStoreHarness.gb, free: floor + ArchiveConstants.resumeMarginBytes - 1))
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.store.writeState.pause == .diskFull, "not yet: it must be 1 GiB above the floor")
        harness.space.set(VolumeMonitor.Space(total: 500 * ArchiveStoreHarness.gb, free: floor + ArchiveConstants.resumeMarginBytes))
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.writeState.pause == nil })
        #expect(harness.removed.value.isEmpty, "a full drive deletes nothing")
    }

    @Test func theStorageStatusIsRoundedAndFollowsTheDrive() async throws {
        let harness = try ArchiveStoreHarness(total: 128_000_000_000, free: 60_123_456_789, isSystemVolume: true)
        await harness.start()
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.storageStatus?.totalBytes == 128_000_000_000 })
        let status = try #require(harness.store.storageStatus)
        #expect(status.freeBytes == 60_120_000_000, "rounded down to 10 MB")
        #expect(status.floorBytes == ArchivePlatformPolicy.linuxSystemFloor(total: 128_000_000_000) && status.floorBytes == 8 * ArchiveConstants.resumeMarginBytes)
        #expect(status.spareBytes == 60_120_000_000 - status.floorBytes && status.roomBytes == status.usedBytes + status.spareBytes)
        harness.space.set(VolumeMonitor.Space(total: 128_000_000_000, free: 50_000_000_000))
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.storageStatus?.freeBytes == 50_000_000_000 })
    }

    @Test func numbersThatMoveAreRefreshedAtMostOncePerRefreshPeriodButAPauseShowsAtOnce() async throws {
        let harness = try ArchiveStoreHarness(free: 100 * ArchiveStoreHarness.gb, statusRefresh: .seconds(3_600))
        await harness.start()
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.storageStatus?.freeBytes == 100 * ArchiveStoreHarness.gb })
        harness.space.set(VolumeMonitor.Space(total: 500 * ArchiveStoreHarness.gb, free: 90 * ArchiveStoreHarness.gb))
        try await Task.sleep(for: .milliseconds(300))   // several probes later
        #expect(harness.store.storageStatus?.freeBytes == 100 * ArchiveStoreHarness.gb, "within the refresh period the published numbers stay")
        harness.space.set(VolumeMonitor.Space(total: 500 * ArchiveStoreHarness.gb, free: ArchiveConstants.otherVolumeFloorBytes - 1))
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.storageStatus?.pause == .diskFull }, "a pause is published at once, with the numbers of that moment")
        #expect(harness.store.storageStatus?.freeBytes == VolumeMonitor.rounded(ArchiveConstants.otherVolumeFloorBytes - 1))
    }
}
