import Foundation

/// What the camera's recording gave for a picture of the sky log made later (`SkyCameraDetector.Context.recordedStill`, Ruling S31).
enum SkyRecordedStill: Sendable, Equatable {
    /// The picture: the recording's keyframe nearest the time, made as a live one is (the camera's own picture, at most 1920 wide).
    case made(Data)
    /// Nothing was recorded then, or it is gone (retention took it, a gap, a camera that does not record): not asked again.
    case gone
    /// Not now: the recording is not written yet, the recordings are loading, or the drive does not answer. Asked again later, a few times.
    case later
    /// The recording is there, but no picture could be made of it: given up.
    case failed
}

/// The pictures the sky log has not got, made later from the camera's recording (Ruling S31: the owner asked that every unexplained light keep
/// its picture). A light is logged without one when the drive had no room then, when the camera's ring no longer held its middle (a long
/// track), or by a build that kept 30 an hour, or one that kept none for the rules' probable planes and satellites (before 2026-10-26). Once a
/// minute (the detector's `tick`), while the drive has room, a few of them (`perTick`) are made from the recording at the light's middle, the
/// newest first, and written as a live picture is, with a line that says so (`SkyLogStore.recordStill`: the log stays append-only, and the entry
/// then reads `hasStill`), and its small picture is asked for (`SkyCameraDetector.Context.stillWritten`).
///
/// The candidates are the entries of the log the time is filed in and of the one before it (tonight's and last night's), that want a picture
/// (`SkyLightFilter.wantsStill`: not a flight's plane or an orbit's satellite), have none, and ended at least `settle` ago (their live picture,
/// and the recorder, come first). The logs are read again when every candidate was tried and `readInterval` has passed. A light whose recording
/// is gone or makes no picture is given up quietly, and one not written yet is tried `laterTries` times at the most: no retry storm. What was
/// given up is kept in memory only, for the lights of the logs it reads, so a restart tries each once more.
struct SkyStillBackfill: Sendable {
    static let perTick = 4
    static let readInterval: TimeInterval = 600
    static let settle: TimeInterval = 60
    static let laterTries = 5

    /// One light to make a picture of: its entry, the log it is in, and its middle (the box's clock, as the recordings are).
    struct Item: Sendable, Equatable {
        var id: String
        var night: String
        var middle: Date
    }

    /// The lights waiting for a picture, the next first.
    private(set) var queue: [Item] = []
    /// Made, or given up.
    private var finished: Set<String> = []
    /// How often each was not ready yet.
    private var tries: [String: Int] = [:]
    private var readAt: Date?

    /// Whether the logs are to be read again: nothing waits, and they were not read in the last `readInterval` (or the clock went back).
    func wantsRead(at date: Date) -> Bool {
        guard queue.isEmpty else { return false }
        guard let readAt else { return true }
        return date < readAt || date.timeIntervalSince(readAt) >= Self.readInterval
    }

    /// The middle of `entry`'s time.
    static func middle(of entry: SkyEntry) -> Date {
        entry.start.addingTimeInterval(max(0, entry.end.timeIntervalSince(entry.start)) / 2)
    }

    /// The candidates of `logs` (read at `date`), newest first. `complete`: every log asked for was read, so what was given up of the lights
    /// they no longer hold can be forgotten.
    mutating func refill(_ logs: [(night: String, entries: [SkyEntry])], complete: Bool, at date: Date) {
        readAt = date
        var items: [Item] = []
        var seen = Set<String>()
        for (night, entries) in logs {
            for entry in entries {
                seen.insert(entry.id)
                let middle = Self.middle(of: entry)
                guard SkyLightFilter.wantsStill(entry.label, by: entry.by), !entry.hasStill, !finished.contains(entry.id), middle.timeIntervalSince1970.isFinite,
                      date.timeIntervalSince(middle) >= Self.settle else { continue }
                items.append(Item(id: entry.id, night: night, middle: middle))
            }
        }
        if complete {
            finished.formIntersection(seen)
            tries = tries.filter { seen.contains($0.key) }
        }
        queue = items.sorted { $0.middle > $1.middle }
    }

    /// The next light to make a picture of.
    mutating func next() -> Item? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    /// Its picture was made, or it is given up: it is not asked again.
    mutating func finish(_ item: Item) {
        finished.insert(item.id)
        tries[item.id] = nil
    }

    /// Its recording was not ready: asked again at a later read, until `laterTries`.
    mutating func notYet(_ item: Item) {
        let count = (tries[item.id] ?? 0) + 1
        if count >= Self.laterTries { finish(item) } else { tries[item.id] = count }
    }
}
