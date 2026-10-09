#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import PlatformApple
import Synchronization
import TestSupport
import Testing
@testable import HAP

/// A browser that answers what the test says, once per `lookup`.
private final class ScriptedBrowser: ServiceBrowsing {
    private let answers = Mutex<[ServiceLookup]>([])
    let lookups = Mutex(0)

    /// `lookup` answers these in order, then repeats the last one.
    func answer(_ answers: ServiceLookup...) {
        self.answers.withLock { $0 = answers }
    }

    func lookup(type: String, name: String, timeout: Duration) async -> ServiceLookup {
        lookups.withLock { $0 += 1 }
        return answers.withLock { answers in
            guard let first = answers.first else { return .notFound }
            if answers.count > 1 { answers.removeFirst() }
            return first
        }
    }
}

/// Hands out a connection that accepts the probe's request and never answers: a listener that accepts and wedges.
private final class SilentProbeTransport: NetworkTransport {
    let base = FlakyTransport()
    var listenCount: Int { base.listenCount }

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        try await base.listen(port: port, loopbackOnly: loopbackOnly)
    }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        FakeTCPConnection.pair().client
    }
}

/// Hardening plan WS-C 9: the per-accessory health monitor, driven pass by pass with a hand-moved clock, a scripted
/// browser and a recording advertiser (nothing is announced, nothing browses).
@Suite(.timeLimit(.minutes(1))) struct HealthMonitorTests {
    private final class Clock: Sendable {
        private let instant = Mutex(ContinuousClock.now)
        var now: ContinuousClock.Instant { instant.withLock { $0 } }
        func advance(_ duration: Duration) { instant.withLock { $0 = $0 + duration } }
    }

    private func monitor(_ running: RunningServer, browser: ServiceBrowsing, clock: Clock = Clock(),
                         timing: HAPHealthMonitor.Timing = .init(probeTimeout: .milliseconds(500))) -> HAPHealthMonitor {
        HAPHealthMonitor(server: running.server, name: "Test Hub", browser: browser, timing: timing, log: Log(category: "hap")) { clock.now }
    }

    private func txt(_ running: RunningServer) async throws -> [String: String] {
        try #require(await running.server.advertisedTXT)
    }

    @Test func aHealthyAccessoryIsLeftAlone() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let browser = ScriptedBrowser()
        browser.answer(.found(try await txt(running)))
        let monitor = monitor(running, browser: browser)
        for _ in 0..<4 { await monitor.runOnce() }
        #expect(await monitor.listenerRestarts == 0)
        #expect(await monitor.advertisingRestarts == 0)
        #expect(running.advertiser.records.count == 1)
        #expect(browser.lookups.withLock { $0 } == 4)
    }

    /// Bonjour that does not show the accessory is registered again after two checks in a row, not after one; a check that
    /// sees it in between starts the count over.
    @Test func bonjourThatMissesTheAccessoryTwiceInARowRegistersItAgain() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let seen = try await txt(running)
        let browser = ScriptedBrowser()
        let monitor = monitor(running, browser: browser)

        browser.answer(.notFound, .found(seen), .notFound, .notFound)
        await monitor.runOnce()                    // miss 1
        await monitor.runOnce()                    // seen: reset
        await monitor.runOnce()                    // miss 1 again
        #expect(await monitor.advertisingRestarts == 0)
        #expect(running.advertiser.records.count == 1)
        await monitor.runOnce()                    // miss 2: register again
        #expect(await monitor.advertisingRestarts == 1)
        #expect(await eventually { running.advertiser.records.count == 2 })
        #expect(running.advertiser.records.first?.cancelled == true && running.advertiser.records.last?.cancelled == false)
    }

    /// A stale record (the `c#` of an older configuration, or `sf` still saying unpaired) is as bad as a missing one.
    @Test func aStaleTXTRecordCountsAsAMiss() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        var stale = try await txt(running)
        stale["c#"] = "99"
        let browser = ScriptedBrowser()
        browser.answer(.found(stale))
        let monitor = monitor(running, browser: browser)
        await monitor.runOnce()
        await monitor.runOnce()
        #expect(await monitor.advertisingRestarts == 1)
        #expect(await eventually { running.advertiser.records.count == 2 })
    }

    @Test func aBrowseThatCannotRunChangesNothing() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let browser = ScriptedBrowser()
        browser.answer(.unavailable("Local Network access was denied"))
        let monitor = monitor(running, browser: browser)
        for _ in 0..<5 { await monitor.runOnce() }
        #expect(await monitor.advertisingRestarts == 0)
        #expect(running.advertiser.records.count == 1)
    }

    @Test func anAccessoryThatIsNotAdvertisedIsNotBrowsedFor() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, advertise: false)
        defer { await running.stop() }
        let browser = ScriptedBrowser()
        let monitor = monitor(running, browser: browser)
        await monitor.runOnce()
        #expect(browser.lookups.withLock { $0 } == 0)
    }

    /// A paired accessory that no controller has connected to for ten minutes is advertised again once and says so; a
    /// controller connecting clears the note.
    @Test func aPairedAccessoryNoControllerHasContactedForTenMinutesIsAdvertisedAgainOnce() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        await running.server.addPairingForTesting(controllerID: UUID().uuidString, publicKey: HAPLongTermKey().publicKey)
        #expect(await running.advertiser.waitForTXT { $0["sf"] == "0" }, "the pairing reached the TXT record")
        let browser = ScriptedBrowser()
        browser.answer(.found(try await txt(running)))
        let clock = Clock()
        let monitor = monitor(running, browser: browser, clock: clock)

        await monitor.runOnce()
        clock.advance(.seconds(540))
        await monitor.runOnce()
        #expect(await monitor.controllerSilenceNote == nil, "nine minutes is not ten")
        clock.advance(.seconds(120))
        await monitor.runOnce()
        #expect(await monitor.controllerSilenceNote == "Home hasn't contacted this camera for 11 min")
        #expect(await monitor.advertisingRestarts == 1)
        await monitor.runOnce()
        #expect(await monitor.advertisingRestarts == 1, "once, not at every pass")

        // A verified controller: the note goes away and the silence starts over.
        let client = try await running.pairedClient()
        await monitor.runOnce()
        #expect(await monitor.controllerSilenceNote == nil)
        await client.close()
        #expect(await eventually { await running.server.sessionCount == 0 })
        clock.advance(.seconds(300))
        await monitor.runOnce()
        #expect(await monitor.controllerSilenceNote == nil)
    }

    @Test func anUnpairedAccessoryIsNeverReportedSilent() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let browser = ScriptedBrowser()
        browser.answer(.found(try await txt(running)))
        let clock = Clock()
        let monitor = monitor(running, browser: browser, clock: clock)
        clock.advance(.seconds(3600))
        await monitor.runOnce()
        #expect(await monitor.controllerSilenceNote == nil)
        #expect(await monitor.advertisingRestarts == 0)
    }

    /// A listener that accepts and never answers: restarted on the same port, one repair per pass.
    @Test func aListenerThatDoesNotAnswerIsRestarted() async throws {
        let transport = SilentProbeTransport()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, transport: transport)
        defer { await running.stop() }
        let browser = ScriptedBrowser()
        browser.answer(.found(try await txt(running)))
        let monitor = monitor(running, browser: browser)
        #expect(transport.listenCount == 1)
        await monitor.runOnce()
        #expect(await monitor.listenerRestarts == 1)
        #expect(await eventually(timeout: .seconds(5)) { transport.listenCount == 2 })
        #expect(await eventually { await running.server.port == running.port })
    }

    @Test func theLoopIsCancelledByStop() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let browser = ScriptedBrowser()
        browser.answer(.found(try await txt(running)))
        let monitor = monitor(running, browser: browser, timing: .init(interval: .milliseconds(50), probeTimeout: .milliseconds(500)))
        await monitor.start()
        #expect(await eventually { browser.lookups.withLock { $0 } >= 3 })
        await monitor.stop()
        let after = browser.lookups.withLock { $0 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(browser.lookups.withLock { $0 } <= after + 1)
    }
}
#endif
