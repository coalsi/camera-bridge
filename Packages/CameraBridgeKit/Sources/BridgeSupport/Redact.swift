import Foundation

/// Removes secrets from strings before they are logged or shown in UI.
public enum Redact {
    /// A parameter is secret when its lowercased name ends with one of these (`user_password`, `adminPwd`, …).
    static let secretSuffixes = ["password", "passwd", "pwd", "pass", "pw", "token", "secret", "apikey", "api_key"]
    /// … or equals one of these.
    static let secretNames: Set<String> = ["auth", "authorization", "session", "sessionid"]

    static func isSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        return secretNames.contains(lower) || secretSuffixes.contains { lower.hasSuffix($0) }
    }

    /// Strips `user:password@` and masks password-like query items (`name=***`; names are compared percent-decoded),
    /// plus secret assignments nested inside other values (`?x=a?password=…`), in the fragment, and in the path, where
    /// some cameras take credentials (Xiongmai/XMEye `/user=admin&password=…`, `/snapshot.cgi;pwd=…`; a path value ends
    /// at the next `/` too). Scheme, host and the rest of the path are kept. The query is rewritten as text rather than
    /// through `URLComponents`' validating `percentEncoded*` setters, which trap on unusual characters.
    public static func url(_ url: URL) -> String {
        let stripped = url.removingUserInfo
        guard let components = URLComponents(url: stripped, resolvingAgainstBaseURL: false), components.user == nil,
              components.password == nil else {
            return string(url.absoluteString)   // not rebuilt without its user info: mask the text
        }
        let text = stripped.absoluteString
        // With the user info removed, the first `#` starts the fragment and the first `?` before it starts the
        // query (RFC 3986 §3).
        let queryEnd = text.firstIndex(of: "#") ?? text.endIndex
        guard let queryStart = text[..<queryEnd].firstIndex(of: "?") else {
            return maskAssignments(String(text[..<queryEnd]), inPath: true) + maskAssignments(String(text[queryEnd...]))
        }
        let afterMark = text.index(after: queryStart)
        let masked = text[afterMark..<queryEnd].split(separator: "&", omittingEmptySubsequences: false).map { segment in
            guard let equals = segment.firstIndex(of: "="), isSecret(URLQuery.percentDecode(segment[..<equals])) else {
                return String(segment)
            }
            return "\(segment[..<equals])=***"
        }
        return maskAssignments(String(text[..<queryStart]), inPath: true) + "?"
            + maskAssignments(masked.joined(separator: "&") + text[queryEnd...])
    }

    /// Masks secret-named assignments (`password=…`, `adminPwd=…`, `access_token=…`, also when nested inside another
    /// value), JSON members (`"password": "…"`) and `scheme://user:pass@` user info in free text. User info runs to
    /// the last `@` before the next `/` or line break (`\v`), so passwords containing `@` or spaces do not leak (at
    /// the cost of over-masking a path-less URL followed by an e-mail address on the same line).
    ///
    /// Linear in the length of `s` (camera-supplied text can be megabytes long; see `maskUserInfo`).
    public static func string(_ s: String) -> String {
        var result = maskUserInfo(s)
        result = maskAssignments(result)
        let json = /("([A-Za-z0-9_.\-]+)"\s*:\s*)"(?:[^"\\]|\\.)*"/
        result = result.replacing(json) { match in
            isSecret(String(match.2)) ? "\(match.1)\"***\"" : String(match.0)
        }
        return result
    }

    /// Replaces the user info of every `scheme://user:pass@` with `***`: what `/([A-Za-z][A-Za-z0-9+.\-]*:\/\/)[^\/\v]*@/`
    /// matches (leftmost scheme letter, user info to the last `@` before the next `/` or line break, the next match
    /// starting after the previous one), found by a scan instead. Swift Regex backtracks: that pattern rescanned every
    /// run of scheme characters without `://` from each start position, quadratic time (hours for 1 MiB of letters).
    /// Here each character is visited a bounded number of times: the scheme run before a `://` is walked back once
    /// (runs end at `:`, so they are disjoint), and the user info forward once (it ends at the next `/`, so at the
    /// latest at the next `://`).
    static func maskUserInfo(_ text: String) -> String {
        guard text.utf8.count > 3, text.contains("://") else { return text }
        let characters = Array(text)
        var out = ""
        var copied = 0   // characters[..<copied] are in `out`; a scheme starts no earlier (the regex resumes there)
        var index = 0    // the candidate `:` of a `://`
        while index + 2 < characters.count {
            guard characters[index] == ":", characters[index + 1] == "/", characters[index + 2] == "/" else {
                index += 1
                continue
            }
            var runStart = index
            while runStart > copied, isSchemeCharacter(characters[runStart - 1]) { runStart -= 1 }
            let schemeStart = (runStart..<index).first { characters[$0].isASCII && characters[$0].isLetter }
            let userInfoStart = index + 3
            var end = userInfoStart
            var lastAt: Int?
            while end < characters.count, characters[end] != "/", !characters[end].isNewline {
                if characters[end] == "@" { lastAt = end }
                end += 1
            }
            guard schemeStart != nil, let lastAt else {
                index += 1
                continue
            }
            out.append(contentsOf: characters[copied..<userInfoStart])
            out += "***@"
            copied = lastAt + 1
            index = copied
        }
        if copied == 0 { return text }
        out.append(contentsOf: characters[copied...])
        return out
    }

    /// The most characters of camera-supplied text that `cameraText` keeps.
    package static let cameraTextLimit = 200

    /// Camera-supplied text (an SDP codec name, a SOAP fault, a transport) made fit for an error message or a log line:
    /// every character with a control, format, line- or paragraph-separator scalar (line breaks, tabs, escapes, bidi
    /// overrides) becomes a space, and text longer than `limit` characters (at least 1) is cut to `limit` characters, the
    /// last one `…`. Reads at most `limit` + 1 characters, so a camera's megabytes cost nothing here or in `string`.
    package static func cameraText(_ text: some StringProtocol, limit: Int = cameraTextLimit) -> String {
        let limit = max(1, limit)
        var characters = text.prefix(limit + 1).map { character -> Character in
            character.unicodeScalars.contains { [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }
                ? " " : character
        }
        if characters.count > limit { characters.replaceSubrange((limit - 1)..., with: CollectionOfOne("…")) }
        return String(characters)
    }

    private static func isSchemeCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "+" || c == "." || c == "-")
    }

    /// Replaces the value of every `name=value` whose name (the run of `[A-Za-z0-9_.-]` right before `=`) is secret
    /// with `***`. A quoted value (`'…'` or `"…"`) runs to its closing quote (or line end); any other value to the next `&`,
    /// whitespace, quote, `,` or `;` (`inPath`: or `/`, which separates path segments). Values of non-secret names are
    /// scanned too, so `x=a?password=…` is caught.
    static func maskAssignments(_ text: String, inPath: Bool = false) -> String {
        let characters = Array(text)
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var nameStart = 0   // start of the run of name characters ending at `index`
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "=", nameStart < index, isSecret(String(characters[nameStart..<index])) {
                index += 1
                if index < characters.count, characters[index] == "\"" || characters[index] == "'" {
                    let quote = characters[index]
                    out += "=\(quote)***"
                    index += 1
                    while index < characters.count, characters[index] != quote, !characters[index].isNewline { index += 1 }
                    if index < characters.count, characters[index] == quote { out.append(quote); index += 1 }
                } else {
                    out += "=***"
                    while index < characters.count, !isValueDelimiter(characters[index]), !(inPath && characters[index] == "/") { index += 1 }
                }
                nameStart = index
                continue
            }
            out.append(character)
            index += 1
            if !isNameCharacter(character) { nameStart = index }
        }
        return out
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "." || c == "-")
    }

    private static func isValueDelimiter(_ c: Character) -> Bool {
        c == "&" || c == "\"" || c == "'" || c == "," || c == ";" || c.isWhitespace
    }
}
