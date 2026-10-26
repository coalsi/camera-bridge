import BridgeSupport
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

// One light, not fifteen (the owner, 2026-10-26: "if you look at the timing of the event and the location it should understand it's one object not
// 15"): the rule that says when pieces are one light (`SkyStitch`), the detector holding a light until nothing can continue it (`SkyStitchHold`), and
// the older logs joined as they are read (`SkyStitch.joined`, `BridgeEngine.skyNightLog`, corrections). All made up: pieces in the pixels of a 1920 ×
// 852 analysed picture (a dual camera's, its seam at 960), five points a second.

@Suite(.timeLimit(.minutes(3))) struct SkyStitchTests {
    static let dual = SkyStitch.Picture(width: 1920, height: 852, seam: 0.5)
    static let single = SkyStitch.Picture(width: 1920, height: 852)

    /// A piece of a light: from `start` (s) for `seconds`, five points a second, from (x, y) at (vx, vy) pixels a second.
    static func piece(_ id: String, from start: Double, seconds: Double, at x: Double, _ y: Double, moving vx: Double, _ vy: Double, flash: Bool = false,
                      byDay: Bool = false) -> SkyStitch.Piece {
        let count = max(1, Int((seconds * 5).rounded()) + 1)
        return SkyStitch.Piece(id: id, points: (0..<count).map { k in
            let t = Double(k) / 5
            return SkyStitch.Point(t: start + t, x: x + vx * t, y: y + vy * t)
        }, flash: flash, byDay: byDay)
    }

    /// A light that crossed the picture at (vx, vy) from (x, y) at 0 s, seen only in `spans` (each from a time for a time, s): its pieces.
    static func pieces(of name: String, at x: Double, _ y: Double, moving vx: Double, _ vy: Double, seen spans: [(from: Double, seconds: Double)],
                       byDay: Bool = false) -> [SkyStitch.Piece] {
        spans.enumerated().map { index, span in
            piece("\(name)\(index)", from: span.from, seconds: span.seconds, at: x + vx * span.from, y + vy * span.from, moving: vx, vy, byDay: byDay)
        }
    }

    /// The pieces joined in the order they began; the lights, by their first piece's id.
    static func join(_ pieces: [SkyStitch.Piece], in picture: SkyStitch.Picture = dual) -> [SkyStitch.Light] {
        var joiner = SkyStitch.Joiner(picture: picture)
        for piece in pieces.sorted(by: { ($0.points.first?.t ?? 0) < ($1.points.first?.t ?? 0) }) { joiner.add(piece) }
        return joiner.lights.sorted { ($0.parts.first?.id ?? "") < ($1.parts.first?.id ?? "") }
    }

    static func ids(_ lights: [SkyStitch.Light]) -> [[String]] {
        lights.map { $0.parts.map(\.id).sorted() }.sorted { $0.first ?? "" < $1.first ?? "" }
    }

    // MARK: A light in pieces

    @Test func strobeGapsJoinIntoOneLight() {
        // A plane at 10 px/s whose light is seen 2.4 s at a time and dark 1.6 to 4 s between (as on Oct 25 at 7:32 PM): one light of five pieces,
        // each continuing the last.
        let spans: [(Double, Double)] = [(0, 2.4), (4, 2.4), (8.4, 2.4), (14.8, 2.4), (21.2, 3)]
        let pieces = Self.pieces(of: "p", at: 200, 400, moving: 10, -3, seen: spans)
        let lights = Self.join(pieces)
        #expect(lights.count == 1)
        let light = try! #require(lights.first)
        #expect(light.parts.map(\.link) == [.first, .next, .next, .next, .next])
        #expect(light.spine.count == pieces.reduce(0) { $0 + $1.points.count }, "every piece's points are the light's path")
        #expect(light.start == 0 && light.end == 24.2)
        // A gap longer than 6 s is another light: the light the tracker lost is gone by then.
        let late = Self.pieces(of: "q", at: 200, 400, moving: 10, -3, seen: [(0, 2.4), (8.6, 2.4)])
        #expect(Self.join(late).count == 2)
    }

    @Test func aLightAheadAfterAFrozenPictureJoinsButNotBehind() {
        // The light's last pictures froze while it moved on: the next piece begins 0.4 s before the first ends and 8 px ahead of where it was then (Oct
        // 25, 7:32 PM: each piece began 6 to 9 px ahead).
        let a = Self.piece("a", from: 0, seconds: 3, at: 100, 300, moving: 10, 0)
        let b = Self.piece("b", from: 2.6, seconds: 3, at: 100 + 26 + 8, 300, moving: 10, 0)
        #expect(Self.ids(Self.join([a, b])) == [["a", "b"]])
        let match = SkyStitch.match(b, to: SkyStitch.Light(a), in: Self.dual)
        #expect(match?.link == .next)
        // Behind where the light would be, by more than the floor and a quarter of its travel: another light following on its line (a car behind
        // another on a road, a plane in trail).
        let behind = Self.piece("c", from: 5, seconds: 3, at: 100 + 50 - 12, 300, moving: 10, 0)
        #expect(SkyStitch.match(behind, to: SkyStitch.Light(a), in: Self.dual) == nil)
        // Ahead by more than 1.5 s of its travel (and the tolerance): another light.
        let farAhead = Self.piece("d", from: 5, seconds: 3, at: 100 + 50 + 30, 300, moving: 10, 0)
        #expect(SkyStitch.match(farAhead, to: SkyStitch.Light(a), in: Self.dual) == nil)
        // Beside the line by more than the tolerance: another light.
        let beside = Self.piece("e", from: 5, seconds: 3, at: 150, 300 + 11, moving: 10, 0)
        #expect(SkyStitch.match(beside, to: SkyStitch.Light(a), in: Self.dual) == nil)
    }

    @Test func aSeamCrossingJoins() {
        // A light going left at 10 px/s reaches the seam (960) in the right half and shows in the left half 4 s later right by it: the stitch hid a
        // strip of sky, and in the picture the light waited at the seam (Oct 25, 6:32 PM: 5.6 s). A few pixels lower, as the halves meet.
        let a = Self.piece("a", from: 0, seconds: 6, at: 1022, 400, moving: -10, 0)
        let b = Self.piece("b", from: 10, seconds: 6, at: 957, 405, moving: -10, 0)
        #expect(SkyStitch.match(b, to: SkyStitch.Light(a), in: Self.dual)?.link == .seam)
        #expect(Self.join([a, b]).first?.parts.map(\.link) == [.first, .seam])
        // Away from the seam (or on a camera of one lens) the same pieces are two lights: the second is 35 px behind where the light would be.
        #expect(SkyStitch.match(b, to: SkyStitch.Light(a), in: Self.single) == nil)
        let elsewhere = (Self.piece("c", from: 0, seconds: 6, at: 1522, 400, moving: -10, 0), Self.piece("d", from: 10, seconds: 6, at: 1457, 405, moving: -10, 0))
        #expect(SkyStitch.match(elsewhere.1, to: SkyStitch.Light(elsewhere.0), in: Self.dual) == nil)
        // Across the seam the other way, but going back: not the same light.
        let back = Self.piece("e", from: 10, seconds: 6, at: 957, 405, moving: 10, 0)
        #expect(SkyStitch.match(back, to: SkyStitch.Light(a), in: Self.dual) == nil)
    }

    @Test func twoPlanesCrossingDoNotJoin() {
        // Plane 1 goes right at 10 px/s and the tracker loses it as it meets plane 2 at (500, 300); plane 2 crosses there at 60° or 90°, or at 20° at
        // two and a half times its speed, or at 20° at its speed, and the tracker begins it again just after the crossing. Plane 1 shows again 2 s
        // later on its own line.
        let one = Self.piece("1a", from: 0, seconds: 10, at: 400, 300, moving: 10, 0)
        let oneAgain = Self.piece("1b", from: 12, seconds: 6, at: 520, 300, moving: 10, 0)
        for (degrees, speed) in [(60.0, 10.0), (90.0, 10.0), (20.0, 25.0), (20.0, 10.0)] {
            let radians = degrees * Double.pi / 180
            let vx = speed * cos(radians), vy = -speed * sin(radians)
            // Plane 2 passes (500, 300) at 10 s: its piece before (lost there too) and after.
            let twoBefore = Self.piece("2a", from: 2, seconds: 8, at: 500 - vx * 8, 300 - vy * 8, moving: vx, vy)
            let twoAfter = Self.piece("2b", from: 10.4, seconds: 8, at: 500 + vx * 0.4, 300 + vy * 0.4, moving: vx, vy)
            let lights = Self.join([one, oneAgain, twoBefore, twoAfter])
            #expect(Self.ids(lights) == [["1a", "1b"], ["2a", "2b"]], "\(degrees)°: \(Self.ids(lights))")
            // Plane 2 after the crossing does not continue plane 1, even alone, when it turned more than 30° or goes at another speed. At a shallow
            // angle and the same speed it could, alone: then plane 2's own piece before the crossing continues it better, and it joins that.
            let alone = SkyStitch.match(twoAfter, to: SkyStitch.Light(one), in: Self.dual)
            if degrees > SkyStitch.headings || !SkyStitch.speedRatios.contains(speed / 10) {
                #expect(alone == nil, "\(degrees)° at \(speed)")
            } else {
                let own = try! #require(SkyStitch.match(twoAfter, to: SkyStitch.Light(twoBefore), in: Self.dual))
                #expect(alone == nil || own.score < alone!.score, "\(degrees)° at \(speed)")
            }
        }
    }

    @Test func aFormationDoesNotJoin() {
        // Three lights side by side (a formation, a satellite train abreast), 12 px apart across their way, the same speed and heading at the same
        // time, each seen in pieces with a gap of 2 s: three lights of two pieces each, never one.
        let spans: [(Double, Double)] = [(0, 5), (7, 5)]
        let formation = [0.0, 12, 24].enumerated().flatMap { index, offset in
            Self.pieces(of: "f\(index)-", at: 300, 200 + offset, moving: 8, 0, seen: spans)
        }
        let lights = Self.join(formation)
        #expect(Self.ids(lights) == [["f0-0", "f0-1"], ["f1-0", "f1-1"], ["f2-0", "f2-1"]], "\(Self.ids(lights))")
        #expect(lights.allSatisfy { $0.parts.map(\.link) == [.first, .next] })
        // Two of them, side by side the whole time, are not one light followed twice either.
        #expect(SkyStitch.sameLight(formation[0].points, formation[2].points) == nil)
    }

    @Test func aTurnWithinToleranceJoinsAndAReversalDoesNot() {
        let a = Self.piece("a", from: 0, seconds: 5, at: 300, 300, moving: 10, 0)
        let end = (x: 350.0, y: 300.0)
        func after(_ degrees: Double, seconds: Double = 4, gap: Double = 1.6) -> SkyStitch.Piece {
            let radians = degrees * Double.pi / 180, vx = 10 * cos(radians), vy = 10 * sin(radians)
            return Self.piece("b", from: 5 + gap, seconds: seconds, at: end.x + 10 * gap, end.y, moving: vx, vy)
        }
        #expect(SkyStitch.match(after(20), to: SkyStitch.Light(a), in: Self.dual)?.link == .next, "a gentle turn")
        #expect(SkyStitch.match(after(-25), to: SkyStitch.Light(a), in: Self.dual)?.link == .next)
        #expect(SkyStitch.match(after(45), to: SkyStitch.Light(a), in: Self.dual) == nil, "more than 30°")
        #expect(SkyStitch.match(after(180), to: SkyStitch.Light(a), in: Self.dual) == nil, "back the way it came")
        // A piece too short to say which way it goes is placed by the light's motion, and must still go its way: one going back is not it.
        #expect(SkyStitch.match(after(0, seconds: 0.8), to: SkyStitch.Light(a), in: Self.dual)?.link == .next)
        #expect(SkyStitch.match(after(150, seconds: 0.8), to: SkyStitch.Light(a), in: Self.dual) == nil)
        // Nor much faster: a short piece six times as fast along the line (a contrail's bits) is not the light.
        let fast = Self.piece("f", from: 6.6, seconds: 0.6, at: 366, 300, moving: 60, 0)
        #expect(SkyStitch.match(fast, to: SkyStitch.Light(a), in: Self.dual) == nil)
        // Twice as fast or half as fast, both long: the same speed within 0.5 to 2.
        let faster = Self.piece("g", from: 6.6, seconds: 4, at: 366, 300, moving: 25, 0)
        #expect(SkyStitch.match(faster, to: SkyStitch.Light(a), in: Self.dual) == nil)
    }

    @Test func theSameLightFollowedTwiceIsOne() {
        // The tracker followed one light twice at once (a blob split in two): within 2 px at every picture they share.
        let a = Self.piece("a", from: 0, seconds: 8, at: 300, 300, moving: 10, 0)
        let b = Self.piece("b", from: 2, seconds: 8, at: 322, 301.5, moving: 10, 0)
        #expect(SkyStitch.match(b, to: SkyStitch.Light(a), in: Self.dual)?.link == .sameLight)
        let light = try! #require(Self.join([a, b]).first)
        #expect(light.parts.map(\.link) == [.first, .sameLight])
        #expect(light.spine.count == 51, "one point a picture: 0 to 10 s")
        // Two lights 10 px apart, side by side: two.
        let beside = Self.piece("c", from: 2, seconds: 8, at: 320, 310, moving: 10, 0)
        #expect(Self.join([a, beside]).count == 2)
        // Two lights that only cross: they go different ways.
        let crossing = Self.piece("d", from: 3, seconds: 4, at: 350 - 14, 300 - 14, moving: 7, 7)
        #expect(SkyStitch.sameLight(a.points, crossing.points) == nil)
    }

    @Test func byDayAContrailIsPartOfItsPlaneButNotAtNight() {
        // By day a plane draws a line for 20 s; pieces of its contrail light up along what it drew, going back along it and forward: parts of the
        // plane, not of its path.
        let plane = Self.piece("plane", from: 0, seconds: 20, at: 100, 100, moving: 12, 6, byDay: true)
        let back = Self.piece("echo1", from: 8, seconds: 3, at: 100 + 12 * 7, 100 + 6 * 7, moving: -20, -10, byDay: true)
        let forward = Self.piece("echo2", from: 14, seconds: 2, at: 100 + 12 * 9, 100 + 6 * 9, moving: 24, 12, byDay: true)
        let lights = Self.join([plane, back, forward])
        #expect(Self.ids(lights) == [["echo1", "echo2", "plane"]])
        let light = try! #require(lights.first)
        #expect(light.parts.filter { $0.link == .trail }.count == 2 && light.spine == plane.points, "the plane's path is its own")
        // At night nothing is a contrail (a satellite train keeps to one line too): three lights.
        let night = [plane, back, forward].map { SkyStitch.Piece(id: $0.id, points: $0.points) }
        #expect(Self.join(night).count == 3)
        // By day, a plane following the first a minute later on its line is not on the line the first drew in the last 15 s.
        let follower = Self.piece("follower", from: 21, seconds: 10, at: 100 + 12, 100 + 6, moving: 12, 6, byDay: true)
        #expect(SkyStitch.match(follower, to: SkyStitch.Light(plane), in: Self.dual) == nil)
        // The contrail's bit that ended before the plane did, taken in first (live: it ended first): the plane takes it in when it comes.
        var joiner = SkyStitch.Joiner(picture: Self.dual)
        joiner.add(back)
        joiner.add(plane)
        #expect(joiner.lights.count == 1 && joiner.lights.first?.parts.map(\.id) == ["plane", "echo1"])
    }

    @Test func aLightThatFoundItsTwinFirstStillJoinsTheLightBefore() {
        // Live, pieces come as they end. The second piece of a light (5.5 s after the first) was followed twice for a while, and the twin ended first: too
        // late after the first piece to continue it alone, it waits on its own. The second piece is the same light as the twin, which it joins, and the
        // first piece, which the pair continues, comes too.
        let first = Self.piece("a", from: 0, seconds: 5, at: 300, 300, moving: 10, 0)
        let second = Self.piece("c", from: 10.5, seconds: 9.5, at: 405, 300, moving: 10, 0)
        let twin = Self.piece("b", from: 12, seconds: 4, at: 421, 301, moving: 10, 0)
        #expect(SkyStitch.match(twin, to: SkyStitch.Light(first), in: Self.dual) == nil, "7 s after it")
        var joiner = SkyStitch.Joiner(picture: Self.dual)
        for piece in [first, twin, second] { joiner.add(piece) }
        #expect(joiner.lights.count == 1, "\(joiner.lights.map { $0.parts.map(\.id) })")
        #expect(joiner.lights.first?.parts.map(\.id) == ["a", "b", "c"] && joiner.lights.first?.parts.map(\.link) == [.first, .next, .sameLight])
    }

    @Test func aLightIsNeverLongerThanTenMinutes() {
        let a = Self.piece("a", from: 0, seconds: 598, at: 10, 300, moving: 1, 0)
        let b = Self.piece("b", from: 600, seconds: 5, at: 612, 300, moving: 1, 0)
        #expect(SkyStitch.match(b, to: SkyStitch.Light(a), in: Self.dual) == nil)
    }

    // MARK: The hold (live)

    /// A tracker's track of a light: from `start` (s, the stream's) for `seconds`, five samples a second, from (x, y) at (vx, vy) analysed pixels a second
    /// of a 1920 × 852 picture.
    static func track(from start: Double, seconds: Double, at x: Double, _ y: Double, moving vx: Double, _ vy: Double, misses: [Double] = [],
                      flux: Double = 400) -> SkyTrack {
        let count = max(1, Int((seconds * 5).rounded()) + 1)
        let samples = (0..<count).map { k -> SkyTrackSample in
            let t = Double(k) / 5
            return SkyTrackSample(time: start + t, wallClock: SkyFixtures.aimEpoch.addingTimeInterval(start + t),
                                  point: PixelPoint(x: (x + vx * t) / 1920, y: (y + vy * t) / 852), area: 6, flux: flux, sharpness: 0.6, elongation: 1.2,
                                  lens: (x + vx * t) < 960 ? 0 : 1, significance: 3)
        }
        return SkyTrack(id: UUID(), samples: samples, streakBorn: false, misses: misses)
    }

    @Test func theHoldKeepsALightForTheGapThenLetsItGo() throws {
        var hold = SkyStitchHold(picture: Self.dual)
        let a = Self.track(from: 100, seconds: 5, at: 300, 300, moving: 10, 0)
        #expect(hold.add(a, flash: false, byDay: false).isEmpty && hold.count == 1)
        // Held for 6 s after its last picture, and the second it takes a continuation to be born.
        #expect(hold.release(at: 111.9, open: []).isEmpty && hold.count == 1)
        let released = hold.release(at: 112.1, open: [])
        #expect(released.count == 1 && hold.isEmpty)
        let one = try #require(released.first?.track())
        #expect(one.pieces == 1 && one.kind == .track && one.track.id == a.id && one.track.samples == a.samples)
    }

    @Test func theHoldWaitsForAnOpenTrackThatContinuesTheLight() throws {
        var hold = SkyStitchHold(picture: Self.dual)
        let a = Self.track(from: 100, seconds: 5, at: 300, 300, moving: 10, 0)
        _ = hold.add(a, flash: false, byDay: false)
        // A track that began 2 s after the light ended, where it would be, is still open at 112.1 s: the light waits for it.
        let open = Self.track(from: 107, seconds: 6, at: 370, 300, moving: 10, 0)
        #expect(hold.release(at: 113, open: [open]).isEmpty)
        // It ends and joins the light: one light of two pieces, the gap's pictures missed.
        let b = Self.track(from: 107, seconds: 8, at: 370, 300, moving: 10, 0)
        #expect(hold.add(b, flash: false, byDay: false).isEmpty && hold.count == 1)
        #expect(hold.release(at: 122, open: []).isEmpty, "6 s and the second after its last piece ended")
        let released = hold.release(at: 122.1, open: [])
        let joined = try #require(released.first?.track())
        #expect(joined.pieces == 2 && joined.kind == .track && joined.track.id == a.id)
        #expect(joined.track.samples.count == a.samples.count + b.samples.count)
        #expect(joined.track.misses.count == 9 && joined.track.misses.allSatisfy { $0 > 105 && $0 < 107 }, "\(joined.track.misses)")
        // An open track elsewhere does not keep a light.
        var other = SkyStitchHold(picture: Self.dual)
        _ = other.add(a, flash: false, byDay: false)
        let elsewhere = Self.track(from: 107, seconds: 6, at: 900, 600, moving: -10, 0)
        #expect(other.release(at: 113, open: [elsewhere]).count == 1)
    }

    @Test func theHoldIsBoundedAndFlushes() {
        var hold = SkyStitchHold(picture: Self.dual)
        // Lights far apart: each held on its own; at most 100, the one that ended first let go first.
        var released: [SkyStitchHold.Released] = []
        for index in 0..<101 {
            released += hold.add(Self.track(from: 100 + Double(index) * 0.01, seconds: 2, at: 10 + Double(index % 20) * 90, 30 + Double(index / 20) * 150,
                                            moving: 10, 0), flash: false, byDay: false)
        }
        #expect(hold.count == SkyStitchHold.longestHeld && released.count == 1)
        #expect(released.first?.light.end == 102)
        // A light longer than 10 minutes is let go whatever is open.
        var long = SkyStitchHold(picture: Self.dual)
        let crawl = Self.track(from: 0, seconds: 599, at: 10, 300, moving: 1, 0)
        _ = long.add(crawl, flash: false, byDay: false)
        #expect(long.release(at: 607, open: [Self.track(from: 600, seconds: 7, at: 610, 300, moving: 1, 0)]).count == 1)
        // Everything at once (a gap, a restart, the stop).
        #expect(hold.flush().count == SkyStitchHold.longestHeld && hold.isEmpty)
    }

    @Test func flashesInALineAreAChainAndAFlashAloneIsNothing() throws {
        // A distant plane's strobe caught as flashes (tracks the tracker dropped: they barely moved), one every 2 s along a line at 5 px/s.
        var hold = SkyStitchHold(picture: Self.dual)
        let flashes = (0..<4).map { k in Self.track(from: 100 + Double(k) * 2, seconds: 0.4, at: 300 + Double(k) * 10, 300, moving: 0.5, 0) }
        for flash in flashes { _ = hold.add(flash, flash: true, byDay: false) }
        #expect(hold.count == 1)
        let chain = try #require(hold.flush().first?.track())
        #expect(chain.kind == .flash && chain.pieces == 4 && chain.track.samples.count == 12)
        // A flash alone, or two: nothing to log (the tracker dropped them, and they were handed over as such).
        var few = SkyStitchHold(picture: Self.dual)
        for flash in flashes.prefix(2) { _ = few.add(flash, flash: true, byDay: false) }
        #expect(few.flush().allSatisfy { $0.track() == nil })
        // Flashes that stay on one spot (a star twinkling) are no chain that moved.
        var star = SkyStitchHold(picture: Self.dual)
        for k in 0..<5 { _ = star.add(Self.track(from: 100 + Double(k) * 2, seconds: 0.4, at: 300, 300, moving: 0, 0), flash: true, byDay: false) }
        #expect(star.flush().allSatisfy { $0.track() == nil })
        // A flash on a moving light's line is part of it.
        var plane = SkyStitchHold(picture: Self.dual)
        _ = plane.add(Self.track(from: 100, seconds: 5, at: 300, 300, moving: 10, 0), flash: false, byDay: false)
        _ = plane.add(Self.track(from: 107, seconds: 0.4, at: 370, 300, moving: 0.5, 0), flash: true, byDay: false)
        let light = try #require(plane.flush().first?.track())
        #expect(light.kind == .track && light.pieces == 2)
    }

    // MARK: Older logs, as they are read

    static let camera = SkyLogStoreTests.camera

    /// A logged light: from `start` for `seconds`, its path five points a second (at most 64, as kept) from (x, y) at (vx, vy) analysed pixels a second of
    /// a 1920 × 852 picture; measures that go with it (0.1° a pixel).
    static func logged(_ id: String, _ start: Date, seconds: Double, at x: Double, _ y: Double, moving vx: Double, _ vy: Double, label: SkyLabel = .unexplained,
                       by: SkyLabelSource? = nil, hasStill: Bool = true, brightness: Double = 400) -> SkyEntry {
        let count = max(2, Int((seconds * 5).rounded()) + 1)
        let points = (0..<count).map { k -> SkyPathPoint in
            let t = Double(k) / 5
            return SkyPathPoint(t: t, x: (x + vx * t) / 1920, y: (y + vy * t) / 852)
        }
        let speed = hypot(vx, vy) * 0.1
        let measures = SkyMeasures(azimuth: 300 + x * 0.1, elevation: 40 - y * 0.1, azimuthEnd: 300 + (x + vx * seconds) * 0.1,
                                   elevationEnd: 40 - (y + vy * seconds) * 0.1, duration: seconds, speed: speed, acceleration: 0, turnRate: 0, maxTurn: 2,
                                   straightness: 0.99, shape: .straight, sizeDegrees: 0.3, brightness: brightness, blinks: false, blinkRate: nil, focus: 0.6)
        return SkyEntry(id: id, camera: camera, kind: .track, start: start, end: start.addingTimeInterval(seconds), path: SkyStitch.evenly(points, 64),
                        measures: measures, label: label, by: by, hasStill: hasStill)
    }

    @Test func olderLogsAreJoinedAsTheyAreRead() throws {
        let night = SkyLogStoreTests.local(24, 21)
        // A plane seen in three pieces (gaps of 2 and 3 s), and another light a minute later.
        let parts = [Self.logged("u-1", night, seconds: 10, at: 200, 400, moving: 10, -2),
                     Self.logged("u-2", night.addingTimeInterval(12), seconds: 6, at: 320, 376, moving: 10, -2, hasStill: false),
                     Self.logged("u-3", night.addingTimeInterval(21), seconds: 8, at: 410, 358, moving: 10, -2)]
        let other = Self.logged("u-4", night.addingTimeInterval(60), seconds: 5, at: 900, 200, moving: -5, 5)
        let joined = SkyStitch.joined(parts + [other], picture: Self.dual, isDay: { _ in false })
        #expect(joined.map(\.id) == ["u-1", "u-4"])
        let light = try #require(joined.first)
        #expect(light.parts == ["u-1", "u-2", "u-3"] && light.pieces == 3)
        #expect(light.start == night && light.end == night.addingTimeInterval(29))
        #expect(light.path.count == SkyPathPoint.maximumPerEntry && light.path.first?.t == 0 && abs((light.path.last?.t ?? 0) - 29) < 1e-6)
        #expect(abs((light.path.first?.x ?? 0) - 200.0 / 1920) < 1e-9 && abs((light.path.last?.x ?? 0) - 490.0 / 1920) < 1e-9)
        // The measures of the whole light: from the first's start to the last's end, over its whole time, straight; its gaps are dark pictures.
        #expect(light.measures.azimuth == parts[0].measures.azimuth && light.measures.azimuthEnd == parts[2].measures.azimuthEnd)
        #expect(light.measures.duration == 29 && light.measures.straightness > 0.97 && light.measures.shape == .straight)
        #expect(abs(light.measures.speed - parts[0].measures.speed) < 0.15, "\(light.measures.speed)")
        let seen = try #require(light.measures.seenShare)
        #expect(seen > 0.8 && seen < 0.85, "\(seen): 5 s dark of 29")
        // Its picture is the part nearest its middle (14.5 s) that has one: the first (5 s) and the last (25 s) have one, the middle none.
        #expect(light.hasStill && light.stillPart?.id == "u-1" && light.stillPart?.path == parts[0].path)
        // A light that is no part of another is as it was.
        #expect(joined.last == other && other.parts.isEmpty && other.pieces == 1)
        // Nothing to join: the entries as they were.
        #expect(SkyStitch.joined([other], picture: Self.dual, isDay: { _ in false }) == [other])
    }

    @Test func aJoinedLightIsWhatItsPartsSay() throws {
        let night = SkyLogStoreTests.local(24, 21)
        var first = Self.logged("u-1", night, seconds: 10, at: 200, 400, moving: 10, -2)
        var second = Self.logged("u-2", night.addingTimeInterval(12), seconds: 30, at: 320, 376, moving: 10, -2, label: .probablePlane, by: .rule)
        second.detail = "Probable plane: it flashes every 1.2 s, like a plane’s strobe"
        // The longest piece's word, when no flight matched a part; a flight's when one did (the longest such).
        var joined = try #require(SkyStitch.joined([first, second], picture: Self.dual, isDay: { _ in false }).first)
        #expect(joined.label == .probablePlane && joined.by == .rule && joined.detail == second.detail)
        first.label = .plane
        first.by = .flight
        first.detail = "TEST123 · 35,000 ft"
        joined = try #require(SkyStitch.joined([first, second], picture: Self.dual, isDay: { _ in false }).first)
        #expect(joined.label == .plane && joined.by == .flight && joined.detail == "TEST123 · 35,000 ft" && joined.priority == nil)
        // The person's latest word on any part shows.
        first.correction = .bird
        second.correction = .plane
        let at = [first.id: night.addingTimeInterval(3_600), second.id: night.addingTimeInterval(60)]
        joined = try #require(SkyStitch.joined([first, second], picture: Self.dual, isDay: { _ in false }, corrected: at).first)
        #expect(joined.correction == .bird)
        joined = try #require(SkyStitch.joined([first, second], picture: Self.dual, isDay: { _ in false },
                                               corrected: [first.id: night, second.id: night.addingTimeInterval(7_200)]).first)
        #expect(joined.correction == .plane)
    }

    @Test func aLightLoggedWholeAndAJoinedOneAreWrittenAsTheyWere() throws {
        let night = SkyLogStoreTests.local(24, 21)
        let whole = Self.logged("u-1", night, seconds: 4, at: 200, 400, moving: 10, -2)
        let line = try String(data: SkyLogStore.makeEncoder().encode(whole), encoding: .utf8) ?? ""
        #expect(!line.contains("pieces") && !line.contains("parts") && !line.contains("stillPart"), "a light seen whole is written as it always was")
        var pieced = whole
        pieced.pieces = 3
        pieced.parts = ["u-1", "u-2"]
        pieced.stillPart = SkyStillPart(id: "u-2", path: whole.path)
        let kept = try #require(SkyLogStore.bounded(pieced))
        #expect(kept.pieces == 3 && kept.parts.isEmpty && kept.stillPart == nil, "the parts are found as the log is read, never kept")
        let read = try SkyLogStore.makeDecoder().decode(SkyEntry.self, from: SkyLogStore.makeEncoder().encode(kept))
        #expect(read.pieces == 3)
    }
}

// MARK: - The detector holds a light until nothing can continue it

@Suite(.timeLimit(.minutes(3))) struct SkyStitchDetectorTests {
    static let start = SkyFixtures.aimEpoch

    /// Pieces of a light on an arc of the left lens of a dual camera analysed 640 × 284 (so that the rules leave it unexplained: curved), 8 px/s, seen in
    /// `spans` (seconds after `start`, the stream at 100 s then); each a track as the tracker hands one over.
    static func arc(_ spans: [(from: Double, seconds: Double)]) -> [SkyTrack] {
        spans.map { span in
            let count = Int((span.seconds * 5).rounded()) + 1
            let samples = (0..<count).map { k -> SkyTrackSample in
                let t = span.from + Double(k) / 5
                let angle = -Double.pi / 2 - 0.55 + 0.05 * t
                let x = 160 + 160 * cos(angle), y = 250 + 160 * sin(angle)
                return SkyTrackSample(time: 100 + t, wallClock: start.addingTimeInterval(t), point: PixelPoint(x: x / 640, y: y / 284), area: 6, flux: 300,
                                      sharpness: 0.6, elongation: 1.2, lens: 0, significance: 3)
            }
            return SkyTrack(id: UUID(), samples: samples, streakBorn: false)
        }
    }

    @Test func aLightInPiecesIsLoggedOnceWithOnePictureOfItsMiddle() async throws {
        let rig = try SkyDetectorRig(settings: SkyDetectorTests.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        // Four pieces of one light, dark 2 s between them: the tracker hands each over as it ends; the detector holds them as one light.
        let pieces = Self.arc([(0, 4), (6, 4), (12, 4), (18, 4)])
        for piece in pieces { await rig.detector.handOver(piece, analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256) }
        #expect(await rig.detector.heldCount == 1)
        // Nothing is logged while it is held (6 s and a second after its last piece), then it is, once.
        await rig.detector.releaseHeld(at: 100 + 22 + 6.9)
        #expect(await rig.detector.heldCount == 1)
        await rig.detector.settle(releasingHeld: false)
        await rig.log.flush()
        #expect(rig.log.read(camera: SkyDetectorRig.camera, night: rig.night(Self.start), folder: rig.recordings.url).entries.isEmpty)
        await rig.detector.releaseHeld(at: 100 + 22 + 7.1)
        #expect(await rig.detector.heldCount == 0)
        let entries = await rig.logged().entries
        #expect(entries.count == 1, "\(entries.map(\.id))")
        let entry = try #require(entries.first)
        #expect(entry.pieces == 4 && entry.kind == .track && entry.parts.isEmpty)
        #expect(entry.start == Self.start && entry.end == Self.start.addingTimeInterval(22))
        #expect(entry.path.count == SkyPathPoint.maximumPerEntry && entry.path.first?.t == 0 && entry.path.last?.t == 22)
        // Its blinking is measured from its gaps: three dark stretches.
        #expect(entry.measures.blinks && entry.measures.duration == 22 && (entry.measures.seenShare ?? 1) < 0.8, "\(entry.measures)")
        // One picture, of the middle of the whole light.
        #expect(entry.label == .unexplained && entry.hasStill, "\(entry.label)")
        #expect(rig.stillsAsked.value == [Self.start.addingTimeInterval(11)], "\(rig.stillsAsked.value.map { $0.timeIntervalSince(Self.start) })")
        await rig.detector.stop()
    }

    @Test func aLightWhoseMiddleTheRingNoLongerHoldsIsLeftForTheRecordingToPicture() async throws {
        let rig = try SkyDetectorRig(settings: SkyDetectorTests.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        // Held 7 s after its end, a light of 22 s has its middle 18 s back: the camera's ring (its last 12 s or so) answers with its oldest picture,
        // well after the middle. It is logged without one, and the recording gives the picture of its middle later (`SkyStillBackfill`).
        rig.stillLate.set(12)
        for piece in Self.arc([(0, 4), (6, 4), (12, 4), (18, 4)]) {
            await rig.detector.handOver(piece, analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256)
        }
        await rig.detector.releaseHeld(at: 100 + 22 + 7.1)
        var entries = await rig.logged().entries
        #expect(entries.count == 1 && entries.first?.label == .unexplained && entries.first?.hasStill == false, "\(entries.map(\.hasStill))")
        // A picture between keyframes, a few seconds from the middle of a short light, is its picture.
        rig.stillLate.set(3)
        for piece in Self.arc([(30, 4)]) { await rig.detector.handOver(piece, analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256) }
        await rig.detector.releaseHeld(at: 100 + 34 + 7.1)
        entries = await rig.logged().entries
        #expect(entries.count == 2 && entries.last?.label == .unexplained && entries.last?.hasStill == true, "\(entries.map { ($0.label, $0.hasStill) })")
        await rig.detector.stop()
    }

    @Test func aGapReleasesWhatIsHeldAndTheStopDropsIt() async throws {
        let rig = try SkyDetectorRig(settings: SkyDetectorTests.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        let pieces = Self.arc([(0, 4), (6, 4)])
        for piece in pieces { await rig.detector.handOver(piece, analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256) }
        // A gap in the stream: nothing after it continues the light, which is logged as it is.
        await rig.detector.gap(at: Self.start.addingTimeInterval(11), reason: "the camera's stream was reconnected")
        #expect(await rig.detector.heldCount == 0)
        await rig.detector.settle(releasingHeld: false)
        await rig.log.flush()
        let logged = rig.log.read(camera: SkyDetectorRig.camera, night: rig.night(Self.start), folder: rig.recordings.url).entries
        #expect(logged.count == 1 && logged.first?.pieces == 2)
        // The stop lets go of what is held at once, to the queue, whose waiting lights the stop drops (the quick stop: Ruling S27).
        for piece in Self.arc([(40, 4)]) { await rig.detector.handOver(piece, analysisWidth: 640, analysisHeight: 284, pictureWidth: 4256) }
        #expect(await rig.detector.heldCount == 1)
        let clock = ContinuousClock()
        let stopping = clock.now
        await rig.detector.stop()
        #expect(clock.now - stopping < SkyCameraDetector.stopPatience + .seconds(1))
        #expect(await rig.detector.heldCount == 0)
    }

    @Test func aLightThatFadesTwiceIsOneEntry() async throws {
        // End to end: pictures of a light that goes dark twice for 2.2 s (longer than the tracker coasts): three tracks, one entry.
        let rig = try SkyDetectorRig(settings: SkyDetectorTests.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        var scene = SkyScene(model: SkyDetectorTests.dualModel, start: Self.start)
        let path = SkyPath(start: SkyDirection(azimuth: 20, elevation: 35), bearing: Double.pi / 2, legs: [SkyPath.Leg(duration: 20, speed: 1, turnRate: 4)])
        let light = scene.along(path, from: 2)
        scene.lights = [{ date in
            let into = date.timeIntervalSince(Self.start) - 2
            return (6..<8.2).contains(into) || (12..<14.2).contains(into) ? nil : light(date)
        }]
        await rig.play(scene, 0..<130)
        let entries = await rig.logged().entries
        #expect(entries.count == 1, "\(entries.map { ($0.start.timeIntervalSince(Self.start), $0.end.timeIntervalSince(Self.start), $0.pieces) })")
        let entry = try #require(entries.first)
        #expect(entry.pieces == 3 && entry.end.timeIntervalSince(entry.start) > 18, "\(entry.pieces) \(entry.end.timeIntervalSince(entry.start))")
        #expect(rig.stillsAsked.value.count <= 1, "one picture at most")
        await rig.detector.stop()
    }
}

// MARK: - Older logs, joined as the night is read

@Suite(.timeLimit(.minutes(2))) struct SkyStitchNightLogTests {
    typealias Rig = SkyNightLogEngineTests.Rig

    /// A plane in three pieces at 9 PM (gaps of 2 and 3 s) in a 1920 × 1080 picture (the test camera's), with a picture for the first and the last, and
    /// another light a minute later.
    static func night() -> (parts: [SkyEntry], other: SkyEntry) {
        let start = SkyLogStoreTests.local(24, 21)
        func logged(_ id: String, _ seconds: Double, from: Double, hasStill: Bool) -> SkyEntry {
            var entry = SkyStitchTests.logged(id, start.addingTimeInterval(from), seconds: seconds, at: 200 + 10 * from, 400 - 2 * from, moving: 10, -2,
                                              hasStill: hasStill)
            entry.camera = SkyNightLogEngineTests.camera
            entry.path = entry.path.map { SkyPathPoint(t: $0.t, x: $0.x, y: $0.y * 852 / 1080) }
            return entry
        }
        var other = logged("u-4", 5, from: 60, hasStill: false)
        other.path = [SkyPathPoint(t: 0, x: 0.7, y: 0.2), SkyPathPoint(t: 5, x: 0.68, y: 0.22)]
        return ([logged("u-1", 10, from: 0, hasStill: true), logged("u-2", 6, from: 12, hasStill: false), logged("u-3", 8, from: 21, hasStill: true)], other)
    }

    static func lines(_ rig: Rig, _ night: String) throws -> [String] {
        try SkyLogStoreTests.lines(SkyLogStore.nightFile(folder: rig.recordings.url, camera: rig.cameraID, night: night)).filter { !$0.isEmpty }
    }

    @MainActor @Test func olderLogsAreOneLightAsTheyAreReadAndTheLogIsNotWritten() async throws {
        let rig = try await Rig()
        let (parts, other) = Self.night()
        for entry in parts + [other] { await rig.file(entry, still: entry.hasStill ? SkyLogStoreTests.jpeg() : nil) }
        let before = try Self.lines(rig, "2026-10-24")
        let log = try await rig.night("2026-10-24", .night)
        #expect(log.entries.map(\.id) == ["u-1", "u-4"], "\(log.entries.map(\.id))")
        let light = try #require(log.entries.first)
        #expect(light.parts == ["u-1", "u-2", "u-3"] && light.pieces == 3 && light.start == parts[0].start && light.end == parts[2].end)
        #expect(light.stillPart?.id == "u-1" && light.hasStill)
        // Logged before the rules, its parts are sorted by them as one light (`SkySortLater`, after the joining): the whole of it is judged, 29 s of it.
        #expect(light.sortedLater && light.by == .rule && abs(light.measures.duration - 29) < 0.01, "\(light.label) \(String(describing: light.by)) \(light.measures.duration)")
        #expect(log.entries.allSatisfy(\.sortedLater) && log.counts.unexplained + log.counts.explained == 2, "one light, counted once: \(log.counts)")
        #expect(try Self.lines(rig, "2026-10-24") == before, "the log stays as it was written: append-only")
    }

    @MainActor @Test func aCorrectionOnAJoinedLightIsWrittenToEveryPart() async throws {
        let rig = try await Rig()
        let (parts, other) = Self.night()
        for entry in parts + [other] { await rig.file(entry) }
        // A part's earlier word shows on the joined light.
        rig.log.recordCorrection(.plane, entryID: "u-3", camera: rig.cameraID, night: "2026-10-24", folder: rig.recordings.url, at: SkyLogStoreTests.local(25, 7))
        await rig.log.flush()
        var light = try #require(try await rig.night("2026-10-24", .night).entries.first)
        #expect(light.correction == .plane && SkyDisplay.label(light) == .plane)
        // A word on the joined light (sent with any part's id) goes to every part, and the answer is the joined light (sorted: its parts were logged
        // before the rules).
        let answer = try await BridgeTime.$taskZone.withValue(SkyNightLogEngineTests.zone) {
            try await rig.engine.correctSkyEntry(cameraID: rig.cameraID, entryID: "u-2", night: "2026-10-24", label: .bird)
        }
        #expect(answer.id == "u-1" && answer.parts == ["u-1", "u-2", "u-3"] && answer.correction == .bird && answer.sortedLater,
                "the answer is the joined light, sorted as the log reads it")
        await rig.log.flush()
        let said = try Self.lines(rig, "2026-10-24").filter { $0.contains("\"correction\"") && $0.contains("bird") }
        #expect(said.count == 3 && ["u-1", "u-2", "u-3"].allSatisfy { id in said.contains { $0.contains("\"id\":\"\(id)\"") } }, "\(said)")
        light = try #require(try await rig.night("2026-10-24", .night).entries.first)
        #expect(light.correction == .bird, "the latest word shows")
        let counts = try await rig.night("2026-10-24", .night).counts
        #expect(counts.bugsAndBirds == 1 && counts.unexplained + counts.explained == 2, "\(counts)")
        // A light the log kept whole takes the word alone.
        _ = try await BridgeTime.$taskZone.withValue(SkyNightLogEngineTests.zone) {
            try await rig.engine.correctSkyEntry(cameraID: rig.cameraID, entryID: "u-4", night: "2026-10-24", label: .satellite)
        }
        await rig.log.flush()
        #expect(try Self.lines(rig, "2026-10-24").filter { $0.contains("satellite") && $0.contains("\"correction\"") }.count == 1)
    }

    /// A light seen in pieces across sunset is a light in each view, the day's and the night's, as the page shows them; a word on one goes to its own
    /// parts, and its answer is that light.
    @MainActor @Test func aLightAcrossSunsetIsOneInEachViewAndAWordGoesToItsOwnParts() async throws {
        let rig = try await Rig()
        let observer = SkyFixtures.observer
        let day = SkyNight.logSpan(named: "2026-10-24", view: .day, observer: observer, zone: SkyNightLogEngineTests.zone)
        let night = SkyNight.logSpan(named: "2026-10-24", view: .night, observer: observer, zone: SkyNightLogEngineTests.zone)
        let sunset = night.lowerBound
        func logged(_ id: String, from: Double, seconds: Double) -> SkyEntry {
            var entry = SkyStitchTests.logged(id, sunset.addingTimeInterval(from), seconds: seconds, at: 600 + 10 * from, 400 - 2 * from, moving: 10, -2)
            entry.camera = SkyNightLogEngineTests.camera
            entry.path = entry.path.map { SkyPathPoint(t: $0.t, x: $0.x, y: $0.y * 852 / 1080) }
            return entry
        }
        // One plane along one line, gaps of 3, 3.5 and 2.5 s: two pieces before sunset, two after.
        let parts = [logged("d-1", from: -20, seconds: 8), logged("d-2", from: -9, seconds: 6), logged("n-1", from: 0.5, seconds: 5),
                     logged("n-2", from: 8, seconds: 6)]
        #expect(parts.prefix(2).allSatisfy { $0.start >= day.lowerBound && $0.start < day.upperBound } && parts.suffix(2).allSatisfy { night.contains($0.start) })
        for entry in parts { await rig.file(entry) }
        let all = SkyStitch.joined(parts, picture: SkyStitch.Picture(width: 1920, height: 1080), isDay: { _ in false })
        #expect(all.map(\.parts) == [["d-1", "d-2", "n-1", "n-2"]], "the four are one light when read together")
        let evening = try await rig.night("2026-10-24", .day).entries
        #expect(evening.map(\.id) == ["d-1"] && evening.first?.parts == ["d-1", "d-2"], "\(evening.map(\.parts))")
        let dark = try await rig.night("2026-10-24", .night).entries
        #expect(dark.map(\.id) == ["n-1"] && dark.first?.parts == ["n-1", "n-2"], "\(dark.map(\.parts))")
        let answer = try await BridgeTime.$taskZone.withValue(SkyNightLogEngineTests.zone) {
            try await rig.engine.correctSkyEntry(cameraID: rig.cameraID, entryID: "n-1", night: "2026-10-24", label: .plane)
        }
        #expect(answer.id == "n-1" && answer.parts == ["n-1", "n-2"] && answer.correction == .plane)
        await rig.log.flush()
        let said = try Self.lines(rig, "2026-10-24").filter { $0.contains("\"correction\"") && $0.contains("\"plane\"") }
        #expect(said.count == 2 && said.allSatisfy { $0.contains("\"id\":\"n-") }, "\(said)")
    }
}
