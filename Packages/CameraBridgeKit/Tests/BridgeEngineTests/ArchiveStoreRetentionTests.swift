import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// The janitor (Mac spec 6 with the Linux changes): which files it deletes on a real folder, what it never touches, and that free space never
/// causes a deletion. Files are sparse (400 MB each, no disk used) with real sidecars.
@Suite struct ArchiveStoreRetentionTests {
    static let now = ArchiveStoreHarness.now
    static let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
    static let day: Int64 = 86_400_000

    struct Written {
        var camera: UUID
        var segment: String
        var startMs: Int64
        var mp4: URL
        var sidecar: URL
        var bytes: UInt64
    }

    /// A 400 MB sparse file of four fragments that started `hoursAgo` hours before the harness clock.
    @discardableResult
    static func sparse(_ root: URL, camera: UUID, hoursAgo: Double, date: String? = nil, base: String? = nil, directory: String? = nil, manifest: Bool = false) throws -> Written {
        let startMs = nowMs - Int64(hoursAgo * 3_600_000)
        let seconds = Int(startMs / 1_000)
        let date = date ?? String(format: "2026-%02d-%02d", 1 + (seconds / 86_400) % 12, 1 + (seconds / 3_600) % 28)
        let base = base ?? String(format: "%02d-%02d-%02d", (seconds / 3_600) % 24, (seconds / 60) % 60, seconds % 60)
        let directory = directory ?? camera.uuidString
        let (mp4, index) = try ArchiveFixtureWriter.writeSparse(root: root, camera: camera, directory: directory, date: date, baseName: base, startMs: startMs, fragmentCount: 4,
                                                                fragmentLength: 100_000_000, writesManifest: manifest)
        return Written(camera: camera, segment: ArchiveLayout.segment(cameraDirectory: directory, dateDirectory: date, baseName: base), startMs: startMs, mp4: mp4,
                       sidecar: mp4.deletingPathExtension().appendingPathExtension("cbidx"), bytes: index.mp4Size + UInt64(index.encoded().count))
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    @Test func filesThatEndedBeforeTheKeepTimeAreDeletedWithTheirSidecars() async throws {
        let camera = UUID()
        var files: [Written] = []
        let harness = try ArchiveStoreHarness { root in
            try ArchiveFixtureWriter.writeManifest(camera: camera, directory: camera.uuidString, root: root)
            for hours: Double in [24 * 8, 24 * 7 + 1, 24 * 6, 5, 1] { files.append(try Self.sparse(root, camera: camera, hoursAgo: hours)) }
        }
        await harness.start()
        #expect(harness.store.extent(camera: camera)?.oldest == ArchiveTime.date(ms: files[0].startMs))
        let version = harness.store.catalogVersion
        await harness.store.runRetention(harness.run)
        #expect(files.map { Self.exists($0.mp4) } == [false, false, true, true, true] && files.map { Self.exists($0.sidecar) } == [false, false, true, true, true])
        #expect(harness.removed.value.count == 4, "each file: the mp4 and then its sidecar")
        let removedNames = harness.removed.value
        #expect(removedNames.firstIndex { $0.hasSuffix(".mp4") }! < removedNames.firstIndex { $0.hasSuffix(".cbidx") }!, "mp4 before sidecar")
        #expect(harness.store.catalogVersion == version + 2 && harness.store.extent(camera: camera)?.oldest == ArchiveTime.date(ms: files[2].startMs))
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.storageStatus?.oldest == ArchiveTime.date(ms: files[2].startMs) }, "the status follows")
        #expect(harness.store.state.withLock { $0.catalog.fileCount } == 3)
        let ids = await harness.ids(camera: camera)
        #expect(ids.count == 12)
    }

    @Test func theSizeCapDeletesTheOldestStartsAcrossCamerasAndKeepsTheRest() async throws {
        let cameras = [UUID(), UUID(), UUID()]
        var files: [Written] = []
        let harness = try ArchiveStoreHarness { root in
            for position in 0..<30 {   // 12 GB, interleaved: camera 0, 1, 2, 0, 1, 2 ...
                files.append(try Self.sparse(root, camera: cameras[position % 3], hoursAgo: Double(60 - position * 2), manifest: position < 3))
            }
        }
        await harness.start(harness.settings(maxSizeGB: 10))
        let total = files.reduce(0) { $0 + $1.bytes }
        #expect(total > 10 * ArchiveStoreHarness.gb)
        await harness.store.runRetention(harness.run)
        var expectedGone = 0
        var used = total
        for file in files.sorted(by: { $0.startMs < $1.startMs }) where used > 10 * ArchiveStoreHarness.gb {
            used -= file.bytes
            expectedGone += 1
        }
        let gone = files.filter { !Self.exists($0.mp4) }
        #expect(gone.count == expectedGone && expectedGone == 6)
        #expect(Set(gone.map(\.segment)) == Set(files.sorted { $0.startMs < $1.startMs }.prefix(expectedGone).map(\.segment)), "the oldest by start, whichever camera")
        #expect(gone.allSatisfy { !Self.exists($0.sidecar) } && Set(gone.map(\.camera)).count == 3)
        #expect(harness.store.state.withLock { $0.catalog.usedBytes } == used)
        await harness.store.runRetention(harness.run)
        #expect(files.filter { !Self.exists($0.mp4) }.count == expectedGone, "a second pass has nothing to do")
    }

    @Test func theLimitFollowsASmallDrive() async throws {
        // A 20 GB drive with the 2 GiB floor of an ordinary volume holds 20e9 - 2 x 2 GiB = 15.7e9 bytes, whatever 500 GB says.
        let camera = UUID()
        var files: [Written] = []
        let harness = try ArchiveStoreHarness(total: 20 * ArchiveStoreHarness.gb, free: 2 * ArchiveStoreHarness.gb + 10) { root in
            for position in 0..<40 { files.append(try Self.sparse(root, camera: camera, hoursAgo: Double(80 - position * 2), manifest: position == 0)) }   // 16 GB
        }
        await harness.start(harness.settings(maxSizeGB: 500))
        await harness.store.runRetention(harness.run)
        let limit = 20 * ArchiveStoreHarness.gb - 2 * ArchiveConstants.otherVolumeFloorBytes
        let kept = files.filter { Self.exists($0.mp4) }.reduce(0) { $0 + $1.bytes }
        #expect(kept <= limit && kept > limit - files[0].bytes, "as many as fit: \(kept) of \(limit)")
    }

    @Test func foreignFilesLinksAndUnindexedFilesAreNeverCountedOrDeleted() async throws {
        let camera = UUID(), unconfigured = UUID()
        let outside = try TemporaryDirectory()
        defer { outside.remove() }
        var old: Written?
        var unindexed: Written?
        var lonely: Written?
        var target: Written?
        let harness = try ArchiveStoreHarness { root in
            old = try Self.sparse(root, camera: camera, hoursAgo: 24 * 30, manifest: true)
            // Another camera that is not configured anywhere: its directory has a camera.json, so its old files are ours.
            lonely = try Self.sparse(root, camera: unconfigured, hoursAgo: 24 * 30, manifest: true)
            // An own-pattern mp4 without a sidecar is not known to be ours: it stays.
            unindexed = try Self.sparse(root, camera: camera, hoursAgo: 24 * 29, base: "01-02-03")
            try FileManager.default.removeItem(at: unindexed!.sidecar)
            let dateFolder = old!.mp4.deletingLastPathComponent()
            try Data("note".utf8).write(to: dateFolder.appending(path: "notes.txt"))
            try Data("x".utf8).write(to: dateFolder.appending(path: "13-00-00.mp4.bak"))
            target = try Self.sparse(outside.url, camera: camera, hoursAgo: 24 * 31, directory: "outside", manifest: true)
            try FileManager.default.createSymbolicLink(at: dateFolder.appending(path: "04-05-06.mp4"), withDestinationURL: target!.mp4)
            try FileManager.default.createSymbolicLink(at: dateFolder.appending(path: "04-05-06.cbidx"), withDestinationURL: target!.sidecar)
            // A directory that is not a camera's.
            try FileManager.default.createDirectory(at: root.appending(path: "Other"), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: root.appending(path: "Other/2026-01-01.mp4"))
        }
        await harness.start()
        await harness.store.runRetention(harness.run)
        #expect(!Self.exists(old!.mp4) && !Self.exists(old!.sidecar) && !Self.exists(lonely!.mp4) && !Self.exists(lonely!.sidecar), "old files of every camera directory with a camera.json")
        #expect(Self.exists(unindexed!.mp4))
        let foreign = (try? FileManager.default.contentsOfDirectory(atPath: old!.mp4.deletingLastPathComponent().path(percentEncoded: false))) ?? []
        #expect(Set(foreign) == ["notes.txt", "13-00-00.mp4.bak", "04-05-06.mp4", "04-05-06.cbidx"], "beside the deleted file: \(foreign)")
        #expect(Self.exists(target!.mp4) && Self.exists(target!.sidecar), "what a link points at is not ours either")
        #expect(Self.exists(harness.root.url.appending(path: "Other/2026-01-01.mp4")))
        #expect(Self.exists(harness.root.url.appending(path: "\(camera.uuidString)/camera.json")), "a camera directory outlives its files")
        #expect(Self.exists(harness.root.url), "the recordings folder is never removed")
    }

    @Test func emptyDateDirectoriesOfEarlierDaysAreRemovedButTodaysIsKept() async throws {
        let camera = UUID()
        let today = ArchiveStore.dateDirectoryName(Self.now)
        var older: Written?
        var current: Written?
        let harness = try ArchiveStoreHarness { root in
            older = try Self.sparse(root, camera: camera, hoursAgo: 24 * 30, date: "2025-09-10", base: "10-00-00", manifest: true)
            current = try Self.sparse(root, camera: camera, hoursAgo: 0.5, date: today, base: "12-00-00")
        }
        await harness.start(harness.settings(maxSizeGB: 10))
        harness.space.set(VolumeMonitor.Space(total: 500 * ArchiveStoreHarness.gb, free: 400 * ArchiveStoreHarness.gb))
        await harness.store.runRetention(harness.run)
        #expect(!Self.exists(older!.mp4.deletingLastPathComponent()), "the emptied directory of an earlier day goes")
        #expect(Self.exists(current!.mp4))
        // Today's file goes by the size rule (cap 0 is not allowed by the settings; the janitor is told by the planner's input): empty today stays.
        try FileManager.default.removeItem(at: current!.sidecar)
        try FileManager.default.removeItem(at: current!.mp4)
        await harness.store.runRetention(harness.run)
        #expect(Self.exists(current!.mp4.deletingLastPathComponent()), "never touch a directory a recorder may be about to write in")
    }

    @Test func freeSpaceNeverDeletesAnything() async throws {
        let camera = UUID()
        var files: [Written] = []
        let harness = try ArchiveStoreHarness(free: 1_000_000) { root in   // 1 MB free on a 500 GB drive: far below the floor
            for position in 0..<10 { files.append(try Self.sparse(root, camera: camera, hoursAgo: Double(20 - position), manifest: position == 0)) }
        }
        await harness.start()
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.writeState.pause == .diskFull })
        for _ in 0..<5 { await harness.store.runRetention(harness.run) }
        #expect(harness.removed.value.isEmpty && files.allSatisfy { Self.exists($0.mp4) }, "young files under the cap stay however little room there is")
        // Aged files go, and only those: deleting them does not raise free space (a snapshot holds it) and nothing more is deleted for it.
        let aged = try Self.sparse(harness.root.url, camera: camera, hoursAgo: 24 * 40, date: "2026-08-01", base: "09-00-00")
        await harness.store.stop()
        await harness.start()
        for _ in 0..<5 { await harness.store.runRetention(harness.run) }
        #expect(!Self.exists(aged.mp4) && files.allSatisfy { Self.exists($0.mp4) })
        #expect(harness.removed.value.count == 2)
        #expect(harness.store.writeState.pause == .diskFull, "still full: free space did not move, and nothing else was deleted to move it")
    }

    @Test func aFileThatCannotBeDeletedStaysAndIsNotTriedAgainAndTheRestGo() async throws {
        let camera = UUID()
        var files: [Written] = []
        let harness = try ArchiveStoreHarness { root in
            for hours: Double in [24 * 20, 24 * 19, 24 * 18] { files.append(try Self.sparse(root, camera: camera, hoursAgo: hours, manifest: files.isEmpty)) }
        }
        harness.failRemoval.set([files[1].segment + ".mp4"])
        await harness.start()
        await harness.store.runRetention(harness.run)
        #expect(!Self.exists(files[0].mp4) && Self.exists(files[1].mp4) && !Self.exists(files[2].mp4), "the failure does not stop the next candidate")
        #expect(Self.exists(files[1].sidecar), "the sidecar is only deleted after the mp4")
        let before = harness.removed.value
        await harness.store.runRetention(harness.run)
        #expect(harness.removed.value == before, "not tried again")
        #expect(harness.store.state.withLock { $0.catalog.file(camera: camera, segment: files[1].segment) } != nil, "it is still in the timeline")
    }

    @Test func aRecordingBeingPlayedWhenItIsDeletedKeepsReadingUntilItsHandleIsRetired() async throws {
        let camera = UUID()
        var result: ArchiveFixtureResult?
        let harness = try ArchiveStoreHarness(deletedHandleGrace: .seconds(60)) { root in
            result = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: camera, cameraDirectory: camera.uuidString, date: "2026-09-01", baseName: "10-00-00",
                                                                startMs: Self.nowMs - 40 * Self.day), root: root)
        }
        await harness.start()
        let first = try #require(await harness.store.fragment(camera: camera, containing: ArchiveTime.date(ms: Self.nowMs - 40 * Self.day + 100)))
        let second = try #require(await harness.store.fragment(camera: camera, containing: ArchiveTime.date(ms: Self.nowMs - 40 * Self.day + 3_000)))
        _ = try await harness.store.read(first, .fragment)
        #expect(harness.store.handles.isOpen(first.segment))
        await harness.store.runRetention(harness.run)   // the file is 40 days old: deleted, its handle retired for a minute
        #expect(!Self.exists(result!.mp4))
        let gone = await harness.store.fragment(camera: camera, containing: first.start)
        #expect(gone == nil, "out of the timeline at once")
        #expect(try await harness.store.read(second, .fragment) == result!.fragments[1], "a player that is in the middle of it finishes through the open handle")
        harness.store.handles.sweep(grace: .zero)
        #expect(!harness.store.handles.isOpen(first.segment))
        await #expect(throws: ArchiveError.fileGone) { try await harness.store.read(second, .fragment) }
    }

    @Test func theDescriptorOfADeletedFileClosesOnceTheGraceHasPassed() async throws {
        let camera = UUID()
        var result: ArchiveFixtureResult?
        let harness = try ArchiveStoreHarness(deletedHandleGrace: .milliseconds(50)) { root in
            result = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: camera, cameraDirectory: camera.uuidString, date: "2026-09-01", baseName: "10-00-00",
                                                                startMs: Self.nowMs - 40 * Self.day), root: root)
        }
        await harness.start()
        let first = try #require(await harness.store.fragment(camera: camera, containing: ArchiveTime.date(ms: Self.nowMs - 40 * Self.day + 100)))
        _ = try await harness.store.read(first, .fragment)
        await harness.store.runRetention(harness.run)
        #expect(!Self.exists(result!.mp4))
        #expect(await eventually(timeout: archiveStorePatience) { !harness.store.handles.isOpen(first.segment) }, "the space of a deleted file is free once nobody reads it")
    }

    @Test func aNewLimitRunsTheJanitorAtOnceAndAClosedFileDoes() async throws {
        let camera = UUID()
        var files: [Written] = []
        let harness = try ArchiveStoreHarness { root in
            for hours: Double in [24 * 5, 24 * 3, 24 * 1.5, 2] { files.append(try Self.sparse(root, camera: camera, hoursAgo: hours, manifest: files.isEmpty)) }
        }
        await harness.start()
        await harness.store.runRetention(harness.run)
        #expect(files.allSatisfy { Self.exists($0.mp4) }, "all within 7 days")
        await harness.store.settingsChanged(from: harness.settings(), to: harness.settings(keepDays: 2))
        #expect(await eventually(timeout: archiveStorePatience) { !Self.exists(files[0].mp4) && !Self.exists(files[1].mp4) && Self.exists(files[2].mp4) && Self.exists(files[3].mp4) }, "keep 2 days")
        // The clock moves on a day; a file that a recorder closes wakes the janitor, which finds the next file aged.
        harness.clock.set(Self.now.addingTimeInterval(86_400))
        let owner = ArchiveOpenFile(camera: camera, segment: "\(camera.uuidString)/2026-10-10/22-00-00")
        harness.store.recorderOpened(owner, startWallMs: Self.nowMs, initLength: 600, hasAudio: false)
        harness.store.recorderClosed(owner, index: nil)
        #expect(await eventually(timeout: archiveStorePatience) { !Self.exists(files[2].mp4) && Self.exists(files[3].mp4) })
    }

    @Test func nothingIsDeletedWhileTheFolderIsMissingOrTheDriveReportsNoSize() async throws {
        let camera = UUID()
        var old: Written?
        let harness = try ArchiveStoreHarness(total: 0, free: 0) { root in old = try Self.sparse(root, camera: camera, hoursAgo: 24 * 30, manifest: true) }
        await harness.start()
        await harness.store.runRetention(harness.run)
        #expect(harness.removed.value.isEmpty && Self.exists(old!.mp4), "a drive that reports a total of 0 is not a drive to delete by")
        harness.space.set(VolumeMonitor.Space(total: 500 * ArchiveStoreHarness.gb, free: 400 * ArchiveStoreHarness.gb))
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.storageStatus?.totalBytes == 500 * ArchiveStoreHarness.gb })
        let hidden = harness.root.url.deletingLastPathComponent().appending(path: "hidden-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: harness.root.url, to: hidden)
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.writeState.pause == .folderMissing })
        await harness.store.runRetention(harness.run)
        #expect(harness.removed.value.isEmpty, "a missing folder is not a reason to delete anything")
        try FileManager.default.moveItem(at: hidden, to: harness.root.url)
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.writeState.pause == nil })
        await harness.store.runRetention(harness.run)
        #expect(!Self.exists(old!.mp4), "and when the folder is back the old file goes")
    }

    @Test func theJanitorRunsOnceTheCatalogIsLoaded() async throws {
        let camera = UUID()
        var files: [Written] = []
        let harness = try ArchiveStoreHarness(retentionAtStart: true) { root in
            for hours: Double in [24 * 9, 24 * 8, 3] { files.append(try Self.sparse(root, camera: camera, hoursAgo: hours, manifest: files.isEmpty)) }
        }
        await harness.start()
        #expect(await eventually(timeout: archiveStorePatience) { !Self.exists(files[0].mp4) && !Self.exists(files[1].mp4) }, "aged files go as soon as the store is up")
        #expect(Self.exists(files[2].mp4))
        #expect(await harness.ids(camera: camera).count == 4)
    }
}
