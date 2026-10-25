import Foundation

/// A direction in the sky as the observer sees it, in degrees: the azimuth from true north, clockwise (0 ≤ azimuth < 360), and the elevation
/// above the horizon (−90…90). Geometric: no refraction.
public struct SkyDirection: Codable, Sendable, Equatable {
    public var azimuth: Double
    public var elevation: Double

    public init(azimuth: Double, elevation: Double) {
        self.azimuth = azimuth
        self.elevation = elevation
    }
}

/// Where the sky is seen from: the box's location, WGS84 in degrees (longitude east of Greenwich, so 100° W is −100) and the height above
/// the ellipsoid in metres. It is kept only on the box and never logged: printed, interpolated, dumped or shown in an error, it says only
/// that it is hidden.
struct SkyObserver: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    var heightMeters: Double
}

extension SkyObserver: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "SkyObserver(location hidden)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Sky geometry, in degrees: separations, time scales, equatorial to horizontal coordinates, and WGS84 positions to directions. Directions
/// are worked in the observer's east-north-up frame (`unitVector(_:)`, `direction(of:)`). Portable: Foundation's math and `SIMD3` only.
enum SkyMath {
    static let degrees = 180 / Double.pi
    static let radians = Double.pi / 180

    /// WGS84: the equatorial radius (metres) and the flattening.
    static let equatorialRadius = 6_378_137.0
    static let flattening = 1 / 298.257_223_563
    static let eccentricitySquared = flattening * (2 - flattening)

    /// The J2000.0 epoch (2000 January 1, 12:00, Julian date 2451545.0), in seconds since 1970.
    static let j2000 = 946_728_000.0

    /// The angle between two directions (degrees, 0…180), accurate for tiny and near-opposite angles alike.
    static func separation(_ a: SkyDirection, _ b: SkyDirection) -> Double {
        let u = unitVector(a), v = unitVector(b)
        return atan2(length(cross(u, v)), dot(u, v)) * degrees
    }

    /// The Julian date of `date` (days since 4713 BC January 1, 12:00), counting UTC as uniform time: the dates here need no leap seconds,
    /// and the Sun moves only 0.001° in the minute or so between UTC and dynamical time.
    static func julianDate(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    /// Days since J2000.0, worked from the date itself (more digits than `julianDate(_:) − 2451545`).
    static func daysSinceJ2000(_ date: Date) -> Double {
        (date.timeIntervalSince1970 - j2000) / 86_400
    }

    /// The mean sidereal time at Greenwich (degrees, 0…360): Meeus, "Astronomical Algorithms", equation 12.4.
    static func greenwichSiderealDegrees(_ date: Date) -> Double {
        let days = daysSinceJ2000(date)
        let centuries = days / 36_525
        return normalizedDegrees(280.460_618_37 + 360.985_647_366_29 * days + centuries * centuries * (0.000_387_933 - centuries / 38_710_000))
    }

    /// The direction of a body at right ascension and declination `rightAscension`, `declination` (degrees, of the date) from `observer` at
    /// `date`: geometric (no refraction, no parallax).
    static func horizontal(rightAscension: Double, declination: Double, at date: Date, observer: SkyObserver) -> SkyDirection {
        let hourAngle = (greenwichSiderealDegrees(date) + observer.longitude - rightAscension) * radians
        let delta = declination * radians, phi = observer.latitude * radians
        let east = -cos(delta) * sin(hourAngle)
        let north = sin(delta) * cos(phi) - cos(delta) * cos(hourAngle) * sin(phi)
        let up = sin(delta) * sin(phi) + cos(delta) * cos(hourAngle) * cos(phi)
        return direction(of: SIMD3(east, north, up))
    }

    /// The direction and distance from `observer` to a point at `latitude`, `longitude` and `altitudeMeters` (WGS84, the altitude above the
    /// ellipsoid), through the Earth-centred frame into the observer's east-north-up frame, so the Earth's curve is included.
    static func direction(from observer: SkyObserver, toLatitude latitude: Double, longitude: Double,
                          altitudeMeters: Double) -> (direction: SkyDirection, rangeMeters: Double) {
        let offset = ecef(latitude: latitude, longitude: longitude, altitudeMeters: altitudeMeters)
            - ecef(latitude: observer.latitude, longitude: observer.longitude, altitudeMeters: observer.heightMeters)
        let phi = observer.latitude * radians, lambda = observer.longitude * radians
        let east = -sin(lambda) * offset.x + cos(lambda) * offset.y
        let north = -sin(phi) * cos(lambda) * offset.x - sin(phi) * sin(lambda) * offset.y + cos(phi) * offset.z
        let up = cos(phi) * cos(lambda) * offset.x + cos(phi) * sin(lambda) * offset.y + sin(phi) * offset.z
        let local = SIMD3(east, north, up)
        return (direction(of: local), length(local))
    }

    /// The Earth-centred, Earth-fixed position (metres) of a WGS84 point: x towards 0° E on the equator, z towards the North Pole.
    static func ecef(latitude: Double, longitude: Double, altitudeMeters: Double) -> SIMD3<Double> {
        let phi = latitude * radians, lambda = longitude * radians
        let primeVertical = equatorialRadius / (1 - eccentricitySquared * sin(phi) * sin(phi)).squareRoot()
        return SIMD3((primeVertical + altitudeMeters) * cos(phi) * cos(lambda),
                     (primeVertical + altitudeMeters) * cos(phi) * sin(lambda),
                     (primeVertical * (1 - eccentricitySquared) + altitudeMeters) * sin(phi))
    }

    // MARK: The east-north-up frame

    /// The unit vector of a direction: x east, y north, z up.
    static func unitVector(_ direction: SkyDirection) -> SIMD3<Double> {
        let azimuth = direction.azimuth * radians, elevation = direction.elevation * radians
        return SIMD3(cos(elevation) * sin(azimuth), cos(elevation) * cos(azimuth), sin(elevation))
    }

    /// The direction of an east-north-up vector of any length (straight up or down has azimuth 0; so has the zero vector, at elevation 0).
    static func direction(of vector: SIMD3<Double>) -> SkyDirection {
        SkyDirection(azimuth: normalizedDegrees(atan2(vector.x, vector.y) * degrees),
                     elevation: atan2(vector.z, (vector.x * vector.x + vector.y * vector.y).squareRoot()) * degrees)
    }

    /// `angle` in 0…360 (degrees); not a number stays one.
    static func normalizedDegrees(_ angle: Double) -> Double {
        let remainder = angle.truncatingRemainder(dividingBy: 360)
        let positive = remainder < 0 ? remainder + 360 : remainder
        return positive == 360 ? 0 : positive
    }

    static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        (a * b).sum()
    }

    static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    static func length(_ a: SIMD3<Double>) -> Double {
        dot(a, a).squareRoot()
    }
}
