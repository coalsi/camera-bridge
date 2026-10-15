import Foundation
import Testing
@testable import BridgeEngine

/// Which files retention deletes (Mac spec 6 and the Linux changes): pure, from the archive's own bytes only.
@Suite struct RetentionPlannerTests {
    static let day: Int64 = 86_400_000
    static let now: Int64 = 1_760_100_000_000
    static let cameras = [UUID(), UUID(), UUID()]

    /// A closed file of `megabytes` that started `hoursAgo` hours before `now` and lasted 15 minutes.
    static func file(_ camera: Int, hoursAgo: Double, megabytes: UInt64 = 100, name: String = "") -> RetentionCandidate {
        let start = now - Int64(hoursAgo * 3_600_000)
        return RetentionCandidate(camera: cameras[camera], segment: "\(cameras[camera].uuidString)/\(Int(hoursAgo * 60))\(name)", startMs: start, endMs: start + 900_000,
                                  bytes: megabytes * 1_000_000)
    }

    static func plan(_ closed: [RetentionCandidate], open: UInt64 = 0, newestStart: Int64? = nil, keepDays: Int = 7, maximum: UInt64 = .max, now: Int64 = RetentionPlannerTests.now)
        -> [RetentionCandidate] {
        RetentionPlanner.plan(.init(closed: closed, openBytes: open, newestStartMs: newestStart ?? closed.map(\.startMs).max(), nowMs: now, keepDays: keepDays, maximumBytes: maximum))
    }

    @Test func nothingToDeleteWhenEverythingIsYoungAndFits() {
        let files = (0..<10).map { Self.file($0 % 3, hoursAgo: Double($0) * 5 + 1) }
        #expect(Self.plan(files, maximum: 10 * 100_000_000).isEmpty, "exactly at the maximum fits")
        #expect(Self.plan([], maximum: 0).isEmpty)
    }

    @Test func filesThatEndedBeforeTheKeepTimeAreDeletedOldestFirst() {
        let old = Self.file(0, hoursAgo: 24 * 8)            // 8 days old
        let older = Self.file(1, hoursAgo: 24 * 30)
        let young = Self.file(2, hoursAgo: 24 * 6)
        #expect(Self.plan([young, old, older]) == [older, old])
        #expect(Self.plan([young, old, older], keepDays: 30) == [], "the keep time is a setting: 30 days keeps the 30-day-old file (its end is newer)")
        #expect(Self.plan([young, old, older], keepDays: 365).isEmpty)
        // The boundary: a file whose end is exactly the cutoff stays; one millisecond older goes.
        let cutoff = Self.now - 7 * Self.day
        let edge = RetentionCandidate(camera: Self.cameras[0], segment: "edge", startMs: cutoff - 900_000, endMs: cutoff, bytes: 1)
        var before = edge
        before.segment = "before"
        before.endMs = cutoff - 1
        #expect(Self.plan([edge, before]) == [before])
    }

    @Test func theSizeRuleDeletesTheOldestStartsAcrossAllCameras() {
        // Eight files of 100 MB from three cameras, interleaved in time; the archive may hold 450 MB.
        let files = (0..<8).map { Self.file($0 % 3, hoursAgo: Double(8 - $0), megabytes: 100) }
        let plan = Self.plan(files.shuffled(), maximum: 450_000_000)
        #expect(plan == Array(files.prefix(4)), "four files go: 800 MB down to 400 MB, oldest first whatever camera they are from")
        #expect(Set(plan.map(\.camera)).count == 3)
    }

    @Test func filesDeletedForTheirAgeCountTowardTheSizeSoNothingIsDeletedTwice() {
        let aged = [Self.file(0, hoursAgo: 24 * 9, megabytes: 300), Self.file(1, hoursAgo: 24 * 8, megabytes: 300)]
        let young = [Self.file(0, hoursAgo: 5, megabytes: 200), Self.file(1, hoursAgo: 3, megabytes: 200)]
        // 1,000 MB in all; the aged 600 MB go; the remaining 400 MB fit a 400 MB maximum, so the young stay.
        #expect(Self.plan(young + aged, maximum: 400_000_000) == aged)
        // With a 250 MB maximum the oldest young file goes too.
        #expect(Self.plan(young + aged, maximum: 250_000_000) == aged + [young[0]])
    }

    @Test func openFilesCountButAreNeverDeleted() {
        let files = [Self.file(0, hoursAgo: 3, megabytes: 100), Self.file(1, hoursAgo: 2, megabytes: 100)]
        #expect(Self.plan(files, open: 150_000_000, maximum: 300_000_000) == [files[0]], "350 MB with the open files: one closed file must go")
        #expect(Self.plan(files, open: 900_000_000, maximum: 300_000_000) == files, "everything that can be deleted goes; the open files stay")
    }

    @Test func aMaximumOfZeroDeletesEveryClosedFile() {
        let files = (0..<5).map { Self.file(0, hoursAgo: Double($0 + 1)) }
        #expect(Set(Self.plan(files, maximum: 0).map(\.segment)) == Set(files.map(\.segment)))
    }

    @Test func theEffectiveMaximumIsTheSmallerOfTheSettingAndWhatTheDriveCanHold() {
        let gib = ArchiveConstants.resumeMarginBytes
        // A 128 GB data partition with the box's floor (8 GiB): it can hold 128e9 - 2 x 8 GiB = 110.8e9 bytes, whatever the setting says.
        let status = ArchiveStorageStatus(totalBytes: 128_000_000_000, floorBytes: 8 * gib)
        #expect(status.effectiveMaximumBytes(maxSizeGB: 500) == 128_000_000_000 - 16 * gib)
        #expect(status.effectiveMaximumBytes(maxSizeGB: 50) == 50_000_000_000)
        let files = (0..<130).map { Self.file(0, hoursAgo: Double(130 - $0), megabytes: 1_000) }   // 130 GB
        let plan = Self.plan(files, maximum: status.effectiveMaximumBytes(maxSizeGB: 500))
        #expect(plan == Array(files.prefix(20)), "19 files would leave 111 GB, still over 110.8 GB: 20 go")
    }

    @Test func aClockThatJumpedForwardNeverAgesAnythingOut() {
        let old = Self.file(0, hoursAgo: 24 * 30)
        let young = Self.file(1, hoursAgo: 1)
        let future = Self.now + 10 * 60_000   // the newest file starts 10 minutes ahead
        #expect(Self.plan([old, young], newestStart: future).isEmpty, "the age rule waits until the clock agrees again")
        #expect(Self.plan([old, young], newestStart: Self.now + 4 * 60_000) == [old], "4 minutes ahead is normal drift")
        #expect(Self.plan([old, young], newestStart: future, maximum: 150_000_000) == [old], "the size rule does not use the clock")
    }

    @Test func filesThatStartTogetherAreOrderedByTheirNames() {
        let first = Self.file(0, hoursAgo: 2, name: "a"), second = Self.file(1, hoursAgo: 2, name: "b")
        #expect(first.startMs == second.startMs)
        let ordered = [first, second].sorted { $0.segment < $1.segment }
        #expect(Self.plan([ordered[1], ordered[0]], maximum: 100_000_000) == [ordered[0]], "the same answer whatever order they come in")
        #expect(Self.plan([ordered[0], ordered[1]], maximum: 100_000_000) == [ordered[0]])
    }

    @Test func randomArchivesFollowTheRules() {
        var generator = ArchiveStoreGenerator(seed: 0xA11CE)
        for round in 0..<300 {
            let count = Int.random(in: 0...40, using: &generator)
            let files = (0..<count).map { number in
                RetentionCandidate(camera: Self.cameras[Int.random(in: 0..<3, using: &generator)], segment: "f\(round)-\(number)",
                                   startMs: Self.now - Int64.random(in: 0...(20 * Self.day), using: &generator), endMs: 0,
                                   bytes: UInt64.random(in: 1...900, using: &generator) * 1_000_000)
            }.map { file -> RetentionCandidate in var file = file; file.endMs = file.startMs + 900_000; return file }
            let open = UInt64.random(in: 0...2, using: &generator) * 500_000_000
            let maximum = UInt64.random(in: 0...20_000, using: &generator) * 1_000_000
            let keepDays = Int.random(in: 1...20, using: &generator)
            let plan = Self.plan(files, open: open, keepDays: keepDays, maximum: maximum)
            // Only candidates, each once.
            #expect(Set(plan.map(\.segment)).count == plan.count && Set(plan.map(\.segment)).isSubset(of: Set(files.map(\.segment))))
            // After the deletions the archive fits, or nothing but open files is left.
            let kept = files.filter { file in !plan.contains { $0.segment == file.segment } }
            let used = kept.reduce(open) { $0 + $1.bytes }
            #expect(used <= maximum || kept.isEmpty, "round \(round): \(used) bytes kept of at most \(maximum)")
            // Everything aged is gone; whatever else went is an oldest-first run.
            let cutoff = Self.now - Int64(keepDays) * Self.day
            #expect(!kept.contains { $0.endMs < cutoff })
            let others = plan.filter { $0.endMs >= cutoff }
            let youngest = files.filter { $0.endMs >= cutoff }.sorted { ($0.startMs, $0.segment) < ($1.startMs, $1.segment) }
            #expect(others.map(\.segment) == youngest.prefix(others.count).map(\.segment), "round \(round): the size rule takes the oldest first")
            // A bigger maximum never deletes more; a longer keep time never deletes more.
            let more = Set(Self.plan(files, open: open, keepDays: keepDays, maximum: maximum + 1_000_000_000).map(\.segment))
            #expect(more.isSubset(of: Set(plan.map(\.segment))))
            let aged = Set(Self.plan(files, open: open, keepDays: keepDays, maximum: .max).map(\.segment))
            let agedLonger = Set(Self.plan(files, open: open, keepDays: keepDays + 5, maximum: .max).map(\.segment))
            #expect(agedLonger.isSubset(of: aged), "a longer keep time ages out fewer files")
            if maximum >= files.reduce(open, { $0 + $1.bytes }) { #expect(Set(plan.map(\.segment)) == Set(files.filter { $0.endMs < cutoff }.map(\.segment))) }
        }
    }
}
