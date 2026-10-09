import Crypto
import Foundation
import Synchronization

public struct HTTPCredentials: Sendable, Hashable, Codable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// A parsed `WWW-Authenticate: Digest …` challenge (RFC 2617 / RFC 7616).
public struct DigestChallenge: Sendable, Equatable {
    public var realm: String
    public var nonce: String
    public var opaque: String?
    /// "MD5" (default), "MD5-sess", "SHA-256", "SHA-256-sess".
    public var algorithm: String
    public var qop: [String]
    public var stale: Bool

    public init(realm: String, nonce: String, opaque: String? = nil, algorithm: String = "MD5", qop: [String] = [], stale: Bool = false) {
        self.realm = realm
        self.nonce = nonce
        self.opaque = opaque
        self.algorithm = algorithm
        self.qop = qop
        self.stale = stale
    }

    /// Accepts a header value such as `Digest realm="…", nonce="…"`. The Digest challenge may appear after other
    /// schemes in a combined header value. Returns nil when there is no Digest challenge with realm and nonce.
    public static func parse(_ wwwAuthenticate: String) -> DigestChallenge? {
        guard let params = AuthParamScanner.digestParameters(in: wwwAuthenticate),
              let realm = params["realm"], let nonce = params["nonce"] else { return nil }
        let qop = (params["qop"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return DigestChallenge(
            realm: realm,
            nonce: nonce,
            opaque: params["opaque"],
            algorithm: params["algorithm"] ?? "MD5",
            qop: qop,
            stale: params["stale"]?.lowercased() == "true")
    }
}

/// Tokenizer for RFC 7235 challenges: `scheme param=value, param="quoted", scheme2 …`.
enum AuthParamScanner {
    /// Parameters (lowercased names) of the first `Digest` challenge in `header`, or nil if none.
    static func digestParameters(in header: String) -> [String: String]? {
        let chars = Array(header)
        var i = 0
        var inDigest = false
        var found = false
        var params: [String: String] = [:]

        func skip(_ set: Set<Character>) { while i < chars.count, set.contains(chars[i]) { i += 1 } }
        func token() -> String {
            let start = i
            while i < chars.count, !" \t,=\"".contains(chars[i]) { i += 1 }
            return String(chars[start..<i])
        }

        while i < chars.count {
            skip([" ", "\t", ","])
            guard i < chars.count else { break }
            let name = token()
            if name.isEmpty { i += 1; continue }
            skip([" ", "\t"])
            if i < chars.count, chars[i] == "=" {
                i += 1
                skip([" ", "\t"])
                var value = ""
                if i < chars.count, chars[i] == "\"" {
                    i += 1
                    while i < chars.count, chars[i] != "\"" {
                        if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                        value.append(chars[i])
                        i += 1
                    }
                    i += 1   // closing quote
                } else {
                    value = token()
                }
                if inDigest { params[name.lowercased()] = value }
            } else {
                // A bare token starts a new challenge (auth-scheme).
                if found { break }
                inDigest = name.lowercased() == "digest"
                found = inDigest
            }
        }
        return found ? params : nil
    }
}

/// Computes `Authorization: Digest …` values. Tracks the nonce count per nonce.
public struct DigestAuthenticator: Sendable {
    private let credentials: HTTPCredentials
    private let makeCNonce: @Sendable () -> String
    private var lastNonce: String?
    private var nonceCount: UInt32 = 0

    public init(credentials: HTTPCredentials) {
        self.init(credentials: credentials, cnonce: {
            var generator = SystemRandomNumberGenerator()
            return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
        })
    }

    /// Deterministic client nonces (tests, RFC vectors).
    public init(credentials: HTTPCredentials, cnonce: @escaping @Sendable () -> String) {
        self.credentials = credentials
        self.makeCNonce = cnonce
    }

    /// Full header value (`Digest username="…", …`) for `method` and `uri` (the request target as sent), for a
    /// request without an entity body. See `authorization(for:method:uri:body:)`.
    public mutating func authorization(for challenge: DigestChallenge, method: String, uri: String) -> String {
        authorization(for: challenge, method: method, uri: uri, body: Data())
    }

    /// Full header value for `method`, `uri` and the request entity `body`. qop selection: `auth` when offered,
    /// else `auth-int` (HA2 = H(method:uri:H(body))), else RFC 2069 legacy (no qop/nc/cnonce).
    public mutating func authorization(for challenge: DigestChallenge, method: String, uri: String, body: Data) -> String {
        if challenge.nonce != lastNonce {
            lastNonce = challenge.nonce
            nonceCount = 0
        }
        nonceCount &+= 1

        let algorithm = challenge.algorithm.uppercased()
        let useSHA256 = algorithm.hasPrefix("SHA-256")
        let isSession = algorithm.hasSuffix("-SESS")
        let hash: (Data) -> String = { useSHA256 ? Self.sha256Hex($0) : Self.md5Hex($0) }
        let hashString: (String) -> String = { hash(Data($0.utf8)) }
        let qop: String? = challenge.qop.contains("auth") ? "auth" : challenge.qop.contains("auth-int") ? "auth-int" : nil
        let cnonce = makeCNonce()
        let nc = String(format: "%08x", nonceCount)

        var ha1 = hashString("\(credentials.username):\(challenge.realm):\(credentials.password)")
        if isSession { ha1 = hashString("\(ha1):\(challenge.nonce):\(cnonce)") }
        let ha2 = qop == "auth-int" ? hashString("\(method):\(uri):\(hash(body))") : hashString("\(method):\(uri)")
        let response = qop.map { hashString("\(ha1):\(challenge.nonce):\(nc):\(cnonce):\($0):\(ha2)") }
            ?? hashString("\(ha1):\(challenge.nonce):\(ha2)")

        var parts = [
            "username=\(Self.quoted(credentials.username))",
            "realm=\(Self.quoted(challenge.realm))",
            "nonce=\(Self.quoted(challenge.nonce))",
            "uri=\(Self.quoted(uri))",
        ]
        if algorithm != "MD5" { parts.append("algorithm=\(challenge.algorithm)") }
        parts.append("response=\(Self.quoted(response))")
        if let opaque = challenge.opaque { parts.append("opaque=\(Self.quoted(opaque))") }
        if let qop {
            parts.append("qop=\(qop)")
            parts.append("nc=\(nc)")
            parts.append("cnonce=\(Self.quoted(cnonce))")
        }
        return "Digest " + parts.joined(separator: ", ")
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum BasicAuth {
    /// `Basic base64(username:password)`.
    public static func header(_ credentials: HTTPCredentials) -> String {
        "Basic " + Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
    }
}

/// Refuses to move a host from Digest to Basic. Basic sends the password itself (base64), so a host impersonating a
/// Digest camera (ARP or DHCP spoofing, then a plaintext connection or any self-signed certificate) would read it from
/// the answer to a single `401` that offers only Basic. Once a host asked for Digest, `mayAnswerBasic` is false for it
/// (a warning is logged once per host); a host that never asked for Digest is still answered (cameras that support
/// only Basic), which is logged once per host per process. One instance per client (`AuthenticatingHTTPClient`, the
/// sessions of one `RTSPMediaSource`, a Hikvision talkback sink), never shared between cameras: a camera switched to
/// Basic on purpose is answered again once its runtime restarts. Keys are `scheme:host:port` (no user info).
package final class BasicDowngradeGuard: Sendable {
    private struct State {
        var digestHosts: Set<String> = []
        var refusedHosts: Set<String> = []
    }

    private let state = Mutex(State())
    /// Hosts whose use of Basic was logged: process-wide, so short-lived clients (probes, reconnects) do not repeat it.
    private static let basicLogged = Mutex<Set<String>>([])

    package init() {}

    /// Notes that `host` asked for Digest.
    package func digestRequested(by host: String) {
        _ = state.withLock { $0.digestHosts.insert(host) }
    }

    /// Whether Basic credentials may be sent to `host`: false once it asked for Digest.
    package func mayAnswerBasic(from host: String, log: Log) -> Bool {
        let (refused, firstRefusal) = state.withLock { state -> (Bool, Bool) in
            guard state.digestHosts.contains(host) else { return (false, false) }
            return (true, state.refusedHosts.insert(host).inserted)
        }
        if refused {
            if firstRefusal {
                log.warning("\(host) asked for Basic authentication after using Digest; the password was not sent. Something on the "
                            + "network may be impersonating the camera (if the camera was switched to Basic, restart Camera Bridge)")
            }
            return false
        }
        if Self.basicLogged.withLock({ $0.insert(host).inserted }) {
            log.notice("\(host) uses Basic authentication: the password is sent base64-encoded, readable on the network without HTTPS")
        }
        return true
    }
}
