import Foundation

// Away from home (`Away/`): the Settings card and the phones' tunnel. Spec: docs/superpowers/specs/2026-11-12-away-from-home-design.md.
//   GET    away                the card: { on, state, problem, port, address, name, router, addressChangedAt, devices }
//   POST   away                { on } -> the card
//   POST   away/devices        { name } -> 201 { device, config }: a device that uses the WireGuard app; the config (with its private key) is never kept
//   DELETE away/devices/:id    204, for a device of either kind
//   POST   viewer/away         a paired iPhone's { publicKey } -> its tunnel document; 409 away_off while off
//   GET    viewer/away         the same document again; 404 not_set_up before the phone has a key
//   DELETE viewer/away         200 { ok: true }, on or off, so a phone can always turn its switch off
// A paired iPhone's key opens the three `viewer/away` routes; a browser's session gets 403 `viewer_only` on them. Errors are `APIError`s.
extension WebApp {
    static let awayRoutes: [Route] = [
        Route("GET", "away") { app, _ in try await app.awayCard() },
        Route("POST", "away", takesBody: true) { app, ctx in try await app.awaySetOn(ctx) },
        Route("POST", "away/devices", takesBody: true) { app, ctx in try await app.awayAddDevice(ctx) },
        Route("DELETE", "away/devices/:id") { app, ctx in try await app.awayRemoveDevice(ctx) },
        Route("POST", "viewer/away", .viewer, takesBody: true) { app, ctx in try await app.viewerAwaySet(ctx) },
        Route("GET", "viewer/away", .viewer) { app, ctx in try await app.viewerAwayGet(ctx) },
        Route("DELETE", "viewer/away", .viewer) { app, ctx in await app.viewerAwayRemove(ctx) },
    ]

    private struct OnBody: Decodable { var on: Bool }
    private struct DeviceBody: Decodable { var name: String? }
    private struct KeyBody: Decodable { var publicKey: String }

    private static let viewerOnly = APIError(status: 403, code: "viewer_only", message: "Only a paired device can do this.")

    /// Each failure with its own status, code and sentence.
    static func awayError(_ failure: AwayFailure) -> APIError {
        switch failure {
        case .unavailable: .unavailable("Away from home is part of Camera Bridge OS.")
        case .off: .conflict("away_off", "Away from home is off on the box.")
        case .secureAddressOff: .conflict("secure_address_off", "The box’s secure address isn’t set up yet.")
        case .badKey: APIError(status: 400, code: "bad_key", message: "That isn’t a WireGuard public key.")
        case .notSetUp: APIError(status: 404, code: "not_set_up", message: "Away from home isn’t set up for this device.")
        case .badName: .badRequest("Give the device a name.", field: "name")
        case .tooManyDevices: .conflict("too_many_devices", "\(AwayRules.maximumWireGuardDevices) devices use the WireGuard app already. Remove one first.")
        case .noAddress: .conflict("no_address", "The box has no address on the internet yet, so a device couldn’t reach it from away.")
        case .notReady: .conflict("not_ready", "The box’s VPN isn’t ready yet. Try again in a moment.")
        case .noSuchDevice: .notFound("That device isn’t there any more.")
        case .system(let message): APIError(status: 503, code: "system", message: message)
        }
    }

    /// Runs `body` and turns an Away from home failure into its answer.
    private func awayCall<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let failure as AwayFailure {
            throw Self.awayError(failure)
        }
    }

    func awayCard() async throws -> HTTPResponse {
        .json(try await awayCall { try await away.card() })
    }

    func awaySetOn(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(OnBody.self, from: ctx)
        return .json(try await awayCall { try await away.setOn(body.on) })
    }

    func awayAddDevice(_ ctx: RequestContext) async throws -> HTTPResponse {
        struct Added: Encodable { var device: AwayCard.Device; var config: String }
        let body = try decode(DeviceBody.self, from: ctx)
        let added = try await awayCall { try await away.addWireGuardDevice(name: body.name) }
        return .json(Added(device: added.device, config: added.config), status: 201)
    }

    func awayRemoveDevice(_ ctx: RequestContext) async throws -> HTTPResponse {
        guard let id = ctx.params["id"], !id.isEmpty, id.utf8.count <= 64 else { throw Self.awayError(.noSuchDevice) }
        // From the owner's browser the removal is applied now, and a failed apply is the answer. From inside the tunnel the answer goes first: the
        // key being dropped may be the one this request is travelling through.
        guard await away.isTunnelAddress(ctx.request.remoteAddress) else {
            try await awayCall { try await away.removeDevice(id: id) }
            return .empty()
        }
        let hold = try await awayCall { try await away.takeOutDevice(id: id) }
        var response = HTTPResponse.empty()
        settleRemoval(hold, after: &response)
        return response
    }

    func viewerAwaySet(_ ctx: RequestContext) async throws -> HTTPResponse {
        let viewer = try pairedDevice(ctx)
        let body = try decode(KeyBody.self, from: ctx)
        return .json(try await awayCall { try await away.setAppDevice(viewer: viewer, publicKey: body.publicKey) })
    }

    func viewerAwayGet(_ ctx: RequestContext) async throws -> HTTPResponse {
        let viewer = try pairedDevice(ctx)
        return .json(try await awayCall { try await away.tunnelDocument(viewerID: viewer.id) })
    }

    /// Always `{ok: true}`, on or off: the phone turns its switch off with this, and a box with Away from home off has nothing left to remove.
    func viewerAwayRemove(_ ctx: RequestContext) async -> HTTPResponse {
        struct Done: Encodable { var ok = true }
        guard let viewer = ctx.viewer else { return .error(Self.viewerOnly) }
        let hold = await away.takeOutAppDevice(viewerID: viewer.id)
        var response = HTTPResponse.json(Done())
        if let hold { settleRemoval(hold, after: &response) }
        return response
    }

    private func pairedDevice(_ ctx: RequestContext) throws -> AuthStore.ViewerInfo {
        guard let viewer = ctx.viewer else { throw Self.viewerOnly }
        return viewer
    }

    /// Has the system drop the removed key once the answer has been written to the connection. A phone turning Away from home off is talking
    /// through the very tunnel whose peer is dropped, so if the peer went first the answer would never arrive and the phone would wait out its
    /// timeout. The removal is certain all the same: the device is out of the record and marked as owed already, so a send that fails is
    /// covered by the hold's fallback (the next look applies it), a failed apply shows on the card, and every look tries again. Only this
    /// answer's hold ends: another removal still waiting for its own answer keeps its key.
    private func settleRemoval(_ hold: AwayService.Hold, after response: inout HTTPResponse) {
        let away = away
        response.afterSend = {
            Task {
                // The last packet of the answer needs a moment to leave the box.
                try? await Task.sleep(for: AwayService.lastPacketDelay)
                await away.settleRemoval(hold)
            }
        }
    }
}
