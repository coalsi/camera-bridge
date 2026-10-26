import Foundation

// The older logs, joined as they are read (`BridgeEngine.skyNightLog`): the lights the log kept in pieces, before the detector held a light until nothing
// could continue it (`SkyStitchHold`), are one entry on the page. Nothing is written: the log stays append-only, and the next read joins again.

extension SkyStitch {
    /// The paths a joined light keeps: at most this many points, as an entry's.
    static let joinedPathPoints = SkyPathPoint.maximumPerEntry
    /// A light's path whole (one point a picture) has fewer points than this: a path thinned to it keeps no account of the pictures it was missed in.
    static let wholePathPoints = SkyPathPoint.maximumPerEntry
    /// In a gap between two pictures, at most this many are taken as missed.
    static let mostMissesInAGap = 64

    /// `entries` (a night's, in their order) with the moving lights that are one light (`SkyStitch`'s rule, taken in the order they began) as one entry each
    /// (`entry(of:entries:picture:corrected:)`), in the place of the first of them; every other entry as it was. `picture`: the camera's analysed picture;
    /// `isDay(start)`: the Sun at −6° or above when a light began (only then can it be a contrail's); `corrected`: when each entry's last correction was made
    /// (`SkyLogContents.corrected`), so that the latest of a joined light's parts shows. This runs before anything that sorts or groups the night's lights:
    /// they sort and group the joined ones.
    static func joined(_ entries: [SkyEntry], picture: Picture, isDay: (Date) -> Bool, corrected: [String: Date] = [:]) -> [SkyEntry] {
        var byID: [String: SkyEntry] = [:]
        var order: [SkyEntry] = []
        for entry in entries where entry.kind == .track && !entry.path.isEmpty && entry.start.timeIntervalSince1970.isFinite && byID[entry.id] == nil {
            byID[entry.id] = entry
            order.append(entry)
        }
        guard order.count >= 2 else { return entries }
        order.sort { ($0.start, $0.id) < ($1.start, $1.id) }
        var joiner = Joiner(picture: picture)
        var lights: [Light] = []
        for entry in order {
            lights += joiner.closed(before: entry.start.timeIntervalSince1970 - longestGap - 1)
            joiner.add(piece(of: entry, in: picture, byDay: isDay(entry.start)))
        }
        lights += joiner.lights
        var replacing: [String: SkyEntry] = [:]
        var taken = Set<String>()
        for light in lights where light.parts.count > 1 {
            guard let joined = entry(of: light, entries: byID, picture: picture, corrected: corrected) else { continue }
            replacing[joined.id] = joined
            taken.formUnion(light.parts.map(\.id))
        }
        guard !replacing.isEmpty else { return entries }
        var shown = Set<String>()
        return entries.compactMap { entry in
            if let joined = replacing[entry.id] {
                guard shown.insert(entry.id).inserted else { return nil }
                return joined
            }
            return taken.contains(entry.id) ? nil : entry
        }
    }

    /// A logged light as a piece: its path's points in the analysed picture's pixels, on the box's clock (seconds since 1970).
    static func piece(of entry: SkyEntry, in picture: Picture, byDay: Bool) -> Piece {
        let start = entry.start.timeIntervalSince1970
        return Piece(id: entry.id, points: entry.path.map { picture.point(t: start + $0.t, x: $0.x, y: $0.y) }, byDay: byDay)
    }

    /// A light joined from logged lights as one entry: the first part's id and camera, `parts` every part's id in the order they began, `pieces` the pieces
    /// they were seen in; from the first part's start to the last one's end; its path the spine's (its own pieces', not its contrail's), at most 64 points
    /// evenly picked, the first and the last among them; the measures of the whole light (`measures(of:)`). What it is: a flight's when a part matched one
    /// (the longest such), else its longest piece's (the rules' word, the guide's priority and reasons, or nothing yet: what sorts the night later judges
    /// the joined light). The person's latest word on any part shows; it alerted when any part did; its picture is the part nearest its middle that has one
    /// (`stillPart`: that part's id and path, as the small picture is cut around it), else none; the AI's sentence is that picture's, else its longest
    /// piece's. Nil when fewer than two of its parts are in `entries`.
    static func entry(of light: Light, entries: [String: SkyEntry], picture: Picture, corrected: [String: Date]) -> SkyEntry? {
        let parts = light.parts.compactMap { part in entries[part.id].map { (part: part, entry: $0) } }
            .sorted { ($0.entry.start, $0.entry.id) < ($1.entry.start, $1.entry.id) }
        guard parts.count >= 2, let first = parts.first?.entry else { return nil }
        let spine = parts.filter { $0.part.link != .trail }.map(\.entry)
        let start = parts.map(\.entry.start).min() ?? first.start
        let end = max(start, parts.map(\.entry.end).max() ?? first.end)
        let longest = { (list: [SkyEntry]) in list.max { ($0.measures.duration, $1.start) < ($1.measures.duration, $0.start) } }
        let main = longest(parts.map(\.entry).filter { $0.by == .flight }) ?? longest(spine) ?? first
        let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        let still = parts.map(\.entry).filter(\.hasStill).min {
            (abs(SkyStillBackfill.middle(of: $0).timeIntervalSince(middle)), $0.start) < (abs(SkyStillBackfill.middle(of: $1).timeIntervalSince(middle)), $1.start)
        }
        let said = parts.map(\.entry).filter { $0.correction != nil }.max {
            (corrected[$0.id] ?? .distantPast, $0.start) < (corrected[$1.id] ?? .distantPast, $1.start)
        }
        let origin = start.timeIntervalSince1970
        let path = evenly(light.spine.map { SkyPathPoint(t: $0.t - origin, x: $0.x / picture.width, y: $0.y / picture.height) }, joinedPathPoints)
        let fromAFlight = main.by == .flight
        var joined = SkyEntry(id: first.id, camera: first.camera, kind: .track, start: start, end: end, path: path,
                              measures: measures(of: spine.isEmpty ? [main] : spine), label: main.label, by: main.by, detail: main.detail,
                              unusual: fromAFlight ? [] : main.unusual, speedVsPlanes: fromAFlight ? nil : main.speedVsPlanes,
                              candidate: fromAFlight ? false : main.candidate, alerted: parts.contains { $0.entry.alerted }, hasStill: still != nil,
                              ai: still?.ai ?? main.ai ?? parts.first { $0.entry.ai != nil }?.entry.ai, correction: said?.correction,
                              priority: fromAFlight ? nil : main.priority, reasons: fromAFlight ? [] : main.reasons, doubtful: fromAFlight ? false : main.doubtful)
        joined.pieces = parts.reduce(0) { $0 + max(1, $1.entry.pieces) }
        joined.parts = parts.map(\.entry.id)
        joined.stillPart = still.map { SkyStillPart(id: $0.id, path: $0.path) }
        return joined
    }

    /// At most `count` of `points`, evenly picked, the first and the last among them.
    static func evenly<Element>(_ points: [Element], _ count: Int) -> [Element] {
        guard points.count > count, count >= 2 else { return points }
        let last = points.count - 1, steps = count - 1
        return (0...steps).map { points[$0 * last / steps] }
    }

    // MARK: The measures of a joined light

    /// The measures of a light joined from the logged lights of its path (`spine`): from where the first was first seen to where the last was last seen
    /// (each through the aim it was logged with), over its whole time; its path the parts' own and the sky crossed in each gap between them (once where two
    /// were seen at once); its speed that path over the time; its straightness the chord over the path; its acceleration the slope of the parts' speeds over
    /// their middles, by how long each lasted; its turns the largest of the parts' and their turn rates by how long each lasted; its shape a sharp turn when a
    /// part turned sharply, a sudden stop when its last part stopped, else straight or curved as `TrackMeasurer` says; its size, brightness and focus the
    /// medians of the parts' by how long each lasted. Its blinking, strobe and the share of its pictures it was seen in come from its pictures from the first
    /// to the last (`pictures(of:)`): the dark ones in its gaps are what blinks (a light seen in pieces at a steady rhythm is a strobe), as `TrackMeasurer`
    /// measures them; a part that blinked by its brightness alone blinks the light too. Its wobble and turns are not measured again without the aim (nil).
    static func measures(of spine: [SkyEntry]) -> SkyMeasures {
        let parts = spine.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        guard let first = parts.first else {
            return SkyMeasures(azimuth: 0, elevation: 0, azimuthEnd: 0, elevationEnd: 0, duration: 0, speed: 0, acceleration: 0, turnRate: 0, maxTurn: 0,
                               straightness: 1, shape: .straight, sizeDegrees: 0, brightness: 0, blinks: false, blinkRate: nil, focus: 0)
        }
        let last = parts.max { ($0.end, $0.start) < ($1.end, $1.start) } ?? first
        let begins = SkyDirection(azimuth: first.measures.azimuth, elevation: first.measures.elevation)
        let ends = SkyDirection(azimuth: last.measures.azimuthEnd, elevation: last.measures.elevationEnd)
        let duration = max(0, last.end.timeIntervalSince(first.start))
        // The path: each part's own, past what was already covered, and the sky crossed in each gap.
        var path = 0.0
        var covered = -Double.infinity
        var before: SkyDirection?
        for part in parts {
            let from = part.start.timeIntervalSince1970, to = part.end.timeIntervalSince1970
            guard to > covered else { continue }
            let lasted = max(0, part.measures.duration)
            let share = to > from ? min(1, (to - max(from, covered)) / (to - from)) : 1
            path += plain(part.measures.speed) * lasted * share
            if from > covered, let before {
                path += plain(SkyMath.separation(before, SkyDirection(azimuth: part.measures.azimuth, elevation: part.measures.elevation)))
            }
            covered = to
            before = SkyDirection(azimuth: part.measures.azimuthEnd, elevation: part.measures.elevationEnd)
        }
        let chord = plain(SkyMath.separation(begins, ends))
        path = max(path, chord)
        let straightness = path > 0 ? min(1, chord / path) : 1
        let weight = { (part: SkyEntry) in max(part.measures.duration, 0.2) }
        let maxTurn = parts.map { plain($0.measures.maxTurn) }.max() ?? 0
        let total = parts.reduce(0) { $0 + weight($1) }
        let turnRate = total > 0 ? parts.reduce(0) { $0 + plain($1.measures.turnRate) * weight($1) } / total : 0
        let shape: SkyPathShape
        if parts.contains(where: { $0.measures.shape == .sharpTurn }) {
            shape = .sharpTurn
        } else if last.measures.shape == .suddenStop {
            shape = .suddenStop
        } else {
            shape = maxTurn < TrackMeasurer.straightTurn && straightness >= TrackMeasurer.straightLine ? .straight : .curved
        }
        let pictures = Self.pictures(of: parts)
        let blinking = blinks(pictures)
        let flashing = TrackMeasurer.strobe(pictures)
        let seen = pictures.filter { $0.flux > 0 }.count
        let blinkingPart = parts.filter { $0.measures.blinks }.max { $0.measures.duration < $1.measures.duration }
        return SkyMeasures(azimuth: begins.azimuth, elevation: begins.elevation, azimuthEnd: ends.azimuth, elevationEnd: ends.elevation,
                           duration: duration, speed: duration > 0 ? path / duration : 0, acceleration: slope(parts), turnRate: plain(turnRate),
                           maxTurn: maxTurn, straightness: straightness, shape: shape,
                           sizeDegrees: median(parts.map { (plain($0.measures.sizeDegrees), weight($0)) }),
                           brightness: median(parts.map { (plain($0.measures.brightness), weight($0)) }),
                           blinks: blinking.blinks || blinkingPart != nil, blinkRate: blinking.blinks ? blinking.rate : blinkingPart?.measures.blinkRate,
                           focus: median(parts.map { (plain($0.measures.focus), weight($0)) }),
                           strobePeriod: flashing?.period, strobeStrength: flashing?.strength,
                           seenShare: pictures.isEmpty ? nil : Double(seen) / Double(pictures.count))
    }

    /// The pictures of a light joined from `parts` (in the order they began), from its first to its last, in time order, at the analysis pace
    /// (`SkyStreamChoice.analysisRate`): each part's path points seen (brightness 1) and the pictures missed between them dark (0) when its path is whole,
    /// else seen at the pace all along; the pictures of each gap between parts dark; where two parts were seen at once, once.
    static func pictures(of parts: [SkyEntry]) -> [(time: Double, flux: Double)] {
        let pace = 1 / SkyStreamChoice.analysisRate
        var pictures: [(time: Double, flux: Double)] = []
        var covered = -Double.infinity
        func dark(from: Double, to: Double) {
            let gap = to - from
            guard gap > 1.5 * pace else { return }
            let count = min(Int((gap / pace).rounded()) - 1, mostMissesInAGap)
            guard count > 0 else { return }
            for k in 1...count { pictures.append((from + gap * Double(k) / Double(count + 1), 0)) }
        }
        for part in parts {
            let origin = part.start.timeIntervalSince1970
            var seen: [Double]
            if part.path.count < wholePathPoints {
                seen = part.path.map { origin + $0.t }.filter(\.isFinite).sorted()
            } else {
                let to = part.end.timeIntervalSince1970
                seen = Array(Swift.stride(from: origin, through: to, by: pace))
            }
            seen = seen.filter { $0 > covered + SkyStitch.samePicture }
            guard let firstSeen = seen.first, let lastSeen = seen.last else { continue }
            if covered.isFinite { dark(from: covered, to: firstSeen) }
            var previous: Double?
            for time in seen {
                if let previous, part.path.count < wholePathPoints { dark(from: previous, to: time) }
                pictures.append((time, 1))
                previous = time
            }
            covered = lastSeen
        }
        return pictures.sorted { $0.time < $1.time }
    }

    /// Dips in a light's pictures (runs of dark ones), as `TrackMeasurer` counts a blinking light's: blinking at three or more, at (dips − 1) over the
    /// time from the first dip's start to the last one's.
    static func blinks(_ pictures: [(time: Double, flux: Double)]) -> (blinks: Bool, rate: Double?) {
        var starts: [Double] = []
        var low = false
        for picture in pictures {
            let dim = !(picture.flux >= TrackMeasurer.dipShare)
            if dim && !low { starts.append(picture.time) }
            low = dim
        }
        guard starts.count >= TrackMeasurer.blinkDips, let firstDip = starts.first, let lastDip = starts.last, lastDip > firstDip else { return (false, nil) }
        return (true, Double(starts.count - 1) / (lastDip - firstDip))
    }

    /// The least-squares slope of the parts' speeds over their middles (°/s²), each weighted by how long it lasted; 0 with fewer than two.
    private static func slope(_ parts: [SkyEntry]) -> Double {
        let values = parts.map { part -> (time: Double, speed: Double, weight: Double) in
            (part.start.timeIntervalSince1970 + max(0, part.measures.duration) / 2, plain(part.measures.speed), max(part.measures.duration, 0.2))
        }
        let total = values.reduce(0) { $0 + $1.weight }
        guard values.count >= 2, total > 0 else { return 0 }
        let meanTime = values.reduce(0) { $0 + $1.weight * $1.time } / total
        let meanSpeed = values.reduce(0) { $0 + $1.weight * $1.speed } / total
        var covariance = 0.0, variance = 0.0
        for value in values {
            covariance += value.weight * (value.time - meanTime) * (value.speed - meanSpeed)
            variance += value.weight * (value.time - meanTime) * (value.time - meanTime)
        }
        return variance > 0 ? plain(covariance / variance) : 0
    }

    /// The median of weighted values (the value at which half the weight is reached).
    private static func median(_ values: [(Double, Double)]) -> Double {
        let sorted = values.filter { $0.1 > 0 }.sorted { $0.0 < $1.0 }
        let total = sorted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return 0 }
        var running = 0.0
        for (value, weight) in sorted {
            running += weight
            if running >= total / 2 { return value }
        }
        return sorted.last?.0 ?? 0
    }

    private static func plain(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
