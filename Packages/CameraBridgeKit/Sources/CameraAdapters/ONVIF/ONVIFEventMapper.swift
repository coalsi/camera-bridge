import Foundation

/// One `wsnt:NotificationMessage` from a PullMessages response (ONVIF Core §9).
struct ONVIFNotification: Sendable, Equatable {
    /// Topic path with namespace prefixes removed, e.g. `RuleEngine/CellMotionDetector/Motion`.
    var topic: String
    /// `Initialized`, `Changed` or `Deleted` (nil when absent).
    var propertyOperation: String?
    /// `tt:Source` simple items (name → value).
    var source: [String: String]
    /// `tt:Data` simple items (name → value).
    var data: [String: String]

    static func parse(pullMessagesResponse envelope: XMLTree) -> [ONVIFNotification] {
        envelope.descendants("NotificationMessage").compactMap { message in
            guard let topicText = message.child("Topic")?.text, !topicText.isEmpty else { return nil }
            let outer = message.child("Message")
            let inner = outer?.child("Message") ?? outer?.firstDescendant("Message") ?? outer
            func items(_ container: String) -> [String: String] {
                var result: [String: String] = [:]
                for item in inner?.child(container)?.children("SimpleItem") ?? [] {
                    if let name = item.attribute("Name") { result[name] = item.attribute("Value") ?? "" }
                }
                return result
            }
            return ONVIFNotification(topic: cleanTopic(topicText), propertyOperation: inner?.attribute("PropertyOperation"),
                                     source: items("Source"), data: items("Data"))
        }
    }

    /// Removes namespace prefixes from each path component and trailing `/`, `//.` decorations.
    static func cleanTopic(_ topic: String) -> String {
        var text = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") || text.hasSuffix("/.") || text.hasSuffix(".") {
            text.removeLast()
        }
        return text.split(separator: "/", omittingEmptySubsequences: true)
            .map { component in component.split(separator: ":").last.map(String.init) ?? String(component) }
            .joined(separator: "/")
    }

    /// The boolean state carried in `Data` (preferred names first, then any boolean-looking item).
    var booleanState: Bool? {
        for name in ["State", "IsMotion", "LogicalState", "IsSoundDetected", "IsInside", "IsTamper", "Value"] {
            if let value = data[name], let parsed = ONVIFNotification.parseBool(value) { return parsed }
        }
        for key in data.keys.sorted() {
            if let value = data[key], let parsed = ONVIFNotification.parseBool(value) { return parsed }
        }
        return nil
    }

    static func parseBool(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1", "on", "active", "yes": true
        case "false", "0", "off", "inactive", "no": false
        default: nil
        }
    }
}

/// One subscription's ONVIF mapping (`ONVIFPullPoint` keeps one per subscription): `ONVIFEventMapper.signals`, whose
/// states are keyed per property instance, plus the instances this subscription turned on, so that a stop whose Source
/// items differ from its start's still ends it.
///
/// A stop ends every instance of its topic (and key) whose Source items do not contradict its own — no item both carry
/// has different values. So a stop with fewer items than its start (or none), or a start without items, still ends the
/// state, which would otherwise stay on until the channel drops; while two video sources, rules or detecting services
/// (different values, or different topics) stay separate OR inputs.
struct ONVIFEventMapping: Sendable {
    /// Instances remembered per topic and key; the oldest is forgotten beyond this (it still ends on its exact stop).
    static let maximumInstancesPerTopic = 16

    private struct Family: Hashable {
        var key: HoldKey
        var topic: String
    }

    private struct Instance {
        var source: String
        var items: [String: String]
    }

    private var active: [Family: [Instance]] = [:]

    mutating func signals(for notification: ONVIFNotification, pulseHold: Duration) -> [EventSignal] {
        let instance = ONVIFEventMapper.instanceSource(notification)
        let items = ONVIFEventMapper.instanceItems(notification)
        return ONVIFEventMapper.signals(for: notification, pulseHold: pulseHold).flatMap { signal -> [EventSignal] in
            switch signal {
            case .activate(let key, let source, _) where source == instance:
                let family = Family(key: key, topic: notification.topic)
                var instances = active[family] ?? []
                if !instances.contains(where: { $0.source == source }) {
                    if instances.count >= Self.maximumInstancesPerTopic { instances.removeFirst() }
                    instances.append(Instance(source: source, items: items))
                }
                active[family] = instances
                return [signal]
            case .deactivate(let key, let source) where source == instance:
                let family = Family(key: key, topic: notification.topic)
                let instances = active[family] ?? []
                let ended = instances.filter { Self.compatible($0.items, items) }.map(\.source)
                let remaining = instances.filter { !Self.compatible($0.items, items) }
                active[family] = remaining.isEmpty ? nil : remaining
                return ([source] + ended.filter { $0 != source }).map { .deactivate(key, source: $0) }
            default:
                return [signal]
            }
        }
    }

    /// Two Source item sets can name the same property instance: no item both carry has different values.
    static func compatible(_ a: [String: String], _ b: [String: String]) -> Bool {
        a.allSatisfy { name, value in b[name].map { $0 == value } ?? true }
    }
}

/// Maps ONVIF event topics to camera signals (ONVIF Core/Analytics/Imaging/DeviceIO topics, Reolink `MyRuleDetector`,
/// Mobotix `VideoSource/Alarm` ring). Object detections also pulse motion so HKSV records them.
///
/// Level and pulse states with a stop are keyed per property instance (`instanceSource`: the full topic plus the
/// Source items), so each detecting service (Imaging §5.5.1 defines `…/ImageTooDark/ImagingService`,
/// `…/AnalyticsService` and `…/RecordingService` separately), video source and rule is its own OR input: one
/// instance's stop (or its `Initialized` false after subscribing) does not end another's state. `ONVIFEventMapping`
/// ends instances whose stop carries different Source items than their start.
enum ONVIFEventMapper {
    static let tamperTopics = ["GlobalSceneChange", "ImageTooDark", "ImageTooBlurry", "ImageTooBright", "SignalLoss"]
    /// Bounds on the Source items an instance key takes (camera-reported; they become hold-state keys).
    static let maximumInstanceItems = 8
    static let maximumInstanceItemLength = 64

    /// The Source items that identify a notification's property instance: at most `maximumInstanceItems` (by name), each
    /// name and value cut to `maximumInstanceItemLength` characters.
    static func instanceItems(_ notification: ONVIFNotification) -> [String: String] {
        var items: [String: String] = [:]
        for (name, value) in notification.source.sorted(by: { $0.key < $1.key }).prefix(maximumInstanceItems) {
            items[String(name.prefix(maximumInstanceItemLength))] = String(value.prefix(maximumInstanceItemLength))
        }
        return items
    }

    /// The hold source of a notification's property instance: `topic|name=value|…` (items sorted by name), e.g.
    /// `VideoSource/MotionAlarm|Source=VS_1`.
    static func instanceSource(_ notification: ONVIFNotification) -> String {
        ([notification.topic] + instanceItems(notification).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: "|")
    }

    static func signals(for notification: ONVIFNotification, pulseHold: Duration) -> [EventSignal] {
        let components = notification.topic.split(separator: "/").map(String.init)
        let lower = notification.topic.lowercased()
        let leaf = components.last ?? ""
        let state = notification.booleanState
        let instance = instanceSource(notification)

        // States with a stop are keyed per property instance (`instanceSource`).
        func level(_ key: HoldKey) -> [EventSignal] {
            guard let state else { return [] }
            return state ? [.activate(key, source: instance, hold: nil)] : [.deactivate(key, source: instance)]
        }
        func pulse(_ key: HoldKey) -> [EventSignal] {
            guard let state else { return [] }
            return state ? [.activate(key, source: instance, hold: pulseHold)] : [.deactivate(key, source: instance)]
        }

        if leaf.caseInsensitiveCompare("Visitor") == .orderedSame {
            // A press is a Changed → true; Initialized reports the current state after (re)subscribing.
            return state == true && notification.propertyOperation?.caseInsensitiveCompare("Initialized") != .orderedSame ? [.ring] : []
        }
        if lower.contains("myruledetector/") {
            if let kind = detectorKind(leaf) { return level(.object(kind)) + level(.motion) }
            if leaf.localizedCaseInsensitiveContains("motion") { return level(.motion) }
            return []
        }
        if lower.contains("videosource/motionalarm") { return level(.motion) }
        if lower.contains("cellmotiondetector/motion") { return pulse(.motion) }
        if lower.contains("ruleengine/objectdetection") || lower.contains("ruleengine/objectdetector") {
            if state == false { return [] }
            let classes = notification.data["ClassTypes"] ?? notification.data["ClassType"] ?? notification.data["Type"] ?? ""
            let kinds = objectKinds(classes)
            guard !kinds.isEmpty else { return [] }
            return kinds.map { .activate(.object($0), source: "ObjectDetection", hold: pulseHold) }
                + [.activate(.motion, source: "ObjectDetection", hold: pulseHold)]
        }
        if lower.contains("fielddetector/objectsinside") { return pulse(.motion) }
        if lower.contains("linedetector/crossed") { return [.activate(.motion, source: "LineDetector", hold: pulseHold)] }
        if components.contains(where: { component in tamperTopics.contains { $0.caseInsensitiveCompare(component) == .orderedSame } }) {
            return level(.tamper)
        }
        if lower.contains("device/trigger/digitalinput") {
            let id = notification.source["InputToken"] ?? notification.source.sorted { $0.key < $1.key }.first?.value ?? "1"
            return level(.digitalInput(id))
        }
        if lower.contains("audioanalytics/audio/detectedsound") { return level(.audioAlarm) }
        if components.count >= 2, leaf.caseInsensitiveCompare("Alarm") == .orderedSame,
           components.contains(where: { $0.caseInsensitiveCompare("VideoSource") == .orderedSame }) {
            let rang = notification.data.values.contains { $0 == "Ring" || $0 == "CameraBellButton" }
            return rang ? [.ring] : []
        }
        return []
    }

    static func detectorKind(_ leaf: String) -> DetectedObjectKind? {
        let lower = leaf.lowercased()
        if lower.contains("people") || lower.contains("person") { return .person }
        if lower.contains("vehicle") { return .vehicle }
        if lower.contains("dogcat") || lower.contains("animal") || lower.contains("pet") { return .animal }
        if lower.contains("face") { return .face }
        if lower.contains("package") { return .package }
        return nil
    }

    /// `ClassTypes` tokens (space/comma separated) → kinds, in order of appearance, without duplicates.
    static func objectKinds(_ classTypes: String) -> [DetectedObjectKind] {
        var kinds: [DetectedObjectKind] = []
        for token in classTypes.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" }) {
            let kind: DetectedObjectKind?
            switch token.lowercased() {
            case "human", "person", "people", "pedestrian": kind = .person
            case "face": kind = .face
            case "vehicle", "car", "truck", "bus", "bike", "bicycle", "motorcycle", "motorbike", "licenseplate": kind = .vehicle
            case "animal", "dog", "cat", "dogcat", "dog_cat", "pet", "bird": kind = .animal
            case "package", "parcel": kind = .package
            default: kind = nil
            }
            if let kind, !kinds.contains(kind) { kinds.append(kind) }
        }
        return kinds
    }

    /// Topic paths (prefixes stripped) declared in a `GetEventPropertiesResponse` TopicSet.
    static func topics(inEventProperties envelope: XMLTree) -> Set<String> {
        guard let topicSet = envelope.firstDescendant("TopicSet") else { return [] }
        var result: Set<String> = []
        func walk(_ node: XMLTree, path: [String]) {
            for child in node.children where !child.matches("MessageDescription") {
                let childPath = path + [child.name]
                if child.attribute("topic") == "true" || child.child("MessageDescription") != nil {
                    result.insert(childPath.joined(separator: "/"))
                }
                walk(child, path: childPath)
            }
        }
        walk(topicSet, path: [])
        return result
    }

    /// Capability kinds implied by a topic set.
    static func eventKinds(forTopics topics: Set<String>) -> Set<CameraEventKind> {
        var kinds: Set<CameraEventKind> = []
        for topic in topics {
            let lower = topic.lowercased()
            let leaf = topic.split(separator: "/").last.map(String.init) ?? topic
            if leaf.caseInsensitiveCompare("Visitor") == .orderedSame { kinds.insert(.doorbell); continue }
            if lower.contains("motionalarm") || lower.contains("cellmotiondetector") || lower.contains("fielddetector")
                || lower.contains("linedetector") { kinds.insert(.motion) }
            if lower.contains("ruleengine/objectdetect") { kinds.formUnion([.motion, .person, .vehicle, .animal]) }
            if lower.contains("myruledetector/"), let kind = detectorKind(leaf) {
                kinds.insert(.motion)
                switch kind {
                case .person: kinds.insert(.person)
                case .vehicle: kinds.insert(.vehicle)
                case .animal: kinds.insert(.animal)
                case .face: kinds.insert(.face)
                case .package: kinds.insert(.package)
                }
            }
            if tamperTopics.contains(where: { lower.contains($0.lowercased()) }) { kinds.insert(.tamper) }
            if lower.contains("device/trigger/digitalinput") { kinds.insert(.digitalInput) }
            if lower.contains("audioanalytics/audio/detectedsound") { kinds.insert(.audioAlarm) }
        }
        return kinds
    }
}
