import BridgeSupport
import CameraAdapters
import Foundation
import Testing
@testable import BridgeEngine

/// What the network does to Apple Home devices (`NetworkNotice`): this Mac on a VPN (`MacVPNDetector`), the notice log
/// (one per device, an hour of life), and what the diagnostics report says about it.
@Suite struct NetworkNoticeTests {
    // MARK: This Mac on a VPN

    private func lan() -> [InterfaceAddress] {
        [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
         InterfaceAddress(interface: "en0", address: "192.0.2.5", prefixLength: 24),
         InterfaceAddress(interface: "en0", address: "fe80::aa:bb", prefixLength: 64),
         InterfaceAddress(interface: "utun0", address: "fe80::1", prefixLength: 64),
         InterfaceAddress(interface: "utun1", address: "fe80::2", prefixLength: 64)]
    }

    @Test func aMacWithoutATunnelIsNotOnAVPN() {
        #expect(MacVPNDetector.detect(interfaces: lan(), defaultRouteInterfaces: ["en0"]) == nil)
        #expect(MacVPNDetector.detect(interfaces: lan(), defaultRouteInterfaces: nil) == nil, "the system's own utun, link-local only")
        #expect(MacVPNDetector.detect(interfaces: [], defaultRouteInterfaces: []) == nil)
    }

    @Test func aTunnelThatCarriesTheDefaultRouteIsAVPN() {
        let interfaces = lan() + [InterfaceAddress(interface: "utun4", address: "10.8.0.6", prefixLength: 32)]
        let status = MacVPNDetector.detect(interfaces: interfaces, defaultRouteInterfaces: ["utun4"])
        #expect(status == MacVPNStatus(interface: "utun4", address: "10.8.0.6", reason: .defaultRoute))
        // The same tunnel without the default route (a split tunnel, Tailscale without an exit node) is none.
        #expect(MacVPNDetector.detect(interfaces: interfaces, defaultRouteInterfaces: ["en0"]) == nil)
        // Without a readable routing table an addressed IPv4 tunnel counts.
        #expect(MacVPNDetector.detect(interfaces: interfaces, defaultRouteInterfaces: nil)?.reason == .tunnelInterface)
        // WireGuard and IPsec interfaces too.
        let wireGuard = lan() + [InterfaceAddress(interface: "wg0", address: "10.66.66.2", prefixLength: 32)]
        #expect(MacVPNDetector.detect(interfaces: wireGuard, defaultRouteInterfaces: ["wg0"])?.interface == "wg0")
        let ipsec = lan() + [InterfaceAddress(interface: "ipsec0", address: "172.20.1.9", prefixLength: 32)]
        #expect(MacVPNDetector.detect(interfaces: ipsec, defaultRouteInterfaces: ["ipsec0"])?.interface == "ipsec0")
    }

    @Test func aNordLynxAddressIsAVPNEvenWhenTheDefaultRouteStaysOnTheLAN() {
        let interfaces = lan() + [InterfaceAddress(interface: "utun5", address: "10.5.0.2", prefixLength: 32)]
        let status = MacVPNDetector.detect(interfaces: interfaces, defaultRouteInterfaces: ["en0"])
        #expect(status == MacVPNStatus(interface: "utun5", address: "10.5.0.2", reason: .nordLynxAddress))
        // 10.5.x.x on a LAN interface is a LAN, not a tunnel.
        let homeNet = [InterfaceAddress(interface: "en0", address: "10.5.0.20", prefixLength: 16)]
        #expect(MacVPNDetector.detect(interfaces: homeNet, defaultRouteInterfaces: ["en0"]) == nil)
    }

    @Test func aTunnelNeedsAddressesOfItsOwn() {
        let selfAssigned = [InterfaceAddress(interface: "utun2", address: "169.254.10.3", prefixLength: 16)]
        #expect(MacVPNDetector.detect(interfaces: selfAssigned, defaultRouteInterfaces: nil) == nil)
        let global = [InterfaceAddress(interface: "utun3", address: "2001:db8::2", prefixLength: 64)]
        #expect(MacVPNDetector.detect(interfaces: global, defaultRouteInterfaces: ["utun3"])?.interface == "utun3")
    }

    /// One route message as the kernel dumps it: the 92-byte header, then the destination and the netmask (cut off after
    /// its last non-zero byte), each padded to 4 bytes.
    private func routeMessage(destination: [UInt8], mask: [UInt8]?, interfaceIndex: Int, flags: Int32 = 0x1 | 0x2) -> [UInt8] {
        func sockaddr(_ address: [UInt8], length: Int) -> [UInt8] {
            var bytes = [UInt8(length), UInt8(AF_INET), 0, 0] + address
            bytes += [UInt8](repeating: 0, count: max(0, length - bytes.count))
            let padded = length == 0 ? 4 : 1 + ((length - 1) | 3)
            return bytes + [UInt8](repeating: 0, count: padded - bytes.count)
        }
        var addresses: Int32 = 1
        var payload = sockaddr(destination, length: 16)
        if let mask {
            addresses |= 4
            payload += sockaddr(mask, length: 4 + mask.count)
        }
        var header = [UInt8](repeating: 0, count: 92)
        let length = 92 + payload.count
        header[0] = UInt8(length & 0xFF); header[1] = UInt8(length >> 8)
        header[4] = UInt8(interfaceIndex & 0xFF); header[5] = UInt8(interfaceIndex >> 8)
        for (offset, value) in [(8, flags), (12, addresses)] {
            let raw = UInt32(bitPattern: value)
            for byte in 0..<4 { header[offset + byte] = UInt8((raw >> (8 * UInt32(byte))) & 0xFF) }
        }
        return header + payload
    }

    @Test func theRoutingTableNamesTheInterfacesThatCarryTheDefaultRoute() {
        let names = [4: "en0", 20: "en1", 21: "utun4", 22: "utun5"]
        // en0: the real 0.0.0.0/0 (no netmask); en1: a scoped one (ignored); utun4: 0/1 and 128/1 (a VPN client); utun5 only 0/1.
        let dump = routeMessage(destination: [0, 0, 0, 0], mask: nil, interfaceIndex: 4)
            + routeMessage(destination: [0, 0, 0, 0], mask: nil, interfaceIndex: 20, flags: 0x1 | 0x2 | 0x1000000)
            + routeMessage(destination: [0, 0, 0, 0], mask: [0x80], interfaceIndex: 21)
            + routeMessage(destination: [128, 0, 0, 0], mask: [0x80], interfaceIndex: 21)
            + routeMessage(destination: [0, 0, 0, 0], mask: [0x80], interfaceIndex: 22)
            + routeMessage(destination: [192, 168, 4, 0], mask: [255, 255, 255], interfaceIndex: 4)
            + routeMessage(destination: [10, 0, 0, 0], mask: [255], interfaceIndex: 21)
        let carriers = MacVPNDetector.defaultRouteInterfaces(inRouteDump: dump, interfaceName: { names[$0] })
        #expect(carriers == ["en0", "utun4"])
        #expect(MacVPNDetector.defaultRouteInterfaces(inRouteDump: [], interfaceName: { names[$0] }).isEmpty)
        #expect(MacVPNDetector.defaultRouteInterfaces(inRouteDump: [1, 2, 3], interfaceName: { names[$0] }).isEmpty, "garbage is no route")
    }

    @Test func theSystemsRoutingTableCanBeRead() throws {
        #if canImport(Darwin)
        // A Mac with a network has an IPv4 default route: reading the table must find it (or not fail on a Mac without one).
        let carriers = try #require(MacVPNDetector.systemDefaultRouteInterfaces())
        #expect(carriers.allSatisfy { !$0.isEmpty })
        #endif
    }

    // MARK: The notice log

    private func controllerNotice(device: String = "192.0.2.20", camera: String? = "Driveway", delivery: NetworkNotice.Delivery = .pending,
                                  at date: Date) -> NetworkNotice {
        NetworkNotice(kind: .controllerOnVPN, cameraID: UUID(), cameraName: camera, advertisedAddress: "10.5.0.2", peerAddress: device,
                      usedFallback: true, delivery: delivery, date: date)
    }

    @Test func oneDeviceIsOneNoticeWhateverCameraItWatches() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var log = NetworkNoticeLog()
        do { let changed = log.record(controllerNotice(at: t0), now: t0); #expect(changed) }
        do { let changed = log.record(controllerNotice(camera: "Front Door", delivery: .reached, at: t0.addingTimeInterval(20)), now: t0.addingTimeInterval(20)); #expect(changed) }
        #expect(log.notices.count == 1)
        #expect(log.notices[0].cameraName == "Front Door" && log.notices[0].delivery == .reached)
        #expect(log.notices[0].firstSeen == t0, "the episode began with the first report")
        // Another device is another notice.
        do { let changed = log.record(controllerNotice(device: "192.0.2.31", at: t0.addingTimeInterval(30)), now: t0.addingTimeInterval(30)); #expect(changed) }
        #expect(log.notices.count == 2)
        // The same report again changes nothing.
        let same = log.notices[1]
        do { let changed = log.record(same, now: t0.addingTimeInterval(31)); #expect(!changed) }
    }

    @Test func aControllerNoticeExpiresAnHourAfterItWasLastSeenAndRecurrenceStartsANewEpisode() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var log = NetworkNoticeLog()
        log.record(controllerNotice(at: t0), now: t0)
        do { let changed = log.prune(now: t0.addingTimeInterval(3_599)); #expect(!changed) }
        #expect(log.notices.count == 1)
        // Seen again at 50 min: the hour starts over.
        let again = t0.addingTimeInterval(3_000)
        log.record(controllerNotice(delivery: .reached, at: again), now: again)
        do { let changed = log.prune(now: t0.addingTimeInterval(3_700)); #expect(!changed) }
        do { let changed = log.prune(now: again.addingTimeInterval(3_600)); #expect(changed) }
        #expect(log.notices.isEmpty)
        // It comes back later: a new episode.
        let later = t0.addingTimeInterval(20_000)
        log.record(controllerNotice(at: later), now: later)
        #expect(log.notices[0].firstSeen == later)
        // An expired notice that was not pruned yet also starts a new episode when it recurs.
        let recurrence = later.addingTimeInterval(4_000)
        log.record(controllerNotice(at: recurrence), now: recurrence)
        #expect(log.notices[0].firstSeen == recurrence)
    }

    @Test func theMacNoticeStaysUntilTheVPNIsGone() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var log = NetworkNoticeLog()
        log.record(NetworkNotice(kind: .macOnVPN, interfaceName: "utun4", date: t0), now: t0)
        do { let changed = log.prune(now: t0.addingTimeInterval(86_400)); #expect(!changed) }
        #expect(log.notices.count == 1 && log.notices[0].id == "macOnVPN:mac")
        do { let changed = log.remove(.macOnVPN); #expect(changed) }
        do { let changed = log.remove(.macOnVPN); #expect(!changed) }
        #expect(log.notices.isEmpty)
    }

    @Test func aNoticesDeviceIsItsAddressOnThisNetwork() {
        let a = NetworkNotice(kind: .controllerOnVPN, advertisedAddress: "10.5.0.2", peerAddress: "::ffff:192.0.2.20")
        let b = NetworkNotice(kind: .controllerOnVPN, advertisedAddress: "10.5.0.2", peerAddress: "192.0.2.20")
        #expect(a.id == b.id)
        let unknownPeer = NetworkNotice(kind: .controllerOnVPN, advertisedAddress: "10.5.0.2")
        #expect(unknownPeer.deviceKey == "10.5.0.2")
    }

    @Test func tunnelAddressesAreTheOnesThatLookLikeAVPN() {
        #expect(StreamAddress.looksLikeTunnelAddress("10.5.0.2"))
        #expect(StreamAddress.looksLikeTunnelAddress("100.64.1.9"))
        #expect(StreamAddress.looksLikeTunnelAddress("172.16.0.4"))
        #expect(StreamAddress.looksLikeTunnelAddress("fd00:dead:beef::2"))
        #expect(!StreamAddress.looksLikeTunnelAddress("2001:db8::9"))
        #expect(!StreamAddress.looksLikeTunnelAddress("fe80::1"))
        #expect(!StreamAddress.looksLikeTunnelAddress("not an address"))
    }

    // MARK: Diagnostics

    @Test func theDiagnosticsReportSaysWhetherTheMacOrADeviceIsOnAVPN() {
        let context = DiagnosticsContext(appVersion: "1.0", appBuild: "7", macOSVersion: "Version 27.0", macModel: "Mac15,3", architecture: "arm64",
                                         systemUptime: 100, processUptime: 50, generated: Date(timeIntervalSince1970: 1_790_000_600), locale: "en_US")
        let notice = NetworkNotice(kind: .controllerOnVPN, cameraName: "Driveway", advertisedAddress: "10.5.0.2", peerAddress: "192.0.2.20",
                                   usedFallback: true, delivery: .failed, date: Date(timeIntervalSince1970: 1_790_000_000))
        let text = DiagnosticsReport.render(context: context, state: .running, localNetwork: .granted, settings: BridgeSettings(), cameras: [],
                                            configurations: [], sessions: [], logEntries: [], networkNotices: [notice],
                                            macVPN: MacVPNStatus(interface: "utun4", address: "10.5.0.2", reason: .defaultRoute))
        #expect(text.contains("## Network"))
        #expect(text.contains("This Mac: connected to a VPN (utun4, 10.5.0.2, carries the default route)"))
        #expect(text.contains("Device at 192.0.2.20 asked for video at 10.5.0.2 for Driveway; sent to 192.0.2.20 instead; the device did not answer"))
        #expect(text.contains("last seen 10 min ago"))
        let quiet = DiagnosticsReport.render(context: context, state: .running, localNetwork: .granted, settings: BridgeSettings(), cameras: [],
                                             configurations: [], sessions: [], logEntries: [])
        #expect(quiet.contains("This Mac: no VPN found") && quiet.contains("none seen asking for video"))
        #expect(quiet.contains("Live video findings: none"))
    }

    /// The report listed only `controllerOnVPN`: a device that received no video, a blocked send and a doubly held network were
    /// in the app's banner but not in the export the owner sends when something is wrong.
    @Test func theDiagnosticsReportListsEveryKindOfFinding() {
        let now = Date(timeIntervalSince1970: 1_790_000_600)
        let context = DiagnosticsContext(appVersion: "1.0", appBuild: "7", macOSVersion: "Version 27.0", macModel: "Mac15,3", architecture: "arm64",
                                         systemUptime: 100, processUptime: 50, generated: now, locale: "en_US")
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let notices = [
            NetworkNotice(kind: .liveViewNotReceived, cameraName: "Driveway", peerAddress: "192.0.2.20", delivery: .failed,
                          detail: "reports show 100% lost", date: started.addingTimeInterval(300), firstSeen: started),
            NetworkNotice(kind: .localNetworkDenied, detail: "no route to host", date: started.addingTimeInterval(120)),
            NetworkNotice(kind: .dualHomedSubnet, interfaceName: "en0, en1", detail: "192.0.2.0/24", date: started),
        ]
        let text = DiagnosticsReport.render(context: context, state: .running, localNetwork: .granted, settings: BridgeSettings(), cameras: [],
                                            configurations: [], sessions: [], logEntries: [], networkNotices: notices)
        #expect(text.contains("- Live video did not reach the device at 192.0.2.20 (watching Driveway)"))
        #expect(text.contains("no live view has received video since; first seen 10 min ago, last seen 5 min ago"))
        #expect(text.contains("- Sending live video failed for good (no route to host): the Local Network permission is off or a firewall or VPN app blocks Camera Bridge"))
        #expect(text.contains("- This Mac is on one network twice (en0, en1, 192.0.2.0/24): live video is sent from the address the device connected to"))
        #expect(!text.contains("Live video findings: none"))
        // A device that received video afterwards is settled, and says so.
        var settled = notices[0]
        settled.delivery = .reached
        let after = DiagnosticsReport.render(context: context, state: .running, localNetwork: .granted, settings: BridgeSettings(), cameras: [],
                                             configurations: [], sessions: [], logEntries: [], networkNotices: [settled])
        #expect(after.contains("a later live view received video (settled)"))
    }

    /// A live session's health and the reason the pipeline ended it are in the camera's section.
    @Test func theDiagnosticsReportShowsALiveSessionsHealthAndEndReason() {
        let configuration = CameraConfiguration(name: "Patio", kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "")
        var status = CameraStatus(id: configuration.id, name: "Patio", kind: .camera, vendor: .demo, connection: .online, eventChannelConnected: false,
                                  isPaired: true, setupCode: "", setupURI: "")
        status.liveSessions = [LiveSessionStatus(usesSubStream: true, isPassthrough: false, resolution: nil, bitrateKbps: nil, health: "ok"),
                               LiveSessionStatus(usesSubStream: false, isPassthrough: true, resolution: nil, bitrateKbps: nil, health: "no video for 4 s",
                                                 endReason: "the video encoder could not be built")]
        let context = DiagnosticsContext(appVersion: "1.0", appBuild: "7", macOSVersion: "Version 27.0", macModel: "Mac15,3", architecture: "arm64",
                                         systemUptime: 100, processUptime: 50, generated: Date(timeIntervalSince1970: 1_790_000_600), locale: "en_US")
        let text = DiagnosticsReport.render(context: context, state: .running, localNetwork: .granted, settings: BridgeSettings(), cameras: [status],
                                            configurations: [configuration], sessions: [], logEntries: [])
        #expect(text.contains("Live session 1: sub stream, transcoded, health: ok\n"))
        #expect(text.contains("Live session 2: main stream, passthrough, health: no video for 4 s, ended by Camera Bridge: the video encoder could not be built"))
    }
}
