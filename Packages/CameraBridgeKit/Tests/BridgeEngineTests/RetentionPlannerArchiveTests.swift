import Foundation
import Testing
@testable import BridgeEngine

/// Retention with an archive drive (archive-tier brief, part 2): the size rule moves the oldest files to the archive instead of deleting them, aged
/// files are still deleted, the archive keeps its own floor and cap, and without an archive the plan is exactly today's.
@Suite struct RetentionPlannerArchiveTests {
    static let now = RetentionPlannerTests.now
    static let day = RetentionPlannerTests.day
    static let mb: UInt64 = 1_000_000

    static func file(_ camera: Int, hoursAgo: Double, megabytes: UInt64 = 100, name: String = "") -> RetentionCandidate {
        RetentionPlannerTests.file(camera, hoursAgo: hoursAgo, megabytes: megabytes, name: name)
    }

    static func input(_ closed: [RetentionCandidate], open: UInt64 = 0, newestStart: Int64? = nil, keepDays: Int = 7, maximum: UInt64 = .max,
                      also archive: [RetentionCandidate] = []) -> RetentionPlanner.Input {
        RetentionPlanner.Input(closed: closed, openBytes: open, newestStartMs: newestStart ?? (closed + archive).map(\.startMs).max(), nowMs: now, keepDays: keepDays,
                               maximumBytes: maximum)
    }

    static func drive(_ closed: [RetentionCandidate] = [], maximum: UInt64 = 10_000 * mb, free: UInt64 = 10_000 * mb, floor: UInt64 = 100 * mb,
                      hard: UInt64 = .max, unmovable: Set<String> = []) -> RetentionPlanner.ArchiveInput {
        RetentionPlanner.ArchiveInput(closed: closed, maximumBytes: maximum, freeBytes: free, floorBytes: floor, unmovable: unmovable, mainHardMaximumBytes: hard)
    }

    @Test func withoutAnArchiveThePlanIsTodaysExactly() {
        var generator = ArchiveStoreGenerator(seed: 7)
        for _ in 0..<200 {
            let count = Int.random(in: 0..<30, using: &generator)
            let files = (0..<count).map { position in
                Self.file(position % 3, hoursAgo: Double.random(in: 0..<(24 * 12), using: &generator), megabytes: UInt64.random(in: 1...400, using: &generator),
                          name: "-\(position)")
            }
            let input = Self.input(files, open: UInt64.random(in: 0...500, using: &generator) * Self.mb, keepDays: Int.random(in: 1...10, using: &generator),
                                   maximum: UInt64.random(in: 0...5_000, using: &generator) * Self.mb)
            let tiered = RetentionPlanner.plan(input, archive: nil)
            #expect(tiered.deletions == RetentionPlanner.plan(input) && tiered.moves.isEmpty && tiered.archiveDeletions.isEmpty)
        }
    }

    @Test func theSizeRuleMovesTheOldestFilesAcrossCamerasInsteadOfDeletingThem() {
        let files = (0..<8).map { Self.file($0 % 3, hoursAgo: Double(8 - $0)) }
        let plan = RetentionPlanner.plan(Self.input(files.shuffled(), maximum: 450 * Self.mb), archive: Self.drive())
        #expect(plan.moves == Array(files.prefix(4)), "800 MB down to 400 MB: the four oldest move, oldest first, whatever camera")
        #expect(plan.deletions.isEmpty && plan.archiveDeletions.isEmpty)
        #expect(Set(plan.moves.map(\.camera)).count == 3)
    }

    @Test func agedFilesAreDeletedOnBothDrivesNotMoved() {
        let agedMain = Self.file(0, hoursAgo: 24 * 8)
        let youngMain = Self.file(1, hoursAgo: 2)
        let agedArchive = Self.file(2, hoursAgo: 24 * 9)
        let youngArchive = Self.file(0, hoursAgo: 24 * 6)
        let plan = RetentionPlanner.plan(Self.input([youngMain, agedMain], maximum: 50 * Self.mb, also: [agedArchive, youngArchive]),
                                         archive: Self.drive([youngArchive, agedArchive]))
        #expect(plan.deletions == [agedMain], "an aged file would only be deleted on the archive: it is deleted where it is")
        #expect(plan.archiveDeletions == [agedArchive], "the archive keeps the same number of days")
        #expect(plan.moves == [youngMain], "the young one over the size limit moves")
    }

    @Test func theClockGuardKeepsAgedFilesOnBothDrives() {
        let aged = Self.file(0, hoursAgo: 24 * 30)
        let agedArchive = Self.file(1, hoursAgo: 24 * 40)
        let future = Self.now + 3_600_000
        let plan = RetentionPlanner.plan(Self.input([aged], newestStart: future, also: [agedArchive]), archive: Self.drive([agedArchive]))
        #expect(plan.deletions.isEmpty && plan.archiveDeletions.isEmpty && plan.moves.isEmpty, "a clock that jumped deletes nothing for age, on either drive")
    }

    @Test func openFilesCountButAreNeverCandidates() {
        // 300 MB closed + 400 MB being written, under a 500 MB limit: 200 MB too many. Only closed files move, the oldest first.
        let closed = [Self.file(0, hoursAgo: 3), Self.file(1, hoursAgo: 2), Self.file(2, hoursAgo: 1)]
        let plan = RetentionPlanner.plan(Self.input(closed, open: 400 * Self.mb, maximum: 500 * Self.mb), archive: Self.drive())
        #expect(plan.moves == Array(closed.prefix(2)))
        // Even when only the open file is over the limit, nothing else can be planned for it than the closed ones.
        let alone = RetentionPlanner.plan(Self.input([], open: 900 * Self.mb, maximum: 500 * Self.mb), archive: Self.drive())
        #expect(alone == RetentionPlanner.TieredPlan())
    }

    @Test func movesStayAboveTheArchivesFloor() {
        // 1,000 MB free on the archive with a floor of 750 MB: room for two of the five 100 MB files that must leave the box.
        let files = (0..<6).map { Self.file($0 % 3, hoursAgo: Double(10 - $0)) }
        let plan = RetentionPlanner.plan(Self.input(files, maximum: 100 * Self.mb), archive: Self.drive(free: 1_000 * Self.mb, floor: 750 * Self.mb))
        #expect(plan.moves == Array(files[3..<5]), "the archive never goes under its floor; what it takes is the newest of what leaves")
        #expect(plan.deletions == Array(files.prefix(3)), "the oldest are deleted, as today: oldest first across both drives")
        // The archive's own deletions make room: what they free counts, and its own oldest file goes before anything newer.
        let old = Self.file(0, hoursAgo: 24 * 6, megabytes: 200)
        let roomier = RetentionPlanner.plan(Self.input(files, maximum: 100 * Self.mb), archive: Self.drive([old], maximum: 300 * Self.mb, free: 1_000 * Self.mb, floor: 750 * Self.mb))
        #expect(roomier.archiveDeletions == [old] && roomier.moves == Array(files[2..<5]) && roomier.deletions == Array(files.prefix(2)))
    }

    @Test func theFullArchiveDeletesItsOldestToTakeNewerFilesNeverNewerOnes() {
        // The archive holds 500 MB of its 500 MB cap; three main files must leave. Its oldest go to take them.
        let archived = (0..<5).map { Self.file($0 % 3, hoursAgo: 24 * 6 - Double($0)) }
        let main = (0..<5).map { Self.file($0 % 3, hoursAgo: 24 * 2 - Double($0)) }
        let plan = RetentionPlanner.plan(Self.input(main, maximum: 200 * Self.mb, also: archived), archive: Self.drive(archived.shuffled(), maximum: 500 * Self.mb))
        #expect(plan.moves == Array(main.prefix(3)))
        #expect(plan.archiveDeletions == Array(archived.prefix(3)), "oldest first, one for each file that comes in")
        #expect(plan.deletions.isEmpty)
        // An archive whose files are all newer than the oldest file of the box is not emptied for it: that file is the oldest recording, and goes as today.
        let newer = (0..<5).map { Self.file($0 % 3, hoursAgo: Double(5 - $0)) }
        let oldMain = [Self.file(0, hoursAgo: 24 * 3), Self.file(1, hoursAgo: 0.5)]
        let odd = RetentionPlanner.plan(Self.input(oldMain, maximum: 100 * Self.mb, also: newer), archive: Self.drive(newer, maximum: 500 * Self.mb))
        #expect(odd.archiveDeletions.isEmpty && odd.moves.isEmpty && odd.deletions == [oldMain[0]])
    }

    @Test func anArchiveOverItsOwnCapShrinksToIt() {
        let archived = (0..<6).map { Self.file($0 % 3, hoursAgo: 24 * 5 - Double($0)) }
        let plan = RetentionPlanner.plan(Self.input([Self.file(0, hoursAgo: 1)], also: archived), archive: Self.drive(archived, maximum: 350 * Self.mb))
        #expect(plan.archiveDeletions == Array(archived.prefix(3)) && plan.moves.isEmpty && plan.deletions.isEmpty)
    }

    @Test func aFileTheArchiveCanNeverHoldIsDeletedAsToday() {
        let big = Self.file(0, hoursAgo: 5, megabytes: 900)
        let small = Self.file(1, hoursAgo: 4, megabytes: 100)
        let plan = RetentionPlanner.plan(Self.input([big, small], maximum: 100 * Self.mb), archive: Self.drive(maximum: 500 * Self.mb))
        #expect(plan.deletions == [big] && plan.moves.isEmpty, "900 MB never fits a 500 MB archive; with it gone the box fits")
        let tiny = RetentionPlanner.plan(Self.input([big, small], maximum: 100 * Self.mb), archive: Self.drive(maximum: 0))
        #expect(tiny.deletions == [big] && tiny.moves.isEmpty, "an archive too small to hold anything changes nothing")
    }

    @Test func overTheHardLimitTheOldestAreDeletedEvenWithAnArchive() {
        // Moves that lag must never pause recording: over the box's hard limit the oldest go as today, the next ones over the soft limit move.
        let files = (0..<10).map { Self.file($0 % 3, hoursAgo: Double(10 - $0)) }
        let plan = RetentionPlanner.plan(Self.input(files, maximum: 500 * Self.mb), archive: Self.drive(hard: 800 * Self.mb))
        #expect(plan.deletions == Array(files.prefix(2)), "1,000 MB down to the 800 MB hard limit: deleted")
        #expect(plan.moves == Array(files[2..<5]), "800 MB down to the 500 MB limit: moved")
    }

    @Test func aFileThatCannotBeMovedIsDeletedAsToday() {
        let files = (0..<4).map { Self.file($0 % 3, hoursAgo: Double(4 - $0)) }
        let plan = RetentionPlanner.plan(Self.input(files, maximum: 200 * Self.mb), archive: Self.drive(unmovable: [files[0].segment]))
        #expect(plan.deletions == [files[0]] && plan.moves == [files[1]])
    }

    @Test func theHardLimitOfTheBoxIsAFloorAndAHalfBelowItsSize() {
        let status = ArchiveStorageStatus(totalBytes: 476 * Self.mb * 1_000, floorBytes: 24 * Self.mb * 1_000)
        #expect(status.hardMaximumBytes == 440 * Self.mb * 1_000)
        #expect(status.hardMaximumBytes > status.effectiveMaximumBytes(maxSizeGB: 10_000), "always above the soft limit")
        #expect(ArchiveStorageStatus(totalBytes: 10, floorBytes: 100).hardMaximumBytes == 0)
    }
}
