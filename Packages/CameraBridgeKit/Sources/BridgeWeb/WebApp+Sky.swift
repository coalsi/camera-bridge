import BridgeEngine
import BridgeSupport
import Foundation

// The Sky Watcher's web API: a night's or a day's log of a sky camera with its entries, counts, conditions, aim and learning; one-tap corrections;
// the pictures kept with the entries; "Find a feed" for the flight feed on the home network; and the settings: where the box is and the feed in
// `PATCH /settings` (`sky`), and each camera's switch in `PATCH /cameras/:id` (`skyDetector`). Every route needs a session. Times are epoch
// milliseconds and an optional value is always there, as null.
//
// Where the box is shows in `GET /settings` and nowhere else: not in the log, the cameras' list, the status or the event stream, and no log line
// or error sentence repeats what was typed.

extension WebApp {
    static let skyRoutes: [Route] = [
        Route("GET", "sky/cameras/:id/night") { app, ctx in try await app.skyNight(ctx) },
        Route("GET", "sky/cameras/:id/entries/:eid/still") { app, ctx in try await app.skyStill(ctx) },
        Route("POST", "sky/cameras/:id/entries/:eid/correction", takesBody: true) { app, ctx in try await app.skyCorrection(ctx) },
        Route("POST", "sky/feeds/find") { app, _ in await app.skyFindFeeds() },
    ]

    static let nightSentence = "Give the date as year-month-day, like 2026-10-24."

    // MARK: The night's log

    /// `GET /sky/cameras/:id/night?date=yyyy-MM-dd&view=night|day`: the log of a night (sunset to sunrise) or a day (sunrise to sunset), named by
    /// the local date of its sunset or its own date; no `date` is the latest, and no `view` the night. `200 {camera, night, view, from, to,
    /// serverTime, entries, conditions, counts, aim, learning, capped}` (`capped`: the hours in which more lights were followed than are logged,
    /// `[{hour, count}]`); `409 no_location` or `no_folder` with the sentence to show; `404` for a camera
    /// the bridge does not have; `503`/`504` while the recordings' drive is away or does not answer.
    func skyNight(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try ctx.uuid("id")
        var night: String?
        if let date = ctx.request.queryValue("date") {
            guard ArchiveLayout.isDateDirectoryName(date) else { throw APIError.badRequest(Self.nightSentence, field: "date") }
            night = date
        }
        var view = SkyLogView.night
        if let name = ctx.request.queryValue("view") {
            guard let chosen = SkyLogView(rawValue: name) else { throw APIError.badRequest("Choose the night or the day.", field: "view") }
            view = chosen
        }
        do {
            return .json(SkyNightResource(try await backend.skyNightLog(cameraID: id, night: night, view: view), serverTime: Date()))
        } catch {
            throw Self.skyAPIError(error, nightField: "date")
        }
    }

    // MARK: Pictures

    /// `GET /sky/cameras/:id/entries/:eid/still?night=yyyy-MM-dd`: the picture kept with an entry, `image/jpeg`; `404` when it has none.
    func skyStill(_ ctx: RequestContext) async throws -> HTTPResponse {
        try refuseHEAD(ctx)
        let id = try ctx.uuid("id")
        let entryID = try skyEntryID(ctx)
        guard let night = ctx.request.queryValue("night"), ArchiveLayout.isDateDirectoryName(night) else {
            throw APIError.badRequest(Self.nightSentence, field: "night")
        }
        do {
            let jpeg = try await backend.skyStill(cameraID: id, night: night, entryID: entryID)
            var response = HTTPResponse(status: 200, contentType: "image/jpeg", data: jpeg)
            response.headers["Cache-Control"] = "private, max-age=3600"
            return response
        } catch {
            throw Self.skyAPIError(error, nightField: "night")
        }
    }

    // MARK: Corrections

    private struct SkyCorrectionBody: Decodable {
        var night: String
        var label: String
    }

    /// `POST /sky/cameras/:id/entries/:eid/correction {night, label}`: "That was a…" with `label` one of plane, bird, bug, satellite, meteor and
    /// notSure; answers the entry as it reads now. `400` (field `label` or `night`) for a word or a night that is not one; `404` for an entry the
    /// night's log does not hold.
    func skyCorrection(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try ctx.uuid("id")
        let entryID = try skyEntryID(ctx)
        let body = try decode(SkyCorrectionBody.self, from: ctx)
        guard ArchiveLayout.isDateDirectoryName(body.night) else { throw APIError.badRequest(Self.nightSentence, field: "night") }
        guard let label = SkyCorrection(rawValue: body.label) else {
            throw APIError.badRequest("Choose one of Plane, Bird, Bug, Satellite, Meteor or Not sure.", field: "label")
        }
        do {
            return .json(SkyEntryResource(try await backend.correctSkyEntry(cameraID: id, entryID: entryID, night: body.night, label: label)))
        } catch {
            throw Self.skyAPIError(error, nightField: "night")
        }
    }

    /// The entry's id in the address; one that cannot be an id is an entry the log does not have.
    private func skyEntryID(_ ctx: RequestContext) throws -> String {
        guard let entryID = ctx.params["eid"], SkyEntry.isValidID(entryID) else { throw APIError.notFound(SkyLogError.unknownEntry.description) }
        return entryID
    }

    // MARK: Flight feeds

    /// `POST /sky/feeds/find`: the flight feeds on the box's own network, one address per host: `200 {feeds: [url]}`. It takes a few seconds.
    func skyFindFeeds() async -> HTTPResponse {
        struct Found: Encodable { var feeds: [String] }
        return .json(Found(feeds: await backend.findFlightFeeds().map(\.absoluteString)))
    }

    // MARK: Errors

    /// Every way the sky log can fail, as the answer for the page: `nightField` is the field of the request that holds the night.
    static func skyAPIError(_ error: any Error, nightField: String) -> any Error {
        switch error {
        case is APIError:
            return error
        case EngineError.unknownCamera:
            return APIError.notFound("There is no camera with this identifier.")
        case let failure as SkyLogError:
            switch failure {
            case .noLocation: return APIError.conflict("no_location", failure.description)
            case .noFolder: return APIError.conflict("no_folder", failure.description)
            case .unknownNight: return APIError.badRequest(nightSentence, field: nightField)
            case .unknownEntry, .noStill: return APIError.notFound(failure.description)
            case .unavailable: return APIError.unavailable(failure.description)
            }
        case is ArchiveUnavailable, is ArchiveError, is DeadlineExceeded, is CancellationError:
            return archiveAPIError(error)
        default:
            return error
        }
    }

    // MARK: Settings: where the box is, the feed and the AI's limit

    /// `sky` in `PATCH /settings`: what was sent. A field that is left out stays; `location` and `flightFeedURL` can be null to take them away (the
    /// feed also an empty string). A place is replaced whole: sent with only a latitude and a longitude it is at 0 m.
    struct SkyPatch: Decodable {
        var location: PatchField<SkyLocationPatch>
        var flightFeedURL: PatchField<String>
        var aiDailyLimit: Int?

        private enum CodingKeys: String, CodingKey { case location, flightFeedURL, aiDailyLimit }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            location = try PatchField(container, .location)
            flightFeedURL = try PatchField(container, .flightFeedURL)
            aiDailyLimit = try container.decodeIfPresent(Int.self, forKey: .aiDailyLimit)
        }
    }

    struct SkyLocationPatch: Decodable, Sendable {
        var latitude: Double
        var longitude: Double
        var heightMeters: Double?
    }

    /// What `PATCH /settings` changes in `BridgeSettings.sky`, cleaned and checked, applied inside the engine's own settings change (so a change
    /// made meanwhile to another field stays).
    struct SkyChange: Sendable {
        var location: PatchField<SkyLocation> = .absent
        var flightFeedURL: PatchField<String> = .absent
        var aiDailyLimit: Int?

        func apply(to settings: inout SkySettings) {
            switch location {
            case .absent: break
            case .null: settings.location = nil
            case .value(let place): settings.location = place
            }
            switch flightFeedURL {
            case .absent: break
            case .null: settings.flightFeedURL = nil
            case .value(let address): settings.flightFeedURL = address
            }
            if let aiDailyLimit { settings.aiDailyLimit = aiDailyLimit }
        }
    }

    /// The patch cleaned (the feed's address trimmed, an empty one taken as none) and checked against the settings as they are: `400` with the
    /// field (`sky.location`, `sky.flightFeedURL`, `sky.aiDailyLimit`) when the result could not be saved. Nothing is changed here.
    func skyChange(from patch: SkyPatch) async throws -> SkyChange {
        var change = SkyChange()
        switch patch.location {
        case .absent: break
        case .null: change.location = .null
        case .value(let place): change.location = .value(SkyLocation(latitude: place.latitude, longitude: place.longitude, heightMeters: place.heightMeters ?? 0))
        }
        switch patch.flightFeedURL {
        case .absent: break
        case .null: change.flightFeedURL = .null
        case .value(let text):
            let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
            change.flightFeedURL = address.isEmpty ? .null : .value(address)
        }
        change.aiDailyLimit = patch.aiDailyLimit
        var merged = await backend.overview().settings.sky
        change.apply(to: &merged)
        if let problem = merged.validationProblem { throw APIError.badRequest(problem.message, field: problem.field) }
        return change
    }

    // MARK: A camera's switch

    /// `skyDetector` in `PATCH /cameras/:id`: what was sent. A field that is left out stays; `lensLayout` can be null (automatic).
    struct SkyDetectorPatch: Decodable {
        var enabled: Bool?
        var facing: Double?
        var tilt: Double?
        var groundPercent: Int?
        var nightProfile: Bool?
        var lensLayout: PatchField<String>

        private enum CodingKeys: String, CodingKey { case enabled, facing, tilt, groundPercent, nightProfile, lensLayout }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            facing = try container.decodeIfPresent(Double.self, forKey: .facing)
            tilt = try container.decodeIfPresent(Double.self, forKey: .tilt)
            groundPercent = try container.decodeIfPresent(Int.self, forKey: .groundPercent)
            nightProfile = try container.decodeIfPresent(Bool.self, forKey: .nightProfile)
            lensLayout = try PatchField(container, .lensLayout)
        }
    }

    /// `camera`'s Sky Watcher settings with `patch` applied, checked: `400` with the field (`skyDetector.facing`, `.tilt`, `.groundPercent`,
    /// `.lensLayout`) for a value that could not be kept. Saying `enabled: true` needs the Sky Watcher plugin switched on (`plugins.sky`: "Turn on Sky
    /// Watcher in Plugins first."), a camera that can watch the sky (a battery camera cannot: it would be kept awake all night), a place for the box
    /// (`sky.location`) and a recordings folder (`nvrFolder`), checked in that order; turning it off, and changing the aim of a camera without saying
    /// "on" again, need none of them (the plugin being off included: every camera keeps its settings while it is).
    func skyDetectorSettings(applying patch: SkyDetectorPatch, to camera: CameraConfiguration, bridge: BridgeSettings) throws -> SkyDetectorSettings {
        var settings = camera.skyDetector ?? SkyDetectorSettings()
        if let value = patch.enabled { settings.enabled = value }
        if let value = patch.facing { settings.facing = value }
        if let value = patch.tilt { settings.tilt = value }
        if let value = patch.groundPercent { settings.groundPercent = value }
        if let value = patch.nightProfile { settings.nightProfile = value }
        switch patch.lensLayout {
        case .absent: break
        case .null: settings.lensLayout = nil
        case .value(let name):
            guard let layout = SkyLensLayout(rawValue: name) else {
                throw APIError.badRequest("Choose “single” for one lens or “dual” for two lenses side by side.", field: "skyDetector.lensLayout")
            }
            settings.lensLayout = layout
        }
        if let problem = settings.validationProblem { throw APIError.badRequest(problem.message, field: problem.field) }
        if patch.enabled == true {
            if !bridge.skyPluginOn { throw APIError.badRequest(SkyWatcherPlugin.pluginOffSentence, field: SkyWatcherPlugin.pluginOffField) }
            if camera.streamsOnDemand {
                throw APIError.badRequest("Battery cameras can’t watch the sky: it would keep them awake.", field: "skyDetector.enabled")
            }
            if bridge.sky.location == nil { throw APIError.badRequest(SkyLogError.noLocation.description, field: "sky.location") }
            if bridge.nvrFolder == nil { throw APIError.badRequest(SkyLogError.noFolder.description, field: "nvrFolder") }
        }
        return settings
    }
}

// MARK: - What the page reads

/// A time in epoch milliseconds, whole.
private func milliseconds(_ date: Date) -> Int64 { WebApp.milliseconds(date) }

/// A number that is always a number (a measure that came out as NaN or infinity would otherwise empty the whole answer). (Not called `finite`:
/// Glibc has a function of that name.)
private func plain(_ value: Double) -> Double { value.isFinite ? value : 0 }

/// One entry of the log as the page reads it: the entry's own fields, `display` (the label the log shows: the person's word wins) and `watch`
/// (the recordings' moment to open, three seconds before it began). Optional values are null, not left out.
struct SkyEntryResource: Encodable {
    var entry: SkyEntry

    init(_ entry: SkyEntry) {
        self.entry = entry
    }

    private enum CodingKeys: String, CodingKey {
        case id, camera, kind, start, end, path, measures, label, display, by, detail, unusual, speedVsPlanes, candidate, alerted, hasStill, ai, correction, watch
    }

    private struct Point: Encodable {
        var t: Double
        var x: Double
        var y: Double
    }

    private struct Answer: Encodable {
        var kind: String
        var sentence: String
        var model: String
        var at: Int64
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entry.id, forKey: .id)
        try container.encode(entry.camera.uuidString, forKey: .camera)
        try container.encode(entry.kind.rawValue, forKey: .kind)
        try container.encode(milliseconds(entry.start), forKey: .start)
        try container.encode(milliseconds(entry.end), forKey: .end)
        try container.encode(entry.path.map { Point(t: plain($0.t), x: plain($0.x), y: plain($0.y)) }, forKey: .path)
        try container.encode(SkyMeasuresResource(entry.measures), forKey: .measures)
        try container.encode(entry.label.rawValue, forKey: .label)
        try container.encode(SkyDisplay.label(entry).rawValue, forKey: .display)
        try container.encode(OrNull(entry.by?.rawValue), forKey: .by)
        try container.encode(OrNull(entry.detail), forKey: .detail)
        try container.encode(entry.unusual.map(\.rawValue), forKey: .unusual)
        try container.encode(OrNull(entry.speedVsPlanes.flatMap { $0.isFinite ? $0 : nil }), forKey: .speedVsPlanes)
        try container.encode(entry.candidate, forKey: .candidate)
        try container.encode(entry.alerted, forKey: .alerted)
        try container.encode(entry.hasStill, forKey: .hasStill)
        try container.encode(OrNull(entry.ai.map { Answer(kind: $0.kind, sentence: $0.sentence, model: $0.model, at: milliseconds($0.at)) }), forKey: .ai)
        try container.encode(OrNull(entry.correction?.rawValue), forKey: .correction)
        try container.encode(milliseconds(entry.start) - 3_000, forKey: .watch)
    }
}

/// What was measured of a light, on the sky and in no real unit; every key is there.
struct SkyMeasuresResource: Encodable {
    var measures: SkyMeasures

    init(_ measures: SkyMeasures) {
        self.measures = measures
    }

    private enum CodingKeys: String, CodingKey {
        case azimuth, elevation, azimuthEnd, elevationEnd, duration, speed, acceleration, turnRate, maxTurn, straightness, shape, sizeDegrees, brightness
        case blinks, blinkRate, focus
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(plain(measures.azimuth), forKey: .azimuth)
        try container.encode(plain(measures.elevation), forKey: .elevation)
        try container.encode(plain(measures.azimuthEnd), forKey: .azimuthEnd)
        try container.encode(plain(measures.elevationEnd), forKey: .elevationEnd)
        try container.encode(plain(measures.duration), forKey: .duration)
        try container.encode(plain(measures.speed), forKey: .speed)
        try container.encode(plain(measures.acceleration), forKey: .acceleration)
        try container.encode(plain(measures.turnRate), forKey: .turnRate)
        try container.encode(plain(measures.maxTurn), forKey: .maxTurn)
        try container.encode(plain(measures.straightness), forKey: .straightness)
        try container.encode(measures.shape.rawValue, forKey: .shape)
        try container.encode(plain(measures.sizeDegrees), forKey: .sizeDegrees)
        try container.encode(plain(measures.brightness), forKey: .brightness)
        try container.encode(measures.blinks, forKey: .blinks)
        try container.encode(OrNull(measures.blinkRate.flatMap { $0.isFinite ? $0 : nil }), forKey: .blinkRate)
        try container.encode(plain(measures.focus), forKey: .focus)
    }
}

/// A night's (or a day's) log: see `WebApp.skyNight`. `serverTime` is the bridge's clock when it answered, for the page to say "tonight so far".
struct SkyNightResource: Encodable {
    struct Span: Encodable {
        var from: Int64
        var to: Int64
        var state: String
        var cloudCover: OrNull<Int>
    }

    struct Lens: Encodable {
        var quality: String
        var planes: Int
        var stars: Int
        var residualPixels: OrNull<Double>
    }

    /// The camera's aim: how good it is, what it rests on, its error in pixels of the camera's original picture, when it was fitted, each lens's own
    /// and what the card says about it ("The camera seems to have moved; aiming again.").
    struct Aim: Encodable {
        var quality: String
        var planes: Int
        var stars: Int
        var residualPixels: OrNull<Double>
        var updated: OrNull<Int64>
        var lenses: [Lens]
        var note: OrNull<String>
    }

    struct Learning: Encodable {
        var ready: Bool
        var planes: Int
        var satellites: Int
        var planesNeeded = SkyLearning.planesNeeded
        var satellitesNeeded = SkyLearning.satellitesNeeded
    }

    /// A clock hour (its start) in which more lights were followed than are logged, and how many more ("4 PM: 212 more lights weren't logged").
    struct Capped: Encodable {
        var hour: Int64
        var count: Int
    }

    var camera: String
    var night: String
    var view: String
    var from: Int64
    var to: Int64
    var serverTime: Int64
    var entries: [SkyEntryResource]
    var conditions: [Span]
    var counts: SkyCounts
    var aim: Aim
    var learning: Learning
    var capped: [Capped]

    init(_ log: SkyNightLog, serverTime: Date) {
        camera = log.camera.uuidString
        night = log.night
        view = log.view.rawValue
        from = milliseconds(log.from)
        to = milliseconds(log.to)
        self.serverTime = milliseconds(serverTime)
        entries = log.entries.map(SkyEntryResource.init)
        conditions = log.conditions.map { Span(from: milliseconds($0.from), to: milliseconds($0.to), state: $0.state.rawValue, cloudCover: OrNull($0.cloudCover)) }
        counts = log.counts
        aim = Aim(quality: log.aim.quality.rawValue, planes: log.aim.planes, stars: log.aim.stars,
                  residualPixels: OrNull(log.aim.residualPixels.flatMap { $0.isFinite ? $0 : nil }), updated: OrNull(log.aim.updated.map(milliseconds)),
                  lenses: log.aim.lenses.map { Lens(quality: $0.quality.rawValue, planes: $0.planes, stars: $0.stars, residualPixels: OrNull($0.residualPixels.flatMap { $0.isFinite ? $0 : nil })) },
                  note: OrNull(log.aim.note))
        learning = Learning(ready: log.learning.ready, planes: log.learning.planes, satellites: log.learning.satellites)
        capped = log.capped.map { Capped(hour: milliseconds($0.hour), count: $0.count) }
    }
}

/// `BridgeSettings.sky` as the page reads it. The place is shown here, to the signed-in page, and nowhere else.
struct SkySettingsResource: Encodable {
    struct Place: Encodable {
        var latitude: Double
        var longitude: Double
        var heightMeters: Double
    }

    var location: OrNull<Place>
    var flightFeedURL: OrNull<String>
    var aiDailyLimit: Int

    init(_ settings: SkySettings) {
        location = OrNull(settings.location.map { Place(latitude: $0.latitude, longitude: $0.longitude, heightMeters: $0.heightMeters) })
        flightFeedURL = OrNull(settings.flightFeedURL)
        aiDailyLimit = settings.aiDailyLimit
    }
}
