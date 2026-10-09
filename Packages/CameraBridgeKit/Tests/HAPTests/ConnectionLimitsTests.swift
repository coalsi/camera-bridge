#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import PlatformApple
import Synchronization
import TestSupport
import Testing
@testable import HAP

/// What the server does with connections it cannot or need not keep: a controller that stopped reading (its write
/// queue overflows) and connections idle for long once there are many. Review finding (W4 round 3): neither path ran
/// in any test, so a regression that dropped frames silently (desynchronizing the nonce counters) or kept stalled or
/// idle controllers forever would have passed every suite.
@Suite(.timeLimit(.minutes(1))) struct ConnectionLimitsTests {
    // MARK: - A controller that stopped reading

    /// An EVENT burst (doorbell presses) to a hub that stopped reading: once the writer is stuck in `send` and the 512
    /// queued writes are used up, the connection is closed instead of the next frame being dropped.
    @Test func controllerThatStopsReadingIsClosedInsteadOfLosingFrames() async throws {
        let sink = CapturingSink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let hub = TestAccessories.sensorHub()
        let transport = StallingTransport()
        let running = try await startServer(accessory: hub.accessory, transport: transport)
        defer { await running.stop() }
        let stalled = try await running.pairedClient()
        #expect(try await stalled.subscribe(aid: 1, iid: hub.switchEvent.iid) == 204)
        #expect(await running.server.sessionCount == 1)

        transport.stallAcceptedConnections()
        // Fewer presses than the queue holds: the connection stays open (frames wait, none is dropped).
        for _ in 0..<100 { hub.switchEvent.sendEvent(.uint(0)) }
        #expect(await eventually { transport.blockedSends == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await stalled.isClosed == false)
        #expect(await running.server.sessionCount == 1)
        // More than it holds: closed.
        for _ in 0..<500 { hub.switchEvent.sendEvent(.uint(0)) }
        #expect(await stalled.waitUntilClosed())
        #expect(await eventually { await running.server.connectionCount == 0 })
        #expect(await running.server.sessionCount == 0)
        #expect(transport.blockedSends == 0, "closing ends the writer's stuck send")
        #expect(sink.messages.contains { $0.contains("127.0.0.1: the controller is not reading") })

        // Controllers that read are unaffected.
        let reader = try await running.pairedClient()
        #expect(try await reader.subscribe(aid: 1, iid: hub.switchEvent.iid) == 204)
        hub.switchEvent.sendEvent(.uint(1))
        #expect(try await reader.nextEvent().json()["characteristics"]?[0]?["value"] == 1)
    }

    /// Hardening plan WS-C 1 (audit A1): a controller that is gone without a FIN or RST never lets a send complete, and
    /// a single event does not fill the 512-frame queue, so nothing used to end the connection. The send-progress
    /// watchdog closes it after `sendStallTimeout`, and the line says why.
    @Test func connectionWhoseSendMakesNoProgressIsClosedByTheWatchdog() async throws {
        let sink = CapturingSink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let hub = TestAccessories.sensorHub()
        let transport = StallingTransport()
        let running = try await startServer(accessory: hub.accessory, timings: .fast { $0.sendStallTimeout = .milliseconds(400) },
                                            transport: transport)
        defer { await running.stop() }
        let gone = try await running.pairedClient()
        #expect(try await gone.subscribe(aid: 1, iid: hub.switchEvent.iid) == 204)
        #expect(await running.server.sessionCount == 1)

        transport.stallAcceptedConnections()
        hub.switchEvent.sendEvent(.uint(0))   // one frame: the writer is stuck in `send`, the queue is nearly empty
        #expect(await eventually { transport.blockedSends == 1 })
        #expect(await gone.isClosed == false, "not before the limit")
        #expect(await gone.waitUntilClosed(timeout: .seconds(5)))
        #expect(await eventually { await running.server.connectionCount == 0 })
        #expect(await running.server.sessionCount == 0)
        #expect(sink.messages.contains { $0.contains("the controller accepted no data for") })
    }

    /// Side finding of the same review: when the plaintext pair-verify M4 was the write that overflowed the queue (a
    /// paired controller pipelining hundreds of requests without reading), the session was still installed on the
    /// connection that write had just closed — logged as verified, `sessionsChanged` broadcast, never `markClosed`.
    @Test func pairVerifyM4ThatOverflowsTheQueueInstallsNoSession() async throws {
        let sink = CapturingSink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let transport = StallingTransport()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, transport: transport)
        defer { await running.stop() }
        let controllerID = UUID().uuidString
        let key = HAPLongTermKey()
        await running.server.addPairingForTesting(controllerID: controllerID, publicKey: key.publicKey)
        let sessions = Box<[Int]>([])
        let events = running.server.events
        let watcher = Task {
            for await event in events {
                if case .sessionsChanged(let count) = event { sessions.update { $0.append(count) } }
            }
        }
        defer { watcher.cancel() }

        let client = try await HAPTestClient.connect(port: running.port, controllerID: controllerID, longTermKey: key,
                                                     pairing: running.accessoryPairing)
        let (_, m3) = try await client.pairVerifyUpToM3()
        transport.stallAcceptedConnections()
        // 513 requests answered 470 fill the writer (one) and the queue (512); M4 is the write that overflows.
        var pipelined = Data()
        for _ in 0..<513 { pipelined.append(Data("GET /accessories HTTP/1.1\r\nHost: x\r\n\r\n".utf8)) }
        let m3Head = HTTPRequestHead(method: "POST", target: "/pair-verify",
                                     headers: HTTPHeaders([("Host", "x"), ("Content-Type", "application/pairing+tlv8"),
                                                           ("Content-Length", String(m3.data.count))]))
        pipelined.append(HTTPSerializer.request(m3Head, body: m3.data))
        try await client.sendUnencrypted(pipelined)
        #expect(await client.waitUntilClosed())
        #expect(await eventually { await running.server.connectionCount == 0 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(sink.messages.contains { $0.contains("127.0.0.1: the controller is not reading") })
        #expect(!sink.messages.contains { $0.contains("HAP session verified for controller \(controllerID)") })
        #expect(sessions.value.isEmpty, "\(sessions.value)")
        #expect(await running.server.sessionCount == 0)
    }

    // MARK: - Idle connections

    /// With `connectionPruneThreshold` connections open, a new connection closes those idle for longer than
    /// `maximumIdleTime` (HAP-NodeJS), verified or not; below the threshold idle connections stay.
    @Test func idleConnectionsArePrunedOnceThereAreMany() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, timings: .fast {
            $0.connectionPruneThreshold = 4
            $0.maximumIdleTime = .seconds(2)
        })
        defer { await running.stop() }
        let idle = try await running.pairedClient()
        let active = try await running.pairedClient()
        try await Task.sleep(for: .milliseconds(2400))
        #expect(try await active.request("GET", "/accessories").status == 200)

        let third = try await HAPTestClient.connect(port: running.port)
        #expect(await eventually { await running.server.connectionCount == 3 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await idle.isClosed == false, "3 connections: below the threshold")

        let fourth = try await HAPTestClient.connect(port: running.port)
        #expect(await idle.waitUntilClosed())
        #expect(await eventually { await running.server.connectionCount == 3 })
        #expect(await active.isClosed == false)
        #expect(try await active.request("GET", "/accessories").status == 200)
        #expect(try await third.request("GET", "/accessories").status == 470)
        #expect(try await fourth.request("GET", "/accessories").status == 470)
        #expect(await running.server.sessionCount == 1)
    }
}
#endif
