import BridgeEngine
import CameraAdapters
import Foundation
import Synchronization
import Testing
@testable import BridgeWeb

/// A stand-in for the `eufy-bridge` helper: the sign-in steps of its fake mode (password "captcha" asks for a captcha, "code" for an emailed
/// code) and one SoloCam S220.
final class FakeEufyBridge: EufyBridgeCalling {
    struct State {
        var wanted = false
        var state = "signedOut"
        var account: String?
        var requests: [(method: String, path: String, body: [String: String])] = []
    }

    let installed: Bool
    let state = Mutex(State())

    init(installed: Bool = true) {
        self.installed = installed
    }

    func setWanted(_ on: Bool) async { state.withLock { $0.wanted = on } }
    func isInstalled() async -> Bool { installed }

    func request(_ method: String, _ path: String, body: Data?) async throws -> (status: Int, body: Data) {
        let fields = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        return try state.withLock { s in
            s.requests.append((method, path, fields))
            guard s.wanted else { throw IntegrationError("The eufy plugin is off. Turn it on in Plugins.") }
            switch (method, path) {
            case ("POST", "/sign-in"):
                s.account = fields["email"]
                s.state = fields["password"] == "captcha" ? "needsCaptcha" : fields["password"] == "code" ? "needsCode" : "signedIn"
            case ("POST", "/captcha"):
                s.state = fields["answer"] == "1234" ? "needsCode" : "needsCaptcha"
            case ("POST", "/verify"):
                if fields["code"] == "123456" { s.state = "signedIn" } else { return (400, Data(#"{"error":"That code isn’t right."}"#.utf8)) }
            case ("POST", "/sign-out"):
                s.state = "signedOut"
                s.account = nil
            case ("GET", "/devices"):
                return (200, Data(#"{"devices":[{"serial":"T8134FAKE0000001","name":"Fake SoloCam","model":"T8134","type":63,"online":true,"battery":87,"livestream":true,"codec":"h264"}]}"#.utf8))
            case ("GET", "/status"):
                break
            default:
                return (404, Data(#"{"error":"no such call"}"#.utf8))
            }
            var status: [String: Any] = ["state": s.state]
            if let account = s.account { status["account"] = account }
            if s.state == "needsCaptcha" { status["captcha"] = ["id": "c1", "image": "data:image/png;base64,AAAA"] }
            if s.state == "needsCode" { status["codeSentTo"] = "s***@example.com" }
            return (200, try JSONSerialization.data(withJSONObject: status))
        }
    }

    var lastPasswordSent: String? {
        state.withLock { $0.requests.last { $0.path == "/sign-in" }?.body["password"] }
    }
}

@Suite struct EufyPluginTests {
    static func harness(_ backend: FakeBackend = FakeBackend(), bridge: FakeEufyBridge = FakeEufyBridge()) throws -> Harness {
        try Harness(backend: backend) { $0.eufyBridge = bridge }
    }

    @Test func signingInFollowsTheCaptchaAndTheCodeAndKeepsNoPassword() async throws {
        let backend = FakeBackend()
        let bridge = FakeEufyBridge()
        let harness = try Self.harness(backend, bridge: bridge)
        let session = try await harness.signIn()
        let before = await session.get("/api/v1/plugins/eufy")
        #expect(before.status == 200 && before.json["installed"] as? Bool == true && before.json["enabled"] as? Bool == false)

        let first = await session.send("POST", "/api/v1/plugins/eufy/sign-in", json: ["email": "second@example.com", "password": "captcha", "country": "us"])
        #expect(first.status == 200 && first.json["state"] as? String == "needsCaptcha", "\(first.text)")
        #expect((first.json["captcha"] as? [String: Any])?["id"] as? String == "c1")
        #expect(backend.read { $0.settings.plugins["eufy"]?.enabled } == true, "signing in turns the plugin on")
        #expect(bridge.state.withLock { $0.wanted }, "and starts the helper")

        let code = await session.send("POST", "/api/v1/plugins/eufy/captcha", json: ["id": "c1", "answer": "1234"])
        #expect(code.json["state"] as? String == "needsCode")
        let wrong = await session.send("POST", "/api/v1/plugins/eufy/verify", json: ["code": "000000"])
        #expect(wrong.status == 422 && wrong.json["message"] as? String == "That code isn’t right.", "\(wrong.text)")
        let done = await session.send("POST", "/api/v1/plugins/eufy/verify", json: ["code": "123456"])
        #expect(done.json["state"] as? String == "signedIn")
        #expect(backend.read { $0.settings.plugins["eufy"]?.account } == "second@example.com")

        // The password went to the helper and nowhere else.
        #expect(bridge.lastPasswordSent == "captcha")
        #expect(backend.read { $0.pluginSecrets.isEmpty })
        let settings = try JSONEncoder().encode(backend.read { $0.settings })
        #expect(!String(decoding: settings, as: UTF8.self).contains("captcha"))

        let out = await session.send("POST", "/api/v1/plugins/eufy/sign-out")
        #expect(out.json["state"] as? String == "signedOut")
        #expect(backend.read { $0.settings.plugins["eufy"]?.account } == nil)
    }

    @Test func theAccountsCamerasAreListedAndAddedAsOnDemandCameras() async throws {
        let backend = FakeBackend()
        backend.write {
            $0.integrationProbe = .success(CameraProbeResult(vendor: .go2rtc, manufacturer: "eufy", model: "SoloCam S220", serialNumber: "eufy-T8134FAKE0000001",
                                                             firmware: "", capabilities: CameraCapabilities(events: [.motion, .person], snapshotAPI: true)))
        }
        let harness = try Self.harness(backend)
        let session = try await harness.signIn()
        _ = await session.send("POST", "/api/v1/plugins/eufy/sign-in", json: ["email": "second@example.com", "password": "fine", "country": "US"])
        let state = await session.get("/api/v1/plugins/eufy")
        let cameras = try #require(state.json["cameras"] as? [[String: Any]])
        let solo = try #require(cameras.first)
        #expect(solo["modelName"] as? String == "SoloCam S220" && solo["canAdd"] as? Bool == true && solo["battery"] as? Int == 87)
        #expect((solo["note"] as? String)?.contains("battery camera") == true)

        let check = await session.send("POST", "/api/v1/probe", json: ["type": "eufy", "eufySerial": "T8134FAKE0000001"])
        #expect((check.json["motionSources"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["cameraEvents"], "\(check.text)")
        let answer = await session.send("POST", "/api/v1/cameras", json: ["type": "eufy", "eufySerial": "T8134FAKE0000001", "name": "Patio Solo",
                                                                         "motionSource": "softMotion"])
        #expect(answer.status == 201, "\(answer.text)")
        let id = try #require(UUID(uuidString: answer.json["id"] as? String ?? ""))
        let config = try #require(backend.read { $0.configurations.first { $0.id == id } })
        #expect(config.vendor == .go2rtc && config.integration?.service == .eufy)
        #expect(config.integration?.details[IntegrationSettings.Key.eufySerial] == "T8134FAKE0000001")
        #expect(config.motionSource == .cameraEvents, "a camera that sleeps can't use built-in motion detection")
        let again = await session.get("/api/v1/plugins/eufy")
        #expect(((again.json["cameras"] as? [[String: Any]])?.first?["cameraID"] as? String) == id.uuidString)

        let unknown = await session.send("POST", "/api/v1/cameras", json: ["type": "eufy", "eufySerial": "T8134NOPE", "name": "Nope"])
        #expect(unknown.status == 400)
    }

    @Test func withoutTheHelperThePageSaysSo() async throws {
        let harness = try Self.harness(bridge: FakeEufyBridge(installed: false))
        let session = try await harness.signIn()
        let state = await session.get("/api/v1/plugins/eufy")
        #expect(state.json["installed"] as? Bool == false)
        let signIn = await session.send("POST", "/api/v1/plugins/eufy/sign-in", json: ["email": "second@example.com", "password": "fine"])
        #expect(signIn.status == 422)
    }
}

@Suite struct EufyModelTests {
    @Test func modelCodesAreNamed() {
        #expect(EufyModels.name(for: "T8134") == "SoloCam S220")
        #expect(EufyModels.name(for: "t8134-x") == "SoloCam S220")
        #expect(EufyModels.name(for: "T9999") == "eufy T9999")
    }

    @Test func theStreamSourceKeepsTheTokenOutOfItsDescription() {
        let source = Go2RTCSource.eufyBridge(port: 18470, token: "SECRET", serial: "T8134/../x")
        #expect(source.url == "http://127.0.0.1:18470/stream/SECRET/T8134x")
        #expect(!source.description.contains("SECRET"))
    }
}
