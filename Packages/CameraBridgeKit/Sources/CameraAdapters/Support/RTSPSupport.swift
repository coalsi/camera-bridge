import BridgeSupport
import Foundation
import MediaCore
import RTSP
import Synchronization

/// The parts of `RTSPClient` the adapters use (probing, ONVIF backchannel). Injectable so tests never open RTSP.
protocol RTSPSessionClient: Sendable {
    func connect() async throws -> RTSPSessionInfo
    func play() async throws -> AsyncThrowingStream<MediaSample, any Error>
    func sendBackchannel(_ frame: EncodedAudioFrame) async throws
    func close() async
}

extension RTSPClient: RTSPSessionClient {}

typealias RTSPSessionFactory = @Sendable (RTSPConfiguration) -> any RTSPSessionClient

enum RTSPProbing {
    static let probeTimeout: Duration = .seconds(8)

    static func factory(transport: any NetworkTransport) -> RTSPSessionFactory {
        { configuration in RTSPClient(configuration: configuration, transport: transport) }
    }

    /// `StreamInfo` from a negotiated session (codec, size, SPS frame rate, audio).
    static func streamInfo(url: URL, info: RTSPSessionInfo) -> StreamInfo {
        var stream = StreamInfo(url: url.removingUserInfo)
        if let video = info.videoFormat {
            stream.videoCodec = video.codec
            stream.width = video.width > 0 ? video.width : nil
            stream.height = video.height > 0 ? video.height : nil
            if video.codec == .h264, let sps = video.parameterSets.first { stream.fps = H264SPS.parse(sps)?.frameRate }
        }
        if let audio = info.audioFormat {
            stream.audioCodec = audio.codec
            stream.audioSampleRate = audio.sampleRate
            stream.audioChannels = audio.channels
        }
        return stream
    }

    /// OPTIONS/DESCRIBE/SETUP then TEARDOWN; throws on failure or after `probeTimeout`. `cameraID`: the camera the probe
    /// is for (the RTSP session logs with it).
    static func describe(url: URL, credentials: HTTPCredentials?, requestBackchannel: Bool = false, cameraID: UUID? = nil,
                         timeout: Duration = RTSPProbing.probeTimeout, factory: RTSPSessionFactory) async throws -> RTSPSessionInfo {
        var configuration = RTSPConfiguration(url: url.removingUserInfo, credentials: credentials, requestBackchannel: requestBackchannel,
                                              timeout: timeout)
        configuration.cameraID = cameraID
        let session = factory(configuration)
        do {
            let info = try await withTimeout(timeout) { try await session.connect() }
            await session.close()
            return info
        } catch {
            await session.close()
            throw error
        }
    }

    /// The ONVIF audio backchannel format the camera offers on `url`, nil when it offers none or cannot be reached.
    static func backchannelFormat(url: URL, credentials: HTTPCredentials?, cameraID: UUID? = nil, factory: RTSPSessionFactory) async -> AudioFormat? {
        do {
            return try await describe(url: url, credentials: credentials, requestBackchannel: true, cameraID: cameraID, factory: factory)
                .backchannelFormat
        } catch {
            Log(category: "rtsp-probe", cameraID: cameraID)
                .info("backchannel probe of \(Redact.url(url)) failed: \(Redact.string(String(describing: error)))")
            return nil
        }
    }
}

/// Two-way audio through the ONVIF RTSP audio backchannel (`Require: www.onvif.org/ver20/backchannel`).
/// `inputFormat` is PCMU 8 kHz until `open()` negotiates the camera's backchannel format; read it after opening.
///
/// The session sets up only the backchannel track (`RTSPConfiguration.backchannelOnly`): the camera's own video and
/// audio would be a second full-bitrate stream per talking viewer, thrown away, and count against the camera's few
/// RTSP sessions. A camera that refuses such a session (an RTSP error status, or a protocol error such as a SETUP or
/// PLAY it cannot do without its media) gets one retry with the full session, whose media is drained.
final class RTSPBackchannelTalkbackSink: TalkbackSink, Sendable {
    static let defaultFormat = AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1)

    private struct State {
        var session: (any RTSPSessionClient)?
        var drain: Task<Void, Never>?
        var format: AudioFormat?
    }

    private let resolveURL: @Sendable () async throws -> URL
    private let credentials: HTTPCredentials?
    private let factory: RTSPSessionFactory
    private let state = Mutex(State())
    private let cameraID: UUID?
    private let log: Log
    /// A camera that stops reading fails `send` after this long; the session is closed.
    private let sendTimeout: Duration

    init(credentials: HTTPCredentials?, factory: @escaping RTSPSessionFactory, cameraID: UUID? = nil, sendTimeout: Duration = .seconds(5),
         resolveURL: @escaping @Sendable () async throws -> URL) {
        self.credentials = credentials
        self.factory = factory
        self.sendTimeout = sendTimeout
        self.resolveURL = resolveURL
        self.cameraID = cameraID
        self.log = Log(category: "talkback", cameraID: cameraID)
    }

    var inputFormat: AudioFormat { state.withLock { $0.format } ?? Self.defaultFormat }

    func open() async throws {
        await close()
        let url = try await resolveURL().removingUserInfo
        var configuration = RTSPConfiguration(url: url, credentials: credentials, requestBackchannel: true)
        configuration.backchannelOnly = true
        configuration.cameraID = cameraID
        let opened: (session: any RTSPSessionClient, format: AudioFormat, drain: Task<Void, Never>?)
        do {
            opened = try await start(configuration)
        } catch let error where Self.retriesWithMedia(after: error) {
            log.info("the camera refused a backchannel-only session (\(Redact.string(String(describing: error)))); opening a full session")
            configuration.backchannelOnly = false
            opened = try await start(configuration)
        }
        // A concurrent open() may have stored a session meanwhile: keep the newest, close the other.
        let previous = state.withLock { state in
            defer { state = State(session: opened.session, drain: opened.drain, format: opened.format) }
            return state
        }
        previous.drain?.cancel()
        await previous.session?.close()
        log.info("backchannel open (\(opened.format.codec.rawValue) \(opened.format.sampleRate) Hz)")
    }

    /// Connects and PLAYs one session (closed again on failure). A full session's camera media is drained so the RTSP
    /// client never buffers it.
    private func start(_ configuration: RTSPConfiguration) async throws
        -> (session: any RTSPSessionClient, format: AudioFormat, drain: Task<Void, Never>?) {
        let session = factory(configuration)
        do {
            let info = try await session.connect()
            guard let format = info.backchannelFormat else { throw CameraAdapterError.unsupported("the camera offers no ONVIF audio backchannel") }
            let samples = try await session.play()
            let drain = configuration.backchannelOnly ? nil : Task {
                do { for try await _ in samples {} } catch {}
            }
            return (session, format, drain)
        } catch {
            await session.close()
            throw error
        }
    }

    /// Errors after which a full session may still work: the camera answered, but refused the request as made.
    /// Rejected credentials, a wrong URL and unreachable cameras fail the same way with media.
    static func retriesWithMedia(after error: any Error) -> Bool {
        switch error as? RTSPError {
        case .badStatus?, .protocolError?: true
        default: false
        }
    }

    /// Fails with `TransportError.timedOut` when the camera does not take the frame within `sendTimeout` (the session
    /// is closed). Closing is what ends the pending send, which then fails too — possibly before the timer reports —
    /// so every failure after the timer fired is a timeout.
    func send(_ frame: EncodedAudioFrame) async throws {
        guard let session = state.withLock({ $0.session }) else { throw CameraAdapterError.unsupported("talkback is not open") }
        let timedOut = LockedValue(false)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await session.sendBackchannel(frame) }
                group.addTask {
                    try await Task.sleep(for: self.sendTimeout)
                    timedOut.set(true)
                    // The camera stopped reading: closing the session is what ends the pending send (the group waits for it).
                    let current = self.state.withLock { state -> Bool in
                        guard let stored = state.session, stored as AnyObject === session as AnyObject else { return false }
                        state.session = nil
                        state.drain?.cancel()
                        state.drain = nil
                        return true
                    }
                    if current { await session.close() }
                    throw TransportError.timedOut
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch {
            if timedOut.value { throw TransportError.timedOut }
            throw error
        }
    }

    func close() async {
        let (session, drain) = state.withLock { state in
            defer { state.session = nil; state.drain = nil }
            return (state.session, state.drain)
        }
        drain?.cancel()
        await session?.close()
    }
}
