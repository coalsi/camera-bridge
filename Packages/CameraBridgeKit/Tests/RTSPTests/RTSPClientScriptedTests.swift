#if os(macOS)
import BridgeSupport
import Foundation
import MediaCore
import PlatformApple
import RTP
import Synchronization
import TestSupport
import Testing
@testable import RTSP

/// A loopback RTSP peer whose answers are scripted per request (for protocol edge cases the test server does not
/// produce). Records the responses the client sends back to server-initiated requests.
final class ScriptedRTSPServer: Sendable {
    typealias Handler = @Sendable (RTSPRequest) -> [Data]
    /// Runs after the PLAY response has been sent; `send` returns false once the connection is gone.
    typealias Streamer = @Sendable (_ send: @escaping @Sendable (Data) async -> Bool) async -> Void

    private let listener: any TCPListener
    private let task: Task<Void, Never>
    private final class Log: Sendable {
        let responses = Mutex<[RTSPResponse]>([])
        let requests = Mutex<[RTSPRequest]>([])
        let interleaved = Mutex<[(channel: UInt8, payload: Data)]>([])
    }

    private let received = Log()

    init(handler: @escaping Handler, afterPlay streamer: Streamer? = nil) async throws {
        let listener = try await AppleNetworkTransport().listen(port: 0, loopbackOnly: true)
        self.listener = listener
        let received = self.received
        task = Task {
            for await connection in listener.connections {
                Task {
                    var parser = RTSPMessageParser()
                    var streaming: Task<Void, Never>?
                    while let data = try? await connection.receive(maximumLength: 65_536) {
                        parser.append(data)
                        while let message = try? parser.next() {
                            switch message {
                            case .request(let request):
                                received.requests.withLock { $0.append(request) }
                                for chunk in handler(request) { try? await connection.send(chunk) }
                                if request.method == "PLAY", let streamer, streaming == nil {
                                    streaming = Task { await streamer { data in (try? await connection.send(data)) != nil } }
                                }
                            case .response(let response):
                                received.responses.withLock { $0.append(response) }
                            case .interleaved(let channel, let payload):
                                received.interleaved.withLock { $0.append((channel, payload)) }
                            }
                        }
                    }
                    streaming?.cancel()
                    connection.close()
                }
            }
        }
    }

    deinit {
        listener.close()
        task.cancel()
    }

    var url: URL { URL(string: "rtsp://127.0.0.1:\(listener.port)/cam") ?? URL(filePath: "/") }
    var responsesFromClient: [RTSPResponse] { received.responses.withLock { $0 } }
    var requests: [RTSPRequest] { received.requests.withLock { $0 } }
    var interleavedFromClient: [(channel: UInt8, payload: Data)] { received.interleaved.withLock { $0 } }

    static func response(_ status: Int, _ reason: String, _ request: RTSPRequest, headers: [(String, String)] = [], body: String = "") -> Data {
        var text = "RTSP/1.0 \(status) \(reason)\r\nCSeq: \(request.headers["CSeq"] ?? "0")\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if !body.isEmpty { text += "Content-Length: \(body.utf8.count)\r\n" }
        return Data((text + "\r\n" + body).utf8)
    }

    /// Answers OPTIONS/SETUP/PLAY/TEARDOWN/GET_PARAMETER normally and DESCRIBE with `sdp`.
    static func standard(sdp: String) -> Handler {
        { request in
            switch request.method {
            case "DESCRIBE": [response(200, "OK", request, headers: [("Content-Type", "application/sdp")], body: sdp)]
            case "SETUP": [response(200, "OK", request, headers: [("Session", "S1;timeout=60"), ("Transport", request.headers["Transport"] ?? "")])]
            default: [response(200, "OK", request, headers: [("Session", "S1")])]
            }
        }
    }
}

private func client(_ server: ScriptedRTSPServer, timeout: Duration = .seconds(3)) -> RTSPClient {
    RTSPClient(configuration: RTSPConfiguration(url: server.url, credentials: nil, timeout: timeout), transport: AppleNetworkTransport())
}

private let videoSDP = """
v=0
o=- 1 1 IN IP4 127.0.0.1
s=scripted
t=0 0
m=video 0 RTP/AVP 96
a=rtpmap:96 H264/90000
a=fmtp:96 packetization-mode=1;sprop-parameter-sets=J00AHqsoFAX/Kg==,KO48gA==
a=control:track1
"""

/// `$`-framed RTP packet on `channel`.
func framedRTP(channel: UInt8 = 0, payloadType: UInt8 = 96, sequence: UInt16, timestamp: UInt32, ssrc: UInt32 = 1, marker: Bool = true,
               payload: Data) -> Data {
    RTSPRequestSerializer.interleaved(channel: channel, payload: RTPPacket(marker: marker, payloadType: payloadType, sequenceNumber: sequence,
                                                                             timestamp: timestamp, ssrc: ssrc, payload: payload).serialized())
}

private let videoAudioSDP = """
v=0
o=- 1 1 IN IP4 127.0.0.1
s=scripted
t=0 0
m=video 0 RTP/AVP 96
a=rtpmap:96 H264/90000
a=fmtp:96 packetization-mode=1;sprop-parameter-sets=J00AHqsoFAX/Kg==,KO48gA==
a=control:track1
m=audio 0 RTP/AVP 0
a=rtpmap:0 PCMU/8000
a=control:track2
"""

private func outcome<T: Sendable>(_ body: () async throws -> T) async -> Result<T, any Error> {
    do {
        return .success(try await body())
    } catch {
        return .failure(error)
    }
}

private func senderReportPacket() -> Data {
    var writer = ByteWriter()
    writer.write(0x80); writer.write(200); writer.writeUInt16BE(6); writer.writeUInt32BE(1)
    writer.writeUInt64BE(NTPTime.timestamp(for: Date())); writer.writeUInt32BE(0); writer.writeUInt32BE(0); writer.writeUInt32BE(0)
    return writer.data
}

@Suite(.timeLimit(.minutes(1))) struct RTSPClientResilienceTests {
    @Test func sequenceResetMidSessionKeepsVideoFlowing() async throws {
        // The camera restarts its RTP sender: sequence numbers jump back from 20_009 to 100 (a new keyframe first).
        var chunks: [Data] = []
        for i in 0..<10 { chunks.append(framedRTP(sequence: UInt16(20_000 + i), timestamp: UInt32(i * 3600), payload: h264NAL(type: i == 0 ? 5 : 1, size: 50))) }
        for i in 0..<100 {
            chunks.append(framedRTP(sequence: UInt16(100 + i), timestamp: UInt32((10 + i) * 3600), ssrc: 2,
                                    payload: h264NAL(type: i % 10 == 0 ? 5 : 1, size: 50)))
        }
        let media = chunks
        let standard = ScriptedRTSPServer.standard(sdp: videoSDP)
        let server = try await ScriptedRTSPServer { request in request.method == "PLAY" ? standard(request) + media : standard(request) }
        let client = client(server)
        _ = try await client.connect()
        let collected = await collect(try await client.play(), timeout: .seconds(5)) { videoFrameCount($0) >= 110 }
        await client.close()
        #expect(collected.error == nil)
        #expect(collected.video.count == 110)
        #expect(zip(collected.video.dropFirst(), collected.video).allSatisfy { $0.pts > $1.pts })
    }

    @Test func absurdSDPClockRateIsTreatedAs90kHz() async throws {
        let sdp = videoSDP.replacingOccurrences(of: "H264/90000", with: "H264/5000000000000000000")
        let media = (0..<3).map { framedRTP(sequence: UInt16($0), timestamp: UInt32($0 * 3000), payload: h264NAL(type: $0 == 0 ? 5 : 1, size: 50)) }
        let standard = ScriptedRTSPServer.standard(sdp: sdp)
        let server = try await ScriptedRTSPServer { request in request.method == "PLAY" ? standard(request) + media : standard(request) }
        let client = client(server)
        let info = try await client.connect()
        #expect(info.tracks.first?.clockRate == 90_000)
        let collected = await collect(try await client.play(), timeout: .seconds(5)) { videoFrameCount($0) >= 3 }
        await client.close()
        #expect(collected.video.map(\.pts.value) == [0, 3000, 6000])
    }

    @Test func concurrentPlayIsRejectedWithoutBreakingTheFirst() async throws {
        let media = (0..<5).map { framedRTP(sequence: UInt16($0), timestamp: UInt32($0 * 3600), payload: h264NAL(type: $0 == 0 ? 5 : 1, size: 50)) }
        let standard = ScriptedRTSPServer.standard(sdp: videoSDP)
        let server = try await ScriptedRTSPServer { request in request.method == "PLAY" ? standard(request) + media : standard(request) }
        let client = client(server)
        _ = try await client.connect()
        async let first = outcome { try await client.play() }
        async let second = outcome { try await client.play() }
        let results = await [first, second]
        let streams = results.compactMap { try? $0.get() }
        #expect(streams.count == 1)
        #expect(results.contains { if case .failure(RTSPError.protocolError) = $0 { true } else { false } })
        let stream = try #require(streams.first)
        let collected = await collect(stream, timeout: .seconds(5)) { videoFrameCount($0) >= 5 }
        await client.close()
        #expect(collected.video.count == 5)
        #expect(server.requests.filter { $0.method == "PLAY" }.count == 1)
    }

    @Test func sendonlyAudioWithoutBackchannelRequestIsReceived() async throws {
        let sdp = videoAudioSDP.replacingOccurrences(of: "a=control:track2", with: "a=control:track2\na=sendonly")
        let media = [framedRTP(sequence: 0, timestamp: 0, payload: h264NAL(type: 5, size: 50)),
                     framedRTP(channel: 2, payloadType: 0, sequence: 7, timestamp: 800, ssrc: 9, payload: filler(160)),
                     framedRTP(channel: 2, payloadType: 0, sequence: 8, timestamp: 960, ssrc: 9, payload: filler(160))]
        let standard = ScriptedRTSPServer.standard(sdp: sdp)
        let server = try await ScriptedRTSPServer { request in request.method == "PLAY" ? standard(request) + media : standard(request) }
        let client = client(server)
        let info = try await client.connect()
        #expect(info.tracks.map(\.kind) == [.video, .audio])
        #expect(info.audioFormat == AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1))
        let collected = await collect(try await client.play(), timeout: .seconds(5)) { $0.count >= 3 }
        await client.close()
        #expect(collected.audio.count == 2)
        #expect(server.requests.filter { $0.method == "SETUP" }.count == 2)
    }

    @Test func interleavedPacketizationModeIsUnsupported() async throws {
        let sdp = videoSDP.replacingOccurrences(of: "packetization-mode=1", with: "packetization-mode=2")
        let server = try await ScriptedRTSPServer(handler: ScriptedRTSPServer.standard(sdp: sdp))
        await #expect(throws: RTSPError.unsupportedCodec("H264 packetization-mode=2")) { try await client(server).connect() }
    }

    @Test(arguments: [461, 500])
    func failedAudioSetupIsSkipped(_ status: Int) async throws {
        let standard = ScriptedRTSPServer.standard(sdp: videoAudioSDP)
        let media = (0..<3).map { framedRTP(sequence: UInt16($0), timestamp: UInt32($0 * 3600), payload: h264NAL(type: $0 == 0 ? 5 : 1, size: 50)) }
        let server = try await ScriptedRTSPServer { request in
            if request.method == "SETUP", request.uri.hasSuffix("track2") { return [ScriptedRTSPServer.response(status, "No", request)] }
            return request.method == "PLAY" ? standard(request) + media : standard(request)
        }
        let client = client(server)
        let info = try await client.connect()
        #expect(info.audioFormat == nil)
        #expect(info.videoFormat?.width == 640)
        let collected = await collect(try await client.play(), timeout: .seconds(5)) { videoFrameCount($0) >= 3 }
        await client.close()
        #expect(collected.video.count == 3)
    }

    @Test func udpTransportAnswerIsAProtocolErrorAndTearsDown() async throws {
        let server = try await ScriptedRTSPServer { request in
            switch request.method {
            case "DESCRIBE":
                [ScriptedRTSPServer.response(200, "OK", request, headers: [("Content-Type", "application/sdp")], body: videoSDP)]
            case "SETUP":
                [ScriptedRTSPServer.response(200, "OK", request, headers: [("Session", "S1"),
                                                                           ("Transport", "RTP/AVP;unicast;client_port=5000-5001;server_port=6970-6971")])]
            default:
                [ScriptedRTSPServer.response(200, "OK", request)]
            }
        }
        await #expect(throws: RTSPError.self) { try await client(server).connect() }
        #expect(await eventually(timeout: .seconds(2)) { server.requests.last?.method == "TEARDOWN" })
    }

    @Test func playFailureTearsDownTheSession() async throws {
        let standard = ScriptedRTSPServer.standard(sdp: videoSDP)
        let server = try await ScriptedRTSPServer { request in
            request.method == "PLAY" ? [ScriptedRTSPServer.response(500, "Internal", request)] : standard(request)
        }
        let client = client(server)
        _ = try await client.connect()
        await #expect(throws: RTSPError.badStatus(500)) { try await client.play() }
        #expect(await eventually(timeout: .seconds(2)) { server.requests.last?.method == "TEARDOWN" })
        #expect(server.requests.last?.headers["Session"] == "S1")
    }

    @Test func unansweredSetupAfterTheSessionExistsTearsDown() async throws {
        let standard = ScriptedRTSPServer.standard(sdp: videoAudioSDP)
        let server = try await ScriptedRTSPServer { request in
            request.method == "SETUP" && request.uri.hasSuffix("track2") ? [] : standard(request)
        }
        await #expect(throws: RTSPError.timeout) { try await client(server, timeout: .milliseconds(500)).connect() }
        #expect(await eventually(timeout: .seconds(2)) { server.requests.last?.method == "TEARDOWN" })
    }

    @Test(arguments: [400, 405, 454, 501])
    func getParameterKeepaliveFallsBackToOptionsAtRuntime(_ status: Int) async throws {
        let server = try await ScriptedRTSPServer { request in
            switch request.method {
            case "OPTIONS":
                return [ScriptedRTSPServer.response(200, "OK", request, headers: [("Public", "OPTIONS, DESCRIBE, SETUP, PLAY, GET_PARAMETER")])]
            case "DESCRIBE":
                return [ScriptedRTSPServer.response(200, "OK", request, headers: [("Content-Type", "application/sdp")], body: videoSDP)]
            case "SETUP":
                return [ScriptedRTSPServer.response(200, "OK", request, headers: [("Session", "S1;timeout=2"), ("Transport", request.headers["Transport"] ?? "")])]
            case "GET_PARAMETER":
                return [ScriptedRTSPServer.response(status, "No", request)]
            default:
                return [ScriptedRTSPServer.response(200, "OK", request)]
            }
        }
        let client = RTSPClient(configuration: RTSPConfiguration(url: server.url, credentials: nil, timeout: .seconds(30)), transport: AppleNetworkTransport())
        _ = try await client.connect()
        let stream = try await client.play()
        #expect(await eventually(timeout: .seconds(4)) {
            server.requests.drop { $0.method != "GET_PARAMETER" }.contains { $0.method == "OPTIONS" && $0.headers["Session"] != nil }
        })
        await client.close()
        withExtendedLifetime(stream) {}
        #expect(server.requests.filter { $0.method == "GET_PARAMETER" }.count == 1)
    }

    @Test func staleDigestNonceIsRetried() async throws {
        let server = try await ScriptedRTSPServer { request in
            let authorization = request.headers["Authorization"] ?? ""
            func challenge(_ nonce: String, stale: Bool) -> [Data] {
                [ScriptedRTSPServer.response(401, "Unauthorized", request,
                                             headers: [("WWW-Authenticate", "Digest realm=\"cam\", nonce=\"\(nonce)\"\(stale ? ", stale=TRUE" : "")")])]
            }
            switch request.method {
            case "OPTIONS":
                return [ScriptedRTSPServer.response(200, "OK", request)]
            case "DESCRIBE" where authorization.isEmpty:
                return challenge("first", stale: false)
            case "DESCRIBE" where authorization.contains("nonce=\"first\""):
                return challenge("second", stale: true)
            case "DESCRIBE" where authorization.contains("nonce=\"second\""):
                return ScriptedRTSPServer.standard(sdp: videoSDP)(request)
            case "DESCRIBE":
                return challenge("other", stale: false)
            default:
                return ScriptedRTSPServer.standard(sdp: videoSDP)(request)
            }
        }
        let client = RTSPClient(configuration: RTSPConfiguration(url: server.url, credentials: HTTPCredentials(username: "u", password: "p"),
                                                                 timeout: .seconds(3)),
                                transport: AppleNetworkTransport())
        let info = try await client.connect()
        await client.close()
        #expect(info.videoFormat?.width == 640)
        #expect(server.requests.filter { $0.method == "DESCRIBE" }.count == 3)
        #expect(server.requests.first { $0.method == "SETUP" }?.headers["Authorization"]?.contains("nonce=\"second\"") == true)
    }

    @Test func videoStallWhileAudioAndRTCPFlowFailsTheStream() async throws {
        let server = try await ScriptedRTSPServer(handler: ScriptedRTSPServer.standard(sdp: videoAudioSDP)) { send in
            for i in 0..<5 {
                guard await send(framedRTP(sequence: UInt16(i), timestamp: UInt32(i * 3600), payload: h264NAL(type: i == 0 ? 5 : 1, size: 50))) else { return }
            }
            // The video encoder freezes; audio and sender reports keep coming.
            for i in 0..<200 {
                guard await send(framedRTP(channel: 2, payloadType: 0, sequence: UInt16(i), timestamp: UInt32(i * 160), ssrc: 9, payload: filler(160))),
                      await send(RTSPRequestSerializer.interleaved(channel: 1, payload: senderReportPacket())) else { return }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        let client = client(server, timeout: .seconds(1))
        _ = try await client.connect()
        let started = ContinuousClock.now
        let collected = await collect(try await client.play(), timeout: .seconds(6))
        #expect(collected.ended)
        #expect(collected.error as? RTSPError == .timeout)
        #expect(collected.video.count == 5)
        #expect(collected.audio.count > 10)
        #expect(ContinuousClock.now - started < .seconds(4))
    }

    @Test func videoThatNeverDecodesFailsTheStream() async throws {
        let server = try await ScriptedRTSPServer(handler: ScriptedRTSPServer.standard(sdp: videoSDP)) { send in
            // Delta frames only: packets keep arriving, but no frame can ever be delivered.
            for i in 0..<300 {
                guard await send(framedRTP(sequence: UInt16(i), timestamp: UInt32(i * 3600), payload: h264NAL(type: 1, size: 50))) else { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let client = RTSPClient(configuration: RTSPConfiguration(url: server.url, credentials: nil, timeout: .seconds(1)),
                                transport: AppleNetworkTransport(), videoFrameTimeout: .milliseconds(1500))
        _ = try await client.connect()
        let started = ContinuousClock.now
        let collected = await collect(try await client.play(), timeout: .seconds(5))
        #expect(collected.error as? RTSPError == .timeout)
        #expect(collected.video.isEmpty)
        #expect(ContinuousClock.now - started > .seconds(1.2))
        #expect(ContinuousClock.now - started < .seconds(4))
    }
}

@Suite(.timeLimit(.minutes(1))) struct RTSPClientScriptedTests {
    @Test func describeNotFound() async throws {
        let server = try await ScriptedRTSPServer { request in
            [ScriptedRTSPServer.response(request.method == "DESCRIBE" ? 404 : 200, "X", request)]
        }
        await #expect(throws: RTSPError.notFound) { try await client(server).connect() }
    }

    @Test func describeServerError() async throws {
        let server = try await ScriptedRTSPServer { request in
            [ScriptedRTSPServer.response(request.method == "DESCRIBE" ? 500 : 200, "X", request)]
        }
        await #expect(throws: RTSPError.badStatus(500)) { try await client(server).connect() }
    }

    @Test func audioOnlyHasNoVideoTrack() async throws {
        let server = try await ScriptedRTSPServer(handler: ScriptedRTSPServer.standard(sdp: "v=0\nm=audio 0 RTP/AVP 0\na=control:a\n"))
        await #expect(throws: RTSPError.noVideoTrack) { try await client(server).connect() }
    }

    @Test func unsupportedVideoCodec() async throws {
        let server = try await ScriptedRTSPServer(handler: ScriptedRTSPServer.standard(sdp: "v=0\nm=video 0 RTP/AVP 26\na=control:v\n"))
        await #expect(throws: RTSPError.unsupportedCodec("JPEG")) { try await client(server).connect() }
    }

    /// Review finding (W4 BridgeSupport, round 4): the rtpmap encoding name of a DESCRIBE body (up to 4 MiB) went into
    /// `RTSPError.unsupportedCodec` whole, control characters included, and from there through `Redact.string` into the
    /// log and the Add Camera sheet. Camera text in an error is at most 200 characters, without control characters.
    @Test func longCodecNameIsCutInTheError() async throws {
        let name = String(repeating: "X", count: 32_000) + "\u{1B}[2J\u{7}"
        let sdp = "v=0\nm=video 0 RTP/AVP 96\na=rtpmap:96 \(name)/90000\na=control:v\n"
        let server = try await ScriptedRTSPServer(handler: ScriptedRTSPServer.standard(sdp: sdp))
        let error = await #expect(throws: RTSPError.self) { try await client(server).connect() }
        guard case .unsupportedCodec(let codec) = error else {
            Issue.record("expected unsupportedCodec, got \(String(describing: error))")
            return
        }
        #expect(codec.count <= 200)
        #expect(codec.hasPrefix("XXXXXXXX"))
        #expect(!codec.unicodeScalars.contains { $0.properties.generalCategory == .control })
    }

    /// Same finding: the transport a camera answers SETUP with is camera text too.
    @Test func longTransportIsCutInTheError() async throws {
        let transport = "RTP/AVP/" + String(repeating: "Z", count: 20_000) + "\tZ;unicast;client_port=5000-5001"
        let server = try await ScriptedRTSPServer { request in
            switch request.method {
            case "DESCRIBE":
                [ScriptedRTSPServer.response(200, "OK", request, headers: [("Content-Type", "application/sdp")], body: videoSDP)]
            case "SETUP":
                [ScriptedRTSPServer.response(200, "OK", request, headers: [("Session", "S1"), ("Transport", transport)])]
            default:
                [ScriptedRTSPServer.response(200, "OK", request)]
            }
        }
        let error = await #expect(throws: RTSPError.self) { try await client(server).connect() }
        guard case .protocolError(let message) = error else {
            Issue.record("expected protocolError, got \(String(describing: error))")
            return
        }
        #expect(message.hasPrefix("camera answered SETUP with a non-TCP transport (RTP/AVP/ZZZZ"))
        #expect(message.count <= 260)
        #expect(!message.unicodeScalars.contains { $0.properties.generalCategory == .control })
    }

    @Test func unansweredRequestTimesOut() async throws {
        let server = try await ScriptedRTSPServer { request in
            request.method == "OPTIONS" ? [ScriptedRTSPServer.response(200, "OK", request)] : []
        }
        let started = ContinuousClock.now
        await #expect(throws: RTSPError.timeout) { try await client(server, timeout: .milliseconds(500)).connect() }
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func udpOnlyServerIsAProtocolError() async throws {
        let server = try await ScriptedRTSPServer { request in
            switch request.method {
            case "DESCRIBE": [ScriptedRTSPServer.response(200, "OK", request, headers: [("Content-Type", "application/sdp")], body: videoSDP)]
            case "SETUP": [ScriptedRTSPServer.response(461, "Unsupported Transport", request)]
            default: [ScriptedRTSPServer.response(200, "OK", request)]
            }
        }
        await #expect(throws: RTSPError.self) { try await client(server).connect() }
    }

    @Test func junkBeforeResponsesIsTolerated() async throws {
        let standard = ScriptedRTSPServer.standard(sdp: videoSDP)
        let server = try await ScriptedRTSPServer { request in
            [Data([0x00, 0xFF, 0x0D, 0x0A])] + standard(request)
        }
        let info = try await client(server).connect()
        #expect(info.videoFormat?.width == 640)
    }

    @Test func interleavedDataBeforePlayResponseAndServerRequests() async throws {
        let standard = ScriptedRTSPServer.standard(sdp: videoSDP)
        let idr = h264NAL(type: 5, size: 200)
        let packet = RTPPacket(marker: true, payloadType: 96, sequenceNumber: 1, timestamp: 1234, ssrc: 1, payload: idr).serialized()
        var framed = Data([0x24, 0x00, UInt8(packet.count >> 8), UInt8(packet.count & 0xFF)])
        framed.append(packet)
        let frame = framed
        let server = try await ScriptedRTSPServer { request in
            guard request.method == "PLAY" else { return standard(request) }
            // Media first, then the PLAY response, then a server-initiated keepalive request.
            return [frame] + standard(request) + [Data("GET_PARAMETER rtsp://127.0.0.1/cam RTSP/1.0\r\nCSeq: 77\r\nSession: S1\r\n\r\n".utf8)]
        }
        let client = client(server)
        _ = try await client.connect()
        let collected = await collect(try await client.play(), timeout: .seconds(3)) { videoFrameCount($0) >= 1 }
        #expect(collected.video.first?.nalUnits == [idr])
        #expect(collected.video.first?.format.width == 640)
        #expect(await eventually(timeout: .seconds(2)) { server.responsesFromClient.contains { $0.cseq == 77 && $0.status == 200 } })
        await client.close()
    }

    @Test func sessionTimeoutDrivesKeepaliveInterval() async throws {
        let counter = Mutex(0)
        let server = try await ScriptedRTSPServer { request in
            switch request.method {
            case "DESCRIBE":
                return [ScriptedRTSPServer.response(200, "OK", request, headers: [("Content-Type", "application/sdp")], body: videoSDP)]
            case "SETUP":
                return [ScriptedRTSPServer.response(200, "OK", request, headers: [("Session", "S1;timeout=2"),
                                                                                   ("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1")])]
            case "GET_PARAMETER":
                counter.withLock { $0 += 1 }
                return [ScriptedRTSPServer.response(200, "OK", request)]
            default:
                return [ScriptedRTSPServer.response(200, "OK", request)]
            }
        }
        let client = RTSPClient(configuration: RTSPConfiguration(url: server.url, credentials: nil, timeout: .seconds(30)),
                                transport: AppleNetworkTransport())
        _ = try await client.connect()
        let stream = try await client.play()   // kept alive: dropping the stream closes the session
        try await Task.sleep(for: .milliseconds(2600))
        await client.close()
        withExtendedLifetime(stream) {}
        #expect(counter.withLock { $0 } >= 2)
    }

    @Test func useAfterCloseFails() async throws {
        let server = try await ScriptedRTSPServer(handler: ScriptedRTSPServer.standard(sdp: videoSDP))
        let client = client(server)
        _ = try await client.connect()
        await client.close()
        await #expect(throws: (any Error).self) { try await client.play() }
        await #expect(throws: (any Error).self) { try await client.connect() }
    }
}

/// A Digest 401 with a fresh nonce per request (derived from its CSeq), as live555 answers every failed
/// authentication; `stale` is the raw parameter value (nil: absent).
private func rotatingNonceChallenge(_ request: RTSPRequest, stale: String? = nil) -> [Data] {
    let nonce = "n\(request.headers["CSeq"] ?? "0")"
    let staleParameter = stale.map { ", stale=\($0)" } ?? ""
    return [ScriptedRTSPServer.response(401, "Unauthorized", request,
                                        headers: [("WWW-Authenticate", "Digest realm=\"cam\", nonce=\"\(nonce)\"\(staleParameter)")])]
}

/// Wrong credentials must cost one authenticated attempt per connect (RFC 2617 §3.2.1 / RFC 7616 §3.3: a challenge
/// whose `stale` is absent or false rejects the username/password), so a camera's illegal-login lockout is not
/// reached by the client's own retries.
@Suite(.timeLimit(.minutes(1))) struct RTSPClientAuthenticationRetryTests {
    private func client(_ server: ScriptedRTSPServer) -> RTSPClient {
        RTSPClient(configuration: RTSPConfiguration(url: server.url, credentials: HTTPCredentials(username: "u", password: "p"),
                                                    timeout: .seconds(3)),
                   transport: AppleNetworkTransport())
    }

    @Test(arguments: [nil, "\"FALSE\"", "false"] as [String?])
    func wrongPasswordWithRotatingNonceCostsOneAuthenticatedDescribe(stale: String?) async throws {
        let server = try await ScriptedRTSPServer { request in
            request.method == "DESCRIBE" ? rotatingNonceChallenge(request, stale: stale) : ScriptedRTSPServer.standard(sdp: videoSDP)(request)
        }
        let client = client(server)
        await #expect(throws: RTSPError.unauthorized) { try await client.connect() }
        await client.close()
        let describes = server.requests.filter { $0.method == "DESCRIBE" }
        #expect(describes.count == 2)
        #expect(describes.filter { $0.headers["Authorization"] != nil }.count == 1)
    }

    @Test func wrongPasswordOnChallengedOptionsCostsOneAuthenticatedAttempt() async throws {
        let server = try await ScriptedRTSPServer { rotatingNonceChallenge($0) }
        let client = client(server)
        await #expect(throws: RTSPError.unauthorized) { try await client.connect() }
        await client.close()
        #expect(server.requests.map(\.method) == ["OPTIONS", "OPTIONS"])
        #expect(server.requests.filter { $0.headers["Authorization"] != nil }.count == 1)
    }

    @Test func rejectedBasicSwitchesToDigest() async throws {
        let server = try await ScriptedRTSPServer { request in
            let authorization = request.headers["Authorization"] ?? ""
            switch request.method {
            case "DESCRIBE" where authorization.isEmpty:
                return [ScriptedRTSPServer.response(401, "Unauthorized", request, headers: [("WWW-Authenticate", "Basic realm=\"cam\"")])]
            case "DESCRIBE" where authorization.hasPrefix("Basic "):
                return [ScriptedRTSPServer.response(401, "Unauthorized", request,
                                                    headers: [("WWW-Authenticate", "Digest realm=\"cam\", nonce=\"d1\"")])]
            default:
                return ScriptedRTSPServer.standard(sdp: videoSDP)(request)
            }
        }
        let client = client(server)
        _ = try await client.connect()
        await client.close()
        let describes = server.requests.filter { $0.method == "DESCRIBE" }
        #expect(describes.count == 3)
        #expect(describes.last?.headers["Authorization"]?.hasPrefix("Digest ") == true)
    }

    @Test func rejectedDigestIsNotRetriedAsBasic() async throws {
        let server = try await ScriptedRTSPServer { request in
            switch request.method {
            case "DESCRIBE" where request.headers["Authorization"] == nil:
                return [ScriptedRTSPServer.response(401, "Unauthorized", request,
                                                    headers: [("WWW-Authenticate", "Digest realm=\"cam\", nonce=\"d1\"")])]
            case "DESCRIBE":
                return [ScriptedRTSPServer.response(401, "Unauthorized", request, headers: [("WWW-Authenticate", "Basic realm=\"cam\"")])]
            default:
                return ScriptedRTSPServer.standard(sdp: videoSDP)(request)
            }
        }
        let client = client(server)
        await #expect(throws: RTSPError.unauthorized) { try await client.connect() }
        await client.close()
        let describes = server.requests.filter { $0.method == "DESCRIBE" }
        #expect(describes.count == 2)
        #expect(!describes.contains { $0.headers["Authorization"]?.hasPrefix("Basic ") == true })
    }

    /// A camera that renews its nonce without `stale` after accepting the credentials (they are known to be right).
    @Test func freshNonceAfterAcceptedCredentialsIsRetried() async throws {
        let server = try await ScriptedRTSPServer { request in
            let authorization = request.headers["Authorization"] ?? ""
            switch request.method {
            case "DESCRIBE" where authorization.isEmpty:
                return [ScriptedRTSPServer.response(401, "Unauthorized", request,
                                                    headers: [("WWW-Authenticate", "Digest realm=\"cam\", nonce=\"first\"")])]
            case "SETUP" where authorization.contains("nonce=\"first\""):
                return [ScriptedRTSPServer.response(401, "Unauthorized", request,
                                                    headers: [("WWW-Authenticate", "Digest realm=\"cam\", nonce=\"second\"")])]
            default:
                return ScriptedRTSPServer.standard(sdp: videoSDP)(request)
            }
        }
        let client = client(server)
        _ = try await client.connect()
        await client.close()
        let setups = server.requests.filter { $0.method == "SETUP" }
        #expect(setups.count == 2)
        #expect(setups.last?.headers["Authorization"]?.contains("nonce=\"second\"") == true)
    }

    /// Credentials the camera stops accepting mid-session (changed password) cost one retry, not one per new nonce.
    @Test func rejectionAfterAcceptedCredentialsIsRetriedOnce() async throws {
        let server = try await ScriptedRTSPServer { request in
            switch request.method {
            case "DESCRIBE" where request.headers["Authorization"] == nil:
                return [ScriptedRTSPServer.response(401, "Unauthorized", request,
                                                    headers: [("WWW-Authenticate", "Digest realm=\"cam\", nonce=\"first\"")])]
            case "SETUP":
                return rotatingNonceChallenge(request)
            default:
                return ScriptedRTSPServer.standard(sdp: videoSDP)(request)
            }
        }
        let client = client(server)
        await #expect(throws: RTSPError.unauthorized) { try await client.connect() }
        await client.close()
        #expect(server.requests.filter { $0.method == "SETUP" }.count == 2)
    }
}

/// Review finding (W4 BridgeSupport, round 4): a 401 offering only Basic switched the client from Digest to Basic, also
/// in the middle of a session, so a host impersonating the camera (ARP or DHCP spoofing, plaintext RTSP) got the
/// password with one answer. Once the camera asked for Digest, neither the session nor a later session of the same
/// `RTSPMediaSource` (its reconnects) answers Basic; a camera that only ever asks for Basic still gets it
/// (`RTSPClientAuthenticationTests`).
@Suite(.timeLimit(.minutes(1))) struct RTSPClientDowngradeTests {
    private let credentials = HTTPCredentials(username: "admin", password: "pa55")

    private static func challenge(_ request: RTSPRequest, _ value: String) -> [Data] {
        [ScriptedRTSPServer.response(401, "Unauthorized", request, headers: [("WWW-Authenticate", value)])]
    }

    private static func sentBasic(_ server: ScriptedRTSPServer) -> Bool {
        server.requests.contains { $0.headers["Authorization"]?.lowercased().hasPrefix("basic") == true }
    }

    @Test func basicChallengeAfterDigestInTheSameSessionIsNotAnswered() async throws {
        let standard = ScriptedRTSPServer.standard(sdp: videoSDP)
        let server = try await ScriptedRTSPServer { request in
            let authorization = request.headers["Authorization"] ?? ""
            switch request.method {
            case "SETUP":   // the impersonator takes over after DESCRIBE
                return authorization.hasPrefix("Basic ") ? standard(request) : Self.challenge(request, #"Basic realm="cam""#)
            case "DESCRIBE" where !authorization.hasPrefix("Digest "):
                return Self.challenge(request, #"Digest realm="cam", nonce="n1""#)
            default:
                return standard(request)
            }
        }
        let client = RTSPClient(configuration: RTSPConfiguration(url: server.url, credentials: credentials, timeout: .seconds(3)),
                                transport: AppleNetworkTransport())
        await #expect(throws: RTSPError.unauthorized) { try await client.connect() }
        await client.close()
        #expect(server.requests.contains { $0.method == "DESCRIBE" && $0.headers["Authorization"]?.hasPrefix("Digest ") == true })
        #expect(!Self.sentBasic(server))
    }

    @Test func laterSessionsOfTheSourceDoNotAnswerBasic() async throws {
        let impersonating = Box(false)
        let standard = ScriptedRTSPServer.standard(sdp: videoSDP)
        let server = try await ScriptedRTSPServer { request in
            let authorization = request.headers["Authorization"] ?? ""
            if impersonating.value {
                return authorization.hasPrefix("Basic ") ? standard(request) : Self.challenge(request, #"Basic realm="cam""#)
            }
            if request.method != "OPTIONS", !authorization.hasPrefix("Digest ") {
                return Self.challenge(request, #"Digest realm="cam", nonce="n1""#)
            }
            return standard(request)
        }
        let source = RTSPMediaSource(configuration: RTSPConfiguration(url: server.url, credentials: credentials, timeout: .seconds(3)),
                                     displayName: "downgrade", transport: AppleNetworkTransport())
        _ = try await source.samples()
        impersonating.set(true)
        await #expect(throws: RTSPError.unauthorized) { _ = try await source.samples() }
        await source.stop()
        #expect(server.requests.contains { $0.method == "PLAY" && $0.headers["Authorization"]?.hasPrefix("Digest ") == true })
        #expect(!Self.sentBasic(server))
    }
}
#endif
