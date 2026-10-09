#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import PlatformApple
import TestSupport
import Testing
@testable import HAP

/// Hardening plan WS-C 4 and 7 at the server: a network change or wake brings a down listener back at once, a listener that
/// runs but does not answer is found and restarted, and connections that went silent in a sleep are dropped.
@Suite(.timeLimit(.minutes(1))) struct NetworkRecoveryTests {
    /// Audit network #6: the relisten backoff doubles up to a minute while the network is away and a network change or wake
    /// did not reset it, so Home saw "No Response" for up to a minute after the network was back.
    @Test func relistenNowListensAgainWithinAFewHundredMillisecondsInsteadOfWaitingOutTheBackoff() async throws {
        let transport = FlakyTransport()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory,
                                            timings: .fast {
                                                $0.listenerRetryDelay = .seconds(30)
                                                $0.listenerRetryMaximumDelay = .seconds(60)
                                            }, transport: transport)
        defer { await running.stop() }
        transport.failNextListens([.failed("network is down")])   // the first retry fails; the next is 30 s away
        transport.failCurrentListener()
        #expect(await eventually { transport.listenCount == 2 }, "the first retry came at once")
        #expect(await running.server.port == nil)

        try await Task.sleep(for: .milliseconds(300))   // the failed listener's port is released by now
        let before = ContinuousClock.now
        await running.server.relistenNow()
        #expect(await eventually(timeout: .seconds(2)) { await running.server.port == running.port })
        #expect(ContinuousClock.now - before < .milliseconds(500), "not after the 30 s backoff")
        #expect(transport.listenCount == 3)
        // Advertised again, on the known port, and controllers can connect.
        #expect(await eventually { running.advertiser.records.last?.advertisement.port == running.port && running.advertiser.records.last?.cancelled == false })
        let client = try await HAPTestClient.connect(port: running.port)
        #expect(try await client.request("GET", "/accessories").status == 470)
        // A running listener is left alone.
        await running.server.relistenNow()
        #expect(transport.listenCount == 3)
    }

    /// Every test shortens these, so a debug value left in a default would pass the suite.
    @Test func theLivenessDefaultsAreTheDocumentedOnes() {
        let timings = HAPServerTimings()
        #expect(timings.sendStallTimeout == .seconds(15))
        #expect(timings.staleConnectionLimit == .seconds(60))
        #expect(timings.listenerRestartSettle == .milliseconds(300))
        #expect(timings.listenerRetryDelay == .seconds(1) && timings.listenerRetryMaximumDelay == .seconds(60))
    }

    @Test func restartListenerReplacesARunningListenerAndKeepsVerifiedSessions() async throws {
        let transport = FlakyTransport()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, transport: transport)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        #expect(transport.listenCount == 1)

        await running.server.restartListener(because: "a test says so")
        #expect(await eventually(timeout: .seconds(5)) { transport.listenCount == 2 && running.advertiser.records.count == 2 })
        #expect(transport.requestedPorts == [0, running.port], "listens again on the same port")
        #expect(await running.server.port == running.port)
        #expect(try await client.request("GET", "/accessories").status == 200, "the verified session survived")
        let late = try await running.pairedClient()
        #expect(try await late.request("GET", "/accessories").status == 200)
    }

    @Test func theListenerProbeSeesAnAnsweringServerAndAStoppedOne() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        #expect(await running.server.probeListener(timeout: .seconds(2)) == .answered)
        await running.stop()
        #expect(await running.server.probeListener(timeout: .seconds(1)) == .notListening)
    }

    /// A connection is silent since before the sleep: it is closed on wake and the controller verifies again; one that has
    /// sent something recently stays.
    @Test func dropStaleConnectionsClosesOnlyVerifiedConnectionsThatWentSilent() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let silent = try await running.pairedClient()
        let unverified = try await HAPTestClient.connect(port: running.port)
        try await Task.sleep(for: .milliseconds(400))
        let chatty = try await running.pairedClient()
        #expect(await running.server.sessionCount == 2)

        #expect(await running.server.dropStaleConnections(inactiveFor: .milliseconds(300)) == 1)
        // `chatty` and `unverified` are younger or unverified; only `silent` has been quiet for longer than the limit.
        #expect(await silent.waitUntilClosed())
        #expect(await chatty.isClosed == false)
        #expect(await unverified.isClosed == false)
        #expect(await running.server.sessionCount == 1)
        #expect(try await chatty.request("GET", "/accessories").status == 200)
        // Nothing is stale within a generous limit.
        #expect(await running.server.dropStaleConnections(inactiveFor: .seconds(60)) == 0)
    }
}
#endif
