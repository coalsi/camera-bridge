import BridgeSupport
import Foundation

/// What a session's pipeline counted of its stream's troubles (`MediaPipeline.health`, `RTSPMediaSource.health()`).
public struct StreamHealth: Sendable, Equatable {
    /// RTP packets of the video that never came (sequence gaps).
    public var lostPackets = 0
    /// Stretches in which the picture froze until the next keyframe (a loss, a broken or oversize picture, the sender restarting).
    public var freezes = 0
    /// How long those stretches lasted in all, by arrival.
    public var frozenSeconds: Double = 0
    /// Pictures dropped while waiting for a keyframe.
    public var droppedAccessUnits = 0
    /// Timestamps the smoothing re-timed (a camera's bogus jumps or repeats).
    public var retimedSteps = 0
    /// Samples the consumer was too slow to take (`SampleDelivery`).
    public var consumerDrops = 0
    /// How far the audio was eased to stay on the video's clock in all (seconds; negative: moved back), `AudioDriftTracker`.
    public var audioEased: Double = 0

    public init() {}
}

/// Keeps a session's audio on its video's clock (`MediaPipeline`). Many cameras stamp audio by sample count (the converter's clock) and
/// video by their system timer; even 10 ppm apart is 0.9 s a day, and the box keeps one session for days. The two tracks are aligned once,
/// by their first units; this measures, over windows of `window`, how late each track's units arrive after their own times (the floor
/// of arrival − pts, which network jitter only raises), and compares the difference between the tracks with the first window's. When the
/// audio drifted more than `threshold` it is eased back in steps of at most `maximumStep` a window (no audible jump: the muxers drop an
/// overlap), until it is within `settled`. Only the change counts: an offset the session started with (one track packetized later) is not
/// drift.
struct AudioDriftTracker: Sendable {
    static let window: TimeInterval = 60
    static let threshold: TimeInterval = 0.1
    static let settled: TimeInterval = 0.02
    static let maximumStep: TimeInterval = 0.04

    private var reference: Date?
    private var windowStart: Date?
    private var videoFloor: Double?
    private var audioFloor: Double?
    private var baseline: Double?
    private var easing = false
    /// The audio's drift from the video at the last window (seconds; negative: the audio runs ahead).
    private(set) var drift: Double = 0
    /// Every step taken, summed.
    private(set) var eased: Double = 0

    private mutating func lag(_ pts: Double, _ arrival: Date) -> Double {
        let reference = self.reference ?? arrival
        self.reference = reference
        return arrival.timeIntervalSince(reference) - pts
    }

    /// A video unit, its decode time in seconds on the session timeline.
    mutating func noteVideo(pts: Double, arrival: Date) {
        let lag = lag(pts, arrival)
        videoFloor = min(videoFloor ?? lag, lag)
    }

    /// An audio unit, its time in seconds on the session timeline. When a window ends and the audio drifted: the step to add to the audio's
    /// times (seconds).
    mutating func noteAudio(pts: Double, arrival: Date) -> Double? {
        let lag = lag(pts, arrival)
        audioFloor = min(audioFloor ?? lag, lag)
        guard let windowStart else {
            self.windowStart = arrival
            return nil
        }
        guard arrival.timeIntervalSince(windowStart) >= Self.window else { return nil }
        defer {
            self.windowStart = arrival
            videoFloor = nil
            audioFloor = nil
        }
        guard let videoFloor, let audioFloor else { return nil }   // a window without video (it stalled) says nothing
        let difference = audioFloor - videoFloor
        guard let baseline else {
            self.baseline = difference
            return nil
        }
        drift = difference - baseline
        if abs(drift) > Self.threshold {
            easing = true
        } else if abs(drift) < Self.settled {
            easing = false
        }
        guard easing else { return nil }
        let step = min(max(drift, -Self.maximumStep), Self.maximumStep)
        eased += step
        return step
    }
}

/// Follows the video's frozen stretches for `StreamHealth` and the log: the first is logged when it ends, later ones as one summary at
/// most every `summaryInterval` (and when the session ends), so a camera on weak Wi-Fi is visible without filling the journal.
struct FreezeLog: Sendable {
    static let summaryInterval: TimeInterval = 300

    private var frozeAt: Date?
    private var lostAtFreeze = 0
    private var lastLogged: Date?
    /// Not logged yet: stretches, their seconds, the packets lost in them.
    private var pending = (count: 0, seconds: 0.0, lost: 0)

    /// The picture froze (it was delivering and now waits for a keyframe); `lostBefore`: the packets lost in the session before the
    /// packet that froze it.
    mutating func froze(at arrival: Date, lostBefore: Int) {
        guard frozeAt == nil else { return }
        frozeAt = arrival
        lostAtFreeze = lostBefore
    }

    /// A picture came out; ends a frozen stretch. Its length when it was one.
    mutating func delivered(at arrival: Date, lost: Int, log: Log) -> Double? {
        guard let frozeAt else { return nil }
        self.frozeAt = nil
        let seconds = max(0, arrival.timeIntervalSince(frozeAt))
        pending.count += 1
        pending.seconds += seconds
        pending.lost += max(0, lost - lostAtFreeze)
        if lastLogged.map({ arrival.timeIntervalSince($0) >= Self.summaryInterval }) ?? true { flush(at: arrival, log: log) }
        return seconds
    }

    /// Logs what is pending.
    mutating func flush(at arrival: Date, log: Log) {
        guard pending.count > 0 else { return }
        let seconds = String(format: "%.1f", pending.seconds)
        let cause = pending.lost > 0 ? "after \(pending.lost) lost packet\(pending.lost == 1 ? "" : "s")" : "after a broken picture"
        if pending.count == 1, lastLogged == nil {
            log.notice("The camera's picture froze for \(seconds) s, until its next keyframe, \(cause) (a weak network or a busy camera)")
        } else {
            log.notice("The camera's picture froze \(pending.count) time\(pending.count == 1 ? "" : "s") since the last report, \(seconds) s in all, "
                       + "each until the next keyframe, \(cause)")
        }
        lastLogged = arrival
        pending = (0, 0, 0)
    }
}
