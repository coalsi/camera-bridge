import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// An Apple TV's key on the API (`Route.Access.viewer`). Sent as `Authorization: Bearer <key>`, it opens the fifteen viewer routes (live and
/// recorded video, pictures, `GET viewer`, moving a camera and an iPhone's Away from home tunnel) and nothing else, needs no CSRF token and never works in the address; a wrong
/// or removed key is `401 viewer_key`, even beside a session cookie, and a TV removed while it watches live loses the stream. A browser's
/// session works on the same routes as before. Pairing itself is `ViewerPairingAPITests`'.
@Suite(.timeLimit(.minutes(1))) struct ViewerAccessTests {
    /// The routes a TV's key opens, as the spec lists them.
    private static let viewerRoutes: Set<String> = [
        "GET viewer", "GET cameras/:id/snapshot", "GET live", "GET nvr/cameras", "GET nvr/activity", "GET nvr/events", "GET nvr/cameras/:id/fragments",
        "GET nvr/cameras/:id/fragments/:fid", "GET nvr/cameras/:id/fragments/:fid/init", "GET nvr/cameras/:id/keyframe", "POST cameras/:id/pan-tilt",
        "POST hls/tickets", "POST viewer/away", "GET viewer/away", "DELETE viewer/away",
    ]
    private static let removed = "This device was removed from Camera Bridge. Pair it again."
    private static let inTheAddress = "Send the key in the Authorization header (Bearer), never in the address."

    /// A bridge with one camera, its owner signed in, and an Apple TV added from 192.0.2.40.
    private struct Bridge {
        var harness: Harness
        var owner: Harness.Session
        var tv: Harness.PairedTV
        var camera: CameraConfiguration

        var backend: FakeBackend { harness.backend }
    }

    private func makeBridge(modify: (inout WebConfiguration) -> Void = { _ in }) async throws -> Bridge {
        let backend = FakeBackend()
        let porch = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.20"), username: "")
        try await backend.addCamera(porch, password: nil)
        let harness = try Harness(backend: backend, modify: modify)
        let owner = try await harness.signIn()
        return Bridge(harness: harness, owner: owner, tv: try await harness.pairAppleTV(owner: owner), camera: porch)
    }

    private func bearer(_ key: String) -> [(String, String)] { [("Authorization", "Bearer \(key)")] }

    /// The TVs the owner's list shows.
    private func listed(_ owner: Harness.Session) async throws -> [[String: Any]] {
        try #require(await owner.get("/api/v1/viewers").json["viewers"] as? [[String: Any]])
    }

    @Test func theViewerRoutesAreTheSpecsList() {
        let routes = WebApp.routes.filter { $0.access == .viewer }.map { "\($0.method) \($0.pattern.joined(separator: "/"))" }
        #expect(Set(routes) == Self.viewerRoutes)
        #expect(routes.count == Self.viewerRoutes.count, "each of them once")
    }

    @Test func aKeyOpensExactlyTheViewerRoutes() async throws {
        let bridge = try await makeBridge()
        var asked = 0
        for route in WebApp.routes where route.access != .open {
            let name = "\(route.method) \(route.pattern.joined(separator: "/"))"
            let path = route.pattern.map { segment in
                switch segment {
                case ":id": bridge.camera.id.uuidString
                case ":fid": "0123456789ab.1"
                default: segment.hasPrefix(":") ? "x" : segment
                }
            }.joined(separator: "/")
            let body: Any? = route.method == "GET" ? nil : [String: Any]()
            let answer = await bridge.harness.send(route.method, "/api/v1/" + path, json: body, headers: bearer(bridge.tv.key))
            if route.access == .viewer {
                #expect(answer.status != 401 && answer.status != 403, "\(name) opens to a TV's key: \(answer.status) \(answer.text)")
            } else {
                #expect(answer.status == 401 && answer.json["code"] as? String == "unauthorized", "\(name) is not a TV's: \(answer.status) \(answer.text)")
            }
            asked += 1
        }
        #expect(asked > 100, "every route but the open ones")
    }

    @Test func aKeyNeedsNoCSRFAndABrowserStillDoes() async throws {
        let bridge = try await makeBridge()
        bridge.backend.write { $0.panTiltError = nil }   // Porch pans and tilts
        let path = "/api/v1/cameras/\(bridge.camera.id.uuidString)/pan-tilt"
        let stop = ["pan": 0, "tilt": 0]

        let moved = await bridge.harness.send("POST", path, json: stop, headers: bearer(bridge.tv.key))
        #expect(moved.status == 204, "a TV sends no cookie and no X-CSRF-Token: \(moved.text)")
        let noToken = await bridge.harness.send("POST", path, json: stop, cookie: bridge.owner.cookie)
        #expect(noToken.status == 403 && noToken.json["code"] as? String == "csrf", "a browser's cookie still needs its token: \(noToken.text)")
        let elsewhere = await bridge.harness.send("POST", path, json: stop, headers: bearer(bridge.tv.key), origin: "http://evil.example")
        #expect(elsewhere.status == 403 && elsewhere.json["code"] as? String == "cross_origin", "a key lets no other site in: \(elsewhere.text)")
        #expect(await bridge.owner.send("POST", path, json: stop).status == 204, "the owner's page, with its token, as before")
        #expect(bridge.backend.read { $0.calls.filter { $0 == "panTilt" }.count } == 2, "only the TV and the owner's page moved it")
    }

    @Test func aKeyInTheAddressIsRefused() async throws {
        let bridge = try await makeBridge()
        let (harness, key) = (bridge.harness, bridge.tv.key)
        func refused(_ answer: Answer, _ label: String) {
            #expect(answer.status == 400 && answer.json["code"] as? String == "invalid" && answer.json["field"] as? String == "token", "\(label): \(answer.text)")
            #expect(answer.json["message"] as? String == Self.inTheAddress, "\(label)")
        }
        refused(await harness.send("GET", "/api/v1/viewer?token=\(key)"), "the key in the address alone")
        refused(await harness.send("GET", "/api/v1/viewer?token=\(key)", headers: bearer(key)), "even with a good header")
        refused(await harness.send("GET", "/api/v1/live?cameras=\(bridge.camera.id.uuidString)&access_token=\(key)"), "access_token")
        let settings = await harness.send("GET", "/api/v1/settings?token=\(key)")
        #expect(settings.status == 401 && settings.json["code"] as? String == "unauthorized", "any other route never looks at the key: \(settings.text)")
        #expect(try await listed(bridge.owner).first?["lastSeen"] is NSNull, "a key in the address was not used")
    }

    @Test func aWrongOrRemovedKeyIs401ViewerKey() async throws {
        let bridge = try await makeBridge()
        let (harness, owner, tv) = (bridge.harness, bridge.owner, bridge.tv)
        func refused(_ answer: Answer, _ label: String) {
            #expect(answer.status == 401 && answer.json["error"] as? String == "viewer_key" && answer.json["code"] as? String == "viewer_key",
                    "\(label): \(answer.status) \(answer.text)")
            #expect(answer.json["message"] as? String == Self.removed, "\(label)")
            #expect(answer.headers["WWW-Authenticate"] == "Bearer", "\(label)")
            #expect(answer.headers.values(for: "Set-Cookie").isEmpty, "\(label): no cookie is cleared")
        }
        let nobodys = String(repeating: "0123456789abcdef", count: 4)
        refused(await harness.send("GET", "/api/v1/viewer", headers: bearer(nobodys)), "64 hex nobody holds")
        refused(await harness.send("GET", "/api/v1/viewer", cookie: owner.cookie, headers: bearer(nobodys)), "beside a valid session cookie")
        refused(await harness.send("GET", "/api/v1/viewer", headers: bearer(tv.key.uppercased())), "not the form of a key")
        #expect(await owner.get("/api/v1/viewer").status == 200, "the cookie beside the wrong key still signs the owner in")
        #expect(await harness.send("GET", "/api/v1/viewer", headers: bearer(tv.key)).status == 200)

        #expect(await owner.send("DELETE", "/api/v1/viewers/\(tv.id)").status == 204)
        refused(await harness.send("GET", "/api/v1/viewer", headers: bearer(tv.key)), "the key of a TV that was removed")
        refused(await harness.send("POST", "/api/v1/cameras/\(bridge.camera.id.uuidString)/pan-tilt", json: ["pan": 0, "tilt": 0], headers: bearer(tv.key)),
                "nor can it move a camera")
        let read = await owner.get("/api/v1/viewer")
        #expect(read.status == 200, "a session alone still reads GET viewer: \(read.text)")
    }

    /// Review Focus 2: the owner removes a TV that has a live view open. Its key is refused at once, and the stream it has open ends too.
    @Test func aTVRemovedWhileWatchingLiveIsCutOff() async throws {
        let bridge = try await makeBridge { $0.viewerRecheckInterval = .milliseconds(100) }
        let path = "/api/v1/live?cameras=\(bridge.camera.id.uuidString)"
        // The fake backend has no live video: each stream stays open, saying the camera is unavailable.
        let tv = StreamCollector(await bridge.harness.app.handle(bridge.harness.request("GET", path, headers: bearer(bridge.tv.key))))
        let browser = await bridge.owner.stream(path)
        #expect(tv.response.status == 200 && browser.response.status == 200)
        #expect(await tv.wait { $0.contains("\"state\":\"unavailable\"") })
        #expect(await browser.wait { $0.contains("\"state\":\"unavailable\"") })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!tv.finished.value, "the TV watches while it is added")

        #expect(await bridge.owner.send("DELETE", "/api/v1/viewers/\(bridge.tv.id)").status == 204)
        #expect(await eventually(timeout: .seconds(2)) { tv.finished.value }, "the removed TV's live view ends")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!browser.finished.value, "a browser's live view is not the TV's")
        browser.cancel()
    }

    /// The slot a TV's live view held is given back when the view is cut off: with room for one live view, the owner's page can open its own as
    /// soon as the removed TV's has ended. (An ended view that kept its slot would leave every later live view refused with 429 until a restart.)
    @Test func theLiveSlotOfATVThatWasCutOffIsFreeAgain() async throws {
        let bridge = try await makeBridge {
            $0.viewerRecheckInterval = .milliseconds(100)
            $0.maximumLiveStreams = 1
        }
        let path = "/api/v1/live?cameras=\(bridge.camera.id.uuidString)"
        let tv = StreamCollector(await bridge.harness.app.handle(bridge.harness.request("GET", path, headers: bearer(bridge.tv.key))))
        #expect(tv.response.status == 200)
        #expect(await tv.wait { $0.contains("\"state\":\"unavailable\"") })
        let refused = await bridge.owner.get(path)
        #expect(refused.status == 429 && refused.json["code"] as? String == "too_many_streams", "the one slot is the TV's: \(refused.status) \(refused.text)")

        #expect(await bridge.owner.send("DELETE", "/api/v1/viewers/\(bridge.tv.id)").status == 204)
        #expect(await eventually(timeout: .seconds(5)) { tv.finished.value }, "the removed TV's live view ends")
        let browser = await bridge.owner.stream(path)
        defer { browser.cancel() }
        #expect(browser.response.status == 200, "the slot the TV had is free again: \(browser.response.status)")
        #expect(await browser.wait { $0.contains("\"state\":\"unavailable\"") }, "and the owner's page is given a live view in it")
    }

    /// A TV's live view looks again at whether the TV is still added no more often than every 100 ms, whatever is configured: a zero interval would
    /// be a loop that never sleeps.
    @Test func theRecheckIsNeverMoreOftenThanEvery100Milliseconds() {
        #expect(WebApp.viewerRecheckWait(.zero) == .milliseconds(100))
        #expect(WebApp.viewerRecheckWait(.milliseconds(-5)) == .milliseconds(100))
        #expect(WebApp.viewerRecheckWait(.milliseconds(20)) == .milliseconds(100))
        #expect(WebApp.viewerRecheckWait(.milliseconds(100)) == .milliseconds(100))
        #expect(WebApp.viewerRecheckWait(.milliseconds(250)) == .milliseconds(250))
        #expect(WebApp.viewerRecheckWait(.seconds(5)) == .seconds(5))
        let configuration = WebConfiguration(dataDirectory: URL(fileURLWithPath: "/nonexistent"))
        #expect(configuration.viewerRecheckInterval == .seconds(5) && WebApp.viewerRecheckWait(configuration.viewerRecheckInterval) == .seconds(5))
    }

    /// A header that holds no key is no stand-in for the CSRF token: beside a valid session cookie and without `X-CSRF-Token`, moving a camera is
    /// refused whatever `Authorization` says, and the camera does not move. A header with nothing in it or another scheme is no key at all (the
    /// session rules apply: 403 csrf); one that is meant as a key and is not one is refused as a key (401 viewer_key), even beside the cookie.
    @Test func aHeaderThatHoldsNoKeyDoesNotStandInForTheCSRFToken() async throws {
        let bridge = try await makeBridge()
        bridge.backend.write { $0.panTiltError = nil }   // Porch pans and tilts
        let path = "/api/v1/cameras/\(bridge.camera.id.uuidString)/pan-tilt"
        let stop = ["pan": 0, "tilt": 0]
        func moves() -> Int { bridge.backend.read { $0.calls.filter { $0 == "panTilt" }.count } }

        for header in ["", "Bearer", "Bearer ", "Bearer    ", "bearer \t", "Basic YWRtaW46YWRtaW4=", "Token abc"] {
            let answer = await bridge.harness.send("POST", path, json: stop, cookie: bridge.owner.cookie, headers: [("Authorization", header)])
            #expect(answer.status == 403 && answer.json["code"] as? String == "csrf", "\"\(header)\" is no key, so the cookie needs its token: \(answer.status) \(answer.text)")
        }
        let notAKey = ["Bearer x", "Bearer not-a-key", "Bearer a b", "Bearer " + String(repeating: "a", count: 63), "Bearer " + String(repeating: "a", count: 65),
                       "Bearer " + String(repeating: "A", count: 64), "Bearer \(bridge.tv.key.uppercased())", "Bearer \(bridge.tv.key.dropLast())g"]
        for header in notAKey {
            let answer = await bridge.harness.send("POST", path, json: stop, cookie: bridge.owner.cookie, headers: [("Authorization", header)])
            #expect(answer.status == 401 && answer.json["code"] as? String == "viewer_key", "\"\(header)\" is a key that opens nothing: \(answer.status) \(answer.text)")
            #expect(answer.headers["WWW-Authenticate"] == "Bearer" && answer.headers.values(for: "Set-Cookie").isEmpty, "\"\(header)\"")
        }
        #expect(moves() == 0, "nothing moved the camera")

        // The same cookie with its token moves it, with or without such a header beside it: the refusals above were about the missing token.
        #expect(await bridge.owner.send("POST", path, json: stop).status == 204)
        #expect(await bridge.owner.send("POST", path, json: stop, headers: [("Authorization", "Bearer ")]).status == 204)
        #expect(moves() == 2)
    }

    @Test func aKeyIsUsedFromWhereItCameAndWhen() async throws {
        let bridge = try await makeBridge()
        var tv = try #require(try await listed(bridge.owner).first)
        #expect(tv["address"] as? String == "192.0.2.40" && tv["lastSeen"] is NSNull, "where it asked for its code from, and never used")

        #expect(await bridge.harness.send("GET", "/api/v1/viewer", headers: bearer(bridge.tv.key), from: "192.0.2.41").status == 200)
        tv = try #require(try await listed(bridge.owner).first)
        #expect(tv["address"] as? String == "192.0.2.41")
        let lastSeen = try #require(tv["lastSeen"] as? String)
        let date = try #require(ISO8601DateFormatter().date(from: lastSeen))
        #expect(abs(date.timeIntervalSinceNow) < 60, "\(lastSeen)")
    }

    /// The header as `GET monitor` reads its token: "Bearer" in any case and the key trimmed. A header that carries no key leaves the request to
    /// the session rules, HEAD is a GET, and on an open route a key signs nobody in.
    @Test func theHeaderIsReadAsMonitoringReadsIt() async throws {
        func token(_ header: String?) -> String? {
            WebApp.bearerToken(in: HTTPRequest(method: "GET", target: "/api/v1/viewer", headers: HTTPHeaders(header.map { [("Authorization", $0)] } ?? [])))
        }
        #expect(token("Bearer abc") == "abc" && token("bearer abc") == "abc" && token("BEARER   abc \t") == "abc")
        for nothing: String? in [nil, "", "Bearer", "Bearer    ", "Bearerabc", "Basic YWRtaW46YWRtaW4=", "Token abc"] {
            #expect(token(nothing) == nil, "\(nothing ?? "no header")")
        }

        let bridge = try await makeBridge()
        let (harness, owner, key) = (bridge.harness, bridge.owner, bridge.tv.key)
        #expect(await harness.send("GET", "/api/v1/viewer", headers: [("Authorization", "bearer  \(key) ")]).status == 200)
        let basic = await harness.send("GET", "/api/v1/viewer", cookie: owner.cookie, headers: [("Authorization", "Basic YWRtaW46YWRtaW4=")])
        #expect(basic.status == 200, "no key: the session rules, and the owner's cookie reads: \(basic.text)")
        let empty = await harness.send("GET", "/api/v1/viewer", headers: [("Authorization", "Bearer ")])
        #expect(empty.status == 401 && empty.json["code"] as? String == "unauthorized", "no key and no session: \(empty.text)")

        #expect(await harness.send("HEAD", "/api/v1/viewer", headers: bearer(key)).status == 200)
        let headSettings = await harness.send("HEAD", "/api/v1/settings", headers: bearer(key))
        #expect(headSettings.status == 401 && headSettings.json["code"] as? String == "unauthorized")

        let session = await harness.send("GET", "/api/v1/session", headers: bearer(key))
        #expect(session.status == 200 && session.json["authenticated"] as? Bool == false && session.json["csrfToken"] == nil)
        let status = await harness.send("GET", "/api/v1/status", headers: bearer(key))
        #expect(status.status == 200 && status.json["authenticated"] as? Bool == false && status.json["state"] == nil)
    }
}
