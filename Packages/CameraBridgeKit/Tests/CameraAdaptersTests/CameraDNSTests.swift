// Loopback fake ISAPI and ONVIF cameras (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// The internet guard's Watch (docs/superpowers/specs/2026-10-17-internet-guard-design.md), the camera's side: its DNS servers read (the
/// backup), pointed at the bridge, read back and put back; its gateway and network interfaces read. Against fakes only, with the answers
/// two real cameras gave (addresses changed to documentation ones).
@Suite(.timeLimit(.minutes(1))) struct CameraDNSTests {
    private let onvifCredentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)
    private let bridge = "192.0.2.10"

    private func onvif(_ camera: MockONVIFCamera) -> CameraSettingsService {
        CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)
    }

    private func hikvision(_ camera: FakeSetupCamera) -> CameraSettingsService {
        CameraSettingsService(endpoint: camera.endpoint, credentials: camera.credentials, vendor: .hikvision)
    }

    /// The response element of a device service answer, parsed as the client parses it (inside a SOAP envelope).
    private func body(_ fragment: String) throws -> XMLTree {
        let envelope = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" \
        xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body>\(fragment)</s:Body></s:Envelope>
        """
        return try #require(try XMLTree.parse(Data(envelope.utf8)).child("Body")?.children.first)
    }

    // MARK: ONVIF answers as two cameras gave them

    static let cameraADNS = """
    <tds:GetDNSResponse><tds:DNSInformation><tt:FromDHCP>true</tt:FromDHCP><tt:SearchDomain>domain.name</tt:SearchDomain><tt:DNSFromDHCP>\
    <tt:Type>IPv4</tt:Type><tt:IPv4Address>1.1.1.1</tt:IPv4Address></tt:DNSFromDHCP><tt:DNSFromDHCP><tt:Type>IPv4</tt:Type>\
    <tt:IPv4Address>8.8.8.8</tt:IPv4Address></tt:DNSFromDHCP></tds:DNSInformation></tds:GetDNSResponse>
    """
    static let cameraBDNS = """
    <tds:GetDNSResponse><tds:DNSInformation><tt:FromDHCP>false</tt:FromDHCP><tt:SearchDomain>ipnc</tt:SearchDomain><tt:DNSManual>\
    <tt:Type>IPv4</tt:Type><tt:IPv4Address>1.1.1.1</tt:IPv4Address></tt:DNSManual></tds:DNSInformation></tds:GetDNSResponse>
    """

    @Test func dnsAnswersAreReadAsTheCamerasGaveThem() throws {
        let a = ONVIFClient.parseDNS(try body(Self.cameraADNS))
        #expect(a == ONVIFDNSSettings(fromDHCP: true, searchDomains: ["domain.name"], dhcpServers: ["1.1.1.1", "8.8.8.8"], manualServers: []))
        #expect(a.servers == ["1.1.1.1", "8.8.8.8"], "a camera on DHCP uses what DHCP gave")
        let b = ONVIFClient.parseDNS(try body(Self.cameraBDNS))
        #expect(b == ONVIFDNSSettings(fromDHCP: false, searchDomains: ["ipnc"], dhcpServers: [], manualServers: ["1.1.1.1"]))
        #expect(b.servers == ["1.1.1.1"])
        let ipv6 = ONVIFClient.parseDNS(try body("""
        <tds:GetDNSResponse><tds:DNSInformation><tt:FromDHCP>false</tt:FromDHCP><tt:DNSManual><tt:Type>IPv6</tt:Type>\
        <tt:IPv6Address>2001:db8::53</tt:IPv6Address></tt:DNSManual><tt:DNSManual><tt:Type>IPv4</tt:Type><tt:IPv4Address> 192.0.2.53 </tt:IPv4Address>\
        </tt:DNSManual><tt:DNSManual><tt:Type>IPv4</tt:Type><tt:IPv4Address></tt:IPv4Address></tt:DNSManual></tds:DNSInformation></tds:GetDNSResponse>
        """))
        #expect(ipv6.manualServers == ["2001:db8::53", "192.0.2.53"], "IPv6 entries are kept, empty ones dropped")
        #expect(ipv6.searchDomains.isEmpty)
    }

    @Test func theGatewayAndInterfacesAreReadWithoutTheMAC() throws {
        let gateway = ONVIFClient.parseDefaultGateway(try body(MockONVIFCamera.gatewayAnswer))
        #expect(gateway == ONVIFDefaultGateway(ipv4: ["192.168.77.1"], ipv6: []))

        let interfaces = ONVIFClient.parseNetworkInterfaces(try body(MockONVIFCamera.interfacesAnswer))
        let eth0 = try #require(interfaces.first)
        #expect(interfaces.count == 1)
        #expect(eth0.token == "eth0" && eth0.enabled && eth0.name == "eth0" && eth0.mtu == 1400)
        #expect(eth0.ipv4Enabled && eth0.ipv4DHCP && eth0.ipv4Manual.isEmpty)
        #expect(eth0.ipv4FromDHCP == ONVIFPrefixedAddress(address: "192.168.77.22", prefixLength: 24))
        #expect(eth0.ipv4LinkLocal == ONVIFPrefixedAddress(address: "192.168.77.22", prefixLength: 24))
        #expect(eth0.ipv4Address == ONVIFPrefixedAddress(address: "192.168.77.22", prefixLength: 24), "on DHCP: the address DHCP gave")
        #expect(eth0.ipv6Enabled == nil)
        #expect(!String(describing: interfaces).lowercased().contains(MockONVIFCamera.documentationMAC), "the MAC address is not kept")
    }

    @Test func aFixedAddressAndIPv6AreRead() throws {
        let interfaces = ONVIFClient.parseNetworkInterfaces(try body("""
        <tds:GetNetworkInterfacesResponse><tds:NetworkInterfaces token="eth0"><tt:Enabled>true</tt:Enabled><tt:IPv4><tt:Enabled>true</tt:Enabled>\
        <tt:Config><tt:Manual><tt:Address>192.168.77.40</tt:Address><tt:PrefixLength>24</tt:PrefixLength></tt:Manual><tt:DHCP>false</tt:DHCP>\
        </tt:Config></tt:IPv4><tt:IPv6><tt:Enabled>true</tt:Enabled><tt:Config><tt:AcceptRouterAdvert>true</tt:AcceptRouterAdvert>\
        <tt:DHCP>Auto</tt:DHCP><tt:LinkLocal><tt:Address>fe80::5:22</tt:Address><tt:PrefixLength>64</tt:PrefixLength></tt:LinkLocal>\
        <tt:FromRA><tt:Address>2001:db8::40</tt:Address><tt:PrefixLength>64</tt:PrefixLength></tt:FromRA></tt:Config></tt:IPv6>\
        </tds:NetworkInterfaces><tds:NetworkInterfaces token="wlan0"><tt:Enabled>false</tt:Enabled></tds:NetworkInterfaces>\
        </tds:GetNetworkInterfacesResponse>
        """))
        #expect(interfaces.map(\.token) == ["eth0", "wlan0"])
        let eth0 = interfaces[0]
        #expect(!eth0.ipv4DHCP && eth0.ipv4Manual == [ONVIFPrefixedAddress(address: "192.168.77.40", prefixLength: 24)])
        #expect(eth0.ipv4Address == ONVIFPrefixedAddress(address: "192.168.77.40", prefixLength: 24), "fixed: the first manual address")
        #expect(eth0.ipv6Enabled == true && eth0.ipv6DHCP == "Auto")
        #expect(eth0.ipv6Addresses == [ONVIFPrefixedAddress(address: "2001:db8::40", prefixLength: 64)], "link-local addresses are left out")
        #expect(!interfaces[1].enabled && !interfaces[1].ipv4Enabled && interfaces[1].ipv4Address == nil)
        let gateway = ONVIFClient.parseDefaultGateway(try body("""
        <tds:GetNetworkDefaultGatewayResponse><tds:NetworkGateway><tt:IPv6Address>2001:db8::1</tt:IPv6Address></tds:NetworkGateway>\
        </tds:GetNetworkDefaultGatewayResponse>
        """))
        #expect(gateway == ONVIFDefaultGateway(ipv4: [], ipv6: ["2001:db8::1"]))
    }

    @Test func addressesAreTold() {
        for address in ["2001:db8::10", "::1", "fe80::5:22", "2001:db8:0:0:0:0:0:1", "::ffff:192.0.2.10", "::"] {
            #expect(ONVIFClient.isIPv6(address), "\(address)")
        }
        for text in ["192.0.2.10", "bridge.local", "2001:db8:::1", "2001:db8::1::2", "1:2:3:4:5:6:7:8:9", "fe80::1%eth0", "12345::", ""] {
            #expect(!ONVIFClient.isIPv6(text), "\(text)")
        }
    }

    @Test func theClientReadsTheDeviceAndWritesItsDNS() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let client = ONVIFClient(deviceServiceURL: camera.deviceServiceURL, credentials: onvifCredentials)
        #expect(try await client.dns().servers == ["1.1.1.1", "8.8.8.8"])
        #expect(try await client.defaultGateway().ipv4 == ["192.168.77.1"])
        #expect(try await client.networkInterfaces().first?.ipv4Address?.address == "192.168.77.22")

        try await client.setDNS(fromDHCP: false, servers: [bridge, "2001:db8::10"], searchDomains: ["domain.name"])
        let sent = try #require(camera.setDNSBodies.value.last)
        #expect(sent.contains("<tds:FromDHCP>false</tds:FromDHCP><tds:SearchDomain>domain.name</tds:SearchDomain>"))
        #expect(sent.contains("<tds:DNSManual><tt:Type>IPv4</tt:Type><tt:IPv4Address>192.0.2.10</tt:IPv4Address></tds:DNSManual>"))
        #expect(sent.contains("<tds:DNSManual><tt:Type>IPv6</tt:Type><tt:IPv6Address>2001:db8::10</tt:IPv6Address></tds:DNSManual>"))
        #expect(camera.dns.value.manualServers == [bridge, "2001:db8::10"] && !camera.dns.value.fromDHCP)
        await #expect(throws: CameraAdapterError.self, "a DNS server is an address") {
            try await client.setDNS(fromDHCP: false, servers: ["bridge.local"])
        }
        #expect(camera.setDNSBodies.value.count == 1, "nothing is sent for a name")
    }

    // MARK: ONVIF through the settings service

    @Test func aCameraOnDHCPIsPointedAtTheBridgeAndGivenBack() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = onvif(camera)

        let read = try #require(try await service.readDNS())
        #expect(read.servers == ["1.1.1.1", "8.8.8.8"] && read.fromDHCP && read.method == .onvifMinimal)
        #expect(read.backup == CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], searchDomains: ["domain.name"]))

        #expect(try await service.applyDNS(server: bridge) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.dns.value == MockONVIFCamera.DNS(fromDHCP: false, searchDomains: ["domain.name"], manualServers: [bridge]),
                "only the servers change: the search domain is kept")
        let after = try #require(try await service.readDNS())
        #expect(after.servers == [bridge] && !after.fromDHCP && after.pointsAt(bridge))
        #expect(!read.pointsAt(bridge) && !after.pointsAt("192.0.2.11"))

        #expect(try await service.restoreDNS(read.backup) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.dns.value == MockONVIFCamera.DNS(), "back on DHCP, as it was")
    }

    @Test func aCameraSetByHandGetsItsOwnServerBack() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dns.set(MockONVIFCamera.DNS(fromDHCP: false, searchDomains: ["ipnc"], dhcpServers: [], manualServers: ["1.1.1.1"]))
        let service = onvif(camera)
        let backup = try #require(try await service.readDNS()).backup
        #expect(backup == CameraDNSBackup(method: .onvifMinimal, fromDHCP: false, servers: ["1.1.1.1"], searchDomains: ["ipnc"]))
        #expect(try await service.applyDNS(server: bridge).succeeded)
        #expect(camera.dns.value.manualServers == [bridge])
        #expect(try await service.restoreDNS(backup).succeeded)
        #expect(camera.dns.value == MockONVIFCamera.DNS(fromDHCP: false, searchDomains: ["ipnc"], dhcpServers: [], manualServers: ["1.1.1.1"]))
    }

    @Test func ipv6ServersAreWrittenAndPutBack() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dns.set(MockONVIFCamera.DNS(fromDHCP: false, searchDomains: [], dhcpServers: [], manualServers: ["2001:db8::53", "192.0.2.53"]))
        let service = onvif(camera)
        let read = try #require(try await service.readDNS())
        #expect(read.servers == ["2001:db8::53", "192.0.2.53"])

        #expect(try await service.applyDNS(server: "2001:db8::10").succeeded)
        #expect(camera.setDNSBodies.value.last?.contains("<tt:Type>IPv6</tt:Type><tt:IPv6Address>2001:db8::10</tt:IPv6Address>") == true)
        #expect(camera.dns.value.manualServers == ["2001:db8::10"], "the bridge alone: no other server is left to ask")
        #expect(try #require(try await service.readDNS()).pointsAt("2001:DB8:0:0:0:0:0:10"), "an address written another way is the same address")
        #expect(try await service.applyDNS(server: "2001:DB8:0::10").succeeded, "the camera keeps it in its own way (lower case): read back the same")

        #expect(try await service.restoreDNS(read.backup).succeeded)
        #expect(camera.dns.value.manualServers == ["2001:db8::53", "192.0.2.53"])
    }

    @Test func aRefusalIsTheCamerasWordsAndAWriteThatDoesNotStickIsARefusal() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = onvif(camera)
        camera.refuseDNSChanges.set(true)
        let refused = try await service.applyDNS(server: bridge)
        #expect(!refused.succeeded && refused.detail.contains("InvalidArgVal"))
        #expect(camera.dns.value == MockONVIFCamera.DNS())

        camera.refuseDNSChanges.set(false)
        camera.ignoreDNSChanges.set(true)
        #expect(try await service.applyDNS(server: bridge) == CameraSetupOutcome(succeeded: false, detail: "the camera kept its own DNS servers"))
        let backup = CameraDNSBackup(method: .onvifMinimal, fromDHCP: false, servers: ["1.1.1.1"], searchDomains: ["ipnc"])
        #expect(try await service.restoreDNS(backup) == CameraSetupOutcome(succeeded: false, detail: "the camera did not take its old DNS servers back"))
    }

    @Test func aCameraWithoutDNSOrWithAWrongPasswordAndANameForAServer() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = onvif(camera)
        #expect(try await service.applyDNS(server: "bridge.local") == CameraSetupOutcome(succeeded: false, detail: "the DNS server must be an address"))
        #expect(camera.setDNSBodies.value.isEmpty)

        camera.noDNS.set(true)
        #expect(try await service.readDNS() == nil, "the camera does not show its DNS servers")
        #expect(try await service.applyDNS(server: bridge) == CameraSetupOutcome(succeeded: false, detail: "the camera does not show its DNS servers"))
        #expect(camera.setDNSBodies.value.isEmpty, "nothing is written to a camera whose DNS cannot be read back")

        camera.noDNS.set(false)
        camera.rejectCredentials.set(true)
        defer { ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(camera.server.port)") }
        await #expect(throws: CameraAdapterError.unauthorized) { try await service.readDNS() }
        // The login refusal paused ONVIF logins to the camera: the next call is refused before it is sent.
        let error = await #expect(throws: CameraAdapterError.self) { try await service.applyDNS(server: bridge) }
        #expect(error?.isLoginRefusal == true)
        #expect(camera.setDNSBodies.value.isEmpty)
    }

    // MARK: Hikvision ISAPI

    @Test func isapiDNSIsReadAndEditedInsideItsOwnElements() throws {
        let document = FakeSetupCamera.ipAddress()
        let read = try #require(HikvisionISAPI.dnsServers(in: document))
        #expect(read == ISAPIDNSServers(slots: ["8.8.8.8", "1.1.1.1"], addressingType: "dynamic"))
        #expect(read.servers == ["8.8.8.8", "1.1.1.1"])
        #expect(HikvisionISAPI.dnsServers(in: FakeSetupCamera.ipAddress(primaryDNS: "0.0.0.0", secondaryDNS: "0.0.0.0"))?.servers == [],
                "0.0.0.0 is no server")
        #expect(HikvisionISAPI.dnsServers(in: FakeSetupCamera.ipAddress(primaryDNS: "192.0.2.10", secondaryDNS: "192.0.2.10"))?.servers == ["192.0.2.10"])
        #expect(HikvisionISAPI.dnsServers(in: FakeSetupCamera.ipAddress(secondaryDNS: nil))?.slots == ["8.8.8.8"])
        #expect(HikvisionISAPI.dnsServers(in: FakeSetupCamera.upnp) == nil, "a document without DNS servers")

        let edited = try #require(HikvisionISAPI.settingDNS([bridge, bridge], in: document))
        #expect(edited == FakeSetupCamera.ipAddress(primaryDNS: bridge, secondaryDNS: bridge), "only the DNS servers differ")
        #expect(HikvisionISAPI.settingDNS(["8.8.8.8", "1.1.1.1"], in: edited) == document)
        #expect(HikvisionISAPI.settingDNS([bridge, bridge], in: FakeSetupCamera.ipAddress(secondaryDNS: nil)) == FakeSetupCamera.ipAddress(primaryDNS: bridge, secondaryDNS: nil),
                "no secondary server is added")
        #expect(HikvisionISAPI.settingDNS([bridge], in: FakeSetupCamera.upnp) == nil)
    }

    @Test func aHikvisionIsPointedAtTheBridgeAndGivenBackThroughISAPI() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        let service = hikvision(camera)

        let read = try #require(try await service.readDNS())
        #expect(read.servers == ["8.8.8.8", "1.1.1.1"] && !read.fromDHCP && read.method == .hikvisionISAPI)
        #expect(read.backup == CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: ["8.8.8.8", "1.1.1.1"]))

        #expect(try await service.applyDNS(server: bridge) == CameraSetupOutcome(succeeded: true, detail: "via ISAPI"))
        let put = try #require(camera.puts(to: HikvisionISAPI.ipAddressPath).last)
        #expect(put == FakeSetupCamera.ipAddress(primaryDNS: bridge, secondaryDNS: bridge),
                "the whole document goes back with only the DNS servers changed: the address, its DHCP and the gateway are as they were")
        #expect(try await service.readDNS()?.servers == [bridge])
        #expect(try await service.readDNS()?.pointsAt(bridge) == true)
        #expect(!camera.server.requests.contains { $0.path.contains("onvif") }, "a Hikvision is set through ISAPI")

        #expect(try await service.restoreDNS(read.backup) == CameraSetupOutcome(succeeded: true, detail: "via ISAPI"))
        #expect(camera.documents.value[HikvisionISAPI.ipAddressPath] == FakeSetupCamera.ipAddress(), "the document is exactly as it was")
    }

    @Test func aFixedAddressStaysFixed() async throws {
        var documents = FakeSetupCamera.defaultDocuments()
        documents[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress(addressing: "static", secondaryDNS: "0.0.0.0")
        let camera = try await FakeSetupCamera.start(documents: documents)
        defer { camera.stop() }
        let service = hikvision(camera)
        let read = try #require(try await service.readDNS())
        #expect(read.servers == ["8.8.8.8"] && read.backup.servers == ["8.8.8.8", "0.0.0.0"])
        #expect(try await service.applyDNS(server: bridge).succeeded)
        #expect(camera.documents.value[HikvisionISAPI.ipAddressPath] == FakeSetupCamera.ipAddress(addressing: "static", primaryDNS: bridge, secondaryDNS: bridge))
        #expect(try await service.restoreDNS(read.backup).succeeded)
        #expect(camera.documents.value[HikvisionISAPI.ipAddressPath] == FakeSetupCamera.ipAddress(addressing: "static", secondaryDNS: "0.0.0.0"))
    }

    @Test func isapiRefusalsRestartsAndIPv6() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        let service = hikvision(camera)
        camera.refusePUT.update { $0.insert(HikvisionISAPI.ipAddressPath) }
        #expect(try await service.applyDNS(server: bridge) == CameraSetupOutcome(succeeded: false, detail: "Invalid Content (badParameters)"))

        camera.refusePUT.update { $0.removeAll() }
        camera.ignorePUT.update { $0.insert(HikvisionISAPI.ipAddressPath) }
        #expect(try await service.applyDNS(server: bridge) == CameraSetupOutcome(succeeded: false, detail: "the camera kept its own DNS servers"))
        let backup = CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: ["192.0.2.53", "192.0.2.54"])
        #expect(try await service.restoreDNS(backup) == CameraSetupOutcome(succeeded: false, detail: "the camera did not take its old DNS servers back"))

        camera.ignorePUT.update { $0.removeAll() }
        camera.rebootRequired.update { $0.insert(HikvisionISAPI.ipAddressPath) }
        #expect(try await service.applyDNS(server: bridge) == CameraSetupOutcome(succeeded: true, needsRestart: true, detail: "via ISAPI"))
        #expect(!camera.server.requests.contains { $0.path.contains("reboot") }, "the bridge never restarts the camera")

        // "Reboot Required" while the camera still shows its old servers: it waits for its restart (the security check reads its DNS again
        // before the guard counts it as watched), and Camera Bridge never restarts it.
        camera.documents.update { $0[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress() }
        camera.ignorePUT.update { $0.insert(HikvisionISAPI.ipAddressPath) }
        #expect(try await service.applyDNS(server: bridge) == CameraSetupOutcome(succeeded: true, needsRestart: true, detail: "via ISAPI"))
        #expect(try await service.readDNS()?.pointsAt(bridge) == false)
        camera.ignorePUT.update { $0.removeAll() }

        // A camera whose document is gone after the write shows nothing to check it against.
        camera.rebootRequired.update { $0.removeAll() }
        camera.vanishAfterPUT.update { $0.insert(HikvisionISAPI.ipAddressPath) }
        camera.documents.update { $0[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress() }
        #expect(try await service.applyDNS(server: bridge) == CameraSetupOutcome(succeeded: false, detail: "the camera no longer shows its DNS servers"))
        camera.vanishAfterPUT.update { $0.removeAll() }
        camera.documents.update { $0[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress() }

        let puts = camera.puts(to: HikvisionISAPI.ipAddressPath).count
        #expect(try await service.applyDNS(server: "2001:db8::10") == CameraSetupOutcome(succeeded: false, detail: "this camera takes an IPv4 address for its DNS server"))
        #expect(camera.puts(to: HikvisionISAPI.ipAddressPath).count == puts)
    }

    @Test func aHikvisionWithoutTheDocumentOrONVIFShowsNoDNS() async throws {
        var documents = FakeSetupCamera.defaultDocuments()
        documents[HikvisionISAPI.ipAddressPath] = nil
        let camera = try await FakeSetupCamera.start(documents: documents)
        defer { camera.stop() }
        let service = hikvision(camera)
        #expect(try await service.readDNS() == nil)
        #expect(try await service.applyDNS(server: bridge) == CameraSetupOutcome(succeeded: false, detail: "the camera does not show its DNS servers"))
        let backup = CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: ["8.8.8.8"])
        #expect(try await service.restoreDNS(backup) == CameraSetupOutcome(succeeded: false, detail: "the camera no longer shows its DNS servers"))
    }

    @Test func aBackupIsSavedAndReadBack() throws {
        let backup = CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: ["2001:db8::53"], searchDomains: ["domain.name"])
        #expect(try JSONDecoder().decode(CameraDNSBackup.self, from: JSONEncoder().encode(backup)) == backup)
        let older = try JSONDecoder().decode(CameraDNSBackup.self, from: Data(#"{"method":"hikvisionISAPI","fromDHCP":false,"servers":["8.8.8.8"]}"#.utf8))
        #expect(older == CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: ["8.8.8.8"]), "search domains are optional")
    }
}
#endif
