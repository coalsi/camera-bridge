// A loopback fake RTSP server (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import Synchronization
import TestSupport
import Testing
@testable import CameraAdapters

/// Whether a camera's video plays without a password: one RTSP DESCRIBE without credentials, against a loopback fake only. 200 with the
/// stream's description is on, 401 or 403 is off, anything else (another answer, silence, a closed or refused connection) is unknown.
@Suite(.timeLimit(.minutes(1))) struct RTSPAccessProbeTests {
    /// Answers every request with `answer` (nil: never answers) and records what it was sent.
    final class FakeRTSPServer: Sendable {
        let port: UInt16
        let requests = Box<[String]>([])
        let connections = Box(0)
        let answer: Box<String?>
        private let listener: any TCPListener
        private let task = Mutex<Task<Void, Never>?>(nil)

        init(answer: String?) async throws {
            self.answer = Box(answer)
            listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
            port = listener.port
            let task = Task { [self] in
                for await connection in listener.connections { Task { await serve(connection) } }
            }
            self.task.withLock { $0 = task }
        }

        func url(_ path: String = "/stream1", credentials: String = "") -> URL {
            URL(string: "rtsp://\(credentials)127.0.0.1:\(port)\(path)")!
        }

        func stop() {
            listener.close()
            task.withLock { $0?.cancel() }
        }

        private func serve(_ connection: any TCPConnection) async {
            connections.update { $0 += 1 }
            defer { connection.close() }
            var received = Data()
            while !String(decoding: received, as: UTF8.self).contains("\r\n\r\n") {
                guard let data = try? await connection.receive(maximumLength: 4096) else { return }
                received.append(data)
            }
            requests.update { $0.append(String(decoding: received, as: UTF8.self)) }
            guard let answer = answer.value else {
                try? await Task.sleep(for: .seconds(30))   // a camera that never answers
                return
            }
            _ = try? await connection.send(Data(answer.utf8))
        }
    }

    static let sdp = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=Media Presentation\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"
    static let open = "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Type: application/sdp\r\nContent-Length: \(sdp.utf8.count)\r\n\r\n\(sdp)"

    private func check(_ answer: String?, timeout: Duration = .seconds(2)) async throws -> (RemoteAccessState, FakeRTSPServer) {
        let server = try await FakeRTSPServer(answer: answer)
        let state = await RTSPAccessProbe.check(url: server.url(), transport: PlatformNetworkTransport(), timeout: timeout)
        return (state, server)
    }

    @Test func videoThatPlaysWithoutAPasswordIsOn() async throws {
        let (state, server) = try await check(Self.open)
        defer { server.stop() }
        #expect(state == .on)
        #expect(server.connections.value == 1 && server.requests.value.count == 1, "one request per check")
        let request = try #require(server.requests.value.first)
        #expect(request.hasPrefix("DESCRIBE rtsp://127.0.0.1:\(server.port)/stream1 RTSP/1.0\r\n"))
        #expect(request.contains("CSeq: 1\r\n") && request.contains("Accept: application/sdp\r\n"))
    }

    @Test func aPasswordChallengeOrARefusalIsOff() async throws {
        for answer in ["RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\nWWW-Authenticate: Digest realm=\"IP Camera\", nonce=\"4e6f6e6365\"\r\n\r\n",
                       "RTSP/1.0 403 Forbidden\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n"] {
            let (state, server) = try await check(answer)
            server.stop()
            #expect(state == .off, "\(answer)")
        }
    }

    @Test func anyOtherAnswerIsUnknown() async throws {
        for answer in ["RTSP/1.0 404 Not Found\r\nCSeq: 1\r\n\r\n", "RTSP/1.0 454 Session Not Found\r\nCSeq: 1\r\n\r\n",
                       "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nhello",
                       "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", "garbage\r\n\r\n"] {
            let (state, server) = try await check(answer)
            server.stop()
            #expect(state == .unknown, "\(answer)")
        }
    }

    @Test func silenceAClosedConnectionOrNoServerIsUnknown() async throws {
        let clock = ContinuousClock(), start = clock.now
        let (silent, server) = try await check(nil, timeout: .milliseconds(300))
        server.stop()
        #expect(silent == .unknown && clock.now - start < .seconds(5), "a short timeout")

        let (closed, quiet) = try await check("")
        quiet.stop()
        #expect(closed == .unknown)

        let gone = try await FakeRTSPServer(answer: Self.open)
        let url = gone.url()
        gone.stop()
        #expect(await RTSPAccessProbe.check(url: url, transport: PlatformNetworkTransport(), timeout: .seconds(2)) == .unknown)
    }

    @Test func credentialsInTheAddressAreNeverSent() async throws {
        let server = try await FakeRTSPServer(answer: "RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\n\r\n")
        defer { server.stop() }
        let state = await RTSPAccessProbe.check(url: server.url(credentials: "admin:s3cret@"), transport: PlatformNetworkTransport(), timeout: .seconds(2))
        #expect(state == .off)
        let request = try #require(server.requests.value.first)
        #expect(!request.contains("s3cret") && !request.contains("admin") && !request.contains("Authorization"))
        #expect(server.requests.value.count == 1, "the challenge is never answered")
    }

    /// Some cameras take their credentials in the path or the query (XMEye `/user=admin&password=…`): such an address signs in, so it
    /// would not tell whether the video needs a password. Nothing is sent.
    @Test func credentialsInThePathOrQueryAreNeverSent() async throws {
        let server = try await FakeRTSPServer(answer: Self.open)
        defer { server.stop() }
        for path in ["/user=admin&password=s3cret&channel=1&stream=0.sdp", "/live?pwd=s3cret", "/cam/realmonitor;passwd=s3cret"] {
            #expect(await RTSPAccessProbe.check(url: server.url(path), transport: PlatformNetworkTransport(), timeout: .seconds(2)) == .unknown, "\(path)")
        }
        #expect(server.connections.value == 0, "nothing was sent")
        #expect(await RTSPAccessProbe.check(url: server.url("/user=admin&channel=1&stream=0.sdp"), transport: PlatformNetworkTransport(),
                                            timeout: .seconds(2)) == .on, "a user name alone is no credential")
    }

    @Test func onlyRTSPAddressesAreChecked() async {
        let transport = UnusedTransport()
        #expect(await RTSPAccessProbe.check(url: URL(string: "rtsps://192.0.2.20/stream")!, transport: transport) == .unknown)
        #expect(await RTSPAccessProbe.check(url: URL(string: "http://192.0.2.20/stream")!, transport: transport) == .unknown)
        #expect(!transport.used.value, "nothing is sent")
    }

    @Test func answersAreReadAsTheyArrive() {
        #expect(RTSPAccessProbe.classify(Data(Self.open.utf8)) == .on)
        #expect(RTSPAccessProbe.classify(Data("RTSP/1.0 200 OK\r\nContent-Length: 10\r\n\r\nv=0".utf8)) == nil, "the body is not complete yet")
        #expect(RTSPAccessProbe.classify(Data("RTSP/1.0 200 OK\r\nCSeq: 1".utf8)) == nil, "the headers are not complete yet")
        #expect(RTSPAccessProbe.classify(Data("RTSP/1.0 200 OK\r\nContent-Length: 4\r\n\r\nv=0\n".utf8)) == .on, "a description without its type")
        #expect(RTSPAccessProbe.classify(Data("RTSP/1.0 401 Unauthorized\r\n\r\n".utf8)) == .off)
    }
}
#endif
