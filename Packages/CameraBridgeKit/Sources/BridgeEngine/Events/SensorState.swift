import CameraAdapters
import Foundation

/// Which part of the bridge reported a camera event; decides how starts and stops are read (`EventRouter`).
public enum EventOrigin: String, Sendable, Codable, CaseIterable {
    /// The camera's event channel (`CameraDriver.makeEventSource()`); reports ends (CameraAdapters already holds
    /// pulses, 20 s for Hikvision).
    case camera
    /// `SoftMotionDetector` on the decoded sub stream; reports ends (10 s after the last movement).
    case softMotion
    /// `WebhookServer`: starts are pulses (held), a stop ends the webhook's own hold at once.
    case webhook
    /// The media ingest (`CameraRuntime`), e.g. `.authenticationFailed` for an RTSP 401; reports ends.
    case stream
    /// App or developer actions (`triggerMotion`): pulses.
    case user

    /// Whether this origin reports the end of every state it starts. Starts from other origins are pulses.
    public var reportsEnds: Bool {
        switch self {
        case .camera, .softMotion, .stream: true
        case .webhook, .user: false
        }
    }
}

/// One camera's debounced event state (`EventRouter` output): what the camera accessory (MotionDetected, sensor status)
/// and the sensors bridge show.
public struct SensorState: Sendable, Equatable, Identifiable {
    public static let credentialsRejectedMessage = "Camera rejected the username or password"

    /// The camera.
    public var id: UUID
    /// MotionDetected (HKSV recording trigger).
    public var motion: Bool
    /// Detections currently held (60 s after the last one).
    public var objects: Set<DetectedObjectKind>
    public var tampered: Bool
    public var audioAlarm: Bool
    /// nil until the camera reports day/night.
    public var isNight: Bool?
    /// Alarm inputs by id; every input the camera reported stays listed (at most `EventRouter.maximumInputsPerCamera`).
    public var digitalInputs: [String: Bool]
    public var temperature: Double?
    public var humidity: Double?
    /// nil while the camera has no event channel (none yet, or its source was reset).
    public var eventChannelConnected: Bool?
    /// The ingest's connection state as reported by `setStreamConnection` (`.idle` until then).
    public var streamConnection: ConnectionState
    /// The camera (event channel or stream) rejected the username or password.
    public var credentialsRejected: Bool
    public var isEnabled: Bool
    /// "Motion", "Doorbell ring", "Person", "Tamper", "Alarm input 2", … (rising edges).
    public var lastEvent: String?
    public var lastEventDate: Date?
    public var lastRingDate: Date?
    /// Every rising edge `lastEvent` names, oldest first, at most `EventRouter.recentEventLimit` (the camera page's
    /// "Recent Events", whatever the log level).
    public var recentEvents: [CameraEventRecord]

    public init(id: UUID, motion: Bool = false, objects: Set<DetectedObjectKind> = [], tampered: Bool = false, audioAlarm: Bool = false,
                isNight: Bool? = nil, digitalInputs: [String: Bool] = [:], temperature: Double? = nil, humidity: Double? = nil,
                eventChannelConnected: Bool? = nil, streamConnection: ConnectionState = .idle, credentialsRejected: Bool = false,
                isEnabled: Bool = true, lastEvent: String? = nil, lastEventDate: Date? = nil, lastRingDate: Date? = nil,
                recentEvents: [CameraEventRecord] = []) {
        self.id = id
        self.motion = motion
        self.objects = objects
        self.tampered = tampered
        self.audioAlarm = audioAlarm
        self.isNight = isNight
        self.digitalInputs = digitalInputs
        self.temperature = temperature
        self.humidity = humidity
        self.eventChannelConnected = eventChannelConnected
        self.streamConnection = streamConnection
        self.credentialsRejected = credentialsRejected
        self.isEnabled = isEnabled
        self.lastEvent = lastEvent
        self.lastEventDate = lastEventDate
        self.lastRingDate = lastRingDate
        self.recentEvents = recentEvents
    }

    /// `.disabled` for a disabled camera, `.offline(credentialsRejectedMessage)` after rejected credentials, else the
    /// stream's state.
    public var connection: ConnectionState {
        if !isEnabled { return .disabled }
        if credentialsRejected { return .offline(Self.credentialsRejectedMessage) }
        return streamConnection
    }

    public var lastError: String? {
        if case .offline(let reason) = connection { return reason }
        return nil
    }

    /// StatusFault: the camera is offline, rejected the credentials, or its event channel is down.
    public var isFault: Bool {
        guard isEnabled else { return false }
        if case .offline = connection { return true }
        return eventChannelConnected == false
    }

    /// StatusActive: enabled and not faulted.
    public var isActive: Bool { isEnabled && !isFault }

    /// Bridged sensors answer reads (false → "No Response"): not while the camera is offline or disabled.
    public var isReachable: Bool {
        switch connection {
        case .offline, .disabled: false
        case .idle, .connecting, .online: true
        }
    }

    /// Copies what the router knows into the camera's status: connection, event channel, motion, last event, last error.
    public func apply(to status: inout CameraStatus) {
        status.connection = connection
        status.eventChannelConnected = eventChannelConnected == true
        status.motionActive = motion
        status.lastEvent = lastEvent
        status.lastEventDate = lastEventDate
        status.recentEvents = recentEvents
        status.lastError = lastError
    }
}

/// What the router reports; `.state` follows every change of a camera's `SensorState`.
public enum EventRouterOutput: Sendable, Equatable {
    /// MotionDetected on the camera accessory changed.
    case motion(cameraID: UUID, active: Bool)
    /// A (deduplicated) doorbell press: `CameraController.ringDoorbell()`. The motion pulse follows as `.motion`.
    case doorbell(cameraID: UUID)
    case state(SensorState)
}
