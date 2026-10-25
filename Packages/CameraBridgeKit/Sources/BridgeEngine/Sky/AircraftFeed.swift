import BridgeSupport
import Foundation

/// Where one aircraft was, as a flight feed reported it. The time is the box's own: the moment the answer was received less the report's
/// `seen_pos`, never the feed's own clock.
struct AircraftReport: Sendable, Equatable {
    /// The 24-bit ICAO address, six lower-case hex digits (a non-ICAO address, such as a TIS-B target's, keeps its `~`).
    var hex: String
    /// The call sign, upper case, when the feed gave one that is plain letters and digits.
    var callsign: String?
    /// WGS84 degrees.
    var latitude: Double
    var longitude: Double
    /// The geometric altitude when the feed has it, else the barometric one: WGS84 metres, and the same in whole feet.
    var altitudeMeters: Double
    var altitudeFeet: Int
    /// When the position was current, on the box's clock.
    var positionTime: Date
    /// Knots over the ground and degrees clockwise from true north, when the feed gave sensible ones.
    var groundSpeedKnots: Double?
    var trackDegrees: Double?
}

/// Reads the aircraft list of a flight feed: dump1090, readsb, tar1090 or PiAware `aircraft.json` (`aircraft`), or adsb.fi's answer (`ac`).
///
/// A feed is somebody else's input, so nothing in it can stop the whole: the document is read with `JSONSerialization` and each field of
/// each aircraft on its own (a number, or a plain decimal in a string), and an aircraft with anything odd in a field that it needs (a
/// position, an age, a height) is left out alone. A body over `maximumBytes` is not read, and at most `maximumAircraft` come out.
///
/// **Pinned:** the geometric altitude (`alt_geom`) else the barometric one (`alt_baro`); an aircraft on the ground (`alt_baro` "ground"), one
/// with a position older than `maximumPositionAge` (`seen_pos`) and one with a number that is not one (NaN, out of range) are skipped; the
/// position's time is the time of receipt less `seen_pos`.
///
/// **The builder's choices:**
/// - The feed's own `now` is never read. A feed host's clock can be minutes out, and `seen_pos` is relative to the moment the feed was
///   written, so the box's receive time is the only clock that is its own. An aircraft with no `seen_pos` has an age nobody knows and is
///   left out; a `seen_pos` a little under 0 (a clock step on the feed's host) is 0.
/// - Some dump1090 builds have written `nan` and `inf` where JSON has no such thing, which makes the document unreadable. If it will not
///   read, the bare words outside any string that JSON does not have are made `null` and it is read once more; the aircraft they stood in
///   then lack the field, and the rest are kept.
/// - A document nested more than `maximumNesting` levels deep is not read (see `nesting(of:)`: Apple's JSON reader can crash on one).
/// - Heights outside −2,000…100,000 ft are not an aircraft's. A speed is taken from 0 to 2,000 knots and a track from 0 to 360°, and an odd
///   one only costs the aircraft its speed or track.
/// - The address must be six hex digits (with a `~` for a non-ICAO one), and an aircraft is read once: the first of a hex wins. A call sign is
///   at most 8 letters, digits, hyphens or underscores, else the aircraft has none: what a feed says is shown on the box's pages.
enum AircraftFeedParser {
    static let maximumBytes = 4 << 20
    static let maximumAircraft = 5_000
    static let maximumPositionAge: TimeInterval = 30

    /// An aircraft's height in feet, at the most and the least.
    static let altitudeLimits = -2_000.0...100_000.0
    static let metresPerFoot = 0.3048
    static let maximumSpeedKnots = 2_000.0
    /// How far under 0 a `seen_pos` may be, and still be 0.
    static let clockStep = 1.0
    static let maximumCallSignLength = 8
    /// How deep a feed's arrays and objects may nest: a feed is an object holding a list of objects, and the deepest thing in a real one
    /// (readsb's `lastPosition`) is four levels down.
    static let maximumNesting = 16

    /// The reports of the aircraft in `data`, as `parseFeed` reads them, or none when it is not a feed.
    static func parse(_ data: Data, receivedAt: Date) -> [AircraftReport] {
        parseFeed(data, receivedAt: receivedAt) ?? []
    }

    /// The reports of the aircraft in `data` (an empty list for a feed with none in view), or nil when `data` is not a flight feed: too long,
    /// not JSON, or with no list of aircraft under `aircraft` or `ac`.
    static func parseFeed(_ data: Data, receivedAt: Date) -> [AircraftReport]? {
        guard let list = aircraftList(in: data) else { return nil }
        var seen = Set<String>()
        var reports: [AircraftReport] = []
        for item in list {
            guard reports.count < maximumAircraft else { break }
            guard let aircraft = item as? [String: Any], let report = report(from: aircraft, receivedAt: receivedAt),
                  seen.insert(report.hex).inserted else { continue }
            reports.append(report)
        }
        return reports
    }

    /// Whether `data` is a flight feed, however many aircraft are in view (the feed finder's test).
    static func isFeed(_ data: Data) -> Bool {
        aircraftList(in: data) != nil
    }

    // MARK: The document

    private static func aircraftList(in data: Data) -> [Any]? {
        guard !data.isEmpty, data.count <= maximumBytes, nesting(of: data) <= maximumNesting,
              let root = document(from: data) as? [String: Any] else { return nil }
        return (root["aircraft"] as? [Any]) ?? (root["ac"] as? [Any])
    }

    /// How deep the arrays and objects of `data` are nested (strings aside), by a look at the bytes alone, so that a document built to be
    /// deep never reaches the JSON reader: Foundation's has a limit of 512 levels, but on macOS, on a thread with a small stack (512 KB is
    /// usual off the main thread), objects nested 480 deep already overflow it, and that is a crash, not an error. (On Linux the limit of 512
    /// is reached first.)
    static func nesting(of data: Data) -> Int {
        data.withUnsafeBytes { bytes in
            var depth = 0, deepest = 0
            var inString = false, escaped = false
            for byte in bytes {
                if inString {
                    if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                } else if byte == 0x22 {
                    inString = true
                } else if byte == 0x5B || byte == 0x7B {
                    depth += 1
                    deepest = max(deepest, depth)
                    if deepest > maximumNesting { return deepest }
                } else if byte == 0x5D || byte == 0x7D {
                    depth = max(0, depth - 1)
                }
            }
            return deepest
        }
    }

    private static func document(from data: Data) -> Any? {
        if let value = try? JSONSerialization.jsonObject(with: data) { return value }
        guard let cleaned = withoutBareWords(data) else { return nil }
        return try? JSONSerialization.jsonObject(with: cleaned)
    }

    /// `data` with every bare word that JSON does not have (anything but `true`, `false` and `null`, a sign before it included) outside a
    /// string made `null`; nil when there was none. Numbers (`1e5`, `-4.5E+2`) and strings are left as they are.
    private static func withoutBareWords(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var cleaned: [UInt8] = []
        cleaned.reserveCapacity(bytes.count)
        var changed = false
        var inString = false, escaped = false
        var index = 0
        func isLetter(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
        func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
        func isSign(_ byte: UInt8) -> Bool { byte == 0x2D || byte == 0x2B }
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                cleaned.append(byte)
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                index += 1
            } else if byte == 0x22 {
                inString = true
                cleaned.append(byte)
                index += 1
            } else if isDigit(byte) || (isSign(byte) && index + 1 < bytes.count && (isDigit(bytes[index + 1]) || bytes[index + 1] == 0x2E)) {
                // A number, with its sign, point and exponent.
                repeat {
                    cleaned.append(bytes[index])
                    index += 1
                } while index < bytes.count && (isDigit(bytes[index]) || [0x2E, 0x65, 0x45, 0x2B, 0x2D].contains(bytes[index]))
            } else if isLetter(byte) || (isSign(byte) && index + 1 < bytes.count && isLetter(bytes[index + 1])) {
                var end = index + 1
                while end < bytes.count && isLetter(bytes[end]) { end += 1 }
                let word = bytes[index..<end]
                if word.elementsEqual("true".utf8) || word.elementsEqual("false".utf8) || word.elementsEqual("null".utf8) {
                    cleaned.append(contentsOf: word)
                } else {
                    cleaned.append(contentsOf: "null".utf8)
                    changed = true
                }
                index = end
            } else {
                cleaned.append(byte)
                index += 1
            }
        }
        return changed ? Data(cleaned) : nil
    }

    // MARK: An aircraft

    private static func report(from aircraft: [String: Any], receivedAt: Date) -> AircraftReport? {
        guard let hex = hexAddress(aircraft["hex"]),
              let latitude = number(aircraft["lat"]), (-90.0...90.0).contains(latitude),
              let longitude = number(aircraft["lon"]), (-180.0...180.0).contains(longitude),
              let seen = number(aircraft["seen_pos"]), seen >= -clockStep, seen <= maximumPositionAge else { return nil }
        if let barometric = aircraft["alt_baro"] as? String, barometric.trimmingCharacters(in: .whitespaces).lowercased() == "ground" { return nil }
        guard let feet = [number(aircraft["alt_geom"]), number(aircraft["alt_baro"])].compactMap({ $0 }).first(where: altitudeLimits.contains)
        else { return nil }
        var track = number(aircraft["track"]).flatMap { (0.0...360.0).contains($0) ? $0 : nil }
        if track == 360 { track = 0 }
        return AircraftReport(hex: hex, callsign: callSign(aircraft["flight"]), latitude: latitude, longitude: longitude,
                              altitudeMeters: feet * metresPerFoot, altitudeFeet: Int(feet.rounded()),
                              positionTime: receivedAt.addingTimeInterval(-max(0, seen)),
                              groundSpeedKnots: number(aircraft["gs"]).flatMap { (0.0...maximumSpeedKnots).contains($0) ? $0 : nil },
                              trackDegrees: track)
    }

    /// Six lower-case hex digits, with a `~` before them for an address that is not an ICAO one.
    private static func hexAddress(_ value: Any?) -> String? {
        guard let text = value as? String, text.utf8.count <= 32 else { return nil }
        var address = Array(text.trimmingCharacters(in: .whitespaces).lowercased().utf8)
        let anonymous = address.first == 0x7E
        if anonymous { address.removeFirst() }
        guard address.count == 6, address.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
        return (anonymous ? "~" : "") + String(decoding: address, as: UTF8.self)
    }

    /// Up to eight letters, digits, hyphens or underscores, upper case; nil for anything else (it is shown on the box's pages).
    private static func callSign(_ value: Any?) -> String? {
        guard let text = value as? String, text.utf8.count <= 64 else { return nil }
        let name = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().utf8)
        guard (1...maximumCallSignLength).contains(name.count),
              name.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || $0 == 0x2D || $0 == 0x5F }) else { return nil }
        return String(decoding: name, as: UTF8.self)
    }

    // MARK: Numbers

    /// A JSON number, or a string that holds one in plain decimal; nothing else (not `true`, not `nan`, not a hex float). Always finite.
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            // A JSON `true` is an NSNumber too, and reads as 1; its type is `c` where a number's is never.
            guard number.objCType.pointee != 0x63 else { return nil }
            return number.doubleValue.isFinite ? number.doubleValue : nil
        case let text as String:
            return decimal(text)
        default:
            return nil
        }
    }

    /// `text` as a number when it is a plain decimal (digits, a sign, a point, an exponent): `Double("0x1p3")`, `Double("nan")` and
    /// `Double("inf")` all read, and none of them is a measurement.
    private static func decimal(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 32 else { return nil }
        var digits = 0
        for byte in trimmed.utf8 {
            switch byte {
            case 0x30...0x39: digits += 1
            case 0x2B, 0x2D, 0x2E, 0x65, 0x45: break
            default: return nil
            }
        }
        guard digits > 0, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }
}

/// Polls a flight feed and keeps what it says in a `FlightHistory`: one request at a time, `interval` after the last answer, every one
/// bounded in time and size (`timeout`, `AircraftFeedParser.maximumBytes`). What is wrong with the feed is `problem`, in plain words with no
/// address in them; the last good answer is `lastAnswer`.
///
/// `stop()` returns once the polling has ended: no request starts after it, one still on its way is cancelled, and an answer that arrives
/// anyway is thrown away. A poller nobody holds any more stops by itself.
actor FlightFeedPoller {
    /// How long one request may take.
    static let timeout: Duration = .seconds(5)

    static let notUnderstood = "The flight feed answered, but not with a list of aircraft."
    static let tooLarge = "The flight feed's answer was too large."
    static let unreachable = "The flight feed could not be reached."
    static func answered(_ status: Int) -> String { "The flight feed answered \(status)." }

    private let url: URL
    private let http: any SkyHTTP
    private let history: FlightHistory
    private let interval: Duration
    private let now: @Sendable () -> Date
    private var task: Task<Void, Never>?
    /// What is wrong with the feed now; nil when its last answer was a feed.
    private(set) var problem: String?
    /// When the last answer that was a feed came (the box's clock).
    private(set) var lastAnswer: Date?

    /// `now` is the box's clock: the time an answer was received, which dates every position in it.
    init(url: URL, http: any SkyHTTP, history: FlightHistory, interval: Duration = .seconds(1), now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.http = http
        self.history = history
        self.interval = interval
        self.now = now
    }

    deinit {
        task?.cancel()
    }

    /// Starts polling, with a request at once. Does nothing while it is polling already.
    func start() {
        if let running = task, !running.isCancelled { return }
        let interval = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard await Self.poll(self) else { return }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    /// Stops polling and returns when it has stopped.
    func stop() async {
        guard let running = task else { return }
        running.cancel()
        await running.value
        if task == running { task = nil }
    }

    /// One request, if `poller` is still there (the polling loop holds it only while it asks, so letting go of it ends the loop).
    private static func poll(_ poller: FlightFeedPoller?) async -> Bool {
        guard let poller else { return false }
        await poller.pollOnce()
        return true
    }

    private func pollOnce() async {
        let answer: (body: Data, status: Int)
        do {
            answer = try await http.get(url, timeout: Self.timeout, maximumBytes: AircraftFeedParser.maximumBytes)
        } catch is CancellationError {
            return
        } catch HTTPClientError.bodyTooLarge {
            if !Task.isCancelled { problem = Self.tooLarge }
            return
        } catch {
            if !Task.isCancelled { problem = Self.unreachable }
            return
        }
        guard !Task.isCancelled else { return }
        let received = now()
        guard (200..<300).contains(answer.status) else {
            problem = Self.answered(answer.status)
            return
        }
        guard let reports = AircraftFeedParser.parseFeed(answer.body, receivedAt: received) else {
            problem = Self.notUnderstood
            return
        }
        await history.add(reports)
        problem = nil
        lastAnswer = received
    }
}
