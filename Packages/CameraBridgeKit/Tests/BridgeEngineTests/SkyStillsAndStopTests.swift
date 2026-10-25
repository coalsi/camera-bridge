import BridgeSupport
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

// Ruling S27, from the pre-beta check (they join `SkyDetectorTests`, `SkyServiceTests`, `SkyLogStoreTests` and the archive store's tests).
//
// Pictures of the sky must not fill the recordings drive, which pauses recording on every camera when its free space falls below its floor:
// a picture is taken only while the drive has at least twice its floor free; a camera's pictures stay under 2 GiB, the oldest nights' going
// first (never the logs or the recordings); a picture that could not be made smaller is not kept at full size.
//
// Stopping a detector must be quick, as the engine stops it with its locks held and the daemon gives the whole engine ten seconds: the lights
// still waiting are dropped, none takes a picture once the detector is told to stop, and the call returns within about a second whatever the
// light it is at work on is waiting for. These tests say what happened (how many pictures were made by the time the stop returned, whether it
// waited for a picture that was stuck) rather than how long a stop took on a machine that other tests have loaded: the old drain made thirty
// pictures first, and a wait for the stuck one would have been over only when it was.

extension SkyDetectorTests {
    static let gibibyte: UInt64 = 1_073_741_824

    // MARK: The drive's room

    @Test func picturesNeedTwiceTheFloorFreeOnTheRecordingsDrive() {
        func storage(free: UInt64, floor: UInt64 = 2 * Self.gibibyte, pause: ArchivePause? = nil) -> ArchiveStorageStatus {
            ArchiveStorageStatus(folder: URL(fileURLWithPath: "/recordings"), pause: pause, usedBytes: 0, freeBytes: free, totalBytes: 500 * Self.gibibyte,
                                 floorBytes: floor)
        }
        #expect(SkyLightFilter.stillRoomFactor == 2 && SkyLightFilter.stillBytesPerCamera == 2 * Self.gibibyte)
        #expect(!SkyLightFilter.stillsHaveRoom(nil), "the drive has not been measured yet")
        #expect(!SkyLightFilter.stillsHaveRoom(storage(free: 4 * Self.gibibyte - 1)), "under twice the floor")
        #expect(SkyLightFilter.stillsHaveRoom(storage(free: 4 * Self.gibibyte)), "twice the floor")
        #expect(SkyLightFilter.stillsHaveRoom(storage(free: 400 * Self.gibibyte, floor: 50 * Self.gibibyte)))
        #expect(!SkyLightFilter.stillsHaveRoom(storage(free: 90 * Self.gibibyte, floor: 50 * Self.gibibyte)), "a Mac's startup drive has a floor of 50 GiB")
        #expect(!SkyLightFilter.stillsHaveRoom(storage(free: 400 * Self.gibibyte, pause: .diskFull)), "recording is paused already")
        #expect(!SkyLightFilter.stillsHaveRoom(storage(free: 400 * Self.gibibyte, pause: .folderMissing)))
        #expect(!SkyLightFilter.stillsHaveRoom(storage(free: 400 * Self.gibibyte, floor: 0)), "a floor that is not known is not room")
    }

    @Test func noPictureIsTakenWhileTheDriveHasNoRoomForOneAndNoneIsCountedMeanwhile() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        let hour = Self.start
        func light(_ index: Int) -> SkyTrack {
            Self.straightTrack(from: (40, 30 + Double(index % 20) * 10), pixelsPerSecond: 5, seconds: 6, at: hour.addingTimeInterval(Double(index) * 20))
        }
        // The drive is nearly full: the lights are logged, with no picture asked for.
        rig.room.set(false)
        for index in 0..<5 { await rig.detector.handle(light(index), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256) }
        #expect(rig.stillsAsked.value.isEmpty)
        // It has room again: the hour's thirty pictures are all there still (the lights that were refused one did not use them up).
        rig.room.set(true)
        for index in 5..<40 { await rig.detector.handle(light(index), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256) }
        let entries = await rig.logged().entries.sorted { $0.start < $1.start }
        #expect(entries.count == 40)
        #expect(entries.prefix(5).allSatisfy { !$0.hasStill && $0.label == .unexplained }, "logged without a picture")
        #expect(entries.dropFirst(5).prefix(30).allSatisfy { $0.hasStill }, "the thirty after it have theirs")
        #expect(entries.suffix(5).allSatisfy { !$0.hasStill }, "and then the hour's limit")
        #expect(rig.stillsAsked.value.count == 30)
        await rig.detector.stop()
    }

    // MARK: A picture that could not be made smaller

    @Test func aPictureThatCouldNotBeMadeSmallerIsNotKeptAtFullSize() async throws {
        let codecs = SkyFakeCodecs()
        let full = Data("a 4256-wide picture".utf8)
        let resized = await BridgeEngine.skyStillJPEG(full, codecs: codecs)
        #expect(resized == full, "the fake resize answers the picture it was given")
        codecs.resizeFails.set(true)
        let failed = await BridgeEngine.skyStillJPEG(full, codecs: codecs)
        #expect(failed == nil, "no picture rather than the full-size one")
        codecs.resizeFails.set(false)
        let empty = await BridgeEngine.skyStillJPEG(Data(), codecs: codecs)
        #expect(empty == nil, "an empty answer is no picture")
        #expect(BridgeEngine.skyStillWidth == 1920)
    }

    // MARK: Stopping

    /// 200 fast lights, each a track that went 5 pixels a second for 6 s, in one clock hour.
    static func lights(_ count: Int) -> [SkyTrack] {
        (0..<count).map { Self.straightTrack(from: (40, 30 + Double($0 % 20) * 10), pixelsPerSecond: 5, seconds: 6, at: Self.start.addingTimeInterval(Double($0))) }
    }

    @Test func stoppingWithTwoHundredLightsWaitingTakesNoTimeAndNoMorePictures() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888, stillDelay: .milliseconds(300))
        defer { rig.remove() }
        await rig.detector.start()
        for track in Self.lights(200) { await rig.detector.receive(track, analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256) }
        // The queue is at work on the first, whose picture takes 0.3 s; 199 wait behind it. Draining them made thirty pictures (the hour's limit),
        // about ten seconds' work, before the stop returned.
        #expect(await eventually(timeout: .seconds(30)) { rig.stillsAsked.value.count >= 1 })
        let began = ContinuousClock.now
        await rig.detector.stop()
        let took = began.duration(to: .now)
        let asked = rig.stillsAsked.value.count
        #expect(asked <= 2, "the stop did not wait for the queue: \(asked) pictures were asked for by the time it returned")
        #expect(took < .seconds(20), "stopping took \(took)")
        try await Task.sleep(for: .milliseconds(800))
        #expect(rig.stillsAsked.value.count == asked, "no picture is taken after the stop")
        let entries = await rig.logged().entries
        #expect(entries.count < 10, "the lights that waited are dropped, not logged: \(entries.count)")
    }

    @Test func stoppingDoesNotWaitForALightWhosePictureIsStuck() async throws {
        // A keyframe whose decode is stuck for half a minute (the decoder pool gives up on one after ten seconds).
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888, stillDelay: .seconds(30))
        defer { rig.remove() }
        await rig.detector.start()
        for track in Self.lights(3) { await rig.detector.receive(track, analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256) }
        #expect(await eventually(timeout: .seconds(30)) { rig.stillsAsked.value.count >= 1 })
        let began = ContinuousClock.now
        await rig.detector.stop()
        let took = began.duration(to: .now)
        #expect(took < .seconds(25), "the stuck decode was not waited for to its end: \(took)")
        #expect(took >= .milliseconds(500), "but it was given the time: \(took)")
        #expect(rig.stillsAsked.value.count == 1, "the two behind it are not even tried")
    }

    @Test func aStoppedDetectorsAimIsNotWrittenAgainByWorkThatOutlivesTheStop() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var random = SkyRandom(seed: 5)
        let model = Self.singleModel
        let epoch = SkyFixtures.aimEpoch
        let store = SkyAimStore(directory: directory.url, log: Log(category: "SkyTest"), start: model, pictureWidth: 1920, pictureHeight: 1080,
                                now: { epoch.addingTimeInterval(60) }, seed: 7)
        _ = await store.add(SkyFixtures.planeTracks(through: model, perLens: 3, samples: 4, noise: 0.05, using: &random))
        func files() -> [String: Data] {
            Dictionary(uniqueKeysWithValues: [SkyAimStore.aimFileName, SkyAimStore.matchesFileName].map { ($0, (try? Data(contentsOf: directory.url.appending(path: $0))) ?? Data()) })
        }
        let before = files()
        #expect(before.values.allSatisfy { !$0.isEmpty }, "the aim and its matches are on disk")
        store.close()   // from outside the actor: a fit that is running does not hold it up
        _ = await store.add(SkyFixtures.planeTracks(through: model, perLens: 3, samples: 4, noise: 0.05, using: &random))
        await store.reset(reason: "again")
        await store.setStart(SkyCameraModel.initial(facing: 10, tilt: 20, pictureWidth: 1920, pictureHeight: 1080), pictureWidth: 1920, pictureHeight: 1080)
        #expect(files() == before, "nothing is written after the store is closed")
        #expect(await store.status().note == "again", "it goes on in memory")
    }
}

// MARK: - A camera's pictures on the drive

extension SkyLogStoreTests {
    /// A camera's folder of one night's pictures: `count` files of `size` bytes, and the night's log beside it.
    private static func makeNight(_ name: String, of camera: UUID, in folder: URL, pictures count: Int, size: Int) throws {
        let manager = FileManager.default
        let cameraFolder = folder.appending(path: ".sky/\(camera.uuidString)", directoryHint: .isDirectory)
        let stills = cameraFolder.appending(path: name, directoryHint: .isDirectory)
        try manager.createDirectory(at: stills, withIntermediateDirectories: true)
        for index in 0..<count { try Data(repeating: 7, count: size).write(to: stills.appending(path: "p-\(index).jpg")) }
        try Data("{}\n".utf8).write(to: cameraFolder.appending(path: "\(name).jsonl"))
    }

    private static func contents(_ camera: UUID, in folder: URL) -> [String] {
        let url = folder.appending(path: ".sky/\(camera.uuidString)", directoryHint: .isDirectory)
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []).sorted()
    }

    @Test func aCamerasPicturesStayUnderTheLimitByLosingTheOldestNightsFirst() throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let nights = ["2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23"]
        for night in nights { try Self.makeNight(night, of: Self.camera, in: folder.url, pictures: 10, size: 100) }   // 1,000 bytes a night
        for night in nights.prefix(3) { try Self.makeNight(night, of: Self.other, in: folder.url, pictures: 6, size: 100) }   // 600 a night, 1,800 in all
        // What is not a night's pictures is neither counted nor touched: a folder with another name, and a file.
        let notes = folder.url.appending(path: ".sky/\(Self.camera.uuidString)/notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5_000).write(to: notes.appending(path: "big.bin"))
        try Data(repeating: 1, count: 5_000).write(to: folder.url.appending(path: ".sky/readme.txt"))

        let removed = Box<[String]>([])
        let first = SkyLogStore.pruneStills(folder: folder.url, maximumBytes: 2_500, remove: { url in
            removed.update { $0.append(url.lastPathComponent) }
            try FileManager.default.removeItem(at: url)
        })
        #expect(first.nights == 2 && first.bytes == 2_000, "the oldest two of the first camera, which had 4,000 bytes: \(first)")
        #expect(removed.value == ["2026-10-20", "2026-10-21"])
        #expect(Self.contents(Self.camera, in: folder.url) == ["2026-10-20.jsonl", "2026-10-21.jsonl", "2026-10-22", "2026-10-22.jsonl", "2026-10-23",
                                                              "2026-10-23.jsonl", "notes"], "the logs stay, whatever happens to the pictures")
        #expect(Self.contents(Self.other, in: folder.url).count == 6, "the other camera had room, and is not touched")
        #expect(SkyLogStore.pruneStills(folder: folder.url, maximumBytes: 2_500).nights == 0, "nothing more to do")

        // A limit below one night's: the night in progress, the newest, is never taken.
        let tight = SkyLogStore.pruneStills(folder: folder.url, maximumBytes: 500)
        #expect(tight.nights == 3 && tight.bytes == 2_200, "one of the first camera and two of the other: \(tight)")
        #expect(Self.contents(Self.camera, in: folder.url).contains("2026-10-23") && !Self.contents(Self.camera, in: folder.url).contains("2026-10-22"))
        #expect(Self.contents(Self.other, in: folder.url).contains("2026-10-22") && !Self.contents(Self.other, in: folder.url).contains("2026-10-21"))
        #expect(SkyLogStore.pruneStills(folder: folder.url.appending(path: "nowhere"), maximumBytes: 1).nights == 0)
        #expect(SkyLogStore.pruneStills(folder: folder.url, maximumBytes: 0).nights == 0, "whatever the limit, the newest night's pictures stay")
    }

    @Test func aPictureFolderThatCannotBeDeletedIsLeftAndTheNextOldestGoes() throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        for night in ["2026-10-20", "2026-10-21", "2026-10-22"] { try Self.makeNight(night, of: Self.camera, in: folder.url, pictures: 10, size: 100) }
        let result = SkyLogStore.pruneStills(folder: folder.url, maximumBytes: 1_500, remove: { url in
            if url.lastPathComponent == "2026-10-20" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        #expect(result.nights == 1 && result.bytes == 1_000, "\(result)")
        #expect(Self.contents(Self.camera, in: folder.url).contains("2026-10-20") && !Self.contents(Self.camera, in: folder.url).contains("2026-10-21"))
        // Tried again next time.
        #expect(SkyLogStore.pruneStills(folder: folder.url, maximumBytes: 1_500).nights == 1)
        #expect(!Self.contents(Self.camera, in: folder.url).contains("2026-10-20"))
    }

    @Test func picturesAreNeverCountedOrDeletedThroughALink() throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let manager = FileManager.default
        let folder = parent.url.appending(path: "recordings", directoryHint: .isDirectory)
        let outside = parent.url.appending(path: "outside", directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        for night in ["2026-10-20", "2026-10-21"] { try Self.makeNight(night, of: Self.camera, in: folder, pictures: 10, size: 100) }
        // A night's folder that is a link to a big folder elsewhere: its size is not the camera's, and it is not followed or removed.
        let target = outside.appending(path: "2026-10-19", directoryHint: .isDirectory)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 50_000).write(to: target.appending(path: "big.jpg"))
        let cameraFolder = folder.appending(path: ".sky/\(Self.camera.uuidString)", directoryHint: .isDirectory)
        try manager.createSymbolicLink(at: URL(fileURLWithPath: ArchiveVolume.path(of: cameraFolder.appending(path: "2026-10-19"))), withDestinationURL: target)
        let result = SkyLogStore.pruneStills(folder: folder, maximumBytes: 1_500)
        #expect(result.nights == 1 && result.bytes == 1_000, "the real nights alone: \(result)")
        #expect(manager.fileExists(atPath: target.appending(path: "big.jpg").path(percentEncoded: false)), "what the link pointed to is as it was")
        // `.sky` itself a link: nothing is read or removed.
        let linked = parent.url.appending(path: "linked", directoryHint: .isDirectory)
        try manager.createDirectory(at: linked, withIntermediateDirectories: false)
        try manager.createSymbolicLink(at: URL(fileURLWithPath: ArchiveVolume.path(of: linked.appending(path: ".sky"))), withDestinationURL: folder.appending(path: ".sky"))
        #expect(SkyLogStore.pruneStills(folder: linked, maximumBytes: 1).nights == 0)
    }
}

// MARK: - The janitor

extension ArchiveStoreLifecycleTests {
    @Test func retentionKeepsEachCamerasSkyPicturesUnderTheLimitAndLooksOnlyNowAndThen() async throws {
        let harness = try ArchiveStoreHarness(skyStillBytes: 2_500) { _ in }
        await harness.start(harness.settings(keepDays: 7, maxSizeGB: 10))
        // The store's clock is 2025-10-10 14:00 UTC and the keep time seven days before: these nights are all within it.
        let nights = ["2025-10-06", "2025-10-07", "2025-10-08", "2025-10-09"]
        let camera = SkyLogStoreTests.camera
        func pictures(_ night: String) throws {
            let folder = harness.root.url.appending(path: ".sky/\(camera.uuidString)/\(night)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<10 { try Data(repeating: 7, count: 100).write(to: folder.appending(path: "p-\(index).jpg")) }
        }
        func left() -> [String] {
            let folder = harness.root.url.appending(path: ".sky/\(camera.uuidString)")
            return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).sorted()
        }
        for night in nights { try pictures(night) }   // 4,000 bytes
        await harness.store.pruneEvents(harness.run)
        #expect(left() == ["2025-10-08", "2025-10-09"], "under 2,500 bytes by the oldest nights' pictures")

        // More pictures at once do not wake it: the folders are looked at every ten minutes at most.
        try pictures("2025-10-10")
        await harness.store.pruneEvents(harness.run)
        #expect(left() == ["2025-10-08", "2025-10-09", "2025-10-10"])
        harness.clock.update { $0 = $0.addingTimeInterval(SkyLightFilter.stillPruneInterval + 1) }
        await harness.store.pruneEvents(harness.run)
        #expect(left() == ["2025-10-09", "2025-10-10"], "and then it does")
    }
}

// MARK: - Stopping through the service

extension SkyServiceTests {
    @Test func stoppingADetectorWithLightsWaitingDoesNotHoldTheServiceUp() async throws {
        let data = try TemporaryDirectory(), recordings = try TemporaryDirectory()
        defer {
            data.remove()
            recordings.remove()
        }
        let asked = Box(0)
        let id = UUID()
        let context = SkyCameraDetector.Context(cameraID: id, cameraName: "North Sky", settings: SkyDetectorSettings(enabled: true, facing: 330, tilt: 15),
                                                observer: SkyFixtures.observer, zone: SkyDetectorRig.zone, pictureWidth: 4256, pictureHeight: 1888,
                                                folder: { recordings.url },
                                                still: { date in
                                                    asked.update { $0 += 1 }
                                                    try? await Task.sleep(for: .milliseconds(300))
                                                    return (SkyLogStoreTests.jpeg("still"), date)
                                                })
        let service = SkyService(dataDirectory: data.url, http: SkyFakeFeed(), logStore: SkyLogStore(log: .silent))
        let sky = SkySettings(location: Self.place)
        let detector = try #require(await service.update(settings: sky, cameras: [id: context])[id])
        for track in SkyDetectorTests.lights(200) { await detector.receive(track, analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256) }
        #expect(await eventually(timeout: .seconds(30)) { asked.value >= 1 })

        // The camera's switch goes off (the engine does this with its lock held): the service is free again without draining the queue (which
        // made thirty pictures, about ten seconds' work).
        let began = ContinuousClock.now
        await service.update(settings: sky, cameras: [:])
        let stopped = began.duration(to: .now)
        #expect(asked.value <= 2 && stopped < .seconds(20), "stopping took \(stopped), with \(asked.value) pictures asked for")
        // And the next change is not held up: the camera is switched on again.
        let running = await service.update(settings: sky, cameras: [id: context])
        #expect(running[id] != nil && running[id] !== detector)
        // Every detector stops together, and the service stops as quickly.
        await service.stop()
        let afterStop = await service.detector(id)
        #expect(afterStop == nil)
    }
}

// MARK: - Stopping through the engine

#if canImport(Darwin)
import PlatformApple

extension SkyEngineTests {
    /// The demo camera as a sky camera on a recordings drive with room to spare; its stills (the keyframes' decodes) take as long as `codecs` says.
    @MainActor private static func slowStillRig(recordings: TemporaryDirectory, codecs: SkyFakeCodecs)
        async throws -> (fixture: EngineFixture, camera: CameraConfiguration) {
        var tuning = EngineTuning.testing
        tuning.skyHTTP = SkyFakeFeed()
        tuning.skyPollInterval = .milliseconds(100)
        let folder = recordings.url.path(percentEncoded: false)
        let gibibyte = SkyDetectorTests.gibibyte
        let fixture = try await EngineFixture(tuning: tuning, configure: { settings in
            settings.plugins["sky"] = PluginState(enabled: true)
            settings.sky = SkyServiceTests.settings
            settings.nvrFolder = folder
        }, adjust: {
            $0.codecs = codecs
            $0.archivePolicy = ArchivePlatformPolicy(space: { _ in (total: 500 * gibibyte, free: 400 * gibibyte) }, isSystemVolume: { _ in false },
                                                     systemFloor: ArchivePlatformPolicy.linuxSystemFloor, directoryNaming: .cameraID)
        })
        var camera = EngineFixture.demoCamera(name: "Slow Sky")
        camera.skyDetector = SkyDetectorSettings(enabled: true, facing: 330, tilt: 15)
        try await fixture.engine.addCamera(camera, password: nil)
        await fixture.engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        return (fixture, camera)
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func stoppingTheSkyWithLightsWaitingDoesNotHoldTheEngineUp() async throws {
        let recordings = try TemporaryDirectory()
        defer { recordings.remove() }
        let codecs = SkyFakeCodecs(base: AppleMediaCodecs(), stillDelay: .milliseconds(400))
        let (fixture, added) = try await Self.slowStillRig(recordings: recordings, codecs: codecs)
        var camera = added
        #expect(await fixture.waitFor(.seconds(30)) { fixture.status(camera.id)?.sky?.running == true })
        #expect(await fixture.until(.seconds(30)) { fixture.engine.skyStillsHaveRoom() }, "the drive has room, once it has been measured")
        let detector = try #require(fixture.engine.skyDetectors[camera.id])
        for track in SkyDetectorTests.lights(200) { await detector.receive(track, analysisWidth: 640, analysisHeight: 360, pictureWidth: 640) }
        #expect(await fixture.until(.seconds(30)) { codecs.otherDecoders.value >= 1 }, "a light's picture is being made")

        // The camera's Sky Watcher goes off: the engine holds its operations lock while the detector stops, and the next operation is not held up.
        // (Draining the queue made thirty pictures first, a decoder each: about twelve seconds' work.)
        camera.skyDetector?.enabled = false
        let began = ContinuousClock.now
        try await fixture.engine.updateCamera(camera, password: nil)
        let switchedOff = began.duration(to: .now)
        let made = codecs.otherDecoders.value
        #expect(made <= 2 && switchedOff < .seconds(20), "switching it off took \(switchedOff), with \(made) pictures made")
        try await fixture.engine.updateSettings { $0.plugins["sky"] = PluginState(enabled: false) }
        try await Task.sleep(for: .milliseconds(900))
        #expect(codecs.otherDecoders.value == made, "no picture is made once the detector has stopped")
        await fixture.tearDown()
    }
}
#endif
