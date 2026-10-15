import Foundation
import Synchronization
import Testing
@testable import BridgeEngine

/// The limits of a plan (export-clip spec 3.3, step 7) and the sizes it reports: seconds of media, bytes in all, and sizes at the 4 GiB edge.
@Suite struct ClipPlannerLimitTests {
    typealias Fixture = PlannerFixture

    static func limits(seconds: Int = 7_200, bytes: Int64 = 20 << 30) -> ClipLimits {
        ClipLimits(maxSecondsPerCamera: seconds, maxTotalBytes: bytes, maxHold: 10, continuity: 1)
    }

    static func standard(_ limits: ClipLimits, sizing: @escaping @Sendable (ClipPartTables) throws -> Int64 = PlannerFixture.sizing) throws
        -> (ClipPlanner, PlannerFixtureArchive) {
        let archive = PlannerFixtureArchive()
        try archive.add(PlannerFixtureFile())
        return (Fixture.planner(archive, limits: limits, sizing: sizing), archive)
    }

    @Test func tenSecondsOfMediaIsWithinATenSecondLimitAndOnePictureMoreIsNot() async throws {
        let (planner, _) = try Self.standard(Self.limits(seconds: 10))
        let exact = try await planner.plan(Fixture.request(0, 10_000))
        #expect(exact.parts.first?.sampleCount == 200 && exact.duration == 10)
        await #expect(throws: ClipError.tooLong(maxSeconds: 10)) { try await planner.plan(Fixture.request(0, 10_050)) }
    }

    @Test func theSecondsAreThoseOfTheFileLeadInIncluded() async throws {
        let (planner, _) = try Self.standard(Self.limits(seconds: 10))
        // 6.0 to 12.5 s is 6.5 s asked for, but the clip begins at the key picture at 2.5 s: 10 s of pictures.
        let exact = try await planner.plan(Fixture.request(6_000, 12_500))
        #expect(exact.parts.first?.sampleCount == 200)
        await #expect(throws: ClipError.tooLong(maxSeconds: 10)) { try await planner.plan(Fixture.request(6_000, 13_000)) }
    }

    @Test func aHeldGapCountsAndASkippedOneDoesNot() async throws {
        // Two files of 15 s: 32 s of media with a 2 s hold, 30 s with a 12 s gap that is skipped.
        let held = try await ClipPlannerJoinTests.plan(gapMs: 2_000, limits: Self.limits(seconds: 32))
        #expect(held.0.parts.first?.sampleCount == 600)
        await #expect(throws: ClipError.tooLong(maxSeconds: 31)) { try await ClipPlannerJoinTests.plan(gapMs: 2_000, limits: Self.limits(seconds: 31)) }
        let skipped = try await ClipPlannerJoinTests.plan(gapMs: 12_000, limits: Self.limits(seconds: 30))
        #expect(skipped.0.gaps.map(\.held) == [false])
    }

    @Test func aLimitOfAnythingUpToIntMaxSecondsDoesNotOverflow() async throws {
        let (planner, _) = try Self.standard(Self.limits(seconds: .max))
        #expect(try await planner.plan(Fixture.request(0, 5_000)).parts.first?.sampleCount == 100)
        let (none, _) = try Self.standard(Self.limits(seconds: -1))
        await #expect(throws: ClipError.tooLong(maxSeconds: -1)) { try await none.plan(Fixture.request(0, 5_000)) }
    }

    @Test func aTooLongRangeStopsReadingAsSoonAsItIsTooLong() async throws {
        let archive = PlannerFixtureArchive()
        try archive.add(PlannerFixtureFile())
        try archive.add(PlannerFixtureFile(name: "13-00-15", startMs: Fixture.t0 + 15_000))
        let planner = Fixture.planner(archive, limits: Self.limits(seconds: 5))
        await #expect(throws: ClipError.tooLong(maxSeconds: 5)) { try await planner.plan(Fixture.request(0, 100_000)) }
        #expect(archive.reads(of: .header).count == 4, "5 s are 2 fragments; the third is the one that is too much, and the fourth was read before it was added")
    }

    @Test func bytesInAllAboveTheLimitAreTooLarge() async throws {
        let (fits, _) = try Self.standard(Self.limits(bytes: 1_000)) { _ in 1_000 }
        let plan = try await fits.plan(Fixture.request(0, 5_000))
        #expect(plan.byteCount == 1_000 && plan.parts.first?.byteCount == 1_000)
        let (tooMuch, _) = try Self.standard(Self.limits(bytes: 999)) { _ in 1_000 }
        await #expect(throws: ClipError.tooLarge(maxBytes: 999)) { try await tooMuch.plan(Fixture.request(0, 5_000)) }
    }

    @Test func theSizesOfAllPartsAreAddedUp() async throws {
        let archive = PlannerFixtureArchive()
        try archive.add(PlannerFixtureFile())
        try archive.add(PlannerFixtureFile(name: "13-00-15", startMs: Fixture.t0 + 15_000, format: ArchiveMediaFixtures.tapoFormat))
        let request = Fixture.request(0, 100_000)
        let fits = try await Fixture.planner(archive, limits: Self.limits(bytes: 1_200)) { _ in 600 }.plan(request)
        #expect(fits.parts.map(\.byteCount) == [600, 600] && fits.byteCount == 1_200)
        await #expect(throws: ClipError.tooLarge(maxBytes: 1_199)) { try await Fixture.planner(archive, limits: Self.limits(bytes: 1_199)) { _ in 600 }.plan(request) }
    }

    @Test func sizingSeesEachPartsTablesOnce() async throws {
        let archive = PlannerFixtureArchive()
        try archive.add(PlannerFixtureFile())
        try archive.add(PlannerFixtureFile(name: "13-00-15", startMs: Fixture.t0 + 15_000, format: ArchiveMediaFixtures.tapoFormat))
        let seen = Mutex<[(samples: Int, copies: Int, width: Int)]>([])
        let planner = Fixture.planner(archive) { tables in
            seen.withLock { $0.append((tables.samples.count, tables.copies.count, tables.width)) }
            return Int64(tables.samples.count)
        }
        let plan = try await planner.plan(Fixture.request(0, 100_000))
        let calls = seen.withLock { $0 }
        #expect(calls.map(\.samples) == [300, 300] && calls.map(\.copies) == [6, 6] && calls.map(\.width) == [640, 2_688])
        #expect(plan.parts.map(\.byteCount) == [300, 300])
    }

    @Test func aPartJustUnderOrOverFourGibIsReportedExactly() async throws {
        let four: Int64 = 4 << 30
        for size in [four - 1, four, four + 1] {
            let (planner, _) = try Self.standard(.standard) { _ in size }
            let plan = try await planner.plan(Fixture.request(0, 5_000))
            #expect(plan.parts.first?.byteCount == size && plan.byteCount == size, "\(size) bytes")
        }
        let archive = PlannerFixtureArchive()
        try archive.add(PlannerFixtureFile())
        try archive.add(PlannerFixtureFile(name: "13-00-15", startMs: Fixture.t0 + 15_000, format: ArchiveMediaFixtures.tapoFormat))
        let two = try await Fixture.planner(archive) { _ in four + 1 }.plan(Fixture.request(0, 100_000))
        #expect(two.parts.map(\.byteCount) == [four + 1, four + 1] && two.byteCount == 2 * four + 2)
    }

    @Test func theLimitOnBytesIsExactAndSizesAtTheEdgeOfInt64DoNotOverflow() async throws {
        let twenty: Int64 = 20 << 30
        let (atLimit, _) = try Self.standard(.standard) { _ in twenty }
        #expect(try await atLimit.plan(Fixture.request(0, 5_000)).byteCount == twenty)
        let (over, _) = try Self.standard(.standard) { _ in twenty + 1 }
        await #expect(throws: ClipError.tooLarge(maxBytes: twenty)) { try await over.plan(Fixture.request(0, 5_000)) }
        let (huge, _) = try Self.standard(Self.limits(bytes: .max)) { _ in .max }
        #expect(try await huge.plan(Fixture.request(0, 5_000)).byteCount == .max)
        let archive = PlannerFixtureArchive()
        try archive.add(PlannerFixtureFile())
        try archive.add(PlannerFixtureFile(name: "13-00-15", startMs: Fixture.t0 + 15_000, format: ArchiveMediaFixtures.tapoFormat))
        let sizes = Mutex<[Int64]>([.max, 1])
        let overflowing = Fixture.planner(archive, limits: Self.limits(bytes: .max)) { _ in sizes.withLock { $0.removeFirst() } }
        await #expect(throws: ClipError.tooLarge(maxBytes: .max)) { try await overflowing.plan(Fixture.request(0, 100_000)) }
    }
}
