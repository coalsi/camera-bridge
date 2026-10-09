import BridgeSupport
import Foundation
import Synchronization
import TestSupport
import Testing
@testable import RTP

/// Loopback only (127.0.0.1 / ::1).
@Suite(.timeLimit(.minutes(1)), .loopback) struct UDPSocketTests {
    @Test func ipv4LoopbackSendAndReceive() async throws {
        let sender = try UDPSocket.bind(host: "127.0.0.1")
        let receiver = try UDPSocket.bind(host: "127.0.0.1")
        defer { sender.close(); receiver.close() }
        #expect(sender.localPort != 0 && receiver.localPort != 0 && sender.localPort != receiver.localPort)

        let payloads = (0..<100).map { index in Data((0..<(index * 14 % 1_400 + 1)).map { UInt8(truncatingIfNeeded: $0 + index) }) }
        let destination = SocketAddress(host: "127.0.0.1", port: receiver.localPort)
        async let received = collectDatagrams(receiver.datagrams, count: payloads.count)
        try await Task.sleep(for: .milliseconds(20))
        for payload in payloads { try sender.send(payload, to: destination) }
        let datagrams = await received
        #expect(datagrams.map(\.data) == payloads)
        #expect(datagrams.allSatisfy { $0.from == SocketAddress(host: "127.0.0.1", port: sender.localPort) })
    }

    @Test func ipv6LoopbackWhenAvailable() async throws {
        guard let sender = try? UDPSocket.bind(host: "::1", ipv6: true), let receiver = try? UDPSocket.bind(host: "::1", ipv6: true) else {
            return   // no IPv6 loopback on this machine
        }
        defer { sender.close(); receiver.close() }
        try sender.send(Data("six".utf8), to: SocketAddress(host: "::1", port: receiver.localPort))
        let datagrams = await collectDatagrams(receiver.datagrams, count: 1)
        #expect(datagrams.first?.data == Data("six".utf8))
        #expect(datagrams.first?.from == SocketAddress(host: "::1", port: sender.localPort))
        #expect(datagrams.first?.from.description == "[::1]:\(sender.localPort)")
    }

    @Test func closeFinishesTheStreamAndLaterSendsThrow() async throws {
        let socket = try UDPSocket.bind(host: "127.0.0.1")
        let port = socket.localPort
        let reader = Task { () -> Int in
            var count = 0
            for await _ in socket.datagrams { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(50))
        socket.close()
        #expect(await reader.value == 0)
        #expect(socket.localPort == port)
        #expect(throws: UDPSocketError.closed) { try socket.send(Data([1]), to: SocketAddress(host: "127.0.0.1", port: 9)) }
        socket.close()   // idempotent
    }

    @Test func droppingTheSocketFinishesTheStream() async throws {
        var socket: UDPSocket? = try UDPSocket.bind(host: "127.0.0.1")
        let stream = try #require(socket?.datagrams)
        socket = nil
        let finished = Task { () -> Bool in
            for await _ in stream {}
            return true
        }
        #expect(await finished.value)
    }

    @Test func invalidAddressesAndBusyPortsThrow() throws {
        #expect(throws: UDPSocketError.self) { try UDPSocket.bind(host: "not an address") }
        #expect(throws: UDPSocketError.self) { try UDPSocket.bind(host: "::1", ipv6: false) }
        #expect(throws: UDPSocketError.self) { try UDPSocket.bind(host: "127.0.0.1", ipv6: true) }
        let socket = try UDPSocket.bind(host: "127.0.0.1")
        defer { socket.close() }
        #expect(throws: UDPSocketError.self) { try UDPSocket.bind(host: "127.0.0.1", port: socket.localPort) }
        #expect(throws: UDPSocketError.self) { try socket.send(Data([1]), to: SocketAddress(host: "no such host ^^", port: 9)) }
        #expect(throws: UDPSocketError.self) { try socket.send(Data([1]), to: SocketAddress(host: "::1", port: 9)) }   // wrong family
    }

    /// A sender that keeps the receive buffer non-empty must not hold up closing (review W1-4: close() and deinit
    /// used to wait for the read loop, which only returned once recvfrom hit EAGAIN).
    @Test(.loopbackFlood) func closingAndDroppingAreNotHeldUpByAFlood() async throws {
        let closed = try UDPSocket.bind(host: "127.0.0.1")
        var dropped: UDPSocket? = try UDPSocket.bind(host: "127.0.0.1")
        let droppedPort = try #require(dropped?.localPort)
        let droppedStream = try #require(dropped?.datagrams)
        let received = Box(0)
        let readers = [closed.datagrams, droppedStream].map { stream in
            Task { () -> Bool in
                for await _ in stream { received.update { $0 += 1 } }
                return true
            }
        }
        let flood = try LoopbackFlood(ports: [closed.localPort, droppedPort], payload: Data(repeating: 0xA5, count: 200))
        #expect(await eventually { received.value > 2_000 }, "the flood did not arrive")

        var started = ContinuousClock.now
        closed.close()
        let closing = ContinuousClock.now - started
        started = .now
        dropped = nil   // deinit
        let dropping = ContinuousClock.now - started
        started = .now
        for reader in readers { #expect(await reader.value) }
        let finishing = ContinuousClock.now - started
        let flooding = flood.sent.load(ordering: .relaxed)
        await flood.stop()

        #expect(closing < .milliseconds(250), "close() took \(closing) during the flood")
        #expect(dropping < .milliseconds(250), "deinit took \(dropping) during the flood")
        #expect(finishing < .milliseconds(500), "the streams finished \(finishing) after closing")
        #expect(flood.sent.load(ordering: .relaxed) > flooding, "the flood stopped before the sockets closed")
        #expect(throws: UDPSocketError.closed) { try closed.send(Data([1]), to: SocketAddress(host: "127.0.0.1", port: 9)) }
        // close() returned after the descriptor was closed: the port is free again.
        let rebound = try UDPSocket.bind(host: "127.0.0.1", port: closed.localPort)
        rebound.close()
        // deinit does not wait, but still closes the descriptor.
        #expect(await eventually(timeout: .seconds(2)) {
            guard let probe = try? UDPSocket.bind(host: "127.0.0.1", port: droppedPort) else { return false }
            probe.close()
            return true
        })
    }

    /// One readiness event reads at most `readBatchLimit` datagrams; the (level-triggered) source fires again for the rest.
    @Test func aBacklogLongerThanOneReadBatchIsDeliveredInFull() async throws {
        let sender = try UDPSocket.bind(host: "127.0.0.1")
        let receiver = try UDPSocket.bind(host: "127.0.0.1")
        defer { sender.close(); receiver.close() }
        let count = UDPSocket.readBatchLimit * 8 + 5
        let destination = SocketAddress(host: "127.0.0.1", port: receiver.localPort)
        // Holding the receiver's queue keeps its read handler from running, so every datagram waits in the kernel.
        try receiver.queue.sync {
            for index in 0..<count { try sender.send(Data([UInt8(index >> 8), UInt8(truncatingIfNeeded: index)]), to: destination) }
        }
        let datagrams = await collectDatagrams(receiver.datagrams, count: count)
        #expect(datagrams.count == count)
        #expect(datagrams.map(\.data) == (0..<count).map { Data([UInt8($0 >> 8), UInt8(truncatingIfNeeded: $0)]) })
    }

    /// For actors and deinit: returns at once; `waitUntilClosed()` resumes once the descriptor is closed.
    @Test func closeWithoutWaitingThenWaitUntilClosed() async throws {
        let socket = try UDPSocket.bind(host: "127.0.0.1")
        let port = socket.localPort
        let reader = Task { () -> Bool in
            for await _ in socket.datagrams {}
            return true
        }
        socket.closeWithoutWaiting()
        #expect(throws: UDPSocketError.closed) { try socket.send(Data([1]), to: SocketAddress(host: "127.0.0.1", port: 9)) }
        #expect(await reader.value)
        await socket.waitUntilClosed()
        let rebound = try UDPSocket.bind(host: "127.0.0.1", port: port)
        rebound.close()
        await socket.waitUntilClosed()   // already closed: returns at once
        socket.close()                   // idempotent
        socket.closeWithoutWaiting()
    }

    @Test func bindsTheRequestedPort() throws {
        let probe = try UDPSocket.bind(host: "127.0.0.1")
        let port = probe.localPort
        probe.close()
        let socket = try UDPSocket.bind(host: "127.0.0.1", port: port)
        defer { socket.close() }
        #expect(socket.localPort == port)
    }
}
