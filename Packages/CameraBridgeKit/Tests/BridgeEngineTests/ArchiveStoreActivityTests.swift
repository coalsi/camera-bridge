import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// `ArchiveReading.activity` on a store: bins from rollups and from fragment tables, the live file, the typical level (Mac spec 7).
@Suite struct ArchiveStoreActivityTests {
    static let camera = ArchiveStoreHarness.camera
    static let start: Int64 = 1_760_101_200_000

    /// `files` sparse files of 360 fragments (15 minutes, 120 bytes a second) back to back from `start`.
    static func quarterHours(_ root: URL, files: Int, nonKeyBytes: UInt32 = 300, camera: UUID = ArchiveStoreActivityTests.camera, from: Int64 = start) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        for position in 0..<files {
            let startMs = from + Int64(position) * 900_000
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: ArchiveTime.date(ms: startMs))
            try ArchiveFixtureWriter.writeSparse(root: root, camera: camera, directory: camera.uuidString,
                                                 date: String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!),
                                                 baseName: String(format: "%02d-%02d-%02d", parts.hour!, parts.minute!, parts.second!), startMs: startMs,
                                                 fragmentCount: 360, nonKeyBytes: nonKeyBytes, writesManifest: position == 0)
        }
    }

    @Test func binsOfAMinuteOrMoreAreAddedUpFromTheRollups() async throws {
        let harness = try ArchiveStoreHarness { try Self.quarterHours($0, files: 2) }   // 30 minutes, 120 B/s
        await harness.start()
        let begin = ArchiveTime.date(ms: Self.start - 5 * 60_000)
        let activity = await harness.store.activity(camera: Self.camera, range: begin..<begin.addingTimeInterval(40 * 60), binCount: 8)   // 8 bins of 5 minutes
        #expect(activity.isComplete && activity.binDuration == 300 && activity.start == begin && activity.bins.count == 8)
        #expect(activity.bins.map(\.coverage) == [0, 1, 1, 1, 1, 1, 1, 0])
        #expect(activity.bins.map { $0.level.rounded() } == [0, 120, 120, 120, 120, 120, 120, 0])
        #expect(activity.typical == 120, "exactly 30 recorded minutes are enough")
    }

    @Test func theTypicalLevelNeedsHalfAnHourOfRecordedMinutes() async throws {
        let short = try ArchiveStoreHarness { try Self.quarterHours($0, files: 1) }   // 15 minutes
        await short.start()
        let range = ArchiveTime.date(ms: Self.start)..<ArchiveTime.date(ms: Self.start + 900_000)
        let one = await short.store.activity(camera: Self.camera, range: range, binCount: 15)
        #expect(one.typical == nil && one.bins.allSatisfy { $0.coverage == 1 })
        let long = try ArchiveStoreHarness { try Self.quarterHours($0, files: 4) }   // an hour
        await long.start()
        let hour = await long.store.activity(camera: Self.camera, range: ArchiveTime.date(ms: Self.start)..<ArchiveTime.date(ms: Self.start + 3_600_000), binCount: 60)
        #expect(hour.typical == 120, "the median of the recorded minutes")
        // The window is the 24 hours before the camera's newest video, not before now.
        long.clock.set(Date(timeIntervalSince1970: 1_800_000_000))
        let later = await long.store.activity(camera: Self.camera, range: ArchiveTime.date(ms: Self.start)..<ArchiveTime.date(ms: Self.start + 3_600_000), binCount: 60)
        #expect(later.typical == 120)
    }

    @Test func binsFinerThanAMinuteReadTheFragmentTables() async throws {
        let harness = try ArchiveStoreHarness { try Self.quarterHours($0, files: 1) }
        await harness.start()
        #expect(harness.store.state.withLock { $0.catalog.cachedTableCount } == 1, "the newest file's table was read at start")
        let begin = ArchiveTime.date(ms: Self.start + 10_000)
        let activity = await harness.store.activity(camera: Self.camera, range: begin..<begin.addingTimeInterval(20), binCount: 10)   // 2 s bins
        #expect(activity.binDuration == 2 && activity.bins.count == 10 && activity.isComplete)
        #expect(activity.bins.allSatisfy { $0.coverage == 1 && abs($0.level - 120) < 1e-9 && abs($0.peak - 120) < 1e-9 })
        #expect(activity.typical == nil)
        let after = ArchiveTime.date(ms: Self.start + 890_000)   // the last 10 s are recorded, the next 10 are not
        let edge = await harness.store.activity(camera: Self.camera, range: after..<after.addingTimeInterval(20), binCount: 10)
        #expect(edge.bins.map(\.coverage) == [1, 1, 1, 1, 1, 0, 0, 0, 0, 0])
    }

    @Test func theLaterFileWinsAnOverlapSoCoverageNeverExceedsOne() async throws {
        let harness = try ArchiveStoreHarness { root in
            try ArchiveFixtureWriter.writeSparse(root: root, camera: Self.camera, directory: Self.camera.uuidString, date: "2025-10-10", baseName: "13-00-00", startMs: Self.start,
                                                 fragmentCount: 48, nonKeyBytes: 300)   // 2 minutes
            try ArchiveFixtureWriter.writeSparse(root: root, camera: Self.camera, directory: Self.camera.uuidString, date: "2025-10-10", baseName: "13-01-00", startMs: Self.start + 60_000,
                                                 fragmentCount: 48, nonKeyBytes: 600, writesManifest: false)
        }
        await harness.start()
        let range = ArchiveTime.date(ms: Self.start)..<ArchiveTime.date(ms: Self.start + 180_000)
        let coarse = await harness.store.activity(camera: Self.camera, range: range, binCount: 3)
        #expect(coarse.bins.map(\.coverage) == [1, 1, 1] && coarse.bins.map { $0.level.rounded() } == [120, 240, 240], "from the second minute on the second file")
        let fine = await harness.store.activity(camera: Self.camera, range: range, binCount: 36)   // 5 s bins
        #expect(fine.bins.allSatisfy { $0.coverage <= 1 } && fine.bins.map { $0.level.rounded() } == Array(repeating: 120, count: 12) + Array(repeating: 240, count: 24))
    }

    @Test func aLongStretchAtFineBinsIsAnsweredFromTheRollupsSoNoMoreThanAFewTablesAreRead() async throws {
        let harness = try ArchiveStoreHarness { try Self.quarterHours($0, files: 40) }   // ten hours
        await harness.start()
        let tablesAtStart = harness.store.state.withLock { $0.catalog.cachedTableCount }
        let range = ArchiveTime.date(ms: Self.start)..<ArchiveTime.date(ms: Self.start + 36_000_000)
        let activity = await harness.store.activity(camera: Self.camera, range: range, binCount: 7_200)   // 5 s bins: finer than a minute
        #expect(activity.bins.count == 7_200 && activity.isComplete && activity.binDuration == 5)
        #expect(activity.bins.allSatisfy { $0.coverage == 1 && abs($0.level - 120) < 1e-9 })
        #expect(harness.store.state.withLock { $0.catalog.cachedTableCount } == tablesAtStart, "no table was read")
        // A short stretch at the same resolution reads its tables.
        let short = ArchiveTime.date(ms: Self.start + 100_000)..<ArchiveTime.date(ms: Self.start + 200_000)
        _ = await harness.store.activity(camera: Self.camera, range: short, binCount: 20)
        #expect(harness.store.state.withLock { $0.catalog.cachedTableCount } == tablesAtStart + 1)
    }

    @Test func theLiveFilesRollupsAreComputedFromWhatWasWritten() async throws {
        let harness = try ArchiveStoreHarness()
        await harness.start()
        let result = try harness.write(fragments: Array(repeating: ArchiveFixtureFragment(), count: 6), writesIndex: false)   // 15 s of 49 x 404 = 19,796 bytes per fragment
        let file = ArchiveOpenFile(camera: Self.camera, segment: result.file.segment)
        harness.store.recorderOpened(file, startWallMs: Self.start, initLength: result.index.initLength, hasAudio: false)
        for record in result.index.fragments.prefix(4) { harness.store.recorderWrote(file, record) }   // 10 s are written
        let range = ArchiveTime.date(ms: Self.start)..<ArchiveTime.date(ms: Self.start + 120_000)
        let live = await harness.store.activity(camera: Self.camera, range: range, binCount: 2)
        #expect(live.bins.map { ($0.coverage * 60).rounded() } == [10, 0], "10 s of the first minute")
        #expect(live.bins[0].level.rounded() == (19_796 / 2.5).rounded())
        // Closed, the sidecar's rollups say the same.
        for record in result.index.fragments.dropFirst(4) { harness.store.recorderWrote(file, record) }
        try result.index.encoded().write(to: result.sidecar)
        let beforeClose = await harness.store.activity(camera: Self.camera, range: range, binCount: 2)
        harness.store.recorderClosed(file, index: result.index)
        let closed = await harness.store.activity(camera: Self.camera, range: range, binCount: 2)
        #expect(closed == beforeClose && closed.bins[0].coverage == 0.25)
    }

    @Test func degenerateRequestsGetAnHonestAnswer() async throws {
        let harness = try ArchiveStoreHarness { try Self.quarterHours($0, files: 1) }
        await harness.start()
        let date = ArchiveTime.date(ms: Self.start)
        let empty = await harness.store.activity(camera: Self.camera, range: date..<date, binCount: 5)
        #expect(empty.bins.isEmpty && empty.isComplete)
        let none = await harness.store.activity(camera: Self.camera, range: date..<date.addingTimeInterval(60), binCount: 0)
        #expect(none.bins.isEmpty)
        let unknown = await harness.store.activity(camera: UUID(), range: date..<date.addingTimeInterval(600), binCount: 5)
        #expect(unknown.bins.count == 5 && unknown.bins.allSatisfy { $0.coverage == 0 } && unknown.typical == nil && unknown.isComplete)
        let before = await harness.store.activity(camera: Self.camera, range: date.addingTimeInterval(-7_200)..<date.addingTimeInterval(-3_600), binCount: 4)
        #expect(before.bins.allSatisfy { $0.coverage == 0 })
        let huge = await harness.store.activity(camera: Self.camera, range: date..<date.addingTimeInterval(1_000_000), binCount: 1_000_000)
        #expect(huge.bins.count == 20_000, "capped")
    }

    @Test func aWeekOfOneCameraAnswersFast() async throws {
        // 7 days x 96 files for one camera: 672 files of 15 minutes. 400 bins over the week come from the rollups, 1,440 bins over a day too.
        let harness = try ArchiveStoreHarness { try Self.quarterHours($0, files: 672) }
        await harness.start()
        let week = ArchiveTime.date(ms: Self.start)..<ArchiveTime.date(ms: Self.start + 7 * 86_400_000)
        let day = ArchiveTime.date(ms: Self.start + 86_400_000)..<ArchiveTime.date(ms: Self.start + 2 * 86_400_000)
        _ = await harness.store.activity(camera: Self.camera, range: week, binCount: 400)   // warm
        let clock = ContinuousClock()
        var weekly: ArchiveActivity?, daily: ArchiveActivity?
        let weekTime = await clock.measure { weekly = await harness.store.activity(camera: Self.camera, range: week, binCount: 400) }
        let dayTime = await clock.measure { daily = await harness.store.activity(camera: Self.camera, range: day, binCount: 1_440) }
        // Targets: 20 ms in an optimized build. The tests also run unoptimized on loaded machines; there the limit only catches a cost that grows
        // with the number of files instead of the number of bins.
        #if DEBUG
        let limit = Duration.seconds(5)
        #else
        let limit = Duration.milliseconds(20)
        #endif
        print("NVR timing: 400 bins over 7 days \(weekTime), 1,440 bins over a day \(dayTime)")   // printed so that the numbers are on record
        #expect(weekly?.bins.count == 400 && weekly?.bins.allSatisfy { $0.coverage > 0.99 } == true)
        #expect(daily?.bins.count == 1_440 && daily?.typical == 120)
        #expect(weekTime < limit && dayTime < limit, "week \(weekTime), day \(dayTime)")
    }
}
