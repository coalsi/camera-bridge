#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import HAPCore
import Synchronization
import Testing
@testable import HAP
import TestSupport

private func child(_ serial: String) -> Accessory {
    let accessory = Accessory(info: AccessoryInfo(name: "Sensor \(serial)", manufacturer: "CameraBridge", model: "Occupancy",
                                                  serialNumber: serial, firmwareRevision: "1.0"), category: .sensor)
    accessory.addService(Service(.occupancySensor, name: "Person"))
    return accessory
}

/// Plan W1-1 items 2 and 4 (server level), 12 (bridges) and 13 (mDNS).
@Suite(.timeLimit(.minutes(1))) struct BridgeAndAdvertisingTests {
    @Test func bridgedAccessoriesGetStableAIDsAndReachability() async throws {
        let store = InMemoryHAPStore()
        let bridge = Accessory(info: TestAccessories.info, category: .bridge)
        let a = child("camera.1.person")
        let b = child("camera.2.person")
        bridge.addBridgedAccessory(a)
        bridge.addBridgedAccessory(b)
        let running = try await startServer(accessory: bridge, store: store)
        let client = try await running.pairedClient()
        let json = try await client.accessories()
        let aids = try #require(json["accessories"]?.arrayValue).compactMap { $0["aid"]?.intValue }
        #expect(aids == [1, 2, 3])
        #expect(a.aid == 2 && b.aid == 3)
        let occupancy = try #require(b.services.last?.existingCharacteristic(.occupancyDetected))
        let otherOccupancy = try #require(a.services.last?.existingCharacteristic(.occupancyDetected))

        b.setReachable(false)
        let unreachable = try await client.getJSON("/characteristics?id=3.\(occupancy.iid),2.\(otherOccupancy.iid)")
        #expect(unreachable.status == 207)
        #expect(unreachable.json?["characteristics"]?[0] == ["aid": 3, "iid": .int(Int64(occupancy.iid)), "status": -70402])
        #expect(unreachable.json?["characteristics"]?[1]?["status"] == 0)
        let write = try await client.writeCharacteristics([["aid": 3, "iid": .int(Int64(occupancy.iid)), "ev": true]])
        #expect(write.status == 204)
        b.setReachable(true)
        #expect(try await client.getJSON("/characteristics?id=3.\(occupancy.iid)").status == 200)

        // Events carry the bridged aid.
        occupancy.update(.uint(1))
        let event = try await client.nextEvent()
        #expect(try event.json()["characteristics"]?[0]?["aid"] == 3)
        await running.stop()

        // Restart with a different order plus a new accessory: existing aids are kept.
        let bridge2 = Accessory(info: TestAccessories.info, category: .bridge)
        let c = child("camera.3.person")
        let b2 = child("camera.2.person")
        bridge2.addBridgedAccessory(c)
        bridge2.addBridgedAccessory(b2)
        let restarted = try await startServer(accessory: bridge2, store: store)
        defer { await restarted.stop() }
        #expect(b2.aid == 3)
        #expect(c.aid == 4)
        #expect(b2.services.map(\.iid) == b.services.map(\.iid))
    }

    /// HAP-NodeJS adds ProtocolInformation (A2) to the published accessory only (Accessory.ts `publish`); bridged
    /// accessories list AccessoryInformation and their own services. Regression: every bridged aid carried an A2 service.
    @Test func protocolInformationOnlyOnThePublishedAccessory() async throws {
        let bridge = Accessory(info: TestAccessories.info, category: .bridge)
        let a = child("camera.1.person")
        let b = child("camera.2.person")
        bridge.addBridgedAccessory(a)
        bridge.addBridgedAccessory(b)
        let running = try await startServer(accessory: bridge)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        let accessories = try #require(try await client.accessories()["accessories"]?.arrayValue)
        let types = accessories.map { accessory in (accessory["services"]?.arrayValue ?? []).compactMap { $0["type"]?.stringValue } }
        #expect(types == [["3E", "A2"], ["3E", "86"], ["3E", "86"]])
        let version = try #require(accessories[0]["services"]?[1]?["characteristics"]?[0])
        #expect(version["type"] == "37" && version["value"] == "1.1.0")
        #expect(a.services.map(\.type) == [.accessoryInformation, .occupancySensor])

        // Out of the bridge it is a standalone accessory again (with A2).
        bridge.removeBridgedAccessory(b)
        #expect(b.services.map(\.type) == [.accessoryInformation, .protocolInformation, .occupancySensor])
        let remaining = try #require(try await client.accessories()["accessories"]?.arrayValue)
        #expect(remaining.map { ($0["services"]?.arrayValue ?? []).compactMap { $0["type"]?.stringValue } } == [["3E", "A2"], ["3E", "86"]])
    }

    @Test func bridgedAccessoryAddedWhileRunningAppearsAndBumpsConfigNumber() async throws {
        let bridge = Accessory(info: TestAccessories.info, category: .bridge)
        bridge.addBridgedAccessory(child("one"))
        let running = try await startServer(accessory: bridge)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        #expect(running.advertiser.currentTXT?["c#"] == "1")
        let late = child("two")
        bridge.addBridgedAccessory(late)
        #expect(late.aid == 3)
        #expect(await running.advertiser.waitForTXT { $0["c#"] == "2" })
        let aids = try #require(try await client.accessories()["accessories"]?.arrayValue).compactMap { $0["aid"]?.intValue }
        #expect(aids == [1, 2, 3])
        bridge.removeBridgedAccessory(late)
        #expect(await running.advertiser.waitForTXT { $0["c#"] == "3" })
    }

    @Test func iidsStableAcrossServerRestart() async throws {
        let store = InMemoryHAPStore()
        let first = TestAccessories.sensorHub()
        let running = try await startServer(accessory: first.accessory, store: store)
        await running.stop()
        let second = TestAccessories.sensorHub()
        let restarted = try await startServer(accessory: second.accessory, store: store)
        defer { await restarted.stop() }
        #expect(first.accessory.services.map(\.iid) == second.accessory.services.map(\.iid))
        #expect(first.accessory.services.flatMap(\.characteristics).map(\.iid) == second.accessory.services.flatMap(\.characteristics).map(\.iid))
        #expect(second.accessory.informationService.iid == 1)
        #expect(try store.loadState()?.configNumber == 1)
    }

    @Test func configNumberChangesOnlyWithStructureAndPersists() async throws {
        let store = InMemoryHAPStore()
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory, store: store)
        #expect(running.advertiser.currentTXT?["c#"] == "1")
        hub.motionDetected.update(.bool(true))
        await running.server.configurationDidChange()
        #expect(try store.loadState()?.configNumber == 1)

        hub.motion.characteristic(.statusFault)
        await running.server.configurationDidChange()
        #expect(try store.loadState()?.configNumber == 2)
        #expect(await running.advertiser.waitForTXT { $0["c#"] == "2" })
        await running.stop()

        // Same structure after restart: c# unchanged. Without the extra characteristic: bumped again.
        let same = TestAccessories.sensorHub()
        same.motion.characteristic(.statusFault)
        let again = try await startServer(accessory: same.accessory, store: store)
        #expect(again.advertiser.currentTXT?["c#"] == "2")
        await again.stop()
        let changed = TestAccessories.sensorHub()
        let third = try await startServer(accessory: changed.accessory, store: store)
        defer { await third.stop() }
        #expect(third.advertiser.currentTXT?["c#"] == "3")
    }

    /// Hardening plan WS-C 6 (audit B1): the camera's supported stream and recording configurations are values a hub caches
    /// from `/accessories` and re-reads only when `c#` moves; a change of only those values (a new picture size, new
    /// recording options after an update) used to leave `c#` alone, so the hub kept selecting against stale options.
    @Test func configNumberBumpsWhenOnlyAStaticConfigurationValueChanges() async throws {
        let store = InMemoryHAPStore()
        func hub(video: UInt8) -> SensorHub {
            let hub = TestAccessories.sensorHub(category: .ipCamera)
            hub.recording.characteristic(.supportedVideoRecordingConfiguration).update(.data(Data([1, 2, video])))
            return hub
        }
        let first = try await startServer(accessory: hub(video: 7).accessory, store: store)
        #expect(first.advertiser.currentTXT?["c#"] == "1")
        await first.stop()

        let same = try await startServer(accessory: hub(video: 7).accessory, store: store)
        #expect(same.advertiser.currentTXT?["c#"] == "1", "the same values: c# stays")
        await same.stop()

        let changed = try await startServer(accessory: hub(video: 8).accessory, store: store)
        #expect(changed.advertiser.currentTXT?["c#"] == "2", "only a supported-configuration value changed")
        #expect(try store.loadState()?.configNumber == 2)
        await changed.stop()

        let again = try await startServer(accessory: hub(video: 8).accessory, store: store)
        #expect(again.advertiser.currentTXT?["c#"] == "2")
        await again.stop()
    }

    /// The first start after this change: a state saved with the old value-free hash gets one bump (the hash now covers the
    /// values) and nothing else changes (the identity, the pairings, the identifiers); the next start is stable. An
    /// accessory without static-value characteristics (the sensors bridge) keeps exactly the old hash: no bump at all.
    @Test func theFirstStartAfterTheUpdateBumpsOnceAndKeepsTheIdentity() async throws {
        let store = InMemoryHAPStore()
        func camera() -> SensorHub {
            let camera = TestAccessories.sensorHub(category: .ipCamera)
            camera.recording.characteristic(.supportedVideoRecordingConfiguration).update(.data(Data([1, 2, 3])))
            return camera
        }
        let first = try await startServer(accessory: camera().accessory, store: store)
        let identity = try #require(try store.loadIdentity())
        await first.server.addPairingForTesting(controllerID: UUID().uuidString, publicKey: HAPLongTermKey().publicKey)
        await first.stop()
        // The state as the previous version saved it: the plain structure hash.
        var legacy = try #require(try store.loadState())
        let structureOnly = try #require(legacy.configHash.split(separator: ".").first.map(String.init))
        #expect(legacy.configHash.contains("."), "static values are part of the hash")
        legacy.configHash = structureOnly
        try store.saveState(legacy)
        let pairings = legacy.pairings

        let second = try await startServer(accessory: camera().accessory, store: store)
        #expect(second.advertiser.currentTXT?["c#"] == "2", "bumped once")
        #expect(try store.loadIdentity()?.deviceID == identity.deviceID && (try store.loadIdentity())?.setupCode == identity.setupCode)
        #expect(try store.loadState()?.pairings == pairings)
        await second.stop()
        let third = try await startServer(accessory: camera().accessory, store: store)
        #expect(third.advertiser.currentTXT?["c#"] == "2", "stable afterwards")
        await third.stop()

        // No static values: the hash is the structure hash, with no suffix.
        let plain = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await plain.stop() }
        #expect(try plain.store.loadState()?.configHash.contains(".") == false)
        #expect(try plain.store.loadState()?.configHash.isEmpty == false)
    }

    @Test func advertisementCarriesTheHAPTXTRecord() async throws {
        let hub = TestAccessories.sensorHub(category: .ipCamera)
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let record = try #require(running.advertiser.records.first)
        #expect(record.advertisement.type == "_hap._tcp")
        #expect(record.advertisement.name == "CameraBridge Test")
        #expect(record.advertisement.port == running.port)
        let identity = try #require(try running.store.loadIdentity())
        let txt = record.advertisement.txt
        #expect(txt == ["c#": "1", "ff": "0", "id": identity.deviceID.description, "md": "CB-Test", "pv": "1.1", "s#": "1", "sf": "1",
                        "ci": "17", "sh": SetupPayload.setupHash(setupID: identity.setupID, deviceID: identity.deviceID)])
    }

    @Test func txtUpdatesOnPairAndUnpair() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        #expect(await running.advertiser.waitForTXT { $0["sf"] == "0" })
        _ = try await client.pairings(method: 4, identifier: client.controllerID)
        #expect(await running.advertiser.waitForTXT { $0["sf"] == "1" })
        let updates = try #require(running.advertiser.records.first?.txtUpdates)
        #expect(updates.map { $0["sf"] } == ["0", "1"])
    }

    @Test func txtUpdatesAreDebounced() async throws {
        let timings = HAPServerTimings(handlerWarning: .seconds(3), handlerTimeout: .seconds(9), resourceWarning: .seconds(8),
                                       resourceTimeout: .seconds(25), eventCoalescing: .milliseconds(250), configurationDebounce: .milliseconds(20),
                                       advertisementDebounce: .milliseconds(300))
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory, timings: timings)
        defer { await running.stop() }
        hub.motion.characteristic(.statusFault)
        await running.server.configurationDidChange()
        hub.motion.characteristic(.statusTampered)
        await running.server.configurationDidChange()
        try await Task.sleep(for: .milliseconds(100))
        #expect(running.advertiser.records.first?.txtUpdates.isEmpty == true)
        #expect(await running.advertiser.waitForTXT { $0["c#"] == "3" })
        #expect(running.advertiser.records.first?.txtUpdates.count == 1)
    }

    @Test func localNetworkDenialIsReported() async throws {
        let advertiser = RecordingAdvertiser()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, advertiser: advertiser)
        defer { await running.stop() }
        let events = running.server.events
        let service = try #require(advertiser.services.first)
        service.fail(.localNetworkDenied)
        var iterator = events.makeAsyncIterator()
        var reported: AccessoryServerEvent?
        while let event = await iterator.next() {
            if case .advertisingFailed = event { reported = event; break }
        }
        guard case .advertisingFailed(_, let denied)? = reported else {
            Issue.record("no advertisingFailed event")
            return
        }
        #expect(denied)
    }

    @Test func advertiseErrorIsReportedAndServerKeepsRunning() async throws {
        let advertiser = RecordingAdvertiser()
        advertiser.failNextAdvertise(with: .localNetworkDenied)
        let configuration = AccessoryServerConfiguration(port: 0, advertise: true, serviceName: "Denied", loopbackOnly: true)
        let server = AccessoryServer(accessory: TestAccessories.sensorHub().accessory, configuration: configuration, store: InMemoryHAPStore(),
                                     transport: PlatformNetworkTransport(), advertiser: advertiser)
        let events = server.events
        try await server.start()
        defer { await server.stop() }
        var iterator = events.makeAsyncIterator()
        var seen: [AccessoryServerEvent] = []
        while seen.count < 2, let event = await iterator.next() { seen.append(event) }
        #expect(seen.first == .listening(port: try #require(await server.port)))
        guard case .advertisingFailed(_, true)? = seen.last else {
            Issue.record("expected advertisingFailed(localNetworkDenied: true), got \(seen)")
            return
        }
        // Advertising can be retried (e.g. after the user grants Local Network access).
        await server.restartAdvertising()
        #expect(advertiser.records.count == 1)
    }

    @Test func advertiseFalseNeverAdvertises() async throws {
        let advertiser = RecordingAdvertiser()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, advertiser: advertiser, advertise: false)
        defer { await running.stop() }
        _ = try await running.pairedClient()
        try await Task.sleep(for: .milliseconds(100))
        #expect(advertiser.records.isEmpty)
    }

    @Test func stopWithdrawsTheAdvertisement() async throws {
        let advertiser = RecordingAdvertiser()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, advertiser: advertiser)
        await running.stop()
        #expect(advertiser.records.first?.cancelled == true)
    }

    @Test func extrasArePersisted() async throws {
        let store = InMemoryHAPStore()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, store: store)
        defer { await running.stop() }
        try await running.server.store(extra: Data([1, 2, 3]), forKey: "recording")
        #expect(await running.server.extra(forKey: "recording") == Data([1, 2, 3]))
        #expect(try store.loadState()?.extras["recording"] == Data([1, 2, 3]))
        try await running.server.store(extra: nil, forKey: "recording")
        #expect(await running.server.extra(forKey: "recording") == nil)
        #expect(try store.loadState()?.extras["recording"] == nil)
    }
}
#endif
