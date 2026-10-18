import BridgeSupport
import Foundation

/// The camera's DNS servers before the internet guard pointed them at the bridge (Watch), as `restoreDNS(_:)` puts them back.
public struct CameraDNSBackup: Sendable, Codable, Equatable {
    /// `.hikvisionISAPI`, `.onvifMinimal`, `.reolinkAPI` (a Reolink, read through its `LocalLink`), or `.ipcWebAPI` (a camera that speaks
    /// the IP camera web API, read through its `LANConfig`).
    public var method: CameraConfigMethod
    /// The camera took its DNS servers from DHCP. Always false through ISAPI.
    public var fromDHCP: Bool
    /// ONVIF: the servers set by hand (`DNSManual`), in order (a camera on DHCP may have none). ISAPI: the `PrimaryDNS` and `SecondaryDNS`
    /// addresses as the camera had them, "0.0.0.0" included. Reolink: its `dns1` and `dns2` as it had them. The IP camera web API: its
    /// `DNS1` and `DNS2` as it had them.
    public var servers: [String]
    /// ONVIF: the search domains, written back with the servers (nil: none known).
    public var searchDomains: [String]?
    /// The DNS settings of the camera's own API as they were, each value as text, when Camera Bridge can also write them that way: the
    /// IPCamera Web family's `<dns>` (`ondhcp`, `dns1`, `dns2`), Reolink's `LocalLink.dns` (`auto`, `dns1`, `dns2`). Restore writes them
    /// back through that API (the family's page whenever it can be asked; a Reolink's whenever it shows its `LocalLink`), so the camera's own
    /// two slots come back exactly. nil: none read (another camera, or a backup saved before they were).
    public var ownAPI: [String: String]?
    /// The IP camera web API's DNS values as the camera had them (`LANConfig`'s `DHCP`, `DNS1`, `DNS2`, each as text), for a reading through
    /// that API (`method` `.ipcWebAPI`): Restore writes `DNS1` and `DNS2` back through it, with the rest of `LANConfig` as the camera has it
    /// then (`CameraSettingsService.restoreIPCWebDNS`). nil: none read (another camera, or a backup saved before 2026-10-18).
    public var ipcWebAPI: [String: String]?

    public init(method: CameraConfigMethod, fromDHCP: Bool, servers: [String], searchDomains: [String]? = nil, ownAPI: [String: String]? = nil,
                ipcWebAPI: [String: String]? = nil) {
        self.method = method
        self.fromDHCP = fromDHCP
        self.servers = servers
        self.searchDomains = searchDomains
        self.ownAPI = ownAPI
        self.ipcWebAPI = ipcWebAPI
    }
}

/// What `CameraSettingsService.readDNS()` found: the DNS servers the camera asks, where it takes them from, the way they were read (and
/// are written), and the backup to restore them from.
public struct CameraDNSReading: Sendable, Equatable {
    /// The servers in use, each once: DHCP's when the camera takes them from DHCP. An empty slot (0.0.0.0, ::) is not among them.
    public var servers: [String]
    /// The camera takes them from DHCP (the router's): whoever points them at the bridge there, the router can change them when it renews
    /// the camera's address.
    public var fromDHCP: Bool
    /// `.hikvisionISAPI`, `.onvifMinimal`, `.reolinkAPI` or `.ipcWebAPI`.
    public var method: CameraConfigMethod
    public var backup: CameraDNSBackup
    /// The camera takes its servers from DHCP, but which ones is not known: a Reolink on automatic DNS (`LocalLink.dns.auto` 1) whose ONVIF
    /// did not say which servers DHCP gives (no answer, a refused or paused login, no `GetDNS`, ONVIF switched off in `GetNetPort`, an answer
    /// not from DHCP). `servers` is then empty and `pointsAt` false, and the Internet guard takes the reading as unreadable: it changes
    /// nothing (owner decision, 2026-10-18). False for a reading that knows its servers, none included ("no servers").
    public var serversUnknown: Bool

    public init(servers: [String], fromDHCP: Bool, method: CameraConfigMethod, backup: CameraDNSBackup, serversUnknown: Bool = false) {
        self.servers = servers
        self.fromDHCP = fromDHCP
        self.method = method
        self.backup = backup
        self.serversUnknown = serversUnknown
    }

    /// The camera asks `server` and no other (an IPv6 address matches however it is written), wherever it has its servers from: set by hand
    /// on the camera, by "Set up for Camera Bridge", or handed out by the router's DHCP (`fromDHCP` says which). A slot that holds 0.0.0.0
    /// or :: is empty, not a server.
    public func pointsAt(_ server: String) -> Bool {
        let used = servers.filter { !Self.isEmptySlot($0) }
        return !used.isEmpty && used.allSatisfy { ONVIFClient.sameAddress($0, server) }
    }

    /// A DNS slot that names no server: empty, 0.0.0.0, or :: however it is written (cameras show an emptied slot so).
    static func isEmptySlot(_ slot: String) -> Bool {
        let text = slot.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "0.0.0.0" || ONVIFClient.sameAddress(text, "::")
    }
}

/// How long a write that restarts the camera's network service (the IPCamera Web family's `set=eth`, Reolink's `SetLocalLink`) is read
/// back for: every `interval`, until `limit` has passed.
struct DNSReadBackTiming: Sendable {
    var limit: Duration = .seconds(30)
    var interval: Duration = .seconds(2)
}

/// The internet guard's Watch, the camera's side (docs/superpowers/specs/2026-10-17-internet-guard-design.md): every DNS server the camera
/// asks pointed at the bridge, so the bridge sees every name it looks up and answers none. Hikvision through ISAPI
/// (`/ISAPI/System/Network/interfaces/1/ipAddress`, `HikvisionISAPI+DNS.swift`, both slots); a Reolink through its own API (`GetLocalLink` /
/// `SetLocalLink`: it refuses ONVIF's writes to its ONVIF user), and through ONVIF only when it does not show its `LocalLink`; an ONVIF camera
/// that speaks the IP camera web API through that API's `LANConfig` (`IPCWebDNS.swift`: its ONVIF reports DNS changes it does not keep), and
/// through ONVIF only when that API does not speak or shows no `LANConfig`; other cameras through ONVIF (`SetDNS`), and where ONVIF leaves a
/// server the bridge is not, through the IPCamera Web family's page (`CameraSettingsService+IPCamWeb.swift`). Each write is read back, and a
/// refusal says what the camera kept; DNS changes nothing about how the home network reaches the camera.
extension CameraSettingsService {
    static let dnsIPv4Only = "this camera takes an IPv4 address for its DNS server"

    /// The camera's DNS servers; nil when it does not show them (no ISAPI document, no `LocalLink` for a Reolink, no ONVIF device service or
    /// `GetDNS`). A Reolink is read through its `LocalLink` (`dns.auto` 1: from DHCP), which is what its app sets; from DHCP, the servers in use
    /// are ONVIF's (`reolinkDHCPServers`), and when ONVIF does not say, the reading says it does not know them (`serversUnknown`). An ONVIF
    /// camera that speaks the IP camera web API is read through its `LANConfig` (`readIPCWebDNS`), what the camera keeps; while that API
    /// cannot be asked, `IPCWebUnavailable` is thrown (its ONVIF is not asked: the reading is unreadable). Throws the camera's login refusal.
    public func readDNS() async throws -> CameraDNSReading? {
        if vendor == .hikvision, let (_, servers) = try await isapiDNSDocument() {
            let backup = CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: servers.slots)
            return CameraDNSReading(servers: servers.servers, fromDHCP: false, method: .hikvisionISAPI, backup: backup)
        }
        if vendor == .reolink, let link = try await ownAPIRead({ try await reolinkLink() }) {
            var reading = Self.reolinkReading(link.dns)
            if reading.fromDHCP {
                let servers = try await reolinkDHCPServers()
                reading.servers = servers ?? []
                reading.serversUnknown = servers == nil
            }
            return reading
        }
        if vendor == .onvif, let reading = try await readIPCWebDNS() { return reading }
        if let client = await client(), let dns = try await onvifDNS(client) { return Self.onvifReading(dns) }
        return nil
    }

    /// Points every DNS server of the camera at `server` (the bridge's address), then reads it back. Through ISAPI, the IPCamera Web family's
    /// page, Reolink's API and the IP camera web API an IPv4 address only.
    public func applyDNS(server: String) async throws -> CameraSetupOutcome {
        try await applyDNS(server: server, readBack: DNSReadBackTiming())
    }

    func applyDNS(server: String, readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome {
        guard ONVIFClient.isIPv4(server) || ONVIFClient.isIPv6(server) else { return .refused("the DNS server must be an address") }
        if vendor == .hikvision, try await isapiDNSDocument() != nil {
            guard ONVIFClient.isIPv4(server) else { return .refused(Self.dnsIPv4Only) }
            return try await writeISAPIDNS([server, server], failure: { Self.kept($0, server: server) }) { $0.pointsAt(server) }
        }
        if vendor == .reolink, ONVIFClient.isIPv4(server), let outcome = try await setReolinkDNS(server: server, readBack: readBack) { return outcome }
        if vendor == .onvif, let outcome = try await applyIPCWebDNS(server: server, readBack: readBack) { return outcome }
        guard let client = await client(), let current = try await onvifDNS(client) else {
            if vendor == .reolink, !ONVIFClient.isIPv4(server), try await ownAPIRead({ try await reolinkLink() }) != nil {
                return .refused(Self.dnsIPv4Only)
            }
            return .refused("the camera does not show its DNS servers")
        }
        let onvif = try await writeONVIFBridge(client, server: server, searchDomains: current.searchDomains)
        guard !onvif.succeeded, vendor == .onvif else { return onvif }
        // ONVIF left a server that is not the bridge (or refused): the family's page, which sets both of its slots.
        return try await setIPCamWebDNS(server: server, onvif: client, failed: onvif, readBack: readBack)
    }

    /// Puts the camera's DNS servers back as the backup has them, then reads them back.
    public func restoreDNS(_ backup: CameraDNSBackup) async throws -> CameraSetupOutcome {
        try await restoreDNS(backup, readBack: DNSReadBackTiming())
    }

    func restoreDNS(_ backup: CameraDNSBackup, readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome {
        switch backup.method {
        case .hikvisionISAPI:
            return try await writeISAPIDNS(backup.servers, failure: { _ in Self.notTakenBack }) { Self.same($0.backup.servers, backup.servers) }
        case .reolinkAPI:
            return try await restoreReolinkDNS(backup, readBack: readBack) ?? .refused("the camera no longer shows its DNS servers")
        default:
            // The family's page, and a Reolink's `LocalLink`, put the camera's own two slots back exactly, whenever they can be asked; a
            // Reolink's backup an earlier build saved through ONVIF goes back through `LocalLink` too, as the run's change did.
            if vendor == .onvif, let saved = backup.ownAPI, let outcome = try await restoreIPCamWebDNS(saved, readBack: readBack) { return outcome }
            if vendor == .onvif, backup.ownAPI == nil, let outcome = try await restoreIPCWebDNS(backup, readBack: readBack) { return outcome }
            if vendor == .reolink, let outcome = try await restoreReolinkDNS(backup, readBack: readBack) { return outcome }
            guard let client = await client(), let current = try await onvifDNS(client) else { return .refused("the camera no longer shows its DNS servers") }
            return try await restoreONVIFDNS(client, backup, searchDomains: backup.searchDomains ?? current.searchDomains)
        }
    }

    static let notTakenBack = "the camera did not take its old DNS servers back"

    /// What a camera that does not ask the bridge alone kept, in words: "the camera asks Camera Bridge first but kept 8.8.8.8 as its other
    /// DNS server", or "the camera kept its own DNS servers" when it does not ask the bridge at all.
    static func kept(_ reading: CameraDNSReading, server: String) -> String {
        let others = reading.servers.filter { !ONVIFClient.sameAddress($0, server) }
        guard !reading.fromDHCP, !others.isEmpty, others.count < reading.servers.count else { return "the camera kept its own DNS servers" }
        let plural = others.count == 1 ? "" : "s"
        guard ONVIFClient.sameAddress(reading.servers[0], server) else {
            return "the camera kept \(CameraSetupText.list(others)) as DNS server\(plural) besides Camera Bridge, "
                + "and asks \(reading.servers[0]) first"
        }
        return "the camera asks Camera Bridge first but kept \(CameraSetupText.list(others)) as its other DNS server\(plural)"
    }

    /// Reads the camera back after a write that restarts its network service, every `interval` until `limit`: `check` tells whether it
    /// shows what was written. A read that fails while the camera restarts (no answer, a timeout, an HTTP or vendor error, a session gone)
    /// is no answer yet; a login refusal ends the wait (thrown), as does a cancellation.
    func readBackAfterRestart(_ timing: DNSReadBackTiming, _ check: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timing.limit
        repeat {
            try await Task.sleep(for: timing.interval)
            do {
                if try await check() { return true }
            } catch let error as CameraAdapterError where error.isLoginRefusal {
                throw error
            } catch let error as IPCamWebUnavailable {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        } while ContinuousClock.now < deadline
        return false
    }

    /// The same own-API DNS values: the switch (`ondhcp`, `auto`) as written, the servers as addresses.
    static func sameOwnDNS(_ lhs: [String: String], _ rhs: [String: String]) -> Bool {
        Set(lhs.keys) == Set(rhs.keys) && lhs.allSatisfy { key, value in
            guard let other = rhs[key] else { return false }
            return key.hasPrefix("dns") ? ONVIFClient.sameAddress(value, other) : value == other
        }
    }

    /// An own API's DNS values as a reading: `dns1` and `dns2` (the backup keeps both slots as they are), from DHCP when `dhcpKey` is "1".
    static func ownReading(_ values: [String: String], dhcpKey: String, method: CameraConfigMethod) -> CameraDNSReading {
        let slots = [values["dns1"] ?? "", values["dns2"] ?? ""]
        var servers: [String] = []
        for slot in slots where !CameraDNSReading.isEmptySlot(slot) && !servers.contains(where: { ONVIFClient.sameAddress($0, slot) }) {
            servers.append(slot)
        }
        let fromDHCP = values[dhcpKey] == "1"
        return CameraDNSReading(servers: servers, fromDHCP: fromDHCP, method: method,
                                backup: CameraDNSBackup(method: method, fromDHCP: fromDHCP, servers: slots, ownAPI: values))
    }

    // MARK: ONVIF

    /// `GetDNS`; nil when the camera does not answer it (a fault or an HTTP error that is not a login refusal).
    func onvifDNS(_ client: ONVIFClient) async throws -> ONVIFDNSSettings? {
        do { return try await client.dns() } catch let error as CameraAdapterError where !error.isLoginRefusal { return nil }
    }

    /// The servers in use (an empty slot, 0.0.0.0 or ::, left out); the backup keeps the servers set by hand as the camera has them.
    static func onvifReading(_ dns: ONVIFDNSSettings) -> CameraDNSReading {
        var servers: [String] = []
        for server in dns.servers where !CameraDNSReading.isEmptySlot(server) && !servers.contains(where: { ONVIFClient.sameAddress($0, server) }) {
            servers.append(server)
        }
        let backup = CameraDNSBackup(method: .onvifMinimal, fromDHCP: dns.fromDHCP, servers: dns.manualServers, searchDomains: dns.searchDomains)
        return CameraDNSReading(servers: servers, fromDHCP: dns.fromDHCP, method: .onvifMinimal, backup: backup)
    }

    /// `SetDNS` with the bridge alone; then, for a camera with fixed slots that took it but kept another server set by hand ("Patio New"
    /// kept 8.8.8.8 in its second slot), the bridge in two slots, and then the bridge with an empty second slot (for a camera that refuses
    /// one address twice). Each write is read back; the refusal says what the camera kept. A camera that refuses the first write takes no
    /// DNS servers through ONVIF: its words are the refusal.
    private func writeONVIFBridge(_ client: ONVIFClient, server: String, searchDomains: [String]) async throws -> CameraSetupOutcome {
        var after: CameraDNSReading?
        for servers in [[server], [server, server], [server, ""]] {
            if let after, after.fromDHCP || !after.servers.contains(where: { ONVIFClient.sameAddress($0, server) }) { break }
            do {
                try await client.setDNS(fromDHCP: false, servers: servers, searchDomains: searchDomains)
            } catch let error as CameraAdapterError where !error.isLoginRefusal {
                guard after != nil else { return .refused(error) }
                continue
            }
            guard let dns = try await onvifDNS(client) else { return .refused("the camera no longer shows its DNS servers") }
            let reading = Self.onvifReading(dns)
            if reading.pointsAt(server) {
                log.info("Set the camera's DNS servers through ONVIF")
                return CameraSetupOutcome(succeeded: true, detail: "via ONVIF")
            }
            after = reading
        }
        return .refused(after.map { Self.kept($0, server: server) } ?? "the camera kept its own DNS servers")
    }

    /// `SetDNS` with the backup's servers (or DHCP), read back. A camera with fixed slots that kept a server in a slot the write did not name
    /// (the bridge, after Watch put it in both) gets those slots emptied, so it asks exactly the servers it had. Empty slots (0.0.0.0, ::)
    /// are no servers on either side: a camera that shows an emptied slot as 0.0.0.0 has its old servers back all the same.
    private func restoreONVIFDNS(_ client: ONVIFClient, _ backup: CameraDNSBackup, searchDomains: [String]) async throws -> CameraSetupOutcome {
        var servers = backup.servers
        let wanted = Self.usedSlots(backup.servers)
        for attempt in 0..<2 {
            do {
                try await client.setDNS(fromDHCP: backup.fromDHCP, servers: servers, searchDomains: searchDomains)
            } catch let error as CameraAdapterError where !error.isLoginRefusal {
                return .refused(error)
            }
            guard let after = try await onvifDNS(client) else { return .refused(Self.notTakenBack) }
            let now = Self.onvifReading(after)
            let kept = Self.usedSlots(now.backup.servers)
            // Back on DHCP, the servers set by hand no longer count (some cameras keep the last ones).
            if now.fromDHCP == backup.fromDHCP && (backup.fromDHCP || Self.same(kept, wanted)) {
                log.info("Set the camera's DNS servers through ONVIF")
                return CameraSetupOutcome(succeeded: true, detail: "via ONVIF")
            }
            guard attempt == 0, !backup.fromDHCP, !now.fromDHCP, kept.count > wanted.count,
                  Self.same(Array(kept.prefix(wanted.count)), wanted) else { break }
            servers = wanted + Array(repeating: "", count: now.backup.servers.count - wanted.count)
        }
        return .refused(Self.notTakenBack)
    }

    /// The slots that name a server, in order (an empty one, 0.0.0.0 or ::, left out).
    static func usedSlots(_ slots: [String]) -> [String] {
        slots.filter { !CameraDNSReading.isEmptySlot($0) }
    }

    // MARK: ISAPI

    /// The interface's address document and its DNS servers; nil when the camera does not have it or it holds no DNS servers.
    private func isapiDNSDocument() async throws -> (document: String, servers: ISAPIDNSServers)? {
        guard let document = try await isapi().document(HikvisionISAPI.ipAddressPath),
              let servers = HikvisionISAPI.dnsServers(in: document) else { return nil }
        return (document, servers)
    }

    /// Writes `servers` into the document as the camera has it now and reads it back; a camera that shows no document afterwards is a
    /// refusal (nothing to check the write against), one that shows other servers is refused in `failure`'s words. ISAPI `statusCode` 7 is
    /// noted (the camera may show the old servers until it restarts, and Camera Bridge never restarts it): the step is done, waiting for the
    /// restart, and the security check reads the camera's DNS again before the guard counts the camera as watched (`GuardEvidence.asksBridge`).
    private func writeISAPIDNS(_ servers: [String], failure: (CameraDNSReading) -> String,
                               verify: (CameraDNSReading) -> Bool) async throws -> CameraSetupOutcome {
        guard let (document, _) = try await isapiDNSDocument() else { return .refused("the camera no longer shows its DNS servers") }
        guard let edited = HikvisionISAPI.settingDNS(servers, in: document) else { return .refused("the camera shows no DNS servers") }
        var restart = false
        if edited != document {
            do {
                restart = try await isapi().write(HikvisionISAPI.ipAddressPath, document: edited) == .rebootRequired
            } catch let refusal as ISAPIRefusal {
                return .refused(refusal.words)
            }
        }
        guard let (_, after) = try await isapiDNSDocument() else { return .refused("the camera no longer shows its DNS servers") }
        let reading = CameraDNSReading(servers: after.servers, fromDHCP: false, method: .hikvisionISAPI,
                                       backup: CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: after.slots))
        guard verify(reading) || restart else { return .refused(failure(reading)) }
        log.info("Set the camera's DNS servers through ISAPI")
        return CameraSetupOutcome(succeeded: true, needsRestart: restart, detail: "via ISAPI")
    }

    /// The same servers in the same order.
    static func same(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { ONVIFClient.sameAddress($0, $1) }
    }

    // MARK: Reolink

    static let reolinkDNSKeys = ["auto", "dns1", "dns2"]

    /// Why a Reolink's `LocalLink` is left as it is: written back, it could change the camera's address.
    static let reolinkLinkLeftAlone = "the camera’s network settings are not ones Camera Bridge can write back exactly (its address could "
        + "change), so Camera Bridge left them as they are: set both DNS servers on the camera"

    /// `GetLocalLink` through the run's session: the whole `LocalLink` (written back with only `dns` changed) and its `dns` (`auto` 1: from
    /// DHCP, `dns1`, `dns2`) as text; nil when the camera does not show them (an API error, or no `dns` with those three). `LocalLink` also
    /// holds the camera's address and MAC: nothing of it is logged or kept.
    func reolinkLink() async throws -> (link: [String: JSONValue], dns: [String: String])? {
        guard let link = try await reolinkValue("GetLocalLink")?["LocalLink"]?.object, let dns = link["dns"]?.object else { return nil }
        var values: [String: String] = [:]
        for key in Self.reolinkDNSKeys {
            guard let text = dns[key]?.string else { return nil }
            values[key] = text.trimmingCharacters(in: .whitespaces)
        }
        return (link, values)
    }

    /// `LocalLink.dns` as a reading. With `auto` 1 its `dns1` and `dns2` are not the servers in use: the camera asks those DHCP hands out, and
    /// may keep the ones set by hand in the slots (the v8 guide's own example has `auto` 1 with 114.114.114.114 in `dns2`), so `readDNS()`
    /// takes them from ONVIF (`reolinkDHCPServers`); the backup keeps the slots as they are.
    static func reolinkReading(_ dns: [String: String]) -> CameraDNSReading { ownReading(dns, dhcpKey: "auto", method: .reolinkAPI) }

    /// The servers a Reolink on DHCP (`LocalLink.dns.auto` 1) asks: ONVIF `GetDNS`'s `DNSFromDHCP` (a read, which Reolink's ONVIF user may
    /// make), each once (none when DHCP gives none), at the camera's ONVIF port (`reolinkONVIFClient`: no port is searched for). nil when
    /// its ONVIF does not say (switched off, no answer, not from DHCP there, a refused or paused login: a login refusal of this read is not
    /// thrown, as the camera's own API answered): the reading then does not know its servers (`CameraDNSReading.serversUnknown`).
    func reolinkDHCPServers() async throws -> [String]? {
        do {
            guard let client = try await reolinkONVIFClient() else { return nil }
            let dns = try await client.dns()
            guard dns.fromDHCP else { return nil }
            var servers: [String] = []
            for server in dns.dhcpServers where !CameraDNSReading.isEmptySlot(server) && !servers.contains(where: { ONVIFClient.sameAddress($0, server) }) {
                servers.append(server)
            }
            return servers
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// A Reolink's ONVIF device service, as its driver finds it for events (`ReolinkEvents`): at the saved ONVIF port (`client()`), else at
    /// the one `GetNetPort` reports (`onvifPort`), else at Reolink's default (`ReolinkDriver.defaultONVIFPort`); no port is searched for. nil
    /// when `GetNetPort` says ONVIF is switched off. `GetNetPort` refused (an error code, a per-user refusal) says nothing.
    private func reolinkONVIFClient() async throws -> ONVIFClient? {
        if endpoint.onvifPort != nil { return await client() }
        var netPort: JSONValue?
        do {
            netPort = try await reolinkValue("GetNetPort")
        } catch CameraAdapterError.unauthorized {
            netPort = nil   // refused to this account: the session's own reads just worked
        }
        var resolved = endpoint
        guard let port = Self.reolinkONVIFPort(saved: nil, netPort: ReolinkDriver.onvifNetPort(netPort)) else { return nil }
        resolved.onvifPort = port
        guard let url = ONVIFClient.deviceServiceURL(for: resolved) else { return nil }
        return ONVIFClient(deviceServiceURL: url, credentials: credentials, cameraID: cameraID)
    }

    /// A Reolink's ONVIF port: `saved` (the camera's `CameraEndpoint.onvifPort`), else `GetNetPort`'s `onvifPort`, else Reolink's default;
    /// nil when `GetNetPort` says ONVIF is switched off (and none is saved).
    static func reolinkONVIFPort(saved: Int?, netPort: ReolinkDriver.ONVIFNetPort) -> Int? {
        if let saved { return saved }
        guard netPort.enabled != false else { return nil }
        return netPort.port ?? ReolinkDriver.defaultONVIFPort
    }

    /// `LocalLink` with `dns` as read but `values` written into it (`auto` as a number, as the camera has it); everything else as read.
    static func reolinkLink(_ link: [String: JSONValue], dns values: [String: String]) -> [String: JSONValue] {
        var dns = link["dns"]?.object ?? [:]
        let auto = values["auto"] ?? "0"
        dns["auto"] = Double(auto).map(JSONValue.number) ?? .string(auto)
        dns["dns1"] = .string(values["dns1"] ?? "")
        dns["dns2"] = .string(values["dns2"] ?? "")
        var edited = link
        edited["dns"] = .object(dns)
        return edited
    }

    /// Whether `LocalLink` as read can go back with only its DNS changed without risking the camera's address: its `type` is "DHCP", or
    /// "Static" with `static.ip` the address Camera Bridge reaches the camera at (when that is an IPv4 address), and `dns` is an object.
    /// Anything else (another `type`, none, a fixed address that is another one) is refused rather than written.
    func reolinkLinkWritable(_ link: [String: JSONValue]) -> Bool {
        guard link["dns"]?.object != nil, let type = link["type"]?.string else { return false }
        switch type {
        case "DHCP":
            return true
        case "Static":
            guard let ip = link["static"]?["ip"]?.string else { return false }
            return !ONVIFClient.isIPv4(endpoint.host) || ip == endpoint.host
        default:
            return false
        }
    }

    /// Points a Reolink's DNS at the bridge through its own API (owner decision, 2026-10-18): `SetLocalLink` with `LocalLink` as read and only
    /// `dns` changed (`auto` 0, the bridge in both slots), refused rather than written when that could change the camera's address
    /// (`reolinkLinkWritable`) and not sent when `GetAbility` says this account may not change it; then read back while the camera restarts
    /// its network service (a Wi-Fi doorbell drops off the network for a few seconds: what fails meanwhile is no refusal). nil when the
    /// camera does not show its `LocalLink` (ONVIF then).
    private func setReolinkDNS(server: String, readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome? {
        guard let (link, dns) = try await ownAPIRead({ try await reolinkLink() }) else { return nil }
        let wanted = ["auto": "0", "dns1": server, "dns2": server]
        if Self.sameOwnDNS(dns, wanted) { return CameraSetupOutcome(succeeded: true, detail: "via Reolink API") }
        guard reolinkLinkWritable(link) else { return .refused(Self.reolinkLinkLeftAlone) }
        if try await reolinkMayNotChange("localLink") { return .notPermittedRefusal }
        if let refusal = try await reolinkWrite(Self.reolinkLink(link, dns: wanted)) { return refusal }
        var last: [String: String]?
        let done = try await readBackAfterRestart(readBack) {
            guard let (_, values) = try await self.reolinkLink() else { return false }
            last = values
            return Self.sameOwnDNS(values, wanted)
        }
        if done {
            log.info("Set the camera's DNS servers through its Reolink API")
            return CameraSetupOutcome(succeeded: true, detail: "via Reolink API")
        }
        return .refused(Self.keptAfterRestart(last.map(Self.reolinkReading), server: server))
    }

    /// Writes the backup's `LocalLink.dns` back as `setReolinkDNS` writes, read back while the camera restarts its network service; nil when
    /// the camera does not show its `LocalLink`. A backup with the camera's own values (`ownAPI`) goes back exactly; one without them (saved
    /// through ONVIF by a build before 2026-10-18: the owner's doorbell has `fromDHCP` true and no servers) is translated
    /// (`reolinkDNS(restoring:current:)`).
    private func restoreReolinkDNS(_ backup: CameraDNSBackup, readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome? {
        if let saved = backup.ownAPI, Set(saved.keys) != Set(Self.reolinkDNSKeys) { return nil }
        guard let (link, dns) = try await ownAPIRead({ try await reolinkLink() }) else { return nil }
        let (saved, matches) = Self.reolinkDNS(restoring: backup, current: dns)
        if !matches(dns) {
            guard reolinkLinkWritable(link) else { return .refused(Self.reolinkLinkLeftAlone) }
            if try await reolinkMayNotChange("localLink") { return .notPermittedRefusal }
            if let refusal = try await reolinkWrite(Self.reolinkLink(link, dns: saved)) { return refusal }
            let done = try await readBackAfterRestart(readBack) {
                guard let (_, values) = try await self.reolinkLink() else { return false }
                return matches(values)
            }
            guard done else { return .refused(Self.notTakenBack) }
        }
        log.info("Set the camera's DNS servers through its Reolink API")
        return CameraSetupOutcome(succeeded: true, detail: "via Reolink API")
    }

    /// What Restore writes into `LocalLink.dns` (`current` as read now) for `backup`, and how a reading shows it took: the camera's own
    /// values (`ownAPI`) exactly; else from DHCP (`fromDHCP`) `auto` 1 with the slots as they are, checked by `auto` alone (the camera
    /// asks DHCP's servers then, whatever its slots hold); else `auto` 0 with the backup's servers in the two slots, an empty slot no
    /// server on either side.
    static func reolinkDNS(restoring backup: CameraDNSBackup, current: [String: String])
        -> (values: [String: String], matches: @Sendable ([String: String]) -> Bool) {
        if let saved = backup.ownAPI { return (saved, { sameOwnDNS($0, saved) }) }
        if backup.fromDHCP {
            var values = current
            values["auto"] = "1"
            return (values, { $0["auto"] == "1" })
        }
        let slots = [backup.servers.first ?? "", backup.servers.dropFirst().first ?? ""]
        let wanted = usedSlots(slots)
        return (["auto": "0", "dns1": slots[0], "dns2": slots[1]],
                { $0["auto"] == "0" && same(usedSlots([$0["dns1"] ?? "", $0["dns2"] ?? ""]), wanted) })
    }

    /// `SetLocalLink`; the refusal when the camera answered one (an error code, or an account it does not let change it). No answer is not a
    /// refusal: the camera may restart its network service before it answers, and the read-back tells.
    private func reolinkWrite(_ link: [String: JSONValue]) async throws -> CameraSetupOutcome? {
        do {
            if let refusal = try await reolinkSet("SetLocalLink", .object(["LocalLink": .object(link)]), module: nil,
                                                  unsupported: "the camera does not let its DNS servers be changed") { return refusal }
        } catch let error as CameraAdapterError where error.isLoginRefusal {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.debug("The camera did not answer the DNS change through its Reolink API (it may be restarting its network)")
        }
        return nil
    }

    /// A read of the camera's own API before anything is written to it: nil when it does not answer (ONVIF's words then stand); a login
    /// refusal and a cancellation are thrown.
    func ownAPIRead<T: Sendable>(_ read: () async throws -> T?) async throws -> T? {
        do {
            return try await read()
        } catch let error as CameraAdapterError where error.isLoginRefusal {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// The refusal after a write that restarted the camera's network service and was not read back as written.
    static func keptAfterRestart(_ reading: CameraDNSReading?, server: String) -> String {
        reading.map { kept($0, server: server) } ?? "the camera did not answer again after restarting its network service"
    }
}

// MARK: - The setup step

extension CameraSettingsService {
    /// The step's note when the camera asks the bridge alone with DNS servers its router's DHCP hands out.
    static let dnsFromRouterNote = "Its DNS servers come from the router (DHCP): the router can change them when it renews the camera’s address."

    /// "Watch its internet" for the preview: the camera's DNS servers now against `server` (the bridge's address on the camera's network).
    /// Already right when the camera asks that address and no other, wherever it has them from (from the router's DHCP, the note says the
    /// router can change them); the backup is the camera's value now, with its own API's DNS values when it has an API Camera Bridge writes
    /// them through (the IPCamera Web family's page, Reolink's `LocalLink`; the IP camera web API's `LANConfig`, which the reading itself
    /// comes from). Not supported, saying why, when the IP camera web API cannot be asked now or the camera is on DHCP there (its page sets
    /// DNS servers only in Mode Static).
    public func readInternetWatch(server: String) async throws -> (CameraSetupReading, CameraDNSBackup?) {
        let read: CameraDNSReading?
        do {
            read = try await readDNS()
        } catch let unavailable as IPCWebUnavailable {
            return (.notSupported(unavailable.reason), nil)
        }
        guard let dns = read else { return (.notSupported("the camera does not show its DNS servers"), nil) }
        var backup = dns.backup
        if backup.ownAPI == nil, dns.method != .ipcWebAPI { backup.ownAPI = try await ownAPIDNS() }
        if dns.pointsAt(server) { return (CameraSetupReading(state: .alreadyRight, note: dns.fromDHCP ? Self.dnsFromRouterNote : nil), backup) }
        if vendor == .reolink, dns.method == .reolinkAPI, try await reolinkMayNotChange("localLink") {
            return (.notSupported(CameraAdapterError.notPermittedReason), backup)
        }
        if let refusal = Self.ipcWebWatchRefusal(dns) { return (.notSupported(refusal), backup) }
        let servers = CameraSetupText.list(dns.servers)
        let now = dns.fromDHCP ? (dns.servers.isEmpty ? "from the router (DHCP)" : "\(servers) from the router (DHCP)")
            : dns.servers.isEmpty ? "none set" : servers
        return (CameraSetupReading(state: .willChange, changes: [.init(label: "DNS", now: now, after: "the bridge (\(server))")]), backup)
    }

    /// The DNS values of the camera's own API, for the backup: the IPCamera Web family's page, Reolink's `LocalLink`; nil for other
    /// cameras, and when they cannot be read now (Restore then goes through ONVIF alone). Throws a cancellation only.
    private func ownAPIDNS() async throws -> [String: String]? {
        do {
            switch vendor {
            case .onvif:
                guard case .speaks(let web) = try await ipcamWeb() else { return nil }
                return try await ipcamWebDNS(web)?.dns
            case .reolink:
                return try await reolinkLink()?.dns
            default:
                return nil
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }
}
