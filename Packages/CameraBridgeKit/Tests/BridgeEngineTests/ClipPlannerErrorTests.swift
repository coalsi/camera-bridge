import Foundation
import Testing
import TestSupport
@testable import BridgeEngine

/// What goes wrong while a plan is made (export-clip spec 3.3, step 8): a drive that is gone or slow, bytes that are not what the index said, the
/// caller giving up, and the priority the reads run at. A plan ends with a `ClipError`, never with an `ArchiveError` or an FMP4 error.
@Suite struct ClipPlannerErrorTests {
    typealias Fixture = PlannerFixture

    static func standard() throws -> (ClipPlanner, PlannerFixtureArchive, PlannerFixtureArchive.Built) {
        let archive = PlannerFixtureArchive()
        let built = try archive.add(PlannerFixtureFile())
        return (Fixture.planner(archive), archive, built)
    }

    /// Fails read number `number` of the archive with `error`.
    static func failRead(_ number: Int, of archive: PlannerFixtureArchive, with error: ArchiveError) {
        archive.setHook { read, _, _ in if read == number { throw error } }
    }

    @Test func aFileOrADriveThatIsNotThereOnTheFirstReadIsAGoneDrive() async throws {
        for error in [ArchiveError.fileGone, ArchiveError.timedOut] {
            let (planner, archive, _) = try Self.standard()
            Self.failRead(1, of: archive, with: error)
            await #expect(throws: ClipError.driveGone, "\(error)") { try await planner.plan(Fixture.request(0, 5_000)) }
            #expect(archive.reads.count == 1, "and the plan stops there")
        }
    }

    @Test func theSameAnswerLaterInTheRangeIsARecordingThatCannotBeReadThere() async throws {
        for error in [ArchiveError.fileGone, ArchiveError.timedOut, ArchiveError.unreadable("x")] {
            let (planner, archive, _) = try Self.standard()
            archive.setHook { _, fragment, part in if fragment.index == 3 && part == .header { throw error } }
            await #expect(throws: ClipError.damaged(at: Fixture.at(7_500)), "\(error)") { try await planner.plan(Fixture.request(0, 15_000)) }
        }
        let (planner, archive, _) = try Self.standard()
        Self.failRead(2, of: archive, with: .fileGone)
        await #expect(throws: ClipError.damaged(at: Fixture.at(0)), "the header of the first fragment is the second read") { try await planner.plan(Fixture.request(0, 5_000)) }
    }

    @Test func aReadThatEndsInACancellationIsCancelled() async throws {
        let (planner, archive, _) = try Self.standard()
        archive.setHook { number, _, _ in if number == 2 { throw CancellationError() } }
        await #expect(throws: ClipError.cancelled) { try await planner.plan(Fixture.request(0, 5_000)) }
    }

    @Test func aFragmentTheIndexCalledUnreadableIsDamagedAtItsStart() async throws {
        let (planner, archive, _) = try Self.standard()
        Self.failRead(1, of: archive, with: .unreadable("This part of the recording is damaged."))
        await #expect(throws: ClipError.damaged(at: Fixture.at(0))) { try await planner.plan(Fixture.request(0, 5_000)) }
        let (second, other, _) = try Self.standard()
        other.setHook { _, fragment, part in if fragment.index == 1 && part == .header { throw ArchiveError.noKeyframe } }
        await #expect(throws: ClipError.damaged(at: Fixture.at(2_500))) { try await second.plan(Fixture.request(0, 5_000)) }
    }

    @Test func bytesThatAreNotWhatTheIndexSaidAreDamagedAtTheFragment() async throws {
        let damages: [(String, @Sendable (Data) -> Data)] = [
            ("cut short", { Data($0.prefix(20)) }),
            ("garbage", { Data(repeating: 0xFF, count: $0.count) }),
            ("a moof longer than the header", { var data = $0; data.replaceSubrange(32..<36, with: [0, 0x10, 0, 0]); return data }),
            ("an mdat smaller than the samples", { var data = $0; data.replaceSubrange(data.count - 8..<data.count - 4, with: [0, 0, 0, 9]); return data }),
            ("no mdat after the moof", { var data = $0; data.replaceSubrange(data.count - 4..<data.count, with: Array("free".utf8)); return data }),
            ("an empty read", { _ in Data() }),
        ]
        for (name, damage) in damages {
            let (planner, archive, _) = try Self.standard()
            archive.setTamper { fragment, part, data in fragment.index == 2 && part == .header ? damage(data) : data }
            await #expect(throws: ClipError.damaged(at: Fixture.at(5_000)), "\(name)") { try await planner.plan(Fixture.request(0, 15_000)) }
        }
    }

    @Test func anIndexThatDisagreesWithTheFileAboutWhereTheVideoIsMakesTheFragmentDamaged() async throws {
        let archive = PlannerFixtureArchive()
        try archive.add(PlannerFixtureFile(headerLengthShift: 4))
        await #expect(throws: ClipError.damaged(at: Fixture.at(0)), "the video starts 4 bytes before where the index says") { try await Fixture.planner(archive).plan(Fixture.request(0, 5_000)) }
        let short = PlannerFixtureArchive()
        try short.add(PlannerFixtureFile(lengthShift: -10))
        await #expect(throws: ClipError.damaged(at: Fixture.at(0)), "the fragment the index describes ends before its video does") { try await Fixture.planner(short).plan(Fixture.request(0, 5_000)) }
    }

    @Test func anInitializationSegmentThatIsNotOneIsDamagedAtTheFirstFragment() async throws {
        let (planner, archive, _) = try Self.standard()
        archive.setTamper { _, part, data in part == .initialization ? Data(data.prefix(10)) : data }
        await #expect(throws: ClipError.damaged(at: Fixture.at(0))) { try await planner.plan(Fixture.request(0, 5_000)) }
    }

    @Test func aFileWhoseTimescaleIsNotNinetyKilohertzCannotBePlanned() async throws {
        let archive = PlannerFixtureArchive()
        try archive.add(PlannerFixtureFile(videoTimescale: 30_000))
        await #expect(throws: ClipError.damaged(at: Fixture.at(0))) { try await Fixture.planner(archive).plan(Fixture.request(0, 5_000)) }
    }

    @Test func aKeyFragmentThatRetentionTookIsAGoneDrive() async throws {
        let (planner, archive, built) = try Self.standard()
        archive.hide(built.id(1))
        await #expect(throws: ClipError.driveGone) { try await planner.plan(Fixture.request(6_000, 8_000)) }
        #expect(archive.reads.isEmpty)
    }

    @Test func aSizeThatCannotBeWorkedOutIsDamagedAndAClipErrorPassesThrough() async throws {
        struct Refused: Error {}
        let archive = PlannerFixtureArchive()
        try archive.add(PlannerFixtureFile())
        await #expect(throws: ClipError.damaged(at: Fixture.at(0))) { try await Fixture.planner(archive) { _ in throw Refused() }.plan(Fixture.request(0, 5_000)) }
        await #expect(throws: ClipError.sink("full")) { try await Fixture.planner(archive) { _ in throw ClipError.sink("full") }.plan(Fixture.request(0, 5_000)) }
    }

    @Test func aCallerThatHasAlreadyCancelledGetsCancelledAndNothingIsRead() async throws {
        let (planner, archive, _) = try Self.standard()
        let start = PlannerGate()
        let task = Task {
            await start.wait()
            return try await planner.plan(Fixture.request(0, 15_000))
        }
        task.cancel()
        start.open()
        await #expect(throws: ClipError.cancelled) { try await task.value }
        #expect(archive.reads.isEmpty)
    }

    @Test func aCancelBetweenReadsStopsTheWalkAtOnce() async throws {
        let (planner, archive, _) = try Self.standard()
        let gate = PlannerGate()
        archive.setHook { number, _, _ in if number == 3 { await gate.wait() } }
        let task = Task { try await planner.plan(Fixture.request(0, 15_000)) }
        #expect(await eventually(timeout: .seconds(30)) { archive.reads.count == 3 }, "the plan is in its third read")
        task.cancel()
        gate.open()
        await #expect(throws: ClipError.cancelled) { try await task.value }
        #expect(archive.reads.count == 3, "no read after the cancel")
    }

    @Test func theReadsRunAtUtilityPriorityWhoeverAsks() async throws {
        let (planner, archive, _) = try Self.standard()
        _ = try await planner.plan(Fixture.request(0, 15_000))
        #expect(archive.reads.count == 7 && archive.reads.allSatisfy { $0.priority == .utility }, "asked from a task of the test's own priority")
        let (other, otherArchive, _) = try Self.standard()
        _ = try await Task(priority: .userInitiated) { try await other.plan(Fixture.request(0, 15_000)) }.value
        #expect(otherArchive.reads.count == 7 && otherArchive.reads.allSatisfy { $0.priority == .utility }, "and from a task of a high one: the result is handed over, the task is not awaited")
    }
}
