#if os(macOS)
import BridgeSupport
import Foundation
import HAP
import PlatformApple
import TestSupport
import Testing
@testable import HDS

/// Loopback only (127.0.0.1): the listener never binds a LAN interface and nothing is advertised.
@Suite(.timeLimit(.minutes(1))) struct DataStreamServerTests {
    let transport = AppleNetworkTransport()

    /// A server, one prepared session and a connected (not yet hello'd) client.
    struct Harness {
        let server: DataStreamServer
        let session: FakeHAPSession
        let client: HDSLoopbackClient
        let port: UInt16
    }

    /// The default keeps the 2 s first-byte bound out of the way of slow test machines: these tests do not exercise it
    /// (`DataStreamServerFakeTransportTests.silentConnectionIsClosedBeforeTheHelloTimeout` does, deterministically).
    func makeServer(timing: DataStreamServer.Timing = .init(firstByteTimeout: .seconds(10))) -> DataStreamServer {
        DataStreamServer(transport: transport, loopbackOnly: true, timing: timing)
    }

    func connect(_ server: DataStreamServer, session: FakeHAPSession = FakeHAPSession(),
                 clientSecret: Data? = nil) async throws -> Harness {
        let controllerKeySalt = randomBytes(32)
        let prepared = try await server.prepareSession(controllerKeySalt: controllerKeySalt, session: session)
        let client = try await HDSLoopbackClient.connect(transport: transport, port: prepared.port,
                                                         sharedSecret: clientSecret ?? session.sharedSecret,
                                                         controllerKeySalt: controllerKeySalt, accessoryKeySalt: prepared.accessoryKeySalt)
        return Harness(server: server, session: session, client: client, port: prepared.port)
    }

    static let openBody = HDSDictionary([("target", .string("controller")), ("type", .string("ipcamera.recording")), ("streamId", .int(1))])

    // MARK: - Required flow (plan W1-6 item 5)

    @Test func helloThenDataSendOpenReachesHandlerWhichResponds() async throws {
        let server = makeServer()
        let received = Mailbox<HDSMessage>()
        await server.setHandler(protocol: "dataSend") { message, connection in
            await received.append(message)
            if case .request = message.kind {
                try? await connection.sendResponse(to: message, status: .success, body: HDSDictionary([("status", .int(0))]))
            }
        }
        let harness = try await connect(server)
        #expect(harness.port != 0)

        let hello = try await harness.client.hello(id: 42)
        #expect(hello == HDSMessage(kind: .response(id: 42, status: .success), protocolName: "control", topic: "hello"))
        #expect(await server.connectionCount == 1)

        let open = HDSMessage(kind: .request(id: 7), protocolName: "dataSend", topic: "open", body: Self.openBody)
        try await harness.client.send(open)
        #expect(await received.next() == open)
        let response = try await harness.client.receiveMessage()
        #expect(response == HDSMessage(kind: .response(id: 7, status: .success), protocolName: "dataSend", topic: "open",
                                       body: HDSDictionary([("status", .int(0))])))
        await harness.client.close()
        await server.stop()
    }

    @Test func eventsAndRequestsFlowBothWays() async throws {
        let server = makeServer()
        let received = Mailbox<(HDSMessage, DataStreamConnection)>()
        await server.setHandler(protocol: "dataSend") { message, connection in
            await received.append((message, connection))
        }
        let harness = try await connect(server)
        _ = try await harness.client.hello()

        // Controller → accessory event.
        let ack = HDSMessage(kind: .event, protocolName: "dataSend", topic: "ack", body: HDSDictionary([("streamId", .int(1))]))
        try await harness.client.send(ack)
        let delivered = try #require(await received.next())
        #expect(delivered.0 == ack)
        let connection = delivered.1
        #expect(connection.hapSessionID == harness.session.id)
        #expect(!connection.isClosed)

        // Accessory → controller event.
        let data = HDSDictionary([("streamId", .int(1)), ("packets", .array([.data(Data([1, 2, 3]))]))])
        try await connection.sendEvent(protocol: "dataSend", topic: "data", body: data)
        #expect(try await harness.client.receiveMessage() == HDSMessage(kind: .event, protocolName: "dataSend", topic: "data", body: data))

        // Accessory → controller request, answered by the controller.
        async let answer = connection.sendRequest(protocol: "dataSend", topic: "close", body: HDSDictionary([("reason", .int(0))]),
                                                  timeout: .seconds(5))
        let request = try await harness.client.receiveMessage()
        guard case .request(let id) = request.kind else {
            Issue.record("expected a request, got \(request)")
            return
        }
        #expect(request.protocolName == "dataSend" && request.topic == "close" && request.body == HDSDictionary([("reason", .int(0))]))
        let reply = HDSMessage(kind: .response(id: id, status: .success), protocolName: "dataSend", topic: "close",
                               body: HDSDictionary([("ok", .bool(true))]))
        try await harness.client.send(reply)
        let answered = try await answer
        #expect(answered == reply)
        #expect(await received.count == 0)   // responses never reach the protocol handler
        await server.stop()
    }

    @Test func wrongKeyConnectionIsDropped() async throws {
        let server = makeServer()
        let received = Mailbox<HDSMessage>()
        await server.setHandler(protocol: "dataSend") { message, _ in await received.append(message) }
        let harness = try await connect(server, clientSecret: randomBytes(32))
        try await harness.client.send(HDSMessage(kind: .request(id: 1), protocolName: "control", topic: "hello"))
        #expect(await harness.client.isDropped())
        #expect(await server.connectionCount == 0)
        #expect(await server.preparedSessionCount == 1)   // the real controller may still connect
        #expect(await received.count == 0)
        await server.stop()
    }

    @Test func expiredSessionIsRejected() async throws {
        let server = makeServer()
        let expired = FakeHAPSession()
        let expiredSalt = randomBytes(32)
        // Only the stale session expires quickly; the live one below keeps the normal 10 s.
        let stale = try await server.prepareSession(controllerKeySalt: expiredSalt, session: expired, expiry: .milliseconds(200))
        #expect(await eventually { await server.preparedSessionCount == 0 })

        // A fresh session keeps (or re-opens) the listener; the stale keys must not match anything.
        let live = try await connect(server)
        let staleClient = try await HDSLoopbackClient.connect(transport: transport, port: live.port, sharedSecret: expired.sharedSecret,
                                                              controllerKeySalt: expiredSalt, accessoryKeySalt: stale.accessoryKeySalt)
        try await staleClient.send(HDSMessage(kind: .request(id: 1), protocolName: "control", topic: "hello"))
        #expect(await staleClient.isDropped())

        #expect(try await live.client.hello().kind == .response(id: 1, status: .success))
        #expect(await server.connectionCount == 1)
        await server.stop()
    }

    /// Brief §3.8: prepared sessions expire after 10 s, hello must arrive within 10 s, `sendRequest` times out after 10 s.
    /// Our own bound: a connection that sends nothing at all for 2 s is closed earlier (a hub sends its hello at once).
    @Test func protocolTimersDefaultToTenSeconds() async throws {
        #expect(DataStreamServer.Timing() == DataStreamServer.Timing(sessionExpiry: .seconds(10), helloTimeout: .seconds(10),
                                                                     firstByteTimeout: .seconds(2)))
        #expect(await DataStreamServer(transport: transport).timing == DataStreamServer.Timing())

        let server = makeServer()
        let received = Mailbox<DataStreamConnection>()
        await server.setHandler(protocol: "dataSend") { _, connection in await received.append(connection) }
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        try await harness.client.send(HDSMessage(kind: .event, protocolName: "dataSend", topic: "ack"))
        let connection = try #require(await received.next())
        let outcome = Task { try await connection.sendRequest(protocol: "dataSend", topic: "close", body: HDSDictionary()) }
        let request = try await harness.client.receiveMessage()
        #expect(await connection.pendingRequestTimeouts == [.seconds(10)])
        guard case .request(let id) = request.kind else {
            Issue.record("expected a request, got \(request)")
            return
        }
        try await harness.client.send(HDSMessage(kind: .response(id: id, status: .success), protocolName: "dataSend", topic: "close"))
        #expect(try await outcome.value.kind == .response(id: id, status: .success))
        await server.stop()
    }

    // MARK: - Listener lifecycle

    @Test func listenerBindsLazilyOnLoopbackAndClosesWhenIdle() async throws {
        let counting = CountingTransport(transport)
        let server = DataStreamServer(transport: counting, loopbackOnly: true)
        await server.setHandler(protocol: "dataSend") { _, _ in }
        #expect(counting.listenCount == 0)
        #expect(await !server.isListening)

        let a = FakeHAPSession()
        let b = FakeHAPSession()
        let first = try await server.prepareSession(controllerKeySalt: randomBytes(32), session: a)
        let second = try await server.prepareSession(controllerKeySalt: randomBytes(32), session: b)
        #expect(counting.listenCount == 1)
        #expect(counting.loopbackFlags == [true])
        #expect(first.port == second.port)
        #expect(first.accessoryKeySalt.count == 32 && first.accessoryKeySalt != second.accessoryKeySalt)
        #expect(await server.isListening)

        // Both HAP sessions close → nothing left to serve → the listener closes; the next session re-binds.
        a.close()
        #expect(await eventually { await server.preparedSessionCount == 1 })
        #expect(await server.isListening)
        b.close()
        #expect(await eventually { await !server.isListening })
        _ = try await server.prepareSession(controllerKeySalt: randomBytes(32), session: FakeHAPSession())
        #expect(counting.listenCount == 2)
        await server.stop()
        #expect(await !server.isListening)
    }

    @Test func listenerClosesWhenPreparedSessionsExpireUnused() async throws {
        let server = makeServer()
        _ = try await server.prepareSession(controllerKeySalt: randomBytes(32), session: FakeHAPSession(), expiry: .milliseconds(200))
        #expect(await eventually { await server.preparedSessionCount == 0 })
        #expect(await eventually { await !server.isListening })
        await server.stop()
    }

    /// Dropping the server without `stop()` closes its listener at once (not when the next peer connects) and
    /// releases its port.
    @Test func releasedServerReleasesItsPort() async throws {
        let counting = CountingTransport(transport)
        let (server, port) = try await abandonedServer(transport: counting)
        let listener = try #require(counting.listeners.first)
        #expect(await eventually { server.object == nil })
        #expect(await eventually { listener.isClosed })
        #expect(await eventually { await !canConnect(port: port) })
    }

    private func abandonedServer(transport: CountingTransport) async throws -> (WeakReference<DataStreamServer>, UInt16) {
        let server = DataStreamServer(transport: transport, loopbackOnly: true)
        let prepared = try await server.prepareSession(controllerKeySalt: randomBytes(32), session: FakeHAPSession())
        return (WeakReference(server), prepared.port)
    }

    private func canConnect(port: UInt16) async -> Bool {
        guard let connection = try? await transport.connect(host: "127.0.0.1", port: port, timeout: .seconds(1)) else { return false }
        connection.close()
        return true
    }

    @Test func concurrentPreparesShareOneListener() async throws {
        let counting = CountingTransport(transport)
        let server = DataStreamServer(transport: counting, loopbackOnly: true)
        let ports = try await withThrowingTaskGroup(of: UInt16.self) { group in
            for _ in 0..<8 {
                group.addTask { try await server.prepareSession(controllerKeySalt: randomBytes(32), session: FakeHAPSession()).port }
            }
            return try await group.reduce(into: Set<UInt16>()) { $0.insert($1) }
        }
        #expect(ports.count == 1)
        #expect(counting.listenCount == 1)
        #expect(await server.preparedSessionCount == 8)
        await server.stop()
        #expect(await server.preparedSessionCount == 0)
    }

    @Test func matchesTheRightSessionAmongSeveral() async throws {
        let server = makeServer()
        let a = FakeHAPSession()
        let b = FakeHAPSession()
        let saltA = randomBytes(32)
        let preparedA = try await server.prepareSession(controllerKeySalt: saltA, session: a)
        let harnessB = try await connect(server, session: b)
        _ = try await harnessB.client.hello()
        #expect(await server.connections.map(\.hapSessionID) == [b.id])
        #expect(await server.preparedSessionCount == 1)

        let clientA = try await HDSLoopbackClient.connect(transport: transport, port: preparedA.port, sharedSecret: a.sharedSecret,
                                                          controllerKeySalt: saltA, accessoryKeySalt: preparedA.accessoryKeySalt)
        _ = try await clientA.hello()
        #expect(Set(await server.connections.map(\.hapSessionID)) == [a.id, b.id])
        #expect(await server.connectionCount == 2)
        #expect(await server.preparedSessionCount == 0)

        // A prepared session is consumed by its connection: the same keys cannot connect twice.
        let replay = try await HDSLoopbackClient.connect(transport: transport, port: preparedA.port, sharedSecret: a.sharedSecret,
                                                         controllerKeySalt: saltA, accessoryKeySalt: preparedA.accessoryKeySalt)
        try await replay.send(HDSMessage(kind: .request(id: 1), protocolName: "control", topic: "hello"))
        #expect(await replay.isDropped())
        await server.stop()
    }

    // MARK: - Connection lifecycle

    @Test func hapSessionCloseClosesItsConnection() async throws {
        let server = makeServer()
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        let connection = try #require(await server.connections.first)
        let closed = Mailbox<Bool>()
        connection.onClose { Task { await closed.append(true) } }

        harness.session.close()
        #expect(await harness.client.isDropped())
        #expect(await closed.next() == true)
        #expect(connection.isClosed)
        #expect(await eventually { await server.connectionCount == 0 })
        await server.stop()
    }

    @Test func hapSessionCloseDropsItsPreparedSession() async throws {
        let server = makeServer()
        let session = FakeHAPSession()
        _ = try await server.prepareSession(controllerKeySalt: randomBytes(32), session: session)
        #expect(await server.preparedSessionCount == 1)
        session.close()
        #expect(await eventually { await server.preparedSessionCount == 0 })
        await server.stop()
    }

    @Test func helloMustArriveInTime() async throws {
        let server = makeServer(timing: .init(sessionExpiry: .seconds(10), helloTimeout: .milliseconds(300)))
        let silent = try await connect(server)
        #expect(await silent.client.isDropped())

        // A partial first frame does not keep the connection alive either.
        let partial = try await connect(server)
        let hello = try await partial.client.seal(HDSMessage(kind: .request(id: 1), protocolName: "control", topic: "hello"))
        try await partial.client.sendRaw(hello.prefix(10))
        #expect(await partial.client.isDropped())
        #expect(await server.connectionCount == 0)
        await server.stop()
    }

    @Test func firstMessageMustBeHello() async throws {
        let server = makeServer()
        let received = Mailbox<HDSMessage>()
        await server.setHandler(protocol: "dataSend") { message, _ in await received.append(message) }
        let harness = try await connect(server)
        try await harness.client.send(HDSMessage(kind: .event, protocolName: "dataSend", topic: "ack"))
        #expect(await harness.client.isDropped())
        #expect(await received.count == 0)
        #expect(await eventually { await server.connectionCount == 0 })
        await server.stop()
    }

    @Test func frameThatFailsAuthenticationClosesTheConnection() async throws {
        let server = makeServer()
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        // Replays counter 0 (the hello's nonce).
        let replayed = try await harness.client.seal(HDSMessage(kind: .event, protocolName: "dataSend", topic: "ack"), counter: 0)
        try await harness.client.sendRaw(replayed)
        #expect(await harness.client.isDropped())
        #expect(await eventually { await server.connectionCount == 0 })
        await server.stop()
    }

    @Test func oversizedFrameClosesTheConnection() async throws {
        let server = makeServer()
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        try await harness.client.sendRaw(Data([0x01, 0x10, 0x00, 0x00]) + Data(count: 64))
        #expect(await harness.client.isDropped())
        await server.stop()
    }

    @Test func requestTimeoutClosesTheConnection() async throws {
        let server = makeServer()
        let received = Mailbox<DataStreamConnection>()
        await server.setHandler(protocol: "dataSend") { _, connection in await received.append(connection) }
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        try await harness.client.send(HDSMessage(kind: .event, protocolName: "dataSend", topic: "ack"))
        let connection = try #require(await received.next())

        let start = ContinuousClock.now
        await #expect(throws: HDSConnectionError.timeout) {
            _ = try await connection.sendRequest(protocol: "dataSend", topic: "close", body: HDSDictionary(), timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start >= .milliseconds(250))
        #expect(connection.isClosed)
        let request = try await harness.client.receiveMessage()   // the request itself was delivered
        #expect(request.topic == "close")
        #expect(await harness.client.isDropped())
        await server.stop()
    }

    @Test func closedConnectionRejectsSendsAndReportsCloseImmediately() async throws {
        let server = makeServer()
        let received = Mailbox<DataStreamConnection>()
        await server.setHandler(protocol: "dataSend") { _, connection in await received.append(connection) }
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        try await harness.client.send(HDSMessage(kind: .event, protocolName: "dataSend", topic: "ack"))
        let connection = try #require(await received.next())

        let closeCount = Mailbox<Int>()
        connection.onClose { Task { await closeCount.append(1) } }
        await connection.close()
        await connection.close()   // idempotent
        #expect(connection.isClosed)
        #expect(await harness.client.isDropped())
        await #expect(throws: HDSConnectionError.closed) {
            try await connection.sendEvent(protocol: "dataSend", topic: "data", body: HDSDictionary())
        }
        await #expect(throws: HDSConnectionError.closed) {
            _ = try await connection.sendRequest(protocol: "dataSend", topic: "close", body: HDSDictionary())
        }
        let late = Mailbox<Int>()
        connection.onClose { Task { await late.append(1) } }   // already closed: runs at once
        #expect(await late.next() == 1)
        #expect(await closeCount.next() == 1)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await closeCount.count == 0)   // exactly once
        #expect(await eventually { await server.connectionCount == 0 })
        await server.stop()
    }

    @Test func pendingRequestFailsWhenTheConnectionCloses() async throws {
        let server = makeServer()
        let received = Mailbox<DataStreamConnection>()
        await server.setHandler(protocol: "dataSend") { _, connection in await received.append(connection) }
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        try await harness.client.send(HDSMessage(kind: .event, protocolName: "dataSend", topic: "ack"))
        let connection = try #require(await received.next())
        let outcome = Task { try await connection.sendRequest(protocol: "dataSend", topic: "close", body: HDSDictionary(), timeout: .seconds(20)) }
        _ = try await harness.client.receiveMessage()
        await harness.client.close()
        await #expect(throws: HDSConnectionError.closed) { _ = try await outcome.value }
        await server.stop()
    }

    @Test func stopClosesConnectionsAndServerCanRestart() async throws {
        let server = makeServer()
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        let pending = try await connect(server)   // accepted, never says hello
        await server.stop()
        #expect(await harness.client.isDropped())
        #expect(await pending.client.isDropped())
        #expect(await server.connectionCount == 0)
        #expect(await server.preparedSessionCount == 0)

        let again = try await connect(server)
        #expect(try await again.client.hello().kind == .response(id: 1, status: .success))
        await server.stop()
    }

    // MARK: - Dispatch

    @Test func unhandledRequestsGetMissingProtocolAndUnhandledEventsAreIgnored() async throws {
        let server = makeServer()
        await server.setHandler(protocol: "dataSend") { message, connection in
            try? await connection.sendResponse(to: message, status: .success, body: HDSDictionary())
        }
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        try await harness.client.send(HDSMessage(kind: .event, protocolName: "siri", topic: "audio"))
        try await harness.client.send(HDSMessage(kind: .request(id: 5), protocolName: "targetControl", topic: "whoami"))
        #expect(try await harness.client.receiveMessage() ==
            HDSMessage(kind: .response(id: 5, status: .missingProtocol), protocolName: "targetControl", topic: "whoami"))
        try await harness.client.send(HDSMessage(kind: .request(id: 6), protocolName: "dataSend", topic: "open", body: Self.openBody))
        #expect(try await harness.client.receiveMessage().kind == .response(id: 6, status: .success))
        await server.stop()
    }

    @Test func handlerRegisteredLaterAndReplacedHandlersApply() async throws {
        let server = makeServer()
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        let first = Mailbox<String>()
        await server.setHandler(protocol: "dataSend") { message, _ in await first.append(message.topic) }
        try await harness.client.send(HDSMessage(kind: .event, protocolName: "dataSend", topic: "one"))
        #expect(await first.next() == "one")
        let second = Mailbox<String>()
        await server.setHandler(protocol: "dataSend") { message, _ in await second.append(message.topic) }
        try await harness.client.send(HDSMessage(kind: .event, protocolName: "dataSend", topic: "two"))
        #expect(await second.next() == "two")
        #expect(await first.count == 0)
        await server.stop()
    }

    @Test func framesSplitAcrossWritesAndCoalescedAreHandledInOrder() async throws {
        let server = makeServer()
        let received = Mailbox<String>()
        await server.setHandler(protocol: "dataSend") { message, connection in
            await received.append(message.topic)
            if case .request = message.kind { try? await connection.sendResponse(to: message, status: .success, body: HDSDictionary()) }
        }
        let harness = try await connect(server)
        let hello = try await harness.client.seal(HDSMessage(kind: .request(id: 1), protocolName: "control", topic: "hello"))
        for byte in hello { try await harness.client.sendRaw(Data([byte])) }
        #expect(try await harness.client.receiveMessage().kind == .response(id: 1, status: .success))

        var batch = Data()
        for index in 0..<30 {
            batch += try await harness.client.seal(HDSMessage(kind: .event, protocolName: "dataSend", topic: "e\(index)"))
        }
        batch += try await harness.client.seal(HDSMessage(kind: .request(id: 2), protocolName: "dataSend", topic: "last"))
        try await harness.client.sendRaw(batch)
        #expect(try await harness.client.receiveMessage().kind == .response(id: 2, status: .success))
        #expect(await received.all == (0..<30).map { "e\($0)" } + ["last"])
        await server.stop()
    }

    /// Frames sent concurrently from many tasks still leave in nonce order (the client decrypts every one).
    @Test func concurrentSendsKeepNonceOrder() async throws {
        let server = makeServer()
        let received = Mailbox<DataStreamConnection>()
        await server.setHandler(protocol: "dataSend") { _, connection in await received.append(connection) }
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        try await harness.client.send(HDSMessage(kind: .event, protocolName: "dataSend", topic: "ack"))
        let connection = try #require(await received.next())

        let count = 100
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    try await connection.sendEvent(protocol: "dataSend", topic: "data",
                                                   body: HDSDictionary([("n", .int(Int64(index))), ("pad", .data(Data(count: index * 100)))]))
                }
            }
            try await group.waitForAll()
        }
        var seen = Set<Int64>()
        for _ in 0..<count {
            let message = try await harness.client.receiveMessage()
            if case .int(let n)? = message.body["n"] { seen.insert(n) }
        }
        #expect(seen.count == count)
        await server.stop()
    }

    /// Messages still queued for a busy handler are not dispatched once the connection has closed.
    @Test func queuedMessagesAreDroppedWhenTheConnectionCloses() async throws {
        let server = makeServer()
        let gate = Gate()
        let received = Mailbox<HDSMessage>()
        let connections = Mailbox<DataStreamConnection>()
        await server.setHandler(protocol: "dataSend") { message, connection in
            await received.append(message)
            await connections.append(connection)
            await gate.wait()
        }
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        try await harness.client.send(HDSMessage(kind: .event, protocolName: "dataSend", topic: "ack"))
        let connection = try #require(await connections.next())
        #expect(await received.next()?.topic == "ack")

        try await harness.client.send(HDSMessage(kind: .request(id: 9), protocolName: "dataSend", topic: "open", body: Self.openBody))
        // A later hello is answered by the reader itself, so its response proves "open" is queued behind the handler.
        #expect(try await harness.client.hello(id: 2).kind == .response(id: 2, status: .success))
        #expect(await connection.queuedMessageCount == 2)

        harness.session.close()
        #expect(await eventually { connection.isClosed })
        await gate.open()
        #expect(await eventually { await connection.isDispatchFinished })
        #expect(await received.count == 0)
        #expect(await harness.client.isDropped())
        await server.stop()
    }

    /// A response the codec cannot represent (status outside 0–6) fails its request at once instead of timing out and
    /// closing the connection.
    @Test func responseWithUnknownStatusFailsItsRequestAtOnce() async throws {
        let server = makeServer()
        let received = Mailbox<DataStreamConnection>()
        await server.setHandler(protocol: "dataSend") { _, connection in await received.append(connection) }
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        try await harness.client.send(HDSMessage(kind: .event, protocolName: "dataSend", topic: "ack"))
        let connection = try #require(await received.next())

        let start = ContinuousClock.now
        let outcome = Task { try await connection.sendRequest(protocol: "dataSend", topic: "close", body: HDSDictionary(), timeout: .seconds(20)) }
        let request = try await harness.client.receiveMessage()
        guard case .request(let id) = request.kind else {
            Issue.record("expected a request, got \(request)")
            return
        }
        let header = HDSDictionary([("protocol", .string("dataSend")), ("response", .string("close")), ("id", .int(id)), ("status", .int(9))])
        try await harness.client.sendPayload(try rawPayload(header: header))
        await #expect(throws: HDSFrameError.invalidStatus(9)) { _ = try await outcome.value }
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(!connection.isClosed)

        // The connection keeps working.
        try await connection.sendEvent(protocol: "dataSend", topic: "data", body: HDSDictionary())
        #expect(try await harness.client.receiveMessage().topic == "data")
        await server.stop()
    }

    /// A request whose header is readable but whose message part is not gets `.payloadError`; the handler never sees it.
    @Test func requestWithUndecodableBodyIsAnsweredWithPayloadError() async throws {
        let server = makeServer()
        let received = Mailbox<HDSMessage>()
        await server.setHandler(protocol: "dataSend") { message, _ in await received.append(message) }
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        let header = HDSDictionary([("protocol", .string("dataSend")), ("request", .string("open")), ("id", .int(11))])
        try await harness.client.sendPayload(try rawPayload(header: header, message: Data([0x00])))       // invalid tag
        #expect(try await harness.client.receiveMessage() ==
            HDSMessage(kind: .response(id: 11, status: .payloadError), protocolName: "dataSend", topic: "open"))
        try await harness.client.sendPayload(try rawPayload(header: header, message: try HDSCodec.encode(.int(1))))   // not a dictionary
        #expect(try await harness.client.receiveMessage() ==
            HDSMessage(kind: .response(id: 11, status: .payloadError), protocolName: "dataSend", topic: "open"))
        // An undecodable event is dropped; the connection stays up.
        let event = HDSDictionary([("protocol", .string("dataSend")), ("event", .string("ack"))])
        try await harness.client.sendPayload(try rawPayload(header: event, message: Data([0x00])))
        try await harness.client.send(HDSMessage(kind: .event, protocolName: "dataSend", topic: "ack"))
        #expect(await received.next() == HDSMessage(kind: .event, protocolName: "dataSend", topic: "ack"))
        #expect(await received.count == 0)
        await server.stop()
    }

    private func rawPayload(header: HDSDictionary, message: Data? = nil) throws -> Data {
        let encodedHeader = try HDSCodec.encode(.dictionary(header))
        return Data([UInt8(encodedHeader.count)]) + encodedHeader + (try message ?? HDSCodec.encode(.dictionary(HDSDictionary())))
    }

    @Test func secondHelloIsAnsweredToo() async throws {
        let server = makeServer()
        let harness = try await connect(server)
        _ = try await harness.client.hello(id: 1)
        #expect(try await harness.client.hello(id: 2).kind == .response(id: 2, status: .success))
        await server.stop()
    }

    @Test func largeRecordingSizedEventsArrive() async throws {
        let server = makeServer()
        let received = Mailbox<DataStreamConnection>()
        await server.setHandler(protocol: "dataSend") { _, connection in await received.append(connection) }
        let harness = try await connect(server)
        _ = try await harness.client.hello()
        try await harness.client.send(HDSMessage(kind: .event, protocolName: "dataSend", topic: "ack"))
        let connection = try #require(await received.next())
        let chunk = Data((0..<0x40000).map { UInt8(truncatingIfNeeded: $0 &* 31) })   // brief §3.8 maximum chunk
        let body = HDSDictionary([("streamId", .int(1)), ("packets", .array([.dictionary(HDSDictionary([("data", .data(chunk))]))]))])
        try await connection.sendEvent(protocol: "dataSend", topic: "data", body: body)
        #expect(try await harness.client.receiveMessage().body == body)
        let tooLarge = HDSDictionary([("data", .data(Data(count: 0x100000)))])
        let tooLargeCount = try HDSFrameCodec.encodePayload(HDSMessage(kind: .event, protocolName: "dataSend", topic: "data", body: tooLarge)).count
        await #expect(throws: HDSFrameError.payloadTooLarge(tooLargeCount)) {
            try await connection.sendEvent(protocol: "dataSend", topic: "data", body: tooLarge)
        }
        #expect(!connection.isClosed)
        await server.stop()
    }
}
#endif
