import Foundation
import Testing
@testable import BridgeEngine

/// Where one file ends and the next begins (export-clip spec 3.3, step 4): the standard file twice, the second `gapMs` after the end of the first
/// (negative: before it). Both are 15 s of 600 pictures in all; the first ends at 15 s.
@Suite struct ClipPlannerJoinTests {
    typealias Fixture = PlannerFixture

    /// The planner over two standard files, the second starting at 15 s + `gapMs`, and the plan of everything they hold.
    static func plan(gapMs: Int64, limits: ClipLimits = .standard, to endMs: Int64 = 100_000)
        async throws -> (ClipPlan, PlannerFixtureArchive, [PlannerFixtureArchive.Built]) {
        let archive = PlannerFixtureArchive()
        let first = try archive.add(PlannerFixtureFile())
        let second = try archive.add(PlannerFixtureFile(name: "13-00-15", startMs: Fixture.t0 + 15_000 + gapMs))
        let plan = try await Fixture.planner(archive, limits: limits).plan(Fixture.request(0, endMs))
        return (plan, archive, [first, second])
    }

    @Test func twoFilesThatAbutAreOneContinuousClip() async throws {
        let (plan, _, built) = try await Self.plan(gapMs: 0)
        let part = try #require(plan.parts.first)
        #expect(plan.parts.count == 1 && part.sampleCount == 600 && Fixture.offset(part.start) == 0 && Fixture.offset(part.end) == 30_000)
        #expect(plan.gaps.isEmpty)
        let tables = try #require(plan.tables.first)
        #expect(tables.copies.map(\.fragment.fileKey) == Array(repeating: built[0].fileKey, count: 6) + Array(repeating: built[1].fileKey, count: 6))
        #expect(tables.copies.map(\.firstSample) == (0..<12).map { $0 * 50 })
        #expect(tables.samples.map(\.duration) == Array(repeating: 4_500, count: 600), "nothing is lengthened or trimmed")
    }

    @Test func aSmallOverlapOrGapIsContinuity() async throws {
        for gapMs: Int64 in [-270, -999, 999] {
            let (plan, _, _) = try await Self.plan(gapMs: gapMs)
            let tables = try #require(plan.tables.first)
            #expect(plan.parts.count == 1 && plan.gaps.isEmpty && tables.samples.count == 600, "\(gapMs) ms")
            #expect(tables.samples.map(\.duration) == Array(repeating: 4_500, count: 600), "\(gapMs) ms: the media simply continues")
        }
    }

    @Test func aTwoSecondGapIsHeldByLengtheningTheLastPicture() async throws {
        let (plan, _, _) = try await Self.plan(gapMs: 2_000)
        let tables = try #require(plan.tables.first)
        #expect(plan.parts.count == 1 && tables.samples.count == 600)
        #expect(plan.gaps == [ClipGap(from: Fixture.at(15_000), to: Fixture.at(17_000), held: true)])
        #expect(tables.samples[299].duration == 4_500 + 180_000, "the last picture of the first file lasts the 2 s of the gap as well")
        #expect(tables.samples.enumerated().allSatisfy { $0.offset == 299 || $0.element.duration == 4_500 })
        #expect(tables.samples.reduce(0) { $0 + Int($1.duration) } == 600 * 4_500 + 180_000, "32 s: the clip keeps real time")
        let part = try #require(plan.parts.first)
        #expect(Fixture.offset(part.start) == 0 && Fixture.offset(part.end) == 32_000)
    }

    @Test func aTwelveSecondGapIsSkippedAndSaidSo() async throws {
        let (plan, _, _) = try await Self.plan(gapMs: 12_000)
        let tables = try #require(plan.tables.first)
        #expect(plan.parts.count == 1 && tables.samples.count == 600)
        #expect(plan.gaps == [ClipGap(from: Fixture.at(15_000), to: Fixture.at(27_000), held: false)])
        #expect(tables.samples.map(\.duration) == Array(repeating: 4_500, count: 600), "nothing is frozen")
        #expect(Fixture.offset(try #require(plan.parts.first).end) == 42_000, "the clip jumps from 15 s to 27 s")
    }

    @Test func theLimitsOfAHoldAndOfContinuityAreExact() async throws {
        // gap in ms: (is it reported, is the picture held)
        let cases: [(Int64, Bool, Bool)] = [(999, false, false), (1_000, true, true), (10_000, true, true), (10_001, true, false)]
        for (gapMs, reported, held) in cases {
            let (plan, _, _) = try await Self.plan(gapMs: gapMs)
            let tables = try #require(plan.tables.first)
            #expect(plan.gaps.map(\.held) == (reported ? [held] : []), "\(gapMs) ms")
            #expect(tables.samples[299].duration == (held ? UInt32(4_500 + gapMs * 90) : 4_500), "\(gapMs) ms")
        }
    }

    @Test func theLimitsAreTheOnesGiven() async throws {
        let strict = ClipLimits(maxSecondsPerCamera: 7_200, maxTotalBytes: 20 << 30, maxHold: 3, continuity: 0.5)
        let (plan, _, _) = try await Self.plan(gapMs: 600, limits: strict)
        #expect(plan.gaps.map(\.held) == [true], "0.6 s is a gap when continuity is half a second")
        let (long, _, _) = try await Self.plan(gapMs: 3_001, limits: strict)
        #expect(long.gaps.map(\.held) == [false], "3.001 s is skipped when a hold lasts at most 3 s")
    }

    @Test func anOverlapOfOneSecondOrMoreCutsTheEarlierFileWhereTheLaterOneStarts() async throws {
        // The first file's last fragment is 12.5 to 15 s: it overlaps a second file that starts 1 s, 2 s or 2.4 s before its end.
        for (overlapMs, kept) in [(1_000, 30), (2_000, 10), (2_400, 2), (999, 50)] as [(Int64, Int)] {
            let (plan, _, _) = try await Self.plan(gapMs: -overlapMs)
            let tables = try #require(plan.tables.first)
            #expect(plan.gaps.isEmpty, "\(overlapMs) ms")
            #expect(tables.copies[5].sampleCount == kept && tables.copies[5].length == 104 + (kept - 1) * 44, "\(overlapMs) ms: the pictures of the first file that start before the second file does")
            #expect(tables.samples.count == 250 + kept + 300, "\(overlapMs) ms")
            #expect(tables.copies[6].firstSample == 250 + kept, "\(overlapMs) ms: the second file follows at once")
        }
    }

    @Test func aThreeSecondOverlapTrimsAFragmentLongerThanThat() async throws {
        // Fragments of 64 pictures (3.2 s) are what a camera at 12.5 pictures a second records; the second file starts 3 s before the end of the first.
        let archive = PlannerFixtureArchive()
        let long = PlannerFixtureFragment(frames: 64)
        let first = try archive.add(PlannerFixtureFile(fragments: [long, long, long]))
        let second = try archive.add(PlannerFixtureFile(name: "13-00-07", startMs: Fixture.t0 + 6_600))
        let plan = try await Fixture.planner(archive).plan(Fixture.request(0, 100_000))
        let tables = try #require(plan.tables.first)
        #expect(plan.gaps.isEmpty && plan.parts.count == 1)
        #expect(tables.copies.map(\.fragment.fileKey) == Array(repeating: first.fileKey, count: 3) + Array(repeating: second.fileKey, count: 6))
        #expect(tables.copies.map(\.sampleCount) == [64, 64, 4] + Array(repeating: 50, count: 6), "the third fragment is kept up to 6.6 s: its pictures at 6.40, 6.45, 6.50 and 6.55 s")
        #expect(tables.samples.count == 132 + 300 && tables.samples.reduce(0) { $0 + Int($1.duration) } == 432 * 4_500)
        let part = try #require(plan.parts.first)
        #expect(Fixture.offset(part.start) == 0 && Fixture.offset(part.end) == 21_600, "21.6 s of pictures in 21.6 s of time")
    }

    @Test func aHoldThatCouldNotBeStoredIsASkipInstead() async throws {
        // A picture lasts at most 2^32 ticks, 13.25 hours. With holds of up to 100,000 s allowed, a gap of 14 hours would not fit the last picture.
        let limits = ClipLimits(maxSecondsPerCamera: 7_200, maxTotalBytes: 20 << 30, maxHold: 100_000, continuity: 1)
        let (plan, _, _) = try await Self.plan(gapMs: 50_400_000, limits: limits, to: 51_000_000)
        #expect(plan.gaps.map(\.held) == [false])
        #expect(try #require(plan.tables.first).samples.map(\.duration) == Array(repeating: 4_500, count: 600))
        let (shorter, _, _) = try await Self.plan(gapMs: 3_600_000, limits: limits, to: 3_700_000)
        #expect(shorter.gaps.map(\.held) == [true] && shorter.tables.first?.samples[299].duration == 4_500 + 3_600 * 90_000, "an hour fits")
    }
}
