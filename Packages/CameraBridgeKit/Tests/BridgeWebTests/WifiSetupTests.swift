import BridgeSupport
import Foundation
import Testing
@testable import BridgeWeb

/// The setup hotspot (setup.html and `setup/wifi`), the captive-portal redirect and the System page's Wi-Fi routes.
@Suite struct WifiSetupTests {
    static let hotspot = SetupHotspot(ssid: "CameraBridge-1A2B", address: "10.42.0.1")
    static let origin = "http://camera-bridge.local"

    @Test func aPhonesCaptivePortalCheckIsSentToTheSetupPageOnlyWhileTheHotspotIsOpen() async throws {
        let harness = try Harness()
        let before = await harness.send("GET", "/hotspot-detect.html", headers: [("Host", "captive.apple.com")])
        #expect(before.status == 421, "without the hotspot an unknown name is refused, as before")
        harness.system.hotspot.set(Self.hotspot)
        for host in ["captive.apple.com", "connectivitycheck.gstatic.com", "www.msftconnecttest.com"] {
            let answer = await harness.send("GET", "/generate_204", headers: [("Host", host)])
            #expect(answer.status == 302 && answer.headers["Location"] == "http://10.42.0.1/setup.html", "\(host)")
        }
        #expect(await harness.send("GET", "/api/v1/status", headers: [("Host", "10.42.0.1")]).status == 200, "the box's own address works as always")
    }

    @Test func theSetupRoutesAnswerOnlyWhileTheHotspotIsOpen() async throws {
        let harness = try Harness()
        let closed = await harness.send("GET", "/api/v1/setup/wifi")
        #expect(closed.status == 409)
        #expect(await harness.send("POST", "/api/v1/setup/wifi", json: ["ssid": "Home", "password": "12345678"], origin: Self.origin).status == 409)
        harness.system.hotspot.set(Self.hotspot)
        let open = await harness.send("GET", "/api/v1/setup/wifi")
        #expect(open.status == 200)
        #expect((open.json["networks"] as? [[String: Any]])?.first?["ssid"] as? String == "Home")
        #expect(open.json["needsAdminPassword"] as? Bool == false && (open.json["hotspot"] as? [String: Any])?["ssid"] as? String == "CameraBridge-1A2B")
        #expect(open.json["lastError"] as? String == "Couldn’t join “Home”.")
        #expect(await harness.send("POST", "/api/v1/setup/wifi", json: ["ssid": "Home", "password": "short"], origin: Self.origin).status == 400)
        #expect(await harness.send("POST", "/api/v1/setup/wifi", json: ["password": "12345678"], origin: Self.origin).status == 400)
        #expect(harness.system.calls.value.isEmpty)
        #expect(await harness.send("POST", "/api/v1/setup/wifi", json: ["ssid": "Home", "password": "12345678"], origin: Self.origin).status == 202)
        #expect(await harness.send("POST", "/api/v1/setup/wifi", json: ["ssid": "Cafe", "password": ""], origin: Self.origin).status == 202, "an open network")
        #expect(harness.system.calls.value == ["wifi:Home:8:true", "wifi:Cafe:0:true"])
        #expect(await harness.send("POST", "/api/v1/setup/wifi", json: ["ssid": "Home", "password": "12345678"], origin: "http://evil.example").status == 403,
                "another site cannot change the network")
    }

    @Test func onceTheBridgeIsSetUpTheHotspotAsksForItsPassword() async throws {
        let harness = try Harness()
        _ = try await harness.signIn(password: "correct horse")
        harness.system.hotspot.set(Self.hotspot)
        #expect(await harness.send("GET", "/api/v1/setup/wifi").json["needsAdminPassword"] as? Bool == true)
        let wrong = await harness.send("POST", "/api/v1/setup/wifi", json: ["ssid": "Home", "password": "12345678", "adminPassword": "nope"], origin: Self.origin)
        #expect(wrong.status == 401 && wrong.json["field"] as? String == "adminPassword")
        #expect(await harness.send("POST", "/api/v1/setup/wifi", json: ["ssid": "Home", "password": "12345678"], origin: Self.origin).status == 401)
        #expect(harness.system.calls.value.isEmpty)
        let right = await harness.send("POST", "/api/v1/setup/wifi", json: ["ssid": "Home", "password": "12345678", "adminPassword": "correct horse"], origin: Self.origin)
        #expect(right.status == 202 && harness.system.calls.value == ["wifi:Home:8:true"])
    }

    @Test func theSystemPagesWifiRoutesNeedASession() async throws {
        let harness = try Harness()
        #expect(await harness.send("GET", "/api/v1/system/wifi").status == 403, "nothing before the password exists")
        let session = try await harness.signIn()
        let report = await session.get("/api/v1/system/wifi")
        #expect(report.status == 200 && report.json["ssid"] as? String == "Home" && report.json["state"] as? String == "online")
        let scan = await session.send("POST", "/api/v1/system/wifi/scan", json: [:])
        #expect((scan.json["networks"] as? [[String: Any]])?.count == 2)
        #expect(await session.send("POST", "/api/v1/system/wifi", json: ["ssid": "Cafe", "password": ""]).status == 202)
        #expect(await session.send("POST", "/api/v1/system/wifi/forget", json: ["ssid": "Home"]).status == 204)
        #expect(harness.system.calls.value == ["wifi:Cafe:0:true", "wifi-forget:Home"])
    }
}
