import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// "Keep this": a kept stretch is never deleted by retention (its bytes still count, so newer files make room for it), keeps its event days,
/// survives a restart, may take at most a quarter of the box's limit, and goes back to retention when it is let go.
@Suite struct KeptRecordingsTests {
    typealias Written = ArchiveStoreRetentionTests.Written
    static let day = ArchiveStoreRetentionTests.day

    static func exists(_ url: URL) -> Bool { ArchiveStoreRetentionTests.exists(url) }

    /// 30 files of 400 MB (12 GB) across three cameras, two hours apart, under a 10 GB limit.
    static func harness() throws -> (ArchiveStoreHarness, [Written], [UUID]) {
        let cameras = [UUID(), UUID(), UUID()]
        var files: [Written] = []
        let harness = try ArchiveStoreHarness { root in
            for position in 0..<30 {
                files.append(try ArchiveStoreRetentionTests.sparse(root, camera: cameras[position % 3], hoursAgo: Double(60 - position * 2), manifest: position < 3))
            }
        }
        return (harness, files, cameras)
    }

    @Test func aKeptStretchSurvivesTheSizeRuleAndNewerFilesMakeRoomForIt() async throws {
        let (harness, files, _) = try Self.harness()
        await harness.start(harness.settings(maxSizeGB: 10))
        let oldest = files[0]
        let kept = try await harness.store.keep(camera: oldest.camera, start: ArchiveTime.date(ms: oldest.startMs + 1_000),
                                                end: ArchiveTime.date(ms: oldest.startMs + 2_000), note: "  the parcel  ")
        #expect(kept.kept.note == "the parcel" && kept.bytes == oldest.bytes && kept.hasVideo)
        await harness.store.runRetention(harness.run)
        #expect(Self.exists(oldest.mp4) && Self.exists(oldest.sidecar), "kept")
        let total = files.reduce(0) { $0 + $1.bytes }
        let left = files.filter { Self.exists($0.mp4) }.reduce(0) { $0 + $1.bytes }
        #expect(left <= 10 * ArchiveStoreHarness.gb && left > 10 * ArchiveStoreHarness.gb - files[1].bytes, "still within the limit: \(left) of \(total)")
        #expect(files[1...6].allSatisfy { !Self.exists($0.mp4) } && Self.exists(files[7].mp4), "the next oldest went in its place")
        // Let go: a later pass takes it like any other (here, the keep time passing).
        try await harness.store.forgetKept(id: kept.kept.id)
        harness.clock.set(ArchiveStoreHarness.now.addingTimeInterval(10 * 86_400))
        await harness.store.runRetention(harness.run)
        #expect(!Self.exists(oldest.mp4))
        #expect(await harness.store.keptRecordings().isEmpty)
    }

    @Test func aKeptStretchIsReadBackAfterARestartAndKeepsItsEventDay() async throws {
        let (harness, files, _) = try Self.harness()
        await harness.start(harness.settings(maxSizeGB: 40))
        let oldest = files[0]
        _ = try await harness.store.keep(camera: oldest.camera, start: ArchiveTime.date(ms: oldest.startMs), end: ArchiveTime.date(ms: oldest.startMs + 60_000), note: "")
        // An event day of the kept camera and one of another camera, both older than the keep time once the clock moves on.
        let dayName = ArchiveEventLog.dayName(ms: oldest.startMs)
        for camera in [oldest.camera, files[1].camera] {
            let url = ArchiveEventLog.dayFile(folder: harness.root.url, camera: camera, day: dayName)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: url)
        }
        harness.clock.set(ArchiveStoreHarness.now.addingTimeInterval(30 * 86_400))
        harness.store.shutDown()
        // A restart: another store over the same folder reads it back from .kept.json.
        let restarted = harness.makeStore()
        defer { restarted.shutDown() }
        restarted.start(settings: harness.settings(maxSizeGB: 40))
        #expect(await eventually(timeout: archiveStorePatience) { restarted.isSettled })
        #expect(await restarted.keptRecordings().count == 1)
        await restarted.runRetention(restarted.currentRun)
        await restarted.pruneEvents(restarted.currentRun)
        #expect(Self.exists(oldest.mp4), "past the keep time too")
        #expect(files.dropFirst().allSatisfy { !Self.exists($0.mp4) }, "everything else aged out")
        #expect(Self.exists(ArchiveEventLog.dayFile(folder: harness.root.url, camera: oldest.camera, day: dayName)), "its event day stays")
        #expect(!Self.exists(ArchiveEventLog.dayFile(folder: harness.root.url, camera: files[1].camera, day: dayName)), "another camera's goes")
    }

    @Test func whatCannotBeKeptIsRefusedWithASentence() async throws {
        let (harness, files, cameras) = try Self.harness()
        await harness.start(harness.settings(maxSizeGB: 10))
        let start = ArchiveTime.date(ms: files[0].startMs)
        await #expect(throws: KeptRecordingError.badRange) { try await harness.store.keep(camera: cameras[0], start: start, end: start, note: "") }
        await #expect(throws: KeptRecordingError.tooLong) {
            try await harness.store.keep(camera: cameras[0], start: start, end: start.addingTimeInterval(25 * 3_600), note: "")
        }
        await #expect(throws: KeptRecordingError.nothingRecorded) {
            try await harness.store.keep(camera: UUID(), start: start, end: start.addingTimeInterval(60), note: "")
        }
        // A quarter of 10 GB is 2.5 GB: six 400 MB files fit, the seventh does not.
        let spans = files.suffix(14)
        for file in spans.prefix(6) {
            _ = try await harness.store.keep(camera: file.camera, start: ArchiveTime.date(ms: file.startMs), end: ArchiveTime.date(ms: file.startMs + 1), note: "")
        }
        let seventh = spans.dropFirst(6).first!
        await #expect(throws: KeptRecordingError.noRoom) {
            try await harness.store.keep(camera: seventh.camera, start: ArchiveTime.date(ms: seventh.startMs), end: ArchiveTime.date(ms: seventh.startMs + 1), note: "")
        }
        await #expect(throws: KeptRecordingError.unknown) { try await harness.store.forgetKept(id: "0123456789abcdef") }
        #expect(KeptRecordingError.noRoom.errorDescription?.contains("quarter") == true)
    }
}
