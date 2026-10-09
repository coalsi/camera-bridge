import BridgeEngine
import BridgeSupport
import Foundation
import Synchronization

/// One server-sent event: `event: <name>` and a JSON `data:` line.
struct ServerEvent: Sendable, Equatable {
    var name: String
    var data: String

    /// The wire form (`event:`, `data:`, blank line). Newlines in the data cannot occur (JSON is one line); a comment event has no name.
    var text: String {
        name.isEmpty ? ": \(data)\n\n" : "event: \(name)\ndata: \(data)\n\n"
    }

    static let ping = ServerEvent(name: "", data: "ping")
}

extension BridgeOverview {
    func cameraResources() -> [CameraResource] {
        configurations.map { configuration in
            CameraResource(configuration: configuration, status: cameras.first { $0.id == configuration.id }.map(CameraStatusResource.init))
        }
    }

    func cameraResource(id: UUID) -> CameraResource? {
        configurations.first { $0.id == id }.map { configuration in
            CameraResource(configuration: configuration, status: cameras.first { $0.id == id }.map(CameraStatusResource.init))
        }
    }

    var bridgeResource: BridgeStateResource {
        BridgeStateResource(state: StatusText.engineStateName(state), stateText: StatusText.engineState(state))
    }
}

struct BridgeStateResource: Encodable, Equatable {
    var state: String
    var stateText: String
}

struct MotionEventResource: Encodable {
    var id: UUID
    var name: String
    var active: Bool
}

struct DoorbellEventResource: Encodable {
    var id: UUID
    var name: String
    var date: Date
}

struct RemovedEventResource: Encodable {
    var id: UUID
}

/// Turns the bridge's changing state into events: the engine publishes state (it is observable on its actor), the hub looks at it
/// twice a second while somebody listens and says what changed — a camera's status or configuration (`camera`), motion starting
/// or stopping (`motion`), a doorbell ring (`doorbell`), a camera removed (`removed`), the bridge starting or pausing (`bridge`)
/// and the network notices (`notices`). A comment line every 15 s keeps idle connections open.
final class EventHub: Sendable {
    private let backend: any BridgeBackend
    private let interval: Duration
    private let broadcaster = AsyncBroadcaster<ServerEvent>(bufferingNewest: 256)
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(backend: any BridgeBackend, interval: Duration = .milliseconds(500)) {
        self.backend = backend
        self.interval = interval
    }

    func start() {
        task.withLock { task in
            guard task == nil else { return }
            task = Task { [self] in await run() }
        }
    }

    func stop() {
        let running = task.withLock { task -> Task<Void, Never>? in
            defer { task = nil }
            return task
        }
        running?.cancel()
        broadcaster.finish()
    }

    func subscribe() -> AsyncStream<ServerEvent> {
        broadcaster.subscribe()
    }

    var subscriberCount: Int { broadcaster.subscriberCount }

    /// What a new listener is told first: the state as it is now.
    static func snapshotEvents(_ overview: BridgeOverview, now: Date = Date()) -> [ServerEvent] {
        var events = [event("bridge", overview.bridgeResource)]
        events.append(contentsOf: overview.cameraResources().map { event("camera", $0) })
        events.append(event("notices", NoticeResource.resources(for: overview.networkNotices, now: now)))
        return events
    }

    static func event<T: Encodable>(_ name: String, _ value: T) -> ServerEvent {
        let data = (try? JSONEncoder.iso.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        return ServerEvent(name: name, data: data)
    }

    private func run() async {
        var cameras: [UUID: CameraStatus] = [:]
        var configurations: [UUID: CameraConfiguration] = [:]
        var bridge: BridgeStateResource?
        var notices: [NoticeResource.Fingerprint] = []
        var started = false
        var lastPing = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            guard broadcaster.subscriberCount > 0 else {
                started = false
                continue
            }
            let overview = await backend.overview()
            let now = Date()
            if !started {
                // First look since somebody listened: the listener got the snapshot itself, so this is the baseline.
                started = true
                cameras = Dictionary(overview.cameras.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                configurations = Dictionary(overview.configurations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                bridge = overview.bridgeResource
                notices = NoticeResource.resources(for: overview.networkNotices, now: now).map(\.fingerprint)
                continue
            }
            if overview.bridgeResource != bridge {
                bridge = overview.bridgeResource
                broadcaster.yield(Self.event("bridge", overview.bridgeResource))
            }
            let currentIDs = Set(overview.configurations.map(\.id))
            for id in configurations.keys where !currentIDs.contains(id) {
                broadcaster.yield(Self.event("removed", RemovedEventResource(id: id)))
                configurations[id] = nil
                cameras[id] = nil
            }
            for configuration in overview.configurations {
                let status = overview.cameras.first { $0.id == configuration.id }
                let changed = configurations[configuration.id] != configuration || cameras[configuration.id] != status
                if let status {
                    let before = cameras[configuration.id]
                    if before?.motionActive != status.motionActive, before != nil || status.motionActive {
                        broadcaster.yield(Self.event("motion", MotionEventResource(id: configuration.id, name: configuration.name, active: status.motionActive)))
                    }
                    if let date = status.lastEventDate, date != before?.lastEventDate, status.lastEvent?.localizedCaseInsensitiveContains("doorbell") == true,
                       before != nil {
                        broadcaster.yield(Self.event("doorbell", DoorbellEventResource(id: configuration.id, name: configuration.name, date: date)))
                    }
                }
                if changed {
                    broadcaster.yield(Self.event("camera", CameraResource(configuration: configuration, status: status.map(CameraStatusResource.init))))
                    configurations[configuration.id] = configuration
                    cameras[configuration.id] = status
                }
            }
            let currentNotices = NoticeResource.resources(for: overview.networkNotices, now: now)
            if currentNotices.map(\.fingerprint) != notices {
                notices = currentNotices.map(\.fingerprint)
                broadcaster.yield(Self.event("notices", currentNotices))
            }
            if ContinuousClock.now - lastPing >= .seconds(15) {
                lastPing = .now
                broadcaster.yield(.ping)
            }
        }
    }
}

extension NoticeResource {
    struct Fingerprint: Equatable {
        var id: String
        var severity: String
        var detail: String
    }

    var fingerprint: Fingerprint { Fingerprint(id: id, severity: severity, detail: detail) }
}
