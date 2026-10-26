import Foundation

/// The Sun's guard by day. With the Sun just outside the view, its light floods the lens's side nearest it: glare, a lens's flare, and specks,
/// bugs and leaves lit from behind. On the owner's camera, the late afternoon of 2026-10-25, about four lights a minute that lasted under 5 s
/// were logged at x 0 to 20 % and y 60 to 80 % of the picture, the left lens's outer (west) edge, with the Sun low beyond it.
///
/// - **When**: while the Sun is up (above −6°, as the mask has it: `SkyMask.sunMaskedAbove`), and outside the view but within `nearDegrees`
///   (25°) of its nearest picture edge, `roughNearDegrees` (40°) while the aim is rough: a card's facing and tilt are only guessed, to about
///   15°, so the guard is generous then. A dual camera's seam is no edge of the picture: the Sun past it is in the other lens's view.
/// - **Where**: a band along that edge, `bandDegrees` (25°) deep into the lens's frame, `roughBandDegrees` (40°) while the aim is rough, as a
///   share of the lens's field across (the left and right edges) or up and down (the top and bottom). North Sky's left lens is 90° across:
///   the rough band is its outer 44 %, x 0 to 22 % of the picture.
/// - **What**: a light that nothing explains and whose whole path lies in the band is not logged, only counted (`SkyCameraDetector`). A light
///   that leaves the band is logged, and so is a plane anywhere: planes are still matched first.
/// - With the Sun in the view, its circle of the mask is the guard (`SkyMask.sunCircles`: nothing is looked for within 15° of it), as before.
enum SkySunGuard {
    static let nearDegrees = 25.0
    static let roughNearDegrees = 40.0
    static let bandDegrees = 25.0
    static let roughBandDegrees = 40.0
    /// Points looked at along each edge to find how far the Sun is from it (its ends, the corners, included).
    static let edgeSamples = 17

    /// An edge of a lens's frame.
    enum Edge: String, Sendable {
        case left, right, top, bottom
    }

    /// The band of the picture the Sun guards: along `edge` of `lens`'s frame, `depth` of the frame deep (0…1 of its width for the left and right
    /// edges, of its height for the top and bottom); `sunDistance` is how far outside the view the Sun is (degrees, to the edge's nearest point).
    struct Band: Sendable, Equatable {
        var lens: Int
        var edge: Edge
        var depth: Double
        var sunDistance: Double
    }

    /// The band the Sun guards at `date` from `observer`, through `model` at its aim; nil while the Sun is down, in the view, or far from it.
    static func band(at date: Date, observer: SkyObserver, model: SkyCameraModel, aim: SkyAimQuality) -> Band? {
        let sun = SunEphemeris.direction(at: date, observer: observer)
        guard sun.elevation > SkyMask.sunMaskedAbove else { return nil }
        return band(sun: sun, model: model, aim: aim)
    }

    /// The band the Sun at `sun` guards through `model` at its aim; nil when the Sun is in the picture (its circle guards it) or not near enough
    /// to any edge of it.
    static func band(sun: SkyDirection, model: SkyCameraModel, aim: SkyAimQuality) -> Band? {
        guard sun.azimuth.isFinite, sun.elevation.isFinite, model.project(sun).isEmpty else { return nil }
        var nearest: (lens: Int, edge: Edge, distance: Double)?
        for lens in 0..<model.lensCount {
            for edge in pictureEdges(of: lens, in: model) {
                let distances = points(along: edge).compactMap { local -> Double? in
                    guard let direction = model.direction(at: picturePoint(local, lens: lens, in: model), lens: lens) else { return nil }
                    let separation = SkyMath.separation(direction, sun)
                    return separation.isFinite ? separation : nil
                }
                guard let distance = distances.min() else { continue }
                if nearest.map({ distance < $0.distance }) ?? true { nearest = (lens, edge, distance) }
            }
        }
        let rough = aim == .rough
        guard let nearest, nearest.distance <= (rough ? roughNearDegrees : nearDegrees), model.lenses.indices.contains(nearest.lens) else { return nil }
        let lens = model.lenses[nearest.lens]
        let field = nearest.edge == .left || nearest.edge == .right ? lens.horizontalFOV : lens.verticalFOV
        guard field.isFinite, field > 0 else { return nil }
        return Band(lens: nearest.lens, edge: nearest.edge, depth: min(1, (rough ? roughBandDegrees : bandDegrees) / field), sunDistance: nearest.distance)
    }

    /// Whether every one of `points` (0…1 of the picture) lies in `band`: in its lens's part of the picture, and within its depth of its edge.
    static func covers(_ points: [PixelPoint], band: Band, model: SkyCameraModel) -> Bool {
        let frame = model.frame(of: band.lens)
        guard !points.isEmpty, frame.width > 0 else { return false }
        return points.allSatisfy { point in
            guard point.x.isFinite, point.y.isFinite, model.lens(at: point) == band.lens else { return false }
            let x = (point.x - frame.origin) / frame.width, y = point.y
            switch band.edge {
            case .left: return x <= band.depth
            case .right: return x >= 1 - band.depth
            case .top: return y <= band.depth
            case .bottom: return y >= 1 - band.depth
            }
        }
    }

    /// Whether `track`'s whole path lies in `band`.
    static func covers(_ track: SkyTrack, band: Band, model: SkyCameraModel) -> Bool {
        covers(track.samples.map(\.point), band: band, model: model)
    }

    /// A lens's edges that are edges of the picture: all four of a single lens; a dual camera's lenses without the seam.
    private static func pictureEdges(of lens: Int, in model: SkyCameraModel) -> [Edge] {
        guard model.layout == .dual else { return [.left, .right, .top, .bottom] }
        return lens == 0 ? [.left, .top, .bottom] : [.right, .top, .bottom]
    }

    /// `edgeSamples` points along `edge` of a lens's frame (its own 0…1).
    private static func points(along edge: Edge) -> [PixelPoint] {
        (0..<edgeSamples).map { index in
            let along = Double(index) / Double(edgeSamples - 1)
            switch edge {
            case .left: return PixelPoint(x: 0, y: along)
            case .right: return PixelPoint(x: 1, y: along)
            case .top: return PixelPoint(x: along, y: 0)
            case .bottom: return PixelPoint(x: along, y: 1)
            }
        }
    }

    private static func picturePoint(_ local: PixelPoint, lens: Int, in model: SkyCameraModel) -> PixelPoint {
        let frame = model.frame(of: lens)
        return PixelPoint(x: frame.origin + local.x * frame.width, y: local.y)
    }
}
