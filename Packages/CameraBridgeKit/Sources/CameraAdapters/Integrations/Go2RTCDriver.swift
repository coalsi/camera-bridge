import BridgeSupport
import Foundation
import MediaCore
import RTSP

/// A driver that holds streams on a helper (the engine ends them when the camera stops).
public protocol StreamHoldingDriver: CameraDriver {
    /// Attaches the camera's stream to the helper and returns its local RTSP address (what the ingest connects to), without
    /// asking the stream for anything. Called again after a failure (the helper restarted, the saved source changed).
    func attachStreams() async throws -> URL
    /// Lets go of the helper streams this driver attached. The driver stays usable: `probe()` attaches again.
    func releaseStreams() async
}

/// A problem with a service integration, worded for the person (no secrets in it).
public struct IntegrationError: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

extension Go2RTCError: LocalizedError {
    public var errorDescription: String? { description }
}

/// A camera that go2rtc turns into plain RTSP: Ring, Google Nest, Wyze, Tuya, other go2rtc sources.
///
/// The camera's secret is its go2rtc source (`Go2RTCSource`), kept in the Keychain as the camera's "password". The driver hands
/// the source to the `Go2RTCManager`, gets back `rtsp://127.0.0.1:<port>/cb-<camera id>`, and the ordinary RTSP ingest reads
/// that. There is no event channel (motion comes from Camera Bridge's built-in motion detection, `MotionSource.softMotion`),
/// no snapshot API and no two-way audio: the helper's RTSP carries video and the camera's audio.
final class Go2RTCDriver: StreamHoldingDriver, Sendable {
    let vendor: CameraVendor = .go2rtc

    /// How long a probe waits for the service to deliver the first picture: cloud services negotiate a WebRTC session first.
    static let probeTimeout: Duration = .seconds(40)

    private let cameraID: UUID?
    private let streamID: String
    private let settings: IntegrationSettings?
    private let credentials: HTTPCredentials?
    private let provider: (any Go2RTCStreamProviding)?
    private let rtspFactory: RTSPSessionFactory
    private let probeTimeout: Duration

    init(cameraID: UUID?, settings: IntegrationSettings?, credentials: HTTPCredentials?, provider: (any Go2RTCStreamProviding)?,
         rtspFactory: @escaping RTSPSessionFactory, probeTimeout: Duration = Go2RTCDriver.probeTimeout) {
        self.cameraID = cameraID
        self.streamID = Go2RTCManager.streamName(for: cameraID ?? UUID())
        self.settings = settings
        self.credentials = credentials
        self.provider = provider
        self.rtspFactory = rtspFactory
        self.probeTimeout = probeTimeout
    }

    /// The source saved for the camera, or why there is none.
    func source() throws -> Go2RTCSource {
        guard let text = credentials?.password, !text.isEmpty else {
            throw IntegrationError("This camera has no source address saved. Open its settings and enter it again.")
        }
        do {
            return try Go2RTCSource(parsing: text)
        } catch let invalid as Go2RTCSource.Invalid {
            throw IntegrationError("The saved source address can’t be used. \(invalid.reason)")
        }
    }

    func probe() async throws -> CameraProbeResult {
        guard let provider else { throw IntegrationError("The streaming helper isn’t available in this copy of Camera Bridge.") }
        let source = try source()
        let service = settings?.service ?? source.service
        let url = try await provider.attach(streamID: streamID, source: source)
        let info: RTSPSessionInfo
        do {
            info = try await RTSPProbing.describe(url: url, credentials: nil, cameraID: cameraID, timeout: probeTimeout, factory: rtspFactory)
        } catch {
            throw await Self.explained(error, service: service, problems: provider.problems(streamID: streamID))
        }
        return CameraProbeResult(vendor: .go2rtc, manufacturer: service.displayName, model: settings?.deviceName ?? "\(service.displayName) camera",
                                 serialNumber: Self.identity(of: source), firmware: "", mainStream: RTSPProbing.streamInfo(url: url, info: info),
                                 subStream: nil, capabilities: CameraCapabilities())
    }

    /// The camera's stream address, once the helper serves it (the ingest reads it; `CameraRuntime` asks through `probe()`).
    func makeEventSource() -> (any CameraEventSource)? { nil }

    func snapshot() async throws -> Data? { nil }

    func makeTalkbackSink() -> (any TalkbackSink)? { nil }

    func attachStreams() async throws -> URL {
        guard let provider else { throw IntegrationError("The streaming helper isn’t available in this copy of Camera Bridge.") }
        return try await provider.attach(streamID: streamID, source: try source())
    }

    func releaseStreams() async {
        await provider?.detach(streamID: streamID)
    }

    func close() async {
        await releaseStreams()
    }

    /// A stable identity for the same source added twice (the wizard warns about it): a short hash of the source address.
    static func identity(of source: Go2RTCSource) -> String {
        var hash: UInt64 = 0xcbf29ce484222325   // FNV-1a
        for byte in source.url.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "go2rtc-" + String(hash, radix: 16)
    }

    /// The failure with what the helper said about it, in the person's words.
    static func explained(_ error: any Error, service: IntegrationService, problems: [String]) -> any Error {
        if error is CancellationError || error is Go2RTCError { return error }
        let detail = problems.last.map { " go2rtc says: \($0)" } ?? ""
        let what: String
        switch error {
        case RTSPError.timeout:
            what = "\(service.displayName) did not deliver video in time."
        case RTSPError.notFound, RTSPError.badStatus:
            what = "\(service.displayName) did not deliver video."
        case is TransportError:
            what = "The streaming helper could not be reached."
        default:
            what = "Camera Bridge could not get video from \(service.displayName)."
        }
        let advice = " Check the credentials and that the camera is online in the \(service.displayName) app."
        return IntegrationError(Redact.string(what + detail + (detail.isEmpty ? advice : "")))
    }
}
