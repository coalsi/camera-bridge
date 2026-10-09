#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import PlatformApple
import Testing
@testable import HAP

/// Plan W1-1 acceptance: the loopback test pairs, reads /accessories, writes a characteristic, receives an EVENT within
/// 100 ms for MotionDetected, removes the pairing, and TXT `sf` flips.
@Suite(.timeLimit(.minutes(1))) struct EndToEndTests {
    @Test func pairReadWriteEventUnpair() async throws {
        let hub = TestAccessories.sensorHub(category: .ipCamera)
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        #expect(running.advertiser.currentTXT?["sf"] == "1")

        let client = try await HAPTestClient.connect(port: running.port)
        try await client.pairSetup(code: running.setupCode)
        #expect(await running.advertiser.waitForTXT { $0["sf"] == "0" })
        try await client.pairVerify()

        let accessories = try await client.accessories()
        let services = try #require(accessories["accessories"]?[0]?["services"]?.arrayValue)
        #expect(services.contains { $0["type"] == "85" })

        #expect(try await client.writeCharacteristics([writeItem(1, hub.lightOn, value: 1)]).status == 204)
        #expect(hub.lightOn.value == .bool(true))
        let readBack = try await client.getJSON("/characteristics?id=1.\(hub.lightOn.iid)")
        #expect(readBack.json?["characteristics"]?[0]?["value"] == 1)

        #expect(try await client.subscribe(aid: 1, iid: hub.motionDetected.iid) == 204)
        let started = ContinuousClock.now
        hub.motionDetected.update(.bool(true))
        let event = try await client.nextEvent(timeout: .seconds(2))
        #expect(ContinuousClock.now - started < .milliseconds(100))
        #expect(try event.json()["characteristics"]?[0]?["value"] == 1)

        let removal = try await client.pairings(method: 4, identifier: client.controllerID)
        #expect(removal.uint8(0x07) == nil)
        #expect(await client.waitUntilClosed())
        #expect(await running.advertiser.waitForTXT { $0["sf"] == "1" })
        #expect(await running.server.isPaired == false)
    }
}
#endif
