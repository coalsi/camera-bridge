// Loopback servers use Network.framework / PlatformApple, so these tests run on macOS only.
#if os(macOS)
import Crypto
import Foundation
import Network
import Synchronization
import PlatformApple
import Testing
@testable import BridgeSupport

/// Minimal loopback HTTP/1.1 server used only by these tests. One handler call per parsed request.
final class LoopbackHTTPServer: Sendable {
    typealias Handler = @Sendable (HTTPRequestHead, Data) -> (status: Int, headers: [(String, String)], body: Data)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackHTTPServer")
    let port: UInt16

    init(handler: @escaping Handler) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            let parser = ParserBox()
            connection.start(queue: queue)
            LoopbackHTTPServer.receive(on: connection, parser: parser, handler: handler)
        }
        self.listener = listener
        self.port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.withLock({ let r = $0; $0 = true; return !r }) { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.withLock({ let r = $0; $0 = true; return !r }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private final class ParserBox: @unchecked Sendable {   // only touched on the server queue
        var parser = HTTPRequestParser()
    }

    private static func receive(on connection: NWConnection, parser: ParserBox, handler: @escaping Handler) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                guard let requests = try? parser.parser.feed(data) else { connection.cancel(); return }
                for (head, body) in requests {
                    let (status, headers, responseBody) = handler(head, body)
                    let wire = HTTPSerializer.response(status: status, headers: HTTPHeaders(headers), body: responseBody)
                    connection.send(content: wire, completion: .contentProcessed { _ in })
                }
            }
            if isComplete || error != nil { connection.cancel(); return }
            receive(on: connection, parser: parser, handler: handler)
        }
    }
}

private func md5Hex(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

/// Server-side Digest verification written independently of `DigestAuthenticator`.
private func verifyDigest(_ header: String?, method: String, user: String, password: String, realm: String, nonce: String) -> Bool {
    guard let header, header.hasPrefix("Digest ") else { return false }
    let p = digestParameters(header)
    guard p["username"] == user, p["realm"] == realm, p["nonce"] == nonce, let uri = p["uri"], let response = p["response"],
          let nc = p["nc"], let cnonce = p["cnonce"], p["qop"] == "auth" else { return false }
    let ha1 = md5Hex("\(user):\(realm):\(password)")
    let ha2 = md5Hex("\(method):\(uri)")
    return response == md5Hex("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
}

/// qop=auth-int variant: HA2 = MD5(method:uri:MD5(entity-body)).
private func verifyDigestAuthInt(_ header: String?, method: String, body: Data, user: String, password: String, realm: String, nonce: String) -> Bool {
    guard let header, header.hasPrefix("Digest ") else { return false }
    let p = digestParameters(header)
    guard p["username"] == user, p["realm"] == realm, p["nonce"] == nonce, let uri = p["uri"], let response = p["response"],
          let nc = p["nc"], let cnonce = p["cnonce"], p["qop"] == "auth-int" else { return false }
    let bodyHash = Insecure.MD5.hash(data: body).map { String(format: "%02x", $0) }.joined()
    let ha1 = md5Hex("\(user):\(realm):\(password)")
    let ha2 = md5Hex("\(method):\(uri):\(bodyHash)")
    return response == md5Hex("\(ha1):\(nonce):\(nc):\(cnonce):auth-int:\(ha2)")
}

/// Loopback only (127.0.0.1).
@Suite(.timeLimit(.minutes(1))) struct AuthenticatingHTTPClientTests {
    private final class Counters: Sendable {
        private let count = Mutex(0)
        private let all = Mutex(0)
        func increment() { count.withLock { $0 += 1 } }
        func sawRequest() { all.withLock { $0 += 1 } }
        var unauthorized: Int { count.withLock { $0 } }
        var requests: Int { all.withLock { $0 } }
    }

    private func makeServer(counters: Counters = Counters()) async throws -> LoopbackHTTPServer {
        try await LoopbackHTTPServer { head, body in
            counters.sawRequest()
            switch head.path {
            case "/digest", "/stream":
                if verifyDigest(head.headers["Authorization"], method: head.method, user: "admin", password: "pa55", realm: "IP Camera", nonce: "n0nce") {
                    let body = head.path == "/stream" ? Data(repeating: 0x41, count: 100_000) : Data("ok-digest".utf8)
                    return (200, [("Content-Type", "text/plain")], body)
                }
                counters.increment()
                return (401, [("WWW-Authenticate", #"Digest realm="IP Camera", nonce="n0nce", qop="auth", opaque="o1""#)], Data())
            case "/authint":
                if verifyDigestAuthInt(head.headers["Authorization"], method: head.method, body: body, user: "admin", password: "pa55",
                                       realm: "IP Camera", nonce: "n1nce") {
                    return (200, [], Data("ok-auth-int".utf8))
                }
                counters.increment()
                return (401, [("WWW-Authenticate", #"Digest realm="IP Camera", nonce="n1nce", qop="auth-int""#)], Data())
            case "/basic":
                if head.headers["Authorization"] == BasicAuth.header(HTTPCredentials(username: "admin", password: "pa55")) {
                    return (200, [], Data("ok-basic".utf8))
                }
                return (401, [("WWW-Authenticate", #"Basic realm="cam""#)], Data())
            default:
                return (404, [], Data())
            }
        }
    }

    @Test func answersDigestChallengeAndReusesItPreemptively() async throws {
        let counters = Counters()
        let server = try await makeServer(counters: counters)
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: HTTPCredentials(username: "admin", password: "pa55"), timeout: .seconds(5))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/digest"))

        let (data, response) = try await client.data(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "ok-digest")
        #expect(counters.unauthorized == 1, "unauthorized=\(counters.unauthorized)")

        let (data2, response2) = try await client.data(for: URLRequest(url: url))
        #expect(response2.statusCode == 200)
        #expect(String(decoding: data2, as: UTF8.self) == "ok-digest")
        #expect(counters.unauthorized == 1, "second request should authenticate preemptively")
    }

    @Test func answersAuthIntOnlyChallengeWithRequestBody() async throws {
        let counters = Counters()
        let server = try await makeServer(counters: counters)
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: HTTPCredentials(username: "admin", password: "pa55"), timeout: .seconds(5))
        defer { client.invalidate() }
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(server.port)/authint")))
        request.httpMethod = "POST"
        request.httpBody = Data(#"[{"cmd":"GetDevInfo"}]"#.utf8)
        let (data, response) = try await client.data(for: request)
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "ok-auth-int")
        #expect(counters.unauthorized == 1)
    }

    @Test func wrongPasswordReturnsUnauthorizedAfterOneAttempt() async throws {
        let counters = Counters()
        let server = try await makeServer(counters: counters)
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: HTTPCredentials(username: "admin", password: "nope"), timeout: .seconds(5))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/digest"))
        let (_, response) = try await client.data(for: URLRequest(url: url))
        #expect(response.statusCode == 401)
        #expect(counters.requests == 2, "one anonymous request + exactly one authenticated attempt")
    }

    @Test func wrongPasswordStreamingReturnsUnauthorizedWithEmptyBody() async throws {
        let counters = Counters()
        let server = try await makeServer(counters: counters)
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: HTTPCredentials(username: "admin", password: "nope"), timeout: .seconds(5))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/stream"))
        let (response, body) = try await client.stream(for: URLRequest(url: url))
        #expect(response.statusCode == 401)
        var received = 0
        for try await chunk in body { received += chunk.count }
        #expect(received == 0)
        #expect(counters.requests == 2, "one anonymous request + exactly one authenticated attempt, no further logins")
    }

    @Test func noCredentialsReturnsUnauthorized() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(5))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/basic"))
        let (_, response) = try await client.data(for: URLRequest(url: url))
        #expect(response.statusCode == 401)
    }

    @Test func answersBasicChallenge() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: HTTPCredentials(username: "admin", password: "pa55"), timeout: .seconds(5))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/basic"))
        let (data, response) = try await client.data(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "ok-basic")
    }

    @Test func streamsBodyAfterDigestChallenge() async throws {
        let counters = Counters()
        let server = try await makeServer(counters: counters)
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: HTTPCredentials(username: "admin", password: "pa55"), timeout: .seconds(5))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/stream"))
        let (response, body) = try await client.stream(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        var received = Data()
        for try await chunk in body { received.append(chunk) }
        #expect(received == Data(repeating: 0x41, count: 100_000))
        #expect(counters.unauthorized == 1, "unauthorized=\(counters.unauthorized)")
    }

    @Test func streamWithoutCredentialsReturnsUnauthorizedResponse() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(5))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/basic"))
        let (response, body) = try await client.stream(for: URLRequest(url: url))
        #expect(response.statusCode == 401)
        for try await _ in body {}
    }
}

/// `stream(for:)` against a server that sends a chunked body piece by piece, released by the test.
@Suite(.timeLimit(.minutes(1))) struct AuthenticatingHTTPClientStreamingTests {
    @Test func deliversChunksAsTheyArrive() async throws {
        let server = try await ChunkedHTTPServer.start()
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/ISAPI/Event/notification/alertStream"))

        // URLSession reports the response together with the first body bytes, so queue those before connecting.
        server.send(Data("--boundary\r\nfirst".utf8))
        let (response, body) = try await client.stream(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/mixed") == true)
        var received = Data()
        var iterator = body.makeAsyncIterator()
        // The first chunk must arrive before the server has produced the second one.
        while received.count < 15, let chunk = try await iterator.next() { received.append(chunk) }
        #expect(String(decoding: received, as: UTF8.self) == "--boundary\r\nfirst")
        server.send(Data("second".utf8))
        server.send(Data("third".utf8))
        server.finish()
        while let chunk = try await iterator.next() { received.append(chunk) }
        #expect(String(decoding: received, as: UTF8.self) == "--boundary\r\nfirstsecondthird")
        #expect(server.requestPaths == ["/ISAPI/Event/notification/alertStream"])
    }

    @Test func answersDigestChallengeBeforeStreaming() async throws {
        let server = try await ChunkedHTTPServer.start(digest: (user: "admin", password: "pa55", realm: "IP Camera", nonce: "n0nce"))
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: HTTPCredentials(username: "admin", password: "pa55"), timeout: .seconds(10))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/flv"))
        server.send(Data("FLV".utf8))
        server.finish()
        let (response, body) = try await client.stream(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        var received = Data()
        for try await chunk in body { received.append(chunk) }
        #expect(received == Data("FLV".utf8))
        #expect(server.unauthorizedCount == 1)
    }

    @Test func droppingTheStreamCancelsTheRequest() async throws {
        let server = try await ChunkedHTTPServer.start()
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/stream"))
        server.send(Data("x".utf8))
        do {
            let (_, body) = try await client.stream(for: URLRequest(url: url))
            for try await _ in body { break }
        }
        // The client closes the connection; the server sees EOF or a reset instead of waiting forever.
        #expect(await server.waitForClientDisconnect(), "client never closed the connection")
    }
}

/// One-connection-per-request loopback HTTP/1.1 server (PlatformApple transport) that answers with
/// `Transfer-Encoding: chunked` and writes each chunk when the test calls `send`. Optional Digest auth (qop=auth).
private final class ChunkedHTTPServer: Sendable {
    private let listener: any TCPListener
    private let feed: AsyncStream<Data?>.Continuation
    private let feedStream: AsyncStream<Data?>
    private let state = Mutex<(paths: [String], unauthorized: Int, disconnected: Bool)>(([], 0, false))
    private let digest: (user: String, password: String, realm: String, nonce: String)?
    private let serverTask = Mutex<Task<Void, Never>?>(nil)

    var port: UInt16 { listener.port }
    var requestPaths: [String] { state.withLock { $0.paths } }
    var unauthorizedCount: Int { state.withLock { $0.unauthorized } }

    private init(listener: any TCPListener, digest: (user: String, password: String, realm: String, nonce: String)?) {
        self.listener = listener
        self.digest = digest
        (feedStream, feed) = AsyncStream.makeStream(of: Data?.self)
    }

    static func start(digest: (user: String, password: String, realm: String, nonce: String)? = nil) async throws -> ChunkedHTTPServer {
        let listener = try await AppleNetworkTransport().listen(port: 0, loopbackOnly: true)
        let server = ChunkedHTTPServer(listener: listener, digest: digest)
        server.serverTask.withLock { $0 = Task { await server.acceptLoop() } }
        return server
    }

    func send(_ chunk: Data) { feed.yield(chunk) }
    func finish() { feed.yield(nil) }

    func stop() {
        listener.close()
        feed.finish()
        serverTask.withLock { $0?.cancel() }
    }

    func waitForClientDisconnect() async -> Bool {
        for _ in 0..<100 {
            if state.withLock({ $0.disconnected }) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func acceptLoop() async {
        await withTaskGroup(of: Void.self) { group in
            for await connection in listener.connections {
                group.addTask { await self.serve(connection) }
            }
        }
    }

    private func serve(_ connection: any TCPConnection) async {
        defer { connection.close() }
        var parser = HTTPRequestParser()
        do {
            while true {
                guard let data = try await connection.receive(maximumLength: 65_536) else { return }
                for (head, _) in try parser.feed(data) {
                    if let digest, !verifyDigest(head.headers["Authorization"], method: head.method, user: digest.user,
                                                 password: digest.password, realm: digest.realm, nonce: digest.nonce) {
                        state.withLock { $0.unauthorized += 1 }
                        let challenge = #"Digest realm="\#(digest.realm)", nonce="\#(digest.nonce)", qop="auth""#
                        try await connection.send(HTTPSerializer.response(status: 401, headers: HTTPHeaders([("WWW-Authenticate", challenge)]),
                                                                          body: Data()))
                        continue
                    }
                    state.withLock { $0.paths.append(head.path) }
                    // Notice the client going away (EOF or reset) even while the body is still being streamed.
                    let watcher = Task {
                        do { while try await connection.receive(maximumLength: 65_536) != nil {} } catch {}
                        self.state.withLock { $0.disconnected = true }
                    }
                    try await streamBody(on: connection)
                    await watcher.value
                    return
                }
            }
        } catch {
            state.withLock { $0.disconnected = true }
        }
    }

    private func streamBody(on connection: any TCPConnection) async throws {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/mixed; boundary=boundary\r\nX-Content-Type-Options: nosniff\r\n"
            + "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        try await connection.send(Data(head.utf8))
        for await chunk in feedStream {
            guard let chunk else { break }
            var frame = Data((String(chunk.count, radix: 16) + "\r\n").utf8)
            frame.append(chunk)
            frame.append(Data("\r\n".utf8))
            try await connection.send(frame)
        }
        try await connection.send(Data("0\r\n\r\n".utf8))
    }
}

/// Review finding (W4 BridgeSupport, round 4): one `401` with `WWW-Authenticate: Basic` from a host that had used
/// Digest got the password (base64) in the retry, and the cached `.basic` sent it up front on every later request. A
/// host impersonating the camera (ARP or DHCP spoofing) needs nothing more. Once a host asked for Digest, the client
/// never answers Basic for it; a host that only ever asks for Basic still gets it.
@Suite(.timeLimit(.minutes(1))) struct AuthenticatingHTTPClientDowngradeTests {
    private enum Behaviour { case camera, rejectDigest, askForBasic }

    /// The camera (Digest, nonce `n0nce`) until the test switches it to an impersonator.
    private final class Impersonator: Sendable {
        let behaviour = Mutex(Behaviour.camera)
        let authorizations = Mutex<[String]>([])
        var sentBasic: Bool { authorizations.withLock { $0.contains { $0.lowercased().hasPrefix("basic") } } }
    }

    private func makeServer(_ impersonator: Impersonator) async throws -> LoopbackHTTPServer {
        try await LoopbackHTTPServer { head, _ in
            let authorization = head.headers["Authorization"]
            if let authorization { impersonator.authorizations.withLock { $0.append(authorization) } }
            switch impersonator.behaviour.withLock({ $0 }) {
            case .camera:
                if verifyDigest(authorization, method: head.method, user: "admin", password: "pa55", realm: "IP Camera", nonce: "n0nce") {
                    return (200, [], Data("ok".utf8))
                }
                return (401, [("WWW-Authenticate", #"Digest realm="IP Camera", nonce="n0nce", qop="auth""#)], Data())
            case .rejectDigest:
                return (401, [("WWW-Authenticate", #"Digest realm="IP Camera", nonce="evil", qop="auth""#)], Data())
            case .askForBasic:
                if authorization?.lowercased().hasPrefix("basic") == true { return (200, [], Data("captured".utf8)) }
                return (401, [("WWW-Authenticate", #"Basic realm="IP Camera""#)], Data())
            }
        }
    }

    @Test func basicChallengeAfterDigestIsNotAnswered() async throws {
        let impersonator = Impersonator()
        let server = try await makeServer(impersonator)
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: HTTPCredentials(username: "admin", password: "pa55"), timeout: .seconds(5))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/ISAPI/System/deviceInfo"))
        #expect(try await client.data(for: URLRequest(url: url)).1.statusCode == 200)
        #expect(try await client.data(for: URLRequest(url: url)).1.statusCode == 200)

        impersonator.behaviour.withLock { $0 = .askForBasic }
        #expect(try await client.data(for: URLRequest(url: url)).1.statusCode == 401)
        let (response, body) = try await client.stream(for: URLRequest(url: url))
        #expect(response.statusCode == 401)
        for try await _ in body {}
        #expect(try await client.data(for: URLRequest(url: url)).1.statusCode == 401)
        #expect(!impersonator.sentBasic, "\(impersonator.authorizations.withLock { $0 })")
    }

    /// A rejected Digest retry forgets the cached challenge; the host is still known to use Digest.
    @Test func rejectingDigestFirstDoesNotUnlockBasic() async throws {
        let impersonator = Impersonator()
        let server = try await makeServer(impersonator)
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: HTTPCredentials(username: "admin", password: "pa55"), timeout: .seconds(5))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/onvif/device_service"))
        #expect(try await client.data(for: URLRequest(url: url)).1.statusCode == 200)

        impersonator.behaviour.withLock { $0 = .rejectDigest }
        #expect(try await client.data(for: URLRequest(url: url)).1.statusCode == 401)
        impersonator.behaviour.withLock { $0 = .askForBasic }
        #expect(try await client.data(for: URLRequest(url: url)).1.statusCode == 401)
        #expect(try await client.data(for: URLRequest(url: url)).1.statusCode == 401)
        #expect(!impersonator.sentBasic, "\(impersonator.authorizations.withLock { $0 })")
    }

    /// The refusal is per host: the same client still answers Basic for a host that never asked for Digest.
    @Test func basicOnlyHostIsStillAnswered() async throws {
        let digestCamera = Impersonator()
        let digestServer = try await makeServer(digestCamera)
        defer { digestServer.stop() }
        let basicCamera = Impersonator()
        basicCamera.behaviour.withLock { $0 = .askForBasic }
        let basicServer = try await makeServer(basicCamera)
        defer { basicServer.stop() }
        let client = AuthenticatingHTTPClient(credentials: HTTPCredentials(username: "admin", password: "pa55"), timeout: .seconds(5))
        defer { client.invalidate() }
        let digestURL = try #require(URL(string: "http://127.0.0.1:\(digestServer.port)/a"))
        let basicURL = try #require(URL(string: "http://127.0.0.1:\(basicServer.port)/a"))
        #expect(try await client.data(for: URLRequest(url: digestURL)).1.statusCode == 200)
        let (data, response) = try await client.data(for: URLRequest(url: basicURL))
        #expect(response.statusCode == 200 && String(decoding: data, as: UTF8.self) == "captured")
        #expect(basicCamera.authorizations.withLock { $0 } == [BasicAuth.header(HTTPCredentials(username: "admin", password: "pa55"))])
    }
}
#endif
