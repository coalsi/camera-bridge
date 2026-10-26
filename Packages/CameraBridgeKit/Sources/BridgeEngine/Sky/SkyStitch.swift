import Foundation

/// One light, not fifteen (the owner, 2026-10-26, after browsing the log: "a lot of events are one event just more than a few seconds, like if you look at
/// the timing of the event and the location it should understand it's one object not 15"). The tracker loses a light whenever it misses it for 1.5 s or the
/// light jumps out of its gate, and a new track begins where it shows again: a plane whose lights fade for a few seconds; a light crossing a dual camera's
/// seam (the stitch hides a strip of sky, so in the picture the light waits at the seam while it crosses, for up to 6 s on the owner's camera); a picture that
/// froze for a moment (the light shows again a little ahead of where it was); a light the tracker followed twice at once. On the owner's night of Oct 25 one
/// plane at 7:32 PM was eight entries of 2 to 39 s, one after another along one line.
///
/// `SkyStitch` says when pieces are one light, the same way live (the detector holds a light that ended until nothing can continue it: `SkyStitchHold`) and
/// when an older night is read (`joined`). Pieces are in the analysed picture's pixels (x times its width, y times its height: a pixel as wide as it is tall),
/// times in seconds of one clock.
///
/// **A piece continues a light** (`Link.next`) when:
/// - it begins after the light ends, at most `longestGap` later (or at most `longestOverlap` before it ends: the light seen twice for a moment), and ends after it;
/// - it begins where the light would be by then: the light's end (fitted over its last `lightFitTime`) carried on at its speed over the gap. Across the way the
///   light moves, within `floorPixels` and `spread` of the light's travel over the gap; along it, as much behind, and ahead by that and up to `leadTime` of its
///   travel (at most `longestLead` pixels): after a frozen picture a light shows again ahead of where it was, never behind;
/// - when both moved for `reliableTime` or more, they go the same way (within `headings`) at about the same speed (`speedRatios`): the piece's way over its
///   first `fitTime` against the light's over its last `lightFitTime` or its last `fitTime` (a turning light's way over the longer time lags its last; a
///   slow light that jitters says its way better over it). A piece too short to say
///   (or a flash) is placed by the light's motion alone, and must go its way as far as its chord can tell, no more than twice as fast (`chordPixels`,
///   `fasterAtMost`); a light too short to say is placed by the piece's own motion, carried back over the gap, and judged the same way.
///
/// Across a dual camera's seam (`Link.seam`: the light ends near the seam in one half and the piece begins near it in the other, within `seamBand` of the
/// width) the light may have waited at the seam the whole gap, and the halves are a few pixels apart there: it may begin anywhere from the light's end to
/// where the light would be, and `seamPixels` more across.
///
/// **The same light, followed twice** (`Link.sameLight`): the piece and the light are within `sameLightPixels` of each other at the pictures they share (the
/// median), and go the same way at about the same speed when both moved long enough to say. Lights side by side (a formation) are further apart than that,
/// and lights that only cross go different ways.
///
/// **By day, a light's contrail** (`Link.trail`): a light that drew a long line (`drawerTime` and `drawerPixels` or more) leaves a contrail, whose freshly lit
/// parts the tracker follows as lights of their own, forwards and backwards along the line (on the owner's morning of Oct 26 one plane made 22 entries at
/// sunrise). A piece seen by day that keeps to the line the light drew in the `trailMemory` before it (`trailShare` of its points within `trailPixels`) is
/// part of that light, but not of its path: a light's spine is its own. Never at night: a satellite train keeps to one line too, and a plane that follows
/// another a minute later is on the line the first drew a minute before, not in the last 15 s.
///
/// **Flashes** (live only: the tracks the tracker drops because they barely moved, `SkyDroppedTrack.DropReason.barelyMoved`) have no way of their own: one
/// joins a light that moves, and two a little apart (`flashSpeed` a second at most) begin a chain that the next must continue, in a line.
///
/// A light is never longer than `longestLight` (10 minutes, as the tracker splits a track). Nothing here is a real speed or size.
enum SkyStitch {
    // MARK: Values (the owner's nights of Oct 25 and 26, and the overnight prototype's `track.link`)

    /// A piece may begin at most this long after the light ended (s). The seam crossings of Oct 25 hid their light for 1.6 to 5.6 s, its fades for up to
    /// 6 s; one in five more pieces joined at 6 to 12 s, mostly faint lights low over the horizon (cars on a road, distant planes), where a longer wait also
    /// joins different lights.
    static let longestGap: TimeInterval = 6
    /// …or at most this long before it ended: the tracker followed the light twice for a moment (a frozen picture, a light that split in two).
    static let longestOverlap: TimeInterval = 1
    /// Where a piece begins may be this far from where the light would be (analysed pixels: about 0.4° on a 180° camera analysed 1,920 wide)…
    static let floorPixels = 4.0
    /// …and this share of the light's travel over the gap more.
    static let spread = 0.25
    /// Along the light's way, it may also be ahead by this much of its travel (s)…
    static let leadTime: TimeInterval = 1.5
    /// …at most this many pixels.
    static let longestLead = 30.0
    /// Two pieces that both moved go the same way within this (degrees)…
    static let headings = 30.0
    /// …at about the same speed: the piece's over the light's.
    static let speedRatios: ClosedRange<Double> = 0.5...2
    /// A piece too short in time to say which way it goes must still go the light's way as far as its chord can tell: within `headings` and the angle
    /// `floorPixels` makes across its chord (93° for a chord of 2 pixels, 57° for 8, 36° for 40: a fast piece of three pictures goes one clear way), once it is
    /// `chordPixels` long; nor may it go much faster: its chord within `floorPixels` and `fasterAtMost` times the light's travel in its time (on Oct 25 a
    /// plane's contrail in the afternoon threw off pieces of 0.2 to 0.8 s at six to fifteen times its speed along its line).
    static let chordPixels = 2.0
    static let fasterAtMost = 2.0
    /// Slower than this (analysed pixels a second, `SkyLightFilter.slowPixelsPerSecond`), a piece has no way.
    static let movingPixelsPerSecond = SkyLightFilter.slowPixelsPerSecond
    /// A piece's start is fitted over its first this long, a light's end over its last `lightFitTime`; a fit that spans `reliableTime` says which way.
    static let fitTime: TimeInterval = 3
    static let lightFitTime: TimeInterval = 6
    static let reliableTime: TimeInterval = 1.5
    /// A dual camera's seam: within this share of the width of it on either side, and this much more across.
    static let seamBand = 0.02
    static let seamPixels = 8.0
    /// The same light followed twice: the median distance at the pictures they share (pixels), over at least this many pictures of each.
    static let sameLightPixels = 4.0
    static let sharedPictures = 3
    /// Two flashes begin a chain when the second is at most this far a second from the first (pixels a second), and at least this long after it (s).
    static let flashSpeed = 6.0
    static let flashGap: TimeInterval = 0.4
    /// By day, a contrail: this share of a piece's points within this many pixels of the line the light drew in the `trailMemory` before each (and up to
    /// `trailAhead` after), the light having drawn `drawerTime` and `drawerPixels` or more.
    static let trailShare = 0.9
    static let trailPixels = 4.0
    static let trailMemory: TimeInterval = 15
    static let trailAhead: TimeInterval = 0.5
    static let drawerTime: TimeInterval = 10
    static let drawerPixels = 60.0
    /// A light is never longer than this (s): the tracker splits a track at 10 minutes, and so does this.
    static let longestLight: TimeInterval = 600
    /// Two points this close in time are one picture.
    static let samePicture: TimeInterval = 0.02

    // MARK: Pieces and lights

    /// A point of a piece: its time (s), and where in the analysed picture (pixels).
    struct Point: Sendable, Equatable {
        var t: Double
        var x: Double
        var y: Double
    }

    /// The picture the pieces were seen in: its analysed size (pixels), and a dual camera's seam (x, 0…1; nil for one lens).
    struct Picture: Sendable, Equatable {
        var width: Double
        var height: Double
        var seam: Double?

        init(width: Double, height: Double, seam: Double? = nil) {
            self.width = width.isFinite && width > 0 ? width : 1
            self.height = height.isFinite && height > 0 ? height : 1
            self.seam = seam.flatMap { $0.isFinite ? $0 : nil }
        }

        /// A point of the picture's 0…1 at time `t`, in its pixels.
        func point(t: Double, x: Double, y: Double) -> Point {
            Point(t: t, x: x * width, y: y * height)
        }

        /// Whether `a` and `b` are on either side of a dual camera's seam, each within `seamBand` of the width of it.
        func across(_ a: Point, _ b: Point) -> Bool {
            guard let seam else { return false }
            let line = seam * width, band = SkyStitch.seamBand * width
            return (a.x < line) != (b.x < line) && abs(a.x - line) <= band && abs(b.x - line) <= band
        }
    }

    /// One piece of a light: a track the tracker followed (live) or a light the log kept (read time).
    struct Piece: Sendable {
        var id: String
        /// In time order, finite.
        private(set) var points: [Point]
        /// A flash (live only): a track the tracker dropped because it barely moved.
        var flash: Bool
        /// Seen by day (the Sun at −6° or above as it began): only then can it be a contrail's.
        var byDay: Bool

        init(id: String, points: [Point], flash: Bool = false, byDay: Bool = false) {
            self.id = id
            self.points = points.filter { $0.t.isFinite && $0.x.isFinite && $0.y.isFinite }.sorted { $0.t < $1.t }
            self.flash = flash
            self.byDay = byDay
        }
    }

    /// How a piece became part of a light.
    enum Link: String, Sendable, Equatable {
        /// The light's first piece.
        case first
        /// It continues the light after a gap (or a moment's overlap).
        case next
        /// It continues the light across a dual camera's seam.
        case seam
        /// The same light, followed twice at once.
        case sameLight
        /// By day, it kept to the line the light drew: its contrail, not its path.
        case trail
    }

    /// A piece of a light, and how it joined.
    struct Part: Sendable, Equatable {
        var id: String
        var link: Link
        var flash: Bool
    }

    /// One light: its pieces in the order they joined, and its spine (the points of the pieces that are the light itself, not its contrail; one a picture,
    /// in time order).
    struct Light: Sendable {
        private(set) var parts: [Part]
        private(set) var spine: [Point]
        /// Its first and last times, over every piece.
        private(set) var start: Double
        private(set) var end: Double
        private(set) var byDay: Bool

        init(_ piece: Piece) {
            parts = [Part(id: piece.id, link: .first, flash: piece.flash)]
            spine = piece.points
            start = piece.points.first?.t ?? 0
            end = piece.points.last?.t ?? start
            byDay = piece.byDay
        }

        var spineStart: Double { spine.first?.t ?? start }
        var spineEnd: Double { spine.last?.t ?? end }
        /// Every piece is a flash: a chain of flashes (or one).
        var flashesOnly: Bool { parts.allSatisfy(\.flash) }
        /// The pieces of its path (not its contrail).
        var spineParts: [Part] { parts.filter { $0.link != .trail } }

        /// `piece` joins it, as `link` says.
        mutating func add(_ piece: Piece, as link: Link) {
            guard let first = piece.points.first, let last = piece.points.last else { return }
            parts.append(Part(id: piece.id, link: link, flash: piece.flash))
            start = min(start, first.t)
            end = max(end, last.t)
            switch link {
            case .next, .seam: spine = spine.filter { $0.t < first.t - SkyStitch.samePicture } + piece.points
            case .sameLight: spine = SkyStitch.union(spine, piece.points)
            case .first, .trail: break
            }
        }

        /// `other` joins it, as `link` says: its pieces come along (its first as `link`; all of them as its contrail's when `link` is `.trail`).
        mutating func merge(_ other: Light, as link: Link) {
            let joining = other.parts.enumerated().map { index, part in
                Part(id: part.id, link: link == .trail ? .trail : (index == 0 ? link : part.link), flash: part.flash)
            }
            parts += joining
            start = min(start, other.start)
            end = max(end, other.end)
            byDay = byDay || other.byDay
            switch link {
            case .next, .seam:
                if let first = other.spine.first { spine = spine.filter { $0.t < first.t - SkyStitch.samePicture } + other.spine }
            case .sameLight: spine = SkyStitch.union(spine, other.spine)
            case .first, .trail: break
            }
        }
    }

    /// Two time-ordered point lists as one, one point a picture (`a`'s where both have one).
    static func union(_ a: [Point], _ b: [Point]) -> [Point] {
        var out: [Point] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if j == b.count {
                out.append(a[i])
                i += 1
            } else if i == a.count {
                out.append(b[j])
                j += 1
            } else if abs(a[i].t - b[j].t) <= samePicture {
                out.append(a[i])
                i += 1
                j += 1
            } else if a[i].t < b[j].t {
                out.append(a[i])
                i += 1
            } else {
                out.append(b[j])
                j += 1
            }
        }
        return out
    }

    // MARK: The rule

    /// How a piece belongs to a light, and how well (the lower the better: the same light before a continuation, a continuation before a contrail).
    struct Match: Sendable, Equatable {
        var link: Link
        var score: Double
    }

    /// How `piece` belongs to `light`, the best way it does, or nil.
    static func match(_ piece: Piece, to light: Light, in picture: Picture) -> Match? {
        guard let first = piece.points.first, let last = piece.points.last, !light.spine.isEmpty else { return nil }
        guard last.t - light.spineStart <= longestLight, first.t <= light.end + longestGap, last.t >= light.start - longestOverlap else { return nil }
        if let distance = sameLight(piece.points, light.spine) { return Match(link: .sameLight, score: distance) }
        if let next = continuation(of: light, by: piece, in: picture) { return next }
        if piece.byDay, let share = keepsToTheLine(piece.points, drawnBy: light.spine) { return Match(link: .trail, score: 20 + (1 - share)) }
        return nil
    }

    /// How a light belongs with a light that a piece just joined (`absorbed`).
    enum Absorption: Sendable, Equatable {
        /// The same light followed twice.
        case sameLight
        /// By day, the contrail of the line the other drew.
        case trail
        /// It came first, and the other continues it (`Link.next` or `.seam`).
        case before(Link)
    }

    /// How `light` belongs with `host`, a light a piece just joined (live, a track that ended after; read time, one that began after): the same light
    /// followed twice, (by day) the contrail of the line `host` drew, or the light `host` continues (the piece found its twin first). Nil when it does not.
    static func absorbed(_ light: Light, by host: Light, in picture: Picture) -> Absorption? {
        guard !light.spine.isEmpty, !host.spine.isEmpty, light.start <= host.end + longestGap, light.end >= host.start - longestGap,
              max(light.end, host.end) - min(light.spineStart, host.spineStart) <= longestLight else { return nil }
        if sameLight(light.spine, host.spine) != nil { return .sameLight }
        if let next = continuation(of: light, by: Piece(id: "", points: host.spine, flash: host.flashesOnly, byDay: host.byDay), in: picture) {
            return .before(next.link)
        }
        if light.byDay, keepsToTheLine(light.spine, drawnBy: host.spine) != nil { return .trail }
        return nil
    }

    /// A straight line fitted over time to points (least squares): where it is at a time, its velocity (pixels a second), how long the points span and
    /// how many there are.
    struct Fit {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var span: Double
        var count: Int

        var speed: Double { hypot(vx, vy) }
        /// It moved long enough, and fast enough, to say which way.
        var reliable: Bool { count >= 3 && span >= SkyStitch.reliableTime && speed >= SkyStitch.movingPixelsPerSecond }

        init?<Points: Collection>(_ points: Points, at time: Double) where Points.Element == Point {
            guard let first = points.first else { return nil }
            let n = Double(points.count)
            let meanT = points.reduce(0) { $0 + $1.t } / n
            let meanX = points.reduce(0) { $0 + $1.x } / n
            let meanY = points.reduce(0) { $0 + $1.y } / n
            var tt = 0.0, tx = 0.0, ty = 0.0, earliest = first.t, latest = first.t
            for point in points {
                let dt = point.t - meanT
                tt += dt * dt
                tx += dt * (point.x - meanX)
                ty += dt * (point.y - meanY)
                earliest = min(earliest, point.t)
                latest = max(latest, point.t)
            }
            vx = tt > 0 ? tx / tt : 0
            vy = tt > 0 ? ty / tt : 0
            x = meanX + vx * (time - meanT)
            y = meanY + vy * (time - meanT)
            span = latest - earliest
            count = points.count
            guard x.isFinite, y.isFinite, vx.isFinite, vy.isFinite else { return nil }
        }
    }

    /// The angle between two directions in the picture (degrees, 0…180); 0 when either is nothing.
    static func angle(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
        let a = hypot(ax, ay), b = hypot(bx, by)
        guard a > 0, b > 0 else { return 0 }
        return acos(min(1, max(-1, (ax * bx + ay * by) / (a * b)))) * SkyMath.degrees
    }

    /// Whether `piece` continues `light` (see the type's notes), and how well.
    static func continuation(of light: Light, by piece: Piece, in picture: Picture) -> Match? {
        guard let end = light.spine.last, let begin = piece.points.first, let finish = piece.points.last else { return nil }
        let gap = begin.t - end.t
        guard gap >= -longestOverlap, gap <= longestGap, begin.t > light.spineStart, finish.t > end.t + samePicture else { return nil }
        let tail = light.spine.drop(while: { $0.t < end.t - lightFitTime })
        let head = piece.points.prefix(while: { $0.t <= begin.t + fitTime })
        guard let a = Fit(tail, at: end.t), let b = Fit(head, at: begin.t) else { return nil }
        let lightWay = a.reliable, pieceWay = b.reliable && !piece.flash
        let vx: Double, vy: Double
        switch (lightWay, pieceWay) {
        case (true, true):
            // Its way and speed over its last 6 s, or over its last 3 s as the piece's over its first: a turning light's way over 6 s lags its last,
            // and a slow light that jitters says its way better over 6 s.
            let last = Fit(tail.drop(while: { $0.t < end.t - fitTime }), at: end.t).flatMap { $0.reliable ? $0 : nil }
            guard [a, last].contains(where: { way in
                guard let way else { return false }
                return speedRatios.contains(b.speed / way.speed) && angle(way.vx, way.vy, b.vx, b.vy) <= headings
            }) else { return nil }
            (vx, vy) = (a.vx, a.vy)
        case (true, false):
            guard goesOn(head, a.vx, a.vy, at: a.speed) else { return nil }
            (vx, vy) = (a.vx, a.vy)
        case (false, true):
            guard goesOn(tail.drop(while: { $0.t < end.t - fitTime }), b.vx, b.vy, at: b.speed) else { return nil }
            (vx, vy) = (b.vx, b.vy)
        case (false, false):
            // Flashes: a chain of them begins with two a little apart.
            guard light.flashesOnly, piece.flash, gap >= flashGap else { return nil }
            let reach = floorPixels + flashSpeed * gap
            let distance = hypot(begin.x - end.x, begin.y - end.y)
            return distance <= reach ? Match(link: .next, score: 10 + distance / reach + gap / longestGap) : nil
        }
        // Where it begins against where the light would be: across its way and along it.
        let speed = hypot(vx, vy)
        let from = a.count >= 3 ? Point(t: end.t, x: a.x, y: a.y) : end
        let to = b.count >= 3 ? Point(t: begin.t, x: b.x, y: b.y) : begin
        let dx = to.x - (from.x + vx * gap), dy = to.y - (from.y + vy * gap)
        let along = (dx * vx + dy * vy) / speed, across = abs(dy * vx - dx * vy) / speed
        let seam = picture.across(end, begin)
        let tolerance = floorPixels + spread * speed * abs(gap)
        let acrossLimit = tolerance + (seam ? seamPixels : 0)
        let behind = tolerance + (seam ? speed * max(0, gap) : 0)
        let ahead = tolerance + min(speed * leadTime, longestLead)
        guard across <= acrossLimit, along >= -behind, along <= ahead else { return nil }
        let score = across / acrossLimit + (along < 0 ? -along / behind : along / ahead) + max(0, gap) / longestGap
        return Match(link: seam ? .seam : .next, score: 10 + score)
    }

    /// Whether points too short in time to say which way they go (in time order) may be the light that goes (vx, vy) at `speed`: they go its way as far
    /// as their chord can tell (within `headings` and the angle `floorPixels` makes across the chord, once it is `chordPixels` long), and not much faster
    /// (their chord within `floorPixels` and `fasterAtMost` times how far it goes in their time).
    private static func goesOn<Points: BidirectionalCollection>(_ points: Points, _ vx: Double, _ vy: Double, at speed: Double) -> Bool
        where Points.Element == Point {
        guard let first = points.first, let last = points.last else { return true }
        let chord = hypot(last.x - first.x, last.y - first.y)
        guard chord <= floorPixels + fasterAtMost * speed * (last.t - first.t) else { return false }
        guard chord >= chordPixels else { return true }
        return angle(last.x - first.x, last.y - first.y, vx, vy) <= headings + atan2(floorPixels, chord) * SkyMath.degrees
    }

    /// Where time-ordered `points` were at `time`, between the two around it; nil outside them.
    static func position(_ points: [Point], at time: Double) -> (x: Double, y: Double)? {
        guard let first = points.first, let last = points.last, time >= first.t - samePicture, time <= last.t + samePicture else { return nil }
        var low = 0, high = points.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if points[middle].t <= time { low = middle } else { high = middle }
        }
        let a = points[low], b = points[high]
        let share = b.t > a.t ? min(1, max(0, (time - a.t) / (b.t - a.t))) : 0
        return (a.x + (b.x - a.x) * share, a.y + (b.y - a.y) * share)
    }

    /// When two lights are one followed twice: the median distance between them at the pictures they share (each one's points against where the other was
    /// then, at least `sharedPictures` of each) over `sameLightPixels`; and, when both moved long enough around then to say, the same way at about the same
    /// speed. Nil when they are not.
    static func sameLight(_ a: [Point], _ b: [Point]) -> Double? {
        guard let a0 = a.first, let a1 = a.last, let b0 = b.first, let b1 = b.last else { return nil }
        let from = max(a0.t, b0.t), to = min(a1.t, b1.t)
        guard to >= from else { return nil }
        let sharedA = a.filter { $0.t >= from - samePicture && $0.t <= to + samePicture }
        let sharedB = b.filter { $0.t >= from - samePicture && $0.t <= to + samePicture }
        guard sharedA.count >= sharedPictures, sharedB.count >= sharedPictures else { return nil }
        var distances: [Double] = []
        for point in sharedB { if let there = position(a, at: point.t) { distances.append(hypot(point.x - there.x, point.y - there.y)) } }
        for point in sharedA { if let there = position(b, at: point.t) { distances.append(hypot(point.x - there.x, point.y - there.y)) } }
        guard !distances.isEmpty else { return nil }
        distances.sort()
        let median = distances[distances.count / 2]
        guard median <= sameLightPixels else { return nil }
        // Their ways around the time they share: lights that only cross go different ways.
        let around = { (points: [Point]) in points.filter { $0.t >= from - fitTime && $0.t <= to + fitTime } }
        if let fa = Fit(around(a), at: from), let fb = Fit(around(b), at: from), fa.reliable, fb.reliable {
            guard speedRatios.contains(fb.speed / fa.speed), angle(fa.vx, fa.vy, fb.vx, fb.vy) <= headings else { return nil }
        }
        return median / sameLightPixels
    }

    /// By day, the share of `points` that keep to the line `drawer` drew in the `trailMemory` before each of them (and up to `trailAhead` after), when it
    /// is `trailShare` or more and the drawer drew a long line (`drawerTime`, `drawerPixels`); nil otherwise. The points begin no earlier than a second
    /// before the drawer, and at most `longestGap` after it ended.
    static func keepsToTheLine(_ points: [Point], drawnBy drawer: [Point]) -> Double? {
        guard let d0 = drawer.first, let d1 = drawer.last, d1.t - d0.t >= drawerTime, hypot(d1.x - d0.x, d1.y - d0.y) >= drawerPixels,
              let p0 = points.first, p0.t >= d0.t - 1, p0.t <= d1.t + longestGap else { return nil }
        var near = 0
        for point in points where distance(point, toLineOf: drawer, from: point.t - trailMemory, to: point.t + trailAhead) <= trailPixels { near += 1 }
        let share = Double(near) / Double(points.count)
        return share >= trailShare ? share : nil
    }

    /// How far `point` is from the line through the time-ordered `points` between `from` and `to` (pixels); infinity when there is none.
    private static func distance(_ point: Point, toLineOf points: [Point], from: Double, to: Double) -> Double {
        var low = 0, high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].t < from { low = middle + 1 } else { high = middle }
        }
        var best = Double.infinity
        var index = low
        while index < points.count, points[index].t <= to {
            let a = points[index]
            if index + 1 < points.count, points[index + 1].t <= to {
                let b = points[index + 1]
                let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
                let share = length > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0
                best = min(best, hypot(point.x - a.x - share * dx, point.y - a.y - share * dy))
            } else {
                best = min(best, hypot(point.x - a.x, point.y - a.y))
            }
            index += 1
        }
        return best
    }

    // MARK: Joining

    /// Pieces joined into lights as they come (`add`): read time in the order they began, live in the order they ended.
    struct Joiner: Sendable {
        let picture: Picture
        private(set) var lights: [Light] = []

        init(picture: Picture) {
            self.picture = picture
        }

        /// `piece` joins the light it belongs to best, and then every light that belongs with that one (the same light followed twice, or by day the
        /// contrail of the line it drew) comes too; else it begins a light of its own. Returns its light's index.
        @discardableResult
        mutating func add(_ piece: Piece) -> Int {
            var host: (index: Int, match: Match)?
            for (index, light) in lights.enumerated() {
                guard let match = SkyStitch.match(piece, to: light, in: picture), host.map({ match.score < $0.match.score }) ?? true else { continue }
                host = (index, match)
            }
            var index: Int
            if let host {
                lights[host.index].add(piece, as: host.match.link)
                index = host.index
            } else {
                lights.append(Light(piece))
                index = lights.count - 1
            }
            // The lights that belong with it now: the same light followed twice, the contrail of the line it drew, the light it continues.
            var found = true
            while found {
                found = false
                for other in lights.indices where other != index {
                    guard let how = SkyStitch.absorbed(lights[other], by: lights[index], in: picture) else { continue }
                    switch how {
                    case .sameLight, .trail:
                        let taken = lights.remove(at: other)
                        if other < index { index -= 1 }
                        lights[index].merge(taken, as: how == .trail ? .trail : .sameLight)
                    case .before(let link):
                        let taken = lights.remove(at: index)
                        let earlier = other < index ? other : other - 1
                        lights[earlier].merge(taken, as: link)
                        index = earlier
                    }
                    found = true
                    break
                }
            }
            return index
        }

        /// Takes the light at `index` out.
        mutating func remove(at index: Int) -> Light {
            lights.remove(at: index)
        }

        /// Takes out every light that ended before `time` (s): read time, no piece that begins at `time` or later can join one.
        mutating func closed(before time: Double) -> [Light] {
            let gone = lights.filter { $0.end < time }
            lights.removeAll { $0.end < time }
            return gone
        }
    }
}
