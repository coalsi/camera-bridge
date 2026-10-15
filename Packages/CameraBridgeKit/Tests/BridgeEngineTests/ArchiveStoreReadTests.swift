import Dispatch
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// Finding and reading recorded video through the store (Mac spec 7 and 13): lookups on a folder read from disk, the four parts, the cache, the
/// handles, a file that is unlinked while it is read, a drive that goes away, a fragment that is not where its index says.
@Suite struct ArchiveStoreReadTests {
    static let camera = ArchiveStoreHarness.camera
    static let start: Int64 = 1_760_101_200_000

    /// A harness with one real file of six fragments (the 3rd and 4th are continuation fragments) and the store started on it.
    static func started(sound: Bool = false) async throws -> (ArchiveStoreHarness, ArchiveFixtureResult) {
        var result: ArchiveFixtureResult?
        let plan = [ArchiveFixtureFragment(), ArchiveFixtureFragment(), ArchiveFixtureFragment(startsOnKey: false), ArchiveFixtureFragment(startsOnKey: false), ArchiveFixtureFragment(), ArchiveFixtureFragment()]
        let harness = try ArchiveStoreHarness { root in
            result = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: camera, cameraDirectory: camera.uuidString, fragments: plan, hasAudio: sound), root: root)
        }
        await harness.start()
        return (harness, try #require(result))
    }

    @Test func lookupsOnAFolderReadFromDiskLoadTablesWhenTheyAreNeeded() async throws {
        let (harness, result) = try await Self.started()
        let store = harness.store
        #expect(store.state.withLock { $0.catalog.cachedTableCount } == 1, "the catalog holds headers and rollups; only the newest file's table was read, to measure the keyframe interval")
        #expect(store.extent(camera: Self.camera)?.typicalGOP == 2.5, "keyframes at 0, 2.5, 10 and 12.5 s: intervals of 2.5, 7.5 and 2.5 s, median 2.5 s")
        let at = ArchiveTime.date(ms: Self.start + 6_000)
        let fragment = try #require(await store.fragment(camera: Self.camera, containing: at))
        #expect(fragment.index == 2 && fragment.start == ArchiveTime.date(ms: Self.start + 5_000) && fragment.duration == 2.5 && !fragment.hasKeyframe)
        #expect(fragment.backToKey == 1 && fragment.gopStart == ArchiveTime.date(ms: Self.start + 2_500) && fragment.byteLength == Int(result.index.fragments[2].length))
        #expect(store.state.withLock { $0.catalog.cachedTableCount } == 1, "one sidecar was read")
        #expect(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start - 1)) == nil)
        #expect(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 15_000)) == nil)
        let next = try #require(await store.fragment(camera: Self.camera, startingAfter: at))
        #expect(next.index == 3 && next.start == ArchiveTime.date(ms: Self.start + 7_500))
        #expect(await store.fragment(camera: Self.camera, startingAfter: ArchiveTime.date(ms: Self.start + 12_500)) == nil)
        let byID = try #require(await store.fragment(camera: Self.camera, id: fragment.id))
        #expect(byID == fragment)
        let unknownKey = await store.fragment(camera: Self.camera, id: "000000000000.0"), notAnID = await store.fragment(camera: Self.camera, id: "nonsense")
        let otherCamera = await store.fragment(camera: UUID(), id: fragment.id), pastTheEnd = await store.fragment(camera: Self.camera, id: "\(fragment.fileKey).6")
        #expect(unknownKey == nil && notAnID == nil && otherCamera == nil && pastTheEnd == nil)
    }

    @Test func eachPartReadsExactlyTheBytesTheIndexPointsAt() async throws {
        let (harness, result) = try await Self.started()
        let store = harness.store
        let first = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start)))
        #expect(try await store.read(first, .fragment) == result.fragments[0])
        #expect(try await store.read(first, .initialization) == result.initData)
        let key = try await store.read(first, .keyframe)
        let record = result.index.fragments[0]
        #expect(key == result.fragments[0].subdata(in: Int(record.headerLength)..<Int(record.headerLength) + Int(record.keyLength)) && key.count == 6_004)
        #expect(key.prefix(5) == Data([0, 0, 0x17, 0x70, 0x65]), "a length-prefixed IDR NAL unit")
        // A fragment from the middle of a group of pictures has no keyframe to read, but the fragment itself reads.
        let middle = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 5_000)))
        await #expect(throws: ArchiveError.noKeyframe) { try await store.read(middle, .keyframe) }
        #expect(try await store.read(middle, .fragment) == result.fragments[2])
        // Every fragment, through the cache or not, is byte for byte what the muxer wrote.
        for position in 0..<6 {
            let fragment = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + Int64(position) * 2_500 + 1)))
            #expect(try await store.read(fragment, .fragment) == result.fragments[position])
        }
    }

    @Test func soundDoesNotChangeWhereTheVideoIs() async throws {
        let (harness, result) = try await Self.started(sound: true)
        let fragment = try #require(await harness.store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 3_000)))
        let key = try await harness.store.read(fragment, .keyframe)
        #expect(key.count == 6_004 && key.dropFirst(4).first == 0x65)
        #expect(try await harness.store.read(fragment, .fragment) == result.fragments[1])
    }

    @Test func aReadCannotReachOutsideTheFileOrTheArchive() async throws {
        let (harness, _) = try await Self.started()
        let store = harness.store
        let real = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start)))
        func fake(segment: String? = nil, camera: UUID? = nil, byteLength: Int? = nil, offset: UInt64? = nil) -> ArchiveFragment {
            var fragment = ArchiveFragment(camera: camera ?? real.camera, segment: segment ?? real.segment, index: 0, start: real.start, duration: 2.5, mediaStart: 0,
                                           hasKeyframe: true, gopStart: real.start, backToKey: 0, byteLength: byteLength ?? real.byteLength)
            fragment.byteOffset = offset ?? real.byteOffset
            fragment.keyLength = real.keyLength
            fragment.headerLength = real.headerLength
            return fragment
        }
        for segment in ["../../etc/passwd", "a/b/c", "\(Self.camera.uuidString)/2026-10-10/../13-00-00", "/etc/passwd", "\(Self.camera.uuidString)/2026-10-10/13-00-00.mp4"] {
            await #expect(throws: ArchiveError.self) { try await store.read(fake(segment: segment), .fragment) }
        }
        await #expect(throws: ArchiveError.fileGone) { try await store.read(fake(segment: "\(Self.camera.uuidString)/2026-10-10/13-45-00"), .fragment) }
        await #expect(throws: ArchiveError.fileGone) { try await store.read(fake(camera: UUID()), .fragment) }
        await #expect(throws: ArchiveError.self) { try await store.read(fake(byteLength: 0), .fragment) }
        await #expect(throws: ArchiveError.self) { try await store.read(fake(byteLength: 17 * 1_048_576), .fragment) }
        await #expect(throws: ArchiveError.self) { try await store.read(fake(byteLength: 1_000, offset: UInt64.max - 10), .fragment) }
        await #expect(throws: ArchiveError.self) { try await store.read(fake(byteLength: 1_000_000, offset: 100), .fragment) }
    }

    @Test func aRepeatedReadIsServedFromTheCacheEvenWhenTheFileIsGone() async throws {
        let (harness, result) = try await Self.started()
        let store = harness.store
        let first = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start)))
        _ = try await store.read(first, .fragment)
        await store.stop()                                     // the handles close
        try FileManager.default.removeItem(at: result.mp4)
        #expect(try await store.read(first, .fragment) == result.fragments[0], "the 64 MB cache answers")
        let second = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 3_000)))
        await #expect(throws: ArchiveError.fileGone) { try await store.read(second, .fragment) }
    }

    @Test func aFileUnlinkedWhileItIsPlayedStaysReadableThroughItsOpenHandle() async throws {
        let (harness, result) = try await Self.started()
        let store = harness.store
        let first = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start)))
        let second = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 3_000)))
        let third = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 6_000)))
        _ = try await store.read(first, .fragment)             // opens the file
        try FileManager.default.removeItem(at: result.mp4)     // retention (or the person) deletes it
        #expect(try await store.read(second, .fragment) == result.fragments[1], "read through the handle that is open")
        // Reading the missing file's init segment needs the catalog's note of it: it is still there until a read finds the file gone.
        await store.stop()                                     // handles closed
        await #expect(throws: ArchiveError.fileGone) { try await store.read(third, .fragment) }
    }

    @Test func aFileThatIsGoneWhileTheDriveIsThereLeavesTheCatalogButAMissingDriveKeepsItsEntries() async throws {
        let (harness, result) = try await Self.started()
        let store = harness.store
        let fragment = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start)))
        let version = store.catalogVersion
        // The drive goes away: reads fail as a gap, nothing is forgotten.
        let hidden = harness.root.url.deletingLastPathComponent().appending(path: "hidden-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: harness.root.url, to: hidden)
        await #expect(throws: ArchiveError.fileGone) { try await store.read(fragment, .fragment) }
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.writeState.pause == .folderMissing })
        #expect(store.extent(camera: Self.camera) != nil && store.catalogVersion == version, "entries stay: the drive may come back")
        try FileManager.default.moveItem(at: hidden, to: harness.root.url)
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.writeState.pause == nil })
        #expect(try await store.read(fragment, .fragment) == result.fragments[0], "and it reads again")
        // The folder is there but the file is not: it leaves the catalog.
        await store.stop()
        try FileManager.default.removeItem(at: result.mp4)
        let other = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 8_000)))
        await #expect(throws: ArchiveError.fileGone) { try await store.read(other, .fragment) }
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.extent(camera: Self.camera) == nil }, "reconciled when a read found it gone")
        #expect(store.catalogVersion > version)
    }

    @Test func aFragmentThatIsNotWhereItsIndexSaysTakesItsFileOutOfTheTimeline() async throws {
        let (harness, result) = try await Self.started()
        let store = harness.store
        let fragment = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 8_000)))
        // Something overwrote the start of fragment 3 (the index is right about the file's size, wrong about what is in it).
        let handle = try FileHandle(forWritingTo: result.mp4)
        try handle.seek(toOffset: result.index.fragments[3].offset + 4)
        try handle.write(contentsOf: Data("junk".utf8))
        try handle.close()
        await #expect(throws: ArchiveError.unreadable("This part of the recording is damaged.")) { try await store.read(fragment, .fragment) }
        #expect(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 1_000)) == nil, "the file is out of the timeline: a gap")
        #expect(store.extent(camera: Self.camera) == nil)
        #expect(store.state.withLock { $0.repairQueue.count } == 1 && store.state.withLock { $0.damagedLogged.count } == 1)
        // Another fragment of the same file reads (the cache and the handle know nothing of the damage) but the file is not offered any more.
        let ids = await harness.ids()
        #expect(ids.isEmpty)
    }

    @Test func aSidecarThatDoesNotMatchItsFileTakesTheFileOutOfTheTimeline() async throws {
        let (harness, result) = try await Self.started()
        let store = harness.store
        // The sidecar is replaced by one of the same size with a record that points outside the mp4: its header still looks right.
        var changed = result.index
        changed.fragments[4].offset = result.index.mp4Size
        try changed.encoded().write(to: result.sidecar)
        await store.stop()
        #expect(await harness.start(), "the header passes, so the file is listed")
        let missing = await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 1_000))
        #expect(missing == nil, "its table does not: the file is out of the timeline, and queued for a rebuild once it is quiet")
        #expect(store.extent(camera: Self.camera) == nil && store.state.withLock { $0.repairQueue.count } == 1)
    }

    @Test func readsThatTimeOutFailAtOnceUntilAProbeSucceeds() async throws {
        var result: ArchiveFixtureResult?
        let harness = try ArchiveStoreHarness(readDeadline: .seconds(1), probeInterval: .seconds(3_600)) { root in
            result = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: Self.camera, cameraDirectory: Self.camera.uuidString), root: root)
        }
        await harness.start()
        let store = harness.store
        let fragment = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start)))
        // Every read slot is taken by a read that does not return (a disk that stopped answering).
        let slots = ArchiveConstants.maximumConcurrentReads
        let gate = DispatchSemaphore(value: 0)
        let stuck = (0..<slots).map { _ in Task { try? await store.reads.run { gate.wait(); return 0 } } }
        #expect(await eventually(timeout: archiveStorePatience) { store.reads.load.running == slots })
        let clock = ContinuousClock()
        let slow = await clock.measure { await #expect(throws: ArchiveError.timedOut) { try await store.read(fragment, .fragment) } }
        #expect(slow >= .milliseconds(900) && slow < .seconds(20))
        let fast = await clock.measure { await #expect(throws: ArchiveError.timedOut) { try await store.read(fragment, .fragment) } }
        #expect(fast < .milliseconds(500), "later reads fail at once, not after the deadline")
        gate.signal(); for _ in 0..<slots { gate.signal() }
        for task in stuck { _ = await task.value }
        await #expect(throws: ArchiveError.timedOut) { try await store.read(fragment, .fragment) }   // still marked: only a probe clears it
        await harness.store.probe(harness.run)
        #expect(try await store.read(fragment, .fragment) == result?.fragments[0], "the next successful probe clears it")
    }

    @Test func manyReadersAtOnceGetTheirOwnBytes() async throws {
        let (harness, result) = try await Self.started()
        let store = harness.store
        let wrong = try await withThrowingTaskGroup(of: Int.self) { group -> Int in
            for worker in 0..<12 {
                group.addTask {
                    var wrong = 0
                    for round in 0..<40 {
                        let position = (worker + round) % 6
                        guard let fragment = await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + Int64(position) * 2_500 + 100)) else { wrong += 1; continue }
                        if try await store.read(fragment, round % 2 == 0 ? .fragment : .initialization) != (round % 2 == 0 ? result.fragments[position] : result.initData) { wrong += 1 }
                    }
                    return wrong
                }
            }
            var total = 0
            for try await count in group { total += count }
            return total
        }
        #expect(wrong == 0)
    }
}
