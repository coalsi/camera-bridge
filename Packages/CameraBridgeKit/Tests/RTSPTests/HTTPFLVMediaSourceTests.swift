// Loopback HTTP server over PlatformApple's transport: macOS only.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import MediaCore
import Synchronization
import TestSupport
import Testing
@testable import RTSP

/// Loopback HTTP/1.1 server that answers each request with a status line and, for 200, streams a close-delimited body
/// chunk by chunk at the given times.
final class StreamingHTTPServer: Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [(String, String)] = []
        /// (delay since the response head, bytes)
        var chunks: [(Duration, Data)] = []
        /// Wait before sending the response head.
        var headDelay: Duration = .zero
    }

    private let listener: any TCPListener
    private let task: Task<Void, Never>
    private let requestLog = RequestLog()

    private final class RequestLog: Sendable {
        let heads = Mutex<[HTTPRequestHead]>([])
    }

    init(handler: @escaping @Sendable (HTTPRequestHead) -> Reply) async throws {
        let listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
        self.listener = listener
        let log = requestLog
        task = Task {
            for await connection in listener.connections {
                Task {
                    var parser = HTTPRequestParser()
                    while let data = try? await connection.receive(maximumLength: 65_536) {
                        guard let requests = try? parser.feed(data) else { break }
                        for (head, _) in requests {
                            log.heads.withLock { $0.append(head) }
                            let reply = handler(head)
                            if reply.headDelay > .zero { try? await Task.sleep(for: reply.headDelay) }
                            var text = "HTTP/1.1 \(reply.status) \(reply.status == 200 ? "OK" : "Error")\r\n"
                            for (name, value) in reply.headers { text += "\(name): \(value)\r\n" }
                            if reply.status == 200 {
                                text += "Content-Type: video/x-flv\r\nConnection: close\r\n\r\n"
                            } else {
                                text += "Content-Length: 0\r\n\r\n"
                            }
                            try? await connection.send(Data(text.utf8))
                            guard reply.status == 200 else { continue }
                            let start = ContinuousClock.now
                            for (delay, chunk) in reply.chunks {
                                try? await Task.sleep(until: start.advanced(by: delay), clock: .continuous)
                                if (try? await connection.send(chunk)) == nil { break }
                            }
                            connection.close()
                            return
                        }
                    }
                    connection.close()
                }
            }
        }
    }

    deinit {
        listener.close()
        task.cancel()
    }

    func url(_ path: String = "/flv?port=1935&app=bcs&stream=channel0_main.bcs&user=admin&password=secret") -> URL {
        URL(string: "http://127.0.0.1:\(listener.port)\(path)") ?? URL(filePath: "/")
    }

    var requests: [HTTPRequestHead] { requestLog.heads.withLock { $0 } }
}

/// A paced FLV stream: 25 fps H.264 (GOP 25, first tag not a keyframe) + AAC-LC 48 kHz mono (21.33 ms frames, so
/// FLV's millisecond timestamps jitter).
private func flvChunks(frames: Int, startWithDeltaFrame: Bool = true) -> [(Duration, Data)] {
    let sets = RealParameterSets.h264Main640x360
    var head = FLVWriter.header()
    head.append(FLVWriter.script())
    head.append(FLVWriter.avcSequenceHeader(sps: sets.sps, pps: sets.pps))
    head.append(FLVWriter.aacSequenceHeader(Data([0x11, 0x88])))
    var chunks: [(Duration, Data)] = [(.zero, head)]
    var audioIndex = 0
    let offset = startWithDeltaFrame ? 1 : 0
    for i in 0..<frames {
        let index = i + offset
        let key = index % 25 == 0
        let nal = SyntheticNALSource.videoNAL(index: index, isKeyframe: key, size: key ? 3000 : 400, codec: .h264)
        var chunk = FLVWriter.avcNALUs([nal], keyframe: key, timestamp: UInt32(index * 40))
        while audioIndex * 1024 < (index + 1) * 40 * 48 {
            let milliseconds = (Double(audioIndex) * 1024 / 48).rounded()
            chunk.append(FLVWriter.aacRaw(filler(50, seed: UInt8(audioIndex % 200)), timestamp: UInt32(milliseconds)))
            audioIndex += 1
        }
        chunks.append((.milliseconds(i * 40), chunk))
    }
    return chunks
}

@Suite(.timeLimit(.minutes(1))) struct HTTPFLVMediaSourceTests {
    @Test func streamsVideoAndAudioUntilEOF() async throws {
        let server = try await StreamingHTTPServer { _ in StreamingHTTPServer.Reply(status: 200, chunks: flvChunks(frames: 60)) }
        let source = HTTPFLVMediaSource(url: server.url(), credentials: nil, displayName: "Doorbell")
        #expect(source.displayName == "Doorbell")
        let collected = await collect(try await source.samples(), timeout: .seconds(10))
        #expect(collected.ended)
        #expect(collected.error as? RTSPError == .protocolError("HTTP-FLV stream ended"))

        let video = collected.video
        // Output starts at the first keyframe (index 25).
        #expect(video.first?.isKeyframe == true)
        #expect(video.first.flatMap(SyntheticNALSource.frameIndex(of:)) == 25)
        #expect(video.count == 36)
        #expect(video.allSatisfy { $0.format.width == 640 && $0.format.height == 360 && $0.format.codec == .h264 })
        let deltas = zip(video.dropFirst(), video).map { $0.pts.value - $1.pts.value }
        #expect(deltas.allSatisfy { $0 == 3600 })
        #expect(video.first?.pts.value == 0)

        let audio = collected.audio
        #expect(audio.count >= 60)
        #expect(audio.allSatisfy { $0.format.codec == .aac && $0.format.sampleRate == 48_000 && $0.sampleCount == 1024 })
        #expect(audio.allSatisfy { $0.pts.timescale == 48_000 })
        let audioDeltas = zip(audio.dropFirst(), audio).map { $0.pts.value - $1.pts.value }
        #expect(audioDeltas.allSatisfy { $0 == 1024 }, "sample-exact AAC spacing despite millisecond timestamps")
        #expect(zip(collected.samples.dropFirst(), collected.samples).allSatisfy { $0.wallClock >= $1.wallClock })
        #expect(server.requests.first?.headers["User-Agent"] == "CameraBridge/1.0")
    }

    @Test func basicAuthenticationChallengeIsAnswered() async throws {
        let expected = "Basic " + Data("admin:secret".utf8).base64EncodedString()
        let server = try await StreamingHTTPServer { head in
            head.headers["Authorization"] == expected
                ? StreamingHTTPServer.Reply(status: 200, chunks: flvChunks(frames: 20, startWithDeltaFrame: false))
                : StreamingHTTPServer.Reply(status: 401, headers: [("WWW-Authenticate", "Basic realm=\"cam\"")])
        }
        let source = HTTPFLVMediaSource(url: server.url("/flv"), credentials: HTTPCredentials(username: "admin", password: "secret"),
                                        displayName: "cam")
        let collected = await collect(try await source.samples(), timeout: .seconds(5)) { videoFrameCount($0) >= 5 }
        await source.stop()
        #expect(collected.video.count >= 5)
        #expect(server.requests.count == 2)
    }

    /// Review finding (W4 BridgeSupport, round 4): every `samples()` call used a fresh client, so once the camera had
    /// used Digest, a host impersonating it could answer the reconnect with `401 Basic` and read the password.
    @Test func reconnectNeverAnswersBasicAfterDigest() async throws {
        let impersonating = Box(false)
        let server = try await StreamingHTTPServer { head in
            let authorization = head.headers["Authorization"] ?? ""
            if impersonating.value {
                return authorization.hasPrefix("Basic ")
                    ? StreamingHTTPServer.Reply(status: 200, chunks: flvChunks(frames: 20, startWithDeltaFrame: false))
                    : StreamingHTTPServer.Reply(status: 401, headers: [("WWW-Authenticate", "Basic realm=\"cam\"")])
            }
            return authorization.hasPrefix("Digest ")
                ? StreamingHTTPServer.Reply(status: 200, chunks: flvChunks(frames: 20, startWithDeltaFrame: false))
                : StreamingHTTPServer.Reply(status: 401, headers: [("WWW-Authenticate", "Digest realm=\"cam\", nonce=\"n1\", qop=\"auth\"")])
        }
        let source = HTTPFLVMediaSource(url: server.url("/flv"), credentials: HTTPCredentials(username: "admin", password: "secret"),
                                        displayName: "cam")
        let first = await collect(try await source.samples(), timeout: .seconds(5)) { videoFrameCount($0) >= 5 }
        #expect(first.video.count >= 5)
        impersonating.set(true)
        await #expect(throws: RTSPError.unauthorized) { try await source.samples() }
        await source.stop()
        #expect(server.requests.contains { $0.headers["Authorization"]?.hasPrefix("Digest ") == true })
        #expect(!server.requests.contains { $0.headers["Authorization"]?.lowercased().hasPrefix("basic") == true })
    }

    @Test func rejectedCredentials() async throws {
        let server = try await StreamingHTTPServer { _ in
            StreamingHTTPServer.Reply(status: 401, headers: [("WWW-Authenticate", "Basic realm=\"cam\"")])
        }
        let source = HTTPFLVMediaSource(url: server.url(), credentials: HTTPCredentials(username: "admin", password: "wrong"), displayName: "cam")
        await #expect(throws: RTSPError.unauthorized) { try await source.samples() }
    }

    @Test func notFound() async throws {
        let server = try await StreamingHTTPServer { _ in StreamingHTTPServer.Reply(status: 404) }
        let source = HTTPFLVMediaSource(url: server.url(), credentials: nil, displayName: "cam")
        await #expect(throws: RTSPError.notFound) { try await source.samples() }
    }

    @Test func serverErrorStatus() async throws {
        let server = try await StreamingHTTPServer { _ in StreamingHTTPServer.Reply(status: 503) }
        let source = HTTPFLVMediaSource(url: server.url(), credentials: nil, displayName: "cam")
        await #expect(throws: RTSPError.badStatus(503)) { try await source.samples() }
    }

    @Test func notFLVFailsTheStream() async throws {
        let server = try await StreamingHTTPServer { _ in
            StreamingHTTPServer.Reply(status: 200, chunks: [(.zero, Data("<html>login</html>".utf8))])
        }
        let source = HTTPFLVMediaSource(url: server.url(), credentials: nil, displayName: "cam")
        let collected = await collect(try await source.samples(), timeout: .seconds(5))
        #expect(collected.ended)
        #expect(collected.error is RTSPError)
    }

    @Test func stopFinishesWithoutError() async throws {
        let server = try await StreamingHTTPServer { _ in StreamingHTTPServer.Reply(status: 200, chunks: flvChunks(frames: 200)) }
        let source = HTTPFLVMediaSource(url: server.url(), credentials: nil, displayName: "cam")
        let stream = try await source.samples()
        let reader = Task { await collect(stream, timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(1500))
        await source.stop()
        let collected = await reader.value
        #expect(collected.ended)
        #expect(collected.error == nil)
        #expect(collected.video.count > 0)
    }

    @Test func silentServerFailsWithTimeoutAndNoSecretsInTheError() async throws {
        let sets = RealParameterSets.h264Main640x360
        var head = FLVWriter.header()
        head.append(FLVWriter.avcSequenceHeader(sps: sets.sps, pps: sets.pps))
        let first = head
        let server = try await StreamingHTTPServer { _ in StreamingHTTPServer.Reply(status: 200, chunks: [(.zero, first), (.seconds(20), Data([0]))]) }
        let source = HTTPFLVMediaSource(url: server.url(), credentials: nil, displayName: "cam", timeout: .seconds(1))
        let started = ContinuousClock.now
        let collected = await collect(try await source.samples(), timeout: .seconds(8))
        #expect(collected.ended)
        #expect(collected.error as? RTSPError == .timeout)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(!String(describing: collected.error).contains("secret"))
    }

    @Test func connectionErrorsNeverCarryTheURL() async throws {
        let listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
        let port = listener.port
        listener.close()
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/flv?app=bcs&user=admin&password=secret"))
        let source = HTTPFLVMediaSource(url: url, credentials: nil, displayName: "cam", timeout: .seconds(2))
        do {
            _ = try await source.samples()
            Issue.record("expected an error")
        } catch {
            #expect(!String(describing: error).contains("secret"))
            #expect(!(error as NSError).userInfo.values.contains { "\($0)".contains("secret") })
            #expect(error is TransportError || error is RTSPError)
        }
    }

    @Test func stopWhileConnectingCancelsTheConnection() async throws {
        let server = try await StreamingHTTPServer { _ in
            StreamingHTTPServer.Reply(status: 200, chunks: flvChunks(frames: 50), headDelay: .seconds(3))
        }
        let source = HTTPFLVMediaSource(url: server.url(), credentials: nil, displayName: "cam")
        let started = ContinuousClock.now
        let connecting = Task { try await source.samples() }
        try await Task.sleep(for: .milliseconds(300))
        await source.stop()
        let result = await connecting.result
        #expect(ContinuousClock.now - started < .seconds(2), "stop() does not wait for the response head")
        #expect(throws: TransportError.closed) { try result.get() }
    }

    @Test func newerSamplesCallSupersedesAConnectingOne() async throws {
        let calls = Mutex(0)
        let server = try await StreamingHTTPServer { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            return StreamingHTTPServer.Reply(status: 200, chunks: flvChunks(frames: 30, startWithDeltaFrame: false),
                                             headDelay: call == 1 ? .seconds(3) : .zero)
        }
        let source = HTTPFLVMediaSource(url: server.url(), credentials: nil, displayName: "cam")
        let first = Task { try await source.samples() }
        try await Task.sleep(for: .milliseconds(300))
        let second = try await source.samples()
        await #expect(throws: TransportError.closed) { try await first.value }
        let collected = await collect(second, timeout: .seconds(5)) { videoFrameCount($0) >= 5 }
        await source.stop()
        #expect(collected.video.count >= 5)
    }

    @Test func timeline() {
        var timeline = FLVTimeline()
        let format = RTSPSessionDescription.makeH264Format(sps: RealParameterSets.h264Main640x360.sps, pps: RealParameterSets.h264Main640x360.pps)
        let now = Date()
        let frame = { (ms: Int64, key: Bool, cts: Int32) in
            FLVSample.video(FLVVideoFrame(nalUnits: [Data([0x65])], isKeyframe: key, timestamp: ms, compositionOffset: cts, format: format))
        }
        #expect(timeline.map(frame(0, false, 0), arrival: now).map { _ in true } == nil, "output starts at a keyframe")
        guard case .video(let first)? = timeline.map(frame(1000, true, 0), arrival: now),
              case .video(let second)? = timeline.map(frame(1040, false, 80), arrival: now),
              case .video(let third)? = timeline.map(frame(1040, false, 0), arrival: now) else {
            Issue.record("expected frames")
            return
        }
        #expect(first.pts.value == 0 && first.dts == nil)
        #expect(second.dts?.value == 3600 && second.pts.value == 3600 + 7200)
        #expect(third.pts.value > 3600, "a repeated timestamp still moves forward")
    }
}
#endif
