import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// Away from home's routes over a real `WebApp` with the fake system: the card and its devices (a signed-in browser), the paired iPhone's three
/// tunnel routes (its key), and the two hooks into the paired devices and the secure address.
@Suite(.timeLimit(.minutes(1))) struct AwayRoutesTests {
    static let secureState = SecureAddressState(name: "k7f2q9", host: "k7f2q9.box.camera-bridge.app", address: "192.0.2.10")
    static let cardKeys: Set<String> = ["on", "state", "problem", "port", "address", "name", "router", "addressChangedAt", "devices"]
    static let tunnelKeys: Set<String> = ["boxPublicKey", "endpoint", "address", "routes", "secureURL", "mtu"]

    struct Bridge {
        let harness: Harness
        let owner: Harness.Session
        let iPhone: Harness.PairedTV

        func phone(_ method: String, _ path: String = "/api/v1/viewer/away", json: Any? = nil) async -> Answer {
            await harness.send(method, path, json: json, headers: [("Authorization", "Bearer \(iPhone.key)")])
        }

        /// The phone's `DELETE viewer/away`: the response itself, so a test decides when "the answer has gone out" (`afterSend`).
        func phoneRemoval() async -> HTTPResponse {
            await harness.app.handle(harness.request("DELETE", "/api/v1/viewer/away", headers: [("Authorization", "Bearer \(iPhone.key)")]))
        }

        func turnOn() async { await owner.send("POST", "/api/v1/away", json: ["on": true]) }
    }

    /// A box with the secure address registered (no certificate, so no call reaches the website), a network with a global address and, unless
    /// `supportsAway` is false, a system with Away from home. The address is one the website takes (`AwayServiceTests.homeAddress` says why it
    /// isn't a documentation address).
    private func makeBridge(secureState: SecureAddressState? = Self.secureState, supportsAway: Bool = true) async throws -> Bridge {
        let network = FakeAwayNetwork()
        network.addresses.set([AwayAddress(address: AwayServiceTests.homeAddress, prefixLength: 64, preferredLifetime: .max)])
        network.prefixes.set(["192.0.2.0/24", AwayServiceTests.homePrefix])
        let harness = try Harness { configuration in
            secureState?.save(to: configuration.dataDirectory)
            configuration.awayNetwork = network
        }
        if supportsAway { harness.system.supportAway() }
        let owner = try await harness.signIn()
        return Bridge(harness: harness, owner: owner, iPhone: try await harness.pairAppleTV(owner: owner, name: "iPhone", device: "iPhone"))
    }

    private func peers(_ bridge: Bridge) -> Set<String> {
        Set(bridge.harness.system.awayRequests.value.last?.peers.map(\.publicKey) ?? [])
    }

    /// Waits for `condition`, which the detached removal makes true a moment after the answer.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test func theCardHasExactlyTheSpecsKeys() async throws {
        let bridge = try await makeBridge()
        let off = await bridge.owner.get("/api/v1/away")
        #expect(off.status == 200 && Set(off.json.keys) == Self.cardKeys, "\(off.text)")
        for key in ["problem", "address", "name", "router", "addressChangedAt"] { #expect(off.json[key] is NSNull, "\(key) is null while off") }
        #expect(off.json["on"] as? Bool == false && off.json["state"] as? String == "off" && off.json["port"] as? Int == 51820)
        #expect((off.json["devices"] as? [Any])?.isEmpty == true)
    }

    @Test func turningOnAnswersTheCard() async throws {
        let bridge = try await makeBridge()
        let on = await bridge.owner.send("POST", "/api/v1/away", json: ["on": true])
        #expect(on.status == 200 && on.json["on"] as? Bool == true, "\(on.text)")
        #expect(["setup", "checking"].contains(on.json["state"] as? String ?? ""), "\(on.text)")
        let secure = await bridge.owner.get("/api/v1/system/secure-address")
        #expect(secure.json["enabled"] as? Bool == true)
        let bad = await bridge.owner.send("POST", "/api/v1/away", json: ["on": "yes"])
        #expect(bad.status == 400, "\(bad.text)")
    }

    @Test func aWireGuardDeviceIsAnsweredOnce() async throws {
        let bridge = try await makeBridge()
        await bridge.turnOn()
        let added = await bridge.owner.send("POST", "/api/v1/away/devices", json: ["name": "Laptop"])
        #expect(added.status == 201 && Set(added.json.keys) == ["device", "config"], "\(added.text)")
        let device = try #require(added.json["device"] as? [String: Any])
        #expect(Set(device.keys) == ["id", "kind", "name", "lastHandshake", "lastAwayAt"] && device["kind"] as? String == "wireguard")
        let config = try #require(added.json["config"] as? String)
        #expect(config.contains("PrivateKey"))
        let card = await bridge.owner.get("/api/v1/away")
        let listed = try #require(card.json["devices"] as? [[String: Any]])
        #expect(listed.map { $0["id"] as? String } == [device["id"] as? String])
        #expect(!card.text.contains("config") && !card.text.contains("PrivateKey"))
        let nameless = await bridge.owner.send("POST", "/api/v1/away/devices", json: ["name": "  "])
        #expect(nameless.status == 400 && nameless.json["field"] as? String == "name", "\(nameless.text)")
    }

    @Test func removingADeviceOfEitherKind() async throws {
        let bridge = try await makeBridge()
        await bridge.turnOn()
        let wireGuard = try #require(await bridge.owner.send("POST", "/api/v1/away/devices", json: ["name": "Laptop"]).json["device"] as? [String: Any])
        let phone = await bridge.phone("POST", json: ["publicKey": AwayKeyPair().publicKey])
        #expect(phone.status == 200, "\(phone.text)")
        for id in [try #require(wireGuard["id"] as? String), bridge.iPhone.id] {
            let removed = await bridge.owner.send("DELETE", "/api/v1/away/devices/\(id)")
            #expect(removed.status == 204, "\(removed.text)")
            let again = await bridge.owner.send("DELETE", "/api/v1/away/devices/\(id)")
            #expect(again.status == 404 && again.json["code"] as? String == "not_found", "\(again.text)")
        }
        #expect(await eventually { peers(bridge).isEmpty })
    }

    @Test func thePhonesRoutes() async throws {
        let bridge = try await makeBridge()
        let key = AwayKeyPair().publicKey

        // Off: POST and GET are 409 away_off.
        for answer in [await bridge.phone("POST", json: ["publicKey": key]), await bridge.phone("GET")] {
            #expect(answer.status == 409 && answer.json["error"] as? String == "away_off" && answer.json["code"] as? String == "away_off", "\(answer.text)")
        }
        await bridge.turnOn()
        let set = await bridge.phone("POST", json: ["publicKey": key])
        #expect(set.status == 200 && Set(set.json.keys) == Self.tunnelKeys, "\(set.text)")
        let endpoint = try #require(set.json["endpoint"] as? [String: Any])
        #expect(Set(endpoint.keys) == ["host", "port", "addresses"])
        let again = await bridge.phone("GET")
        #expect(again.status == 200 && Set(again.json.keys) == Self.tunnelKeys && again.json["address"] as? String == set.json["address"] as? String)

        let removed = await bridge.phone("DELETE")
        #expect(removed.status == 200 && removed.json as NSDictionary == ["ok": true] as NSDictionary, "\(removed.text)")
        let gone = await bridge.phone("GET")
        #expect(gone.status == 404 && gone.json["code"] as? String == "not_set_up", "\(gone.text)")

        let bad = await bridge.phone("POST", json: ["publicKey": "abc"])
        #expect(bad.status == 400 && bad.json["code"] as? String == "bad_key", "\(bad.text)")
        for method in ["POST", "GET", "DELETE"] {
            let owner = await bridge.owner.send(method, "/api/v1/viewer/away", json: method == "POST" ? ["publicKey": key] : nil)
            #expect(owner.status == 403 && owner.json["code"] as? String == "viewer_only", "\(method): \(owner.text)")
        }
    }

    @Test func turningOffViaThePhoneAnswersWhetherAwayIsOnOrOff() async throws {
        let bridge = try await makeBridge()
        let off = await bridge.phone("DELETE")
        #expect(off.status == 200 && off.json["ok"] as? Bool == true, "\(off.text)")
    }

    @Test func withoutTheSecureAddressThePhoneIsRefused() async throws {
        let bridge = try await makeBridge(secureState: nil)
        await bridge.turnOn()
        let answer = await bridge.phone("POST", json: ["publicKey": AwayKeyPair().publicKey])
        #expect(answer.status == 409 && answer.json["code"] as? String == "secure_address_off", "\(answer.text)")
    }

    @Test func removingThePairedDeviceRemovesItsKey() async throws {
        let bridge = try await makeBridge()
        await bridge.turnOn()
        let key = AwayKeyPair().publicKey
        #expect(await bridge.phone("POST", json: ["publicKey": key]).status == 200)
        #expect(peers(bridge) == [key])

        let removed = await bridge.owner.send("DELETE", "/api/v1/viewers/\(bridge.iPhone.id)")
        #expect(removed.status == 204)
        #expect(!peers(bridge).contains(key), "the key left the system with the device")
        let card = await bridge.owner.get("/api/v1/away")
        #expect((card.json["devices"] as? [Any])?.isEmpty == true, "\(card.text)")
    }

    @Test func thePhonesTurnOffKeepsItsKeyUntilTheAnswerIsOut() async throws {
        let bridge = try await makeBridge()
        await bridge.turnOn()
        let key = AwayKeyPair().publicKey
        #expect(await bridge.phone("POST", json: ["publicKey": key]).status == 200)

        let answer = await bridge.phoneRemoval()
        #expect(answer.status == 200 && answer.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["ok"] as? Bool == true)
        let hook = try #require(answer.afterSend, "the removal waits for the answer to leave")
        // Any other change in the window still sends the key: a look, or an owner adding a device, must not drop it early.
        #expect(await bridge.owner.send("POST", "/api/v1/away/devices", json: ["name": "Laptop"]).status == 201)
        #expect(peers(bridge).contains(key), "the key stays until the answer is out")

        hook()
        #expect(await eventually { !peers(bridge).contains(key) }, "the key goes once the answer is out")
        #expect(peers(bridge).count == 1, "the other device stays")
    }

    @Test func aRemovalFromInsideTheTunnelAnswersFirstAndFromTheBrowserAppliesAtOnce() async throws {
        let bridge = try await makeBridge()
        await bridge.turnOn()
        let key = AwayKeyPair().publicKey
        #expect(await bridge.phone("POST", json: ["publicKey": key]).status == 200)
        let subnet = try #require(bridge.harness.system.awayRequests.value.last?.subnet)
        let tunnel = String(subnet.dropLast(4)) + "2"

        // The owner's own browser: applied now, and a refusal by the system is the answer.
        bridge.harness.system.awayFailure.set("The VPN couldn’t be changed.")
        let refused = await bridge.owner.send("DELETE", "/api/v1/away/devices/\(bridge.iPhone.id)")
        #expect(refused.status == 503 && refused.json["code"] as? String == "system", "\(refused.text)")
        bridge.harness.system.awayFailure.set(nil)
        let again = await bridge.phone("POST", json: ["publicKey": key])   // the refused removal stayed removed; the phone sets up again
        #expect(again.status == 200)

        // Through the tunnel: the answer first.
        let response = await bridge.harness.app.handle(bridge.harness.request("DELETE", "/api/v1/away/devices/\(bridge.iPhone.id)", cookie: bridge.owner.cookie,
                                                                                csrf: bridge.owner.csrf, from: tunnel))
        #expect(response.status == 204)
        let hook = try #require(response.afterSend)
        #expect(peers(bridge).contains(key))
        hook()
        #expect(await eventually { peers(bridge).isEmpty })

        let browser = await bridge.owner.send("DELETE", "/api/v1/away/devices/\(bridge.iPhone.id)")
        #expect(browser.status == 404)
    }

    @Test func aRemovalTheSystemRefusesShowsOnTheCardAndIsTriedAgain() async throws {
        let bridge = try await makeBridge()
        await bridge.turnOn()
        let key = AwayKeyPair().publicKey
        #expect(await bridge.phone("POST", json: ["publicKey": key]).status == 200)
        bridge.harness.system.awayFailure.set("The VPN couldn’t be changed.")

        let answer = await bridge.phoneRemoval()
        #expect(answer.status == 200)
        answer.afterSend?()
        var problem: String?
        for _ in 0..<200 where problem == nil {
            problem = await bridge.owner.get("/api/v1/away").json["problem"] as? String
            if problem == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(problem?.contains("can still connect") == true, "\(problem ?? "no problem")")
    }

    @Test func theSecureAddressStaysOnWhileAwayFromHomeIsOn() async throws {
        let bridge = try await makeBridge()
        await bridge.turnOn()
        let refused = await bridge.owner.send("POST", "/api/v1/system/secure-address/enabled", json: ["enabled": false])
        #expect(refused.status == 409 && refused.json["code"] as? String == "away_on", "\(refused.text)")
        #expect(refused.json["message"] as? String == "Away from home needs the secure address. Turn Away from home off first.")
        #expect(await bridge.owner.send("POST", "/api/v1/away", json: ["on": false]).status == 200)
        let allowed = await bridge.owner.send("POST", "/api/v1/system/secure-address/enabled", json: ["enabled": false])
        #expect(allowed.status == 200, "\(allowed.text)")
    }

    @Test func withoutTheSystemItIsUnavailable() async throws {
        let bridge = try await makeBridge(supportsAway: false)
        let card = await bridge.owner.get("/api/v1/away")
        #expect(card.status == 503 && card.json["error"] as? String == "unavailable", "\(card.text)")
        #expect(card.json["message"] as? String == "Away from home is part of Camera Bridge OS.")
    }

    @Test func everyFailureHasItsStatusAndCode() {
        let expected: [(AwayFailure, Int, String)] = [
            (.unavailable, 503, "unavailable"), (.off, 409, "away_off"), (.secureAddressOff, 409, "secure_address_off"), (.badKey, 400, "bad_key"),
            (.notSetUp, 404, "not_set_up"), (.badName, 400, "invalid"), (.tooManyDevices, 409, "too_many_devices"), (.noAddress, 409, "no_address"),
            (.notReady, 409, "not_ready"), (.noSuchDevice, 404, "not_found"), (.system("x"), 503, "system"),
        ]
        for (failure, status, code) in expected {
            let error = WebApp.awayError(failure)
            #expect(error.status == status && error.code == code, "\(failure)")
        }
        #expect(WebApp.awayError(.tooManyDevices).message == "20 devices use the WireGuard app already. Remove one first.")
    }
}
