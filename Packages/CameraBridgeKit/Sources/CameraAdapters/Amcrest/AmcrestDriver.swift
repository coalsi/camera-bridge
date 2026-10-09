import BridgeSupport
import Foundation
import MediaCore
import RTSP

/// Amcrest or Dahua camera or doorbell: RTSP `/cam/realmonitor?channel=1&subtype=0|1`, motion, smart-detection, tamper and doorbell
/// events from the CGI event stream (`AmcrestEvents`), JPEG snapshots from `snapshot.cgi`. Two-way audio is the ONVIF backchannel
/// and not offered here (Amcrest's own call button stops working while a client holds the backchannel; use the ONVIF type for it).
final class AmcrestDriver: CameraDriver, Sendable {
    let vendor: CameraVendor = .amcrest

    private let endpoint: CameraEndpoint
    private let credentials: HTTPCredentials?
    private let mainStreamURL: URL?
    private let subStreamURL: URL?
    private let rtspFactory: RTSPSessionFactory
    private let transport: any NetworkTransport
    private let timing: AmcrestEventTiming
    private let api: AmcrestAPI
    private let cameraID: UUID?

    init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, mainStreamURL: URL?, subStreamURL: URL?, transport: any NetworkTransport,
         rtspFactory: @escaping RTSPSessionFactory, timing: AmcrestEventTiming = AmcrestEventTiming(), cameraID: UUID? = nil) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.mainStreamURL = mainStreamURL?.removingUserInfo
        self.subStreamURL = subStreamURL?.removingUserInfo
        self.rtspFactory = rtspFactory
        self.transport = transport
        self.timing = timing
        self.cameraID = cameraID
        self.api = AmcrestAPI(endpoint: endpoint, credentials: credentials)
    }

    convenience init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, mainStreamURL: URL?, subStreamURL: URL?, transport: any NetworkTransport,
                     cameraID: UUID? = nil) {
        self.init(endpoint: endpoint, credentials: credentials, mainStreamURL: mainStreamURL, subStreamURL: subStreamURL, transport: transport,
                  rtspFactory: RTSPProbing.factory(transport: transport), cameraID: cameraID)
    }

    func probe() async throws -> CameraProbeResult {
        let info = try await api.deviceInfo()   // the login: a wrong password stops here, before any RTSP attempt
        let mainURL = mainStreamURL ?? endpoint.rtspURL(path: AmcrestRTSP.path(channel: 1, sub: false))
        let subURL = subStreamURL ?? (mainStreamURL == nil ? endpoint.rtspURL(path: AmcrestRTSP.path(channel: 1, sub: true)) : nil)
        var main: StreamInfo?
        if let mainURL {
            let described = try await RTSPProbing.describe(url: mainURL, credentials: credentials, cameraID: cameraID, factory: rtspFactory)
            main = RTSPProbing.streamInfo(url: mainURL, info: described)
        }
        var sub: StreamInfo?
        if let subURL {
            if let described = try? await RTSPProbing.describe(url: subURL, credentials: credentials, cameraID: cameraID, factory: rtspFactory) {
                sub = RTSPProbing.streamInfo(url: subURL, info: described)
            }
        }
        var events: Set<CameraEventKind> = [.motion, .person, .vehicle, .tamper, .audioAlarm]
        if info.isDoorbell { events.insert(.doorbell) }
        let model = info.deviceType.isEmpty ? (info.isDoorbell ? "Doorbell" : "Camera") : info.deviceType
        return CameraProbeResult(vendor: .amcrest, manufacturer: Self.manufacturer(model: info.deviceType), model: model,
                                 serialNumber: info.serialNumber, firmware: info.firmware, mainStream: main, subStream: sub,
                                 capabilities: CameraCapabilities(events: events, twoWayAudio: false, isDoorbell: info.isDoorbell, snapshotAPI: true))
    }

    /// Amcrest model names start with `IP`, `ASH`, `AD`…; Dahua's with `IPC-`, `DH-`, `VTO`. Both ship as "Amcrest" or "Dahua" firmware.
    static func manufacturer(model: String) -> String {
        let upper = model.uppercased()
        return ["IPC-", "DH-", "VTO", "NVR", "XVR"].contains { upper.hasPrefix($0) } ? "Dahua" : "Amcrest"
    }

    func makeEventSource() -> (any CameraEventSource)? {
        AmcrestEvents.makeSource(endpoint: endpoint, credentials: credentials, transport: transport, timing: timing, cameraID: cameraID)
    }

    func snapshot() async throws -> Data? {
        try await api.snapshot()
    }

    func makeTalkbackSink() -> (any TalkbackSink)? { nil }

    func close() async {
        api.invalidate()
    }
}
