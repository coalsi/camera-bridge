import Foundation
import MediaCore

/// The remap maps of the snapshots' straightening ("Straighten the picture"), kept from one snapshot to the next: a camera's `/live`
/// preview asks for a picture every 700 ms, and each one needs the same four map images (about 9 MB at 1280 × 720, 16 MB at 1920 × 852)
/// that were made for the one before. One set (a `RemapScratch`) is kept for each picture size and correction, so the cameras that take
/// turns, and Apple Home's size beside the web's, never rewrite each other's maps. The `capacity` most recently used sets are kept; a
/// set pushed out is removed from the disk at once, or, when a snapshot's ffmpeg child is still starting up on it, as soon as that snapshot
/// is done. A set that cannot be written is dropped, so the next snapshot makes it afresh. Everything is removed with the cache.
final class SnapshotMapCache: @unchecked Sendable {
    /// How many sets are kept (every size of every corrected camera asks for one: Apple Home's and the web's, a few cameras).
    static let defaultCapacity = 6

    private struct Key: Hashable {
        var correction: PictureCorrection
        var width: Int
        var height: Int
    }

    private final class Entry {
        let key: Key
        let scratch: RemapScratch
        var users = 0
        var retired = false

        init(key: Key, scratch: RemapScratch) {
            self.key = key
            self.scratch = scratch
        }
    }

    private let parent: URL?
    private let capacity: Int
    private let lock = NSLock()
    /// The sets, least recently used first.
    private var entries: [Entry] = []

    init(parent: URL?, capacity: Int = SnapshotMapCache.defaultCapacity) {
        self.parent = parent
        self.capacity = max(1, capacity)
    }

    deinit {
        for entry in entries { entry.scratch.remove() }
    }

    /// The sets kept now (tests).
    var count: Int { lock.withLock { entries.count } }

    /// Runs `body` with the four maps of `correction` for a `width × height` picture on disk: made the first time they are asked for,
    /// the same files after that. The set is not removed while `body` runs, whatever else is asked for meanwhile. `body` runs outside
    /// the cache's lock, so snapshots of other pictures are not held up.
    func withMaps<Output>(for correction: PictureCorrection, width: Int, height: Int, _ body: (RemapStage) throws -> Output) throws -> Output {
        let entry = try take(Key(correction: correction, width: width, height: height))
        defer { give(entry) }
        let stage: RemapStage
        do {
            // RemapScratch writes what the files do not hold yet, under its own lock: a second snapshot of the same set waits for the first.
            stage = try entry.scratch.stage(for: correction, width: width, height: height)
        } catch {
            drop(entry)
            throw error
        }
        return try body(stage)
    }

    /// The set of `key` (made when there is none), marked as in use and as the most recently used; the oldest sets past the capacity go.
    private func take(_ key: Key) throws -> Entry {
        lock.lock()
        defer { lock.unlock() }
        let entry: Entry
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entry = entries.remove(at: index)
        } else {
            entry = Entry(key: key, scratch: try RemapScratch(parent: parent))
        }
        entry.users += 1
        entries.append(entry)
        while entries.count > capacity {
            let oldest = entries.removeFirst()
            oldest.retired = true
            if oldest.users == 0 { oldest.scratch.remove() }
        }
        return entry
    }

    private func give(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        entry.users -= 1
        if entry.retired && entry.users == 0 { entry.scratch.remove() }
    }

    /// Takes a set that could not be written out of the cache (the files it holds are removed once nobody uses it).
    private func drop(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        if let index = entries.firstIndex(where: { $0 === entry }) { entries.remove(at: index) }
        entry.retired = true
    }
}
