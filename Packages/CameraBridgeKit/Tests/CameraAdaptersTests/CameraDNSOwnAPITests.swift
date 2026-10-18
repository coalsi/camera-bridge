// Loopback fake ONVIF, IPCamera Web and Reolink cameras (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// The internet guard's Watch through a camera's own API: the IPCamera Web family's page, where ONVIF cannot point every DNS server the camera
/// has at the bridge (`network.cgi` `get=eth` / `set=eth`, the interface written as the page writes it with only its DNS changed), and a
/// Reolink's `GetLocalLink` / `SetLocalLink`, whenever it shows them (Reolink refuses ONVIF's writes to its ONVIF user; more in
/// `ReolinkSetupTests`). Each write restarts the camera's network service, so the read-back waits for it; the
/// backup keeps the API's own values and Restore writes them back. Against fakes only, with documentation addresses.
@Suite(.timeLimit(.minutes(1))) struct CameraDNSOwnAPITests {
    private let bridge = "192.0.2.10"
    /// The read-back after a restart, short for the fakes (a camera gets 30 s).
    private let quick = DNSReadBackTiming(limit: .seconds(10), interval: .milliseconds(20))

    final class Capture: LogSink {
        let entries = Box<[LogEntry]>([])
        func record(_ entry: LogEntry) { entries.update { $0.append(entry) } }
        var text: String { entries.value.map(\.message).joined(separator: "\n") }
    }

    // MARK: The IPCamera Web family

    /// A camera of the family as the owner's "Patio New" is: an ONVIF that asks no password and keeps the second of its two slots (by
    /// default), on DHCP; the family's web API on the web port with its `eth` option, restarting its network service after an `eth`
    /// write; its ONVIF then shows what the page set.
    private struct Family {
        let onvif: MockONVIFCamera
        let web: FakeIPCamWebCamera
        var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(web.server.port), onvifPort: Int(onvif.server.port)) }

        static func start(slots: MockONVIFCamera.DNSSlots = .twoKeepingSecond) async throws -> Family {
            let onvif = try await MockONVIFCamera.start()
            onvif.openONVIF.set(true)
            onvif.dnsSlots.set(slots)
            onvif.dns.set(MockONVIFCamera.DNS(fromDHCP: true, searchDomains: ["domain.name"], dhcpServers: ["1.1.1.1", "8.8.8.8"],
                                              manualServers: ["1.1.1.1", "8.8.8.8"]))
            let web = try await FakeIPCamWebCamera.start()
            web.options.update { $0["eth"] = FakeIPCamWebCamera.eth }
            web.restartAfterEthWrite.set(3)
            web.ethWritten.set { dns in
                onvif.dns.update { state in
                    state.fromDHCP = dns["ondhcp"] == "1"
                    state.manualServers = [dns["dns1"] ?? "", dns["dns2"] ?? ""]
                }
            }
            let family = Family(onvif: onvif, web: web)
            for key in IPCamWebClient.loginKeys(family.endpoint) { ONVIFLoginGuard.shared.clear(host: key) }
            return family
        }

        func service() -> CameraSettingsService { CameraSettingsService(endpoint: endpoint, credentials: web.credentials, vendor: .onvif) }

        func stop() {
            onvif.stop()
            web.stop()
            for key in IPCamWebClient.loginKeys(endpoint) { ONVIFLoginGuard.shared.clear(host: key) }
            IPCamWebLatch.shared.reset(IPCamWebLatch.key(endpoint))
        }
    }

    /// `set=eth`'s `data` for the fake's interface with this `dns` child, as the camera's page writes it.
    private func ethWrite(dns ondhcp: String, _ dns1: String, _ dns2: String) -> String {
        "<?xml version='1.0'?><root><eth ondhcp='1' ip='192.168.77.22' submask='255.255.255.0' gateway='192.168.77.1' ip6='' submask6='' "
            + "gateway6='' dhcp_mode='0' dhcp_fixed_time='0' hostname='TESTCAM' ><dns ondhcp='\(ondhcp)' dns1='\(dns1)' dns2='\(dns2)' /></eth></root>"
    }

    private static let kept = "the camera asks Camera Bridge first but kept 8.8.8.8 as its other DNS server"

    /// ONVIF kept 8.8.8.8 whatever it was sent: the page's own setting puts the bridge in both slots. The interface goes back exactly as
    /// read, in the page's order, with only its DNS changed; the camera restarts its network service (and forgets its session) before it
    /// answers again; Restore writes the old DNS back the same way. Nothing of the answer reaches the log.
    @Test func thePageSetsBothServersWhenONVIFKeepsOne() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        let capture = Capture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let service = camera.service()

        let (reading, backup) = try await service.readInternetWatch(server: bridge)
        #expect(reading.state == .willChange)
        let saved = try #require(backup)
        #expect(saved == CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], searchDomains: ["domain.name"],
                                         ownAPI: ["ondhcp": "1", "dns1": "1.1.1.1", "dns2": "8.8.8.8"]), "the page's DNS as it was")
        #expect(camera.web.writes("eth").isEmpty, "reading changes nothing")

        #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via web API"))
        #expect(camera.onvif.setDNSBodies.value.count == 3, "ONVIF first: it touches only the DNS")
        #expect(camera.web.writes("eth") == [ethWrite(dns: "0", bridge, bridge)])
        #expect(camera.web.signIns.count == 2, "signed in again after the restart")
        #expect(try await service.readDNS()?.pointsAt(bridge) == true)

        #expect(try await service.restoreDNS(saved, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via web API"))
        #expect(camera.web.writes("eth").last == ethWrite(dns: "1", "1.1.1.1", "8.8.8.8"))
        #expect(camera.onvif.dns.value.fromDHCP)
        for text in ["192.168.77.22", "255.255.255.0", "TESTCAM", FakeIPCamWebCamera.password] {
            #expect(!capture.text.contains(text), "the interface's answer is never logged")
        }
    }

    /// A camera whose ONVIF takes the bridge alone is never signed in to.
    @Test func aCameraWhoseONVIFTakesTheBridgeKeepsItsPageAsItIs() async throws {
        let camera = try await Family.start(slots: .asSent)
        defer { camera.stop() }
        #expect(try await camera.service().applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.web.writes("eth").isEmpty && camera.web.signIns.isEmpty)
    }

    /// The family's sign-in refused: nothing is written through the page and the refusal says why ONVIF's words are the last.
    @Test func aRefusedSignInLeavesTheCameraToONVIFAndSaysWhy() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        camera.web.signInCode.set(531201)
        let outcome = try await camera.service().applyDNS(server: bridge, readBack: quick)
        #expect(!outcome.succeeded && outcome.detail.hasPrefix(Self.kept + "; the camera’s web API "), "\(outcome.detail)")
        #expect(camera.web.writes("eth").isEmpty && camera.web.signIns.count == 1)
    }

    /// The page's write refused for want of privilege (532374, once the camera signed Camera Bridge in) is a change the account may not
    /// make, typed (`notPermitted`), after ONVIF's words; so is a sign-in the camera refuses so.
    @Test func aPageWriteRefusedForWantOfPrivilegeIsAChangeTheAccountMayNotMake() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        camera.web.writeCode.set(IPCamWebCameraError.noPrivilege)
        let outcome = try await camera.service().applyDNS(server: bridge, readBack: quick)
        #expect(outcome == CameraSetupOutcome(succeeded: false, detail: Self.kept + "; the camera’s web API refused the change ("
                                              + CameraAdapterError.notPermittedReason + ")", notPermitted: true))
        #expect(!IPCamWebLatch.shared.isTripped(IPCamWebLatch.key(camera.endpoint)))

        let signIn = try await Family.start()
        defer { signIn.stop() }
        signIn.web.signInCode.set(IPCamWebCameraError.noPrivilege)
        let refused = try await signIn.service().applyDNS(server: bridge, readBack: quick)
        #expect(refused == CameraSetupOutcome(succeeded: false, detail: Self.kept + "; the camera’s web API cannot be asked: "
                                              + IPCamWebUnavailable.noPrivilege.reason, notPermitted: true))
        #expect(signIn.web.writes("eth").isEmpty)
    }

    /// An interface the page would not write back as it was is not written: Camera Bridge refuses rather than change anything else.
    @Test func anInterfaceThePageWouldChangeIsLeftAlone() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        let service = camera.service()
        for eth in [FakeIPCamWebCamera.eth.replacingOccurrences(of: #" hostname="#, with: #" mtu="1400" hostname="#),
                    FakeIPCamWebCamera.eth.replacingOccurrences(of: #"hostname="TESTCAM""#, with: #"hostname="TEST CAM""#),
                    #"<eth ondhcp="1" ip="192.168.77.22"/>"#] {
            camera.web.options.update { $0["eth"] = eth }
            let outcome = try await service.applyDNS(server: bridge, readBack: quick)
            #expect(!outcome.succeeded && outcome.detail.hasPrefix(Self.kept + "; "), "\(outcome.detail)")
        }
        camera.web.options.update { $0["eth"] = nil }
        let none = try await service.applyDNS(server: bridge, readBack: quick)
        #expect(none == CameraSetupOutcome(succeeded: false, detail: Self.kept + "; the camera’s web API shows no DNS servers"))
        #expect(camera.web.writes("eth").isEmpty)
    }

    /// A camera that takes the write but keeps its servers is refused once the wait is over, saying what it kept.
    @Test func aPageThatKeepsItsServersIsRefused() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        camera.web.mode.set(.ignoreWrites)
        let outcome = try await camera.service().applyDNS(server: bridge, readBack: DNSReadBackTiming(limit: .milliseconds(300), interval: .milliseconds(20)))
        #expect(outcome == CameraSetupOutcome(succeeded: false, detail: Self.kept))
        #expect(camera.web.writes("eth").count == 1)
    }

    /// Without the page (the camera now refuses Camera Bridge's sign-in), Restore goes through ONVIF.
    @Test func withoutThePageRestoreGoesThroughONVIF() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        let saved = try #require(try await camera.service().readInternetWatch(server: bridge).1)
        #expect(try await camera.service().applyDNS(server: bridge, readBack: quick).succeeded)
        IPCamWebLatch.shared.trip(IPCamWebLatch.key(camera.endpoint), credentials: camera.web.credentials)
        #expect(try await camera.service().restoreDNS(saved, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.onvif.dns.value.fromDHCP && camera.web.writes("eth").count == 1)
    }

    /// Round one's review: the camera forgot Camera Bridge's session and now refuses its sign-in, at Restore time. The page is one way back,
    /// not the only one: Restore goes through ONVIF (whose logins the family's refusal does not pause), and nothing more goes to the page.
    @Test func aSignInRefusedAtRestoreGoesBackThroughONVIF() async throws {
        let camera = try await Family.start()
        defer { camera.stop() }
        let service = camera.service()
        let saved = try #require(try await service.readInternetWatch(server: bridge).1)
        #expect(saved.ownAPI != nil)
        #expect(try await service.applyDNS(server: bridge, readBack: quick).succeeded)
        camera.web.expireSessions.set(1)
        camera.web.signInCode.set(FakeIPCamWebCamera.wrongPasswordCode)

        #expect(try await service.restoreDNS(saved, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.onvif.dns.value.fromDHCP, "back on DHCP, as it was")
        #expect(camera.web.writes("eth").count == 1, "only Watch's write went to the page")
    }

    @Test func theInterfaceIsWrittenAsThePageWritesIt() throws {
        let dns = ["ondhcp": "0", "dns1": bridge, "dns2": bridge]
        let page = try #require(CameraSettingsService.ipcamEthWrite("<root>\(FakeIPCamWebCamera.eth)</root>", dns: dns))
        #expect("<?xml version='1.0'?><root>\(page)</root>" == ethWrite(dns: "0", bridge, bridge))
        // `dns` beside the interface instead of inside it, and the page's own quotes: written the same.
        let beside = FakeIPCamWebCamera.eth.replacingOccurrences(of: "><dns", with: "/><dns").replacingOccurrences(of: "</eth>", with: "")
        #expect(CameraSettingsService.ipcamEthWrite("<root>\(beside)</root>", dns: dns) == page)
        let written = ethWrite(dns: "1", "1.1.1.1", "8.8.8.8").replacingOccurrences(of: "<?xml version='1.0'?>", with: "")
        #expect(CameraSettingsService.ipcamEthWrite(written, dns: dns) == page)

        for refused in [FakeIPCamWebCamera.eth.replacingOccurrences(of: #" ip6="""#, with: ""),
                        FakeIPCamWebCamera.eth.replacingOccurrences(of: #"<dns "#, with: #"<wifi on="0"/><dns "#),
                        FakeIPCamWebCamera.eth.replacingOccurrences(of: #" dns2="8.8.8.8""#, with: ""),
                        FakeIPCamWebCamera.eth.replacingOccurrences(of: #"hostname="TESTCAM""#, with: #"hostname="T&amp;CAM""#),
                        FakeIPCamWebCamera.eth.replacingOccurrences(of: #"ondhcp="1" ip="#, with: #"ondhcp="1" ondhcp="1" ip="#)] {
            #expect(CameraSettingsService.ipcamEthWrite("<root>\(refused)</root>", dns: dns) == nil, "\(refused)")
        }
        #expect(CameraSettingsService.ipcamEthWrite("<root>\(FakeIPCamWebCamera.eth)</root>", dns: ["ondhcp": "0", "dns1": "bridge'", "dns2": ""]) == nil)
    }

    // MARK: Reolink

    /// A Reolink goes through its own `LocalLink` (owner decision, 2026-10-18: Reolink refuses ONVIF's writes to its ONVIF user, and such a
    /// refusal paused every ONVIF login to the owner's doorbell): read, set and put back there, its ONVIF never written to.
    @Test func aReolinkIsReadSetAndGivenBackThroughItsOwnAPINotONVIF() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let reolink = FakeReolinkLink(onvif: camera)
        camera.refuseDNSChanges.set(true)
        let service = reolinkService(camera)

        let (reading, backup) = try await service.readInternetWatch(server: bridge)
        #expect(reading.state == .willChange)
        let saved = try #require(backup)
        #expect(saved == CameraDNSBackup(method: .reolinkAPI, fromDHCP: true, servers: ["192.168.77.1", "192.168.77.1"],
                                         ownAPI: ["auto": "1", "dns1": "192.168.77.1", "dns2": "192.168.77.1"]))

        #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        let sent = try #require(reolink.sets.value.last?.object)
        #expect(sent["dns"] == .object(["auto": .number(0), "dns1": .string(bridge), "dns2": .string(bridge)]))
        var original = try #require(try JSONValue.parse(Data(FakeReolinkLink.link.utf8)).object)
        original["dns"] = sent["dns"]
        #expect(sent == original, "the rest of LocalLink goes back as the camera had it")
        #expect(try await service.readDNS()?.pointsAt(bridge) == true)
        #expect(camera.setDNSBodies.value.isEmpty, "ONVIF is not written to")

        #expect(try await service.restoreDNS(saved, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        #expect(try JSONValue.parse(Data(reolink.link.value.utf8)) == JSONValue.parse(Data(FakeReolinkLink.link.utf8)), "as the camera had it")
        // An IPv6 address goes to ONVIF (LocalLink takes IPv4 only), which refuses here in its own words.
        let writes = reolink.sets.value.count
        let v6 = try await service.applyDNS(server: "2001:db8::10", readBack: quick)
        #expect(!v6.succeeded && v6.detail.contains("InvalidArgVal") && reolink.sets.value.count == writes, "\(v6)")
        #expect(camera.setDNSBodies.value.count == 1)
    }

    /// A backup saved through ONVIF by an earlier build is put back through `LocalLink` when it kept the camera's own values: exactly its
    /// two slots.
    @Test func anOlderONVIFBackupOfAReolinkGoesBackThroughItsOwnAPI() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let reolink = FakeReolinkLink(onvif: camera)
        let service = reolinkService(camera)
        let older = CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], searchDomains: ["domain.name"],
                                    ownAPI: ["auto": "1", "dns1": "192.168.77.1", "dns2": "192.168.77.1"])
        #expect(try await service.applyDNS(server: bridge, readBack: quick).succeeded)
        #expect(try await service.restoreDNS(older, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        #expect(try JSONValue.parse(Data(reolink.link.value.utf8)) == JSONValue.parse(Data(FakeReolinkLink.link.utf8)))
        #expect(camera.setDNSBodies.value.isEmpty)
    }

    /// A Reolink that does not show its `LocalLink` ("not support") goes through ONVIF, as other cameras do; an IPv6 address with a `LocalLink`
    /// and no ONVIF DNS is refused (LocalLink takes IPv4 only).
    @Test func aReolinkWithoutLocalLinkGoesThroughONVIF() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let reolink = FakeReolinkLink(onvif: camera)
        reolink.link.set("")
        let service = reolinkService(camera)
        let read = try #require(try await service.readDNS())
        #expect(read.method == .onvifMinimal)
        #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(reolink.sets.value.isEmpty)
        #expect(try await service.restoreDNS(read.backup, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))

        reolink.link.set(FakeReolinkLink.link)
        camera.noDNS.set(true)
        #expect(try await service.applyDNS(server: "2001:db8::10", readBack: quick)
                == CameraSetupOutcome(succeeded: false, detail: "this camera takes an IPv4 address for its DNS server"))
        #expect(reolink.sets.value.isEmpty)
    }

    private func reolinkService(_ camera: MockONVIFCamera) -> CameraSettingsService {
        CameraSettingsService(endpoint: camera.endpoint, credentials: HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password),
                              vendor: .reolink)
    }
}

/// Reolink's `/api.cgi` beside the camera's ONVIF (`MockONVIFCamera.otherAPI`): a login, `GetLocalLink` and `SetLocalLink`, whose `dns` the
/// camera's ONVIF then shows. An empty `link` is a camera without the command (-9 "not support"). Documentation addresses and MAC.
final class FakeReolinkLink: Sendable {
    static let link = #"{"activeLink":"LAN","dns":{"auto":1,"dns1":"192.168.77.1","dns2":"192.168.77.1"},"mac":"00:00:5e:00:53:30","#
        + #""static":{"gateway":"192.168.77.1","ip":"192.168.77.30","mask":"255.255.255.0"},"type":"DHCP"}"#
    let link = Box(FakeReolinkLink.link)
    /// The `LocalLink` of every `SetLocalLink`, as sent.
    let sets = Box<[JSONValue]>([])

    init(onvif: MockONVIFCamera) {
        onvif.otherAPI.set { [self] request in handle(request, onvif: onvif) }
    }

    private func handle(_ request: MockRequest, onvif: MockONVIFCamera) -> MockResponse? {
        guard request.path == "/api.cgi" else { return nil }
        let cmd = request.query("cmd") ?? ""
        func value(_ text: String) -> MockResponse { .json(#"[{"cmd":"\#(cmd)","code":0,"value":\#(text)}]"#) }
        let notSupported = MockResponse.json(#"[{"cmd":"\#(cmd)","code":1,"error":{"detail":"not support","rspCode":-9}}]"#)
        switch cmd {
        case "Login": return value(#"{"Token":{"leaseTime":3600,"name":"tok1"}}"#)
        case "Logout": return value(#"{"rspCode":200}"#)
        case "GetLocalLink": return link.value.isEmpty ? notSupported : value(#"{"LocalLink":\#(link.value)}"#)
        case "SetLocalLink":
            guard !link.value.isEmpty, let sent = (try? JSONValue.parse(request.body))?[0]?["param"]?["LocalLink"], let dns = sent["dns"],
                  let text = (try? JSONEncoder().encode(sent)).map({ String(decoding: $0, as: UTF8.self) }) else { return notSupported }
            sets.update { $0.append(sent) }
            link.set(text)
            onvif.dns.update { state in
                state.fromDHCP = dns["auto"]?.int == 1
                state.manualServers = [dns["dns1"]?.string ?? "", dns["dns2"]?.string ?? ""]
            }
            return value(#"{"rspCode":200}"#)
        default: return notSupported
        }
    }
}
#endif
