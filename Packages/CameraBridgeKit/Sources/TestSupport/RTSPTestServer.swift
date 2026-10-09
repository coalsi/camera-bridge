import BridgeSupport
import Foundation
import MediaCore
import RTP
import Synchronization

/// Loopback RTSP/TCP-interleaved server for tests: serves a `MediaSource` like a camera would.
///
/// - One upstream subscription to `source`; each PLAYing session starts at the next keyframe.
/// - Optional Digest (RFC 2069 or qop=auth, MD5) or Basic authentication on every request except OPTIONS.
/// - Optional audio track (PCMU / PCMA / AAC-hbr) and optional ONVIF backchannel track (offered only when DESCRIBE
///   carries `Require: www.onvif.org/ver20/backchannel`, otherwise 551); received backchannel RTP is recorded.
/// - RTCP sender reports every `senderReportInterval` (NTP from the frames' wall clock + `senderReportClockOffset`).
/// - Fault injection (`Faults`, changeable while running): drop every Nth FU fragment, stall media for a while,
///   close the connection some time after PLAY. Optional session-timeout enforcement.
///
/// The server has its own request parser, packetizers and MD5 (it does not use the RTSP module), so it can serve
/// as an oracle for the client. Bind it to loopback only: `start()` listens with `loopbackOnly: true`.
public final class RTSPTestServer: Sendable {
    public enum Authentication: Sendable, Equatable { case digest, digestWithQop, basic }
    /// How parameter sets are sent in band before keyframes: one STAP-A / AP, or one packet each.
    public enum ParameterSetMode: Sendable, Equatable { case aggregated, separate }

    public struct Stall: Sendable, Equatable {
        public var after: Duration
        public var duration: Duration
        public init(after: Duration, duration: Duration) {
            self.after = after
            self.duration = duration
        }
    }

    public struct Faults: Sendable, Equatable {
        public var dropEveryNthFUFragment: Int?
        /// Media stops `after` PLAY for `duration` (frames are dropped; sending resumes at a keyframe).
        public var stall: Stall?
        /// The connection is closed this long after PLAY.
        public var closeAfter: Duration?

        public init(dropEveryNthFUFragment: Int? = nil, stall: Stall? = nil, closeAfter: Duration? = nil) {
            self.dropEveryNthFUFragment = dropEveryNthFUFragment
            self.stall = stall
            self.closeAfter = closeAfter
        }
    }

    public struct Configuration: Sendable {
        public var path: String = "/stream"
        public var credentials: HTTPCredentials?
        public var authentication: Authentication = .digest
        public var realm = "CameraBridge Test"
        /// Audio track to advertise; the source's audio frames are forwarded when their codec matches.
        public var audio: AudioFormat?
        /// AAC units per RTP packet (RFC 3640 allows several).
        public var aacUnitsPerPacket = 1
        /// ONVIF backchannel (sendonly) track format.
        public var backchannel: AudioFormat?
        public var parameterSetsInSDP = true
        public var parameterSetMode: ParameterSetMode = .aggregated
        /// Absolute `a=control` URLs instead of relative `trackID=N`.
        public var absoluteControlURLs = false
        /// Seconds advertised in the Session header.
        public var sessionTimeout = 60
        /// Close sessions that send no request for `sessionTimeout` seconds after PLAY.
        public var enforceSessionTimeout = false
        /// When false, GET_PARAMETER is answered 501 and not listed in `Public`.
        public var supportsGetParameter = true
        public var maxPacketSize = 1400
        /// nil: no RTCP.
        public var senderReportInterval: Duration? = .seconds(1)
        /// Added to the frames' wall clock in sender reports (a camera whose clock is off).
        public var senderReportClockOffset: Duration = .zero
        public var faults = Faults()

        public init() {}
    }

    public struct RecordedRequest: Sendable {
        public var method: String
        public var uri: String
        public var headers: HTTPHeaders
        public var connection: Int
    }

    private struct State {
        var listener: (any TCPListener)?
        var port: UInt16 = 0
        var acceptTask: Task<Void, Never>?
        var pumpTask: Task<Void, Never>?
        var subscribers: [UUID: AsyncStream<MediaSample>.Continuation] = [:]
        var videoFormat: VideoFormat?
        var faults: Faults
        var requests: [RecordedRequest] = []
        var backchannelPackets: [RTPPacket] = []
        var connections: [Int: RTSPTestServerConnection] = [:]
        var connectionCount = 0
        var droppedFragments = 0
        var sessionTimeouts = 0
        var sentVideoFrames = 0
    }

    let source: any MediaSource
    let transport: any NetworkTransport
    let configuration: Configuration
    let nonce: String
    private let state: Mutex<State>

    public init(source: any MediaSource, transport: any NetworkTransport, configuration: Configuration = Configuration()) {
        self.source = source
        self.transport = transport
        self.configuration = configuration
        nonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        state = Mutex(State(faults: configuration.faults))
    }

    deinit {
        let (listener, tasks) = state.withLock { ($0.listener, [$0.acceptTask, $0.pumpTask]) }
        listener?.close()
        tasks.forEach { $0?.cancel() }
    }

    /// Listens on an ephemeral loopback port and starts pulling from `source`.
    public func start() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        let stream = try await source.samples()
        let pumpTask = Task { [weak self] in
            do {
                for try await sample in stream {
                    guard let self else { return }
                    self.distribute(sample)
                }
            } catch {}
        }
        let acceptTask = Task { [weak self] in
            for await connection in listener.connections {
                guard let self else { connection.close(); return }
                self.accept(connection)
            }
        }
        state.withLock {
            $0.listener = listener
            $0.port = listener.port
            $0.pumpTask = pumpTask
            $0.acceptTask = acceptTask
        }
    }

    public func stop() async {
        let (listener, tasks, connections, subscribers) = state.withLock { s in
            defer {
                s.listener = nil
                s.connections = [:]
                s.subscribers = [:]
            }
            return (s.listener, [s.acceptTask, s.pumpTask], Array(s.connections.values), Array(s.subscribers.values))
        }
        listener?.close()
        tasks.forEach { $0?.cancel() }
        connections.forEach { $0.close() }
        subscribers.forEach { $0.finish() }
        await source.stop()
    }

    public var port: UInt16 { state.withLock { $0.port } }

    /// `rtsp://127.0.0.1:<port><path>`.
    public var url: URL {
        URL(string: "rtsp://127.0.0.1:\(port)\(configuration.path)") ?? URL(filePath: "/")
    }

    public var faults: Faults { state.withLock { $0.faults } }

    public func setFaults(_ faults: Faults) {
        state.withLock { $0.faults = faults }
    }

    // MARK: Observations

    public var requests: [RecordedRequest] { state.withLock { $0.requests } }
    public var backchannelPackets: [RTPPacket] { state.withLock { $0.backchannelPackets } }
    /// Accepted TCP connections so far.
    public var connectionCount: Int { state.withLock { $0.connectionCount } }
    public var droppedFragmentCount: Int { state.withLock { $0.droppedFragments } }
    /// Sessions closed by `enforceSessionTimeout`.
    public var sessionTimeoutCount: Int { state.withLock { $0.sessionTimeouts } }
    public var sentVideoFrameCount: Int { state.withLock { $0.sentVideoFrames } }

    /// Closes every open client connection (like a camera reboot) without stopping the server.
    public func dropConnections() {
        let connections = state.withLock { s in
            defer { s.connections = [:] }
            return Array(s.connections.values)
        }
        connections.forEach { $0.close() }
    }

    // MARK: Internal

    private func accept(_ connection: any TCPConnection) {
        let handler = state.withLock { s -> RTSPTestServerConnection in
            s.connectionCount += 1
            let handler = RTSPTestServerConnection(number: s.connectionCount, connection: connection, server: self)
            s.connections[s.connectionCount] = handler
            return handler
        }
        handler.start()
    }

    private func distribute(_ sample: MediaSample) {
        let subscribers = state.withLock { s -> [AsyncStream<MediaSample>.Continuation] in
            if case .video(let frame) = sample { s.videoFormat = frame.format }
            return Array(s.subscribers.values)
        }
        subscribers.forEach { $0.yield(sample) }
    }

    func subscribe() -> (UUID, AsyncStream<MediaSample>) {
        let (stream, continuation) = AsyncStream.makeStream(of: MediaSample.self, bufferingPolicy: .bufferingNewest(512))
        let id = UUID()
        state.withLock { $0.subscribers[id] = continuation }
        return (id, stream)
    }

    func unsubscribe(_ id: UUID) {
        let continuation = state.withLock { $0.subscribers.removeValue(forKey: id) }
        continuation?.finish()
    }

    /// Waits up to 5 s for the first video frame's format.
    func videoFormat() async -> VideoFormat? {
        for _ in 0..<250 {
            if let format = state.withLock({ $0.videoFormat }) { return format }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func record(_ request: RecordedRequest) {
        state.withLock { $0.requests.append(request) }
    }

    func recordBackchannel(_ packet: RTPPacket) {
        state.withLock { $0.backchannelPackets.append(packet) }
    }

    func recordDroppedFragments(_ count: Int) {
        guard count > 0 else { return }
        state.withLock { $0.droppedFragments += count }
    }

    func recordSentVideoFrame() {
        state.withLock { $0.sentVideoFrames += 1 }
    }

    func recordSessionTimeout() {
        state.withLock { $0.sessionTimeouts += 1 }
    }

    func connectionClosed(_ number: Int) {
        _ = state.withLock { $0.connections.removeValue(forKey: number) }
    }
}
