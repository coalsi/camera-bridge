import BridgeSupport
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import BridgeWeb

/// A client on the in-memory transport: writes raw bytes, reads answers (Content-Length, chunked, or until the server closes).
final class RawClient: Sendable {
    struct Reply {
        var status: Int
        var headers: HTTPHeaders
        var body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    let connection: FakeTCPConnection
    private let buffer = Mutex(Data())

    init(connection: FakeTCPConnection) {
        self.connection = connection
    }

    func send(_ text: String) async throws {
        try await connection.send(Data(text.utf8))
    }

    func send(_ data: Data) async throws {
        try await connection.send(data)
    }

    /// Reads more bytes into the buffer; false at EOF.
    private func fill() async throws -> Bool {
        guard let data = try await connection.receive(maximumLength: 64 * 1024) else { return false }
        buffer.withLock { $0.append(data) }
        return true
    }

    private func takeLine() async throws -> String? {
        while true {
            if let line = buffer.withLock({ buffer -> String? in
                guard let range = buffer.range(of: Data("\r\n".utf8)) else { return nil }
                let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }) { return line }
            guard try await fill() else { return nil }
        }
    }

    private func take(_ count: Int) async throws -> Data? {
        while buffer.withLock({ $0.count }) < count {
            guard try await fill() else { return nil }
        }
        return buffer.withLock { buffer in
            let out = Data(buffer.prefix(count))
            buffer.removeFirst(count)
            return out
        }
    }

    /// The next answer; nil when the connection ended first. `hasBody` false for HEAD.
    func reply(hasBody: Bool = true) async throws -> Reply? {
        guard let start = try await takeLine() else { return nil }
        let parts = start.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var headers = HTTPHeaders()
        while let line = try await takeLine(), !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.add(String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        var body = Data()
        if status < 200 || status == 204 || status == 304 || !hasBody {
            return Reply(status: status, headers: headers, body: body)
        }
        if headers["Transfer-Encoding"]?.lowercased() == "chunked" {
            while let sizeLine = try await takeLine(), let size = Int(sizeLine, radix: 16) {
                if size == 0 {
                    _ = try await takeLine()
                    break
                }
                body.append(try await take(size) ?? Data())
                _ = try await takeLine()
            }
        } else if let length = headers["Content-Length"].flatMap({ Int($0) }) {
            body = try await take(length) ?? Data()
        } else {
            while try await fill() {}
            body = buffer.withLock { buffer in
                defer { buffer.removeAll() }
                return buffer
            }
        }
        return Reply(status: status, headers: headers, body: body)
    }

    /// One chunk of a chunked answer whose head has been read; nil at the end.
    func chunk() async throws -> Data? {
        guard let sizeLine = try await takeLine(), let size = Int(sizeLine, radix: 16) else { return nil }
        if size == 0 {
            _ = try await takeLine()   // the empty line that ends the body
            return nil
        }
        let data = try await take(size)
        _ = try await takeLine()
        return data
    }

    /// The head of a streaming answer (chunks follow).
    func head() async throws -> Reply? {
        guard let start = try await takeLine() else { return nil }
        let parts = start.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var headers = HTTPHeaders()
        while let line = try await takeLine(), !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.add(String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return Reply(status: status, headers: headers, body: Data())
    }

    /// Whether the server closed its end (EOF after what was buffered).
    func atEnd() async throws -> Bool {
        if buffer.withLock({ !$0.isEmpty }) { return false }
        return try await !fill()
    }

    func close() {
        connection.close()
    }
}

@Suite(.timeLimit(.minutes(1))) struct HTTPServerTests {
    private final class Rig: Sendable {
        let transport = FakeNetworkTransport()
        let server: HTTPServer
        let seen = Box<[HTTPRequest]>([])
        let serverEnds = Box<[FakeTCPConnection]>([])

        init(limits: HTTPServer.Limits = HTTPServer.Limits(), handler: (@Sendable (HTTPRequest) async -> HTTPResponse)? = nil) {
            let seen = seen
            server = HTTPServer(port: 0, transport: transport, limits: limits) { request in
                seen.update { $0.append(request) }
                if let handler { return await handler(request) }
                return .text("hello \(request.path)")
            }
        }

        func connect(from address: String = "192.0.2.50") async throws -> RawClient {
            if transport.listeners.isEmpty { try await server.start() }
            let (client, serverEnd) = FakeTCPConnection.pair(remoteAddress: address)
            serverEnds.update { $0.append(serverEnd) }
            transport.listeners[0].accept(serverEnd)
            return RawClient(connection: client)
        }

    }

    // MARK: Basics

    @Test func answersARequestWithContentLength() async throws {
        let rig = Rig()
        let client = try await rig.connect()
        try await client.send("GET /one?x=1 HTTP/1.1\r\nHost: camera-bridge.local\r\n\r\n")
        let reply = try #require(try await client.reply())
        #expect(reply.status == 200)
        #expect(reply.text == "hello /one")
        #expect(reply.headers["Content-Length"] == "10")
        #expect(reply.headers["Date"]?.hasSuffix("GMT") == true)
        let request = try #require(rig.seen.value.first)
        #expect(request.queryValue("x") == "1")
        #expect(request.remoteAddress == "192.0.2.50")
        await rig.server.stop()
    }

    @Test func keepAliveServesSeveralRequestsOnOneConnection() async throws {
        let rig = Rig()
        let client = try await rig.connect()
        for index in 0..<3 {
            try await client.send("GET /r\(index) HTTP/1.1\r\nHost: a\r\n\r\n")
            let reply = try #require(try await client.reply())
            #expect(reply.text == "hello /r\(index)")
        }
        #expect(await rig.server.connectionCount == 1)
        await rig.server.stop()
    }

    @Test func pipelinedRequestsAreAnsweredInOrder() async throws {
        let rig = Rig()
        let client = try await rig.connect()
        try await client.send("GET /a HTTP/1.1\r\nHost: a\r\n\r\nGET /b HTTP/1.1\r\nHost: a\r\n\r\nGET /c HTTP/1.1\r\nHost: a\r\n\r\n")
        for name in ["a", "b", "c"] {
            #expect(try await client.reply()?.text == "hello /\(name)")
        }
        await rig.server.stop()
    }

    @Test func aRequestSplitIntoTinyPiecesIsStillOneRequest() async throws {
        let rig = Rig()
        let client = try await rig.connect()
        let text = "POST /split HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhello"
        for character in text {
            try await client.send(String(character))
        }
        #expect(try await client.reply()?.text == "hello /split")
        #expect(rig.seen.value.first?.body == Data("hello".utf8))
        await rig.server.stop()
    }

    @Test func connectionCloseAndHTTP10CloseAfterTheAnswer() async throws {
        let rig = Rig()
        let first = try await rig.connect()
        try await first.send("GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n")
        let reply = try #require(try await first.reply())
        #expect(reply.headers["Connection"] == "close")
        #expect(try await first.atEnd())
        let second = try await rig.connect()
        try await second.send("GET / HTTP/1.0\r\n\r\n")
        _ = try await second.reply()
        #expect(try await second.atEnd())
        await rig.server.stop()
    }

    @Test func headSendsHeadersWithoutABody() async throws {
        let rig = Rig()
        let client = try await rig.connect()
        try await client.send("HEAD /head HTTP/1.1\r\nHost: a\r\n\r\n")
        let reply = try #require(try await client.reply(hasBody: false))
        #expect(reply.status == 200)
        #expect(reply.headers["Content-Length"] == "11")
        // The connection stays usable: the next answer is not preceded by stray body bytes.
        try await client.send("GET /after HTTP/1.1\r\nHost: a\r\n\r\n")
        #expect(try await client.reply()?.text == "hello /after")
        await rig.server.stop()
    }

    // MARK: Malformed and oversized input

    @Test func garbageIsAnsweredWith400AndClosed() async throws {
        let rig = Rig()
        let client = try await rig.connect()
        try await client.send("this is not http\r\n\r\n")
        let reply = try #require(try await client.reply())
        #expect(reply.status == 400)
        #expect(try await client.atEnd())
        #expect(rig.seen.value.isEmpty)
        await rig.server.stop()
    }

    @Test func aBadContentLengthIsRefused() async throws {
        let rig = Rig()
        let client = try await rig.connect()
        try await client.send("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: abc\r\n\r\n")
        #expect(try await client.reply()?.status == 400)
        await rig.server.stop()
    }

    @Test func conflictingContentLengthsAreRefused() async throws {
        let rig = Rig()
        let client = try await rig.connect()
        try await client.send("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabcd")
        #expect(try await client.reply()?.status == 400)
        #expect(rig.seen.value.isEmpty)
        await rig.server.stop()
    }

    @Test func anOversizedBodyIsRefusedBeforeItIsRead() async throws {
        var limits = HTTPServer.Limits()
        limits.maxBodySize = 100
        let rig = Rig(limits: limits)
        let client = try await rig.connect()
        try await client.send("POST /big HTTP/1.1\r\nHost: a\r\nContent-Length: 1000000\r\n\r\n")   // no body is sent at all
        let reply = try #require(try await client.reply())
        #expect(reply.status == 413)
        #expect(rig.seen.value.isEmpty)
        await rig.server.stop()
    }

    @Test func anOversizedHeadIsRefused() async throws {
        var limits = HTTPServer.Limits()
        limits.maxHeadSize = 512
        let rig = Rig(limits: limits)
        let client = try await rig.connect()
        try await client.send("GET / HTTP/1.1\r\nHost: a\r\nX-Pad: \(String(repeating: "x", count: 2_000))\r\n\r\n")
        #expect(try await client.reply()?.status == 431)
        await rig.server.stop()
    }

    @Test func tooManyHeadersAreRefused() async throws {
        var limits = HTTPServer.Limits()
        limits.maxHeaderCount = 10
        let rig = Rig(limits: limits)
        let client = try await rig.connect()
        let headers = (0..<30).map { "X-\($0): 1\r\n" }.joined()
        try await client.send("GET / HTTP/1.1\r\nHost: a\r\n\(headers)\r\n")
        #expect(try await client.reply()?.status == 431)
        await rig.server.stop()
    }

    @Test func aHeadThatNeverEndsIsRefusedWithoutBuffering() async throws {
        var limits = HTTPServer.Limits()
        limits.maxHeadSize = 1_024
        let rig = Rig(limits: limits)
        let client = try await rig.connect()
        try await client.send("GET / HTTP/1.1\r\n")
        for _ in 0..<5 { try await client.send(String(repeating: "a", count: 400)) }
        #expect(try await client.reply()?.status == 431)
        await rig.server.stop()
    }

    @Test func aChunkedRequestBodyIsNotImplemented() async throws {
        let rig = Rig()
        let client = try await rig.connect()
        try await client.send("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
        #expect(try await client.reply()?.status == 501)
        await rig.server.stop()
    }

    @Test func binaryNoiseDoesNotHangOrCrash() async throws {
        let rig = Rig()
        let client = try await rig.connect()
        try await client.send(Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }) + Data("\r\n\r\n".utf8))
        #expect(try await client.reply()?.status == 400)
        await rig.server.stop()
    }

    // MARK: Time limits

    @Test func aSlowRequestIsAnsweredWith408() async throws {
        var limits = HTTPServer.Limits()
        limits.requestTimeout = .milliseconds(150)
        let rig = Rig(limits: limits)
        let client = try await rig.connect()
        try await client.send("GET / HTTP/1.1\r\nHost: a\r\n")   // never finishes
        let reply = try #require(try await client.reply())
        #expect(reply.status == 408)
        await rig.server.stop()
    }

    @Test func aConnectionThatSendsNothingIsDropped() async throws {
        var limits = HTTPServer.Limits()
        limits.firstByteTimeout = .milliseconds(100)
        let rig = Rig(limits: limits)
        let client = try await rig.connect()
        #expect(try await client.atEnd())
        #expect(await eventually { await rig.server.connectionCount == 0 })
        await rig.server.stop()
    }

    @Test func anIdleKeepAliveConnectionIsDropped() async throws {
        var limits = HTTPServer.Limits()
        limits.idleTimeout = .milliseconds(100)
        let rig = Rig(limits: limits)
        let client = try await rig.connect()
        try await client.send("GET / HTTP/1.1\r\nHost: a\r\n\r\n")
        _ = try await client.reply()
        #expect(try await client.atEnd())
        await rig.server.stop()
    }

    // MARK: Streaming

    @Test func aStreamIsSentChunkedAndEndsTheConnection() async throws {
        let rig = Rig { _ in
            .stream(contentType: "text/event-stream") { stream in
                try await stream.write("event: one\n\n")
                try await stream.write("event: two\n\n")
            }
        }
        let client = try await rig.connect()
        try await client.send("GET /events HTTP/1.1\r\nHost: a\r\n\r\n")
        let head = try #require(try await client.head())
        #expect(head.status == 200)
        #expect(head.headers["Transfer-Encoding"] == "chunked")
        #expect(head.headers["Connection"] == "close")
        #expect(head.headers["Content-Length"] == nil)
        #expect(try await client.chunk() == Data("event: one\n\n".utf8))
        #expect(try await client.chunk() == Data("event: two\n\n".utf8))
        #expect(try await client.chunk() == nil)
        #expect(try await client.atEnd())
        await rig.server.stop()
    }

    @Test func aStreamEndsWhenTheClientLeaves() async throws {
        let started = Box(false)
        let cancelled = Box(false)
        let rig = Rig { _ in
            .stream(contentType: "text/event-stream") { stream in
                started.set(true)
                try await stream.write("hello\n\n")
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    cancelled.set(true)
                }
            }
        }
        let client = try await rig.connect()
        try await client.send("GET /events HTTP/1.1\r\nHost: a\r\n\r\n")
        _ = try await client.head()
        #expect(try await client.chunk() != nil)
        #expect(started.value)
        client.close()
        #expect(await eventually { cancelled.value }, "the streaming task is cancelled when the client closes")
        #expect(await eventually { await rig.server.connectionCount == 0 })
        await rig.server.stop()
    }

    @Test func aHTTP10ClientGetsAStreamWithoutChunking() async throws {
        let rig = Rig { _ in .stream(contentType: "text/plain") { try await $0.write("raw bytes") } }
        let client = try await rig.connect()
        try await client.send("GET / HTTP/1.0\r\n\r\n")
        let reply = try #require(try await client.reply())
        #expect(reply.headers["Transfer-Encoding"] == nil)
        #expect(reply.text == "raw bytes")
        await rig.server.stop()
    }

    @Test func aClientThatStopsReadingIsDropped() async throws {
        var limits = HTTPServer.Limits()
        limits.writeTimeout = .milliseconds(150)
        let ended = Box(false)
        let rig = Rig(limits: limits) { _ in
            .stream(contentType: "text/plain") { stream in
                defer { ended.set(true) }
                while true { try await stream.write(String(repeating: "x", count: 1_000)) }
            }
        }
        let client = try await rig.connect()
        try await client.send("GET / HTTP/1.1\r\nHost: a\r\n\r\n")
        _ = try await client.head()
        rig.serverEnds.value.last?.stallSends()   // the server's sends now wait, like a socket whose peer stopped reading
        #expect(await eventually(timeout: .seconds(5)) { ended.value })
        await rig.server.stop()
    }

    // MARK: Limits on connections

    @Test func theOldestIdleConnectionMakesRoomForANewcomer() async throws {
        var limits = HTTPServer.Limits()
        limits.maxConnections = 3
        let rig = Rig(limits: limits)
        let first = try await rig.connect(from: "192.0.2.1")
        _ = try await rig.connect(from: "192.0.2.2")
        _ = try await rig.connect(from: "192.0.2.3")
        #expect(await eventually { await rig.server.connectionCount == 3 })
        let newcomer = try await rig.connect(from: "192.0.2.4")
        #expect(try await first.atEnd(), "the oldest was closed")
        try await newcomer.send("GET /new HTTP/1.1\r\nHost: a\r\n\r\n")
        #expect(try await newcomer.reply()?.text == "hello /new")
        await rig.server.stop()
    }

    @Test func busyConnectionsAreNeverEvicted() async throws {
        var limits = HTTPServer.Limits()
        limits.maxConnections = 2
        let gate = Box(true)
        let rig = Rig(limits: limits) { request in
            while gate.value { try? await Task.sleep(for: .milliseconds(5)) }
            return .text("done \(request.path)")
        }
        let a = try await rig.connect(from: "192.0.2.1")
        let b = try await rig.connect(from: "192.0.2.2")
        try await a.send("GET /a HTTP/1.1\r\nHost: x\r\n\r\n")
        try await b.send("GET /b HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(await eventually { rig.seen.value.count == 2 })
        let refused = try await rig.connect(from: "192.0.2.3")
        #expect(try await refused.atEnd(), "every slot is answering a request: the newcomer is refused")
        gate.set(false)
        #expect(try await a.reply()?.text == "done /a")
        #expect(try await b.reply()?.text == "done /b")
        await rig.server.stop()
    }

    @Test func onePeerCannotTakeEverySlot() async throws {
        var limits = HTTPServer.Limits()
        limits.maxConnectionsPerAddress = 2
        let rig = Rig(limits: limits)
        let first = try await rig.connect(from: "192.0.2.9")
        _ = try await rig.connect(from: "192.0.2.9")
        _ = try await rig.connect(from: "192.0.2.9")
        #expect(try await first.atEnd(), "the peer's own oldest connection made room")
        let other = try await rig.connect(from: "192.0.2.10")
        try await other.send("GET / HTTP/1.1\r\nHost: a\r\n\r\n")
        #expect(try await other.reply()?.status == 200)
        await rig.server.stop()
    }

    // MARK: Lifecycle

    @Test func stopClosesTheListenerAndEveryConnection() async throws {
        let rig = Rig()
        let client = try await rig.connect()
        try await client.send("GET / HTTP/1.1\r\nHost: a\r\n\r\n")
        _ = try await client.reply()
        await rig.server.stop()
        #expect(try await client.atEnd())
        #expect(rig.transport.listeners[0].isClosed)
        #expect(await rig.server.boundPort == nil)
    }

    @Test func aListenerThatFailsIsReplaced() async throws {
        var limits = HTTPServer.Limits()
        limits.relistenDelay = .milliseconds(20)
        let rig = Rig(limits: limits)
        try await rig.server.start()
        rig.transport.listeners[0].fail()
        #expect(await eventually { rig.transport.listeners.count == 2 })
        let (client, serverEnd) = FakeTCPConnection.pair()
        rig.transport.listeners[1].accept(serverEnd)
        let raw = RawClient(connection: client)
        try await raw.send("GET /again HTTP/1.1\r\nHost: a\r\n\r\n")
        #expect(try await raw.reply()?.text == "hello /again")
        await rig.server.stop()
    }

    @Test func startingTwiceListensOnce() async throws {
        let rig = Rig()
        async let a = rig.server.start()
        async let b = rig.server.start()
        _ = try await (a, b)
        #expect(rig.transport.listenCount == 1)
        await rig.server.stop()
    }
}

@Suite struct HTTPDateTests {
    @Test func formatsLikeRFC9110() {
        #expect(HTTPDate.string(from: Date(timeIntervalSince1970: 0)) == "Thu, 01 Jan 1970 00:00:00 GMT")
        #expect(HTTPDate.string(from: Date(timeIntervalSince1970: 1_791_460_800)) == "Thu, 08 Oct 2026 12:00:00 GMT")
    }
}
