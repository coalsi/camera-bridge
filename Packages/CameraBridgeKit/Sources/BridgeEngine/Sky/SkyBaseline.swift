import Foundation

/// What one camera has learned of its sky (the plan's Task 11): the speeds, sizes and brightnesses of the planes and satellites it matched (by a
/// flight, later by an orbit; never the rules' probable ones), the last `keptPerBand` of each kind in each band of elevation. "Unusual" is
/// measured against them: an unexplained light that crosses faster, looks larger or brighter than they do at its height, or stops or turns in a
/// way they never do. Before the camera has learned (`SkyLearning.planesNeeded` planes), the plan's defaults stand in for them ("typical
/// planes"). Kept per camera in `baseline.json` (`SkyCameraDetector`). The plan had it forgotten with the aim when the camera seems to have
/// moved; Ruling S25 keeps what the box learned of the sky through a new card or an aim started again (it is not the aim), and so does this.
///
/// **Pinned:**
/// - bands of the light's elevation (at its middle): 0–10°, 10–30°, 30–60°, 60–90°; a band with fewer than 10 samples of a kind is judged by
///   all the bands together;
/// - `faster`: over 1.5 × the larger of the planes' and the satellites' 95th-percentile speeds; `larger`: over 1.5 × the planes' 95th-percentile
///   size; `brighter`: over 1.5 × the 95th-percentile brightness of planes and satellites together;
/// - before learning: a 95th-percentile speed of 2°/s and no `brighter`;
/// - `speedVsPlanes`: the speed over the median plane speed in its band; nil with fewer than 10 planes anywhere;
/// - learning is ready with 30 planes, and 10 satellites too once orbits are loaded.
///
/// **Changed by the owner's nights** (the report says why): before learning, a 95th-percentile size of 0.75°, not 0.3°: the planes the rules
/// found on the owner's camera on the night of Oct 25 measure 0.28° across at the median and 0.76° at the 95th percentile (a bright light
/// spreads), and at 0.3° one plane in five would have been "larger".
///
/// **The builder's (the owner's nights):** `suddenStop` and `sharpTurn` come from the shape only when it can be trusted: the light crossed 1°/s
/// or more for 2 s or more, turned by 45° at most twice, and kept within 0.2° of a smooth path. On the owner's camera nearly every "stop" and
/// "turn" was the wander of a faint, slow or ragged track, or a piece of a passing light whose last second settled on the noise as it faded.
struct SkyBaseline: Codable, Sendable, Equatable {
    static let bands: [ClosedRange<Double>] = [0...10, 10...30, 30...60, 60...90]
    static let keptPerBand = 500
    static let fewestPerBand = 10
    static let unusualShare = 1.5
    static let defaultSpeed95 = 2.0
    static let defaultSize95 = 0.75
    static let fewestForRatio = 10
    /// A shape is trusted from this speed (°/s) and duration (s), with at most this many turns of 45° and within this many degrees of a smooth
    /// path.
    static let shapeSpeed = 1.0
    static let shapeDuration: TimeInterval = 2
    static let shapeTurns = 2
    static let shapeWobble = 0.2

    /// What is kept of a matched light.
    struct Sample: Codable, Sendable, Equatable {
        var speed: Double
        var size: Double
        var brightness: Double
    }

    var v = 1
    /// Per band, oldest first.
    private(set) var planes: [[Sample]] = Array(repeating: [], count: SkyBaseline.bands.count)
    private(set) var satellites: [[Sample]] = Array(repeating: [], count: SkyBaseline.bands.count)

    init() {}

    /// A file of a later or broken shape reads as nothing learned.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let count = Self.bands.count
        func read(_ key: CodingKeys) -> [[Sample]] {
            let bands = ((try? container.decode([[Sample]].self, forKey: key)) ?? []).prefix(count).map { band in
                Array(band.filter { $0.speed.isFinite && $0.size.isFinite && $0.brightness.isFinite }.suffix(Self.keptPerBand))
            }
            return bands + Array(repeating: [], count: count - bands.count)
        }
        planes = read(.planes)
        satellites = read(.satellites)
    }

    /// Learns a matched plane or satellite (`.plane`, `.satellite`); any other label (the rules' probable ones among them) teaches nothing.
    mutating func learn(_ m: SkyMeasures, label: SkyLabel) {
        guard label == .plane || label == .satellite, m.speed.isFinite, m.sizeDegrees.isFinite, m.brightness.isFinite else { return }
        let band = Self.band(of: m)
        let sample = Sample(speed: m.speed, size: m.sizeDegrees, brightness: m.brightness)
        if label == .plane {
            planes[band].append(sample)
            if planes[band].count > Self.keptPerBand { planes[band].removeFirst(planes[band].count - Self.keptPerBand) }
        } else {
            satellites[band].append(sample)
            if satellites[band].count > Self.keptPerBand { satellites[band].removeFirst(satellites[band].count - Self.keptPerBand) }
        }
    }

    var planeCount: Int { planes.reduce(0) { $0 + $1.count } }
    var satelliteCount: Int { satellites.reduce(0) { $0 + $1.count } }

    /// Whether the comparisons are against what this camera learned (enough planes), not the defaults.
    var isLearned: Bool { planeCount >= SkyLearning.planesNeeded }

    /// Ready once enough planes, and (when orbits are loaded) enough satellites, were matched.
    func learning(orbitsLoaded: Bool) -> SkyLearning {
        let planes = planeCount, satellites = satelliteCount
        let ready = planes >= SkyLearning.planesNeeded && (!orbitsLoaded || satellites >= SkyLearning.satellitesNeeded)
        return SkyLearning(ready: ready, planes: planes, satellites: satellites)
    }

    /// How `m` is unusual against the planes and satellites at its height (the defaults before learning). The shape's reasons only when the
    /// shape can be trusted (`shapeIsTrusted`).
    func unusual(_ m: SkyMeasures) -> [SkyUnusualReason] {
        var reasons: [SkyUnusualReason] = []
        let band = Self.band(of: m)
        let speed95: Double, size95: Double, brightness95: Double?
        if isLearned {
            let planeSpeeds = values(planes, band: band, \.speed), satelliteSpeeds = values(satellites, band: band, \.speed)
            speed95 = max(Self.percentile95(planeSpeeds) ?? 0, Self.percentile95(satelliteSpeeds) ?? 0)
            size95 = Self.percentile95(values(planes, band: band, \.size)) ?? Self.defaultSize95
            brightness95 = Self.percentile95(values(planes, band: band, \.brightness) + values(satellites, band: band, \.brightness))
        } else {
            speed95 = Self.defaultSpeed95
            size95 = Self.defaultSize95
            brightness95 = nil
        }
        if m.speed > Self.unusualShare * speed95 { reasons.append(.faster) }
        if m.sizeDegrees > Self.unusualShare * size95 { reasons.append(.larger) }
        if let brightness95, m.brightness > Self.unusualShare * brightness95 { reasons.append(.brighter) }
        if Self.shapeIsTrusted(m) {
            if m.shape == .suddenStop { reasons.append(.suddenStop) }
            if m.shape == .sharpTurn { reasons.append(.sharpTurn) }
        }
        return reasons
    }

    /// How many times faster across the sky than the median plane at its height (all heights when its band has few); nil with fewer than
    /// `fewestForRatio` planes anywhere.
    func speedVsPlanes(_ m: SkyMeasures) -> Double? {
        guard planeCount >= Self.fewestForRatio, m.speed.isFinite else { return nil }
        let speeds = values(planes, band: Self.band(of: m), \.speed).sorted()
        guard !speeds.isEmpty else { return nil }
        let median = speeds.count % 2 == 1 ? speeds[speeds.count / 2] : (speeds[speeds.count / 2 - 1] + speeds[speeds.count / 2]) / 2
        return median > 0 ? m.speed / median : nil
    }

    /// Whether a path's stop or turn is the light's and not its track's wander: fast and long enough, few turns, a smooth path.
    static func shapeIsTrusted(_ m: SkyMeasures) -> Bool {
        m.speed >= shapeSpeed && m.duration >= shapeDuration && (m.turns ?? 0) <= shapeTurns && (m.wobble ?? 0) <= shapeWobble
    }

    /// The band of a light's elevation at its middle (the first that holds it; under the horizon is the lowest).
    static func band(of m: SkyMeasures) -> Int {
        let middle = (m.elevation + m.elevationEnd) / 2
        let elevation = middle.isFinite ? min(90, max(0, middle)) : 0
        return bands.firstIndex { $0.contains(elevation) } ?? 0
    }

    /// The values of one kind in a band, or in all bands when the band has fewer than `fewestPerBand`.
    private func values(_ kind: [[Sample]], band: Int, _ value: KeyPath<Sample, Double>) -> [Double] {
        let own = kind[band]
        return (own.count >= Self.fewestPerBand ? own : kind.flatMap { $0 }).map { $0[keyPath: value] }
    }

    /// The 95th percentile (nearest rank); nil for none.
    static func percentile95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }
}
