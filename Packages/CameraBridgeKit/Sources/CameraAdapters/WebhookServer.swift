import BridgeSupport
import Foundation

/// Local HTTP webhook receiver over the injected `NetworkTransport`, so Frigate / Home Assistant / Scrypted
/// automations can drive camera events:
///
///     POST /cameras/<camera UUID>/<event>      Authorization: Bearer <token>
///
/// Events: `motion` (`motion/start`), `motion/stop`, `doorbell` (`ring`), `person|vehicle|animal|package|face`
/// (+ `/start`, `/stop`), `tamper`, `tamper/stop`. Answers 204 on success, 401 for a missing/wrong token (checked
/// first, constant time), 404 for an unknown path or event, 405 for other methods, 400 for malformed HTTP. Created with
/// a camera lookup (`init(…cameras:)`, as the engine does), it also answers 404 for a camera ID that names no configured
/// camera and 409 for a disabled camera, and publishes nothing for either (logged once per ID), so an automation with a
/// stale or mistyped ID learns that nothing happened.
///
/// - Keep-alive; at most 32 connections. Idle connections close after 30 s, a new connection must send its first
///   byte within 5 s, and a request must arrive completely within 10 s of its first byte (a client trickling bytes
///   cannot hold a connection slot).
/// - When the slots run out, the oldest connection that has not sent a request with the right token is closed to
///   admit the newcomer, so idle or unauthenticated sockets cannot lock Frigate / Home Assistant out; only when every
///   slot holds an authorized client is the newcomer refused.
/// - Concurrent `start()` calls bind once.
/// - A listener the platform stops on its own (interface change, sleep/wake, Local Network access revoked) is
///   replaced: the server listens again on the same port with backoff, keeping `events` and the open connections.
/// - `stop()` does not finish `events`, so the server can be started again; a server released without `stop()`
///   closes its listener and connections.
/// - `listenerStates` reports listening, every failed attempt to listen again (so the owner can say the webhook is not
///   reachable while it retries) and the stop.
public actor WebhookServer {
    /// What the listener does (`listenerStates`).
    public enum ListenerState: Sendable, Equatable {
        case listening(port: UInt16)
        /// The listener stopped on its own and listening again failed with this error; the server keeps trying.
        case relistenFailed(TransportError)
        case stopped
    }

    static let maximumConnections = 32
    static let idleTimeout: Duration = .seconds(30)
    static let requestTimeout: Duration = .seconds(10)
    static let maximumBody = 64 * 1024
    /// A request head may be at most this long (like HAP's plaintext requests) with at most `maximumHeaderLines` header
    /// lines: any LAN peer can send one before the token is checked, and an automation's head is a few hundred bytes.
    static let maximumHead = 8 * 1024
    static let maximumHeaderLines = 64

    /// Timers; shortened by tests.
    struct Timing: Sendable {
        /// A connection without traffic between requests closes after this long.
        var idleTimeout: Duration = WebhookServer.idleTimeout
        /// A request must arrive completely within this long of its first byte.
        var requestTimeout: Duration = WebhookServer.requestTimeout
        /// A new connection that has sent nothing by then closes (HTTP clients send their request right after
        /// connecting; only an idle socket holding a slot waits this long).
        var firstByteTimeout: Duration = .seconds(5)
        /// First wait between attempts to listen again after the listener stopped; doubles up to `relistenMaximumDelay`.
        var relistenDelay: Duration = .seconds(1)
        var relistenMaximumDelay: Duration = .seconds(30)
    }

    private struct Client {
        let connection: any TCPConnection
        let task: Task<Void, Never>
        /// Accept order: the oldest unauthorized connection is closed first when the slots run out.
        let sequence: UInt64
        /// Sent a request with the right token: keeps its slot when a newcomer arrives.
        var authorized = false
    }

    private let port: UInt16
    private let token: String
    private let loopbackOnly: Bool
    private let transport: any NetworkTransport
    private let timing: Timing
    /// nil: every camera ID is published (the contract initializer).
    private let cameras: (@Sendable (UUID) async -> CameraState)?
    /// The last refusal logged per camera ID (at most `maximumReportedCameras`), so each is logged once.
    private var reportedCameras: [UUID: CameraState] = [:]
    static let maximumReportedCameras = 64
    private let broadcaster = AsyncBroadcaster<(cameraID: UUID, event: CameraEvent)>(bufferingNewest: 256)
    private let stateBroadcaster = AsyncBroadcaster<ListenerState>(bufferingNewest: 16)
    private let log = Log(category: "webhook")
    private var listener: (any TCPListener)?
    private var acceptTask: Task<Void, Never>?
    private var connections: [UUID: Client] = [:]
    private var acceptSequence: UInt64 = 0
    /// The bind in progress; concurrent `start()` calls and relisten attempts await it instead of binding again.
    private var starting: Task<Void, any Error>?
    /// Listens again after the listener stopped on its own; nil while listening or stopped.
    private var relistenTask: Task<Void, Never>?
    /// Bumped by `stop()`: a bind that finishes after a stop closes its listener.
    private var generation = 0

    public init(port: UInt16, token: String, loopbackOnly: Bool = false, transport: any NetworkTransport) {
        self.init(port: port, token: token, loopbackOnly: loopbackOnly, transport: transport, timing: Timing())
    }

    /// What a camera ID in a webhook path names.
    public enum CameraState: Sendable, Equatable {
        /// A configured, enabled camera: the event is published (204).
        case enabled
        /// A configured camera that is turned off: 409, nothing is published.
        case disabled
        /// No configured camera (mistyped, or removed — a camera added again gets a new ID): 404, nothing is published.
        case unknown
    }

    /// As the contract initializer, with `cameras` answering what each camera ID in an authorized, well-formed event
    /// request names (asked once per request; logged once per ID and answer when it is not `.enabled`).
    public init(port: UInt16, token: String, loopbackOnly: Bool = false, transport: any NetworkTransport,
                cameras: @escaping @Sendable (UUID) async -> CameraState) {
        self.init(port: port, token: token, loopbackOnly: loopbackOnly, transport: transport, timing: Timing(), cameras: cameras)
    }

    init(port: UInt16, token: String, loopbackOnly: Bool = false, transport: any NetworkTransport, idleTimeout: Duration, requestTimeout: Duration) {
        var timing = Timing()
        timing.idleTimeout = idleTimeout
        timing.requestTimeout = requestTimeout
        self.init(port: port, token: token, loopbackOnly: loopbackOnly, transport: transport, timing: timing)
    }

    init(port: UInt16, token: String, loopbackOnly: Bool = false, transport: any NetworkTransport, timing: Timing,
         cameras: (@Sendable (UUID) async -> CameraState)? = nil) {
        self.port = port
        self.token = token
        self.loopbackOnly = loopbackOnly
        self.transport = transport
        self.timing = timing
        self.cameras = cameras
    }

    deinit {
        // Released without stop(): nothing else would ever close the listening socket.
        listener?.close()
        acceptTask?.cancel()
        relistenTask?.cancel()
        for entry in connections.values {
            entry.connection.close()
            entry.task.cancel()
        }
    }

    /// The listening port while started (the ephemeral port when started with 0); nil while the server is stopped or
    /// listening again after its listener stopped.
    public var boundPort: UInt16? { listener?.port }

    /// Tests: connections currently open.
    var connectionCount: Int { connections.count }

    public func start() async throws {
        try await bindOnce(port: port)
    }

    /// Binds unless already listening; joins a bind in progress.
    private func bindOnce(port: UInt16) async throws {
        if listener != nil { return }
        if let starting { return try await starting.value }
        let task = Task { try await self.bind(port: port) }
        starting = task
        defer { if starting == task { starting = nil } }
        try await task.value
    }

    private func bind(port: UInt16) async throws {
        let generation = generation
        let listener = try await transport.listen(port: port, loopbackOnly: loopbackOnly)
        guard generation == self.generation else {   // stop() ran while binding
            listener.close()
            return
        }
        self.listener = listener
        acceptTask = makeAcceptTask(for: listener)
        relistenTask?.cancel()   // listening (again): no further attempts
        relistenTask = nil
        log.info("webhook listening on port \(listener.port)\(loopbackOnly ? " (loopback)" : "")")
        stateBroadcaster.yield(.listening(port: listener.port))
    }

    /// Listening, failed attempts to listen again after the listener stopped on its own, and the stop (multi-subscriber).
    public nonisolated var listenerStates: AsyncStream<ListenerState> { stateBroadcaster.subscribe() }

    private func makeAcceptTask(for listener: any TCPListener) -> Task<Void, Never> {
        Task { [weak self] in
            for await connection in listener.connections {
                guard let self else {
                    connection.close()
                    continue
                }
                await self.accept(connection)
            }
            guard !Task.isCancelled else { return }   // stop() closed it
            await self?.listenerStopped(listener)
        }
    }

    /// The listener's connection stream ended although `stop()` was not called: the platform stopped it (interface
    /// change, sleep/wake, Local Network access revoked). Listens again on the same port with backoff, as
    /// `AccessoryServer` does; `events` subscribers and open connections are kept.
    private func listenerStopped(_ failed: any TCPListener) {
        guard let current = listener, current === failed else { return }
        let previousPort = failed.port
        failed.close()
        listener = nil
        acceptTask = nil
        log.error("webhook listener on port \(previousPort) stopped; listening again")
        relistenTask?.cancel()
        let (generation, initialDelay, maximumDelay) = (generation, timing.relistenDelay, timing.relistenMaximumDelay)
        // Holds the server only weakly between attempts (a server dropped without stop() is not kept alive).
        relistenTask = Task { [weak self] in
            var progress = RelistenProgress()
            var delay = initialDelay
            while !Task.isCancelled {
                guard let next = await self?.relistenAttempt(previousPort: previousPort, generation: generation, progress: progress) else {
                    return
                }
                progress = next
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                delay = min(delay * 2, maximumDelay)
            }
        }
    }

    private struct RelistenProgress: Sendable {
        /// Attempts refused with `.addressInUse`.
        var portInUse = 0
        /// Last failure logged (each distinct one is logged once).
        var lastReported: String?
    }

    /// One attempt to listen again; nil = finished (listening, or stopped). Uses the configured port, or else (port 0)
    /// the previous one until it was refused as in use three times, then any free port.
    private func relistenAttempt(previousPort: UInt16, generation: Int, progress: RelistenProgress) async -> RelistenProgress? {
        guard generation == self.generation, !Task.isCancelled, listener == nil else { return nil }
        var progress = progress
        let port = self.port != 0 ? self.port : (progress.portInUse < 3 ? previousPort : 0)
        do {
            try await bindOnce(port: port)
            return nil
        } catch {
            guard generation == self.generation, !Task.isCancelled, listener == nil else { return nil }
            if (error as? TransportError) == .addressInUse { progress.portInUse += 1 }
            let message = Redact.string(String(describing: error))
            if message != progress.lastReported {
                progress.lastReported = message
                log.error("webhook could not listen again on port \(port): \(message); retrying")
            }
            stateBroadcaster.yield(.relistenFailed(error as? TransportError ?? .failed(message)))
            return progress
        }
    }

    public func stop() async {
        generation += 1
        starting = nil
        stateBroadcaster.yield(.stopped)
        relistenTask?.cancel()
        relistenTask = nil
        listener?.close()
        listener = nil
        acceptTask?.cancel()
        acceptTask = nil
        let open = connections.values
        connections.removeAll()
        for entry in open {
            entry.connection.close()
            entry.task.cancel()
        }
    }

    /// POST /cameras/<uuid>/(motion|motion/stop|doorbell|person|...)
    public nonisolated var events: AsyncStream<(cameraID: UUID, event: CameraEvent)> { broadcaster.subscribe() }

    private func accept(_ connection: any TCPConnection) {
        guard listener != nil else {
            connection.close()
            return
        }
        guard makeRoom(toAdmit: connection) else {
            log.debug("webhook connection from \(connection.remoteAddress) refused: \(Self.maximumConnections) authorized connections are open")
            connection.close()
            return
        }
        let id = connection.id
        let (token, broadcaster, log, timing) = (token, broadcaster, log, timing)
        let task = Task { [weak self] in
            await Self.serve(connection, token: token, broadcaster: broadcaster, log: log, timing: timing) { [weak self] in
                await self?.authorized(id)
            } cameraState: { [weak self] cameraID in
                await self?.cameraState(cameraID) ?? .enabled
            }
            await self?.finished(id)
        }
        acceptSequence += 1
        connections[id] = Client(connection: connection, task: task, sequence: acceptSequence)
    }

    /// Frees a slot for `newcomer` by closing the oldest connections that have not sent an authorized request
    /// (`DataStreamServer` and `AccessoryServer` likewise keep the newcomer): refusing the newcomer instead would let
    /// any LAN peer hold every slot with idle sockets and lock the automations out. False when every slot is authorized.
    private func makeRoom(toAdmit newcomer: any TCPConnection) -> Bool {
        while connections.count >= Self.maximumConnections {
            guard let (id, oldest) = connections.filter({ !$0.value.authorized }).min(by: { $0.value.sequence < $1.value.sequence }) else {
                return false
            }
            connections.removeValue(forKey: id)
            log.debug("webhook connection from \(oldest.connection.remoteAddress) closed to admit \(newcomer.remoteAddress): \(Self.maximumConnections) connections are open")
            oldest.connection.close()
            oldest.task.cancel()
        }
        return true
    }

    private func authorized(_ id: UUID) {
        connections[id]?.authorized = true
    }

    private func finished(_ id: UUID) {
        connections[id] = nil
    }

    /// What `cameras` says about `id` (`.enabled` without a lookup). A refusal is logged once per ID and answer (for at
    /// most `maximumReportedCameras` IDs): the automation only sees the status, the person reads the log.
    private func cameraState(_ id: UUID) async -> CameraState {
        guard let cameras else { return .enabled }
        let state = await cameras(id)
        guard state != .enabled else {
            reportedCameras[id] = nil
            return state
        }
        let known = reportedCameras[id] != nil
        guard reportedCameras[id] != state, known || reportedCameras.count < Self.maximumReportedCameras else { return state }
        reportedCameras[id] = state
        let camera = id.uuidString.prefix(8)
        switch state {
        case .unknown:
            log.warning("webhook event for camera \(camera)… answered 404: no camera has this ID (check the automation's URL; "
                        + "a camera that was removed and added again has a new ID)")
        case .disabled:
            log.notice("webhook event for camera \(camera)… answered 409: the camera is turned off")
        case .enabled:
            break
        }
        return state
    }

    /// `onAuthorized` runs once, before the answer to the connection's first request with the right token. `cameraState`
    /// decides whether an authorized, well-formed event is published (204) or refused (404 unknown, 409 disabled).
    private static func serve(_ connection: any TCPConnection, token: String, broadcaster: AsyncBroadcaster<(cameraID: UUID, event: CameraEvent)>,
                              log: Log, timing: Timing, onAuthorized: @escaping @Sendable () async -> Void,
                              cameraState: @escaping @Sendable (UUID) async -> CameraState) async {
        defer { connection.close() }
        var parser = HTTPRequestParser(maxBodySize: maximumBody, maxHeadSize: maximumHead, maxHeaderCount: maximumHeaderLines)
        /// Set by the first byte of a request: the whole request must arrive by then.
        var requestDeadline: ContinuousClock.Instant?
        var receivedAny = false
        var authorized = false
        while !Task.isCancelled {
            var limit = receivedAny ? timing.idleTimeout : min(timing.idleTimeout, timing.firstByteTimeout)
            if let requestDeadline { limit = min(limit, requestDeadline - .now) }
            guard limit > .zero else {
                log.debug("webhook request not completed within \(Int(timing.requestTimeout.timeInterval)) s; closing")
                return
            }
            let data: Data?
            do {
                data = try await withTimeout(limit) { try await connection.receive(maximumLength: 16 * 1024) }
            } catch {
                return
            }
            guard let data else { return }
            if !data.isEmpty { receivedAny = true }
            if requestDeadline == nil { requestDeadline = .now + timing.requestTimeout }
            let requests: [(head: HTTPRequestHead, body: Data)]
            do {
                requests = try parser.feed(data)
                if !requests.isEmpty { requestDeadline = nil }
            } catch {
                let response = HTTPSerializer.response(status: 400, headers: HTTPHeaders([("Connection", "close")]), body: Data())
                try? await connection.send(response)
                return
            }
            for (head, _) in requests {
                var result = route(head, token: token)
                if result.status != 401, !authorized {   // the token matched: this client keeps its slot
                    authorized = true
                    await onAuthorized()
                }
                if let event = result.event {
                    switch await cameraState(event.cameraID) {
                    case .enabled:
                        broadcaster.yield(event)
                        log.info("webhook \(head.path.split(separator: "/").dropFirst(2).joined(separator: "/")) for \(event.cameraID.uuidString.prefix(8))")
                    case .disabled:
                        result = RouteResult(status: 409)
                    case .unknown:
                        result = RouteResult(status: 404)
                    }
                }
                var headers = HTTPHeaders(result.headers)
                let close = head.headers["Connection"]?.lowercased() == "close" || head.version == "HTTP/1.0"
                if close { headers.add("Connection", "close") }
                do { try await connection.send(HTTPSerializer.response(status: result.status, headers: headers, body: Data())) } catch { return }
                if close { return }
            }
            // A request whose body is still to come is refused as soon as its head shows a wrong token: its body is
            // never read (a peer without the token gets no more of the server's time than its head).
            if let pending = parser.pendingHead, !isAuthorized(pending.headers["Authorization"], token: token) {
                var headers = HTTPHeaders(route(pending, token: token).headers)
                headers.add("Connection", "close")
                try? await connection.send(HTTPSerializer.response(status: 401, headers: headers, body: Data()))
                return
            }
        }
    }

    struct RouteResult: Sendable {
        var status: Int
        var headers: [(String, String)] = []
        var event: (cameraID: UUID, event: CameraEvent)?
    }

    static func route(_ head: HTTPRequestHead, token: String) -> RouteResult {
        guard isAuthorized(head.headers["Authorization"], token: token) else {
            return RouteResult(status: 401, headers: [("WWW-Authenticate", #"Bearer realm="CameraBridge""#)])
        }
        let components = head.path.split(separator: "/").map(String.init)
        guard components.count >= 3, components[0] == "cameras", let cameraID = UUID(uuidString: components[1]),
              let event = event(named: components[2...].joined(separator: "/").lowercased()) else {
            return RouteResult(status: 404)
        }
        guard head.method == "POST" else { return RouteResult(status: 405, headers: [("Allow", "POST")]) }
        return RouteResult(status: 204, event: (cameraID, event))
    }

    static func event(named name: String) -> CameraEvent? {
        switch name {
        case "motion", "motion/start": return .motion(true)
        case "motion/stop": return .motion(false)
        case "doorbell", "ring": return .doorbellPressed
        case "tamper", "tamper/start": return .tamper(true)
        case "tamper/stop": return .tamper(false)
        default:
            let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
            guard let kind = DetectedObjectKind(rawValue: parts[0]) else { return nil }
            switch parts.count == 2 ? parts[1] : "start" {
            case "start": return .object(kind, true)
            case "stop": return .object(kind, false)
            default: return nil
            }
        }
    }

    /// `Bearer <token>` (scheme case-insensitive), compared in constant time; an empty configured token rejects all.
    static func isAuthorized(_ header: String?, token: String) -> Bool {
        guard !token.isEmpty, let header else { return false }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        let presented = Array(parts[1].trimmingCharacters(in: .whitespaces).utf8)
        let expected = Array(token.utf8)
        var difference = UInt8(truncatingIfNeeded: presented.count ^ expected.count)
        for i in 0..<expected.count {
            difference |= expected[i] ^ (i < presented.count ? presented[i] : 0)
        }
        return difference == 0 && presented.count == expected.count
    }
}
