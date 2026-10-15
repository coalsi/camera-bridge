import Foundation
import Testing
@testable import BridgeEngine

/// The range of a clip: what the planner clamps, where it starts, where it stops and what it copies (export-clip spec 3.3, steps 1 to 3).
/// The standard file has six fragments of 50 pictures (2.5 s): K K C C K K, that is `backToKey` 0 0 1 2 0 0; a key picture is 104 bytes, any other 44.
@Suite struct ClipPlannerRangeTests {
    typealias Fixture = PlannerFixture

    /// The planner, the archive and the one file in it.
    static func standard() throws -> (ClipPlanner, PlannerFixtureArchive, PlannerFixtureArchive.Built) {
        let archive = PlannerFixtureArchive()
        let built = try archive.add(PlannerFixtureFile())
        return (Fixture.planner(archive), archive, built)
    }

    @Test func aRangeInsideOneFragmentIsThatFragmentUpToTheEnd() async throws {
        let (planner, archive, built) = try Self.standard()
        let plan = try await planner.plan(Fixture.request(500, 1_500))
        let part = try #require(plan.parts.first)
        #expect(plan.parts.count == 1 && part.index == 1 && part.count == 1)
        #expect(Fixture.offset(part.start) == 0 && Fixture.offset(part.end) == 1_500, "30 pictures of 50 ms: the one at 1.45 s is the last that starts before 1.5 s")
        #expect(part.leadIn == 0.5 && part.sampleCount == 30)
        let record = built.records[0]
        let tables = try #require(plan.tables.first)
        #expect(tables.copies == [ClipCopy(fragment: try #require(await archive.fragment(camera: Fixture.camera, id: built.id(0))), skipBytes: Int(record.headerLength),
                                           length: 104 + 29 * 44, firstSample: 0, sampleCount: 30)])
        #expect(tables.samples.count == 30 && tables.samples.map(\.duration) == Array(repeating: 4_500, count: 30) && tables.samples.map(\.isSync) == [true] + Array(repeating: false, count: 29))
        #expect(tables.samples.map(\.size) == [104] + Array(repeating: 44, count: 29) && tables.samples.allSatisfy { $0.compositionOffset == 0 })
        #expect(part.byteCount == Int64(104 + 29 * 44 + 100) && plan.byteCount == part.byteCount, "the size is what `sizing` said")
        #expect(plan.gaps.isEmpty && !plan.soundOmitted && plan.request == Fixture.request(500, 1_500))
    }

    @Test func thePartCarriesTheSizeTheFileNameAndTheTablesOfItsFirstFile() async throws {
        let (planner, _, built) = try Self.standard()
        let request = Fixture.request(500, 1_500)
        let plan = try await planner.plan(request)
        let part = try #require(plan.parts.first)
        #expect(part.fileName == ClipFileName.part(cameraName: "Driveway", start: part.start, end: part.end, partIndex: 1, partCount: 1, timeZone: request.timeZone))
        #expect(!part.fileName.contains("(part"), "one part: no part suffix")
        let tables = try #require(plan.tables.first)
        #expect(tables.initialization == built.initData && tables.wallStart == part.start && tables.width == 640 && tables.height == 360)
        #expect(plan.tables.count == plan.parts.count && plan.duration == part.end.timeIntervalSince(part.start))
    }

    @Test func aRangeThatStartsAndEndsOnFragmentBoundariesTakesWholeFragmentsAndReadsNoMore() async throws {
        let (planner, archive, built) = try Self.standard()
        let plan = try await planner.plan(Fixture.request(2_500, 7_500))
        let part = try #require(plan.parts.first)
        #expect(Fixture.offset(part.start) == 2_500 && Fixture.offset(part.end) == 7_500 && part.leadIn == 0 && part.sampleCount == 100)
        let copies = try #require(plan.tables.first).copies
        #expect(copies.map(\.length) == [104 + 49 * 44, 50 * 44] && copies.map(\.firstSample) == [0, 50] && copies.map(\.sampleCount) == [50, 50])
        #expect(copies.map(\.fragment.id) == [built.id(1), built.id(2)] && copies.map(\.skipBytes) == [Int(built.records[1].headerLength), Int(built.records[2].headerLength)])
        #expect(archive.reads(of: .header) == [built.id(1), built.id(2)], "the fragment that starts at the end is not read")
    }

    @Test func aStartInsideAContinuationFragmentBeginsAtTheKeyFragmentBeforeIt() async throws {
        let (planner, archive, built) = try Self.standard()
        // 6.0 s is in fragment 2 (5.0 to 7.5 s), which continues the group of pictures of fragment 1.
        let plan = try await planner.plan(Fixture.request(6_000, 8_000))
        let part = try #require(plan.parts.first)
        #expect(Fixture.offset(part.start) == 2_500 && Fixture.offset(part.end) == 8_000 && part.leadIn == 3.5, "the clip begins at the key picture, 3.5 s before the start")
        #expect(part.sampleCount == 110)
        let tables = try #require(plan.tables.first)
        #expect(tables.copies.map(\.fragment.id) == [built.id(1), built.id(2), built.id(3)])
        #expect(tables.copies.map(\.length) == [104 + 49 * 44, 50 * 44, 10 * 44] && tables.copies.map(\.firstSample) == [0, 50, 100])
        #expect(tables.samples.map(\.isSync) == [true] + Array(repeating: false, count: 109), "one key picture, first")
        #expect(archive.reads(of: .header) == [built.id(1), built.id(2), built.id(3)])
    }

    @Test func aStartDeepInAGroupOfPicturesGoesBackToItsKeyFragment() async throws {
        let (planner, _, built) = try Self.standard()
        // Fragment 3 has `backToKey` 2: its key picture is in fragment 1.
        let plan = try await planner.plan(Fixture.request(8_000, 12_000))
        let part = try #require(plan.parts.first)
        #expect(Fixture.offset(part.start) == 2_500 && part.leadIn == 5.5 && part.sampleCount == 50 + 50 + 50 + 40)
        #expect(try #require(plan.tables.first).copies.map(\.fragment.id) == [built.id(1), built.id(2), built.id(3), built.id(4)])
        #expect(Fixture.offset(part.end) == 12_000)
    }

    @Test func aStartBeforeTheOldestRecordingBeginsAtTheOldestAndHasNoLeadIn() async throws {
        let (planner, _, built) = try Self.standard()
        let plan = try await planner.plan(Fixture.request(-10_000, 5_000))
        let part = try #require(plan.parts.first)
        #expect(Fixture.offset(part.start) == 0 && part.leadIn == 0 && part.sampleCount == 100 && Fixture.offset(part.end) == 5_000)
        #expect(try #require(plan.tables.first).copies.map(\.fragment.id) == [built.id(0), built.id(1)])
    }

    @Test func anEndAfterTheNewestRecordingStopsAtTheEndOfTheNewestFragment() async throws {
        let (planner, _, built) = try Self.standard()
        let plan = try await planner.plan(Fixture.request(10_000, 60_000))
        let part = try #require(plan.parts.first)
        #expect(Fixture.offset(part.start) == 10_000 && Fixture.offset(part.end) == 15_000 && part.sampleCount == 100 && part.leadIn == 0)
        #expect(try #require(plan.tables.first).copies.map(\.fragment.id) == [built.id(4), built.id(5)])
    }

    @Test func aRangeBeforeTheOldestOrAfterTheNewestHasNothing() async throws {
        let (planner, archive, _) = try Self.standard()
        for (from, to) in [(-20_000, -5_000), (20_000, 30_000), (15_000, 40_000), (-9_000, 0)] as [(Int64, Int64)] {
            await #expect(throws: ClipError.nothingRecorded, "\(from) to \(to)") { try await planner.plan(Fixture.request(from, to)) }
        }
        #expect(archive.reads.isEmpty, "decided without a read")
    }

    @Test func aStartInAGapBeginsAtTheNextRecordingAndSaysSo() async throws {
        let archive = PlannerFixtureArchive()
        let first = try archive.add(PlannerFixtureFile())
        let second = try archive.add(PlannerFixtureFile(name: "13-00-35", startMs: Fixture.t0 + 35_000))
        let planner = Fixture.planner(archive)
        // The first file ends at 15 s and the second starts at 35 s: 20 s is in the gap.
        let plan = try await planner.plan(Fixture.request(20_000, 45_000))
        let part = try #require(plan.parts.first)
        #expect(Fixture.offset(part.start) == 35_000 && Fixture.offset(part.end) == 45_000 && part.leadIn == 0 && part.sampleCount == 200)
        #expect(try #require(plan.tables.first).copies.map(\.fragment.id) == [second.id(0), second.id(1), second.id(2), second.id(3)])
        #expect(!archive.reads.contains { $0.fragment.hasPrefix(first.fileKey) }, "nothing of the first file is read")
        let reads = archive.reads.count
        await #expect(throws: ClipError.nothingRecorded) { try await planner.plan(Fixture.request(18_000, 30_000)) }
        #expect(archive.reads.count == reads, "a range that holds nothing is decided without a read")
    }

    @Test func anArchiveThatIsStillLoadingIsNotReadyAndOneWithoutRecordingsHasNothing() async throws {
        let (planner, archive, _) = try Self.standard()
        archive.setReady(false)
        await #expect(throws: ClipError.notReady) { try await planner.plan(Fixture.request(0, 5_000)) }
        archive.setReady(true)
        await #expect(throws: ClipError.nothingRecorded) { try await planner.plan(Fixture.request(0, 5_000, camera: UUID())) }
        await #expect(throws: ClipError.nothingRecorded) { try await Fixture.planner(PlannerFixtureArchive()).plan(Fixture.request(0, 5_000)) }
        #expect(archive.reads.isEmpty)
    }

    @Test func aClipUnderOneSecondIsNothingAndExactlyOneSecondIsAClip() async throws {
        let (planner, _, _) = try Self.standard()
        await #expect(throws: ClipError.nothingRecorded) { try await planner.plan(Fixture.request(500, 1_499)) }
        await #expect(throws: ClipError.nothingRecorded) { try await planner.plan(Fixture.request(5_000, 3_000)) }
        await #expect(throws: ClipError.nothingRecorded) { try await planner.plan(Fixture.request(14_500, 20_000)) }
        await #expect(throws: ClipError.nothingRecorded) { try await planner.plan(Fixture.request(-5_000, 999)) }
        let exact = try await planner.plan(Fixture.request(500, 1_500))
        #expect(exact.parts.first?.sampleCount == 30)
        let clamped = try await planner.plan(Fixture.request(-5_000, 1_000))
        #expect(clamped.parts.first?.sampleCount == 20, "clamped to the oldest, a second is a clip")
        let atTheEnd = try await planner.plan(Fixture.request(14_000, 15_000))
        #expect(Fixture.offset(try #require(atTheEnd.parts.first).start) == 12_500 && atTheEnd.parts.first?.sampleCount == 50)
    }

    @Test func thePlanReadsOneInitializationSegmentAndHeadersOnly() async throws {
        let (planner, archive, built) = try Self.standard()
        _ = try await planner.plan(Fixture.request(0, 15_000))
        #expect(archive.reads(of: .initialization) == [built.id(0)], "one per file, for the first fragment that needed it")
        #expect(archive.reads(of: .header) == (0..<6).map(built.id))
        #expect(archive.reads.count == 7 && !archive.reads.contains { $0.part == .fragment || $0.part == .keyframe })
    }
}
