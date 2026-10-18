import BridgeSupport
import Foundation

/// Where the camera took its time from before the setup pointed it at the bridge.
public struct CameraTimeSourceBackup: Sendable, Codable, Equatable {
    /// `.hikvisionISAPI`, `.reolinkAPI` or `.onvifMinimal`.
    public var method: CameraConfigMethod
    /// ISAPI `timeMode` ("NTP", "manual"), ONVIF `DateTimeType` ("NTP", "Manual"), or Reolink's `Ntp.enable` ("NTP" for 1, "manual" for 0).
    public var mode: String
    /// ISAPI: the time server's `addressingFormatType`, `hostName`, `ipAddress` and `portNo` as the camera had them (nil: absent).
    /// Reolink: `hostName` and `port` are `Ntp.server` and `Ntp.port`.
    public var addressing: String?
    public var hostName: String?
    public var ipAddress: String?
    public var port: String?
    /// ONVIF: servers from DHCP, and the manual ones.
    public var fromDHCP: Bool?
    public var servers: [String]
    /// Reolink: `Ntp.interval`, minutes between synchronizations (nil: not read, or another camera).
    public var interval: Int?

    public init(method: CameraConfigMethod, mode: String, addressing: String? = nil, hostName: String? = nil, ipAddress: String? = nil,
                port: String? = nil, fromDHCP: Bool? = nil, servers: [String] = [], interval: Int? = nil) {
        self.method = method
        self.mode = mode
        self.addressing = addressing
        self.hostName = hostName
        self.ipAddress = ipAddress
        self.port = port
        self.fromDHCP = fromDHCP
        self.servers = servers
        self.interval = interval
    }
}

/// "Time from the box": the camera's clock set by NTP from the bridge's address (Camera Bridge OS serves time to the local network), so
/// every camera and the bridge agree without the internet. Hikvision through ISAPI (`/ISAPI/System/time` mode NTP and
/// `/ISAPI/System/time/ntpServers/1`), Reolink through its own API only (`GetNtp` / `SetNtp`, CameraSettingsService+Reolink.swift: Reolink
/// refuses ONVIF's writes to its ONVIF user; a backup an earlier build saved through ONVIF is put back that way too), other cameras through
/// ONVIF (`SetNTP`, then `SetSystemDateAndTime` with NTP).
extension CameraSettingsService {
    public func readTimeSource(server: String) async throws -> (CameraSetupReading, CameraTimeSourceBackup?) {
        if vendor == .reolink { return try await readReolinkTimeSource(server: server) }
        let after = "NTP from the bridge (\(server))"
        if vendor == .hikvision, let (time, ntp) = try await isapiTimeDocuments() {
            let backup = Self.isapiTimeBackup(time: time, ntp: ntp)
            let now = Self.isapiTimeSourceText(backup)
            if Self.isapiPointsAt(server, backup) { return (CameraSetupReading(state: .alreadyRight), backup) }
            return (CameraSetupReading(state: .willChange, changes: [.init(label: "Time source", now: now, after: after)]), backup)
        }
        guard let client = await client() else { return (.notSupported("the camera has no ONVIF device service"), nil) }
        let settings = try await client.dateTimeSettings()
        let ntp: ONVIFNTPSettings
        do { ntp = try await client.ntp() } catch let error as CameraAdapterError where !error.isLoginRefusal {
            return (.notSupported("the camera does not show its time servers"), nil)
        }
        let backup = CameraTimeSourceBackup(method: .onvifMinimal, mode: settings.type, fromDHCP: ntp.fromDHCP, servers: ntp.servers)
        let isNTP = settings.type.caseInsensitiveCompare("NTP") == .orderedSame
        if isNTP, !ntp.fromDHCP, ntp.servers == [server] { return (CameraSetupReading(state: .alreadyRight), backup) }
        let now = !isNTP ? "set by hand" : ntp.fromDHCP ? "NTP from the router (DHCP)" : ntp.servers.isEmpty ? "NTP, no server set" : "NTP from \(CameraSetupText.list(ntp.servers))"
        return (CameraSetupReading(state: .willChange, changes: [.init(label: "Time source", now: now, after: after)]), backup)
    }

    /// Points the camera's clock at `server` (an IPv4 address) by NTP, then reads it back.
    public func applyTimeSource(server: String) async throws -> CameraSetupOutcome {
        if vendor == .reolink { return try await applyReolinkTimeSource(server: server) }
        if vendor == .hikvision, let (time, ntp) = try await isapiTimeDocuments() {
            var current = Self.isapiTimeBackup(time: time, ntp: ntp)
            current.addressing = "ipaddress"
            current.ipAddress = server
            current.port = "123"
            current.mode = "NTP"
            return try await writeISAPITimeSource(current, verify: { Self.isapiPointsAt(server, $0) })
        }
        guard let client = await client() else { return .refused("the camera has no ONVIF device service") }
        do {
            try await client.setNTP(ONVIFNTPSettings(fromDHCP: false, servers: [server]))
            var settings = try await client.dateTimeSettings()
            if settings.type.caseInsensitiveCompare("NTP") != .orderedSame {
                settings.type = "NTP"
                try await client.setDateTime(settings)
            }
        } catch let error as CameraAdapterError where !error.isLoginRefusal {
            return .refused(error)
        }
        let ntp = try await client.ntp(), settings = try await client.dateTimeSettings()
        guard ntp.servers == [server], !ntp.fromDHCP, settings.type.caseInsensitiveCompare("NTP") == .orderedSame else {
            return .refused("the camera kept its own time source")
        }
        return CameraSetupOutcome(succeeded: true, detail: "via ONVIF")
    }

    /// Puts the camera's time source back as the backup has it. `bridge`: the bridge's address the setup gave the camera as its time server
    /// (a Reolink's older backup that names no server is refused only while the camera still asks it).
    public func restoreTimeSource(_ backup: CameraTimeSourceBackup, bridge: String? = nil) async throws -> CameraSetupOutcome {
        switch backup.method {
        case .hikvisionISAPI:
            return try await writeISAPITimeSource(backup, verify: { now in
                now.mode.caseInsensitiveCompare(backup.mode) == .orderedSame && (backup.addressing == nil || now.addressing == backup.addressing)
                    && (backup.hostName == nil || now.hostName == backup.hostName) && (backup.ipAddress == nil || now.ipAddress == backup.ipAddress)
            })
        case .reolinkAPI:
            return try await restoreReolinkTimeSource(backup)
        default:
            // A Reolink's backup an earlier build saved through ONVIF goes back through its own API, as the run's change did.
            if vendor == .reolink, let outcome = try await restoreReolinkTimeSourceFromONVIF(backup, bridge: bridge) { return outcome }
            guard let client = await client() else { return .refused("the camera has no ONVIF device service") }
            do {
                try await client.setNTP(ONVIFNTPSettings(fromDHCP: backup.fromDHCP ?? false, servers: backup.servers))
                var settings = try await client.dateTimeSettings()
                if settings.type.caseInsensitiveCompare(backup.mode) != .orderedSame {
                    settings.type = backup.mode
                    try await client.setDateTime(settings)
                }
            } catch let error as CameraAdapterError where !error.isLoginRefusal {
                return .refused(error)
            }
            let ntp = try await client.ntp()
            return ntp.servers == backup.servers ? CameraSetupOutcome(succeeded: true, detail: "via ONVIF") : .refused("the camera kept the bridge as its time server")
        }
    }

    // MARK: ISAPI

    /// The clock document and the first time server's document; nil when the camera does not have both.
    private func isapiTimeDocuments() async throws -> (time: String, ntp: String)? {
        guard let time = try await isapi().document(HikvisionISAPI.timePath), HikvisionISAPI.elementText("timeMode", in: time) != nil,
              let ntp = try await isapi().document(HikvisionISAPI.ntpServerPath) else { return nil }
        return (time, ntp)
    }

    static func isapiTimeBackup(time: String, ntp: String) -> CameraTimeSourceBackup {
        CameraTimeSourceBackup(method: .hikvisionISAPI, mode: HikvisionISAPI.elementText("timeMode", in: time) ?? "manual",
                               addressing: HikvisionISAPI.elementText("addressingFormatType", in: ntp),
                               hostName: HikvisionISAPI.elementText("hostName", in: ntp), ipAddress: HikvisionISAPI.elementText("ipAddress", in: ntp),
                               port: HikvisionISAPI.elementText("portNo", in: ntp))
    }

    static func isapiPointsAt(_ server: String, _ values: CameraTimeSourceBackup) -> Bool {
        values.mode.caseInsensitiveCompare("NTP") == .orderedSame && values.addressing?.lowercased() == "ipaddress" && values.ipAddress == server
            && (values.port == nil || values.port == "123")
    }

    static func isapiTimeSourceText(_ values: CameraTimeSourceBackup) -> String {
        guard values.mode.caseInsensitiveCompare("NTP") == .orderedSame else { return "set by hand" }
        let host = values.addressing?.lowercased() == "ipaddress" ? values.ipAddress : values.hostName
        return host.map { $0.isEmpty ? "NTP, no server set" : "NTP from \($0)" } ?? "NTP"
    }

    /// Writes the time server (`ntpServers/1`), then the clock's mode (`time`), each a read-modify-write, and reads both back.
    private func writeISAPITimeSource(_ wanted: CameraTimeSourceBackup, verify: (CameraTimeSourceBackup) -> Bool) async throws -> CameraSetupOutcome {
        let api = isapi()
        guard let (time, ntp) = try await isapiTimeDocuments() else { return .refused("the camera no longer shows its time settings") }
        var restart = false
        var server = ntp
        for (name, value) in [("addressingFormatType", wanted.addressing), ("hostName", wanted.hostName), ("ipAddress", wanted.ipAddress), ("portNo", wanted.port)] {
            guard let value, let edited = HikvisionISAPI.settingElement(name, to: value, in: server, addingBefore: "</NTPServer>") else { continue }
            server = edited
        }
        do {
            if server != ntp { restart = try await api.write(HikvisionISAPI.ntpServerPath, document: server) == .rebootRequired || restart }
            if HikvisionISAPI.elementText("timeMode", in: time) != wanted.mode, let edited = HikvisionISAPI.settingElement("timeMode", to: wanted.mode, in: time) {
                restart = try await api.write(HikvisionISAPI.timePath, document: Self.withoutLocalTime(edited)) == .rebootRequired || restart
            }
        } catch let refusal as ISAPIRefusal {
            return .refused(refusal.words)
        }
        guard let (timeAfter, ntpAfter) = try await isapiTimeDocuments() else { return CameraSetupOutcome(succeeded: true, needsRestart: restart, detail: "via ISAPI") }
        guard verify(Self.isapiTimeBackup(time: timeAfter, ntp: ntpAfter)) || restart else { return .refused("the camera kept its own time source") }
        return CameraSetupOutcome(succeeded: true, needsRestart: restart, detail: "via ISAPI")
    }

    /// The clock document to write back: without `localTime` when the clock keeps time by NTP (written back, the camera would set its clock
    /// to the time it was read at); as read when it is set by hand (the camera needs a time then).
    static func withoutLocalTime(_ document: String, now: Date = Date()) -> String {
        guard HikvisionISAPI.elementText("timeMode", in: document)?.caseInsensitiveCompare("NTP") == .orderedSame else {
            // Set by hand: the camera needs a time; one written back without it (it was NTP until now) gets the bridge's.
            guard HikvisionISAPI.elementText("localTime", in: document) == nil else { return document }
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            return HikvisionISAPI.settingElement("localTime", to: formatter.string(from: now), in: document, addingBefore: "</Time>") ?? document
        }
        guard let open = document.range(of: "<localTime", options: .caseInsensitive),
              let close = document.range(of: "</localTime>", options: .caseInsensitive, range: open.upperBound..<document.endIndex) else { return document }
        var result = document
        result.removeSubrange(open.lowerBound..<close.upperBound)
        return result
    }
}
