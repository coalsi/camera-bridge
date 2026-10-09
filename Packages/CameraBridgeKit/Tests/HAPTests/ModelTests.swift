import Foundation
import HAPCore
import Synchronization
import Testing
@testable import HAP

private let testInfo = AccessoryInfo(name: "Cam", manufacturer: "Maker", model: "M1", serialNumber: "S1", firmwareRevision: "2.0.1",
                                     hardwareRevision: "B")

@Suite struct CharacteristicModelTests {
    @Test func defaultValuesFollowFormat() {
        #expect(Characteristic(.motionDetected).value == .bool(false))
        #expect(Characteristic(.name).value == .string(""))
        #expect(Characteristic(.setupEndpoints).value == .data(Data()))
        #expect(Characteristic(.volume).value == .uint(0))
        #expect(Characteristic(.currentAmbientLightLevel).value == .float(0.0001))
        #expect(Characteristic(.currentTemperature).value == .float(0))
        #expect(Characteristic(.chargingState).value == .uint(0))
        #expect(Characteristic(.on, value: .bool(true)).value == .bool(true))
        #expect(Characteristic(.volume, value: .int(40)).value == .uint(40))
    }

    @Test func updateNormalizesAndClamps() {
        let volume = Characteristic(.volume)
        volume.update(.int(250))
        #expect(volume.value == .uint(100))
        volume.update(.bool(true))
        #expect(volume.value == .uint(1))
        let on = Characteristic(.on)
        on.update(.int(1))
        #expect(on.value == .bool(true))
        let lux = Characteristic(.currentAmbientLightLevel)
        lux.update(.int(0))
        #expect(lux.value == .float(0.0001))
        lux.update(.string("bright"))   // wrong kind: ignored
        #expect(lux.value == .float(0.0001))
        let name = Characteristic(.name)
        name.update(.string(String(repeating: "x", count: 100)))
        #expect(name.value == .string(String(repeating: "x", count: 64)))
    }

    @Test func observersSeeChangesOnly() {
        let characteristic = Characteristic(.motionDetected)
        let seen = Mutex<[(HAPValue, UUID?)]>([])
        let origin = UUID()
        let token = characteristic.addObserver { value, origin in seen.withLock { $0.append((value, origin)) } }
        characteristic.update(.bool(true), origin: origin)
        characteristic.update(.bool(true))
        characteristic.update(.bool(false))
        characteristic.removeObserver(token)
        characteristic.update(.bool(true))
        let values = seen.withLock { $0 }
        #expect(values.map(\.0) == [.bool(true), .bool(false)])
        #expect(values.first?.1 == origin && values.last?.1 == nil)
    }

    @Test func eventOnlyCharacteristicsAlwaysNotify() {
        let characteristic = Characteristic(.programmableSwitchEvent)
        let count = Mutex(0)
        _ = characteristic.addObserver { _, _ in count.withLock { $0 += 1 } }
        characteristic.update(.uint(0))
        characteristic.update(.uint(0))
        characteristic.sendEvent(.uint(0))
        #expect(count.withLock { $0 } == 3)

        let motion = Characteristic(.motionDetected)
        let motionCount = Mutex(0)
        _ = motion.addObserver { _, _ in motionCount.withLock { $0 += 1 } }
        motion.sendEvent(.bool(false))
        motion.sendEvent(.bool(false))
        #expect(motionCount.withLock { $0 } == 2)
    }

    @Test func overridesAffectValidation() throws {
        let characteristic = Characteristic(.programmableSwitchEvent)
        characteristic.validValuesOverride = [0]
        #expect(characteristic.validValuesOverride == [0])
        #expect(throws: HAPStatus.invalidValue) { try characteristic.validateIncoming(.int(1)) }
        #expect(try characteristic.validateIncoming(.int(0)) == .uint(0))

        let volume = Characteristic(.volume)
        volume.maxValueOverride = 50
        volume.minValueOverride = 10
        #expect(throws: HAPStatus.invalidValue) { try volume.validateIncoming(.int(60)) }
        #expect(throws: HAPStatus.invalidValue) { try volume.validateIncoming(.int(5)) }
        #expect(try volume.validateIncoming(.int(30)) == .uint(30))
    }

    @Test func incomingValueValidation() throws {
        let on = Characteristic(.on)
        #expect(try on.validateIncoming(.int(1)) == .bool(true))
        #expect(try on.validateIncoming(.int(0)) == .bool(false))
        #expect(try on.validateIncoming(.bool(true)) == .bool(true))
        #expect(throws: HAPStatus.invalidValue) { try on.validateIncoming(.int(2)) }
        #expect(throws: HAPStatus.invalidValue) { try on.validateIncoming(.string("1")) }

        let active = Characteristic(.active)
        #expect(try active.validateIncoming(.bool(true)) == .uint(1))
        #expect(throws: HAPStatus.invalidValue) { try active.validateIncoming(.double(0.5)) }
        #expect(throws: HAPStatus.invalidValue) { try active.validateIncoming(.int(-1)) }
        #expect(throws: HAPStatus.invalidValue) { try active.validateIncoming(.null) }

        let temperature = Characteristic(.currentTemperature)
        #expect(try temperature.validateIncoming(.double(21.5)) == .float(21.5))
        #expect(throws: HAPStatus.invalidValue) { try temperature.validateIncoming(.double(120)) }

        let setup = Characteristic(.setupEndpoints)
        #expect(try setup.validateIncoming(.string("AQID")) == .data(Data([1, 2, 3])))
        #expect(throws: HAPStatus.invalidValue) { try setup.validateIncoming(.string("not base64!")) }
        #expect(throws: HAPStatus.invalidValue) { try setup.validateIncoming(.int(1)) }

        let name = Characteristic(.configuredName)
        #expect(try name.validateIncoming(.string("Porch")) == .string("Porch"))
        #expect(throws: HAPStatus.invalidValue) { try name.validateIncoming(.string(String(repeating: "a", count: 65))) }
    }

    @Test func outgoingJSONValues() {
        #expect(Characteristic(.on).jsonValue(.bool(true)) == .int(1))
        #expect(Characteristic(.setupEndpoints).jsonValue(.data(Data([1, 2, 3]))) == .string("AQID"))
        #expect(Characteristic(.currentTemperature).jsonValue(.float(21.349)) == .double(21.3))
        #expect(Characteristic(.volume).jsonValue(.uint(7)) == .int(7))
        #expect(Characteristic(.programmableSwitchEvent).jsonValue(.null) == .null)
    }

    @Test func readAndWriteHandlers() async throws {
        let characteristic = Characteristic(.setupDataStreamTransport)
        let session = FakeSession()
        characteristic.onRead { _ async throws(HAPStatus) -> HAPValue in .data(Data([9])) }
        characteristic.onWrite { value, context async throws(HAPStatus) -> HAPValue? in
            #expect(context.session.id == session.id)
            return .data(value.dataValue.map { $0 + Data([0xFF]) } ?? Data())
        }
        #expect(try await characteristic.handleRead(context: HAPRequestContext(session: session)) == .data(Data([9])))
        let response = try await characteristic.handleWrite(.data(Data([1])), context: HAPRequestContext(session: session))
        #expect(response == .data(Data([1, 0xFF])))

        let failing = Characteristic(.on)
        failing.onWrite { _, _ async throws(HAPStatus) -> HAPValue? in throw .resourceBusy }
        await #expect(throws: HAPStatus.resourceBusy) {
            _ = try await failing.handleWrite(.bool(true), context: HAPRequestContext(session: session))
        }
        #expect(failing.value == .bool(false))
    }

    @Test func writeWithoutHandlerStoresValueAndNotifiesWithOrigin() async throws {
        let characteristic = Characteristic(.on)
        let session = FakeSession()
        let seen = Mutex<[UUID?]>([])
        _ = characteristic.addObserver { _, origin in seen.withLock { $0.append(origin) } }
        _ = try await characteristic.handleWrite(.bool(true), context: HAPRequestContext(session: session))
        #expect(characteristic.value == .bool(true))
        #expect(seen.withLock { $0 } == [session.id])
    }

    @Test func programmableSwitchEventReadsNull() async throws {
        let characteristic = Characteristic(.programmableSwitchEvent)
        characteristic.update(.uint(1))
        #expect(try await characteristic.handleRead(context: nil) == .null)
        let identify = Characteristic(.identify)
        await #expect(throws: HAPStatus.writeOnly) { _ = try await identify.handleRead(context: nil) }
    }
}

@Suite struct ServiceAndAccessoryModelTests {
    @Test func serviceCreatesRequiredCharacteristicsAndName() {
        let service = Service(.motionSensor, name: "Front", subtype: "front")
        #expect(service.characteristics.map(\.type) == [.motionDetected, .name])
        #expect(service.existingCharacteristic(.name)?.value == .string("Front"))
        #expect(service.subtype == "front")
        #expect(service.existingCharacteristic(.statusActive) == nil)
        let active = service.characteristic(.statusActive)
        #expect(service.characteristic(.statusActive) === active)
        #expect(service.characteristics.count == 3)
        #expect(Service(.switch).characteristics.map(\.type) == [.on])
    }

    @Test func linkedPrimaryHidden() {
        let a = Service(.cameraRecordingManagement)
        let b = Service(.motionSensor)
        a.addLinkedService(b)
        a.addLinkedService(b)
        #expect(a.linkedServices.count == 1 && a.linkedServices.first === b)
        a.isPrimary = true
        b.isHidden = true
        #expect(a.isPrimary && !a.isHidden && b.isHidden)
    }

    @Test func accessoryAddsInformationAndProtocolServices() {
        let accessory = Accessory(info: testInfo, category: .ipCamera)
        #expect(accessory.services.map(\.type) == [.accessoryInformation, .protocolInformation])
        let info = accessory.informationService
        #expect(info.type == .accessoryInformation)
        #expect(info.existingCharacteristic(.manufacturer)?.value == .string("Maker"))
        #expect(info.existingCharacteristic(.model)?.value == .string("M1"))
        #expect(info.existingCharacteristic(.name)?.value == .string("Cam"))
        #expect(info.existingCharacteristic(.serialNumber)?.value == .string("S1"))
        #expect(info.existingCharacteristic(.firmwareRevision)?.value == .string("2.0.1"))
        #expect(info.existingCharacteristic(.hardwareRevision)?.value == .string("B"))
        #expect(accessory.services[1].existingCharacteristic(.version)?.value == .string("1.1.0"))
        #expect(accessory.info == testInfo)
        #expect(accessory.category == .ipCamera)
        #expect(accessory.aid == 1)
    }

    @Test func addRemoveServices() {
        let accessory = Accessory(info: testInfo, category: .sensor)
        let motion = Service(.motionSensor)
        #expect(accessory.addService(motion) === motion)
        accessory.addService(motion)
        #expect(accessory.services.count == 3)
        accessory.removeService(motion)
        accessory.removeService(accessory.informationService)   // information service cannot be removed
        #expect(accessory.services.count == 2)
    }

    @Test func identifyWriteCallsHandler() async throws {
        let accessory = Accessory(info: testInfo, category: .sensor)
        let called = Mutex(0)
        accessory.onIdentify { called.withLock { $0 += 1 } }
        let identify = try #require(accessory.informationService.existingCharacteristic(.identify))
        _ = try await identify.handleWrite(.bool(true), context: HAPRequestContext(session: FakeSession()))
        #expect(called.withLock { $0 } == 1)
    }

    @Test func bridgedAccessories() {
        let bridge = Accessory(info: testInfo, category: .bridge)
        let child = Accessory(info: AccessoryInfo(name: "Child", manufacturer: "M", model: "X", serialNumber: "C1", firmwareRevision: "1"),
                              category: .sensor)
        bridge.addBridgedAccessory(child)
        bridge.addBridgedAccessory(child)
        #expect(bridge.bridgedAccessories.count == 1)
        child.setReachable(false)
        #expect(!child.isReachable)
        bridge.removeBridgedAccessory(child)
        #expect(bridge.bridgedAccessories.isEmpty)
    }
}

/// Plan W1-1 items 2, 4 and 12 at the model level (no network).
@Suite struct IdentifierAssignmentTests {
    private func makeCamera(order: [ServiceType] = [.motionSensor, .switch]) -> Accessory {
        let accessory = Accessory(info: testInfo, category: .ipCamera)
        for type in order { accessory.addService(Service(type, subtype: type == .switch ? "a" : nil)) }
        return accessory
    }

    @Test func informationServiceIsIID1AndOthersAreUnique() {
        let accessory = makeCamera()
        let publication = Publication(root: accessory, state: HAPPersistentState())
        publication.assignIDs()
        defer { publication.unbind() }
        #expect(accessory.informationService.iid == 1)
        let serviceIIDs = accessory.services.map(\.iid)
        let characteristicIIDs = accessory.services.flatMap(\.characteristics).map(\.iid)
        let all = serviceIIDs + characteristicIIDs
        #expect(Set(all).count == all.count)
        #expect(all.allSatisfy { $0 >= 1 })
        #expect(Array(serviceIIDs.dropFirst()).allSatisfy { $0 >= 2 })
        #expect(publication.characteristic(aid: 1, iid: characteristicIIDs[0])?.characteristic === accessory.services[0].characteristics[0])
    }

    @Test func iidsStableAcrossRestartAndReordering() {
        let first = makeCamera(order: [.motionSensor, .switch])
        let publication = Publication(root: first, state: HAPPersistentState())
        publication.assignIDs()
        let saved = publication.persistentIdentifiers(into: HAPPersistentState())
        publication.unbind()

        let second = makeCamera(order: [.switch, .motionSensor])
        let restored = Publication(root: second, state: saved)
        restored.assignIDs()
        defer { restored.unbind() }
        for type in [ServiceType.motionSensor, .switch, .protocolInformation] {
            let a = first.services.first { $0.type == type }
            let b = second.services.first { $0.type == type }
            #expect(a?.iid == b?.iid)
            #expect(a?.characteristics.map(\.iid) == b?.characteristics.map(\.iid))
        }
    }

    @Test func addingAfterPublishAssignsNewIIDsWithoutChangingOld() {
        let accessory = makeCamera()
        let publication = Publication(root: accessory, state: HAPPersistentState())
        publication.assignIDs()
        defer { publication.unbind() }
        let before = accessory.services.map { $0.characteristics.map(\.iid) }
        let contact = accessory.addService(Service(.contactSensor))
        let tampered = accessory.services[2].characteristic(.statusTampered)
        #expect(contact.iid > 0 && tampered.iid > 0)
        #expect(accessory.services[0].characteristics.map(\.iid) == before[0])
        #expect(Array(accessory.services[2].characteristics.dropLast().map(\.iid)) == before[2])
        let old = Set(before.flatMap { $0 })
        #expect(!old.contains(tampered.iid) && !old.contains(contact.iid))
        #expect(contact.characteristics.allSatisfy { $0.iid > 0 && !old.contains($0.iid) })
    }

    @Test func bridgedAIDsStableByKey() {
        func build(_ serials: [String]) -> (Accessory, [String: Accessory]) {
            let bridge = Accessory(info: testInfo, category: .bridge)
            var children: [String: Accessory] = [:]
            for serial in serials {
                let child = Accessory(info: AccessoryInfo(name: serial, manufacturer: "M", model: "X", serialNumber: serial, firmwareRevision: "1"),
                                      category: .sensor)
                child.addService(Service(.occupancySensor))
                bridge.addBridgedAccessory(child)
                children[serial] = child
            }
            return (bridge, children)
        }
        let (bridge, children) = build(["a", "b", "c"])
        let publication = Publication(root: bridge, state: HAPPersistentState())
        publication.assignIDs()
        #expect(bridge.aid == 1)
        #expect(children.values.map(\.aid).sorted() == [2, 3, 4])
        #expect(children.values.allSatisfy { $0.informationService.iid == 1 })
        let saved = publication.persistentIdentifiers(into: HAPPersistentState())
        publication.unbind()

        let (bridge2, children2) = build(["c", "b"])
        let restored = Publication(root: bridge2, state: saved)
        restored.assignIDs()
        defer { restored.unbind() }
        #expect(children2["b"]?.aid == children["b"]?.aid)
        #expect(children2["c"]?.aid == children["c"]?.aid)
        let late = Accessory(info: AccessoryInfo(name: "d", manufacturer: "M", model: "X", serialNumber: "d", firmwareRevision: "1"), category: .sensor)
        bridge2.addBridgedAccessory(late)
        #expect(late.aid == 5)
        #expect(restored.accessory(aid: 5) === late)
    }

    @Test func configHashIgnoresValuesButNotStructure() {
        let accessory = makeCamera()
        let publication = Publication(root: accessory, state: HAPPersistentState())
        publication.assignIDs()
        defer { publication.unbind() }
        let hash = publication.configurationHash()
        #expect(hash.count == 64)
        accessory.services[2].characteristic(.motionDetected).update(.bool(true))
        #expect(publication.configurationHash() == hash)
        accessory.services[2].characteristic(.statusActive)
        #expect(publication.configurationHash() != hash)
    }

    @Test func configNumberBumpsAndWraps() {
        var state = HAPPersistentState()
        #expect(ConfigurationNumber.apply(hash: "a", to: &state) == false)   // first hash: recorded, c# stays 1
        #expect(state.configNumber == 1 && state.configHash == "a")
        #expect(ConfigurationNumber.apply(hash: "a", to: &state) == false)
        #expect(ConfigurationNumber.apply(hash: "b", to: &state) == true)
        #expect(state.configNumber == 2)
        state.configNumber = 65535
        #expect(ConfigurationNumber.apply(hash: "c", to: &state) == true)
        #expect(state.configNumber == 1)
    }
}

final class FakeSession: HAPSessionHandle {
    let id = UUID()
    let controllerID = "controller"
    let isAdmin = true
    let sharedSecret = Data(repeating: 7, count: 32)
    let localAddress = "127.0.0.1"
    let remoteAddress = "127.0.0.1"
    let isIPv6 = false
    func onClose(_ handler: @escaping @Sendable () -> Void) {}
}
