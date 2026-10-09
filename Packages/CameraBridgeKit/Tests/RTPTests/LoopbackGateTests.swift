import Foundation
import TestSupport
import Testing
@testable import RTP

/// The readers-writer gate on its own (a private instance; no sockets).
@Suite struct LoopbackGateTests {
    @Test func sharedHoldersOverlapAndExclusiveWaitsForAllOfThem() async {
        let gate = LoopbackGate()
        await gate.acquire(.shared)
        await gate.acquire(.shared)   // shared holders never wait for each other
        #expect(gate.status == .init(shared: 2, exclusive: false, waiting: 0))
        let flood = Task { await gate.acquire(.exclusive) }
        #expect(await eventually { gate.status.waiting == 1 })

        gate.release(.shared)
        #expect(gate.status == .init(shared: 1, exclusive: false, waiting: 1))
        gate.release(.shared)   // the last shared holder hands over to the waiting flood
        #expect(gate.status == .init(shared: 0, exclusive: true, waiting: 0))
        await flood.value
        gate.release(.exclusive)
        #expect(gate.status == .init(shared: 0, exclusive: false, waiting: 0))
    }

    /// Arrival order: a waiting flood holds off later shared tests (no starvation), and ending it lets every shared test
    /// queued before the next flood in at once.
    @Test func grantsInArrivalOrder() async {
        let gate = LoopbackGate()
        await gate.acquire(.shared)
        let first = Task { await gate.acquire(.exclusive) }
        #expect(await eventually { gate.status.waiting == 1 })
        var waiters = [Task<Void, Never>]()
        for (index, access) in [LoopbackAccess.shared, .shared, .exclusive, .shared].enumerated() {
            waiters.append(Task { await gate.acquire(access) })
            #expect(await eventually { gate.status.waiting == index + 2 })
        }
        #expect(gate.status == .init(shared: 1, exclusive: false, waiting: 5), "a waiting flood holds off later shared access")

        gate.release(.shared)
        #expect(gate.status == .init(shared: 0, exclusive: true, waiting: 4))
        await first.value
        gate.release(.exclusive)
        #expect(gate.status == .init(shared: 2, exclusive: false, waiting: 2))
        await waiters[0].value
        await waiters[1].value
        gate.release(.shared)
        gate.release(.shared)
        #expect(gate.status == .init(shared: 0, exclusive: true, waiting: 1))
        await waiters[2].value
        gate.release(.exclusive)
        #expect(gate.status == .init(shared: 1, exclusive: false, waiting: 0))
        await waiters[3].value
        gate.release(.shared)
        #expect(gate.status == .init(shared: 0, exclusive: false, waiting: 0))
    }

    @Test func withAccessReleasesWhenTheBodyThrows() async {
        struct Failure: Error {}
        let gate = LoopbackGate()
        await #expect(throws: Failure.self) {
            try await gate.withAccess(.exclusive) {
                #expect(gate.status == .init(shared: 0, exclusive: true, waiting: 0))
                throw Failure()
            }
        }
        #expect(gate.status == .init(shared: 0, exclusive: false, waiting: 0))
    }
}

/// The traits on the gate every RTP loopback test shares: a flood test never overlaps a test that must not lose
/// datagrams (review: UDP loopback tests lost datagrams while a flood test ran in parallel).
@Suite(.loopback) struct LoopbackTraitTests {
    @Test func testsInALoopbackSuiteShareAccess() {
        #expect(LoopbackTrait.current == .shared)
        #expect(LoopbackTrait.gate.status.shared >= 1 && !LoopbackTrait.gate.status.exclusive)
    }

    @Test(.loopbackFlood) func aFloodTestRunsAlone() async throws {
        #expect(LoopbackTrait.current == .exclusive)
        // Held for the whole test: no `.loopback` test starts meanwhile.
        for _ in 0..<5 {
            #expect(LoopbackTrait.gate.status.shared == 0 && LoopbackTrait.gate.status.exclusive)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(.loopback) func declaringItOnTheTestAsWellIsHarmless() {
        #expect(LoopbackTrait.current == .shared)
    }

    /// `LoopbackFlood` only starts in a `.loopbackFlood` test.
    @Test func aFloodNeedsExclusiveAccess() async {
        func refusesToStart() async {
            do {
                let flood = try LoopbackFlood(ports: [9], payload: Data([0]), senders: 1, limit: .milliseconds(10))
                await flood.stop()
                Issue.record("a flood started with \(String(describing: LoopbackTrait.current)) loopback access")
            } catch {
                #expect(error is LoopbackFlood.NeedsExclusiveAccess)
            }
        }
        await refusesToStart()                          // shared access (this suite)
        await Task.detached { await refusesToStart() }.value   // no access at all (no task locals)
    }
}
