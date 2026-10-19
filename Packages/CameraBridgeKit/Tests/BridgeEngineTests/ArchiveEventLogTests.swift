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

    // MARK: Event ids and descriptions

    static func description(_ summary: String = "A person at the front door", kind: EventDescription.Kind = .person,
                            concern: EventDescription.Concern = .unusual, at ms: Int64 = 1_760_101_205_000) -> EventDescription {
        EventDescription(summary: summary, kind: kind, concern: concern, model: "claude-haiku-4-5", at: ArchiveTime.date(ms: ms))
    }

    @Test func recordHandsOutTheIdsOfTheEventsItStarts() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let counter = Box<UInt32>(0)
        let log = ArchiveEventLog(log: .silent, random: { counter.update { $0 += 1 }; return counter.value })
        let start: Int64 = 1_760_101_200_000   // 2025-10-10 13:00 UTC
        let started = log.record([Self.edge("Person", start), Self.edge("Motion", start), Self.edge("Tamper", start + 1, began: false)],
                                 folder: folder.url, video: { _ in true })
        #expect(started == [
            StartedEvent(cameraID: Self.camera, kind: "Person", id: "199ce34f080-00000001", date: ArchiveTime.date(ms: start)),
            StartedEvent(cameraID: Self.camera, kind: "Motion", id: "199ce34f080-00000002", date: ArchiveTime.date(ms: start)),
        ], "one per event that began, in the edges' order; an end (here of an event that never began) hands out nothing")
        let ended = log.record([Self.edge("Motion", start + 9_000, began: false)], folder: folder.url, video: { _ in true })
        #expect(ended.isEmpty)
        let other = log.record([Self.edge("Doorbell ring", start + 10_000, camera: Self.other)], folder: folder.url, video: { _ in false })
        #expect(other.map(\.cameraID) == [Self.other] && other.map(\.id) == ["199ce351790-00000003"])
        await log.flush()

        let read = try ArchiveEventLog.read(folder: folder.url, cameras: [Self.camera], fromMs: start, toMs: start + 1, limit: 10)
        #expect(Set(read.events.map(\.id)) == Set(started.map(\.id)), "the ids handed out are the ids written")
    }

    @Test func withoutAFolderNothingStartsAndNoIdIsHandedOut() async throws {
        let log = ArchiveEventLog(log: .silent)
        let start: Int64 = 1_760_101_200_000
        let started = log.record([Self.edge("Motion", start), Self.edge("Person", start)], folder: nil, video: { _ in true })
        #expect(started.isEmpty && log.pendingCount == 0)
        let none = log.record([], folder: nil, video: { _ in true })
        #expect(none.isEmpty)
        // A description has nowhere to go either.
        log.recordDescription(Self.description(), for: StartedEvent(cameraID: Self.camera, kind: "Person", id: "x-00000001", date: ArchiveTime.date(ms: start)),
                              folder: nil)
        #expect(log.pendingCount == 0)

        let harness = try ArchiveStoreHarness { _ in }
        var settings = harness.settings()
        settings.nvrFolder = nil
        await harness.start(settings)
        #expect(harness.store.recordEvents([Self.edge("Motion", start)], video: { _ in false }).isEmpty)
        #expect(harness.store.eventLog.pendingCount == 0)
    }

    @Test func aDescriptionLineIsReadWithItsEvent() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let counter = Box<UInt32>(0)
        let log = ArchiveEventLog(log: .silent, random: { counter.update { $0 += 1 }; return counter.value })
        let start: Int64 = 1_760_101_200_000
        let started = log.record([Self.edge("Person", start), Self.edge("Motion", start)], folder: folder.url, video: { _ in true })
        let person = try #require(started.first), motion = try #require(started.last)
        let first = Self.description("A person at the front door")
        log.recordDescription(first, for: person, folder: folder.url)
        log.record([Self.edge("Person", start + 20_000, began: false)], folder: folder.url, video: { _ in true })
        await log.flush()

        let file = ArchiveEventLog.dayFile(folder: folder.url, camera: Self.camera, day: "2025-10-10")
        let lines = try Self.lines(file)
        #expect(lines.count == 5 && lines.last == "", "two starts, the description, the end and the last break")
        #expect(lines[2] == #"{"ai":{"at":1760101205000,"concern":"unusual","kind":"person","model":"claude-haiku-4-5","summary":"A person at the front door"},"id":"\#(person.id)","v":1}"#,
                "dates in milliseconds like the rest of the file: \(lines[2])")
        #expect(Self.mode(file) == 0o600)
        let read = { try ArchiveEventLog.read(folder: folder.url, cameras: [Self.camera], fromMs: start, toMs: start + 1, limit: 10).events }
        var events = try read()
        #expect(events.map(\.kind) == ["Person", "Motion"] && events.map(\.description) == [first, nil])
        #expect(events[0].endMs == start + 20_000 && events[1].endMs == nil, "a description line does not disturb the ends")

        // A second description of the same event replaces the first; one of an event the file does not hold is ignored.
        let second = Self.description("Someone leaves a parcel", kind: .delivery, concern: .routine, at: 1_760_101_230_000)
        log.recordDescription(second, for: person, folder: folder.url)
        log.recordDescription(Self.description("A ghost"), for: StartedEvent(cameraID: Self.camera, kind: "Person", id: "199ce34f080-0000ffff",
                                                                              date: ArchiveTime.date(ms: start)), folder: folder.url)
        log.recordDescription(Self.description("A cat", kind: .animal, concern: .routine), for: motion, folder: folder.url)
        await log.flush()
        events = try read()
        #expect(events.count == 2 && events.map(\.description) == [second, Self.description("A cat", kind: .animal, concern: .routine)],
                "the last line of an id wins: \(events)")
    }

    @Test func aDescriptionIsKeptInTheDayFileOfItsEventsStart() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let log = ArchiveEventLog(log: .silent)
        let late: Int64 = 1_760_054_400_000 - 2_000   // 2025-10-09 23:59:58 UTC
        let started = log.record([Self.edge("Vehicle", late)], folder: folder.url, video: { _ in true })
        // The picture arrives and the model answers after midnight.
        log.recordDescription(Self.description("A van pulls up", kind: .vehicle, concern: .routine, at: late + 12_000), for: try #require(started.first),
                              folder: folder.url)
        await log.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.appending(path: ".events/\(Self.camera.uuidString)").path(percentEncoded: false)).sorted()
        #expect(names == ["2025-10-09.jsonl"], "no file for the day the answer came, so retention takes both together")
        let read = try ArchiveEventLog.read(folder: folder.url, cameras: [Self.camera], fromMs: late, toMs: late + 1, limit: 5)
        #expect(read.events.first?.description?.summary == "A van pulls up")
    }

    /// Final review M3: a description that does not fit is dropped, and the owner who looks at the log at debug level can see that one was
    /// (its size, never its words).
    @Test func aDescriptionThatDoesNotFitIsLoggedAtDebugLevel() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let messages = Box<[(level: LogLevel, message: String)]>([])
        let log = ArchiveEventLog(log: ArchiveStoreLog { level, message in messages.update { $0.append((level, message)) } })
        let started = try #require(log.record([Self.edge("Person", 1_760_101_200_000)], folder: folder.url, video: { _ in true }).first)
        let heavy = String(repeating: "e\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306}\u{0307}\u{0308}\u{0309}\u{030A}", count: 130)
        log.recordDescription(Self.description(heavy), for: started, folder: folder.url)
        log.recordDescription(Self.description("A van stops outside"), for: started, folder: folder.url)
        await log.flush()
        let dropped = messages.value.filter { $0.message.contains("description") && $0.message.contains("not kept") }
        #expect(dropped.count == 1 && dropped.first?.level == .debug, "\(messages.value)")
        #expect(!messages.value.contains { $0.message.contains("e\u{0301}") || $0.message.contains("A van stops") }, "the model's words are not logged")
    }

    @Test func aDescriptionLineIsBoundedAndOldReadersIgnoreIt() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let log = ArchiveEventLog(log: .silent)
        let start: Int64 = 1_760_101_200_000
        let started = try #require(log.record([Self.edge("Person", start)], folder: folder.url, video: { _ in true }).first)
        // A summary built without `EventDescription.parse` can be any length: the line keeps to the limit.
        log.recordDescription(Self.description(String(repeating: "word ", count: 2_000)), for: started, folder: folder.url)
        // Characters can be many bytes: what still does not fit is not kept at all.
        log.recordDescription(Self.description(String(repeating: "e\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306}\u{0307}\u{0308}\u{0309}\u{030A}", count: 130)),
                              for: started, folder: folder.url)
        await log.flush()
        let file = ArchiveEventLog.dayFile(folder: folder.url, camera: Self.camera, day: "2025-10-10")
        let lines = try Self.lines(file).filter { !$0.isEmpty }
        #expect(lines.count == 2, "the start and one description: \(lines.count)")
        #expect(lines.allSatisfy { $0.utf8.count <= ArchiveEventLog.maximumDescriptionLineBytes })
        let kept = try #require(try ArchiveEventLog.read(folder: folder.url, cameras: [Self.camera], fromMs: start, toMs: start + 1, limit: 5).events.first?.description)
        #expect(kept.summary.count == EventDescription.maximumSummaryLength)
        // A longer line than this build writes (a hand edit, a build with another limit) is not read.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"ai":{"at":1760101230000,"concern":"alarm","kind":"person","model":"m","summary":""# + String(repeating: "x", count: 5_000)
                                           + #""},"id":"\#(started.id)","v":1}"# + "\n").utf8))
        try handle.close()
        let again = try ArchiveEventLog.read(folder: folder.url, cameras: [Self.camera], fromMs: start, toMs: start + 1, limit: 5).events.first?.description
        #expect(again == kept, "the oversized line does not replace it")

        // An older build reads the same file: the description line has none of what makes a start or an end, so it pairs with nothing.
        struct OldLine: Decodable {
            var v: Int
            var id: String
            var camera: String?
            var kind: String?
            var start: Int64?
            var end: Int64?
            var video: Bool?
        }
        let old = try JSONDecoder().decode(OldLine.self, from: Data(lines[1].utf8))
        #expect(old.id == started.id && old.start == nil && old.kind == nil && old.end == nil)
        // And this build reads a file with none: a line without `ai` is the line it always was.
        let plain = try JSONDecoder().decode(ArchiveEventLog.Line.self, from: Data(lines[0].utf8))
        #expect(plain.ai == nil && plain.start == start && plain.kind == "Person")
    }

    @Test func aDescriptionRecordedThroughTheStoreComesBackWithItsEvent() async throws {
        let harness = try ArchiveStoreHarness { _ in }
        await harness.start()
        let start: Int64 = 1_760_101_200_000
        harness.clock.update { $0 = ArchiveTime.date(ms: start + 3_600_000) }
        let started = harness.store.recordEvents([Self.edge("Person", start), Self.edge("Motion", start + 1_000)], video: { _ in true })
        #expect(started.count == 2)
        let description = Self.description()
        harness.store.recordDescription(description, for: started[0])
        await harness.store.eventLog.flush()
        let page = try await harness.store.events(cameras: [Self.camera], range: ArchiveTime.date(ms: start - 60_000)..<ArchiveTime.date(ms: start + 60_000), limit: 10)
        #expect(page.events.map(\.kind) == ["Motion", "Person"] && page.events.map(\.description) == [nil, description])
    }

    @Test func aDescriptionWaitsInTheSameQueueAsTheEventsAndAPlaceChangeGivesItUp() async throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let old = parent.url.appending(path: "gone", directoryHint: .isDirectory)
        let new = parent.url.appending(path: "new", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: false)
        let log = ArchiveEventLog(log: .silent)
        let start: Int64 = 1_760_101_200_000
        let started = try #require(log.record([Self.edge("Person", start)], folder: old, video: { _ in true }).first)
        log.recordDescription(Self.description(), for: started, folder: old)
        await log.flush()
        #expect(log.pendingCount == 2, "the folder is missing: the event and its description wait, in order")
        // The owner chose another place: what waited for the old one is given up, the description with it. (A description that arrives now
        // is written there as a line that matches no event: harmless, and retention takes it with its day.)
        log.recordDescription(Self.description("Late"), for: started, folder: new)
        await log.flush()
        #expect(log.pendingCount == 0)
        let read = try ArchiveEventLog.read(folder: new, cameras: [Self.camera], fromMs: start, toMs: start + 60_000, limit: 5)
        #expect(read.events.isEmpty, "the new place never saw the event, so its description matches nothing")
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
