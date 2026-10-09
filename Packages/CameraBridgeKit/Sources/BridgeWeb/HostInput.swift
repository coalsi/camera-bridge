import Foundation

/// A camera address as typed or pasted into the Add Camera page: `192.0.2.20`, `camera.local:8000`,
/// `http://admin:pw@192.0.2.20/doc/page.html`, `[fe80::1%en0]:80` or a bare `fe80::1`. Path, query and fragment are
/// dropped; user info is split off so the page can move it into the credential fields. (The Mac app's `HostInput`.)
struct HostInput: Equatable {
    static let schemes: Set<String> = ["http", "https", "rtsp", "rtsps"]

    var host: String
    var port: Int?
    /// Lowercased: http, https, rtsp or rtsps.
    var scheme: String?
    var user: String?
    var password: String?

    /// Nil when `text` isn't an address (empty, spaces or other stray characters, a bad port, an unsupported scheme).
    init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var scheme: String?
        if let separator = rest.range(of: "://") {
            let name = rest[..<separator.lowerBound].lowercased()
            guard Self.schemes.contains(name) else { return nil }
            scheme = name
            rest = rest[separator.upperBound...]
        }
        // The authority ends at the first `/`, `?` or `#` (RFC 3986 §3.2).
        if let end = rest.firstIndex(where: { "/?#".contains($0) }) { rest = rest[..<end] }
        var user: String?, password: String?
        if let at = rest.lastIndex(of: "@") {
            let info = rest[..<at]
            if let colon = info.firstIndex(of: ":") {
                user = String(info[..<colon]).removingPercentEncoding
                password = String(info[info.index(after: colon)...]).removingPercentEncoding
            } else {
                user = String(info).removingPercentEncoding
            }
            rest = rest[rest.index(after: at)...]
        }

        let host: Substring
        var portText: Substring?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = rest[rest.index(after: rest.startIndex)..<close]
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                portText = after.dropFirst()
            }
            guard Self.isIPv6Literal(host) else { return nil }
        } else if rest.filter({ $0 == ":" }).count > 1 {
            host = rest   // bare IPv6 literal: no port
            guard Self.isIPv6Literal(host) else { return nil }
        } else {
            if let colon = rest.firstIndex(of: ":") {
                host = rest[..<colon]
                portText = rest[rest.index(after: colon)...]
            } else {
                host = rest
            }
            guard !host.isEmpty, host.allSatisfy(Self.isNameCharacter) else { return nil }
        }

        var port: Int?
        if let portText {
            guard let value = Int(portText), (1...65_535).contains(value) else { return nil }
            port = value
        }
        self.host = String(host)
        self.port = port
        self.scheme = scheme
        self.user = user.flatMap { $0.isEmpty ? nil : $0 }
        self.password = password
    }

    /// Host names and IPv4 addresses: letters and digits (any script, for `.local` names), `.`, `-` and `_`.
    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || ".-_".contains(character)
    }

    /// Hex digits, `:` and `.` (embedded IPv4), then an optional `%zone` (`fe80::1%en0`).
    private static func isIPv6Literal(_ text: Substring) -> Bool {
        let parts = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard let address = parts.first, address.contains(":"),
              address.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return false }
        guard parts.count == 2 else { return true }
        let zone = parts[1]
        return !zone.isEmpty && zone.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
