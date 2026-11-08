import BridgeEngine
import BridgeSupport
import Foundation

// HLS for the iPhone, iPad and CarPlay apps (docs/superpowers/specs/2026-11-06-ios-carplay-app-design.md, "Tickets").
//   POST /hls/tickets  viewer: { camera, kind: "live", stream?: "sub"|"main"|"automatic", audio?: bool }
//                              or { camera, kind: "recorded", from, to }   (milliseconds, at most 2 hours)
//                      -> { url: "/api/v1/hls/<ticket>/index.m3u8", expiresIn: 300 }; 404 for a camera the box does not know. A live ticket
//                      starts or finds the camera's packager (`HLS/HLSLivePackager.swift`), which holds a live slot: none free is 429
//                      too_many_streams with Retry-After. A recorded ticket is planned once at mint (`HLS/HLSRecorded.swift`, an archive slot for the walk):
//                      no recordings in the range is 404 `gap`, more than 2 hours (after a `to` past now is cut to now) is 400 `range_too_long`. Its
//                      files are `index.m3u8`, `media.m3u8` (VOD), `init-<n>.mp4` (one per recording file) and `seg-<n>.m4s` (a key fragment and the
//                      continuation fragments after it); the last two take an archive slot each (429 `busy`). A camera whose "Camera audio" switch is off is sent without sound, whatever the ticket asks.
//   GET  /hls/:ticket/:file  open: the files of that ticket's playlist. A ticket that is unknown, ended or of a viewer that was removed, and
//                      a file that does not exist, are all the same empty 404. So is a live ticket whose packager stopped: a ticket plays only the
//                      packager it was minted against, because a newer one numbers from 0 again, and the player takes a new ticket. A live playlist
//                      waits up to `hlsFirstPlaylistWait` for three segments, then is 503 with Retry-After, but for a master with one to write it from.
//                      Files are answered whole and never stored: a live segment that slid out of the playlist is gone.
// The ticket in the path is the one deliberate exception to "no token in an address": it opens one camera, read-only, for minutes, and the
// viewer's key itself stays refused in any address. A viewer is the TV that minted it, or, for the `viewer` route's session fallback, the
// browser's session: signing that browser out, removing it from the list or a password change that ends it ends its tickets at the next request.
extension WebApp {
    static let hlsRoutes: [Route] = [
        Route("POST", "hls/tickets", .viewer, takesBody: true) { app, ctx in try await app.mintHLSTicket(ctx) },
        Route("GET", "hls/:ticket/:file", .open) { app, ctx in await app.hlsFile(ctx) },
    ]

    private struct TicketRequest: Decodable {
        var camera: UUID
        var kind: String
        var stream: String?
        var audio: Bool?
        var from: Int64?
        var to: Int64?
    }

    private struct TicketAnswer: Encodable {
        var url: String
        var expiresIn: Int
    }

    /// The longest range a recorded ticket plays.
    static let hlsLongestRecording: Int64 = 2 * 60 * 60 * 1000

    private func mintHLSTicket(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(TicketRequest.self, from: ctx)
        var kind: HLSTicketKind
        var packager: UUID?
        switch body.kind {
        case "live":
            guard let stream = LiveVideoStream(rawValue: body.stream ?? "sub") else {
                throw APIError.badRequest("stream must be sub, main or automatic.", field: "stream")
            }
            kind = .live(stream: stream, audio: body.audio ?? false)
        case "recorded":
            guard let from = body.from, let to = body.to, from >= 0, to > from else {
                throw APIError.badRequest("Give from and to in milliseconds, with to after from.", field: "to")
            }
            // An open event is asked for up to now, and nothing plays past now: a later `to` is cut to it before the length is judged.
            let end = min(to, Self.milliseconds(configuration.now()))
            guard end - from <= Self.hlsLongestRecording else {
                throw APIError(status: 400, code: "range_too_long", message: "Ask for at most 2 hours at a time.", field: "to")
            }
            kind = .recorded(from: from, to: end)
        default:
            throw APIError.badRequest("kind must be live or recorded.", field: "kind")
        }
        guard let camera = await backend.overview().configurations.first(where: { $0.id == body.camera }) else {
            throw APIError.notFound("There is no camera with this identifier.")
        }
        guard let viewer = ctx.viewer?.id ?? ctx.session.map({ HLSTickets.sessionViewer($0.id) }) else {
            throw APIError(status: 401, code: "unauthorized", message: "Sign in to continue.")
        }
        if case .live(let stream, let audio) = kind {
            // The switch is the owner's word on whether a camera is heard, as on `GET live`.
            let key = HLSLivePackager.Key(camera: camera.id, stream: stream, audio: audio && camera.audioEnabled)
            kind = .live(stream: key.stream, audio: key.audio)
            guard let running = await startHLSPackager(key, viewer: viewer) else { throw Self.tooManyLiveViews }
            packager = running.id
        }
        var recording: HLSRecordedPlan?
        if case .recorded(let from, let to) = kind {
            // Planned here, once: no recordings in the range is 404 now rather than an empty playlist later. The camera's sound switch is read now.
            recording = try await withArchiveSlot(ctx) { archive in
                try await planRecording(camera: camera.id, from: from, to: to, keepSound: camera.audioEnabled, archive: archive)
            }
        }
        let ticket = await hlsTickets.mint(viewer: viewer, camera: camera.id, kind: kind, packager: packager, recording: recording, now: configuration.now())
        return .json(TicketAnswer(url: "/api/v1/hls/\(ticket)/index.m3u8", expiresIn: Int(HLSTickets.idleLifetime)))
    }

    /// Finds the packager of `key` or starts one in a live slot of its own; nil when none is free. `viewer` becomes one of its users.
    private func startHLSPackager(_ key: HLSLivePackager.Key, viewer: String) async -> HLSLivePackager? {
        await hlsPackagers.packager(for: key, viewer: viewer) { [self] onStop in
            guard takeLiveSlot() else { return nil }
            let slot = ReleaseOnce { [weak self] in self?.releaseLiveSlot() }
            return HLSLivePackager(key: key, backend: backend, uptime: configuration.uptime, slot: slot, onStop: onStop)
        }
    }

    /// The same answer for everything that is not a file of a live ticket: nothing says which part was wrong.
    static func hlsNotFound() -> HTTPResponse {
        var response = HTTPResponse.text("", status: 404)
        response.headers["Cache-Control"] = "no-store"
        return response
    }

    /// The answer to a HEAD on a recorded init or segment, as `refuseHEAD` gives on the other media routes.
    static func hlsHeadRefused() -> HTTPResponse {
        var response = HTTPResponse.error(APIError(status: 405, code: "method_not_allowed", message: "That isn’t possible here.", headers: [("Allow", "GET")]))
        response.headers["Cache-Control"] = "no-store"
        return response
    }

    /// A live playlist whose first segments are not out yet.
    private static func hlsNotReady() -> HTTPResponse {
        var response = HTTPResponse.text("", status: 503)
        response.headers["Cache-Control"] = "no-store"
        response.headers["Retry-After"] = "5"
        return response
    }

    static func hlsAnswer(_ data: Data?, contentType: String) -> HTTPResponse {
        guard let data else { return hlsNotFound() }
        var headers = HTTPHeaders()
        headers["Cache-Control"] = "no-store"
        return HTTPResponse(status: 200, contentType: contentType, data: data, headers: headers)
    }

    private func hlsFile(_ ctx: RequestContext) async -> HTTPResponse {
        guard let presented = ctx.params["ticket"], let name = ctx.params["file"],
              let ticket = await hlsTickets.touch(presented, now: configuration.now()) else { return Self.hlsNotFound() }
        // A TV removed from the list, or a browser signed out, loses its tickets at its next request (no timer): this is the whole recheck.
        let listed = if let session = HLSTickets.sessionID(of: ticket.viewer) { await auth.isSessionListed(session) } else { await auth.isViewerListed(ticket.viewer) }
        if !listed {
            await hlsTickets.drop(viewer: ticket.viewer)
            await hlsPackagers.viewerLeft(ticket.viewer)
            return Self.hlsNotFound()
        }
        guard let file = HLSFile(name: name) else { return Self.hlsNotFound() }
        switch ticket.kind {
        case .live(let stream, let audio):
            return await hlsLiveFile(file, of: HLSLivePackager.Key(camera: ticket.camera, stream: stream, audio: audio), mintedAgainst: ticket.packager)
        case .recorded:
            guard let plan = ticket.recording else { return Self.hlsNotFound() }
            return await hlsRecordedFile(file, plan: plan, camera: ticket.camera, ctx: ctx)
        }
    }

    private func hlsLiveFile(_ file: HLSFile, of key: HLSLivePackager.Key, mintedAgainst id: UUID?) async -> HTTPResponse {
        guard let packager = await hlsPackagers.running(key), packager.id == id else { return Self.hlsNotFound() }
        let playlist = "application/vnd.apple.mpegurl"
        switch file {
        case .master:
            guard let text = await packager.master(waitingUpTo: configuration.hlsFirstPlaylistWait) else { return Self.hlsNotReady() }
            return Self.hlsAnswer(Data(text.utf8), contentType: playlist)
        case .media:
            guard let text = await packager.playlist(waitingUpTo: configuration.hlsFirstPlaylistWait) else { return Self.hlsNotReady() }
            return Self.hlsAnswer(Data(text.utf8), contentType: playlist)
        case .initSegment(let number):
            return Self.hlsAnswer(await packager.initSegment(number), contentType: "video/mp4")
        case .segment(let number):
            return Self.hlsAnswer(await packager.segment(number), contentType: "video/iso.segment")
        }
    }
}

/// A file of a ticket's playlist, by its name. Only the names the playlists write are files: a number has digits and nothing else, without a sign
/// or a leading zero.
enum HLSFile: Equatable {
    case master, media
    case initSegment(Int)
    case segment(Int)

    init?(name: String) {
        if name == "index.m3u8" {
            self = .master
        } else if name == "media.m3u8" {
            self = .media
        } else if let number = Self.number(in: name, between: "init-", and: ".mp4") {
            self = .initSegment(number)
        } else if let number = Self.number(in: name, between: "seg-", and: ".m4s") {
            self = .segment(number)
        } else {
            return nil
        }
    }

    private static func number(in name: String, between prefix: String, and suffix: String) -> Int? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard let number = Int(digits), String(number) == digits else { return nil }
        return number
    }
}
