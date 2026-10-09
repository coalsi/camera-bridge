import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// Waits `duration` and ignores cancellation (a continuation without a cancellation handler).
private func ignoringCancellation<T: Sendable>(for duration: Duration, returning value: T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        Task.detached {
            try? await Task.sleep(for: duration)
            continuation.resume(returning: value)
        }
    }
}

/// The drivers' hard bounds (`withTimeout`: detection, RTSP probes, Hikvision talkback, webhook reads) hold even when a
/// body does not honour cancellation.
@Suite(.timeLimit(.minutes(1))) struct TimeoutTests {
    @Test func returnsOnTimeWhenTheBodyIgnoresCancellation() async {
        let started = ContinuousClock.now
        await #expect(throws: TransportError.timedOut) {
            _ = try await withTimeout(.milliseconds(100)) { await ignoringCancellation(for: .seconds(2), returning: 1) }
        }
        #expect(ContinuousClock.now - started < .milliseconds(800), "a task-group timeout waits for the body to end")
    }

    @Test func passesResultsAndErrorsThrough() async throws {
        #expect(try await withTimeout(.seconds(5)) { 42 } == 42)
        await #expect(throws: TransportError.closed) { _ = try await withTimeout(.seconds(5)) { () async throws -> Int in throw TransportError.closed } }
    }

    /// An idle webhook connection closes on time even when its transport's `receive` ignores cancellation.
    @Test func webhookClosesAnIdleConnectionWhoseReceiveIgnoresCancellation() async throws {
        let transport = OneConnectionTransport()
        let server = WebhookServer(port: 0, token: "0123456789abcdef0123456789abcdef", loopbackOnly: true, transport: transport,
                                   idleTimeout: .milliseconds(150), requestTimeout: .seconds(10))
        try await server.start()
        let started = ContinuousClock.now
        transport.connect(transport.connection)
        let deadline = ContinuousClock.now + .seconds(5)
        while transport.connection.closedAt.value == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let closedAt = try #require(transport.connection.closedAt.value)
        #expect(closedAt - started < .milliseconds(1_000), "the idle timeout must not wait for the 3 s receive")
        await server.stop()
    }
}

/// A connection whose `receive` takes 3 s whatever happens (no cancellation handler) and then reports EOF.
private final class StubbornConnection: TCPConnection {
    let id = UUID()
    let localAddress = "127.0.0.1"
    let remoteAddress = "127.0.0.1"
    let isIPv6 = false
    let closedAt = Box<ContinuousClock.Instant?>(nil)

    func receive(maximumLength: Int) async throws -> Data? { await ignoringCancellation(for: .seconds(3), returning: nil) }
    func send(_ data: Data) async throws {}
    func close() { closedAt.update { $0 = $0 ?? .now } }
}

/// A transport whose listener hands out the connections passed to `connect(_:)`.
private final class OneConnectionTransport: NetworkTransport {
    final class Listener: TCPListener {
        let port: UInt16 = 1
        let connections: AsyncStream<any TCPConnection>
        let continuation: AsyncStream<any TCPConnection>.Continuation

        init() { (connections, continuation) = AsyncStream.makeStream(of: (any TCPConnection).self) }
        func close() { continuation.finish() }
    }

    let listener = Listener()
    let connection = StubbornConnection()

    func connect(_ connection: any TCPConnection) { listener.continuation.yield(connection) }
    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener { listener }
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection { throw TransportError.connectionRefused }
}
