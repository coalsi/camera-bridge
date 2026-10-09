import Foundation

/// One source in go2rtc's own syntax (`ring:?device_id=…&refresh_token=…`, `nest:?…`, `wyze://192.168.1.20?uid=…`,
/// `rtspx://console:7441/<key>`), the thing a go2rtc stream is made of. It is a secret as a whole (it carries refresh tokens,
/// client secrets, account passwords or a stream key): it is kept in the Keychain as the camera's stored "password", handed to
/// go2rtc through the helper's environment, and never put into `config.json`, a file, a command line or a log. `description`
/// shows the scheme and host only.
///
/// Only the source types Camera Bridge knows are accepted (`allowedSchemes`): go2rtc can also run programs (`exec:`, `echo:`,
/// `expr:`, `ffmpeg:`); those are refused here, and the helper is started without those modules as well.
///
/// The formats come from go2rtc's documentation (MIT, github.com/AlexxIT/go2rtc, README and `internal/<source>/README.md`).
public struct Go2RTCSource: Sendable, Equatable, CustomStringConvertible {
    /// Source types go2rtc 1.9 documents for cameras and that need nothing but their URL. `rtsps` is accepted for convenience and
    /// written as `rtspx` (go2rtc's TLS RTSP that accepts the self-signed certificates consoles use).
    public static let allowedSchemes: Set<String> = ["ring", "nest", "tuya", "wyze", "tapo", "kasa", "rtspx", "rtsps", "xiaomi", "doorbird",
                                                      "dvrip"]

    public struct Invalid: Error, Equatable, Sendable, CustomStringConvertible {
        public var reason: String
        public var description: String { reason }
    }

    /// The complete source, as go2rtc reads it. Secret.
    public let url: String
    /// Lowercased scheme (`ring`, `rtspx`).
    public let scheme: String
    /// The host part (empty for `ring:` and `nest:`).
    public let host: String
    /// Query names (never their values).
    public let parameterNames: Set<String>

    public var service: IntegrationService {
        switch scheme {
        case "ring": .ring
        case "nest": .nest
        case "tuya": .tuya
        case "wyze": .wyze
        default: .other
        }
    }

    /// `ring:`, `wyze://192.168.1.20`: no parameter, key or password.
    public var description: String { host.isEmpty ? "\(scheme):" : "\(scheme)://\(host)" }

    /// Parses and checks what the person pasted. Problems are described without quoting the text (it holds secrets).
    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Invalid(reason: "Paste the source address first.") }
        guard trimmed.utf8.count <= 4096 else { throw Invalid(reason: "That address is too long to be a camera source.") }
        guard !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.isWhitespace }) else {
            throw Invalid(reason: "The source address must be a single line without spaces.")
        }
        guard let colon = trimmed.firstIndex(of: ":") else {
            throw Invalid(reason: "The address must start with the kind of source, like ring: or wyze://.")
        }
        let scheme = trimmed[..<colon].lowercased()
        guard Self.allowedSchemes.contains(scheme) else {
            throw Invalid(reason: "“\(scheme.prefix(20))” sources are not supported. Supported: \(Self.allowedSchemes.sorted().joined(separator: ", ")).")
        }
        var rest = String(trimmed[trimmed.index(after: colon)...])
        var host = ""
        var query = ""
        var path = ""
        if rest.hasPrefix("//") {
            rest.removeFirst(2)
            let hostEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
            var authority = String(rest[..<hostEnd])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }   // user info is not a host
            host = authority
            rest = String(rest[hostEnd...])
        }
        if let mark = rest.firstIndex(of: "?") {
            path = String(rest[..<mark])
            query = String(rest[rest.index(after: mark)...])
        } else {
            path = rest
        }
        if let hash = query.firstIndex(of: "#") { query = String(query[..<hash]) }
        var names: Set<String> = []
        for pair in query.split(separator: "&") {
            let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if !name.isEmpty { names.insert((name.removingPercentEncoding ?? name).lowercased()) }
        }
        try Self.check(scheme: scheme, host: host, path: path, names: names)
        // `rtsps` is go2rtc's `rtspx` here: consoles and cameras use self-signed certificates.
        self.url = scheme == "rtsps" ? "rtspx" + trimmed.dropFirst("rtsps".count) : trimmed
        self.scheme = scheme == "rtsps" ? "rtspx" : scheme
        self.host = host
        self.parameterNames = names
    }

    private static func check(scheme: String, host: String, path: String, names: Set<String>) throws {
        func require(_ required: [String], _ what: String) throws {
            let missing = required.filter { !names.contains($0) }
            guard missing.isEmpty else { throw Invalid(reason: "The \(what) source is missing: \(missing.joined(separator: ", ")).") }
        }
        switch scheme {
        case "ring":
            try require(["refresh_token", "device_id", "camera_id"], "Ring")
        case "nest":
            try require(["client_id", "client_secret", "refresh_token", "project_id", "device_id"], "Google Nest")
        case "tuya":
            guard !host.isEmpty else { throw Invalid(reason: "The Tuya source needs the server name after tuya://.") }
            try require(["device_id"], "Tuya")
            let smart = names.isSuperset(of: ["email", "password"])
            let cloud = names.isSuperset(of: ["uid", "client_id", "client_secret"])
            guard smart || cloud else {
                throw Invalid(reason: "The Tuya source needs either email and password, or uid, client_id and client_secret.")
            }
        case "wyze":
            guard !host.isEmpty else { throw Invalid(reason: "The Wyze source needs the camera's address after wyze://.") }
            try require(["uid", "enr"], "Wyze")
        default:
            guard !host.isEmpty else { throw Invalid(reason: "The address needs a host name or IP address after \(scheme)://.") }
        }
    }

    private init(url: String, scheme: String, host: String, parameterNames: Set<String>) {
        self.url = url
        self.scheme = scheme
        self.host = host
        self.parameterNames = parameterNames
    }

    // MARK: Builders

    /// A Google Nest source from the Device Access values: `nest:?client_id=…&client_secret=…&refresh_token=…&project_id=…&device_id=…`.
    /// `protocols`: `WEB_RTC` (battery and wired cameras, newer doorbells; go2rtc's default) or `RTSP` (legacy Nest Cam, Hub Max).
    public static func nest(clientID: String, clientSecret: String, refreshToken: String, projectID: String, deviceID: String,
                            protocols: String = "WEB_RTC") throws -> Go2RTCSource {
        let items = ["client_id": clientID, "client_secret": clientSecret, "device_id": deviceID, "project_id": projectID, "protocols": protocols,
                     "refresh_token": refreshToken]
        for (name, value) in items where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Invalid(reason: "\(name) is missing.")
        }
        return try Go2RTCSource(parsing: "nest:?" + encodedQuery(items))
    }

    /// A UniFi Protect RTSPS stream (`rtsps://console:7441/<key>?enableSrtp`) as go2rtc reads it: `rtspx://console:7441/<key>` (go2rtc's
    /// docs: use `rtspx://` for Ubiquiti and leave `?enableSrtp` off).
    public static func unifiProtect(rtspsURL: String) throws -> Go2RTCSource {
        guard let url = URL(string: rtspsURL.trimmingCharacters(in: .whitespacesAndNewlines))?.removingUserInfo,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["rtsps", "rtspx", "rtsp"].contains(scheme),
              components.host?.isEmpty == false, !components.path.isEmpty, components.path != "/" else {
            throw Invalid(reason: "The console did not return a usable stream address.")
        }
        components.scheme = scheme == "rtsp" ? "rtsp" : "rtspx"
        components.query = nil
        guard let text = components.string else { throw Invalid(reason: "The console did not return a usable stream address.") }
        guard scheme == "rtsp" else { return try Go2RTCSource(parsing: text) }
        // A plain rtsp:// address needs no helper-specific source type, but go2rtc serves it the same way.
        return Go2RTCSource(url: text, scheme: "rtsp", host: components.host ?? "", parameterNames: [])
    }

    /// Go's `url.Values.Encode()`: keys sorted, everything but `A-Za-z0-9-_.~` percent-encoded (space as `+`).
    static func encodedQuery(_ items: [String: String]) -> String {
        items.keys.sorted().map { "\($0)=\(escape(items[$0] ?? ""))" }.joined(separator: "&")
    }

    private static func escape(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                out.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: " "):
                out.append("+")
            default:
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }
}
