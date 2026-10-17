import BridgeSupport
import Foundation
import MediaCore

/// eufy model codes and their names, for the camera list and the accessory's model field.
public enum EufyModels {
    static let names: [String: String] = [
        "T8134": "SoloCam S220", "T8170": "SoloCam S340", "T8171": "SoloCam E30", "T8130": "SoloCam S40", "T8131": "SoloCam L40",
        "T8122": "SoloCam L20", "T8123": "SoloCam L40", "T8124": "SoloCam E40", "T8424": "4G Starlight Camera", "T8150": "Wired Wall Light Cam S100",
        "T8400": "Indoor Cam 2K", "T8410": "Indoor Cam Pan & Tilt 2K", "T8416": "Indoor Cam S350", "T8441": "Floodlight Cam E340",
        "T8210": "Video Doorbell", "T8213": "Video Doorbell Dual", "T8214": "Video Doorbell E340", "T8222": "Video Doorbell C210",
    ]

    /// "SoloCam S220" for `T8134` (the code's first five characters decide); the code itself for models this list doesn't know.
    public static func name(for model: String) -> String {
        names[String(model.prefix(5)).uppercased()] ?? (model.isEmpty ? "eufy camera" : "eufy \(model)")
    }
}

/// A eufy camera brought in by the `eufy-bridge` helper (`EufyBridge`). It streams on demand: the engine reads it only while a viewer, a
/// recording or a motion event wants the picture (`CameraDriver.streamsOnDemand`), because battery cameras sleep between those. Motion,
/// person and doorbell events come from the account's push notifications through the helper; snapshots are the helper's latest picture
/// (no wake-up). The ordinary RTSP ingest reads go2rtc, which reads the helper's HTTP stream.
final class EufyDriver: StreamHoldingDriver, Sendable {
    let vendor: CameraVendor = .go2rtc
    var streamsOnDemand: Bool { true }

    private let cameraID: UUID?
    private let streamID: String
    private let settings: IntegrationSettings?
    private let provider: (any Go2RTCStreamProviding)?
    private let bridge: EufyBridge

    init(cameraID: UUID?, settings: IntegrationSettings?, provider: (any Go2RTCStreamProviding)?, bridge: EufyBridge = .shared) {
        self.cameraID = cameraID
        self.streamID = Go2RTCManager.streamName(for: cameraID ?? UUID())
        self.settings = settings
        self.provider = provider
        self.bridge = bridge
    }

    private var serial: String { settings?.details[IntegrationSettings.Key.eufySerial] ?? "" }

    /// Never wakes the camera: what the account says about it.
    func probe() async throws -> CameraProbeResult {
        guard !serial.isEmpty else { throw IntegrationError("This camera isn’t tied to a eufy camera. Remove it and add it again from Plugins, eufy.") }
        let model = settings?.details[IntegrationSettings.Key.eufyModel] ?? ""
        return CameraProbeResult(vendor: .go2rtc, manufacturer: "eufy", model: EufyModels.name(for: model), serialNumber: "eufy-" + serial,
                                 firmware: "", capabilities: CameraCapabilities(events: [.motion, .person], snapshotAPI: true))
    }

    func makeEventSource() -> (any CameraEventSource)? {
        serial.isEmpty ? nil : EufyEventSource(serial: serial, bridge: bridge)
    }

    func snapshot() async throws -> Data? {
        guard !serial.isEmpty else { return nil }
        return try await bridge.snapshot(serial: serial)
    }

    func makeTalkbackSink() -> (any TalkbackSink)? { nil }

    /// What eufy's cloud last heard from the camera (the helper's `/devices`): never wakes it.
    func batteryStatus() async -> BatteryStatus? {
        guard !serial.isEmpty else { return nil }
        return await bridge.battery(serial: serial)
    }

    func attachStreams() async throws -> URL {
        guard let provider else { throw IntegrationError("The streaming helper isn’t available in this copy of Camera Bridge.") }
        guard await bridge.isInstalled() else { throw IntegrationError("This copy of Camera Bridge OS doesn’t include the eufy helper.") }
        guard !serial.isEmpty else { throw IntegrationError("This camera isn’t tied to a eufy camera. Remove it and add it again from Plugins, eufy.") }
        let endpoint = await bridge.endpoint
        return try await provider.attach(streamID: streamID, source: .eufyBridge(port: endpoint.port, token: endpoint.token, serial: serial))
    }

    func releaseStreams() async {
        await provider?.detach(streamID: streamID)
    }

    func close() async {
        await releaseStreams()
    }
}

/// A eufy camera's events from the helper: Eufy's push notifications are single pulses, so motion (and a person) stays on for `hold` after
/// the last one, then turns off.
final class EufyEventSource: CameraEventSource, Sendable {
    static let hold: Duration = .seconds(30)

    private let serial: String
    private let bridge: EufyBridge
    private let task = LockedValue<Task<Void, Never>?>(nil)

    init(serial: String, bridge: EufyBridge) {
        self.serial = serial
        self.bridge = bridge
    }

    func events() -> AsyncStream<CameraEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CameraEvent.self)
        let serial = serial, bridge = bridge
        let work = Task {
            let incoming = await bridge.events(serial: serial)
            continuation.yield(.eventChannel(connected: true))
            let pulses = EufyPulses(hold: Self.hold, emit: { continuation.yield($0) })
            for await event in incoming {
                if Task.isCancelled { break }
                switch event.kind {
                case "motion": await pulses.pulse(.motion)
                case "person":
                    await pulses.pulse(.motion)
                    await pulses.pulse(.object(.person))
                case "ring": continuation.yield(.doorbellPressed)
                default: break
                }
            }
            await pulses.end()
            continuation.finish()
        }
        task.withLock { $0 = work }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    func stop() async {
        task.withLock { $0 }?.cancel()
    }
}

/// Turns pulses into on/off: on at the first, off `hold` after the last.
actor EufyPulses {
    private let hold: Duration
    private let emit: @Sendable (CameraEvent) -> Void
    private var timers: [HoldKey: Task<Void, Never>] = [:]

    init(hold: Duration, emit: @escaping @Sendable (CameraEvent) -> Void) {
        self.hold = hold
        self.emit = emit
    }

    func pulse(_ key: HoldKey) {
        if timers[key] == nil { emit(key.event(active: true)) }
        timers[key]?.cancel()
        let hold = hold
        timers[key] = Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            await self?.expire(key)
        }
    }

    private func expire(_ key: HoldKey) {
        guard timers.removeValue(forKey: key) != nil else { return }
        emit(key.event(active: false))
    }

    func end() {
        for (key, timer) in timers {
            timer.cancel()
            emit(key.event(active: false))
        }
        timers = [:]
    }
}
