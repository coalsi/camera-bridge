#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import PlatformApple
import Testing
import TestSupport
@testable import HAP

/// Collects server events until `stop` returns true for them (bounded by the suite time limit).
private func collect(_ events: AsyncStream<AccessoryServerEvent>, until stop: ([AccessoryServerEvent]) -> Bool) async -> [AccessoryServerEvent] {
    var seen: [AccessoryServerEvent] = []
    for await event in events {
        seen.append(event)
        if stop(seen) { break }
    }
    return seen
}

private func isAdvertisingFailure(_ event: AccessoryServerEvent, denied: Bool) -> Bool {
    guard case .advertisingFailed(_, let localNetworkDenied) = event else { return false }
    return localNetworkDenied == denied
}

private let daemonDown = TransportError.failed("DNS-SD error -65563 (mDNSResponder not running)")

/// Review finding (W4 round 2): after mDNSResponder dropped the registration (DNS-SD "service not running": the
/// registration is gone) or the first `advertise` failed, nothing registered `_hap._tcp` again until a wake or network
/// change, so hubs that had to resolve the accessory again showed "No Response". The server now withdraws the dead
/// registration and advertises again with backoff (as it listens again after a listener failure). Local Network denial is
/// not retried: the engine advertises again once access is granted (`restartAdvertising`).
@Suite(.timeLimit(.minutes(1))) struct AdvertisingRecoveryTests {
    private func makeServer(_ advertiser: RecordingAdvertiser, name: String = "Advertising Test") async -> AccessoryServer {
        let configuration = AccessoryServerConfiguration(port: 0, advertise: true, serviceName: name, loopbackOnly: true)
        let server = AccessoryServer(accessory: TestAccessories.sensorHub().accessory, configuration: configuration, store: InMemoryHAPStore(),
                                     transport: AppleNetworkTransport(), advertiser: advertiser)
        await server.setTimings(.fastTests)
        return server
    }

    @Test func registrationDroppedByTheDaemonIsRegisteredAgain() async throws {
        let advertiser = RecordingAdvertiser()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, advertiser: advertiser)
        defer { await running.stop() }
        let events = running.server.events
        let service = try #require(advertiser.services.first)

        service.fail(daemonDown)
        let seen = await collect(events) { $0.contains(.advertising) }
        #expect(seen.contains { isAdvertisingFailure($0, denied: false) }, "\(seen)")
        let records = advertiser.records
        #expect(records.count == 2)
        #expect(records.first?.cancelled == true, "the dead registration is withdrawn")
        #expect(records.last?.cancelled == false)
        #expect(records.last?.advertisement.port == running.port)
        #expect(records.last?.advertisement.txt == records.first?.advertisement.txt)

        // TXT changes reach the new registration.
        _ = try await running.pairedClient()
        #expect(await advertiser.waitForTXT { $0["sf"] == "0" })
        #expect(advertiser.records.count == 2)
    }

    @Test func failedFirstAdvertiseIsRetriedAndReportedOncePerError() async throws {
        let advertiser = RecordingAdvertiser()
        advertiser.failNextAdvertises([daemonDown, daemonDown, daemonDown])
        let server = await makeServer(advertiser)
        let events = server.events
        try await server.start()
        defer { await server.stop() }

        let seen = await collect(events) { $0.contains(.advertising) }
        #expect(seen.filter { isAdvertisingFailure($0, denied: false) }.count == 1, "\(seen)")
        #expect(advertiser.attempts == 4)
        let record = try #require(advertiser.records.first)
        #expect(advertiser.records.count == 1)
        #expect(record.cancelled == false)
        #expect(record.advertisement.port == (await server.port))
    }

    @Test func failedTXTUpdateRegistersAgain() async throws {
        let advertiser = RecordingAdvertiser()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, advertiser: advertiser)
        defer { await running.stop() }
        let service = try #require(advertiser.services.first)
        service.failUpdates(with: .closed)

        _ = try await running.pairedClient()
        // The new registration carries the current TXT record.
        #expect(await eventually { advertiser.records.count == 2 })
        #expect(advertiser.records.first?.cancelled == true)
        #expect(advertiser.records.last?.advertisement.txt["sf"] == "0")
    }

    @Test func localNetworkDenialIsNotRetried() async throws {
        let advertiser = RecordingAdvertiser()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, advertiser: advertiser)
        defer { await running.stop() }
        let events = running.server.events
        try #require(advertiser.services.first).fail(.localNetworkDenied)
        _ = await collect(events) { $0.contains { isAdvertisingFailure($0, denied: true) } }
        try await Task.sleep(for: .milliseconds(500))
        #expect(advertiser.attempts == 1)

        // Granted later: the engine advertises again.
        await running.server.restartAdvertising()
        #expect(advertiser.records.count == 2)
        #expect(advertiser.records.last?.cancelled == false)
    }

    @Test func stopEndsTheAdvertisingRetries() async throws {
        let advertiser = RecordingAdvertiser()
        advertiser.failNextAdvertises(Array(repeating: daemonDown, count: 1000))
        let server = await makeServer(advertiser)
        try await server.start()
        #expect(await eventually { advertiser.attempts >= 3 })
        await server.stop()
        let attempts = advertiser.attempts
        try await Task.sleep(for: .milliseconds(500))
        #expect(advertiser.attempts == attempts)
        #expect(advertiser.records.isEmpty)
    }

    @Test func restartAdvertisingReplacesAPendingRetry() async throws {
        let advertiser = RecordingAdvertiser()
        advertiser.failNextAdvertise(with: daemonDown)
        var timings = HAPServerTimings.fastTests
        timings.advertisingRetryDelay = .seconds(30)   // the retry would come far too late
        let server = await makeServer(advertiser)
        await server.setTimings(timings)
        try await server.start()
        defer { await server.stop() }
        await server.restartAdvertising()
        #expect(advertiser.records.count == 1)
        #expect(advertiser.records.first?.cancelled == false)
        #expect(advertiser.attempts == 2)
    }

    @Test func advertisingRetriesDoNotKeepADroppedServerAlive() async throws {
        let advertiser = RecordingAdvertiser()
        advertiser.failNextAdvertises(Array(repeating: daemonDown, count: 1000))
        weak var weakServer: AccessoryServer?
        do {
            let server = await makeServer(advertiser, name: "Dropped")
            try await server.start()
            weakServer = server
            #expect(await eventually { advertiser.attempts >= 3 })
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while weakServer != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(weakServer == nil)
        let attempts = advertiser.attempts
        try await Task.sleep(for: .milliseconds(500))
        #expect(advertiser.attempts <= attempts + 1)
    }
}
#endif
