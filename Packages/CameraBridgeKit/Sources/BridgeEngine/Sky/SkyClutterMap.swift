import Foundation

/// Where in the busy-spot map's tiles a track was seen (`SkyClutterMap.footprint`): the tile it began in, the one it was seen in most (a sample
/// a picture, so the most time), and every tile it was seen in.
struct SkyClutterFootprint: Sendable, Equatable {
    var start: Int
    var most: Int
    var tiles: Set<Int>
}

/// The busy spots of a sky camera's picture: the places that keep making tracks that are not lights. On the owner's camera, the afternoon of
/// 2026-10-25, tree tops, roof lines and shimmer just above the ground cut made about 2,500 "unexplained" entries in 70 minutes, nearly all in a
/// few tiles at the picture's left edge. A real light seldom begins and ends at one spot: planes and satellites cross it, about two or three
/// tracks an hour come from any one place of the sky at the most.
///
/// - **Counted** per tile of the analysed picture (the analyzer's own, `tileSize` 64 pixels): every ended track, kept or dropped by the tracker,
///   that no flight explains, counts in the tile it began in and in the one it was seen in most (once when they are the same).
/// - **A score that decays**: each count is worth 1 when it is made and less as it ages (`timeConstant`: to 1/e in two hours, half in 83
///   minutes), at most `maximumScore`. A tile is **busy** once its score reaches `busyAt` (ten tracks in a short while; about five an hour
///   kept up), and stays busy until it falls under `quietBelow`: ten tracks at once are quiet again after 83 minutes, an afternoon of them
///   (the score held at 20) within 2.8 hours of the last. A real sky's three tracks an hour at one spot keep a score of about 6.5.
/// - **What it does** (`SkyCameraDetector`): a light that nothing explains and that began and stayed in busy tiles (`covers`) is not logged, only
///   counted. A light that crosses out of the busy tiles is logged, and a plane is a plane wherever it was: over a wire or the tree line a real
///   light is still logged, which a mask would not do (the overnight lesson).
///
/// Kept in memory and in `<data>/sky/<camera-uuid>/clutter.json` (0600, `fileName`) beside the aim, so a restart does not learn it again from
/// nothing; a changed card (Ruling S25) or another analysed size starts it afresh. It holds tiles, scores and times, and nothing of the place.
struct SkyClutterMap: Codable, Sendable, Equatable {
    static let tileSize = SkyFrameAnalyzer.tileSize
    static let busyAt = 10.0
    static let quietBelow = 5.0
    static let maximumScore = 20.0
    static let timeConstant: TimeInterval = 7_200
    static let fileName = "clutter.json"
    /// A tile whose score has fallen under this, and that is not busy, is forgotten when the map is kept.
    static let negligible = 0.01
    static let version = 1

    /// One tile's count: its score as of `at` (seconds since 1970), and whether it is busy.
    struct Tile: Sendable, Equatable {
        var score: Double
        var at: Double
        var busy: Bool
    }

    /// The analysed picture's size, in pixels.
    let width: Int
    let height: Int
    private var tiles: [Int: Tile] = [:]

    var across: Int { max(1, (width + Self.tileSize - 1) / Self.tileSize) }
    var down: Int { max(1, (height + Self.tileSize - 1) / Self.tileSize) }
    /// Nothing is counted.
    var isEmpty: Bool { tiles.isEmpty }

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }

    // MARK: Where

    /// The tile `point` (0…1 of the picture) is in: what lies on or past an edge is in the edge's tile.
    func tile(of point: PixelPoint) -> Int {
        let x = point.x.isFinite ? min(1, max(0, point.x)) : 0, y = point.y.isFinite ? min(1, max(0, point.y)) : 0
        let column = min(across - 1, Int(x * Double(width)) / Self.tileSize)
        let row = min(down - 1, Int(y * Double(height)) / Self.tileSize)
        return row * across + column
    }

    /// Where the points of a track (in the order seen) were: nil without one. A tie for the most goes to the tile it was in first.
    func footprint(of points: [PixelPoint]) -> SkyClutterFootprint? {
        let usable = points.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = usable.first else { return nil }
        var counts: [Int: Int] = [:]
        var order: [Int] = []
        for point in usable {
            let index = tile(of: point)
            if counts[index] == nil { order.append(index) }
            counts[index, default: 0] += 1
        }
        let most = order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? tile(of: first)
        return SkyClutterFootprint(start: tile(of: first), most: most, tiles: Set(order))
    }

    /// Where `track`'s samples were, in the order of their time.
    func footprint(of track: SkyTrack) -> SkyClutterFootprint? {
        footprint(of: track.samples.sorted { $0.time < $1.time }.map(\.point))
    }

    // MARK: Counting

    /// The score of `tile` at `date` (a time before its last count, after a clock that went back, does not age it).
    func score(_ tile: Int, at date: Date) -> Double {
        tiles[tile].map { Self.aged($0, to: date) } ?? 0
    }

    /// Whether `tile` is busy at `date`.
    func isBusy(_ tile: Int, at date: Date) -> Bool {
        guard let kept = tiles[tile], kept.busy else { return false }
        return Self.aged(kept, to: date) >= Self.quietBelow
    }

    /// Whether every tile of `footprint` is busy at `date`: a light that began and stayed there.
    func covers(_ footprint: SkyClutterFootprint, at date: Date) -> Bool {
        !footprint.tiles.isEmpty && footprint.tiles.allSatisfy { isBusy($0, at: date) }
    }

    /// One more track that ended at `date`, counted where it began and where it was seen most.
    mutating func learn(_ footprint: SkyClutterFootprint, at date: Date) {
        let now = date.timeIntervalSince1970
        guard now.isFinite else { return }
        for index in Set([footprint.start, footprint.most]) where index >= 0 && index < across * down {
            var tile = tiles[index] ?? Tile(score: 0, at: now, busy: false)
            let aged = Self.aged(tile, to: date)
            if tile.busy && aged < Self.quietBelow { tile.busy = false }
            tile.score = min(Self.maximumScore, aged + 1)
            tile.at = max(tile.at, now)
            if tile.score >= Self.busyAt { tile.busy = true }
            tiles[index] = tile
        }
    }

    /// The busy tiles at `date`, in order.
    func busyTiles(at date: Date) -> [Int] {
        tiles.keys.filter { isBusy($0, at: date) }.sorted()
    }

    /// How many spots are busy at `date`: groups of busy tiles that touch, side or corner (a tree line across the picture is one).
    func busySpots(at date: Date) -> Int {
        var left = Set(busyTiles(at: date))
        var spots = 0
        while let seed = left.first {
            spots += 1
            left.remove(seed)
            var stack = [seed]
            while let tile = stack.popLast() {
                let row = tile / across, column = tile % across
                for rowStep in -1...1 {
                    for columnStep in -1...1 where rowStep != 0 || columnStep != 0 {
                        let neighbourRow = row + rowStep, neighbourColumn = column + columnStep
                        guard neighbourRow >= 0, neighbourRow < down, neighbourColumn >= 0, neighbourColumn < across else { continue }
                        if left.remove(neighbourRow * across + neighbourColumn) != nil { stack.append(neighbourRow * across + neighbourColumn) }
                    }
                }
            }
        }
        return spots
    }

    /// Forgets the tiles that count for nothing any more at `date` (kept small on the disk).
    mutating func forgetQuietTiles(at date: Date) {
        tiles = tiles.filter { $0.value.busy || Self.aged($0.value, to: date) >= Self.negligible }
    }

    /// What the camera's status says of them: "Ignoring 3 busy spots (trees, wires or glare)"; nil for none.
    static func note(spots: Int) -> String? {
        guard spots > 0 else { return nil }
        return spots == 1 ? "Ignoring 1 busy spot (trees, wires or glare)" : "Ignoring \(spots) busy spots (trees, wires or glare)"
    }

    private static func aged(_ tile: Tile, to date: Date) -> Double {
        let elapsed = date.timeIntervalSince1970 - tile.at
        guard elapsed.isFinite, elapsed > 0 else { return tile.score }
        return tile.score * exp(-elapsed / timeConstant)
    }

    // MARK: Kept

    private enum CodingKeys: String, CodingKey { case v, width, height, tiles }

    /// A tile as kept: its index, score, time (seconds since 1970) and whether it is busy.
    private struct Kept: Codable {
        var i: Int
        var s: Double
        var t: Double
        var b: Bool
    }

    /// A map that cannot be read is an empty one of its size; a tile that is not in the grid, or not numbers, is left out.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .width), height = try container.decode(Int.self, forKey: .height)
        guard (1...100_000).contains(width), (1...100_000).contains(height) else {
            throw DecodingError.dataCorruptedError(forKey: .width, in: container, debugDescription: "not a picture's size")
        }
        self.init(width: width, height: height)
        let count = across * down
        for kept in (try? container.decodeIfPresent([Kept].self, forKey: .tiles)) ?? [] {
            guard kept.i >= 0, kept.i < count, kept.s.isFinite, kept.s >= 0, kept.t.isFinite else { continue }
            tiles[kept.i] = Tile(score: min(Self.maximumScore, kept.s), at: kept.t, busy: kept.b)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .v)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(tiles.sorted { $0.key < $1.key }.map { Kept(i: $0.key, s: $0.value.score, t: $0.value.at, b: $0.value.busy) }, forKey: .tiles)
    }
}
