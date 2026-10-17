#if canImport(Darwin)
import BridgeSupport
import Foundation
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine
@testable import CameraAdapters

/// "Set up for Camera Bridge" through the engine on an ONVIF camera that speaks the IP camera web API (a loopback fake, never a real
/// camera): the clean picture and cloud steps go through the web API, are saved in the one backup (the cloud's sign-in value apart from
/// it, in the secret store) and come back exactly with "Restore original settings"; the steps it has no way to do stay not supported.
@MainActor @Suite(.timeLimit(.minutes(1))) struct IPCWebSetupEngineTests {
    /// Shows the family's web page at `/` and answers the web API's form-typed POSTs; anything else (ONVIF's SOAP) reaches "its ONVIF
    /// server", which refuses it.
    final class FakeWebCamera: Sendable {
        static let authcode = #"Ab&1<2"x"#
        static let overlay = #"<Overlay Enable="1" Transparency="0" Style="3" ><TimeOverlay PosX="1" PosY="1" PosType="0" />"#
            + #"<TitleOverlay PosX="0" PosY="0" TitleUtf8="43616d657261" Title="43616d657261" /></Overlay>"#
        static let p2p = #"<P2PConfig Enable="1" Type="10" Authcode="Ab&amp;1&lt;2&quot;x"/>"#
        static let fault = "<?xml version=\"1.0\"?><SOAP-ENV:Envelope xmlns:SOAP-ENV=\"http://www.w3.org/2003/05/soap-envelope\"><SOAP-ENV:Body>"
            + "<SOAP-ENV:Fault><SOAP-ENV:Code><SOAP-ENV:Value>SOAP-ENV:Sender</SOAP-ENV:Value></SOAP-ENV:Code></SOAP-ENV:Fault></SOAP-ENV:Body></SOAP-ENV:Envelope>"

        let port: UInt16
        let overlay = Box(FakeWebCamera.overlay)
        let p2p = Box(FakeWebCamera.p2p)
        let writes = Box<[String]>([])
        private let listener: any TCPListener
        private let task = Mutex<Task<Void, Never>?>(nil)

        init() async throws {
            listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
            port = listener.port
            let task = Task { [self] in
                for await connection in listener.connections { Task { await serve(connection) } }
            }
            self.task.withLock { $0 = task }
            IPCWebLatch.shared.reset(IPCWebLatch.key(endpoint))
            ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(port)")
        }

        var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(port), onvifPort: Int(port)) }

        func stop() {
            listener.close()
            task.withLock { $0?.cancel() }
        }

        private func serve(_ connection: any TCPConnection) async {
            var parser = HTTPRequestParser(maxBodySize: 1 << 20)
            defer { connection.close() }
            while true {
                guard let data = try? await connection.receive(maximumLength: 65_536), let requests = try? parser.feed(data) else { return }
                for (head, body) in requests {
                    let (status, text) = answer(head, String(decoding: body, as: UTF8.self))
                    let wire = HTTPSerializer.response(status: status, headers: HTTPHeaders([("Content-Type", "application/xml")]), body: Data(text.utf8))
                    guard (try? await connection.send(wire)) != nil else { return }
                }
            }
        }

        private func answer(_ head: HTTPRequestHead, _ text: String) -> (Int, String) {
            if head.method == "GET", head.path == "/jsCore/rpcLogin.js" { return (200, "e=stringToHex(des(\"WebLogin\",e,1,0));sendRequest(e,s,!1,\"/ipcLogin\")") }
            guard head.method == "POST", head.headers["Content-Type"] == "application/x-www-form-urlencoded",
                  text.contains("<userid>\(IPCWebToken.make("admin") ?? "")</userid>") else { return (500, Self.fault) }
            let body = IPCWebXML.element("soap:Body", in: text).map { element -> String in
                guard let open = element.firstIndex(of: ">"), let close = element.range(of: "</", options: .backwards) else { return "" }
                return String(element[element.index(after: open)..<close.lowerBound])
            } ?? ""
            switch head.path {
            case "/getSystemVersionInfo":
                return (200, #"<?xml version="1.0"?><SystemVersionInfo><VersionInfo kernelVersion="Linux" fsVersion="TEST V1.0"/></SystemVersionInfo>"#)
            case "/getSystemControlString":
                return (200, "+gpio_input+ircut_setting+ircut_leddelay+p2p_config+")
            case "/getMediaVideoConfig":
                return (200, "<?xml version=\"1.0\"?><Video><Capture IrcutMode=\"2\"\nled_brightness_mode=\"2\"\nled_brightness_value=\"100\"></Capture>\(overlay.value)</Video>")
            case "/setMediaVideoOverlayConfig":
                writes.update { $0.append("overlay") }
                if let element = IPCWebXML.element("Overlay", in: body) { overlay.set(String(element)) }
                return (202, "")
            case "/getNetworkConfig":
                return (200, "<?xml version=\"1.0\"?><NetworkConfig><WIFIConfig Password=\"wifi-secret-value\"/>\(p2p.value)</NetworkConfig>")
            case "/setNetworkP2PConfig":
                writes.update { $0.append("cloud") }
                if let element = IPCWebXML.element("P2PConfig", in: body) { p2p.set(String(element)) }
                return (202, "")
            default:
                return (404, "")
            }
        }
    }

    private func stored(_ fixture: EngineFixture, _ id: UUID) -> CameraConfiguration? { fixture.engine.configurations.first { $0.id == id } }

    @Test func theLabelsAndTheCloudGoThroughTheWebAPIAndComeBackExactly() async throws {
        let fixture = try await EngineFixture()
        let camera = try await FakeWebCamera()
        defer { camera.stop(); fixture.directory.remove() }
        var configuration = CameraConfiguration(name: "Yard", kind: .camera, vendor: .onvif, endpoint: camera.endpoint, username: "admin")
        configuration.isEnabled = false   // no stream: only the settings are tried
        try await fixture.engine.addCamera(configuration, password: "pa55")

        let preview = try await fixture.engine.cameraSetupPreview(cameraID: configuration.id)
        let steps = Dictionary(uniqueKeysWithValues: preview.steps.map { ($0.id, $0) })
        #expect(steps[.cleanPicture]?.status == .willChange)
        #expect(steps[.cleanPicture]?.changes.first?.now == "date and time and camera name")
        #expect(steps[.cloud]?.title == "Cloud off" && steps[.cloud]?.status == .willChange)
        #expect(steps[.cloud]?.changes == [CameraSetupChange(label: "The maker’s cloud", now: "on", after: "off")])
        #expect(steps[.upnp]?.status == .notSupported, "no UPnP step on these cameras")
        #expect(camera.writes.value.isEmpty, "a preview never writes")

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(report.stoppedAt == nil)
        let applied = Dictionary(uniqueKeysWithValues: report.steps.map { ($0.id, $0) })
        #expect(applied[.cleanPicture]?.status == .done && applied[.cleanPicture]?.detail == "via web API")
        #expect(applied[.cloud]?.status == .done && applied[.cloud]?.detail == "via web API")
        #expect(camera.overlay.value == FakeWebCamera.overlay.replacingOccurrences(of: "Enable=\"1\"", with: "Enable=\"0\""))
        #expect(camera.p2p.value == FakeWebCamera.p2p.replacingOccurrences(of: "Enable=\"1\"", with: "Enable=\"0\""), "kind and sign-in kept")

        let saved = try #require(stored(fixture, configuration.id))
        let backup = try #require(saved.setupBackup)
        #expect(backup.cleanPicture == CleanPictureBackup(method: .ipcWebAPI, document: "1"))
        #expect(backup.cloud == CameraFeatureBackup(path: "getNetworkConfig", enabled: true, cloudType: "10"), "the sign-in value is kept apart")
        #expect(try fixture.engine.credentials.setupCloudAuthcode(for: configuration.id) == FakeWebCamera.authcode, "in the secret store")
        // The configuration is what the page, its events and the Mac's backup file get.
        let encoded = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        for secret in ["Ab&1<2", "Ab&amp;1", "wifi-secret-value", "pa55"] { #expect(!encoded.contains(secret), "never in the configuration") }

        // The camera lost its sign-in while the cloud was off: the kept one goes back with the switch.
        camera.p2p.set(#"<P2PConfig Enable="0" Type="10" Authcode=""/>"#)
        let restored = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        #expect(restored.steps.map(\.id) == [.cleanPicture, .cloud] && restored.steps.allSatisfy { $0.status == .restored })
        #expect(camera.overlay.value == FakeWebCamera.overlay && camera.p2p.value == FakeWebCamera.p2p, "as the camera had them")
        #expect(stored(fixture, configuration.id)?.setupBackup == nil)
        #expect(try fixture.engine.credentials.setupCloudAuthcode(for: configuration.id) == nil, "deleted once the cloud is back")
    }

    /// A secret store whose reads of the cloud's kept sign-in fail while `failsReads` is set (a locked Keychain, say).
    final class LockedSecrets: SecretStore {
        struct ReadRefused: Error {}
        let base = InMemorySecretStore()
        let failsReads = Box(false)

        func read(account: String) throws -> Data? {
            if failsReads.value, account.hasSuffix(".setup-cloud") { throw ReadRefused() }
            return try base.read(account: account)
        }

        func write(_ data: Data?, account: String) throws { try base.write(data, account: account) }
    }

    /// Restore cannot read the cloud's kept sign-in: the cloud step fails and changes nothing, and the kept value stays for the next try
    /// (it is deleted only once a restore gave it back).
    @Test func aKeptSignInThatCannotBeReadIsNotDeleted() async throws {
        let secrets = LockedSecrets()
        let fixture = try await EngineFixture(secrets: secrets)
        let camera = try await FakeWebCamera()
        defer { camera.stop(); fixture.directory.remove() }
        var configuration = CameraConfiguration(name: "Yard", kind: .camera, vendor: .onvif, endpoint: camera.endpoint, username: "admin")
        configuration.isEnabled = false
        try await fixture.engine.addCamera(configuration, password: "pa55")
        #expect(try await fixture.engine.applyCameraSetup(cameraID: configuration.id).stoppedAt == nil)
        let lost = #"<P2PConfig Enable="0" Type="10" Authcode=""/>"#
        camera.p2p.set(lost)   // the camera lost its sign-in while the cloud was off
        let account = CredentialStore.setupCloudAccount(for: configuration.id)

        secrets.failsReads.set(true)
        let refused = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        let cloud = try #require(refused.steps.first { $0.id == .cloud })
        #expect(cloud.status == .refused && cloud.detail?.contains("sign-in") == true, "said plainly")
        #expect(camera.p2p.value == lost, "the cloud is not turned on without its sign-in")
        #expect(try secrets.base.read(account: account) != nil, "kept, not deleted")
        #expect(stored(fixture, configuration.id)?.setupBackup?.cloud != nil && refused.canRestore, "Restore can be tried again")

        secrets.failsReads.set(false)
        let restored = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        #expect(restored.steps.map(\.id) == [.cloud] && restored.steps.allSatisfy { $0.status == .restored })
        #expect(camera.p2p.value == FakeWebCamera.p2p, "with the kept sign-in")
        #expect(try secrets.base.read(account: account) == nil, "deleted once the cloud is back")
    }

    @Test func removingTheCameraDeletesTheKeptSignIn() async throws {
        let fixture = try await EngineFixture()
        defer { fixture.directory.remove() }
        let id = UUID()
        try fixture.engine.credentials.setSetupCloudAuthcode(FakeWebCamera.authcode, for: id)
        try fixture.engine.credentials.forgetCamera(id, dataDirectory: fixture.directory.url)
        #expect(try fixture.engine.credentials.setupCloudAuthcode(for: id) == nil)
    }
}
#endif
