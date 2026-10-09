// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// Connection handling, event coalescing and advertisement updates follow HAP-NodeJS HAPServer.ts,
// util/eventedhttp.ts, Accessory.ts (publish, enqueueConfigurationUpdate) and Advertiser.ts (TXT record).

import BridgeSupport
import Foundation
import HAPCore

public struct AccessoryServerConfiguration: Sendable {
    /// 0 = ephemeral.
    public var port: UInt16
    /// false in some tests.
    public var advertise: Bool
    /// Bonjour instance name.
    public var serviceName: String
    /// Tests: bind 127.0.0.1.
    public var loopbackOnly: Bool

    public init(port: UInt16 = 0, advertise: Bool = true, serviceName: String, loopbackOnly: Bool = false) {
        self.port = port
        self.advertise = advertise
        self.serviceName = serviceName
        self.loopbackOnly = loopbackOnly
    }
}

public enum AccessoryServerEvent: Sendable, Equatable {
    case listening(port: UInt16)
    case advertising
    case advertisingFailed(message: String, localNetworkDenied: Bool)
    case paired(controllerID: String)
    case unpaired
    case sessionsChanged(count: Int)
}

/// HAP accessory server: TCP listener (injected `NetworkTransport`), HTTP/1.1, pair-setup/verify, encrypted sessions,
/// `/accessories`, `/characteristics`, `/prepare`, `/pairings`, `/resource`, events and `_hap._tcp` advertising
/// (injected `ServiceAdvertiser`). Persistent identity, pairings, identifiers and `c#` live in the `HAPStore`.
public actor AccessoryServer {
    /// Category "hap"; tagged with the camera's ID when the owner passes one (`init(…, log:)`), so the camera's own log
    /// shows its pairing, session and listener lines.
    nonisolated let log: Log

    let accessory: Accessory
    let configuration: AccessoryServerConfiguration
    let persistentStore: any HAPStore
    let transport: any NetworkTransport
    let advertiser: any ServiceAdvertiser
    private let broadcaster = AsyncBroadcaster<AccessoryServerEvent>()

    var timings = HAPServerTimings()
    private var identity: HAPIdentity?
    private(set) var longTermKey: HAPLongTermKey?
    var state: HAPPersistentState?
    private var running = false
    private var listener: (any TCPListener)?
    private var acceptTask: Task<Void, Never>?
    /// Listens again after the listener failed while running.
    private var relistenTask: Task<Void, Never>?
    /// The port the listener last had (`relistenNow` asks for it again: controllers know it).
    private var lastListeningPort: UInt16 = 0
    private var signalTask: Task<Void, Never>?
    private(set) var publication: Publication?
    var connections: [UUID: HAPConnection] = [:]
    private var advertisedService: (any AdvertisedService)?
    private var failureTask: Task<Void, Never>?
    /// Advertises again after a failure other than Local Network denial.
    private var advertisingRetryTask: Task<Void, Never>?
    private var advertisementTask: Task<Void, Never>?
    private var publishedTXT: [String: String]?
    private var configurationTask: Task<Void, Never>?
    /// Unsuccessful pair-setup proofs since launch; above 100, pair-setup answers MaxTries (HAP-NodeJS).
    private(set) var failedPairSetupAttempts = 0
    /// The one connection allowed to run pair-setup right now (others get Busy).
    var pairSetupOwner: PairSetupOwner?
    var lastAccessoriesRead: ContinuousClock.Instant?
    /// Rate limit for warnings unauthenticated peers can trigger (`warnUnauthenticated`).
    var unauthenticatedWarnings = UnauthenticatedWarningLimiter()

    /// Responses/events queued for a connection that stopped reading; beyond this the connection is closed.
    private static let maximumQueuedWrites = 512

    public init(accessory: Accessory, configuration: AccessoryServerConfiguration, store: any HAPStore,
                transport: any NetworkTransport, advertiser: any ServiceAdvertiser) {
        self.init(accessory: accessory, configuration: configuration, store: store, transport: transport, advertiser: advertiser,
                  log: Log(category: "hap"))
    }

    /// `log`: the server's logger, e.g. `Log(category: "hap", cameraID:)` for a camera's accessory.
    public init(accessory: Accessory, configuration: AccessoryServerConfiguration, store: any HAPStore,
                transport: any NetworkTransport, advertiser: any ServiceAdvertiser, log: Log) {
        self.accessory = accessory
        self.configuration = configuration
        self.persistentStore = store
        self.transport = transport
        self.advertiser = advertiser
        self.log = log
    }

    /// Safety net for a server released without `stop()` (open connections keep it alive, so none remain here).
    deinit {
        acceptTask?.cancel()
        relistenTask?.cancel()
        signalTask?.cancel()
        advertisementTask?.cancel()
        configurationTask?.cancel()
        failureTask?.cancel()
        advertisingRetryTask?.cancel()
        listener?.close()
        advertisedService?.cancel()
        publication?.unbind()
    }

    // MARK: - Public API

    /// Loads (or creates) the identity and state, assigns identifiers, updates `c#`, listens and advertises.
    public func start() async throws {
        guard !running else { return }
        let identity = try loadIdentity()
        var state = try loadState()
        let (stream, continuation) = AsyncStream.makeStream(of: PublicationSignal.self)
        let publication = Publication(root: accessory, state: state, signals: continuation)
        publication.assignIDs()
        state = publication.persistentIdentifiers(into: state)
        let storedHash = state.configHash
        let hash = publication.configurationHash()
        if ConfigurationNumber.apply(hash: hash, to: &state) {
            log.info("Configuration of \(accessory.info.name) changed (\(ConfigurationNumber.cause(from: storedHash, to: hash))); "
                     + "c# is now \(state.configNumber)")
        }
        self.state = state
        try persistentStore.saveState(state)

        running = true
        let listener: any TCPListener
        do {
            listener = try await transport.listen(port: configuration.port, loopbackOnly: configuration.loopbackOnly)
        } catch {
            running = false
            publication.unbind()
            throw error
        }
        guard running else {   // stop() was called while listening
            listener.close()
            publication.unbind()
            return
        }
        self.listener = listener
        lastListeningPort = listener.port
        self.publication = publication
        log.info("HAP server for \(accessory.info.name) listening on port \(listener.port) (\(identity.deviceID))")
        broadcaster.yield(.listening(port: listener.port))

        signalTask = Task { [weak self] in
            for await signal in stream {
                guard let self else { return }
                await self.handle(signal)
            }
        }
        acceptTask = makeAcceptTask(for: listener)
        if configuration.advertise { await startAdvertising() }
    }

    /// Stops listening, closes every connection and withdraws the advertisement. `start()` may be called again.
    public func stop() async {
        guard running else { return }
        running = false
        acceptTask?.cancel()
        acceptTask = nil
        relistenTask?.cancel()
        relistenTask = nil
        listener?.close()
        listener = nil
        for connection in Array(connections.values) { closeConnection(connection, graceful: false) }
        advertisementTask?.cancel()
        advertisementTask = nil
        configurationTask?.cancel()
        configurationTask = nil
        stopAdvertising()
        signalTask?.cancel()
        signalTask = nil
        if let publication, let current = state {
            state = publication.persistentIdentifiers(into: current)
            persist()
            publication.unbind()
        }
        publication = nil
    }

    /// Multi-subscriber (AsyncBroadcaster).
    public nonisolated var events: AsyncStream<AccessoryServerEvent> { broadcaster.subscribe() }

    public var port: UInt16? { listener?.port }

    public var isPaired: Bool { !((try? loadState())?.pairings.isEmpty ?? true) }

    /// Pairings this server removed because the identity they belonged to was missing from the store (a reset or lost
    /// Keychain, a data directory restored without it; `HAPStore.loadOrCreateIdentity()`). Not 0: Home still lists the
    /// accessory under the lost identity, where it never answers again; it has to be removed there and added again with
    /// the new setup code (research brief §4, "Keys missing").
    public private(set) var pairingsLostWithIdentity = 0

    public var setupCode: SetupCode {
        get throws { try loadIdentity().setupCode }
    }

    public var setupURI: String {
        get throws {
            let identity = try loadIdentity()
            return SetupPayload.uri(code: identity.setupCode, setupID: identity.setupID, category: accessory.category)
        }
    }

    public var deviceID: DeviceID {
        get throws { try loadIdentity().deviceID }
    }

    /// Verified (pair-verify complete) connections.
    public var sessionCount: Int { connections.values.filter { $0.session != nil && !$0.isClosed }.count }

    /// Open connections, verified or not.
    var connectionCount: Int { connections.count }

    /// Clears pairings, sf=1, closes sessions, re-advertises.
    public func resetPairings() async throws {
        var state = try loadState()
        state.pairings = []
        self.state = state
        try persistentStore.saveState(state)
        failedPairSetupAttempts = 0
        for connection in Array(connections.values) where connection.session != nil { closeConnection(connection, graceful: false) }
        log.notice("Pairings of \(accessory.info.name) were reset")
        broadcaster.yield(.unpaired)
        scheduleAdvertisementUpdate()
    }

    /// Recompute config hash → bump c# if changed → re-advertise.
    public func configurationDidChange() async {
        checkConfiguration()
    }

    /// HAPPersistentState.extras
    public func store(extra data: Data?, forKey key: String) async throws {
        var state = try loadState()
        state.extras[key] = data
        self.state = state
        try persistentStore.saveState(state)
    }

    public func extra(forKey key: String) async -> Data? {
        (try? loadState())?.extras[key]
    }

    /// Withdraws and re-registers the Bonjour advertisement (e.g. after a network change or after Local Network access
    /// was granted). No-op when not running or `advertise` is false.
    public func restartAdvertising() async {
        guard running, configuration.advertise else { return }
        stopAdvertising()
        await startAdvertising()
    }

    /// The network changed or the Mac woke: a listener that is down listens again at once instead of waiting out its
    /// backoff (which doubles up to a minute while the network is away), and then advertises again. No-op while the
    /// listener runs (`restartListener` is for one that runs but does not answer) or the server is stopped.
    public func relistenNow() {
        guard running, listener == nil else { return }
        log.info("Listening again for \(accessory.info.name) now (the network changed)")
        startRelistening(previousPort: lastListeningPort)
    }

    /// Closes the listener and listens again at once, keeping the open connections. For a listener that runs but does not
    /// answer (`HAPHealthMonitor`'s loopback check); the advertisement is withdrawn and registered again with it.
    public func restartListener(because reason: String) {
        guard running else { return }
        guard let current = listener else {
            relistenNow()
            return
        }
        log.warning("Restarting the HAP listener of \(accessory.info.name): \(reason)")
        listenerStopped(current, firstAttemptAfter: timings.listenerRestartSettle)
    }

    /// Closes the verified connections that sent nothing for `limit` (default `HAPServerTimings.staleConnectionLimit`),
    /// returning how many. After a sleep the Mac cannot tell which of its connections the controllers still hold: a
    /// connection that is silent since before the sleep is closed, and the controller (whose own end is gone or will be
    /// reset) connects and verifies again, which is cheap. Closing ends what rode on the connection: its HDS connection and
    /// the stream session that was prepared on it.
    @discardableResult
    public func dropStaleConnections(inactiveFor limit: Duration? = nil) -> Int {
        let limit = limit ?? timings.staleConnectionLimit
        let now = ContinuousClock.now
        var closed = 0
        for connection in Array(connections.values) where connection.session != nil && !connection.isClosed && now - connection.lastInbound > limit {
            log.info("Closing the HAP connection from \(connection.transport.remoteAddress) to \(accessory.info.name): nothing received for "
                     + "\(now - connection.lastInbound) (the Mac slept or the controller is gone)")
            closeConnection(connection, graceful: false)
            closed += 1
        }
        return closed
    }

    /// The `_hap._tcp` TXT record this server registered (`id`, `c#`, `sf`, …), nil while it is not advertised.
    public var advertisedTXT: [String: String]? { advertisedService == nil ? nil : publishedTXT }

    /// The Bonjour instance name of the advertisement.
    public var advertisedName: String { configuration.serviceName }

    public enum ListenerProbe: Sendable, Equatable {
        /// An unauthenticated request got HAP's refusal within the limit.
        case answered
        case notListening
        /// Connecting, sending or reading failed, or nothing came back in time.
        case failed(String)
    }

    /// Asks the listener a question as a controller would, over loopback: an unauthenticated `GET /accessories` must be
    /// refused (470) within `timeout`. A listener that accepts but never answers (a wedged accept loop, an actor that is
    /// not scheduled) shows here, which the controllers see only as "No Response".
    public nonisolated func probeListener(timeout: Duration) async -> ListenerProbe {
        guard let port = await port else { return .notListening }
        do {
            let connection = try await transport.connect(host: "127.0.0.1", port: port, timeout: timeout)
            defer { connection.close() }
            let reply: Data? = try await withDeadline(timeout) {
                try await connection.send(Data("GET /accessories HTTP/1.1\r\nHost: self-check\r\n\r\n".utf8))
                return try await connection.receive(maximumLength: 512)
            }
            guard let reply, String(decoding: reply.prefix(12), as: UTF8.self) == "HTTP/1.1 470" else {
                return .failed("an unauthenticated request was not refused as HAP does")
            }
            return .answered
        } catch is DeadlineExceeded {
            return .failed("no answer within \(timeout)")
        } catch {
            return .failed("\(error)")
        }
    }

    // MARK: - Test hooks

    func setTimings(_ timings: HAPServerTimings) {
        self.timings = timings
    }

    func setFailedPairSetupAttempts(_ count: Int) {
        failedPairSetupAttempts = count
    }

    func recordFailedPairSetupAttempt() {
        failedPairSetupAttempts += 1
    }

    /// Tests: records an admin pairing as pair-setup M5 would (same persistence, event and TXT update), so tests that
    /// only need a verified session can skip the 3072-bit SRP exchange.
    func addPairingForTesting(controllerID: String, publicKey: Data) {
        if state == nil { _ = try? loadState() }
        addAdminPairing(controllerID: controllerID, publicKey: publicKey)
    }

    // MARK: - Identity and state

    func loadIdentity() throws -> HAPIdentity {
        if let identity { return identity }
        let (loaded, created, discarded) = try persistentStore.loadOrCreateIdentity()
        longTermKey = try HAPLongTermKey(rawRepresentation: loaded.longTermKey)
        identity = loaded
        if created { log.info("Created a new HAP identity for \(accessory.info.name)") }
        if discarded > 0 { pairingsOfLostIdentityRemoved(discarded) }
        return loaded
    }

    /// The store held pairings without their identity, and `loadOrCreateIdentity()` removed them: they belonged to an
    /// identity no controller can reach any more. Reported as an unpair (controllers' state such as the camera's
    /// recording settings is reset, the app offers the setup code again), with a log line telling the user what to do.
    private func pairingsOfLostIdentityRemoved(_ count: Int) {
        state?.pairings = []   // a copy loaded before the identity
        pairingsLostWithIdentity += count
        let name = accessory.info.name
        let pairings = count == 1 ? "1 pairing with the old one was" : "\(count) pairings with the old one were"
        log.error("The HomeKit identity of \(name) was missing (its Keychain item was lost or reset), so it got a new one and its "
                       + "\(pairings) removed. Remove \(name) from the Home app and add it again with its setup code.")
        broadcaster.yield(.unpaired)
    }

    func loadState() throws -> HAPPersistentState {
        if let state { return state }
        let loaded = try persistentStore.loadState() ?? HAPPersistentState()
        state = loaded
        return loaded
    }

    /// Saves `state`, logging a failure: for identifiers and `c#`, which stay in memory and reach the disk with the next
    /// save that works. Pairing changes go through `savePairingChange` instead.
    func persist() {
        guard let state else { return }
        do {
            try persistentStore.saveState(state)
        } catch {
            log.error("Could not save HAP state for \(accessory.info.name): \(error)")
        }
    }

    /// Makes `updated` (a pairing change: pair-setup M5, Add or Remove Pairing) the state once the store has saved it.
    /// false: not saved (logged), and the state in memory is left as it was, so the request is refused rather than
    /// answered with a change a relaunch would undo (HAP-NodeJS saves before it answers).
    func savePairingChange(_ updated: HAPPersistentState) -> Bool {
        do {
            try persistentStore.saveState(updated)
        } catch {
            log.error("Could not save the pairings of \(accessory.info.name), so the pairing change was refused: \(error)")
            return false
        }
        state = updated
        return true
    }

    var pairings: [Pairing] { state?.pairings ?? [] }

    // MARK: - Listener

    private func makeAcceptTask(for listener: any TCPListener) -> Task<Void, Never> {
        Task { [weak self] in
            for await connection in listener.connections {
                guard let self else {
                    connection.close()
                    return
                }
                await self.accept(connection)
            }
            guard !Task.isCancelled else { return }
            await self?.listenerStopped(listener)
        }
    }

    /// The listener's connection stream ended although `stop()` was not called: the listener failed (interface change,
    /// sleep/wake, Local Network access revoked). Withdraws the now unreachable advertisement, reports it and listens
    /// again with backoff; verified sessions stay open.
    private func listenerStopped(_ failed: any TCPListener, firstAttemptAfter settle: Duration = .zero) {
        guard running, let current = listener, current === failed else { return }
        let port = failed.port
        failed.close()
        listener = nil
        acceptTask = nil
        stopAdvertising()
        log.error("HAP listener of \(accessory.info.name) on port \(port) stopped; listening again")
        broadcaster.yield(.advertisingFailed(message: "The HAP listener stopped; restarting it", localNetworkDenied: false))
        startRelistening(previousPort: port, firstAttemptAfter: settle)
    }

    /// Listens again: the first attempt at once (after `settle`, for a listener this server closed itself), then every `listenerRetryDelay`, doubling up to the maximum, until it works
    /// or the server stops. A running retry is replaced (its backoff starts over).
    private func startRelistening(previousPort port: UInt16, firstAttemptAfter settle: Duration = .zero) {
        relistenTask?.cancel()
        let (initialDelay, maximumDelay) = (timings.listenerRetryDelay, timings.listenerRetryMaximumDelay)
        // Holds the server only weakly between attempts (a server dropped without stop() is not kept alive).
        relistenTask = Task { [weak self] in
            var progress = RelistenProgress()
            var delay = initialDelay
            if settle > .zero {
                do {
                    try await Task.sleep(for: settle)
                } catch {
                    return
                }
            }
            while !Task.isCancelled {
                guard let next = await self?.relistenAttempt(previousPort: port, progress: progress) else { return }
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
        /// Last restart failure reported as an event (each distinct one is reported once).
        var lastReported: String?
    }

    /// One attempt to listen again; nil = finished (listening again, or the server stopped). Uses the configured port,
    /// or else the previous one (controllers know it) until it was refused as in use three times, then any free port.
    /// On success accepts, reports `.listening` and advertises again.
    private func relistenAttempt(previousPort: UInt16, progress: RelistenProgress) async -> RelistenProgress? {
        guard running, !Task.isCancelled else { return nil }
        var progress = progress
        let port = configuration.port != 0 ? configuration.port : (progress.portInUse < 3 ? previousPort : 0)
        do {
            let listener = try await transport.listen(port: port, loopbackOnly: configuration.loopbackOnly)
            guard running, !Task.isCancelled else {
                listener.close()
                return nil
            }
            self.listener = listener
            lastListeningPort = listener.port
            relistenTask = nil
            acceptTask = makeAcceptTask(for: listener)
            log.info("HAP server for \(accessory.info.name) listening again on port \(listener.port)")
            broadcaster.yield(.listening(port: listener.port))
            if configuration.advertise { await startAdvertising() }
            return nil
        } catch {
            if (error as? TransportError) == .addressInUse { progress.portInUse += 1 }
            let denied = (error as? TransportError) == .localNetworkDenied
            let message = denied ? "Local Network access was denied" : "The HAP listener could not restart: \(error)"
            if message != progress.lastReported {
                progress.lastReported = message
                log.error("\(accessory.info.name): \(message)")
                broadcaster.yield(.advertisingFailed(message: message, localNetworkDenied: denied))
            }
            return progress
        }
    }

    // MARK: - Connections

    private func accept(_ transportConnection: any TCPConnection) {
        guard running else {
            transportConnection.close()
            return
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(Self.maximumQueuedWrites))
        let connection = HAPConnection(transport: transportConnection, outbound: continuation)
        connections[connection.id] = connection
        let (log, name, stall) = (self.log, accessory.info.name, timings.sendStallTimeout)
        Task { await Self.writeLoop(stream, to: transportConnection, stallTimeout: stall, log: log, accessoryName: name) }
        Task { [weak self] in await self?.readLoop(transportConnection) }
        startIdleWatchdog(connection)
        limitUnverifiedConnections(keeping: connection)
        pruneIdleConnections()
    }

    /// Closes `connection` once it has been unverified and without traffic for `unverifiedIdleTimeout`.
    private func startIdleWatchdog(_ connection: HAPConnection) {
        let id = connection.id
        let timeout = timings.unverifiedIdleTimeout
        connection.idleTask = Task { [weak self] in
            var delay = timeout
            while true {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let next = await self?.checkUnverifiedIdle(id, timeout: timeout) else { return }
                delay = next
            }
        }
    }

    /// nil = nothing left to watch; otherwise how long to wait before checking again. The connection running pair-setup
    /// gets `pairSetupIdleTimeout` instead while it holds the slot: between M2 and M3 the user may still be typing the
    /// setup code shown in the app (HAP-NodeJS has no idle limit for unverified connections at all).
    private func checkUnverifiedIdle(_ id: UUID, timeout: Duration) -> Duration? {
        guard let connection = connections[id], !connection.isClosed, !connection.isVerified else { return nil }
        let idle = ContinuousClock.now - connection.lastActivity
        let runsPairSetup = connection.pairSetup != nil && pairSetupOwner?.connectionID == id
        let limit = runsPairSetup ? max(timeout, timings.pairSetupIdleTimeout) : timeout
        // Checked at least every `timeout`, so a connection that loses the pair-setup slot is not kept much longer.
        if idle < limit || connection.handlingRequest { return max(min(limit - idle, timeout), .milliseconds(10)) }
        let remoteAddress = connection.transport.remoteAddress
        noteUnauthenticated("idle", from: remoteAddress,
                            "Closing unverified HAP connection to \(accessory.info.name) from \(remoteAddress) idle for \(idle)")
        closeConnection(connection, graceful: false)
        return nil
    }

    /// Keeps at most `maximumUnverifiedConnections` unverified connections by closing the least recently active ones
    /// (never `newest` or the connection running pair-setup).
    private func limitUnverifiedConnections(keeping newest: HAPConnection) {
        let unverified = connections.values.filter { !$0.isClosed && !$0.isVerified }
        let excess = unverified.count - timings.maximumUnverifiedConnections
        guard excess > 0 else { return }
        let candidates = unverified.filter { $0 !== newest && $0.id != pairSetupOwner?.connectionID }.sorted { $0.lastActivity < $1.lastActivity }
        for connection in candidates.prefix(excess) {
            // Once per minute whatever the address: every connect beyond the cap gets here.
            noteUnauthenticated("unverified-cap", from: nil, "Closing unverified HAP connection to \(accessory.info.name) from "
                                + "\(connection.transport.remoteAddress): too many unverified connections")
            closeConnection(connection, graceful: false)
        }
    }

    /// Sends queued chunks in order; closes the transport when the queue finishes (graceful close), a send fails, or one
    /// send makes no progress for `stallTimeout` (the controller is gone without a FIN or RST: `sendWatchingProgress`).
    private static func writeLoop(_ stream: AsyncStream<Data>, to transport: any TCPConnection, stallTimeout: Duration, log: Log,
                                  accessoryName: String) async {
        for await chunk in stream {
            do {
                try await sendWatchingProgress(chunk, on: transport, limit: stallTimeout) {
                    log.warning("Closing HAP connection to \(accessoryName) from \(transport.remoteAddress): the controller accepted no data for \(stallTimeout)")
                }
            } catch {
                break
            }
        }
        transport.close()
    }

    private nonisolated func readLoop(_ transport: any TCPConnection) async {
        while true {
            let data: Data?
            do {
                data = try await transport.receive(maximumLength: 65_536)
            } catch {
                data = nil
            }
            guard let data else { break }
            guard await handleIncoming(data, connectionID: transport.id) else { break }
        }
        await connectionEnded(transport.id)
    }

    private func connectionEnded(_ id: UUID) {
        if let connection = connections[id] { closeConnection(connection, graceful: false) }
    }

    /// Once `connectionPruneThreshold` connections are open, closes those without traffic for `maximumIdleTime`
    /// (HAP-NodeJS), verified or not.
    private func pruneIdleConnections() {
        guard connections.count >= timings.connectionPruneThreshold else { return }
        let now = ContinuousClock.now
        for connection in Array(connections.values) where now - connection.lastActivity > timings.maximumIdleTime {
            log.info("Closing HAP connection idle since \(now - connection.lastActivity)")
            closeConnection(connection, graceful: false)
        }
    }

    /// Closes a connection. `graceful`: queued responses are written first.
    func closeConnection(_ connection: HAPConnection, graceful: Bool) {
        guard !connection.isClosed else { return }
        connection.isClosed = true
        connection.idleTask?.cancel()
        connection.idleTask = nil
        if pairSetupOwner?.connectionID == connection.id { pairSetupOwner = nil }
        connection.eventTimer?.cancel()
        connection.eventTimer = nil
        connection.pendingEvents.removeAll()
        connection.subscriptions.removeAll()
        connection.pairSetup = nil
        connection.pairVerify = nil
        connection.pendingSession = nil
        connection.outbound.finish()
        let transport = connection.transport
        if graceful {
            // The writer closes the transport after the queued bytes; force it if the peer stopped reading.
            Task {
                try? await Task.sleep(for: .seconds(2))
                transport.close()
            }
        } else {
            transport.close()
        }
        connections.removeValue(forKey: connection.id)
        if let session = connection.session {
            session.markClosed()
            broadcaster.yield(.sessionsChanged(count: sessionCount))
        }
    }

    /// Handles bytes from a connection. Returns false when the connection is finished.
    ///
    /// Input is consumed one unit at a time (a whole request before pair-verify, a frame afterwards) so that the
    /// session keys can switch exactly after pair-verify M4: bytes the controller sent behind M3 are decrypted with
    /// the new keys instead of being parsed as plaintext.
    private func handleIncoming(_ data: Data, connectionID: UUID) async -> Bool {
        guard let connection = connections[connectionID], !connection.isClosed else { return false }
        connection.lastActivity = .now
        connection.lastInbound = .now
        if connection.decryptor != nil {
            connection.decryptor?.append(data)
        } else {
            connection.plaintextBuffer.append(data)
        }
        while !connection.isClosed {
            let wasPlaintext = connection.decryptor == nil
            let requests: [(head: HTTPRequestHead, body: Data)]
            do {
                guard let input = try connection.nextInput() else { return true }
                requests = try connection.parser.feed(input)
                // Before pair-verify each input is exactly one request.
                if wasPlaintext && requests.count != 1 { throw HTTPParseError.malformedRequestLine }
            } catch {
                let remoteAddress = connection.transport.remoteAddress
                let message = "Closing HAP connection from \(remoteAddress): malformed input (\(error))"
                if connection.session == nil {
                    warnUnauthenticated("input", from: remoteAddress, message)
                } else {
                    log.warning(message)
                }
                closeConnection(connection, graceful: false)
                return false
            }
            let generation = connection.keyGeneration
            for (head, body) in requests {
                guard !connection.isClosed else { return false }
                guard connection.keyGeneration == generation else {
                    // Plaintext of the replaced session that followed pair-verify M3 inside the same frame.
                    log.warning("Ignoring a request sent behind pair-verify M3 under the previous session keys")
                    break
                }
                connection.handlingRequest = true
                let response = await route(head, body: body, connection: connection)
                guard !connection.isClosed else { return false }
                write(response.serialized(), to: connection)
                // The write closes a connection whose queue overflowed: a pair-verify M4 it carried starts no session.
                guard !connection.isClosed else { return false }
                connection.handlingRequest = false
                if let pending = connection.pendingSession {
                    connection.pendingSession = nil
                    activate(pending, on: connection)
                }
                if connection.closeAfterResponse {
                    closeConnection(connection, graceful: true)
                    return false
                }
                // Events that became due while the request was in flight (HAP-NodeJS handleHttpServerResponse).
                if connection.eventTimer == nil || connection.immediateEventsQueued { flushEvents(connection) }
            }
        }
        return false
    }

    /// Encrypts (after pair-verify) and queues bytes for the connection's writer. A connection whose queue overflows
    /// (the controller stopped reading) is closed: dropping a frame would desynchronize the nonce counters anyway.
    func write(_ data: Data, to connection: HAPConnection) {
        guard !connection.isClosed else { return }
        var bytes = data
        if connection.encryptor != nil {
            do {
                bytes = try connection.encryptor?.seal(data) ?? Data()
            } catch {
                log.error("Could not encrypt a HAP frame: \(error)")
                closeConnection(connection, graceful: false)
                return
            }
        }
        connection.lastActivity = .now
        if case .dropped = connection.outbound.yield(bytes) {
            log.warning("Closing HAP connection from \(connection.transport.remoteAddress): the controller is not reading")
            closeConnection(connection, graceful: false)
        }
    }

    /// Turns on encryption after the (plaintext) pair-verify M4 response was queued.
    private func activate(_ pending: HAPConnection.PendingSession, on connection: HAPConnection) {
        // A repeated pair-verify on a verified connection replaces its session: the old one ends here.
        let previous = connection.session
        previous?.markClosed()
        // Whatever the controller sent after M3 is already encrypted with the new keys.
        var decryptor = HAPFrameDecryptor(key: pending.readKey)
        decryptor.append(connection.decryptor?.takeBuffered() ?? connection.plaintextBuffer)
        connection.plaintextBuffer = Data()
        connection.decryptor = decryptor
        connection.encryptor = HAPFrameEncryptor(key: pending.writeKey)
        connection.parser = HTTPRequestParser()
        connection.keyGeneration += 1
        connection.idleTask?.cancel()
        connection.idleTask = nil
        if let previous, previous.controllerID != pending.session.controllerID {
            // Another controller must not inherit the previous one's subscriptions, queued events or timed write.
            connection.subscriptions.removeAll()
            connection.pendingEvents.removeAll()
            connection.immediateEventsQueued = false
            connection.eventTimer?.cancel()
            connection.eventTimer = nil
            connection.timedWrite = nil
        }
        connection.session = pending.session
        log.info("HAP session verified for controller \(Self.loggable(controllerID: pending.session.controllerID)) "
                      + "from \(pending.session.remoteAddress)")
        broadcaster.yield(.sessionsChanged(count: sessionCount))
    }

    // MARK: - Routing

    private func route(_ head: HTTPRequestHead, body: Data, connection: HAPConnection) async -> HAPResponse {
        let path = head.path.lowercased()
        switch (path, head.method) {
        case ("/pair-setup", "POST"): return await handlePairSetup(body, connection: connection)
        case ("/pair-verify", "POST"): return handlePairVerify(body, connection: connection)
        case ("/identify", "POST"): return handleIdentify(connection)
        case ("/pair-setup", _), ("/pair-verify", _), ("/identify", _): return .status(400, .invalidValue)
        default: break
        }
        guard let session = connection.session else { return .status(470, .insufficientPrivileges) }
        let context = HAPRequestContext(session: session)
        switch (path, head.method) {
        case ("/pairings", "POST"): return handlePairings(body, connection: connection, session: session)
        case ("/accessories", "GET"): return await handleAccessories(context: context)
        case ("/characteristics", "GET"): return await handleGetCharacteristics(head, connection: connection, context: context)
        case ("/characteristics", "PUT"): return await handlePutCharacteristics(body, connection: connection, context: context)
        case ("/prepare", "PUT"): return handlePrepare(body, connection: connection)
        case ("/resource", "POST"): return await handleResource(body, context: context)
        case ("/accessories", _), ("/characteristics", _), ("/prepare", _), ("/resource", _), ("/pairings", _): return .status(400, .invalidValue)
        default: return .status(404, .resourceDoesNotExist)
        }
    }

    /// Unpaired only, and before pair-verify: any LAN peer can send it (pipelined, thousands per second), so its log
    /// line is rate-limited like the other lines unauthenticated peers can cause (HAP-NodeJS logs it at debug level).
    private func handleIdentify(_ connection: HAPConnection) -> HAPResponse {
        if isPaired { return .status(400, .insufficientPrivileges) }
        let remoteAddress = connection.transport.remoteAddress
        noteUnauthenticated("identify", from: remoteAddress, "Identify requested for \(accessory.info.name) from \(remoteAddress)")
        accessory.identify()
        return .noContent
    }

    // MARK: - Events

    private func handle(_ signal: PublicationSignal) {
        switch signal {
        case .characteristicChanged(let characteristic, let value, let origin, let sequence):
            // Concurrent updates may report their changes out of order; an older value must not be the last event.
            // Every event of an event-only characteristic (a doorbell press) counts.
            guard characteristic.isEventOnly || characteristic.claimEventDispatch(sequence) else { return }
            dispatchEvent(characteristic, value: value, origin: origin)
        case .structureChanged:
            if let publication, publication.hasUnsavedIdentifiers, let current = state {
                state = publication.persistentIdentifiers(into: current)
                persist()
            }
            scheduleConfigurationCheck()
        }
    }

    private func dispatchEvent(_ characteristic: Characteristic, value: HAPValue, origin: UUID?) {
        let key = CharacteristicKey(aid: characteristic.aid, iid: characteristic.iid)
        guard key.aid > 0, key.iid > 0 else { return }
        let json = characteristic.jsonValue(value)
        let immediate = characteristic.deliversImmediately
        for connection in connections.values where !connection.isClosed && connection.subscriptions.contains(key) {
            guard let session = connection.session, session.id != origin else { continue }
            enqueueEvent(key, value: json, immediate: immediate, on: connection)
        }
    }

    private func enqueueEvent(_ key: CharacteristicKey, value: HAPJSON, immediate: Bool, on connection: HAPConnection) {
        if immediate {
            connection.pendingEvents.append((key, value))
            connection.immediateEventsQueued = true
            connection.eventTimer?.cancel()
            connection.eventTimer = nil
            flushEvents(connection)
            return
        }
        if let last = connection.pendingEvents.last(where: { $0.key == key }), last.value == value { return }
        connection.pendingEvents.append((key, value))
        if connection.eventTimer == nil {
            let id = connection.id
            let delay = timings.eventCoalescing
            connection.eventTimer = Task { [weak self] in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                await self?.eventTimerFired(id)
            }
        }
    }

    private func eventTimerFired(_ id: UUID) {
        guard let connection = connections[id] else { return }
        connection.eventTimer = nil
        flushEvents(connection)
    }

    /// Writes the queued events as one `EVENT/1.0` message (newest first), unless a request is in flight.
    private func flushEvents(_ connection: HAPConnection) {
        guard !connection.handlingRequest, !connection.isClosed, !connection.pendingEvents.isEmpty else { return }
        connection.eventTimer?.cancel()
        connection.eventTimer = nil
        let items = connection.pendingEvents.filter { connection.subscriptions.contains($0.key) }.reversed()
        connection.pendingEvents.removeAll()
        connection.immediateEventsQueued = false
        guard !items.isEmpty else { return }
        let body: HAPJSON = ["characteristics": .array(items.map {
            ["aid": .unsigned($0.key.aid), "iid": .unsigned($0.key.iid), "value": $0.value]
        })]
        let message = HTTPSerializer.response(status: 200, reason: "OK", headers: HTTPHeaders([("Content-Type", HAPResponse.hapJSON)]),
                                              body: body.serialized(), version: "EVENT/1.0")
        write(message, to: connection)
    }

    // MARK: - Configuration number

    private func scheduleConfigurationCheck() {
        guard configurationTask == nil else { return }
        let delay = timings.configurationDebounce
        configurationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.configurationTimerFired()
        }
    }

    private func configurationTimerFired() {
        configurationTask = nil
        checkConfiguration()
    }

    private func checkConfiguration() {
        guard let publication, var state else { return }
        state = publication.persistentIdentifiers(into: state)
        let storedHash = state.configHash
        let hash = publication.configurationHash()
        let changed = ConfigurationNumber.apply(hash: hash, to: &state)
        self.state = state
        persist()
        if changed {
            log.info("Configuration of \(accessory.info.name) changed (\(ConfigurationNumber.cause(from: storedHash, to: hash))); "
                     + "c# is now \(state.configNumber)")
            scheduleAdvertisementUpdate()
        }
    }

    // MARK: - Advertising

    /// `_hap._tcp` TXT record (research brief §3.3).
    private func txtRecord() -> [String: String]? {
        guard let identity, let state else { return nil }
        return [
            "c#": String(state.configNumber),
            "ff": "0",
            "id": identity.deviceID.description,
            "md": accessory.info.model,
            "pv": "1.1",
            "s#": "1",
            "sf": state.pairings.isEmpty ? "1" : "0",
            "ci": String(accessory.category.rawValue),
            "sh": SetupPayload.setupHash(setupID: identity.setupID, deviceID: identity.deviceID),
        ]
    }

    /// Registers the `_hap._tcp` advertisement; a failure is reported and, unless it is Local Network denial, retried
    /// (`advertisingFailed`).
    private func startAdvertising() async {
        if let error = await registerAdvertisement() { advertisingFailed(error) }
    }

    /// One registration attempt. nil = advertising, or nothing to do (stopped, no listener, already advertised);
    /// otherwise the error.
    private func registerAdvertisement() async -> (any Error)? {
        guard running, advertisedService == nil, let port = listener?.port, let txt = txtRecord() else { return nil }
        let advertisement = ServiceAdvertisement(name: configuration.serviceName, type: "_hap._tcp", port: port, txt: txt)
        let service: any AdvertisedService
        do {
            service = try await advertiser.advertise(advertisement)
        } catch {
            return error
        }
        // Stopped, advertised by another attempt, or the listener changed while registering.
        guard running, advertisedService == nil, listener?.port == port else {
            service.cancel()
            return nil
        }
        advertisedService = service
        publishedTXT = txt
        broadcaster.yield(.advertising)
        let failures = service.failures
        failureTask = Task { [weak self] in
            for await failure in failures {
                await self?.advertisingFailed(failure, of: service)
            }
        }
        // A change that happened while registering.
        if txtRecord() != txt { scheduleAdvertisementUpdate() }
        return nil
    }

    /// Withdraws the advertisement and ends any retry.
    private func stopAdvertising() {
        advertisingRetryTask?.cancel()
        advertisingRetryTask = nil
        failureTask?.cancel()
        failureTask = nil
        advertisedService?.cancel()
        advertisedService = nil
        publishedTXT = nil
    }

    private static func describeAdvertisingFailure(_ error: any Error) -> (message: String, denied: Bool) {
        let denied = (error as? TransportError) == .localNetworkDenied
        return (denied ? "Local Network access was denied" : "Bonjour advertising failed: \(error)", denied)
    }

    /// Reports an advertising failure: registering (`service` nil), or later on the registration `service` (DNS-SD
    /// failures, a failed TXT update). Local Network denial is left to the engine, which advertises again once access is
    /// granted (`restartAdvertising`). Anything else (mDNSResponder restarted and dropped the registration, the daemon
    /// unreachable at launch) withdraws what is left of the registration and advertises again with backoff.
    private func advertisingFailed(_ error: any Error, of service: (any AdvertisedService)? = nil) {
        // Late news from a registration already replaced, or a registration that failed while another one succeeded.
        if let service, service !== advertisedService { return }
        if service == nil, advertisedService != nil { return }
        let (message, denied) = Self.describeAdvertisingFailure(error)
        log.error("\(accessory.info.name): \(message)")
        broadcaster.yield(.advertisingFailed(message: message, localNetworkDenied: denied))
        guard !denied, running, configuration.advertise else { return }
        stopAdvertising()
        scheduleAdvertisingRetry(lastReported: message)
    }

    /// Advertises again after `advertisingRetryDelay`, doubling up to `advertisingRetryMaximumDelay`, until it works, is
    /// denied, or advertising is stopped or restarted (`stopAdvertising` cancels it). Holds the server only weakly between
    /// attempts (a server dropped without `stop()` is not kept alive).
    private func scheduleAdvertisingRetry(lastReported: String) {
        advertisingRetryTask?.cancel()
        let (initialDelay, maximumDelay) = (timings.advertisingRetryDelay, timings.advertisingRetryMaximumDelay)
        advertisingRetryTask = Task { [weak self] in
            var lastReported = lastReported
            var delay = initialDelay
            while true {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let failure = await self?.advertisingRetryAttempt(lastReported: lastReported) else { return }
                lastReported = failure
                delay = min(delay * 2, maximumDelay)
            }
        }
    }

    /// One retry. nil = finished (advertising again, denied, or no longer wanted); otherwise this attempt's failure,
    /// which is reported only when it differs from the last one reported.
    private func advertisingRetryAttempt(lastReported: String) async -> String? {
        guard running, !Task.isCancelled, advertisedService == nil, listener != nil else { return nil }
        guard let error = await registerAdvertisement() else {
            if !Task.isCancelled { advertisingRetryTask = nil }
            return nil
        }
        guard running, !Task.isCancelled, advertisedService == nil else { return nil }
        let (message, denied) = Self.describeAdvertisingFailure(error)
        if message != lastReported {
            log.error("\(accessory.info.name): \(message)")
            broadcaster.yield(.advertisingFailed(message: message, localNetworkDenied: denied))
        }
        if denied {
            advertisingRetryTask = nil
            return nil
        }
        return message
    }

    /// Debounced TXT refresh (pairing added/removed, `c#` changed).
    func scheduleAdvertisementUpdate() {
        guard advertisementTask == nil else { return }
        let delay = timings.advertisementDebounce
        advertisementTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.publishTXT()
        }
    }

    private func publishTXT() async {
        advertisementTask = nil
        guard let service = advertisedService, let txt = txtRecord(), txt != publishedTXT else { return }
        publishedTXT = txt
        do {
            try await service.updateTXT(txt)
        } catch {
            advertisingFailed(error, of: service)
        }
    }

    // MARK: - Pairing state

    func emit(_ event: AccessoryServerEvent) {
        broadcaster.yield(event)
    }
}
