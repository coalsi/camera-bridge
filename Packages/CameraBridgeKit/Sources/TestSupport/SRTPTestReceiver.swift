import BridgeSupport
import Foundation
import MediaCore
import RTP

/// One audio RTP packet (an Opus frame on HomeKit streams) as received.
public struct ReceivedAudioFrame: Sendable {
    public var payload: Data
    public var rtpTimestamp: UInt32
    public var sequenceNumber: UInt16
    public var payloadType: UInt8
    public var ssrc: UInt32
    public var marker: Bool
    public var receivedAt: ContinuousClock.Instant
}

/// The controller end of a HomeKit live stream (research brief §3.6): two UDP sockets (video, audio) that decrypt the
/// accessory's SRTP/SRTCP, reassemble H.264 access units and Opus frames, and send what a controller sends back —
/// SRTCP receiver reports (the keepalive), PLI keyframe requests and SRTP return audio.
///
/// Both directions of a stream use the one key/salt the controller put in SetupEndpoints (accessories echo it).
/// Bind to loopback in tests. Statistics count every anomaly (authentication failures, SSRC mismatches, gaps) so a
/// test can assert on them.
public actor SRTPTestReceiver {
    public struct Statistics: Sendable, Equatable {
        public var videoPackets = 0
        public var audioPackets = 0
        public var videoFrames = 0
        public var incompleteVideoFrames = 0
        public var keyframes = 0
        public var audioFrames = 0
        /// Packets with another payload type than the selected one (e.g. comfort noise 13).
        public var otherAudioPackets = 0
        public var videoSenderReports = 0
        public var audioSenderReports = 0
        public var byes = 0
        public var authenticationFailures = 0
        public var malformedPackets = 0
        public var unexpectedSSRCPackets = 0
        public var sequenceGaps = 0
        /// Largest SRTP datagram received (bytes on the wire).
        public var largestVideoDatagram = 0
        public var receiverReportsSent = 0
        public var keyframeRequestsSent = 0
        public var returnAudioPacketsSent = 0
        public init() {}
    }

    /// Where the accessory's media comes from and what the controller selected (from SetupEndpoints + the start
    /// command). Needed before sending RTCP or return audio; received media is decrypted either way.
    public struct Peer: Sendable, Equatable {
        public var host: String
        public var videoPort: UInt16
        public var audioPort: UInt16
        /// The accessory's SSRCs from SetupEndpoints; packets with other SSRCs are counted and dropped. nil = accept any.
        public var videoSSRC: UInt32?
        public var audioSSRC: UInt32?
        /// Our SSRCs from SelectedRTPStreamConfiguration.
        public var controllerVideoSSRC: UInt32
        public var controllerAudioSSRC: UInt32
        public var videoPayloadType: UInt8?
        public var audioPayloadType: UInt8?

        public init(host: String, videoPort: UInt16, audioPort: UInt16, videoSSRC: UInt32? = nil, audioSSRC: UInt32? = nil,
                    controllerVideoSSRC: UInt32, controllerAudioSSRC: UInt32, videoPayloadType: UInt8? = nil, audioPayloadType: UInt8? = nil) {
            self.host = host
            self.videoPort = videoPort
            self.audioPort = audioPort
            self.videoSSRC = videoSSRC
            self.audioSSRC = audioSSRC
            self.controllerVideoSSRC = controllerVideoSSRC
            self.controllerAudioSSRC = controllerAudioSSRC
            self.videoPayloadType = videoPayloadType
            self.audioPayloadType = audioPayloadType
        }
    }

    /// A compact record of every video access unit (for frame-rate / keyframe-latency checks).
    public struct FrameRecord: Sendable, Equatable {
        public var rtpTimestamp: UInt32
        public var receivedAt: ContinuousClock.Instant
        public var isKeyframe: Bool
        public var isComplete: Bool
        public var byteCount: Int
    }

    /// What the controller's receiver reports say about the accessory's streams (RFC 3550 §6.4.1).
    public enum ReportBlocks: Sendable, Equatable {
        /// A block per stream with what this receiver really got: highest sequence number, packets lost (a healthy iPhone).
        case counting
        /// No block: reports only prove the controller is alive (an iPhone that receives nothing sends exactly this).
        case none
        /// A block whose highest sequence number stays at the value reached when this was set (a stream that stopped arriving).
        case frozen
    }

    /// What one stream's receiver reports are made of (RFC 3550 appendix A.1, without jitter).
    struct ReceptionState: Sendable, Equatable {
        var ssrc: UInt32?
        var baseSequence: UInt16?
        var maxSequence: UInt16 = 0
        var cycles: UInt32 = 0
        var received = 0
        var expectedPrior = 0
        var receivedPrior = 0
        /// The extended highest sequence number a `.frozen` block keeps repeating.
        var frozenAt: UInt32?

        mutating func note(sequence: UInt16, ssrc: UInt32) {
            self.ssrc = ssrc
            received += 1
            guard baseSequence != nil else {
                baseSequence = sequence
                maxSequence = sequence
                return
            }
            if sequence &- maxSequence < 0x8000 {
                if sequence < maxSequence { cycles &+= 1 << 16 }
                maxSequence = sequence
            }
        }

        var extendedHighest: UInt32 { cycles | UInt32(maxSequence) }

        /// The report block for now (`.counting`), nil before any packet; advances the loss interval.
        mutating func block(_ mode: ReportBlocks) -> RTCPReportBlock? {
            guard let ssrc, let base = baseSequence else { return nil }
            let highest = extendedHighest
            let expected = Int(highest) - Int(base) + 1
            let lost = max(0, expected - received)
            let expectedInterval = expected - expectedPrior, receivedInterval = received - receivedPrior
            expectedPrior = expected
            receivedPrior = received
            let lostInterval = expectedInterval - receivedInterval
            let fraction = expectedInterval <= 0 || lostInterval <= 0 ? 0 : UInt8(min(255, (lostInterval << 8) / expectedInterval))
            if mode == .frozen, frozenAt == nil { frozenAt = highest }
            if mode != .frozen { frozenAt = nil }
            return RTCPReportBlock(ssrc: ssrc, fractionLost: fraction, cumulativeLost: Int32(clamping: lost), extendedHighestSequence: frozenAt ?? highest)
        }
    }

    public nonisolated let host: String
    public nonisolated let isIPv6: Bool
    public nonisolated let videoPort: UInt16
    public nonisolated let audioPort: UInt16
    public nonisolated let videoKeys: ControllerTLV.SRTPKeys
    public nonisolated let audioKeys: ControllerTLV.SRTPKeys
    /// Every reassembled access unit (single consumer).
    public nonisolated let videoFrames: AsyncStream<ReceivedVideoFrame>
    /// Every audio packet with the selected payload type (single consumer).
    public nonisolated let audioFrames: AsyncStream<ReceivedAudioFrame>

    public private(set) var statistics = Statistics()
    public private(set) var peer: Peer?
    public private(set) var frameRecords: [FrameRecord] = []
    public let createdAt = ContinuousClock.now
    public private(set) var firstKeyframeAt: ContinuousClock.Instant?
    public private(set) var lastMediaAt: ContinuousClock.Instant?
    public private(set) var isStopped = false
    /// What the receiver reports carry (`ReportBlocks`); `.counting` by default, like a controller that receives the stream.
    public private(set) var reportBlocks = ReportBlocks.counting
    private var videoReception = ReceptionState()
    private var audioReception = ReceptionState()

    private let videoSocket: UDPSocket
    private let audioSocket: UDPSocket
    private let videoContinuation: AsyncStream<ReceivedVideoFrame>.Continuation
    private let audioContinuation: AsyncStream<ReceivedAudioFrame>.Continuation
    private var videoSRTP: SRTPContext
    private var audioSRTP: SRTPContext
    private var assembler = H264AccessUnitAssembler()
    private var tasks: [Task<Void, Never>] = []
    private var keepalive: Task<Void, Never>?
    private var returnSequence = UInt16.random(in: 0...UInt16.max)
    private var returnTimestamp = UInt32.random(in: 0...UInt32.max)
    private let log = Log(category: "SRTPTestReceiver")

    /// Binds the two sockets on `host` (ephemeral ports) with the controller's SRTP keys.
    public init(host: String = "127.0.0.1", ipv6: Bool = false, videoKeys: ControllerTLV.SRTPKeys = .random(),
                audioKeys: ControllerTLV.SRTPKeys = .random()) throws {
        self.host = host
        isIPv6 = ipv6
        self.videoKeys = videoKeys
        self.audioKeys = audioKeys
        videoSRTP = try SRTPContext(masterKey: videoKeys.masterKey, masterSalt: videoKeys.masterSalt)
        audioSRTP = try SRTPContext(masterKey: audioKeys.masterKey, masterSalt: audioKeys.masterSalt)
        let video = try UDPSocket.bind(host: host, port: 0, ipv6: ipv6)
        let audio: UDPSocket
        do {
            audio = try UDPSocket.bind(host: host, port: 0, ipv6: ipv6)
        } catch {
            video.close()
            throw error
        }
        videoSocket = video
        audioSocket = audio
        videoPort = video.localPort
        audioPort = audio.localPort
        (videoFrames, videoContinuation) = AsyncStream.makeStream(of: ReceivedVideoFrame.self, bufferingPolicy: .bufferingNewest(4096))
        (audioFrames, audioContinuation) = AsyncStream.makeStream(of: ReceivedAudioFrame.self, bufferingPolicy: .bufferingNewest(4096))
    }

    /// Released without `stop()`: end the tasks and streams (the sockets close when they are released).
    deinit {
        keepalive?.cancel()
        for task in tasks { task.cancel() }
        videoContinuation.finish()
        audioContinuation.finish()
    }

    /// Binds and starts receiving.
    public static func start(host: String = "127.0.0.1", ipv6: Bool = false, videoKeys: ControllerTLV.SRTPKeys = .random(),
                             audioKeys: ControllerTLV.SRTPKeys = .random()) async throws -> SRTPTestReceiver {
        let receiver = try SRTPTestReceiver(host: host, ipv6: ipv6, videoKeys: videoKeys, audioKeys: audioKeys)
        await receiver.startReceiving()
        return receiver
    }

    /// The controller address to put in SetupEndpoints.
    public nonisolated var address: ControllerTLV.Address {
        ControllerTLV.Address(isIPv6: isIPv6, ip: host, videoPort: videoPort, audioPort: audioPort)
    }

    public func startReceiving() {
        guard tasks.isEmpty, !isStopped else { return }
        let video = videoSocket.datagrams
        let audio = audioSocket.datagrams
        tasks.append(Task { [weak self] in
            for await datagram in video { await self?.receive(datagram.data, isVideo: true) }
        })
        tasks.append(Task { [weak self] in
            for await datagram in audio { await self?.receive(datagram.data, isVideo: false) }
        })
    }

    /// Sets the accessory's endpoint; with `keepaliveInterval` sends receiver reports on both streams right away and
    /// then periodically (the accessory ends the stream after 30 s without controller RTCP).
    public func connect(to peer: Peer, keepaliveInterval: Duration? = .milliseconds(500)) {
        self.peer = peer
        keepalive?.cancel()
        keepalive = nil
        guard let keepaliveInterval, !isStopped else { return }
        sendReceiverReports()
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: keepaliveInterval)
                guard !Task.isCancelled else { return }
                await self?.sendReceiverReports()
            }
        }
    }

    /// Stops the periodic receiver reports (to test the accessory's controller timeout).
    public func stopKeepalive() {
        keepalive?.cancel()
        keepalive = nil
    }

    /// Changes what the receiver reports carry from now on: `.none` and `.frozen` stand for a controller that stopped receiving
    /// (its RTCP still arrives, so the accessory's 30 s controller timeout never fires).
    public func setReportBlocks(_ mode: ReportBlocks) {
        reportBlocks = mode
    }

    /// One SRTCP receiver report on each stream.
    public func sendReceiverReports() {
        guard let peer, !isStopped else { return }
        sendRTCP([.receiverReport(ssrc: peer.controllerVideoSSRC, blocks: blocks(video: true))], isVideo: true)
        sendRTCP([.receiverReport(ssrc: peer.controllerAudioSSRC, blocks: blocks(video: false))], isVideo: false)
        statistics.receiverReportsSent += 1
    }

    private func blocks(video: Bool) -> [RTCPReportBlock] {
        guard reportBlocks != .none else { return [] }
        let mode = reportBlocks
        return (video ? videoReception.block(mode) : audioReception.block(mode)).map { [$0] } ?? []
    }

    /// RR + PLI on the video stream (asks for a keyframe).
    public func requestKeyframe() {
        guard let peer, !isStopped else { return }
        sendRTCP([.receiverReport(ssrc: peer.controllerVideoSSRC, blocks: blocks(video: true)),
                  .pictureLossIndication(senderSSRC: peer.controllerVideoSSRC, mediaSSRC: peer.videoSSRC ?? 0)], isVideo: true)
        statistics.keyframeRequestsSent += 1
    }

    /// Sends one return-audio packet (e.g. an Opus frame) to the accessory's audio port with our audio SSRC and the
    /// selected audio payload type; the RTP timestamp advances by `samples`.
    public func sendReturnAudio(_ payload: Data, samples: Int) throws {
        guard let peer else { throw SRTPTestReceiverError.notConnected }
        guard !isStopped else { throw SRTPTestReceiverError.stopped }
        let packet = RTPPacket(marker: statistics.returnAudioPacketsSent == 0, payloadType: peer.audioPayloadType ?? 110,
                               sequenceNumber: returnSequence, timestamp: returnTimestamp, ssrc: peer.controllerAudioSSRC, payload: payload)
        returnSequence &+= 1
        returnTimestamp &+= UInt32(truncatingIfNeeded: max(0, samples))
        let protected = try audioSRTP.protectRTP(packet.serialized())
        try audioSocket.send(protected, to: SocketAddress(host: peer.host, port: peer.audioPort))
        statistics.returnAudioPacketsSent += 1
    }

    /// Closes both sockets and finishes the streams.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        keepalive?.cancel()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        videoSocket.close()
        audioSocket.close()
        if let unit = assembler.flush() { deliver(unit) }
        videoContinuation.finish()
        audioContinuation.finish()
    }

    /// Waits until `condition` holds for the statistics, or `timeout` passes; returns whether it held.
    public func waitFor(timeout: Duration, _ condition: @Sendable (Statistics) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(statistics) {
            if ContinuousClock.now >= deadline || isStopped { return condition(statistics) }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Measured video frame rate over the complete access units received in `window` (default: all).
    public func measuredFrameRate(lastSeconds window: Double? = nil) -> Double? {
        var records = frameRecords.filter(\.isComplete)
        if let window, let last = records.last {
            records = records.filter { last.receivedAt - $0.receivedAt <= .seconds(window) }
        }
        guard records.count >= 2, let first = records.first, let last = records.last else { return nil }
        let ticks = Double(Int32(bitPattern: last.rtpTimestamp &- first.rtpTimestamp))
        guard ticks > 0 else { return nil }
        return Double(records.count - 1) / (ticks / 90_000)
    }

    // MARK: - Receiving

    private func receive(_ data: Data, isVideo: Bool) {
        guard !isStopped else { return }
        if RTPPacket.isRTCP(data) {
            receiveRTCP(data, isVideo: isVideo)
            return
        }
        let plain: Data
        do {
            plain = isVideo ? try videoSRTP.unprotectRTP(data) : try audioSRTP.unprotectRTP(data)
        } catch SRTPError.authenticationFailed {
            statistics.authenticationFailures += 1
            return
        } catch {
            statistics.malformedPackets += 1
            return
        }
        guard let packet = try? RTPPacket(parsing: plain) else {
            statistics.malformedPackets += 1
            return
        }
        lastMediaAt = .now
        if isVideo {
            statistics.largestVideoDatagram = max(statistics.largestVideoDatagram, data.count)
            if let expected = peer?.videoSSRC, packet.ssrc != expected {
                statistics.unexpectedSSRCPackets += 1
                return
            }
            statistics.videoPackets += 1
            videoReception.note(sequence: packet.sequenceNumber, ssrc: packet.ssrc)
            let gapsBefore = assembler.sequenceGaps
            let units = assembler.push(packet)
            statistics.sequenceGaps += assembler.sequenceGaps - gapsBefore
            for unit in units { deliver(unit) }
        } else {
            if let expected = peer?.audioSSRC, packet.ssrc != expected {
                statistics.unexpectedSSRCPackets += 1
                return
            }
            statistics.audioPackets += 1
            audioReception.note(sequence: packet.sequenceNumber, ssrc: packet.ssrc)
            if let payloadType = peer?.audioPayloadType, packet.payloadType != payloadType {
                statistics.otherAudioPackets += 1
                return
            }
            statistics.audioFrames += 1
            audioContinuation.yield(ReceivedAudioFrame(payload: packet.payload, rtpTimestamp: packet.timestamp, sequenceNumber: packet.sequenceNumber,
                                                       payloadType: packet.payloadType, ssrc: packet.ssrc, marker: packet.marker, receivedAt: .now))
        }
    }

    private func deliver(_ unit: ReceivedVideoFrame) {
        statistics.videoFrames += 1
        if !unit.isComplete { statistics.incompleteVideoFrames += 1 }
        if unit.isKeyframe {
            statistics.keyframes += 1
            if firstKeyframeAt == nil { firstKeyframeAt = unit.receivedAt }
        }
        if frameRecords.count < 100_000 {
            frameRecords.append(FrameRecord(rtpTimestamp: unit.rtpTimestamp, receivedAt: unit.receivedAt, isKeyframe: unit.isKeyframe,
                                            isComplete: unit.isComplete, byteCount: unit.nalUnits.reduce(0) { $0 + $1.count }))
        }
        videoContinuation.yield(unit)
    }

    private func receiveRTCP(_ data: Data, isVideo: Bool) {
        let plain: Data
        do {
            plain = isVideo ? try videoSRTP.unprotectRTCP(data) : try audioSRTP.unprotectRTCP(data)
        } catch SRTPError.authenticationFailed {
            statistics.authenticationFailures += 1
            return
        } catch {
            statistics.malformedPackets += 1
            return
        }
        guard let packets = try? RTCPPacket.parseCompound(plain) else {
            statistics.malformedPackets += 1
            return
        }
        for packet in packets {
            switch packet {
            case .senderReport:
                if isVideo { statistics.videoSenderReports += 1 } else { statistics.audioSenderReports += 1 }
            case .bye:
                statistics.byes += 1
            default:
                break
            }
        }
    }

    private func sendRTCP(_ packets: [RTCPPacket], isVideo: Bool) {
        guard let peer else { return }
        let plain = packets.reduce(into: Data()) { $0.append($1.serialized()) }
        do {
            let protected = isVideo ? try videoSRTP.protectRTCP(plain) : try audioSRTP.protectRTCP(plain)
            let socket = isVideo ? videoSocket : audioSocket
            try socket.send(protected, to: SocketAddress(host: peer.host, port: isVideo ? peer.videoPort : peer.audioPort))
        } catch {
            log.debug("RTCP send failed: \(error)")
        }
    }
}

public enum SRTPTestReceiverError: Error, Equatable, Sendable {
    case notConnected
    case stopped
}
