import CameraAdapters
import Foundation
import HAPCamera

public enum ConnectionState: Sendable, Equatable { case idle, connecting, online, offline(String), disabled }

/// What one active live view is currently receiving (`CameraStatus.liveSessions`).
public struct LiveSessionStatus: Sendable, Equatable {
    public var usesSubStream: Bool
    public var isPassthrough: Bool
    public var resolution: VideoResolution?
    public var bitrateKbps: Int?
    /// How the stream's own health check sees it, in words ("ok", "starting", what it is recovering from); nil when unknown.
    public var health: String?
    /// Why the pipeline ended this stream (it is then ended through HomeKit and gone from the list a moment later); nil while it runs.
    public var endReason: String?

    public init(usesSubStream: Bool, isPassthrough: Bool, resolution: VideoResolution?, bitrateKbps: Int?, health: String? = nil,
                endReason: String? = nil) {
        self.usesSubStream = usesSubStream
        self.isPassthrough = isPassthrough
        self.resolution = resolution
        self.bitrateKbps = bitrateKbps
        self.health = health
        self.endReason = endReason
    }
}

/// What the running HKSV recording is currently producing (`CameraStatus.recordingSession`). `isPassthrough` is nil
/// (unknown ahead of the first decision made from a source frame).
public struct RecordingSessionStatus: Sendable, Equatable {
    public var usesSubStream: Bool
    public var isPassthrough: Bool?
    public var resolution: VideoResolution?
    public var bitrateKbps: Int?

    public init(usesSubStream: Bool, isPassthrough: Bool?, resolution: VideoResolution?, bitrateKbps: Int?) {
        self.usesSubStream = usesSubStream
        self.isPassthrough = isPassthrough
        self.resolution = resolution
        self.bitrateKbps = bitrateKbps
    }
}

/// Static facts about one of the camera's own streams, as last measured by its ingest (`CameraStatus.mainStreamInfo` /
/// `.subStreamInfo`).
public struct SourceStreamInfo: Sendable, Equatable {
    public var codec: String
    public var width: Int
    public var height: Int
    public var fps: Double?
    public var bitrateKbps: Int?

    public init(codec: String, width: Int, height: Int, fps: Double?, bitrateKbps: Int? = nil) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateKbps = bitrateKbps
    }
}

public struct CameraStatus: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: CameraKind
    public var vendor: CameraVendor
    public var connection: ConnectionState
    public var eventChannelConnected: Bool
    /// "H.264 1920×1080 · 20 fps"
    public var videoSummary: String?
    public var isPaired: Bool
    public var setupCode: String
    public var setupURI: String
    public var hapPort: UInt16?
    public var motionActive: Bool
    public var recordingEnabled: Bool
    public var recordingNow: Bool
    public var liveViewers: Int
    /// Viewers in CameraBridge's own window ("1 viewer in CameraBridge"), counted apart from the HomeKit viewers in
    /// `liveViewers`.
    public var appViewers: Int
    public var lastEvent: String?
    public var lastEventDate: Date?
    public var lastError: String?
    /// The camera's latest events (rising edges, as `lastEvent` names them), oldest first, at most
    /// `EventRouter.recentEventLimit`. Kept by the event router whatever the log level.
    public var recentEvents: [CameraEventRecord]
    /// Why the camera's sub stream is offline while it should run ("the connection was refused", "the camera has no
    /// video stream at this address", …: `BridgeEngine.readableReason`), or was when it last ran (an unused sub stream is
    /// stopped; the failure is kept until it delivers a picture again); nil when it is fine, has not failed, or is not
    /// configured. Live views then use the main stream at once, and so does soft motion while the sub stream has no picture.
    public var subStreamProblem: String?
    /// What each active live viewer is currently receiving (docs/CONTRACT_CHANGES.md 2026-10-01).
    public var liveSessions: [LiveSessionStatus]
    /// What the running HKSV recording is currently producing, nil when none is running.
    public var recordingSession: RecordingSessionStatus?
    /// The main stream's codec/size/rate, as last measured (nil before the first picture).
    public var mainStreamInfo: SourceStreamInfo?
    /// The sub stream's codec/size/rate, nil when the camera has none configured or none has been measured yet.
    public var subStreamInfo: SourceStreamInfo?
    /// A note about how the camera's events are obtained, nil when nothing is unusual ("Camera events unreliable; using
    /// built-in motion detection").
    public var eventsNote: String?
    /// A note about Apple Home's contact with this camera, nil when nothing is unusual: a paired camera no Home device has
    /// connected to for a while ("Home hasn't contacted this camera for 12 min"; CameraBridge advertises it again).
    public var homeKitNote: String?
    /// The motion shadow test's numbers for this camera: nil when the test is off (`BridgeSettings.motionShadowTest`) or the
    /// camera does not use its own events for motion.
    public var motionShadow: MotionShadowStatus?

    public init(id: UUID, name: String, kind: CameraKind, vendor: CameraVendor, connection: ConnectionState = .idle,
                eventChannelConnected: Bool = false, videoSummary: String? = nil, isPaired: Bool = false, setupCode: String = "",
                setupURI: String = "", hapPort: UInt16? = nil, motionActive: Bool = false, recordingEnabled: Bool = false,
                recordingNow: Bool = false, liveViewers: Int = 0, lastEvent: String? = nil, lastEventDate: Date? = nil, lastError: String? = nil,
                recentEvents: [CameraEventRecord] = [], subStreamProblem: String? = nil, liveSessions: [LiveSessionStatus] = [],
                recordingSession: RecordingSessionStatus? = nil, mainStreamInfo: SourceStreamInfo? = nil, subStreamInfo: SourceStreamInfo? = nil,
                eventsNote: String? = nil, appViewers: Int = 0, homeKitNote: String? = nil, motionShadow: MotionShadowStatus? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.vendor = vendor
        self.connection = connection
        self.eventChannelConnected = eventChannelConnected
        self.videoSummary = videoSummary
        self.isPaired = isPaired
        self.setupCode = setupCode
        self.setupURI = setupURI
        self.hapPort = hapPort
        self.motionActive = motionActive
        self.recordingEnabled = recordingEnabled
        self.recordingNow = recordingNow
        self.liveViewers = liveViewers
        self.appViewers = appViewers
        self.lastEvent = lastEvent
        self.lastEventDate = lastEventDate
        self.lastError = lastError
        self.recentEvents = recentEvents
        self.subStreamProblem = subStreamProblem
        self.liveSessions = liveSessions
        self.recordingSession = recordingSession
        self.mainStreamInfo = mainStreamInfo
        self.subStreamInfo = subStreamInfo
        self.eventsNote = eventsNote
        self.homeKitNote = homeKitNote
        self.motionShadow = motionShadow
    }
}

/// One camera event: "Motion", "Doorbell ring", "Person", "Tamper", "Alarm input 2", … and when it started.
public struct CameraEventRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var date: Date

    public init(id: UUID = UUID(), name: String, date: Date) {
        self.id = id
        self.name = name
        self.date = date
    }
}

public struct SensorsBridgeStatus: Sendable, Equatable {
    public var isPaired: Bool
    public var setupCode: String
    public var setupURI: String
    public var accessoryCount: Int
    /// The sensors the bridge publishes for each camera, in bridge order (`SensorsBridge.sensors(for:)`; cameras without
    /// any are left out). The app lists these instead of working them out from the options: an alarm input, for
    /// example, is published only once the camera has reported it.
    public var publishedSensors: [UUID: [BridgedSensor]]

    public init(isPaired: Bool, setupCode: String, setupURI: String, accessoryCount: Int, publishedSensors: [UUID: [BridgedSensor]] = [:]) {
        self.isPaired = isPaired
        self.setupCode = setupCode
        self.setupURI = setupURI
        self.accessoryCount = accessoryCount
        self.publishedSensors = publishedSensors
    }
}

public enum EngineState: Sendable, Equatable { case stopped, starting, running, paused, failed(String) }

public enum LocalNetworkAccess: Sendable, Equatable { case unknown, granted, denied }

/// Engine-level errors surfaced to the app.
public enum EngineError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownCamera
    case duplicateCamera
    case cameraNotRunning
    case invalidSettings(String)
    case configurationUnavailable(String)
    /// `probeCamera` with no vendor and no stream URL: no Hikvision, Reolink or ONVIF interface answered at `host`.
    case noCameraAPI(host: String)

    public var description: String {
        switch self {
        case .unknownCamera: "There is no camera with this identifier."
        case .duplicateCamera: "A camera with this identifier already exists."
        case .cameraNotRunning: "The camera is not running."
        case .invalidSettings(let reason): "Invalid settings: \(reason)"
        case .configurationUnavailable(let reason): "The configuration could not be read: \(reason)"
        case .noCameraAPI(let host): "No supported camera API answered at \(host)."
        }
    }
}
