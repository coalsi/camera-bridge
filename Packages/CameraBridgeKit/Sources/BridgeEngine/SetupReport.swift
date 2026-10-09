import CameraAdapters
import Foundation

/// The anonymous camera setup report people can choose to send (`POST /api/v1/setup-reports`): which camera brand and
/// model, which ways of changing its settings worked or failed, and the readiness results. It never carries addresses,
/// names, passwords, serial numbers, images or video: every free-text field is scrubbed (`SetupReportScrubber`) and
/// the report is built only from what is listed here. The app shows the exact JSON (`prettyJSON`) before sending it.
public struct SetupReport: Sendable, Equatable, Codable {
    public static let schemaVersion = 1

    public struct ReadinessEntry: Sendable, Equatable, Codable {
        public var id: String
        public var status: String
    }

    public struct MethodEntry: Sendable, Equatable, Codable {
        public var fix: String
        public var method: String
        /// "ok" or "failed".
        public var result: String
        public var reason: String?
    }

    public var schema: Int
    public var appVersion: String
    public var osVersion: String
    public var vendor: String
    public var model: String?
    public var firmware: String?
    public var readiness: [ReadinessEntry]
    public var methods: [MethodEntry]
    /// Check IDs still open after the run: failed fixes and manual-only fixes.
    public var unresolved: [String]

    /// Builds a report from an Optimize run. `vendor` is the brand the camera reported (or its vendor name);
    /// `model` and `firmware` come from its device info. Nothing else about the camera goes in.
    public init(result: HomeKitOptimizationResult, vendor: String, model: String?, firmware: String?, appVersion: String, osVersion: String) {
        schema = Self.schemaVersion
        self.appVersion = SetupReportScrubber.field(appVersion) ?? "unknown"
        self.osVersion = SetupReportScrubber.field(osVersion) ?? "unknown"
        self.vendor = SetupReportScrubber.field(vendor) ?? "unknown"
        self.model = SetupReportScrubber.field(model)
        self.firmware = SetupReportScrubber.field(firmware)
        readiness = result.after.checks.map { ReadinessEntry(id: $0.id, status: $0.status.rawValue) }

        var entries: [MethodEntry] = []
        for fix in result.appliedFixes {
            guard let method = result.fixMethods[fix] else { continue }
            entries.append(MethodEntry(fix: fix, method: method.rawValue, result: "ok", reason: nil))
        }
        for failure in result.failedFixes {
            for attempt in failure.attempts {
                entries.append(MethodEntry(fix: failure.checkID, method: attempt.method.rawValue, result: "failed",
                                           reason: SetupReportScrubber.reason(for: attempt.failure)))
            }
        }
        methods = entries

        var open: [String] = result.failedFixes.map(\.checkID)
        for check in result.after.checks where check.status != .ok {
            if case .manual = check.fixMethod { open.append(check.id) }
        }
        var seen = Set<String>()
        unresolved = open.filter { seen.insert($0).inserted }
    }

    /// Whether the run left something worth reporting: a failed or manual-only fix.
    public var hasUnresolvedFixes: Bool { !unresolved.isEmpty }

    /// The exact bytes that are sent: sorted keys, indented, so what the person reads is what goes out.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// `encoded()` as text, for display.
    public var prettyJSON: String {
        guard let data = try? encoded() else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A made-up report for Settings' "Show example report".
    public static let example = SetupReport(
        schema: schemaVersion, appVersion: "1.0 (1)", osVersion: "macOS 27.0", vendor: "Hikvision", model: "DS-2CD2143G2-I", firmware: "V5.7.15",
        readiness: [ReadinessEntry(id: "codec", status: "ok"), ReadinessEntry(id: "keyframeInterval", status: "ok"),
                    ReadinessEntry(id: "smartCodec", status: "warning"), ReadinessEntry(id: "subStream", status: "ok")],
        methods: [MethodEntry(fix: "keyframeInterval", method: "onvifMinimal", result: "failed", reason: "ONVIF minimal: InvalidArgVal"),
                  MethodEntry(fix: "keyframeInterval", method: "hikvisionISAPI", result: "ok", reason: nil)],
        unresolved: ["smartCodec"])

    init(schema: Int, appVersion: String, osVersion: String, vendor: String, model: String?, firmware: String?,
         readiness: [ReadinessEntry], methods: [MethodEntry], unresolved: [String]) {
        self.schema = schema
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.vendor = vendor
        self.model = model
        self.firmware = firmware
        self.readiness = readiness
        self.methods = methods
        self.unresolved = unresolved
    }
}

/// Removes anything that could identify a person, a network or a device from text that goes into a setup report.
public enum SetupReportScrubber {
    static let maximumFieldLength = 64
    static let maximumReasonLength = 80

    /// A failure in a few words. A camera's own fault text is scrubbed in full *before* it is shortened, so a cut can't
    /// leave half of a host name behind.
    public static func reason(for failure: CameraConfigFailure) -> String? {
        if case .rejected(let text) = failure {
            let cleaned = scrub(text, hostsAndIdentifiers: true)
            let head = cleaned.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces) ?? cleaned
            return head.isEmpty ? "rejected" : String(head.prefix(40))
        }
        return reason(failure.summary)
    }

    /// URLs, e-mail addresses, MAC addresses, IPv4/IPv6 addresses, host names and long identifier-like tokens.
    public static func reason(_ text: String) -> String? {
        let cleaned = scrub(text, hostsAndIdentifiers: true)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(maximumReasonLength))
    }

    /// A brand, model, firmware or version field: addresses, URLs and e-mails go; dots in versions stay.
    public static func field(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = scrub(text, hostsAndIdentifiers: false)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(maximumFieldLength))
    }

    private static var url: Regex<Substring> { #/[A-Za-z][A-Za-z0-9+.\-]*:\/\/\S+/# }
    private static var email: Regex<Substring> { #/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+/# }
    private static var mac: Regex<Substring> { #/\b(?:[0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}\b/# }
    private static var ipv4: Regex<Substring> { #/\b\d{1,3}(?:\.\d{1,3}){3}(?::\d{1,5})?\b/# }
    private static var ipv6: Regex<Substring> { #/[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}/# }
    private static var host: Regex<Substring> { #/\b(?:[A-Za-z0-9\-]+\.)+[A-Za-z][A-Za-z0-9\-]*\b/# }
    private static var identifier: Regex<Substring> { #/\b(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{12,}\b/# }

    static func scrub(_ text: String, hostsAndIdentifiers: Bool) -> String {
        // Control characters and runs of whitespace first, so a pattern can't be split by a newline.
        var result = String(text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) })
        result = result.replacing(url, with: "<url>")
        result = result.replacing(email, with: "<email>")
        result = result.replacing(mac, with: "<mac>")
        result = result.replacing(ipv4, with: "<ip>")
        result = result.replacing(ipv6, with: "<ip>")
        if hostsAndIdentifiers {
            result = result.replacing(host, with: "<host>")
            result = result.replacing(identifier, with: "<id>")
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
