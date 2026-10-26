import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

// Two pre-beta rulings on the sky detector, tested before they were built (they join `SkyDetectorTests` and `SkyServiceTests`).
//
// Ruling S24 (fewer junk entries): a light that nothing explains and that moves too slowly, a star, is no entry and has no picture, only a count
// that the journal gets once an hour; a light that a flight explains is a plane whatever its speed. (Its 30 pictures an hour went with Ruling S31:
// every logged light has its picture, `SkyClutterTests.swift`.)
//
// Ruling S25 (a camera that moved): the aim starts again from the card, rough as a new camera's is, when the card's facing, tilt or lenses change
// or when a good aim has matched no plane in the 2 hours that planes flew through the view. The ground and the night profile are not where the
// camera looks, and change nothing. Ruling S25b: so too when the card was changed while the detector was off (the plugin or the camera's switch);
// an aim saved before its card was kept keeps its fit, and its card from then on.
//
// All made up, as in `SkyDetectorTests`: the place is 40.0000, −100.0000, the aircraft are the fixtures', nothing is downloaded.

extension SkyDetectorTests {
    // MARK: Made-up lights and a made-up aim

    /// A camera with one lens over a 1920 × 1080 picture whose card is right (facing 315°, tilted 25°): `teachTheAim` makes its aim good.
    static let singleCard = SkyDetectorSettings(enabled: true, facing: 315, tilt: 25)
    static var singleModel: SkyCameraModel { SkyCameraModel.initial(facing: 315, tilt: 25, pictureWidth: 1920, pictureHeight: 1080) }

    /// Twelve planes, each its own pass of 15 s a minute apart from `start`, matched through `classify`: the aim of `singleCard` is good after
    /// them (as in `matchesImproveTheAim`). The labels, in order.
    @discardableResult
    static func teachTheAim(_ detector: SkyCameraDetector, flights: FlightHistory, clock: Box<Date>, using random: inout SkyRandom) async -> [SkyLabel] {
        var labels: [SkyLabel] = []
        for index in 0..<12 {
            let pass = Self.pass(index, at: Self.start.addingTimeInterval(Double(index) * 60), seenBy: singleModel, using: &random)
            await flights.add(pass.reports)
            clock.set(pass.track.samples.last?.wallClock ?? Self.start)
            let measures = TrackMeasurer.measure(pass.track, model: singleModel, analysisWidth: 1920, pictureWidth: 1920)
            labels.append(await detector.classify(pass.track, measures: measures).label)
        }
        return labels
    }

    /// A rig for `singleCard` whose aim is good, and whose clock is at the last of the twelve passes.
    static func goodAimedRig(camera: UUID = SkyDetectorRig.camera) async throws -> SkyDetectorRig {
        let rig = try SkyDetectorRig(settings: singleCard, pictureWidth: 1920, pictureHeight: 1080, camera: camera)
        await rig.detector.start()
        var random = SkyRandom(seed: 12)
        await teachTheAim(rig.detector, flights: rig.flights, clock: rig.clock, using: &random)
        let aim = await rig.detector.status.aim
        let good = aim.quality == .good && aim.planes == 12
        if !good { rig.remove() }
        try #require(good, "twelve matched passes make the aim good: \(aim)")
        return rig
    }

    /// A light that goes straight across an `width` × `height` analysed picture at `pixelsPerSecond`, five pictures a second for `seconds`, from
    /// `from` (analysed pixels): no noise, so its speed is exactly what it says.
    static func straightTrack(from: (x: Double, y: Double), pixelsPerSecond: Double, seconds: Double, at start: Date, width: Int = 640,
                              height: Int = 284) -> SkyTrack {
        let samples = (0...Int(seconds * 5)).map { index -> SkyTrackSample in
            let time = Double(index) / 5, x = from.x + pixelsPerSecond * time
            return SkyTrackSample(time: time, wallClock: start.addingTimeInterval(time), point: PixelPoint(x: x / Double(width), y: from.y / Double(height)),
                                  area: 9, flux: 120, sharpness: 0.6, elongation: 1, lens: x / Double(width) < 0.5 ? 0 : 1, significance: 4)
        }
        return SkyTrack(id: UUID(), samples: samples, streakBorn: false)
    }

    /// The track of a light along `path` from `start`, five pictures a second, seen through `model`: no noise.
    static func quietTrack(along path: SkyPath, at start: Date, seenBy model: SkyCameraModel) -> SkyTrack {
        let samples = path.directions().compactMap {
            SkyFixtures.sample(at: start.addingTimeInterval($0.time), since: start, direction: $0.direction, through: model)
        }
        return SkyTrack(id: UUID(), samples: samples, streakBorn: false)
    }

    // MARK: Ruling S24: the rule and its numbers

    @Test func theSlowLightRuleKeepsItsNumbersInOnePlace() {
        #expect(SkyLightFilter.slowDegreesPerSecond == 0.05 && SkyLightFilter.slowPixelsPerSecond == 0.5 && SkyLightFilter.unexplainedPerHour == 200)
        func measured(_ speed: Double, duration: Double = 10) -> SkyMeasures {
            SkyMeasures(azimuth: 0, elevation: 0, azimuthEnd: 0, elevationEnd: 0, duration: duration, speed: speed, acceleration: 0, turnRate: 0,
                        maxTurn: 0, straightness: 1, shape: .straight, sizeDegrees: 0, brightness: 0, blinks: false, blinkRate: nil, focus: 0)
        }
        // A good or precise aim: degrees a second along the path; at least 0.05 is logged, and pixels do not count.
        #expect(SkyLightFilter.isSlow(measured(0.049), pixelsPerSecond: 100, aimIsGood: true))
        #expect(!SkyLightFilter.isSlow(measured(0.05), pixelsPerSecond: 0, aimIsGood: true))
        #expect(!SkyLightFilter.isSlow(measured(0.4), pixelsPerSecond: 0, aimIsGood: true))
        // A rough aim: analysed pixels a second; at least 0.5 is logged, and degrees through a guessed lens do not count.
        #expect(SkyLightFilter.isSlow(measured(5), pixelsPerSecond: 0.49, aimIsGood: false))
        #expect(!SkyLightFilter.isSlow(measured(0), pixelsPerSecond: 0.5, aimIsGood: false))
        #expect(!SkyLightFilter.isSlow(measured(0), pixelsPerSecond: 8, aimIsGood: false))
        // A track the model could not place in the sky at all has no speed in degrees: pixels judge it, whatever the aim.
        #expect(SkyLightFilter.isSlow(measured(0, duration: 0), pixelsPerSecond: 0.1, aimIsGood: true))
        #expect(!SkyLightFilter.isSlow(measured(0, duration: 0), pixelsPerSecond: 3, aimIsGood: true))
    }

    @Test func aLightsReachIsTheFarthestItGotFromItsFirstPoint() {
        #expect(SkyLightFilter.minimumReachPixels == 12)
        // A steady light: 0.6 px/s for 30 s gets 18 px away.
        let steady = Self.straightTrack(from: (50, 100), pixelsPerSecond: 0.6, seconds: 30, at: Self.start)
        #expect(abs(SkyLightFilter.reach(of: steady, analysisWidth: 640, analysisHeight: 284) - 18) < 0.001)
        // A faint star that wanders: every point within 8 px of where it began, however far its steps add up to.
        let wander = SkyTrack(id: UUID(), samples: (0...100).map { index in
            let time = Double(index) / 5
            let x = 100 + [0.0, 6, -2, 7, 1, -5][index % 6], y = 50 + [0.0, -3, 4, 2, -6, 3][index % 6]
            return SkyTrackSample(time: time, wallClock: Self.start.addingTimeInterval(time), point: PixelPoint(x: x / 640, y: y / 284),
                                  area: 9, flux: 120, sharpness: 0.6, elongation: 1)
        }, streakBorn: false)
        #expect(SkyLightFilter.reach(of: wander, analysisWidth: 640, analysisHeight: 284) < SkyLightFilter.minimumReachPixels)
        // A light that goes 30 px out and comes back counts by the farthest point: a sharp turn is kept.
        let back = SkyTrack(id: UUID(), samples: (0...60).map { index in
            let time = Double(index) / 5
            let x = 200 + Double(index <= 30 ? index : 60 - index)
            return SkyTrackSample(time: time, wallClock: Self.start.addingTimeInterval(time), point: PixelPoint(x: x / 640, y: 80 / 284),
                                  area: 9, flux: 120, sharpness: 0.6, elongation: 1)
        }, streakBorn: false)
        #expect(abs(SkyLightFilter.reach(of: back, analysisWidth: 640, analysisHeight: 284) - 30) < 0.001)
        #expect(SkyLightFilter.reach(of: SkyTrack(id: UUID(), samples: [], streakBorn: false), analysisWidth: 640, analysisHeight: 284) == 0)
        // Wandering in place is a faint light that never got 12 px away; a bright one (6σ or more at its strongest) is kept however little it moved,
        // like the overnight test's lights that rose, held and faded on one spot (Ruling S29).
        #expect(SkyLightFilter.brightSignificance == 6)
        #expect(SkyLightFilter.wandersInPlace(wander, analysisWidth: 640, analysisHeight: 284))
        var flare = wander
        flare.samples[50].significance = 6
        #expect(!SkyLightFilter.wandersInPlace(flare, analysisWidth: 640, analysisHeight: 284))
        flare.samples[50].significance = 5.9
        #expect(SkyLightFilter.wandersInPlace(flare, analysisWidth: 640, analysisHeight: 284))
        #expect(!SkyLightFilter.wandersInPlace(back, analysisWidth: 640, analysisHeight: 284), "a light that got 30 px away moved")
    }

    @Test func aLightsSpeedInAnalysedPixelsIsItsPathOverItsTime() {
        let steady = Self.straightTrack(from: (50, 100), pixelsPerSecond: 0.6, seconds: 30, at: Self.start)
        #expect(abs(SkyLightFilter.pixelSpeed(of: steady, analysisWidth: 640, analysisHeight: 284) - 0.6) < 0.001)
        #expect(abs(SkyLightFilter.pixelSpeed(of: steady, analysisWidth: 1280, analysisHeight: 568) - 1.2) < 0.001, "twice the pixels across the same picture")
        // A light that only jitters by a pixel has no path to speak of: steps under 4 px are noise, and the chord is all that is left.
        let jitter = SkyTrack(id: UUID(), samples: (0...100).map { index in
            let time = Double(index) / 5
            return SkyTrackSample(time: time, wallClock: Self.start.addingTimeInterval(time), point: PixelPoint(x: (100 + Double(index % 2)) / 640, y: 50 / 284),
                                  area: 9, flux: 120, sharpness: 0.6, elongation: 1)
        }, streakBorn: false)
        #expect(SkyLightFilter.pixelSpeed(of: jitter, analysisWidth: 640, analysisHeight: 284) < 0.1)
        // Nothing to divide by: no speed.
        let one = SkyTrack(id: UUID(), samples: Array(steady.samples.prefix(1)), streakBorn: false)
        #expect(SkyLightFilter.pixelSpeed(of: one, analysisWidth: 640, analysisHeight: 284) == 0)
        #expect(SkyLightFilter.pixelSpeed(of: SkyTrack(id: UUID(), samples: [], streakBorn: false), analysisWidth: 640, analysisHeight: 284) == 0)
    }

    @Test func theClockHourIsThePersonsOwnAndTheCountsKeepOnlyTheNewestHours() {
        let chicago = SkyDetectorRig.zone, kolkata = TimeZone(identifier: "Asia/Kolkata")!
        let hour = SkyFixtures.aimEpoch   // 03:00 UTC: 22:00 in Chicago (daylight time), on the hour
        #expect(SkyLightFilter.clockHour(of: hour, in: chicago) == hour)
        #expect(SkyLightFilter.clockHour(of: hour.addingTimeInterval(3_599), in: chicago) == hour)
        #expect(SkyLightFilter.clockHour(of: hour.addingTimeInterval(3_600), in: chicago) == hour.addingTimeInterval(3_600))
        #expect(SkyLightFilter.clockHour(of: hour.addingTimeInterval(-1), in: chicago) == hour.addingTimeInterval(-3_600))
        #expect(SkyLightFilter.clockHour(of: hour, in: kolkata) == hour.addingTimeInterval(-1_800), "08:30 there: the hour began at 08:00")
        #expect(SkyLightFilter.clockHour(of: hour.addingTimeInterval(1_800), in: kolkata) == hour.addingTimeInterval(1_800))

        var counts = SkyHourCounts()
        let first = hour, second = hour.addingTimeInterval(3_600), third = hour.addingTimeInterval(7_200)
        #expect(counts.count(in: first) == 0)
        #expect(counts.add(in: first) == 1 && counts.add(in: first) == 2 && counts.add(in: second) == 1 && counts.count(in: first) == 2)
        let finished = counts.drain(before: second)
        #expect(finished.map { $0.hour } == [first] && finished.map { $0.count } == [2], "the hours before the one in progress, once")
        #expect(counts.drain(before: second).isEmpty && counts.count(in: second) == 1 && counts.count(in: first) == 0)
        _ = counts.add(in: third)
        #expect(counts.drain(before: .distantFuture).map { $0.hour } == [second, third], "oldest first")
        var many = SkyHourCounts()
        for index in 0..<(SkyHourCounts.kept + 12) { _ = many.add(in: hour.addingTimeInterval(Double(index) * 3_600)) }
        #expect(many.drain(before: .distantFuture).count == SkyHourCounts.kept, "a counter that is never read does not grow")
    }

    // MARK: Ruling S24: through the detector

    @Test func aSlowLightNothingExplainsIsSkippedAndCountedWhileTheAimIsRough() async throws {
        let id = UUID()
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888, camera: id)
        defer { rig.remove() }
        let capture = CameraLogCapture.start(camera: id)
        defer { capture.stop() }
        await rig.detector.start()
        // Two lights crawl (0.3 and 0.25 pixels a second of the 640-wide picture), two go (0.8 and 4). At this scale a pixel is about 0.3°, so the
        // crawlers still make 0.07° a second or more: the old guard for lights that stood still (under 0.05°/s) lets them by; the new rule does not.
        let lights: [(pixelsPerSecond: Double, seconds: Double)] = [(0.3, 40), (0.8, 30), (0.25, 40), (4, 8)]
        for (index, light) in lights.enumerated() {
            let track = Self.straightTrack(from: (60, 40 + Double(index) * 40), pixelsPerSecond: light.pixelsPerSecond, seconds: light.seconds,
                                           at: Self.start.addingTimeInterval(Double(index) * 60))
            let measures = TrackMeasurer.measure(track, model: Self.dualModel, analysisWidth: 640, pictureWidth: 4256)
            #expect(!TrackMeasurer.isStationary(measures), "light \(index) must pass the stationary guard (\(measures.speed)°/s): it is the new rule that decides")
            await rig.detector.handle(track, analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        }
        let entries = await rig.logged().entries
        #expect(entries.map { $0.start.timeIntervalSince(Self.start) } == [60, 180], "the two that go are logged; the crawlers are not")
        #expect(entries.allSatisfy { $0.label == .unexplained && $0.hasStill } && rig.stillsAsked.value.count == 2, "no picture is asked for a skipped light")

        func slowLines() -> [String] { capture.lines.filter { $0.contains("slow light") } }
        await rig.detector.tick(at: Self.start.addingTimeInterval(1_800))
        #expect(slowLines().isEmpty, "the hour is not over: nothing is said yet")
        let next = Self.start.addingTimeInterval(3_600)
        await rig.detector.tick(at: next.addingTimeInterval(60))
        #expect(slowLines() == ["Sky Watcher, North Sky: 2 slow lights skipped this hour (likely stars)"], "\(capture.lines)")
        await rig.detector.tick(at: next.addingTimeInterval(120))
        #expect(slowLines().count == 1, "one line for the hour")

        // One more in the next hour: the line for it is written when the detector stops, in the singular.
        let crawler = Self.straightTrack(from: (60, 200), pixelsPerSecond: 0.3, seconds: 40, at: next.addingTimeInterval(300))
        await rig.detector.handle(crawler, analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        #expect(slowLines().count == 1)
        await rig.detector.stop()
        #expect(Array(slowLines().suffix(1)) == ["Sky Watcher, North Sky: 1 slow light skipped this hour (likely a star)"], "\(slowLines())")
        #expect(slowLines().allSatisfy { !$0.contains("40.0") && !$0.contains("100.0") }, "the line does not name the place")
    }

    @Test func aSlowLightNothingExplainsIsSkippedWhileTheAimIsGood() async throws {
        let id = UUID()
        let rig = try await Self.goodAimedRig(camera: id)
        defer { rig.remove() }
        let capture = CameraLogCapture.start(camera: id)
        defer { capture.stop() }
        let begins = rig.clock.value.addingTimeInterval(120)
        // Lights of under 2 s, so that the stationary guard does not hold them: 0.04°/s is a star's pace, 0.5°/s a plane's.
        let crawling = SkyPath(start: SkyDirection(azimuth: 300, elevation: 30), bearing: Double.pi / 2, legs: [SkyPath.Leg(duration: 1.6, speed: 0.04)])
        let going = SkyPath(start: SkyDirection(azimuth: 300, elevation: 30), bearing: Double.pi / 2, legs: [SkyPath.Leg(duration: 4, speed: 0.5)])
        for (index, path) in [crawling, going, crawling].enumerated() {
            let track = Self.quietTrack(along: path, at: begins.addingTimeInterval(Double(index) * 60), seenBy: Self.singleModel)
            await rig.detector.handle(track, analysisWidth: 1920, analysisHeight: 1080, pictureWidth: 1920)
        }
        let entries = await rig.logged(begins).entries
        #expect(entries.count == 1 && entries.first?.label == .unexplained && entries.first?.hasStill == true, "\(entries.map { $0.measures.speed })")
        #expect(abs((entries.first?.measures.speed ?? 0) - 0.5) < 0.05 && rig.stillsAsked.value.count == 1)
        await rig.detector.stop()
        let lines = capture.lines.filter { $0.contains("slow light") }
        #expect(lines == ["Sky Watcher, North Sky: 2 slow lights skipped this hour (likely stars)"], "\(lines)")
    }

    @Test func aSlowLightAFlightExplainsIsStillAPlane() async throws {
        let rig = try SkyDetectorRig(settings: Self.singleCard, pictureWidth: 1920, pictureHeight: 1080)
        defer { rig.remove() }
        await rig.detector.start()
        let begins = Self.start
        let path = SkyPath(start: SkyDirection(azimuth: 315, elevation: 40), bearing: Double.pi / 2, legs: [SkyPath.Leg(duration: 1.6, speed: 0.04)])
        await rig.flights.add(SkyFixtures.reports(along: path, beginningAt: begins, altitudeMeters: 3_000, from: begins.addingTimeInterval(-3),
                                                  to: begins.addingTimeInterval(5), hex: "c0ffee"))
        let track = Self.quietTrack(along: path, at: begins, seenBy: Self.singleModel)
        let measures = TrackMeasurer.measure(track, model: Self.singleModel, analysisWidth: 1920, pictureWidth: 1920)
        #expect(measures.speed < SkyLightFilter.slowDegreesPerSecond && !TrackMeasurer.isStationary(measures), "slow, but not for the old guard: \(measures.speed)°/s")
        rig.clock.set(begins.addingTimeInterval(2))
        await rig.detector.handle(track, analysisWidth: 1920, analysisHeight: 1080, pictureWidth: 1920)
        let entries = await rig.logged().entries
        #expect(entries.count == 1 && entries.first?.label == .probablePlane && entries.first?.by == .flight, "\(entries.map { ($0.label, $0.measures.speed) })")
        #expect(entries.first?.hasStill == false && rig.stillsAsked.value.isEmpty)
        await rig.detector.stop()
    }

    // A camera's thirty pictures an hour are gone (Ruling S31): every unexplained light that is logged has its picture, and the hour's 60 entries
    // bound them (`SkyClutterTests.swift`: `everyLoggedUnexplainedLightHasItsPicture`, `atMostSixtyUnexplainedEntriesAnHourAndALineSaysHowManyMoreWereNot`).

    // MARK: Ruling S25: a camera that moved

    /// What the person can change of the card: where the camera looks, which a settings update must notice.
    enum CardChange: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case facing, tilt, lensLayout

        var testDescription: String { rawValue }

        var settings: SkyDetectorSettings {
            var changed = SkyDetectorTests.singleCard
            switch self {
            case .facing: changed.facing = 345
            case .tilt: changed.tilt = 35
            case .lensLayout: changed.lensLayout = .dual
            }
            return changed
        }
    }

    @Test(arguments: CardChange.allCases) func aChangedCardStartsTheAimAgainFromTheCard(_ change: CardChange) async throws {
        let id = UUID()
        let rig = try await Self.goodAimedRig(camera: id)
        defer { rig.remove() }
        let capture = CameraLogCapture.start(camera: id)
        defer { capture.stop() }
        let before = await rig.detector.status
        #expect(before.aim.quality == .good && before.aim.planes == 12 && before.aim.lenses.count == 1)
        await rig.detector.update(change.settings)
        await rig.detector.settle()
        let after = await rig.detector.status
        #expect(after.aim == SkyAimStatus.unaimed(), "\(change): rough, nothing matched, no note: the state of a camera just added, \(after.aim)")
        #expect(after.learning == before.learning, "what the box learned of this sky is not the aim")
        #expect(capture.lines.filter { $0.contains("again") } == ["Sky Watcher, North Sky: the camera's card changed; starting the aim again"], "one line says it: \(capture.lines)")
        // What it dropped stays dropped: a restart finds no fit and no matches.
        await rig.detector.stop()
        let again = rig.again()
        await again.start()
        #expect(await again.status.aim == SkyAimStatus.unaimed())
        await again.stop()
    }

    // MARK: Ruling S25b: a card changed while the detector was off

    /// The matches kept in the rig's camera's folder.
    static func matchesKept(_ rig: SkyDetectorRig) async -> [AimCorrespondence] {
        await SkyAimStore(directory: rig.aimFile.deletingLastPathComponent(), log: Log(category: "SkyTest"), start: singleModel, pictureWidth: 1920,
                          pictureHeight: 1080).correspondences()
    }

    @Test(arguments: CardChange.allCases) func aCardChangedWhileTheDetectorWasOffStartsTheAimAgain(_ change: CardChange) async throws {
        // The person changes the card while the plugin or the camera's switch is off, so no detector is told: the next one to start finds the aim
        // was made from another card, and starts it again from this one, as a change while it runs does.
        let id = UUID()
        let rig = try await Self.goodAimedRig(camera: id)
        defer { rig.remove() }
        let before = await rig.detector.status
        await rig.detector.stop()
        #expect(await Self.matchesKept(rig).count > 0)
        let capture = CameraLogCapture.start(camera: id)
        defer { capture.stop() }
        let later = rig.again(settings: change.settings)
        await later.start()
        let after = await later.status
        #expect(after.aim == SkyAimStatus.unaimed(), "\(change): rough, nothing matched, no note: the state of a camera just added, \(after.aim)")
        #expect(after.learning == before.learning, "what the box learned of this sky is not the aim")
        #expect(capture.lines.filter { $0.contains("again") } == ["Sky Watcher, North Sky: the camera's card changed while Sky Watcher was off; starting the aim again"],
                "one line says it: \(capture.lines)")
        await later.stop()
        // The matches went with the fit, and the new card is the aim's now: started with it again, the detector says nothing more.
        #expect(await Self.matchesKept(rig).isEmpty)
        let again = rig.again(settings: change.settings)
        await again.start()
        #expect(await again.status.aim == SkyAimStatus.unaimed())
        #expect(capture.lines.filter { $0.contains("again") }.count == 1, "\(capture.lines)")
        await again.stop()
    }

    @Test func anAimSavedBeforeItsCardWasKeptKeepsItsFitAndThenItsCard() async throws {
        // An aim from before Ruling S25b has no card in its file. Its fit stays, whatever the card says now (nothing tells which card it was
        // made from), and the card is saved, so that a change while the detector is off is noticed from then on.
        let id = UUID()
        let rig = try await Self.goodAimedRig(camera: id)
        defer { rig.remove() }
        let good = await rig.detector.status.aim
        await rig.detector.stop()
        let text = try String(contentsOf: rig.aimFile, encoding: .utf8)
        let older = text.replacingOccurrences(of: #""card":\{[^{}]*\},?"#, with: "", options: .regularExpression)
        #expect(older != text && !older.contains("\"card\""), "the card is kept with the aim: \(text.count) characters")
        try Data(older.utf8).write(to: rig.aimFile)
        let capture = CameraLogCapture.start(camera: id)
        defer { capture.stop() }
        var tilted = Self.singleCard
        tilted.tilt = 35
        let upgraded = rig.again(settings: tilted)
        await upgraded.start()
        #expect(await upgraded.status.aim == good, "the fit is kept")
        await upgraded.stop()
        let saved = try String(contentsOf: rig.aimFile, encoding: .utf8)
        #expect(saved.contains(#""card":{"facing":315,"tilt":35}"#), "and the card it is on now is saved: \(saved.prefix(120))")
        // A change while it is off is noticed now.
        let later = rig.again(settings: Self.singleCard)
        await later.start()
        #expect(await later.status.aim == SkyAimStatus.unaimed())
        #expect(capture.lines.filter { $0.contains("again") }.count == 1, "\(capture.lines)")
        await later.stop()
    }

    @Test func theGroundAndTheNightProfileAreNotWhereTheCameraLooks() async throws {
        let id = UUID()
        let rig = try await Self.goodAimedRig(camera: id)
        defer { rig.remove() }
        let capture = CameraLogCapture.start(camera: id)
        defer { capture.stop() }
        let before = await rig.detector.status
        var changed = Self.singleCard
        changed.groundPercent = 30
        await rig.detector.update(changed)
        changed.nightProfile = false
        await rig.detector.update(changed)
        await rig.detector.settle()
        let after = await rig.detector.status
        #expect(after.aim == before.aim && after.aim.quality == .good && after.aim.planes == 12, "\(after.aim)")
        // The same card again, and a card moved there and back, are the camera where it was.
        await rig.detector.update(changed)
        await rig.detector.settle()
        #expect(await rig.detector.status.aim == before.aim)
        #expect(capture.lines.allSatisfy { !$0.contains("again") }, "nothing is said: \(capture.lines)")
        await rig.detector.stop()
    }

    @Test func aGoodAimThatMatchesNoPlaneForTwoHoursStartsAgain() async throws {
        let id = UUID()
        let rig = try await Self.goodAimedRig(camera: id)
        defer { rig.remove() }
        let capture = CameraLogCapture.start(camera: id)
        defer { capture.stop() }
        let model = Self.singleModel
        let before = await rig.detector.status
        var random = SkyRandom(seed: 3)
        func startedAgain() -> [String] { capture.lines.filter { $0.contains("again") } }
        // Every 15 minutes a plane crosses the view (the feed has it) and a light that the camera follows goes straight up: nothing is the plane.
        let first = Self.start.addingTimeInterval(3_600)
        for index in 0..<8 {
            let at = first.addingTimeInterval(Double(index) * 900)
            let pass = Self.pass(12 + index, at: at, seenBy: model, using: &random)
            await rig.flights.add(pass.reports)
            let climbing = SkyPath(start: SkyDirection(azimuth: 300 + Double(index) * 5, elevation: 15), bearing: 0, legs: [SkyPath.Leg(duration: 10, speed: 1)])
            let track = Self.track(along: climbing, at: at, seenBy: model, using: &random)
            rig.clock.set(at.addingTimeInterval(10))
            let entry = await rig.detector.classify(track, measures: TrackMeasurer.measure(track, model: model, analysisWidth: 1920, pictureWidth: 1920))
            #expect(entry.label == .unexplained)
            await rig.detector.tick(at: at.addingTimeInterval(8))
            let status = await rig.detector.status
            #expect(status.aim.quality == .good && status.aim.note == nil && startedAgain().isEmpty, "not before two hours: \(index)")
        }
        let later = first.addingTimeInterval(7_260)
        rig.clock.set(later)
        await rig.detector.tick(at: later)
        let status = await rig.detector.status
        let note = "No planes matched for 2 hours with the aim good; starting the aim again."
        #expect(status.aim == SkyAimStatus(quality: .rough, planes: 0, stars: 0, residualPixels: nil, updated: nil, note: note), "\(status.aim)")
        #expect(SkyMatchWatch.restartNote(for: .good) == note && status.learning == before.learning)
        #expect(startedAgain() == ["Sky Watcher, North Sky: no planes matched for 2 hours with the aim good; starting the aim again"], "\(capture.lines)")
        // Once: the stretch begins again, and the card keeps saying why the aim is rough until it is good again.
        await rig.detector.tick(at: later.addingTimeInterval(60))
        let noteAfter = await rig.detector.status.aim.note
        #expect(startedAgain().count == 1 && noteAfter == note)
        #expect(SkyMatchWatch.restartNote(for: .precise) == "No planes matched for 2 hours with the aim precise; starting the aim again.")
        #expect(SkyMatchWatch.window == 7_200, "the words say 2 hours")
        await rig.detector.stop()
    }

    @Test func theWideSearchRunsAgainOnceTheCardIsChanged() async throws {
        // A good aim; the camera is then turned 30° and tilted 10° higher, and the person sets the card roughly (30° and 10° off): the aim is rough
        // again, and two hours of planes that fit no card near it show the wide search the way.
        let rig = try await Self.goodAimedRig()
        defer { rig.remove() }
        let card = SkyDetectorSettings(enabled: true, facing: 330, tilt: 20)
        let model = SkyCameraModel.initial(facing: 330, tilt: 20, pictureWidth: 1920, pictureHeight: 1080)
        let truth = SkyCameraModel.initial(facing: 0, tilt: 30, pictureWidth: 1920, pictureHeight: 1080)
        await rig.detector.update(card)
        await rig.detector.settle()
        #expect(await rig.detector.status.aim == SkyAimStatus.unaimed())
        var random = SkyRandom(seed: 9)
        let first = Self.start.addingTimeInterval(3_600)
        for index in 0..<8 {
            let at = first.addingTimeInterval(Double(index) * 900)
            let pass = Self.pass(12 + index, at: at, seenBy: truth, using: &random)
            await rig.flights.add(pass.reports)
            rig.clock.set(at.addingTimeInterval(16))
            let entry = await rig.detector.classify(pass.track, measures: TrackMeasurer.measure(pass.track, model: model, analysisWidth: 1920, pictureWidth: 1920))
            #expect(entry.label == .unexplained, "the card is 30° off: no match")
            await rig.detector.tick(at: at.addingTimeInterval(8))
        }
        let later = first.addingTimeInterval(7_260)
        rig.clock.set(later)
        await rig.detector.tick(at: later)
        let status = await rig.detector.status
        #expect(status.aim.note == "The planes fit the camera facing about 30° further right and tilted 10° higher than set: it aims from there now.",
                "\(status.aim.note ?? "no note")")
        let at = later.addingTimeInterval(60)
        let pass = Self.pass(20, at: at, seenBy: truth, using: &random)
        await rig.flights.add(pass.reports)
        rig.clock.set(at.addingTimeInterval(16))
        let entry = await rig.detector.classify(pass.track, measures: TrackMeasurer.measure(pass.track, model: truth, analysisWidth: 1920, pictureWidth: 1920))
        #expect(entry.label == .probablePlane && entry.by == .flight, "the next plane matches through the card the search found")
        await rig.detector.stop()
    }
}

// MARK: - Ruling S25 through the service

extension SkyServiceTests {
    // The settings update path: the engine gives the service a new context for a camera whose card changed.
    @Test func theCardChangesThroughTheServiceReachTheRunningDetector() async throws {
        let data = try TemporaryDirectory()
        let id = UUID()
        // A good aim, kept in the camera's own folder by an earlier run…
        let earlier = try SkyDetectorRig(settings: SkyDetectorTests.singleCard, pictureWidth: 1920, pictureHeight: 1080, data: data, camera: id)
        defer { earlier.remove() }
        await earlier.detector.start()
        var random = SkyRandom(seed: 12)
        await SkyDetectorTests.teachTheAim(earlier.detector, flights: earlier.flights, clock: earlier.clock, using: &random)
        await earlier.detector.stop()
        // …and a service that starts the camera's detector from it.
        let service = SkyService(dataDirectory: data.url, http: SkyFakeFeed(), logStore: SkyLogStore(log: .silent), now: { earlier.clock.value })
        let recordings = earlier.recordings.url
        func context(_ settings: SkyDetectorSettings) -> SkyCameraDetector.Context {
            SkyCameraDetector.Context(cameraID: id, cameraName: "North Sky", settings: settings, observer: SkyFixtures.observer, zone: SkyDetectorRig.zone,
                                      pictureWidth: 1920, pictureHeight: 1080, folder: { recordings }, still: { _ in nil })
        }
        let sky = SkySettings(location: Self.place)
        let detector = try #require(await service.update(settings: sky, cameras: [id: context(SkyDetectorTests.singleCard)])[id])
        let good = await detector.status.aim
        #expect(good.quality == .good && good.planes == 12, "\(good)")
        // The ground and the night profile: the aim stays.
        var other = SkyDetectorTests.singleCard
        other.groundPercent = 40
        other.nightProfile = false
        await service.update(settings: sky, cameras: [id: context(other)])
        await detector.settle()
        #expect(await detector.status.aim == good)
        // The facing: the same detector, its aim started again.
        other.facing = 345
        let running = await service.update(settings: sky, cameras: [id: context(other)])
        await detector.settle()
        let restarted = await detector.status.aim
        #expect(running[id] === detector && restarted == SkyAimStatus.unaimed(), "\(restarted)")
        await service.stop()
    }

    // Ruling S25b: the plugin (or the camera's switch) is off, so there is no detector to tell; the card changes; the plugin is switched on.
    @Test func aCardChangedWhileThePluginWasOffStartsTheAimAgain() async throws {
        let data = try TemporaryDirectory()
        let id = UUID()
        let earlier = try SkyDetectorRig(settings: SkyDetectorTests.singleCard, pictureWidth: 1920, pictureHeight: 1080, data: data, camera: id)
        defer { earlier.remove() }
        await earlier.detector.start()
        var random = SkyRandom(seed: 12)
        await SkyDetectorTests.teachTheAim(earlier.detector, flights: earlier.flights, clock: earlier.clock, using: &random)
        #expect(await earlier.detector.status.aim.quality == .good)
        await earlier.detector.stop()
        var turned = SkyDetectorTests.singleCard
        turned.facing = 345
        let service = SkyService(dataDirectory: data.url, http: SkyFakeFeed(), logStore: SkyLogStore(log: .silent), now: { earlier.clock.value })
        let recordings = earlier.recordings.url
        let context = SkyCameraDetector.Context(cameraID: id, cameraName: "North Sky", settings: turned, observer: SkyFixtures.observer,
                                                zone: SkyDetectorRig.zone, pictureWidth: 1920, pictureHeight: 1080, folder: { recordings },
                                                still: { _ in nil })
        let detector = try #require(await service.update(settings: SkySettings(location: Self.place), cameras: [id: context])[id])
        let aim = await detector.status.aim
        #expect(aim == SkyAimStatus.unaimed(), "\(aim)")
        await service.stop()
    }
}
