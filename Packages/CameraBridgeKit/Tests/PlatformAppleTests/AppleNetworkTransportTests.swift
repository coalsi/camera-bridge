#if os(macOS)
import BridgeSupport
import Foundation
import Network
import Testing
@testable import PlatformApple

/// Loopback only (127.0.0.1): nothing here leaves the machine.
@Suite(.timeLimit(.minutes(1))) struct AppleNetworkTransportTests {
    let transport = AppleNetworkTransport()

    @Test func loopbackEchoRoundTrip() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        defer { listener.close() }
        #expect(listener.port != 0)

        let echo = Task {
            var iterator = listener.connections.makeAsyncIterator()
            guard let connection = await iterator.next() else { return (local: "", remote: "", ipv6: true) }
            defer { connection.close() }
            while let data = try await connection.receive(maximumLength: 4096) {
                try await connection.send(data)
            }
            return (local: connection.localAddress, remote: connection.remoteAddress, ipv6: connection.isIPv6)
        }

        let client = try await transport.connect(host: "127.0.0.1", port: listener.port, timeout: .seconds(5))
        #expect(client.localAddress == "127.0.0.1" && client.remoteAddress == "127.0.0.1" && !client.isIPv6)
        try await client.send(Data("hello, ".utf8))
        try await client.send(Data("camera".utf8))
        var received = Data()
        while received.count < 13, let chunk = try await client.receive(maximumLength: 4096) { received.append(chunk) }
        #expect(String(decoding: received, as: UTF8.self) == "hello, camera")
        client.close()

        let server = try await echo.value
        #expect(server.local == "127.0.0.1" && server.remote == "127.0.0.1" && !server.ipv6)
    }

    @Test func receiveReturnsNilAfterPeerClosesAndRespectsMaximumLength() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        defer { listener.close() }
        let reader = Task {
            var iterator = listener.connections.makeAsyncIterator()
            guard let connection = await iterator.next() else { return (Data(), false, true) }
            defer { connection.close() }
            var total = Data()
            var withinLimit = true
            while let chunk = try await connection.receive(maximumLength: 1000) {
                withinLimit = withinLimit && chunk.count <= 1000 && !chunk.isEmpty
                total.append(chunk)
            }
            return (total, withinLimit, false)
        }
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let client = try await transport.connect(host: "127.0.0.1", port: listener.port, timeout: .seconds(5))
        try await client.send(payload)
        client.close()
        let (received, withinLimit, missing) = try await reader.value
        #expect(!missing)
        #expect(received == payload)
        #expect(withinLimit)
    }

    @Test func acceptsSeveralConnections() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        defer { listener.close() }
        let clients = try await withThrowingTaskGroup(of: (any TCPConnection).self) { group in
            for _ in 0..<3 { group.addTask { try await transport.connect(host: "127.0.0.1", port: listener.port, timeout: .seconds(5)) } }
            return try await group.reduce(into: [any TCPConnection]()) { $0.append($1) }
        }
        defer { clients.forEach { $0.close() } }
        var accepted: [any TCPConnection] = []
        for await connection in listener.connections {
            accepted.append(connection)
            if accepted.count == 3 { break }
        }
        defer { accepted.forEach { $0.close() } }
        #expect(Set(accepted.map(\.id)).count == 3)
        #expect(Set(clients.map(\.id)).isDisjoint(with: accepted.map(\.id)))
    }

    @Test func connectingToAClosedPortIsRefused() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        let port = listener.port
        listener.close()
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: TransportError.connectionRefused) {
            _ = try await transport.connect(host: "127.0.0.1", port: port, timeout: .seconds(5))
        }
    }

    @Test func listeningOnABoundPortFailsWithAddressInUse() async throws {
        let first = try await transport.listen(port: 0, loopbackOnly: true)
        defer { first.close() }
        await #expect(throws: TransportError.addressInUse) {
            let second = try await transport.listen(port: first.port, loopbackOnly: true)
            second.close()
        }
    }

    /// With address reuse the kernel lets an all-interfaces listener share a port with a 127.0.0.1-only socket (which
    /// would keep every loopback connection); the pre-bind probe reports it. The probe tries 127.0.0.1 first, so this
    /// test binds nothing but loopback.
    @Test func listeningOnEveryInterfaceRefusesAPortHeldOnLoopback() async throws {
        let loopback = try await transport.listen(port: 0, loopbackOnly: true)
        defer { loopback.close() }
        await #expect(throws: TransportError.addressInUse) {
            let everywhere = try await transport.listen(port: loopback.port, loopbackOnly: false)
            everywhere.close()
        }
    }

    @Test func portProbeFindsOnlyTheHeldAddress() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        let port = listener.port
        #expect(ListenerPortProbe.firstConflict(port: port, among: [.ipv6(.loopback), .ipv4(.loopback)]) == .ipv4(.loopback))
        #expect(ListenerPortProbe.firstConflict(port: port, among: [.ipv6(.loopback)]) == nil)
        listener.close()
        let released = try await retryingWhileInUse { () async throws(TransportError) -> Bool in
            if ListenerPortProbe.firstConflict(port: port, among: [.ipv4(.loopback)]) != nil { throw .addressInUse }
            return true
        }
        #expect(released)
    }

    @Test func probeAddressesStartWithLoopback() {
        let all = ListenerPortProbe.addresses(loopbackOnly: false)
        #expect(Array(all.prefix(4)) == [.ipv4(.loopback), .ipv6(.loopback), .ipv4(.any), .ipv6(.any)])
        #expect(Set(all).count == all.count)
        #expect(ListenerPortProbe.addresses(loopbackOnly: true) == [.ipv4(.loopback), .ipv4(.any)])
        let interfaces = ListenerPortProbe.interfaceAddresses()
        #expect(interfaces.contains(.ipv4(.loopback)) && interfaces.contains(.ipv6(.loopback)))
        #expect(!interfaces.contains { if case .ipv6(let address, 0) = $0 { address.isLinkLocal } else { false } })
    }

    /// Address reuse is what lets a fixed port rebind while the previous listener's connections sit in TIME_WAIT;
    /// the probe must not undo that.
    @Test func fixedPortRebindsWhileConnectionsAreInTimeWait() async throws {
        let first = try await transport.listen(port: 0, loopbackOnly: true)
        let port = first.port
        let server = Task {
            var iterator = first.connections.makeAsyncIterator()
            await iterator.next()?.close()   // the server closes first, so its side enters TIME_WAIT
        }
        let client = try await transport.connect(host: "127.0.0.1", port: port, timeout: .seconds(5))
        await server.value
        #expect(try await client.receive(maximumLength: 16) == nil)
        client.close()
        first.close()
        let second = try await retryingWhileInUse { () async throws(TransportError) -> any TCPListener in
            do {
                // Loopback-only probe list: tests never bind other interfaces.
                return try await AppleTCPListener.start(port: port, loopbackOnly: true, probing: [.ipv4(.loopback)])
            } catch {
                throw AppleNetworkTransport.transportError(error)
            }
        }
        #expect(second.port == port)
        second.close()
    }

    /// Review finding (flaky `cbctl record`): a server that closes a loopback connection first leaves its side in
    /// TIME_WAIT (127.0.0.1:S ↔ 127.0.0.1:C). Once the client's socket is gone, a new listener can get port C, and
    /// Network.framework then gives a connection to C the local port S: that 4-tuple exists, so the connection sat in
    /// `.waiting(EADDRINUSE)` until the timeout (a plain new `NWConnection` is given S again). `connect` must get through
    /// from another local port, well within its timeout.
    @Test func connectsWhenTheOfferedLocalPortIsInTimeWait() async throws {
        // Without TCP keepalive on the accepted connection: with it Network.framework no longer hands the client's old port
        // out as this scenario needs (the retry path is then not reached, and nothing is left to test here).
        let server = try await AppleTCPListener.start(port: 0, loopbackOnly: true, probing: [], keepalive: false)
        defer { server.close() }
        let closedByServer = Task {
            var iterator = server.connections.makeAsyncIterator()
            await iterator.next()?.close()   // the server closes first, so its side enters TIME_WAIT
        }
        let client = try await transport.connect(host: "127.0.0.1", port: server.port, timeout: .seconds(5))
        let clientPort = try #require((client as? AppleTCPConnection)?.localPort)
        await closedByServer.value
        #expect(try await client.receive(maximumLength: 16) == nil)
        client.close()

        // A listener on the client's old port (free once the client's side has closed).
        let listener = try await retryingWhileInUse { () async throws(TransportError) -> any TCPListener in
            do {
                return try await AppleTCPListener.start(port: clientPort, loopbackOnly: true, probing: [.ipv4(.loopback)])
            } catch {
                throw AppleNetworkTransport.transportError(error)
            }
        }
        defer { listener.close() }
        let accepted = Task { () -> Bool in
            var iterator = listener.connections.makeAsyncIterator()
            guard let connection = await iterator.next() else { return false }
            connection.close()
            return true
        }
        let started = ContinuousClock.now
        let connection = try await transport.connect(host: "127.0.0.1", port: clientPort, timeout: .seconds(5))
        defer { connection.close() }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await accepted.value)
        let apple = try #require(connection as? AppleTCPConnection)
        #expect(apple.localPort != nil && apple.localPort != server.port)
        // The scenario does hand out S first (Network.framework, macOS 27): the retry path ran.
        #expect(apple.connectAttempts == 2)
    }

    /// Review finding (RTP coverage): the app's HAP, HDS and webhook listeners serve every interface, a path no test
    /// reached. The listeners are built here but never started, so nothing is bound: every interface means no required
    /// local address and both IP versions; `loopbackOnly` requires 127.0.0.1 at the requested port. Both reuse addresses.
    /// (`EveryInterfaceListenerTests` starts one, opt-in.)
    @Test func everyInterfaceListenerRequiresNoLocalAddress() throws {
        let everywhere = try AppleTCPListener.makeListener(port: 51_234, loopbackOnly: false)
        defer { everywhere.cancel() }
        #expect(everywhere.parameters.requiredLocalEndpoint == nil)
        #expect(everywhere.parameters.allowLocalEndpointReuse)
        #expect(!everywhere.parameters.includePeerToPeer)
        let ip = everywhere.parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options
        #expect(ip?.version == .any, "dual stack")
        #expect((everywhere.parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay == true)

        let loopback = try AppleTCPListener.makeListener(port: 51_234, loopbackOnly: true)
        defer { loopback.cancel() }
        #expect(loopback.parameters.requiredLocalEndpoint == .hostPort(host: .ipv4(.loopback), port: 51_234))
        #expect(loopback.parameters.allowLocalEndpointReuse)

        let anyPort = try AppleTCPListener.makeListener(port: 0, loopbackOnly: true)
        defer { anyPort.cancel() }
        #expect(anyPort.parameters.requiredLocalEndpoint == .hostPort(host: .ipv4(.loopback), port: .any))
    }

    /// Hardening plan WS-C 1: a controller that vanished without a FIN or RST (Wi-Fi dropped, the hub slept) must be
    /// noticed, or its HAP/HDS connection keeps a stream session or the recording slot "in use" for good. The options
    /// are on the listener (accepted connections inherit them), not on outbound connections (cameras keep the system's).
    @Test func listenersAcceptConnectionsWithTCPKeepaliveAndADropTime() throws {
        for loopbackOnly in [true, false] {
            let listener = try AppleTCPListener.makeListener(port: 51_235, loopbackOnly: loopbackOnly)
            defer { listener.cancel() }
            let tcp = try #require(listener.parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
            #expect(tcp.enableKeepalive)
            #expect(tcp.keepaliveIdle == 30)
            #expect(tcp.keepaliveInterval == 10)
            #expect(tcp.keepaliveCount == 3)
            #expect(tcp.connectionDropTime == 20)
            #expect(tcp.noDelay)
        }
        let outbound = try #require(AppleNetworkTransport.parameters().defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
        #expect(!outbound.enableKeepalive, "outbound connections (cameras) keep the system's defaults")
    }

    @Test func loopbackOnlyListenerIsBoundTo127001() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        defer { listener.close() }
        // Not listening on the IPv6 loopback: the connection cannot succeed.
        await #expect(throws: TransportError.self) {
            let connection = try await transport.connect(host: "::1", port: listener.port, timeout: .seconds(2))
            connection.close()
        }
    }

    @Test func closingTheListenerFinishesConnections() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        let drained = Task { for await connection in listener.connections { connection.close() } }
        listener.close()
        listener.close()   // idempotent
        await drained.value
    }

    @Test func localCloseFailsPendingReceiveAndLaterSends() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        defer { listener.close() }
        let client = try await transport.connect(host: "127.0.0.1", port: listener.port, timeout: .seconds(5))
        var iterator = listener.connections.makeAsyncIterator()
        let server = try #require(await iterator.next())
        defer { server.close() }
        let pending = Task { try await client.receive(maximumLength: 16) }
        try await Task.sleep(for: .milliseconds(100))
        client.close()
        await #expect(throws: TransportError.closed) { _ = try await pending.value }
        await #expect(throws: TransportError.closed) { try await client.send(Data([1])) }
        // The peer sees an orderly EOF.
        #expect(try await server.receive(maximumLength: 16) == nil)
    }

    @Test func cancellingAReceivingTaskClosesTheConnection() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        defer { listener.close() }
        let client = try await transport.connect(host: "127.0.0.1", port: listener.port, timeout: .seconds(5))
        var iterator = listener.connections.makeAsyncIterator()
        let server = try #require(await iterator.next())
        defer { server.close() }
        let pending = Task { try await client.receive(maximumLength: 16) }
        try await Task.sleep(for: .milliseconds(100))
        pending.cancel()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        #expect(try await server.receive(maximumLength: 16) == nil)
    }

    @Test func mapsNetworkErrors() {
        #expect(AppleNetworkTransport.transportError(.posix(.ECONNREFUSED)) == .connectionRefused)
        #expect(AppleNetworkTransport.transportError(.posix(.ETIMEDOUT)) == .timedOut)
        #expect(AppleNetworkTransport.transportError(.posix(.EADDRINUSE)) == .addressInUse)
        #expect(AppleNetworkTransport.transportError(.posix(.ECANCELED)) == .closed)
        #expect(AppleNetworkTransport.transportError(.posix(.ECONNRESET)) == .closed)
        #expect(AppleNetworkTransport.transportError(.dns(-65570)) == .localNetworkDenied)
        if case .failed(let message) = AppleNetworkTransport.transportError(.posix(.EHOSTUNREACH)) {
            #expect(!message.isEmpty)
        } else {
            Issue.record("EHOSTUNREACH should map to .failed")
        }
    }

    @Test func formatsAddressesAsBareIPLiterals() throws {
        #expect(AppleNetworkTransport.ipLiteral(.ipv4(.loopback)) == ("127.0.0.1", false))
        #expect(AppleNetworkTransport.ipLiteral(.ipv6(.loopback)) == ("::1", true))
        let scoped = try #require(IPv6Address("fe80::1%lo0"))
        #expect(AppleNetworkTransport.ipLiteral(.ipv6(scoped)) == ("fe80::1", true))
        let mapped = try #require(IPv6Address("::ffff:192.168.1.20"))
        #expect(AppleNetworkTransport.ipLiteral(.ipv6(mapped)) == ("192.168.1.20", false))
    }

    /// Review finding (W4 round 4): the zone of a link-local HAP connection was dropped with the literal, so nothing
    /// downstream could reach a link-local address the controller names in SetupEndpoints (which carries no scope). It
    /// is kept apart (`TCPConnection.zone`).
    @Test func keepsTheZoneOfALinkLocalAddress() throws {
        #expect(AppleNetworkTransport.zone(.ipv6(try #require(IPv6Address("fe80::1%lo0")))) == "lo0")
        #expect(AppleNetworkTransport.zone(.ipv6(try #require(IPv6Address("fe80::1")))) == nil)
        #expect(AppleNetworkTransport.zone(.ipv6(.loopback)) == nil)
        #expect(AppleNetworkTransport.zone(.ipv4(.loopback)) == nil)
        #expect(AppleNetworkTransport.zone(.ipv6(try #require(IPv6Address("::ffff:192.168.1.20")))) == nil)
        #expect(AppleNetworkTransport.zone(nil as NWEndpoint?) == nil)
        #expect(AppleNetworkTransport.zone(NWEndpoint.hostPort(host: .ipv6(try #require(IPv6Address("fe80::1%lo0"))), port: 80)) == "lo0")
    }
}

/// Opt-in (`CB_WILDCARD_TESTS=1 swift test --filter EveryInterfaceListenerTests`): starts listeners on every interface,
/// as the app's HAP, HDS and webhook servers do. They are reachable from the LAN while the test runs, so this is off by
/// default (the default suites listen on 127.0.0.1 only). Every connection comes from 127.0.0.1 or ::1; nothing is
/// advertised.
@Suite(.timeLimit(.minutes(1)),
       .enabled(if: ProcessInfo.processInfo.environment["CB_WILDCARD_TESTS"] == "1", "set CB_WILDCARD_TESTS=1 to listen on every interface"))
struct EveryInterfaceListenerTests {
    let transport = AppleNetworkTransport()

    /// Dual stack: an IPv4 client arrives on the IPv6 socket as an IPv4-mapped address and is reported as IPv4.
    @Test func servesIPv4AndIPv6LoopbackClients() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: false)
        defer { listener.close() }
        #expect(listener.port != 0)
        let server = Task { () -> [String] in
            var seen: [String] = []
            for await connection in listener.connections {
                defer { connection.close() }
                if let data = try? await connection.receive(maximumLength: 64) { try? await connection.send(data) }
                seen.append("\(connection.remoteAddress) \(connection.localAddress) \(connection.isIPv6)")
                if seen.count == 2 { break }
            }
            return seen
        }
        for host in ["127.0.0.1", "::1"] {
            let client = try await transport.connect(host: host, port: listener.port, timeout: .seconds(5))
            defer { client.close() }
            #expect(client.remoteAddress == host && client.isIPv6 == host.contains(":"))
            try await client.send(Data(host.utf8))
            var received = Data()
            while received.count < host.utf8.count, let chunk = try await client.receive(maximumLength: 64) { received.append(chunk) }
            #expect(received == Data(host.utf8), "echo over \(host)")
        }
        #expect(await server.value == ["127.0.0.1 127.0.0.1 false", "::1 ::1 true"])
    }

    /// A fixed port (the HAP port is fixed per camera) is bound as requested.
    @Test func bindsTheRequestedFixedPort() async throws {
        let probe = try await transport.listen(port: 0, loopbackOnly: true)   // a port that is free right now
        let port = probe.port
        probe.close()
        let listener = try await retryingWhileInUse { () async throws(TransportError) -> any TCPListener in
            do {
                return try await transport.listen(port: port, loopbackOnly: false)
            } catch {
                throw AppleNetworkTransport.transportError(error)
            }
        }
        defer { listener.close() }
        #expect(listener.port == port)
        let accepted = Task { () -> Bool in
            var iterator = listener.connections.makeAsyncIterator()
            guard let connection = await iterator.next() else { return false }
            connection.close()
            return true
        }
        let client = try await transport.connect(host: "127.0.0.1", port: port, timeout: .seconds(5))
        client.close()
        #expect(await accepted.value)
    }
}

/// Runs `body` until it stops throwing `.addressInUse` (a closed listener releases its socket asynchronously), for up
/// to two seconds; the last attempt's error is rethrown.
private func retryingWhileInUse<Value>(_ body: () async throws(TransportError) -> Value) async throws -> Value {
    for _ in 0..<20 {
        do {
            return try await body()
        } catch .addressInUse {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    return try await body()
}
#endif
