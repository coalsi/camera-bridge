import BridgeSupport
import Foundation
import MediaCore
import Synchronization
import TestSupport
import Testing
@testable import RTP

/// A loopback stand-in for the HomeKit controller: two UDP sockets on 127.0.0.1 that unprotect everything the session
/// sends, and send SRTCP / SRTP return audio back with the stream's keys (as controllers reuse them).
final class TestController: Sendable {
    struct Received: Sendable {
        var videoSRTP: SRTPContext
        var audioSRTP: SRTPContext
        var videoRTP: [RTPPacket] = []
        var videoWireSizes: [Int] = []
        var audioRTP: [RTPPacket] = []
        var videoRTCP: [(packet: RTCPPacket, at: ContinuousClock.Instant)] = []
        var audioRTCP: [RTCPPacket] = []
        /// Every SRTCP compound as received, per socket.
        var compounds: [(video: Bool, packets: [RTCPPacket])] = []
        var errors: [String] = []
    }

    static let videoKey = Data((0..<16).map { UInt8($0) }), videoSalt = Data((100..<114).map { UInt8($0) })
    static let audioKey = Data((50..<66).map { UInt8($0) }), audioSalt = Data((200..<214).map { UInt8($0) })

    let video: UDPSocket
    let audio: UDPSocket
    let received: Box<Received>
    private let outbound: Box<(video: SRTPContext, audio: SRTPContext)>
    private let readers: Box<[Task<Void, Never>]>

    init(sourceLocation: SourceLocation = #_sourceLocation) throws {
        expectLoopbackAccess(sourceLocation: sourceLocation)
        video = try UDPSocket.bind(host: "127.0.0.1")
        audio = try UDPSocket.bind(host: "127.0.0.1")
        received = Box(Received(videoSRTP: try SRTPContext(masterKey: Self.videoKey, masterSalt: Self.videoSalt),
                                        audioSRTP: try SRTPContext(masterKey: Self.audioKey, masterSalt: Self.audioSalt)))
        outbound = Box((try SRTPContext(masterKey: Self.videoKey, masterSalt: Self.videoSalt),
                                try SRTPContext(masterKey: Self.audioKey, masterSalt: Self.audioSalt)))
        readers = Box([])
        let received = self.received
        readers.update {
            $0 = [
                Task { for await datagram in self.video.datagrams { Self.handle(datagram.data, video: true, into: received) } },
                Task { for await datagram in self.audio.datagrams { Self.handle(datagram.data, video: false, into: received) } },
            ]
        }
    }

    func close() {
        video.close()
        audio.close()
    }

    private static func handle(_ data: Data, video: Bool, into box: Box<Received>) {
        box.update { state in
            do {
                if RTPPacket.isRTCP(data) {
                    let plain = video ? try state.videoSRTP.unprotectRTCP(data) : try state.audioSRTP.unprotectRTCP(data)
                    let packets = try RTCPPacket.parseCompound(plain)
                    state.compounds.append((video, packets))
                    if video {
                        state.videoRTCP += packets.map { ($0, ContinuousClock.now) }
                    } else {
                        state.audioRTCP += packets
                    }
                } else if video {
                    state.videoRTP.append(try RTPPacket(parsing: try state.videoSRTP.unprotectRTP(data)))
                    state.videoWireSizes.append(data.count)
                } else {
                    state.audioRTP.append(try RTPPacket(parsing: try state.audioSRTP.unprotectRTP(data)))
                }
            } catch {
                state.errors.append("\(video ? "video" : "audio"): \(error)")
            }
        }
    }

    func sendRTCP(_ packets: [RTCPPacket], video: Bool, to port: UInt16) throws {
        let compound = packets.reduce(into: Data()) { $0.append($1.serialized()) }
        let protected = try outbound.update { video ? try $0.video.protectRTCP(compound) : try $0.audio.protectRTCP(compound) }
        try (video ? self.video : audio).send(protected, to: SocketAddress(host: "127.0.0.1", port: port))
    }

    func sendReturnAudio(_ packet: RTPPacket, to port: UInt16) throws {
        let protected = try outbound.update { try $0.audio.protectRTP(packet.serialized()) }
        try audio.send(protected, to: SocketAddress(host: "127.0.0.1", port: port))
    }

    var senderReports: [(ssrc: UInt32, packetCount: UInt32, at: ContinuousClock.Instant)] {
        received.value.videoRTCP.compactMap {
            if case let .senderReport(ssrc, _, _, packetCount, _, _) = $0.packet { return (ssrc, packetCount, $0.at) }
            return nil
        }
    }
}

/// A keyless on-path peer: bounces every datagram straight back to the port it came from, so the session receives its
/// own SRTP and SRTCP (which authenticate, since one key serves both directions of a stream).
final class Reflector: Sendable {
    let video: UDPSocket
    let audio: UDPSocket
    let bouncedRTCP = Atomic<Int>(0)
    let bouncedRTP = Atomic<Int>(0)
    private let readers: Box<[Task<Void, Never>]>

    init(sourceLocation: SourceLocation = #_sourceLocation) throws {
        expectLoopbackAccess(sourceLocation: sourceLocation)
        video = try UDPSocket.bind(host: "127.0.0.1")
        audio = try UDPSocket.bind(host: "127.0.0.1")
        readers = Box([])
        readers.update { $0 = [self.reflect(self.video), self.reflect(self.audio)] }
    }

    private func reflect(_ socket: UDPSocket) -> Task<Void, Never> {
        Task {
            for await datagram in socket.datagrams {
                guard (try? socket.send(datagram.data, to: datagram.from)) != nil else { continue }
                if RTPPacket.isRTCP(datagram.data) {
                    bouncedRTCP.add(1, ordering: .relaxed)
                } else {
                    bouncedRTP.add(1, ordering: .relaxed)
                }
            }
        }
    }

    func close() {
        video.close()
        audio.close()
    }
}

/// Session side of a test: its two sockets and the session itself.
struct SessionUnderTest {
    static let videoSSRC: UInt32 = 0x1111_1111, audioSSRC: UInt32 = 0x2222_2222

    let session: LiveStreamSession
    let videoSocket: UDPSocket
    let audioSocket: UDPSocket

    init(controller: TestController, withAudio: Bool = true, timeout: Duration = .seconds(30), videoKey: Data = TestController.videoKey, timings: LiveStreamTimings = .standard,
         audioCodec: AudioCodec = .opus, audioClockRate: Int = 24_000, packetTime: Duration = .milliseconds(20)) throws {
        try self.init(videoPort: controller.video.localPort, audioPort: controller.audio.localPort, withAudio: withAudio, timeout: timeout,
                      videoKey: videoKey, audioCodec: audioCodec, audioClockRate: audioClockRate, packetTime: packetTime, timings: timings)
    }

    /// Media goes to 127.0.0.1 `videoPort` / `audioPort`.
    init(videoPort: UInt16, audioPort: UInt16, withAudio: Bool = true, timeout: Duration = .seconds(30), videoKey: Data = TestController.videoKey,
         audioCodec: AudioCodec = .opus, audioClockRate: Int = 24_000, packetTime: Duration = .milliseconds(20),
         destinationHost: String = "127.0.0.1", advertisedController: String? = nil, timings: LiveStreamTimings = .standard) throws {
        videoSocket = try UDPSocket.bind(host: "127.0.0.1")
        audioSocket = try UDPSocket.bind(host: "127.0.0.1")
        let video = LiveVideoParameters(payloadType: 99, ssrc: Self.videoSSRC, srtpKey: videoKey, srtpSalt: TestController.videoSalt, maxPacketSize: 1200,
                                        rtcpInterval: .milliseconds(500))
        let audio = LiveAudioParameters(codec: audioCodec, payloadType: 110, ssrc: Self.audioSSRC, srtpKey: TestController.audioKey,
                                        srtpSalt: TestController.audioSalt, rtpClockRate: audioClockRate, packetTime: packetTime, rtcpInterval: .milliseconds(500))
        session = LiveStreamSession(controller: SocketAddress(host: destinationHost, port: 0), videoPort: videoPort, audioPort: audioPort,
                                    videoSocket: videoSocket, audioSocket: audioSocket, video: video, audio: withAudio ? audio : nil,
                                    controllerTimeout: timeout, advertisedController: advertisedController, timings: timings)
    }

    /// The session's end reason, or nil if it has not ended within `timeout`.
    func endReason(within timeout: Duration) async -> LiveStreamEndReason? {
        let box = Box<LiveStreamEndReason?>(nil)
        let session = self.session
        Task { let reason = await session.waitForEnd(); box.update { $0 = reason } }
        _ = await eventually(timeout: timeout) { box.value != nil }
        return box.value
    }
}

enum Frames {
    static let sps = Data([0x67, 0x42, 0xC0, 0x1F, 0xDA, 0x01, 0x40, 0x16, 0xE8, 0x40])
    static let pps = Data([0x68, 0xCE, 0x3C, 0x80])
    static let format = VideoFormat(codec: .h264, width: 1280, height: 720, parameterSets: [sps, pps])

    /// Frame `index`: a keyframe every 30 frames (IDR of 4000 bytes), otherwise a P slice of 300–2700 bytes.
    static func video(_ index: Int) -> EncodedVideoFrame {
        let keyframe = index % 30 == 0
        let size = keyframe ? 4_000 : 300 + (index * 997) % 2_400
        let nal = Data([keyframe ? 0x65 : 0x41]) + Data((1..<size).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ index) })
        return EncodedVideoFrame(format: format, nalUnits: [nal], isKeyframe: keyframe, pts: MediaTime(value: Int64(index) * 3_000, timescale: 90_000),
                                 wallClock: Date())
    }

    /// Yields `frames` (then finishes if `finish`), one every `interval`.
    static func stream<Frame: Sendable>(_ frames: [Frame], interval: Duration, finish: Bool) -> AsyncStream<Frame> {
        let (stream, continuation) = AsyncStream.makeStream(of: Frame.self)
        Task {
            for frame in frames {
                continuation.yield(frame)
                try? await Task.sleep(for: interval)
            }
            if finish { continuation.finish() }
        }
        return stream
    }

    static func open<Frame: Sendable>(_: Frame.Type) -> AsyncStream<Frame> {
        AsyncStream.makeStream(of: Frame.self).stream
    }
}

/// Loopback only: the session and the test controller use 127.0.0.1 sockets.
@Suite(.timeLimit(.minutes(1)), .loopback) struct LiveStreamSessionTests {
    @Test func streamsSRTPVideoKeyframeFirstWithSenderReports() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, withAudio: false)
        // A delta frame before the first keyframe is dropped.
        var leadingDelta = Frames.video(1)
        leadingDelta.pts = MediaTime(value: -3_000, timescale: 90_000)
        let frames = [leadingDelta] + (0..<45).map(Frames.video)
        let started = ContinuousClock.now
        await sut.session.start(video: Frames.stream(frames, interval: .milliseconds(33), finish: false), audio: nil)

        #expect(await eventually(timeout: .seconds(10)) { controller.received.value.videoRTP.filter(\.marker).count >= 45 })
        #expect(await eventually(timeout: .seconds(3)) { controller.senderReports.count >= 3 })
        let reports = controller.senderReports   // periodic ones; stopping adds a final SR with the BYE
        await sut.session.stop()
        #expect(await sut.session.waitForEnd() == .stopped)
        let elapsed = ContinuousClock.now - started

        let received = controller.received.value
        #expect(received.errors.isEmpty, "\(received.errors)")
        #expect(received.videoWireSizes.allSatisfy { $0 <= 1200 })
        #expect(received.videoRTP.allSatisfy { $0.ssrc == SessionUnderTest.videoSSRC && $0.payloadType == 99 })
        for (previous, next) in zip(received.videoRTP, received.videoRTP.dropFirst()) {
            #expect(next.sequenceNumber == previous.sequenceNumber &+ 1)
        }
        var depacketizer = H264TestDepacketizer()
        var units: [(nals: [Data], timestamp: UInt32)] = []
        for packet in received.videoRTP {
            if let nals = try depacketizer.push(packet) { units.append((nals, packet.timestamp)) }
        }
        #expect(units.count == 45)
        #expect(units.first?.nals == [Frames.sps, Frames.pps] + Frames.video(0).nalUnits)
        for (index, unit) in units.enumerated() {
            let expected = Frames.video(index)
            #expect(unit.nals == (expected.isKeyframe ? [Frames.sps, Frames.pps] : []) + expected.nalUnits)
            #expect(unit.timestamp &- units[0].timestamp == UInt32(index * 3_000))
        }

        // Sender reports about every 0.5 s, for the video SSRC, counting the packets sent so far.
        #expect(reports.allSatisfy { $0.ssrc == SessionUnderTest.videoSSRC && $0.packetCount > 0 })
        #expect(reports.count <= Int(elapsed / .milliseconds(500)) + 1)
        for (previous, next) in zip(reports, reports.dropFirst()) {
            let gap = next.at - previous.at
            #expect(gap > .milliseconds(300) && gap < .milliseconds(800), "SR gap \(gap)")
            #expect(next.packetCount >= previous.packetCount)
        }
        // Stopping sends SR + BYE in one compound; every compound starts with a report (RFC 3550 §6.1).
        #expect(await eventually(timeout: .seconds(2)) { controller.received.value.videoRTCP.contains { $0.packet == .bye(ssrcs: [SessionUnderTest.videoSSRC]) } })
        let compounds = controller.received.value.compounds
        #expect(compounds.allSatisfy { $0.video && $0.packets.first.map(Self.isReport) == true }, "\(compounds.map(\.packets))")
        #expect(compounds.last.map { $0.packets.count == 2 && $0.packets.last == .bye(ssrcs: [SessionUnderTest.videoSSRC]) } == true)
    }

    /// Symmetric RTP latching: the controller advertised an address the media cannot reach (here a TEST-NET address standing
    /// for a VPN's); its first authenticated packet arrives from 127.0.0.1, and the media (advertised ports) follows.
    @Test func theDestinationLatchesOntoTheSourceOfTheFirstAuthenticatedControllerPacket() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(videoPort: controller.video.localPort, audioPort: controller.audio.localPort, withAudio: false,
                                       destinationHost: "192.0.2.1", advertisedController: "192.0.2.1")
        await sut.session.start(video: Frames.stream((0..<200).map(Frames.video), interval: .milliseconds(20), finish: false), audio: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.received.value.videoRTP.isEmpty, "nothing reaches the controller before it is heard from")
        #expect(await sut.session.timeline.latchedDestination == nil)
        try controller.sendRTCP([.receiverReport(ssrc: 0xC0C0_C0C0)], video: true, to: sut.videoSocket.localPort)
        #expect(await eventually(timeout: .seconds(5)) { controller.received.value.videoRTP.count >= 5 }, "the media follows the controller")
        #expect(await sut.session.timeline.latchedDestination == "127.0.0.1")
        #expect(controller.received.value.errors.isEmpty, "\(controller.received.value.errors)")
        await sut.session.stop()
        _ = await sut.session.waitForEnd()
    }

    /// A datagram that does not authenticate (no key: anyone on the path) never moves the destination, and a source that is
    /// already the destination is no change.
    @Test func onlyAuthenticatedPacketsLatchAndTheDestinationItselfIsNoChange() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(videoPort: controller.video.localPort, audioPort: controller.audio.localPort, withAudio: false,
                                       destinationHost: "192.0.2.1")
        await sut.session.start(video: Frames.open(EncodedVideoFrame.self), audio: nil)
        let stranger = try UDPSocket.bind(host: "127.0.0.1")
        defer { stranger.close() }
        var wrongKeys = try SRTPContext(masterKey: Data(repeating: 9, count: 16), masterSalt: Data(repeating: 8, count: 14))
        let forged = try wrongKeys.protectRTCP(RTCPPacket.receiverReport(ssrc: 0xBAD0_BAD0).serialized())
        try stranger.send(forged, to: SocketAddress(host: "127.0.0.1", port: sut.videoSocket.localPort))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await sut.session.timeline.latchedDestination == nil)
        #expect(await sut.session.timeline.controllerRTCPPackets == 0)
        await sut.session.stop()
        _ = await sut.session.waitForEnd()

        // The destination already is the packet's source: nothing latches.
        let same = try SessionUnderTest(controller: controller, withAudio: false)
        await same.session.start(video: Frames.open(EncodedVideoFrame.self), audio: nil)
        try controller.sendRTCP([.receiverReport(ssrc: 0xC0C0_C0C0)], video: true, to: same.videoSocket.localPort)
        #expect(await same.session.waitForController(timeout: .seconds(5)))
        #expect(await same.session.timeline.latchedDestination == nil)
        await same.session.stop()
        _ = await same.session.waitForEnd()
    }

    @Test func hostsAreComparedAsAddresses() {
        #expect(SocketAddress.sameHost("198.51.100.20", "198.51.100.20"))
        #expect(SocketAddress.sameHost("::ffff:198.51.100.20", "198.51.100.20"))
        #expect(SocketAddress.sameHost("fe80::1%en0", "FE80:0:0:0:0:0:0:1"))
        #expect(SocketAddress.sameHost("[2001:db8::1]", "2001:db8:0::1"))
        #expect(!SocketAddress.sameHost("10.5.0.2", "198.51.100.20"))
        #expect(!SocketAddress.sameHost("fe80::1", "fe80::2"))
    }

    static func isReport(_ packet: RTCPPacket) -> Bool {
        switch packet {
        case .senderReport, .receiverReport: true
        default: false
        }
    }

    @Test func controllerRTCPKeepsTheSessionAliveUntilItStops() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, timeout: .seconds(1))
        await sut.session.start(video: Frames.open(EncodedVideoFrame.self), audio: nil)
        var lastKeepalive = ContinuousClock.now
        for index in 0..<20 {   // 2.5 s of receiver reports every 125 ms, alternating sockets
            try await Task.sleep(for: .milliseconds(125))
            let onVideo = index.isMultiple(of: 2)
            try controller.sendRTCP([.receiverReport(ssrc: 0xC0C0_C0C0)], video: onVideo, to: onVideo ? sut.videoSocket.localPort : sut.audioSocket.localPort)
            lastKeepalive = ContinuousClock.now
        }
        #expect(await sut.endReason(within: .milliseconds(1)) == nil)
        let reason = await sut.endReason(within: .seconds(5))
        #expect(reason == .controllerTimeout)
        let silence = ContinuousClock.now - lastKeepalive
        #expect(silence >= .milliseconds(900) && silence < .seconds(3), "ended after \(silence) of silence")
    }

    /// Any authenticated controller packet is a keepalive, including return audio without any RTCP.
    @Test func returnAudioAloneKeepsTheSessionAlive() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, timeout: .seconds(1))
        await sut.session.start(video: Frames.open(EncodedVideoFrame.self), audio: nil)
        var lastPacket = ContinuousClock.now
        for index in 0..<20 {   // 2.5 s of return audio every 125 ms
            try await Task.sleep(for: .milliseconds(125))
            let packet = RTPPacket(payloadType: 110, sequenceNumber: UInt16(index), timestamp: UInt32(index * 480), ssrc: 0x3333, payload: Data([0x78, UInt8(index)]))
            try controller.sendReturnAudio(packet, to: sut.audioSocket.localPort)
            lastPacket = ContinuousClock.now
        }
        #expect(await sut.endReason(within: .milliseconds(1)) == nil)
        #expect(await sut.endReason(within: .seconds(5)) == .controllerTimeout)
        let silence = ContinuousClock.now - lastPacket
        #expect(silence >= .milliseconds(900) && silence < .seconds(3), "ended after \(silence) of silence")
        #expect(controller.received.value.compounds.isEmpty, "no media was sent, so no RTCP either")
    }

    /// RFC 3550 §6.3.7: a participant that never sent RTP or RTCP must not send BYE (and §6.1: no compound without
    /// a leading report). Ending before the first keyframe and before any audio sends no RTCP at all.
    /// The media pipeline in front of the session can end it with its own reason (`end(reason:)`): `waitForEnd`, the timeline and the
    /// log line say what it was, not "stopped"; ending it again changes nothing.
    @Test func aSessionEndedWithAPipelineReasonReportsIt() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller)
        await sut.session.start(video: Frames.open(EncodedVideoFrame.self), audio: nil)
        await sut.session.end(reason: .pipelineFailed("the video encoder could not be made"))
        await sut.session.stop()
        let reason = await sut.endReason(within: .seconds(2))
        #expect(reason == .pipelineFailed("the video encoder could not be made"))
        #expect(await sut.session.timeline.endReason == reason)
        #expect(reason?.description == "pipelineFailed: the video encoder could not be made")
        #expect(LiveStreamEndReason.stopped.description == "stopped")
    }

    @Test func endingBeforeAnyMediaSendsNoRTCP() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller)
        // Delta frames only: all dropped while waiting for a keyframe. The audio source never yields.
        await sut.session.start(video: Frames.stream((1..<20).map(Frames.video), interval: .milliseconds(33), finish: false),
                                audio: Frames.open(EncodedAudioFrame.self))
        try await Task.sleep(for: .milliseconds(700))   // past one rtcpInterval
        await sut.session.stop()
        #expect(await sut.session.waitForEnd() == .stopped)
        try await Task.sleep(for: .milliseconds(200))
        let received = controller.received.value
        #expect(received.videoRTP.isEmpty && received.audioRTP.isEmpty)
        #expect(received.compounds.isEmpty, "\(received.compounds.map(\.packets))")
    }

    /// Review W1-4: a UDP flood at the session's ports used to hold `stop()` for as long as it lasted.
    @Test(.loopbackFlood) func stopIsPromptDuringAUDPFlood() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller)
        await sut.session.start(video: Frames.stream((0..<200).map(Frames.video), interval: .milliseconds(33), finish: false), audio: nil)
        let videoPort = sut.videoSocket.localPort, audioPort = sut.audioSocket.localPort
        // Unauthenticated SRTCP-looking (SR) and SRTP-looking datagrams: each costs the session an HMAC check.
        let floods = [
            try LoopbackFlood(ports: [videoPort, audioPort], payload: Data([0x80, 0xC8, 0x00, 0x06]) + Data(repeating: 0x5A, count: 60), senders: 4),
            try LoopbackFlood(ports: [audioPort], payload: Data([0x80, 0x6E, 0x00, 0x01]) + Data(repeating: 0x5A, count: 160), senders: 4),
        ]
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        await sut.session.stop()
        let reason = await sut.session.waitForEnd()
        let stopping = ContinuousClock.now - started
        let flooding = floods.map { $0.sent.load(ordering: .relaxed) }
        for flood in floods { await flood.stop() }

        #expect(reason == .stopped)
        #expect(stopping < .milliseconds(500), "stop() + waitForEnd() took \(stopping) during the flood")
        #expect(zip(floods, flooding).allSatisfy { $0.sent.load(ordering: .relaxed) > $1 }, "the flood stopped before the session did")
        #expect(controller.received.value.videoRTP.contains { $0.marker }, "video flowed during the flood")
        // waitForEnd() returns after both descriptors are closed: the ports are free again.
        for port in [videoPort, audioPort] {
            let rebound = try UDPSocket.bind(host: "127.0.0.1", port: port)
            rebound.close()
        }
    }

    /// AAC-ELD end to end: RFC 3640 AU headers on the wire (marker on every packet, +480 per 480-sample frame at
    /// 16 kHz) and return audio split back into AUs with the ELD AudioSpecificConfig.
    @Test func aacELDAudioAndReturnAudioUseRFC3640() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, audioCodec: .aacELD, audioClockRate: 16_000, packetTime: .milliseconds(30))
        let accessUnits = (0..<20).map { index in Data((0..<(40 + index * 7)).map { UInt8(truncatingIfNeeded: $0 &* 3 &+ index) }) }
        let audioFrames = accessUnits.enumerated().map { index, unit in
            EncodedAudioFrame(format: AudioFormat(codec: .aacELD, sampleRate: 16_000, channels: 1), data: unit,
                              pts: MediaTime(value: 32_000 + Int64(index) * 480, timescale: 16_000), sampleCount: 480, wallClock: Date())
        }
        await sut.session.start(video: Frames.open(EncodedVideoFrame.self), audio: Frames.stream(audioFrames, interval: .milliseconds(30), finish: false))
        async let returned = collect(sut.session.returnAudio, count: 3)
        try await Task.sleep(for: .milliseconds(50))
        for index in 0..<3 {
            let packet = RTPPacket(marker: true, payloadType: 110, sequenceNumber: UInt16(900 + index), timestamp: 5_000 + UInt32(index * 480), ssrc: 0x3333,
                                   payload: RFC3640.payload(for: accessUnits[index]))
            try controller.sendReturnAudio(packet, to: sut.audioSocket.localPort)
        }
        #expect(await eventually { controller.received.value.audioRTP.count == accessUnits.count })
        let frames = await returned
        await sut.session.stop()

        let received = controller.received.value
        #expect(received.errors.isEmpty, "\(received.errors)")
        for (packet, unit) in zip(received.audioRTP, accessUnits) {
            let header = UInt16(unit.count) << 3
            #expect(packet.payload == Data([0x00, 0x10, UInt8(header >> 8), UInt8(truncatingIfNeeded: header)]) + unit)
            #expect(packet.marker && packet.payloadType == 110 && packet.ssrc == SessionUnderTest.audioSSRC)
        }
        for (index, packet) in received.audioRTP.enumerated() {
            #expect(packet.timestamp &- received.audioRTP[0].timestamp == UInt32(index * 480))
        }
        #expect(frames.map(\.data) == Array(accessUnits.prefix(3)))
        #expect(frames.map(\.pts.value) == [0, 480, 960])
        #expect(frames.allSatisfy {
            $0.format.codec == .aacELD && $0.format.sampleRate == 16_000 && $0.sampleCount == 480
                && $0.format.audioSpecificConfig == Data([0xF8, 0xF0, 0x30, 0x00])
        })
    }

    /// Review (reflection): a peer with no keys bounced the session's own SR and audio back. They authenticated with the
    /// stream's key, so they satisfied `waitForController`, kept the session alive past the controller timeout and came
    /// out as return audio (which opens the camera's talkback). A packet carrying the session's own SSRC is a loop
    /// (RFC 3550 §8.2), never the controller.
    @Test func ownPacketsReflectedBackAreNotTheController() async throws {
        let reflector = try Reflector()
        defer { reflector.close() }
        let sut = try SessionUnderTest(videoPort: reflector.video.localPort, audioPort: reflector.audio.localPort, timeout: .seconds(2))
        let audioFrames = (0..<200).map { index in   // 4 s of Opus with the session's audio payload type
            EncodedAudioFrame(format: AudioFormat(codec: .opus, sampleRate: 24_000, channels: 1), data: Data([0x78, UInt8(truncatingIfNeeded: index), 0x55]),
                              pts: MediaTime(value: Int64(index) * 480, timescale: 24_000), sampleCount: 480, wallClock: Date())
        }
        let started = ContinuousClock.now
        await sut.session.start(video: Frames.stream((0..<120).map(Frames.video), interval: .milliseconds(33), finish: false),
                                audio: Frames.stream(audioFrames, interval: .milliseconds(20), finish: false))
        async let returned = collect(sut.session.returnAudio, count: 1, timeout: .seconds(5))

        #expect(await sut.session.waitForController(timeout: .milliseconds(1500)) == false, "the session's own RTCP is not the controller")
        let reason = await sut.endReason(within: .seconds(5))
        #expect(reason == .controllerTimeout, "reflected RTCP kept the session alive")
        let lifetime = ContinuousClock.now - started
        #expect(lifetime < .seconds(4), "ended after \(lifetime) with a 2 s controller timeout")
        #expect(await returned.isEmpty, "the session's own audio came back as return audio")
        // The reflection did happen: sender reports on both sockets and audio RTP went back to the session.
        #expect(reflector.bouncedRTCP.load(ordering: .relaxed) >= 4)
        #expect(reflector.bouncedRTP.load(ordering: .relaxed) >= 50)
        await sut.session.stop()
    }

    /// The loop check reads the SSRC SRTP/SRTCP leave in the clear, from `Data` slices too.
    @Test func senderSSRCIsReadFromTheClearHeader() {
        let rtp = RTPPacket(payloadType: 110, sequenceNumber: 7, timestamp: 9, ssrc: 0xDEAD_BEEF, payload: Data([1, 2])).serialized()
        #expect(LiveStreamSession.senderSSRC(rtp, isRTCP: false) == 0xDEAD_BEEF)
        #expect(LiveStreamSession.senderSSRC((Data([0xFF, 0xFF, 0xFF]) + rtp).dropFirst(3), isRTCP: false) == 0xDEAD_BEEF)
        let rtcp = RTCPPacket.receiverReport(ssrc: 0x0102_0304).serialized()
        #expect(LiveStreamSession.senderSSRC(rtcp, isRTCP: true) == 0x0102_0304)
        #expect(LiveStreamSession.senderSSRC((Data([0xAA]) + rtcp).dropFirst(), isRTCP: true) == 0x0102_0304)
        #expect(LiveStreamSession.senderSSRC(Data(count: 11), isRTCP: false) == nil)
        #expect(LiveStreamSession.senderSSRC(Data(count: 7), isRTCP: true) == nil)
    }

    /// A shorter wait timing out must not release another caller's longer wait (the pipeline waits for the controller in two
    /// places with different timeouts; the first one to time out used to release both).
    @Test func eachControllerWaitEndsOnItsOwnTimeout() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, timeout: .seconds(30))
        await sut.session.start(video: Frames.open(EncodedVideoFrame.self), audio: nil)
        let started = ContinuousClock.now
        async let long = sut.session.waitForController(timeout: .milliseconds(1_200))
        async let short = sut.session.waitForController(timeout: .milliseconds(200))
        #expect(await short == false)
        let shortTook = ContinuousClock.now - started
        #expect(await long == false)
        let longTook = ContinuousClock.now - started
        #expect(shortTook < .milliseconds(800), "the short wait ended after \(shortTook)")
        #expect(longTook >= .milliseconds(1_100), "the long wait was released early, after \(longTook)")
        // Once the controller speaks, every waiter returns at once.
        async let waiting = sut.session.waitForController(timeout: .seconds(20))
        try await Task.sleep(for: .milliseconds(100))
        try controller.sendRTCP([.receiverReport(ssrc: 0x1111)], video: true, to: sut.videoSocket.localPort)
        #expect(await waiting == true)
        await sut.session.stop()
    }

    @Test func endsWithoutAnyControllerRTCP() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, timeout: .seconds(1))
        let started = ContinuousClock.now
        await sut.session.start(video: Frames.open(EncodedVideoFrame.self), audio: nil)
        #expect(await sut.endReason(within: .seconds(5)) == .controllerTimeout)
        #expect(ContinuousClock.now - started >= .milliseconds(900))
        // The session owns its sockets and has closed them.
        #expect(throws: UDPSocketError.closed) { try sut.videoSocket.send(Data([1]), to: SocketAddress(host: "127.0.0.1", port: 9)) }
        #expect(throws: UDPSocketError.closed) { try sut.audioSocket.send(Data([1]), to: SocketAddress(host: "127.0.0.1", port: 9)) }
    }

    @Test func returnAudioIsDecryptedAndDepacketized() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller)
        await sut.session.start(video: Frames.open(EncodedVideoFrame.self), audio: nil)
        let port = sut.audioSocket.localPort
        async let frames = collect(sut.session.returnAudio, count: 5)
        try await Task.sleep(for: .milliseconds(50))
        // Garbage, a forged packet and comfort noise are ignored.
        try controller.audio.send(Data([0x80, 0x6E, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]), to: SocketAddress(host: "127.0.0.1", port: port))
        var forger = try SRTPContext(masterKey: Data(repeating: 9, count: 16), masterSalt: TestController.audioSalt)
        try controller.audio.send(try forger.protectRTP(RTPPacket(payloadType: 110, sequenceNumber: 1, timestamp: 0, ssrc: 0x3333, payload: Data([0xFF])).serialized()),
                                  to: SocketAddress(host: "127.0.0.1", port: port))
        try controller.sendReturnAudio(RTPPacket(payloadType: 13, sequenceNumber: 499, timestamp: 0, ssrc: 0x3333, payload: Data([0x40])), to: port)
        for index in 0..<5 {
            let packet = RTPPacket(payloadType: 110, sequenceNumber: UInt16(500 + index), timestamp: 7_000 + UInt32(index * 480), ssrc: 0x3333,
                                   payload: Data([0x78, UInt8(index), 0xAA]))
            try controller.sendReturnAudio(packet, to: port)
        }
        let received = await frames
        #expect(received.map(\.data) == (0..<5).map { Data([0x78, UInt8($0), 0xAA]) })
        #expect(received.map(\.pts.value) == [0, 480, 960, 1_440, 1_920])
        #expect(received.allSatisfy { $0.format.codec == .opus && $0.format.sampleRate == 24_000 && $0.pts.timescale == 24_000 && $0.sampleCount == 480 })
        await sut.session.stop()
    }

    @Test func pictureLossAndFullIntraRequestsAskForKeyframes() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller)
        await sut.session.start(video: Frames.open(EncodedVideoFrame.self), audio: nil)
        let requests = Box(0)
        let reader = Task { for await _ in sut.session.keyframeRequests { requests.update { $0 += 1 } } }
        try await Task.sleep(for: .milliseconds(50))
        try controller.sendRTCP([.receiverReport(ssrc: 0xC0C0_C0C0), .pictureLossIndication(senderSSRC: 0xC0C0_C0C0, mediaSSRC: SessionUnderTest.videoSSRC)],
                                video: true, to: sut.videoSocket.localPort)
        #expect(await eventually { requests.value == 1 })
        try controller.sendRTCP([.fullIntraRequest(senderSSRC: 0xC0C0_C0C0, mediaSSRC: SessionUnderTest.videoSSRC)], video: true, to: sut.videoSocket.localPort)
        #expect(await eventually { requests.value == 2 })
        // Unauthenticated RTCP is ignored.
        try controller.video.send(RTCPPacket.pictureLossIndication(senderSSRC: 1, mediaSSRC: 2).serialized() + Data(count: 14),
                                  to: SocketAddress(host: "127.0.0.1", port: sut.videoSocket.localPort))
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests.value == 2)
        await sut.session.stop()
        // Ending the session finishes the stream.
        await reader.value
    }

    @Test func audioIsSentAsSRTPWithTimestampsAtTheNegotiatedClock() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller)
        // Encoder output at 48 kHz (960 samples = 20 ms); the negotiated RTP clock is 24 kHz → +480 per packet.
        let audioFrames = (0..<40).map { index in
            EncodedAudioFrame(format: AudioFormat(codec: .opus, sampleRate: 48_000, channels: 1), data: Data([0x78, UInt8(index)]),
                              pts: MediaTime(value: 96_000 + Int64(index) * 960, timescale: 48_000), sampleCount: 960, wallClock: Date())
        }
        await sut.session.start(video: Frames.open(EncodedVideoFrame.self), audio: Frames.stream(audioFrames, interval: .milliseconds(20), finish: false))
        #expect(await eventually { controller.received.value.audioRTP.count == 40 })
        #expect(await eventually(timeout: .seconds(2)) { controller.received.value.audioRTCP.contains { if case .senderReport = $0 { true } else { false } } })
        await sut.session.stop()
        let received = controller.received.value
        #expect(received.errors.isEmpty, "\(received.errors)")
        #expect(received.audioRTP.map(\.payload) == audioFrames.map(\.data))
        #expect(received.audioRTP.allSatisfy { $0.payloadType == 110 && $0.ssrc == SessionUnderTest.audioSSRC })
        for (index, packet) in received.audioRTP.enumerated() {
            #expect(packet.timestamp &- received.audioRTP[0].timestamp == UInt32(index * 480))
        }
        let reports = received.audioRTCP.compactMap { if case let .senderReport(ssrc, _, _, count, _, _) = $0 { (ssrc, count) } else { nil } }
        #expect(reports.allSatisfy { $0.0 == SessionUnderTest.audioSSRC && $0.1 > 0 })
        // No video was sent (no keyframe arrived), so no video RTCP either: no SR and no lone BYE (RFC 3550 §6.3.7).
        #expect(await eventually(timeout: .seconds(2)) { controller.received.value.audioRTCP.contains { $0 == .bye(ssrcs: [SessionUnderTest.audioSSRC]) } })
        let compounds = controller.received.value.compounds
        #expect(received.videoRTP.isEmpty && compounds.allSatisfy { !$0.video }, "\(compounds.map(\.packets))")
        #expect(compounds.allSatisfy { $0.packets.first.map(Self.isReport) == true }, "\(compounds.map(\.packets))")
    }

    @Test func videoSourceEndingEndsTheSession() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller)
        await sut.session.start(video: Frames.stream((0..<3).map(Frames.video), interval: .milliseconds(10), finish: true), audio: nil)
        #expect(await sut.endReason(within: .seconds(5)) == .sourceEnded)
        // Both output streams finish.
        #expect(await collect(sut.session.returnAudio, count: 1, timeout: .seconds(2)).isEmpty)
        #expect(await collect(sut.session.keyframeRequests, count: 1, timeout: .seconds(2)).isEmpty)
        #expect(await eventually { controller.received.value.videoRTP.filter(\.marker).count == 3 })
    }

    @Test func stopBeforeStartAndRepeatedCallsAreHarmless() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller)
        async let first = sut.session.waitForEnd()
        async let second = sut.session.waitForEnd()
        await sut.session.stop()
        let reasons = await (first, second)
        #expect(reasons.0 == .stopped && reasons.1 == .stopped)
        await sut.session.start(video: Frames.stream([Frames.video(0)], interval: .milliseconds(1), finish: false), audio: nil)   // ignored
        await sut.session.stop()
        #expect(await sut.session.waitForEnd() == .stopped)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.received.value.videoRTP.isEmpty)
    }

    @Test func invalidSRTPParametersEndTheSession() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, videoKey: Data(count: 5))
        await sut.session.start(video: Frames.open(EncodedVideoFrame.self), audio: nil)
        guard case .socketError(let message)? = await sut.endReason(within: .seconds(2)) else {
            Issue.record("expected socketError")
            return
        }
        #expect(message.contains("SRTP"))
    }
}
