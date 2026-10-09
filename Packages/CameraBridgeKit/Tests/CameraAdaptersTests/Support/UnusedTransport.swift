import BridgeSupport
import Foundation
import TestSupport

/// A `NetworkTransport` whose connections are always refused.
final class RefusingTransport: NetworkTransport {
    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener { throw TransportError.addressInUse }
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection { throw TransportError.connectionRefused }
}

/// A `NetworkTransport` that must not be used (drivers under test get fake RTSP sessions instead).
final class UnusedTransport: NetworkTransport {
    let used = Box(false)

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        used.set(true)
        throw TransportError.failed("UnusedTransport.listen")
    }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        used.set(true)
        throw TransportError.failed("UnusedTransport.connect \(host):\(port)")
    }
}
