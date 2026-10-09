import BridgeSupport
import Foundation
import MediaCore
import RTSP
import Synchronization

/// Reolink stream URLs.
public enum ReolinkStreamURLs {
    /// `rtsp://host:rtspPort/h264Preview_<NN>_main|sub` (`h265Preview_…` for H.265 streams); `channel` is 0-based.
    public static func rtsp(endpoint: CameraEndpoint, channel: Int = 0, main: Bool = true, hevc: Bool = false) -> URL? {
        let number = String(format: "%02d", channel + 1)
        return endpoint.rtspURL(path: "/\(hevc ? "h265" : "h264")Preview_\(number)_\(main ? "main" : "sub")")
    }

    /// HTTP-FLV fallback: `http(s)://host:httpPort/flv?port=1935&app=bcs&stream=channel<N>_main|sub.bcs`.
    /// Reolink authenticates FLV with `user`/`password` query items: pass `credentials` only for the URL actually
    /// requested by the ingest layer — that URL is secret (never log it unredacted, never store it, never show it).
    public static func flv(endpoint: CameraEndpoint, channel: Int = 0, main: Bool = true, rtmpPort: Int = 1935,
                           credentials: HTTPCredentials? = nil) -> URL? {
        var query = [("port", String(rtmpPort)), ("app", "bcs"), ("stream", "channel\(channel)_\(main ? "main" : "sub").bcs")]
        if let credentials { query += [("user", credentials.username), ("password", credentials.password)] }
        let text = query.map { "\($0.0)=\(strictEncode($0.1))" }.joined(separator: "&")
        guard let base = endpoint.httpURL(path: "/flv") else { return nil }
        return URL(string: base.absoluteString + "?" + text)
    }

    /// Percent-encodes everything but RFC 3986 unreserved characters.
    static func strictEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// Reolink camera or doorbell: JSON API (token login), RTSP `h264Preview_01_main|sub`, 1 Hz event polling plus ONVIF
/// `Visitor` for doorbells, `Snap` snapshots, and talkback through the ONVIF RTSP backchannel when the SDP offers it.
final class ReolinkDriver: CameraDriver, Sendable {
    let vendor: CameraVendor = .reolink
    static let defaultONVIFPort = 8000
    /// Models whose AI detections Scrypted reads from ONVIF (Scrypted's Reolink plugin, read for behaviour only).
    static let onvifDetectionModels: Set<String> = ["CX410W", "CX410", "CX810", "Reolink Video Doorbell WiFi", "Reolink Video Doorbell PoE"]

    private let endpoint: CameraEndpoint
    private let credentials: HTTPCredentials?
    private let mainStreamURL: URL?
    private let subStreamURL: URL?
    private let rtspFactory: RTSPSessionFactory
    private let timing: ReolinkEventTiming
    private let channel: Int
    /// One API session per driver: probe, snapshots and the event source share its token.
    private let api: ReolinkAPI
    /// nil until probed.
    private let backchannel = Mutex<(known: Bool?, url: URL?)>((nil, nil))
    /// The configured camera this driver serves: its API session, event source, RTSP probes and talkback log with it.
    private let cameraID: UUID?

    init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, mainStreamURL: URL?, subStreamURL: URL?, transport: any NetworkTransport,
         rtspFactory: RTSPSessionFactory? = nil, timing: ReolinkEventTiming = ReolinkEventTiming(), channel: Int = 0, cameraID: UUID? = nil,
         reachability: CameraReachability? = nil) {
        self.cameraID = cameraID
        self.endpoint = endpoint
        self.credentials = credentials
        self.mainStreamURL = mainStreamURL?.removingUserInfo
        self.subStreamURL = subStreamURL?.removingUserInfo
        self.rtspFactory = rtspFactory ?? RTSPProbing.factory(transport: transport)
        self.timing = timing
        self.channel = channel
        self.api = ReolinkAPI(endpoint: endpoint, credentials: credentials, channel: channel, cameraID: cameraID, reachability: reachability)
    }

    static func isDoorbell(devInfo: JSONValue?, visitorSupported: Bool) -> Bool {
        let type = devInfo?["type"]?.string?.uppercased() ?? ""
        let model = devInfo?["model"]?.string ?? ""
        return visitorSupported || type == "BELL" || model.localizedCaseInsensitiveContains("doorbell")
    }

    static let abilityAIKeys: [(key: String, kind: DetectedObjectKind)] = [
        ("supportAiPeople", .person), ("supportAiVehicle", .vehicle), ("supportAiDogCat", .animal), ("supportAiPackage", .package),
        ("supportAiFace", .face),
    ]

    /// AI classes a `GetAbility` value declares (`ver` ≠ 0), per channel or device-wide.
    static func aiKinds(fromAbility value: JSONValue, channel: Int) -> [DetectedObjectKind] {
        let ability = value["Ability"]
        let perChannel = ability?["abilityChn"]?[channel]
        return abilityAIKeys.compactMap { entry in
            let supported = perChannel?[entry.key]?["ver"]?.flag ?? ability?[entry.key]?["ver"]?.flag ?? false
            return supported ? entry.kind : nil
        }
    }

    /// `Ability.supportOnvifEnable.ver` ≠ 0; nil when not reported. This says the camera *has* an ONVIF switch
    /// (API v8: "0: not support, 1: support"), not that the switch is on — that is `GetNetPort` (`onvifNetPort`).
    static func onvifEnabled(ability value: JSONValue?) -> Bool? {
        value?["Ability"]?["supportOnvifEnable"]?["ver"]?.flag
    }

    /// The ONVIF switch and port a `GetNetPort` value reports; nil fields when not reported (or out of range).
    struct ONVIFNetPort: Sendable, Equatable {
        var enabled: Bool?
        var port: Int?
    }

    /// From a `GetNetPort` value: `{NetPort:{onvifEnable, onvifPort, rtspEnable, …}}` (API v8 §3.3.17).
    static func onvifNetPort(_ value: JSONValue?) -> ONVIFNetPort {
        let netPort = value?["NetPort"]
        let port = netPort?["onvifPort"]?.int.flatMap { (1...65_535).contains($0) ? $0 : nil }
        return ONVIFNetPort(enabled: netPort?["onvifEnable"]?.flag, port: port)
    }

    static func abilityParam(_ credentials: HTTPCredentials?) -> JSONValue {
        .object(["User": .object(["userName": .string(credentials?.username ?? "admin")])])
    }

    private func streamInfo(_ stream: JSONValue?, main: Bool, audio: Bool) -> StreamInfo? {
        if let override = main ? mainStreamURL : subStreamURL { return StreamInfo(url: override) }
        let hevc = stream?["vType"]?.string?.lowercased() == "h265"
        guard let url = ReolinkStreamURLs.rtsp(endpoint: endpoint, channel: channel, main: main, hevc: hevc) else { return nil }
        guard let stream else { return StreamInfo(url: url) }
        return StreamInfo(url: url, videoCodec: hevc ? .hevc : .h264, width: CameraNumbers.dimension(stream["width"]?.int),
                          height: CameraNumbers.dimension(stream["height"]?.int), fps: CameraNumbers.frameRate(stream["frameRate"]?.double),
                          audioCodec: audio ? .aac : nil)
    }

    func probe() async throws -> CameraProbeResult {
        _ = try await api.validToken()   // proves the credentials (or reuses the driver's live session)
        let devInfo = try await api.command("GetDevInfo")["DevInfo"]
        let channelParam = JSONValue.object(["channel": .number(Double(channel))])
        let enc = try? await api.command("GetEnc", param: channelParam)
        let encoder = enc?["Enc"]
        let audio = encoder?["audio"]?.flag ?? false

        var state: ReolinkEventState?
        if let events = try? await api.command("GetEvents", param: channelParam) {
            state = ReolinkEventState(events: events)
        } else if let ai = try? await api.command("GetAiState", param: channelParam) {
            state = ReolinkEventState(motionState: nil, aiState: ai)
        }
        let ability = try? await api.command("GetAbility", param: Self.abilityParam(credentials))
        let isDoorbell = Self.isDoorbell(devInfo: devInfo, visitorSupported: state?.visitor != nil)
        var events = state?.supported ?? [.motion]
        if state == nil, let ability {
            events.formUnion(Self.aiKinds(fromAbility: ability, channel: channel).map(CameraEventKind.init))
        }
        if isDoorbell { events.insert(.doorbell) }

        let main = streamInfo(encoder?["mainStream"], main: true, audio: audio)
        let sub = streamInfo(encoder?["subStream"], main: false, audio: audio)
        var twoWay = false
        if let url = main?.url {
            twoWay = await RTSPProbing.backchannelFormat(url: url, credentials: credentials, cameraID: cameraID, factory: rtspFactory) != nil
        }
        backchannel.withLock { $0 = (twoWay, main?.url) }
        return CameraProbeResult(vendor: .reolink, manufacturer: "Reolink", model: devInfo?["model"]?.string ?? "Reolink",
                                 serialNumber: devInfo?["serial"]?.string ?? "", firmware: devInfo?["firmVer"]?.string ?? "",
                                 mainStream: main, subStream: sub,
                                 capabilities: CameraCapabilities(events: events, twoWayAudio: twoWay, isDoorbell: isDoorbell, snapshotAPI: true))
    }

    func makeEventSource() -> (any CameraEventSource)? {
        ReolinkEvents.makeSource(api: api, credentials: credentials, timing: timing)
    }

    func snapshot() async throws -> Data? {
        try await api.snapshot()
    }

    /// Logs the driver's API session out (a probe-only driver would otherwise hold one of the camera's few sessions for
    /// the whole lease); a later call logs in again.
    func close() async {
        await api.logout()
    }

    func makeTalkbackSink() -> (any TalkbackSink)? {
        let (known, probedURL) = backchannel.withLock { $0 }
        if known == false { return nil }
        let url = mainStreamURL ?? probedURL ?? ReolinkStreamURLs.rtsp(endpoint: endpoint, channel: channel)
        guard let url else { return nil }
        return RTSPBackchannelTalkbackSink(credentials: credentials, factory: rtspFactory, cameraID: cameraID) { url }
    }
}
