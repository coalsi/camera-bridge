import BridgeEngine
import CameraAdapters
import Foundation
import Testing

/// The sidebar's Sensors section: the published sensors grouped under the camera that provides them, their live state, which
/// lists start open, and the sidebar's arrow-key navigation.
@MainActor @Suite(.timeLimit(.minutes(1))) struct SensorsSidebarTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func camera(_ name: String, id: UUID = UUID()) -> CameraConfiguration {
        CameraConfiguration(id: id, name: name, kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "192.0.2.1"), username: "")
    }

    private func status(_ id: UUID, events: [(String, TimeInterval)]) -> CameraStatus {
        CameraStatus(id: id, name: "x", kind: .camera, vendor: .demo, connection: .online,
                     recentEvents: events.map { CameraEventRecord(name: $0.0, date: Self.now.addingTimeInterval(-$0.1)) })
    }

    @Test func sensorsAreGroupedUnderTheirCameraInConfigurationOrder() {
        let driveway = camera("Driveway"), door = camera("Front Door"), garage = camera("Garage")
        let published: [UUID: [BridgedSensor]] = [door.id: [.occupancy(.person), .occupancy(.package)],
                                                  driveway.id: [.occupancy(.person), .occupancy(.vehicle), .light]]
        let groups = SensorsSidebar.groups(configurations: [driveway, door, garage], published: published, statuses: [], now: Self.now)
        #expect(groups.map(\.name) == ["Driveway", "Front Door"], "cameras without sensors have no group; configuration order")
        #expect(groups[0].sensors.map(\.title) == ["Person", "Vehicle", "Day and Night"])
        #expect(groups[1].sensors.map(\.title) == ["Person", "Package"])
        #expect(groups[0].sensors.map(\.symbol) == ["figure.stand", "car", "sun.max"])
        #expect(Set(groups.flatMap { $0.sensors.map(\.id) }).count == 5, "every sensor has its own identity")
    }

    @Test func nothingIsListedBeforeTheBridgeRanOrWithoutSensors() {
        let driveway = camera("Driveway")
        #expect(SensorsSidebar.groups(configurations: [driveway], published: nil, statuses: [], now: Self.now).isEmpty)
        #expect(SensorsSidebar.groups(configurations: [driveway], published: [:], statuses: [], now: Self.now).isEmpty)
        #expect(SensorsSidebar.groups(configurations: [driveway], published: [driveway.id: []], statuses: [], now: Self.now).isEmpty)
    }

    @Test func aDetectionIsHeldAMinuteThenReadsAsTheLastOne() {
        let driveway = camera("Driveway")
        let events = status(driveway.id, events: [("Vehicle", 7_200), ("Person", 120), ("Motion", 30), ("Person", 20)])
        let group = SensorsSidebar.groups(configurations: [driveway], published: [driveway.id: [.occupancy(.person), .occupancy(.vehicle), .occupancy(.animal)]],
                                          statuses: [events], now: Self.now)[0]
        let person = group.sensors[0], vehicle = group.sensors[1], animal = group.sensors[2]
        #expect(person.isActive && person.stateText(now: Self.now) == "Detected now", "the newest Person event is 20 s old")
        #expect(!vehicle.isActive && vehicle.state == .clear(last: Self.now.addingTimeInterval(-7_200)))
        #expect(vehicle.stateText(now: Self.now).hasPrefix("Detected "), "the last detection, as time ago")
        #expect(animal.state == .clear(last: nil) && animal.stateText(now: Self.now) == "Clear")
        // 61 s later the person detection has been released.
        let later = SensorsSidebar.row(for: .occupancy(.person), camera: driveway.id, status: events, now: Self.now.addingTimeInterval(41))
        #expect(!later.isActive)
    }

    @Test func alarmInputsAndReadingsHaveTheirOwnRows() {
        let id = UUID()
        let events = status(id, events: [("Alarm input 2", 10)])
        let input = SensorsSidebar.row(for: .contact(input: "2"), camera: id, status: events, now: Self.now)
        #expect(input.title == "Alarm Input 2" && input.symbol == "switch.2" && input.isActive)
        let other = SensorsSidebar.row(for: .contact(input: "3"), camera: id, status: events, now: Self.now)
        #expect(other.state == .clear(last: nil))
        for sensor in [BridgedSensor.light, .temperature, .humidity] {
            let row = SensorsSidebar.row(for: sensor, camera: id, status: events, now: Self.now)
            #expect(row.state == .published && row.stateText(now: Self.now) == "Published to Home")
        }
        let face = SensorsSidebar.row(for: .occupancy(.face), camera: id, status: nil, now: Self.now)
        #expect(face.title == "Face" && !face.symbol.isEmpty)
    }

    @Test func longListsStartCollapsedAndTheChoiceIsRemembered() {
        let id = UUID()
        func group(_ count: Int) -> SidebarSensorGroup {
            SidebarSensorGroup(id: id, name: "Cam", kind: .camera, sensors: (0..<count).map {
                SidebarSensor(id: "\($0)", sensor: .temperature, title: "t", symbol: "thermometer.medium", state: .published)
            })
        }
        #expect(SensorsSidebar.isExpanded(group(4), overrides: [:]) && !SensorsSidebar.isExpanded(group(5), overrides: [:]))
        #expect(!SensorsSidebar.isExpanded(group(2), overrides: [id: false]) && SensorsSidebar.isExpanded(group(9), overrides: [id: true]))
        let scratch = ScratchDefaults()
        let model = AppModel(options: LaunchOptions(usesPreviewEngine: true), engine: BridgeEngine.preview(), loginItems: InMemoryLoginItemService(),
                             defaults: scratch.defaults, previewLatency: .zero)
        let first = model.sensorGroups()[0]
        #expect(model.isSensorGroupExpanded(first), "three sensors: open")
        model.setSensorGroup(first, expanded: false)
        #expect(!model.isSensorGroupExpanded(first))
        let reopened = AppModel(options: LaunchOptions(usesPreviewEngine: true), engine: BridgeEngine.preview(), loginItems: InMemoryLoginItemService(),
                                defaults: scratch.defaults, previewLatency: .zero)
        #expect(!reopened.isSensorGroupExpanded(reopened.sensorGroups()[0]), "remembered across launches")
    }

    @Test func theModelOpensTheSensorsPageOnACameraOrOnAll() {
        let scratch = ScratchDefaults()
        let model = AppModel(options: LaunchOptions(usesPreviewEngine: true), engine: BridgeEngine.preview(), loginItems: InMemoryLoginItemService(),
                             defaults: scratch.defaults, previewLatency: .zero)
        let groups = model.sensorGroups()
        #expect(groups.map(\.name) == ["Driveway", "Front Door"], "the sample bridge publishes sensors for two cameras")
        #expect(groups[0].sensors.map(\.title) == ["Person", "Vehicle", "Day and Night"])
        model.showSensors(for: groups[1].id)
        #expect(model.selection == .sensorsBridge && model.sensorsFocus == groups[1].id)
        model.showSensors(for: nil)
        #expect(model.selection == .sensorsBridge && model.sensorsFocus == nil)
    }

    @Test func sampleSensorsShowLiveStateFromTheSampleEvents() {
        let model = AppModel(options: LaunchOptions(usesPreviewEngine: true), engine: BridgeEngine.preview(), loginItems: InMemoryLoginItemService(),
                             defaults: ScratchDefaults().defaults, previewLatency: .zero)
        let driveway = model.sensorGroups()[0]
        #expect(driveway.sensors[0].stateText(now: Date()).hasPrefix("Detected "), "the sample Driveway saw a person 25 minutes ago")
        #expect(!driveway.sensors[0].isActive)
    }

    // MARK: Keyboard

    @Test func arrowKeysWalkTheListAndDiagnosticsReturnsIntoIt() {
        let a = UUID(), b = UUID()
        let order: [ManagerSelection] = [.overview, .camera(a), .camera(b), .sensorsBridge]
        #expect(SidebarNavigation.next(from: nil, offset: 1, order: order) == .overview)
        #expect(SidebarNavigation.next(from: .overview, offset: 1, order: order) == .camera(a))
        #expect(SidebarNavigation.next(from: .camera(b), offset: 1, order: order) == .sensorsBridge)
        #expect(SidebarNavigation.next(from: .sensorsBridge, offset: 1, order: order) == .sensorsBridge, "no wrap")
        #expect(SidebarNavigation.next(from: .overview, offset: -1, order: order) == .overview)
        // Diagnostics is a button below the list: up goes to the list's last page, down stays.
        #expect(SidebarNavigation.next(from: .diagnostics, offset: -1, order: order) == .sensorsBridge)
        #expect(SidebarNavigation.next(from: .diagnostics, offset: 1, order: order) == .diagnostics)
    }
}
