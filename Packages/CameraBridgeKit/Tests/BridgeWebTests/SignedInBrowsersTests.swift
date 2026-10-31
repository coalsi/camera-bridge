import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// The Signed-in browsers list (`GET auth/sessions`, `DELETE auth/sessions/:id`) and the security notice for a burst of wrong passwords.
@Suite(.timeLimit(.minutes(1))) struct SignedInBrowsersTests {
    static let iPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    @Test func theListSaysWhichBrowserAndWhereAndOneCanBeSignedOut() async throws {
        let harness = try Harness()
        let mine = try await harness.signIn()
        let phone = await harness.send("POST", "/api/v1/auth/login", json: ["password": "correct horse"], headers: [("User-Agent", Self.iPhone)], from: "192.0.2.41")
        let phoneCookie = try #require(phone.cookie)
        let list = await mine.get("/api/v1/auth/sessions")
        #expect(list.status == 200)
        let sessions = try #require(list.json["sessions"] as? [[String: Any]])
        #expect(sessions.count == 2)
        #expect(sessions.allSatisfy { Set($0.keys) == ["id", "browser", "address", "created", "lastSeen", "current"] })
        let entry = try #require(sessions.first { $0["browser"] as? String == "Safari on iPhone" })
        #expect(entry["address"] as? String == "192.0.2.41" && entry["current"] as? Bool == false)
        #expect(sessions.filter { $0["current"] as? Bool == true }.count == 1, "the browser that asks is marked")
        let id = try #require(entry["id"] as? String)
        let token = String(phoneCookie.dropFirst("cb_session=".count))
        #expect(!id.isEmpty && !token.contains(id) && id != Secrets.sha256Hex(token), "the id signs nobody in")

        #expect(await mine.send("DELETE", "/api/v1/auth/sessions/\(id)").status == 204)
        #expect(await harness.send("GET", "/api/v1/settings", cookie: phoneCookie).status == 401, "the phone is signed out")
        #expect(await mine.get("/api/v1/settings").status == 200, "this browser is not")
        #expect(await mine.send("DELETE", "/api/v1/auth/sessions/\(id)").status == 404)
        #expect(await harness.send("GET", "/api/v1/auth/sessions").status == 401)
    }

    @Test func signingOutThisBrowserFromTheListClearsItsCookie() async throws {
        let harness = try Harness()
        let mine = try await harness.signIn()
        let sessions = try #require(await mine.get("/api/v1/auth/sessions").json["sessions"] as? [[String: Any]])
        let id = try #require(sessions.first { $0["current"] as? Bool == true }?["id"] as? String)
        let out = await mine.send("DELETE", "/api/v1/auth/sessions/\(id)")
        #expect(out.status == 204 && out.headers.values(for: "Set-Cookie").contains { $0.hasPrefix("cb_session=;") })
        #expect(await mine.get("/api/v1/settings").status == 401)
    }

    @Test func browsersAreNamedTheWayAPersonWould() {
        let agents: [(String?, String)] = [
            (Self.iPhone, "Safari on iPhone"),
            ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15", "Safari on Mac"),
            ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", "Chrome on Windows"),
            ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0", "Edge on Windows"),
            ("Mozilla/5.0 (X11; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0", "Firefox on Linux"),
            ("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36", "Chrome on Android"),
            ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/130.0 Mobile/15E148 Safari/604.1", "Chrome on iPhone"),
            ("curl/8.7.1", "curl"),
            ("Home\u{7}Assistant/2026.10", "HomeAssistant"),
            (nil, "A browser"), ("", "A browser"),
        ]
        for (agent, expected) in agents { #expect(BrowserLabel.describe(agent) == expected, "\(agent ?? "nil")") }
        #expect(BrowserLabel.describe(String(repeating: "x", count: 500)).count == 60)
    }

    // MARK: Bursts of wrong passwords

    @Test func aBurstOfWrongPasswordsBecomesOneSecurityNotification() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        func signInNotices() async -> [[String: Any]] {
            (await session.get("/api/v1/notifications").json["notifications"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "signInAttempts" }
        }
        for _ in 0..<4 { _ = await harness.send("POST", "/api/v1/auth/login", json: ["password": "wrong password"], from: "192.0.2.40") }
        #expect(await signInNotices().isEmpty, "a few wrong tries are no news")
        _ = await harness.send("POST", "/api/v1/auth/login", json: ["password": "wrong password"], from: "192.0.2.40")
        var notices = await signInNotices()
        #expect(notices.count == 1)
        let notice = try #require(notices.first)
        #expect(notice["category"] as? String == "security" && notice["severity"] as? String == "warning" && notice["title"] as? String == "Wrong Passwords Entered")
        #expect((notice["detail"] as? String)?.hasPrefix("5 wrong passwords were entered from 192.0.2.40.") == true, "\(notice["detail"] ?? "")")
        let shown = await session.send("POST", "/api/v1/notifications/shown")
        #expect((shown.json["shown"] as? [[String: Any]])?.contains { $0["kind"] as? String == "signInAttempts" } == true, "one browser shows it as a toast")
        for _ in 0..<5 { _ = await harness.send("POST", "/api/v1/auth/login", json: ["password": "wrong password"], from: "192.0.2.41") }
        notices = await signInNotices()
        #expect(notices.count == 1, "the same burst: no second entry")
        #expect(await harness.app.auth.signInAlert()?.count == 10)
    }
}
