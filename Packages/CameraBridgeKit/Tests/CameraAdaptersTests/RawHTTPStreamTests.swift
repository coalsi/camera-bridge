import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

@Suite(.timeLimit(.minutes(1))) struct ChunkedDecoderTests {
    @Test func decodesChunksSplitAnywhere() {
        let wire = Data("5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n".utf8)
        for step in [1, 2, 3, 100] {
            var decoder = ChunkedDecoder()
            var out = Data()
            var offset = 0
            while offset < wire.count {
                let end = min(wire.count, offset + step)
                out.append(decoder.feed(wire[offset..<end]))
                offset = end
            }
            #expect(String(decoding: out, as: UTF8.self) == "hello world", "step \(step)")
            #expect(decoder.isFinished)
        }
    }

    @Test func sizesAreHexadecimal() {
        var decoder = ChunkedDecoder()
        let out = decoder.feed(Data("a\r\n0123456789\r\n1F\r\n".utf8) + Data(String(repeating: "x", count: 31).utf8) + Data("\r\n0\r\n\r\n".utf8))
        #expect(String(decoding: out, as: UTF8.self) == "0123456789" + String(repeating: "x", count: 31))
        #expect(decoder.isFinished)
    }

    @Test func garbageSizeEndsTheStream() {
        var decoder = ChunkedDecoder()
        #expect(decoder.feed(Data("zz\r\nabc".utf8)).isEmpty)
        #expect(decoder.isFinished)
    }
}

@Suite(.timeLimit(.minutes(1))) struct RawHTTPHeadTests {
    @Test func parsesStatusAndHeaders() throws {
        let head = try RawHTTPStream.parseHead(Data("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Digest realm=\"x\", nonce=\"n\"\r\nContent-Length: 0".utf8))
        #expect(head.status == 401 && head.reason == "Unauthorized")
        #expect(head.headers.values(for: "www-authenticate").first?.hasPrefix("Digest") == true)
        #expect(throws: CameraAdapterError.self) { try RawHTTPStream.parseHead(Data("garbage".utf8)) }
        #expect(throws: CameraAdapterError.self) { try RawHTTPStream.parseHead(Data("HTTP/1.1 abc".utf8)) }
    }
}

#if os(macOS) || os(Linux)

@Suite(.timeLimit(.minutes(1))) struct RawHTTPStreamTests {
    private let credentials = HTTPCredentials(username: "admin", password: "pa55")

    /// A part reaches the reader at once, not when the next boundary arrives.
    @Test func partsArriveAsTheyAreSentAfterTheDigestChallenge() async throws {
        let release = Box(false)
        let server = try await MockHTTPServer.start { request in
            guard isDigestAuthorization(request.head.headers["Authorization"]) else { return .digestChallenge() }
            return .stream(status: 200, headers: [("Content-Type", "multipart/x-mixed-replace; boundary=myboundary")]) { writer in
                await writer.write("--myboundary\r\nContent-Type: text/plain\r\n\r\nFirst\r\n")
                _ = await eventually(timeout: .seconds(10)) { release.value }
                await writer.write("\r\n--myboundary\r\n\r\nSecond\r\n")
            }
        }
        defer { server.stop() }
        let opened = try await RawHTTPStream.open(transport: PlatformNetworkTransport(), host: "127.0.0.1", port: Int(server.port), target: "/x?a=[b]",
                                                  credentials: credentials)
        #expect(opened.status == 200)
        var received = Data()
        var iterator = opened.body.makeAsyncIterator()
        while !String(decoding: received, as: UTF8.self).contains("First") {
            guard let chunk = try await iterator.next() else { break }
            received.append(chunk)
        }
        #expect(String(decoding: received, as: UTF8.self).contains("First"), "the first part arrived before the second was sent")
        #expect(!String(decoding: received, as: UTF8.self).contains("Second"))
        release.set(true)
        opened.close()
        // The challenge was answered once, on a second request; the target went out exactly as given.
        #expect(server.requests.count == 2)
        #expect(server.requests.last?.head.target == "/x?a=[b]")
        #expect(server.requests.first?.head.headers["Authorization"] == nil)
    }

    @Test func rejectedCredentialsComeBackAs401() async throws {
        let server = try await MockHTTPServer.start { _ in .digestChallenge() }
        defer { server.stop() }
        let opened = try await RawHTTPStream.open(transport: PlatformNetworkTransport(), host: "127.0.0.1", port: Int(server.port), target: "/", credentials: credentials)
        #expect(opened.status == 401)
        opened.close()
        #expect(server.requests.count == 2, "one challenge, one answer; nothing more")
    }

    @Test func basicIsUsedOnlyWhenBasicIsAsked() async throws {
        let server = try await MockHTTPServer.start { request in
            guard request.head.headers["Authorization"]?.hasPrefix("Basic ") == true else {
                return .full(status: 401, headers: [("WWW-Authenticate", #"Basic realm="x""#)], body: Data())
            }
            return .stream(status: 200, headers: [("Content-Type", "text/plain")]) { writer in await writer.write("hi") }
        }
        defer { server.stop() }
        let opened = try await RawHTTPStream.open(transport: PlatformNetworkTransport(), host: "127.0.0.1", port: Int(server.port), target: "/", credentials: credentials)
        #expect(opened.status == 200)
        var iterator = opened.body.makeAsyncIterator()
        #expect(try await iterator.next().map { String(decoding: $0, as: UTF8.self) } == "hi")
        opened.close()
    }

    @Test func aChallengeItCannotAnswerIsUnauthorizedWithoutSendingTheCredentials() async throws {
        let server = try await MockHTTPServer.start { _ in .full(status: 401, headers: [("WWW-Authenticate", "Negotiate")], body: Data()) }
        defer { server.stop() }
        await #expect(throws: CameraAdapterError.unauthorized) {
            _ = try await RawHTTPStream.open(transport: PlatformNetworkTransport(), host: "127.0.0.1", port: Int(server.port), target: "/", credentials: credentials)
        }
        #expect(server.requests.count == 1 && server.requests.allSatisfy { $0.head.headers["Authorization"] == nil })
    }

    @Test func withoutCredentialsThe401IsReturnedAtOnce() async throws {
        let server = try await MockHTTPServer.start { _ in .digestChallenge() }
        defer { server.stop() }
        let opened = try await RawHTTPStream.open(transport: PlatformNetworkTransport(), host: "127.0.0.1", port: Int(server.port), target: "/", credentials: nil)
        #expect(opened.status == 401 && server.requests.count == 1)
        opened.close()
    }

    @Test func aRefusedConnectionIsATransportError() async throws {
        let listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
        let port = listener.port
        listener.close()
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: (any Error).self) {
            _ = try await RawHTTPStream.open(transport: PlatformNetworkTransport(), host: "127.0.0.1", port: Int(port), target: "/", credentials: nil, timeout: .seconds(2))
        }
    }
}
#endif
