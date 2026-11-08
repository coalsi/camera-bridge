import BridgeEngine
import Foundation
import MediaCore

// The Apple TVs: one asks for a code, the owner types it into Settings while signed in, and the TV, asking again, is handed its key once
// (`AuthStore` holds the requests in memory and keeps the TVs in `auth.json`). Requests and answers are JSON.
//   POST   /viewers/pair          open: { name?, device? } -> { request, secret, code, expiresIn, interval }; 429 too_many_pairings + Retry-After
//   POST   /viewers/pair/status   open: { request, secret } -> { state: "waiting" }, or, once, { state: "approved", token, viewer: { id, name } };
//                                 404 pairing_gone (ended, unknown, a wrong secret, collected already, or the TV removed meanwhile)
//   POST   /viewers/approve       { code } in any case, with or without the dash -> 201 { viewer }; 404 no_such_code, 409 too_many_viewers, 500 storage
//   GET    /viewers               { viewers: [viewer] }, the one used last first
//   DELETE /viewers/:id           204; 404 when there is no such TV
// `viewer` is { id, name, device, created, lastSeen, address }, every key always there (null for what is not known). `id` names the TV in the
// list and signs nobody in. The two open routes can only make a code: nothing is added until a signed-in owner types it, and the key goes
// to the TV in the one answer that ends its request (the box keeps only its SHA-256).
//
// What a TV draws its screens from is one answer, `GET viewer`, every key always there (null for what is not known):
//   { bridge: { id, name, version, secureURL | null },
//     cameras: [{ id, name, kind, enabled, connection, motion, recordingNow, panTilt, zoom, sound, main | null, sub | null, lastEvent | null }] }
// The cameras come in the owner's order. It names no address, user name, stream URL, setting, token or setup code.
extension WebApp {
    static let viewerRoutes: [Route] = [
        Route("POST", "viewers/pair", .open, takesBody: true) { app, ctx in try await app.startPairing(ctx) },
        Route("POST", "viewers/pair/status", .open, takesBody: true) { app, ctx in try await app.pairingStatus(ctx) },
        Route("POST", "viewers/approve", takesBody: true) { app, ctx in try await app.approveViewer(ctx) },
        Route("GET", "viewers") { app, _ in await app.listViewers() },
        Route("DELETE", "viewers/:id") { app, ctx in try await app.removeViewer(ctx) },
        Route("GET", "viewer", .viewer) { app, _ in await app.viewerOverview() },
    ]

    private struct PairingRequest: Decodable {
        var name: String?
        var device: String?
    }

    private struct PairingQuestion: Decodable {
        var request: String
        var secret: String
    }

    private struct Approval: Decodable {
        var code: String
    }

    private struct PairingOffer: Encodable {
        var request: String
        var secret: String
        var code: String
        var expiresIn: Int
        var interval: Int
    }

    private struct ViewerResource: Encodable {
        var id: String
        var name: String
        var device: OrNull<String>
        var created: Date
        var lastSeen: OrNull<Date>
        var address: OrNull<String>

        init(_ viewer: AuthStore.ViewerInfo) {
            id = viewer.id
            name = viewer.name
            device = OrNull(viewer.device)
            created = viewer.created
            lastSeen = OrNull(viewer.lastSeen)
            address = OrNull(viewer.address)
        }
    }

    private struct ViewerAnswer: Encodable {
        var bridge: ViewerBridgeResource
        var cameras: [ViewerCameraResource]
    }

    private struct ViewerBridgeResource: Encodable {
        var id: String
        var name: String
        var version: String
        var secureURL: OrNull<String>
    }

    private struct ViewerCameraResource: Encodable {
        var id: UUID
        var name: String
        var kind: String
        var enabled: Bool
        var connection: String
        var motion: Bool
        var recordingNow: Bool
        var panTilt: Bool
        var zoom: Bool
        var sound: Bool
        var main: OrNull<ViewerStreamResource>
        var sub: OrNull<ViewerStreamResource>
        var lastEvent: OrNull<ViewerEventResource>

        /// `status` is nil for a camera the engine has not reported on yet: idle, or disabled when it is turned off, and nothing else known.
        init(_ configuration: CameraConfiguration, status: CameraStatus?) {
            id = configuration.id
            name = configuration.name
            kind = configuration.kind.rawValue
            enabled = configuration.isEnabled
            connection = status.map { StatusText.connectionName($0.connection) } ?? (configuration.isEnabled ? "idle" : "disabled")
            motion = status?.motionActive ?? false
            // The box's own recorder, not Apple Home's recording (`CameraStatus.recordingNow`), which the TV's timeline knows nothing of.
            recordingNow = status?.nvr.state == .recording
            // What the camera's control says, less what the owner turned off (`CameraStatus.panTilt`, `.zoom`).
            panTilt = status?.panTilt ?? false
            zoom = status?.zoom ?? false
            // The page's own rule for its speaker: the camera's "Camera audio" switch.
            sound = configuration.audioEnabled
            main = OrNull(status?.mainStreamInfo.flatMap(ViewerStreamResource.init))
            sub = OrNull(status?.subStreamInfo.flatMap(ViewerStreamResource.init))
            lastEvent = OrNull(status.flatMap(ViewerEventResource.init))
        }
    }

    /// A stream's size and codec, `h264` or `hevc`.
    private struct ViewerStreamResource: Encodable {
        var width: Int
        var height: Int
        var codec: VideoCodec

        /// nil when the stream's numbers are not ones a TV can use: no size, or a codec the engine does not write.
        init?(_ info: SourceStreamInfo) {
            guard info.width > 0, info.height > 0, let codec = VideoCodec(rawValue: info.codec) else { return nil }
            width = info.width
            height = info.height
            self.codec = codec
        }
    }

    /// The camera's latest event, named as `nvr/events` names its kinds ("Motion", "Person", "Doorbell ring", …).
    private struct ViewerEventResource: Encodable {
        var kind: String
        var date: Date

        /// nil unless the camera has a latest event and says when it was.
        init?(_ status: CameraStatus) {
            guard let kind = status.lastEvent, let date = status.lastEventDate else { return nil }
            self.kind = kind
            self.date = date
        }
    }

    /// What a TV asks about a request that is over or never was (`AuthStore.PairingStatus.gone`).
    static let pairingGone = APIError(status: 404, code: "pairing_gone", message: "This code ran out or was removed. Ask for a new one.")

    func pairingError(_ failure: AuthStore.PairingFailure) -> APIError {
        switch failure {
        case .busy(let seconds):
            APIError(status: 429, code: "too_many_pairings", message: "Too many devices are asking for a code right now. Try again in a few minutes.",
                     headers: [("Retry-After", String(seconds))])
        case .noSuchCode:
            APIError(status: 404, code: "no_such_code",
                     message: "No device is waiting with this code. Check the code on the device: it shows a new one every 10 minutes.")
        case .tooManyViewers:
            .conflict("too_many_viewers", "\(AuthStore.maximumViewers) devices are added already. Remove one you no longer use, then try again.")
        }
    }

    /// A TV asks for a code. Open, even before first-run setup: all it gets is a code, and only a signed-in owner can use that.
    func startPairing(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(PairingRequest.self, from: ctx)
        do {
            let start = try await auth.beginPairing(name: body.name, device: body.device, address: ctx.request.remoteAddress)
            return .json(PairingOffer(request: start.request, secret: start.secret, code: start.code, expiresIn: start.expiresIn, interval: start.interval))
        } catch let failure as AuthStore.PairingFailure {
            throw pairingError(failure)
        }
    }

    /// The TV asks whether its code was entered. The answer that carries the key is the last one: the box keeps the key only until then.
    func pairingStatus(_ ctx: RequestContext) async throws -> HTTPResponse {
        struct Waiting: Encodable { var state = "waiting" }
        struct Approved: Encodable {
            struct TV: Encodable {
                var id: String
                var name: String
            }

            var state = "approved"
            var token: String
            var viewer: TV
        }
        let body = try decode(PairingQuestion.self, from: ctx)
        switch await auth.pairingStatus(request: body.request, secret: body.secret) {
        case .waiting: return .json(Waiting())
        case .approved(let token, let viewer): return .json(Approved(token: token, viewer: .init(id: viewer.id, name: viewer.name)))
        case .gone: throw Self.pairingGone
        }
    }

    /// The owner types the code a TV shows: the TV is added now, and gets its key with its next question.
    func approveViewer(_ ctx: RequestContext) async throws -> HTTPResponse {
        struct Added: Encodable { var viewer: ViewerResource }
        let body = try decode(Approval.self, from: ctx)
        do {
            let viewer = try await auth.approvePairing(code: body.code)
            return .json(Added(viewer: ViewerResource(viewer)), status: 201)
        } catch let failure as AuthStore.PairingFailure {
            throw pairingError(failure)
        } catch AuthStore.Failure.storageFailed {
            throw APIError(status: 500, code: "storage", message: "The device couldn’t be saved. The disk may be full or read-only.")
        } catch AuthStore.Failure.unreadable {
            throw Self.authUnreadable
        }
    }

    func listViewers() async -> HTTPResponse {
        struct List: Encodable { var viewers: [ViewerResource] }
        return .json(List(viewers: await auth.viewers().map(ViewerResource.init)))
    }

    func removeViewer(_ ctx: RequestContext) async throws -> HTTPResponse {
        guard let id = ctx.params["id"], !id.isEmpty, id.utf8.count <= 64, await auth.removeViewer(id: id) else {
            throw APIError.notFound("That device isn’t added any more.")
        }
        return .empty()
    }

    /// The bridge and its cameras as an Apple TV draws them, in the owner's order. `id` is the box's identity for life, `version` what About shows.
    /// A camera says `recordingNow` while the box's own recorder writes it, `sound` while its "Camera audio" switch is on, `main` and `sub` once
    /// that stream has shown a picture, and `lastEvent` with the kind and time of the latest event.
    func viewerOverview() async -> HTTPResponse {
        let overview = await backend.overview()
        let configurations = Dictionary(overview.configurations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let statuses = Dictionary(overview.cameras.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cameras = overview.settings.orderedIDs(of: overview.configurations).compactMap { id in
            configurations[id].map { ViewerCameraResource($0, status: statuses[id]) }
        }
        let version = await system.info().version
        let secureURL = Self.secureURL(from: await secureAddress.report())
        let bridge = ViewerBridgeResource(id: await auth.bridgeID(), name: await auth.bridgeName, version: version, secureURL: OrNull(secureURL))
        return .json(ViewerAnswer(bridge: bridge, cameras: cameras))
    }

    /// The secure address as a TV may use it: only once its certificate is in place (`ready`). The report has the name from the moment the box
    /// is registered, but until the certificate is there nothing answers on it that a TV would trust.
    static func secureURL(from report: SecureAddressService.Report) -> String? {
        report.state == "ready" ? report.url : nil
    }
}
