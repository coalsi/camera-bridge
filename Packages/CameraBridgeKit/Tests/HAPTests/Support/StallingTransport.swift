#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import Synchronization
import TestSupport

/// `NetworkTransport` over `PlatformNetworkTransport` (loopback) whose accepted connections can be made to stop sending,
/// like a controller that stopped reading: once the socket buffers are full, `AppleTCPConnection.send` waits for
/// `.contentProcessed` forever. A stalled connection's `send` returns only when the connection is closed (throwing
/// `TransportError.closed`, as the real one does).
final class StallingTransport: NetworkTransport {
    private let base = PlatformNetworkTransport()
    private let accepted = Mutex<[StallingConnection]>([])

    /// Stalls every connection accepted so far (later connections send normally).
    func stallAcceptedConnections() {
        for connection in accepted.withLock({ $0 }) { connection.stall() }
    }

    /// Sends that are waiting on a stalled connection (each connection's writer waits in at most one).
    var blockedSends: Int { accepted.withLock { $0 }.reduce(0) { $0 + $1.blockedSends } }

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        StallingListener(try await base.listen(port: port, loopbackOnly: loopbackOnly)) { [weak self] connection in
            self?.accepted.withLock { $0.append(connection) }
        }
    }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        try await base.connect(host: host, port: port, timeout: timeout)
    }
}

private final class StallingListener: TCPListener {
    let connections: AsyncStream<any TCPConnection>
    private let inner: any TCPListener
    private let forwarder: Task<Void, Never>

    init(_ inner: any TCPListener, accepted: @escaping @Sendable (StallingConnection) -> Void) {
        self.inner = inner
        let (stream, continuation) = AsyncStream.makeStream(of: (any TCPConnection).self)
        connections = stream
        forwarder = Task {
            for await connection in inner.connections {
                let wrapped = StallingConnection(connection)
                accepted(wrapped)
                continuation.yield(wrapped)
            }
            continuation.finish()
        }
    }

    var port: UInt16 { inner.port }

    func close() {
        inner.close()
        forwarder.cancel()
    }
}

final class StallingConnection: TCPConnection {
    private struct State {
        var stalled = false
        var closed = false
        var waiting: [CheckedContinuation<Void, any Error>] = []
    }

    private let inner: any TCPConnection
    private let state = Mutex(State())

    init(_ inner: any TCPConnection) {
        self.inner = inner
    }

    var id: UUID { inner.id }
    var localAddress: String { inner.localAddress }
    var remoteAddress: String { inner.remoteAddress }
    var isIPv6: Bool { inner.isIPv6 }

    func stall() {
        state.withLock { $0.stalled = true }
    }

    var blockedSends: Int { state.withLock { $0.waiting.count } }

    func receive(maximumLength: Int) async throws -> Data? {
        try await inner.receive(maximumLength: maximumLength)
    }

    func send(_ data: Data) async throws {
        let stalled = state.withLock { $0.stalled }
        guard stalled else {
            try await inner.send(data)
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let closed = state.withLock { state in
                if !state.closed { state.waiting.append(continuation) }
                return state.closed
            }
            if closed { continuation.resume(throwing: TransportError.closed) }
        }
    }

    func close() {
        let waiting = state.withLock { state in
            state.closed = true
            defer { state.waiting.removeAll() }
            return state.waiting
        }
        for continuation in waiting { continuation.resume(throwing: TransportError.closed) }
        inner.close()
    }
}
#endif
