#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import PlatformApple
import Synchronization
import TestSupport
import Testing
@testable import HAP

private func m1() -> TLVBuilder {
    var builder = TLVBuilder()
    builder.add(0x00, uint8: 0)
    builder.add(0x06, uint8: 1)
    return builder
}

/// Limits on what an unverified LAN peer can make the accessory do, and the session switch at pair-verify M4
/// (review of W1-1).
@Suite(.timeLimit(.minutes(1))) struct PreVerifyHardeningTests {
    // MARK: - One pair-setup at a time

    @Test func concurrentPairSetupIsBusy() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let first = try await HAPTestClient.connect(port: running.port)
        let second = try await HAPTestClient.connect(port: running.port)

        let started = try await first.pairingRequest("/pair-setup", m1())
        #expect(started.uint8(0x06) == 2 && started.uint8(0x07) == nil && started.data(0x02) != nil)
        let refused = try await second.pairingRequest("/pair-setup", m1())
        #expect(refused.uint8(0x06) == 2)
        #expect(refused.uint8(0x07) == 7)   // Busy
        #expect(await running.server.failedPairSetupAttempts == 0)

        // The first controller can still finish (restarting from M1 on its own connection is allowed).
        try await first.pairSetup(code: running.setupCode)
        #expect(await running.server.isPaired)
        let late = try await second.pairingRequest("/pair-setup", m1())
        #expect(late.uint8(0x07) == 6)   // Unavailable: already paired
    }

    @Test func pairSetupSlotIsReleasedWhenItsConnectionCloses() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let first = try await HAPTestClient.connect(port: running.port)
        _ = try await first.pairingRequest("/pair-setup", m1())
        let second = try await HAPTestClient.connect(port: running.port)
        #expect(try await second.pairingRequest("/pair-setup", m1()).uint8(0x07) == 7)
        await first.close()
        #expect(await eventually { await running.server.pairSetupOwner == nil })
        let resumed = try await second.pairingRequest("/pair-setup", m1())
        #expect(resumed.uint8(0x07) == nil && resumed.data(0x03) != nil)
    }

    @Test func abandonedPairSetupSlotExpires() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory,
                                            timings: .fast { $0.pairSetupTimeout = .milliseconds(500) })
        defer { await running.stop() }
        let first = try await HAPTestClient.connect(port: running.port)
        _ = try await first.pairingRequest("/pair-setup", m1())
        let second = try await HAPTestClient.connect(port: running.port)
        #expect(try await second.pairingRequest("/pair-setup", m1()).uint8(0x07) == 7)
        try await Task.sleep(for: .milliseconds(700))
        #expect(try await second.pairingRequest("/pair-setup", m1()).uint8(0x07) == nil)
        // The first connection lost the slot: its M3 is out of order now.
        var m3 = TLVBuilder()
        m3.add(0x06, uint8: 3)
        m3.add(0x03, Data(repeating: 1, count: 384))
        m3.add(0x04, Data(repeating: 2, count: 64))
        let stale = try await first.request("POST", "/pair-setup", body: m3.data, contentType: "application/pairing+tlv8")
        #expect(try stale.tlv().uint8(0x07) == 1)
    }

    // MARK: - Unverified connections

    @Test func idleUnverifiedConnectionsAreClosed() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory,
                                            timings: .fast { $0.unverifiedIdleTimeout = .milliseconds(300) })
        defer { await running.stop() }
        let verified = try await running.pairedClient()
        let idle = try await HAPTestClient.connect(port: running.port)
        #expect(await idle.waitUntilClosed(timeout: .seconds(5)))
        try await Task.sleep(for: .milliseconds(400))
        #expect(await verified.isClosed == false)
        #expect(try await verified.request("GET", "/accessories").status == 200)
    }

    @Test func unverifiedConnectionsAreCapped() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory,
                                            timings: .fast { $0.maximumUnverifiedConnections = 2 })
        defer { await running.stop() }
        let verified = try await running.pairedClient()
        let oldest = try await HAPTestClient.connect(port: running.port)
        #expect(await eventually { await running.server.connectionCount == 2 })
        let middle = try await HAPTestClient.connect(port: running.port)
        #expect(await eventually { await running.server.connectionCount == 3 })
        let newest = try await HAPTestClient.connect(port: running.port)
        #expect(await oldest.waitUntilClosed())
        #expect(await middle.isClosed == false)
        #expect(try await newest.request("GET", "/accessories").status == 470)
        #expect(try await middle.request("GET", "/accessories").status == 470)
        #expect(try await verified.request("GET", "/accessories").status == 200)
    }

    /// Review finding (W4 round 2): the connection running pair-setup was closed after `unverifiedIdleTimeout` without
    /// traffic between M2 and M3, while the user may still be typing the setup code shown in the app (the controller
    /// sends M1 before it asks for the code).
    @Test func pairSetupWaitingForTheSetupCodeIsNotClosedAsIdle() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory,
                                            timings: .fast { $0.unverifiedIdleTimeout = .milliseconds(300) })
        defer { await running.stop() }
        let client = try await HAPTestClient.connect(port: running.port)
        try await client.pairSetup(code: running.setupCode, pauseAfterM2: .milliseconds(1000))
        #expect(await running.server.isPaired)
        // Other unverified connections are still closed when idle.
        let idle = try await HAPTestClient.connect(port: running.port)
        #expect(await idle.waitUntilClosed(timeout: .seconds(5)))
    }

    /// The pair-setup connection's own idle limit still ends a pair-setup that was abandoned after M2.
    @Test func abandonedPairSetupConnectionIsClosedAfterItsOwnLimit() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory,
                                            timings: .fast {
                                                $0.unverifiedIdleTimeout = .milliseconds(200)
                                                $0.pairSetupIdleTimeout = .milliseconds(1200)
                                            })
        defer { await running.stop() }
        let client = try await HAPTestClient.connect(port: running.port)
        let m2 = try await client.pairingRequest("/pair-setup", m1())
        #expect(m2.uint8(0x06) == 2 && m2.uint8(0x07) == nil)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await client.isClosed == false)
        #expect(await client.waitUntilClosed(timeout: .seconds(5)))
        #expect(await eventually { await running.server.pairSetupOwner == nil })
    }

    @Test func oversizedUnverifiedRequestsCloseTheConnection() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        // A pair-setup body far beyond any pairing TLV.
        let big = try await HAPTestClient.connect(port: running.port)
        try await big.sendUnencrypted(Data("POST /pair-setup HTTP/1.1\r\nContent-Length: 100000\r\n\r\n".utf8))
        #expect(await big.waitUntilClosed())
        // A head that never ends.
        let endless = try await HAPTestClient.connect(port: running.port)
        try await endless.sendUnencrypted(Data("POST /pair-setup HTTP/1.1\r\nX-Filler: ".utf8) + Data(repeating: 0x61, count: 12_000))
        #expect(await endless.waitUntilClosed())
        // Normal pre-verify traffic is unaffected.
        let normal = try await HAPTestClient.connect(port: running.port)
        #expect(try await normal.request("POST", "/identify").status == 204)
    }

    // MARK: - What unverified peers can put into the log

    /// The pair-verify M3 identifier is chosen by the peer before any authentication (the M3 key needs no pairing). It
    /// reaches the log without control characters and cut to a bounded length, and repeated failures from one address
    /// are not logged one by one. Regression: CR/LF/ESC (forged log lines) and 15 KB identifiers were logged verbatim,
    /// once per M3.
    @Test func pairVerifyIdentifiersAreSanitizedAndFailuresRateLimited() async throws {
        let sink = CapturingSink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        _ = try await running.pairedClient()
        let marker = "PROBE-\(UUID().uuidString)"
        let forged = marker + "\n2026-09-30 14:03:12 ERROR [RTSP] Camera password is hunter2 \u{1B}[31m\r\u{07}"
            + String(repeating: "x", count: 15_000)
        let attacker = try await HAPTestClient.connect(port: running.port, controllerID: forged, pairing: running.accessoryPairing)
        await #expect(throws: HAPTestClientError.pairing(step: 4, error: 2)) { try await attacker.pairVerify() }
        // The connection stays open after a failed M3; more rounds (and other identifiers) follow.
        for round in 0..<50 {
            await #expect(throws: HAPTestClientError.pairing(step: 4, error: 2)) {
                try await attacker.pairVerify(as: ("\(marker)-\(round)\r\nforged", HAPLongTermKey()))
            }
        }

        let logged = sink.messages.filter { $0.contains(marker) }
        #expect(logged.count == 1, "\(logged.count) entries: \(logged.prefix(3))")
        let message = try #require(logged.first)
        #expect(!message.unicodeScalars.contains { $0.properties.generalCategory == .control }, "\(message.debugDescription)")
        #expect(message.count < 200, "\(message.count) characters")
        #expect(message.contains("127.0.0.1"), "names the peer's address: \(message)")
    }

    /// Review finding (W4 round 2): each connect beyond the unverified-connection cap logged "Closing unverified HAP
    /// connection …: too many unverified connections" (and each idle close a line too), so a LAN peer connecting in a
    /// loop could replace the 1000-entry in-app log in under a second. Logged at most once per minute now.
    @Test func connectionChurnIsNotLoggedOneByOne() async throws {
        let sink = CapturingSink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let name = "Churn-\(UUID().uuidString.prefix(8))"
        let accessory = Accessory(info: AccessoryInfo(name: name, manufacturer: "CameraBridge", model: "CB-Test", serialNumber: "SN-CHURN",
                                                      firmwareRevision: "1.0.0"), category: .sensor)
        let running = try await startServer(accessory: accessory, timings: .fast {
            $0.maximumUnverifiedConnections = 2
            $0.unverifiedIdleTimeout = .milliseconds(300)
        })
        defer { await running.stop() }
        var clients: [HAPTestClient] = []
        for _ in 0..<40 { clients.append(try await HAPTestClient.connect(port: running.port)) }
        // 38 are closed for the cap, the last two once they are idle.
        #expect(await eventually { await running.server.connectionCount == 0 })
        for client in clients { #expect(await client.waitUntilClosed()) }

        let capped = sink.messages.filter { $0.contains("too many unverified connections") }
        #expect(capped.count <= 3, "\(capped.count) lines")   // this server's one, and maybe another test's
        #expect(capped.contains { $0.contains(name) })
        let idle = sink.messages.filter { $0.contains(name) && $0.contains("idle") }
        #expect(idle.count == 1, "\(idle)")
    }

    /// Review finding (W4 round 3): `POST /identify`, which an unpaired accessory answers before pair-verify, logged an
    /// info line per request, so one LAN peer pipelining identify requests (46 bytes each) replaced the 1000-entry in-app
    /// log in well under a second — the sensors bridge is unpaired on its fixed port until it is added to Home. Logged at
    /// most once per minute per remote address now; every identify still reaches the accessory.
    @Test func identifyRequestsAreNotLoggedOneByOne() async throws {
        let sink = CapturingSink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let name = "Identify-\(UUID().uuidString.prefix(8))"
        let accessory = Accessory(info: AccessoryInfo(name: name, manufacturer: "CameraBridge", model: "CB-Test", serialNumber: "SN-IDENTIFY",
                                                      firmwareRevision: "1.0.0"), category: .sensor)
        let identified = Mutex(0)
        accessory.onIdentify { identified.withLock { $0 += 1 } }
        let running = try await startServer(accessory: accessory)
        defer { await running.stop() }

        let request = Data("POST /identify HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n".utf8)
        let (connections, perConnection) = (3, 200)
        for _ in 0..<connections {
            let peer = try await HAPTestClient.connect(port: running.port)
            var pipelined = Data()
            for _ in 0..<perConnection { pipelined.append(request) }
            try await peer.sendUnencrypted(pipelined)
            var statuses: [Int] = []
            for _ in 0..<perConnection { statuses.append(try await peer.nextResponse().status) }
            #expect(statuses.allSatisfy { $0 == 204 }, "\(Set(statuses))")
            await peer.close()
        }
        #expect(identified.withLock { $0 } == connections * perConnection)

        let logged = sink.messages.filter { $0.contains("Identify requested for \(name)") }
        #expect(logged.count == 1, "\(logged.count) lines: \(logged.prefix(3))")
        #expect(logged.first?.contains("127.0.0.1") == true, "names the peer's address: \(logged.first ?? "")")
    }

    @Test func loggableControllerIDs() {
        let uuid = UUID().uuidString
        #expect(AccessoryServer.loggable(controllerID: uuid) == uuid)
        #expect(AccessoryServer.loggable(controllerID: "ctrl-1_a.b:c") == "ctrl-1_a.b:c")
        #expect(AccessoryServer.loggable(controllerID: "a\nb\rc\u{1B}[31m\u{07}d e\r\nf") == "a?b?c??31m?d?e?f")
        #expect(AccessoryServer.loggable(controllerID: "") == "\"\"")
        let long = AccessoryServer.loggable(controllerID: String(repeating: "x", count: 15_000))
        #expect(long == String(repeating: "x", count: 64) + "… (15000 bytes)")
        #expect(AccessoryServer.loggable(controllerID: "é" + String(repeating: "y", count: 70)).hasPrefix("?yyy"))
    }

    @Test func unauthenticatedWarningLimiter() {
        var limiter = UnauthenticatedWarningLimiter(interval: .seconds(60), capacity: 2)
        let start = ContinuousClock.now
        #expect(limiter.admit("pv|10.0.0.1", at: start) == 0)
        #expect(limiter.admit("pv|10.0.0.1", at: start + .seconds(1)) == nil)
        #expect(limiter.admit("pv|10.0.0.1", at: start + .seconds(59)) == nil)
        #expect(limiter.admit("pv|10.0.0.2", at: start + .seconds(2)) == 0, "other addresses have their own budget")
        // After the interval the next one passes and reports what was suppressed.
        #expect(limiter.admit("pv|10.0.0.1", at: start + .seconds(61)) == 2)
        #expect(limiter.admit("pv|10.0.0.1", at: start + .seconds(62)) == nil)
        // Bounded: a third key evicts the least recently logged one (10.0.0.2), which starts over.
        #expect(limiter.admit("pv|10.0.0.3", at: start + .seconds(63)) == 0)
        #expect(limiter.trackedKeyCount == 2)
        #expect(limiter.admit("pv|10.0.0.2", at: start + .seconds(64)) == 0)
    }

    // MARK: - Pair-verify M3/M4 session switch

    @Test func requestPipelinedBehindPairVerifyM3IsDecrypted() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let controllerID = UUID().uuidString
        let key = HAPLongTermKey()
        await running.server.addPairingForTesting(controllerID: controllerID, publicKey: key.publicKey)
        let client = try await HAPTestClient.connect(port: running.port, controllerID: controllerID, longTermKey: key,
                                                     pairing: running.accessoryPairing)
        let response = try await client.pairVerifyPipelining("GET", "/accessories")
        #expect(response.status == 200)
        #expect(try response.json()["accessories"]?[0]?["aid"] == 1)
        #expect(try await client.request("GET", "/accessories").status == 200)
    }

    @Test func reverifyAsAnotherControllerDropsSubscriptions() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        #expect(try await client.subscribe(aid: 1, iid: hub.motionDetected.iid) == 204)
        let guestKey = HAPLongTermKey()
        _ = try await client.pairings(method: 3, identifier: "guest-reverify", publicKey: guestKey.publicKey, permissions: 0)

        try await client.pairVerify(as: ("guest-reverify", guestKey))
        hub.motionDetected.update(.bool(true))
        try await Task.sleep(for: .milliseconds(400))
        #expect(await client.bufferedEventCount == 0)
        // The guest's own subscriptions work.
        #expect(try await client.subscribe(aid: 1, iid: hub.motionDetected.iid) == 204)
        hub.motionDetected.update(.bool(false))
        #expect(try await client.nextEvent().json()["characteristics"]?[0]?["value"] == 0)
    }

    @Test func reverifyAsTheSameControllerKeepsSubscriptions() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        #expect(try await client.subscribe(aid: 1, iid: hub.motionDetected.iid) == 204)
        try await client.pairVerify()
        hub.motionDetected.update(.bool(true))
        #expect(try await client.nextEvent().json()["characteristics"]?[0]?["value"] == 1)
    }
}
#endif
