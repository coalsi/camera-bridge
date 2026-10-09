#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import Synchronization
import TestSupport

/// `NetworkTransport` over `PlatformNetworkTransport` (loopback) that lets a test make the current listener fail the way
/// `AppleTCPListener` does when NWListener enters `.failed`/`.waiting` after becoming ready (its `connections` stream
/// finishes), and queue errors for the next `listen` calls.
final class FlakyTransport: NetworkTransport {
    private let base = PlatformNetworkTransport()
    private let state = Mutex<(listeners: [FlakyListener], errors: [TransportError], requestedPorts: [UInt16])>(([], [], []))

    /// Ports passed to `listen`, in order.
    var requestedPorts: [UInt16] { state.withLock { $0.requestedPorts } }
    var listenCount: Int { state.withLock { $0.requestedPorts.count } }

    /// The next `listen` calls throw these errors (in order) before listening works again.
    func failNextListens(_ errors: [TransportError]) {
        state.withLock { $0.errors.append(contentsOf: errors) }
    }

    /// Makes the most recent listener fail: it stops accepting and its `connections` stream finishes.
    func failCurrentListener() {
        let listener = state.withLock { $0.listeners.last }
        listener?.fail()
    }

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        let error = state.withLock { state -> TransportError? in
            state.requestedPorts.append(port)
            return state.errors.isEmpty ? nil : state.errors.removeFirst()
        }
        if let error { throw error }
        let listener = FlakyListener(try await base.listen(port: port, loopbackOnly: loopbackOnly))
        state.withLock { $0.listeners.append(listener) }
        return listener
    }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        try await base.connect(host: host, port: port, timeout: timeout)
    }
}

final class FlakyListener: TCPListener {
    let connections: AsyncStream<any TCPConnection>
    private let inner: any TCPListener
    private let continuation: AsyncStream<any TCPConnection>.Continuation
    private let forwarder: Task<Void, Never>

    init(_ inner: any TCPListener) {
        self.inner = inner
        let (stream, continuation) = AsyncStream.makeStream(of: (any TCPConnection).self)
        connections = stream
        self.continuation = continuation
        forwarder = Task {
            for await connection in inner.connections { continuation.yield(connection) }
            continuation.finish()
        }
    }

    var port: UInt16 { inner.port }

    func close() {
        inner.close()
        continuation.finish()
        forwarder.cancel()
    }

    /// Like NWListener entering `.failed`: the port is released and the stream finishes without `close()`.
    func fail() {
        inner.close()
        continuation.finish()
    }
}
#endif
