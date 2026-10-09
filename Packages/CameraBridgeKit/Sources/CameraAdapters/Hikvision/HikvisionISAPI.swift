import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MediaCore

struct HikvisionDeviceInfo: Sendable, Equatable {
    var deviceName: String
    var model: String
    var serialNumber: String
    var firmware: String
    var macAddress: String
    var deviceType: String
}

struct HikvisionStreamingChannel: Sendable, Equatable {
    var id: String
    var videoCodec: VideoCodec?
    var width: Int?
    var height: Int?
    var fps: Double?
    var audioCodec: AudioCodec?
    var audioSampleRate: Int?

    func streamInfo(url: URL) -> StreamInfo {
        StreamInfo(url: url, videoCodec: videoCodec, width: width, height: height, fps: fps, audioCodec: audioCodec,
                   audioSampleRate: audioCodec == nil ? nil : audioSampleRate, audioChannels: audioCodec == nil ? nil : 1)
    }
}

struct HikvisionTwoWayChannel: Sendable, Equatable {
    var id: String
    var codec: AudioCodec?
    /// `audioCompressionType` as reported (also when `codec` cannot represent it, e.g. `G.726`); nil when absent.
    var compression: String?
}

/// ISAPI XML documents (namespace-agnostic: `hikvision.com/ver10|ver20` and `isapi.org/ver20` both occur).
enum HikvisionXML {
    static func deviceInfo(_ tree: XMLTree) throws -> HikvisionDeviceInfo {
        guard tree.matches("DeviceInfo") else { throw CameraAdapterError.invalidResponse("not an ISAPI DeviceInfo document") }
        let firmware = [tree.string("firmwareVersion"), tree.string("firmwareReleasedDate")].compactMap { $0 }.filter { !$0.isEmpty }
        return HikvisionDeviceInfo(deviceName: tree.string("deviceName") ?? "", model: tree.string("model") ?? "",
                                   serialNumber: tree.string("serialNumber") ?? "", firmware: firmware.joined(separator: " "),
                                   macAddress: tree.string("macAddress") ?? "", deviceType: tree.string("deviceType") ?? "")
    }

    static func audioCodec(_ compression: String?) -> AudioCodec? {
        switch compression?.lowercased() {
        case "g.711ulaw", "g711ulaw", "g.711u": .pcmu
        case "g.711alaw", "g711alaw", "g.711a": .pcma
        case "aac", "mpeg2-aac", "aac-lc": .aac
        default: nil
        }
    }

    static func streamingChannels(_ tree: XMLTree) -> [HikvisionStreamingChannel] {
        let channels = tree.matches("StreamingChannel") ? [tree] : tree.children("StreamingChannel")
        return channels.compactMap { channel in
            guard let id = channel.string("id"), !id.isEmpty else { return nil }
            let video = channel.child("Video")
            let videoCodec: VideoCodec? = switch video?.string("videoCodecType")?.uppercased() {
            case "H.264", "H264": .h264
            case "H.265", "H265", "HEVC": .hevc
            default: nil
            }
            let audio = channel.child("Audio")
            let audioEnabled = audio?.string("enabled").flatMap(ONVIFNotification.parseBool) ?? false
            let audioCodec = audioEnabled ? Self.audioCodec(audio?.string("audioCompressionType")) : nil
            // Camera-reported numbers are sanitized (NaN, ∞ or huge values must not trap).
            let g711Rate = audioCodec == .pcmu || audioCodec == .pcma ? 8000 : nil
            let sampleRate = CameraNumbers.sampleRate(audio?.string("audioSamplingRate")) ?? g711Rate
            return HikvisionStreamingChannel(id: id, videoCodec: videoCodec, width: CameraNumbers.dimension(video?.string("videoResolutionWidth")),
                                             height: CameraNumbers.dimension(video?.string("videoResolutionHeight")),
                                             fps: CameraNumbers.frameRate(video?.string("maxFrameRate").flatMap(Double.init).map { $0 / 100 }),
                                             audioCodec: audioCodec, audioSampleRate: sampleRate)
        }
    }

    /// Event capabilities from `/ISAPI/Event/triggers`: only triggers that notify the surveillance center (`center`)
    /// reach the alertStream; a trigger without a notification list is assumed to. Motion (VMD) is always present.
    static func triggerKinds(_ tree: XMLTree) -> Set<CameraEventKind> {
        var kinds: Set<CameraEventKind> = [.motion]
        for trigger in tree.descendants("EventTrigger") {
            let methods = trigger.descendants("notificationMethod").map { $0.text.lowercased() }
            let listed = trigger.child("EventTriggerNotificationList") != nil
            guard !listed || methods.contains("center") else { continue }
            switch trigger.string("eventType")?.lowercased() {
            case "vmd", "pir": kinds.insert(.motion)
            case "fielddetection", "linedetection", "regionentrance", "regionexiting": kinds.formUnion([.person, .vehicle])
            case "tamperdetection", "shelteralarm", "defocus", "scenechangedetection": kinds.insert(.tamper)
            case "io": kinds.insert(.digitalInput)
            case "audioexception": kinds.insert(.audioAlarm)
            default: break
            }
        }
        return kinds
    }

    static func twoWayAudioChannels(_ tree: XMLTree) -> [HikvisionTwoWayChannel] {
        let channels = tree.matches("TwoWayAudioChannel") ? [tree] : tree.descendants("TwoWayAudioChannel")
        return channels.compactMap { channel in
            guard let id = channel.string("id") else { return nil }
            let compression = channel.string("audioCompressionType")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return HikvisionTwoWayChannel(id: id, codec: audioCodec(compression), compression: compression)
        }
    }
}

/// ISAPI over `AuthenticatingHTTPClient` (Digest).
struct HikvisionISAPI: Sendable {
    let endpoint: CameraEndpoint
    let credentials: HTTPCredentials?
    let http: AuthenticatingHTTPClient

    init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, timeout: Duration = .seconds(10)) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.http = AuthenticatingHTTPClient(credentials: credentials, timeout: timeout)
    }

    func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let url = endpoint.httpURL(path: path, query: query) else { throw CameraAdapterError.invalidResponse("invalid camera address") }
        return url
    }

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await CameraHTTP.send(http, CameraHTTP.request(url(path, query: query))).0
    }

    func put(_ path: String, body: Data? = nil) async throws -> Data {
        try await CameraHTTP.send(http, CameraHTTP.request(url(path), method: "PUT", body: body,
                                                          contentType: body == nil ? nil : "application/xml")).0
    }

    func xml(_ path: String) async throws -> XMLTree {
        do { return try XMLTree.parse(try await get(path)) } catch let error as XMLTreeError {
            throw CameraAdapterError.invalidResponse("\(path): \(error)")
        }
    }

    func deviceInfo() async throws -> HikvisionDeviceInfo {
        try HikvisionXML.deviceInfo(try await xml("/ISAPI/System/deviceInfo"))
    }

    func streamingChannels() async throws -> [HikvisionStreamingChannel] {
        HikvisionXML.streamingChannels(try await xml("/ISAPI/Streaming/channels"))
    }

    func triggerKinds() async throws -> Set<CameraEventKind> {
        HikvisionXML.triggerKinds(try await xml("/ISAPI/Event/triggers"))
    }

    func twoWayAudioChannels() async throws -> [HikvisionTwoWayChannel] {
        HikvisionXML.twoWayAudioChannels(try await xml("/ISAPI/System/TwoWayAudio/channels"))
    }

    /// Asks channel `channelID` for a keyframe (`PUT /ISAPI/Streaming/channels/<id>/requestKeyFrame`, no body). One request; the
    /// caller (`CameraDriver.requestKeyframe`) guards it.
    func requestKeyFrame(channelID: String) async throws {
        _ = try await put("/ISAPI/Streaming/channels/\(channelID)/requestKeyFrame")
    }

    func snapshot(channelID: String) async throws -> Data {
        try await get("/ISAPI/Streaming/channels/\(channelID)/picture", query: [URLQueryItem(name: "snapShotImageType", value: "JPEG")])
    }

    /// Whether channel `channelID`'s "H.264+"/"H.265+" smart codec (`SmartCodec/enabled` inside the channel's own
    /// `/ISAPI/Streaming/channels/<id>` document) is on; nil when the camera's document has no `SmartCodec` element
    /// (older/other models: nothing to disable).
    func smartCodecEnabled(channelID: String) async throws -> Bool? {
        let xml = try await xml("/ISAPI/Streaming/channels/\(channelID)")
        guard let enabled = xml.child("Video")?.child("SmartCodec")?.string("enabled") else { return nil }
        return ONVIFNotification.parseBool(enabled)
    }

    /// Reads `/ISAPI/Streaming/channels/<channelID>`, flips `Video/SmartCodec/enabled` to `enabled`, and writes the
    /// whole document back (ISAPI's `PUT` on this resource replaces the configuration, so the read-modify-write keeps
    /// everything else the channel already had). Does nothing (no PUT) if the camera's document has no `SmartCodec`
    /// element to flip.
    func setSmartCodecEnabled(_ enabled: Bool, channelID: String) async throws {
        let path = "/ISAPI/Streaming/channels/\(channelID)"
        let raw = try await get(path)
        guard let document = String(data: raw, encoding: .utf8) else {
            throw CameraAdapterError.invalidResponse("\(path): not UTF-8 XML")
        }
        guard let replaced = Self.replacingSmartCodecEnabled(in: document, enabled: enabled) else {
            // No <SmartCodec><enabled>…</enabled></SmartCodec> in this channel's document: nothing to change.
            return
        }
        guard let body = replaced.data(using: .utf8) else {
            throw CameraAdapterError.invalidResponse("\(path): could not re-encode XML")
        }
        _ = try await put(path, body: body)
    }

    /// Channel `channelID`'s codec (`videoCodecType`), frame rate (`maxFrameRate` is in hundredths) and keyframe
    /// interval in frames (`GovLength`), from `/ISAPI/Streaming/channels/<id>`.
    func encoderSettings(channelID: String) async throws -> (codec: String?, fps: Double?, govLength: Int?) {
        let video = try await xml("/ISAPI/Streaming/channels/\(channelID)").child("Video")
        let fps = video?.string("maxFrameRate").flatMap { Double($0) }.map { $0 / 100 }
        return (video?.string("videoCodecType"), fps, video?.string("GovLength").flatMap { Int($0) })
    }

    /// Sets channel `channelID`'s `GovLength` (keyframe interval, in frames) by read-modify-write of its channel
    /// document, leaving every other setting as the camera had it. More reliable on Hikvision than ONVIF's
    /// `SetVideoEncoderConfiguration`, which many firmwares reject (`InvalidArgVal`) for values they show as allowed.
    func setGovLength(_ frames: Int, channelID: String) async throws {
        let path = "/ISAPI/Streaming/channels/\(channelID)"
        guard let document = String(data: try await get(path), encoding: .utf8) else {
            throw CameraAdapterError.invalidResponse("\(path): not UTF-8 XML")
        }
        guard let replaced = Self.replacingElement("GovLength", in: document, with: String(frames)),
              let body = replaced.data(using: .utf8) else {
            throw CameraAdapterError.unsupported("This camera's stream settings have no keyframe interval to change")
        }
        _ = try await put(path, body: body)
    }

    /// The video values of `/ISAPI/Streaming/channels/<channelID>`, with the document text they were read from.
    func encoderValues(channelID: String) async throws -> (document: String, values: EncoderValues) {
        let path = "/ISAPI/Streaming/channels/\(channelID)"
        let raw = try await get(path)
        guard let document = String(data: raw, encoding: .utf8) else { throw CameraAdapterError.invalidResponse("\(path): not UTF-8 XML") }
        do { return (document, Self.encoderValues(try XMLTree.parse(raw))) } catch let error as XMLTreeError {
            throw CameraAdapterError.invalidResponse("\(path): \(error)")
        }
    }

    /// Codec, size, frame rate (`maxFrameRate` is in hundredths), bit rate (`constantBitRate`, else `vbrUpperCap`),
    /// keyframe interval and H.264 profile of a channel document.
    static func encoderValues(_ tree: XMLTree) -> EncoderValues {
        let video = tree.matches("Video") ? tree : tree.child("Video")
        return EncoderValues(
            codec: video?.string("videoCodecType").map(EncoderValues.normalizedCodec),
            width: CameraNumbers.dimension(video?.string("videoResolutionWidth")), height: CameraNumbers.dimension(video?.string("videoResolutionHeight")),
            frameRate: video?.string("maxFrameRate").flatMap { Double($0) }.map { $0 / 100 },
            bitrate: (video?.string("constantBitRate") ?? video?.string("vbrUpperCap")).flatMap { Int($0) },
            govLength: video?.string("GovLength").flatMap { Int($0) }, h264Profile: video?.string("H264Profile"))
    }

    /// `document` with `changes` written into its elements, or nil when a changed field has no element in it (the
    /// camera does not expose that setting here). Text-level, like `setGovLength`: every other element is untouched.
    static func applying(_ changes: EncoderValues, to document: String) -> String? {
        var result = document
        func replace(_ name: String, _ value: String?) -> Bool {
            guard let value else { return true }
            guard let edited = replacingElement(name, in: result, with: value) else { return false }
            result = edited
            return true
        }
        let codec: String? = switch changes.codec {
        case "H264": "H.264"
        case "H265": "H.265"
        case let other: other
        }
        // A variable-rate channel caps its bit rate with `vbrUpperCap`; a constant-rate one sets `constantBitRate`.
        let usesVBR = document.range(of: "<videoQualityControlType>VBR<", options: .caseInsensitive) != nil
        let bitrateElement = usesVBR && document.range(of: "<vbrUpperCap", options: .caseInsensitive) != nil ? "vbrUpperCap" : "constantBitRate"
        guard replace("videoCodecType", codec), replace("videoResolutionWidth", changes.width.map(String.init)),
              replace("videoResolutionHeight", changes.height.map(String.init)),
              replace("maxFrameRate", changes.frameRate.map { String(Int(($0 * 100).rounded())) }),
              replace(bitrateElement, changes.bitrate.map(String.init)), replace("GovLength", changes.govLength.map(String.init)),
              replace("H264Profile", changes.h264Profile) else { return nil }
        return result
    }

    /// Reads a channel's document, writes `changes` into it and PUTs the whole document back.
    func setEncoderValues(_ changes: EncoderValues, channelID: String) async throws {
        let path = "/ISAPI/Streaming/channels/\(channelID)"
        let (document, _) = try await encoderValues(channelID: channelID)
        guard let edited = Self.applying(changes, to: document), let body = edited.data(using: .utf8) else {
            throw CameraAdapterError.unsupported("This camera's stream settings don't list every setting to change")
        }
        _ = try await put(path, body: body)
    }

    /// Replaces the text of the first `<name>…</name>` element (any attributes) in `document`; nil when absent.
    static func replacingElement(_ name: String, in document: String, with value: String) -> String? {
        guard let open = document.range(of: "<\(name)", options: .caseInsensitive),
              let tagEnd = document.range(of: ">", range: open.upperBound..<document.endIndex),
              let close = document.range(of: "</\(name)>", options: .caseInsensitive, range: tagEnd.upperBound..<document.endIndex)
        else { return nil }
        var result = document
        result.replaceSubrange(tagEnd.upperBound..<close.lowerBound, with: value)
        return result
    }

    /// Text-level read-modify-write of `<SmartCodec><enabled>…</enabled></SmartCodec>` (any whitespace/attributes
    /// between tags), rather than parsing/rebuilding the whole ISAPI document — `XMLTree` has no serializer that
    /// round-trips every sibling element some firmwares include, and ISAPI `PUT` expects the camera's own document
    /// shape back unchanged apart from the field being edited. Returns nil (no substitution made) when the pattern
    /// isn't found, so the caller can skip the PUT instead of sending a document that didn't actually change.
    static func replacingSmartCodecEnabled(in document: String, enabled: Bool) -> String? {
        guard let smartCodecRange = document.range(of: "<SmartCodec", options: .caseInsensitive) else { return nil }
        guard let closeRange = document.range(of: "</SmartCodec>", options: .caseInsensitive, range: smartCodecRange.lowerBound..<document.endIndex) else {
            return nil
        }
        let section = document[smartCodecRange.lowerBound..<closeRange.upperBound]
        guard let enabledOpen = section.range(of: "<enabled", options: .caseInsensitive) else { return nil }
        guard let enabledTagEnd = section.range(of: ">", range: enabledOpen.upperBound..<section.endIndex) else { return nil }
        guard let enabledClose = section.range(of: "</enabled>", options: .caseInsensitive, range: enabledTagEnd.upperBound..<section.endIndex) else {
            return nil
        }
        var newSection = section
        newSection.replaceSubrange(enabledTagEnd.upperBound..<enabledClose.lowerBound, with: enabled ? "true" : "false")
        var result = document
        result.replaceSubrange(smartCodecRange.lowerBound..<closeRange.upperBound, with: newSection)
        return result
    }

    // MARK: On-screen display (the camera's own date/time overlay)

    /// `/ISAPI/System/Video/inputs/channels/<n>/overlays`: the video input's on-screen display document. The input
    /// number is the channel id's hundreds (`101` and `102` are input 1's main and sub stream).
    static func overlaysPath(inputChannel: Int) -> String { "/ISAPI/System/Video/inputs/channels/\(inputChannel)/overlays" }

    /// The video input a streaming channel id belongs to ("101" → 1, "402" → 4; a bare "1" → 1).
    static func inputChannel(streamingChannelID id: String) -> Int {
        guard let number = Int(id), number > 0 else { return 1 }
        return number >= 100 ? number / 100 : number
    }

    /// Whether the camera draws its own date and time (`DateTimeOverlay/enabled`); nil when the overlays document has no
    /// `DateTimeOverlay` element (a model that does not offer it).
    func dateTimeOverlayEnabled(inputChannel: Int) async throws -> Bool? {
        let document = try await xml(Self.overlaysPath(inputChannel: inputChannel))
        guard let section = document.matches("DateTimeOverlay") ? document : document.firstDescendant("DateTimeOverlay"),
              let enabled = section.string("enabled") else { return nil }
        return ONVIFNotification.parseBool(enabled)
    }

    /// Reads the overlays document, sets `DateTimeOverlay/enabled`, and writes the whole document back (read-modify-write:
    /// the camera's other overlays — channel name, text lines — stay as they were). Throws `.unsupported` when the document
    /// has no `DateTimeOverlay/enabled` to change.
    func setDateTimeOverlayEnabled(_ enabled: Bool, inputChannel: Int) async throws {
        let path = Self.overlaysPath(inputChannel: inputChannel)
        guard let document = String(data: try await get(path), encoding: .utf8) else {
            throw CameraAdapterError.invalidResponse("\(path): not UTF-8 XML")
        }
        guard let replaced = Self.replacingEnabled(inSection: "DateTimeOverlay", in: document, enabled: enabled),
              let body = replaced.data(using: .utf8) else {
            throw CameraAdapterError.unsupported("This camera's on-screen display has no date and time overlay to change")
        }
        _ = try await put(path, body: body)
    }

    /// Text-level read-modify-write of `<section><enabled>…</enabled>…</section>` (any attributes on the section tag; the
    /// first `enabled` inside it). nil when the section or its `enabled` is missing.
    static func replacingEnabled(inSection name: String, in document: String, enabled: Bool) -> String? {
        guard let open = document.range(of: "<\(name)", options: .caseInsensitive),
              let close = document.range(of: "</\(name)>", options: .caseInsensitive, range: open.lowerBound..<document.endIndex) else { return nil }
        let section = String(document[open.lowerBound..<close.upperBound])
        guard let edited = replacingElement("enabled", in: section, with: enabled ? "true" : "false") else { return nil }
        var result = document
        result.replaceSubrange(open.lowerBound..<close.upperBound, with: edited)
        return result
    }

    /// The long-lived `alertStream` response (its own client: the request timeout covers each wait for data).
    static func alertStream(endpoint: CameraEndpoint, credentials: HTTPCredentials?, readTimeout: Duration) async throws
        -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>, AuthenticatingHTTPClient) {
        guard let url = endpoint.httpURL(path: "/ISAPI/Event/notification/alertStream") else {
            throw CameraAdapterError.invalidResponse("invalid camera address")
        }
        let client = AuthenticatingHTTPClient(credentials: credentials, timeout: readTimeout)
        do {
            let (response, body) = try await client.stream(for: URLRequest(url: url))
            return (response, body, client)
        } catch {
            client.invalidate()
            throw CameraHTTP.sanitized(error)
        }
    }
}
