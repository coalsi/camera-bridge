// Loopback-only mock camera HTTP server built on PlatformApple's transport, so it runs on macOS only.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import Synchronization
import TestSupport

struct MockRequest: Sendable {
    let head: HTTPRequestHead
    let body: Data
    var path: String { head.path }
    var method: String { head.method }
    var bodyText: String { String(decoding: body, as: UTF8.self) }
    func query(_ name: String) -> String? { head.queryItems.first { $0.name == name }?.value }
}

enum MockResponse: Sendable {
    /// A complete response with Content-Length.
    case full(status: Int, headers: [(String, String)], body: Data)
    /// Sends the head without Content-Length, then whatever `writer` writes; the connection closes when it returns.
    case stream(status: Int, headers: [(String, String)], writer: @Sendable (MockStreamWriter) async -> Void)
    /// Sends the head (Content-Length: 0), then hands every further received byte to `sink` (raw upload channel).
    case raw(status: Int, headers: [(String, String)], sink: @Sendable (Data) -> Void)

    static func xml(_ text: String, status: Int = 200) -> MockResponse {
        .full(status: status, headers: [("Content-Type", "application/xml; charset=utf-8")], body: Data(text.utf8))
    }

    static func soap(_ text: String, status: Int = 200) -> MockResponse {
        .full(status: status, headers: [("Content-Type", "application/soap+xml; charset=utf-8")], body: Data(text.utf8))
    }

    static func json(_ text: String, status: Int = 200) -> MockResponse {
        .full(status: status, headers: [("Content-Type", "application/json")], body: Data(text.utf8))
    }

    static func status(_ status: Int, headers: [(String, String)] = []) -> MockResponse {
        .full(status: status, headers: headers, body: Data())
    }

    static func digestChallenge(realm: String = "IP Camera", nonce: String = "4e6f6e6365") -> MockResponse {
        .full(status: 401, headers: [("WWW-Authenticate", #"Digest qop="auth", realm="\#(realm)", nonce="\#(nonce)", stale="FALSE""#)],
              body: Data("<html>401</html>".utf8))
    }
}

/// Writes to a streaming response connection.
final class MockStreamWriter: Sendable {
    private let connection: any TCPConnection
    init(connection: any TCPConnection) { self.connection = connection }
    @discardableResult
    func write(_ data: Data) async -> Bool {
        do { try await connection.send(data); return true } catch { return false }
    }
    func write(_ text: String) async { await write(Data(text.utf8)) }
}

/// Structural check of a Digest `Authorization` header (hash correctness is BridgeSupport's `DigestAuthenticator` tests).
func isDigestAuthorization(_ header: String?, username: String = "admin", realm: String = "IP Camera") -> Bool {
    guard let header, header.hasPrefix("Digest ") else { return false }
    return header.contains(#"username="\#(username)""#) && header.contains(#"realm="\#(realm)""#) && header.contains("response=")
}

/// Minimal HTTP/1.1 server on 127.0.0.1 (ephemeral port) for camera API fixtures. Keep-alive for full responses.
final class MockHTTPServer: Sendable {
    typealias Handler = @Sendable (MockRequest) async -> MockResponse

    let port: UInt16
    private let listener: any TCPListener
    private let handler: Handler
    private let state = Mutex<(requests: [MockRequest], connections: [any TCPConnection], connectionCount: Int)>(([], [], 0))
    private let acceptTask = Mutex<Task<Void, Never>?>(nil)

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var requests: [MockRequest] { state.withLock { $0.requests } }
    var connectionCount: Int { state.withLock { $0.connectionCount } }
    func requests(path: String) -> [MockRequest] { requests.filter { $0.path == path } }

    private init(listener: any TCPListener, handler: @escaping Handler) {
        self.listener = listener
        self.port = listener.port
        self.handler = handler
    }

    static func start(handler: @escaping Handler) async throws -> MockHTTPServer {
        let listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
        let server = MockHTTPServer(listener: listener, handler: handler)
        let task = Task { [server] in
            for await connection in listener.connections {
                server.state.withLock { $0.connections.append(connection); $0.connectionCount += 1 }
                Task { await server.serve(connection) }
            }
        }
        server.acceptTask.withLock { $0 = task }
        return server
    }

    func stop() {
        listener.close()
        acceptTask.withLock { $0?.cancel() }
        let connections = state.withLock { $0.connections }
        for connection in connections { connection.close() }
    }

    /// Closes every open connection (simulates the camera dropping streams).
    func dropConnections() {
        let connections = state.withLock { state in
            defer { state.connections.removeAll() }
            return state.connections
        }
        for connection in connections { connection.close() }
    }

    private func serve(_ connection: any TCPConnection) async {
        var parser = HTTPRequestParser(maxBodySize: 4 << 20)
        defer { connection.close() }
        while true {
            let data: Data?
            do { data = try await connection.receive(maximumLength: 65_536) } catch { return }
            guard let data else { return }
            let requests: [(head: HTTPRequestHead, body: Data)]
            do { requests = try parser.feed(data) } catch { return }
            for (head, body) in requests {
                let request = MockRequest(head: head, body: body)
                state.withLock { $0.requests.append(request) }
                switch await handler(request) {
                case .full(let status, let headers, let body):
                    let wire = HTTPSerializer.response(status: status, headers: HTTPHeaders(headers), body: body)
                    do { try await connection.send(wire) } catch { return }
                    if head.headers["Connection"]?.lowercased() == "close" { return }
                case .stream(let status, let headers, let writer):
                    var text = "HTTP/1.1 \(status) \(HTTPSerializer.reasonPhrase(for: status))\r\n"
                    for (name, value) in headers { text += "\(name): \(value)\r\n" }
                    text += "Connection: close\r\n\r\n"
                    do { try await connection.send(Data(text.utf8)) } catch { return }
                    await writer(MockStreamWriter(connection: connection))
                    return
                case .raw(let status, let headers, let sink):
                    var all = headers
                    all.append(("Content-Length", "0"))
                    let wire = HTTPSerializer.response(status: status, headers: HTTPHeaders(all), body: Data())
                    do { try await connection.send(wire) } catch { return }
                    while true {
                        guard let chunk = try? await connection.receive(maximumLength: 65_536) else { return }
                        sink(chunk)
                    }
                }
            }
        }
    }
}
#endif
