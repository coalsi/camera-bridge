// Loopback fake ISAPI and ONVIF cameras (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// "Watch its internet", the setup step on the camera's side (docs/superpowers/specs/2026-10-17-internet-guard-design.md, stage 1): its
/// reading for the preview (the camera's DNS now against the bridge's address), its place among the steps and its backup. Against fakes
/// only, with documentation addresses.
@Suite(.timeLimit(.minutes(1))) struct InternetWatchStepTests {
    private let onvifCredentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)
    private let bridge = "192.168.77.2"

    /// A refused step stops the steps after it: the steps not yet tried on many cameras (the IPCamera Web family's, Watch) come after UPnP
    /// off and Cloud off, so a refusal of theirs leaves the camera's cloud as Set up for Camera Bridge always turned it off. Watch is last,
    /// so Restore (in reverse) puts the camera's DNS back first.
    @Test func theStepComesLastAfterTheCloud() throws {
        #expect(CameraSetupStepID.allCases == [.timeZone, .timeSource, .cleanPicture, .streams, .upnp, .cloud, .videoPassword, .extraServices, .internetWatch])
        #expect(CameraSetupStepID.internetWatch.rawValue == "internetWatch")
    }

    @Test func aBackupHoldsAndClearsTheWatch() throws {
        var backup = CameraSetupBackup(version: 1, created: Date(timeIntervalSince1970: 0))
        backup.internetWatch = CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], searchDomains: ["domain.name"])
        #expect(backup.holds(.internetWatch) && !backup.isEmpty)
        #expect(backup.clearing(.internetWatch).isEmpty)
        #expect(try JSONDecoder().decode(CameraSetupBackup.self, from: JSONEncoder().encode(backup)) == backup)
        let older = try JSONDecoder().decode(CameraSetupBackup.self, from: Data(#"{"version":1,"created":0}"#.utf8))
        #expect(older.internetWatch == nil, "a backup saved before the step has none")
    }

    @Test func aHikvisionsServersAreShownAgainstTheBridge() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: camera.credentials, vendor: .hikvision)

        let (reading, backup) = try await service.readInternetWatch(server: bridge)
        #expect(reading.state == .willChange)
        #expect(reading.changes == [CameraSetupChange(label: "DNS", now: "8.8.8.8 and 1.1.1.1", after: "the bridge (192.168.77.2)")])
        #expect(backup == CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: ["8.8.8.8", "1.1.1.1"]))
        #expect(camera.puts(to: HikvisionISAPI.ipAddressPath).isEmpty, "reading changes nothing")

        #expect(try await service.applyDNS(server: bridge).succeeded)
        let (again, kept) = try await service.readInternetWatch(server: bridge)
        #expect(again.state == .alreadyRight && again.changes.isEmpty)
        #expect(kept?.servers == [bridge, bridge], "the value now, which a later run does not keep over the first one's")
    }

    @Test func anONVIFCameraOnDHCPOrWithoutServersIsShownInWords() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)

        let (dhcp, backup) = try await service.readInternetWatch(server: bridge)
        #expect(dhcp.changes == [CameraSetupChange(label: "DNS", now: "1.1.1.1 and 8.8.8.8 from the router (DHCP)", after: "the bridge (192.168.77.2)")])
        #expect(backup == CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], searchDomains: ["domain.name"]))

        camera.dns.set(MockONVIFCamera.DNS(fromDHCP: true, searchDomains: [], dhcpServers: [], manualServers: []))
        #expect(try await service.readInternetWatch(server: bridge).0.changes.first?.now == "from the router (DHCP)")
        camera.dns.set(MockONVIFCamera.DNS(fromDHCP: false, searchDomains: [], dhcpServers: [], manualServers: []))
        #expect(try await service.readInternetWatch(server: bridge).0.changes.first?.now == "none set")
        camera.dns.set(MockONVIFCamera.DNS(fromDHCP: false, searchDomains: [], dhcpServers: [], manualServers: [bridge, "1.1.1.1"]))
        let (fallback, _) = try await service.readInternetWatch(server: bridge)
        #expect(fallback.state == .willChange && fallback.changes.first?.now == "192.168.77.2 and 1.1.1.1", "another server left to ask is a change")
    }

    @Test func aCameraThatDoesNotShowItsDNSCannotBeWatched() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.noDNS.set(true)
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)
        let (reading, backup) = try await service.readInternetWatch(server: bridge)
        #expect(reading.state == .notSupported("the camera does not show its DNS servers") && backup == nil)
    }
}
#endif
