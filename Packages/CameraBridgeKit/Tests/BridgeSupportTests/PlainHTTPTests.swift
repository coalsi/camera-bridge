// Loopback servers use the platform transport (Network.framework on macOS, POSIX sockets on Linux).
#if os(macOS) || os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import BridgeSupport

/// Runs a test with plain `http://` requests on `PlainHTTP` where that is what the daemon does — on Linux — and on a Mac with
/// `CB_TEST_PLAIN_HTTP=1`, so the client's suites cover the route each platform takes.
struct PlainHTTPRouteTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        #if os(Linux)
        let plain = true
        #else
        let plain = ProcessInfo.processInfo.environment["CB_TEST_PLAIN_HTTP"] == "1"
        #endif
        guard plain, testCase != nil else { return try await function() }
        try await AuthenticatingHTTPClient.$plainHTTPRoute.withValue(PlatformNetworkTransport()) { try await function() }
    }
}

extension Trait where Self == PlainHTTPRouteTrait {
    /// The daemon's route for plain HTTP on Linux (and on a Mac with `CB_TEST_PLAIN_HTTP=1`).
    static var plainHTTPRoute: Self { Self() }
}

/// Loopback server that reads each request (head and Content-Length body, kept in `requests`) and answers it with `script`; the
/// connection closes when the script returns, or at `stop()`.
private final class ScriptedHTTPServer: Sendable {
    typealias Script = @Sendable (_ connection: any TCPConnection, _ request: String) async throws -> Void
    private final class Recorder: Sendable {
        let requests = Mutex<[String]>([])
        let tasks = Mutex<[Task<Void, Never>]>([])
    }
    private let listener: any TCPListener
    private let recorder = Recorder()
    private let acceptor: Task<Void, Never>
    let port: UInt16

    var requests: [String] { recorder.requests.withLock { $0 } }

    init(_ script: @escaping Script) async throws {
        let listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
        self.listener = listener
        port = listener.port
        acceptor = Task { [recorder] in
            for await connection in listener.connections {
                let task = Task {
                    defer { connection.close() }
                    guard let request = try? await Self.readRequest(connection) else { return }
                    recorder.requests.withLock { $0.append(request) }
                    try? await script(connection, request)
                }
                recorder.tasks.withLock { $0.append(task) }
            }
        }
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func stop() {
        listener.close()
        acceptor.cancel()
        for task in recorder.tasks.withLock({ $0 }) { task.cancel() }
    }

    private static func readRequest(_ connection: any TCPConnection) async throws -> String {
        var buffer = Data()
        while true {
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                while buffer.count - end.upperBound < length {
                    guard let more = try await connection.receive(maximumLength: 65_536) else { break }
                    buffer.append(more)
                }
                return String(decoding: buffer, as: UTF8.self)
            }
            guard let more = try await connection.receive(maximumLength: 65_536) else { throw TransportError.closed }
            buffer.append(more)
        }
    }
}

private func send(_ text: String, on connection: any TCPConnection) async throws {
    try await connection.send(Data(text.utf8))
}

/// Waits until `stop()` (the connection stays open).
private func holdOpen() async {
    try? await Task.sleep(for: .seconds(50))
}

private func withPlainRoute<T: Sendable>(_ body: () async throws -> T) async throws -> T {
    try await AuthenticatingHTTPClient.$plainHTTPRoute.withValue(PlatformNetworkTransport()) { try await body() }
}

private func text(_ body: AsyncThrowingStream<Data, any Error>) async throws -> String {
    var data = Data()
    for try await chunk in body { data.append(chunk) }
    return String(decoding: data, as: UTF8.self)
}

@Suite(.timeLimit(.minutes(1))) struct PlainHTTPTests {
    @Test func aBodyEndsAtItsContentLengthWithoutWaitingForTheCameraToHangUp() async throws {
        let server = try await ScriptedHTTPServer { connection, _ in
            try await send("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", on: connection)
            await holdOpen()
        }
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        let started = ContinuousClock.now
        let (data, response) = try await withPlainRoute { try await client.data(for: URLRequest(url: server.url("/a"))) }
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "hello")
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aChunkedBodyIsDecodedAcrossReads() async throws {
        let server = try await ScriptedHTTPServer { connection, _ in
            try await send("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel", on: connection)
            try await Task.sleep(for: .milliseconds(50))
            try await send("lo\r\n6;x=1\r\n world\r\n0\r\n\r\n", on: connection)
            await holdOpen()
        }
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        let (data, _) = try await withPlainRoute { try await client.data(for: URLRequest(url: server.url("/c"))) }
        #expect(String(decoding: data, as: UTF8.self) == "hello world")
    }

    @Test func aBodyWithoutLengthEndsWhenTheCameraHangsUp() async throws {
        let server = try await ScriptedHTTPServer { connection, _ in
            try await send("HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nall of it", on: connection)
        }
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        let (response, body) = try await withPlainRoute { try await client.stream(for: URLRequest(url: server.url("/u"))) }
        #expect(response.value(forHTTPHeaderField: "content-type") == "text/plain")
        #expect(try await text(body) == "all of it")
    }

    @Test func anInterimAnswerIsSkippedAndBareLineFeedsAreRead() async throws {
        let server = try await ScriptedHTTPServer { connection, _ in
            try await send("HTTP/1.1 100 Continue\n\nHTTP/1.1 200 OK\nX-Folded: one\n two\nContent-Length: 2\n\nok", on: connection)
        }
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        let (data, response) = try await withPlainRoute { try await client.data(for: URLRequest(url: server.url("/i"))) }
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "X-Folded") == "one two")
        #expect(data == Data("ok".utf8))
    }

    @Test func theRequestCarriesItsTargetHostAndBodyAndClosesTheConnection() async throws {
        let server = try await ScriptedHTTPServer { connection, _ in
            try await send("HTTP/1.1 204 No Content\r\n\r\n", on: connection)
        }
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        var request = URLRequest(url: server.url("/onvif/device_service?a=b%20c"))
        request.httpMethod = "POST"
        request.httpBody = Data("<soap/>".utf8)
        request.setValue("application/soap+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await withPlainRoute { try await client.data(for: request) }
        #expect(response.statusCode == 204)
        #expect(data.isEmpty)
        let sent = try #require(server.requests.first)
        let lines = sent.components(separatedBy: "\r\n")
        #expect(lines.first == "POST /onvif/device_service?a=b%20c HTTP/1.1")
        #expect(lines.contains("Host: 127.0.0.1:\(server.port)"))
        #expect(lines.contains("Connection: close"))
        #expect(lines.contains("Content-Length: 7"))
        #expect(lines.contains("Content-Type: application/soap+xml"))
        #expect(!sent.lowercased().contains("accept-encoding"), "the answer must come uncompressed")
        #expect(sent.hasSuffix("\r\n\r\n<soap/>"))
    }

    @Test func aStreamThatGoesQuietTimesOutButASlowReaderDoesNot() async throws {
        let server = try await ScriptedHTTPServer { connection, _ in
            try await send("HTTP/1.1 200 OK\r\n\r\nfirst", on: connection)
            await holdOpen()
        }
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(1))
        let (_, body) = try await withPlainRoute { try await client.stream(for: URLRequest(url: server.url("/quiet"))) }
        // Nothing waits for bytes while the reader is busy: what arrived meanwhile is still read.
        try await Task.sleep(for: .milliseconds(2_500))
        var iterator = body.makeAsyncIterator()
        #expect(try await iterator.next() == Data("first".utf8))
        let started = ContinuousClock.now
        await #expect(throws: URLError.self) { _ = try await iterator.next() }
        let waited = ContinuousClock.now - started
        #expect(waited >= .milliseconds(900) && waited < .seconds(5), "waited \(waited)")
    }

    @Test func anAnswerCutShortFails() async throws {
        let server = try await ScriptedHTTPServer { connection, _ in
            try await send("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc", on: connection)
        }
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        await #expect(throws: TransportError.closed) {
            _ = try await withPlainRoute { try await client.data(for: URLRequest(url: server.url("/short"))) }
        }
    }

    @Test(arguments: ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nabc\r\n", "HTTP/1.1 200 OK\r\nContent-Length: 1, 2\r\n\r\nab",
                      "SSH-2.0-OpenSSH\r\n\r\n"])
    func aMalformedAnswerFails(_ answer: String) async throws {
        let server = try await ScriptedHTTPServer { connection, _ in try await send(answer, on: connection) }
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        await #expect(throws: HTTPClientError.notHTTPResponse) {
            _ = try await withPlainRoute { try await client.data(for: URLRequest(url: server.url("/bad"))) }
        }
    }

    @Test func aHeadLongerThanTheLimitFails() async throws {
        let server = try await ScriptedHTTPServer { connection, _ in
            try await send("HTTP/1.1 200 OK\r\n" + String(repeating: "X-Filler: 0123456789abcdef\r\n", count: 3_000), on: connection)
            await holdOpen()
        }
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        await #expect(throws: HTTPClientError.notHTTPResponse) {
            _ = try await withPlainRoute { try await client.stream(for: URLRequest(url: server.url("/huge"))) }
        }
    }

    @Test func aRedirectIsFollowedAsURLSessionWould() async throws {
        let target = try await ScriptedHTTPServer { connection, _ in
            try await send("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nhere", on: connection)
        }
        defer { target.stop() }
        let origin = try await ScriptedHTTPServer { connection, request in
            let status = request.hasPrefix("POST /see-other") ? "303 See Other" : "302 Found"
            try await send("HTTP/1.1 \(status)\r\nLocation: http://127.0.0.1:\(target.port)/there\r\nContent-Length: 0\r\n\r\n", on: connection)
        }
        defer { origin.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        var request = URLRequest(url: origin.url("/see-other"))
        request.httpMethod = "POST"
        request.httpBody = Data("form".utf8)
        request.setValue("Token secret", forHTTPHeaderField: "Authorization")
        let (data, response) = try await withPlainRoute { try await client.data(for: request) }
        #expect(response.statusCode == 200)
        #expect(response.url == target.url("/there"))
        #expect(data == Data("here".utf8))
        let followed = try #require(target.requests.first)
        #expect(followed.hasPrefix("GET /there HTTP/1.1\r\n"), "a 303 after a POST becomes a GET")
        #expect(!followed.contains("Token secret"), "the Authorization header stays with its own host")
        #expect(!followed.contains("form"))
    }

    @Test func aClientThatFollowsNoRedirectReturnsTheRedirect() async throws {
        let server = try await ScriptedHTTPServer { connection, _ in
            try await send("HTTP/1.1 302 Found\r\nLocation: http://192.0.2.1/elsewhere\r\nContent-Length: 0\r\n\r\n", on: connection)
        }
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10), allowSelfSignedTLS: false, maximumBodySize: 1 << 20,
                                              downgradeGuard: BasicDowngradeGuard(), followsRedirects: false)
        let (_, response) = try await withPlainRoute { try await client.data(for: URLRequest(url: server.url("/r"))) }
        #expect(response.statusCode == 302)
        #expect(response.value(forHTTPHeaderField: "Location") == "http://192.0.2.1/elsewhere")
    }

    @Test func endlessRedirectsStop() async throws {
        let server = try await ScriptedHTTPServer { connection, _ in
            try await send("HTTP/1.1 302 Found\r\nLocation: /again\r\nContent-Length: 0\r\n\r\n", on: connection)
        }
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        await #expect(throws: URLError.self) {
            _ = try await withPlainRoute { try await client.data(for: URLRequest(url: server.url("/again"))) }
        }
        #expect(server.requests.count == AuthenticatingHTTPClient.maximumRedirects + 1)
    }

    @Test func invalidatingTheClientClosesItsStreamsAndRefusesNewRequests() async throws {
        let server = try await ScriptedHTTPServer { connection, _ in
            try await send("HTTP/1.1 200 OK\r\n\r\nx", on: connection)
            await holdOpen()
        }
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        let (_, body) = try await withPlainRoute { try await client.stream(for: URLRequest(url: server.url("/s"))) }
        var iterator = body.makeAsyncIterator()
        #expect(try await iterator.next() == Data("x".utf8))
        client.invalidate()
        await #expect(throws: TransportError.closed) { _ = try await iterator.next() }
        await #expect(throws: TransportError.closed) {
            _ = try await withPlainRoute { try await client.data(for: URLRequest(url: server.url("/again"))) }
        }
    }

    @Test func cancellingTheReaderEndsTheStreamAndClosesTheConnection() async throws {
        let closed = Flag()
        let server = try await ScriptedHTTPServer { connection, _ in
            try await send("HTTP/1.1 200 OK\r\n\r\nx", on: connection)
            while let _ = try await connection.receive(maximumLength: 1024) {}
            closed.set()
        }
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        let (_, body) = try await withPlainRoute { try await client.stream(for: URLRequest(url: server.url("/s"))) }
        let reader = Task {
            var count = 0
            for try await _ in body { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(200))
        reader.cancel()
        #expect(try await reader.value == 1, "the stream ends quietly")
        #expect(await eventuallyTrue { closed.isSet })
    }

    @Test func httpsAndAddressesWithAUserNameStayOnURLSession() {
        #expect(PlainHTTP.handles(URLRequest(url: URL(string: "http://192.0.2.1/x")!)))
        #expect(!PlainHTTP.handles(URLRequest(url: URL(string: "https://192.0.2.1/x")!)))
        #expect(!PlainHTTP.handles(URLRequest(url: URL(string: "http://user:pw@192.0.2.1/x")!)))
    }

    @Test func multipleChallengesGiveTheDigestOne() {
        let headers = HTTPHeaders([("WWW-Authenticate", #"Basic realm="cam""#), ("WWW-Authenticate", #"Digest realm="cam", nonce="n""#),
                                   ("Set-Cookie", "a=1"), ("set-cookie", "b=2")])
        let fields = PlainHTTP.headerFields(headers)
        #expect(fields["WWW-Authenticate"] == #"Digest realm="cam", nonce="n""#)
        #expect(fields["Set-Cookie"] == "a=1, b=2")
    }
}

private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

private func eventuallyTrue(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}
#endif
