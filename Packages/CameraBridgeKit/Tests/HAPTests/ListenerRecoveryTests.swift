#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import HAPCore
import TestSupport
import Testing
@testable import HAP

/// Collects server events until `stop` returns true for one of them (bounded by the suite time limit).
private func collect(_ events: AsyncStream<AccessoryServerEvent>, until stop: ([AccessoryServerEvent]) -> Bool) async -> [AccessoryServerEvent] {
    var seen: [AccessoryServerEvent] = []
    for await event in events {
        seen.append(event)
        if stop(seen) { break }
    }
    return seen
}

private func isAdvertisingFailure(_ event: AccessoryServerEvent, denied: Bool? = nil) -> Bool {
    guard case .advertisingFailed(_, let localNetworkDenied) = event else { return false }
    return denied.map { $0 == localNetworkDenied } ?? true
}

/// The accept loop ending while the server runs (NWListener `.failed`/`.waiting` after it was ready: interface change,
/// sleep/wake, Local Network access revoked) must not leave a dead but advertised server behind (review of W1-1).
@Suite(.timeLimit(.minutes(1))) struct ListenerRecoveryTests {
    @Test func failedListenerIsReportedWithdrawnAndRestartedOnTheSamePort() async throws {
        let transport = FlakyTransport()
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory, transport: transport)
        defer { await running.stop() }
        let events = running.server.events
        let client = try await running.pairedClient()
        #expect(running.advertiser.records.count == 1)

        transport.failCurrentListener()
        let seen = await collect(events) { seen in
            guard let failure = seen.firstIndex(where: { isAdvertisingFailure($0) }) else { return false }
            return seen[failure...].contains(.advertising)
        }
        let failure = try #require(seen.firstIndex { isAdvertisingFailure($0) })
        #expect(seen[failure...].contains(.listening(port: running.port)))
        #expect(await running.server.port == running.port)
        // The known port again (possibly retried while the failed socket is released).
        #expect(transport.requestedPorts.first == 0)
        #expect(transport.requestedPorts.count >= 2 && transport.requestedPorts.dropFirst().allSatisfy { $0 == running.port })

        // The stale advertisement was withdrawn and the new one points at the listening port.
        let records = running.advertiser.records
        #expect(records.count == 2)
        #expect(records.first?.cancelled == true)
        #expect(records.last?.advertisement.port == running.port)
        #expect(records.last?.cancelled == false)

        // New controllers can connect again, and the verified session survived.
        let late = try await running.pairedClient()
        #expect(try await late.request("GET", "/accessories").status == 200)
        #expect(try await client.request("GET", "/accessories").status == 200)
    }

    @Test func restartFailuresAreReportedOnceAndRetried() async throws {
        let transport = FlakyTransport()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, transport: transport)
        defer { await running.stop() }
        let events = running.server.events
        transport.failNextListens([.localNetworkDenied, .localNetworkDenied, .localNetworkDenied])

        transport.failCurrentListener()
        let seen = await collect(events) { $0.contains(.advertising) }
        #expect(seen.filter { isAdvertisingFailure($0, denied: true) }.count == 1, "\(seen)")
        #expect(seen.contains(.listening(port: running.port)))
        // Three refused attempts on the known port, then success on it again.
        #expect(transport.requestedPorts == [0, running.port, running.port, running.port, running.port])
        #expect(await running.server.port == running.port)
    }

    @Test func ephemeralPortFallsBackToANewPortWhenTheOldOneStaysTaken() async throws {
        let transport = FlakyTransport()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, transport: transport)
        defer { await running.stop() }
        let events = running.server.events
        transport.failNextListens([.addressInUse, .addressInUse, .addressInUse])

        transport.failCurrentListener()
        _ = await collect(events) { $0.contains(.advertising) }
        #expect(transport.requestedPorts == [0, running.port, running.port, running.port, 0])
        let port = try #require(await running.server.port)
        #expect(running.advertiser.records.last?.advertisement.port == port)
        let client = try await HAPTestClient.connect(port: port)
        #expect(try await client.request("GET", "/accessories").status == 470)
    }

    @Test func restartLoopDoesNotKeepADroppedServerAlive() async throws {
        let transport = FlakyTransport()
        weak var weakServer: AccessoryServer?
        do {
            let configuration = AccessoryServerConfiguration(port: 0, advertise: true, serviceName: "Dropped", loopbackOnly: true)
            let server = AccessoryServer(accessory: TestAccessories.sensorHub().accessory, configuration: configuration,
                                         store: InMemoryHAPStore(), transport: transport, advertiser: RecordingAdvertiser())
            await server.setTimings(.fastTests)
            try await server.start()
            weakServer = server
            let events = server.events
            transport.failNextListens(Array(repeating: .failed("down"), count: 1000))
            transport.failCurrentListener()
            _ = await collect(events) { seen in seen.contains { isAdvertisingFailure($0) } }
            #expect(await eventually { transport.listenCount >= 3 })
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while weakServer != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(weakServer == nil)
        let attempts = transport.listenCount
        try await Task.sleep(for: .milliseconds(500))
        #expect(transport.listenCount <= attempts + 1)
    }

    @Test func stopEndsTheRestartLoop() async throws {
        let transport = FlakyTransport()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, transport: transport)
        let events = running.server.events
        transport.failNextListens(Array(repeating: .failed("down"), count: 1000))

        transport.failCurrentListener()
        _ = await collect(events) { seen in seen.contains { isAdvertisingFailure($0) } }
        #expect(await eventually { transport.listenCount >= 3 })
        await running.stop()
        let attempts = transport.listenCount
        try await Task.sleep(for: .milliseconds(500))
        #expect(transport.listenCount == attempts)
        #expect(await running.server.port == nil)
    }
}
#endif
