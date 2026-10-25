import Foundation

/// Fits a sky camera's aim to its matches (`AimCorrespondence`): where things were seen in the original picture, and where in the sky they
/// really were. Each lens is fitted on its own, to the matches it owns outside the seam band (a dual camera's halves share nothing but the
/// location), in four steps:
/// 1. **RANSAC**: 200 samples of 3 of the lens's matches, each solved for the lens's rotation alone (Horn's method) from where the lens
///    sees their pixels now; the rotation most matches agree with, within `matchTolerance` of the previous aim's quality, wins. When fewer
///    than 60 % of them agree within it (an aim that was precise where it had matches can be wrong elsewhere), the fit is tried again at the
///    next looser tolerance, as a fit with fewer would not be accepted anyway.
/// 2. **Levenberg–Marquardt** (at most 50 iterations) over the terms the lens's stage frees, on the matches' pixel errors in the original
///    picture, with Huber weights (δ = 3 px) and a ridge prior on the correction terms. The lens is turned by small rotations of its own
///    axes, so a lens looking straight up fits like any other. A pixel error past a quarter of the picture's width, or a direction the
///    lens has no point for, is an outlier: it stops counting, whatever its size.
/// 3. **Inliers.** After each refinement the inliers are judged again, at the tolerance the residual earns: three standard deviations
///    (from the median error), rounded up to one of the match tolerances (0.75°, 1.5°, 15°), never looser than before. A wrong match
///    within the rough 15° then no longer spoils the residual of a good aim. When the tolerance earned would cost the lens its stage, 1.5°
///    is tried; when that does too, the lens takes the lower stage rather than keep 15° (but never tightens itself out of a fit).
/// 4. **The projection.** Once a lens has the matches for stage 2 (40, over its frame), it is fitted in every projection
///    (`LensProjection.allCases`), and keeps the one with the lowest robust residual, unless its own is within 10 % of that, so that it
///    does not flap between fits. While its matches are fewer, it keeps the projection it has (the card's, or the one fitted before).
///
/// A lens's fit is then accepted only when at least 60 % of what it saw agrees (each star match counting once, and each aircraft once, by
/// at least half of its samples), its inliers' RMS is at most 1.1 × the previous aim's on them, and its picture is sane over its whole frame
/// (a 9×5 grid): its distortion does not fold, and a dual camera's lens is not moved more than 3 % of the picture's width by its
/// corrections. Otherwise, and while it has too few matches to fit, the lens keeps its previous aim.
///
/// **Stages** (`stage(for:model:lens:)`), of a lens's inliers:
/// - 0: fewer than 8 matches, or of fewer than 5 objects: not fitted (the card's model, or the previous aim, and rough);
/// - 1: the pose (yaw, pitch and roll) and the field of view (the vertical one following it, as the start's pixels are shaped);
/// - 2: at least 40, of at least 8 objects (aircraft and stars: a few aircraft are a few great circles, however many samples they have),
///   with 10 in each quadrant of the lens's frame (in 3 of its 4 for a dual camera's lens, whose outer bottom corner is usually ground):
///   also the principal point and k1;
/// - 3: at least 150, covering 6 of the 9 cells of a 3×3 grid on the frame: also k2, and the vertical field on its own;
/// - 4: a single lens only, at least 300: also k3. (A dual camera's halves keep to two terms: what is left after the camera's stitch is
///   small, and a third term would bend the ground's corners, where nothing is seen.)
///
/// Portable: Foundation's math and `SIMD3` only. It never logs (the store does): a caller learns what was not accepted from `attempt`.
enum AimFitter {
    // MARK: Pinned values

    static let ransacSamples = 200
    static let maximumIterations = 50
    /// Huber's δ, in pixels of the original picture: errors up to it count squared, larger ones linearly. It is also the data's scale
    /// against the ridge prior.
    static let huberPixels = 3.0
    /// A pixel error past this part of the picture's width is no match at all: it counts as an outlier, with no weight.
    static let outlierWidths = 0.25
    /// The ridge prior's standard deviations: the principal point (frame units, at the frame's centre), the vertical focal scale's ratio to
    /// the start's (relative), and the radial terms k1, k2 and k3 (at zero).
    static let principalPointSigma = 0.02
    static let verticalScaleSigma = 0.02
    static let radialSigmas = [0.1, 0.05, 0.02]
    /// What stage 1 needs, and stage 2 and up: matches and distinct objects.
    static let stageOneMatches = 8, stageOneObjects = 5, stageTwoObjects = 8
    static let minimumInlierShare = 0.6
    static let allowedGrowth = 1.1
    static let largestCorrection = 0.03
    static let projectionMargin = 1.1
    /// The stage from which a lens's projection is chosen.
    static let projectionStage = 2
    /// Levenberg–Marquardt stops when a step lowers the cost by less than this part of it: the terms are then within a small part of their
    /// own uncertainty of the optimum.
    static let convergence = 1e-8
    /// The tolerances an aim's inliers are judged at, tightest first (`matchTolerance` of precise, good and rough).
    static let tolerances = [0.75, 1.5, 15.0]

    /// The tolerance (degrees) within which a match agrees with an aim of `quality`: rough 15, good 1.5, precise 0.75. The flight and star
    /// matchers use it too.
    static func matchTolerance(_ quality: SkyAimQuality) -> Double {
        switch quality {
        case .rough: 15
        case .good: 1.5
        case .precise: 0.75
        }
    }

    /// The quality a lens's fit earns: precise with at least 25 star matches among its inliers whose own RMS (`starResidualDegrees`) is
    /// 0.15° or less; good from stage 1 with an RMS of all its inliers of 0.8° or less; otherwise rough.
    static func quality(stage: Int, residualDegrees: Double, starResidualDegrees: Double?, starMatches: Int) -> SkyAimQuality {
        guard stage >= 1, residualDegrees.isFinite else { return .rough }
        if starMatches >= 25, let stars = starResidualDegrees, stars <= 0.15 { return .precise }
        return residualDegrees <= 0.8 ? .good : .rough
    }

    /// The stage that `correspondences` (a fit's inliers) allow lens `lens` of `model`: they count only where they are its own pixels,
    /// outside the seam band. A 3×3 cell is covered by at least 3 of them, so that one stray match does not cover it.
    static func stage(for correspondences: [AimCorrespondence], model: SkyCameraModel, lens: Int) -> Int {
        let frame = model.frame(of: lens)
        let own = correspondences.filter { usable($0) && model.lens(at: $0.point) == lens && !model.isInSeamBand($0.point) }
        return stage(own.map { PixelPoint(x: ($0.point.x - frame.origin) / frame.width, y: $0.point.y) }, objects: own.map(objectKey),
                     dual: model.layout == .dual)
    }

    /// The stage of a lens's inliers, from their points in its frame and their objects; `dual` for a lens of a dual camera.
    static func stage(_ points: [PixelPoint], objects: [String], dual: Bool) -> Int {
        let distinct = Set(objects).count
        guard points.count >= stageOneMatches, distinct >= stageOneObjects else { return 0 }
        var quadrants = [0, 0, 0, 0], cells = Array(repeating: 0, count: 9)
        for point in points {
            quadrants[(point.x < 0.5 ? 0 : 1) + (point.y < 0.5 ? 0 : 2)] += 1
            cells[min(2, max(0, Int(point.y * 3))) * 3 + min(2, max(0, Int(point.x * 3)))] += 1
        }
        guard points.count >= 40, distinct >= stageTwoObjects, quadrants.filter({ $0 >= 10 }).count >= (dual ? 3 : 4) else { return 1 }
        guard points.count >= 150, cells.filter({ $0 >= 3 }).count >= 6 else { return 2 }
        return points.count >= 300 && !dual ? 4 : 3
    }

    /// A fit and what became of it: `accepted` when at least one lens's new fit was taken; `notes` say why a lens's was not.
    struct Attempt: Sendable {
        var fit: AimFit
        var accepted: Bool
        var notes: [String]
    }

    /// The fit of `correspondences`, from `starting` (normally `previous`'s model, or the card's before there is one). A lens whose new
    /// fit is not accepted keeps `previous`'s (or `starting`'s) lens; when no lens's is, the result is `previous` itself. `pictureWidth` and
    /// `pictureHeight` are the original picture's, in pixels. `generator` drives RANSAC (the store passes `SystemRandomNumberGenerator`,
    /// tests a seeded `SkyRandom`).
    static func fit(_ correspondences: [AimCorrespondence], starting: SkyCameraModel, pictureWidth: Int, pictureHeight: Int, previous: AimFit?,
                    using generator: inout some RandomNumberGenerator) -> AimFit {
        attempt(correspondences, starting: starting, pictureWidth: pictureWidth, pictureHeight: pictureHeight, previous: previous,
                using: &generator).fit
    }

    /// `fit`, saying whether a new fit was accepted and why a lens's was not.
    static func attempt(_ correspondences: [AimCorrespondence], starting: SkyCameraModel, pictureWidth: Int, pictureHeight: Int,
                        previous: AimFit?, using generator: inout some RandomNumberGenerator) -> Attempt {
        let width = Double(max(1, pictureWidth)), height = Double(max(1, pictureHeight))
        let count = min(starting.lensCount, starting.lenses.count)
        let earlier = previous.flatMap { $0.model.lensCount == starting.lensCount && $0.model.lenses.count >= count && $0.lenses.count >= count
            ? $0 : nil }
        var lenses = Array(starting.lenses.prefix(count))
        var fits: [AimFit.LensFit] = Array(repeating: .unfitted, count: count)
        var inlierSets: [[Sighting]] = Array(repeating: [], count: count)
        var planeErrors: [[Double]] = Array(repeating: [], count: count)
        var accepted = false, notes: [String] = []
        for index in 0..<count {
            let solver = LensSolver(model: starting, lens: index, correspondences: correspondences, width: width, height: height)
            let before = earlier?.model.lenses[index] ?? starting.lenses[index]
            let beforeFit = earlier?.lenses[index] ?? .unfitted
            // An inlier is within the tolerance of the lens's previous aim (rough before there is one).
            let tolerance = matchTolerance(earlier?.lenses[index].quality ?? .rough)
            guard let candidate = solver.bestFit(from: starting.lenses[index], tolerance: tolerance, using: &generator) else {
                // Too few matches to fit now (stage 0): the lens keeps its earlier aim, as when a fit is rejected (before there is one, the
                // card's model, not fitted).
                lenses[index] = before
                fits[index] = beforeFit
                continue
            }
            if let problem = solver.problem(with: candidate, before: before) {
                notes.append("\(solver.name): \(problem)")
                lenses[index] = before
                fits[index] = beforeFit
                continue
            }
            accepted = true
            lenses[index] = candidate.lens
            let inliers = candidate.inliers.map { solver.sightings[$0] }
            inlierSets[index] = inliers
            planeErrors[index] = candidate.inliers.filter { solver.sightings[$0].source == .plane }.map { candidate.errors[$0] }
            let stars = inliers.filter { $0.source == .star }
            let starErrors = candidate.inliers.filter { solver.sightings[$0].source == .star }.map { candidate.errors[$0] }
            let starResidual = starErrors.isEmpty ? nil : rms(starErrors)
            fits[index] = AimFit.LensFit(
                stage: candidate.stage,
                quality: quality(stage: candidate.stage, residualDegrees: candidate.residualDegrees, starResidualDegrees: starResidual,
                                 starMatches: stars.count),
                residualDegrees: candidate.residualDegrees, residualPixels: candidate.residualPixels, inliers: inliers.count,
                planes: Set(inliers.filter { $0.source == .plane }.map(\.object)).count, stars: Set(stars.map(\.object)).count,
                starMatches: stars.count, planeMatches: planeErrors[index].count,
                planeResidualDegrees: planeErrors[index].isEmpty ? nil : rms(planeErrors[index]), starResidualDegrees: starResidual)
        }
        if !accepted, let earlier { return Attempt(fit: earlier, accepted: false, notes: notes) }

        var model = starting
        model.lenses = lenses + starting.lenses.dropFirst(count)
        let fitted = fits.filter { $0.stage > 0 }
        let inlierCount = fitted.reduce(0) { $0 + $1.inliers }
        let pooled = { (value: (AimFit.LensFit) -> Double) -> Double in
            inlierCount > 0 ? (fitted.reduce(0) { $0 + Double($1.inliers) * value($1) * value($1) } / Double(inlierCount)).squareRoot() : 0
        }
        let planeCount = fitted.reduce(0) { $0 + $1.planeMatches }
        let planeResidual = planeCount > 0
            ? (fitted.reduce(0) { $0 + Double($1.planeMatches) * pow($1.planeResidualDegrees ?? 0, 2) } / Double(planeCount)).squareRoot()
            : nil
        // Objects counted once in the whole camera: from this fit's inliers, and for a lens that kept its earlier fit, that fit's counts.
        let kept = (0..<count).filter { inlierSets[$0].isEmpty && fits[$0].stage > 0 }
        let planes = Set(inlierSets.joined().filter { $0.source == .plane }.map(\.object)).count + kept.reduce(0) { $0 + fits[$1].planes }
        let stars = Set(inlierSets.joined().filter { $0.source == .star }.map(\.object)).count + kept.reduce(0) { $0 + fits[$1].stars }
        let fit = AimFit(model: model, stage: fits.map(\.stage).min() ?? 0, quality: SkyAimQuality.lowest(fits.map(\.quality)),
                         residualDegrees: pooled(\.residualDegrees), residualPixels: pooled(\.residualPixels), inliers: inlierCount,
                         planes: planes, stars: stars, lenses: fits, planeResidualDegrees: planeResidual)
        return Attempt(fit: fit, accepted: accepted, notes: notes)
    }

    // MARK: Robust weights

    /// Huber's cost of a pixel error (δ = `huberPixels`): e²/2 up to δ, δ(e − δ/2) past it. An error past `cap`, not finite or missing (no
    /// point for the direction) costs what `cap` does: it is an outlier, whose size no longer counts.
    static func robustCost(pixels error: Double?, cap: Double) -> Double {
        let size = error.map { $0.isFinite ? min(abs($0), cap) : cap } ?? cap
        return size <= huberPixels ? size * size / 2 : huberPixels * (size - huberPixels / 2)
    }

    /// The weight of a pixel error in a Levenberg–Marquardt step: 1 up to δ, δ/e past it (Huber), and none for an outlier (`robustCost`).
    static func robustWeight(pixels error: Double?, cap: Double) -> Double {
        guard let error, error.isFinite, abs(error) <= cap else { return 0 }
        return abs(error) <= huberPixels ? 1 : huberPixels / abs(error)
    }

    // MARK: Rotations

    /// A rotation of east-north-up vectors.
    struct Rotation: Sendable, Equatable {
        /// Row-major.
        var matrix: [Double]

        static let identity = Rotation(matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1])

        func applied(to vector: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(matrix[0] * vector.x + matrix[1] * vector.y + matrix[2] * vector.z,
                  matrix[3] * vector.x + matrix[4] * vector.y + matrix[5] * vector.z,
                  matrix[6] * vector.x + matrix[7] * vector.y + matrix[8] * vector.z)
        }
    }

    /// The rotation that best takes `sources` to `targets` (unit vectors, in pairs), by least squares: Horn's quaternion method (the
    /// eigenvector of the largest eigenvalue of his 4×4 matrix). Nil when they do not fix a rotation: no two of either are more than about
    /// 0.06° apart.
    static func rotation(from sources: [SIMD3<Double>], to targets: [SIMD3<Double>]) -> Rotation? {
        guard sources.count == targets.count, spread(sources), spread(targets) else { return nil }
        var s = [Double](repeating: 0, count: 9)   // Σ source targetᵀ
        for (source, target) in zip(sources, targets) {
            for a in 0..<3 { for b in 0..<3 { s[a * 3 + b] += source[a] * target[b] } }
        }
        let (xx, xy, xz, yx, yy, yz, zx, zy, zz) = (s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8])
        let n: [[Double]] = [
            [xx + yy + zz, yz - zy, zx - xz, xy - yx],
            [yz - zy, xx - yy - zz, xy + yx, zx + xz],
            [zx - xz, xy + yx, -xx + yy - zz, yz + zy],
            [xy - yx, zx + xz, yz + zy, -xx - yy + zz],
        ]
        let q = largestEigenvector(n)
        let length = (q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]).squareRoot()
        guard length > 0, length.isFinite else { return nil }
        let (w, x, y, z) = (q[0] / length, q[1] / length, q[2] / length, q[3] / length)
        return Rotation(matrix: [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y),
                                 2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x),
                                 2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)])
    }

    /// Whether some two of `vectors` are far enough apart to fix a rotation with them (sin 0.06° ≈ 1e-3).
    private static func spread(_ vectors: [SIMD3<Double>]) -> Bool {
        for i in vectors.indices {
            for j in vectors.indices where j > i && SkyMath.length(SkyMath.cross(vectors[i], vectors[j])) > 1e-3 { return true }
        }
        return false
    }

    /// The eigenvector of the largest eigenvalue of a symmetric 4×4 matrix, by Jacobi's method.
    private static func largestEigenvector(_ matrix: [[Double]]) -> [Double] {
        var a = matrix
        var v: [[Double]] = (0..<4).map { row in (0..<4).map { $0 == row ? 1 : 0 } }
        for _ in 0..<60 {
            var off = 0.0, scale = 0.0
            for p in 0..<4 {
                scale += a[p][p] * a[p][p]
                for q in (p + 1)..<4 { off += a[p][q] * a[p][q] }
            }
            if off <= 1e-30 * max(scale, 1e-300) { break }
            for p in 0..<3 {
                for q in (p + 1)..<4 where a[p][q] != 0 {
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta < 0 ? -1.0 : 1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for k in 0..<4 {
                        let (kp, kq) = (a[k][p], a[k][q])
                        a[k][p] = c * kp - s * kq
                        a[k][q] = s * kp + c * kq
                    }
                    for k in 0..<4 {
                        let (pk, qk) = (a[p][k], a[q][k])
                        a[p][k] = c * pk - s * qk
                        a[q][k] = s * pk + c * qk
                    }
                    for k in 0..<4 {
                        let (kp, kq) = (v[k][p], v[k][q])
                        v[k][p] = c * kp - s * kq
                        v[k][q] = s * kp + c * kq
                    }
                }
            }
        }
        let best = (0..<4).max { a[$0][$0] < a[$1][$1] } ?? 0
        return (0..<4).map { v[$0][best] }
    }

    // MARK: Small helpers

    /// Whether a match can be used at all: finite numbers, its point in the picture.
    static func usable(_ match: AimCorrespondence) -> Bool {
        let numbers = [match.point.x, match.point.y, match.direction.azimuth, match.direction.elevation]
        return numbers.allSatisfy(\.isFinite) && (0...1).contains(match.point.x) && (0...1).contains(match.point.y)
            && abs(match.direction.elevation) <= 90
    }

    /// A match's object with its source, so that a star's number and an aircraft's hex never count as one.
    static func objectKey(_ match: AimCorrespondence) -> String {
        "\(match.source.rawValue):\(match.object)"
    }

    static func rms(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    }

    /// Solves `matrix` · x = `vector` for a symmetric positive definite `matrix` (`count` × `count`, row-major) by Cholesky's method; nil when
    /// it is not positive definite.
    static func solve(_ matrix: [Double], _ vector: [Double], count n: Int) -> [Double]? {
        var lower = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = matrix[i * n + j]
                for k in 0..<j { sum -= lower[i * n + k] * lower[j * n + k] }
                if i == j {
                    guard sum > 0, sum.isFinite else { return nil }
                    lower[i * n + i] = sum.squareRoot()
                } else {
                    lower[i * n + j] = sum / lower[j * n + j]
                }
            }
        }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = vector[i]
            for k in 0..<i { sum -= lower[i * n + k] * y[k] }
            y[i] = sum / lower[i * n + i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = y[i]
            for k in (i + 1)..<n { sum -= lower[k * n + i] * x[k] }
            x[i] = sum / lower[i * n + i]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }
}

// MARK: - One lens

/// A match as one lens's fit uses it.
private struct Sighting {
    /// Where it was seen, in the lens's own frame.
    var local: PixelPoint
    /// Where it really was: the direction's unit vector, east-north-up.
    var sky: SIMD3<Double>
    var source: AimCorrespondence.Source
    /// `AimFitter.objectKey`.
    var object: String
}

/// The numbers of one lens that a fit moves: its axes, its focal scales (the normalized plane's value at half its frame's width and height),
/// its principal point and its radial terms. The projection stays as it is.
private struct LensNumbers {
    var projection: SkyCameraModel.LensProjection
    var right: SIMD3<Double>
    var up: SIMD3<Double>
    var forward: SIMD3<Double>
    var across: Double
    var upward: Double
    var centre: PixelPoint
    var radial: [Double]

    init(_ lens: SkyCameraModel.Lens) {
        projection = lens.projection
        (right, up, forward) = lens.axes
        across = Self.scale(ofField: lens.horizontalFOV, lens.projection, vertical: false)
        upward = Self.scale(ofField: lens.verticalFOV, lens.projection, vertical: true)
        centre = lens.principalPoint
        radial = lens.radial
    }

    /// The lens these numbers make; nil when they do not make a valid one.
    var lens: SkyCameraModel.Lens? {
        guard Self.fits(across, projection, vertical: false), Self.fits(upward, projection, vertical: true),
              centre.x.isFinite, centre.y.isFinite, radial.allSatisfy(\.isFinite) else { return nil }
        let lens = SkyCameraModel.Lens(projection: projection, up: up, forward: forward,
                                       horizontalFOV: Self.field(ofScale: across, projection, vertical: false),
                                       verticalFOV: Self.field(ofScale: upward, projection, vertical: true), principalPoint: centre, radial: radial)
        return [lens.yaw, lens.pitch, lens.roll].allSatisfy(\.isFinite) ? lens : nil
    }

    /// The focal scale of a field of view (degrees) of `projection`, across its frame or up and down it: tan(field/2) where the projection
    /// is a pinhole that way, field/2 in radians where it is angle-linear.
    static func scale(ofField field: Double, _ projection: SkyCameraModel.LensProjection, vertical: Bool) -> Double {
        let half = field / 2 * SkyMath.radians
        switch projection {
        case .rectilinear: return tan(half)
        case .cylindrical: return vertical ? tan(half) : half
        case .equidistant, .equirectangular: return half
        }
    }

    static func field(ofScale scale: Double, _ projection: SkyCameraModel.LensProjection, vertical: Bool) -> Double {
        switch projection {
        case .rectilinear: return 2 * atan(scale) * SkyMath.degrees
        case .cylindrical: return (vertical ? 2 * atan(scale) : 2 * scale) * SkyMath.degrees
        case .equidistant, .equirectangular: return 2 * scale * SkyMath.degrees
        }
    }

    /// Whether a focal scale makes a field `projection` allows (`SkyCameraModel.Lens`): under 180° as a pinhole, at most 180° up and down
    /// for an equirectangular lens, under 360° otherwise.
    static func fits(_ scale: Double, _ projection: SkyCameraModel.LensProjection, vertical: Bool) -> Bool {
        guard scale > 0, scale < 1e6 else { return false }
        switch projection {
        case .rectilinear: return true
        case .cylindrical: return vertical || scale < .pi
        case .equidistant: return scale < .pi
        case .equirectangular: return vertical ? scale <= .pi / 2 : scale < .pi
        }
    }

    /// These numbers turned by `turn` (radians, about the lens's own right, up and forward axes; Rodrigues' formula).
    func turned(by turn: SIMD3<Double>) -> LensNumbers {
        let angle = SkyMath.length(turn)
        guard angle > 0 else { return self }
        let k = turn / angle, c = cos(angle), s = sin(angle), t = 1 - c
        // R = I cos + [k]× sin + k kᵀ (1 − cos); the new axes are the old ones times R (columns).
        let r: [Double] = [c + k.x * k.x * t, k.x * k.y * t - k.z * s, k.x * k.z * t + k.y * s,
                           k.y * k.x * t + k.z * s, c + k.y * k.y * t, k.y * k.z * t - k.x * s,
                           k.z * k.x * t - k.y * s, k.z * k.y * t + k.x * s, c + k.z * k.z * t]
        var next = self
        next.right = right * r[0] + up * r[3] + forward * r[6]
        next.up = right * r[1] + up * r[4] + forward * r[7]
        next.forward = right * r[2] + up * r[5] + forward * r[8]
        return next
    }
}

/// A term a fit can free.
private enum Parameter: Equatable {
    /// A small rotation of the lens about its own right (0), up (1) or forward (2) axis, in radians.
    case turn(Int)
    /// The logarithm of the focal scale across (and up and down, while the vertical scale follows it).
    case scale
    /// The logarithm of the focal scale up and down, on its own.
    case verticalScale
    case centreX, centreY
    /// k1, k2, k3.
    case radial(Int)

    /// What a stage frees (`AimFitter`).
    static func freed(by stage: Int) -> [Parameter] {
        var list: [Parameter] = [.turn(0), .turn(1), .turn(2), .scale]
        if stage >= 2 { list += [.centreX, .centreY, .radial(0)] }
        if stage >= 3 { list += [.radial(1), .verticalScale] }
        if stage >= 4 { list.append(.radial(2)) }
        return list
    }
}

/// A lens fitted in one projection.
private struct Candidate {
    var lens: SkyCameraModel.Lens
    var stage: Int
    /// The tolerance its inliers are judged at (degrees).
    var tolerance: Double
    /// Indices into the solver's sightings.
    var inliers: [Int]
    /// The angular error (degrees) of every sighting; infinity where the lens has no direction for its pixel.
    var errors: [Double]
    var residualDegrees: Double
    /// The inliers' RMS in pixels of the original picture: where the lens puts each direction, against where it was seen.
    var residualPixels: Double
}

/// Fits one lens of a camera to the sightings it owns.
private struct LensSolver {
    let name: String
    let dual: Bool
    let sightings: [Sighting]
    /// The lens's frame in pixels of the original picture, across, and the picture's height and width.
    let framePixels: Double
    let heightPixels: Double
    let widthPixels: Double
    let cap: Double

    init(model: SkyCameraModel, lens: Int, correspondences: [AimCorrespondence], width: Double, height: Double) {
        dual = model.layout == .dual
        name = dual ? (lens == 0 ? "the left lens" : "the right lens") : "the lens"
        let frame = model.frame(of: lens)
        sightings = correspondences.compactMap { match in
            guard AimFitter.usable(match), model.lens(at: match.point) == lens, !model.isInSeamBand(match.point) else { return nil }
            return Sighting(local: PixelPoint(x: (match.point.x - frame.origin) / frame.width, y: match.point.y),
                            sky: SkyMath.unitVector(match.direction), source: match.source, object: AimFitter.objectKey(match))
        }
        framePixels = frame.width * width
        heightPixels = height
        widthPixels = width
        cap = AimFitter.outlierWidths * width
    }

    // MARK: Choosing the projection

    /// The lens fitted from `start` in its own projection and, once its matches allow stage 2 (`AimFitter.projectionStage`), in every
    /// other: the one with the lowest robust residual (its errors capped at the tightest tolerance any candidate reached), unless `start`'s
    /// own is within 10 % of it. Nil while the lens's matches are too few to fit (stage 0).
    func bestFit(from start: SkyCameraModel.Lens, tolerance: Double, using generator: inout some RandomNumberGenerator) -> Candidate? {
        guard sightings.count >= 8 else { return nil }
        let begin = LensNumbers(start)
        let tie = begin.across / begin.upward
        guard tie.isFinite, tie > 0 else { return nil }
        var tolerance = tolerance
        var fitted = fit(begin, start: begin, tie: tie, tolerance: tolerance, using: &generator)
        while fitted.map({ share(of: $0) < AimFitter.minimumInlierShare }) ?? true,
              let looser = AimFitter.tolerances.first(where: { $0 > tolerance }) {
            tolerance = looser
            fitted = fit(begin, start: begin, tie: tie, tolerance: tolerance, using: &generator)
        }
        guard let own = fitted else { return nil }
        // Whether the matches are enough to choose a projection is a matter of the matches, not of how well a wrong projection fits them.
        guard stage(of: Array(sightings.indices)) >= AimFitter.projectionStage else { return own }
        var candidates = [own]
        for projection in SkyCameraModel.LensProjection.allCases where projection != start.projection {
            guard let other = converted(begin, to: projection, tie: tie) else { continue }
            if let candidate = fit(other, start: other, tie: tie, tolerance: tolerance, using: &generator) { candidates.append(candidate) }
        }
        let cap = candidates.map(\.tolerance).min() ?? tolerance
        let robust = candidates.map { candidate in
            (candidate.errors.reduce(0) { $0 + min($1 * $1, cap * cap) } / Double(sightings.count)).squareRoot()
        }
        let best = robust.indices.min { robust[$0] < robust[$1] } ?? 0
        return robust[0] <= AimFitter.projectionMargin * robust[best] ? candidates[0] : candidates[best]
    }

    /// The part of what the lens saw that agrees with a candidate: each star match counting once, and each aircraft once (it agrees when at
    /// least half of its samples are inliers), so that a long track weighs no more than a short one.
    func share(of candidate: Candidate) -> Double {
        let agreeing = Set(candidate.inliers)
        var aircraft: [String: (samples: Int, inliers: Int)] = [:]
        var stars = 0, starInliers = 0
        for (index, sighting) in sightings.enumerated() {
            let inlier = agreeing.contains(index)
            if sighting.source == .plane {
                aircraft[sighting.object, default: (0, 0)].samples += 1
                if inlier { aircraft[sighting.object, default: (0, 0)].inliers += 1 }
            } else {
                stars += 1
                if inlier { starInliers += 1 }
            }
        }
        let agreeingAircraft = aircraft.values.filter { 2 * $0.inliers >= $0.samples }.count
        return Double(agreeingAircraft + starInliers) / Double(max(1, aircraft.count + stars))
    }

    /// `numbers` in another projection: the same axes and principal point, no radial terms (they belong to the old projection), and the
    /// focal scale that sees the sightings' pixels most nearly where the old lens does (a golden-section search on its logarithm), the
    /// vertical one following it.
    func converted(_ numbers: LensNumbers, to projection: SkyCameraModel.LensProjection, tie: Double) -> LensNumbers? {
        guard let old = numbers.lens else { return nil }
        let step = max(1, sightings.count / 60)
        let samples = stride(from: 0, to: sightings.count, by: step).compactMap { index -> (PixelPoint, SIMD3<Double>)? in
            old.direction(atLocal: sightings[index].local).map { (sightings[index].local, SkyMath.unitVector($0)) }
        }
        var base = numbers
        base.projection = projection
        base.radial = []
        func trial(_ logScale: Double) -> (LensNumbers, Double)? {
            var next = base
            next.across = exp(logScale)
            next.upward = next.across / tie
            guard let lens = next.lens else { return nil }
            let cost = samples.reduce(0.0) { sum, sample in
                guard let seen = lens.direction(atLocal: sample.0) else { return sum + 1 }
                let angle = atan2(SkyMath.length(SkyMath.cross(SkyMath.unitVector(seen), sample.1)), SkyMath.dot(SkyMath.unitVector(seen), sample.1))
                return sum + angle * angle
            }
            return (next, cost)
        }
        // The same field's scale in the new projection, then the search either side of it.
        let middle = log(LensNumbers.scale(ofField: old.horizontalFOV, projection, vertical: false))
        var low = middle - 1.5, high = middle + 1.5
        let golden = (5.0.squareRoot() - 1) / 2
        var best = trial(middle)
        for _ in 0..<40 {
            let a = high - golden * (high - low), b = low + golden * (high - low)
            let costA = trial(a)?.1 ?? .infinity, costB = trial(b)?.1 ?? .infinity
            if costA < costB { high = b } else { low = a }
        }
        if let found = trial((low + high) / 2), found.1 < (best?.1 ?? .infinity) { best = found }
        return best?.0
    }

    // MARK: Fitting in one projection

    /// The lens fitted from `numbers` in their projection: RANSAC on the rotation, then rounds of refinement and of judging the inliers,
    /// until they settle (at most 8). Terms a round's stage does not free stay at `start`'s. The tolerance tightens only while the inliers
    /// it keeps still allow the stage (a point that the terms not yet freed explain badly is no wrong match). Nil when the inliers do not
    /// reach stage 1.
    func fit(_ numbers: LensNumbers, start: LensNumbers, tie: Double, tolerance: Double,
             using generator: inout some RandomNumberGenerator) -> Candidate? {
        var (current, inliers) = ransac(numbers, tolerance: tolerance, using: &generator)
        var tolerance = tolerance, freed = 0
        for _ in 0..<8 {
            let round = stage(of: inliers)
            guard round > 0 else { return nil }
            freed = round
            current = refine(restricted(current, to: freed, start: start, tie: tie), inliers: inliers, parameters: Parameter.freed(by: freed),
                             tie: tie)
            guard let lens = current.lens else { return nil }
            let errors = angularErrors(lens)
            // The tolerance the residual earns: 3σ (σ from the median error of those within the tolerance now), rounded up to a match
            // tolerance, never looser.
            let within = errors.filter { $0 <= tolerance }.sorted()
            var next = tolerance
            if !within.isEmpty {
                let gate = 3 * within[within.count / 2] / 1.177_4
                next = min(tolerance, AimFitter.tolerances.first { $0 >= gate } ?? tolerance)
            }
            var judged = errors.indices.filter { errors[$0] <= next }
            if next < tolerance && stage(of: judged) < freed {
                // A point that the terms not yet freed explain badly is no wrong match: a looser tolerance, 1.5° before 15°. When 1.5°
                // costs the stage too, the lens takes the lower stage, but never stage 0 (then it keeps the earlier tolerance).
                let looser = AimFitter.tolerances.first { $0 > next && $0 <= min(tolerance, AimFitter.matchTolerance(.good)) }
                if let looser {
                    next = looser
                    judged = errors.indices.filter { errors[$0] <= looser }
                }
                // But a lens never tightens itself out of a fit: what it keeps must still allow stage 1.
                if stage(of: judged) == 0 {
                    next = tolerance
                    judged = errors.indices.filter { errors[$0] <= tolerance }
                }
            }
            if next == tolerance && judged == inliers { break }
            tolerance = next
            inliers = judged
        }
        return finish(current, stage: freed, tolerance: tolerance)
    }

    /// The stage that sightings (indices) allow.
    private func stage(of indices: [Int]) -> Int {
        AimFitter.stage(indices.map { sightings[$0].local }, objects: indices.map { sightings[$0].object }, dual: dual)
    }

    /// The candidate of fitted `numbers`: its errors and inliers at `tolerance`.
    private func finish(_ numbers: LensNumbers, stage: Int, tolerance: Double) -> Candidate? {
        guard let lens = numbers.lens else { return nil }
        let errors = angularErrors(lens)
        let inliers = errors.indices.filter { errors[$0] <= tolerance }
        let pixels = self.errors(of: inliers.map { sightings[$0] }, through: lens)
        let sizes = stride(from: 0, to: pixels.count, by: 2).map { magnitude(pixels[$0], pixels[$0 + 1]) }.filter { !$0.isNaN }
        return Candidate(lens: lens, stage: stage, tolerance: tolerance, inliers: inliers, errors: errors,
                         residualDegrees: AimFitter.rms(inliers.map { errors[$0] }), residualPixels: AimFitter.rms(sizes))
    }

    /// `numbers` with the terms that `stage` does not free put back to `start`'s (the vertical scale following the horizontal one).
    private func restricted(_ numbers: LensNumbers, to stage: Int, start: LensNumbers, tie: Double) -> LensNumbers {
        var next = numbers
        if stage < 2 { next.centre = start.centre }
        let freed = stage >= 4 ? 3 : stage >= 3 ? 2 : stage >= 2 ? 1 : 0
        var radial = Array(next.radial.prefix(freed))
        if start.radial.count > freed {
            radial += Array(repeating: 0, count: freed - radial.count)
            radial += start.radial[freed...]
        }
        next.radial = radial
        if stage < 3 { next.upward = next.across / tie }
        return next
    }

    /// The angle (degrees) between each sighting's direction and the direction of its pixel through `lens`: infinity where it has none.
    func angularErrors(_ lens: SkyCameraModel.Lens) -> [Double] {
        sightings.map { sighting in
            guard let seen = lens.direction(atLocal: sighting.local) else { return .infinity }
            let vector = SkyMath.unitVector(seen)
            return atan2(SkyMath.length(SkyMath.cross(vector, sighting.sky)), SkyMath.dot(vector, sighting.sky)) * SkyMath.degrees
        }
    }

    // MARK: RANSAC

    /// The lens turned by the rotation that the most sightings agree with, within `tolerance` (of two with as many, the one with the
    /// smaller summed error): the identity first, then `AimFitter.ransacSamples` samples of 3, each solved for the rotation alone from where
    /// the lens sees their pixels now; the winner is solved again from all its inliers. Returns its inliers too (indices into the sightings).
    func ransac(_ numbers: LensNumbers, tolerance: Double, using generator: inout some RandomNumberGenerator) -> (LensNumbers, [Int]) {
        guard let lens = numbers.lens else { return (numbers, []) }
        // Where the lens sees each sighting's pixel now, for those it has a direction for.
        let seen: [(index: Int, source: SIMD3<Double>)] = sightings.indices.compactMap { index in
            lens.direction(atLocal: sightings[index].local).map { (index, SkyMath.unitVector($0)) }
        }
        let limit = cos(tolerance * SkyMath.radians)
        func agreeing(_ rotation: AimFitter.Rotation) -> [Int] {
            seen.filter { SkyMath.dot(rotation.applied(to: $0.source), sightings[$0.index].sky) >= limit }.map(\.index)
        }
        func score(_ rotation: AimFitter.Rotation) -> (count: Int, cost: Double) {
            var count = 0, cost = 0.0
            for pair in seen {
                let agreement = SkyMath.dot(rotation.applied(to: pair.source), sightings[pair.index].sky)
                if agreement >= limit { count += 1 }
                cost += min(1 - agreement, 1 - limit)
            }
            return (count, cost)
        }
        var best = AimFitter.Rotation.identity, bestScore = score(.identity)
        if seen.count >= 3 {
            for _ in 0..<AimFitter.ransacSamples {
                let sample = (0..<3).map { _ in seen[Int.random(in: 0..<seen.count, using: &generator)] }
                guard sample[0].index != sample[1].index, sample[1].index != sample[2].index, sample[0].index != sample[2].index,
                      let rotation = AimFitter.rotation(from: sample.map(\.source), to: sample.map { sightings[$0.index].sky }) else { continue }
                let trial = score(rotation)
                if trial.count > bestScore.count || (trial.count == bestScore.count && trial.cost < bestScore.cost) {
                    (best, bestScore) = (rotation, trial)
                }
            }
            let agreed = Set(agreeing(best))
            let pairs = seen.filter { agreed.contains($0.index) }
            if let refined = AimFitter.rotation(from: pairs.map(\.source), to: pairs.map { sightings[$0.index].sky }) {
                let trial = score(refined)
                if trial.count >= bestScore.count { (best, bestScore) = (refined, trial) }
            }
        }
        var turned = numbers
        turned.right = best.applied(to: numbers.right)
        turned.up = best.applied(to: numbers.up)
        turned.forward = best.applied(to: numbers.forward)
        return (turned, agreeing(best))
    }

    // MARK: Levenberg–Marquardt

    /// The pixel errors of `points` through `lens` (pixels of the original picture; x then y, two to a point): where it puts each
    /// sighting's direction, against where it was seen. NaN where the lens has no point for it. (Plain numbers in one array: the fit's
    /// innermost loop.)
    private func errors(of points: [Sighting], through lens: SkyCameraModel.Lens?) -> [Double] {
        var values = [Double](repeating: .nan, count: points.count * 2)
        guard let lens else { return values }
        for (index, point) in points.enumerated() {
            guard let local = lens.localPoint(ofUnit: point.sky) else { continue }
            values[2 * index] = (local.x - point.local.x) * framePixels
            values[2 * index + 1] = (local.y - point.local.y) * heightPixels
        }
        return values
    }

    /// The ridge prior's residuals of the freed correction terms, with their derivatives by parameter index.
    private func prior(_ numbers: LensNumbers, parameters: [Parameter], tie: Double) -> [(value: Double, slopes: [(Int, Double)])] {
        var terms: [(value: Double, slopes: [(Int, Double)])] = []
        let scaleIndex = parameters.firstIndex(of: .scale)
        for (index, parameter) in parameters.enumerated() {
            switch parameter {
            case .centreX: terms.append(((numbers.centre.x - 0.5) / AimFitter.principalPointSigma, [(index, 1 / AimFitter.principalPointSigma)]))
            case .centreY: terms.append(((numbers.centre.y - 0.5) / AimFitter.principalPointSigma, [(index, 1 / AimFitter.principalPointSigma)]))
            case .radial(let k):
                let sigma = AimFitter.radialSigmas[k]
                terms.append(((k < numbers.radial.count ? numbers.radial[k] : 0) / sigma, [(index, 1 / sigma)]))
            case .verticalScale:
                let sigma = AimFitter.verticalScaleSigma
                var slopes = [(index, -1 / sigma)]
                if let scaleIndex { slopes.append((scaleIndex, 1 / sigma)) }
                terms.append((log(numbers.across / numbers.upward / tie) / sigma, slopes))
            case .turn, .scale:
                break
            }
        }
        return terms
    }

    /// The robust cost: Huber's (`AimFitter.robustCost`) of each pixel error over δ², twice, plus the prior's squares.
    private func totalCost(_ errors: [Double], _ numbers: LensNumbers, parameters: [Parameter], tie: Double) -> Double {
        let delta = AimFitter.huberPixels
        var data = 0.0
        for index in stride(from: 0, to: errors.count, by: 2) {
            data += 2 * AimFitter.robustCost(pixels: magnitude(errors[index], errors[index + 1]), cap: cap) / (delta * delta)
        }
        return data + prior(numbers, parameters: parameters, tie: tie).reduce(0) { $0 + $1.value * $1.value }
    }

    /// `numbers` moved by `step` (one value per parameter), the vertical scale following the horizontal one unless it is freed.
    private func moved(_ numbers: LensNumbers, by step: [Double], parameters: [Parameter], tie: Double) -> LensNumbers {
        var next = numbers
        var turn = SIMD3<Double>(0, 0, 0)
        for (value, parameter) in zip(step, parameters) {
            switch parameter {
            case .turn(let axis): turn[axis] = value
            case .scale: next.across *= exp(value)
            case .verticalScale: next.upward *= exp(value)
            case .centreX: next.centre.x += value
            case .centreY: next.centre.y += value
            case .radial(let index):
                while next.radial.count <= index { next.radial.append(0) }
                next.radial[index] += value
            }
        }
        if !parameters.contains(.verticalScale) { next.upward = next.across / tie }
        return next.turned(by: turn)
    }

    /// Levenberg–Marquardt over `parameters` from `numbers`, on the pixel errors of the `inliers`: the Jacobian by forward differences
    /// through the lens's own projection, Huber weights (none for an outlier), the ridge prior, and Marquardt's damping. At most
    /// `AimFitter.maximumIterations` solves; a step is taken only when it lowers the robust cost.
    func refine(_ numbers: LensNumbers, inliers: [Int], parameters: [Parameter], tie: Double) -> LensNumbers {
        let points = inliers.map { sightings[$0] }
        let count = parameters.count, delta2 = AimFitter.huberPixels * AimFitter.huberPixels
        var current = numbers
        if !parameters.contains(.verticalScale) { current.upward = current.across / tie }
        guard let lens = current.lens, !points.isEmpty else { return numbers }
        current = LensNumbers(lens)
        var errors = errors(of: points, through: lens)
        var cost = totalCost(errors, current, parameters: parameters, tie: tie)
        var damping = 1e-3
        let h = 1e-6
        var solves = 0
        outer: while solves < AimFitter.maximumIterations {
            // The Jacobian, column by column (a column is NaN where the moved lens has no point).
            var columns: [[Double]] = []
            for index in 0..<count {
                var step = [Double](repeating: 0, count: count)
                step[index] = h
                columns.append(self.errors(of: points, through: moved(current, by: step, parameters: parameters, tie: tie).lens))
            }
            var normal = [Double](repeating: 0, count: count * count), gradient = [Double](repeating: 0, count: count)
            var slopesX = [Double](repeating: 0, count: count), slopesY = [Double](repeating: 0, count: count)
            for row in 0..<points.count {
                let x = errors[2 * row], y = errors[2 * row + 1]
                guard !x.isNaN else { continue }
                let weight = AimFitter.robustWeight(pixels: magnitude(x, y), cap: cap) / delta2
                guard weight > 0 else { continue }
                for index in 0..<count {
                    let movedX = columns[index][2 * row], movedY = columns[index][2 * row + 1]
                    (slopesX[index], slopesY[index]) = movedX.isNaN ? (0, 0) : ((movedX - x) / h, (movedY - y) / h)
                }
                for a in 0..<count {
                    gradient[a] += weight * (slopesX[a] * x + slopesY[a] * y)
                    for b in a..<count { normal[a * count + b] += weight * (slopesX[a] * slopesX[b] + slopesY[a] * slopesY[b]) }
                }
            }
            for term in prior(current, parameters: parameters, tie: tie) {
                // Into the upper triangle, each pair of slopes once (the lower one is copied from it below).
                for (a, slopeA) in term.slopes {
                    gradient[a] += slopeA * term.value
                    for (b, slopeB) in term.slopes where b >= a { normal[a * count + b] += slopeA * slopeB }
                }
            }
            for a in 0..<count { for b in 0..<a { normal[a * count + b] = normal[b * count + a] } }
            let largest = (0..<count).map { normal[$0 * count + $0] }.max() ?? 0
            guard largest > 0, largest.isFinite else { break }
            // Damped steps until one lowers the cost.
            while solves < AimFitter.maximumIterations {
                solves += 1
                var damped = normal
                for a in 0..<count { damped[a * count + a] += damping * max(normal[a * count + a], 1e-12 * largest) }
                guard let step = AimFitter.solve(damped, gradient.map { -$0 }, count: count) else {
                    damping *= 10
                    if damping > 1e12 { break outer }
                    continue
                }
                let trial = moved(current, by: step, parameters: parameters, tie: tie)
                if let trialLens = trial.lens {
                    let trialErrors = self.errors(of: points, through: trialLens)
                    let trialCost = totalCost(trialErrors, trial, parameters: parameters, tie: tie)
                    if trialCost < cost {
                        let gain = (cost - trialCost) / max(cost, 1e-300)
                        current = LensNumbers(trialLens)
                        errors = trialErrors
                        cost = trialCost
                        damping = max(damping / 10, 1e-12)
                        if gain < AimFitter.convergence { break outer }
                        continue outer
                    }
                }
                damping *= 10
                if damping > 1e12 { break outer }
            }
        }
        return current
    }

    // MARK: Acceptance

    /// Why `candidate` is not to be taken over `before` (the lens's previous aim), or nil when it is: too few of the lens's matches agree
    /// with it, its residual grew against `before`'s on the same inliers, or its picture is not sane over the frame (a fold, or for a dual
    /// camera's lens a correction that moves a point of a 9×5 grid more than 3 % of the picture's width from its plain projection).
    func problem(with candidate: Candidate, before: SkyCameraModel.Lens) -> String? {
        let part = share(of: candidate)
        if part < AimFitter.minimumInlierShare {
            return "only \(Int((part * 100).rounded())) % of its matches agree with any aim (each aircraft counted once; "
                + "\(Int(AimFitter.minimumInlierShare * 100)) % needed)"
        }
        let earlier = angularErrors(before)
        let earlierResidual = AimFitter.rms(candidate.inliers.map { min(earlier[$0], 180) })
        if candidate.residualDegrees > AimFitter.allowedGrowth * earlierResidual {
            return String(format: "its new aim is further off than before (%.3f° against %.3f°)", candidate.residualDegrees, earlierResidual)
        }
        let plain = SkyCameraModel.Lens(projection: candidate.lens.projection, yaw: candidate.lens.yaw, pitch: candidate.lens.pitch,
                                        roll: candidate.lens.roll, horizontalFOV: candidate.lens.horizontalFOV,
                                        verticalFOV: candidate.lens.verticalFOV, principalPoint: PixelPoint(x: 0.5, y: 0.5), radial: [])
        var largest = 0.0
        for i in 0...8 {
            for j in 0...4 {
                let point = PixelPoint(x: Double(i) / 8, y: Double(j) / 4)
                guard let direction = candidate.lens.direction(atLocal: point) else { return "its distortion folds inside its frame" }
                guard dual else { continue }
                guard let base = plain.localPoint(of: direction) else { return "its corrections move its picture out of its frame" }
                largest = max(largest, hypot((base.x - point.x) * framePixels, (base.y - point.y) * heightPixels))
            }
        }
        if largest > AimFitter.largestCorrection * widthPixels {
            return String(format: "a correction moves its picture by %.1f %% of the width (%.0f %% at most)", largest / widthPixels * 100,
                          AimFitter.largestCorrection * 100)
        }
        return nil
    }
}

/// The length of a pixel error; NaN (no point) stays NaN, which the robust weights count as an outlier.
private func magnitude(_ x: Double, _ y: Double) -> Double {
    (x * x + y * y).squareRoot()
}

/// A seeded random number generator (SplitMix64): the same seed gives the same numbers, so a fit can be repeated (tests, and a store given a
/// seed).
struct SkyRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
