import BridgeSupport
import Foundation
import MediaCore
import RTSP

/// A camera of a UniFi Protect console, through the console's official Integration API and an API key the person created.
///
/// - **Video.** The API hands out RTSPS addresses (`rtsps://console:7441/<key>?enableSrtp`). Camera Bridge's own RTSP client speaks
///   plain RTSP only, so the address goes to the go2rtc helper as `rtspx://console:7441/<key>` (go2rtc's TLS RTSP for Ubiquiti)
///   and the helper's local RTSP is what the ingest reads. Without the helper there is no video.
/// - **Events.** Motion, smart detections (person, vehicle, animal, package, face) and doorbell rings come from the console's
///   events WebSocket with the same key.
/// - **Snapshots** come from the API (`snapshot`).
/// - **Secret.** The API key is the camera's Keychain "password" (the key grants access to the console's cameras: treat it like one).
final class UnifiProtectDriver: StreamHoldingDriver, Sendable {
    let vendor: CameraVendor = .unifi

    private let endpoint: CameraEndpoint
    private let apiKey: String
    private let protectCameraID: String
    private let quality: String
    private let settings: IntegrationSettings?
    private let provider: (any Go2RTCStreamProviding)?
    private let rtspFactory: RTSPSessionFactory
    private let timing: UnifiEventTiming
    private let api: UnifiProtectAPI
    private let cameraID: UUID?
    private let streamID: String

    init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, settings: IntegrationSettings?, provider: (any Go2RTCStreamProviding)?,
         rtspFactory: @escaping RTSPSessionFactory, timing: UnifiEventTiming = UnifiEventTiming(), cameraID: UUID? = nil, useHTTPS: Bool = true) {
        var secure = endpoint
        secure.useHTTPS = useHTTPS
        self.endpoint = secure
        self.apiKey = credentials?.password ?? ""
        self.protectCameraID = settings?.details[IntegrationSettings.Key.protectCameraID] ?? ""
        let quality = settings?.details[IntegrationSettings.Key.protectQuality] ?? "high"
        self.quality = ["high", "medium", "low"].contains(quality) ? quality : "high"
        self.settings = settings
        self.provider = provider
        self.rtspFactory = rtspFactory
        self.timing = timing
        self.cameraID = cameraID
        self.streamID = Go2RTCManager.streamName(for: cameraID ?? UUID())
        self.api = UnifiProtectAPI(endpoint: secure, apiKey: apiKey, useHTTPS: useHTTPS)
    }

    private func requireSetup() throws {
        guard !apiKey.isEmpty else { throw IntegrationError("This camera has no API key saved. Open its settings and enter it again.") }
        guard !protectCameraID.isEmpty else { throw IntegrationError("Choose which Protect camera this is.") }
    }

    func probe() async throws -> CameraProbeResult {
        try requireSetup()
        guard let provider else { throw IntegrationError("The streaming helper isn’t available in this copy of Camera Bridge.") }
        let version = try await api.applicationVersion()   // proves the key
        guard let camera = try await api.cameras().first(where: { $0.id == protectCameraID }) else {
            throw IntegrationError("The console has no camera with that ID any more. Choose the camera again.")
        }
        guard camera.isConnected else { throw IntegrationError("\(camera.name) is not connected to the console right now.") }
        let url = try await provider.attach(streamID: streamID, source: try await source())
        let info: RTSPSessionInfo
        do {
            info = try await RTSPProbing.describe(url: url, credentials: nil, cameraID: cameraID, timeout: .seconds(20), factory: rtspFactory)
        } catch {
            throw await Go2RTCDriver.explained(error, service: .unifiProtect, problems: provider.problems(streamID: streamID))
        }
        var events: Set<CameraEventKind> = [.motion, .person, .vehicle, .animal, .package]
        if camera.isDoorbell { events.insert(.doorbell) }
        return CameraProbeResult(vendor: .unifi, manufacturer: "Ubiquiti", model: camera.type.isEmpty ? camera.name : camera.type,
                                 serialNumber: camera.mac.isEmpty ? camera.id : camera.mac, firmware: "Protect \(version)",
                                 mainStream: RTSPProbing.streamInfo(url: url, info: info), subStream: nil,
                                 capabilities: CameraCapabilities(events: events, twoWayAudio: false, isDoorbell: camera.isDoorbell, snapshotAPI: true))
    }

    /// The go2rtc source for the camera's RTSPS stream (the console is asked for it: creating it is idempotent).
    private func source() async throws -> Go2RTCSource {
        let rtsps = try await api.rtspsStream(cameraID: protectCameraID, quality: quality)
        // The console may report its internal address; the address the person gave is the one that works from this Mac.
        guard let url = URL(string: rtsps) else { throw CameraAdapterError.invalidResponse("the console sent a bad stream address") }
        return try Go2RTCSource.unifiProtect(rtspsURL: url.replacingHost(with: endpoint.host).absoluteString)
    }

    func attachStreams() async throws -> URL {
        try requireSetup()
        guard let provider else { throw IntegrationError("The streaming helper isn’t available in this copy of Camera Bridge.") }
        return try await provider.attach(streamID: streamID, source: try await source())
    }

    func releaseStreams() async {
        await provider?.detach(streamID: streamID)
    }

    func makeEventSource() -> (any CameraEventSource)? {
        guard !apiKey.isEmpty, !protectCameraID.isEmpty else { return nil }
        return UnifiProtectEvents.makeSource(endpoint: endpoint, apiKey: apiKey, protectCameraID: protectCameraID, timing: timing, cameraID: cameraID)
    }

    func snapshot() async throws -> Data? {
        try requireSetup()
        return try await api.snapshot(cameraID: protectCameraID)
    }

    func makeTalkbackSink() -> (any TalkbackSink)? { nil }

    func close() async {
        await releaseStreams()
        api.invalidate()
    }
}
