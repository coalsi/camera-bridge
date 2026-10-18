#if canImport(Darwin)
import BridgeSupport
import Foundation
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine
@testable import CameraAdapters

/// "Set up for Camera Bridge" through the engine on a camera of the IPCamera Web family (a loopback fake, never a real camera): Video password,
/// Extra services off and Cloud off are previewed, applied, saved in the one backup and put back exactly by "Restore original settings".
@MainActor @Suite(.timeLimit(.minutes(1))) struct IPCamWebSetupEngineTests {
    /// The family's page and API as the owner's camera answers them (identifiers made up). Its sign-in takes only the values of "admin" /
    /// "pa55" and of "admin" without a password: RC4 under "pwnsd" of the UPPERCASE MD5 hex of "username:password", written here as computed
    /// by Python's hashlib and an RC4 written apart from Camera Bridge's (OpenSSL's `rc4-40` agrees).
    final class FakeCamera: Sendable {
        static let encrypted = "197dfea66307c3d0e4b1858c1a6044d147c4516294c0e1107c31291707c364d6"
        static let encryptedWithoutPassword = "6e798ad26672b5a491c78bf9681445a134b0246c9fc091647b4b5b1601c211d0"
        static let options: [String: String] = [
            "mobile": #"<mobile on="1" sendalarm="1" cuid="TESTCUID000002"/>"#,
            "rtsp": #"<rtsp port="554" rtspsport="322" authorized="0" mtu="1400"/>"#,
            "onvif": #"<onvif on="1" authorized="0" companyname="A_ONVIF_CAMERA"/>"#,
            "hik": #"<hik on="1" authorized="0" port="8000" dataport="8200"/>"#,
            "meari": #"<meari on="1" authorized="0" port="10000"/>"#,
        ]

        let port: UInt16
        let options = Box(FakeCamera.options)
        let writes = Box<[String]>([])
        /// The options whose writes are answered 532374 ("No Privilege": the account may not change them).
        let refusedWrites = Box<Set<String>>([])
        private let listener: any TCPListener
        private let task = Mutex<Task<Void, Never>?>(nil)

        init() async throws {
            listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
            port = listener.port
            let task = Task { [self] in
                for await connection in listener.connections { Task { await serve(connection) } }
            }
            self.task.withLock { $0 = task }
            IPCamWebLatch.shared.reset(IPCamWebLatch.key(endpoint))
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
                for (head, _) in requests {
                    let (status, text) = answer(head)
                    let wire = HTTPSerializer.response(status: status, headers: HTTPHeaders([("Content-Type", "text/xml")]), body: Data(text.utf8))
                    guard (try? await connection.send(wire)) != nil else { return }
                }
            }
        }

        private func answer(_ head: HTTPRequestHead) -> (Int, String) {
            func query(_ name: String) -> String? { head.queryItems.first { $0.name == name }?.value }
            func root(_ body: String) -> (Int, String) { (200, "<?xml version=\"1.0\"?><root>\(body)</root>") }
            guard head.method == "GET" else { return (404, "") }   // ONVIF's POSTs: no ONVIF answers here
            switch head.path {
            case "/": return (200, #"<html><head><title>IPCamera Web</title><script src="../js/script/land.js"></script></head></html>"#)
            case "/js/script/land.js": return (200, "ajax(\"cgi/auth.cgi?act=auth&auth=123456&data=\"+d)")
            case "/cgi/auth.cgi":
                guard [Self.encrypted, Self.encryptedWithoutPassword].map({ "<?xml version='1.0'?><root><mode>1</mode><encrypt>\($0)</encrypt></root>" })
                    .contains(query("data") ?? "") else {
                    return root("<code>531201</code><error>user or password error</error>")
                }
                return root("<code>0</code><authid>S1</authid>")
            case "/cgi/network.cgi":
                guard query("auth") == "S1" else { return root("<code>532227</code><error>auth failed</error>") }
                if let what = query("get") {
                    guard let element = options.value[what] else { return root("<code>532229</code><error>no option</error>") }
                    return root(element)
                }
                guard let what = query("set"), let stored = options.value[what], let data = query("data"),
                      let element = IPCWebXML.element(what, in: data) else { return root("<code>531000</code>") }
                if refusedWrites.value.contains(what) { return root("<code>532374</code><error>No Privilege</error>") }
                writes.update { $0.append(what) }
                let written = String(element)
                let values = Dictionary(IPCWebXML.attributes(of: written).map { ($0.name, String(written[$0.value])) }, uniquingKeysWith: { $1 })
                options.update { $0[what] = IPCWebXML.replacingAttributes(values.filter { stored.contains(" \($0.key)=") }, in: stored) ?? stored }
                return root("<code>0</code>")
            default:
                return (404, "")
            }
        }
    }

    private func stored(_ fixture: EngineFixture, _ id: UUID) -> CameraConfiguration? { fixture.engine.configurations.first { $0.id == id } }

    @Test func theFamilysStepsAreAppliedSavedAndRestoredExactly() async throws {
        let fixture = try await EngineFixture()
        let camera = try await FakeCamera()
        defer { camera.stop(); fixture.directory.remove() }
        var configuration = CameraConfiguration(name: "Patio", kind: .camera, vendor: .onvif, endpoint: camera.endpoint, username: "admin")
        configuration.isEnabled = false   // no stream: only the settings are tried
        try await fixture.engine.addCamera(configuration, password: "pa55")

        let preview = try await fixture.engine.cameraSetupPreview(cameraID: configuration.id)
        let steps = Dictionary(uniqueKeysWithValues: preview.steps.map { ($0.id, $0) })
        #expect(preview.steps.map(\.id) == CameraSetupStepID.allCases)
        #expect(steps[.videoPassword]?.title == "Video password" && steps[.videoPassword]?.status == .willChange)
        #expect(steps[.extraServices]?.title == "Extra services off" && steps[.extraServices]?.changes.map(\.label)
            == ["Hikvision protocol (port 8000)", "Meari service (port 10000)"])
        #expect(steps[.cloud]?.changes == [CameraSetupChange(label: "The maker’s cloud (VisionEye app)", now: "on", after: "off")])
        #expect(steps[.upnp]?.status == .notSupported && steps[.upnp]?.detail == "not supported by this camera", "the family has no UPnP")
        #expect(camera.writes.value.isEmpty, "a preview never writes")

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(report.stoppedAt == nil)
        let applied = Dictionary(uniqueKeysWithValues: report.steps.map { ($0.id, $0.status) })
        #expect(applied[.videoPassword] == .done && applied[.extraServices] == .done && applied[.cloud] == .done)
        #expect(camera.options.value["rtsp"]?.contains(#"authorized="1""#) == true && camera.options.value["onvif"]?.contains(#"authorized="1""#) == true)
        #expect(camera.options.value["hik"]?.contains(#"on="0""#) == true && camera.options.value["meari"]?.contains(#"on="0""#) == true)
        #expect(camera.options.value["mobile"]?.contains(#"on="0""#) == true)

        let backup = try #require(stored(fixture, configuration.id)?.setupBackup)
        #expect(backup.videoPassword == CameraServiceSwitchesBackup(services: ["rtsp": ["authorized": "0"], "onvif": ["authorized": "0"]]))
        #expect(backup.extraServices == CameraServiceSwitchesBackup(services: ["hik": ["on": "1"], "meari": ["on": "1"]]))
        #expect(backup.cloud == CameraFeatureBackup(path: "mobile", enabled: true))
        let encoded = String(decoding: try JSONEncoder().encode(try #require(stored(fixture, configuration.id))), as: UTF8.self)
        for secret in ["TESTCUID000002", FakeCamera.encrypted, "pa55"] {
            #expect(!encoded.contains(secret), "never in the configuration")
        }

        let restored = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        #expect(restored.steps.map(\.id) == [.cloud, .videoPassword, .extraServices] && restored.steps.allSatisfy { $0.status == .restored })
        #expect(camera.options.value == FakeCamera.options, "every value as the camera had it")
        #expect(stored(fixture, configuration.id)?.setupBackup == nil)
    }

    /// A step whose write the camera answers 532374 ("No Privilege") once it signed Camera Bridge in is a change the account may not make
    /// (owner decision, 2026-10-18): it says to use an administrator account and stops nothing, so the steps after it still run.
    @Test func aWriteRefusedForWantOfPrivilegeStopsNoOtherStep() async throws {
        let fixture = try await EngineFixture()
        let camera = try await FakeCamera()
        defer { camera.stop(); fixture.directory.remove() }
        camera.refusedWrites.set(["mobile"])   // Cloud off, the step before Video password and Extra services off
        var configuration = CameraConfiguration(name: "Patio", kind: .camera, vendor: .onvif, endpoint: camera.endpoint, username: "admin")
        configuration.isEnabled = false
        try await fixture.engine.addCamera(configuration, password: "pa55")

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        let steps = Dictionary(uniqueKeysWithValues: report.steps.map { ($0.id, $0) })
        #expect(steps[.cloud]?.status == .refused && steps[.cloud]?.detail == CameraAdapterError.notPermittedReason)
        #expect(report.stoppedAt == nil, "a change the account may not make stops nothing")
        #expect(steps[.videoPassword]?.status == .done && steps[.extraServices]?.status == .done)
        #expect(camera.writes.value.sorted() == ["hik", "meari", "onvif", "rtsp"])
        #expect(camera.options.value["mobile"] == FakeCamera.options["mobile"])
    }

    @Test func withoutASavedPasswordTheVideoPasswordIsNotOffered() async throws {
        let fixture = try await EngineFixture()
        let camera = try await FakeCamera()
        defer { camera.stop(); fixture.directory.remove() }
        var configuration = CameraConfiguration(name: "Patio", kind: .camera, vendor: .onvif, endpoint: camera.endpoint, username: "admin")
        configuration.isEnabled = false
        try await fixture.engine.addCamera(configuration, password: nil)
        let preview = try await fixture.engine.cameraSetupPreview(cameraID: configuration.id)
        let step = try #require(preview.steps.first { $0.id == .videoPassword })
        #expect(step.status == .notOffered && step.detail == "Camera Bridge has no password saved for this camera, so its video can’t be locked with one")
    }
}
#endif
