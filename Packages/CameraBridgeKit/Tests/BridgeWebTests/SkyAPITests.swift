import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// The Sky Watcher in the API: the night's log and its corrections and stills, the flight feeds the box finds, the box's place and the feed in
/// the settings, and each camera's switch. The place is shown to the signed-in page only and is in no log line.
@Suite(.timeLimit(.minutes(2))) struct SkyAPITests {
    static let place: [String: Double] = ["latitude": 40.0, "longitude": -100.0]
    static let enableMessage = "Set where the box is first."
    static let folderMessage = "Choose a recordings folder first: the sky log is kept with the recordings."
    static let batteryMessage = "Battery cameras can’t watch the sky: it would keep them awake."
    static let pluginMessage = "Turn on Sky Watcher in Plugins first."
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0xD9])

    static let measures: SkyMeasures = {
        let json = #"{"azimuth":312,"elevation":8,"azimuthEnd":330,"elevationEnd":14,"duration":4.2,"speed":3,"acceleration":0,"turnRate":0.1,"maxTurn":5,"# +
            #""straightness":0.99,"shape":"straight","sizeDegrees":0.1,"brightness":100,"blinks":true,"blinkRate":1,"focus":1}"#
        return try! JSONDecoder().decode(SkyMeasures.self, from: Data(json.utf8))   // swiftlint:disable:this force_try
    }()

    /// The time the fake's entries begin: 2026-10-25 08:12:00 UTC.
    static let start = Date(timeIntervalSince1970: 1_792_915_920)

    static func entry(_ id: String, camera: UUID, at offset: TimeInterval, label: SkyLabel = .unexplained, by: SkyLabelSource? = nil, detail: String? = nil,
                      correction: SkyCorrection? = nil, hasStill: Bool = false) -> SkyEntry {
        var entry = SkyEntry(id: id, camera: camera, kind: .track, start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + 4.2),
                             path: [SkyPathPoint(t: 0, x: 0.1, y: 0.2), SkyPathPoint(t: 4.2, x: 0.3, y: 0.25)], measures: measures, label: label)
        entry.by = by
        entry.detail = detail
        entry.correction = correction
        entry.hasStill = hasStill
        return entry
    }

    private func addCamera(_ session: Harness.Session, host: String = "192.168.77.30") async throws -> UUID {
        let answer = await session.send("POST", "/api/v1/cameras", json: ["type": "automatic", "host": host, "username": "viewer", "password": "pw", "name": "North Sky"])
        return try #require(UUID(uuidString: answer.json["id"] as? String ?? ""), "\(answer.text)")
    }

    /// A bridge with one camera. The Sky Watcher plugin is on (it is off on a new box): the tests of the plugin itself ask for `plugin: false`.
    private func ready(place: Bool = true, folder: Bool = true, plugin: Bool = true) async throws -> (backend: FakeBackend, session: Harness.Session, id: UUID) {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        let id = try await addCamera(session)
        backend.write { state in
            if plugin { state.settings.plugins["sky"] = PluginState(enabled: true) }
            if place { state.settings.sky.location = SkyLocation(latitude: 40, longitude: -100) }
            if folder { state.settings.nvrFolder = "/srv/recordings" }
        }
        return (backend, session, id)
    }

    private func sky(_ answer: Answer) -> [String: Any] { answer.json["skyDetector"] as? [String: Any] ?? [:] }

    // MARK: The night's log

    @Test func nightRouteAnswersTheLog() async throws {
        let (backend, session, id) = try await ready()
        let plane = Self.entry("p-1", camera: id, at: 0, label: .plane, by: .flight, detail: "TEST123 · 35,000 ft")
        var odd = Self.entry("u-1", camera: id, at: 60, hasStill: true)
        odd.unusual = [.faster, .larger]
        odd.speedVsPlanes = 6.1
        odd.candidate = true
        odd.ai = SkyAIAnswer(kind: "drone", sentence: "A bright light moving fast.", model: "claude-haiku-5-5", at: Self.start.addingTimeInterval(70))
        let doubted = Self.entry("s-1", camera: id, at: 120, label: .satellite, by: .orbit, detail: "ISS (ZARYA)", correction: .bird)
        backend.write { state in
            state.skyEntries = [odd, doubted, plane, Self.entry("elsewhere", camera: UUID(), at: 5)]
            state.skyConditions = [SkyConditions(from: Self.start, to: Self.start.addingTimeInterval(3_600), state: .clear, cloudCover: 10),
                                   SkyConditions(from: Self.start.addingTimeInterval(3_600), to: Self.start.addingTimeInterval(7_200), state: .unknown, cloudCover: nil)]
            state.skyAim = SkyAimStatus(quality: .good, planes: 23, stars: 0, residualPixels: 14, updated: Self.start,
                                        lenses: [SkyLensAimStatus(quality: .good, planes: 23, stars: 0, residualPixels: 14)], note: "Aiming again.")
            state.skyLearning = SkyLearning(ready: false, planes: 12, satellites: 3)
        }
        let before = Date()
        let answer = await session.get("/api/v1/sky/cameras/\(id.uuidString)/night?date=2026-10-24&view=night")
        let after = Date()
        #expect(answer.status == 200, "\(answer.text)")
        #expect(backend.read { $0.skyCalls } == ["night:\(id.uuidString):2026-10-24:night"])
        let json = answer.json
        #expect(json["camera"] as? String == id.uuidString && json["night"] as? String == "2026-10-24" && json["view"] as? String == "night")
        #expect(answer.int("from") == Int64(FakeBackend.skyFrom.timeIntervalSince1970 * 1_000) && answer.int("to") == Int64(FakeBackend.skyTo.timeIntervalSince1970 * 1_000),
                "times are epoch milliseconds")
        let serverTime = try #require(answer.int("serverTime"))
        #expect(serverTime >= Int64(before.timeIntervalSince1970 * 1_000) - 1 && serverTime <= Int64(after.timeIntervalSince1970 * 1_000) + 1)

        let counts = answer.object("counts")
        #expect(counts["unexplained"] as? Int == 1 && counts["planes"] as? Int == 1 && counts["satellites"] as? Int == 0 && counts["meteors"] as? Int == 0)
        #expect(counts["bugsAndBirds"] as? Int == 1 && counts["notSure"] as? Int == 0 && counts["explained"] as? Int == 2, "the person's word counts: \(counts)")

        let entries = answer.array("entries")
        #expect(entries.compactMap { $0["id"] as? String } == ["p-1", "u-1", "s-1"], "only this camera's, by the time they began")
        let planeJSON = entries[0], oddJSON = entries[1], doubtedJSON = entries[2]
        #expect(planeJSON["display"] as? String == "plane" && planeJSON["label"] as? String == "plane" && planeJSON["by"] as? String == "flight")
        #expect(planeJSON["detail"] as? String == "TEST123 · 35,000 ft" && planeJSON["kind"] as? String == "track" && planeJSON["camera"] as? String == id.uuidString)
        #expect(doubtedJSON["label"] as? String == "satellite" && doubtedJSON["display"] as? String == "bird" && doubtedJSON["correction"] as? String == "bird",
                "display is what the person sees: their word wins")
        let startMs = Int64((Self.start.timeIntervalSince1970 * 1_000).rounded())
        #expect(jsonInt(planeJSON["start"]) == startMs && jsonInt(planeJSON["end"]) == startMs + 4_200, "times in milliseconds")
        #expect(jsonInt(planeJSON["watch"]) == startMs - 3_000, "the recordings' moment to open: three seconds before it began")
        #expect(jsonInt(oddJSON["watch"]) == startMs + 60_000 - 3_000)
        // Optional values are always there, as null.
        for key in ["by", "detail", "speedVsPlanes", "ai", "correction"] {
            #expect(oddJSON.keys.contains(key) && planeJSON.keys.contains(key), "\(key) is present even when it is nothing")
        }
        #expect(planeJSON["ai"] is NSNull && planeJSON["correction"] is NSNull && planeJSON["speedVsPlanes"] is NSNull)
        #expect(oddJSON["by"] is NSNull && oddJSON["detail"] is NSNull && oddJSON["correction"] is NSNull)
        #expect((oddJSON["unusual"] as? [String]) == ["faster", "larger"] && (oddJSON["speedVsPlanes"] as? Double) == 6.1)
        #expect(oddJSON["candidate"] as? Bool == true && oddJSON["alerted"] as? Bool == false && oddJSON["hasStill"] as? Bool == true)
        let ai = try #require(oddJSON["ai"] as? [String: Any])
        #expect(ai["kind"] as? String == "drone" && ai["sentence"] as? String == "A bright light moving fast." && ai["model"] as? String == "claude-haiku-5-5")
        #expect(jsonInt(ai["at"]) == startMs + 70_000, "the answer's time in milliseconds")
        let path = try #require(planeJSON["path"] as? [[String: Any]])
        #expect(path.count == 2 && path[1]["t"] as? Double == 4.2 && path[1]["x"] as? Double == 0.3 && path[1]["y"] as? Double == 0.25)
        let measures = try #require(planeJSON["measures"] as? [String: Any])
        #expect(measures["azimuth"] as? Double == 312 && measures["shape"] as? String == "straight" && measures["blinks"] as? Bool == true && measures["blinkRate"] as? Double == 1)
        #expect(Set(measures.keys) == ["azimuth", "elevation", "azimuthEnd", "elevationEnd", "duration", "speed", "acceleration", "turnRate", "maxTurn", "straightness",
                                       "shape", "sizeDegrees", "brightness", "blinks", "blinkRate", "focus"])

        let conditions = answer.array("conditions")
        #expect(conditions.count == 2 && conditions[0]["state"] as? String == "clear" && conditions[0]["cloudCover"] as? Int == 10)
        #expect(jsonInt(conditions[0]["from"]) == startMs && jsonInt(conditions[0]["to"]) == startMs + 3_600_000)
        #expect(conditions[1]["state"] as? String == "unknown" && conditions[1]["cloudCover"] is NSNull)
        let aim = answer.object("aim")
        #expect(aim["quality"] as? String == "good" && aim["planes"] as? Int == 23 && aim["stars"] as? Int == 0 && aim["residualPixels"] as? Double == 14)
        #expect(jsonInt(aim["updated"]) == startMs && aim["note"] as? String == "Aiming again.")
        #expect((aim["lenses"] as? [[String: Any]])?.first?["quality"] as? String == "good")
        let learning = answer.object("learning")
        #expect(learning["ready"] as? Bool == false && learning["planes"] as? Int == 12 && learning["satellites"] as? Int == 3)
        #expect(learning["planesNeeded"] as? Int == 30 && learning["satellitesNeeded"] as? Int == 10)
    }

    @Test func theLatestNightAndTheDayViewAreAskedForAndAnEmptyAimIsNull() async throws {
        let (backend, session, id) = try await ready()
        let latest = await session.get("/api/v1/sky/cameras/\(id.uuidString)/night")
        #expect(latest.status == 200 && latest.json["view"] as? String == "night")
        let day = await session.get("/api/v1/sky/cameras/\(id.uuidString)/night?view=day")
        #expect(day.status == 200 && day.json["view"] as? String == "day")
        let both = await session.get("/api/v1/sky/cameras/\(id.uuidString)/night?date=2026-10-25&view=day")
        #expect(both.status == 200 && both.json["night"] as? String == "2026-10-25")
        #expect(backend.read { $0.skyCalls } == ["night:\(id.uuidString):latest:night", "night:\(id.uuidString):latest:day", "night:\(id.uuidString):2026-10-25:day"])
        let aim = latest.object("aim")
        #expect(aim["quality"] as? String == "rough" && aim["residualPixels"] is NSNull && aim["updated"] is NSNull && aim["note"] is NSNull)
        #expect((aim["lenses"] as? [Any])?.isEmpty == true)
        #expect(latest.array("entries").isEmpty && latest.array("conditions").isEmpty)
        #expect(latest.object("counts").values.allSatisfy { ($0 as? Int) == 0 } && latest.object("counts").count == 7)
    }

    @Test func theNightRouteRefusesWhatItCannotAnswer() async throws {
        let (backend, session, id) = try await ready()
        for (query, field) in [("date=tonight", "date"), ("date=2026-13-01", "date"), ("date=2026-10-4", "date"), ("date=", "date"), ("date=../x", "date"),
                               ("view=week", "view"), ("view=", "view"), ("view=NIGHT", "view")] {
            let answer = await session.get("/api/v1/sky/cameras/\(id.uuidString)/night?\(query)")
            #expect(answer.status == 400 && answer.json["field"] as? String == field, "\(query): \(answer.status) \(answer.text)")
        }
        #expect(backend.read { $0.skyCalls.isEmpty }, "none of them reached the log")
        let unknown = await session.get("/api/v1/sky/cameras/\(UUID().uuidString)/night")
        #expect(unknown.status == 404)
        let notAnID = await session.get("/api/v1/sky/cameras/not-a-camera/night")
        #expect(notAnID.status == 404)

        // What the engine says when the log cannot be read is said in its words.
        backend.write { $0.skyError = SkyLogError.noLocation }
        let noPlace = await session.get("/api/v1/sky/cameras/\(id.uuidString)/night")
        #expect(noPlace.status == 409 && noPlace.json["error"] as? String == "no_location" && noPlace.json["message"] as? String == Self.enableMessage)
        backend.write { $0.skyError = SkyLogError.noFolder }
        let noFolder = await session.get("/api/v1/sky/cameras/\(id.uuidString)/night")
        #expect(noFolder.status == 409 && noFolder.json["error"] as? String == "no_folder" && noFolder.json["message"] as? String == Self.folderMessage)
        backend.write { $0.skyError = SkyLogError.unknownNight }
        let badNight = await session.get("/api/v1/sky/cameras/\(id.uuidString)/night?date=2026-02-30")
        #expect(badNight.status == 400 && badNight.json["field"] as? String == "date")
        backend.write { $0.skyError = ArchiveUnavailable.folderMissing }
        let away = await session.get("/api/v1/sky/cameras/\(id.uuidString)/night")
        #expect(away.status == 503 && away.json["error"] as? String == "archive_unavailable" && away.headers["Retry-After"] != nil)
        backend.write { $0.skyError = ArchiveError.timedOut }
        #expect(await session.get("/api/v1/sky/cameras/\(id.uuidString)/night").status == 504)
        backend.write { $0.skyError = SkyLogError.unavailable }
        #expect(await session.get("/api/v1/sky/cameras/\(id.uuidString)/night").status == 503)
    }

    // MARK: Corrections

    @Test func correctionRouteWritesAndAnswers() async throws {
        let (backend, session, id) = try await ready()
        backend.write { $0.skyEntries = [Self.entry("u-1", camera: id, at: 0, hasStill: true), Self.entry("p-1", camera: id, at: 60, label: .plane, by: .flight)] }
        let path = "/api/v1/sky/cameras/\(id.uuidString)/entries/u-1/correction"
        let bird = await session.send("POST", path, json: ["night": "2026-10-24", "label": "bird"])
        #expect(bird.status == 200, "\(bird.text)")
        #expect(bird.json["id"] as? String == "u-1" && bird.json["correction"] as? String == "bird" && bird.json["display"] as? String == "bird")
        #expect(bird.json["label"] as? String == "unexplained", "the box's own label is as it was")
        #expect(bird.json["watch"] != nil && bird.json["measures"] != nil && bird.json["ai"] is NSNull)
        #expect(backend.read { $0.skyEntries.first { $0.id == "u-1" }?.correction } == .bird)
        #expect(backend.read { $0.skyCalls } == ["correct:u-1:2026-10-24:bird"])

        for label in ["plane", "bug", "satellite", "meteor", "notSure", "bird"] {
            let answer = await session.send("POST", path, json: ["night": "2026-10-24", "label": label])
            #expect(answer.status == 200 && answer.json["correction"] as? String == label, "\(label): \(answer.text)")
        }
        // "Not sure" shows the box's own label again.
        let doubt = await session.send("POST", "/api/v1/sky/cameras/\(id.uuidString)/entries/p-1/correction", json: ["night": "2026-10-24", "label": "notSure"])
        #expect(doubt.json["correction"] as? String == "notSure" && doubt.json["display"] as? String == "plane")

        // What is refused never reaches the log.
        let calls = backend.read { $0.skyCalls.count }
        for (body, field) in [(["night": "2026-10-24", "label": "ufo"], "label"), (["night": "2026-10-24", "label": "Bird"], "label"),
                              (["night": "2026-10-24", "label": ""], "label"), (["night": "last night", "label": "bird"], "night"),
                              (["night": "../2026-10-24", "label": "bird"], "night"), (["night": "", "label": "bird"], "night")] {
            let answer = await session.send("POST", path, json: body)
            #expect(answer.status == 400 && answer.json["field"] as? String == field, "\(body): \(answer.status) \(answer.text)")
        }
        let ufo = await session.send("POST", path, json: ["night": "2026-10-24", "label": "ufo"])
        #expect((ufo.json["message"] as? String)?.contains("Plane, Bird, Bug, Satellite, Meteor or Not sure") == true, "\(ufo.text)")
        for body: Any in [["label": "bird"], ["night": "2026-10-24"], ["night": 5, "label": "bird"], ["night": "2026-10-24", "label": 3], [String: Any](), [1, 2]] {
            #expect(await session.send("POST", path, json: body).status == 400)
        }
        #expect(await session.send("POST", path).status == 400, "no body")
        #expect(backend.read { $0.skyCalls.count } == calls, "nothing reached the log")

        // Unknown things are 404.
        let ghost = await session.send("POST", "/api/v1/sky/cameras/\(id.uuidString)/entries/ghost/correction", json: ["night": "2026-10-24", "label": "bird"])
        #expect(ghost.status == 404)
        let strange = await session.send("POST", "/api/v1/sky/cameras/\(id.uuidString)/entries/a%2Fb/correction", json: ["night": "2026-10-24", "label": "bird"])
        #expect(strange.status == 404, "an id that cannot be one is not looked for")
        let elsewhere = await session.send("POST", "/api/v1/sky/cameras/\(UUID().uuidString)/entries/u-1/correction", json: ["night": "2026-10-24", "label": "bird"])
        #expect(elsewhere.status == 404)
        backend.write { $0.skyError = SkyLogError.noFolder }
        let noFolder = await session.send("POST", path, json: ["night": "2026-10-24", "label": "bird"])
        #expect(noFolder.status == 409 && noFolder.json["message"] as? String == Self.folderMessage)
    }

    // MARK: Stills

    @Test func stillRouteServesJPEGOrNotFound() async throws {
        let (backend, session, id) = try await ready()
        backend.write { $0.skyStills["u-1"] = Self.jpeg }
        let path = "/api/v1/sky/cameras/\(id.uuidString)/entries/u-1/still"
        let answer = await session.get(path + "?night=2026-10-24")
        #expect(answer.status == 200 && answer.headers["Content-Type"] == "image/jpeg" && answer.body == Self.jpeg, "\(answer.status)")
        #expect(backend.read { $0.skyCalls } == ["still:u-1:2026-10-24"])
        #expect(answer.headers["X-Content-Type-Options"] == "nosniff", "served as the picture it is")

        let missing = await session.get("/api/v1/sky/cameras/\(id.uuidString)/entries/u-2/still?night=2026-10-24")
        #expect(missing.status == 404 && missing.json["error"] as? String == "not_found")
        for query in ["", "?night=", "?night=tonight", "?night=../x", "?night=2026-13-40"] {
            let answer = await session.get(path + query)
            #expect(answer.status == 400 && answer.json["field"] as? String == "night", "\(query): \(answer.status)")
        }
        #expect(await session.get("/api/v1/sky/cameras/\(id.uuidString)/entries/a%2Fb/still?night=2026-10-24").status == 404)
        #expect(await session.get("/api/v1/sky/cameras/\(UUID().uuidString)/entries/u-1/still?night=2026-10-24").status == 404)
        backend.write { $0.skyError = SkyLogError.noFolder }
        #expect(await session.get(path + "?night=2026-10-24").status == 409)
    }

    // MARK: Flight feeds

    @Test func theFeedFinderAnswersTheFeedsItFound() async throws {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        let none = await session.send("POST", "/api/v1/sky/feeds/find")
        #expect(none.status == 200 && (none.json["feeds"] as? [String])?.isEmpty == true, "\(none.text)")
        backend.write { $0.feeds = [URL(string: "http://192.168.77.20/tar1090/data/aircraft.json")!, URL(string: "http://192.168.77.21:8080/data/aircraft.json")!] }
        let found = await session.send("POST", "/api/v1/sky/feeds/find", json: [String: Any]())
        #expect(found.status == 200 && found.json["feeds"] as? [String] == ["http://192.168.77.20/tar1090/data/aircraft.json", "http://192.168.77.21:8080/data/aircraft.json"])
        #expect(backend.read { $0.skyCalls } == ["feeds", "feeds"])
    }

    // MARK: Settings

    @Test func settingsCarrySkyAndTakeIt() async throws {
        let capture = LogCapture()
        defer { capture.stop() }
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let start = await session.get("/api/v1/settings")
        let initial = start.object("sky")
        #expect(initial["location"] is NSNull && initial.keys.contains("location") && initial["flightFeedURL"] is NSNull && initial["aiDailyLimit"] as? Int == 50)

        let placed = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["location": Self.place]])
        #expect(placed.status == 200, "\(placed.text)")
        let location = try #require(placed.object("sky")["location"] as? [String: Any])
        #expect(location["latitude"] as? Double == 40 && location["longitude"] as? Double == -100 && location["heightMeters"] as? Double == 0)
        #expect(backend.read { $0.settings.sky.location } == SkyLocation(latitude: 40, longitude: -100, heightMeters: 0))
        // The signed-in page reads it back.
        #expect((await session.get("/api/v1/settings")).object("sky")["location"] as? [String: Any] != nil)

        let feed = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["flightFeedURL": "  http://192.168.77.20/tar1090/data/aircraft.json \n", "aiDailyLimit": 25]])
        #expect(feed.status == 200 && feed.object("sky")["flightFeedURL"] as? String == "http://192.168.77.20/tar1090/data/aircraft.json" && feed.object("sky")["aiDailyLimit"] as? Int == 25)
        #expect(backend.read { $0.settings.sky.location != nil }, "what was not sent stays")

        let high = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["location": ["latitude": 40.25, "longitude": -100.5, "heightMeters": 412.5]]])
        #expect(backend.read { $0.settings.sky.location } == SkyLocation(latitude: 40.25, longitude: -100.5, heightMeters: 412.5) && high.status == 200)
        // A place is replaced whole: sent with two numbers, as the page does, it is at 0 m.
        _ = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["location": ["latitude": 41, "longitude": -101]]])
        #expect(backend.read { $0.settings.sky.location } == SkyLocation(latitude: 41, longitude: -101, heightMeters: 0))

        // Taking them away: null, or for the feed also an empty string.
        let noFeed = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["flightFeedURL": ""]])
        #expect(noFeed.object("sky")["flightFeedURL"] is NSNull)
        _ = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["flightFeedURL": "https://feed.example.com/aircraft.json"]])
        #expect((await session.send("PATCH", "/api/v1/settings", json: ["sky": ["flightFeedURL": NSNull()]])).object("sky")["flightFeedURL"] is NSNull)
        let cleared = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["location": NSNull()]])
        #expect(cleared.status == 200 && cleared.object("sky")["location"] is NSNull && backend.read { $0.settings.sky.location } == nil)

        // The place is in no log line the web interface wrote. (The made-up place with four more digits: the log is shared by the tests that run
        // side by side, and none of their lines has these.)
        let sent = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["location": ["latitude": 40.0123, "longitude": -100.0456]]])
        #expect(sent.status == 200 && sent.object("sky")["location"] as? [String: Any] != nil)
        _ = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["location": ["latitude": 91.0123, "longitude": -100.0456]]])   // and a refused one
        for needle in ["40.0123", "100.0456", "40.012", "100.045", "91.012"] {
            #expect(!capture.text.contains { $0.contains(needle) }, "a log line holds \(needle): \(capture.text.filter { $0.contains(needle) })")
        }
        #expect(capture.text.contains { $0.contains("PATCH /api/v1/settings") }, "the request line is written, without the body")
        // Nor in what a visitor who has not signed in can read, nor in the cameras' list.
        let anonymous = await harness.send("GET", "/api/v1/settings")
        #expect(anonymous.status == 401 && !anonymous.text.contains("40.0") && !anonymous.text.contains("100.0"))
        let status = await harness.send("GET", "/api/v1/status")
        #expect(!status.text.contains("40.0") && !status.text.contains("latitude"))
        let signedInStatus = await session.get("/api/v1/status")
        #expect(!signedInStatus.text.contains("latitude") && !signedInStatus.text.contains("100.0"))
        #expect(!(await session.get("/api/v1/cameras")).text.contains("latitude"))
    }

    @Test func nullRemovesTheFeedAndThePlaceAndLeavingThemOutChangesNothing() async throws {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        let feed = "http://192.168.77.20/tar1090/data/aircraft.json"
        _ = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["location": Self.place, "flightFeedURL": feed, "aiDailyLimit": 20]])
        #expect(backend.read { $0.settings.sky } == SkySettings(location: SkyLocation(latitude: 40, longitude: -100), flightFeedURL: feed, aiDailyLimit: 20))

        // Left out: unchanged, whatever else is sent.
        for body in [[String: Any](), ["aiDailyLimit": 30], ["flightFeedURL": feed], ["location": Self.place]] as [[String: Any]] {
            let answer = await session.send("PATCH", "/api/v1/settings", json: ["sky": body, "basePort": 21_100])
            #expect(answer.status == 200 && answer.object("sky")["flightFeedURL"] as? String == feed && answer.object("sky")["location"] as? [String: Any] != nil, "\(body)")
        }
        #expect(await session.send("PATCH", "/api/v1/settings", json: ["bridgeName": "Hall"]).status == 200, "a request with no sky at all")
        #expect(backend.read { $0.settings.sky.flightFeedURL == feed && $0.settings.sky.location != nil })

        // null removes the feed, and only the feed.
        let noFeed = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["flightFeedURL": NSNull()]])
        #expect(noFeed.status == 200 && noFeed.object("sky")["flightFeedURL"] is NSNull && noFeed.object("sky")["location"] as? [String: Any] != nil, "\(noFeed.text)")
        #expect(backend.read { $0.settings.sky.flightFeedURL == nil && $0.settings.sky.location != nil && $0.settings.sky.aiDailyLimit == 30 })
        #expect((await session.get("/api/v1/settings")).object("sky")["flightFeedURL"] is NSNull, "and it stays removed")

        // null removes the place, and only the place.
        _ = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["flightFeedURL": feed]])
        let noPlace = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["location": NSNull()]])
        #expect(noPlace.status == 200 && noPlace.object("sky")["location"] is NSNull && noPlace.object("sky")["flightFeedURL"] as? String == feed, "\(noPlace.text)")
        #expect(backend.read { $0.settings.sky.location == nil && $0.settings.sky.flightFeedURL == feed })
        #expect((await session.get("/api/v1/settings")).object("sky")["location"] is NSNull, "and it stays removed")
        // Both at once.
        let neither = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["location": NSNull(), "flightFeedURL": NSNull()]])
        #expect(neither.status == 200 && backend.read { $0.settings.sky == SkySettings(location: nil, flightFeedURL: nil, aiDailyLimit: 30) })
    }

    @Test func settingsThatCannotBeKeptAreRefusedWithTheirField() async throws {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        let refused: [([String: Any], String)] = [
            (["location": ["latitude": 91, "longitude": -100]], "sky.location"),
            (["location": ["latitude": -91, "longitude": -100]], "sky.location"),
            (["location": ["latitude": 40, "longitude": 181]], "sky.location"),
            (["location": ["latitude": 0, "longitude": 0]], "sky.location"),
            (["location": ["latitude": 40, "longitude": -100, "heightMeters": 50_000]], "sky.location"),
            (["flightFeedURL": "ftp://192.168.77.20/aircraft.json"], "sky.flightFeedURL"),
            (["flightFeedURL": "192.168.77.20/aircraft.json"], "sky.flightFeedURL"),
            (["flightFeedURL": "http://user:pw@192.168.77.20/aircraft.json"], "sky.flightFeedURL"),
            (["aiDailyLimit": 0], "sky.aiDailyLimit"),
            (["aiDailyLimit": 1_001], "sky.aiDailyLimit"),
        ]
        for (body, field) in refused {
            let answer = await session.send("PATCH", "/api/v1/settings", json: ["sky": body])
            #expect(answer.status == 400 && answer.json["field"] as? String == field, "\(body): \(answer.status) \(answer.text)")
            #expect(!(answer.json["message"] as? String ?? "").isEmpty && !answer.text.contains("91") && !answer.text.contains("50000"), "the words do not repeat what was sent")
        }
        // Not what the field takes.
        for body: Any in [["location": "home"], ["location": ["latitude": "north", "longitude": -100]], ["location": ["latitude": 40]], ["aiDailyLimit": "many"],
                          ["flightFeedURL": 7], "sky", ["location": [Any]()]] {
            #expect(await session.send("PATCH", "/api/v1/settings", json: ["sky": body]).status == 400, "\(body)")
        }
        #expect(backend.read { $0.settings.sky } == SkySettings(), "nothing was saved")
        // A refusal stops the whole request.
        let mixed = await session.send("PATCH", "/api/v1/settings", json: ["basePort": 22_000, "sky": ["aiDailyLimit": 0]])
        #expect(mixed.status == 400)
        #expect((await session.get("/api/v1/settings")).json["basePort"] as? Int == 21_100)
        // The edges that are allowed.
        for body in [["aiDailyLimit": 1], ["aiDailyLimit": 1_000], ["location": ["latitude": 90, "longitude": 180]], ["location": ["latitude": -90, "longitude": -180]]] as [[String: Any]] {
            #expect(await session.send("PATCH", "/api/v1/settings", json: ["sky": body]).status == 200, "\(body)")
        }
    }

    // MARK: A camera's switch

    @Test func theCameraResourceCarriesSkyDetector() async throws {
        let (backend, session, id) = try await ready()
        // Never set: the key is there, null.
        let list = await session.get("/api/v1/cameras")
        let camera = try #require(list.array("cameras").first)
        #expect(camera.keys.contains("skyDetector") && camera["skyDetector"] is NSNull, "\(camera.keys.sorted())")
        let one = await session.get("/api/v1/cameras/\(id.uuidString)")
        #expect(one.json.keys.contains("skyDetector") && one.json["skyDetector"] is NSNull)
        // A camera that has just been added says so too.
        let second = await session.send("POST", "/api/v1/cameras", json: ["type": "automatic", "host": "192.168.77.31", "username": "viewer", "password": "pw", "name": "East"])
        #expect(second.status == 201 && second.json.keys.contains("skyDetector") && second.json["skyDetector"] is NSNull)

        // Saved: the settings object, with the page's names.
        backend.write { state in
            state.configurations[0].skyDetector = SkyDetectorSettings(enabled: true, facing: 315, tilt: 30, groundPercent: 8, nightProfile: false, lensLayout: .dual)
        }
        for json in [(await session.get("/api/v1/cameras")).array("cameras").first, (await session.get("/api/v1/cameras/\(id.uuidString)")).json] {
            let saved = try #require(json?["skyDetector"] as? [String: Any])
            #expect(saved["enabled"] as? Bool == true && saved["facing"] as? Double == 315 && saved["tilt"] as? Double == 30)
            #expect(saved["groundPercent"] as? Int == 8 && saved["nightProfile"] as? Bool == false && saved["lensLayout"] as? String == "dual")
        }
        // A lens layout left automatic is null, not missing.
        backend.write { $0.configurations[0].skyDetector = SkyDetectorSettings(enabled: true) }
        let automatic = (await session.get("/api/v1/cameras/\(id.uuidString)")).json["skyDetector"] as? [String: Any]
        #expect(automatic?.keys.contains("lensLayout") == true && automatic?["lensLayout"] is NSNull)
    }

    @Test func enablingNeedsALocationAndAFolder() async throws {
        let (backend, session, id) = try await ready(place: false, folder: false)
        let path = "/api/v1/cameras/\(id.uuidString)"
        let neither = await session.send("PATCH", path, json: ["skyDetector": ["enabled": true]])
        #expect(neither.status == 400 && neither.json["message"] as? String == Self.enableMessage && neither.json["field"] as? String == "sky.location", "\(neither.text)")
        backend.write { $0.settings.sky.location = SkyLocation(latitude: 40, longitude: -100) }
        let noFolder = await session.send("PATCH", path, json: ["skyDetector": ["enabled": true]])
        #expect(noFolder.status == 400 && noFolder.json["message"] as? String == Self.folderMessage && noFolder.json["field"] as? String == "nvrFolder", "\(noFolder.text)")
        #expect(backend.read { $0.configurations[0].skyDetector } == nil && backend.read { !$0.calls.contains("update") }, "nothing was changed")

        backend.write { $0.settings.nvrFolder = "/srv/recordings" }
        let on = await session.send("PATCH", path, json: ["skyDetector": ["enabled": true]])
        #expect(on.status == 200, "\(on.text)")
        // Everything the page did not send is the design's default.
        #expect(sky(on)["enabled"] as? Bool == true && sky(on)["facing"] as? Double == 0 && sky(on)["tilt"] as? Double == 20)
        #expect(sky(on)["groundPercent"] as? Int == 12 && sky(on)["nightProfile"] as? Bool == true && sky(on)["lensLayout"] is NSNull)
        #expect(backend.read { $0.configurations[0].skyDetector } == SkyDetectorSettings(enabled: true))

        // Turning it off needs neither, whatever happened to them since.
        backend.write { $0.settings.sky.location = nil; $0.settings.nvrFolder = nil }
        let off = await session.send("PATCH", path, json: ["skyDetector": ["enabled": false]])
        #expect(off.status == 200 && sky(off)["enabled"] as? Bool == false && sky(off)["facing"] as? Double == 0, "\(off.text)")
        // A camera that is on can change its aim without either.
        backend.write { $0.configurations[0].skyDetector = SkyDetectorSettings(enabled: true) }
        let aimed = await session.send("PATCH", path, json: ["skyDetector": ["facing": 90]])
        #expect(aimed.status == 200 && sky(aimed)["facing"] as? Double == 90 && sky(aimed)["enabled"] as? Bool == true)
        // But saying "on" again asks again.
        #expect(await session.send("PATCH", path, json: ["skyDetector": ["enabled": true, "facing": 91]]).status == 400)
    }

    @Test func aCameraSkySettingsPatchMergesAndIsChecked() async throws {
        let (backend, session, id) = try await ready()
        let path = "/api/v1/cameras/\(id.uuidString)"
        let full = await session.send("PATCH", path, json: ["skyDetector": ["enabled": true, "facing": 315, "tilt": 30, "groundPercent": 8, "nightProfile": false, "lensLayout": "dual"]])
        #expect(full.status == 200 && backend.read { $0.configurations[0].skyDetector } ==
                SkyDetectorSettings(enabled: true, facing: 315, tilt: 30, groundPercent: 8, nightProfile: false, lensLayout: .dual), "\(full.text)")
        #expect(backend.read { $0.calls.filter { $0 == "update" }.count } == 1)
        // A field that is left out stays; lensLayout null is automatic; single is single.
        _ = await session.send("PATCH", path, json: ["skyDetector": ["tilt": 45]])
        #expect(backend.read { $0.configurations[0].skyDetector } == SkyDetectorSettings(enabled: true, facing: 315, tilt: 45, groundPercent: 8, nightProfile: false, lensLayout: .dual))
        let automatic = await session.send("PATCH", path, json: ["skyDetector": ["lensLayout": NSNull()]])
        #expect(automatic.status == 200 && sky(automatic)["lensLayout"] is NSNull && backend.read { $0.configurations[0].skyDetector?.lensLayout } == nil)
        #expect(sky(await session.send("PATCH", path, json: ["skyDetector": ["lensLayout": "single"]]))["lensLayout"] as? String == "single")
        // The edges.
        for body in [["facing": 0], ["facing": 359.5], ["tilt": 0], ["tilt": 90], ["groundPercent": 0], ["groundPercent": 60]] as [[String: Any]] {
            #expect(await session.send("PATCH", path, json: ["skyDetector": body]).status == 200, "\(body)")
        }
        // What cannot be kept names its field; a refusal stops the whole request (the name is not changed).
        let before = backend.read { $0.configurations[0] }
        let refused: [([String: Any], String)] = [
            (["lensLayout": "triple"], "skyDetector.lensLayout"), (["lensLayout": ""], "skyDetector.lensLayout"), (["lensLayout": "Dual"], "skyDetector.lensLayout"),
            (["facing": 360], "skyDetector.facing"), (["facing": -1], "skyDetector.facing"), (["tilt": 91], "skyDetector.tilt"), (["tilt": -1], "skyDetector.tilt"),
            (["groundPercent": 61], "skyDetector.groundPercent"), (["groundPercent": -1], "skyDetector.groundPercent"),
        ]
        for (body, field) in refused {
            let answer = await session.send("PATCH", path, json: ["name": "Renamed", "skyDetector": body])
            #expect(answer.status == 400 && answer.json["field"] as? String == field, "\(body): \(answer.status) \(answer.text)")
            #expect(!(answer.json["message"] as? String ?? "").isEmpty)
        }
        for body: Any in [["facing": "north"], ["groundPercent": 12.5], ["enabled": "yes"], ["nightProfile": 1], "dual", [1]] {
            #expect(await session.send("PATCH", path, json: ["skyDetector": body]).status == 400, "\(body)")
        }
        // A null in a field that cannot be taken away is no change.
        let nulls = await session.send("PATCH", path, json: ["skyDetector": ["tilt": NSNull(), "facing": NSNull()]])
        #expect(nulls.status == 200 && backend.read { $0.configurations[0].skyDetector } == before.skyDetector)
        #expect(backend.read { $0.configurations[0] } == before, "nothing was changed")
        // The sentence for an unknown layout says what is allowed.
        let layout = await session.send("PATCH", path, json: ["skyDetector": ["lensLayout": "triple"]])
        #expect((layout.json["message"] as? String)?.contains("single") == true && (layout.json["message"] as? String)?.contains("dual") == true, "\(layout.text)")
    }

    @Test func batteryCamerasCannotWatchTheSky() async throws {
        let (backend, session, id) = try await ready()
        backend.write { state in
            state.configurations[0].vendor = .go2rtc
            state.configurations[0].integration = IntegrationSettings(service: .eufy)
        }
        let path = "/api/v1/cameras/\(id.uuidString)"
        let refused = await session.send("PATCH", path, json: ["skyDetector": ["enabled": true]])
        #expect(refused.status == 400 && refused.json["message"] as? String == Self.batteryMessage && refused.json["field"] as? String == "skyDetector.enabled", "\(refused.text)")
        #expect(backend.read { $0.configurations[0].skyDetector } == nil)
        // The words come first even when the box has no place yet: nothing the person does will change them.
        backend.write { $0.settings.sky.location = nil }
        #expect((await session.send("PATCH", path, json: ["skyDetector": ["enabled": true]])).json["message"] as? String == Self.batteryMessage)
        // Off is always allowed, and so is saving the aim without turning it on.
        #expect((await session.send("PATCH", path, json: ["skyDetector": ["enabled": false]])).status == 200)
        // A camera on the network is not one.
        backend.write { state in
            state.configurations[0].vendor = .hikvision
            state.configurations[0].integration = nil
            state.settings.sky.location = SkyLocation(latitude: 40, longitude: -100)
        }
        #expect((await session.send("PATCH", path, json: ["skyDetector": ["enabled": true]])).status == 200)
    }

    // MARK: The plugin

    private func skyPlugin(_ session: Harness.Session) async throws -> [String: Any] {
        let list = await session.get("/api/v1/plugins")
        let plugins = try #require(list.json["plugins"] as? [[String: Any]], "\(list.text)")
        return try #require(plugins.first { $0["id"] as? String == "sky" }, "the Sky Watcher is in the plugins' list: \(list.text)")
    }

    @Test func theSkyWatcherIsAPluginThatIsOffUntilItsSwitchIsOn() async throws {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        #expect(backend.read { $0.settings.skyPluginOn } == false, "a new box has it off")
        let list = await session.get("/api/v1/plugins")
        #expect((list.json["plugins"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["wyze", "eufy", "sky"], "the third plugin")
        let off = try await skyPlugin(session)
        #expect(off["name"] as? String == "Sky Watcher" && off["enabled"] as? Bool == false)
        #expect(off["summary"] as? String == "Watches the sky with a camera pointed up and keeps a log of planes, satellites, meteors and anything it can’t explain.")
        #expect(!(off["needs"] as? String ?? "").isEmpty, "what it needs, in a sentence")
        #expect(off["account"] == nil && off["lastSync"] == nil && off["lastError"] == nil, "no account, no sign-in and no sync")

        let on = await session.send("PATCH", "/api/v1/plugins/sky", json: ["enabled": true])
        #expect(on.status == 200, "\(on.text)")
        #expect(backend.read { $0.settings.skyPluginOn } && backend.read { $0.settings.plugins["sky"]?.enabled } == true, "the switch is the stored one")
        let answered = try #require((on.json["plugins"] as? [[String: Any]])?.first { $0["id"] as? String == "sky" }, "\(on.text)")
        #expect(answered["enabled"] as? Bool == true, "the answer is the list, as for the others")
        #expect(try await skyPlugin(session)["enabled"] as? Bool == true)

        let back = await session.send("PATCH", "/api/v1/plugins/sky", json: ["enabled": false])
        #expect(back.status == 200 && backend.read { !$0.settings.skyPluginOn })
        #expect(backend.read { $0.settings.plugins["wyze"] == nil && $0.settings.plugins["eufy"] == nil }, "the others are not touched")
        #expect(backend.read { $0.settings.sky == SkySettings() }, "and neither are the Sky Watcher's own settings")
    }

    @Test func enablingACameraNeedsThePluginSwitchedOnFirst() async throws {
        let (backend, session, id) = try await ready(plugin: false)   // the box knows where it is and has a recordings folder
        let path = "/api/v1/cameras/\(id.uuidString)"
        let body: [String: Any] = ["skyDetector": ["enabled": true, "facing": 90]]
        let refused = await session.send("PATCH", path, json: body)
        #expect(refused.status == 400 && refused.json["error"] as? String == "invalid", "\(refused.text)")
        #expect(refused.json["field"] as? String == "plugins.sky" && refused.json["message"] as? String == Self.pluginMessage, "\(refused.text)")
        #expect(backend.read { $0.configurations[0].skyDetector } == nil && backend.read { !$0.calls.contains("update") }, "nothing was changed, not even the aim that came with it")
        // A name that goes with it is not saved either: a refusal stops the whole request.
        let renamed = await session.send("PATCH", path, json: ["name": "Roof", "skyDetector": ["enabled": true]])
        #expect(renamed.status == 400 && backend.read { $0.configurations[0].name } == "North Sky")

        // Switched on in Plugins, the same request works (the box has its place and its folder).
        #expect(await session.send("PATCH", "/api/v1/plugins/sky", json: ["enabled": true]).status == 200)
        let on = await session.send("PATCH", path, json: body)
        #expect(on.status == 200 && sky(on)["enabled"] as? Bool == true && sky(on)["facing"] as? Double == 90, "\(on.text)")
        #expect(backend.read { $0.configurations[0].skyDetector } == SkyDetectorSettings(enabled: true, facing: 90))
    }

    @Test func thePluginComesBeforeAnythingElseEnablingNeeds() async throws {
        // No place, no folder, a camera on a battery and the plugin off: the plugin is the first thing to do, then the camera's own limit, then the box's.
        let (backend, session, id) = try await ready(place: false, folder: false, plugin: false)
        backend.write { state in
            state.configurations[0].vendor = .go2rtc
            state.configurations[0].integration = IntegrationSettings(service: .eufy)
        }
        let path = "/api/v1/cameras/\(id.uuidString)"
        func refusal() async -> (String?, String?) {
            let answer = await session.send("PATCH", path, json: ["skyDetector": ["enabled": true]])
            return (answer.json["message"] as? String, answer.json["field"] as? String)
        }
        var (message, field) = await refusal()
        #expect(message == Self.pluginMessage && field == "plugins.sky")
        backend.write { $0.settings.plugins["sky"] = PluginState(enabled: true) }
        (message, field) = await refusal()
        #expect(message == Self.batteryMessage && field == "skyDetector.enabled")
        backend.write { state in
            state.configurations[0].vendor = .hikvision
            state.configurations[0].integration = nil
        }
        (message, field) = await refusal()
        #expect(message == Self.enableMessage && field == "sky.location")
        backend.write { $0.settings.sky.location = SkyLocation(latitude: 40, longitude: -100) }
        (message, field) = await refusal()
        #expect(message == Self.folderMessage && field == "nvrFolder")
        // The switch being off again brings the first sentence back, whatever else is in place.
        backend.write { state in
            state.settings.nvrFolder = "/srv/recordings"
            state.settings.plugins["sky"] = PluginState(enabled: false)
        }
        (message, field) = await refusal()
        #expect(message == Self.pluginMessage && field == "plugins.sky")
    }

    @Test func switchingThePluginOffKeepsEveryCamerasSkySettingsSoSwitchingItOnBringsThemBack() async throws {
        let (backend, session, id) = try await ready()
        let second = try await addCamera(session, host: "192.168.77.31")
        let path = "/api/v1/cameras/\(id.uuidString)"
        let kept = SkyDetectorSettings(enabled: true, facing: 315, tilt: 30, groundPercent: 8, nightProfile: false, lensLayout: .dual)
        let full = await session.send("PATCH", path, json: ["skyDetector": ["enabled": true, "facing": 315, "tilt": 30, "groundPercent": 8, "nightProfile": false, "lensLayout": "dual"]])
        #expect(full.status == 200 && backend.read { $0.configurations[0].skyDetector } == kept, "\(full.text)")
        let other = SkyDetectorSettings(enabled: false, facing: 90, tilt: 10, groundPercent: 20, nightProfile: true, lensLayout: .single)
        backend.write { state in state.configurations[state.configurations.firstIndex { $0.id == second }!].skyDetector = other }
        let before = backend.read { $0.configurations }

        let off = await session.send("PATCH", "/api/v1/plugins/sky", json: ["enabled": false])
        #expect(off.status == 200)
        #expect(backend.read { $0.configurations } == before, "no camera was touched")
        #expect(backend.read { $0.configurations[0].skyDetector } == kept)
        let resource = await session.get(path)
        #expect(sky(resource)["enabled"] as? Bool == true && sky(resource)["facing"] as? Double == 315 && sky(resource)["lensLayout"] as? String == "dual",
                "the camera still says what it was set to: \(resource.text)")

        let on = await session.send("PATCH", "/api/v1/plugins/sky", json: ["enabled": true])
        #expect(on.status == 200)
        #expect(backend.read { $0.configurations } == before, "the same cameras are back, as they were")
        #expect(backend.read { $0.configurations[0].skyDetector?.enabled } == true)
    }

    @Test func whileThePluginIsOffSavingOffOrTheAimStillWorks() async throws {
        let (backend, session, id) = try await ready(plugin: false)
        let path = "/api/v1/cameras/\(id.uuidString)"
        // A camera whose settings were kept from before: on, facing north.
        backend.write { $0.configurations[0].skyDetector = SkyDetectorSettings(enabled: true) }
        let aimed = await session.send("PATCH", path, json: ["skyDetector": ["facing": 90, "tilt": 45]])
        #expect(aimed.status == 200 && backend.read { $0.configurations[0].skyDetector } == SkyDetectorSettings(enabled: true, facing: 90, tilt: 45), "\(aimed.text)")
        // Saying "on" again asks for the plugin; saying "off" never does.
        #expect((await session.send("PATCH", path, json: ["skyDetector": ["enabled": true]])).status == 400)
        let stopped = await session.send("PATCH", path, json: ["skyDetector": ["enabled": false]])
        #expect(stopped.status == 200 && sky(stopped)["enabled"] as? Bool == false && sky(stopped)["facing"] as? Double == 90, "\(stopped.text)")
        // The rest of the camera is saved as always.
        let renamed = await session.send("PATCH", path, json: ["name": "Roof"])
        #expect(renamed.status == 200 && backend.read { $0.configurations[0].name } == "Roof")
        // The box's own settings for it (the place and the feed) are not the plugin's to refuse.
        let place = await session.send("PATCH", "/api/v1/settings", json: ["sky": ["location": ["latitude": 41.5, "longitude": -100.25], "flightFeedURL": "http://192.168.77.20/tar1090/data/aircraft.json"]])
        #expect(place.status == 200 && backend.read { $0.settings.sky.location?.latitude } == 41.5, "\(place.text)")
    }

    // MARK: Who may ask

    @Test func everySkyRouteNeedsASessionAndChangesNeedTheTokenToo() async throws {
        let (backend, session, id) = try await ready()
        backend.write { $0.skyStills["u-1"] = Self.jpeg; $0.skyEntries = [Self.entry("u-1", camera: id, at: 0)] }
        let harness = session.harness
        let routes = WebApp.skyRoutes
        let expected = ["GET sky/cameras/:id/night", "GET sky/cameras/:id/entries/:eid/still", "POST sky/cameras/:id/entries/:eid/correction", "POST sky/feeds/find"]
        func name(_ route: Route) -> String { "\(route.method) \(route.pattern.joined(separator: "/"))" }
        #expect(routes.map(name) == expected && routes.allSatisfy { $0.access == .session })
        #expect(Set(WebApp.routes.map(name)).isSuperset(of: expected), "and they are in the route table the application serves")
        let calls = backend.read { $0.skyCalls.count }
        for route in routes {
            let path = "/api/v1/" + route.pattern.map { $0 == ":id" ? id.uuidString : $0 == ":eid" ? "u-1" : $0 }.joined(separator: "/")
                + (route.pattern.last == "still" ? "?night=2026-10-24" : "")
            let json: [String: Any]? = route.method == "POST" ? ["night": "2026-10-24", "label": "bird"] : nil
            let none = await harness.send(route.method, path, json: json)
            #expect(none.status == 401 && none.json["error"] as? String == "unauthorized", "\(name(route)) -> \(none.status)")
            if route.method == "POST" {
                let noToken = await harness.send(route.method, path, json: json, cookie: session.cookie)
                #expect(noToken.status == 403 && noToken.json["error"] as? String == "csrf", "\(name(route)) without the token")
                let foreign = await harness.send(route.method, path, json: json, cookie: session.cookie, csrf: session.csrf, origin: "http://evil.example")
                #expect(foreign.status == 403 && foreign.json["error"] as? String == "cross_origin", "\(name(route)) from another site")
            } else {
                let allowed = await harness.send(route.method, path, cookie: session.cookie)
                #expect(![401, 403].contains(allowed.status), "\(name(route)) -> \(allowed.status): no token is needed to read")
            }
        }
        // Only the two reads reached the log.
        #expect(backend.read { $0.skyCalls.count } == calls + 2)
        // A method the route does not have is refused as such.
        let wrong = await session.send("DELETE", "/api/v1/sky/cameras/\(id.uuidString)/night")
        #expect(wrong.status == 405)
    }
}
