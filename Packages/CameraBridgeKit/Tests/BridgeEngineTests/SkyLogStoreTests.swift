import BridgeSupport
@testable import CameraAdapters
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// The sky log beside the recordings (`SkyLogStore`): what reaches a night's file, how later lines apply to their entry, a torn last line, the
/// stills, retention with the events' cutoff, links never followed; how entries are filed by time (a night by its sunset's date, a day by its
/// own: Ruling S4); and the engine's reading of the log by night or by day, its corrections, its stills and the flight feeds it finds.
@Suite(.timeLimit(.minutes(2))) struct SkyLogStoreTests {
    static let camera = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    static let other = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!
    static let zone = TimeZone(identifier: "America/Chicago")!
    static let observer = SkyFixtures.observer
    static let night = "2026-10-24"
    static let day: Int64 = 86_400_000

    /// A wall-clock time of October 2026 in Chicago (still on daylight time, UTC−5).
    static func local(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded()) }

    static let measures = SkyMeasures(azimuth: 312, elevation: 8, azimuthEnd: 330, elevationEnd: 14, duration: 4.2, speed: 3, acceleration: 0, turnRate: 0.1,
                                      maxTurn: 5, straightness: 0.99, shape: .straight, sizeDegrees: 0.1, brightness: 100, blinks: false, blinkRate: nil, focus: 1)

    static func entry(_ id: String, _ start: Date, label: SkyLabel = .unexplained, camera: UUID = camera, seconds: Double = 4.2, hasStill: Bool = false,
                      kind: SkyEntryKind = .track) -> SkyEntry {
        SkyEntry(id: id, camera: camera, kind: kind, start: start, end: start.addingTimeInterval(seconds),
                 path: [SkyPathPoint(t: 0, x: 0.1, y: 0.2), SkyPathPoint(t: seconds, x: 0.3, y: 0.25)], measures: measures, label: label, hasStill: hasStill)
    }

    static func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.posixPermissions] as? Int
    }

    static func int(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }

    static func object(_ line: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    /// A made-up picture: the bytes of a JPEG's start and end markers around a body.
    static func jpeg(_ body: String = "sky") -> Data { Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(body.utf8) + Data([0xFF, 0xD9]) }

    // MARK: The file

    @Test func eachKindOfLineIsOneLineOfTheNightsFile() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let log = SkyLogStore(log: .silent)
        let start = Self.local(24, 21)
        let entry = Self.entry("199ce34f080-00000001", start, hasStill: true)
        log.record(entry, night: Self.night, folder: folder.url)
        log.recordCorrection(.bird, entryID: entry.id, camera: Self.camera, night: Self.night, folder: folder.url, at: Self.local(25, 8))
        log.recordAI(SkyAIAnswer(kind: "insect", sentence: "A moth near the lens.", model: "claude-haiku-5-5", at: Self.local(24, 21, 1)), entryID: entry.id,
                     camera: Self.camera, night: Self.night, folder: folder.url)
        log.recordAlert(entryID: entry.id, camera: Self.camera, night: Self.night, folder: folder.url)
        log.recordConditions(SkyConditions(from: Self.local(24, 19), to: Self.local(25, 3), state: .clear, cloudCover: 10), camera: Self.camera, night: Self.night,
                             folder: folder.url)
        log.writeStill(Self.jpeg(), entryID: entry.id, camera: Self.camera, night: Self.night, folder: folder.url)
        await log.flush()
        #expect(log.pendingCount == 0)

        let file = SkyLogStore.nightFile(folder: folder.url, camera: Self.camera, night: Self.night)
        #expect(file.path(percentEncoded: false).hasSuffix("/.sky/\(Self.camera.uuidString)/2026-10-24.jsonl"))
        let lines = try Self.lines(file)
        #expect(lines.count == 6 && lines.last == "", "five lines, each ending in a line break")
        let first = try Self.object(lines[0])
        #expect(first["v"] as? Int == 1 && Set(first.keys) == ["entry", "v"] && lines[0].hasPrefix(#"{"entry":{"#), "sorted keys: \(lines[0].prefix(60))")
        let stored = try #require(first["entry"] as? [String: Any])
        #expect(stored["id"] as? String == entry.id && stored["camera"] as? String == Self.camera.uuidString && stored["kind"] as? String == "track")
        #expect(stored["label"] as? String == "unexplained" && stored["hasStill"] as? Bool == true)
        #expect(Self.int(stored["start"]) == Self.ms(start) && Self.int(stored["end"]) == Self.ms(start.addingTimeInterval(4.2)), "times in milliseconds")
        #expect(lines[1] == #"{"correction":{"at":\#(Self.ms(Self.local(25, 8))),"label":"bird"},"id":"\#(entry.id)","v":1}"#)
        #expect(lines[2] == #"{"ai":{"at":\#(Self.ms(Self.local(24, 21, 1))),"kind":"insect","model":"claude-haiku-5-5","sentence":"A moth near the lens."},"id":"\#(entry.id)","v":1}"#)
        #expect(lines[3] == #"{"alerted":true,"id":"\#(entry.id)","v":1}"#)
        #expect(lines[4] == #"{"conditions":{"cloudCover":10,"from":\#(Self.ms(Self.local(24, 19))),"state":"clear","to":\#(Self.ms(Self.local(25, 3)))},"v":1}"#)

        // 0600 files in folders of 0700, and the still beside the log, in a folder of the night's name.
        let sky = folder.url.appending(path: ".sky", directoryHint: .isDirectory)
        let cameraFolder = sky.appending(path: Self.camera.uuidString, directoryHint: .isDirectory)
        let still = cameraFolder.appending(path: "2026-10-24/\(entry.id).jpg")
        #expect(SkyLogStore.stillFile(folder: folder.url, camera: Self.camera, night: Self.night, id: entry.id) == still)
        #expect(try Data(contentsOf: still) == Self.jpeg())
        #expect(Self.mode(file) == 0o600 && Self.mode(still) == 0o600)
        #expect(Self.mode(sky) == 0o700 && Self.mode(cameraFolder) == 0o700 && Self.mode(still.deletingLastPathComponent()) == 0o700)
        #expect(SkyLogStore.directoryName == ".sky")
    }

    @Test func laterLinesApplyToTheirEntry() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let log = SkyLogStore(log: .silent)
        let plain = Self.entry("a-1", Self.local(24, 20), label: .plane), doubted = Self.entry("a-2", Self.local(24, 21)), quiet = Self.entry("a-3", Self.local(24, 22))
        for entry in [plain, doubted, quiet] { log.record(entry, night: Self.night, folder: folder.url) }
        log.recordCorrection(.bug, entryID: "a-2", camera: Self.camera, night: Self.night, folder: folder.url, at: Self.local(25, 7))
        log.recordCorrection(.bird, entryID: "a-2", camera: Self.camera, night: Self.night, folder: folder.url, at: Self.local(25, 8))
        let answer = SkyAIAnswer(kind: "bird", sentence: "A bird crossing the beam.", model: "claude-haiku-5-5", at: Self.local(24, 21, 2))
        log.recordAI(SkyAIAnswer(kind: "unknown", sentence: "Something small.", model: "claude-haiku-5-5", at: Self.local(24, 21, 1)), entryID: "a-2",
                     camera: Self.camera, night: Self.night, folder: folder.url)
        log.recordAI(answer, entryID: "a-2", camera: Self.camera, night: Self.night, folder: folder.url)
        log.recordAlert(entryID: "a-2", camera: Self.camera, night: Self.night, folder: folder.url)
        log.recordAlert(entryID: "a-2", camera: Self.camera, night: Self.night, folder: folder.url)
        // Lines for an entry the file does not hold, or another camera's, change nothing.
        log.recordCorrection(.plane, entryID: "ghost", camera: Self.camera, night: Self.night, folder: folder.url, at: Self.local(25, 9))
        log.recordAlert(entryID: "ghost", camera: Self.camera, night: Self.night, folder: folder.url)
        log.recordAI(answer, entryID: "ghost", camera: Self.camera, night: Self.night, folder: folder.url)
        let conditions = [SkyConditions(from: Self.local(24, 22), to: Self.local(25, 3), state: .notVisible, cloudCover: 95),
                          SkyConditions(from: Self.local(24, 19), to: Self.local(24, 22), state: .clear, cloudCover: nil)]
        for span in conditions { log.recordConditions(span, camera: Self.camera, night: Self.night, folder: folder.url) }
        log.recordConditions(conditions[0], camera: Self.camera, night: Self.night, folder: folder.url)   // the same span twice is one
        await log.flush()

        let read = log.read(camera: Self.camera, night: Self.night, folder: folder.url)
        #expect(read.entries.map(\.id) == ["a-1", "a-2", "a-3"], "in the order the lights began")
        let corrected = read.entries[1]
        #expect(corrected.correction == .bird, "the last correction of an id wins")
        #expect(corrected.ai == answer && corrected.alerted, "the last answer wins; alerted stays true")
        #expect(SkyDisplay.label(corrected) == .bird)
        #expect(read.entries[0] == plain && read.entries[2] == quiet, "the others are as they were recorded")
        #expect(read.conditions == [conditions[1], conditions[0]], "conditions in the order of their time, each once")
        #expect(log.read(camera: Self.other, night: Self.night, folder: folder.url).entries.isEmpty, "another camera has its own log")

        // The label a person sees: a correction wins, "not sure" shows the entry's own label.
        let own = Self.entry("x", Self.local(24, 20), label: .satellite)
        func shown(_ correction: SkyCorrection?, label: SkyLabel = .satellite) -> SkyLabel {
            var entry = own
            entry.label = label
            entry.correction = correction
            return SkyDisplay.label(entry)
        }
        #expect(shown(nil) == .satellite && shown(.plane) == .plane && shown(.bird) == .bird && shown(.bug) == .bug)
        #expect(shown(.satellite, label: .plane) == .satellite && shown(.meteor) == .meteor)
        #expect(shown(.notSure) == .satellite && shown(.notSure, label: .probablePlane) == .probablePlane && shown(.notSure, label: .unexplained) == .unexplained)
        #expect(shown(.plane, label: .unexplained) == .plane, "a person can explain what the box could not")
        #expect(SkyCorrection.allCases.map(\.rawValue) == ["plane", "bird", "bug", "satellite", "meteor", "notSure"])
    }

    @Test func aTornLineIsSkipped() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let log = SkyLogStore(log: .silent)
        for (index, hour) in [20, 21, 22].enumerated() { log.record(Self.entry("t-\(index)", Self.local(24, hour)), night: Self.night, folder: folder.url) }
        await log.flush()
        let file = SkyLogStore.nightFile(folder: folder.url, camera: Self.camera, night: Self.night)
        // The power went: the last line is cut off, with no line break.
        let whole = try Data(contentsOf: file)
        try whole.prefix(whole.count - 40).write(to: file)
        let read = log.read(camera: Self.camera, night: Self.night, folder: folder.url)
        #expect(read.entries.map(\.id) == ["t-0", "t-1"], "the other entries read")

        // The next line starts on a line of its own.
        log.record(Self.entry("t-3", Self.local(24, 23)), night: Self.night, folder: folder.url)
        await log.flush()
        let again = log.read(camera: Self.camera, night: Self.night, folder: folder.url)
        #expect(again.entries.map(\.id) == ["t-0", "t-1", "t-3"])
        let lines = try Self.lines(file)
        #expect(lines.count == 5 && lines.last == "", "the torn text stays on a line of its own: \(lines.count) lines")
        #expect((try? JSONSerialization.jsonObject(with: Data(lines[2].utf8))) == nil && lines[3].hasPrefix(#"{"entry":{"#))
    }

    @Test func linesOfALaterVersionOrDamagedAreSkippedAndTheRestRead() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let log = SkyLogStore(log: .silent)
        log.record(Self.entry("k-1", Self.local(24, 20)), night: Self.night, folder: folder.url)
        await log.flush()
        let file = SkyLogStore.nightFile(folder: folder.url, camera: Self.camera, night: Self.night)
        let other = Self.entry("k-9", Self.local(24, 22), camera: Self.other)
        let otherLine = String(decoding: try SkyLogStore.makeEncoder().encode(SkyLogStore.Line(v: 1, entry: other)), as: UTF8.self)
        let later = #"{"correction":{"at":1,"label":"bird"},"id":"k-1","v":2}"#
        let junk = [later, "not json", "{}", #"{"v":1}"#, #"{"v":1,"id":"k-1","correction":{"label":"ufo","at":1}}"#, #"{"v":1,"id":"k-1","unknown":true}"#,
                    #"{"v":1,"id":"","alerted":true}"#, otherLine, #"{"v":1,"id":"k-1","correction":{"label":"plane","at":5}}"#]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((junk.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        let read = log.read(camera: Self.camera, night: Self.night, folder: folder.url)
        #expect(read.entries.map(\.id) == ["k-1"], "another camera's entry in this camera's file is not read")
        #expect(read.entries[0].correction == .plane && !read.entries[0].alerted, "only the line that was whole and known applied")
        // An oversized line is not read; a missing file is no entries.
        let huge = #"{"v":1,"id":"k-1","ai":{"at":1,"kind":"x","model":"m","sentence":""# + String(repeating: "w", count: SkyLogStore.maximumLineBytes) + #""}}"# + "\n"
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(huge.utf8))
        try writer.close()
        #expect(log.read(camera: Self.camera, night: Self.night, folder: folder.url).entries[0].ai == nil)
        #expect(log.read(camera: Self.camera, night: "2026-10-01", folder: folder.url).entries.isEmpty)
    }

    @Test func aWaitingLineIsReadBeforeItIsWritten() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let gate = DispatchSemaphore(value: 0), calls = Box(0)
        // A slow drive: the first line waits for the gate on its way to the file.
        let log = SkyLogStore(log: .silent, append: { data, folder, camera, night in
            if calls.update({ $0 += 1; return $0 }) == 1 { gate.wait() }
            try SkyLogStore.append(data, folder: folder, camera: camera, night: night)
        })
        log.record(Self.entry("w-1", Self.local(24, 20)), night: Self.night, folder: folder.url)
        #expect(await eventually { calls.value == 1 }, "the entry's line is on its way to the drive")
        log.recordCorrection(.bird, entryID: "w-1", camera: Self.camera, night: Self.night, folder: folder.url, at: Self.local(25, 8))
        log.recordAlert(entryID: "w-1", camera: Self.camera, night: Self.night, folder: folder.url)
        let before = log.read(camera: Self.camera, night: Self.night, folder: folder.url)
        #expect(before.entries.map(\.id) == ["w-1"] && before.entries[0].correction == .bird && before.entries[0].alerted,
                "what has not reached the drive yet is read all the same, once")
        gate.signal()
        await log.flush()
        #expect(log.pendingCount == 0)
        let after = log.read(camera: Self.camera, night: Self.night, folder: folder.url)
        #expect(after.entries == before.entries && after.entries.count == 1, "and the same when it has")
    }

    // MARK: Nothing is kept without a place, and what cannot be written waits for the drive

    @Test func nothingIsKeptWithoutAFolderAndLinesWaitWhileTheFolderIsMissing() async throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let folder = parent.url.appending(path: "drive", directoryHint: .isDirectory)
        let log = SkyLogStore(log: .silent)
        let entry = Self.entry("d-1", Self.local(24, 20), hasStill: true)
        log.record(entry, night: Self.night, folder: nil)
        log.recordCorrection(.bird, entryID: entry.id, camera: Self.camera, night: Self.night, folder: nil, at: Self.local(25, 8))
        log.writeStill(Self.jpeg(), entryID: entry.id, camera: Self.camera, night: Self.night, folder: nil)
        #expect(log.pendingCount == 0, "no place for recordings is chosen")

        log.record(entry, night: Self.night, folder: folder)
        log.writeStill(Self.jpeg(), entryID: entry.id, camera: Self.camera, night: Self.night, folder: folder)
        await log.flush()
        #expect(log.pendingCount == 2 && !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)), "the recordings folder is never made")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        log.retry()
        await log.flush()
        #expect(log.pendingCount == 0)
        #expect(log.read(camera: Self.camera, night: Self.night, folder: folder).entries.map(\.id) == ["d-1"])
        #expect(log.still(camera: Self.camera, night: Self.night, entryID: "d-1", folder: folder) == Self.jpeg())
    }

    @Test func aNewPlaceForRecordingsGivesUpWhatWaitedForTheOldOne() async throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let old = parent.url.appending(path: "gone", directoryHint: .isDirectory), new = parent.url.appending(path: "new", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: false)
        let log = SkyLogStore(log: .silent)
        log.record(Self.entry("o-1", Self.local(24, 20)), night: Self.night, folder: old)
        await log.flush()
        #expect(log.pendingCount == 1)
        log.record(Self.entry("o-2", Self.local(24, 21)), night: Self.night, folder: new)
        await log.flush()
        #expect(log.pendingCount == 0)
        #expect(log.read(camera: Self.camera, night: Self.night, folder: new).entries.map(\.id) == ["o-2"])
    }

    @Test func theCapDropsTheOldestWaitingLinesButNeverTheOneBeingWritten() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let gate = DispatchSemaphore(value: 0), calls = Box(0), messages = Box<[String]>([])
        let log = SkyLogStore(log: ArchiveStoreLog { _, message in messages.update { $0.append(message) } }, append: { data, folder, camera, night in
            if calls.update({ $0 += 1; return $0 }) == 1 {
                gate.wait()
                throw CocoaError(.fileWriteUnknown)
            }
            try SkyLogStore.append(data, folder: folder, camera: camera, night: night)
        })
        log.record(Self.entry("c-0", Self.local(24, 20)), night: Self.night, folder: folder.url)
        #expect(await eventually { calls.value == 1 })
        for index in 1...(SkyLogStore.maximumPending + 1) {
            log.recordAlert(entryID: "c-\(index)", camera: Self.camera, night: Self.night, folder: folder.url)
        }
        #expect(log.pendingCount == SkyLogStore.maximumPending)
        gate.signal()
        await log.flush()
        #expect(log.pendingCount == SkyLogStore.maximumPending, "the failed line waits with the rest")
        log.retry()
        await log.flush()
        #expect(log.pendingCount == 0)
        let lines = try Self.lines(SkyLogStore.nightFile(folder: folder.url, camera: Self.camera, night: Self.night))
        #expect(lines.count == SkyLogStore.maximumPending + 1 && lines[0].contains("\"c-0\""), "the line that was being written is the first, and kept")
        #expect(!lines.contains { $0.contains("\"c-1\"") } && !lines.contains { $0.contains("\"c-2\"") } && lines.contains { $0.contains("\"c-3\"") },
                "the oldest waiting lines went")
        #expect(messages.value.contains { $0.contains("(2 were lost)") }, "\(messages.value)")
        #expect(messages.value.allSatisfy { $0.contains("Sky Watcher") }, "said in the feature's name: \(messages.value)")
    }

    @Test func aStillTooLargeIsNotKeptAndWaitingStillsAreBounded() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let gate = DispatchSemaphore(value: 0), calls = Box(0)
        let log = SkyLogStore(log: .silent, writeStill: { jpeg, folder, camera, night, id in
            if calls.update({ $0 += 1; return $0 }) == 1 { gate.wait() }
            try SkyLogStore.writeStillFile(jpeg, folder: folder, camera: camera, night: night, id: id)
        })
        log.writeStill(Data(count: SkyLogStore.maximumStillBytes + 1), entryID: "big", camera: Self.camera, night: Self.night, folder: folder.url)
        #expect(log.pendingCount == 0, "a picture over the limit is not kept")
        log.writeStill(Data(), entryID: "empty", camera: Self.camera, night: Self.night, folder: folder.url)
        #expect(log.pendingCount == 0, "nor is an empty one")
        let size = SkyLogStore.maximumStillBytes
        log.writeStill(Data(count: size), entryID: "s-0", camera: Self.camera, night: Self.night, folder: folder.url)
        #expect(await eventually { calls.value == 1 })
        let room = SkyLogStore.maximumPendingStillBytes / size
        for index in 1...(room + 3) { log.writeStill(Data(count: size), entryID: "s-\(index)", camera: Self.camera, night: Self.night, folder: folder.url) }
        #expect(log.pendingCount == room, "the pictures that wait are bounded in bytes: \(log.pendingCount) of \(room)")
        gate.signal()
        await log.flush()
        #expect(log.pendingCount == 0)
        #expect(log.still(camera: Self.camera, night: Self.night, entryID: "s-0", folder: folder.url)?.count == size, "the one being written was kept")
        #expect(log.still(camera: Self.camera, night: Self.night, entryID: "s-\(room + 3)", folder: folder.url)?.count == size, "and the newest")
    }

    // MARK: An entry is kept within bounds

    @Test func anEntryIsKeptWithinBounds() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let log = SkyLogStore(log: .silent)
        var long = Self.entry("b-1", Self.local(24, 20), seconds: 100)
        long.path = (0...300).map { SkyPathPoint(t: Double($0) / 3, x: Double($0) / 300, y: 0.5) }
        long.path.insert(SkyPathPoint(t: .nan, x: 0.2, y: 0.2), at: 5)
        long.path.insert(SkyPathPoint(t: 1, x: .infinity, y: 0.2), at: 9)
        long.detail = String(repeating: "d", count: 1_000)
        long.ai = SkyAIAnswer(kind: "bird", sentence: String(repeating: "s", count: 5_000), model: "m", at: Self.local(24, 21))
        log.record(long, night: Self.night, folder: folder.url)
        // An end before the start is the start; a start that is not a time, and an id that is not safe in a path, are no line at all.
        var backwards = Self.entry("b-2", Self.local(24, 21))
        backwards.end = backwards.start.addingTimeInterval(-5)
        log.record(backwards, night: Self.night, folder: folder.url)
        log.record(Self.entry("b-3", Date(timeIntervalSince1970: .nan)), night: Self.night, folder: folder.url)
        for id in ["", "../escape", "a/b", "a b", "dot.dot", String(repeating: "x", count: 65), "ünï"] {
            log.record(Self.entry(id, Self.local(24, 22)), night: Self.night, folder: folder.url)
        }
        await log.flush()
        let read = log.read(camera: Self.camera, night: Self.night, folder: folder.url)
        let kept = try #require(read.entries.first)
        #expect(read.entries.map(\.id) == ["b-1", "b-2"] && read.entries[1].end == read.entries[1].start)
        #expect(kept.id == "b-1")
        #expect(kept.path.count == SkyPathPoint.maximumPerEntry && SkyPathPoint.maximumPerEntry == 64, "at most 64 points")
        #expect(kept.path.first?.x == 0 && kept.path.last?.x == 1, "evenly picked, the first and the last among them")
        #expect(kept.path.allSatisfy { $0.t.isFinite && $0.x.isFinite && $0.y.isFinite } && kept.path.map(\.t) == kept.path.map(\.t).sorted())
        #expect((kept.detail?.count ?? 0) <= SkyEntry.maximumDetailLength && (kept.ai?.sentence.count ?? 0) <= SkyAIAnswer.maximumSentenceLength)
        let lines = try Self.lines(SkyLogStore.nightFile(folder: folder.url, camera: Self.camera, night: Self.night))
        #expect(lines.count == 3 && lines.allSatisfy { $0.utf8.count <= SkyLogStore.maximumLineBytes }, "two lines, within the limit")
    }

    @Test func namesAreCheckedBeforeTheyReachAPath() async throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let folder = parent.url.appending(path: "recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let log = SkyLogStore(log: .silent)
        for night in ["../2026-10-24", "2026-10-24/../x", "2026-13-01", "2026-10-24.jsonl", "", "tonight", "2026-10-4", "２０２６-10-24"] {
            log.record(Self.entry("n-1", Self.local(24, 20)), night: night, folder: folder)
            log.writeStill(Self.jpeg(), entryID: "n-1", camera: Self.camera, night: night, folder: folder)
            #expect(log.read(camera: Self.camera, night: night, folder: folder).entries.isEmpty)
            #expect(log.still(camera: Self.camera, night: night, entryID: "n-1", folder: folder) == nil)
        }
        for id in ["../n", "a/b", "", "n 1"] {
            log.writeStill(Self.jpeg(), entryID: id, camera: Self.camera, night: Self.night, folder: folder)
            log.recordAlert(entryID: id, camera: Self.camera, night: Self.night, folder: folder)
            log.recordCorrection(.bird, entryID: id, camera: Self.camera, night: Self.night, folder: folder, at: Self.local(25, 8))
            #expect(log.still(camera: Self.camera, night: Self.night, entryID: id, folder: folder) == nil)
        }
        await log.flush()
        #expect(log.pendingCount == 0, "nothing was queued")
        let listing = FileManager.default.enumerator(atPath: folder.path(percentEncoded: false))?.allObjects as? [String] ?? []
        #expect(listing.isEmpty, "nothing was made: \(listing)")
        #expect(!FileManager.default.fileExists(atPath: parent.url.appending(path: "escape").path(percentEncoded: false)))
        #expect(SkyEntry.isValidID("199ce34f080-00000001") && SkyEntry.isValidID("a_b-C9") && !SkyEntry.isValidID("a.b") && !SkyEntry.isValidID(""))
    }

    // MARK: Stills

    @Test func stillsAreKeptBesideTheLogAndReadBack() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let log = SkyLogStore(log: .silent)
        log.writeStill(Self.jpeg("first"), entryID: "p-1", camera: Self.camera, night: Self.night, folder: folder.url)
        log.writeStill(Self.jpeg("second"), entryID: "p-2", camera: Self.camera, night: Self.night, folder: folder.url)
        log.writeStill(Self.jpeg("later"), entryID: "p-1", camera: Self.camera, night: Self.night, folder: folder.url)   // the same entry again: the newer
        await log.flush()
        func still(_ id: String, night: String = Self.night, camera: UUID = Self.camera) -> Data? {
            log.still(camera: camera, night: night, entryID: id, folder: folder.url)
        }
        #expect(still("p-1") == Self.jpeg("later") && still("p-2") == Self.jpeg("second"))
        #expect(still("p-3") == nil && still("p-1", night: "2026-10-25") == nil && still("p-1", camera: Self.other) == nil)
        let directory = SkyLogStore.stillFile(folder: folder.url, camera: Self.camera, night: Self.night, id: "p-1").deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted() == ["p-1.jpg", "p-2.jpg"], "no temporary file is left")
        // A file in the folder that is not a regular file is not a still.
        try FileManager.default.createDirectory(at: directory.appending(path: "p-4.jpg"), withIntermediateDirectories: false)
        #expect(still("p-4") == nil)
    }

    // MARK: Retention

    @Test func pruningFollowsTheEventsCutoff() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let log = SkyLogStore(log: .silent)
        let nights = ["2026-10-05", "2026-10-17", "2026-10-18", "2026-10-19", "2026-10-20"]
        for night in nights {
            log.record(Self.entry("r-\(night)", Self.local(24, 20)), night: night, folder: folder.url)
            log.writeStill(Self.jpeg(night), entryID: "r-\(night)", camera: Self.camera, night: night, folder: folder.url)
            log.record(Self.entry("o-\(night)", Self.local(24, 20), camera: Self.other), night: night, folder: folder.url)
        }
        await log.flush()
        let root = folder.url.appending(path: ".sky", directoryHint: .isDirectory)
        // A stills folder whose log is gone, and names that are not nights'.
        let orphan = root.appending(path: "\(Self.camera.uuidString)/2026-09-30", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: orphan.appending(path: "gone.jpg"))
        let cameraFolder = root.appending(path: Self.camera.uuidString, directoryHint: .isDirectory)
        for name in ["notes.jsonl", "2026-10-05.jsonl.bak", "2026-02-30.txt"] { try Data("x\n".utf8).write(to: cameraFolder.appending(path: name)) }
        try Data("x".utf8).write(to: root.appending(path: "readme.txt"))
        let stranger = root.appending(path: "not-a-camera", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: stranger.appending(path: "2026-01-01.jsonl"))

        // A night goes when its date and the next day are over: the night of the 18th, which ends on the morning of the 19th, goes at the 20th.
        let cutoff = Self.dayStart("2026-10-20")
        let removed = Box<[String]>([])
        #expect(SkyLogStore.prune(folder: folder.url, cutoffMs: cutoff, remove: { url in
            removed.update { $0.append(url.lastPathComponent) }
            try FileManager.default.removeItem(at: url)
        }) == 7, "three nights of each camera, and a folder of stills whose log is gone")
        func left(_ camera: UUID) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: camera.uuidString).path(percentEncoded: false))) ?? []).sorted()
        }
        #expect(left(Self.camera) == ["2026-10-19", "2026-10-19.jsonl", "2026-10-20", "2026-10-20.jsonl", "2026-02-30.txt", "2026-10-05.jsonl.bak", "notes.jsonl"].sorted())
        #expect(left(Self.other) == ["2026-10-19.jsonl", "2026-10-20.jsonl"])
        #expect(log.read(camera: Self.camera, night: "2026-10-05", folder: folder.url).entries.isEmpty)
        #expect(log.read(camera: Self.camera, night: "2026-10-19", folder: folder.url).entries.count == 1)
        #expect(log.still(camera: Self.camera, night: "2026-10-18", entryID: "r-2026-10-18", folder: folder.url) == nil, "a night's stills go with it")
        #expect(log.still(camera: Self.camera, night: "2026-10-19", entryID: "r-2026-10-19", folder: folder.url) == Self.jpeg("2026-10-19"))
        #expect(FileManager.default.fileExists(atPath: stranger.appending(path: "2026-01-01.jsonl").path(percentEncoded: false)), "only a camera's folder is pruned")
        #expect(removed.value.count == 10, "a log and a folder of stills for three nights of one camera, the orphan, and three logs of the other")
        #expect(SkyLogStore.prune(folder: folder.url, cutoffMs: cutoff) == 0, "nothing more to do")
        #expect(SkyLogStore.prune(folder: folder.url.appending(path: "nowhere"), cutoffMs: cutoff) == 0)

        // A deletion that fails is not counted, and is tried again next time.
        #expect(SkyLogStore.prune(folder: folder.url, cutoffMs: Self.dayStart("2026-10-22"), remove: { _ in throw CocoaError(.fileWriteNoPermission) }) == 0)
        #expect(SkyLogStore.prune(folder: folder.url, cutoffMs: Self.dayStart("2026-10-22")) == 4, "the 19th and the 20th of both cameras")
    }

    /// The start of the UTC day `name` in milliseconds.
    static func dayStart(_ name: String) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = name.split(separator: "-").compactMap { Int($0) }
        return ms(calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!)
    }

    @Test func retentionPrunesTheSkyLogWithTheEvents() async throws {
        let harness = try ArchiveStoreHarness { _ in }
        await harness.start(harness.settings(keepDays: 7, maxSizeGB: 10))
        // The store's clock is 2025-10-10 14:00 UTC; the keep time is seven days before.
        let log = harness.store.skyLog
        for night in ["2025-09-30", "2025-10-01", "2025-10-02", "2025-10-09"] {
            log.record(Self.entry("e-\(night)", Date(timeIntervalSince1970: 1_760_000_000)), night: night, folder: harness.root.url)
            log.writeStill(Self.jpeg(), entryID: "e-\(night)", camera: Self.camera, night: night, folder: harness.root.url)
        }
        await log.flush()
        let nights = { () -> [String] in
            let folder = harness.root.url.appending(path: ".sky/\(Self.camera.uuidString)")
            return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
        }
        #expect(nights().count == 4)
        await harness.store.pruneEvents(harness.run)
        #expect(nights() == ["2025-10-02.jsonl", "2025-10-09.jsonl"], "the nights that are over by the keep time")
        #expect(!FileManager.default.fileExists(atPath: harness.root.url.appending(path: ".sky/\(Self.camera.uuidString)/2025-10-01").path(percentEncoded: false)))
        #expect(log.still(camera: Self.camera, night: "2025-10-02", entryID: "e-2025-10-02", folder: harness.root.url) == Self.jpeg())
    }

    // MARK: Links

    @Test func theSkyLogIsNeverWrittenReadOrPrunedThroughALink() async throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let manager = FileManager.default
        let folder = parent.url.appending(path: "recordings", directoryHint: .isDirectory)
        let outside = parent.url.appending(path: "outside", directoryHint: .isDirectory)
        let outsideCamera = outside.appending(path: Self.camera.uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        try manager.createDirectory(at: outsideCamera.appending(path: Self.night, directoryHint: .isDirectory), withIntermediateDirectories: true)
        let messages = Box<[String]>([])
        let log = SkyLogStore(log: ArchiveStoreLog { _, message in messages.update { $0.append(message) } })
        let line = String(decoding: try SkyLogStore.makeEncoder().encode(SkyLogStore.Line(v: 1, entry: Self.entry("l-0", Self.local(24, 20)))), as: UTF8.self) + "\n"
        let outsideFile = outsideCamera.appending(path: "\(Self.night).jsonl")
        let outsideStill = outsideCamera.appending(path: "\(Self.night)/l-1.jpg")
        try Data(line.utf8).write(to: outsideFile)
        try Self.jpeg("outside").write(to: outsideStill)
        let sky = folder.appending(path: ".sky", directoryHint: .isDirectory)
        let cutoff = Self.dayStart("2026-12-01")
        func link(_ at: URL, to target: URL) throws {
            try manager.createSymbolicLink(at: URL(fileURLWithPath: ArchiveVolume.path(of: at)), withDestinationURL: target)
        }
        func remove(_ url: URL) throws { try manager.removeItem(at: URL(fileURLWithPath: ArchiveVolume.path(of: url))) }
        /// Nothing outside was written, replaced or deleted.
        func outsideIsAsItWas() throws -> Bool {
            try Self.lines(outsideFile).count == 2 && Data(contentsOf: outsideStill) == Self.jpeg("outside")
                && manager.fileExists(atPath: outsideCamera.appending(path: Self.night).path(percentEncoded: false))
        }
        /// Reads give nothing of what is outside, and a prune takes nothing.
        func nothingIsReadOrPruned() -> Bool {
            log.read(camera: Self.camera, night: Self.night, folder: folder).entries.allSatisfy { $0.id != "l-0" }
                && log.still(camera: Self.camera, night: Self.night, entryID: "l-1", folder: folder) == nil
                && SkyLogStore.prune(folder: folder, cutoffMs: cutoff) == 0
        }
        /// An entry and its picture, written where a link is in the way: both are given up (nothing waits for a link to go), and nothing is read.
        func attempt(_ id: String) async throws -> Bool {
            log.record(Self.entry(id, Self.local(24, 21)), night: Self.night, folder: folder)
            log.writeStill(Self.jpeg("mine"), entryID: "l-1", camera: Self.camera, night: Self.night, folder: folder)
            await log.flush()
            return try log.pendingCount == 0 && outsideIsAsItWas() && nothingIsReadOrPruned()
        }

        // `.sky` is a link to a folder elsewhere.
        try link(sky, to: outside)
        #expect(try await attempt("l-2"))
        #expect(messages.value.contains { $0.contains("link is in the way") && $0.contains("Sky Watcher") }, "said once for each: \(messages.value)")

        // `.sky` is real, and a camera's folder in it is a link.
        try remove(sky)
        try manager.createDirectory(at: sky, withIntermediateDirectories: false)
        try link(sky.appending(path: Self.camera.uuidString, directoryHint: .isDirectory), to: outsideCamera)
        #expect(try await attempt("l-3"))

        // The camera's folder is real, and the night's log and its folder of pictures are links.
        try remove(sky.appending(path: Self.camera.uuidString))
        let cameraFolder = sky.appending(path: Self.camera.uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: cameraFolder, withIntermediateDirectories: false)
        try link(cameraFolder.appending(path: "\(Self.night).jsonl"), to: outsideFile)
        try link(cameraFolder.appending(path: Self.night, directoryHint: .isDirectory), to: outsideCamera.appending(path: Self.night, directoryHint: .isDirectory))
        #expect(try await attempt("l-4"))

        // The log's file is real now, and the picture's own file is a link: the entry is written, the picture refused.
        try remove(cameraFolder.appending(path: "\(Self.night).jsonl"))
        try remove(cameraFolder.appending(path: Self.night))
        try manager.createDirectory(at: cameraFolder.appending(path: Self.night), withIntermediateDirectories: false)
        try link(cameraFolder.appending(path: "\(Self.night)/l-1.jpg"), to: outsideStill)
        log.record(Self.entry("l-5", Self.local(24, 22)), night: Self.night, folder: folder)
        log.writeStill(Self.jpeg("mine"), entryID: "l-1", camera: Self.camera, night: Self.night, folder: folder)
        await log.flush()
        #expect(log.pendingCount == 0)
        #expect(log.read(camera: Self.camera, night: Self.night, folder: folder).entries.map(\.id) == ["l-5"], "the entry is in a real file")
        #expect(try outsideIsAsItWas() && log.still(camera: Self.camera, night: Self.night, entryID: "l-1", folder: folder) == nil)
        #expect(SkyLogStore.prune(folder: folder, cutoffMs: cutoff) == 1, "a real night is pruned; the link in it is removed with it, and what it pointed to stays")
        #expect(try outsideIsAsItWas())

        // A drive that fails is another thing: that waits.
        let away = parent.url.appending(path: "away", directoryHint: .isDirectory)
        log.record(Self.entry("l-6", Self.local(24, 23)), night: Self.night, folder: away)
        await log.flush()
        #expect(log.pendingCount == 1)
    }

    // MARK: The store is told where a folder is by whoever writes

    @Test func theFilesOfOtherCamerasAndNightsDoNotMix() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let log = SkyLogStore(log: .silent)
        log.record(Self.entry("m-1", Self.local(24, 20)), night: "2026-10-24", folder: folder.url)
        log.record(Self.entry("m-2", Self.local(25, 14)), night: "2026-10-25", folder: folder.url)
        log.record(Self.entry("m-3", Self.local(24, 20), camera: Self.other), night: "2026-10-24", folder: folder.url)
        await log.flush()
        #expect(log.read(camera: Self.camera, night: "2026-10-24", folder: folder.url).entries.map(\.id) == ["m-1"])
        #expect(log.read(camera: Self.camera, night: "2026-10-25", folder: folder.url).entries.map(\.id) == ["m-2"])
        #expect(log.read(camera: Self.other, night: "2026-10-24", folder: folder.url).entries.map(\.id) == ["m-3"])
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.appending(path: ".sky").path(percentEncoded: false)).sorted()
        #expect(names == [Self.camera.uuidString, Self.other.uuidString].sorted())
    }
}

// MARK: - Filing by time (Ruling S4)

/// A night is named by its sunset's local date, a day by its own, and the day after night N is day N+1; an entry is filed by its time, so a night
/// is one file across midnight.
@Suite(.timeLimit(.minutes(2))) struct SkyFilingTests {
    static let observer = SkyFixtures.observer
    static let zone = SkyLogStoreTests.zone
    static func local(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date { SkyLogStoreTests.local(day, hour, minute, second) }

    static func name(_ day: Int, _ hour: Int, _ minute: Int = 0) -> String {
        SkyNight.logName(for: local(day, hour, minute), observer: observer, zone: zone)
    }

    @Test func aNightIsOneFileAcrossMidnight() async throws {
        // Sunset is about 6:45 PM and sunrise about 8 AM there: 9 PM and 2 AM are the same night, named for the evening's date.
        #expect(Self.name(24, 21) == "2026-10-24" && Self.name(25, 2) == "2026-10-24" && Self.name(25, 5) == "2026-10-24" && Self.name(25, 7) == "2026-10-24")
        #expect(Self.name(24, 19, 30) == "2026-10-24", "just after sunset")
        // The day after night N is day N+1, named by its own date; and the evening of that date is its night.
        #expect(Self.name(25, 9) == "2026-10-25" && Self.name(25, 14) == "2026-10-25" && Self.name(25, 17, 30) == "2026-10-25")
        #expect(Self.name(25, 21) == "2026-10-25" && Self.name(26, 2) == "2026-10-25")
        #expect(Self.name(24, 12) == "2026-10-24", "the day before the night of the same date")

        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let log = SkyLogStore(log: .silent)
        for (id, day, hour) in [("f-1", 24, 21), ("f-2", 25, 2), ("f-3", 25, 14), ("f-4", 25, 21)] {
            let start = Self.local(day, hour)
            log.record(SkyLogStoreTests.entry(id, start), night: SkyNight.logName(for: start, observer: Self.observer, zone: Self.zone), folder: folder.url)
        }
        await log.flush()
        let directory = folder.url.appending(path: ".sky/\(SkyLogStoreTests.camera.uuidString)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted() == ["2026-10-24.jsonl", "2026-10-25.jsonl"])
        let evening = log.read(camera: SkyLogStoreTests.camera, night: "2026-10-24", folder: folder.url).entries
        #expect(evening.map(\.id) == ["f-1", "f-2"], "9 PM and 2 AM: one file named for the evening's date")
        #expect(log.read(camera: SkyLogStoreTests.camera, night: "2026-10-25", folder: folder.url).entries.map(\.id) == ["f-3", "f-4"], "the day and the night of the 25th")
    }

    @Test func aViewSpansItsNightOrItsDay() {
        let night = SkyNight.logSpan(named: "2026-10-24", view: .night, observer: Self.observer, zone: Self.zone)
        let day = SkyNight.logSpan(named: "2026-10-25", view: .day, observer: Self.observer, zone: Self.zone)
        let next = SkyNight.logSpan(named: "2026-10-25", view: .night, observer: Self.observer, zone: Self.zone)
        func hours(_ span: ClosedRange<Date>) -> Double { span.upperBound.timeIntervalSince(span.lowerBound) / 3_600 }
        // The night: sunset to sunrise. The day: sunrise to sunset, the day after it. The next night starts where the day ends.
        #expect(night.lowerBound > Self.local(24, 18) && night.lowerBound < Self.local(24, 19, 30), "sunset of the 24th: \(night)")
        #expect(night.upperBound > Self.local(25, 7) && night.upperBound < Self.local(25, 9), "sunrise of the 25th")
        #expect(day.lowerBound == night.upperBound, "the day after night N starts at that night's sunrise")
        #expect(next.lowerBound == day.upperBound, "and ends at the sunset that begins the next night")
        #expect(hours(night) > 13 && hours(night) < 14.5 && hours(day) > 9.5 && hours(day) < 11, "\(hours(night)) \(hours(day))")
        // An entry belongs to the view its time is in.
        #expect(night.contains(Self.local(24, 21)) && night.contains(Self.local(25, 2)) && !night.contains(Self.local(25, 14)))
        #expect(day.contains(Self.local(25, 14)) && !day.contains(Self.local(25, 21)) && next.contains(Self.local(25, 21)))
        // A name that is not a date has nothing to span.
        let none = SkyNight.logSpan(named: "tonight", view: .night, observer: Self.observer, zone: Self.zone)
        #expect(none.lowerBound == none.upperBound)
    }

    @Test func theLatestLogIsTheOneNowIsInOrTheNightThatJustEnded() {
        func latest(_ view: SkyLogView, _ day: Int, _ hour: Int) -> String {
            SkyNight.latestLogName(view: view, now: Self.local(day, hour), observer: Self.observer, zone: Self.zone)
        }
        // At 3 PM on the 25th: the last night is the one that ended that morning; the day is today's.
        #expect(latest(.night, 25, 15) == "2026-10-24" && latest(.day, 25, 15) == "2026-10-25")
        // At 11 PM on the 25th: the night is on (tonight so far); the day is the one that ended at sunset.
        #expect(latest(.night, 25, 23) == "2026-10-25" && latest(.day, 25, 23) == "2026-10-25")
        // At 3 AM on the 26th it is still that night, and the last day is still the 25th.
        #expect(latest(.night, 26, 3) == "2026-10-25" && latest(.day, 26, 3) == "2026-10-25")
    }

    @Test func whereTheSunDoesNotSetADayIsItsLocalDate() {
        // Near the pole in July the Sun does not set: no night, one day named by its date, spanning the local day.
        let pole = SkyObserver(latitude: 80, longitude: 15, heightMeters: 0)
        let zone = TimeZone(identifier: "Europe/Oslo")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let noon = calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 12))!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 7, day: 11, hour: 1))!
        #expect(SkyNight.logName(for: noon, observer: pole, zone: zone) == "2026-07-10" && SkyNight.logName(for: midnight, observer: pole, zone: zone) == "2026-07-11")
        let day = SkyNight.logSpan(named: "2026-07-10", view: .day, observer: pole, zone: zone)
        #expect(day.contains(noon) && !day.contains(midnight), "the whole local day")
        let night = SkyNight.logSpan(named: "2026-07-10", view: .night, observer: pole, zone: zone)
        #expect(night.lowerBound == night.upperBound, "no night")
    }
}

// MARK: - The engine reads the log

@Suite(.timeLimit(.minutes(2))) struct SkyNightLogEngineTests {
    static let camera = SkyLogStoreTests.camera
    static let zone = SkyLogStoreTests.zone
    static let place = SkyLocation(latitude: 40.0, longitude: -100.0, heightMeters: 0)

    /// An engine that has the made-up place, a recordings folder and one camera (not started: nothing runs).
    @MainActor final class Rig {
        let directory: TemporaryDirectory
        let recordings: TemporaryDirectory
        let engine: BridgeEngine
        let cameraID: UUID
        var log: SkyLogStore { engine.nvr.store.skyLog }

        init(location: SkyLocation? = SkyNightLogEngineTests.place, folder: Bool = true) async throws {
            directory = try TemporaryDirectory()
            recordings = try TemporaryDirectory()
            engine = BridgeEngine(environment: .inert(directory: directory.url))
            let folderPath = recordings.url.path(percentEncoded: false)
            try await engine.updateSettings { settings in
                settings.sky.location = location
                settings.nvrFolder = folder ? folderPath : nil
            }
            var camera = CameraConfiguration(id: SkyNightLogEngineTests.camera, name: "North Sky", kind: .camera, vendor: .hikvision,
                                             endpoint: CameraEndpoint(host: "192.168.77.30"), username: "admin")
            camera.skyDetector = SkyDetectorSettings(enabled: true)
            cameraID = camera.id
            try await engine.addCamera(camera, password: nil)
        }

        /// Files `entry` where its time says (Ruling S4) and waits for it to be written.
        func file(_ entry: SkyEntry, still: Data? = nil) async {
            let name = SkyNight.logName(for: entry.start, observer: SkyFixtures.observer, zone: SkyNightLogEngineTests.zone)
            log.record(entry, night: name, folder: recordings.url)
            if let still { log.writeStill(still, entryID: entry.id, camera: entry.camera, night: name, folder: recordings.url) }
            await log.flush()
        }

        func night(_ night: String?, _ view: SkyLogView, now: Date = SkyLogStoreTests.local(25, 15)) async throws -> SkyNightLog {
            try await BridgeTime.$taskZone.withValue(SkyNightLogEngineTests.zone) {
                try await engine.skyNightLog(cameraID: cameraID, night: night, view: view, now: now)
            }
        }

        deinit {
            directory.remove()
            recordings.remove()
        }
    }

    static func entry(_ id: String, _ day: Int, _ hour: Int, label: SkyLabel = .unexplained, hasStill: Bool = false) -> SkyEntry {
        SkyLogStoreTests.entry(id, SkyLogStoreTests.local(day, hour), label: label, hasStill: hasStill)
    }

    @MainActor @Test func theNightLogAnswersByViewWithCountsAndTheCamerasState() async throws {
        let rig = try await Rig()
        for entry in [Self.entry("g-1", 24, 21, label: .plane), Self.entry("g-2", 25, 2, label: .satellite), Self.entry("g-3", 24, 22),
                      Self.entry("g-4", 25, 9, label: .probablePlane), Self.entry("g-5", 25, 14), Self.entry("g-6", 25, 20, label: .bird),
                      Self.entry("g-7", 25, 21, label: .meteor), Self.entry("g-8", 25, 22, label: .satelliteFlare), Self.entry("g-9", 25, 22, label: .bug)] {
            await rig.file(entry)
        }
        let conditions = SkyConditions(from: SkyLogStoreTests.local(24, 19), to: SkyLogStoreTests.local(25, 3), state: .clear, cloudCover: 10)
        rig.log.recordConditions(conditions, camera: Self.camera, night: "2026-10-24", folder: rig.recordings.url)
        await rig.log.flush()

        let last = try await rig.night("2026-10-24", .night)
        #expect(last.camera == rig.cameraID && last.night == "2026-10-24" && last.view == .night)
        #expect(last.entries.map(\.id) == ["g-1", "g-3", "g-2"], "the night's lights, by the time they began")
        #expect(last.counts == SkyCounts(unexplained: 1, planes: 1, satellites: 1, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 2))
        #expect(last.conditions == [conditions] && last.from < last.entries[0].start && last.entries[2].start < last.to)
        #expect(last.aim.quality == .rough && last.learning == SkyLearning(ready: false, planes: 0, satellites: 0), "until the detector says otherwise")

        let today = try await rig.night("2026-10-25", .day)
        #expect(today.night == "2026-10-25" && today.view == .day && today.entries.map(\.id) == ["g-4", "g-5"])
        #expect(today.counts == SkyCounts(unexplained: 1, planes: 1, satellites: 0, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 1), "probable planes are planes")
        #expect(today.conditions.isEmpty && today.from == last.to, "the day starts at the sunrise that ended the night")
        let tonight = try await rig.night("2026-10-25", .night)
        #expect(tonight.entries.map(\.id) == ["g-6", "g-7", "g-8", "g-9"])
        #expect(tonight.counts == SkyCounts(unexplained: 0, planes: 0, satellites: 1, meteors: 1, bugsAndBirds: 2, notSure: 0, explained: 4))
        #expect(today.to == tonight.from, "and the next night where the day ends")

        // No night named: the latest. At 3 PM that is the night that ended this morning; the day is today's.
        let latestNight = try await rig.night(nil, .night), latestDay = try await rig.night(nil, .day)
        #expect(latestNight.night == "2026-10-24" && latestDay.night == "2026-10-25" && latestNight.view == .night && latestDay.view == .day)
        let tonightSoFar = try await rig.night(nil, .night, now: SkyLogStoreTests.local(25, 23))
        #expect(tonightSoFar.night == "2026-10-25", "tonight so far")
        // A night with nothing in it is an empty log, with its hours.
        let empty = try await rig.night("2026-10-20", .night)
        #expect(empty.entries.isEmpty && empty.counts == SkyCounts() && empty.from < empty.to)
    }

    @MainActor @Test func theCountsFollowTheDisplayedLabelAndNotSureIsItsOwnGroup() async throws {
        let rig = try await Rig()
        for entry in [Self.entry("h-1", 24, 20, label: .unexplained), Self.entry("h-2", 24, 21, label: .plane), Self.entry("h-3", 24, 22, label: .satellite),
                      Self.entry("h-4", 24, 23, label: .bird), Self.entry("h-5", 25, 1, label: .unexplained), Self.entry("h-6", 25, 2, label: .meteor)] {
            await rig.file(entry)
        }
        let corrections: [(String, SkyCorrection)] = [("h-1", .plane), ("h-2", .notSure), ("h-3", .meteor), ("h-4", .bug), ("h-5", .notSure), ("h-6", .bird)]
        for (id, correction) in corrections {
            _ = try await rig.engine.correctSkyEntry(cameraID: rig.cameraID, entryID: id, night: "2026-10-24", label: correction)
        }
        let log = try await rig.night("2026-10-24", .night)
        #expect(log.counts == SkyCounts(unexplained: 1, planes: 1, satellites: 0, meteors: 1, bugsAndBirds: 2, notSure: 1, explained: 5),
                "a person's word wins; 'not sure' about an explained light is its own group, and about an unexplained one changes nothing: \(log.counts)")
        #expect(SkyCounts(counting: log.entries) == log.counts)
        #expect(SkyCounts() == SkyCounts(unexplained: 0, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 0))
    }

    @MainActor @Test func aCorrectionIsWrittenAndAnswered() async throws {
        let rig = try await Rig()
        await rig.file(Self.entry("k-1", 24, 21), still: nil)
        await rig.file(Self.entry("k-2", 24, 22, label: .plane))
        let bird = try await rig.engine.correctSkyEntry(cameraID: rig.cameraID, entryID: "k-1", night: "2026-10-24", label: .bird)
        #expect(bird.id == "k-1" && bird.correction == .bird && SkyDisplay.label(bird) == .bird)
        let file = SkyLogStore.nightFile(folder: rig.recordings.url, camera: Self.camera, night: "2026-10-24")
        await rig.log.flush()
        let lines = try SkyLogStoreTests.lines(file)
        let written = try #require(lines.last(where: { $0.contains("\"correction\"") }))
        #expect(written.contains("\"label\":\"bird\"") && written.contains("\"id\":\"k-1\""), "written to the night's file: \(written)")
        // The log shows it, and a later word replaces it.
        #expect(try await rig.night("2026-10-24", .night).entries.first { $0.id == "k-1" }?.correction == .bird)
        let sure = try await rig.engine.correctSkyEntry(cameraID: rig.cameraID, entryID: "k-1", night: "2026-10-24", label: .notSure)
        #expect(sure.correction == .notSure && SkyDisplay.label(sure) == .unexplained)

        // What cannot be corrected.
        await #expect(throws: SkyLogError.unknownEntry) { try await rig.engine.correctSkyEntry(cameraID: rig.cameraID, entryID: "nope", night: "2026-10-24", label: .bird) }
        await #expect(throws: SkyLogError.unknownEntry) { try await rig.engine.correctSkyEntry(cameraID: rig.cameraID, entryID: "k-1", night: "2026-10-23", label: .bird) }
        await #expect(throws: SkyLogError.unknownNight) { try await rig.engine.correctSkyEntry(cameraID: rig.cameraID, entryID: "k-1", night: "../x", label: .bird) }
        await #expect(throws: SkyLogError.unknownEntry) { try await rig.engine.correctSkyEntry(cameraID: rig.cameraID, entryID: "../k-1", night: "2026-10-24", label: .bird) }
        await #expect(throws: EngineError.unknownCamera) { try await rig.engine.correctSkyEntry(cameraID: UUID(), entryID: "k-1", night: "2026-10-24", label: .bird) }
        #expect(try await rig.night("2026-10-24", .night).entries.first { $0.id == "k-1" }?.correction == .notSure, "nothing else changed")
    }

    @MainActor @Test func aStillComesBackOrIsMissing() async throws {
        let rig = try await Rig()
        await rig.file(Self.entry("s-1", 24, 21, hasStill: true), still: SkyLogStoreTests.jpeg("one"))
        await rig.file(Self.entry("s-2", 24, 22))
        #expect(try await rig.engine.skyStill(cameraID: rig.cameraID, night: "2026-10-24", entryID: "s-1") == SkyLogStoreTests.jpeg("one"))
        await #expect(throws: SkyLogError.noStill) { try await rig.engine.skyStill(cameraID: rig.cameraID, night: "2026-10-24", entryID: "s-2") }
        await #expect(throws: SkyLogError.noStill) { try await rig.engine.skyStill(cameraID: rig.cameraID, night: "2026-10-23", entryID: "s-1") }
        await #expect(throws: SkyLogError.noStill) { try await rig.engine.skyStill(cameraID: rig.cameraID, night: "2026-10-24", entryID: "../s-1") }
        await #expect(throws: SkyLogError.unknownNight) { try await rig.engine.skyStill(cameraID: rig.cameraID, night: "2026-10-24/..", entryID: "s-1") }
        await #expect(throws: EngineError.unknownCamera) { try await rig.engine.skyStill(cameraID: UUID(), night: "2026-10-24", entryID: "s-1") }
    }

    @MainActor @Test func theLogNeedsAPlaceAndAFolderAndSaysWhich() async throws {
        let noPlace = try await Rig(location: nil)
        await #expect(throws: SkyLogError.noLocation) { try await noPlace.night("2026-10-24", .night) }
        // A picture and a correction need only the folder: the night is named.
        await #expect(throws: SkyLogError.noStill) { try await noPlace.engine.skyStill(cameraID: noPlace.cameraID, night: "2026-10-24", entryID: "x") }
        let noFolder = try await Rig(folder: false)
        await #expect(throws: SkyLogError.noFolder) { try await noFolder.night("2026-10-24", .night) }
        await #expect(throws: SkyLogError.noFolder) {
            try await noFolder.engine.correctSkyEntry(cameraID: noFolder.cameraID, entryID: "x", night: "2026-10-24", label: .bird)
        }
        await #expect(throws: SkyLogError.noFolder) { try await noFolder.engine.skyStill(cameraID: noFolder.cameraID, night: "2026-10-24", entryID: "x") }
        let rig = try await Rig()
        await #expect(throws: SkyLogError.unknownNight) { try await rig.night("tonight", .night) }
        await #expect(throws: SkyLogError.unknownNight) { try await rig.night("2026-02-30", .night) }
        await #expect(throws: EngineError.unknownCamera) {
            try await rig.engine.skyNightLog(cameraID: UUID(), night: nil, view: .night)
        }
        #expect(SkyLogError.noLocation.description == "Set where the box is first.")
        #expect(SkyLogError.noFolder.description == "Choose a recordings folder first: the sky log is kept with the recordings.")
    }

    @MainActor @Test func aMissingDriveIsUnavailableAndNotAnEmptyLog() async throws {
        let rig = try await Rig()
        await rig.file(Self.entry("v-1", 24, 21))
        #expect(try await rig.night("2026-10-24", .night).entries.map(\.id) == ["v-1"])
        // The recordings drive goes away: the folder is gone, and the log says it is unavailable rather than empty.
        let moved = rig.recordings.url.deletingLastPathComponent().appending(path: "away-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: rig.recordings.url, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: rig.recordings.url) }
        await #expect(throws: ArchiveUnavailable.folderMissing) { try await rig.night("2026-10-24", .night) }
    }

    // MARK: Flight feeds

    struct FakeFeedHTTP: SkyHTTP {
        var answers: [String: Int]   // a URL's text to the status it answers (with a feed in it when 200)

        func get(_ url: URL, timeout: Duration, maximumBytes: Int) async throws -> (body: Data, status: Int) {
            guard let status = answers[url.absoluteString] else { throw TransportError.timedOut }
            return (status == 200 ? Data(SkyFixtures.aircraftJSON.utf8) : Data("not found".utf8), status)
        }
    }

    static let neighbours = """
    IP address       HW type     Flags       HW address            Mask     Device
    192.168.77.20    0x1         0x2         aa:bb:cc:00:00:20     *        eth0
    192.168.77.21    0x1         0x2         aa:bb:cc:00:00:21     *        eth0
    192.168.77.22    0x1         0x2         aa:bb:cc:00:00:22     *        eth0
    """

    @MainActor @Test func oneFeedPerHostTheFirstThatAnswersInTheFindersOrder() async throws {
        let rig = try await Rig()
        let http = FakeFeedHTTP(answers: [
            "http://192.168.77.20/tar1090/data/aircraft.json": 200, "http://192.168.77.20/skyaware/data/aircraft.json": 200,
            "http://192.168.77.20:8080/data/aircraft.json": 200, "http://192.168.77.21/skyaware/data/aircraft.json": 200,
            "http://192.168.77.21:8080/data/aircraft.json": 200, "http://192.168.77.22/tar1090/data/aircraft.json": 404,
        ])
        let found = await rig.engine.findFlightFeeds(http: http, neighbours: Self.neighbours)
        #expect(found.map(\.absoluteString) == ["http://192.168.77.20/tar1090/data/aircraft.json", "http://192.168.77.21/skyaware/data/aircraft.json"],
                "one Pi appears once, however many places answer, and a host that answers 404 not at all")
        #expect(await rig.engine.findFlightFeeds(http: FakeFeedHTTP(answers: [:]), neighbours: Self.neighbours).isEmpty)
        #expect(await rig.engine.findFlightFeeds(http: http, neighbours: "").isEmpty)
        // The same host with two spellings of its address in the list is one.
        let urls = ["http://192.168.77.20/a", "http://192.168.77.20:8080/b", "http://192.168.77.21/c", "http://192.168.77.20/d"].compactMap { URL(string: $0) }
        #expect(BridgeEngine.onePerHost(urls).map(\.absoluteString) == ["http://192.168.77.20/a", "http://192.168.77.21/c"])
        #expect(BridgeEngine.onePerHost([]).isEmpty)
    }
}
