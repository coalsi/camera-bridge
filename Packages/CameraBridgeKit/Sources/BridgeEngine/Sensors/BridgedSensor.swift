import CameraAdapters
import Foundation
import HAP

/// One accessory on the sensors bridge for a camera (spec §3.4; integration brief §4).
public enum BridgedSensor: Hashable, Sendable {
    /// OccupancySensor for person, vehicle, animal or package detections (60 s hold; never triggers recording).
    case occupancy(DetectedObjectKind)
    /// LightSensor proxy for the camera's day/night mode: night 1 lux, day 1000 lux.
    case light
    /// ContactSensor per alarm input: an active input reads "contact not detected" (1, open).
    case contact(input: String)
    case temperature
    case humidity

    /// Last component of the stable key: `person`, `vehicle`, `animal`, `package`, `dayNight`, `input.<id>`,
    /// `temperature`, `humidity`.
    public var keySuffix: String {
        switch self {
        case .occupancy(let kind): kind.rawValue
        case .light: "dayNight"
        case .contact(let input): "input.\(input)"
        case .temperature: "temperature"
        case .humidity: "humidity"
        }
    }

    /// The bridged accessory's persisted identity (its aid is stored under it): `camera.<UUID>.<suffix>`.
    public func stableKey(cameraID: UUID) -> String {
        "camera.\(cameraID.uuidString).\(keySuffix)"
    }

    /// Appended to the camera's name in Home (alarm-input ids raw: `SensorsBridge.labels(for:)` cleans them).
    var label: String {
        switch self {
        case .occupancy(let kind): kind.rawValue.capitalized
        case .light: "Daylight"
        case .contact(let input): "Alarm Input \(input)"
        case .temperature: "Temperature"
        case .humidity: "Humidity"
        }
    }

    var model: String {
        switch self {
        case .occupancy: "Occupancy Sensor"
        case .light: "Light Sensor"
        case .contact: "Contact Sensor"
        case .temperature: "Temperature Sensor"
        case .humidity: "Humidity Sensor"
        }
    }

    var serviceType: ServiceType {
        switch self {
        case .occupancy: .occupancySensor
        case .light: .lightSensor
        case .contact: .contactSensor
        case .temperature: .temperatureSensor
        case .humidity: .humiditySensor
        }
    }

    /// The characteristic that carries the reading.
    var valueType: CharacteristicType {
        switch self {
        case .occupancy: .occupancyDetected
        case .light: .currentAmbientLightLevel
        case .contact: .contactSensorState
        case .temperature: .currentTemperature
        case .humidity: .currentRelativeHumidity
        }
    }

    /// Numeric ids in numeric order ("2" before "10"), then the others alphabetically.
    static func inputOrder(_ lhs: String, _ rhs: String) -> Bool {
        switch (Int(lhs), Int(rhs)) {
        case let (left?, right?): left < right
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): lhs < rhs
        }
    }

    /// Detections a camera whose motion source is the webhook can receive from there (Frigate, Home Assistant:
    /// `POST …/<person|vehicle|animal|package>`), whatever the camera itself reports.
    static let webhookEvents: Set<CameraEventKind> = [.person, .vehicle, .animal, .package]

    /// The sensors `camera` publishes: enabled in its options and offered by the camera (unknown capabilities trust
    /// the options) or, for detections, by the webhook when it is the camera's motion source. Alarm inputs: one per id
    /// in `knownInputs` (inputs the camera has reported), sorted.
    static func sensors(for camera: CameraConfiguration, knownInputs: Set<String>) -> [BridgedSensor] {
        let events = camera.capabilities?.events
        let fromWebhook = camera.motionSource == .webhook ? webhookEvents : []
        func offered(_ kind: CameraEventKind) -> Bool { (events?.contains(kind) ?? true) || fromWebhook.contains(kind) }
        let options = camera.sensors
        var result: [BridgedSensor] = []
        let wanted: [(DetectedObjectKind, Bool, CameraEventKind)] = [(.person, options.person, .person), (.vehicle, options.vehicle, .vehicle),
                                                                     (.animal, options.animal, .animal), (.package, options.package, .package)]
        for (kind, enabled, event) in wanted where enabled && offered(event) { result.append(.occupancy(kind)) }
        if options.dayNight && offered(.dayNight) { result.append(.light) }
        if options.digitalInputs && offered(.digitalInput) {
            result += knownInputs.sorted(by: inputOrder).map { .contact(input: $0) }
        }
        if options.temperature && offered(.temperature) { result.append(.temperature) }
        if options.humidity && offered(.humidity) { result.append(.humidity) }
        return result
    }
}
