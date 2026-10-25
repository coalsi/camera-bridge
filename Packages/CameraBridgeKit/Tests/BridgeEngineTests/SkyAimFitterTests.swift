import Foundation
import Testing
import TestSupport
@testable import BridgeSupport
@testable import BridgeEngine

/// Aim fitting (`AimFitter`, `SkyAimStore`): each lens of a camera is fitted on its own to the matches it sees (plane tracks first, then
/// stars), robustly (RANSAC on the rotation, then Levenberg–Marquardt with Huber weights in the original picture's pixels), its projection
/// chosen and its terms freed in stages as matches accumulate. Synthetic data only: the truth models of `SkyFixtures`, plane tracks along
/// great circles and random stars above 5°, each direction moved in a random direction, uniformly over a disc: by up to 0.15° for a plane
/// (an RMS of 0.106°: a feed's position and timing) and up to 0.03° for a star (its centroid on a stack of analysis pictures, a third of a
/// pixel of the 1920 px picture across a 90° lens). With a plane's noise on the stars too, no fit could meet the pixel bounds of the
/// distortion tests (the residual alone would be 2 px at a lens's centre); the fitter reaches the same optimum from the truth itself.
@Suite struct SkyAimFitterTests {
    static let radians = Double.pi / 180
    static let width = 4256, height = 1888
    static let noise = 0.15
    static let starNoise = 0.03

    /// The card's model of the truth dual camera: facing north, tilted up 20° (the truth's housing faces 352° and is tilted up 18°).
    static let card = SkyCameraModel.initial(facing: 0, tilt: 20, pictureWidth: width, pictureHeight: height)

    /// The truth dual camera's plane tracks (6 for each lens, 6 samples each), and their fit from the card's model.
    static let planes: (data: [AimCorrespondence], fit: AimFit) = {
        var random = SkyRandom(seed: 1)
        let data = SkyFixtures.planeTracks(through: SkyFixtures.truthDual, perLens: 6, samples: 6, noise: noise, using: &random)
        return (data, AimFitter.fit(data, starting: card, pictureWidth: width, pictureHeight: height, previous: nil, using: &random))
    }()

    /// Then 170 stars for each lens (outside the seam band) with those planes, fitted from the planes' fit.
    static let stars: (data: [AimCorrespondence], fit: AimFit) = {
        var random = SkyRandom(seed: 3)
        let data = planes.data + SkyFixtures.stars(through: SkyFixtures.truthDual, perLens: 170, noise: starNoise, using: &random)
        return (data, AimFitter.fit(data, starting: planes.fit.model, pictureWidth: width, pictureHeight: height, previous: planes.fit,
                                    using: &random))
    }()

    /// The truth single lens's card (1920×1080, facing 205°, tilted up 20°; the truth faces 212.5° and is tilted up 24°).
    static let singleCard = SkyCameraModel.initial(facing: 205, tilt: 20, pictureWidth: 1920, pictureHeight: 1080)

    // MARK: Helpers

    /// Where a lens's frame centre looks, and the bearing there (degrees from north, through east) of the frame's middle row, to the right:
    /// the aim that a fit of the pose and the field alone can find (a principal point off the centre, which that fit does not free, is the
    /// same as a turn of the lens there).
    static func aim(_ model: SkyCameraModel, lens: Int) -> (centre: SkyDirection, bearing: Double)? {
        let frame = model.frame(of: lens)
        guard let centre = model.direction(at: PixelPoint(x: frame.origin + frame.width / 2, y: 0.5), lens: lens),
              let right = model.direction(at: PixelPoint(x: frame.origin + frame.width * 0.6, y: 0.5), lens: lens) else { return nil }
        let azimuth = centre.azimuth * radians, elevation = centre.elevation * radians
        let east = SIMD3(cos(azimuth), -sin(azimuth), 0.0)
        let north = SIMD3(-sin(elevation) * sin(azimuth), -sin(elevation) * cos(azimuth), cos(elevation))
        let here = SkyMath.unitVector(centre), there = SkyMath.unitVector(right)
        let toward = there - here * SkyMath.dot(here, there)
        return (centre, atan2(SkyMath.dot(toward, east), SkyMath.dot(toward, north)) / radians)
    }

    /// The angle a lens's frame spans across its middle row, edge to edge: its field of view as far as a fit without radial terms can tell
    /// (the truth's barrel distortion shows more than its pinhole's field).
    static func span(_ model: SkyCameraModel, lens: Int) -> Double? {
        let frame = model.frame(of: lens)
        guard let left = model.direction(at: PixelPoint(x: frame.origin, y: 0.5), lens: lens),
              let right = model.direction(at: PixelPoint(x: frame.origin + frame.width, y: 0.5), lens: lens) else { return nil }
        return SkyMath.separation(left, right)
    }

    /// Each lens of `fitted` aims where `truth`'s does: its frame centre's azimuth and elevation and its middle row's bearing within `angle`
    /// degrees ("yaw, pitch and roll"), and its field (`span`) within `field` degrees.
    static func expectAim(_ fitted: SkyCameraModel, _ truth: SkyCameraModel, within angle: Double, field: Double,
                          sourceLocation: SourceLocation = #_sourceLocation) throws {
        for lens in 0..<truth.lensCount {
            let seen = try #require(aim(fitted, lens: lens), sourceLocation: sourceLocation)
            let real = try #require(aim(truth, lens: lens), sourceLocation: sourceLocation)
            let yaw: Double = SkyFixtures.azimuthDifference(seen.centre.azimuth, real.centre.azimuth)
            let pitch: Double = abs(seen.centre.elevation - real.centre.elevation)
            let roll: Double = abs((seen.bearing - real.bearing).remainder(dividingBy: 360))
            let fieldOff: Double = abs(try #require(span(fitted, lens: lens)) - (try #require(span(truth, lens: lens))))
            #expect(yaw <= angle && pitch <= angle && roll <= angle, "lens \(lens): yaw \(yaw)°, pitch \(pitch)°, roll \(roll)° off",
                    sourceLocation: sourceLocation)
            #expect(fieldOff <= field, "lens \(lens): the field is \(fieldOff)° off", sourceLocation: sourceLocation)
        }
    }

    /// How far (pixels of a `width` × `height` picture) `fitted` puts the direction that `truth` sees at `point`, through the point's own lens.
    static func pixelError(_ fitted: SkyCameraModel, _ truth: SkyCameraModel, at point: PixelPoint, width: Int = width,
                           height: Int = height) -> Double {
        let lens = truth.lens(at: point)
        guard let direction = truth.direction(at: point, lens: lens), let seen = fitted.project(direction, lens: lens) else { return .infinity }
        return hypot((seen.x - point.x) * Double(width), (seen.y - point.y) * Double(height))
    }

    static func rms(_ values: [Double]) -> Double {
        (values.reduce(0) { $0 + $1 * $1 } / Double(max(1, values.count))).squareRoot()
    }

    /// How far (pixels of a `width` × `height` picture) `model` puts a match's direction, through the lens of its pixel, from where it was
    /// seen.
    static func reprojection(_ model: SkyCameraModel, _ match: AimCorrespondence, width: Int = width, height: Int = height) -> Double {
        guard let seen = model.project(match.direction, lens: model.lens(at: match.point)) else { return .infinity }
        return hypot((seen.x - match.point.x) * Double(width), (seen.y - match.point.y) * Double(height))
    }

    /// A plain single lens (1920×1080, rectilinear, no distortion, its principal point at the centre, square pixels; `stretch` makes its
    /// vertical field that much larger), and a card 3° off it.
    static func plainLens(stretch: Double = 1) -> SkyCameraModel {
        SkyCameraModel(layout: .single, seam: 0.5, lenses: [SkyCameraModel.Lens(
            yaw: 150, pitch: 40, roll: 0, horizontalFOV: 100,
            verticalFOV: stretch * SkyCameraModel.Lens.verticalFOV(horizontalFOV: 100, frameAspect: 16.0 / 9),
            principalPoint: PixelPoint(x: 0.5, y: 0.5), radial: [])])
    }
    static let plainCard = SkyCameraModel.initial(facing: 147, tilt: 37, pictureWidth: 1920, pictureHeight: 1080)

    /// A rectilinear lens's vertical focal scale over its horizontal one (1 / the frame's aspect for square pixels).
    static func scaleRatio(_ lens: SkyCameraModel.Lens) -> Double {
        tan(lens.verticalFOV / 2 * radians) / tan(lens.horizontalFOV / 2 * radians)
    }

    /// `count` plane matches of as many aircraft at random pixels of the truth dual camera's sky (outside the seam band), each direction moved
    /// `range` degrees off the truth's, the way a camera that has turned would see them.
    static func planesOff(_ count: Int, by range: ClosedRange<Double>, seed: UInt64, at: Date) -> [AimCorrespondence] {
        var random = SkyRandom(seed: seed)
        var made: [AimCorrespondence] = []
        while made.count < count {
            let point = PixelPoint(x: Double.random(in: 0.05...0.95, using: &random), y: Double.random(in: 0.1...0.45, using: &random))
            guard !card.isInSeamBand(point), let seen = SkyFixtures.truthDual.direction(at: point), seen.direction.elevation > 3 else { continue }
            let direction = SkyFixtures.offset(seen.direction, by: Double.random(in: range, using: &random),
                                               toward: Double.random(in: 0..<(2 * Double.pi), using: &random))
            made.append(AimCorrespondence(point: point, direction: direction, source: .plane, at: at.addingTimeInterval(Double(made.count)),
                                          object: "d\(seed)-\(made.count)"))
        }
        return made
    }

    // MARK: The brief's tests

    @Test func recoversAimFromSyntheticPlaneTracks() throws {
        let (data, fit) = Self.planes
        #expect(data.count == 72)
        // Each lens has 36 sightings of 6 aircraft: stage 1 (its pose and its field), and good.
        #expect(fit.lenses.map(\.stage) == [1, 1] && fit.stage == 1, "\(fit.lenses)")
        #expect(fit.quality == .good && fit.lenses.allSatisfy { $0.quality == .good }, "\(fit.lenses)")
        try Self.expectAim(fit.model, SkyFixtures.truthDual, within: 0.3, field: 1)
        // Stage 1 frees only the pose and the field: no radial terms, the principal points where the card put them, the projection kept.
        for (lens, start) in zip(fit.model.lenses, Self.card.lenses) {
            #expect(lens.radial.isEmpty && lens.principalPoint == start.principalPoint && lens.projection == start.projection, "\(lens)")
        }
        #expect(fit.planes == 12 && fit.stars == 0 && fit.inliers >= 70, "\(fit.inliers) inliers")
    }

    @Test func mismatchesDoNotSkewTheFit() throws {
        var random = SkyRandom(seed: 2)
        var data = Self.planes.data
        // 30 % of each lens's samples (11 of 36) get a random direction above the horizon: a wrong aircraft.
        for lens in 0...1 {
            let own = data.indices.filter { Self.card.lens(at: data[$0].point) == lens }
            for index in own.shuffled(using: &random).prefix(11) { data[index].direction = SkyFixtures.randomDirection(above: 0, using: &random) }
        }
        let fit = AimFitter.fit(data, starting: Self.card, pictureWidth: Self.width, pictureHeight: Self.height, previous: nil, using: &random)
        #expect(fit.lenses.map(\.stage) == [1, 1] && fit.quality == .good, "\(fit.lenses)")
        try Self.expectAim(fit.model, SkyFixtures.truthDual, within: 0.3, field: 1)
        // The right matches are its inliers, the wrong ones are not.
        #expect(fit.inliers >= 48 && fit.inliers <= 52, "\(fit.inliers) inliers")

        // Wrong aircraft are usually near the right one: within the rough matching tolerance (here 2–14° off), so RANSAC's 15° keeps them.
        // Judged again at the tolerance the fit earns, they are no inliers, and the aim is as good.
        var near = Self.planes.data
        for lens in 0...1 {
            let own = near.indices.filter { Self.card.lens(at: near[$0].point) == lens }
            for index in own.shuffled(using: &random).prefix(11) {
                near[index].direction = SkyFixtures.offset(near[index].direction, by: Double.random(in: 2...14, using: &random),
                                                           toward: Double.random(in: 0..<(2 * Double.pi), using: &random))
            }
        }
        let nearFit = AimFitter.fit(near, starting: Self.card, pictureWidth: Self.width, pictureHeight: Self.height, previous: nil, using: &random)
        #expect(nearFit.lenses.map(\.stage) == [1, 1] && nearFit.quality == .good, "\(nearFit.lenses)")
        try Self.expectAim(nearFit.model, SkyFixtures.truthDual, within: 0.3, field: 1)
        #expect(nearFit.inliers == 50, "\(nearFit.inliers) inliers")
    }

    @Test func recoversDistortionFromSyntheticStars() throws {
        let (data, fit) = Self.stars
        // Each lens has 36 plane and 170 star sightings, all over its frame: stage 3, and precise.
        #expect(fit.lenses.map(\.stage) == [3, 3] && fit.stage == 3, "\(fit.lenses)")
        #expect(fit.quality == .precise && fit.lenses.allSatisfy { $0.quality == .precise }, "\(fit.lenses)")
        // Where the matches are, the fitted model puts the sky where the truth does: RMS ≤ 1.5 px of the 4256 px picture.
        let errors = data.map { Self.pixelError(fit.model, SkyFixtures.truthDual, at: $0.point) }
        #expect(Self.rms(errors) <= 1.5, "RMS \(Self.rms(errors)) px, worst \(errors.max() ?? 0) px")
        // What it reports is the noise: the planes' (an RMS of 0.106°) and the stars' (0.021°) together, under 1.5 px.
        #expect(fit.residualDegrees > 0.03 && fit.residualDegrees < 0.08, "\(fit.residualDegrees)°")
        #expect(fit.residualPixels <= 1.5, "\(fit.residualPixels) px")
        // Stage 3 frees k1 and k2 (k3 waits for 300), and with them the principal points and each lens's own vertical field.
        #expect(fit.model.lenses.allSatisfy { $0.radial.count == 2 && $0.projection == .rectilinear }, "\(fit.model.lenses)")
        #expect(fit.stars == 340 && fit.planes == 12)
    }

    @Test func edgeOfFrameIsAccurate() throws {
        let fit = Self.stars.fit
        var errors: [Double] = []
        for i in 0...200 {
            for j in 0...100 {
                let point = PixelPoint(x: Double(i) / 200, y: Double(j) / 100)
                guard point.x < 0.05 || point.x > 0.95 || point.y < 0.05 || point.y > 0.95, !Self.card.isInSeamBand(point) else { continue }
                errors.append(Self.pixelError(fit.model, SkyFixtures.truthDual, at: point))
            }
        }
        // Below the horizon too (no star is there): the lenses' terms are radial, so the sky above pins them down.
        #expect(errors.count > 2_000 && (errors.max() ?? .infinity) <= 3, "worst \(errors.max() ?? 0) px of \(errors.count)")
    }

    @Test func theStitchSeamIsAccurate() throws {
        let fit = Self.stars.fit
        var errors: [Double] = []
        for i in 0...40 {
            let x = 0.4805 + Double(i) * 0.000_975   // 0.4805 … 0.5195: both sides of the seam, its band included, each through its own lens
            for j in 0...50 { errors.append(Self.pixelError(fit.model, SkyFixtures.truthDual, at: PixelPoint(x: x, y: Double(j) / 50))) }
        }
        #expect((errors.max() ?? .infinity) <= 3, "worst \(errors.max() ?? 0) px")
        // The halves' constants (their principal points) are each their own, as in the truth.
        let fitted = fit.model.lenses.map(\.principalPoint), truth = SkyFixtures.truthDual.lenses.map(\.principalPoint)
        for (seen, real) in zip(fitted, truth) {
            #expect(abs(seen.x - real.x) <= 0.002 && abs(seen.y - real.y) <= 0.002, "\(seen) against \(real)")
        }
        let across: Double = (fitted[1].x - fitted[0].x) * (truth[1].x - truth[0].x)
        let down: Double = (fitted[1].y - fitted[0].y) * (truth[1].y - truth[0].y)
        #expect(across > 0 && down > 0, "the halves differ as the truth's do: \(fitted)")
    }

    @Test func rectilinearBrownIsRecovered() throws {
        var random = SkyRandom(seed: 4)
        let truth = SkyFixtures.truthSingle
        let corners = [PixelPoint(x: 0, y: 0), PixelPoint(x: 1, y: 0), PixelPoint(x: 0, y: 1), PixelPoint(x: 1, y: 1)]
        let data = SkyFixtures.stars(through: truth, perLens: 320, noise: Self.starNoise, using: &random)
        let fit = AimFitter.fit(data, starting: Self.singleCard, pictureWidth: 1920, pictureHeight: 1080, previous: nil, using: &random)
        let lens = fit.model.lenses[0]
        // 320 sightings over the frame: stage 4 (k3 too), straight from the card's rough aim.
        #expect(fit.stage == 4 && fit.quality == .precise && lens.projection == .rectilinear && lens.radial.count == 3, "\(fit.lenses) \(lens)")
        let k1 = lens.radial.first ?? 0, k2 = lens.radial.count > 1 ? lens.radial[1] : 0
        #expect(abs(k1 + 0.25) <= 0.02 && abs(k2 - 0.08) <= 0.02, "k1 \(k1), k2 \(k2)")
        // The corners are the frame's largest radius, where a pixel spans a fifth of what it does at the centre and k3 counts most: one
        // standard deviation of k3 from 320 stars moves them about 3 px. So with 320 they are within 4 px, and with 1,000 more (the store
        // keeps up to 2,000) within 2.
        for corner in corners {
            let error = Self.pixelError(fit.model, truth, at: corner, width: 1920, height: 1080)
            #expect(error <= 4, "\(corner): \(error) px")
        }
        let more = SkyFixtures.stars(through: truth, perLens: 1_000, noise: Self.starNoise, using: &random)
        let refit = AimFitter.fit(data + more, starting: fit.model, pictureWidth: 1920, pictureHeight: 1080, previous: fit, using: &random)
        for corner in corners {
            let error = Self.pixelError(refit.model, truth, at: corner, width: 1920, height: 1080)
            #expect(error <= 2, "\(corner): \(error) px from 1,320 stars")
        }
    }

    @Test func fewMatchesFreeFewTerms() throws {
        var random = SkyRandom(seed: 5)
        let start = Self.singleCard
        let tracks = SkyFixtures.planeTracks(through: SkyFixtures.truthSingle, perLens: 5, samples: 2, noise: Self.noise, using: &random)
        // 6 matches of 3 aircraft are too few: stage 0, and the card's model unchanged.
        let six = AimFitter.fit(Array(tracks.prefix(6)), starting: start, pictureWidth: 1920, pictureHeight: 1080, previous: nil, using: &random)
        #expect(six.stage == 0 && six.quality == .rough && six.model == start && six.inliers == 0, "\(six)")
        // 9 of 5 aircraft: stage 1, the pose and the field only (no radial terms, the principal point where it was).
        let nine = AimFitter.fit(Array(tracks.prefix(9)), starting: start, pictureWidth: 1920, pictureHeight: 1080, previous: nil, using: &random)
        let lens = nine.model.lenses[0]
        #expect(nine.stage == 1 && lens.radial.isEmpty && lens.principalPoint == start.lenses[0].principalPoint, "\(nine.lenses) \(lens)")
        #expect(lens != start.lenses[0] && lens.projection == .rectilinear)

        // A dual camera: 9 of 5 aircraft in the left lens fit that lens alone. The right lens has none and stays as the card made it, so the
        // camera as a whole, as aimed as its least aimed lens, is at stage 0.
        let left = SkyFixtures.planeTracks(through: SkyFixtures.truthDual, perLens: 5, samples: 2, noise: Self.noise, using: &random)
            .filter { Self.card.lens(at: $0.point) == 0 }
        let dual = AimFitter.fit(Array(left.prefix(9)), starting: Self.card, pictureWidth: Self.width, pictureHeight: Self.height, previous: nil,
                                 using: &random)
        #expect(dual.lenses.map(\.stage) == [1, 0] && dual.stage == 0 && dual.quality == .rough, "\(dual.lenses)")
        #expect(dual.model.lenses[1] == Self.card.lenses[1] && dual.model.lenses[0] != Self.card.lenses[0] && dual.model.lenses[0].radial.isEmpty)
    }

    @Test func aWildFitIsRejected() throws {
        var random = SkyRandom(seed: 6)
        let truth = SkyFixtures.truthSingle
        // A stage-1 aim from planes, then 60 matches all in one quarter of the picture: enough for stage 2 by number, not by coverage, so
        // the lens stays at stage 1, and no radial term is freed.
        let planes = SkyFixtures.planeTracks(through: truth, perLens: 6, samples: 4, noise: Self.noise, using: &random)
        let before = AimFitter.fit(planes, starting: Self.singleCard, pictureWidth: 1920, pictureHeight: 1080, previous: nil, using: &random)
        #expect(before.stage == 1, "\(before.lenses)")
        let quarter = SkyFixtures.stars(through: truth, perLens: 60, noise: Self.starNoise, where: { $0.x < 0.5 && $0.y < 0.5 }, using: &random)
        #expect(AimFitter.stage(for: quarter, model: before.model, lens: 0) == 1)
        let fit = AimFitter.fit(quarter, starting: before.model, pictureWidth: 1920, pictureHeight: 1080, previous: before, using: &random)
        #expect(fit.stage == 1 && fit.model.lenses[0].radial.isEmpty, "\(fit.lenses)")

        // A dual camera's lens is gated the same way: one quarter of the picture is the top half of its left lens.
        let corner = SkyFixtures.stars(through: SkyFixtures.truthDual, perLens: 60, noise: Self.starNoise, lenses: [0],
                                       where: { $0.x < 0.5 && $0.y < 0.5 }, using: &random)
        let dual = AimFitter.fit(corner, starting: Self.planes.fit.model, pictureWidth: Self.width, pictureHeight: Self.height,
                                 previous: Self.planes.fit, using: &random)
        #expect(dual.lenses[0].stage == 1 && dual.model.lenses[0].radial.isEmpty, "\(dual.lenses)")
        // Its right lens has no matches here: too few to fit now, it keeps its earlier aim and what was said of it.
        #expect(dual.lenses[1] == Self.planes.fit.lenses[1] && dual.model.lenses[1] == Self.planes.fit.model.lenses[1], "\(dual.lenses)")
    }

    @Test func aCorrectionBeyondThreePercentIsRejected() throws {
        // A dual camera whose left half has strong pincushion distortion (k1 +0.3, which no projection explains): the fit of that lens would
        // move the picture by far more than 3 % of its width from the lens's plain projection, so it is not taken. The right lens's fit is.
        var truth = SkyFixtures.truthDual
        truth.lenses[0].radial = [0.3]
        var random = SkyRandom(seed: 9)
        let data = SkyFixtures.stars(through: truth, perLens: 170, noise: Self.starNoise, using: &random)
        let attempt = AimFitter.attempt(data, starting: Self.card, pictureWidth: Self.width, pictureHeight: Self.height, previous: nil,
                                        using: &random)
        #expect(attempt.accepted, "the right lens's fit is taken")
        #expect(attempt.fit.model.lenses[0] == Self.card.lenses[0] && attempt.fit.lenses[0].stage == 0, "\(attempt.fit.lenses)")
        #expect(attempt.fit.lenses[1].stage == 3 && attempt.fit.lenses[1].quality == .precise, "\(attempt.fit.lenses)")
        #expect(attempt.notes.contains { $0.contains("left lens") && $0.contains("3 %") }, "\(attempt.notes)")
    }

    @Test func residualIsReportedInOriginalPixels() throws {
        // The residual in pixels is the inliers' own RMS in the original picture: where the fitted lens puts each match's direction, against
        // where it was seen (here every match is an inlier).
        var random = SkyRandom(seed: 10)
        let data = SkyFixtures.stars(through: SkyFixtures.truthSingle, perLens: 200, noise: Self.starNoise, using: &random)
        let fit = AimFitter.fit(data, starting: Self.singleCard, pictureWidth: 1920, pictureHeight: 1080, previous: nil, using: &random)
        #expect(fit.stage >= 1 && fit.inliers == data.count)
        let own = Self.rms(data.map { Self.reprojection(fit.model, $0, width: 1920, height: 1080) })
        #expect(abs(fit.residualPixels / own - 1) <= 1e-9, "\(fit.residualPixels) px against \(own) px")
        // Away from a rectilinear lens's centre a degree spans more pixels than there, so these are more pixels than the residual in degrees
        // over the centre's degrees per pixel would say.
        let centre = fit.model.degreesPerPixel(at: PixelPoint(x: 0.5, y: 0.5), pictureWidth: 1920)
        #expect(fit.residualPixels > fit.residualDegrees / centre, "\(fit.residualPixels) px, \(fit.residualDegrees / centre) px at the centre's scale")
        // The same lens seen in a picture twice as wide (the main stream, not the analysis one): about twice the pixels.
        let wider = AimFitter.fit(data, starting: Self.singleCard, pictureWidth: 3840, pictureHeight: 2160, previous: nil, using: &random)
        let doubled: Double = wider.residualPixels / fit.residualPixels
        #expect(abs(doubled - 2) <= 0.1, "\(wider.residualPixels) px against \(fit.residualPixels) px")
        // A dual camera: each lens's own inliers, and the camera's all of them.
        let (both, dual) = Self.stars
        #expect(dual.inliers == both.count)
        for (index, lens) in dual.lenses.enumerated() {
            let mine = Self.rms(both.filter { Self.card.lens(at: $0.point) == index }.map { Self.reprojection(dual.model, $0) })
            #expect(abs(lens.residualPixels / mine - 1) <= 1e-9, "lens \(index): \(lens.residualPixels) px against \(mine) px")
        }
        let all = Self.rms(both.map { Self.reprojection(dual.model, $0) })
        #expect(abs(dual.residualPixels / all - 1) <= 1e-9, "\(dual.residualPixels) px against \(all) px")
    }

    @Test func aMovedCameraStartsAimingAgain() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let now: @Sendable () -> Date = { SkyFixtures.aimEpoch.addingTimeInterval(7_200) }
        let store = SkyAimStore(directory: directory.url, log: Log(category: "Sky"), start: Self.card, pictureWidth: Self.width,
                                pictureHeight: Self.height, now: now, seed: 11)
        let first = await store.add(Self.planes.data)
        #expect(first?.quality == .good && first?.stage == 1, "\(String(describing: first?.lenses))")
        // Then the camera turns: plane matches 5° off where the aim says.
        var random = SkyRandom(seed: 12)
        var moved: [AimCorrespondence] = []
        while moved.count < 10 {
            let point = PixelPoint(x: Double.random(in: 0.05...0.95, using: &random), y: Double.random(in: 0.1...0.5, using: &random))
            guard !Self.card.isInSeamBand(point), let seen = SkyFixtures.truthDual.direction(at: point) else { continue }
            moved.append(AimCorrespondence(point: point, direction: SkyFixtures.offset(seen.direction, by: 5, toward: 1), source: .plane,
                                           at: SkyFixtures.aimEpoch.addingTimeInterval(3_600 + Double(moved.count)), object: "b\(moved.count)"))
        }
        #expect(await store.add(Array(moved.prefix(9))) == nil)
        #expect(await store.current() != nil, "nine in a row are not enough")
        #expect(await store.add(Array(moved.suffix(1))) == nil)
        // The tenth: the quality drops to rough, the matches are cleared, and the card says why.
        #expect(await store.current() == nil)
        let status = await store.status()
        #expect(status.quality == .rough && status.residualPixels == nil && status.note == "The camera seems to have moved; aiming again.",
                "\(status)")
        #expect(await store.correspondences().isEmpty)
        // A restart keeps it so.
        let again = SkyAimStore(directory: directory.url, log: Log(category: "Sky"), start: Self.card, pictureWidth: Self.width,
                                pictureHeight: Self.height, now: now, seed: 11)
        #expect(await again.current() == nil)
        #expect(await again.correspondences().isEmpty)
        #expect(await again.status().note == SkyAimStore.movedNote)
    }

    @Test func theSeamBandIsLeftOutOfTheFit() throws {
        // Matches in the seam band, where the stitch blends, are not fitted to: with 40 wildly wrong ones there the fit is the same, and
        // none is counted.
        var random = SkyRandom(seed: 18)
        var band: [AimCorrespondence] = []
        for index in 0..<40 {
            let x = 0.5 + Double.random(in: -0.004...0.004, using: &random)
            band.append(AimCorrespondence(point: PixelPoint(x: x, y: Double.random(in: 0.1...0.5, using: &random)),
                                          direction: SkyFixtures.randomDirection(above: 0, using: &random), source: .plane, at: SkyFixtures.aimEpoch,
                                          object: "band\(index)"))
        }
        #expect(band.allSatisfy { Self.card.isInSeamBand($0.point) })
        var same = SkyRandom(seed: 19), again = SkyRandom(seed: 19)
        let clean = AimFitter.fit(Self.planes.data, starting: Self.card, pictureWidth: Self.width, pictureHeight: Self.height, previous: nil,
                                  using: &same)
        let banded = AimFitter.fit(Self.planes.data + band, starting: Self.card, pictureWidth: Self.width, pictureHeight: Self.height,
                                   previous: nil, using: &again)
        #expect(banded == clean)
    }

    @Test func aFitWorseThanThePreviousAimIsRejected() throws {
        // The previous aim is the truth itself (a strongly distorted single lens), precise. Plane matches alone allow only stage 1 (the pose
        // and the field), which fits them far worse than the truth does, by more than 10 %, so the lens keeps the truth.
        var random = SkyRandom(seed: 20)
        let truth = SkyFixtures.truthSingle
        var previous = AimFitter.fit(SkyFixtures.stars(through: truth, perLens: 200, noise: Self.starNoise, using: &random),
                                     starting: Self.singleCard, pictureWidth: 1920, pictureHeight: 1080, previous: nil, using: &random)
        previous.model = truth
        #expect(previous.quality == .precise)
        let planes = SkyFixtures.planeTracks(through: truth, perLens: 6, samples: 5, noise: Self.noise, using: &random)
        let attempt = AimFitter.attempt(planes, starting: Self.singleCard, pictureWidth: 1920, pictureHeight: 1080, previous: previous,
                                        using: &random)
        #expect(!attempt.accepted && attempt.fit == previous, "\(attempt.notes)")
        #expect(attempt.notes.count == 1 && attempt.notes.allSatisfy { $0.contains("further off than before") }, "\(attempt.notes)")
    }

    @Test func aStretchedHalfIsFollowedFromStage3() throws {
        // A half stretched up and down (its vertical field 4 % off square). From stage 3 the fit frees the vertical field, and follows it to
        // 0.2°.
        let truth = SkyFixtures.truthStretchedDual
        var random = SkyRandom(seed: 24)
        let three = AimFitter.fit(SkyFixtures.stars(through: truth, perLens: 170, noise: Self.starNoise, using: &random), starting: Self.card,
                                  pictureWidth: Self.width, pictureHeight: Self.height, previous: nil, using: &random)
        #expect(three.lenses.map(\.stage) == [3, 3], "\(three.lenses)")
        for (fitted, real) in zip(three.model.lenses, truth.lenses) {
            let off: Double = abs(fitted.verticalFOV - real.verticalFOV)
            #expect(off <= 0.2, "vertical field \(fitted.verticalFOV)° against \(real.verticalFOV)°")
        }
        // At stage 2 the vertical field is not freed: it follows the horizontal one at the ratio the lens had, here the one stage 3 found …
        let two = AimFitter.fit(SkyFixtures.stars(through: truth, perLens: 100, noise: Self.starNoise, using: &random), starting: three.model,
                                pictureWidth: Self.width, pictureHeight: Self.height, previous: three, using: &random)
        #expect(two.lenses[0].stage == 2, "\(two.lenses)")
        let kept: Double = Self.scaleRatio(two.model.lenses[0]) / Self.scaleRatio(three.model.lenses[0])
        #expect(abs(kept - 1) <= 1e-9, "\(kept)")
        // … and from the card, its square pixels, though the lens is 4 % off them (a single lens: k1 and the principal point make up what
        // they can; a dual camera's lens would move more than 3 % and be refused).
        let stretched = Self.plainLens(stretch: 1.04)
        let card = AimFitter.fit(SkyFixtures.stars(through: stretched, perLens: 100, noise: Self.starNoise, using: &random),
                                 starting: Self.plainCard, pictureWidth: 1920, pictureHeight: 1080, previous: nil, using: &random)
        #expect(card.stage == 2, "\(card.lenses)")
        let square: Double = Self.scaleRatio(card.model.lenses[0]) / Self.scaleRatio(Self.plainCard.lenses[0])
        #expect(abs(square - 1) <= 1e-9, "\(square)")
    }

    @Test func weakMatchesLeaveTheCorrectionsToThePrior() throws {
        // Noisy matches (up to 0.15°) all within about 6° of a plain lens's centre allow stage 2 by their number and spread, but hardly tell
        // k1 or the principal point from the pose and the field. The ridge prior holds them: k1 near 0, the principal point near the frame's
        // centre, as in the truth. (Without the prior, k1 runs to 0.5 and the principal point 0.04 off.)
        let truth = Self.plainLens()
        for seed in [UInt64(400), 401, 402] {
            var random = SkyRandom(seed: seed)
            let data = SkyFixtures.stars(through: truth, perLens: 100, noise: Self.noise,
                                         where: { abs($0.x - 0.5) < 0.06 && abs($0.y - 0.5) < 0.06 }, using: &random)
            let fit = AimFitter.fit(data, starting: Self.plainCard, pictureWidth: 1920, pictureHeight: 1080, previous: nil, using: &random)
            let lens = fit.model.lenses[0]
            let k1 = lens.radial.first ?? 0
            let centre: Double = max(abs(lens.principalPoint.x - 0.5), abs(lens.principalPoint.y - 0.5))
            #expect(fit.stage == 2 && abs(k1) <= 0.03 && centre <= 0.012, "seed \(seed): stage \(fit.stage), k1 \(k1), \(lens.principalPoint)")
        }
    }

    @Test func aircraftCountOnceForTheInlierShare() throws {
        // Seven aircraft seen well (4 samples each) and one long wrong one (40 samples that agree with nothing): by samples only 41 % agree,
        // but by aircraft 7 of 8 do, so the fit is taken.
        var random = SkyRandom(seed: 26)
        let truth = Self.plainLens()
        let good = SkyFixtures.planeTracks(through: truth, perLens: 7, samples: 4, noise: Self.noise, using: &random)
        let wrong = (0..<40).map { index in
            AimCorrespondence(point: PixelPoint(x: Double.random(in: 0.05...0.95, using: &random), y: Double.random(in: 0.05...0.6, using: &random)),
                              direction: SkyFixtures.randomDirection(above: 0, using: &random), source: .plane,
                              at: SkyFixtures.aimEpoch.addingTimeInterval(Double(index)), object: "bad")
        }
        let attempt = AimFitter.attempt(good + wrong, starting: Self.plainCard, pictureWidth: 1920, pictureHeight: 1080, previous: nil,
                                        using: &random)
        #expect(attempt.accepted && attempt.fit.stage == 1 && attempt.fit.inliers == 28 && attempt.fit.planes == 7, "\(attempt.notes)")
    }

    @Test func preciseIsJudgedOnTheStars() throws {
        // 30 stars (to 0.03°) among 60 plane samples (to 0.4°): all together they are about 0.2° off, but precise is about the stars, whose
        // own RMS is far under 0.15°.
        var random = SkyRandom(seed: 27)
        let truth = Self.plainLens()
        let data = SkyFixtures.planeTracks(through: truth, perLens: 10, samples: 6, noise: 0.4, using: &random)
            + SkyFixtures.stars(through: truth, perLens: 30, noise: Self.starNoise, using: &random)
        let fit = AimFitter.fit(data, starting: Self.plainCard, pictureWidth: 1920, pictureHeight: 1080, previous: nil, using: &random)
        let lens = fit.lenses[0]
        #expect(fit.quality == .precise && lens.starMatches == 30 && fit.residualDegrees > 0.15, "\(lens)")
        #expect((lens.starResidualDegrees ?? 1) < 0.05 && (lens.planeResidualDegrees ?? 0) > 0.15, "\(lens)")
    }

    @Test func oneAircraftIsOneMatchForAMovedCamera() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(SkyFixtures.aimEpoch.addingTimeInterval(7_200))
        let store = Self.store(in: directory, clock: clock)
        #expect(await store.add(Self.planes.data)?.quality == .good)
        // One aircraft matched wrongly, its 12 samples all 5° off: one match, not 12, so the camera has not moved.
        var random = SkyRandom(seed: 23)
        var wrong: [AimCorrespondence] = []
        while wrong.count < 12 {
            let point = PixelPoint(x: Double.random(in: 0.05...0.45, using: &random), y: Double.random(in: 0.1...0.5, using: &random))
            guard let seen = SkyFixtures.truthDual.direction(at: point) else { continue }
            wrong.append(AimCorrespondence(point: point, direction: SkyFixtures.offset(seen.direction, by: 5, toward: 2), source: .plane,
                                           at: clock.value, object: "c0ffee"))
        }
        _ = await store.add(wrong)
        #expect(await store.current() != nil)
        #expect(await store.status().note == nil)
    }

    // MARK: Projections

    struct ProjectionCase: Sendable, CustomTestStringConvertible {
        var name: String
        var truth: SkyCameraModel
        var width: Int
        var height: Int
        var card: SkyCameraModel
        /// Stars for each lens: enough for 10 in each of its bottom quadrants, where only a strip above 5° is sky; under 300.
        var stars: Int
        var testDescription: String { name }
    }

    static let projectionCases: [ProjectionCase] = [
        // Picture sizes with square pixels for each truth (its fields of view as a frame's aspect).
        ProjectionCase(name: "equidistant", truth: SkyFixtures.truthEquidistant, width: 1600, height: 1200,
                       card: .initial(facing: 135, tilt: 30, pictureWidth: 1600, pictureHeight: 1200), stars: 170),
        ProjectionCase(name: "cylindrical", truth: SkyFixtures.truthCylindrical, width: 1496, height: 1000,
                       card: .initial(facing: 70, tilt: 12, pictureWidth: 1496, pictureHeight: 1000), stars: 260),
        ProjectionCase(name: "equirectangular", truth: SkyFixtures.truthEquirectangular, width: 2000, height: 900,
                       card: .initial(facing: 260, tilt: 12, pictureWidth: 2000, pictureHeight: 900, layout: .single), stars: 200),
        ProjectionCase(name: "equirectangular dual", truth: SkyFixtures.truthEquirectangularDual, width: 4256, height: 1888,
                       card: .initial(facing: 0, tilt: 20, pictureWidth: 4256, pictureHeight: 1888), stars: 260),
    ]

    /// Each lens's projection is chosen by the fit (the card starts every lens rectilinear), and the lens is fitted precisely.
    @Test(arguments: projectionCases) func eachProjectionIsChosenAndFitted(_ test: ProjectionCase) throws {
        var random = SkyRandom(seed: 13)
        let data = SkyFixtures.stars(through: test.truth, perLens: test.stars, noise: Self.starNoise, using: &random)
        let fit = AimFitter.fit(data, starting: test.card, pictureWidth: test.width, pictureHeight: test.height, previous: nil, using: &random)
        #expect(fit.model.lenses.map(\.projection) == test.truth.lenses.map(\.projection), "\(fit.model.lenses.map(\.projection))")
        #expect(fit.quality == .precise && fit.stage == 3, "\(fit.lenses)")
        let errors = data.map { Self.pixelError(fit.model, test.truth, at: $0.point, width: test.width, height: test.height) }
        #expect(Self.rms(errors) <= 1.5, "RMS \(Self.rms(errors)) px, worst \(errors.max() ?? 0) px")
    }

    @Test func theProjectionDoesNotFlap() throws {
        // A plain rectilinear lens seen only within about 5° of its axis, where every projection looks alike: a lens stored as equidistant,
        // fitted at stage 2 (where the projection is chosen), stays equidistant, as the candidates are within 10 % of each other …
        let truth = SkyCameraModel(layout: .single, seam: 0.5, lenses: [SkyCameraModel.Lens(
            yaw: 100, pitch: 30, roll: 0, horizontalFOV: 100, verticalFOV: SkyCameraModel.Lens.verticalFOV(horizontalFOV: 100, frameAspect: 16.0 / 9),
            principalPoint: PixelPoint(x: 0.5, y: 0.5), radial: [])])
        var stored = SkyCameraModel.initial(facing: 98, tilt: 28, pictureWidth: 1920, pictureHeight: 1080)
        stored.lenses[0].projection = .equidistant
        stored.lenses[0].verticalFOV = SkyCameraModel.Lens.verticalFOV(horizontalFOV: 100, frameAspect: 16.0 / 9, projection: .equidistant)
        var random = SkyRandom(seed: 14)
        let near = SkyFixtures.stars(through: truth, perLens: 60, noise: Self.starNoise, where: { abs($0.x - 0.5) < 0.05 && abs($0.y - 0.5) < 0.08 },
                                     using: &random)
        let kept = AimFitter.fit(near, starting: stored, pictureWidth: 1920, pictureHeight: 1080, previous: nil, using: &random)
        #expect(kept.stage == 2 && kept.model.lenses[0].projection == .equidistant, "\(kept.lenses) \(kept.model.lenses[0])")
        // … until matches all over the frame tell them apart.
        let wide = SkyFixtures.stars(through: truth, perLens: 120, noise: Self.starNoise, using: &random)
        let switched = AimFitter.fit(wide, starting: kept.model, pictureWidth: 1920, pictureHeight: 1080, previous: kept, using: &random)
        #expect(switched.model.lenses[0].projection == .rectilinear && switched.quality == .precise, "\(switched.lenses)")
    }

    // MARK: Robustness

    @Test func aLensPointedStraightUpStillFits() throws {
        // At pitch ±90° yaw and roll turn about the same axis; the fit turns the lens by small rotations of its own axes, so a lens looking
        // straight up (or just short of it) is fitted like any other, from a card that is 5° off and turned 34° about the zenith.
        for pitch in [90.0, 89.97] {
            let truth = SkyCameraModel(layout: .single, seam: 0.5, lenses: [SkyCameraModel.Lens(
                yaw: 30, pitch: pitch, roll: 4, horizontalFOV: 100,
                verticalFOV: SkyCameraModel.Lens.verticalFOV(horizontalFOV: 100, frameAspect: 16.0 / 9),
                principalPoint: PixelPoint(x: 0.5, y: 0.5), radial: [])])
            var random = SkyRandom(seed: 15)
            let data = SkyFixtures.stars(through: truth, perLens: 120, noise: Self.starNoise, using: &random)
            let card = SkyCameraModel.initial(facing: 0, tilt: 85, pictureWidth: 1920, pictureHeight: 1080)
            let fit = AimFitter.fit(data, starting: card, pictureWidth: 1920, pictureHeight: 1080, previous: nil, using: &random)
            let errors = data.map { Self.pixelError(fit.model, truth, at: $0.point, width: 1920, height: 1080) }
            #expect(fit.quality == .precise && Self.rms(errors) <= 1, "pitch \(pitch): \(fit.lenses), RMS \(Self.rms(errors)) px")
        }
    }

    @Test func aHugeProjectionIsAnOutlierNotAHugeError() throws {
        // Near a rectilinear lens's side (almost 90° off its axis) a direction projects millions of frames away: its error is capped, so
        // it counts as an outlier (no weight) and never as a gigantic squared error; a missing projection counts the same.
        let cap = AimFitter.outlierWidths * 1920   // a quarter of the picture's width
        let capped = AimFitter.robustCost(pixels: nil, cap: cap)
        #expect(capped.isFinite && capped == AimFitter.robustCost(pixels: 1e15, cap: cap) && AimFitter.robustCost(pixels: .infinity, cap: cap) == capped)
        #expect(AimFitter.robustWeight(pixels: 1e15, cap: cap) == 0 && AimFitter.robustWeight(pixels: nil, cap: cap) == 0)
        #expect(AimFitter.robustWeight(pixels: 2, cap: cap) == 1 && abs(AimFitter.robustWeight(pixels: 6, cap: cap) - 0.5) <= 1e-12, "Huber, δ = 3 px")
        let small = AimFitter.robustCost(pixels: 2, cap: cap), larger = AimFitter.robustCost(pixels: 6, cap: cap)
        #expect(small == 2 && larger == 3 * (6 - 1.5) && larger < capped)

        // In a fit: a match whose direction is 89.999999° off the axis of a lens with no fold (it projects about 10⁷ frame widths out)
        // changes nothing.
        var random = SkyRandom(seed: 16)
        var truth = SkyFixtures.truthSingle
        truth.lenses[0].radial = []
        let data = SkyFixtures.stars(through: truth, perLens: 120, noise: Self.starNoise, using: &random)
        let axes = truth.lenses[0].axes
        let side = SkyMath.direction(of: axes.right * cos(1e-6 * Self.radians) + axes.forward * sin(1e-6 * Self.radians))
        #expect((truth.project(side, lens: 0)?.x ?? 0) > 1e5, "it does project far out")
        let bad = AimCorrespondence(point: PixelPoint(x: 0.97, y: 0.5), direction: side, source: .star, at: SkyFixtures.aimEpoch, object: "9999")
        var again = SkyRandom(seed: 17), same = SkyRandom(seed: 17)
        let clean = AimFitter.fit(data, starting: Self.singleCard, pictureWidth: 1920, pictureHeight: 1080, previous: nil, using: &again)
        let spoiled = AimFitter.fit(data + [bad], starting: Self.singleCard, pictureWidth: 1920, pictureHeight: 1080, previous: nil, using: &same)
        let difference = data.map { Self.pixelError(spoiled.model, clean.model, at: $0.point, width: 1920, height: 1080) }
        #expect((difference.max() ?? .infinity) <= 0.25 && spoiled.inliers == clean.inliers, "\(difference.max() ?? 0) px")
    }

    @Test func theInverseFallsBackWhenNewtonStalls() throws {
        // The truth single lens's terms (k1 −0.25, k2 0.08, k3 −0.002) far out, where the polynomial is steep and wavy: ten Newton steps from
        // r = r_d do not converge there (from r_d ≈ 5), so a bracketed search finds the radius instead.
        let centre = PixelPoint(x: 0.5, y: 0.5)
        let steep = SkyCameraModel.Lens(yaw: 0, pitch: 0, roll: 0, horizontalFOV: 100, verticalFOV: 67.67, principalPoint: centre,
                                        radial: [-0.25, 0.08, -0.002])
        for target in stride(from: 0.5, through: 60, by: 0.5) {
            let radius = try #require(steep.undistortedRadius(target), "r_d \(target)")
            let error: Double = abs(steep.distortedRadius(radius) - target)
            #expect(error <= 1e-12 * max(1, target) && steep.isMonotonic(upToSquaredRadius: radius * radius), "r_d \(target) → r \(radius)")
        }
        // Next to a fold, where the slope goes to zero and Newton crawls (k1 −0.3, k2 0.05, k3 −0.004): every r_d up to the largest is found.
        let folding = SkyCameraModel.Lens(yaw: 0, pitch: 0, roll: 0, horizontalFOV: 100, verticalFOV: 67.67, principalPoint: centre,
                                          radial: [-0.3, 0.05, -0.004])
        var low = 0.0, high = 4.0   // the fold's r², by halving on `isMonotonic`
        for _ in 0..<200 { let middle = (low + high) / 2; if folding.isMonotonic(upToSquaredRadius: middle) { low = middle } else { high = middle } }
        let peak = folding.distortedRadius(low.squareRoot())
        for fraction in [0.5, 0.9, 0.99, 0.999, 0.999_9, 0.999_99, 0.999_999] {
            let radius = try #require(folding.undistortedRadius(peak * fraction), "\(fraction) of the peak")
            #expect(abs(folding.distortedRadius(radius) - peak * fraction) <= 1e-12 && radius * radius < high, "\(fraction): \(radius)")
        }
        #expect(folding.undistortedRadius(peak * 1.001) == nil, "past the fold there is no radius")
        // And through the picture: the direction of a pixel far out in a lens's frame.
        let model = SkyCameraModel(layout: .single, seam: 0.5, lenses: [steep])
        let far = PixelPoint(x: 0.5 + 0.5 * 8 / tan(50 * Self.radians), y: 0.5)
        let direction = try #require(model.direction(at: far))
        let back = try #require(model.project(direction.direction, lens: 0))
        #expect(abs(back.x - far.x) <= 1e-9 && abs(back.y - far.y) <= 1e-9, "\(back)")
    }

    @Test func aRotationFromThreeDirections() throws {
        // Horn's method: three directions and where a rotation takes them give back that rotation, exactly.
        let axis = SIMD3(0.3, -0.5, 0.81), angle = 0.7
        let unit = axis / SkyMath.length(axis)
        func turned(_ v: SIMD3<Double>) -> SIMD3<Double> {
            v * cos(angle) + SkyMath.cross(unit, v) * sin(angle) + unit * SkyMath.dot(unit, v) * (1 - cos(angle))
        }
        let sources = [SIMD3(1.0, 0, 0), SIMD3(0.0, 0.6, 0.8), SIMD3(-0.48, 0.6, 0.64)]
        let rotation = try #require(AimFitter.rotation(from: sources, to: sources.map(turned)))
        for probe in [SIMD3(0.0, 0, 1), SIMD3(0.6, 0.8, 0), SIMD3(-0.36, 0.48, 0.8)] {
            #expect(SkyMath.length(rotation.applied(to: probe) - turned(probe)) <= 1e-12, "\(probe)")
        }
        // Parallel directions do not fix a rotation.
        #expect(AimFitter.rotation(from: [SIMD3(1.0, 0, 0), SIMD3(1.0, 0, 0)], to: [SIMD3(0.0, 1, 0), SIMD3(0.0, 1, 0)]) == nil)
    }

    // MARK: Stages, tolerances and the summary

    @Test func stagesFollowCountsAndCoverage() {
        let model = Self.singleCard
        func matches(_ cells: [(x: Double, y: Double, count: Int)], objects: Int? = nil) -> [AimCorrespondence] {
            var made: [AimCorrespondence] = []
            for cell in cells {
                for _ in 0..<cell.count {
                    let object = objects.map { made.count % $0 } ?? made.count
                    made.append(AimCorrespondence(point: PixelPoint(x: cell.x, y: cell.y), direction: SkyDirection(azimuth: 0, elevation: 30),
                                                  source: .plane, at: SkyFixtures.aimEpoch, object: "\(object)"))
                }
            }
            return made
        }
        // 3×3 cells (x and y 1/6, 1/2, 5/6) by quadrant: the top row and the left column hold the top-left quadrant, and so on.
        #expect(AimFitter.stage(for: matches([(0.2, 0.2, 7)]), model: model, lens: 0) == 0, "7 matches")
        #expect(AimFitter.stage(for: matches([(0.2, 0.2, 8)], objects: 4), model: model, lens: 0) == 0, "8 matches of 4 objects")
        #expect(AimFitter.stage(for: matches([(0.2, 0.2, 8)], objects: 5), model: model, lens: 0) == 1)
        let quadrants = [(0.2, 0.2, 10), (0.8, 0.2, 10), (0.2, 0.8, 10), (0.8, 0.8, 10)]
        #expect(AimFitter.stage(for: matches(quadrants.map { ($0.0, $0.1, $0.2) }), model: model, lens: 0) == 2)
        // From stage 2, 8 objects: 40 samples of 7 aircraft, however spread, are stage 1 (a few great circles); of 8, stage 2.
        #expect(AimFitter.stage(for: matches(quadrants.map { ($0.0, $0.1, $0.2) }, objects: 7), model: model, lens: 0) == 1)
        #expect(AimFitter.stage(for: matches(quadrants.map { ($0.0, $0.1, $0.2) }, objects: 8), model: model, lens: 0) == 2)
        #expect(AimFitter.stage(for: matches([(0.2, 0.2, 11), (0.8, 0.2, 10), (0.2, 0.8, 10), (0.8, 0.8, 9)]), model: model, lens: 0) == 1,
                "one quadrant short")
        // 150 over 5 cells (the four corners and the centre): stage 2; over 6, stage 3; 300 over them, stage 4.
        let five = [(0.15, 0.15, 30), (0.85, 0.15, 30), (0.15, 0.85, 30), (0.85, 0.85, 30), (0.5, 0.5, 30)]
        #expect(AimFitter.stage(for: matches(five.map { ($0.0, $0.1, $0.2) }), model: model, lens: 0) == 2)
        let six = five.map { ($0.0, $0.1) } + [(0.5, 0.15)]
        #expect(AimFitter.stage(for: matches(six.map { ($0.0, $0.1, 25) }), model: model, lens: 0) == 3, "150 over 6 cells")
        #expect(AimFitter.stage(for: Array(matches(six.map { ($0.0, $0.1, 50) }).dropLast()), model: model, lens: 0) == 3, "299 is not 300")
        #expect(AimFitter.stage(for: matches(six.map { ($0.0, $0.1, 50) }), model: model, lens: 0) == 4, "300")
        // A cell is covered by 3 matches, not by one stray match.
        let stray = five.map { ($0.0, $0.1, $0.2) } + [(0.5, 0.15, 2)]
        #expect(AimFitter.stage(for: matches(stray), model: model, lens: 0) == 2)

        // A dual camera's lens, whose outer bottom corner is usually ground, needs 10 in 3 of its quadrants, and stops at stage 3.
        let dual = Self.card
        let three = matches([(0.05, 0.1, 11), (0.4, 0.1, 10), (0.4, 0.9, 10), (0.05, 0.9, 9)])   // its frame's x is twice the picture's
        #expect(AimFitter.stage(for: three, model: dual, lens: 0) == 2 && AimFitter.stage(for: three, model: model, lens: 0) == 1)
        let two = matches([(0.05, 0.1, 20), (0.2, 0.1, 20)])
        #expect(AimFitter.stage(for: two, model: dual, lens: 0) == 1)
        let many = matches([(0.05, 0.1, 60), (0.2, 0.1, 60), (0.05, 0.5, 60), (0.2, 0.5, 60), (0.4, 0.1, 30), (0.4, 0.5, 30)])
        #expect(AimFitter.stage(for: many, model: dual, lens: 0) == 3 && AimFitter.stage(for: many.map { var m = $0; m.point.x *= 2; return m },
                                                                                          model: model, lens: 0) == 4)

        // And a lens counts only its own pixels, none in the seam band.
        let inBand = matches([(0.497, 0.3, 20), (0.503, 0.3, 20)])
        #expect(AimFitter.stage(for: inBand, model: dual, lens: 0) == 0 && AimFitter.stage(for: inBand, model: dual, lens: 1) == 0)
        let leftOnly = matches([(0.1, 0.1, 10), (0.4, 0.1, 10), (0.1, 0.9, 10), (0.4, 0.9, 10)])
        #expect(AimFitter.stage(for: leftOnly, model: dual, lens: 0) == 2 && AimFitter.stage(for: leftOnly, model: dual, lens: 1) == 0)
    }

    @Test func matchToleranceFollowsTheAim() {
        #expect(AimFitter.matchTolerance(.rough) == 15 && AimFitter.matchTolerance(.good) == 1.5 && AimFitter.matchTolerance(.precise) == 0.75)
    }

    @Test func theStatusSummarizesTheFit() throws {
        let fit = Self.planes.fit
        let updated = SkyFixtures.aimEpoch
        let status = fit.status(updated: updated, note: nil)
        #expect(status.quality == .good && status.planes == 12 && status.stars == 0 && status.updated == updated && status.note == nil)
        #expect(status.residualPixels == fit.residualPixels && status.lenses.count == 2)
        #expect(status.lenses.map(\.quality) == [.good, .good] && status.lenses.map(\.planes) == [6, 6])
        // A camera that is not aimed yet has no residual to show.
        var random = SkyRandom(seed: 99)
        let none = AimFitter.fit([], starting: Self.card, pictureWidth: Self.width, pictureHeight: Self.height, previous: nil, using: &random)
        #expect(none.status(updated: nil, note: nil).residualPixels == nil && none.stage == 0)
        // Status and fit survive JSON.
        let decoded = try JSONDecoder().decode(SkyAimStatus.self, from: JSONEncoder().encode(status))
        #expect(decoded == status)
        let fitBack = try JSONDecoder().decode(AimFit.self, from: JSONEncoder().encode(fit))
        #expect(fitBack == fit)
        // A status saved before it had lenses or a note still reads.
        let older = try JSONDecoder().decode(SkyAimStatus.self, from: Data(#"{"quality":"good","planes":3,"stars":0}"#.utf8))
        #expect(older.quality == .good && older.planes == 3 && older.lenses.isEmpty && older.note == nil && older.residualPixels == nil)
    }

    // MARK: The store

    /// A store in a fresh folder whose clock reads `clock`.
    static func store(in directory: TemporaryDirectory, clock: Box<Date>, log: Log = Log(category: "Sky"), seed: UInt64 = 21) -> SkyAimStore {
        SkyAimStore(directory: directory.url, log: log, start: card, pictureWidth: width, pictureHeight: height, now: { clock.value }, seed: seed)
    }

    @Test func theStoreKeepsItsAimAcrossARestart() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(SkyFixtures.aimEpoch.addingTimeInterval(600))
        let store = Self.store(in: directory, clock: clock)
        let fit = try #require(await store.add(Self.planes.data))
        #expect(fit.quality == .good)
        #expect(await store.status().updated == clock.value)
        let again = Self.store(in: directory, clock: clock)
        #expect(await again.current() == fit)
        #expect(await again.correspondences() == Self.planes.data)
        let before = await store.status(), after = await again.status()
        #expect(after == before)
        // The files are private, as the bridge's other state is.
        for name in [SkyAimStore.aimFileName, SkyAimStore.matchesFileName] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.file(name).path(percentEncoded: false))
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "\(name)")
        }
    }

    @Test func theStoreKeepsTheLatestMatchesOfEachSource() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(SkyFixtures.aimEpoch.addingTimeInterval(40 * 86_400))
        let store = Self.store(in: directory, clock: clock)
        func match(_ source: AimCorrespondence.Source, _ index: Int, at: Date) -> AimCorrespondence {
            AimCorrespondence(point: PixelPoint(x: 0.3, y: 0.3), direction: SkyDirection(azimuth: 300, elevation: 30), source: source, at: at,
                              object: "\(index)")
        }
        // Plane matches 31 days old are dropped; of 2,100 star matches the latest 2,000 are kept, whatever order they came in.
        let old = (0..<20).map { match(.plane, $0, at: clock.value.addingTimeInterval(-31 * 86_400)) }
        let recent = (0..<20).map { match(.plane, 100 + $0, at: clock.value.addingTimeInterval(-29 * 86_400)) }
        let stars = (0..<2_100).map { match(.star, 1_000 + $0, at: clock.value.addingTimeInterval(-Double(2_100 - $0))) }
        _ = await store.add(old + recent)
        _ = await store.add(Array(stars.reversed()))
        let kept = await store.correspondences()
        #expect(kept.filter { $0.source == .plane }.map(\.object).sorted() == recent.map(\.object).sorted())
        let keptStars = Set(kept.filter { $0.source == .star }.map(\.object))
        #expect(keptStars == Set(stars.suffix(2_000).map(\.object)))
        // And so after a restart, from the file.
        let again = Self.store(in: directory, clock: clock)
        #expect(Set(await again.correspondences().map(\.object)) == Set(kept.map(\.object)))
    }

    @Test func theStoreRefitsEveryTenMatchesOrEveryHour() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(SkyFixtures.aimEpoch.addingTimeInterval(600))
        let store = Self.store(in: directory, clock: clock)
        let data = Self.planes.data
        _ = await store.add(Array(data[0..<20]))
        let first = try #require(await store.lastAttempt())
        clock.set(clock.value.addingTimeInterval(60))
        _ = await store.add(Array(data[20..<29]))
        #expect(await store.lastAttempt() == first, "9 new matches wait")
        _ = await store.add(Array(data[29..<30]))
        #expect(await store.lastAttempt() == clock.value, "the 10th refits")
        clock.set(clock.value.addingTimeInterval(60))
        _ = await store.add(Array(data[30..<33]))
        #expect(await store.lastAttempt() != clock.value, "3 new matches wait")
        clock.set(clock.value.addingTimeInterval(3_600))
        _ = await store.add(Array(data[33..<34]))
        #expect(await store.lastAttempt() == clock.value, "after an hour, one is enough")
        // The rest arrive: the aim is good, and `add` hands back the fit it accepted.
        clock.set(clock.value.addingTimeInterval(60))
        let fit = await store.add(Array(data[34...]))
        #expect(fit?.quality == .good)
        #expect(await store.current() == fit)
    }

    @Test func aNewCardKeepsTheMatches() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(SkyFixtures.aimEpoch.addingTimeInterval(600))
        let store = Self.store(in: directory, clock: clock)
        let fit = try #require(await store.add(Self.planes.data))
        // A new facing on the card changes nothing once there is a fit: the matches say where the camera looks.
        await store.setStart(.initial(facing: 30, tilt: 10, pictureWidth: Self.width, pictureHeight: Self.height), pictureWidth: Self.width,
                             pictureHeight: Self.height)
        #expect(await store.current() == fit)
        // A new layout (one lens instead of two) drops the fit, whose lenses no longer apply, and fits the same matches again from the new
        // card; and so after a restart, from the files.
        let single = SkyCameraModel.initial(facing: 0, tilt: 20, pictureWidth: Self.width, pictureHeight: Self.height, layout: .single)
        await store.setStart(single, pictureWidth: Self.width, pictureHeight: Self.height)
        #expect(await store.current()?.model.layout != .dual)
        #expect(await store.correspondences() == Self.planes.data)
        let again = SkyAimStore(directory: directory.url, log: Log(category: "Sky"), start: single, pictureWidth: Self.width,
                                pictureHeight: Self.height, now: { clock.value }, seed: 21)
        #expect(await again.current()?.model.layout != .dual)
        #expect(await again.correspondences() == Self.planes.data)
    }

    @Test func aStarAimIsNotMovedByPlanes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(SkyFixtures.aimEpoch.addingTimeInterval(7_200))
        let store = Self.store(in: directory, clock: clock)
        // A precise aim from stars alone has no plane RMS to hold planes to: planes 0.4–0.75° off (as plane matches are; past half a precise
        // lens's tolerance, so only the missing plane RMS keeps them from counting) never reset it …
        var random = SkyRandom(seed: 28)
        let fit = try #require(await store.add(SkyFixtures.stars(through: SkyFixtures.truthDual, perLens: 170, noise: Self.starNoise,
                                                                   using: &random)))
        #expect(fit.quality == .precise && fit.planeResidualDegrees == nil)
        _ = await store.add(Self.planesOff(12, by: 0.4...0.75, seed: 29, at: clock.value))
        #expect(await store.current() != nil)
        #expect(await store.status().note == nil)

        // … and with near-perfect plane matches in the fit (3 × their RMS is a few hundredths of a degree), half the lens's match tolerance
        // still floors what is off: planes 0.3° off are no move …
        let other = try TemporaryDirectory()
        defer { other.remove() }
        let precise = Self.store(in: other, clock: clock)
        let planes = SkyFixtures.planeTracks(through: SkyFixtures.truthDual, perLens: 6, samples: 6, noise: 0.01, using: &random)
        let both = try #require(await precise.add(planes + SkyFixtures.stars(through: SkyFixtures.truthDual, perLens: 170, noise: Self.starNoise,
                                                                              using: &random)))
        #expect(both.quality == .precise && (both.planeResidualDegrees ?? 1) < 0.02)
        _ = await precise.add(Self.planesOff(10, by: 0.3...0.3, seed: 30, at: clock.value))
        #expect(await precise.current() != nil)
        // … while planes 2° off are.
        _ = await precise.add(Self.planesOff(10, by: 2...2, seed: 31, at: clock.value))
        #expect(await precise.current() == nil)
        #expect(await precise.status().note == SkyAimStore.movedNote)
    }

    @Test func onePassOfAnAircraftKeepsAtMostTwelveSamples() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(SkyFixtures.aimEpoch.addingTimeInterval(600))
        let store = Self.store(in: directory, clock: clock)
        // One aircraft seen for a long time: 1,800 samples along 40° of its great circle, in the left lens.
        let start = SkyDirection(azimuth: 285, elevation: 22)
        var track: [AimCorrespondence] = []
        for sample in 0..<1_800 {
            let direction = SkyFixtures.offset(start, by: 40 * Double(sample) / 1_799, toward: 80 * Self.radians)
            let hit = try #require(SkyFixtures.truthDual.project(direction).first { $0.lens == 0 && !Self.card.isInSeamBand($0.point) })
            track.append(AimCorrespondence(point: hit.point, direction: direction, source: .plane,
                                           at: SkyFixtures.aimEpoch.addingTimeInterval(Double(sample) / 5), object: "a1b2c3"))
        }
        _ = await store.add(track)
        // One pass keeps at most 12 of them, each at least 1° from the others, spread along the whole track: its first, and one within 1° of
        // its end.
        let kept = await store.correspondences()
        let end: Double = SkyMath.separation(kept.last?.direction ?? start, track[track.count - 1].direction)
        #expect(kept.count == 12 && kept.first == track.first && end < 1, "\(kept.count), the last \(end)° from the end")
        for (index, one) in kept.enumerated() {
            for other in kept[(index + 1)...] { #expect(SkyMath.separation(one.direction, other.direction) >= 1) }
        }
        // A short pass (1.7° of track, 76 samples) keeps the two 1° apart; a second pass of the long one adds 12 more; stars are all kept.
        _ = await store.add(Array(track.prefix(76)).map { var m = $0; m.object = "d4e5f6"; return m })
        #expect(await store.correspondences().filter { $0.object == "d4e5f6" }.count == 2)
        _ = await store.add(track)
        #expect(await store.correspondences().filter { $0.object == "a1b2c3" }.count == 24)
        var random = SkyRandom(seed: 32)
        let stars = SkyFixtures.stars(through: SkyFixtures.truthDual, perLens: 20, noise: Self.starNoise, using: &random)
        _ = await store.add(stars)
        #expect(await store.correspondences().filter { $0.source == .star } == stars)
    }

    @Test func aTornLastLineIsSkipped() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(SkyFixtures.aimEpoch.addingTimeInterval(600))
        let store = Self.store(in: directory, clock: clock)
        _ = await store.add(Array(Self.planes.data.prefix(5)))
        // A crash mid-line, then a line of a later version.
        let file = directory.file(SkyAimStore.matchesFileName)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"at":17928972000"#.utf8))
        try handle.close()
        let again = Self.store(in: directory, clock: clock)
        #expect(await again.correspondences() == Array(Self.planes.data.prefix(5)))
        // The next match starts on a line of its own.
        _ = await again.add(Array(Self.planes.data[5..<6]))
        let third = Self.store(in: directory, clock: clock)
        #expect(await third.correspondences() == Array(Self.planes.data.prefix(6)))
    }

    @Test func aRejectedFitIsLoggedOnce() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let router = LogRouter()
        let sink = Sink()
        router.addSink(sink)
        let clock = Box(SkyFixtures.aimEpoch.addingTimeInterval(600))
        let store = Self.store(in: directory, clock: clock, log: Log(category: "Sky", router: router))
        let before = try #require(await store.add(Self.planes.data))
        #expect(before.quality == .good)
        // Then many matches that agree with nothing: fewer than 60 % of each lens's matches fit any aim, so no new fit is taken …
        var random = SkyRandom(seed: 22)
        for round in 0..<2 {
            var junk: [AimCorrespondence] = []
            for index in 0..<80 {
                let x = index % 2 == 0 ? Double.random(in: 0.05...0.45, using: &random) : Double.random(in: 0.55...0.95, using: &random)
                junk.append(AimCorrespondence(point: PixelPoint(x: x, y: Double.random(in: 0.1...0.6, using: &random)),
                                              direction: SkyFixtures.randomDirection(above: 0, using: &random), source: .star,
                                              at: clock.value, object: "\(round)-\(index)"))
            }
            #expect(await store.add(junk) == nil)
        }
        // … the aim stays as it was, and that is said once.
        #expect(await store.current() == before)
        let said = sink.entries.value.filter { $0.message.contains("not refined") }
        #expect(said.count == 1, "\(sink.entries.value.map(\.message))")
    }

    final class Sink: LogSink {
        let entries = Box<[LogEntry]>([])
        func record(_ entry: LogEntry) { entries.update { $0.append(entry) } }
    }
}
