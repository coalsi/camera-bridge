import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// When the clock may age recordings out (`AgeRuleClock`; review of 2026-11-09, C1 and I1; rulings of 2026-11-11), on its own.
@Suite struct AgeRuleClockTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A clock that has been up for days and is synchronized, looked at once.
    static func settled() -> AgeRuleClock {
        var clock = AgeRuleClock()
        _ = clock.check(wall: start, monotonic: 1_000, uptime: 200_000, synchronized: true)
        return clock
    }

    @Test func aStepForwardOfMoreThanTenMinutesPausesTheAgeRuleForADayOfMonotonicTime() {
        var clock = Self.settled()
        #expect(clock.allowsAging)
        // Ten minutes exactly is not a jump; a second more is.
        #expect(clock.check(wall: Self.start.addingTimeInterval(600), monotonic: 1_000, uptime: 200_000, synchronized: true).isEmpty)
        #expect(clock.allowsAging)
        let changes = clock.check(wall: Self.start.addingTimeInterval(1_201), monotonic: 1_000, uptime: 200_000, synchronized: true)
        #expect(changes == [.pauseStarted(jump: 601, until: Self.start.addingTimeInterval(1_201 + 86_400))])
        #expect(!clock.allowsAging && clock.pause == ArchiveAgeRulePause(reason: .clockJumped, until: Self.start.addingTimeInterval(1_201 + 86_400)))
        // A day of the monotonic clock, whatever the wall clock does meanwhile (here: nothing more).
        let later = { (seconds: TimeInterval) in Self.start.addingTimeInterval(1_201 + seconds) }
        #expect(clock.check(wall: later(86_399), monotonic: 1_000 + 86_399, uptime: 200_000, synchronized: true).isEmpty)
        #expect(!clock.allowsAging)
        #expect(clock.check(wall: later(86_400), monotonic: 1_000 + 86_400, uptime: 200_000, synchronized: true) == [.pauseEnded])
        #expect(clock.allowsAging && clock.pause == nil)
    }

    @Test func aSecondJumpDuringThePauseStartsTheDayAgainAndIsNotSaidTwice() {
        var clock = Self.settled()
        _ = clock.check(wall: Self.start.addingTimeInterval(3_600), monotonic: 1_000, uptime: 200_000, synchronized: true)
        let second = clock.check(wall: Self.start.addingTimeInterval(3_600 + 43_200 + 7_200), monotonic: 1_000 + 43_200, uptime: 200_000, synchronized: true)
        #expect(second.isEmpty, "the pause goes on; it was said when it started")
        #expect(clock.check(wall: Self.start.addingTimeInterval(3_600 + 86_400 + 7_200), monotonic: 1_000 + 86_400, uptime: 200_000, synchronized: true).isEmpty,
                "a day after the first jump, but not after the second")
        #expect(!clock.allowsAging)
        #expect(clock.check(wall: Self.start.addingTimeInterval(3_600 + 43_200 + 86_400 + 7_200), monotonic: 1_000 + 43_200 + 86_400, uptime: 200_000,
                            synchronized: true) == [.pauseEnded])
    }

    @Test func aStepBackNeverPausesAndTimePassingIsNoJump() {
        var clock = Self.settled()
        #expect(clock.check(wall: Self.start.addingTimeInterval(-7 * 86_400), monotonic: 1_000, uptime: 200_000, synchronized: true).isEmpty)
        #expect(clock.allowsAging)
        // A month passes on both clocks: no jump.
        #expect(clock.check(wall: Self.start.addingTimeInterval(-7 * 86_400 + 30 * 86_400), monotonic: 1_000 + 30 * 86_400, uptime: 200_000,
                            synchronized: true).isEmpty)
        #expect(clock.allowsAging)
        // The first look of all has nothing to compare with.
        var fresh = AgeRuleClock()
        #expect(fresh.check(wall: Self.start, monotonic: 0, uptime: 200_000, synchronized: true).isEmpty && fresh.allowsAging)
    }

    @Test func anUnsynchronizedClockWaitsUntilADayOfUptimeOrUntilItIsSynchronized() {
        var clock = AgeRuleClock()
        #expect(clock.needsSynchronization(uptime: 3_600))
        #expect(clock.check(wall: Self.start, monotonic: 0, uptime: 3_600, synchronized: false) == [.waitStarted(until: Self.start.addingTimeInterval(82_800))])
        #expect(!clock.allowsAging && clock.pause == ArchiveAgeRulePause(reason: .clockNotSynchronized, until: Self.start.addingTimeInterval(82_800)))
        #expect(clock.check(wall: Self.start.addingTimeInterval(60), monotonic: 60, uptime: 3_660, synchronized: false).isEmpty, "said once")
        #expect(clock.check(wall: Self.start.addingTimeInterval(82_800), monotonic: 82_800, uptime: 86_400, synchronized: false) == [.waitEnded(synchronized: false)])
        #expect(clock.allowsAging && clock.pause == nil && !clock.needsSynchronization(uptime: 86_400))

        var synced = AgeRuleClock()
        _ = synced.check(wall: Self.start, monotonic: 0, uptime: 60, synchronized: false)
        #expect(synced.check(wall: Self.start.addingTimeInterval(120), monotonic: 120, uptime: 180, synchronized: true) == [.waitEnded(synchronized: true)])
        #expect(synced.allowsAging)
        // Once known, the clock is not asked again: a later "not synchronized" (the internet went away) changes nothing.
        #expect(!synced.needsSynchronization(uptime: 240))
        #expect(synced.check(wall: Self.start.addingTimeInterval(180), monotonic: 180, uptime: 240, synchronized: false).isEmpty && synced.allowsAging)
    }

    @Test func aJumpWhileWaitingIsSeenAndThePauseIsWhatTheStatusShows() {
        var clock = AgeRuleClock()
        _ = clock.check(wall: Self.start, monotonic: 0, uptime: 60, synchronized: false)
        // chrony's first answer sets the clock a year ahead (a wrong RTC behind it) and says it is synchronized.
        let changes = clock.check(wall: Self.start.addingTimeInterval(365 * 86_400 + 30), monotonic: 30, uptime: 90, synchronized: true)
        #expect(changes.count == 2 && changes.contains(.waitEnded(synchronized: true)))
        #expect(!clock.allowsAging && clock.pause?.reason == .clockJumped)
    }
}

/// The age rule on a real folder, with the store's clocks injected: a forward jump pauses it, a jump back deletes nothing extra, an unsynchronized
/// clock waits for a day of uptime, a file dated in the future no longer stops the others, and the size rule runs throughout.
@Suite struct ArchiveStoreClockTests {
    typealias Written = ArchiveStoreRetentionTests.Written
    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400

    static func sparse(_ root: URL, _ camera: UUID, hoursAgo: Double, manifest: Bool = false) throws -> Written {
        try ArchiveStoreRetentionTests.sparse(root, camera: camera, hoursAgo: hoursAgo, manifest: manifest)
    }

    static func exists(_ file: Written?) -> Bool { file.map { ArchiveStoreRetentionTests.exists($0.mp4) } ?? false }

    /// What the store logs, kept.
    static func collecting(_ lines: Box<[String]>) -> ArchiveStoreLog {
        ArchiveStoreLog { _, message in lines.update { $0.append(message) } }
    }

    @Test func aForwardJumpOfAnHourPausesTheAgeRuleForADay() async throws {
        let camera = UUID()
        let lines = Box<[String]>([])
        var nearlyOld: Written?, young: Written?
        let harness = try ArchiveStoreHarness(log: Self.collecting(lines)) { root in
            nearlyOld = try Self.sparse(root, camera, hoursAgo: 24 * 7 - 0.5, manifest: true)   // half an hour inside the keep time
            young = try Self.sparse(root, camera, hoursAgo: 2)
        }
        await harness.start()
        await harness.store.runRetention(harness.run)
        #expect(Self.exists(nearlyOld) && Self.exists(young))
        harness.stepClock(by: Self.hour)   // now every file looks half an hour older than the keep time
        await harness.store.runRetention(harness.run)
        await harness.store.pruneEvents(harness.run)
        #expect(Self.exists(nearlyOld), "a clock that jumped forward deletes nothing for its age")
        #expect(harness.store.storageStatus?.ageRulePause == ArchiveAgeRulePause(reason: .clockJumped, until: Date(timeIntervalSince1970: (harness.clock.value.timeIntervalSince1970 + Self.day).rounded(.down))))
        #expect(lines.value.filter { $0.contains("jumped") }.count == 1, "the pause is said once: \(lines.value)")
        harness.advance(by: 23 * Self.hour)
        await harness.store.runRetention(harness.run)
        #expect(Self.exists(nearlyOld), "23 hours on, the pause holds")
        harness.advance(by: Self.hour)
        await harness.store.runRetention(harness.run)
        #expect(!Self.exists(nearlyOld) && Self.exists(young), "a day of uptime after the jump, the age rule runs on the clock it has")
        #expect(harness.store.storageStatus?.ageRulePause == nil)
        #expect(lines.value.filter { $0.contains("jumped") }.count == 2, "and its end once: \(lines.value)")
    }

    @Test func aBackwardJumpDeletesNothingExtra() async throws {
        let camera = UUID()
        var old: Written?, aged: Written?, young: Written?
        let harness = try ArchiveStoreHarness { root in
            old = try Self.sparse(root, camera, hoursAgo: 24 * 10, manifest: true)
            aged = try Self.sparse(root, camera, hoursAgo: 24 * 8)
            young = try Self.sparse(root, camera, hoursAgo: 24 * 6)
        }
        await harness.start()
        harness.stepClock(by: -2 * Self.day)
        await harness.store.runRetention(harness.run)
        #expect(!Self.exists(old), "older than the keep time by the earlier clock too")
        #expect(Self.exists(aged) && Self.exists(young), "the earlier clock ages out less, never more")
        #expect(harness.store.storageStatus?.ageRulePause == nil, "a jump back pauses nothing")
    }

    @Test func anUnsynchronizedClockSkipsTheAgeRuleUntilADayOfUptime() async throws {
        let camera = UUID()
        var aged: Written?, young: Written?
        let harness = try ArchiveStoreHarness(uptime: Self.hour, synchronized: false) { root in
            aged = try Self.sparse(root, camera, hoursAgo: 24 * 8, manifest: true)
            young = try Self.sparse(root, camera, hoursAgo: 2)
        }
        await harness.start()
        await harness.store.runRetention(harness.run)
        #expect(Self.exists(aged), "the system never said its clock is right, and has run for an hour")
        let pause = try #require(harness.store.storageStatus?.ageRulePause)
        #expect(pause.reason == .clockNotSynchronized && pause.until == ArchiveStoreHarness.now.addingTimeInterval(23 * Self.hour))
        harness.advance(by: 22 * Self.hour)
        await harness.store.runRetention(harness.run)
        #expect(Self.exists(aged))
        harness.advance(by: Self.hour)
        await harness.store.runRetention(harness.run)
        #expect(!Self.exists(aged) && Self.exists(young), "after a day of uptime it runs on the clock it has")
        #expect(harness.store.storageStatus?.ageRulePause == nil)
    }

    @Test func aClockThatIsSynchronizedEndsTheWaitAtOnce() async throws {
        let camera = UUID()
        var aged: Written?
        let harness = try ArchiveStoreHarness(uptime: 60, synchronized: false) { root in
            aged = try Self.sparse(root, camera, hoursAgo: 24 * 8, manifest: true)
        }
        await harness.start()
        await harness.store.runRetention(harness.run)
        #expect(Self.exists(aged))
        harness.synchronized.set(true)
        await harness.store.runRetention(harness.run)
        #expect(!Self.exists(aged))
    }

    @Test func oneFileDatedInTheFutureNoLongerStopsTheOthersFromAging() async throws {
        let camera = UUID()
        var aged: Written?, future: Written?, young: Written?
        let harness = try ArchiveStoreHarness { root in
            aged = try Self.sparse(root, camera, hoursAgo: 24 * 8, manifest: true)
            future = try Self.sparse(root, camera, hoursAgo: -24 * 30)   // recorded while the clock was a month ahead
            young = try Self.sparse(root, camera, hoursAgo: 2)
        }
        await harness.start()
        await harness.store.runRetention(harness.run)
        #expect(!Self.exists(aged), "the keep time holds for every other file")
        #expect(Self.exists(future) && Self.exists(young), "the future file is not aged until its time comes")
        #expect(harness.store.storageStatus?.ageRulePause == nil)
    }

    /// While the age rule is paused the size rule goes on, oldest first, files past the keep time included: what it takes goes by size, so the event
    /// days before it go with it, and the event days only the age rule would take wait for the pause to end.
    @Test func theSizeRuleStillDeletesWhileTheAgeRuleIsPaused() async throws {
        let camera = UUID()
        var aged: [Written] = [], young: [Written] = []
        let harness = try ArchiveStoreHarness { root in
            // Two files past the 7-day keep time and 24 inside it, 400 MB each: two files over a 10 GB limit.
            aged.append(try Self.sparse(root, camera, hoursAgo: 24 * 9, manifest: true))
            aged.append(try Self.sparse(root, camera, hoursAgo: 24 * 8.5))
            for position in 0..<24 { young.append(try Self.sparse(root, camera, hoursAgo: Double(48 - position * 2))) }
        }
        await harness.start(harness.settings(maxSizeGB: 10))
        let nowMs = ArchiveStoreRetentionTests.nowMs
        // Events (one file per UTC day) before the second aged file, after it but past the keep time, and of today.
        let events = [nowMs - 10 * 86_400_000, nowMs - 8 * 86_400_000 - 2 * 3_600_000, nowMs - 3_600_000]
        for time in events { harness.store.recordEvents([ArchiveEventLogTests.edge("Motion", time, camera: camera)], video: { _ in true }) }
        await harness.store.eventLog.flush()
        let dayFiles = {
            ((try? FileManager.default.contentsOfDirectory(atPath: harness.root.url.appending(path: ".events/\(camera.uuidString)").path(percentEncoded: false))) ?? []).sorted()
        }
        let days = events.map { ArchiveEventLog.dayName(ms: $0) + ".jsonl" }
        #expect(dayFiles() == days)

        harness.stepClock(by: 2 * Self.hour)
        await harness.store.runRetention(harness.run)
        #expect(harness.store.storageStatus?.ageRulePause?.reason == .clockJumped)
        let gone = (aged + young).filter { !Self.exists($0) }
        #expect(Set(gone.map(\.segment)) == Set(aged.map(\.segment)), "over 10 GB: the two oldest go, by size, as ever")
        #expect(harness.store.state.withLock { $0.eventSizeCutoffMs } == aged[1].startMs, "they went by size, so their days' events go with them")
        await harness.store.pruneEvents(harness.run)
        #expect(dayFiles() == Array(days.dropFirst()), "the day before them goes; the day past the keep time after them waits: \(dayFiles())")
        harness.advance(by: Self.day)
        await harness.store.pruneEvents(harness.run)
        #expect(dayFiles() == [days[2]], "the pause over, the age rule takes it")
    }

    @Test func cameraEventsAndSkyWatcherNightsWaitWithTheRecordings() async throws {
        let camera = UUID()
        let harness = try ArchiveStoreHarness { root in _ = try Self.sparse(root, camera, hoursAgo: 2, manifest: true) }
        await harness.start()
        let nowMs = ArchiveStoreRetentionTests.nowMs
        harness.store.recordEvents([ArchiveEventLogTests.edge("Motion", nowMs - 7 * 86_400_000 + 6 * 3_600_000, camera: camera)], video: { _ in true })
        await harness.store.eventLog.flush()
        let dayFiles = {
            (try? FileManager.default.contentsOfDirectory(atPath: harness.root.url.appending(path: ".events/\(camera.uuidString)").path(percentEncoded: false))) ?? []
        }
        // A Sky Watcher night of eight days ago (it lasts into the next morning, so it goes once the day after that is over by the cutoff).
        let night = SkyLogStore.nightFile(folder: harness.root.url, camera: camera, night: ArchiveEventLog.dayName(ms: nowMs - 8 * 86_400_000))
        try FileManager.default.createDirectory(at: night.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: night)
        let nightKept = { FileManager.default.fileExists(atPath: night.path(percentEncoded: false)) }
        #expect(dayFiles().count == 1 && nightKept())
        harness.stepClock(by: 2 * Self.day)   // the event's day and the night now look past the keep time
        await harness.store.pruneEvents(harness.run)
        #expect(dayFiles().count == 1, "a clock that jumped deletes no events")
        #expect(nightKept(), "and no Sky Watcher nights")
        harness.advance(by: Self.day)
        await harness.store.pruneEvents(harness.run)
        #expect(dayFiles().isEmpty && !nightKept(), "a day later they go by the clock it has")
    }

    /// A flat clock battery after a power cut: the box comes up on its last saved time, then chrony steps the clock forward and says it is
    /// synchronized, both seen at one look. The jump's pause holds, and the log says what is true.
    @Test func aJumpAndTheFirstSyncAtOneLookLogThatThePauseHolds() async throws {
        let camera = UUID()
        let lines = Box<[String]>([])
        var nearlyOld: Written?
        let harness = try ArchiveStoreHarness(uptime: 60, synchronized: false, log: Self.collecting(lines)) { root in
            nearlyOld = try Self.sparse(root, camera, hoursAgo: 24 * 7 - 0.5, manifest: true)
        }
        await harness.start()
        harness.stepClock(by: Self.hour)
        harness.synchronized.set(true)
        await harness.store.runRetention(harness.run)
        #expect(Self.exists(nearlyOld), "the jump's pause holds")
        #expect(harness.store.storageStatus?.ageRulePause?.reason == .clockJumped)
        #expect(lines.value.contains { $0.hasPrefix("The clock is synchronized, but the 24-hour pause") }, "\(lines.value)")
        #expect(!lines.value.contains { $0.contains("deleted for their age again") }, "nothing says the age rule runs while it does not: \(lines.value)")
        harness.advance(by: Self.day)
        await harness.store.runRetention(harness.run)
        #expect(!Self.exists(nearlyOld))
        #expect(lines.value.contains("24 hours have passed since the clock jumped: recordings are deleted for their age again"), "\(lines.value)")
    }
}
