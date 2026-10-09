import Foundation

/// Ordered HTTP header list with case-insensitive lookup.
public struct HTTPHeaders: Sendable, Equatable, Sequence {
    private var storage: [(name: String, value: String)]

    public init(_ pairs: [(String, String)] = []) {
        storage = pairs.map { (name: $0.0, value: $0.1) }
    }

    /// First value for `name` (case-insensitive). Setting replaces every existing value; `nil` removes.
    public subscript(name: String) -> String? {
        get {
            let key = name.lowercased()
            return storage.first { $0.name.lowercased() == key }?.value
        }
        set {
            let key = name.lowercased()
            if let newValue {
                if let index = storage.firstIndex(where: { $0.name.lowercased() == key }) {
                    storage[index].value = newValue
                    var i = storage.index(after: index)
                    while i < storage.endIndex {
                        if storage[i].name.lowercased() == key { storage.remove(at: i) } else { i += 1 }
                    }
                } else {
                    storage.append((name: name, value: newValue))
                }
            } else {
                storage.removeAll { $0.name.lowercased() == key }
            }
        }
    }

    public mutating func add(_ name: String, _ value: String) {
        storage.append((name: name, value: value))
    }

    /// Every value for `name`, in order.
    public func values(for name: String) -> [String] {
        let key = name.lowercased()
        return storage.filter { $0.name.lowercased() == key }.map(\.value)
    }

    public func makeIterator() -> IndexingIterator<[(name: String, value: String)]> {
        storage.makeIterator()
    }

    public static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        lhs.storage.count == rhs.storage.count
            && zip(lhs.storage, rhs.storage).allSatisfy { $0.name.lowercased() == $1.name.lowercased() && $0.value == $1.value }
    }
}

public struct HTTPRequestHead: Sendable, Equatable {
    public var method: String
    public var target: String
    public var version: String
    public var headers: HTTPHeaders

    public init(method: String, target: String, version: String = "HTTP/1.1", headers: HTTPHeaders = HTTPHeaders()) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
    }

    /// Request target without the query string or a (non-standard) `#fragment`; not percent-decoded.
    public var path: String {
        if let end = target.firstIndex(where: { $0 == "?" || $0 == "#" }) { return String(target[..<end]) }
        return target
    }

    /// Decoded query items (empty when there is no query). Never traps on malformed input: see `URLQuery.items`.
    public var queryItems: [URLQueryItem] {
        let beforeFragment = target[..<(target.firstIndex(of: "#") ?? target.endIndex)]
        guard let q = beforeFragment.firstIndex(of: "?") else { return [] }
        return URLQuery.items(beforeFragment[beforeFragment.index(after: q)...])
    }
}

/// Query-string parsing that never hands untrusted text to Foundation's validating `percentEncoded*` setters
/// (they `fatalError` on characters such as `%zz`, `"`, `<` or `#`).
enum URLQuery {
    /// Splits on `&` and at the first `=`, like `URLComponents.queryItems`: empty segments become items with an empty
    /// name, a segment without `=` has a nil value, `+` is not treated as a space. Names and values are decoded with
    /// `percentDecode`.
    static func items(_ query: Substring) -> [URLQueryItem] {
        guard !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: false).map { segment in
            guard let equals = segment.firstIndex(of: "=") else { return URLQueryItem(name: percentDecode(segment), value: nil) }
            return URLQueryItem(name: percentDecode(segment[..<equals]), value: percentDecode(segment[segment.index(after: equals)...]))
        }
    }

    /// Lenient percent-decoding (WHATWG URL style): `%XX` with two hex digits becomes that byte; any other `%` is kept
    /// literally; byte sequences that are not UTF-8 decode to U+FFFD.
    static func percentDecode(_ text: Substring) -> String {
        guard text.contains("%") else { return String(text) }
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count, let high = hexValue(bytes[i + 1]), let low = hexValue(bytes[i + 2]) {
                out.append(high << 4 | low)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

public struct HTTPResponseHead: Sendable, Equatable {
    public var version: String
    public var status: Int
    public var reason: String
    public var headers: HTTPHeaders

    public init(version: String = "HTTP/1.1", status: Int, reason: String, headers: HTTPHeaders = HTTPHeaders()) {
        self.version = version
        self.status = status
        self.reason = reason
        self.headers = headers
    }
}

public enum HTTPParseError: Error, Equatable, Sendable {
    case malformedRequestLine
    case malformedStatusLine
    case malformedHeader
    case headTooLarge
    case bodyTooLarge
    case invalidContentLength
    case unsupportedTransferEncoding
}

/// Shared head/body framing for request and response parsers (Content-Length bodies only), generic over the parsed
/// head.
///
/// Incremental, so a peer that trickles a message costs work in proportion to its bytes, not to its bytes times the
/// reads (W4 review round 4: the webhook re-searched and re-parsed a 64 KiB head on every one-byte read before it
/// checked any token): the search for the head's end resumes where the previous one stopped, a head is parsed once
/// and kept while its body arrives, and consumed messages are dropped from the buffer once per append rather than by
/// copying the rest of the buffer per message.
struct HTTPFraming<Head: Sendable>: Sendable {
    /// Turns a head's start line and headers into `Head` (throwing on a malformed start line) and says whether the
    /// message may have a body.
    typealias HeadParser = (String, HTTPHeaders) throws(HTTPParseError) -> (head: Head, bodyAllowed: Bool)

    static var defaultMaxHeadSize: Int { 64 * 1024 }

    private struct Pending: Sendable {
        var head: Head
        /// The body's offset from the start of the message, and its length.
        var bodyOffset: Int
        var bodyLength: Int
    }

    private var buffer = Data()
    /// Bytes at the front of `buffer` that belong to messages already returned (dropped on the next append).
    private var consumed = 0
    /// How far from the current message's start the search for the head's end got (it resumes there).
    private var searched = 0
    /// The parsed head of the message whose body is still arriving.
    private var pending: Pending?
    let maxBodySize: Int
    let maxHeadSize: Int
    /// Header lines a head may have (the start line not counted); more → `headTooLarge`.
    let maxHeaderCount: Int
    /// Search positions and head bytes examined so far (tests: the work stays linear in the input).
    private(set) var bytesExamined = 0

    init(maxBodySize: Int, maxHeadSize: Int = defaultMaxHeadSize, maxHeaderCount: Int = .max) {
        self.maxBodySize = maxBodySize
        self.maxHeadSize = maxHeadSize
        self.maxHeaderCount = maxHeaderCount
    }

    /// The head of the message whose body is still arriving; nil when there is none.
    var pendingHead: Head? { pending?.head }

    mutating func append(_ data: Data) {
        if consumed > 0 {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + consumed))
            consumed = 0
        }
        buffer.append(data)
    }

    /// Extracts the next complete message. Returns nil when more data is needed.
    mutating func next(_ parseHead: HeadParser) throws(HTTPParseError) -> (head: Head, body: Data)? {
        if pending == nil {
            guard let headLength = headLength() else {
                if buffer.count - consumed > maxHeadSize { throw .headTooLarge }
                return nil
            }
            if headLength > maxHeadSize { throw .headTooLarge }
            pending = try parse(headLength: headLength, parseHead)
        }
        guard let message = pending else { return nil }
        let messageStart = buffer.startIndex + consumed
        let bodyStart = messageStart + message.bodyOffset
        guard buffer.endIndex - bodyStart >= message.bodyLength else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + message.bodyLength)])
        consumed += message.bodyOffset + message.bodyLength
        pending = nil
        searched = 0
        return (message.head, body)
    }

    /// The length of the current message's head (up to its CRLFCRLF), searching only what earlier calls have not.
    private mutating func headLength() -> Int? {
        let base = consumed
        let from = searched
        let found = buffer.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int? in
            var index = base + from
            while index + 3 < bytes.count {
                if bytes[index + 3] == 0x0A, bytes[index + 2] == 0x0D, bytes[index + 1] == 0x0A, bytes[index] == 0x0D {
                    return index - base
                }
                index += 1
            }
            return nil
        }
        let available = buffer.count - base
        bytesExamined += max(0, (found ?? (available - 3)) - from)
        if found == nil { searched = max(0, available - 3) }
        return found
    }

    private mutating func parse(headLength: Int, _ parseHead: HeadParser) throws(HTTPParseError) -> Pending {
        bytesExamined += headLength
        let start = buffer.startIndex + consumed
        let headText = String(decoding: buffer[start..<(start + headLength)], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let startLine = lines.removeFirst()
        if lines.count > maxHeaderCount { throw .headTooLarge }
        var headers = HTTPHeaders()
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  let first = line.first, first != " ", first != "\t" else { throw .malformedHeader }
            let name = String(line[..<colon])
            guard !name.contains(" ") else { throw .malformedHeader }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.add(name, value)
        }
        if headers["Transfer-Encoding"] != nil { throw .unsupportedTransferEncoding }
        var bodyLength = 0
        let lengths = Set(headers.values(for: "Content-Length").map { $0.trimmingCharacters(in: .whitespaces) })
        if !lengths.isEmpty {
            guard lengths.count == 1, let text = lengths.first, !text.isEmpty, text.allSatisfy(\.isASCII),
                  text.allSatisfy(\.isNumber), let length = Int(text) else { throw .invalidContentLength }
            bodyLength = length
        }
        let (head, bodyAllowed) = try parseHead(startLine, headers)
        if !bodyAllowed { bodyLength = 0 }
        if bodyLength > maxBodySize { throw .bodyTooLarge }
        return Pending(head: head, bodyOffset: headLength + 4, bodyLength: bodyLength)
    }
}

/// Incremental HTTP/1.1 request parser (pipelining supported; Content-Length bodies only).
public struct HTTPRequestParser: Sendable {
    private var framing: HTTPFraming<HTTPRequestHead>

    public init(maxBodySize: Int = 1 << 20) {
        framing = HTTPFraming(maxBodySize: maxBodySize)
    }

    /// With a head limit of `maxHeadSize` bytes and at most `maxHeaderCount` header lines (more → `headTooLarge`), for a
    /// server any peer reaches before it authenticates (the webhook).
    package init(maxBodySize: Int, maxHeadSize: Int, maxHeaderCount: Int) {
        framing = HTTPFraming(maxBodySize: maxBodySize, maxHeadSize: maxHeadSize, maxHeaderCount: maxHeaderCount)
    }

    /// The head of the request whose body is still arriving (nil when none is), so a server can refuse the request
    /// (a wrong token) before reading its body.
    package var pendingHead: HTTPRequestHead? { framing.pendingHead }

    /// Search positions and head bytes examined so far (tests).
    var bytesExamined: Int { framing.bytesExamined }

    /// Appends `data` and returns every request completed by it. Throws on malformed or oversize input;
    /// the connection should then be closed.
    public mutating func feed(_ data: Data) throws -> [(head: HTTPRequestHead, body: Data)] {
        framing.append(data)
        var out: [(head: HTTPRequestHead, body: Data)] = []
        while let message = try framing.next(Self.head) { out.append(message) }
        return out
    }

    private static func head(_ startLine: String, _ headers: HTTPHeaders) throws(HTTPParseError) -> (head: HTTPRequestHead, bodyAllowed: Bool) {
        let parts = startLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, parts[2].contains("/"),
              parts[0].allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" }) else {
            throw .malformedRequestLine
        }
        return (HTTPRequestHead(method: String(parts[0]), target: String(parts[1]), version: String(parts[2]), headers: headers), true)
    }
}

/// Incremental HTTP/1.1 (and HAP `EVENT/1.0`) response parser. Bodies require Content-Length; 1xx/204/304 have none.
public struct HTTPResponseParser: Sendable {
    private var framing: HTTPFraming<HTTPResponseHead>

    public init(maxBodySize: Int = 8 << 20) {
        framing = HTTPFraming(maxBodySize: maxBodySize)
    }

    public mutating func feed(_ data: Data) throws -> [(head: HTTPResponseHead, body: Data)] {
        framing.append(data)
        var out: [(head: HTTPResponseHead, body: Data)] = []
        while let message = try framing.next(Self.head) { out.append(message) }
        return out
    }

    private static func head(_ startLine: String, _ headers: HTTPHeaders) throws(HTTPParseError) -> (head: HTTPResponseHead, bodyAllowed: Bool) {
        let parts = startLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].contains("/"), let status = Int(parts[1]), (100...999).contains(status) else {
            throw .malformedStatusLine
        }
        let reason = parts.count == 3 ? String(parts[2]) : ""
        let bodyAllowed = !(status < 200 || status == 204 || status == 304)
        return (HTTPResponseHead(version: String(parts[0]), status: status, reason: reason, headers: headers), bodyAllowed)
    }
}

public enum HTTPSerializer {
    /// Standard reason phrases (plus HAP's 470).
    public static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 207: "Multi-Status"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 413: "Payload Too Large"
        case 422: "Unprocessable Entity"
        case 429: "Too Many Requests"
        case 470: "Connection Authorization Required"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Status \(status)"
        }
    }

    /// Serializes a response. Adds `Content-Length` unless present or the status forbids a body (1xx, 204, 304).
    public static func response(status: Int, reason: String? = nil, headers: HTTPHeaders, body: Data, version: String = "HTTP/1.1") -> Data {
        var headers = headers
        let bodyless = status < 200 || status == 204 || status == 304
        if !bodyless && headers["Content-Length"] == nil { headers.add("Content-Length", String(body.count)) }
        var text = "\(version) \(status) \(reason ?? reasonPhrase(for: status))\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        if !bodyless { data.append(body) }
        return data
    }

    /// Serializes a request. Adds `Content-Length` when there is a body and none is present.
    public static func request(_ head: HTTPRequestHead, body: Data) -> Data {
        var headers = head.headers
        if !body.isEmpty && headers["Content-Length"] == nil { headers.add("Content-Length", String(body.count)) }
        var text = "\(head.method) \(head.target) \(head.version)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}
