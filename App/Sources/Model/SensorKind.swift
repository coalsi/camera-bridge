import BridgeEngine
import CameraAdapters
import Foundation

/// Optional sensors a camera can publish on the sensors bridge (spec §3.4). Offered only when the camera reports the
/// matching event, or (detections) when the webhook is the camera's motion source and can report them.
enum SensorKind: String, CaseIterable, Identifiable {
    case person, vehicle, animal, package, dayNight, digitalInputs, temperature, humidity

    var id: Self { self }

    var requiredEvent: CameraEventKind {
        switch self {
        case .person: .person
        case .vehicle: .vehicle
        case .animal: .animal
        case .package: .package
        case .dayNight: .dayNight
        case .digitalInputs: .digitalInput
        case .temperature: .temperature
        case .humidity: .humidity
        }
    }

    var keyPath: WritableKeyPath<SensorOptions, Bool> {
        switch self {
        case .person: \.person
        case .vehicle: \.vehicle
        case .animal: \.animal
        case .package: \.package
        case .dayNight: \.dayNight
        case .digitalInputs: \.digitalInputs
        case .temperature: \.temperature
        case .humidity: \.humidity
        }
    }

    var title: String {
        switch self {
        case .person: String(localized: "Person Detection")
        case .vehicle: String(localized: "Vehicle Detection")
        case .animal: String(localized: "Animal Detection")
        case .package: String(localized: "Package Detection")
        case .dayNight: String(localized: "Day and Night")
        case .digitalInputs: String(localized: "Alarm Inputs")
        case .temperature: String(localized: "Temperature")
        case .humidity: String(localized: "Humidity")
        }
    }

    /// What appears in the Home app.
    var homeAccessory: String {
        switch self {
        case .person, .vehicle, .animal, .package: String(localized: "Occupancy sensor (stays on for 60 seconds)")
        case .dayNight: String(localized: "Light sensor (night reads 1 lux, day 1000 lux)")
        case .digitalInputs: String(localized: "Contact sensor")
        case .temperature: String(localized: "Temperature sensor")
        case .humidity: String(localized: "Humidity sensor")
        }
    }

    var symbol: String {
        switch self {
        case .person: "figure.stand"
        case .vehicle: "car"
        case .animal: "pawprint"
        case .package: "shippingbox"
        case .dayNight: "sun.max"
        case .digitalInputs: "switch.2"
        case .temperature: "thermometer.medium"
        case .humidity: "humidity"
        }
    }

    /// Detections the webhook can report (`POST …/person`, `/vehicle`, `/animal`, `/package`): offered for a camera whose
    /// motion source is the webhook (Frigate or Home Assistant next to a plain RTSP camera), as the engine publishes them.
    static let webhookKinds: [SensorKind] = [.person, .vehicle, .animal, .package]

    /// The sensors `capabilities` offer, plus the webhook's detections when `motionSource` is the webhook.
    static func available(in capabilities: CameraCapabilities?, motionSource: MotionSource) -> [SensorKind] {
        let events = capabilities?.events ?? []
        return allCases.filter { events.contains($0.requiredEvent) || (motionSource == .webhook && webhookKinds.contains($0)) }
    }

    /// Offered only because the webhook can report it (the camera itself doesn't).
    func isFromWebhook(in capabilities: CameraCapabilities?, motionSource: MotionSource) -> Bool {
        motionSource == .webhook && Self.webhookKinds.contains(self) && !(capabilities?.events.contains(requiredEvent) ?? false)
    }

    /// The option behind a sensor the bridge publishes; nil for face detections, which no option publishes.
    init?(_ sensor: BridgedSensor) {
        switch sensor {
        case .occupancy(.person): self = .person
        case .occupancy(.vehicle): self = .vehicle
        case .occupancy(.animal): self = .animal
        case .occupancy(.package): self = .package
        case .occupancy(.face): return nil
        case .light: self = .dayNight
        case .contact: self = .digitalInputs
        case .temperature: self = .temperature
        case .humidity: self = .humidity
        }
    }

    /// The Sensors Bridge page's names for one camera's published sensors (`SensorsBridgeStatus.publishedSensors`), in
    /// the bridge's order: each kind once, alarm inputs counted ("2 Alarm Inputs").
    static func names(of sensors: [BridgedSensor]) -> [String] {
        let inputs = sensors.filter { if case .contact = $0 { true } else { false } }.count
        var seen: Set<SensorKind> = [], names: [String] = []
        for sensor in sensors {
            guard let kind = SensorKind(sensor), seen.insert(kind).inserted else { continue }
            if kind == .digitalInputs {
                names.append(inputs == 1 ? String(localized: "1 Alarm Input") : String(localized: "\(inputs) Alarm Inputs"))
            } else {
                names.append(kind.title)
            }
        }
        return names
    }

    /// One line of the Sensors Bridge page's "Cameras With Sensors".
    struct CameraRow: Equatable, Identifiable {
        var id: UUID
        var name: String
        var sensors: [String]
    }

    /// The cameras the bridge publishes sensors for, in configuration order, with `names(of:)` their sensors. From the
    /// engine's list (`published`), never worked out from the options: the engine decides what it publishes.
    static func cameraRows(_ configurations: [CameraConfiguration], published: [UUID: [BridgedSensor]]) -> [CameraRow] {
        configurations.compactMap { camera in
            let names = names(of: published[camera.id] ?? [])
            return names.isEmpty ? nil : CameraRow(id: camera.id, name: camera.name, sensors: names)
        }
    }

    /// The camera page's toggles: what the camera (or its webhook) offers, plus — while its capabilities are unknown, when
    /// the engine trusts the options — every sensor that is on, so each sensor the bridge may publish can be turned off.
    /// (What the bridge does publish is the engine's: `SensorsBridgeStatus.publishedSensors`.)
    static func shown(in capabilities: CameraCapabilities?, motionSource: MotionSource, options: SensorOptions) -> [SensorKind] {
        let offered = Set(available(in: capabilities, motionSource: motionSource))
        return allCases.filter { offered.contains($0) || (capabilities == nil && options[keyPath: $0.keyPath]) }
    }

    /// `options` after the motion source changes from `old` to `new`: a sensor shown under `old` and not under `new` (the
    /// webhook's detections, for a camera that doesn't report them) is turned off; every other setting is kept.
    static func adjusted(_ options: SensorOptions, capabilities: CameraCapabilities?, from old: MotionSource, to new: MotionSource) -> SensorOptions {
        let hidden = Set(shown(in: capabilities, motionSource: old, options: options))
            .subtracting(shown(in: capabilities, motionSource: new, options: options))
        var result = options
        for kind in hidden { result[keyPath: kind.keyPath] = false }
        return result
    }

    /// `options` with every sensor the camera (or its webhook) can't provide turned off.
    static func filtered(_ options: SensorOptions, by capabilities: CameraCapabilities?, motionSource: MotionSource) -> SensorOptions {
        let available = Set(available(in: capabilities, motionSource: motionSource))
        var result = SensorOptions()
        for kind in allCases where available.contains(kind) {
            result[keyPath: kind.keyPath] = options[keyPath: kind.keyPath]
        }
        return result
    }
}
