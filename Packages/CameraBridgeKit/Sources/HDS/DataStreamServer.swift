// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// (Session preparation and trial-decrypt matching from lib/datastream/DataStreamServer.ts; research brief §3.8.)

import BridgeSupport
import Foundation
import HAP

/// Per-accessory HDS listener over the injected `NetworkTransport` (research brief §3.8).
///
/// - `prepareSession` (SetupDataStreamTransport) binds one TCP listener lazily on an ephemeral port, derives the
///   session keys from the HAP session's shared secret, and keeps the prepared session for 10 s.
/// - An incoming connection is matched by trial-decrypting its first frame with each prepared session's
///   controller→accessory key at counter 0; a match consumes the prepared session, anything else is closed. The first
///   frame must arrive within 10 s of the TCP accept, must be `control/hello`, and may carry at most
///   `maximumFirstPayloadLength` bytes; a connection that sends no byte at all within 2 s is closed earlier (a hub
///   sends its hello right after connecting). At most `maximumIdentifyingConnections` connections may await their
///   first frame at once; a newcomer beyond that closes the oldest of them (it is never refused itself, so silent
///   sockets cannot lock the hub out).
/// - When the HAP session closes, its prepared sessions are dropped and its HDS connections closed.
/// - The listener closes again once nothing is prepared, connecting or connected; the next session re-binds.
/// - `stop()`, or releasing the server without it, closes the listener and every connection. A connection the
///   transport hands over after its listener was closed is closed at once.
public actor DataStreamServer {
    typealias Handler = @Sendable (HDSMessage, DataStreamConnection) async -> Void

    /// Protocol timers (brief §3.8); shortened by tests.
    struct Timing: Sendable, Equatable {
        var sessionExpiry: Duration = .seconds(10)
        var helloTimeout: Duration = .seconds(10)
        /// A connection that has sent no byte at all by then is closed (ours, not HAP-NodeJS: Apple hubs send
        /// `control/hello` right after connecting, so only an idle socket holding a slot waits this long).
        var firstByteTimeout: Duration = .seconds(2)
        /// One send to a controller that makes no progress for this long closes its connection (a recording stalled on a
        /// hub that vanished without a FIN would otherwise hold the recording slot until the next busy open).
        var sendStallTimeout: Duration = .seconds(15)
    }

    /// Unauthenticated connections awaiting their first frame; a newcomer beyond this closes the oldest of them.
    static let maximumIdentifyingConnections = 8
    /// Upper bound for the first frame's payload, which must be a `control/hello` request (about 45 bytes with the
    /// usual empty message). A longer one is refused as soon as its frame header arrives, before it is buffered or
    /// trial-decrypted.
    static let maximumFirstPayloadLength = 1024

    private struct PreparedSession {
        let id: UUID
        let hapSessionID: UUID
        let accessoryToControllerKey: Data
        let controllerToAccessoryKey: Data
        let expiry: Task<Void, Never>
    }

    private struct Identification {
        let connection: any TCPConnection
        let task: Task<Void, Never>
        /// Accept order: the lowest is evicted first when the slots run out.
        let sequence: UInt64
    }

    /// A connection's first frame and the bytes that arrived after it.
    private typealias FirstFrame = (frame: HDSRawFrame, assembler: HDSFrameAssembler)

    private let transport: any NetworkTransport
    private let loopbackOnly: Bool
    let timing: Timing
    /// Category "HDS"; the owner's camera-tagged logger with `init(transport:loopbackOnly:log:)`. Its connections log
    /// with it too.
    private let log: Log
    /// Lines a peer that has not sent a valid hello can cause (evictions, unmatched first frames): at most once a minute.
    private var unauthenticatedLog = UnauthenticatedWarningLimiter()
    private var handlers: [String: Handler] = [:]
    private var listener: (any TCPListener)?
    private var listenerStart: Task<any TCPListener, any Error>?
    private var acceptTask: Task<Void, Never>?
    /// Bumped by `stop()`; a bind that started before it is discarded.
    private var generation = 0
    /// `prepareSession` calls in flight (the listener must not close under them).
    private var preparing = 0
    private var prepared: [PreparedSession] = []
    private var identifying: [UUID: Identification] = [:]
    private var acceptSequence: UInt64 = 0
    private var active: [UUID: DataStreamConnection] = [:]
    private var observedHAPSessions: Set<UUID> = []

    public init(transport: any NetworkTransport, loopbackOnly: Bool = false) {
        self.init(transport: transport, loopbackOnly: loopbackOnly, timing: Timing())
    }

    /// `log`: the logger for this server and its connections, e.g. `Log(category: "HDS", cameraID:)` so a camera's
    /// own log shows its HDS lines.
    public init(transport: any NetworkTransport, loopbackOnly: Bool = false, log: Log) {
        self.init(transport: transport, loopbackOnly: loopbackOnly, timing: Timing(), log: log)
    }

    init(transport: any NetworkTransport, loopbackOnly: Bool, timing: Timing, log: Log = Log(category: "HDS")) {
        self.transport = transport
        self.loopbackOnly = loopbackOnly
        self.timing = timing
        self.log = log
    }

    /// Released without `stop()` (e.g. on an owner's error path): release the port and every connection. Nothing here
    /// keeps the server alive (every task holds it weakly while it waits), so this runs as soon as the owner lets go.
    deinit {
        listenerStart?.cancel()
        listener?.close()
        acceptTask?.cancel()
        for session in prepared { session.expiry.cancel() }
        for identification in identifying.values {
            identification.connection.close()
            identification.task.cancel()
        }
        for connection in active.values {
            Task { await connection.close() }
        }
    }

    /// For SetupDataStreamTransport. Starts the listener lazily; session expires after 10 s if unused.
    /// Throws the transport's error if the listener cannot bind, or `HDSConnectionError.closed` if `stop()` interrupts.
    public func prepareSession(controllerKeySalt: Data, session: any HAPSessionHandle) async throws -> (port: UInt16, accessoryKeySalt: Data) {
        try await prepareSession(controllerKeySalt: controllerKeySalt, session: session, expiry: timing.sessionExpiry)
    }

    /// `prepareSession` with its own expiry (tests: one stale session next to live ones).
    func prepareSession(controllerKeySalt: Data, session: any HAPSessionHandle, expiry expiryDelay: Duration) async throws -> (port: UInt16, accessoryKeySalt: Data) {
        preparing += 1
        defer { preparing -= 1 }
        let startGeneration = generation
        let bound: any TCPListener
        do {
            bound = try await ensureListener()
        } catch {
            throw generation == startGeneration ? error : HDSConnectionError.closed
        }
        guard generation == startGeneration, let listener, listener === bound else { throw HDSConnectionError.closed }

        let accessoryKeySalt = Self.randomBytes(32)
        let keys = HDSFrameCodec.deriveKeys(sharedSecret: session.sharedSecret, controllerKeySalt: controllerKeySalt,
                                            accessoryKeySalt: accessoryKeySalt)
        let preparedID = UUID()
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: expiryDelay)
            guard !Task.isCancelled else { return }
            await self?.expire(preparedID)
        }
        prepared.append(PreparedSession(id: preparedID, hapSessionID: session.id, accessoryToControllerKey: keys.accessoryToController,
                                        controllerToAccessoryKey: keys.controllerToAccessory, expiry: expiry))
        observe(session)
        log.debug("HDS session prepared for HAP session \(session.id) on port \(listener.port)")
        return (listener.port, accessoryKeySalt)
    }

    /// Handles every request/event for `protocolName` on any connection (e.g. "dataSend"); replaces an earlier handler.
    /// "control/hello" is internal. Handlers run one message at a time per connection (see `DataStreamConnection`).
    public func setHandler(protocol protocolName: String, _ handler: @escaping @Sendable (HDSMessage, DataStreamConnection) async -> Void) {
        handlers[protocolName] = handler
    }

    /// Closes the listener, every connection and every prepared session. Handlers stay; a later `prepareSession`
    /// starts a new listener.
    public func stop() async {
        generation += 1
        listenerStart?.cancel()
        listenerStart = nil
        // From here on, `accepted` refuses whatever the old listener still delivers (even while this call is
        // suspended below), so nothing re-enters `identifying` for it.
        closeListener()
        for session in prepared { session.expiry.cancel() }
        prepared.removeAll()
        for identification in identifying.values {
            identification.connection.close()
            identification.task.cancel()
        }
        identifying.removeAll()
        let connections = Array(active.values)
        active.removeAll()
        for connection in connections { await connection.close() }
    }

    /// Open (identified) connections.
    public var connectionCount: Int {
        active.values.count(where: { !$0.isClosed })
    }

    // MARK: - Test hooks

    var preparedSessionCount: Int { prepared.count }
    var isListening: Bool { listener != nil }
    var identifyingCount: Int { identifying.count }
    var connections: [DataStreamConnection] { active.values.filter { !$0.isClosed } }

    // MARK: - Listener

    private func ensureListener() async throws -> any TCPListener {
        if let listener { return listener }
        if let listenerStart { return try await listenerStart.value }
        let startGeneration = generation
        // Runs on this actor (it captures `self`), so the listener is installed before any waiter resumes.
        let task = Task { () async throws -> any TCPListener in
            do {
                let bound = try await transport.listen(port: 0, loopbackOnly: loopbackOnly)
                return try install(bound, generation: startGeneration)
            } catch {
                bindFailed(generation: startGeneration)
                throw error
            }
        }
        listenerStart = task
        return try await task.value
    }

    private func install(_ bound: any TCPListener, generation startGeneration: Int) throws -> any TCPListener {
        guard generation == startGeneration else {
            bound.close()
            throw HDSConnectionError.closed
        }
        listenerStart = nil
        listener = bound
        log.info("HDS listener started on port \(bound.port)\(loopbackOnly ? " (loopback)" : "")")
        acceptTask = Task { [weak self] in
            for await connection in bound.connections {
                guard let self else {
                    connection.close()
                    return
                }
                await self.accepted(connection, from: bound)
            }
            await self?.listenerEnded(bound)
        }
        return bound
    }

    private func bindFailed(generation startGeneration: Int) {
        if generation == startGeneration { listenerStart = nil }
    }

    /// The transport stopped the listener on its own (e.g. it failed): forget it so the next session re-binds.
    private func listenerEnded(_ bound: any TCPListener) {
        guard let listener, listener === bound else { return }   // closed on purpose
        log.warning("HDS listener on port \(bound.port) stopped unexpectedly")
        self.listener = nil
        acceptTask = nil
    }

    private func closeListener() {
        guard let listener else { return }
        listener.close()
        self.listener = nil
        acceptTask?.cancel()
        acceptTask = nil
        log.debug("HDS listener closed")
    }

    /// Nothing prepared, connecting or connected: release the port (HAP-NodeJS `checkCloseable`).
    private func closeListenerIfIdle() {
        guard prepared.isEmpty, identifying.isEmpty, active.isEmpty, preparing == 0, listenerStart == nil else { return }
        closeListener()
    }

    // MARK: - Sessions

    private func expire(_ preparedID: UUID) {
        guard let index = prepared.firstIndex(where: { $0.id == preparedID }) else { return }
        log.debug("HDS session for HAP session \(prepared[index].hapSessionID) expired unused")
        prepared.remove(at: index)
        closeListenerIfIdle()
    }

    private func observe(_ session: any HAPSessionHandle) {
        let sessionID = session.id
        guard observedHAPSessions.insert(sessionID).inserted else { return }
        session.onClose { [weak self] in
            Task { await self?.hapSessionClosed(sessionID) }
        }
    }

    private func hapSessionClosed(_ sessionID: UUID) async {
        observedHAPSessions.remove(sessionID)
        for session in prepared where session.hapSessionID == sessionID { session.expiry.cancel() }
        prepared.removeAll { $0.hapSessionID == sessionID }
        let linked = active.values.filter { $0.hapSessionID == sessionID }
        if !linked.isEmpty { log.info("HAP session \(sessionID) closed; closing its HDS connection") }
        for connection in linked { await connection.close() }
        closeListenerIfIdle()
    }

    // MARK: - Connections

    private func accepted(_ connection: any TCPConnection, from bound: any TCPListener) {
        // Delivered by a listener that is no longer ours (stop(), idle close, restart): nothing would serve it.
        guard let listener, listener === bound else {
            connection.close()
            return
        }
        evictOldestIdentifying(toAdmit: connection)
        let timing = timing
        let task = Task { [weak self] in
            // Waits without holding the server, so releasing it is never delayed by a silent peer.
            let first = await Self.readFirstFrame(from: connection, timing: timing)
            guard let self else {
                connection.close()
                return
            }
            await self.identify(connection, first: first)
        }
        acceptSequence += 1
        identifying[connection.id] = Identification(connection: connection, task: task, sequence: acceptSequence)
    }

    /// Makes room for `newcomer` by closing the connection that has waited longest for its first frame
    /// (`AccessoryServer`'s cap on unverified HAP connections likewise keeps the newcomer). Refusing the newcomer
    /// instead would let a peer that keeps every slot busy lock the hub out without racing it; this way the hub's
    /// connection, which sends its hello at once, is only lost if every slot turns over before that hello arrives.
    private func evictOldestIdentifying(toAdmit newcomer: any TCPConnection) {
        while identifying.count >= Self.maximumIdentifyingConnections,
              let (id, oldest) = identifying.min(by: { $0.value.sequence < $1.value.sequence }) {
            identifying.removeValue(forKey: id)
            // Every connect beyond the cap gets here: at most once a minute, whatever the address.
            unauthenticatedLog.log("HDS connection from \(oldest.connection.remoteAddress) closed before its first frame to admit "
                                   + "\(newcomer.remoteAddress): \(Self.maximumIdentifyingConnections) connections already await theirs",
                                   kind: "evicted", from: nil, level: .notice, to: log)
            oldest.connection.close()
            oldest.task.cancel()
        }
    }

    /// The first frame (within `timing.helloTimeout`, at most `maximumFirstPayloadLength` bytes; the first byte within
    /// `timing.firstByteTimeout`) and whatever followed it; nil if the peer closed, timed out or sent something else.
    private static func readFirstFrame(from connection: any TCPConnection, timing: Timing) async -> FirstFrame? {
        let deadline = Task {
            try? await Task.sleep(for: timing.helloTimeout)
            if !Task.isCancelled { connection.close() }
        }
        var silenceDeadline: Task<Void, Never>? = Task {
            try? await Task.sleep(for: timing.firstByteTimeout)
            if !Task.isCancelled { connection.close() }
        }
        defer {
            deadline.cancel()
            silenceDeadline?.cancel()
        }
        var assembler = HDSFrameAssembler()
        do {
            while let chunk = try await connection.receive(maximumLength: DataStreamConnection.receiveChunkSize) {
                if !chunk.isEmpty {
                    silenceDeadline?.cancel()
                    silenceDeadline = nil
                }
                assembler.append(chunk)
                if let frame = try assembler.nextFrame(maximumPayloadLength: maximumFirstPayloadLength) {
                    return (frame, assembler)
                }
            }
        } catch {
            // Timed out, reset by the peer, first frame too long: the caller closes the connection.
        }
        return nil
    }

    /// Hands a first frame to `attach`; closes the connection if there is none or it matches no prepared session.
    private func identify(_ tcp: any TCPConnection, first: FirstFrame?) async {
        guard identifying.removeValue(forKey: tcp.id) != nil else {   // stop() got there first
            tcp.close()
            return
        }
        if let first, await attach(tcp, firstFrame: first.frame, assembler: first.assembler) { return }
        tcp.close()
        closeListenerIfIdle()
    }

    /// Links the connection to the prepared session whose key opens `firstFrame`; false if none does.
    private func attach(_ tcp: any TCPConnection, firstFrame: HDSRawFrame, assembler: HDSFrameAssembler) async -> Bool {
        for (index, candidate) in prepared.enumerated() {
            guard let payload = try? HDSFrameCodec.openFrame(header: firstFrame.header, body: firstFrame.body,
                                                             key: candidate.controllerToAccessoryKey, counter: 0) else { continue }
            prepared.remove(at: index)
            candidate.expiry.cancel()
            let connection = DataStreamConnection(hapSessionID: candidate.hapSessionID, tcp: tcp,
                                                  accessoryToControllerKey: candidate.accessoryToControllerKey,
                                                  controllerToAccessoryKey: candidate.controllerToAccessoryKey,
                                                  log: log, sendStallTimeout: timing.sendStallTimeout, dispatch: dispatcher())
            let connectionID = connection.id
            active[connectionID] = connection
            connection.onClose { [weak self] in
                Task { await self?.connectionClosed(connectionID) }
            }
            log.info("HDS connection \(connectionID) from \(tcp.remoteAddress) linked to HAP session \(candidate.hapSessionID)")
            await connection.start(firstPayload: payload, assembler: assembler)
            return true
        }
        unauthenticatedLog.log("HDS connection from \(tcp.remoteAddress) matched no prepared session; closing", kind: "unmatched",
                               from: tcp.remoteAddress, level: .notice, to: log)
        return false
    }

    private func connectionClosed(_ connectionID: UUID) {
        active.removeValue(forKey: connectionID)
        closeListenerIfIdle()
    }

    private func dispatcher() -> DataStreamConnection.Dispatch {
        { [weak self] message, connection in
            guard let handler = await self?.handler(for: message.protocolName) else { return false }
            await handler(message, connection)
            return true
        }
    }

    private func handler(for protocolName: String) -> Handler? {
        handlers[protocolName]
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
