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
    /// A regular flash like a plane's strobe (the overnight prototype's measure): the period (s) of the first clear repeat of its brightness
    /// between 0.6 and 1.6 s, nil when there is none; and how strong it is (0…1; 0 when there is none). Both nil when the light was followed
    /// for fewer than 20 pictures. The pictures it was missing from count as dark.
    public var strobePeriod: Double?
    public var strobeStrength: Double?
    /// The share of its pictures it was seen in (1: a steady light; a plane's strobe seen only when it flashes, far less).
    public var seenShare: Double?
    /// How far its positions stray from a smooth path (degrees, the root mean square from quadratic fits over time, 30 s at a time): a light's
    /// track keeps within a tenth of a degree or two, a chain of noise does not.
    public var wobble: Double?
    /// How many times its path turned by 45° or more (between the chords the turn rate is measured on).
    public var turns: Int?
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
///
/// **The overnight prototype's measures** (ported for `SkyRules`):
/// - the strobe: the brightness of each of its pictures from the first to the last (a picture it was missing from is dark), less its running
///   median over 11 pictures (the edges repeated) and its mean; the first lag between 0.6 and 1.6 s whose autocorrelation is over 0.25, a peak
///   among its neighbours, and at least 0.3 over the autocorrelation at half that lag (a real period has a dip there), gives the period and its
///   strength. The 2 s pulse of a faint light at the camera's keyframes is outside the range on purpose. At least 20 pictures;
/// - the wobble: the directions on the plane touching the sky at the track's middle, a quadratic over time fitted on each axis 30 s at a time,
///   the root mean square of what is left (degrees);
/// - the turns: the turns of 45° or more between the turn rate's chords (at least 20 pixels each).
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
    /// The prototype's strobe: the periods looked at (s), the pictures it needs, its running median, how strong a repeat must be and how far
    /// over the half lag's.
    static let strobePeriods: ClosedRange<Double> = 0.6...1.6
    static let strobePictures = 20
    static let strobeMedianPictures = 11
    static let strobeLongestLag: TimeInterval = 3.4
    static let strobeFloor = 0.25
    static let strobeDip = 0.3
    /// The wobble's fits: at most this long each.
    static let wobbleWindow: TimeInterval = 30
    /// A turn counts from this many degrees.
    static let turnDegrees = 45.0

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
        let pictures = Self.pictures(samples, misses: track.misses)
        let flashing = strobe(pictures)
        let seenShare = pictures.isEmpty ? nil : Double(samples.count) / Double(pictures.count)

        let points = Self.points(samples, model: model)
        guard let first = points.first, let last = points.last else {
            return SkyMeasures(azimuth: 0, elevation: 0, azimuthEnd: 0, elevationEnd: 0, duration: 0, speed: 0, acceleration: 0, turnRate: 0,
                               maxTurn: 0, straightness: 1, shape: .straight, sizeDegrees: 0, brightness: finite(brightness), blinks: blinking.blinks,
                               blinkRate: blinking.rate, focus: finite(focus), strobePeriod: flashing?.period, strobeStrength: flashing?.strength,
                               seenShare: seenShare)
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
        let (turning, covered, turns) = Self.turning(points, pixel: pixel)
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
        let wobble = wobbleDegrees(points)
        return SkyMeasures(azimuth: start.azimuth, elevation: start.elevation, azimuthEnd: end.azimuth, elevationEnd: end.elevation,
                           duration: finite(duration), speed: finite(speed), acceleration: finite(slope(speeds)), turnRate: finite(turnRate),
                           maxTurn: finite(maxTurn), straightness: finite(straightness), shape: shape, sizeDegrees: finite(median(sizes)),
                           brightness: finite(brightness), blinks: blinking.blinks, blinkRate: blinking.rate, focus: finite(focus),
                           strobePeriod: flashing?.period, strobeStrength: flashing?.strength, seenShare: seenShare,
                           wobble: finite(wobble), turns: turns)
    }

    /// What a logged light's path gives again (`SkySortLater`: an entry logged before these measures keeps its path, not them).
    struct PathMeasures: Sendable, Equatable {
        var wobble: Double
        var turns: Int
        var strobePeriod: Double? = nil
        var strobeStrength: Double? = nil
        var seenShare: Double? = nil
    }

    /// The wobble and the turns of `track`'s points through `model` (an analysis `analysisWidth` wide), placed and counted as `measure` does,
    /// and, when `pictures` (its samples are every picture it was seen in, its misses every one it was not), from them (each sample at the
    /// brightness it was given, each miss dark) the strobe and the share of them it was seen in: the cheap part of `measure`, for a path read back
    /// from the log. Nil when the model places none of it.
    static func pathMeasures(_ track: SkyTrack, model: SkyCameraModel, analysisWidth: Int, pictures: Bool) -> PathMeasures? {
        let samples = track.samples.filter { $0.time.isFinite }.sorted { $0.time < $1.time }
        let points = Self.points(samples, model: model)
        guard !points.isEmpty else { return nil }
        var pixel = model.degreesPerPixel(at: points[points.count / 2].sample.point, pictureWidth: max(1, analysisWidth))
        if !(pixel.isFinite && pixel > 0) { pixel = 0 }
        var measured = PathMeasures(wobble: finite(wobbleDegrees(points)), turns: turning(points, pixel: pixel).turns)
        if pictures {
            let all = Self.pictures(samples, misses: track.misses)
            let flashing = strobe(all)
            measured.strobePeriod = flashing?.period
            measured.strobeStrength = flashing?.strength
            measured.seenShare = all.isEmpty ? nil : Double(samples.count) / Double(all.count)
        }
        return measured
    }

    // MARK: Pieces

    private struct Point {
        var time: Double
        var unit: SIMD3<Double>
        var sample: SkyTrackSample
    }

    /// The samples the model places in the sky, each through the lens it was seen in: the samples' own, unless one outside the seam band
    /// disagrees with the model's split (the picture was analysed without the model, which knows only one lens), and then the split's.
    private static func points(_ samples: [SkyTrackSample], model: SkyCameraModel) -> [Point] {
        let trusted = !samples.contains { $0.point.x.isFinite && model.lens(at: $0.point) != $0.lens && !model.isInSeamBand($0.point) }
        return samples.compactMap { sample in
            guard sample.point.x.isFinite, sample.point.y.isFinite,
                  let direction = model.direction(at: sample.point, lens: trusted ? sample.lens : model.lens(at: sample.point)),
                  direction.azimuth.isFinite, direction.elevation.isFinite else { return nil }
            return Point(time: sample.time, unit: SkyMath.unitVector(direction), sample: sample)
        }
    }

    /// The turns between the chords of at least `headingPixels` (`pixel` degrees each) along `points`: all of their heading changes, the path
    /// they cover (each turn is between the chords on either side of a node, so the turns cover the path from the first chord's middle to the
    /// last one's: that is what they are per degree of), and how many were of `turnDegrees` or more.
    private static func turning(_ points: [Point], pixel: Double) -> (turning: Double, covered: Double, turns: Int) {
        guard !points.isEmpty else { return (0, 0, 0) }
        var headings = [0]
        for index in 1..<points.count where angle(points[headings[headings.count - 1]].unit, points[index].unit) >= headingPixels * pixel {
            headings.append(index)
        }
        var turning = 0.0, covered = 0.0, turns = 0
        if headings.count >= 3 {
            let chords = (1..<headings.count).map { angle(points[headings[$0 - 1]].unit, points[headings[$0]].unit) }
            covered = chords.reduce(0, +) - (chords[0] + chords[chords.count - 1]) / 2
            for k in 1..<(headings.count - 1) {
                let change = turn(points[headings[k - 1]].unit, points[headings[k]].unit, points[headings[k + 1]].unit) ?? 0
                turning += change
                if change >= turnDegrees { turns += 1 }
            }
        }
        return (turning, covered, turns)
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

    /// The pictures of a track from its first sample to its last, in time order: each sample's flux, and a miss (`SkyTrack.misses`) as dark.
    private static func pictures(_ samples: [SkyTrackSample], misses: [TimeInterval]) -> [(time: Double, flux: Double)] {
        guard let first = samples.first?.time, let last = samples.last?.time else { return [] }
        return (samples.map { (time: $0.time, flux: $0.flux.isFinite ? $0.flux : 0) }
            + misses.filter { $0 > first && $0 < last && $0.isFinite }.map { (time: $0, flux: 0.0) }).sorted { $0.time < $1.time }
    }

    /// The prototype's strobe of a light's pictures (see the type's notes): nil with fewer than `strobePictures`; else the period and strength
    /// of the first clear repeat between 0.6 and 1.6 s, or a strength of 0 and no period when there is none.
    static func strobe(_ pictures: [(time: Double, flux: Double)]) -> (period: Double?, strength: Double)? {
        let n = pictures.count
        guard n >= strobePictures, let first = pictures.first?.time, let last = pictures.last?.time, last > first else { return nil }
        let interval = (last - first) / Double(n - 1)
        let flux = pictures.map(\.flux)
        let reach = strobeMedianPictures / 2
        // One window, sorted in place for each picture (not a new array each time: this runs for every light).
        var window = [Double](repeating: 0, count: 2 * reach + 1)
        var residual = [Double](repeating: 0, count: n)
        for index in 0..<n {
            for offset in 0..<window.count { window[offset] = flux[min(n - 1, max(0, index - reach + offset))] }
            window.sort()
            residual[index] = flux[index] - window[reach]
        }
        let mean = residual.reduce(0, +) / Double(n)
        residual = residual.map { $0 - mean }
        let power = residual.reduce(0) { $0 + $1 * $1 }
        guard power > 0 else { return (nil, 0) }
        let lags = min(Int((strobeLongestLag / interval).rounded(.toNearestOrEven)), n / 2)
        guard lags > 2 else { return (nil, 0) }
        var correlation = [0.0]
        for lag in 1..<lags {
            var sum = 0.0
            for index in 0..<(n - lag) { sum += residual[index] * residual[index + lag] }
            correlation.append(sum / power * Double(n) / Double(n - lag))
        }
        let lowest = max(2, Int((strobePeriods.lowerBound / interval).rounded(.toNearestOrEven)))
        let highest = min(Int((strobePeriods.upperBound / interval).rounded(.toNearestOrEven)), correlation.count - 2)
        guard lowest <= highest else { return (nil, 0) }
        for lag in lowest...highest {
            let value = correlation[lag]
            guard value > strobeFloor, value >= correlation[lag - 1], value >= correlation[lag + 1] else { continue }
            let half = max(1, Int((Double(lag) / 2).rounded(.toNearestOrEven)))
            if correlation[half] < value - strobeDip { return (Double(lag) * interval, value) }
        }
        return (nil, 0)
    }

    /// How far the points stray from a smooth path (degrees): on the plane touching the sky at their middle, a quadratic over time fitted on
    /// each axis, `wobbleWindow` at a time (a line for a window of four points; none for fewer), the root mean square of what is left.
    private static func wobbleDegrees(_ points: [Point]) -> Double {
        let sum = points.reduce(SIMD3<Double>(repeating: 0)) { $0 + $1.unit }
        let length = SkyMath.length(sum)
        guard length > 0, points.count >= 4, let start = points.first?.time else { return 0 }
        let centre = sum / length
        let helper = abs(centre.z) < 0.9 ? SIMD3(0.0, 0, 1) : SIMD3(1.0, 0, 0)
        let across = SkyMath.cross(centre, helper) / SkyMath.length(SkyMath.cross(centre, helper))
        let along = SkyMath.cross(centre, across)
        var squares = 0.0, counted = 0
        var from = start
        while let last = points.last?.time, from <= last {
            let window = points.filter { $0.time >= from && $0.time < from + wobbleWindow }
            from += wobbleWindow
            guard window.count >= 4 else { continue }
            let times = window.map(\.time)
            for axis in [across, along] {
                let values = window.map { SkyMath.dot($0.unit, axis) * SkyMath.degrees }
                squares += residualSquares(times, values, degree: window.count >= 5 ? 2 : 1)
            }
            counted += window.count
        }
        return counted > 0 ? (squares / Double(counted)).squareRoot() : 0
    }

    /// The sum of the squared residuals of a least-squares polynomial of `degree` (1 or 2) of `values` over `times`.
    private static func residualSquares(_ times: [Double], _ values: [Double], degree: Int) -> Double {
        let n = Double(times.count)
        let middle = times.reduce(0, +) / n
        let span = max(1e-9, (times.map { abs($0 - middle) }.max() ?? 1))
        let x = times.map { ($0 - middle) / span }
        // The normal equations of 1, x and x² (or 1 and x), solved by Gaussian elimination. Their sums are added up point by point in scalars, each
        // as the matrix's own entry would be (x² as x·x, x³ as x·x², x⁴ as x²·x²): it runs for every light, and a matrix of arrays added to
        // point by point was most of the measuring.
        let size = degree + 1
        var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, r0 = 0.0, r1 = 0.0, r2 = 0.0
        for (xi, yi) in zip(x, values) {
            let square = xi * xi
            s0 += 1
            s1 += xi
            s2 += square
            r0 += yi
            r1 += xi * yi
            if size > 2 {
                s3 += xi * square
                s4 += square * square
                r2 += square * yi
            }
        }
        var matrix = size > 2 ? [[s0, s1, s2, r0], [s1, s2, s3, r1], [s2, s3, s4, r2]] : [[s0, s1, r0], [s1, s2, r1]]
        for pivot in 0..<size {
            guard let best = (pivot..<size).max(by: { abs(matrix[$0][pivot]) < abs(matrix[$1][pivot]) }), abs(matrix[best][pivot]) > 1e-12 else {
                return degree > 1 ? residualSquares(times, values, degree: degree - 1) : 0
            }
            matrix.swapAt(pivot, best)
            for row in 0..<size where row != pivot {
                let factor = matrix[row][pivot] / matrix[pivot][pivot]
                for column in pivot...size { matrix[row][column] -= factor * matrix[pivot][column] }
            }
        }
        let coefficients = (0..<size).map { matrix[$0][size] / matrix[$0][$0] }
        var squares = 0.0
        for (xi, yi) in zip(x, values) {
            var fitted = 0.0, power = 1.0
            for coefficient in coefficients {
                fitted += coefficient * power
                power *= xi
            }
            squares += (yi - fitted) * (yi - fitted)
        }
        return squares
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
