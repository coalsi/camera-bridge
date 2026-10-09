import BridgeSupport
import Foundation
import MediaCore
import RTP

/// RTSP 1.0 client over TCP with interleaved RTP (RFC 2326 §10.12) through the injected `NetworkTransport`.
///
/// `connect()`: OPTIONS → DESCRIBE (401 → Digest via `DigestAuthenticator`, Basic fallback, but never Basic once the
/// camera asked for Digest — in the session, or in an earlier session of the same `RTSPMediaSource`; a 401 to
/// credentials is not retried unless its Digest nonce is stale, so wrong credentials cost one authenticated attempt; with
/// `requestBackchannel`, `Require: www.onvif.org/ver20/backchannel`, retried without it on 551) → SETUP of the video
/// track, the first usable audio track and the backchannel, each `RTP/AVP/TCP;unicast;interleaved=2n-(2n+1)`. A
/// refused SETUP of the audio track or backchannel skips that track (the session goes on without it); a SETUP answer
/// with a non-TCP transport is `RTSPError.protocolError`. When `connect()` or `play()` fails after the camera created a
/// session, TEARDOWN is sent (best effort) before the connection closes.
/// `play()`: PLAY, then keepalive (`GET_PARAMETER`, or `OPTIONS` when the camera does not list/support it) every
/// session timeout / 2, and a watchdog that fails the stream with `RTSPError.timeout` when no video RTP packet arrives
/// for `configuration.timeout` (audio and RTCP do not count) or no video frame can be delivered for `videoFrameTimeout`
/// (default max(3 × `configuration.timeout`, 30 s): video that never reaches a keyframe). The sample stream buffers
/// at most `SampleDelivery.bufferLimit` samples for a slow consumer, finishes normally on `close()` and throws on
/// disconnect or stall; dropping or cancelling it closes the session. `close()` sends TEARDOWN. A client is
/// single-use: create a new one to reconnect (`RTSPMediaSource` does); a second `play()` is rejected.
///
/// Credentials never appear in request lines or logs; user info in `configuration.url` is stripped (and used as
/// credentials when `configuration.credentials` is nil).
public actor RTSPClient {
    static let backchannelRequire = "www.onvif.org/ver20/backchannel"

    /// `starting`: PLAY sent, answer pending (a concurrent `play()` is rejected).
    private enum Phase { case idle, connecting, connected, starting, playing, closed }

    private enum Authorization {
        case none
        case basic
        case digest(DigestChallenge, DigestAuthenticator)
    }

    private struct SetupTrack {
        var track: RTSPTrack
        var rtpChannel: UInt8
        var rtcpChannel: UInt8
        var serverSSRC: UInt32?
    }

    private let configuration: RTSPConfiguration
    private let transport: any NetworkTransport
    private let log: Log
    private let requestURL: String
    private let credentials: HTTPCredentials?
    private let videoFrameTimeout: Duration
    /// Basic is never answered once the camera asked for Digest: in this session, and in the later sessions of the
    /// `RTSPMediaSource` that shares it.
    private let downgradeGuard: BasicDowngradeGuard
    /// `scheme:host:port` of `configuration.url`, the guard's key.
    private let hostKey: String

    private var phase = Phase.idle
    private var control: RTSPControlConnection?
    private var cseq = 0
    private var sessionID: String?
    private var sessionTimeout: Duration = .seconds(60)
    private var authorization = Authorization.none
    /// The camera answered a request carrying credentials with 2xx (cleared by the one retry it allows, see
    /// `updateAuthorization(from:rejecting:)`).
    private var credentialsAccepted = false
    private var useGetParameter = true
    private var sendRequire = false
    private var aggregateURL: String
    private var setupTracks: [SetupTrack] = []
    private var sessionInfo: RTSPSessionInfo?
    private var pipeline: MediaPipeline?
    private var backchannel: (channel: UInt8, packetizer: BackchannelPacketizer)?
    private var backgroundTasks: [Task<Void, Never>] = []
    private var closingTask: Task<Void, Never>?
    private var loggedBackchannelDrop = false

    public init(configuration: RTSPConfiguration, transport: any NetworkTransport) {
        self.init(configuration: configuration, transport: transport, videoFrameTimeout: nil)
    }

    /// `videoFrameTimeout`: see the type documentation (nil: the default). `downgradeGuard`: shared by the sessions of
    /// one camera (`RTSPMediaSource`), so a reconnect does not answer Basic after Digest either.
    init(configuration: RTSPConfiguration, transport: any NetworkTransport, videoFrameTimeout: Duration?,
         downgradeGuard: BasicDowngradeGuard = BasicDowngradeGuard()) {
        self.configuration = configuration
        self.transport = transport
        log = Log(category: "rtsp", cameraID: configuration.cameraID)
        requestURL = RTSPURL.requestString(for: configuration.url)
        credentials = configuration.credentials ?? RTSPURL.embeddedCredentials(in: configuration.url)
        aggregateURL = RTSPURL.requestString(for: configuration.url)
        self.videoFrameTimeout = videoFrameTimeout ?? max(configuration.timeout * 3, .seconds(30))
        self.downgradeGuard = downgradeGuard
        let url = configuration.url
        hostKey = "\(url.scheme?.lowercased() ?? "rtsp"):\(url.host?.lowercased() ?? ""):\(url.port ?? 554)"
    }

    deinit {
        backgroundTasks.forEach { $0.cancel() }
        pipeline?.finish(throwing: nil)
        control?.close()
    }

    // MARK: Public API

    /// OPTIONS, DESCRIBE (auth), SETUP (TCP interleaved).
    public func connect() async throws -> RTSPSessionInfo {
        guard phase == .idle else { throw RTSPError.protocolError("connect() may be called once per client") }
        phase = .connecting
        do {
            let info = try await performConnect()
            guard phase == .connecting else { throw TransportError.closed }   // closed while connecting
            phase = .connected
            sessionInfo = info
            return info
        } catch {
            await abandonSession()
            throw error
        }
    }

    /// PLAY + keepalive; depacketized samples.
    public func play() async throws -> AsyncThrowingStream<MediaSample, any Error> {
        guard phase == .connected, let control else { throw RTSPError.protocolError("play() requires a connected client") }
        phase = .starting   // before any suspension: a concurrent play() is rejected above
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self, bufferingPolicy: SampleDelivery.bufferingPolicy)
        let plans = setupTracks.filter { $0.track.kind != .backchannel }.map { setup in
            MediaPipeline.TrackPlan(track: setup.track, rtpChannel: setup.rtpChannel, rtcpChannel: setup.rtcpChannel,
                                    videoFormat: setup.track.kind == .video ? sessionInfo?.videoFormat : nil,
                                    audioFormat: setup.track.kind == .audio ? sessionInfo?.audioFormat : nil)
        }
        let pipeline = MediaPipeline(plans: plans, continuation: continuation, log: log)
        self.pipeline = pipeline
        control.setInterleavedHandler { channel, payload, arrival in
            pipeline.handle(channel: channel, payload: payload, arrival: arrival)
        }
        control.setCloseHandler { [weak self] error in
            pipeline.finish(throwing: error)
            Task { await self?.connectionLost(error) }
        }
        // A receiving session lives as long as its stream: dropping or cancelling the stream closes it (the handler
        // keeps the client alive until then). A talkback-only session has no stream to hold.
        if !plans.isEmpty {
            continuation.onTermination = { termination in
                if case .cancelled = termination { Task { await self.close() } }
            }
        }

        do {
            var headers: [(String, String)] = [("Range", "npt=0.000-")]
            if sendRequire { headers.append(("Require", Self.backchannelRequire)) }
            let response = try await request("PLAY", url: aggregateURL, headers: headers)
            try Self.check(response, method: "PLAY")
        } catch {
            pipeline.finish(throwing: error)
            await abandonSession()
            throw error
        }
        guard phase == .starting else {
            pipeline.finish(throwing: TransportError.closed)
            throw TransportError.closed
        }
        phase = .playing
        startKeepalive()
        if !plans.isEmpty { startWatchdog(pipeline, hasVideo: plans.contains { $0.track.kind == .video }) }
        log.info("Playing \(Redact.url(configuration.url)) (\(plans.map { $0.track.encoding }.joined(separator: ", ")))")
        return stream
    }

    /// Sends one audio frame on the ONVIF backchannel (requires a backchannel track and PLAY). The frame's codec and
    /// sample rate must match `RTSPSessionInfo.backchannelFormat`.
    public func sendBackchannel(_ frame: EncodedAudioFrame) async throws {
        guard phase == .playing, let control else { throw RTSPError.protocolError("sendBackchannel requires a playing session") }
        guard var sender = backchannel else { throw RTSPError.protocolError("the camera offers no audio backchannel") }
        let packets = try sender.packetizer.packetize(frame)
        backchannel = sender
        var wire = Data()
        for packet in packets { wire.append(RTSPRequestSerializer.interleaved(channel: sender.channel, payload: packet.serialized())) }
        if try !control.send(wire), !loggedBackchannelDrop {
            loggedBackchannelDrop = true
            log.warning("Camera is not reading backchannel audio; dropping audio until it catches up")
        }
    }

    /// TEARDOWN, then closes the connection. The sample stream finishes normally. Idempotent; concurrent calls
    /// return once the first one has finished.
    public func close() async {
        if let closingTask {
            await closingTask.value
            return
        }
        let previous = phase
        guard previous != .closed else { return }
        phase = .closed
        backgroundTasks.forEach { $0.cancel() }
        backgroundTasks = []
        pipeline?.finish(throwing: nil)
        let task = Task { await self.teardown(after: previous) }
        closingTask = task
        await task.value
    }

    private func teardown(after previous: Phase) async {
        if let control, sessionID != nil, !control.isClosed, previous != .idle {
            control.setCloseHandler(nil)
            _ = try? await request("TEARDOWN", url: aggregateURL, timeout: min(configuration.timeout, .seconds(2)), allowClosed: true)
        }
        control?.close()
        control = nil
    }

    // MARK: Connect

    private func performConnect() async throws -> RTSPSessionInfo {
        guard let components = URLComponents(url: configuration.url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "rtsp",
              let host = components.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else {
            throw RTSPError.protocolError("unsupported RTSP URL")
        }
        let port = components.port ?? 554
        guard (1...65_535).contains(port) else { throw RTSPError.protocolError("invalid RTSP port") }
        let connection = try await transport.connect(host: host, port: UInt16(port), timeout: configuration.timeout)
        guard phase == .connecting else {
            connection.close()
            throw TransportError.closed
        }
        control = RTSPControlConnection(connection: connection, log: log)

        // OPTIONS (some cameras challenge it; others answer 4xx — neither is fatal).
        let options = try await request("OPTIONS", url: requestURL)
        if options.status == 401 { throw RTSPError.unauthorized }
        if (200..<300).contains(options.status), let value = options.headers["Public"] {
            useGetParameter = value.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).uppercased() == "GET_PARAMETER" }
        }

        // DESCRIBE
        var wantBackchannel = configuration.requestBackchannel || configuration.backchannelOnly
        var describe = try await request("DESCRIBE", url: requestURL, headers: describeHeaders(backchannel: wantBackchannel))
        if wantBackchannel, [551, 400, 405, 501].contains(describe.status) {
            log.info("Camera refused the ONVIF backchannel (\(describe.status)); continuing without it")
            wantBackchannel = false
            describe = try await request("DESCRIBE", url: requestURL, headers: describeHeaders(backchannel: false))
        }
        try Self.check(describe, method: "DESCRIBE")
        let sdp = try SDPSession.parse(String(decoding: describe.body, as: UTF8.self))
        let base = (describe.headers["Content-Base"] ?? describe.headers["Content-Location"])
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
            .map(RTSPURL.requestString(for:)) ?? requestURL
        aggregateURL = RTSPURL.resolve(control: sdp.control ?? "*", base: base)

        // Track selection
        let allTracks = RTSPSessionDescription.tracks(in: sdp, backchannelRequested: wantBackchannel)
        var selected: [RTSPTrack] = []
        var videoFormat: VideoFormat?
        var audioFormat: AudioFormat?
        var backchannelFormat: AudioFormat?
        if !configuration.backchannelOnly {
            let videoTracks = allTracks.filter { $0.kind == .video }
            guard let video = videoTracks.first(where: RTSPSessionDescription.isSupportedVideo) else {
                if let unsupported = videoTracks.first { throw RTSPError.unsupportedCodec(RTSPSessionDescription.unsupportedDescription(unsupported)) }
                throw RTSPError.noVideoTrack
            }
            selected.append(video)
            videoFormat = RTSPSessionDescription.videoFormat(for: video)
            if let audio = allTracks.first(where: RTSPSessionDescription.isUsableAudio) {
                selected.append(audio)
                audioFormat = RTSPSessionDescription.audioFormat(for: audio)
            }
        }
        if wantBackchannel, let track = allTracks.first(where: { $0.kind == .backchannel && RTSPSessionDescription.clockRateRange.contains($0.clockRate)
                                                                 && RTSPSessionDescription.audioFormat(for: $0) != nil }) {
            selected.append(track)
            backchannelFormat = RTSPSessionDescription.audioFormat(for: track)
        } else if configuration.backchannelOnly {
            throw RTSPError.protocolError("the camera offers no audio backchannel")
        }
        sendRequire = backchannelFormat != nil

        // SETUP. Video (or the backchannel of a talkback-only session) is required; audio and the backchannel of a
        // viewing session are optional: a camera that refuses them still streams video.
        for (index, track) in selected.enumerated() {
            let requested = (UInt8(truncatingIfNeeded: index * 2), UInt8(truncatingIfNeeded: index * 2 + 1))
            var headers = [("Transport", "RTP/AVP/TCP;unicast;interleaved=\(requested.0)-\(requested.1)")]
            if sendRequire { headers.append(("Require", Self.backchannelRequire)) }
            let response = try await request("SETUP", url: RTSPURL.resolve(control: track.control, base: base), headers: headers)
            if !(200..<300).contains(response.status), index > 0 {
                log.info("Camera refused SETUP of the \(track.kind) track (\(response.status)); continuing without it")
                if track.kind == .audio { audioFormat = nil } else { backchannelFormat = nil }
                continue
            }
            if response.status == 461 { throw RTSPError.protocolError("camera refused RTP over TCP (461 Unsupported Transport)") }
            try Self.check(response, method: "SETUP")
            if sessionID == nil {
                guard let value = response.headers["Session"], let session = RTSPHeaderValues.session(value) else {
                    throw RTSPError.protocolError("SETUP response without Session")
                }
                sessionID = session.id
                if let timeout = session.timeout { sessionTimeout = timeout }
            }
            let transportHeader = response.headers["Transport"] ?? ""
            let parameters = RTSPHeaderValues.transportParameters(transportHeader)
            // A camera that silently switched to UDP would never deliver media over this connection.
            if !transportHeader.isEmpty, parameters["interleaved"] == nil, !(parameters[""] ?? "").uppercased().hasSuffix("/TCP") {
                throw RTSPError.protocolError("camera answered SETUP with a non-TCP transport (\(Redact.cameraText(parameters[""] ?? "")))")
            }
            let channels = RTSPHeaderValues.interleavedChannels(transportHeader) ?? (requested.0, requested.1)
            let ssrc = parameters["ssrc"].flatMap { UInt32($0, radix: 16) }
            setupTracks.append(SetupTrack(track: track, rtpChannel: channels.rtp, rtcpChannel: channels.rtcp, serverSSRC: ssrc))
        }
        if let format = backchannelFormat, let setup = setupTracks.first(where: { $0.track.kind == .backchannel }) {
            backchannel = (setup.rtpChannel, BackchannelPacketizer(format: format, payloadType: setup.track.payloadType,
                                                                   clockRate: setup.track.clockRate,
                                                                   ssrc: setup.serverSSRC ?? .random(in: 1...UInt32.max)))
        }
        let active = setupTracks.map { "\($0.track.kind) \($0.track.encoding)" }.joined(separator: ", ")
        log.info("Connected to \(Redact.url(configuration.url)): \(active)")
        return RTSPSessionInfo(tracks: allTracks, videoFormat: videoFormat, audioFormat: audioFormat, backchannelFormat: backchannelFormat)
    }

    private func describeHeaders(backchannel: Bool) -> [(String, String)] {
        var headers = [("Accept", "application/sdp")]
        if backchannel { headers.append(("Require", Self.backchannelRequire)) }
        return headers
    }

    private static func check(_ response: RTSPResponse, method: String) throws {
        switch response.status {
        case 200..<300: return
        case 401, 403: throw RTSPError.unauthorized
        case 404: throw RTSPError.notFound
        default: throw RTSPError.badStatus(response.status)
        }
    }

    // MARK: Requests

    /// Sends a request with CSeq, User-Agent, Session and Authorization; answers a 401 challenge by retrying with
    /// credentials (see `updateAuthorization(from:rejecting:)`: wrong credentials cost exactly one authenticated
    /// attempt).
    private func request(_ method: String, url: String, headers extra: [(String, String)] = [], timeout: Duration? = nil,
                         allowClosed: Bool = false) async throws -> RTSPResponse {
        var attempts = 0
        while true {
            guard let control, allowClosed || phase != .closed else { throw TransportError.closed }
            cseq += 1
            var headers = [("CSeq", String(cseq)), ("User-Agent", configuration.userAgent)]
            if let sessionID, method != "OPTIONS" || phase == .playing { headers.append(("Session", sessionID)) }
            let authorizationValue = authorizationHeader(method: method, uri: url)
            let sent = authorizationValue == nil ? Authorization.none : authorization
            if let authorizationValue { headers.append(("Authorization", authorizationValue)) }
            headers += extra
            let data = RTSPRequestSerializer.serialize(method: method, uri: url, headers: headers)
            let response = try await control.request(data, cseq: cseq, timeout: timeout ?? configuration.timeout)
            attempts += 1
            if authorizationValue != nil, (200..<300).contains(response.status) { credentialsAccepted = true }
            guard response.status == 401, attempts < 3, updateAuthorization(from: response, rejecting: sent) else { return response }
        }
    }

    private func authorizationHeader(method: String, uri: String) -> String? {
        guard let credentials else { return nil }
        switch authorization {
        case .none:
            return nil
        case .basic:
            return BasicAuth.header(credentials)
        case .digest(let challenge, var authenticator):
            let value = authenticator.authorization(for: challenge, method: method, uri: uri)
            authorization = .digest(challenge, authenticator)
            return value
        }
    }

    /// Adopts the challenge of a 401 to a request sent with `sent` and says whether to retry; false returns the 401 to
    /// the caller. A request without credentials is retried with them (Digest preferred over Basic; Basic never once
    /// this camera asked for Digest, in this or an earlier session sharing the `BasicDowngradeGuard`). A 401 to
    /// credentials means they are wrong (RFC 2617 §3.2.1, RFC 7616 §3.3: `stale` absent or false), whatever new nonce
    /// it carries (live555 answers every failed login with a fresh one), so wrong credentials cost one authenticated
    /// attempt, not one per nonce, against cameras that lock out after a few failed logins. Retried anyway: a stale
    /// Digest nonce (`stale=true`), a switch from Basic to Digest (never back), and once a fresh Digest nonce after the
    /// camera accepted these credentials on this connection (a nonce that expired without `stale`).
    private func updateAuthorization(from response: RTSPResponse, rejecting sent: Authorization) -> Bool {
        guard let credentials else { return false }
        let challenges = response.headers.values(for: "WWW-Authenticate")
        let digest = challenges.lazy.compactMap(DigestChallenge.parse).first
        if digest != nil { downgradeGuard.digestRequested(by: hostKey) }
        switch sent {
        case .none:
            if digest == nil {
                guard challenges.contains(where: { $0.lowercased().hasPrefix("basic") }) else { return false }
                guard downgradeGuard.mayAnswerBasic(from: hostKey, log: log) else { return false }
                authorization = .basic
                return true
            }
        case .basic:
            guard digest != nil else { return false }
        case .digest(let rejected, _):
            guard let digest else { return false }
            if !digest.stale {
                guard credentialsAccepted, digest.nonce != rejected.nonce else { return false }
                credentialsAccepted = false
            }
        }
        guard let digest else { return false }
        authorization = .digest(digest, DigestAuthenticator(credentials: credentials))
        return true
    }

    // MARK: Keepalive, watchdog, teardown

    private func startKeepalive() {
        let interval = max(.seconds(1), sessionTimeout / 2)
        backgroundTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.sendKeepalive()
            }
        })
    }

    private func sendKeepalive() async {
        guard phase == .playing else { return }
        let method = useGetParameter ? "GET_PARAMETER" : "OPTIONS"
        do {
            let response = try await request(method, url: aggregateURL)
            if method == "GET_PARAMETER", [400, 405, 451, 454, 501, 551].contains(response.status) {
                log.debug("Camera does not support GET_PARAMETER keepalive (\(response.status)); using OPTIONS")
                useGetParameter = false
            }
        } catch {
            log.debug("Keepalive \(method) failed: \(error)")
        }
    }

    private func startWatchdog(_ pipeline: MediaPipeline, hasVideo: Bool) {
        let packetLimit = configuration.timeout
        let frameLimit = videoFrameTimeout
        let period = max(.milliseconds(100), min(min(packetLimit, frameLimit) / 4, .seconds(1)))
        backgroundTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: period)
                guard !Task.isCancelled else { return }
                let progress = pipeline.progress
                let now = ContinuousClock.now
                if now - progress.videoPacket > packetLimit {
                    await self?.stalled("No video packets for \(packetLimit)")
                    return
                }
                if hasVideo, now - progress.videoFrame > frameLimit {
                    await self?.stalled("No decodable video frame for \(frameLimit)")
                    return
                }
            }
        })
    }

    private func stalled(_ reason: String) async {
        guard phase == .playing else { return }
        log.warning("\(reason) from \(Redact.url(configuration.url)); closing")
        pipeline?.finish(throwing: RTSPError.timeout)
        await close()
    }

    private func connectionLost(_ error: any Error) {
        guard phase != .closed else { return }
        log.warning("RTSP connection to \(Redact.url(configuration.url)) lost: \(error)")
        shutdownWithoutTeardown()
    }

    /// Ends a session that failed before or while starting: TEARDOWN when the camera created a session (best effort,
    /// short timeout), then closes. When `close()` already ran, it did the TEARDOWN.
    private func abandonSession() async {
        let wasOpen = phase != .closed
        phase = .closed
        backgroundTasks.forEach { $0.cancel() }
        backgroundTasks = []
        if wasOpen, sessionID != nil, let control, !control.isClosed {
            control.setCloseHandler(nil)
            _ = try? await request("TEARDOWN", url: aggregateURL, timeout: min(configuration.timeout, .seconds(2)), allowClosed: true)
        }
        if wasOpen {
            control?.close()
            control = nil
        }
    }

    private func shutdownWithoutTeardown() {
        phase = .closed
        backgroundTasks.forEach { $0.cancel() }
        backgroundTasks = []
        control?.close()
        control = nil
    }
}
