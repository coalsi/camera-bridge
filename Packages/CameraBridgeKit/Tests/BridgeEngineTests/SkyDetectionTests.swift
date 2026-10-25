import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

/// Finding and following lights (`SkyFrameAnalyzer`, `SkyTracker`): made-up pictures 640×284 (a flat sky with seeded Gaussian noise of
/// σ 3), dots drawn as 3×3 Gaussians, 1-px "stars" and 1-px-thick streaks, analysed five a second as the detector does.
@Suite struct SkyDetectionTests {
    static let width = 640, height = 284
    static let interval = 0.2

    /// Pictures through an analyzer and a tracker as the detector (Task 7) runs them, five a second: a whole-picture change ends what was
    /// open and drops it; every other picture updates the tracker, with no detections when there are none.
    final class Run {
        let analyzer: SkyFrameAnalyzer
        let tracker: SkyTracker
        var mask = SkyMask()
        var isNight = true
        private(set) var time: TimeInterval = 0
        private(set) var results: [SkyFrameResult] = []
        private(set) var ended: [SkyTrack] = []
        /// The tracks the tracker dropped as they ended, apart from `ended` (`SkyTracker.update(_:at:wallClock:dropped:)`).
        private(set) var dropped: [SkyDroppedTrack] = []

        init(width: Int = SkyDetectionTests.width, height: Int = SkyDetectionTests.height) {
            analyzer = SkyFrameAnalyzer(width: width, height: height)
            tracker = SkyTracker(width: width, height: height)
        }

        func feed(_ picture: SkyPicture) {
            let result = analyzer.process(picture.image, mask: mask, isNight: isNight)
            results.append(result)
            if result.globalChange {
                _ = tracker.endAll()
            } else {
                ended += tracker.update(result.detections, at: time, wallClock: SkyFixtures.aimEpoch.addingTimeInterval(time), dropped: &dropped)
            }
            time += SkyDetectionTests.interval
        }

        /// Ends what is open, as a gap does: the tracks kept over the whole run (the dropped ones are in `dropped`).
        func finish() -> [SkyTrack] {
            ended + tracker.endAll(dropped: &dropped)
        }

        /// The detections of every picture, in order.
        var detections: [[SkyDetection]] { results.map(\.detections) }
    }

    /// A single lens over the made-up 640×284 picture (100° across, facing north and up 30°), for measuring tracks found in it.
    static let singleLens = SkyCameraModel.initial(facing: 0, tilt: 30, pictureWidth: width, pictureHeight: height, layout: .single)

    /// The distance (px) from a sample's point to the line through `origin` along `angle` (degrees from the x axis towards y).
    static func offLine(_ sample: SkyTrackSample, origin: (x: Double, y: Double), angle: Double) -> Double {
        let x = sample.point.x * Double(width) - origin.x, y = sample.point.y * Double(height) - origin.y
        let radians = angle * Double.pi / 180
        return abs(-x * sin(radians) + y * cos(radians))
    }

    // MARK: Finding

    @Test func aMovingDotIsDetectedAndTracked() throws {
        var random = SkyRandom(seed: 11)
        let run = Run()
        var truth: [(x: Double, y: Double)] = []
        for frame in 0..<45 {
            var picture = SkyPicture(using: &random)
            let k = frame - 5
            if (0..<25).contains(k) {
                let point = (x: 100.3 + 12 * Double(k), y: 120.6 + 0.1 * Double(k))
                truth.append(point)
                picture.dot(x: point.x, y: point.y, amplitude: 70)
            }
            run.feed(picture)
        }
        // The dot alone: no noise detection anywhere.
        let found = run.detections.flatMap { $0 }
        #expect(found.count == 25)
        #expect(run.detections[5..<30].allSatisfy { $0.count == 1 })
        for (detection, point) in zip(found, truth) {
            let miss: Double = ((detection.x - point.x) * (detection.x - point.x) + (detection.y - point.y) * (detection.y - point.y)).squareRoot()
            #expect(miss < 0.4, "the dot at (\(point.x), \(point.y)) was found \(miss) px away")
            #expect(detection.brighter && detection.lens == 0 && !detection.inSeamBand)
            #expect(detection.elongation < 1.6)
            #expect(detection.area >= 5 && detection.area <= 25)
        }
        #expect(run.ended.count == 1)
        let track = try #require(run.ended.first)
        #expect(abs(track.samples.count - 25) <= 1)
        #expect(!track.streakBorn && track.brighter && track.misses.isEmpty)
        #expect(run.tracker.activeCount == 0)
        #expect(run.tracker.endAll().isEmpty)
        // Its points are the picture's own 0…1, and its times the pictures'.
        let first = try #require(track.samples.first)
        #expect(abs(first.point.x - 100.3 / 640) < 0.001 && abs(first.point.y - 120.6 / 284) < 0.002)
        #expect(abs(first.time - 1.0) < 1e-9 && first.wallClock == SkyFixtures.aimEpoch.addingTimeInterval(1.0))
    }

    @Test func staticStarsAreNotDetected() {
        var random = SkyRandom(seed: 12)
        let stars = (0..<40).map { _ in
            (x: Int.random(in: 4..<636, using: &random), y: Int.random(in: 4..<240, using: &random), amplitude: Float.random(in: 30...150, using: &random))
        }
        // Stars in the sky from the start: the background begins with them, so none is ever found.
        let steady = Run()
        for _ in 0..<40 {
            var picture = SkyPicture(using: &random)
            for star in stars { picture.star(x: star.x, y: star.y, amplitude: star.amplitude) }
            steady.feed(picture)
        }
        #expect(steady.detections.allSatisfy { $0.isEmpty })
        // Twinkling by ±10 % from picture to picture changes nothing: the smoothing keeps a quarter of a 1-px flicker.
        let twinkling = Run()
        for _ in 0..<40 {
            var picture = SkyPicture(using: &random)
            for star in stars { picture.star(x: star.x, y: star.y, amplitude: star.amplitude * Float.random(in: 0.9...1.1, using: &random)) }
            twinkling.feed(picture)
        }
        #expect(twinkling.detections.allSatisfy { $0.isEmpty })
        // By ±25 %, the brightest flicker past the threshold now and then, where they are: they make no track (they do not move).
        let flickering = Run()
        for _ in 0..<40 {
            var picture = SkyPicture(using: &random)
            for star in stars { picture.star(x: star.x, y: star.y, amplitude: star.amplitude * Float.random(in: 0.75...1.25, using: &random)) }
            flickering.feed(picture)
        }
        #expect(!flickering.detections.flatMap({ $0 }).isEmpty)
        for detection in flickering.detections.flatMap({ $0 }) {
            let atAStar = stars.contains { abs(Double($0.x) + 0.5 - detection.x) < 1 && abs(Double($0.y) + 0.5 - detection.y) < 1 }
            #expect(atAStar, "a detection at (\(detection.x), \(detection.y)) is at no star")
        }
        #expect((flickering.ended + flickering.tracker.endAll()).isEmpty)
        // Stars that come out (a cloud clears) are found at first, then settle into the background (after 40 pictures it holds 87 % of
        // each: a bright one's rest, with the noise, still passes now and then, alone). They make no track: they do not move.
        let clearing = Run()
        for frame in 0..<55 {
            var picture = SkyPicture(using: &random)
            if frame >= 5 { for star in stars { picture.star(x: star.x, y: star.y, amplitude: star.amplitude) } }
            clearing.feed(picture)
        }
        #expect(clearing.detections[5].count >= 10)
        #expect(clearing.detections[45...].allSatisfy { $0.count <= 1 })
        #expect((clearing.ended + clearing.tracker.endAll()).isEmpty)
    }

    @Test(arguments: [Float(40), -40])
    func aWholePictureChangeResetsWithoutTracks(step: Float) throws {
        var random = SkyRandom(seed: 13)
        let run = Run()
        for frame in 0..<70 {
            var picture = SkyPicture(sky: 60, using: &random)
            if frame >= 30 { picture.brighten(by: step) }
            if (8..<60).contains(frame) { picture.dot(x: 60.4 + 8 * Double(frame - 8), y: 140.5, amplitude: 70) }
            run.feed(picture)
        }
        // The switch is one whole-picture change (the IR-cut filter), and the 2 s after it find nothing.
        let changes = run.results.indices.filter { run.results[$0].globalChange }
        #expect(changes == [30])
        #expect(run.results[30].detections.isEmpty)
        #expect(run.detections[31...40].allSatisfy { $0.isEmpty })
        #expect(!run.detections[41].isEmpty)
        // The track open at the switch was dropped; no track has samples on both sides of it; the dot is followed again after it.
        let switchTime = 30 * Self.interval
        for track in run.ended {
            #expect(track.samples.allSatisfy { $0.time < switchTime } || track.samples.allSatisfy { $0.time > switchTime })
        }
        #expect(run.ended.count == 1)
        let after = try #require(run.ended.first)
        #expect(abs((after.samples.first?.time ?? 0) - 41 * Self.interval) < 1e-9)
        #expect(after.samples.count == 19)
        #expect(run.results.allSatisfy { !$0.noisy })
    }

    @Test func theThresholdFollowsTheNoise() {
        // A faint dot (amplitude 25: about 11.6 levels once smoothed) and a brighter one (45: about 21). Over noise of σ 3 the threshold is
        // its floor, 8: both are found in every picture, and the noise never passes. Over noise of σ 10 it is 4σ of the smoothed difference
        // (about 15): the faint dot is found in a few pictures at most (against 17 of 20 with the floor alone), the brighter one in nearly
        // all (against about 6 at 6σ); the noise itself passes a few times a picture, here and there (lower, it would flood the picture),
        // and makes no track. Both dots make tracks over σ 3; over σ 10 neither is kept: the brighter one stands only about 1.35 times over
        // that threshold, so every sample of its track is faint (under 1.5), as noise lined up by chance would be.
        for (noise, faintFound) in [(Float(3), true), (10, false)] {
            var random = SkyRandom(seed: 26)
            let run = Run()
            var faint = 0, bright = 0, stray = 0
            for frame in 0..<52 {
                var picture = SkyPicture(sky: 60, noise: noise, using: &random)
                let k = frame - 30
                let x = 200.5 + 6 * Double(k)
                if (0..<20).contains(k) {
                    picture.dot(x: x, y: 100.5, amplitude: 25)
                    picture.dot(x: x, y: 180.5, amplitude: 45)
                }
                run.feed(picture)
                let found = run.detections[frame]
                if (0..<20).contains(k) {
                    faint += found.contains { abs($0.x - x) < 2 && abs($0.y - 100.5) < 2 } ? 1 : 0
                    bright += found.contains { abs($0.x - x) < 2 && abs($0.y - 180.5) < 2 } ? 1 : 0
                } else if frame >= 2 {
                    stray += found.count
                }
            }
            #expect(faintFound ? faint == 20 : faint <= 8, "noise σ \(noise): the faint dot was found in \(faint) of 20 pictures")
            #expect(bright >= (faintFound ? 20 : 16), "noise σ \(noise): the brighter dot was found in \(bright) of 20 pictures")
            #expect(run.results.allSatisfy { !$0.noisy })
            #expect(faintFound ? stray == 0 : stray <= 5 * 30, "noise σ \(noise): \(stray) detections of noise in 30 pictures")
            let tracks = run.ended + run.tracker.endAll()
            #expect(tracks.count == (faintFound ? 2 : 0), "noise σ \(noise) made \(tracks.count) tracks")
        }
    }

    @Test func aChangeOfAFifthOfThePictureIsWhole() {
        // 30 % of the rows 40 levels brighter at once is a whole-picture change; 10 % is not one, and is too large (over 5000 px) to be a
        // light.
        for (share, whole) in [(0.3, true), (0.1, false)] {
            var random = SkyRandom(seed: 27)
            let run = Run()
            for frame in 0..<8 {
                var picture = SkyPicture(sky: 60, using: &random)
                if frame >= 5 {
                    for index in 0..<(Int(Double(Self.height) * share) * Self.width) { picture.values[index] += 40 }
                }
                run.feed(picture)
            }
            #expect(run.results[5].globalChange == whole)
            #expect(run.results[5...].allSatisfy { $0.detections.isEmpty })
        }
    }

    @Test func theGroundMaskHidesTheBottom() {
        var random = SkyRandom(seed: 14)
        // The bottom 12 % of 284 rows is 34 rows (250…283).
        let ground = Run()
        ground.mask = SkyMask(groundPercent: 12)
        for frame in 0..<40 {
            var picture = SkyPicture(using: &random)
            picture.dot(x: 50.5 + 10 * Double(frame), y: 266.5, amplitude: 90)
            ground.feed(picture)
        }
        #expect(ground.detections.allSatisfy { $0.isEmpty })
        #expect(ground.ended.isEmpty && ground.tracker.activeCount == 0)
        // The same dot just above the ground is found.
        let sky = Run()
        sky.mask = SkyMask(groundPercent: 12)
        for frame in 0..<40 {
            var picture = SkyPicture(using: &random)
            picture.dot(x: 50.5 + 10 * Double(frame), y: 245.5, amplitude: 90)
            sky.feed(picture)
        }
        #expect(sky.detections[2...].allSatisfy { $0.count == 1 })
    }

    @Test func circlesAreMaskedToo() {
        var random = SkyRandom(seed: 15)
        let run = Run()
        // A circle of radius 0.05 of the width (32 px) around (320, 142).
        run.mask = SkyMask(excluded: [SkyMask.Circle(center: PixelPoint(x: 0.5, y: 0.5), radius: 0.05)])
        for frame in 0..<12 {
            var picture = SkyPicture(using: &random)
            if frame >= 2 {
                picture.dot(x: 330.5, y: 150.5, amplitude: 90)   // 13 px from the centre: inside
                picture.dot(x: 380.5, y: 142.5, amplitude: 90)   // 60 px away: outside
            }
            run.feed(picture)
        }
        #expect(run.detections[2...].allSatisfy { $0.count == 1 && abs($0[0].x - 380.5) < 0.5 })
    }

    @Test func theHorizonIsMaskedOnceTheAimIsGood() throws {
        // A single lens facing north and up only 5°: the picture's lower rows look below 1°.
        let model = SkyCameraModel.initial(facing: 0, tilt: 5, pictureWidth: Self.width, pictureHeight: Self.height, layout: .single)
        let low = try #require(model.direction(at: PixelPoint(x: 0.5, y: 0.8))?.direction)
        #expect(low.elevation < 0)
        var random = SkyRandom(seed: 16)
        for (limit, found) in [(Double?.none, true), (1.0, false)] {
            let run = Run()
            run.mask = SkyMask(belowElevation: limit, model: model)
            for frame in 0..<10 {
                var picture = SkyPicture(using: &random)
                if frame >= 2 { picture.dot(x: 320.5, y: 0.8 * 284, amplitude: 90) }
                run.feed(picture)
            }
            #expect(run.detections[2...].allSatisfy { $0.count == (found ? 1 : 0) })
        }
    }

    @Test func aDarkBirdCountsOnlyByDay() {
        var random = SkyRandom(seed: 17)
        for isNight in [true, false] {
            let run = Run()
            run.isNight = isNight
            for frame in 0..<12 {
                var picture = SkyPicture(sky: 180, using: &random)
                if frame >= 2 { picture.dot(x: 100.5 + 9 * Double(frame), y: 80.5, amplitude: -80) }
                run.feed(picture)
            }
            let found = run.detections[2...].flatMap { $0 }
            if isNight {
                #expect(found.isEmpty)
            } else {
                #expect(found.count == 10 && found.allSatisfy { !$0.brighter })
                _ = run.tracker.endAll()
            }
        }
    }

    @Test func aFloodOfBlobsIsNoisy() {
        var random = SkyRandom(seed: 18)
        func flood(_ count: Int) -> SkyFrameResult {
            let analyzer = SkyFrameAnalyzer(width: Self.width, height: Self.height)
            for _ in 0..<3 { _ = analyzer.process(SkyPicture(using: &random).image, mask: SkyMask(), isNight: true) }
            var picture = SkyPicture(using: &random)
            // A 20 × 15 grid of cells (32 × 18 px), a dot somewhere in each of the first `count`.
            for cell in 0..<count {
                let column = cell % 20, row = cell / 20
                picture.dot(x: 32 * Double(column) + Double.random(in: 8...24, using: &random),
                            y: 18 * Double(row) + Double.random(in: 5...13, using: &random), amplitude: 80)
            }
            return analyzer.process(picture.image, mask: SkyMask(), isNight: true)
        }
        let flooded = flood(300)
        #expect(flooded.noisy && flooded.detections.isEmpty && !flooded.globalChange)
        let busy = flood(150)
        #expect(!busy.noisy && busy.detections.count == 150)
    }

    @Test func aSlowDriftMakesNoStrayDetections() {
        // The sky brightening 0.3 levels a picture for 60 pictures (dusk, an exposure creeping up): the background, a running mean of 5 %
        // a picture, lags it by up to 5.7 levels. The threshold is about each tile's own level, so the lag passes nothing (about zero, it
        // made over a thousand detections and dozens of noisy pictures). The same when only one side brightens (a gradient across the
        // picture). An exposure step of 4 levels at once passes a little noise in its first picture only, and no track.
        let drifts: [(name: String, level: (Int, Int, Int) -> Float)] = [
            ("everywhere", { frame, _, _ in Float(max(0, min(frame, 65) - 5)) * 0.3 }),
            ("to the right", { frame, x, _ in Float(max(0, min(frame, 65) - 5)) * 0.3 * Float(x) / Float(Self.width) }),
            ("a step", { frame, _, _ in frame >= 10 ? 4 : 0 }),
        ]
        for drift in drifts {
            var random = SkyRandom(seed: 42)
            let run = Run()
            for frame in 0..<(drift.name == "a step" ? 30 : 70) {
                var picture = SkyPicture(sky: 60, using: &random)
                picture.brighten { x, y in drift.level(frame, x, y) }
                run.feed(picture)
            }
            let stray = run.detections.enumerated().filter { drift.name != "a step" || $0.offset != 10 }.flatMap(\.element).count
            #expect(stray == 0, "\(drift.name): \(stray) detections")
            #expect(run.results.allSatisfy { !$0.noisy && !$0.globalChange }, "\(drift.name)")
            #expect((run.ended + run.tracker.endAll()).isEmpty, "\(drift.name)")
        }
    }

    @Test func speckleIsNoLight() throws {
        // A camera's single-pixel speckle at night: 2 pixels in 10,000 a spike of exponential height (mean 25 levels) over sky noise of σ 3,
        // in a strip of the widest analysed picture (1920 px, where a light no noise makes looks 96 px for its second detection): about 11
        // detections a picture (6 in 100,000 pixels, the owner's camera's night rate after the smoothing), a quarter of them far over the
        // threshold, each a lone sharp pixel. A faint light (a dot of amplitude 30, about 1.6 times the threshold once smoothed) crosses among
        // it at 2 px a picture: it is one track, and the speckle makes none (taken as lights no noise makes, it made 5 to 9 in these 30 s).
        let width = 1920, height = 96
        var random = SkyRandom(seed: 41)
        let run = Run(width: width, height: height)
        var light: [(x: Double, y: Double)?] = []
        for frame in 0..<150 {
            var picture = SkyPicture(width: width, height: height, using: &random)
            picture.speckle(share: 2e-4, mean: 25, using: &random)
            let k = frame - 10
            let point = (0..<130).contains(k) ? (x: 115.5 + 2 * Double(k), y: 34.5) : nil
            if let point { picture.dot(x: point.x, y: point.y, amplitude: 30) }
            light.append(point)
            run.feed(picture)
        }
        func isLight(_ x: Double, _ y: Double, _ frame: Int) -> Bool {
            guard let point = light[frame] else { return false }
            return abs(x - point.x) < 2 && abs(y - point.y) < 2
        }
        var speckle = 0, significant = 0, sharp = 0
        var lightSharpness: [Double] = []
        for (frame, detections) in run.detections.enumerated() {
            for detection in detections {
                if isLight(detection.x, detection.y, frame) {
                    lightSharpness.append(detection.sharpness)
                    continue
                }
                speckle += 1
                if detection.significance >= SkyTracker.strongSignificance {
                    significant += 1
                    if detection.sharpness >= SkyTracker.loneSharpness { sharp += 1 }
                }
            }
        }
        // The speckle is many detections, a good share of them significant, and nearly every significant one a lone sharp pixel (a spike
        // can land beside another, or on a bump of the sky's noise); the light is not.
        #expect(speckle >= 9 * 140, "\(speckle) detections of speckle")
        #expect(significant >= 300 && sharp * 100 >= significant * 98, "\(significant) significant, \(sharp) of them sharp")
        let sharpLight = lightSharpness.filter { $0 >= SkyTracker.loneSharpness }.count
        #expect(lightSharpness.count >= 125 && sharpLight <= 2, "the light: \(lightSharpness.count) detections, \(sharpLight) sharp")
        let tracks = run.ended + run.tracker.endAll()
        let lightTracks = tracks.filter { track in
            track.samples.contains { isLight($0.point.x * Double(width), $0.point.y * Double(height), Int(($0.time / Self.interval).rounded())) }
        }
        let lightTrack = try #require(lightTracks.max { $0.samples.count < $1.samples.count })
        #expect(lightTracks.count == 1 && lightTrack.samples.count >= 125, "the light: \(lightTracks.map(\.samples.count)) samples")
        #expect(tracks.count == lightTracks.count, "the speckle made \(tracks.count - lightTracks.count) tracks")
    }

    // MARK: Following

    @Test func crossingObjectsKeepTheirIdentities() throws {
        var random = SkyRandom(seed: 19)
        let run = Run()
        let angle = -20.0, radians = angle * Double.pi / 180
        for frame in 0..<60 {
            var picture = SkyPicture(using: &random)
            if frame < 50 {
                let t = Double(frame - 25)
                picture.dot(x: 310.5 + 10 * t, y: 150.5, amplitude: 80)
                picture.dot(x: 310.5 + 10 * t * cos(radians), y: 150.5 + 10 * t * sin(radians), amplitude: 80)
            }
            run.feed(picture)
        }
        #expect(run.ended.count == 2)
        let level = try #require(run.ended.first { abs(($0.samples.first?.point.y ?? 0) * 284 - 150.5) < 2 })
        let climbing = try #require(run.ended.first { $0.id != level.id })
        // Each keeps to its own line, all the way.
        for sample in level.samples { #expect(Self.offLine(sample, origin: (310.5, 150.5), angle: 0) < 2.5) }
        for sample in climbing.samples { #expect(Self.offLine(sample, origin: (310.5, 150.5), angle: angle) < 2.5) }
        for track in [level, climbing] {
            #expect(track.samples.count >= 44)
            let measures = TrackMeasurer.measure(track, model: Self.singleLens, analysisWidth: Self.width, pictureWidth: Self.width)
            #expect(measures.shape == .straight, "maxTurn \(measures.maxTurn)°, straightness \(measures.straightness)")
        }
    }

    @Test func aBlinkingLightIsOneTrack() throws {
        var random = SkyRandom(seed: 20)
        let run = Run()
        for frame in 0..<75 {
            var picture = SkyPicture(using: &random)
            let k = frame - 5
            if (0..<60).contains(k) && k % 5 != 4 { picture.dot(x: 80.5 + 3 * Double(k), y: 100.5, amplitude: 70) }
            run.feed(picture)
        }
        #expect(run.ended.count == 1)
        let track = try #require(run.ended.first)
        #expect(track.samples.count == 48)
        #expect(track.misses.count == 11)
        let measures = TrackMeasurer.measure(track, model: Self.singleLens, analysisWidth: Self.width, pictureWidth: Self.width)
        #expect(measures.blinks)
        let rate = try #require(measures.blinkRate)
        #expect(abs(rate - 1.0) <= 0.15, "blinks \(rate) Hz")
    }

    @Test func aSuddenStopAndASharpTurnAreFollowed() throws {
        var random = SkyRandom(seed: 21)
        // A dot at 10 px a picture that stops dead and stays: one track, which ends in a sudden stop.
        let stop = Run()
        for frame in 0..<50 {
            var picture = SkyPicture(using: &random)
            let k = frame - 5
            if (0..<35).contains(k) { picture.dot(x: 100.5 + 10 * Double(min(k, 20)), y: 120.5, amplitude: 80) }
            stop.feed(picture)
        }
        #expect(stop.ended.count == 1)
        let stopped = try #require(stop.ended.first)
        #expect(stopped.samples.count == 35)
        let stopMeasures = TrackMeasurer.measure(stopped, model: Self.singleLens, analysisWidth: Self.width, pictureWidth: Self.width)
        #expect(stopMeasures.shape == .suddenStop)
        // A dot that turns 90° at once: one track, a sharp turn.
        let turn = Run()
        for frame in 0..<50 {
            var picture = SkyPicture(using: &random)
            let k = frame - 5
            if (0..<36).contains(k) {
                let x = k <= 18 ? 100.5 + 10 * Double(k) : 280.5
                let y = k <= 18 ? 60.5 : 60.5 + 10 * Double(k - 18)
                picture.dot(x: x, y: y, amplitude: 80)
            }
            turn.feed(picture)
        }
        #expect(turn.ended.count == 1)
        let turned = try #require(turn.ended.first)
        #expect(turned.samples.count == 36)
        let turnMeasures = TrackMeasurer.measure(turned, model: Self.singleLens, analysisWidth: Self.width, pictureWidth: Self.width)
        #expect(turnMeasures.shape == .sharpTurn, "maxTurn \(turnMeasures.maxTurn)°")
    }

    @Test func twoAlignedStreaksStartAMeteor() throws {
        var random = SkyRandom(seed: 22)
        // Two 1×9 streaks 120 px apart along their axis, in consecutive pictures: one meteor.
        let meteor = Run()
        for frame in 0..<25 {
            var picture = SkyPicture(using: &random)
            if frame == 10 { picture.streak(x: 200, y: 100, length: 9, amplitude: 80) }
            if frame == 11 { picture.streak(x: 320, y: 100, length: 9, amplitude: 80) }
            meteor.feed(picture)
        }
        let streak = try #require(meteor.detections[10].first)
        #expect(streak.elongation >= 3 && (streak.orientation < 10 || streak.orientation > 170))
        #expect(meteor.ended.count == 1)
        let track = try #require(meteor.ended.first)
        #expect(track.streakBorn && track.samples.count == 2)
        // Diagonal streaks along their path too.
        let diagonal = Run()
        for frame in 0..<25 {
            var picture = SkyPicture(using: &random)
            if frame == 10 { picture.streak(x: 100, y: 60, length: 11, angle: 30, amplitude: 90) }
            if frame == 11 { picture.streak(x: 100 + 90 * cos(Double.pi / 6), y: 60 + 90 * sin(Double.pi / 6), length: 11, angle: 30, amplitude: 90) }
            diagonal.feed(picture)
        }
        #expect(diagonal.ended.count == 1 && diagonal.ended.first?.streakBorn == true)
        // Streaks side by side (moved across their axis), or one alone, are no meteor.
        for second in [(x: 200.0, y: 160.0), nil] {
            let run = Run()
            for frame in 0..<25 {
                var picture = SkyPicture(using: &random)
                if frame == 10 { picture.streak(x: 200, y: 100, length: 9, amplitude: 80) }
                if frame == 11, let second { picture.streak(x: second.x, y: second.y, length: 9, amplitude: 80) }
                run.feed(picture)
            }
            #expect(run.ended.isEmpty)
        }
    }

    // MARK: The tracker's rules, on detections given directly

    /// A round detection at (x, y) of the analysed picture (`elongation` and the fixed rises, nothing fixed under it, as given).
    static func detection(_ x: Double, _ y: Double, lens: Int = 0, flux: Double = 400, significance: Double = 5, sharpness: Double = 0.6,
                          inSeamBand: Bool = false, elongation: Double = 1, fixedRise: Double = 0, fixedRiseUnder: Double = 0) -> SkyDetection {
        SkyDetection(x: x, y: y, area: 9, flux: flux, peak: 60, elongation: elongation, orientation: 0, sharpness: sharpness, brighter: true, lens: lens,
                     inSeamBand: inSeamBand, significance: significance, fixedRise: fixedRise, fixedRiseUnder: fixedRiseUnder)
    }

    /// Feeds `pictures` (each picture's detections) to `tracker` five a second from `start`; returns what ended, then what was open.
    static func follow(_ tracker: SkyTracker, _ pictures: [[SkyDetection]], start: Int = 0) -> [SkyTrack] {
        var ended: [SkyTrack] = []
        for (index, detections) in pictures.enumerated() {
            let time = Double(start + index) * interval
            ended += tracker.update(detections, at: time, wallClock: SkyFixtures.aimEpoch.addingTimeInterval(time))
        }
        return ended
    }

    /// As `follow`, then ends what is open: the tracks kept, and the tracks dropped, apart.
    static func followToTheEnd(_ tracker: SkyTracker, _ pictures: [[SkyDetection]]) -> (kept: [SkyTrack], dropped: [SkyDroppedTrack]) {
        var kept: [SkyTrack] = [], dropped: [SkyDroppedTrack] = []
        for (index, detections) in pictures.enumerated() {
            let time = Double(index) * interval
            kept += tracker.update(detections, at: time, wallClock: SkyFixtures.aimEpoch.addingTimeInterval(time), dropped: &dropped)
        }
        kept += tracker.endAll(dropped: &dropped)
        return (kept, dropped)
    }

    @Test func aTrackIsBornAfterThreeAndCoastsAShortGap() {
        // Two detections are not a track; three are, but one that ends within 0.6 s is dropped.
        let two = SkyTracker(width: Self.width, height: Self.height)
        #expect(Self.follow(two, [[Self.detection(100, 100)], [Self.detection(110, 100)]]).isEmpty)
        #expect(two.activeCount == 0)
        #expect(Self.follow(two, Array(repeating: [], count: 9), start: 2).isEmpty)
        #expect(two.activeCount == 0)
        let three = SkyTracker(width: Self.width, height: Self.height)
        _ = Self.follow(three, [[Self.detection(100, 100)], [Self.detection(110, 100)]])
        #expect(three.activeCount == 0)
        _ = Self.follow(three, [[Self.detection(120, 100)]], start: 2)
        #expect(three.activeCount == 1)
        #expect(Self.follow(three, Array(repeating: [], count: 9), start: 3).isEmpty)
        #expect(three.activeCount == 0)
        // A third detection outside the gate (6 px from where the first two point) starts nothing either.
        let astray = SkyTracker(width: Self.width, height: Self.height)
        _ = Self.follow(astray, [[Self.detection(100, 100)], [Self.detection(110, 100)], [Self.detection(120, 107)]])
        #expect(astray.activeCount == 0)
        // Detections up to 1.5 s apart are one track (6 pictures missed: 1.4 s); 1.8 s apart (8 missed) are two.
        func gap(_ pictures: Int) -> [SkyTrack] {
            let tracker = SkyTracker(width: Self.width, height: Self.height)
            var frames: [[SkyDetection]] = []
            for k in 0..<30 { frames.append(k >= 10 && k < 10 + pictures ? [] : [Self.detection(50 + 5 * Double(k), 200)]) }
            frames += Array(repeating: [], count: 10)
            return Self.follow(tracker, frames)
        }
        #expect(gap(6).count == 1)
        #expect(gap(8).count == 2)
        // A slow light (1 px a picture) whose detection wanders 4.5 px once (a centroid pulled by a star it passes) is within the 6 px
        // floor of its gate: all 20 pictures are its samples.
        let slow = SkyTracker(width: Self.width, height: Self.height)
        let wandering = (0..<20).map { k in [Self.detection(100 + Double(k), k == 10 ? 104.5 : 100)] } + Array(repeating: [], count: 10)
        let slowTracks = Self.follow(slow, wandering)
        #expect(slowTracks.count == 1 && slowTracks.first?.samples.count == 20)
    }

    @Test func thePredictionIsAlphaBeta() throws {
        // A light at 10 px a picture along a row: born from its first three (velocity 50 px/s, from the first to the third), then one
        // detection 5 px off its row. The filter takes 0.85 of the miss into its position and 0.005 of it over the 0.2 s into its velocity.
        let tracker = SkyTracker(width: Self.width, height: Self.height)
        var pictures: [[SkyDetection]] = (0..<10).map { [Self.detection(100 + 10 * Double($0), 100)] }
        pictures.append([Self.detection(200, 105)])
        _ = Self.follow(tracker, pictures)
        let filter = try #require(tracker.filters.first)
        #expect(tracker.filters.count == 1)
        #expect(abs(filter.x - 200) < 1e-9 && abs(filter.vx - 50) < 1e-9)
        #expect(abs(filter.y - (100 + 0.85 * 5)) < 1e-9, "y \(filter.y)")
        #expect(abs(filter.vy - 0.005 / 0.2 * 5) < 1e-9, "vy \(filter.vy)")
    }

    @Test func noiseMakesNoTracksButALightAmongItIsFollowed() {
        var random = SkyRandom(seed: 23)
        // The widest analysed picture, 1920×852.
        let tracker = SkyTracker(width: 1920, height: 852)
        var pictures: [[SkyDetection]] = []
        for k in 0..<100 {
            // 100 faint detections at random places in every picture (noise just over the threshold), and one bright light.
            var detections = (0..<100).map { _ in
                Self.detection(Double.random(in: 0..<1920, using: &random), Double.random(in: 0..<852, using: &random), flux: 30, significance: 1.1)
            }
            detections.append(Self.detection(60 + 5 * Double(k), 40 + 2 * Double(k)))
            detections.shuffle(using: &random)
            pictures.append(detections)
        }
        let ended = Self.follow(tracker, pictures) + tracker.endAll()
        #expect(ended.count == 1)
        #expect((ended.first?.samples.count ?? 0) >= 95)
    }

    @Test func onlyALightNoNoiseMakesTurnsATrack() {
        // A light seen for 10 pictures at 5 px a picture along a row, then a detection 7 px from where it was last seen, at right angles:
        // outside its 6 px gate, within a step and a gate. A bright one continues the track (it turned); a faint one (under 2) could be noise
        // and does not, and the track ends as it was; nor does a bright one that is a lone sharp pixel (sensor speckle can be far over the
        // threshold).
        for (significance, sharpness, turned) in [(5.0, 0.6, true), (1.6, 0.6, false), (5.0, 0.95, false)] {
            let tracker = SkyTracker(width: Self.width, height: Self.height)
            var pictures: [[SkyDetection]] = (0..<10).map {
                [Self.detection(100 + 5 * Double($0), 100, flux: 30, significance: significance, sharpness: sharpness)]
            }
            pictures.append([Self.detection(145, 107, flux: 30, significance: significance, sharpness: sharpness)])
            pictures += Array(repeating: [], count: 10)
            let ended = Self.follow(tracker, pictures)
            #expect(ended.count == 1)
            #expect(ended.first?.samples.count == (turned ? 11 : 10), "significance \(significance), sharpness \(sharpness)")
        }
    }

    @Test func aLonePixelIsNoStrongLight() {
        // A light 30 px a picture: within the reach of a light no noise makes (5 % of the width, 32 px), beyond a faint one's in a picture
        // with nothing else (where a chance partner turns up once in a hundred: 24 px). A significant detection that is a lone sharp pixel
        // (sensor speckle) pairs only as a faint one.
        for (sharpness, followed) in [(0.6, true), (0.95, false)] {
            let tracker = SkyTracker(width: Self.width, height: Self.height)
            let pictures = (0..<8).map { [Self.detection(100 + 30 * Double($0), 100, sharpness: sharpness)] } + Array(repeating: [], count: 10)
            #expect(Self.follow(tracker, pictures).count == (followed ? 1 : 0), "sharpness \(sharpness)")
        }
        // A track's third detection is about as bright as its first two (a third to three times them), as a turn's is.
        for (flux, born) in [(1_000.0, true), (1_300, false), (150, true), (120, false)] {
            let tracker = SkyTracker(width: Self.width, height: Self.height)
            _ = Self.follow(tracker, [[Self.detection(100, 100)], [Self.detection(110, 100)], [Self.detection(120, 100, flux: flux)]])
            #expect(tracker.activeCount == (born ? 1 : 0), "a third of flux \(flux) after two of 400")
        }
    }

    /// A normal deviate (seeded), for a detection's wander.
    static func gauss(_ random: inout SkyRandom) -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1, using: &random), u2 = Double.random(in: 0..<1, using: &random)
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }

    @Test func aTwinklingStarIsNoTrack() {
        // A star (or a flickering spot) that stays put: its detection wanders half a pixel each way and its brightness twinkles, picture after
        // picture, for half a minute. Its first and last points are under 4 px apart, so it is no track, however long it lasted; with the aim
        // good or rough.
        for aim in [SkyAimQuality.rough, .good] {
            var random = SkyRandom(seed: 44)
            let tracker = SkyTracker(width: 1920, height: 852)
            tracker.model = SkyFixtures.truthDual
            tracker.aimQuality = aim
            let pictures: [[SkyDetection]] = (0..<150).map { _ in
                [Self.detection(500.5 + 0.5 * Self.gauss(&random), 300.5 + 0.5 * Self.gauss(&random), flux: Double.random(in: 60...400, using: &random),
                                significance: Double.random(in: 1.2...4, using: &random))]
            }
            #expect((Self.follow(tracker, pictures) + tracker.endAll()).isEmpty, "aim \(aim)")
        }
    }

    @Test func aNarrowLensJudgesTheMoveOnTheSky() {
        // Through a lens 20° across 1920 px (0.0104° a pixel), a light that creeps 4.5 px (0.047°) moved 4 px but not 0.05°: once the aim is
        // good the sky decides, and it is no track; with the aim rough the pixels alone decide, and it is (3.5 px is not). 6 px (0.062°) is
        // a track either way. The same going out that far and back to where it began: its farthest sample decides, on the sky too.
        let narrow = SkyCameraModel(layout: .single, seam: SkyCameraModel.defaultSeam, lenses: [
            SkyCameraModel.Lens(yaw: 0, pitch: 30, roll: 0, horizontalFOV: 20, verticalFOV: SkyCameraModel.Lens.verticalFOV(horizontalFOV: 20, frameAspect: 1920.0 / 852),
                                principalPoint: PixelPoint(x: 0.5, y: 0.5), radial: []),
        ])
        let paths: [(name: String, pictures: Int, share: (Int) -> Double)] = [
            ("creeping", 20, { Double($0) / 19 }),
            ("out and back", 21, { 1 - abs(Double($0) - 10) / 10 }),
        ]
        for (moved, aim, kept) in [(4.5, SkyAimQuality.good, false), (4.5, .rough, true), (3.5, .rough, false), (6.0, .good, true)] {
            for path in paths {
                let tracker = SkyTracker(width: 1920, height: 852)
                tracker.model = narrow
                tracker.aimQuality = aim
                let pictures = (0..<path.pictures).map { k in [Self.detection(960 + moved * path.share(k), 400)] }
                #expect((Self.follow(tracker, pictures) + tracker.endAll()).count == (kept ? 1 : 0), "\(path.name) \(moved) px, aim \(aim)")
            }
        }
    }

    @Test func aSlowSatelliteIsKept() throws {
        // A satellite crossing at 0.3°/s for 20 s, seen through the truth dual camera analysed 1920 wide (about 3 px a second), faint
        // (significance 1.6 to 2.2), its detection wandering 0.3 px: one track of all its pictures, kept (it moved 6°, some 60 px).
        let model = SkyFixtures.truthDual
        let path = SkyPath(start: SkyDirection(azimuth: 300, elevation: 30), bearing: Double.pi / 2, legs: [SkyPath.Leg(duration: 20, speed: 0.3)])
        for aim in [SkyAimQuality.rough, .good] {
            var random = SkyRandom(seed: 45)
            var pictures: [[SkyDetection]] = []
            for item in path.directions() {
                let hit = try #require(model.project(item.direction).first)
                pictures.append([Self.detection(hit.point.x * 1920 + 0.3 * Self.gauss(&random), hit.point.y * 852 + 0.3 * Self.gauss(&random),
                                                lens: hit.lens, flux: 80, significance: Double.random(in: 1.6...2.2, using: &random))])
            }
            let tracker = SkyTracker(width: 1920, height: 852)
            tracker.model = model
            tracker.aimQuality = aim
            let tracks = Self.follow(tracker, pictures) + tracker.endAll()
            #expect(tracks.count == 1 && tracks.first?.samples.count == pictures.count, "aim \(aim): \(tracks.map(\.samples.count))")
        }
    }

    @Test func aLightThatStopsAndHoversIsKept() {
        // A light moving 4 px a picture for 10 pictures (40 px) that then stops and hovers 5 s, wandering 0.3 px: one track of every picture,
        // kept (its first and last points are 40 px apart).
        var random = SkyRandom(seed: 46)
        let tracker = SkyTracker(width: Self.width, height: Self.height)
        let pictures: [[SkyDetection]] = (0..<36).map { k in
            let wander = k > 10 ? (x: 0.3 * Self.gauss(&random), y: 0.3 * Self.gauss(&random)) : (x: 0, y: 0)
            return [Self.detection(100 + 4 * Double(min(k, 10)) + wander.x, 120 + wander.y)]
        }
        let tracks = Self.follow(tracker, pictures) + tracker.endAll()
        #expect(tracks.count == 1 && tracks.first?.samples.count == 36, "\(tracks.map(\.samples.count))")
    }

    @Test func aLightThatGoesOutAndBackIsKept() {
        // The farthest sample from the first decides whether a track moved, not the last. A light that goes out 40 px and comes back to where
        // it began (4 px a picture, turning at once), and one that makes a lap round a circle 40 px across, each end where they began, 0 px
        // from their first point, but went 40 px from it: each is one track of every picture, kept (the chord alone dropped both). With the aim
        // rough (the pixels decide) and good (the sky decides too).
        let lap: [(x: Double, y: Double)] = (0...36).map { k in
            let angle = Double(k) * 10 * Double.pi / 180
            return (x: 200 - 20 * cos(angle), y: 120 - 20 * sin(angle))
        }
        let outAndBack: [(x: Double, y: Double)] = (0...20).map { k in (x: 100 + 4 * Double(min(k, 20 - k)), y: 120) }
        for (name, path) in [("out and back", outAndBack), ("a lap", lap)] {
            for aim in [SkyAimQuality.rough, .good] {
                let tracker = SkyTracker(width: Self.width, height: Self.height)
                tracker.model = Self.singleLens
                tracker.aimQuality = aim
                let tracks = Self.follow(tracker, path.map { [Self.detection($0.x, $0.y)] }) + tracker.endAll()
                #expect(tracks.count == 1 && tracks.first?.samples.count == path.count, "\(name), aim \(aim): \(tracks.map(\.samples.count)) samples")
            }
        }
    }

    @Test func anAllFaintTrackIsDropped() {
        // A light moving 5 px a picture whose every detection is faint (significance under 1.5) may be noise lined up by chance: no track.
        // One detection of 1.5 keeps it.
        for (strongest, kept) in [(1.45, false), (1.5, true)] {
            let tracker = SkyTracker(width: Self.width, height: Self.height)
            let pictures = (0..<20).map { k in [Self.detection(100 + 5 * Double(k), 100, significance: k == 12 ? strongest : 1.2)] }
            #expect((Self.follow(tracker, pictures) + tracker.endAll()).count == (kept ? 1 : 0), "strongest \(strongest)")
        }
    }

    @Test func aRepeatedPictureTimeIsIgnored() {
        // The same picture time twice (a picture handed over again): the second is ignored, and what was open stays open.
        let tracker = SkyTracker(width: Self.width, height: Self.height)
        let light = { (k: Int) in [Self.detection(100 + 5 * Double(k), 100)] }
        var ended = Self.follow(tracker, (0..<10).map(light))
        #expect(ended.isEmpty && tracker.activeCount == 1)
        ended += tracker.update(light(9), at: 9 * Self.interval, wallClock: SkyFixtures.aimEpoch.addingTimeInterval(9 * Self.interval))
        #expect(ended.isEmpty && tracker.activeCount == 1)
        ended += Self.follow(tracker, (10..<20).map(light) + Array(repeating: [], count: 10), start: 10)
        #expect(ended.count == 1 && ended.first?.samples.count == 20)
        // A time that goes back (the stream's clock started again) ends what was open.
        let restarted = SkyTracker(width: Self.width, height: Self.height)
        _ = Self.follow(restarted, (0..<10).map(light))
        let over = restarted.update([], at: 0.5, wallClock: SkyFixtures.aimEpoch)
        #expect(over.count == 1 && over.first?.samples.count == 10 && restarted.activeCount == 0)
    }

    @Test func aLostFaintLightDoesNotWanderIntoNoise() {
        var random = SkyRandom(seed: 28)
        let tracker = SkyTracker(width: 1920, height: 852)
        // Twenty faint lights in turn (significance 1.6: under a strong light's 2, over an all-faint track's 1.5), each seen for 10 pictures
        // and then gone, among 30 faint noise detections a picture. A light's track
        // may take a stray detection in its own gate, which the pinned rules allow (rarely), or start on a noise detection that its second
        // was nearer to; it never wanders off after noise.
        var pictures: [[SkyDetection]] = []
        var lights: [(x: Double, y: Double)] = []
        for light in 0..<20 {
            let start = (x: 100 + 80 * Double(light % 20), y: 100 + 30 * Double(light % 5))
            lights.append(start)
            for k in 0..<20 {
                var detections = (0..<30).map { _ in
                    Self.detection(Double.random(in: 1..<1919, using: &random), Double.random(in: 1..<851, using: &random), flux: 30, significance: 1.1)
                }
                if k < 10 { detections.append(Self.detection(start.x + 5 * Double(k), start.y, flux: 30, significance: 1.6)) }
                pictures.append(detections)
            }
        }
        let ended = Self.follow(tracker, pictures) + tracker.endAll()
        var strays = 0
        for (index, light) in lights.enumerated() {
            func isOwn(_ sample: SkyTrackSample) -> Bool {
                (0..<10).contains { abs(sample.point.x * 1920 - (light.x + 5 * Double($0))) < 0.5 } && abs(sample.point.y * 852 - light.y) < 0.5
            }
            guard let track = ended.first(where: { $0.samples.filter(isOwn).count >= 8 }) else {
                Issue.record("light \(index) was not followed")
                continue
            }
            strays += track.samples.count - track.samples.filter(isOwn).count
        }
        #expect(strays <= 3, "the lights' tracks took \(strays) stray detections")
    }

    @Test func atMostFiftyTracksAreOpen() {
        let tracker = SkyTracker(width: Self.width, height: Self.height)
        var pictures: [[SkyDetection]] = []
        for k in 0..<6 {
            let row: [SkyDetection] = (0..<60).map { index in
                let x: Double = 20 + 10 * Double(index % 30) + 2 * Double(k)
                let y: Double = 20 + 120 * Double(index / 30)
                return Self.detection(x, y)
            }
            pictures.append(row)
        }
        _ = Self.follow(tracker, pictures)
        #expect(tracker.activeCount == 50)
        #expect(tracker.endAll().count == 50)
        #expect(tracker.activeCount == 0)
    }

    @Test func aLongTrackIsSplitAtTenMinutes() {
        let tracker = SkyTracker(width: Self.width, height: Self.height)
        // A slow light (0.1 px a picture) watched for 11 minutes.
        var ended: [SkyTrack] = []
        for k in 0..<3_300 {
            let time = Double(k) * Self.interval
            ended += tracker.update([Self.detection(50 + 0.1 * Double(k), 100)], at: time, wallClock: SkyFixtures.aimEpoch.addingTimeInterval(time))
        }
        ended += tracker.endAll()
        #expect(ended.count == 2)
        let first = ended.first?.samples ?? []
        #expect(abs(((first.last?.time ?? 0) - (first.first?.time ?? 0)) - 600) <= 0.2 + 1e-9)
        #expect(ended.map(\.samples.count).reduce(0, +) == 3_300)
        // A light that stays put for the 11 minutes (it wanders 0.2 px) is split too: neither piece is kept, and both are handed over as
        // barely moved, the first of 600 s.
        let still = SkyTracker(width: Self.width, height: Self.height)
        var kept: [SkyTrack] = [], dropped: [SkyDroppedTrack] = []
        for k in 0..<3_300 {
            let time = Double(k) * Self.interval
            kept += still.update([Self.detection(300 + (k % 2 == 0 ? 0.2 : -0.2), 150)], at: time,
                                 wallClock: SkyFixtures.aimEpoch.addingTimeInterval(time), dropped: &dropped)
        }
        kept += still.endAll(dropped: &dropped)
        #expect(kept.isEmpty && dropped.map(\.reason) == [.barelyMoved, .barelyMoved], "\(kept.count) kept, \(dropped.map(\.reason)) dropped")
        #expect(dropped.map(\.track.samples.count).reduce(0, +) == 3_300 && Set(dropped.map(\.track.id)).count == 2)
        let piece = dropped.first?.track.samples ?? []
        #expect(abs(((piece.last?.time ?? 0) - (piece.first?.time ?? 0)) - 600) <= 0.2 + 1e-9)
    }

    // MARK: Fixed things in the sky

    /// The kept tracks of a run, and whether `point` of picture `frame` is one of them.
    static func keptSamples(_ tracks: [SkyTrack], width: Int, height: Int, near point: (Int) -> (x: Double, y: Double)?) -> Int {
        tracks.flatMap(\.samples).filter { sample in
            guard let at = point(Int((sample.time / interval).rounded())) else { return false }
            return abs(sample.point.x * Double(width) - at.x) < 2 && abs(sample.point.y * Double(height) - at.y) < 2
        }.count
    }

    @Test func slowLightsAreKeptAcrossAStar() {
        // Through a lens of 0.1° a pixel (the box's 1920-px analysis of a 180° camera), a light at 0.05°/s (0.1 px a picture) and one at
        // 0.3°/s (0.6 px a picture) cross a twinkling star that was in the sky all along. The slow background (τ about 1,000 pictures) holds
        // the star, not them: a light leaves each pixel long before it could build in. Each light is followed (kept tracks hold most of its
        // pictures); its samples by the star stand by something fixed, the rest are clear of it.
        for (step, pictures) in [(0.1, 1_000), (0.6, 200)] {
            var random = SkyRandom(seed: 47)
            let run = Run(width: 160, height: 64)
            var light: [(x: Double, y: Double)?] = []
            for frame in 0..<(pictures + 12) {
                var picture = SkyPicture(width: 160, height: 64, using: &random)
                picture.dot(x: 80.5, y: 32.5, amplitude: 120 * Float.random(in: 0.7...1.3, using: &random))
                let k = frame - 2
                let at = (0..<pictures).contains(k) ? (x: 20.3 + step * Double(k), y: 32.5) : nil
                if let at { picture.dot(x: at.x, y: at.y, amplitude: 100) }
                light.append(at)
                run.feed(picture)
            }
            let tracks = run.ended + run.tracker.endAll()
            let followed = Self.keptSamples(tracks, width: 160, height: 64) { light[$0] }
            #expect(followed >= pictures * 8 / 10, "\(step) px a picture: \(followed) of \(pictures) pictures in kept tracks")
            let samples = tracks.flatMap(\.samples)
            #expect(samples.contains { $0.fixedRise >= 6 } && samples.contains { $0.fixedRise < 5 }, "\(step) px a picture")
            for sample in samples where sample.fixedRise >= 5 {
                #expect(abs(sample.point.x * 160 - 80.5) <= 12, "by something fixed at \(sample.point.x * 160), away from the star")
            }
        }
    }

    @Test func aSlowSaturatingLightIsKeptWhereItsOwnTrailStands() {
        // A light bright enough to saturate its pixels, crossing at 0.03°/s through a lens of 0.1° a pixel (0.06 px a picture): it dwells
        // about 50 pictures on a pixel, and the slow background takes in 5 to 9 levels there, over the 5σ of its floor of 1 level. A dip of
        // 2.4 s ends its track; the next piece's every detection then stands within 10 px of the first piece's trail, and it is slower than
        // the stationary 0.05°/s, so crossing 12 px does not exempt it. Only the quarter-peak test keeps it clear: the spot must stand a quarter
        // as high as the detection does over the fast background (5 to 9 levels against about 100). Both pieces are kept; without the
        // test the second read over 5σ all along and was dropped as fixed.
        let width = 64, height = 64, preroll = 700, piece = 200, dip = 11, step = 0.06
        var random = SkyRandom(seed: 53)
        let run = Run(width: width, height: height)
        for frame in 0..<(preroll + 2 * piece + dip + 12) {
            var picture = SkyPicture(width: width, height: height, using: &random)
            let k = frame - preroll
            if (0..<piece).contains(k) || (piece + dip..<(2 * piece + dip)).contains(k) {
                picture.dot(x: 18.3 + step * Double(k), y: 32.5, amplitude: 400)
            }
            run.feed(picture)
        }
        let tracks = run.finish()
        // The premise: under most of its path the slow background stands 5 or more levels over the sky (30).
        let slow = run.analyzer.slowBackground
        let built = (22...40).map { Int(slow.pixels[32 * width + $0]) - 30 }.sorted()
        #expect(built[built.count / 2] >= 5, "the slow background stands \(built) levels over the sky under the light's path")
        #expect(tracks.count == 2 && tracks.allSatisfy { $0.samples.count >= piece - 5 }, "\(tracks.map(\.samples.count)) samples")
        #expect(tracks.flatMap(\.samples).allSatisfy { $0.fixedRise < SkyTracker.fixedSigmas })
    }

    @Test func aFixedPointThatPicksUpNoiseIsDropped() throws {
        // A bright star twinkling hard (seen in about half the pictures), and faint noise blobs that come and go 4 to 10 px from it (a quarter
        // of the pictures), which its track picks up: its points wander, and it ends on a blob 8 px away, so its first and last points are far
        // enough apart to pass as a move. Its detections are on the star or beside it, never clear of it: no track.
        var random = SkyRandom(seed: 48)
        let run = Run(width: 160, height: 64)
        let star = (x: 80.5, y: 32.5)
        for frame in 0..<160 {
            var picture = SkyPicture(width: 160, height: 64, using: &random)
            let last = frame == 150
            picture.dot(x: star.x, y: star.y, amplitude: last ? 150 : 150 * Float.random(in: 0.5...1.8, using: &random))
            if last {
                picture.dot(x: star.x + 8, y: star.y + 1, amplitude: 45)
            } else if frame < 150 && Double.random(in: 0..<1, using: &random) < 0.25 {
                let distance = Double.random(in: 4...10, using: &random), angle = Double.random(in: 0..<(2 * Double.pi), using: &random)
                picture.dot(x: star.x + distance * cos(angle), y: star.y + distance * sin(angle), amplitude: Float.random(in: 30...45, using: &random))
            }
            run.feed(picture)
        }
        let detections = run.detections.flatMap { $0 }
        #expect(detections.count >= 80)
        #expect(detections.allSatisfy { hypot($0.x - star.x, $0.y - star.y) <= 12 && $0.fixedRise >= 6 })
        // The star's own track wanders onto the blobs and ends on one 8 px away.
        #expect(detections.filter { hypot($0.x - star.x, $0.y - star.y) >= 4 }.count >= 20)
        let blob = try #require(run.detections[150].first)
        #expect(abs(blob.x - star.x - 8) < 1.5)
        #expect(run.finish().isEmpty)
        // It moved enough to pass as a track, so it is dropped as fixed, not as barely moved, and handed over so.
        #expect(!run.dropped.isEmpty && run.dropped.allSatisfy { $0.reason == .fixed }, "\(run.dropped.map(\.reason))")
    }

    @Test func aFlickeringWireIsDropped() {
        // A wire across the sky (a line one pixel thick, 40 levels over it), along whose middle two short stretches brighten at random each
        // picture: chance chains along the wire make tracks that move a few pixels along it. Every detection sits on the wire, which the
        // slow background holds: no track.
        var random = SkyRandom(seed: 49)
        let run = Run(width: 160, height: 64)
        let angle = 17.0, radians = angle * Double.pi / 180
        for _ in 0..<200 {
            var picture = SkyPicture(width: 160, height: 64, using: &random)
            picture.streak(x: 4, y: 10, length: 152, angle: angle, amplitude: 40)
            for _ in 0..<2 {
                let along = Double.random(in: 50...100, using: &random)
                picture.dot(x: 4 + along * cos(radians), y: 10.5 + along * sin(radians), amplitude: Float.random(in: 40...60, using: &random))
            }
            run.feed(picture)
        }
        #expect(run.detections.flatMap { $0 }.count >= 150)
        #expect(run.finish().isEmpty)
        #expect(run.dropped.count >= 10 && run.dropped.allSatisfy { $0.reason == .fixed }, "\(run.dropped.map(\.reason))")
    }

    @Test func aLightAlongAWireIsKeptButItsFlickerIsNot() throws {
        // A fainter wire (13 levels, over 5σ of its tile's slow background). Flicker on it, which can travel along it, sits right on it and
        // makes no track; a faint light flying along it 5 px to one side (as one did past the owner's power lines) is beside it all the way,
        // never on it, and travels: it is kept.
        let angle = 10.0, radians = angle * Double.pi / 180
        func wire(_ x: Double) -> Double { 20.5 + (x - 4) * tan(radians) }
        for flicker in [true, false] {
            var random = SkyRandom(seed: 51)
            let run = Run(width: 160, height: 64)
            var light: [(x: Double, y: Double)?] = []
            for frame in 0..<300 {
                var picture = SkyPicture(width: 160, height: 64, using: &random)
                picture.streak(x: 4, y: 20, length: 152, angle: angle, amplitude: 13)
                let k = frame - 250
                var at: (x: Double, y: Double)?
                if flicker {
                    for _ in 0..<2 where frame >= 250 {
                        let x = Double.random(in: 50...110, using: &random)
                        picture.dot(x: x, y: wire(x), amplitude: Float.random(in: 30...40, using: &random))
                    }
                } else if (0..<40).contains(k) {
                    let x = 20.5 + 3 * Double(k)
                    at = (x: x, y: wire(x) + 5)
                    picture.dot(x: x, y: wire(x) + 5, amplitude: 35)
                }
                light.append(at)
                run.feed(picture)
            }
            let found = run.detections[250...].flatMap { $0 }
            #expect(found.count >= 40, "flicker \(flicker): \(found.count) detections")
            #expect(found.allSatisfy { $0.fixedRise >= SkyTracker.fixedSigmas }, "flicker \(flicker): \(found.map(\.fixedRise).sorted().prefix(3))…")
            let tracks = run.finish()
            if flicker {
                #expect(found.filter { $0.fixedRiseUnder >= SkyTracker.fixedSigmas }.count * 2 >= found.count)
                #expect(tracks.isEmpty, "\(tracks.map(\.samples.count))")
                #expect(!run.dropped.isEmpty && run.dropped.allSatisfy { $0.reason == .fixed }, "\(run.dropped.map(\.reason))")
            } else {
                #expect(found.allSatisfy { $0.fixedRiseUnder < SkyTracker.fixedSigmas })
                #expect(Self.keptSamples(tracks, width: 160, height: 64) { light[$0] } >= 36, "\(tracks.map(\.samples.count))")
                #expect(run.dropped.isEmpty, "\(run.dropped.map(\.reason))")
            }
        }
    }

    @Test func aPlanePassingAStarIsKept() throws {
        // A plane at 3 px a picture flying right over a bright star: its detections by the star sit on the star's spot, the others do not, so
        // its track is kept.
        var random = SkyRandom(seed: 50)
        let run = Run(width: 160, height: 64)
        for frame in 0..<60 {
            var picture = SkyPicture(width: 160, height: 64, using: &random)
            picture.dot(x: 80.5, y: 32.5, amplitude: 120)
            let k = frame - 2
            if (0..<47).contains(k) { picture.dot(x: 10.3 + 3 * Double(k), y: 32.5, amplitude: 80) }
            run.feed(picture)
        }
        let tracks = run.finish()
        let plane = try #require(tracks.first)
        #expect(tracks.count == 1 && plane.samples.count >= 44, "\(tracks.map(\.samples.count))")
        #expect(run.dropped.isEmpty, "\(run.dropped.map(\.reason))")
        let byStar = plane.samples.filter { $0.fixedRise >= 6 }.count
        #expect(byStar >= 3 && byStar <= 12, "\(byStar) of \(plane.samples.count) samples by the star")
    }

    // MARK: What the tracker drops, and why

    @Test func aLightThatStaysPutIsDroppedAsBarelyMoved() throws {
        // A light that stays put for 12 s (its detection wanders half a pixel) is no kept track, but the tracker hands it over as dropped, with
        // all its samples and its reason: a stationary point for Task 10. So is a flash: two streaks 2 px apart along their own path (streak-born,
        // 2 samples). With the aim rough or good.
        for aim in [SkyAimQuality.rough, .good] {
            var random = SkyRandom(seed: 54)
            let tracker = SkyTracker(width: Self.width, height: Self.height)
            tracker.model = Self.singleLens
            tracker.aimQuality = aim
            var pictures: [[SkyDetection]] = (0..<60).map { _ in
                [Self.detection(300.5 + 0.5 * Self.gauss(&random), 150.5 + 0.5 * Self.gauss(&random), flux: Double.random(in: 200...400, using: &random),
                                significance: Double.random(in: 1.6...4, using: &random))]
            }
            pictures += Array(repeating: [], count: 10)
            pictures += [[Self.detection(500, 100, elongation: 9)], [Self.detection(502, 100, elongation: 9)]]
            let (kept, dropped) = Self.followToTheEnd(tracker, pictures)
            #expect(kept.isEmpty, "aim \(aim): \(kept.count) kept")
            #expect(dropped.map(\.reason) == [.barelyMoved, .barelyMoved], "aim \(aim): \(dropped.map(\.reason))")
            let star = try #require(dropped.first).track, flash = try #require(dropped.last).track
            #expect(star.samples.count == 60 && !star.streakBorn, "aim \(aim): the light's \(star.samples.count) samples")
            #expect(star.samples.allSatisfy { abs($0.point.x * Double(Self.width) - 300.5) < 2 && abs($0.point.y * Double(Self.height) - 150.5) < 2 })
            #expect(flash.streakBorn && flash.samples.count == 2, "aim \(aim): the flash's \(flash.samples.count) samples")
        }
    }

    @Test func aTrackOnSomethingFixedIsDroppedAsFixed() {
        // A light creeping 8 px in 4 s moves enough to be a track, but when every one of its detections stands 6σ by a spot of the slow
        // background (and it travelled under 10 px) it is dropped as fixed, not as barely moved. One that stays put on such a spot is fixed too:
        // the spot says what it is. Without the spot the first is kept and the second is barely moved.
        let cases: [(step: Double, fixed: Bool, reason: SkyDroppedTrack.DropReason?)] = [
            (0.4, true, .fixed), (0, true, .fixed), (0.4, false, nil), (0, false, .barelyMoved),
        ]
        for item in cases {
            let tracker = SkyTracker(width: Self.width, height: Self.height)
            let pictures = (0..<20).map { k in
                [Self.detection(300 + item.step * Double(k), 150, fixedRise: item.fixed ? 6 : 0, fixedRiseUnder: item.fixed ? 6 : 0)]
            }
            let (kept, dropped) = Self.followToTheEnd(tracker, pictures)
            #expect(kept.count == (item.reason == nil ? 1 : 0), "\(item): \(kept.count) kept")
            #expect(dropped.map(\.reason) == (item.reason.map { [$0] } ?? []), "\(item): \(dropped.map(\.reason))")
            #expect(dropped.allSatisfy { $0.track.samples.count == 20 }, "\(item)")
        }
    }

    @Test func noiseAndShortTracksAreNotReported() {
        // Dropped but not handed over: a track of faint samples only (significance under 1.5: noise lined up by chance), whether it moves,
        // stays put or sits by something fixed, and a track that ended within 0.6 s (the pinned minimum), however little it moved.
        let cases: [(name: String, pictures: [[SkyDetection]])] = [
            ("faint and moving", (0..<20).map { [Self.detection(100 + 5 * Double($0), 100, significance: 1.2)] }),
            ("faint and still", (0..<20).map { _ in [Self.detection(300, 150, significance: 1.2)] }),
            ("faint and fixed", (0..<20).map { _ in [Self.detection(300, 150, significance: 1.2, fixedRise: 6, fixedRiseUnder: 6)] }),
            ("under 0.6 s and still", (0..<3).map { _ in [Self.detection(300, 150)] }),
        ]
        for item in cases {
            let tracker = SkyTracker(width: Self.width, height: Self.height)
            let (kept, dropped) = Self.followToTheEnd(tracker, item.pictures)
            #expect(kept.isEmpty && dropped.isEmpty, "\(item.name): \(kept.count) kept, \(dropped.map(\.reason)) dropped")
        }
    }

    @Test func aKeptTrackIsNeverInTheDroppedList() {
        // A light flying across, one that stays put and a flicker on something fixed, all in one run: only the first is kept, the other two
        // are dropped (barely moved, fixed), no track is in both lists, and the calls without a list return the same kept track.
        let pictures: [[SkyDetection]] = (0..<40).map { k in
            [Self.detection(100 + 5 * Double(k), 60), Self.detection(300.2, 150), Self.detection(400, 200, fixedRise: 6, fixedRiseUnder: 6)]
        }
        let tracker = SkyTracker(width: Self.width, height: Self.height)
        let (kept, dropped) = Self.followToTheEnd(tracker, pictures)
        #expect(kept.count == 1 && kept.first?.samples.count == 40)
        #expect(kept.first.map { abs($0.samples[0].point.y * Double(Self.height) - 60) < 1e-6 } == true)
        #expect(dropped.count == 2 && Set(dropped.map(\.reason)) == [.barelyMoved, .fixed], "\(dropped.map(\.reason))")
        #expect(Set(kept.map(\.id)).isDisjoint(with: dropped.map(\.track.id)))
        for drop in dropped {
            let wanted = drop.reason == .fixed ? 200.0 : 150.0
            #expect(drop.track.samples.count == 40 && drop.track.samples.allSatisfy { abs($0.point.y * Double(Self.height) - wanted) < 1e-6 })
        }
        let plain = SkyTracker(width: Self.width, height: Self.height)
        let alone = Self.follow(plain, pictures) + plain.endAll()
        #expect(alone.count == 1 && alone.first?.samples.map(\.time) == kept.first?.samples.map(\.time))
        // A clock that starts again ends what is open, and reports what it drops.
        let restarted = SkyTracker(width: Self.width, height: Self.height)
        _ = Self.follow(restarted, (0..<20).map { _ in [Self.detection(300, 150)] })
        var restartDrops: [SkyDroppedTrack] = []
        let over = restarted.update([], at: 0.5, wallClock: SkyFixtures.aimEpoch, dropped: &restartDrops)
        #expect(over.isEmpty && restartDrops.map(\.reason) == [.barelyMoved] && restarted.activeCount == 0)
    }

    // MARK: A dual camera's halves

    @Test func aDualCameraIsAnalysedPerHalf() throws {
        let model = SkyCameraModel.initial(facing: 0, tilt: 20, pictureWidth: Self.width, pictureHeight: Self.height)
        #expect(model.layout == .dual)
        var random = SkyRandom(seed: 24)
        let run = Run()
        run.mask = SkyMask(model: model)
        for frame in 0..<6 {
            var picture = SkyPicture(using: &random)
            if frame >= 2 {
                picture.dot(x: 320.0, y: 100.5, amplitude: 90)   // on the seam (between columns 319 and 320)
                picture.dot(x: 150.5, y: 100.5, amplitude: 90)
                picture.dot(x: 500.5, y: 100.5, amplitude: 90)
            }
            run.feed(picture)
        }
        let found = try #require(run.detections.last).sorted { $0.x < $1.x }
        try #require(found.count == 4)
        #expect(found.map(\.lens) == [0, 0, 1, 1])
        #expect(found.map(\.inSeamBand) == [false, true, true, false])
        // The seam cuts the dot in two: neither half reaches across it. The halves are linked as one blob's pieces, and share its
        // measures: its whole flux, area, peak and shape.
        #expect(found[1].x < 320 && found[2].x > 320)
        #expect(found[1].seamGroup != nil && found[1].seamGroup == found[2].seamGroup)
        #expect(found[0].seamGroup == nil && found[3].seamGroup == nil)
        #expect(found[1].flux == found[2].flux && found[1].area == found[2].area && found[1].peak == found[2].peak)
        #expect(abs(found[1].flux / found[0].flux - 1) < 0.25 && found[1].elongation < 1.6)
    }

    @Test func aLightOnTheSeamIsOneTrack() {
        // A light on a dual camera's seam is cut into a piece in each lens. The pieces are linked: a track that takes one takes the other
        // too, and neither starts a track of its own. A light moving along the seam, one crossing it slowly, and one crossing it at 5° to
        // the seam (on it for a dozen pictures): each is one track (each was two).
        let model = SkyCameraModel.initial(facing: 0, tilt: 20, pictureWidth: Self.width, pictureHeight: Self.height)
        let slant = 5 * Double.pi / 180
        let cases: [(name: String, start: (x: Double, y: Double), step: (x: Double, y: Double), pictures: Int, aim: SkyAimQuality)] = [
            ("along the seam", (320.0, 40.5), (0, 2.5), 70, .good),
            ("slowly across it", (310.3, 142.5), (0.3, 0), 70, .good),
            ("across it at 5° to it", (316.4, 30.5), (5 * sin(slant), 5 * cos(slant)), 45, .rough),
        ]
        for (index, item) in cases.enumerated() {
            var random = SkyRandom(seed: 50 + UInt64(index))
            let run = Run()
            run.mask = SkyMask(model: model)
            run.tracker.model = model
            run.tracker.aimQuality = item.aim
            for frame in 0..<(item.pictures + 12) {
                var picture = SkyPicture(using: &random)
                let k = frame - 2
                if (0..<item.pictures).contains(k) {
                    picture.dot(x: item.start.x + item.step.x * Double(k), y: item.start.y + item.step.y * Double(k), amplitude: 70)
                }
                run.feed(picture)
            }
            let tracks = run.ended + run.tracker.endAll()
            #expect(tracks.count == 1, "\(item.name): \(tracks.count) tracks of \(tracks.map(\.samples.count)) samples")
            #expect((tracks.first?.samples.count ?? 0) >= item.pictures - 2, "\(item.name): \(tracks.first?.samples.count ?? 0) samples")
            // It keeps to its own lens's piece while there is one: along the seam it never changes lens, across it once.
            #expect(tracks.first?.seamJoins == (index == 0 ? 0 : 1), "\(item.name): \(tracks.first?.seamJoins ?? -1) joins")
        }
    }

    @Test func aPairAcrossTheSeamIsJudgedOnTheSky() throws {
        // A track's first two detections in different lenses are judged as a track's join across the seam is: once the aim is good, by their
        // sky directions (within 3° and the reach in degrees). Halves overlapping 12°: 317 in the left lens and 323 in the right are 10.9°
        // apart in the sky, so a precise aim does not pair them; the light is followed from 323 on. A rough aim pairs them by the picture,
        // and the join is uncertain. Halves that meet: the same detections are one light, joined for certain.
        let pictures: [[SkyDetection]] = [[Self.detection(317, 142, lens: 0)]] + (0..<12).map { [Self.detection(323 + 3 * Double($0), 142, lens: 1)] }
            + Array(repeating: [], count: 10)
        let apart = SkyTracker(width: Self.width, height: Self.height)
        apart.model = Self.overlapping(12)
        apart.aimQuality = .precise
        let separate = Self.follow(apart, pictures)
        #expect(separate.count == 1)
        let followed = try #require(separate.first)
        #expect(followed.samples.count == 12 && followed.samples.allSatisfy { $0.lens == 1 } && followed.seamJoins == 0)
        let rough = SkyTracker(width: Self.width, height: Self.height)
        rough.model = Self.overlapping(12)
        let guessed = Self.follow(rough, pictures)
        #expect(guessed.count == 1 && guessed.first?.samples.count == 13 && guessed.first?.uncertainSeamJoin == true)
        let meeting = SkyTracker(width: Self.width, height: Self.height)
        meeting.model = Self.overlapping(0)
        meeting.aimQuality = .precise
        let joined = Self.follow(meeting, pictures)
        #expect(joined.count == 1 && joined.first?.samples.count == 13)
        #expect(joined.first?.seamJoins == 1 && joined.first?.uncertainSeamJoin == false)
        // A light first seen in the left lens's last picture of it and then through the right one, halves overlapping 2° (it jumps about
        // 11 px ahead at the seam): its velocity is measured in the right lens's pixels (where the left one's detection is seen through
        // it), so its third detection is where it was predicted and the track keeps its first.
        let overlap = Self.overlapping(2)
        let crossing = Self.seamCrossing(overlap)
        let last = try #require(crossing.lastIndex { $0.first?.lens == 0 })
        let born = SkyTracker(width: Self.width, height: Self.height)
        born.model = overlap
        born.aimQuality = .good
        let late = Self.follow(born, Array(crossing[last...]))
        #expect(late.count == 1 && late.first?.samples.count == crossing[last...].filter { !$0.isEmpty }.count)
        #expect(late.first?.samples.first?.lens == 0 && late.first?.seamJoins == 1 && late.first?.uncertainSeamJoin == false)
    }

    /// A dual camera whose halves overlap at the seam by `overlap` degrees (the right lens turned that much towards the left one), as a
    /// stitch can leave them: a light crossing the seam jumps ahead in the picture.
    static func overlapping(_ overlap: Double) -> SkyCameraModel {
        var model = SkyCameraModel.initial(facing: 0, tilt: 0, pictureWidth: width, pictureHeight: height)
        model.lenses[1].yaw -= overlap
        return model
    }

    /// Detections of a light moving along the horizon's row (eastward, 2.4°/s) through `model`, each through the lens of the half it is
    /// seen in, staying with the left lens while that still sees it.
    static func seamCrossing(_ model: SkyCameraModel) -> [[SkyDetection]] {
        var pictures: [[SkyDetection]] = []
        var lens = 0
        for k in 0..<40 {
            let direction = SkyDirection(azimuth: SkyMath.normalizedDegrees(-10 + 0.48 * Double(k)), elevation: 0)
            let hits = model.project(direction)
            guard let hit = hits.first(where: { $0.lens == lens }) ?? hits.first else { pictures.append([]); continue }
            lens = hit.lens
            pictures.append([detection(hit.point.x * Double(width), hit.point.y * Double(height), lens: hit.lens,
                                       inSeamBand: model.isInSeamBand(hit.point))])
        }
        return pictures + Array(repeating: [], count: 10)
    }

    @Test func aTrackCrossesTheSeamThroughTheLensesOnceTheAimIsGood() throws {
        // A 2° overlap makes the light jump about 11 px ahead as it crosses (the lenses' edges have 5.6 px a degree): more than the gate,
        // within the 3° the lenses' directions allow.
        let model = Self.overlapping(2)
        let pictures = Self.seamCrossing(model)
        let lenses = pictures.compactMap { $0.first?.lens }
        #expect(lenses.contains(0) && lenses.contains(1))
        let aimed = SkyTracker(width: Self.width, height: Self.height)
        aimed.model = model
        aimed.aimQuality = .good
        let joined = Self.follow(aimed, pictures)
        #expect(joined.count == 1)
        let track = try #require(joined.first)
        #expect(track.samples.count == 40)
        #expect(track.seamJoins == 1 && !track.uncertainSeamJoin)
        #expect(Set(track.samples.map(\.lens)) == [0, 1])
        // Before the aim is good, the halves are joined by the picture alone, with a wider gate, and the join is marked uncertain.
        let rough = SkyTracker(width: Self.width, height: Self.height)
        rough.model = model
        let guessed = Self.follow(rough, pictures)
        #expect(guessed.count == 1)
        #expect(guessed.first?.seamJoins == 1 && guessed.first?.uncertainSeamJoin == true)
    }

    @Test func theLensesKeepApartWhatOnlyLooksClose() {
        // A 12° overlap: right after the seam, the right lens shows sky 12° back, so a light seen there next to the left one's track is
        // something else. A good aim keeps them apart; joining by the picture alone cannot tell.
        let model = Self.overlapping(12)
        var pictures: [[SkyDetection]] = []
        for k in 0..<20 { pictures.append([Self.detection(260 + 3 * Double(k), 142, lens: 0)]) }      // to x 317, the left lens's edge
        for k in 0..<12 { pictures.append([Self.detection(323 + 3 * Double(k), 142, lens: 1)]) }      // on, through the right lens
        pictures += Array(repeating: [], count: 10)
        let aimed = SkyTracker(width: Self.width, height: Self.height)
        aimed.model = model
        aimed.aimQuality = .precise
        #expect(Self.follow(aimed, pictures).count == 2)
        let rough = SkyTracker(width: Self.width, height: Self.height)
        rough.model = model
        let guessed = Self.follow(rough, pictures)
        #expect(guessed.count == 1 && guessed.first?.uncertainSeamJoin == true)
    }

    // MARK: Cost

    /// The analysis of a full-size picture (1920×852, the widest the sky is analysed at): its cost per picture is printed (a debug build
    /// is several times slower than the box's; the report has the optimized figure).
    @Test func aFullSizePictureIsAnalysed() {
        var random = SkyRandom(seed: 25)
        let analyzer = SkyFrameAnalyzer(width: 1920, height: 852)
        let mask = SkyMask(groundPercent: 12, model: SkyCameraModel.initial(facing: 0, tilt: 20, pictureWidth: 4256, pictureHeight: 1888))
        let pictures = (0..<4).map { _ in SkyPicture(width: 1920, height: 852, using: &random) }
        var withDots = pictures[3]
        withDots.dot(x: 700.5, y: 300.5, amplitude: 80)
        withDots.dot(x: 1500.5, y: 200.5, amplitude: 80)
        for picture in pictures.prefix(3) { _ = analyzer.process(picture.image, mask: mask, isNight: true) }
        let images = pictures.map(\.image) + [withDots.image]
        let clock = ContinuousClock()
        var found = 0
        let elapsed = clock.measure {
            for k in 0..<10 { found += analyzer.process(images[k % images.count], mask: mask, isNight: true).detections.count }
        }
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 / 10 + Double(elapsed.components.seconds) * 1000 / 10
        print("SkyFrameAnalyzer: \(String(format: "%.1f", milliseconds)) ms per 1920×852 picture (this build)")
        #expect(found == 4)
        #expect(analyzer.background.width == 1920 && analyzer.background.pixels.count == 1920 * 852)
    }
}
