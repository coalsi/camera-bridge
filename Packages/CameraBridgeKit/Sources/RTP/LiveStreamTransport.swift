import Foundation
import Synchronization

/// Every timing and threshold of a live session's transport protection, in one place so tests run in milliseconds. The
/// defaults are the production values (see the live-view hardening contract: the pipeline recovers at 4 s, these are the
/// session-level backstops).
public struct LiveStreamTimings: Sendable, Equatable {
    // MARK: Pacing and send errors

    /// A video frame's packets go out in chunks of at most this many (the kernel's send queue holds about 128 datagrams).
    public var pacingChunkPackets = 24
    /// The pause between two chunks of one frame.
    public var pacingGap: Duration = .milliseconds(1)
    /// No frame is held back longer than this by pacing: a frame needing more gaps gets bigger chunks.
    public var maximumFrameDelay: Duration = .milliseconds(20)
    /// ENOBUFS / EAGAIN / EINTR: the wait before sending the packet again.
    public var sendRetryDelay: Duration = .milliseconds(1)
    public var sendRetries = 10
    /// Replayed (catch-up) frames are sent at this multiple of the negotiated maximum bit rate.
    public var catchUpBitrateFactor = 2.0
    /// A lost video packet asks for a fresh keyframe, at most this often.
    public var lossKeyframeRequestInterval: Duration = .seconds(1)
    /// Losses closer together than this are one incident (one WARNING).
    public var lossIncidentGap: Duration = .seconds(5)
    /// A fatal send error (no route, address gone, network down) that nothing succeeded after for this long ends the session.
    public var fatalSendErrorAfter: Duration = .seconds(2)

    // MARK: Liveness

    /// No video packet sent this long after the start: the session ends (`.noVideoAtStart`).
    public var noVideoAtStart: Duration = .seconds(10)
    /// No video packet sent this long mid-session: the session ends (`.sourceStalled`).
    public var sourceStalled: Duration = .seconds(8)
    /// A stream that sent no media for this long sends no sender reports (they would extrapolate a dead stream's clock).
    public var senderReportStaleAfter: Duration = .seconds(5)
    /// How often the watchdog looks (it also wakes for the controller timeout's deadline).
    public var watchdogTick: Duration = .milliseconds(500)

    // MARK: Blind controller

    /// Receiver reports showing the controller gets none of our video for this long: warn and try other interfaces.
    public var blindAfter: Duration = .seconds(3)
    /// ... and this long (from the same moment): end the session so Home retries.
    public var endBlindAfter: Duration = .seconds(10)
    /// The pause between two interface flips while blind.
    public var interfaceFlipInterval: Duration = .seconds(3)
    /// The session must be this old before it can be judged blind.
    public var minimumSessionAge: Duration = .seconds(4)
    /// Receiver reports (after the first video packet) a judgement needs.
    public var minimumReports = 3
    /// Video packets sent during the symptom a judgement needs ("not receiving" with nothing sent is a stalled source).
    public var minimumPacketsSent = 30
    public var minimumPacketsSentWhileFrozen = 50
    /// A `fractionLost` (1/256) from here on counts as nothing received.
    public var heavyLossFraction: UInt8 = 230

    // MARK: Latching

    /// A different source than the one latched is followed only after the latched one was silent this long.
    public var relatchAfter: Duration = .seconds(5)

    public init() {}

    public static let standard = LiveStreamTimings()

    /// A report is evidence only while it is recent.
    var staleReportAfter: Duration { max(blindAfter * 2, .milliseconds(1)) }
}

/// How a live stream's sockets were set up and who is told when the transport misbehaves, carried by the video socket from
/// `prepareStream` to the session (`LiveStreamSession` reads it when it starts). The streaming delegate fills it; every
/// field is optional, so sessions built without it (tests, other callers) behave as before.
public final class LiveStreamTransport: Sendable {
    public struct Values: Sendable {
        /// The address the sockets are bound to, nil for the wildcard.
        public var boundSource: String?
        /// How the sockets were bound, in words ("accessory address 192.0.2.25 on en1").
        public var strategy = "wildcard"
        /// How the destination was chosen, in words (`StreamAddress.ControllerRoute.summary`).
        public var route: String?
        /// Interfaces to scope the sockets to, one at a time, while the controller receives nothing; nil clears the scope.
        public var recoveryScopes: [String?] = []
        /// The negotiated maximum video bit rate, for pacing a replay; nil: no replay pacing.
        public var maxBitrateKbps: Int?
        /// Replaces `LiveStreamSession`'s own timings (tests).
        public var timings: LiveStreamTimings?
        /// The controller keeps answering but receives none of our video (said once per incident).
        public var onControllerNotReceiving: (@Sendable (_ symptom: String) -> Void)?
        /// The controller's first receiver report that shows our video arriving (once per session): it receives.
        public var onControllerReceiving: (@Sendable () -> Void)?
        /// A fatal send error persisted (`code` is the errno, `text` its description, `localNetworkDenied` whether it is the
        /// error macOS gives an app without the Local Network permission, or behind a firewall: EHOSTUNREACH, EPERM).
        public var onFatalSendError: (@Sendable (_ code: Int32, _ text: String, _ localNetworkDenied: Bool) -> Void)?

        public init() {}
    }

    private let state = Mutex(Values())

    public init() {}

    public var values: Values { state.withLock { $0 } }

    public func update(_ change: (inout Values) -> Void) {
        state.withLock { change(&$0) }
    }
}
