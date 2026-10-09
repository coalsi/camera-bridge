import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One `EventNotificationAlert` from the ISAPI alertStream.
struct HikvisionAlert: Sendable, Equatable {
    var eventType: String
    var eventState: String
    /// `channelID` or `dynChannelID`.
    var channelID: String?
    /// Detection targets (`detectionTarget`, `detectionTarget/name` or `targetType`), lowercased.
    var targets: [String]
    /// Alarm input port for `IO` events.
    var inputPort: String?

    var isActive: Bool { eventState.lowercased() != "inactive" }

    /// `videoloss` + `inactive` arrives periodically: a heartbeat for the idle watchdog, not an event.
    var isHeartbeat: Bool { eventType.lowercased() == "videoloss" && !isActive }

    static func parse(_ data: Data) -> HikvisionAlert? {
        guard let tree = try? XMLTree.parse(data), tree.matches("EventNotificationAlert"),
              let eventType = tree.string("eventType"), !eventType.isEmpty else { return nil }
        var targets: [String] = []
        for node in tree.descendants("detectionTarget") + tree.descendants("targetType") {
            let value = (node.child("name")?.text ?? node.text).lowercased()
            if !value.isEmpty, !targets.contains(value) { targets.append(value) }
        }
        let channel = [tree.string("channelID"), tree.string("dynChannelID")].compactMap { $0 }.first { !$0.isEmpty }
        let port = [tree.string("inputIOPortID"), tree.string("dynInputIOPortID"), tree.firstDescendant("inputIOPortID")?.text]
            .compactMap { $0 }.first { !$0.isEmpty }
        return HikvisionAlert(eventType: eventType, eventState: tree.string("eventState") ?? "active", channelID: channel, targets: targets,
                              inputPort: port)
    }
}

/// ISAPI event types → signals. Pulse events (VMD ~1 s pulses, smart events) are held `pulseHold` (20 s) after the
/// last pulse; smart detections also pulse motion so HKSV records them.
enum HikvisionEventMapper {
    static func signals(for alert: HikvisionAlert, pulseHold: Duration, channelFilter: String? = nil) -> [EventSignal] {
        if let channelFilter, let channel = alert.channelID, channel != channelFilter { return [] }
        let type = alert.eventType
        switch type.lowercased() {
        case "vmd", "pir":
            return alert.isActive ? [.activate(.motion, source: "VMD", hold: pulseHold)] : []
        case "fielddetection", "linedetection", "regionentrance", "regionexiting", "regionexit":
            guard alert.isActive else { return [] }
            var kinds: [DetectedObjectKind] = []
            for target in alert.targets {
                let kind: DetectedObjectKind? = switch target {
                case "human", "person", "people", "pedestrian": .person
                case "vehicle", "car", "motorvehicle", "nonmotorvehicle": .vehicle
                case "animal": .animal
                default: nil
                }
                if let kind, !kinds.contains(kind) { kinds.append(kind) }
            }
            return kinds.map { .activate(.object($0), source: type, hold: pulseHold) } + [.activate(.motion, source: "smart", hold: pulseHold)]
        case "tamperdetection", "shelteralarm", "defocus", "scenechangedetection":
            return alert.isActive ? [.activate(.tamper, source: type, hold: pulseHold)] : [.deactivate(.tamper, source: type)]
        case "io":
            let key = HoldKey.digitalInput(alert.inputPort ?? "1")
            return alert.isActive ? [.activate(key, source: "IO", hold: pulseHold)] : [.deactivate(key, source: "IO")]
        case "audioexception":
            return alert.isActive ? [.activate(.audioAlarm, source: type, hold: pulseHold)] : [.deactivate(.audioAlarm, source: type)]
        default:
            return []
        }
    }
}

struct HikvisionEventTiming: Sendable {
    var pulseHold: Duration = .seconds(20)
    /// No bytes (not even the videoloss heartbeat) for this long → restart the stream.
    var idleTimeout: Duration = .seconds(300)
    /// A stream that lived ≥ 10 s reconnects at once; one that died faster waits ≥ 10 s (then backoff to 60 s).
    var policy = ReconnectPolicy(backoff: Backoff(), healthyAfter: .seconds(10), minimumDelayAfterFailure: .seconds(10))
    var ringDedupe: Duration = .seconds(3)
}

private struct HikvisionIdleTimeout: Error, CustomStringConvertible {
    var description: String { "alertStream idle timeout" }
}

/// Hikvision event sources: one per camera (or NVR channel), all fed by the device's shared `HikvisionAlertHub`.
enum HikvisionEvents {
    /// The per-channel source only follows the hub (which owns reconnects and their timing), so it restarts quickly
    /// if its subscription ever ends.
    static let followerPolicy = ReconnectPolicy(backoff: Backoff(initial: .milliseconds(100), maximum: .seconds(1)), healthyAfter: .seconds(1))

    /// Events of one camera: alerts from the device's shared alertStream, filtered by `channelFilter` (the NVR
    /// channel's `channelID`; nil = every alert), mapped with this camera's hold timing. `resubscribing`: the source
    /// replaces an earlier one of the same camera (wake, network change); its first subscription counts towards
    /// reconnecting the shared stream (`HikvisionAlertHub`).
    static func makeSource(endpoint: CameraEndpoint, credentials: HTTPCredentials?, channelFilter: String?,
                           timing: HikvisionEventTiming = HikvisionEventTiming(), cameraID: UUID? = nil,
                           resubscribing: Bool = false) -> SupervisedEventSource {
        let label = "Hikvision \(endpoint.host)" + (channelFilter.map { " channel \($0)" } ?? "")
        let pendingResubscribe = LockedValue(resubscribing)
        return SupervisedEventSource(label: label, cameraID: cameraID, policy: followerPolicy, ringDedupe: timing.ringDedupe) { context in
            let resubscribe = pendingResubscribe.withLock { pending in
                defer { pending = false }
                return pending
            }
            let subscription = HikvisionAlertHub.acquire(endpoint: endpoint, credentials: credentials, timing: timing, cameraID: cameraID,
                                                         resubscribing: resubscribe)
            defer { subscription.release() }
            let (connected, credentialsRejected, updates) = subscription.hub.subscribe()
            if connected { context.connected() }
            if credentialsRejected { await context.apply([.event(.authenticationFailed)]) }
            for await update in updates {
                switch update {
                case .connected(true): context.connected()
                case .connected(false): await context.disconnected()
                case .authenticationFailed: await context.apply([.event(.authenticationFailed)])
                case .alert(let alert):
                    await context.apply(HikvisionEventMapper.signals(for: alert, pulseHold: timing.pulseHold, channelFilter: channelFilter))
                }
            }
            try Task.checkCancellation()
        }
    }

    /// One alertStream connection: the multipart response's XML alerts (heartbeats only feed the idle watchdog).
    static func alertSession(endpoint: CameraEndpoint, credentials: HTTPCredentials?, timing: HikvisionEventTiming,
                             onConnected: @Sendable () -> Void, onAlert: @escaping @Sendable (HikvisionAlert) -> Void) async throws {
        let (response, body, client) = try await HikvisionISAPI.alertStream(endpoint: endpoint, credentials: credentials,
                                                                             readTimeout: timing.idleTimeout + .seconds(30))
        defer { client.invalidate() }
        switch response.statusCode {
        case 200: break
        case 401: throw CameraAdapterError.unauthorized
        default: throw CameraAdapterError.httpStatus(response.statusCode)
        }
        onConnected()
        let lastActivity = LockedValue(ContinuousClock.now)
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var parser = MultipartStreamParser(contentType: contentType)
                for try await chunk in body {
                    lastActivity.set(.now)
                    for part in try parser.feed(chunk) where part.isXML {
                        guard let alert = HikvisionAlert.parse(part.body), !alert.isHeartbeat else { continue }
                        onAlert(alert)
                    }
                }
            }
            group.addTask {
                let interval = min(timing.idleTimeout / 4, .seconds(5))
                while true {
                    try await Task.sleep(for: interval)
                    if ContinuousClock.now - lastActivity.value >= timing.idleTimeout { throw HikvisionIdleTimeout() }
                }
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
