import Dispatch
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// The archive drive (archive-tier brief): older recordings move there instead of being deleted, a move survives a crash at any step with exactly
/// one good copy, the archive keeps its own rules, reads go to whichever drive holds a file (through the archive's own read queue), and a drive
/// that is away shows its recordings as such until it is back. Real fixture files (about 26 KB each, six fragments of 2.5 s).
@Suite struct ArchiveStoreArchiveTests {
    static let camera = ArchiveStoreHarness.camera
    static let start: Int64 = 1_760_101_200_000
    static let floor = ArchiveConstants.otherVolumeFloorBytes
    /// One fixture file: its mp4 and sidecar.
    static let fileBytes: UInt64 = {
        let directory = try! TemporaryDirectory()
        defer { directory.remove() }
        let result = try! ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: camera, cameraDirectory: camera.uuidString), root: directory.url)
        return result.index.mp4Size + UInt64(result.index.encoded().count)
    }()

    /// Fifteen seconds apart, so they follow one another: "13-00-00", "13-00-15", …
    static func file(_ position: Int, camera: UUID = ArchiveStoreArchiveTests.camera) -> ArchiveFixtureFile {
        let seconds = position * 15
        return ArchiveFixtureFile(camera: camera, cameraDirectory: camera.uuidString, baseName: String(format: "13-%02d-%02d", seconds / 60, seconds % 60),
                                  startMs: start + Int64(seconds) * 1_000)
    }

    /// A harness with `count` fixture files on the recordings drive and an archive drive. The recordings drive starts roomy (retention, which the
    /// store also runs by itself when the archive comes, has nothing to do); `squeeze` shrinks it to hold `keep` files.
    static func harness(count: Int, archiveTotal: UInt64 = 2_000 * ArchiveStoreHarness.gb, archiveFree: UInt64 = 1_900 * ArchiveStoreHarness.gb,
                        moveBytesPerSecond: Int = 0, moveCrash: (@Sendable (ArchiveMoveStep) -> Bool)? = nil, populate: (URL) throws -> Void = { _ in },
                        populateArchive: (URL) throws -> Void = { _ in }) throws -> (ArchiveStoreHarness, [ArchiveFixtureResult]) {
        var results: [ArchiveFixtureResult] = []
        let harness = try ArchiveStoreHarness(archive: true, archiveTotal: archiveTotal, archiveFree: archiveFree, moveBytesPerSecond: moveBytesPerSecond, populate: { root in
            for position in 0..<count { results.append(try ArchiveFixtureWriter.write(Self.file(position), root: root)) }
            try populate(root)
        }, populateArchive: populateArchive, moveCrash: moveCrash)
        return (harness, results)
    }

    /// The recordings drive holds `keep` fixture files from now on (its size is twice the floor plus that), once `store` has measured it; nil: roomy again.
    static func squeeze(_ harness: ArchiveStoreHarness, keep: Int?, store: ArchiveStore? = nil) async -> Bool {
        let store = store ?? harness.store
        let total = keep.map { 2 * floor + UInt64($0) * fileBytes + fileBytes / 2 } ?? 500 * ArchiveStoreHarness.gb
        harness.space.set(VolumeMonitor.Space(total: total, free: keep == nil ? 400 * ArchiveStoreHarness.gb : total - floor / 2))
        return await eventually(timeout: archiveStorePatience) { store.state.withLock { $0.space?.total == total } }
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    static func onArchive(_ harness: ArchiveStoreHarness, _ result: ArchiveFixtureResult) -> (mp4: URL, sidecar: URL) {
        let root = harness.archiveRoot!.url
        return (ArchiveMove.url(root, result.file.segment, "mp4"), ArchiveMove.url(root, result.file.segment, "cbidx"))
    }

    static func tier(_ store: ArchiveStore, _ result: ArchiveFixtureResult) -> StorageTier? {
        store.state.withLock { $0.catalog.file(camera: result.file.camera, segment: result.file.segment)?.tier }
    }

    /// Starts `store` and waits until the archive drive's files are loaded and the mover has nothing left to sort out.
    static func started(_ harness: ArchiveStoreHarness, store: ArchiveStore? = nil) async -> Bool {
        let store = store ?? harness.store
        store.start(settings: harness.settings())
        return await eventually(timeout: archiveStorePatience) {
            store.isSettled && store.state.withLock { $0.drive.loaded && $0.drive.shadowed.isEmpty && $0.drive.pendingMainRemovals.isEmpty }
        }
    }

    /// Squeezes the recordings drive to `keep` files, runs retention and waits until the mover is idle again.
    static func retainAndMove(_ harness: ArchiveStoreHarness, keep: Int, store: ArchiveStore? = nil) async -> Bool {
        let store = store ?? harness.store
        guard await squeeze(harness, keep: keep, store: store) else { return false }
        await store.runRetention(store.currentRun)
        return await eventually(timeout: archiveStorePatience) {
            store.state.withLock { $0.drive.plannedMoves.isEmpty && $0.drive.moving == nil && $0.drive.pendingMainRemovals.isEmpty || $0.drive.crashed }
        }
    }

    /// Every temporary file of a move anywhere under `folder`.
    static func temporaries(under folder: URL) -> [String] {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.map(\.lastPathComponent).filter { $0.hasSuffix(ArchiveMove.temporarySuffix) }
    }

    // MARK: Moving

    @Test func theOldestFilesMoveToTheArchiveAndPlayFromThereWithTheSameIDs() async throws {
        let (harness, results) = try Self.harness(count: 5)
        #expect(await Self.started(harness))
        let ids = await harness.ids()
        #expect(ids.count == 30)
        #expect(await Self.retainAndMove(harness, keep: 3))
        for (position, result) in results.enumerated() {
            let moved = position < 2
            let archived = Self.onArchive(harness, result)
            #expect(Self.exists(result.mp4) == !moved && Self.exists(result.sidecar) == !moved, "file \(position) on the box")
            #expect(Self.exists(archived.mp4) == moved && Self.exists(archived.sidecar) == moved, "file \(position) on the archive")
            #expect(Self.tier(harness.store, result) == (moved ? .archive : .main))
        }
        #expect(harness.removed.value.filter { $0.hasSuffix(".mp4") }.count == 2, "the box's copies of the two that moved, and nothing else")
        #expect(try Data(contentsOf: Self.onArchive(harness, results[0]).mp4) == results[0].fragments.reduce(results[0].initData, +), "byte for byte")
        #expect(await harness.ids() == ids, "a file keeps its fragment ids when it moves")
        for result in results {
            for (index, bytes) in result.fragments.enumerated() {
                let fragment = try #require(await harness.store.fragment(camera: Self.camera, id: ArchiveIdentity.fragmentID(fileKey: result.file.key, index: index)))
                #expect(try await harness.store.read(fragment, .fragment) == bytes, "the same bytes from whichever drive")
            }
        }
        #expect(await eventually(timeout: archiveStorePatience) {
            guard let status = harness.store.storageStatus?.archive else { return false }
            return status.state == .connected && status.movedFiles == 2 && status.moving == nil && status.waitingFiles == 0
        }, "the status says what moved")
        #expect(Self.temporaries(under: harness.archiveRoot!.url).isEmpty)
        // The camera's folder on the archive carries its camera.json, so the drive can be read on its own.
        #expect(Self.exists(harness.archiveRoot!.url.appending(path: "\(Self.camera.uuidString)/camera.json")))
        #expect(harness.store.writeState.pause == nil, "recording never paused")
    }

    @Test func aCopyThatComesBackDifferentIsThrownAwayAndTheBoxKeepsTheRecording() async throws {
        let archiveFolder = Box<URL?>(nil)
        let (harness, results) = try Self.harness(count: 3, moveCrash: { step in
            // Not a crash: the copy is spoiled on the archive between its writing and its check.
            guard step == .copied, let folder = archiveFolder.value else { return false }
            for name in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL }) ?? []
            where name.lastPathComponent.hasSuffix(".mp4" + ArchiveMove.temporarySuffix) {
                if let handle = try? FileHandle(forUpdating: name) {
                    try? handle.seek(toOffset: 100)
                    try? handle.write(contentsOf: Data([0xFF, 0x00, 0xFF]))
                    try? handle.close()
                }
            }
            return false
        })
        archiveFolder.set(harness.archiveRoot?.url)
        #expect(await Self.started(harness))
        #expect(await Self.squeeze(harness, keep: 2))
        await harness.store.runRetention(harness.run)
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.state.withLock { $0.drive.failures >= 1 && $0.drive.moving == nil } })
        #expect(Self.exists(results[0].mp4) && Self.exists(results[0].sidecar) && Self.tier(harness.store, results[0]) == .main, "the box keeps it")
        let archived = Self.onArchive(harness, results[0])
        #expect(!Self.exists(archived.mp4) && !Self.exists(archived.sidecar) && Self.temporaries(under: harness.archiveRoot!.url).isEmpty, "nothing of it stays on the archive")
        #expect(try await harness.store.read(try #require(await harness.store.fragment(camera: Self.camera, id: "\(results[0].file.key).0")), .fragment) == results[0].fragments[0])
    }

    @Test(arguments: ArchiveMoveStep.allCases)
    func aCrashAtAnyStepLeavesExactlyOneGoodCopyAfterTheRestart(step: ArchiveMoveStep) async throws {
        let (harness, results) = try Self.harness(count: 2, moveCrash: { $0 == step })
        #expect(await Self.started(harness))
        #expect(await Self.retainAndMove(harness, keep: 1))
        #expect(harness.store.state.withLock { $0.drive.crashed }, "the move stopped at \(step)")
        harness.store.shutDown()   // the box lost power

        // Roomy after the restart, so that what is seen is the repair alone (not the next move).
        harness.space.set(VolumeMonitor.Space(total: 500 * ArchiveStoreHarness.gb, free: 400 * ArchiveStoreHarness.gb))
        let restarted = harness.makeStore()
        defer { restarted.shutDown() }
        #expect(await Self.started(harness, store: restarted))
        let moved = results[0]
        let archived = Self.onArchive(harness, moved)
        #expect(await eventually(timeout: archiveStorePatience) {
            Self.exists(moved.mp4) != Self.exists(archived.mp4) && Self.exists(moved.sidecar) == Self.exists(moved.mp4)
                && Self.exists(archived.sidecar) == Self.exists(archived.mp4)
        }, "the restart sorts it out")
        let onBox = Self.exists(moved.mp4), onArchive = Self.exists(archived.mp4)
        #expect(onBox != onArchive, "one copy of the mp4 after a crash at \(step): box \(onBox), archive \(onArchive)")
        #expect(Self.exists(moved.sidecar) == onBox && Self.exists(archived.sidecar) == onArchive, "the sidecar is with its mp4")
        #expect(Self.temporaries(under: harness.archiveRoot!.url).isEmpty && Self.temporaries(under: harness.root.url).isEmpty)
        let expected: StorageTier = [.copying, .copied, .sidecarInPlace].contains(step) ? .main : .archive
        #expect(Self.tier(restarted, moved) == expected && (expected == .archive) == onArchive)
        for (index, bytes) in moved.fragments.enumerated() {
            let fragment = try #require(await restarted.fragment(camera: Self.camera, id: ArchiveIdentity.fragmentID(fileKey: moved.file.key, index: index)))
            #expect(try await restarted.read(fragment, .fragment) == bytes)
        }
        #expect(Self.exists(results[1].mp4) && Self.tier(restarted, results[1]) == .main, "the other file was never touched")
        // And the move finishes on the next pass.
        if expected == .main {
            #expect(await Self.retainAndMove(harness, keep: 1, store: restarted))
            #expect(!Self.exists(moved.mp4) && Self.exists(archived.mp4) && Self.tier(restarted, moved) == .archive)
        }
    }

    @Test func theMoverKeepsToItsRateAndGivesWayToReaders() throws {
        let source = try TemporaryDirectory(), target = try TemporaryDirectory()
        defer { source.remove(); target.remove() }
        let result = try ArchiveFixtureWriter.write(Self.file(0), root: source.url)
        try ArchiveStoreHarness.writeMarker(in: target.url)
        let slept = Box<[TimeInterval]>([])
        let yields = Box(3)
        var controls = ArchiveMove.Controls()
        controls.chunkBytes = 1_000
        controls.bytesPerSecond = 10_000
        controls.sleep = { seconds in slept.update { $0.append(seconds) } }
        controls.shouldYield = { yields.update { $0 -= 1 }; return yields.value >= 0 }
        let ticket = ArchiveMove.Ticket(camera: Self.camera, segment: result.file.segment, mainFolder: source.url, archiveFolder: target.url,
                                        mp4Bytes: result.index.mp4Size, sidecarBytes: UInt64(result.index.encoded().count))
        #expect(ArchiveMove.perform(ticket, controls) == .inPlace)
        let throttled = slept.value.filter { $0 != 0.2 }.reduce(0, +)
        let due = Double(ticket.mp4Bytes) / 10_000
        #expect(throttled > due * 0.9 && throttled <= due + Double(ticket.sidecarBytes) / 10_000 + 0.5, "about \(due) s of waiting for \(ticket.mp4Bytes) bytes at 10 kB/s: \(throttled)")
        #expect(slept.value.filter { $0 == 0.2 }.count == 3, "it waited while someone read the archive")
        #expect(try Data(contentsOf: ArchiveMove.url(target.url, ticket.segment, "mp4")) == Data(contentsOf: result.mp4))
        #expect(Self.exists(result.mp4), "perform never touches the box's copy: the store deletes it after the catalog switched")
    }

    @Test func theSkyWatchersLogAndTheEventsStayOnTheBox() async throws {
        let (harness, results) = try Self.harness(count: 4, populate: { root in
            for path in [".sky/2026-10-10/log.jsonl", ".sky/2026-10-10/stills/a.jpg", ".events/\(Self.camera.uuidString)/2026-10-10.jsonl"] {
                let url = root.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("kept".utf8).write(to: url)
            }
        })
        #expect(await Self.started(harness))
        #expect(await Self.retainAndMove(harness, keep: 2))
        #expect(Self.tier(harness.store, results[0]) == .archive && Self.tier(harness.store, results[1]) == .archive)
        for path in [".sky/2026-10-10/log.jsonl", ".sky/2026-10-10/stills/a.jpg", ".events/\(Self.camera.uuidString)/2026-10-10.jsonl"] {
            #expect(try Data(contentsOf: harness.root.url.appending(path: path)) == Data("kept".utf8), "\(path) is where it was")
        }
        let onArchive = try FileManager.default.contentsOfDirectory(atPath: harness.archiveRoot!.url.path(percentEncoded: false))
        #expect(!onArchive.contains(".sky") && !onArchive.contains(".events"))
    }

    @Test func aFileBeingWrittenNeverMoves() async throws {
        let (harness, results) = try Self.harness(count: 2)
        #expect(await Self.started(harness))
        // A recorder opens an older-named file and writes enough to put the box over its limit.
        let open = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: Self.camera, cameraDirectory: Self.camera.uuidString, baseName: "12-59-00",
                                                                     startMs: Self.start - 60_000, writesIndex: false), root: harness.root.url)
        let owned = ArchiveOpenFile(camera: Self.camera, segment: open.file.segment)
        harness.store.recorderOpened(owned, startWallMs: open.index.startWallMs, initLength: open.index.initLength, hasAudio: false)
        for record in open.index.fragments { harness.store.recorderWrote(owned, record) }
        #expect(await Self.retainAndMove(harness, keep: 2))
        #expect(Self.exists(open.mp4) && !Self.exists(ArchiveMove.url(harness.archiveRoot!.url, open.file.segment, "mp4")), "the open file stays where its recorder writes")
        #expect(harness.store.state.withLock { $0.catalog.file(camera: Self.camera, segment: open.file.segment)?.isOpen } == true)
        #expect(Self.tier(harness.store, results[0]) == .archive, "the oldest closed file went instead")
    }

    // MARK: The archive's own rules

    @Test func theArchiveKeepsTheSameDaysAndMakesRoomFromItsOldest() async throws {
        // An archive that holds two files: two old ones are there, two of the box's must leave.
        let archiveTotal = 2 * Self.floor + 2 * Self.fileBytes + Self.fileBytes / 2
        var old: [ArchiveFixtureResult] = []
        let (harness, results) = try Self.harness(count: 4, archiveTotal: archiveTotal, archiveFree: Self.floor + 3 * Self.fileBytes, populateArchive: { root in
            for position in 0..<2 {
                var file = ArchiveFixtureFile(camera: Self.camera, cameraDirectory: Self.camera.uuidString, date: "2026-10-09",
                                              baseName: String(format: "10-00-%02d", position * 15), startMs: Self.start - 86_400_000 + Int64(position) * 15_000)
                file.fragments = Array(repeating: ArchiveFixtureFragment(), count: 6)
                old.append(try ArchiveFixtureWriter.write(file, root: root))
            }
        })
        #expect(await Self.started(harness))
        #expect(Self.tier(harness.store, old[0]) == .archive && Self.tier(harness.store, old[1]) == .archive, "what was on the drive is in the catalog")
        #expect(await Self.retainAndMove(harness, keep: 2))
        #expect(!Self.exists(old[0].mp4) && !Self.exists(old[1].mp4), "the archive's oldest made room")
        #expect(Self.tier(harness.store, results[0]) == .archive && Self.tier(harness.store, results[1]) == .archive)
        #expect(Self.exists(results[2].mp4) && Self.exists(results[3].mp4))
        // A day later than the keep time, everything on the archive has aged out: it goes, as on the box.
        harness.clock.set(ArchiveStoreHarness.now.addingTimeInterval(8 * 86_400))
        #expect(await Self.retainAndMove(harness, keep: 2))
        #expect(!Self.exists(Self.onArchive(harness, results[0]).mp4) && Self.tier(harness.store, results[0]) == nil)
    }

    @Test func withoutAUsableArchiveRetentionDeletesAsToday() async throws {
        // A folder without the drive's marker (unplugged, or never chosen): the oldest are deleted, nothing is written to the folder.
        let (harness, results) = try Self.harness(count: 4)
        try FileManager.default.removeItem(at: harness.archiveRoot!.url.appending(path: ArchiveDriveMeasurement.markerName))
        harness.store.start(settings: harness.settings())
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.isSettled && harness.store.state.withLock { $0.drive.connection == .away } })
        #expect(await Self.squeeze(harness, keep: 2))
        await harness.store.runRetention(harness.run)
        #expect(!Self.exists(results[0].mp4) && !Self.exists(results[1].mp4) && Self.exists(results[2].mp4) && Self.exists(results[3].mp4))
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.archiveRoot!.url.path(percentEncoded: false)).isEmpty)
        #expect(harness.store.storageStatus != nil && harness.store.storageStatus?.archive == nil, "a box that never saw an archive drive says nothing about one")
    }

    @Test func anArchiveThatStopsAnsweringNeverHoldsUpTheBox() async throws {
        let gate = DispatchSemaphore(value: 0)
        let blocked = Box(false)
        var results: [ArchiveFixtureResult] = []
        let harness = try ArchiveStoreHarness(probeStallAfter: .milliseconds(300), archive: true, populate: { root in
            for position in 0..<4 { results.append(try ArchiveFixtureWriter.write(Self.file(position), root: root)) }
        })
        defer { blocked.set(false); for _ in 0..<50 { gate.signal() } }
        // The archive's space call hangs once `blocked` is set (a USB drive that stopped answering).
        var environment = harness.environment
        let policy = environment.archivePolicy!
        let archivePath = ArchiveVolume.path(of: harness.archiveRoot!.url)
        environment.archivePolicy = ArchivePlatformPolicy(space: { url in
            if ArchiveVolume.path(of: url).hasPrefix(archivePath), blocked.value { gate.wait() }
            return policy.space(url)
        }, isSystemVolume: policy.isSystemVolume, systemFloor: policy.systemFloor, directoryNaming: .cameraID)
        let store = ArchiveStore(environment: environment, signal: ChangeSignal(), tuning: harness.tuning)
        defer { store.shutDown() }
        #expect(await Self.started(harness, store: store))
        blocked.set(true)
        #expect(await eventually(timeout: archiveStorePatience) { store.storageStatus?.archive?.state == .notAnswering })
        #expect(await Self.squeeze(harness, keep: 2, store: store))
        await store.runRetention(store.currentRun)
        #expect(!Self.exists(results[0].mp4) && !Self.exists(results[1].mp4), "deleted as without an archive")
        #expect(store.writeState.pause == nil, "recording never paused because of the archive")
        let fragment = try #require(await store.fragment(camera: Self.camera, id: "\(results[3].file.key).0"))
        #expect(try await store.read(fragment, .fragment) == results[3].fragments[0], "the box's recordings play")
    }

    @Test func anArchiveDeletionThatHangsDoesNotHoldUpTheBoxsRetention() async throws {
        // Old files on both drives; deleting on the archive hangs (a USB drive that stopped answering in the middle of it).
        let gate = DispatchSemaphore(value: 0)
        defer { for _ in 0..<10 { gate.signal() } }
        var oldOnArchive: ArchiveFixtureResult?
        var oldOnBox: ArchiveFixtureResult?
        let harness = try ArchiveStoreHarness(archive: true, populate: { root in
            oldOnBox = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: Self.camera, cameraDirectory: Self.camera.uuidString, date: "2026-09-01", baseName: "10-00-00",
                                                                         startMs: Self.start - 30 * 86_400_000), root: root)
        }, populateArchive: { root in
            oldOnArchive = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: Self.camera, cameraDirectory: Self.camera.uuidString, date: "2026-08-01", baseName: "10-00-00",
                                                                             startMs: Self.start - 60 * 86_400_000), root: root)
        })
        var tuning = harness.tuning
        tuning.archiveDeletionDeadline = .milliseconds(300)
        let archivePath = ArchiveVolume.path(of: harness.archiveRoot!.url)
        tuning.removeFile = { url in
            if ArchiveVolume.path(of: url).hasPrefix(archivePath) { gate.wait() }
            try FileManager.default.removeItem(at: url)
        }
        let store = ArchiveStore(environment: harness.environment, signal: ChangeSignal(), tuning: tuning)
        defer { store.shutDown() }
        store.start(settings: harness.settings())
        #expect(await eventually(timeout: archiveStorePatience) { store.isSettled && store.state.withLock { $0.drive.loaded } })
        let started = ContinuousClock.now
        await store.runRetention(store.currentRun)
        #expect(started.duration(to: .now) < .seconds(10), "the pass ended at the deadline, not with the drive")
        #expect(!Self.exists(try #require(oldOnBox).mp4), "the box's own old file went")
        #expect(Self.exists(try #require(oldOnArchive).mp4), "the archive's waits for its drive")
        gate.signal()
        #expect(await eventually(timeout: archiveStorePatience) { !Self.exists(oldOnArchive!.mp4) }, "and goes when the drive answers")
    }

    // MARK: Reading from both

    @Test func aCopyTheArchiveLostBeforeTheBoxsCopyWentLeavesTheRecordingOnTheBox() async throws {
        let archiveFolder = Box<URL?>(nil), segment = Box<String?>(nil)
        let (harness, results) = try Self.harness(count: 3, moveCrash: { step in
            // Not a crash: once the catalog points at the archive's copy, the drive loses it (it went away and came back without it).
            guard step == .swapped, let folder = archiveFolder.value, let name = segment.value else { return false }
            try? FileManager.default.removeItem(at: ArchiveMove.url(folder, name, "mp4"))
            return false
        })
        let lost = results[0]
        archiveFolder.set(harness.archiveRoot?.url)
        segment.set(lost.file.segment)
        #expect(await Self.started(harness))
        #expect(await Self.retainAndMove(harness, keep: 2))
        #expect(Self.tier(harness.store, lost) == .main, "the box's copy is the recording again")
        #expect(Self.exists(lost.mp4) && Self.exists(lost.sidecar) && !harness.removed.value.contains(lost.mp4.lastPathComponent), "and it was never deleted")
        #expect(harness.store.state.withLock { $0.drive.unmovable.contains(lost.file.segment) }, "not moved again until the drive is loaded again")
        for (index, bytes) in lost.fragments.enumerated() {
            let fragment = try #require(await harness.store.fragment(camera: Self.camera, id: ArchiveIdentity.fragmentID(fileKey: lost.file.key, index: index)))
            #expect(try await harness.store.read(fragment, .fragment) == bytes)
        }
    }

    @Test func theBoxsCopyOfAMovedFileWaitsWhileTheDriveIsAwayAndGoesWhenItIsBack() async throws {
        let mount = Box<URL?>(nil), aside = Box<URL?>(nil)
        let (harness, results) = try Self.harness(count: 3, moveCrash: { step in
            // Not a crash: the drive is unplugged once the catalog points at its copy, before the box's copy is deleted (once).
            guard step == .swapped, let folder = mount.value, let unplugged = aside.value else { return false }
            mount.set(nil)
            try? FileManager.default.moveItem(at: folder, to: unplugged)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            return false
        })
        let moved = results[0], root = harness.archiveRoot!.url
        let unplugged = root.deletingLastPathComponent().appending(path: "unplugged-\(UUID().uuidString)")
        mount.set(root)
        aside.set(unplugged)
        #expect(await Self.started(harness))
        #expect(await Self.squeeze(harness, keep: 2))
        await harness.store.runRetention(harness.run)
        #expect(await eventually(timeout: archiveStorePatience) {
            harness.store.state.withLock { $0.drive.pendingMainRemovals[moved.file.segment] != nil && $0.drive.moving == nil && $0.drive.mainRemovalsWaitUntil != nil }
        })
        #expect(Self.exists(moved.mp4) && Self.exists(moved.sidecar), "the box keeps its copy while the drive is away")
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.storageStatus?.archive?.state == .notConnected })
        // Plugged back in: the copy is there, whole, and the box's goes at once.
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: unplugged, to: root)
        #expect(await eventually(timeout: archiveStorePatience) {
            harness.store.state.withLock { $0.drive.loaded && $0.drive.pendingMainRemovals.isEmpty } && !Self.exists(moved.mp4)
        })
        let archived = Self.onArchive(harness, moved)
        #expect(!Self.exists(moved.sidecar) && Self.exists(archived.mp4) && Self.exists(archived.sidecar) && Self.tier(harness.store, moved) == .archive)
        for (index, bytes) in moved.fragments.enumerated() {
            let fragment = try #require(await harness.store.fragment(camera: Self.camera, id: ArchiveIdentity.fragmentID(fileKey: moved.file.key, index: index)))
            #expect(try await harness.store.read(fragment, .fragment) == bytes)
        }
        #expect(harness.store.writeState.pause == nil)
    }

    @Test func aDriveThatGoesAwayShowsItsRecordingsAsAwayAndTheyPlayAgainWhenItIsBack() async throws {
        let (harness, results) = try Self.harness(count: 4)
        #expect(await Self.started(harness))
        #expect(await Self.retainAndMove(harness, keep: 2))
        let store = harness.store
        let inArchived = ArchiveTime.date(ms: Self.start + 5_000)
        #expect(await store.fragment(camera: Self.camera, containing: inArchived) != nil)
        // Unplugged: the folder it was mounted on stays, empty.
        let mount = harness.archiveRoot!.url
        let unplugged = mount.deletingLastPathComponent().appending(path: "unplugged-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: mount, to: unplugged)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        #expect(await eventually(timeout: archiveStorePatience) { store.storageStatus?.archive?.state == .notConnected })
        #expect(await store.fragment(camera: Self.camera, containing: inArchived) == nil, "it does not play")
        let away = try #require(store.awaySpan(camera: Self.camera, containing: inArchived))
        #expect(ArchiveTime.ms(away.start) == Self.start && ArchiveTime.ms(away.end) == results[1].index.endWallMs, "the two archived files, as one stretch")
        #expect(store.awaySpan(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 35_000)) == nil, "the box's files are not away")
        #expect(store.extent(camera: Self.camera)?.oldest == ArchiveTime.date(ms: Self.start), "the timeline still reaches back to them")
        let next = try #require(await store.fragment(camera: Self.camera, startingAfter: inArchived))
        #expect(next.segment == results[2].file.segment, "playing on skips to the box's next recording")
        let activity = await store.activity(camera: Self.camera, range: ArchiveTime.date(ms: Self.start)..<ArchiveTime.date(ms: Self.start + 60_000), binCount: 4)
        #expect(activity.bins.map { ($0.away * 100).rounded() } == [100, 100, 0, 0] && activity.bins.map { ($0.coverage * 100).rounded() } == [0, 0, 100, 100])
        #expect(store.writeState.pause == nil)
        // Plugged back in.
        try FileManager.default.removeItem(at: mount)
        try FileManager.default.moveItem(at: unplugged, to: mount)
        #expect(await eventually(timeout: archiveStorePatience) { store.storageStatus?.archive?.state == .connected && store.state.withLock { $0.drive.loaded } })
        let back = try #require(await store.fragment(camera: Self.camera, containing: inArchived))
        #expect(try await store.read(back, .fragment) == results[0].fragments[2])
        #expect(store.awaySpan(camera: Self.camera, containing: inArchived) == nil)
    }

    @Test func aStartScansBothDrivesAndAStartWithoutTheArchiveRemembersWhatIsOnIt() async throws {
        let (harness, results) = try Self.harness(count: 4)
        #expect(await Self.started(harness))
        #expect(await Self.retainAndMove(harness, keep: 2))
        let ids = await harness.ids()
        harness.store.shutDown()
        // A start with both drives: everything is found, each file on its drive.
        let again = harness.makeStore()
        #expect(await Self.started(harness, store: again))
        #expect(results.map { Self.tier(again, $0) } == [.archive, .archive, .main, .main])
        var cursor = Date(timeIntervalSince1970: 0)
        var found: [String] = []
        while let fragment = await again.fragment(camera: Self.camera, startingAfter: cursor) { found.append(fragment.id); cursor = fragment.start }
        #expect(found == ids)
        again.shutDown()
        // A start without the archive drive: its recordings are known from the list the box kept, as away.
        try FileManager.default.removeItem(at: harness.archiveRoot!.url.appending(path: ArchiveDriveMeasurement.markerName))
        let alone = harness.makeStore()
        defer { alone.shutDown() }
        alone.start(settings: harness.settings())
        #expect(await eventually(timeout: archiveStorePatience) { alone.isSettled && alone.state.withLock { $0.drive.connection == .away } })
        #expect(alone.awaySpan(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 1_000)) != nil)
        #expect(results.map { Self.tier(alone, $0) } == [.archive, .archive, .main, .main])
        #expect(alone.storageStatus?.archive?.state == .notConnected)
    }

    @Test func aSlowArchiveCannotHoldUpReadsOfTheBox() async throws {
        let (harness, results) = try Self.harness(count: 4)
        #expect(await Self.started(harness))
        #expect(await Self.retainAndMove(harness, keep: 2))
        let store = harness.store
        // Every slot of the archive's read queue is taken by reads that hang.
        let gate = DispatchSemaphore(value: 0)
        defer { for _ in 0..<store.archiveReads.width { gate.signal() } }
        for _ in 0..<store.archiveReads.width { Task.detached { _ = try? await store.archiveReads.run { gate.wait() } } }
        #expect(await eventually(timeout: archiveStorePatience) { store.archiveReads.load.running == store.archiveReads.width })
        let mainFragment = try #require(await store.fragment(camera: Self.camera, id: "\(results[3].file.key).1"))
        let started = ContinuousClock.now
        #expect(try await store.read(mainFragment, .fragment) == results[3].fragments[1])
        #expect(started.duration(to: .now) < .seconds(2), "the box's read did not wait behind the archive's")
        #expect(store.reads.load.waiting == 0)
    }

    @Test func aClipCanSpanTheArchiveAndTheBox() async throws {
        let (harness, results) = try Self.harness(count: 3)
        #expect(await Self.started(harness))
        #expect(await Self.retainAndMove(harness, keep: 1))
        #expect(results.map { Self.tier(harness.store, $0) } == [.archive, .archive, .main])
        let exporter = ClipExporter(archive: harness.store)
        // From the middle of the second file (on the archive) into the third (on the box).
        let request = ClipRequest(camera: Self.camera, cameraName: "Driveway", start: ArchiveTime.date(ms: Self.start + 20_000),
                                  end: ArchiveTime.date(ms: Self.start + 40_000), timeZone: TimeZone(identifier: "UTC")!)
        let plan = try await exporter.plan(request)
        #expect(plan.parts.count == 1 && plan.gaps.isEmpty)
        let segments = Set(try #require(plan.tables.first).copies.map(\.fragment.segment))
        #expect(segments == [results[1].file.segment, results[2].file.segment], "one clip, fragments from both drives")
        let sink = CollectingSink()
        try await exporter.export(plan, part: 1, to: sink) { _ in }
        #expect(Int64(sink.data.count) == plan.parts[0].byteCount)
        // The pictures of the archived fragments are in the file as the archive has them.
        let copy = try #require(plan.tables.first?.copies.first)
        let source = try await harness.store.read(copy.fragment, .fragment)
        #expect(sink.data.range(of: source.subdata(in: source.startIndex + copy.skipBytes ..< source.startIndex + copy.skipBytes + copy.length)) != nil)
    }
}
