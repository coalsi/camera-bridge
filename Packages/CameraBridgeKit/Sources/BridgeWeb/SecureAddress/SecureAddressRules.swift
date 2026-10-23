import Foundation

/// The rules that tie the web interface to the TLS front and to the secure address. Pure functions, tested alone.
enum SecureAddressRules {
    /// Renewal starts this long before the certificate expires.
    static let renewBefore: TimeInterval = 30 * 24 * 3600

    /// Waits between certificate tries after a failure: 10 min, 30 min, 1 h, 3 h, then 6 h.
    static func retryDelay(attempts: Int) -> TimeInterval {
        let steps: [TimeInterval] = [600, 1800, 3600, 3 * 3600, 6 * 3600]
        return steps[min(max(attempts - 1, 0), steps.count - 1)]
    }

    /// How long to leave the website alone after it failed: "too many requests" waits for the website's next day (UTC midnight, at least
    /// an hour); anything else grows like `retryDelay` (10 min to 6 h), so a broken website is not asked every minute.
    static func websiteWait(after kind: BoxClientError.Kind, failures: Int, now: Date) -> Date {
        if kind == .rateLimited {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let midnight = utc.nextDate(after: now, matching: DateComponents(hour: 0, minute: 5), matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
            return max(midnight, now.addingTimeInterval(3600))
        }
        return now.addingTimeInterval(retryDelay(attempts: failures))
    }

    /// Whether a certificate must be asked for now.
    static func needsCertificate(_ status: CertificateStatus, host: String, now: Date) -> Bool {
        guard status.state != "working" else { return false }
        guard let notAfter = status.notAfter, status.host == host, status.state == "ready" || status.state == "failed" else { return true }
        return notAfter.timeIntervalSince(now) < renewBefore
    }

    /// A certificate that browsers accept now: for this host and not expired.
    static func isValid(_ status: CertificateStatus?, host: String?, now: Date) -> Bool {
        guard let status, let host, status.host == host, let notAfter = status.notAfter else { return false }
        return notAfter > now && (status.state == "ready" || status.state == "failed")
    }

    /// The box's address on the home network among its addresses: the one sent before while it is still there, else the first private one.
    static func homeAddress(among addresses: [String], previous: String?) -> String? {
        let privateOnes = addresses.filter(isPrivateIPv4)
        if let previous, privateOnes.contains(previous) { return previous }
        return privateOnes.first
    }

    static func isPrivateIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard parts.count == 4, text.split(separator: ".").count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
    }

    // MARK: The redirect

    /// Where a plain-HTTP request goes, or nil to serve it. Only a browser opening a page (GET or HEAD, asking for HTML) at a `.local` name,
    /// and only when the switch is on, a valid certificate is in place and the setup hotspot is not open. Never an API call (Apple Home's
    /// helpers, `cbctl`, the health check), never a request from this box itself (the TLS front, the box's tools), never an address typed
    /// as an IP number, so that one stays a way in if the certificate ever fails.
    static func redirectTarget(for request: HTTPRequest, host: String?, enabled: Bool, certificateValid: Bool, hotspotOpen: Bool) -> String? {
        guard enabled, certificateValid, !hotspotOpen, let host, !request.isSecure else { return nil }
        guard request.method == "GET" || request.method == "HEAD" else { return nil }
        guard !isLoopback(request.remoteAddress) else { return nil }
        let path = request.path
        guard path != "/api", !path.hasPrefix("/api/"), !path.hasPrefix("/.well-known/") else { return nil }
        guard let name = request.hostName?.lowercased(), name.hasSuffix(".local") || name.hasSuffix(".local.") else { return nil }
        guard (request.headers["Accept"] ?? "").lowercased().contains("text/html") else { return nil }
        return "https://\(host)\(request.target)"
    }

    static func isLoopback(_ address: String) -> Bool {
        address == "::1" || address == "127.0.0.1" || address.hasPrefix("127.")
    }

    // MARK: The TLS front

    /// The request as the daemon should see it. The TLS front (nginx) is on this box and connects from loopback; it sets
    /// `X-Forwarded-For` (the real client) and `X-Forwarded-Proto: https`. Those headers count only from a loopback peer: anyone else
    /// on the network could write them.
    static func normalized(_ request: HTTPRequest) -> HTTPRequest {
        var request = request
        request.isSecure = false
        guard isLoopback(request.remoteAddress), request.headers["X-Forwarded-Proto"]?.lowercased() == "https" else { return request }
        request.isSecure = true
        if let forwarded = request.headers["X-Forwarded-For"]?.split(separator: ",").last?.trimmingCharacters(in: .whitespaces), !forwarded.isEmpty {
            request.remoteAddress = forwarded
        }
        return request
    }
}
