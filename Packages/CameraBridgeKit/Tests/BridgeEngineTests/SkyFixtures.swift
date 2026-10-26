import Foundation
import MediaCore
@testable import BridgeEngine

/// Made-up data for the sky detector's tests: the location and the truth camera models (later tasks add flights, orbits and stars). Nothing
/// here is a real place, camera, feed or key.
enum SkyFixtures {
    /// The made-up location of every sky test: latitude 40.0000, longitude −100.0000 (100° W), height 0 m.
    static let observer = SkyObserver(latitude: 40.0, longitude: -100.0, heightMeters: 0)

    /// A rectilinear single-lens camera (16:9) looking south-west and up, with barrel distortion, a little roll and its principal point off
    /// the centre.
    static let truthSingle = SkyCameraModel(
        layout: .single, seam: SkyCameraModel.defaultSeam,
        lenses: [SkyCameraModel.Lens(yaw: 212.5, pitch: 24, roll: 1.5, horizontalFOV: 100, verticalFOV: 67.67,
                                     principalPoint: PixelPoint(x: 0.507, y: 0.494), radial: [-0.25, 0.08, -0.002])])

    /// A dual-lens camera stitched on the camera (a 4256×1888 picture, the housing facing 352° and tilted up 18°). The halves have different
    /// poses, fields of view, principal points and radial terms, and they meet along the seam as a stitch does: each covers 90° across its
    /// half with its distortion, and each lens's seam column, seen through the other lens, is inside the seam band on the other's side (they
    /// overlap by a few pixels). Tuned offline. Strong radial terms bow the two seam columns in opposite directions, so these are small.
    static let truthDual = SkyCameraModel(
        layout: .dual, seam: 0.5,
        lenses: [
            SkyCameraModel.Lens(yaw: 305.963, pitch: 12.321, roll: -12.439, horizontalFOV: 89.124, verticalFOV: 82.291,
                                principalPoint: PixelPoint(x: 0.496, y: 0.504), radial: [-0.018, 0.003, -0.000_2]),
            SkyCameraModel.Lens(yaw: 39.172, pitch: 12.279, roll: 12.959, horizontalFOV: 89.311, verticalFOV: 82.477,
                                principalPoint: PixelPoint(x: 0.505, y: 0.497), radial: [-0.014, 0.002]),
        ])

    /// An equidistant (fisheye) single lens, 160° by 120°, looking south-east and well up, with small radial terms.
    static let truthEquidistant = SkyCameraModel(
        layout: .single, seam: SkyCameraModel.defaultSeam,
        lenses: [SkyCameraModel.Lens(projection: .equidistant, yaw: 140, pitch: 35, roll: -2, horizontalFOV: 160, verticalFOV: 120,
                                     principalPoint: PixelPoint(x: 0.495, y: 0.503), radial: [0.02, -0.003, 0.000_4])])

    /// A cylindrical single lens (a panorama 120° by 70°) facing east-north-east, with small radial terms.
    static let truthCylindrical = SkyCameraModel(
        layout: .single, seam: SkyCameraModel.defaultSeam,
        lenses: [SkyCameraModel.Lens(projection: .cylindrical, yaw: 75, pitch: 10, roll: 0.8, horizontalFOV: 120, verticalFOV: 70,
                                     principalPoint: PixelPoint(x: 0.502, y: 0.49), radial: [-0.03, 0.004])])

    /// An equirectangular single lens (a panorama 200° by 90°) facing west, with small radial terms.
    static let truthEquirectangular = SkyCameraModel(
        layout: .single, seam: SkyCameraModel.defaultSeam,
        lenses: [SkyCameraModel.Lens(projection: .equirectangular, yaw: 265, pitch: 15, roll: -1.2, horizontalFOV: 200, verticalFOV: 90,
                                     principalPoint: PixelPoint(x: 0.497, y: 0.506), radial: [0.015, -0.002])])

    /// A dual camera whose halves have different projections (a cylindrical left half, an equidistant right one): each is its own camera.
    static let truthMixedDual = SkyCameraModel(layout: .dual, seam: 0.5, lenses: [truthCylindrical.lenses[0], truthEquidistant.lenses[0]])

    /// A dual camera stitched angle-linear both ways (equirectangular halves; the housing faces 10° and is tilted up 15°), each half with a
    /// slightly different pose, fields of view, principal point and radial terms.
    static let truthEquirectangularDual = SkyCameraModel(
        layout: .dual, seam: 0.5,
        lenses: [
            SkyCameraModel.Lens(projection: .equirectangular, yaw: 324.2, pitch: 10.4, roll: -10.6, horizontalFOV: 90.4, verticalFOV: 79.9,
                                principalPoint: PixelPoint(x: 0.502, y: 0.498), radial: [0.01]),
            SkyCameraModel.Lens(projection: .equirectangular, yaw: 55.8, pitch: 10.7, roll: 10.9, horizontalFOV: 89.7, verticalFOV: 79.6,
                                principalPoint: PixelPoint(x: 0.497, y: 0.503), radial: [-0.008, 0.001]),
        ])

    /// The truth dual camera with its left half stretched up and down: its vertical field 4 % larger than square pixels give (85.58° against
    /// 82.29°), as a stitch can leave a half. Only a fit that frees the vertical field (stage 3) follows it.
    static let truthStretchedDual: SkyCameraModel = {
        var model = truthDual
        model.lenses[0].verticalFOV *= 1.04
        return model
    }()

    /// A dual camera stitched as one seamless panorama in its own tilted frame, as North Sky's picture is (its night sky showed it on
    /// 2026-10-26): the housing faces `facing` and is tilted up by `tilt`, and each half is an equirectangular lens 90° across, the housing
    /// turned 45° to its side about the housing's own up (so the halves meet all down the seam), with square pixels in angle on a 4256×1888
    /// picture. Built here, not with `SkyCameraModel.initial`.
    static func stitchedPanorama(facing: Double, tilt: Double) -> SkyCameraModel {
        let radians = Double.pi / 180
        let forward = SkyMath.unitVector(SkyDirection(azimuth: facing, elevation: tilt))
        let up = SkyMath.unitVector(SkyDirection(azimuth: SkyMath.normalizedDegrees(facing + 180), elevation: 90 - tilt))
        let right = SkyMath.cross(forward, up)
        let lenses = [-45.0, 45.0].map { turn in
            SkyCameraModel.Lens(projection: .equirectangular, up: up, forward: forward * cos(turn * radians) + right * sin(turn * radians),
                                horizontalFOV: 90, verticalFOV: 90 * 1888 / 2128, principalPoint: PixelPoint(x: 0.5, y: 0.5), radial: [])
        }
        return SkyCameraModel(layout: .dual, seam: 0.5, lenses: lenses)
    }

    /// Every projection, as a single lens and as the halves of a dual camera.
    static let truthModels = [truthSingle, truthEquidistant, truthCylindrical, truthEquirectangular, truthDual, truthMixedDual,
                              truthEquirectangularDual]

    /// The difference between two azimuths (degrees, 0…180), across north too.
    static func azimuthDifference(_ a: Double, _ b: Double) -> Double {
        abs((a - b).remainder(dividingBy: 360))
    }
}

// MARK: Made-up matches for aiming

extension SkyFixtures {
    /// When the made-up matches were seen: 2026-10-25 03:00 UTC, then one a second.
    static let aimEpoch = Date(timeIntervalSince1970: 1_792_897_200)

    /// `direction` moved `degrees` along the great circle that leaves it at `bearing` (radians from north, through east).
    static func offset(_ direction: SkyDirection, by degrees: Double, toward bearing: Double) -> SkyDirection {
        let radians = Double.pi / 180
        let azimuth = direction.azimuth * radians, elevation = direction.elevation * radians
        let east = SIMD3(cos(azimuth), -sin(azimuth), 0.0)
        let north = SIMD3(-sin(elevation) * sin(azimuth), -sin(elevation) * cos(azimuth), cos(elevation))
        let toward = east * sin(bearing) + north * cos(bearing), size = degrees * radians
        return SkyMath.direction(of: SkyMath.unitVector(direction) * cos(size) + toward * sin(size))
    }

    /// The noise of the made-up matches: `direction` moved by up to `maximum` degrees in a random direction, uniformly over the disc of that
    /// radius (so the offsets' RMS is maximum / √2).
    static func noisy(_ direction: SkyDirection, upTo maximum: Double, using random: inout some RandomNumberGenerator) -> SkyDirection {
        let bearing = Double.random(in: 0..<(2 * Double.pi), using: &random)
        return offset(direction, by: maximum * Double.random(in: 0...1, using: &random).squareRoot(), toward: bearing)
    }

    /// A random direction above `elevation` degrees, uniform over that part of the sky.
    static func randomDirection(above elevation: Double, using random: inout some RandomNumberGenerator) -> SkyDirection {
        let height = Double.random(in: sin(elevation * Double.pi / 180)...1, using: &random)
        return SkyDirection(azimuth: Double.random(in: 0..<360, using: &random), elevation: asin(height) * 180 / Double.pi)
    }

    /// Made-up plane tracks for `truth`: for each lens, `perLens` straight great-circle paths across the part of the sky it sees (above 2°),
    /// each sampled `samples` times 1.5–4° apart. Every sample is a match: the pixel where `truth` sees it (in that lens, outside the seam
    /// band) and its direction moved by up to `noise` degrees. Each track is one aircraft, with a hex of its own.
    static func planeTracks(through truth: SkyCameraModel, perLens: Int, samples: Int, noise: Double,
                            using random: inout some RandomNumberGenerator) -> [AimCorrespondence] {
        var matches: [AimCorrespondence] = []
        for lens in 0..<truth.lensCount {
            let frame = truth.frame(of: lens)
            var tracks = 0, attempts = 0
            while tracks < perLens && attempts < 10_000 {
                attempts += 1
                let start = PixelPoint(x: frame.origin + frame.width * Double.random(in: 0.1...0.9, using: &random),
                                       y: Double.random(in: 0.05...0.6, using: &random))
                guard let first = truth.direction(at: start, lens: lens), first.elevation >= 3 else { continue }
                let bearing = Double.random(in: 0..<(2 * Double.pi), using: &random), step = Double.random(in: 1.5...4, using: &random)
                var track: [AimCorrespondence] = []
                for sample in 0..<samples {
                    let direction = offset(first, by: step * Double(sample), toward: bearing)
                    guard direction.elevation >= 2,
                          let hit = truth.project(direction).first(where: { $0.lens == lens && !truth.isInSeamBand($0.point) }) else { break }
                    track.append(AimCorrespondence(point: hit.point, direction: noisy(direction, upTo: noise, using: &random), source: .plane,
                                                   at: aimEpoch.addingTimeInterval(Double(matches.count + track.count)),
                                                   object: "a\(lens)" + String(0x1000 + tracks, radix: 16)))
                }
                guard track.count == samples else { continue }
                matches += track
                tracks += 1
            }
        }
        return matches
    }

    /// Made-up stars for `truth`: random directions above 5° elevation (uniform over that part of the sky), kept where `truth` sees them
    /// outside the seam band (and where `keep` says) until each of `lenses` (every lens unless given) has `perLens`. Each is a match: the pixel
    /// where `truth` sees it and its direction moved by up to `noise` degrees, one star (a number of its own) each.
    static func stars(through truth: SkyCameraModel, perLens: Int, noise: Double, lenses: [Int]? = nil,
                      where keep: (PixelPoint) -> Bool = { _ in true }, using random: inout some RandomNumberGenerator) -> [AimCorrespondence] {
        var matches: [AimCorrespondence] = []
        var wanted = Array(repeating: 0, count: truth.lensCount)
        for lens in lenses ?? Array(0..<truth.lensCount) { wanted[lens] = perLens }
        var draws = 0
        while wanted.contains(where: { $0 > 0 }) && draws < 2_000_000 {
            draws += 1
            let direction = randomDirection(above: 5, using: &random)
            guard let hit = truth.project(direction).first(where: { !truth.isInSeamBand($0.point) && keep($0.point) }), wanted[hit.lens] > 0
            else { continue }
            wanted[hit.lens] -= 1
            matches.append(AimCorrespondence(point: hit.point, direction: noisy(direction, upTo: noise, using: &random), source: .star,
                                             at: aimEpoch.addingTimeInterval(Double(matches.count)), object: "\(1 + matches.count)"))
        }
        return matches
    }
}

// MARK: Made-up pictures for detection

/// A made-up analysed picture (luma, 0…255 once rounded): a flat sky with Gaussian noise, to which dots (3×3 Gaussians), 1-px "stars" and
/// streaks are added.
struct SkyPicture {
    let width: Int
    let height: Int
    var values: [Float]

    /// 2^20 Gaussian values of σ 1 (seeded), shared by every picture. Each picture reads them in its own order, from a random start with a
    /// random odd stride, so no two pictures share a pattern (a shifted copy of one picture's noise in the next would look like motion).
    static let bank: [Float] = {
        var random = SkyRandom(seed: 0x5EED_5C1E)
        var values = [Float](repeating: 0, count: 1 << 20)
        var index = 0
        while index < values.count {
            let u1 = Double.random(in: Double.ulpOfOne..<1, using: &random), u2 = Double.random(in: 0..<1, using: &random)
            let radius = (-2 * log(u1)).squareRoot(), angle = 2 * Double.pi * u2
            values[index] = Float(radius * cos(angle))
            if index + 1 < values.count { values[index + 1] = Float(radius * sin(angle)) }
            index += 2
        }
        return values
    }()

    /// A sky at `sky` with noise of σ `noise`.
    init(width: Int = 640, height: Int = 284, sky: Float = 30, noise: Float = 3, using random: inout SkyRandom) {
        self.width = width
        self.height = height
        let mask = Self.bank.count - 1
        let start = Int(random.next() & UInt64(mask)), stride = Int(random.next() & UInt64(mask)) | 1
        var values = [Float](repeating: sky, count: width * height)
        if noise != 0 {
            Self.bank.withUnsafeBufferPointer { bank in
                for index in values.indices { values[index] += noise * bank[(start &+ index &* stride) & mask] }
            }
        }
        self.values = values
    }

    /// A dot: a Gaussian of `spread` px over the 3×3 pixels around the one that holds (x, y) (pixel i covers i…i+1).
    mutating func dot(x: Double, y: Double, amplitude: Float, spread: Double = 0.7) {
        let column = Int(x.rounded(.down)), row = Int(y.rounded(.down))
        for j in (row - 1)...(row + 1) where j >= 0 && j < height {
            for i in (column - 1)...(column + 1) where i >= 0 && i < width {
                let dx = Double(i) + 0.5 - x, dy = Double(j) + 0.5 - y
                values[j * width + i] += amplitude * Float(exp(-(dx * dx + dy * dy) / (2 * spread * spread)))
            }
        }
    }

    /// A 1-px point.
    mutating func star(x: Int, y: Int, amplitude: Float) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        values[y * width + x] += amplitude
    }

    /// A streak one pixel thick: `length` pixels from (x, y) along `angle` (degrees from the x axis towards y), each the pixel nearest its
    /// point.
    mutating func streak(x: Double, y: Double, length: Int, angle: Double = 0, amplitude: Float) {
        let cosine = cos(angle * Double.pi / 180), sine = sin(angle * Double.pi / 180)
        var seen = Set<Int>()
        for step in 0..<length {
            let i = Int((x + Double(step) * cosine).rounded(.down)), j = Int((y + Double(step) * sine).rounded(.down))
            guard i >= 0, i < width, j >= 0, j < height, seen.insert(j * width + i).inserted else { continue }
            values[j * width + i] += amplitude
        }
    }

    /// Every pixel `level` brighter (darker when negative): the IR-cut switch, an exposure step.
    mutating func brighten(by level: Float) {
        for index in values.indices { values[index] += level }
    }

    /// Each pixel brighter by `level(x, y)`: a sky that brightens unevenly.
    mutating func brighten(by level: (Int, Int) -> Float) {
        for y in 0..<height {
            for x in 0..<width { values[y * width + x] += level(x, y) }
        }
    }

    /// A camera's single-pixel sensor speckle: `share` of the pixels, at random, each a spike of an exponentially distributed height of
    /// mean `mean` levels (its neighbours untouched).
    mutating func speckle(share: Double, mean: Double, using random: inout SkyRandom) {
        for _ in 0..<Int((Double(values.count) * share).rounded()) {
            let index = Int.random(in: 0..<values.count, using: &random)
            values[index] += Float(-mean * log(Double.random(in: Double.ulpOfOne..<1, using: &random)))
        }
    }

    var image: GrayImage {
        GrayImage(width: width, height: height, pixels: values.map { UInt8(clamping: Int($0.rounded())) })
    }
}

// MARK: Made-up paths across the sky

/// A made-up path of a light across the sky: it starts at a direction, heading along a bearing, and follows great circles (straight in the
/// sky) at a speed, turning or stopping as its legs say.
struct SkyPath {
    /// A stretch of the path: `duration` seconds at `speed` °/s, its heading turning at `turnRate` °/s (positive to the right, seen from
    /// the observer: from north through east).
    struct Leg {
        var duration: Double
        var speed: Double
        var turnRate: Double = 0
    }

    var start: SkyDirection
    /// The first heading: radians from the start's local north (up the sky) through east.
    var bearing: Double
    var legs: [Leg]

    var duration: Double { legs.reduce(0) { $0 + $1.duration } }

    /// The directions at `rate` pictures a second from time 0 to the end (the end included when it falls on a picture).
    func directions(rate: Double = 5) -> [(time: Double, direction: SkyDirection)] {
        let step = 1 / rate
        let steps = Int((duration * rate + 1e-9).rounded(.down))
        return (0...steps).map { (Double($0) * step, direction(at: Double($0) * step)) }
    }

    /// Where the path is at `time`, integrated in small steps along great circles.
    func direction(at time: Double) -> SkyDirection {
        let radians = Double.pi / 180
        var position = SkyMath.unitVector(start)
        let az = start.azimuth * radians, el = start.elevation * radians
        let east = SIMD3(cos(az), -sin(az), 0.0)
        let north = SIMD3(-sin(el) * sin(az), -sin(el) * cos(az), cos(el))
        var heading = east * sin(bearing) + north * cos(bearing)
        var remaining = max(0, time)
        for leg in legs where remaining > 0 {
            let span = min(remaining, leg.duration)
            remaining -= span
            let pieces = max(1, Int((span / 0.005).rounded(.up))), dt = span / Double(pieces)
            for _ in 0..<pieces {
                let move = leg.speed * dt * radians, turn = leg.turnRate * dt * radians
                // To the right, as the observer sees it (from up the sky towards increasing azimuth): position × heading.
                let right = SkyMath.cross(position, heading)
                heading = heading * cos(turn) + right * sin(turn)
                let next = position * cos(move) + heading * sin(move)
                heading = heading * cos(move) - position * sin(move)
                position = next / SkyMath.length(next)
                heading = heading - position * SkyMath.dot(heading, position)
                heading = heading / SkyMath.length(heading)
            }
        }
        return SkyMath.direction(of: position)
    }
}

// MARK: Made-up flights

extension SkyFixtures {
    /// A made-up dump1090-fa / readsb / tar1090 `aircraft.json`, the shape `AircraftFeedParser` reads from a network feed. Six entries, in
    /// this order: `TEST123` (hex `a0b1c2`, 35,025 feet geometric and 34,950 barometric, 35.8 km from `observer`), `TEST456` (barometric
    /// only), one with no call sign (29.9 s old, still fresh), one on the ground, one 45 s old, and one with no position. Three have a usable
    /// position. The feed's `now` is a made-up time.
    static let aircraftJSON = """
    {"now":1792897200.4,"messages":1234567,"aircraft":[
    {"hex":"a0b1c2","flight":"TEST123 ","alt_baro":34950,"alt_geom":35025,"gs":449.7,"track":90.2,"baro_rate":0,"lat":40.2250,"lon":-100.3000,\
    "nic":8,"rc":186,"seen_pos":0.4,"version":2,"nic_baro":1,"nac_p":9,"nac_v":2,"sil":3,"sil_type":"perhour","gva":2,"sda":2,"mlat":[],\
    "tisb":[],"messages":812,"seen":0.1,"rssi":-17.2},
    {"hex":"b1c2d3","flight":"TEST456 ","alt_baro":12000,"gs":280.5,"track":181.4,"lat":39.65,"lon":-99.60,"seen_pos":1.2,"messages":300,\
    "seen":0.9,"rssi":-22.0},
    {"hex":"c2d3e4","alt_baro":8000,"alt_geom":8250,"gs":150.0,"track":35.0,"lat":40.1,"lon":-100.55,"seen_pos":29.9,"seen":0.5},
    {"hex":"d3e4f5","flight":"TEST789 ","alt_baro":"ground","gs":12.5,"track":270.0,"lat":40.0003,"lon":-100.0002,"seen_pos":1.0},
    {"hex":"e4f5a6","flight":"TEST321 ","alt_baro":20000,"gs":300.0,"track":10.0,"lat":40.3,"lon":-99.9,"seen_pos":45.0},
    {"hex":"f5a6b7","alt_baro":30000,"seen":2.5,"messages":4}
    ]}
    """

    /// A made-up `aircraft.json` in the older shape that dump1090-mutability writes (and a tar1090 that serves it): the barometric altitude is
    /// `altitude` (feet, or "ground") and the speed `speed`, with no `alt_baro`, `alt_geom` or `gs`. The same six entries as `aircraftJSON`,
    /// in the same order, the three usable ones at their barometric heights.
    static let olderAircraftJSON = """
    {"now":1792897200.4,"messages":1234567,"aircraft":[
    {"hex":"a0b1c2","squawk":"1200","flight":"TEST123 ","lat":40.2250,"lon":-100.3000,"nucp":7,"seen_pos":0.4,"altitude":34950,"vert_rate":0,\
    "track":90.2,"speed":449.7,"category":"A3","mlat":[],"tisb":[],"messages":812,"seen":0.1,"rssi":-17.2},
    {"hex":"b1c2d3","flight":"TEST456 ","lat":39.65,"lon":-99.60,"nucp":7,"seen_pos":1.2,"altitude":12000,"vert_rate":-640,"track":181.4,\
    "speed":280.5,"mlat":[],"tisb":[],"messages":300,"seen":0.9,"rssi":-22.0},
    {"hex":"c2d3e4","lat":40.1,"lon":-100.55,"nucp":7,"seen_pos":29.9,"altitude":8000,"track":35.0,"speed":150.0,"mlat":[],"tisb":[],"seen":0.5},
    {"hex":"d3e4f5","flight":"TEST789 ","lat":40.0003,"lon":-100.0002,"nucp":7,"seen_pos":1.0,"altitude":"ground","track":270.0,"speed":12.5},
    {"hex":"e4f5a6","flight":"TEST321 ","lat":40.3,"lon":-99.9,"nucp":7,"seen_pos":45.0,"altitude":20000,"track":10.0,"speed":300.0},
    {"hex":"f5a6b7","altitude":30000,"mlat":[],"tisb":[],"messages":4,"seen":2.5,"rssi":-30.1}
    ]}
    """

    /// A made-up adsb.fi (`opendata.adsb.fi/api/v2`) answer: the aircraft are under `ac`, `now` is in milliseconds. The same `TEST123` as
    /// `aircraftJSON`, at the same altitude, and one on the ground.
    static let adsbFiJSON = """
    {"ac":[
    {"hex":"a0b1c2","type":"adsb_icao","flight":"TEST123 ","r":"N123TS","t":"B738","alt_baro":34950,"alt_geom":35025,"gs":449.7,"track":90.2,\
    "baro_rate":0,"lat":40.2250,"lon":-100.3000,"nic":8,"rc":186,"seen_pos":0.4,"category":"A3","messages":812,"seen":0.1,"rssi":-17.2},
    {"hex":"b9c8d7","type":"adsb_icao","flight":"TEST654 ","alt_baro":"ground","lat":40.0,"lon":-100.0,"seen_pos":2.0}
    ],"msg":"No error","now":1792897200412,"total":2,"ctime":1792897200412,"ptime":0}
    """

    /// A made-up aircraft flying straight and level at a constant ground speed: its position `seconds` after `epoch` is a flat displacement
    /// on the WGS84 radii at its starting latitude. By default it is `aircraftJSON`'s `TEST123`, 25 km north of `observer` and 25 km west,
    /// flying east at 450 knots: `truthDual` sees it in its left lens, going right.
    struct Flight: Sendable {
        var hex = "a0b1c2"
        var callsign: String? = "TEST123"
        /// Where it is at `epoch`.
        var latitude = 40.2250
        var longitude = -100.3000
        var altitudeFeet = 35_025
        var knots = 450.0
        /// Degrees from true north, clockwise.
        var track = 90.0
        var epoch = SkyFixtures.aimEpoch

        var altitudeMeters: Double { Double(altitudeFeet) * 0.3048 }

        func position(after seconds: Double) -> (latitude: Double, longitude: Double) {
            let radians = Double.pi / 180, distance = knots * 1852 / 3600 * seconds
            let phi = latitude * radians, e2 = SkyMath.eccentricitySquared
            let w = (1 - e2 * sin(phi) * sin(phi)).squareRoot()
            let meridian = SkyMath.equatorialRadius * (1 - e2) / (w * w * w), prime = SkyMath.equatorialRadius / w
            let north = distance * cos(track * radians), east = distance * sin(track * radians)
            var longitude = longitude + east / (prime * cos(phi)) / radians
            if longitude > 180 { longitude -= 360 } else if longitude < -180 { longitude += 360 }
            return (latitude + north / meridian / radians, longitude)
        }

        func position(at time: Date) -> (latitude: Double, longitude: Double) {
            position(after: time.timeIntervalSince(epoch))
        }

        /// Where `observer` sees it at `time`.
        func direction(at time: Date, from observer: SkyObserver = SkyFixtures.observer) -> SkyDirection {
            let place = position(at: time)
            return SkyMath.direction(from: observer, toLatitude: place.latitude, longitude: place.longitude, altitudeMeters: altitudeMeters).direction
        }

        /// The report a feed gives of the position message it sent at `time`.
        func report(at time: Date) -> AircraftReport {
            let place = position(at: time)
            return AircraftReport(hex: hex, callsign: callsign, latitude: place.latitude, longitude: place.longitude,
                                  altitudeMeters: altitudeMeters, altitudeFeet: altitudeFeet, positionTime: time, groundSpeedKnots: knots,
                                  trackDegrees: track)
        }

        /// A report every `step` seconds from `start` to `end`.
        func reports(from start: Date, to end: Date, every step: Double = 1) -> [AircraftReport] {
            stride(from: 0.0, through: end.timeIntervalSince(start) + 1e-9, by: step).map { report(at: start.addingTimeInterval($0)) }
        }

        /// Its entry in an `aircraft.json` written when the position message sent at `time` was `age` seconds old.
        func entry(positionAt time: Date, age: Double) -> String {
            let place = position(at: time)
            var fields = ["\"hex\":\"\(hex)\""]
            if let callsign { fields.append("\"flight\":\"\(callsign.padding(toLength: 8, withPad: " ", startingAt: 0))\"") }
            fields += ["\"alt_baro\":\(altitudeFeet - 75)", "\"alt_geom\":\(altitudeFeet)", "\"gs\":\(knots)", "\"track\":\(track)",
                       "\"lat\":\(place.latitude)", "\"lon\":\(place.longitude)", "\"seen_pos\":\(age)"]
            return "{" + fields.joined(separator: ",") + "}"
        }

        /// The same entry as dump1090-mutability writes it (`olderAircraftJSON`'s shape): the height under `altitude`, the speed under `speed`.
        func olderEntry(positionAt time: Date, age: Double) -> String {
            let place = position(at: time)
            var fields = ["\"hex\":\"\(hex)\""]
            if let callsign { fields.append("\"flight\":\"\(callsign.padding(toLength: 8, withPad: " ", startingAt: 0))\"") }
            fields += ["\"lat\":\(place.latitude)", "\"lon\":\(place.longitude)", "\"nucp\":7", "\"seen_pos\":\(age)", "\"altitude\":\(altitudeFeet)",
                       "\"vert_rate\":0", "\"track\":\(track)", "\"speed\":\(knots)", "\"mlat\":[]", "\"tisb\":[]", "\"messages\":120", "\"seen\":\(age)"]
            return "{" + fields.joined(separator: ",") + "}"
        }
    }

    /// Where a point `altitudeMeters` up in `direction` from `observer` is, on a flat Earth at the observer's latitude: a place to seat an
    /// aircraft at, so that a path across the sky can be flown (the Earth's curve moves it by under half a degree at the ranges used here).
    static func place(at direction: SkyDirection, altitudeMeters: Double, from observer: SkyObserver = SkyFixtures.observer)
        -> (latitude: Double, longitude: Double) {
        let radians = Double.pi / 180, unit = SkyMath.unitVector(direction), range = altitudeMeters / unit.z
        let phi = observer.latitude * radians, e2 = SkyMath.eccentricitySquared
        let w = (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        let meridian = SkyMath.equatorialRadius * (1 - e2) / (w * w * w), prime = SkyMath.equatorialRadius / w
        return (observer.latitude + range * unit.y / meridian / radians, observer.longitude + range * unit.x / (prime * cos(phi)) / radians)
    }

    /// The reports, one a second from `start` to `end`, of an aircraft that is `altitudeMeters` up and goes along `path` (which begins at
    /// `pathStart`): it has no ground speed or track.
    static func reports(along path: SkyPath, beginningAt pathStart: Date, altitudeMeters: Double = 10_668, from start: Date, to end: Date,
                        hex: String = "b2c3d4") -> [AircraftReport] {
        stride(from: 0.0, through: end.timeIntervalSince(start) + 1e-9, by: 1).map { step in
            let time = start.addingTimeInterval(step)
            let place = place(at: path.direction(at: time.timeIntervalSince(pathStart)), altitudeMeters: altitudeMeters)
            return AircraftReport(hex: hex, callsign: "TEST456", latitude: place.latitude, longitude: place.longitude, altitudeMeters: altitudeMeters,
                                  altitudeFeet: Int((altitudeMeters / 0.3048).rounded()), positionTime: time, groundSpeedKnots: nil, trackDegrees: nil)
        }
    }

    /// A dump1090-fa style `aircraft.json` of `entries` (each one aircraft's JSON object) written by a host whose clock says `now`.
    static func feedJSON(_ entries: [String], now: Double) -> String {
        "{\"now\":\(now),\"messages\":1,\"aircraft\":[" + entries.joined(separator: ",") + "]}"
    }

    /// One picture of a light at `direction`, seen by `truth`: nil where `truth` has no pixel for it.
    static func sample(at time: Date, since start: Date, direction: SkyDirection, through truth: SkyCameraModel) -> SkyTrackSample? {
        guard let hit = truth.project(direction).first else { return nil }
        return SkyTrackSample(time: time.timeIntervalSince(start), wallClock: time, point: hit.point, area: 9, flux: 120, sharpness: 0.6,
                              elongation: 1, lens: hit.lens, inSeamBand: truth.isInSeamBand(hit.point), significance: 4)
    }

    /// A track of `flight` as `truth` sees it: `seconds` from `start`, `rate` pictures a second, each direction off by up to `noise` degrees.
    /// Nil where `truth` does not see the flight all the way.
    static func track(of flight: Flight, through truth: SkyCameraModel, from start: Date, seconds: Double, rate: Double = 5, noise: Double = 0.1,
                      seenFrom observer: SkyObserver = SkyFixtures.observer, using random: inout SkyRandom) -> SkyTrack? {
        var samples: [SkyTrackSample] = []
        for index in 0...Int((seconds * rate).rounded(.down)) {
            let time = start.addingTimeInterval(Double(index) / rate)
            guard let sample = sample(at: time, since: start,
                                      direction: noisy(flight.direction(at: time, from: observer), upTo: noise, using: &random),
                                      through: truth) else { return nil }
            samples.append(sample)
        }
        return SkyTrack(id: UUID(), samples: samples, streakBorn: false)
    }

    /// What the detector measures of `track` through `model` (an analysis 1920 wide of a 4256-wide picture).
    static func measures(of track: SkyTrack, model: SkyCameraModel) -> SkyMeasures {
        TrackMeasurer.measure(track, model: model, analysisWidth: 1920, pictureWidth: 4256)
    }

    /// `model` turned `degrees` about the vertical, as an aim that is off by that much in azimuth.
    static func turned(_ model: SkyCameraModel, by degrees: Double) -> SkyCameraModel {
        var turned = model
        for index in turned.lenses.indices { turned.lenses[index].yaw += degrees }
        return turned
    }
}
