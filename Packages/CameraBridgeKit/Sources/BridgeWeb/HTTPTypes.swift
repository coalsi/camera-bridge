import BridgeSupport
import Foundation

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
/// (server-sent events, multipart JPEG) and the connection closes after it.
public struct HTTPResponse: Sendable {
    public enum Body: Sendable {
        case data(Data)
        case stream(@Sendable (ResponseStream) async throws -> Void)
    }

    public var status: Int
    public var headers: HTTPHeaders
    public var body: Body

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

    public static func stream(status: Int = 200, contentType: String, headers: HTTPHeaders = HTTPHeaders(),
                              _ body: @escaping @Sendable (ResponseStream) async throws -> Void) -> HTTPResponse {
        var headers = headers
        headers["Content-Type"] = contentType
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
