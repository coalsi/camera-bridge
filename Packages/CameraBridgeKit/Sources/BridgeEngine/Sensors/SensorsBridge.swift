import BridgeSupport
import CameraAdapters
import Foundation
import HAP
import HAPCore

/// The "CameraBridge Sensors" bridge (spec §3.4): one HAP bridge accessory (category 2) with a bridged accessory per
/// camera signal the user enabled and the camera provides (`BridgedSensor`). Bridged accessories keep their aid across
/// restarts, option changes and camera order (stable key `camera.<UUID>.<sensor>`). `apply(_:)` mirrors a camera's
/// `SensorState`: readings, StatusActive / StatusFault / StatusTampered on every sensor of the camera, and reachability
/// (false while the camera is offline, rejected its credentials or is disabled). Alarm inputs become contact sensors
/// once the camera reports them; their ids are remembered in the bridge's HAP state (at most
/// `maximumInputsPerCamera` per camera, ids up to `maximumInputIDLength` characters). Structure changes call
/// `AccessoryServer.configurationDidChange()` so controllers reload (`c#`).
public actor SensorsBridge {
    /// The accessory's display name. Home keeps its own name for a bridge that is already paired; this is only the default.
    public static let name = "Camera Bridge Sensors"
    /// The Bonjour service name, unchanged since before the product became "Camera Bridge", so the advertised identity stays the same.
    static let bonjourServiceName = "CameraBridge Sensors"
    /// LightSensor proxy readings (CurrentAmbientLightLevel is at least 0.0001 lux).
    public static let dayLux = 1000.0
    public static let nightLux = 1.0
    public static let maximumInputsPerCamera = 16
    public static let maximumInputIDLength = 32
    /// Rejected input ids remembered per camera (so they are not re-examined on every state).
    static let maximumIgnoredInputs = 64
    static let inputsExtraKey = "cameraBridge.digitalInputs"
    static let firmwareRevision = "1.0"

    /// The bridge accessory (its `bridgedAccessories` are the sensors).
    public nonisolated let accessory: Accessory
    public nonisolated let server: AccessoryServer

    private struct Published {
        let accessory: Accessory
        let service: Service
    }

    private var cameras: [UUID: CameraConfiguration] = [:]
    private var published: [UUID: [BridgedSensor: Published]] = [:]
    private var order: [UUID: [BridgedSensor]] = [:]
    private var states: [UUID: SensorState] = [:]
    /// Alarm input ids each camera has reported (loaded from the HAP state on first use).
    private var knownInputs: [UUID: Set<String>]?
    /// Input ids that were not published (over the limit or unusable); at most `maximumIgnoredInputs` per camera.
    private var ignoredInputs: [UUID: Set<String>] = [:]
    /// Cameras whose rejected inputs were warned about (once per camera).
    private var warnedInputs: Set<UUID> = []
    private let log = Log(category: "Sensors")

    public init(configuration: AccessoryServerConfiguration, store: any HAPStore, transport: any NetworkTransport,
                advertiser: any ServiceAdvertiser) {
        let accessory = Accessory(info: AccessoryInfo(name: Self.name, manufacturer: "CameraBridge", model: "Sensors Bridge",
                                                      serialNumber: "CameraBridge-Sensors", firmwareRevision: Self.firmwareRevision),
                                  category: .bridge)
        self.accessory = accessory
        self.server = AccessoryServer(accessory: accessory, configuration: configuration, store: store, transport: transport, advertiser: advertiser)
    }

    /// The engine's bridge: `HAPStorage.sensorsBridgeStore` (`hap.sensors-bridge`), the environment's transport,
    /// advertiser, loopback and advertising flags, on `port` (`BridgeSettings.sensorsBridgePort`).
    public init(environment: BridgeEnvironment, port: UInt16) {
        self.init(configuration: AccessoryServerConfiguration(port: port, advertise: environment.advertise, serviceName: Self.bonjourServiceName,
                                                              loopbackOnly: environment.loopbackOnly),
                  store: HAPStorage.sensorsBridgeStore(dataDirectory: environment.dataDirectory, secrets: environment.platform.secrets),
                  transport: environment.platform.transport, advertiser: environment.platform.advertiser)
    }

    public func start() async throws {
        _ = await loadKnownInputs()
        try await server.start()
    }

    public func stop() async {
        await server.stop()
    }

    /// Clears the pairings and keeps the identity (`AccessoryServer.resetPairings()`). The engine's
    /// `resetSensorsBridgePairing()` also replaces the identity, so the old setup code pairs nothing.
    public func resetPairing() async throws {
        try await server.resetPairings()
    }

    public func status() async throws -> SensorsBridgeStatus {
        SensorsBridgeStatus(isPaired: await server.isPaired, setupCode: try await server.setupCode.formatted,
                            setupURI: try await server.setupURI, accessoryCount: accessoryCount, publishedSensors: order)
    }

    public nonisolated var accessoryCount: Int { accessory.bridgedAccessories.count }

    /// The sensors published for a camera, in bridge order.
    public func sensors(for cameraID: UUID) -> [BridgedSensor] {
        order[cameraID] ?? []
    }

    /// Adds, removes and renames bridged accessories to match `cameras` (the full list; cameras not in it lose their
    /// sensors and remembered inputs, also inputs remembered from earlier runs).
    public func update(cameras configurations: [CameraConfiguration]) async {
        let remembered = await loadKnownInputs()
        var changed = false
        var seen = Set<UUID>()
        let unique = configurations.filter { seen.insert($0.id).inserted }
        for id in Array(cameras.keys) where !seen.contains(id) {
            cameras[id] = nil
            states[id] = nil
            ignoredInputs[id] = nil
            warnedInputs.remove(id)
            changed = reconcile(id) || changed
        }
        let forgotten = remembered.keys.filter { !seen.contains($0) }
        for id in forgotten { knownInputs?[id] = nil }
        let forgotInputs = !forgotten.isEmpty
        for camera in unique {
            cameras[camera.id] = camera
            changed = reconcile(camera.id) || changed
        }
        if forgotInputs { await persistKnownInputs() }
        if changed { await server.configurationDidChange() }
    }

    /// Mirrors a camera's state into its sensors (unknown cameras are ignored). New alarm input ids are remembered and,
    /// when the camera publishes alarm inputs, get a contact sensor.
    public func apply(_ state: SensorState) async {
        guard cameras[state.id] != nil else { return }
        states[state.id] = state
        let known = await loadKnownInputs()[state.id] ?? []
        let ignored = ignoredInputs[state.id] ?? []
        let fresh = state.digitalInputs.keys.filter { !known.contains($0) && !ignored.contains($0) }
        if !fresh.isEmpty {
            let valid = fresh.filter(EventRouter.isUsableInputID).sorted(by: BridgedSensor.inputOrder)
            let admitted = valid.prefix(max(0, Self.maximumInputsPerCamera - known.count))
            let rejected = Set(fresh).subtracting(admitted)
            if !rejected.isEmpty {
                var remembered = ignored
                for id in rejected.sorted() where remembered.count < Self.maximumIgnoredInputs { remembered.insert(id) }
                ignoredInputs[state.id] = remembered
                if warnedInputs.insert(state.id).inserted {
                    log.warning("\(cameras[state.id]?.name ?? "A camera") reported \(rejected.count) alarm input(s) that are not "
                                + "published (more than \(Self.maximumInputsPerCamera), or unusable ids)")
                }
            }
            if !admitted.isEmpty {
                knownInputs?[state.id] = known.union(admitted)
                await persistKnownInputs()
                if reconcile(state.id) { await server.configurationDidChange() }
            }
        }
        guard let current = states[state.id] else { return }   // the camera may have been removed meanwhile
        for (sensor, entry) in published[state.id] ?? [:] { Self.mirror(current, sensor: sensor, into: entry) }
    }

    /// Follows `router`: subscribes to its outputs first, then applies every camera's current state, then the outputs
    /// (`follow(_:)`). A change while catching up is applied after the snapshot instead of being lost; a state applied
    /// twice is harmless.
    func follow(router: EventRouter) async -> Task<Void, Never> {
        let outputs = router.outputs
        for state in await router.states { await apply(state) }
        return follow(outputs)
    }

    /// Applies every `.state` of `outputs` (e.g. `EventRouter.outputs`) until the stream ends or the task is cancelled.
    public nonisolated func follow(_ outputs: AsyncStream<EventRouterOutput>) -> Task<Void, Never> {
        Task { [weak self] in
            for await output in outputs {
                guard let self else { return }
                if case .state(let state) = output { await self.apply(state) }
            }
        }
    }

    // MARK: - Names

    /// Longest name Home is given.
    static let maximumNameLength = 64

    /// "<camera> <label>" as Home accepts it (the rule HAP-NodeJS `checkName` warns about): letters, digits, spaces and
    /// `'` `’` `.` `,` `-` only, starting and ending with a letter or digit, at most 64 characters. Both parts are
    /// cleaned (`homeSafe`); "Camera" stands in when nothing of the camera's name is left, "Sensor" for the label.
    static func homeName(_ cameraName: String, _ label: String) -> String {
        // Labels up to 48 characters stay whole ("Alarm Input " + a 32-character id), so distinct labels stay distinct.
        var cleanLabel = homeSafe(String(homeSafe(label).prefix(48)))
        if cleanLabel.isEmpty { cleanLabel = "Sensor" }
        let camera = homeSafe(String(homeSafe(cameraName).prefix(maximumNameLength - cleanLabel.count - 1)))
        return "\(camera.isEmpty ? "Camera" : camera) \(cleanLabel)"
    }

    /// `text` with every character Home rejects turned into a space, runs of spaces collapsed and both ends trimmed to a
    /// letter or digit (canonically composed first, so "é" stays one letter). Empty when nothing usable is left.
    static func homeSafe(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if isLetterOrDigit(scalar) || "'.,-\u{2019}".unicodeScalars.contains(scalar) {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        while let first = result.unicodeScalars.first, !isLetterOrDigit(first) { result.unicodeScalars.removeFirst() }
        while let last = result.unicodeScalars.last, !isLetterOrDigit(last) { result.unicodeScalars.removeLast() }
        return result
    }

    /// Unicode letters (L*) and numbers (N*): what Home's name rule calls alphanumeric.
    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    /// Labels for a camera's sensors (in `sensors` order): alarm inputs are "Alarm Input <id>" with the id cleaned for
    /// Home, or "Alarm Input <n>" (the input's position) when nothing of the id is left or two ids clean to the same text.
    static func labels(for sensors: [BridgedSensor]) -> [BridgedSensor: String] {
        var labels: [BridgedSensor: String] = [:]
        let inputs = sensors.compactMap { sensor -> String? in if case .contact(let input) = sensor { input } else { nil } }
        let cleaned = inputs.map { homeSafe($0) }
        var counts: [String: Int] = [:]
        for text in cleaned where !text.isEmpty { counts[text.lowercased(), default: 0] += 1 }
        var used = Set<String>()
        var fallbacks: [(position: Int, input: String)] = []
        for (position, (input, text)) in zip(inputs, cleaned).enumerated() {
            if !text.isEmpty, counts[text.lowercased()] == 1 {
                let label = "Alarm Input \(text)"
                labels[.contact(input: input)] = label
                used.insert(label.lowercased())
            } else {
                fallbacks.append((position + 1, input))
            }
        }
        for (position, input) in fallbacks {
            var number = position
            while used.contains("alarm input \(number)") { number += 1 }
            let label = "Alarm Input \(number)"
            labels[.contact(input: input)] = label
            used.insert(label.lowercased())
        }
        for sensor in sensors where labels[sensor] == nil { labels[sensor] = sensor.label }
        return labels
    }

    // MARK: - Private

    /// Makes the camera's published sensors match its configuration; true when accessories were added or removed.
    private func reconcile(_ id: UUID) -> Bool {
        let desired = cameras[id].map { BridgedSensor.sensors(for: $0, knownInputs: knownInputs?[id] ?? []) } ?? []
        var current = published[id] ?? [:]
        var changed = false
        for (sensor, entry) in current where !desired.contains(sensor) {
            accessory.removeBridgedAccessory(entry.accessory)
            current[sensor] = nil
            changed = true
        }
        if let camera = cameras[id] {
            let labels = Self.labels(for: desired)
            for sensor in desired {
                let name = Self.homeName(camera.name, labels[sensor] ?? sensor.label)
                if let entry = current[sensor] {
                    Self.rename(entry, to: name)
                    continue
                }
                let entry = Self.makeAccessory(sensor, camera: camera, name: name)
                if let state = states[id] { Self.mirror(state, sensor: sensor, into: entry) }
                accessory.addBridgedAccessory(entry.accessory)
                current[sensor] = entry
                changed = true
            }
        }
        published[id] = current.isEmpty ? nil : current
        order[id] = desired.isEmpty ? nil : desired
        return changed
    }

    private static func makeAccessory(_ sensor: BridgedSensor, camera: CameraConfiguration, name: String) -> Published {
        let serial = String("\(camera.id.uuidString.prefix(8))-\(sensor.keySuffix)".prefix(64))
        let info = AccessoryInfo(name: name, manufacturer: "CameraBridge", model: sensor.model, serialNumber: serial,
                                 firmwareRevision: firmwareRevision)
        let accessory = Accessory(info: info, category: .sensor, stableKey: sensor.stableKey(cameraID: camera.id))
        let service = Service(sensor.serviceType, name: name)
        service.characteristic(.statusActive).update(.bool(true))
        service.characteristic(.statusFault).update(.uint(0))
        service.characteristic(.statusTampered).update(.uint(0))
        if sensor == .light { service.characteristic(.currentAmbientLightLevel).update(.float(dayLux)) }
        accessory.addService(service)
        return Published(accessory: accessory, service: service)
    }

    private static func rename(_ entry: Published, to name: String) {
        entry.accessory.informationService.characteristic(.name).update(.string(name))
        entry.service.characteristic(.name).update(.string(name))
    }

    private static func mirror(_ state: SensorState, sensor: BridgedSensor, into entry: Published) {
        let service = entry.service
        entry.accessory.setReachable(state.isReachable)
        service.characteristic(.statusActive).update(.bool(state.isActive))
        service.characteristic(.statusFault).update(.uint(state.isFault ? 1 : 0))
        service.characteristic(.statusTampered).update(.uint(state.tampered ? 1 : 0))
        let value = service.characteristic(sensor.valueType)
        switch sensor {
        case .occupancy(let kind):
            value.update(.uint(state.objects.contains(kind) ? 1 : 0))
        case .light:
            if let isNight = state.isNight { value.update(.float(isNight ? nightLux : dayLux)) }
        case .contact(let input):
            value.update(.uint(state.digitalInputs[input] == true ? 1 : 0))
        case .temperature:
            if let celsius = state.temperature, celsius.isFinite { value.update(.float(celsius)) }
        case .humidity:
            if let percent = state.humidity, percent.isFinite { value.update(.float(percent)) }
        }
    }

    private func loadKnownInputs() async -> [UUID: Set<String>] {
        if let knownInputs { return knownInputs }
        var loaded: [UUID: Set<String>] = [:]
        if let data = await server.extra(forKey: Self.inputsExtraKey),
           let stored = try? JSONDecoder().decode([String: [String]].self, from: data) {
            for (key, ids) in stored {
                guard let id = UUID(uuidString: key) else { continue }
                let valid = ids.filter(EventRouter.isUsableInputID).sorted(by: BridgedSensor.inputOrder)
                if !valid.isEmpty { loaded[id] = Set(valid.prefix(Self.maximumInputsPerCamera)) }
            }
        }
        if let knownInputs { return knownInputs }   // loaded by a concurrent call
        knownInputs = loaded
        return loaded
    }

    private func persistKnownInputs() async {
        let stored = Dictionary(uniqueKeysWithValues: (knownInputs ?? [:]).map { ($0.key.uuidString, $0.value.sorted()) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try await server.store(extra: try encoder.encode(stored), forKey: Self.inputsExtraKey)
        } catch {
            log.warning("Could not save the sensors bridge's alarm inputs: \(error)")
        }
    }
}
