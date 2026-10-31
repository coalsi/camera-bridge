import BridgeSupport
import Foundation
import Synchronization

/// One request, as the server hands it to the application: parsed, size-limited, with the peer's address.
public struct HTTPRequest: Sendable {
    public var method: String
    /// The request target as sent (path and query, not decoded).
    public var target: String
    public var version: String
    public var headers: HTTPHeaders
    public var body: Data
    /// IP literal of the peer (no port).
    public var remoteAddress: String
    /// The request came through the box's TLS front over HTTPS (`SecureAddressRules.normalized`); false for a plain request.
    public var isSecure = false

    public init(method: String, target: String, version: String = "HTTP/1.1", headers: HTTPHeaders = HTTPHeaders(), body: Data = Data(),
                remoteAddress: String = "127.0.0.1") {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
        self.body = body
        self.remoteAddress = remoteAddress
    }

    private var head: HTTPRequestHead { HTTPRequestHead(method: method, target: target, version: version, headers: headers) }

    /// The target without its query string, not decoded.
    public var path: String { head.path }

    public var query: [URLQueryItem] { head.queryItems }

    public func queryValue(_ name: String) -> String? {
        query.first { $0.name == name }?.value
    }

    /// The cookies of the `Cookie` headers (first value wins for a repeated name).
    public var cookies: [String: String] {
        var result: [String: String] = [:]
        for header in headers.values(for: "Cookie") {
            for pair in header.split(separator: ";") {
                let trimmed = pair.trimmingCharacters(in: .whitespaces)
                guard let equals = trimmed.firstIndex(of: "="), equals != trimmed.startIndex else { continue }
                let name = String(trimmed[..<equals])
                if result[name] == nil { result[name] = String(trimmed[trimmed.index(after: equals)...]) }
            }
        }
        return result
    }

    /// The value of the `Host` header without its port ("camera-bridge.local", "192.0.2.10", "2001:db8::1" without brackets).
    public var hostName: String? {
        guard let host = headers["Host"] else { return nil }
        return Self.splitHost(host).name
    }

    static func splitHost(_ value: String) -> (name: String, port: String?) {
        let host = value.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return (host, nil) }
            let name = String(host[host.index(after: host.startIndex)..<close])
            let rest = host[host.index(after: close)...]
            return (name, rest.hasPrefix(":") ? String(rest.dropFirst()) : nil)
        }
        if let colon = host.lastIndex(of: ":"), host.filter({ $0 == ":" }).count == 1 {
            return (String(host[..<colon]), String(host[host.index(after: colon)...]))
        }
        return (host, nil)
    }

    /// Whether the client asked for server-sent events.
    public var acceptsEventStream: Bool {
        (headers["Accept"] ?? "").lowercased().contains("text/event-stream")
    }
}

/// What a handler answers. A buffered body is sent with `Content-Length`; a stream is sent chunked until its closure returns
/// (server-sent events, multipart JPEG) and the connection closes after it. A stream that throws ends without the last chunk, so a
/// download that failed half way is not taken for a finished one.
public struct HTTPResponse: Sendable {
    public enum Body: Sendable {
        case data(Data)
        case stream(@Sendable (ResponseStream) async throws -> Void)
    }

    public var status: Int
    public var headers: HTTPHeaders
    public var body: Body
    /// Runs when the server does not run a stream's body after all: a HEAD request, a head that could not be sent, a connection that
    /// ended first. A handler that took something for the body (a live or event slot, an archive slot) gives it back here as well as in
    /// the body's own `defer`, through one `ReleaseOnce`, so it is given back exactly once whichever way the answer goes.
    public var onDiscard: (@Sendable () -> Void)?

    public init(status: Int, headers: HTTPHeaders = HTTPHeaders(), body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public init(status: Int, contentType: String, data: Data, headers: HTTPHeaders = HTTPHeaders()) {
        var headers = headers
        headers["Content-Type"] = contentType
        self.init(status: status, headers: headers, body: .data(data))
    }

    public static func text(_ text: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, contentType: contentType, data: Data(text.utf8))
    }

    public static func empty(_ status: Int = 204) -> HTTPResponse {
        HTTPResponse(status: status)
    }

    /// A streaming answer. With `contentLength` (a clip, whose size is known before the first byte) it is sent with that
    /// `Content-Length` instead of chunked: the body must write exactly that many bytes. A write past it throws, and a body that ends
    /// short leaves the download short, which the browser sees as failed.
    public static func stream(status: Int = 200, contentType: String, headers: HTTPHeaders = HTTPHeaders(), contentLength: Int64? = nil,
                              _ body: @escaping @Sendable (ResponseStream) async throws -> Void) -> HTTPResponse {
        var headers = headers
        headers["Content-Type"] = contentType
        headers["Content-Length"] = contentLength.map { String(max(0, $0)) }
        return HTTPResponse(status: status, headers: headers, body: .stream(body))
    }

    /// The buffered body, nil for a stream.
    public var bodyData: Data? {
        if case .data(let data) = body { return data }
        return nil
    }
}

/// The connection a streaming response writes to. Each `write` is one chunk; it throws once the client has gone (or stopped
/// reading for `HTTPServer.Limits.writeTimeout`), which ends the response.
public final class ResponseStream: Sendable {
    private let sink: @Sendable (Data) async throws -> Void

    init(sink: @escaping @Sendable (Data) async throws -> Void) {
        self.sink = sink
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await sink(data)
    }

    public func write(_ text: String) async throws {
        try await write(Data(text.utf8))
    }
}

/// Something to give back once (a stream slot), whichever of a stream's body and its `HTTPResponse.onDiscard` gets there first.
public final class ReleaseOnce: Sendable {
    private let action: Mutex<(@Sendable () -> Void)?>

    public init(_ action: @escaping @Sendable () -> Void) {
        self.action = Mutex(action)
    }

    public func callAsFunction() {
        let run = action.withLock { action -> (@Sendable () -> Void)? in
            defer { action = nil }
            return action
        }
        run?()
    }
}
