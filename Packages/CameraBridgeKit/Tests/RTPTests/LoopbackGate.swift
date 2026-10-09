import Synchronization
import Testing

/// How a test uses the loopback interface.
enum LoopbackAccess: Sendable, Equatable {
    /// Exchanges datagrams over loopback and expects all of them to arrive; runs alongside other such tests.
    case shared
    /// Floods loopback (`LoopbackFlood`); runs alone.
    case exclusive
}

/// Readers-writer lock for async code, granted in arrival order: a waiting `.exclusive` holds off later `.shared`
/// requests, so neither side starves. Waiting suspends the task without blocking a thread.
final class LoopbackGate: Sendable {
    struct Status: Equatable {
        var shared: Int
        var exclusive: Bool
        var waiting: Int
    }

    private struct State {
        var shared = 0
        var exclusive = false
        var waiting: [(access: LoopbackAccess, continuation: CheckedContinuation<Void, Never>)] = []

        func canGrant(_ access: LoopbackAccess) -> Bool {
            access == .shared ? !exclusive : !exclusive && shared == 0
        }

        mutating func grant(_ access: LoopbackAccess) {
            if access == .shared { shared += 1 } else { exclusive = true }
        }
    }

    private let state = Mutex(State())

    var status: Status {
        state.withLock { Status(shared: $0.shared, exclusive: $0.exclusive, waiting: $0.waiting.count) }
    }

    /// Returns once `access` is granted; requests that cannot be granted yet wait behind every earlier one.
    func acquire(_ access: LoopbackAccess) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let granted = state.withLock { state -> Bool in
                guard state.waiting.isEmpty, state.canGrant(access) else {
                    state.waiting.append((access, continuation))
                    return false
                }
                state.grant(access)
                return true
            }
            if granted { continuation.resume() }
        }
    }

    /// Releases `access` and grants the waiting requests at the head of the queue that now fit.
    func release(_ access: LoopbackAccess) {
        let granted = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            if access == .shared {
                precondition(state.shared > 0, "shared loopback access released but not held")
                state.shared -= 1
            } else {
                precondition(state.exclusive, "exclusive loopback access released but not held")
                state.exclusive = false
            }
            var granted: [CheckedContinuation<Void, Never>] = []
            while let next = state.waiting.first, state.canGrant(next.access) {
                state.waiting.removeFirst()
                state.grant(next.access)
                granted.append(next.continuation)
            }
            return granted
        }
        for continuation in granted { continuation.resume() }
    }

    func withAccess<R>(_ access: LoopbackAccess, _ body: () async throws -> R) async rethrows -> R {
        await acquire(access)
        defer { release(access) }
        return try await body()
    }
}

/// Keeps loopback floods apart from the tests that expect every datagram to arrive.
///
/// A flood can overflow the loopback interface's input queue, which all of lo0 shares (on macOS
/// `net.link.generic.system.rcvq_maxlen`, 256 on the development Mac). The kernel then drops datagrams addressed to
/// other sockets too, without reporting an error to anyone. Tests that sent a known sequence over 127.0.0.1 lost datagrams whenever a
/// flood test happened to run in parallel. Each test case holds the gate while it runs: `.loopback` (recursive on a
/// suite) shares it, `.loopbackFlood` holds it alone and takes precedence over an inherited `.loopback`.
/// `LoopbackFlood` only starts under `.loopbackFlood`; `collectDatagrams` and `TestController` expect `.loopback`.
struct LoopbackTrait: TestTrait, SuiteTrait, TestScoping {
    /// One gate for the test bundle: every RTP test runs in this process.
    static let gate = LoopbackGate()

    /// The access the running test holds; nil outside `.loopback` / `.loopbackFlood` tests.
    @TaskLocal static var current: LoopbackAccess?

    let access: LoopbackAccess

    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        // Each test case, never a whole suite: a suite holding shared access would block its own flood test.
        guard !test.isSuite, testCase != nil else { return nil }
        if access == .shared, test.traits.contains(where: { ($0 as? Self)?.access == .exclusive }) { return nil }
        return self
    }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        if let held = Self.current {   // declared on both the suite and the test
            precondition(held == .exclusive || access == .shared, "shared loopback access cannot become exclusive")
            return try await function()
        }
        try await Self.gate.withAccess(access) {
            try await Self.$current.withValue(access) { try await function() }
        }
    }
}

extension Trait where Self == LoopbackTrait {
    /// The test exchanges datagrams over loopback and expects all of them to arrive: it never runs during a flood.
    static var loopback: Self { LoopbackTrait(access: .shared) }

    /// The test floods loopback (`LoopbackFlood`): no `.loopback` test runs meanwhile.
    static var loopbackFlood: Self { LoopbackTrait(access: .exclusive) }
}
