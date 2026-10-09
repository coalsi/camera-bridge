#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import MediaCore
import PlatformApple
import RTP
import Synchronization
import Testing
import TestSupport
@testable import BridgeEngine

/// Live view through the streaming delegate (plan W3-1 item 3; research brief §3.6; integration brief §5.4): prepare
/// → start → SRTP to a loopback test receiver, passthrough vs transcode, Opus audio at the requested rate and packet
/// time, PLI, reconfigure, two-way audio to a talkback sink, the 30 s controller timeout, teardown.
@Suite(.serialized) struct RuntimeLiveStreamTests {
    static let log = Log(category: "LiveTest")

    /// A talkback sink that records what it is sent.
    final class FakeTalkbackSink: TalkbackSink {
        let inputFormat = AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1)
        /// How long `close()` takes (ignoring cancellation: a camera that does not answer its close request).
        let closeDelay: Duration
        let opens = Box(0)
        /// When `open()` returned.
        let openedAt = Box<ContinuousClock.Instant?>(nil)
        /// `close()` calls begun / returned.
        let closes = Box(0)
        let closesFinished = Box(0)
        let frames = Box<[EncodedAudioFrame]>([])
        /// When each frame reached the camera.
        let sentAt = Box<[ContinuousClock.Instant]>([])

        /// How long `open()` waits for the camera's answer, following cancellation (an HTTP request: Hikvision).
        let openDelay: Duration

        init(closeDelay: Duration = .zero, openDelay: Duration = .zero) {
            self.closeDelay = closeDelay
            self.openDelay = openDelay
        }

        func open() async throws {
            opens.update { $0 += 1 }
            if openDelay > .zero { try await Task.sleep(for: openDelay) }
            openedAt.set(.now)
        }
        func send(_ frame: EncodedAudioFrame) async throws {
            frames.update { $0.append(frame) }
            sentAt.update { $0.append(.now) }
        }
        func close() async {
            closes.update { $0 += 1 }
            if closeDelay > .zero {
                let delay = closeDelay
                await Task.detached { try? await Task.sleep(for: delay) }.value
            }
            closesFinished.update { $0 += 1 }
        }
    }

    struct Setup {
        let feeder: HubFeeder
        let handler: StreamingHandler
        let leases: Box<[Bool]>
        let released: Box<Int>
        let ended: Box<[UUID]>
    }

    /// `leaseDelay`: how long the hub provider takes (ignoring cancellation, like a runtime waiting for the sub stream).
    static func setup(source: any MediaSource, hub: MediaHub = MediaHub(), talkback: FakeTalkbackSink? = nil, controllerTimeout: Duration = .seconds(30),
                      controllerWait: Duration = .seconds(1), leaseDelay: Duration = .zero, codecs: any MediaCodecs = AppleMediaCodecs(),
                      cameraAudioEnabled: Bool = true, loopbackOnly: Bool = true, overlay: TimestampOverlayControl? = nil,
                      interfaceAddresses: @escaping @Sendable () -> [InterfaceAddress] = StreamAddress.interfaceAddresses,
                      routeTable: @escaping @Sendable () -> [MacVPNDetector.InterfaceRoute] = StreamAddress.routeTable, strategyMemory: Duration = .seconds(3_600),
                      liveTimings: LiveStreamTimings? = nil,
                      networkNotices: (@Sendable (NetworkNotice) -> Void)? = nil, routeVerdictWait: Duration = .seconds(8),
                      timing: LiveStreamTiming = .standard, cameraKeyframe: (@Sendable (Bool) async -> Void)? = nil, selfCheck: Bool = true,
                      subStreamSize: (@Sendable () async -> VideoResolution?)? = nil) -> Setup {
        let feeder = HubFeeder(source: source, hub: hub)
        let leases = Box<[Bool]>([])
        let released = Box(0)
        let hub = feeder.hub
        let provider: HubProvider = { preferSub in
            leases.update { $0.append(preferSub) }
            if leaseDelay > .zero { await Task.detached { try? await Task.sleep(for: leaseDelay) }.value }
            return HubLease(hub: hub, isSubStream: false, release: { released.update { $0 += 1 } })
        }
        let snapshots = SnapshotProvider(cameraSnapshot: nil, codecs: codecs, hub: hub, log: log)
        let makeSink: (@Sendable () -> (any TalkbackSink)?)? = talkback.map { sink in { @Sendable in sink } }
        let context = LiveStreamPipeline.Context(codecs: codecs, cameraAudioEnabled: cameraAudioEnabled, talkback: makeSink,
                                                 controllerTimeout: controllerTimeout, controllerWait: controllerWait, log: log, overlay: overlay,
                                                 timing: timing, cameraKeyframe: cameraKeyframe, subStreamSize: subStreamSize, selfCheck: selfCheck)
        let handler = StreamingHandler(hubs: provider, snapshots: snapshots, context: context, loopbackOnly: loopbackOnly,
                                      interfaceAddresses: interfaceAddresses, routeTable: routeTable, strategyMemory: strategyMemory, liveTimings: liveTimings,
                                      networkNotices: networkNotices, routeVerdictWait: routeVerdictWait)
        return Setup(feeder: feeder, handler: handler, leases: leases, released: released, ended: Box([]))
    }

    /// Picture sizes ("W×H") of the received video frames that carry an SPS, in arrival order.
    final class SPSSizes: Sendable {
        let sizes = Box<[String]>([])
        private let task: Task<Void, Never>

        init(_ receiver: SRTPTestReceiver) {
            let sizes = sizes
            task = Task {
                for await frame in receiver.videoFrames {
                    guard let sps = frame.sps, let pps = frame.pps, let format = VideoFormat.h264(sps: sps, pps: pps) else { continue }
                    sizes.update { $0.append("\(format.width)×\(format.height)") }
                }
            }
        }

        func stop() { task.cancel() }
    }

    /// One second of silence as Opus packets (return audio from a controller).
    static func opusSecond() throws -> [EncodedAudioFrame] {
        let encoder = try AppleMediaCodecs().makeAudioTranscoder(input: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1),
                                                                 output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000))
        var opus = try encoder.transcode(EncodedAudioFrame(format: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1), data: Data(count: 32_000),
                                                           pts: MediaTime(value: 0, timescale: 16_000), sampleCount: 16_000, wallClock: Date()))
        opus += try encoder.flush()
        return opus
    }

    static func sendReturnAudio(_ packets: [EncodedAudioFrame], from receiver: SRTPTestReceiver) async throws {
        for packet in packets {
            try await receiver.sendReturnAudio(packet.data, samples: packet.sampleCount)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func prepare(_ handler: StreamingHandler, receiver: SRTPTestReceiver, sessionID: UUID = UUID()) async throws -> PrepareStreamResponse {
        let request = PrepareStreamRequest(sessionID: sessionID, controllerAddress: "127.0.0.1", isIPv6: false, controllerVideoPort: receiver.videoPort,
                                           controllerAudioPort: receiver.audioPort,
                                           videoSRTP: SRTPParameters(suite: .aesCm128HmacSha1_80, masterKey: receiver.videoKeys.masterKey,
                                                                     masterSalt: receiver.videoKeys.masterSalt),
                                           audioSRTP: SRTPParameters(suite: .aesCm128HmacSha1_80, masterKey: receiver.audioKeys.masterKey,
                                                                     masterSalt: receiver.audioKeys.masterSalt),
                                           localAddress: "127.0.0.1")
        return try await handler.prepareStream(request)
    }

    static func video(_ width: Int, _ height: Int, fps: Int = 30, bitrate: Int = 800) -> SelectedVideoParameters {
        SelectedVideoParameters(profile: .main, level: .level4_0, resolution: VideoResolution(width, height, fps), payloadType: 99,
                                controllerSSRC: 0x1111, maxBitrateKbps: bitrate, rtcpIntervalSeconds: 0.5, mtu: 1378)
    }

    static func audio(rate: StreamingSampleRate = .khz24, packetTime: Int = 20, bitrate: Int = 24) -> SelectedAudioParameters {
        SelectedAudioParameters(codec: .opus, channels: 1, sampleRate: rate, packetTimeMs: packetTime, payloadType: 110, controllerSSRC: 0x2222,
                                maxBitrateKbps: bitrate, rtcpIntervalSeconds: 0.5)
    }

    static func connect(_ receiver: SRTPTestReceiver, to response: PrepareStreamResponse, keepalive: Bool = true) async {
        await receiver.connect(to: SRTPTestReceiver.Peer(host: "127.0.0.1", videoPort: response.videoPort, audioPort: response.audioPort,
                                                         videoSSRC: response.videoSSRC, audioSSRC: response.audioSSRC, controllerVideoSSRC: 0x1111,
                                                         controllerAudioSSRC: 0x2222, videoPayloadType: 99, audioPayloadType: 110),
                               keepaliveInterval: keepalive ? .milliseconds(500) : nil)
    }

    @Test(.timeLimit(.minutes(3))) func passthroughStartsWithTheLastKeyframeAndSendsOpus() async throws {
        // A 3 s GOP: the picture must not wait for the camera's next keyframe.
        let setup = Self.setup(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(3), audio: .aac, audioRate: 16_000))
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await Self.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        #expect(response.accessoryAddress == "127.0.0.1" && response.videoSSRC != response.audioSSRC)
        #expect(response.videoSRTP.masterKey == receiver.videoKeys.masterKey)
        await Self.connect(receiver, to: response)
        let started = ContinuousClock.now
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(1280, 720), audio: Self.audio()))
        #expect(setup.leases.value == [false])
        let pipeline = try #require(await setup.handler.pipeline(sessionID))
        #expect(await receiver.waitFor(timeout: .seconds(5)) { $0.keyframes >= 1 })
        let firstKeyframe = try #require(await receiver.firstKeyframeAt)
        #expect(firstKeyframe - started < .seconds(1), "the hub's last keyframe goes out at once")
        #expect(pipeline.videoPath == .passthrough && !pipeline.isTranscoding)
        #expect(await receiver.waitFor(timeout: .seconds(8)) { $0.videoFrames >= 45 && $0.audioFrames >= 20 })
        let stats = await receiver.statistics
        #expect(stats.authenticationFailures == 0 && stats.unexpectedSSRCPackets == 0 && stats.incompleteVideoFrames == 0)
        #expect(stats.largestVideoDatagram <= 1200)
        var audioPackets: [ReceivedAudioFrame] = []
        for await packet in receiver.audioFrames {
            audioPackets.append(packet)
            if audioPackets.count == 5 { break }
        }
        #expect(audioPackets.allSatisfy { $0.payloadType == 110 && $0.ssrc == response.audioSSRC })
        let steps = zip(audioPackets, audioPackets.dropFirst()).map { $1.rtpTimestamp &- $0.rtpTimestamp }
        #expect(steps.allSatisfy { $0 == 480 }, "20 ms at the 24 kHz RTP clock")
        // Stop tears down: BYE sent, hub released, no running session.
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        #expect(await receiver.waitFor(timeout: .seconds(3)) { $0.byes >= 1 })
        #expect(setup.released.value == 1)
        #expect(await setup.handler.runningSessionCount == 0)
        #expect(await eventually { await setup.feeder.hub.subscriberCount == 0 })
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test(.timeLimit(.minutes(3))) func transcodesSmallerRequestsAndAnswersPLI() async throws {
        let setup = Self.setup(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(4), audio: nil))
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await Self.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await Self.connect(receiver, to: response)
        let sizes = SPSSizes(receiver)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(320, 240, fps: 15, bitrate: 200), audio: Self.audio()))
        #expect(setup.leases.value == [true], "small requests prefer the sub stream")
        #expect(await receiver.waitFor(timeout: .seconds(5)) { $0.keyframes >= 1 && $0.videoFrames >= 10 })
        let pipeline = try #require(await setup.handler.pipeline(sessionID))
        #expect(pipeline.isTranscoding)
        if case .transcode = pipeline.videoPath {} else { Issue.record("expected the transcoded path") }
        // The encoder's keyframes come every 2 s; right after one, a PLI gets the next much sooner.
        let regular = await receiver.statistics.keyframes
        #expect(await receiver.waitFor(timeout: .seconds(4)) { $0.keyframes > regular })
        let before = await receiver.statistics.keyframes
        let asked = ContinuousClock.now
        await receiver.requestKeyframe()
        #expect(await receiver.waitFor(timeout: .seconds(3)) { $0.keyframes > before })
        #expect(ContinuousClock.now - asked < .milliseconds(1_200))
        // Reconfigure: bit rate, then resolution; frames keep flowing.
        try await setup.handler.handleStreamRequest(.reconfigure(sessionID: sessionID, video: Self.video(320, 240, fps: 15, bitrate: 100)))
        try await setup.handler.handleStreamRequest(.reconfigure(sessionID: sessionID, video: Self.video(480, 270, fps: 15, bitrate: 300)))
        let frames = await receiver.statistics.videoFrames
        #expect(await receiver.waitFor(timeout: .seconds(8)) { $0.videoFrames >= frames + 30 && $0.keyframes > before + 1 })
        // Review finding (W4): the new size must reach the controller (a no-op resize passed every suite).
        #expect(sizes.sizes.value.first == "320×240")
        #expect(await eventually(timeout: .seconds(5)) { sizes.sizes.value.last == "480×270" }, "keyframes after the resize: \(sizes.sizes.value)")
        sizes.stop()
        await #expect(throws: StreamingHandler.Failure.unknownSession) {
            try await setup.handler.handleStreamRequest(.reconfigure(sessionID: UUID(), video: Self.video(320, 240)))
        }
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await setup.feeder.stop()
    }

    /// Review findings (W4 round 3): a bit-rate reconfigure was checked only for frames still flowing (a no-op passed
    /// every suite), the requested Opus bit rate not at all, and a reconfigure that changed the size as well left the
    /// running transcoder at the old bit rate until the next source keyframe (a GOP later; controllers lower both under
    /// congestion). The bit rate reaches the transcoder at once, the video rate follows, Opus keeps to its request.
    @Test(.timeLimit(.minutes(3))) func aLowerBitRateReachesTheTranscoderAtOnceAndOpusKeepsItsBitRate() async throws {
        let codecs = WatchedTranscoderCodecs()
        // A 4 s GOP: the next source keyframe is far off when the size changes.
        let setup = Self.setup(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(4), audio: .aac, audioRate: 16_000),
                               codecs: codecs)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await Self.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await Self.connect(receiver, to: response)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(320, 240, fps: 15, bitrate: 1000),
                                                           audio: Self.audio(bitrate: 16)))
        #expect(await receiver.waitFor(timeout: .seconds(5)) { $0.keyframes >= 1 && $0.videoFrames >= 10 })
        let transcoder = try #require(codecs.transcoders.value.last)
        func kbps(over seconds: Double) async throws -> Double {
            let from = ContinuousClock.now
            try await Task.sleep(for: .seconds(seconds))
            let bytes = await receiver.frameRecords.filter { $0.receivedAt >= from }.reduce(0) { $0 + $1.byteCount }
            return Double(bytes * 8) / seconds / 1000
        }
        let before = try await kbps(over: 3)

        // The bit rate alone.
        try await setup.handler.handleStreamRequest(.reconfigure(sessionID: sessionID, video: Self.video(320, 240, fps: 15, bitrate: 100)))
        #expect(transcoder.bitrates.value == [100])
        try await Task.sleep(for: .seconds(1))
        let after = try await kbps(over: 3)
        #expect(after < before * 0.6, "\(before) → \(after) kbit/s (unchanged when the transcoder keeps its bit rate)")

        // Opus: the requested 16 kbit/s (20 ms packets: 40 bytes on average), not the encoder's default 24 kbit/s (60 bytes).
        var audioPackets: [ReceivedAudioFrame] = []
        for await packet in receiver.audioFrames {
            audioPackets.append(packet)
            if audioPackets.count == 50 { break }
        }
        let averagePayload = Double(audioPackets.reduce(0) { $0 + $1.payload.count }) / Double(audioPackets.count)
        #expect(averagePayload < 52, "average Opus payload \(averagePayload) bytes for 16 kbit/s")

        // Size and bit rate together: the running transcoder takes the bit rate before the next source keyframe.
        try await setup.handler.handleStreamRequest(.reconfigure(sessionID: sessionID, video: Self.video(160, 120, fps: 15, bitrate: 60)))
        #expect(transcoder.bitrates.value == [100, 60], "the running transcoder keeps the old bit rate until the next source keyframe")
        #expect(codecs.transcoders.value.count == 1, "the new size waits for the next source keyframe")
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await setup.feeder.stop()
    }

    /// Review finding (W4 round 3): turning Camera Audio off (a privacy setting) was never tested for live view: the
    /// camera's sound must not reach the controller.
    @Test(.timeLimit(.minutes(1))) func cameraAudioOffSendsNoCameraSound() async throws {
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: .aac, audioRate: 16_000),
                               cameraAudioEnabled: false)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        #expect(await setup.feeder.hub.audioFormat != nil, "the camera has audio")
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await Self.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await Self.connect(receiver, to: response)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(1280, 720), audio: Self.audio()))
        #expect(await receiver.waitFor(timeout: .seconds(8)) { $0.videoFrames >= 30 })
        #expect(await receiver.statistics.audioFrames == 0, "camera audio is off")
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test(.timeLimit(.minutes(3))) func sixtyMillisecondPacketTimeAndTwoWayAudio() async throws {
        let sink = FakeTalkbackSink()
        let setup = Self.setup(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: .pcmu, audioRate: 8_000), talkback: sink)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await Self.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await Self.connect(receiver, to: response)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(1280, 720), audio: Self.audio(rate: .khz16, packetTime: 60)))
        var audioPackets: [ReceivedAudioFrame] = []
        for await packet in receiver.audioFrames {
            audioPackets.append(packet)
            if audioPackets.count == 4 { break }
        }
        let steps = zip(audioPackets, audioPackets.dropFirst()).map { $1.rtpTimestamp &- $0.rtpTimestamp }
        #expect(steps.allSatisfy { $0 == 960 }, "60 ms at the 16 kHz RTP clock")
        #expect(audioPackets.allSatisfy { ($0.payload.first ?? 0) & 0x03 == 3 }, "three frames per code-3 packet")

        // Return audio: Opus from the controller reaches the camera's sink as PCMU.
        let encoder = try AppleMediaCodecs().makeAudioTranscoder(input: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1),
                                                                 output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000))
        let pcm = Data(count: 16_000 * 2)   // 1 s of silence
        var opus = try encoder.transcode(EncodedAudioFrame(format: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1), data: pcm,
                                                           pts: MediaTime(value: 0, timescale: 16_000), sampleCount: 16_000, wallClock: Date()))
        opus += try encoder.flush()
        #expect(opus.count >= 20)
        for packet in opus {
            try await receiver.sendReturnAudio(packet.data, samples: packet.sampleCount)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await eventually(timeout: .seconds(5)) { sink.frames.value.count >= 10 })
        #expect(sink.opens.value == 1)
        #expect(sink.frames.value.allSatisfy { $0.format.codec == .pcmu && $0.format.sampleRate == 8_000 })
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        #expect(sink.closes.value == 1, "the sink closes with the stream")
        await receiver.stop()
        await setup.feeder.stop()
    }

    /// Review finding (W4 round 2): the camera-facing talkback close was awaited without a bound before the hub lease
    /// and the transcoder were let go. A camera that did not answer its close request (Hikvision: up to the 10 s HTTP
    /// timeout) held the stop past HAP's 8 s delegate deadline, and a camera stop or pause as long.
    @Test(.timeLimit(.minutes(1))) func aTalkbackCloseThatHangsNeverHoldsUpTheStop() async throws {
        let sink = FakeTalkbackSink(closeDelay: .seconds(6))
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), talkback: sink)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await Self.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await Self.connect(receiver, to: response)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(1280, 720), audio: Self.audio()))
        #expect(await receiver.waitFor(timeout: .seconds(5)) { $0.keyframes >= 1 })
        try await Self.sendReturnAudio(Array(try Self.opusSecond().prefix(10)), from: receiver)
        #expect(await eventually(timeout: .seconds(5)) { sink.opens.value == 1 && !sink.frames.value.isEmpty })

        let stopping = ContinuousClock.now
        let stop = Task { try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID)) }
        #expect(await eventually(timeout: .milliseconds(1_000)) { setup.released.value == 1 }, "the hub is let go before the talkback close")
        #expect(sink.closes.value == 1 && sink.closesFinished.value == 0)
        try await stop.value
        #expect(ContinuousClock.now - stopping < .milliseconds(3_800), "bounded like the other camera-facing stops (3 s)")
        await receiver.stop()
        await setup.feeder.stop()
    }

    /// Review finding (W4 round 3): the stop cancelled the return-audio task while the camera-facing talkback open was
    /// under way; the open failed with the cancellation and the camera's two-way session stayed open.
    @Test(.timeLimit(.minutes(1))) func stoppingALiveViewWhileTalkbackOpensClosesTheCamerasSession() async throws {
        let sink = FakeTalkbackSink(openDelay: .milliseconds(600))
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), talkback: sink)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await Self.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await Self.connect(receiver, to: response)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(1280, 720), audio: Self.audio()))
        #expect(await receiver.waitFor(timeout: .seconds(5)) { $0.keyframes >= 1 })
        try await Self.sendReturnAudio(Array(try Self.opusSecond().prefix(3)), from: receiver)
        #expect(await eventually(timeout: .seconds(3)) { sink.opens.value == 1 })
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        #expect(await eventually(timeout: .seconds(3)) { sink.closes.value == 1 }, "the camera's two-way session is closed")
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aControllerThatGoesSilentEndsTheSessionThroughHAP() async throws {
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 10, gop: .seconds(1), audio: nil),
                               controllerTimeout: .seconds(1))
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let ended = setup.ended
        await setup.handler.setSessionEnder { id in
            ended.update { $0.append(id) }
            return false   // no HAP controller here: the handler ends the session itself
        }
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await Self.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await Self.connect(receiver, to: response, keepalive: false)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(640, 360), audio: nil))
        #expect(await eventually(timeout: .seconds(5)) { ended.value == [sessionID] })
        #expect(await eventually { await setup.handler.runningSessionCount == 0 })
        #expect(setup.released.value == 1)
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test(.timeLimit(.minutes(1))) func preparedSessionsAreClosedAndUnknownStartsFail() async throws {
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 10, audio: nil))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await Self.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await #expect(throws: StreamingHandler.Failure.unknownSession) {
            try await setup.handler.handleStreamRequest(.start(sessionID: UUID(), video: Self.video(640, 360), audio: nil))
        }
        // Stopping a prepared (never started) session frees its ports.
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        let rebound = try UDPSocket.bind(host: "127.0.0.1", port: response.videoPort)
        rebound.close()
        await setup.handler.stopAll()
        await #expect(throws: StreamingHandler.Failure.stopped) { _ = try await Self.prepare(setup.handler, receiver: receiver) }
        await receiver.stop()
        await setup.feeder.stop()
    }

    static func request(sessionID: UUID = UUID(), controller: String, ipv6: Bool, local: String, receiver: SRTPTestReceiver) -> PrepareStreamRequest {
        PrepareStreamRequest(sessionID: sessionID, controllerAddress: controller, isIPv6: ipv6, controllerVideoPort: receiver.videoPort,
                             controllerAudioPort: receiver.audioPort,
                             videoSRTP: SRTPParameters(suite: .aesCm128HmacSha1_80, masterKey: receiver.videoKeys.masterKey, masterSalt: receiver.videoKeys.masterSalt),
                             audioSRTP: SRTPParameters(suite: .aesCm128HmacSha1_80, masterKey: receiver.audioKeys.masterKey, masterSalt: receiver.audioKeys.masterSalt),
                             localAddress: local)
    }

    /// Review finding (W4): a controller asking for the other address family than its HAP connection got the HAP
    /// connection's address back, which RTPStreamManagement refuses (-70402): live view never started.
    @Test(.timeLimit(.minutes(1))) func theAccessoryAddressIsOfTheRequestedFamily() async throws {
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 10, audio: nil))
        let receiver = try await SRTPTestReceiver.start()
        // HAP over IPv6 loopback, stream over IPv4 — and the reverse (lo0 carries both).
        let ipv4 = try await setup.handler.prepareStream(Self.request(controller: "127.0.0.1", ipv6: false, local: "::1", receiver: receiver))
        #expect(ipv4.accessoryAddress == "127.0.0.1")
        let ipv6 = try await setup.handler.prepareStream(Self.request(controller: "::1", ipv6: true, local: "127.0.0.1", receiver: receiver))
        #expect(ipv6.accessoryAddress == "::1")
        let same = try await setup.handler.prepareStream(Self.request(controller: "127.0.0.1", ipv6: false, local: "127.0.0.1", receiver: receiver))
        #expect(same.accessoryAddress == "127.0.0.1")
        await setup.handler.stopAll()
        await receiver.stop()
        await setup.feeder.stop()
    }

    /// A reported bug: an iPhone on a VPN advertises the tunnel's address (10.5.0.2) in SetupEndpoints while its HAP
    /// connection arrives over the LAN. The stream goes to the HAP connection's address instead (here loopback stands for
    /// the LAN peer, the receiver listens there), and the SetupEndpoints answer names our address on that connection.
    @Test(.timeLimit(.minutes(3))) func aVPNAdvertisedAddressIsReplacedByTheHAPConnectionsAddress() async throws {
        let lan = [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
                   InterfaceAddress(interface: "en0", address: "192.0.2.5", prefixLength: 24)]
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 10, audio: nil), interfaceAddresses: { lan })
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        var request = Self.request(sessionID: sessionID, controller: "10.5.0.2", ipv6: false, local: "127.0.0.1", receiver: receiver)
        request.peerAddress = "127.0.0.1"
        let response = try await setup.handler.prepareStream(request)
        #expect(response.accessoryAddress == "127.0.0.1", "our address on the HAP connection's interface")
        await Self.connect(receiver, to: response)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(640, 360), audio: nil))
        let pipeline = try #require(await setup.handler.pipeline(sessionID))
        #expect(pipeline.controllerHost == "127.0.0.1" && pipeline.advertisedHost == "10.5.0.2")
        #expect(await receiver.waitFor(timeout: .seconds(10)) { $0.keyframes >= 1 && $0.videoFrames >= 5 }, "the video reaches the peer")
        #expect(await setup.handler.runningSessionCount == 1)
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await setup.feeder.stop()
    }

    /// The VPN notice: the controller advertised 10.5.0.2, the stream went to the HAP connection's address, and the notice
    /// says first that it was set up (pending) and then that the controller answered (video got through).
    @Test(.timeLimit(.minutes(3))) func aVPNControllerIsReportedAndItsAnswerConfirmsTheDelivery() async throws {
        let lan = [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
                   InterfaceAddress(interface: "en0", address: "192.0.2.5", prefixLength: 24)]
        let notices = Box<[NetworkNotice]>([])
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 10, audio: nil), interfaceAddresses: { lan },
                               networkNotices: { notice in notices.update { $0.append(notice) } }, routeVerdictWait: .seconds(5))
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        var request = Self.request(sessionID: sessionID, controller: "10.5.0.2", ipv6: false, local: "127.0.0.1", receiver: receiver)
        request.peerAddress = "127.0.0.1"
        let response = try await setup.handler.prepareStream(request)
        let pending = try #require(notices.value.first)
        #expect(pending.kind == .controllerOnVPN && pending.advertisedAddress == "10.5.0.2" && pending.peerAddress == "127.0.0.1")
        #expect(pending.usedFallback && pending.delivery == .pending)
        await Self.connect(receiver, to: response)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(640, 360), audio: nil))
        #expect(await eventually { notices.value.last?.delivery == .reached }, "the receiver's RTCP is the first controller packet")
        #expect(notices.value.last?.usedFallback == true)
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test(.timeLimit(.minutes(3))) func aVPNControllerThatStaysSilentIsReportedAsNotReached() async throws {
        let lan = [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8)]
        let notices = Box<[NetworkNotice]>([])
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 10, audio: nil), controllerWait: .milliseconds(100),
                               interfaceAddresses: { lan }, networkNotices: { notice in notices.update { $0.append(notice) } },
                               routeVerdictWait: .milliseconds(600))
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        var request = Self.request(sessionID: sessionID, controller: "10.5.0.2", ipv6: false, local: "127.0.0.1", receiver: receiver)
        request.peerAddress = "127.0.0.1"
        let response = try await setup.handler.prepareStream(request)
        await Self.connect(receiver, to: response, keepalive: false)   // the controller never answers
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(640, 360), audio: nil))
        #expect(await eventually { notices.value.last?.delivery == .failed })
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test(.timeLimit(.minutes(3))) func aViewerThatLeavesBeforeTheVerdictLeavesTheNoticePending() async throws {
        let lan = [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8)]
        let notices = Box<[NetworkNotice]>([])
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 10, audio: nil), controllerWait: .milliseconds(100),
                               interfaceAddresses: { lan }, networkNotices: { notice in notices.update { $0.append(notice) } },
                               routeVerdictWait: .seconds(30))
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        var request = Self.request(sessionID: sessionID, controller: "10.5.0.2", ipv6: false, local: "127.0.0.1", receiver: receiver)
        request.peerAddress = "127.0.0.1"
        let response = try await setup.handler.prepareStream(request)
        await Self.connect(receiver, to: response, keepalive: false)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(640, 360), audio: nil))
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        try await Task.sleep(for: .milliseconds(500))
        #expect(notices.value.map(\.delivery) == [.pending], "no verdict is made for a session that was stopped")
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test func aStreamToAnAdvertisedAddressOnTheNetworkMakesNoNotice() async throws {
        let lan = [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8)]
        let notices = Box<[NetworkNotice]>([])
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 10, audio: nil), interfaceAddresses: { lan },
                               networkNotices: { notice in notices.update { $0.append(notice) } })
        let receiver = try await SRTPTestReceiver.start()
        _ = try await setup.handler.prepareStream(Self.request(controller: "127.0.0.1", ipv6: false, local: "127.0.0.1", receiver: receiver))
        // Off network but not a tunnel's address (a global IPv6 one): the route changes, the person is not told it is a VPN.
        var global = Self.request(controller: "2001:db8::9", ipv6: true, local: "::1", receiver: receiver)
        global.peerAddress = "::1"
        _ = try await setup.handler.prepareStream(global)
        #expect(notices.value.isEmpty)
        await setup.handler.stopAll()
        await receiver.stop()
        await setup.feeder.stop()
    }

    /// Review finding (RTP coverage): every test runs `loopbackOnly`, so nothing checked that the app (`.live()`) binds
    /// the wildcard of the requested family; a live view bound to loopback would be unreachable from Apple Home.
    /// (`UDPSocketWildcardTests` covers the wildcard and dual-stack socket paths.)
    @Test func liveViewSocketsBindTheWildcardUnlessLoopbackOnly() {
        #expect(StreamingHandler.bindHost(loopbackOnly: false, ipv6: false) == nil)
        #expect(StreamingHandler.bindHost(loopbackOnly: false, ipv6: true) == nil)
        #expect(StreamingHandler.bindHost(loopbackOnly: true, ipv6: false) == "127.0.0.1")
        #expect(StreamingHandler.bindHost(loopbackOnly: true, ipv6: true) == "::1")
    }

    /// Field report (2026-10-03): a Mac on the LAN twice (Ethernet 192.0.2.69 and Wi-Fi 192.0.2.25) left every camera
    /// loading forever in Home. An iPhone whose HAP connection came in on .25 was told to expect SRTP from .25, the
    /// wildcard sockets sent it from .69 (the routing table's interface), and the iPhone dropped it while its RTCP kept
    /// the session alive. The sockets now bind the advertised accessory address.
    @Test func liveViewSocketsSendFromTheAdvertisedAddress() {
        let interfaces = [InterfaceAddress(interface: "lo0", address: "127.0.0.1"), InterfaceAddress(interface: "en0", address: "192.0.2.69"),
                          InterfaceAddress(interface: "en0", address: "fe80::1c:2d"), InterfaceAddress(interface: "en0", address: "fd00::69"),
                          InterfaceAddress(interface: "en1", address: "192.0.2.25"), InterfaceAddress(interface: "en1", address: "fd00::25")]
        func host(_ address: String, to destination: String, ipv6: Bool = false) -> String? {
            StreamingHandler.bindHost(accessoryAddress: address, destination: destination, ipv6: ipv6, interfaces: interfaces)
        }
        #expect(host("192.0.2.25", to: "192.0.2.20") == "192.0.2.25", "Wi-Fi, though the route to the iPhone is Ethernet")
        #expect(host("192.0.2.69", to: "192.0.2.20") == "192.0.2.69")
        #expect(host("fd00::25", to: "fd00::20", ipv6: true) == "fd00::25")
        #expect(host("fd00::25", to: "192.0.2.20", ipv6: true) == nil, "an IPv6 session sent to an IPv4 peer needs the dual-stack wildcard")
        #expect(host("fe80::1c:2d", to: "fe80::2%en0", ipv6: true) == nil, "link-local needs a scope to bind")
        #expect(host("203.0.113.9", to: "192.0.2.20") == nil, "not one of ours")
    }

    @Test func accessoryAddressesComeFromTheHAPConnectionsInterface() {
        let interfaces = [InterfaceAddress(interface: "lo0", address: "127.0.0.1"), InterfaceAddress(interface: "lo0", address: "::1"),
                          InterfaceAddress(interface: "en0", address: "fe80::1c:2d"), InterfaceAddress(interface: "en0", address: "192.168.1.20"),
                          InterfaceAddress(interface: "en0", address: "fd00::20"), InterfaceAddress(interface: "en1", address: "10.0.0.7"),
                          InterfaceAddress(interface: "en1", address: "2001:db8::7")]
        func address(_ local: String, ipv6: Bool) -> String { StreamAddress.accessoryAddress(localAddress: local, ipv6: ipv6, interfaces: interfaces) }
        #expect(address("192.168.1.20", ipv6: false) == "192.168.1.20")
        #expect(address("::ffff:192.168.1.20", ipv6: false) == "192.168.1.20")
        #expect(address("192.168.1.20", ipv6: true) == "fd00::20", "a routable IPv6 address of the same interface")
        #expect(address("fe80::1c:2d", ipv6: false) == "192.168.1.20")
        #expect(address("fe80::1c:2d%en0", ipv6: true) == "fd00::20", "HAP-NodeJS prefers an address without a scope")
        #expect(address("fd00::20", ipv6: true) == "fd00::20")
        #expect(address("2001:db8::7", ipv6: false) == "10.0.0.7")
        #expect(address("::1", ipv6: false) == "127.0.0.1")
        // Nothing of that family on the interface (or an unknown address): the connection's address, as before.
        #expect(address("203.0.113.9", ipv6: true) == "203.0.113.9")
    }

    /// Review finding (W4 round 4): the controller's link-local address is scoped with the HAP connection's zone, else
    /// with the interface of our address on that connection (a controller on IPv4 naming its fe80 address).
    @Test func aLinkLocalControllerAddressGetsTheHAPConnectionsZone() {
        let interfaces = [InterfaceAddress(interface: "en0", address: "fe80::1c:2d"), InterfaceAddress(interface: "en0", address: "192.168.1.20"),
                          InterfaceAddress(interface: "en1", address: "fe80::77")]
        let asked = Box(0)
        func host(_ address: String, zone: String?, local: String) -> String {
            StreamAddress.controllerHost(address, zone: zone, localAddress: local, interfaces: { asked.update { $0 += 1 }; return interfaces })
        }
        #expect(host("fe80::2", zone: "en1", local: "fe80::77") == "fe80::2%en1")
        #expect(host("FE80::2", zone: "en1", local: "fe80::77") == "FE80::2%en1")
        #expect(host("febf::2", zone: "en1", local: "fe80::77") == "febf::2%en1", "all of fe80::/10")
        #expect(asked.value == 0, "the connection's zone needs no interface list")
        #expect(host("fe80::2", zone: nil, local: "192.168.1.20") == "fe80::2%en0", "the interface of our address")
        #expect(host("fe80::2", zone: "", local: "fe80::1c:2d%en0") == "fe80::2%en0")
        #expect(host("fe80::2%en0", zone: "en1", local: "fe80::77") == "fe80::2%en0", "a scope given stays")
        #expect(host("fd00::2", zone: "en0", local: "fd00::20") == "fd00::2", "routable addresses need none")
        #expect(host("fec0::2", zone: "en0", local: "fd00::20") == "fec0::2")
        #expect(host("192.168.1.30", zone: "en0", local: "192.168.1.20") == "192.168.1.30")
        #expect(host("fe80::2", zone: nil, local: "203.0.113.9") == "fe80::2", "nothing known: as it came")
        // The machine's own list names lo0's link-local address as the lookup expects it (no embedded scope).
        #expect(StreamAddress.interfaceAddresses().contains(InterfaceAddress(interface: "lo0", address: "fe80::1")),
                "\(StreamAddress.interfaceAddresses().filter { $0.interface == "lo0" })")
    }

    /// Review finding (W4 round 4): a controller whose HAP connection runs over IPv6 link-local writes its own fe80
    /// address into SetupEndpoints, as text without a scope. Every RTP packet and sender report went to that bare
    /// address, which `sendto` refuses from the wildcard sockets the app binds (EHOSTUNREACH): no video, no audio, and a
    /// session the controller's RTCP kept alive. The HAP connection's zone scopes it. lo0's own fe80::1 stands in for the
    /// controller. (Loopback-bound sockets reach it either way; the wildcard variant below shows the failure.)
    @Test(.timeLimit(.minutes(1))) func aLinkLocalControllerIsReachedThroughTheHAPConnectionsZone() async throws {
        try await Self.streamToLinkLocalController(loopbackOnly: true)
    }

    /// `aLinkLocalControllerIsReachedThroughTheHAPConnectionsZone` from the wildcard sockets the app binds (opt-in:
    /// `CB_WILDCARD_TESTS=1 swift test --filter aLinkLocalControllerIsReachedFromTheWildcardSockets`; they listen on every
    /// interface). Before the fix no packet arrived.
    @Test(.timeLimit(.minutes(1)),
          .enabled(if: ProcessInfo.processInfo.environment["CB_WILDCARD_TESTS"] == "1", "set CB_WILDCARD_TESTS=1 to bind the wildcard address"))
    func aLinkLocalControllerIsReachedFromTheWildcardSockets() async throws {
        try await Self.streamToLinkLocalController(loopbackOnly: false)
    }

    static func streamToLinkLocalController(loopbackOnly: Bool) async throws {
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 10, gop: .seconds(1), audio: nil), loopbackOnly: loopbackOnly)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start(host: "fe80::1%lo0", ipv6: true)
        let sessionID = UUID()
        // SetupEndpoints names the controller without a scope; its HAP connection came over lo0.
        var request = Self.request(sessionID: sessionID, controller: "fe80::1", ipv6: true, local: "fe80::1", receiver: receiver)
        request.connectionZone = "lo0"
        let response = try await setup.handler.prepareStream(request)
        await receiver.connect(to: SRTPTestReceiver.Peer(host: response.accessoryAddress, videoPort: response.videoPort, audioPort: response.audioPort,
                                                         videoSSRC: response.videoSSRC, audioSSRC: response.audioSSRC, controllerVideoSSRC: 0x1111,
                                                         controllerAudioSSRC: 0x2222, videoPayloadType: 99, audioPayloadType: 110),
                               keepaliveInterval: nil)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(640, 360), audio: nil))
        let pipeline = try #require(await setup.handler.pipeline(sessionID))
        #expect(pipeline.controllerHost == "fe80::1%lo0")
        let arrived = await receiver.waitFor(timeout: .seconds(6)) { $0.keyframes >= 1 && $0.videoFrames >= 5 }
        let statistics = await receiver.statistics
        #expect(arrived, "video reaches the link-local controller: \(statistics)")
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await setup.feeder.stop()
    }

    /// Review finding (W4): video went out before the controller's first RTCP (integration brief §5.4: wait up to 1 s);
    /// with passthrough answering PLI with nothing, a lost first keyframe left the view blank for a whole GOP.
    @Test(.timeLimit(.minutes(1))) func videoWaitsForTheControllersFirstPacket() async throws {
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 10, gop: .seconds(1), audio: nil), controllerWait: .seconds(4))
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await Self.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await Self.connect(receiver, to: response, keepalive: false)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(640, 360), audio: nil))
        try await Task.sleep(for: .seconds(1))
        #expect(await receiver.statistics.videoPackets == 0, "no video before the controller spoke")
        let spoke = ContinuousClock.now
        await receiver.sendReceiverReports()
        #expect(await receiver.waitFor(timeout: .seconds(2)) { $0.keyframes >= 1 })
        let first = try #require(await receiver.firstKeyframeAt)
        #expect(first - spoke < .milliseconds(800), "the cached keyframe goes out once the controller spoke")
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()

        // A controller that stays silent still gets video after the wait.
        let silent = try await SRTPTestReceiver.start()
        let second = UUID()
        let answer = try await Self.prepare(setup.handler, receiver: silent, sessionID: second)
        await Self.connect(silent, to: answer, keepalive: false)
        let started = ContinuousClock.now
        try await setup.handler.handleStreamRequest(.start(sessionID: second, video: Self.video(640, 360), audio: nil))
        #expect(await silent.waitFor(timeout: .seconds(8)) { $0.keyframes >= 1 })
        let late = try #require(await silent.firstKeyframeAt)
        #expect(late - started >= .milliseconds(3_500) && late - started < .seconds(6))
        try await setup.handler.handleStreamRequest(.stop(sessionID: second))
        await silent.stop()
        await setup.feeder.stop()
    }

    /// Review finding (W4): the path was chosen once; a source that came back larger after a reconnect kept passing
    /// through, so a 720p session received 1080p (here: 360p and 540p, to keep the encoders light).
    @Test(.timeLimit(.minutes(2))) func aSourceFormatChangeChoosesThePathAgain() async throws {
        let hub = MediaHub()
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 10, gop: .seconds(1), audio: nil), hub: hub)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await Self.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await Self.connect(receiver, to: response)
        let sizes = SPSSizes(receiver)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(640, 360, fps: 10), audio: nil))
        let pipeline = try #require(await setup.handler.pipeline(sessionID))
        #expect(await receiver.waitFor(timeout: .seconds(5)) { $0.keyframes >= 2 })
        #expect(pipeline.videoPath == .passthrough)

        // The camera reconnects at 960×540 (IngestSupervisor: discontinuity, then the new stream).
        await setup.feeder.stop()
        await hub.discontinuity()
        let larger = HubFeeder(source: syntheticSource(width: 960, height: 540, fps: 10, gop: .seconds(1), audio: nil), hub: hub)
        #expect(await eventually(timeout: .seconds(10)) { pipeline.isTranscoding }, "the larger source is transcoded to the request")
        let seen = sizes.sizes.value.count
        #expect(await eventually(timeout: .seconds(10)) { sizes.sizes.value.count >= seen + 2 })
        #expect(sizes.sizes.value.suffix(2).allSatisfy { $0 == "640×360" }, "\(sizes.sizes.value)")
        #expect(!sizes.sizes.value.contains("960×540"))
        sizes.stop()
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await larger.stop()
    }

    /// Review finding (W4): a `.stop` that arrived while `.start` waited for the hub was lost; the abandoned start then
    /// installed a live stream for a HAP session that no longer existed.
    @Test(.timeLimit(.minutes(1))) func aStopWhileStartingWins() async throws {
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 10, gop: .seconds(1), audio: nil), leaseDelay: .milliseconds(600))
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await Self.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await Self.connect(receiver, to: response)
        let handler = setup.handler
        let start = Task { try await handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(640, 360), audio: nil)) }
        try await Task.sleep(for: .milliseconds(150))
        // RTPStreamManagement's deadline abandons (cancels) the start and stops the session.
        start.cancel()
        try await handler.handleStreamRequest(.stop(sessionID: sessionID))
        let outcome: Void? = try? await start.value
        #expect(outcome == nil, "the abandoned start fails")
        try await Task.sleep(for: .milliseconds(800))
        #expect(await handler.runningSessionCount == 0)
        #expect(await handler.pipeline(sessionID) == nil)
        #expect(setup.released.value == 1, "the hub lease is released")
        #expect(await receiver.statistics.videoPackets == 0)
        await receiver.stop()
        await setup.feeder.stop()
    }

    /// Review finding (W4): every live session opened its own talkback sink, so a second viewer's return audio closed the
    /// camera's only two-way session under the first (Hikvision `PUT …/close` before `open`).
    @Test(.timeLimit(.minutes(2))) func viewersShareTheCamerasTalkbackChannel() async throws {
        let sink = FakeTalkbackSink()
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 10, gop: .seconds(1), audio: .pcmu, audioRate: 8_000), talkback: sink)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let first = try await SRTPTestReceiver.start()
        let second = try await SRTPTestReceiver.start()
        let a = UUID(), b = UUID()
        await Self.connect(first, to: try await Self.prepare(setup.handler, receiver: first, sessionID: a))
        await Self.connect(second, to: try await Self.prepare(setup.handler, receiver: second, sessionID: b))
        try await setup.handler.handleStreamRequest(.start(sessionID: a, video: Self.video(640, 360), audio: Self.audio(rate: .khz16)))
        try await setup.handler.handleStreamRequest(.start(sessionID: b, video: Self.video(640, 360), audio: Self.audio(rate: .khz16)))
        let opus = try Self.opusSecond()

        try await Self.sendReturnAudio(opus, from: first)
        #expect(await eventually(timeout: .seconds(5)) { sink.frames.value.count >= 10 })
        // The second viewer talks while the first holds the channel: dropped, and the channel is not reopened.
        try await Self.sendReturnAudio(opus, from: second)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sink.opens.value == 1)
        #expect(sink.closes.value == 0)

        // The first viewer leaves: the channel stays open for the second one, who now gets it.
        try await setup.handler.handleStreamRequest(.stop(sessionID: a))
        #expect(sink.closes.value == 0, "another viewer still uses the channel")
        let before = sink.frames.value.count
        try await Self.sendReturnAudio(opus, from: second)
        #expect(await eventually(timeout: .seconds(5)) { sink.frames.value.count >= before + 10 })
        #expect(sink.opens.value == 1)
        try await setup.handler.handleStreamRequest(.stop(sessionID: b))
        #expect(sink.closes.value == 1, "the last viewer's end closes the channel")
        await first.stop()
        await second.stop()
        await setup.feeder.stop()
    }

    /// Review finding (W4 round 4): the return packet that opened the camera's talkback channel waited for the open inside
    /// its session's return-audio loop. What the viewer said meanwhile queued up in the session (up to 128 packets) and
    /// reached the camera in one burst once the open returned (here 1.5 s of speech within 50 ms), so the camera played
    /// everything late by the open time for as long as the viewer kept talking. Packets during the open are dropped, the
    /// opener's too, and what follows arrives at the pace it was spoken.
    @Test(.timeLimit(.minutes(1))) func speechDuringASlowTalkbackOpenIsDroppedNotPlayedLateInABurst() async throws {
        let sink = FakeTalkbackSink(openDelay: .milliseconds(1_500))
        let setup = Self.setup(source: syntheticSource(width: 320, height: 180, fps: 10, gop: .seconds(1), audio: nil), talkback: sink)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        await Self.connect(receiver, to: try await Self.prepare(setup.handler, receiver: receiver, sessionID: sessionID))
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(640, 360), audio: Self.audio(rate: .khz16)))
        // The viewer talks at the pace of speech (20 ms packets) for 3 s.
        let second = try Self.opusSecond()
        for packet in (0..<3).flatMap({ _ in second }) {
            try await receiver.sendReturnAudio(packet.data, samples: packet.sampleCount)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await eventually(timeout: .seconds(5)) { sink.openedAt.value != nil && !sink.sentAt.value.isEmpty })
        let opened = try #require(sink.openedAt.value)
        let sent = sink.sentAt.value
        let burst = sent.filter { $0 - opened < .milliseconds(100) }.count
        #expect(burst <= 10, "\(burst) frames reached the camera within 100 ms of the open (\(sent.count) in all)")
        #expect(sent.count >= 40 && sent.count <= 110, "\(sent.count) frames: what was said during the open is dropped")
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await setup.feeder.stop()
    }

    /// Review finding (W4 round 4): a reconfigure (size and bit rate) that came while the live stream's path decision was
    /// building its transcoder was overwritten by the decision: the transcoder kept the old size and bit rate for the rest
    /// of the session, and a later reconfigure to the same size could not bring the new one back.
    @Test(.timeLimit(.minutes(2))) func aReconfigureDuringTheTranscoderBuildIsNotLost() async throws {
        var codecs = WatchedTranscoderCodecs()
        codecs.creationDelay = .milliseconds(400)
        let setup = Self.setup(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), codecs: codecs)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        await Self.connect(receiver, to: try await Self.prepare(setup.handler, receiver: receiver, sessionID: sessionID))
        let sizes = SPSSizes(receiver)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: Self.video(320, 240, fps: 15, bitrate: 1000), audio: nil))
        // Congestion: the controller steps down while the first transcoder is being made.
        #expect(await eventually { codecs.creations.value == 1 })
        try await setup.handler.handleStreamRequest(.reconfigure(sessionID: sessionID, video: Self.video(160, 120, fps: 15, bitrate: 60)))
        #expect(await eventually(timeout: .seconds(10)) {
            codecs.transcoders.value.contains { $0.settings.width == 160 && $0.settings.height == 120 }
        }, "transcoders made: \(codecs.transcoders.value.map { "\($0.settings.width)×\($0.settings.height)@\($0.settings.bitrateKbps)" })")
        #expect(await eventually(timeout: .seconds(10)) { sizes.sizes.value.last == "160×120" }, "\(sizes.sizes.value)")
        // The first transcoder ran with the old size meanwhile: it got the new bit rate at once.
        let first = try #require(codecs.transcoders.value.first)
        #expect(first.settings.bitrateKbps == 60 || first.bitrates.value.contains(60), "\(first.settings.bitrateKbps) kbit/s, updates \(first.bitrates.value)")
        sizes.stop()
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await setup.feeder.stop()
    }
}
#endif

