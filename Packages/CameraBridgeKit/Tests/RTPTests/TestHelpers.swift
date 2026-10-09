import Dispatch
import Foundation
import Synchronization
import TestSupport
import Testing
@testable import RTP

/// Collects up to `count` elements, returning early when the stream finishes and giving up after `timeout` (then
/// returns what arrived so far). Cancels the iteration afterwards, which terminates the stream.
func collect<Element: Sendable>(_ stream: AsyncStream<Element>, count: Int, timeout: Duration = .seconds(5)) async -> [Element] {
    let box = Box<(elements: [Element], done: Bool)>(([], false))
    let reader = Task {
        for await element in stream {
            if box.update({ $0.elements.append(element); return $0.elements.count }) >= count { break }
        }
        box.update { $0.done = true }
    }
    _ = await eventually(timeout: timeout) { box.value.done }
    reader.cancel()
    return box.value.elements
}

typealias Datagram = (data: Data, from: SocketAddress)

/// `collect` for a socket's datagrams; the test must hold loopback access (see `expectLoopbackAccess`).
func collectDatagrams(_ stream: AsyncStream<Datagram>, count: Int, timeout: Duration = .seconds(5),
                      sourceLocation: SourceLocation = #_sourceLocation) async -> [Datagram] {
    expectLoopbackAccess(sourceLocation: sourceLocation)
    return await collect(stream, count: count, timeout: timeout)
}

/// A test that expects every datagram it sends over loopback to arrive must hold loopback access (`.loopback` on the
/// test or its suite), so that no `LoopbackFlood` runs alongside it.
func expectLoopbackAccess(sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(LoopbackTrait.current != nil, "loopback test without the .loopback trait: a parallel LoopbackFlood can drop its datagrams",
            sourceLocation: sourceLocation)
}

/// Floods 127.0.0.1 `ports` (round robin) with `payload` from `senders` threads until `stop()` or `limit`. Loopback
/// only. Threads, not tasks, so the flood does not occupy the cooperative pool the code under test runs on.
/// Only starts in a `.loopbackFlood` test: a flood drops other sockets' loopback datagrams (see `LoopbackTrait`).
final class LoopbackFlood: Sendable {
    struct NeedsExclusiveAccess: Error, CustomStringConvertible {
        var description: String { "LoopbackFlood outside a .loopbackFlood test would drop parallel tests' loopback datagrams" }
    }

    private let running = Atomic<Bool>(true)
    private let finished = DispatchGroup()
    let sent = Atomic<Int>(0)

    init(ports: [UInt16], payload: Data, senders: Int = 8, limit: Duration = .seconds(3)) throws {
        guard LoopbackTrait.current == .exclusive else { throw NeedsExclusiveAccess() }
        let destinations = ports.map { SocketAddress(host: "127.0.0.1", port: $0) }
        let sockets = try (0..<senders).map { _ in try UDPSocket.bind(host: "127.0.0.1") }
        let deadline = ContinuousClock.now + limit
        for (index, socket) in sockets.enumerated() {
            finished.enter()
            Thread.detachNewThread { [self] in
                var next = index
                while running.load(ordering: .relaxed), ContinuousClock.now < deadline {
                    if (try? socket.send(payload, to: destinations[next % destinations.count])) != nil { sent.add(1, ordering: .relaxed) }
                    next &+= 1
                }
                socket.close()
                finished.leave()
            }
        }
    }

    /// Stops every sender and returns once they have closed their sockets.
    func stop() async {
        running.store(false, ordering: .relaxed)
        await withCheckedContinuation { continuation in finished.notify(queue: .global()) { continuation.resume() } }
    }
}
