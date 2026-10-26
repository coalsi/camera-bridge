@testable import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// Flights from a network feed: reading `aircraft.json` (`AircraftFeedParser`), keeping and polling it (`FlightHistory`,
/// `FlightFeedPoller`), finding feeds on the box's own network (`FlightFeedFinder`) and matching planes to tracks (`FlightMatcher`). Made-up
/// data only: `SkyFixtures.aircraftJSON` and `adsbFiJSON`, a made-up flight 25 km north and 25 km west of the made-up observer, and
/// 192.168.77.x feeds behind a fake `SkyHTTP`.
@Suite(.timeLimit(.minutes(2))) struct SkyFlightTests {
    typealias Flight = SkyFixtures.Flight

    static let epoch = SkyFixtures.aimEpoch
    /// When the made-up feed was received.
    static let received = Date(timeIntervalSince1970: 1_792_897_201)
    /// The made-up track begins 5 s after the made-up flight's epoch and lasts 12 s.
    static let trackStart = epoch.addingTimeInterval(5)
    static let feedURL = URL(string: "http://192.168.77.20/tar1090/data/aircraft.json")!

    // MARK: Helpers

    /// A track of `flight` as the truth camera sees it (0.1° of noise).
    private func makeTrack(of flight: Flight = Flight(), seconds: Double = 12, through truth: SkyCameraModel = SkyFixtures.truthDual,
                       noise: Double = 0.1, seed: UInt64 = 7) throws -> SkyTrack {
        var random = SkyRandom(seed: seed)
        return try #require(SkyFixtures.track(of: flight, through: truth, from: Self.trackStart, seconds: seconds, noise: noise, using: &random))
    }

    /// The matcher as the detector calls it: the track measured through the same model it is matched with.
    private func matched(_ track: SkyTrack, model: SkyCameraModel = SkyFixtures.truthDual, aim: SkyAimQuality,
                       flights: [String: [AircraftReport]]) -> FlightMatch? {
        FlightMatcher.match(track, measures: SkyFixtures.measures(of: track, model: model), model: model, aim: aim, observer: SkyFixtures.observer,
                            flights: flights)
    }

    /// The history of a feed that sent each flight's position once a second, from `from` to `to` seconds after the epoch.
    private func histories(_ list: [Flight] = [Flight()], from: Double = -5, to: Double = 25) -> [String: [AircraftReport]] {
        Dictionary(uniqueKeysWithValues: list.map { ($0.hex, $0.reports(from: Self.epoch.addingTimeInterval(from), to: Self.epoch.addingTimeInterval(to))) })
    }

    /// The flight that is where `flight` is at `Self.trackStart` and keeps going at `knots`, as another aircraft with a hex of its own.
    private func companion(of flight: Flight = Flight(), hex: String = "b2c3d4", knots: Double? = nil, eastward: Double = 0, track: Double? = nil) -> Flight {
        var other = flight
        let place = flight.position(at: Self.trackStart)
        other.hex = hex
        other.callsign = "TEST456"
        other.epoch = Self.trackStart
        other.latitude = place.latitude
        other.longitude = place.longitude + eastward
        other.knots = knots ?? flight.knots
        other.track = track ?? flight.track
        return other
    }

    /// The history of an aircraft that goes through the places `flight` does, the other way round: at each moment it is where `flight` is
    /// the same time on the other side of the track's middle, so it passes the track's middle with it and is 6° from it at the ends.
    private func backwards(_ flight: Flight = Flight(), hex: String = "b2c3d4") -> [AircraftReport] {
        let middle = Self.trackStart.addingTimeInterval(6)
        return (-5...25).map { second in
            let time = Self.epoch.addingTimeInterval(Double(second))
            var report = flight.report(at: middle.addingTimeInterval(middle.timeIntervalSince(time)))
            report.hex = hex
            report.positionTime = time
            report.trackDegrees = (flight.track + 180).truncatingRemainder(dividingBy: 360)
            return report
        }
    }

    // MARK: Reading a feed

    @Test func parsesBothFeedShapes() throws {
        let reports = AircraftFeedParser.parse(Data(SkyFixtures.aircraftJSON.utf8), receivedAt: Self.received)
        // Three of the six: the one on the ground, the one 45 s old and the one with no position are left out.
        #expect(reports.map(\.hex) == ["a0b1c2", "b1c2d3", "c2d3e4"])
        try #require(reports.count == 3)
        let first = try #require(reports.first)
        #expect(first.callsign == "TEST123", "the call sign is trimmed")
        #expect(first.latitude == 40.2250 && first.longitude == -100.3000)
        #expect(first.altitudeFeet == 35_025, "the geometric altitude, not the barometric 34,950")
        #expect(abs(first.altitudeMeters - 35_025 * 0.3048) < 1e-9)
        #expect(first.positionTime == Self.received.addingTimeInterval(-0.4), "the box's receive time less seen_pos")
        #expect(first.groundSpeedKnots == 449.7 && first.trackDegrees == 90.2)
        let second = reports[1]
        #expect(second.callsign == "TEST456" && second.altitudeFeet == 12_000, "no geometric altitude: the barometric one")
        #expect(second.positionTime == Self.received.addingTimeInterval(-1.2))
        let third = reports[2]
        #expect(third.callsign == nil && third.altitudeFeet == 8_250)
        #expect(third.positionTime == Self.received.addingTimeInterval(-29.9), "29.9 s old is still fresh")

        // adsb.fi puts the aircraft under `ac`: the same flight, at the same altitude.
        let online = AircraftFeedParser.parse(Data(SkyFixtures.adsbFiJSON.utf8), receivedAt: Self.received)
        #expect(online.count == 1 && online.first?.hex == "a0b1c2", "the one on the ground is left out")
        #expect(online.first?.altitudeFeet == first.altitudeFeet && online.first?.altitudeMeters == first.altitudeMeters)
        #expect(online.first?.callsign == "TEST123" && online.first?.positionTime == first.positionTime)
    }

    @Test func hostileFeedIsBounded() throws {
        let feed = Data(SkyFixtures.aircraftJSON.utf8)
        // A body longer than the limit is refused whole, whatever it holds; one of exactly the limit is read.
        var atLimit = feed
        atLimit.append(Data(repeating: 0x20, count: AircraftFeedParser.maximumBytes - feed.count))
        #expect(atLimit.count == AircraftFeedParser.maximumBytes)
        #expect(AircraftFeedParser.parse(atLimit, receivedAt: Self.received).count == 3)
        var over = atLimit
        over.append(0x20)
        #expect(AircraftFeedParser.parse(over, receivedAt: Self.received).isEmpty)
        var big = feed
        big.append(Data(repeating: 0x20, count: 5 << 20))
        #expect(AircraftFeedParser.parse(big, receivedAt: Self.received).isEmpty)
        #expect(AircraftFeedParser.parseFeed(big, receivedAt: Self.received) == nil && !AircraftFeedParser.isFeed(big))

        // 10,000 aircraft: the first 5,000.
        let many = (0..<10_000).map { #"{"hex":"\#(String(0x100000 + $0, radix: 16))","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1.0}"# }
        let crowd = AircraftFeedParser.parse(Data(SkyFixtures.feedJSON(many, now: 0).utf8), receivedAt: Self.received)
        #expect(crowd.count == AircraftFeedParser.maximumAircraft && AircraftFeedParser.maximumAircraft == 5_000)
        #expect(crowd.first?.hex == "100000" && crowd.last?.hex == String(0x100000 + 4_999, radix: 16))

        // Strings where numbers belong, NaN, out-of-range places and heights: those aircraft are skipped, the good one is kept.
        let good = #"{"hex":"a0b1c2","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1.0}"#
        let junk = [
            #""lat":"north","lon":-100.1,"alt_baro":30000,"seen_pos":1"#,
            #""lat":40.2,"lon":"east","alt_baro":30000,"seen_pos":1"#,
            #""lat":40.2,"lon":-100.1,"alt_baro":"high","seen_pos":1"#,
            #""lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":"soon""#,
            #""lat":"NaN","lon":-100.1,"alt_baro":30000,"seen_pos":1"#,
            #""lat":40.2,"lon":"nan","alt_baro":30000,"seen_pos":1"#,
            #""lat":40.2,"lon":-100.1,"alt_baro":"inf","seen_pos":1"#,
            #""lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":"NaN""#,
            #""lat":"-Infinity","lon":-100.1,"alt_baro":30000,"seen_pos":1"#,
            #""lat":"1e999","lon":-100.1,"alt_baro":30000,"seen_pos":1"#,
            #""lat":"0x1p5","lon":-100.1,"alt_baro":30000,"seen_pos":1"#,
            #""lat":400,"lon":-100.1,"alt_baro":30000,"seen_pos":1"#,
            #""lat":-90.0001,"lon":-100.1,"alt_baro":30000,"seen_pos":1"#,
            #""lat":40.2,"lon":181,"alt_baro":30000,"seen_pos":1"#,
            #""lat":40.2,"lon":-180.0001,"alt_baro":30000,"seen_pos":1"#,
            #""lat":40.2,"lon":-100.1,"alt_baro":1e12,"seen_pos":1"#,
            #""lat":40.2,"lon":-100.1,"alt_baro":-50000,"seen_pos":1"#,
            #""lat":40.2,"lon":-100.1,"alt_baro":9e18,"seen_pos":1"#,
            #""lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1e300"#,
            #""lat":true,"lon":-100.1,"alt_baro":30000,"seen_pos":1"#,
            #""lat":40.2,"lon":-100.1,"alt_baro":true,"seen_pos":1"#,
            #""lat":null,"lon":-100.1,"alt_baro":30000,"seen_pos":1"#,
            #""lat":[40.2],"lon":-100.1,"alt_baro":30000,"seen_pos":1"#,
            #""lat":{"v":40.2},"lon":-100.1,"alt_baro":30000,"seen_pos":1"#,
            #""lat":40.2,"lon":-100.1,"alt_baro":30000"#,
        ]
        var entries = [good]
        for (index, fields) in junk.enumerated() { entries.append(#"{"hex":"\#(String(0x200000 + index, radix: 16))",\#(fields)}"#) }
        let reports = AircraftFeedParser.parse(Data(SkyFixtures.feedJSON(entries, now: 0).utf8), receivedAt: Self.received)
        #expect(reports.map(\.hex) == ["a0b1c2"], "kept: \(reports.map(\.hex))")
        // Each alone, too: none of them gives a report.
        for (index, fields) in junk.enumerated() {
            let one = SkyFixtures.feedJSON([#"{"hex":"a0b1c2",\#(fields)}"#], now: 0)
            #expect(AircraftFeedParser.parse(Data(one.utf8), receivedAt: Self.received).isEmpty, "junk \(index): \(fields)")
        }

        // Hostile identifiers and call signs.
        let names = [
            #"{"hex":123456,"lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1}"#,
            #"{"hex":"","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1}"#,
            #"{"hex":"zzzzzz","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1}"#,
            #"{"hex":"a0b1c2d","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1}"#,
            #"{"hex":"a0b1","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1}"#,
            #"{"hex":"\#(String(repeating: "a", count: 1 << 20))","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1}"#,
            #"{"lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1}"#,
            "7", "null", #""text""#, "[]", "{}",
        ]
        #expect(AircraftFeedParser.parse(Data(SkyFixtures.feedJSON(names, now: 0).utf8), receivedAt: Self.received).isEmpty)
        let odd = #"{"hex":"a0b1c2","flight":"<script>alert(1)</script>","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1}"#
        let long = #"{"hex":"a0b1c3","flight":"\#(String(repeating: "A", count: 100_000))","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1}"#
        let odds = AircraftFeedParser.parse(Data(SkyFixtures.feedJSON([odd, long], now: 0).utf8), receivedAt: Self.received)
        #expect(odds.map(\.hex) == ["a0b1c2", "a0b1c3"], "the aircraft is kept, only its call sign is dropped")
        #expect(odds.allSatisfy { $0.callsign == nil })

        // A document that is not a feed, in every way: never a trap.
        let deepArray = String(repeating: "[", count: 200_000) + String(repeating: "]", count: 200_000)
        let deepObject = #"{"aircraft":"# + String(repeating: #"{"a":"#, count: 100_000) + "1" + String(repeating: "}", count: 100_000) + "}"
        for text in ["", " ", "x", "nul", "5", "[]", "[{}]", "{}", #"{"aircraft":5}"#, #"{"aircraft":{"a":1}}"#, #"{"aircraft":"x"}"#, #"{"ac":null}"#,
                     #"{"aircraft":[1,2,3],"ac":7}"#, "{\"aircraft\":[", "<html><body>It works!</body></html>", deepArray, deepObject,
                     String(repeating: "{", count: 1 << 20), "\u{0}\u{1}\u{2}"] {
            let reports = AircraftFeedParser.parse(Data(text.utf8), receivedAt: Self.received)
            #expect(reports.isEmpty, "\(text.prefix(30))")
        }
        for bytes in [Data([0xFF, 0xFE, 0x00]), Data([0x7B, 0xFF, 0xFF, 0x7D]), Data(repeating: 0xFF, count: 4096), Data()] {
            #expect(AircraftFeedParser.parse(bytes, receivedAt: Self.received).isEmpty)
        }
    }

    @Test func aFeedDamagedInAnyWayIsReadOrRefusedNeverTrapped() {
        // The made-up feed with bytes flipped, cut, repeated and filled with odd words: some still read, none brings the reader down.
        let original = Array(SkyFixtures.aircraftJSON.utf8)
        let words: [[UInt8]] = ["nan", "-nan", "inf", "-Infinity", "1e999", "-", "+", ".", "e", "0x", "[", "{", "]", "}", "\"", "\\", ",", ":", "\u{0}", "null",
                                "true", "99999999999999999999999999", "-0", "1E-999"].map { Array($0.utf8) }
        var random = SkyRandom(seed: 0xFEED)
        var read = 0
        for _ in 0..<600 {
            var bytes = original
            for _ in 0..<Int.random(in: 1...3, using: &random) {
                let at = Int.random(in: 0..<bytes.count, using: &random)
                switch Int.random(in: 0..<6, using: &random) {
                case 0: bytes[at] = UInt8.random(in: 0...255, using: &random)
                case 1: bytes.removeSubrange(at..<min(bytes.count, at + Int.random(in: 1...40, using: &random)))
                case 2: bytes.insert(contentsOf: words[Int.random(in: 0..<words.count, using: &random)], at: at)
                case 3: bytes.insert(contentsOf: bytes[at..<min(bytes.count, at + Int.random(in: 1...60, using: &random))], at: at)
                case 4: bytes.removeSubrange(at...)
                default: bytes[at] = words[Int.random(in: 0..<words.count, using: &random)][0]
                }
                if bytes.isEmpty { bytes = [0x7B] }
            }
            let data = Data(bytes)
            let reports = AircraftFeedParser.parse(data, receivedAt: Self.received)
            _ = AircraftFeedParser.isFeed(data)
            #expect(reports.count <= AircraftFeedParser.maximumAircraft)
            for report in reports {
                #expect(report.latitude.isFinite && report.longitude.isFinite && report.altitudeMeters.isFinite)
                #expect((-90.0...90.0).contains(report.latitude) && (-180.0...180.0).contains(report.longitude))
                #expect(report.positionTime <= Self.received && report.positionTime >= Self.received.addingTimeInterval(-30))
            }
            if !reports.isEmpty { read += 1 }
        }
        #expect(read > 40, "the damage is not always fatal: \(read) of 600 still gave aircraft")
    }

    @Test func aDocumentBuiltToBeDeepIsNotRead() {
        // Foundation's JSON reader limits nesting to 512 levels, but on a thread with a small stack (512 KB is the usual off the main
        // thread) objects nested about 480 deep already overflow it: a crash. Such a document never reaches it.
        func objects(_ depth: Int) -> String { String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth) }
        func arrays(_ depth: Int) -> String { String(repeating: "[", count: depth) + String(repeating: "]", count: depth) }
        func feed(with value: String) -> Data {
            Data(#"{"aircraft":[{"hex":"a0b1c2","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1,"x":\#(value)}]}"#.utf8)
        }
        for depth in [100, 300, 450, 480, 500, 511, 512, 513, 5_000, 200_000] {
            for value in [objects(depth), arrays(depth)] {
                #expect(AircraftFeedParser.parseFeed(feed(with: value), receivedAt: Self.received) == nil && !AircraftFeedParser.isFeed(feed(with: value)),
                        "\(depth) deep")
            }
        }
        // The limit is 16 levels, counting the feed's own three (the object, the list, the aircraft); brackets inside strings are not levels.
        #expect(AircraftFeedParser.maximumNesting == 16)
        #expect(AircraftFeedParser.nesting(of: feed(with: arrays(13))) == 16)
        #expect(AircraftFeedParser.nesting(of: feed(with: arrays(14))) > 16)
        #expect(AircraftFeedParser.parse(feed(with: arrays(13)), receivedAt: Self.received).count == 1)
        #expect(AircraftFeedParser.parse(feed(with: arrays(14)), receivedAt: Self.received).isEmpty)
        let quoted = String(repeating: "[", count: 200) + String(repeating: "{", count: 200)
        let inStrings = Data(#"{"aircraft":[{"hex":"a0b1c2","flight":"\#(quoted)","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1,"x":"\"\#(quoted)"}]}"#.utf8)
        #expect(AircraftFeedParser.nesting(of: inStrings) == 3)
        #expect(AircraftFeedParser.parse(inStrings, receivedAt: Self.received).map(\.hex) == ["a0b1c2"])
        // A real feed's deepest level is four down (the empty `mlat` and `tisb` lists of an aircraft).
        #expect(AircraftFeedParser.nesting(of: Data(SkyFixtures.aircraftJSON.utf8)) == 4)
        let last = #"{"aircraft":[{"hex":"a0b1c2","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1,"lastPosition":{"lat":40.1,"mlat":[1,[2]]}}]}"#
        #expect(AircraftFeedParser.nesting(of: Data(last.utf8)) == 6 && AircraftFeedParser.parse(Data(last.utf8), receivedAt: Self.received).count == 1)
        // Unbalanced brackets never count below nothing.
        #expect(AircraftFeedParser.nesting(of: Data("]]]}}}[[".utf8)) == 2)
        #expect(AircraftFeedParser.nesting(of: Data()) == 0)
    }

    @Test func aFeedIsRecognisedEvenWhenNoAircraftAreInIt() {
        // An empty sky is a feed (the finder counts it); a page that is not one is not.
        for text in [#"{"now":1792897200.1,"messages":0,"aircraft":[]}"#, #"{"ac":[],"msg":"No error","now":1792897200412}"#,
                     SkyFixtures.aircraftJSON, SkyFixtures.adsbFiJSON, #"{"aircraft":[1,"x",null]}"#] {
            #expect(AircraftFeedParser.isFeed(Data(text.utf8)), "\(text.prefix(40))")
            #expect(AircraftFeedParser.parseFeed(Data(text.utf8), receivedAt: Self.received) != nil)
        }
        #expect(AircraftFeedParser.parseFeed(Data(#"{"aircraft":[]}"#.utf8), receivedAt: Self.received)?.isEmpty == true)
        for text in ["", "<html></html>", "[]", #"{"aircraft":null}"#, #"{"data":[]}"#, #"{"aircraft":{}}"#, "{", "null", #"{"error":"not found"}"#] {
            #expect(!AircraftFeedParser.isFeed(Data(text.utf8)), "\(text)")
            #expect(AircraftFeedParser.parseFeed(Data(text.utf8), receivedAt: Self.received) == nil)
        }
        // `aircraft` wins over `ac` when a document has both.
        let both = #"{"aircraft":[{"hex":"a0b1c2","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1}],"ac":[]}"#
        #expect(AircraftFeedParser.parse(Data(both.utf8), receivedAt: Self.received).count == 1)
    }

    @Test func oneOddFieldNeverDropsAWholeFeed() throws {
        // Some dump1090 builds have written nan and inf where JSON has no such thing: the feed still reads, the odd value counts as missing.
        let odd = """
        {"now":1792897200.4,"aircraft":[
        {"hex":"a0b1c2","flight":"NAN123  ","alt_baro":34950,"gs":4.5e2,"track":90,"lat":40.2250,"lon":-100.3000,"seen_pos":0.4,"rssi":-nan},
        {"hex":"b1c2d3","alt_baro":inf,"lat":39.65,"lon":-99.60,"seen_pos":1.2,"rssi":-inf},
        {"hex":"c2d3e4","alt_baro":8000,"lat":NaN,"lon":-100.55,"seen_pos":2.0},
        {"hex":"d4e5f6","alt_baro":9000,"lat":40.1,"lon":-100.5,"seen_pos":2.0,"nav":-Infinity,"ok":true,"no":false,"gone":null,"x":nan}
        ]}
        """
        let reports = AircraftFeedParser.parse(Data(odd.utf8), receivedAt: Self.received)
        #expect(reports.map(\.hex) == ["a0b1c2", "d4e5f6"], "\(reports.map(\.hex))")
        #expect(reports.first?.callsign == "NAN123", "a string that says nan is left alone")
        #expect(reports.first?.groundSpeedKnots == 450, "4.5e2 is a number")
        // The odd words are not touched when they are in a string, and a plain feed does not go through this at all.
        let text = #"{"aircraft":[{"hex":"a0b1c2","flight":"inf","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1,"x":nan}]}"#
        #expect(AircraftFeedParser.parse(Data(text.utf8), receivedAt: Self.received).first?.callsign == "INF")
        // Other broken JSON stays broken.
        #expect(AircraftFeedParser.parse(Data(#"{"aircraft":[{"hex":"a0b1c2",,}]}"#.utf8), receivedAt: Self.received).isEmpty)
        #expect(AircraftFeedParser.parse(Data(#"{"aircraft":[{"hex":"a0b1c2","lat":nan}] garbage"#.utf8), receivedAt: Self.received).isEmpty)
    }

    @Test func aNumericStringIsReadAsANumber() throws {
        let text = #"{"aircraft":[{"hex":"a0b1c2","flight":"TEST123","alt_baro":"35000","gs":"450.5","track":" 90 ","lat":"40.2","lon":"-100.1","seen_pos":"0.5"}]}"#
        let report = try #require(AircraftFeedParser.parse(Data(text.utf8), receivedAt: Self.received).first)
        #expect(report.latitude == 40.2 && report.longitude == -100.1 && report.altitudeFeet == 35_000)
        #expect(report.groundSpeedKnots == 450.5 && report.trackDegrees == 90)
        #expect(report.positionTime == Self.received.addingTimeInterval(-0.5))
    }

    @Test func aPositionIsDatedFromTheBoxsClockNotTheFeeds() throws {
        // seen_pos 0 to 30 s is fresh; a little under 0 is a clock step on the feed's host (the position is now); the rest is skipped.
        let cases: [(seen: String, age: Double?)] = [
            ("0", 0), ("0.0", 0), ("12.5", 12.5), ("30", 30), ("30.001", nil), ("45", nil), ("-0.5", 0), ("-1", 0), ("-1.5", nil), ("-5", nil),
            ("null", nil), ("\"x\"", nil), ("true", nil),
        ]
        for (seen, age) in cases {
            let text = #"{"aircraft":[{"hex":"a0b1c2","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":\#(seen)}]}"#
            let reports = AircraftFeedParser.parse(Data(text.utf8), receivedAt: Self.received)
            if let age {
                #expect(reports.first?.positionTime == Self.received.addingTimeInterval(-age), "seen_pos \(seen)")
            } else {
                #expect(reports.isEmpty, "seen_pos \(seen)")
            }
        }
        // No seen_pos: the age is unknown, so the position is not used.
        let without = #"{"aircraft":[{"hex":"a0b1c2","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen":0.1}]}"#
        #expect(AircraftFeedParser.parse(Data(without.utf8), receivedAt: Self.received).isEmpty)
        // The feed's own clock is never read: a day behind, a minute ahead, absent, text, nonsense.
        for now in ["1792810800.0", "1792897260", "", "\"yesterday\"", "-1", "1e300", "null"] {
            let field = now.isEmpty ? "" : #""now":\#(now),"#
            let text = #"{\#(field)"aircraft":[{"hex":"a0b1c2","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":2.5}]}"#
            #expect(AircraftFeedParser.parse(Data(text.utf8), receivedAt: Self.received).first?.positionTime == Self.received.addingTimeInterval(-2.5), "now \(now)")
        }
    }

    @Test func heightsComeFromTheGeometricAltitudeThenTheBarometricOne() throws {
        func read(_ fields: String) -> AircraftReport? {
            let text = #"{"aircraft":[{"hex":"a0b1c2","lat":40.2,"lon":-100.1,"seen_pos":1,\#(fields)}]}"#
            return AircraftFeedParser.parse(Data(text.utf8), receivedAt: Self.received).first
        }
        #expect(read(#""alt_baro":34950,"alt_geom":35025"#)?.altitudeFeet == 35_025)
        #expect(read(#""alt_baro":34950"#)?.altitudeFeet == 34_950)
        #expect(read(#""alt_geom":35025"#)?.altitudeFeet == 35_025, "geometric only")
        #expect(read(#""alt_baro":34950,"alt_geom":"x""#)?.altitudeFeet == 34_950, "an odd geometric altitude: the barometric one")
        #expect(read(#""alt_baro":34950,"alt_geom":1e12"#)?.altitudeFeet == 34_950)
        #expect(read(#""alt_baro":"ground","alt_geom":35025"#) == nil, "on the ground is not in the sky, whatever else it says")
        #expect(read(#""alt_baro":" Ground ""#) == nil)
        #expect(read(#""alt_baro":" Ground ","alt_geom":35025"#) == nil, "whatever case, with spaces")
        #expect(read(#""alt_baro":"GROUND","alt_geom":35025"#) == nil)
        #expect(read(#""alt_geom":35025.6"#)?.altitudeFeet == 35_026, "rounded to a whole foot")
        #expect(read(#""alt_baro":-1200"#)?.altitudeFeet == -1_200, "below sea level is a place")
        #expect(read(#""alt_baro":99999"#)?.altitudeFeet == 99_999)
        #expect(read(#""alt_baro":100001"#) == nil)
        #expect(read("") == nil && read(#""alt_baro":null"#) == nil)
        let metres = try #require(read(#""alt_geom":10000"#)?.altitudeMeters)
        #expect(abs(metres - 3_048) < 1e-9, "feet times 0.3048")
        // The ground speed and track are optional, and only taken when they make sense.
        func motion(_ fields: String) -> (Double?, Double?) {
            let report = read(#""alt_baro":30000,\#(fields)"#)
            return (report?.groundSpeedKnots, report?.trackDegrees)
        }
        #expect(motion(#""gs":450.5,"track":90.2"#) == (450.5, 90.2))
        #expect(motion(#""gs":-3,"track":400"#) == (nil, nil))
        #expect(motion(#""gs":5000,"track":-1"#) == (nil, nil))
        #expect(motion(#""gs":"fast","track":"north""#) == (nil, nil))
        #expect(motion(#""gs":0,"track":360"#) == (0, 0), "360° is north")
        #expect(motion("") == (nil, nil))
        #expect(read(#""alt_baro":30000,"gs":-3"#) != nil, "an odd speed does not cost the aircraft")
    }

    @Test func anOlderDump1090FeedIsReadToo() throws {
        // dump1090-mutability, and a tar1090 that serves it, write the barometric altitude as `altitude` and the speed as `speed`. With no
        // `alt_baro` or `alt_geom` every aircraft of such a feed was left out, and a box on one matched no plane at all.
        let reports = AircraftFeedParser.parse(Data(SkyFixtures.olderAircraftJSON.utf8), receivedAt: Self.received)
        #expect(reports.map(\.hex) == ["a0b1c2", "b1c2d3", "c2d3e4"], "the one on the ground, the one 45 s old and the one with no position are left out")
        try #require(reports.count == 3)
        #expect(reports[0].altitudeFeet == 34_950 && abs(reports[0].altitudeMeters - 34_950 * 0.3048) < 1e-9)
        #expect(reports[0].callsign == "TEST123" && reports[0].positionTime == Self.received.addingTimeInterval(-0.4))
        #expect(reports[0].groundSpeedKnots == 449.7 && reports[0].trackDegrees == 90.2)
        #expect(reports[1].altitudeFeet == 12_000 && reports[1].groundSpeedKnots == 280.5 && reports[1].trackDegrees == 181.4)
        #expect(reports[2].altitudeFeet == 8_000 && reports[2].positionTime == Self.received.addingTimeInterval(-29.9))

        // Where a feed gives both shapes, the newer fields come first: the geometric altitude, the barometric one, then `altitude`; `gs`,
        // then `speed`.
        func read(_ fields: String) -> AircraftReport? {
            let text = #"{"aircraft":[{"hex":"a0b1c2","lat":40.2,"lon":-100.1,"seen_pos":1,\#(fields)}]}"#
            return AircraftFeedParser.parse(Data(text.utf8), receivedAt: Self.received).first
        }
        #expect(read(#""altitude":34000,"alt_baro":34950,"alt_geom":35025"#)?.altitudeFeet == 35_025)
        #expect(read(#""altitude":34000,"alt_baro":34950"#)?.altitudeFeet == 34_950)
        #expect(read(#""altitude":34000,"alt_baro":"x""#)?.altitudeFeet == 34_000, "an odd newer field: the older one")
        #expect(read(#""altitude":"34000""#)?.altitudeFeet == 34_000, "a number in a string")
        #expect(read(#""altitude":" Ground ""#) == nil, "on the ground, whatever case, with spaces")
        #expect(read(#""altitude":"ground","alt_geom":35025"#) == nil, "on the ground, whatever else it says")
        #expect(read(#""altitude":100001"#) == nil && read(#""altitude":null"#) == nil && read(#""altitude":"high""#) == nil)
        func motion(_ fields: String) -> (Double?, Double?) {
            let report = read(#""altitude":30000,\#(fields)"#)
            return (report?.groundSpeedKnots, report?.trackDegrees)
        }
        #expect(motion(#""speed":450.5,"track":90.2"#) == (450.5, 90.2))
        #expect(motion(#""gs":440,"speed":450.5"#) == (440, nil))
        #expect(motion(#""gs":-3,"speed":450.5"#) == (450.5, nil), "an odd ground speed: the older field")
        #expect(motion(#""speed":5000"#) == (nil, nil))
    }

    @Test func anAircraftIsReadOnceAndNamedInLowerCase() throws {
        let text = SkyFixtures.feedJSON([
            #"{"hex":"A0B1C2","flight":"first","lat":40.2,"lon":-100.1,"alt_baro":30000,"seen_pos":1}"#,
            #"{"hex":"a0b1c2","flight":"again","lat":41.2,"lon":-101.1,"alt_baro":31000,"seen_pos":1}"#,
            #"{"hex":" ~B1C2D3 ","flight":"  ab12  ","lat":40.3,"lon":-100.2,"alt_baro":3000,"seen_pos":1}"#,
        ], now: 0)
        let reports = AircraftFeedParser.parse(Data(text.utf8), receivedAt: Self.received)
        #expect(reports.map(\.hex) == ["a0b1c2", "~b1c2d3"], "the first of a hex wins, and a non-ICAO address keeps its ~")
        #expect(reports.map(\.callsign) == ["FIRST", "AB12"], "call signs are upper case")
        #expect(reports.first?.latitude == 40.2)
    }

    @Test func aCallSignIsPlainOrNone() throws {
        func callsign(_ text: String) throws -> String? {
            let aircraft: [String: Any] = ["hex": "a0b1c2", "flight": text, "lat": 40.2, "lon": -100.1, "alt_baro": 30_000, "seen_pos": 1]
            let data = try JSONSerialization.data(withJSONObject: ["aircraft": [aircraft]])
            let reports = AircraftFeedParser.parse(data, receivedAt: Self.received)
            try #require(reports.count == 1, "the aircraft is kept whatever its call sign")
            return reports[0].callsign
        }
        let plain: [(String, String)] = [("TEST123", "TEST123"), (" test123 ", "TEST123"), ("AB-12_c", "AB-12_C"), ("N1", "N1"), ("12345678", "12345678"),
                                         ("UAL1 \n", "UAL1")]
        for (text, expected) in plain { #expect(try callsign(text) == expected, "\(text)") }
        for text in ["123456789", "", "   ", "A B", "<b>x</b>", "ab/cd", "é1234", "AB;DROP", "AB\u{0}", "a\nb", "A\"B", "A'B", "a&b", "ＴＥＳＴ１２３"] {
            #expect(try callsign(text) == nil, "\(text.debugDescription)")
        }
    }

    // MARK: The history

    @Test func theHistoryKeepsAQuarterOfAnHour() async {
        let history = FlightHistory()
        let flight = Flight()
        // One report every 30 s for 20 minutes: only the last 900 s before the newest are kept.
        for second in stride(from: 0.0, through: 1_200, by: 30) { await history.add([flight.report(at: Self.epoch.addingTimeInterval(second))]) }
        let all = await history.tracks(overlapping: Self.epoch.addingTimeInterval(-10_000)...Self.epoch.addingTimeInterval(10_000))
        let times = all["a0b1c2"]?.map { $0.positionTime.timeIntervalSince(Self.epoch) } ?? []
        #expect(times.first == 300 && times.last == 1_200 && times.count == 31, "\(times)")
        #expect(times == times.sorted())
        // A different window.
        let short = FlightHistory(keep: 60)
        for second in 0...300 { await short.add([flight.report(at: Self.epoch.addingTimeInterval(Double(second)))]) }
        let kept = await short.tracks(overlapping: Self.epoch.addingTimeInterval(-10_000)...Self.epoch.addingTimeInterval(10_000))["a0b1c2"] ?? []
        #expect(kept.count == 61 && kept.first?.positionTime == Self.epoch.addingTimeInterval(240))
    }

    @Test func anAircraftThatWentQuietIsForgotten() async {
        let history = FlightHistory(keep: 100)
        var gone = Flight()
        gone.hex = "000001"
        let stays = Flight()
        await history.add([gone.report(at: Self.epoch), stays.report(at: Self.epoch)])
        #expect(await history.aircraftCount == 2)
        // Reports of the other one, long after: the quiet one has nothing left in the window.
        for second in stride(from: 0.0, through: 400, by: 20) { await history.add([stays.report(at: Self.epoch.addingTimeInterval(second))]) }
        #expect(await history.aircraftCount == 1)
        let left = await history.tracks(overlapping: Self.epoch.addingTimeInterval(-1_000)...Self.epoch.addingTimeInterval(1_000))
        #expect(Set(left.keys) == ["a0b1c2"])
    }

    @Test func aRangeGetsTheReportsInItAndTheNearestOnEitherSide() async {
        let history = FlightHistory()
        let flight = Flight()
        for second in stride(from: 0.0, through: 40, by: 10) { await history.add([flight.report(at: Self.epoch.addingTimeInterval(second))]) }
        func times(_ lower: Double, _ upper: Double) async -> [Double] {
            let found = await history.tracks(overlapping: Self.epoch.addingTimeInterval(lower)...Self.epoch.addingTimeInterval(upper))
            return found["a0b1c2"]?.map { $0.positionTime.timeIntervalSince(Self.epoch) } ?? []
        }
        #expect(await times(12, 28) == [10, 20, 30], "the one in the range and one either side")
        #expect(await times(10, 30) == [10, 20, 30], "reports on the range's edges are in it, and the neighbours are not repeated")
        #expect(await times(12, 18) == [10, 20], "no report inside: the ones round it")
        #expect(await times(-100, 100) == [0, 10, 20, 30, 40])
        #expect(await times(41, 50) == [40], "after the last: the last, to extrapolate from")
        #expect(await times(-9, -1) == [0], "before the first: the first")
        #expect(await times(1_000, 1_100).isEmpty, "far from every report (30 s is near)")
        #expect(await times(-1_100, -1_000).isEmpty)
        #expect(await times(69, 70) == [40], "30 s past the last report is the limit")
        #expect(await times(71, 72).isEmpty)
        // Another aircraft is only in the answer when something of it is near.
        var other = Flight()
        other.hex = "b1c2d3"
        await history.add([other.report(at: Self.epoch.addingTimeInterval(5))])
        let found = await history.tracks(overlapping: Self.epoch.addingTimeInterval(12)...Self.epoch.addingTimeInterval(28))
        #expect(found["b1c2d3"]?.count == 1 && found["a0b1c2"]?.count == 3)
        #expect(await history.tracks(overlapping: Self.epoch.addingTimeInterval(500)...Self.epoch.addingTimeInterval(600)).isEmpty)
    }

    @Test func theHistorySortsAndReplacesReportsByTime() async throws {
        let history = FlightHistory()
        let flight = Flight()
        // Out of order, and a second report for a time that has one: the later answer replaces it.
        var again = false
        for second in [20.0, 0, 10, 30, 10] {
            var report = flight.report(at: Self.epoch.addingTimeInterval(second))
            if second == 10 && again { report.altitudeFeet += 100 }
            again = again || second == 10
            await history.add([report])
        }
        let reports = await history.tracks(overlapping: Self.epoch...Self.epoch.addingTimeInterval(30))["a0b1c2"] ?? []
        #expect(reports.map { $0.positionTime.timeIntervalSince(Self.epoch) } == [0, 10, 20, 30])
        try #require(reports.count == 4)
        #expect(reports[1].altitudeFeet == flight.altitudeFeet + 100, "the second report of the same time won")
        // One batch with the same aircraft twice: also by time.
        await history.add([flight.report(at: Self.epoch.addingTimeInterval(40)), flight.report(at: Self.epoch.addingTimeInterval(35))])
        let more = await history.tracks(overlapping: Self.epoch...Self.epoch.addingTimeInterval(45))["a0b1c2"] ?? []
        #expect(more.map { $0.positionTime.timeIntervalSince(Self.epoch) } == [0, 10, 20, 30, 35, 40])
        // Reports that are not numbers, and times that are not dates, are not kept.
        var bad = flight.report(at: Self.epoch)
        bad.latitude = .nan
        var worse = flight.report(at: Self.epoch.addingTimeInterval(50))
        worse.positionTime = Date(timeIntervalSince1970: .infinity)
        await history.add([bad, worse])
        #expect(await history.tracks(overlapping: Self.epoch...Self.epoch.addingTimeInterval(60))["a0b1c2"]?.count == 6)
    }

    @Test func theHistoryIsBounded() async {
        let history = FlightHistory()
        // A feed that invents a new aircraft with every answer: the number of aircraft is capped, the freshest kept.
        for batch in 0..<30 {
            let time = Self.epoch.addingTimeInterval(Double(batch))
            await history.add((0..<1_000).map { index in
                var report = Flight().report(at: time)
                report.hex = String(0x300000 + batch * 1_000 + index, radix: 16)
                return report
            })
        }
        let count = await history.aircraftCount
        #expect(count <= FlightHistory.maximumAircraft && count >= FlightHistory.maximumAircraft - 1_000, "\(count)")
        let all = await history.tracks(overlapping: Self.epoch...Self.epoch.addingTimeInterval(100))
        #expect(all[String(0x300000 + 29 * 1_000, radix: 16)] != nil, "the newest are kept")
        #expect(all[String(0x300000, radix: 16)] == nil, "the oldest are not")
        // One aircraft that answers faster than it can fly: its reports are capped too.
        let one = FlightHistory(keep: 100_000)
        let flight = Flight()
        for index in 0..<3_000 { await one.add([flight.report(at: Self.epoch.addingTimeInterval(Double(index) / 10))]) }
        let kept = await one.tracks(overlapping: Self.epoch.addingTimeInterval(-1_000)...Self.epoch.addingTimeInterval(10_000))["a0b1c2"] ?? []
        #expect(kept.count == FlightHistory.maximumReports)
        #expect(kept.last?.positionTime == Self.epoch.addingTimeInterval(299.9), "the newest are kept")
    }

    @Test func aReportFarFromARangeIsNoNeighbourOfIt() async {
        let history = FlightHistory(keep: 10_000)
        let flight = Flight()
        for second in [0.0, 100, 200] { await history.add([flight.report(at: Self.epoch.addingTimeInterval(second))]) }
        func times(_ lower: Double, _ upper: Double) async -> [Double] {
            let found = await history.tracks(overlapping: Self.epoch.addingTimeInterval(lower)...Self.epoch.addingTimeInterval(upper))
            return found["a0b1c2"]?.map { $0.positionTime.timeIntervalSince(Self.epoch) } ?? []
        }
        // Reports 95 s away on either side are not the nearest that count; the one inside the range is.
        #expect(await times(95, 105) == [100])
        #expect(await times(80, 90) == [100], "10 s before the next, and 80 s after the one before")
        #expect(await times(110, 120) == [100], "10 s after the one before, 80 s before the next")
        #expect(await times(130, 170) == [100, 200], "30 s from each is near, though none is inside")
        #expect(await times(131, 169).isEmpty, "31 s is not")
        #expect(await times(40, 60).isEmpty, "40 s from both")
    }

    @Test func oneBatchIsPrunedFromItsNewestReport() async {
        let history = FlightHistory(keep: 100)
        var old = Flight()
        old.hex = "000001"
        // In one call, one report is 1,000 s older than the other: it is outside the window of the call's newest.
        await history.add([old.report(at: Self.epoch), Flight().report(at: Self.epoch.addingTimeInterval(1_000))])
        #expect(await history.aircraftCount == 1)
        let left = await history.tracks(overlapping: Self.epoch.addingTimeInterval(900)...Self.epoch.addingTimeInterval(1_100))
        #expect(Set(left.keys) == ["a0b1c2"])
    }

    @Test func theHistoryTakesOnlyReportsThatAreAPlaceAndATime() async {
        let history = FlightHistory()
        var nameless = Flight().report(at: Self.epoch)
        nameless.hex = ""
        var south = Flight().report(at: Self.epoch)
        south.latitude = -91
        var east = Flight().report(at: Self.epoch)
        east.longitude = 180.5
        var high = Flight().report(at: Self.epoch)
        high.altitudeMeters = .infinity
        await history.add([nameless, south, east, high])
        #expect(await history.aircraftCount == 0)
        await history.add([Flight().report(at: Self.epoch)])
        #expect(await history.aircraftCount == 1)
    }

    @Test func aWindowThatIsNotANumberIsAQuarterOfAnHour() async {
        for keep in [Double.nan, .infinity, -.infinity] {
            let history = FlightHistory(keep: keep)
            let flight = Flight()
            await history.add([flight.report(at: Self.epoch)])
            await history.add([flight.report(at: Self.epoch.addingTimeInterval(500))])
            let kept = await history.tracks(overlapping: Self.epoch.addingTimeInterval(-10)...Self.epoch.addingTimeInterval(510))["a0b1c2"] ?? []
            #expect(kept.count == 2, "\(keep): 500 s apart is within 900")
            await history.add([flight.report(at: Self.epoch.addingTimeInterval(1_000))])
            let later = await history.tracks(overlapping: Self.epoch.addingTimeInterval(-10)...Self.epoch.addingTimeInterval(1_010))["a0b1c2"] ?? []
            #expect(later.count == 2, "\(keep): 1,000 s apart is not")
        }
        // A window under a second is a second.
        let tiny = FlightHistory(keep: -5)
        await tiny.add([Flight().report(at: Self.epoch)])
        await tiny.add([Flight().report(at: Self.epoch.addingTimeInterval(10))])
        #expect(await tiny.tracks(overlapping: Self.epoch.addingTimeInterval(-10)...Self.epoch.addingTimeInterval(20))["a0b1c2"]?.count == 1)
    }

    // MARK: The poller

    @Test func thePollerStopsWhenToldAndReportsProblems() async throws {
        let http = FakeSkyHTTP(pages: [:])   // every address answers 404
        let poller = FlightFeedPoller(url: Self.feedURL, http: http, history: FlightHistory(), interval: .milliseconds(10))
        #expect(await poller.problem == nil)
        #expect(await poller.lastAnswer == nil)
        await poller.start()
        #expect(await eventually { await poller.problem == "The flight feed answered 404." })
        #expect(await eventually { http.requests.value.count >= 3 }, "it keeps asking")
        #expect(http.requests.value.allSatisfy { $0.url == Self.feedURL })
        await poller.stop()
        let asked = http.requests.value.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(http.requests.value.count == asked, "no request after stop()")
        #expect(await poller.problem == "The flight feed answered 404.", "what was last wrong stays")
        await poller.stop()   // stopping again is fine
    }

    @Test func thePollerReadsTheFeedIntoTheHistory() async throws {
        let http = FakeSkyHTTP(pages: [Self.feedURL.absoluteString: (200, SkyFixtures.aircraftJSON)])
        let history = FlightHistory()
        let poller = FlightFeedPoller(url: Self.feedURL, http: http, history: history, interval: .milliseconds(10), now: { Self.received })
        await poller.start()
        #expect(await eventually { await history.aircraftCount == 3 })
        await poller.stop()
        let all = await history.tracks(overlapping: Self.received.addingTimeInterval(-100)...Self.received.addingTimeInterval(100))
        #expect(Set(all.keys) == ["a0b1c2", "b1c2d3", "c2d3e4"])
        #expect(all["a0b1c2"]?.count == 1, "the same position, polled again, is one report: it has the same time")
        #expect(all["a0b1c2"]?.first?.positionTime == Self.received.addingTimeInterval(-0.4), "the box's receive time less seen_pos")
        #expect(await poller.problem == nil)
        #expect(await poller.lastAnswer == Self.received)
        // What it asks: the address, a bounded wait, a bounded answer.
        let request = try #require(http.requests.value.first)
        #expect(request.url == Self.feedURL && request.maximumBytes == AircraftFeedParser.maximumBytes && request.timeout <= .seconds(10))
    }

    @Test func thePollerReadsAnOlderFeedIntoTheHistory() async throws {
        // A feed in dump1090-mutability's shape answers like any other: the poller saw no problem with it, and its aircraft must reach the
        // history too (they did not, and the history stayed empty).
        let http = FakeSkyHTTP(pages: [Self.feedURL.absoluteString: (200, SkyFixtures.olderAircraftJSON)])
        let history = FlightHistory()
        let poller = FlightFeedPoller(url: Self.feedURL, http: http, history: history, interval: .milliseconds(10), now: { Self.received })
        await poller.start()
        #expect(await eventually { await history.aircraftCount == 3 })
        await poller.stop()
        #expect(await poller.problem == nil)
        let all = await history.tracks(overlapping: Self.received.addingTimeInterval(-100)...Self.received.addingTimeInterval(100))
        #expect(Set(all.keys) == ["a0b1c2", "b1c2d3", "c2d3e4"])
    }

    // MARK: A feed whose planes cannot be read

    /// A made-up answer in no shape the parser knows: two aircraft with positions and ages but their heights under a key no feed writes, and
    /// one with no position.
    static let unknownShapeJSON = SkyFixtures.feedJSON([
        #"{"hex":"a0b1c2","flight":"TEST123 ","lat":40.2250,"lon":-100.3000,"seen_pos":0.4,"height_ft":34950,"spd":449.7,"track":90.2}"#,
        #"{"hex":"b1c2d3","lat":39.65,"lon":-99.60,"seen_pos":1.2,"height_ft":12000}"#,
        #"{"hex":"c2d3e4","seen":0.5,"messages":20}"#,
    ], now: 1_792_897_200.4)

    /// Made-up aircraft that are read and left out for a reason understood: one on the ground, one last placed 45 s ago.
    static let groundAndStaleJSON = SkyFixtures.feedJSON([
        #"{"hex":"d3e4f5","lat":40.0003,"lon":-100.0002,"alt_baro":"ground","seen_pos":1.0}"#,
        #"{"hex":"e4f5a6","lat":40.3,"lon":-99.9,"alt_baro":20000,"seen_pos":45.0}"#,
    ], now: 1_792_897_200.4)

    static let emptyJSON = #"{"now":1792897200.4,"messages":12,"aircraft":[]}"#

    /// The journal lines of a poller, on a router of their own.
    private final class FeedLines: LogSink {
        let entries = Box<[LogEntry]>([])
        func record(_ entry: LogEntry) { entries.update { $0.append(entry) } }
        var messages: [String] { entries.value.map(\.message) }
    }

    /// A poller of `page` (whatever it holds when asked) on a clock the test moves, writing to `lines`; `at(seconds)` moves the clock and
    /// returns once an answer has been read at that time.
    private func feedRig(_ page: Box<String>) async -> (poller: FlightFeedPoller, history: FlightHistory, lines: FeedLines,
                                                        at: (TimeInterval) async -> Void) {
        let http = FakeSkyHTTP { _ in (Data(page.value.utf8), 200) }
        let clock = Box(Self.received)
        let router = LogRouter(), lines = FeedLines()
        router.addSink(lines)
        let history = FlightHistory()
        let poller = FlightFeedPoller(url: Self.feedURL, http: http, history: history, interval: .milliseconds(5), now: { clock.value },
                                      log: Log(category: "Sky", router: router))
        await poller.start()
        return (poller, history, lines, { seconds in
            clock.set(Self.received.addingTimeInterval(seconds))
            let asked = http.requests.value.count
            _ = await eventually { http.requests.value.count >= asked + 2 }   // the first answer asked for after the move has been read
        })
    }

    @Test func aFeedReadingCountsTheAircraftItCouldRead() throws {
        // What one answer holds: the aircraft it lists, and how many of them were readable, a report or left out for a reason understood (on
        // the ground, a position too old). The rest lack a position, an age or a height the parser reads.
        let older = try #require(AircraftFeedParser.read(Data(SkyFixtures.olderAircraftJSON.utf8), receivedAt: Self.received))
        #expect(older.reports.map(\.hex) == ["a0b1c2", "b1c2d3", "c2d3e4"] && older.listed == 6 && older.readable == 5,
                "only the one with no position is not readable")
        let newer = try #require(AircraftFeedParser.read(Data(SkyFixtures.aircraftJSON.utf8), receivedAt: Self.received))
        #expect(newer.reports.count == 3 && newer.listed == 6 && newer.readable == 5)
        let unknown = try #require(AircraftFeedParser.read(Data(Self.unknownShapeJSON.utf8), receivedAt: Self.received))
        #expect(unknown.reports.isEmpty && unknown.listed == 3 && unknown.readable == 0)
        let understood = try #require(AircraftFeedParser.read(Data(Self.groundAndStaleJSON.utf8), receivedAt: Self.received))
        #expect(understood.reports.isEmpty && understood.listed == 2 && understood.readable == 2)
        let empty = try #require(AircraftFeedParser.read(Data(Self.emptyJSON.utf8), receivedAt: Self.received))
        #expect(empty.reports.isEmpty && empty.listed == 0 && empty.readable == 0)
        #expect(AircraftFeedParser.read(Data("<html><body>It works!</body></html>".utf8), receivedAt: Self.received) == nil)
        #expect(AircraftFeedParser.parseFeed(Data(SkyFixtures.olderAircraftJSON.utf8), receivedAt: Self.received) == older.reports)
    }

    @Test func aFeedWhosePlanesCannotBeReadSaysSoAfterFiveMinutes() async throws {
        // The box's feed answered, as a feed, for a day while none of its aircraft could be read, and nothing said so. Once a feed's answers
        // have listed aircraft and none of them readable for five minutes, its problem says so (the sky status shows the feed's problem), with
        // one line in the journal when that starts and one when it ends, not one an answer.
        let page = Box(Self.unknownShapeJSON)
        let rig = await feedRig(page)
        for seconds in [0.0, 120, 240, 299] { await rig.at(seconds) }
        #expect(await rig.poller.problem == nil, "under five minutes")
        #expect(await rig.history.aircraftCount == 0 && rig.lines.messages.isEmpty)
        await rig.at(300)
        #expect(await rig.poller.problem == FlightFeedPoller.unreadable)
        #expect(FlightFeedPoller.unreadable == "The flight feed answers, but none of its planes can be read (no height or position). "
                + "Check that it's dump1090, readsb, tar1090 or PiAware.")
        for seconds in [301.0, 360, 600] { await rig.at(seconds) }
        #expect(await rig.poller.problem == FlightFeedPoller.unreadable)
        #expect(rig.lines.messages == ["Sky Watcher: the flight feed answers, but none of its planes can be read (no height or position)"],
                "\(rig.lines.messages)")
        // Answers that list nothing do not end it (they say nothing about the feed's shape); one with a plane it can read does.
        page.set(Self.emptyJSON)
        await rig.at(650)
        #expect(await rig.poller.problem == FlightFeedPoller.unreadable)
        page.set(SkyFixtures.olderAircraftJSON)
        await rig.at(660)
        #expect(await rig.poller.problem == nil)
        await rig.at(670)
        #expect(rig.lines.messages.count == 2 && rig.lines.messages.last == "Sky Watcher: the flight feed's planes can be read again",
                "\(rig.lines.messages)")

        // Five minutes again, counted from after the last answer that could be read.
        page.set(Self.unknownShapeJSON)
        await rig.at(700)
        await rig.at(999)
        #expect(await rig.poller.problem == nil)
        await rig.at(1_000)
        #expect(await rig.poller.problem == FlightFeedPoller.unreadable)
        await rig.poller.stop()
        #expect(rig.lines.messages.count == 3, "\(rig.lines.messages)")
    }

    @Test func noAircraftAroundIsNoProblem() async throws {
        // An empty list is a sky with nothing in it, not a feed that cannot be read; nor are aircraft that are read and left out (on the ground,
        // last placed long ago). However long either lasts, the feed has no problem and the journal says nothing.
        let page = Box(Self.emptyJSON)
        let rig = await feedRig(page)
        for seconds in [0.0, 300, 900, 1_800] { await rig.at(seconds) }
        #expect(await rig.poller.problem == nil)
        page.set(Self.groundAndStaleJSON)
        for seconds in [1_900.0, 2_400, 3_600] { await rig.at(seconds) }
        #expect(await rig.poller.problem == nil)
        // A stretch of unreadable answers broken by more than five minutes of empty ones is not one stretch: it starts again.
        page.set(Self.unknownShapeJSON)
        await rig.at(3_700)
        page.set(Self.emptyJSON)
        await rig.at(4_100)
        page.set(Self.unknownShapeJSON)
        await rig.at(4_200)
        #expect(await rig.poller.problem == nil, "the first unreadable answer was 500 s ago, but with 400 s of empty answers after it")
        await rig.poller.stop()
        #expect(rig.lines.messages.isEmpty, "\(rig.lines.messages)")
    }

    @Test func aProblemClearsWhenTheFeedComesBack() async throws {
        let answer = Box<(status: Int, body: String)?>((503, "busy"))   // nil: unreachable
        let http = FakeSkyHTTP { _ in
            guard let now = answer.value else { throw TransportError.connectionRefused }
            return (Data(now.body.utf8), now.status)
        }
        let poller = FlightFeedPoller(url: Self.feedURL, http: http, history: FlightHistory(), interval: .milliseconds(10))
        await poller.start()
        #expect(await eventually { await poller.problem == "The flight feed answered 503." })
        answer.set(nil)
        #expect(await eventually { await poller.problem == "The flight feed could not be reached." })
        answer.set((200, "<html><body>It works!</body></html>"))
        #expect(await eventually { await poller.problem == "The flight feed answered, but not with a list of aircraft." })
        answer.set((200, SkyFixtures.aircraftJSON))
        #expect(await eventually { await poller.lastAnswer != nil })
        #expect(await eventually { await poller.problem == nil })
        answer.set((301, ""))
        #expect(await eventually { await poller.problem == "The flight feed answered 301." })
        answer.set((200, String(repeating: " ", count: 100) + #"{"aircraft":[]}"#))
        #expect(await eventually { await poller.problem == nil }, "a feed with no aircraft is still a feed")
        await poller.stop()
        // An answer too large says so, with no address in it.
        let large = FakeSkyHTTP { _ in throw HTTPClientError.bodyTooLarge(limit: AircraftFeedParser.maximumBytes) }
        let big = FlightFeedPoller(url: Self.feedURL, http: large, history: FlightHistory(), interval: .milliseconds(10))
        await big.start()
        #expect(await eventually { await big.problem == "The flight feed's answer was too large." })
        await big.stop()
        for text in [await poller.problem, await big.problem].compactMap(\.self) { #expect(!text.contains("192.168")) }
    }

    @Test func aStoppedPollerKeepsNothingThatWasInFlight() async throws {
        // An answer that is still on its way when the poller is stopped is thrown away, even from a client that ignores being cancelled.
        let history = FlightHistory()
        let started = Box(false)
        let http = FakeSkyHTTP { _ in
            started.set(true)
            try? await Task.sleep(for: .milliseconds(300))
            return (Data(SkyFixtures.aircraftJSON.utf8), 200)
        }
        let poller = FlightFeedPoller(url: Self.feedURL, http: http, history: history, interval: .milliseconds(10))
        await poller.start()
        #expect(await eventually { started.value })
        await poller.stop()
        #expect(await history.aircraftCount == 0, "nothing arrived after stop() returned")
        try await Task.sleep(for: .milliseconds(400))
        #expect(await history.aircraftCount == 0)
        #expect(http.requests.value.count == 1)
        #expect(await poller.problem == nil)
        #expect(await poller.lastAnswer == nil)
    }

    @Test func stopWaitsForARequestThatCannotBeCancelled() async throws {
        // A client that does not notice it is cancelled: its work goes on in a task of its own. stop() returns when that is over.
        let started = Box(false), finished = Box(false)
        let http = FakeSkyHTTP { _ in
            started.set(true)
            await Task { try? await Task.sleep(for: .milliseconds(300)) }.value
            finished.set(true)
            return (Data(SkyFixtures.aircraftJSON.utf8), 200)
        }
        let history = FlightHistory()
        let poller = FlightFeedPoller(url: Self.feedURL, http: http, history: history, interval: .milliseconds(10))
        await poller.start()
        #expect(await eventually { started.value })
        await poller.stop()
        #expect(finished.value, "the request that was in flight had ended when stop() returned")
        #expect(await history.aircraftCount == 0, "and what it brought was thrown away")
        #expect(http.requests.value.count == 1)
    }

    @Test func aPollerCanBeStartedAgainAndOnlyRunsOnce() async throws {
        let http = FakeSkyHTTP(pages: [Self.feedURL.absoluteString: (200, SkyFixtures.aircraftJSON)])
        let poller = FlightFeedPoller(url: Self.feedURL, http: http, history: FlightHistory(), interval: .milliseconds(100))
        await poller.start()
        await poller.start()   // a second start is nothing
        #expect(await eventually { http.requests.value.count >= 1 })
        try await Task.sleep(for: .milliseconds(450))
        await poller.stop()
        let first = http.requests.value.count
        #expect(first >= 2 && first <= 7, "one poller asking every 100 ms for about 450 ms (two would ask 9 times): \(first)")
        await poller.start()
        #expect(await eventually { http.requests.value.count > first })
        await poller.stop()
        let second = http.requests.value.count
        try await Task.sleep(for: .milliseconds(250))
        #expect(http.requests.value.count == second)
    }

    @Test func aPollerThatIsLetGoStopsAsking() async throws {
        let http = FakeSkyHTTP(pages: [:])
        var poller: FlightFeedPoller? = FlightFeedPoller(url: Self.feedURL, http: http, history: FlightHistory(), interval: .milliseconds(10))
        await poller?.start()
        #expect(await eventually { http.requests.value.count >= 2 })
        poller = nil
        try await Task.sleep(for: .milliseconds(150))
        let asked = http.requests.value.count
        try await Task.sleep(for: .milliseconds(250))
        #expect(http.requests.value.count == asked, "a poller nobody holds does not keep asking")
    }

    // MARK: Finding feeds

    static let arp = """
    IP address       HW type     Flags       HW address            Mask     Device
    192.168.77.20    0x1         0x2         2c:aa:8e:00:00:20     *        eth0
    192.168.77.21    0x1         0x0         00:00:00:00:00:00     *        eth0
    8.8.8.8          0x1         0x2         2c:aa:8e:00:00:88     *        eth0
    """

    @Test func findsFeedsOnTheNeighbours() async throws {
        // Only the complete entry of a private address is a candidate: four addresses, the ones a feed is usually served at.
        let candidates = FlightFeedFinder.candidates(neighbours: Self.arp)
        #expect(candidates.map(\.absoluteString) == [
            "http://192.168.77.20/tar1090/data/aircraft.json", "http://192.168.77.20/dump1090-fa/data/aircraft.json",
            "http://192.168.77.20/skyaware/data/aircraft.json", "http://192.168.77.20:8080/data/aircraft.json",
        ])
        let found = "http://192.168.77.20/tar1090/data/aircraft.json"
        let http = FakeSkyHTTP(pages: [found: (200, SkyFixtures.aircraftJSON)])
        let feeds = await FlightFeedFinder.find(http: http, neighbours: Self.arp)
        #expect(feeds.map(\.absoluteString) == [found])
        #expect(Set(http.urls) == Set(candidates.map(\.absoluteString)), "it asked the candidates and nothing else")
        #expect(http.requests.value.allSatisfy { $0.timeout == .milliseconds(1_500) && $0.maximumBytes == AircraftFeedParser.maximumBytes })
        #expect(await FlightFeedFinder.find(http: http, neighbours: "").isEmpty)
    }

    @Test func candidatesAreOnlyTheBoxsOwnPrivateAddresses() {
        func hosts(_ addresses: [String]) -> [String] {
            let table = "IP address HW type Flags HW address Mask Device\n" + addresses.enumerated().map {
                "\($0.element) 0x1 0x2 2c:aa:8e:00:\(String(format: "%02x", $0.offset / 256)):\(String(format: "%02x", $0.offset % 256)) * eth0"
            }.joined(separator: "\n")
            return FlightFeedFinder.candidates(neighbours: table).compactMap(\.host).reduce(into: []) { if $0.last != $1 { $0.append($1) } }
        }
        let wanted = ["10.77.0.1", "10.255.255.254", "172.16.0.1", "172.20.1.1", "172.31.255.254", "192.168.78.1", "192.168.255.254"]
        let refused = ["0.0.0.0", "1.2.3.4", "8.8.8.8", "9.255.255.255", "11.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.1.1", "172.15.255.255",
                       "172.32.0.1", "192.0.2.1", "192.167.255.255", "192.169.0.1", "198.51.100.1", "224.0.0.251", "239.255.255.250", "240.0.0.1",
                       "255.255.255.255"]
        #expect(hosts(wanted) == wanted)
        #expect(hosts(refused).isEmpty, "\(hosts(refused))")
        // Addresses that are not written plainly are not guessed at: 192.168.077.020 might be octal.
        #expect(hosts(["192.168.077.020", "192.168.77.020", "010.77.0.1", "192.168.77.01", "+192.168.77.9", "192.168.77.9.", "192.168.1"]).isEmpty)
        // The same host twice is one.
        #expect(hosts(["192.168.77.20", "192.168.77.20", "192.168.77.21"]) == ["192.168.77.20", "192.168.77.21"])
    }

    @Test func atMostSixtyFourHostsAreTried() {
        let table = (1...70).map { "192.168.77.\($0) 0x1 0x2 2c:aa:8e:00:00:\(String(format: "%02x", $0)) * eth0" }.joined(separator: "\n")
        let candidates = FlightFeedFinder.candidates(neighbours: table)
        #expect(candidates.count == 64 * FlightFeedFinder.paths.count)
        #expect(candidates.first?.host == "192.168.77.1" && candidates.last?.host == "192.168.77.64", "the first 64 of the table")
        #expect(FlightFeedFinder.maximumHosts == 64)
        #expect(FlightFeedFinder.paths == ["/tar1090/data/aircraft.json", "/dump1090-fa/data/aircraft.json", "/skyaware/data/aircraft.json",
                                           ":8080/data/aircraft.json"])
    }

    @Test func theFinderAsksFastAndFewAtATime() async throws {
        let table = (1...40).map { "192.168.77.\($0 + 100) 0x1 0x2 2c:aa:8e:00:00:\(String(format: "%02x", $0)) * eth0" }.joined(separator: "\n")
        let inFlight = Box(0), most = Box(0)
        let http = FakeSkyHTTP { _ in
            let now = inFlight.update { $0 += 1; return $0 }
            most.update { $0 = max($0, now) }
            try? await Task.sleep(for: .milliseconds(15))
            inFlight.update { $0 -= 1 }
            return (Data(), 404)
        }
        let feeds = await FlightFeedFinder.find(http: http, neighbours: table)
        #expect(feeds.isEmpty)
        #expect(http.requests.value.count == 40 * 4)
        #expect(most.value <= 8 && most.value >= 5, "eight at a time at most, and really in parallel: \(most.value)")
        #expect(FlightFeedFinder.parallel == 8 && FlightFeedFinder.timeout == .milliseconds(1_500))
    }

    /// The address a feed of the eight made-up neighbours would be at.
    static func page(_ last: Int, _ path: String = "/tar1090/data/aircraft.json") -> String { "http://192.168.77.\(20 + last)\(path)" }

    @Test func aPageIsAFeedOnlyIfItReadsAsOne() async throws {
        let table = (1...8).map { "192.168.77.\(20 + $0) 0x1 0x2 2c:aa:8e:00:00:\(String(format: "%02x", $0)) * eth0" }.joined(separator: "\n")
        let http = FakeSkyHTTP { requested in
            switch requested.absoluteString {
            case Self.page(1): return (Data(SkyFixtures.aircraftJSON.utf8), 200)
            case Self.page(2): return (Data(#"{"now":1792897200.1,"messages":0,"aircraft":[]}"#.utf8), 200)   // an empty sky is a feed
            case Self.page(3): return (Data("<html><body>It works!</body></html>".utf8), 200)
            case Self.page(4): return (Data(SkyFixtures.aircraftJSON.utf8), 404)
            case Self.page(5): return (Data(SkyFixtures.aircraftJSON.utf8), 301)
            case Self.page(6): throw TransportError.timedOut
            case Self.page(7): return (Data(SkyFixtures.adsbFiJSON.utf8), 200)
            case Self.page(8, ":8080/data/aircraft.json"): return (Data(SkyFixtures.aircraftJSON.utf8), 200)
            default: return (Data(), 404)
            }
        }
        let feeds = await FlightFeedFinder.find(http: http, neighbours: table)
        #expect(feeds.map(\.absoluteString) == [Self.page(1), Self.page(2), Self.page(7), Self.page(8, ":8080/data/aircraft.json")], "in the table's order: \(feeds)")
        // Every address is its own: two paths of one host that both answer are both listed.
        let both = FakeSkyHTTP { _ in (Data(SkyFixtures.aircraftJSON.utf8), 200) }
        let two = await FlightFeedFinder.find(http: both, neighbours: Self.arp)
        #expect(two.count == 4 && Set(two.compactMap(\.host)) == ["192.168.77.20"])
    }

    @Test func theFinderStopsWhenToldTo() async throws {
        let table = (1...30).map { "192.168.77.\($0 + 100) 0x1 0x2 2c:aa:8e:00:00:\(String(format: "%02x", $0)) * eth0" }.joined(separator: "\n")
        let http = FakeSkyHTTP { _ in
            try await Task.sleep(for: .seconds(30))
            return (Data(), 404)
        }
        let finding = Task { await FlightFeedFinder.find(http: http, neighbours: table) }
        #expect(await eventually { http.requests.value.count >= 8 })
        finding.cancel()
        let started = ContinuousClock.now
        let feeds = await finding.value
        #expect(feeds.isEmpty && ContinuousClock.now - started < .seconds(5))
        #expect(http.requests.value.count < 30 * 4, "it stopped asking")
    }

    // MARK: Matching planes to tracks

    @Test func aSyntheticPlaneTrackMatches() throws {
        let flight = Flight()
        let track = try makeTrack(of: flight)
        #expect(track.samples.count == 61 && Set(track.samples.map(\.lens)) == [0], "a made-up track of 12 s in the left lens")
        for aim in [SkyAimQuality.good, .precise] {
            let found = try #require(matched(track, aim: aim, flights: histories()), "\(aim)")
            #expect(found.hex == "a0b1c2" && found.label == .plane && found.detail == "TEST123 · 35,000 ft")
            #expect(found.score >= 0 && found.score < 0.1, "the median angular distance: \(found.score)")
            // One correspondence per sample: the track's pixel and the aircraft's direction at that moment.
            #expect(found.correspondences.count == track.samples.count)
            for (sample, correspondence) in zip(track.samples, found.correspondences) {
                #expect(correspondence.point == sample.point && correspondence.source == .plane && correspondence.object == "a0b1c2")
                #expect(correspondence.at == sample.wallClock)
                #expect(SkyMath.separation(correspondence.direction, flight.direction(at: sample.wallClock)) < 1e-6, "the aircraft's own direction")
            }
        }
        // The same flight, matched with other aircraft about: the right one.
        var others = histories()
        others["b1c2d3"] = companion(hex: "b1c2d3", eastward: 0.3).reports(from: Self.epoch.addingTimeInterval(-5), to: Self.epoch.addingTimeInterval(25))
        #expect(matched(track, aim: .good, flights: others)?.hex == "a0b1c2")
    }

    @Test func aFeedWithAWrongClockStillMatches() async throws {
        let flight = Flight()
        let track = try makeTrack(of: flight)
        // A feed polled once a second; each answer arrives half a second after the position message it carries, which says so with seen_pos.
        // The feed host's clock is 300 s ahead: its `now` is not the time of anything here.
        let history = FlightHistory()
        for second in -5...25 {
            let message = Self.epoch.addingTimeInterval(Double(second))
            let received = message.addingTimeInterval(0.5)
            let json = SkyFixtures.feedJSON([flight.entry(positionAt: message, age: 0.5)], now: received.timeIntervalSince1970 + 300)
            let reports = AircraftFeedParser.parse(Data(json.utf8), receivedAt: received)
            let report = try #require(reports.first)
            #expect(abs(report.positionTime.timeIntervalSince(message)) < 1e-6, "receivedAt − seen_pos, not the feed's now")
            await history.add(reports)
        }
        let first = try #require(track.samples.first?.wallClock), last = try #require(track.samples.last?.wallClock)
        let flights = await history.tracks(overlapping: first...last)
        let found = try #require(matched(track, aim: .good, flights: flights))
        #expect(found.hex == "a0b1c2" && found.label == .plane && found.score < 0.1)
        // The same track against a history 300 s late (what taking the feed's own clock would make) matches nothing: the test can tell.
        let late = flights.mapValues { $0.map { report -> AircraftReport in
            var shifted = report
            shifted.positionTime = report.positionTime.addingTimeInterval(300)
            return shifted
        } }
        #expect(matched(track, aim: .good, flights: late) == nil)
        #expect(matched(track, aim: .rough, flights: late) == nil)
    }

    @Test func aPlaneIsMatchedThroughAnOlderDump1090Feed() async throws {
        // A feed in dump1090-mutability's shape, polled once a second, through the parser and the history: the made-up flight explains its
        // track at the card's rough aim (about 8° off), as it does through a newer feed.
        let flight = Flight()
        let track = try makeTrack(of: flight)
        let rough = SkyCameraModel.initial(facing: 0, tilt: 20, pictureWidth: 4256, pictureHeight: 1888)
        let history = FlightHistory()
        for second in -5...25 {
            let message = Self.epoch.addingTimeInterval(Double(second)), received = message.addingTimeInterval(0.5)
            let json = SkyFixtures.feedJSON([flight.olderEntry(positionAt: message, age: 0.5)], now: received.timeIntervalSince1970)
            await history.add(AircraftFeedParser.parse(Data(json.utf8), receivedAt: received))
        }
        let first = try #require(track.samples.first?.wallClock), last = try #require(track.samples.last?.wallClock)
        let flights = await history.tracks(overlapping: first...last)
        #expect(flights.keys.sorted() == ["a0b1c2"])
        let found = try #require(matched(track, model: rough, aim: .rough, flights: flights))
        #expect(found.hex == "a0b1c2" && found.label == .probablePlane && found.detail == "TEST123 · 35,000 ft")
        #expect(found.correspondences.count == track.samples.count, "every picture is one for the fit")
    }

    @Test func aPlaneHighUpInASteepStitchedPictureMatchesAtTheRoughAim() throws {
        // A stitched dual camera tilted up 35°, one seamless panorama in its own frame (as North Sky's picture is), sees the made-up airliner
        // 5 km north and 10.7 km up, about 62° high, near the top of the picture. Through the rough card made from the camera's facing and tilt
        // it matches at the rough aim: with lenses turned about the vertical the card was more than 15° off up there (North Sky's planes at 30°
        // to 60° were 10° to 25° off), so nothing high in the sky could match before the aim was fitted.
        let truth = SkyFixtures.stitchedPanorama(facing: 0, tilt: 35)
        let card = SkyCameraModel.initial(facing: 0, tilt: 35, pictureWidth: 4256, pictureHeight: 1888)
        var high = Flight()
        high.latitude = 40.045
        high.longitude = -100.03
        let track = try makeTrack(of: high, through: truth)
        #expect(track.samples.allSatisfy { $0.point.y < 0.3 }, "high in the picture: \(track.samples.map(\.point.y).max() ?? 1)")
        let found = try #require(matched(track, model: card, aim: .rough, flights: histories([high])))
        #expect(found.hex == high.hex && found.label == .probablePlane && found.score < 6, "\(found.score)")
    }

    @Test func roughAimMatchesLooselyAndOnlyWhenUnique() throws {
        // The card's model, 8° or so from the truth.
        let rough = SkyCameraModel.initial(facing: 0, tilt: 20, pictureWidth: 4256, pictureHeight: 1888)
        let track = try makeTrack()
        let errors = track.samples.compactMap { sample in
            rough.direction(at: sample.point, lens: sample.lens).map { SkyMath.separation($0, Flight().direction(at: sample.wallClock)) }
        }
        #expect(errors.count == track.samples.count && errors.min()! > 5 && errors.max()! < 11, "about 8° off: \(errors.min()!)…\(errors.max()!)")

        let found = try #require(matched(track, model: rough, aim: .rough, flights: histories()))
        #expect(found.label == .probablePlane && found.hex == "a0b1c2" && found.detail == "TEST123 · 35,000 ft")
        #expect(found.score > 5 && found.score < 11)
        #expect(found.correspondences.count == track.samples.count, "they are the fit's to correct")
        // It is rough only while the aim is: as good, the tolerance is 1.5°.
        #expect(matched(track, model: rough, aim: .good, flights: histories()) == nil)

        // A second aircraft 6° from the first: either could be it, so neither is.
        let near = companion(hex: "b2c3d4", eastward: 0.046)
        let apart = (0...60).map { index -> Double in
            let time = Self.trackStart.addingTimeInterval(Double(index) / 5)
            return SkyMath.separation(Flight().direction(at: time), near.direction(at: time))
        }
        #expect(apart.min()! > 4 && apart.max()! < 8, "about 6° apart: \(apart.min()!)…\(apart.max()!)")
        #expect(matched(track, model: rough, aim: .rough, flights: histories([near]))?.hex == "b2c3d4", "alone, it would match too")
        #expect(matched(track, model: rough, aim: .rough, flights: histories([Flight(), near])) == nil)
        // One that is further than 15° away does not matter.
        let far = companion(hex: "b2c3d4", eastward: 0.3)
        let distant = (0...60).map { index -> Double in
            let time = Self.trackStart.addingTimeInterval(Double(index) / 5)
            return SkyMath.separation(rough.direction(at: track.samples[index].point, lens: 0)!, far.direction(at: time))
        }
        #expect(distant.min()! > 15, "\(distant.min()!)")
        #expect(matched(track, model: rough, aim: .rough, flights: histories([Flight(), far]))?.hex == "a0b1c2")
        // With a good aim a second aircraft within the tolerance is not a reason to say nothing: the better is taken.
        let beside = companion(hex: "b2c3d4", eastward: 0.0058)
        #expect(matched(track, aim: .good, flights: histories([beside, Flight()]))?.hex == "a0b1c2")
        #expect(matched(track, aim: .good, flights: histories([beside]))?.hex == "b2c3d4", "0.8° is within 1.5°")
    }

    @Test func aPlaneGoingTheOtherWayDoesNotMatch() throws {
        let track = try makeTrack()
        let back = ["b2c3d4": backwards()]
        // The same places in the opposite order: it passes the track's middle, but is 6° away at the ends and heads the wrong way.
        #expect(matched(track, aim: .good, flights: back) == nil)
        #expect(matched(track, aim: .precise, flights: back) == nil)
        // A rough aim is loose enough to take its places (about 3° off by the median); only its heading says no.
        #expect(matched(track, aim: .rough, flights: back) == nil)
        // The aircraft that goes the way the track does, at the same places, is found at every aim.
        let there = ["b2c3d4": (-5...25).map { second -> AircraftReport in
            var report = Flight().report(at: Self.epoch.addingTimeInterval(Double(second)))
            report.hex = "b2c3d4"
            return report
        }]
        for aim in [SkyAimQuality.rough, .good, .precise] { #expect(matched(track, aim: aim, flights: there)?.hex == "b2c3d4", "\(aim)") }
        // Without a ground speed and track the report still places the aircraft: the heading is the track's own against the places, not the report's.
        let bare = there.mapValues { $0.map { report -> AircraftReport in
            var bare = report
            bare.groundSpeedKnots = nil
            bare.trackDegrees = nil
            return bare
        } }
        #expect(matched(track, aim: .good, flights: bare)?.hex == "b2c3d4")
        #expect(matched(track, aim: .rough, flights: ["b2c3d4": backwards().map { var bare = $0; bare.groundSpeedKnots = nil; bare.trackDegrees = nil; return bare }]) == nil)
    }

    @Test func theHeadingMustAgreeWithin30Degrees() throws {
        // An aircraft that goes across the sky to the right at 0.3°/s, and tracks that start with it at the same speed and go off at other
        // bearings. A rough aim is loose about places (all of these are within 5° of it for the whole 12 s), so the heading decides.
        let start = SkyDirection(azimuth: 320, elevation: 20)
        func path(_ bearing: Double) -> SkyPath { SkyPath(start: start, bearing: bearing * Double.pi / 180, legs: [.init(duration: 12, speed: 0.3)]) }
        let aircraft = SkyFixtures.reports(along: path(90), beginningAt: Self.trackStart, from: Self.epoch.addingTimeInterval(-5), to: Self.epoch.addingTimeInterval(25))
        let model = SkyFixtures.truthDual
        func match(offset: Double) throws -> FlightMatch? {
            let flown = path(90 + offset)
            let samples = try (0...60).map { index -> SkyTrackSample in
                let time = Self.trackStart.addingTimeInterval(Double(index) / 5)
                return try #require(SkyFixtures.sample(at: time, since: Self.trackStart, direction: flown.direction(at: Double(index) / 5), through: model))
            }
            let track = SkyTrack(id: UUID(), samples: samples, streakBorn: false)
            let measures = SkyFixtures.measures(of: track, model: model)
            #expect(abs(measures.speed - 0.3) < 0.03, "0.3°/s: \(measures.speed)")
            return FlightMatcher.match(track, measures: measures, model: model, aim: .rough, observer: SkyFixtures.observer, flights: ["b2c3d4": aircraft])
        }
        for offset in [0.0, 10, -10, 20, -20] { #expect(try match(offset: offset)?.hex == "b2c3d4", "\(offset)° off its heading") }
        for offset in [45.0, -45, 90, -90, 135, 180] { #expect(try match(offset: offset) == nil, "\(offset)° off its heading") }
        #expect(FlightMatcher.headingTolerance == 30 && FlightMatcher.headingFromDuration == 1)
    }

    @Test func onlyThePicturesThatAgreeMakeMatches() throws {
        // The aircraft turns away 8 s into the track: from then it is more than 1.5° from the light. Most of the track still agrees (the
        // median is within the tolerance), but only the pictures that agree are matches for the aim to be fitted to.
        let track = try makeTrack()
        var reports = Flight().reports(from: Self.epoch.addingTimeInterval(-5), to: Self.epoch.addingTimeInterval(25))
        for index in reports.indices where reports[index].positionTime >= Self.trackStart.addingTimeInterval(8) { reports[index].latitude += 0.03 }
        let found = try #require(matched(track, aim: .good, flights: ["a0b1c2": reports]))
        #expect(found.score < 0.2)
        #expect(found.correspondences.count >= 38 && found.correspondences.count <= 46, "\(found.correspondences.count) of \(track.samples.count)")
        #expect(found.correspondences.allSatisfy { $0.at <= Self.trackStart.addingTimeInterval(8.8) })
        for correspondence in found.correspondences {
            let sample = try #require(track.samples.first { $0.wallClock == correspondence.at })
            let seen = try #require(SkyFixtures.truthDual.direction(at: sample.point, lens: sample.lens))
            #expect(SkyMath.separation(seen, correspondence.direction) <= 1.5)
        }
    }

    @Test func aTrackUnderASecondNeedsNoHeading() throws {
        // 0.8 s: five pictures. Close to the track's places, a heading from so little is no evidence, so only the places count.
        let track = try makeTrack(seconds: 0.8)
        #expect(SkyFixtures.measures(of: track, model: SkyFixtures.truthDual).duration < 1)
        let middle = Self.trackStart.addingTimeInterval(0.4)
        let back = (-5...25).map { second -> AircraftReport in
            let time = Self.epoch.addingTimeInterval(Double(second))
            var report = Flight().report(at: middle.addingTimeInterval(middle.timeIntervalSince(time)))
            report.hex = "b2c3d4"
            report.positionTime = time
            return report
        }
        #expect(matched(track, aim: .good, flights: ["b2c3d4": back])?.hex == "b2c3d4", "the places agree to 0.3°, whichever way it flies")
        // Longer, the same aircraft is the other way round.
        let longer = try self.makeTrack(seconds: 1.4)
        #expect(SkyFixtures.measures(of: longer, model: SkyFixtures.truthDual).duration >= 1)
        let middleLonger = Self.trackStart.addingTimeInterval(0.7)
        let backLonger = (-5...25).map { second -> AircraftReport in
            let time = Self.epoch.addingTimeInterval(Double(second))
            var report = Flight().report(at: middleLonger.addingTimeInterval(middleLonger.timeIntervalSince(time)))
            report.hex = "b2c3d4"
            report.positionTime = time
            return report
        }
        #expect(matched(longer, aim: .good, flights: ["b2c3d4": backLonger]) == nil, "a second long enough for the heading to count")
    }

    @Test func roughAimNeedsTheSpeedToAgree() throws {
        // Aircraft that start where the track does, on its line, at other speeds. Rough, they are all within 15°; the speed is what decides.
        let track = try makeTrack()
        func matched(_ ratio: Double) -> FlightMatch? {
            self.matched(track, aim: .rough, flights: histories([companion(knots: 450 * ratio)]))
        }
        for ratio in [0.6, 0.8, 1.0, 1.2, 1.4] { #expect(matched(ratio)?.label == .probablePlane, "\(ratio)× the speed") }
        for ratio in [0.3, 0.4, 1.6, 2.0, 4.0] { #expect(matched(ratio) == nil, "\(ratio)× the speed") }
        // With a good aim the speed is not asked about (the places must agree to 1.5°, which they do for 0.8× over 12 s... only just).
        let slow = histories([companion(knots: 450 * 0.97)])
        #expect(self.matched(track, aim: .good, flights: slow) != nil)
    }

    @Test func toleranceTightensWithTheAim() throws {
        let track = try makeTrack()
        // 3° off in azimuth (about 2.8° on the sky at this height).
        let off = SkyFixtures.turned(SkyFixtures.truthDual, by: 3)
        let apart = track.samples.compactMap { sample in
            off.direction(at: sample.point, lens: sample.lens).map { SkyMath.separation($0, Flight().direction(at: sample.wallClock)) }
        }
        #expect(apart.min()! > 2.5 && apart.max()! < 3.1, "\(apart.min()!)…\(apart.max()!)")
        #expect(matched(track, model: off, aim: .rough, flights: histories())?.label == .probablePlane)
        #expect(matched(track, model: off, aim: .good, flights: histories()) == nil)
        #expect(matched(track, model: off, aim: .precise, flights: histories()) == nil)
        // 1° off: good, not precise.
        let near = SkyFixtures.turned(SkyFixtures.truthDual, by: 1)
        #expect(matched(track, model: near, aim: .rough, flights: histories())?.label == .probablePlane)
        #expect(matched(track, model: near, aim: .good, flights: histories())?.label == .plane)
        #expect(matched(track, model: near, aim: .precise, flights: histories()) == nil)
        // The tolerances are the aim fitter's own.
        #expect(AimFitter.matchTolerance(.rough) == 15 && AimFitter.matchTolerance(.good) == 1.5 && AimFitter.matchTolerance(.precise) == 0.75)
    }

    @Test func aPlaneMissingFromHalfTheTrackStillMatchesAndOneMissingFromMostDoesNot() throws {
        let track = try makeTrack()
        // The history ends `end` seconds into the track. Up to 5 s past its last report an aircraft is extrapolated from its speed and track.
        func matched(endingAfter end: Double, extrapolating: Bool = true) -> FlightMatch? {
            var reports = Flight().reports(from: Self.epoch.addingTimeInterval(-5), to: Self.trackStart.addingTimeInterval(end))
            if !extrapolating { reports = reports.map { var bare = $0; bare.groundSpeedKnots = nil; bare.trackDegrees = nil; return bare } }
            return self.matched(track, aim: .good, flights: ["a0b1c2": reports])
        }
        let whole = matched(endingAfter: 12)
        #expect(whole?.correspondences.count == track.samples.count)
        // Ending 7 s in: the next 5 s are extrapolated, which is the whole track.
        #expect(matched(endingAfter: 7)?.correspondences.count == track.samples.count)
        // Ending 4 s in: 3 s of the track are further than 5 s past it: 51 of 61 pictures.
        let late = try #require(matched(endingAfter: 4))
        #expect(late.correspondences.count < track.samples.count && late.correspondences.count >= 45, "\(late.correspondences.count)")
        #expect(late.correspondences.allSatisfy { $0.at <= Self.trackStart.addingTimeInterval(4 + 5 + 1e-6) })
        // Ending 0 s in: 5 s of the track are predicted, 7 s are not, so more than half are missing.
        #expect(matched(endingAfter: 0) == nil)
        // Without a speed and track nothing is extrapolated: ending 7 s in leaves 5 s of 12 unplaced, which is under half; 4 s leaves 8.
        #expect(matched(endingAfter: 7, extrapolating: false)?.correspondences.count ?? 0 > 30)
        #expect(matched(endingAfter: 4, extrapolating: false) == nil)
        // Before the first report, too: a history that begins 3 s into the track places the aircraft from 2 s before it, so the whole track.
        let early = Flight().reports(from: Self.trackStart.addingTimeInterval(3), to: Self.epoch.addingTimeInterval(25))
        #expect(self.matched(track, aim: .good, flights: ["a0b1c2": early])?.correspondences.count == track.samples.count)
        // One that begins 10 s in places it from 5 s in: the 5 s before are missing, which is under half.
        let half = Flight().reports(from: Self.trackStart.addingTimeInterval(10), to: Self.epoch.addingTimeInterval(25))
        let partly = try #require(self.matched(track, aim: .good, flights: ["a0b1c2": half]))
        #expect(partly.correspondences.count < track.samples.count && partly.correspondences.count >= 30, "\(partly.correspondences.count)")
        #expect(partly.correspondences.allSatisfy { $0.at >= Self.trackStart.addingTimeInterval(5 - 1e-6) })
        // One that begins 14 s in places it from 9 s in: three quarters of the track are missing.
        let tooLate = Flight().reports(from: Self.trackStart.addingTimeInterval(14), to: Self.epoch.addingTimeInterval(25))
        #expect(self.matched(track, aim: .good, flights: ["a0b1c2": tooLate]) == nil)
    }

    @Test func aGapInTheReportsIsNotBridgedForever() throws {
        let track = try makeTrack()
        // Reports up to the track's start, then none for a while: a straight flight would be placed right by joining them, but an aircraft
        // that left the feed and came back could have gone anywhere in between.
        func matched(gap: Double) -> FlightMatch? {
            let before = Flight().reports(from: Self.epoch.addingTimeInterval(-5), to: Self.trackStart)
            let after = Flight().reports(from: Self.trackStart.addingTimeInterval(gap), to: Self.epoch.addingTimeInterval(40))
            return self.matched(track, aim: .good, flights: ["a0b1c2": before + after])
        }
        #expect(matched(gap: 15)?.correspondences.count == track.samples.count, "15 s is a gap an aircraft crosses")
        #expect(matched(gap: 25) == nil, "25 s is not")
        #expect(FlightMatcher.maximumGap == 20 && FlightMatcher.maximumExtrapolation == 5)
    }

    @Test func aTrackAcrossTheSeamIsMatchedThroughEachLensOfItsOwn() throws {
        // A flight that crosses the dual camera's seam: 40 s from lon −100.12, east at 450 knots; the seam is at about −100.04.
        var flight = Flight()
        flight.longitude = -100.12
        flight.epoch = Self.trackStart
        var random = SkyRandom(seed: 3)
        let track = try #require(SkyFixtures.track(of: flight, through: SkyFixtures.truthDual, from: Self.trackStart, seconds: 40, rate: 2, using: &random))
        #expect(Set(track.samples.map(\.lens)) == [0, 1], "it crosses")
        let band = track.samples.filter(\.inSeamBand)
        #expect(!band.isEmpty, "and spends some pictures in the seam's low-trust band")
        let history = flight.reports(from: Self.trackStart.addingTimeInterval(-5), to: Self.trackStart.addingTimeInterval(45))
        let found = try #require(matched(track, aim: .good, flights: ["a0b1c2": history]))
        #expect(found.label == .plane && found.score < 0.1)
        // Samples in the band are not fit on, so they give no correspondence; every other sample does, in whichever lens.
        #expect(found.correspondences.count == track.samples.count - band.count)
        #expect(found.correspondences.allSatisfy { !SkyFixtures.truthDual.isInSeamBand($0.point) })
        #expect(Set(found.correspondences.map { SkyFixtures.truthDual.lens(at: $0.point) }) == [0, 1])
    }

    @Test func aSeamJoinMadeByThePictureAloneMustHoldInBothLenses() throws {
        // Two lights joined at the seam before the aim was good: the left one is the aircraft, the right one another aircraft that flies 4°
        // above it. The aircraft explains most of the pictures; it must explain each lens's.
        var flight = Flight()
        flight.longitude = -100.12
        flight.epoch = Self.trackStart
        var random = SkyRandom(seed: 3)
        let whole = try #require(SkyFixtures.track(of: flight, through: SkyFixtures.truthDual, from: Self.trackStart, seconds: 40, rate: 2, using: &random))
        let left = whole.samples.filter { $0.lens == 0 }, right = whole.samples.filter { $0.lens == 1 }
        #expect(left.count > 2 * right.count && right.count > 10)
        let above: [SkyTrackSample] = right.compactMap { sample in
            var direction = flight.direction(at: sample.wallClock)
            direction.elevation += 4
            return SkyFixtures.sample(at: sample.wallClock, since: Self.trackStart, direction: direction, through: SkyFixtures.truthDual)
        }.filter { $0.lens == 1 }
        #expect(above.count > right.count - 3, "the other light is in the right-hand lens too")
        var joined = SkyTrack(id: UUID(), samples: left + above, streakBorn: false)
        let history = ["a0b1c2": flight.reports(from: Self.trackStart.addingTimeInterval(-5), to: Self.trackStart.addingTimeInterval(45))]
        // Taken for one light for certain, it is the aircraft: most of its pictures say so.
        #expect(matched(joined, aim: .good, flights: history)?.hex == "a0b1c2")
        // Joined by the picture alone, the right-hand lens's pictures have to be the aircraft's too, and they are 4° off: no, at a good aim.
        joined.uncertainSeamJoin = true
        joined.seamJoins = 1
        #expect(matched(joined, aim: .good, flights: history) == nil)
        #expect(matched(joined, aim: .precise, flights: history) == nil)
        // A rough aim is as loose in each lens: 4° is within 15°.
        #expect(matched(joined, aim: .rough, flights: history)?.label == .probablePlane)
        // An uncertain join of one aircraft that does explain both halves is a match.
        var honest = whole
        honest.uncertainSeamJoin = true
        #expect(matched(honest, aim: .good, flights: history)?.hex == "a0b1c2")
        #expect(matched(honest, aim: .precise, flights: history)?.label == .plane)
        // The lens of a light that is all in one lens is that one alone.
        var oneLens = try makeTrack()
        oneLens.uncertainSeamJoin = true
        #expect(matched(oneLens, aim: .good, flights: histories())?.hex == "a0b1c2")
    }

    @Test func aTrackInAnyOrderIsJudgedInTimeOrder() throws {
        let track = try makeTrack()
        var shuffled = track
        var random = SkyRandom(seed: 5)
        shuffled.samples.shuffle(using: &random)
        #expect(shuffled.samples.map(\.wallClock) != track.samples.map(\.wallClock))
        let sorted = try #require(matched(track, aim: .good, flights: histories()))
        let found = try #require(matched(shuffled, aim: .good, flights: histories()))
        #expect(found.hex == sorted.hex && found.score == sorted.score)
        #expect(found.correspondences == sorted.correspondences, "in time order, as the store reads them")
    }

    @Test func aLongTrackIsJudgedOnPicturesSpreadAlongIt() throws {
        // A slow flight, so that two minutes of it stay in the left lens.
        var flight = Flight()
        flight.knots = 150
        let track = try makeTrack(of: flight, seconds: 120)
        #expect(track.samples.count == 601 && FlightMatcher.maximumSamples == 100)
        let found = try #require(matched(track, aim: .good, flights: histories([flight], from: -5, to: 140)))
        #expect(found.correspondences.count == 100, "\(found.correspondences.count)")
        #expect(found.correspondences.first?.at == track.samples.first?.wallClock && found.correspondences.last?.at == track.samples.last?.wallClock,
                "the first and the last picture are among them")
        let times = found.correspondences.map { $0.at.timeIntervalSince(Self.trackStart) }
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(gaps.min()! > 1.0 && gaps.max()! < 1.5, "spread evenly: \(gaps.min()!)…\(gaps.max()!) s apart")
    }

    @Test func theDetailIsOfTheReportNearestTheMiddleOfTheTrack() throws {
        let track = try makeTrack()
        // The call sign changes during the history: the track's middle is at 11 s.
        let reports = Flight().reports(from: Self.epoch.addingTimeInterval(-5), to: Self.epoch.addingTimeInterval(25)).map { report -> AircraftReport in
            var changed = report
            let second = report.positionTime.timeIntervalSince(Self.epoch)
            changed.callsign = second < 11 ? "OLD1" : "NEW2"
            changed.altitudeFeet = second < 11 ? 31_000 : 36_000
            return changed
        }
        let found = try #require(matched(track, aim: .good, flights: ["a0b1c2": reports]))
        #expect(found.detail == "NEW2 · 36,000 ft" || found.detail == "OLD1 · 31,000 ft")
        let nearer = reports.min { abs($0.positionTime.timeIntervalSince(Self.trackStart.addingTimeInterval(6))) < abs($1.positionTime.timeIntervalSince(Self.trackStart.addingTimeInterval(6))) }
        #expect(found.detail == FlightMatcher.detail(nearer!), "\(found.detail)")
    }

    @Test func aFlightAcrossTheAntimeridianIsPlaced() throws {
        // The made-up observer is on the 180° meridian and the flight crosses it, going east, 7 s after the epoch: its reports go from
        // 179.99… to −179.99…, and it is placed between them and past the last of them as if the Earth were a line.
        let there = SkyObserver(latitude: 40, longitude: 180, heightMeters: 0)
        var flight = Flight()
        flight.longitude = 179.98
        var random = SkyRandom(seed: 9)
        let model = SkyFixtures.truthDual
        let track = try #require(SkyFixtures.track(of: flight, through: model, from: Self.trackStart, seconds: 12, seenFrom: there, using: &random))
        func match(historyEndingAt end: Double) -> FlightMatch? {
            let history = flight.reports(from: Self.epoch.addingTimeInterval(-5), to: Self.epoch.addingTimeInterval(end))
            return FlightMatcher.match(track, measures: SkyFixtures.measures(of: track, model: model), model: model, aim: .good, observer: there,
                                       flights: ["a0b1c2": history])
        }
        let history = flight.reports(from: Self.epoch.addingTimeInterval(-5), to: Self.epoch.addingTimeInterval(25))
        #expect(history.contains { $0.longitude > 179.99 } && history.contains { $0.longitude < -179.99 }, "the reports cross the meridian")
        // Between two reports either side of it.
        let between = try #require(match(historyEndingAt: 25))
        #expect(between.correspondences.count == track.samples.count)
        // Past the last report, which is 0.3 s short of it.
        let beyond = try #require(match(historyEndingAt: 7))
        #expect(beyond.correspondences.count >= 30 && beyond.correspondences.count < track.samples.count, "\(beyond.correspondences.count)")
        for found in [between, beyond] {
            for correspondence in found.correspondences {
                #expect(SkyMath.separation(correspondence.direction, flight.direction(at: correspondence.at, from: there)) < 0.02, "\(correspondence.at)")
            }
        }
    }

    @Test func aSingleLensCameraMatchesToo() throws {
        // truthSingle faces south-west and up; a flight south-west of the observer, heading north-west.
        var flight = Flight()
        flight.latitude = 39.80
        flight.longitude = -100.30
        flight.track = 300
        var random = SkyRandom(seed: 2)
        let model = SkyFixtures.truthSingle
        let track = try #require(SkyFixtures.track(of: flight, through: model, from: Self.trackStart, seconds: 12, using: &random))
        #expect(Set(track.samples.map(\.lens)) == [0])
        let history = [flight.hex: flight.reports(from: Self.epoch.addingTimeInterval(-5), to: Self.epoch.addingTimeInterval(25))]
        let found = try #require(matched(track, model: model, aim: .good, flights: history))
        #expect(found.hex == "a0b1c2" && found.label == .plane && found.correspondences.count == track.samples.count)
        // And not a flight that goes the other way.
        var other = flight
        other.track = 120
        other.epoch = Self.trackStart
        let place = flight.position(at: Self.trackStart)
        other.latitude = place.latitude
        other.longitude = place.longitude
        #expect(matched(track, model: model, aim: .good, flights: [flight.hex: other.reports(from: Self.epoch.addingTimeInterval(-5), to: Self.epoch.addingTimeInterval(25))])
                == nil)
    }

    @Test func theScoreIsTheMedianOfTheDistances() throws {
        // Four pictures (0.6 s), the aircraft right for two of them and 2.5° off for two: the median of 0, 0, d, d is d / 2, within 1.5°.
        // Five pictures: with two off the median is a right one, with three it is a wrong one (3° off, over 1.5°).
        func match(pictures: Int, displaced: Int, by latitude: Double) throws -> (found: FlightMatch?, distance: Double) {
            let track = try makeTrack(seconds: Double(pictures - 1) / 5, noise: 0)
            #expect(track.samples.count == pictures)
            var distance = 0.0
            let reports = track.samples.enumerated().map { index, sample -> AircraftReport in
                var report = Flight().report(at: sample.wallClock)
                if index >= pictures - displaced {
                    report.latitude += latitude
                    let seen = SkyFixtures.truthDual.direction(at: sample.point, lens: sample.lens)!
                    let there = SkyMath.direction(from: SkyFixtures.observer, toLatitude: report.latitude, longitude: report.longitude,
                                                  altitudeMeters: report.altitudeMeters).direction
                    distance = SkyMath.separation(seen, there)
                }
                return report
            }
            return (matched(track, aim: .good, flights: ["a0b1c2": reports]), distance)
        }
        let four = try match(pictures: 4, displaced: 2, by: 0.020)
        #expect(four.distance > 2.2 && four.distance < 2.8, "\(four.distance)")
        let found = try #require(four.found)
        #expect(abs(found.score - four.distance / 2) < 0.05, "the mean of the two middle distances: \(found.score) of \(four.distance)")
        #expect(found.correspondences.count == 2, "the two that agree")
        let threeOfFive = try match(pictures: 5, displaced: 3, by: 0.025)
        #expect(threeOfFive.distance > 2.5, "\(threeOfFive.distance)")
        #expect(threeOfFive.found == nil, "the median of 0, 0, d, d, d is d")
        let twoOfFive = try #require(try match(pictures: 5, displaced: 2, by: 0.025).found)
        #expect(twoOfFive.score < 0.01 && twoOfFive.correspondences.count == 3, "the median of 0, 0, 0, d, d is 0")
    }

    @Test func theMatcherAsksForNothingItCannotUse() throws {
        let track = try makeTrack()
        let good = histories()
        // Nothing to match with, or nothing to match.
        #expect(matched(track, aim: .good, flights: [:]) == nil)
        #expect(matched(track, aim: .good, flights: ["a0b1c2": []]) == nil)
        var one = track
        one.samples = Array(track.samples.prefix(1))
        #expect(matched(one, aim: .good, flights: good) == nil)
        var none = track
        none.samples = []
        #expect(FlightMatcher.match(none, measures: SkyFixtures.measures(of: track, model: SkyFixtures.truthDual), model: SkyFixtures.truthDual,
                                    aim: .good, observer: SkyFixtures.observer, flights: good) == nil)
        // Reports in any order, with repeats, still place the aircraft.
        let shuffled = ["a0b1c2": good["a0b1c2"]!.reversed() + good["a0b1c2"]!]
        #expect(matched(track, aim: .good, flights: shuffled)?.hex == "a0b1c2")
        // Reports that are not numbers, or not places, never trap and never match.
        var hostile: [AircraftReport] = []
        for (latitude, longitude, altitude) in [(Double.nan, -100.0, 1_000.0), (40.0, .infinity, 1_000), (400, 0, 1_000), (40, -100, .nan), (40, -100, 1e300),
                                                 (90, 180, 0), (-90, -180, -1e9), (1e308, -1e308, 1e308), (40.0, -100.0, 0), (40.0, -100.0, 3)] {
            var report = Flight().report(at: Self.trackStart)
            report.latitude = latitude
            report.longitude = longitude
            report.altitudeMeters = altitude
            hostile.append(report)
            var moving = report
            moving.positionTime = Self.trackStart.addingTimeInterval(20)
            moving.groundSpeedKnots = 1e308
            moving.trackDegrees = .nan
            hostile.append(moving)
        }
        for aim in [SkyAimQuality.rough, .good, .precise] { #expect(matched(track, aim: aim, flights: ["bad": hostile]) == nil, "\(aim)") }
        // A track whose pixels have no direction (past a fold) or are not numbers.
        var odd = track
        odd.samples[0].point = PixelPoint(x: .nan, y: 0.5)
        odd.samples[1].point = PixelPoint(x: 2, y: -1)
        #expect(matched(odd, aim: .good, flights: good)?.correspondences.count ?? 0 >= 55, "the pictures with no direction count against it")
        var times = track
        times.samples[3].wallClock = Date(timeIntervalSince1970: .nan)
        _ = matched(times, aim: .good, flights: good)
    }

    @Test func reportsOfAnyValueNeverTrapTheMatcher() throws {
        let track = try makeTrack()
        var random = SkyRandom(seed: 0xA11CE)
        func odd() -> Double {
            switch Int.random(in: 0..<9, using: &random) {
            case 0: .nan
            case 1: .infinity
            case 2: -.infinity
            case 3: 1e308
            case 4: -1e308
            case 5: 0
            case 6: Double.random(in: -400...400, using: &random)
            default: Double.random(in: -1...1, using: &random) * 1e5
            }
        }
        for round in 0..<300 {
            var reports: [AircraftReport] = []
            for index in 0..<Int.random(in: 1...12, using: &random) {
                var report = Flight().report(at: Self.epoch.addingTimeInterval(Double.random(in: -10...40, using: &random)))
                if Bool.random(using: &random) { report.latitude = Bool.random(using: &random) ? odd() : report.latitude + Double.random(in: -1...1, using: &random) }
                if Bool.random(using: &random) { report.longitude = Bool.random(using: &random) ? odd() : report.longitude + Double.random(in: -1...1, using: &random) }
                if Bool.random(using: &random) { report.altitudeMeters = odd() }
                if Bool.random(using: &random) { report.groundSpeedKnots = Bool.random(using: &random) ? odd() : nil }
                if Bool.random(using: &random) { report.trackDegrees = Bool.random(using: &random) ? odd() : nil }
                if Int.random(in: 0..<8, using: &random) == 0 { report.positionTime = Date(timeIntervalSince1970: odd()) }
                report.hex = String(index)
                reports.append(report)
            }
            for aim in [SkyAimQuality.rough, .good, .precise] {
                let found = matched(track, aim: aim, flights: ["x": reports, "y": reports.reversed(), "a0b1c2": Flight().reports(from: Self.epoch, to: Self.epoch.addingTimeInterval(20))])
                if let found { #expect(found.correspondences.allSatisfy(AimFitter.usable), "round \(round)") }
            }
        }
        // And tracks of any value, against a good aircraft.
        let flights = histories()
        for round in 0..<200 {
            var odd = track
            for _ in 0..<Int.random(in: 1...10, using: &random) {
                let at = Int.random(in: 0..<odd.samples.count, using: &random)
                switch Int.random(in: 0..<5, using: &random) {
                case 0: odd.samples[at].point = PixelPoint(x: Double.random(in: -3...4, using: &random), y: Double.random(in: -3...4, using: &random))
                case 1: odd.samples[at].point = PixelPoint(x: .nan, y: 0.5)
                case 2: odd.samples[at].lens = Int.random(in: -2...5, using: &random)
                case 3: odd.samples[at].wallClock = Date(timeIntervalSince1970: Double.random(in: -1e9...1e12, using: &random))
                default: odd.samples[at].point = PixelPoint(x: .infinity, y: -.infinity)
                }
            }
            if round % 5 == 0 { odd.samples.shuffle(using: &random) }
            for aim in [SkyAimQuality.rough, .good, .precise] { _ = matched(odd, aim: aim, flights: flights) }
        }
    }

    @Test func manyAircraftAndALongTrackAreMatchedInGoodTime() throws {
        // 600 aircraft in view and a track of 3 minutes (900 pictures): the work is bounded by the pictures it looks at.
        let track = try makeTrack(seconds: 180)
        let crowd: [String: [AircraftReport]] = Dictionary(uniqueKeysWithValues: (0..<600).map { index in
            var other = Flight()
            other.hex = String(0x400000 + index, radix: 16)
            other.latitude = 39.0 + Double(index % 60) / 30
            other.longitude = -101.0 + Double(index / 60) / 5
            return (other.hex, other.reports(from: Self.epoch.addingTimeInterval(-5), to: Self.epoch.addingTimeInterval(200), every: 1))
        })
        var all = crowd
        all["a0b1c2"] = Flight().reports(from: Self.epoch.addingTimeInterval(-5), to: Self.epoch.addingTimeInterval(200))
        let started = ContinuousClock.now
        let found = matched(track, aim: .good, flights: all)
        let elapsed = ContinuousClock.now - started
        #expect(found?.hex == "a0b1c2")
        #expect(found.map { $0.correspondences.count <= FlightMatcher.maximumSamples } == true, "\(found?.correspondences.count ?? -1)")
        #expect(elapsed < .seconds(20), "\(elapsed)")
    }

    @Test func theMatchIsDeterministic() throws {
        let track = try makeTrack()
        let near = companion(hex: "b2c3d4", eastward: 0.0058)
        let list = histories([near, Flight()])
        let first = matched(track, aim: .good, flights: list)
        for _ in 0..<5 { #expect(matched(track, aim: .good, flights: list) == first) }
        // Two aircraft that are equally good: the same one every time (the lower hex).
        var twin = Flight()
        twin.hex = "000001"
        let tie = histories([Flight(), twin])
        let chosen = matched(track, aim: .good, flights: tie)?.hex
        #expect(chosen == "000001")
        for _ in 0..<5 { #expect(matched(track, aim: .good, flights: tie)?.hex == chosen) }
    }

    @Test func aMatchFeedsTheAimInOnePass() throws {
        let track = try makeTrack()
        let found = try #require(matched(track, aim: .good, flights: histories()))
        #expect(found.correspondences.allSatisfy(AimFitter.usable))
        #expect(found.correspondences.map(\.at) == found.correspondences.map(\.at).sorted(), "in time order, as the store reads them")
        // One call thins them (at most 12, 1° apart); a flight match is one object for the stage's counts.
        let thinned = SkyAimStore.thinned(found.correspondences)
        #expect(thinned.count >= 4 && thinned.count <= SkyAimStore.planeSamplesPerPass)
        #expect(Set(found.correspondences.map(\.object)) == ["a0b1c2"])
    }

    @Test func aMatchGoesIntoTheAimStoreInOneCall() async throws {
        let directory = try TemporaryDirectory()
        let card = SkyCameraModel.initial(facing: 352, tilt: 18, pictureWidth: 4256, pictureHeight: 1888)
        let store = SkyAimStore(directory: directory.url, log: Log(category: "Sky"), start: card, pictureWidth: 4256, pictureHeight: 1888,
                                now: { Self.epoch.addingTimeInterval(30) }, seed: 1)
        let found = try #require(matched(try makeTrack(), aim: .good, flights: histories()))
        #expect(found.correspondences.count == 61)
        _ = await store.add(found.correspondences)
        // The store thins one call's samples of an aircraft (at most 12, 1° apart): one call, so the whole pass is thinned as one.
        let kept = await store.correspondences()
        #expect(kept == SkyAimStore.thinned(found.correspondences))
        #expect(kept.count >= 4 && kept.count <= SkyAimStore.planeSamplesPerPass)
        #expect(kept.allSatisfy { $0.source == .plane && $0.object == "a0b1c2" })
    }

    @Test func theDetailNamesTheFlightAndItsHeight() {
        func detail(_ callsign: String?, _ feet: Int, hex: String = "a0b1c2") -> String {
            var report = Flight().report(at: Self.epoch)
            report.callsign = callsign
            report.altitudeFeet = feet
            report.hex = hex
            return FlightMatcher.detail(report)
        }
        #expect(detail("TEST123", 35_025) == "TEST123 · 35,000 ft")
        #expect(detail("  TEST123 ", 35_025) == "TEST123 · 35,000 ft", "trimmed")
        #expect(detail(nil, 35_025) == "A0B1C2 · 35,000 ft", "no call sign: the hex, in capitals")
        #expect(detail("", 35_025) == "A0B1C2 · 35,000 ft" && detail("   ", 35_025) == "A0B1C2 · 35,000 ft")
        #expect(detail(nil, 35_025, hex: "~b1c2d3") == "~B1C2D3 · 35,000 ft")
        // Feet, to the nearest hundred (halves go up), with a comma.
        let heights: [(Int, String)] = [(34_949, "34,900"), (34_950, "35,000"), (34_951, "35,000"), (0, "0"), (49, "0"), (50, "100"), (499, "500"),
                                        (500, "500"), (999, "1,000"), (1_000, "1,000"), (5_250, "5,300"), (12_345, "12,300"), (100_000, "100,000"),
                                        (1_000_000, "1,000,000"), (-49, "0"), (-150, "-200"), (-1_240, "-1,200")]
        for (feet, text) in heights { #expect(detail("T1", feet) == "T1 · \(text) ft", "\(feet)") }
        #expect(detail("T1", Int.max).hasSuffix(" ft"), "no trap at the ends")
        #expect(detail("T1", Int.min).hasSuffix(" ft"))
    }

    @Test func theLabelsAreTheDesigns() throws {
        #expect(SkyLabel.allCases.map(\.rawValue) == ["unexplained", "plane", "probablePlane", "satellite", "probableSatellite", "satelliteFlare", "meteor", "bug",
                                                       "bird"])
        for label in SkyLabel.allCases {
            let data = try JSONEncoder().encode([label])
            #expect(try JSONDecoder().decode([SkyLabel].self, from: data) == [label])
        }
    }
}

// MARK: - The live transport

#if os(macOS) || os(Linux)
extension SkyFlightTests {
    /// A server on the loopback interface that hands each connection to `serve`.
    final class Loopback: Sendable {
        typealias Serve = @Sendable (any TCPConnection, Box<[HTTPRequestHead]>) async -> Void
        let requests = Box<[HTTPRequestHead]>([])
        let port: UInt16
        private let listener: any TCPListener
        private let acceptor: Task<Void, Never>

        init(serve: @escaping Serve) async throws {
            let listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
            let requests = requests
            self.listener = listener
            port = listener.port
            acceptor = Task {
                for await connection in listener.connections { Task { await serve(connection, requests) } }
            }
        }

        /// A server that answers every request from `answer`.
        convenience init(answer: @escaping @Sendable (HTTPRequestHead) -> (status: Int, headers: [(String, String)], body: Data)) async throws {
            try await self.init { connection, requests in
                var parser = HTTPRequestParser(maxBodySize: 1 << 20)
                defer { connection.close() }
                while let data = try? await connection.receive(maximumLength: 65_536), let parsed = try? parser.feed(data) {
                    for (head, _) in parsed {
                        requests.update { $0.append(head) }
                        let (status, headers, body) = answer(head)
                        guard (try? await connection.send(HTTPSerializer.response(status: status, headers: HTTPHeaders(headers), body: body))) != nil else { return }
                    }
                }
            }
        }

        func stop() {
            listener.close()
            acceptor.cancel()
        }
    }

    private func url(_ server: Loopback, _ path: String = "/data/aircraft.json") throws -> URL {
        try #require(URL(string: "http://127.0.0.1:\(server.port)\(path)"))
    }

    @Test func theLiveTransportReturnsWhateverTheFeedAnswers() async throws {
        let body = Data(SkyFixtures.aircraftJSON.utf8)
        let server = try await Loopback { head in
            switch head.target {
            case "/data/aircraft.json": (200, [("Content-Type", "application/json")], body)
            case "/missing": (404, [], Data("nothing here".utf8))
            case "/busy": (503, [], Data())
            default: (500, [], Data())
            }
        }
        defer { server.stop() }
        let http = URLSessionSkyHTTP()
        let ok = try await http.get(try url(server), timeout: .seconds(5), maximumBytes: AircraftFeedParser.maximumBytes)
        #expect(ok.status == 200 && ok.body == body)
        let missing = try await http.get(try url(server, "/missing"), timeout: .seconds(5), maximumBytes: 1_000)
        #expect(missing.status == 404 && missing.body == Data("nothing here".utf8), "a status is an answer, not an error")
        let busy = try await http.get(try url(server, "/busy"), timeout: .seconds(5), maximumBytes: 1_000)
        #expect(busy.status == 503)
        // A plain GET that asks for JSON, with nothing of the box's in it.
        let seen = server.requests.value
        #expect(seen.count == 3 && seen.allSatisfy { $0.method == "GET" })
        let names = Set(seen.flatMap { $0.headers.map { $0.name.lowercased() } })
        #expect(!names.contains("authorization") && !names.contains("cookie"), "\(names)")
        // The same client serves many at once.
        let answers = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<12 { group.addTask { try await http.get(try self.url(server), timeout: .seconds(5), maximumBytes: AircraftFeedParser.maximumBytes).status } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(answers == Array(repeating: 200, count: 12))
    }

    @Test func theLiveTransportNeverFollowsARedirect() async throws {
        let target = try await Loopback { _ in (200, [], Data(SkyFixtures.aircraftJSON.utf8)) }
        defer { target.stop() }
        let location = "http://127.0.0.1:\(target.port)/elsewhere"
        let redirecting = try await Loopback { _ in (302, [("Location", location)], Data()) }
        defer { redirecting.stop() }
        let answer = try await URLSessionSkyHTTP().get(try url(redirecting), timeout: .seconds(5), maximumBytes: 1 << 20)
        #expect(answer.status == 302 && answer.body.isEmpty, "the redirect is the answer")
        #expect(target.requests.value.isEmpty && redirecting.requests.value.count == 1, "the address it names is never asked")
    }

    @Test func theLiveTransportAnswersWithoutCredentialsToAChallenge() async throws {
        let server = try await Loopback { _ in (401, [("WWW-Authenticate", #"Basic realm="feed""#)], Data("no".utf8)) }
        defer { server.stop() }
        let answer = try await URLSessionSkyHTTP().get(try url(server), timeout: .seconds(5), maximumBytes: 1_000)
        #expect(answer.status == 401)
        // URLSession may ask once more after a challenge; whichever, nothing it sent carries a credential.
        let asked = server.requests.value
        #expect(!asked.isEmpty && asked.count <= 2)
        #expect(asked.allSatisfy { head in !head.headers.contains { $0.name.lowercased() == "authorization" } })
    }

    @Test func theLiveTransportRefusesALongerAnswerThanItWasToldTo() async throws {
        let exact = Data(repeating: 0x41, count: 100_000)
        let server = try await Loopback { _ in (200, [], exact) }
        defer { server.stop() }
        let http = URLSessionSkyHTTP()
        let whole = try await http.get(try url(server), timeout: .seconds(5), maximumBytes: exact.count)
        #expect(whole.body == exact, "exactly the limit is fine")
        await #expect(throws: HTTPClientError.bodyTooLarge(limit: exact.count - 1)) {
            _ = try await http.get(try self.url(server), timeout: .seconds(5), maximumBytes: exact.count - 1)
        }
        // A length that is announced is refused before the body is read; one that is not is cut off as soon as it is too long.
        let endless = try await Loopback { connection, requests in
            var parser = HTTPRequestParser(maxBodySize: 1 << 20)
            defer { connection.close() }
            guard let data = try? await connection.receive(maximumLength: 65_536), let parsed = try? parser.feed(data), let head = parsed.first?.head else { return }
            requests.update { $0.append(head) }
            guard (try? await connection.send(Data("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".utf8))) != nil else { return }
            let chunk = Data(repeating: 0x20, count: 64 << 10)
            for _ in 0..<2_000 { guard (try? await connection.send(chunk)) != nil else { return } }
        }
        defer { endless.stop() }
        let started = ContinuousClock.now
        await #expect(throws: HTTPClientError.bodyTooLarge(limit: 1 << 20)) {
            _ = try await http.get(try self.url(endless), timeout: .seconds(20), maximumBytes: 1 << 20)
        }
        #expect(ContinuousClock.now - started < .seconds(10), "it did not read it all")
        let lying = try await Loopback { _ in (200, [("Content-Length", "50000000000")], Data(repeating: 0x20, count: 1_000)) }
        defer { lying.stop() }
        await #expect(throws: HTTPClientError.bodyTooLarge(limit: 4 << 20)) {
            _ = try await http.get(try self.url(lying), timeout: .seconds(20), maximumBytes: 4 << 20)
        }
    }

    @Test func theLiveTransportWaitsNoLongerThanItWasToldTo() async throws {
        // A host that accepts the connection and never answers.
        let silent = try await Loopback { connection, requests in
            // Reads what is sent and answers nothing, until the client lets go.
            while (try? await connection.receive(maximumLength: 65_536)) != nil {}
            connection.close()
        }
        defer { silent.stop() }
        let http = URLSessionSkyHTTP()
        for wait in [Duration.milliseconds(300), .milliseconds(1_500)] {
            let started = ContinuousClock.now
            do {
                _ = try await http.get(try url(silent), timeout: wait, maximumBytes: 1 << 20)
                Issue.record("answered")
            } catch let error as TransportError {
                #expect(error == .timedOut, "\(error)")
            }
            let took = ContinuousClock.now - started
            #expect(took >= wait - .milliseconds(50) && took < wait + .seconds(3), "asked to wait \(wait), waited \(took)")
        }
        // A caller that is cancelled stops waiting at once.
        let waiting = Task { try await http.get(try self.url(silent), timeout: .seconds(30), maximumBytes: 1 << 20) }
        try await Task.sleep(for: .milliseconds(200))
        waiting.cancel()
        let started = ContinuousClock.now
        do {
            _ = try await waiting.value
            Issue.record("answered")
        } catch is CancellationError {
        }
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func theLiveTransportsErrorsNameNoAddress() async throws {
        // Nothing listens there.
        let closed = try await Loopback { _ in (200, [], Data()) }
        let address = try url(closed, "/secret-token-path?key=sk-test-0000")
        closed.stop()
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await URLSessionSkyHTTP().get(address, timeout: .seconds(3), maximumBytes: 1_000)
            Issue.record("answered")
        } catch {
            for text in [String(describing: error), String(reflecting: error), "\(error)"] {
                #expect(!text.contains("127.0.0.1") && !text.contains("secret-token-path") && !text.contains("sk-test-0000"), "\(text)")
            }
        }
    }
}
#endif

// MARK: - A fake network

/// A `SkyHTTP` that answers from memory and records what it was asked.
final class FakeSkyHTTP: SkyHTTP {
    struct Request: Sendable, Equatable {
        var url: URL
        var timeout: Duration
        var maximumBytes: Int
    }

    typealias Answer = @Sendable (URL) async throws -> (Data, Int)

    let requests = Box<[Request]>([])
    private let answer: Answer

    init(_ answer: @escaping Answer) {
        self.answer = answer
    }

    /// Answers each address in `pages` with its status and body, and every other with 404.
    convenience init(pages: [String: (status: Int, body: String)]) {
        self.init { url in
            guard let page = pages[url.absoluteString] else { return (Data(), 404) }
            return (Data(page.body.utf8), page.status)
        }
    }

    var urls: [String] { requests.value.map(\.url.absoluteString) }

    func get(_ url: URL, timeout: Duration, maximumBytes: Int) async throws -> (body: Data, status: Int) {
        requests.update { $0.append(Request(url: url, timeout: timeout, maximumBytes: maximumBytes)) }
        let (body, status) = try await answer(url)
        return (body, status)
    }
}
