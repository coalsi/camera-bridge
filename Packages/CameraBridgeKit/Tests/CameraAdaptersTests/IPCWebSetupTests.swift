// A loopback fake IP camera web API (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// "Set up for Camera Bridge" on an ONVIF camera that speaks the IP camera web API: its own labels and its maker's cloud are read, changed,
/// read back and restored through the web API (its ONVIF on-screen display answers cannot be trusted), against a fake only.
@Suite(.timeLimit(.minutes(1))) struct IPCWebSetupTests {
    final class Capture: LogSink {
        let entries = Box<[LogEntry]>([])
        func record(_ entry: LogEntry) { entries.update { $0.append(entry) } }
    }

    private func service(_ camera: FakeIPCWebCamera) -> CameraSettingsService {
        CameraSettingsService(endpoint: camera.endpoint, credentials: camera.credentials, vendor: .onvif)
    }

    @Test func theCamerasLabelsGoOffThroughTheWebAPIAndComeBack() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        let service = service(camera)

        let reading = try await service.readCleanPicture()
        #expect(reading == CameraSetupReading(state: .willChange, changes: [
            .init(label: "The camera’s own labels", now: "date and time and camera name", after: "off (the bridge draws its own)"),
        ]))
        let change = try await service.cleanPicture()
        #expect(change.succeeded && change.method == .ipcWebAPI && change.summary == "via web API")
        #expect(change.backup == CleanPictureBackup(method: .ipcWebAPI, document: "1"))
        #expect(camera.calls("setMediaVideoOverlayConfig") == [FakeIPCWebCamera.overlay(enabled: 0)], "the overlay as read, with only Enable changed")
        #expect(try await service.readCleanPicture().state == .alreadyRight, "read back: off")
        #expect(!camera.server.requests.contains { $0.path.hasPrefix("/onvif") }, "ONVIF's on-screen display is not asked")

        let restored = try await service.restorePicture(try #require(change.backup))
        #expect(restored.succeeded && restored.summary == "via web API")
        #expect(camera.state.value.overlay == FakeIPCWebCamera.overlay(enabled: 1), "exactly as the camera had it")
    }

    @Test func aCameraThatKeepsItsLabelsIsARefusal() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        camera.mode.set(.ignoreWrites)
        let change = try await service(camera).cleanPicture()
        #expect(!change.succeeded && change.summary.contains("kept its own labels"))
        #expect(camera.server.requests.allSatisfy { !$0.path.hasPrefix("/onvif") }, "no ONVIF fallback on these cameras")
    }

    @Test func theMakersCloudGoesOffAndComesBackWithItsSignIn() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        let capture = Capture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let service = service(camera)

        let (reading, backup) = try await service.readFeature(.cloud)
        #expect(reading.changes == [.init(label: "The maker’s cloud", now: "on", after: "off")])
        #expect(backup == CameraFeatureBackup(path: "getNetworkConfig", enabled: true, cloudType: "10", cloudAuthcode: FakeIPCWebCamera.authcode))
        let encoded = String(decoding: try JSONEncoder().encode(backup), as: UTF8.self)
        #expect(!encoded.contains("Ab&1") && !encoded.contains("Authcode") && !encoded.contains("cloudAuthcode"),
                "the sign-in value is never encoded (the configuration reaches the page and backup files)")
        let decoded = try JSONDecoder().decode(CameraFeatureBackup.self, from: Data(encoded.utf8))
        #expect(decoded == CameraFeatureBackup(path: "getNetworkConfig", enabled: true, cloudType: "10"))

        #expect(try await service.setFeature(.cloud, enabled: false, path: backup?.path) == CameraSetupOutcome(succeeded: true, detail: "via web API"))
        let escaped = "Ab&amp;1&lt;2&quot;x"
        #expect(camera.calls("setNetworkP2PConfig") == ["<NetworkConfig><P2PConfig Enable=\"0\" Type=\"10\" Authcode=\"\(escaped)\"/></NetworkConfig>"])
        #expect(try await service.readFeature(.cloud).0.state == .alreadyRight)
        #expect(try await service.setFeature(.cloud, enabled: false).detail == "already off", "running it again writes nothing")
        #expect(camera.calls("setNetworkP2PConfig").count == 1)

        // The camera lost its sign-in while off: the saved one goes back with the switch.
        camera.state.update { $0.p2p = #"<P2PConfig Enable="0" Type="10" Authcode=""/>"# }
        let restored = try await service.setFeature(.cloud, enabled: true, path: backup?.path, saved: backup)
        #expect(restored == CameraSetupOutcome(succeeded: true, detail: "via web API"))
        #expect(camera.state.value.p2p == FakeIPCWebCamera.p2p(enabled: 1), "the switch, kind and sign-in as they were")

        #expect(try await service.readFeature(.upnp).0.state == .notSupported("Camera Bridge can’t change this camera’s UPnP setting yet. If it has one, "
            + "block the camera’s internet in your router (see Keep this camera local)."), "no known call changes it")
        let logged = capture.entries.value.map(\.message).joined(separator: "\n")
        for secret in [FakeIPCWebCamera.authcode, escaped, "wifi-secret-value", "mail-secret-value", FakeIPCWebCamera.password,
                       IPCWebToken.make(FakeIPCWebCamera.password) ?? "-"] {
            #expect(!logged.contains(secret), "never logged")
        }
    }

    @Test func aCloudThatStaysOnIsARefusal() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        camera.mode.set(.ignoreWrites)
        #expect(try await service(camera).setFeature(.cloud, enabled: false) == CameraSetupOutcome(succeeded: false, detail: "the camera kept it on"))
    }

    @Test func aCameraWithoutTheCloudSettingHasNoCloudStep() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        camera.state.update { $0.p2p = "" }
        #expect(try await service(camera).readFeature(.cloud).0.state == .notSupported("not supported by this camera"))
    }

    @Test func otherVendorsNeverAskTheWebAPI() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        let hikvision = CameraSettingsService(endpoint: camera.endpoint, credentials: camera.credentials, vendor: .hikvision)
        #expect(try await hikvision.ipcWeb().isNone)
        let reolink = CameraSettingsService(endpoint: camera.endpoint, credentials: camera.credentials, vendor: .reolink)
        #expect(try await reolink.ipcWeb().isNone)
        #expect(camera.server.requests.isEmpty, "not even its web page")
    }

    /// The camera spoke the web API earlier in this run, and then refused a request (the night vision's, say): its clean picture and
    /// cloud steps are not possible now, and never go through ONVIF, whose on-screen display answers it gets wrong.
    @Test func aPausedWebAPIIsNeverReplacedByONVIF() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        #expect(try await service(camera).readCleanPicture().state == .willChange)
        IPCWebLatch.shared.trip(IPCWebLatch.key(camera.endpoint))
        let sent = camera.server.requests.count

        let setup = service(camera)
        let paused = IPCWebUnavailable.paused.reason
        #expect(try await setup.readCleanPicture() == .notSupported(paused))
        let change = try await setup.cleanPicture()
        #expect(!change.succeeded && change.summary == paused)
        #expect(try await setup.readFeature(.cloud).0 == .notSupported(paused))
        #expect(try await setup.setFeature(.cloud, enabled: false) == CameraSetupOutcome(succeeded: false, detail: paused))
        let restored = try await setup.restorePicture(CleanPictureBackup(method: .ipcWebAPI, document: "1"))
        #expect(!restored.succeeded && restored.summary == paused)
        #expect(camera.server.requests.count == sent, "nothing is sent: not the web API, not ONVIF")
    }

    /// A password with a character the web API cannot take: the camera's sign-in script (loaded without it) shows it is of the family, so
    /// its clean picture and cloud steps are not possible, said plainly, and never go through ONVIF's on-screen display.
    @Test func aPasswordTheAPICannotTakeIsNeverReplacedByONVIF() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        let setup = CameraSettingsService(endpoint: camera.endpoint, credentials: HTTPCredentials(username: "admin", password: "pass✓"), vendor: .onvif)
        guard case .notSupported(let why) = try await setup.readCleanPicture().state else {
            Issue.record("the clean picture is not possible")
            return
        }
        #expect(why.contains("password") && !why.contains("pass✓"), "said plainly, without the password")
        let change = try await setup.cleanPicture()
        #expect(!change.succeeded && change.summary == why)
        #expect(try await setup.readFeature(.cloud).0 == .notSupported(why))
        #expect(camera.apiRequests.isEmpty, "the password is never sent")
        #expect(!camera.server.requests.contains { $0.path.hasPrefix("/onvif") }, "ONVIF's on-screen display is not asked")
    }

    @Test func aWebAPIThatDoesNotAnswerIsNeverReplacedByONVIF() async throws {
        let camera = try await FakeIPCWebCamera.start()
        #expect(try await service(camera).readCleanPicture().state == .willChange)   // its page is known for the address
        let endpoint = camera.endpoint, credentials = camera.credentials
        camera.stop()
        defer { IPCWebLatch.shared.reset(IPCWebLatch.key(endpoint)) }
        let setup = CameraSettingsService(endpoint: endpoint, credentials: credentials, vendor: .onvif)
        let silent = IPCWebUnavailable.noAnswer.reason
        #expect(try await setup.readCleanPicture() == .notSupported(silent))
        #expect(try await setup.cleanPicture().summary == silent)
        #expect(try await setup.readFeature(.cloud).0 == .notSupported(silent))
    }
}
#endif
