import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// Wyze's servers, recorded: login, the device list, the refresh.
final class FakeWyzeServer: WyzeTransport, Sendable {
    let paths = Box<[String]>([])
    let answers: [String: (String, Int)]

    init(_ answers: [String: (String, Int)]) { self.answers = answers }

    func post(_ url: URL, headers: [String: String], json: Data) async throws -> (status: Int, body: Data) {
        paths.update { $0.append(url.path) }
        guard let (body, status) = answers[url.path] else { return (404, Data()) }
        return (status, Data(body.utf8))
    }
}

/// The Plugins section and the Wyze plugin: the list, signing in (the password never kept), the account's cameras with how each one
/// connects, and adding one over RTSP or the local Wyze connection.
@Suite(.timeLimit(.minutes(1))) struct WyzePluginTests {
    static let login = #"{"access_token":"ACCESS-TOKEN-AAAA","refresh_token":"REFRESH-TOKEN-RRRR","user_id":"user-42","mfa_options":null}"#
    static let mfa = #"""
    {"access_token":"","refresh_token":"","user_id":"user-42","mfa_options":["TotpVerificationCode"],
     "mfa_details":{"totp_apps":[{"app_id":"TOTP-APP-ID-9999","app_name":"Authenticator"}]},"sms_session_id":null,"email_session_id":null}
    """#
    static let devices = #"""
    {"code":"1","msg":"","data":{"device_list":[
      {"mac":"D03F27A1B2C3","enr":"ENR+/SECRET==","nickname":"Front Yard","product_model":"HL_CAM4","product_type":"Camera",
       "firmware_ver":"4.52.17.19","conn_state":1,"device_params":{"p2p_id":"P2PUID1234567890ABCD","p2p_type":4,"ip":"192.0.2.40","dtls":1}},
      {"mac":"GW0000000001","enr":"","nickname":"Living Room","product_model":"HL_PAN4","product_type":"Camera",
       "firmware_ver":"1.0.32","conn_state":1,"device_params":{}}
    ]}}
    """#

    static func server(login: String = login) -> FakeWyzeServer {
        FakeWyzeServer(["/api/user/login": (login, 200), "/app/v2/home_page/get_object_list": (devices, 200), "/user/login": (Self.login, 200),
                        "/app/user/refresh_token": (#"{"code":"1","data":{"access_token":"NEW-ACCESS","refresh_token":"NEW-REFRESH"}}"#, 200)])
    }

    static func harness(_ backend: FakeBackend = FakeBackend(), server: FakeWyzeServer = server()) throws -> Harness {
        try Harness(backend: backend) {
            $0.wyzeTransport = server
            $0.wyzeNeighborTable = { nil }   // as on a Mac: the addresses Wyze reports (the CI's Linux has a real table)
        }
    }

    nonisolated(unsafe) static let signInBody: [String: Any] = ["email": "someone@example.com", "password": "Hunter2-Secret!", "keyID": "KEYID-1", "apiKey": "APIKEY-SECRET"]

    @Test func thePluginsListShowsWyzeAndItsSwitch() async throws {
        let harness = try Self.harness()
        let session = try await harness.signIn()
        let list = await session.get("/api/v1/plugins")
        #expect(list.status == 200)
        let plugins = try #require(list.json["plugins"] as? [[String: Any]])
        #expect(plugins.compactMap { $0["id"] as? String } == ["wyze", "eufy"])
        #expect(plugins.first?["enabled"] as? Bool == false)
        let on = await session.send("PATCH", "/api/v1/plugins/wyze", json: ["enabled": true])
        #expect(on.status == 200)
        #expect(harness.backend.read { $0.settings.plugins["wyze"]?.enabled } == true)
        #expect(await session.send("PATCH", "/api/v1/plugins/nope", json: ["enabled": true]).status == 404)
    }

    @Test func signingInKeepsTheSessionButNeverThePassword() async throws {
        let backend = FakeBackend()
        let harness = try Self.harness(backend)
        let session = try await harness.signIn()
        let before = await session.get("/api/v1/plugins/wyze")
        #expect(before.json["signedIn"] as? Bool == false)
        let answer = await session.send("POST", "/api/v1/plugins/wyze/sign-in", json: Self.signInBody)
        #expect(answer.status == 200, "\(answer.text)")
        #expect(answer.json["signedIn"] as? Bool == true)
        let stored = try #require(backend.read { $0.pluginSecrets["wyze"] })
        let text = String(decoding: stored, as: UTF8.self)
        #expect(text.contains("REFRESH-TOKEN-RRRR"))
        #expect(!text.contains("Hunter2-Secret!"), "the password is used for the sign-in only")
        #expect(backend.read { $0.settings.plugins["wyze"] } .map { $0.enabled && $0.account == "someone@example.com" } == true)
        let state = await session.get("/api/v1/plugins/wyze")
        #expect(!state.text.contains("ACCESS-TOKEN") && !state.text.contains("ENR+") && !state.text.contains("P2PUID"), "no secret reaches the page")
        let out = await session.send("POST", "/api/v1/plugins/wyze/sign-out")
        #expect(out.status == 200)
        #expect(backend.read { $0.pluginSecrets["wyze"] } == nil)
    }

    @Test func twoStepVerificationAsksForTheCode() async throws {
        let harness = try Self.harness(server: Self.server(login: Self.mfa))
        let session = try await harness.signIn()
        let first = await session.send("POST", "/api/v1/plugins/wyze/sign-in", json: Self.signInBody)
        #expect(first.status == 200, "\(first.text)")
        #expect(first.json["signedIn"] as? Bool == false)
        #expect(first.json["kinds"] as? [String] == ["authenticatorApp"])
        let id = try #require(first.json["verification"] as? String)
        #expect(await session.send("POST", "/api/v1/plugins/wyze/verify", json: ["verification": id, "kind": "authenticatorApp", "code": "12"]).status == 400)
        let done = await session.send("POST", "/api/v1/plugins/wyze/verify", json: ["verification": id, "kind": "authenticatorApp", "code": "123 456"])
        #expect(done.status == 200, "\(done.text)")
        #expect(done.json["signedIn"] as? Bool == true)
        let stale = await session.send("POST", "/api/v1/plugins/wyze/verify", json: ["verification": "unknown", "kind": "authenticatorApp", "code": "123456"])
        #expect(stale.status == 422)
    }

    @Test func theCamerasSayHowEachOneConnects() async throws {
        let backend = FakeBackend()
        backend.write { $0.ports["192.0.2.40:554"] = .answers }
        let harness = try Self.harness(backend)
        let session = try await harness.signIn()
        _ = await session.send("POST", "/api/v1/plugins/wyze/sign-in", json: Self.signInBody)
        let state = await session.get("/api/v1/plugins/wyze?refresh=1")
        let cameras = try #require(state.json["cameras"] as? [[String: Any]])
        #expect(cameras.count == 2)
        let v4 = try #require(cameras.first { $0["model"] as? String == "HL_CAM4" })
        #expect(v4["rtsp"] as? String == "on")
        #expect(v4["ways"] as? [String] == ["rtsp", "local"])
        #expect(v4["address"] as? String == "192.0.2.40")
        let pan = try #require(cameras.first { $0["model"] as? String == "HL_PAN4" })
        #expect(pan["ways"] as? [String] == [], "the Pan v4's cloud helper doesn't ship yet")
        #expect((pan["note"] as? String)?.contains("doesn’t work with Camera Bridge yet") == true)

        // RTSP switched off: the page says where to turn it on, and the local connection is offered meanwhile.
        backend.write { $0.ports["192.0.2.40:554"] = .silent }
        let off = await session.get("/api/v1/plugins/wyze?refresh=1")
        let v4off = try #require((off.json["cameras"] as? [[String: Any]])?.first { $0["model"] as? String == "HL_CAM4" })
        #expect(v4off["rtsp"] as? String == "off")
        #expect(v4off["ways"] as? [String] == ["local"])
        #expect((v4off["note"] as? String)?.contains("Turn on RTSP") == true)
    }

    @Test func aCameraIsAddedOverRTSPWithBothStreams() async throws {
        let backend = FakeBackend()
        backend.write {
            $0.ports["192.0.2.40:554"] = .answers
            $0.probe = .success(CameraProbeResult(vendor: .rtsp, manufacturer: "", model: "", serialNumber: "", firmware: "", capabilities: CameraCapabilities()))
        }
        let harness = try Self.harness(backend)
        let session = try await harness.signIn()
        _ = await session.send("POST", "/api/v1/plugins/wyze/sign-in", json: Self.signInBody)
        _ = await session.get("/api/v1/plugins/wyze?refresh=1")
        let missing = await session.send("POST", "/api/v1/cameras", json: ["type": "wyzeCloud", "wyzeMAC": "D03F27A1B2C3", "wyzeWay": "rtsp", "name": "Front Yard"])
        #expect(missing.status == 400, "the RTSP password is needed")
        let answer = await session.send("POST", "/api/v1/cameras", json: ["type": "wyzeCloud", "wyzeMAC": "D03F27A1B2C3", "wyzeWay": "rtsp",
                                                                         "password": "rtsp-pass", "name": "Front Yard"])
        #expect(answer.status == 201, "\(answer.text)")
        let id = try #require(UUID(uuidString: answer.json["id"] as? String ?? ""))
        let config = try #require(backend.read { $0.configurations.first { $0.id == id } })
        #expect(config.vendor == .rtsp)
        #expect(config.username == "admin")
        #expect(config.mainStreamURL?.absoluteString == "rtsp://192.0.2.40:554/stream0")
        #expect(config.subStreamURL?.absoluteString == "rtsp://192.0.2.40:554/stream1")
        #expect(config.integration?.service == .wyze)
        #expect(config.integration?.details[IntegrationSettings.Key.wyzeMAC] == "D03F27A1B2C3")
        #expect(config.integration?.details[IntegrationSettings.Key.wyzeWay] == "rtsp")
        #expect(backend.read { $0.passwords[id] } == "rtsp-pass")
        // The plugin now shows it as added.
        let state = await session.get("/api/v1/plugins/wyze")
        let v4 = try #require((state.json["cameras"] as? [[String: Any]])?.first { $0["model"] as? String == "HL_CAM4" })
        #expect(v4["cameraID"] as? String == id.uuidString)
    }

    @Test func aCameraIsAddedOverTheLocalWyzeConnection() async throws {
        let backend = FakeBackend()
        backend.write {
            $0.integrationProbe = .success(CameraProbeResult(vendor: .go2rtc, manufacturer: "Wyze", model: "Wyze Cam v4", serialNumber: "", firmware: "",
                                                             capabilities: CameraCapabilities()))
        }
        let harness = try Self.harness(backend)
        let session = try await harness.signIn()
        _ = await session.send("POST", "/api/v1/plugins/wyze/sign-in", json: Self.signInBody)
        _ = await session.get("/api/v1/plugins/wyze?refresh=1")
        let answer = await session.send("POST", "/api/v1/cameras", json: ["type": "wyzeCloud", "wyzeMAC": "D03F27A1B2C3", "wyzeWay": "local", "name": "Front Yard"])
        #expect(answer.status == 201, "\(answer.text)")
        #expect(!answer.text.contains("ENR+") && !answer.text.contains("P2PUID"))
        let id = try #require(UUID(uuidString: answer.json["id"] as? String ?? ""))
        let config = try #require(backend.read { $0.configurations.first { $0.id == id } })
        #expect(config.vendor == .go2rtc)
        #expect(config.integration?.details[IntegrationSettings.Key.wyzeWay] == "local")
        let source = try #require(backend.read { $0.passwords[id] })
        #expect(source.hasPrefix("wyze://192.0.2.40?") && source.contains("subtype=hd"))
        // An unknown camera is refused with a sentence.
        let unknown = await session.send("POST", "/api/v1/cameras", json: ["type": "wyzeCloud", "wyzeMAC": "000000000000", "wyzeWay": "local", "name": "X"])
        #expect(unknown.status == 400)
    }

    @Test func theSweepCoversTheBridgesOwnPrivateNetworks() {
        let hosts = LocalSubnets.sweepTargets(addresses: ["192.168.77.20", "127.0.0.1", "10.42.0.1", "203.0.113.5"])
        #expect(hosts.count == 253)
        #expect(hosts.contains("192.168.77.1") && hosts.contains("192.168.77.254") && !hosts.contains("192.168.77.20"))
        #expect(LocalSubnets.isPrivate("172.20.1.2") && !LocalSubnets.isPrivate("172.32.0.1"))
    }

    @Test func pluginSettingsSurviveTheConfigurationFile() throws {
        var settings = BridgeSettings()
        settings.plugins["wyze"] = PluginState(enabled: true, account: "someone@example.com", lastSync: Date(timeIntervalSince1970: 1_800_000_000), lastError: nil)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BridgeSettings.self, from: data)
        #expect(decoded.plugins == settings.plugins)
        let older = try JSONDecoder().decode(BridgeSettings.self, from: Data(#"{"basePort":21100}"#.utf8))
        #expect(older.plugins.isEmpty)
    }

    @Test func thePanV4IsNotAddedYetButItsHelperCredentialsAreReady() async throws {
        let backend = FakeBackend()
        backend.write {
            $0.integrationProbe = .success(CameraProbeResult(vendor: .go2rtc, manufacturer: "Wyze", model: "Wyze Cam Pan v4", serialNumber: "", firmware: "",
                                                             capabilities: CameraCapabilities()))
        }
        let harness = try Self.harness(backend)
        let session = try await harness.signIn()
        _ = await session.send("POST", "/api/v1/plugins/wyze/sign-in", json: Self.signInBody)
        _ = await session.get("/api/v1/plugins/wyze?refresh=1")
        // Its helper doesn't ship yet, so it can't be added; the helper's credentials are ready for when it does.
        let answer = await session.send("POST", "/api/v1/cameras", json: ["type": "wyzeCloud", "wyzeMAC": "GW0000000001", "wyzeWay": "cloud", "name": "Pan"])
        #expect(answer.status == 400, "\(answer.text)")
        let environment = try await harness.app.wyze.helperEnvironment(WyzeHelpers.Request(kind: .cloud, mac: "GW0000000001", model: "HL_PAN4"))
        #expect(environment["CB_LAKE_ACCESS_TOKEN"] == "ACCESS-TOKEN-AAAA")
        #expect(environment["CB_LAKE_DEVICE_MAC"] == "GW0000000001" && environment["CB_LAKE_DEVICE_MODEL"] == "HL_PAN4")
        #expect(environment["CB_LAKE_PHONE_ID"]?.isEmpty == false)
        // A cloud camera can't be added over RTSP.
        let wrong = await session.send("POST", "/api/v1/cameras", json: ["type": "wyzeCloud", "wyzeMAC": "GW0000000001", "wyzeWay": "gwell", "name": "Pan 2"])
        #expect(wrong.status == 400)
    }
}
