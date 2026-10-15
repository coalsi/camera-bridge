import BridgeSupport
import Foundation

/// ONVIF device service: setting the camera's time zone (`SetSystemDateAndTime`).
extension ONVIFClient {
    /// Puts the camera in `posixTimeZone` (a POSIX TZ string, "MST7" or "CST6CDT,M3.2.0,M11.1.0"), with daylight saving as the string says. A camera
    /// that takes its time from NTP keeps doing so; one set by hand gets the bridge's UTC time with it.
    func setTimeZone(posix posixTimeZone: String) async throws {
        try await systemDateAndTime()
        let ntp = (dateTimeType ?? "NTP").caseInsensitiveCompare("Manual") != .orderedSame
        let daylightSavings = PosixTimeZone.hasDaylightSaving(posixTimeZone)
        var body = "<tds:SetSystemDateAndTime><tds:DateTimeType>\(ntp ? "NTP" : "Manual")</tds:DateTimeType>"
            + "<tds:DaylightSavings>\(daylightSavings)</tds:DaylightSavings>"
            + "<tds:TimeZone><tt:TZ>\(XMLTree.escape(posixTimeZone))</tt:TZ></tds:TimeZone>"
        if !ntp {
            let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: Date())
            body += "<tds:UTCDateTime><tt:Time><tt:Hour>\(parts.hour ?? 0)</tt:Hour><tt:Minute>\(parts.minute ?? 0)</tt:Minute>"
                + "<tt:Second>\(parts.second ?? 0)</tt:Second></tt:Time><tt:Date><tt:Year>\(parts.year ?? 2026)</tt:Year>"
                + "<tt:Month>\(parts.month ?? 1)</tt:Month><tt:Day>\(parts.day ?? 1)</tt:Day></tt:Date></tds:UTCDateTime>"
        }
        body += "</tds:SetSystemDateAndTime>"
        _ = try await call(deviceServiceURL, body: body, action: "http://www.onvif.org/ver10/device/wsdl/SetSystemDateAndTime")
    }
}

/// A time zone as cameras take it: the POSIX TZ string at the end of the system's zone file ("America/Phoenix" → "MST7").
public enum PosixTimeZone {
    /// The POSIX string of the IANA zone `identifier`, from `/usr/share/zoneinfo` (TZif version 2 and later end with it); nil when the zone or the
    /// string is not there.
    public static func string(for identifier: String, zoneDirectory: String = "/usr/share/zoneinfo") -> String? {
        guard TimeZone(identifier: identifier) != nil, !identifier.contains(".."),
              let data = FileManager.default.contents(atPath: "\(zoneDirectory)/\(identifier)"), data.prefix(4) == Data("TZif".utf8),
              data.count > 6, data.last == 0x0A else { return nil }
        let body = data.dropLast()
        guard let start = body.lastIndex(of: 0x0A) else { return nil }
        let footer = String(decoding: body[(start + 1)...], as: UTF8.self)
        return footer.isEmpty || footer.contains(where: { $0.isWhitespace }) ? nil : footer
    }

    /// Whether `posix` has a daylight-saving part: a second zone name after the standard offset ("MST7MDT,…", but not "MST7" or "<-03>3").
    public static func hasDaylightSaving(_ posix: String) -> Bool {
        let head = posix.split(separator: ",", maxSplits: 1).first.map(String.init) ?? posix
        var index = head.startIndex
        func skipName() {
            if index < head.endIndex, head[index] == "<" {
                index = head[index...].firstIndex(of: ">").map { head.index(after: $0) } ?? head.endIndex
            } else {
                while index < head.endIndex, head[index].isLetter { index = head.index(after: index) }
            }
        }
        skipName()
        while index < head.endIndex, "+-0123456789:".contains(head[index]) { index = head.index(after: index) }
        return index < head.endIndex
    }
}
