import BridgeEngine
import CameraAdapters
import Foundation
import Testing
@testable import BridgeWeb

/// `GET /api/v1/viewer`: the bridge and its cameras as an Apple TV needs them, in one answer; read here with the owner's session. Every key is
/// always there, and none of it is an address, a user name, a stream URL, a setting, a token or a setup code.
@Suite(.timeLimit(.minutes(1))) struct ViewerOverviewTests {
    private static let path = "/api/v1/viewer"
    private static let secureHost = "k7f2q9.box.camera-bridge.app"
    /// 2026-11-02T14:03:07Z.
    private static let ring = Date(timeIntervalSince1970: 1_793_628_187)
    private static let cameraKeys: Set<String> = ["id", "name", "kind", "enabled", "connection", "motion", "recordingNow", "panTilt", "zoom", "sound", "main", "sub",
                                                  "lastEvent"]

    private func camera(_ name: String, kind: CameraKind = .camera, id: UUID = UUID()) -> CameraConfiguration {
        CameraConfiguration(id: id, name: name, kind: kind, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.20"), username: "admin")
    }

    /// The cameras the answer lists, in its order.
    private func listed(_ owner: Harness.Session) async throws -> [[String: Any]] {
        let answer = await owner.get(Self.path)
        #expect(answer.status == 200, "\(answer.text)")
        return try #require(answer.json["cameras"] as? [[String: Any]])
    }

    /// The one camera the answer lists.
    private func theCamera(_ owner: Harness.Session) async throws -> [String: Any] {
        let cameras = try await listed(owner)
        #expect(cameras.count == 1)
        return try #require(cameras.first)
    }

    private func isLowercaseHex(_ text: Any?, count: Int) -> Bool {
        guard let text = text as? String else { return false }
        return text.count == count && text.allSatisfy { "0123456789abcdef".contains($0) }
    }

    @Test func theAnswerHasExactlyTheSpecsKeys() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let owner = try await harness.signIn(name: "Hallway")
        #expect(await harness.send("GET", Self.path).status == 401, "nobody is told anything without signing in")

        let empty = await owner.get(Self.path)
        #expect(empty.status == 200 && empty.headers["Cache-Control"] == "no-store", "\(empty.text)")
        #expect((empty.json["cameras"] as? [Any])?.isEmpty == true, "a bridge with no cameras lists none: an empty list, not null")

        try await backend.addCamera(camera("Front Door"), password: nil)
        let answer = await owner.get(Self.path)
        #expect(answer.status == 200, "\(answer.text)")
        #expect(Set(answer.json.keys) == ["bridge", "cameras"])
        let bridge = try #require(answer.json["bridge"] as? [String: Any])
        #expect(Set(bridge.keys) == ["id", "name", "version", "secureURL"])
        let identity = await harness.app.auth.bridgeID()
        #expect(isLowercaseHex(bridge["id"], count: 32) && bridge["id"] as? String == identity, "the box's identity for life")
        #expect(bridge["name"] as? String == "Hallway" && bridge["version"] as? String == "0.1")
        #expect(bridge.keys.contains("secureURL") && bridge["secureURL"] is NSNull, "no secure address: the key is there, with null")
        let cameras = try #require(answer.json["cameras"] as? [[String: Any]])
        #expect(cameras.count == 1 && Set(cameras[0].keys) == Self.cameraKeys)
        #expect(cameras[0]["name"] as? String == "Front Door" && cameras[0]["kind"] as? String == "camera" && cameras[0]["enabled"] as? Bool == true)
    }

    @Test func camerasComeInTheOwnersOrder() async throws {
        let backend = FakeBackend()
        let (b, a, c) = (camera("B"), camera("A"), camera("C"))
        for config in [b, a, c] { try await backend.addCamera(config, password: nil) }
        let owner = try await Harness(backend: backend).signIn()

        backend.write { $0.settings.cameraOrder = [c.id, a.id] }
        let names = try await listed(owner).compactMap { $0["name"] as? String }
        #expect(names == ["C", "A", "B"], "the saved order first, the cameras it does not name after them")
        #expect(try await listed(owner).compactMap { $0["id"] as? String } == [c.id, a.id, b.id].map(\.uuidString))

        backend.write { $0.settings.cameraOrder = [] }
        #expect(try await listed(owner).compactMap { $0["name"] as? String } == ["A", "B", "C"], "no saved order: by name, as the page lists them")
    }

    @Test func eachCameraSaysWhatAViewerNeeds() async throws {
        let doorbell = camera("Front Door", kind: .doorbell)
        let backend = FakeBackend()
        try await backend.addCamera(doorbell, password: nil)
        // Apple Home is not recording (`recordingNow`), the box's own recorder is (`nvr`).
        var status = CameraStatus(id: doorbell.id, name: doorbell.name, kind: .doorbell, vendor: .hikvision, connection: .online, motionActive: true,
                                  recordingNow: false, lastEvent: "Doorbell ring", lastEventDate: Self.ring,
                                  mainStreamInfo: SourceStreamInfo(codec: "hevc", width: 2_560, height: 1_440, fps: 15), nvr: CameraArchiveStatus(state: .recording))
        status.panTilt = true
        backend.write { $0.statusOverrides[doorbell.id] = status }
        let owner = try await Harness(backend: backend).signIn()

        var front = try await theCamera(owner)
        #expect(front["id"] as? String == doorbell.id.uuidString && front["name"] as? String == "Front Door" && front["kind"] as? String == "doorbell")
        #expect(front["enabled"] as? Bool == true && front["connection"] as? String == "online" && front["motion"] as? Bool == true)
        #expect(front["recordingNow"] as? Bool == true, "the box's own recorder is writing the camera now, though Apple Home is not recording")
        #expect(front["panTilt"] as? Bool == true && front["zoom"] as? Bool == false)
        let main = try #require(front["main"] as? [String: Any])
        #expect(Set(main.keys) == ["width", "height", "codec"] && main["width"] as? Int == 2_560 && main["height"] as? Int == 1_440 && main["codec"] as? String == "hevc")
        #expect(front.keys.contains("sub") && front["sub"] is NSNull, "no sub stream was measured: the key is there, with null")
        let event = try #require(front["lastEvent"] as? [String: Any])
        #expect(Set(event.keys) == ["kind", "date"] && event["kind"] as? String == "Doorbell ring" && event["date"] as? String == "2026-11-02T14:03:07Z")

        // Both streams, zoom too, and a camera that is offline and has seen nothing.
        status.subStreamInfo = SourceStreamInfo(codec: "h264", width: 640, height: 360, fps: 15)
        status.zoom = true
        status.connection = .offline("the connection was refused")
        status.motionActive = false
        status.lastEvent = nil
        status.lastEventDate = nil
        backend.write { $0.statusOverrides[doorbell.id] = status }
        front = try await theCamera(owner)
        let sub = try #require(front["sub"] as? [String: Any])
        #expect(Set(sub.keys) == ["width", "height", "codec"] && sub["width"] as? Int == 640 && sub["height"] as? Int == 360 && sub["codec"] as? String == "h264")
        #expect(front["connection"] as? String == "offline" && front["motion"] as? Bool == false && front["zoom"] as? Bool == true)
        #expect(front.keys.contains("lastEvent") && front["lastEvent"] is NSNull, "nothing happened yet")
        status.lastEvent = "Motion"   // a kind without its time is not an event a TV can show
        backend.write { $0.statusOverrides[doorbell.id] = status }
        #expect(try await theCamera(owner)["lastEvent"] is NSNull)
        for (state, name) in [(ConnectionState.connecting, "connecting"), (.idle, "idle"), (.disabled, "disabled")] {
            status.connection = state
            backend.write { $0.statusOverrides[doorbell.id] = status }
            #expect(try await theCamera(owner)["connection"] as? String == name)
        }

        // The sound is the camera's "Camera audio" switch.
        #expect(try await theCamera(owner)["sound"] as? Bool == true)
        backend.write { $0.configurations[0].audioEnabled = false }
        #expect(try await theCamera(owner)["sound"] as? Bool == false)

        // Only the box's own recorder counts, whatever Apple Home is doing.
        status.recordingNow = true
        for notWriting in [ArchiveRecordingState.off, .waiting("waiting for the camera"), .paused(.diskFull)] {
            status.nvr = CameraArchiveStatus(state: notWriting)
            backend.write { $0.statusOverrides[doorbell.id] = status }
            #expect(try await theCamera(owner)["recordingNow"] as? Bool == false, "\(notWriting)")
        }
    }

    @Test func aStreamATVCouldNotUseIsLeftOut() async throws {
        let door = camera("Front Door")
        let backend = FakeBackend()
        try await backend.addCamera(door, password: nil)
        backend.write {
            $0.statusOverrides[door.id] = CameraStatus(id: door.id, name: door.name, kind: .camera, vendor: .hikvision, connection: .online,
                                                       mainStreamInfo: SourceStreamInfo(codec: "h264", width: 0, height: 0, fps: nil),
                                                       subStreamInfo: SourceStreamInfo(codec: "mjpeg", width: 640, height: 360, fps: 5))
        }
        let owner = try await Harness(backend: backend).signIn()
        let only = try await theCamera(owner)
        #expect(only["main"] is NSNull && only["sub"] is NSNull, "a stream with no size, or a codec the answer does not name, is as good as none")
    }

    @Test func aCameraWithoutAStatusIsIdleOrDisabled() async throws {
        let on = camera("Porch")
        var off = camera("Shed")
        off.isEnabled = false
        let backend = FakeBackend()
        for config in [on, off] { try await backend.addCamera(config, password: nil) }
        backend.write { $0.withoutStatus = [on.id, off.id] }
        let owner = try await Harness(backend: backend).signIn()

        let cameras = try await listed(owner)
        #expect(cameras.map { $0["name"] as? String } == ["Porch", "Shed"])
        #expect(cameras.map { $0["connection"] as? String } == ["idle", "disabled"], "a camera the engine has not reported yet is idle, or disabled when it is turned off")
        #expect(cameras.map { $0["enabled"] as? Bool } == [true, false])
        for entry in cameras {
            #expect(Set(entry.keys) == Self.cameraKeys)
            for key in ["motion", "recordingNow", "panTilt", "zoom"] { #expect(entry[key] as? Bool == false, "\(key)") }
            for key in ["main", "sub", "lastEvent"] { #expect(entry.keys.contains(key) && entry[key] is NSNull, "\(key)") }
            #expect(entry["sound"] as? Bool == true, "the switch is the camera's own, status or not")
        }
    }

    @Test func noAddressesUserNamesOrSecrets() async throws {
        var config = camera("Front Door", kind: .doorbell, id: UUID(uuidString: "6F3E1B2A-8C4D-4E5F-9A7B-0C1D2E3F4A5B")!)
        config.mainStreamURL = URL(string: "rtsp://192.0.2.20:554/main")
        config.subStreamURL = URL(string: "rtsp://192.0.2.20:554/sub")
        let backend = FakeBackend()
        try await backend.addCamera(config, password: "hunter2-camera")
        backend.write { state in
            state.settings.webhookEnabled = true
            state.settings.webhookToken = "webhook-0123456789abcdef"
            state.aiKey = "sk-ant-fake-key-9876543210"
            // Every sentence a status carries names the camera's address or its user.
            state.statusOverrides[config.id] = CameraStatus(
                id: config.id, name: config.name, kind: .doorbell, vendor: .hikvision, connection: .offline("Couldn’t reach 192.0.2.20"),
                videoSummary: "H.264 1920×1080 at 192.0.2.20", isPaired: false, setupCode: "12345678", setupURI: "X-HM://00GW95DQA7OSX", hapPort: 21_100,
                lastError: "Login for admin at 192.0.2.20 failed", subStreamProblem: "rtsp://192.0.2.20:554/sub is down", eventsNote: "admin@192.0.2.20",
                homeKitNote: "Home hasn’t contacted 192.0.2.20")
        }
        let harness = try Harness(backend: backend)
        let owner = try await harness.signIn()
        let monitoring = await owner.send("PATCH", "/api/v1/settings", json: ["monitorEnabled": true])
        let monitorToken = try #require(monitoring.json["monitorToken"] as? String)

        let answer = await owner.get(Self.path)
        #expect(answer.status == 200 && answer.json["cameras"] is [Any], "\(answer.text)")
        #expect(try await theCamera(owner)["connection"] as? String == "offline", "the camera is offline, and why stays with the owner")
        let secrets = ["192.0.2", "admin", "hunter2-camera", "rtsp", "webhook-0123456789abcdef", monitorToken, "sk-ant", "12345678", "123-45-678", "X-HM",
                       "00GW95DQA7OSX", owner.csrf, String(owner.cookie.dropFirst("cb_session=".count)), "correct horse"]
        for secret in secrets { #expect(!answer.text.contains(secret), "“\(secret)” is not for a TV") }
    }

    @Test func secureURLIsTheReportsURLOnlyWhenReady() {
        // The report has the address from the moment the box is registered; the certificate comes later, and only then is the address one to open.
        func report(_ state: String, url: String? = "https://\(Self.secureHost)") -> SecureAddressService.Report {
            SecureAddressService.Report(available: true, enabled: true, state: state, host: Self.secureHost, url: url, redirect: true, redirectActive: false)
        }
        #expect(WebApp.secureURL(from: report("ready")) == "https://k7f2q9.box.camera-bridge.app")
        for state in ["waiting", "off", "error"] { #expect(WebApp.secureURL(from: report(state)) == nil, "\(state)") }
        #expect(WebApp.secureURL(from: report("ready", url: nil)) == nil)
    }

    @Test func theSecureAddressIsInTheAnswerOnceItsCertificateIsReady() async throws {
        let harness = try Harness()
        let owner = try await harness.signIn()
        harness.system.certificate.set(CertificateStatus(state: "working", host: Self.secureHost))
        SecureAddressState(name: "k7f2q9", host: Self.secureHost, address: "192.0.2.10").save(to: harness.directory.url)
        // A new app reads the saved state of the secure address; the owner's session is in `auth.json`, so it is still signed in.
        let app = WebApp(configuration: WebConfiguration(dataDirectory: harness.directory.url, port: 0, loopbackOnly: true, passwordIterations: 1_000),
                         backend: harness.backend, system: harness.system, logs: harness.logs)
        func secureURL() async throws -> Any? {
            let response = await app.handle(harness.request("GET", Self.path, cookie: owner.cookie))
            let answer = Answer(status: response.status, headers: response.headers, body: response.bodyData ?? Data())
            #expect(answer.status == 200, "\(answer.text)")
            return try #require(answer.json["bridge"] as? [String: Any])["secureURL"]
        }
        #expect(try await secureURL() is NSNull, "the name is there, its certificate is still on its way")
        harness.system.certificate.set(CertificateStatus(state: "ready", host: Self.secureHost, notAfter: Date().addingTimeInterval(40 * 86_400)))
        #expect(try await secureURL() as? String == "https://k7f2q9.box.camera-bridge.app")
    }
}
