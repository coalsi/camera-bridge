import Foundation

/// The credentials some cameras take in their stream URL's query (`?user=admin&password=…`, a password hash `&hash=…`, a `token=`) or
/// path (XMEye `/user=admin&password=…&channel=1&stream=0.sdp`, `;pwd=…`): an ONVIF `GetStreamUri` answer can carry them, and so can
/// an address the person typed. They are secrets like the camera's password, so
/// `config.json`, the engine's cameras, screens and logs only ever see the URL without them (`URL.removingStreamCredentials`), the
/// platform secret store keeps the URL with them (BridgeEngine's `CredentialStore`, `camera.<UUID>.stream-urls`), and an RTSP session
/// puts them back into its request line, and nowhere else (`RTSPConfiguration.streamCredentials`, `connectionURL(for:)`).
///
/// User info (`user:password@`) is not part of this: it is the camera's username and password, which have their own fields.
public struct StreamURLCredentials: Sendable, Hashable {
    /// The main and sub stream URLs as the camera takes them, with the credentials in their query or path (never with user info).
    public var main: URL?
    public var sub: URL?

    public static let none = StreamURLCredentials()

    public init(main: URL? = nil, sub: URL? = nil) {
        self.main = main
        self.sub = sub
    }

    public var isEmpty: Bool { main == nil && sub == nil }

    /// The URL to connect to for `url`: the stored stream URL whose address without credentials is `url`'s, else `url` itself (also when
    /// `url` carries credentials of its own, from a camera's `GetStreamUri` answer, say). Stored credentials never go to another
    /// address than the one they were saved with.
    public func connectionURL(for url: URL) -> URL {
        guard !url.hasStreamCredentials else { return url }
        let address = url.removingStreamCredentials.absoluteString
        return [main, sub].lazy.compactMap { $0 }.first { $0.removingStreamCredentials.absoluteString == address } ?? url
    }

    /// Whether a query item name (compared lowercased, percent-decoded) is a credential or stands in for one: every name `Redact` masks
    /// (`password`, `pwd`, `passwd`, `pass`, `token`, `secret`, `auth`, `session`, …; a name ending in `hash` too: `hash`, `pwdHash`), and
    /// the user names cameras take next to them (`user`, `username`, `usr`, and `loginuse` / `loginpas` of older CGI cameras).
    public static func isCredential(_ name: String) -> Bool {
        Redact.isSecret(name) || userNames.contains(name.lowercased())
    }

    static let userNames: Set<String> = ["user", "username", "usr", "loginuse", "loginpas"]
}

extension URL {
    /// The URL without user info and without the credentials in its query and path (`StreamURLCredentials.isCredential` names):
    /// - query items with such a name go; the others keep their order and spelling, and a query left empty loses its `?`;
    /// - in the path, `name=value` assignments with such a name go from each segment (`pathParameters`); the rest of the segment keeps
    ///   its order and separators, and a segment left empty goes with its `/` (a path left empty is `/`).
    ///
    /// Scheme, host, port and the fragment are kept. Rewritten as text (like `Redact.url`), not through `URLComponents`' validating
    /// `percentEncoded*` setters, which trap on unusual characters.
    public var removingStreamCredentials: URL {
        let stripped = removingUserInfo
        let text = stripped.absoluteString
        let parts = Self.parts(of: text)
        let newPath = Self.removingCredentials(fromPath: text[parts.path])
        let newQuery = parts.query.flatMap { Self.removingCredentials(fromQuery: text[$0]) }   // nil: no query, or nothing removed
        guard newPath != nil || newQuery != nil else { return stripped }
        let head = String(text[..<parts.path.lowerBound])
        let query = if let newQuery { newQuery.isEmpty ? "" : "?" + newQuery } else { parts.query.map { "?" + text[$0] } ?? "" }
        let fragment = text[(parts.query?.upperBound ?? parts.path.upperBound)...]
        let rebuilt = head + (newPath ?? String(text[parts.path])) + query + fragment
        // Removing parts keeps a valid URL valid; should it not, the path and query go rather than the credentials staying.
        return URL(string: rebuilt) ?? URL(string: head + "/" + fragment) ?? stripped
    }

    /// Whether the query or the path carries credentials (`removingStreamCredentials` removes something besides user info).
    public var hasStreamCredentials: Bool {
        let text = removingUserInfo.absoluteString
        let parts = Self.parts(of: text)
        if let query = parts.query, Self.queryItems(text[query]).contains(where: Self.isCredentialItem) { return true }
        return text[parts.path].split(separator: "/", omittingEmptySubsequences: false)
            .contains { Self.pathParameters($0).contains { Self.isCredentialAssignment($0.piece) } }
    }

    /// Where the path and the query of `text` (without user info) are: the path runs from the first `/` after `scheme://authority`
    /// to the first `?` or `#` (empty when there is none, also for a URL without `://`); the query, without its `?`, to the first `#`.
    private static func parts(of text: String) -> (path: Range<String.Index>, query: Range<String.Index>?) {
        let fragmentStart = text.firstIndex(of: "#") ?? text.endIndex
        let queryMark = text[..<fragmentStart].firstIndex(of: "?")
        let pathEnd = queryMark ?? fragmentStart
        var pathStart = pathEnd
        if let scheme = text[..<pathEnd].range(of: "://") {
            pathStart = text[scheme.upperBound..<pathEnd].firstIndex(of: "/") ?? pathEnd
        }
        return (pathStart..<pathEnd, queryMark.map { text.index(after: $0)..<fragmentStart })
    }

    private static func queryItems(_ query: Substring) -> [Substring] {
        query.split(separator: "&", omittingEmptySubsequences: false)
    }

    /// The query without its credential items (joined by `&`, "" when none is left), nil when it has none.
    private static func removingCredentials(fromQuery query: Substring) -> String? {
        let items = queryItems(query)
        let kept = items.filter { !isCredentialItem($0) }
        return kept.count == items.count ? nil : kept.joined(separator: "&")
    }

    /// The path without its credential assignments, nil when it has none.
    private static func removingCredentials(fromPath path: Substring) -> String? {
        var changed = false
        var segments: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            let parameters = pathParameters(segment)
            let kept = parameters.filter { !isCredentialAssignment($0.piece) }
            guard kept.count != parameters.count else {
                segments.append(String(segment))
                continue
            }
            changed = true
            let rebuilt = kept.enumerated().map { $0.offset == 0 ? $0.element.piece : $0.element.separator + $0.element.piece }.joined()
            if !rebuilt.isEmpty { segments.append(rebuilt) }   // a segment that was only credentials goes with its `/`
        }
        guard changed else { return nil }
        let rebuilt = segments.joined(separator: "/")
        return rebuilt.isEmpty && path.hasPrefix("/") ? "/" : rebuilt
    }

    /// One path segment's parameters, each with the separator before it ("" for the first): split at `&` and `;` when the segment has
    /// either; else, in a segment that starts with an assignment, at each `_` that starts the next one (XMEye's
    /// `user=admin_password=…_channel=1_stream=0.sdp`; a value with an `_` that does not start an assignment stays whole, so a
    /// password `my_pass` goes with its `password=`). Anything else is one parameter, which is a credential only when it is one
    /// assignment with a credential name (`token=…`); plain path words (`h264Preview_01_main`) never are.
    static func pathParameters(_ segment: Substring) -> [(separator: Substring, piece: Substring)] {
        let separators: (Character) -> Bool
        let cut: (Substring.Index) -> Bool
        if segment.contains(where: { $0 == "&" || $0 == ";" }) {
            separators = { $0 == "&" || $0 == ";" }
            cut = { _ in true }
        } else if startsWithAssignment(segment[...]) {
            separators = { $0 == "_" }
            cut = { startsWithAssignment(segment[segment.index(after: $0)...]) }
        } else {
            return [(segment[segment.startIndex..<segment.startIndex], segment)]
        }
        var parameters: [(separator: Substring, piece: Substring)] = []
        var separator = segment[segment.startIndex..<segment.startIndex]
        var start = segment.startIndex
        var index = segment.startIndex
        while index < segment.endIndex {
            if separators(segment[index]), cut(index) {
                parameters.append((separator, segment[start..<index]))
                separator = segment[index...index]
                start = segment.index(after: index)
            }
            index = segment.index(after: index)
        }
        parameters.append((separator, segment[start..<segment.endIndex]))
        return parameters
    }

    /// `name=` at the start, the name an ASCII letter followed by letters, digits, `.` or `-` (no `_`: there it separates). Reads only
    /// the name, so scanning every `_` of a segment stays linear.
    private static func startsWithAssignment(_ text: Substring) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter else { return false }
        for character in text.dropFirst() {
            if character == "=" { return true }
            guard character.isASCII, character.isLetter || character.isNumber || character == "." || character == "-" else { return false }
        }
        return false
    }

    /// `name=value` or a bare `name` in the query whose name is a credential.
    private static func isCredentialItem(_ item: Substring) -> Bool {
        let name = item.firstIndex(of: "=").map { item[..<$0] } ?? item
        return !name.isEmpty && StreamURLCredentials.isCredential(URLQuery.percentDecode(name))
    }

    /// A path parameter `name=value` whose name is a credential (a bare word in a path is not one).
    private static func isCredentialAssignment(_ piece: Substring) -> Bool {
        guard let equals = piece.firstIndex(of: "=") else { return false }
        let name = piece[..<equals]
        return !name.isEmpty && StreamURLCredentials.isCredential(URLQuery.percentDecode(name))
    }
}
