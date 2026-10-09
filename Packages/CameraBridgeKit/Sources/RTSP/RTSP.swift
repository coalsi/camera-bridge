import BridgeSupport
import Foundation
import MediaCore
import RTP

// Public configuration and result types of the RTSP module (contracts: RTSP).

public struct RTSPConfiguration: Sendable {
    /// No credentials in the URL.
    public var url: URL
    public var credentials: HTTPCredentials?
    /// ONVIF "Require: www.onvif.org/ver20/backchannel".
    public var requestBackchannel: Bool
    public var timeout: Duration
    public var userAgent: String
    /// Talkback sessions: SETUP only the backchannel track (no video/audio is received). Requires
    /// `requestBackchannel`; `connect()` then throws `RTSPError.protocolError` when the camera offers no backchannel.
    public var backchannelOnly = false
    /// The camera this session belongs to: the client's log lines carry it (`LogEntry.cameraID`), so they show in the
    /// camera's own log. nil: untagged (probes before a camera exists).
    public var cameraID: UUID?

    public init(url: URL, credentials: HTTPCredentials?, requestBackchannel: Bool = false, timeout: Duration = .seconds(10),
                userAgent: String = "CameraBridge/1.0") {
        self.url = url
        self.credentials = credentials
        self.requestBackchannel = requestBackchannel
        self.timeout = timeout
        self.userAgent = userAgent
    }
}

public struct RTSPTrack: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case video, audio, backchannel }

    public var kind: Kind
    public var control: String
    public var payloadType: UInt8
    public var encoding: String
    public var clockRate: Int
    public var channels: Int
    public var fmtp: [String: String]

    public init(kind: Kind, control: String, payloadType: UInt8, encoding: String, clockRate: Int, channels: Int = 1, fmtp: [String: String] = [:]) {
        self.kind = kind
        self.control = control
        self.payloadType = payloadType
        self.encoding = encoding
        self.clockRate = clockRate
        self.channels = channels
        self.fmtp = fmtp
    }
}

/// Result of `RTSPClient.connect()`. `tracks` lists every video/audio section of the SDP (backchannels only when
/// requested); the formats describe the tracks that were set up. `videoFormat` is nil when the camera sends its
/// parameter sets only in band: each frame's `format` is authoritative.
public struct RTSPSessionInfo: Sendable {
    public var tracks: [RTSPTrack]
    public var videoFormat: VideoFormat?
    public var audioFormat: AudioFormat?
    public var backchannelFormat: AudioFormat?

    public init(tracks: [RTSPTrack], videoFormat: VideoFormat? = nil, audioFormat: AudioFormat? = nil, backchannelFormat: AudioFormat? = nil) {
        self.tracks = tracks
        self.videoFormat = videoFormat
        self.audioFormat = audioFormat
        self.backchannelFormat = backchannelFormat
    }
}

public enum RTSPError: Error, Equatable {
    case unauthorized, notFound, badStatus(Int), protocolError(String), timeout, noVideoTrack, unsupportedCodec(String)
}
