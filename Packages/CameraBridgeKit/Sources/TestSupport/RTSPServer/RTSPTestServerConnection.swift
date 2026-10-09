import BridgeSupport
import Foundation
import MediaCore
import RTP
import Synchronization

/// One client connection of `RTSPTestServer`: request handling, session state and the media sender.
final class RTSPTestServerConnection: Sendable {
    static let backchannelRequire = "www.onvif.org/ver20/backchannel"

    private struct TrackSetup: Sendable {
        var rtp: UInt8
        var rtcp: UInt8
    }

    private struct State {
        var sessionID: String?
        var tracks: [Int: TrackSetup] = [:]
        var playing = false
        var tasks: [Task<Void, Never>] = []
        var subscription: UUID?
        var lastRequest = ContinuousClock.now
        var closed = false
    }

    let number: Int
    private let connection: any TCPConnection
    private weak let server: RTSPTestServer?
    private let configuration: RTSPTestServer.Configuration
    private let nonce: String
    private let state = Mutex(State())

    init(number: Int, connection: any TCPConnection, server: RTSPTestServer) {
        self.number = number
        self.connection = connection
        self.server = server
        configuration = server.configuration
        nonce = server.nonce
    }

    func start() {
        let task = Task { await self.readLoop() }
        state.withLock { $0.tasks.append(task) }
        if configuration.enforceSessionTimeout {
            let watchdog = Task { await self.sessionWatchdog() }
            state.withLock { $0.tasks.append(watchdog) }
        }
    }

    func close() {
        let (tasks, subscription, alreadyClosed) = state.withLock { s in
            defer {
                s.closed = true
                s.tasks = []
                s.subscription = nil
            }
            return (s.tasks, s.subscription, s.closed)
        }
        guard !alreadyClosed else { return }
        connection.close()
        tasks.forEach { $0.cancel() }
        if let subscription { server?.unsubscribe(subscription) }
        server?.connectionClosed(number)
    }

    // MARK: Requests

    private func readLoop() async {
        var parser = TestServerRequestParser()
        defer { close() }
        do {
            while !Task.isCancelled {
                guard let data = try await connection.receive(maximumLength: 64 * 1024) else { return }
                parser.append(data)
                while let message = try parser.next() {
                    switch message {
                    case .request(let method, let uri, let headers):
                        state.withLock { $0.lastRequest = .now }
                        server?.record(RTSPTestServer.RecordedRequest(method: method, uri: uri, headers: headers, connection: number))
                        let (response, closeAfterSending) = await handle(method: method, uri: uri, headers: headers)
                        try await connection.send(response)
                        if closeAfterSending { return }
                    case .interleaved(let channel, let payload):
                        let backchannel = state.withLock { $0.tracks[2]?.rtp }
                        if channel == backchannel, let packet = try? RTPPacket(parsing: payload) {
                            server?.recordBackchannel(packet)
                        }
                    }
                }
            }
        } catch {
            return
        }
    }

    private func handle(method: String, uri: String, headers: HTTPHeaders) async -> (Data, Bool) {
        let cseq = headers["CSeq"]
        let wantsBackchannel = (headers["Require"] ?? "").contains(Self.backchannelRequire)
        if method != "OPTIONS", !authorized(method: method, headers: headers) {
            return (unauthorized(cseq: cseq), false)
        }
        if let session = headers["Session"]?.split(separator: ";").first.map(String.init),
           let current = state.withLock({ $0.sessionID }), session != current {
            return (response(454, "Session Not Found", cseq: cseq), false)
        }
        switch method {
        case "OPTIONS":
            var methods = ["OPTIONS", "DESCRIBE", "SETUP", "PLAY", "TEARDOWN"]
            if configuration.supportsGetParameter { methods.append("GET_PARAMETER") }
            return (response(200, "OK", cseq: cseq, headers: [("Public", methods.joined(separator: ", "))]), false)
        case "DESCRIBE":
            if wantsBackchannel, configuration.backchannel == nil {
                return (response(551, "Option not supported", cseq: cseq, headers: [("Unsupported", Self.backchannelRequire)]), false)
            }
            guard let video = await server?.videoFormat() else { return (response(503, "Service Unavailable", cseq: cseq), false) }
            let base = baseURL
            let sdp = TestServerSDP.make(video: video, audio: configuration.audio, backchannel: wantsBackchannel ? configuration.backchannel : nil,
                                         parameterSetsInSDP: configuration.parameterSetsInSDP,
                                         controlBase: configuration.absoluteControlURLs ? base : nil)
            return (response(200, "OK", cseq: cseq, headers: [("Content-Type", "application/sdp"), ("Content-Base", base)], body: Data(sdp.utf8)), false)
        case "SETUP":
            guard let track = Self.trackNumber(in: uri), track == 0 || (track == 1 && configuration.audio != nil)
                    || (track == 2 && configuration.backchannel != nil) else {
                return (response(404, "Not Found", cseq: cseq), false)
            }
            let transport = headers["Transport"] ?? ""
            guard transport.contains("TCP"), let channels = Self.interleaved(transport) else {
                return (response(461, "Unsupported Transport", cseq: cseq), false)
            }
            let sessionID = state.withLock { s -> String in
                let id = s.sessionID ?? String(format: "%08X", UInt32.random(in: 1...UInt32.max))
                s.sessionID = id
                s.tracks[track] = TrackSetup(rtp: channels.0, rtcp: channels.1)
                return id
            }
            let ssrc = String(format: "%08X", UInt32.random(in: 1...UInt32.max))
            return (response(200, "OK", cseq: cseq, headers: [
                ("Transport", "RTP/AVP/TCP;unicast;interleaved=\(channels.0)-\(channels.1);ssrc=\(ssrc)"),
                ("Session", "\(sessionID);timeout=\(configuration.sessionTimeout)"),
            ]), false)
        case "PLAY":
            guard let sessionID = state.withLock({ $0.sessionID }), headers["Session"] != nil else {
                return (response(454, "Session Not Found", cseq: cseq), false)
            }
            startMedia()
            let rtpInfo = state.withLock { s in s.tracks.keys.sorted().map { "url=\(baseURL)trackID=\($0);seq=0;rtptime=0" } }
            return (response(200, "OK", cseq: cseq, headers: [("Session", sessionID), ("Range", "npt=now-"),
                                                               ("RTP-Info", rtpInfo.joined(separator: ","))]), false)
        case "GET_PARAMETER" where configuration.supportsGetParameter:
            return (response(200, "OK", cseq: cseq), false)
        case "TEARDOWN":
            return (response(200, "OK", cseq: cseq), true)
        default:
            return (response(501, "Not Implemented", cseq: cseq), false)
        }
    }

    private var baseURL: String {
        "rtsp://127.0.0.1:\(server?.port ?? 0)\(configuration.path)/"
    }

    private func authorized(method: String, headers: HTTPHeaders) -> Bool {
        guard let credentials = configuration.credentials else { return true }
        let authorization = headers["Authorization"]
        switch configuration.authentication {
        case .basic:
            return TestDigest.verifyBasic(authorization: authorization, credentials: credentials)
        case .digest, .digestWithQop:
            return TestDigest.verify(authorization: authorization, method: method, credentials: credentials, realm: configuration.realm, nonce: nonce)
        }
    }

    private func unauthorized(cseq: String?) -> Data {
        var headers: [(String, String)] = []
        switch configuration.authentication {
        case .basic:
            headers.append(("WWW-Authenticate", "Basic realm=\"\(configuration.realm)\""))
        case .digest:
            headers.append(("WWW-Authenticate", "Digest realm=\"\(configuration.realm)\", nonce=\"\(nonce)\", stale=\"FALSE\""))
            headers.append(("WWW-Authenticate", "Basic realm=\"\(configuration.realm)\""))
        case .digestWithQop:
            headers.append(("WWW-Authenticate", "Digest realm=\"\(configuration.realm)\", qop=\"auth\", nonce=\"\(nonce)\", algorithm=MD5"))
        }
        return response(401, "Unauthorized", cseq: cseq, headers: headers)
    }

    private func response(_ status: Int, _ reason: String, cseq: String?, headers: [(String, String)] = [], body: Data = Data()) -> Data {
        var text = "RTSP/1.0 \(status) \(reason)\r\n"
        if let cseq { text += "CSeq: \(cseq)\r\n" }
        text += "Server: CameraBridge RTSPTestServer\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if !body.isEmpty { text += "Content-Length: \(body.count)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    private static func trackNumber(in uri: String) -> Int? {
        guard let range = uri.range(of: "trackID=", options: .backwards) else { return nil }
        return Int(uri[range.upperBound...].prefix { $0.isNumber })
    }

    private static func interleaved(_ transport: String) -> (UInt8, UInt8)? {
        guard let range = transport.range(of: "interleaved=") else { return nil }
        let value = transport[range.upperBound...].prefix { $0.isNumber || $0 == "-" }
        let parts = value.split(separator: "-").compactMap { UInt8($0) }
        guard let first = parts.first else { return nil }
        return (first, parts.count > 1 ? parts[1] : first &+ 1)
    }

    private func sessionWatchdog() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            let (playing, last) = state.withLock { ($0.playing, $0.lastRequest) }
            if playing, ContinuousClock.now - last > .seconds(configuration.sessionTimeout) {
                server?.recordSessionTimeout()
                close()
                return
            }
        }
    }

    // MARK: Media

    private func startMedia() {
        guard let server else { return }
        let alreadyPlaying = state.withLock { s in
            defer { s.playing = true }
            return s.playing
        }
        guard !alreadyPlaying else { return }
        let (subscription, stream) = server.subscribe()
        let tracks = state.withLock { s in
            s.subscription = subscription
            return s.tracks
        }
        let media = Task { await self.sendMedia(stream, tracks: tracks) }
        var tasks = [media]
        if let closeAfter = server.faults.closeAfter {
            tasks.append(Task {
                try? await Task.sleep(for: closeAfter)
                if !Task.isCancelled { self.close() }
            })
        }
        state.withLock { $0.tasks += tasks }
    }

    private func sendMedia(_ stream: AsyncStream<MediaSample>, tracks: [Int: TrackSetup]) async {
        guard let video = tracks[0] else { return }
        let clock = ContinuousClock()
        let playStart = clock.now
        var videoPacketizer = TestServerPacketizer(maxPacketSize: configuration.maxPacketSize, parameterSetMode: configuration.parameterSetMode,
                                                   payloadType: 96)
        let audioFormat = configuration.audio
        var audioPacketizer = TestServerPacketizer(maxPacketSize: configuration.maxPacketSize, parameterSetMode: .separate,
                                                   payloadType: audioFormat.map { TestServerSDP.payloadType($0, backchannel: false) } ?? 0)
        let videoBase = UInt32.random(in: 0...UInt32.max)
        let audioBase = UInt32.random(in: 0...UInt32.max)
        var waitingForKeyframe = true
        var lastVideoReport: ContinuousClock.Instant?
        var lastAudioReport: ContinuousClock.Instant?
        var videoPackets: UInt32 = 0, videoOctets: UInt32 = 0, audioPackets: UInt32 = 0, audioOctets: UInt32 = 0
        var pendingAAC: [EncodedAudioFrame] = []

        for await sample in stream {
            guard let server else { return }
            let faults = server.faults
            if let stall = faults.stall {
                let elapsed = clock.now - playStart
                if elapsed >= stall.after, elapsed < stall.after + stall.duration {
                    waitingForKeyframe = true
                    continue
                }
            }
            var wire = Data()
            switch sample {
            case .video(let frame):
                if waitingForKeyframe, !frame.isKeyframe { continue }
                waitingForKeyframe = false
                let timestamp = videoBase &+ UInt32(truncatingIfNeeded: frame.pts.converted(to: 90_000).value)
                let droppedBefore = videoPacketizer.droppedFragments
                let packets = videoPacketizer.packetize(frame, timestamp: timestamp, dropEveryNthFragment: faults.dropEveryNthFUFragment)
                server.recordDroppedFragments(videoPacketizer.droppedFragments - droppedBefore)
                for packet in packets {
                    let bytes = packet.serialized()
                    videoPackets &+= 1
                    videoOctets &+= UInt32(truncatingIfNeeded: packet.payload.count)
                    wire.append(Self.interleaved(channel: video.rtp, bytes))
                }
                server.recordSentVideoFrame()
                if let interval = configuration.senderReportInterval, lastVideoReport.map({ clock.now - $0 >= interval }) ?? true {
                    lastVideoReport = clock.now
                    let ntp = NTPTime.timestamp(for: frame.wallClock.addingTimeInterval(Self.seconds(configuration.senderReportClockOffset)))
                    wire.append(Self.interleaved(channel: video.rtcp, TestServerPacketizer.senderReport(
                        ssrc: videoPacketizer.ssrc, ntp: ntp, rtpTimestamp: timestamp, packets: videoPackets, octets: videoOctets)))
                }
            case .audio(let frame):
                guard waitingForKeyframe == false, let audio = tracks[1], let audioFormat, frame.format.codec == audioFormat.codec else { continue }
                let clockRate = Int32(audioFormat.sampleRate)
                var payload: Data?
                var timestamp = audioBase &+ UInt32(truncatingIfNeeded: frame.pts.converted(to: clockRate).value)
                if audioFormat.codec == .aac {
                    pendingAAC.append(frame)
                    if pendingAAC.count >= max(1, configuration.aacUnitsPerPacket), let first = pendingAAC.first {
                        timestamp = audioBase &+ UInt32(truncatingIfNeeded: first.pts.converted(to: clockRate).value)
                        payload = TestServerPacketizer.aacHBR(pendingAAC.map(\.data))
                        pendingAAC.removeAll()
                    }
                } else {
                    payload = frame.data
                }
                guard let payload else { continue }
                let packet = audioPacketizer.audioPacket(payload: payload, timestamp: timestamp)
                audioPackets &+= 1
                audioOctets &+= UInt32(truncatingIfNeeded: payload.count)
                wire.append(Self.interleaved(channel: audio.rtp, packet.serialized()))
                if let interval = configuration.senderReportInterval, lastAudioReport.map({ clock.now - $0 >= interval }) ?? true {
                    lastAudioReport = clock.now
                    let ntp = NTPTime.timestamp(for: frame.wallClock.addingTimeInterval(Self.seconds(configuration.senderReportClockOffset)))
                    wire.append(Self.interleaved(channel: audio.rtcp, TestServerPacketizer.senderReport(
                        ssrc: audioPacketizer.ssrc, ntp: ntp, rtpTimestamp: timestamp, packets: audioPackets, octets: audioOctets)))
                }
            }
            guard !wire.isEmpty else { continue }
            do {
                try await connection.send(wire)
            } catch {
                close()
                return
            }
        }
    }

    private static func interleaved(channel: UInt8, _ packet: Data) -> Data {
        var data = Data([0x24, channel, UInt8(packet.count >> 8), UInt8(packet.count & 0xFF)])
        data.append(packet)
        return data
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        duration.timeInterval
    }
}
