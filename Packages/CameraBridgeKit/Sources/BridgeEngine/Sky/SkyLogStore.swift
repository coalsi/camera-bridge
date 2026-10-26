import BridgeSupport
import Foundation
import Synchronization

/// The Sky Watcher's log beside the recordings: every light a sky camera saw, kept whether or not video is recorded, and deleted by the
/// recordings' rules (the events' cutoff, `ArchiveStore.pruneEvents`).
///
/// Layout: `<recordings>/.sky/<CAMERA-UUID>/<night>.jsonl`, one file per camera per night, mode 0600 in folders of 0700. A night is named by the
/// local date of its sunset (a day by its own date), and one file holds a day and the night that follows it (`SkyNight.logName`: Ruling S4), so
/// a night is one file across midnight. The leading dot keeps the folder out of the catalog. A file is append-only, one JSON object per line,
/// keys sorted, times in milliseconds:
///
///     {"entry":{…},"v":1}                                               a light (a `SkyEntry`)
///     {"correction":{"at":<ms>,"label":"bird"},"id":"<id>","v":1}       a person's word on it
///     {"ai":{"at","kind","model","sentence"},"id":"<id>","v":1}         the AI's answer
///     {"alerted":true,"id":"<id>","v":1}                                it raised an alert
///     {"id":"<id>","still":true,"v":1}                                  its picture was made later, from the recording (Ruling S31)
///     {"conditions":{"cloudCover","from","state","to"},"v":1}           how the sky was for a stretch of time
///     {"capped":{"at","count","hour"},"v":1}                            `count` more lights in the clock hour `hour` were not logged
///
/// The first entry line of an id wins; the lines after it (in the order written) apply to it, the last correction and the last answer winning,
/// and one for an id the file does not hold is ignored. A line that does not parse (a torn last line after a crash, a line of a later version, an
/// oversized one) is skipped, and the next append starts on a new line; so is a line of a kind the reader does not know (a later build's), since
/// every key it knows is absent from it, or names an entry it applies nothing to. The picture of an entry is `<night>/<id>.jpg` in the camera's
/// folder, and the small one made from it for the page's grid (once: when the picture is written, or when the page first asks; `SkyLogStore+Thumbnails.swift`) is `<night>/<id>.thumb.jpg`
/// beside it. The capped lines of an hour add up (a detector that restarted in the hour writes one for each part; `at` is when each was written).
///
/// Writes run on one serial queue and never wait for a drive: lines (and pictures) that cannot be written wait, at most `maximumPending`
/// (the oldest dropped first, never the one being written) and `maximumPendingStillBytes` of pictures; `retry()` tries again. A read sees what
/// waits as well as what is in the file. Nothing here creates the recordings folder. `.sky`, a camera's folder, a night's file and its folder of
/// pictures are never written, read or pruned through a link: a write that finds one is given up, not waited on. The place of the box is in none
/// of it.
final class SkyLogStore: Sendable {
    static let directoryName = ".sky"
    static let fileExtension = "jsonl"
    static let stillExtension = "jpg"
    static let version = 1
    /// The most of a night's file a read looks at (the newest part when it is larger).
    static let maximumReadBytes = 16 * 1_048_576
    /// Lines and pictures waiting for the drive: beyond this the oldest are dropped.
    static let maximumPending = 1_000
    /// A line, its line break included, is not written or read when it is longer than this.
    static let maximumLineBytes = 65_536
    /// A picture is not kept when it is larger than this; the pictures that wait for the drive hold at most `maximumPendingStillBytes` in all.
    static let maximumStillBytes = 2 * 1_048_576
    static let maximumPendingStillBytes = 16 * 1_048_576
    static let dayMs: Int64 = 86_400_000

    /// One line of a night's file: `v` and one of the rest.
    struct Line: Codable, Equatable, Sendable {
        struct Correction: Codable, Equatable, Sendable {
            var label: SkyCorrection
            var at: Date
        }

        /// An hour's lights that were not logged: the hour, how many, and when the line was written.
        struct Capped: Codable, Equatable, Sendable {
            var hour: Date
            var count: Int
            var at: Date
        }

        var v: Int
        var entry: SkyEntry?
        var id: String?
        var correction: Correction?
        var ai: SkyAIAnswer?
        var alerted: Bool?
        var still: Bool?
        var conditions: SkyConditions?
        var capped: Capped?

        init(v: Int, entry: SkyEntry? = nil, id: String? = nil, correction: Correction? = nil, ai: SkyAIAnswer? = nil, alerted: Bool? = nil,
             still: Bool? = nil, conditions: SkyConditions? = nil, capped: Capped? = nil) {
            self.v = v
            self.entry = entry
            self.id = id
            self.correction = correction
            self.ai = ai
            self.alerted = alerted
            self.still = still
            self.conditions = conditions
            self.capped = capped
        }
    }

    /// Something in the way that is not the drive's fault (a link where a folder or a file belongs): given up, not waited on.
    private enum Refusal: Error { case linkInTheWay }

    private enum Payload: Sendable {
        case line(Data)
        case still(Data, id: String)
    }

    private struct Pending: Sendable {
        /// Given in order under the lock: an item leaves the queue by its number once it is written, wherever it is in the queue then.
        var sequence: UInt64
        var folder: URL
        var camera: UUID
        var night: String
        var payload: Payload

        var stillBytes: Int {
            if case .still(let jpeg, _) = payload { return jpeg.count }
            return 0
        }
    }

    private struct State {
        var pending: [Pending] = []
        var nextSequence: UInt64 = 0
        /// The item being written now: a new folder or the cap may take it out of `pending` meanwhile, but the cap never counts it as lost.
        var inFlight: UInt64?
        var writing = false
        var dropped = 0
        var failing = false
    }

    /// Appends whole lines to a night's file (`SkyLogStore.append`; a test may slow it down or make it fail).
    typealias Append = @Sendable (_ data: Data, _ folder: URL, _ camera: UUID, _ night: String) throws -> Void
    /// Writes an entry's picture (`SkyLogStore.writeStillFile`).
    typealias WriteStill = @Sendable (_ jpeg: Data, _ folder: URL, _ camera: UUID, _ night: String, _ id: String) throws -> Void

    /// Held while a picture is moved into place (and its thumbnail removed) and while a thumbnail is checked against the picture it was made from and
    /// moved into place, so that a thumbnail is never kept for a picture it was not made from. A few file operations at a time, never a wait for anything else.
    static let pictureMoves = Mutex<Void>(())

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "CameraBridge.NVR.sky", qos: .utility)
    private let log: ArchiveStoreLog
    private let appender: Append
    private let stillWriter: WriteStill

    init(log: ArchiveStoreLog, append: @escaping Append = { try SkyLogStore.append($0, folder: $1, camera: $2, night: $3) },
         writeStill: @escaping WriteStill = { try SkyLogStore.writeStillFile($0, folder: $1, camera: $2, night: $3, id: $4) }) {
        self.log = log
        appender = append
        stillWriter = writeStill
    }

    // MARK: Writing

    /// Records a light in `night`'s file of its camera (nil `folder`: no place for recordings is chosen, nothing is kept). The entry is kept
    /// within bounds first (`bounded`): a path of at most 64 points, text cut to length, an end that is not before the start; one whose id is
    /// not safe in a path, or whose start is not a time, is not kept. Returns at once; the line reaches the drive on the log's queue.
    func record(_ entry: SkyEntry, night: String, folder: URL?) {
        guard let folder, Self.isValidNight(night), let entry = Self.bounded(entry) else { return }
        guard let data = line(Line(v: Self.version, entry: entry), what: "an entry") else { return }
        enqueue(.line(data), folder: folder, camera: entry.camera, night: night)
    }

    /// A person's word on an entry ("That was a bird"), at `at`. The last one of an id wins.
    func recordCorrection(_ correction: SkyCorrection, entryID: String, camera: UUID, night: String, folder: URL?, at: Date) {
        guard let folder, Self.isValidNight(night), SkyEntry.isValidID(entryID) else { return }
        let line = Line(v: Self.version, id: entryID, correction: Line.Correction(label: correction, at: Self.millisecond(at)))
        if let data = self.line(line, what: "a correction") { enqueue(.line(data), folder: folder, camera: camera, night: night) }
    }

    /// The AI's answer about an entry. The last one of an id wins.
    func recordAI(_ answer: SkyAIAnswer, entryID: String, camera: UUID, night: String, folder: URL?) {
        guard let folder, Self.isValidNight(night), SkyEntry.isValidID(entryID) else { return }
        let line = Line(v: Self.version, id: entryID, ai: Self.bounded(answer))
        if let data = self.line(line, what: "an answer") { enqueue(.line(data), folder: folder, camera: camera, night: night) }
    }

    /// The entry raised an alert.
    func recordAlert(entryID: String, camera: UUID, night: String, folder: URL?) {
        guard let folder, Self.isValidNight(night), SkyEntry.isValidID(entryID) else { return }
        if let data = line(Line(v: Self.version, id: entryID, alerted: true), what: "an alert") { enqueue(.line(data), folder: folder, camera: camera, night: night) }
    }

    /// The entry's picture was made later, from the camera's recording (Ruling S31: it is written with `writeStill` first, on the same queue). The
    /// entry then reads as having one, as a correction applies to it.
    func recordStill(entryID: String, camera: UUID, night: String, folder: URL?) {
        guard let folder, Self.isValidNight(night), SkyEntry.isValidID(entryID) else { return }
        if let data = line(Line(v: Self.version, id: entryID, still: true), what: "a picture's line") {
            enqueue(.line(data), folder: folder, camera: camera, night: night)
        }
    }

    /// `hour.count` more lights that nothing explains were followed in the clock hour that began at `hour.hour` than the camera logs
    /// (`SkyLightFilter.unexplainedPerHour`); `at` is now, so that two lines of one hour (a detector that restarted in it) are two.
    func recordCapped(_ hour: SkyCappedHour, camera: UUID, night: String, folder: URL?, at: Date) {
        guard let folder, Self.isValidNight(night), hour.count > 0, hour.hour.timeIntervalSince1970.isFinite, at.timeIntervalSince1970.isFinite else { return }
        let capped = Line.Capped(hour: Self.millisecond(hour.hour), count: hour.count, at: Self.millisecond(at))
        if let data = line(Line(v: Self.version, capped: capped), what: "an hour's count") { enqueue(.line(data), folder: folder, camera: camera, night: night) }
    }

    /// How the sky was for a stretch of time.
    func recordConditions(_ conditions: SkyConditions, camera: UUID, night: String, folder: URL?) {
        guard let folder, Self.isValidNight(night), conditions.from.timeIntervalSince1970.isFinite, conditions.to.timeIntervalSince1970.isFinite else { return }
        var conditions = conditions
        conditions.from = Self.millisecond(conditions.from)
        conditions.to = max(conditions.from, Self.millisecond(conditions.to))
        if let data = line(Line(v: Self.version, conditions: conditions), what: "the conditions") { enqueue(.line(data), folder: folder, camera: camera, night: night) }
    }

    /// The picture of an entry (a JPEG of the camera's original picture), in `<night>/<id>.jpg` beside the log. One over `maximumStillBytes`, or
    /// empty, is not kept. The same entry again replaces it.
    func writeStill(_ jpeg: Data, entryID: String, camera: UUID, night: String, folder: URL?) {
        guard let folder, Self.isValidNight(night), SkyEntry.isValidID(entryID), !jpeg.isEmpty else { return }
        guard jpeg.count <= Self.maximumStillBytes else {
            log.debug("A Sky Watcher picture was not kept: it was \(jpeg.count) bytes, over the limit of \(Self.maximumStillBytes)")
            return
        }
        enqueue(.still(jpeg, id: entryID), folder: folder, camera: camera, night: night)
    }

    /// `line` as a line of the file, or nil (and a debug line) when it is over `maximumLineBytes` or cannot be written as JSON.
    private func line(_ line: Line, what: String) -> Data? {
        guard var data = try? Self.makeEncoder().encode(line) else {
            log.debug("Sky Watcher \(what) was not kept: it could not be written")
            return nil
        }
        data.append(0x0A)
        guard data.count <= Self.maximumLineBytes else {
            log.debug("Sky Watcher \(what) was not kept: its line was \(data.count) bytes, over the limit of \(Self.maximumLineBytes)")
            return nil
        }
        return data
    }

    /// Keys sorted and slashes plain (a stable file), times as whole milliseconds (like every time in the events' files), and a number that is
    /// not one (a measure that came out as NaN) as a word that reads back: one odd number never costs a light.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ArchiveTime.ms(date))
        }
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            ArchiveTime.date(ms: Int64((try decoder.singleValueContainer().decode(Double.self)).rounded()))
        }
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    /// `date` to the millisecond, as the file keeps it (so that what is read back is exactly what was recorded).
    static func millisecond(_ date: Date) -> Date {
        ArchiveTime.date(ms: ArchiveTime.ms(date))
    }

    /// The entry as it is kept, or nil when it cannot be: an id that is not safe in a path, or a start that is not a time. Times to the
    /// millisecond; an end that is not a time or is before the start is the start; the path without points that are not numbers, then at most 64 of
    /// them, evenly picked, the first and the last among them; the detail, the AI's sentence, model and kind cut to length; at most 8 reasons, each
    /// cut to length; and no group (the lights that moved together are found as the log is read: `SkyFormations`).
    static func bounded(_ entry: SkyEntry) -> SkyEntry? {
        guard SkyEntry.isValidID(entry.id), entry.start.timeIntervalSince1970.isFinite, abs(entry.start.timeIntervalSince1970) < 1e11 else { return nil }
        var entry = entry
        entry.start = millisecond(entry.start)
        entry.end = entry.end.timeIntervalSince1970.isFinite && abs(entry.end.timeIntervalSince1970) < 1e11 ? max(entry.start, millisecond(entry.end)) : entry.start
        let points = entry.path.filter { $0.t.isFinite && $0.x.isFinite && $0.y.isFinite }
        if points.count > SkyPathPoint.maximumPerEntry {
            let last = points.count - 1, steps = SkyPathPoint.maximumPerEntry - 1
            entry.path = (0...steps).map { points[$0 * last / steps] }
        } else {
            entry.path = points
        }
        entry.detail = entry.detail.map { String($0.prefix(SkyEntry.maximumDetailLength)) }
        entry.ai = entry.ai.map(bounded)
        if let ratio = entry.speedVsPlanes, !ratio.isFinite { entry.speedVsPlanes = nil }
        entry.reasons = entry.reasons.prefix(SkyEntry.maximumReasons).map { String($0.prefix(SkyEntry.maximumReasonLength)) }
        // A group is found as the log is read (`SkyFormations`), never kept.
        entry.group = nil
        return entry
    }

    static func bounded(_ answer: SkyAIAnswer) -> SkyAIAnswer {
        SkyAIAnswer(kind: String(answer.kind.prefix(SkyAIAnswer.maximumKindLength)), sentence: String(answer.sentence.prefix(SkyAIAnswer.maximumSentenceLength)),
                    model: String(answer.model.prefix(SkyAIAnswer.maximumModelLength)),
                    at: answer.at.timeIntervalSince1970.isFinite ? millisecond(answer.at) : Date(timeIntervalSince1970: 0))
    }

    /// "2026-10-24": a date as a night's name (four digits, a month 01 to 12, a day 01 to 31). The name is in a path, so nothing else is taken.
    static func isValidNight(_ name: String) -> Bool {
        ArchiveLayout.isDateDirectoryName(name)
    }

    /// Puts an item last in the queue, giving up what waited for another place first.
    private func enqueue(_ payload: Payload, folder: URL, camera: UUID, night: String) {
        let schedule = state.withLock { state -> Bool in
            Self.follow(folder, in: &state)
            state.nextSequence += 1
            state.pending.append(Pending(sequence: state.nextSequence, folder: folder, camera: camera, night: night, payload: payload))
            return Self.cappedAndReady(&state)
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// The place for recordings changed: what waited for the old one is given up.
    private static func follow(_ folder: URL, in state: inout State) {
        let path = ArchiveVolume.path(of: folder)
        state.pending.removeAll { ArchiveVolume.path(of: $0.folder) != path }
    }

    /// Drops the oldest items beyond `maximumPending`, and the oldest pictures beyond `maximumPendingStillBytes` (never the item being written),
    /// then says whether the caller must start the drain (items wait and none is being written).
    private static func cappedAndReady(_ state: inout State) -> Bool {
        let inFlight = state.inFlight
        var excess = state.pending.count - maximumPending
        if excess > 0 {
            let before = state.pending.count
            state.pending = state.pending.filter { item in
                guard excess > 0, item.sequence != inFlight else { return true }
                excess -= 1
                return false
            }
            state.dropped += before - state.pending.count
        }
        var bytes = state.pending.reduce(0) { $0 + $1.stillBytes }
        while bytes > maximumPendingStillBytes, let index = state.pending.firstIndex(where: { $0.stillBytes > 0 && $0.sequence != inFlight }) {
            bytes -= state.pending[index].stillBytes
            state.pending.remove(at: index)
            state.dropped += 1
        }
        guard !state.pending.isEmpty, !state.writing else { return false }
        state.writing = true
        return true
    }

    /// Writes what is pending, in order, until nothing is or a write fails (the rest waits for the next item or `retry`). An item that cannot
    /// be written for a reason that will not go away (a link in the way) is given up and the next one tried.
    private func drain() {
        while true {
            let next = state.withLock { state -> Pending? in
                guard let first = state.pending.first else {
                    state.writing = false
                    state.inFlight = nil
                    return nil
                }
                state.inFlight = first.sequence
                return first
            }
            guard let next else { return }
            do {
                switch next.payload {
                case .line(let data): try appender(data, next.folder, next.camera, next.night)
                case .still(let jpeg, let id): try stillWriter(jpeg, next.folder, next.camera, next.night, id)
                }
                let (recovered, dropped) = state.withLock { state -> (Bool, Int) in
                    // By its number, not its place: while it was written, a new folder may have taken it out of the queue.
                    if let index = state.pending.firstIndex(where: { $0.sequence == next.sequence }) { state.pending.remove(at: index) }
                    state.inFlight = nil
                    defer { state.failing = false; state.dropped = 0 }
                    return (state.failing, state.dropped)
                }
                if recovered || dropped > 0 { log.info("Sky Watcher log entries are written again\(dropped > 0 ? " (\(dropped) were lost)" : "")") }
            } catch Refusal.linkInTheWay {
                state.withLock { state in
                    if let index = state.pending.firstIndex(where: { $0.sequence == next.sequence }) { state.pending.remove(at: index) }
                    state.inFlight = nil
                }
                log.warning("A Sky Watcher log entry was not kept: a link is in the way of the .sky folder")
            } catch {
                let first = state.withLock { state -> Bool in
                    state.writing = false
                    state.inFlight = nil
                    defer { state.failing = true }
                    return !state.failing
                }
                if first { log.warning("Sky Watcher log entries could not be written (\(ArchiveErrors.brief(error))); they wait for the drive") }
                return
            }
        }
    }

    /// Tries what waits again (the janitor calls it every pass).
    func retry() {
        let schedule = state.withLock { state -> Bool in
            guard !state.pending.isEmpty, !state.writing else { return false }
            state.writing = true
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// Items not written yet (tests).
    var pendingCount: Int { state.withLock { $0.pending.count } }

    /// Waits until the queue has run what was scheduled before (tests).
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in queue.async { continuation.resume() } }
    }

    // MARK: Files

    /// `<folder>/.sky/<camera>/<night>.jsonl`.
    static func nightFile(folder: URL, camera: UUID, night: String) -> URL {
        cameraFolder(folder: folder, camera: camera).appending(path: "\(night).\(fileExtension)", directoryHint: .notDirectory)
    }

    /// `<folder>/.sky/<camera>/<night>/<id>.jpg`.
    static func stillFile(folder: URL, camera: UUID, night: String, id: String) -> URL {
        stillsFolder(folder: folder, camera: camera, night: night).appending(path: "\(id).\(stillExtension)", directoryHint: .notDirectory)
    }

    static func skyFolder(_ folder: URL) -> URL { folder.appending(path: directoryName, directoryHint: .isDirectory) }

    static func cameraFolder(folder: URL, camera: UUID) -> URL {
        skyFolder(folder).appending(path: camera.uuidString, directoryHint: .isDirectory)
    }

    static func stillsFolder(folder: URL, camera: UUID, night: String) -> URL {
        cameraFolder(folder: folder, camera: camera).appending(path: night, directoryHint: .isDirectory)
    }

    /// The recordings folder is there (a link to one counts: it is the folder the owner chose).
    static func folderExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Makes `directory` (mode 0700) when it is missing; a real folder is left; anything else (a file, a link) is in the way.
    private static func prepareFolder(_ directory: URL) throws {
        switch ArchiveEventLog.entryType(directory) {
        case .typeDirectory?:
            return
        case .none:
            do {
                try FileManager.default.createDirectory(atPath: ArchiveVolume.path(of: directory), withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                guard ArchiveEventLog.entryType(directory) == .typeDirectory else { throw error }   // made meanwhile by another writer
            }
        default:
            throw Refusal.linkInTheWay
        }
    }

    /// Appends whole lines to a night's file, making `.sky` and the camera's folder when they are missing (never the recordings folder). When
    /// the file does not end in a line break (a torn last line), the new lines start on a line of their own.
    static func append(_ data: Data, folder: URL, camera: UUID, night: String) throws {
        guard isValidNight(night) else { throw CocoaError(.fileWriteInvalidFileName) }
        guard folderExists(folder) else { throw CocoaError(.fileNoSuchFile) }
        try prepareFolder(skyFolder(folder))
        try prepareFolder(cameraFolder(folder: folder, camera: camera))
        let file = nightFile(folder: folder, camera: camera, night: night)
        let manager = FileManager.default
        switch ArchiveEventLog.entryType(file) {
        case .none:
            guard manager.createFile(atPath: file.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        case .typeRegular?:
            break
        default:
            throw Refusal.linkInTheWay
        }
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var bytes = Data()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { bytes.append(0x0A) }
            _ = try handle.seekToEnd()
        }
        bytes.append(data)
        try handle.write(contentsOf: bytes)
    }

    /// Writes an entry's picture: into a 0600 temporary file in the night's folder, then moved over any earlier picture of the entry.
    static func writeStillFile(_ jpeg: Data, folder: URL, camera: UUID, night: String, id: String) throws {
        guard isValidNight(night), SkyEntry.isValidID(id) else { throw CocoaError(.fileWriteInvalidFileName) }
        guard folderExists(folder) else { throw CocoaError(.fileNoSuchFile) }
        try prepareFolder(skyFolder(folder))
        try prepareFolder(cameraFolder(folder: folder, camera: camera))
        let directory = stillsFolder(folder: folder, camera: camera, night: night)
        try prepareFolder(directory)
        let file = stillFile(folder: folder, camera: camera, night: night, id: id)
        let manager = FileManager.default
        let existing = ArchiveEventLog.entryType(file)
        guard existing == nil || existing == .typeRegular else { throw Refusal.linkInTheWay }
        let temporary = directory.appending(path: ".\(id).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        guard manager.createFile(atPath: temporary.path(percentEncoded: false), contents: jpeg, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            // Together with the thumbnail's removal and not at the same time as a thumbnail is kept (`storeThumbnail`): the thumbnail made from the picture
            // that is replaced goes, and one that was being made from it is refused.
            try pictureMoves.withLock { _ in
                if existing == .typeRegular { try manager.removeItem(at: file) }
                try manager.moveItem(at: temporary, to: file)
                removeThumbnail(folder: folder, camera: camera, night: night, id: id)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    // MARK: Reading

    /// The entries and the conditions of one camera's night, in the order of their time (`contents`).
    func read(camera: UUID, night: String, folder: URL) -> (entries: [SkyEntry], conditions: [SkyConditions]) {
        let read = contents(camera: camera, night: night, folder: folder)
        return (read.entries, read.conditions)
    }

    /// The lines of one camera's night that wait for the drive, in the order they were queued.
    func waitingLines(camera: UUID, night: String, folder: URL) -> [Data] {
        let path = ArchiveVolume.path(of: folder)
        return state.withLock { state in
            state.pending.compactMap { item -> Data? in
                guard item.camera == camera, item.night == night, ArchiveVolume.path(of: item.folder) == path, case .line(let data) = item.payload else { return nil }
                return data
            }
        }
    }

    /// Everything one camera's night holds, in the order of its time: the lines of the file in the order written, and then the ones still waiting
    /// for the drive, each applied to its entry (the first entry line of an id wins; the last correction and the last answer win; a picture made
    /// later sets `hasStill`; a line for an id the file does not hold is ignored), the conditions and the capped hours. Blocking disk work (the
    /// engine runs it on the store's read queue). A missing file, or one reached through a link, is nothing. A file larger than
    /// `maximumReadBytes` is read from its end: a night is filed after the day before it, so a day that flooded the file does not hide its night.
    func contents(camera: UUID, night: String, folder: URL) -> SkyLogContents {
        guard Self.isValidNight(night) else { return SkyLogContents() }
        // What waits is looked at before the file, so a line that is written meanwhile is read twice (harmless) and never not at all.
        let waiting = waitingLines(camera: camera, night: night, folder: folder)
        var lines: [Data] = []
        if let data = Self.readTail(Self.nightFile(folder: folder, camera: camera, night: night), folder: folder, camera: camera) {
            lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        }
        lines += waiting
        return Self.parse(lines, camera: camera)
    }

    /// The lines read, applied: see `contents`. A capped line read twice (it waited, and then it was in the file) counts once; the distinct
    /// lines of an hour add up.
    static func parse(_ lines: [Data], camera: UUID) -> SkyLogContents {
        let decoder = makeDecoder()
        var entries: [SkyEntry] = []
        var position: [String: Int] = [:]
        var conditions: [SkyConditions] = []
        var capped: [Line.Capped] = []
        for raw in lines {
            guard raw.count <= maximumLineBytes, let line = try? decoder.decode(Line.self, from: raw), line.v == version else { continue }
            if let entry = line.entry {
                guard entry.camera == camera, SkyEntry.isValidID(entry.id), position[entry.id] == nil else { continue }
                position[entry.id] = entries.count
                entries.append(entry)
            } else if let id = line.id, let index = position[id] {
                if let correction = line.correction { entries[index].correction = correction.label }
                if let answer = line.ai { entries[index].ai = answer }
                if line.alerted == true { entries[index].alerted = true }
                if line.still == true { entries[index].hasStill = true }
            } else if let span = line.conditions, !conditions.contains(span) {
                conditions.append(span)
            } else if let hour = line.capped, hour.count > 0, !capped.contains(hour) {
                capped.append(hour)
            }
        }
        entries.sort { ($0.start, $0.id) < ($1.start, $1.id) }
        conditions.sort { ($0.from, $0.to) < ($1.from, $1.to) }
        let hours = Dictionary(grouping: capped, by: \.hour).map { SkyCappedHour(hour: $0.key, count: $0.value.reduce(0) { $0 + $1.count }) }
        return SkyLogContents(entries: entries, conditions: conditions, capped: hours.sorted { $0.hour < $1.hour })
    }

    /// The JPEG of an entry, or nil when there is none (or the name is not a night's or an id, or a link is in the way, or the file is larger
    /// than a picture is kept). Blocking disk work.
    func still(camera: UUID, night: String, entryID: String, folder: URL) -> Data? {
        guard Self.isValidNight(night), SkyEntry.isValidID(entryID) else { return nil }
        let file = Self.stillFile(folder: folder, camera: camera, night: night, id: entryID)
        guard Self.isReal(Self.skyFolder(folder)), Self.isReal(Self.cameraFolder(folder: folder, camera: camera)),
              Self.isReal(Self.stillsFolder(folder: folder, camera: camera, night: night)),
              let attributes = CatalogLoader.attributes(file), attributes.type == .typeRegular, attributes.size <= UInt64(Self.maximumStillBytes),
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        return try? handle.readToEnd()
    }

    static func isReal(_ directory: URL) -> Bool { ArchiveEventLog.entryType(directory) == .typeDirectory }

    /// The file, or its last `maximumReadBytes` from the first whole line on; nil when it is not a regular file in real folders.
    static func readTail(_ file: URL, folder: URL, camera: UUID) -> Data? {
        guard isReal(skyFolder(folder)), isReal(cameraFolder(folder: folder, camera: camera)),
              let attributes = CatalogLoader.attributes(file), attributes.type == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard attributes.size > UInt64(maximumReadBytes) else { return try? handle.readToEnd() ?? Data() }
        guard (try? handle.seek(toOffset: attributes.size - UInt64(maximumReadBytes))) != nil,
              let tail = try? handle.read(upToCount: maximumReadBytes) else { return nil }
        guard let firstBreak = tail.firstIndex(of: 0x0A) else { return Data() }
        return tail[tail.index(after: firstBreak)...]
    }

    // MARK: Retention

    /// Deletes the nights whose date and the day after it are over by `cutoffMs` (a night named D lasts to the morning of D+1, which can end late in
    /// D+1's UTC day, so it goes when D+2 begins at or before the cutoff: nothing newer than the cutoff goes), each with its folder of pictures,
    /// and a folder of pictures whose log is gone. Camera folders stay (a write may be making a file in one). Returns how many nights went.
    /// Blocking disk work (the store runs it on its control queue). Never follows a link (`.sky`, a camera's folder, a night's file or folder that
    /// is one is left alone); deletes only regular files named `yyyy-MM-dd.jsonl` and folders named `yyyy-MM-dd` in folders named by a camera's
    /// UUID.
    static func prune(folder: URL, cutoffMs: Int64, remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> Int {
        let sky = skyFolder(folder)
        guard isReal(sky), let cameras = CatalogLoader.entries(in: sky) else { return 0 }
        var removed = 0
        for camera in cameras where !camera.isSymbolicLink && camera.isDirectory && UUID(uuidString: camera.name) != nil {
            guard isReal(camera.url), let items = CatalogLoader.entries(in: camera.url) else { continue }
            var nights: [String: [CatalogLoader.Entry]] = [:]
            for item in items where !item.isSymbolicLink {
                let name: String
                if item.isRegularFile, item.name.hasSuffix("." + fileExtension) {
                    name = String(item.name.dropLast(fileExtension.count + 1))
                } else if item.isDirectory {
                    name = item.name
                } else {
                    continue
                }
                guard let dayStart = ArchiveEventLog.dayStartMs(name), dayStart + 2 * dayMs <= cutoffMs else { continue }
                nights[name, default: []].append(item)
            }
            for (_, group) in nights {
                var any = false
                // The pictures first, then the log: a prune that is cut short never leaves pictures of a night whose log is gone.
                for item in group.sorted(by: { $0.isDirectory && !$1.isDirectory }) {
                    let type: FileAttributeType = item.isDirectory ? .typeDirectory : .typeRegular
                    guard ArchiveEventLog.entryType(item.url) == type else { continue }
                    if (try? remove(item.url)) != nil { any = true }
                }
                if any { removed += 1 }
            }
        }
        return removed
    }
}

/// What a camera's night file holds, read (`SkyLogStore.contents`): its entries with the lines after them applied, the conditions, and the hours
/// in which more lights were followed than logged, oldest first, each hour's lines added up.
struct SkyLogContents: Sendable, Equatable {
    var entries: [SkyEntry] = []
    var conditions: [SkyConditions] = []
    var capped: [SkyCappedHour] = []
}

// MARK: - A camera's pictures on the drive (Ruling S27)

extension SkyLogStore {
    /// Keeps each camera's pictures under `maximumBytes` by deleting the oldest nights' folders of pictures first, and says how many nights'
    /// pictures went and how many bytes that freed. The recordings' size rule never counts what the sky log keeps, and recording pauses on every
    /// camera when the drive is full, so the pictures keep to a limit of their own (`SkyLightFilter.stillBytesPerCamera`).
    ///
    /// A picture's thumbnail (`<id>.thumb.jpg`, `SkyLogStore+Thumbnails.swift`) is a file of the same folder: it counts, and goes with its night.
    /// Only the regular files directly in a folder named `yyyy-MM-dd` in a camera's folder count, and only that folder goes: the night's log
    /// (`<night>.jsonl`) and the recordings are never touched, and an entry whose picture went simply has no picture any more (`skyStill` answers
    /// `noStill`). The newest night's folder is never taken, whatever the limit: it is the one pictures are being written to. No link is followed
    /// (`.sky`, a camera's folder, or a night's folder that is one is left alone and counts for nothing). A folder that cannot be deleted stays,
    /// is not counted, and is tried again next time; the next oldest goes in its place. Blocking disk work (the store runs it on its control
    /// queue).
    @discardableResult
    static func pruneStills(folder: URL, maximumBytes: UInt64, remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) })
        -> (nights: Int, bytes: UInt64) {
        let sky = skyFolder(folder)
        guard isReal(sky), let cameras = CatalogLoader.entries(in: sky) else { return (0, 0) }
        var nights = 0
        var freed: UInt64 = 0
        for camera in cameras where !camera.isSymbolicLink && camera.isDirectory && UUID(uuidString: camera.name) != nil {
            guard isReal(camera.url), let items = CatalogLoader.entries(in: camera.url) else { continue }
            var stills: [(name: String, url: URL, bytes: UInt64)] = []
            for item in items where item.isDirectory && isValidNight(item.name) {   // a link is neither a directory nor a regular file here
                let files = CatalogLoader.entries(in: item.url) ?? []
                stills.append((item.name, item.url, files.filter(\.isRegularFile).reduce(0) { $0 + $1.size }))
            }
            stills.sort { $0.name < $1.name }
            var total = stills.reduce(0) { $0 + $1.bytes }
            for night in stills.dropLast() where total > maximumBytes {
                guard ArchiveEventLog.entryType(night.url) == .typeDirectory, (try? remove(night.url)) != nil else { continue }
                total -= night.bytes
                freed += night.bytes
                nights += 1
            }
        }
        return (nights, freed)
    }
}

// MARK: - Filing by time (Ruling S4)

/// Where an instant is filed, and what hours a log's view spans, by `SkyNight`'s sunsets and sunrises at the observer: a night (sunset to sunrise)
/// is named by the local date of its sunset, a day (sunrise to sunset) by its own local date, and the day after night N is day N+1. A night's file
/// holds that night and the day before it, since both carry the date: the log named D reaches from the sunrise of D to the sunrise of D+1.
extension SkyNight {
    /// The log `date` is filed in: the night it is in, by that night's name; otherwise the day it is in, by the local date of `date`. (Where the
    /// Sun does not set or does not rise there is no night, and a day is the local day.)
    static func logName(for date: Date, observer: SkyObserver, zone: TimeZone) -> String {
        let night = name(containing: date, observer: observer, zone: zone)
        let window = self.window(named: night, observer: observer, zone: zone)
        let span = self.span(window, view: .night, zone: zone)
        if window.sunset != nil, date >= span.lowerBound, date < span.upperBound { return night }
        return dayName(date, zone: zone)
    }

    /// The hours of the view of the log named `name`: the night from sunset to sunrise; the day from the sunrise that ends the night before it to
    /// the sunset that begins the night (the local day, midnight to midnight, where the Sun does not rise or set). A name that is not a date has
    /// one instant.
    static func logSpan(named name: String, view: SkyLogView, observer: SkyObserver, zone: TimeZone) -> ClosedRange<Date> {
        let window = self.window(named: name, observer: observer, zone: zone)
        let whole = span(window, view: view, zone: zone)
        guard view == .day, let sunset = window.sunset, let day = localDay(named: name, zone: zone) else { return whole }
        let before = self.window(named: dayName(day.start.addingTimeInterval(-1), zone: zone), observer: observer, zone: zone)
        guard let sunrise = before.sunrise, sunrise < sunset else { return whole }
        return sunrise...sunset
    }

    /// The log before the one named `name`: the one named by the local date a day earlier; nil for a name that is not a date.
    static func logName(before name: String, zone: TimeZone) -> String? {
        guard let day = localDay(named: name, zone: zone) else { return nil }
        return dayName(day.start.addingTimeInterval(-1), zone: zone)
    }

    /// The log to show when none is asked for: the night in progress or the one that ended this morning; or, for the day view, the log `now` is
    /// filed in (today's day, or the day that ended at sunset).
    static func latestLogName(view: SkyLogView, now: Date, observer: SkyObserver, zone: TimeZone) -> String {
        switch view {
        case .night: name(containing: now, observer: observer, zone: zone)
        case .day: logName(for: now, observer: observer, zone: zone)
        }
    }
}
