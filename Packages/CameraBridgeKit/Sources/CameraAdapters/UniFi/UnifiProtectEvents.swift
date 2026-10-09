import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// One message of Protect's events WebSocket (`wss://console/proxy/protect/integration/v1/subscribe/events`):
/// `{"type":"add","item":{"id":"…","modelKey":"event","type":"motion","start":1741267544209,"end":null,"device":"<camera id>",
/// "smartDetectTypes":["person"]}}`. An `update` later carries the event's `end` (it may be a partial item, with no types).
struct UnifiEventMessage: Sendable, Equatable {
    var messageType: String
    var id: String
    var eventType: String
    var device: String
    var smartDetectTypes: [String]
    var hasEnded: Bool

    static func parse(_ text: String) -> UnifiEventMessage? {
        guard let json = try? JSONValue.parse(Data(text.utf8)), let item = json["item"], item["modelKey"]?.string == "event" || item["modelKey"] == nil,
              let id = item["id"]?.string else { return nil }
        var types: [String] = []
        if case .array(let list)? = item["smartDetectTypes"] { types = list.compactMap(\.string) }
        var ended = false
        if let end = item["end"], end != .null { ended = true }
        return UnifiEventMessage(messageType: json["type"]?.string ?? "add", id: id, eventType: item["type"]?.string ?? "",
                                 device: item["device"]?.string ?? "", smartDetectTypes: types, hasEnded: ended)
    }
}

/// Turns the messages of one camera into signals. It remembers which signals each event turned on, because the update that ends an
/// event may not repeat its types.
struct UnifiEventTracker: Sendable {
    /// An event nobody ended turns itself off after this long (a missed update must not hold motion on).
    var maximumHold: Duration = .seconds(120)
    private var open: [String: [HoldKey]] = [:]

    init(maximumHold: Duration = .seconds(120)) {
        self.maximumHold = maximumHold
    }

    mutating func signals(for message: UnifiEventMessage) -> [EventSignal] {
        let source = "protect:\(message.id)"
        if message.eventType == "ring" {
            return message.messageType == "add" ? [.ring] : []
        }
        if message.hasEnded {
            let keys = open.removeValue(forKey: message.id) ?? [.motion]
            return keys.map { .deactivate($0, source: source) }
        }
        var keys: [HoldKey] = []
        switch message.eventType {
        case "motion", "lightMotion":
            keys = [.motion]
        case "smartDetectZone", "smartDetectLine", "smartDetectLoiterZone":
            keys = [.motion]
            for type in message.smartDetectTypes {
                let kind: DetectedObjectKind? = switch type {
                case "person": .person
                case "vehicle": .vehicle
                case "animal": .animal
                case "package": .package
                case "face": .face
                default: nil
                }
                if let kind, !keys.contains(.object(kind)) { keys.append(.object(kind)) }
            }
        default:
            return []   // sensors, audio detections and the like are not cameras' video events
        }
        var known = open[message.id] ?? []
        for key in keys where !known.contains(key) { known.append(key) }
        open[message.id] = known
        return keys.map { .activate($0, source: source, hold: maximumHold) }
    }

    /// Events that never ended; forgotten when the socket drops (the levels end with it).
    mutating func reset() { open = [:] }
}

struct UnifiEventTiming: Sendable {
    var pingInterval: Duration = .seconds(30)
    var policy = ReconnectPolicy(backoff: Backoff(), healthyAfter: .seconds(10), minimumDelayAfterFailure: .seconds(5))
    var ringDedupe: Duration = .seconds(3)
    var maximumHold: Duration = .seconds(120)
}

/// Accepts the console's self-signed certificate for the console's own address and nothing else (the same trust as the HTTP client).
private final class ConsoleTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String

    init(host: String) {
        self.host = host
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        #if !os(Linux)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host.caseInsensitiveCompare(host) == .orderedSame, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        #endif
        // FoundationNetworking has no server-trust challenges: a self-signed console certificate is not accepted there yet.
        completionHandler(.performDefaultHandling, nil)
    }
}

enum UnifiProtectEvents {
    static func makeSource(endpoint: CameraEndpoint, apiKey: String, protectCameraID: String, timing: UnifiEventTiming = UnifiEventTiming(),
                           cameraID: UUID? = nil) -> SupervisedEventSource {
        SupervisedEventSource(label: "UniFi Protect \(endpoint.host)", cameraID: cameraID, policy: timing.policy, ringDedupe: timing.ringDedupe) { context in
            try await session(endpoint: endpoint, apiKey: apiKey, protectCameraID: protectCameraID, timing: timing, context: context)
        }
    }

    static func session(endpoint: CameraEndpoint, apiKey: String, protectCameraID: String, timing: UnifiEventTiming, context: EventSessionContext) async throws {
        var secure = endpoint
        secure.useHTTPS = true
        guard let url = URL(string: "wss://\(secure.urlHost):\(secure.httpPort)\(UnifiProtectAPI.basePath)/subscribe/events") else {
            throw CameraAdapterError.invalidResponse("invalid console address")
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-API-KEY")
        let delegate = ConsoleTrustDelegate(host: endpoint.host)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        task.resume()
        // The first message (or a ping answer) proves the handshake; a 401 on the upgrade shows as a failed receive.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Self.ping(task)
                context.connected()
                while true {
                    try await Task.sleep(for: timing.pingInterval)
                    try await Self.ping(task)
                }
            }
            group.addTask {
                var tracker = UnifiEventTracker(maximumHold: timing.maximumHold)
                while true {
                    let message: URLSessionWebSocketTask.Message
                    do {
                        message = try await task.receive()
                    } catch {
                        if (task.response as? HTTPURLResponse)?.statusCode == 401 { throw CameraAdapterError.unauthorized }
                        throw error
                    }
                    let text: String
                    switch message {
                    case .string(let value): text = value
                    case .data(let data): text = String(decoding: data, as: UTF8.self)
                    @unknown default: continue
                    }
                    guard let parsed = UnifiEventMessage.parse(text), parsed.device == protectCameraID else { continue }
                    await context.apply(tracker.signals(for: parsed))
                }
            }
            defer { group.cancelAll() }
            do {
                _ = try await group.next()
            } catch {
                if (task.response as? HTTPURLResponse)?.statusCode == 401 { throw CameraAdapterError.unauthorized }
                throw error
            }
        }
    }

    private static func ping(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
