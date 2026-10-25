import Foundation

/// Which lights that nothing explains are worth an entry in the sky log, and how many pictures of them a camera keeps (Ruling S24).
///
/// Phase 1 logged every light the tracker kept, and about 2 to 3 a minute were not lights, mostly faint stars, each with a picture of its own.
/// Now:
/// - **A slow light is skipped**: no entry and no picture, only a count that the journal gets once an hour (`SkyCameraDetector`). A light is slow
///   when its mean speed along its path (`SkyMeasures.speed`: stars drift at about 0.004°/s, planes and satellites move at 0.1 to 1°/s) is under
///   `slowDegreesPerSecond` while the lens's aim is good or precise, and, while the aim is rough and degrees through a lens that is only guessed
///   are not to be trusted, when its speed is under `slowPixelsPerSecond` in analysed pixels (about the same speed to a camera that sees 180°
///   across 1920 pixels). It is asked only of a light that no flight explains: a plane is a plane whatever its speed.
/// - **A camera keeps at most `stillsPerHour` pictures** in a clock hour (of the box's zone); a later light that nothing explains is logged
///   without one.
///
/// And the pictures must not fill the recordings drive (Ruling S27): recording pauses on every camera when the drive's free space falls
/// below its floor, and the size rule never counts what the sky log keeps. So a picture is taken only while the drive has `stillRoomFactor`
/// times its floor free (`stillsHaveRoom`), and a camera's pictures stay under `stillBytesPerCamera`, the oldest nights' going first
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
    /// A camera keeps at most this many pictures of unexplained lights in a clock hour.
    static let stillsPerHour = 30
    /// A camera's pictures stay under this many bytes on the recordings drive.
    static let stillBytesPerCamera: UInt64 = 2 * 1_073_741_824
    /// A picture is taken only while the drive has at least this many times its floor free (below the floor recording pauses).
    static let stillRoomFactor: UInt64 = 2
    /// A camera's folders of pictures are measured at most this often (seconds).
    static let stillPruneInterval: TimeInterval = 600

    /// Whether the recordings drive has room for a picture of the sky: measured, recording not paused, and at least `stillRoomFactor` times
    /// its floor free. A drive that has not been measured, or whose floor is not known, has none.
    static func stillsHaveRoom(_ storage: ArchiveStorageStatus?) -> Bool {
        guard let storage, storage.pause == nil, storage.floorBytes > 0 else { return false }
        let (needed, overflow) = storage.floorBytes.multipliedReportingOverflow(by: stillRoomFactor)
        return !overflow && storage.freeBytes >= needed
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

    /// When the clock hour that holds `date` began, in `zone` (a person's hour: it begins at :30 in a zone that is half an hour off).
    static func clockHour(of date: Date, in zone: TimeZone) -> Date {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return Date(timeIntervalSince1970: 0) }
        let offset = TimeInterval(zone.secondsFromGMT(for: date))
        return Date(timeIntervalSince1970: ((seconds + offset) / 3_600).rounded(.down) * 3_600 - offset)
    }
}

/// How many of something happened in each clock hour (`SkyLightFilter.clockHour`): the pictures a camera asked for, the slow lights it skipped.
/// Only the newest `kept` hours are remembered, so that a count nobody reads does not grow.
struct SkyHourCounts: Sendable, Equatable {
    static let kept = 8

    private var counts: [Date: Int] = [:]

    func count(in hour: Date) -> Int {
        counts[hour] ?? 0
    }

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
