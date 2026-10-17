import BridgeSupport
@testable import CameraAdapters
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// The cameras' events beside the recordings (`ArchiveEventLog`): what reaches the day files, a torn last line, a restart, what the store answers
/// with whether the recordings hold each event, retention, a new place for recordings, and the router's edges that feed it.
@Suite(.timeLimit(.minutes(1))) struct ArchiveEventLogTests {
    static let camera = ArchiveStoreHarness.camera
    static let other = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!
    static let day: Int64 = 86_400_000

    static func edge(_ kind: String, _ ms: Int64, began: Bool = true, camera: UUID = camera) -> EventEdge {
        EventEdge(cameraID: camera, kind: kind, date: ArchiveTime.date(ms: ms), began: began)
    }

    static func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.posixPermissions] as? Int
    }

    // MARK: The file

    @Test func eventsAreAppendedOneLinePerEdgeToTheCamerasDayFile() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let counter = Box<UInt32>(0)
        let log = ArchiveEventLog(log: .silent, random: { counter.update { $0 += 1 }; return counter.value })
        let start: Int64 = 1_760_101_200_000   // 2025-10-10 13:00 UTC
        log.record([Self.edge("Person", start), Self.edge("Motion", start)], folder: folder.url, video: { _ in true })
        log.record([Self.edge("Motion", start + 9_000, began: false), Self.edge("Person", start + 60_000, began: false)], folder: folder.url, video: { _ in true })
        log.record([Self.edge("Motion", start + 1, began: false)], folder: folder.url, video: { _ in true })   // no event of that kind is open: nothing
        await log.flush()
        #expect(log.pendingCount == 0)

        let file = ArchiveEventLog.dayFile(folder: folder.url, camera: Self.camera, day: "2025-10-10")
        #expect(file.path(percentEncoded: false).hasSuffix("/.events/\(Self.camera.uuidString)/2025-10-10.jsonl"))
        let lines = try Self.lines(file)
        #expect(lines.count == 5 && lines.last == "", "four lines, each ending in a line break")
        #expect(lines[0] == #"{"camera":"\#(Self.camera.uuidString)","id":"199ce34f080-00000001","kind":"Person","start":1760101200000,"v":1,"video":true}"#)
        #expect(lines[2] == #"{"end":1760101209000,"id":"199ce34f080-00000002","v":1}"#)
        #expect(Self.mode(file) == 0o600 && Self.mode(file.deletingLastPathComponent()) == 0o700)
        #expect(Self.mode(folder.url.appending(path: ".events")) == 0o700)

        let read = try ArchiveEventLog.read(folder: folder.url, cameras: [Self.camera], fromMs: start, toMs: start + 1, limit: 10)
        #expect(read.events.map(\.kind) == ["Person", "Motion"], "the same moment: in a stable order")
        #expect(read.events.map(\.endMs) == [start + 60_000, start + 9_000] && read.events.allSatisfy(\.video) && !read.truncated)
        #expect(read.events.map(\.id) == ["199ce34f080-00000001", "199ce34f080-00000002"])

        let other = ArchiveEventLog(log: .silent)
        other.record([Self.edge("Motion", start + 120_000)], folder: folder.url, video: { _ in false })
        await other.flush()
        let later = try ArchiveEventLog.read(folder: folder.url, cameras: [Self.camera], fromMs: start, toMs: start + Self.day, limit: 10)
        #expect(later.events.map(\.kind) == ["Motion", "Person", "Motion"], "newest first")
        #expect(later.events[0].endMs == nil && later.events[0].video == false)
    }

    @Test func aTornLastLineIsSkippedAndTheNextEventStartsOnALineOfItsOwn() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let start: Int64 = 1_760_101_200_000
        let log = ArchiveEventLog(log: .silent)
        log.record([Self.edge("Motion", start)], folder: folder.url, video: { _ in true })
        await log.flush()
        let file = ArchiveEventLog.dayFile(folder: folder.url, camera: Self.camera, day: "2025-10-10")
        // The power went while a line was written.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"camera":"\#(Self.camera.uuidString)","id":"torn","kind":"Mot"#.utf8))
        try handle.close()

        let restarted = ArchiveEventLog(log: .silent)
        restarted.record([Self.edge("Doorbell ring", start + 5_000), Self.edge("Doorbell ring", start + 5_000, began: false)], folder: folder.url, video: { _ in true })
        await restarted.flush()
        let lines = try Self.lines(file)
        #expect(lines.count == 5, "the start, the torn line, the ring's start and its end, and the last break: \(lines)")
        #expect(lines[1].hasSuffix(#""kind":"Mot"#) && lines[2].hasPrefix(#"{"camera""#))
        let read = try ArchiveEventLog.read(folder: folder.url, cameras: [Self.camera], fromMs: start, toMs: start + 60_000, limit: 10)
        #expect(read.events.map(\.kind) == ["Doorbell ring", "Motion"])
        #expect(read.events[0].endMs == start + 5_000, "a ring ends as it begins")
        #expect(read.events[1].endMs == nil, "the motion that was going on when the bridge stopped has no end")
    }

    @Test func eventsSurviveARestartAndAnEndTheNewRunNeverSawStartIsIgnored() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let start: Int64 = 1_760_101_200_000
        let first = ArchiveEventLog(log: .silent)
        first.record([Self.edge("Vehicle", start), Self.edge("Vehicle", start + 30_000, began: false), Self.edge("Motion", start + 40_000)],
                     folder: folder.url, video: { _ in true })
        await first.flush()

        let second = ArchiveEventLog(log: .silent)
        second.record([Self.edge("Motion", start + 50_000, began: false)], folder: folder.url, video: { _ in true })   // began in the old run
        await second.flush()
        let read = try ArchiveEventLog.read(folder: folder.url, cameras: [Self.camera], fromMs: start, toMs: start + 3_600_000, limit: 10)
        #expect(read.events.map(\.kind) == ["Motion", "Vehicle"])
        #expect(read.events[0].endMs == nil && read.events[1].endMs == start + 30_000)
    }

    @Test func readingCrossesDaysAndCamerasNewestFirstAndSaysWhenItCutOlderOnesOff() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let midnight: Int64 = 1_760_054_400_000   // 2025-10-10 00:00 UTC
        let log = ArchiveEventLog(log: .silent)
        var times: [Int64] = []
        for hour in stride(from: -30, through: 30, by: 6) { times.append(midnight + Int64(hour) * 3_600_000) }
        for (index, time) in times.enumerated() {
            log.record([Self.edge("Motion", time, camera: index.isMultiple(of: 2) ? Self.camera : Self.other)], folder: folder.url, video: { _ in false })
        }
        await log.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.appending(path: ".events/\(Self.camera.uuidString)").path(percentEncoded: false)).sorted()
        #expect(names == ["2025-10-08.jsonl", "2025-10-09.jsonl", "2025-10-10.jsonl", "2025-10-11.jsonl"])

        let all = try ArchiveEventLog.read(folder: folder.url, cameras: [Self.camera, Self.other], fromMs: times[0], toMs: times.last! + 1, limit: 100)
        #expect(all.events.map(\.startMs) == times.reversed() && !all.truncated)
        let some = try ArchiveEventLog.read(folder: folder.url, cameras: [Self.camera, Self.other], fromMs: times[0], toMs: times.last! + 1, limit: 4)
        #expect(some.events.map(\.startMs) == Array(times.reversed().prefix(4)) && some.truncated)
        let one = try ArchiveEventLog.read(folder: folder.url, cameras: [Self.other], fromMs: times[2], toMs: times[7], limit: 100)
        #expect(one.events.map(\.startMs) == [times[5], times[3]], "from is inclusive, to exclusive, one camera")
        #expect(try ArchiveEventLog.read(folder: folder.url, cameras: [UUID()], fromMs: times[0], toMs: times.last!, limit: 10).events.isEmpty)
    }

    @Test func aPageNeverSplitsAMillisecondSoTheNextPageFindsItWhole() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let midnight: Int64 = 1_760_054_400_000   // 2025-10-10 00:00 UTC
        let log = ArchiveEventLog(log: .silent)
        // The router stamps every edge of one publication alike: a ring with its motion and person, just after midnight; two of another
        // camera at one moment of the day before, and one more that day.
        let ring = midnight + 1_000, pair = midnight - 1_000, single = midnight - 7_200_000
        log.record([Self.edge("Doorbell ring", ring), Self.edge("Motion", ring), Self.edge("Person", ring)], folder: folder.url, video: { _ in true })
        log.record([Self.edge("Motion", pair, camera: Self.other), Self.edge("Person", pair, camera: Self.other)], folder: folder.url, video: { _ in true })
        log.record([Self.edge("Vehicle", single)], folder: folder.url, video: { _ in true })
        await log.flush()
        let cameras = [Self.camera, Self.other], from = midnight - Self.day, to = midnight + Self.day
        let all = try ArchiveEventLog.read(folder: folder.url, cameras: cameras, fromMs: from, toMs: to, limit: 100)
        #expect(all.events.map(\.startMs) == [ring, ring, ring, pair, pair, single] && !all.truncated)

        let two = try ArchiveEventLog.read(folder: folder.url, cameras: cameras, fromMs: from, toMs: to, limit: 2)
        #expect(two.events.map(\.startMs) == [ring, ring, ring] && two.truncated,
                "more than the limit at the newest moment: that moment whole, and the day before still to come")
        let four = try ArchiveEventLog.read(folder: folder.url, cameras: cameras, fromMs: from, toMs: to, limit: 4)
        #expect(four.events.map(\.startMs) == [ring, ring, ring] && four.truncated, "a cut inside the next moment leaves all of it for the next page")
        let three = try ArchiveEventLog.read(folder: folder.url, cameras: cameras, fromMs: from, toMs: to, limit: 3)
        #expect(three.events.map(\.startMs) == [ring, ring, ring] && three.truncated)

        // Paged with `to` = the oldest start of the page before, every event comes exactly once, whatever the limit.
        for limit in 1...7 {
            var end = to, seen: [String] = []
            for _ in 0..<10 {
                let page = try ArchiveEventLog.read(folder: folder.url, cameras: cameras, fromMs: from, toMs: end, limit: limit)
                seen += page.events.map(\.id)
                guard page.truncated, let oldest = page.events.last?.startMs else { break }
                end = oldest
            }
            #expect(seen.count == 6 && Set(seen) == Set(all.events.map(\.id)), "limit \(limit): \(seen.count) events")
        }
    }

    @Test func nothingIsKeptWithoutAFolderAndLinesWaitWhileTheFolderIsMissing() async throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let folder = parent.url.appending(path: "drive", directoryHint: .isDirectory)
        let log = ArchiveEventLog(log: .silent)
        let start: Int64 = 1_760_101_200_000
        log.record([Self.edge("Motion", start)], folder: nil, video: { _ in true })
        #expect(log.pendingCount == 0, "no place for recordings is chosen")
        log.record([Self.edge("Motion", start)], folder: folder, video: { _ in true })
        await log.flush()
        #expect(log.pendingCount == 1 && !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)), "the recordings folder is never made")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        log.retry()
        await log.flush()
        #expect(log.pendingCount == 0)
        #expect(try ArchiveEventLog.read(folder: folder, cameras: [Self.camera], fromMs: start, toMs: start + 1, limit: 5).events.count == 1)
    }

    @Test func aNewPlaceForRecordingsGivesUpWhatWaitedForTheOldOne() async throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let old = parent.url.appending(path: "gone", directoryHint: .isDirectory)
        let new = parent.url.appending(path: "new", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: false)
        let log = ArchiveEventLog(log: .silent)
        let start: Int64 = 1_760_101_200_000
        log.record([Self.edge("Motion", start)], folder: old, video: { _ in true })
        await log.flush()
        #expect(log.pendingCount == 1)
        log.record([Self.edge("Motion", start + 5_000, began: false), Self.edge("Person", start + 6_000)], folder: new, video: { _ in true })
        await log.flush()
        #expect(log.pendingCount == 0)
        let read = try ArchiveEventLog.read(folder: new, cameras: [Self.camera], fromMs: start, toMs: start + 60_000, limit: 5)
        #expect(read.events.map(\.kind) == ["Person"], "the old place's motion does not end in the new one")
    }

    /// A log whose first append waits for `gate` (a slow drive) and then does what `first` says; later appends are the real one.
    static func slowLog(gate: DispatchSemaphore, calls: Box<Int>, messages: Box<[String]>,
                        first: @escaping @Sendable () throws -> Void = {}) -> ArchiveEventLog {
        ArchiveEventLog(log: ArchiveStoreLog { _, message in messages.update { $0.append(message) } }, append: { data, folder, camera, day in
            if calls.update({ $0 += 1; return $0 }) == 1 {
                gate.wait()
                try first()
            }
            try ArchiveEventLog.append(data, folder: folder, camera: camera, day: day)
        })
    }

    @Test func aLineWrittenWhileThePlaceChangesNeverTakesAnotherLineOutOfTheQueue() async throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let old = parent.url.appending(path: "old", directoryHint: .isDirectory), new = parent.url.appending(path: "new", directoryHint: .isDirectory)
        for folder in [old, new] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        let gate = DispatchSemaphore(value: 0), calls = Box(0), messages = Box<[String]>([])
        let log = Self.slowLog(gate: gate, calls: calls, messages: messages)
        let start: Int64 = 1_760_101_200_000
        log.record([Self.edge("Motion", start)], folder: old, video: { _ in true })
        #expect(await eventually { calls.value == 1 }, "the old place's line is on its way to the drive")
        log.record([Self.edge("Person", start + 1_000), Self.edge("Person", start + 4_000, began: false)], folder: new, video: { _ in true })
        gate.signal()
        await log.flush()
        #expect(log.pendingCount == 0)
        let read = try ArchiveEventLog.read(folder: new, cameras: [Self.camera], fromMs: start, toMs: start + 60_000, limit: 5)
        #expect(read.events.map(\.kind) == ["Person"] && read.events.first?.endMs == start + 4_000, "both lines of the new place were written")
        #expect(try ArchiveEventLog.read(folder: old, cameras: [Self.camera], fromMs: start, toMs: start + 60_000, limit: 5).events.map(\.kind) == ["Motion"])
        #expect(messages.value.isEmpty, "nothing was lost")
    }

    @Test func theCapNeverDropsTheLineBeingWrittenAndCountsWhatItDrops() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let gate = DispatchSemaphore(value: 0), calls = Box(0), messages = Box<[String]>([])
        // The drive fails the first write, after making it wait while the queue overflows.
        let log = Self.slowLog(gate: gate, calls: calls, messages: messages) { throw CocoaError(.fileWriteUnknown) }
        let start: Int64 = 1_760_101_200_000
        log.record([Self.edge("Motion", start)], folder: folder.url, video: { _ in true })
        #expect(await eventually { calls.value == 1 })
        let more = ArchiveEventLog.maximumPending + 1
        log.record((1...more).map { Self.edge("K\($0)", start + Int64($0)) }, folder: folder.url, video: { _ in true })
        #expect(log.pendingCount == ArchiveEventLog.maximumPending)
        gate.signal()
        await log.flush()
        #expect(log.pendingCount == ArchiveEventLog.maximumPending, "the failed line waits with the rest")
        log.retry()
        await log.flush()
        #expect(log.pendingCount == 0)
        let kinds = Set(try ArchiveEventLog.read(folder: folder.url, cameras: [Self.camera], fromMs: start, toMs: start + 60_000, limit: 2_000).events.map(\.kind))
        #expect(kinds.count == ArchiveEventLog.maximumPending)
        #expect(kinds.contains("Motion") && !kinds.contains("K1") && !kinds.contains("K2") && kinds.contains("K3"),
                "the oldest waiting lines went, not the one that was being written")
        #expect(messages.value.contains { $0.contains("(2 were lost)") }, "\(messages.value)")
    }

    @Test func pruneDeletesOnlyWholeDaysBeforeTheCutoffAndOnlyOwnNames() throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let directory = folder.url.appending(path: ".events/\(Self.camera.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["2025-10-08.jsonl", "2025-10-09.jsonl", "2025-10-10.jsonl", "notes.jsonl", "2025-10-07.txt"] {
            try Data("x\n".utf8).write(to: directory.appending(path: name))
        }
        let cutoff: Int64 = 1_760_054_400_000 + 3_600_000   // 2025-10-10 01:00 UTC: the 9th ended before it, the 10th did not
        #expect(ArchiveEventLog.prune(folder: folder.url, cutoffMs: cutoff) == 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
        #expect(left == ["2025-10-07.txt", "2025-10-10.jsonl", "notes.jsonl"])
        #expect(ArchiveEventLog.dayStartMs("2025-02-30") == nil && ArchiveEventLog.dayStartMs("2025-10-10") == 1_760_054_400_000)
    }

    @Test func eventsAreNeverWrittenReadOrPrunedThroughALink() async throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let manager = FileManager.default
        let folder = parent.url.appending(path: "recordings", directoryHint: .isDirectory)
        let outside = parent.url.appending(path: "outside", directoryHint: .isDirectory)
        let outsideCamera = outside.appending(path: Self.camera.uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        try manager.createDirectory(at: outsideCamera, withIntermediateDirectories: true)
        let start: Int64 = 1_760_101_200_000   // 2025-10-10 13:00 UTC
        let line = #"{"camera":"\#(Self.camera.uuidString)","id":"x-00000001","kind":"Motion","start":\#(start),"v":1,"video":true}"# + "\n"
        let outsideFile = outsideCamera.appending(path: "2025-10-10.jsonl")
        try Data(line.utf8).write(to: outsideFile)
        let events = folder.appending(path: ".events", directoryHint: .isDirectory)
        let cutoff = start + 30 * Self.day

        // `.events` is a link to a folder elsewhere.
        try manager.createSymbolicLink(at: URL(fileURLWithPath: ArchiveVolume.path(of: events)), withDestinationURL: outside)
        #expect(ArchiveEventLog.prune(folder: folder, cutoffMs: cutoff) == 0 && manager.fileExists(atPath: outsideFile.path(percentEncoded: false)))
        #expect(try ArchiveEventLog.read(folder: folder, cameras: [Self.camera], fromMs: start, toMs: start + 1, limit: 5).events.isEmpty)
        let log = ArchiveEventLog(log: .silent)
        log.record([Self.edge("Person", start + 1_000)], folder: folder, video: { _ in true })
        await log.flush()
        #expect(try log.pendingCount == 1 && Self.lines(outsideFile).count == 2, "not written through the link")

        // A camera's folder is a link.
        try manager.removeItem(at: URL(fileURLWithPath: ArchiveVolume.path(of: events)))
        try manager.createDirectory(at: events, withIntermediateDirectories: false)
        try manager.createSymbolicLink(at: URL(fileURLWithPath: ArchiveVolume.path(of: events.appending(path: Self.camera.uuidString))), withDestinationURL: outsideCamera)
        #expect(ArchiveEventLog.prune(folder: folder, cutoffMs: cutoff) == 0 && manager.fileExists(atPath: outsideFile.path(percentEncoded: false)))
        #expect(try ArchiveEventLog.read(folder: folder, cameras: [Self.camera], fromMs: start, toMs: start + 1, limit: 5).events.isEmpty)
        log.retry()
        await log.flush()
        #expect(try log.pendingCount == 1 && Self.lines(outsideFile).count == 2)

        // A day file that is a link, in a real camera folder.
        try manager.removeItem(at: URL(fileURLWithPath: ArchiveVolume.path(of: events.appending(path: Self.camera.uuidString))))
        let cameraFolder = events.appending(path: Self.camera.uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: cameraFolder, withIntermediateDirectories: false)
        try manager.createSymbolicLink(at: cameraFolder.appending(path: "2025-10-09.jsonl"), withDestinationURL: outsideFile)
        #expect(ArchiveEventLog.prune(folder: folder, cutoffMs: cutoff) == 0 && manager.fileExists(atPath: outsideFile.path(percentEncoded: false)))
        log.retry()
        await log.flush()
        #expect(log.pendingCount == 0, "a real folder is written again")
    }

    // MARK: The store

    @Test func theStoreAnswersEventsWithWhetherTheRecordingsHoldThem() async throws {
        let harness = try ArchiveStoreHarness { _ in }
        try harness.write()   // 6 fragments of 1 s from 2025-10-10 13:00:00 UTC
        await harness.start()
        let fileStart: Int64 = 1_760_101_200_000
        harness.clock.update { $0 = ArchiveTime.date(ms: fileStart + 3_600_000) }
        harness.store.recordEvents([Self.edge("Motion", fileStart + 2_000), Self.edge("Person", fileStart - 2_000)], video: { _ in true })
        harness.store.recordEvents([Self.edge("Motion", fileStart + 60_000, began: false)], video: { _ in true })
        harness.store.recordEvents([Self.edge("Vehicle", fileStart + 600_000)], video: { _ in false })
        harness.store.recordEvents([Self.edge("Tamper", fileStart + 3_590_000)], video: { _ in true })
        await harness.store.eventLog.flush()
        let page = try await harness.store.events(cameras: [Self.camera], range: ArchiveTime.date(ms: fileStart - 60_000)..<ArchiveTime.date(ms: fileStart + 3_600_000),
                                                  limit: 10)
        #expect(page.events.map(\.kind) == ["Tamper", "Vehicle", "Motion", "Person"] && !page.isTruncated)
        #expect(page.events.map(\.recorded) == [true, false, true, true],
                "just now while recording; after the file without video; inside the file; 2 s before it (a click plays from 3 s before)")
        #expect(page.events[2].end == ArchiveTime.date(ms: fileStart + 60_000) && page.events[2].hadVideo)
        let limited = try await harness.store.events(cameras: [Self.camera], range: ArchiveTime.date(ms: fileStart - 60_000)..<ArchiveTime.date(ms: fileStart + 3_600_000),
                                                     limit: 2)
        #expect(limited.events.count == 2 && limited.isTruncated)
    }

    @Test func aStoreWithoutAFolderHasNoEvents() async throws {
        let harness = try ArchiveStoreHarness { _ in }
        var settings = harness.settings()
        settings.nvrFolder = nil
        await harness.start(settings)
        harness.store.recordEvents([Self.edge("Motion", 1_760_101_200_000)], video: { _ in false })
        #expect(harness.store.eventLog.pendingCount == 0)
        let page = try await harness.store.events(cameras: [Self.camera], range: Date(timeIntervalSince1970: 0)..<Date(), limit: 10)
        #expect(page.events.isEmpty)
    }

    /// The Monitor keeps an answered range for good: only "no place for recordings is chosen" may answer no events without looking.
    @Test func aStoreThatCannotLookSaysSoInsteadOfAnsweringNoEvents() async throws {
        let start: Int64 = 1_760_101_200_000
        let range = ArchiveTime.date(ms: start - 60_000)..<ArchiveTime.date(ms: start + 3_600_000)
        // The folder is not there at the start: the store is ready, and paused.
        let away = try ArchiveStoreHarness { _ in }
        await away.start(away.settings(folder: away.root.url.appending(path: "drive", directoryHint: .isDirectory)))
        #expect(away.store.writeState.pause == .folderMissing)
        await #expect(throws: ArchiveUnavailable.folderMissing) { try await away.store.events(cameras: [Self.camera], range: range, limit: 10) }

        let harness = try ArchiveStoreHarness { _ in }
        await harness.start()
        harness.store.recordEvents([Self.edge("Motion", start)], video: { _ in false })
        await harness.store.eventLog.flush()
        await harness.store.stop()   // no probe changes what the test sets
        let events = { try await harness.store.events(cameras: [Self.camera], range: range, limit: 10) }
        #expect(try await events().events.count == 1)
        // The drive went before the monitor noticed.
        let hidden = harness.root.url.deletingLastPathComponent().appending(path: "hidden-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: harness.root.url, to: hidden)
        await #expect(throws: ArchiveUnavailable.folderMissing) { try await events() }
        try FileManager.default.moveItem(at: hidden, to: harness.root.url)
        harness.store.state.withLock { $0.pause = .folderMissing }
        await #expect(throws: ArchiveUnavailable.folderMissing) { try await events() }
        harness.store.state.withLock { $0.pause = nil; $0.isReady = false }
        await #expect(throws: ArchiveUnavailable.loading) { try await events() }
        harness.store.state.withLock { $0.isReady = true; $0.readsStalled = true }
        await #expect(throws: ArchiveError.timedOut) { try await events() }
        harness.store.state.withLock { $0.readsStalled = false }
        #expect(try await events().events.count == 1)
    }

    @Test func retentionDeletesEventDaysByTheKeepTimeAndAfterTheSizeRule() async throws {
        let cameras = [UUID(), UUID(), UUID()]
        var files: [ArchiveStoreRetentionTests.Written] = []
        let harness = try ArchiveStoreHarness { root in
            for position in 0..<30 {   // 12 GB over 60 hours: the 10 GB cap takes the oldest six
                files.append(try ArchiveStoreRetentionTests.sparse(root, camera: cameras[position % 3], hoursAgo: Double(60 - position * 2), manifest: position < 3))
            }
        }
        await harness.start(harness.settings(keepDays: 7, maxSizeGB: 10))
        let nowMs = ArchiveStoreRetentionTests.nowMs
        // Events of eight days ago, of three days ago, of the day of the oldest deleted file, and of today.
        let times = [nowMs - 8 * Self.day, nowMs - 3 * Self.day, nowMs - 2 * Self.day - 12 * 3_600_000, nowMs - 60_000]
        for time in times { harness.store.recordEvents([Self.edge("Motion", time, camera: cameras[0])], video: { _ in true }) }
        await harness.store.eventLog.flush()
        let dayFiles = { () -> [String] in
            (try? FileManager.default.contentsOfDirectory(atPath: harness.root.url.appending(path: ".events/\(cameras[0].uuidString)").path(percentEncoded: false)))?.sorted() ?? []
        }
        #expect(dayFiles().count == 4)

        await harness.store.pruneEvents(harness.run)
        #expect(dayFiles().count == 3, "the day that ended before the keep time")

        await harness.store.runRetention(harness.run)
        let deleted = files.filter { !ArchiveStoreRetentionTests.exists($0.mp4) }
        #expect(deleted.count == 6)
        let cutoff = try #require(harness.store.state.withLock { $0.eventSizeCutoffMs })
        #expect(cutoff == deleted.map(\.startMs).max())
        await harness.store.pruneEvents(harness.run)
        let expected = times.dropFirst().filter { ($0 / Self.day + 1) * Self.day > cutoff }.map { ArchiveEventLog.dayName(ms: $0) + ".jsonl" }
        #expect(dayFiles() == expected.sorted() && dayFiles().count < 3, "the days before the newest file the size rule took")
    }

    // MARK: The router's edges

    @Test func theRouterReportsEachEventsBeginningAndEnd() async {
        let clock = TestClock()
        let wall = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let router = EventRouter(clock: clock, date: { wall.value })
        let edges = Box<[EventEdge]>([])
        await router.setEdgeHandler { batch in edges.update { $0 += batch } }
        let id = UUID()
        var camera = CameraConfiguration(id: id, name: "Porch", kind: .doorbell, vendor: .onvif, endpoint: CameraEndpoint(host: "192.0.2.1"), username: "admin")
        camera.motionHoldSeconds = 5
        await router.register(camera)
        #expect(edges.value.isEmpty)

        await router.handle(.object(.person, true), for: id)
        await router.handle(.motion(true), for: id)
        #expect(edges.value.map { "\($0.kind) \($0.began)" } == ["Person true", "Motion true"])
        wall.update { $0 = $0.addingTimeInterval(10) }
        clock.advance(by: .seconds(10))
        await router.handle(.motion(false), for: id)
        clock.advance(by: .seconds(6))
        wall.update { $0 = $0.addingTimeInterval(6) }
        _ = await router.state(for: id)   // applies the expired hold
        #expect(edges.value.suffix(1).map { "\($0.kind) \($0.began)" } == ["Motion false"])
        #expect(edges.value.last?.date == Date(timeIntervalSince1970: 1_800_000_016))

        edges.update { $0 = [] }
        await router.handle(.doorbellPressed, for: id)
        #expect(edges.value.map { "\($0.kind) \($0.began)" } == ["Motion true", "Doorbell ring true", "Doorbell ring false"])
        #expect(Set(edges.value.map(\.date)).count == 1, "one stamp for one publication")

        edges.update { $0 = [] }
        await router.unregister(cameraID: id)
        #expect(Set(edges.value.map { "\($0.kind) \($0.began)" }) == ["Person false", "Motion false"], "a removed camera's events end")
    }
}
