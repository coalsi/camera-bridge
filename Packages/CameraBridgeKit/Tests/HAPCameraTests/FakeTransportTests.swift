import BridgeSupport
import Foundation
import TestSupport
import Testing

/// The in-memory `FakeTCPConnection` the recording tests run `HDSLoopbackClient` over. Review finding (TestSupport):
/// HAPCameraTests had its own copy of HDSTests' fake transport whose `receive` ignored cancellation, so
/// `withTimeout` around a receive nothing answers (which waits for the cancelled receive to end) never returned.
/// Both targets now use TestSupport's one copy, which also keeps this copy's stallable sends.
@Suite(.timeLimit(.minutes(1))) struct FakeTransportTests {
    @Test func timedOutReceiveEndsWhenNothingAnswers() async throws {
        let (client, server) = FakeTCPConnection.pair()
        let outcome = Box<String?>(nil)
        let reader = Task {
            do {
                _ = try await withTimeout(.milliseconds(100)) { try await client.receive(maximumLength: 1024) }
                outcome.set("received")
            } catch is TestTimeout {
                outcome.set("timed out")
            } catch {
                outcome.set("\(error)")
            }
        }
        let ended = await eventually(timeout: .seconds(3)) { outcome.value != nil }
        // Unblocks a receive that ignored the cancellation, so a failure is reported instead of hanging the suite.
        client.close()
        await reader.value
        try #require(ended, "withTimeout did not return: the cancelled receive kept waiting")
        #expect(outcome.value == "timed out")

        // The cancelled receive consumed nothing: a later one still gets the bytes.
        let (sender, receiver) = FakeTCPConnection.pair()
        _ = try? await withTimeout(.milliseconds(50)) { try await receiver.receive(maximumLength: 1024) }
        try await sender.send(Data([1, 2, 3]))
        #expect(try await receiver.receive(maximumLength: 1024) == Data([1, 2, 3]))
        server.close()
    }

    @Test func stalledSendsWaitUntilTheConnectionCloses() async throws {
        let (client, server) = FakeTCPConnection.pair()
        try await server.send(Data([1]))
        #expect(try await client.receive(maximumLength: 16) == Data([1]))

        server.stallSends()
        let send = Task { try await server.send(Data([2])) }
        #expect(await eventually { server.stalledSendCount == 1 })
        server.close()
        await #expect(throws: TransportError.closed) { try await send.value }
        #expect(server.stalledSendCount == 0)
        // The peer sees EOF, and a send after close fails at once.
        #expect(try await client.receive(maximumLength: 16) == nil)
        await #expect(throws: TransportError.closed) { try await server.send(Data([3])) }
    }
}
