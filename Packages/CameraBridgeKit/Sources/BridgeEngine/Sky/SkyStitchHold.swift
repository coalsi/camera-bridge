import Foundation

/// The lights a sky camera's detector holds after their track ended (`SkyCameraDetector`), so that a piece that continues one (`SkyStitch`) joins it before it
/// is classified and logged: one light, one entry, one picture of its middle.
///
/// A track that ended (kept by the tracker, or a flash it dropped: `SkyDroppedTrack.DropReason.barelyMoved`, streak-born or under 1.5 s) joins the light it
/// belongs to, or begins one. A light is held for `SkyStitch.longestGap` after its last piece ended, and `birthSlack` more (the tracker gives a track that
/// begins in that time only three pictures later); longer only while a track open now may still be part of it (it began in that time and so far continues
/// it, it is the same light followed twice, or by day it drew the line the light kept to): it is let go once that track has ended without joining it. At
/// most `longestHeld` are held (the light that ended first goes first), a light is never longer than 10 minutes (`SkyStitch.longestLight`), and everything
/// is let go at a gap, a restart, a new picture size or a clock that went back (`flush`). On its own a held light costs its tracks' samples (at most 10
/// minutes of pictures each) and a fit of a few seconds of them a picture.
struct SkyStitchHold: Sendable {
    /// A track that continues a light is reported this long after it began, at most (s): three pictures, and the picture it comes in.
    static let birthSlack: TimeInterval = 1
    /// At most this many lights are held.
    static let longestHeld = 100
    /// A chain of flashes alone is a light worth logging with this many flashes, over this long (s) and this far (analysed pixels).
    static let fewestFlashes = 3
    static let shortestFlashes = SkyRules.strobeShortest
    static let flashesTravel = 4 * SkyStitch.floorPixels

    /// A light let go: the light, and its parts' tracks in the order they joined.
    struct Released: Sendable {
        var light: SkyStitch.Light
        var tracks: [SkyTrack]
    }

    private var joiner: SkyStitch.Joiner
    private var tracks: [String: SkyTrack] = [:]

    /// `picture`: the analysed picture the tracks are seen in (its size in pixels, and a dual camera's seam).
    init(picture: SkyStitch.Picture) {
        joiner = SkyStitch.Joiner(picture: picture)
    }

    var picture: SkyStitch.Picture { joiner.picture }
    /// How many lights are held.
    var count: Int { joiner.lights.count }
    var isEmpty: Bool { joiner.lights.isEmpty }

    /// A track that ended (`flash`: one the tracker dropped as a flash) joins what it belongs to, or begins a light; `byDay`: the Sun was at −6° or above.
    /// Returns the lights let go to keep within `longestHeld`.
    mutating func add(_ track: SkyTrack, flash: Bool, byDay: Bool) -> [Released] {
        let piece = Self.piece(of: track, in: picture, flash: flash, byDay: byDay)
        guard !piece.points.isEmpty else { return [] }
        tracks[piece.id] = track
        joiner.add(piece)
        var released: [Released] = []
        while joiner.lights.count > Self.longestHeld, let oldest = joiner.lights.indices.min(by: { joiner.lights[$0].end < joiner.lights[$1].end }) {
            released.append(take(oldest))
        }
        return released
    }

    /// The lights nothing can join any more at `time` (the stream's seconds, as the tracks' samples): quiet for `SkyStitch.longestGap` and `birthSlack`,
    /// and no track of `open` (the tracker's open tracks, as followed so far) may still be part of it; or 10 minutes long.
    mutating func release(at time: TimeInterval, open: [SkyTrack]) -> [Released] {
        var released: [Released] = []
        for index in joiner.lights.indices.reversed() {
            let light = joiner.lights[index]
            guard time > light.end + SkyStitch.longestGap + Self.birthSlack else { continue }
            if time - light.spineStart <= SkyStitch.longestLight, open.contains(where: { mightJoin($0, light) }) { continue }
            released.append(take(index))
        }
        return released.reversed()
    }

    /// Every light held, let go (a gap, a restart, a new picture size, a clock that went back, the stop).
    mutating func flush() -> [Released] {
        var released: [Released] = []
        while !joiner.lights.isEmpty { released.append(take(0)) }
        return released
    }

    /// Whether an open track, as followed so far, may still be part of `light`.
    private func mightJoin(_ track: SkyTrack, _ light: SkyStitch.Light) -> Bool {
        guard let first = track.samples.first?.time, let last = track.samples.last?.time, first <= light.end + SkyStitch.longestGap,
              last >= light.start - SkyStitch.longestOverlap else { return false }
        let piece = Self.piece(of: track, in: picture, flash: false, byDay: light.byDay)
        return SkyStitch.match(piece, to: light, in: picture) != nil || SkyStitch.absorbed(light, by: SkyStitch.Light(piece), in: picture) != nil
    }

    private mutating func take(_ index: Int) -> Released {
        let light = joiner.remove(at: index)
        return Released(light: light, tracks: light.parts.compactMap { tracks.removeValue(forKey: $0.id) })
    }

    /// A track as a piece: its samples' points in the analysed picture's pixels, at their stream times.
    static func piece(of track: SkyTrack, in picture: SkyStitch.Picture, flash: Bool, byDay: Bool) -> SkyStitch.Piece {
        SkyStitch.Piece(id: track.id.uuidString, points: track.samples.map { picture.point(t: $0.time, x: $0.point.x, y: $0.point.y) }, flash: flash,
                        byDay: byDay)
    }
}

extension SkyStitchHold.Released {
    /// The light as one track to classify and log, with how many pieces it was seen in and its kind; nil when there is nothing to log (a flash alone, or
    /// flashes that never made a chain: fewer than `fewestFlashes`, shorter than `shortestFlashes` or nearer than `flashesTravel` end to end; the tracker
    /// dropped them, and they were handed over as such). A light of one piece is its track as it was. Otherwise:
    /// - its samples are its spine's (its own pieces', not its contrail's), one a picture, in time order, each the sample of the piece it came from;
    /// - the pictures it was missed in are its pieces' own and, in each gap between pieces, one at their pace (the median time between their samples), so
    ///   that its blinking, its strobe and the share of its pictures it was seen in are measured over the whole light (`TrackMeasurer`);
    /// - its id, its first piece's; born from a streak when that was, brighter or darker as it was; its joins across the seam its pieces' and the stitch's.
    /// Its kind is a chain of flashes (`SkyEntryKind.flash`) when every piece was a flash.
    func track() -> (track: SkyTrack, pieces: Int, kind: SkyEntryKind)? {
        guard let first = tracks.first, let firstPart = light.parts.first, tracks.count == light.parts.count else { return nil }
        if light.parts.count == 1 { return firstPart.flash ? nil : (first, 1, .track) }
        let spineIDs = Set(light.spineParts.map(\.id))
        let spineTracks = tracks.filter { spineIDs.contains($0.id.uuidString) }
        var byTime: [TimeInterval: SkyTrackSample] = [:]
        for track in spineTracks {
            for sample in track.samples where byTime[sample.time] == nil { byTime[sample.time] = sample }
        }
        let samples = light.spine.compactMap { byTime[$0.t] }
        guard let begins = samples.first, let ends = samples.last else { return nil }
        let flashes = light.flashesOnly
        if flashes {
            guard let from = light.spine.first, let to = light.spine.last, light.parts.count >= SkyStitchHold.fewestFlashes,
                  ends.time - begins.time >= SkyStitchHold.shortestFlashes, hypot(to.x - from.x, to.y - from.y) >= SkyStitchHold.flashesTravel else { return nil }
        }
        let times = Set(samples.map(\.time))
        var misses = spineTracks.flatMap(\.misses).filter { $0 > begins.time && $0 < ends.time && !times.contains($0) }
        misses = Array(Set(misses)).sorted()
        let pace = Self.pace(spineTracks)
        var gapMisses: [TimeInterval] = []
        for (a, b) in zip(samples, samples.dropFirst()) where b.time - a.time > 1.5 * pace {
            guard !misses.contains(where: { $0 > a.time && $0 < b.time }) else { continue }
            let count = min(Int(((b.time - a.time) / pace).rounded()) - 1, SkyStitch.mostMissesInAGap)
            guard count > 0 else { continue }
            for k in 1...count { gapMisses.append(a.time + (b.time - a.time) * Double(k) / Double(count + 1)) }
        }
        let firstSpine = spineTracks.first ?? first
        let seams = light.parts.filter { $0.link == .seam }.count
        let track = SkyTrack(id: first.id, samples: samples, streakBorn: firstSpine.streakBorn, misses: (misses + gapMisses).sorted(),
                             brighter: firstSpine.brighter, seamJoins: spineTracks.reduce(seams) { $0 + $1.seamJoins },
                             uncertainSeamJoin: spineTracks.contains { $0.uncertainSeamJoin })
        return (track, light.parts.count, flashes ? .flash : .track)
    }

    /// The pace of tracks' pictures: the median time between their consecutive samples (s), between a twentieth of a second and one second.
    private static func pace(_ tracks: [SkyTrack]) -> TimeInterval {
        let steps = tracks.flatMap { track in zip(track.samples, track.samples.dropFirst()).map { $1.time - $0.time } }.filter { $0 > 0 && $0.isFinite }.sorted()
        guard !steps.isEmpty else { return 1 / SkyStreamChoice.analysisRate }
        return min(1, max(0.05, steps[steps.count / 2]))
    }
}
