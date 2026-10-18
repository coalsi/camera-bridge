import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// Recovery in the store (Mac spec 4.5): what start-up repairs, what it leaves alone, and the files a recorder abandoned.
@Suite struct ArchiveStoreRepairTests {
    static let camera = ArchiveStoreHarness.camera
    static let start: Int64 = 1_760_101_200_000

    static func size(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? UInt64) ?? 0
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    @Test func startUpRepairsTornStaleAndUnindexedFilesBeforeTheCatalogIsReady() async throws {
        var torn: ArchiveFixtureResult?, stale: ArchiveFixtureResult?, missing: ArchiveFixtureResult?, clean: ArchiveFixtureResult?, initOnly: ArchiveFixtureResult?
        let harness = try ArchiveStoreHarness { root in
            // A crash in the middle of a fragment: no sidecar, the last fragment cut in two.
            torn = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: Self.camera, cameraDirectory: Self.camera.uuidString, baseName: "09-00-00", startMs: Self.start,
                                                              writesIndex: false), root: root)
            let handle = try FileHandle(forWritingTo: torn!.mp4)
            try handle.truncate(atOffset: torn!.index.fragments[5].offset + 1_000)
            try handle.close()
            // The sidecar of a file that kept growing after it was written (the recorder died before the final one).
            stale = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: Self.camera, cameraDirectory: Self.camera.uuidString, baseName: "09-15-00", startMs: Self.start + 900_000),
                                                   root: root)
            var shorter = stale!.index
            shorter.fragments.removeLast(2)
            shorter.endWallMs = shorter.startWallMs + 10_000
            shorter.mp4Size = shorter.fragments.last.map { $0.offset + UInt64($0.length) }!
            shorter.rollups = ArchiveFixtureWriter.bruteForceRollups(shorter.fragments)
            try shorter.encoded().write(to: stale!.sidecar)
            missing = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: Self.camera, cameraDirectory: Self.camera.uuidString, baseName: "09-30-00", startMs: Self.start + 1_800_000,
                                                                 writesIndex: false), root: root)
            clean = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: Self.camera, cameraDirectory: Self.camera.uuidString, baseName: "09-45-00", startMs: Self.start + 2_700_000),
                                                   root: root)
            // A file that only got as far as its initialization segment: nothing in it, and nothing is done to it.
            initOnly = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: Self.camera, cameraDirectory: Self.camera.uuidString, baseName: "10-00-00", startMs: Self.start + 3_600_000,
                                                                  fragments: [ArchiveFixtureFragment()], writesIndex: false), root: root)
            let initHandle = try FileHandle(forWritingTo: initOnly!.mp4)
            try initHandle.truncate(atOffset: UInt64(initOnly!.initData.count))
            try initHandle.close()
        }
        let cleanSidecar = try Data(contentsOf: clean!.sidecar)
        let modified = try #require(try FileManager.default.attributesOfItem(atPath: clean!.sidecar.path(percentEncoded: false))[.modificationDate] as? Date)
        await harness.start()
        let files = harness.store.state.withLock { $0.catalog.files[Self.camera] ?? [] }
        #expect(files.map(\.segment.lastPathComponentOfSegment) == ["09-00-00", "09-15-00", "09-30-00", "09-45-00"], "the init-only file is not in the timeline")
        #expect(files.map(\.fragmentCount) == [5, 6, 6, 6])
        // The torn file was cut after its fifth fragment, and now has a sidecar the loader trusts.
        let fifth = torn!.index.fragments[4]
        #expect(Self.size(torn!.mp4) == fifth.offset + UInt64(fifth.length) && Self.exists(torn!.sidecar))
        let staleSidecar = try Data(contentsOf: stale!.sidecar), missingSidecar = try Data(contentsOf: missing!.sidecar)
        #expect(Self.size(stale!.mp4) == stale!.index.mp4Size && staleSidecar == stale!.index.encoded(), "the stale sidecar was replaced by the true one")
        #expect(missingSidecar == missing!.index.encoded())
        let cleanAfter = try Data(contentsOf: clean!.sidecar)
        let modifiedAfter = try FileManager.default.attributesOfItem(atPath: clean!.sidecar.path(percentEncoded: false))[.modificationDate] as? Date
        #expect(cleanAfter == cleanSidecar && modifiedAfter == modified, "a file that needed nothing was not written")
        #expect(Self.size(initOnly!.mp4) == UInt64(initOnly!.initData.count) && !Self.exists(initOnly!.sidecar))
        let ids = await harness.ids()
        #expect(ids.count == 23, "5 + 6 + 6 + 6 fragments")
        let restored = try #require(await harness.store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 11_000)))
        #expect(try await harness.store.read(restored, .fragment) == torn!.fragments[4])
        // A second start finds nothing to do.
        await harness.store.stop()
        let sizeBefore = Self.size(torn!.mp4)
        await harness.start()
        #expect(Self.size(torn!.mp4) == sizeBefore && harness.store.catalogVersion > 0)
    }

    @Test func aFileARecorderHasOpenIsNeverRepairedWhateverItLooksLike() async throws {
        let harness = try ArchiveStoreHarness()
        await harness.start()
        let result = try harness.write(startMs: Self.start, writesIndex: false)
        let file = ArchiveOpenFile(camera: Self.camera, segment: result.file.segment)
        harness.store.recorderOpened(file, startWallMs: Self.start, initLength: result.index.initLength, hasAudio: false)
        for record in result.index.fragments.prefix(3) { harness.store.recorderWrote(file, record) }
        // The recorder is in the middle of its fourth fragment: a torn tail on disk, no sidecar.
        let handle = try FileHandle(forWritingTo: result.mp4)
        try handle.truncate(atOffset: result.index.fragments[3].offset + 500)
        try handle.close()
        let before = try Data(contentsOf: result.mp4)
        // The things that scan and repair: a reload of the folder, the janitor's repair of quiet files, a queued repair.
        harness.clock.set(Date())
        harness.store.state.withLock { $0.repairQueue[file.segment] = Self.camera }
        await harness.store.loadCatalog(harness.run)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: result.mp4.path(percentEncoded: false))
        await harness.store.repairQuiet(harness.run)
        #expect(try Data(contentsOf: result.mp4) == before && !Self.exists(result.sidecar), "not truncated, no sidecar")
        let ids = await harness.ids()
        #expect(ids.count == 3, "and the three written fragments are still the catalog's")
        #expect(harness.store.state.withLock { $0.catalog.openFiles.count } == 1)
    }

    @Test func aFileTheRecorderAbandonedIsRepairedOnceItHasBeenQuiet() async throws {
        let harness = try ArchiveStoreHarness()
        await harness.start()
        let result = try harness.write(startMs: Self.start, writesIndex: false)
        let file = ArchiveOpenFile(camera: Self.camera, segment: result.file.segment)
        harness.store.recorderOpened(file, startWallMs: Self.start, initLength: result.index.initLength, hasAudio: false)
        for record in result.index.fragments.prefix(4) { harness.store.recorderWrote(file, record) }
        let handle = try FileHandle(forWritingTo: result.mp4)   // the drive stalled during the fifth fragment
        try handle.truncate(atOffset: result.index.fragments[4].offset + 700)
        try handle.close()
        // The close wakes the janitor, which runs on its own task: its pass is over before the test makes the passes it is about by hand (the close is the
        // only wake in this test, so it is one pass).
        let passesBefore = harness.store.state.withLock { $0.retentionPasses }
        harness.store.recorderClosed(file, index: nil)
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.state.withLock { $0.retentionPasses } > passesBefore }, "the janitor's pass for the close is over")
        let none = await harness.ids()
        #expect(none.isEmpty)
        // Just written: it may still be written to. Nothing happens. The time is the store's clock, an hour after the recording started: at the real time
        // the recording would be a year past the 7 days it is kept, and a pass of the janitor would delete it as soon as the repair put it back.
        let written = harness.clock.value
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: result.mp4.path(percentEncoded: false))
        await harness.store.repairQuiet(harness.run)
        #expect(harness.store.state.withLock { $0.repairQueue.count } == 1 && !Self.exists(result.sidecar))
        // 60 s without a write: repaired, back in the timeline with its four whole fragments.
        harness.clock.set(written.addingTimeInterval(61))
        await harness.store.repairQuiet(harness.run)
        #expect(harness.store.state.withLock { $0.repairQueue.isEmpty })
        let ids = await harness.ids()
        #expect(ids.count == 4)
        let fourth = result.index.fragments[3]
        #expect(Self.size(result.mp4) == fourth.offset + UInt64(fourth.length) && Self.exists(result.sidecar))
        let fragment = try #require(await harness.store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 8_000)))
        #expect(try await harness.store.read(fragment, .fragment) == result.fragments[3])
    }

    @Test func aDamagedFragmentIsRescannedAndTheFileComesBackWithWhatIsLeftOfIt() async throws {
        let harness = try ArchiveStoreHarness()
        let result = try harness.write(startMs: Self.start)
        await harness.start()
        var damaged = try Data(contentsOf: result.mp4)
        damaged.replaceSubrange(Int(result.index.fragments[3].offset) + 4..<Int(result.index.fragments[3].offset) + 8, with: Data("junk".utf8))
        try damaged.write(to: result.mp4)
        let fragment = try #require(await harness.store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 8_000)))
        // The failed read quarantines the file, which wakes the janitor on its own task: its pass is over before the repair by hand.
        let passesBefore = harness.store.state.withLock { $0.retentionPasses }
        await #expect(throws: ArchiveError.self) { try await harness.store.read(fragment, .fragment) }
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.state.withLock { $0.retentionPasses } > passesBefore }, "the janitor's pass for the quarantine is over")
        let gone = await harness.ids()
        #expect(gone.isEmpty && harness.store.state.withLock { $0.repairQueue.count } == 1)
        // Quiet for 2 minutes on the store's clock (at the real time the recording would be past the 7 days it is kept, and a pass of the
        // janitor would delete it as soon as the repair put it back).
        try FileManager.default.setAttributes([.modificationDate: harness.clock.value.addingTimeInterval(-120)], ofItemAtPath: result.mp4.path(percentEncoded: false))
        await harness.store.repairQuiet(harness.run)
        let back = await harness.ids()
        #expect(back.count == 3, "the three fragments before the damage")
        #expect(Self.size(result.mp4) == result.index.fragments[3].offset, "and the damaged tail, small enough to be a torn one, was cut")
    }

    @Test func everythingTheRepairWritesIsPrivate() async throws {
        let harness = try ArchiveStoreHarness { root in
            try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: Self.camera, cameraDirectory: Self.camera.uuidString, writesIndex: false), root: root)
        }
        await harness.start()
        let sidecar = harness.root.url.appending(path: "\(Self.camera.uuidString)/2026-10-10/13-00-00.cbidx")
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: sidecar.path(percentEncoded: false))[.posixPermissions] as? Int)
        #expect(mode == 0o600)
        let leftovers = harness.root.contents().filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
        let inDate = (try? FileManager.default.contentsOfDirectory(atPath: sidecar.deletingLastPathComponent().path(percentEncoded: false))) ?? []
        #expect(inDate.sorted() == ["13-00-00.cbidx", "13-00-00.mp4"], "no temporary file is left in the date directory: \(inDate)")
    }
}

extension String {
    /// The last component of a segment ("<camera>/<date>/<base>").
    var lastPathComponentOfSegment: String { String(split(separator: "/").last ?? "") }
}
