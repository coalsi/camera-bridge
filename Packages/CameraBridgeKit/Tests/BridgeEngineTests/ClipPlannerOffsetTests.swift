import Foundation
import Testing
@testable import BridgeEngine

/// Composition offsets (export-clip spec 3.3, steps 3 and 6): the end of a clip is by the time a picture is shown, and offsets that are all equal
/// are subtracted while offsets that differ are kept. Pictures are 4,500 ticks (50 ms) apart in decode order.
@Suite struct ClipPlannerOffsetTests {
    typealias Fixture = PlannerFixture

    /// One file of a single fragment of `frames` pictures whose offsets are `offset`.
    static func plan(frames: Int = 50, from: Int64 = 0, to: Int64, offset: @escaping @Sendable (Int) -> Int64) async throws -> ClipPlan {
        let archive = PlannerFixtureArchive()
        try archive.add(PlannerFixtureFile(fragments: [PlannerFixtureFragment(frames: frames, compositionOffset: offset)]))
        return try await Fixture.planner(archive).plan(Fixture.request(from, to))
    }

    @Test func offsetsThatAreAllEqualAreSubtracted() async throws {
        let plan = try await Self.plan(to: 1_500) { _ in 9_000 }
        let tables = try #require(plan.tables.first)
        #expect(tables.samples.allSatisfy { $0.compositionOffset == 0 }, "the clip's pictures are shown from its start, not 0.1 s after it")
        #expect(tables.samples.map(\.duration) == Array(repeating: 4_500, count: tables.samples.count), "the durations are as recorded")
        let negative = try await Self.plan(to: 1_500) { _ in -4_500 }
        #expect(try #require(negative.tables.first).samples.allSatisfy { $0.compositionOffset == 0 })
    }

    @Test func aSharedOffsetMovesTheEndOfTheClipBecauseThePicturesAreShownLater() async throws {
        // The picture at 1.35 s is shown at 1.45 s, the one at 1.40 s at 1.50 s: with the end at 1.5 s the clip holds 28 pictures, not 30.
        let later = try await Self.plan(to: 1_500) { _ in 9_000 }
        #expect(later.parts.first?.sampleCount == 28)
        let sooner = try await Self.plan(to: 1_500) { _ in -4_500 }
        #expect(sooner.parts.first?.sampleCount == 31, "shown 50 ms earlier: the picture at 1.5 s is shown at 1.45 s")
        let plain = try await Self.plan(to: 1_500) { _ in 0 }
        #expect(plain.parts.first?.sampleCount == 30)
    }

    @Test func offsetsThatDifferAreKeptAsRecordedNegativeOnesToo() async throws {
        let plan = try await Self.plan(to: 1_000) { $0 % 2 == 0 ? 4_500 : -4_500 }
        let samples = try #require(plan.tables.first).samples
        // Even pictures are shown a frame late, odd ones a frame early: shown at 4,500 x (i + 1) and 4,500 x (i - 1) ticks. By 1.0 s (90,000 ticks)
        // the last picture in decode order that is shown is the 20th (index 19, shown at 81,000); the 22nd (index 21) is shown at exactly 90,000.
        #expect(samples.count == 20)
        #expect(samples.map(\.compositionOffset) == (0..<20).map { $0 % 2 == 0 ? 4_500 : -4_500 })
        #expect(samples.map(\.duration) == Array(repeating: 4_500, count: 20), "no time stamp is made up")
        let mixed = try await Self.plan(to: 2_000) { $0 < 25 ? 9_000 : 0 }
        let kept = try #require(mixed.tables.first).samples
        #expect(kept.count == 40 && kept[24].compositionOffset == 9_000 && kept[25].compositionOffset == 0, "a part that starts with offsets and goes on without them has varying ones")
    }

    @Test func theLastPictureIsTheLastInDecodeOrderThatIsShownBeforeTheEnd() async throws {
        // Picture 18 is shown late (at 1.08 s: its offset is 27,000 ticks) and the pictures after it are shown on time. The end is 1.1 s.
        // Picture 18 is shown after the end but pictures 19, 20 and 21 are not, and they need it to be decoded: the clip holds pictures 0 to 21.
        let plan = try await Self.plan(frames: 30, to: 1_100) { $0 == 18 ? 27_000 : 0 }
        let samples = try #require(plan.tables.first).samples
        #expect(samples.count == 22 && plan.parts.first?.sampleCount == 22)
        #expect(samples[18].compositionOffset == 27_000 && samples.filter { $0.compositionOffset != 0 }.count == 1)
        // The pictures that a clip of plain pictures holds up to 1.1 s are 22 too (0 to 21); picture 22 is shown at exactly 1.1 s.
        let plain = try await Self.plan(frames: 30, to: 1_100) { _ in 0 }
        #expect(plain.parts.first?.sampleCount == 22)
    }

    @Test func aRangeWhoseFirstPictureIsShownAfterTheEndHasNothing() async throws {
        // Every picture is shown 3 s late: nothing is shown before 2 s.
        await #expect(throws: ClipError.nothingRecorded) { try await Self.plan(to: 2_000) { _ in 270_000 } }
    }
}
