import BridgeSupport
import Foundation

/// The camera's clock settings as ONVIF's `GetSystemDateAndTime` reports them.
struct ONVIFDateTimeSettings: Sendable, Equatable {
    /// "NTP" or "Manual".
    var type: String
    var daylightSavings: Bool
    /// The POSIX TZ string; nil when the camera reports none.
    var timeZone: String?
}

/// Where the camera takes its time from (`GetNTP`).
struct ONVIFNTPSettings: Sendable, Equatable {
    var fromDHCP: Bool
    /// The manual servers: addresses or names.
    var servers: [String]
}

/// ONVIF device service: the clock's mode and time zone, and its time servers (`GetNTP` / `SetNTP`).
extension ONVIFClient {
    func dateTimeSettings() async throws -> ONVIFDateTimeSettings {
        let envelope = try await call(deviceServiceURL, body: "<tds:GetSystemDateAndTime/>",
                                      action: "http://www.onvif.org/ver10/device/wsdl/GetSystemDateAndTime", authenticated: false)
        let body = try responseBody(envelope, "GetSystemDateAndTimeResponse")
        return Self.parseDateTimeSettings(body)
    }

    static func parseDateTimeSettings(_ body: XMLTree) -> ONVIFDateTimeSettings {
        let type = body.firstDescendant("DateTimeType")?.text.trimmingCharacters(in: .whitespaces) ?? "NTP"
        let dst = body.firstDescendant("DaylightSavings").flatMap { ONVIFNotification.parseBool($0.text) } ?? false
        let tz = body.firstDescendant("TimeZone")?.child("TZ")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ONVIFDateTimeSettings(type: type.isEmpty ? "NTP" : type, daylightSavings: dst, timeZone: tz?.isEmpty == false ? tz : nil)
    }

    /// `SetSystemDateAndTime` with these values. A camera set by hand (`Manual`) gets the bridge's UTC time with it.
    func setDateTime(_ settings: ONVIFDateTimeSettings) async throws {
        let manual = settings.type.caseInsensitiveCompare("Manual") == .orderedSame
        var body = "<tds:SetSystemDateAndTime><tds:DateTimeType>\(manual ? "Manual" : "NTP")</tds:DateTimeType>"
            + "<tds:DaylightSavings>\(settings.daylightSavings)</tds:DaylightSavings>"
        if let zone = settings.timeZone { body += "<tds:TimeZone><tt:TZ>\(XMLTree.escape(zone))</tt:TZ></tds:TimeZone>" }
        if manual {
            let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: Date())
            body += "<tds:UTCDateTime><tt:Time><tt:Hour>\(parts.hour ?? 0)</tt:Hour><tt:Minute>\(parts.minute ?? 0)</tt:Minute>"
                + "<tt:Second>\(parts.second ?? 0)</tt:Second></tt:Time><tt:Date><tt:Year>\(parts.year ?? 2026)</tt:Year>"
                + "<tt:Month>\(parts.month ?? 1)</tt:Month><tt:Day>\(parts.day ?? 1)</tt:Day></tt:Date></tds:UTCDateTime>"
        }
        body += "</tds:SetSystemDateAndTime>"
        _ = try await call(deviceServiceURL, body: body, action: "http://www.onvif.org/ver10/device/wsdl/SetSystemDateAndTime")
    }

    func ntp() async throws -> ONVIFNTPSettings {
        let envelope = try await call(deviceServiceURL, body: "<tds:GetNTP/>", action: "http://www.onvif.org/ver10/device/wsdl/GetNTP")
        return Self.parseNTP(try responseBody(envelope, "GetNTPResponse"))
    }

    static func parseNTP(_ body: XMLTree) -> ONVIFNTPSettings {
        let information = body.firstDescendant("NTPInformation") ?? body
        let fromDHCP = information.child("FromDHCP").flatMap { ONVIFNotification.parseBool($0.text) } ?? false
        let servers = information.children("NTPManual").compactMap { entry -> String? in
            let value = entry.string("IPv4Address") ?? entry.string("IPv6Address") ?? entry.string("DNSname")
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return ONVIFNTPSettings(fromDHCP: fromDHCP, servers: servers)
    }

    /// `SetNTP`: each server as an IPv4 or IPv6 address, or a DNS name.
    func setNTP(_ settings: ONVIFNTPSettings) async throws {
        var body = "<tds:SetNTP><tds:FromDHCP>\(settings.fromDHCP)</tds:FromDHCP>"
        for server in settings.servers {
            let escaped = XMLTree.escape(server)
            if Self.isIPv4(server) {
                body += "<tds:NTPManual><tt:Type>IPv4</tt:Type><tt:IPv4Address>\(escaped)</tt:IPv4Address></tds:NTPManual>"
            } else if server.contains(":") {
                body += "<tds:NTPManual><tt:Type>IPv6</tt:Type><tt:IPv6Address>\(escaped)</tt:IPv6Address></tds:NTPManual>"
            } else {
                body += "<tds:NTPManual><tt:Type>DNS</tt:Type><tt:DNSname>\(escaped)</tt:DNSname></tds:NTPManual>"
            }
        }
        body += "</tds:SetNTP>"
        _ = try await call(deviceServiceURL, body: body, action: "http://www.onvif.org/ver10/device/wsdl/SetNTP")
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in part.count <= 3 && !part.isEmpty && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255 }
    }
}
