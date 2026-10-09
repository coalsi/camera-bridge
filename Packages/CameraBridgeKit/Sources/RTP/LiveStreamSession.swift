import BridgeSupport
import Foundation
import MediaCore

public struct LiveVideoParameters: Sendable {
    public var payloadType: UInt8
    public var ssrc: UInt32
    public var srtp: (key: Data, salt: Data)
    /// Upper bound for every SRTP packet on the wire (RTP header + payload + 10-byte tag).
    public var maxPacketSize: Int
    public var rtcpInterval: Duration

    public init(payloadType: UInt8, ssrc: UInt32, srtpKey: Data, srtpSalt: Data, maxPacketSize: Int = 1200, rtcpInterval: Duration = .milliseconds(500)) {
        self.payloadType = payloadType
        self.ssrc = ssrc
        self.srtp = (srtpKey, srtpSalt)
        self.maxPacketSize = maxPacketSize
        self.rtcpInterval = rtcpInterval
    }
}

public struct LiveAudioParameters: Sendable {
    /// .opus or .aacELD
    public var codec: AudioCodec
    public var payloadType: UInt8
    public var ssrc: UInt32
    public var srtp: (key: Data, salt: Data)
    public var rtpClockRate: Int
    public var packetTime: Duration
    public var rtcpInterval: Duration

    public init(codec: AudioCodec, payloadType: UInt8, ssrc: UInt32, srtpKey: Data, srtpSalt: Data, rtpClockRate: Int, packetTime: Duration,
                rtcpInterval: Duration = .milliseconds(500)) {
        self.codec = codec
        self.payloadType = payloadType
        self.ssrc = ssrc
        self.srtp = (srtpKey, srtpSalt)
        self.rtpClockRate = rtpClockRate
        self.packetTime = packetTime
        self.rtcpInterval = rtcpInterval
    }
}

public enum LiveStreamEndReason: Sendable, Equatable, CustomStringConvertible {
    case stopped, controllerTimeout, socketError(String), sourceEnded
    /// The media pipeline in front of the session gave up and ended it (`LiveStreamSession.end(reason:)`): the text is the
    /// pipeline's own plain-words reason (a transcoder that could not be built, a failed self-check, a picture of the wrong size).
    case pipelineFailed(String)
    /// No video packet could be sent in the first `LiveStreamTimings.noVideoAtStart`.
    case noVideoAtStart
    /// No video packet was sent for `LiveStreamTimings.sourceStalled` mid-session.
    case sourceStalled
    /// The controller's RTCP kept coming but its receiver reports showed it received none of our video for
    /// `LiveStreamTimings.endBlindAfter` (`ControllerReceptionMonitor`).
    case controllerNotReceiving

    /// The reason in plain words (log lines).
    public var description: String { LiveStreamSession.describe(self) }
}

/// When a live session reached each phase, on a monotonic clock (diagnostics: where a live view stalls). Phases that
/// did not happen are nil.
public struct LiveStreamTimeline: Sendable, Equatable {
    public var started: ContinuousClock.Instant?
    public var firstVideoPacket: ContinuousClock.Instant?
    public var firstKeyframe: ContinuousClock.Instant?
    public var firstAudioPacket: ContinuousClock.Instant?
    /// The controller's first authenticated packet (its RTCP, or return audio).
    public var firstControllerPacket: ContinuousClock.Instant?
    public var firstKeyframeRequest: ContinuousClock.Instant?
    public var ended: ContinuousClock.Instant?
    public var endReason: LiveStreamEndReason?
    public var videoPackets = 0
    public var audioPackets = 0
    public var keyframesSent = 0
    public var controllerRTCPPackets = 0
    public var rejectedInbound = 0
    /// Video packets that never went out (a failed send that was not retried away); each lost frame asked for a keyframe.
    public var videoPacketsLost = 0
    /// Times a video packet was sent again after ENOBUFS / EAGAIN / EINTR.
    public var videoSendRetries = 0
    /// Keyframes asked for because video packets were lost.
    public var lossKeyframeRequests = 0
    /// The last video packet sent.
    public var lastVideoPacket: ContinuousClock.Instant?
    /// The controller answers but its receiver reports show it receives none of our video (now).
    public var controllerNotReceiving = false
    /// How often that was found during the session.
    public var controllerNotReceivingEpisodes = 0
    /// The host the stream moved to when the controller's first authenticated packet came from other than the destination
    /// (symmetric RTP latching), nil when it never did.
    public var latchedDestination: String?

    public init() {}
}

/// One HomeKit live stream (research brief §3.6): SRTP H.264 video and optional Opus/AAC-ELD audio to the controller,
/// RTCP sender reports, and SRTCP/SRTP from the controller (keepalive, PLI/FIR, return audio). RTP and RTCP share
/// each socket (rtcp-mux); media goes to `controller.host` on `videoPort` / `audioPort`.
///
/// - Video: frames before the first keyframe are dropped; RTP timestamps are a random base + pts (90 kHz) relative to
///   the first keyframe. `maxPacketSize` bounds the SRTP packet, so the packetizer gets `maxPacketSize − 10`.
///   Only H.264 is sent (HEVC frames are dropped).
/// - Audio: one packet per frame; RTP timestamps are a random base + pts relative to the first frame, converted to
///   `rtpClockRate` (HomeKit wants the negotiated rate, not the encoder's). The audio source finishing only stops audio.
/// - RTCP: a sender report every `rtcpInterval` per stream once it has sent media; SR + BYE when the session ends.
///   A stream that never sent media sends no RTCP at all, not even BYE (RFC 3550 §6.1, §6.3.7).
/// - Controller: any packet that authenticates on either socket (RTCP or return-audio RTP) is a keepalive; after
///   `controllerTimeout` without one the session ends with `.controllerTimeout`. PLI/FIR yield on `keyframeRequests`
///   (coalesced to one pending request); return audio with the audio payload type is depacketized onto `returnAudio`
///   (newest 128 kept). Packets that fail authentication, replay checks or parsing are dropped, and so are packets
///   carrying one of the session's own SSRCs (RTP or the SRTCP sender SSRC; checked before authentication): they are
///   our own packets looped or reflected back (RFC 3550 §8.2), which would authenticate since one key per stream
///   serves both directions, and are neither keepalives nor return audio.
/// - Sending: a frame's packets go out in paced chunks (`LiveStreamTimings`: at most 24 packets per millisecond, never more
///   than 20 ms of pacing per frame; a replay is spread at twice the negotiated maximum bit rate), ENOBUFS / EAGAIN / EINTR
///   are retried briefly, and any lost video packet asks for a fresh keyframe on `keyframeRequests` (one WARNING per
///   incident, each distinct errno logged once). A fatal errno (address gone, network down, no route, permission) with no
///   send succeeding for 2 s ends the session with `.socketError`. Sender reports stop for a stream that sent no media for 5 s.
/// - Liveness (all end through the owner so Home sees the stream available and asks again): no video packet sent 10 s after
///   the start → `.noVideoAtStart`; none for 8 s mid-session → `.sourceStalled`; a controller whose receiver reports show
///   it receives none of our video for 3 s gets a WARNING, the sockets scoped to other interfaces one after the other
///   (`LiveStreamTransport.Values.recoveryScopes`) and a notice to the owner, and for 10 s ends the session with
///   `.controllerNotReceiving` (`ControllerReceptionMonitor`).
/// - Latching: the destination follows the source of the first authenticated controller packet once; a different source
///   is followed later only when the latched one was silent for `LiveStreamTimings.relatchAfter` (no flapping between a
///   controller's video and audio addresses).
/// - Ending (`stop()`, timeout, the video source finishing, a closed socket, or SRTP parameters that are not 16/14
///   bytes → `.socketError`) cancels all work, closes both sockets (the session owns them from `init`; closing never
///   blocks the actor, so a flood at the ports cannot delay it), finishes `returnAudio` and `keyframeRequests`.
///   `waitForEnd()` returns once the session ended and both socket descriptors are closed (their ports are free).
///   `start` runs at most once and is ignored after the session ended.
public actor LiveStreamSession {
    private enum Phase: Equatable {
        case idle, running, ended(LiveStreamEndReason)
    }

    /// Outbound media on one socket: SRTP state and RTCP sender statistics.
    private struct Outbound {
        var srtp: SRTPContext
        let ssrc: UInt32
        let clockRate: Int
        let socket: UDPSocket
        var destination: SocketAddress
        let timestampBase = UInt32.random(in: 0...UInt32.max)
        var firstPTS: MediaTime?
        var packetCount: UInt32 = 0
        var octetCount: UInt32 = 0
        var lastSent: (timestamp: UInt32, at: ContinuousClock.Instant)?
        /// Failed send attempts (a retried one counts).
        var failures = 0
        var tracker = SendFailureTracker()

        mutating func rtpTimestamp(for pts: MediaTime) -> UInt32 {
            let first = firstPTS ?? pts
            firstPTS = first
            let ticks = (pts - first).converted(to: Int32(clamping: clockRate)).value
            return timestampBase &+ UInt32(truncatingIfNeeded: ticks)
        }

        /// The SR for now, extrapolating the RTP timestamp from the last packet sent; nil before any media, and (with
        /// `maxAge`) once the stream has sent nothing for that long: extrapolating a dead stream's clock forever tells the
        /// controller the stream is alive.
        func senderReport(maxAge: Duration? = nil) -> RTCPPacket? {
            guard let lastSent else { return nil }
            if let maxAge, ContinuousClock.now - lastSent.at > maxAge { return nil }
            let elapsed = (ContinuousClock.now - lastSent.at) / .seconds(1)
            let ticks = Int64((elapsed * Double(clockRate)).rounded())
            return .senderReport(ssrc: ssrc, ntp: NTPTime.timestamp(for: Date()), rtpTimestamp: lastSent.timestamp &+ UInt32(truncatingIfNeeded: ticks),
                                 packetCount: packetCount, octetCount: octetCount)
        }
    }

    private let log = Log(category: "LiveStream")
    /// Where the media goes now: the initial destination, or the source the controller's packets came from
    /// (`latchDestination`).
    private var controllerHost: String
    /// What the controller advertised, when the initial destination is another address (diagnostics).
    private let advertisedController: String?
    private let videoSocket: UDPSocket
    private let audioSocket: UDPSocket?
    private var videoDestination: SocketAddress
    private var audioDestination: SocketAddress
    private let videoParameters: LiveVideoParameters
    private let audioParameters: LiveAudioParameters?
    private let controllerTimeout: Duration
    /// The SSRCs this session sends with; inbound packets carrying them are looped back, not the controller's.
    private let ownSSRCs: [UInt32]
    private let returnAudioStream: AsyncStream<EncodedAudioFrame>
    private let returnAudioContinuation: AsyncStream<EncodedAudioFrame>.Continuation
    private let keyframeRequestStream: AsyncStream<Void>
    private let keyframeRequestContinuation: AsyncStream<Void>.Continuation

    private var phase = Phase.idle
    private var tasks: [Task<Void, Never>] = []
    private var endWaiters: [CheckedContinuation<LiveStreamEndReason, Never>] = []
    private var lastHeardFromController = ContinuousClock.now
    /// A packet from the controller authenticated (RTCP or return audio).
    private var heardFromController = false
    /// Callers of `waitForController`, each released by its own timeout (or by the controller speaking, or the end).
    private var controllerWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextControllerWaiter: UInt64 = 0

    private var videoOut: Outbound?
    private var audioOut: Outbound?
    private var videoIn: SRTPContext?
    private var audioIn: SRTPContext?
    private var videoPacketizer: H264Packetizer?
    private var audioPacketizer: AudioPacketizer?
    private var returnAudioDepacketizer: AudioDepacketizer?
    private var sentFirstKeyframe = false
    private var droppedLeadingFrames = 0
    private var rejectedInbound = 0
    /// Inbound packets dropped for carrying one of our own SSRCs.
    private var loopedInbound = 0
    private var warnedAboutCodec = false
    private var timelineState = LiveStreamTimeline()
    private let trace: SessionTrace?
    private let timings: LiveStreamTimings
    /// Judges the controller's receiver reports; created at the start.
    private var monitor: ControllerReceptionMonitor?
    private var catchUp = CatchUpPacer(maxBitrateKbps: nil, factor: 2)
    /// When a video packet last went out, nil before the first.
    private var lastVideoSentAt: ContinuousClock.Instant?
    private var videoFramesReceived = 0
    private var lastLossAt: ContinuousClock.Instant?
    private var lastLossKeyframeRequestAt: ContinuousClock.Instant?
    /// The controller's receiver reports show it receives none of our video: since when, and how far the recovery got.
    private var blind: (since: ContinuousClock.Instant, flips: Int, lastFlipAt: ContinuousClock.Instant?)?
    /// The newest report block about our audio (diagnostics only: audio is tracked, not acted on).
    private var lastAudioBlock: RTCPReportBlock?
    /// Decides when the destination follows the controller's packets (`DestinationLatch`).
    private var latch = DestinationLatch()
    /// `onControllerReceiving` was told (it is, once).
    private var announcedReceiving = false

    public init(controller: SocketAddress /* host only; ports below */, videoPort: UInt16, audioPort: UInt16,
                videoSocket: UDPSocket, audioSocket: UDPSocket?, video: LiveVideoParameters, audio: LiveAudioParameters?,
                controllerTimeout: Duration = .seconds(30), trace: SessionTrace? = nil, advertisedController: String? = nil,
                timings: LiveStreamTimings = .standard) {
        self.trace = trace
        self.timings = videoSocket.transport.values.timings ?? timings
        self.advertisedController = advertisedController
        controllerHost = controller.host
        self.videoSocket = videoSocket
        self.audioSocket = audioSocket
        videoDestination = SocketAddress(host: controller.host, port: videoPort)
        audioDestination = SocketAddress(host: controller.host, port: audioPort)
        videoParameters = video
        audioParameters = audio
        self.controllerTimeout = controllerTimeout
        ownSSRCs = [video.ssrc] + (audio.map { [$0.ssrc] } ?? [])
        (returnAudioStream, returnAudioContinuation) = AsyncStream.makeStream(of: EncodedAudioFrame.self, bufferingPolicy: .bufferingNewest(128))
        (keyframeRequestStream, keyframeRequestContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start(video: AsyncStream<EncodedVideoFrame>, audio: AsyncStream<EncodedAudioFrame>?) {
        guard phase == .idle else {
            log.debug("start ignored: session already \(phase == .running ? "running" : "ended")")
            return
        }
        phase = .running
        do {
            videoOut = Outbound(srtp: try SRTPContext(masterKey: videoParameters.srtp.key, masterSalt: videoParameters.srtp.salt), ssrc: videoParameters.ssrc,
                                clockRate: 90_000, socket: videoSocket, destination: videoDestination)
            videoIn = try SRTPContext(masterKey: videoParameters.srtp.key, masterSalt: videoParameters.srtp.salt)
            if let audioParameters, let audioSocket {
                audioOut = Outbound(srtp: try SRTPContext(masterKey: audioParameters.srtp.key, masterSalt: audioParameters.srtp.salt),
                                    ssrc: audioParameters.ssrc, clockRate: audioParameters.rtpClockRate, socket: audioSocket, destination: audioDestination)
                audioIn = try SRTPContext(masterKey: audioParameters.srtp.key, masterSalt: audioParameters.srtp.salt)
            }
        } catch {
            log.error("live stream to \(controllerHost) not started: invalid SRTP parameters")
            end(.socketError("invalid SRTP parameters (key must be 16 bytes, salt 14)"))
            return
        }
        videoPacketizer = H264Packetizer(payloadType: videoParameters.payloadType, ssrc: videoParameters.ssrc,
                                         maxPacketSize: videoParameters.maxPacketSize - SRTPSessionKeys.tagLength)
        if let audioParameters, audioOut != nil {
            audioPacketizer = AudioPacketizer(codec: audioParameters.codec, payloadType: audioParameters.payloadType, ssrc: audioParameters.ssrc)
            returnAudioDepacketizer = AudioDepacketizer(codec: audioParameters.codec, payloadType: audioParameters.payloadType,
                                                        clockRate: audioParameters.rtpClockRate, packetTime: audioParameters.packetTime)
        }
        lastHeardFromController = .now
        timelineState.started = .now
        let setup = videoSocket.transport.values
        monitor = ControllerReceptionMonitor(videoSSRC: videoParameters.ssrc, timings: timings, startedAt: .now)
        catchUp = CatchUpPacer(maxBitrateKbps: setup.maxBitrateKbps, factor: timings.catchUpBitrateFactor)

        tasks.append(Task {
            for await frame in video { await self.send(video: frame) }
            self.end(.sourceEnded)
        })
        if let audio, audioOut != nil {
            tasks.append(Task {
                for await frame in audio { await self.send(audio: frame) }
                self.log.debug("audio source finished")
            })
        }
        tasks.append(receiveTask(videoSocket, isVideo: true))
        if let audioSocket { tasks.append(receiveTask(audioSocket, isVideo: false)) }
        tasks.append(reportTask(isVideo: true, interval: videoParameters.rtcpInterval))
        if let audioParameters, audioOut != nil { tasks.append(reportTask(isVideo: false, interval: audioParameters.rtcpInterval)) }
        tasks.append(Task { await self.watchdog() })
        log.info("live stream started to \(controllerHost) (video port \(videoDestination.port), audio port \(audioOut == nil ? "none" : String(audioDestination.port)))"
                 + (advertisedController.map { ", the controller advertised \($0)" } ?? "")
                 + ", sending from \(setup.boundSource ?? "any address")" + (videoSocket.scopedInterface.map { " through \($0)" } ?? ""))
    }

    /// The controller timeout, the liveness limits, fatal send errors and the blind-controller check, on one timer: wakes at
    /// the controller timeout's deadline or `watchdogTick`, whichever is first.
    private func watchdog() async {
        while !Task.isCancelled {
            let now = ContinuousClock.now
            let deadline = lastHeardFromController + controllerTimeout
            if now >= deadline {
                end(.controllerTimeout)
                return
            }
            if checkTransport(now) { return }
            try? await Task.sleep(until: min(deadline, now + timings.watchdogTick), clock: .continuous)
        }
    }

    /// Ends the session when its transport is dead; returns whether it did.
    private func checkTransport(_ now: ContinuousClock.Instant) -> Bool {
        guard phase == .running, let started = timelineState.started else { return false }
        let wording = "so the controller sees the stream available and asks again"
        if let last = lastVideoSentAt {
            if now - last >= timings.sourceStalled {
                log.warning("live stream to \(videoDestination): no video packet was sent for \(Self.seconds(now - last)); the source delivered "
                            + "\(videoFramesReceived) frame(s) in total (\(timelineState.videoPacketsLost) packets lost to send errors); ending the stream, \(wording)")
                end(.sourceStalled)
                return true
            }
        } else if now - started >= timings.noVideoAtStart {
            log.warning("live stream to \(videoDestination): no video packet was sent in the first \(Self.seconds(now - started)); the source delivered "
                        + "\(videoFramesReceived) frame(s), \(droppedLeadingFrames) of them before a keyframe; ending the stream, \(wording)")
            end(.noVideoAtStart)
            return true
        }
        for isVideo in [true, false] {
            guard let out = isVideo ? videoOut : audioOut,
                  let code = out.tracker.persistentFatal(at: now, after: timings.fatalSendErrorAfter) else { continue }
            let text = SendFailure.describe(code)
            log.warning("live stream to \(isVideo ? videoDestination : audioDestination): \(isVideo ? "video" : "audio") packets cannot be sent: \(text), for "
                        + "\(Self.seconds(timings.fatalSendErrorAfter)) with no send succeeding; ending the stream, \(wording)")
            videoSocket.transport.values.onFatalSendError?(code, text, SendFailure.suggestsLocalNetworkDenied(code))
            end(.socketError("sendto failed: \(text)"))
            return true
        }
        return checkReception(now)
    }

    /// The blind-controller judgement (`ControllerReceptionMonitor`) and what follows from it: a WARNING and a notice once,
    /// the sockets scoped to other interfaces one after the other, the end after `endBlindAfter`.
    private func checkReception(_ now: ContinuousClock.Instant) -> Bool {
        guard let verdict = monitor?.verdict(at: now) else {
            if blind != nil {
                log.info("live stream to \(controllerHost): the controller is receiving our video again"
                         + (videoSocket.scopedInterface.map { " (sockets scoped to \($0))" } ?? ""))
                blind = nil
                timelineState.controllerNotReceiving = false
            }
            return false
        }
        if blind == nil {
            blind = (verdict.since, 0, nil)
            timelineState.controllerNotReceiving = true
            timelineState.controllerNotReceivingEpisodes += 1
            log.warning(blindMessage(verdict, now: now))
            trace?.mark("controller not receiving", verdict.symptom.rawValue)
            keyframeRequestContinuation.yield(())
            videoSocket.transport.values.onControllerNotReceiving?(verdict.symptom.rawValue)
        }
        if let state = blind {
            let scopes = videoSocket.transport.values.recoveryScopes
            if state.flips < scopes.count, state.lastFlipAt.map({ now - $0 >= timings.interfaceFlipInterval }) ?? true {
                flip(to: scopes[state.flips])
                blind = (state.since, state.flips + 1, now)
            }
        }
        if now - verdict.since >= timings.endBlindAfter {
            log.warning("live stream to \(videoDestination): the controller still receives none of our video after \(Self.seconds(now - verdict.since)) "
                        + "(\(verdict.symptom.rawValue)); ending the stream so the controller sees it available and asks again")
            end(.controllerNotReceiving)
            return true
        }
        return false
    }

    /// Scopes both sockets to `interface` (nil: unscoped) as a last attempt to get video through, and asks for a keyframe.
    private func flip(to interface: String?) {
        let was = videoSocket.scopedInterface
        do {
            try videoSocket.scope(toInterface: interface)
            try audioSocket?.scope(toInterface: interface)
            log.info("live stream to \(videoDestination): the controller still receives none of our video; sending through "
                     + (interface.map { "interface \($0)" } ?? "the routing table's choice") + " now (was " + (was.map { "interface \($0)" } ?? "the routing table's choice") + ")")
            keyframeRequestContinuation.yield(())
        } catch {
            log.warning("live stream to \(controllerHost): could not send through " + (interface.map { "interface \($0)" } ?? "the routing table's choice") + ": \(error)")
        }
    }

    private func blindMessage(_ verdict: ControllerReceptionMonitor.Verdict, now: ContinuousClock.Instant) -> String {
        let setup = videoSocket.transport.values
        var text = "live stream to \(videoDestination): the controller answers but is not receiving our video: \(verdict.symptom.rawValue) "
            + "for \(Self.seconds(now - verdict.since)) (\(verdict.reports) reports, \(verdict.packetsSentSince) video packets sent meanwhile). "
            + "Sending from \(setup.boundSource ?? "any address") (\(setup.strategy)) to \(videoDestination)"
        if let route = setup.route { text += ", route: \(route)" }
        if let advertisedController { text += ", advertised \(advertisedController)" }
        let sent = videoOut
        text += "; \(sent?.packetCount ?? 0) packets, \(sent?.octetCount ?? 0) octets sent, \(sent?.failures ?? 0) failed send attempts, \(timelineState.videoPacketsLost) packets lost"
        if let block = monitor?.lastBlock {
            text += "; last report block: lost \(block.fractionLost)/256 (\(block.cumulativeLost) in all), highest sequence \(block.extendedHighestSequence), jitter \(block.jitter)"
        } else {
            text += "; no report block about our video was ever received"
        }
        if !setup.recoveryScopes.isEmpty {
            text += "; trying other interfaces next"
        }
        return text
    }

    static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f s", duration / .seconds(1))
    }

    public func stop() {
        end(.stopped)
    }

    /// Ends the session with `reason` (the pipeline in front of it gave up: `.pipelineFailed`), so the log, the timeline and
    /// `waitForEnd()` say why. Does nothing once the session ended.
    public func end(reason: LiveStreamEndReason) {
        end(reason)
    }

    /// Decrypted, depacketized audio from the controller.
    public nonisolated var returnAudio: AsyncStream<EncodedAudioFrame> { returnAudioStream }

    /// PLI/FIR from the controller.
    public nonisolated var keyframeRequests: AsyncStream<Void> { keyframeRequestStream }

    /// Waits until the controller's first packet authenticated (its RTCP: it listens), at most `timeout`, or until the
    /// session ended. Returns whether the controller was heard (integration brief §5.4: video waits for it up to 1 s).
    public func waitForController(timeout: Duration) async -> Bool {
        if heardFromController { return true }
        if isEnded || timeout <= .zero { return false }
        let id = nextControllerWaiter
        nextControllerWaiter &+= 1
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.releaseControllerWaiter(id)
        }
        await withCheckedContinuation { controllerWaiters[id] = $0 }
        timer.cancel()
        return heardFromController
    }

    /// Only the waiter whose timeout it is: another caller's longer wait goes on.
    private func releaseControllerWaiter(_ id: UInt64) {
        controllerWaiters.removeValue(forKey: id)?.resume()
    }

    private func releaseControllerWaiters() {
        let waiters = controllerWaiters
        controllerWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
    }

    /// Symmetric RTP: the controller's first authenticated packet came from `source`. When that host is not the one we
    /// send to (the controller advertised an address it cannot be reached at, e.g. a VPN's, or it sits behind a NAT or on
    /// another of its interfaces), the media follows it; the ports stay the advertised ones. Only authenticated packets
    /// get here, so nobody else can steer the stream.
    ///
    /// It latches once: the first authenticated packet decides. A later packet from another source (a controller whose video
    /// and audio, or two of its interfaces, come from different addresses) moves the stream only when the latched source has
    /// been silent for `relatchAfter`; otherwise the stream would flap between the two with every packet.
    private func latchDestination(to source: SocketAddress) {
        switch latch.observe(source: source.host, destination: controllerHost, now: .now, relatchAfter: timings.relatchAfter) {
        case .unchanged:
            return
        case .ignored(let first):
            if first { log.info("live stream: also hearing from \(source.host); staying with \(controllerHost), which is still answering") }
            return
        case .moved(let silentFor):
            if let silentFor { log.info("live stream: \(controllerHost) was silent for \(Self.seconds(silentFor)) while \(source.host) kept answering") }
        }
        log.info("live stream: the controller's packets come from \(source.host), not \(controllerHost)"
                 + (advertisedController.map { " (advertised \($0))" } ?? "") + "; sending to \(source.host) from now on")
        trace?.mark("destination latched", "controller packets from \(source.host), was \(controllerHost)")
        timelineState.latchedDestination = source.host
        controllerHost = source.host
        videoDestination = SocketAddress(host: source.host, port: videoDestination.port)
        audioDestination = SocketAddress(host: source.host, port: audioDestination.port)
        videoOut?.destination = videoDestination
        audioOut?.destination = audioDestination
    }

    private func controllerSpoke() {
        lastHeardFromController = .now
        guard !heardFromController else { return }
        heardFromController = true
        timelineState.firstControllerPacket = .now
        trace?.mark("first RTCP received", timelineState.firstVideoPacket == nil ? "before any video" : nil)
        let video = timelineState.firstVideoPacket == nil ? "before any video was sent"
            : "\(elapsedText(since: timelineState.firstVideoPacket)) after the first video packet"
        log.info("live stream trace: first controller packet received \(elapsedText(since: timelineState.started)) after start, \(video)")
        releaseControllerWaiters()
    }

    public func waitForEnd() async -> LiveStreamEndReason {
        let reason: LiveStreamEndReason
        if case .ended(let ended) = phase {
            reason = ended
        } else {
            reason = await withCheckedContinuation { endWaiters.append($0) }
        }
        await videoSocket.waitUntilClosed()
        await audioSocket?.waitUntilClosed()
        return reason
    }

    // MARK: Outbound media

    private func send(video frame: EncodedVideoFrame) async {
        guard phase == .running, videoOut != nil, var packetizer = videoPacketizer else { return }
        videoFramesReceived += 1
        guard frame.format.codec == .h264 else {
            if !warnedAboutCodec { log.warning("dropping \(frame.format.codec.rawValue) frames: live video is H.264 only") }
            warnedAboutCodec = true
            return
        }
        if !sentFirstKeyframe {
            guard frame.isKeyframe else {
                droppedLeadingFrames += 1
                return
            }
            sentFirstKeyframe = true
            if droppedLeadingFrames > 0 { log.debug("dropped \(droppedLeadingFrames) frames before the first keyframe") }
        }
        // A replay (media time ahead of the wall clock) is spread at twice the negotiated bit rate; live frames never wait.
        let bytes = frame.nalUnits.reduce(0) { $0 + $1.count }
        let wait = catchUp.delay(bytes: bytes, pts: frame.pts.seconds, now: .now)
        if wait > .zero {
            try? await Task.sleep(for: wait)
            guard phase == .running else { return }
        }
        guard let timestamp = withOutbound(video: true, { $0.rtpTimestamp(for: frame.pts) }) else { return }
        let packets = packetizer.packetize(frame, rtpTimestamp: timestamp)
        videoPacketizer = packetizer
        guard let result = await transmit(packets, timestamp: timestamp, isVideo: true), phase == .running else { return }
        let now = ContinuousClock.now
        let sent = Int(videoOut?.packetCount ?? 0)
        timelineState.videoPacketsLost += result.outcome.lost
        timelineState.videoSendRetries += result.outcome.retries
        if result.outcome.lost > 0 { noteVideoLoss(result, packets: packets.count, keyframe: frame.isKeyframe, now: now) }
        guard result.outcome.sent > 0 else { return }
        lastVideoSentAt = now
        timelineState.lastVideoPacket = now
        monitor?.videoSent(total: sent, at: now)
        timelineState.videoPackets = sent
        if timelineState.firstVideoPacket == nil {
            timelineState.firstVideoPacket = .now
            trace?.mark("first video packet", "\(packets.count) packets, keyframe \(frame.isKeyframe)")
            let heard = timelineState.firstControllerPacket == nil ? "controller not heard yet" : "controller heard"
            log.info("live stream trace: first video packet sent \(elapsedText(since: timelineState.started)) after start "
                     + "(\(packets.count) packets, keyframe \(frame.isKeyframe), \(heard))")
        }
        if frame.isKeyframe {
            timelineState.keyframesSent += 1
            if timelineState.firstKeyframe == nil {
                timelineState.firstKeyframe = .now
                trace?.mark("keyframe sent", "\(bytes) bytes")
                log.info("live stream trace: first keyframe sent \(elapsedText(since: timelineState.started)) after start "
                         + "(\(bytes) bytes, \(packets.count) packets)")
            } else {
                log.debug("live stream trace: keyframe #\(timelineState.keyframesSent) sent")
            }
        }
    }

    private func send(audio frame: EncodedAudioFrame) async {
        guard phase == .running, audioOut != nil, var packetizer = audioPacketizer else { return }
        guard let timestamp = withOutbound(video: false, { $0.rtpTimestamp(for: frame.pts) }) else { return }
        let packet = packetizer.packetize(frame, rtpTimestamp: timestamp)
        audioPacketizer = packetizer
        guard await transmit([packet], timestamp: timestamp, isVideo: false) != nil else { return }
        let sent = Int(audioOut?.packetCount ?? 0)
        timelineState.audioPackets = sent
        if timelineState.firstAudioPacket == nil, sent > 0 {
            timelineState.firstAudioPacket = .now
            trace?.mark("first audio packet")
            log.debug("live stream trace: first audio packet sent \(elapsedText(since: timelineState.started)) after start")
        }
    }

    /// `body` on the stream's outbound state, in place (no copy is held across a suspension: SRTP and RTCP state are shared
    /// by the media task and the report task); nil when the stream does not exist.
    private func withOutbound<T>(video isVideo: Bool, _ body: (inout Outbound) throws -> T) rethrows -> T? {
        if isVideo {
            guard videoOut != nil else { return nil }
            return try body(&videoOut!)
        }
        guard audioOut != nil else { return nil }
        return try body(&audioOut!)
    }

    /// Protects `packets` in sequence, then sends them in paced chunks (`PacedTransmission`), retrying transient errors. The
    /// counters and the send-failure tracker are updated at the end; each distinct errno is logged once.
    private func transmit(_ packets: [RTPPacket], timestamp: UInt32, isVideo: Bool) async -> (outcome: PacedTransmission.Outcome, fresh: [Int32])? {
        guard !packets.isEmpty, let socket = isVideo ? videoOut?.socket : audioOut?.socket,
              let destination = isVideo ? videoOut?.destination : audioOut?.destination else { return nil }
        let kind = isVideo ? "video" : "audio"
        var datagrams: [Data] = []
        var payloadSizes: [Int] = []
        var unprotected = 0
        for packet in packets {
            do {
                if let datagram = try withOutbound(video: isVideo, { try $0.srtp.protectRTP(packet.serialized()) }) {
                    datagrams.append(datagram)
                    payloadSizes.append(packet.payload.count)
                }
            } catch {
                unprotected += 1
            }
        }
        var sentPackets = 0
        var sentOctets = 0
        var outcome = await PacedTransmission.run(count: datagrams.count, timings: timings, send: { index in
            try socket.send(datagrams[index], to: destination)
            sentPackets += 1
            sentOctets += payloadSizes[index]
        }, pause: { try? await Task.sleep(for: $0) })
        outcome.lost += unprotected
        let now = ContinuousClock.now
        let fresh: [Int32] = withOutbound(video: isVideo) { (out: inout Outbound) -> [Int32] in
            out.packetCount &+= UInt32(truncatingIfNeeded: sentPackets)
            out.octetCount &+= UInt32(truncatingIfNeeded: sentOctets)
            if sentPackets > 0 { out.lastSent = (timestamp, now) }
            out.failures += outcome.failures.values.reduce(0, +)
            return out.tracker.record(successes: sentPackets, failures: outcome.failures, at: now)
        } ?? []
        if outcome.closed {
            end(.socketError("\(kind) socket closed"))
            return nil
        }
        // A video loss has its own incident line (`noteVideoLoss`); an errno first seen otherwise is logged once.
        if !fresh.isEmpty, !(isVideo && outcome.lost > 0) {
            log.warning("\(kind) packets to \(destination): send failed: \(SendFailure.describe(fresh))")
        }
        return (outcome, fresh)
    }

    /// Video packets did not go out: one WARNING per incident (losses within `lossIncidentGap` of each other are one), and a
    /// fresh keyframe is asked for (the pipeline's encoder or the camera makes one) at most once per
    /// `lossKeyframeRequestInterval`, since a frame with a hole is undecodable until the next keyframe.
    private func noteVideoLoss(_ result: (outcome: PacedTransmission.Outcome, fresh: [Int32]), packets: Int, keyframe: Bool, now: ContinuousClock.Instant) {
        let newIncident = lastLossAt.map { now - $0 > timings.lossIncidentGap } ?? true
        lastLossAt = now
        let errors = result.outcome.failures.sorted { $0.key < $1.key }.map { "\(SendFailure.describe($0.key)) x\($0.value)" }.joined(separator: ", ")
        if newIncident {
            log.warning("live stream to \(videoDestination): \(result.outcome.lost) of \(packets) packets of a \(keyframe ? "keyframe" : "video frame") could not be sent "
                        + "(\(errors); \(result.outcome.retries) retries); asking for a fresh keyframe so the picture recovers")
        } else if !result.fresh.isEmpty {
            log.warning("live stream to \(videoDestination): video packets also fail with \(SendFailure.describe(result.fresh))")
        }
        if lastLossKeyframeRequestAt.map({ now - $0 >= timings.lossKeyframeRequestInterval }) ?? true {
            lastLossKeyframeRequestAt = now
            timelineState.lossKeyframeRequests += 1
            keyframeRequestContinuation.yield(())
        }
    }

    // MARK: RTCP

    private func reportTask(isVideo: Bool, interval: Duration) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self.sendReport(isVideo: isVideo, bye: false)
            }
        }
    }

    /// SR and optionally BYE, as one SRTCP compound packet; nothing before the stream's first media packet (a compound
    /// must start with a report, RFC 3550 §6.1, and a participant that never sent RTP or RTCP must not send BYE, §6.3.7).
    private func sendReport(isVideo: Bool, bye: Bool) {
        guard var out = isVideo ? videoOut : audioOut, let report = out.senderReport(maxAge: bye ? nil : timings.senderReportStaleAfter) else { return }
        let compound = bye ? [report, .bye(ssrcs: [out.ssrc])] : [report]
        let plain = compound.reduce(into: Data()) { $0.append($1.serialized()) }
        var fresh: [Int32] = []
        do {
            try out.socket.send(try out.srtp.protectRTCP(plain), to: out.destination)
            fresh = out.tracker.record(successes: 1, failures: [:], at: .now)
        } catch UDPSocketError.closed {
            return   // the session is ending
        } catch {
            out.failures += 1
            fresh = out.tracker.record(successes: 0, failures: [SendFailure.code(of: error) ?? -1: 1], at: .now)
            if !bye, !fresh.isEmpty { log.warning("\(isVideo ? "video" : "audio") RTCP to \(out.destination): send failed: \(error)") }
        }
        if isVideo { videoOut = out } else { audioOut = out }
    }

    // MARK: Inbound

    private func receiveTask(_ socket: UDPSocket, isVideo: Bool) -> Task<Void, Never> {
        Task {
            for await datagram in socket.datagrams { self.receive(datagram.data, isVideo: isVideo, from: datagram.from) }
            self.end(.socketError("\(isVideo ? "video" : "audio") socket closed"))
        }
    }

    private func receive(_ data: Data, isVideo: Bool, from source: SocketAddress? = nil) {
        guard phase == .running else { return }
        let isRTCP = RTPPacket.isRTCP(data)
        // Our own SSRC coming back is a loop (RFC 3550 §8.2), never the controller: one key serves both directions, so a
        // peer without keys that bounces our packets would otherwise pass authentication. Checked before the HMAC.
        if let ssrc = Self.senderSSRC(data, isRTCP: isRTCP), ownSSRCs.contains(ssrc) {
            loopedInbound += 1
            if loopedInbound == 1 || loopedInbound % 500 == 0 {
                log.warning("dropped inbound packet carrying our own SSRC (\(loopedInbound) so far): looped or reflected back to us")
            }
            return
        }
        if isRTCP {
            let plain: Data
            do {
                guard let unprotected = try isVideo ? videoIn?.unprotectRTCP(data) : audioIn?.unprotectRTCP(data) else { return }
                plain = unprotected
            } catch {
                return reject(error)
            }
            if let source { latchDestination(to: source) }
            controllerSpoke()
            timelineState.controllerRTCPPackets += 1
            guard let packets = try? RTCPPacket.parseCompound(plain) else { return reject(RTPError.truncated) }
            for packet in packets {
                switch packet {
                case .pictureLossIndication, .fullIntraRequest:
                    if timelineState.firstKeyframeRequest == nil {
                        timelineState.firstKeyframeRequest = .now
                        trace?.mark("keyframe requested by the controller (PLI/FIR)")
                    }
                    log.debug("live stream trace: controller asked for a keyframe (PLI/FIR)")
                    keyframeRequestContinuation.yield(())
                case .bye:
                    log.debug("controller sent RTCP BYE")
                case .receiverReport(_, let blocks), .senderReport(_, _, _, _, _, let blocks):
                    noteReportBlocks(blocks, onVideoSocket: isVideo)
                default:
                    break
                }
            }
        } else {
            guard !isVideo, audioIn != nil, var depacketizer = returnAudioDepacketizer else { return }
            let packet: RTPPacket
            do {
                guard let plain = try audioIn?.unprotectRTP(data) else { return }
                packet = try RTPPacket(parsing: plain)
            } catch {
                return reject(error)
            }
            if let source { latchDestination(to: source) }
            controllerSpoke()
            for frame in depacketizer.depacketize(packet) { returnAudioContinuation.yield(frame) }
            returnAudioDepacketizer = depacketizer
        }
    }

    /// What the controller reports having received of our streams. Reports on the video socket count for the blind-controller
    /// judgement (one lacking a block about our video is evidence); on the audio socket only one that mentions our video does.
    /// Audio is tracked for the end-of-session line, not acted on.
    private func noteReportBlocks(_ blocks: [RTCPReportBlock], onVideoSocket: Bool) {
        if let audioSSRC = audioParameters?.ssrc, let block = blocks.first(where: { $0.ssrc == audioSSRC }) { lastAudioBlock = block }
        if onVideoSocket || blocks.contains(where: { $0.ssrc == videoParameters.ssrc }) {
            monitor?.report(blocks: blocks, at: .now)
        }
        if !announcedReceiving, let block = blocks.first(where: { $0.ssrc == videoParameters.ssrc }), block.fractionLost < timings.heavyLossFraction {
            announcedReceiving = true
            videoSocket.transport.values.onControllerReceiving?()
        }
    }

    /// The sender SSRC, which SRTP and SRTCP leave in the clear: RTP header bytes 8..<12, or the first RTCP packet's
    /// bytes 4..<8. nil when the datagram is too short to hold it.
    static func senderSSRC(_ data: Data, isRTCP: Bool) -> UInt32? {
        let offset = isRTCP ? 4 : 8
        guard data.count >= offset + 4 else { return nil }
        let start = data.startIndex + offset
        return data[start..<start + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func reject(_ error: any Error) {
        rejectedInbound += 1
        timelineState.rejectedInbound = rejectedInbound
        if rejectedInbound == 1 || rejectedInbound % 500 == 0 { log.debug("dropped inbound packet (\(rejectedInbound) so far): \(error)") }
    }

    // MARK: Ending

    private func end(_ reason: LiveStreamEndReason) {
        guard !isEnded else { return }
        let wasRunning = phase == .running
        phase = .ended(reason)
        timelineState.ended = .now
        timelineState.endReason = reason
        trace?.finish(Self.describe(reason))
        if wasRunning {
            sendReport(isVideo: true, bye: true)
            if audioOut != nil { sendReport(isVideo: false, bye: true) }
        }
        for task in tasks { task.cancel() }
        tasks.removeAll()
        // Never block the actor on the sockets' queues; waitForEnd() awaits the descriptors.
        videoSocket.closeWithoutWaiting()
        audioSocket?.closeWithoutWaiting()
        returnAudioContinuation.finish()
        keyframeRequestContinuation.finish()
        releaseControllerWaiters()
        let waiters = endWaiters
        endWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: reason) }
        if wasRunning {
            let t = timelineState
            func offset(_ instant: ContinuousClock.Instant?) -> String {
                guard let instant, let started = t.started else { return "never" }
                return Self.ms(instant - started)
            }
            log.info("live stream to \(controllerHost) ended (\(reason)) after \(offset(t.ended)): video \(videoOut?.packetCount ?? 0) packets "
                     + "(\(t.keyframesSent) keyframes), audio \(audioOut?.packetCount ?? 0) packets, controller RTCP packets \(t.controllerRTCPPackets), "
                     + "rejected inbound \(rejectedInbound), first video \(offset(t.firstVideoPacket)), "
                     + "first controller packet \(offset(t.firstControllerPacket))"
                     + (t.videoPacketsLost > 0 ? ", video packets lost \(t.videoPacketsLost) (\(t.videoSendRetries) retries)" : "")
                     + (t.controllerNotReceivingEpisodes > 0 ? ", controller not receiving video \(t.controllerNotReceivingEpisodes)x" : "")
                     + (monitor?.lastBlock.map { ", last video report: lost \($0.fractionLost)/256, highest sequence \($0.extendedHighestSequence)" } ?? "")
                     + (lastAudioBlock.map { ", last audio report: lost \($0.fractionLost)/256" } ?? ""))
        }
    }

    /// Phase times so far (see `LiveStreamTimeline`).
    public var timeline: LiveStreamTimeline { timelineState }

    private func elapsedText(since instant: ContinuousClock.Instant?) -> String {
        guard let instant else { return "n/a" }
        return Self.ms(.now - instant)
    }

    /// An end reason in words, for the session history.
    static func describe(_ reason: LiveStreamEndReason) -> String {
        switch reason {
        case .stopped: "stopped"
        case .controllerTimeout: "controllerTimeout: no RTCP from the controller"
        case .socketError(let text): "socketError: \(text)"
        case .sourceEnded: "sourceEnded: the video source finished"
        case .noVideoAtStart: "noVideoAtStart: no video packet could be sent after the start"
        case .sourceStalled: "sourceStalled: no video packet was sent for a long time"
        case .controllerNotReceiving: "controllerNotReceiving: the controller answers but receives none of our video"
        case .pipelineFailed(let text): "pipelineFailed: \(text)"
        }
    }

    static func ms(_ duration: Duration) -> String {
        "\(Int((duration / .milliseconds(1)).rounded())) ms"
    }

    private var isEnded: Bool {
        if case .ended = phase { return true }
        return false
    }

    /// The session has ended (stopped, timed out or failed).
    public var hasEnded: Bool { isEnded }
}
