import Foundation

/// One picture of a track: where the light was (in the camera's original picture's 0…1, through the lens it was seen in) and what it
/// looked like.
struct SkyTrackSample: Codable, Sendable, Equatable {
    /// The picture's time on the stream's clock (seconds), and its wall clock.
    var time: TimeInterval
    var wallClock: Date
    var point: PixelPoint
    /// The detection's pixels, flux and sharpness (`SkyDetection`), in the analysed picture.
    var area: Int
    var flux: Double
    var sharpness: Double
    var elongation: Double
    /// The lens it was seen through (0, or 1 for a dual camera's right half): its direction is `SkyCameraModel.direction(at:lens:)`.
    var lens: Int = 0
    /// In the seam's low-trust band: not to be used for aiming.
    var inSeamBand: Bool = false
    /// The detection's significance (`SkyDetection.significance`). The tracker keeps no track whose samples all stay under 1.5
    /// (`SkyTracker.faintSignificance`); one whose samples are all lone sharp pixels (`sharpness` 0.9 or more: sensor speckle) may still be
    /// noise that lined up by chance.
    var significance: Double = 1
    /// What stood still in the sky by the detection (`SkyDetection.fixedRise`, `.fixedRiseUnder`: σ of its tile's slow background).
    var fixedRise: Double = 0
    var fixedRiseUnder: Double = 0

    private enum CodingKeys: String, CodingKey {
        case time, wallClock, point, area, flux, sharpness, elongation, lens, inSeamBand, significance, fixedRise, fixedRiseUnder
    }

    init(time: TimeInterval, wallClock: Date, point: PixelPoint, area: Int, flux: Double, sharpness: Double, elongation: Double, lens: Int = 0,
         inSeamBand: Bool = false, significance: Double = 1, fixedRise: Double = 0, fixedRiseUnder: Double = 0) {
        self.time = time
        self.wallClock = wallClock
        self.point = point
        self.area = area
        self.flux = flux
        self.sharpness = sharpness
        self.elongation = elongation
        self.lens = lens
        self.inSeamBand = inSeamBand
        self.significance = significance
        self.fixedRise = fixedRise
        self.fixedRiseUnder = fixedRiseUnder
    }

    /// A sample saved without a lens is the first lens's, outside the band, of significance 1, clear of anything fixed.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(time: try values.decode(TimeInterval.self, forKey: .time), wallClock: try values.decode(Date.self, forKey: .wallClock),
                  point: try values.decode(PixelPoint.self, forKey: .point), area: try values.decode(Int.self, forKey: .area),
                  flux: try values.decode(Double.self, forKey: .flux), sharpness: try values.decode(Double.self, forKey: .sharpness),
                  elongation: try values.decode(Double.self, forKey: .elongation),
                  lens: try values.decodeIfPresent(Int.self, forKey: .lens) ?? 0,
                  inSeamBand: try values.decodeIfPresent(Bool.self, forKey: .inSeamBand) ?? false,
                  significance: try values.decodeIfPresent(Double.self, forKey: .significance) ?? 1,
                  fixedRise: try values.decodeIfPresent(Double.self, forKey: .fixedRise) ?? 0,
                  fixedRiseUnder: try values.decodeIfPresent(Double.self, forKey: .fixedRiseUnder) ?? 0)
    }
}

/// A light followed across pictures.
struct SkyTrack: Sendable, Identifiable {
    var id: UUID
    /// One per picture it was seen in, in time order.
    var samples: [SkyTrackSample]
    /// Born from two streaks along their own path (a meteor), not from three dots.
    var streakBorn: Bool
    /// The pictures (their times) in which it was open but not seen, between its first and last samples: a blinking light's dark ones.
    var misses: [TimeInterval] = []
    /// Brighter than the sky (always at night); false: darker (a bird by day).
    var brighter: Bool = true
    /// How often it was followed from one lens of a dual camera to the other.
    var seamJoins: Int = 0
    /// One of those joins was made by the picture alone, before the aim was good: the two halves' parts may be two lights.
    var uncertainSeamJoin: Bool = false
}

/// A track that ended and was dropped, with why: **not a logged light**, and handed over apart from the kept tracks
/// (`SkyTracker.update(_:at:wallClock:dropped:)`, `endAll(dropped:)`), so that nothing downstream can mistake it for one. The tracker keeps
/// the log to lights that travel and are more than faint, and drops what the later parts still read: **Tasks 9 and 10 read the flashes and
/// the stationary points from this channel.** A flash is a `barelyMoved` track that is streak-born or lasted under 1.5 s (Task 10 takes
/// those whose displacement is at most 3 px; Task 9 labels one at a satellite's predicted point a flare); a stationary point is a
/// `barelyMoved` track that lasted longer (Task 10's new stationary lights); a `fixed` track is a star's, a wire's or a lamp's flicker,
/// which they use to tell what is known. A track under 0.6 s that was not streak-born is dropped silently (the pinned minimum), and so is
/// noise (`allFaint`): neither is handed over.
struct SkyDroppedTrack: Sendable {
    /// Why it was dropped, the first of these that holds: every sample under significance 1.5 (`allFaint`: noise lined up by chance, never
    /// handed over); every sample by something fixed in the sky (`fixed`, `SkyTracker.onSomethingFixed`); no sample 4 analysed pixels (once the
    /// aim is not rough, and 0.05° on the sky) from the first (`barelyMoved`, `SkyTracker.moved`).
    enum DropReason: Sendable {
        case barelyMoved, allFaint, fixed
    }

    var track: SkyTrack
    var reason: DropReason
}

/// Follows the lights of each analysed picture from one to the next: a nearest-neighbour tracker with alpha-beta (constant-velocity)
/// prediction, in pixels of the analysed picture, each track in the lens it was seen in. Owned by one detector actor: not `Sendable`.
///
/// **Pinned:**
/// - prediction: alpha-beta, α 0.85, β 0.005 (the velocity in pixels a second);
/// - the gate: max(6 px, 0.6 × the predicted displacement since the track was last seen);
/// - a track is born after 3 detections in consecutive analysed pictures, or after 2 when both are elongated (3:1 or more) and lie along
///   their displacement (±15°): `streakBorn` (a meteor);
/// - it coasts up to 1.5 s (detections at most 1.5 s apart continue it), and is split at 10 minutes;
/// - a track that ends after less than 0.6 s is dropped, unless it was streak-born; at most 50 are open.
///
/// **What a track must show** (the coordinator's, fix round 2; whatever it lasted, streak-born too): an ended track is dropped when it
/// barely moved, none of its samples getting 4 px (of the analysed picture) or, once the aim is not rough, 0.05° on the sky from its first
/// (fix round 4: the farthest sample decides, not the last, so a loop or a path out and back that went far is kept); when every sample is
/// faint (significance under 1.5); and (fix round 3) when it sat on something fixed all along (`onSomethingFixed`: where the slow
/// background holds a star, a wire or a lamp). On the owner's camera nine tracks in ten were motionless faint flicker (twinkling stars, a
/// noisy edge), which the first drops; a light that stops counts (it moved first), and a satellite or plane moves far more. A star's track
/// that wanders onto the noise beside it, or flicker along a wire, moves but stays on the fixed thing, which the last drops; a plane
/// crossing a star is clear of it before and after, and a light passing beside a wire is beside it, not on it.
///
/// **What it drops is handed over** (fix round 4): a track dropped for barely moving or for sitting on something fixed is reported apart
/// from the kept ones, as a `SkyDroppedTrack` with its reason (`update(_:at:wallClock:dropped:)`, `endAll(dropped:)`): the flashes and
/// stationary points that Tasks 9 and 10 read are there, and nothing downstream can take one for a logged light.
///
/// **A dual camera's seam:** a track that crosses it is joined from one half to the other through the two lenses' sky directions, within
/// 3° (plus its gate in degrees) once the aim is good, since each half's radial terms bow its seam column its own way; before the aim is
/// good, by the picture alone with a wider gate (twice the gate and the seam band's width), and the join is marked uncertain. A track's
/// first two detections in different lenses are judged the same way (within 3° and the pairing reach in degrees; by the picture,
/// uncertain, before), and its velocity is then measured in one lens's pixels (the first detection's direction seen through the second's
/// lens). A light on the seam is cut into a piece in each lens (`SkyDetection.seamGroup`): a track takes the piece in its own lens when
/// there is one, the other pieces go with it, and a cut blob starts one tentative track, not one per piece.
///
/// **The builder's additions:**
/// - **A light no noise makes** (`isStrong`): `significance` 2 or more, and not a lone sharp pixel (`sharpness` under 0.9). The sky's
///   Gaussian noise stays under about 1.4, but a camera's single-pixel sensor speckle can stand far over the threshold (its spikes are
///   tens of levels): it is one pixel against the sky around it (sharpness about 1), where a light seen through a lens spreads onto its
///   neighbours (a dot's is about 0.6). Taken as strong, speckle on 2 pixels in 10,000 of a 1920×852 picture made about 400 tracks in two
///   minutes; not taken so, 2.
/// - **A turn or a stop.** A track seen in the previous picture, with at least 5 samples, that finds nothing in its gate takes the nearest
///   unclaimed detection of its lens and kind, a strong one about as bright (a third to three times its recent flux), within one
///   predicted step and a gate of where it was last seen, and its velocity is measured afresh from there. The pinned gate is centred on a
///   constant-velocity prediction, so a light that stops dead or turns sharply always falls outside it (by its whole step against 0.6 of
///   it), and the track would end at the very moment the detector most wants measured; with β 0.005 the velocity also follows a path's
///   slow bends very slowly. A detection in the pinned gate turns a track's heading by at most about 31° (0.6 of a step to the side), one
///   taken here by any angle: so only a strong light is taken, and a faint light that turns or stops ends its track and starts a new one.
/// - **Starting a track among noise.** A light's second detection is looked for within 5 % of the picture's width of its first (a quarter
///   of the width for a streak). When either of the two is not strong, the reach is cut to where a chance partner is unlikely: the radius
///   at which one of this picture's detections would turn up by chance once in a hundred, but at least the 6 px gate. The third detection's
///   gate is 0.6 of the first two's step, so a long reach among noise would let three chance detections line up; and the third is about as
///   bright as the first two (a third to three times their mean flux), as a turn's is. With faint chance detections over 1920×852 for an
///   hour, the cut reach leaves 1–2 tracks at 15 a picture, 5–8 at 50 and 24–32 at 100 (the pinned 6 px gate and its growth while a track
///   coasts let those through); a wide reach for all makes about 1,300 at 15 and 45,000 at 100.
/// - **The picture's time.** A picture with the same time as the last is ignored (handed over twice); one with an earlier time (the
///   stream's clock started again) ends everything first.
final class SkyTracker {
    // MARK: Pinned values

    static let alpha = 0.85
    static let beta = 0.005
    static let minimumGate = 6.0
    static let gateShare = 0.6
    static let streakElongation = 3.0
    static let streakAlignment = 15.0
    static let coast: TimeInterval = 1.5
    static let splitAfter: TimeInterval = 600
    static let minimumDuration: TimeInterval = 0.6
    static let maximumOpen = 50
    /// Across a dual camera's seam, once the aim is good.
    static let seamToleranceDegrees = 3.0
    /// An ended track has a sample at least this far from its first (analysed pixels; on the sky once the aim is not rough)…
    static let minimumMovePixels = 4.0
    static let minimumMoveDegrees = 0.05
    /// …and one of its samples at least this significant (`SkyDetection.significance`)…
    static let faintSignificance = 1.5
    /// …and it is no track on something fixed (`onSomethingFixed`): a spot standing this many σ within 10 px of every sample, and (for a
    /// track that travelled `travelPixels` or more, faster than a stationary light) within 3 px of this share of them.
    static let fixedSigmas = 5.0
    static let fixedShare = 0.5
    static let travelPixels = Double(SkyFrameAnalyzer.anchorRadius)
    /// The scale a track's travel is judged at without a model (about the box's 1920-px analysis of a 180° camera).
    static let nominalDegreesPerPixel = 0.1

    // MARK: Builder's values

    /// Before the aim is good, the seam's gate is this many times the track's, and the seam band's width.
    static let seamGateFactor = 2.0
    /// Joins across the seam are looked for within this part of the width of it.
    static let seamReachShare = 0.1
    /// A second detection is looked for within this part of the width of the first (a quarter for a streak).
    static let pairingShare = 0.05
    static let streakPairingShare = 0.25
    /// A detection this significant (`SkyDetection.significance`), and not a lone sharp pixel, is no chance noise (`isStrong`)…
    static let strongSignificance = 2.0
    /// …a lone sharp pixel being one whose peak stands this much of itself above its four neighbours (`SkyDetection.sharpness`).
    static let loneSharpness = 0.9
    /// A faint pair's reach: where a chance partner turns up once in this many.
    static let chancePartners = 0.01
    /// A detection is about as bright as a track within this factor of its flux: a turn or stop's of the track's last 9 samples' median, a
    /// tentative track's third of its first two's mean (`fluxAgrees`).
    static let maneuverFlux = 3.0
    /// A turn or stop is followed only for a track with at least this many samples.
    static let maneuverSamples = 5

    /// The aim, for following a track across a dual camera's seam: its lenses' sky directions once `aimQuality` is good or precise.
    var model: SkyCameraModel?
    var aimQuality: SkyAimQuality = .rough

    let width: Int
    let height: Int
    private var open: [Open] = []
    private var tentative: [Tentative] = []
    private var lastTime: TimeInterval?

    /// The tracks open now (born, not ended).
    var activeCount: Int { open.count }

    /// The open tracks' filters: position (analysed pixels) and velocity (pixels a second) as of their last update, for the status and the
    /// tests.
    var filters: [(id: UUID, x: Double, y: Double, vx: Double, vy: Double)] {
        open.map { ($0.track.id, $0.x, $0.y, $0.vx, $0.vy) }
    }

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }

    private struct Open {
        var track: SkyTrack
        /// The filter's position (analysed pixels) and velocity (pixels a second), as of `updated`.
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var updated: TimeInterval
        var lastSeen: TimeInterval
        var lens: Int
        /// Pictures missed since the last sample: the track's misses once it is seen again.
        var pending: [TimeInterval] = []
    }

    private struct Hit {
        var detection: SkyDetection
        var time: TimeInterval
        var wallClock: Date
    }

    private struct Tentative {
        var hits: [Hit]
        var seamJoins = 0
        var uncertain = false
        var lens: Int { hits.last?.detection.lens ?? 0 }
    }

    private enum Join {
        case sameLens, byDirection, byPicture
    }

    /// One analysed picture's detections; call it for every analysed picture, with none when there are none. Returns the tracks that ended
    /// and are kept (the tracks it dropped are not reported: see `update(_:at:wallClock:dropped:)`). A picture with the same time as the last
    /// is ignored (it was handed over twice); an earlier time (the stream's clock started again) ends everything first.
    func update(_ detections: [SkyDetection], at time: TimeInterval, wallClock: Date) -> [SkyTrack] {
        var unreported: [SkyDroppedTrack] = []
        return update(detections, at: time, wallClock: wallClock, dropped: &unreported)
    }

    /// `update`, also appending the tracks that ended and were dropped to `dropped` (`SkyDroppedTrack`: barely moved, or on something fixed;
    /// not lights to log). It returns the same kept tracks `update(_:at:wallClock:)` does, none of which is in `dropped`.
    func update(_ detections: [SkyDetection], at time: TimeInterval, wallClock: Date, dropped: inout [SkyDroppedTrack]) -> [SkyTrack] {
        var ended: [SkyTrack] = []
        guard time.isFinite else { return ended }
        if let lastTime {
            if time == lastTime { return ended }
            if time < lastTime { ended += endAll(dropped: &dropped) }
        }
        let previous = lastTime
        lastTime = time
        let found = detections.filter { $0.x.isFinite && $0.y.isFinite && $0.flux.isFinite }
        var taken = [Bool](repeating: false, count: found.count)
        let pieces = Pieces(found)
        /// A detection taken, with the other pieces of its blob when the seam cut it.
        func take(_ index: Int) {
            taken[index] = true
            for other in pieces.others(of: index) { taken[other] = true }
        }
        let directions = SeamDirections(tracker: self, detections: found)

        // Tracks last seen more than 1.5 s ago are over.
        var index = 0
        while index < open.count {
            if time - open[index].lastSeen > Self.coast {
                ended += finish(open.remove(at: index).track, dropped: &dropped)
            } else {
                index += 1
            }
        }

        // Open tracks take the detections in their gates, the best fits first; a piece of a blob the seam cut only through the track's own
        // lens when the blob has a piece there.
        var claims: [(cost: Double, track: Int, detection: Int, join: Join)] = []
        for (t, track) in open.enumerated() {
            let prediction = predict(x: track.x, y: track.y, vx: track.vx, vy: track.vy, since: time - track.updated)
            for (d, detection) in found.enumerated() where detection.brighter == track.track.brighter {
                if detection.lens != track.lens && pieces.hasPiece(of: d, in: track.lens) { continue }
                if let fit = fit(detection, index: d, lens: track.lens, prediction: prediction, directions: directions) {
                    claims.append((fit.cost, t, d, fit.join))
                }
            }
        }
        claims.sort { $0.cost < $1.cost }
        var served = [Bool](repeating: false, count: open.count)
        for claim in claims where !served[claim.track] && !taken[claim.detection] {
            served[claim.track] = true
            take(claim.detection)
            extend(&open[claim.track], with: found[claim.detection], at: time, wallClock: wallClock, join: claim.join)
        }

        // A track that found nothing in its gate may have turned or stopped.
        for t in open.indices where !served[t] {
            if open[t].lastSeen == previous, let d = maneuver(open[t], at: time, found: found, taken: taken) {
                served[t] = true
                take(d)
                restart(&open[t], with: found[d], at: time, wallClock: wallClock)
            } else {
                open[t].pending.append(time)
            }
        }

        // Tentative tracks: those with two detections take a third in their gates, about as bright as the two, and are born.
        var next: [Tentative] = []
        var pairs: [(cost: Double, tentative: Int, detection: Int, join: Join)] = []
        for (k, candidate) in tentative.enumerated() where candidate.hits.count == 2 {
            let first = candidate.hits[0], second = candidate.hits[1]
            let span = second.time - first.time
            guard span > 0 else { continue }
            let from = position(first, inLens: second.detection.lens)
            let vx = (second.detection.x - from.x) / span, vy = (second.detection.y - from.y) / span
            let prediction = predict(x: second.detection.x, y: second.detection.y, vx: vx, vy: vy, since: time - second.time)
            let flux = (first.detection.flux + second.detection.flux) / 2
            for (d, detection) in found.enumerated() where !taken[d] && detection.brighter == second.detection.brighter {
                guard Self.fluxAgrees(detection.flux, with: flux) else { continue }
                if detection.lens != candidate.lens && pieces.hasPiece(of: d, in: candidate.lens) { continue }
                if let fit = fit(detection, index: d, lens: candidate.lens, prediction: prediction, directions: directions) {
                    pairs.append((fit.cost, k, d, fit.join))
                }
            }
        }
        pairs.sort { $0.cost < $1.cost }
        var grown = [Bool](repeating: false, count: tentative.count)
        for pair in pairs where !grown[pair.tentative] && !taken[pair.detection] {
            grown[pair.tentative] = true
            take(pair.detection)
            var candidate = tentative[pair.tentative]
            note(pair.join, in: &candidate)
            candidate.hits.append(Hit(detection: found[pair.detection], time: time, wallClock: wallClock))
            born(candidate, streak: false)
        }

        // Those with one detection pair with a second: streaks along their path first, then the nearest. A second in the other lens of a
        // dual camera is judged as a join across its seam is (`pairing`).
        let reach = pairingReach(found)
        var matches: [(rank: Int, cost: Double, tentative: Int, detection: Int, join: Join)] = []
        for (k, candidate) in tentative.enumerated() where candidate.hits.count == 1 {
            let first = candidate.hits[0].detection
            for (d, detection) in found.enumerated() where !taken[d] && detection.brighter == first.brighter {
                if detection.lens != first.lens && pieces.hasPiece(of: d, in: first.lens) { continue }
                let distance = hypot(detection.x - first.x, detection.y - first.y)
                let streak = Self.alongTheirPath(first, detection) && distance <= Self.streakPairingShare * Double(width)
                let limit = streak ? Self.streakPairingShare * Double(width)
                    : Self.isStrong(first) && Self.isStrong(detection) ? Self.pairingShare * Double(width) : reach
                if let pair = pairing(first, detection, index: d, distance: distance, limit: limit, directions: directions) {
                    matches.append((streak ? 0 : 1, pair.cost, k, d, pair.join))
                }
            }
        }
        matches.sort { ($0.rank, $0.cost) < ($1.rank, $1.cost) }
        var paired = [Bool](repeating: false, count: tentative.count)
        for match in matches where !paired[match.tentative] && !taken[match.detection] {
            paired[match.tentative] = true
            take(match.detection)
            var candidate = tentative[match.tentative]
            note(match.join, in: &candidate)
            candidate.hits.append(Hit(detection: found[match.detection], time: time, wallClock: wallClock))
            if match.rank == 0 { born(candidate, streak: true) } else { next.append(candidate) }
        }

        // The rest start tentative tracks: a blob the seam cut, one (from its first piece).
        for (d, detection) in found.enumerated() where !taken[d] {
            take(d)
            next.append(Tentative(hits: [Hit(detection: detection, time: time, wallClock: wallClock)]))
        }
        tentative = next

        // A track 10 minutes long is split: it ends, and the light goes on as a new track.
        for t in open.indices {
            guard let first = open[t].track.samples.first?.time, open[t].lastSeen - first >= Self.splitAfter else { continue }
            ended += finish(open[t].track, dropped: &dropped)
            open[t].track = SkyTrack(id: UUID(), samples: [], streakBorn: false, brighter: open[t].track.brighter)
            open[t].pending = []
        }
        return ended
    }

    /// A gap in the stream: everything open ends (the usual rules: a track under 0.6 s is dropped unless streak-born), and nothing is
    /// carried over to the next picture. Returns the kept tracks (the dropped ones are not reported: see `endAll(dropped:)`).
    func endAll() -> [SkyTrack] {
        var unreported: [SkyDroppedTrack] = []
        return endAll(dropped: &unreported)
    }

    /// `endAll`, also appending the tracks it dropped to `dropped` (`SkyDroppedTrack`).
    func endAll(dropped: inout [SkyDroppedTrack]) -> [SkyTrack] {
        var ended: [SkyTrack] = []
        for track in open { ended += finish(track.track, dropped: &dropped) }
        open = []
        tentative = []
        lastTime = nil
        return ended
    }

    // MARK: Gates

    private struct Prediction {
        var x: Double
        var y: Double
        var gate: Double
    }

    private func predict(x: Double, y: Double, vx: Double, vy: Double, since: TimeInterval) -> Prediction {
        let dx = vx * since, dy = vy * since
        return Prediction(x: x + dx, y: y + dy, gate: max(Self.minimumGate, Self.gateShare * hypot(dx, dy)))
    }

    /// How well `detection` continues a track of `lens` predicted at `prediction` (its cost, lower is better), or nil when it does not.
    private func fit(_ detection: SkyDetection, index: Int, lens: Int, prediction: Prediction, directions: SeamDirections) -> (cost: Double, join: Join)? {
        let distance = hypot(detection.x - prediction.x, detection.y - prediction.y)
        if detection.lens == lens {
            return distance <= prediction.gate ? (distance / prediction.gate, .sameLens) : nil
        }
        // The other half of a dual camera: only near the seam.
        let seam = Double(SkyFrameAnalyzer.splitColumn(model, width: width)), near = Self.seamReachShare * Double(width)
        guard model?.layout != .single, abs(prediction.x - seam) <= near || model == nil, abs(detection.x - seam) <= near || model == nil
        else { return nil }
        if aimQuality != .rough, let model {
            guard let seen = directions.direction(of: index),
                  let expected = model.direction(at: PixelPoint(x: prediction.x / Double(width), y: prediction.y / Double(height)), lens: lens)
            else { return nil }
            let scale = model.degreesPerPixel(at: PixelPoint(x: min(1, max(0, prediction.x / Double(width))), y: prediction.y / Double(height)),
                                              pictureWidth: width)
            let tolerance = Self.seamToleranceDegrees + prediction.gate * (scale.isFinite ? scale : 0)
            let separation = SkyMath.separation(expected, seen)
            return separation <= tolerance ? (separation / tolerance, .byDirection) : nil
        }
        let wide = Self.seamGateFactor * prediction.gate + SkyCameraModel.seamBandWidth * Double(width)
        return distance <= wide ? (distance / wide, .byPicture) : nil
    }

    /// Whether `second` can be a track's second detection after `first`, `distance` apart (px), within `limit`, and how well (lower is
    /// better). In one lens, by the picture. In the other lens of a dual camera, as a track's join across its seam is: both near the seam,
    /// and once the aim is good, their sky directions through their own lenses within 3° and `limit` in degrees; before, by the picture
    /// (the pair is then marked uncertain).
    private func pairing(_ first: SkyDetection, _ second: SkyDetection, index: Int, distance: Double, limit: Double,
                         directions: SeamDirections) -> (cost: Double, join: Join)? {
        if second.lens == first.lens { return distance <= limit ? (distance / limit, .sameLens) : nil }
        let seam = Double(SkyFrameAnalyzer.splitColumn(model, width: width)), near = Self.seamReachShare * Double(width)
        guard model?.layout != .single, abs(first.x - seam) <= near || model == nil, abs(second.x - seam) <= near || model == nil
        else { return nil }
        if aimQuality != .rough, let model {
            let point = PixelPoint(x: first.x / Double(width), y: first.y / Double(height))
            guard let seen = directions.direction(of: index), let from = model.direction(at: point, lens: first.lens) else { return nil }
            let scale = model.degreesPerPixel(at: PixelPoint(x: min(1, max(0, point.x)), y: point.y), pictureWidth: width)
            let tolerance = Self.seamToleranceDegrees + limit * (scale.isFinite ? scale : 0)
            let separation = SkyMath.separation(from, seen)
            return separation <= tolerance ? (separation / tolerance, .byDirection) : nil
        }
        return distance <= limit ? (distance / limit, .byPicture) : nil
    }

    /// A detection no chance makes: significant (`significance` 2 or more) and not a lone sharp pixel (`sharpness` under 0.9). A camera's
    /// single-pixel speckle can be far over the threshold, but it is one pixel against the sky around it, where a light seen through a lens
    /// spreads onto its neighbours.
    static func isStrong(_ detection: SkyDetection) -> Bool {
        detection.significance >= strongSignificance && detection.sharpness < loneSharpness
    }

    /// Whether `flux` is about as bright as `reference`: a third to three times it (any, when the reference is nothing).
    static func fluxAgrees(_ flux: Double, with reference: Double) -> Bool {
        !(reference > 0) || (flux >= reference / maneuverFlux && flux <= reference * maneuverFlux)
    }

    /// Where `hit` is in `lens`'s pixels: its own point in its own lens. Through the other lens of a dual camera once the aim is good, where
    /// that lens sees its direction (the halves' pixels are not one grid: overlapping halves show the same sky at different columns);
    /// before, its own point.
    private func position(_ hit: Hit, inLens lens: Int) -> (x: Double, y: Double) {
        let detection = hit.detection
        guard detection.lens != lens, aimQuality != .rough, let model,
              let direction = model.direction(at: PixelPoint(x: detection.x / Double(width), y: detection.y / Double(height)), lens: detection.lens),
              let point = model.project(direction, lens: lens), point.x.isFinite, point.y.isFinite
        else { return (detection.x, detection.y) }
        return (point.x * Double(width), point.y * Double(height))
    }

    /// A faint pair's reach in this picture: where one of its detections turns up by chance once in a hundred (at their density over the
    /// picture), between the 6 px gate and 5 % of the width.
    private func pairingReach(_ found: [SkyDetection]) -> Double {
        let longest = Self.pairingShare * Double(width)
        guard !found.isEmpty else { return longest }
        let density = Double(found.count) / (Double(width) * Double(height))
        return min(longest, max(Self.minimumGate, (Self.chancePartners / (Double.pi * density)).squareRoot()))
    }

    /// Both elongated (3:1 or more) and both along the line from one to the other (±15°).
    private static func alongTheirPath(_ a: SkyDetection, _ b: SkyDetection) -> Bool {
        guard a.elongation >= streakElongation, b.elongation >= streakElongation, a.x != b.x || a.y != b.y else { return false }
        let direction = atan2(b.y - a.y, b.x - a.x) * SkyMath.degrees
        return axisDifference(a.orientation, direction) <= streakAlignment && axisDifference(b.orientation, direction) <= streakAlignment
    }

    /// The angle between two axes (degrees, 0…90): directions taken modulo 180.
    static func axisDifference(_ a: Double, _ b: Double) -> Double {
        let difference = abs((a - b).truncatingRemainder(dividingBy: 180))
        return min(difference, 180 - difference)
    }

    /// The best unclaimed detection to continue a track that found nothing in its gate (it turned or stopped), or nil.
    private func maneuver(_ track: Open, at time: TimeInterval, found: [SkyDetection], taken: [Bool]) -> Int? {
        guard track.track.samples.count >= Self.maneuverSamples, let last = track.track.samples.last else { return nil }
        let since = time - track.lastSeen
        guard since > 0 else { return nil }
        let step = hypot(track.vx, track.vy) * since
        let reach = step + max(Self.minimumGate, Self.gateShare * step)
        let recent = track.track.samples.suffix(9).map(\.flux).sorted()
        let flux = recent[recent.count / 2]
        let lastX = last.point.x * Double(width), lastY = last.point.y * Double(height)
        var best: (distance: Double, index: Int)?
        for (d, detection) in found.enumerated() where !taken[d] && detection.lens == track.lens && detection.brighter == track.track.brighter {
            guard Self.isStrong(detection), Self.fluxAgrees(detection.flux, with: flux) else { continue }
            let distance = hypot(detection.x - lastX, detection.y - lastY)
            if distance <= reach, distance < (best?.distance ?? .infinity) { best = (distance, d) }
        }
        return best?.index
    }

    // MARK: Tracks

    /// Alpha-beta: the prediction moves α of the way to the detection, and the velocity β of the miss over the time since. Across the seam
    /// the position is the detection's (the halves' pixels are not one grid), and the velocity is kept.
    private func extend(_ track: inout Open, with detection: SkyDetection, at time: TimeInterval, wallClock: Date, join: Join) {
        let since = time - track.updated
        let px = track.x + track.vx * since, py = track.y + track.vy * since
        let rx = detection.x - px, ry = detection.y - py
        if join == .sameLens {
            track.x = px + Self.alpha * rx
            track.y = py + Self.alpha * ry
            if since > 0 {
                track.vx += Self.beta / since * rx
                track.vy += Self.beta / since * ry
            }
        } else {
            track.x = detection.x
            track.y = detection.y
            track.lens = detection.lens
            track.track.seamJoins += 1
            if join == .byPicture { track.track.uncertainSeamJoin = true }
        }
        seen(&track, detection, at: time, wallClock: wallClock)
    }

    /// A turn or a stop: the filter starts again from the detection, its velocity measured from where the track was last seen.
    private func restart(_ track: inout Open, with detection: SkyDetection, at time: TimeInterval, wallClock: Date) {
        if let last = track.track.samples.last, time > track.lastSeen {
            track.vx = (detection.x - last.point.x * Double(width)) / (time - track.lastSeen)
            track.vy = (detection.y - last.point.y * Double(height)) / (time - track.lastSeen)
        }
        track.x = detection.x
        track.y = detection.y
        seen(&track, detection, at: time, wallClock: wallClock)
    }

    private func seen(_ track: inout Open, _ detection: SkyDetection, at time: TimeInterval, wallClock: Date) {
        track.updated = time
        track.lastSeen = time
        track.track.misses += track.pending
        track.pending = []
        track.track.samples.append(sample(detection, at: time, wallClock: wallClock))
    }

    private func note(_ join: Join, in candidate: inout Tentative) {
        guard join != .sameLens else { return }
        candidate.seamJoins += 1
        if join == .byPicture { candidate.uncertain = true }
    }

    /// A tentative track becomes an open one, while fewer than 50 are open. Its velocity is from its first detection to its last, in the
    /// last one's lens's pixels.
    private func born(_ candidate: Tentative, streak: Bool) {
        guard open.count < Self.maximumOpen, let first = candidate.hits.first, let last = candidate.hits.last else { return }
        let span = last.time - first.time
        let from = position(first, inLens: last.detection.lens)
        let vx = span > 0 ? (last.detection.x - from.x) / span : 0
        let vy = span > 0 ? (last.detection.y - from.y) / span : 0
        let track = SkyTrack(id: UUID(), samples: candidate.hits.map { sample($0.detection, at: $0.time, wallClock: $0.wallClock) }, streakBorn: streak,
                             brighter: last.detection.brighter, seamJoins: candidate.seamJoins, uncertainSeamJoin: candidate.uncertain)
        open.append(Open(track: track, x: last.detection.x, y: last.detection.y, vx: vx, vy: vy, updated: last.time, lastSeen: last.time,
                         lens: last.detection.lens))
    }

    /// What an ended track leaves: itself, unless it lasted under 0.6 s and was not streak-born, showed only faint samples (all under
    /// significance 1.5), sat on something fixed in the sky all along (`onSomethingFixed`), or barely moved (`moved`); or it was never seen.
    /// A track dropped for sitting on something fixed, or for barely moving, is also appended to `dropped` with its reason, for the later
    /// parts that read flashes and stationary points (`SkyDroppedTrack`); one that is both is `fixed`. The other drops are not handed over: a
    /// track under 0.6 s is the pinned minimum (so none appended has fewer than two samples), and a faint one is noise.
    private func finish(_ track: SkyTrack, dropped: inout [SkyDroppedTrack]) -> [SkyTrack] {
        guard let first = track.samples.first, let last = track.samples.last,
              track.streakBorn || last.time - first.time >= Self.minimumDuration,
              track.samples.contains(where: { $0.significance >= Self.faintSignificance }) else { return [] }
        if onSomethingFixed(track) {
            dropped.append(SkyDroppedTrack(track: track, reason: .fixed))
        } else if !moved(track) {
            dropped.append(SkyDroppedTrack(track: track, reason: .barelyMoved))
        } else {
            return [track]
        }
        return []
    }

    /// Whether a track sat on something fixed in the sky all along (a star, a wire or a lamp flickering): every sample within 10 px of a spot
    /// of the slow background standing 5σ (`fixedSigmas`, `SkyDetection.fixedRise`). A track that stayed where it began (`travelled`) is
    /// then that thing: a star's track wanders onto the noise beside it, and sits beside the star's own trail in the slow background as the
    /// sky turns it a few pixels a minute. One that travelled further is that thing only when it sat right on it (within 3 px) at least half
    /// the time: flicker along a wire. A light flying along a wire is beside it, not on it, and a light crossing a star is clear of it
    /// before and after.
    private func onSomethingFixed(_ track: SkyTrack) -> Bool {
        guard track.samples.allSatisfy({ $0.fixedRise >= Self.fixedSigmas }) else { return false }
        guard travelled(track) else { return true }
        return Double(track.samples.filter { $0.fixedRiseUnder >= Self.fixedSigmas }.count) >= Self.fixedShare * Double(track.samples.count)
    }

    /// Whether a track went further than one fixed spot accounts for: its first and last points at least `travelPixels` apart (the slow
    /// background's reach, `SkyFrameAnalyzer.anchorRadius`), faster than a stationary light (`TrackMeasurer.stationarySpeed`, 0.05°/s:
    /// through the model where the track is, or at 0.1° a pixel without one).
    private func travelled(_ track: SkyTrack) -> Bool {
        guard let first = track.samples.first, let last = track.samples.last, last.time > first.time else { return false }
        let pixels = hypot((last.point.x - first.point.x) * Double(width), (last.point.y - first.point.y) * Double(height))
        guard pixels >= Self.travelPixels else { return false }
        var scale = Self.nominalDegreesPerPixel
        if let model {
            let middle = PixelPoint(x: min(1, max(0, (first.point.x + last.point.x) / 2)), y: (first.point.y + last.point.y) / 2)
            let local = model.degreesPerPixel(at: middle, pictureWidth: width)
            if local.isFinite && local > 0 { scale = local }
        }
        return pixels * scale / (last.time - first.time) >= TrackMeasurer.stationarySpeed
    }

    /// Whether a track moved: some sample is far enough from its first, 4 analysed pixels and once the aim is not rough 0.05° on the sky too
    /// (each point's direction through its own lens; where the model gives none, the pixels alone decide). The farthest sample decides, not
    /// the last, so a loop or a path out and back that went far is kept.
    private func moved(_ track: SkyTrack) -> Bool {
        guard let first = track.samples.first else { return false }
        let across = Double(width), down = Double(height)
        let origin = aimQuality != .rough ? model?.direction(at: first.point, lens: first.lens) : nil
        return track.samples.contains { sample in
            let pixels = hypot((sample.point.x - first.point.x) * across, (sample.point.y - first.point.y) * down)
            guard pixels >= Self.minimumMovePixels else { return false }
            guard let origin, let model, let there = model.direction(at: sample.point, lens: sample.lens) else { return true }
            return SkyMath.separation(origin, there) >= Self.minimumMoveDegrees
        }
    }

    private func sample(_ detection: SkyDetection, at time: TimeInterval, wallClock: Date) -> SkyTrackSample {
        SkyTrackSample(time: time, wallClock: wallClock, point: PixelPoint(x: detection.x / Double(width), y: detection.y / Double(height)),
                       area: detection.area, flux: detection.flux, sharpness: detection.sharpness, elongation: detection.elongation,
                       lens: detection.lens, inSeamBand: detection.inSeamBand, significance: detection.significance, fixedRise: detection.fixedRise,
                       fixedRiseUnder: detection.fixedRiseUnder)
    }

    /// The pieces of the blobs a dual camera's seam cut (`SkyDetection.seamGroup`) among a picture's detections.
    private struct Pieces {
        /// For each detection, the other pieces of its blob (none for a blob the seam did not cut).
        private var partners: [[Int]]
        private let lenses: [Int]

        init(_ detections: [SkyDetection]) {
            partners = Array(repeating: [], count: detections.count)
            lenses = detections.map(\.lens)
            var groups: [Int: [Int]] = [:]
            for (index, detection) in detections.enumerated() {
                if let group = detection.seamGroup { groups[group, default: []].append(index) }
            }
            for members in groups.values where members.count > 1 {
                for member in members { partners[member] = members.filter { $0 != member } }
            }
        }

        func others(of index: Int) -> [Int] {
            partners[index]
        }

        /// Whether the blob that detection `index` is a piece of has a piece in `lens`.
        func hasPiece(of index: Int, in lens: Int) -> Bool {
            partners[index].contains { lenses[$0] == lens }
        }
    }

    /// The sky directions of a picture's detections near a dual camera's seam, through their own lenses, worked out once each when a join
    /// across the seam needs them.
    private final class SeamDirections {
        private let model: SkyCameraModel?
        private let width: Double
        private let height: Double
        private let detections: [SkyDetection]
        private var cache: [Int: SkyDirection?] = [:]

        init(tracker: SkyTracker, detections: [SkyDetection]) {
            model = tracker.aimQuality == .rough ? nil : tracker.model
            width = Double(tracker.width)
            height = Double(tracker.height)
            self.detections = detections
        }

        func direction(of index: Int) -> SkyDirection? {
            if let known = cache[index] { return known }
            let detection = detections[index]
            let direction = model?.direction(at: PixelPoint(x: detection.x / width, y: detection.y / height), lens: detection.lens)
            cache[index] = direction
            return direction
        }
    }
}
