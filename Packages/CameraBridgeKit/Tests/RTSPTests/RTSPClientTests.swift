// The loopback server and client use PlatformApple's Network.framework transport: macOS only.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import MediaCore
import RTP
import Synchronization
import TestSupport
import Testing
@testable import RTSP

private let h264Format = RTSPSessionDescription.makeH264Format(sps: RealParameterSets.h264Main640x360.sps,
                                                              pps: RealParameterSets.h264Main640x360.pps)
private let credentials = HTTPCredentials(username: "admin", password: "p@ss:word")

private func makeServer(_ configure: (inout RTSPTestServer.Configuration) -> Void = { _ in },
                        source: SyntheticNALSource.Configuration = SyntheticNALSource.Configuration(format: h264Format))
    async throws -> RTSPTestServer {
    var configuration = RTSPTestServer.Configuration()
    configure(&configuration)
    let server = RTSPTestServer(source: SyntheticNALSource(configuration: source), transport: PlatformNetworkTransport(), configuration: configuration)
    try await server.start()
    return server
}

private func makeClient(_ server: RTSPTestServer, credentials: HTTPCredentials? = nil, backchannel: Bool = false,
                        timeout: Duration = .seconds(5)) -> RTSPClient {
    RTSPClient(configuration: RTSPConfiguration(url: server.url, credentials: credentials, requestBackchannel: backchannel, timeout: timeout),
               transport: PlatformNetworkTransport())
}

/// Every frame's NAL is exactly what the synthetic source produced for its index.
private func expectIntact(_ frames: [EncodedVideoFrame], source: SyntheticNALSource.Configuration, sourceLocation: SourceLocation = #_sourceLocation) {
    for frame in frames {
        guard let index = SyntheticNALSource.frameIndex(of: frame) else {
            Issue.record("frame without index", sourceLocation: sourceLocation)
            continue
        }
        let isKeyframe = index % source.keyframeInterval == 0
        #expect(frame.isKeyframe == isKeyframe, sourceLocation: sourceLocation)
        let expected = SyntheticNALSource.videoNAL(index: index, isKeyframe: isKeyframe,
                                                   size: isKeyframe ? source.keyframeSize : source.frameSize, codec: source.format.codec)
        #expect(frame.nalUnits == [expected], sourceLocation: sourceLocation)
    }
}

private func expectStrictlyIncreasing(_ times: [MediaTime], sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(zip(times.dropFirst(), times).allSatisfy { $0 > $1 }, sourceLocation: sourceLocation)
}

@Suite(.timeLimit(.minutes(1))) struct RTSPClientStreamingTests {
    @Test func tenSecondsOfVideoAndAudio() async throws {
        let source = SyntheticNALSource.Configuration(format: h264Format, fps: 25, keyframeInterval: 25, keyframeSize: 6000, frameSize: 900,
                                                      audio: AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1))
        let server = try await makeServer({ $0.audio = AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1) }, source: source)
        let client = makeClient(server)
        let info = try await client.connect()
        #expect(info.tracks.map(\.kind) == [.video, .audio])
        #expect(info.videoFormat?.width == 640)
        #expect(info.videoFormat?.height == 360)
        #expect(info.audioFormat == AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1))

        let started = Date()
        let collected = await collect(try await client.play(), timeout: .seconds(10.5))
        await client.close()
        await server.stop()

        let video = collected.video
        #expect(video.count >= 215, "received \(video.count) frames in 10 s at 25 fps")
        #expect(video.first?.isKeyframe == true)
        expectStrictlyIncreasing(video.map(\.pts))
        #expect(video.allSatisfy { $0.pts.timescale == 90_000 })
        #expect(video.first?.pts.value ?? -1 >= 0)
        expectIntact(video, source: source)
        let indices = video.compactMap(SyntheticNALSource.frameIndex(of:))
        #expect(zip(indices.dropFirst(), indices).allSatisfy { $0 == $1 + 1 }, "no frame lost on a clean stream")
        // Source spacing (40 ms) is kept.
        let deltas = zip(video.dropFirst(), video).map { $0.pts.value - $1.pts.value }
        #expect(deltas.allSatisfy { $0 == 3600 })
        #expect(video.allSatisfy { abs($0.wallClock.timeIntervalSince(started)) < 12 })
        #expect(video.map(\.format.width).allSatisfy { $0 == 640 })

        let audio = collected.audio
        #expect(audio.count >= 420)
        expectStrictlyIncreasing(audio.map(\.pts))
        #expect(audio.allSatisfy { $0.pts.timescale == 8000 && $0.sampleCount == 160 && $0.format.codec == .pcmu })
        let audioIndices = audio.compactMap(SyntheticNALSource.audioIndex(of:))
        #expect(zip(audioIndices.dropFirst(), audioIndices).allSatisfy { $0 == $1 + 1 })
        #expect(audio.allSatisfy { $0.data == SyntheticNALSource.audioUnit(index: SyntheticNALSource.audioIndex(of: $0) ?? -1, format: $0.format).data })
        // Audio and video share one timeline: the first audio unit is within 200 ms of the first video frame.
        if let firstAudio = audio.first, let firstVideo = video.first {
            #expect(abs(firstAudio.pts.seconds - firstVideo.pts.seconds) < 0.2)
        }

        let methods = server.requests.map(\.method)
        #expect(Array(methods.prefix(5)) == ["OPTIONS", "DESCRIBE", "SETUP", "SETUP", "PLAY"])
        #expect(methods.last == "TEARDOWN")
        let setups = server.requests.filter { $0.method == "SETUP" }
        #expect(setups.map { $0.headers["Transport"] } == ["RTP/AVP/TCP;unicast;interleaved=0-1", "RTP/AVP/TCP;unicast;interleaved=2-3"])
        #expect(setups[0].uri == server.url.absoluteString + "/trackID=0")
        #expect(setups[1].headers["Session"] != nil)
        #expect(server.requests.allSatisfy { $0.headers["User-Agent"] == "CameraBridge/1.0" })
    }

    @Test func aacWithSeveralUnitsPerPacket() async throws {
        let aac = AudioFormat.aacLC(sampleRate: 16_000, channels: 1)
        let source = SyntheticNALSource.Configuration(format: h264Format, audio: aac)
        let server = try await makeServer({ $0.audio = aac; $0.aacUnitsPerPacket = 3 }, source: source)
        let client = makeClient(server)
        let info = try await client.connect()
        #expect(info.audioFormat?.codec == .aac)
        #expect(info.audioFormat?.audioSpecificConfig == aac.audioSpecificConfig)
        let collected = await collect(try await client.play(), timeout: .seconds(10)) { $0.count > 60 && videoFrameCount($0) > 30 }
        await client.close()
        await server.stop()
        let audio = collected.audio
        #expect(audio.count >= 20)
        let indices = audio.compactMap(SyntheticNALSource.audioIndex(of:))
        #expect(zip(indices.dropFirst(), indices).allSatisfy { $0 == $1 + 1 })
        let deltas = zip(audio.dropFirst(), audio).map { $0.pts.value - $1.pts.value }
        #expect(deltas.allSatisfy { $0 == 1024 })
        #expect(audio.allSatisfy { $0.pts.timescale == 16_000 && $0.format.audioSpecificConfig == aac.audioSpecificConfig })
    }

    @Test func inBandParameterSetsOnly() async throws {
        let server = try await makeServer { $0.parameterSetsInSDP = false; $0.parameterSetMode = .separate }
        let client = makeClient(server)
        let info = try await client.connect()
        #expect(info.videoFormat == nil)
        let collected = await collect(try await client.play(), timeout: .seconds(10)) { videoFrameCount($0) >= 30 }
        await client.close()
        await server.stop()
        #expect(collected.video.count >= 30)
        #expect(collected.video.first?.isKeyframe == true)
        #expect(collected.video.allSatisfy { $0.format.width == 640 && $0.format.parameterSets == h264Format.parameterSets })
    }

    @Test func hevcStream() async throws {
        let sets = RealParameterSets.hevcMain640x360
        let format = RTSPSessionDescription.makeHEVCFormat(vps: sets.vps, sps: sets.sps, pps: sets.pps)
        let source = SyntheticNALSource.Configuration(format: format, keyframeSize: 5000, frameSize: 2000)
        let server = try await makeServer({ _ in }, source: source)
        let client = makeClient(server)
        let info = try await client.connect()
        #expect(info.tracks.first?.encoding == "H265")
        #expect(info.videoFormat?.codec == .hevc)
        let collected = await collect(try await client.play(), timeout: .seconds(10)) { videoFrameCount($0) >= 30 }
        await client.close()
        await server.stop()
        #expect(collected.video.count >= 30)
        #expect(collected.video.first?.isKeyframe == true)
        #expect(collected.video.allSatisfy { $0.format.codec == .hevc && $0.format.width == 640 })
        expectIntact(collected.video, source: source)
    }

    @Test func absoluteControlURLs() async throws {
        let server = try await makeServer { $0.absoluteControlURLs = true }
        let client = makeClient(server)
        _ = try await client.connect()
        _ = await collect(try await client.play(), timeout: .seconds(5)) { videoFrameCount($0) >= 2 }
        await client.close()
        await server.stop()
        #expect(server.requests.first { $0.method == "SETUP" }?.uri == server.url.absoluteString + "/trackID=0")
    }

    @Test func senderReportsDriveWallClock() async throws {
        let server = try await makeServer { $0.senderReportClockOffset = .milliseconds(-1500) }
        let client = makeClient(server)
        _ = try await client.connect()
        let stream = try await client.play()
        let box = WallClockOffsets()
        let collected = await collect(stream, timeout: .seconds(10)) { samples in
            if case .video(let frame)? = samples.last { box.append(Date().timeIntervalSince(frame.wallClock)) }
            return videoFrameCount(samples) >= 90
        }
        await client.close()
        await server.stop()
        #expect(collected.video.count >= 90)
        // After the first sender report, frames are stamped with the (1.5 s slow) camera clock.
        let late = box.values.suffix(20)
        #expect(late.allSatisfy { $0 > 1.2 && $0 < 1.9 }, "offsets \(Array(late))")
    }

    @Test func implausibleSenderReportClockIsIgnored() async throws {
        let server = try await makeServer { $0.senderReportClockOffset = .seconds(-3600) }
        let client = makeClient(server)
        _ = try await client.connect()
        let box = WallClockOffsets()
        _ = await collect(try await client.play(), timeout: .seconds(10)) { samples in
            if case .video(let frame)? = samples.last { box.append(Date().timeIntervalSince(frame.wallClock)) }
            return videoFrameCount(samples) >= 50
        }
        await client.close()
        await server.stop()
        #expect(box.values.allSatisfy { abs($0) < 0.5 })
    }

    @Test func teardownAndStreamEndOnClose() async throws {
        let server = try await makeServer()
        let client = makeClient(server)
        _ = try await client.connect()
        let stream = try await client.play()
        let reader = Task { await collect(stream, timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(500))
        await client.close()
        let collected = await reader.value
        #expect(collected.ended)
        #expect(collected.error == nil)
        #expect(await eventually(timeout: .seconds(2)) { server.requests.last?.method == "TEARDOWN" })
        await server.stop()
    }
}

final class WallClockOffsets: Sendable {
    private let state = Mutex<[TimeInterval]>([])
    func append(_ value: TimeInterval) { state.withLock { $0.append(value) } }
    var values: [TimeInterval] { state.withLock { $0 } }
}

@Suite(.timeLimit(.minutes(1))) struct RTSPClientAuthenticationTests {
    @Test(arguments: [RTSPTestServer.Authentication.digest, .digestWithQop, .basic])
    func correctCredentialsAreAccepted(_ authentication: RTSPTestServer.Authentication) async throws {
        let server = try await makeServer { $0.credentials = credentials; $0.authentication = authentication }
        let client = makeClient(server, credentials: credentials)
        _ = try await client.connect()
        let collected = await collect(try await client.play(), timeout: .seconds(5)) { videoFrameCount($0) >= 5 }
        await client.close()
        await server.stop()
        #expect(collected.video.count >= 5)
        let describes = server.requests.filter { $0.method == "DESCRIBE" }
        #expect(describes.count == 2)
        #expect(describes.first?.headers["Authorization"] == nil)
        let scheme = authentication == .basic ? "Basic " : "Digest "
        #expect(describes.last?.headers["Authorization"]?.hasPrefix(scheme) == true)
        // Every later request is authenticated too.
        #expect(server.requests.drop { $0.method != "SETUP" }.allSatisfy { $0.headers["Authorization"]?.hasPrefix(scheme) == true })
    }

    @Test func wrongPasswordIsUnauthorized() async throws {
        let server = try await makeServer { $0.credentials = credentials }
        let client = makeClient(server, credentials: HTTPCredentials(username: "admin", password: "wrong"))
        await #expect(throws: RTSPError.unauthorized) { try await client.connect() }
        await client.close()
        #expect(server.requests.filter { $0.method == "DESCRIBE" }.count == 2)
        await server.stop()
    }

    @Test func missingCredentialsAreUnauthorized() async throws {
        let server = try await makeServer { $0.credentials = credentials }
        let client = makeClient(server)
        await #expect(throws: RTSPError.unauthorized) { try await client.connect() }
        await server.stop()
    }

    @Test func credentialsInURLAreUsedButNeverSent() async throws {
        let server = try await makeServer { $0.credentials = credentials }
        var components = try #require(URLComponents(url: server.url, resolvingAgainstBaseURL: false))
        components.user = credentials.username
        components.password = credentials.password
        let url = try #require(components.url)
        let client = RTSPClient(configuration: RTSPConfiguration(url: url, credentials: nil), transport: PlatformNetworkTransport())
        _ = try await client.connect()
        await client.close()
        await server.stop()
        #expect(server.requests.allSatisfy { !$0.uri.contains("@") && !$0.uri.contains("admin") })
    }
}

@Suite(.timeLimit(.minutes(1))) struct RTSPClientKeepaliveTests {
    @Test func getParameterKeepsSessionAlive() async throws {
        let server = try await makeServer { $0.sessionTimeout = 2; $0.enforceSessionTimeout = true }
        let client = makeClient(server)
        _ = try await client.connect()
        let collected = await collect(try await client.play(), timeout: .seconds(4.5))
        await client.close()
        await server.stop()
        #expect(collected.error == nil)
        #expect(server.sessionTimeoutCount == 0)
        let keepalives = server.requests.filter { $0.method == "GET_PARAMETER" }
        #expect(keepalives.count >= 3)
        #expect(keepalives.allSatisfy { $0.headers["Session"] != nil })
        #expect(collected.video.count >= 60)
    }

    @Test func optionsKeepaliveWhenGetParameterIsUnsupported() async throws {
        let server = try await makeServer { $0.sessionTimeout = 2; $0.enforceSessionTimeout = true; $0.supportsGetParameter = false }
        let client = makeClient(server)
        _ = try await client.connect()
        let collected = await collect(try await client.play(), timeout: .seconds(3.5))
        await client.close()
        await server.stop()
        #expect(collected.error == nil)
        #expect(server.sessionTimeoutCount == 0)
        #expect(server.requests.filter { $0.method == "GET_PARAMETER" }.isEmpty)
        #expect(server.requests.filter { $0.method == "OPTIONS" }.count >= 3)
    }
}

@Suite(.timeLimit(.minutes(1))) struct RTSPClientFaultTests {
    @Test func fragmentLossDropsUntilNextKeyframe() async throws {
        let source = SyntheticNALSource.Configuration(format: h264Format, fps: 25, keyframeInterval: 10, keyframeSize: 6000, frameSize: 3000)
        let server = try await makeServer({ $0.faults.dropEveryNthFUFragment = 23 }, source: source)
        let client = makeClient(server)
        _ = try await client.connect()
        let collected = await collect(try await client.play(), timeout: .seconds(10)) { videoFrameCount($0) >= 30 }
        await client.close()
        await server.stop()
        let video = collected.video
        #expect(collected.error == nil)
        #expect(video.count >= 30)
        #expect(server.droppedFragmentCount > 0)
        expectIntact(video, source: source)
        let indices = video.compactMap(SyntheticNALSource.frameIndex(of:))
        #expect(indices.count < (indices.last ?? 0) - (indices.first ?? 0) + 1, "some frames were lost")
        // After every gap the stream resumes at a keyframe.
        for (previous, current) in zip(video, video.dropFirst()) {
            guard let a = SyntheticNALSource.frameIndex(of: previous), let b = SyntheticNALSource.frameIndex(of: current) else { continue }
            if b != a + 1 { #expect(current.isKeyframe, "frame \(b) after gap from \(a)") }
        }
        expectStrictlyIncreasing(video.map(\.pts))
    }

    @Test func shortStallKeepsStreamAndTimeline() async throws {
        let server = try await makeServer { $0.faults.stall = RTSPTestServer.Stall(after: .seconds(1.5), duration: .seconds(1.5)) }
        let client = makeClient(server, timeout: .seconds(5))
        _ = try await client.connect()
        let collected = await collect(try await client.play(), timeout: .seconds(5))
        await client.close()
        await server.stop()
        #expect(collected.error == nil)
        let video = collected.video
        expectStrictlyIncreasing(video.map(\.pts))
        let gaps = zip(video.dropFirst(), video).map { ($0.pts.seconds - $1.pts.seconds, $0.isKeyframe) }
        // One real gap of about the stall length, ended by a keyframe; source timing is kept.
        let big = gaps.filter { $0.0 > 0.5 }
        #expect(big.count == 1)
        #expect(big.first.map { $0.0 > 1.2 && $0.0 < 2.6 && $0.1 } == true)
    }

    @Test func stallLongerThanTimeoutFailsStream() async throws {
        let server = try await makeServer({ $0.faults.stall = RTSPTestServer.Stall(after: .milliseconds(500), duration: .seconds(5)) },
                                          source: SyntheticNALSource.Configuration(format: h264Format, keyframeInterval: 5))
        let source = RTSPMediaSource(configuration: RTSPConfiguration(url: server.url, credentials: nil, timeout: .seconds(1)),
                                     displayName: "stall", transport: PlatformNetworkTransport())
        let first = await collect(try await source.samples(), timeout: .seconds(8))
        #expect(first.ended)
        #expect(first.error as? RTSPError == .timeout)
        #expect(first.video.count > 0)

        server.setFaults(RTSPTestServer.Faults())
        let second = await collect(try await source.samples(), timeout: .seconds(5)) { videoFrameCount($0) >= 10 }
        await source.stop()
        await server.stop()
        #expect(second.video.count >= 10)
        #expect(second.video.first?.isKeyframe == true)
    }

    @Test func reconnectAfterServerClose() async throws {
        let server = try await makeServer({ $0.faults.closeAfter = .seconds(1) },
                                          source: SyntheticNALSource.Configuration(format: h264Format, keyframeInterval: 5))
        let source = RTSPMediaSource(configuration: RTSPConfiguration(url: server.url, credentials: nil, timeout: .seconds(3)),
                                     displayName: "reconnect", transport: PlatformNetworkTransport())
        let first = await collect(try await source.samples(), timeout: .seconds(8))
        #expect(first.ended)
        #expect(first.error != nil, "the stream finishes throwing on disconnect")
        #expect(first.video.count >= 10)

        server.setFaults(RTSPTestServer.Faults())
        let second = await collect(try await source.samples(), timeout: .seconds(5)) { videoFrameCount($0) >= 20 }
        await source.stop()
        await server.stop()
        #expect(server.connectionCount == 2)
        #expect(second.video.count >= 20)
        #expect(second.video.first?.isKeyframe == true)
        #expect(second.video.first?.pts.value == 0, "a new session starts a new timeline")
        expectStrictlyIncreasing(second.video.map(\.pts))
    }

    @Test func stopFinishesStreamWithoutError() async throws {
        let server = try await makeServer()
        let source = RTSPMediaSource(configuration: RTSPConfiguration(url: server.url, credentials: nil), displayName: "stop",
                                     transport: PlatformNetworkTransport())
        #expect(source.displayName == "stop")
        let stream = try await source.samples()
        let reader = Task { await collect(stream, timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(1500))
        await source.stop()
        let collected = await reader.value
        await server.stop()
        #expect(collected.ended)
        #expect(collected.error == nil)
        #expect(collected.video.count > 3)
    }

    @Test func connectionRefused() async throws {
        let listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
        let port = listener.port
        listener.close()
        let client = RTSPClient(configuration: RTSPConfiguration(url: try #require(URL(string: "rtsp://127.0.0.1:\(port)/x")), credentials: nil,
                                                                 timeout: .seconds(2)),
                                transport: PlatformNetworkTransport())
        await #expect(throws: (any Error).self) { try await client.connect() }
    }
}

@Suite(.timeLimit(.minutes(1))) struct RTSPBackchannelTests {
    @Test func backchannelAudioReachesServer() async throws {
        let pcmu = AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1)
        let server = try await makeServer { $0.backchannel = pcmu }
        let client = makeClient(server, backchannel: true)
        let info = try await client.connect()
        #expect(info.tracks.map(\.kind) == [.video, .backchannel])
        #expect(info.backchannelFormat == pcmu)
        let stream = try await client.play()
        let reader = Task { await collect(stream, timeout: .seconds(10)) }

        let frames = (0..<10).map { SyntheticNALSource.audioUnit(index: $0, format: pcmu) }
        for frame in frames { try await client.sendBackchannel(frame) }
        #expect(await eventually(timeout: .seconds(3)) { server.backchannelPackets.count >= 10 })
        await client.close()
        _ = await reader.value
        await server.stop()

        let packets = server.backchannelPackets
        #expect(packets.map(\.payload) == frames.map(\.data))
        #expect(packets.allSatisfy { $0.payloadType == 0 })
        #expect(zip(packets.dropFirst(), packets).allSatisfy { $0.sequenceNumber == $1.sequenceNumber &+ 1 })
        #expect(zip(packets.dropFirst(), packets).allSatisfy { $0.timestamp == $1.timestamp &+ 160 })
        #expect(Set(packets.map(\.ssrc)).count == 1)
        let require = "www.onvif.org/ver20/backchannel"
        #expect(server.requests.filter { ["DESCRIBE", "SETUP", "PLAY"].contains($0.method) }.allSatisfy { $0.headers["Require"] == require })
    }

    @Test func aacBackchannelReachesServer() async throws {
        let aac = AudioFormat.aacLC(sampleRate: 16_000, channels: 1)
        let server = try await makeServer { $0.backchannel = aac }
        let client = makeClient(server, backchannel: true)
        let info = try await client.connect()
        let format = try #require(info.backchannelFormat)
        #expect(format.codec == .aac)
        #expect(format.sampleRate == 16_000)
        let stream = try await client.play()   // kept alive: dropping the stream closes the session
        let frames = (0..<5).map {
            EncodedAudioFrame(format: format, data: filler(100 + $0, seed: UInt8($0 + 1)), pts: MediaTime(value: Int64($0 * 1024), timescale: 16_000),
                              sampleCount: 1024, wallClock: Date())
        }
        for frame in frames { try await client.sendBackchannel(frame) }
        #expect(await eventually(timeout: .seconds(3)) { server.backchannelPackets.count >= 5 })
        await client.close()
        withExtendedLifetime(stream) {}
        await server.stop()
        let packets = server.backchannelPackets
        #expect(packets.count == 5)
        #expect(packets.allSatisfy { $0.payloadType == 98 })
        // RFC 3640 AAC-hbr: AU-headers-length 16 bits, one header (13-bit size, 3-bit index 0), then the access unit.
        for (packet, frame) in zip(packets, frames) {
            let bytes = [UInt8](packet.payload)
            #expect(bytes.count == 4 + frame.data.count)
            #expect(bytes.prefix(2) == [0x00, 0x10])
            #expect((Int(bytes[2]) << 5 | Int(bytes[3]) >> 3) == frame.data.count)
            #expect(Data(bytes.dropFirst(4)) == frame.data)
        }
        #expect(zip(packets.dropFirst(), packets).allSatisfy { $0.timestamp == $1.timestamp &+ 1024 })
        #expect(zip(packets.dropFirst(), packets).allSatisfy { $0.sequenceNumber == $1.sequenceNumber &+ 1 })
    }

    @Test func largeFramesAreSplitIntoSeveralPackets() async throws {
        let pcma = AudioFormat(codec: .pcma, sampleRate: 8000, channels: 1)
        let server = try await makeServer { $0.backchannel = pcma }
        let client = makeClient(server, backchannel: true)
        let info = try await client.connect()
        #expect(info.backchannelFormat == pcma)
        let stream = try await client.play()   // kept alive: dropping the stream closes the session
        let big = EncodedAudioFrame(format: pcma, data: filler(2400), pts: MediaTime(value: 0, timescale: 8000), sampleCount: 2400, wallClock: Date())
        try await client.sendBackchannel(big)
        #expect(await eventually(timeout: .seconds(3)) { server.backchannelPackets.reduce(0) { $0 + $1.payload.count } >= 2400 })
        await client.close()
        withExtendedLifetime(stream) {}
        await server.stop()
        let packets = server.backchannelPackets
        #expect(packets.count == 3)
        #expect(packets.allSatisfy { $0.payload.count <= 1024 && $0.payloadType == 8 })
        #expect(packets.reduce(Data()) { $0 + $1.payload } == big.data)
        #expect(zip(packets.dropFirst(), packets).allSatisfy { $0.timestamp == $1.timestamp &+ UInt32($1.payload.count) })
    }

    @Test func unsupportedBackchannelFallsBackToPlainSession() async throws {
        let server = try await makeServer()
        let client = makeClient(server, backchannel: true)
        let info = try await client.connect()
        #expect(info.backchannelFormat == nil)
        #expect(info.tracks.map(\.kind) == [.video])
        let describes = server.requests.filter { $0.method == "DESCRIBE" }
        #expect(describes.count == 2)
        #expect(describes.first?.headers["Require"] != nil)
        #expect(describes.last?.headers["Require"] == nil)
        let stream = try await client.play()   // kept alive: dropping the stream closes the session
        let frame = SyntheticNALSource.audioUnit(index: 0, format: AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1))
        await #expect(throws: RTSPError.self) { try await client.sendBackchannel(frame) }
        await client.close()
        withExtendedLifetime(stream) {}
        await server.stop()
    }

    @Test func mismatchedCodecIsRejected() async throws {
        let server = try await makeServer { $0.backchannel = AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1) }
        let client = makeClient(server, backchannel: true)
        _ = try await client.connect()
        let stream = try await client.play()   // kept alive: dropping the stream closes the session
        let opus = EncodedAudioFrame(format: AudioFormat(codec: .opus, sampleRate: 16_000, channels: 1), data: Data([1, 2, 3]),
                                     pts: MediaTime(value: 0, timescale: 16_000), sampleCount: 320, wallClock: Date())
        await #expect(throws: RTSPError.unsupportedCodec("opus")) { try await client.sendBackchannel(opus) }
        await client.close()
        withExtendedLifetime(stream) {}
        await server.stop()
    }
}
#endif
