import Foundation
import Testing
@testable import RTP
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The wildcard and dual-stack paths the shipped app uses for every live view (`StreamingHandler` binds `host: nil` unless
/// `loopbackOnly`), which the loopback suites never reach (review finding: 0% coverage). Nothing here binds a socket:
/// addresses are built and checked in memory, and `configure` runs on an unbound descriptor.
@Suite struct UDPSocketWildcardTests {
    @Test func ipv4WildcardIsAnyAddressWithTheBigEndianPort() throws {
        let wildcard = UDPSocket.wildcard(port: 0x1234, family: AF_INET)
        #expect(Int32(wildcard.storage.ss_family) == AF_INET)
        #expect(wildcard.length == socklen_t(MemoryLayout<sockaddr_in>.size))
        let address = withUnsafeBytes(of: wildcard.storage) { $0.loadUnaligned(as: sockaddr_in.self) }
        #expect(Int32(address.sin_family) == AF_INET)
        #expect(withUnsafeBytes(of: address.sin_port) { Array($0) } == [0x12, 0x34], "the port goes out in network byte order")
        #expect(withUnsafeBytes(of: address.sin_addr) { Array($0) } == [0, 0, 0, 0])
        #expect(UDPSocket.socketAddress(wildcard.storage) == SocketAddress(host: "0.0.0.0", port: 0x1234))
    }

    @Test func ipv6WildcardIsAnyAddressWithTheBigEndianPort() throws {
        let wildcard = UDPSocket.wildcard(port: 0xABCD, family: AF_INET6)
        #expect(Int32(wildcard.storage.ss_family) == AF_INET6)
        #expect(wildcard.length == socklen_t(MemoryLayout<sockaddr_in6>.size))
        let address = withUnsafeBytes(of: wildcard.storage) { $0.loadUnaligned(as: sockaddr_in6.self) }
        #expect(Int32(address.sin6_family) == AF_INET6)
        #expect(withUnsafeBytes(of: address.sin6_port) { Array($0) } == [0xAB, 0xCD], "the port goes out in network byte order")
        #expect(withUnsafeBytes(of: address.sin6_addr) { Array($0) } == [UInt8](repeating: 0, count: 16))
        #expect(address.sin6_flowinfo == 0 && address.sin6_scope_id == 0)
        #expect(UDPSocket.socketAddress(wildcard.storage) == SocketAddress(host: "::", port: 0xABCD))
    }

    /// An IPv6 live-view socket must also serve IPv4 controllers (Apple Home picks the family per session); bind() relies
    /// on `configure(dualStack: true)` clearing IPV6_V6ONLY, whatever the system default (Linux: `bindv6only`).
    @Test func dualStackClearsIPv6OnlyAndSingleStackSetsIt() throws {
        let descriptor = try unboundDescriptor(family: AF_INET6)
        defer { closeUnbound(descriptor) }
        try setIntOption(descriptor, level: Int32(IPPROTO_IPV6), name: IPV6_V6ONLY, value: 1)
        try UDPSocket.configure(descriptor, family: AF_INET6, dualStack: true)
        #expect(intOption(descriptor, level: Int32(IPPROTO_IPV6), name: IPV6_V6ONLY) == 0)

        try UDPSocket.configure(descriptor, family: AF_INET6, dualStack: false)
        #expect(intOption(descriptor, level: Int32(IPPROTO_IPV6), name: IPV6_V6ONLY) == 1)
    }

    @Test func configuredSocketsAreNonBlockingAndCloseOnExec() throws {
        for (family, dualStack) in [(AF_INET, true), (AF_INET, false), (AF_INET6, true), (AF_INET6, false)] {
            let descriptor = try unboundDescriptor(family: family)
            defer { closeUnbound(descriptor) }
            try UDPSocket.configure(descriptor, family: family, dualStack: dualStack)
            #expect(fcntl(descriptor, F_GETFL, 0) & O_NONBLOCK != 0, "family \(family): send must never block")
            #expect(fcntl(descriptor, F_GETFD, 0) & FD_CLOEXEC != 0, "family \(family)")
        }
    }

    /// A dual-stack socket sends to an IPv4 controller through its IPv4-mapped address (::ffff:a.b.c.d).
    @Test func ipv4DestinationsOfIPv6SocketsAreIPv4Mapped() throws {
        let mapped = try UDPSocket.resolve(host: "192.0.2.7", port: 0xABCD, family: AF_INET6, passive: false)
        #expect(Int32(mapped.storage.ss_family) == AF_INET6)
        #expect(mapped.length == socklen_t(MemoryLayout<sockaddr_in6>.size))
        let address = withUnsafeBytes(of: mapped.storage) { $0.loadUnaligned(as: sockaddr_in6.self) }
        #expect(Int32(address.sin6_family) == AF_INET6)
        #expect(withUnsafeBytes(of: address.sin6_port) { Array($0) } == [0xAB, 0xCD])
        #expect(withUnsafeBytes(of: address.sin6_addr) { Array($0) } == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 192, 0, 2, 7])
        // ...and reports an IPv4-mapped sender as IPv4, so a reply goes back the same way.
        #expect(UDPSocket.socketAddress(mapped.storage) == SocketAddress(host: "192.0.2.7", port: 0xABCD))

        // Binding: an IPv4 literal is not an address of an IPv6 socket.
        #expect(throws: UDPSocketError.invalidAddress("192.0.2.7")) {
            try UDPSocket.resolve(host: "192.0.2.7", port: 0, family: AF_INET6, passive: true)
        }
    }

    @Test func plainAddressesOfEachFamily() throws {
        let ipv4 = try UDPSocket.resolve(host: "192.0.2.7", port: 5_004, family: AF_INET, passive: false)
        #expect(Int32(ipv4.storage.ss_family) == AF_INET)
        #expect(ipv4.length == socklen_t(MemoryLayout<sockaddr_in>.size))
        #expect(UDPSocket.socketAddress(ipv4.storage) == SocketAddress(host: "192.0.2.7", port: 5_004))

        let ipv6 = try UDPSocket.resolve(host: "2001:db8::7", port: 5_006, family: AF_INET6, passive: false)
        #expect(Int32(ipv6.storage.ss_family) == AF_INET6)
        #expect(ipv6.length == socklen_t(MemoryLayout<sockaddr_in6>.size))
        #expect(UDPSocket.socketAddress(ipv6.storage) == SocketAddress(host: "2001:db8::7", port: 5_006))
    }

    // MARK: Helpers

    private func unboundDescriptor(family: Int32) throws -> Int32 {
        let descriptor = socket(family, datagramSocketType, 0)
        guard descriptor >= 0 else { throw UDPSocketError.system(operation: "socket", code: errno) }
        return descriptor
    }

    private func closeUnbound(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #elseif canImport(Glibc)
        _ = Glibc.close(descriptor)
        #endif
    }

    private func setIntOption(_ descriptor: Int32, level: Int32, name: Int32, value: Int32) throws {
        var value = value
        guard setsockopt(descriptor, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw UDPSocketError.system(operation: "setsockopt", code: errno)
        }
    }

    private func intOption(_ descriptor: Int32, level: Int32, name: Int32) -> Int32? {
        var value: Int32 = -1
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, level, name, &value, &length) == 0 else { return nil }
        return value
    }
}

/// Opt-in (`CB_WILDCARD_TESTS=1 swift test --filter UDPSocketWildcardBindTests`): binds the wildcard address exactly as a
/// live view in the app does. The socket is reachable on every interface while the test runs, so it is off by default
/// (the default suites bind loopback only); every datagram goes to 127.0.0.1 or ::1.
@Suite(.timeLimit(.minutes(1)), .loopback,
       .enabled(if: ProcessInfo.processInfo.environment["CB_WILDCARD_TESTS"] == "1", "set CB_WILDCARD_TESTS=1 to bind the wildcard address"))
struct UDPSocketWildcardBindTests {
    @Test func ipv4WildcardExchangesDatagramsOverLoopback() async throws {
        let wildcard = try UDPSocket.bind(host: nil, port: 0, ipv6: false)
        let peer = try UDPSocket.bind(host: "127.0.0.1")
        defer { wildcard.close(); peer.close() }
        #expect(wildcard.localPort != 0)

        try peer.send(Data("ping".utf8), to: SocketAddress(host: "127.0.0.1", port: wildcard.localPort))
        let received = await collectDatagrams(wildcard.datagrams, count: 1)
        #expect(received.first?.data == Data("ping".utf8))
        let sender = try #require(received.first?.from)
        #expect(sender == SocketAddress(host: "127.0.0.1", port: peer.localPort))

        try wildcard.send(Data("pong".utf8), to: sender)
        let reply = await collectDatagrams(peer.datagrams, count: 1)
        #expect(reply.first?.data == Data("pong".utf8))
        #expect(reply.first?.from == SocketAddress(host: "127.0.0.1", port: wildcard.localPort))
    }

    /// The IPv6 wildcard is dual stack: it serves an IPv4 controller (sender reported as IPv4, reply sent to its
    /// IPv4-mapped address) and an IPv6 one on the same port.
    @Test func ipv6WildcardServesIPv4AndIPv6Peers() async throws {
        let wildcard = try UDPSocket.bind(host: nil, port: 0, ipv6: true)
        let ipv4Peer = try UDPSocket.bind(host: "127.0.0.1")
        let ipv6Peer = try? UDPSocket.bind(host: "::1", ipv6: true)   // nil: no IPv6 loopback on this machine
        defer { wildcard.close(); ipv4Peer.close(); ipv6Peer?.close() }

        try ipv4Peer.send(Data("four".utf8), to: SocketAddress(host: "127.0.0.1", port: wildcard.localPort))
        try ipv6Peer?.send(Data("six".utf8), to: SocketAddress(host: "::1", port: wildcard.localPort))
        let received = await collectDatagrams(wildcard.datagrams, count: ipv6Peer == nil ? 1 : 2)
        let ipv4Sender = SocketAddress(host: "127.0.0.1", port: ipv4Peer.localPort)
        #expect(received.first { $0.data == Data("four".utf8) }?.from == ipv4Sender, "an IPv4-mapped sender is reported as IPv4")
        if let ipv6Peer {
            #expect(received.first { $0.data == Data("six".utf8) }?.from == SocketAddress(host: "::1", port: ipv6Peer.localPort))
        }

        try wildcard.send(Data("back to four".utf8), to: ipv4Sender)
        let ipv4Reply = await collectDatagrams(ipv4Peer.datagrams, count: 1)
        #expect(ipv4Reply.first?.data == Data("back to four".utf8))
        #expect(ipv4Reply.first?.from == SocketAddress(host: "127.0.0.1", port: wildcard.localPort))
        if let ipv6Peer {
            try wildcard.send(Data("back to six".utf8), to: SocketAddress(host: "::1", port: ipv6Peer.localPort))
            let ipv6Reply = await collectDatagrams(ipv6Peer.datagrams, count: 1)
            #expect(ipv6Reply.first?.data == Data("back to six".utf8))
            #expect(ipv6Reply.first?.from == SocketAddress(host: "::1", port: wildcard.localPort))
        }
    }
}
