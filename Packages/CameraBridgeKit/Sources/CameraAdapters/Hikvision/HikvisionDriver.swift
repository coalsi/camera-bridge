import BridgeSupport
import Foundation
import MediaCore

/// Hikvision ISAPI camera (or one NVR channel): RTSP `/ISAPI/Streaming/channels/<n>01|<n>02`, Digest auth,
/// `alertStream` events (one stream per device, shared through `HikvisionAlertHub`), JPEG snapshots and ISAPI two-way
/// audio.
final class HikvisionDriver: CameraDriver, Sendable {
    let vendor: CameraVendor = .hikvision

    private let endpoint: CameraEndpoint
    private let credentials: HTTPCredentials?
    private let mainStreamURL: URL?
    private let subStreamURL: URL?
    private let transport: any NetworkTransport
    private let timing: HikvisionEventTiming
    /// One client per driver so the Digest challenge is reused across probes and snapshots.
    private let isapi: HikvisionISAPI
    /// 1 for cameras; the NVR channel number otherwise (from the configured stream URL).
    let cameraNumber: Int
    /// The `channelID` this camera's events carry, when the stream URL names an ISAPI channel (as Scrypted does: an
    /// explicit channel filters the device's shared alertStream, including channel 1 of an NVR); nil = every alert.
    let eventChannelFilter: String?
    private let eventSourcesMade = LockedValue(0)
    /// The configured camera this driver serves: its event source and talkback sink log with it.
    private let cameraID: UUID?
    /// Spaces this camera's keyframe requests (`requestKeyframe`); tests give it a short spacing.
    private let keyframeGuard: CameraKeyframeGuard

    init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, mainStreamURL: URL?, subStreamURL: URL?, transport: any NetworkTransport,
         timing: HikvisionEventTiming = HikvisionEventTiming(), cameraID: UUID? = nil, keyframeGuard: CameraKeyframeGuard = .shared) {
        self.keyframeGuard = keyframeGuard
        self.cameraID = cameraID
        self.endpoint = endpoint
        self.credentials = credentials
        self.mainStreamURL = mainStreamURL?.removingUserInfo
        self.subStreamURL = subStreamURL?.removingUserInfo
        self.transport = transport
        self.timing = timing
        let explicitNumber = Self.explicitCameraNumber(from: mainStreamURL)
        self.cameraNumber = explicitNumber ?? 1
        self.eventChannelFilter = explicitNumber.map(String.init)
        self.isapi = HikvisionISAPI(endpoint: endpoint, credentials: credentials)
    }

    /// `…/channels/101` → 1, `…/Channels/402` → 4; 1 when the URL has no ISAPI channel. (`CameraDrivers.hikvisionChannelID`
    /// is the public entry point for callers outside this module, e.g. `BridgeEngine`'s HomeKit optimizer.)
    static func cameraNumber(from url: URL?) -> Int {
        explicitCameraNumber(from: url) ?? 1
    }

    /// The camera number of an ISAPI channel in the URL (`…/channels/<n>01`), nil when there is none.
    static func explicitCameraNumber(from url: URL?) -> Int? {
        guard let path = url?.path.lowercased(), let range = path.range(of: "/channels/") else { return nil }
        let digits = path[range.upperBound...].prefix { $0.isNumber }
        guard let id = Int(digits), id >= 100 else { return nil }
        return max(1, id / 100)
    }

    private var mainChannelID: String { "\(cameraNumber)01" }
    private var subChannelID: String { "\(cameraNumber)02" }

    func probe() async throws -> CameraProbeResult {
        let info = try await isapi.deviceInfo()
        let channels = (try? await isapi.streamingChannels()) ?? []
        func stream(id: String, override: URL?) -> StreamInfo? {
            let channel = channels.first { $0.id == id }
            if let override {
                return channel.map { $0.streamInfo(url: override) } ?? StreamInfo(url: override)
            }
            guard let url = endpoint.rtspURL(path: "/ISAPI/Streaming/channels/\(id)") else { return nil }
            if let channel { return channel.streamInfo(url: url) }
            return channels.isEmpty && id == mainChannelID ? StreamInfo(url: url) : nil
        }
        let events = (try? await isapi.triggerKinds()) ?? [.motion]
        let twoWayChannels = endpoint.useHTTPS ? nil : try? await isapi.twoWayAudioChannels()
        let twoWay = Self.offersTwoWayAudio(channels: twoWayChannels, cameraNumber: cameraNumber, useHTTPS: endpoint.useHTTPS)
        // Hikvision intercoms (DS-KV/DS-KB) are not reported as doorbells: no alertStream ring event is mapped, so a
        // Doorbell accessory could never ring. Users can still choose Video Doorbell and ring it through the webhook.
        return CameraProbeResult(vendor: .hikvision, manufacturer: "Hikvision", model: info.model, serialNumber: info.serialNumber,
                                 firmware: info.firmware, mainStream: stream(id: mainChannelID, override: mainStreamURL),
                                 subStream: stream(id: subChannelID, override: subStreamURL),
                                 capabilities: CameraCapabilities(events: events, twoWayAudio: twoWay, isDoorbell: false, snapshotAPI: true))
    }

    /// Every source after the first re-subscribes this camera's events (`CameraRuntime` replaces the source on wake
    /// and network changes), which lets the device's shared alertStream reconnect once all its cameras did.
    func makeEventSource() -> (any CameraEventSource)? {
        let resubscribing = eventSourcesMade.withLock { count in
            defer { count += 1 }
            return count > 0
        }
        return HikvisionEvents.makeSource(endpoint: endpoint, credentials: credentials, channelFilter: eventChannelFilter, timing: timing,
                                          cameraID: cameraID, resubscribing: resubscribing)
    }

    func snapshot() async throws -> Data? {
        try await isapi.snapshot(channelID: mainChannelID)
    }

    /// ISAPI `requestKeyFrame` on the main or sub channel (see `CameraDriver.requestKeyframe`).
    func requestKeyframe(subStream: Bool) async throws {
        let channel = subStream ? subChannelID : mainChannelID
        let address = "\(endpoint.host):\(endpoint.httpPort)"
        let isapi = isapi
        try await guardedKeyframeRequest(endpoint: endpoint, key: "\(address)/\(channel)", loginHost: address, guardian: keyframeGuard) {
            try await isapi.requestKeyFrame(channelID: channel)
        }
    }

    /// nil for HTTPS cameras (see `offersTwoWayAudio`): no Speaker is published for a talkback that cannot open. The sink
    /// opens the TwoWayAudio channel the probe offered (`HikvisionTalkbackSink.channel(forCamera:in:)`).
    func makeTalkbackSink() -> (any TalkbackSink)? {
        guard !endpoint.useHTTPS else { return nil }
        return HikvisionTalkbackSink(endpoint: endpoint, credentials: credentials, transport: transport, channel: "\(cameraNumber)",
                                     cameraID: cameraID)
    }

    /// Two-way audio needs a `TwoWayAudio` channel for this camera (its own, or channel 1, which serves an NVR's cameras:
    /// `HikvisionTalkbackSink.channel(forCamera:in:)`, the rule the sink opens by) and plain HTTP: the audio upload runs
    /// over a raw `NetworkTransport` connection, which cannot do TLS, so `HikvisionTalkbackSink.open()` refuses HTTPS
    /// cameras.
    static func offersTwoWayAudio(channels: [HikvisionTwoWayChannel]?, cameraNumber: Int, useHTTPS: Bool) -> Bool {
        guard !useHTTPS, let channels else { return false }
        return HikvisionTalkbackSink.channel(forCamera: "\(cameraNumber)", in: channels) != nil
    }
}
