#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import PlatformApple
import Synchronization
import TestSupport
import Testing
@testable import HAP

/// Plan W1-1 item 11: EVENT/1.0 notifications.
@Suite(.timeLimit(.minutes(1))) struct EventTests {
    /// Two threads calling `update` on one characteristic can deliver their notifications in the opposite order of
    /// their stores; the older value must not become the controller's last event (review of W1-1).
    @Test func staleChangeNotificationsAreNotDelivered() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        _ = try await client.subscribe(aid: 1, iid: hub.contactState.iid)
        hub.contactState.update(.uint(1))
        let older = hub.contactState.changeSequence
        #expect(try await client.nextEvent().json()["characteristics"]?[0]?["value"] == 1)
        hub.contactState.update(.uint(0))
        #expect(try await client.nextEvent().json()["characteristics"]?[0]?["value"] == 0)

        // The first update's notification arrives only now.
        let publication = try #require(await running.server.publication)
        publication.characteristicDidChange(hub.contactState, value: .uint(1), origin: nil, sequence: older)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await client.bufferedEventCount == 0)
        #expect(hub.contactState.value == .uint(0))

        // Event-only characteristics (doorbell presses) deliver every event, whatever the order.
        _ = try await client.subscribe(aid: 1, iid: hub.switchEvent.iid)
        hub.switchEvent.sendEvent(.uint(0))
        let press = hub.switchEvent.changeSequence
        _ = try await client.nextEvent()
        hub.switchEvent.sendEvent(.uint(1))
        _ = try await client.nextEvent()
        publication.characteristicDidChange(hub.switchEvent, value: .uint(2), origin: nil, sequence: press)
        #expect(try await client.nextEvent().json()["characteristics"]?[0]?["value"] == 2)
    }

    @Test func motionEventIsImmediateAndWellFormed() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        #expect(try await client.subscribe(aid: 1, iid: hub.motionDetected.iid) == 204)

        let started = ContinuousClock.now
        hub.motionDetected.update(.bool(true))
        let event = try await client.nextEvent()
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .milliseconds(100), "motion event took \(elapsed)")
        #expect(event.version == "EVENT/1.0" && event.status == 200)
        #expect(event.headers["Content-Type"] == "application/hap+json")
        #expect(event.headers["Content-Length"] == String(event.body.count))
        #expect(try event.json() == ["characteristics": [["aid": 1, "iid": .int(Int64(hub.motionDetected.iid)), "value": 1]]])
    }

    @Test func immediateCharacteristicsSkipCoalescing() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        _ = try await client.subscribe(aid: 1, iid: hub.contactState.iid)
        _ = try await client.subscribe(aid: 1, iid: hub.switchEvent.iid)
        for (characteristic, value) in [(hub.contactState, HAPValue.uint(1)), (hub.switchEvent, .uint(0))] {
            let started = ContinuousClock.now
            characteristic.update(value)
            let event = try await client.nextEvent()
            #expect(ContinuousClock.now - started < .milliseconds(100))
            #expect(try event.json()["characteristics"]?[0]?["iid"]?.intValue == Int64(characteristic.iid))
        }
        // ProgrammableSwitchEvent notifies even when the value repeats.
        hub.switchEvent.update(.uint(0))
        #expect(try await client.nextEvent().json()["characteristics"]?[0]?["value"] == 0)
    }

    @Test func regularEventsAreCoalescedFor250ms() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        _ = try await client.subscribe(aid: 1, iid: hub.lightOn.iid)
        let active = hub.motion.characteristic(.statusActive)
        _ = try await client.subscribe(aid: 1, iid: active.iid)

        let started = ContinuousClock.now
        hub.lightOn.update(.bool(true))
        active.update(.bool(true))
        hub.lightOn.update(.bool(false))
        let event = try await client.nextEvent()
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(200), "coalesced event came after \(elapsed)")
        #expect(elapsed < .milliseconds(1000))
        let items = try #require(try event.json()["characteristics"]?.arrayValue)
        // HAP-NodeJS sends the queue reversed: newest first.
        #expect(items == [["aid": 1, "iid": .int(Int64(hub.lightOn.iid)), "value": 0],
                          ["aid": 1, "iid": .int(Int64(active.iid)), "value": 1],
                          ["aid": 1, "iid": .int(Int64(hub.lightOn.iid)), "value": 1]])
        try await Task.sleep(for: .milliseconds(350))
        #expect(await client.bufferedEventCount == 0)
    }

    @Test func identicalQueuedValuesAreDropped() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        let active = hub.motion.characteristic(.statusActive)
        _ = try await client.subscribe(aid: 1, iid: active.iid)
        active.sendEvent(.bool(true))
        active.sendEvent(.bool(true))
        let items = try #require(try await client.nextEvent().json()["characteristics"]?.arrayValue)
        #expect(items.count == 1)
    }

    @Test func unsubscribedAndUnverifiedConnectionsGetNothing() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let subscribed = try await running.pairedClient()
        let other = try await running.verifiedConnection(like: subscribed)
        _ = try await subscribed.subscribe(aid: 1, iid: hub.motionDetected.iid)
        _ = try await other.subscribe(aid: 1, iid: hub.motionDetected.iid)
        #expect(try await other.subscribe(aid: 1, iid: hub.motionDetected.iid, false) == 204)
        hub.motionDetected.update(.bool(true))
        _ = try await subscribed.nextEvent()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await other.bufferedEventCount == 0)
    }

    @Test func changesAreNotSentBackToTheOriginatingSession() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let writer = try await running.pairedClient()
        let watcher = try await running.verifiedConnection(like: writer)
        _ = try await writer.subscribe(aid: 1, iid: hub.lightOn.iid)
        _ = try await watcher.subscribe(aid: 1, iid: hub.lightOn.iid)
        #expect(try await writer.writeCharacteristics([writeItem(1, hub.lightOn, value: 1)]).status == 204)
        let event = try await watcher.nextEvent()
        #expect(try event.json()["characteristics"]?[0]?["value"] == 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await writer.bufferedEventCount == 0)
    }

    @Test func eventsNeverInterleaveWithAResponse() async throws {
        let hub = TestAccessories.sensorHub()
        let motion = hub.motionDetected
        // While this read is in flight, motion fires (an immediate event); the event must follow the response.
        hub.lightOn.onRead { _ async throws(HAPStatus) -> HAPValue in
            motion.update(.bool(true))
            try? await Task.sleep(for: .milliseconds(150))
            return .bool(true)
        }
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        _ = try await client.subscribe(aid: 1, iid: motion.iid)
        let response = try await client.getJSON("/characteristics?id=1.\(hub.lightOn.iid)")
        #expect(response.status == 200)
        let event = try await client.nextEvent()
        #expect(try event.json()["characteristics"]?[0]?["iid"]?.intValue == Int64(motion.iid))
        let log = await client.arrivalLog
        #expect(Array(log.suffix(2)) == ["R 200", "E"])
    }

    @Test func subscriptionsEndWithTheConnection() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let first = try await running.pairedClient()
        _ = try await first.subscribe(aid: 1, iid: hub.motionDetected.iid)
        await first.close()
        #expect(await eventually { await running.server.sessionCount == 0 })
        let second = try await running.verifiedConnection(like: first)
        hub.motionDetected.update(.bool(true))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await second.bufferedEventCount == 0)
        let read = try await second.getJSON("/characteristics?id=1.\(hub.motionDetected.iid)&ev=1")
        #expect(read.json?["characteristics"]?[0]?["ev"] == .bool(false))
    }
}
#endif
