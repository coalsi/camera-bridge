// Loopback fake Dahua / Amcrest / Lorex cameras (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// The internet guard's Watch on a Dahua, Amcrest or Lorex camera (vendor `.amcrest`) through the camera's own CGI
/// (`configManager.cgi`, `Network.<interface>.DnsServers[0|1]`, `AmcrestDNS.swift`) before ONVIF, whose DNS these cameras are known to
/// keep unreliably. The camera answers Digest; "OK" or "Error" tells a change. A camera whose CGI is not Dahua's (HTML, a 404) is left
/// to ONVIF. Against fakes only, with documentation-style addresses.
@Suite(.timeLimit(.minutes(1))) struct AmcrestDNSTests {
    private let credentials = HTTPCredentials(username: "admin", password: MockONVIFCamera.password)
    private let bridge = "192.168.77.10"
    /// The read-back after a write, short for the fakes (a camera gets 30 s, read every 2 s).
    private let quick = DNSReadBackTiming(limit: .seconds(10), interval: .milliseconds(20))
    /// The whole wait of a camera that never shows the change.
    private let brief = DNSReadBackTiming(limit: .milliseconds(300), interval: .milliseconds(20), laterFormsLimit: .milliseconds(100))

    private func service(_ camera: FakeDahuaCamera) -> CameraSettingsService {
        CameraSettingsService(endpoint: camera.endpoint, credentials: credentials, vendor: .amcrest)
    }

    private func setConfig(_ interface: String, _ first: String, _ second: String) -> [String: String] {
        ["action": "setConfig", "Network.\(interface).DnsServers[0]": first, "Network.\(interface).DnsServers[1]": second]
    }

    // MARK: Reading

    /// The default interface's two slots: the Wi-Fi model's `eth2`, not `eth0`. One `getConfig` of `Network` over Digest, nothing written, and
    /// ONVIF is not asked.
    @Test func readsTheDefaultInterfacesServers() async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        camera.network.update { $0.defaultInterface = "eth2" }

        let api = AmcrestAPI(endpoint: camera.endpoint, credentials: credentials)
        let answer = try #require(try await api.networkDNS())
        #expect(answer.interface == "eth2" && answer.servers == ["192.168.77.2", "192.168.77.3"])
        let request = try #require(camera.server.requests.last)
        #expect(request.method == "GET" && request.path == "/cgi-bin/configManager.cgi")
        #expect(request.query("action") == "getConfig" && request.query("name") == "Network")
        #expect(isDigestAuthorization(request.head.headers["Authorization"]))

        let read = try #require(try await service(camera).readDNS())
        #expect(read.servers == ["192.168.77.2", "192.168.77.3"] && !read.fromDHCP && read.method == .dahuaCGI)
        #expect(read.backup == CameraDNSBackup(method: .dahuaCGI, fromDHCP: false, servers: ["192.168.77.2", "192.168.77.3"], dahuaInterface: "eth2"))
        #expect(camera.writes.value.isEmpty, "reading changes nothing")
        #expect(camera.onvif.actions.value.isEmpty, "ONVIF is not asked")

        // A slot the camera shows as 0.0.0.0 is no server, and the backup keeps it as it is.
        camera.network.update { $0.servers["eth2"] = ["192.168.77.2", "0.0.0.0"] }
        let one = try #require(try await service(camera).readDNS())
        #expect(one.servers == ["192.168.77.2"] && one.backup.servers == ["192.168.77.2", "0.0.0.0"])
    }

    /// Only an answer that is the `Network` table with the interface's DNS slots is Dahua's: the interface name goes into the address of
    /// the change, so what is not a plain name is not used.
    @Test func anAnswerThatIsNotTheNetworkTableIsNotUsed() {
        let table = "table.Network.DefaultInterface=eth0\r\ntable.Network.eth0.DnsServers[0]=192.168.77.1\r\ntable.Network.eth0.DnsServers[1]=8.8.8.8\r\n"
        #expect(AmcrestAPI.parseNetworkDNS(table)?.servers == ["192.168.77.1", "8.8.8.8"])
        #expect(AmcrestAPI.parseNetworkDNS(table, interface: "eth2") == nil, "that interface has no DNS slots")
        for text in ["", "<html><body>x=1</body></html>", "Error\r\nBad Request!\r\n", "table.Network.DefaultInterface=eth0\r\n",
                     "table.Network.eth0.DnsServers[0]=192.168.77.1\r\n"] {
            #expect(AmcrestAPI.parseNetworkDNS(text) == nil, "\(text)")
        }
        for name in ["eth0&Network.eth0.DnsServers[0]=6.6.6.6", "", "../eth0", "eth0=1", String(repeating: "e", count: 40)] {
            let hostile = "table.Network.DefaultInterface=\(name)\r\ntable.Network.\(name).DnsServers[0]=192.168.77.1\r\n"
            #expect(AmcrestAPI.parseNetworkDNS(hostile) == nil, "\(name)")
        }
        #expect(AmcrestAPI.parseNetworkDNS("table.Network.DefaultInterface=eth0\r\ntable.Network.eth0.DnsServers[1]=8.8.8.8\r\n")?.servers == ["", "8.8.8.8"],
                "a missing first slot keeps the second one in its place")
    }

    // MARK: Writing

    /// The bridge in both slots, with the camera showing the change only after a few reads (some restart their network): one `setConfig`,
    /// read back until the camera asks the bridge alone, and ONVIF is never asked.
    @Test func writesBothSlotsAndReadsBack() async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        camera.applyAfterReads.set(3)
        let service = service(camera)

        #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via Dahua API"))
        #expect(camera.writes.value == [setConfig("eth0", bridge, bridge)], "one change: the bridge in both slots, on the default interface")
        #expect(camera.network.value.servers["eth0"] == [bridge, bridge] && camera.network.value.servers["eth2"] == ["192.168.77.2", "192.168.77.3"])
        #expect(camera.readsAfterTheWrite.value == 4, "read back until the camera showed it: three old readings, then the new one")
        #expect(camera.onvif.actions.value.isEmpty)
        let after = try #require(try await service.readDNS())
        #expect(after.pointsAt(bridge) && after.servers == [bridge])
    }

    /// A camera whose network service restarts after the change answers nothing for a moment: no answer is no refusal, and the read-back
    /// waits for it. A change it applied but never answered is read back too.
    @Test func aCameraThatRestartsItsNetworkIsReadAgain() async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        camera.applyAfterReads.set(3)
        camera.silentWhileApplying.set(true)
        #expect(try await service(camera).applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via Dahua API"))
        #expect(camera.writes.value.count == 1)

        let silent = try await FakeDahuaCamera.start()
        defer { silent.stop() }
        silent.writeMode.set(.appliesThenDrops)
        #expect(try await service(silent).applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via Dahua API"))
        #expect(silent.network.value.servers["eth0"] == [bridge, bridge])
    }

    /// A camera that says "OK" and keeps its second server is refused in words that say what it kept: the bridge is there, so the camera
    /// took the change, and ONVIF is not tried. One that never answers again says so, and ONVIF is not tried either.
    @Test func aCameraThatKeepsItsOtherServerIsRefusedInWordsThatSayWhatItKept() async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        camera.writeMode.set(.keepsSecond)
        camera.network.update { $0.servers["eth0"] = ["192.168.77.1", "8.8.8.8"] }
        let outcome = try await service(camera).applyDNS(server: bridge, readBack: brief)
        #expect(outcome == CameraSetupOutcome(succeeded: false, detail: "the camera asks Camera Bridge first but kept 8.8.8.8 as its other DNS server"),
                "\(outcome)")
        #expect(camera.writes.value.count == 1 && camera.onvif.actions.value.isEmpty)

        let gone = try await FakeDahuaCamera.start()
        defer { gone.stop() }
        gone.applyAfterReads.set(10_000)
        gone.silentWhileApplying.set(true)
        #expect(try await service(gone).applyDNS(server: bridge, readBack: brief)
                == CameraSetupOutcome(succeeded: false, detail: "the camera did not answer again after restarting its network service"))
        #expect(gone.onvif.actions.value.isEmpty, "a camera that does not answer is not written twice")
    }

    /// A camera that answers "OK" and shows none of the bridge's servers once the whole read-back has passed (it ignored the keys, or shows
    /// what it showed before) is a wrong guess about the CGI: ONVIF is tried, and succeeds. Restore goes the same way. When ONVIF refuses
    /// too, the camera's own API's part is said after ONVIF's.
    @Test func anOKThatChangesNothingFallsThroughToONVIF() async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        camera.writeMode.set(.ignores)
        let service = service(camera)
        let read = try #require(try await service.readDNS())

        #expect(try await service.applyDNS(server: bridge, readBack: brief) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.writes.value == [setConfig("eth0", bridge, bridge)], "the CGI was asked once, and said OK")
        #expect(camera.readsAfterTheWrite.value >= 2, "and read back for the wait before ONVIF was tried")
        #expect(camera.onvif.dns.value.manualServers == [bridge, bridge] && !camera.onvif.dns.value.fromDHCP)

        camera.network.update { $0.servers["eth0"] = [bridge, bridge] }   // one camera: its CGI table shows what ONVIF set
        #expect(try await service.restoreDNS(read.backup, readBack: brief) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.writes.value.last == setConfig("eth0", "192.168.77.1", "8.8.8.8"), "Restore asked the CGI first too")
        #expect(camera.onvif.dns.value.manualServers == ["192.168.77.1", "8.8.8.8"])

        let both = try await FakeDahuaCamera.start()
        defer { both.stop() }
        both.writeMode.set(.ignores)
        both.onvif.refuseDNSChanges.set(true)
        let refused = try await self.service(both).applyDNS(server: bridge, readBack: brief)
        #expect(!refused.succeeded && refused.detail.contains("InvalidArgVal") && refused.detail.hasSuffix("; the camera’s own API said OK but kept its own DNS servers"),
                "\(refused.detail)")
    }

    /// A camera that already asks the bridge in both slots is not written.
    @Test func aCameraThatAlreadyAsksTheBridgeInBothSlotsIsNotWritten() async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        camera.network.update { $0.servers["eth0"] = [bridge, bridge] }
        let service = service(camera)
        #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via Dahua API"))
        #expect(camera.writes.value.isEmpty)
        let (reading, backup) = try await service.readInternetWatch(server: bridge)
        #expect(reading.state == .alreadyRight && backup?.method == .dahuaCGI)
    }

    /// The setup's preview: what the camera asks now against the bridge, with the backup that Restore uses.
    @Test func theWatchStepIsPlannedFromTheCamerasOwnReading() async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        let (reading, backup) = try await service(camera).readInternetWatch(server: bridge)
        #expect(reading.state == .willChange)
        #expect(reading.changes == [.init(label: "DNS", now: "192.168.77.1 and 8.8.8.8", after: "the bridge (\(bridge))")])
        #expect(backup == CameraDNSBackup(method: .dahuaCGI, fromDHCP: false, servers: ["192.168.77.1", "8.8.8.8"], dahuaInterface: "eth0"))
        #expect(camera.writes.value.isEmpty)
    }

    // MARK: Not Dahua's

    /// A camera whose `configManager.cgi` is a web server's login page (HTML), a 404, or a table with no DNS slots is not one this API
    /// serves: ONVIF reads and writes, as before, and nothing is refused.
    @Test(arguments: [FakeDahuaCamera.Answer.html, .notFound, .tableWithoutDNS])
    func aNonDahuaAnswerFallsBackToONVIF(_ answer: FakeDahuaCamera.Answer) async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        camera.answer.set(answer)
        let service = service(camera)

        let read = try #require(try await service.readDNS())
        #expect(read.method == .onvifMinimal && read.servers == ["1.1.1.1", "8.8.8.8"] && read.fromDHCP)
        #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.onvif.dns.value.manualServers == [bridge, bridge] && !camera.onvif.dns.value.fromDHCP)
        #expect(camera.writes.value.isEmpty, "nothing was written through the CGI")
        #expect(try await service.restoreDNS(read.backup, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.onvif.dns.value.fromDHCP, "a backup read through ONVIF goes back through ONVIF")
    }

    /// An IPv6 address is not one the CGI takes (an IPv4 address in each slot): ONVIF, as before.
    @Test func anIPv6AddressGoesThroughONVIF() async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        #expect(try await service(camera).applyDNS(server: "2001:db8::10", readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.writes.value.isEmpty && camera.onvif.dns.value.manualServers == ["2001:db8::10", "2001:db8::10"])
    }

    // MARK: Restoring

    /// Restore writes the two slots the camera had on the interface the backup names, even if the camera's default interface is another
    /// one by now; a camera that already has them is not written again.
    @Test func restorePutsTheOldServersBack() async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        let service = service(camera)
        let read = try #require(try await service.readDNS())
        #expect(try await service.applyDNS(server: bridge, readBack: quick).succeeded)
        camera.network.update { $0.defaultInterface = "eth2" }

        #expect(try await service.restoreDNS(read.backup, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via Dahua API"))
        #expect(camera.writes.value.last == setConfig("eth0", "192.168.77.1", "8.8.8.8"))
        #expect(camera.network.value.servers["eth0"] == ["192.168.77.1", "8.8.8.8"] && camera.network.value.servers["eth2"] == ["192.168.77.2", "192.168.77.3"])
        #expect(camera.onvif.actions.value.isEmpty)

        let writes = camera.writes.value.count
        #expect(try await service.restoreDNS(read.backup, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via Dahua API"))
        #expect(camera.writes.value.count == writes, "it already has them")
    }

    /// A slot the camera had empty goes back as 0.0.0.0, the camera's own way to show one; a slot it cannot take back (not an IPv4 address) is
    /// left as it is, in words.
    @Test func restoreWritesAnEmptySlotAsZerosAndLeavesWhatItCannotWrite() async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        camera.network.update { $0.servers["eth0"] = [bridge, bridge] }
        let service = service(camera)
        let emptied = CameraDNSBackup(method: .dahuaCGI, fromDHCP: false, servers: ["192.168.77.1", ""], dahuaInterface: "eth0")
        #expect(try await service.restoreDNS(emptied, readBack: quick).succeeded)
        #expect(camera.writes.value == [setConfig("eth0", "192.168.77.1", "0.0.0.0")])
        #expect(camera.network.value.servers["eth0"] == ["192.168.77.1", "0.0.0.0"])

        let writes = camera.writes.value.count
        let name = CameraDNSBackup(method: .dahuaCGI, fromDHCP: false, servers: ["dns.example.net", "8.8.8.8"], dahuaInterface: "eth0")
        let refused = try await service.restoreDNS(name, readBack: quick)
        #expect(!refused.succeeded && refused.detail.hasPrefix("the camera’s old DNS servers"), "\(refused)")
        let noInterface = try await service.restoreDNS(CameraDNSBackup(method: .dahuaCGI, fromDHCP: false, servers: ["8.8.8.8"]), readBack: quick)
        #expect(!noInterface.succeeded)
        #expect(camera.writes.value.count == writes, "nothing was written for either")
    }

    // MARK: Refusals

    /// "Error" with the camera's words, whether it answers 200 or 400, is not the end of the step: ONVIF follows (Camera Bridge cannot know
    /// that a camera takes the encoded brackets of `DnsServers[0]`), and when it refuses too, the camera's words stay in the refusal.
    @Test(arguments: [(200, "Error\r\nBad Request!\r\n"), (400, "Error\nBad Request!\n")])
    func aRefusalCarriesTheCamerasWords(_ status: Int, _ body: String) async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        camera.writeMode.set(.answers(status: status, body: body))
        camera.onvif.refuseDNSChanges.set(true)
        let service = service(camera)
        let outcome = try await service.applyDNS(server: bridge, readBack: quick)
        #expect(!outcome.succeeded && !outcome.notPermitted)
        #expect(outcome.detail.contains("InvalidArgVal") && outcome.detail.hasSuffix("; the camera’s own API refused the change (Error Bad Request!)"),
                "ONVIF's words, then the camera's: \(outcome.detail)")
        #expect(camera.writes.value.count == 1, "the CGI was asked once")
        #expect(camera.onvif.actions.value.filter { $0 == "SetDNS" }.count == 3, "ONVIF followed with its three forms")
        #expect(camera.network.value.servers["eth0"] == ["192.168.77.1", "8.8.8.8"])

        // A camera whose ONVIF cannot be read either says so, with the camera's words.
        camera.onvif.noDNS.set(true)
        let unread = try await service.applyDNS(server: bridge, readBack: quick)
        #expect(unread == CameraSetupOutcome(succeeded: false,
                                             detail: "the camera does not show its DNS servers; the camera’s own API refused the change (Error Bad Request!)"))
    }

    /// A camera that refuses the CGI write (it may not read the encoded brackets of `DnsServers%5B0%5D`) is pointed at the bridge through
    /// ONVIF as before this API was used, and Restore goes the same way: the CGI is asked, refuses again, and ONVIF puts the servers back.
    @Test(arguments: [(200, "Error\r\nBad Request!\r\n"), (400, "Error\nBad Request!\n")])
    func aRefusedWriteFallsThroughToONVIF(_ status: Int, _ body: String) async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        camera.writeMode.set(.answers(status: status, body: body))
        let service = service(camera)
        let read = try #require(try await service.readDNS())
        #expect(read.method == .dahuaCGI)

        #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.writes.value == [setConfig("eth0", bridge, bridge)], "the CGI was tried first, once")
        #expect(camera.onvif.dns.value.manualServers == [bridge, bridge] && !camera.onvif.dns.value.fromDHCP)
        camera.network.update { $0.servers["eth0"] = [bridge, bridge] }   // one camera: its CGI table shows what ONVIF set

        #expect(try await service.restoreDNS(read.backup, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.writes.value == [setConfig("eth0", bridge, bridge), setConfig("eth0", "192.168.77.1", "8.8.8.8")],
                "Restore asked the CGI first too")
        #expect(camera.onvif.dns.value.manualServers == ["192.168.77.1", "8.8.8.8"])
    }

    /// The exact request line and Digest `uri` of the reading and of the change: the brackets of `DnsServers[0]` go out as `%5B0%5D` (what
    /// `URLComponents` makes of them; not yet checked on a real camera, which is why a refusal falls through to ONVIF). A change of this
    /// form is a change of what real cameras are asked: see `docs/integrations/amcrest-dahua.md`.
    @Test func theWireFormIsPinned() async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        #expect(try await service(camera).applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via Dahua API"))

        let read = "/cgi-bin/configManager.cgi?action=getConfig&name=Network"
        let write = "/cgi-bin/configManager.cgi?action=setConfig&Network.eth0.DnsServers%5B0%5D=\(bridge)&Network.eth0.DnsServers%5B1%5D=\(bridge)"
        let requests = camera.server.requests
        #expect(Set(requests.map { $0.head.target }) == [read, write], "no other request line: \(requests.map { $0.head.target })")
        let sent = requests.filter { $0.head.target == write }
        #expect(!sent.isEmpty && sent.allSatisfy { $0.method == "GET" })
        for request in requests {
            guard let authorization = request.head.headers["Authorization"] else { continue }
            #expect(authorization.contains("uri=\"\(request.head.target)\""), "the Digest answer is for the line that was sent: \(authorization)")
        }
        #expect(camera.writes.value == [setConfig("eth0", bridge, bridge)], "and the camera reads it as the two keys")
    }

    /// An HTTP 403 is an account that may not change the network (its login works): the step ends there, ONVIF is not tried. An answer with
    /// no words at all is quoted as its status.
    @Test func anAccountThatMayNotChangeItIsNotAWrongPassword() async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        let key = "127.0.0.1:\(camera.server.port)"
        ONVIFLoginGuard.shared.clear(host: key)
        let service = service(camera)

        camera.writeMode.set(.answers(status: 403, body: ""))
        #expect(try await service.applyDNS(server: bridge, readBack: quick) == .notPermittedRefusal)
        #expect(ONVIFLoginGuard.shared.pause(host: key) == nil, "the login works: nothing is paused")
        #expect(camera.onvif.actions.value.isEmpty, "an account that may not change it ends the step: ONVIF is not tried")

        // Any other answer is a refusal that ONVIF follows; with no words of its own, the camera's refusal is its status.
        camera.writeMode.set(.answers(status: 500, body: ""))
        camera.onvif.refuseDNSChanges.set(true)
        let refused = try await service.applyDNS(server: bridge, readBack: quick)
        #expect(!refused.succeeded && refused.detail.hasSuffix("; the camera’s own API refused the change (HTTP 500)"), "\(refused.detail)")
        #expect(camera.onvif.actions.value.contains("SetDNS"))
    }

    /// A wrong password is a login refusal, thrown as for every other API: no refusal in words, no ONVIF after it, and the next call is
    /// paused (nothing is sent) so the camera is not asked again until it locks the account.
    @Test func aLoginRefusalIsALoginRefusal() async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        camera.rejectLogin.set(true)
        let service = service(camera)

        await #expect(throws: CameraAdapterError.unauthorized) { try await service.applyDNS(server: bridge, readBack: quick) }
        #expect(camera.writes.value.isEmpty && camera.onvif.actions.value.isEmpty, "nothing written, and ONVIF is not tried with the same password")
        #expect(camera.loginAttempts.value == 1)
        #expect(ONVIFLoginGuard.shared.pause(host: "127.0.0.1:\(camera.server.port)") != nil)

        let sent = camera.server.requests.count
        let backup = CameraDNSBackup(method: .dahuaCGI, fromDHCP: false, servers: ["8.8.8.8"], dahuaInterface: "eth0")
        await expectPausedLogin("read") { _ = try await service.readDNS() }
        await expectPausedLogin("apply") { _ = try await service.applyDNS(server: bridge, readBack: quick) }
        await expectPausedLogin("restore") { _ = try await service.restoreDNS(backup, readBack: quick) }
        await expectPausedLogin("preview") { _ = try await service.readInternetWatch(server: bridge) }
        #expect(camera.server.requests.count == sent, "nothing was sent to the camera while the login is paused")
        #expect(camera.loginAttempts.value == 1)
    }

    private func expectPausedLogin(_ what: String, _ call: () async throws -> Void) async {
        do {
            try await call()
            Issue.record("\(what): a paused login is thrown")
        } catch let error as CameraAdapterError {
            #expect(error.isLoginRefusal && error != .unauthorized, "\(what): paused, not tried again: \(error)")
        } catch {
            Issue.record("\(what): \(error)")
        }
    }

    // MARK: The API's own guards

    /// The address of a change is built from the interface and the servers: anything that is not a plain interface name and IPv4 addresses
    /// is never sent.
    @Test func hostileValuesNeverReachTheAddress() async throws {
        let camera = try await FakeDahuaCamera.start()
        defer { camera.stop() }
        let api = AmcrestAPI(endpoint: camera.endpoint, credentials: credentials)
        let hostile: [(String, [String])] = [("eth0&Network.eth0.IPAddress=192.168.77.99", [bridge]), ("", [bridge]), ("eth0", ["8.8.8.8&x=1"]),
                                             ("eth0", ["dns.example.net"]), ("eth0", ["2001:db8::10"]), ("eth0", []),
                                             ("eth0", [bridge, bridge, bridge])]
        for (interface, servers) in hostile {
            await #expect(throws: CameraAdapterError.self, "\(interface) \(servers)") { try await api.setNetworkDNS(interface: interface, servers: servers) }
        }
        #expect(camera.server.requests.isEmpty, "nothing was sent")
        try await api.setNetworkDNS(interface: "eth0", servers: [bridge, "0.0.0.0"])
        #expect(camera.writes.value == [setConfig("eth0", bridge, "0.0.0.0")])
    }

    /// The new method is stored by name, a backup saved before it has no interface, and it is no way to change the encoder or the clock.
    @Test func theNewMethodIsOnlyForDNS() throws {
        let backup = CameraDNSBackup(method: .dahuaCGI, fromDHCP: false, servers: ["192.168.77.1", "0.0.0.0"], dahuaInterface: "eth2")
        #expect(try JSONDecoder().decode(CameraDNSBackup.self, from: JSONEncoder().encode(backup)) == backup)
        let older = try JSONDecoder().decode(CameraDNSBackup.self, from: Data(#"{"method":"onvifMinimal","fromDHCP":false,"servers":["8.8.8.8"]}"#.utf8))
        #expect(older.dahuaInterface == nil)
        #expect(CameraConfigMethod(rawValue: "dahuaCGI") == .dahuaCGI && CameraConfigMethod.dahuaCGI.displayName == "Dahua API")
        for vendor in CameraVendor.allCases {
            #expect(!CameraConfigMethod.attemptOrder(vendor: vendor, preferred: .dahuaCGI).contains(.dahuaCGI), "\(vendor)")
        }
    }
}

/// A loopback Dahua / Amcrest / Lorex camera: Digest-protected `configManager.cgi` for `Network` (the default interface and each
/// interface's `DnsServers[0|1]`, answered as `table.Network.…` lines), with an ONVIF device on its own port for the cameras whose CGI is
/// not Dahua's.
final class FakeDahuaCamera: Sendable {
    /// What the CGI answers.
    enum Answer: Sendable, CustomTestStringConvertible {
        case dahua
        /// A web server's login page for any path (200), as another maker's camera may answer.
        case html
        case notFound
        /// `table.Network.` lines with the default interface and nothing else.
        case tableWithoutDNS

        var testDescription: String {
            switch self {
            case .dahua: "dahua"
            case .html: "html"
            case .notFound: "404"
            case .tableWithoutDNS: "a table without DNS slots"
            }
        }
    }

    /// How `setConfig` is answered.
    enum WriteMode: Sendable, Equatable {
        /// Applies the change and answers OK.
        case accept
        /// Answers OK and keeps the second slot as it was.
        case keepsSecond
        /// Answers OK and changes nothing.
        case ignores
        /// Applies the change, then closes the connection without answering (the network restarts).
        case appliesThenDrops
        /// Answers this status and body, and changes nothing.
        case answers(status: Int, body: String)
    }

    struct Network: Sendable, Equatable {
        var defaultInterface = "eth0"
        /// `DnsServers[0]`, `[1]` per interface (the Wi-Fi model's `eth2` too).
        var servers = ["eth0": ["192.168.77.1", "8.8.8.8"], "eth2": ["192.168.77.2", "192.168.77.3"]]
    }

    /// A change the camera has answered but shows only after `readsLeft` more reads.
    private struct Pending: Sendable {
        var readsLeft: Int
        var interface: String
        var servers: [String]
    }

    let server: MockHTTPServer
    let onvif: MockONVIFCamera
    let answer = Box(Answer.dahua)
    let writeMode = Box(WriteMode.accept)
    let network = Box(Network())
    /// The `setConfig` calls received: the decoded query (name → value) of each.
    let writes = Box<[[String: String]]>([])
    /// A change shows only after this many reads (0: at once), and the camera answers nothing meanwhile while `silentWhileApplying`.
    let applyAfterReads = Box(0)
    let silentWhileApplying = Box(false)
    /// `getConfig` calls since the last `setConfig`.
    let readsAfterTheWrite = Box(0)
    let rejectLogin = Box(false)
    /// Credentialed requests that were challenged again.
    let loginAttempts = Box(0)
    private let pending = Box<Pending?>(nil)

    var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port), onvifPort: Int(onvif.server.port)) }

    private init(server: MockHTTPServer, onvif: MockONVIFCamera) {
        self.server = server
        self.onvif = onvif
    }

    static func start() async throws -> FakeDahuaCamera {
        let holder = Box<FakeDahuaCamera?>(nil)
        let server = try await MockHTTPServer.start { request in
            guard let camera = holder.value else { return .status(503) }
            return camera.handle(request)
        }
        let camera = FakeDahuaCamera(server: server, onvif: try await MockONVIFCamera.start())
        holder.set(camera)
        ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(server.port)")
        return camera
    }

    func stop() {
        ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(server.port)")
        server.stop()
        onvif.stop()
    }

    private func handle(_ request: MockRequest) -> MockResponse {
        guard request.path == "/cgi-bin/configManager.cgi" else { return .status(404) }
        switch answer.value {
        case .html:
            return .full(status: 200, headers: [("Content-Type", "text/html")], body: Data("<html><body>Please sign in <a href=\"/?a=1\">here</a></body></html>".utf8))
        case .notFound:
            return .status(404)
        case .dahua, .tableWithoutDNS:
            break
        }
        let authorization = request.head.headers["Authorization"]
        guard !rejectLogin.value, isDigestAuthorization(authorization) else {
            if authorization != nil { loginAttempts.update { $0 += 1 } }
            return .digestChallenge()
        }
        switch (request.query("action"), request.query("name")) {
        case ("getConfig", "Network"):
            return read()
        case ("setConfig", _):
            return write(request)
        default:
            return .full(status: 400, headers: [], body: Data("Error\r\nBad Request!\r\n".utf8))
        }
    }

    private func read() -> MockResponse {
        readsAfterTheWrite.update { $0 += 1 }
        let restarting = pending.update { pending -> Bool in
            guard let waiting = pending else { return false }
            guard waiting.readsLeft == 0 else { pending?.readsLeft -= 1; return true }
            network.update { $0.servers[waiting.interface] = waiting.servers }
            pending = nil
            return false
        }
        if restarting && silentWhileApplying.value { return .drop }
        let state = network.value
        var lines = ["table.Network.DefaultInterface=\(state.defaultInterface)", "table.Network.Domain=", "table.Network.Hostname=IPC"]
        for name in state.servers.keys.sorted() {
            lines += ["table.Network.\(name).DefaultGateway=192.168.77.1", "table.Network.\(name).DhcpEnable=true",
                      "table.Network.\(name).IPAddress=192.168.77.22", "table.Network.\(name).SubnetMask=255.255.255.0",
                      "table.Network.\(name).PhysicalAddress=02:00:00:00:00:22"]
            if answer.value == .dahua {
                for (index, server) in state.servers[name, default: []].enumerated() { lines.append("table.Network.\(name).DnsServers[\(index)]=\(server)") }
            }
        }
        return .full(status: 200, headers: [("Content-Type", "text/plain")], body: Data((lines.joined(separator: "\r\n") + "\r\n").utf8))
    }

    private func write(_ request: MockRequest) -> MockResponse {
        let items = Dictionary(request.head.queryItems.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { $1 })
        writes.update { $0.append(items) }
        readsAfterTheWrite.set(0)
        let mode = writeMode.value
        if case .answers(let status, let body) = mode { return .full(status: status, headers: [], body: Data(body.utf8)) }
        if mode != .ignores {
            // `Network.<interface>.DnsServers[<n>]=<address>`
            var interface = ""
            var servers: [String] = []
            for (name, value) in items.sorted(by: { $0.key < $1.key }) where name.hasPrefix("Network.") && name.contains(".DnsServers[") {
                let parts = name.dropFirst("Network.".count).components(separatedBy: ".DnsServers[")
                interface = parts[0]
                if servers.isEmpty { servers = network.value.servers[interface] ?? [] }
                guard let index = Int(parts[1].dropLast()), servers.indices.contains(index), !(mode == .keepsSecond && index == 1) else { continue }
                servers[index] = value
            }
            if applyAfterReads.value > 0 {
                pending.set(Pending(readsLeft: applyAfterReads.value, interface: interface, servers: servers))
            } else {
                network.update { $0.servers[interface] = servers }
            }
        }
        return mode == .appliesThenDrops ? .drop : .full(status: 200, headers: [("Content-Type", "text/plain")], body: Data("OK\r\n".utf8))
    }
}
#endif
