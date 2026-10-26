import Foundation

/// The lights logged before the rules (`SkyRules`, 2026-10-26), sorted by them as a night's log is read (the owner's request of 2026-10-26: on his
/// box the night of Oct 25 was 1,533 lights, every one "unexplained", which the replay of the rules sorted into birds, probable planes and
/// satellites, bugs and meteors, and ranked what it left). A light is sorted when it is unexplained, nothing named it (`by` nil: the old pipeline's
/// word) and it has none of the guide's fields (`needsSorting`). It is judged as the detector judges a light now (`SkyRules.judge`: the rules, the
/// camera's baseline as it is now, or the defaults before it learned, and the guide), shown so, and marked `SkyEntry.sortedLater`; the lights that
/// moved together are found afterwards on the whole view (`SkyFormations`), the sorted ones among them. Nothing is written: the log stays
/// append-only, and the next read sorts again, with what the camera has learned by then. A person's word wins as ever (`SkyDisplay`).
///
/// What the rules need of a light that its entry does not keep comes from the night and from its path, as the replay of the rules took it:
/// - **how it began** (`Beginnings`): from the start times of every light of the night's log, how many began in its picture (the same start),
///   how many within a second of it, and whether a picture from 1 s before it to 10 s after saw 5 or more begin (`SkyTracker.beganWith`). The
///   tracker counts every track it starts, the ones it drops too, so these doubts are fewer than the live ones;
/// - **the Sun's height** at its middle, and whether a satellite could be in sunlight where it was (the box's place, which never leaves the box);
/// - **its way across the picture** (straight down: a bug on silk) from its path's first and last points in the camera's picture
///   (`Camera.picture`); none while the picture's size is not known;
/// - **the measures an older build did not keep** (`SkyMeasures.wobble`, `turns`, `strobePeriod`, `strobeStrength`, `seenShare`): from its path
///   through the camera's aim now (`Camera.model`), as `TrackMeasurer` measures them (`TrackMeasurer.pathMeasures`): the wobble and the turns from
///   any path; the strobe and the share of its pictures it was seen in only from a whole path (fewer than 64 points: one for each picture it was
///   seen in), the pictures it was missed in found in the gaps between them at the pictures' pace (`Camera.picturesPerSecond`), every point at one
///   brightness; never from a path thinned to 64 points. Without an aim none is measured again, and the rules take them as absent (a smooth light,
///   seen all along, no strobe). They decide the rules only: the entry keeps the measures it was logged with;
/// - it is taken as not streak-born, seen in as many pictures as its path has points (the rules ask for three), and stepping its speed over the
///   pictures' pace from one picture to the next.
///
/// No picture or file is read for it: a night of 2,000 old lights is sorted and grouped in about 25 ms of a release build on a Mac, and read whole by
/// the engine in about 0.11 s against 0.09 s for the same night logged with the rules (`SkySortLaterTests`).
struct SkySortLater: Sendable {
    /// What is known of the camera: its aim now (nil: none), the width its pictures are analysed at, its picture's size (nil: not known), what it
    /// learned of its sky (the defaults before it learned), and how many pictures a second it looks at.
    struct Camera: Sendable {
        var model: SkyCameraModel?
        var analysisWidth: Int
        var picture: SkyPictureSize?
        var baseline: SkyBaseline
        var picturesPerSecond: Double = SkyStreamChoice.analysisRate
    }

    /// How a light began: how many lights began in its picture and within `SkyRules.meteorAloneWithin` of it (each counting itself), and whether
    /// the camera changed its picture around then (`SkyRules.cameraChangeLights` beginning in one picture, `SkyRules.cameraChangeWindow` around it).
    struct Began: Sendable, Equatable {
        var count: Int
        var near: Int
        var cameraChange: Bool
    }

    /// The start times of a night's lights, for how each began.
    struct Beginnings: Sendable {
        /// Seconds since 1970, in order; and the ones at which `SkyRules.cameraChangeLights` or more began.
        private let starts: [TimeInterval]
        private let changes: [TimeInterval]

        init(_ dates: [Date]) {
            let starts = dates.map(\.timeIntervalSince1970).filter(\.isFinite).sorted()
            var changes: [TimeInterval] = []
            var index = 0
            while index < starts.count {
                var end = index
                while end + 1 < starts.count, starts[end + 1] == starts[index] { end += 1 }
                if end - index + 1 >= SkyRules.cameraChangeLights { changes.append(starts[index]) }
                index = end + 1
            }
            self.starts = starts
            self.changes = changes
        }

        /// How the light that began at `start` began (a light the night does not hold counts itself all the same).
        func began(at start: Date) -> Began {
            let time = start.timeIntervalSince1970
            guard time.isFinite else { return Began(count: 1, near: 1, cameraChange: false) }
            let count = max(1, Self.count(starts, from: time, to: time))
            let near = max(count, Self.count(starts, from: time - SkyRules.meteorAloneWithin, to: time + SkyRules.meteorAloneWithin))
            let window = SkyRules.cameraChangeWindow
            return Began(count: count, near: near, cameraChange: Self.count(changes, from: time - window.upperBound, to: time - window.lowerBound) > 0)
        }

        /// How many of `sorted` lie in `from...to`.
        private static func count(_ sorted: [TimeInterval], from: TimeInterval, to: TimeInterval) -> Int {
            guard from <= to else { return 0 }
            return index(sorted) { $0 > to } - index(sorted) { $0 >= from }
        }

        /// The first index of `sorted` where `isPast` holds (it holds from there on), or its count.
        private static func index(_ sorted: [TimeInterval], where isPast: (TimeInterval) -> Bool) -> Int {
            var low = 0, high = sorted.count
            while low < high {
                let middle = (low + high) / 2
                if isPast(sorted[middle]) { high = middle } else { low = middle + 1 }
            }
            return low
        }
    }

    /// In a gap between two points of a whole path, at most this many pictures are taken as missed (the tracker coasts for 1.5 s).
    static let mostMissesInAGap = 64
    private static let trackID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    var observer: SkyObserver
    var camera: Camera

    /// Whether `entry` is a light the rules have not judged: unexplained, named by nothing (an older build's word), with none of the guide's fields.
    static func needsSorting(_ entry: SkyEntry) -> Bool {
        entry.label == .unexplained && entry.by == nil && entry.priority == nil && entry.reasons.isEmpty && !entry.doubtful
    }

    /// `entries`, in their order, with each one that `needsSorting` judged by the rules and the guide and marked `sortedLater`; the others as they
    /// were. `night`: every light of the log they were read from (how each began).
    func sort(_ entries: [SkyEntry], night: [SkyEntry]) -> [SkyEntry] {
        guard entries.contains(where: Self.needsSorting) else { return entries }
        let beginnings = Beginnings(night.map(\.start))
        return entries.map { entry in
            guard Self.needsSorting(entry) else { return entry }
            var sorted = entry
            SkyRules.judge(&sorted, light: light(of: entry, began: beginnings.began(at: entry.start)), baseline: camera.baseline)
            sorted.sortedLater = true
            return sorted
        }
    }

    /// What the rules know of a logged light (see the type's notes).
    func light(of entry: SkyEntry, began: Began) -> SkyRuleLight {
        let missed = misses(of: entry.path)
        let measures = measured(entry, misses: missed)
        let middle = SkyStillBackfill.middle(of: entry)
        var light = SkyRuleLight(measures: measures, kind: entry.kind, streakBorn: false, samples: entry.path.count,
                                 sunElevation: SunEphemeris.direction(at: middle, observer: observer).elevation)
        light.beganWith = began.count
        light.beganNear = began.near
        light.afterCameraChange = began.cameraChange
        if let picture = camera.picture, let first = entry.path.first, let last = entry.path.last {
            let across = (last.x - first.x) * Double(picture.width), down = (last.y - first.y) * Double(picture.height)
            if across.isFinite, down.isFinite, hypot(across, down) > 0 { light.fromStraightDown = atan2(abs(across), down) * SkyMath.degrees }
        }
        if let first = entry.path.first?.t, let last = entry.path.last?.t, last > first, last.isFinite, first.isFinite {
            let span = last - first
            let pictures = missed.map { Double(entry.path.count + $0.count) } ?? span / pace + 1
            if pictures > 1 { light.degreesPerPicture = measures.speed * span / (pictures - 1) }
        }
        light.satelliteSunlit = SkyRules.satelliteCouldBeSunlit(SkyRules.halfway(measures), at: middle, observer: observer)
        return light
    }

    /// The measures the rules take of `entry`: as logged, with the ones an older build did not keep measured again from its path through the aim
    /// (see the type's notes); as logged when no aim is known or the path gives nothing.
    func measured(_ entry: SkyEntry) -> SkyMeasures {
        measured(entry, misses: misses(of: entry.path))
    }

    private func measured(_ entry: SkyEntry, misses: [TimeInterval]?) -> SkyMeasures {
        var measures = entry.measures
        guard let model = camera.model, entry.path.count >= 2,
              measures.wobble == nil || measures.turns == nil || measures.seenShare == nil || measures.strobeStrength == nil else { return measures }
        let samples = entry.path.compactMap { point -> SkyTrackSample? in
            guard point.t.isFinite, point.x.isFinite, point.y.isFinite else { return nil }
            let at = PixelPoint(x: point.x, y: point.y)
            return SkyTrackSample(time: point.t, wallClock: entry.start.addingTimeInterval(point.t), point: at, area: 1, flux: 1, sharpness: 0.5,
                                  elongation: 1, lens: model.lens(at: at))
        }
        let track = SkyTrack(id: Self.trackID, samples: samples, streakBorn: false, misses: misses ?? [])
        guard let path = TrackMeasurer.pathMeasures(track, model: model, analysisWidth: camera.analysisWidth, pictures: misses != nil) else { return measures }
        if measures.wobble == nil { measures.wobble = path.wobble }
        if measures.turns == nil { measures.turns = path.turns }
        if misses != nil {   // a whole path: which pictures it was missed in is known
            if measures.strobePeriod == nil && measures.strobeStrength == nil {
                measures.strobePeriod = path.strobePeriod
                measures.strobeStrength = path.strobeStrength
            }
            if measures.seenShare == nil { measures.seenShare = path.seenShare }
        }
        return measures
    }

    /// The pictures' pace (s), from how many a second the camera looks at.
    private var pace: TimeInterval {
        let rate = camera.picturesPerSecond
        return 1 / (rate.isFinite && rate > 0 ? rate : SkyStreamChoice.analysisRate)
    }

    /// The times a whole path was missed in: in each gap between two of its points, the gap's whole number of the pictures' pace less one, evenly
    /// spread (at most `mostMissesInAGap`). Nil for a path thinned to 64 points, which keeps no account of its pictures, or one of fewer than two.
    func misses(of path: [SkyPathPoint]) -> [TimeInterval]? {
        guard path.count >= 2, path.count < SkyPathPoint.maximumPerEntry else { return nil }
        let pace = pace
        var misses: [TimeInterval] = []
        for (a, b) in zip(path, path.dropFirst()) where a.t.isFinite && b.t.isFinite && b.t > a.t {
            let gap = b.t - a.t
            let count = min(Int((gap / pace).rounded()) - 1, Self.mostMissesInAGap)
            guard count > 0 else { continue }
            for k in 1...count { misses.append(a.t + gap * Double(k) / Double(count + 1)) }
        }
        return misses
    }
}
