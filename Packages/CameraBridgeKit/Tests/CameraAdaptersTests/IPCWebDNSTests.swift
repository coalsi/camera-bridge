// Loopback fake ONVIF and IP camera web API cameras (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// The internet guard's Watch on an ONVIF camera that speaks the IP camera web API (Jennov "Backyard PTZ", JM800S5): its DNS servers are
/// read, set, read back and restored through the camera's own network settings (`getNetworkConfig`'s `LANConfig`, written back whole with
/// `setNetworkLANConfig` and only `DNS1` and `DNS2` changed), because its ONVIF reports DNS changes it does not keep. ONVIF stays the way for
/// a camera that does not speak that API. Against fakes only, with documentation addresses.
@Suite(.timeLimit(.minutes(1))) struct IPCWebDNSTests {
    private let bridge = "192.0.2.10"
    /// The read-back after a restart, short for the fakes (a camera gets 30 s).
    private let quick = DNSReadBackTiming(limit: .seconds(10), interval: .milliseconds(20))

    final class Capture: LogSink {
        let entries = Box<[LogEntry]>([])
        func record(_ entry: LogEntry) { entries.update { $0.append(entry) } }
        var text: String { entries.value.map(\.message).joined(separator: "\n") }
    }

    /// A camera of the family as the owner's is: its ONVIF beside its web API, and that ONVIF says the DNS is set by hand to 1.1.1.1 (what
    /// it reports, not what the camera keeps); its web API's `LANConfig` static, with 8.8.8.8 and 1.1.1.1.
    private struct Family {
        let onvif: MockONVIFCamera
        let web: FakeIPCWebCamera
        var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(web.server.port), onvifPort: Int(onvif.server.port)) }

        static func start() async throws -> Family {
            let onvif = try await MockONVIFCamera.start()
            onvif.openONVIF.set(true)
            onvif.dns.set(MockONVIFCamera.DNS(fromDHCP: false, searchDomains: [], dhcpServers: [], manualServers: ["1.1.1.1"]))
            let web = try await FakeIPCWebCamera.start()
            let family = Family(onvif: onvif, web: web)
            family.reset()
            return family
        }

        func service() -> CameraSettingsService { CameraSettingsService(endpoint: endpoint, credentials: web.credentials, vendor: .onvif) }

        func reset() {
            for key in IPCWebClient.loginKeys(endpoint) { ONVIFLoginGuard.shared.clear(host: key) }
            IPCWebLatch.shared.reset(IPCWebLatch.key(endpoint))
        }

        func stop() {
            onvif.stop()
            web.stop()
            reset()
        }

        var writes: [String] { web.calls(CameraSettingsService.ipcLANWrite) }
    }

    private var original: CameraDNSBackup {
        CameraDNSBackup(method: .ipcWebAPI, fromDHCP: false, servers: ["8.8.8.8", "1.1.1.1"],
                        ipcWebAPI: ["DHCP": "0", "DNS1": "8.8.8.8", "DNS2": "1.1.1.1"])
    }

    private func done(_ via: String = "via web API") -> CameraSetupOutcome { CameraSetupOutcome(succeeded: true, detail: via) }

    // MARK: Reading

    /// The guard's reading and the security check read what the camera keeps (its web API), not what its ONVIF reports.
    @Test func theDNSIsReadThroughTheWebAPINotONVIF() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        let reading = try #require(try await camera.service().readDNS())
        #expect(reading == CameraDNSReading(servers: ["8.8.8.8", "1.1.1.1"], fromDHCP: false, method: .ipcWebAPI, backup: original))
        #expect(!camera.onvif.actions.value.contains("GetDNS"), "its ONVIF is not asked")

        // Its ONVIF says the bridge (a change it reported and dropped): the camera does not ask the bridge.
        camera.onvif.dns.update { $0.manualServers = [bridge] }
        #expect(try await camera.service().readDNS()?.pointsAt(bridge) == false)

        // On DHCP the page shows the servers the camera has now: from DHCP, each once, an empty slot no server.
        camera.web.state.update { $0.lan = FakeIPCWebCamera.lan(dhcp: 1, dns1: "192.0.2.1", dns2: "0.0.0.0") }
        let dhcp = try #require(try await camera.service().readDNS())
        #expect(dhcp.servers == ["192.0.2.1"] && dhcp.fromDHCP && dhcp.method == .ipcWebAPI)
        #expect(dhcp.backup.ipcWebAPI == ["DHCP": "1", "DNS1": "192.0.2.1", "DNS2": "0.0.0.0"])
    }

    /// The reading carries the camera's address whole, its hardware address too, as `LANConfig` shows it ("Change it by hand" says to keep
    /// it and reserve it); none when `LANConfig` does not show it whole (here, a gateway off its network).
    @Test func theReadingCarriesTheAddressLANConfigShows() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        #expect(try await camera.service().readDNS()?.addressing == nil, "127.0.0.1 with the gateway 192.0.2.1: not whole")
        camera.web.state.update { $0.lan = FakeIPCWebCamera.lan(dhcp: 1, ip: "192.0.2.20", gateway: "192.0.2.1") }
        #expect(try await camera.service().readDNS()?.addressing
                == CameraAddressing(address: "192.0.2.20", subnetMask: "255.255.255.0", gateway: "192.0.2.1", hardwareAddress: FakeIPCWebCamera.hardwareAddress))
    }

    // MARK: Watch and Restore

    /// Watch writes the camera's `LANConfig` back as it was read with only its two DNS servers changed, waits while the camera restarts
    /// its network service (no answer meanwhile is no refusal), and reads it back through the web API; Restore writes the old servers back
    /// the same way. ONVIF is never written to, and nothing of the network settings reaches the log.
    @Test func watchSetsBothServersThroughTheWebAPIAndRestoreGivesThemBack() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        camera.web.restartAfterLANWrite.set(3)
        let capture = Capture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let service = camera.service()

        let (reading, backup) = try await service.readInternetWatch(server: bridge)
        #expect(reading == CameraSetupReading(state: .willChange, changes: [.init(label: "DNS", now: "8.8.8.8 and 1.1.1.1", after: "the bridge (\(bridge))")]))
        let saved = try #require(backup)
        #expect(saved == original, "the camera's own values, kept for Restore")
        #expect(camera.writes.isEmpty, "reading changes nothing")

        #expect(try await service.applyDNS(server: bridge, readBack: quick) == done())
        #expect(camera.writes == [FakeIPCWebCamera.lan(dns1: bridge, dns2: bridge)], "LANConfig as the camera wrote it, only DNS1 and DNS2 changed")
        #expect(camera.web.dropped.value > 0, "the camera restarted its network after the write")
        #expect(!IPCWebLatch.shared.isTripped(IPCWebLatch.key(camera.endpoint)), "no answer while it restarts is no refusal")
        #expect(camera.onvif.setDNSBodies.value.isEmpty, "ONVIF is not written to")
        #expect(try await service.readDNS()?.pointsAt(bridge) == true)
        #expect(try await service.readInternetWatch(server: bridge).0.state == .alreadyRight)
        #expect(try await service.applyDNS(server: bridge, readBack: quick) == done(), "running it again writes nothing")
        #expect(camera.writes.count == 1)

        #expect(try await service.restoreDNS(saved, readBack: quick) == done())
        #expect(camera.writes.count == 2)
        #expect(camera.web.state.value.lan == FakeIPCWebCamera.lan(), "exactly as the camera had it")
        #expect(camera.onvif.setDNSBodies.value.isEmpty)
        for text in [FakeIPCWebCamera.hardwareAddress, "TESTCAM", "255.255.255.0", "1460", "wifi-secret-value", "mail-secret-value", FakeIPCWebCamera.password,
                     IPCWebToken.make(FakeIPCWebCamera.password) ?? "-"] {
            #expect(!capture.text.contains(text), "the network settings and the sign-in are never logged")
        }
    }

    /// The camera restarted its network before it answered the write: the write is no refusal, and the read-back tells.
    @Test func aWriteTheCameraDidNotAnswerIsReadBack() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        camera.web.dropLANWriteAnswer.set(true)
        camera.web.restartAfterLANWrite.set(2)
        #expect(try await camera.service().applyDNS(server: bridge, readBack: quick) == done())
        #expect(!camera.writes.isEmpty && camera.writes.allSatisfy { $0 == FakeIPCWebCamera.lan(dns1: bridge, dns2: bridge) })
        #expect(!IPCWebLatch.shared.isTripped(IPCWebLatch.key(camera.endpoint)))
    }

    /// A camera that takes the write but keeps its servers is refused once the wait is over, saying what it kept.
    @Test func aCameraThatKeepsItsServersIsRefused() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        camera.web.mode.set(.ignoreWrites)
        let outcome = try await camera.service().applyDNS(server: bridge, readBack: DNSReadBackTiming(limit: .milliseconds(300), interval: .milliseconds(20)))
        #expect(outcome == CameraSetupOutcome(succeeded: false, detail: "the camera kept its own DNS servers"))
        #expect(camera.writes.count == 1)
        #expect(camera.onvif.setDNSBodies.value.isEmpty, "no ONVIF fallback: its ONVIF reports changes it does not keep")
    }

    // MARK: Refusals

    /// The camera's page sets DNS servers only in Mode Static (its DNS fields are disabled on DHCP): a camera on DHCP is refused, saying
    /// where to change it, and its mode is never switched (that would fix its address). One whose router hands out the bridge is right.
    @Test func aCameraOnDHCPIsRefusedNotSwitched() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        camera.web.state.update { $0.lan = FakeIPCWebCamera.lan(dhcp: 1) }
        let service = camera.service()
        let words = CameraSettingsService.ipcWebDHCPRefusal
        #expect(words.contains("DHCP") && words.contains("Network › Basic") && words.contains("TCP/IP") && words.contains("Mode Static"))

        let (reading, backup) = try await service.readInternetWatch(server: bridge)
        #expect(reading == .notSupported(words), "not offered as a change it would refuse")
        #expect(backup?.fromDHCP == true)
        #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: false, detail: words))
        #expect(camera.writes.isEmpty && camera.onvif.setDNSBodies.value.isEmpty, "nothing is written, not through ONVIF either")

        camera.web.state.update { $0.lan = FakeIPCWebCamera.lan(dhcp: 1, dns1: bridge, dns2: bridge) }
        #expect(try await service.readInternetWatch(server: bridge).0 == CameraSetupReading(state: .alreadyRight, note: CameraSettingsService.dnsFromRouterNote))
        #expect(try await service.applyDNS(server: bridge, readBack: quick) == done())
        #expect(camera.writes.isEmpty)
    }

    /// Network settings that would not go back exactly (an attribute the page writes is missing or twice, an address that is not the one
    /// Camera Bridge reaches the camera at), and an IPv6 bridge address, are refused rather than written.
    @Test func networkSettingsThatWouldNotGoBackExactlyAreLeftAlone() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        let service = camera.service()
        for lan in [FakeIPCWebCamera.lan().replacingOccurrences(of: "\nMTU=\"1460\"", with: ""),
                    FakeIPCWebCamera.lan().replacingOccurrences(of: "ALLNET=\"0\"", with: "ALLNET=\"0\"\nALLNET=\"1\""),
                    FakeIPCWebCamera.lan(ip: "192.0.2.20")] {
            camera.web.state.update { $0.lan = lan }
            #expect(try await service.applyDNS(server: bridge, readBack: quick)
                    == CameraSetupOutcome(succeeded: false, detail: CameraSettingsService.ipcWebLANLeftAlone), "\(lan)")
        }
        camera.web.state.update { $0.lan = FakeIPCWebCamera.lan() }
        #expect(try await service.applyDNS(server: "2001:db8::10", readBack: quick)
                == CameraSetupOutcome(succeeded: false, detail: CameraSettingsService.dnsIPv4Only))
        #expect(camera.writes.isEmpty && camera.onvif.setDNSBodies.value.isEmpty)
    }

    /// A camera of the family whose web API cannot be asked now (paused after a refusal) is not read or written through ONVIF, whose DNS
    /// answers it gets wrong: each says why, and nothing is sent.
    @Test func aWebAPIThatCannotBeAskedIsNeverReplacedByONVIF() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        #expect(try await camera.service().readDNS()?.method == .ipcWebAPI)   // its page is known for the address
        IPCWebLatch.shared.trip(IPCWebLatch.key(camera.endpoint))
        let webSent = camera.web.server.requests.count, onvifSent = camera.onvif.server.requests.count

        let service = camera.service()
        let paused = IPCWebUnavailable.paused
        await #expect(throws: paused) { try await service.readDNS() }
        let (reading, backup) = try await service.readInternetWatch(server: bridge)
        #expect(reading == .notSupported(paused.reason) && backup == nil)
        #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: false, detail: paused.reason))
        #expect(try await service.restoreDNS(original, readBack: quick) == CameraSetupOutcome(succeeded: false, detail: paused.reason))
        #expect(camera.web.server.requests.count == webSent && camera.onvif.server.requests.count == onvifSent, "nothing is sent")
    }

    // MARK: ONVIF stays the way without the web API

    /// An ONVIF camera that does not speak the web API, and one whose web API shows no `LANConfig`, go through ONVIF as before.
    @Test func withoutTheWebAPIONVIFStaysTheWay() async throws {
        let plain = try await MockONVIFCamera.start()
        defer { plain.stop() }
        let other = CameraSettingsService(endpoint: plain.endpoint, credentials: HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password),
                                          vendor: .onvif)
        #expect(try await other.readDNS()?.method == .onvifMinimal)
        #expect(try await other.applyDNS(server: bridge, readBack: quick) == done("via ONVIF"))

        let camera = try await Family.start()
        defer { camera.stop() }
        camera.web.state.update { $0.lan = nil }
        let service = camera.service()
        let reading = try #require(try await service.readDNS())
        #expect(reading.method == .onvifMinimal && reading.servers == ["1.1.1.1"])
        #expect(try await service.applyDNS(server: bridge, readBack: quick) == done("via ONVIF"))
        #expect(camera.writes.isEmpty)
        // A backup read through the web API goes back through ONVIF when the web API no longer shows its network settings.
        #expect(try await service.restoreDNS(original, readBack: quick) == done("via ONVIF"))
        #expect(camera.onvif.dns.value.manualServers == ["8.8.8.8", "1.1.1.1"] && !camera.onvif.dns.value.fromDHCP)
    }

    // MARK: Backups

    /// A backup an earlier build saved through ONVIF (the one server its ONVIF showed) is put back through the web API, the server in both
    /// slots, when the camera is on Mode Static (Watch may have written it there since); nothing is written when the camera already asks
    /// that server; on DHCP (where Watch never writes through the page) it goes back through ONVIF, as that build wrote it.
    @Test func anOlderONVIFBackupGoesBackThroughTheWebAPI() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        let service = camera.service()
        #expect(try await service.applyDNS(server: bridge, readBack: quick) == done())
        let older = CameraDNSBackup(method: .onvifMinimal, fromDHCP: false, servers: ["1.1.1.1"], searchDomains: [])

        #expect(try await service.restoreDNS(older, readBack: quick) == done())
        #expect(camera.web.state.value.lan == FakeIPCWebCamera.lan(dns1: "1.1.1.1", dns2: "1.1.1.1"))
        #expect(camera.writes.count == 2 && camera.onvif.setDNSBodies.value.isEmpty)
        #expect(try await service.restoreDNS(older, readBack: quick) == done(), "already as it was")
        #expect(camera.writes.count == 2)

        camera.web.state.update { $0.lan = FakeIPCWebCamera.lan(dhcp: 1) }
        #expect(try await service.restoreDNS(older, readBack: quick) == done("via ONVIF"))
        #expect(camera.writes.count == 2 && camera.onvif.setDNSBodies.value.count == 1)
    }

    /// A camera switched to DHCP since Watch: its page cannot take DNS servers, so Restore says so and writes nothing.
    @Test func aCameraSwitchedToDHCPSinceWatchIsNotWritten() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        let service = camera.service()
        #expect(try await service.applyDNS(server: bridge, readBack: quick) == done())
        camera.web.state.update { $0.lan = FakeIPCWebCamera.lan(dhcp: 1, dns1: bridge, dns2: bridge) }
        #expect(try await service.restoreDNS(original, readBack: quick)
                == CameraSetupOutcome(succeeded: false, detail: CameraSettingsService.ipcWebRestoreOnDHCP))
        #expect(camera.writes.count == 1 && camera.onvif.setDNSBodies.value.isEmpty)
    }

    @Test func theBackupDecodesWithoutTheWebAPIValues() throws {
        let encoded = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(CameraDNSBackup.self, from: encoded) == original)
        let older = #"{"method":"onvifMinimal","fromDHCP":false,"servers":["1.1.1.1"]}"#
        #expect(try JSONDecoder().decode(CameraDNSBackup.self, from: Data(older.utf8)).ipcWebAPI == nil, "a backup saved before has none")
    }

    // MARK: Fix its address so the DNS stays (opt-in)

    /// The fake's own address on DHCP (it is reached at its own address, as a camera is), as the choice keeps it, with a gateway and the
    /// bridge on its network.
    private let keeps = CameraAddressing(address: "127.0.0.1", subnetMask: "255.255.255.0", gateway: "127.0.0.254")
    private let local = "127.0.0.2"
    private func onDHCP(netmask: String = "255.255.255.0", gateway: String = "127.0.0.254", mac: String = FakeIPCWebCamera.hardwareAddress) -> String {
        FakeIPCWebCamera.lan(dhcp: 1, netmask: netmask, gateway: gateway, mac: mac)
    }

    /// A camera of the family on DHCP (its page takes DNS servers only in Mode Static) is offered "Fix its address so the DNS stays", keeping
    /// its address, mask and gateway as `LANConfig` shows them, with its hardware address; one in Mode Static is written as it is. The
    /// reading writes nothing.
    @Test func theChoiceIsOfferedOnlyWhereDNSNeedsAFixedAddress() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        camera.web.state.update { $0.lan = onDHCP() }
        let service = camera.service()
        let (reading, backup) = try await service.readInternetWatch(server: local, cameraAddress: "127.0.0.1")
        #expect(reading.state == .notSupported(CameraSettingsService.ipcWebDHCPRefusal), "without the choice nothing is written")
        var offered = keeps
        offered.hardwareAddress = FakeIPCWebCamera.hardwareAddress
        #expect(reading.fixAddress == CameraSetupFixAddress(addressing: offered, changes: [
            CameraSetupChange(label: "Address", now: "127.0.0.1 from the router (DHCP)", after: "127.0.0.1, fixed (mask 255.255.255.0, gateway 127.0.0.254)"),
            CameraSetupChange(label: "DNS", now: "8.8.8.8 and 1.1.1.1 from the router (DHCP)", after: "the bridge (\(local))"),
        ], method: .ipcWebAPI))
        #expect(backup?.fixedAddress == nil)
        #expect(try await service.readInternetWatch(server: local, cameraAddress: "192.0.2.20").0.fixAddress == nil, "another address")

        camera.web.state.update { $0.lan = FakeIPCWebCamera.lan(gateway: "127.0.0.254") }
        #expect(try await service.readInternetWatch(server: local, cameraAddress: "127.0.0.1").0.fixAddress == nil, "Mode Static")
        #expect(camera.writes.isEmpty && camera.onvif.setNetworkInterfacesBodies.value.isEmpty)
    }

    /// No offer without the whole address: a mask that is not one, no gateway, a gateway on another network; a hardware address it does not
    /// show is left out.
    @Test func theChoiceNeedsTheWholeAddress() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        let service = camera.service()
        for lan in [onDHCP(netmask: "0.255.255.0"), onDHCP(gateway: "0.0.0.0"), onDHCP(gateway: ""), onDHCP(gateway: "192.0.2.1")] {
            camera.web.state.update { $0.lan = lan }
            #expect(try await service.readInternetWatch(server: local, cameraAddress: "127.0.0.1").0.fixAddress == nil, "\(lan)")
        }
        camera.web.state.update { $0.lan = onDHCP(mac: "") }
        #expect(try await service.readInternetWatch(server: local, cameraAddress: "127.0.0.1").0.fixAddress?.addressing == keeps)
    }

    /// `LANConfig` goes back as the camera wrote it with only `DHCP` (0: Mode Static), `DNS1` and `DNS2` changed: the camera's address, mask
    /// and gateway as they were; read back while the camera restarts its network service. Its ONVIF is not written to.
    @Test func fixingKeepsTheSameAddressMaskAndGateway() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        camera.web.state.update { $0.lan = onDHCP() }
        camera.web.restartAfterLANWrite.set(2)
        let service = camera.service()
        #expect(try await service.applyDNS(server: local, fixingAddress: keeps, readBack: quick)
                == CameraSetupOutcome(succeeded: true, detail: "via web API", addressFixed: true))
        #expect(camera.writes == [FakeIPCWebCamera.lan(dhcp: 0, dns1: local, dns2: local, gateway: "127.0.0.254")],
                "one write: Mode Static, its address as it was, the bridge twice")
        #expect(try await service.readDNS()?.pointsAt(local) == true)
        #expect(camera.onvif.setDNSBodies.value.isEmpty && camera.onvif.setNetworkInterfacesBodies.value.isEmpty)

        // DHCP gave it another address since the preview: nothing is written.
        camera.web.state.update { $0.lan = onDHCP(gateway: "127.0.0.253") }
        #expect(try await service.applyDNS(server: local, fixingAddress: keeps, readBack: quick)
                == CameraSetupOutcome(succeeded: false, detail: CameraSettingsService.addressChangedRefusal(keeps), addressUntouched: true))
        #expect(camera.writes.count == 1)
    }

    /// Restore after the choice puts the camera back on DHCP with its DNS servers as they were, also when they were changed by hand since.
    @Test func restorePutsDHCPBack() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        camera.web.state.update { $0.lan = onDHCP() }
        let service = camera.service()
        var backup = try #require(try await service.readInternetWatch(server: local, cameraAddress: "127.0.0.1").1)
        backup.fixedAddress = keeps   // what the run saves before it changes anything
        backup.fixedAddressMethod = .ipcWebAPI
        #expect(try await service.applyDNS(server: local, fixingAddress: keeps, readBack: quick).succeeded)
        camera.web.state.update { $0.lan = FakeIPCWebCamera.lan(dns1: "127.0.0.53", dns2: "127.0.0.53", gateway: "127.0.0.254") }   // changed by hand since

        #expect(try await service.restoreDNS(backup, readBack: quick) == done())
        #expect(camera.web.state.value.lan == onDHCP(), "DHCP, and the DNS values as they were")
        #expect(try await service.restoreDNS(backup, readBack: quick) == done(), "already on DHCP")
        #expect(camera.writes.count == 2)

        camera.web.state.update { $0.lan = FakeIPCWebCamera.lan(netmask: "255.255.0.0", gateway: "127.0.0.254") }   // fixed otherwise by hand since
        #expect(try await service.restoreDNS(backup, readBack: quick)
                == CameraSetupOutcome(succeeded: false, detail: CameraSettingsService.addressChangedSinceFixed(keeps)))
        #expect(camera.writes.count == 2)
    }

    /// A Jennov whose DNS backup an older build saved through ONVIF, joined by this run's fix through its web API: Restore puts DHCP back
    /// through the web API (the way the address was fixed), and its DNS servers, from DHCP, come back with the address.
    @Test func restorePutsDHCPBackWhicheverWayTheDNSWasRead() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        camera.web.state.update { $0.lan = onDHCP() }
        let service = camera.service()
        #expect(try await service.applyDNS(server: local, fixingAddress: keeps, readBack: quick).succeeded)
        let merged = CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], searchDomains: [], fixedAddress: keeps, fixedAddressMethod: .ipcWebAPI)
        #expect(try await service.restoreDNS(merged, readBack: quick) == done())
        #expect(camera.web.state.value.lan == FakeIPCWebCamera.lan(dhcp: 1, dns1: local, dns2: local, gateway: "127.0.0.254"),
                "Mode DHCP again; the slots as they were left (the camera takes DHCP's)")
        #expect(camera.onvif.setDNSBodies.value.isEmpty && camera.onvif.setNetworkInterfacesBodies.value.isEmpty, "its ONVIF is not written to")
    }

    // MARK: The write

    @Test func theLANConfigIsWrittenBackAsTheCameraWroteIt() {
        let lan = FakeIPCWebCamera.lan()
        let written = FakeIPCWebCamera.lan(dns1: bridge, dns2: bridge)
        #expect(CameraSettingsService.ipcWebLANWrite(lan, dns1: bridge, dns2: bridge, host: "127.0.0.1") == written)
        #expect(CameraSettingsService.ipcWebLANWrite(lan, dns1: bridge, dns2: bridge, host: "camera.local") == written, "a name: no address to compare")
        // An attribute the page does not write, a child: back as the camera wrote them.
        let more = lan.replacingOccurrences(of: "MTU=\"1460\" />", with: "MTU=\"1460\"\nIPv6=\"fe80::1\"><Extra A=\"1\"/></LANConfig>")
        #expect(CameraSettingsService.ipcWebLANWrite(more, dns1: bridge, dns2: "", host: "127.0.0.1")
                == more.replacingOccurrences(of: "DNS1=\"8.8.8.8\"", with: "DNS1=\"\(bridge)\"").replacingOccurrences(of: "DNS2=\"1.1.1.1\"", with: "DNS2=\"\""))

        for refused in [FakeIPCWebCamera.lan(dhcp: 1), FakeIPCWebCamera.lan(ip: "192.0.2.20"),
                        lan.replacingOccurrences(of: "\nhostname=\"TESTCAM\"", with: ""),
                        lan.replacingOccurrences(of: "MTU=\"1460\"", with: "MTU=\"1460\" MTU=\"1500\"")] {
            #expect(CameraSettingsService.ipcWebLANWrite(refused, dns1: bridge, dns2: bridge, host: "127.0.0.1") == nil, "\(refused)")
        }
        #expect(CameraSettingsService.ipcWebLANWrite(lan, dns1: #"192.0.2.10" DHCP="1"#, dns2: bridge, host: "127.0.0.1") == nil, "an address only")
    }
}
#endif
