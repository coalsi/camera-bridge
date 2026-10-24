// Loopback fake ONVIF cameras (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// A DNS write never breaks a camera's address (`CameraSettingsService+AddressGuard.swift`; 2026-10-24: two ANNKE I91ET on DHCP came up
/// at 192.168.1.64 with DHCP off after an ONVIF `SetDNS`). Against the mock ONVIF camera only.
@Suite(.timeLimit(.minutes(1))) struct CameraDNSAddressGuardTests {
    private let credentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)
    private let bridge = "192.0.2.10"
    private let quick = DNSReadBackTiming(limit: .seconds(10), interval: .milliseconds(20))
    private let brief = DNSReadBackTiming(limit: .milliseconds(300), interval: .milliseconds(20), laterFormsLimit: .milliseconds(100))

    private func service(_ camera: MockONVIFCamera, vendor: CameraVendor = .onvif) -> CameraSettingsService {
        CameraSettingsService(endpoint: camera.endpoint, credentials: credentials, vendor: vendor)
    }

    /// The `DHCP` values of the `SetNetworkInterfaces` requests sent.
    private func dhcpWrites(_ camera: MockONVIFCamera) -> [String] {
        camera.setNetworkInterfacesBodies.value.compactMap { body in
            guard let range = body.range(of: "<tt:DHCP>"), let end = body.range(of: "</tt:DHCP>", range: range.upperBound..<body.endIndex) else { return nil }
            return String(body[range.upperBound..<end.lowerBound])
        }
    }

    // MARK: Who is Hikvision's family

    @Test func hikvisionsFamilyIsToldByItsNamesAndRealm() {
        #expect(CameraSettingsService.namesHikvisionFamily(manufacturer: "ANNKE", model: "I91ET"))
        #expect(CameraSettingsService.namesHikvisionFamily(manufacturer: "HIKVISION", model: "DS-2CD2143G2-I"))
        #expect(CameraSettingsService.namesHikvisionFamily(manufacturer: "General", model: "DS-2CD1023G0-I"), "a Hikvision model number")
        #expect(CameraSettingsService.namesHikvisionFamily(manufacturer: "HiWatch", model: "IPC-B120"))
        #expect(CameraSettingsService.namesHikvisionFamily(manufacturer: "IP Camera(K1234)", model: "Camera"))
        #expect(!CameraSettingsService.namesHikvisionFamily(manufacturer: "Reolink", model: "Reolink Video Doorbell WiFi"))
        #expect(!CameraSettingsService.namesHikvisionFamily(manufacturer: "Dahua", model: "IPC-HDW2431T"))
        #expect(CameraDrivers.isHikvisionRealm("IP Camera(K1234)"))
        #expect(CameraDrivers.isHikvisionRealm("DS-2CD2143G2-I") && CameraDrivers.isHikvisionRealm("Hikvision"))
        #expect(!CameraDrivers.isHikvisionRealm("IP Camera") && !CameraDrivers.isHikvisionRealm("Login to 4K0000000000"))
    }

    // MARK: A Hikvision-family camera on DHCP gets no SetDNS

    @Test func anAnnkeOnDHCPGetsNoSetDNS() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.deviceInformation.set(["ANNKE", "I91ET"])
        camera.dnsTurnsDHCPOff.set(true)
        let service = service(camera)

        let (reading, backup) = try await service.readInternetWatch(server: bridge, cameraAddress: "192.168.77.22", refusedBefore: true)
        #expect(reading.state == .notSupported(CameraSettingsService.hikvisionONVIFRefusal))
        #expect(reading.fixAddress == nil, "no fixed address is offered through ONVIF either")
        #expect(backup != nil)

        let outcome = try await service.applyDNS(server: bridge, readBack: quick, cameraAddress: "192.168.77.22")
        #expect(outcome == .refused(CameraSettingsService.hikvisionONVIFRefusal))
        #expect(camera.setDNSBodies.value.isEmpty, "nothing is sent")
        #expect(camera.setNetworkInterfacesBodies.value.isEmpty)
        #expect(camera.ipv4.value.dhcp && camera.dns.value == MockONVIFCamera.DNS())
    }

    @Test func aCameraWhoseHTTPPortAnswersISAPIsRealmIsHikvisionsFamily() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.otherAPI.set({ request in
            request.method == "GET" && request.path == "/ISAPI/System/deviceInfo" ? .digestChallenge(realm: "IP Camera(K1234)") : nil
        })
        let outcome = try await service(camera).applyDNS(server: bridge, readBack: quick)
        #expect(outcome == .refused(CameraSettingsService.hikvisionONVIFRefusal))
        #expect(camera.setDNSBodies.value.isEmpty)
    }

    @Test func aHikvisionWithoutISAPIsDocumentOnDHCPGetsNoSetDNSEither() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.otherAPI.set({ request in request.method == "GET" && request.path.hasPrefix("/ISAPI/") ? .status(404) : nil })
        let outcome = try await service(camera, vendor: .hikvision).applyDNS(server: bridge, readBack: quick)
        #expect(outcome == .refused(CameraSettingsService.hikvisionONVIFRefusal))
        #expect(camera.setDNSBodies.value.isEmpty)
    }

    @Test func aHikvisionFamilyCameraThatDoesNotShowItsInterfacesGetsNoSetDNS() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.deviceInformation.set(["ANNKE", "I91ET"])
        camera.interfacesOverride.set("<tds:GetNetworkInterfacesResponse/>")
        #expect(try await service(camera).applyDNS(server: bridge, readBack: quick) == .refused(CameraSettingsService.hikvisionONVIFRefusal))
        #expect(camera.setDNSBodies.value.isEmpty)
    }

    @Test func aHikvisionFamilyCameraWithAFixedAddressIsWritten() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.deviceInformation.set(["ANNKE", "I91ET"])
        camera.ipv4.set(MockONVIFCamera.IPv4(dhcp: false))
        #expect(try await service(camera).applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.dns.value.manualServers == [bridge, bridge] && !camera.ipv4.value.dhcp)
        #expect(camera.setNetworkInterfacesBodies.value.isEmpty)
    }

    // MARK: A SetDNS that turns DHCP off gets DHCP back

    @Test func aSetDNSThatTurnsDHCPOffGetsDHCPBackAndARefusal() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dnsTurnsDHCPOff.set(true)
        let outcome = try await service(camera).applyDNS(server: bridge, readBack: quick, cameraAddress: "192.168.77.22")
        #expect(outcome == .refused(CameraSettingsService.dhcpTurnedOff(back: true)))
        #expect(!outcome.succeeded && outcome.detail.contains("turned DHCP back on at once"))
        #expect(camera.ipv4.value.dhcp, "DHCP is on again")
        #expect(dhcpWrites(camera) == ["true"], "one SetNetworkInterfaces, DHCP true and no address set by hand")
        #expect(camera.setNetworkInterfacesBodies.value.first?.contains("<tt:Manual>") == false)
        #expect(camera.setDNSBodies.value.count == 1, "no other form is tried after it")
    }

    @Test func aCameraThatDoesNotTakeDHCPBackIsToldInWordsToTurnItOn() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dnsTurnsDHCPOff.set(true)
        camera.ignoreNetworkChanges.set(true)
        let outcome = try await service(camera).applyDNS(server: bridge, readBack: brief)
        #expect(outcome == .refused(CameraSettingsService.dhcpTurnedOff(back: false)))
        #expect(outcome.detail.contains("turn DHCP on"))

        camera.ignoreNetworkChanges.set(false)
        camera.ipv4.set(MockONVIFCamera.IPv4())
        camera.networkInterfacesFault.set("ActionNotSupported")
        #expect(try await service(camera).applyDNS(server: bridge, readBack: brief) == .refused(CameraSettingsService.dhcpTurnedOff(back: false)))
    }

    @Test func dhcpThatComesBackAtTheRestartIsSaid() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dnsTurnsDHCPOff.set(true)
        camera.networkRebootNeeded.set(true)
        #expect(try await service(camera).applyDNS(server: bridge, readBack: quick) == .refused(CameraSettingsService.dhcpTurnedOff(back: true, atRestart: true)))
    }

    @Test func aCameraThatHidesItsInterfacesAfterTheWriteIsRefused() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = service(camera)
        // The interfaces are read before the write; the camera then stops showing them.
        camera.otherAPI.set({ request in
            guard request.method == "POST", request.bodyText.contains("SetDNS") else { return nil }
            camera.interfacesOverride.set("<tds:GetNetworkInterfacesResponse/>")
            return nil
        })
        #expect(try await service.applyDNS(server: bridge, readBack: brief) == .refused(CameraSettingsService.dhcpUnconfirmed))
    }

    // MARK: A normal camera is unchanged

    @Test func aNormalCameraOnDHCPIsWrittenAndKeepsItsDHCP() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = service(camera)
        let backup = try #require(try await service.readDNS()).backup
        let (reading, _) = try await service.readInternetWatch(server: bridge)
        #expect(reading.state == .willChange)
        #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.dns.value.manualServers == [bridge, bridge] && camera.ipv4.value.dhcp)
        #expect(camera.setNetworkInterfacesBodies.value.isEmpty, "nothing about its address is written")
        #expect(try await service.restoreDNS(backup) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.dns.value == MockONVIFCamera.DNS() && camera.setNetworkInterfacesBodies.value.isEmpty)
    }

    // MARK: Restore

    @Test func aRestoreThatTurnsDHCPOffGetsDHCPBackAndARefusal() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        // Watched by an earlier build: the bridge set by hand, the camera on DHCP for its address.
        camera.dns.set(MockONVIFCamera.DNS(fromDHCP: false, manualServers: [bridge, bridge]))
        camera.dnsTurnsDHCPOff.set(true)
        let service = service(camera)
        await service.useDNSReadBack(quick)
        let backup = CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], searchDomains: ["domain.name"])
        #expect(try await service.restoreDNS(backup) == .refused(CameraSettingsService.dhcpTurnedOff(back: true)))
        #expect(camera.ipv4.value.dhcp && dhcpWrites(camera) == ["true"])
        #expect(camera.dns.value.fromDHCP, "the DNS write itself was made")
    }

    @Test func aRestoreOfAHikvisionFamilyCameraOnDHCPIsMadeAndItsDHCPKept() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.deviceInformation.set(["ANNKE", "I91ET"])
        camera.dns.set(MockONVIFCamera.DNS(fromDHCP: false, manualServers: [bridge, bridge]))
        let service = service(camera)
        let backup = CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], searchDomains: ["domain.name"])
        #expect(try await service.restoreDNS(backup) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.dns.value == MockONVIFCamera.DNS() && camera.ipv4.value.dhcp && camera.setNetworkInterfacesBodies.value.isEmpty)
    }
}
#endif
