import Foundation

/// Which lights that nothing explains are worth an entry in the sky log, how many a camera logs, and which have pictures (Rulings S24 and S31).
///
/// Phase 1 logged every light the tracker kept, and about 2 to 3 a minute were not lights, mostly faint stars, each with a picture of its own.
/// Now:
/// - **A slow light is skipped**: no entry and no picture, only a count that the journal gets once an hour (`SkyCameraDetector`). A light is slow
///   when its mean speed along its path (`SkyMeasures.speed`: stars drift at about 0.004°/s, planes and satellites move at 0.1 to 1°/s) is under
///   `slowDegreesPerSecond` while the lens's aim is good or precise, and, while the aim is rough and degrees through a lens that is only guessed
///   are not to be trusted, when its speed is under `slowPixelsPerSecond` in analysed pixels (about the same speed to a camera that sees 180°
///   across 1920 pixels). It is asked only of a light that no flight explains: a plane is a plane whatever its speed. So are the lights at a
///   busy spot (`SkyClutterMap`) and those in the band along the edge nearest the Sun (`SkySunGuard`).
/// - **A camera logs at most `unexplainedPerHour` lights that nothing explains** in a clock hour (of the box's zone): the owner's camera logged
///   about 2,500 junk entries in one afternoon, which made the page unusable and the day's file (which the night after it shares) huge. The
///   later ones are counted, not logged, and one line of the log says how many for the hour (`SkyLogStore.recordCapped`). Since the rules
///   (`SkyRules`) the hour's count is of every light that no flight explains and that the rules leave unexplained or call a meteor, a bug or a
///   bird (`countsAgainstTheHour`); the rules' probable planes and satellites are logged whatever the hour holds, so that a busy hour of them
///   never takes the room of a light nothing explains.
/// - **Every light that is logged and wants a picture has one** (`wantsStill`, Ruling S31: what nothing explains, the rules' meteors, bugs and
///   birds, and since 2026-10-26 their probable planes and satellites and a satellite's flare, so that the owner can check the rules by eye; a
///   flight's planes and an orbit's named satellites have none). One the camera's ring could not give is made later from the recordings
///   (`SkyStillBackfill`). The hour's 200 bound the pictures of what nothing explains; the room rule and each camera's 2 GiB (below) bound
///   them all.
///
/// And the pictures must not fill the recordings drive (Ruling S27): recording pauses on every camera when the drive's free space falls
/// below its floor, and the size rule never counts what the sky log keeps. So a picture is taken only while the drive has its floor and
/// `stillRoomMargin` more free (`stillsHaveRoom`), and a camera's pictures stay under `stillBytesPerCamera`, the oldest nights' going first
/// (`SkyLogStore.pruneStills`, looked at every `stillPruneInterval`).
enum SkyLightFilter {
    /// A light that nothing explains and that crosses the sky slower than this (degrees a second) is skipped while the aim is good or precise.
    static let slowDegreesPerSecond = 0.05
    /// …slower than this (analysed pixels a second) while the aim is rough.
    static let slowPixelsPerSecond = 0.5
    /// A light that nothing explains and that never gets this far (analysed pixels) from where it was first seen is skipped too, whatever its
    /// speed (Ruling S28): a faint star or a wire whose centroid wanders a few pixels reads 0.2 to 0.3°/s along its path. Three times the
    /// measurer's noise floor. A light that turns back on itself counts by the farthest point it reached.
    static let minimumReachPixels = 3 * TrackMeasurer.noisePixels
    /// …unless it is bright (Ruling S29): a light whose strongest detection stands at least this many times the noise above the sky is kept
    /// however little it moved. The overnight test's strangest lights rose, held for seconds and faded on one spot; faint stars and wires never
    /// stand this far above the noise (and a bright star is on the slow background, which the tracker already drops).
    static let brightSignificance = 6.0
    /// A camera logs at most this many lights that count against the hour (`countsAgainstTheHour`) in a clock hour; the rest are counted.
    static let unexplainedPerHour = 200
    /// A camera's pictures stay under this many bytes on the recordings drive (their thumbnails, which the page's grid has made beside them, included).
    static let stillBytesPerCamera: UInt64 = 2 * 1_073_741_824
    /// A picture is taken only while the drive has its floor and at least this much more free (below the floor recording pauses). It was twice
    /// the floor (Ruling S27), which a full recorder almost never has: retention keeps it at about twice its floor free (Ruling S31).
    static let stillRoomMargin: UInt64 = 1_073_741_824
    /// A camera's folders of pictures are measured at most this often (seconds).
    static let stillPruneInterval: TimeInterval = 600

    /// Whether the recordings drive has room for a picture of the sky: measured, recording not paused, and its floor and `stillRoomMargin` more
    /// free, so that a picture can never take it down to the floor. A drive that has not been measured, or whose floor is not known, has none.
    static func stillsHaveRoom(_ storage: ArchiveStorageStatus?) -> Bool {
        guard let storage, storage.pause == nil, storage.floorBytes > 0 else { return false }
        let (needed, overflow) = storage.floorBytes.addingReportingOverflow(stillRoomMargin)
        return !overflow && storage.freeBytes >= needed
    }

    /// Whether an entry of this label, given by `source`, has a picture (Ruling S31): what nothing explains, what the rules say is a meteor, a bug or
    /// a bird, and (2026-10-26, so that the owner can check the rules by eye) their probable planes and satellites and a satellite's flare. A plane a
    /// flight explains (a probable one while the aim is rough) and a satellite an orbit names are explained by the feed's word on them: no picture.
    static func wantsStill(_ label: SkyLabel, by source: SkyLabelSource?) -> Bool {
        guard source != .flight else { return false }
        switch label {
        case .unexplained, .meteor, .bug, .bird, .probablePlane, .probableSatellite, .satelliteFlare: return true
        case .plane, .satellite: return false
        }
    }

    /// Whether a logged light counts against the hour's `unexplainedPerHour`: one that no flight explains and that the rules leave unexplained or
    /// call a meteor, a bug or a bird, as before their probable planes and satellites had pictures. Those are logged, with their pictures, whatever
    /// the hour holds: a busy hour of satellites never takes the room of a light nothing explains.
    static func countsAgainstTheHour(_ label: SkyLabel, by source: SkyLabelSource?) -> Bool {
        guard source != .flight else { return false }
        switch label {
        case .unexplained, .meteor, .bug, .bird: return true
        case .plane, .probablePlane, .satellite, .probableSatellite, .satelliteFlare: return false
        }
    }

    /// Whether a light that nothing explains moved too slowly to be logged: `measures.speed` (degrees a second along its path) while the aim is
    /// good or precise, `pixelsPerSecond` (`pixelSpeed`) while it is rough. A track that the model could not place in the sky at all (no
    /// duration in degrees) has no speed in degrees, and its pixels judge it.
    static func isSlow(_ measures: SkyMeasures, pixelsPerSecond: Double, aimIsGood: Bool) -> Bool {
        if aimIsGood, measures.duration > 0, measures.speed.isFinite { return measures.speed < slowDegreesPerSecond }
        return pixelsPerSecond < slowPixelsPerSecond
    }

    /// `track`'s mean speed along its path in analysed pixels a second (`analysisWidth` × `analysisHeight`), measured as `TrackMeasurer` measures
    /// it on the sky: the path runs between points at least `TrackMeasurer.noisePixels` apart (so that a centroid's wander by a fraction of a
    /// pixel adds no path) and ends at the last point, over the time the track was followed. 0 when there is no time to divide by.
    static func pixelSpeed(of track: SkyTrack, analysisWidth: Int, analysisHeight: Int) -> Double {
        let samples = track.samples.filter { $0.time.isFinite && $0.point.x.isFinite && $0.point.y.isFinite }.sorted { $0.time < $1.time }
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        let across = Double(max(1, analysisWidth)), down = Double(max(1, analysisHeight))
        func distance(_ a: PixelPoint, _ b: PixelPoint) -> Double { hypot((b.x - a.x) * across, (b.y - a.y) * down) }
        var path = 0.0, node = first.point
        for sample in samples.dropFirst() where distance(node, sample.point) >= TrackMeasurer.noisePixels {
            path += distance(node, sample.point)
            node = sample.point
        }
        path += distance(node, last.point)
        return path / (last.time - first.time)
    }

    /// How far `track` got from its first point, in analysed pixels (`analysisWidth` × `analysisHeight`): the farthest of its points.
    static func reach(of track: SkyTrack, analysisWidth: Int, analysisHeight: Int) -> Double {
        let samples = track.samples.filter { $0.time.isFinite && $0.point.x.isFinite && $0.point.y.isFinite }.sorted { $0.time < $1.time }
        guard let first = samples.first else { return 0 }
        let across = Double(max(1, analysisWidth)), down = Double(max(1, analysisHeight))
        return samples.reduce(0) { max($0, hypot(($1.point.x - first.point.x) * across, ($1.point.y - first.point.y) * down)) }
    }

    /// Whether `track` only wandered in place: it never got `minimumReachPixels` from its first point, and it was never bright
    /// (`brightSignificance`).
    static func wandersInPlace(_ track: SkyTrack, analysisWidth: Int, analysisHeight: Int) -> Bool {
        guard reach(of: track, analysisWidth: analysisWidth, analysisHeight: analysisHeight) < minimumReachPixels else { return false }
        let peak = track.samples.map(\.significance).filter(\.isFinite).max() ?? 0
        return peak < brightSignificance
    }

    /// When the clock hour that holds `date` began, in `zone` (a person's hour: it begins at :30 in a zone that is half an hour off).
    static func clockHour(of date: Date, in zone: TimeZone) -> Date {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return Date(timeIntervalSince1970: 0) }
        let offset = TimeInterval(zone.secondsFromGMT(for: date))
        return Date(timeIntervalSince1970: ((seconds + offset) / 3_600).rounded(.down) * 3_600 - offset)
    }
}

/// How many of something happened in each clock hour (`SkyLightFilter.clockHour`): the lights a camera logged, and those it skipped or did not
/// log, by why. Only the newest `kept` hours are remembered, so that a count nobody reads does not grow.
struct SkyHourCounts: Sendable, Equatable {
    static let kept = 8

    private var counts: [Date: Int] = [:]

    func count(in hour: Date) -> Int {
        counts[hour] ?? 0
    }

    /// No hour has anything counted.
    var isEmpty: Bool { counts.isEmpty }

    /// One more in `hour`; the count there now.
    @discardableResult
    mutating func add(in hour: Date) -> Int {
        let now = (counts[hour] ?? 0) + 1
        counts[hour] = now
        if counts.count > Self.kept {
            for old in counts.keys.sorted().prefix(counts.count - Self.kept) { counts[old] = nil }
        }
        return now
    }

    /// The hours before `hour` that have something counted, oldest first; they are forgotten once handed over.
    mutating func drain(before hour: Date) -> [(hour: Date, count: Int)] {
        let finished = counts.filter { $0.key < hour }.sorted { $0.key < $1.key }
        for (key, _) in finished { counts[key] = nil }
        return finished.map { (hour: $0.key, count: $0.value) }
    }
}
