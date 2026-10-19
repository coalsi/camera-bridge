// Loopback fake ISAPI and ONVIF cameras (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// The internet guard's Watch (docs/superpowers/specs/2026-10-17-internet-guard-design.md), the camera's side: its DNS servers read (the
/// backup), pointed at the bridge (every slot of a camera that keeps a slot it is not sent), read back and put back, a refusal saying what
/// the camera kept; its gateway and network interfaces read. Against fakes only, with the answers two real cameras gave (addresses changed
/// to documentation ones). The cameras' own APIs: `CameraDNSOwnAPITests`.
@Suite(.timeLimit(.minutes(1))) struct CameraDNSTests {
    private let onvifCredentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)
    private let bridge = "192.0.2.10"
    /// The read-back after a write, short for the fakes (a camera gets 30 s, read every 2 s): at once, then every 20 ms for up to 10 s.
    private let quick = DNSReadBackTiming(limit: .seconds(10), interval: .milliseconds(20))
    /// The whole wait of a camera that never takes the form, short: every 20 ms for 300 ms, and 100 ms for each form after the first one
    /// the camera accepted (a camera gets 30 s for the first, 6 s for the others).
    private let brief = DNSReadBackTiming(limit: .milliseconds(300), interval: .milliseconds(20), laterFormsLimit: .milliseconds(100))

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

    /// The hardware address is read for the router reservation of "Fix its address so the DNS stays" only (never logged or saved).
    @Test func theGatewayAndInterfacesAreRead() throws {
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
        #expect(eth0.hardwareAddress == MockONVIFCamera.hardwareAddress)
        let hidden = ONVIFClient.parseNetworkInterfaces(try body(MockONVIFCamera.interfacesAnswer(MockONVIFCamera.IPv4(), hardwareAddress: nil)))
        #expect(hidden.first?.hardwareAddress == nil)
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

    /// Whether IPv6 is on, for the DNS help's warning: an enabled interface with IPv6 enabled, as `GetNetworkInterfaces` shows it. Reads only;
    /// nil for a camera that does not answer it.
    @Test func ipv6IsReadFromTheInterfaces() async throws {
        let device = try await MockONVIFCamera.start()
        defer { device.stop() }
        let service = onvif(device)
        #expect(try await service.readIPv6() == false, "camera A shows no IPv6 section")
        let interface = { (on: Bool, ipv6: Bool) in
            "<tds:GetNetworkInterfacesResponse><tds:NetworkInterfaces token=\"eth0\"><tt:Enabled>\(on)</tt:Enabled><tt:IPv4><tt:Enabled>true</tt:Enabled>"
                + "<tt:Config><tt:DHCP>true</tt:DHCP></tt:Config></tt:IPv4><tt:IPv6><tt:Enabled>\(ipv6)</tt:Enabled><tt:Config><tt:DHCP>Auto</tt:DHCP>"
                + "</tt:Config></tt:IPv6></tds:NetworkInterfaces></tds:GetNetworkInterfacesResponse>"
        }
        device.interfacesOverride.set(interface(true, true))
        #expect(try await service.readIPv6() == true)
        device.interfacesOverride.set(interface(true, false))
        #expect(try await service.readIPv6() == false)
        device.interfacesOverride.set(interface(false, true))
        #expect(try await service.readIPv6() == false, "on an interface that is off")
        device.interfacesOverride.set("<tds:GetDNSResponse/>")
        #expect(try await service.readIPv6() == nil, "an answer that is not the interfaces")
        #expect(device.actions.value.filter { $0 == "GetNetworkInterfaces" }.count == 5)
        #expect(!device.actions.value.contains { $0.hasPrefix("Set") }, "reads only")
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

        #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.dns.value == MockONVIFCamera.DNS(fromDHCP: false, searchDomains: ["domain.name"], manualServers: [bridge, bridge]),
                "only the servers change: the search domain is kept, and the bridge fills both slots")
        #expect(camera.setDNSBodies.value.count == 1, "a camera that takes the bridge in both slots is written once")
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
        #expect(try await service.applyDNS(server: bridge, readBack: quick).succeeded)
        #expect(camera.dns.value.manualServers == [bridge, bridge])
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

        #expect(try await service.applyDNS(server: "2001:db8::10", readBack: quick).succeeded)
        #expect(camera.setDNSBodies.value.last?.contains("<tt:Type>IPv6</tt:Type><tt:IPv6Address>2001:db8::10</tt:IPv6Address>") == true)
        #expect(camera.dns.value.manualServers == ["2001:db8::10", "2001:db8::10"], "the bridge in both slots: no other server is left to ask")
        #expect(try #require(try await service.readDNS()).pointsAt("2001:DB8:0:0:0:0:0:10"), "an address written another way is the same address")
        #expect(try await service.applyDNS(server: "2001:DB8:0::10", readBack: quick).succeeded,
                "the camera keeps it in its own way (lower case): read back the same")

        #expect(try await service.restoreDNS(read.backup).succeeded)
        #expect(camera.dns.value.manualServers == ["2001:db8::53", "192.0.2.53"])
    }

    @Test func aRefusalIsTheCamerasWordsAndAWriteThatDoesNotStickIsARefusal() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = onvif(camera)
        camera.refuseDNSChanges.set(true)
        let refused = try await service.applyDNS(server: bridge, readBack: quick)
        #expect(!refused.succeeded && refused.detail.contains("InvalidArgVal"))
        #expect(entries(camera) == [2, 1, 2], "a camera that refuses the first form is offered the others, and every refusal is its own words")
        #expect(camera.dns.value == MockONVIFCamera.DNS())

        camera.refuseDNSChanges.set(false)
        camera.ignoreDNSChanges.set(true)
        #expect(try await service.applyDNS(server: bridge, readBack: brief) == CameraSetupOutcome(succeeded: false, detail: "the camera kept its own DNS servers"))
        let backup = CameraDNSBackup(method: .onvifMinimal, fromDHCP: false, servers: ["1.1.1.1"], searchDomains: ["ipnc"])
        #expect(try await service.restoreDNS(backup) == CameraSetupOutcome(succeeded: false, detail: "the camera did not take its old DNS servers back"))
    }

    // MARK: ONVIF on a camera with two slots

    /// One `DNSManual` entry as `SetDNS` sends it.
    private func entry(_ address: String) -> String {
        "<tds:DNSManual><tt:Type>IPv4</tt:Type><tt:IPv4Address>\(address)</tt:IPv4Address></tds:DNSManual>"
    }

    /// The number of `DNSManual` entries of each `SetDNS` the camera was sent.
    private func entries(_ camera: MockONVIFCamera) -> [Int] {
        camera.setDNSBodies.value.map { $0.components(separatedBy: "<tds:DNSManual>").count - 1 }
    }

    /// As "Patio New" answered: on DHCP, and the servers of its page's two slots (not shown while on DHCP).
    private static let patioNew = MockONVIFCamera.DNS(fromDHCP: true, searchDomains: ["domain.name"], dhcpServers: ["1.1.1.1", "8.8.8.8"],
                                                      manualServers: ["1.1.1.1", "8.8.8.8"])

    /// "Patio New" kept 8.8.8.8 in its second slot when `SetDNS` named the bridge alone: the bridge goes into both slots (the first form
    /// now), and Restore puts DHCP back.
    @Test func aCameraWithTwoSlotsGetsTheBridgeInBoth() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dnsSlots.set(.two)
        camera.dns.set(Self.patioNew)
        let service = onvif(camera)
        let read = try #require(try await service.readDNS())
        #expect(read.backup == CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], searchDomains: ["domain.name"]))

        #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(entries(camera) == [2], "the bridge in both slots, at once: no other form is needed")
        #expect(camera.setDNSBodies.value.last?.contains(entry(bridge) + entry(bridge)) == true)
        #expect(camera.dns.value.manualServers == [bridge, bridge] && !camera.dns.value.fromDHCP)
        #expect(try await service.readDNS()?.pointsAt(bridge) == true)

        #expect(try await service.restoreDNS(read.backup) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.dns.value.fromDHCP, "back on DHCP, as it was")
    }

    @Test func aCameraWithTwoSlotsGetsBackExactlyTheServersItHad() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dnsSlots.set(.two)
        let service = onvif(camera)

        // One server set by hand, the second slot empty: the bridge alone fills what the camera asks.
        camera.dns.set(MockONVIFCamera.DNS(fromDHCP: false, searchDomains: ["ipnc"], dhcpServers: [], manualServers: ["1.1.1.1", ""]))
        let one = try #require(try await service.readDNS()).backup
        #expect(one.servers == ["1.1.1.1"])
        #expect(try await service.applyDNS(server: bridge, readBack: quick).succeeded)
        #expect(entries(camera) == [2])
        // A run before left the bridge in both slots: the old server alone would keep the bridge second, so the second slot is emptied.
        camera.dns.update { $0.manualServers = [bridge, bridge] }
        #expect(try await service.restoreDNS(one) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.dns.value.manualServers == ["1.1.1.1", ""])
        #expect(Array(entries(camera).suffix(2)) == [1, 2], "Restore: the old server alone, then with the second slot emptied")
        #expect(camera.setDNSBodies.value.last?.contains(entry("1.1.1.1") + entry("")) == true)

        // Two servers set by hand come back as they were.
        camera.dns.set(MockONVIFCamera.DNS(fromDHCP: false, searchDomains: ["ipnc"], dhcpServers: [], manualServers: ["1.1.1.1", "8.8.8.8"]))
        let two = try #require(try await service.readDNS()).backup
        #expect(try await service.applyDNS(server: bridge, readBack: quick).succeeded)
        #expect(camera.dns.value.manualServers == [bridge, bridge])
        #expect(try await service.restoreDNS(two).succeeded)
        #expect(camera.dns.value.manualServers == ["1.1.1.1", "8.8.8.8"])
    }

    @Test func aCameraThatRefusesOneAddressTwiceGetsTheBridgeAndAnEmptySlot() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dnsSlots.set(.twoRefusingDuplicates)
        camera.dns.set(Self.patioNew)
        let service = onvif(camera)
        // The bridge alone is the first form the camera accepts, and leaves 8.8.8.8 in the second slot: it is read back for the whole wait
        // before the last form is sent.
        #expect(try await service.applyDNS(server: bridge, readBack: brief) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(entries(camera) == [2, 1, 2], "the bridge twice (refused), the bridge alone (the other server stays), then with an empty second slot")
        #expect(camera.setDNSBodies.value.last?.contains(entry(bridge) + entry("")) == true)
        #expect(camera.dns.value.manualServers == [bridge, ""])
        #expect(try await service.readDNS()?.servers == [bridge])
    }

    @Test func aCameraThatKeepsItsOtherServerIsRefusedInWordsThatSayWhatItKept() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dnsSlots.set(.twoKeepingSecond)
        camera.dns.set(Self.patioNew)
        let service = onvif(camera)
        let read = try #require(try await service.readDNS())
        #expect(try await service.applyDNS(server: bridge, readBack: brief)
                == CameraSetupOutcome(succeeded: false, detail: "the camera asks Camera Bridge first but kept 8.8.8.8 as its other DNS server"))
        #expect(entries(camera) == [2, 1, 2])
        #expect(camera.dns.value.manualServers == [bridge, "8.8.8.8"])
        #expect(try await service.restoreDNS(read.backup).succeeded)
        #expect(camera.dns.value.fromDHCP, "Restore puts back what the camera had")
    }

    // MARK: ONVIF: the bridge in both slots first, and patience (Camera DNS)

    /// The `GetDNS` reads the camera was asked after its last `SetDNS`.
    private func readsAfterTheWrite(_ camera: MockONVIFCamera) -> Int {
        let actions = camera.actions.value
        guard let write = actions.lastIndex(of: "SetDNS") else { return 0 }
        return actions[write...].filter { $0 == "GetDNS" }.count
    }

    /// A Dahua with an empty second slot fell back to Google DNS: the first form names the bridge twice, so no slot is left empty or to a
    /// server the camera had.
    @Test func theFirstFormFillsBothSlots() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dns.set(MockONVIFCamera.DNS(fromDHCP: false, searchDomains: ["ipnc"], dhcpServers: [], manualServers: ["1.1.1.1", "8.8.8.8"]))
        #expect(try await onvif(camera).applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        let first = try #require(camera.setDNSBodies.value.first)
        #expect(first.contains(entry(bridge) + entry(bridge)), "two DNSManual entries, both the bridge")
        #expect(first.contains("<tds:FromDHCP>false</tds:FromDHCP><tds:SearchDomain>ipnc</tds:SearchDomain>"), "not from DHCP, the search domain as read")
        #expect(entries(camera) == [2], "a camera that takes it is written once")
        #expect(camera.dns.value.manualServers == [bridge, bridge])
    }

    /// Some cameras apply `SetDNS` only after their network restarts: until then `GetDNS` still shows the old servers. The camera here
    /// shows the write after 5 reads (10 s at the real 2 s between reads); it is read back until it does, and no other form is sent meanwhile.
    @Test func aSlowCameraIsGivenThirtySeconds() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.applyDNSAfterReads.set(5)
        let service = onvif(camera)
        #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(entries(camera) == [2], "the first form was still being applied: no second form is sent")
        #expect(readsAfterTheWrite(camera) == 6, "the camera was read again until it showed the write: five times the old servers, then the bridge")
        #expect(camera.dns.value == MockONVIFCamera.DNS(fromDHCP: false, searchDomains: ["domain.name"], manualServers: [bridge, bridge]))
        #expect(try await service.readDNS()?.pointsAt(bridge) == true)
    }

    /// The camera restarts its network service: it does not answer `GetDNS` at all for a while. That is no answer yet, not a refusal.
    @Test func aCameraThatIsSilentWhileItRestartsIsReadAgain() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.applyDNSAfterReads.set(4)
        camera.silentWhileApplying.set(true)
        #expect(try await onvif(camera).applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(entries(camera) == [2])
        #expect(readsAfterTheWrite(camera) == 5, "four reads without an answer, then the camera shows the write")
    }

    /// A camera that never shows the write is read back for the whole wait before it is called refused: it kept its own servers, so no
    /// other form is sent (it ignores `SetDNS`).
    @Test func aCameraThatKeepsItsOwnServersIsReadBackForTheWholeWait() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.applyDNSAfterReads.set(1_000_000)
        let started = ContinuousClock.now
        let outcome = try await onvif(camera).applyDNS(server: bridge, readBack: brief)
        #expect(outcome == CameraSetupOutcome(succeeded: false, detail: "the camera kept its own DNS servers"))
        #expect(ContinuousClock.now - started >= brief.limit, "refused only once the wait was over")
        #expect(readsAfterTheWrite(camera) >= 2, "read again after the first read, while it waited")
        #expect(entries(camera) == [2], "a camera that shows nothing of the write is not sent the other forms")
    }

    /// The real wait, which the fakes shorten: every 2 s for up to 30 s, and 6 s for the forms after the first one the camera accepts.
    @Test func theWaitIsThirtySecondsReadEveryTwo() {
        let real = DNSReadBackTiming()
        #expect(real.limit == .seconds(30) && real.interval == .seconds(2) && real.laterFormsLimit == .seconds(6))
        #expect(real.forLaterForms == DNSReadBackTiming(limit: .seconds(6), interval: .seconds(2), laterFormsLimit: .seconds(6)))
        #expect(DNSReadBackTiming(limit: .seconds(1), laterFormsLimit: .seconds(6)).forLaterForms.limit == .seconds(1),
                "a later form never waits longer than the first")
    }

    /// `applyDNS(server:)` and `restoreDNS(_:)` read back with the service's timing, which is the real one unless a test shortens it.
    @Test func thePublicCallsReadBackWithTheServicesTiming() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = onvif(camera)
        #expect(await service.dnsReadBack == DNSReadBackTiming(), "30 s every 2 s, and 6 s for later forms, unless told otherwise")

        await service.useDNSReadBack(brief)
        camera.ignoreDNSChanges.set(true)
        let started = ContinuousClock.now
        #expect(try await service.applyDNS(server: bridge) == CameraSetupOutcome(succeeded: false, detail: "the camera kept its own DNS servers"))
        #expect(ContinuousClock.now - started >= brief.limit, "read back for the whole wait of the timing it was given")
        #expect(ContinuousClock.now - started < .seconds(10), "not for the real 30 s")
        #expect(readsAfterTheWrite(camera) >= 2)
    }

    // MARK: How long each form is read back (ruling D2)

    /// The first form the camera accepts gets the whole wait: a camera that applies it slowly shows it long after a later form's wait would
    /// have ended. Here it shows the write after 40 reads, 20 ms apart, with 50 ms for later forms.
    @Test func theFirstAcceptedFormIsReadBackForTheWholeWait() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.applyDNSAfterReads.set(40)
        let timing = DNSReadBackTiming(limit: .seconds(10), interval: .milliseconds(20), laterFormsLimit: .milliseconds(50))
        #expect(try await onvif(camera).applyDNS(server: bridge, readBack: timing) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(entries(camera) == [2], "no other form was sent while the first was being applied")
        #expect(readsAfterTheWrite(camera) == 41)
    }

    /// A camera that keeps its second slot whatever it is sent takes every form and shows none: the first is read back for `limit`, the other
    /// two for `laterFormsLimit` each (the wait is about limit + 2 x later, not 3 x limit).
    @Test func aLaterFormIsReadBackForTheShorterWaitOnly() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dnsSlots.set(.twoKeepingSecond)
        camera.dns.set(Self.patioNew)
        let timing = DNSReadBackTiming(limit: .seconds(1), interval: .milliseconds(20), laterFormsLimit: .milliseconds(50))
        let started = ContinuousClock.now
        let outcome = try await onvif(camera).applyDNS(server: bridge, readBack: timing)
        let waited = ContinuousClock.now - started
        #expect(outcome == CameraSetupOutcome(succeeded: false, detail: "the camera asks Camera Bridge first but kept 8.8.8.8 as its other DNS server"))
        #expect(entries(camera) == [2, 1, 2])
        #expect(waited >= timing.limit + timing.laterFormsLimit * 2, "the first form was read back for the whole wait, the others for theirs")
        #expect(waited < timing.limit * 2.5, "three full waits would be 3 s")
    }

    /// A camera that answers nothing at all in a later form's short window says what an earlier form's reading showed (it kept 8.8.8.8),
    /// not that it "no longer shows its DNS servers"; one that was never read says the latter.
    @Test func aLaterFormThatGetsNoAnswerSaysWhatTheEarlierReadingKept() async throws {
        let timing = DNSReadBackTiming(limit: .seconds(1), interval: .milliseconds(20), laterFormsLimit: .milliseconds(50))
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dnsSlots.set(.twoKeepingSecond)
        camera.dns.set(Self.patioNew)
        // Every write shows only after 8 reads, and the camera is silent meanwhile: the first form's wait (1 s) outlasts that and reads
        // [bridge, 8.8.8.8]; the second form's window (50 ms: 4 reads at most) does not.
        camera.applyDNSAfterReads.set(8)
        camera.silentWhileApplying.set(true)
        let outcome = try await onvif(camera).applyDNS(server: bridge, readBack: timing)
        #expect(outcome == CameraSetupOutcome(succeeded: false, detail: "the camera asks Camera Bridge first but kept 8.8.8.8 as its other DNS server"),
                "\(outcome)")
        #expect(entries(camera) == [2, 1], "the third form is not sent: the second one's read-back ended the attempts")

        // No earlier reading to quote: the first form itself is never answered.
        let silent = try await MockONVIFCamera.start()
        defer { silent.stop() }
        silent.applyDNSAfterReads.set(10_000)
        silent.silentWhileApplying.set(true)
        let never = try await onvif(silent).applyDNS(server: bridge, readBack: brief)
        #expect(never == CameraSetupOutcome(succeeded: false, detail: "the camera no longer shows its DNS servers"), "\(never)")
    }

    /// The whole wait is for the first form the camera *accepts*: one it answered with a fault was not accepted, and is not read back.
    @Test func theFirstFormAfterAFaultStillGetsTheWholeWait() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dnsSlots.set(.twoRefusingDuplicates)
        camera.dns.set(Self.patioNew)
        let timing = DNSReadBackTiming(limit: .seconds(1), interval: .milliseconds(20), laterFormsLimit: .milliseconds(50))
        let started = ContinuousClock.now
        #expect(try await onvif(camera).applyDNS(server: bridge, readBack: timing) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(ContinuousClock.now - started >= timing.limit, "the bridge alone, accepted second, was read back for the whole wait (8.8.8.8 stayed)")
        #expect(entries(camera) == [2, 1, 2])
    }

    /// A write the camera answers with a fault is not read back: the next form follows at once.
    @Test func aFaultedFormIsFollowedByTheNextWithoutAReadBack() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dnsSlots.set(.twoRefusingDuplicates)
        #expect(try await onvif(camera).applyDNS(server: bridge, readBack: quick).succeeded)
        let dns = camera.actions.value.filter { $0 == "GetDNS" || $0 == "SetDNS" }
        #expect(dns == ["GetDNS", "SetDNS", "SetDNS", "GetDNS"],
                "the reading before the write, the refused form, the next form straight after it, then the read-back of that one")
    }

    // MARK: When every form is refused

    /// A camera that refuses every form is refused in the words of the last one.
    @Test func aCameraThatRefusesEveryFormIsRefusedInTheLastFormsWords() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dnsFaults.set(["InvalidArgVal", "ActionNotSupported", "OperationProhibited"])
        let outcome = try await onvif(camera).applyDNS(server: bridge, readBack: quick)
        #expect(!outcome.succeeded && !outcome.notPermitted)
        #expect(outcome.detail.contains("OperationProhibited") && !outcome.detail.contains("InvalidArgVal"), "\(outcome.detail)")
        #expect(entries(camera) == [2, 1, 2])
    }

    /// An account that may not change the DNS is told so, whatever the forms before it were refused for: the administrator words,
    /// typed, and no further form is sent.
    @Test func aRefusalForTheAccountIsPreferredToTheOtherFaults() async throws {
        let camera = try await MockONVIFCamera.start()
        let host = "127.0.0.1:\(camera.server.port)"
        ONVIFLoginGuard.shared.clear(host: host)
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        camera.dnsFaults.set(["InvalidArgVal", "NotAuthorized", "InvalidArgVal"])
        let outcome = try await onvif(camera).applyDNS(server: bridge, readBack: quick)
        #expect(outcome == .notPermittedRefusal)
        #expect(outcome.notPermitted && outcome.detail == CameraAdapterError.notPermittedReason)
        #expect(entries(camera) == [2, 1], "the account was refused at the second form: no third is sent")
        #expect(ONVIFLoginGuard.shared.pause(host: host) == nil)
    }

    /// A camera that refuses one address twice answers the first form with a fault: the next form (the bridge alone) is sent, not the
    /// camera's refusal returned.
    @Test func aCameraThatRefusesTheSameAddressTwiceGetsTheNextForm() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dnsSlots.set(.twoRefusingDuplicates)
        #expect(try await onvif(camera).applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(entries(camera) == [2, 1], "the bridge twice (refused), then the bridge alone")
        #expect(camera.setDNSBodies.value.last?.contains(entry(bridge)) == true)
        #expect(camera.dns.value.fromDHCP == false)
        #expect(try await onvif(camera).readDNS()?.servers == [bridge])
    }

    /// A refusal because the account may not change the camera's network is no reason to try other forms: the account's words, at once.
    @Test func aChangeTheAccountMayNotMakeIsRefusedWithoutTryingTheOtherForms() async throws {
        let camera = try await MockONVIFCamera.start()
        let host = "127.0.0.1:\(camera.server.port)"
        ONVIFLoginGuard.shared.clear(host: host)
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        camera.refusedWrites.set(["SetDNS": .notAuthorizedFault])
        #expect(try await onvif(camera).applyDNS(server: bridge, readBack: quick) == .notPermittedRefusal)
        #expect(camera.actions.value.filter { $0 == "SetDNS" }.count == 1, "asked once: no other form would be let through")
        #expect(ONVIFLoginGuard.shared.pause(host: host) == nil)
    }

    @Test func aRefusalSaysWhatTheCameraKept() {
        func reading(_ servers: [String], fromDHCP: Bool = false) -> CameraDNSReading {
            CameraDNSReading(servers: servers, fromDHCP: fromDHCP, method: .onvifMinimal,
                             backup: CameraDNSBackup(method: .onvifMinimal, fromDHCP: fromDHCP, servers: servers))
        }
        #expect(CameraSettingsService.kept(reading([bridge, "8.8.8.8", "1.1.1.1"]), server: bridge)
                == "the camera asks Camera Bridge first but kept 8.8.8.8 and 1.1.1.1 as its other DNS servers")
        #expect(CameraSettingsService.kept(reading(["8.8.8.8", bridge]), server: bridge)
                == "the camera kept 8.8.8.8 as DNS server besides Camera Bridge, and asks 8.8.8.8 first")
        for other in [reading(["1.1.1.1", "8.8.8.8"]), reading(["1.1.1.1", "8.8.8.8"], fromDHCP: true), reading([])] {
            #expect(CameraSettingsService.kept(other, server: bridge) == "the camera kept its own DNS servers")
        }
    }

    @Test func aCameraWithoutDNSOrWithAWrongPasswordAndANameForAServer() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = onvif(camera)
        #expect(try await service.applyDNS(server: "bridge.local") == CameraSetupOutcome(succeeded: false, detail: "the DNS server must be an address"))
        #expect(camera.setDNSBodies.value.isEmpty)

        camera.noDNS.set(true)
        #expect(try await service.readDNS() == nil, "the camera does not show its DNS servers")
        #expect(try await service.applyDNS(server: bridge, readBack: quick)
                == CameraSetupOutcome(succeeded: false, detail: "the camera does not show its DNS servers"))
        #expect(camera.setDNSBodies.value.isEmpty, "nothing is written to a camera whose DNS cannot be read back")

        camera.noDNS.set(false)
        camera.rejectCredentials.set(true)
        defer { ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(camera.server.port)") }
        await #expect(throws: CameraAdapterError.unauthorized) { try await service.readDNS() }
        // The login refusal paused ONVIF logins to the camera: the next call is refused before it is sent.
        let error = await #expect(throws: CameraAdapterError.self) { try await service.applyDNS(server: bridge, readBack: quick) }
        #expect(error?.isLoginRefusal == true)
        #expect(camera.setDNSBodies.value.isEmpty)
    }

    // MARK: Whoever changed it (owner decision, 2026-10-18)

    private func reading(_ servers: [String], fromDHCP: Bool) -> CameraDNSReading {
        CameraDNSReading(servers: servers, fromDHCP: fromDHCP, method: .onvifMinimal,
                         backup: CameraDNSBackup(method: .onvifMinimal, fromDHCP: fromDHCP, servers: servers))
    }

    /// A camera asks the bridge when every DNS server it uses is the bridge, wherever it has them from: one the router's DHCP points at the
    /// bridge counts too (the reading still says it came from DHCP, so the page can say it may change when the router renews it). A slot that
    /// holds 0.0.0.0 or :: is an empty slot, not a server (round one's review).
    @Test func dnsThatPointsOnlyAtTheBridgeCountsWhoeverSetIt() {
        #expect(reading([bridge], fromDHCP: true).pointsAt(bridge), "the router's DHCP hands out the bridge")
        #expect(reading([bridge, bridge], fromDHCP: true).pointsAt(bridge))
        #expect(!reading([bridge, "8.8.8.8"], fromDHCP: true).pointsAt(bridge), "another server: not the bridge alone")
        #expect(!reading([], fromDHCP: true).pointsAt(bridge))
        #expect(reading([bridge, "0.0.0.0"], fromDHCP: false).pointsAt(bridge), "0.0.0.0 is an empty slot")
        #expect(reading(["2001:db8::10", "::"], fromDHCP: false).pointsAt("2001:DB8:0:0:0:0:0:10"), ":: is an empty slot")
        #expect(!reading(["0.0.0.0", "0:0:0:0:0:0:0:0"], fromDHCP: false).pointsAt(bridge), "no server at all")
    }

    /// A camera whose DHCP already points it at the bridge is left as it is, and the step says the router can change it.
    @Test func aCameraTheRouterPointsAtTheBridgeIsAlreadyRightAndMayChange() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dns.set(MockONVIFCamera.DNS(fromDHCP: true, searchDomains: ["domain.name"], dhcpServers: [bridge], manualServers: []))
        let (reading, backup) = try await onvif(camera).readInternetWatch(server: bridge)
        #expect(reading.state == .alreadyRight)
        #expect(reading.note == "Its DNS servers come from the router (DHCP): the router can change them when it renews the camera’s address.")
        #expect(backup?.fromDHCP == true)
        #expect(camera.setDNSBodies.value.isEmpty)
    }

    /// A camera that shows an emptied slot as 0.0.0.0: after Watch it asks only the bridge, and after Restore exactly its old server.
    @Test func anEmptiedSlotShownAsZerosIsEmpty() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.dnsSlots.set(.twoRefusingDuplicates)
        camera.emptySlotShownAs.set("0.0.0.0")
        camera.dns.set(MockONVIFCamera.DNS(fromDHCP: false, searchDomains: ["ipnc"], dhcpServers: [], manualServers: ["1.1.1.1", "8.8.8.8"]))
        let service = onvif(camera)
        #expect(try await service.applyDNS(server: bridge, readBack: brief) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(entries(camera) == [2, 1, 2], "the bridge twice (refused), the bridge alone (the old second server stays), then with an empty second slot")
        #expect(camera.dns.value.manualServers == [bridge, ""])
        #expect(try await service.readDNS()?.servers == [bridge])

        camera.dnsSlots.set(.two)
        camera.dns.update { $0.manualServers = [bridge, bridge] }
        let one = CameraDNSBackup(method: .onvifMinimal, fromDHCP: false, servers: ["1.1.1.1"], searchDomains: ["ipnc"])
        #expect(try await service.restoreDNS(one) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.dns.value.manualServers == ["1.1.1.1", ""])
    }

    // MARK: Hikvision ISAPI

    @Test func isapiDNSIsReadAndEditedInsideItsOwnElements() throws {
        let document = FakeSetupCamera.ipAddress()
        let read = try #require(HikvisionISAPI.dnsServers(in: document))
        #expect(read == ISAPIDNSServers(slots: ["8.8.8.8", "1.1.1.1"], addressingType: "static"))
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

    /// The reading carries the camera's address whole where the answer its servers came from shows it (ISAPI's address document; "Change it
    /// by hand" says to keep it and reserve it), and nothing where it does not: no other call is made for it.
    @Test func theReadingCarriesTheAddressItsAnswerShows() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        #expect(try await hikvision(camera).readDNS()?.addressing == hikvisionKeeps)
        camera.documents.update { $0[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress(gateway: "0.0.0.0") }
        #expect(try await hikvision(camera).readDNS()?.addressing == nil, "not whole: no gateway")

        let device = try await MockONVIFCamera.start()
        defer { device.stop() }
        let before = device.actions.value.count
        #expect(try #require(try await onvif(device).readDNS()).addressing == nil)
        #expect(!device.actions.value.dropFirst(before).contains("GetNetworkInterfaces"), "ONVIF's address is not asked for it")
    }

    /// Both slots are sent the bridge, and the read-back needs both: a camera that keeps its second server is refused, saying which.
    @Test func aHikvisionThatKeepsItsSecondServerIsRefusedInWordsThatSayWhatItKept() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        camera.keepSecondaryDNS.set(true)
        let service = hikvision(camera)
        #expect(try await service.applyDNS(server: bridge)
                == CameraSetupOutcome(succeeded: false, detail: "the camera asks Camera Bridge first but kept 1.1.1.1 as its other DNS server"))
        #expect(camera.puts(to: HikvisionISAPI.ipAddressPath) == [FakeSetupCamera.ipAddress(primaryDNS: bridge, secondaryDNS: bridge)])
        #expect(try await service.readDNS()?.servers == [bridge, "1.1.1.1"])
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

    /// A Hikvision on DHCP (`addressingType` dynamic) takes its DNS servers from the router: a DNS set on it would go back to the router's at
    /// the next renewal, so Watch on it would not last. Its reading says DHCP; the preview and the write are refused in words that say why and
    /// what to do, and nothing is written. One the router itself points at the bridge is right (the router can change it); Restore still puts
    /// a backup's servers back. A fixed or self-assigned (`apipa`) address is no DHCP.
    @Test func aDynamicHikvisionIsNotReportedWatchedOnADNSThatWontLast() async throws {
        var documents = FakeSetupCamera.defaultDocuments()
        documents[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress(addressing: "dynamic")
        let camera = try await FakeSetupCamera.start(documents: documents)
        defer { camera.stop() }
        let service = hikvision(camera)
        let words = "the camera takes its address from DHCP, so its DNS would go back to the router’s at the next renewal: choose “Fix its "
            + "address so the DNS stays”, or set it by hand with a fixed address"

        let read = try #require(try await service.readDNS())
        #expect(read.fromDHCP && read.servers == ["8.8.8.8", "1.1.1.1"] && read.method == .hikvisionISAPI)
        #expect(read.backup == CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: true, servers: ["8.8.8.8", "1.1.1.1"]))
        let (preview, backup) = try await service.readInternetWatch(server: bridge)
        #expect(preview == .notSupported(words), "not offered as a change that would not last")
        #expect(backup == read.backup)
        #expect(try await service.applyDNS(server: bridge) == CameraSetupOutcome(succeeded: false, detail: words))
        #expect(camera.puts(to: HikvisionISAPI.ipAddressPath).isEmpty, "no DNS that would not last is written")

        // The router hands it the bridge: right as it is, and the router can change it.
        camera.documents.update { $0[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress(addressing: "dynamic", primaryDNS: bridge, secondaryDNS: bridge) }
        let (already, _) = try await service.readInternetWatch(server: bridge)
        #expect(already == CameraSetupReading(state: .alreadyRight, note: CameraSettingsService.dnsFromRouterNote))
        #expect(try await service.applyDNS(server: bridge) == CameraSetupOutcome(succeeded: true, detail: "via ISAPI"))
        #expect(camera.puts(to: HikvisionISAPI.ipAddressPath).isEmpty)

        // Restore gives the camera its own servers back whatever its addressing now.
        #expect(try await service.restoreDNS(read.backup) == CameraSetupOutcome(succeeded: true, detail: "via ISAPI"))
        #expect(camera.documents.value[HikvisionISAPI.ipAddressPath] == FakeSetupCamera.ipAddress(addressing: "dynamic"))

        for addressing in ["static", "apipa"] {
            camera.documents.update { $0[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress(addressing: addressing) }
            let fixed = try #require(try await service.readDNS())
            #expect(!fixed.fromDHCP && !fixed.backup.fromDHCP, "\(addressing)")
            #expect(try await service.readInternetWatch(server: bridge).0.state == .willChange, "\(addressing)")
        }
        #expect(try await service.applyDNS(server: bridge).succeeded, "a fixed address takes the bridge")
    }

    /// An ISAPI write answered HTTP 403 is a change the account Camera Bridge uses may not make (Hikvision's `lowPrivilege`, or a 403 with no
    /// status at all): the camera signed the account in and read with it, so it is no refused login (nothing pauses the logins), and the step
    /// says to use an administrator account. On every ISAPI write the setup makes, and the restart. A 403 whose status says the camera has no
    /// such setting (`notSupport`) stays the camera's own words.
    @Test func a403IsNotPermittedNotALoginRefusal() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        let service = hikvision(camera)
        let notPermitted = CameraSetupOutcome(succeeded: false, detail: CameraAdapterError.notPermittedReason, notPermitted: true)

        for sub in ["lowPrivilege", ""] {
            camera.forbidPUT.set([HikvisionISAPI.ipAddressPath: sub])
            #expect(try await service.applyDNS(server: bridge) == notPermitted, "“\(sub)”")
        }
        let backup = CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: ["192.0.2.53", "192.0.2.54"])
        #expect(try await service.restoreDNS(backup) == notPermitted)

        // The setup's other ISAPI writes (the time zone, the time server, UPnP and the cloud) say so too, and the restart throws it.
        camera.forbidPUT.set([HikvisionISAPI.timePath: "lowPrivilege", HikvisionISAPI.ntpServerPath: "lowPrivilege",
                              "/ISAPI/System/Network/UPnP": "lowPrivilege", "/ISAPI/System/Network/EZVIZ": "lowPrivilege",
                              FakeSetupCamera.rebootPath: "lowPrivilege"])
        let steps: [(String, () async throws -> CameraSetupOutcome)] = [
            ("time zone", { try await service.applyTimeZone(posix: "MST7MDT,M3.2.0,M11.1.0") }),
            ("time server", { try await service.applyTimeSource(server: self.bridge) }),
            ("UPnP", { try await service.setFeature(.upnp, enabled: false) }),
            ("cloud", { try await service.setFeature(.cloud, enabled: false) }),
        ]
        for (name, step) in steps { #expect(try await step() == notPermitted, "\(name)") }
        let refused = await #expect(throws: CameraAdapterError.self) { try await service.reboot() }
        #expect(refused.map { CameraAdapterError.isNotPermitted($0) && !$0.isLoginRefusal } == true, "\(String(describing: refused))")
        #expect(camera.restarts == 1, "asked once, refused: never again")
        // ISAPI's other writes (the streams, the clean picture, a keyframe request) throw it too.
        camera.forbidPUT.set(["/ISAPI/Streaming/channels/101": ""])
        await #expect(throws: CameraAdapterError.notPermitted("PUT /ISAPI/Streaming/channels/101")) {
            try await service.setHikvisionSmartCodec(enabled: false, channelID: "101")
        }

        // "Not supported" in a 403 is the camera's answer about the setting, in its words.
        camera.forbidPUT.set([HikvisionISAPI.ipAddressPath: "notSupport"])
        #expect(try await service.applyDNS(server: bridge) == CameraSetupOutcome(succeeded: false, detail: "Invalid Operation (notSupport)"))
        #expect(!camera.server.requests.contains { $0.path.contains("onvif") }, "a Hikvision is not asked through ONVIF")
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

    // MARK: Fix its address so the DNS stays (opt-in)

    /// The Hikvision fake's own address on DHCP, and the ONVIF fake's: what the choice keeps; the bridge on their network.
    private let hikvisionKeeps = CameraAddressing(address: "192.168.77.30", subnetMask: "255.255.255.0", gateway: "192.168.77.1")
    private let onvifKeeps = CameraAddressing(address: "192.168.77.22", subnetMask: "255.255.255.0", gateway: "192.168.77.1", interface: "eth0")
    private let local = "192.168.77.2"

    private func dynamicHikvision() async throws -> FakeSetupCamera {
        var documents = FakeSetupCamera.defaultDocuments()
        documents[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress(addressing: "dynamic")
        return try await FakeSetupCamera.start(documents: documents)
    }

    /// "Fix its address so the DNS stays" is offered where the camera's DNS only stays with a fixed address: a Hikvision on DHCP, and an ONVIF
    /// camera on DHCP whose DNS set by hand was refused (its last run said so). Not for a fixed address, a camera that already asks the bridge,
    /// one whose own address is not the one Camera Bridge knows it by, nor without that address. The offer keeps the camera's address, mask and
    /// gateway as they are, with its hardware address for the router reservation and the way it is fixed; a reading writes nothing.
    @Test func theChoiceIsOfferedOnlyWhereDNSNeedsAFixedAddress() async throws {
        let camera = try await dynamicHikvision()
        defer { camera.stop() }
        let service = hikvision(camera)
        let (reading, backup) = try await service.readInternetWatch(server: local, cameraAddress: "192.168.77.30")
        #expect(reading.state == .notSupported(CameraSettingsService.hikvisionDHCPRefusal), "without the choice nothing is written")
        var keeps = hikvisionKeeps
        keeps.hardwareAddress = FakeSetupCamera.hardwareAddress
        #expect(reading.fixAddress == CameraSetupFixAddress(addressing: keeps, changes: [
            CameraSetupChange(label: "Address", now: "192.168.77.30 from the router (DHCP)",
                              after: "192.168.77.30, fixed (mask 255.255.255.0, gateway 192.168.77.1)"),
            CameraSetupChange(label: "DNS", now: "8.8.8.8 and 1.1.1.1 from the router (DHCP)", after: "the bridge (\(local))"),
        ], method: .hikvisionISAPI))
        #expect(backup?.fixedAddress == nil, "a reading fixes nothing")
        #expect(try await service.readInternetWatch(server: local).0.fixAddress == nil, "no address to compare with")
        #expect(try await service.readInternetWatch(server: local, cameraAddress: "192.168.77.31").0.fixAddress == nil, "another address")

        camera.documents.update { $0[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress() }
        let fixed = try await service.readInternetWatch(server: local, cameraAddress: "192.168.77.30").0
        #expect(fixed.state == .willChange && fixed.fixAddress == nil, "a fixed address takes the DNS as it is")
        camera.documents.update { $0[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress(addressing: "dynamic", primaryDNS: local, secondaryDNS: local) }
        #expect(try await service.readInternetWatch(server: local, cameraAddress: "192.168.77.30").0
                == CameraSetupReading(state: .alreadyRight, note: CameraSettingsService.dnsFromRouterNote))
        #expect(camera.puts.value.isEmpty)

        // ONVIF on DHCP: its DNS alone first; once that was refused, the fixed address.
        let device = try await MockONVIFCamera.start()
        defer { device.stop() }
        let onvif = onvif(device)
        let first = try await onvif.readInternetWatch(server: local, cameraAddress: "192.168.77.22")
        #expect(first.0.state == .willChange && first.0.fixAddress == nil)
        let offer = try #require(try await onvif.readInternetWatch(server: local, cameraAddress: "192.168.77.22", refusedBefore: true).0.fixAddress)
        var onvifOffer = onvifKeeps
        onvifOffer.hardwareAddress = MockONVIFCamera.hardwareAddress
        #expect(offer.addressing == onvifOffer && offer.method == .onvifMinimal)
        #expect(offer.changes.first == CameraSetupChange(label: "Address", now: "192.168.77.22 from the router (DHCP)",
                                                         after: "192.168.77.22, fixed (mask 255.255.255.0, gateway 192.168.77.1)"))
        device.ipv4.update { $0.dhcp = false }
        #expect(try await onvif.readInternetWatch(server: local, cameraAddress: "192.168.77.22", refusedBefore: true).0.fixAddress == nil,
                "an interface with a fixed address")
        device.ipv4.update { $0.dhcp = true }
        device.dns.set(MockONVIFCamera.DNS(fromDHCP: false, searchDomains: [], dhcpServers: [], manualServers: ["1.1.1.1"]))
        #expect(try await onvif.readInternetWatch(server: local, cameraAddress: "192.168.77.22", refusedBefore: true).0.fixAddress == nil,
                "DNS set by hand: a DHCP address is not why it was refused")
        #expect(device.setNetworkInterfacesBodies.value.isEmpty && device.setDNSBodies.value.isEmpty)
    }

    /// The choice is never a guess: it needs the camera's whole address (an IPv4 address, a mask, a gateway that is one and on its network),
    /// Camera Bridge on that network too, and an ONVIF camera's lease as DHCP gave it. A hardware address the camera does not show is left
    /// out of the offer.
    @Test func theChoiceNeedsTheWholeAddress() async throws {
        let camera = try await dynamicHikvision()
        defer { camera.stop() }
        let service = hikvision(camera)
        let offered = { try await service.readInternetWatch(server: self.local, cameraAddress: "192.168.77.30").0.fixAddress }
        for (document, why) in [(FakeSetupCamera.ipAddress(addressing: "dynamic", subnetMask: ""), "no mask"),
                                (FakeSetupCamera.ipAddress(addressing: "dynamic", subnetMask: "255.0.255.0"), "not a mask"),
                                (FakeSetupCamera.ipAddress(addressing: "dynamic", subnetMask: "255.255.255.255"), "a /32 from a stale document"),
                                (FakeSetupCamera.ipAddress(addressing: "dynamic", gateway: ""), "no gateway"),
                                (FakeSetupCamera.ipAddress(addressing: "dynamic", gateway: "0.0.0.0"), "an empty gateway"),
                                (FakeSetupCamera.ipAddress(addressing: "dynamic", gateway: "192.168.78.1"), "a gateway on another network"),
                                (FakeSetupCamera.ipAddress(addressing: "dynamic", address: "0.0.0.0"), "no address yet")] {
            camera.documents.update { $0[HikvisionISAPI.ipAddressPath] = document }
            #expect(try await offered() == nil, "\(why)")
        }
        camera.documents.update { $0[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress(addressing: "dynamic"); $0[HikvisionISAPI.interfacePath] = nil }
        #expect(try await offered()?.addressing == hikvisionKeeps, "offered without the hardware address it does not show")
        #expect(try await service.readInternetWatch(server: "192.168.78.2", cameraAddress: "192.168.77.30").0.fixAddress == nil,
                "Camera Bridge off the camera's network")
        #expect(try await service.applyDNS(server: "192.168.78.2", fixingAddress: hikvisionKeeps)
                == CameraSetupOutcome(succeeded: false, detail: "Camera Bridge (192.168.78.2) is not on the camera’s network as the camera has it "
                    + "(192.168.77.30, mask 255.255.255.0), so Camera Bridge changed nothing", addressUntouched: true))
        #expect(camera.puts.value.isEmpty)

        let device = try await MockONVIFCamera.start()
        defer { device.stop() }
        let onvif = onvif(device)
        let onvifOffered = { try await onvif.readInternetWatch(server: self.local, cameraAddress: "192.168.77.22", refusedBefore: true).0.fixAddress }
        device.hidesHardwareAddress.set(true)
        #expect(try await onvifOffered()?.addressing == onvifKeeps)
        device.gateways.set([])
        #expect(try await onvifOffered() == nil, "no gateway")
        device.gateways.set(["192.168.77.1"])
        let interface = { (config: String) in
            "<tds:GetNetworkInterfacesResponse><tds:NetworkInterfaces token=\"eth0\"><tt:Enabled>true</tt:Enabled><tt:IPv4><tt:Enabled>true</tt:Enabled>"
                + "<tt:Config>\(config)</tt:Config></tt:IPv4></tds:NetworkInterfaces></tds:GetNetworkInterfacesResponse>"
        }
        for (answer, why) in [(interface("<tt:FromDHCP><tt:Address>192.168.77.22</tt:Address></tt:FromDHCP><tt:DHCP>true</tt:DHCP>"), "a lease without its prefix"),
                              (interface("<tt:Manual><tt:Address>192.168.77.22</tt:Address><tt:PrefixLength>24</tt:PrefixLength></tt:Manual><tt:DHCP>true</tt:DHCP>"),
                               "on DHCP without the lease: the address set by hand may not be the one in use")] {
            device.interfacesOverride.set(answer)
            #expect(try await onvifOffered() == nil, "\(why)")
        }
    }

    /// A Hikvision's address document goes back whole with `addressingType` static and both DNS servers the bridge: its address, mask and
    /// gateway exactly as they were. An ONVIF camera gets `SetNetworkInterfaces` (DHCP off, the address and prefix it has), its gateway as it
    /// was, then `SetDNS`, each read back. A camera that takes the address after a restart ("Reboot Required", `RebootNeeded`) is done
    /// waiting for it; Camera Bridge never restarts it.
    @Test func fixingKeepsTheSameAddressMaskAndGateway() async throws {
        let camera = try await dynamicHikvision()
        defer { camera.stop() }
        let service = hikvision(camera)
        #expect(try await service.applyDNS(server: local, fixingAddress: hikvisionKeeps)
                == CameraSetupOutcome(succeeded: true, detail: "via ISAPI", addressFixed: true))
        #expect(camera.puts(to: HikvisionISAPI.ipAddressPath) == [FakeSetupCamera.ipAddress(addressing: "static", primaryDNS: local, secondaryDNS: local)],
                "one write: the same address, mask and gateway, fixed, and the bridge in both slots")
        #expect(try await service.readDNS()?.pointsAt(local) == true)

        camera.documents.update { $0[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress(addressing: "dynamic") }
        camera.rebootRequired.update { $0.insert(HikvisionISAPI.ipAddressPath) }
        #expect(try await service.applyDNS(server: local, fixingAddress: hikvisionKeeps)
                == CameraSetupOutcome(succeeded: true, needsRestart: true, detail: "via ISAPI", addressFixed: true))
        #expect(camera.restarts == 0, "Camera Bridge never restarts the camera")

        let device = try await MockONVIFCamera.start()
        defer { device.stop() }
        let onvif = onvif(device)
        #expect(try await onvif.applyDNS(server: local, fixingAddress: onvifKeeps, readBack: quick)
                == CameraSetupOutcome(succeeded: true, detail: "via ONVIF", addressFixed: true))
        #expect(device.setNetworkInterfacesBodies.value.count == 1)
        #expect(device.setNetworkInterfacesBodies.value.first?.contains("<tds:SetNetworkInterfaces><tds:InterfaceToken>eth0</tds:InterfaceToken>"
            + "<tds:NetworkInterface><tt:Enabled>true</tt:Enabled><tt:IPv4><tt:Enabled>true</tt:Enabled><tt:Manual><tt:Address>192.168.77.22</tt:Address>"
            + "<tt:PrefixLength>24</tt:PrefixLength></tt:Manual><tt:DHCP>false</tt:DHCP></tt:IPv4></tds:NetworkInterface></tds:SetNetworkInterfaces>") == true)
        #expect(device.ipv4.value == MockONVIFCamera.IPv4(dhcp: false, address: "192.168.77.22", prefixLength: 24), "the same address and prefix, fixed")
        #expect(device.setGatewayBodies.value.first?.contains(
            "<tds:SetNetworkDefaultGateway><tds:IPv4Address>192.168.77.1</tds:IPv4Address></tds:SetNetworkDefaultGateway>") == true)
        #expect(device.gateways.value == ["192.168.77.1"], "the gateway as it was")
        #expect(device.dns.value == MockONVIFCamera.DNS(fromDHCP: false, searchDomains: ["domain.name"], manualServers: [local, local]))
        let order = device.actions.value.filter { ["SetNetworkInterfaces", "SetNetworkDefaultGateway", "SetDNS"].contains($0) }
        #expect(order == ["SetNetworkInterfaces", "SetNetworkDefaultGateway", "SetDNS"])

        let later = try await MockONVIFCamera.start()
        defer { later.stop() }
        later.networkRebootNeeded.set(true)
        #expect(try await self.onvif(later).applyDNS(server: local, fixingAddress: onvifKeeps, readBack: quick)
                == CameraSetupOutcome(succeeded: true, needsRestart: true, detail: "via ONVIF", addressFixed: true))
        #expect(later.systemRebootCalled.value == 0, "Camera Bridge never restarts the camera")
        #expect(later.setGatewayBodies.value.count == 1 && later.setDNSBodies.value.count == 1)
    }

    /// The camera's address is read again just before the write: one DHCP has changed since the preview (or one fixed by hand meanwhile) is
    /// refused in plain words, and nothing is written; so is a gateway the request could not carry back.
    @Test func anAddressThatChangedSinceThePreviewIsNotWritten() async throws {
        let camera = try await dynamicHikvision()
        defer { camera.stop() }
        let service = hikvision(camera)
        let words = CameraSettingsService.addressChangedRefusal(hikvisionKeeps)
        #expect(words == "the camera’s address is no longer the one the preview showed (192.168.77.30, mask 255.255.255.0, gateway 192.168.77.1 from "
                + "the router), so Camera Bridge changed nothing: open “Set up for Camera Bridge” again to see it as it is now")
        for document in [FakeSetupCamera.ipAddress(addressing: "dynamic", address: "192.168.77.31"),
                         FakeSetupCamera.ipAddress(addressing: "dynamic", gateway: "192.168.77.254"),
                         FakeSetupCamera.ipAddress(addressing: "static")] {
            camera.documents.update { $0[HikvisionISAPI.ipAddressPath] = document }
            #expect(try await service.applyDNS(server: local, fixingAddress: hikvisionKeeps) == CameraSetupOutcome(succeeded: false, detail: words, addressUntouched: true))
        }
        #expect(camera.puts.value.isEmpty)

        let device = try await MockONVIFCamera.start()
        defer { device.stop() }
        let onvif = onvif(device)
        device.ipv4.update { $0.address = "192.168.77.23" }
        #expect(try await onvif.applyDNS(server: local, fixingAddress: onvifKeeps, readBack: quick)
                == CameraSetupOutcome(succeeded: false, detail: CameraSettingsService.addressChangedRefusal(onvifKeeps), addressUntouched: true))
        device.ipv4.update { $0.address = "192.168.77.22" }
        device.gateways.set(["192.168.77.254"])
        #expect(try await onvif.applyDNS(server: local, fixingAddress: onvifKeeps, readBack: quick).detail == CameraSettingsService.addressChangedRefusal(onvifKeeps))
        device.gateways.set(["192.168.77.1", "gateway.local"])   // a second entry the gateway request could not carry back
        #expect(try await onvif.applyDNS(server: local, fixingAddress: onvifKeeps, readBack: quick)
                == CameraSetupOutcome(succeeded: false, detail: "the camera shows a gateway that is not an address", addressUntouched: true))
        #expect(device.setNetworkInterfacesBodies.value.isEmpty && device.setGatewayBodies.value.isEmpty && device.setDNSBodies.value.isEmpty)
    }

    /// Restore after the choice puts DHCP back with the DNS servers as they were, also when the camera's DNS was changed by hand since; a
    /// camera already back on DHCP has only its DNS servers put back. One whose address was changed by hand since is left as it is, said so.
    @Test func restorePutsDHCPBack() async throws {
        let camera = try await dynamicHikvision()
        defer { camera.stop() }
        let service = hikvision(camera)
        var backup = try #require(try await service.readInternetWatch(server: local, cameraAddress: "192.168.77.30").1)
        backup.fixedAddress = hikvisionKeeps   // what the run saves before it changes anything
        backup.fixedAddressMethod = .hikvisionISAPI
        #expect(try await service.applyDNS(server: local, fixingAddress: hikvisionKeeps).succeeded)
        camera.documents.update { $0[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress(addressing: "static", primaryDNS: "192.168.77.53", secondaryDNS: "192.168.77.53") }
        #expect(try await service.restoreDNS(backup) == CameraSetupOutcome(succeeded: true, detail: "via ISAPI"))
        #expect(camera.documents.value[HikvisionISAPI.ipAddressPath] == FakeSetupCamera.ipAddress(addressing: "dynamic"), "DHCP and its own servers back")
        #expect(try await service.restoreDNS(backup) == CameraSetupOutcome(succeeded: true, detail: "via ISAPI"), "already on DHCP")
        camera.documents.update { $0[HikvisionISAPI.ipAddressPath] = FakeSetupCamera.ipAddress(addressing: "static", address: "192.168.77.40") }
        let writes = camera.puts.value.count
        #expect(try await service.restoreDNS(backup)
                == CameraSetupOutcome(succeeded: false, detail: CameraSettingsService.addressChangedSinceFixed(hikvisionKeeps)))
        #expect(camera.puts.value.count == writes, "an address set by hand since is left as it is")
        #expect(CameraSettingsService.addressChangedSinceFixed(hikvisionKeeps)
                == "the camera’s address was changed since Camera Bridge fixed it at 192.168.77.30, so Camera Bridge left its network settings as they are")

        let device = try await MockONVIFCamera.start()
        defer { device.stop() }
        let onvif = onvif(device)
        var onvifBackup = try #require(try await onvif.readInternetWatch(server: local, cameraAddress: "192.168.77.22", refusedBefore: true).1)
        onvifBackup.fixedAddress = onvifKeeps
        onvifBackup.fixedAddressMethod = .onvifMinimal
        #expect(try await onvif.applyDNS(server: local, fixingAddress: onvifKeeps, readBack: quick).succeeded)
        device.dns.update { $0.manualServers = ["192.168.77.53"] }   // changed by hand since
        #expect(try await onvif.restoreDNS(onvifBackup, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(device.ipv4.value == MockONVIFCamera.IPv4(), "back on DHCP")
        #expect(device.dns.value.fromDHCP, "its DNS servers from DHCP, as they were")
        #expect(device.setNetworkInterfacesBodies.value.last?.contains(
            "<tt:IPv4><tt:Enabled>true</tt:Enabled><tt:DHCP>true</tt:DHCP></tt:IPv4>") == true)
        let dnsFirst = device.actions.value.filter { ["SetNetworkInterfaces", "SetDNS"].contains($0) }.suffix(2)
        #expect(Array(dnsFirst) == ["SetDNS", "SetNetworkInterfaces"], "the DNS first, DHCP last (it may move the camera)")
        device.ipv4.update { $0 = MockONVIFCamera.IPv4(dhcp: false, address: "192.168.77.40", prefixLength: 24) }
        let sent = device.setNetworkInterfacesBodies.value.count
        #expect(try await onvif.restoreDNS(onvifBackup, readBack: quick)
                == CameraSetupOutcome(succeeded: false, detail: CameraSettingsService.addressChangedSinceFixed(onvifKeeps)))
        #expect(device.setNetworkInterfacesBodies.value.count == sent, "an address set by hand since is left as it is")
    }

    /// Restore puts DHCP back the way the address was fixed, whatever way the DNS servers were read: the backup an earlier run saved through
    /// ONVIF, which this run's fix through ISAPI joined (the merge `offByDefault` builds), goes back through ISAPI; its DNS servers, from
    /// DHCP, come back with the address.
    @Test func restorePutsDHCPBackWhicheverWayTheDNSWasRead() async throws {
        let camera = try await dynamicHikvision()
        defer { camera.stop() }
        let service = hikvision(camera)
        #expect(try await service.applyDNS(server: local, fixingAddress: hikvisionKeeps).succeeded)
        let merged = CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], fixedAddress: hikvisionKeeps, fixedAddressMethod: .hikvisionISAPI)
        #expect(try await service.restoreDNS(merged) == CameraSetupOutcome(succeeded: true, detail: "via ISAPI"))
        #expect(camera.documents.value[HikvisionISAPI.ipAddressPath] == FakeSetupCamera.ipAddress(addressing: "dynamic", primaryDNS: local, secondaryDNS: local),
                "on DHCP again; the slots as they were left (DHCP's servers come with the address)")
        #expect(try await service.restoreDNS(merged) == CameraSetupOutcome(succeeded: true, detail: "via ISAPI"), "on DHCP already: nothing left to put back")
        #expect(!camera.server.requests.contains { $0.path.contains("onvif") }, "nothing is asked through ONVIF")
    }

    /// An ONVIF fix that stopped part-way still puts DHCP back: the interface write the camera did not take (it stays on DHCP), a gateway it
    /// dropped and did not take back (only the address and prefix are compared, the missing gateway is Camera Bridge's own change), and an
    /// address waiting for a restart (undone with DHCP on). A camera that keeps its fixed address is said so, its DNS servers back; DHCP comes
    /// back even when the DNS part is refused.
    @Test func restoreAfterAPartialONVIFFixPutsDHCPBack() async throws {
        func backup(_ device: MockONVIFCamera) -> CameraDNSBackup {
            CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], searchDomains: ["domain.name"], fixedAddress: onvifKeeps,
                            fixedAddressMethod: .onvifMinimal)
        }
        // The interface write not taken.
        let ignoring = try await MockONVIFCamera.start()
        defer { ignoring.stop() }
        ignoring.ignoreNetworkChanges.set(true)
        #expect(try await onvif(ignoring).applyDNS(server: local, fixingAddress: onvifKeeps, readBack: brief)
                == CameraSetupOutcome(succeeded: false, detail: CameraSettingsService.addressNotFixed))
        #expect(try await onvif(ignoring).restoreDNS(backup(ignoring), readBack: brief) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(ignoring.ipv4.value.dhcp && ignoring.setNetworkInterfacesBodies.value.last?.contains("<tt:DHCP>true</tt:DHCP>") == true)

        // The gateway dropped and not taken back.
        let dropping = try await MockONVIFCamera.start()
        defer { dropping.stop() }
        dropping.dropsGatewayWhenFixed.set(true)
        dropping.ignoreGatewayChanges.set(true)
        #expect(try await onvif(dropping).applyDNS(server: local, fixingAddress: onvifKeeps, readBack: quick)
                == CameraSetupOutcome(succeeded: false, detail: "the camera did not keep its gateway (192.168.77.1)", addressFixed: true))
        #expect(!dropping.ipv4.value.dhcp && dropping.gateways.value.isEmpty)
        #expect(try await onvif(dropping).restoreDNS(backup(dropping), readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(dropping.ipv4.value == MockONVIFCamera.IPv4() && dropping.gateways.value == ["192.168.77.1"], "DHCP gives its gateway back")

        // Waiting for a restart: DHCP on again undoes the address it would take.
        let waiting = try await MockONVIFCamera.start()
        defer { waiting.stop() }
        waiting.networkRebootNeeded.set(true)
        #expect(try await onvif(waiting).applyDNS(server: local, fixingAddress: onvifKeeps, readBack: quick).needsRestart)
        #expect(try await onvif(waiting).restoreDNS(backup(waiting), readBack: quick) == CameraSetupOutcome(succeeded: true, needsRestart: true, detail: "via ONVIF"))
        #expect(waiting.setNetworkInterfacesBodies.value.count == 2 && waiting.setNetworkInterfacesBodies.value.last?.contains("<tt:DHCP>true</tt:DHCP>") == true)

        // Not back on DHCP, and DHCP back although the DNS part is refused.
        let keeping = try await MockONVIFCamera.start()
        defer { keeping.stop() }
        #expect(try await onvif(keeping).applyDNS(server: local, fixingAddress: onvifKeeps, readBack: quick).succeeded)
        keeping.ignoreNetworkChanges.set(true)
        #expect(try await onvif(keeping).restoreDNS(backup(keeping), readBack: brief) == CameraSetupOutcome(succeeded: false, detail: CameraSettingsService.addressNotBackOnDHCP))
        #expect(keeping.dns.value.fromDHCP, "its DNS servers went back first")
        keeping.ignoreNetworkChanges.set(false)
        keeping.dns.set(MockONVIFCamera.DNS(fromDHCP: false, searchDomains: ["domain.name"], dhcpServers: [], manualServers: [local, local]))
        keeping.refuseDNSChanges.set(true)
        let refused = try await onvif(keeping).restoreDNS(backup(keeping), readBack: brief)
        #expect(!refused.succeeded && refused.detail.contains("InvalidArgVal"), "\(refused)")
        #expect(keeping.ipv4.value == MockONVIFCamera.IPv4(), "DHCP back all the same")
    }

    /// An ONVIF camera on DHCP whose DNS set by hand does not stay is refused in words that say the next run can fix its address, only where
    /// that run would offer it: its lease whole and the address Camera Bridge knows it by, the bridge on its network. Not one with DNS set
    /// by hand, nor a change the account may not make.
    @Test func aRefusedWatchOnDHCPSaysTheAddressCanBeFixed() async throws {
        let device = try await MockONVIFCamera.start()
        defer { device.stop() }
        device.ignoreDNSChanges.set(true)
        let kept = "the camera kept its own DNS servers"
        #expect(try await onvif(device).applyDNS(server: local, readBack: brief, cameraAddress: "192.168.77.22")
                == CameraSetupOutcome(succeeded: false, detail: "\(kept). Open “Set up for Camera Bridge” again to fix its address so the DNS stays"))
        #expect(try await onvif(device).applyDNS(server: local, readBack: brief) == .refused(kept), "no address Camera Bridge knows it by")
        #expect(try await onvif(device).applyDNS(server: local, readBack: brief, cameraAddress: "192.168.77.23") == .refused(kept), "another address")
        #expect(try await onvif(device).applyDNS(server: bridge, readBack: brief, cameraAddress: "192.168.77.22") == .refused(kept),
                "the bridge off its network")
        device.gateways.set([])
        #expect(try await onvif(device).applyDNS(server: local, readBack: brief, cameraAddress: "192.168.77.22") == .refused(kept), "no gateway")
        device.gateways.set(["192.168.77.1"])
        device.dns.set(MockONVIFCamera.DNS(fromDHCP: false, searchDomains: [], dhcpServers: [], manualServers: ["1.1.1.1"]))
        #expect(try await onvif(device).applyDNS(server: local, readBack: brief, cameraAddress: "192.168.77.22") == .refused(kept), "DNS set by hand")
        device.dns.set(MockONVIFCamera.DNS())
        device.dnsFaults.set(["NotAuthorized"])
        device.ignoreDNSChanges.set(false)
        #expect(try await onvif(device).applyDNS(server: local, readBack: brief, cameraAddress: "192.168.77.22")
                == CameraSetupOutcome(succeeded: false, detail: CameraAdapterError.notPermittedReason, notPermitted: true))
    }

    /// A fix whose first write the camera refused changed nothing (`addressUntouched`), and Restore still succeeds: the interface on DHCP,
    /// the camera refusing `SetNetworkInterfaces` again, the DNS servers alone decide.
    @Test func aFixRefusedAtItsFirstWriteChangesNothingAndRestoreSucceeds() async throws {
        let device = try await MockONVIFCamera.start()
        defer { device.stop() }
        device.networkInterfacesFault.set("InvalidArgVal")
        let fix = try await onvif(device).applyDNS(server: local, fixingAddress: onvifKeeps, readBack: quick)
        #expect(!fix.succeeded && fix.addressUntouched && !fix.addressFixed && fix.detail.contains("InvalidArgVal"), "\(fix)")
        #expect(device.setGatewayBodies.value.isEmpty && device.setDNSBodies.value.isEmpty, "nothing after the refused first write")
        let backup = CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], searchDomains: ["domain.name"], fixedAddress: onvifKeeps,
                                     fixedAddressMethod: .onvifMinimal)
        #expect(try await onvif(device).restoreDNS(backup, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(device.setNetworkInterfacesBodies.value.count == 2, "DHCP on was asked, and refused")
        // A refusal before any write is untouched too; one after a write the camera took is not.
        #expect(try await onvif(device).applyDNS(server: "192.0.2.10", fixingAddress: onvifKeeps, readBack: quick).addressUntouched)
        device.networkInterfacesFault.set(nil)
        device.ignoreGatewayChanges.set(true)
        device.dropsGatewayWhenFixed.set(true)
        let partial = try await onvif(device).applyDNS(server: local, fixingAddress: onvifKeeps, readBack: quick)
        #expect(!partial.succeeded && !partial.addressUntouched && partial.addressFixed)
    }

    /// A 2xx answer to the fix's first write that the client can't read (not a fault, not a refusal) may be one the camera applied: the
    /// address it was fixed at stays in the backup (`addressUntouched` false), so Restore can put DHCP back.
    @Test func anUnreadableAnswerToTheFixsFirstWriteKeepsTheAddressToPutBack() async throws {
        let device = try await MockONVIFCamera.start()
        defer { device.stop() }
        device.networkInterfacesUnreadable.set(true)
        let fix = try await onvif(device).applyDNS(server: local, fixingAddress: onvifKeeps, readBack: quick)
        #expect(!fix.succeeded && !fix.addressUntouched && !fix.addressFixed, "\(fix)")
        #expect(!device.ipv4.value.dhcp, "the camera did take it")
    }

    /// Restore whose DNS part is refused while DHCP comes back only at the camera's restart (`RebootNeeded`) says so and waits for it.
    @Test func aRestoreWhoseDHCPWaitsForARestartSaysSo() async throws {
        let device = try await MockONVIFCamera.start()
        defer { device.stop() }
        #expect(try await onvif(device).applyDNS(server: local, fixingAddress: onvifKeeps, readBack: quick).succeeded)
        device.networkRebootNeeded.set(true)
        device.refuseDNSChanges.set(true)
        let backup = CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], searchDomains: ["domain.name"], fixedAddress: onvifKeeps,
                                     fixedAddressMethod: .onvifMinimal)
        let restored = try await onvif(device).restoreDNS(backup, readBack: brief)
        #expect(!restored.succeeded && restored.needsRestart, "\(restored)")
        #expect(restored.detail.hasSuffix(". The camera takes its address from DHCP again once it restarts") && restored.detail.contains("InvalidArgVal"))
        #expect(device.systemRebootCalled.value == 0)
    }

    @Test func aBackupIsSavedAndReadBack() throws {
        let backup = CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: ["2001:db8::53"], searchDomains: ["domain.name"])
        #expect(try JSONDecoder().decode(CameraDNSBackup.self, from: JSONEncoder().encode(backup)) == backup)
        let older = try JSONDecoder().decode(CameraDNSBackup.self, from: Data(#"{"method":"hikvisionISAPI","fromDHCP":false,"servers":["8.8.8.8"]}"#.utf8))
        #expect(older == CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: ["8.8.8.8"]), "search domains are optional")
        let own = CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], searchDomains: ["domain.name"],
                                  ownAPI: ["ondhcp": "1", "dns1": "1.1.1.1", "dns2": "8.8.8.8"])
        #expect(try JSONDecoder().decode(CameraDNSBackup.self, from: JSONEncoder().encode(own)) == own)
        #expect(older.ownAPI == nil, "a backup saved before the camera's own API was read has none")
    }
}
#endif
