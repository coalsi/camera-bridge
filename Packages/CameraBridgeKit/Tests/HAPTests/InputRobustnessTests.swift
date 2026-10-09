#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import HAPCore
import Synchronization
import Testing
@testable import HAP

private func child(_ serial: String, name: String? = nil) -> Accessory {
    let accessory = Accessory(info: AccessoryInfo(name: name ?? "Sensor \(serial)", manufacturer: "CameraBridge", model: "Occupancy",
                                                  serialNumber: serial, firmwareRevision: "1.0"), category: .sensor)
    accessory.addService(Service(.occupancySensor, name: "Person"))
    return accessory
}

/// Controller- and API-supplied values that used to trap or corrupt the accessory database (review of W1-1).
@Suite(.timeLimit(.minutes(1))) struct InputRobustnessTests {
    // MARK: - GET /characteristics ids

    @Test func idsAboveInt64MaxAreRejectedInsteadOfTrapping() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        for ids in ["18446744073709551615.2", "1.18446744073709551615", "9223372036854775808.1", "1.9223372036854775808",
                    "1.2,18446744073709551615.2", "99999999999999999999999.1"] {
            let response = try await client.getJSON("/characteristics?id=\(ids)")
            #expect(response.status == 400, "id=\(ids)")
            #expect(response.json == ["status": -70410], "id=\(ids)")
        }
        // The largest representable id is answered normally (it just does not exist).
        let largest = try await client.getJSON("/characteristics?id=9223372036854775807.1")
        #expect(largest.status == 207)
        #expect(largest.json?["characteristics"]?[0] == ["aid": .int(Int64.max), "iid": 1, "status": -70409])
        // The connection (and the process) survived.
        #expect(try await client.request("GET", "/accessories").status == 200)
    }

    // MARK: - uint64 values

    private static let counter = CharacteristicType(uuid: "0A0B0C0D-0000-1000-8000-00AABBCCDDEE", name: "Counter", format: .uint64,
                                                    permissions: [.pairedRead, .pairedWrite, .events])

    @Test func uint64ValuesAtOrAbove2To64AreRejectedOrSaturated() throws {
        let characteristic = Characteristic(Self.counter)
        // Double(UInt64.max) rounds up to 2^64, which passes a naive `<= Double(UInt64.max)` bound.
        #expect(throws: HAPStatus.invalidValue) { try characteristic.validateIncoming(.double(18_446_744_073_709_551_616.0)) }
        #expect(throws: HAPStatus.invalidValue) { try characteristic.validateIncoming(.double(1e30)) }
        #expect(try characteristic.validateIncoming(.uint(UInt64.max)) == .uint(UInt64.max))
        #expect(try characteristic.validateIncoming(.double(18_000_000_000_000_000_000.0)) == .uint(18_000_000_000_000_000_000))
        #expect(try characteristic.validateIncoming(.int(7)) == .uint(7))
        #expect(throws: HAPStatus.invalidValue) { try characteristic.validateIncoming(.int(-1)) }

        characteristic.update(.float(1e300))
        #expect(characteristic.value == .uint(UInt64.max))
        characteristic.update(.float(18_446_744_073_709_551_616.0))
        #expect(characteristic.value == .uint(UInt64.max))
        characteristic.update(.float(-5))
        #expect(characteristic.value == .uint(0))
    }

    @Test func extremeConstraintsNeverTrap() throws {
        let hugeUnsigned = CharacteristicType(uuid: "0A0B0C0E-0000-1000-8000-00AABBCCDDEE", name: "Huge", format: .uint64,
                                              permissions: [.pairedRead], minValue: 1e30)
        #expect(Characteristic(hugeUnsigned).value == .uint(UInt64.max))
        let hugeSigned = CharacteristicType(uuid: "0A0B0C0F-0000-1000-8000-00AABBCCDDEE", name: "Signed", format: .int,
                                            permissions: [.pairedRead], minValue: 1e30)
        let signed = Characteristic(hugeSigned)
        #expect(signed.value == .int(Int64(Int32.max)))
        signed.update(.float(-1e300))
        #expect(signed.value == .int(Int64(Int32.max)))   // min 1e30 clamps into the int32 range
    }

    @Test func corruptPersistedIdentifiersNeverTrap() throws {
        var state = HAPPersistentState()
        state.nextIID = UInt64.max
        state.nextAID = UInt64.max
        state.iids = ["\(ServiceType.motionSensor.uuid)": UInt64.max]
        state.aids = ["aid|SN-X": UInt64.max]
        let bridge = Accessory(info: TestAccessories.info, category: .bridge)
        bridge.addService(Service(.motionSensor, name: "Motion"))
        let bridged = child("SN-X")
        bridge.addBridgedAccessory(bridged)
        let publication = Publication(root: bridge, state: state)
        defer { publication.unbind() }
        publication.assignIDs()
        let ids = bridge.services.map(\.iid) + bridge.services.flatMap(\.characteristics).map(\.iid) + [bridged.aid]
        #expect(ids.allSatisfy { $0 >= 1 && $0 <= UInt64(Int64.max) })
        #expect(Set(bridge.services.map(\.iid)).count == bridge.services.count)
        #expect(bridged.aid >= 2)
        // The canonical JSON (and so the configuration hash) can be produced.
        #expect(!publication.configurationHash().isEmpty)
    }

    // MARK: - Methods of the pairing routes

    @Test func pairingRoutesAcceptOnlyPOST() async throws {
        let hub = TestAccessories.sensorHub()
        let identified = Mutex(0)
        hub.accessory.onIdentify { identified.withLock { $0 += 1 } }
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let anonymous = try await HAPTestClient.connect(port: running.port)
        for (method, path) in [("GET", "/identify"), ("PUT", "/identify"), ("GET", "/pair-setup"), ("GET", "/pair-verify"),
                               ("DELETE", "/pair-setup")] {
            let response = try await anonymous.request(method, path)
            #expect(response.status == 400, "\(method) \(path)")
            #expect(try response.json() == ["status": -70410], "\(method) \(path)")
        }
        #expect(identified.withLock { $0 } == 0)
        #expect(try await anonymous.request("POST", "/identify").status == 204)
        #expect(identified.withLock { $0 } == 1)

        let client = try await running.pairedClient()
        let list = try await client.request("GET", "/pairings")
        #expect(list.status == 400)
        #expect(try list.json() == ["status": -70410])
        #expect(try await client.pairings(method: 5).uint8(0x06) == 2)
    }

    // MARK: - Bridged accessories

    @Test func bridgedAccessoriesWithTheSameStableKeyGetDistinctStableAIDs() async throws {
        let sink = CapturingSink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let store = InMemoryHAPStore()
        let bridge = Accessory(info: TestAccessories.info, category: .bridge)
        // Derived sensors of one camera that share its serial number.
        let motion = child("CAM-1", name: "Porch Motion")
        let person = child("CAM-1", name: "Porch Person")
        bridge.addBridgedAccessory(motion)
        bridge.addBridgedAccessory(person)
        #expect(sink.messages.contains { $0.contains("Porch Person") && $0.contains("stable key") })

        let running = try await startServer(accessory: bridge, store: store)
        #expect(motion.aid == 2 && person.aid == 3)
        let client = try await running.pairedClient()
        let aids = try #require(try await client.accessories()["accessories"]?.arrayValue).compactMap { $0["aid"]?.intValue }
        #expect(aids == [1, 2, 3])

        // Each aid resolves to its own accessory: reads, and events carry the right aid.
        let occupancy = try #require(person.services.last?.existingCharacteristic(.occupancyDetected))
        let motionOccupancy = try #require(motion.services.last?.existingCharacteristic(.occupancyDetected))
        person.setReachable(false)
        let read = try await client.getJSON("/characteristics?id=3.\(occupancy.iid),2.\(motionOccupancy.iid)")
        #expect(read.json?["characteristics"]?[0]?["status"] == -70402)
        #expect(read.json?["characteristics"]?[1]?["status"] == 0)
        person.setReachable(true)
        _ = try await client.subscribe(aid: 3, iid: occupancy.iid)
        occupancy.update(.uint(1))
        #expect(try await client.nextEvent().json()["characteristics"]?[0]?["aid"] == 3)
        await running.stop()

        // Same accessories after a restart: same aids.
        let bridge2 = Accessory(info: TestAccessories.info, category: .bridge)
        let motion2 = child("CAM-1", name: "Porch Motion")
        let person2 = child("CAM-1", name: "Porch Person")
        bridge2.addBridgedAccessory(motion2)
        bridge2.addBridgedAccessory(person2)
        let restarted = try await startServer(accessory: bridge2, store: store)
        defer { await restarted.stop() }
        #expect(motion2.aid == 2 && person2.aid == 3)
        #expect(person2.services.map(\.iid) == person.services.map(\.iid))
    }

    @Test func bridgeLimitsAreReported() {
        let sink = CapturingSink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let bridge = Accessory(info: AccessoryInfo(name: "Crowded Bridge", manufacturer: "CameraBridge", model: "B", serialNumber: "B-1",
                                                   firmwareRevision: "1"), category: .bridge)
        for index in 0..<149 { bridge.addBridgedAccessory(child("limit-\(index)")) }
        #expect(!sink.messages.contains { $0.contains("Crowded Bridge") })
        bridge.addBridgedAccessory(child("limit-149"))
        #expect(sink.messages.contains { $0.contains("Crowded Bridge") && $0.contains("150 bridged accessories") && $0.contains("149") })

        let crowded = Accessory(info: AccessoryInfo(name: "Crowded Accessory", manufacturer: "CameraBridge", model: "S",
                                                    serialNumber: "S-1", firmwareRevision: "1"), category: .sensor)
        // AccessoryInformation + ProtocolInformation + 98 = 100 services: still fine.
        for index in 0..<98 { crowded.addService(Service(.switch, subtype: "s\(index)")) }
        #expect(!sink.messages.contains { $0.contains("Crowded Accessory") })
        crowded.addService(Service(.switch, subtype: "s98"))
        #expect(sink.messages.contains { $0.contains("Crowded Accessory") && $0.contains("101 services") && $0.contains("100") })
    }
}
#endif
