import BridgeSupport
import Foundation
import MediaCore

public enum CameraVendor: String, Sendable, Codable, CaseIterable {
    case hikvision, reolink, onvif, rtsp, demo
    /// A camera behind a cloud account or a console, reached through the go2rtc helper (`Go2RTCDriver`).
    case go2rtc
    /// Amcrest and Dahua cameras and doorbells: RTSP `/cam/realmonitor`, motion and doorbell events from the CGI event stream
    /// (`AmcrestDriver`).
    case amcrest
    /// A UniFi Protect console (API key): video as RTSPS through the go2rtc helper, events from the Protect WebSocket
    /// (`UnifiProtectDriver`).
    case unifi
    /// A DoorBird intercom over its LAN API: RTSP video, doorbell and motion from the event monitor (`DoorBirdDriver`).
    case doorbird
}

public enum DetectedObjectKind: String, Sendable, Codable, CaseIterable { case person, vehicle, animal, package, face }

public enum CameraEvent: Sendable, Equatable {
    case motion(Bool)
    case object(DetectedObjectKind, Bool)
    case doorbellPressed
    case tamper(Bool)
    case dayNight(isNight: Bool)
    case digitalInput(id: String, active: Bool)
    case temperature(celsius: Double)
    case humidity(percent: Double)
    case audioAlarm(Bool)
    case eventChannel(connected: Bool)
    /// The camera rejected the credentials (HTTP 401 after the Digest answer, Reolink login error, ONVIF
    /// `NotAuthorized`). Emitted once per rejected attempt; the source retries only after 10 minutes (camera login
    /// lockouts). A later `.eventChannel(connected: true)` means the credentials work again.
    case authenticationFailed
    /// The event channel connects and then ends again and again within seconds (a camera that accepts the subscription and
    /// drops it): its events cannot be relied on. Emitted once per streak of short sessions; the app falls back to built-in
    /// motion detection for the camera.
    case eventChannelUnreliable(shortSessions: Int)
}

public enum CameraEventKind: String, Sendable, Codable, CaseIterable {
    case motion, person, vehicle, animal, package, face, doorbell, tamper, dayNight, digitalInput, temperature, humidity, audioAlarm
}

public struct CameraEndpoint: Sendable, Codable, Hashable {
    public var host: String
    public var httpPort: Int
    public var rtspPort: Int
    public var onvifPort: Int?
    public var useHTTPS: Bool

    public init(host: String, httpPort: Int = 80, rtspPort: Int = 554, onvifPort: Int? = nil, useHTTPS: Bool = false) {
        self.host = host
        self.httpPort = httpPort
        self.rtspPort = rtspPort
        self.onvifPort = onvifPort
        self.useHTTPS = useHTTPS
    }
}

public struct CameraCapabilities: Sendable, Codable, Equatable {
    public var events: Set<CameraEventKind>
    public var twoWayAudio: Bool
    public var isDoorbell: Bool
    public var snapshotAPI: Bool
    public var nightVisionControl: Bool
    public var indicatorControl: Bool

    public init(events: Set<CameraEventKind> = [], twoWayAudio: Bool = false, isDoorbell: Bool = false, snapshotAPI: Bool = false,
                nightVisionControl: Bool = false, indicatorControl: Bool = false) {
        self.events = events
        self.twoWayAudio = twoWayAudio
        self.isDoorbell = isDoorbell
        self.snapshotAPI = snapshotAPI
        self.nightVisionControl = nightVisionControl
        self.indicatorControl = indicatorControl
    }
}

public struct CameraProbeResult: Sendable, Codable, Equatable {
    public var vendor: CameraVendor
    public var manufacturer: String
    public var model: String
    public var serialNumber: String
    public var firmware: String
    public var mainStream: StreamInfo?
    public var subStream: StreamInfo?
    public var capabilities: CameraCapabilities
    /// The ONVIF device service's port when the probe found it somewhere other than the endpoint's HTTP port
    /// (`BridgeEngine.probeCamera`): save it as `CameraEndpoint.onvifPort`. nil otherwise.
    public var onvifPort: Int?

    public init(vendor: CameraVendor, manufacturer: String, model: String, serialNumber: String, firmware: String,
                mainStream: StreamInfo? = nil, subStream: StreamInfo? = nil, capabilities: CameraCapabilities = CameraCapabilities(),
                onvifPort: Int? = nil) {
        self.vendor = vendor
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber
        self.firmware = firmware
        self.mainStream = mainStream
        self.subStream = subStream
        self.capabilities = capabilities
        self.onvifPort = onvifPort
    }
}

public protocol CameraEventSource: Sendable {
    /// Self-reconnecting (Backoff). Emits .eventChannel(connected:) on (dis)connect.
    func events() -> AsyncStream<CameraEvent>
    func stop() async
}

public protocol TalkbackSink: Sendable {
    /// What `send` expects (e.g. PCMU 8 kHz mono).
    var inputFormat: AudioFormat { get }
    func open() async throws
    func send(_ frame: EncodedAudioFrame) async throws
    func close() async
}

public protocol CameraDriver: Sendable {
    var vendor: CameraVendor { get }
    func probe() async throws -> CameraProbeResult
    func makeEventSource() -> (any CameraEventSource)?
    /// JPEG from the camera API, nil if unsupported.
    func snapshot() async throws -> Data?
    func makeTalkbackSink() -> (any TalkbackSink)?
    /// Ends the camera sessions the driver holds (Reolink: its API login, one of the camera's few sessions, held for the
    /// whole lease otherwise). The driver stays usable: a later call logs in again. Whoever makes a driver for a single
    /// check (`BridgeEngine`'s probe) closes it when done. The default does nothing.
    func close() async

    /// Asks the camera to produce a keyframe (an IDR) on its main or sub stream now: a live view that starts in the middle of a
    /// camera's long GOP otherwise waits for the next one. One request per call, never retried: the camera locks logins after a
    /// few failed ones, so a rejected login is not repeated and pauses the camera's logins (`ONVIFLoginGuard`), a camera that does
    /// not know the call is not asked again, and requests to one camera keep their distance (`CameraKeyframeGuard`). Hikvision:
    /// ISAPI `requestKeyFrame`; ONVIF: `SetSynchronizationPoint`. Returns without sending anything when a request went out lately;
    /// throws `CameraAdapterError.unsupported` for cameras without the call (the default), `.unauthorized` / `.lockedOut` when the
    /// camera refuses the login.
    func requestKeyframe(subStream: Bool) async throws
}

extension CameraDriver {
    public func close() async {}

    public func requestKeyframe(subStream: Bool) async throws {
        throw CameraAdapterError.unsupported("this camera has no keyframe request")
    }
}

public struct DiscoveredCamera: Sendable, Hashable, Codable {
    public var host: String
    public var name: String?
    public var hardware: String?
    public var xAddrs: [URL]

    public init(host: String, name: String? = nil, hardware: String? = nil, xAddrs: [URL] = []) {
        self.host = host
        self.name = name
        self.hardware = hardware
        self.xAddrs = xAddrs
    }
}
