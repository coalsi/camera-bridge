import BridgeSupport
import Foundation
import MediaCore
import RTSP
import Synchronization

/// Generic ONVIF (Profile S/T) camera: device info, media profiles → stream/snapshot URIs, PullPoint events and the
/// RTSP audio backchannel for talkback.
final class ONVIFDriver: CameraDriver, Sendable {
    let vendor: CameraVendor = .onvif

    private struct Cache {
        var mainStreamURL: URL?
        var snapshotURL: URL?
        /// The profiles the streams were taken from (`selectProfiles`), once probed or listed for a keyframe request.
        var mainProfileToken: String?
        var subProfileToken: String?
        /// nil until probed.
        var backchannel: Bool?
    }

    private let endpoint: CameraEndpoint
    private let credentials: HTTPCredentials?
    private let mainStreamURL: URL?
    private let subStreamURL: URL?
    private let rtspFactory: RTSPSessionFactory
    private let timing: ONVIFEventTiming
    private let cache = Mutex(Cache())
    /// One client per driver (Digest challenge and camera clock offset are reused); nil for an invalid address.
    private let sharedClient: ONVIFClient?
    /// The configured camera this driver serves: its ONVIF clients, event source, RTSP probes and talkback log with it.
    private let cameraID: UUID?
    /// Spaces this camera's keyframe requests (`requestKeyframe`); tests give it a short spacing.
    private let keyframeGuard: CameraKeyframeGuard

    init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, mainStreamURL: URL?, subStreamURL: URL?, transport: any NetworkTransport,
         rtspFactory: RTSPSessionFactory? = nil, timing: ONVIFEventTiming = ONVIFEventTiming(), cameraID: UUID? = nil,
         keyframeGuard: CameraKeyframeGuard = .shared) {
        self.keyframeGuard = keyframeGuard
        self.cameraID = cameraID
        self.endpoint = endpoint
        self.credentials = credentials
        self.mainStreamURL = mainStreamURL?.removingUserInfo
        self.subStreamURL = subStreamURL?.removingUserInfo
        self.rtspFactory = rtspFactory ?? RTSPProbing.factory(transport: transport)
        self.timing = timing
        self.sharedClient = ONVIFClient.deviceServiceURL(for: endpoint).map {
            ONVIFClient(deviceServiceURL: $0, credentials: credentials, cameraID: cameraID)
        }
    }

    private func client() throws -> ONVIFClient {
        guard let sharedClient else { throw CameraAdapterError.invalidResponse("invalid camera address") }
        return sharedClient
    }

    /// Main = the largest H.264/H.265 profile; sub = the smallest one when it is smaller (preferring profiles whose size
    /// is known over ones that report none).
    static func selectProfiles(_ profiles: [ONVIFProfile]) -> (main: ONVIFProfile?, sub: ONVIFProfile?) {
        let video = profiles.filter { $0.videoCodec != nil }
        let candidates = (video.isEmpty ? profiles : video).sorted { $0.pixelCount > $1.pixelCount }
        guard let main = candidates.first else { return (nil, nil) }
        let smaller = candidates.filter { $0.token != main.token && $0.pixelCount < main.pixelCount }
        return (main, smaller.last { $0.pixelCount > 0 } ?? smaller.last)
    }

    func probe() async throws -> CameraProbeResult {
        let client = try client()
        _ = try? await client.systemDateAndTime()
        let info = try await client.deviceInformation()   // proves the credentials
        let profiles = (try? await client.profiles()) ?? []
        let (mainProfile, subProfile) = Self.selectProfiles(profiles)

        var main: StreamInfo?
        if let mainStreamURL {
            main = StreamInfo(url: mainStreamURL)
        } else if let mainProfile, let uri = try? await client.streamURI(profileToken: mainProfile.token) {
            main = mainProfile.streamInfo(url: uri)
        }
        var sub: StreamInfo?
        if let subStreamURL {
            sub = StreamInfo(url: subStreamURL)
        } else if let subProfile, let uri = try? await client.streamURI(profileToken: subProfile.token) {
            sub = subProfile.streamInfo(url: uri)
        }

        var snapshotURL: URL?
        if let token = (mainProfile ?? profiles.first)?.token { snapshotURL = try? await client.snapshotURI(profileToken: token) }

        var events: Set<CameraEventKind> = []
        if let topics = try? await client.eventTopics(), !topics.isEmpty {
            events = ONVIFEventMapper.eventKinds(forTopics: topics)
        } else if let capabilities = try? await client.capabilities(), capabilities.eventsURL != nil {
            events = [.motion]
        }

        var backchannel = false
        if let url = main?.url {
            backchannel = await RTSPProbing.backchannelFormat(url: url, credentials: credentials, cameraID: cameraID, factory: rtspFactory) != nil
        }
        cache.withLock { cache in
            cache.mainStreamURL = main?.url
            cache.snapshotURL = snapshotURL
            cache.backchannel = backchannel
            cache.mainProfileToken = mainProfile?.token
            cache.subProfileToken = subProfile?.token
        }
        return CameraProbeResult(vendor: .onvif, manufacturer: info.manufacturer, model: info.model, serialNumber: info.serialNumber,
                                 firmware: info.firmwareVersion, mainStream: main, subStream: sub,
                                 capabilities: CameraCapabilities(events: events, twoWayAudio: backchannel, isDoorbell: events.contains(.doorbell),
                                                                  snapshotAPI: snapshotURL != nil))
    }

    func makeEventSource() -> (any CameraEventSource)? {
        guard let url = ONVIFClient.deviceServiceURL(for: endpoint) else { return nil }
        return ONVIFPullPoint.makeSource(deviceServiceURL: url, credentials: credentials, timing: timing, label: "ONVIF \(endpoint.host)",
                                         cameraID: cameraID)
    }

    func snapshot() async throws -> Data? {
        let client = try client()
        var url = cache.withLock { $0.snapshotURL }
        if url == nil {
            let profiles = try await client.profiles()
            guard let token = (Self.selectProfiles(profiles).main ?? profiles.first)?.token,
                  let resolved = try? await client.snapshotURI(profileToken: token) else { return nil }
            cache.withLock { $0.snapshotURL = resolved }
            url = resolved
        }
        guard let url else { return nil }
        return try await client.fetchSnapshot(url)
    }

    /// `SetSynchronizationPoint` on the main or sub profile (see `CameraDriver.requestKeyframe`). The profile tokens come from the
    /// probe; a driver that never probed lists the profiles once for them.
    func requestKeyframe(subStream: Bool) async throws {
        guard let deviceURL = ONVIFClient.deviceServiceURL(for: endpoint) else { throw CameraAdapterError.invalidResponse("invalid camera address") }
        let address = "\(deviceURL.host(percentEncoded: false) ?? ""):\(deviceURL.port ?? 80)"
        let client = try client()
        try await guardedKeyframeRequest(endpoint: endpoint, key: "\(address)/onvif/\(subStream ? "sub" : "main")", loginHost: address,
                                         guardian: keyframeGuard) { [self] in
            var tokens = cache.withLock { ($0.mainProfileToken, $0.subProfileToken) }
            if tokens.0 == nil, tokens.1 == nil {
                let selected = Self.selectProfiles(try await client.profiles())
                tokens = (selected.main?.token, selected.sub?.token)
                cache.withLock { cache in
                    cache.mainProfileToken = tokens.0
                    cache.subProfileToken = tokens.1
                }
            }
            guard let token = subStream ? tokens.1 : tokens.0 else { throw CameraAdapterError.unsupported("no media profile for that stream") }
            try await client.setSynchronizationPoint(profileToken: token)
        }
    }

    func makeTalkbackSink() -> (any TalkbackSink)? {
        let (backchannel, cachedURL) = cache.withLock { ($0.backchannel, $0.mainStreamURL) }
        if backchannel == false { return nil }
        let explicitURL = mainStreamURL
        let endpoint = endpoint
        let credentials = credentials
        let cameraID = cameraID
        return RTSPBackchannelTalkbackSink(credentials: credentials, factory: rtspFactory, cameraID: cameraID) {
            if let url = explicitURL ?? cachedURL { return url }
            guard let deviceURL = ONVIFClient.deviceServiceURL(for: endpoint) else { throw CameraAdapterError.invalidResponse("invalid camera address") }
            let client = ONVIFClient(deviceServiceURL: deviceURL, credentials: credentials, cameraID: cameraID)
            guard let profile = Self.selectProfiles(try await client.profiles()).main else {
                throw CameraAdapterError.unsupported("no media profile")
            }
            return try await client.streamURI(profileToken: profile.token)
        }
    }
}
