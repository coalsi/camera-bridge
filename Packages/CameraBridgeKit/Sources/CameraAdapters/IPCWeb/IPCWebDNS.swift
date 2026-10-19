import BridgeSupport
import Foundation

/// The internet guard's Watch (`CameraSettingsService+DNS.swift`) on an ONVIF camera that speaks the IP camera web API
/// (`CameraSettingsService.ipcWeb()`), through the camera's own network settings as its page's Network › Basic › TCP/IP tab
/// (`networkConfig.js`) reads and writes them: `getNetworkConfig` answers `<NetworkConfig>` with a `LANConfig` element (`MacAddress`, `DHCP`
/// (0: Mode Static; anything else: DHCP), `dhcpOffTime`, `ALLNET`, `IPAddress`, `Netmask`, `Gateway`, `DNS1` (the Preferred DNS Server),
/// `DNS2` (the Alternate DNS Server), `hostname`, `MTU`), and `setNetworkLANConfig` takes `<LANConfig …/>` back whole, the camera's address
/// included (202). These cameras' ONVIF reports a DNS change it does not keep (`SetDNS` read back as set, `GetDNS` showing the old servers
/// later), so this API goes first, and ONVIF only for a camera whose web API does not speak or shows no `LANConfig`; a camera of the family
/// whose web API cannot be asked now is refused (read: unreadable) with why, never written through ONVIF.
///
/// - The write is `LANConfig` as the camera wrote it with only `DNS1` and `DNS2` changed (the family's read-modify-write), and only when it
///   holds every attribute the page writes, each once, and its `IPAddress` is the address Camera Bridge reaches the camera at: anything else
///   could change the camera's address, and is refused rather than written (`ipcWebLANWrite`).
/// - The page disables its DNS fields in Mode DHCP (and sends them as read): a camera on DHCP is refused (`ipcWebDHCPRefusal`), and its mode
///   is switched only when the person chooses "Fix its address so the DNS stays" (`fixIPCWebAddress`: `DHCP` 0 with the camera's address,
///   mask and gateway as they are; Restore sets `DHCP` back).
/// - The camera may restart its network service after the write: it is read back through the same API for up to `DNSReadBackTiming.limit`;
///   a request that gets no answer meanwhile (a transport error, a timeout) is no refusal, and nor is a write it did not answer. A refusal
///   (an HTTP error, a SOAP fault) pauses the web API (`IPCWebClient`) and is said so.
/// - The answer also holds the camera's other passwords (Wi-Fi, e-mail, FTP), and `LANConfig` its address, MAC and host name: only
///   `LANConfig` is looked at, nothing of it is logged, and only `DHCP`, `DNS1` and `DNS2` are kept (`CameraDNSBackup.ipcWebAPI`), with the
///   address, mask and gateway "Fix its address so the DNS stays" fixed (`CameraDNSBackup.fixedAddress`); the MAC is shown in the setup's
///   preview and result only.
extension CameraSettingsService {
    static let ipcLANWrite = "setNetworkLANConfig"
    /// The attributes the camera's page writes with `setNetworkLANConfig`, in its settings export's order.
    static let ipcLANAttributes = ["MacAddress", "DHCP", "dhcpOffTime", "ALLNET", "IPAddress", "Netmask", "Gateway", "DNS1", "DNS2", "hostname", "MTU"]
    /// What the backup keeps of `LANConfig`.
    static let ipcDNSKeys = ["DHCP", "DNS1", "DNS2"]
    static let ipcWebDone = "via web API"

    /// Why a camera on DHCP is not written: its page sets DNS servers only in Mode Static. The words name the setup's choice that fixes the
    /// camera's address as it is, and where to change it by hand (the engine's "Change it by hand" help says the rest).
    static let ipcWebDHCPRefusal = "the camera takes its address from DHCP, and its own page sets DNS servers only in Mode Static "
        + "(Network › Basic, TCP/IP): choose “Fix its address so the DNS stays”, or set it there by hand"
    /// Restore on a camera switched to DHCP since Watch.
    static let ipcWebRestoreOnDHCP = "the camera now takes its address from DHCP, and its own page sets DNS servers only in Mode Static "
        + "(Network › Basic, TCP/IP), so Camera Bridge left them as they are"
    /// Network settings that would not go back exactly (`ipcWebLANWrite` nil).
    static let ipcWebLANLeftAlone = "the camera’s network settings are not ones Camera Bridge can write back exactly (its address could "
        + "change), so Camera Bridge left them as they are"

    static func ipcWebNotAskedAgain(_ unavailable: IPCWebUnavailable) -> String {
        "the camera was sent the change through its web API, but could not be asked again: \(unavailable.reason)"
    }

    // MARK: Reading

    /// `LANConfig` of the network settings as the camera wrote it; nil when the answer has none, or one without `DHCP`, `DNS1` or `DNS2`.
    func ipcWebLAN(_ client: IPCWebClient) async throws -> String? {
        let network = try await client.read(Self.ipcNetworkRead, root: "NetworkConfig")
        guard let lan = IPCWebXML.element("LANConfig", in: network), Self.ipcWebDNSValues(in: lan) != nil else { return nil }
        return String(lan)
    }

    /// `ipcWebLAN` for the DNS steps: no answer, an answer without `NetworkConfig`, or a refusal (which pauses the web API) is
    /// `IPCWebUnavailable` (never ONVIF's answers instead); a login refusal and a cancellation are thrown.
    func ipcWebLANRead(_ client: IPCWebClient) async throws -> String? {
        do {
            return try await ipcWebLAN(client)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CameraAdapterError where error.isLoginRefusal {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw client.isPaused ? IPCWebUnavailable.paused : IPCWebUnavailable.noAnswer
        }
    }

    /// `LANConfig`'s `DHCP`, `DNS1` and `DNS2`, trimmed; nil when one is missing.
    static func ipcWebDNSValues(in lan: some StringProtocol) -> [String: String]? {
        var values: [String: String] = [:]
        for key in ipcDNSKeys {
            guard let value = IPCWebXML.attribute(key, of: lan) else { return nil }
            values[key] = value.trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// The values as a reading: from DHCP unless `DHCP` is 0 (as the page takes it); the servers `DNS1` and `DNS2`, each once, an empty slot
    /// (0.0.0.0) none; the backup keeps both slots and the values as they are. On DHCP the page shows the servers the camera has now as it
    /// shows its address, and they are taken as the servers in use (a camera that shows the bridge asks it; one whose DHCP hands out the
    /// bridge while it shows others reads as not watched, which is the safe side).
    static func ipcWebReading(_ values: [String: String]) -> CameraDNSReading {
        let slots = [values["DNS1"] ?? "", values["DNS2"] ?? ""]
        let fromDHCP = values["DHCP"] != "0"
        return CameraDNSReading(servers: distinctServers(slots), fromDHCP: fromDHCP, method: .ipcWebAPI,
                                backup: CameraDNSBackup(method: .ipcWebAPI, fromDHCP: fromDHCP, servers: slots, ipcWebAPI: values))
    }

    /// The slots that name a server, each once (an IPv6 address however it is written); an empty slot (0.0.0.0, ::) names none.
    static func distinctServers(_ slots: [String]) -> [String] {
        var servers: [String] = []
        for slot in slots where !CameraDNSReading.isEmptySlot(slot) && !servers.contains(where: { ONVIFClient.sameAddress($0, slot) }) {
            servers.append(slot)
        }
        return servers
    }

    /// `readDNS()` of an ONVIF camera that speaks the IP camera web API: nil when it does not (`ipcWeb()` `.none`) or shows no `LANConfig`
    /// (ONVIF then). Throws `IPCWebUnavailable` for a camera of the family whose web API cannot be asked now, and a login refusal.
    func readIPCWebDNS() async throws -> CameraDNSReading? {
        switch try await ipcWeb() {
        case .none:
            return nil
        case .unavailable(let why):
            throw IPCWebUnavailable(reason: why)
        case .speaks(let client, _):
            guard let lan = try await ipcWebLANRead(client), let values = Self.ipcWebDNSValues(in: lan) else { return nil }
            var reading = Self.ipcWebReading(values)
            reading.addressing = Self.ipcWebAddressing(in: lan)
            return reading
        }
    }

    /// Why "Watch its internet" is not offered for a reading through the IP camera web API that does not ask the bridge: the camera is on
    /// DHCP, and its page sets DNS servers only in Mode Static. nil otherwise.
    static func ipcWebWatchRefusal(_ reading: CameraDNSReading) -> String? {
        reading.method == .ipcWebAPI && reading.fromDHCP ? ipcWebDHCPRefusal : nil
    }

    // MARK: Writing

    /// `lan` (`LANConfig` as the camera wrote it) with only `DNS1` and `DNS2` replaced (and `DHCP` with `dhcp`), every other character as
    /// it was: what `setNetworkLANConfig` takes. nil (refused rather than written) when the camera is not in Mode Static (`DHCP` 0) and no
    /// `dhcp` is given (the mode "Fix its address so the DNS stays" sets, 0, or the one Restore puts back: digits only), an attribute the page
    /// writes is missing or one appears twice, `IPAddress` is not `host` (the address Camera Bridge reaches the camera at, when that is an IPv4
    /// address: another interface's settings, or ones that would move the camera), or a server is neither an IPv4 address nor empty. What the
    /// page does not write (another attribute, a child) goes back as the camera wrote it, as the family's other writes do; the camera's
    /// address, mask and gateway always do.
    static func ipcWebLANWrite(_ lan: String, dns1: String, dns2: String, host: String, dhcp: String? = nil) -> String? {
        let names = IPCWebXML.attributes(of: lan).map(\.name)
        guard Set(names).count == names.count, Set(ipcLANAttributes).isSubset(of: names),
              dhcp != nil || IPCWebXML.attribute("DHCP", of: lan)?.trimmingCharacters(in: .whitespaces) == "0",
              dhcp.map({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) ?? true,
              [dns1, dns2].allSatisfy({ $0.isEmpty || ONVIFClient.isIPv4($0) }) else { return nil }
        if ONVIFClient.isIPv4(host), IPCWebXML.attribute("IPAddress", of: lan)?.trimmingCharacters(in: .whitespaces) != host { return nil }
        var values = ["DNS1": dns1, "DNS2": dns2]
        if let dhcp { values["DHCP"] = dhcp }
        return IPCWebXML.replacingAttributes(values, in: lan)
    }

    // MARK: Fix its address so the DNS stays

    /// `LANConfig`'s own address as the choice keeps it (`IPAddress`, `Netmask`, `Gateway`), with `MacAddress` for the router reservation;
    /// nil when not whole.
    static func ipcWebAddressing(in lan: some StringProtocol) -> CameraAddressing? {
        func value(_ name: String) -> String? { IPCWebXML.attribute(name, of: lan)?.trimmingCharacters(in: .whitespaces) }
        return CameraAddressing.whole(address: value("IPAddress"), mask: value("Netmask"), gateway: value("Gateway"),
                                      hardwareAddress: CameraAddressing.hardwareAddress(value("MacAddress")))
    }

    /// The camera is in Mode DHCP (`DHCP` anything but 0, as its page takes it).
    static func ipcWebOnDHCP(_ lan: some StringProtocol) -> Bool { IPCWebXML.attribute("DHCP", of: lan)?.trimmingCharacters(in: .whitespaces) != "0" }

    /// In Mode Static with exactly `addressing`'s address, mask and gateway.
    static func ipcWebFixed(_ lan: some StringProtocol, at addressing: CameraAddressing) -> Bool {
        !ipcWebOnDHCP(lan) && ipcWebAddressing(in: lan)?.sameAddress(as: addressing) == true
    }

    /// The address of a camera that speaks the IP camera web API, for the choice: in Mode DHCP, whole, and `cameraAddress`; nil otherwise.
    func ipcWebAddressToFix(cameraAddress: String) async throws -> CameraAddressing? {
        guard case .speaks(let client, _) = try await ipcWeb(), let lan = try await ipcWebLANRead(client), Self.ipcWebOnDHCP(lan),
              let addressing = Self.ipcWebAddressing(in: lan), addressing.address == cameraAddress else { return nil }
        return addressing
    }

    /// "Fix its address so the DNS stays" through the IP camera web API: `LANConfig` read again, then written back as the camera wrote it with
    /// `DHCP` 0 (Mode Static) and the bridge in `DNS1` and `DNS2`, its address, mask and gateway as they are (they are `expected`, or nothing is
    /// written: `addressChangedRefusal`), and read back while the camera restarts its network service. nil when the camera does not speak that
    /// API or shows no `LANConfig` (ONVIF then); a camera of the family whose web API cannot be asked now is refused with why.
    func fixIPCWebAddress(server: String, expected: CameraAddressing, readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome? {
        let client: IPCWebClient
        switch try await ipcWeb() {
        case .none: return nil
        case .unavailable(let why): return .refused(why).untouched
        case .speaks(let speaking, _): client = speaking
        }
        let lan: String
        do {
            guard let read = try await ipcWebLANRead(client) else { return nil }
            lan = read
        } catch let unavailable as IPCWebUnavailable {
            return .refused(unavailable.reason).untouched
        }
        guard Self.ipcWebOnDHCP(lan), Self.ipcWebAddressing(in: lan)?.sameAddress(as: expected) == true else {
            return .refused(Self.addressChangedRefusal(expected)).untouched
        }
        guard let edited = Self.ipcWebLANWrite(lan, dns1: server, dns2: server, host: endpoint.host, dhcp: "0") else {
            return .refused(Self.ipcWebLANLeftAlone).untouched
        }
        if let refusal = try await writeIPCWebLAN(edited, client) { return refusal.untouched }   // refused: nothing changed
        var last: String?
        let done: Bool
        do {
            done = try await ipcWebReadBack(client, readBack) { lan in
                last = lan
                return Self.ipcWebFixed(lan, at: expected) && Self.ipcWebDNSValues(in: lan).map { Self.ipcWebReading($0).pointsAt(server) } == true
            }
        } catch let unavailable as IPCWebUnavailable {
            return .refused(Self.ipcWebNotAskedAgain(unavailable))
        }
        if done {
            log.info("Fixed the camera's address as it was and set its DNS servers through its web API")
            return CameraSetupOutcome(succeeded: true, detail: Self.ipcWebDone, addressFixed: true)
        }
        guard let last else { return .refused(Self.keptAfterRestart(nil, server: server)) }
        guard Self.ipcWebFixed(last, at: expected) else { return .refused(Self.addressNotFixed) }
        return CameraSetupOutcome(succeeded: false, detail: Self.keptAfterRestart(Self.ipcWebDNSValues(in: last).map(Self.ipcWebReading), server: server),
                                  addressFixed: true)
    }

    /// Restore after the choice through the IP camera web API: while the camera still has the fixed address, `LANConfig` with `DHCP` as it
    /// was (1 when the backup does not say) and `DNS1` and `DNS2` as they were when they were read this way (else as they are: on DHCP the
    /// camera takes DHCP's), read back by its mode. nil when it is in Mode DHCP already; one whose address was changed by hand since is left
    /// as it is, said so. A camera that no longer speaks the API, or shows no `LANConfig`, is refused (its address is set there only).
    func restoreIPCWebFixedAddress(_ plain: CameraDNSBackup, fixed: CameraAddressing, readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome? {
        let client: IPCWebClient
        switch try await ipcWeb() {
        case .none: return .refused("the camera no longer shows its network settings")
        case .unavailable(let why): return .refused(why)
        case .speaks(let speaking, _): client = speaking
        }
        let lan: String
        do {
            guard let read = try await ipcWebLANRead(client) else { return .refused("the camera no longer shows its network settings") }
            lan = read
        } catch let unavailable as IPCWebUnavailable {
            return .refused(unavailable.reason)
        }
        if Self.ipcWebOnDHCP(lan) { return nil }
        guard Self.ipcWebFixed(lan, at: fixed) else { return .refused(Self.addressChangedSinceFixed(fixed)) }
        let saved = plain.method == .ipcWebAPI ? plain.ipcWebAPI ?? [:] : [:]
        let dhcp = saved["DHCP"].flatMap { $0 == "0" || $0.isEmpty ? nil : $0 } ?? "1"
        let now = Self.ipcWebDNSValues(in: lan) ?? [:]
        func slot(_ key: String) -> String {
            if let value = saved[key], value.isEmpty || ONVIFClient.isIPv4(value) { return value }
            return now[key] ?? ""
        }
        guard let edited = Self.ipcWebLANWrite(lan, dns1: slot("DNS1"), dns2: slot("DNS2"), host: endpoint.host, dhcp: dhcp) else {
            return .refused(Self.ipcWebLANLeftAlone)
        }
        if let refusal = try await writeIPCWebLAN(edited, client) { return refusal }
        do {
            guard try await ipcWebReadBack(client, readBack, { IPCWebXML.attribute("DHCP", of: $0)?.trimmingCharacters(in: .whitespaces) == dhcp }) else {
                return .refused(Self.addressNotBackOnDHCP)
            }
        } catch let unavailable as IPCWebUnavailable {
            return .refused(Self.ipcWebNotAskedAgain(unavailable))
        }
        log.info("Put the camera back on DHCP through its web API")
        return CameraSetupOutcome(succeeded: true, detail: Self.ipcWebDone)
    }

    /// Points every DNS server of a camera that speaks the IP camera web API at `server` (`applyDNS`): both slots the bridge, in Mode Static
    /// only, then read back through the same API while the camera restarts its network service. Already done when the camera asks the bridge
    /// and no other (its router's DHCP may hand it out). nil when the camera does not speak that API or shows no `LANConfig` (ONVIF then); a
    /// camera of the family whose web API cannot be asked now is refused with why. Throws a login refusal and a cancellation.
    func applyIPCWebDNS(server: String, readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome? {
        let client: IPCWebClient
        switch try await ipcWeb() {
        case .none: return nil
        case .unavailable(let why): return .refused(why)
        case .speaks(let speaking, _): client = speaking
        }
        let lan: String
        do {
            guard let read = try await ipcWebLANRead(client) else { return nil }
            lan = read
        } catch let unavailable as IPCWebUnavailable {
            return .refused(unavailable.reason)
        }
        guard let values = Self.ipcWebDNSValues(in: lan) else { return nil }
        let reading = Self.ipcWebReading(values)
        if reading.pointsAt(server) { return CameraSetupOutcome(succeeded: true, detail: Self.ipcWebDone) }
        guard ONVIFClient.isIPv4(server) else { return .refused(Self.dnsIPv4Only) }
        if let refusal = Self.ipcWebWatchRefusal(reading) { return .refused(refusal) }
        guard let edited = Self.ipcWebLANWrite(lan, dns1: server, dns2: server, host: endpoint.host) else { return .refused(Self.ipcWebLANLeftAlone) }
        if let refusal = try await writeIPCWebLAN(edited, client) { return refusal }
        var last: CameraDNSReading?
        let done: Bool
        do {
            done = try await ipcWebReadBack(client, readBack) { lan in
                guard let values = Self.ipcWebDNSValues(in: lan) else { return false }
                let now = Self.ipcWebReading(values)
                last = now
                return now.pointsAt(server)
            }
        } catch let unavailable as IPCWebUnavailable {
            return .refused(Self.ipcWebNotAskedAgain(unavailable))
        }
        guard done else { return .refused(Self.keptAfterRestart(last, server: server)) }
        log.info("Set the camera's DNS servers through its web API")
        return CameraSetupOutcome(succeeded: true, detail: Self.ipcWebDone)
    }

    // MARK: Restoring

    /// Puts the DNS servers of a camera that speaks the IP camera web API back as `backup` has them (`restoreDNS`), then reads them back the
    /// same way: its own values (`ipcWebAPI`) exactly; a backup an earlier build saved through ONVIF, without them, as its servers set by hand
    /// (`ipcWebDNS(restoring:)`), in Mode Static only (on DHCP Watch never writes through the page: it goes back through ONVIF, as that build
    /// wrote it). Nothing is written when the camera already has them. A camera switched to DHCP since Watch is refused (its page cannot take
    /// DNS servers then). nil when the camera does not speak that API, shows no `LANConfig`, or the backup cannot be said in its two slots
    /// (ONVIF then); a camera of the family whose web API cannot be asked now is refused with why. Throws a login refusal and a cancellation.
    func restoreIPCWebDNS(_ backup: CameraDNSBackup, readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome? {
        let client: IPCWebClient
        switch try await ipcWeb() {
        case .none: return nil
        case .unavailable(let why): return .refused(why)
        case .speaks(let speaking, _): client = speaking
        }
        let lan: String
        do {
            guard let read = try await ipcWebLANRead(client) else { return nil }
            lan = read
        } catch let unavailable as IPCWebUnavailable {
            return .refused(unavailable.reason)
        }
        guard let now = Self.ipcWebDNSValues(in: lan), let target = Self.ipcWebDNS(restoring: backup) else { return nil }
        if target.matches(now) { return CameraSetupOutcome(succeeded: true, detail: Self.ipcWebDone) }
        if now["DHCP"] != "0" {
            guard let saved = backup.ipcWebAPI else { return nil }
            // Saved on DHCP too: the camera takes its servers from DHCP, as it did.
            return saved["DHCP"] != "0" ? CameraSetupOutcome(succeeded: true, detail: Self.ipcWebDone) : .refused(Self.ipcWebRestoreOnDHCP)
        }
        guard let edited = Self.ipcWebLANWrite(lan, dns1: target.slots[0], dns2: target.slots[1], host: endpoint.host) else {
            return .refused(Self.ipcWebLANLeftAlone)
        }
        if let refusal = try await writeIPCWebLAN(edited, client) { return refusal }
        do {
            guard try await ipcWebReadBack(client, readBack, { Self.ipcWebDNSValues(in: $0).map(target.matches) == true }) else { return .refused(Self.notTakenBack) }
        } catch let unavailable as IPCWebUnavailable {
            return .refused(Self.ipcWebNotAskedAgain(unavailable))
        }
        log.info("Set the camera's DNS servers through its web API")
        return CameraSetupOutcome(succeeded: true, detail: Self.ipcWebDone)
    }

    /// What Restore writes into `DNS1` and `DNS2` for `backup`, and how the camera's values show it took: the camera's own values
    /// (`ipcWebAPI`) slot by slot, an empty slot (0.0.0.0, nothing) none on either side; else (saved through ONVIF by a build before
    /// 2026-10-18) its servers set by hand, one server in both slots, matched by the servers the slots name. nil when the backup cannot be said
    /// in the two slots (from DHCP, no server, more than two).
    static func ipcWebDNS(restoring backup: CameraDNSBackup) -> (slots: [String], matches: @Sendable ([String: String]) -> Bool)? {
        if let saved = backup.ipcWebAPI {
            guard let dns1 = saved["DNS1"], let dns2 = saved["DNS2"] else { return nil }
            let slots = [dns1, dns2]
            return (slots, { sameSlots([$0["DNS1"] ?? "", $0["DNS2"] ?? ""], slots) })
        }
        let wanted = distinctServers(backup.servers)
        guard !backup.fromDHCP, let first = wanted.first, wanted.count <= 2 else { return nil }
        return ([first, wanted.count > 1 ? wanted[1] : first], { same(distinctServers([$0["DNS1"] ?? "", $0["DNS2"] ?? ""]), wanted) })
    }

    /// The same slots in the same order: the same address, or both empty (0.0.0.0, ::, nothing).
    static func sameSlots(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { left, right in
            (CameraDNSReading.isEmptySlot(left) && CameraDNSReading.isEmptySlot(right)) || ONVIFClient.sameAddress(left, right)
        }
    }

    // MARK: The write and its read-back

    /// `setNetworkLANConfig`; the refusal when the camera refused it (which pauses its web API). No answer is not a refusal: the camera may
    /// restart its network service before it answers, and the read-back tells. A login refusal and a cancellation are thrown.
    private func writeIPCWebLAN(_ element: String, _ client: IPCWebClient) async throws -> CameraSetupOutcome? {
        do {
            try await client.write(Self.ipcLANWrite, body: element)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CameraAdapterError where error.isLoginRefusal {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if client.isPaused { return .refused(IPCWebUnavailable.paused.reason) }
            log.debug("The camera did not answer the DNS change through its web API (it may be restarting its network)")
        }
        return nil
    }

    /// Reads `LANConfig` back every `timing.interval` until `timing.limit` has passed, while the camera restarts its network service: `check`
    /// tells whether it shows what was written. A read that gets no answer (a transport error, a timeout) is no answer yet; a refusal,
    /// which pauses the web API, throws `IPCWebUnavailable.paused` (nothing more would be sent); a login refusal and a cancellation are thrown.
    private func ipcWebReadBack(_ client: IPCWebClient, _ timing: DNSReadBackTiming, _ check: (String) -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timing.limit
        repeat {
            try await Task.sleep(for: timing.interval)
            do {
                if let lan = try await ipcWebLAN(client), check(lan) { return true }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CameraAdapterError where error.isLoginRefusal {
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if client.isPaused { throw IPCWebUnavailable.paused }
            }
        } while ContinuousClock.now < deadline
        return false
    }
}
