import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import BridgeWeb

/// Short-lived HLS tickets: a viewer mints one with its key (`POST hls/tickets`), and the player then fetches files with only the ticket in
/// the path (`GET hls/:ticket/:file`, open). A ticket opens one camera, read-only, and the viewer's key never goes in a URL.
@Suite(.timeLimit(.minutes(1))) struct HLSTicketRoutesTests {
    /// The clocks the tests move: the time of day, and the time that passed (what tickets end on). Time passing moves both; somebody setting the
    /// clock moves only the first.
    private final class Clock: Sendable {
        private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        private let passed = Mutex(ContinuousClock.now)
        var now: Date { time.withLock { $0 } }
        var uptime: ContinuousClock.Instant { passed.withLock { $0 } }

        func advance(_ seconds: TimeInterval) {
            step(seconds)
            passed.withLock { $0 = $0.advanced(by: .seconds(seconds)) }
        }

        /// The time of day is set `seconds` forward, or back if negative.
        func step(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    private struct Bridge {
        var harness: Harness
        var owner: Harness.Session
        var tv: Harness.PairedTV
        var camera: CameraConfiguration
        var clock: Clock
    }

    private func makeBridge() async throws -> Bridge {
        let backend = FakeBackend()
        let porch = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.20"), username: "")
        try await backend.addCamera(porch, password: nil)
        // Some recordings for a recorded ticket to play: 9 s from `NVRRig.base`.
        let recording = try ArchiveFixture.file(camera: porch.id, segment: "\(porch.id.uuidString)/2026-09-14/13-24-05", startMs: Double(NVRRig.base), fragments: 9, gopFragments: 3)
        backend.write { $0.archive = FakeArchiveReading([recording]) }
        let clock = Clock()
        let harness = try Harness(backend: backend) {
            $0.now = { clock.now }
            $0.uptime = { clock.uptime }
            $0.hlsFirstPlaylistWait = .milliseconds(10)
        }
        let owner = try await harness.signIn()
        return Bridge(harness: harness, owner: owner, tv: try await harness.pairAppleTV(owner: owner), camera: porch, clock: clock)
    }

    private func bearer(_ key: String) -> [(String, String)] { [("Authorization", "Bearer \(key)")] }

    private func mint(_ bridge: Bridge, camera: UUID? = nil, body: [String: Any]? = nil) async -> Answer {
        let body = body ?? ["camera": (camera ?? bridge.camera.id).uuidString, "kind": "live", "stream": "sub", "audio": false]
        return await bridge.harness.send("POST", "/api/v1/hls/tickets", json: body, headers: bearer(bridge.tv.key))
    }

    private func ticketOf(in answer: Answer) throws -> String {
        let url = try #require(answer.json["url"] as? String, "a url: \(answer.text)")
        let parts = url.split(separator: "/").map(String.init)
        return try #require(parts.count == 5 ? parts[3] : nil, "/api/v1/hls/<ticket>/index.m3u8: \(url)")
    }

    /// The owner signed in from another browser.
    private func secondBrowser(_ bridge: Bridge) async throws -> Harness.Session {
        let answer = await bridge.harness.send("POST", "/api/v1/auth/login", json: ["password": "correct horse"], headers: [("User-Agent", "Other")], from: "192.0.2.41")
        let cookie = try #require(answer.cookie, "\(answer.text)")
        return Harness.Session(cookie: cookie, csrf: answer.json["csrfToken"] as? String ?? "", harness: bridge.harness)
    }

    private func fetch(_ bridge: Bridge, _ ticket: String, _ file: String = "index.m3u8") async -> Answer {
        await bridge.harness.send("GET", "/api/v1/hls/\(ticket)/\(file)")
    }

    @Test func mintNeedsAViewerKey() async throws {
        let bridge = try await makeBridge()
        let body: [String: Any] = ["camera": bridge.camera.id.uuidString, "kind": "live"]
        let none = await bridge.harness.send("POST", "/api/v1/hls/tickets", json: body)
        #expect(none.status == 401)
        let wrong = await bridge.harness.send("POST", "/api/v1/hls/tickets", json: body, headers: bearer("0123"))
        #expect(wrong.status == 401 && wrong.json["code"] as? String == "viewer_key")
        #expect((await mint(bridge)).status == 200)
    }

    @Test func aSessionCookieMayMintToo() async throws {
        let bridge = try await makeBridge()
        let answer = await bridge.owner.send("POST", "/api/v1/hls/tickets", json: ["camera": bridge.camera.id.uuidString, "kind": "live"])
        #expect(answer.status == 200, "\(answer.text)")
        let ticket = try ticketOf(in: answer)
        // Removing an Apple TV does not end a browser's ticket.
        #expect(await bridge.owner.send("DELETE", "/api/v1/viewers/\(bridge.tv.id)").status == 204)
        #expect((await fetch(bridge, ticket)).status == 503, "there is still a ticket, and this fake's camera gives no picture")
        let touched = await bridge.harness.app.hlsTickets.touch(ticket, now: bridge.clock.uptime)
        #expect(touched != nil)
    }

    @Test func answersAURLWithNoKeyInIt() async throws {
        let bridge = try await makeBridge()
        let answer = await mint(bridge)
        #expect(answer.status == 200)
        let url = try #require(answer.json["url"] as? String)
        #expect(url.hasPrefix("/api/v1/hls/") && url.hasSuffix("/index.m3u8"))
        #expect(!url.contains(bridge.tv.key) && !url.contains("?") && !url.contains("token"))
        #expect(answer.json["expiresIn"] as? Int == 300)
        let ticket = try ticketOf(in: answer)
        let lowerHex = Set("0123456789abcdef")
        #expect(ticket.count == 64 && ticket.allSatisfy { lowerHex.contains($0) })
        #expect(ticket != bridge.tv.key)
        let second = try ticketOf(in: await mint(bridge))
        #expect(second != ticket)
    }

    @Test func aRecordedTicketTakesARange() async throws {
        let bridge = try await makeBridge()
        let id = bridge.camera.id.uuidString
        #expect((await mint(bridge, body: ["camera": id, "kind": "recorded", "from": NVRRig.base, "to": NVRRig.base + 9_000])).status == 200)
        #expect((await mint(bridge, body: ["camera": id, "kind": "recorded", "from": NVRRig.base + 9_000, "to": NVRRig.base])).status == 400)
        #expect((await mint(bridge, body: ["camera": id, "kind": "recorded", "from": 0, "to": 7_200_001])).status == 400)
        #expect((await mint(bridge, body: ["camera": id, "kind": "recorded"])).status == 400)
        #expect((await mint(bridge, body: ["camera": id, "kind": "other"])).status == 400)
        #expect((await mint(bridge, body: ["camera": id, "kind": "live", "stream": "huge"])).status == 400)
    }

    @Test func refusesAnUnknownCamera() async throws {
        let bridge = try await makeBridge()
        #expect((await mint(bridge, camera: UUID())).status == 404)
    }

    @Test func aKeyInTheAddressStaysRefused() async throws {
        let bridge = try await makeBridge()
        let body: [String: Any] = ["camera": bridge.camera.id.uuidString, "kind": "live"]
        let answer = await bridge.harness.send("POST", "/api/v1/hls/tickets?token=\(bridge.tv.key)", json: body, headers: bearer(bridge.tv.key))
        #expect(answer.status == 400)
    }

    @Test func unknownTicketIs404WithNoDetail() async throws {
        let bridge = try await makeBridge()
        let real = try ticketOf(in: await mint(bridge))
        let badTicket = await fetch(bridge, String(repeating: "0", count: 64))
        let badFile = await fetch(bridge, real, "nothing.txt")
        let goodFile = await fetch(bridge, real, "seg-0.m4s")
        for answer in [badTicket, badFile, goodFile] {
            #expect(answer.status == 404)
            #expect(!answer.text.contains("ticket") && !answer.text.contains("not_found"), "no detail: \(answer.text)")
        }
        #expect(badTicket.body == badFile.body && badFile.body == goodFile.body, "the same answer, so nothing says which part was wrong")
        #expect(badTicket.headers["Content-Type"] == badFile.headers["Content-Type"])
    }

    @Test func expiresFiveMinutesAfterLastUse() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticketOf(in: await mint(bridge))
        let tickets = bridge.harness.app.hlsTickets
        bridge.clock.advance(299)
        #expect(await tickets.touch(ticket, now: bridge.clock.uptime) != nil)
        bridge.clock.advance(299)
        #expect(await tickets.touch(ticket, now: bridge.clock.uptime) != nil, "each use starts the five minutes again")
        bridge.clock.advance(301)
        #expect(await tickets.touch(ticket, now: bridge.clock.uptime) == nil)
        #expect(await tickets.touch(ticket, now: bridge.clock.uptime) == nil, "and stays gone")
    }

    @Test func hardCapSixHours() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticketOf(in: await mint(bridge))
        let tickets = bridge.harness.app.hlsTickets
        for _ in 0..<71 {
            bridge.clock.advance(299)
            #expect(await tickets.touch(ticket, now: bridge.clock.uptime) != nil)
        }
        bridge.clock.advance(299)   // 72 x 299 s = 21,528 s
        #expect(await tickets.touch(ticket, now: bridge.clock.uptime) != nil)
        bridge.clock.advance(100)   // 21,628 s, kept alive all along
        #expect(await tickets.touch(ticket, now: bridge.clock.uptime) == nil)
    }

    /// Review of 2026-11-09, M1: tickets ended on the time of day, so a clock set forward ended every open one and a clock set back made them last longer.
    @Test func settingTheClockNeitherEndsATicketNorMakesOneLastLonger() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticketOf(in: await mint(bridge))
        let tickets = bridge.harness.app.hlsTickets
        bridge.clock.step(3_600)
        #expect(await tickets.touch(ticket, now: bridge.clock.uptime) != nil, "an hour ahead on the wall, but no time passed")
        #expect((await fetch(bridge, ticket)).status != 404, "and its files are still there")
        bridge.clock.step(-86_400)
        bridge.clock.advance(301)
        #expect(await tickets.touch(ticket, now: bridge.clock.uptime) == nil, "a day back on the wall, and five minutes passed: it ended")
        let second = try ticketOf(in: await mint(bridge))
        for _ in 0..<72 {
            bridge.clock.step(-3_600)
            bridge.clock.advance(299)
            _ = await tickets.touch(second, now: bridge.clock.uptime)
        }
        bridge.clock.advance(100)
        #expect(await tickets.touch(second, now: bridge.clock.uptime) == nil, "six hours of use, whatever the clock says")
    }

    @Test func eighthIsKeptAndNinthDropsTheOldest() async throws {
        let bridge = try await makeBridge()
        var minted: [String] = []
        for _ in 0..<8 {
            minted.append(try ticketOf(in: await mint(bridge)))
            bridge.clock.advance(1)
        }
        let tickets = bridge.harness.app.hlsTickets
        #expect(await tickets.count(viewer: bridge.tv.id) == 8)
        minted.append(try ticketOf(in: await mint(bridge)))
        #expect(await tickets.count(viewer: bridge.tv.id) == 8)
        #expect(await tickets.touch(minted[0], now: bridge.clock.uptime) == nil, "the oldest")
        for kept in minted.dropFirst() { #expect(await tickets.touch(kept, now: bridge.clock.uptime) != nil) }
        let key = HLSLivePackager.Key(camera: bridge.camera.id, stream: .sub, audio: false)
        #expect(await bridge.harness.app.hlsPackagers.running(key) != nil, "the other tickets play the same packager: it goes on")
    }

    @Test func oneViewersTicketsDoNotCountForAnother() async throws {
        let bridge = try await makeBridge()
        let other = try await bridge.harness.pairAppleTV(owner: bridge.owner, name: "Bedroom", from: "192.0.2.41")
        let first = try ticketOf(in: await mint(bridge))
        for _ in 0..<9 {
            _ = await bridge.harness.send("POST", "/api/v1/hls/tickets", json: ["camera": bridge.camera.id.uuidString, "kind": "live"], headers: bearer(other.key))
        }
        #expect(await bridge.harness.app.hlsTickets.touch(first, now: bridge.clock.uptime) != nil)
    }

    @Test func removedViewerGets404AtOnce() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticketOf(in: await mint(bridge))
        let tickets = bridge.harness.app.hlsTickets
        #expect(await bridge.owner.send("DELETE", "/api/v1/viewers/\(bridge.tv.id)").status == 204)
        #expect((await fetch(bridge, ticket)).status == 404)
        #expect(await tickets.touch(ticket, now: bridge.clock.uptime) == nil, "and the ticket is dropped, not only refused")
    }

    @Test func signOutEndsItsTickets() async throws {
        let bridge = try await makeBridge()
        let answer = await bridge.owner.send("POST", "/api/v1/hls/tickets", json: ["camera": bridge.camera.id.uuidString, "kind": "live"])
        let ticket = try ticketOf(in: answer)
        #expect(await bridge.owner.send("POST", "/api/v1/auth/logout").status == 204)
        #expect((await fetch(bridge, ticket)).status == 404)
        #expect(await bridge.harness.app.hlsTickets.touch(ticket, now: bridge.clock.uptime) == nil, "dropped, not only refused")
    }

    @Test func removingABrowserEndsItsTickets() async throws {
        let bridge = try await makeBridge()
        let second = try await secondBrowser(bridge)
        let ticket = try ticketOf(in: await second.send("POST", "/api/v1/hls/tickets", json: ["camera": bridge.camera.id.uuidString, "kind": "live"]))
        let listed = try #require(await bridge.owner.get("/api/v1/auth/sessions").json["sessions"] as? [[String: Any]])
        let theirs = try #require(listed.first { $0["current"] as? Bool == false }?["id"] as? String)
        #expect(await bridge.owner.send("DELETE", "/api/v1/auth/sessions/\(theirs)").status == 204)
        #expect(await bridge.harness.app.hlsTickets.touch(ticket, now: bridge.clock.uptime) != nil, "still held until it is fetched")
        #expect((await fetch(bridge, ticket)).status == 404)
        #expect(await bridge.harness.app.hlsTickets.touch(ticket, now: bridge.clock.uptime) == nil)
    }

    @Test func aPasswordChangeEndsOtherSessionsTickets() async throws {
        let bridge = try await makeBridge()
        let second = try await secondBrowser(bridge)
        let body: [String: Any] = ["camera": bridge.camera.id.uuidString, "kind": "live"]
        let theirs = try ticketOf(in: await second.send("POST", "/api/v1/hls/tickets", json: body))
        let mine = try ticketOf(in: await bridge.owner.send("POST", "/api/v1/hls/tickets", json: body))
        let changed = await bridge.owner.send("POST", "/api/v1/auth/password", json: ["current": "correct horse", "new": "another horse staple"])
        #expect(changed.status == 204 || changed.status == 200, "\(changed.text)")
        #expect(await bridge.harness.app.hlsTickets.touch(theirs, now: bridge.clock.uptime) != nil)
        #expect((await fetch(bridge, theirs)).status == 404)
        #expect(await bridge.harness.app.hlsTickets.touch(theirs, now: bridge.clock.uptime) == nil)
        #expect(await bridge.harness.app.hlsTickets.touch(mine, now: bridge.clock.uptime) != nil, "the browser that changed it stays signed in")
    }

    @Test func aTicketKeepsWhatItWasMintedFor() async throws {
        let bridge = try await makeBridge()
        let live = try ticketOf(in: await mint(bridge, body: ["camera": bridge.camera.id.uuidString, "kind": "live", "stream": "main", "audio": true]))
        let recorded = try ticketOf(in: await mint(bridge, body: ["camera": bridge.camera.id.uuidString, "kind": "recorded", "from": NVRRig.base, "to": NVRRig.base + 9_000]))
        let tickets = bridge.harness.app.hlsTickets
        let a = try #require(await tickets.touch(live, now: bridge.clock.uptime))
        #expect(a.camera == bridge.camera.id && a.viewer == bridge.tv.id && a.kind == .live(stream: .main, audio: true))
        let b = try #require(await tickets.touch(recorded, now: bridge.clock.uptime))
        #expect(b.camera == bridge.camera.id && b.viewer == bridge.tv.id && b.kind == .recorded(from: NVRRig.base, to: NVRRig.base + 9_000))
    }

    @Test func anOversizedTicketIsNotLookedUp() async throws {
        let bridge = try await makeBridge()
        let real = try ticketOf(in: await mint(bridge))
        #expect(await bridge.harness.app.hlsTickets.touch(real + "0", now: bridge.clock.uptime) == nil)
        #expect(await bridge.harness.app.hlsTickets.touch(String(repeating: "a", count: 100_000), now: bridge.clock.uptime) == nil)
        #expect((await fetch(bridge, String(repeating: "a", count: 5_000))).status == 404)
    }

    @Test func everyFileIsNoStore() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticketOf(in: await mint(bridge))
        for file in ["index.m3u8", "media.m3u8", "init-1.mp4", "seg-1.m4s", "bad"] {
            #expect((await fetch(bridge, ticket, file)).headers["Cache-Control"] == "no-store", "\(file)")
        }
        #expect((await fetch(bridge, "nope")).headers["Cache-Control"] == "no-store")
        #expect((await mint(bridge)).headers["Cache-Control"] == "no-store")
    }

    @Test func ticketIsComparedInConstantTime() throws {
        // The lookup compares with Secrets.constantTimeEqual against every held ticket rather than hashing into a dictionary.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/BridgeWeb/HLS/HLSTickets.swift").standardized, encoding: .utf8)
        #expect(source.contains("Secrets.constantTimeEqual"))
    }

    @Test func hostCheckStillApplies() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticketOf(in: await mint(bridge))
        let answer = await bridge.harness.send("GET", "/api/v1/hls/\(ticket)/index.m3u8", headers: [("Host", "evil.example.com")])
        #expect(answer.status == 421)
    }

    @Test func theRouteTableHasTheNewRoutes() {
        let routes = WebApp.routes.map { "\($0.method) \($0.pattern.joined(separator: "/")) \($0.access)" }
        #expect(routes.contains("POST hls/tickets viewer"))
        #expect(routes.contains("GET hls/:ticket/:file open"))
    }
}
