import Dispatch
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// A store over a fixture folder, with a fake drive (its free space is a number the test sets), a clock the test moves and a log of what
/// retention deleted. Probes every 50 ms, so a drive that stops answering is noticed within a third of a second.
final class ArchiveStoreHarness: Sendable {
    static let gb: UInt64 = 1_000_000_000
    /// The default clock: one hour after the default fixture file starts.
    static let now = Date(timeIntervalSince1970: 1_760_101_200 + 3_600)
    static let camera = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    let root: TemporaryDirectory
    let dataDirectory: TemporaryDirectory
    let space: Box<VolumeMonitor.Space?>
    let clock: Box<Date>
    let removed = Box<[String]>([])
    let failRemoval = Box<Set<String>>([])
    let spaceCalls = Box(0)
    let signal = ChangeSignal()
    let store: ArchiveStore

    /// `spaceGate`: when set, the drive's `space` call blocks on it (a drive that hangs). `repair` (after `populate`, so that a trailing closure is still `populate`): replaces the scanner's repair of an
    /// unowned file (a test that needs a slow or failing one).
    init(total: UInt64 = 500 * ArchiveStoreHarness.gb, free: UInt64 = 400 * ArchiveStoreHarness.gb, now: Date = ArchiveStoreHarness.now, isSystemVolume: Bool = false,
         spaceGate: DispatchSemaphore? = nil, readDeadline: Duration = .seconds(5), probeInterval: Duration = .milliseconds(50), statusRefresh: Duration = .milliseconds(50), probeStallAfter: Duration = .seconds(5), retentionAtStart: Bool = false,
         deletedHandleGrace: Duration = .zero, logs: Bool = false,
         populate: (URL) throws -> Void = { _ in }, repair: (@Sendable (URL, URL, UUID) throws -> IndexScanOutcome)? = nil) throws {
        root = try TemporaryDirectory()
        dataDirectory = try TemporaryDirectory()
        try populate(root.url)
        let space = Box<VolumeMonitor.Space?>(VolumeMonitor.Space(total: total, free: free))
        let clock = Box(now)
        let spaceCalls = self.spaceCalls
        let removed = self.removed, failRemoval = self.failRemoval
        self.space = space
        self.clock = clock
        var environment = BridgeEnvironment.inert(directory: dataDirectory.url)
        environment.archivePolicy = ArchivePlatformPolicy(
            space: { _ in
                spaceCalls.update { $0 += 1 }
                spaceGate?.wait()
                return space.value.map { (total: $0.total, free: $0.free) }
            },
            isSystemVolume: { _ in isSystemVolume }, systemFloor: ArchivePlatformPolicy.linuxSystemFloor, directoryNaming: .cameraID)
        var tuning = ArchiveStoreTuning()
        tuning.now = { clock.value }
        tuning.probeInterval = probeInterval
        tuning.statusRefresh = statusRefresh
        tuning.retentionAtStart = retentionAtStart
        tuning.log = logs ? .standard : .silent
        tuning.probeStallAfter = probeStallAfter
        tuning.retentionInterval = .seconds(3_600)
        tuning.readDeadline = readDeadline
        tuning.deletedHandleGrace = deletedHandleGrace
        if let repair { tuning.repair = repair }
        tuning.removeFile = { url in
            let path = url.path(percentEncoded: false)
            if failRemoval.value.contains(where: { path.hasSuffix($0) }) { throw CocoaError(.fileWriteNoPermission) }
            removed.update { $0.append(url.lastPathComponent) }
            try FileManager.default.removeItem(at: url)
        }
        store = ArchiveStore(environment: environment, signal: signal, tuning: tuning)
    }

    deinit {
        store.shutDown()   // its background work ends with the test, not a few probes later
        root.remove()
        dataDirectory.remove()
    }

    func settings(folder: URL? = nil, keepDays: Int = 7, maxSizeGB: Int = 500) -> BridgeSettings {
        var settings = BridgeSettings()
        settings.nvrFolder = (folder ?? root.url).path(percentEncoded: false)
        settings.nvrKeepDays = keepDays
        settings.nvrMaxSizeGB = maxSizeGB
        return settings
    }

    /// Starts the store on `settings` and waits until its start-up work is over (ready, and nothing more going on behind the test's back).
    @discardableResult
    func start(_ settings: BridgeSettings? = nil) async -> Bool {
        store.start(settings: settings ?? self.settings())
        return await eventually(timeout: archiveStorePatience) { store.isSettled }
    }

    /// A real fixture file in the harness's folder (the camera's directory is its UUID, as on the box).
    @discardableResult
    func write(camera: UUID = ArchiveStoreHarness.camera, date: String = "2026-10-10", base: String = "13-00-00", startMs: Int64 = 1_760_101_200_000,
               fragments: [ArchiveFixtureFragment] = Array(repeating: ArchiveFixtureFragment(), count: 6), hasAudio: Bool = false, writesIndex: Bool = true) throws -> ArchiveFixtureResult {
        try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: camera, cameraDirectory: camera.uuidString, date: date, baseName: base, startMs: startMs, fragments: fragments,
                                                   hasAudio: hasAudio, writesIndex: writesIndex), root: root.url)
    }

    /// Every fragment id of `camera` in time order, found by walking `startingAfter`.
    func ids(camera: UUID = ArchiveStoreHarness.camera) async -> [String] {
        var ids: [String] = []
        var cursor = Date(timeIntervalSince1970: 0)
        while let fragment = await store.fragment(camera: camera, startingAfter: cursor) {
            ids.append(fragment.id)
            cursor = fragment.start
        }
        return ids
    }

    var run: ArchiveRun { store.currentRun }

    /// The size of every mp4 and sidecar in the folder.
    func bytesOnDisk() -> UInt64 {
        let files = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: [.fileSizeKey])?.compactMap { $0 as? URL } ?? []
        return files.filter { ["mp4", "cbidx"].contains($0.pathExtension) }.reduce(0) { $0 + UInt64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

/// Start, ready, stop, a drive that is not there or does not answer, and a new folder (Mac spec 4.5, 5, 6; addendum L5.1).
@Suite struct ArchiveStoreLifecycleTests {
    @Test func theStoreIsNotReadyUntilItIsStartedAndLoaded() async throws {
        let harness = try ArchiveStoreHarness { _ in }
        let store = harness.store
        #expect(!store.isReady && store.catalogVersion == 0 && store.storageStatus == nil && store.extent(camera: ArchiveStoreHarness.camera) == nil)
        #expect(store.writeState == ArchiveWriteState(folder: nil, pause: nil, isReady: false, generation: 0))
        #expect(await store.fragment(camera: ArchiveStoreHarness.camera, containing: ArchiveStoreHarness.now) == nil)
        let activity = await store.activity(camera: ArchiveStoreHarness.camera, range: ArchiveStoreHarness.now.addingTimeInterval(-60)..<ArchiveStoreHarness.now, binCount: 4)
        #expect(!activity.isComplete && activity.bins.isEmpty)
        let fragment = ArchiveFragment(camera: ArchiveStoreHarness.camera, segment: "c/2026-10-10/13-00-00", index: 0, start: Date(), duration: 1, mediaStart: 0, hasKeyframe: true,
                                       gopStart: Date(), backToKey: 0, byteLength: 10)
        await #expect(throws: ArchiveError.self) { try await store.read(fragment, .fragment) }
    }

    @Test func startReturnsAtOnceAndTheCatalogLoadsInTheBackground() async throws {
        let harness = try ArchiveStoreHarness { root in
            for position in 0..<3 {
                try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: ArchiveStoreHarness.camera, cameraDirectory: ArchiveStoreHarness.camera.uuidString, baseName: String(format: "13-%02d-00", position * 15),
                                                           startMs: 1_760_101_200_000 + Int64(position) * 900_000), root: root)
            }
        }
        let started = ContinuousClock.now
        harness.store.start(settings: harness.settings())
        #expect(ContinuousClock.now - started < .seconds(2), "start() does no disk work")
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.isReady })
        let store = harness.store
        let extent = try #require(store.extent(camera: ArchiveStoreHarness.camera))
        #expect(extent.oldest == ArchiveTime.date(ms: 1_760_101_200_000) && extent.newest == ArchiveTime.date(ms: 1_760_101_200_000 + 2 * 900_000 + 15_000))
        #expect(store.writeState.folder != nil && store.writeState.isReady && store.writeState.pause == nil && store.writeState.generation == 1)
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.storageStatus?.freeBytes == 400 * ArchiveStoreHarness.gb && harness.store.storageStatus?.oldest != nil })
        let status = try #require(store.storageStatus)
        #expect(status.totalBytes == 500 * ArchiveStoreHarness.gb && status.floorBytes == ArchiveConstants.otherVolumeFloorBytes && status.pause == nil)
        #expect(status.usedBytes == VolumeMonitor.rounded(harness.bytesOnDisk()), "three small files round down to 10 MB steps: nothing")
        #expect(status.oldest == extent.oldest && status.newest == extent.newest)
        #expect(await harness.ids().count == 18)
        harness.store.start(settings: harness.settings())   // a second start changes nothing
        #expect(harness.store.writeState.generation == 1)
    }

    @Test func withoutAFolderThereIsNothingToLoadAndTheStoreSaysWhy() async throws {
        let harness = try ArchiveStoreHarness()
        harness.store.start(settings: BridgeSettings())
        #expect(harness.store.isReady, "an empty archive is ready at once")
        #expect(harness.store.writeState == ArchiveWriteState(folder: nil, pause: .noFolder, isReady: true, generation: 1))
        #expect(harness.store.storageStatus == ArchiveStorageStatus(pause: .noFolder))
        let noIDs = await harness.ids()
        #expect(noIDs.isEmpty && harness.store.extent(camera: ArchiveStoreHarness.camera) == nil)
        #expect(harness.spaceCalls.value == 0, "the drive is never asked")
    }

    @Test func aFolderChosenAfterNoneReplacesTheOldStatusAsSoonAsItIsMeasured() async throws {
        // T04's PATCH nvr/storage waits for exactly this: a folder that was just chosen must not keep answering "noFolder" with every byte count 0
        // (the daemon once did, and T14's first phase aborted on it). The old status stays until the new folder has numbers; then it is replaced at once.
        let harness = try ArchiveStoreHarness()
        harness.store.start(settings: BridgeSettings())
        #expect(harness.store.storageStatus == ArchiveStorageStatus(pause: .noFolder))
        await harness.store.settingsChanged(from: BridgeSettings(), to: harness.settings())
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.storageStatus?.folder != nil })
        let status = try #require(harness.store.storageStatus)
        #expect(status.pause == nil && status.totalBytes == 500 * ArchiveStoreHarness.gb && status.freeBytes == 400 * ArchiveStoreHarness.gb && status.floorBytes == ArchiveConstants.otherVolumeFloorBytes)
    }

    @Test func aMissingFolderPausesAndTheCatalogLoadsWhenTheDriveReturns() async throws {
        let harness = try ArchiveStoreHarness()
        let folder = harness.root.url.appending(path: "drive", directoryHint: .isDirectory)   // not there yet
        await harness.start(harness.settings(folder: folder))
        #expect(harness.store.writeState.pause == .folderMissing && harness.store.writeState.isReady)
        #expect(await harness.ids().isEmpty)
        #expect(harness.store.storageStatus?.pause == .folderMissing)
        // The drive is plugged in, with a recording on it (it appears whole: a folder that is filled while it is looked at is not rescanned).
        let staging = harness.root.url.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: ArchiveStoreHarness.camera, cameraDirectory: ArchiveStoreHarness.camera.uuidString), root: staging)
        try FileManager.default.moveItem(at: staging, to: folder)
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.writeState.pause == nil && harness.store.extent(camera: ArchiveStoreHarness.camera) != nil }, "found within a probe or two")
        #expect(await harness.ids().count == 6 && harness.store.isReady)
    }

    @Test func idsAreTheSameAfterTheStoreWasStoppedAndStartedAgain() async throws {
        let harness = try ArchiveStoreHarness { root in
            try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: ArchiveStoreHarness.camera, cameraDirectory: ArchiveStoreHarness.camera.uuidString), root: root)
            try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: ArchiveStoreHarness.camera, cameraDirectory: ArchiveStoreHarness.camera.uuidString, baseName: "13-15-00",
                                                       startMs: 1_760_101_200_000 + 900_000), root: root)
        }
        await harness.start()
        let before = await harness.ids()
        #expect(before.count == 12 && Set(before).count == 12)
        let version = harness.store.catalogVersion
        await harness.store.stop()
        #expect(harness.store.isReady, "a stopped store still answers: a paused bridge shows its recordings")
        #expect(await harness.ids() == before)
        await harness.start()
        #expect(await harness.ids() == before, "ids come from the file's path and the fragment's place in it, nothing that changes")
        #expect(harness.store.catalogVersion > version && harness.store.writeState.generation == 2)
        let found = try #require(await harness.store.fragment(camera: ArchiveStoreHarness.camera, id: before[7]))
        #expect(found.id == before[7] && found.segment.hasSuffix("13-15-00") && found.index == 1)
    }

    @Test func aDriveThatHangsNeitherDelaysStartNorTheStatusAndIsReportedAsNotAnswering() async throws {
        let gate = DispatchSemaphore(value: 0)
        let harness = try ArchiveStoreHarness(spaceGate: gate, probeStallAfter: .milliseconds(300)) { root in
            try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: ArchiveStoreHarness.camera, cameraDirectory: ArchiveStoreHarness.camera.uuidString), root: root)
        }
        let started = ContinuousClock.now
        harness.store.start(settings: harness.settings())
        #expect(ContinuousClock.now - started < .seconds(2), "a drive that stalls for a minute does not delay start()")
        #expect(!harness.store.isReady && harness.store.extent(camera: ArchiveStoreHarness.camera) == nil)
        // Readers are told it is loading; after the stall time the drive is reported to recorders and in the status.
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.writeState.pause == .notWritable("The drive isn’t answering.") })
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.storageStatus?.pause == .notWritable("The drive isn’t answering.") })
        #expect(!harness.store.isReady)
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.spaceCalls.value == 1, "single flight: one probe is blocked, no more are started behind it")
        await harness.store.stop()   // never waits for the stuck call
        #expect(ContinuousClock.now - started < .seconds(20))
        gate.signal()
    }

    @Test func aDriveThatAnswersAgainResumesWithoutARestart() async throws {
        let gate = DispatchSemaphore(value: 0)
        let harness = try ArchiveStoreHarness(spaceGate: gate, probeStallAfter: .milliseconds(300)) { root in
            try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: ArchiveStoreHarness.camera, cameraDirectory: ArchiveStoreHarness.camera.uuidString), root: root)
        }
        harness.store.start(settings: harness.settings())
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.writeState.pause == .notWritable("The drive isn’t answering.") })
        gate.signal()   // the stuck call comes back
        for _ in 0..<10 { gate.signal() }   // and the later probes do not block
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.isReady && harness.store.writeState.pause == nil })
        #expect(harness.store.extent(camera: ArchiveStoreHarness.camera) != nil, "the load that waited for the probe went on")
    }

    @Test func aNewFolderReloadsTheCatalogAndTheOldRecordingsLeaveTheTimeline() async throws {
        let other = try TemporaryDirectory()
        defer { other.remove() }
        let second = UUID()
        let harness = try ArchiveStoreHarness { root in
            try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: ArchiveStoreHarness.camera, cameraDirectory: ArchiveStoreHarness.camera.uuidString), root: root)
        }
        try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: second, cameraDirectory: second.uuidString, baseName: "09-00-00"), root: other.url)
        await harness.start()
        let first = harness.store.writeState
        #expect(first.generation == 1 && harness.store.extent(camera: ArchiveStoreHarness.camera) != nil)
        let version = harness.store.catalogVersion

        await harness.store.settingsChanged(from: harness.settings(), to: harness.settings(folder: other.url))
        #expect(harness.store.writeState.generation == 2 && harness.store.writeState.folder != first.folder)
        #expect(harness.store.catalogVersion > version)
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.isReady && harness.store.extent(camera: second) != nil })
        #expect(harness.store.extent(camera: ArchiveStoreHarness.camera) == nil, "the old folder's recordings are no longer listed")
        let oldIDs = await harness.ids(camera: ArchiveStoreHarness.camera), newIDs = await harness.ids(camera: second)
        #expect(oldIDs.isEmpty && newIDs.count == 6)
        // Choosing the old folder again brings them back: the index lives beside the files.
        await harness.store.settingsChanged(from: harness.settings(folder: other.url), to: harness.settings())
        #expect(harness.store.writeState.generation == 3)
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.isReady && harness.store.extent(camera: ArchiveStoreHarness.camera) != nil })
        #expect(harness.store.extent(camera: second) == nil)
        // Clearing the folder: nothing listed, recorders told why.
        var none = harness.settings()
        none.nvrFolder = nil
        await harness.store.settingsChanged(from: harness.settings(), to: none)
        #expect(harness.store.isReady && harness.store.writeState.pause == .noFolder && harness.store.writeState.folder == nil)
        #expect(harness.store.extent(camera: ArchiveStoreHarness.camera) == nil)
    }

    @Test func settingsChangedBeforeStartAreLeftToStart() async throws {
        let harness = try ArchiveStoreHarness()
        await harness.store.settingsChanged(from: BridgeSettings(), to: harness.settings())
        #expect(harness.store.writeState.generation == 0 && !harness.store.isReady)
        await harness.store.stop()   // stopping a store that never started is harmless
    }

    @Test func fiveThousandFilesAreListedAndTheStoreIsReadyInUnderASecond() async throws {
        // 8 cameras x 7 days x 96 files of 15 minutes is 5,376; 5,000 files here, sparse mp4s with real sidecars (360 fragments, 15 rollups each).
        let cameras = (0..<8).map { _ in UUID() }
        var written = 0
        let startMs = ArchiveStoreHarness.now.timeIntervalSince1970 * 1_000 - 3_600_000
        let harness = try ArchiveStoreHarness { root in
            for camera in cameras {
                try ArchiveFixtureWriter.writeManifest(camera: camera, directory: camera.uuidString, root: root)
                for day in 0..<7 {
                    for slot in 0..<96 where written < 5_000 {
                        let fileStart = Int64(startMs) - Int64(day) * 86_400_000 - Int64(slot) * 900_000
                        try ArchiveFixtureWriter.writeSparse(root: root, camera: camera, directory: camera.uuidString, date: String(format: "2025-10-%02d", 10 - day),
                                                             baseName: String(format: "%02d-%02d-00", slot / 4, (slot % 4) * 15), startMs: fileStart, fragmentCount: 360,
                                                             writesManifest: false)
                        written += 1
                    }
                }
            }
        }
        #expect(written == 5_000)
        // The target is one second, in an optimized build. An unoptimized one runs Swift's regular expressions (the name patterns) about ten times
        // slower, and the tests run on loaded machines: there the limit only catches a load that is not linear in the number of files.
        #if DEBUG
        let limit = Duration.seconds(20)
        #else
        let limit = Duration.seconds(1)
        #endif
        let clock = ContinuousClock()
        var scan = CatalogLoader.Scan()
        let scanTime = clock.measure { scan = CatalogLoader.scan(root: harness.root.url) }
        #expect(scan.files.count == 5_000 && scan.needsRepair.isEmpty && scan.files.allSatisfy { $0.fragmentCount == 360 && $0.rollups.count == 15 })
        #expect(scanTime < limit, "listing took \(scanTime)")
        harness.store.start(settings: harness.settings())
        let startTime = await clock.measure { await eventually(timeout: archiveStorePatience) { harness.store.isReady } }
        print("NVR timing: 5,000 files listed in \(scanTime), store ready \(startTime) after start")   // printed so that the numbers are on record
        #expect(startTime < limit, "start to ready took \(startTime)")
        #expect(harness.store.state.withLock { $0.catalog.fileCount } == 5_000)
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.isSettled })
        #expect(harness.removed.value.isEmpty, "nothing here is older than a week")
    }
}
