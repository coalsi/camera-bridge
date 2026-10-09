import BridgeEngine
import CameraAdapters
import Foundation

/// One sensor under its camera in the sidebar's Sensors section, with what it shows now.
struct SidebarSensor: Equatable, Identifiable {
    /// What the sensor is reporting, as far as the camera's status tells.
    enum State: Equatable {
        /// A detection is held on (60 s after the last one, as the Home app's occupancy sensor does).
        case detected(Date)
        /// Not detecting; the last detection, when there was one.
        case clear(last: Date?)
        /// The status carries no live reading for this kind (day and night, temperature, humidity): it is published to Home.
        case published
    }

    let id: String
    let sensor: BridgedSensor
    let title: String
    let symbol: String
    let state: State

    var isActive: Bool {
        if case .detected = state { true } else { false }
    }

    /// "Detected now", "Detected 2 minutes ago", "Clear", "Published to Home".
    func stateText(now: Date) -> String {
        switch state {
        case .detected: String(localized: "Detected now")
        case .clear(let last?): String(localized: "Detected \(StatusText.timeAgo(last, now: now))")
        case .clear(nil): String(localized: "Clear")
        case .published: String(localized: "Published to Home")
        }
    }
}

/// The sensors one camera provides to the Sensors Bridge.
struct SidebarSensorGroup: Equatable, Identifiable {
    let id: UUID
    let name: String
    let kind: CameraKind
    let sensors: [SidebarSensor]
}

/// The sidebar's Sensors section: the sensors the bridge publishes, listed under the camera that provides them, in
/// configuration order (`SensorsBridgeStatus.publishedSensors`: what the engine publishes, never worked out from options).
enum SensorsSidebar {
    /// A detection holds the occupancy sensor on this long.
    static let holdDuration: TimeInterval = 60
    /// A camera with more sensors than this starts collapsed.
    static let expandedByDefaultLimit = 4

    static func groups(configurations: [CameraConfiguration], published: [UUID: [BridgedSensor]]?, statuses: [CameraStatus], now: Date) -> [SidebarSensorGroup] {
        guard let published else { return [] }
        let status = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return configurations.compactMap { camera in
            guard let sensors = published[camera.id], !sensors.isEmpty else { return nil }
            let rows = sensors.map { row(for: $0, camera: camera.id, status: status[camera.id], now: now) }
            return SidebarSensorGroup(id: camera.id, name: camera.name, kind: camera.kind, sensors: rows)
        }
    }

    /// The row for one published sensor. Detections and alarm inputs read the camera's recent events (rising edges, named
    /// "Person", "Vehicle", "Alarm input 2", …).
    static func row(for sensor: BridgedSensor, camera: UUID, status: CameraStatus?, now: Date) -> SidebarSensor {
        let id = sensor.stableKey(cameraID: camera)
        let symbol = SensorKind(sensor)?.symbol ?? "face.dashed"
        switch sensor {
        case .occupancy(let kind):
            return SidebarSensor(id: id, sensor: sensor, title: kind.rawValue.capitalized, symbol: symbol,
                                 state: detectionState(named: kind.rawValue.capitalized, in: status, now: now))
        case .contact(let input):
            return SidebarSensor(id: id, sensor: sensor, title: String(localized: "Alarm Input \(input)"), symbol: symbol,
                                 state: detectionState(named: "Alarm input \(input)", in: status, now: now))
        case .light:
            return SidebarSensor(id: id, sensor: sensor, title: String(localized: "Day and Night"), symbol: symbol, state: .published)
        case .temperature:
            return SidebarSensor(id: id, sensor: sensor, title: String(localized: "Temperature"), symbol: symbol, state: .published)
        case .humidity:
            return SidebarSensor(id: id, sensor: sensor, title: String(localized: "Humidity"), symbol: symbol, state: .published)
        }
    }

    private static func detectionState(named name: String, in status: CameraStatus?, now: Date) -> SidebarSensor.State {
        guard let last = status?.recentEvents.last(where: { $0.name == name })?.date else { return .clear(last: nil) }
        return now.timeIntervalSince(last) < holdDuration ? .detected(last) : .clear(last: last)
    }

    static func isExpanded(_ group: SidebarSensorGroup, overrides: [UUID: Bool]) -> Bool {
        overrides[group.id] ?? (group.sensors.count <= expandedByDefaultLimit)
    }

    /// The camera's line in the section header: "3 sensors".
    static func countText(_ count: Int) -> String {
        count == 1 ? String(localized: "1 sensor") : String(localized: "\(count) sensors")
    }
}

/// Where the sidebar's arrow keys go.
enum SidebarNavigation {
    /// The page `offset` steps from `current` in `order`; the first when nothing is selected. Pages outside the list (Diagnostics,
    /// reached by its button) go back into it from either end: up to the last, down stays where it is.
    static func next(from current: ManagerSelection?, offset: Int, order: [ManagerSelection]) -> ManagerSelection? {
        guard let current else { return order.first }
        guard let index = order.firstIndex(of: current) else { return offset < 0 ? order.last : current }
        return order[max(0, min(order.count - 1, index + offset))]
    }
}
