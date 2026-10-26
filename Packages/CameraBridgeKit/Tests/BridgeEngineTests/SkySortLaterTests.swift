import BridgeSupport
@testable import CameraAdapters
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

// The lights logged before the rules, sorted by them as a night's log is read (the owner's request of 2026-10-26: his night of Oct 25 was 1,533
// lights, every one "unexplained", and the replay of the rules sorted most of them). The log is never written for it; a person's word still wins.
// All made up: the place is 40.0000, −100.0000, the lights are synthetic.

@Suite(.timeLimit(.minutes(3))) struct SkySortLaterTests {
    static let camera = SkyLogStoreTests.camera
    static let observer = SkyFixtures.observer
    /// The truth dual camera's picture.
    static let picture = SkyPictureSize(width: 4256, height: 1888)

    /// What is known of the camera: the truth dual camera's aim (analysed 1920 wide), its picture, and what it learned (the defaults by default).
    static func known(model: SkyCameraModel? = SkyFixtures.truthDual, picture: SkyPictureSize? = Self.picture,
                      baseline: SkyBaseline = SkyBaseline()) -> SkySortLater.Camera {
        SkySortLater.Camera(model: model, analysisWidth: 1920, picture: picture, baseline: baseline)
    }

    static func sorter(_ camera: SkySortLater.Camera = Self.known()) -> SkySortLater {
        SkySortLater(observer: Self.observer, camera: camera)
    }

    /// The one light of `entries`, sorted on its own.
    static func sorted(_ entry: SkyEntry, _ camera: SkySortLater.Camera = Self.known()) throws -> SkyEntry {
        try #require(Self.sorter(camera).sort([entry], night: [entry]).first)
    }

    /// `track` as an older build logged it: unexplained, named by nothing, no guide, and none of the measures it did not keep.
    static func logged(_ track: SkyTrack) -> SkyEntry {
        var measures = SkyFixtures.measures(of: track, model: SkyFixtures.truthDual)
        measures.strobePeriod = nil
        measures.strobeStrength = nil
        measures.seenShare = nil
        measures.wobble = nil
        measures.turns = nil
        return SkyCameraDetector.entry(of: track, measures: measures, camera: Self.camera)
    }

    /// What the detector makes of `track` now, alone in its picture: every measure of its own, and the rules and the guide as it applies them.
    static func live(_ track: SkyTrack) throws -> SkyEntry {
        let measures = SkyFixtures.measures(of: track, model: SkyFixtures.truthDual)
        var entry = SkyCameraDetector.entry(of: track, measures: measures, camera: Self.camera)
        let middle = SkyStillBackfill.middle(of: entry)
        var light = SkyRuleLight(measures: measures, samples: track.samples.count,
                                 sunElevation: SunEphemeris.direction(at: middle, observer: Self.observer).elevation)
        let first = try #require(track.samples.first), last = try #require(track.samples.last)
        let across = (last.point.x - first.point.x) * Double(Self.picture.width), down = (last.point.y - first.point.y) * Double(Self.picture.height)
        if hypot(across, down) > 0 { light.fromStraightDown = atan2(abs(across), down) * SkyMath.degrees }
        light.degreesPerPicture = measures.speed * (last.time - first.time) / Double(track.samples.count + track.misses.count - 1)
        light.satelliteSunlit = SkyRules.satelliteCouldBeSunlit(SkyRules.halfway(measures), at: middle, observer: Self.observer)
        SkyRules.judge(&entry, light: light, baseline: SkyBaseline())
        return entry
    }

    /// An entry as an older build logged it, of made-up measures: a light going east from 300°, `elevation` up, at `speed` °/s for `duration` s,
    /// its path a point a picture (five a second; thinned to 64, as the log keeps it) across the picture, or straight down it (`down`).
    static func old(_ id: String, at start: Date, speed: Double, duration: Double, elevation: Double = 30, straightness: Double = 0.999,
                    shape: SkyPathShape = .straight, size: Double = 0.3, focus: Double = 0.6, down: Bool = false) -> SkyEntry {
        let measures = SkyMeasures(azimuth: 300, elevation: elevation, azimuthEnd: 300 + speed * duration, elevationEnd: elevation, duration: duration,
                                   speed: speed, acceleration: 0, turnRate: 0, maxTurn: 0, straightness: straightness, shape: shape, sizeDegrees: size,
                                   brightness: 400, blinks: false, blinkRate: nil, focus: focus)
        let points = (0...Int((duration * 5).rounded(.down))).map { index -> SkyPathPoint in
            let t = Double(index) / 5, share = duration > 0 ? t / duration : 0
            return down ? SkyPathPoint(t: t, x: 0.3, y: 0.2 + 0.06 * share) : SkyPathPoint(t: t, x: 0.2 + 0.1 * share, y: 0.3)
        }
        let most = SkyPathPoint.maximumPerEntry
        let path = points.count > most ? (0..<most).map { points[$0 * (points.count - 1) / (most - 1)] } : points
        return SkyEntry(id: id, camera: Self.camera, kind: .track, start: SkyLogStore.millisecond(start), end: SkyLogStore.millisecond(start.addingTimeInterval(duration)),
                        path: path, measures: measures, label: .unexplained)
    }

    /// A chain of noise: 4 s going east from 300°, 30° up, at 3°/s, every picture 0.6° to one side of its way and the next to the other.
    static func zigzag(at start: Date) -> SkyTrack {
        let path = SkyPath(start: SkyDirection(azimuth: 300, elevation: 30), bearing: Double.pi / 2, legs: [SkyPath.Leg(duration: 4, speed: 3)])
        let samples = path.directions().enumerated().compactMap { index, point in
            SkyFixtures.sample(at: start.addingTimeInterval(point.time), since: start,
                               direction: SkyFixtures.offset(point.direction, by: 0.6, toward: index % 2 == 0 ? 0 : Double.pi), through: SkyFixtures.truthDual)
        }
        return SkyTrack(id: UUID(), samples: samples, streakBorn: false)
    }

    // MARK: Which lights

    @Test func onlyTheUnexplainedLightsOfTheOldPipelineAreSorted() throws {
        let old = Self.old("o", at: SkyRulesTests.night, speed: 1, duration: 3)
        #expect(SkySortLater.needsSorting(old))
        var corrected = old
        corrected.correction = .bird
        #expect(SkySortLater.needsSorting(corrected), "the person's word wins on screen, but the light is sorted all the same")
        var guided = old
        guided.priority = .low
        guided.reasons = ["Nothing unusual about it"]
        var plane = old
        plane.label = .plane
        plane.by = .flight
        var rule = old
        rule.label = .probableSatellite
        rule.by = .rule
        var named = old
        named.by = .person
        for entry in [guided, plane, rule, named] { #expect(!SkySortLater.needsSorting(entry), "\(entry.label) \(String(describing: entry.by))") }
        // What is not sorted comes back as it was, the guide's fields and all.
        let lights = [guided, plane, rule, named]
        #expect(Self.sorter().sort(lights, night: lights) == lights)
        let sorted = try Self.sorted(old)
        #expect(sorted.sortedLater && sorted.priority != nil && !sorted.reasons.isEmpty)
        #expect(sorted.path == old.path && sorted.measures == old.measures && sorted.start == old.start && sorted.id == old.id, "the light itself is as logged")
    }

    // MARK: As the detector sorts one now

    @Test func anOldLightIsSortedAsTheDetectorSortsOneNow() throws {
        // A satellite's steady crossing in the evening: 20 s (its path thinned to 64 points) and 10 s (a point a picture).
        for seconds in [20.0, 10] {
            let steady = SkyRulesTests.track(SkyRulesTests.path(speed: 0.6, seconds: seconds), start: SkyRulesTests.evening) { _ in 300 }
            let sorted = try Self.sorted(Self.logged(steady)), live = try Self.live(steady)
            #expect(sorted.label == .probableSatellite && sorted.by == .rule && sorted.sortedLater, "\(seconds) s: \(sorted.label)")
            #expect(sorted.detail == "Probable satellite: a steady light at a steady speed (no orbit check yet)")
            #expect(sorted.priority == nil && sorted.reasons.isEmpty && !sorted.doubtful)
            #expect(sorted.label == live.label && sorted.detail == live.detail, "as the detector would log it")
        }
        // A distant plane seen only when its strobe flashes (one picture in six): its path holds a point for each flash, and the pictures between
        // them are the ones it was missed in, so its strobe is found again.
        let flashes = SkyRulesTests.track(SkyRulesTests.path(speed: 0.4, seconds: 30), start: SkyRulesTests.night) { $0 % 6 == 0 ? 600 : 0 }
        let strobe = try Self.sorted(Self.logged(flashes))
        #expect(strobe.label == .probablePlane && strobe.detail == "Probable plane: it flashes every 1.2 s, like a plane’s strobe", "\(String(describing: strobe.detail))")
        #expect(try Self.live(flashes).detail == strobe.detail)
        // A chain of noise that zigzags across the sky: its path is ragged, and it is doubted as the detector doubts it now. Without the path's
        // measures (no aim known) it would be "fast across the sky", and high.
        let ragged = Self.zigzag(at: SkyRulesTests.night)
        let doubted = try Self.sorted(Self.logged(ragged)), live = try Self.live(ragged)
        #expect(doubted.label == .unexplained && doubted.doubtful && doubted.priority == .low && doubted.reasons == ["A ragged path: noise, most likely"],
                "\(doubted.reasons)")
        #expect(live.priority == doubted.priority && live.reasons == doubted.reasons && live.doubtful)
        let unmeasured = try Self.sorted(Self.logged(ragged), Self.known(model: nil))
        #expect(unmeasured.priority == .high && !unmeasured.doubtful && unmeasured.unusual.contains(.faster) && unmeasured.candidate, "\(unmeasured.reasons)")
    }

    @Test func aPathThinnedTo64PointsGivesNoStrobe() throws {
        // The same distant plane for 80 s: 67 flashes, thinned to 64 points as the log keeps them. Which pictures it was missed in is not known, so
        // its strobe is not looked for: a steady light now, a probable plane or satellite by where it is, but not by a strobe.
        let flashes = SkyRulesTests.track(SkyRulesTests.path(speed: 0.4, seconds: 80), start: SkyRulesTests.night) { $0 % 6 == 0 ? 600 : 0 }
        #expect(flashes.samples.count > SkyPathPoint.maximumPerEntry)
        let entry = Self.logged(flashes)
        #expect(entry.path.count == SkyPathPoint.maximumPerEntry)
        let sorted = try Self.sorted(entry)
        #expect([.probablePlane, .probableSatellite].contains(sorted.label) && sorted.detail?.contains("flashes") == false, "\(String(describing: sorted.detail))")
        // The measures the rules took (`measured`): the wobble and the turns from the path, and no strobe or share of pictures.
        let measured = Self.sorter().measured(entry)
        #expect(measured.strobePeriod == nil && measured.strobeStrength == nil && measured.seenShare == nil)
        #expect((measured.wobble ?? 9) < 0.1 && measured.turns == 0, "\(measured)")
        // A whole path gives them all: the sparse plane of 30 s was seen in one picture in six.
        let short = Self.sorter().measured(Self.logged(SkyRulesTests.track(SkyRulesTests.path(speed: 0.4, seconds: 30), start: SkyRulesTests.night) {
            $0 % 6 == 0 ? 600 : 0
        }))
        #expect(abs((short.seenShare ?? 0) - 26.0 / 151) < 0.01 && abs((short.strobePeriod ?? 0) - 1.2) < 0.01, "\(short)")
        // Without an aim nothing is measured again: the rules take them as absent.
        #expect(Self.sorter(Self.known(model: nil)).measured(entry) == entry.measures)
        // Its step from one picture to the next (for a ragged path) is its speed over the pictures' pace, as for a whole path.
        let thinned = Self.sorter().light(of: entry, began: SkySortLater.Began(count: 1, near: 1, cameraChange: false))
        #expect(abs((thinned.degreesPerPicture ?? 0) - entry.measures.speed / 5) < 1e-6, "\(String(describing: thinned.degreesPerPicture))")
        let whole = Self.logged(SkyRulesTests.track(SkyRulesTests.path(speed: 0.4, seconds: 30), start: SkyRulesTests.night) { $0 % 6 == 0 ? 600 : 0 })
        let step = Self.sorter().light(of: whole, began: SkySortLater.Began(count: 1, near: 1, cameraChange: false)).degreesPerPicture
        #expect(abs((step ?? 0) - whole.measures.speed / 5) < 1e-6, "\(String(describing: step))")
    }

    // MARK: What the night and the picture say

    @Test func howALightBeganIsCountedFromTheNightsStartTimes() {
        let base = SkyLogStore.millisecond(SkyRulesTests.night)
        func at(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }
        // Three began in one picture, one more 0.6 s later; one alone; five in one picture at 100 s (the camera changing its picture), and three
        // around it.
        let starts = [at(0), at(0), at(0), at(0.6), at(5), at(99.5), at(108), at(111)] + Array(repeating: at(100), count: 5)
        let night = SkySortLater.Beginnings(starts)
        #expect(night.began(at: at(0)) == SkySortLater.Began(count: 3, near: 4, cameraChange: false))
        #expect(night.began(at: at(0.6)) == SkySortLater.Began(count: 1, near: 4, cameraChange: false))
        #expect(night.began(at: at(5)) == SkySortLater.Began(count: 1, near: 1, cameraChange: false))
        #expect(night.began(at: at(100)).count == 5 && night.began(at: at(100)).cameraChange)
        #expect(night.began(at: at(99.5)).cameraChange, "half a second before the change")
        #expect(night.began(at: at(108)).cameraChange && !night.began(at: at(111)).cameraChange, "up to 10 s after it")
        #expect(SkySortLater.Beginnings([]).began(at: at(3)) == SkySortLater.Began(count: 1, near: 1, cameraChange: false), "a light counts itself")

        // Through the sorting: the three that began together are doubted, the one alone is not.
        let together = (1...3).map { Self.old("t-\($0)", at: SkyRulesTests.night, speed: 1, duration: 3) }
        let alone = Self.old("a-1", at: SkyRulesTests.night.addingTimeInterval(30), speed: 1, duration: 3)
        let sorted = Self.sorter(Self.known(model: nil)).sort(together + [alone], night: together + [alone])
        #expect(sorted.prefix(3).allSatisfy { $0.doubtful && $0.reasons == ["Began with 2 other lights at the same moment: the camera changing its picture, most likely"] })
        #expect(sorted[3].reasons == ["Too short to tell a plane from a satellite"] && !sorted[3].doubtful)
    }

    @Test func aStreakStraightDownThePictureIsABugOnSilkOnceThePicturesSizeIsKnown() throws {
        let streak = Self.old("s", at: SkyRulesTests.night, speed: 3, duration: 0.8, size: 0.8, focus: 0.1, down: true)
        #expect(try Self.sorted(streak).detail == "Bug on silk: straight down in front of the lens")
        #expect(try Self.sorted(streak, Self.known(model: nil)).label == .bug, "the picture's size is enough")
        let unknown = try Self.sorted(streak, Self.known(model: nil, picture: nil))
        #expect(unknown.label == .meteor && unknown.detail == "Meteor: short, fast and straight", "which way it went in the picture is not known")
        let sideways = Self.old("w", at: SkyRulesTests.night, speed: 3, duration: 0.8, size: 0.8, focus: 0.1)
        #expect(try Self.sorted(sideways).label == .meteor)
    }

    @Test func whatTheCameraLearnedJudgesTheOldLightsToo() throws {
        let fast = Self.old("f", at: SkyRulesTests.night, speed: 5, duration: 3, elevation: 5, straightness: 0.96, shape: .curved)
        let unlearned = try Self.sorted(fast)
        #expect(unlearned.priority == .high && unlearned.reasons == ["Fast across the sky (about 2.5× typical planes)"] && unlearned.speedVsPlanes == nil)
        let learned = try Self.sorted(fast, Self.known(baseline: SkyRulesTests.baseline(planes: 40, speed: 0.8)))
        #expect(learned.priority == .high && learned.reasons == ["Fast across the sky (about 6× a plane at that height)"], "\(learned.reasons)")
        #expect(abs((learned.speedVsPlanes ?? 0) - 6.25) < 0.1 && learned.unusual == [.faster] && learned.candidate)
    }

    // MARK: The cost

    /// An old light `index` of a busy night from `start`, one every 20 s: made-up measures of every kind (birds, planes, satellites, meteors, noise),
    /// and a path a point a picture (some pictures missed), thinned to 64.
    static func busy(_ index: Int, from start: Date, using random: inout SkyRandom) -> SkyEntry {
        let duration = [0.8, 2.5, 4, 8, 20, 45][index % 6] * Double.random(in: 0.8...1.2, using: &random)
        let speed = [6.0, 3, 1.2, 0.6, 0.4, 0.2][(index / 6) % 6] * Double.random(in: 0.7...1.3, using: &random)
        let elevation = Double.random(in: 3...70, using: &random)
        let straightness = Double.random(in: 0.9...1, using: &random)
        let measures = SkyMeasures(azimuth: Double.random(in: 0..<360, using: &random), elevation: elevation, azimuthEnd: Double.random(in: 0..<360, using: &random),
                                   elevationEnd: min(80, elevation + Double.random(in: -3...3, using: &random)), duration: duration, speed: speed, acceleration: 0,
                                   turnRate: 0.1, maxTurn: 10, straightness: straightness, shape: straightness > 0.97 ? .straight : .curved,
                                   sizeDegrees: Double.random(in: 0.05...1.4, using: &random), brightness: 300, blinks: index % 7 == 0, blinkRate: nil,
                                   focus: Double.random(in: 0.05...1, using: &random))
        let from = (x: Double.random(in: 0.05...0.95, using: &random), y: Double.random(in: 0.05...0.8, using: &random))
        let heading = Double.random(in: 0..<(2 * Double.pi), using: &random), rate = speed / 90 / 2   // a half of the picture is about 90°
        var points: [SkyPathPoint] = []
        for picture in 0...Int((duration * 5).rounded(.down)) where picture == 0 || Double.random(in: 0...1, using: &random) > 0.15 {
            let t = Double(picture) / 5
            let wobble = Double.random(in: -0.0004...0.0004, using: &random)
            points.append(SkyPathPoint(t: t, x: min(1, max(0, from.x + cos(heading) * rate * t + wobble)), y: min(1, max(0, from.y + sin(heading) * rate * t * 2.25))))
        }
        let most = SkyPathPoint.maximumPerEntry
        let path = points.count > most ? (0..<most).map { points[$0 * (points.count - 1) / (most - 1)] } : points
        let begins = SkyLogStore.millisecond(start.addingTimeInterval(Double(index) * 20 + Double.random(in: 0...3, using: &random)))
        return SkyEntry(id: "busy-\(index)", camera: Self.camera, kind: .track, start: begins, end: SkyLogStore.millisecond(begins.addingTimeInterval(duration)),
                        path: path, measures: measures, label: .unexplained)
    }

    /// The cost of the sorting (the report's timing): 2,000 old lights of every kind, their paths measured through the aim, then grouped. A debug
    /// build on a Mac takes half a second alone and about a second among the other sky suites; the box runs a release build, which takes about
    /// 25 ms on a Mac.
    @Test func aNightOfTwoThousandOldLightsIsSortedAndGroupedQuickly() {
        var random = SkyRandom(seed: 25)
        let entries = (0..<2_000).map { Self.busy($0, from: SkyRulesTests.evening, using: &random) }
        let sorter = Self.sorter()
        let began = ContinuousClock.now
        let judged = sorter.sort(entries, night: entries)
        let sortedAt = ContinuousClock.now
        let sorted = SkyFormations.mark(judged)
        let took = began.duration(to: .now)
        let labels = Dictionary(grouping: sorted, by: \.label).mapValues(\.count).sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }
        print("SkySortLater timing: 2,000 old lights sorted in \(began.duration(to: sortedAt)), grouped in \(sortedAt.duration(to: .now)) "
              + "(\(labels.joined(separator: ", ")); \(sorted.filter(\.doubtful).count) doubted, \(sorted.filter { $0.group != nil }.count) in groups)")
        #expect(sorted.count == 2_000 && sorted.allSatisfy(\.sortedLater))
        #expect(labels.count >= 4, "a night of every kind: \(labels)")
        #expect(took < .seconds(4), "\(took)")
    }
}

// MARK: - The night as the page reads it

extension SkyNightLogEngineTests {
    @MainActor @Test func oldLightsAreSortedByTheRulesAsTheNightIsReadAndTheLogStaysAsItWas() async throws {
        let rig = try await Rig()
        // 8 PM in Chicago on the 24th: dark, and a satellite in the north-west can be in the sunlight.
        let evening = SkyRulesTests.evening
        func at(_ minutes: Double) -> Date { evening.addingTimeInterval(minutes * 60) }
        var zigzag = SkySortLaterTests.logged(SkySortLaterTests.zigzag(at: at(70)))
        zigzag.id = "o-zigzag"
        zigzag.hasStill = true
        var guided = SkySortLaterTests.old("n-new", at: at(30), speed: 5, duration: 3)
        guided.priority = .low
        guided.reasons = ["Nothing unusual about it"]
        var plane = SkySortLaterTests.old("n-plane", at: at(40), speed: 0.5, duration: 20)
        plane.label = .plane
        plane.by = .flight
        plane.detail = "TEST123 · 35,000 ft"
        var rule = SkySortLaterTests.old("n-rule", at: at(50), speed: 0.6, duration: 20)
        rule.label = .probableSatellite
        rule.by = .rule
        rule.detail = "Probable satellite: a steady light at a steady speed (no orbit check yet)"
        // As an older build logged them: a steady light at a satellite's pace, twice more (the person says one was a bird, and is not sure of
        // the other), a light fast across the sky, a short fast straight streak, three that began at once, and by day a bird.
        func old(_ id: String, _ start: Date, _ speed: Double, _ duration: Double, elevation: Double = 30, straightness: Double = 0.999,
                 shape: SkyPathShape = .straight, size: Double = 0.3) -> SkyEntry {
            SkySortLaterTests.old(id, at: start, speed: speed, duration: duration, elevation: elevation, straightness: straightness, shape: shape, size: size)
        }
        // The three that began at once are in three places of the picture: three lights at one place, going one way together, would be one light
        // followed three times, which the reading joins first (`SkyStitch`).
        func apart(_ entry: SkyEntry, by down: Double) -> SkyEntry {
            var moved = entry
            moved.path = entry.path.map { SkyPathPoint(t: $0.t, x: $0.x, y: $0.y + down) }
            return moved
        }
        let entries = [
            old("o-sat", at(0), 0.6, 20), old("o-said", at(10), 0.6, 20), old("o-unsure", at(20), 0.6, 20), guided, plane, rule,
            old("o-fast", at(60), 5, 3, elevation: 40, straightness: 0.96, shape: .curved), old("o-meteor", at(90), 12, 0.8, elevation: 50, size: 0.4),
            old("o-c1", at(120), 1, 3, elevation: 20), apart(old("o-c2", at(120), 1, 3, elevation: 20), by: 0.15),
            apart(old("o-c3", at(120), 1, 3, elevation: 20), by: 0.3),
            old("o-bird", SkyLogStoreTests.local(24, 14), 20, 2.5, straightness: 0.95, shape: .curved, size: 0.4),
        ]
        for entry in entries { await rig.file(entry) }
        // A picture: the night's pictures say how big the camera's are, and the card is the aim (the detector does not run).
        await rig.file(zigzag, still: SkyThumbnailStoreTests.still("zigzag"))
        _ = try await rig.engine.correctSkyEntry(cameraID: rig.cameraID, entryID: "o-said", night: "2026-10-24", label: .bird)
        let unsure = try await rig.engine.correctSkyEntry(cameraID: rig.cameraID, entryID: "o-unsure", night: "2026-10-24", label: .notSure)
        #expect(unsure.label == .probableSatellite && unsure.sortedLater && SkyDisplay.label(unsure) == .probableSatellite,
                "a correction answers the light as the log reads now: \(unsure.label)")
        await rig.log.flush()   // the corrections' lines are the person's, written as they come
        let file = SkyLogStore.nightFile(folder: rig.recordings.url, camera: rig.cameraID, night: "2026-10-24")
        let written = try Data(contentsOf: file)

        let log = try await rig.night("2026-10-24", .night)
        let byID = Dictionary(uniqueKeysWithValues: log.entries.map { ($0.id, $0) })
        func entry(_ id: String) throws -> SkyEntry { try #require(byID[id], "\(id)") }
        // The old lights come back sorted, as if the rules had logged them, and say so.
        let sat = try entry("o-sat")
        #expect(sat.label == .probableSatellite && sat.by == .rule && sat.detail == "Probable satellite: a steady light at a steady speed (no orbit check yet)")
        #expect(sat.sortedLater && sat.priority == nil && sat.reasons.isEmpty)
        let fast = try entry("o-fast")
        #expect(fast.label == .unexplained && fast.by == nil && fast.priority == .high && fast.reasons == ["Fast across the sky (about 2.5× typical planes)"])
        #expect(fast.unusual == [.faster] && fast.candidate && fast.sortedLater)
        #expect(try entry("o-meteor").label == .meteor && entry("o-meteor").detail == "Meteor: short, fast and straight")
        let together = "Began with 2 other lights at the same moment: the camera changing its picture, most likely"
        for id in ["o-c1", "o-c2", "o-c3"] {
            let doubted = try entry(id)
            #expect(doubted.doubtful && doubted.priority == .low && doubted.reasons == [together])
        }
        let ragged = try entry("o-zigzag")
        #expect(ragged.doubtful && ragged.reasons == ["A ragged path: noise, most likely"], "its path measured through the card: \(ragged.reasons)")
        // The person's word wins: a bird is a bird; "not sure" shows what the rules say.
        let said = try entry("o-said")
        #expect(said.label == .probableSatellite && said.correction == .bird && SkyDisplay.label(said) == .bird && said.sortedLater)
        #expect(try SkyDisplay.label(entry("o-unsure")) == .probableSatellite)
        // What the box logged with the rules, or explained otherwise, is as it was.
        #expect(try entry("n-new") == guided && entry("n-plane") == plane && entry("n-rule") == rule)
        #expect(log.counts == SkyCounts(unexplained: 6, planes: 1, satellites: 2, meteors: 1, bugsAndBirds: 1, notSure: 1, explained: 6), "\(log.counts)")
        // By day the old light is a bird.
        let day = try await rig.night("2026-10-24", .day)
        #expect(day.entries.map(\.id) == ["o-bird"] && day.entries[0].label == .bird && day.entries[0].sortedLater)

        // The log was read, never written: it stays append-only (the corrections' lines are the person's), and reads the same again.
        #expect(try Data(contentsOf: file) == written)
        #expect(try await rig.night("2026-10-24", .night).entries == log.entries)
    }

    /// The whole of a night's read (the report's timing): the file of 2,001 old lights read and decoded, sorted with the card as the aim, grouped
    /// and counted. Then the same night as the box logs it now, which is read without sorting.
    @MainActor @Test func aNightOfTwoThousandOldLightsIsReadQuickly() async throws {
        let rig = try await Rig()
        var random = SkyRandom(seed: 26)
        let entries = (0..<2_000).map { SkySortLaterTests.busy($0, from: SkyRulesTests.evening, using: &random) }
        // Written as an older build wrote them, and one picture: the card over the picture's size is the aim their paths are measured through.
        let file = SkyLogStore.nightFile(folder: rig.recordings.url, camera: rig.cameraID, night: "2026-10-24")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = SkyLogStore.makeEncoder()
        var bytes = Data()
        for entry in entries {
            bytes.append(try encoder.encode(SkyLogStore.Line(v: 1, entry: entry)))
            bytes.append(0x0A)
        }
        try bytes.write(to: file)
        var pictured = SkySortLaterTests.old("pictured", at: SkyRulesTests.evening.addingTimeInterval(-60), speed: 0.6, duration: 20)
        pictured.hasStill = true
        await rig.file(pictured, still: SkyThumbnailStoreTests.still("size"))

        let began = ContinuousClock.now
        let log = try await rig.night("2026-10-24", .night)
        let took = began.duration(to: .now)
        #expect(log.entries.count == 2_001 && log.entries.allSatisfy(\.sortedLater) && log.picture == SkyPictureSize(width: 1920, height: 852))
        // The same lights as the box logs them now: nothing to sort.
        var guided = Data()
        for entry in log.entries where entry.id != "pictured" {
            var logged = entry
            logged.sortedLater = false
            logged.group = nil
            guided.append(try encoder.encode(SkyLogStore.Line(v: 1, entry: logged)))
            guided.append(0x0A)
        }
        try guided.write(to: file)
        await rig.file(pictured, still: SkyThumbnailStoreTests.still("size"))
        let again = ContinuousClock.now
        let read = try await rig.night("2026-10-24", .night)
        let plain = again.duration(to: .now)
        #expect(read.entries.count == 2_001 && read.entries.filter(\.sortedLater).map(\.id) == ["pictured"])
        print("SkySortLater timing: a night of 2,001 old lights (\(bytes.count / 1_024) KiB) read whole by the engine in \(took); "
              + "the same night logged with the rules, in \(plain)")
        #expect(took < .seconds(6), "\(took)")
    }
}
