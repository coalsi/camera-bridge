import BridgeSupport
@testable import CameraAdapters
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

// The rules' probable planes and satellites keep a picture, so that the owner can check the rules by eye (2026-10-26), outside the hour's 200,
// which stay the unexplained lights' and the rules' meteors', bugs' and birds'; the backfill makes the older ones'; and a picture's small one is
// made when the picture is written, at low priority in the thumbnails' own places, not at the grid's first view.

extension SkyDetectorTests {
    // MARK: Which lights have a picture, and which count in the hour

    @Test func theRulesPlanesAndSatellitesWantAPictureButNotTheHoursRoom() {
        // What nothing explains, and the rules' meteors, bugs and birds: a picture, and a place in the hour's 200, as before.
        for (label, source) in [(SkyLabel.unexplained, SkyLabelSource?.none), (.meteor, .rule), (.bug, .rule), (.bird, .rule)] {
            #expect(SkyLightFilter.wantsStill(label, by: source) && SkyLightFilter.countsAgainstTheHour(label, by: source), "\(label)")
        }
        // The rules' probable planes and satellites, and a satellite's flare: a picture, to check the rules by eye, but no place in the hour's 200.
        for (label, source) in [(SkyLabel.probablePlane, SkyLabelSource?.some(.rule)), (.probableSatellite, .rule), (.satelliteFlare, nil), (.satelliteFlare, .orbit)] {
            #expect(SkyLightFilter.wantsStill(label, by: source) && !SkyLightFilter.countsAgainstTheHour(label, by: source), "\(label) by \(String(describing: source))")
        }
        // A flight's planes (a probable one while the aim is rough) and an orbit's named satellite: neither.
        for (label, source) in [(SkyLabel.plane, SkyLabelSource?.some(.flight)), (.probablePlane, .flight), (.satellite, .orbit)] {
            #expect(!SkyLightFilter.wantsStill(label, by: source) && !SkyLightFilter.countsAgainstTheHour(label, by: source), "\(label) by \(String(describing: source))")
        }
    }

    /// A steady light in tile `index` (as `spread` places them), going 4 analysed pixels a second for 8 s: the rules call it a probable satellite
    /// or plane at night, and it stays in its tile, so that no spot gets busy.
    static func steady(_ index: Int, at start: Date) -> SkyTrack {
        let tile = index % 50
        let x = Double(tile % 10) * 64, y = min(Double(tile / 10) * 64, 230)
        return straightTrack(from: (x + 10, y + 20), pixelsPerSecond: 4, seconds: 8, at: start)
    }

    @Test func aBusyHourOfProbableSatellitesLeavesTheHoursRoomToTheUnexplained() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        let hour = Self.start
        // Thirty steady lights in one clock hour (the rules' probable satellites and planes), then 201 that nothing explains.
        for index in 0..<30 {
            let at = hour.addingTimeInterval(Double(index) * 10)
            rig.clock.set(at.addingTimeInterval(10))
            await rig.detector.handle(Self.steady(index, at: at), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        }
        for index in 0..<201 {
            let at = hour.addingTimeInterval(400 + Double(index) * 15)
            rig.clock.set(at.addingTimeInterval(6))
            await rig.detector.handle(Self.spread(index, at: at), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        }
        let entries = await rig.logged().entries
        let probable = entries.filter { $0.by == .rule && [.probablePlane, .probableSatellite].contains($0.label) }
        #expect(probable.count == 30 && probable.allSatisfy(\.hasStill), "each with its picture: \(entries.map(\.label))")
        #expect(entries.filter { $0.label == .unexplained }.count == 200 && entries.count == 230, "the hour's 200 are the unexplained lights' still")
        #expect(rig.stillsAsked.value.count == 230)
        for entry in probable {
            #expect(rig.log.still(camera: rig.camera, night: rig.night(entry.start), entryID: entry.id, folder: rig.recordings.url) != nil)
        }
        // The one more is counted, for the hour's line.
        await rig.detector.tick(at: hour.addingTimeInterval(3_660))
        await rig.log.flush()
        #expect(rig.log.contents(camera: rig.camera, night: rig.night(hour), folder: rig.recordings.url).capped == [SkyCappedHour(hour: hour, count: 1)])
        await rig.detector.stop()
    }

    // MARK: Made later

    @Test func theBackfillPicksUpTheRulesPlanesAndSatellitesButNotAFlightsOrAnOrbits() {
        func entry(_ id: String, _ label: SkyLabel, by source: SkyLabelSource?, hasStill: Bool = false) -> SkyEntry {
            var entry = SkyLogStoreTests.entry(id, SkyLogStoreTests.local(24, 21), label: label, hasStill: hasStill)
            entry.by = source
            return entry
        }
        var backfill = SkyStillBackfill()
        let lights = [entry("u", .unexplained, by: nil), entry("pp", .probablePlane, by: .rule), entry("ps", .probableSatellite, by: .rule),
                      entry("fl", .satelliteFlare, by: nil), entry("m", .meteor, by: .rule), entry("fp", .probablePlane, by: .flight), entry("p", .plane, by: .flight),
                      entry("s", .satellite, by: .orbit), entry("had", .probableSatellite, by: .rule, hasStill: true)]
        backfill.refill([(night: SkyLogStoreTests.night, entries: lights)], complete: true, at: SkyLogStoreTests.local(25, 3))
        var ids: [String] = []
        while let item = backfill.next() { ids.append(item.id) }
        #expect(Set(ids) == ["u", "pp", "ps", "fl", "m"], "\(ids)")
    }

    @Test func aProbableSatelliteLoggedWithoutAPictureGetsOneFromTheRecording() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        // The drive was short of room when the light was logged (or an older build logged it with none).
        rig.room.set(false)
        rig.clock.set(Self.start.addingTimeInterval(10))
        await rig.detector.handle(Self.steady(3, at: Self.start), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        let logged = try #require(await rig.logged().entries.first)
        #expect(logged.by == .rule && [.probablePlane, .probableSatellite].contains(logged.label) && !logged.hasStill)
        rig.room.set(true)
        rig.recorded.set(.made(SkyLogStoreTests.jpeg("recorded")))
        await rig.detector.tick(at: Self.start.addingTimeInterval(700))
        #expect(rig.recordedAsked.value.count == 1)
        let entry = try #require(await rig.logged().entries.first)
        #expect(entry.id == logged.id && entry.hasStill)
        #expect(rig.log.still(camera: rig.camera, night: rig.night(entry.start), entryID: entry.id, folder: rig.recordings.url) == SkyLogStoreTests.jpeg("recorded"))
        await rig.detector.stop()
    }

    // MARK: Its small picture

    @Test func aPictureWrittenLiveOrLaterAsksForItsSmallOne() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        rig.clock.set(Self.start.addingTimeInterval(6))
        await rig.detector.handle(Self.spread(1, at: Self.start), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        let live = try #require(await rig.logged().entries.first)
        #expect(live.hasStill && rig.stillsWritten.value == ["\(rig.night(live.start))/\(live.id)"], "\(rig.stillsWritten.value)")
        // No picture, no small one: the drive is short of room.
        rig.room.set(false)
        rig.clock.set(Self.start.addingTimeInterval(66))
        await rig.detector.handle(Self.spread(2, at: Self.start.addingTimeInterval(60)), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        let later = try #require(await rig.logged().entries.first { $0.id != live.id })
        #expect(!later.hasStill && rig.stillsWritten.value.count == 1)
        // Its picture is made from the recording later: its small one is asked for then.
        rig.room.set(true)
        rig.recorded.set(.made(SkyLogStoreTests.jpeg("recorded")))
        await rig.detector.tick(at: Self.start.addingTimeInterval(800))
        #expect(rig.stillsWritten.value == ["\(rig.night(live.start))/\(live.id)", "\(rig.night(later.start))/\(later.id)"], "\(rig.stillsWritten.value)")
        await rig.detector.stop()
    }
}

// MARK: - The small one, made with the picture

extension SkyThumbnailEngineTests {
    @MainActor @Test func aPictureJustWrittenHasItsSmallOneBeforeThePageAsks() async throws {
        let rig = try await Rig()
        let camera = try #require(rig.engine.configurations.first { $0.id == rig.cameraID })
        let context = try #require(rig.engine.skyContext(camera))
        // The detector writes a light's picture and its line (they wait on the log's queue), then says so.
        var entry = SkyLogStoreTests.entry("w-1", SkyLogStoreTests.local(24, 21), hasStill: true)
        entry.path = Self.flat.enumerated().map { SkyPathPoint(t: Double($0.offset), x: $0.element.0, y: $0.element.1) }
        rig.log.writeStill(Self.still(), entryID: "w-1", camera: rig.cameraID, night: Self.night, folder: rig.recordings.url)
        rig.log.record(entry, night: Self.night, folder: rig.recordings.url)
        context.stillWritten("w-1", Self.night)
        #expect(await eventually(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: rig.file(of: "w-1").path(percentEncoded: false)) },
                "made with the picture, not at the grid's first view")
        #expect(rig.fake.calls.value.count == 1 && rig.fake.calls.value.first?.crop == ImageCrop(x: 768, y: 254, width: 384, height: 216),
                "cut around the light, as the page's request cuts it")
        // The page's first view reads it: nothing is made again.
        let first = try await rig.thumbnail("w-1")
        let kept = try Data(contentsOf: rig.file(of: "w-1"))
        #expect(first.isThumbnail && first.jpeg == kept && rig.fake.calls.value.count == 1)
        // Said again (the picture written again): kept already, nothing is made.
        context.stillWritten("w-1", Self.night)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.fake.calls.value.count == 1)
    }

    @MainActor @Test func noSmallOneIsMadeAheadWithoutRoomOrWithoutAPicture() async throws {
        let rig = try await Rig(room: false)
        let camera = try #require(rig.engine.configurations.first { $0.id == rig.cameraID })
        let context = try #require(rig.engine.skyContext(camera))
        await rig.file("r-1", path: Self.flat, still: Self.still())
        await rig.file("r-2", path: Self.flat, still: nil)
        context.stillWritten("r-1", Self.night)
        context.stillWritten("r-2", Self.night)
        try await Task.sleep(for: .milliseconds(400))
        #expect(rig.fake.calls.value.isEmpty && !FileManager.default.fileExists(atPath: rig.file(of: "r-1").path(percentEncoded: false)),
                "a drive close to pausing the recording gets no new small pictures, as it gets no new pictures")
    }
}

// MARK: - Made ahead, after the page's

extension SkyThumbnailGateTests {
    @Test func aPageRequestGoesBeforeTheSmallPicturesMadeAhead() async throws {
        let gate = SkyThumbnailGate(places: 1, maximumWaiting: 4)
        let latch = Latch()
        let ran = Box<[String]>([])
        func ask(_ name: String, ahead: Bool) -> Task<String?, any Error> {
            Task { try await gate.run(background: ahead) { ran.update { $0.append(name) }; await latch.wait(); return name } }
        }
        let first = ask("page-1", ahead: false)
        #expect(await eventually(timeout: .seconds(30)) { ran.value == ["page-1"] })
        let ahead1 = ask("ahead-1", ahead: true)
        #expect(await eventually(timeout: .seconds(30)) { gate.waitingCount == 1 })
        let ahead2 = ask("ahead-2", ahead: true)
        #expect(await eventually(timeout: .seconds(30)) { gate.waitingCount == 2 })
        let second = ask("page-2", ahead: false)
        #expect(await eventually(timeout: .seconds(30)) { gate.waitingCount == 3 })
        await latch.open()
        let answers = [try await first.value, try await second.value, try await ahead1.value, try await ahead2.value]
        #expect(answers == ["page-1", "page-2", "ahead-1", "ahead-2"])
        #expect(ran.value == ["page-1", "page-2", "ahead-1", "ahead-2"], "the page's request went first, then the ones made ahead in their order: \(ran.value)")
    }

    @Test func theSmallPicturesMadeAheadNeverFillThePagesQueue() async throws {
        let gate = SkyThumbnailGate(places: 1, maximumWaiting: 2)
        let latch = Latch()
        let ran = Box<[String]>([])
        func ask(_ name: String, ahead: Bool) -> Task<String?, any Error> {
            Task { try await gate.run(background: ahead) { ran.update { $0.append(name) }; await latch.wait(); return name } }
        }
        let first = ask("page-1", ahead: false)
        #expect(await eventually(timeout: .seconds(30)) { ran.value == ["page-1"] })
        let ahead1 = ask("ahead-1", ahead: true), ahead2 = ask("ahead-2", ahead: true)
        #expect(await eventually(timeout: .seconds(30)) { gate.waitingCount == 2 })
        // The queue is full for the ones made ahead: the next is sent away (its picture's first view will make it).
        #expect(try await ask("ahead-3", ahead: true).value == nil)
        // The page's requests still wait their turn, two of them, as many as the queue holds.
        let second = ask("page-2", ahead: false), third = ask("page-3", ahead: false)
        #expect(await eventually(timeout: .seconds(30)) { gate.waitingCount == 4 })
        #expect(try await ask("page-4", ahead: false).value == nil, "and the next is answered at once")
        await latch.open()
        let answers = [try await first.value, try await second.value, try await third.value, try await ahead1.value, try await ahead2.value]
        #expect(answers == ["page-1", "page-2", "page-3", "ahead-1", "ahead-2"])
        #expect(gate.waitingCount == 0 && !ran.value.contains("ahead-3") && !ran.value.contains("page-4"))
    }
}
