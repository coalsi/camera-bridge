// Loopback servers use PlatformApple's transport, so these tests run on macOS only.
#if os(macOS) || os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import BridgeSupport

/// Review finding (W4 BridgeSupport): `data(for:)` kept the whole body in memory with no size cap and only an idle
/// timeout, so a camera answering with a huge or endless body (compromised camera, MITM on plaintext HTTP, a snapshot
/// URI that points at an MJPEG stream) grew the bridge's memory without bound (10.7 GB in 5 s on loopback).
@Suite(.timeLimit(.minutes(1))) struct AuthenticatingHTTPClientLimitTests {
    @Test func defaultBodyLimitIs16MiB() {
        #expect(AuthenticatingHTTPClient.defaultMaximumBodySize == 16 << 20)
    }

    @Test func dataStopsReadingABodyLongerThanTheLimit() async throws {
        // Close-delimited (no Content-Length): only the bytes received show how long the body is.
        let server = try await EndlessBodyServer.start(contentLength: nil, chunkSize: 1 << 20, interval: .zero, maximum: 96 << 20)
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10), allowSelfSignedTLS: true, maximumBodySize: 4 << 20)
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/api.cgi?cmd=GetMdState"))
        await #expect(throws: HTTPClientError.bodyTooLarge(limit: 4 << 20)) {
            _ = try await client.data(for: URLRequest(url: url))
        }
        #expect(await server.waitForClientDisconnect(), "the client kept the connection open")
        #expect(server.bytesSent < 64 << 20, "sent \(server.bytesSent) bytes: the client kept reading")
    }

    @Test func dataRejectsAnAnnouncedBodyLongerThanTheLimit() async throws {
        // The probe's answer: Content-Length 50 GB, then 1 MiB chunks.
        let server = try await EndlessBodyServer.start(contentLength: 50_000_000_000, chunkSize: 1 << 20, interval: .zero, maximum: 96 << 20)
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/api.cgi?cmd=GetMdState"))
        await #expect(throws: HTTPClientError.bodyTooLarge(limit: AuthenticatingHTTPClient.defaultMaximumBodySize)) {
            _ = try await client.data(for: URLRequest(url: url))
        }
        #expect(await server.waitForClientDisconnect(), "the client kept the connection open")
        #expect(server.bytesSent < 64 << 20, "sent \(server.bytesSent) bytes: the client kept reading")
    }

    @Test func dataFailsWhenTheWholeAnswerTakesLongerThanTheTimeout() async throws {
        // A trickle (16 KiB every 100 ms) never trips the idle timeout; on its own it would end after 8 s.
        let server = try await EndlessBodyServer.start(contentLength: nil, chunkSize: 16 << 10, interval: .milliseconds(100), maximum: 80 * (16 << 10))
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(1))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/onvif/Events"))
        let started = ContinuousClock.now
        do {
            let (data, _) = try await client.data(for: URLRequest(url: url))
            Issue.record("returned \(data.count) bytes after \(ContinuousClock.now - started)")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(await server.waitForClientDisconnect(), "the client kept the connection open")
    }

    @Test func dataReturnsABodyOfExactlyTheLimit() async throws {
        let body = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        let server = try await LoopbackHTTPServer { _, _ in (200, [("Content-Type", "image/jpeg")], body) }
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(5), allowSelfSignedTLS: true, maximumBodySize: 1 << 20)
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/snapshot.jpg"))
        let (data, response) = try await client.data(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(data == body)
        // One byte more is refused.
        let small = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(5), allowSelfSignedTLS: true, maximumBodySize: (1 << 20) - 1)
        defer { small.invalidate() }
        await #expect(throws: HTTPClientError.bodyTooLarge(limit: (1 << 20) - 1)) {
            _ = try await small.data(for: URLRequest(url: url))
        }
    }

    @Test func cancellingTheCallerCancelsTheRequest() async throws {
        let server = try await EndlessBodyServer.start(contentLength: nil, chunkSize: 1 << 10, interval: .milliseconds(100), maximum: 1 << 20)
        defer { server.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(30))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/slow"))
        let request = Task { try await client.data(for: URLRequest(url: url)) }
        #expect(await server.waitForFirstBytes())
        let started = ContinuousClock.now
        request.cancel()
        await #expect(throws: (any Error).self) { _ = try await request.value }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await server.waitForClientDisconnect(), "the client kept the connection open")
    }
}

/// Loopback HTTP/1.1 server (PlatformApple transport) that answers the first request on each connection with a body that
/// does not end on its own: the head (with `contentLength` if given), then `chunkSize` bytes every `interval` until the
/// client goes away or `maximum` bytes were sent (the connection then closes, ending a close-delimited body).
private final class EndlessBodyServer: Sendable {
    private struct State {
        var sent = 0
        var disconnected = false
    }

    private let listener: any TCPListener
    private let contentLength: Int64?
    private let chunk: Data
    private let interval: Duration
    private let maximum: Int
    private let state = Mutex(State())
    private let acceptTask = Mutex<Task<Void, Never>?>(nil)

    var port: UInt16 { listener.port }
    var bytesSent: Int { state.withLock { $0.sent } }

    private init(listener: any TCPListener, contentLength: Int64?, chunkSize: Int, interval: Duration, maximum: Int) {
        self.listener = listener
        self.contentLength = contentLength
        self.chunk = Data(repeating: 0x20, count: chunkSize)
        self.interval = interval
        self.maximum = maximum
    }

    static func start(contentLength: Int64?, chunkSize: Int, interval: Duration, maximum: Int) async throws -> EndlessBodyServer {
        let listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
        let server = EndlessBodyServer(listener: listener, contentLength: contentLength, chunkSize: chunkSize, interval: interval, maximum: maximum)
        server.acceptTask.withLock {
            $0 = Task {
                await withTaskGroup(of: Void.self) { group in
                    for await connection in listener.connections { group.addTask { await server.serve(connection) } }
                }
            }
        }
        return server
    }

    func stop() {
        listener.close()
        acceptTask.withLock { $0?.cancel() }
    }

    func waitForClientDisconnect() async -> Bool {
        await poll { $0.disconnected }
    }

    func waitForFirstBytes() async -> Bool {
        await poll { $0.sent > 0 }
    }

    private func poll(_ condition: (State) -> Bool) async -> Bool {
        for _ in 0..<200 {
            if state.withLock({ condition($0) }) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func serve(_ connection: any TCPConnection) async {
        defer { connection.close() }
        var parser = HTTPRequestParser()
        do {
            while true {
                guard let data = try await connection.receive(maximumLength: 65_536) else { return }
                if try !parser.feed(data).isEmpty { break }
            }
        } catch {
            return
        }
        // Notice the client going away (EOF or reset) while the body is still being sent.
        let watcher = Task {
            do { while try await connection.receive(maximumLength: 65_536) != nil {} } catch {}
            if !Task.isCancelled { self.state.withLock { $0.disconnected = true } }
        }
        defer { watcher.cancel() }
        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n"
        if let contentLength { head += "Content-Length: \(contentLength)\r\n" }
        head += "\r\n"
        do {
            try await connection.send(Data(head.utf8))
            while bytesSent < maximum, !state.withLock({ $0.disconnected }) {
                try await connection.send(chunk)
                state.withLock { $0.sent += chunk.count }
                if interval > .zero { try await Task.sleep(for: interval) }
            }
        } catch {
            state.withLock { $0.disconnected = true }
        }
        // Closing ends a close-delimited body (and cuts one with a Content-Length short).
    }
}
#endif
