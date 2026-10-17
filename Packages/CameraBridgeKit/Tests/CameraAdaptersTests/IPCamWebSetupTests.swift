// A loopback fake camera of the IPCamera Web family (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// "Set up for Camera Bridge" on a camera of the IPCamera Web family: Cloud off (`mobile`), Video password (`rtsp` and `onvif` `authorized`) and
/// Extra services off (`hik` and `meari`), each read, written as the page writes it, read back and restored; other cameras are not offered
/// the new steps. Against `FakeIPCamWebCamera` only.
@Suite(.timeLimit(.minutes(1))) struct IPCamWebSetupTests {
    private func service(_ camera: FakeIPCamWebCamera, credentials: HTTPCredentials? = nil, vendor: CameraVendor = .onvif) -> CameraSettingsService {
        CameraSettingsService(endpoint: camera.endpoint, credentials: credentials ?? camera.credentials, vendor: vendor)
    }

    @Test func theMakersCloudGoesOffAndComesBack() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let service = service(camera)

        let (reading, backup) = try await service.readFeature(.cloud)
        #expect(reading == CameraSetupReading(state: .willChange, changes: [.init(label: "The maker’s cloud (VisionEye app)", now: "on", after: "off")]))
        #expect(backup == CameraFeatureBackup(path: "mobile", enabled: true))
        #expect(try await service.setFeature(.cloud, enabled: false, path: backup?.path) == CameraSetupOutcome(succeeded: true, detail: "via web API"))
        #expect(camera.writes("mobile") == ["<?xml version='1.0'?><root><mobile on='0'></mobile></root>"], "as the camera's page writes it")
        #expect(camera.reads("mobile") >= 2, "read back")
        #expect(try await service.readFeature(.cloud).0.state == .alreadyRight)
        #expect(try await service.setFeature(.cloud, enabled: false).detail == "already off", "running it again writes nothing")
        #expect(camera.writes("mobile").count == 1)

        let restored = try await service.setFeature(.cloud, enabled: true, path: backup?.path, saved: backup)
        #expect(restored == CameraSetupOutcome(succeeded: true, detail: "via web API"))
        #expect(camera.writes("mobile").last == "<?xml version='1.0'?><root><mobile on='1'></mobile></root>")
        #expect(camera.options.value["mobile"] == FakeIPCamWebCamera.options["mobile"], "as the camera had it")
    }

    @Test func theVideoNeedsThePasswordAndComesBack() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let service = service(camera)

        let (reading, backup) = try await service.readVideoPassword()
        #expect(reading == CameraSetupReading(state: .willChange, changes: [
            .init(label: "Video stream (RTSP)", now: "plays without a password", after: "needs the camera’s password"),
            .init(label: "ONVIF", now: "answers without a password", after: "needs the camera’s password"),
        ]))
        #expect(backup == CameraServiceSwitchesBackup(services: ["rtsp": ["authorized": "0"], "onvif": ["authorized": "0"]]))
        #expect(try await service.requireVideoPassword() == CameraSetupOutcome(succeeded: true, detail: "via web API"))
        let rtsp = try #require(FakeIPCamWebCamera.options["rtsp"]), onvif = try #require(FakeIPCamWebCamera.options["onvif"])
        #expect(camera.writes("rtsp") == ["<?xml version='1.0'?><root>\(rtsp.replacingOccurrences(of: #"authorized="0""#, with: #"authorized="1""#))</root>"],
                "the element as read, only authorized changed")
        #expect(camera.writes("onvif") == ["<?xml version='1.0'?><root>\(onvif.replacingOccurrences(of: #"authorized="0""#, with: #"authorized="1""#))</root>"])
        #expect(try await service.readVideoPassword().0.state == .alreadyRight, "read back")

        #expect(try await service.restoreServiceSwitches(try #require(backup)) == CameraSetupOutcome(succeeded: true, detail: "via web API"))
        #expect(camera.options.value["rtsp"] == rtsp && camera.options.value["onvif"] == onvif, "as the camera had them")
    }

    @Test func theVideoPasswordIsOfferedOnlyWithAStoredPassword() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let reading = try await service(camera, credentials: HTTPCredentials(username: "admin", password: "")).readVideoPassword()
        #expect(reading.0.state == .notOffered("Camera Bridge has no password saved for this camera, so its video can’t be locked with one"))
        #expect(reading.1 == nil && camera.writes("rtsp").isEmpty)
    }

    @Test func theExtraServicesGoOffAndComeBack() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let service = service(camera)

        let (reading, backup) = try await service.readExtraServices()
        #expect(reading == CameraSetupReading(state: .willChange, changes: [
            .init(label: "Hikvision protocol (port 8000)", now: "on", after: "off"),
            .init(label: "Meari service (port 10000)", now: "on", after: "off"),
        ]))
        #expect(backup == CameraServiceSwitchesBackup(services: ["hik": ["on": "1"], "meari": ["on": "1"]]))
        #expect(try await service.turnOffExtraServices() == CameraSetupOutcome(succeeded: true, detail: "via web API"))
        let meari = try #require(FakeIPCamWebCamera.options["meari"]), hik = try #require(FakeIPCamWebCamera.options["hik"])
        #expect(camera.writes("meari") == [#"<?xml version='1.0'?><root><meari on="0" authorized="0" port="10000"/></root>"#])
        #expect(camera.writes("hik") == ["<?xml version='1.0'?><root>\(hik.replacingOccurrences(of: #"on="1""#, with: #"on="0""#))</root>"])
        #expect(try await service.readExtraServices().0.state == .alreadyRight)

        #expect(try await service.restoreServiceSwitches(try #require(backup)).succeeded)
        #expect(camera.options.value["meari"] == meari && camera.options.value["hik"] == hik)
    }

    @Test func aCameraThatKeepsItsSettingsIsARefusal() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        camera.mode.set(.ignoreWrites)
        let service = service(camera)
        #expect(try await service.setFeature(.cloud, enabled: false) == CameraSetupOutcome(succeeded: false, detail: "the camera kept it on"))
        #expect(try await service.requireVideoPassword() == CameraSetupOutcome(succeeded: false, detail: "the camera kept its video open without a password"))
        #expect(try await service.turnOffExtraServices() == CameraSetupOutcome(succeeded: false, detail: "the camera kept the Hikvision protocol on"))
    }

    @Test func itsUPnPIsAbsent() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        #expect(try await service(camera).readFeature(.upnp).0.state == .notSupported("not supported by this camera"), "the camera has no UPnP")
    }

    @Test func otherCamerasAreNotOfferedTheNewSteps() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        for vendor in [CameraVendor.hikvision, .reolink, .amcrest] {
            let other = service(camera, vendor: vendor)
            #expect(try await other.readVideoPassword().0.state == .notOffered("not offered for this camera"))
            #expect(try await other.readExtraServices().0.state == .notOffered("not offered for this camera"))
        }
        #expect(camera.server.requests.isEmpty, "not even its web page")

        camera.mode.set(.notThisFamily)
        let onvif = service(camera)
        #expect(try await onvif.readVideoPassword().0.state == .notOffered("not offered for this camera"))
        #expect(try await onvif.readExtraServices().0.state == .notOffered("not offered for this camera"))
        #expect(camera.signIns.isEmpty)
    }

    @Test func aPageThatDoesNotAnswerIsAskedOncePerRun() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        camera.mode.set(.starting)
        let service = service(camera)
        #expect(try await service.readVideoPassword().0.state == .notOffered("not offered for this camera"))
        #expect(try await service.readExtraServices().0.state == .notOffered("not offered for this camera"))
        _ = try await service.readFeature(.cloud)
        #expect(camera.server.requests.filter { $0.path == "/" }.count == 1, "not asked again by every step")
        camera.mode.set(.normal)
        #expect(try await self.service(camera).readVideoPassword().0.state == .willChange, "the next run asks again")
    }

    @Test func aCameraThatRefusedTheSignInSaysWhy() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        _ = try await IPCamWebClient(endpoint: camera.endpoint, credentials: nil).showsItsPage()
        IPCamWebLatch.shared.trip(IPCamWebLatch.key(camera.endpoint))
        let service = service(camera)
        let paused = IPCamWebUnavailable.paused.reason
        #expect(try await service.readVideoPassword().0.state == .notSupported(paused))
        #expect(try await service.readExtraServices().0.state == .notSupported(paused))
        #expect(try await service.readFeature(.cloud).0.state == .notSupported(paused))
        #expect(try await service.setFeature(.cloud, enabled: false) == CameraSetupOutcome(succeeded: false, detail: paused))
        #expect(camera.signIns.isEmpty)
    }
}
#endif
