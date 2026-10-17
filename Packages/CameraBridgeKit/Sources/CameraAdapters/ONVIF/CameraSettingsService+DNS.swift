import BridgeSupport
import Foundation

/// The camera's DNS servers before the internet guard pointed them at the bridge (Watch), as `restoreDNS(_:)` puts them back.
public struct CameraDNSBackup: Sendable, Codable, Equatable {
    /// `.hikvisionISAPI` or `.onvifMinimal`.
    public var method: CameraConfigMethod
    /// ONVIF: the camera took its DNS servers from DHCP. Always false through ISAPI.
    public var fromDHCP: Bool
    /// ONVIF: the servers set by hand (`DNSManual`), in order (a camera on DHCP may have none). ISAPI: the `PrimaryDNS` and `SecondaryDNS`
    /// addresses as the camera had them, "0.0.0.0" included.
    public var servers: [String]
    /// ONVIF: the search domains, written back with the servers (nil: none known).
    public var searchDomains: [String]?

    public init(method: CameraConfigMethod, fromDHCP: Bool, servers: [String], searchDomains: [String]? = nil) {
        self.method = method
        self.fromDHCP = fromDHCP
        self.servers = servers
        self.searchDomains = searchDomains
    }
}

/// What `CameraSettingsService.readDNS()` found: the DNS servers the camera asks, where it takes them from, the way they were read (and
/// are written), and the backup to restore them from.
public struct CameraDNSReading: Sendable, Equatable {
    /// The servers in use, each once: DHCP's when the camera takes them from DHCP.
    public var servers: [String]
    public var fromDHCP: Bool
    /// `.hikvisionISAPI` or `.onvifMinimal`.
    public var method: CameraConfigMethod
    public var backup: CameraDNSBackup

    public init(servers: [String], fromDHCP: Bool, method: CameraConfigMethod, backup: CameraDNSBackup) {
        self.servers = servers
        self.fromDHCP = fromDHCP
        self.method = method
        self.backup = backup
    }

    /// The camera asks `server` and no other (an IPv6 address matches however it is written).
    public func pointsAt(_ server: String) -> Bool {
        !fromDHCP && !servers.isEmpty && servers.allSatisfy { ONVIFClient.sameAddress($0, server) }
    }
}

/// The internet guard's Watch, the camera's side (docs/superpowers/specs/2026-10-17-internet-guard-design.md): the camera's DNS servers
/// pointed at the bridge, so the bridge sees every name it looks up and answers none. Hikvision through ISAPI
/// (`/ISAPI/System/Network/interfaces/1/ipAddress`, `HikvisionISAPI+DNS.swift`), other cameras through ONVIF (`SetDNS`). Each write is
/// read back; DNS changes nothing about how the home network reaches the camera.
extension CameraSettingsService {
    /// The camera's DNS servers; nil when it does not show them (no ISAPI document, no ONVIF device service, or no `GetDNS`). Throws the
    /// camera's login refusal.
    public func readDNS() async throws -> CameraDNSReading? {
        if vendor == .hikvision, let (_, servers) = try await isapiDNSDocument() {
            let backup = CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: servers.slots)
            return CameraDNSReading(servers: servers.servers, fromDHCP: false, method: .hikvisionISAPI, backup: backup)
        }
        guard let client = await client(), let dns = try await onvifDNS(client) else { return nil }
        return Self.onvifReading(dns)
    }

    /// Points the camera's DNS at `server` (the bridge's address) and no other, then reads it back. Through ISAPI an IPv4 address only.
    public func applyDNS(server: String) async throws -> CameraSetupOutcome {
        guard ONVIFClient.isIPv4(server) || ONVIFClient.isIPv6(server) else { return .refused("the DNS server must be an address") }
        if vendor == .hikvision, try await isapiDNSDocument() != nil {
            guard ONVIFClient.isIPv4(server) else { return .refused("this camera takes an IPv4 address for its DNS server") }
            return try await writeISAPIDNS([server, server], failure: "the camera kept its own DNS servers") { $0.pointsAt(server) }
        }
        guard let client = await client(), let current = try await onvifDNS(client) else { return .refused("the camera does not show its DNS servers") }
        return try await writeONVIFDNS(client, fromDHCP: false, servers: [server], searchDomains: current.searchDomains,
                                       failure: "the camera kept its own DNS servers") { $0.pointsAt(server) }
    }

    /// Puts the camera's DNS servers back as the backup has them, then reads them back.
    public func restoreDNS(_ backup: CameraDNSBackup) async throws -> CameraSetupOutcome {
        let failure = "the camera did not take its old DNS servers back"
        switch backup.method {
        case .hikvisionISAPI:
            return try await writeISAPIDNS(backup.servers, failure: failure) { Self.same($0.backup.servers, backup.servers) }
        default:
            guard let client = await client(), let current = try await onvifDNS(client) else { return .refused("the camera no longer shows its DNS servers") }
            return try await writeONVIFDNS(client, fromDHCP: backup.fromDHCP, servers: backup.servers,
                                           searchDomains: backup.searchDomains ?? current.searchDomains, failure: failure) { now in
                // Back on DHCP, the servers set by hand no longer count (some cameras keep the last ones).
                now.fromDHCP == backup.fromDHCP && (backup.fromDHCP || Self.same(now.backup.servers, backup.servers))
            }
        }
    }

    // MARK: ONVIF

    /// `GetDNS`; nil when the camera does not answer it (a fault or an HTTP error that is not a login refusal).
    private func onvifDNS(_ client: ONVIFClient) async throws -> ONVIFDNSSettings? {
        do { return try await client.dns() } catch let error as CameraAdapterError where !error.isLoginRefusal { return nil }
    }

    static func onvifReading(_ dns: ONVIFDNSSettings) -> CameraDNSReading {
        var servers: [String] = []
        for server in dns.servers where !servers.contains(where: { ONVIFClient.sameAddress($0, server) }) { servers.append(server) }
        let backup = CameraDNSBackup(method: .onvifMinimal, fromDHCP: dns.fromDHCP, servers: dns.manualServers, searchDomains: dns.searchDomains)
        return CameraDNSReading(servers: servers, fromDHCP: dns.fromDHCP, method: .onvifMinimal, backup: backup)
    }

    private func writeONVIFDNS(_ client: ONVIFClient, fromDHCP: Bool, servers: [String], searchDomains: [String], failure: String,
                               verify: (CameraDNSReading) -> Bool) async throws -> CameraSetupOutcome {
        do {
            try await client.setDNS(fromDHCP: fromDHCP, servers: servers, searchDomains: searchDomains)
        } catch let error as CameraAdapterError where !error.isLoginRefusal {
            return .refused(Redact.string(String(describing: error)))
        }
        guard let after = try await onvifDNS(client), verify(Self.onvifReading(after)) else { return .refused(failure) }
        log.info("Set the camera's DNS servers through ONVIF")
        return CameraSetupOutcome(succeeded: true, detail: "via ONVIF")
    }

    // MARK: ISAPI

    /// The interface's address document and its DNS servers; nil when the camera does not have it or it holds no DNS servers.
    private func isapiDNSDocument() async throws -> (document: String, servers: ISAPIDNSServers)? {
        guard let document = try await isapi().document(HikvisionISAPI.ipAddressPath),
              let servers = HikvisionISAPI.dnsServers(in: document) else { return nil }
        return (document, servers)
    }

    /// Writes `servers` into the document as the camera has it now and reads it back; a camera that shows no document afterwards is a
    /// refusal (nothing to check the write against). ISAPI `statusCode` 7 is noted (the camera may show the old servers until it restarts,
    /// and Camera Bridge never restarts it): the step is done, waiting for the restart, and the security check reads the camera's DNS again
    /// before the guard counts the camera as watched (`GuardEvidence.asksBridge`).
    private func writeISAPIDNS(_ servers: [String], failure: String, verify: (CameraDNSReading) -> Bool) async throws -> CameraSetupOutcome {
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
        guard verify(reading) || restart else { return .refused(failure) }
        log.info("Set the camera's DNS servers through ISAPI")
        return CameraSetupOutcome(succeeded: true, needsRestart: restart, detail: "via ISAPI")
    }

    /// The same servers in the same order.
    static func same(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { ONVIFClient.sameAddress($0, $1) }
    }
}

// MARK: - The setup step

extension CameraSettingsService {
    /// "Watch its internet" for the preview: the camera's DNS servers now against `server` (the bridge's address on the camera's network).
    /// Already right when the camera asks that address and no other; the backup is the camera's value now.
    public func readInternetWatch(server: String) async throws -> (CameraSetupReading, CameraDNSBackup?) {
        guard let dns = try await readDNS() else { return (.notSupported("the camera does not show its DNS servers"), nil) }
        if dns.pointsAt(server) { return (CameraSetupReading(state: .alreadyRight), dns.backup) }
        let servers = CameraSetupText.list(dns.servers)
        let now = dns.fromDHCP ? (dns.servers.isEmpty ? "from the router (DHCP)" : "\(servers) from the router (DHCP)")
            : dns.servers.isEmpty ? "none set" : servers
        return (CameraSetupReading(state: .willChange, changes: [.init(label: "DNS", now: now, after: "the bridge (\(server))")]), dns.backup)
    }
}
