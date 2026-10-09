import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Amcrest and Dahua event stream (`/cgi-bin/eventManager.cgi?action=attach&codes=[All]&heartbeat=N`).
//
// Written from the public descriptions of Dahua's CGI HTTP API as documented by the MIT-licensed `rroller/dahua` Home Assistant
// integration and Home Assistant's docs; the framing and the event codes below are protocol facts. No code of python-amcrest (GPL)
// or of any Scrypted plugin was used.

/// One event of the stream: `Code=VideoMotion;action=Start;index=0` (+ `;data={…}`).
struct AmcrestEvent: Sendable, Equatable {
    var code: String
    /// `Start`, `Stop` or `Pulse` (other values are kept as sent).
    var action: String
    var index: Int
    /// The JSON after `data=`, when the event has one.
    var data: JSONValue?

    var isStart: Bool { action.caseInsensitiveCompare("Start") == .orderedSame }
    var isStop: Bool { action.caseInsensitiveCompare("Stop") == .orderedSame }
    var isPulse: Bool { action.caseInsensitiveCompare("Pulse") == .orderedSame }

    /// Parses `Code=…;action=…;index=…[;data=…]`; nil for anything else (a heartbeat, a header line).
    static func parse(_ text: String) -> AmcrestEvent? {
        guard text.hasPrefix("Code=") else { return nil }
        var header = text
        var data: JSONValue?
        // The JSON may contain ';' (rule names): everything after the first `;data=` is the JSON.
        if let range = text.range(of: ";data=") {
            header = String(text[..<range.lowerBound])
            let json = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            data = try? JSONValue.parse(Data(json.utf8))
        }
        var fields: [String: String] = [:]
        for pair in header.split(separator: ";") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            fields[String(pair[..<equals]).lowercased()] = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let code = fields["code"], !code.isEmpty else { return nil }
        return AmcrestEvent(code: code, action: fields["action"] ?? "Pulse", index: fields["index"].flatMap { Int($0) } ?? 0, data: data)
    }
}

/// Splits the event stream's bytes into events. It does not depend on the multipart framing (`--myboundary`, `Content-Type`,
/// `Content-Length`, blank lines): devices differ in them, and an event is recognised by its `Code=` line, whose JSON `data=`
/// may continue over several lines until its braces balance.
struct AmcrestEventStreamParser: Sendable {
    /// Output of `feed`.
    enum Item: Sendable, Equatable {
        case event(AmcrestEvent)
        case heartbeat
    }

    private var buffer = Data()
    private var pending: String?
    private var depth = 0
    private var inString = false
    private var escaped = false
    /// Bytes kept while a line is unfinished; a stream that never ends a line is cut.
    static let maximumLine = 256 * 1024

    mutating func feed(_ chunk: Data) -> [Item] {
        buffer.append(chunk)
        var items: [Item] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = Data(buffer[buffer.index(after: newline)...])
            handle(line, into: &items)
        }
        if buffer.count > Self.maximumLine {
            buffer = Data()
            pending = nil
            depth = 0
        }
        return items
    }

    private mutating func handle(_ line: String, into items: inout [Item]) {
        if pending != nil {
            pending! += "\n" + line
            scan(line)
            if depth <= 0 { finishPending(into: &items) }
            return
        }
        if line.hasPrefix("Code=") {
            pending = line
            depth = 0
            inString = false
            escaped = false
            if let range = line.range(of: ";data=") {
                scan(String(line[range.upperBound...]))
                if depth > 0 { return }   // the JSON continues on the next lines
            }
            finishPending(into: &items)
        } else if line == "Heartbeat" || line.hasPrefix("Heartbeat") {
            items.append(.heartbeat)
        }
        // Boundary lines, part headers and blank lines are ignored.
    }

    private mutating func finishPending(into items: inout [Item]) {
        defer {
            pending = nil
            depth = 0
        }
        if let text = pending, let event = AmcrestEvent.parse(text) { items.append(.event(event)) }
    }

    /// Tracks the braces of the JSON outside of strings.
    private mutating func scan(_ text: String) {
        for character in text {
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            default: break
            }
        }
    }
}

/// Event codes → signals. Motion pulses are held `pulseHold` after the last one; `Start`/`Stop` events are levels (ended by the
/// stop, or when the channel drops).
enum AmcrestEventMapper {
    /// Doorbell codes: Amcrest AD110/AD410 and Dahua door stations announce a press as `CallNoAnswered` or `PhoneCallDetect`, the
    /// Amcrest talk-flow as `_DoTalkAction_` with `Action: Invite`, a Dahua VTO's button light as `BackKeyLight` with state 1 or 2.
    static func signals(for event: AmcrestEvent, pulseHold: Duration) -> [EventSignal] {
        let code = event.code
        func hold(_ event: AmcrestEvent) -> Duration? { event.isPulse ? pulseHold : nil }
        func level(_ key: HoldKey, _ source: String) -> [EventSignal] {
            if event.isStop { return [.deactivate(key, source: source)] }
            return [.activate(key, source: source, hold: event.isPulse ? pulseHold : nil)]
        }
        switch code {
        case "VideoMotion", "MDResult":
            return level(.motion, code)
        case "SmartMotionHuman":
            return event.isStop ? [.deactivate(.object(.person), source: code), .deactivate(.motion, source: code)]
                : [.activate(.object(.person), source: code, hold: hold(event)), .activate(.motion, source: code, hold: hold(event))]
        case "SmartMotionVehicle":
            return event.isStop ? [.deactivate(.object(.vehicle), source: code), .deactivate(.motion, source: code)]
                : [.activate(.object(.vehicle), source: code, hold: hold(event)), .activate(.motion, source: code, hold: hold(event))]
        case "CrossLineDetection", "CrossRegionDetection", "LeftDetection", "TakenAwayDetection", "WanderDetection", "MoveDetection",
             "ParkingDetection", "RioterDetection", "CrowdDetection":
            return ivs(event, pulseHold: pulseHold)
        case "FaceDetection", "HumanTrait":
            return event.isStop ? [.deactivate(.object(.face), source: code), .deactivate(.motion, source: code)]
                : [.activate(.object(.face), source: code, hold: hold(event) ?? pulseHold), .activate(.motion, source: code, hold: hold(event) ?? pulseHold)]
        case "VideoBlind", "VideoUnFocus", "VideoAbnormalDetection":
            return level(.tamper, code)
        case "AudioMutation", "AudioAnomaly", "AudioIntensity":
            return level(.audioAlarm, code)
        case "AlarmLocal":
            return level(.digitalInput(String(event.index + 1)), code)
        case "CallNoAnswered", "PhoneCallDetect":
            return event.isStop ? [] : [.ring]
        case "_DoTalkAction_":
            let action = event.data?["Action"]?.string ?? ""
            return action.caseInsensitiveCompare("Invite") == .orderedSame ? [.ring] : []
        case "BackKeyLight":
            let state = event.data?["State"]?.int ?? event.data?["Data"]?["State"]?.int
            return state == 1 || state == 2 ? [.ring] : []
        default:
            return []
        }
    }

    /// An IVS rule: motion, plus the kind of object when the event says (`Object.ObjectType`: Human, Vehicle).
    private static func ivs(_ event: AmcrestEvent, pulseHold: Duration) -> [EventSignal] {
        let source = event.code
        if event.isStop { return [.deactivate(.motion, source: source), .deactivate(.object(.person), source: source), .deactivate(.object(.vehicle), source: source)] }
        let duration = event.isPulse ? pulseHold : nil
        var signals: [EventSignal] = [.activate(.motion, source: source, hold: duration ?? pulseHold)]
        let type = (event.data?["Object"]?["ObjectType"]?.string ?? event.data?["ObjectType"]?.string ?? "").lowercased()
        switch type {
        case "human", "person": signals.append(.activate(.object(.person), source: source, hold: duration ?? pulseHold))
        case "vehicle", "car", "motor vehicle", "nonmotor vehicle": signals.append(.activate(.object(.vehicle), source: source, hold: duration ?? pulseHold))
        default: break
        }
        return signals
    }
}

struct AmcrestEventTiming: Sendable {
    var pulseHold: Duration = .seconds(20)
    /// The camera sends a heartbeat every `heartbeat` seconds; nothing at all for this long restarts the stream.
    var idleTimeout: Duration = .seconds(60)
    var heartbeat = 5
    var policy = ReconnectPolicy(backoff: Backoff(), healthyAfter: .seconds(10), minimumDelayAfterFailure: .seconds(5))
    var ringDedupe: Duration = .seconds(3)
}

private struct AmcrestIdleTimeout: Error, CustomStringConvertible {
    var description: String { "event stream idle timeout" }
}

enum AmcrestEvents {
    static func makeSource(endpoint: CameraEndpoint, credentials: HTTPCredentials?, transport: any NetworkTransport,
                           timing: AmcrestEventTiming = AmcrestEventTiming(), cameraID: UUID? = nil) -> SupervisedEventSource {
        SupervisedEventSource(label: "Amcrest \(endpoint.host)", cameraID: cameraID, policy: timing.policy, ringDedupe: timing.ringDedupe) { context in
            try await session(endpoint: endpoint, credentials: credentials, transport: transport, timing: timing, context: context)
        }
    }

    /// One connection: attach to every event code, map each event until the stream ends or goes quiet.
    static func session(endpoint: CameraEndpoint, credentials: HTTPCredentials?, transport: any NetworkTransport, timing: AmcrestEventTiming,
                        context: EventSessionContext) async throws {
        // A rejected login pauses every login to this camera (`ONVIFLoginGuard`): a camera locks the account after a few failures.
        let loginKey = AmcrestAPI.loginKey(endpoint)
        if credentials != nil, let until = ONVIFLoginGuard.shared.blockedUntil(host: loginKey) { throw CameraAdapterError.lockedOut(until: until) }
        let stream = try await AmcrestAPI.eventStream(endpoint: endpoint, credentials: credentials, heartbeat: timing.heartbeat,
                                                      readTimeout: timing.idleTimeout + .seconds(30), transport: transport)
        defer { stream.close() }
        let body = stream.body
        switch stream.status {
        case 200: break
        case 401:
            ONVIFLoginGuard.shared.recordRejection(host: loginKey)
            throw CameraAdapterError.unauthorized
        case 403:
            throw CameraAdapterError.unsupported("this account may not read events")
        default: throw CameraAdapterError.httpStatus(stream.status)
        }
        context.connected()
        let lastActivity = LockedValue(ContinuousClock.now)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var parser = AmcrestEventStreamParser()
                for try await chunk in body {
                    lastActivity.set(.now)
                    for item in parser.feed(chunk) {
                        guard case .event(let event) = item else { continue }
                        await context.apply(AmcrestEventMapper.signals(for: event, pulseHold: timing.pulseHold))
                    }
                }
            }
            group.addTask {
                let interval = max(min(timing.idleTimeout / 4, .seconds(5)), .milliseconds(10))
                while true {
                    try await Task.sleep(for: interval)
                    if ContinuousClock.now - lastActivity.value >= timing.idleTimeout { throw AmcrestIdleTimeout() }
                }
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
