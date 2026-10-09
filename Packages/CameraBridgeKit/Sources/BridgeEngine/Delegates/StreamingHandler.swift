import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import MediaCore
import RTP

/// The camera's `CameraStreamingDelegate` (plan W3-1 items 3–4).
///
/// - `prepareStream` binds two UDP sockets (loopback in tests; the requested address family), picks random SSRCs,
///   echoes the controller's SRTP keys (one key per stream for both directions; `LiveStreamSession` drops inbound
///   packets carrying our own SSRCs, so our packets reflected back are never taken for the controller's) and answers
///   with an address of the requested family on the HAP connection's interface (`StreamAddress`: the connection's own
///   address when it already has that family). The stream goes to the controller's SetupEndpoints address, unless that is
///   on none of our interface networks (an iPhone on a VPN advertises the tunnel's address) and the HAP connection's peer
///   address is: then to the peer (`StreamAddress.controllerRoute`; `LiveStreamSession` also latches onto the source of the
///   controller's first authenticated packet). A link-local controller address (SetupEndpoints text has no scope) gets
///   the HAP connection's zone (`StreamAddress.controllerHost`), or no packet would reach it.
/// - `.start` builds a `LiveStreamPipeline` on the main or the sub stream (`MediaFit.prefersSubStream`); `.reconfigure`
///   and `.stop` go to it. A `.stop` (or a cancellation: RTPStreamManagement abandons a start that misses its deadline)
///   while `.start` still waits for the hub wins: the start undoes what it built and fails. A session that ends by
///   itself (no controller RTCP for 30 s, source gone, socket error) is ended through
///   `CameraController.stopStreamingSession` so HAP reports the stream available again.
/// - Sending strategy per controller (`SendStrategy`): the sockets bind the accessory address and are scoped to its
///   interface (`IP_BOUND_IF`), else only bound, else the wildcard. A session that ends because the controller received none
///   of its video (`.controllerNotReceiving`) moves that controller to the next strategy for its next session; the choice
///   is remembered for an hour and forgotten on a network change (`networkChanged()`).
/// - Two-way audio: one `TalkbackBridge` per camera, shared by every session (cameras have one talkback channel).
/// - `snapshot` goes to the `SnapshotProvider` (not serialised with stream operations).
actor StreamingHandler: CameraStreamingDelegate {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownSession
        case stopped
        var description: String {
            switch self {
            case .unknownSession: "unknown or already started stream session"
            case .stopped: "the camera is stopping"
            }
        }
    }

    private enum Entry {
        case prepared(PreparedStream)
        /// `.start` waits for the hub; a `.stop` removes the entry, which the start notices (`token`).
        case starting(token: UUID)
        case running(LiveStreamPipeline)
    }

    /// How a session's UDP sockets are tied to the network, from the most to the least specific. A controller whose session
    /// ended without receiving any video moves one step down for its next session.
    enum SendStrategy: Int, Comparable, Sendable {
        /// Bound to the accessory address and scoped to the interface that owns it (`IP_BOUND_IF`): the source address and
        /// the egress interface both match what the controller was told.
        case boundAndScoped = 0
        /// Bound to the accessory address only (the routing table picks the interface).
        case bound = 1
        /// Bound to nothing: the routing table picks both.
        case wildcard = 2

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var text: String {
            switch self {
            case .boundAndScoped: "bound to the accessory address and scoped to its interface"
            case .bound: "bound to the accessory address"
            case .wildcard: "any address"
            }
        }
    }

    private let hubs: HubProvider
    private let snapshots: SnapshotProvider
    private let context: LiveStreamPipeline.Context
    private let loopbackOnly: Bool
    private let interfaceAddresses: @Sendable () -> [InterfaceAddress]
    private let talkback: TalkbackBridge?
    private let onChange: @Sendable () -> Void
    /// Told when a controller's advertised address looks like a VPN's (`NetworkNotice`), and again with the outcome.
    private let networkNotices: (@Sendable (NetworkNotice) -> Void)?
    /// How long after a stream started a silent controller counts as not reached (`NetworkNotice.Delivery.failed`).
    private let routeVerdictWait: Duration
    /// The notice of each prepared stream that has one, until it ends.
    private var routeNotices: [UUID: NetworkNotice] = [:]
    /// The user's live view stream and bit rate preferences (`CameraConfiguration.liveStreamMode` /
    /// `.liveMaxBitrateOverride`; the quality mode lives in `context`, which `LiveStreamPipeline` reads directly).
    private let streamMode: LiveStreamMode
    private let maxBitrateOverrideKbps: Int?
    private var sessions: [UUID: Entry] = [:]
    private var sessionEnder: (@Sendable (UUID) -> Bool)?
    private var stopped = false
    /// The IPv4 routing table, for telling a routed subnet from a VPN (`StreamAddress.isOnLocalNetwork`).
    private let routeTable: @Sendable () -> [MacVPNDetector.InterfaceRoute]
    /// How long a controller keeps the sending strategy a blind session moved it to.
    private let strategyMemory: Duration
    /// Replaces the live sessions' protection timings (`LiveStreamTimings`; tests).
    private let liveTimings: LiveStreamTimings?
    /// The strategy each controller's next session starts with (by the controller's address), with when it was set.
    private var peerStrategies: [String: (strategy: SendStrategy, since: ContinuousClock.Instant)] = [:]
    /// The controller, sending strategy and transport settings of each prepared or running session.
    private var sessionStrategies: [UUID: (peer: String, strategy: SendStrategy, transport: LiveStreamTransport)] = [:]
    /// Controllers with an open `liveViewNotReceived` notice, by controller address: the notice is settled when one of their
    /// sessions receives video again.
    private var blindPeers: [String: NetworkNotice] = [:]
    /// Subnets already reported as held by two interfaces (`NetworkNotice.Kind.dualHomedSubnet`), with when.
    private var dualSubnetReports: [String: ContinuousClock.Instant] = [:]

    /// `interfaceAddresses`: the machine's interface addresses (`StreamAddress.interfaceAddresses`; tests inject).
    init(hubs: @escaping HubProvider, snapshots: SnapshotProvider, context: LiveStreamPipeline.Context, loopbackOnly: Bool,
         streamMode: LiveStreamMode = .automatic, maxBitrateOverride: MaxBitrateOverride = .auto,
         interfaceAddresses: @escaping @Sendable () -> [InterfaceAddress] = StreamAddress.interfaceAddresses,
         routeTable: @escaping @Sendable () -> [MacVPNDetector.InterfaceRoute] = StreamAddress.routeTable,
         strategyMemory: Duration = .seconds(3_600), liveTimings: LiveStreamTimings? = nil,
         networkNotices: (@Sendable (NetworkNotice) -> Void)? = nil, routeVerdictWait: Duration = .seconds(8),
         onChange: @escaping @Sendable () -> Void = {}) {
        self.routeTable = routeTable
        self.strategyMemory = strategyMemory
        self.liveTimings = liveTimings
        self.hubs = hubs
        self.snapshots = snapshots
        self.context = context
        self.loopbackOnly = loopbackOnly
        self.streamMode = streamMode
        self.maxBitrateOverrideKbps = maxBitrateOverride.kbps
        self.interfaceAddresses = interfaceAddresses
        talkback = context.talkback.map { TalkbackBridge(makeSink: $0, codecs: context.codecs, log: context.log) }
        self.onChange = onChange
        self.networkNotices = networkNotices
        self.routeVerdictWait = routeVerdictWait
    }

    /// The most recently started sessions' live view status, for `CameraStatus` (per active viewer).
    func liveSessionStatuses() -> [LiveSessionStatus] {
        sessions.values.compactMap { entry in
            guard case .running(let pipeline) = entry else { return nil }
            return LiveSessionStatus(usesSubStream: pipeline.usesSubStream, isPassthrough: !pipeline.isTranscoding,
                                     resolution: pipeline.currentResolution, bitrateKbps: pipeline.currentBitrateKbps,
                                     health: pipeline.healthSummary, endReason: pipeline.endedByPipelineReason)
        }
    }

    /// How a session that ended by itself is reported to HAP (`CameraController.stopStreamingSession`).
    func setSessionEnder(_ ender: @escaping @Sendable (UUID) -> Bool) {
        sessionEnder = ender
    }

    var runningSessionCount: Int {
        sessions.values.filter { if case .running = $0 { true } else { false } }.count
    }

    /// The pipeline of a running session (tests).
    func pipeline(_ sessionID: UUID) -> LiveStreamPipeline? {
        if case .running(let pipeline) = sessions[sessionID] { return pipeline }
        return nil
    }

    /// Where a session's UDP sockets bind: the loopback address of the requested family in tests, else the wildcard
    /// (`nil`; an IPv6 wildcard socket is dual stack), so the controller reaches them on any interface.
    static func bindHost(loopbackOnly: Bool, ipv6: Bool) -> String? {
        loopbackOnly ? (ipv6 ? "::1" : "127.0.0.1") : nil
    }

    /// Where a session's UDP sockets bind outside tests: the accessory address the SetupEndpoints response advertises,
    /// so the SRTP leaves from the address the controller expects it from. A Mac on one LAN twice (Ethernet and Wi-Fi,
    /// two addresses on one subnet) otherwise sends from the routing table's interface: a controller whose HAP
    /// connection came in on the other address gets video from an address it never set up, drops it, and Home waits
    /// forever. The wildcard (`nil`) when the address is not one of ours, is link-local (a bind needs its scope), or is
    /// of another family than the destination (an IPv6 session sent to an IPv4 HAP peer needs the dual-stack wildcard).
    static func bindHost(accessoryAddress: String, destination: String, ipv6: Bool, interfaces: [InterfaceAddress]) -> String? {
        let address = StreamAddress.canonical(accessoryAddress)
        guard address.contains(":") == ipv6, StreamAddress.canonical(destination).contains(":") == ipv6,
              !StreamAddress.isLinkLocal(address), interfaces.contains(where: { $0.address == address }) else { return nil }
        return address
    }

    nonisolated func snapshot(_ request: SnapshotRequest) async throws -> Data {
        try await snapshots.snapshot(request)
    }

    func prepareStream(_ request: PrepareStreamRequest) throws -> PrepareStreamResponse {
        guard !stopped else { throw Failure.stopped }
        // The stream goes to the controller's advertised address, unless that is on none of our networks (a VPN address)
        // and the HAP connection's own address is: then to that (`StreamAddress.controllerRoute`). Scoped when it is
        // link-local (SetupEndpoints carries no scope).
        let interfaces = interfaceAddresses()
        let route = StreamAddress.controllerRoute(advertised: request.controllerAddress, peer: request.peerAddress,
                                                  zone: request.connectionZone, ipv6: request.isIPv6, interfaces: interfaces,
                                                  routes: loopbackOnly ? [] : routeTable())
        let address = StreamAddress.accessoryAddress(localAddress: request.localAddress, ipv6: request.isIPv6, interfaces: interfaces,
                                                     controller: route.host)
        let host = loopbackOnly ? Self.bindHost(loopbackOnly: true, ipv6: request.isIPv6)
            : Self.bindHost(accessoryAddress: address, destination: route.host, ipv6: request.isIPv6, interfaces: interfaces)
        let peerKey = StreamAddress.canonical(request.peerAddress ?? request.controllerAddress)
        let owner = host.flatMap { host in interfaces.first { $0.address == host }?.interface }
        let wanted = loopbackOnly ? SendStrategy.bound : strategy(forPeer: peerKey, host: host, interface: owner)
        let (video, audio, used) = try bindSockets(host: host, interface: owner, strategy: wanted, ipv6: request.isIPv6)
        sessionStrategies[request.sessionID] = (peerKey, used.strategy, video.transport)
        let videoSSRC = UInt32.random(in: 1...UInt32.max)
        var audioSSRC = UInt32.random(in: 1...UInt32.max)
        while audioSSRC == videoSSRC { audioSSRC = UInt32.random(in: 1...UInt32.max) }
        if case .prepared(let previous) = sessions[request.sessionID] { previous.close() }
        switch route.kind {
        case .advertised:
            break
        case .peerAddress:
            context.log.info(route.explanation ?? route.summary)
        case .advertisedOffNetwork:
            context.log.info("controller advertised \(route.advertised), which is not on this network, and the HAP connection address "
                             + "\(request.peerAddress ?? "(unknown)") is no help; sending to the advertised address")
        }
        if route.kind != .advertised, !interfaces.isEmpty, StreamAddress.looksLikeTunnelAddress(route.advertised) {
            let notice = NetworkNotice(kind: .controllerOnVPN, cameraID: context.log.cameraID, advertisedAddress: StreamAddress.canonical(route.advertised),
                                       peerAddress: request.peerAddress.map(StreamAddress.canonical), usedFallback: route.kind == .peerAddress)
            routeNotices[request.sessionID] = notice
            networkNotices?(notice)
        }
        var scoped = request
        scoped.controllerAddress = StreamAddress.controllerHost(route.host, zone: request.connectionZone,
                                                                localAddress: request.localAddress, interfaces: { interfaces })
        if scoped.controllerAddress != route.host {
            context.log.debug("Stream session to the link-local controller \(scoped.controllerAddress)")
        }
        var prepared = PreparedStream(request: scoped, videoSocket: video, audioSocket: audio, videoSSRC: videoSSRC, audioSSRC: audioSSRC)
        prepared.advertisedControllerAddress = request.controllerAddress
        let trace = DiagnosticsCenter.shared.begin(kind: "live", id: request.sessionID, cameraID: context.log.cameraID,
                                                   summary: "to \(scoped.controllerAddress) (IPv\(request.isIPv6 ? 6 : 4))")
        trace.mark("prepare", "controller video port \(request.controllerVideoPort), our video port \(video.localPort)")
        trace.mark("destination", route.summary)
        prepared.trace = trace
        sessions[request.sessionID] = .prepared(prepared)
        configureTransport(of: video, request: request, route: route, source: used.host, strategy: used.strategy, interface: used.interface,
                           interfaces: interfaces, peerKey: peerKey)
        context.log.info("Stream session prepared: video port \(video.localPort), audio port \(audio.localPort), "
                         + "sending from \(used.host ?? "any address") as \(address) (\(used.strategy.text)\(used.interface.map { ", interface \($0)" } ?? ""))")
        if !loopbackOnly { reportSharedSubnets(interfaces, accessoryAddress: address) }
        return PrepareStreamResponse(accessoryAddress: address, videoPort: video.localPort, audioPort: audio.localPort,
                                     videoSSRC: videoSSRC, audioSSRC: audioSSRC, videoSRTP: request.videoSRTP, audioSRTP: request.audioSRTP)
    }

    /// What a controller's sockets are tied to: the strategy it starts with, the one a session that received nothing moved it to
    /// (while remembered), and never more specific than what the machine offers (no address to bind: the wildcard; no
    /// interface known: no scope).
    private func strategy(forPeer peer: String, host: String?, interface: String?) -> SendStrategy {
        var floor = SendStrategy.boundAndScoped
        if let remembered = peerStrategies[peer] {
            if ContinuousClock.now - remembered.since < strategyMemory {
                floor = remembered.strategy
            } else {
                peerStrategies[peer] = nil
            }
        }
        let available: [SendStrategy] = host == nil ? [.wildcard] : (interface == nil ? [.bound, .wildcard] : [.boundAndScoped, .bound, .wildcard])
        return available.first { $0 >= floor } ?? .wildcard
    }

    /// The video and audio sockets of a session for `strategy`; a step that cannot be taken (the interface or the address went
    /// away since the interface list was read) falls back to the next, down to the wildcard, as before. In tests (loopback)
    /// the address must bind. Returns what the sockets ended up as.
    private func bindSockets(host: String?, interface: String?, strategy: SendStrategy, ipv6: Bool) throws
        -> (video: UDPSocket, audio: UDPSocket, used: (strategy: SendStrategy, host: String?, interface: String?)) {
        func pair(_ host: String?, _ interface: String?) throws -> (video: UDPSocket, audio: UDPSocket) {
            let video = try UDPSocket.bind(host: host, port: 0, ipv6: ipv6, interface: interface)
            do {
                return (video, try UDPSocket.bind(host: host, port: 0, ipv6: ipv6, interface: interface))
            } catch {
                video.close()
                throw error
            }
        }
        guard let host, !loopbackOnly else {
            let sockets = try pair(host, nil)
            return (sockets.video, sockets.audio, (host == nil ? .wildcard : .bound, host, nil))
        }
        var steps: [(SendStrategy, String?, String?)] = []
        if strategy == .boundAndScoped, let interface { steps.append((.boundAndScoped, host, interface)) }
        if strategy <= .bound { steps.append((.bound, host, nil)) }
        steps.append((.wildcard, nil, nil))
        var lastError: (any Error)?
        for (step, stepHost, stepInterface) in steps {
            do {
                let sockets = try pair(stepHost, stepInterface)
                return (sockets.video, sockets.audio, (step, stepHost, stepInterface))
            } catch {
                lastError = error
                context.log.info("Stream sockets could not be \(step.text)\(stepInterface.map { " (\($0))" } ?? "") (\(error)); trying the next way")
            }
        }
        throw lastError ?? UDPSocketError.closed
    }

    /// Tells the session how its sockets are set up and whom to tell when the controller receives nothing or sending fails for
    /// good (`LiveStreamTransport`, carried by the video socket).
    private func configureTransport(of socket: UDPSocket, request: PrepareStreamRequest, route: StreamAddress.ControllerRoute, source: String?,
                                    strategy: SendStrategy, interface: String?, interfaces: [InterfaceAddress], peerKey: String) {
        let cameraID = context.log.cameraID
        let peer = request.peerAddress.map(StreamAddress.canonical)
        let advertised = StreamAddress.canonical(route.advertised)
        let sink = networkNotices
        let usedFallback = route.kind == .peerAddress
        let timings = liveTimings
        let scopes = Self.recoveryScopes(source: source, scopedTo: interface, interfaces: interfaces)
        socket.transport.update { values in
            values.boundSource = source
            values.strategy = strategy.text + (interface.map { ", interface \($0)" } ?? "")
            values.route = route.summary
            values.recoveryScopes = scopes
            values.timings = timings
            values.onControllerNotReceiving = { [weak self] symptom in
                let notice = NetworkNotice(kind: .liveViewNotReceived, cameraID: cameraID, advertisedAddress: advertised, peerAddress: peer,
                                           usedFallback: usedFallback, delivery: .failed, detail: symptom)
                sink?(notice)
                Task { await self?.noteBlind(peer: peerKey, notice: notice) }
            }
            values.onControllerReceiving = { [weak self] in
                Task { await self?.noteReceiving(peer: peerKey) }
            }
            values.onFatalSendError = { _, text, localNetworkDenied in
                guard localNetworkDenied else { return }
                sink?(NetworkNotice(kind: .localNetworkDenied, cameraID: cameraID, detail: text))
            }
        }
    }

    /// The interfaces a session whose controller receives nothing scopes its sockets to, one after another: the interface that
    /// owns the bound address (when the sockets are not scoped to it already), then no scope at all (the routing table's choice),
    /// then the other interfaces of the same subnet (Ethernet and Wi-Fi). nil entries clear the scope. Empty for the wildcard.
    static func recoveryScopes(source: String?, scopedTo interface: String?, interfaces: [InterfaceAddress]) -> [String?] {
        guard let source, let owner = interfaces.first(where: { $0.address == source })?.interface else { return [] }
        let others = StreamAddress.sharedSubnets(interfaces).first { $0.addresses.contains(source) }?.interfaces.filter { $0 != owner } ?? []
        return (interface == nil ? [owner, nil] : [nil]) + others
    }

    private func noteBlind(peer: String, notice: NetworkNotice) {
        blindPeers[peer] = notice
    }

    /// A session of a controller with an open `liveViewNotReceived` notice got video through: the notice is settled.
    private func noteReceiving(peer: String) {
        guard var notice = blindPeers.removeValue(forKey: peer) else { return }
        notice.delivery = .reached
        notice.date = Date()
        context.log.info("Live view to \(peer): the controller receives video again")
        networkNotices?(notice)
    }

    /// Two interfaces of this Mac on one subnet (Ethernet and Wi-Fi on the home network): said once per subnet and hour, as a
    /// notice and an INFO line. CameraBridge sends from the address the controller connected to either way.
    private func reportSharedSubnets(_ interfaces: [InterfaceAddress], accessoryAddress: String) {
        for shared in StreamAddress.sharedSubnets(interfaces) {
            if let last = dualSubnetReports[shared.network], ContinuousClock.now - last < .seconds(3_600) { continue }
            dualSubnetReports[shared.network] = .now
            let list = shared.members.joined(separator: ", ")
            context.log.info("This Mac is on \(shared.network) through two interfaces (\(list)); live video is sent from the address the Home device "
                             + "connected to (\(accessoryAddress)) and scoped to that interface, which works either way, but turning one of them off is more reliable")
            networkNotices?(NetworkNotice(kind: .dualHomedSubnet, interfaceName: shared.interfaces.joined(separator: ", "),
                                          detail: "\(shared.network) (\(list))"))
        }
    }

    /// Forgets which sending strategy each controller moved to: the network changed, so what failed may work now. The runtime
    /// calls this when the network changes.
    func networkChanged() {
        guard !peerStrategies.isEmpty || !dualSubnetReports.isEmpty else { return }
        context.log.info("The network changed; live view sockets start with the most specific sending strategy again")
        peerStrategies.removeAll()
        dualSubnetReports.removeAll()
    }

    func handleStreamRequest(_ request: StreamRequest) async throws {
        switch request {
        case .start(let sessionID, let video, let audio):
            try await start(sessionID, video: video, audio: audio)
        case .reconfigure(let sessionID, var video):
            guard case .running(let pipeline) = sessions[sessionID] else { throw Failure.unknownSession }
            if let override = maxBitrateOverrideKbps { video.maxBitrateKbps = override }
            pipeline.reconfigure(video)
            let bitrate = video.maxBitrateKbps
            sessionStrategies[sessionID]?.transport.update { $0.maxBitrateKbps = bitrate }
        case .stop(let sessionID):
            await end(sessionID)
        }
    }

    /// Ends the running sessions that read the sub stream (it went offline: their picture froze, and nothing else would
    /// end them while the controller keeps sending RTCP) through HAP, so the controller starts them again: on the main
    /// stream while the sub stream is offline. Returns how many it ended.
    func endSubStreamSessions() async -> Int {
        let onSubStream = sessions.compactMap { id, entry -> UUID? in
            if case .running(let pipeline) = entry, pipeline.usesSubStream { return id }
            return nil
        }
        for sessionID in onSubStream {
            context.log.info("Live stream on the offline sub stream ended; ending the HomeKit session")
            if sessionEnder?(sessionID) != true { await end(sessionID) }
        }
        return onSubStream.count
    }

    /// Ends every session (runtime stopping); later setups are refused.
    func stopAll() async {
        stopped = true
        let entries = sessions
        sessions.removeAll()
        routeNotices.removeAll()
        sessionStrategies.removeAll()
        for entry in entries.values {
            switch entry {
            case .prepared(let prepared): prepared.close()
            case .starting: break   // the start sees `stopped` and undoes itself
            case .running(let pipeline): await pipeline.stop()
            }
        }
        await talkback?.close()
        if !entries.isEmpty { onChange() }
    }

    // MARK: - Private

    private func start(_ sessionID: UUID, video requested: SelectedVideoParameters, audio: SelectedAudioParameters?) async throws {
        guard case .prepared(let prepared) = sessions[sessionID] else { throw Failure.unknownSession }
        var video = requested
        if let override = maxBitrateOverrideKbps { video.maxBitrateKbps = override }
        let bitrate = video.maxBitrateKbps
        prepared.videoSocket.transport.update { $0.maxBitrateKbps = bitrate }   // paces a replay (`LiveStreamSession`)
        let token = UUID()
        sessions[sessionID] = .starting(token: token)
        let subSize = await context.subStreamSize?()
        let lease = await hubs(MediaFit.prefersSubStream(for: video, audio: audio, mode: streamMode, subStreamSize: subSize))
        let pipeline = LiveStreamPipeline(sessionID: sessionID, prepared: prepared, video: video, audio: audio, lease: lease, context: context,
                                          talkback: talkback)
        guard !stopped, !Task.isCancelled, case .starting(token) = sessions[sessionID] else {
            // Stopped (or abandoned) while waiting for the hub: release the lease and the sockets.
            if case .starting(token) = sessions[sessionID] { sessions[sessionID] = nil }
            await pipeline.stop()
            throw stopped ? Failure.stopped : CancellationError()
        }
        sessions[sessionID] = .running(pipeline)
        await pipeline.start()
        guard !Task.isCancelled, case .running(let current) = sessions[sessionID], current === pipeline else {
            if case .running(let current) = sessions[sessionID], current === pipeline { sessions[sessionID] = nil }
            await pipeline.stop()
            throw stopped ? Failure.stopped : CancellationError()
        }
        onChange()
        reportRouteOutcome(of: pipeline, sessionID: sessionID)
        Task { [weak self] in
            let reason = await pipeline.waitForEnd()
            await self?.pipelineEnded(sessionID, pipeline: pipeline, reason: reason)
        }
    }

    /// A stream whose controller advertised a VPN address: once the controller has answered (its first RTCP) or stayed silent
    /// for `routeVerdictWait`, the notice says whether the video got through.
    private func reportRouteOutcome(of pipeline: LiveStreamPipeline, sessionID: UUID) {
        guard let pending = routeNotices[sessionID], let sink = networkNotices else { return }
        let wait = routeVerdictWait
        let log = context.log
        Task.detached {
            var notice = pending
            let verdict = await pipeline.awaitController(timeout: wait)
            switch verdict {
            case .heard: notice.delivery = .reached
            case .silent: notice.delivery = .failed
            case .endedFirst: return
            }
            notice.date = Date()
            log.info("Live view to the controller that advertised \(notice.advertisedAddress ?? "an off-network address"): "
                     + (verdict == .heard ? "the controller answered" : "the controller did not answer within \(Int(wait / .seconds(1))) s")
                     + (notice.usedFallback ? " (sent to \(notice.peerAddress ?? "the HAP connection address"))" : ""))
            sink(notice)
        }
    }

    private func end(_ sessionID: UUID) async {
        routeNotices[sessionID] = nil
        sessionStrategies[sessionID] = nil
        guard let entry = sessions.removeValue(forKey: sessionID) else { return }
        switch entry {
        case .prepared(let prepared):
            prepared.trace?.finish("ended before it started")
            prepared.close()
        case .starting:
            break   // the start sees its entry gone and undoes itself
        case .running(let pipeline):
            await pipeline.stop()
            onChange()
        }
    }

    /// The session ended because its controller answered but received none of the video: the controller's next session sends
    /// the next way down `SendStrategy` (remembered for `strategyMemory`, forgotten by `networkChanged()`).
    func rememberBlindEnd(_ sessionID: UUID) {
        guard let used = sessionStrategies[sessionID], let next = SendStrategy(rawValue: used.strategy.rawValue + 1) else { return }
        peerStrategies[used.peer] = (next, .now)
        context.log.warning("Live view to \(used.peer) ended without the controller receiving video (sending was \(used.strategy.text)); "
                            + "its next live view will be \(next.text)")
    }

    /// The strategy and scope of a prepared or running session's video socket (tests).
    func socketSetup(_ sessionID: UUID) -> (strategy: SendStrategy, interface: String?)? {
        guard let used = sessionStrategies[sessionID] else { return nil }
        switch sessions[sessionID] {
        case .prepared(let prepared): return (used.strategy, prepared.videoSocket.scopedInterface)
        default: return (used.strategy, nil)
        }
    }

    /// A prepared session's video socket (tests: they play the part of the session that reports through its transport).
    func preparedVideoSocket(_ sessionID: UUID) -> UDPSocket? {
        if case .prepared(let prepared) = sessions[sessionID] { return prepared.videoSocket }
        return nil
    }

    private func pipelineEnded(_ sessionID: UUID, pipeline: LiveStreamPipeline, reason: LiveStreamEndReason) async {
        guard case .running(let current) = sessions[sessionID], current === pipeline else { return }
        if reason == .controllerNotReceiving { rememberBlindEnd(sessionID) }
        context.log.info("Live stream ended by itself (\(reason)); ending the HomeKit session")
        if sessionEnder?(sessionID) != true {
            await end(sessionID)
        }
    }
}
