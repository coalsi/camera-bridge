import BridgeSupport
import Foundation
import MediaCore
import RTSP

/// Plain RTSP camera: user-provided stream URLs, no event channel (motion comes from `SoftMotionDetector` or the
/// webhook), no snapshot API, no talkback. `probe()` connects with `RTSPClient` (OPTIONS/DESCRIBE/SETUP) to learn the
/// formats. Credentials embedded in a URL are moved out of it (used only when none are configured).
final class GenericRTSPDriver: CameraDriver, Sendable {
    let vendor: CameraVendor = .rtsp

    private let endpoint: CameraEndpoint
    private let credentials: HTTPCredentials?
    private let mainStreamURL: URL?
    private let subStreamURL: URL?
    private let rtspFactory: RTSPSessionFactory
    /// The configured camera this driver serves: its probe's RTSP sessions log with it.
    private let cameraID: UUID?

    init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, mainStreamURL: URL?, subStreamURL: URL?, rtspFactory: @escaping RTSPSessionFactory,
         cameraID: UUID? = nil) {
        self.endpoint = endpoint
        self.credentials = credentials ?? Self.embeddedCredentials(mainStreamURL)
        self.mainStreamURL = mainStreamURL?.removingUserInfo
        self.subStreamURL = subStreamURL?.removingUserInfo
        self.rtspFactory = rtspFactory
        self.cameraID = cameraID
    }

    convenience init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, mainStreamURL: URL?, subStreamURL: URL?,
                     transport: any NetworkTransport, cameraID: UUID? = nil) {
        self.init(endpoint: endpoint, credentials: credentials, mainStreamURL: mainStreamURL, subStreamURL: subStreamURL,
                  rtspFactory: RTSPProbing.factory(transport: transport), cameraID: cameraID)
    }

    static func embeddedCredentials(_ url: URL?) -> HTTPCredentials? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let user = components.user else { return nil }
        return HTTPCredentials(username: user, password: components.password ?? "")
    }

    func probe() async throws -> CameraProbeResult {
        guard let mainStreamURL else { throw CameraAdapterError.unsupported("an RTSP stream URL is required") }
        let info = try await RTSPProbing.describe(url: mainStreamURL, credentials: credentials, cameraID: cameraID, factory: rtspFactory)
        var sub: StreamInfo?
        if let subStreamURL {
            if let subInfo = try? await RTSPProbing.describe(url: subStreamURL, credentials: credentials, cameraID: cameraID, factory: rtspFactory) {
                sub = RTSPProbing.streamInfo(url: subStreamURL, info: subInfo)
            } else {
                sub = StreamInfo(url: subStreamURL)
            }
        }
        return CameraProbeResult(vendor: .rtsp, manufacturer: "Generic", model: "RTSP Camera", serialNumber: endpoint.host, firmware: "",
                                 mainStream: RTSPProbing.streamInfo(url: mainStreamURL, info: info), subStream: sub,
                                 capabilities: CameraCapabilities())
    }

    func makeEventSource() -> (any CameraEventSource)? { nil }

    func snapshot() async throws -> Data? { nil }

    func makeTalkbackSink() -> (any TalkbackSink)? { nil }
}
