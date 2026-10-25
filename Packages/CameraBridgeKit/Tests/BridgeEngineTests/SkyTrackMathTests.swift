import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

/// Track measures (`TrackMeasurer`), how much sky is visible (`SkyVisibility`) and the Sun's mask: made-up paths across the sky (great
/// circles at set speeds, with turns and stops), seen through the truth dual camera (`SkyFixtures.truthDual`, 4256×1888, analysed at
/// 1920×852) five times a second, and made-up backgrounds with and without stars.
@Suite struct SkyTrackMathTests {
    static let model = SkyFixtures.truthDual
    static let analysisWidth = 1920, analysisHeight = 852, pictureWidth = 4256

    /// A made-up track of `path` seen through `model`: a sample at each picture whose direction a lens sees (through the lens it was last
    /// seen through while that one still sees it), its direction first moved by up to `noise` degrees. `flux` and `skip` (a picture with no
    /// sample: the light was not seen) are per picture.
    static func track(_ path: SkyPath, model: SkyCameraModel = model, noise: Double = 0, area: Int = 9, flux: (Int) -> Double = { _ in 400 },
                      sharpness: Double = 0.6, skip: (Int) -> Bool = { _ in false },
                      using random: inout SkyRandom) -> SkyTrack {
        var samples: [SkyTrackSample] = []
        var misses: [TimeInterval] = []
        var lens = -1
        for (index, item) in path.directions().enumerated() {
            let seen = noise > 0 ? SkyFixtures.noisy(item.direction, upTo: noise, using: &random) : item.direction
            let hits = model.project(seen)
            guard let hit = hits.first(where: { $0.lens == lens }) ?? hits.first else { continue }
            if skip(index) {
                misses.append(item.time)
                continue
            }
            lens = hit.lens
            samples.append(SkyTrackSample(time: item.time, wallClock: SkyFixtures.aimEpoch.addingTimeInterval(item.time), point: hit.point,
                                          area: area, flux: flux(index), sharpness: sharpness, elongation: 1, lens: hit.lens,
                                          inSeamBand: model.isInSeamBand(hit.point)))
        }
        // Only the misses between the first and the last sample are the track's.
        let span = (samples.first?.time ?? 0)...(samples.last?.time ?? 0)
        return SkyTrack(id: UUID(), samples: samples, streakBorn: false, misses: misses.filter { span.contains($0) })
    }

    static func measure(_ track: SkyTrack, model: SkyCameraModel = model) -> SkyMeasures {
        TrackMeasurer.measure(track, model: model, analysisWidth: analysisWidth, pictureWidth: pictureWidth)
    }

    /// Up the sky in the north, a little west of the truth camera's seam (the housing faces 352°).
    static let north = SkyDirection(azimuth: 335, elevation: 25)
    static let east = Double.pi / 2

    // MARK: Speed

    @Test func speedAndAccelerationAreRight() throws {
        var random = SkyRandom(seed: 31)
        // 1.2°/s for 30 s along a great circle, across the seam.
        let steady = SkyPath(start: Self.north, bearing: Self.east, legs: [SkyPath.Leg(duration: 30, speed: 1.2)])
        let track = Self.track(steady, noise: 0.02, using: &random)
        #expect(Set(track.samples.map(\.lens)) == [0, 1])
        let measures = Self.measure(track)
        #expect(abs(measures.speed / 1.2 - 1) <= 0.02, "speed \(measures.speed)°/s")
        #expect(abs(measures.acceleration) <= 0.01, "acceleration \(measures.acceleration)°/s²")
        #expect(abs(measures.duration - 30) < 1e-9)
        let start = try #require(steady.directions().first?.direction), end = try #require(steady.directions().last?.direction)
        #expect(SkyMath.separation(SkyDirection(azimuth: measures.azimuth, elevation: measures.elevation), start) < 0.05)
        #expect(SkyMath.separation(SkyDirection(azimuth: measures.azimuthEnd, elevation: measures.elevationEnd), end) < 0.05)
        #expect(measures.shape == .straight && measures.straightness > 0.99 && measures.maxTurn < 10, "maxTurn \(measures.maxTurn)°")
        // A light that speeds up by 0.1°/s every second (0.5 to 3.4°/s).
        let legs = (0..<30).map { SkyPath.Leg(duration: 1, speed: 0.55 + 0.1 * Double($0)) }
        let speeding = Self.measure(Self.track(SkyPath(start: Self.north, bearing: Self.east, legs: legs), noise: 0.02, using: &random))
        #expect(abs(speeding.acceleration - 0.1) <= 0.01, "acceleration \(speeding.acceleration)°/s²")
        #expect(abs(speeding.speed - 2.0) <= 0.04, "speed \(speeding.speed)°/s")
    }

    @Test func aSampleIsMeasuredThroughTheLensItIsIn() {
        var random = SkyRandom(seed: 38)
        // A track across the seam whose samples all say lens 0 (as from a picture analysed without the model): outside the seam band each
        // is measured through the lens of its half, so the speed is still right.
        let steady = SkyPath(start: Self.north, bearing: Self.east, legs: [SkyPath.Leg(duration: 30, speed: 1.2)])
        var track = Self.track(steady, noise: 0.02, using: &random)
        #expect(track.samples.contains { $0.lens == 1 })
        for index in track.samples.indices { track.samples[index].lens = 0 }
        let measures = Self.measure(track)
        #expect(abs(measures.speed / 1.2 - 1) <= 0.02, "speed \(measures.speed)°/s")
        #expect(measures.shape == .straight)
    }

    @Test func stationaryLightsAreStationary() {
        var random = SkyRandom(seed: 32)
        let still = SkyPath(start: Self.north, bearing: 0, legs: [SkyPath.Leg(duration: 3, speed: 0)])
        #expect(TrackMeasurer.isStationary(Self.measure(Self.track(still, noise: 0.02, using: &random))))
        // Too short to tell, or moving slowly but surely.
        let brief = SkyPath(start: Self.north, bearing: 0, legs: [SkyPath.Leg(duration: 1.6, speed: 0)])
        #expect(!TrackMeasurer.isStationary(Self.measure(Self.track(brief, noise: 0.02, using: &random))))
        let slow = SkyPath(start: Self.north, bearing: 0, legs: [SkyPath.Leg(duration: 20, speed: 0.2)])
        #expect(!TrackMeasurer.isStationary(Self.measure(Self.track(slow, noise: 0.02, using: &random))))
    }

    // MARK: Shape

    @Test func shapesAreRecognised() {
        var random = SkyRandom(seed: 33)
        func shape(_ legs: [SkyPath.Leg]) -> SkyMeasures {
            Self.measure(Self.track(SkyPath(start: Self.north, bearing: Self.east, legs: legs), noise: 0.02, using: &random))
        }
        // A 90° turn within 0.4 s at 2°/s.
        let turn = shape([.init(duration: 3, speed: 2), .init(duration: 0.4, speed: 2, turnRate: 225), .init(duration: 3, speed: 2)])
        #expect(turn.shape == .sharpTurn && turn.maxTurn >= 60, "maxTurn \(turn.maxTurn)°")
        // A stop from 1°/s that then stays 2 s.
        let stop = shape([.init(duration: 4, speed: 1), .init(duration: 2, speed: 0)])
        #expect(stop.shape == .suddenStop)
        #expect(stop.acceleration < 0)
        // Arcs: a gentle one (8°/s, 64° in all) and a tight one (25°/s).
        let gentle = shape([.init(duration: 8, speed: 1.5, turnRate: 8)])
        #expect(gentle.shape == .curved && gentle.maxTurn < 15 && gentle.straightness < 0.97,
                "maxTurn \(gentle.maxTurn)°, straightness \(gentle.straightness)")
        let tight = shape([.init(duration: 4, speed: 2, turnRate: 25)])
        #expect(tight.shape == .curved && tight.maxTurn >= 15 && tight.maxTurn < 60, "maxTurn \(tight.maxTurn)°")
        // A hard arc, 45° within each second, is still no sharp turn; a single 20° bend in a straight path is a curve, though its chord is
        // 0.985 of its path.
        let hard = shape([.init(duration: 2, speed: 2), .init(duration: 2, speed: 2, turnRate: 45), .init(duration: 2, speed: 2)])
        #expect(hard.shape == .curved && hard.maxTurn > 35 && hard.maxTurn < 55, "maxTurn \(hard.maxTurn)°")
        let bend = shape([.init(duration: 5, speed: 1.5), .init(duration: 0.2, speed: 1.5, turnRate: 100), .init(duration: 5, speed: 1.5)])
        #expect(bend.shape == .curved && bend.maxTurn > 15 && bend.maxTurn < 25 && bend.straightness >= 0.97,
                "maxTurn \(bend.maxTurn)°, straightness \(bend.straightness)")
        // The turn rate follows the turning: 64° over 12° travelled, against nearly nothing for a straight line.
        #expect(abs(gentle.turnRate - 64.0 / 12) <= 1, "turn rate \(gentle.turnRate)°/°")
        let straight = shape([.init(duration: 10, speed: 1.5)])
        #expect(straight.shape == .straight && straight.turnRate < 1, "turn rate \(straight.turnRate)°/°")
        // Slowing down over 3 s is no sudden stop; turning 90° over 6 s is no sharp turn.
        let slowing = shape([.init(duration: 3, speed: 1)] + (1...5).map { .init(duration: 0.6, speed: 1 - Double($0) / 6) }
            + [.init(duration: 2, speed: 0)])
        #expect(slowing.shape != .suddenStop)
        let wide = shape([.init(duration: 2, speed: 1.5), .init(duration: 6, speed: 1.5, turnRate: 15), .init(duration: 2, speed: 1.5)])
        #expect(wide.shape == .curved, "maxTurn \(wide.maxTurn)°")
        // A sharp turn too slow to see (0.1°/s) is not called one.
        let creeping = shape([.init(duration: 6, speed: 0.1), .init(duration: 0.4, speed: 0.1, turnRate: 225), .init(duration: 6, speed: 0.1)])
        #expect(creeping.shape != .sharpTurn)
    }

    @Test func aStopIsFoundThroughCentroidJitter() {
        // Through a wide lens (the start model of a 4256-px dual camera analysed 1920 wide: 0.113° a pixel where the light is), a light at
        // 0.7°/s for 4 s that stops dead and stays 2 s, its centroid wandering 0.3 px each way (σ) as a faint blob's does: a sudden stop in
        // nearly every trial (judged by where it stays within 5 % of a second's travel, 0.3 px, it was found in 14 of 200). A light that
        // keeps going, or slows to a third, through the same jitter, is no stop.
        var random = SkyRandom(seed: 40)
        let wide = SkyCameraModel.initial(facing: 0, tilt: 20, pictureWidth: 4256, pictureHeight: 1888)
        let start = PixelPoint(x: 0.3, y: 0.4)
        let perPixel = wide.degreesPerPixel(at: start, pictureWidth: Self.analysisWidth)
        #expect(abs(perPixel - 0.113) < 0.002)
        func gauss() -> Double {
            let u1 = Double.random(in: Double.ulpOfOne..<1, using: &random), u2 = Double.random(in: 0..<1, using: &random)
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
        func shapes(after speedAfter: Double, trials: Int) -> Int {
            var stops = 0
            for _ in 0..<trials {
                let pixelsPerSecond = 0.7 / perPixel
                let samples = (0...30).map { k -> SkyTrackSample in
                    let t = Double(k) * 0.2
                    let x = start.x * Double(Self.analysisWidth) + pixelsPerSecond * (min(t, 4) + speedAfter / 0.7 * max(0, t - 4)) + 0.3 * gauss()
                    let y = start.y * Double(Self.analysisHeight) + 0.3 * gauss()
                    return SkyTrackSample(time: t, wallClock: SkyFixtures.aimEpoch.addingTimeInterval(t),
                                          point: PixelPoint(x: x / Double(Self.analysisWidth), y: y / Double(Self.analysisHeight)), area: 9, flux: 400,
                                          sharpness: 0.6, elongation: 1)
                }
                let measures = TrackMeasurer.measure(SkyTrack(id: UUID(), samples: samples, streakBorn: false), model: wide,
                                                     analysisWidth: Self.analysisWidth, pictureWidth: 4256)
                if measures.shape == .suddenStop { stops += 1 }
            }
            return stops
        }
        let stopped = shapes(after: 0, trials: 100)
        #expect(stopped >= 95, "a stop found in \(stopped) of 100")
        let going = shapes(after: 0.7, trials: 50), slowing = shapes(after: 0.7 / 3, trials: 50)
        #expect(going == 0 && slowing == 0, "going on: \(going) stops; slowing to a third: \(slowing)")
    }

    @Test func aSharpTurnNeedsSpeed() {
        var random = SkyRandom(seed: 39)
        // A lens 20° across 1920 px (0.01° a pixel): a 90° turn within 0.4 s is measured as one at 0.15°/s too, but it is a sharp turn only
        // at 0.2°/s or more.
        let narrow = SkyCameraModel(layout: .single, seam: SkyCameraModel.defaultSeam, lenses: [
            SkyCameraModel.Lens(yaw: 0, pitch: 30, roll: 0, horizontalFOV: 20, verticalFOV: SkyCameraModel.Lens.verticalFOV(horizontalFOV: 20, frameAspect: 16.0 / 9),
                                principalPoint: PixelPoint(x: 0.5, y: 0.5), radial: []),
        ])
        func turn(at speed: Double) -> SkyMeasures {
            let legs = [SkyPath.Leg(duration: 4, speed: speed), .init(duration: 0.4, speed: speed, turnRate: 225), .init(duration: 4, speed: speed)]
            let path = SkyPath(start: SkyDirection(azimuth: 359.5, elevation: 30), bearing: Self.east, legs: legs)
            return Self.measure(Self.track(path, model: narrow, noise: 0.001, using: &random), model: narrow)
        }
        let slow = turn(at: 0.15), brisk = turn(at: 0.3)
        #expect(slow.maxTurn >= 60 && slow.shape != .sharpTurn, "slow: maxTurn \(slow.maxTurn)°, \(slow.shape)")
        #expect(brisk.shape == .sharpTurn, "brisk: maxTurn \(brisk.maxTurn)°, \(brisk.shape)")
    }

    // MARK: Size, brightness, focus, blinking

    @Test func sizeBrightnessAndFocusAreMeasured() throws {
        var random = SkyRandom(seed: 34)
        let path = SkyPath(start: Self.north, bearing: Self.east, legs: [SkyPath.Leg(duration: 6, speed: 1)])
        let track = Self.track(path, area: 12, flux: { 300 + Double($0 % 3) * 50 }, sharpness: 0.45, using: &random)
        let measures = Self.measure(track)
        let sizes = track.samples.map { 2 * (12 / Double.pi).squareRoot() * Self.model.degreesPerPixel(at: $0.point, pictureWidth: Self.analysisWidth) }
            .sorted()
        let median = sizes[sizes.count / 2]
        #expect(abs(measures.sizeDegrees / median - 1) < 0.02, "size \(measures.sizeDegrees)° against \(median)°")
        #expect(measures.sizeDegrees > 0.2 && measures.sizeDegrees < 0.5)
        // The median flux, in the original picture's pixels (the analysed picture is 1920 of its 4256).
        let scale = Double(Self.pictureWidth) / Double(Self.analysisWidth)
        #expect(abs(measures.brightness - 350 * scale * scale) < 1e-6)
        #expect(abs(measures.focus - 0.45) < 1e-12)
        #expect(!measures.blinks && measures.blinkRate == nil)
    }

    @Test func blinkingIsCountedFromDips() throws {
        var random = SkyRandom(seed: 35)
        let path = SkyPath(start: Self.north, bearing: Self.east, legs: [SkyPath.Leg(duration: 12, speed: 1)])
        // Dips of the flux below 30 % of the median, every 2 s: 0.5 Hz.
        let dipping = Self.measure(Self.track(path, flux: { $0 % 10 == 5 ? 60 : 400 }, using: &random))
        #expect(dipping.blinks)
        #expect(abs((dipping.blinkRate ?? 0) - 0.5) < 0.05, "blinks \(dipping.blinkRate ?? 0) Hz")
        // Pictures where it was not seen at all count as dips: 2.5 Hz, the most five pictures a second can show.
        let flashing = Self.measure(Self.track(path, skip: { $0 % 2 == 1 }, using: &random))
        #expect(flashing.blinks)
        #expect(abs((flashing.blinkRate ?? 0) - 2.5) < 0.05, "blinks \(flashing.blinkRate ?? 0) Hz")
        // A run of low pictures is one dip; two dips are not blinking; dips to 40 % are not dips.
        let runs = Self.measure(Self.track(path, flux: { [3, 4, 5].contains($0 % 10) ? 50 : 400 }, using: &random))
        #expect(runs.blinks && abs((runs.blinkRate ?? 0) - 0.5) < 0.05, "blinks \(runs.blinkRate ?? 0) Hz")
        let twice = Self.measure(Self.track(path, flux: { [20, 40].contains($0) ? 50 : 400 }, using: &random))
        #expect(!twice.blinks && twice.blinkRate == nil)
        let shallow = Self.measure(Self.track(path, flux: { $0 % 10 == 5 ? 160 : 400 }, using: &random))
        #expect(!shallow.blinks)
    }

    @Test func measuresSurviveOddTracks() {
        // No samples, one sample, samples the model has no direction for: finite measures, never a trap.
        let empty = SkyTrack(id: UUID(), samples: [], streakBorn: false)
        let point = SkyTrackSample(time: 3, wallClock: SkyFixtures.aimEpoch, point: PixelPoint(x: 0.3, y: 0.3), area: 4, flux: 90, sharpness: 0.5,
                                   elongation: 1)
        let lone = SkyTrack(id: UUID(), samples: [point], streakBorn: true)
        var far = point
        far.point = PixelPoint(x: .nan, y: 2)
        let broken = SkyTrack(id: UUID(), samples: [point, far, point], streakBorn: false)
        for track in [empty, lone, broken] {
            let measures = Self.measure(track)
            let numbers = [measures.azimuth, measures.elevation, measures.azimuthEnd, measures.elevationEnd, measures.duration, measures.speed,
                           measures.acceleration, measures.turnRate, measures.maxTurn, measures.straightness, measures.sizeDegrees,
                           measures.brightness, measures.focus]
            let finite = numbers.allSatisfy { $0.isFinite }
            #expect(finite)
            #expect(!TrackMeasurer.isStationary(measures))
        }
        // The measures are what the log keeps: they encode and decode.
        let measures = Self.measure(lone)
        let data = try? JSONEncoder().encode(measures)
        #expect(data.flatMap { try? JSONDecoder().decode(SkyMeasures.self, from: $0) } == measures)
    }

    // MARK: How much sky is visible

    /// A made-up background (the analyzer's running mean): a dark sky with a little noise, and stars where `starry` says.
    static func background(stars: [(x: Int, y: Int, amplitude: Float)], starry: (Int) -> Bool, width: Int = 640, height: Int = 284,
                           using random: inout SkyRandom) -> GrayImage {
        var picture = SkyPicture(width: width, height: height, sky: 22, noise: 0.6, using: &random)
        for star in stars where starry(star.x) { picture.star(x: star.x, y: star.y, amplitude: star.amplitude) }
        return picture.image
    }

    @Test func visibilityIsUnknownUntilThreeNights() throws {
        var random = SkyRandom(seed: 36)
        let stars = (0..<500).map { _ in
            (x: Int.random(in: 3..<637, using: &random), y: Int.random(in: 3..<246, using: &random), amplitude: Float.random(in: 10...70, using: &random))
        }
        let mask = SkyMask(groundPercent: 12)
        var visibility = SkyVisibility()
        let evening = Date(timeIntervalSince1970: 1_792_893_600)   // 2026-10-25 02:00 UTC
        func at(_ night: Int, minute: Int) -> Date { evening.addingTimeInterval(Double(night) * 86_400 + Double(minute) * 60) }
        // Three clear nights (an hour each, a sample a minute), with a day between: unknown all along, and by day.
        for night in 0..<3 {
            for minute in 0..<60 {
                let clear = Self.background(stars: stars, starry: { _ in true }, using: &random)
                let early = visibility.sample(clear, mask: mask, at: at(night, minute: minute), isNight: true)
                #expect(early == nil)
            }
            let day = Self.background(stars: [], starry: { _ in true }, using: &random)
            let daytime = visibility.sample(day, mask: mask, at: at(night, minute: 720), isNight: false)
            #expect(daytime == nil)
        }
        // Then a clear night is visible, and a blank one (clouds) is not.
        let clearSky = Self.background(stars: stars, starry: { _ in true }, using: &random)
        let clear = try #require(visibility.sample(clearSky, mask: mask, at: at(3, minute: 0), isNight: true) as Double?)
        #expect(clear >= 0.6, "clear: \(clear)")
        // Within the minute, the same answer (a sample a minute).
        let blank = Self.background(stars: stars, starry: { _ in false }, using: &random)
        let withinTheMinute = visibility.sample(blank, mask: mask, at: at(3, minute: 0).addingTimeInterval(20), isNight: true)
        #expect(withinTheMinute == clear)
        let cloudy = try #require(visibility.sample(blank, mask: mask, at: at(3, minute: 1), isNight: true) as Double?)
        #expect(cloudy < 0.3, "blank: \(cloudy)")
        // Half the sky clouded over: about half visible.
        let halfSky = Self.background(stars: stars, starry: { $0 < 320 }, using: &random)
        let half = try #require(visibility.sample(halfSky, mask: mask, at: at(3, minute: 2), isNight: true) as Double?)
        #expect(abs(half - 0.5) <= 0.1, "half: \(half)")
        // Thin cloud everywhere, a fifth of the stars left: not visible (under 30 % of a clear night); half of them: visible.
        let thin = Self.background(stars: Array(stars.enumerated().filter { $0.offset % 5 == 0 }.map(\.element)), starry: { _ in true }, using: &random)
        let thinShare = try #require(visibility.sample(thin, mask: mask, at: at(3, minute: 3), isNight: true) as Double?)
        #expect(thinShare < 0.3, "a fifth of the stars: \(thinShare)")
        let haze = Self.background(stars: Array(stars.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)), starry: { _ in true }, using: &random)
        let hazeShare = try #require(visibility.sample(haze, mask: mask, at: at(3, minute: 4), isNight: true) as Double?)
        #expect(hazeShare >= 0.6, "half of the stars: \(hazeShare)")
        // A blank night after: not visible; by day, unknown.
        let blankNight = try #require(visibility.sample(blank, mask: mask, at: at(4, minute: 0), isNight: true) as Double?)
        #expect(blankNight < 0.3)
        let byDay = visibility.sample(blank, mask: mask, at: at(4, minute: 720), isNight: false)
        #expect(byDay == nil)
        // What was learned is kept (the detector saves it).
        let saved = try JSONEncoder().encode(visibility)
        var restored = try JSONDecoder().decode(SkyVisibility.self, from: saved)
        let laterSky = Self.background(stars: stars, starry: { _ in true }, using: &random)
        let again = try #require(restored.sample(laterSky, mask: mask, at: at(5, minute: 0), isNight: true) as Double?)
        #expect(again >= 0.6)
    }

    @Test func aShortOrStarlessHistoryStaysUnknown() {
        var random = SkyRandom(seed: 37)
        let mask = SkyMask(groundPercent: 12)
        var visibility = SkyVisibility()
        let evening = Date(timeIntervalSince1970: 1_792_893_600)
        // Three nights of five minutes each are too short to count; three starless nights teach nothing either.
        for night in 0..<3 {
            for minute in 0..<5 {
                _ = visibility.sample(Self.background(stars: [], starry: { _ in true }, using: &random), mask: mask,
                                      at: evening.addingTimeInterval(Double(night) * 86_400 + Double(minute) * 60), isNight: true)
            }
        }
        let afterShortNights = visibility.sample(Self.background(stars: [], starry: { _ in true }, using: &random), mask: mask,
                                                 at: evening.addingTimeInterval(3 * 86_400), isNight: true)
        #expect(afterShortNights == nil)
        var starless = SkyVisibility()
        for night in 0..<4 {
            for minute in 0..<30 {
                let result = starless.sample(Self.background(stars: [], starry: { _ in true }, using: &random), mask: mask,
                                             at: evening.addingTimeInterval(Double(night) * 86_400 + Double(minute) * 60), isNight: true)
                #expect(result == nil)
            }
        }
    }

    @Test func theVisibilityMemoryIsBoundedAndAPolarNightCloses() throws {
        var random = SkyRandom(seed: 43)
        let stars = (0..<250).map { _ in
            (x: Int.random(in: 3..<317, using: &random), y: Int.random(in: 3..<123, using: &random), amplitude: Float.random(in: 10...70, using: &random))
        }
        let clear = Self.background(stars: stars, starry: { _ in true }, width: 320, height: 142, using: &random)
        let blank = Self.background(stars: stars, starry: { _ in false }, width: 320, height: 142, using: &random)
        let mask = SkyMask(groundPercent: 12)
        let evening = Date(timeIntervalSince1970: 1_792_893_600)
        // One long night, a sample every ten minutes: what is kept of it does not grow with its minutes (it kept every minute's counts).
        var long = SkyVisibility()
        var sizes: [Int] = []
        for step in 0..<84 {
            _ = long.sample(clear, mask: mask, at: evening.addingTimeInterval(Double(step) * 600), isNight: true)
            if step == 5 || step == 83 { sizes.append(try JSONEncoder().encode(long).count) }
        }
        #expect(sizes[1] - sizes[0] < 100, "\(sizes[0]) bytes after an hour, \(sizes[1]) after 14 hours")
        // A polar night: the Sun stays down and the samples never pause. A night closes after 24 hours, so the third ends at 72 hours, and
        // the answer is known from then on: a clear sky is visible, a blank one is not.
        var polar = SkyVisibility()
        var early = 0
        for step in 0..<432 where polar.sample(clear, mask: mask, at: evening.addingTimeInterval(Double(step) * 600), isNight: true) != nil {
            early += 1
        }
        #expect(early == 0, "known \(early) times before the third 24 hours ended")
        let known = try #require(polar.sample(clear, mask: mask, at: evening.addingTimeInterval(72 * 3_600), isNight: true) as Double?)
        #expect(known >= 0.6)
        let clouded = try #require(polar.sample(blank, mask: mask, at: evening.addingTimeInterval(72 * 3_600 + 600), isNight: true) as Double?)
        #expect(clouded < 0.3)
    }

    // MARK: The Sun's mask

    @Test func theSunIsMaskedWithinFifteenDegreesWhileItIsUp() throws {
        // 2026-12-21, 18:44 UTC: about local noon at 100° W; the Sun is in the south, about 26.6° up.
        let noon = Date(timeIntervalSince1970: 1_797_878_640)
        let sun = SunEphemeris.direction(at: noon, observer: SkyFixtures.observer)
        #expect(abs(sun.azimuth - 180) < 3 && abs(sun.elevation - 26.6) < 1)
        let south = SkyCameraModel.initial(facing: 180, tilt: 25, pictureWidth: 1920, pictureHeight: 1080)
        let circles = SkyMask.sunCircles(at: noon, observer: SkyFixtures.observer, model: south, pictureWidth: 1920, pictureHeight: 1080)
        #expect(circles.count == 1)
        let circle = try #require(circles.first)
        let seen = try #require(south.project(sun).first)
        #expect(abs(circle.center.x - seen.point.x) < 1e-9 && abs(circle.center.y - seen.point.y) < 1e-9)
        // 15° across the picture's width at the Sun: the lens is 100° across 1920 px, 0.07° a pixel at its centre.
        let edge = try #require(south.direction(at: PixelPoint(x: circle.center.x + circle.radius, y: circle.center.y))?.direction)
        #expect(abs(SkyMath.separation(edge, sun) - 15) < 0.5, "the circle's edge is \(SkyMath.separation(edge, sun))° from the Sun")
        // Just out of the view (about 7° past its edge), the circle still reaches in; about 25° past the edge, it does not.
        let aside = SkyCameraModel.initial(facing: 120, tilt: 25, pictureWidth: 1920, pictureHeight: 1080)
        let reaching = SkyMask.sunCircles(at: noon, observer: SkyFixtures.observer, model: aside, pictureWidth: 1920, pictureHeight: 1080)
        #expect(reaching.count == 1 && (reaching.first?.center.x ?? 0) > 1)
        let away = SkyCameraModel.initial(facing: 100, tilt: 25, pictureWidth: 1920, pictureHeight: 1080)
        #expect(SkyMask.sunCircles(at: noon, observer: SkyFixtures.observer, model: away, pictureWidth: 1920, pictureHeight: 1080).isEmpty)
        // At midnight the Sun is down: nothing is masked for it.
        let midnight = noon.addingTimeInterval(-12 * 3600)
        #expect(SkyMask.sunCircles(at: midnight, observer: SkyFixtures.observer, model: south, pictureWidth: 1920, pictureHeight: 1080).isEmpty)
    }
}
