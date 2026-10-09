import BridgeSupport
import CameraAdapters
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine
#if os(macOS)
import PlatformApple
#endif

private func camera(_ name: String, port: UInt16 = 0, enabled: Bool = true) -> CameraConfiguration {
    var camera = CameraConfiguration(name: name, kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.1"), username: "")
    camera.hapPort = port
    camera.isEnabled = enabled
    return camera
}

@Suite(.timeLimit(.minutes(1))) struct PortAssignmentTests {
    @Test func newCamerasGetTheBasePortPlusTheLowestFreeOffset() {
        let settings = BridgeSettings()
        let assigned = PortAllocator.assignPorts(to: [camera("A"), camera("B", port: 21_101), camera("C"), camera("D")], settings: settings)
        #expect(assigned.map(\.hapPort) == [21_100, 21_101, 21_102, 21_103])
        // Assigned ports are kept (persisted in the configuration), so removing a camera does not move the others.
        let again = PortAllocator.assignPorts(to: [assigned[0], assigned[2], assigned[3], camera("E")], settings: settings)
        #expect(again.map(\.hapPort) == [21_100, 21_102, 21_103, 21_101])
    }

    @Test func reservedDuplicateAndOverflowingPortsAreReassigned() {
        var settings = BridgeSettings()
        settings.sensorsBridgePort = 21_100
        settings.webhookPort = 21_101
        #expect(PortAllocator.reservedPorts(for: settings) == [21_100, 21_101])
        let assigned = PortAllocator.assignPorts(to: [camera("A"), camera("B", port: 21_101), camera("C", port: 30_000), camera("D", port: 30_000)],
                                                 settings: settings)
        #expect(assigned.map(\.hapPort) == [21_102, 21_103, 30_000, 21_104])

        settings.basePort = 65_534
        let high = PortAllocator.assignPorts(to: [camera("A"), camera("B"), camera("C")], settings: settings)
        #expect(high.map(\.hapPort) == [65_534, 65_535, 0], "no port left: 0 lets the server pick an ephemeral one")

        settings.basePort = 80
        #expect(PortAllocator.assignPorts(to: [camera("A")], settings: settings).first?.hapPort == 1_024, "never a privileged port")
    }
}

@Suite(.timeLimit(.minutes(1))) struct PortCheckTests {
    @Test func aPortIsFreeWhenNothingAcceptsConnectionsOnIt() async {
        let transport = FakeTransport(busyPorts: [21_100])
        let allocator = PortAllocator(transport: transport)
        #expect(await !allocator.isAvailable(21_100))
        #expect(await allocator.isAvailable(21_101))
        #expect(transport.connectCalls.value.map(\.host) == ["127.0.0.1", "127.0.0.1", "::1"], "a free port is checked on IPv4 and IPv6")
        #expect(transport.listenCalls.value.isEmpty, "the check never binds (a closed probe listener would linger)")
        #expect(await PortAllocator(transport: FakeTransport(connectFailure: .timedOut)).isAvailable(21_100), "unknown counts as free")
        #expect(await PortAllocator(transport: FakeTransport()).isAvailable(0))
    }

    @Test func fallbackScanSkipsBusyAndReservedPorts() async throws {
        let allocator = PortAllocator(transport: FakeTransport(busyPorts: [21_100, 21_101]))
        #expect(try await allocator.firstAvailablePort(from: 21_100, avoiding: [21_102]) == 21_103)
        #expect(try await allocator.firstAvailablePort(from: 21_104, avoiding: []) == 21_104)
        await #expect(throws: PortAllocationError.noFreePort(startingAt: 21_100)) {
            _ = try await allocator.firstAvailablePort(from: 21_100, avoiding: [21_102], scanLimit: 2)
        }
        let top = PortAllocator(transport: FakeTransport(busyPorts: [65_535]))
        await #expect(throws: PortAllocationError.noFreePort(startingAt: 65_535)) { _ = try await top.firstAvailablePort(from: 65_535, avoiding: []) }
    }

    @Test func bindingScansUpwardWhileTheAddressIsInUse() async throws {
        let transport = FakeTransport(busyPorts: [21_100, 21_101])
        let (port, listener) = try await PortAllocator.bind(from: 21_100, avoiding: [21_102]) { port in
            try await transport.listen(port: port, loopbackOnly: true)
        }
        #expect(port == 21_103 && listener.port == 21_103)
        #expect(transport.listenCalls.value == [21_100, 21_101, 21_103])
        await #expect(throws: TransportError.localNetworkDenied) {
            _ = try await PortAllocator.bind(from: 21_100, avoiding: []) { _ in throw TransportError.localNetworkDenied }
        }
        await #expect(throws: PortAllocationError.noFreePort(startingAt: 21_100)) {
            _ = try await PortAllocator.bind(from: 21_100, avoiding: [], scanLimit: 3) { _ in throw TransportError.addressInUse }
        }
    }

    @Test func resolvingMovesOnlyEnabledCamerasWhosePortIsTaken() async {
        let transport = FakeTransport(busyPorts: [21_100, 21_102, 21_104])
        let allocator = PortAllocator(transport: transport)
        let cameras = [camera("A", port: 21_100), camera("B", port: 21_101), camera("C", port: 21_102, enabled: false), camera("D")]
        let resolved = await allocator.resolvePorts(for: cameras, settings: BridgeSettings())
        #expect(resolved.map(\.id) == cameras.map(\.id))
        // D first gets 21103 (lowest free offset); A's port is busy, so it moves past B (21101), C (21102, kept while
        // disabled), D (21103) and the busy 21104.
        #expect(resolved.map(\.hapPort) == [21_105, 21_101, 21_102, 21_103])
    }

    @Test func resolvingKeepsPortsTheEnginesOwnServersListenOn() async {
        // A running camera's HAP server answers the check; resolving again (camera added, settings changed) must not
        // move it.
        let transport = FakeTransport(busyPorts: [21_100, 21_101, 21_103])
        let allocator = PortAllocator(transport: transport)
        let cameras = [camera("A", port: 21_100), camera("B", port: 21_101), camera("C")]
        let resolved = await allocator.resolvePorts(for: cameras, settings: BridgeSettings(), listening: [21_100, 21_101])
        #expect(resolved.map(\.hapPort) == [21_100, 21_101, 21_102])
        #expect(!transport.connectCalls.value.contains { $0.port == 21_100 || $0.port == 21_101 }, "own ports are not probed")
        let moved = await allocator.resolvePorts(for: cameras, settings: BridgeSettings())
        #expect(moved.map(\.hapPort) == [21_104, 21_105, 21_102], "without `listening` they look taken")
    }
}

#if os(macOS)
@Suite(.timeLimit(.minutes(1))) struct PortCheckLoopbackTests {
    @Test func detectsARealListenerOnLoopback() async throws {
        let transport = AppleNetworkTransport()
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        let allocator = PortAllocator(transport: transport)
        #expect(await !allocator.isAvailable(listener.port))
        let (port, second) = try await PortAllocator.bind(from: listener.port, avoiding: []) { port in
            try await transport.listen(port: port, loopbackOnly: true)
        }
        #expect(port != listener.port && second.port == port)
        second.close()
        listener.close()
        #expect(await eventually { await allocator.isAvailable(listener.port) })
    }

    @Test func detectsAnIPv6OnlyLoopbackListener() async throws {
        let listener = try IPv6LoopbackListener()
        defer { listener.close() }
        let allocator = PortAllocator(transport: AppleNetworkTransport())
        #expect(await !allocator.isAvailable(listener.port))
    }
}

/// A TCP listener on [::1] only (IPV6_V6ONLY), which a 127.0.0.1 probe cannot see.
private final class IPv6LoopbackListener {
    private let descriptor: Int32
    let port: UInt16

    init() throws {
        struct SocketError: Error { let step: String }
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError(step: "socket") }
        var on: Int32 = 1
        setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        address.sin6_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0, Darwin.listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor)
            throw SocketError(step: "bind/listen")
        }
        var actual = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else {
            Darwin.close(descriptor)
            throw SocketError(step: "getsockname")
        }
        self.descriptor = descriptor
        self.port = UInt16(bigEndian: actual.sin6_port)
    }

    func close() {
        Darwin.close(descriptor)
    }
}
#endif
