import BridgeSupport
import Foundation

/// A camera's IPv4 address as it has it now, whole: what "Fix its address so the DNS stays" keeps exactly (its address, mask and gateway),
/// with the camera's hardware address for the router reservation when it shows one.
public struct CameraAddressing: Sendable, Codable, Equatable {
    public var address: String
    /// Dotted ("255.255.255.0"), contiguous bits (`prefixLength`).
    public var subnetMask: String
    public var gateway: String
    /// The camera's hardware (MAC) address, for "Reserve … for this camera in your router"; nil when it does not show one. Never logged,
    /// and never saved in a backup.
    public var hardwareAddress: String?
    /// ONVIF: the token of the network interface that has the address (`SetNetworkInterfaces` names it); nil through a camera's own API.
    public var interface: String?

    public init(address: String, subnetMask: String, gateway: String, hardwareAddress: String? = nil, interface: String? = nil) {
        self.address = address
        self.subnetMask = subnetMask
        self.gateway = gateway
        self.hardwareAddress = hardwareAddress
        self.interface = interface
    }

    /// The mask's prefix length (24 for 255.255.255.0); nil for one that is not contiguous bits.
    public var prefixLength: Int? { Self.prefixLength(ofMask: subnetMask) }

    /// The same address, mask and gateway: what the choice compares before it writes (the hardware address and the interface are not part
    /// of the address).
    public func sameAddress(as other: CameraAddressing) -> Bool {
        address == other.address && prefixLength != nil && prefixLength == other.prefixLength && gateway == other.gateway
    }

    /// Whether `other` (an IPv4 address) is on the camera's network: the same first `prefixLength` bits as its address.
    public func contains(_ other: String) -> Bool {
        guard let prefix = prefixLength, let mine = Self.value(address), let theirs = Self.value(other) else { return false }
        let mask = UInt32.max << UInt32(32 - prefix)
        return mine & mask == theirs & mask
    }

    /// The address whole, or nil: `address` an IPv4 address and `gateway` one too, neither 0.0.0.0, `mask` contiguous bits, and the gateway
    /// on the network they make (not, say, a /32 from a stale document, or a gateway on another network: research §5). A value is never
    /// guessed: a camera that does not show one is not offered the choice.
    static func whole(address: String?, mask: String?, gateway: String?, hardwareAddress: String? = nil, interface: String? = nil) -> CameraAddressing? {
        guard let address, let mask, let gateway, ONVIFClient.isIPv4(address), ONVIFClient.isIPv4(gateway), address != "0.0.0.0", gateway != "0.0.0.0",
              let prefix = prefixLength(ofMask: mask), let canonical = self.mask(prefixLength: prefix) else { return nil }
        let addressing = CameraAddressing(address: address, subnetMask: canonical, gateway: gateway, hardwareAddress: hardwareAddress, interface: interface)
        return addressing.contains(gateway) ? addressing : nil
    }

    /// An IPv4 address as 32 bits; nil for anything else.
    private static func value(_ address: String) -> UInt32? {
        guard ONVIFClient.isIPv4(address) else { return nil }
        return address.split(separator: ".").compactMap { UInt32($0) }.reduce(UInt32(0)) { $0 << 8 | $1 }
    }

    /// The prefix length of a dotted mask of contiguous bits (1 to 32); nil otherwise.
    static func prefixLength(ofMask mask: String) -> Int? {
        guard let value = value(mask) else { return nil }
        let inverted = ~value
        guard value != 0, inverted & (inverted &+ 1) == 0 else { return nil }
        return value.nonzeroBitCount
    }

    /// The dotted mask of a prefix length of 1 to 32; nil otherwise.
    static func mask(prefixLength: Int) -> String? {
        guard (1...32).contains(prefixLength) else { return nil }
        let value = UInt32.max << UInt32(32 - prefixLength)
        return [24, 16, 8, 0].map { String(value >> UInt32($0) & 0xFF) }.joined(separator: ".")
    }

    /// A hardware address as the camera shows it (six pairs of hex digits split by ":" or "-"), trimmed; nil for anything else.
    static func hardwareAddress(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let pairs = text.split(omittingEmptySubsequences: false) { $0 == ":" || $0 == "-" }
        guard pairs.count == 6, pairs.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return text
    }
}

/// "Fix its address so the DNS stays (keeps <address>)" for "Watch its internet": offered, off unless the person chooses it, where the
/// camera's DNS only stays with a fixed address. Chosen, the step fixes the camera's address exactly as it is (`addressing`) and points its
/// DNS at the bridge (`changes`: the address, then the DNS, now → after); "Restore original settings" puts DHCP back.
public struct CameraSetupFixAddress: Sendable, Codable, Equatable {
    public var addressing: CameraAddressing
    public var changes: [CameraSetupChange]
    /// The way the address is fixed, and put back on DHCP: `.hikvisionISAPI`, `.ipcWebAPI` or `.onvifMinimal` (the reading's). A backup
    /// keeps it with the address (`CameraDNSBackup.fixedAddressMethod`): its own DNS servers may have been read another way.
    public var method: CameraConfigMethod

    public init(addressing: CameraAddressing, changes: [CameraSetupChange], method: CameraConfigMethod) {
        self.addressing = addressing
        self.changes = changes
        self.method = method
    }
}

/// "Fix its address so the DNS stays" (docs/superpowers/specs/2026-10-18-camera-dns-design.md): for a camera whose DNS only stays while its
/// address is fixed (research §2.1, §2.11, §5), the address it has now, kept exactly (address, mask, gateway), with DHCP off, then the DNS
/// pointed at the bridge. Only the person turns it on, in the setup's preview; Camera Bridge never changes a camera's address otherwise, and
/// never restarts a camera that needs a restart to apply it. Hikvision through ISAPI's address document (`addressingType` static, the same
/// `ipAddress`, `subnetMask` and `DefaultGateway`, both DNS servers the bridge), the IP camera web API through `LANConfig` (`DHCP` 0, the
/// same `IPAddress`, `Netmask` and `Gateway`, `DNS1` and `DNS2` the bridge: `IPCWebDNS.swift`), other ONVIF cameras through
/// `SetNetworkInterfaces` (DHCP off, `Manual` the address and prefix they have), `SetNetworkDefaultGateway` as it was, then `SetDNS`.
/// Restore puts DHCP back (and the DNS servers as they were) while the camera still has the fixed address. Every call goes through the
/// camera's usual login and its guards. Nothing of the address is logged.
extension CameraSettingsService {
    /// Whether a reading's DNS only stays with a fixed address: a Hikvision on DHCP (`hikvisionDHCPRefusal`), a camera that speaks the IP
    /// camera web API on DHCP (`ipcWebDHCPRefusal`), and an ONVIF camera on DHCP whose DNS set by hand was refused (`refusedBefore`: its last
    /// run said so; a Reolink keeps its DNS on DHCP, through its own API).
    static func needsFixedAddress(_ reading: CameraDNSReading, vendor: CameraVendor?, refusedBefore: Bool) -> Bool {
        guard reading.fromDHCP else { return false }
        switch reading.method {
        case .hikvisionISAPI, .ipcWebAPI: return true
        case .onvifMinimal: return refusedBefore && vendor != .reolink
        default: return false
        }
    }

    /// The change row of the choice: the address from DHCP, then the same one, fixed.
    static func fixedAddressChange(_ addressing: CameraAddressing) -> CameraSetupChange {
        CameraSetupChange(label: "Address", now: "\(addressing.address) from the router (DHCP)",
                          after: "\(addressing.address), fixed (mask \(addressing.subnetMask), gateway \(addressing.gateway))")
    }

    /// Why the choice wrote nothing: the camera's address read again just before the write is not the one the person saw.
    public static func addressChangedRefusal(_ shown: CameraAddressing) -> String {
        "the camera’s address is no longer the one the preview showed (\(shown.address), mask \(shown.subnetMask), gateway \(shown.gateway) from the "
            + "router), so Camera Bridge changed nothing: open “Set up for Camera Bridge” again to see it as it is now"
    }

    /// Why Restore left a camera's address alone: it is not the fixed one Watch set (changed by hand since).
    static func addressChangedSinceFixed(_ fixed: CameraAddressing) -> String {
        "the camera’s address was changed since Camera Bridge fixed it at \(fixed.address), so Camera Bridge left its network settings as they are"
    }

    /// Why the choice wrote nothing: Camera Bridge's address is not on the camera's network as the camera has it.
    static func bridgeOffTheNetwork(_ addressing: CameraAddressing, server: String) -> String {
        "Camera Bridge (\(server)) is not on the camera’s network as the camera has it (\(addressing.address), mask \(addressing.subnetMask)), "
            + "so Camera Bridge changed nothing"
    }

    /// What a refused Watch on an ONVIF camera on DHCP adds: the next preview offers the choice (`needsFixedAddress`, `refusedBefore`).
    static let fixedAddressNextTime = "Open “Set up for Camera Bridge” again to fix its address so the DNS stays"

    static let addressNotFixed = "the camera did not take the fixed address: it still takes its address from DHCP"
    /// A Restore whose DHCP applies once the camera restarts (`RebootNeeded`).
    static let dhcpAtRestart = "The camera takes its address from DHCP again once it restarts"
    static let addressNotBackOnDHCP = "the camera kept its fixed address instead of taking it from DHCP again"
    static let addressUnreadable = "the camera no longer shows its address"

    /// The camera's address now, for the choice, read the way its DNS reading came (`method`): ISAPI's address document (and the hardware
    /// address from its network interface's), the IP camera web API's `LANConfig`, ONVIF's `GetNetworkInterfaces` and
    /// `GetNetworkDefaultGateway`. nil when the camera does not take it from DHCP, does not show it whole, or shows another address than
    /// `cameraAddress`.
    func addressToFix(_ method: CameraConfigMethod, cameraAddress: String) async throws -> CameraAddressing? {
        switch method {
        case .hikvisionISAPI:
            guard let document = try await isapi().document(HikvisionISAPI.ipAddressPath), let now = HikvisionISAPI.address(in: document), now.fromDHCP,
                  var addressing = now.addressing, addressing.address == cameraAddress else { return nil }
            // The hardware address is only for the reminder: a camera that does not show it is offered the choice without it.
            do {
                addressing.hardwareAddress = try await isapi().document(HikvisionISAPI.interfacePath).flatMap(HikvisionISAPI.hardwareAddress(in:))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                addressing.hardwareAddress = nil
            }
            return addressing
        case .ipcWebAPI:
            return try await ipcWebAddressToFix(cameraAddress: cameraAddress)
        case .onvifMinimal:
            guard let client = await client(), let interfaces = try await onvifAnswer({ try await client.networkInterfaces() }),
                  let gateway = try await onvifAnswer({ try await client.defaultGateway() }) else { return nil }
            return interfaces.filter(\.ipv4DHCP).compactMap { Self.onvifAddressing($0, gateway: gateway) }.first { $0.address == cameraAddress }
        default:
            return nil
        }
    }

    /// "Watch its internet" with "Fix its address so the DNS stays", which the person chose: the camera's address fixed exactly as
    /// `expected` (the address the preview showed), then its DNS pointed at the bridge, each read back. The address is read again first,
    /// through the way that writes it: one that is not `expected` now (a DHCP renewal gave the camera another, or it was fixed meanwhile) is
    /// refused in plain words (`addressChangedRefusal`) and nothing is written. A camera that applies the address after it restarts (ISAPI
    /// "Reboot Required", ONVIF `RebootNeeded`) is done waiting for its restart (`needsRestart`), which only the person starts.
    /// `addressFixed` says the camera took the fixed address. An IPv4 bridge address only.
    public func applyDNS(server: String, fixingAddress expected: CameraAddressing) async throws -> CameraSetupOutcome {
        try await applyDNS(server: server, fixingAddress: expected, readBack: dnsReadBack)
    }

    func applyDNS(server: String, fixingAddress expected: CameraAddressing, readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome {
        guard ONVIFClient.isIPv4(server) else { return .refused(Self.dnsIPv4Only).untouched }
        guard expected.contains(server) else { return .refused(Self.bridgeOffTheNetwork(expected, server: server)).untouched }
        if vendor == .hikvision, let (document, _) = try await isapiDNSDocument() { return try await fixISAPIAddress(document, server: server, expected: expected) }
        if vendor == .onvif, let outcome = try await fixIPCWebAddress(server: server, expected: expected, readBack: readBack) { return outcome }
        return try await fixONVIFAddress(server: server, expected: expected, readBack: readBack)
    }

    // MARK: ISAPI

    /// One write of the address document as the camera has it, with `addressingType` static and both DNS servers the bridge: its address,
    /// mask and gateway as they are (they are `expected`, or nothing is written).
    private func fixISAPIAddress(_ document: String, server: String, expected: CameraAddressing) async throws -> CameraSetupOutcome {
        guard let now = HikvisionISAPI.address(in: document), now.fromDHCP, now.addressing?.sameAddress(as: expected) == true else {
            return .refused(Self.addressChangedRefusal(expected)).untouched
        }
        guard let edited = HikvisionISAPI.settingAddressing("static", dns: [server, server], in: document) else {
            return .refused("the camera shows no DNS servers").untouched
        }
        let restart: Bool
        do {
            restart = try await isapi().write(HikvisionISAPI.ipAddressPath, document: edited) == .rebootRequired
        } catch let refusal as ISAPIRefusal {
            return .refused(refusal.words).untouched
        } catch CameraAdapterError.notPermitted {
            return CameraSetupOutcome.notPermittedRefusal.untouched
        }
        if restart {
            log.info("The camera takes its fixed address and DNS servers through ISAPI once it restarts")
            return CameraSetupOutcome(succeeded: true, needsRestart: true, detail: "via ISAPI", addressFixed: true)
        }
        guard let after = try await isapi().document(HikvisionISAPI.ipAddressPath), let address = HikvisionISAPI.address(in: after),
              let servers = HikvisionISAPI.dnsServers(in: after) else { return .refused(Self.addressUnreadable) }
        guard address.isFixed, address.addressing?.sameAddress(as: expected) == true else { return .refused(Self.addressNotFixed) }
        let reading = Self.isapiReading(servers)
        guard reading.pointsAt(server) else { return CameraSetupOutcome(succeeded: false, detail: Self.kept(reading, server: server), addressFixed: true) }
        log.info("Fixed the camera's address as it was and set its DNS servers through ISAPI")
        return CameraSetupOutcome(succeeded: true, detail: "via ISAPI", addressFixed: true)
    }

    /// Restore of a Hikvision whose address the choice fixed: while it still has that fixed address, one write with `addressingType` dynamic
    /// and `dns` as its DNS servers (nil: the slots as they are; on DHCP its servers come with the address), read back: on DHCP again. nil
    /// when it is on DHCP already; one whose address was changed by hand since is left as it is, said so.
    private func restoreISAPIFixedAddress(dns: [String]?, fixed: CameraAddressing) async throws -> CameraSetupOutcome? {
        guard let document = try await isapi().document(HikvisionISAPI.ipAddressPath), let now = HikvisionISAPI.address(in: document) else {
            return .refused(Self.addressUnreadable)
        }
        if now.fromDHCP { return nil }
        guard now.isFixed, now.addressing?.sameAddress(as: fixed) == true else { return .refused(Self.addressChangedSinceFixed(fixed)) }
        guard let edited = HikvisionISAPI.settingAddressing("dynamic", dns: dns, in: document) else { return .refused("the camera shows no DNS servers") }
        let restart: Bool
        do {
            restart = try await isapi().write(HikvisionISAPI.ipAddressPath, document: edited) == .rebootRequired
        } catch let refusal as ISAPIRefusal {
            return .refused(refusal.words)
        } catch CameraAdapterError.notPermitted {
            return .notPermittedRefusal
        }
        if !restart {
            guard let after = try await isapi().document(HikvisionISAPI.ipAddressPath), HikvisionISAPI.address(in: after)?.fromDHCP == true else {
                return .refused(Self.addressNotBackOnDHCP)
            }
        }
        log.info("Put the camera back on DHCP with its own DNS servers through ISAPI")
        return CameraSetupOutcome(succeeded: true, needsRestart: restart, detail: "via ISAPI")
    }

    // MARK: ONVIF

    /// Whether the camera has IPv6 on, as ONVIF's `GetNetworkInterfaces` shows it: true when an interface that is on has its IPv6 enabled (it
    /// may then take DNS servers from the router's advertisements or DHCPv6 beside the IPv4 ones: research §5), false when none has (or none
    /// shows an IPv6 section); nil when the camera has no ONVIF device service or does not answer it. One read, through the camera's usual
    /// login and its guards; nothing is written. For BridgeEngine's DNS help (its warning), asked by the security check, not by the guard's
    /// own reads. Throws the camera's login refusal and a cancellation.
    public func readIPv6() async throws -> Bool? {
        guard let client = await client(), let interfaces = try await onvifAnswer({ try await client.networkInterfaces() }) else { return nil }
        return interfaces.contains { $0.enabled && $0.ipv6Enabled == true }
    }

    /// A device-service read; nil when the camera answers it with a fault or an HTTP error that is not a login refusal.
    private func onvifAnswer<T: Sendable>(_ read: () async throws -> T) async throws -> T? {
        do { return try await read() } catch let error as CameraAdapterError where !error.isLoginRefusal { return nil }
    }

    /// The address an interface uses, whole, with the first IPv4 gateway: its lease (`FromDHCP`) while DHCP is on, never an address set by
    /// hand it may not be using, else its first address set by hand. nil when it is off, has no token, or does not show it whole.
    static func onvifAddressing(_ interface: ONVIFNetworkInterface, gateway: ONVIFDefaultGateway) -> CameraAddressing? {
        guard interface.enabled, interface.ipv4Enabled, !interface.token.isEmpty,
              let current = interface.ipv4DHCP ? interface.ipv4FromDHCP : interface.ipv4Manual.first, let prefix = current.prefixLength else { return nil }
        return CameraAddressing.whole(address: current.address, mask: CameraAddressing.mask(prefixLength: prefix), gateway: gateway.ipv4.first,
                                      hardwareAddress: CameraAddressing.hardwareAddress(interface.hardwareAddress), interface: interface.token)
    }

    /// A definite refusal of a write, after which nothing it asked was changed: a SOAP fault, the account's rights, an HTTP status that is
    /// not 2xx, or a request Camera Bridge did not send. Not an answer it could not read (a 2xx the camera may have acted on).
    static func refusedOutright(_ error: CameraAdapterError) -> Bool {
        switch error {
        case .soapFault, .notPermitted, .unsupported: true
        case .httpStatus(let status): !(200...299).contains(status)
        default: false
        }
    }

    /// The interface `token` and the default gateways as the camera shows them now; nil when it does not show them.
    private func onvifNetwork(_ client: ONVIFClient, token: String) async throws -> (interface: ONVIFNetworkInterface, gateway: ONVIFDefaultGateway)? {
        guard let interfaces = try await onvifAnswer({ try await client.networkInterfaces() }), let interface = interfaces.first(where: { $0.token == token }),
              let gateway = try await onvifAnswer({ try await client.defaultGateway() }) else { return nil }
        return (interface, gateway)
    }

    /// `SetNetworkInterfaces` (DHCP off, `Manual` the address and prefix the interface has), read back while the camera restarts its network
    /// service; `SetNetworkDefaultGateway` with the gateways as they were (a camera switched off DHCP may drop the one DHCP gave), read back;
    /// then `SetDNS` (`writeONVIFBridge`). A camera that answers `RebootNeeded` applies the address once it restarts: the gateway and the DNS
    /// are sent, the first DNS form it takes is done waiting for the restart, and nothing is read back until then.
    private func fixONVIFAddress(server: String, expected: CameraAddressing, readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome {
        guard let token = expected.interface, let prefix = expected.prefixLength else { return .refused(Self.addressChangedRefusal(expected)).untouched }
        guard let client = await client() else { return .refused("the camera has no ONVIF device service").untouched }
        guard let (interface, gateway) = try await onvifNetwork(client, token: token) else { return .refused(Self.addressUnreadable).untouched }
        guard interface.ipv4DHCP, Self.onvifAddressing(interface, gateway: gateway)?.sameAddress(as: expected) == true else {
            return .refused(Self.addressChangedRefusal(expected)).untouched
        }
        guard let dns = try await onvifDNS(client) else { return .refused("the camera does not show its DNS servers").untouched }
        // The gateway goes back as read: checked before anything is written, so it can't stop the change half-way.
        guard ONVIFClient.setDefaultGatewayBody(gateway) != nil else { return .refused("the camera shows a gateway that is not an address").untouched }
        let manual = ONVIFPrefixedAddress(address: expected.address, prefixLength: prefix)
        let restart: Bool
        do {
            restart = try await client.setNetworkInterface(token: token, manual: manual, dhcp: false)
        } catch let error as CameraAdapterError where Self.refusedOutright(error) {
            return .refused(error).untouched   // the camera refused the first write: nothing about its address changed
        } catch let error as CameraAdapterError where !error.isLoginRefusal {
            return .refused(error)   // an answer that can't be read may be one the camera applied: the address stays to put back
        }
        if !restart {
            let fixed = try await readBackAfterRestart(readBack, immediately: true) {
                guard let (now, _) = try await self.onvifNetwork(client, token: token) else { return false }
                return !now.ipv4DHCP && now.ipv4Manual.first == manual
            }
            guard fixed else { return .refused(Self.addressNotFixed) }
        }
        do {
            try await client.setDefaultGateway(gateway)
        } catch let error as CameraAdapterError where !error.isLoginRefusal {
            var outcome = CameraSetupOutcome.refused(error)
            outcome.addressFixed = true
            return outcome
        }
        if !restart, try await onvifAnswer({ try await client.defaultGateway() })?.ipv4.first != expected.gateway {
            return CameraSetupOutcome(succeeded: false, detail: "the camera did not keep its gateway (\(expected.gateway))", addressFixed: true)
        }
        var outcome = restart ? try await writeONVIFBridgeBeforeRestart(client, server: server, searchDomains: dns.searchDomains)
            : try await writeONVIFBridge(client, server: server, searchDomains: dns.searchDomains, readBack: readBack)
        outcome.addressFixed = true
        if outcome.succeeded { log.info("Fixed the camera's address as it was through ONVIF") }
        return outcome
    }

    /// `SetDNS` in `writeONVIFBridge`'s forms for a camera that applies its new address only once it restarts: the first form it takes is
    /// done, waiting for the restart (a read-back decides nothing before it; the security check reads its DNS again). A form it answers with
    /// a fault is followed by the next; one the account may not make ends it.
    private func writeONVIFBridgeBeforeRestart(_ client: ONVIFClient, server: String, searchDomains: [String]) async throws -> CameraSetupOutcome {
        var refusal: (any Error)?
        for servers in [[server, server], [server], [server, ""]] {
            do {
                try await client.setDNS(fromDHCP: false, servers: servers, searchDomains: searchDomains)
                log.info("Set the camera's DNS servers through ONVIF, applied once it restarts")
                return CameraSetupOutcome(succeeded: true, needsRestart: true, detail: "via ONVIF")
            } catch let error as CameraAdapterError where !error.isLoginRefusal {
                refusal = error
                if CameraAdapterError.isNotPermitted(error) { break }
            }
        }
        guard let refusal else { return .refused("the camera kept its own DNS servers") }
        return .refused(refusal)
    }

    /// The interface `token` as the camera shows it now; nil when it does not show it.
    private func onvifInterface(_ client: ONVIFClient, token: String) async throws -> ONVIFNetworkInterface? {
        try await onvifAnswer({ try await client.networkInterfaces() })?.first { $0.token == token }
    }

    /// Restore of an ONVIF camera whose address the choice fixed. Only what `SetNetworkInterfaces` wrote is compared (the address and its
    /// prefix): a gateway the camera dropped is Camera Bridge's own change, which DHCP gives back; an address changed by hand since is left as
    /// it is, said so, and nothing is written. Then the DNS servers as they were (`restoreDNS` without the address), then DHCP on again,
    /// also when the DNS part was refused (the DNS comes back with DHCP: then that part counts as done) and also when the interface already
    /// shows DHCP (a fixed address waiting for a restart, `RebootNeeded`, is undone so). DHCP comes last, as it can give the camera another
    /// address; it is read back unless the camera needs a restart for it (`needsRestart`).
    private func restoreONVIFFixedAddress(_ plain: CameraDNSBackup, fixed: CameraAddressing, readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome {
        guard let token = fixed.interface, let prefix = fixed.prefixLength else { return try await restoreDNS(plain, readBack: readBack) }
        guard let client = await client() else { return .refused("the camera has no ONVIF device service") }
        guard let interface = try await onvifInterface(client, token: token) else { return .refused(Self.addressUnreadable) }
        if !interface.ipv4DHCP, interface.ipv4Manual.first != ONVIFPrefixedAddress(address: fixed.address, prefixLength: prefix) {
            return .refused(Self.addressChangedSinceFixed(fixed))
        }
        let dns = try await restoreDNS(plain, readBack: readBack)
        let restart: Bool
        do {
            restart = try await client.setNetworkInterface(token: token, manual: nil, dhcp: true)
        } catch let error as CameraAdapterError where !error.isLoginRefusal {
            // Already on DHCP (a fix the camera refused at its first write; one it does not let undo while it waits for a restart): the DNS
            // servers alone decide, or the backup would stay for ever.
            if interface.ipv4DHCP { return dns }
            return .refused(error)
        }
        if !restart {
            let back = try await readBackAfterRestart(readBack, immediately: true) {
                try await self.onvifInterface(client, token: token)?.ipv4DHCP == true
            }
            guard back else { return .refused(Self.addressNotBackOnDHCP) }
        }
        // A DNS part that was refused counts as done once the camera takes its DNS servers from DHCP again.
        if !dns.succeeded {
            if restart {
                var pending = dns
                pending.needsRestart = true
                pending.detail = "\(dns.detail). \(Self.dhcpAtRestart)"
                return pending
            }
            if try await onvifDNS(client)?.fromDHCP != true { return dns }
        }
        log.info("Put the camera back on DHCP through ONVIF")
        return CameraSetupOutcome(succeeded: true, needsRestart: restart || dns.needsRestart, detail: "via ONVIF")
    }

    // MARK: Restore

    /// Restore after "Fix its address so the DNS stays": DHCP back the way the address was fixed (`fixedAddressMethod`; a backup without it:
    /// its own method), whatever way the DNS servers were read, and the DNS servers as they were. ISAPI and the IP camera web API put both
    /// back in one write when the DNS servers were read their way; otherwise the camera's DNS servers come back with DHCP, or, when they were
    /// set by hand, go back their own way afterwards. A camera already on DHCP gets its DNS servers back alone.
    func restoreFixedAddress(_ backup: CameraDNSBackup, fixed: CameraAddressing, readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome {
        var plain = backup
        plain.fixedAddress = nil
        plain.fixedAddressMethod = nil
        let method = backup.fixedAddressMethod ?? backup.method
        let address: CameraSetupOutcome?
        switch method {
        case .hikvisionISAPI:
            address = try await restoreISAPIFixedAddress(dns: plain.method == .hikvisionISAPI ? plain.servers : nil, fixed: fixed)
        case .ipcWebAPI:
            address = try await restoreIPCWebFixedAddress(plain, fixed: fixed, readBack: readBack)
        case .onvifMinimal:
            return try await restoreONVIFFixedAddress(plain, fixed: fixed, readBack: readBack)
        default:
            address = nil
        }
        // Read another way (a backup an earlier run saved): DHCP's servers come back with the address; servers set by hand go back their way.
        let comeWithDHCP = plain.method != method && plain.fromDHCP
        guard let address else {   // on DHCP already: the DNS servers alone
            if comeWithDHCP { return CameraSetupOutcome(succeeded: true, detail: method == .ipcWebAPI ? Self.ipcWebDone : "via ISAPI") }
            return try await restoreDNS(plain, readBack: readBack)
        }
        guard address.succeeded, plain.method != method, !plain.fromDHCP else { return address }
        var dns = try await restoreDNS(plain, readBack: readBack)
        dns.needsRestart = dns.needsRestart || address.needsRestart
        return dns
    }
}
