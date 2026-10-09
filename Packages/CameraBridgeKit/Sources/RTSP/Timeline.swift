import BridgeSupport
import Foundation

// Timing arithmetic on camera input saturates instead of trapping: timestamps, clock rates and sample rates come from
// the network, and an overflow trap would take down every camera of the bridge.
extension Int64 {
    func clampedAdding(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }

    func clampedSubtracting(_ other: Int64) -> Int64 {
        let (difference, overflow) = subtractingReportingOverflow(other)
        return overflow ? (other < 0 ? .max : .min) : difference
    }

    func clampedMultiplied(by other: Int64) -> Int64 {
        let (product, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? ((self < 0) == (other < 0) ? .max : .min) : product
    }

    /// `value` rounded to the nearest integer, clamped to the Int64 range; NaN is 0.
    init(saturating value: Double) {
        let rounded = value.rounded()
        if let exact = Int64(exactly: rounded) {
            self = exact
        } else if rounded.isNaN {
            self = 0
        } else {
            self = rounded < 0 ? .min : .max
        }
    }
}

/// RTP clock rates the timing code accepts (anything else is clamped): 1 Hz … 2^31 − 1 Hz. With these, every product
/// of a rate and a bounded interval fits in 64 bits.
let timingClockRateRange = 1...Int(Int32.max)

/// Extends 32-bit RTP timestamps to 64 bits. Each value is placed within ±2^31 of the previous one, so wraps (and
/// small steps backwards) keep a continuous timeline. Saturates at the ends of the Int64 range.
struct RTPTimestampUnwrapper: Sendable {
    private var last: Int64?

    init(last: Int64? = nil) {
        self.last = last
    }

    mutating func unwrap(_ timestamp: UInt32) -> Int64 {
        guard let last else {
            last = Int64(timestamp)
            return Int64(timestamp)
        }
        let delta = Int64(Int32(bitPattern: timestamp &- UInt32(truncatingIfNeeded: last)))
        let value = last.clampedAdding(delta)
        self.last = value
        return value
    }
}

/// Turns a track's unwrapped source timestamps into a strictly increasing timeline starting at 0.
///
/// Source spacing is kept, including bursty delivery (a cached GOP sent at once) and real gaps (the arrival clock
/// shows the same pause). A step is re-timed to the typical frame spacing when it is not positive, or when it is a
/// bogus forward jump: more than `jumpThreshold` ahead of the arrival clock and more than 4× the typical spacing
/// (Reolink cameras jump ~1.6 s after keyframes; before any spacing is known, more than 4 × `jumpThreshold` ahead),
/// or more than `maxLead` ahead of the arrival clock whatever the spacing (hostile or broken timestamps).
/// Later timestamps follow the re-timed base. Two camera habits get more than a re-timed step, because re-timing alone
/// would let the timeline run ahead of the camera at every occurrence: a repeated or slightly backward timestamp is given
/// a full interval, and the next forward step of more than one interval gives it back (`debt`); and keyframes stamped
/// ahead of the pictures after them (`keyframesRunAhead`, learned from the first such step back) are placed one interval
/// after their predecessor. The clock rate is clamped to `timingClockRateRange` and all arithmetic saturates, so no input
/// can trap.
struct TimestampSmoother: Sendable {
    let clockRate: Int
    let jumpThreshold: Int64
    let maxLead: Int64
    private var lastInput: Int64?
    private var lastOutput: Int64 = 0
    private var lastArrival: Date?
    private var typicalDelta: Double?
    private(set) var retimedCount = 0
    private var previousWasKeyframe = false
    /// This source stamps its keyframes ahead of the pictures after them (seen: a delta frame right after a keyframe steps
    /// back by more than two frame intervals; a Tapo stamps each IDR about seven frames ahead of its own P pictures'
    /// clock). Later keyframes that jump ahead are re-timed to one frame interval instead of being believed, which would
    /// put the timeline further ahead at every keyframe, for ever.
    private(set) var keyframesRunAhead = false
    /// Time the timeline stands ahead of the source because a repeated or slightly backward timestamp was given a full
    /// frame interval (cameras stamp two pictures alike, then catch up): the next forward steps larger than a frame
    /// interval give it back, so such stamps do not make the timeline run fast. At most `maximumDebtIntervals` intervals.
    private var debt: Double = 0
    static let maximumDebtIntervals = 4.0

    init(clockRate: Int, jumpThreshold: Duration = .milliseconds(500), maxLead: Duration = .seconds(60)) {
        let rate = min(max(clockRate, timingClockRateRange.lowerBound), timingClockRateRange.upperBound)
        self.clockRate = rate
        func ticks(_ duration: Duration) -> Int64 {
            Int64(saturating: duration.timeInterval * Double(rate))
        }
        self.jumpThreshold = max(1, ticks(jumpThreshold))
        self.maxLead = max(self.jumpThreshold, ticks(maxLead))
    }

    /// `isKeyframe`: the unit is a keyframe (video; see `keyframesRunAhead`).
    mutating func smooth(_ input: Int64, arrival: Date, isKeyframe: Bool = false) -> Int64 {
        var nextInput = input
        defer {
            lastInput = nextInput
            lastArrival = arrival
            previousWasKeyframe = isKeyframe
        }
        guard let lastInput, let lastArrival else { return 0 }
        let (delta, overflow) = input.subtractingReportingOverflow(lastInput)
        let elapsed = min(max(0, arrival.timeIntervalSince(lastArrival)), 1e6)   // NaN → 0
        let arrivalTicks = Int64(saturating: elapsed * Double(clockRate))           // ≤ 1e6 s × (2^31 − 1) Hz: no clamping in practice
        if !overflow, !isKeyframe, previousWasKeyframe, delta < 0,
           Double(delta.magnitude) > 2 * (typicalDelta ?? Double(clockRate) / 30) {
            keyframesRunAhead = true
        }
        let retime: Bool
        var aheadKeyframe = false
        if overflow || delta <= 0 {
            retime = true
        } else {
            let lead = delta - arrivalTicks   // delta > 0 and arrivalTicks ≥ 0: cannot overflow
            if lead > maxLead {
                retime = true
            } else if let typical = typicalDelta {
                aheadKeyframe = isKeyframe && keyframesRunAhead && Double(delta) > 2 * typical && Double(lead) > 2 * typical
                retime = aheadKeyframe || (lead > jumpThreshold && Double(delta) > 4 * typical)
            } else {
                retime = lead > 4 * jumpThreshold   // no spacing known yet: only a large lead is bogus
            }
        }
        var step: Int64
        if retime {
            step = typicalDelta.map { max(1, Int64(saturating: $0)) } ?? max(1, min(arrivalTicks, jumpThreshold))
            retimedCount += 1
            if aheadKeyframe {
                // The keyframe's own stamp says nothing about where it belongs: the pictures after it continue the earlier
                // pictures' clock, so measure them from where this one is placed.
                nextInput = lastInput.clampedAdding(step)
            } else if !overflow, delta <= 0, let typical = typicalDelta, Double(delta.magnitude) < typical {
                debt = min(debt + Double(step) - Double(max(0, delta)), Self.maximumDebtIntervals * typical)
            }
        } else {
            step = delta
            if let typical = typicalDelta {
                if debt > 0, Double(delta) > 1.5 * typical {
                    let repaid = min(debt, Double(delta) - typical)
                    step = delta - Int64(saturating: repaid)
                    debt -= repaid
                }
                if Double(delta) <= 4 * typical { typicalDelta = typical * 0.9 + Double(step) * 0.1 }
            } else {
                typicalDelta = Double(delta)
            }
        }
        lastOutput = lastOutput.clampedAdding(step)
        return lastOutput
    }
}

/// Decode times for a video track. RTP video timestamps are presentation times (RFC 6184 §5.1, RFC 7798 §4.1): a camera
/// that sends B-frames transmits in decode order, so the timestamps step back at every B-frame.
///
/// A step back is reordering when the unit is not a keyframe, its time is not within `minimumSeparation` of a recent
/// one (clock jitter, a repeated timestamp), at most `maximumDepth` (the H.264/H.265 decoded picture buffer) of the
/// last units are presented after it and it lies at most 1 s behind the newest. `reorderDepth` is the most such units
/// seen. Until the stream reorders, the decode time is the presentation time. Afterwards it is the (depth + 1)-th latest
/// presentation time so far: never after the unit's own (at most `depth` earlier units are presented later) and one
/// frame interval per unit on a regular stream; kept above the previous decode time, so it increases strictly (just
/// after the first reordered units, until the depth's worth of later units arrived, it may pass the presentation time).
/// A unit that steps back behind the IDR that starts its GOP is mis-stamped, not reordered (see `decodeTime`). A keyframe that steps back, or a larger step back, starts a new timeline: its time comes back unchanged (the
/// smoother re-times it) and the history restarts; jitter and repeats also come back unchanged, outside the history.
/// Arithmetic saturates.
struct DecodeTimeline: Sendable {
    static let maximumDepth = 16

    let maximumReorder: Int64
    let minimumSeparation: Int64
    private(set) var reorderDepth = 0
    /// Presentation times of the last ≤ `maximumDepth` + 1 units in decode order.
    private var recent: [Int64] = []
    private var lastDecode: Int64?
    /// Presentation time of the last keyframe when it starts a closed GOP (an IDR), until the next keyframe.
    private var closedKeyframeTime: Int64?

    init(clockRate: Int) {
        let rate = Int64(min(max(clockRate, timingClockRateRange.lowerBound), timingClockRateRange.upperBound))
        maximumReorder = rate                    // 1 s
        minimumSeparation = max(1, rate / 125)   // 8 ms: half a frame at 60 fps
    }

    /// The decode time of the next unit (decode order), presented at the unwrapped timestamp `pts`. `startsClosedGOP`: the
    /// keyframe is an IDR (H.264 type 5, HEVC IDR_W_RADL / IDR_N_LP), so no later picture is presented before it: a unit
    /// stamped at or before it is not reordered (nothing could be) but mis-stamped (a Tapo stamps its IDRs ahead of the
    /// pictures after them), and comes back unchanged for the smoother, outside the history.
    mutating func decodeTime(pts: Int64, isKeyframe: Bool, startsClosedGOP: Bool = false) -> Int64 {
        if !isKeyframe, let closedKeyframeTime, pts <= closedKeyframeTime { return pts }
        if isKeyframe { closedKeyframeTime = startsClosedGOP ? pts : nil }
        if let newest = recent.max(), pts <= newest {
            let presentedLater = recent.count { $0 > pts }
            if isKeyframe || newest.clampedSubtracting(pts) > maximumReorder || presentedLater > Self.maximumDepth {
                recent = [pts]
                lastDecode = pts
                return pts
            }
            let nearest = recent.map { $0.clampedSubtracting(pts).magnitude }.min() ?? 0
            guard nearest >= UInt64(minimumSeparation) else { return pts }
            reorderDepth = max(reorderDepth, presentedLater)
        }
        recent.append(pts)
        if recent.count > Self.maximumDepth + 1 { recent.removeFirst(recent.count - Self.maximumDepth - 1) }
        var decode = pts
        if reorderDepth > 0 {
            let latest = recent.sorted(by: >)
            decode = latest[min(reorderDepth, latest.count - 1)]
        }
        if let lastDecode, decode <= lastDecode { decode = lastDecode.clampedAdding(1) }
        lastDecode = decode
        return decode
    }
}

/// The part of an RTCP sender report (RFC 3550 §6.4.1) used for timing.
struct RTCPSenderReport: Sendable, Equatable {
    var ssrc: UInt32
    var ntp: UInt64
    var rtpTimestamp: UInt32

    /// Sender reports in a (compound) RTCP packet; malformed packets end the scan.
    static func parse(_ data: Data) -> [RTCPSenderReport] {
        var reader = ByteReader(data)
        var reports: [RTCPSenderReport] = []
        while reader.remaining >= 4 {
            guard let first = try? reader.readUInt8(), let type = try? reader.readUInt8(), let words = try? reader.readUInt16BE(),
                  first >> 6 == 2 else { break }
            let length = Int(words) * 4
            guard reader.remaining >= length, let body = try? reader.readBytes(length) else { break }
            guard type == 200 else { continue }
            var fields = ByteReader(body)
            guard let ssrc = try? fields.readUInt32BE(), let ntp = try? fields.readUInt64BE(), let rtp = try? fields.readUInt32BE() else {
                break
            }
            reports.append(RTCPSenderReport(ssrc: ssrc, ntp: ntp, rtpTimestamp: rtp))
        }
        return reports
    }
}

/// Wall clock for one track: the RTCP sender report's NTP ↔ RTP mapping when it agrees with the local arrival clock
/// within `tolerance` (a camera whose clock is wrong falls back), else the arrival time. Never goes backwards.
struct TrackWallClock: Sendable {
    let clockRate: Int
    let tolerance: TimeInterval
    private var report: RTCPSenderReport?
    private var lastWallClock: Date?
    private(set) var usingSenderReport = false

    init(clockRate: Int, tolerance: TimeInterval = 3) {
        self.clockRate = min(max(clockRate, timingClockRateRange.lowerBound), timingClockRateRange.upperBound)
        self.tolerance = tolerance
    }

    mutating func update(senderReport: RTCPSenderReport) {
        report = senderReport
    }

    mutating func wallClock(rtpTimestamp: UInt32, arrival: Date) -> Date {
        var wall = arrival
        usingSenderReport = false
        if let mapped = senderReportTime(rtpTimestamp: rtpTimestamp, arrival: arrival) {
            wall = mapped
            usingSenderReport = true
        }
        if let lastWallClock, wall < lastWallClock { wall = lastWallClock }
        lastWallClock = wall
        return wall
    }

    /// The camera's capture time of `rtpTimestamp` by the latest sender report when that agrees with `arrival` within
    /// `tolerance`, else nil. Pure: no monotonic clamping, no state change.
    func senderReportTime(rtpTimestamp: UInt32, arrival: Date) -> Date? {
        guard let report else { return nil }
        let delta = Double(Int32(bitPattern: rtpTimestamp &- report.rtpTimestamp)) / Double(clockRate)
        let mapped = NTPTime.date(from: report.ntp).addingTimeInterval(delta)
        return abs(mapped.timeIntervalSince(arrival)) <= tolerance ? mapped : nil
    }
}
