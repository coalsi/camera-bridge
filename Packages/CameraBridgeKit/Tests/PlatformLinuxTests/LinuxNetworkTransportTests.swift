#if os(Linux)
import BridgeSupport
import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Testing
@testable import PlatformLinux

/// Loopback only (127.0.0.1 and ::1): nothing here leaves the machine.
@Suite(.timeLimit(.minutes(1))) struct LinuxNetworkTransportTests {
    let transport = LinuxNetworkTransport()

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
        #expect(received == payload, "everything sent before close() arrives")
        #expect(withinLimit)
    }

    /// Closing a connection with unread data must not reset it: the peer would lose what it has not read yet.
    @Test func closingWithUnreadDataStillDeliversWhatWasSent() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        defer { listener.close() }
        let client = try await transport.connect(host: "127.0.0.1", port: listener.port, timeout: .seconds(5))
        var iterator = listener.connections.makeAsyncIterator()
        let server = try #require(await iterator.next())
        defer { server.close() }
        try await server.send(Data("unread by the client".utf8))
        try await client.send(Data("ack".utf8))
        try await Task.sleep(for: .milliseconds(100))   // the client's receive queue now holds data it never reads
        client.close()
        var received = Data()
        while let chunk = try await server.receive(maximumLength: 64) { received.append(chunk) }
        #expect(String(decoding: received, as: UTF8.self) == "ack")
    }

    @Test func acceptsSeveralConnections() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        defer { listener.close() }
        let transport = self.transport
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

    @Test func connectsByNameAndTriesEveryAddress() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        defer { listener.close() }
        // "localhost" may resolve to ::1 first; the connection still gets through on 127.0.0.1.
        let client = try await transport.connect(host: "localhost", port: listener.port, timeout: .seconds(5))
        client.close()
    }

    @Test func rejectsAnInvalidAddress() async throws {
        await #expect(throws: TransportError.self) { _ = try await transport.connect(host: "  ", port: 80, timeout: .seconds(1)) }
        await #expect(throws: TransportError.self) { _ = try await transport.connect(host: "127.0.0.1", port: 0, timeout: .seconds(1)) }
    }

    @Test func listeningOnABoundPortFailsWithAddressInUse() async throws {
        let first = try await transport.listen(port: 0, loopbackOnly: true)
        defer { first.close() }
        await #expect(throws: TransportError.addressInUse) {
            let second = try await transport.listen(port: first.port, loopbackOnly: true)
            second.close()
        }
    }

    /// An all-interfaces listener must not share its port with another process's 127.0.0.1-only listener (which would keep
    /// every loopback connection).
    @Test func listeningOnEveryInterfaceRefusesAPortHeldOnLoopback() async throws {
        let loopback = try await transport.listen(port: 0, loopbackOnly: true)
        defer { loopback.close() }
        await #expect(throws: TransportError.addressInUse) {
            let everywhere = try await transport.listen(port: loopback.port, loopbackOnly: false)
            everywhere.close()
        }
    }

    @Test func fixedPortRebindsWhileConnectionsAreInTimeWait() async throws {
        let first = try await transport.listen(port: 0, loopbackOnly: true)
        let port = first.port
        let client = try await transport.connect(host: "127.0.0.1", port: port, timeout: .seconds(5))
        var iterator = first.connections.makeAsyncIterator()
        let server = try #require(await iterator.next())
        server.close()   // the side that closes first keeps the TIME_WAIT
        #expect(try await client.receive(maximumLength: 16) == nil)
        client.close()
        first.close()
        var rebound: (any TCPListener)?
        for _ in 0..<20 {   // a closed listener releases its socket asynchronously
            rebound = try? await transport.listen(port: port, loopbackOnly: true)
            if rebound != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(rebound?.port == port)
        rebound?.close()
    }

    @Test func acceptedConnectionsGetKeepaliveAndOutboundOnesDoNot() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        defer { listener.close() }
        let client = try await transport.connect(host: "127.0.0.1", port: listener.port, timeout: .seconds(5))
        defer { client.close() }
        var iterator = listener.connections.makeAsyncIterator()
        let server = try #require(await iterator.next())
        defer { server.close() }

        func option(_ connection: any TCPConnection, _ level: Int32, _ name: Int32) -> Int32? {
            let linux = connection as? LinuxTCPConnection
            return linux?.socketOption(level: level, name: name)
        }
        let tcp = Int32(IPPROTO_TCP)
        #expect(option(server, SOL_SOCKET, SO_KEEPALIVE) == 1)
        #expect(option(server, tcp, TCP_KEEPIDLE) == 30)
        #expect(option(server, tcp, TCP_KEEPINTVL) == 10)
        #expect(option(server, tcp, TCP_KEEPCNT) == 3)
        #expect(option(server, tcp, TCP_USER_TIMEOUT) == 20_000)
        #expect(option(server, tcp, TCP_NODELAY) == 1)
        #expect(option(client, SOL_SOCKET, SO_KEEPALIVE) == 0, "outbound connections (cameras) keep the system's defaults")
        #expect(option(client, tcp, TCP_NODELAY) == 1)
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

    @Test func aStalledPeerBlocksSendUntilItReads() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        defer { listener.close() }
        let client = try await transport.connect(host: "127.0.0.1", port: listener.port, timeout: .seconds(5))
        defer { client.close() }
        var iterator = listener.connections.makeAsyncIterator()
        let server = try #require(await iterator.next())
        defer { server.close() }
        let big = Data(repeating: 0x5A, count: 32 << 20)   // far more than the socket buffers hold
        let sending = Task { try await client.send(big) }
        try await Task.sleep(for: .milliseconds(200))
        var total = 0
        while total < big.count, let chunk = try await server.receive(maximumLength: 1 << 20) { total += chunk.count }
        try await sending.value
        #expect(total == big.count)
    }

    @Test func mapsSystemErrors() {
        #expect(LinuxNetworkTransport.transportError(errno: ECONNREFUSED) == .connectionRefused)
        #expect(LinuxNetworkTransport.transportError(errno: ETIMEDOUT) == .timedOut)
        #expect(LinuxNetworkTransport.transportError(errno: EADDRINUSE) == .addressInUse)
        for code in [ECONNRESET, EPIPE, ENOTCONN, ECONNABORTED] {
            #expect(LinuxNetworkTransport.transportError(errno: code) == .closed)
        }
        if case .failed = LinuxNetworkTransport.transportError(errno: EHOSTUNREACH) {} else { Issue.record("EHOSTUNREACH should be .failed") }
    }

    @Test func formatsAddressesAsBareIPLiterals() throws {
        func storage(_ text: String) throws -> sockaddr_storage {
            try #require(SocketAddresses.numeric(host: text, port: 80)).storage
        }
        #expect(SocketAddresses.address(of: try storage("192.0.2.5")) == IPEndpointAddress(host: "192.0.2.5", isIPv6: false, zone: nil))
        #expect(SocketAddresses.address(of: try storage("2001:db8::7")) == IPEndpointAddress(host: "2001:db8::7", isIPv6: true, zone: nil))
        #expect(SocketAddresses.address(of: try storage("::ffff:192.0.2.9")) == IPEndpointAddress(host: "192.0.2.9", isIPv6: false, zone: nil),
                "IPv4-mapped IPv6 is reported as IPv4")
        #expect(SocketAddresses.port(of: try storage("192.0.2.5")) == 80)
        #expect(SocketAddresses.numeric(host: "camera.example", port: 80) == nil)
    }

    @Test func keepsTheZoneOfALinkLocalAddress() throws {
        let storage = try #require(SocketAddresses.numeric(host: "fe80::1%lo", port: 80)).storage
        let address = try #require(SocketAddresses.address(of: storage))
        #expect(address.host == "fe80::1" && address.isIPv6 && address.zone == "lo")
    }
}

/// Dual stack: an IPv4 client arrives on the IPv6 socket as an IPv4-mapped address and is reported as IPv4. Binds every
/// interface (the sandbox of a test run has nothing else on the network).
@Suite(.timeLimit(.minutes(1))) struct EveryInterfaceListenerTests {
    let transport = LinuxNetworkTransport()

    @Test func servesIPv4AndIPv6LoopbackClients() async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: false)
        defer { listener.close() }
        #expect(listener.port != 0)
        let hosts = ipv6Available() ? ["127.0.0.1", "::1"] : ["127.0.0.1"]
        let server = Task { () -> [String] in
            var seen: [String] = []
            for await connection in listener.connections {
                defer { connection.close() }
                if let data = try? await connection.receive(maximumLength: 64) { try? await connection.send(data) }
                seen.append("\(connection.remoteAddress) \(connection.localAddress) \(connection.isIPv6)")
                if seen.count == hosts.count { break }
            }
            return seen
        }
        for host in hosts {
            let client = try await transport.connect(host: host, port: listener.port, timeout: .seconds(5))
            defer { client.close() }
            #expect(client.remoteAddress == host && client.isIPv6 == host.contains(":"))
            try await client.send(Data(host.utf8))
            var received = Data()
            while received.count < host.utf8.count, let chunk = try await client.receive(maximumLength: 64) { received.append(chunk) }
            #expect(received == Data(host.utf8), "echo over \(host)")
        }
        #expect(await server.value == hosts.map { "\($0) \($0) \($0.contains(":"))" })
    }

    private func ipv6Available() -> Bool {
        var storage = SocketAddresses.local(port: 0, family: AF_INET6, loopback: true)
        let descriptor = Glibc.socket(AF_INET6, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor >= 0 else { return false }
        defer { _ = Glibc.close(descriptor) }
        return withUnsafePointer(to: &storage.storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.bind(descriptor, $0, storage.length) }
        } == 0
    }
}
#endif
