import BridgeSupport
import Foundation
import MediaCore

// The small pictures of the Sky Watcher's grid beside the log's pictures (`SkyThumbnails` makes them): `<night>/<id>.thumb.jpg` in the folder of the
// night's pictures, kept once, mode 0600, never through a link, counted in the camera's pictures (`pruneStills` counts every file of a night's
// folder) and gone with their night (a pruned night takes its folder). And what the maker reads from the log: an entry's path, for the close-up, and
// how big a night's pictures are.

/// What identifies a still as it was read: its file, its size and when it was written. A thumbnail is kept only for the still it was made from.
struct SkyStillStamp: Equatable, Sendable {
    var file: UInt64
    var size: UInt64
    var modified: Date
}

/// What `SkyLogStore.thumbnailLookup` found for an entry.
enum SkyThumbnailLookup: Equatable, Sendable {
    /// The entry has no picture (or none that can be read).
    case none
    /// Its thumbnail, kept and good.
    case thumbnail(Data)
    /// Only its picture, as it is stamped (not read: `readStill` does that): the thumbnail is to be made.
    case still(SkyStillStamp)
}

extension SkyLogStore {
    static let thumbnailSuffix = ".thumb.jpg"
    /// A thumbnail is not kept, and a file is not taken for one, when it is larger than this (they are a few KB; the limit is only a bound).
    static let maximumThumbnailBytes = 512 * 1_024
    /// A thumbnail is kept with the modification time of the picture it was made from, and is taken for that picture's while the two agree to within this
    /// (seconds): a picture replaced by something else changes its time, and a clock that was set back since does not make every thumbnail stale, as
    /// "newer than the picture" would.
    static let timeTolerance: TimeInterval = 0.001
    /// The most pictures looked at to learn how big a night's are, and how much of each (the frame header is in the first bytes).
    static let pictureProbeLimit = 8
    static let pictureProbeBytes = 128 * 1_024

    /// `<folder>/.sky/<camera>/<night>/<id>.thumb.jpg`.
    static func thumbnailFile(folder: URL, camera: UUID, night: String, id: String) -> URL {
        stillsFolder(folder: folder, camera: camera, night: night).appending(path: "\(id)\(thumbnailSuffix)", directoryHint: .notDirectory)
    }

    // MARK: The pictures

    /// What identifies the regular file at `url`; nil for anything else (nothing there, a folder, a link).
    static func stamp(of url: URL) -> SkyStillStamp? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)), values[.type] as? FileAttributeType == .typeRegular,
              let size = (values[.size] as? NSNumber)?.uint64Value, let modified = values[.modificationDate] as? Date else { return nil }
        return SkyStillStamp(file: (values[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0, size: size, modified: modified)
    }

    /// Whether `jpeg` can be a thumbnail: the start and the end of a JPEG, and not more than `maximumThumbnailBytes`.
    static func isThumbnailFile(_ jpeg: Data) -> Bool {
        jpeg.count >= 4 && jpeg.count <= maximumThumbnailBytes && jpeg.prefix(2) == Data([0xFF, 0xD8]) && jpeg.suffix(2) == Data([0xFF, 0xD9])
    }

    /// The entry's thumbnail when it is there, a regular file in real folders, good, and stamped with the picture's time (it was made from the picture that is
    /// there); else nil. Blocking disk work.
    func keptThumbnail(camera: UUID, night: String, entryID: String, folder: URL) -> Data? {
        guard Self.isValidNight(night), SkyEntry.isValidID(entryID), Self.picturesAreReal(folder: folder, camera: camera, night: night),
              let still = Self.stamp(of: Self.stillFile(folder: folder, camera: camera, night: night, id: entryID)) else { return nil }
        return Self.thumbnail(folder: folder, camera: camera, night: night, id: entryID, matching: still.modified)
    }

    private static func picturesAreReal(folder: URL, camera: UUID, night: String) -> Bool {
        isReal(skyFolder(folder)) && isReal(cameraFolder(folder: folder, camera: camera)) && isReal(stillsFolder(folder: folder, camera: camera, night: night))
    }

    private static func thumbnail(folder: URL, camera: UUID, night: String, id: String, matching modified: Date) -> Data? {
        let file = thumbnailFile(folder: folder, camera: camera, night: night, id: id)
        guard let attributes = CatalogLoader.attributes(file), attributes.type == .typeRegular, attributes.size > 0, attributes.size <= UInt64(maximumThumbnailBytes),
              abs(attributes.modified.timeIntervalSince(modified)) < timeTolerance, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(), isThumbnailFile(data) else { return nil }
        return data
    }

    /// What there is for an entry's small picture: its thumbnail, when one is kept and good; else its picture, as it is stamped (for `readStill` and
    /// `storeThumbnail`); else nothing. Only a kept thumbnail is read (a few KB). Blocking disk work (the engine runs it on the store's read queue); no link
    /// is followed.
    func thumbnailLookup(camera: UUID, night: String, entryID: String, folder: URL) -> SkyThumbnailLookup {
        guard Self.isValidNight(night), SkyEntry.isValidID(entryID), Self.picturesAreReal(folder: folder, camera: camera, night: night) else { return .none }
        guard let stamp = Self.stamp(of: Self.stillFile(folder: folder, camera: camera, night: night, id: entryID)), stamp.size > 0,
              stamp.size <= UInt64(Self.maximumStillBytes) else { return .none }
        if let kept = Self.thumbnail(folder: folder, camera: camera, night: night, id: entryID, matching: stamp.modified) { return .thumbnail(kept) }
        return .still(stamp)
    }

    /// The bytes of the picture that is stamped `stamp`: nil when the picture is not that one any more (it was replaced, or is gone), before or while it is
    /// read. The picture is stamped before it is read and again after it, so what is returned is of the picture the thumbnail is then kept for.
    /// Blocking disk work.
    func readStill(stamp: SkyStillStamp, entryID: String, camera: UUID, night: String, folder: URL) -> Data? {
        guard Self.isValidNight(night), SkyEntry.isValidID(entryID), Self.picturesAreReal(folder: folder, camera: camera, night: night) else { return nil }
        let file = Self.stillFile(folder: folder, camera: camera, night: night, id: entryID)
        guard Self.stamp(of: file) == stamp, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let still = try? handle.readToEnd(), !still.isEmpty, Self.stamp(of: file) == stamp else { return nil }
        return still
    }

    /// Keeps `jpeg` as the entry's thumbnail: written to a 0600 temporary file in the night's folder of pictures and moved into place, over an earlier
    /// thumbnail of the entry. Refused (false) when `jpeg` cannot be a thumbnail, when the picture is not the one it was made from (`stamp`: it was replaced
    /// meanwhile, or is gone) and when a link is where the thumbnail belongs; no folder is made (the picture's is there). Blocking disk work.
    @discardableResult
    func storeThumbnail(_ jpeg: Data, madeFrom stamp: SkyStillStamp, entryID: String, camera: UUID, night: String, folder: URL) -> Bool {
        guard Self.isValidNight(night), SkyEntry.isValidID(entryID), Self.isThumbnailFile(jpeg), Self.picturesAreReal(folder: folder, camera: camera, night: night) else { return false }
        let manager = FileManager.default
        let directory = Self.stillsFolder(folder: folder, camera: camera, night: night)
        let still = Self.stillFile(folder: folder, camera: camera, night: night, id: entryID)
        let file = Self.thumbnailFile(folder: folder, camera: camera, night: night, id: entryID)
        let temporary = directory.appending(path: ".\(entryID).thumb.\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        guard manager.createFile(atPath: temporary.path(percentEncoded: false), contents: jpeg, attributes: [.posixPermissions: 0o600]) else { return false }
        // Stamped with the picture's time: one that cannot be stamped is kept all the same and, not matching, is made again at the next request.
        try? manager.setAttributes([.modificationDate: stamp.modified], ofItemAtPath: temporary.path(percentEncoded: false))
        let kept = Self.pictureMoves.withLock { _ -> Bool in
            guard Self.stamp(of: still) == stamp else { return false }
            let existing = ArchiveEventLog.entryType(file)
            guard existing == nil || existing == .typeRegular else { return false }
            do {
                if existing == .typeRegular { try manager.removeItem(at: file) }
                try manager.moveItem(at: temporary, to: file)
                return true
            } catch {
                return false
            }
        }
        if !kept { try? manager.removeItem(at: temporary) }
        return kept
    }

    /// Removes the entry's thumbnail when it is a regular file (a link is left alone: it is not served either). Called with `pictureMoves` held, when
    /// the picture it was made from is replaced.
    static func removeThumbnail(folder: URL, camera: UUID, night: String, id: String) {
        let file = thumbnailFile(folder: folder, camera: camera, night: night, id: id)
        if ArchiveEventLog.entryType(file) == .typeRegular { try? FileManager.default.removeItem(at: file) }
    }

    /// How big the pictures of a night are, from the first of the entries `ids` (the newest first) whose picture can be read: the frame header of
    /// at most `pictureProbeLimit` pictures is looked at. nil when none can be. Blocking disk work.
    func pictureSize(ofStills ids: [String], camera: UUID, night: String, folder: URL) -> SkyPictureSize? {
        guard Self.isValidNight(night), Self.picturesAreReal(folder: folder, camera: camera, night: night) else { return nil }
        for id in ids.prefix(Self.pictureProbeLimit) where SkyEntry.isValidID(id) {
            let file = Self.stillFile(folder: folder, camera: camera, night: night, id: id)
            guard let attributes = CatalogLoader.attributes(file), attributes.type == .typeRegular, attributes.size > 0, attributes.size <= UInt64(Self.maximumStillBytes),
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: Self.pictureProbeBytes), let size = JPEGHeader.size(of: head) { return size }
        }
        return nil
    }

    // MARK: The path of an entry

    /// The path of an entry (its first line of the id, in the camera's file for the night, or still waiting for the drive), for the close-up; nil when
    /// the night's log does not hold it. The file is searched for the id's bytes and only the lines that hold them are read as entries (a night's file
    /// is megabytes and a page asks for hundreds of thumbnails: reading every line of it each time would take seconds of the box's time). Blocking
    /// disk work.
    func path(ofEntry id: String, camera: UUID, night: String, folder: URL) -> [SkyPathPoint]? {
        guard Self.isValidNight(night), SkyEntry.isValidID(id) else { return nil }
        // What waits for the drive is looked at before the file, as a read does: a line that is written meanwhile is found in either.
        let waiting = waitingLines(camera: camera, night: night, folder: folder)
        let needle = Array("id\":\"\(id)\"".utf8)
        let decoder = Self.makeDecoder()
        if let file = Self.readTail(Self.nightFile(folder: folder, camera: camera, night: night), folder: folder, camera: camera),
           let path = Self.entryPath(in: file, id: id, camera: camera, needle: needle, decoder: decoder) { return path }
        for line in waiting {
            if let path = Self.entryPath(in: line, id: id, camera: camera, needle: needle, decoder: decoder) { return path }
        }
        return nil
    }

    /// The path of the entry `id` in `data` (lines of the log): in the first line that holds the id's bytes and is that entry's own.
    static func entryPath(in data: Data, id: String, camera: UUID, needle: [UInt8], decoder: JSONDecoder) -> [SkyPathPoint]? {
        data.withUnsafeBytes { raw -> [SkyPathPoint]? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress, !needle.isEmpty, bytes.count >= needle.count else { return nil }
            let count = bytes.count
            var from = 0
            while from + needle.count <= count {
                guard let hit = find(needle, in: base, count: count, from: from) else { return nil }
                var start = hit
                while start > 0, base[start - 1] != 0x0A { start -= 1 }
                var end = hit
                while end < count, base[end] != 0x0A { end += 1 }
                from = end + 1
                guard end - start < maximumLineBytes else { continue }
                let line = Data(bytes: base + start, count: end - start)
                if let decoded = try? decoder.decode(Line.self, from: line), decoded.v == version, let entry = decoded.entry, entry.id == id, entry.camera == camera {
                    return entry.path
                }
            }
            return nil
        }
    }

    /// The offset of the first place at or after `from` where `needle` starts in the `count` bytes at `base`; nil when there is none.
    private static func find(_ needle: [UInt8], in base: UnsafePointer<UInt8>, count: Int, from: Int) -> Int? {
        let last = count - needle.count
        var index = from
        return needle.withUnsafeBufferPointer { pattern -> Int? in
            guard let first = pattern.first, let pointer = pattern.baseAddress else { return nil }
            while index <= last {
                guard let found = memchr(base + index, Int32(first), last - index + 1) else { return nil }
                let offset = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
                if memcmp(base + offset, pointer, needle.count) == 0 { return offset }
                index = offset + 1
            }
            return nil
        }
    }
}
