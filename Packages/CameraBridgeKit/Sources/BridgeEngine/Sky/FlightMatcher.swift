import Foundation

/// What a light that crossed the sky is called in the sky log. A plane is `probablePlane` until the camera's aim is good.
public enum SkyLabel: String, Codable, Sendable, CaseIterable {
    case unexplained, plane, probablePlane, satellite, satelliteFlare, meteor, bug, bird
}

/// A track that an aircraft explains: which one, how it reads in the log, how well it fits (the median angular distance, in degrees: lower is
/// better), what to call the track, and the matches the camera's aim can be fitted to (`SkyAimStore.add`, all of them in one call).
struct FlightMatch: Sendable, Equatable {
    var hex: String
    /// "TEST123 · 35,000 ft".
    var detail: String
    var score: Double
    var label: SkyLabel
    /// One per matched picture, in time order: the track's pixel in the camera's original picture and the aircraft's direction then. The
    /// object is the aircraft's hex.
    var correspondences: [AimCorrespondence]
}

/// Decides whether an aircraft of a flight feed is the light a track followed, by where each would be seen through the camera model.
///
/// **Pinned (the brief's):**
/// - Where an aircraft was at a picture's time (`wallClock`) is interpolated linearly in its history, and up to 5 s beyond the history it is
///   extrapolated from its ground speed and track.
/// - Its score is the median angular distance between the track's directions (each sample's pixel through `model`, by the lens it was seen
///   in) and the aircraft's. It matches when the score is within the aim's tolerance (`AimFitter.matchTolerance`: 15°, 1.5° or 0.75°) and,
///   for a track of 1 s or more, the heading of its motion agrees with the track's within 30°.
/// - While the aim is rough it must also be the only aircraft within 15°, and its angular speed within 50 % of the track's.
/// - The label is `.probablePlane` while the aim is rough, else `.plane`. Each matched picture gives one correspondence.
///
/// **The builder's choices:**
/// - A picture an aircraft cannot be placed at (its history does not reach, or its direction through the model does not exist) counts as
///   infinitely far, so the median needs more than half of the pictures placed and near: an aircraft seen for a fifth of a track does not
///   explain it. A track of more than `maximumSamples` pictures is judged on that many, evenly spread (the first and last included).
/// - Interpolation does not bridge a gap in an aircraft's reports longer than `maximumGap` (20 s): an aircraft lost for longer could have
///   gone anywhere, and its straight line between the two ends would be a match by chance. In a gap each end places it up to 5 s.
/// - The heading is the direction of motion in the track's own tangent plane: the least-squares slope over the pictures of the track's
///   directions against the aircraft's, both taken at the pictures' times, so a track that lags or leads its aircraft by a few degrees still
///   has the aircraft's heading. The speed is the aircraft's path across the sky over the time it was followed, against `SkyMeasures.speed`.
/// - A track whose two halves were joined across the dual camera's seam by the picture alone (`uncertainSeamJoin`: possibly two lights) must
///   be explained in each lens on its own, else it is no match: the median of each lens's pictures must be within the tolerance too.
/// - Of several aircraft within the tolerance the better score wins (the lower hex of two equal ones), unless the aim is rough, which wants
///   the one.
/// - Pictures in the seam's low-trust band count for the score but give no correspondence: the fit ignores them.
enum FlightMatcher {
    // MARK: Pinned values

    static let maximumExtrapolation: TimeInterval = 5
    static let headingTolerance = 30.0
    static let headingFromDuration: TimeInterval = 1
    static let roughSpeedShare = 0.5

    // MARK: Builder's values

    static let maximumGap: TimeInterval = 20
    static let maximumSamples = 100
    /// An aircraft nearer than this is not a direction.
    static let minimumRange = 100.0
    /// A knot is exactly 1,852 m an hour.
    static let metresPerSecondPerKnot = 1_852.0 / 3_600

    /// The aircraft among `flights` (each one's reports, by hex) that explains `track`, or nil. `measures` are the track's, measured through
    /// `model`; `aim` the quality of the aim `model` is; `observer` where the box is.
    static func match(_ track: SkyTrack, measures: SkyMeasures, model: SkyCameraModel, aim: SkyAimQuality, observer: SkyObserver,
                      flights: [String: [AircraftReport]]) -> FlightMatch? {
        guard !flights.isEmpty, let sights = Sights(track, model: model) else { return nil }
        let tolerance = AimFitter.matchTolerance(aim)
        var near: [Candidate] = []
        for hex in flights.keys.sorted() {
            if let candidate = candidate(hex, reports: flights[hex] ?? [], sights: sights, tolerance: tolerance, observer: observer) {
                near.append(candidate)
            }
        }
        // A rough aim is too loose to choose between aircraft: it takes only the one that is alone.
        if aim == .rough && near.count != 1 { return nil }
        let explained = near.filter { agrees($0, with: track, measures: measures, sights: sights, aim: aim, tolerance: tolerance) }
        guard let best = explained.min(by: { ($0.score, $0.hex) < ($1.score, $1.hex) }) else { return nil }

        let correspondences = sights.samples.indices.compactMap { index -> AimCorrespondence? in
            let sample = sights.samples[index]
            guard best.distances[index] <= tolerance, !sample.inSeamBand, let direction = best.directions[index] else { return nil }
            return AimCorrespondence(point: sample.point, direction: direction, source: .plane, at: sample.wallClock, object: best.hex)
        }
        let middle = sights.samples[0].wallClock.addingTimeInterval(sights.seconds[sights.seconds.count - 1] / 2)
        let report = best.history.min { abs($0.positionTime.timeIntervalSince(middle)) < abs($1.positionTime.timeIntervalSince(middle)) }
        return FlightMatch(hex: best.hex, detail: report.map(detail) ?? best.hex.uppercased(), score: best.score,
                           label: aim == .rough ? .probablePlane : .plane, correspondences: correspondences)
    }

    /// "TEST123 · 35,000 ft": the call sign (trimmed), else the hex in capitals, and the height in feet to the nearest hundred, with a comma.
    static func detail(_ report: AircraftReport) -> String {
        let name = report.callsign?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let feet = (Double(min(max(report.altitudeFeet, -1_000_000), 1_000_000)) / 100).rounded() * 100
        return "\(name.isEmpty ? report.hex.uppercased() : name) · \(grouped(Int(feet))) ft"
    }

    private static func grouped(_ value: Int) -> String {
        var text = ""
        for (index, digit) in String(abs(value)).reversed().enumerated() {
            if index > 0 && index % 3 == 0 { text.append(",") }
            text.append(digit)
        }
        return (value < 0 ? "-" : "") + String(text.reversed())
    }

    // MARK: The track

    /// The track's pictures that are judged (in time order, at most `maximumSamples`) and the direction each is seen in.
    private struct Sights {
        var samples: [SkyTrackSample]
        /// The unit vector of the direction through the sample's own lens (east, north, up); nil where there is none.
        var units: [SIMD3<Double>?]
        /// Seconds from the first picture.
        var seconds: [Double]

        init?(_ track: SkyTrack, model: SkyCameraModel) {
            var all = track.samples.filter { $0.wallClock.timeIntervalSince1970.isFinite }
            guard all.count >= 2 else { return nil }
            if !zip(all, all.dropFirst()).allSatisfy({ $0.wallClock <= $1.wallClock }) {
                // Not in time order: sorted, and of two at one time the earlier in the track first.
                all = all.enumerated().sorted { ($0.element.wallClock, $0.offset) < ($1.element.wallClock, $1.offset) }.map(\.element)
            }
            if all.count > FlightMatcher.maximumSamples {
                let last = Double(all.count - 1), steps = Double(FlightMatcher.maximumSamples - 1)
                all = (0..<FlightMatcher.maximumSamples).map { all[Int((Double($0) * last / steps).rounded())] }
            }
            samples = all
            units = all.map { sample in
                guard sample.point.x.isFinite, sample.point.y.isFinite,
                      let direction = model.direction(at: sample.point, lens: sample.lens),
                      direction.azimuth.isFinite, direction.elevation.isFinite else { return nil }
                return SkyMath.unitVector(direction)
            }
            let start = all[0].wallClock
            seconds = all.map { $0.wallClock.timeIntervalSince(start) }
            guard units.filter({ $0 != nil }).count >= 2 else { return nil }
        }
    }

    // MARK: An aircraft

    /// An aircraft that is within the tolerance of the track: where it is at each picture and how far that is from the track's.
    private struct Candidate {
        var hex: String
        var history: [AircraftReport]
        var score: Double
        /// Per picture: the distance (degrees; infinity where the aircraft could not be placed), the direction and its unit vector.
        var distances: [Double]
        var directions: [SkyDirection?]
        var units: [SIMD3<Double>?]
    }

    private static func candidate(_ hex: String, reports: [AircraftReport], sights: Sights, tolerance: Double, observer: SkyObserver) -> Candidate? {
        let history = reports.filter(isUsable).sorted { $0.positionTime < $1.positionTime }
        guard let first = history.first, let last = history.last else { return nil }
        // Quick out: an aircraft that can be placed for less than half of the track's time cannot explain it.
        let from = first.positionTime.addingTimeInterval(-maximumExtrapolation), to = last.positionTime.addingTimeInterval(maximumExtrapolation)
        guard sights.samples.filter({ $0.wallClock >= from && $0.wallClock <= to }).count * 2 >= sights.samples.count else { return nil }

        var distances: [Double] = [], directions: [SkyDirection?] = [], units: [SIMD3<Double>?] = []
        var tooFar = 0
        for index in sights.samples.indices {
            var distance = Double.infinity
            var direction: SkyDirection?, unit: SIMD3<Double>?
            if let seen = sights.units[index], let place = place(in: history, at: sights.samples[index].wallClock) {
                let there = SkyMath.direction(from: observer, toLatitude: place.latitude, longitude: place.longitude,
                                              altitudeMeters: place.altitudeMeters)
                if there.rangeMeters >= minimumRange, there.direction.azimuth.isFinite, there.direction.elevation.isFinite {
                    let flown = SkyMath.unitVector(there.direction)
                    direction = there.direction
                    unit = flown
                    distance = angle(seen, flown)
                }
            }
            distances.append(distance)
            directions.append(direction)
            units.append(unit)
            // More than half of the pictures out of the tolerance: the median cannot come within it.
            if !(distance <= tolerance) {
                tooFar += 1
                if tooFar * 2 > sights.samples.count { return nil }
            }
        }
        let score = median(distances)
        guard score <= tolerance else { return nil }
        return Candidate(hex: hex, history: history, score: score, distances: distances, directions: directions, units: units)
    }

    /// Whether the aircraft's heading, and for a rough aim its speed, and for a seam join made by the picture its explanation of each lens,
    /// agree with the track's.
    private static func agrees(_ candidate: Candidate, with track: SkyTrack, measures: SkyMeasures, sights: Sights, aim: SkyAimQuality,
                               tolerance: Double) -> Bool {
        if measures.duration >= headingFromDuration && !headingAgrees(candidate, sights: sights) { return false }
        if aim == .rough {
            let wanted = measures.speed
            guard wanted.isFinite, wanted > 0, let speed = pathSpeed(candidate.units, seconds: sights.seconds),
                  abs(speed - wanted) <= roughSpeedShare * wanted else { return false }
        }
        if track.uncertainSeamJoin {
            for lens in Set(sights.samples.map(\.lens)) {
                let own = sights.samples.indices.filter { sights.samples[$0].lens == lens }.map { candidate.distances[$0] }
                if !(median(own) <= tolerance) { return false }
            }
        }
        return true
    }

    /// Whether the track and the aircraft move the same way across the sky: the angle between the slopes, over the pictures' times, of the
    /// two paths' directions, flattened onto the sky at the track's middle, is within `headingTolerance`.
    private static func headingAgrees(_ candidate: Candidate, sights: Sights) -> Bool {
        let both = sights.samples.indices.filter { sights.units[$0] != nil && candidate.units[$0] != nil }
        guard both.count >= 2 else { return false }
        let mean = both.reduce(0) { $0 + sights.seconds[$1] } / Double(both.count)
        let spread = both.reduce(0) { $0 + (sights.seconds[$1] - mean) * (sights.seconds[$1] - mean) }
        guard spread > 1e-9 else { return false }
        var trackSlope = SIMD3<Double>(), planeSlope = SIMD3<Double>(), centre = SIMD3<Double>()
        for index in both {
            let weight = sights.seconds[index] - mean
            if let seen = sights.units[index], let flown = candidate.units[index] {
                trackSlope += weight * seen
                planeSlope += weight * flown
                centre += seen
            }
        }
        let size = SkyMath.length(centre)
        guard size > 0 else { return false }
        let up = centre / size
        let track = trackSlope - SkyMath.dot(trackSlope, up) * up, plane = planeSlope - SkyMath.dot(planeSlope, up) * up
        let trackSize = SkyMath.length(track), planeSize = SkyMath.length(plane)
        guard trackSize > 1e-9 * spread, planeSize > 1e-9 * spread else { return false }
        return SkyMath.dot(track, plane) / (trackSize * planeSize) >= cos(headingTolerance * SkyMath.radians)
    }

    /// The length of the path through `units` (degrees) over the time from the first picture it has to the last (°/s); nil with fewer than two.
    private static func pathSpeed(_ units: [SIMD3<Double>?], seconds: [Double]) -> Double? {
        var length = 0.0, previous: SIMD3<Double>?
        var first: Double?, last = 0.0
        for index in units.indices {
            guard let unit = units[index] else { continue }
            if let previous { length += angle(previous, unit) }
            if first == nil { first = seconds[index] }
            last = seconds[index]
            previous = unit
        }
        guard let first, last > first else { return nil }
        return length / (last - first)
    }

    // MARK: Where an aircraft was

    /// Where an aircraft was at a moment (`place(in:at:)`); the wide aim search keeps these for the tracks it may judge again (`SkyAimSearch`).
    struct Place {
        var latitude: Double
        var longitude: Double
        var altitudeMeters: Double

        init(latitude: Double, longitude: Double, altitudeMeters: Double) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitudeMeters = altitudeMeters
        }

        init(_ report: AircraftReport) {
            self.init(latitude: report.latitude, longitude: report.longitude, altitudeMeters: report.altitudeMeters)
        }
    }

    static func isUsable(_ report: AircraftReport) -> Bool {
        report.latitude.isFinite && (-90.0...90.0).contains(report.latitude) && report.longitude.isFinite
            && (-180.0...180.0).contains(report.longitude) && report.altitudeMeters.isFinite
            && report.positionTime.timeIntervalSince1970.isFinite
    }

    /// Where the aircraft was at `time`, from its reports in time order (`history` is not empty): between two reports less than
    /// `maximumGap` apart, on the straight line between them; otherwise up to `maximumExtrapolation` from the nearer report, along its
    /// ground speed and track; else nil. A longitude may come out a little past ±180° (it is only ever sine and cosine'd).
    static func place(in history: [AircraftReport], at time: Date) -> Place? {
        var low = 0, high = history.count
        while low < high {
            let middle = (low + high) / 2
            if history[middle].positionTime < time { low = middle + 1 } else { high = middle }
        }
        if low < history.count, history[low].positionTime == time { return Place(history[low]) }
        if low == 0 { return extrapolated(history[0], by: time.timeIntervalSince(history[0].positionTime)) }
        if low == history.count { return extrapolated(history[low - 1], by: time.timeIntervalSince(history[low - 1].positionTime)) }
        let before = history[low - 1], after = history[low]
        let gap = after.positionTime.timeIntervalSince(before.positionTime)
        if gap <= maximumGap {
            let share = time.timeIntervalSince(before.positionTime) / gap
            var longitudeStep = after.longitude - before.longitude
            if longitudeStep > 180 { longitudeStep -= 360 } else if longitudeStep < -180 { longitudeStep += 360 }
            return Place(latitude: before.latitude + share * (after.latitude - before.latitude),
                         longitude: before.longitude + share * longitudeStep,
                         altitudeMeters: before.altitudeMeters + share * (after.altitudeMeters - before.altitudeMeters))
        }
        let since = time.timeIntervalSince(before.positionTime), until = after.positionTime.timeIntervalSince(time)
        return since <= until ? extrapolated(before, by: since) : extrapolated(after, by: -until)
    }

    /// Where `report`'s aircraft is `seconds` after (or, negative, before) it, flying on at its ground speed along its track, at its height.
    private static func extrapolated(_ report: AircraftReport, by seconds: TimeInterval) -> Place? {
        guard abs(seconds) <= maximumExtrapolation, let knots = report.groundSpeedKnots, let heading = report.trackDegrees,
              knots.isFinite, heading.isFinite, knots >= 0, knots <= AircraftFeedParser.maximumSpeedKnots else { return nil }
        let phi = report.latitude * SkyMath.radians, e2 = SkyMath.eccentricitySquared
        let w = (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        let meridian = SkyMath.equatorialRadius * (1 - e2) / (w * w * w), prime = SkyMath.equatorialRadius / w
        guard abs(cos(phi)) > 1e-6 else { return nil }
        let distance = knots * metresPerSecondPerKnot * seconds
        let north = distance * cos(heading * SkyMath.radians), east = distance * sin(heading * SkyMath.radians)
        return Place(latitude: report.latitude + north / meridian * SkyMath.degrees,
                     longitude: report.longitude + east / (prime * cos(phi)) * SkyMath.degrees,
                     altitudeMeters: report.altitudeMeters)
    }

    // MARK: Numbers

    /// The angle between two unit vectors (degrees), accurate for tiny and near-opposite ones alike.
    private static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        atan2(SkyMath.length(SkyMath.cross(a, b)), SkyMath.dot(a, b)) * SkyMath.degrees
    }

    /// The median (the mean of the middle two of an even count); infinity for none, and for any middle that is infinite.
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .infinity }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
