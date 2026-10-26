import BridgeSupport
@testable import CameraAdapters
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// Codecs that make the Sky Watcher's small pictures out of made-up ones: a JPEG's header of the size the crop and the limit make, with the number of
/// the call in it. Every call is noted; with `hold` set each waits until `release()` lets one go, and `active` and `mostActive` count the calls inside.
final class ThumbnailCodecs: MediaCodecs {
    struct Call: Equatable, Sendable {
        var crop: ImageCrop?
        var maxWidth: Int
        var quality: Double
        var input: Data
    }

    let calls = Box<[Call]>([])
    let active = Box(0)
    let mostActive = Box(0)
    let fails = Box(false)
    private let permits = DispatchSemaphore(value: 0)
    private let hold: Bool
    /// The calls for the pictures of these words wait until `release(word:)`.
    private let gates: [String: DispatchSemaphore]
    /// Answers a picture 1,200 wide, whatever was asked.
    private let wide: Bool

    init(hold: Bool = false, holdOnly words: [String] = [], wide: Bool = false) {
        self.hold = hold
        gates = Dictionary(uniqueKeysWithValues: words.map { ($0, DispatchSemaphore(value: 0)) })
        self.wide = wide
    }

    /// Lets one waiting call go (or the next to come, if none waits).
    func release(_ count: Int = 1) { for _ in 0..<count { permits.signal() } }

    /// Lets the call for the picture of `word` go.
    func release(word: String) { gates[word]?.signal() }

    /// The word a still was made with (`SkyThumbnailStoreTests.still`: three characters here).
    static func word(of still: Data) -> String { String(decoding: still.dropFirst(6).prefix(3), as: UTF8.self) }

    /// The JPEG a call number gets for a part of `width` × `height` at most `maxWidth` wide: a header, with the number in a comment.
    static func output(call: Int, width: Int, height: Int, maxWidth: Int) -> Data {
        let scale = min(1, Double(maxWidth) / Double(width))
        let outWidth = max(1, Int((Double(width) * scale).rounded())), outHeight = max(1, Int((Double(height) * scale).rounded()))
        let word = Data("call \(call)".utf8)
        return Data([0xFF, 0xD8, 0xFF, 0xFE, UInt8((word.count + 2) >> 8), UInt8((word.count + 2) & 0xFF)]) + word
            + Data([0xFF, 0xC0, 0x00, 0x0B, 0x08, UInt8(outHeight >> 8), UInt8(outHeight & 0xFF), UInt8(outWidth >> 8), UInt8(outWidth & 0xFF), 0x01, 0x01, 0x11, 0x00])
            + Data(count: 8) + Data([0xFF, 0xD9])
    }

    func croppedJPEG(_ jpeg: Data, crop: ImageCrop?, maxWidth: Int, quality: Double) throws -> Data {
        let number = calls.update { calls -> Int in
            calls.append(Call(crop: crop, maxWidth: maxWidth, quality: quality, input: jpeg))
            return calls.count
        }
        let inside = active.update { $0 += 1; return $0 }
        mostActive.update { $0 = max($0, inside) }
        defer { active.update { $0 -= 1 } }
        if hold { permits.wait() }
        gates[Self.word(of: jpeg)]?.wait()
        if fails.value { throw MediaCodecError.unsupported("not in this test") }
        guard let size = JPEGHeader.size(of: jpeg) else { throw MediaCodecError.unsupported("not an image") }
        let part = crop ?? ImageCrop(x: 0, y: 0, width: size.width, height: size.height)
        if wide { return Self.output(call: number, width: 1_200, height: 675, maxWidth: 1_200) }
        return Self.output(call: number, width: part.width, height: part.height, maxWidth: maxWidth)
    }

    private static let unavailable = MediaCodecError.unsupported("not in this test")
    func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding { throw Self.unavailable }
    func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { throw Self.unavailable }
    func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding { throw Self.unavailable }
    func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding { throw Self.unavailable }
    func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data { throw Self.unavailable }
    func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data { throw Self.unavailable }
    func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] { throw Self.unavailable }
    func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration, audio: AudioCodec?,
                             audioSampleRate: Int) -> any MediaSource {
        SkyFakeCodecs.SilentSource()
    }
}

/// The small pictures of the grid, asked for through the engine (`BridgeEngine.skyStillThumbnail`): cut around the light, made once and kept, made again
/// when the picture is replaced, the whole picture when they cannot be made, at most two at a time and the newest asked for first; and how big a night's
/// pictures are, for the page to draw a path over a thumbnail.
@Suite(.timeLimit(.minutes(2))) struct SkyThumbnailEngineTests {
    static let camera = SkyLogStoreTests.camera
    static let night = SkyLogStoreTests.night
    static let zone = SkyLogStoreTests.zone

    /// An engine with the made-up place, a recordings folder, one camera and `codecs` (not started: nothing runs).
    @MainActor final class Rig {
        let directory: TemporaryDirectory
        let recordings: TemporaryDirectory
        let engine: BridgeEngine
        let codecs: any MediaCodecs
        let cameraID = SkyThumbnailEngineTests.camera
        var log: SkyLogStore { engine.nvr.store.skyLog }
        /// The codecs, when they are the made-up ones of these tests.
        var fake: ThumbnailCodecs { codecs as! ThumbnailCodecs }   // swiftlint:disable:this force_cast

        init(codecs: any MediaCodecs = ThumbnailCodecs(), tuning: EngineTuning = EngineTuning(), room: Bool = true) async throws {
            directory = try TemporaryDirectory()
            recordings = try TemporaryDirectory()
            self.codecs = codecs
            var environment = BridgeEnvironment.inert(directory: directory.url)
            environment.codecs = codecs
            var tuning = tuning
            // The drive has room unless the test says it has not (an engine that has measured no drive has none to give).
            if tuning.skyThumbnailRoom == nil { tuning.skyThumbnailRoom = { room } }
            engine = BridgeEngine(environment: environment, tuning: tuning)
            let folderPath = recordings.url.path(percentEncoded: false)
            try await engine.updateSettings { settings in
                settings.sky.location = SkyNightLogEngineTests.place
                settings.nvrFolder = folderPath
            }
            var camera = CameraConfiguration(id: SkyThumbnailEngineTests.camera, name: "North Sky", kind: .camera, vendor: .hikvision,
                                             endpoint: CameraEndpoint(host: "192.168.77.30"), username: "admin")
            camera.skyDetector = SkyDetectorSettings(enabled: true)
            try await engine.addCamera(camera, password: nil)
        }

        deinit {
            directory.remove()
            recordings.remove()
        }

        /// Files an entry of the night, with a picture when `still` is given, and waits for the drive.
        func file(_ id: String, path: [(Double, Double)]? = nil, still: Data?, hour: Int = 21) async {
            var entry = SkyLogStoreTests.entry(id, SkyLogStoreTests.local(24, hour), hasStill: still != nil)
            if let path { entry.path = path.enumerated().map { SkyPathPoint(t: Double($0.offset), x: $0.element.0, y: $0.element.1) } }
            log.record(entry, night: SkyThumbnailEngineTests.night, folder: recordings.url)
            if let still { log.writeStill(still, entryID: id, camera: SkyThumbnailEngineTests.camera, night: SkyThumbnailEngineTests.night, folder: recordings.url) }
            await log.flush()
        }

        func thumbnail(_ id: String, night: String = SkyThumbnailEngineTests.night) async throws -> SkyStillPicture {
            try await engine.skyStillThumbnail(cameraID: cameraID, night: night, entryID: id)
        }

        func file(of id: String) -> URL {
            SkyLogStore.thumbnailFile(folder: recordings.url, camera: cameraID, night: SkyThumbnailEngineTests.night, id: id)
        }

        func night(_ night: String = SkyThumbnailEngineTests.night, now: Date = SkyLogStoreTests.local(25, 15)) async throws -> SkyNightLog {
            try await BridgeTime.$taskZone.withValue(SkyThumbnailEngineTests.zone) {
                try await engine.skyNightLog(cameraID: cameraID, night: night, view: .night, now: now)
            }
        }
    }

    /// A still of 1920 × 852 with a word in it.
    static func still(_ word: String = "first") -> Data { SkyThumbnailStoreTests.still(word) }

    /// A light that stays in a small part of the picture, and one that crossed it.
    static let flat: [(Double, Double)] = [(0.45, 0.4), (0.5, 0.42), (0.55, 0.45)]
    static let across: [(Double, Double)] = [(0.05, 0.1), (0.95, 0.9)]

    // MARK: Cut around the light, made once and kept

    @MainActor @Test func aThumbnailIsCutAroundTheLightMadeOnceAndKeptBesideThePicture() async throws {
        let rig = try await Rig()
        await rig.file("m-1", path: Self.flat, still: Self.still())
        let made = try await rig.thumbnail("m-1")
        #expect(made.isThumbnail)
        let call = try #require(rig.fake.calls.value.first)
        #expect(call.crop == ImageCrop(x: 768, y: 254, width: 384, height: 216), "the page’s close-up of this path in 1920 × 852, in whole pixels: \(String(describing: call.crop))")
        #expect(call.maxWidth == 480 && call.quality == 0.8 && call.input == Self.still(), "at most 480 wide, of the picture as it is kept")
        #expect(JPEGHeader.size(of: made.jpeg) == SkyPictureSize(width: 384, height: 216), "never made larger than the part")
        #expect(rig.fake.calls.value.count == 1)

        let file = rig.file(of: "m-1")
        #expect(file.path(percentEncoded: false).hasSuffix("/\(Self.night)/m-1.thumb.jpg"))
        #expect(try Data(contentsOf: file) == made.jpeg && SkyLogStoreTests.mode(file) == 0o600, "kept beside the picture, private")

        // From then on it is served from there: the codecs are not asked again.
        let again = try await rig.thumbnail("m-1")
        #expect(again.isThumbnail && again.jpeg == made.jpeg)
        #expect(rig.fake.calls.value.count == 1, "made once")
        // The picture itself is untouched.
        #expect(try await rig.engine.skyStill(cameraID: rig.cameraID, night: Self.night, entryID: "m-1") == Self.still())
    }

    @MainActor @Test func aCloseUpWiderThanTheLimitIsScaledDownAndALightThatCrossedTheSkyGetsAllOfThePicture() async throws {
        let rig = try await Rig()
        await rig.file("m-1", path: [(0.2, 0.3), (0.7, 0.6)], still: Self.still())
        await rig.file("m-2", path: Self.across, still: Self.still())
        let big = try await rig.thumbnail("m-1")
        #expect(rig.fake.calls.value[0].crop == SkyCloseUp.pixels(path: SkyCloseUpTests.points([(0.2, 0.3), (0.7, 0.6)]), width: 1920, height: 852))
        #expect(JPEGHeader.size(of: big.jpeg) == SkyPictureSize(width: 480, height: 270), "the close-up is 1515 × 852: \(String(describing: JPEGHeader.size(of: big.jpeg)))")
        let whole = try await rig.thumbnail("m-2")
        #expect(rig.fake.calls.value[1].crop == nil, "no close-up: the whole picture, small")
        #expect(JPEGHeader.size(of: whole.jpeg) == SkyPictureSize(width: 480, height: 213))
        #expect(big.isThumbnail && whole.isThumbnail)
    }

    @MainActor @Test func aReplacedPictureMakesANewThumbnail() async throws {
        let rig = try await Rig()
        await rig.file("m-1", path: Self.flat, still: Self.still())
        let first = try await rig.thumbnail("m-1")
        // The same entry's picture is written again (a backfill, a second write): its thumbnail was of the old one.
        rig.log.writeStill(Self.still("second"), entryID: "m-1", camera: rig.cameraID, night: Self.night, folder: rig.recordings.url)
        await rig.log.flush()
        let second = try await rig.thumbnail("m-1")
        #expect(second.isThumbnail && second.jpeg != first.jpeg, "made again, from the new picture")
        #expect(rig.fake.calls.value.count == 2 && rig.fake.calls.value[1].input == Self.still("second"))
        #expect(try await rig.thumbnail("m-1").jpeg == second.jpeg && rig.fake.calls.value.count == 2, "and kept again")
    }

    @MainActor @Test func aThumbnailFileThatWentBadIsMadeAgainAndOneWithoutItsPictureIsNotServed() async throws {
        let rig = try await Rig()
        await rig.file("m-1", path: Self.flat, still: Self.still())
        let first = try await rig.thumbnail("m-1")
        try Data("not a picture".utf8).write(to: rig.file(of: "m-1"))
        let second = try await rig.thumbnail("m-1")
        let kept = try Data(contentsOf: rig.file(of: "m-1"))
        #expect(second.isThumbnail && rig.fake.calls.value.count == 2 && kept == second.jpeg && second.jpeg != first.jpeg, "made again, and kept again")
        // The picture is taken (its night's pictures went to make room): the thumbnail beside it is no answer.
        try FileManager.default.removeItem(at: SkyLogStore.stillFile(folder: rig.recordings.url, camera: rig.cameraID, night: Self.night, id: "m-1"))
        await #expect(throws: SkyLogError.noStill) { try await rig.thumbnail("m-1") }
        await #expect(throws: SkyLogError.noStill) { try await rig.engine.skyStill(cameraID: rig.cameraID, night: Self.night, entryID: "m-1") }
    }

    // MARK: No picture, or no thumbnail

    @MainActor @Test func withoutAPictureOrWithAnEntryThatIsNotAnIdTheAnswerIsTheSameAsTheStillsOwn() async throws {
        let rig = try await Rig()
        await rig.file("m-1", still: nil)
        await #expect(throws: SkyLogError.noStill) { try await rig.thumbnail("m-1") }
        await #expect(throws: SkyLogError.noStill) { try await rig.thumbnail("m-9") }
        await #expect(throws: SkyLogError.noStill) { try await rig.thumbnail("m-1", night: "2026-10-23") }
        await #expect(throws: SkyLogError.noStill) { try await rig.thumbnail("../m-1") }
        await #expect(throws: SkyLogError.unknownNight) { try await rig.thumbnail("m-1", night: "2026-10-24/..") }
        await #expect(throws: SkyLogError.unknownNight) { try await rig.thumbnail("m-1", night: "tonight") }
        await #expect(throws: EngineError.unknownCamera) { try await rig.engine.skyStillThumbnail(cameraID: UUID(), night: Self.night, entryID: "m-1") }
        #expect(rig.fake.calls.value.isEmpty, "nothing was made for any of them")

        let noFolder = try await Rig()
        try await noFolder.engine.updateSettings { $0.nvrFolder = nil }
        await #expect(throws: SkyLogError.noFolder) { try await noFolder.thumbnail("x") }
    }

    @MainActor @Test func whenAThumbnailCannotBeMadeTheWholeStillAnswersAndNothingIsKept() async throws {
        let codecs = ThumbnailCodecs()
        codecs.fails.update { $0 = true }
        let rig = try await Rig(codecs: codecs)
        await rig.file("m-1", path: Self.flat, still: Self.still())
        let answer = try await rig.thumbnail("m-1")
        #expect(!answer.isThumbnail && answer.jpeg == Self.still(), "the picture the page would have asked for")
        #expect(!FileManager.default.fileExists(atPath: rig.file(of: "m-1").path(percentEncoded: false)), "and no thumbnail is kept")
        #expect(codecs.calls.value.count == 1)

        // What went wrong is not tried again at once: a grid of pictures that cannot be made must not be an ffmpeg a card.
        let again = try await rig.thumbnail("m-1")
        #expect(!again.isThumbnail && codecs.calls.value.count == 1, "remembered for a while")
    }

    @MainActor @Test func aThumbnailThatCouldNotBeMadeIsTriedAgainWhenTheMemoryOfItsFailureIsOver() async throws {
        var tuning = EngineTuning()
        tuning.skyThumbnailFailureMemory = .milliseconds(150)
        let codecs = ThumbnailCodecs()
        codecs.fails.update { $0 = true }
        let rig = try await Rig(codecs: codecs, tuning: tuning)
        await rig.file("m-1", path: Self.flat, still: Self.still())
        #expect(try await !rig.thumbnail("m-1").isThumbnail)
        #expect(try await !rig.thumbnail("m-1").isThumbnail && codecs.calls.value.count == 1)
        codecs.fails.update { $0 = false }
        try await Task.sleep(for: .milliseconds(300))
        let made = try await rig.thumbnail("m-1")
        #expect(made.isThumbnail && codecs.calls.value.count == 2, "and it works now")
    }

    @MainActor @Test func aLightTheLogDoesNotHoldAndAPictureOfNoKnownSizeAreAnsweredWithTheWholePicture() async throws {
        let rig = try await Rig()
        // A picture whose entry is not in the log (the line is not there, or the drive did not give it): no path, so no close-up: not guessed at.
        rig.log.writeStill(Self.still(), entryID: "lost", camera: rig.cameraID, night: Self.night, folder: rig.recordings.url)
        // A picture whose size cannot be read.
        await rig.file("odd", path: Self.flat, still: SkyLogStoreTests.jpeg("no size in it"))
        await rig.log.flush()
        let lost = try await rig.thumbnail("lost")
        let odd = try await rig.thumbnail("odd")
        #expect(!lost.isThumbnail && lost.jpeg == Self.still() && !odd.isThumbnail && odd.jpeg == SkyLogStoreTests.jpeg("no size in it"))
        #expect(rig.fake.calls.value.isEmpty, "the codecs were not asked for either")
        #expect(!FileManager.default.fileExists(atPath: rig.file(of: "lost").path(percentEncoded: false)) && !FileManager.default.fileExists(atPath: rig.file(of: "odd").path(percentEncoded: false)))
    }

    @MainActor @Test func aThumbnailTheCodecsMadeWiderThanAskedIsNotKept() async throws {
        // The codecs answer a picture 1,200 wide where 480 was the most asked for: not a thumbnail, so not kept and not served as one.
        let rig = try await Rig(codecs: ThumbnailCodecs(wide: true))
        await rig.file("m-1", path: Self.flat, still: Self.still())
        let answer = try await rig.thumbnail("m-1")
        #expect(!answer.isThumbnail && answer.jpeg == Self.still())
        #expect(!FileManager.default.fileExists(atPath: rig.file(of: "m-1").path(percentEncoded: false)))
    }

    @MainActor @Test func aDriveWithNoRoomGetsNoNewThumbnailsAndTheWholePictureIsServedInstead() async throws {
        let room = Box(false)
        var tuning = EngineTuning()
        tuning.skyThumbnailRoom = { room.value }
        let codecs = ThumbnailCodecs()
        let rig = try await Rig(codecs: codecs, tuning: tuning)
        await rig.file("m-1", path: Self.flat, still: Self.still())
        await rig.file("m-2", path: Self.flat, still: Self.still("another"))
        // A drive that is close to pausing every camera's recording keeps what it has and takes nothing more (Ruling S27, as the pictures themselves).
        let answer = try await rig.thumbnail("m-1")
        #expect(!answer.isThumbnail && answer.jpeg == Self.still() && codecs.calls.value.isEmpty, "the picture already on the drive; no thumbnail made or kept")
        #expect(!FileManager.default.fileExists(atPath: rig.file(of: "m-1").path(percentEncoded: false)))
        // When there is room again it is made at the next request: no failure was remembered.
        room.update { $0 = true }
        #expect(try await rig.thumbnail("m-1").isThumbnail && codecs.calls.value.count == 1)
        // A thumbnail that is kept is served whatever the drive has.
        room.update { $0 = false }
        #expect(try await rig.thumbnail("m-1").isThumbnail && codecs.calls.value.count == 1, "kept ones are only read")
        #expect(try await !rig.thumbnail("m-2").isThumbnail)
    }

    // MARK: Off the hot path, two at a time, the newest first

    @MainActor @Test func atMostTwoAreMadeAtATimeWhateverIsAsked() async throws {
        let codecs = ThumbnailCodecs(hold: true)
        let rig = try await Rig(codecs: codecs)
        let ids = (1...6).map { "c-\($0)" }
        for id in ids { await rig.file(id, path: Self.flat, still: Self.still(id)) }
        let engine = rig.engine, camera = rig.cameraID
        let results = Task { () -> [Bool] in
            await withTaskGroup(of: Bool.self) { group in
                for id in ids { group.addTask { (try? await engine.skyStillThumbnail(cameraID: camera, night: Self.night, entryID: id).isThumbnail) ?? false } }
                var answers: [Bool] = []
                for await answer in group { answers.append(answer) }
                return answers
            }
        }
        #expect(await eventually(timeout: .seconds(30)) { codecs.active.value == 2 }, "two are being made")
        try await Task.sleep(for: .milliseconds(200))
        #expect(codecs.active.value == 2 && codecs.calls.value.count == 2, "and no more than two, however many ask: \(codecs.calls.value.count) started")
        codecs.release(6)
        let done = await results.value
        #expect(done.count == 6 && done.allSatisfy { $0 }, "all six get their thumbnails")
        #expect(codecs.mostActive.value == 2 && codecs.calls.value.count == 6)
    }

    @MainActor @Test func requestsAreMadeInTheOrderTheyCameAndOneThatFindsTheQueueFullIsAnsweredWithTheWholeStillAtOnce() async throws {
        var tuning = EngineTuning()
        tuning.skyThumbnailWaiting = 2
        let codecs = ThumbnailCodecs(hold: true)
        let rig = try await Rig(codecs: codecs, tuning: tuning)
        let ids = (1...6).map { "n-\($0)" }
        for id in ids { await rig.file(id, path: Self.flat, still: Self.still(id)) }
        let engine = rig.engine, camera = rig.cameraID
        func ask(_ id: String) -> Task<SkyStillPicture, any Error> { Task { try await engine.skyStillThumbnail(cameraID: camera, night: Self.night, entryID: id) } }

        let first = ask("n-1"), second = ask("n-2")
        #expect(await eventually(timeout: .seconds(30)) { codecs.active.value == 2 }, "the first two are being made")
        let third = ask("n-3")
        #expect(await eventually(timeout: .seconds(30)) { engine.skyThumbnails.waitingCount == 1 })
        let fourth = ask("n-4")
        #expect(await eventually(timeout: .seconds(30)) { engine.skyThumbnails.waitingCount == 2 })
        // One more than the queue holds: it is answered with the whole picture at once, and the two that wait keep their places.
        let overflowed = try await ask("n-5").value
        #expect(!overflowed.isThumbnail && overflowed.jpeg == Self.still("n-5"), "n-5 found the queue full")
        #expect(engine.skyThumbnails.waitingCount == 2 && codecs.calls.value.count == 2)

        // One place at a time, so that the order the gate gives the places in is the order the codecs see (two places freed at once would start
        // their two on the concurrent queue in either order, and on a loaded machine did).
        codecs.release(1)
        #expect(await eventually(timeout: .seconds(30)) { codecs.calls.value.count == 3 })
        codecs.release(1)
        #expect(await eventually(timeout: .seconds(30)) { codecs.calls.value.count == 4 })
        codecs.release(2)
        let all = try await [first.value, second.value, third.value, fourth.value]
        #expect(all.allSatisfy { $0.isThumbnail })
        // The two that were first are made first (in either order); then the ones that waited, in the order they came.
        let order = codecs.calls.value.map { ThumbnailCodecs.word(of: $0.input) }
        #expect(Set(order.prefix(2)) == ["n-1", "n-2"] && Array(order.suffix(2)) == ["n-3", "n-4"], "\(order)")
        #expect(codecs.calls.value.count == 4, "n-5 was not made")
    }

    @MainActor @Test func aRequestThatWaitedForItsTwinFindsTheThumbnailAlreadyMade() async throws {
        let codecs = ThumbnailCodecs(holdOnly: ["t-1", "t-2"])
        let rig = try await Rig(codecs: codecs)
        for id in ["t-1", "t-2", "t-3"] { await rig.file(id, path: Self.flat, still: Self.still(id)) }
        let engine = rig.engine, camera = rig.cameraID
        func ask(_ id: String) -> Task<SkyStillPicture, any Error> { Task { try await engine.skyStillThumbnail(cameraID: camera, night: Self.night, entryID: id) } }
        let a = ask("t-1"), b = ask("t-2")
        #expect(await eventually(timeout: .seconds(30)) { codecs.active.value == 2 }, "both places are taken")
        // Two ask for the same picture while both places are taken: they wait.
        let twin = ask("t-3")
        #expect(await eventually(timeout: .seconds(30)) { engine.skyThumbnails.waitingCount == 1 })
        let other = ask("t-3")
        #expect(await eventually(timeout: .seconds(30)) { engine.skyThumbnails.waitingCount == 2 })
        // One place frees: the newest of the two takes it and makes the picture's thumbnail. The other gets a place only when that one is done (the second place
        // is still taken), and finds it on the drive.
        codecs.release(word: "t-1")
        let first = try await a.value
        let made = try await other.value
        let found = try await twin.value
        #expect(first.isThumbnail && made.isThumbnail && found.isThumbnail)
        #expect(codecs.calls.value.map { ThumbnailCodecs.word(of: $0.input) }.sorted() == ["t-1", "t-2", "t-3"], "t-3 was made once: \(codecs.calls.value.count) calls")
        #expect(made.jpeg == found.jpeg)
        codecs.release(word: "t-2")
        #expect(try await b.value.isThumbnail)
    }

    @MainActor @Test func aCodecThatHangsIsGivenUpOnAndTheWholeStillAnswers() async throws {
        var tuning = EngineTuning()
        tuning.skyThumbnailDeadline = .milliseconds(250)
        let codecs = ThumbnailCodecs(hold: true)
        let rig = try await Rig(codecs: codecs, tuning: tuning)
        await rig.file("h-1", path: Self.flat, still: Self.still())
        let answer = try await rig.thumbnail("h-1")
        #expect(!answer.isThumbnail && answer.jpeg == Self.still(), "the picture came back though the codecs did not")
        codecs.release()   // and the one that hung can go
        #expect(await eventually(timeout: .seconds(30)) { codecs.active.value == 0 })
    }

    // MARK: How big a night's pictures are

    @MainActor @Test func theNightSaysHowBigItsPicturesAreFromTheNewestThatCanBeRead() async throws {
        let rig = try await Rig()
        #expect(try await rig.night().picture == nil, "a night without a light")
        await rig.file("p-1", still: nil, hour: 20)
        #expect(try await rig.night().picture == nil, "lights without a picture")
        await rig.file("p-2", still: SkyThumbnailStoreTests.still("old", width: 1280, height: 720), hour: 21)
        await rig.file("p-3", still: SkyThumbnailStoreTests.still("new", width: 1920, height: 852), hour: 22)
        #expect(try await rig.night().picture == SkyPictureSize(width: 1920, height: 852), "the newest light with a picture")
        await rig.file("p-4", still: SkyLogStoreTests.jpeg("no size"), hour: 23)
        #expect(try await rig.night().picture == SkyPictureSize(width: 1920, height: 852), "one that cannot be read is passed over")
        // The pictures are gone (a drive that was cleaned, the night’s budget): the entries still say they had one, and the night says nothing.
        try FileManager.default.removeItem(at: SkyLogStore.stillFile(folder: rig.recordings.url, camera: rig.cameraID, night: Self.night, id: "p-3"))
        #expect(try await rig.night().picture == SkyPictureSize(width: 1280, height: 720))
        try FileManager.default.removeItem(at: SkyLogStore.stillFile(folder: rig.recordings.url, camera: rig.cameraID, night: Self.night, id: "p-2"))
        #expect(try await rig.night().picture == nil)
        #expect(try await rig.night().entries.count == 4, "the entries are all there")
    }
}

// MARK: - The gate

/// The places the thumbnails' work waits for (`SkyThumbnailGate`): at most so many at a time, in the order asked, a full queue sends the next away, a waiter that is
/// cancelled leaves.
@Suite(.timeLimit(.minutes(1))) struct SkyThumbnailGateTests {
    /// Lets bodies wait until it is opened.
    actor Latch {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            for continuation in waiting { continuation.resume() }
            waiting = []
        }
    }

    @Test func atMostTheGivenNumberRunAtOnceAndTheOthersWaitInTheOrderTheyAsked() async throws {
        let gate = SkyThumbnailGate(places: 2, maximumWaiting: 10)
        let latch = Latch()
        let running = Box(0), most = Box(0), order = Box<[Int]>([])
        func ask(_ number: Int) -> Task<Int?, any Error> {
            Task {
                try await gate.run {
                    let inside = running.update { $0 += 1; return $0 }
                    most.update { $0 = max($0, inside) }
                    order.update { $0.append(number) }
                    await latch.wait()
                    running.update { $0 -= 1 }
                    return number
                }
            }
        }
        var tasks = [ask(1), ask(2)]
        #expect(await eventually(timeout: .seconds(30)) { running.value == 2 })
        for number in 3...6 {
            tasks.append(ask(number))
            #expect(await eventually(timeout: .seconds(30)) { gate.waitingCount == number - 2 }, "\(number) waits")
        }
        #expect(running.value == 2 && order.value.count == 2, "no more than two at once")
        await latch.open()
        var answers: [Int?] = []
        for task in tasks { answers.append(try await task.value) }
        #expect(answers == [1, 2, 3, 4, 5, 6])
        #expect(Array(order.value.suffix(4)) == [3, 4, 5, 6], "the ones that waited went in the order they asked: \(order.value)")
        #expect(most.value == 2 && gate.waitingCount == 0)
    }

    @Test func aFullQueueSendsTheNextAwayAtOnceAndKeepsThePlacesOfTheOnesThatWait() async throws {
        let gate = SkyThumbnailGate(places: 1, maximumWaiting: 2)
        let latch = Latch()
        let ran = Box<[Int]>([])
        func ask(_ number: Int) -> Task<Int?, any Error> {
            Task { try await gate.run { ran.update { $0.append(number) }; await latch.wait(); return number } }
        }
        let first = ask(1)
        #expect(await eventually(timeout: .seconds(30)) { ran.value == [1] })
        let second = ask(2)
        #expect(await eventually(timeout: .seconds(30)) { gate.waitingCount == 1 })
        let third = ask(3)
        #expect(await eventually(timeout: .seconds(30)) { gate.waitingCount == 2 })
        let fourth = try await ask(4).value
        #expect(fourth == nil, "the queue was full: sent away without running")
        #expect(gate.waitingCount == 2 && ran.value == [1])
        await latch.open()
        let answers = [try await first.value, try await second.value, try await third.value]
        #expect(answers == [1, 2, 3])
        #expect(ran.value == [1, 2, 3], "and 4 never ran")
    }

    @Test func aWaiterWhoseTaskIsCancelledLeavesTheQueueAndNeverRuns() async throws {
        let gate = SkyThumbnailGate(places: 1, maximumWaiting: 5)
        let latch = Latch()
        let ran = Box<[Int]>([])
        func ask(_ number: Int) -> Task<Int?, any Error> {
            Task { try await gate.run { ran.update { $0.append(number) }; await latch.wait(); return number } }
        }
        let first = ask(1)
        #expect(await eventually(timeout: .seconds(30)) { ran.value == [1] })
        let second = ask(2), third = ask(3)
        #expect(await eventually(timeout: .seconds(30)) { gate.waitingCount == 2 })
        second.cancel()
        await #expect(throws: CancellationError.self) { _ = try await second.value }
        #expect(gate.waitingCount == 1, "it left the queue when it was cancelled")
        await latch.open()
        let answers = [try await first.value, try await third.value]
        #expect(answers == [1, 3])
        #expect(ran.value == [1, 3], "the cancelled one never ran")
        // A task cancelled before it asks does not take a place either.
        let late = Task { () -> Int? in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await gate.run { 9 }
        }
        await #expect(throws: CancellationError.self) { _ = try await late.value }
        #expect(gate.waitingCount == 0)
        let free = try await gate.run { 5 }
        #expect(free == 5, "and the places are all free")
    }
}
