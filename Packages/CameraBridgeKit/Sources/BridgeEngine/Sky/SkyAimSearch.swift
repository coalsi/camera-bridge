import Foundation

/// The wide search of a sky camera's card (Ruling S18): when planes have flown through the view for two hours and none matched while the aim is
/// still rough, the card the person set may be far off (more than the rough aim's 15°). The unexplained tracks of the last two hours are judged
/// again, each with the aircraft that were around it, through the cards of a grid around the one in use: facing ±45° in 15° steps and tilt
/// ±30° in 10° steps (kept within 0…90°), each the start model `SkyCameraModel.initial` makes of it, matched as the flight matcher matches a
/// rough aim. The card that explains the most aircraft wins when it explains at least 5 and at least twice as many as the best card that is not
/// next to it on the grid (a neighbour, 15° or 10° away, sees the same planes within the rough tolerance: it is the same answer, not a rival);
/// of cards that explain as many, the one whose matches are nearest. Pure and bounded: at most `maximumRecords` tracks of
/// `samplesPerRecord` pictures, each with at most `aircraftPerRecord` aircraft, through at most 49 cards.
enum SkyAimSearch {
    /// A card: which way the camera faces (degrees from true north) and how far it is tilted up.
    struct Card: Codable, Sendable, Equatable {
        var facing: Double
        var tilt: Double

        static let zero = Card(facing: 0, tilt: 0)
    }

    /// An unexplained track kept for the search: its pictures (at most `samplesPerRecord`), the sizes it was seen at, and each aircraft that was
    /// within `maximumRange` and above the horizon at its middle, placed at each of its pictures' times (one report each, so nothing is
    /// interpolated twice). Kept in memory only: with its times, where aircraft were tells where the box is.
    struct Record: Sendable {
        var track: SkyTrack
        var analysisWidth: Int
        var pictureWidth: Int
        var flights: [String: [AircraftReport]]
        /// The track's last picture (the box's clock): a record is kept for `window`.
        var end: Date
    }

    /// The winner: the card itself, how many aircraft it explains and how many the best card not next to it does.
    struct Outcome: Sendable, Equatable {
        var card: Card
        var aircraft: Int
        var runnerUp: Int
    }

    static let facingSteps: [Double] = [-45, -30, -15, 0, 15, 30, 45]
    static let tiltSteps: [Double] = [-30, -20, -10, 0, 10, 20, 30]
    static let minimumAircraft = 5
    static let clearFactor = 2
    /// The tracks of the last two hours are searched, at most once an hour.
    static let window: TimeInterval = 7_200
    static let interval: TimeInterval = 3_600
    static let maximumRecords = 40
    static let samplesPerRecord = 16
    static let aircraftPerRecord = 40
    static let maximumRange = 100_000.0

    /// `track` kept for the search with the aircraft of `flights` around it (each aircraft's reports in time order or not), or nil when none was
    /// near enough to be the light.
    static func record(of track: SkyTrack, analysisWidth: Int, pictureWidth: Int, flights: [String: [AircraftReport]], observer: SkyObserver) -> Record? {
        let samples = track.samples.filter { $0.wallClock.timeIntervalSince1970.isFinite && $0.point.x.isFinite && $0.point.y.isFinite }
            .sorted { $0.wallClock < $1.wallClock }
        guard samples.count >= 2, let first = samples.first, let last = samples.last else { return nil }
        let picked = evenly(samples, samplesPerRecord)
        let middle = first.wallClock.addingTimeInterval(last.wallClock.timeIntervalSince(first.wallClock) / 2)
        var near: [(range: Double, hex: String, reports: [AircraftReport])] = []
        for (hex, history) in flights {
            let sorted = history.filter(FlightMatcher.isUsable).sorted { $0.positionTime < $1.positionTime }
            guard let named = sorted.first, let place = FlightMatcher.place(in: sorted, at: middle) else { continue }
            let there = SkyMath.direction(from: observer, toLatitude: place.latitude, longitude: place.longitude, altitudeMeters: place.altitudeMeters)
            guard there.rangeMeters <= maximumRange, there.direction.elevation > 0 else { continue }
            let reports = picked.compactMap { sample -> AircraftReport? in
                guard let at = FlightMatcher.place(in: sorted, at: sample.wallClock) else { return nil }
                return AircraftReport(hex: hex, callsign: named.callsign, latitude: at.latitude, longitude: at.longitude, altitudeMeters: at.altitudeMeters,
                                      altitudeFeet: named.altitudeFeet, positionTime: sample.wallClock, groundSpeedKnots: nil, trackDegrees: nil)
            }
            if !reports.isEmpty { near.append((there.rangeMeters, hex, reports)) }
        }
        guard !near.isEmpty else { return nil }
        let kept = near.sorted { ($0.range, $0.hex) < ($1.range, $1.hex) }.prefix(aircraftPerRecord)
        var thinned = track
        thinned.samples = picked
        thinned.misses = []
        return Record(track: thinned, analysisWidth: analysisWidth, pictureWidth: pictureWidth,
                      flights: Dictionary(kept.map { ($0.hex, $0.reports) }, uniquingKeysWith: { first, _ in first }), end: last.wallClock)
    }

    /// The cards of the grid around `card`, `card` itself among them, each once.
    static func cards(around card: Card) -> [Card] {
        var cards: [Card] = []
        for facing in facingSteps {
            for tilt in tiltSteps {
                let candidate = Card(facing: SkyMath.normalizedDegrees(card.facing + facing), tilt: min(90, max(0, card.tilt + tilt)))
                if !cards.contains(candidate) { cards.append(candidate) }
            }
        }
        return cards
    }

    /// The clear winner among the cards around `card` (not `card` itself), or nil. `layout`: the lenses the person set (nil: by the picture's
    /// shape); `pictureWidth`, `pictureHeight`: the camera's picture.
    static func search(_ records: [Record], from card: Card, layout: SkyCameraModel.LensLayout?, pictureWidth: Int, pictureHeight: Int,
                       observer: SkyObserver) -> Outcome? {
        guard !records.isEmpty else { return nil }
        let start = Card(facing: SkyMath.normalizedDegrees(card.facing), tilt: min(90, max(0, card.tilt)))
        var scored: [(card: Card, aircraft: Int, distance: Double)] = []
        for candidate in cards(around: start) {
            let model = SkyCameraModel.initial(facing: candidate.facing, tilt: candidate.tilt, pictureWidth: pictureWidth, pictureHeight: pictureHeight,
                                               layout: layout)
            var matched: [String: Double] = [:]
            for record in records {
                let measures = TrackMeasurer.measure(record.track, model: model, analysisWidth: record.analysisWidth, pictureWidth: record.pictureWidth)
                guard let match = FlightMatcher.match(record.track, measures: measures, model: model, aim: .rough, observer: observer,
                                                      flights: record.flights) else { continue }
                matched[match.hex] = min(matched[match.hex] ?? .infinity, match.score)
            }
            scored.append((candidate, matched.count, matched.values.reduce(0, +)))
        }
        let ranked = scored.sorted { $0.aircraft != $1.aircraft ? $0.aircraft > $1.aircraft : $0.distance < $1.distance }
        guard let best = ranked.first else { return nil }
        let runnerUp = scored.filter { !adjacent($0.card, best.card) }.map(\.aircraft).max() ?? 0
        guard best.aircraft >= minimumAircraft, best.aircraft >= clearFactor * runnerUp, best.card != start else { return nil }
        return Outcome(card: best.card, aircraft: best.aircraft, runnerUp: runnerUp)
    }

    /// Next to each other on the grid (one step or less each way).
    static func adjacent(_ a: Card, _ b: Card) -> Bool {
        abs(difference(a.facing, b.facing)) <= 15 + 1e-9 && abs(a.tilt - b.tilt) <= 10 + 1e-9
    }

    /// `a` less `b`, in −180…180 degrees.
    static func difference(_ a: Double, _ b: Double) -> Double {
        let turn = SkyMath.normalizedDegrees(a - b)
        return turn > 180 ? turn - 360 : turn
    }

    /// What the card shows once the search moved the start: how far the planes say the camera is from the card the person set.
    static func note(facing: Double, tilt: Double) -> String {
        let turn = Int(facing.rounded()), up = Int(tilt.rounded())
        var parts: [String] = []
        if turn != 0 { parts.append("facing about \(abs(turn))° further \(turn > 0 ? "right" : "left")") }
        if up != 0 { parts.append("tilted \(abs(up))° \(up > 0 ? "higher" : "lower")") }
        return "The planes fit the camera \(parts.joined(separator: " and ")) than set: it aims from there now."
    }

    /// At most `count` of `items`, evenly spread, the first and the last among them.
    static func evenly<T>(_ items: [T], _ count: Int) -> [T] {
        guard count >= 1 else { return [] }
        guard items.count > count else { return items }
        guard count >= 2 else { return [items[0]] }
        let last = Double(items.count - 1), steps = Double(count - 1)
        return (0..<count).map { items[Int((Double($0) * last / steps).rounded())] }
    }
}
