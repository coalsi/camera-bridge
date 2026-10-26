import Foundation

/// A point of the camera's ORIGINAL picture, never the one `PictureCorrection` straightens: x from the left edge and y from the top, each
/// 0…1 of the picture, so the same point on the main and the sub stream.
struct PixelPoint: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
}

/// How a sky camera's picture maps to the sky: one lens, or two side by side that the camera stitches into one picture.
///
/// A **dual** camera (the default for stitched views, 2:1 and wider) is split at `seam` (x, 50/50 to start) and each half is a camera of
/// its own: the left lens (0) sees x < seam and the right lens (1) the rest. The camera's stitching is not true to the sky (nor exact for the
/// stars), so there is no shared projection: the halves share nothing but the observer. Near the seam a direction can be in both halves (the
/// stitch shows that strip of sky twice) or in neither (it leaves it out), and `seamBand` marks the pixels where the stitch blends: they keep
/// their directions, but are not to be trusted for fitting. Large radial terms in a half bow its seam column across the sky, and the two
/// halves' columns bow in opposite directions (by degrees at k1 ≈ −0.2), so a track that crosses the seam is matched across it by direction,
/// with an angular tolerance (about 3°), not by pixel position.
///
/// Every lens (`Lens`) has its own projection (`LensProjection`: rectilinear, equidistant, cylindrical or equirectangular) with Brown radial
/// distortion on top. Its fields of view and principal point refer to the lens's **frame**, a fixed part of the picture: the whole of it for a
/// single lens, the left or right half (x 0…0.5, 0.5…1) for a dual camera's lenses, wherever the seam is. The seam only says which lens a
/// pixel belongs to, so moving it changes no lens's mapping.
///
/// For fitting (each lens on its own; a lens's sightings are the pixels it owns outside the seam band):
/// - chosen: each lens's `projection`, the one whose fit leaves the lowest robust residual (`LensProjection.allCases`);
/// - free: each lens's pose (`yaw`, `pitch`, `roll`) and `horizontalFOV`; as sightings accumulate, its `principalPoint` (a prior at its
///   frame's centre) and its `radial` terms k1, k2, k3 (a prior at zero);
/// - `verticalFOV` follows `horizontalFOV` for square pixels (`Lens.verticalFOV(horizontalFOV:frameAspect:projection:)`, the frame's
///   aspect from the original picture) unless it is fitted too;
/// - fixed: `layout` (the person's choice) and `seam` (0.5; a later fit could move it).
struct SkyCameraModel: Codable, Sendable, Equatable {
    enum LensLayout: String, Codable, Sendable {
        /// One lens over the whole picture.
        case single
        /// Two lenses side by side, stitched on the camera.
        case dual
    }

    /// How a lens lays the sky on its frame before its radial terms: a lens-frame direction (x right, y up, z along the axis) becomes a point
    /// (a, b) of a normalized plane, whose radius the Brown terms then scale.
    enum LensProjection: String, Codable, Sendable, CaseIterable {
        /// A pinhole: (a, b) = (x/z, y/z), so r = tan θ (θ the angle off the axis). Nothing behind the lens.
        case rectilinear
        /// Angle-linear in the radius (a fisheye): r = θ, towards the direction's side of the axis. Up to 180° off the axis.
        case equidistant
        /// Angle-linear across and a pinhole up and down, as cameras stitch a panorama: a = the azimuth in the lens's frame (atan2(x, z)),
        /// b = the tangent of the elevation in it. All round, but not straight up or down the frame.
        case cylindrical
        /// Angle-linear across and up and down, as cameras also stitch a panorama: a = the azimuth in the lens's frame, b = the elevation in
        /// it (radians). All round, up to straight up and down.
        case equirectangular
    }

    /// One lens: its projection with Brown radial distortion over its own frame (x and y 0…1 across its part of the picture, see
    /// `localPoint(of:)`). What projecting needs (its axes, its focal scales, its distortion's fold) is worked out once, when it is made or
    /// one of its numbers changes, not on every projection.
    struct Lens: Codable, Sendable, Equatable {
        var projection: LensProjection { didSet { prepare() } }
        /// The optical axis: its azimuth and elevation (degrees). At pitch ±90° yaw and roll turn about the same axis, so the three angles lose a
        /// degree of freedom there: fitting updates a pose near it by a small rotation of its own axes (`axes`), not through these angles.
        var yaw: Double { didSet { prepare() } }
        var pitch: Double { didSet { prepare() } }
        /// About the optical axis (degrees): positive lowers the frame's right side (the lens turned clockwise, seen from behind).
        var roll: Double { didSet { prepare() } }
        /// The fields of view of the projection across its frame (degrees): they set its focal scales. Under 180° for a rectilinear lens (and
        /// a cylindrical one's vertical), at most 180° for an equirectangular one's vertical, under 360° otherwise. With barrel distortion the
        /// frame shows more than this.
        var horizontalFOV: Double { didSet { prepare() } }
        var verticalFOV: Double { didSet { prepare() } }
        /// Where the optical axis meets the frame (its own 0…1 coordinates; the centre is (0.5, 0.5)).
        var principalPoint: PixelPoint { didSet { prepare() } }
        /// Brown radial terms k1, k2, k3 (missing ones are 0): r_d = r(1 + k1 r² + k2 r⁴ + k3 r⁶), on the projection's normalized radius.
        var radial: [Double] { didSet { prepare() } }

        private var prepared: Prepared

        init(projection: LensProjection = .rectilinear, yaw: Double, pitch: Double, roll: Double, horizontalFOV: Double,
             verticalFOV: Double, principalPoint: PixelPoint, radial: [Double]) {
            self.projection = projection
            self.yaw = yaw
            self.pitch = pitch
            self.roll = roll
            self.horizontalFOV = horizontalFOV
            self.verticalFOV = verticalFOV
            self.principalPoint = principalPoint
            self.radial = radial
            prepared = Prepared(projection: projection, yaw: yaw, pitch: pitch, roll: roll, horizontalFOV: horizontalFOV,
                                verticalFOV: verticalFOV, principalPoint: principalPoint, radial: radial)
        }

        private enum CodingKeys: String, CodingKey {
            case projection, yaw, pitch, roll, horizontalFOV, verticalFOV, principalPoint, radial
        }

        /// A lens saved without a projection is rectilinear.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(projection: try values.decodeIfPresent(LensProjection.self, forKey: .projection) ?? .rectilinear,
                      yaw: try values.decode(Double.self, forKey: .yaw), pitch: try values.decode(Double.self, forKey: .pitch),
                      roll: try values.decode(Double.self, forKey: .roll),
                      horizontalFOV: try values.decode(Double.self, forKey: .horizontalFOV),
                      verticalFOV: try values.decode(Double.self, forKey: .verticalFOV),
                      principalPoint: try values.decode(PixelPoint.self, forKey: .principalPoint),
                      radial: try values.decodeIfPresent([Double].self, forKey: .radial) ?? [])
        }

        /// The same numbers (what is worked out from them follows).
        static func == (a: Lens, b: Lens) -> Bool {
            a.projection == b.projection && a.yaw == b.yaw && a.pitch == b.pitch && a.roll == b.roll && a.horizontalFOV == b.horizontalFOV
                && a.verticalFOV == b.verticalFOV && a.principalPoint == b.principalPoint && a.radial == b.radial
        }

        private mutating func prepare() {
            prepared = Prepared(projection: projection, yaw: yaw, pitch: pitch, roll: roll, horizontalFOV: horizontalFOV,
                                verticalFOV: verticalFOV, principalPoint: principalPoint, radial: radial)
        }
    }

    /// Where a sky direction falls in the picture, and through which lens.
    struct Hit: Codable, Sendable, Equatable {
        var lens: Int
        var point: PixelPoint
    }

    /// The sky direction of a pixel, and the lens it was seen through.
    struct LensDirection: Codable, Sendable, Equatable {
        var lens: Int
        var direction: SkyDirection
    }

    var layout: LensLayout
    /// A dual camera's split (x, 0…1): x < seam is the left lens's.
    var seam: Double
    /// One lens for `.single`; left and right for `.dual`.
    var lenses: [Lens]

    static let defaultSeam = 0.5
    /// The low-trust band around a dual camera's seam: this part of the picture's width (1 %, about 43 pixels of 4256), centred on the seam.
    static let seamBandWidth = 0.01
    /// A projection this close outside the picture (or the far side of the seam) is rounding: it counts as on the edge.
    static let edgeTolerance = 1e-9

    // MARK: The lenses and the seam

    var lensCount: Int { layout == .dual ? 2 : 1 }

    /// A lens's frame: its left edge and width in picture x (the whole picture, or a fixed half of a dual camera's).
    func frame(of lens: Int) -> (origin: Double, width: Double) {
        guard layout == .dual else { return (0, 1) }
        return lens == 0 ? (0, 0.5) : (0.5, 0.5)
    }

    /// The lens a pixel belongs to: 0 for a single lens; for a dual camera 0 (left) when x < seam, else 1 (right).
    func lens(at point: PixelPoint) -> Int {
        layout == .dual && !(point.x < seam) ? 1 : 0
    }

    /// A dual camera's seam band (picture x); nil for a single lens.
    var seamBand: ClosedRange<Double>? {
        guard layout == .dual, seam.isFinite else { return nil }
        return (seam - Self.seamBandWidth / 2)...(seam + Self.seamBandWidth / 2)
    }

    /// Whether a point is in the seam band, where the stitch blends: its direction is kept, but it does not count for fitting.
    func isInSeamBand(_ point: PixelPoint) -> Bool {
        seamBand?.contains(point.x) == true
    }

    // MARK: Projecting

    /// Every lens's hit for `direction`: where it falls through each lens, when that is inside the picture and on that lens's side of the
    /// seam. None behind the camera or outside the picture; two near the seam where the halves overlap.
    func project(_ direction: SkyDirection) -> [Hit] {
        (0..<lensCount).compactMap { lens in
            guard let point = project(direction, lens: lens), let inside = Self.inPicture(point), owns(lens, x: inside.x) else { return nil }
            return Hit(lens: lens, point: inside)
        }
    }

    /// Where `direction` falls through one lens (picture coordinates), anywhere: past the seam or the picture's edge too, as fitting needs
    /// for a sighting that a wrong aim puts there. Nil where the lens's projection has no point (behind a rectilinear lens), past its
    /// distortion's fold, or for a lens the model does not have.
    func project(_ direction: SkyDirection, lens: Int) -> PixelPoint? {
        guard let model = self.lens(lens), let local = model.localPoint(of: direction) else { return nil }
        let frame = frame(of: lens)
        return PixelPoint(x: frame.origin + local.x * frame.width, y: local.y)
    }

    /// The sky direction of a pixel, through the lens of the half it lies in (`lens(at:)`); nil when that lens has no direction there.
    func direction(at point: PixelPoint) -> LensDirection? {
        let index = lens(at: point)
        return direction(at: point, lens: index).map { LensDirection(lens: index, direction: $0) }
    }

    /// The sky direction of a pixel through one lens, wherever the pixel is: the distortion is undone to 1e-9 of the frame
    /// (`Lens.undistortedRadius`: Newton's method, with a bracketed search where it does not settle). Nil past the lens's distortion's fold,
    /// where its projection has no direction, or for a lens the model does not have.
    func direction(at point: PixelPoint, lens: Int) -> SkyDirection? {
        guard let model = self.lens(lens) else { return nil }
        let frame = frame(of: lens)
        return model.direction(atLocal: PixelPoint(x: (point.x - frame.origin) / frame.width, y: point.y))
    }

    /// The angle (degrees) that one pixel of a picture `pictureWidth` pixels wide spans across, at `point`, through the point's own lens.
    func degreesPerPixel(at point: PixelPoint, pictureWidth: Int) -> Double {
        let index = lens(at: point)
        let pixels = Double(max(1, pictureWidth))
        let half = 0.5 / pixels
        if let left = direction(at: PixelPoint(x: point.x - half, y: point.y), lens: index),
           let right = direction(at: PixelPoint(x: point.x + half, y: point.y), lens: index) {
            let angle = SkyMath.separation(left, right)
            if angle.isFinite { return angle }
        }
        // No direction there: the nominal angle, the field of view over the frame's pixels.
        let field = lens(index)?.horizontalFOV ?? 0
        return field.isFinite && field > 0 ? field / (pixels * frame(of: index).width) : 0
    }

    private func lens(_ index: Int) -> Lens? {
        index >= 0 && index < lensCount && index < lenses.count ? lenses[index] : nil
    }

    /// Whether picture x is on `lens`'s side of a dual camera's seam (rounding on the seam counts for both).
    private func owns(_ lens: Int, x: Double) -> Bool {
        guard layout == .dual else { return true }
        return lens == 0 ? x <= seam + Self.edgeTolerance : x >= seam - Self.edgeTolerance
    }

    /// `point` when it is in the picture (rounding at the edges clamped onto them), else nil.
    private static func inPicture(_ point: PixelPoint) -> PixelPoint? {
        let range = -edgeTolerance...(1 + edgeTolerance)
        guard range.contains(point.x), range.contains(point.y) else { return nil }
        return PixelPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }

    // MARK: The start

    /// The model a camera starts with, from the card's "faces" and "tilt" and the picture's size. 2:1 and wider is a dual camera (unless
    /// `layout` says otherwise): split 50/50, its lenses 90° across each half (180° edge to edge). Each lens is turned to its own azimuth
    /// (`azimuth` ∓ 45°) about the vertical first, then tilted up by `tilt` about its own horizontal axis: it looks at its azimuth at the
    /// card's tilt, unrolled, so a level skyline is level across each half however steep the card. (Turned about the tilted housing's own up
    /// instead, each lens of a card tilted 45° was rolled 35°, its skyline running from −18° at the outer end to +18° at the seam.) A level card's
    /// halves meet along the seam, the picture's centre facing (azimuth, 0); a tilted card's do not, since a pinhole tilted up leans its sides
    /// towards the zenith: near the top of the seam both halves see the same sky, near its foot neither does. Narrower is a single lens 100°
    /// across, facing (azimuth, tilt). Rectilinear, square pixels, principal points at the centres, no roll and no distortion: fitting refines
    /// each lens's pose on its own, and chooses its projection.
    static func initial(facing azimuth: Double, tilt: Double, pictureWidth: Int, pictureHeight: Int, layout: LensLayout? = nil) -> SkyCameraModel {
        let width = Double(max(1, pictureWidth)), height = Double(max(1, pictureHeight))
        let facing = azimuth.isFinite ? SkyMath.normalizedDegrees(azimuth) : 0
        let tilt = tilt.isFinite ? min(90, max(-90, tilt)) : 0
        let centre = PixelPoint(x: 0.5, y: 0.5)
        switch layout ?? (width / height >= 2 ? .dual : .single) {
        case .single:
            let lens = Lens(yaw: facing, pitch: tilt, roll: 0, horizontalFOV: 100,
                            verticalFOV: Lens.verticalFOV(horizontalFOV: 100, frameAspect: width / height), principalPoint: centre, radial: [])
            return SkyCameraModel(layout: .single, seam: defaultSeam, lenses: [lens])
        case .dual:
            let across = 90.0
            let vertical = Lens.verticalFOV(horizontalFOV: across, frameAspect: width / 2 / height)
            let lenses = [-across / 2, across / 2].map { turn in
                Lens(yaw: SkyMath.normalizedDegrees(facing + turn), pitch: tilt, roll: 0, horizontalFOV: across, verticalFOV: vertical,
                     principalPoint: centre, radial: [])
            }
            return SkyCameraModel(layout: .dual, seam: defaultSeam, lenses: lenses)
        }
    }
}

extension SkyCameraModel.Lens {
    /// The lens whose optical axis is `forward` and whose frame's up is `up` (unit and at right angles, east-north-up; right is then
    /// forward × up, so a mirrored frame cannot be given): its yaw and pitch are where `forward` points, its roll how far `up` is turned
    /// from the level up about it.
    init(projection: SkyCameraModel.LensProjection = .rectilinear, up: SIMD3<Double>, forward: SIMD3<Double>, horizontalFOV: Double,
         verticalFOV: Double, principalPoint: PixelPoint, radial: [Double]) {
        let axis = SkyMath.direction(of: forward)
        let level = SkyCameraModel.Lens(yaw: axis.azimuth, pitch: axis.elevation, roll: 0, horizontalFOV: horizontalFOV,
                                        verticalFOV: verticalFOV, principalPoint: principalPoint, radial: radial).axes
        let roll = atan2(SkyMath.dot(up, level.right), SkyMath.dot(up, level.up)) * SkyMath.degrees
        self.init(projection: projection, yaw: axis.azimuth, pitch: axis.elevation, roll: roll, horizontalFOV: horizontalFOV,
                  verticalFOV: verticalFOV, principalPoint: principalPoint, radial: radial)
    }

    /// The vertical field of view that goes with `horizontalFOV` on a frame `frameAspect` (width / height) wide, for square pixels at the
    /// frame's centre in `projection`.
    static func verticalFOV(horizontalFOV: Double, frameAspect: Double, projection: SkyCameraModel.LensProjection = .rectilinear) -> Double {
        let horizontal = horizontalFOV / 2 * SkyMath.radians
        switch projection {
        case .rectilinear: return 2 * atan(tan(horizontal) / frameAspect) * SkyMath.degrees
        case .equidistant, .equirectangular: return horizontalFOV / frameAspect
        case .cylindrical: return 2 * atan(horizontal / frameAspect) * SkyMath.degrees
        }
    }

    /// The lens's axes in the observer's east-north-up frame: `forward` along the optical axis, `right` and `up` along the frame's x and −y.
    var axes: (right: SIMD3<Double>, up: SIMD3<Double>, forward: SIMD3<Double>) {
        (prepared.right, prepared.up, prepared.forward)
    }

    // MARK: Projecting through the lens

    /// Where `direction` falls in the lens's own frame (x and y 0…1 across it; not limited to it): nil where the projection has no point
    /// (behind a rectilinear lens, straight behind an equidistant one, straight up or down a cylindrical one's frame), past the distortion's
    /// fold (where r_d stops growing, so the polynomial would fold far directions back into the picture), or for a lens that is not valid.
    /// Straight up or down an equirectangular lens's frame is on its top or bottom line (at the centre column only for a level lens).
    func localPoint(of direction: SkyDirection) -> PixelPoint? {
        localPoint(ofUnit: SkyMath.unitVector(direction))
    }

    /// `localPoint(of:)` for a direction given as its unit vector (east-north-up), as fitting has it: no trigonometry to get there.
    func localPoint(ofUnit sky: SIMD3<Double>) -> PixelPoint? {
        let lens = prepared
        guard lens.isValid else { return nil }
        guard let plane = Self.plane(projection, x: SkyMath.dot(sky, lens.right), y: SkyMath.dot(sky, lens.up), z: SkyMath.dot(sky, lens.forward))
        else { return nil }
        let squared = plane.a * plane.a + plane.b * plane.b
        guard squared.isFinite, squared < lens.foldSquared else { return nil }
        let scale = lens.distortion(squared)
        let point = PixelPoint(x: principalPoint.x + 0.5 * plane.a * scale / lens.scaleAcross,
                               y: principalPoint.y - 0.5 * plane.b * scale / lens.scaleUp)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }

    /// The sky direction of a point of the lens's own frame: the distortion is undone to 1e-9 of the frame (`undistortedRadius`: Newton's
    /// method, with a bracketed search where it does not settle). Nil past the distortion's fold, where the projection has no direction, or
    /// for a lens that is not valid.
    func direction(atLocal point: PixelPoint) -> SkyDirection? {
        let lens = prepared
        guard lens.isValid, point.x.isFinite, point.y.isFinite else { return nil }
        var a = (point.x - principalPoint.x) * 2 * lens.scaleAcross
        var b = (principalPoint.y - point.y) * 2 * lens.scaleUp
        let distorted = (a * a + b * b).squareRoot()
        if distorted > 0 {
            // 1e-9 of the frame is 2e-9 times the focal scale in the normalized plane.
            guard let radius = undistortedRadius(distorted, tolerance: 2e-9 * min(lens.scaleAcross, lens.scaleUp)) else { return nil }
            a *= radius / distorted
            b *= radius / distorted
        }
        guard let ray = Self.ray(projection, a: a, b: b) else { return nil }
        return SkyMath.direction(of: lens.right * ray.x + lens.up * ray.y + lens.forward * ray.z)
    }

    /// A lens-frame direction (x right, y up, z along the axis; unit) on `projection`'s normalized plane, before the radial terms.
    private static func plane(_ projection: SkyCameraModel.LensProjection, x: Double, y: Double, z: Double) -> (a: Double, b: Double)? {
        switch projection {
        case .rectilinear:
            guard z > 0 else { return nil }
            return (x / z, y / z)
        case .equidistant:
            let aside = (x * x + y * y).squareRoot()
            let angle = atan2(aside, z)
            guard angle < .pi else { return nil }
            return aside > 0 ? (x / aside * angle, y / aside * angle) : (0, 0)
        case .cylindrical:
            let level = (x * x + z * z).squareRoot()
            guard level > 0 else { return nil }
            return (atan2(x, z), y / level)
        case .equirectangular:
            return (atan2(x, z), atan2(y, (x * x + z * z).squareRoot()))
        }
    }

    /// The lens-frame direction (any length) of a point of `projection`'s normalized plane; nil where it has none.
    private static func ray(_ projection: SkyCameraModel.LensProjection, a: Double, b: Double) -> SIMD3<Double>? {
        switch projection {
        case .rectilinear:
            return SIMD3(a, b, 1)
        case .equidistant:
            let angle = (a * a + b * b).squareRoot()
            guard angle < .pi else { return nil }
            guard angle > 0 else { return SIMD3(0, 0, 1) }
            let aside = sin(angle) / angle
            return SIMD3(a * aside, b * aside, cos(angle))
        case .cylindrical:
            guard abs(a) <= .pi else { return nil }
            return SIMD3(sin(a), b, cos(a))
        case .equirectangular:
            guard abs(a) <= .pi, abs(b) <= .pi / 2 else { return nil }
            return SIMD3(cos(b) * sin(a), sin(b), cos(b) * cos(a))
        }
    }

    // MARK: Brown radial distortion

    /// r_d = r(1 + k1 r² + k2 r⁴ + k3 r⁶).
    func distortedRadius(_ radius: Double) -> Double {
        radius * prepared.distortion(radius * radius)
    }

    /// The radius r whose `distortedRadius` is `distorted`, on the part of the curve that grows from the centre: Newton's method from r =
    /// r_d (at most 10 steps), and where that does not settle (a steep or wavy polynomial far out, or next to the fold, where the slope goes
    /// to zero) a bracketed search between the centre and the fold. Kept when it is within `tolerance` of r_d. Nil when there is none (r_d
    /// larger than the curve reaches before its fold).
    func undistortedRadius(_ distorted: Double, tolerance: Double = 1e-12) -> Double? {
        guard distorted.isFinite, distorted >= 0 else { return nil }
        let lens = prepared
        let converged = 1e-14 * max(1, distorted)
        var radius = distorted
        for _ in 0..<10 {
            let squared = radius * radius
            let error = radius * lens.distortion(squared) - distorted
            if abs(error) <= converged { break }
            let slope = lens.slope(squared)
            guard slope > 0 else { break }
            let next = radius - error / slope
            radius = next > 0 ? next : radius / 2
        }
        let squared = radius * radius
        if radius.isFinite, abs(radius * lens.distortion(squared) - distorted) <= tolerance, squared < lens.foldSquared { return radius }
        return bracketedRadius(distorted, tolerance: tolerance)
    }

    /// `undistortedRadius` by a bracketed search: r_d grows from 0 at the centre up to the fold (or for ever, with no fold), so the radius
    /// lies between the centre and the fold (or the first radius found past it by doubling). Newton's steps are kept inside the bracket;
    /// halving takes over where one would leave it.
    private func bracketedRadius(_ distorted: Double, tolerance: Double) -> Double? {
        let lens = prepared
        func error(_ radius: Double) -> Double { radius * lens.distortion(radius * radius) - distorted }
        var low = 0.0, high: Double
        if lens.foldSquared.isFinite {
            high = lens.foldSquared.squareRoot()
            while high > 0 && high * high >= lens.foldSquared { high = high.nextDown }
            guard error(high) >= 0 else { return nil }   // r_d does not get that far before the fold
        } else {
            high = max(1, distorted)
            while error(high) < 0 {
                high *= 2
                guard high.isFinite else { return nil }
            }
        }
        let converged = 1e-14 * max(1, distorted)
        var radius = (low + high) / 2
        for _ in 0..<200 {
            let miss = error(radius)
            if abs(miss) <= converged { break }
            if miss < 0 { low = radius } else { high = radius }
            let slope = lens.slope(radius * radius)
            let next = slope > 0 ? radius - miss / slope : -1
            radius = next > low && next < high ? next : (low + high) / 2
            if high - low <= 1e-16 * max(1, high) { break }
        }
        return radius * radius < lens.foldSquared && abs(error(radius)) <= tolerance ? radius : nil
    }

    /// Whether r_d grows all the way from the centre to r² = `squared` (it has not reached its fold).
    func isMonotonic(upToSquaredRadius squared: Double) -> Bool {
        squared < prepared.foldSquared
    }
}

/// What a lens's numbers give, worked out once: its axes, its focal scales (the normalized plane's value at half the frame's width and
/// height), its distortion's terms and the r² of its fold.
private struct Prepared: Sendable {
    var right: SIMD3<Double>
    var up: SIMD3<Double>
    var forward: SIMD3<Double>
    var isValid: Bool
    var scaleAcross: Double
    var scaleUp: Double
    var k1: Double
    var k2: Double
    var k3: Double
    var foldSquared: Double

    init(projection: SkyCameraModel.LensProjection, yaw: Double, pitch: Double, roll: Double, horizontalFOV: Double, verticalFOV: Double,
         principalPoint: PixelPoint, radial: [Double]) {
        forward = SkyMath.unitVector(SkyDirection(azimuth: yaw, elevation: pitch))
        let turn = yaw * SkyMath.radians, twist = roll * SkyMath.radians
        let levelRight = SIMD3(cos(turn), -sin(turn), 0)
        let levelUp = SkyMath.cross(levelRight, forward)
        right = levelRight * cos(twist) - levelUp * sin(twist)
        up = levelUp * cos(twist) + levelRight * sin(twist)
        k1 = radial.count > 0 ? radial[0] : 0
        k2 = radial.count > 1 ? radial[1] : 0
        k3 = radial.count > 2 ? radial[2] : 0
        let across = horizontalFOV / 2 * SkyMath.radians, upward = verticalFOV / 2 * SkyMath.radians
        let fieldsFit: Bool
        switch projection {
        case .rectilinear:
            (scaleAcross, scaleUp) = (tan(across), tan(upward))
            fieldsFit = horizontalFOV < 180 && verticalFOV < 180
        case .equidistant:
            (scaleAcross, scaleUp) = (across, upward)
            fieldsFit = horizontalFOV < 360 && verticalFOV < 360
        case .cylindrical:
            (scaleAcross, scaleUp) = (across, tan(upward))
            fieldsFit = horizontalFOV < 360 && verticalFOV < 180
        case .equirectangular:
            (scaleAcross, scaleUp) = (across, upward)
            fieldsFit = horizontalFOV < 360 && verticalFOV <= 180
        }
        isValid = horizontalFOV > 0 && verticalFOV > 0 && fieldsFit
            && [yaw, pitch, roll, principalPoint.x, principalPoint.y].allSatisfy(\.isFinite) && radial.allSatisfy(\.isFinite)
        foldSquared = Self.fold(k1, k2, k3)
    }

    /// 1 + k1 q + k2 q² + k3 q³ at q = r².
    func distortion(_ squared: Double) -> Double {
        1 + squared * (k1 + squared * (k2 + squared * k3))
    }

    /// d r_d / d r at q = r².
    func slope(_ squared: Double) -> Double {
        1 + squared * (3 * k1 + squared * (5 * k2 + squared * 7 * k3))
    }

    /// The first r² at which r_d stops growing (its slope 1 + 3k1 q + 5k2 q² + 7k3 q³ reaches zero), or infinity. The slope is 1 at the
    /// centre and monotonic between its turning points, so the fold is in the first stretch that ends at or below zero.
    static func fold(_ k1: Double, _ k2: Double, _ k3: Double) -> Double {
        func slope(_ q: Double) -> Double { 1 + q * (3 * k1 + q * (5 * k2 + q * 7 * k3)) }
        var start = 0.0
        for end in turningPoints(k1, k2, k3).filter({ $0 > 0 }).sorted() {
            if !(slope(end) > 0) { return root(slope, from: start, to: end) }
            start = end
        }
        // After the last turning point the slope follows its highest term.
        let leading = k3 != 0 ? k3 : k2 != 0 ? k2 : k1
        guard leading < 0 else { return .infinity }
        var end = max(1, start * 2)
        while slope(end) > 0 {
            end *= 2
            if end > 1e12 { return .infinity }
        }
        return root(slope, from: start, to: end)
    }

    /// Where the slope turns (q with 3k1 + 10k2 q + 21k3 q² = 0).
    private static func turningPoints(_ k1: Double, _ k2: Double, _ k3: Double) -> [Double] {
        let a = 21 * k3, b = 10 * k2, c = 3 * k1
        guard a != 0 else { return b != 0 ? [-c / b] : [] }
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return [] }
        let q = -(b + (b < 0 ? -1 : 1) * discriminant.squareRoot()) / 2
        return q != 0 ? [q / a, c / q] : [0]
    }

    /// Where `slope` (positive at `from`, not at `to`) first reaches zero, by halving: the end that is not positive.
    private static func root(_ slope: (Double) -> Double, from: Double, to: Double) -> Double {
        var low = from, high = to
        for _ in 0..<200 {
            let middle = (low + high) / 2
            if middle <= low || middle >= high { break }
            if slope(middle) > 0 { low = middle } else { high = middle }
        }
        return high
    }
}
