import Foundation

// The signed-in browsers (Settings' "Signed-in browsers"): who is signed in, and "Sign out" for one of them without changing the password.
//   GET    /auth/sessions        { sessions: [{ id, browser, address, created, lastSeen, current }] }, the one used last first
//   DELETE /auth/sessions/:id    204; 404 when there is no such browser (signed out already, or expired). Signing out the browser that asks
//                                also clears its cookie.
// `id` is derived from the session (`AuthStore.publicID`): it signs nobody in. `browser` is "Safari on iPhone" and the like (`BrowserLabel`),
// "A browser" for one signed in before the list existed; `address` is where it signed in from (null for those).
extension WebApp {
    static let sessionRoutes: [Route] = [
        Route("GET", "auth/sessions") { app, ctx in await app.signedInBrowsers(ctx) },
        Route("DELETE", "auth/sessions/:id") { app, ctx in try await app.signOutBrowser(ctx) },
    ]

    private struct SessionResource: Encodable {
        var id: String
        var browser: String
        var address: String?
        var created: Date
        var lastSeen: Date
        var current: Bool

        private enum CodingKeys: String, CodingKey { case id, browser, address, created, lastSeen, current }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(browser, forKey: .browser)
            try container.encode(address, forKey: .address)   // null, never left out
            try container.encode(created, forKey: .created)
            try container.encode(lastSeen, forKey: .lastSeen)
            try container.encode(current, forKey: .current)
        }
    }

    func signedInBrowsers(_ ctx: RequestContext) async -> HTTPResponse {
        struct List: Encodable { var sessions: [SessionResource] }
        let sessions = await auth.sessions(current: ctx.session?.id).map {
            SessionResource(id: $0.id, browser: $0.browser, address: $0.address, created: $0.created, lastSeen: $0.lastSeen, current: $0.current)
        }
        return .json(List(sessions: sessions))
    }

    func signOutBrowser(_ ctx: RequestContext) async throws -> HTTPResponse {
        guard let id = ctx.params["id"], !id.isEmpty, id.utf8.count <= 64 else { throw APIError.notFound("That browser isn’t signed in.") }
        let (ended, sessionID) = await auth.endSession(listedAs: id)
        guard ended else { throw APIError.notFound("That browser isn’t signed in.") }
        log.notice("a browser was signed out from the list of signed-in browsers")
        var response = HTTPResponse.empty()
        if sessionID == ctx.session?.id {
            for cookie in Self.clearedCookies() { response.headers.add("Set-Cookie", cookie) }
        }
        return response
    }
}
