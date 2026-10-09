import BridgeSupport
import Foundation
import MediaCore
import RTSP

struct DoorBirdEventTiming: Sendable {
    /// A press is a pulse; motion stays on this long after the last `motionsensor:H` (the monitor reports each change once).
    var motionHold: Duration = .seconds(20)
    /// The monitor sends nothing while the door is quiet, so a stalled connection cannot be told from a quiet one: the stream is
    /// restarted every so often (one request, well inside the device's limit of one connection per second).
    var maximumSession: Duration = .seconds(10 * 60)
    var policy = ReconnectPolicy(backoff: Backoff(), healthyAfter: .seconds(10), minimumDelayAfterFailure: .seconds(5))
    var ringDedupe: Duration = .seconds(3)
}

enum DoorBirdEventMapper {
    static func signals(for line: DoorBirdMonitorLine, motionHold: Duration) -> [EventSignal] {
        switch line {
        case .doorbell(let active): active ? [.ring] : []
        case .motion(let active): active ? [.activate(.motion, source: "motionsensor", hold: motionHold)] : []
        }
    }
}

private struct DoorBirdSessionEnd: Error {}

enum DoorBirdEvents {
    static func makeSource(endpoint: CameraEndpoint, credentials: HTTPCredentials?, transport: any NetworkTransport,
                           timing: DoorBirdEventTiming = DoorBirdEventTiming(), cameraID: UUID? = nil) -> SupervisedEventSource {
        SupervisedEventSource(label: "DoorBird \(endpoint.host)", cameraID: cameraID, policy: timing.policy, ringDedupe: timing.ringDedupe) { context in
            try await session(endpoint: endpoint, credentials: credentials, transport: transport, timing: timing, context: context)
        }
    }

    static func session(endpoint: CameraEndpoint, credentials: HTTPCredentials?, transport: any NetworkTransport, timing: DoorBirdEventTiming,
                        context: EventSessionContext) async throws {
        let key = DoorBirdAPI.loginKey(endpoint)
        if credentials != nil, let until = ONVIFLoginGuard.shared.blockedUntil(host: key) { throw CameraAdapterError.lockedOut(until: until) }
        let stream = try await DoorBirdAPI.monitor(endpoint: endpoint, credentials: credentials, readTimeout: timing.maximumSession + .seconds(30),
                                                   transport: transport)
        defer { stream.close() }
        let body = stream.body
        switch stream.status {
        case 200: break
        case 509: throw CameraAdapterError.unsupported("the DoorBird has all of its event streams in use")
        default: try DoorBirdAPI.check(status: stream.status, key: key, hasCredentials: credentials != nil)
        }
        context.connected()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var parser = DoorBirdMonitorParser()
                for try await chunk in body {
                    for line in parser.feed(chunk) { await context.apply(DoorBirdEventMapper.signals(for: line, motionHold: timing.motionHold)) }
                }
            }
            group.addTask {
                try await Task.sleep(for: timing.maximumSession)
                throw DoorBirdSessionEnd()
            }
            defer { group.cancelAll() }
            do {
                _ = try await group.next()
            } catch is DoorBirdSessionEnd {
                // A planned restart, not a failure: the session counts as healthy and reconnects at once.
            }
        }
    }
}

/// DoorBird intercom over its LAN API: RTSP video, doorbell and motion events from the event monitor, live images. The user the
/// app uses must be allowed to “Watch always” (otherwise the video and images only work for a minute after a ring).
final class DoorBirdDriver: CameraDriver, Sendable {
    let vendor: CameraVendor = .doorbird

    private let endpoint: CameraEndpoint
    private let credentials: HTTPCredentials?
    private let mainStreamURL: URL?
    private let rtspFactory: RTSPSessionFactory
    private let transport: any NetworkTransport
    private let timing: DoorBirdEventTiming
    private let api: DoorBirdAPI
    private let cameraID: UUID?

    init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, mainStreamURL: URL?, transport: any NetworkTransport, rtspFactory: @escaping RTSPSessionFactory,
         timing: DoorBirdEventTiming = DoorBirdEventTiming(), cameraID: UUID? = nil) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.mainStreamURL = mainStreamURL?.removingUserInfo
        self.rtspFactory = rtspFactory
        self.transport = transport
        self.timing = timing
        self.cameraID = cameraID
        self.api = DoorBirdAPI(endpoint: endpoint, credentials: credentials)
    }

    convenience init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, mainStreamURL: URL?, transport: any NetworkTransport, cameraID: UUID? = nil) {
        self.init(endpoint: endpoint, credentials: credentials, mainStreamURL: mainStreamURL, transport: transport,
                  rtspFactory: RTSPProbing.factory(transport: transport), cameraID: cameraID)
    }

    func probe() async throws -> CameraProbeResult {
        let info = try await api.info()   // the login first: a wrong password stops here
        var candidates: [URL] = []
        if let mainStreamURL { candidates.append(mainStreamURL) }
        for path in [DoorBirdRTSP.hdPath, DoorBirdRTSP.path] { if let url = endpoint.rtspURL(path: path), !candidates.contains(url) { candidates.append(url) } }
        var main: StreamInfo?
        var failure: (any Error)?
        for url in candidates {
            do {
                let described = try await RTSPProbing.describe(url: url, credentials: credentials, cameraID: cameraID, factory: rtspFactory)
                main = RTSPProbing.streamInfo(url: url, info: described)
                break
            } catch {
                failure = error
            }
        }
        guard let main else { throw failure ?? CameraAdapterError.unsupported("the DoorBird offers no RTSP stream") }
        return CameraProbeResult(vendor: .doorbird, manufacturer: "DoorBird", model: info.deviceType, serialNumber: info.macAddress, firmware: info.firmware,
                                 mainStream: main, subStream: nil,
                                 capabilities: CameraCapabilities(events: [.motion, .doorbell], twoWayAudio: false, isDoorbell: true, snapshotAPI: true))
    }

    func makeEventSource() -> (any CameraEventSource)? {
        DoorBirdEvents.makeSource(endpoint: endpoint, credentials: credentials, transport: transport, timing: timing, cameraID: cameraID)
    }

    func snapshot() async throws -> Data? {
        try await api.snapshot()
    }

    func makeTalkbackSink() -> (any TalkbackSink)? { nil }

    func close() async {
        api.invalidate()
    }
}
