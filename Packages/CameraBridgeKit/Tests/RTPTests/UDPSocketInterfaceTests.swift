import Foundation
import TestSupport
import Testing
@testable import RTP

/// Scoping a socket to one network interface (`IP_BOUND_IF` / `IPV6_BOUND_IF`): the first rung of the live view sending strategy,
/// so the egress interface matches the source address on a Mac that is on its LAN twice. Only loopback (lo0) is used.
@Suite(.timeLimit(.minutes(1)), .loopback) struct UDPSocketInterfaceTests {
    @Test func aSocketBoundToLoopbackCanBeScopedToItsInterfaceAtBindTime() async throws {
        let receiver = try UDPSocket.bind(host: "127.0.0.1")
        defer { receiver.close() }
        let sender = try UDPSocket.bind(host: "127.0.0.1", interface: "lo0")
        defer { sender.close() }
        #expect(sender.scopedInterface == "lo0" && receiver.scopedInterface == nil)
        try sender.send(Data("ping".utf8), to: SocketAddress(host: "127.0.0.1", port: receiver.localPort))
        let received = await collectDatagrams(receiver.datagrams, count: 1)
        #expect(received.first?.data == Data("ping".utf8))
    }

    @Test func theScopeCanBeSetAndClearedWhileTheSocketIsInUse() async throws {
        let receiver = try UDPSocket.bind(host: "127.0.0.1")
        defer { receiver.close() }
        let sender = try UDPSocket.bind(host: "127.0.0.1")
        defer { sender.close() }
        #expect(sender.scopedInterface == nil)
        try sender.scope(toInterface: "lo0")
        #expect(sender.scopedInterface == "lo0")
        try sender.send(Data([1]), to: SocketAddress(host: "127.0.0.1", port: receiver.localPort))
        try sender.scope(toInterface: nil)
        #expect(sender.scopedInterface == nil)
        try sender.send(Data([2]), to: SocketAddress(host: "127.0.0.1", port: receiver.localPort))
        let received = await collectDatagrams(receiver.datagrams, count: 2)
        #expect(received.map(\.data) == [Data([1]), Data([2])])
    }

    @Test func anIPv6SocketCanBeScopedToo() async throws {
        let receiver = try UDPSocket.bind(host: "::1", ipv6: true)
        defer { receiver.close() }
        let sender = try UDPSocket.bind(host: "::1", ipv6: true, interface: "lo0")
        defer { sender.close() }
        try sender.send(Data([7]), to: SocketAddress(host: "::1", port: receiver.localPort))
        let received = await collectDatagrams(receiver.datagrams, count: 1)
        #expect(received.first?.data == Data([7]))
    }

    @Test func anInterfaceThatDoesNotExistThrowsInsteadOfSilentlyDoingNothing() throws {
        #expect(throws: UDPSocketError.system(operation: "if_nametoindex", code: ENXIO)) { try UDPSocket.bind(host: "127.0.0.1", interface: "nonexistent9") }
        let socket = try UDPSocket.bind(host: "127.0.0.1")
        defer { socket.close() }
        #expect(throws: UDPSocketError.system(operation: "if_nametoindex", code: ENXIO)) { try socket.scope(toInterface: "nonexistent9") }
        #expect(socket.scopedInterface == nil, "a failed scope changes nothing")
    }

    @Test func aClosedSocketCannotBeScoped() throws {
        let socket = try UDPSocket.bind(host: "127.0.0.1")
        socket.close()
        #expect(throws: UDPSocketError.closed) { try socket.scope(toInterface: "lo0") }
    }

    /// The seam the session tests use: a send attempt fails with the errno the closure returns, and counts as an attempt.
    @Test func injectedFailuresFailTheChosenAttemptsOnly() throws {
        let receiver = try UDPSocket.bind(host: "127.0.0.1")
        defer { receiver.close() }
        let sender = try UDPSocket.bind(host: "127.0.0.1")
        defer { sender.close() }
        sender.injectSendFailures { $0 == 2 ? ENOBUFS : nil }
        let destination = SocketAddress(host: "127.0.0.1", port: receiver.localPort)
        try sender.send(Data([1]), to: destination)
        #expect(throws: UDPSocketError.system(operation: "sendto", code: ENOBUFS)) { try sender.send(Data([2]), to: destination) }
        try sender.send(Data([3]), to: destination)
    }
}
