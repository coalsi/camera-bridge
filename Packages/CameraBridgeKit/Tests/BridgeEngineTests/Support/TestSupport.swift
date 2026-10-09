import BridgeSupport
import Foundation
import TestSupport

// Temporary directories: TestSupport's `TemporaryDirectory`.

/// POSIX permission bits of the item at `url`.
func posixPermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

/// A `NetworkTransport` that never touches the network, with `busyPorts` standing for ports another process listens on:
/// `listen` hands out listeners with no connections (busy ports fail with `.addressInUse`; port 0 gets a fake
/// ephemeral port); `connect` succeeds for busy ports and is refused otherwise. `failure` / `connectFailure` replace
/// those answers.
final class FakeTransport: NetworkTransport {
    let busyPorts: Box<Set<UInt16>>
    let listenCalls = Box<[UInt16]>([])
    let connectCalls = Box<[(host: String, port: UInt16)]>([])
    let failure: TransportError?
    let connectFailure: TransportError?

    init(busyPorts: Set<UInt16> = [], failure: TransportError? = nil, connectFailure: TransportError? = nil) {
        self.busyPorts = Box(busyPorts)
        self.failure = failure
        self.connectFailure = connectFailure
    }

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        listenCalls.update { $0.append(port) }
        if let failure { throw failure }
        if busyPorts.value.contains(port) { throw TransportError.addressInUse }
        return FakeListener(port: port == 0 ? 50_000 : port)
    }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        connectCalls.update { $0.append((host, port)) }
        if let connectFailure { throw connectFailure }
        guard busyPorts.value.contains(port) else { throw TransportError.connectionRefused }
        return FakeConnection(remoteAddress: host)
    }
}

final class FakeConnection: TCPConnection {
    let id = UUID()
    let localAddress = "127.0.0.1"
    let remoteAddress: String
    let isIPv6 = false
    let closed = Box(false)

    init(remoteAddress: String) {
        self.remoteAddress = remoteAddress
    }

    func receive(maximumLength: Int) async throws -> Data? { nil }
    func send(_ data: Data) async throws {}
    func close() { closed.set(true) }
}

final class FakeListener: TCPListener {
    let port: UInt16
    let connections: AsyncStream<any TCPConnection>
    private let continuation: AsyncStream<any TCPConnection>.Continuation
    let closed = Box(false)

    init(port: UInt16) {
        self.port = port
        (connections, continuation) = AsyncStream.makeStream(of: (any TCPConnection).self)
    }

    func close() {
        closed.set(true)
        continuation.finish()
    }
}
