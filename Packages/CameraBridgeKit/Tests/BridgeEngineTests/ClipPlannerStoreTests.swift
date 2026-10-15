import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// The planner over the real store (`ArchiveStore`) and the files `ArchiveFixtureWriter` writes: what the store answers to a `header` read is what the
/// planner parses, and what it plans is where the pictures are in the file.
@Suite struct ClipPlannerStoreTests {
    static let camera = ArchiveStoreHarness.camera
    static let start: Int64 = 1_760_101_200_000

    static func request(_ fromMs: Int64, _ toMs: Int64) -> ClipRequest {
        ClipRequest(camera: camera, cameraName: "Driveway", start: ArchiveTime.date(ms: start + fromMs), end: ArchiveTime.date(ms: start + toMs),
                    timeZone: TimeZone(identifier: "UTC")!)
    }

    /// A started store with one real file of six fragments of 50 pictures: two that start a group of pictures, two that continue it, two more that
    /// start one (`backToKey` 0, 0, 1, 2, 0, 0). A key picture is 6,004 bytes, any other 404.
    static func started() async throws -> (ArchiveStoreHarness, ArchiveFixtureResult) {
        var result: ArchiveFixtureResult?
        let plan = [ArchiveFixtureFragment(), ArchiveFixtureFragment(), ArchiveFixtureFragment(startsOnKey: false), ArchiveFixtureFragment(startsOnKey: false),
                    ArchiveFixtureFragment(), ArchiveFixtureFragment()]
        let harness = try ArchiveStoreHarness { root in
            result = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: camera, cameraDirectory: camera.uuidString, fragments: plan), root: root)
        }
        await harness.start()
        return (harness, try #require(result))
    }

    @Test func aPlanOverTheRealStoreFindsThePicturesWhereTheFileHasThem() async throws {
        let (harness, result) = try await Self.started()
        let store = harness.store
        let planner = ClipPlanner(archive: store, limits: .standard) { tables in Int64(tables.copies.reduce(0) { $0 + $1.length }) }
        // 6.0 s is in fragment 2, which continues the group of pictures that fragment 1 starts; the end, 9.0 s, is in fragment 3.
        let plan = try await planner.plan(Self.request(6_000, 9_000))
        let part = try #require(plan.parts.first)
        #expect(plan.parts.count == 1 && part.leadIn == 3.5 && part.sampleCount == 50 + 50 + 30)
        #expect(ArchiveTime.ms(part.start) == Self.start + 2_500 && ArchiveTime.ms(part.end) == Self.start + 9_000)
        let tables = try #require(plan.tables.first)
        let lengths: [Int] = tables.copies.map(\.length)
        let firsts: [Int] = tables.copies.map(\.firstSample)
        let expectedLengths: [Int] = [6_004 + 49 * 404, 50 * 404, 30 * 404]
        #expect(lengths == expectedLengths && firsts == [0, 50, 100])
        #expect(tables.initialization == result.initData && tables.width == 640 && tables.height == 360)
        let totalBytes: Int64 = Int64(expectedLengths.reduce(0, +))
        #expect(part.byteCount == totalBytes)
        // Where the planner says the pictures start they start: the copy begins at the NAL unit header (0x65 of a key picture, 0x41 of any other)
        // behind its 4-byte length, and the header read is the beginning of the fragment.
        for (position, copy) in tables.copies.enumerated() {
            let fragment = try await store.read(copy.fragment, .fragment)
            let header = try await store.read(copy.fragment, .header)
            #expect(copy.skipBytes == Int(result.index.fragments[position + 1].headerLength) && header == fragment.prefix(copy.skipBytes))
            #expect(fragment[fragment.startIndex + copy.skipBytes + 4] == (position == 0 ? 0x65 : 0x41))
            #expect(copy.skipBytes + copy.length <= fragment.count)
        }
    }

    @Test func anOpenFileIsPlannedUpToTheNewestFragmentTheRecorderSaidItWrote() async throws {
        let harness = try ArchiveStoreHarness()
        await harness.start()
        let result = try harness.write(startMs: Self.start, writesIndex: false)          // six fragments on disk, no sidecar: the recorder is still writing
        let store = harness.store
        let file = ArchiveOpenFile(camera: Self.camera, segment: result.file.segment)
        store.recorderOpened(file, startWallMs: Self.start, initLength: result.index.initLength, hasAudio: false)
        for record in result.index.fragments.prefix(3) { store.recorderWrote(file, record) }
        let planner = ClipPlanner(archive: store, limits: .standard) { _ in 1 }
        let plan = try await planner.plan(Self.request(0, 60_000))
        let part = try #require(plan.parts.first)
        #expect(ArchiveTime.ms(part.end) == Self.start + 7_500 && part.sampleCount == 150, "the third fragment is the newest the store was told about")
        #expect(try #require(plan.tables.first).copies.map(\.fragment.index) == [0, 1, 2])
        store.recorderWrote(file, result.index.fragments[3])                               // the recorder goes on
        #expect(try #require(plan.tables.first).copies.count == 3, "a plan that was made does not change")
        let later = try await planner.plan(Self.request(0, 60_000))
        let laterEnd = ArchiveTime.ms(try #require(later.parts.first).end)
        #expect(later.tables.first?.copies.count == 4 && laterEnd == Self.start + 10_000)
    }

    @Test func aDriveThatIsGoneIsAGoneDrive() async throws {
        let (harness, _) = try await Self.started()
        let planner = ClipPlanner(archive: harness.store, limits: .standard) { _ in 1 }
        let hidden = harness.root.url.deletingLastPathComponent().appending(path: "hidden-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: harness.root.url, to: hidden)
        await #expect(throws: ClipError.driveGone) { try await planner.plan(Self.request(0, 5_000)) }
        try FileManager.default.moveItem(at: hidden, to: harness.root.url)
    }

    @Test func aStoreThatIsStillLoadingIsNotReady() async throws {
        let harness = try ArchiveStoreHarness()
        let planner = ClipPlanner(archive: harness.store, limits: .standard) { _ in 1 }
        await #expect(throws: ClipError.notReady) { try await planner.plan(Self.request(0, 5_000)) }
    }
}
