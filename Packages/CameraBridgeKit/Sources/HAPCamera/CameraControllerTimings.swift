import Foundation

/// Timers of `CameraController`: recording streams (research brief §3.8 "Closing") and the streaming delegate's
/// deadline. Tests shorten them.
public struct CameraControllerTimings: Sendable, Equatable {
    /// After the last packet was sent (the delegate's `isLast`, or the packet the cap backstop forces last), the hub
    /// must acknowledge (or close) within this time; otherwise the stream is closed with reason `.cancelled`. 12 s.
    public var recordingAcknowledgeTimeout: Duration
    /// A closed recording stream must stop sending within this time; otherwise the failure is logged and the HDS
    /// connection is closed to free it. The `dataSend/close` event must also have gone out by then. 10 s.
    public var recordingStopTimeout: Duration
    /// Recordings are capped at this length (3 minutes). The recording delegate owns the cap: once its stream has run
    /// this long it marks its next packet last, at a fragment boundary, which can come up to one fragment later and as
    /// two packets (one keyframe closing two fragments). The controller only backstops a delegate that does not: the
    /// first packet after this, plus the selected fragment length, plus `recordingCapGrace` is sent as the last one.
    public var maximumRecordingDuration: Duration
    /// How much longer than `maximumRecordingDuration` plus one fragment the delegate has to end its stream itself
    /// (its own clock starts after the open was answered and its fragments are paced) before the controller's backstop
    /// marks the next packet last. 5 s.
    public var recordingCapGrace: Duration
    /// Deadline of each `prepareStream` / `handleStreamRequest` call: one that misses it fails its HAP request with
    /// -70408 (below HAP's 9 s handler timeout) and the stream service moves on. 8 s.
    public var streamingDelegateTimeout: Duration
    /// A stream session that was prepared (SetupEndpoints answered) but never started is ended after this long, so the
    /// camera is not left "in use" by a controller that gave up or whose connection died between the two writes
    /// (Home would show the camera busy and refuse every later live view). 20 s.
    public var preparedSessionTimeout: Duration
    /// A new SetupEndpoints finds the service busy with a session that was prepared but never started: when that session is
    /// older than this (or belongs to the same controller or HAP connection) it is ended and the new one admitted. 15 s.
    public var staleUnstartedSessionAge: Duration

    public init(recordingAcknowledgeTimeout: Duration = .seconds(12), recordingStopTimeout: Duration = .seconds(10),
                maximumRecordingDuration: Duration = .seconds(180), recordingCapGrace: Duration = .seconds(5),
                streamingDelegateTimeout: Duration = .seconds(8), preparedSessionTimeout: Duration = .seconds(20),
                staleUnstartedSessionAge: Duration = .seconds(15)) {
        self.recordingAcknowledgeTimeout = recordingAcknowledgeTimeout
        self.recordingStopTimeout = recordingStopTimeout
        self.maximumRecordingDuration = maximumRecordingDuration
        self.recordingCapGrace = recordingCapGrace
        self.streamingDelegateTimeout = streamingDelegateTimeout
        self.preparedSessionTimeout = preparedSessionTimeout
        self.staleUnstartedSessionAge = staleUnstartedSessionAge
    }

    /// 12 s acknowledge timeout, 10 s stop timeout, 3-minute cap (backstopped one fragment + 5 s later), 8 s streaming
    /// delegate deadline, 20 s to start a prepared stream session (a new setup supersedes an unstarted one after 15 s).
    public static let standard = CameraControllerTimings()

    /// When the controller's backstop marks a recording's next packet last: the cap, plus one fragment of
    /// `fragmentLength`, plus the grace.
    func recordingBackstop(fragmentLength: Duration) -> Duration {
        maximumRecordingDuration + max(.zero, fragmentLength) + recordingCapGrace
    }
}
