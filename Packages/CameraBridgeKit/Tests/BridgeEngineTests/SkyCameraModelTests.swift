import Foundation
import Testing
@testable import BridgeEngine

/// The camera model (`SkyCameraModel`): a single lens, or two lenses side by side that the camera stitches into one picture, split at the
/// seam and each modelled on its own: its own projection (rectilinear, equidistant, cylindrical or equirectangular) with Brown radial distortion over its own
/// half.
@Suite struct SkyCameraModelTests {
    static let radians = Double.pi / 180

    /// The direction of an east-north-up vector (worked out here, not with the code under test).
    static func direction(_ v: SIMD3<Double>) -> SkyDirection {
        let azimuth = atan2(v.x, v.y) / radians
        return SkyDirection(azimuth: azimuth < 0 ? azimuth + 360 : azimuth, elevation: atan2(v.z, (v.x * v.x + v.y * v.y).squareRoot()) / radians)
    }

    static func vector(_ d: SkyDirection) -> SIMD3<Double> {
        SIMD3(cos(d.elevation * radians) * sin(d.azimuth * radians), cos(d.elevation * radians) * cos(d.azimuth * radians), sin(d.elevation * radians))
    }

    /// The x of a dual camera's points on a grid of one half: for `lens` 0 from the left edge to just left of the seam, for 1 from the seam
    /// to the right edge.
    static func halfGrid(_ lens: Int) -> [Double] {
        (0...10).map { Double(lens) * 0.5 + Double($0) * (lens == 0 ? 0.049_99 : 0.05) }
    }

    /// The residuals of the least-squares fit of `target` by a combination of `columns` (normal equations, Gaussian elimination).
    static func leastSquaresResiduals(_ columns: [[Double]], _ target: [Double]) -> [Double] {
        let n = columns.count
        var matrix = (0..<n).map { i in (0..<n).map { j in zip(columns[i], columns[j]).reduce(0) { $0 + $1.0 * $1.1 } } }
        var vector = (0..<n).map { i in zip(columns[i], target).reduce(0) { $0 + $1.0 * $1.1 } }
        for pivot in 0..<n {
            let best = (pivot..<n).max { abs(matrix[$0][pivot]) < abs(matrix[$1][pivot]) } ?? pivot
            matrix.swapAt(pivot, best)
            vector.swapAt(pivot, best)
            for row in (pivot + 1)..<n {
                let factor = matrix[row][pivot] / matrix[pivot][pivot]
                for column in pivot..<n { matrix[row][column] -= factor * matrix[pivot][column] }
                vector[row] -= factor * vector[pivot]
            }
        }
        var solution = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            solution[row] = (vector[row] - ((row + 1)..<n).reduce(0) { $0 + matrix[row][$1] * solution[$1] }) / matrix[row][row]
        }
        return target.indices.map { k in target[k] - (0..<n).reduce(0) { $0 + solution[$1] * columns[$1][k] } }
    }

    @Test func projectAndBackRoundTrip() throws {
        // Every projection is in the truths, as a single lens and as a dual camera's halves.
        let every = Set(SkyCameraModel.LensProjection.allCases)
        #expect(Set(SkyFixtures.truthModels.filter { $0.layout == .single }.flatMap { $0.lenses.map(\.projection) }) == every)
        #expect(Set(SkyFixtures.truthModels.filter { $0.layout == .dual }.flatMap { $0.lenses.map(\.projection) }) == every)
        for model in SkyFixtures.truthModels {
            let name = "\(model.layout) \(model.lenses.map(\.projection.rawValue))"
            // A 21×11 grid of points, edges and the seam included: point → direction → point.
            var worst = 0.0
            for i in 0...20 {
                for j in 0...10 {
                    let point = PixelPoint(x: Double(i) / 20, y: Double(j) / 10)
                    let seen = try #require(model.direction(at: point), "\(name) \(point)")
                    #expect(seen.lens == model.lens(at: point))
                    let back = try #require(model.project(seen.direction).first { $0.lens == seen.lens }, "\(name) \(point)")
                    worst = max(worst, abs(back.point.x - point.x), abs(back.point.y - point.y))
                }
            }
            #expect(worst <= 1e-6, "\(name): \(worst)")

            // And the other way: directions all over the sky → every lens that sees them → back through that lens.
            var hits = 0
            for azimuth in stride(from: 0.0, to: 360, by: 7.5) {
                for elevation in stride(from: -20.0, through: 85, by: 5) {
                    let direction = SkyDirection(azimuth: azimuth, elevation: elevation)
                    for hit in model.project(direction) {
                        hits += 1
                        #expect(hit.point.x >= 0 && hit.point.x <= 1 && hit.point.y >= 0 && hit.point.y <= 1)
                        let back = try #require(model.direction(at: hit.point, lens: hit.lens))
                        #expect(SkyMath.separation(back, direction) <= 1e-6, "\(name) \(direction) → \(hit)")
                    }
                }
            }
            #expect(hits > 100, "\(name): \(hits) hits")
        }
    }

    @Test func brownDistortionMatchesReference() throws {
        // k1 −0.25, k2 0.08 and no k3 (missing is 0): r = 0.8 → r_d = 0.8·(1 − 0.25·0.64 + 0.08·0.4096), and back.
        let lens = SkyCameraModel.Lens(yaw: 0, pitch: 0, roll: 0, horizontalFOV: 100, verticalFOV: 67.67,
                                       principalPoint: PixelPoint(x: 0.5, y: 0.5), radial: [-0.25, 0.08])
        let reference = 0.8 * (1 - 0.25 * 0.64 + 0.08 * 0.4096)
        #expect(abs(lens.distortedRadius(0.8) - reference) <= 1e-12)
        let inverse = try #require(lens.undistortedRadius(reference))
        #expect(abs(inverse - 0.8) <= 1e-9)

        // Through the picture, in every projection. The normalized radius is tan θ for a rectilinear lens and θ (radians) for the
        // angle-linear ones, and the focal scale comes from the field of view: the direction whose radius is 0.8, to the right of a lens
        // facing north, lands r_d · (half the width / the scale) right of the centre, and comes back.
        for projection in SkyCameraModel.LensProjection.allCases {
            var each = lens
            each.projection = projection
            let model = SkyCameraModel(layout: .single, seam: 0.5, lenses: [each])
            let scale = projection == .rectilinear ? tan(50 * Self.radians) : 50 * Self.radians
            let angle = projection == .rectilinear ? atan(0.8) : 0.8
            let point = try #require(model.project(SkyDirection(azimuth: angle / Self.radians, elevation: 0)).first?.point, "\(projection)")
            #expect(abs((point.x - 0.5) * 2 * scale - reference) <= 1e-12 && abs(point.y - 0.5) <= 1e-12, "\(projection): \(point)")
            let back = try #require(model.direction(at: point), "\(projection)")
            #expect(abs(back.direction.azimuth * Self.radians - angle) <= 1e-9 && abs(back.direction.elevation) <= 1e-9, "\(projection): \(back)")
        }

        // The same radius up and to the left of a rectilinear lens: distortion is radial, so only the length changes.
        let model = SkyCameraModel(layout: .single, seam: 0.5, lenses: [lens])
        let tanHalfWidth = tan(50 * Self.radians), tanHalfHeight = tan(67.67 / 2 * Self.radians)
        let angle = 150 * Self.radians
        let a = 0.8 * cos(angle), b = 0.8 * sin(angle)
        let diagonal = try #require(model.project(Self.direction(SIMD3(a, 1, b))).first?.point)   // the camera's (a, b, 1) is east a, north 1, up b
        let ad = (diagonal.x - 0.5) * 2 * tanHalfWidth, bd = (0.5 - diagonal.y) * 2 * tanHalfHeight
        #expect(abs((ad * ad + bd * bd).squareRoot() - reference) <= 1e-12 && abs(atan2(bd, ad) - angle) <= 1e-12, "\(diagonal)")
        let diagonalBack = try #require(model.direction(at: diagonal))
        #expect(SkyMath.separation(diagonalBack.direction, Self.direction(SIMD3(a, 1, b))) <= 1e-7)

        // Past the fold. With k1 −0.25 alone, r_d stops growing at r = 1/√0.75 ≈ 1.155 (r_d 0.770) and comes back towards the centre: the
        // direction at r = 1.3 would land well inside the picture (x ≈ 0.81), but no lens sees it there, and a larger r_d has no direction.
        let folding = SkyCameraModel(layout: .single, seam: 0.5, lenses: [SkyCameraModel.Lens(
            yaw: 0, pitch: 0, roll: 0, horizontalFOV: 100, verticalFOV: 67.67, principalPoint: PixelPoint(x: 0.5, y: 0.5), radial: [-0.25])])
        let pastTheFold = SkyDirection(azimuth: atan(1.3) / Self.radians, elevation: 0)
        #expect(folding.project(pastTheFold).isEmpty)
        #expect(folding.project(pastTheFold, lens: 0) == nil)
        #expect(folding.lenses[0].undistortedRadius(0.78) == nil)
        #expect(abs((folding.lenses[0].undistortedRadius(0.7) ?? 0) - 0.8578) <= 0.001)
        #expect(folding.direction(at: PixelPoint(x: 0.5 + 0.5 * 0.78 / tanHalfWidth, y: 0.5)) == nil, "no direction past the largest r_d")
        // A fold that comes back (k1 −0.4, k2 0.02, k3 0.001: r_d falls between r ≈ 0.95 and 2.7 and rises again): the far side is not seen
        // either.
        let wavy = SkyCameraModel.Lens(yaw: 0, pitch: 0, roll: 0, horizontalFOV: 100, verticalFOV: 67.67,
                                       principalPoint: PixelPoint(x: 0.5, y: 0.5), radial: [-0.4, 0.02, 0.001])
        #expect(wavy.isMonotonic(upToSquaredRadius: 0.5) && !wavy.isMonotonic(upToSquaredRadius: 10))
        let fold: Double = 0.906   // the fold's r²: the slope 1 + 3k1 q + 5k2 q² + 7k3 q³ is zero there
        let slopeAtFold: Double = 1 - 1.2 * fold + 0.1 * fold * fold + 0.007 * fold * fold * fold
        #expect(abs(slopeAtFold) <= 0.002)
        #expect(wavy.isMonotonic(upToSquaredRadius: 0.9) && !wavy.isMonotonic(upToSquaredRadius: 0.91))
        #expect(wavy.localPoint(of: SkyDirection(azimuth: atan(3.2) / Self.radians, elevation: 0)) == nil)

        // Behind the lens, and a lens that is not valid, have no points; nothing traps.
        #expect(model.project(SkyDirection(azimuth: 180, elevation: 0)).isEmpty)
        let centre = PixelPoint(x: 0.5, y: 0.5)
        for broken in [SkyCameraModel.Lens(yaw: 0, pitch: 0, roll: 0, horizontalFOV: 180, verticalFOV: 60, principalPoint: centre, radial: []),
                       SkyCameraModel.Lens(projection: .cylindrical, yaw: 0, pitch: 0, roll: 0, horizontalFOV: 90, verticalFOV: 180,
                                           principalPoint: centre, radial: []),
                       SkyCameraModel.Lens(projection: .equidistant, yaw: 0, pitch: 0, roll: 0, horizontalFOV: 360, verticalFOV: 90,
                                           principalPoint: centre, radial: []),
                       SkyCameraModel.Lens(projection: .equirectangular, yaw: 0, pitch: 0, roll: 0, horizontalFOV: 90, verticalFOV: 190,
                                           principalPoint: centre, radial: []),
                       SkyCameraModel.Lens(yaw: .nan, pitch: 0, roll: 0, horizontalFOV: 90, verticalFOV: 60, principalPoint: centre, radial: []),
                       SkyCameraModel.Lens(yaw: 0, pitch: 0, roll: 0, horizontalFOV: 90, verticalFOV: 0, principalPoint: centre, radial: []),
                       SkyCameraModel.Lens(yaw: 0, pitch: 0, roll: 0, horizontalFOV: 90, verticalFOV: 60, principalPoint: centre, radial: [.infinity])] {
            let camera = SkyCameraModel(layout: .single, seam: 0.5, lenses: [broken])
            #expect(camera.project(SkyDirection(azimuth: 0, elevation: 0)).isEmpty, "\(broken.projection)")
            #expect(camera.direction(at: centre) == nil, "\(broken.projection)")
            #expect(camera.degreesPerPixel(at: centre, pictureWidth: 1920).isFinite)
        }
        // An equidistant lens sees past 90° off its axis, but not straight behind; a cylindrical one sees all round, but not straight up.
        let fisheye = SkyCameraModel.Lens(projection: .equidistant, yaw: 0, pitch: 0, roll: 0, horizontalFOV: 240, verticalFOV: 180,
                                          principalPoint: centre, radial: [])
        #expect(fisheye.localPoint(of: SkyDirection(azimuth: 110, elevation: 0)).map { abs($0.x - (0.5 + 0.5 * 110 / 120)) <= 1e-12 } == true)
        #expect(fisheye.localPoint(of: SkyDirection(azimuth: 180, elevation: 0)) == nil)
        let panorama = SkyCameraModel.Lens(projection: .cylindrical, yaw: 0, pitch: 0, roll: 0, horizontalFOV: 300, verticalFOV: 90,
                                           principalPoint: centre, radial: [])
        #expect(panorama.localPoint(of: SkyDirection(azimuth: 140, elevation: 10)).map { abs($0.x - (0.5 + 0.5 * 140 / 150)) <= 1e-12 } == true)
        #expect(SkyCameraModel(layout: .single, seam: 0.5, lenses: [panorama]).project(SkyDirection(azimuth: 0, elevation: 90)).isEmpty)
        // An equirectangular one is angle-linear both ways, up to straight up: on its top line, at its centre column.
        let sphere = SkyCameraModel.Lens(projection: .equirectangular, yaw: 0, pitch: 0, roll: 0, horizontalFOV: 300, verticalFOV: 180,
                                         principalPoint: centre, radial: [])
        #expect(sphere.localPoint(of: SkyDirection(azimuth: 140, elevation: -30))
            .map { abs($0.x - (0.5 + 0.5 * 140 / 150)) <= 1e-12 && abs($0.y - (0.5 + 0.5 * 30 / 90)) <= 1e-12 } == true)
        let zenith = try #require(SkyCameraModel(layout: .single, seam: 0.5, lenses: [sphere]).project(SkyDirection(azimuth: 0, elevation: 90)).first)
        #expect(abs(zenith.point.x - 0.5) <= 1e-9 && abs(zenith.point.y) <= 1e-9, "\(zenith)")
        #expect(sphere.direction(atLocal: PixelPoint(x: 0.5, y: -0.1)) == nil, "past the zenith there is nothing")
        #expect(SkyCameraModel(layout: .dual, seam: 0.5, lenses: [lens]).direction(at: PixelPoint(x: 0.75, y: 0.5)) == nil, "no right lens")
    }

    @Test func anAngleLinearStitchedHalfIsCylindrical() throws {
        try Self.checkStitchedHalf(elevationLinear: false, matching: .cylindrical)
    }

    @Test func anAngleLinearInBothStitchedHalfIsEquirectangular() throws {
        try Self.checkStitchedHalf(elevationLinear: true, matching: .equirectangular)
    }

    /// One half of a picture stitched angle-linear across (a cylindrical panorama) or across and up and down (an equirectangular one), as
    /// dual cameras stitch: 2128×1888 of 4256×1888, 90° across with square pixels at the centre, from the housing (facing 0, tilted up 18°)
    /// turned 45° to the left about its own up. Its axes, pixels and their directions, worked out here.
    static func stitchedHalf(elevationLinear: Bool) -> (right: SIMD3<Double>, up: SIMD3<Double>, forward: SIMD3<Double>, pixels: [PixelPoint],
                                                        directions: [SkyDirection]) {
        let across = Double.pi / 2, aspect = 2128.0 / 1888.0
        let tilt = 18 * radians
        let housingForward = SIMD3(0, cos(tilt), sin(tilt)), housingRight = SIMD3<Double>(1, 0, 0), up = SIMD3(0, -sin(tilt), cos(tilt))
        let forward = housingForward * cos(Double.pi / 4) - housingRight * sin(Double.pi / 4)
        let right = housingRight * cos(Double.pi / 4) + housingForward * sin(Double.pi / 4)
        var pixels: [PixelPoint] = [], directions: [SkyDirection] = []
        for i in 0...42 {
            for j in 0...38 {
                let point = PixelPoint(x: Double(i) / 42, y: Double(j) / 38)
                let azimuth = (point.x - 0.5) * across, upward = (0.5 - point.y) * across / aspect
                let ray = elevationLinear
                    ? right * (cos(upward) * sin(azimuth)) + up * sin(upward) + forward * (cos(upward) * cos(azimuth))
                    : right * sin(azimuth) + up * upward + forward * cos(azimuth)   // upward is the tangent of the elevation here
                pixels.append(point)
                directions.append(direction(ray))
            }
        }
        return (right, up, forward, pixels, directions)
    }

    /// The normalized plane of `projection` for a lens-frame direction (x right, y up, z along the axis), worked out here.
    static func plane(_ projection: SkyCameraModel.LensProjection, _ x: Double, _ y: Double, _ z: Double) -> (a: Double, b: Double) {
        switch projection {
        case .rectilinear: return (x / z, y / z)
        case .equidistant:
            let aside = (x * x + y * y).squareRoot(), angle = atan2(aside, z)
            return aside > 0 ? (x / aside * angle, y / aside * angle) : (0, 0)
        case .cylindrical: return (atan2(x, z), y / (x * x + z * z).squareRoot())
        case .equirectangular: return (atan2(x, z), atan2(y, (x * x + z * z).squareRoot()))
        }
    }

    /// A stitched half is reproduced by a lens of its own projection on its axis (well within half a pixel; in fact exactly), and by no
    /// other: even with its focal scale and three radial terms fitted to each axis on its own by least squares (a looser model than one
    /// lens, so a lower bound), each other projection is off by more than 12 px on average. (Measured: on the cylindrical half rectilinear
    /// 33.2, equidistant 33.0, equirectangular 16.5 px; on the equirectangular half 27.9, 28.0 and cylindrical 18.9 px.)
    static func checkStitchedHalf(elevationLinear: Bool, matching: SkyCameraModel.LensProjection) throws {
        let width = 2128.0, height = 1888.0
        let half = stitchedHalf(elevationLinear: elevationLinear)
        let vertical = SkyCameraModel.Lens.verticalFOV(horizontalFOV: 90, frameAspect: width / height, projection: matching)
        #expect(abs(vertical - (elevationLinear ? 90 * height / width : 2 * atan(height / width * Double.pi / 4) / radians)) <= 1e-9)
        let lens = SkyCameraModel.Lens(projection: matching, up: half.up, forward: half.forward, horizontalFOV: 90, verticalFOV: vertical,
                                       principalPoint: PixelPoint(x: 0.5, y: 0.5), radial: [])
        var worst = 0.0
        for (point, direction) in zip(half.pixels, half.directions) {
            let seen = try #require(lens.localPoint(of: direction))
            worst = max(worst, abs(seen.x - point.x) * width, abs(seen.y - point.y) * height)
        }
        #expect(worst <= 0.5, "\(matching): \(worst) px")
        #expect(worst <= 1e-6, "\(matching), in fact exactly: \(worst) px")

        for other in SkyCameraModel.LensProjection.allCases where other != matching {
            var columnsAcross: [[Double]] = Array(repeating: [], count: 4), columnsUp: [[Double]] = Array(repeating: [], count: 4)
            var targetAcross: [Double] = [], targetUp: [Double] = []
            for (point, direction) in zip(half.pixels, half.directions) {
                let sky = vector(direction)
                let flat = plane(other, (sky * half.right).sum(), (sky * half.up).sum(), (sky * half.forward).sum())
                let squared = flat.a * flat.a + flat.b * flat.b
                for power in 0..<4 {
                    columnsAcross[power].append(flat.a * pow(squared, Double(power)))
                    columnsUp[power].append(flat.b * pow(squared, Double(power)))
                }
                targetAcross.append((point.x - 0.5) * width)
                targetUp.append((0.5 - point.y) * height)
            }
            let residuals = zip(leastSquaresResiduals(columnsAcross, targetAcross), leastSquaresResiduals(columnsUp, targetUp))
                .map { ($0 * $0 + $1 * $1).squareRoot() }
            let rms = (residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count)).squareRoot()
            #expect(rms > 12, "\(matching) half, \(other) at best \(rms) px RMS")
        }
    }

    @Test func initialModelFollowsTheCard() throws {
        // 4256×1888 is stitched: two lenses side by side, split 50/50, each 90° across its half (180° edge to edge), rectilinear, with no
        // distortion.
        let dual = SkyCameraModel.initial(facing: 0, tilt: 20, pictureWidth: 4256, pictureHeight: 1888)
        #expect(dual.layout == .dual && dual.seam == 0.5 && dual.lenses.count == 2)
        let halfVertical = 2 * atan(1888.0 / 2128.0) / Self.radians   // square pixels: tan(vertical / 2) = tan 45° · 1888 / 2128
        for lens in dual.lenses {
            #expect(lens.projection == .rectilinear && lens.horizontalFOV == 90 && abs(lens.verticalFOV - halfVertical) <= 1e-9, "\(lens)")
            #expect(lens.principalPoint == PixelPoint(x: 0.5, y: 0.5) && lens.radial.isEmpty, "\(lens)")
        }

        // Each lens is turned to its own azimuth about the vertical (north ∓ 45°), then tilted up 20° about its own horizontal axis: that is its
        // axis, its principal point looks there, straight above the principal point is the vertical through it (no roll), and its middle row
        // runs along its own horizontal axis. (Before, each was the tilted housing turned about the housing's own up, which rolled it.)
        for (index, side) in [(0, -1.0), (1, 1.0)] {
            let turn = side * 45 * Self.radians, tilt = 20 * Self.radians
            let axis = SIMD3(sin(turn) * cos(tilt), cos(turn) * cos(tilt), sin(tilt))
            let level = SIMD3(cos(turn), -sin(turn), 0)   // the lens's horizontal axis, to its right
            let up = SIMD3(-sin(turn) * sin(tilt), -cos(turn) * sin(tilt), cos(tilt))
            let expected = Self.direction(axis)
            let lens = dual.lenses[index]
            #expect(SkyFixtures.azimuthDifference(lens.yaw, side * 45) <= 1e-9 && abs(lens.pitch - 20) <= 1e-9 && abs(lens.roll) <= 1e-9, "\(lens)")
            let principal = try #require(dual.direction(at: PixelPoint(x: index == 0 ? 0.25 : 0.75, y: 0.5)))
            #expect(principal.lens == index && SkyMath.separation(principal.direction, expected) <= 1e-9)
            let above = try #require(dual.direction(at: PixelPoint(x: index == 0 ? 0.25 : 0.75, y: 0.2)))
            #expect(SkyFixtures.azimuthDifference(above.direction.azimuth, expected.azimuth) <= 1e-9 && above.direction.elevation > 20,
                    "straight above the principal point is the vertical through it: \(above)")

            // 90° across its middle row: half a degree inside its outer edge is in the picture, half a degree outside is not; and the same at the
            // top and bottom of the lens's own centre column.
            let inside = Self.direction(axis * cos(44.5 * Self.radians) + level * (side * sin(44.5 * Self.radians)))
            let edge = dual.project(inside)
            #expect(edge.count == 1 && edge.first?.lens == index, "\(edge)")
            if let x = edge.first?.point.x { #expect(index == 0 ? x < 0.01 : x > 0.99, "\(x)") }
            #expect(dual.project(Self.direction(axis * cos(45.5 * Self.radians) + level * (side * sin(45.5 * Self.radians)))).isEmpty)
            for vertical in [-1.0, 1.0] {
                let near = (halfVertical / 2 - 0.5) * Self.radians, far = (halfVertical / 2 + 0.5) * Self.radians
                let top = dual.project(Self.direction(axis * cos(near) + up * (vertical * sin(near))))
                #expect(top.count == 1 && top.first?.lens == index, "\(top)")
                #expect(dual.project(Self.direction(axis * cos(far) + up * (vertical * sin(far)))).isEmpty)
            }
        }

        // 1920×1080 is a single lens: 100° across, the vertical field from square pixels, facing where the card says.
        let single = SkyCameraModel.initial(facing: 135, tilt: 10, pictureWidth: 1920, pictureHeight: 1080)
        #expect(single.layout == .single && single.lenses.count == 1)
        let lens = try #require(single.lenses.first)
        #expect(lens.horizontalFOV == 100 && abs(lens.verticalFOV - 2 * atan(tan(50 * Self.radians) * 1080 / 1920) / Self.radians) <= 1e-9)
        #expect(lens.yaw == 135 && lens.pitch == 10 && lens.roll == 0 && lens.radial.isEmpty && lens.principalPoint == PixelPoint(x: 0.5, y: 0.5))
        #expect(lens.projection == .rectilinear)
        let centre = try #require(single.direction(at: PixelPoint(x: 0.5, y: 0.5)))
        #expect(centre.lens == 0 && SkyFixtures.azimuthDifference(centre.direction.azimuth, 135) <= 1e-9 && abs(centre.direction.elevation - 10) <= 1e-9)

        // Degrees per pixel: at a pinhole's centre 2·atan(tan 50° / 1920); next to the seam, the pixel's own lens's (45° off its axis:
        // cos² 45° · 2 tan 45° / 2128 radians).
        #expect(abs(single.degreesPerPixel(at: PixelPoint(x: 0.5, y: 0.5), pictureWidth: 1920) - 2 * atan(tan(50 * Self.radians) / 1920) / Self.radians) <= 1e-9)
        #expect(abs(dual.degreesPerPixel(at: PixelPoint(x: 0.4999, y: 0.5), pictureWidth: 4256) - 1 / 2128 / Self.radians) <= 1e-4)
        #expect(abs(dual.degreesPerPixel(at: PixelPoint(x: 1, y: 1), pictureWidth: 4256) - dual.degreesPerPixel(at: PixelPoint(x: 0, y: 1), pictureWidth: 4256)) <= 1e-9,
                "the corners, by symmetry")

        // The person can change the layout.
        #expect(SkyCameraModel.initial(facing: 0, tilt: 20, pictureWidth: 4256, pictureHeight: 1888, layout: .single).layout == .single)
        let split = SkyCameraModel.initial(facing: 0, tilt: 20, pictureWidth: 1920, pictureHeight: 1080, layout: .dual)
        #expect(split.layout == .dual && split.lenses.count == 2)
        #expect(abs(split.lenses[0].verticalFOV - 2 * atan(1080.0 / 960.0) / Self.radians) <= 1e-9)

        // A model is saved and read back as it was, projections included; a lens saved without a projection is rectilinear. Odd inputs do
        // not trap.
        for model in SkyFixtures.truthModels + [dual, single] {
            let decoded = try JSONDecoder().decode(SkyCameraModel.self, from: JSONEncoder().encode(model))
            #expect(decoded == model)
            #expect(decoded.project(SkyDirection(azimuth: 10, elevation: 20)) == model.project(SkyDirection(azimuth: 10, elevation: 20)))
        }
        let saved = #"{"yaw":1,"pitch":2,"roll":3,"horizontalFOV":90,"verticalFOV":60,"principalPoint":{"x":0.5,"y":0.5},"radial":[-0.1]}"#
        let older = try JSONDecoder().decode(SkyCameraModel.Lens.self, from: Data(saved.utf8))
        #expect(older == SkyCameraModel.Lens(yaw: 1, pitch: 2, roll: 3, horizontalFOV: 90, verticalFOV: 60, principalPoint: PixelPoint(x: 0.5, y: 0.5), radial: [-0.1]))
        let odd = SkyCameraModel.initial(facing: .nan, tilt: 200, pictureWidth: 0, pictureHeight: -5)
        #expect(odd.lenses.allSatisfy { $0.yaw.isFinite && $0.pitch == 90 })
        #expect(SkyCameraModel.initial(facing: -90, tilt: 0, pictureWidth: 640, pictureHeight: 480).lenses.first?.yaw == 270)
    }

    /// A dual card as it was made until the 2026-10-25 beta: the housing (facing, tilt) turned ±45° about its own up, so that a tilted card
    /// rolled each lens. Here only to show that a level card is made as it was.
    static func housingTurned(facing: Double, tilt: Double) -> SkyCameraModel {
        let vertical = SkyCameraModel.Lens.verticalFOV(horizontalFOV: 90, frameAspect: 2128.0 / 1888)
        let centre = PixelPoint(x: 0.5, y: 0.5)
        let housing = SkyCameraModel.Lens(yaw: facing, pitch: tilt, roll: 0, horizontalFOV: 90, verticalFOV: vertical, principalPoint: centre, radial: []).axes
        let lenses = [-45.0, 45.0].map { turn -> SkyCameraModel.Lens in
            let angle = turn * radians
            return SkyCameraModel.Lens(up: housing.up, forward: housing.forward * cos(angle) + housing.right * sin(angle), horizontalFOV: 90,
                                       verticalFOV: vertical, principalPoint: centre, radial: [])
        }
        return SkyCameraModel(layout: .dual, seam: 0.5, lenses: lenses)
    }

    @Test func aSteepDualCardKeepsEachLensLevel() throws {
        // North Sky's card: facing north and tilted up 45°, a 4256×1888 stitched picture. Each lens is turned to its own azimuth about the
        // vertical (north ∓ 45°), then tilted up about its own horizontal axis: it looks at its azimuth at the card's tilt, with no roll. (Turned
        // about the tilted housing's up instead, as before, each was rolled 35°, and the level skyline ran from −18° to +18° across each half.)
        let card = SkyCameraModel.initial(facing: 0, tilt: 45, pictureWidth: 4256, pictureHeight: 1888)
        #expect(card.layout == .dual && card.seam == 0.5 && card.lenses.count == 2)
        for (index, azimuth) in [(0, 315.0), (1, 45.0)] {
            let lens = card.lenses[index]
            #expect(SkyFixtures.azimuthDifference(lens.yaw, azimuth) <= 1e-9 && abs(lens.pitch - 45) <= 1e-9 && abs(lens.roll) <= 1e-9, "\(lens)")
            let centre = try #require(card.direction(at: PixelPoint(x: index == 0 ? 0.25 : 0.75, y: 0.5)))
            #expect(centre.lens == index && SkyFixtures.azimuthDifference(centre.direction.azimuth, azimuth) <= 1e-9
                    && abs(centre.direction.elevation - 45) <= 1e-9, "the half's centre: \(centre)")
        }
        #expect(Self.housingTurned(facing: 0, tilt: 45).lenses.map { abs($0.roll) }.allSatisfy { abs($0 - 35.26) < 0.01 }, "the old card's roll")

        // The level horizon (elevation 0 along each lens's azimuth span, its axis ± 44°) is one row in each half, within a pixel of 1888: for a
        // level pinhole tilted up by t, 0.5 + 0.5 · tan t / tan(vertical / 2) of the height. At 45° that row is below the picture (each lens's
        // own projection is not cut at the edges); at 20° it is in it.
        for tilt in [45.0, 20.0] {
            let model = SkyCameraModel.initial(facing: 0, tilt: tilt, pictureWidth: 4256, pictureHeight: 1888)
            let row = 0.5 + 0.5 * tan(tilt * Self.radians) * 2128 / 1888
            for (index, azimuth) in [(0, 315.0), (1, 45.0)] {
                let points = try stride(from: -44.0, through: 44, by: 2).map {
                    try #require(model.project(SkyDirection(azimuth: SkyMath.normalizedDegrees(azimuth + $0), elevation: 0), lens: index))
                }
                let rows: [Double] = points.map { $0.y * 1888 }
                let highest: Double = rows.min() ?? .infinity, lowest: Double = rows.max() ?? 0
                #expect(lowest - highest <= 1 && rows.allSatisfy { abs($0 - row * 1888) <= 1 }, "tilt \(tilt), lens \(index): \(rows)")
            }
        }

        // The price of level lenses on a steep card: pinholes tilted up lean their sides towards the zenith, so the halves no longer meet along
        // the seam. Near its top both lenses see the same sky; near its foot, neither does. The fit gives each lens its own pose.
        let top = try #require(card.direction(at: PixelPoint(x: 0.5, y: 0.02), lens: 0))
        #expect(card.project(top).map(\.lens) == [0, 1], "the top of the seam is in both halves")
        let foot = try #require(card.direction(at: PixelPoint(x: 0.5, y: 0.98), lens: 0))
        #expect(card.project(SkyDirection(azimuth: 0, elevation: foot.elevation)).isEmpty, "due north at the foot of the seam is in neither")

        // A level card is made as before: each lens at facing ∓ 45°, level, unrolled; the picture's centre faces the card; the halves meet all down
        // the seam; and every direction falls where it did.
        for facing in [0.0, 137.5, 330] {
            let level = SkyCameraModel.initial(facing: facing, tilt: 0, pictureWidth: 4256, pictureHeight: 1888)
            let before = Self.housingTurned(facing: facing, tilt: 0)
            for (lens, old) in zip(level.lenses, before.lenses) {
                #expect(SkyFixtures.azimuthDifference(lens.yaw, old.yaw) <= 1e-9 && abs(lens.pitch - old.pitch) <= 1e-9 && abs(lens.roll - old.roll) <= 1e-9,
                        "\(facing): \(lens) against \(old)")
                #expect(lens.horizontalFOV == old.horizontalFOV && lens.verticalFOV == old.verticalFOV && lens.principalPoint == old.principalPoint)
            }
            for (lens, turn) in [(0, -45.0), (1, 45.0)] {
                #expect(SkyFixtures.azimuthDifference(level.lenses[lens].yaw, facing + turn) <= 1e-9 && level.lenses[lens].roll == 0)
            }
            for lens in 0...1 {
                let centre = try #require(level.direction(at: PixelPoint(x: 0.5, y: 0.5), lens: lens))
                #expect(SkyFixtures.azimuthDifference(centre.azimuth, facing) <= 1e-9 && abs(centre.elevation) <= 1e-9, "\(facing), \(lens): \(centre)")
            }
            for y in stride(from: 0.0, through: 1, by: 0.1) {
                let left = try #require(level.direction(at: PixelPoint(x: 0.5, y: y), lens: 0))
                let right = try #require(level.direction(at: PixelPoint(x: 0.5, y: y), lens: 1))
                #expect(SkyMath.separation(left, right) <= 1e-9, "\(facing), the seam at \(y)")
            }
            for azimuth in stride(from: 0.0, to: 360, by: 15) {
                for elevation in stride(from: -60.0, through: 80, by: 20) {
                    let direction = SkyDirection(azimuth: azimuth, elevation: elevation)
                    for lens in 0...1 {
                        // Behind a pinhole there is no point; at 90° off its axis, rounding decides which side a direction is on.
                        let axis = SkyDirection(azimuth: before.lenses[lens].yaw, elevation: before.lenses[lens].pitch)
                        guard SkyMath.separation(direction, axis) < 85 else { continue }
                        let now = try #require(level.project(direction, lens: lens)), then = try #require(before.project(direction, lens: lens))
                        #expect(abs(now.x - then.x) <= 1e-9 && abs(now.y - then.y) <= 1e-9, "\(facing): \(direction) through \(lens)")
                    }
                }
            }
        }

        // A single lens is made as it was: facing (facing, tilt), unrolled, however steep.
        let single = try #require(SkyCameraModel.initial(facing: 135, tilt: 45, pictureWidth: 1920, pictureHeight: 1080).lenses.first)
        #expect(single.yaw == 135 && single.pitch == 45 && single.roll == 0 && single.horizontalFOV == 100)
    }

    @Test func rollLowersTheFramesRightSide() throws {
        // A level lens facing north, rolled +10°, 90° by 60°: a point on the horizon at azimuth 20° is above the centre row, at
        // y = 0.5 − 0.5 · (sin 20° sin 10° / cos 20°) / tan 30° ≈ 0.445, and right of the centre at 0.5 + 0.5 · (sin 20° cos 10° / cos 20°).
        let lens = SkyCameraModel.Lens(yaw: 0, pitch: 0, roll: 10, horizontalFOV: 90, verticalFOV: 60, principalPoint: PixelPoint(x: 0.5, y: 0.5),
                                       radial: [])
        let point = try #require(lens.localPoint(of: SkyDirection(azimuth: 20, elevation: 0)))
        let s20 = sin(20 * Self.radians), c20 = cos(20 * Self.radians), s10 = sin(10 * Self.radians), c10 = cos(10 * Self.radians)
        #expect(abs(point.y - (0.5 - 0.5 * (s20 * s10 / c20) / tan(30 * Self.radians))) <= 1e-12, "\(point)")
        #expect(abs(point.y - 0.445) <= 0.001 && point.y < 0.5, "\(point)")
        #expect(abs(point.x - (0.5 + 0.5 * s20 * c10 / c20)) <= 1e-12, "\(point)")
        // Rolled the other way, the same point is below the centre row by as much.
        var other = lens
        other.roll = -10
        let mirrored = try #require(other.localPoint(of: SkyDirection(azimuth: 20, elevation: 0)))
        #expect(abs((mirrored.y - 0.5) + (point.y - 0.5)) <= 1e-12 && mirrored.y > 0.5)
    }

    @Test func aChangedLensProjectsByItsNewNumbers() throws {
        // What projecting needs is worked out once per lens; changing any number, in place or by assignment, works it out again.
        let base = SkyFixtures.truthSingle.lenses[0]
        let direction = SkyDirection(azimuth: 240, elevation: 40)   // 28° off the axis, where every term shows
        let changes: [(String, (inout SkyCameraModel.Lens) -> Void)] = [
            ("projection", { $0.projection = .cylindrical }), ("yaw", { $0.yaw += 3 }), ("pitch", { $0.pitch -= 2 }), ("roll", { $0.roll = 7 }),
            ("horizontalFOV", { $0.horizontalFOV = 80 }), ("verticalFOV", { $0.verticalFOV = 50 }),
            ("principalPoint.x", { $0.principalPoint.x = 0.45 }), ("radial[0]", { $0.radial[0] = -0.1 }), ("radial.removeLast", { _ = $0.radial.removeLast() }),
        ]
        for (name, change) in changes {
            var changed = base
            change(&changed)
            let fresh = SkyCameraModel.Lens(projection: changed.projection, yaw: changed.yaw, pitch: changed.pitch, roll: changed.roll,
                                            horizontalFOV: changed.horizontalFOV, verticalFOV: changed.verticalFOV,
                                            principalPoint: changed.principalPoint, radial: changed.radial)
            #expect(changed == fresh && changed != base, "\(name)")
            #expect(changed.localPoint(of: direction) == fresh.localPoint(of: direction), "\(name)")
            #expect(changed.localPoint(of: direction) != base.localPoint(of: direction), "\(name)")
            #expect(changed.direction(atLocal: PixelPoint(x: 0.3, y: 0.6)) == fresh.direction(atLocal: PixelPoint(x: 0.3, y: 0.6)), "\(name)")
        }
        // A lens in a model's array too.
        var model = SkyFixtures.truthDual
        let ahead = SkyDirection(azimuth: 45, elevation: 15)
        let before = try #require(model.project(ahead, lens: 1))
        model.lenses[1].yaw += 1
        let after = try #require(model.project(ahead, lens: 1))
        #expect(after != before)
        #expect(after == SkyCameraModel(layout: .single, seam: 0.5, lenses: [model.lenses[1]]).project(ahead, lens: 0)
            .map { PixelPoint(x: 0.5 + $0.x * 0.5, y: $0.y) })
    }

    @Test func twoHalvesAreRecoveredIndependently() throws {
        for model in [SkyFixtures.truthDual, SkyFixtures.truthMixedDual] {
            let (left, right) = (model.lenses[0], model.lenses[1])
            #expect(left.yaw != right.yaw && left.pitch != right.pitch && left.roll != right.roll && left.horizontalFOV != right.horizontalFOV)
            #expect(left.principalPoint != right.principalPoint && left.radial != right.radial)

            for lens in 0...1 {
                let own = model.lenses[lens]
                // Each half is a camera of its own: a pixel of that half maps through its lens alone, as the lens on its own maps the same
                // point of its own frame (x across its half), and back.
                for x in Self.halfGrid(lens) {
                    for y in stride(from: 0.0, through: 1, by: 0.125) {
                        let point = PixelPoint(x: x, y: y)
                        let seen = try #require(model.direction(at: point), "\(point)")
                        #expect(seen.lens == lens)
                        let local = PixelPoint(x: (x - Double(lens) * 0.5) / 0.5, y: y)
                        #expect(seen.direction == own.direction(atLocal: local), "\(point)")
                        let back = try #require(own.localPoint(of: seen.direction))
                        #expect(abs(back.x - local.x) <= 1e-9 && abs(back.y - local.y) <= 1e-9, "\(point)")
                    }
                }
                // Its own pose is where its own principal point looks.
                let principal = PixelPoint(x: Double(lens) * 0.5 + own.principalPoint.x * 0.5, y: own.principalPoint.y)
                let axis = try #require(model.direction(at: principal))
                #expect(axis.lens == lens)
                #expect(SkyFixtures.azimuthDifference(axis.direction.azimuth, own.yaw) <= 1e-9 && abs(axis.direction.elevation - own.pitch) <= 1e-9)

                // Changing the other half, even to something quite different, changes nothing in this one.
                var altered = model
                altered.lenses[1 - lens] = SkyCameraModel.Lens(projection: .equidistant, yaw: 80, pitch: 40, roll: -5, horizontalFOV: 70,
                                                               verticalFOV: 60, principalPoint: PixelPoint(x: 0.45, y: 0.55), radial: [0.1])
                for x in Self.halfGrid(lens) {
                    for y in stride(from: 0.0, through: 1, by: 0.25) {
                        let point = PixelPoint(x: x, y: y)
                        let seen = try #require(model.direction(at: point))
                        #expect(altered.direction(at: point) == seen, "\(point)")
                        #expect(altered.project(seen.direction).first { $0.lens == lens } == model.project(seen.direction).first { $0.lens == lens })
                    }
                }
            }
        }
    }

    @Test func theTruthHalvesMeetAtTheSeam() throws {
        // The distorted truth meets as a stitch does: down the whole seam, each lens's seam column is within a fraction of a degree of the
        // other's, and seen through the other lens it lands inside the seam band, on that lens's side (the halves overlap by a few pixels).
        let model = SkyFixtures.truthDual
        for y in stride(from: 0.0, through: 1, by: 0.025) {
            let left = try #require(model.direction(at: PixelPoint(x: 0.5, y: y), lens: 0))
            let right = try #require(model.direction(at: PixelPoint(x: 0.5, y: y), lens: 1))
            #expect(SkyMath.separation(left, right) < 0.5, "\(y)")
            let rightThroughLeft = try #require(model.project(right, lens: 0))
            let leftThroughRight = try #require(model.project(left, lens: 1))
            #expect(model.isInSeamBand(rightThroughLeft) && rightThroughLeft.x < 0.5, "\(y): \(rightThroughLeft)")
            #expect(model.isInSeamBand(leftThroughRight) && leftThroughRight.x > 0.5, "\(y): \(leftThroughRight)")
        }
        // And each half covers about 90° across, 180° edge to edge: the middles of the outer edges are about 90° from the seam's middle.
        let seam = try #require(model.direction(at: PixelPoint(x: 0.5, y: 0.5)))
        for (x, lens) in [(0.0, 0), (1.0, 1)] {
            let edge = try #require(model.direction(at: PixelPoint(x: x, y: model.lenses[lens].principalPoint.y), lens: lens))
            #expect(abs(SkyMath.separation(edge, seam.direction) - 90) <= 1.5, "\(lens): \(edge)")
        }
    }

    @Test func aDirectionNearTheSeamProjectsIntoBothHalves() throws {
        // The distorted truth: a direction on either lens's seam column is in both halves, either side of the seam and in its band, and each
        // hit maps back through its own lens.
        let truth = SkyFixtures.truthDual
        for lens in 0...1 {
            for y in [0.05, 0.3, 0.5, 0.7, 0.95] {
                let onTheSeam = try #require(truth.direction(at: PixelPoint(x: 0.5, y: y), lens: lens))
                let hits = truth.project(onTheSeam)
                #expect(hits.map(\.lens) == [0, 1], "\(lens) \(y): \(hits)")
                for hit in hits {
                    #expect(truth.isInSeamBand(hit.point), "\(lens) \(y): \(hit)")
                    let back = try #require(truth.direction(at: hit.point, lens: hit.lens))
                    #expect(SkyMath.separation(back, onTheSeam) <= 1e-6, "\(lens) \(y): \(hit)")
                }
                #expect((hits.first?.point.x ?? 1) <= 0.5 + 1e-9 && (hits.last?.point.x ?? 0) >= 0.5 - 1e-9, "\(lens) \(y): \(hits)")
            }
        }
        // A few degrees either side of the seam: one lens, outside the band.
        for (x, lens) in [(0.47, 0), (0.53, 1)] {
            let away = try #require(truth.direction(at: PixelPoint(x: x, y: 0.5)))
            let once = truth.project(away.direction)
            #expect(once.map(\.lens) == [lens] && once.allSatisfy { !truth.isInSeamBand($0.point) }, "\(x): \(once)")
        }

        let seamCentre = SkyDirection(azimuth: 0, elevation: 0)
        // A level card's halves meet exactly: on the seam, a direction is at x = 0.5 in both. (A tilted card's level lenses do not: see
        // `aSteepDualCardKeepsEachLensLevel`.)
        let meeting = SkyCameraModel.initial(facing: 0, tilt: 0, pictureWidth: 4256, pictureHeight: 1888)
        let both = meeting.project(seamCentre)
        #expect(both.map(\.lens) == [0, 1], "\(both)")
        for hit in both { #expect(abs(hit.point.x - 0.5) <= 1e-9 && abs(hit.point.y - 0.5) <= 1e-9, "\(hit)") }

        // Halves that overlap more (each lens 0.6° wider, as when the stitch shows a strip of sky twice): the direction is in both, just
        // either side of the seam, symmetrically, in the band, and each hit maps back through its own lens.
        var overlapping = meeting
        for index in overlapping.lenses.indices { overlapping.lenses[index].horizontalFOV = 90.6 }
        let twice = overlapping.project(seamCentre)
        #expect(twice.map(\.lens) == [0, 1], "\(twice)")
        if twice.count == 2 {
            #expect(twice[0].point.x < 0.5 && twice[1].point.x > 0.5, "\(twice)")
            #expect(abs((0.5 - twice[0].point.x) - (twice[1].point.x - 0.5)) <= 1e-9, "symmetric: \(twice)")
        }
        for hit in twice {
            #expect(overlapping.isInSeamBand(hit.point) && abs(hit.point.y - 0.5) <= 1e-9, "\(hit)")
            let back = try #require(overlapping.direction(at: hit.point))
            #expect(back.lens == hit.lens && SkyMath.separation(back.direction, seamCentre) <= 1e-9, "\(hit)")
        }

        // Halves with a gap (each lens 0.6° narrower, as when the stitch leaves a strip of sky out): the direction is in neither.
        var gapped = meeting
        for index in gapped.lenses.indices { gapped.lenses[index].horizontalFOV = 89.4 }
        #expect(gapped.project(seamCentre).isEmpty)

        // A few degrees either side of the seam: one lens, outside the band.
        for (direction, lens) in [(SkyDirection(azimuth: 3, elevation: 0), 1), (SkyDirection(azimuth: 357, elevation: 0), 0)] {
            let once = overlapping.project(direction)
            #expect(once.map(\.lens) == [lens], "\(direction): \(once)")
            #expect(once.allSatisfy { !overlapping.isInSeamBand($0.point) })
        }

        // Each lens's own projection is not cut at the seam (fitting sees a sighting that a wrong aim puts on the other side).
        let beyond = try #require(overlapping.project(SkyDirection(azimuth: 3, elevation: 0), lens: 0))
        #expect(beyond.x > 0.5)
    }

    @Test func aPixelMapsBackThroughItsOwnHalf() throws {
        let model = SkyFixtures.truthDual
        for (x, lens) in [(0.4999, 0), (0.5001, 1), (0.5, 1), (0.25, 0), (0.75, 1), (0.0, 0), (1.0, 1)] {
            for y in [0.1, 0.5, 0.9] {
                let point = PixelPoint(x: x, y: y)
                #expect(model.lens(at: point) == lens, "\(point)")
                let seen = try #require(model.direction(at: point), "\(point)")
                #expect(seen.lens == lens, "\(point)")
                #expect(seen.direction == model.direction(at: point, lens: lens), "its own lens: \(point)")
                #expect(seen.direction != model.direction(at: point, lens: 1 - lens), "not the other one: \(point)")
            }
        }
        // Either side of the seam, 0.0002 of the width apart, the two pixels come from different lenses: their directions are each lens's own.
        let leftOfSeam = try #require(model.direction(at: PixelPoint(x: 0.4999, y: 0.3)))
        let rightOfSeam = try #require(model.direction(at: PixelPoint(x: 0.5001, y: 0.3)))
        #expect(leftOfSeam.lens == 0 && rightOfSeam.lens == 1)
        #expect(leftOfSeam.direction == model.lenses[0].direction(atLocal: PixelPoint(x: 0.4999 / 0.5, y: 0.3)))
        #expect(rightOfSeam.direction == model.lenses[1].direction(atLocal: PixelPoint(x: (0.5001 - 0.5) / 0.5, y: 0.3)))

        // A single lens sees the whole picture.
        let single = SkyFixtures.truthSingle
        for x in [0.0, 0.4999, 0.5, 0.5001, 1.0] {
            #expect(single.lens(at: PixelPoint(x: x, y: 0.5)) == 0 && single.direction(at: PixelPoint(x: x, y: 0.5))?.lens == 0)
        }
        // A seam moved by a later fit moves the split; each lens keeps its own frame (its half), so its own mapping does not change.
        var moved = model
        moved.seam = 0.52
        #expect(moved.lens(at: PixelPoint(x: 0.51, y: 0.5)) == 0)
        #expect(moved.direction(at: PixelPoint(x: 0.51, y: 0.5))?.direction == model.direction(at: PixelPoint(x: 0.51, y: 0.5), lens: 0))
        #expect(moved.direction(at: PixelPoint(x: 0.53, y: 0.5)) == model.direction(at: PixelPoint(x: 0.53, y: 0.5)))
    }

    @Test func theSeamBandIsLowTrust() {
        // 1 % of the picture's width, centred on the seam: about 43 pixels of a 4256-pixel picture, 21 either side.
        #expect(SkyCameraModel.seamBandWidth == 0.01)
        let dual = SkyFixtures.truthDual
        #expect(dual.seamBand == 0.495...0.505)
        for x in [0.5, 0.4951, 0.5049, 0.5 - 21 / 4256.0, 0.5 + 21 / 4256.0] {
            #expect(dual.isInSeamBand(PixelPoint(x: x, y: 0.3)), "\(x)")
        }
        for x in [0.494, 0.506, 0.25, 0.0, 1.0, 0.5 - 22 / 4256.0] {
            #expect(!dual.isInSeamBand(PixelPoint(x: x, y: 0.3)), "\(x)")
        }
        // Low trust only: a point in the band still has a direction, through its own lens.
        #expect(dual.direction(at: PixelPoint(x: 0.4951, y: 0.3))?.lens == 0)
        #expect(dual.direction(at: PixelPoint(x: 0.5049, y: 0.3))?.lens == 1)
        // A single lens has no seam, so no band.
        #expect(SkyFixtures.truthSingle.seamBand == nil)
        #expect(!SkyFixtures.truthSingle.isInSeamBand(PixelPoint(x: 0.5, y: 0.5)))
        // The band follows the seam.
        var moved = dual
        moved.seam = 0.52
        #expect(moved.isInSeamBand(PixelPoint(x: 0.52, y: 0.5)) && !moved.isInSeamBand(PixelPoint(x: 0.5, y: 0.5)))
    }
}
