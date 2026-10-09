import Foundation
import HDS

public enum H264Profile: UInt8, Sendable, Codable, CaseIterable { case baseline = 0, main = 1, high = 2 }
public enum H264Level: UInt8, Sendable, Codable, CaseIterable { case level3_1 = 0, level3_2 = 1, level4_0 = 2 }

public struct VideoResolution: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int
    public var fps: Int

    public init(_ width: Int, _ height: Int, _ fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
    }
}

public enum StreamingAudioCodec: UInt8, Sendable, Codable { case pcmu = 0, pcma = 1, aacELD = 2, opus = 3, msbc = 4, amr = 5, amrWB = 6 }

public enum StreamingSampleRate: UInt8, Sendable, Codable {
    case khz8 = 0, khz16 = 1, khz24 = 2

    public var hertz: Int {
        switch self {
        case .khz8: 8_000
        case .khz16: 16_000
        case .khz24: 24_000
        }
    }
}

public enum RecordingAudioCodec: UInt8, Sendable, Codable { case aacLC = 0, aacELD = 1 }

public enum RecordingSampleRate: UInt8, Sendable, Codable {
    case khz8 = 0, khz16, khz24, khz32, khz44_1, khz48

    public var hertz: Int {
        switch self {
        case .khz8: 8_000
        case .khz16: 16_000
        case .khz24: 24_000
        case .khz32: 32_000
        case .khz44_1: 44_100
        case .khz48: 48_000
        }
    }
}

public enum SRTPCryptoSuite: UInt8, Sendable, Codable { case aesCm128HmacSha1_80 = 0, aesCm256HmacSha1_80 = 1, none = 2 }

public struct SRTPParameters: Sendable, Equatable {
    public var suite: SRTPCryptoSuite
    public var masterKey: Data
    public var masterSalt: Data

    public init(suite: SRTPCryptoSuite, masterKey: Data, masterSalt: Data) {
        self.suite = suite
        self.masterKey = masterKey
        self.masterSalt = masterSalt
    }
}

public struct CameraStreamingOptions: Sendable {
    public var resolutions: [VideoResolution]
    public var profiles: [H264Profile]
    public var levels: [H264Level]
    /// v1: [(.opus, [.khz16, .khz24])]
    public var audioCodecs: [(codec: StreamingAudioCodec, sampleRates: [StreamingSampleRate])]
    public var twoWayAudio: Bool
    /// v1: [.aesCm128HmacSha1_80]
    public var cryptoSuites: [SRTPCryptoSuite]

    public init(resolutions: [VideoResolution], profiles: [H264Profile] = [.main], levels: [H264Level] = [.level3_1, .level3_2, .level4_0],
                audioCodecs: [(codec: StreamingAudioCodec, sampleRates: [StreamingSampleRate])] = [(.opus, [.khz16, .khz24])],
                twoWayAudio: Bool, cryptoSuites: [SRTPCryptoSuite] = [.aesCm128HmacSha1_80]) {
        self.resolutions = resolutions
        self.profiles = profiles
        self.levels = levels
        self.audioCodecs = audioCodecs
        self.twoWayAudio = twoWayAudio
        self.cryptoSuites = cryptoSuites
    }
}

public struct CameraRecordingOptions: Sendable, Equatable {
    public var prebufferLengthMs: Int
    public var fragmentLengthMs: Int
    public var resolutions: [VideoResolution]
    public var profiles: [H264Profile]
    public var levels: [H264Level]
    public var audioCodec: RecordingAudioCodec
    public var audioSampleRates: [RecordingSampleRate]
    public var audioChannels: Int

    public init(prebufferLengthMs: Int = 4000, fragmentLengthMs: Int = 4000, resolutions: [VideoResolution],
                profiles: [H264Profile] = [.baseline, .main, .high], levels: [H264Level] = [.level3_1, .level3_2, .level4_0],
                audioCodec: RecordingAudioCodec = .aacLC, audioSampleRates: [RecordingSampleRate] = [.khz32], audioChannels: Int = 1) {
        self.prebufferLengthMs = prebufferLengthMs
        self.fragmentLengthMs = fragmentLengthMs
        self.resolutions = resolutions
        self.profiles = profiles
        self.levels = levels
        self.audioCodec = audioCodec
        self.audioSampleRates = audioSampleRates
        self.audioChannels = audioChannels
    }
}

public struct CameraRecordingConfiguration: Sendable, Codable, Equatable {
    public var prebufferLengthMs: Int
    public var eventTriggers: UInt64
    public var fragmentLengthMs: Int
    public var videoProfile: H264Profile
    public var videoLevel: H264Level
    public var videoBitrateKbps: Int
    public var iFrameIntervalMs: Int
    public var resolution: VideoResolution
    public var audioCodec: RecordingAudioCodec
    public var audioChannels: Int
    public var audioSampleRate: RecordingSampleRate
    public var audioMaxBitrateKbps: Int

    public init(prebufferLengthMs: Int, eventTriggers: UInt64, fragmentLengthMs: Int, videoProfile: H264Profile, videoLevel: H264Level,
                videoBitrateKbps: Int, iFrameIntervalMs: Int, resolution: VideoResolution, audioCodec: RecordingAudioCodec,
                audioChannels: Int, audioSampleRate: RecordingSampleRate, audioMaxBitrateKbps: Int) {
        self.prebufferLengthMs = prebufferLengthMs
        self.eventTriggers = eventTriggers
        self.fragmentLengthMs = fragmentLengthMs
        self.videoProfile = videoProfile
        self.videoLevel = videoLevel
        self.videoBitrateKbps = videoBitrateKbps
        self.iFrameIntervalMs = iFrameIntervalMs
        self.resolution = resolution
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.audioSampleRate = audioSampleRate
        self.audioMaxBitrateKbps = audioMaxBitrateKbps
    }
}

public enum SnapshotReason: Int, Sendable { case periodic = 0, event = 1 }

public struct SnapshotRequest: Sendable {
    public var width: Int
    public var height: Int
    public var reason: SnapshotReason?

    public init(width: Int, height: Int, reason: SnapshotReason? = nil) {
        self.width = width
        self.height = height
        self.reason = reason
    }
}

public struct PrepareStreamRequest: Sendable {
    public var sessionID: UUID
    public var controllerAddress: String
    public var isIPv6: Bool
    public var controllerVideoPort: UInt16
    public var controllerAudioPort: UInt16
    public var videoSRTP: SRTPParameters
    public var audioSRTP: SRTPParameters
    /// Our interface address for this HAP connection. Rarely, a controller asks for the other family (`isIPv6`); the
    /// response's `accessoryAddress` must be of the requested family, or the setup fails.
    public var localAddress: String
    /// The HAP connection's IPv6 zone (`HAPSessionHandle.zone`, e.g. `en0`), nil when it has none. `controllerAddress` is
    /// the SetupEndpoints text, which carries no scope: a link-local one (fe80::/10) is reachable only through this zone
    /// (`sendto` to an unscoped link-local address fails). Not part of the initializer (default nil).
    public var connectionZone: String?
    /// The HAP TCP connection's remote (peer) address (`HAPSessionHandle.remoteAddress`), nil when unknown. The controller's
    /// SetupEndpoints address can be one that is not on this network (an iPhone on a VPN advertises the tunnel's address);
    /// the streaming delegate then sends to this one instead. Not part of the initializer (default nil).
    public var peerAddress: String?

    public init(sessionID: UUID, controllerAddress: String, isIPv6: Bool, controllerVideoPort: UInt16, controllerAudioPort: UInt16,
                videoSRTP: SRTPParameters, audioSRTP: SRTPParameters, localAddress: String) {
        self.sessionID = sessionID
        self.controllerAddress = controllerAddress
        self.isIPv6 = isIPv6
        self.controllerVideoPort = controllerVideoPort
        self.controllerAudioPort = controllerAudioPort
        self.videoSRTP = videoSRTP
        self.audioSRTP = audioSRTP
        self.localAddress = localAddress
    }
}

public struct PrepareStreamResponse: Sendable {
    public var accessoryAddress: String
    public var videoPort: UInt16
    public var audioPort: UInt16
    public var videoSSRC: UInt32
    public var audioSSRC: UInt32
    /// Usually echo the controller's.
    public var videoSRTP: SRTPParameters
    public var audioSRTP: SRTPParameters

    public init(accessoryAddress: String, videoPort: UInt16, audioPort: UInt16, videoSSRC: UInt32, audioSSRC: UInt32, videoSRTP: SRTPParameters, audioSRTP: SRTPParameters) {
        self.accessoryAddress = accessoryAddress
        self.videoPort = videoPort
        self.audioPort = audioPort
        self.videoSSRC = videoSSRC
        self.audioSSRC = audioSSRC
        self.videoSRTP = videoSRTP
        self.audioSRTP = audioSRTP
    }
}

public struct SelectedVideoParameters: Sendable, Equatable {
    public var profile: H264Profile
    public var level: H264Level
    public var resolution: VideoResolution
    public var payloadType: UInt8
    public var controllerSSRC: UInt32
    public var maxBitrateKbps: Int
    public var rtcpIntervalSeconds: Double
    public var mtu: Int

    public init(profile: H264Profile, level: H264Level, resolution: VideoResolution, payloadType: UInt8, controllerSSRC: UInt32,
                maxBitrateKbps: Int, rtcpIntervalSeconds: Double, mtu: Int) {
        self.profile = profile
        self.level = level
        self.resolution = resolution
        self.payloadType = payloadType
        self.controllerSSRC = controllerSSRC
        self.maxBitrateKbps = maxBitrateKbps
        self.rtcpIntervalSeconds = rtcpIntervalSeconds
        self.mtu = mtu
    }
}

public struct SelectedAudioParameters: Sendable, Equatable {
    public var codec: StreamingAudioCodec
    public var channels: Int
    public var sampleRate: StreamingSampleRate
    public var packetTimeMs: Int
    public var payloadType: UInt8
    public var controllerSSRC: UInt32
    public var maxBitrateKbps: Int
    public var rtcpIntervalSeconds: Double
    public var comfortNoisePayloadType: UInt8?

    public init(codec: StreamingAudioCodec, channels: Int, sampleRate: StreamingSampleRate, packetTimeMs: Int, payloadType: UInt8,
                controllerSSRC: UInt32, maxBitrateKbps: Int, rtcpIntervalSeconds: Double, comfortNoisePayloadType: UInt8? = nil) {
        self.codec = codec
        self.channels = channels
        self.sampleRate = sampleRate
        self.packetTimeMs = packetTimeMs
        self.payloadType = payloadType
        self.controllerSSRC = controllerSSRC
        self.maxBitrateKbps = maxBitrateKbps
        self.rtcpIntervalSeconds = rtcpIntervalSeconds
        self.comfortNoisePayloadType = comfortNoisePayloadType
    }
}

public enum StreamRequest: Sendable {
    case start(sessionID: UUID, video: SelectedVideoParameters, audio: SelectedAudioParameters?)
    case reconfigure(sessionID: UUID, video: SelectedVideoParameters)
    case stop(sessionID: UUID)
}

/// `prepareStream` and `handleStreamRequest` calls for one stream service arrive one at a time and each must return
/// within `CameraControllerTimings.streamingDelegateTimeout` (8 s); a call that does not is cancelled and abandoned.
public protocol CameraStreamingDelegate: AnyObject, Sendable {
    /// JPEG.
    func snapshot(_ request: SnapshotRequest) async throws -> Data
    func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse
    func handleStreamRequest(_ request: StreamRequest) async throws
}

public struct RecordingPacket: Sendable {
    public var data: Data
    public var isLast: Bool

    public init(data: Data, isLast: Bool) {
        self.data = data
        self.isLast = isLast
    }
}

/// The `updateRecording*` calls run before the hub's write is answered: return promptly and do heavy work (restarting
/// a producer) in the background.
public protocol CameraRecordingDelegate: AnyObject, Sendable {
    func updateRecordingActive(_ active: Bool) async
    func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?) async
    func updateRecordingAudioActive(_ active: Bool) async
    /// First packet MUST be the fMP4 initialization segment; subsequent packets are whole moof+mdat fragments.
    func recordingStream(streamID: Int) async throws -> AsyncThrowingStream<RecordingPacket, any Error>
    func acknowledgeStream(streamID: Int) async
    func closeRecordingStream(streamID: Int, reason: HDSProtocolReason?) async
}

public struct CameraOperatingState: Sendable, Equatable {
    public var homeKitCameraActive: Bool
    public var eventSnapshotsActive: Bool
    public var periodicSnapshotsActive: Bool
    public var recordingActive: Bool
    public var recordingAudioActive: Bool
    public var nightVision: Bool?
    public var indicatorEnabled: Bool?

    public init(homeKitCameraActive: Bool, eventSnapshotsActive: Bool, periodicSnapshotsActive: Bool, recordingActive: Bool,
                recordingAudioActive: Bool, nightVision: Bool? = nil, indicatorEnabled: Bool? = nil) {
        self.homeKitCameraActive = homeKitCameraActive
        self.eventSnapshotsActive = eventSnapshotsActive
        self.periodicSnapshotsActive = periodicSnapshotsActive
        self.recordingActive = recordingActive
        self.recordingAudioActive = recordingAudioActive
        self.nightVision = nightVision
        self.indicatorEnabled = indicatorEnabled
    }
}

public struct CameraControllerConfiguration: Sendable {
    /// CameraRTPStreamManagement services (v1: 2).
    public var streamCount: Int
    public var streaming: CameraStreamingOptions
    /// nil = no HKSV.
    public var recording: CameraRecordingOptions?
    public var isDoorbell: Bool
    public var supportsNightVisionControl: Bool
    public var supportsIndicatorControl: Bool

    public init(streamCount: Int = 2, streaming: CameraStreamingOptions, recording: CameraRecordingOptions?, isDoorbell: Bool,
                supportsNightVisionControl: Bool = false, supportsIndicatorControl: Bool = false) {
        self.streamCount = streamCount
        self.streaming = streaming
        self.recording = recording
        self.isDoorbell = isDoorbell
        self.supportsNightVisionControl = supportsNightVisionControl
        self.supportsIndicatorControl = supportsIndicatorControl
    }
}

public enum RecordingEventTrigger {
    public static let motion: UInt64 = 1 << 0
    public static let doorbell: UInt64 = 1 << 1
}
