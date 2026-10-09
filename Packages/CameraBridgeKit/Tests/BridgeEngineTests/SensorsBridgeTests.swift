import BridgeSupport
import CameraAdapters
import Foundation
import HAPCore
import TestSupport
import Testing
@testable import BridgeEngine
@testable import HAP

private let drivewayID = UUID(uuidString: "0B8A2E4C-1111-4000-8000-000000000001") ?? UUID()
private let doorID = UUID(uuidString: "0B8A2E4C-2222-4000-8000-000000000002") ?? UUID()

private func driveway() -> CameraConfiguration {
    var camera = CameraConfiguration(id: drivewayID, name: "Driveway", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.1"),
                                     username: "admin")
    camera.capabilities = CameraCapabilities(events: [.motion, .person, .vehicle, .dayNight, .temperature, .humidity, .digitalInput, .tamper])
    camera.sensors.person = true
    camera.sensors.vehicle = true
    camera.sensors.package = true          // not offered by the camera: no sensor
    camera.sensors.dayNight = true
    camera.sensors.temperature = true
    camera.sensors.humidity = true
    return camera
}

private func door() -> CameraConfiguration {
    var camera = CameraConfiguration(id: doorID, name: "Front Door", kind: .doorbell, vendor: .reolink, endpoint: CameraEndpoint(host: "192.0.2.2"),
                                     username: "admin")
    camera.capabilities = CameraCapabilities(events: [.motion, .person, .package, .doorbell, .digitalInput])
    camera.sensors.package = true
    camera.sensors.digitalInputs = true
    return camera
}

private func makeBridge(store: any HAPStore = InMemoryHAPStore(), transport: FakeTransport = FakeTransport()) -> SensorsBridge {
    SensorsBridge(configuration: AccessoryServerConfiguration(port: 21_099, advertise: false, serviceName: SensorsBridge.name, loopbackOnly: true),
                  store: store, transport: transport, advertiser: NullServiceAdvertiser())
}

/// HAP-NodeJS `checkName` (Reference dist-2.1.6/lib/util/checkName.js): what Home accepts as a name.
private func isValidHomeName(_ name: String) -> Bool {
    guard name.count <= 64,
          let regex = try? NSRegularExpression(pattern: #"^[\p{L}\p{N}][\p{L}\p{N}\x{2019} '.,-]*[\p{L}\p{N}\x{2019}]$"#) else { return false }
    return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
}

private extension SensorsBridge {
    nonisolated func accessory(_ key: String) -> Accessory? {
        accessory.bridgedAccessories.first { $0.stableKey == key }
    }

    nonisolated func value(_ key: String, _ type: CharacteristicType) -> HAPValue? {
        accessory(key)?.services.last?.existingCharacteristic(type)?.value
    }
}

@Suite(.timeLimit(.minutes(1))) struct SensorsBridgeStructureTests {
    /// A camera whose motion comes from the webhook (an RTSP camera with Frigate or Home Assistant) gets its person,
    /// vehicle, animal and package events from there too: those sensors are offered although the camera itself reports
    /// no detections. Other sensors still need the camera.
    @Test func webhookCamerasOfferDetectionSensors() async throws {
        var camera = CameraConfiguration(name: "Side Yard", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.24"), username: "")
        camera.capabilities = CameraCapabilities()
        camera.sensors.person = true
        camera.sensors.vehicle = true
        camera.sensors.dayNight = true
        #expect(BridgedSensor.sensors(for: camera, knownInputs: []).isEmpty, "camera events: nothing the camera doesn't report")
        camera.motionSource = .webhook
        #expect(BridgedSensor.sensors(for: camera, knownInputs: []) == [.occupancy(.person), .occupancy(.vehicle)])
        camera.sensors.animal = true
        camera.sensors.package = true
        #expect(BridgedSensor.sensors(for: camera, knownInputs: []) == ([.person, .vehicle, .animal, .package] as [DetectedObjectKind]).map { .occupancy($0) })

        let bridge = makeBridge()
        await bridge.update(cameras: [camera])
        #expect(bridge.accessory("camera.\(camera.id.uuidString).person") != nil)
    }

    @Test func sensorsFollowTheOptionsTheCameraCanProvide() async throws {
        let bridge = makeBridge()
        await bridge.update(cameras: [driveway(), door()])
        #expect(bridge.accessory.category == .bridge && bridge.accessory.info.name == "Camera Bridge Sensors")
        let keys = Set(bridge.accessory.bridgedAccessories.map(\.stableKey))
        let camera = "camera.\(drivewayID.uuidString)"
        #expect(keys == ["\(camera).person", "\(camera).vehicle", "\(camera).dayNight", "\(camera).temperature", "\(camera).humidity",
                         "camera.\(doorID.uuidString).package"])
        #expect(await bridge.sensors(for: drivewayID) == [.occupancy(.person), .occupancy(.vehicle), .light, .temperature, .humidity])
        #expect(await bridge.sensors(for: doorID) == [.occupancy(.package)], "alarm inputs appear once the camera reports one")

        let person = try #require(bridge.accessory("\(camera).person"))
        #expect(person.category == .sensor && person.info.name == "Driveway Person" && person.info.manufacturer == "CameraBridge")
        let service = try #require(person.services.last)
        #expect(service.type == .occupancySensor)
        #expect(service.existingCharacteristic(.name)?.value == .string("Driveway Person"))
        for type in [CharacteristicType.statusActive, .statusFault, .statusTampered] {
            #expect(service.existingCharacteristic(type) != nil, "missing \(type.name)")
        }
        #expect(bridge.accessory("\(camera).dayNight")?.services.last?.type == .lightSensor)
        #expect(bridge.value("\(camera).dayNight", .currentAmbientLightLevel) == .float(1000), "day until the camera says otherwise")
        #expect(bridge.accessory("\(camera).temperature")?.services.last?.type == .temperatureSensor)
        #expect(bridge.accessory("\(camera).humidity")?.services.last?.type == .humiditySensor)
        #expect(bridge.accessory("\(camera).dayNight")?.info.name == "Driveway Daylight")
    }

    @Test func unknownCapabilitiesTrustTheOptions() async {
        var camera = driveway()
        camera.capabilities = nil
        let bridge = makeBridge()
        await bridge.update(cameras: [camera])
        #expect(await bridge.sensors(for: drivewayID).contains(.occupancy(.package)))
    }

    @Test func aidsAreStableAcrossRestartsOrderAndOptionChanges() async throws {
        let store = InMemoryHAPStore()
        let first = makeBridge(store: store)
        await first.update(cameras: [driveway(), door()])
        try await first.start()
        let aids = Dictionary(uniqueKeysWithValues: first.accessory.bridgedAccessories.map { ($0.stableKey, $0.aid) })
        #expect(Set(aids.values).count == 6 && aids.values.allSatisfy { $0 >= 2 })

        // Turning a sensor off and on again gives it its old aid back.
        var camera = driveway()
        camera.sensors.vehicle = false
        await first.update(cameras: [camera, door()])
        #expect(first.accessory("camera.\(drivewayID.uuidString).vehicle") == nil)
        camera.sensors.vehicle = true
        await first.update(cameras: [camera, door()])
        #expect(first.accessory("camera.\(drivewayID.uuidString).vehicle")?.aid == aids["camera.\(drivewayID.uuidString).vehicle"])
        await first.stop()

        let second = makeBridge(store: store)
        await second.update(cameras: [door(), driveway()])
        try await second.start()
        for accessory in second.accessory.bridgedAccessories {
            #expect(accessory.aid == aids[accessory.stableKey], "\(accessory.stableKey)")
        }
        await second.stop()
    }

    @Test func structureChangesBumpTheConfigurationNumber() async throws {
        let store = InMemoryHAPStore()
        let bridge = makeBridge(store: store)
        await bridge.update(cameras: [driveway()])
        try await bridge.start()
        let before = try #require(try store.loadState()).configNumber
        await bridge.update(cameras: [driveway(), door()])
        let after = try #require(try store.loadState()).configNumber
        #expect(after == before &+ 1)
        await bridge.update(cameras: [driveway(), door()])   // nothing changed
        #expect(try store.loadState()?.configNumber == after)
        await bridge.stop()
    }

    /// The `/accessories` database the bridge publishes: the bridge (aid 1) has AccessoryInformation and
    /// ProtocolInformation; each bridged sensor has AccessoryInformation and its sensor service only (HAP-NodeJS adds
    /// ProtocolInformation to the published accessory only).
    @Test func accessoriesDatabaseShape() async throws {
        let bridge = makeBridge()
        await bridge.update(cameras: [driveway(), door()])
        try await bridge.start()
        let accessories = [bridge.accessory] + bridge.accessory.bridgedAccessories
        let database = accessories.map { HAPJSONEncoding.accessory($0, includeValues: true) }
        let types = database.map { ($0["services"]?.arrayValue ?? []).compactMap { $0["type"]?.stringValue } }
        #expect(types.first == ["3E", "A2"])
        #expect(types.count == 7)
        let sensorTypes: Set<String> = ["86", "84", "8A", "82"]   // occupancy, light, temperature, humidity
        for (accessory, services) in zip(accessories.dropFirst(), types.dropFirst()) {
            #expect(services.count == 2 && services[0] == "3E" && sensorTypes.contains(services[1]), "\(accessory.stableKey): \(services)")
        }
        #expect(database.dropFirst().allSatisfy { ($0["aid"]?.intValue ?? 0) >= 2 })
        await bridge.stop()
    }

    @Test func removedCamerasLoseTheirSensorsAndRenamesReachHome() async throws {
        let bridge = makeBridge()
        await bridge.update(cameras: [driveway(), door()])
        var renamed = driveway()
        renamed.name = "Drive-way 2"
        await bridge.update(cameras: [renamed])
        #expect(bridge.accessory.bridgedAccessories.allSatisfy { $0.stableKey.hasPrefix("camera.\(drivewayID.uuidString).") })
        #expect(await bridge.sensors(for: doorID).isEmpty)
        let person = try #require(bridge.accessory("camera.\(drivewayID.uuidString).person"))
        #expect(person.informationService.existingCharacteristic(.name)?.value == .string("Drive-way 2 Person"))
        #expect(person.services.last?.existingCharacteristic(.name)?.value == .string("Drive-way 2 Person"))
    }

    @Test func namesAreValidForHome() {
        #expect(SensorsBridge.homeName("Front Door", "Person") == "Front Door Person")
        #expect(SensorsBridge.homeName("  Garage / Side #2 ", "Daylight") == "Garage Side 2 Daylight")
        #expect(SensorsBridge.homeName("🙂", "Person") == "Camera Person")
        #expect(SensorsBridge.homeName(String(repeating: "a", count: 100), "Humidity").count <= 64)
        #expect(SensorsBridge.homeName("Front Door", "Alarm Input AlarmIn_1") == "Front Door Alarm Input AlarmIn 1")
        #expect(SensorsBridge.homeName("Front Door", "Alarm Input IO/2 (Gate)") == "Front Door Alarm Input IO 2 Gate")
        #expect(SensorsBridge.homeName("Front Door", "Alarm Input x.") == "Front Door Alarm Input x")
        #expect(SensorsBridge.homeName("Cafe\u{301} Porch", "Person") == "Café Porch Person", "decomposed accents stay letters")
        #expect(SensorsBridge.homeName("Kid’s Room", "Person") == "Kid’s Room Person")
        #expect(SensorsBridge.homeName("Door", "🙂") == "Door Sensor")
        let names = ["Front Door", "  Garage / Side #2 ", "🙂", String(repeating: "a", count: 100), "-Porch-", "Cafe\u{301}", "a\u{200B}b",
                     "Tab\there", "x.", "'", "Kid’s Room", "日本語カメラ", "1"]
        let labels = ["Person", "Alarm Input AlarmIn_1", "Alarm Input IO/2 (Gate)", "Alarm Input x.", "Alarm Input _",
                      "Alarm Input " + String(repeating: "z", count: 32), "🙂", "Daylight"]
        for name in names {
            for label in labels {
                let homeName = SensorsBridge.homeName(name, label)
                #expect(isValidHomeName(homeName), "\(homeName.debugDescription)")
            }
        }
    }

    @Test func alarmInputLabelsAreCleanedAndDistinct() {
        let inputs = ["/", "2", "AlarmIn_1", "IO/2 (Gate)", "_", "a_b", "a/b", "x."]
        let labels = SensorsBridge.labels(for: [.light] + inputs.map { .contact(input: $0) })
        #expect(labels[.light] == "Daylight")
        #expect(labels[.contact(input: "2")] == "Alarm Input 2")
        #expect(labels[.contact(input: "AlarmIn_1")] == "Alarm Input AlarmIn 1")
        #expect(labels[.contact(input: "IO/2 (Gate)")] == "Alarm Input IO 2 Gate")
        #expect(labels[.contact(input: "x.")] == "Alarm Input x")
        #expect(labels[.contact(input: "/")] == "Alarm Input 1", "nothing left of the id: its position")
        #expect(labels[.contact(input: "_")] == "Alarm Input 5")
        #expect(labels[.contact(input: "a_b")] == "Alarm Input 6" && labels[.contact(input: "a/b")] == "Alarm Input 7",
                "two ids that clean to the same text are told apart by position")
        #expect(Set(labels.values).count == labels.count)
        let clash = SensorsBridge.labels(for: [.contact(input: "2"), .contact(input: "?")])
        #expect(clash[.contact(input: "?")] == "Alarm Input 3", "a position already taken by another input's label is skipped")
    }

    @Test func statusReportsPairingCodeAndCount() async throws {
        let store = InMemoryHAPStore()
        let bridge = makeBridge(store: store)
        await bridge.update(cameras: [driveway()])
        let status = try await bridge.status()
        let identity = try #require(try store.loadIdentity())
        #expect(!status.isPaired && status.accessoryCount == 5)
        #expect(status.setupCode == identity.setupCode.formatted)
        #expect(status.setupURI == SetupPayload.uri(code: identity.setupCode, setupID: identity.setupID, category: .bridge))
    }

    /// Review finding (W4 round 4): the app worked the published sensors out from the options and listed Alarm Inputs
    /// for a camera that had reported no input yet, which publishes no contact sensor (the header's count left it out).
    /// The status names the sensors the bridge publishes.
    @Test func statusNamesThePublishedSensors() async throws {
        let bridge = makeBridge()
        var camera = driveway()
        camera.sensors.digitalInputs = true
        await bridge.update(cameras: [camera])
        var status = try await bridge.status()
        let withoutInputs: [BridgedSensor] = [.occupancy(.person), .occupancy(.vehicle), .light, .temperature, .humidity]
        #expect(status.publishedSensors == [drivewayID: withoutInputs], "no contact sensor before the camera reports an input")
        #expect(status.accessoryCount == withoutInputs.count)
        await bridge.apply(SensorState(id: drivewayID, digitalInputs: ["1": false]))
        status = try await bridge.status()
        #expect(status.publishedSensors[drivewayID] == [.occupancy(.person), .occupancy(.vehicle), .light, .contact(input: "1"), .temperature, .humidity])
        await bridge.update(cameras: [])
        #expect(try await bridge.status().publishedSensors.isEmpty)
    }

    @Test func environmentInitUsesTheSensorsBridgeStorage() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let environment = BridgeEnvironment.inert(directory: directory.url)
        let bridge = SensorsBridge(environment: environment, port: 21_099)
        _ = try await bridge.status()
        #expect(try environment.platform.secrets.read(account: HAPStorage.sensorsBridgeAccount) != nil)
        await #expect(throws: TransportError.self) { try await bridge.start() }   // the inert transport never listens
    }
}

@Suite(.timeLimit(.minutes(1))) struct SensorsBridgeStateTests {
    @Test func stateIsMirroredIntoCharacteristics() async {
        let bridge = makeBridge()
        await bridge.update(cameras: [driveway()])
        let camera = "camera.\(drivewayID.uuidString)"
        await bridge.apply(SensorState(id: drivewayID, objects: [.person, .face], tampered: true, isNight: true, temperature: 21.5, humidity: 40,
                                       eventChannelConnected: true, streamConnection: .online))
        #expect(bridge.value("\(camera).person", .occupancyDetected) == .uint(1))
        #expect(bridge.value("\(camera).vehicle", .occupancyDetected) == .uint(0))
        #expect(bridge.value("\(camera).dayNight", .currentAmbientLightLevel) == .float(1))
        #expect(bridge.value("\(camera).temperature", .currentTemperature) == .float(21.5))
        #expect(bridge.value("\(camera).humidity", .currentRelativeHumidity) == .float(40))
        for key in ["person", "vehicle", "dayNight", "temperature", "humidity"] {
            #expect(bridge.value("\(camera).\(key)", .statusTampered) == .uint(1))
            #expect(bridge.value("\(camera).\(key)", .statusFault) == .uint(0))
            #expect(bridge.value("\(camera).\(key)", .statusActive) == .bool(true))
            #expect(bridge.accessory("\(camera).\(key)")?.isReachable == true)
        }
        await bridge.apply(SensorState(id: drivewayID, isNight: false, temperature: 500, eventChannelConnected: false, streamConnection: .online))
        #expect(bridge.value("\(camera).person", .occupancyDetected) == .uint(0))
        #expect(bridge.value("\(camera).dayNight", .currentAmbientLightLevel) == .float(1000))
        #expect(bridge.value("\(camera).temperature", .currentTemperature) == .float(100), "clamped to the characteristic's range")
        #expect(bridge.value("\(camera).person", .statusFault) == .uint(1))
        #expect(bridge.value("\(camera).person", .statusActive) == .bool(false))
        #expect(bridge.value("\(camera).person", .statusTampered) == .uint(0))
    }

    @Test func offlineAndDisabledCamerasAreUnreachable() async {
        let bridge = makeBridge()
        await bridge.update(cameras: [driveway()])
        let person = "camera.\(drivewayID.uuidString).person"
        await bridge.apply(SensorState(id: drivewayID, streamConnection: .offline("Connection timed out")))
        #expect(bridge.accessory(person)?.isReachable == false)
        #expect(bridge.value(person, .statusFault) == .uint(1))
        await bridge.apply(SensorState(id: drivewayID, streamConnection: .online))
        #expect(bridge.accessory(person)?.isReachable == true)
        await bridge.apply(SensorState(id: drivewayID, streamConnection: .online, credentialsRejected: true))
        #expect(bridge.accessory(person)?.isReachable == false)
        await bridge.apply(SensorState(id: drivewayID, isEnabled: false))
        #expect(bridge.accessory(person)?.isReachable == false)
        #expect(bridge.value(person, .statusActive) == .bool(false))
    }

    @Test func alarmInputsAppearWhenReportedAndArePersisted() async throws {
        let store = InMemoryHAPStore()
        let bridge = makeBridge(store: store)
        await bridge.update(cameras: [door(), driveway()])
        try await bridge.start()
        let before = try #require(try store.loadState()).configNumber
        let key = "camera.\(doorID.uuidString).input.1"
        await bridge.apply(SensorState(id: doorID, digitalInputs: ["1": true]))
        let contact = try #require(bridge.accessory(key))
        #expect(contact.services.last?.type == .contactSensor && contact.info.name == "Front Door Alarm Input 1")
        #expect(bridge.value(key, .contactSensorState) == .uint(1), "an active input reads as open (contact not detected)")
        #expect(try store.loadState()?.configNumber == before &+ 1)
        await bridge.apply(SensorState(id: doorID, digitalInputs: ["1": false]))
        #expect(bridge.value(key, .contactSensorState) == .uint(0))
        // Inputs of a camera whose alarm-input option is off are remembered but not published.
        await bridge.apply(SensorState(id: drivewayID, digitalInputs: ["3": true]))
        #expect(bridge.accessory("camera.\(drivewayID.uuidString).input.3") == nil)
        let aid = contact.aid
        await bridge.stop()

        let restarted = makeBridge(store: store)
        var inputsOn = driveway()
        inputsOn.sensors.digitalInputs = true
        await restarted.update(cameras: [door(), inputsOn])
        #expect(restarted.accessory(key) != nil, "known inputs are published before the camera reports them again")
        #expect(restarted.accessory("camera.\(drivewayID.uuidString).input.3") != nil)
        try await restarted.start()
        #expect(restarted.accessory(key)?.aid == aid)
        await restarted.stop()
    }

    @Test func hostileInputIDsAreBounded() async {
        final class Sink: LogSink {
            let messages = Box<[String]>([])
            func record(_ entry: LogEntry) { if entry.category == "Sensors" { messages.update { $0.append(entry.message) } } }
        }
        let sink = Sink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let bridge = makeBridge()
        var camera = door()
        camera.name = "Hostile Door"
        await bridge.update(cameras: [camera])
        var inputs: [String: Bool] = [:]
        for index in 0..<40 { inputs["in\(index)"] = true }
        inputs[String(repeating: "x", count: 200)] = true
        await bridge.apply(SensorState(id: doorID, digitalInputs: inputs))
        await bridge.apply(SensorState(id: doorID, digitalInputs: inputs))
        let contacts = await bridge.sensors(for: doorID).filter { if case .contact = $0 { true } else { false } }
        #expect(contacts.count == SensorsBridge.maximumInputsPerCamera)
        #expect(bridge.accessory.bridgedAccessories.allSatisfy { $0.stableKey.count <= 7 + 36 + 1 + 6 + SensorsBridge.maximumInputIDLength })
        #expect(sink.messages.value.filter { $0.hasPrefix("Hostile Door reported 25 alarm input(s)") }.count == 1, "warned once")
        var more: [String: Bool] = [:]
        for index in 0..<200 { more["more\(index)"] = true }
        await bridge.apply(SensorState(id: doorID, digitalInputs: more))
        await bridge.apply(SensorState(id: doorID, digitalInputs: more))
        #expect(sink.messages.value.filter { $0.hasPrefix("Hostile Door reported") }.count == 1, "once per camera")
        #expect(await bridge.sensors(for: doorID).count == 1 + SensorsBridge.maximumInputsPerCamera)
    }

    @Test func contactSensorNamesAreHomeSafeButKeysKeepTheRawID() async throws {
        let bridge = makeBridge()
        await bridge.update(cameras: [door()])
        await bridge.apply(SensorState(id: doorID, digitalInputs: ["AlarmIn_1": true, "IO/2 (Gate)": false, "x.": false, "_": false]))
        let prefix = "camera.\(doorID.uuidString).input."
        let expected = ["AlarmIn_1": "Front Door Alarm Input AlarmIn 1", "IO/2 (Gate)": "Front Door Alarm Input IO 2 Gate",
                        "x.": "Front Door Alarm Input x", "_": "Front Door Alarm Input 3"]
        for (input, name) in expected {
            let accessory = try #require(bridge.accessory(prefix + input), "\(input)")
            #expect(accessory.info.name == name)
            #expect(accessory.informationService.existingCharacteristic(.name)?.value == .string(name))
            #expect(accessory.services.last?.existingCharacteristic(.name)?.value == .string(name))
            #expect(isValidHomeName(name))
        }
        for accessory in bridge.accessory.bridgedAccessories {
            if case .string(let name)? = accessory.informationService.existingCharacteristic(.name)?.value {
                #expect(isValidHomeName(name), "\(name)")
            }
        }
    }

    @Test func inputsRememberedForCamerasThatAreGoneAreForgotten() async throws {
        let store = InMemoryHAPStore()
        let first = makeBridge(store: store)
        await first.update(cameras: [door(), driveway()])
        await first.apply(SensorState(id: doorID, digitalInputs: ["1": true]))
        #expect(first.accessory("camera.\(doorID.uuidString).input.1") != nil)

        // The door is removed while the app is not running: the next run never registers it.
        let second = makeBridge(store: store)
        await second.update(cameras: [driveway()])
        let stored = try #require(try store.loadState()?.extras[SensorsBridge.inputsExtraKey])
        let decoded = try JSONDecoder().decode([String: [String]].self, from: stored)
        #expect(decoded[doorID.uuidString] == nil)

        let third = makeBridge(store: store)
        await third.update(cameras: [door()])
        #expect(third.accessory("camera.\(doorID.uuidString).input.1") == nil, "a camera added back starts without old inputs")
    }

    @Test func alarmInputsAreOrderedNumerically() async {
        let bridge = makeBridge()
        await bridge.update(cameras: [door()])
        await bridge.apply(SensorState(id: doorID, digitalInputs: ["10": false, "A": false, "2": true]))
        #expect(await bridge.sensors(for: doorID) == [.occupancy(.package), .contact(input: "2"), .contact(input: "10"), .contact(input: "A")])
    }

    @Test func statesForUnknownCamerasAreIgnored() async {
        let bridge = makeBridge()
        await bridge.update(cameras: [driveway()])
        await bridge.apply(SensorState(id: UUID(), digitalInputs: ["1": true]))
        #expect(bridge.accessory.bridgedAccessories.count == 5)
    }

    @Test func followsTheEventRouter() async {
        let bridge = makeBridge()
        let camera = driveway()
        await bridge.update(cameras: [camera])
        let router = EventRouter(clock: TestClock())
        let task = bridge.follow(router.outputs)
        await router.register(camera)
        await router.handle(.object(.vehicle, true), for: drivewayID, origin: .camera)
        let key = "camera.\(drivewayID.uuidString).vehicle"
        #expect(await eventually { bridge.value(key, .occupancyDetected) == .uint(1) })
        await router.handle(.eventChannel(connected: false), for: drivewayID, origin: .camera)
        #expect(await eventually { bridge.value(key, .statusFault) == .uint(1) })
        task.cancel()
    }

    /// Review finding (W4): the engine read the router's states before subscribing to its outputs, so a change in between
    /// (an alarm input, an expiring occupancy hold) never reached the bridge until that camera's next change.
    @Test func followingARouterMissesNoChangeWhileCatchingUp() async throws {
        var stale = 0
        for _ in 0..<40 {
            let bridge = makeBridge()
            await bridge.update(cameras: [door()])
            try await bridge.start()
            let router = EventRouter()
            await router.register(door())
            let producer = Task.detached { await router.handle(.digitalInput(id: "1", active: true), for: doorID, origin: .camera) }
            let task = await bridge.follow(router: router)
            await producer.value
            let key = "camera.\(doorID.uuidString).input.1"
            if !(await eventually(timeout: .milliseconds(500)) { bridge.value(key, .contactSensorState) == .uint(1) }) { stale += 1 }
            task.cancel()
            await bridge.stop()
        }
        #expect(stale == 0, "\(stale) of 40 bridges missed the change")
    }
}
