import BridgeSupport
import Foundation
import MediaCore
import Synchronization

/// Hikvision two-way audio: `PUT …/TwoWayAudio/channels/<n>/open`, then raw G.711 bytes on a long-lived
/// `PUT …/audioData` (`Content-Type: application/octet-stream`, `Content-Length: 0`, the camera reads audio from the
/// socket after answering 200), then `PUT …/close`.
///
/// Open/close go through `AuthenticatingHTTPClient`; the audio upload uses a raw TCP connection from the injected
/// `NetworkTransport` (URLSession cannot stream an unbounded request body) with a Digest/Basic answer computed from
/// the camera's challenge (never Basic once the camera asked for Digest). HTTPS cameras are not supported for talkback.
/// `inputFormat` is G.711 µ-law 8 kHz mono unless the camera reports A-law on `open()`; a channel set to any other
/// codec makes `open()` fail with `CameraAdapterError.unsupported` (see `format(for:)`).
///
/// The TwoWayAudio channel is chosen on each `open()` by `channel(forCamera:in:)`, the rule the driver's probe offers
/// two-way audio by: the camera's own channel when the device lists it, else channel 1 (an NVR's shared two-way
/// channel). Nothing listed (or the list failed) opens the camera's own channel. The camera's side of the session
/// (open, upload, close) belongs to the device channel's `HikvisionTwoWaySession`, shared with every other camera's sink
/// on that channel: an open joins a session another camera holds instead of closing it, a close ends the session only
/// when no other camera holds it, and while another camera talks this sink's audio is dropped.
final class HikvisionTalkbackSink: TalkbackSink, Sendable {
    /// This sink's hold on a device channel's session.
    private struct Lease: Sendable {
        let session: HikvisionTwoWaySession
        let id: UUID
    }

    private struct State {
        /// The session this sink holds (until `close()`, also after its upload failed); nil when none.
        var lease: Lease?
        var format = AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1)
        /// Audio is being dropped because another camera on the device talks (logged once per stretch).
        var dropping = false
    }

    private let endpoint: CameraEndpoint
    private let credentials: HTTPCredentials?
    private let transport: any NetworkTransport
    /// The camera's own channel (its camera number: 1, or the NVR channel).
    private let channel: String
    private let isapi: HikvisionISAPI
    private let state = Mutex(State())
    private let log: Log
    /// A camera that stops reading the upload fails `send` after this long (instead of blocking it forever).
    private let sendTimeout: Duration
    /// The upload never answers Basic once the camera asked for Digest (a host impersonating it would read the password).
    private let downgradeGuard = BasicDowngradeGuard()

    init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, transport: any NetworkTransport, channel: String = "1", cameraID: UUID? = nil,
         sendTimeout: Duration = .seconds(5)) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
        self.channel = channel
        self.sendTimeout = sendTimeout
        self.isapi = HikvisionISAPI(endpoint: endpoint, credentials: credentials)
        self.log = Log(category: "talkback", cameraID: cameraID)
    }

    deinit {
        // Dropped without close(): let go of the shared session, so that the last holder still closes it.
        if let lease = state.withLock({ $0.lease }) {
            Task { await lease.session.release(lease.id) }
        }
    }

    var inputFormat: AudioFormat { state.withLock { $0.format } }

    private static func basePath(_ channel: String) -> String { "/ISAPI/System/TwoWayAudio/channels/\(channel)" }

    /// The listed TwoWayAudio channel that carries talkback for camera channel `camera`: its own when listed, else
    /// channel 1 (an NVR's cameras share it); nil when neither is listed. `HikvisionDriver.offersTwoWayAudio` offers two-way
    /// audio by the same rule, so the Speaker it publishes always opens a channel the device has.
    static func channel(forCamera camera: String, in channels: [HikvisionTwoWayChannel]) -> HikvisionTwoWayChannel? {
        channels.first { $0.id == camera } ?? channels.first { $0.id == "1" }
    }

    func open() async throws {
        await releaseLease()   // this sink's previous session (the last holder's release closes it)
        guard !endpoint.useHTTPS else { throw CameraAdapterError.unsupported("Hikvision two-way audio over HTTPS") }
        let reported = (try? await isapi.twoWayAudioChannels()).flatMap { Self.channel(forCamera: self.channel, in: $0) }
        let channel = reported?.id ?? self.channel
        let basePath = Self.basePath(channel)
        let format = try Self.format(for: reported)
        state.withLock { $0.format = format }
        let key = HikvisionTwoWaySession.Key(host: endpoint.host.lowercased(), port: endpoint.httpPort, useHTTPS: endpoint.useHTTPS,
                                             channel: channel)
        let id = UUID()
        let isapi = isapi
        let (session, joined) = try await HikvisionTwoWaySession.acquire(key, lease: id) { [self] in
            _ = try? await isapi.put("\(basePath)/close")   // a stale session blocks open
            _ = try await isapi.put("\(basePath)/open")
            do {
                return try await openAudioData(path: "\(basePath)/audioData")
            } catch {
                _ = try? await isapi.put("\(basePath)/close")   // do not leave the camera's two-way session open
                throw error
            }
        } close: {
            _ = try? await isapi.put("\(basePath)/close")
        }
        // A concurrent open() may have taken a lease meanwhile: keep the newest, release the other.
        let previous = state.withLock { state in
            defer {
                state.lease = Lease(session: session, id: id)
                state.dropping = false
            }
            return state.lease
        }
        if let previous { await previous.session.release(previous.id) }
        if joined {
            log.info("two-way audio joins the open session on channel \(channel) (another camera on this device uses it)")
        } else {
            log.info("two-way audio open on channel \(channel) (\(format.codec.rawValue))")
        }
    }

    /// Sends on the shared session; dropped (no error) while another camera on the device talks.
    func send(_ frame: EncodedAudioFrame) async throws {
        guard let lease = state.withLock({ $0.lease }) else { throw CameraAdapterError.unsupported("talkback is not open") }
        let sent = try await lease.session.send(frame.data, from: lease.id, timeout: sendTimeout)
        let startedDropping = state.withLock { state -> Bool in
            defer { state.dropping = !sent }
            return !sent && !state.dropping
        }
        if startedDropping {
            log.info("another camera on this device is talking on two-way channel \(lease.session.key.channel); "
                     + "this camera's audio is dropped until it stops")
        }
    }

    /// Sends, closing the connection after `timeout` (a pending send only ends when its connection closes) and then
    /// failing with `TransportError.timedOut` — also when the closed send fails first, as it may.
    static func send(_ data: Data, on connection: any TCPConnection, timeout: Duration) async throws {
        let timedOut = LockedValue(false)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await connection.send(data) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    timedOut.set(true)
                    connection.close()
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

    /// Lets go of the shared session; the camera's session closes when no other camera holds it.
    func close() async {
        await releaseLease()
    }

    /// What the upload carries for the channel's reported `audioCompressionType`: G.711 A-law or µ-law as reported,
    /// µ-law when nothing is reported (no channel, no codec, or the request failed). Any other codec (G.726, G.722.1,
    /// MP2L2, AAC, PCM…) would play the raw G.711 bytes as noise: `open()` refuses it, naming the setting to change
    /// (the integration brief keeps Hikvision two-way audio on G.711µ; the camera's configuration is not rewritten).
    static func format(for reported: HikvisionTwoWayChannel?) throws -> AudioFormat {
        switch reported?.codec {
        case .pcma?:
            return AudioFormat(codec: .pcma, sampleRate: 8000, channels: 1)
        case .pcmu?:
            return AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1)
        default:
            if let compression = reported?.compression.map({ String($0.prefix(40)) }), !compression.isEmpty {
                throw CameraAdapterError.unsupported("Hikvision two-way audio is set to \(compression); set the camera's "
                                                     + "two-way audio encoding to G.711ulaw (or G.711alaw)")
            }
            return AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1)
        }
    }

    private func releaseLease() async {
        let lease = state.withLock { state in
            defer {
                state.lease = nil
                state.dropping = false
            }
            return state.lease
        }
        if let lease { await lease.session.release(lease.id) }
    }

    /// Opens the audio upload (`PUT path`), answering one authentication challenge (Basic only from a camera that never
    /// asked for Digest: `BasicDowngradeGuard`).
    private func openAudioData(path: String) async throws -> any TCPConnection {
        guard let port = UInt16(exactly: endpoint.httpPort) else { throw CameraAdapterError.invalidResponse("invalid HTTP port") }
        let hostKey = "http:\(endpoint.host.lowercased()):\(endpoint.httpPort)"
        var authorization: String?
        var digest = credentials.map { DigestAuthenticator(credentials: $0) }
        for attempt in 0..<2 {
            let connection = try await transport.connect(host: endpoint.host, port: port, timeout: .seconds(10))
            var head = "PUT \(path) HTTP/1.1\r\nHost: \(endpoint.urlHost):\(endpoint.httpPort)\r\n"
            head += "Content-Type: application/octet-stream\r\nContent-Length: 0\r\nConnection: keep-alive\r\n"
            if let authorization { head += "Authorization: \(authorization)\r\n" }
            head += "\r\n"
            do {
                try await connection.send(Data(head.utf8))
                let (status, headers) = try await Self.readResponseHead(connection)
                if status == 401, attempt == 0, let credentials, let challenge = headers["WWW-Authenticate"] {
                    connection.close()
                    if let parsed = DigestChallenge.parse(challenge), digest != nil {
                        downgradeGuard.digestRequested(by: hostKey)
                        authorization = digest?.authorization(for: parsed, method: "PUT", uri: path)
                    } else if challenge.lowercased().hasPrefix("basic"), downgradeGuard.mayAnswerBasic(from: hostKey, log: log) {
                        authorization = BasicAuth.header(credentials)
                    } else {
                        throw CameraAdapterError.unauthorized
                    }
                    continue
                }
                guard status != 401 else { throw CameraAdapterError.unauthorized }
                guard (200..<300).contains(status) else { throw CameraAdapterError.httpStatus(status) }
                return connection
            } catch {
                connection.close()
                throw error
            }
        }
        throw CameraAdapterError.unauthorized
    }

    /// Reads up to the end of the response head (any body bytes that follow are ignored).
    static func readResponseHead(_ connection: any TCPConnection) async throws -> (status: Int, headers: HTTPHeaders) {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.firstRange(of: terminator) == nil {
            guard buffer.count < 16 * 1024 else { throw CameraAdapterError.invalidResponse("response head too large") }
            let chunk = try await withTimeout(.seconds(10)) { try await connection.receive(maximumLength: 4096) }
            guard let chunk, !chunk.isEmpty else { throw TransportError.closed }
            buffer.append(chunk)
        }
        guard let end = buffer.firstRange(of: terminator)?.lowerBound else { throw CameraAdapterError.invalidResponse("no response head") }
        let lines = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self).components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else {
            throw CameraAdapterError.invalidResponse("bad status line")
        }
        var headers = HTTPHeaders()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.add(String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return (status, headers)
    }
}
