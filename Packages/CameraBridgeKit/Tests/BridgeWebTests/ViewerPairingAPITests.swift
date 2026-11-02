import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// Adding an Apple TV over HTTP: it asks for a code (`POST viewers/pair`, open), the owner types the code while signed in (`POST
/// viewers/approve`) and the TV, asking again (`POST viewers/pair/status`, open), is handed its key once; the owner lists the TVs and removes
/// one (`GET viewers`, `DELETE viewers/:id`). The requests themselves are `ViewerPairingTests`', the file `ViewerStoreTests`'.
@Suite(.timeLimit(.minutes(1))) struct ViewerPairingAPITests {
    private static let pairPath = "/api/v1/viewers/pair"
    private static let statusPath = "/api/v1/viewers/pair/status"
    private static let approvePath = "/api/v1/viewers/approve"
    private static let viewersPath = "/api/v1/viewers"

    private static let noSuchCode = "No Apple TV is waiting with this code. Check the code on the TV: it shows a new one every 10 minutes."
    private static let pairingGone = "This code ran out or was removed. Ask for a new one."

    private func isLowercaseHex(_ text: Any?, count: Int) -> Bool {
        guard let text = text as? String else { return false }
        return text.count == count && text.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// A TV asks for a code from `address`.
    private func ask(_ harness: Harness, _ body: [String: String] = ["name": "Living Room"], from address: String = "192.0.2.40") async -> Answer {
        await harness.send("POST", Self.pairPath, json: body, from: address)
    }

    /// The TV asks whether its code was entered.
    private func collect(_ harness: Harness, request: String, secret: String, from address: String = "192.0.2.40") async -> Answer {
        await harness.send("POST", Self.statusPath, json: ["request": request, "secret": secret], from: address)
    }

    /// The TVs the owner's list shows.
    private func listed(_ owner: Harness.Session) async throws -> [[String: Any]] {
        let answer = await owner.get(Self.viewersPath)
        #expect(answer.status == 200, "\(answer.text)")
        return try #require(answer.json["viewers"] as? [[String: Any]])
    }

    private func listedIDs(_ owner: Harness.Session) async throws -> [String] {
        try await listed(owner).compactMap { $0["id"] as? String }
    }

    // MARK: Pairing

    @Test func aTVPairsWithACodeTheOwnerEnters() async throws {
        let harness = try Harness()
        let owner = try await harness.signIn()

        let asked = await harness.send("POST", Self.pairPath, json: ["name": "Living Room", "device": "Apple TV 4K (3rd generation)"], from: "192.0.2.40")
        #expect(asked.status == 200, "\(asked.text)")
        #expect(Set(asked.json.keys) == ["request", "secret", "code", "expiresIn", "interval"])
        let request = try #require(asked.json["request"] as? String)
        let secret = try #require(asked.json["secret"] as? String)
        let code = try #require(asked.json["code"] as? String)
        #expect(isLowercaseHex(request, count: 32) && isLowercaseHex(secret, count: 64))
        #expect(code.range(of: "^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$", options: .regularExpression) != nil, "\(code)")
        #expect(asked.json["expiresIn"] as? Int == 600 && asked.json["interval"] as? Int == 2)

        let waiting = await collect(harness, request: request, secret: secret)
        #expect(waiting.status == 200 && Set(waiting.json.keys) == ["state"] && waiting.json["state"] as? String == "waiting")

        let typed = code.lowercased().replacingOccurrences(of: "-", with: " ")   // "bcdf ghjk"
        let signedOut = await harness.send("POST", Self.approvePath, json: ["code": typed])
        #expect(signedOut.status == 401 && signedOut.json["error"] as? String == "unauthorized")
        let noToken = await harness.send("POST", Self.approvePath, json: ["code": typed], cookie: owner.cookie)
        #expect(noToken.status == 403 && noToken.json["error"] as? String == "csrf")
        #expect(await harness.send("GET", Self.viewersPath).status == 401)
        #expect(await collect(harness, request: request, secret: secret).json["state"] as? String == "waiting", "neither of them used the code up")

        let approved = await owner.send("POST", Self.approvePath, json: ["code": typed])
        #expect(approved.status == 201, "\(approved.text)")
        #expect(Set(approved.json.keys) == ["viewer"])
        let viewer = try #require(approved.json["viewer"] as? [String: Any])
        #expect(Set(viewer.keys) == ["id", "name", "device", "created", "lastSeen", "address"])
        let id = try #require(viewer["id"] as? String)
        #expect(isLowercaseHex(id, count: 32))
        #expect(viewer["name"] as? String == "Living Room" && viewer["device"] as? String == "Apple TV 4K (3rd generation)")
        #expect(viewer["lastSeen"] is NSNull && viewer["address"] as? String == "192.0.2.40")
        let created = try #require(viewer["created"] as? String)
        #expect(created.range(of: "^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ$", options: .regularExpression) != nil, "whole seconds, UTC: \(created)")
        let date = try #require(ISO8601DateFormatter().date(from: created))
        #expect(abs(date.timeIntervalSinceNow) < 60)

        let collected = await collect(harness, request: request, secret: secret)
        #expect(collected.status == 200 && collected.headers["Cache-Control"] == "no-store")
        #expect(Set(collected.json.keys) == ["state", "token", "viewer"] && collected.json["state"] as? String == "approved")
        let token = try #require(collected.json["token"] as? String)
        #expect(isLowercaseHex(token, count: 64))
        let collectedViewer = try #require(collected.json["viewer"] as? [String: Any])
        #expect(Set(collectedViewer.keys) == ["id", "name"] && collectedViewer["id"] as? String == id && collectedViewer["name"] as? String == "Living Room")

        let again = await collect(harness, request: request, secret: secret)
        #expect(again.status == 404 && again.json["error"] as? String == "pairing_gone" && again.json["code"] as? String == "pairing_gone")
        #expect(again.json["message"] as? String == Self.pairingGone, "the key is handed out once")

        let list = await owner.get(Self.viewersPath)
        #expect(list.status == 200 && Set(list.json.keys) == ["viewers"])
        let ids = try await listedIDs(owner)
        #expect(ids == [id])
        #expect(!list.text.contains(token) && !list.text.contains(Secrets.sha256Hex(token)), "the list holds neither the key nor its hash")
    }

    @Test func aTVThatSendsNothingAboutItselfIsAppleTV() async throws {
        let harness = try Harness()
        let owner = try await harness.signIn()
        let asked = await ask(harness, [:])
        #expect(asked.status == 200, "{} is a fine request: both fields are optional")
        let code = try #require(asked.json["code"] as? String)
        let added = await owner.send("POST", Self.approvePath, json: ["code": code])
        let viewer = try #require(added.json["viewer"] as? [String: Any])
        #expect(viewer["name"] as? String == "Apple TV")
        #expect(viewer.keys.contains("device") && viewer["device"] is NSNull, "the key is there, with null")
        let everyKey = try await listed(owner).allSatisfy { Set($0.keys) == ["id", "name", "device", "created", "lastSeen", "address"] }
        #expect(everyKey)

        #expect(await harness.send("POST", Self.pairPath).status == 400, "the body is required, even if it is {}")
        #expect(await harness.send("POST", Self.pairPath, json: ["name": 5], from: "192.0.2.42").status == 400)
    }

    @Test func pairingStartsBeforeSetupButOnlyTheOwnerApproves() async throws {
        let harness = try Harness()
        let asked = await ask(harness)
        #expect(asked.status == 200, "a TV can ask on a box that has no password yet")
        let code = try #require(asked.json["code"] as? String)
        let early = await harness.send("POST", Self.approvePath, json: ["code": code])
        #expect(early.status == 403 && early.json["error"] as? String == "setup_required")
        #expect(await harness.send("GET", Self.viewersPath).status == 403)

        let owner = try await harness.signIn()
        #expect(await owner.send("POST", Self.approvePath, json: ["code": code]).status == 201, "the code waited for the owner")
    }

    @Test func codesThatOpenNothingAre404NoSuchCode() async throws {
        let harness = try Harness()
        let owner = try await harness.signIn()
        for typed in ["ZZZZ-ZZZZ", "ABCD-EFGH", "BCDF-GHJ", "BCDF-GHJKL", ""] {
            let answer = await owner.send("POST", Self.approvePath, json: ["code": typed])
            #expect(answer.status == 404 && answer.json["error"] as? String == "no_such_code" && answer.json["code"] as? String == "no_such_code",
                    "“\(typed)” -> \(answer.status)")
            #expect(answer.json["message"] as? String == Self.noSuchCode)
        }

        let code = try #require(await ask(harness).json["code"] as? String)
        #expect(await owner.send("POST", Self.approvePath, json: ["code": code]).status == 201)
        let second = await owner.send("POST", Self.approvePath, json: ["code": code])
        #expect(second.status == 404 && second.json["error"] as? String == "no_such_code", "a code adds one TV, once")
        let count = try await listed(owner).count
        #expect(count == 1)

        let missing = await owner.send("POST", Self.approvePath, json: [String: String]())
        #expect(missing.status == 400 && missing.json["field"] as? String == "code")
        #expect(await owner.send("POST", Self.approvePath, json: ["code": 12345]).status == 400)
        #expect(await owner.send("POST", Self.approvePath).status == 400)
    }

    @Test func aTVAskingAboutARequestThatIsGoneIsToldSo() async throws {
        let harness = try Harness()
        let owner = try await harness.signIn()
        let asked = await ask(harness)
        let request = try #require(asked.json["request"] as? String)
        let secret = try #require(asked.json["secret"] as? String)
        let code = try #require(asked.json["code"] as? String)

        let others = [("a wrong secret", request, String(repeating: "0", count: 64)), ("a request nobody made", String(repeating: "0", count: 32), secret),
                      ("values that cannot be ours", "short", "short")]
        for (why, otherRequest, otherSecret) in others {
            let answer = await collect(harness, request: otherRequest, secret: otherSecret)
            #expect(answer.status == 404 && answer.json["error"] as? String == "pairing_gone", "\(why)")
            #expect(answer.json["message"] as? String == Self.pairingGone, "\(why)")
        }
        let right = await collect(harness, request: request, secret: secret)
        #expect(right.json["state"] as? String == "waiting", "a wrong secret changes nothing for the TV that has the right one")
        #expect(await harness.send("POST", Self.statusPath, json: ["request": request]).status == 400)
        #expect(await harness.send("POST", Self.statusPath).status == 400)

        let added = await owner.send("POST", Self.approvePath, json: ["code": code])
        let id = try #require((added.json["viewer"] as? [String: Any])?["id"] as? String)
        #expect(await owner.send("DELETE", "\(Self.viewersPath)/\(id)").status == 204)
        let removed = await collect(harness, request: request, secret: secret)
        #expect(removed.status == 404 && removed.json["error"] as? String == "pairing_gone", "removed before it collected its key: no key is handed out")
        let remaining = try await listed(owner)
        #expect(remaining.isEmpty)
    }

    @Test func anApprovalThatCannotBeSavedIs500AndTheCodeStillWaits() async throws {
        let harness = try Harness()
        let owner = try await harness.signIn()
        let code = try #require(await ask(harness).json["code"] as? String)
        let folder = harness.directory.url.appending(path: "web").path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)   // the data partition went read-only
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }
        guard !FileManager.default.isWritableFile(atPath: folder) else { return }   // running as root: every folder can be written

        let refused = await owner.send("POST", Self.approvePath, json: ["code": code])
        #expect(refused.status == 500 && refused.json["error"] as? String == "storage" && refused.json["code"] as? String == "storage")
        #expect(refused.json["message"] as? String == "The Apple TV couldn’t be saved. The disk may be full or read-only.")
        let afterwards = try await listed(owner)
        #expect(afterwards.isEmpty, "a TV that would be gone at the next restart is not added")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        #expect(await owner.send("POST", Self.approvePath, json: ["code": code]).status == 201, "the disk takes it again")
    }

    // MARK: Limits

    @Test func aFourthRequestFromOneAddressIs429WithRetryAfter() async throws {
        let harness = try Harness()
        for _ in 0..<3 { #expect(await ask(harness, from: "192.0.2.40").status == 200) }
        let fourth = await ask(harness, from: "192.0.2.40")
        #expect(fourth.status == 429 && fourth.json["error"] as? String == "too_many_pairings" && fourth.json["code"] as? String == "too_many_pairings")
        #expect(fourth.json["message"] as? String == "Too many Apple TVs are asking for a code right now. Try again in a few minutes.")
        let wait = try #require(fourth.headers["Retry-After"].flatMap { Int($0) }, "Retry-After is whole seconds")
        #expect((1...600).contains(wait), "\(wait)")
        #expect(await ask(harness, from: "192.0.2.41").status == 200, "another address is not held up")
    }

    @Test func theAddressesOfOneIPv6NetworkCountAsOne() async throws {
        let harness = try Harness()
        for address in ["2001:db8:1:2::1", "2001:db8:1:2:aaaa::2", "2001:db8:1:2:aaaa:bbbb:cccc:dddd"] {
            #expect(await ask(harness, from: address).status == 200, "\(address)")
        }
        let fourth = await ask(harness, from: "2001:db8:1:2:eeee::4")
        #expect(fourth.status == 429 && fourth.json["error"] as? String == "too_many_pairings", "a privacy address of the same network")
        #expect(fourth.headers["Retry-After"].flatMap { Int($0) } != nil)
        #expect(await ask(harness, from: "2001:db8:1:3::1").status == 200, "another network")
    }

    @Test func twentyTVsAtMost() async throws {
        let harness = try Harness()
        let owner = try await harness.signIn()
        var added: [Harness.PairedTV] = []
        for number in 1...20 {
            added.append(try await harness.pairAppleTV(owner: owner, name: "TV \(number)", from: "192.0.2.\(number)"))
        }
        let full = try await listed(owner).count
        #expect(full == 20)

        let code = try #require(await ask(harness, ["name": "One too many"], from: "192.0.2.21").json["code"] as? String)
        let refused = await owner.send("POST", Self.approvePath, json: ["code": code])
        #expect(refused.status == 409 && refused.json["error"] as? String == "too_many_viewers" && refused.json["code"] as? String == "too_many_viewers")
        #expect(refused.json["message"] as? String == "20 Apple TVs are added already. Remove one you no longer use, then try again.")
        let stillFull = try await listed(owner).count
        #expect(stillFull == 20)

        #expect(await owner.send("DELETE", "\(Self.viewersPath)/\(added[0].id)").status == 204)
        #expect(await owner.send("POST", Self.approvePath, json: ["code": code]).status == 201, "the code waited for room")
        let refilled = try await listed(owner).count
        #expect(refilled == 20)
    }

    // MARK: The list

    @Test func aTVIsRemovedFromTheList() async throws {
        let harness = try Harness()
        let owner = try await harness.signIn()
        let livingRoom = try await harness.pairAppleTV(owner: owner, name: "Living Room")
        let bedroom = try await harness.pairAppleTV(owner: owner, name: "Bedroom", from: "192.0.2.41")
        let both = try await listedIDs(owner)
        #expect(both == [bedroom.id, livingRoom.id], "the one used last first: the newer, while neither was used")

        #expect(await harness.send("DELETE", "\(Self.viewersPath)/\(livingRoom.id)").status == 401)
        #expect(await harness.send("DELETE", "\(Self.viewersPath)/\(livingRoom.id)", cookie: owner.cookie).status == 403, "and the token is needed")
        let notRemoved = try await listedIDs(owner)
        #expect(notRemoved.count == 2, "neither removed it")

        let removed = await owner.send("DELETE", "\(Self.viewersPath)/\(livingRoom.id)")
        #expect(removed.status == 204 && removed.body.isEmpty)
        let again = await owner.send("DELETE", "\(Self.viewersPath)/\(livingRoom.id)")
        #expect(again.status == 404 && again.json["error"] as? String == "not_found")
        #expect(again.json["message"] as? String == "That Apple TV isn’t added any more.")
        let left = try await listedIDs(owner)
        #expect(left == [bedroom.id])

        for id in ["nobody", "pair", String(repeating: "a", count: 200)] {
            #expect(await owner.send("DELETE", "\(Self.viewersPath)/\(id)").status == 404, "\(id)")
        }
        let last = try await listedIDs(owner)
        #expect(last == [bedroom.id])
    }

    // MARK: Other sites, other content

    @Test func pairingIsOpenButNotToOtherSites() async throws {
        let harness = try Harness()
        _ = try await harness.signIn()
        let bodies: [(path: String, json: [String: String])] = [
            (Self.pairPath, ["name": "Living Room"]),
            (Self.statusPath, ["request": String(repeating: "0", count: 32), "secret": String(repeating: "0", count: 64)]),
        ]
        for (path, json) in bodies {
            let foreign = await harness.send("POST", path, json: json, origin: "http://evil.example")
            #expect(foreign.status == 403 && foreign.json["error"] as? String == "cross_origin", "\(path)")
            let crossSite = await harness.send("POST", path, json: json, headers: [("Sec-Fetch-Site", "cross-site")])
            #expect(crossSite.status == 403 && crossSite.json["error"] as? String == "cross_origin", "\(path) from a browser that sends no Origin")

            var plain = harness.request("POST", path)
            plain.body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            plain.headers["Content-Type"] = "text/plain"
            let notJSON = await harness.app.handle(plain)
            #expect(notJSON.status == 415, "\(path) as text/plain")
        }
        let own = await harness.send("POST", Self.pairPath, json: ["name": "Living Room"], origin: "http://camera-bridge.local")
        #expect(own.status == 200, "its own site is fine")
        let app = await harness.send("POST", Self.pairPath, json: ["name": "Living Room"], from: "192.0.2.41")
        #expect(app.status == 200, "and so is an app, which sends no Origin")
    }
}
