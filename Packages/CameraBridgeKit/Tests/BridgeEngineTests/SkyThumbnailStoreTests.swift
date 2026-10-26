import BridgeSupport
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// The small pictures of the Sky Watcher's grid on the drive (`SkyLogStore` thumbnails): kept once, beside the picture they were made from, in
/// `<night>/<id>.thumb.jpg`, mode 0600, never through a link; made again when the picture is replaced; counted in the camera's pictures and gone with
/// their night. And what the thumbnail's maker reads from the log: an entry's path, and how big the stills of a night are.
@Suite(.timeLimit(.minutes(2))) struct SkyThumbnailStoreTests {
    static let camera = SkyLogStoreTests.camera
    static let night = SkyLogStoreTests.night

    /// A still of `width` × `height` as far as its header goes, with a word in it to tell it from another.
    static func still(_ word: String = "one", width: Int = 1920, height: Int = 852) -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, 0xFE]) + Data([UInt8((word.utf8.count + 2) >> 8), UInt8((word.utf8.count + 2) & 0xFF)]) + Data(word.utf8)
        data += Data([0xFF, 0xC0, 0x00, 0x0B, 0x08, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 0x01, 0x01, 0x11, 0x00])
        return data + Data(count: 12) + Data([0xFF, 0xD9])
    }

    /// A thumbnail: a JPEG as far as its start and end go.
    static func thumbnail(_ word: String = "small") -> Data { Data([0xFF, 0xD8]) + Data(word.utf8) + Data([0xFF, 0xD9]) }

    /// A store with a still of the entry `id` written and waited for.
    func store(in folder: URL, id: String = "t-1", still: Data = SkyThumbnailStoreTests.still()) async -> SkyLogStore {
        let log = SkyLogStore(log: .silent)
        log.writeStill(still, entryID: id, camera: Self.camera, night: Self.night, folder: folder)
        await log.flush()
        return log
    }

    func lookup(_ log: SkyLogStore, _ folder: URL, id: String = "t-1", night: String = SkyThumbnailStoreTests.night) -> SkyThumbnailLookup {
        log.thumbnailLookup(camera: Self.camera, night: night, entryID: id, folder: folder)
    }

    func store(_ log: SkyLogStore, _ jpeg: Data, from stamp: SkyStillStamp, in folder: URL, id: String = "t-1") -> Bool {
        log.storeThumbnail(jpeg, madeFrom: stamp, entryID: id, camera: Self.camera, night: Self.night, folder: folder)
    }

    func stamp(of found: SkyThumbnailLookup) throws -> SkyStillStamp {
        guard case .still(let stamp) = found else { throw Failure("a picture to make a thumbnail of was expected, not \(found)") }
        return stamp
    }

    /// The picture of the entry as the lookup stamped it (nil: it is not that one any more).
    func read(_ log: SkyLogStore, _ folder: URL, _ stamp: SkyStillStamp, id: String = "t-1") -> Data? {
        log.readStill(stamp: stamp, entryID: id, camera: Self.camera, night: Self.night, folder: folder)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func nightFolder(_ folder: URL, night: String = night) -> URL {
        folder.appending(path: ".sky/\(camera.uuidString)/\(night)", directoryHint: .isDirectory)
    }

    static func file(_ folder: URL, _ name: String, night: String = night) -> URL { nightFolder(folder, night: night).appending(path: name, directoryHint: .notDirectory) }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    static func owner(_ url: URL) -> Int? { ((try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.ownerAccountID] as? NSNumber)?.intValue }

    // MARK: Kept beside the picture

    @Test func aThumbnailIsKeptBesideItsPictureOwnedBySameUserAndPrivate() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url
        let log = await store(in: folder)
        let found = lookup(log, folder)
        guard case .still(let picture) = found else { Issue.record("the picture should be there: \(found)"); return }
        #expect(read(log, folder, picture) == Self.still(), "the lookup stamps the picture and the stamp reads it")
        #expect(try store(log, Self.thumbnail(), from: stamp(of: found), in: folder), "kept")

        let thumbnail = Self.file(folder, "t-1.thumb.jpg")
        #expect(SkyLogStore.thumbnailFile(folder: folder, camera: Self.camera, night: Self.night, id: "t-1") == thumbnail)
        #expect(SkyLogStore.thumbnailSuffix == ".thumb.jpg")
        #expect(try Data(contentsOf: thumbnail) == Self.thumbnail())
        let still = Self.file(folder, "t-1.jpg")
        #expect(SkyLogStoreTests.mode(thumbnail) == 0o600 && SkyLogStoreTests.mode(thumbnail.deletingLastPathComponent()) == 0o700, "private, in the picture's own folder")
        #expect(Self.owner(thumbnail) != nil && Self.owner(thumbnail) == Self.owner(still), "owned by whoever owns the picture")
        let names = try FileManager.default.contentsOfDirectory(atPath: thumbnail.deletingLastPathComponent().path(percentEncoded: false)).sorted()
        #expect(names == ["t-1.jpg", "t-1.thumb.jpg"], "and no temporary file left behind: \(names)")
        #expect(lookup(log, folder) == .thumbnail(Self.thumbnail()), "served from there from now on")
        #expect(log.still(camera: Self.camera, night: Self.night, entryID: "t-1", folder: folder) == Self.still(), "the picture itself is as it was")
    }

    @Test func thereIsNothingToMakeAThumbnailOfWithoutAPicture() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url
        let log = await store(in: folder)
        #expect(lookup(log, folder, id: "t-2") == .none)
        #expect(lookup(log, folder, night: "2026-10-23") == .none)
        #expect(lookup(log, folder, id: "../t-1") == .none && lookup(log, folder, night: "../x") == .none)
        let found = lookup(log, folder)
        // The picture goes (its night was pruned, or it was taken for room): its thumbnail is not served without it, and none is kept for it.
        try FileManager.default.removeItem(at: Self.file(folder, "t-1.jpg"))
        #expect(try !store(log, Self.thumbnail(), from: stamp(of: found), in: folder))
        #expect(lookup(log, folder) == .none)
        #expect(!Self.exists(Self.file(folder, "t-1.thumb.jpg")))
        #expect(log.thumbnailLookup(camera: Self.camera, night: Self.night, entryID: "t-1", folder: folder.appending(path: "nowhere")) == .none)
    }

    @Test func aThumbnailThatIsNotAJPEGOrIsTooBigIsNotKept() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url
        let log = await store(in: folder)
        let found = lookup(log, folder)
        let from = try stamp(of: found)
        #expect(!store(log, Data(), from: from, in: folder))
        #expect(!store(log, Data("not a picture".utf8), from: from, in: folder))
        #expect(!store(log, Data([0xFF, 0xD8]) + Data(count: SkyLogStore.maximumThumbnailBytes) + Data([0xFF, 0xD9]), from: from, in: folder), "over the limit")
        #expect(lookup(log, folder) == found)
        #expect(!Self.exists(Self.file(folder, "t-1.thumb.jpg")))
    }

    @Test func aPictureIsReadOnlyAsTheStampSaysAndNeverThroughALink() async throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let manager = FileManager.default
        let folder = parent.url.appending(path: "recordings", directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        let log = await store(in: folder)
        let picture = try stamp(of: lookup(log, folder))
        #expect(read(log, folder, picture) == Self.still())
        #expect(read(log, folder, picture, id: "t-2") == nil && read(log, folder, picture, id: "../t-1") == nil)
        #expect(log.readStill(stamp: picture, entryID: "t-1", camera: Self.camera, night: "2026-10-23", folder: folder) == nil)
        // The picture's size or time changed: not the stamped one.
        var other = picture
        other.size += 1
        #expect(read(log, folder, other) == nil)
        other = picture
        other.modified = picture.modified.addingTimeInterval(5)
        #expect(read(log, folder, other) == nil)
        // The picture is a link to a picture elsewhere: nothing is read through it.
        let outside = parent.url.appending(path: "outside.jpg")
        try Self.still("outside").write(to: outside)
        let file = Self.file(folder, "t-1.jpg")
        try manager.removeItem(at: file)
        try manager.createSymbolicLink(at: URL(fileURLWithPath: ArchiveVolume.path(of: file)), withDestinationURL: outside)
        #expect(read(log, folder, picture) == nil && lookup(log, folder) == .none)
    }

    // MARK: Made again when the picture is replaced

    @Test func aReplacedPictureTakesItsThumbnailWithIt() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url
        let log = await store(in: folder)
        #expect(try store(log, Self.thumbnail(), from: stamp(of: lookup(log, folder)), in: folder))
        #expect(lookup(log, folder) == .thumbnail(Self.thumbnail()))

        // The same entry's picture is written again: the thumbnail made from the old one goes.
        log.writeStill(Self.still("another"), entryID: "t-1", camera: Self.camera, night: Self.night, folder: folder)
        await log.flush()
        #expect(!Self.exists(Self.file(folder, "t-1.thumb.jpg")), "gone with the old picture")
        let found = lookup(log, folder)
        guard case .still(let newStamp) = found else { Issue.record("the new picture should be there: \(found)"); return }
        #expect(read(log, folder, newStamp) == Self.still("another"))
        #expect(store(log, Self.thumbnail("again"), from: newStamp, in: folder))
        #expect(lookup(log, folder) == .thumbnail(Self.thumbnail("again")))
    }

    @Test func aPictureReplacedMeanwhileDoesNotKeepAThumbnailMadeFromTheOldOne() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url
        let log = await store(in: folder)
        let old = try stamp(of: lookup(log, folder))
        // The thumbnail is being made (it takes a moment) and the picture is written again.
        log.writeStill(Self.still("another"), entryID: "t-1", camera: Self.camera, night: Self.night, folder: folder)
        await log.flush()
        #expect(!store(log, Self.thumbnail("from the old one"), from: old, in: folder), "refused: it is of a picture that is gone")
        #expect(!Self.exists(Self.file(folder, "t-1.thumb.jpg")))
        guard case .still(let newStamp) = lookup(log, folder) else { Issue.record("the new picture, still without a thumbnail"); return }
        #expect(read(log, folder, newStamp) == Self.still("another"))
        #expect(read(log, folder, old) == nil, "and the old stamp reads nothing: it is not the picture there now")
    }

    @Test func aThumbnailIsStampedWithItsPicturesTimeAndServedOnlyWhileTheyMatch() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url
        let log = await store(in: folder)
        let found = lookup(log, folder)
        #expect(try store(log, Self.thumbnail(), from: stamp(of: found), in: folder))
        let thumbnail = Self.file(folder, "t-1.thumb.jpg"), still = Self.file(folder, "t-1.jpg")
        func modified(_ url: URL) throws -> Date {
            try #require(try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date)
        }
        #expect(abs(try modified(thumbnail).timeIntervalSince(modified(still))) < 0.001, "the thumbnail has the time of the picture it was made from")
        #expect(lookup(log, folder) == .thumbnail(Self.thumbnail()))

        // Something else replaced the picture's file after the thumbnail was made: the times no longer match, and it is not to be trusted.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: still.path(percentEncoded: false))
        let changed = lookup(log, folder)
        guard case .still = changed else { Issue.record("the thumbnail should be made again: \(changed)"); return }
        #expect(try store(log, Self.thumbnail("new"), from: stamp(of: changed), in: folder), "and a new one takes its place, with the picture’s new time")
        #expect(lookup(log, folder) == .thumbnail(Self.thumbnail("new")))

        // A thumbnail older than its picture is no better than one newer than it.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: thumbnail.path(percentEncoded: false))
        guard case .still = lookup(log, folder) else { Issue.record("older than its picture"); return }
    }

    @Test func aClockThatWentBackDoesNotMakeEveryThumbnailStale() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url
        let log = await store(in: folder)
        // The picture was written when the clock was an hour ahead of what it is now (it was set right since): its time is in the future.
        let future = Date().addingTimeInterval(3_600)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: Self.file(folder, "t-1.jpg").path(percentEncoded: false))
        let found = lookup(log, folder)
        #expect(try store(log, Self.thumbnail(), from: stamp(of: found), in: folder))
        #expect(lookup(log, folder) == .thumbnail(Self.thumbnail()), "kept and served: it is of its picture, whatever the clock says now")
    }

    @Test func aThumbnailFileThatIsDamagedIsMadeAgain() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url
        let log = await store(in: folder)
        let from = try stamp(of: lookup(log, folder))
        #expect(store(log, Self.thumbnail(), from: from, in: folder))
        let file = Self.file(folder, "t-1.thumb.jpg")
        for damage in [Data(), Data("garbage".utf8), Data([0xFF, 0xD8]) + Data(count: SkyLogStore.maximumThumbnailBytes + 10) + Data([0xFF, 0xD9]), Data([0xFF, 0xD8, 0x01, 0x02])] {
            try damage.write(to: file)
            let found = lookup(log, folder)
            guard case .still = found else { Issue.record("\(damage.count) damaged bytes should be made again: \(found)"); return }
        }
        #expect(try store(log, Self.thumbnail("whole"), from: stamp(of: lookup(log, folder)), in: folder), "and the new one replaces it")
        #expect(lookup(log, folder) == .thumbnail(Self.thumbnail("whole")))
    }

    // MARK: Never through a link

    @Test func aThumbnailIsNeverReadWrittenOrReplacedThroughALink() async throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let manager = FileManager.default
        let folder = parent.url.appending(path: "recordings", directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        let outside = parent.url.appending(path: "outside.jpg")
        try Self.thumbnail("outside").write(to: outside)
        let log = await store(in: folder)
        let from = try stamp(of: lookup(log, folder))
        let thumbnail = Self.file(folder, "t-1.thumb.jpg")
        func link(_ at: URL, to target: URL) throws { try manager.createSymbolicLink(at: URL(fileURLWithPath: ArchiveVolume.path(of: at)), withDestinationURL: target) }

        // The thumbnail's own file is a link to a picture elsewhere: it is not read, not written through, not replaced.
        try link(thumbnail, to: outside)
        let found = lookup(log, folder)
        guard case .still = found else { Issue.record("a link is no thumbnail: \(found)"); return }
        #expect(!store(log, Self.thumbnail("mine"), from: from, in: folder), "and nothing is written where a link is")
        #expect(try Data(contentsOf: outside) == Self.thumbnail("outside"), "what it pointed to is as it was")
        #expect((try? manager.destinationOfSymbolicLink(atPath: thumbnail.path(percentEncoded: false))) != nil, "the link is still there")
        try manager.removeItem(at: thumbnail)

        // The night's folder of pictures is a link to a folder elsewhere (with a picture and a thumbnail in it).
        let elsewhere = parent.url.appending(path: "elsewhere", directoryHint: .isDirectory)
        try manager.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try Self.still("far").write(to: elsewhere.appending(path: "t-1.jpg"))
        try Self.thumbnail("far").write(to: elsewhere.appending(path: "t-1.thumb.jpg"))
        let nightFolder = Self.nightFolder(folder)
        try manager.moveItem(at: nightFolder, to: parent.url.appending(path: "moved", directoryHint: .isDirectory))
        try link(nightFolder, to: elsewhere)
        #expect(lookup(log, folder) == .none, "nothing is read through it")
        #expect(!store(log, Self.thumbnail("mine"), from: from, in: folder))
        #expect(try Data(contentsOf: elsewhere.appending(path: "t-1.thumb.jpg")) == Self.thumbnail("far"))
        #expect(try manager.contentsOfDirectory(atPath: elsewhere.path(percentEncoded: false)).sorted() == ["t-1.jpg", "t-1.thumb.jpg"], "and nothing was added there")
    }

    // MARK: Counted in the camera's pictures, and gone with the night

    private static func makeNight(_ night: String, in folder: URL, stillBytes: Int, thumbnailBytes: Int?) throws {
        let directory = nightFolder(folder, night: night)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 7, count: stillBytes).write(to: directory.appending(path: "p-1.jpg"))
        if let thumbnailBytes { try Data(repeating: 8, count: thumbnailBytes).write(to: directory.appending(path: "p-1.thumb.jpg")) }
        try Data("{}\n".utf8).write(to: directory.deletingLastPathComponent().appending(path: "\(night).jsonl"))
    }

    @Test func thumbnailsCountInTheCamerasPicturesAndGoWithTheirNight() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url
        let nights = ["2026-10-20", "2026-10-21", "2026-10-22"]
        // 1,000 bytes of pictures and 600 of thumbnails a night: 4,800 in all. Without the thumbnails the three nights would be 3,000.
        for night in nights { try Self.makeNight(night, in: folder, stillBytes: 1_000, thumbnailBytes: 600) }
        let removed = Box<[String]>([])
        let result = SkyLogStore.pruneStills(folder: folder, maximumBytes: 3_500, remove: { url in
            removed.update { $0.append(url.lastPathComponent) }
            try FileManager.default.removeItem(at: url)
        })
        #expect(result.nights == 1 && result.bytes == 1_600, "the oldest night went, with what the thumbnail added to it: \(result)")
        #expect(removed.value == ["2026-10-20"], "and its folder is what goes: the thumbnail with it")
        #expect(!Self.exists(Self.file(folder, "p-1.thumb.jpg", night: "2026-10-20")))
        #expect(Self.exists(Self.file(folder, "p-1.thumb.jpg", night: "2026-10-21")))
        #expect(SkyLogStore.pruneStills(folder: folder, maximumBytes: 3_500).nights == 0, "3,200 bytes are under the limit")
        #expect(SkyLogStore.pruneStills(folder: folder, maximumBytes: 3_100).nights == 1, "and over this one: the thumbnails are counted")

        // The same limit without thumbnails would have kept all three nights.
        let plain = try TemporaryDirectory()
        defer { plain.remove() }
        for night in nights { try Self.makeNight(night, in: plain.url, stillBytes: 1_000, thumbnailBytes: nil) }
        #expect(SkyLogStore.pruneStills(folder: plain.url, maximumBytes: 3_500).nights == 0)
    }

    @Test func aPrunedNightTakesItsThumbnailsWithIt() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url
        let nights = ["2026-10-05", "2026-10-19"]
        let log = SkyLogStore(log: .silent)
        for night in nights {
            log.record(SkyLogStoreTests.entry("t-1", SkyLogStoreTests.local(24, 20)), night: night, folder: folder)
            log.writeStill(Self.still(), entryID: "t-1", camera: Self.camera, night: night, folder: folder)
        }
        await log.flush()
        for night in nights {
            let found = log.thumbnailLookup(camera: Self.camera, night: night, entryID: "t-1", folder: folder)
            #expect(log.storeThumbnail(Self.thumbnail(), madeFrom: try stamp(of: found), entryID: "t-1", camera: Self.camera, night: night, folder: folder))
        }
        let cutoff = SkyLogStoreTests.dayStart("2026-10-20")
        #expect(SkyLogStore.prune(folder: folder, cutoffMs: cutoff) == 1, "the old night, with its folder of pictures")
        #expect(!Self.exists(Self.nightFolder(folder, night: "2026-10-05")), "thumbnail and all")
        #expect(log.thumbnailLookup(camera: Self.camera, night: "2026-10-05", entryID: "t-1", folder: folder) == .none)
        #expect(log.thumbnailLookup(camera: Self.camera, night: "2026-10-19", entryID: "t-1", folder: folder) == .thumbnail(Self.thumbnail()))
    }

    // MARK: What the maker reads from the log

    @Test func theEntrysPathComesFromItsLineInTheNightsFile() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url
        let log = SkyLogStore(log: .silent)
        var near = SkyLogStoreTests.entry("a-1", SkyLogStoreTests.local(24, 20))
        near.path = [SkyPathPoint(t: 0, x: 0.1, y: 0.2), SkyPathPoint(t: 2, x: 0.15, y: 0.22)]
        var longer = SkyLogStoreTests.entry("a-10", SkyLogStoreTests.local(24, 21))
        longer.path = [SkyPathPoint(t: 0, x: 0.8, y: 0.8)]
        var plane = SkyLogStoreTests.entry("a-2", SkyLogStoreTests.local(24, 22), label: .plane)
        plane.path = [SkyPathPoint(t: 0, x: 0.5, y: 0.5), SkyPathPoint(t: 3, x: 0.6, y: 0.5), SkyPathPoint(t: 6, x: 0.7, y: 0.5)]
        for entry in [near, longer, plane] { log.record(entry, night: Self.night, folder: folder) }
        log.recordCorrection(.bird, entryID: "a-1", camera: Self.camera, night: Self.night, folder: folder, at: SkyLogStoreTests.local(25, 8))
        log.recordAlert(entryID: "a-10", camera: Self.camera, night: Self.night, folder: folder)
        await log.flush()
        func path(_ id: String, camera: UUID = Self.camera, night: String = Self.night) -> [SkyPathPoint]? {
            log.path(ofEntry: id, camera: camera, night: night, folder: folder)
        }
        #expect(path("a-1") == near.path, "not the line of a correction, and not the entry whose id starts the same way")
        #expect(path("a-10") == longer.path)
        #expect(path("a-2") == plane.path)
        #expect(path("a-3") == nil && path("a") == nil && path("a-1", night: "2026-10-23") == nil, "an entry the file does not hold")
        #expect(path("a-1", camera: SkyLogStoreTests.other) == nil, "another camera has its own file")
        #expect(path("../a-1") == nil && path("") == nil && path("a-1", night: "../x") == nil)
    }

    @Test func anEntryThatIsStillWaitingForTheDriveHasItsPathToo() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url
        let gate = DispatchSemaphore(value: 0), calls = Box(0)
        let log = SkyLogStore(log: .silent, append: { data, folder, camera, night in
            if calls.update({ $0 += 1; return $0 }) == 1 { gate.wait() }
            try SkyLogStore.append(data, folder: folder, camera: camera, night: night)
        })
        var first = SkyLogStoreTests.entry("w-1", SkyLogStoreTests.local(24, 20))
        first.path = [SkyPathPoint(t: 0, x: 0.3, y: 0.3)]
        var second = SkyLogStoreTests.entry("w-2", SkyLogStoreTests.local(24, 21))
        second.path = [SkyPathPoint(t: 0, x: 0.7, y: 0.4)]
        log.record(first, night: Self.night, folder: folder)
        #expect(await eventually(timeout: .seconds(30)) { calls.value == 1 })
        log.record(second, night: Self.night, folder: folder)
        #expect(log.path(ofEntry: "w-1", camera: Self.camera, night: Self.night, folder: folder) == first.path, "on its way to the file")
        #expect(log.path(ofEntry: "w-2", camera: Self.camera, night: Self.night, folder: folder) == second.path, "and behind it")
        gate.signal()
        await log.flush()
        #expect(log.path(ofEntry: "w-2", camera: Self.camera, night: Self.night, folder: folder) == second.path)
    }

    @Test func aTornAndAnOversizedLineDoNotHideAnEntry() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url
        let log = SkyLogStore(log: .silent)
        var entry = SkyLogStoreTests.entry("z-1", SkyLogStoreTests.local(24, 20))
        entry.path = [SkyPathPoint(t: 0, x: 0.4, y: 0.4)]
        log.record(SkyLogStoreTests.entry("z-0", SkyLogStoreTests.local(24, 19)), night: Self.night, folder: folder)
        log.record(entry, night: Self.night, folder: folder)
        await log.flush()
        let file = SkyLogStore.nightFile(folder: folder, camera: Self.camera, night: Self.night)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        // Lines that name the entry but are not its own: one that is not an entry, a torn one and a long one.
        try handle.write(contentsOf: Data((#"{"v":1,"id":"z-1","entry":"nonsense"}"# + "\n" + #"{"entry":{"id":"z-1","cam"# + "\n").utf8))
        try handle.write(contentsOf: Data((#"{"v":1,"id":"z-1","ai":{"at":1,"kind":"x","model":"m","sentence":""# + String(repeating: "w", count: SkyLogStore.maximumLineBytes) + #""}}"# + "\n").utf8))
        try handle.close()
        #expect(log.path(ofEntry: "z-1", camera: Self.camera, night: Self.night, folder: folder) == entry.path)
        #expect(log.path(ofEntry: "z-9", camera: Self.camera, night: Self.night, folder: folder) == nil)
    }

    @Test func theSizeOfANightsPicturesComesFromTheFirstThatCanBeRead() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url
        let log = SkyLogStore(log: .silent)
        func size(_ ids: [String], night: String = Self.night) -> SkyPictureSize? {
            log.pictureSize(ofStills: ids, camera: Self.camera, night: night, folder: folder)
        }
        #expect(size(["p-1"]) == nil, "no pictures yet")
        log.writeStill(Self.still("a", width: 1920, height: 852), entryID: "p-2", camera: Self.camera, night: Self.night, folder: folder)
        log.writeStill(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0, 0, 0xFF, 0xD9]), entryID: "p-3", camera: Self.camera, night: Self.night, folder: folder)   // no size in it
        log.writeStill(Self.still("b", width: 1280, height: 720), entryID: "p-4", camera: Self.camera, night: Self.night, folder: folder)
        await log.flush()
        #expect(size(["p-1", "p-2"]) == SkyPictureSize(width: 1920, height: 852), "p-1 has none; p-2 is the first that has")
        #expect(size(["p-3", "p-4", "p-2"]) == SkyPictureSize(width: 1280, height: 720), "one that cannot be read is passed over")
        #expect(size(["p-3"]) == nil && size([]) == nil && size(["../p-2", "p-2/x"]) == nil)
        #expect(size(["p-2"], night: "2026-10-23") == nil && size(["p-2"], night: "../x") == nil)
        #expect(size(Array(repeating: "p-1", count: 20) + ["p-2"]) == nil, "only the first few are looked at")
        // A bigger picture's header can be a few KiB in (an application segment before it).
        log.writeStill(Data([0xFF, 0xD8, 0xFF, 0xE1, 0x7F, 0xFE]) + Data(count: 0x7FFC) + Self.still("c", width: 640, height: 360).dropFirst(2), entryID: "p-5",
                       camera: Self.camera, night: Self.night, folder: folder)
        await log.flush()
        #expect(size(["p-5"]) == SkyPictureSize(width: 640, height: 360))
    }
}
