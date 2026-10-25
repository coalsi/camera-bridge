import Foundation

/// The shape of a track's path across the sky, as the log shows it.
public enum SkyPathShape: String, Codable, Sendable {
    case straight, curved, suddenStop, sharpTurn
}

/// What a track's path says about the light, on the sky (degrees, through the camera model), never in real units: one camera cannot tell
/// how far away a light is, so nothing here is a real size, distance or speed.
public struct SkyMeasures: Codable, Sendable, Equatable {
    /// Where it was first and last seen (degrees: azimuth from true north, clockwise; elevation).
    public var azimuth: Double
    public var elevation: Double
    public var azimuthEnd: Double
    public var elevationEnd: Double
    /// How long it was followed (s).
    public var duration: Double
    /// Its path across the sky over the duration (°/s), and how that changed (°/s², the slope of its speed over time).
    public var speed: Double
    public var acceleration: Double
    /// Its turning: all its heading changes per degree travelled (°/°), and the largest within any second (°).
    public var turnRate: Double
    public var maxTurn: Double
    /// From its first point to its last, over the path (1: straight across the sky).
    public var straightness: Double
    public var shape: SkyPathShape
    /// How large it looks (degrees across), how bright (its median flux, in luma levels × pixels of the camera's original picture) and how
    /// sharp (its median sharpness: 1 a point; a blurred blob is close to the lens).
    public var sizeDegrees: Double
    public var brightness: Double
    /// It dimmed at least three times (dips below 30 % of its median flux, or pictures it was missing from), and how often (Hz; nil when it
    /// does not blink). Five pictures a second show at most 2.5 Hz.
    public var blinks: Bool
    public var blinkRate: Double?
    public var focus: Double
}

/// Measures tracks on the sky: each sample's direction comes through the camera model, by its own lens (or, when a sample outside the
/// seam band says otherwise than the model's split, by the split for all of them).
///
/// **Pinned:**
/// - `speed` is the path length over the duration; `acceleration` the least-squares slope of speed over time;
/// - `turnRate` is the total absolute heading change per degree travelled; `maxTurn` the largest heading change within any 1 s;
/// - `straightness` is the chord over the path length;
/// - `shape`: `sharpTurn` when it turns 60° or more within 1 s at 0.2°/s or more; else `suddenStop` when its speed falls from 0.5°/s or more
///   to 10 % or less within 0.6 s and it then stays for 1 s or more; else `straight` when maxTurn < 15° and straightness ≥ 0.97; else
///   `curved`;
/// - `sizeDegrees` is 2√(area / π) × the local degrees per pixel (the median over its samples); `brightness` the median flux and `focus`
///   the median sharpness;
/// - `blinks` at 3 dips or more below 30 % of the median flux, `blinkRate` dips per second;
/// - stationary: under 0.05°/s over 2 s or more.
///
/// **The builder's choices** (a centroid wanders by a fraction of a pixel, which a slow light's steps of a fraction of a degree would
/// otherwise turn into a crooked, fast path):
/// - the path is measured between points at least 4 analysed pixels apart (a straight track's path is then within 0.2 % of its chord);
/// - a heading is the great circle from a point to the next, so a straight path across the sky never turns; within a second, the turn
///   at each sample is between the chords to where the light was a second before and is a second after (their middles a second apart, so
///   a steady 45°/s arc turns 45°, and an abrupt turn shows whole; shorter for a track under 2 s), both at least 4 pixels long (a stopped
///   light has no heading); the turn rate adds the turns between chords of at least 20 pixels;
/// - the speed before a stop is over the second before it (at least 0.4 s of it); staying is keeping, for a second, to 10 % of that speed,
///   by the least-squares speed of the positions over that second (where it stays, a slow light's tenth of a second's travel is a fraction
///   of a pixel, less than a centroid wanders);
/// - a dip is a run of low pictures, so one long dimming is one dip; the rate is the dips' frequency, from the first dip to the last;
/// - the brightness is in the original picture's pixels (the flux of the analysed picture × (pictureWidth / analysisWidth)²), so it does
///   not change with the stream analysed.
enum TrackMeasurer {
    // MARK: Pinned values

    static let sharpTurnDegrees = 60.0
    static let sharpTurnWithin: TimeInterval = 1
    static let sharpTurnSpeed = 0.2
    static let stopFromSpeed = 0.5
    static let stopShare = 0.1
    static let stopWithin: TimeInterval = 0.6
    static let stopStays: TimeInterval = 1
    static let straightTurn = 15.0
    static let straightLine = 0.97
    static let dipShare = 0.3
    static let blinkDips = 3
    static let stationarySpeed = 0.05
    static let stationaryFor: TimeInterval = 2

    // MARK: Builder's values

    /// A step of the path, or a chord a heading is measured on, is at least this many analysed pixels.
    static let noisePixels = 4.0
    /// The turn rate's chords: at least this many analysed pixels.
    static let headingPixels = 20.0
    /// The speed before a stop is over this long before it (at least `stopLookBackAtLeast`).
    static let stopLookBack: TimeInterval = 1
    static let stopLookBackAtLeast: TimeInterval = 0.4
    /// A stay's speed is fitted to at least this many of its points.
    static let stayPoints = 3
    /// The size is the median over at most this many samples, spread along the track.
    static let sizeSamples = 64

    /// A light that did not move: under 0.05°/s over 2 s or more (a star, a planet, a lamp). The tracker keeps only a track with a sample at
    /// least 4 pixels (`SkyTracker.minimumMovePixels`) from its first; a star followed for minutes drifts further, and is stationary here.
    static func isStationary(_ m: SkyMeasures) -> Bool {
        m.duration >= stationaryFor && m.speed < stationarySpeed
    }

    /// The measures of `track`, its samples' points in the original picture seen through `model`, its areas and fluxes in pixels of the
    /// analysed picture (`analysisWidth` wide, of the original's `pictureWidth`).
    static func measure(_ track: SkyTrack, model: SkyCameraModel, analysisWidth: Int, pictureWidth: Int) -> SkyMeasures {
        let samples = track.samples.filter { $0.time.isFinite }.sorted { $0.time < $1.time }
        let analysed = Double(max(1, analysisWidth))
        let scale = Double(max(1, pictureWidth)) / analysed
        let brightness = median(samples.map(\.flux).filter(\.isFinite)) * scale * scale
        let focus = median(samples.map(\.sharpness).filter(\.isFinite))
        let blinking = blinks(samples, misses: track.misses)

        // The samples the model places in the sky, each through the lens it was seen in: the samples' own, unless one outside the seam band
        // disagrees with the model's split (the picture was analysed without the model, which knows only one lens), and then the split's.
        let trusted = !samples.contains { $0.point.x.isFinite && model.lens(at: $0.point) != $0.lens && !model.isInSeamBand($0.point) }
        let points: [Point] = samples.compactMap { sample in
            guard sample.point.x.isFinite, sample.point.y.isFinite,
                  let direction = model.direction(at: sample.point, lens: trusted ? sample.lens : model.lens(at: sample.point)),
                  direction.azimuth.isFinite, direction.elevation.isFinite else { return nil }
            return Point(time: sample.time, unit: SkyMath.unitVector(direction), sample: sample)
        }
        guard let first = points.first, let last = points.last else {
            return SkyMeasures(azimuth: 0, elevation: 0, azimuthEnd: 0, elevationEnd: 0, duration: 0, speed: 0, acceleration: 0, turnRate: 0,
                               maxTurn: 0, straightness: 1, shape: .straight, sizeDegrees: 0, brightness: finite(brightness), blinks: blinking.blinks,
                               blinkRate: blinking.rate, focus: finite(focus))
        }
        let duration = last.time - first.time
        let middle = points[points.count / 2]
        var pixel = model.degreesPerPixel(at: middle.sample.point, pictureWidth: max(1, analysisWidth))
        if !(pixel.isFinite && pixel > 0) { pixel = 0 }
        let noise = noisePixels * pixel

        // The path, between points at least 4 pixels apart.
        var nodes = [0]
        for index in 1..<points.count where angle(points[nodes[nodes.count - 1]].unit, points[index].unit) >= noise { nodes.append(index) }
        if nodes.last != points.count - 1 { nodes.append(points.count - 1) }
        var path = 0.0
        var speeds: [(time: Double, speed: Double, weight: Double)] = []
        for k in 1..<max(1, nodes.count) {
            let a = points[nodes[k - 1]], b = points[nodes[k]]
            let step = angle(a.unit, b.unit)
            path += step
            let span = b.time - a.time
            if span > 0 { speeds.append(((a.time + b.time) / 2, step / span, span)) }
        }
        let speed = duration > 0 ? path / duration : 0
        let chord = angle(first.unit, last.unit)
        let straightness = path > 0 ? min(1, chord / path) : 1

        // The turn rate: the turns between chords of at least 20 pixels.
        var headings = [0]
        for index in 1..<points.count where angle(points[headings[headings.count - 1]].unit, points[index].unit) >= headingPixels * pixel {
            headings.append(index)
        }
        // Each turn is between the chords on either side of a node, so the turns cover the path from the first chord's middle to the
        // last one's: that is what they are per degree of.
        var turning = 0.0, covered = 0.0
        if headings.count >= 3 {
            let chords = (1..<headings.count).map { angle(points[headings[$0 - 1]].unit, points[headings[$0]].unit) }
            covered = chords.reduce(0, +) - (chords[0] + chords[chords.count - 1]) / 2
            for k in 1..<(headings.count - 1) {
                turning += turn(points[headings[k - 1]].unit, points[headings[k]].unit, points[headings[k + 1]].unit) ?? 0
            }
        }
        let turnRate = covered > 0 ? turning / covered : 0

        // The largest turn within a second: between the chords from a second before each sample and to a second after it (their middles a
        // second apart), and whether it was a sharp one.
        var maxTurn = 0.0, sharp = false
        let half = min(sharpTurnWithin, duration / 2)
        if half > 0 {
            for point in points where point.time - first.time >= half - 1e-9 && last.time - point.time >= half - 1e-9 {
                guard let before = position(points, at: point.time - half), let after = position(points, at: point.time + half) else { continue }
                let into = angle(before, point.unit), out = angle(point.unit, after)
                guard into >= noise, out >= noise, into > 0, out > 0, let angle = turn(before, point.unit, after) else { continue }
                maxTurn = max(maxTurn, angle)
                if angle >= sharpTurnDegrees && into / half >= sharpTurnSpeed && out / half >= sharpTurnSpeed { sharp = true }
            }
        }

        let shape: SkyPathShape
        if sharp {
            shape = .sharpTurn
        } else if stops(points) {
            shape = .suddenStop
        } else if maxTurn < straightTurn && straightness >= straightLine {
            shape = .straight
        } else {
            shape = .curved
        }

        // The size: the median of 2√(area / π) × the degrees per pixel where each was seen.
        let stride = max(1, points.count / sizeSamples)
        let sizes = Swift.stride(from: 0, to: points.count, by: stride).map { index -> Double in
            let sample = points[index].sample
            let local = model.degreesPerPixel(at: sample.point, pictureWidth: max(1, analysisWidth))
            return 2 * (Double(max(0, sample.area)) / Double.pi).squareRoot() * (local.isFinite ? local : 0)
        }
        let start = SkyMath.direction(of: first.unit), end = SkyMath.direction(of: last.unit)
        return SkyMeasures(azimuth: start.azimuth, elevation: start.elevation, azimuthEnd: end.azimuth, elevationEnd: end.elevation,
                           duration: finite(duration), speed: finite(speed), acceleration: finite(slope(speeds)), turnRate: finite(turnRate),
                           maxTurn: finite(maxTurn), straightness: finite(straightness), shape: shape, sizeDegrees: finite(median(sizes)),
                           brightness: finite(brightness), blinks: blinking.blinks, blinkRate: blinking.rate, focus: finite(focus))
    }

    // MARK: Pieces

    private struct Point {
        var time: Double
        var unit: SIMD3<Double>
        var sample: SkyTrackSample
    }

    /// The angle between two unit vectors (degrees).
    private static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        atan2(SkyMath.length(SkyMath.cross(a, b)), SkyMath.dot(a, b)) * SkyMath.degrees
    }

    /// The heading change at `b` (degrees, 0…180) from the great circle arriving from `a` to the one leaving for `c`: zero on one great
    /// circle, however far along it. Nil when a chord has no direction.
    private static func turn(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Double? {
        let arriving = b * SkyMath.dot(a, b) - a, leaving = c - b * SkyMath.dot(b, c)
        let lengths = SkyMath.length(arriving) * SkyMath.length(leaving)
        guard lengths > 0, lengths.isFinite else { return nil }
        return atan2(SkyMath.length(SkyMath.cross(arriving, leaving)), SkyMath.dot(arriving, leaving)) * SkyMath.degrees
    }

    /// Where the track was at `time`: between the samples around it (along the chord, then onto the sphere).
    private static func position(_ points: [Point], at time: Double) -> SIMD3<Double>? {
        guard let first = points.first, let last = points.last, time >= first.time - 1e-9, time <= last.time + 1e-9 else { return nil }
        var low = 0, high = points.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if points[middle].time <= time { low = middle } else { high = middle }
        }
        let a = points[low], b = points[high]
        let span = b.time - a.time
        let share = span > 0 ? min(1, max(0, (time - a.time) / span)) : 0
        let mixed = a.unit * (1 - share) + b.unit * share
        let length = SkyMath.length(mixed)
        return length > 0 ? mixed / length : nil
    }

    /// Whether the light stopped suddenly: at some sample its speed over the second before was 0.5°/s or more, and within 0.6 s it then
    /// kept, for a second, to 10 % of that speed or less: the least-squares speed of its positions over that second (a centroid's wander
    /// of a few tenths of a pixel moves none of it far, where a slow light's stay is a fraction of a pixel across).
    private static func stops(_ points: [Point]) -> Bool {
        guard let end = points.last?.time else { return false }
        var earliest = 0
        for (index, point) in points.enumerated() {
            while earliest < index && points[earliest].time < point.time - stopLookBack - 1e-9 { earliest += 1 }
            let back = points[earliest]
            let span = point.time - back.time
            guard earliest < index, span >= stopLookBackAtLeast - 1e-9 else { continue }
            let before = angle(back.unit, point.unit) / span
            guard before >= stopFromSpeed else { continue }
            for start in index..<points.count where points[start].time - point.time <= stopWithin + 1e-9 {
                let from = points[start].time
                guard end - from >= stopStays - 1e-9 else { break }
                let stay = points[start...].prefix { $0.time - from <= stopStays + 1e-9 }
                guard stay.count >= stayPoints, let speed = fittedSpeed(stay) else { continue }
                if speed <= stopShare * before { return true }
            }
        }
        return false
    }

    /// The least-squares speed (°/s) of `points` over their times: their directions on the plane touching the sky at their middle, a line
    /// fitted over time on each of its two axes. Nil when they have no middle or no spread in time.
    private static func fittedSpeed(_ points: ArraySlice<Point>) -> Double? {
        let sum = points.reduce(SIMD3<Double>(repeating: 0)) { $0 + $1.unit }
        let length = SkyMath.length(sum)
        guard length > 0, !points.isEmpty else { return nil }
        let centre = sum / length
        let helper = abs(centre.z) < 0.9 ? SIMD3(0.0, 0, 1) : SIMD3(1.0, 0, 0)
        let across = SkyMath.cross(centre, helper) / SkyMath.length(SkyMath.cross(centre, helper))
        let along = SkyMath.cross(centre, across)
        let meanTime = points.reduce(0) { $0 + $1.time } / Double(points.count)
        var first = 0.0, second = 0.0, spread = 0.0
        for point in points {
            let dt = point.time - meanTime
            first += dt * SkyMath.dot(point.unit, across)
            second += dt * SkyMath.dot(point.unit, along)
            spread += dt * dt
        }
        guard spread > 0 else { return nil }
        return (first * first + second * second).squareRoot() / spread * SkyMath.degrees
    }

    /// Dips: runs of pictures (the samples, and the misses as nothing seen) below 30 % of the median flux. Blinking is 3 or more; the rate
    /// is their frequency, from the first dip's start to the last's.
    private static func blinks(_ samples: [SkyTrackSample], misses: [TimeInterval]) -> (blinks: Bool, rate: Double?) {
        let level = median(samples.map(\.flux).filter(\.isFinite))
        guard level > 0, let first = samples.first?.time, let last = samples.last?.time else { return (false, nil) }
        let pictures = (samples.map { (time: $0.time, flux: $0.flux) } + misses.filter { $0 > first && $0 < last }.map { (time: $0, flux: 0.0) })
            .sorted { $0.time < $1.time }
        var starts: [Double] = []
        var low = false
        for picture in pictures {
            let dim = !(picture.flux >= dipShare * level)
            if dim && !low { starts.append(picture.time) }
            low = dim
        }
        guard starts.count >= blinkDips, let firstDip = starts.first, let lastDip = starts.last, lastDip > firstDip else { return (false, nil) }
        return (true, Double(starts.count - 1) / (lastDip - firstDip))
    }

    /// The least-squares slope of `values` over time, each weighted by the time it covers; 0 with fewer than two.
    private static func slope(_ values: [(time: Double, speed: Double, weight: Double)]) -> Double {
        let total = values.reduce(0) { $0 + $1.weight }
        guard values.count >= 2, total > 0 else { return 0 }
        let meanTime = values.reduce(0) { $0 + $1.weight * $1.time } / total
        let meanSpeed = values.reduce(0) { $0 + $1.weight * $1.speed } / total
        var covariance = 0.0, variance = 0.0
        for value in values {
            covariance += value.weight * (value.time - meanTime) * (value.speed - meanSpeed)
            variance += value.weight * (value.time - meanTime) * (value.time - meanTime)
        }
        return variance > 0 ? covariance / variance : 0
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
