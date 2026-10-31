#if os(Linux)
import BridgeSupport
import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Synchronization
import Testing
@testable import PlatformLinux

/// The epoll reactor behind every TCP wait: each test has its own reactor, so `registrationCount` is its sockets alone.
@Suite struct SocketReactorTests {
    /// A connected pair of non-blocking stream sockets.
    private func pair() throws -> (Int32, Int32) {
        var ends: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &ends) == 0 else { throw TransportError.failed("socketpair \(errno)") }
        for end in ends { _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK) }
        return (ends[0], ends[1])
    }

    private func outcome(of reactor: SocketReactor, _ token: UInt64, _ interest: SocketReactor.Interest,
                         timeout: Duration? = nil) async -> SocketReactor.Outcome? {
        await withCheckedContinuation { (continuation: CheckedContinuation<SocketReactor.Outcome?, Never>) in
            let accepted = reactor.wait(token, for: interest, until: timeout.map { ContinuousClock.now + $0 }) { continuation.resume(returning: $0) }
            if !accepted { continuation.resume(returning: nil) }
        }
    }

    private func eventually(_ limit: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aWaitWithNothingToReadTimesOutAtItsDeadline() async throws {
        let reactor = SocketReactor()
        let (a, b) = try pair()
        defer { _ = Glibc.close(b) }
        let token = reactor.register(a)
        let started = ContinuousClock.now
        #expect(await outcome(of: reactor, token, .readable, timeout: .milliseconds(150)) == .timedOut)
        let waited = ContinuousClock.now - started
        #expect(waited >= .milliseconds(140) && waited < .seconds(2))
        reactor.close(token: token, linger: .zero)
        #expect(reactor.registrationCount == 0)
    }

    @Test func dataWakesAReaderAndAnEmptyBufferWakesAWriter() async throws {
        let reactor = SocketReactor()
        let (a, b) = try pair()
        defer { _ = Glibc.close(b) }
        let token = reactor.register(a)
        #expect(await outcome(of: reactor, token, .writable, timeout: .seconds(2)) == .ready)
        async let reading = outcome(of: reactor, token, .readable, timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(50))
        var byte: UInt8 = 7
        #expect(Glibc.write(b, &byte, 1) == 1)
        #expect(await reading == .ready)
        reactor.close(token: token, linger: .zero)
    }

    @Test func aReaderAndAWriterWaitOnOneSocketAtOnce() async throws {
        let reactor = SocketReactor()
        let (a, b) = try pair()
        defer { _ = Glibc.close(b) }
        // Fill a's send buffer, so a is not writable until b reads.
        var chunk = [UInt8](repeating: 1, count: 65_536)
        while chunk.withUnsafeMutableBytes({ Glibc.send(a, $0.baseAddress, $0.count, Int32(MSG_DONTWAIT)) }) > 0 {}
        let token = reactor.register(a)
        async let writing = outcome(of: reactor, token, .writable, timeout: .seconds(5))
        async let reading = outcome(of: reactor, token, .readable, timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(50))
        var byte: UInt8 = 9
        #expect(Glibc.write(b, &byte, 1) == 1)
        #expect(await reading == .ready)
        while chunk.withUnsafeMutableBytes({ recv(b, $0.baseAddress, $0.count, Int32(MSG_DONTWAIT)) }) > 0 {}
        #expect(await writing == .ready)
        reactor.close(token: token, linger: .zero)
    }

    @Test func closingFailsTheWaitsAndClosesTheDescriptorAtThePeersFIN() async throws {
        let reactor = SocketReactor()
        let (a, b) = try pair()
        let token = reactor.register(a)
        async let waiting = outcome(of: reactor, token, .readable)
        try await Task.sleep(for: .milliseconds(50))
        _ = shutdown(a, Int32(SHUT_WR))
        reactor.close(token: token, linger: .seconds(30))
        #expect(await waiting == .closed)
        #expect(await outcome(of: reactor, token, .readable) == nil)   // a closed socket takes no more waits
        #expect(reactor.registrationCount == 1)   // lingering for the peer's FIN
        var byte: UInt8 = 1
        _ = Glibc.write(b, &byte, 1)   // read and dropped
        _ = Glibc.close(b)
        #expect(await eventually { reactor.registrationCount == 0 })
    }

    @Test func aLingerEndsAtItsLimitWhenThePeerNeverCloses() async throws {
        let reactor = SocketReactor()
        let (a, b) = try pair()
        defer { _ = Glibc.close(b) }
        let token = reactor.register(a)
        reactor.close(token: token, linger: .milliseconds(150))
        #expect(reactor.registrationCount == 1)
        #expect(await eventually { reactor.registrationCount == 0 })
    }

    /// Thousands of sockets waited on and closed while their peers hang up: every wait answers exactly once (a continuation resumed
    /// twice traps) and nothing is left registered.
    @Test func manySocketsClosingWhileTheirPeersHangUpLeaveNothingBehind() async throws {
        let reactor = SocketReactor()
        let rounds = 2_000
        let answered = Atomic<Int>(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for round in 0..<rounds {
                let (a, b) = try pair()
                let token = reactor.register(a)
                group.addTask {
                    let result = await outcome(of: reactor, token, round.isMultiple(of: 2) ? .readable : .writable, timeout: .seconds(5))
                    if result != nil { answered.add(1, ordering: .relaxed) }
                }
                group.addTask {
                    if round.isMultiple(of: 3) { _ = Glibc.close(b) } else { _ = shutdown(b, Int32(SHUT_RDWR)) }
                    reactor.close(token: token, linger: .milliseconds(round.isMultiple(of: 5) ? 0 : 20))
                    if !round.isMultiple(of: 3) { _ = Glibc.close(b) }
                }
                if round.isMultiple(of: 200) { try await group.next() }
            }
            try await group.waitForAll()
        }
        #expect(await eventually(.seconds(5)) { reactor.registrationCount == 0 })
        #expect(answered.load(ordering: .relaxed) <= rounds)
    }

    @Test func theHeapGivesItsSmallestFirst() {
        var heap = MinHeap<Int>()
        for value in [5, 3, 9, 1, 7, 1, 8] { heap.insert(value) }
        var out: [Int] = []
        while let next = heap.removeFirst() { out.append(next) }
        #expect(out == [1, 1, 3, 5, 7, 8, 9])
        #expect(heap.isEmpty)
    }
}
#endif
