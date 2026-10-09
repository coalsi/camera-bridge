import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

@Suite(.timeLimit(.minutes(1))) struct AuthAPITests {
    // MARK: First run

    @Test func beforeSetupOnlyTheSetupPageIsOffered() async throws {
        let harness = try Harness()
        let status = await harness.send("GET", "/api/v1/status")
        #expect(status.status == 200)
        #expect(status.json["setupRequired"] as? Bool == true)
        #expect(status.json["authenticated"] as? Bool == false)
        #expect(status.json["product"] as? String == "Camera Bridge OS")
        for path in ["/api/v1/cameras", "/api/v1/settings", "/api/v1/logs", "/api/v1/system", "/api/v1/diagnostics", "/api/v1/events"] {
            let answer = await harness.send("GET", path)
            #expect(answer.status == 403, "\(path) before setup")
            #expect(answer.json["error"] as? String == "setup_required")
        }
        #expect(await harness.send("POST", "/api/v1/auth/login", json: ["password": "whatever1"]).status == 409)
        let session = await harness.send("GET", "/api/v1/session")
        #expect(session.json["setupRequired"] as? Bool == true)
        #expect(session.json["csrfToken"] == nil)
    }

    @Test func setupSetsThePasswordNamesTheBridgeAndSignsIn() async throws {
        let harness = try Harness()
        let answer = await harness.send("POST", "/api/v1/auth/setup", json: ["password": "correct horse", "bridgeName": "Hallway Bridge"])
        #expect(answer.status == 201)
        #expect(answer.json["bridgeName"] as? String == "Hallway Bridge")
        let token = try #require(answer.json["csrfToken"] as? String)
        #expect(token.count == 64)
        let cookie = try #require(answer.headers.values(for: "Set-Cookie").first)
        #expect(cookie.hasPrefix("cb_session="))
        #expect(cookie.contains("HttpOnly"))
        #expect(cookie.contains("SameSite=Strict"))
        #expect(cookie.contains("Path=/"))
        #expect(cookie.contains("Max-Age="))
        #expect(!cookie.contains("Secure"), "plain HTTP on the local network: a Secure cookie would never be sent")
        let status = await harness.send("GET", "/api/v1/status", cookie: answer.cookie)
        #expect(status.json["authenticated"] as? Bool == true)
        #expect(status.json["name"] as? String == "Hallway Bridge")
        #expect(status.json["setupRequired"] as? Bool == false)
    }

    @Test func setupWorksOnlyOnce() async throws {
        let harness = try Harness()
        _ = try await harness.signIn()
        let again = await harness.send("POST", "/api/v1/auth/setup", json: ["password": "another password"])
        #expect(again.status == 409)
        #expect(again.json["error"] as? String == "already_configured")
        #expect(again.cookie == nil)
    }

    @Test func setupChecksThePassword() async throws {
        let harness = try Harness()
        let short = await harness.send("POST", "/api/v1/auth/setup", json: ["password": "short"])
        #expect(short.status == 400)
        #expect(short.json["field"] as? String == "password")
        #expect((short.json["message"] as? String)?.contains("8") == true)
        let long = await harness.send("POST", "/api/v1/auth/setup", json: ["password": String(repeating: "x", count: 300)])
        #expect(long.status == 400)
        #expect(await harness.send("POST", "/api/v1/auth/setup", json: ["nothing": 1]).status == 400)
        #expect(await harness.send("GET", "/api/v1/status").json["setupRequired"] as? Bool == true)
    }

    @Test func aSetupCodeCanBeRequired() async throws {
        let harness = try Harness(setupToken: "ABCD-1234")
        #expect(await harness.send("GET", "/api/v1/session").json["setupTokenRequired"] as? Bool == true)
        let missing = await harness.send("POST", "/api/v1/auth/setup", json: ["password": "correct horse"])
        #expect(missing.status == 403)
        #expect(missing.json["error"] as? String == "setup_token")
        let wrong = await harness.send("POST", "/api/v1/auth/setup", json: ["password": "correct horse", "setupToken": "ABCD-0000"])
        #expect(wrong.status == 403)
        let right = await harness.send("POST", "/api/v1/auth/setup", json: ["password": "correct horse", "setupToken": "ABCD-1234"])
        #expect(right.status == 201)
    }

    @Test func wrongSetupCodesAreRateLimited() async throws {
        let harness = try Harness(setupToken: "ABCD-1234")
        for _ in 0..<5 { _ = await harness.send("POST", "/api/v1/auth/setup", json: ["password": "correct horse", "setupToken": "nope"]) }
        let locked = await harness.send("POST", "/api/v1/auth/setup", json: ["password": "correct horse", "setupToken": "ABCD-1234"])
        #expect(locked.status == 429)
    }

    // MARK: Signing in

    @Test func loginAcceptsTheRightPasswordOnly() async throws {
        let harness = try Harness()
        _ = try await harness.signIn(password: "correct horse")
        let wrong = await harness.send("POST", "/api/v1/auth/login", json: ["password": "wrong horse"])
        #expect(wrong.status == 401)
        #expect(wrong.json["error"] as? String == "wrong_password")
        #expect(wrong.cookie == nil)
        let right = await harness.send("POST", "/api/v1/auth/login", json: ["password": "correct horse"])
        #expect(right.status == 200)
        #expect(right.cookie != nil)
        #expect((right.json["csrfToken"] as? String)?.count == 64)
    }

    @Test func eachLoginIsAnIndependentSession() async throws {
        let harness = try Harness()
        let first = try await harness.signIn()
        let second = await harness.send("POST", "/api/v1/auth/login", json: ["password": "correct horse"])
        #expect(second.cookie != first.cookie)
        #expect(second.json["csrfToken"] as? String != first.csrf)
    }

    @Test func tooManyWrongPasswordsLockTheAddressOut() async throws {
        let harness = try Harness()
        _ = try await harness.signIn()
        for _ in 0..<5 {
            #expect(await harness.send("POST", "/api/v1/auth/login", json: ["password": "wrong password"]).status == 401)
        }
        let locked = await harness.send("POST", "/api/v1/auth/login", json: ["password": "correct horse"])
        #expect(locked.status == 429, "even the right password waits")
        #expect(locked.json["error"] as? String == "too_many_attempts")
        #expect(Int(locked.headers["Retry-After"] ?? "") ?? 0 > 0)
        #expect(locked.cookie == nil)
        let other = await harness.send("POST", "/api/v1/auth/login", json: ["password": "correct horse"], from: "192.0.2.99")
        #expect(other.status == 200, "another address is not affected")
    }

    @Test func aRightPasswordClearsTheCount() async throws {
        let harness = try Harness()
        _ = try await harness.signIn()
        for _ in 0..<4 { _ = await harness.send("POST", "/api/v1/auth/login", json: ["password": "wrong password"]) }
        #expect(await harness.send("POST", "/api/v1/auth/login", json: ["password": "correct horse"]).status == 200)
        for _ in 0..<4 { _ = await harness.send("POST", "/api/v1/auth/login", json: ["password": "wrong password"]) }
        #expect(await harness.send("POST", "/api/v1/auth/login", json: ["password": "correct horse"]).status == 200)
    }

    @Test func aMalformedLoginBodyIsRefused() async throws {
        let harness = try Harness()
        _ = try await harness.signIn()
        #expect(await harness.send("POST", "/api/v1/auth/login", rawBody: Data("{not json".utf8)).status == 400)
        #expect(await harness.send("POST", "/api/v1/auth/login", json: ["password": 12345]).status == 400)
        #expect(await harness.send("POST", "/api/v1/auth/login", json: [String: String]()).status == 400)
        #expect(await harness.send("POST", "/api/v1/auth/login").status == 400)
        let huge = await harness.send("POST", "/api/v1/auth/login", json: ["password": String(repeating: "x", count: 100_000)])
        #expect(huge.status == 401, "a very long guess is simply wrong, not expensive")
    }

    // MARK: Sessions

    @Test func theApiNeedsASession() async throws {
        let harness = try Harness()
        _ = try await harness.signIn()
        let none = await harness.send("GET", "/api/v1/cameras")
        #expect(none.status == 401)
        #expect(none.json["error"] as? String == "unauthorized")
        let forged = await harness.send("GET", "/api/v1/cameras", cookie: "cb_session=\(Secrets.randomToken())")
        #expect(forged.status == 401)
        #expect(forged.headers.values(for: "Set-Cookie").first?.contains("Max-Age=0") == true, "a stale cookie is cleared")
        let empty = await harness.send("GET", "/api/v1/cameras", cookie: "cb_session=")
        #expect(empty.status == 401)
        let injected = await harness.send("GET", "/api/v1/cameras", cookie: "cb_session=a; cb_session=b; other=1")
        #expect(injected.status == 401)
    }

    @Test func theSessionEndpointGivesTheAntiForgeryToken() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let answer = await session.get("/api/v1/session")
        #expect(answer.json["authenticated"] as? Bool == true)
        #expect(answer.json["csrfToken"] as? String == session.csrf)
        #expect(await harness.send("GET", "/api/v1/session").json["csrfToken"] == nil)
    }

    @Test func logoutEndsTheSessionAndClearsTheCookie() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let out = await session.send("POST", "/api/v1/auth/logout")
        #expect(out.status == 204)
        #expect(out.headers.values(for: "Set-Cookie").first?.contains("Max-Age=0") == true)
        #expect(await session.get("/api/v1/cameras").status == 401)
    }

    @Test func changingThePasswordSignsOutOtherBrowsers() async throws {
        let harness = try Harness()
        let mine = try await harness.signIn(password: "old password")
        let otherAnswer = await harness.send("POST", "/api/v1/auth/login", json: ["password": "old password"])
        let otherCookie = try #require(otherAnswer.cookie)
        let wrong = await mine.send("POST", "/api/v1/auth/password", json: ["current": "not it", "new": "new password"])
        #expect(wrong.status == 401)
        #expect(wrong.json["field"] as? String == "current")
        let short = await mine.send("POST", "/api/v1/auth/password", json: ["current": "old password", "new": "tiny"])
        #expect(short.status == 400)
        let changed = await mine.send("POST", "/api/v1/auth/password", json: ["current": "old password", "new": "new password"])
        #expect(changed.status == 204)
        #expect(await mine.get("/api/v1/cameras").status == 200, "this browser stays signed in")
        #expect(await harness.send("GET", "/api/v1/cameras", cookie: otherCookie).status == 401)
        #expect(await harness.send("POST", "/api/v1/auth/login", json: ["password": "old password"]).status == 401)
        #expect(await harness.send("POST", "/api/v1/auth/login", json: ["password": "new password"]).status == 200)
    }

    @Test func sessionsSurviveARestartOfTheApplication() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let restarted = WebApp(configuration: WebConfiguration(dataDirectory: harness.directory.url, port: 0, passwordIterations: 1_000),
                               backend: harness.backend, system: harness.system, logs: harness.logs)
        let response = await restarted.handle(harness.request("GET", "/api/v1/cameras", cookie: session.cookie))
        #expect(response.status == 200)
    }

    // MARK: Cross-site requests

    @Test func changingRequestsNeedTheAntiForgeryToken() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let none = await harness.send("POST", "/api/v1/bridge/pause", cookie: session.cookie)
        #expect(none.status == 403)
        #expect(none.json["error"] as? String == "csrf")
        let wrong = await harness.send("POST", "/api/v1/bridge/pause", cookie: session.cookie, csrf: String(repeating: "0", count: 64))
        #expect(wrong.status == 403)
        let otherSession = await harness.send("POST", "/api/v1/auth/login", json: ["password": "correct horse"])
        let stolen = await harness.send("POST", "/api/v1/bridge/pause", cookie: session.cookie, csrf: otherSession.json["csrfToken"] as? String)
        #expect(stolen.status == 403, "another session's token is no good")
        #expect(await harness.send("POST", "/api/v1/bridge/pause", cookie: session.cookie, csrf: session.csrf).status == 204)
        #expect(await harness.send("PATCH", "/api/v1/settings", json: ["motionShadowTest": true], cookie: session.cookie).status == 403)
        #expect(await harness.send("DELETE", "/api/v1/cameras/\(UUID().uuidString)", cookie: session.cookie).status == 403)
    }

    @Test func readingNeedsNoToken() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        #expect(await harness.send("GET", "/api/v1/cameras", cookie: session.cookie).status == 200)
    }

    @Test func aRequestFromAnotherSiteIsRefused() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        for origin in ["http://evil.example", "https://camera-bridge.local", "http://camera-bridge.local:8080", "null", "http://camera-bridge.local.evil.example"] {
            let answer = await session.send("POST", "/api/v1/bridge/pause", origin: origin)
            #expect(answer.status == 403, "Origin \(origin)")
            #expect(answer.json["error"] as? String == "cross_origin")
        }
        #expect(await session.send("POST", "/api/v1/bridge/pause", origin: "http://camera-bridge.local").status == 204)
        #expect(await session.send("POST", "/api/v1/bridge/resume", origin: "http://CAMERA-BRIDGE.local:80").status == 204)
        // A browser that sends no Origin says so with Fetch Metadata.
        #expect(await session.send("POST", "/api/v1/bridge/pause", headers: [("Sec-Fetch-Site", "cross-site")]).status == 403)
        #expect(await session.send("POST", "/api/v1/bridge/pause", headers: [("Sec-Fetch-Site", "same-site")]).status == 403)
        #expect(await session.send("POST", "/api/v1/bridge/pause", headers: [("Sec-Fetch-Site", "same-origin")]).status == 204)
    }

    @Test func loginIsProtectedFromOtherSitesToo() async throws {
        let harness = try Harness()
        _ = try await harness.signIn()
        let answer = await harness.send("POST", "/api/v1/auth/login", json: ["password": "correct horse"], origin: "http://evil.example")
        #expect(answer.status == 403)
        #expect(answer.cookie == nil)
    }

    @Test func aBodyMustBeJSON() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let empty = await harness.send("PATCH", "/api/v1/settings", cookie: session.cookie, csrf: session.csrf)
        #expect(empty.status == 400, "no body at all is a bad request, not an unsupported type")
        var request = harness.request("PATCH", "/api/v1/settings", cookie: session.cookie, csrf: session.csrf)
        request.body = Data(#"{"logLevel":"info"}"#.utf8)
        request.headers["Content-Type"] = "text/plain"
        let refused = await harness.app.handle(request)
        #expect(refused.status == 415)
        request.headers["Content-Type"] = "application/x-www-form-urlencoded"
        #expect(await harness.app.handle(request).status == 415)
    }

    // MARK: Host header

    @Test func onlyLocalNamesAndAddressesAreServed() async throws {
        let harness = try Harness(allowedHosts: ["bridge.home.example"])
        let allowed = ["camera-bridge.local", "192.0.2.10", "192.0.2.10:8080", "localhost", "localhost:8080", "camerabridge", "[2001:db8::1]", "[2001:db8::1]:80",
                       "bridge.home.example", "Bridge.Home.Example", "printer.home.arpa", "CAMERA-BRIDGE.LOCAL"]
        for host in allowed {
            let answer = await harness.send("GET", "/api/v1/status", headers: [("Host", host)])
            #expect(answer.status == 200, "Host: \(host)")
        }
        let refused = ["evil.example", "camera-bridge.local.evil.example", "192.0.2.10.evil.example", "www.example.com:80", "999.1.1.1.evil.io", "a.b"]
        for host in refused {
            let answer = await harness.send("GET", "/api/v1/status", headers: [("Host", host)])
            #expect(answer.status == 421, "Host: \(host)")
        }
        let files = await harness.send("GET", "/", headers: [("Host", "evil.example")])
        #expect(files.status == 421, "the interface's files too")
    }

    @Test func aRequestWithoutHostIsRefusedExceptHTTP10() async throws {
        let harness = try Harness()
        var request = harness.request("GET", "/api/v1/status")
        request.headers["Host"] = nil
        #expect(await harness.app.handle(request).status == 421)
        request.version = "HTTP/1.0"
        #expect(await harness.app.handle(request).status == 200)
    }

    // MARK: Headers and errors

    @Test func everyAnswerCarriesTheSecurityHeaders() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        for answer in [await harness.send("GET", "/api/v1/status"), await session.get("/api/v1/cameras"), await harness.send("GET", "/"),
                       await harness.send("GET", "/api/v1/nothing"), await harness.send("GET", "/api/v1/cameras"),
                       await harness.send("GET", "/api/v1/status", headers: [("Host", "evil.example")])] {
            let policy = try #require(answer.headers["Content-Security-Policy"])
            #expect(policy.contains("default-src 'none'"))
            #expect(policy.contains("script-src 'self'"))
            #expect(policy.contains("frame-ancestors 'none'"))
            #expect(!policy.contains("unsafe-inline") && !policy.contains("unsafe-eval"))
            #expect(answer.headers["X-Content-Type-Options"] == "nosniff")
            #expect(answer.headers["X-Frame-Options"] == "DENY")
            #expect(answer.headers["Referrer-Policy"] == "no-referrer")
            #expect(answer.headers["Cross-Origin-Resource-Policy"] == "same-origin")
            #expect(answer.headers["Cross-Origin-Opener-Policy"] == "same-origin")
            #expect(answer.headers["Permissions-Policy"]?.contains("camera=()") == true)
        }
        for path in ["/api/v1/status", "/api/v1/cameras", "/api/v1/nothing"] {
            #expect(await session.get(path).headers["Cache-Control"] == "no-store", "\(path)")
        }
    }

    @Test func unknownAddressesAndWrongMethodsAnswerInJSON() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let missing = await session.get("/api/v1/nothing")
        #expect(missing.status == 404)
        #expect(missing.json["error"] as? String == "not_found")
        #expect(await harness.send("GET", "/api/other").status == 404)
        #expect(await harness.send("GET", "/api").status == 404)
        let wrongMethod = await session.send("PUT", "/api/v1/cameras")
        #expect(wrongMethod.status == 405)
        #expect(wrongMethod.headers["Allow"]?.contains("GET") == true)
        #expect(wrongMethod.headers["Allow"]?.contains("POST") == true)
        #expect(await session.send("DELETE", "/api/v1/status").status == 405)
    }

    @Test func headIsAnsweredForReadableRoutes() async throws {
        let harness = try Harness()
        #expect(await harness.send("HEAD", "/api/v1/status").status == 200)
    }

    @Test func secretsNeverAppearInAnswers() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn(password: "hunter2-hunter2")
        let camera = await session.send("POST", "/api/v1/cameras", json: ["type": "hikvision", "host": "192.0.2.20", "username": "viewer", "password": "camera-secret-123",
                                                                          "name": "Porch"])
        #expect(camera.status == 201, "\(camera.text)")
        var texts: [String] = [camera.text]
        for path in ["/api/v1/cameras", "/api/v1/status", "/api/v1/settings", "/api/v1/session", "/api/v1/logs", "/api/v1/diagnostics", "/api/v1/system"] {
            texts.append(await session.get(path).text)
        }
        for text in texts {
            #expect(!text.contains("camera-secret-123"))
            #expect(!text.contains("hunter2-hunter2"))
        }
        let auth = try String(contentsOf: harness.directory.url.appending(path: "web/auth.json"), encoding: .utf8)
        #expect(!auth.contains("hunter2-hunter2"))
        // The camera's password went to the secret store only.
        let stored: String? = backend.read { $0.passwords.values.first }
        #expect(stored == "camera-secret-123")
    }
}
