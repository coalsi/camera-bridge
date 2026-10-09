import BridgeSupport
import Foundation
import HAP
import Synchronization
import TestSupport
import Testing
@testable import HDS

/// Deterministic server/connection tests over the in-memory `FakeNetworkTransport` (no sockets at all). The long
/// timers make any connection that is closed only by a timer fail the "closed at once" checks.
@Suite(.timeLimit(.minutes(1))) struct DataStreamServerFakeTransportTests {
    let transport = FakeNetworkTransport()
    static let patient = DataStreamServer.Timing(sessionExpiry: .seconds(30), helloTimeout: .seconds(30), firstByteTimeout: .seconds(30))

    struct Harness {
        let session: FakeHAPSession
        let client: HDSLoopbackClient
        /// The server's end of the client's connection.
        let serverEnd: FakeTCPConnection
        let listener: FakeTCPListener
    }

    func makeServer() -> DataStreamServer {
        DataStreamServer(transport: transport, loopbackOnly: true, timing: Self.patient)
    }

    /// Prepares a session and connects a (not yet hello'd) client through the fake listener.
    func connect(_ server: DataStreamServer, session: FakeHAPSession = FakeHAPSession()) async throws -> Harness {
        let controllerKeySalt = randomBytes(32)
        let prepared = try await server.prepareSession(controllerKeySalt: controllerKeySalt, session: session)
        let listener = try #require(transport.listeners.last)
        #expect(listener.port == prepared.port)
        let pair = FakeTCPConnection.pair()
        let client = HDSLoopbackClient(connection: pair.client, sharedSecret: session.sharedSecret,
                                       controllerKeySalt: controllerKeySalt, accessoryKeySalt: prepared.accessoryKeySalt)
        listener.accept(pair.server)
        return Harness(session: session, client: client, serverEnd: pair.server, listener: listener)
    }

    // MARK: - stop() racing the accept loop

    /// The transport hands over a connection while `stop()` closes the listener: it must be closed at once, not kept
    /// for the hello timeout, and must not keep a restarted server's listener open.
    @Test func connectionAcceptedWhileStopRunsIsClosedAtOnce() async throws {
        let server = makeServer()
        _ = try await server.prepareSession(controllerKeySalt: randomBytes(32), session: FakeHAPSession())
        let listener = try #require(transport.listeners.last)
        // The accept loop has taken one connection, so it is waiting on the stream when the next one arrives.
        let warmUp = FakeTCPConnection.pair()
        listener.accept(warmUp.server)
        #expect(await eventually { await server.identifyingCount == 1 })

        let late = FakeTCPConnection.pair()
        listener.beforeClose { listener.accept(late.server) }
        await server.stop()
        #expect(listener.isClosed)
        #expect(warmUp.server.isClosed)
        #expect(await eventually(timeout: .seconds(2)) { late.server.isClosed })
        #expect(await server.identifyingCount == 0)

        // A restarted server's listener closes as soon as it is idle (no stray connection holds it).
        let again = FakeHAPSession()
        _ = try await server.prepareSession(controllerKeySalt: randomBytes(32), session: again)
        let second = try #require(transport.listeners.last)
        #expect(second !== listener)
        again.close()
        #expect(await eventually(timeout: .seconds(2)) { second.isClosed })
        await server.stop()
    }

    /// Same race while `stop()` is suspended closing an active connection (actor reentrancy).
    @Test func connectionAcceptedWhileStopClosesActiveConnectionsIsClosedAtOnce() async throws {
        let server = makeServer()
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        #expect(await server.connectionCount == 1)

        let late = FakeTCPConnection.pair()
        harness.listener.beforeClose { harness.listener.accept(late.server) }
        await server.stop()
        #expect(await harness.client.isDropped())
        #expect(await eventually(timeout: .seconds(2)) { late.server.isClosed })
        #expect(await server.identifyingCount == 0)
        #expect(await server.connectionCount == 0)
    }

    // MARK: - Listener recovery

    // The engine never restarts a camera's `DataStreamServer` on wake or a network change, so re-binding on the next
    // SetupDataStreamTransport is HKSV's only way back after the listener could not bind or died.

    /// A failed bind is reported to SetupDataStreamTransport but not remembered: the next session binds again and the
    /// hub's connection works.
    @Test func failedBindIsReportedAndTheNextSessionBindsAgain() async throws {
        let server = makeServer()
        await server.setHandler(protocol: "dataSend", Self.answeringRequests)
        transport.failNextListens([.localNetworkDenied])
        await #expect(throws: TransportError.localNetworkDenied) {
            _ = try await server.prepareSession(controllerKeySalt: randomBytes(32), session: FakeHAPSession())
        }
        #expect(await !server.isListening)
        #expect(await server.preparedSessionCount == 0)
        #expect(transport.listeners.isEmpty)

        let harness = try await connect(server)
        #expect(transport.listenCount == 2)
        try await expectHelloAndDataSendOpen(harness.client)
        #expect(await server.connectionCount == 1)
        await server.stop()
        #expect(harness.listener.isClosed)
    }

    /// The transport stops the listener on its own (NWListener `.waiting`/`.failed`, e.g. after a network change)
    /// while an open connection keeps the server busy, so the idle close does not drop it either: the next session
    /// must bind a new listener rather than hand the hub the dead port. The connection already open is unaffected.
    @Test func listenerThatStopsOnItsOwnIsReplacedByTheNextSession() async throws {
        let server = makeServer()
        await server.setHandler(protocol: "dataSend", Self.answeringRequests)
        let busy = try await connect(server)
        _ = try await busy.client.hello()
        #expect(await server.connectionCount == 1)

        let dead = busy.listener
        dead.fail()
        try #require(await eventually { await !server.isListening })

        let harness = try await connect(server)
        #expect(transport.listeners.count == 2)
        try #require(harness.listener !== dead)   // a client of the dead listener would wait for its hello in vain
        #expect(harness.listener.port != dead.port)
        try await expectHelloAndDataSendOpen(harness.client)
        #expect(await server.connectionCount == 2)
        #expect(!busy.serverEnd.isClosed)
        await server.stop()
        #expect(harness.listener.isClosed)
        #expect(await busy.client.isDropped())
    }

    /// Answers every request with success (stands in for HAPCamera's recording handler).
    private static let answeringRequests: @Sendable (HDSMessage, DataStreamConnection) async -> Void = { message, connection in
        if case .request = message.kind {
            try? await connection.sendResponse(to: message, status: .success, body: HDSDictionary([("status", .int(0))]))
        }
    }

    /// The hub's opening exchange on a new connection: `control/hello`, then `dataSend/open`.
    private func expectHelloAndDataSendOpen(_ client: HDSLoopbackClient) async throws {
        #expect(try await client.hello().kind == .response(id: 1, status: .success))
        let open = HDSMessage(kind: .request(id: 2), protocolName: "dataSend", topic: "open",
                              body: HDSDictionary([("target", .string("controller")), ("type", .string("ipcamera.recording")),
                                                   ("streamId", .int(1))]))
        try await client.send(open)
        #expect(try await client.receiveMessage().kind == .response(id: 2, status: .success))
    }

    // MARK: - Releasing the server

    @Test func releasedServerClosesItsListenerAndEveryConnection() async throws {
        let (server, listener, pending, client) = try await abandonedServer()
        #expect(await eventually { server.object == nil })
        #expect(await eventually { listener.isClosed })
        #expect(await eventually { pending.isClosed })
        #expect(await client.isDropped())
    }

    /// A server with an active connection, a prepared session and a connection awaiting its first frame, of which the
    /// caller keeps only a weak reference.
    private func abandonedServer() async throws -> (WeakReference<DataStreamServer>, FakeTCPListener, FakeTCPConnection, HDSLoopbackClient) {
        let server = makeServer()
        await server.setHandler(protocol: "dataSend") { _, _ in }
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        _ = try await server.prepareSession(controllerKeySalt: randomBytes(32), session: FakeHAPSession())
        let pending = FakeTCPConnection.pair()
        harness.listener.accept(pending.server)
        #expect(await eventually { await server.identifyingCount == 1 })
        #expect(await server.connectionCount == 1)
        #expect(await server.preparedSessionCount == 1)
        return (WeakReference(server), harness.listener, pending.server, harness.client)
    }

    // MARK: - Bounded buffering

    /// While the handler is busy, at most `maximumQueuedMessages` messages wait for it; the connection stops reading
    /// from the transport until the handler catches up, then delivers everything in order.
    @Test func slowHandlerStopsTheConnectionReading() async throws {
        let server = makeServer()
        let gate = Gate()
        let topics = Mailbox<String>()
        let connections = Mailbox<DataStreamConnection>()
        await server.setHandler(protocol: "dataSend") { message, connection in
            await topics.append(message.topic)
            await connections.append(connection)
            await gate.wait()
        }
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        let limit = DataStreamConnection.maximumQueuedMessages
        let total = limit + 20
        var batch = Data()
        for index in 0..<total {
            batch += try await harness.client.seal(HDSMessage(kind: .event, protocolName: "dataSend", topic: "e\(index)"))
        }
        try await harness.client.sendRaw(batch)
        let connection = try #require(await connections.next())
        #expect(await eventually { await connection.queuedMessageCount == limit })

        let extra = try await harness.client.seal(HDSMessage(kind: .event, protocolName: "dataSend", topic: "extra"))
        try await harness.client.sendRaw(extra)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(harness.serverEnd.inbound.pendingByteCount == extra.count)   // not read
        #expect(await connection.queuedMessageCount == limit)

        await gate.open()
        #expect(await eventually { await topics.count == total + 1 })
        #expect(await topics.all == (0..<total).map { "e\($0)" } + ["extra"])
        #expect(await eventually { await connection.queuedMessageCount == 0 })
        #expect(harness.serverEnd.inbound.pendingByteCount == 0)
        await server.stop()
    }

    /// At most `maximumIdentifyingConnections` connections await their first frame. When they are all taken, a
    /// newcomer closes the oldest of them instead of being refused, so a LAN peer that holds every slot with silent
    /// sockets cannot keep the hub's HDS connection (and the recording stream) from opening.
    @Test func newcomerEvictsTheOldestConnectionAwaitingItsFirstFrame() async throws {
        let server = makeServer()
        let session = FakeHAPSession()
        let controllerKeySalt = randomBytes(32)
        let prepared = try await server.prepareSession(controllerKeySalt: controllerKeySalt, session: session)
        let listener = try #require(transport.listeners.last)
        let limit = DataStreamServer.maximumIdentifyingConnections
        // The accept loop takes connections in order, so `silent[0]` is the oldest.
        let silent = (0..<limit).map { _ in FakeTCPConnection.pair().server }
        for connection in silent { listener.accept(connection) }
        #expect(await eventually { await server.identifyingCount == limit })

        // The hub connects while every slot is held and sends its hello at once.
        let hub = FakeTCPConnection.pair()
        let client = HDSLoopbackClient(connection: hub.client, sharedSecret: session.sharedSecret,
                                       controllerKeySalt: controllerKeySalt, accessoryKeySalt: prepared.accessoryKeySalt)
        listener.accept(hub.server)
        #expect(await eventually(timeout: .seconds(2)) { silent[0].isClosed })
        #expect(silent.dropFirst().allSatisfy { !$0.isClosed })
        #expect(try await client.hello().kind == .response(id: 1, status: .success))
        #expect(!hub.server.isClosed)
        #expect(await server.connectionCount == 1)
        #expect(await eventually { await server.identifyingCount == limit - 1 })

        // Later newcomers keep closing the oldest waiting connection, in arrival order; the cap holds throughout.
        let later = (0..<2).map { _ in FakeTCPConnection.pair().server }
        for connection in later { listener.accept(connection) }
        #expect(await eventually(timeout: .seconds(2)) { silent[1].isClosed })
        #expect(await server.identifyingCount == limit)
        #expect(silent.dropFirst(2).allSatisfy { !$0.isClosed })
        #expect(later.allSatisfy { !$0.isClosed })
        #expect(await server.connectionCount == 1)   // the identified connection never counts against the cap

        await server.stop()
        #expect((silent + later).allSatisfy { $0.isClosed })
    }

    /// A connection that sends nothing is closed after `firstByteTimeout` (a hub sends its hello right after
    /// connecting), long before the hello timeout. One whose first frame is under way keeps the full hello window.
    @Test func silentConnectionIsClosedBeforeTheHelloTimeout() async throws {
        let server = DataStreamServer(transport: transport, loopbackOnly: true,
                                      timing: .init(sessionExpiry: .seconds(30), helloTimeout: .seconds(30), firstByteTimeout: .milliseconds(200)))
        let silent = try await connect(server)
        #expect(await silent.client.isDropped(within: .seconds(5)))   // the 30 s hello timeout would miss this
        #expect(await eventually { await server.identifyingCount == 0 })
        #expect(await server.preparedSessionCount == 1)   // its controller may still connect again

        let slow = try await connect(server)
        let hello = try await slow.client.seal(HDSMessage(kind: .request(id: 1), protocolName: "control", topic: "hello"))
        try await slow.client.sendRaw(hello.prefix(10))
        try await Task.sleep(for: .milliseconds(600))
        #expect(!slow.serverEnd.isClosed)
        try await slow.client.sendRaw(hello.dropFirst(10))
        #expect(try await slow.client.receiveMessage().kind == .response(id: 1, status: .success))
        #expect(await server.connectionCount == 1)
        await server.stop()
    }

    @Test func theSendStallDefaultIsFifteenSeconds() {
        #expect(DataStreamServer.Timing().sendStallTimeout == .seconds(15))
    }

    /// Hardening plan WS-C 1: a hub that vanished without a FIN never lets a send complete (a recording packet on its
    /// way); the send-progress watchdog closes the connection, which fails the sender and frees the recording slot
    /// behind it. A connection whose sends complete is untouched however long it idles.
    @Test func connectionWhoseSendMakesNoProgressIsClosedByTheWatchdog() async throws {
        var timing = Self.patient
        timing.sendStallTimeout = .milliseconds(300)
        let server = DataStreamServer(transport: transport, loopbackOnly: true, timing: timing)
        await server.setHandler(protocol: "dataSend") { _, _ in }
        let healthy = try await connect(server)
        _ = try await healthy.client.hello()
        let gone = try await connect(server)
        _ = try await gone.client.hello()
        #expect(await server.connectionCount == 2)

        gone.serverEnd.stallSends()
        let connection = try #require(await server.connections.first { $0.hapSessionID == gone.session.id })
        let send = Task { try await connection.sendEvent(protocol: "dataSend", topic: "data", body: HDSDictionary()) }
        #expect(await eventually { gone.serverEnd.stalledSendCount == 1 })
        #expect(!gone.serverEnd.isClosed, "not before the limit")
        await #expect(throws: HDSConnectionError.closed) { try await send.value }
        #expect(gone.serverEnd.isClosed)
        #expect(await eventually { await server.connectionCount == 1 })
        #expect(!healthy.serverEnd.isClosed)
        await server.stop()
    }

    /// The first frame must be a small `control/hello`: a longer one is refused as soon as its header arrives,
    /// without buffering it for the hello timeout or trial-decrypting it.
    @Test func oversizedFirstFrameIsRejectedAtOnce() async throws {
        let server = makeServer()
        let harness = try await connect(server)
        let length = DataStreamServer.maximumFirstPayloadLength + 1
        try await harness.client.sendRaw(Data([0x01, UInt8(length >> 16), UInt8(truncatingIfNeeded: length >> 8),
                                               UInt8(truncatingIfNeeded: length)]) + Data(count: 100))
        #expect(await harness.client.isDropped(within: .seconds(2)))
        #expect(await server.identifyingCount == 0)
        #expect(await server.preparedSessionCount == 1)   // the real controller may still connect
        await server.stop()
    }

    @Test func helloWithABodyUpToTheFirstFrameBoundIsAccepted() async throws {
        let server = makeServer()
        let harness = try await connect(server)
        var body = HDSDictionary([("pad", .data(Data()))])
        let bare = try HDSFrameCodec.encodePayload(HDSMessage(kind: .request(id: 1), protocolName: "control", topic: "hello", body: body)).count
        body["pad"] = .data(Data(count: DataStreamServer.maximumFirstPayloadLength - bare - 2))   // 2-byte length prefix
        let hello = HDSMessage(kind: .request(id: 1), protocolName: "control", topic: "hello", body: body)
        #expect(try HDSFrameCodec.encodePayload(hello).count == DataStreamServer.maximumFirstPayloadLength)
        try await harness.client.send(hello)
        #expect(try await harness.client.receiveMessage().kind == .response(id: 1, status: .success))
        await server.stop()
    }

    // MARK: - What unauthenticated peers can put into the log

    /// Review finding (W4 round 2): every eviction past `maximumIdentifyingConnections` and every first frame that
    /// matched no prepared session logged a notice, so a LAN peer connecting in a loop could flush the in-app log (1000
    /// entries) and fill the unified log. They are now logged at most once per minute (evictions: per server; unmatched
    /// frames: per remote address), the next one noting how many were not.
    @Test func connectionChurnIsNotLoggedOneByOne() async throws {
        let sink = LogCapture()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let server = makeServer()
        let prepared = try await server.prepareSession(controllerKeySalt: randomBytes(32), session: FakeHAPSession())
        let listener = try #require(transport.listeners.last)
        let address = "fd00::\(String(UInt32.random(in: 1...UInt32.max), radix: 16))"

        // Silent connections: each one beyond the cap evicts the oldest.
        let limit = DataStreamServer.maximumIdentifyingConnections
        let silent = (0..<(limit + 40)).map { _ in FakeTCPConnection.pair(remoteAddress: address).server }
        for connection in silent { listener.accept(connection) }
        #expect(await eventually { silent.prefix(40).allSatisfy(\.isClosed) })

        // Complete first frames under keys of no prepared session.
        for _ in 0..<20 {
            let pair = FakeTCPConnection.pair(remoteAddress: address)
            let client = HDSLoopbackClient(connection: pair.client, sharedSecret: randomBytes(32), controllerKeySalt: randomBytes(32),
                                           accessoryKeySalt: prepared.accessoryKeySalt)
            listener.accept(pair.server)
            try await client.send(HDSMessage(kind: .request(id: 1), protocolName: "control", topic: "hello"))
            #expect(await client.isDropped(within: .seconds(2)))
        }

        let logged = sink.messages.filter { $0.contains(address) }
        #expect(logged.filter { $0.contains("before its first frame") }.count == 1, "\(logged.count) lines")
        #expect(logged.filter { $0.contains("matched no prepared session") }.count == 1, "\(logged.count) lines")
        await server.stop()
    }
}

/// Collects log messages (this test's sink only; removed by token).
private final class LogCapture: LogSink {
    private let entries = Mutex<[String]>([])
    func record(_ entry: LogEntry) { entries.withLock { $0.append(entry.message) } }
    var messages: [String] { entries.withLock { $0 } }
}
