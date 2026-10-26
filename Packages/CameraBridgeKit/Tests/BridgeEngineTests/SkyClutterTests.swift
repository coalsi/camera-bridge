import BridgeSupport
import FMP4
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

// The owner's afternoon of 2026-10-25 (beta 0.1.123, North Sky): about 2,500 entries in 70 minutes that were not lights, tree tops and shimmer
// above the ground cut; then, with the ground raised, about four a minute of glare along the west edge in the late sun. Tested before they were
// built:
// - **busy spots** (`SkyClutterMap`): a tile of the analysed picture that keeps making tracks (kept or dropped) is busy, and a light that starts and
//   stays in busy tiles is only counted; the busy state decays over hours, a light that crosses out of busy tiles or a matched plane is never
//   suppressed, the map outlives a restart and goes with a changed card, and the status says how many spots it ignores;
// - **the Sun's guard** (`SkySunGuard`): while the Sun is up and within about 25° outside the view (40° while the aim is rough), a light whose whole
//   path lies in a band along the edge nearest it is only counted; with the Sun in the view its circle is the guard, and planes are still planes;
// - **the hourly cap**: at most 60 unexplained entries a camera and clock hour, the rest counted, with one line in the log for the hour;
// - **every logged light has its picture** (Ruling S31): no hourly limit of pictures, room while the drive has its floor and 1 GiB free, and the
//   pictures the log has not got are made later from the recordings, a few at a time, given up quietly when the recording is gone;
// - **reading**: a night whose file holds a huge day before it is read whole, and the lines a reader does not know are skipped.
// All made up, as in `SkyDetectorTests`: the place is 40.0000, −100.0000, nothing is downloaded.

// MARK: - Busy spots

@Suite struct SkyClutterMapTests {
    static let start = SkyFixtures.aimEpoch

    /// Points at these analysed pixels of a 640 × 284 picture (tiles of 64: ten across, five down).
    static func points(_ pixels: [(x: Double, y: Double)]) -> [PixelPoint] {
        pixels.map { PixelPoint(x: $0.x / 640, y: $0.y / 284) }
    }

    static func spot(_ tile: Int) -> SkyClutterFootprint { SkyClutterFootprint(start: tile, most: tile, tiles: [tile]) }

    @Test func aTrackCountsWhereItBeganAndWhereItSpentMostOfItsTime() throws {
        let map = SkyClutterMap(width: 640, height: 284)
        #expect(map.across == 10 && map.down == 5 && SkyClutterMap.tileSize == SkyFrameAnalyzer.tileSize)
        // Begun in tile 0 (x 0 to 63), seen most in tile 1 (x 64 to 127).
        let crossing = try #require(map.footprint(of: Self.points([(60, 10), (70, 10), (80, 12), (90, 14)])))
        #expect(crossing == SkyClutterFootprint(start: 0, most: 1, tiles: [0, 1]))
        let still = try #require(map.footprint(of: Self.points([(130, 70), (140, 75), (150, 80)])))
        #expect(still == SkyClutterFootprint(start: 12, most: 12, tiles: [12]), "row 1, column 2")
        // A tie goes to the tile it was in first; the picture's edges belong to its last column and row; what is off it is on its edge.
        #expect(map.footprint(of: Self.points([(10, 10), (70, 10)]))?.most == 0)
        #expect(map.tile(of: PixelPoint(x: 1, y: 1)) == 49 && map.tile(of: PixelPoint(x: -0.2, y: 0.5)) == 20)
        #expect(map.footprint(of: []) == nil && map.footprint(of: [PixelPoint(x: .nan, y: 0.5)]) == nil)
    }

    @Test func aSpotThatKeepsMakingTracksIsBusyUntilItQuietsDownOverHours() {
        var map = SkyClutterMap(width: 640, height: 284)
        for _ in 0..<9 { map.learn(Self.spot(12), at: Self.start) }
        #expect(map.score(12, at: Self.start) == 9 && !map.isBusy(12, at: Self.start))
        map.learn(Self.spot(12), at: Self.start)
        #expect(map.isBusy(12, at: Self.start), "ten tracks make a spot busy")
        #expect(!map.isBusy(13, at: Self.start) && map.busyTiles(at: Self.start) == [12])
        // A score falls to 1/e in two hours; a spot is busy until it falls under 5: ten at once are quiet again after 83 minutes.
        #expect(SkyClutterMap.timeConstant == 7_200 && SkyClutterMap.busyAt == 10 && SkyClutterMap.quietBelow == 5 && SkyClutterMap.maximumScore == 20)
        let quiet = Self.start.addingTimeInterval(SkyClutterMap.timeConstant * log(2))
        #expect(map.isBusy(12, at: quiet.addingTimeInterval(-60)) && !map.isBusy(12, at: quiet.addingTimeInterval(60)))
        // Between 5 and 10 a quiet spot stays quiet: it takes the score back to 10 to be busy again.
        var again = map
        let later = quiet.addingTimeInterval(600)
        for _ in 0..<3 { again.learn(Self.spot(12), at: later) }
        #expect(!again.isBusy(12, at: later), "\(again.score(12, at: later))")
        for _ in 0..<3 { again.learn(Self.spot(12), at: later) }
        #expect(again.isBusy(12, at: later), "\(again.score(12, at: later))")
        // A spot that went on all afternoon is capped at 20, so it is quiet again within three hours of its last track.
        var afternoon = SkyClutterMap(width: 640, height: 284)
        for index in 0..<240 { afternoon.learn(Self.spot(3), at: Self.start.addingTimeInterval(Double(index) * 15)) }
        let last = Self.start.addingTimeInterval(239 * 15)
        #expect(abs(afternoon.score(3, at: last) - 20) < 1e-9)
        let calm = last.addingTimeInterval(SkyClutterMap.timeConstant * log(4))
        #expect(afternoon.isBusy(3, at: calm.addingTimeInterval(-60)) && !afternoon.isBusy(3, at: calm.addingTimeInterval(60)))
        #expect(calm.timeIntervalSince(last) < 3 * 3_600)
        // A real sky's spot, three tracks an hour all night (planes coming over the same trees), is never busy; five an hour is.
        var night = SkyClutterMap(width: 640, height: 284), busier = SkyClutterMap(width: 640, height: 284)
        var everBusy = false
        for index in 0..<36 {
            let at = Self.start.addingTimeInterval(Double(index) * 1_200)
            night.learn(Self.spot(7), at: at)
            everBusy = everBusy || night.isBusy(7, at: at)
        }
        for index in 0..<60 { busier.learn(Self.spot(7), at: Self.start.addingTimeInterval(Double(index) * 720)) }
        #expect(!everBusy && busier.isBusy(7, at: Self.start.addingTimeInterval(59 * 720)))
        // A clock that went back neither ages nor grows a score.
        #expect(map.score(12, at: Self.start.addingTimeInterval(-3_600)) == 10)
    }

    @Test func aTrackIsCoveredOnlyWhenEveryTileItWasSeenInIsBusy() throws {
        var map = SkyClutterMap(width: 640, height: 284)
        for _ in 0..<10 { map.learn(Self.spot(0), at: Self.start) }
        let within = try #require(map.footprint(of: Self.points([(10, 10), (30, 20), (50, 40)])))
        #expect(map.covers(within, at: Self.start), "a light that starts and stays in the busy spot")
        let crossing = try #require(map.footprint(of: Self.points([(10, 10), (60, 10), (100, 10)])))
        #expect(!map.covers(crossing, at: Self.start), "a light that crosses out of it is logged")
        for _ in 0..<10 { map.learn(Self.spot(1), at: Self.start) }
        #expect(map.covers(crossing, at: Self.start), "unless it crosses into busy tiles only")
        #expect(!map.covers(within, at: Self.start.addingTimeInterval(5 * 3_600)), "hours later the spot is quiet")
    }

    @Test func busyTilesThatTouchAreOneSpot() {
        var map = SkyClutterMap(width: 640, height: 284)
        #expect(map.busySpots(at: Self.start) == 0 && SkyClutterMap.note(spots: 0) == nil)
        // Tiles 0 and 1 side by side, 11 under 1 and beside 0's corner: one spot. Tile 30 (row 3, column 0) and tile 9 (row 0, column 9): two more.
        for tile in [0, 1, 11, 30, 9] {
            for _ in 0..<10 { map.learn(Self.spot(tile), at: Self.start) }
        }
        #expect(map.busySpots(at: Self.start) == 3)
        #expect(SkyClutterMap.note(spots: 3) == "Ignoring 3 busy spots (trees, wires or glare)")
        #expect(SkyClutterMap.note(spots: 1) == "Ignoring 1 busy spot (trees, wires or glare)")
        // Column 9 and column 0 of the next row are not neighbours.
        var wrap = SkyClutterMap(width: 640, height: 284)
        for tile in [9, 10] {
            for _ in 0..<10 { wrap.learn(Self.spot(tile), at: Self.start) }
        }
        #expect(wrap.busySpots(at: Self.start) == 2)
    }

    @Test func theMapIsKeptAsItIs() throws {
        var map = SkyClutterMap(width: 1920, height: 852)
        for _ in 0..<12 { map.learn(SkyClutterFootprint(start: 345, most: 346, tiles: [345, 346]), at: Self.start) }
        map.learn(Self.spot(4), at: Self.start.addingTimeInterval(60))
        #expect(map.across == 30 && map.down == 14, "the owner's analysed picture")
        let data = try JSONEncoder().encode(map)
        let back = try JSONDecoder().decode(SkyClutterMap.self, from: data)
        #expect(back == map && back.busyTiles(at: Self.start.addingTimeInterval(60)) == [345, 346])
        #expect(!map.isEmpty && SkyClutterMap(width: 640, height: 284).isEmpty)
    }
}

// MARK: - The Sun's guard

@Suite struct SkySunGuardTests {
    /// A stitched dual camera facing north, 10° up: its left lens looks north-west, its outer edge west; its right lens north-east.
    static let dual = SkyCameraModel.initial(facing: 0, tilt: 10, pictureWidth: 4256, pictureHeight: 1888)

    @Test func theSunJustOutsideTheViewGuardsABandAlongTheEdgeNearestIt() throws {
        #expect(SkySunGuard.nearDegrees == 25 && SkySunGuard.roughNearDegrees == 40 && SkySunGuard.bandDegrees == 25 && SkySunGuard.roughBandDegrees == 40)
        // Low in the west-south-west, about 15° past the left lens's outer edge: North Sky's late afternoon.
        let sun = SkyDirection(azimuth: 255, elevation: 8)
        #expect(Self.dual.project(sun).isEmpty, "out of the picture")
        let rough = try #require(SkySunGuard.band(sun: sun, model: Self.dual, aim: .rough))
        #expect(rough.lens == 0 && rough.edge == .left && rough.sunDistance > 10 && rough.sunDistance < 20, "\(rough)")
        #expect(abs(rough.depth - 40.0 / 90) < 1e-9, "generous while the aim is rough: 40° of the lens's 90°")
        let good = try #require(SkySunGuard.band(sun: sun, model: Self.dual, aim: .good))
        #expect(good.lens == 0 && good.edge == .left && abs(good.depth - 25.0 / 90) < 1e-9)
        // 30° past it: within the rough aim's 40°, not the good aim's 25°; behind the camera, nothing.
        let thirty = SkyDirection(azimuth: 240, elevation: 8)
        #expect(SkySunGuard.band(sun: thirty, model: Self.dual, aim: .rough) != nil && SkySunGuard.band(sun: thirty, model: Self.dual, aim: .precise) == nil)
        #expect(SkySunGuard.band(sun: SkyDirection(azimuth: 180, elevation: 30), model: Self.dual, aim: .rough) == nil)
    }

    @Test func theSunInTheViewKeepsItsCircleAndNoBand() {
        let inside = SkyDirection(azimuth: 300, elevation: 12)
        #expect(!Self.dual.project(inside).isEmpty)
        #expect(SkySunGuard.band(sun: inside, model: Self.dual, aim: .rough) == nil)
        #expect(!SkyMask.circles(around: inside, radiusDegrees: SkyMask.sunRadiusDegrees, model: Self.dual, pictureWidth: 4256, pictureHeight: 1888).isEmpty,
                "the mask's circle of 15° around it is the guard there, as before")
    }

    @Test func aLightIsGuardedOnlyWhileItsWholePathIsInTheBand() {
        // The left lens's frame is x 0 to 0.5 of the picture: a depth of 0.4 of it is x 0 to 0.2.
        let left = SkySunGuard.Band(lens: 0, edge: .left, depth: 0.4, sunDistance: 15)
        let glare = [PixelPoint(x: 0.02, y: 0.7), PixelPoint(x: 0.1, y: 0.65), PixelPoint(x: 0.19, y: 0.6)]
        #expect(SkySunGuard.covers(glare, band: left, model: Self.dual))
        #expect(!SkySunGuard.covers(glare + [PixelPoint(x: 0.25, y: 0.6)], band: left, model: Self.dual), "a light that leaves the band is logged")
        #expect(!SkySunGuard.covers([PixelPoint(x: 0.9, y: 0.7)], band: left, model: Self.dual), "and so is the other lens's")
        #expect(!SkySunGuard.covers([], band: left, model: Self.dual))
        let right = SkySunGuard.Band(lens: 1, edge: .right, depth: 0.4, sunDistance: 15)
        #expect(SkySunGuard.covers([PixelPoint(x: 0.85, y: 0.5)], band: right, model: Self.dual) && !SkySunGuard.covers([PixelPoint(x: 0.75, y: 0.5)], band: right, model: Self.dual))
        let top = SkySunGuard.Band(lens: 1, edge: .top, depth: 0.3, sunDistance: 15), bottom = SkySunGuard.Band(lens: 0, edge: .bottom, depth: 0.3, sunDistance: 15)
        #expect(SkySunGuard.covers([PixelPoint(x: 0.6, y: 0.25)], band: top, model: Self.dual) && !SkySunGuard.covers([PixelPoint(x: 0.6, y: 0.35)], band: top, model: Self.dual))
        #expect(SkySunGuard.covers([PixelPoint(x: 0.3, y: 0.75)], band: bottom, model: Self.dual) && !SkySunGuard.covers([PixelPoint(x: 0.3, y: 0.65)], band: bottom, model: Self.dual))
    }

    @Test func aSingleLensIsGuardedAlongWhicheverOfItsEdgesIsNearest() throws {
        let single = SkyCameraModel.initial(facing: 90, tilt: 20, pictureWidth: 1920, pictureHeight: 1080)
        // High in the east, above the top edge; then south of east, past the right edge.
        let high = try #require(SkySunGuard.band(sun: SkyDirection(azimuth: 90, elevation: 66), model: single, aim: .good))
        #expect(high.lens == 0 && high.edge == .top && abs(high.depth - 25 / single.lenses[0].verticalFOV) < 1e-9, "\(high)")
        let right = try #require(SkySunGuard.band(sun: SkyDirection(azimuth: 155, elevation: 15), model: single, aim: .good))
        #expect(right.edge == .right && abs(right.depth - 25.0 / 100) < 1e-9, "\(right)")
    }

    @Test func theGuardHoldsOnlyWhileTheSunIsUp() throws {
        let day = SkyFixtures.aimEpoch.addingTimeInterval(18 * 3_600), night = SkyFixtures.aimEpoch
        let sun = SunEphemeris.direction(at: day, observer: SkyFixtures.observer)
        #expect(sun.elevation > 10 && SunEphemeris.direction(at: night, observer: SkyFixtures.observer).elevation < SkyMask.sunMaskedAbove)
        let card = SkyCameraModel.initial(facing: SkyMath.normalizedDegrees(sun.azimuth + 105), tilt: sun.elevation, pictureWidth: 4256, pictureHeight: 1888)
        #expect(SkySunGuard.band(at: day, observer: SkyFixtures.observer, model: card, aim: .rough)?.edge == .left)
        #expect(SkySunGuard.band(at: night, observer: SkyFixtures.observer, model: card, aim: .rough) == nil)
    }
}

// MARK: - Through the detector

extension SkyDetectorTests {
    /// A light of junk in the tile whose top-left corner is analysed pixel `tile` of a `width` × `height` picture: from 10 px in and 20 px down, 4
    /// pixels a second to the right for 4.8 s (19 px: past the 12 a light must get from where it began, and still inside its 64-pixel tile; and
    /// under the 5 s a straight light needs to be a probable plane or satellite by the rules, so it stays unexplained).
    static func junk(_ tile: (x: Double, y: Double), at start: Date, width: Int = 640, height: Int = 284) -> SkyTrack {
        straightTrack(from: (tile.x + 10, tile.y + 20), pixelsPerSecond: 4, seconds: 4.8, at: start, width: width, height: height)
    }

    /// Plays `count` junk lights into `tile`, one every `every` seconds from `from`, through `handle`.
    static func playJunk(_ rig: SkyDetectorRig, _ tile: (x: Double, y: Double), count: Int, from: Date, every: TimeInterval = 30) async {
        for index in 0..<count {
            let at = from.addingTimeInterval(Double(index) * every)
            rig.clock.set(at.addingTimeInterval(6))
            await rig.detector.handle(Self.junk(tile, at: at), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        }
    }

    // MARK: Busy spots

    @Test func junkAtOneSpotStopsBeingLoggedOnceTheSpotIsBusy() async throws {
        let id = UUID()
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888, camera: id)
        defer { rig.remove() }
        let capture = CameraLogCapture.start(camera: id)
        defer { capture.stop() }
        await rig.detector.start()
        #expect(await rig.detector.status.aim.note == nil)
        // A tree top shimmering in the top-left tile: 25 tracks, one every 30 s. Ten in four and a half minutes score just under ten, so the
        // eleventh makes the spot busy.
        await Self.playJunk(rig, (0, 0), count: 25, from: Self.start)
        let entries = await rig.logged().entries
        #expect(entries.count == 11, "\(entries.count)")
        #expect(entries.allSatisfy { $0.label == .unexplained && $0.hasStill })
        #expect(rig.stillsAsked.value.count == 11, "a light that is only counted has no picture")
        #expect(await rig.detector.status.aim.note == "Ignoring 1 busy spot (trees, wires or glare)")
        // A light elsewhere is logged, and the hour's line says how many were skipped.
        await rig.detector.handle(Self.junk((320, 128), at: Self.start.addingTimeInterval(900)), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        #expect(await rig.logged().entries.count == 12)
        await rig.detector.tick(at: Self.start.addingTimeInterval(1_800))
        #expect(capture.lines.filter { $0.contains("busy spot") }.isEmpty, "not before the hour is over")
        await rig.detector.tick(at: Self.start.addingTimeInterval(3_660))
        #expect(capture.lines.filter { $0.contains("busy spot") } == ["Sky Watcher, North Sky: 14 lights at busy spots skipped this hour (trees, wires or glare)"],
                "\(capture.lines)")
        await rig.detector.stop()
    }

    @Test func aLightThatCrossesOutOfABusySpotIsLoggedAndSoIsAPlaneThere() async throws {
        let rig = try SkyDetectorRig(settings: Self.singleCard, pictureWidth: 1920, pictureHeight: 1080)
        defer { rig.remove() }
        await rig.detector.start()
        // A plane that barely moves (as in `aSlowLightAFlightExplainsIsStillAPlane`), in a spot of the 1920 × 1080 picture that is busy.
        let begins = Self.start.addingTimeInterval(1_200)
        let path = SkyPath(start: SkyDirection(azimuth: 315, elevation: 40), bearing: Double.pi / 2, legs: [SkyPath.Leg(duration: 1.6, speed: 0.04)])
        let plane = Self.quietTrack(along: path, at: begins, seenBy: Self.singleModel)
        let first = try #require(plane.samples.first?.point)
        let tile = (x: (first.x * 1920 / 64).rounded(.down) * 64, y: (first.y * 1080 / 64).rounded(.down) * 64)
        let map = SkyClutterMap(width: 1920, height: 1080)
        #expect(Set(plane.samples.map { map.tile(of: $0.point) }).count == 1, "the plane stays in one tile")
        func junk(_ at: Date, x: Double? = nil, speed: Double = 4, seconds: Double = 6) -> SkyTrack {
            var track = Self.straightTrack(from: (x ?? tile.x + 10, tile.y + 20), pixelsPerSecond: speed, seconds: seconds, at: at, width: 1920, height: 1080)
            for index in track.samples.indices { track.samples[index].lens = 0 }
            return track
        }
        for index in 0..<12 {
            let at = Self.start.addingTimeInterval(Double(index) * 30)
            rig.clock.set(at.addingTimeInterval(6))
            await rig.detector.handle(junk(at), analysisWidth: 1920, analysisHeight: 1080, pictureWidth: 1920)
        }
        let before = await rig.logged().entries.count
        #expect(before == 11)
        await rig.flights.add(SkyFixtures.reports(along: path, beginningAt: begins, altitudeMeters: 3_000, from: begins.addingTimeInterval(-3),
                                                  to: begins.addingTimeInterval(5), hex: "c0ffee"))
        rig.clock.set(begins.addingTimeInterval(2))
        await rig.detector.handle(plane, analysisWidth: 1920, analysisHeight: 1080, pictureWidth: 1920)
        // Junk there again is only counted; a light that begins there and goes 160 px to the right crosses out of the spot and is logged.
        let later = begins.addingTimeInterval(60)
        rig.clock.set(later.addingTimeInterval(6))
        await rig.detector.handle(junk(later), analysisWidth: 1920, analysisHeight: 1080, pictureWidth: 1920)
        await rig.detector.handle(junk(later.addingTimeInterval(30), speed: 40, seconds: 4), analysisWidth: 1920, analysisHeight: 1080, pictureWidth: 1920)
        let entries = await rig.logged().entries.filter { $0.start >= begins }
        #expect(entries.map(\.label) == [.probablePlane, .unexplained], "\(entries.map { ($0.label, $0.start.timeIntervalSince(begins)) })")
        #expect(entries.first?.by == .flight)
        await rig.detector.stop()
    }

    @Test func theTracksTheTrackerDropsMakeASpotBusyToo() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        // A wire flickering in the second tile of the second row: the tracker drops its tracks as on something fixed, twelve of them.
        for index in 0..<12 {
            let at = Self.start.addingTimeInterval(Double(index) * 20)
            await rig.detector.droppedTrack(SkyDroppedTrack(track: Self.junk((64, 64), at: at), reason: .fixed), analysisWidth: 640, analysisHeight: 284)
        }
        rig.clock.set(Self.start.addingTimeInterval(320))
        await rig.detector.handle(Self.junk((64, 64), at: Self.start.addingTimeInterval(300)), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        #expect(await rig.logged().entries.isEmpty, "a light that starts and stays at the wire is only counted")
        await rig.detector.handle(Self.junk((256, 128), at: Self.start.addingTimeInterval(330)), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        #expect(await rig.logged().entries.count == 1, "a light elsewhere is logged")
        await rig.detector.stop()
    }

    @Test func busySpotsAreKeptOverARestartAndForgottenWithANewCard() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        await Self.playJunk(rig, (0, 0), count: 12, from: Self.start)
        #expect(await rig.logged().entries.count == 11)
        await rig.detector.stop()
        // Kept beside the aim, 0600, and nothing in it is the place.
        let file = rig.data.url.appending(path: "sky/\(rig.camera.uuidString)/\(SkyClutterMap.fileName)", directoryHint: .notDirectory)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(SkyLogStoreTests.mode(file) == 0o600 && SkyClutterMap.fileName == "clutter.json")
        #expect(!text.contains("40.0") && !text.contains("-100") && !text.contains("latitude"), "\(text.prefix(200))")
        // A restart does not learn it again from nothing.
        let again = rig.again()
        await again.start()
        let restart = Self.start.addingTimeInterval(600)
        rig.clock.set(restart.addingTimeInterval(6))
        await again.handle(Self.junk((0, 0), at: restart), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        await again.settle()
        await rig.log.flush()
        #expect(rig.log.read(camera: rig.camera, night: rig.night(Self.start), folder: rig.recordings.url).entries.count == 11)
        #expect(await again.status.aim.note == "Ignoring 1 busy spot (trees, wires or glare)")
        // The camera is pointed again: its picture shows other things, and the spot is forgotten.
        var turned = Self.dualCard
        turned.facing = 45
        await again.update(turned)
        await again.settle()
        #expect(await again.status.aim.note == nil)
        await again.handle(Self.junk((0, 0), at: restart.addingTimeInterval(60)), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        await again.settle()
        await rig.log.flush()
        #expect(rig.log.read(camera: rig.camera, night: rig.night(Self.start), folder: rig.recordings.url).entries.count == 12)
        await again.stop()
    }

    @Test func aBusySpotQuietsDownWithinHours() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        await Self.playJunk(rig, (128, 64), count: 12, from: Self.start)
        #expect(await rig.logged().entries.count == 11)
        // Three hours later the spot has calmed down: a light there is logged, and the note is gone.
        let later = Self.start.addingTimeInterval(3 * 3_600)
        rig.clock.set(later.addingTimeInterval(6))
        #expect(await rig.detector.status.aim.note == nil)
        await rig.detector.handle(Self.junk((128, 64), at: later), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        #expect(await rig.logged(later).entries.count == 12)
        await rig.detector.stop()
    }

    // MARK: The Sun's guard

    @Test func lightsAlongTheEdgeNearTheSunAreCountedButPlanesAndTheRestAreLogged() async throws {
        let day = Self.start.addingTimeInterval(18 * 3_600)   // 16:00 in Chicago: the Sun is up, in the south-west
        let sun = SunEphemeris.direction(at: day, observer: Self.observer)
        // A dual camera whose left lens's outer edge is about 15° short of the Sun, as North Sky's west edge in the late afternoon.
        let card = SkyDetectorSettings(enabled: true, facing: SkyMath.normalizedDegrees(sun.azimuth + 105).rounded(), tilt: sun.elevation.rounded())
        let model = SkyCameraModel.initial(facing: card.facing, tilt: card.tilt, pictureWidth: 4256, pictureHeight: 1888)
        let band = try #require(SkySunGuard.band(sun: sun, model: model, aim: .rough))
        #expect(band.lens == 0 && band.edge == .left, "\(band)")
        let id = UUID()
        let rig = try SkyDetectorRig(settings: card, pictureWidth: 4256, pictureHeight: 1888, camera: id)
        defer { rig.remove() }
        let capture = CameraLogCapture.start(camera: id)
        defer { capture.stop() }
        await rig.detector.start()
        // Glare along the edge: counted. A light in the middle of the lens: logged. (Slower than a bird and shorter than a plane by day, so that
        // the rules leave it unexplained: 3 px a second, about 0.8°/s, for 4.8 s.)
        func light(x: Double, at: Date) -> SkyTrack { Self.straightTrack(from: (x, 142), pixelsPerSecond: 3, seconds: 4.8, at: at) }
        rig.clock.set(day.addingTimeInterval(10))
        await rig.detector.handle(light(x: 10, at: day), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        await rig.detector.handle(light(x: 200, at: day.addingTimeInterval(60)), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        // A plane in the band is a plane.
        let inBand = try #require(model.direction(at: PixelPoint(x: 0.06, y: 0.5), lens: 0))
        let path = SkyPath(start: inBand, bearing: Double.pi / 2, legs: [SkyPath.Leg(duration: 4, speed: 0.5)])
        let begins = day.addingTimeInterval(300)
        await rig.flights.add(SkyFixtures.reports(along: path, beginningAt: begins, altitudeMeters: 3_000, from: begins.addingTimeInterval(-3),
                                                  to: begins.addingTimeInterval(7), hex: "c0ffee"))
        let plane = Self.quietTrack(along: path, at: begins, seenBy: model)
        #expect(SkySunGuard.covers(plane, band: band, model: model), "the plane's path lies in the band")
        rig.clock.set(begins.addingTimeInterval(5))
        await rig.detector.handle(plane, analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        let entries = await rig.logged(day).entries
        #expect(entries.map(\.label) == [.unexplained, .probablePlane], "\(entries.map { ($0.label, $0.path.first?.x ?? -1) })")
        #expect(entries.first.map { $0.path.allSatisfy { $0.x > 0.25 } } == true, "the light in the middle of the lens")
        // The same glare at night is logged: the guard holds while the Sun is up.
        rig.clock.set(Self.start.addingTimeInterval(10))
        await rig.detector.handle(light(x: 10, at: Self.start), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        #expect(await rig.logged(Self.start).entries.count == 1)
        await rig.detector.stop()
        #expect(capture.lines.filter { $0.contains("near the Sun") } == ["Sky Watcher, North Sky: 1 light near the Sun skipped this hour (likely glare)"],
                "\(capture.lines)")
    }

    // MARK: The hourly cap

    /// Light `index` of a run, each in a tile of its own as far as fifty go (ten across, five down), so that no spot gets busy.
    static func spread(_ index: Int, at start: Date) -> SkyTrack {
        let tile = index % 50
        let x = Double(tile % 10) * 64, y = min(Double(tile / 10) * 64, 230)
        return junk((x, y), at: start)
    }

    @Test func atMostTwoHundredUnexplainedEntriesAnHourAndALineSaysHowManyMoreWereNot() async throws {
        let id = UUID()
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888, camera: id)
        defer { rig.remove() }
        let capture = CameraLogCapture.start(camera: id)
        defer { capture.stop() }
        await rig.detector.start()
        #expect(SkyLightFilter.unexplainedPerHour == 200)
        // 205 lights nothing explains in one clock hour (22:00 to 23:00 in Chicago), then 3 in the next.
        let hour = Self.start
        for index in 0..<205 {
            let at = hour.addingTimeInterval(Double(index) * 17)
            rig.clock.set(at.addingTimeInterval(6))
            await rig.detector.handle(Self.spread(index, at: at), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        }
        let first = await rig.logged().entries
        #expect(first.count == 200 && first.allSatisfy { $0.hasStill } && rig.stillsAsked.value.count == 200, "\(first.count)")
        // Once the hour is over: one line in the log, and one in the journal.
        await rig.detector.tick(at: hour.addingTimeInterval(3_660))
        await rig.log.flush()
        let contents = rig.log.contents(camera: id, night: rig.night(hour), folder: rig.recordings.url)
        #expect(contents.capped == [SkyCappedHour(hour: hour, count: 5)], "\(contents.capped)")
        #expect(capture.lines.filter { $0.contains("not logged") } == ["Sky Watcher, North Sky: 5 more lights were not logged this hour (at most 200 are logged an hour)"],
                "\(capture.lines)")
        let file = SkyLogStore.nightFile(folder: rig.recordings.url, camera: id, night: rig.night(hour))
        let line = try #require(try SkyLogStoreTests.lines(file).first { $0.contains("capped") })
        #expect(line == #"{"capped":{"at":\#(SkyLogStoreTests.ms(hour.addingTimeInterval(3_660))),"count":5,"hour":\#(SkyLogStoreTests.ms(hour))},"v":1}"#, "\(line)")
        // The next hour starts fresh; a stop writes the line of the hour it is in.
        let next = hour.addingTimeInterval(3_600)
        for index in 0..<203 {
            let at = next.addingTimeInterval(Double(index) * 17)
            rig.clock.set(at.addingTimeInterval(6))
            await rig.detector.handle(Self.spread(index, at: at), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        }
        await rig.detector.stop()
        await rig.log.flush()
        let after = rig.log.contents(camera: id, night: rig.night(hour), folder: rig.recordings.url)
        #expect(after.entries.filter { $0.start >= next }.count == 200)
        #expect(after.capped == [SkyCappedHour(hour: hour, count: 5), SkyCappedHour(hour: next, count: 3)], "\(after.capped)")
    }

    // MARK: A picture for every logged light (Ruling S31)

    @Test func everyLoggedUnexplainedLightHasItsPicture() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        // Forty lights nothing explains in one clock hour: before, the hour's pictures ended at thirty.
        for index in 0..<40 {
            let at = Self.start.addingTimeInterval(Double(index) * 60)
            rig.clock.set(at.addingTimeInterval(6))
            await rig.detector.handle(Self.spread(index, at: at), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        }
        let entries = await rig.logged().entries
        #expect(entries.count == 40 && entries.allSatisfy { $0.hasStill } && rig.stillsAsked.value.count == 40)
        for entry in entries {
            #expect(rig.log.still(camera: rig.camera, night: rig.night(entry.start), entryID: entry.id, folder: rig.recordings.url) != nil)
        }
        #expect([SkyLabel.unexplained, .meteor, .bug, .bird].allSatisfy { SkyLightFilter.wantsStill($0, by: $0 == .unexplained ? nil : .rule) },
                "and the rules' meteors, bugs and birds, when they come (and their probable planes and satellites: `SkyRulesPicturesTests.swift`)")
        #expect(!SkyLightFilter.wantsStill(.plane, by: .flight) && !SkyLightFilter.wantsStill(.probablePlane, by: .flight) && !SkyLightFilter.wantsStill(.satellite, by: .orbit))
        await rig.detector.stop()
    }

    // MARK: Pictures made later from the recordings (Ruling S31)

    @Test func aLightLoggedWithoutAPictureGetsOneFromTheRecordingLater() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        // The drive was short of room when the light was logged.
        rig.room.set(false)
        rig.clock.set(Self.start.addingTimeInterval(6))
        await rig.detector.handle(Self.spread(3, at: Self.start), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        let logged = try #require(await rig.logged().entries.first)
        #expect(!logged.hasStill && rig.stillsAsked.value.isEmpty)
        // Not while the drive has no room, nor in the minute after the light (its live picture and the recording come first).
        rig.recorded.set(.made(SkyLogStoreTests.jpeg("recorded")))
        await rig.detector.tick(at: Self.start.addingTimeInterval(60))
        rig.room.set(true)
        await rig.detector.tick(at: Self.start.addingTimeInterval(61))
        #expect(rig.recordedAsked.value.isEmpty)
        // Then the recording's picture of the light's middle.
        await rig.detector.tick(at: Self.start.addingTimeInterval(700))
        let middle = logged.start.addingTimeInterval(logged.end.timeIntervalSince(logged.start) / 2)
        #expect(rig.recordedAsked.value.count == 1 && abs((rig.recordedAsked.value.first ?? .distantPast).timeIntervalSince(middle)) < 0.01, "\(rig.recordedAsked.value)")
        let entry = try #require(await rig.logged().entries.first)
        #expect(entry.id == logged.id && entry.hasStill, "the entry reads as having its picture")
        #expect(rig.log.still(camera: rig.camera, night: rig.night(entry.start), entryID: entry.id, folder: rig.recordings.url) == SkyLogStoreTests.jpeg("recorded"))
        let file = SkyLogStore.nightFile(folder: rig.recordings.url, camera: rig.camera, night: rig.night(entry.start))
        let lines = try SkyLogStoreTests.lines(file)
        #expect(lines.filter { !$0.isEmpty }.count == 2 && lines.contains(#"{"id":"\#(entry.id)","still":true,"v":1}"#), "the log stays append-only: \(lines)")
        // Once is enough.
        await rig.detector.tick(at: Self.start.addingTimeInterval(1_400))
        await rig.detector.tick(at: Self.start.addingTimeInterval(2_100))
        #expect(rig.recordedAsked.value.count == 1)
        await rig.detector.stop()
    }

    @Test func aRecordingThatIsGoneMeansNoPictureAndNoRetries() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        rig.room.set(false)
        for index in 0..<3 {
            let at = Self.start.addingTimeInterval(Double(index) * 60)
            rig.clock.set(at.addingTimeInterval(6))
            await rig.detector.handle(Self.spread(index, at: at), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        }
        rig.room.set(true)
        rig.recorded.set(.gone)
        // Retention took the recording (or the camera does not record): each light is asked about once, in a day of ticks.
        for minute in 3..<(3 + 24 * 60) where minute % 7 == 0 { await rig.detector.tick(at: Self.start.addingTimeInterval(Double(minute) * 60)) }
        #expect(rig.recordedAsked.value.count == 3, "\(rig.recordedAsked.value.count)")
        #expect(await rig.logged().entries.allSatisfy { !$0.hasStill })
        // A recording not written yet is asked again, a few times at the most.
        let later = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { later.remove() }
        await later.detector.start()
        later.room.set(false)
        later.clock.set(Self.start.addingTimeInterval(6))
        await later.detector.handle(Self.spread(0, at: Self.start), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        later.room.set(true)
        later.recorded.set(.later)
        for tick in 1...20 { await later.detector.tick(at: Self.start.addingTimeInterval(Double(tick) * 700)) }
        #expect(later.recordedAsked.value.count == SkyStillBackfill.laterTries, "\(later.recordedAsked.value.count)")
        await rig.detector.stop()
        await later.detector.stop()
    }

    @Test func theRecordingsPicturesAreMadeAFewAtATimeNewestFirst() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        rig.room.set(false)
        for index in 0..<10 {
            let at = Self.start.addingTimeInterval(Double(index) * 60)
            rig.clock.set(at.addingTimeInterval(6))
            await rig.detector.handle(Self.spread(index, at: at), analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        }
        rig.room.set(true)
        rig.recorded.set(.made(SkyLogStoreTests.jpeg("recorded")))
        let starts = await rig.logged().entries.map(\.start).sorted(by: >)
        await rig.detector.tick(at: Self.start.addingTimeInterval(1_200))
        #expect(SkyStillBackfill.perTick == 4 && rig.recordedAsked.value.count == 4)
        #expect(rig.recordedAsked.value.map { $0.addingTimeInterval(-2.4) } == Array(starts.prefix(4)), "the newest first, each at its middle")
        await rig.detector.tick(at: Self.start.addingTimeInterval(1_260))
        await rig.detector.tick(at: Self.start.addingTimeInterval(1_320))
        #expect(rig.recordedAsked.value.count == 10)
        await rig.detector.tick(at: Self.start.addingTimeInterval(1_380))
        let entries = await rig.logged().entries
        #expect(rig.recordedAsked.value.count == 10 && entries.count == 10 && entries.allSatisfy(\.hasStill))
        await rig.detector.stop()
    }
}

// MARK: - The log's new lines, and reading

extension SkyLogStoreTests {
    @Test func aPictureMadeLaterAndAnHoursCapAreLinesOfTheirOwn() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let log = SkyLogStore(log: .silent)
        let entry = Self.entry("199ce34f080-00000002", Self.local(24, 22))
        log.record(entry, night: Self.night, folder: folder.url)
        log.writeStill(Self.jpeg("later"), entryID: entry.id, camera: Self.camera, night: Self.night, folder: folder.url)
        log.recordStill(entryID: entry.id, camera: Self.camera, night: Self.night, folder: folder.url)
        log.recordStill(entryID: "ghost", camera: Self.camera, night: Self.night, folder: folder.url)
        let hour = Self.local(24, 22), written = Self.local(24, 23, 1)
        log.recordCapped(SkyCappedHour(hour: hour, count: 212), camera: Self.camera, night: Self.night, folder: folder.url, at: written)
        // The same hour from a second run of the detector (it restarted in the hour) adds to it; the next hour has its own.
        log.recordCapped(SkyCappedHour(hour: hour, count: 8), camera: Self.camera, night: Self.night, folder: folder.url, at: Self.local(24, 22, 40))
        log.recordCapped(SkyCappedHour(hour: Self.local(24, 23), count: 1), camera: Self.camera, night: Self.night, folder: folder.url, at: Self.local(25, 0, 1))
        await log.flush()

        let lines = try Self.lines(SkyLogStore.nightFile(folder: folder.url, camera: Self.camera, night: Self.night))
        #expect(lines[1] == #"{"id":"\#(entry.id)","still":true,"v":1}"#)
        #expect(lines[3] == #"{"capped":{"at":\#(Self.ms(written)),"count":212,"hour":\#(Self.ms(hour))},"v":1}"#)
        let read = log.contents(camera: Self.camera, night: Self.night, folder: folder.url)
        #expect(read.entries.map(\.id) == [entry.id] && read.entries[0].hasStill, "the picture's line applies to its entry, like a correction")
        #expect(read.capped == [SkyCappedHour(hour: hour, count: 220), SkyCappedHour(hour: Self.local(24, 23), count: 1)])
        #expect(log.read(camera: Self.camera, night: Self.night, folder: folder.url).entries == read.entries)
        // A line read twice (once while it waited, once from the file) counts once.
        let doubled = SkyLogStore.parse(lines.filter { !$0.isEmpty }.map { Data($0.utf8) } + [Data(lines[3].utf8)], camera: Self.camera)
        #expect(doubled.capped == read.capped)
    }

    @Test func aReaderSkipsTheLinesItDoesNotKnow() async throws {
        // What the readers before these lines make of them (beta 0.1.123's `Line`): nothing. Every key of theirs is absent or names an entry they
        // apply nothing to, so the line is skipped as theirs skips every line it does not know.
        struct OlderLine: Decodable {
            var v: Int
            var entry: SkyEntry?
            var id: String?
            var correction: SkyLogStore.Line.Correction?
            var ai: SkyAIAnswer?
            var alerted: Bool?
            var conditions: SkyConditions?
        }
        let still = #"{"id":"a-1","still":true,"v":1}"#, capped = #"{"capped":{"at":1792900800000,"count":212,"hour":1792897200000},"v":1}"#
        for line in [still, capped] {
            let older = try SkyLogStore.makeDecoder().decode(OlderLine.self, from: Data(line.utf8))
            #expect(older.v == 1 && older.entry == nil && older.correction == nil && older.ai == nil && older.alerted == nil && older.conditions == nil)
        }
        // And this reader skips a kind it does not know, a later build's, and reads the rest.
        let entry = try String(decoding: SkyLogStore.makeEncoder().encode(SkyLogStore.Line(v: 1, entry: Self.entry("a-1", Self.local(24, 21)))), as: UTF8.self)
        let read = SkyLogStore.parse([entry, #"{"orbit":{"name":"ISS"},"v":1}"#, #"{"id":"a-1","later":true,"v":1}"#, still].map { Data($0.utf8) }, camera: Self.camera)
        #expect(read.entries.map(\.id) == ["a-1"] && read.entries[0].hasStill && read.conditions.isEmpty && read.capped.isEmpty)
    }
}

extension SkyNightLogEngineTests {
    @MainActor @Test func aPictureMadeLaterAndTheCappedHoursReadInTheLogByView() async throws {
        let rig = try await Rig()
        await rig.file(Self.entry("b-1", 24, 21))
        rig.log.writeStill(SkyLogStoreTests.jpeg("later"), entryID: "b-1", camera: Self.camera, night: "2026-10-24", folder: rig.recordings.url)
        rig.log.recordStill(entryID: "b-1", camera: Self.camera, night: "2026-10-24", folder: rig.recordings.url)
        // The day of the 24th had a busy hour at 3 PM, and its night one at 10 PM.
        rig.log.recordCapped(SkyCappedHour(hour: SkyLogStoreTests.local(24, 15), count: 30), camera: Self.camera, night: "2026-10-24", folder: rig.recordings.url,
                             at: SkyLogStoreTests.local(24, 16, 1))
        rig.log.recordCapped(SkyCappedHour(hour: SkyLogStoreTests.local(24, 22), count: 212), camera: Self.camera, night: "2026-10-24", folder: rig.recordings.url,
                             at: SkyLogStoreTests.local(24, 23, 1))
        await rig.log.flush()
        let night = try await rig.night("2026-10-24", .night)
        #expect(night.entries.first { $0.id == "b-1" }?.hasStill == true)
        #expect(night.capped == [SkyCappedHour(hour: SkyLogStoreTests.local(24, 22), count: 212)], "\(night.capped)")
        #expect(try await rig.engine.skyStill(cameraID: rig.cameraID, night: "2026-10-24", entryID: "b-1") == SkyLogStoreTests.jpeg("later"))
        let day = try await rig.night("2026-10-24", .day)
        #expect(day.capped == [SkyCappedHour(hour: SkyLogStoreTests.local(24, 15), count: 30)], "\(day.capped)")
    }

    @MainActor @Test func aNightIsReadWholeAfterADayOfTwentyMegabytes() async throws {
        let rig = try await Rig()
        // The day of the 24th as the owner's afternoon was: thousands of lights, here 20 MB of them (each with its 64 points), then the night.
        let file = SkyLogStore.nightFile(folder: rig.recordings.url, camera: Self.camera, night: "2026-10-24")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = SkyLogStore.makeEncoder()
        var day = SkyLogStoreTests.entry("day-0", SkyLogStoreTests.local(24, 13))
        day.path = (0..<64).map { SkyPathPoint(t: Double($0) * 0.31, x: 0.0123456789 + Double($0) * 0.001, y: 0.8123456789) }
        let template = String(decoding: try encoder.encode(SkyLogStore.Line(v: 1, entry: day)), as: UTF8.self)
        var bytes = Data()
        var count = 0
        while bytes.count < 20 * 1_048_576 {
            let second = Double(count % 18_000) / 5
            let start = SkyLogStoreTests.ms(SkyLogStoreTests.local(24, 13).addingTimeInterval(second))
            let line = template.replacingOccurrences(of: "\"day-0\"", with: "\"day-\(count)\"")
                .replacingOccurrences(of: "\"start\":\(SkyLogStoreTests.ms(day.start))", with: "\"start\":\(start)")
                .replacingOccurrences(of: "\"end\":\(SkyLogStoreTests.ms(day.end))", with: "\"end\":\(start + 4_200)")
            bytes.append(Data(line.utf8))
            bytes.append(0x0A)
            count += 1
        }
        try bytes.write(to: file)
        #expect(bytes.count > SkyLogStore.maximumReadBytes, "more than a read takes: \(bytes.count) bytes, \(count) lights")
        let lights = [Self.entry("n-1", 24, 21), Self.entry("n-2", 24, 23), Self.entry("n-3", 25, 2), Self.entry("n-4", 25, 5)]
        for entry in lights { await rig.file(entry) }
        let began = ContinuousClock.now
        let night = try await rig.night("2026-10-24", .night)
        #expect(night.entries.map(\.id) == ["n-1", "n-2", "n-3", "n-4"], "\(night.entries.count)")
        #expect(began.duration(to: .now) < .seconds(30))
        // The day reads as much of itself as fits after it: its newest part (its lights, which all follow one path a moment apart, are joined as it
        // is read: `SkyStitch`).
        let afternoon = try await rig.night("2026-10-24", .day)
        let read = afternoon.entries.reduce(0) { $0 + max(1, $1.parts.count) }
        #expect(read > 1_000 && read < count, "\(read) of \(count), as \(afternoon.entries.count) lights")
    }
}

// MARK: - The recording's picture (Ruling S31)

@Suite struct SkyRecordedStillTests {
    /// The recording of `PlannerFixtureFile()`: 15 s from `PlannerFixture.t0`, keyframes at 0, 2.5, 10 and 12.5 s (the third and fourth fragments
    /// continue the group of pictures of the second).
    static func still(_ seconds: Double, archive: PlannerFixtureArchive, codecs: SkyFakeCodecs, decoders: SnapshotDecoderPool) async -> SkyRecordedStill {
        await BridgeEngine.skyRecordedStill(camera: PlannerFixture.camera, at: PlannerFixture.at(Int64((seconds * 1_000).rounded())), archive: archive,
                                            decoders: decoders, codecs: codecs)
    }

    /// What the fake codecs say they made of the keyframe of `seconds` after `t0`: its time at 90 kHz since 2001.
    static func picture(ofKeyframeAt seconds: Double) -> SkyRecordedStill {
        let pts = Int64((PlannerFixture.at(Int64(seconds * 1_000)).timeIntervalSinceReferenceDate * 90_000).rounded())
        return .made(Data("JPEG pts=\(pts) q=0.8 w=nil h=nil".utf8))
    }

    /// The picture's words (what the fake codecs made), or what was given instead.
    static func describe(_ still: SkyRecordedStill) -> String {
        if case .made(let data) = still { return String(decoding: data, as: UTF8.self) }
        return "\(still)"
    }

    @Test func theKeyframeNearestTheTimeIsThePicture() async throws {
        let archive = PlannerFixtureArchive()
        let built = try archive.add(PlannerFixtureFile())
        let codecs = SkyFakeCodecs()
        let decoders = SnapshotDecoderPool(codecs: codecs, idleLifetime: .seconds(1))
        // At 6 s: the group of pictures that began at 2.5 s (the next keyframe, at 10 s, is further). At 9 s: the one at 10 s.
        let six = await Self.still(6, archive: archive, codecs: codecs, decoders: decoders)
        #expect(six == Self.picture(ofKeyframeAt: 2.5), "\(Self.describe(six))")
        #expect(archive.reads(of: .keyframe) == [built.id(1)])
        #expect(await Self.still(9, archive: archive, codecs: codecs, decoders: decoders) == Self.picture(ofKeyframeAt: 10))
        #expect(await Self.still(1, archive: archive, codecs: codecs, decoders: decoders) == Self.picture(ofKeyframeAt: 0))
        #expect(codecs.jpegs.value.allSatisfy { $0.hasSuffix("q=0.8 w=nil h=nil") }, "the full picture at 0.8, then made 1920 wide like a live one")
        // Before the oldest recording: gone. After the newest: not yet, until it is long past (the camera does not record now): gone.
        #expect(await Self.still(-30, archive: archive, codecs: codecs, decoders: decoders) == .gone)
        #expect(await Self.still(20, archive: archive, codecs: codecs, decoders: decoders) == .later)
        #expect(await Self.still(15 + 700, archive: archive, codecs: codecs, decoders: decoders) == .gone)
        // A gap between two files: gone. A picture that cannot be made smaller: failed.
        var second = PlannerFixtureFile()
        second.name = "13-02-00"
        second.startMs = PlannerFixture.t0 + 120_000
        try archive.add(second)
        #expect(await Self.still(60, archive: archive, codecs: codecs, decoders: decoders) == .gone)
        #expect(await Self.still(121, archive: archive, codecs: codecs, decoders: decoders) == Self.picture(ofKeyframeAt: 120))
        codecs.resizeFails.set(true)
        #expect(await Self.still(6, archive: archive, codecs: codecs, decoders: decoders) == .failed)
        codecs.resizeFails.set(false)
        // While the recordings load: not yet. A file that went: gone.
        archive.setReady(false)
        #expect(await Self.still(6, archive: archive, codecs: codecs, decoders: decoders) == .later)
        archive.setReady(true)
        archive.setHook { _, _, _ in throw ArchiveError.fileGone }
        #expect(await Self.still(6, archive: archive, codecs: codecs, decoders: decoders) == .gone)
        archive.setHook { _, _, _ in throw ArchiveError.timedOut }
        #expect(await Self.still(6, archive: archive, codecs: codecs, decoders: decoders) == .later)
    }
}
