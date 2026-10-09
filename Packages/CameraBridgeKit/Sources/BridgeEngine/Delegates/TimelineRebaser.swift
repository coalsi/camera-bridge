import Foundation
import MediaCore

/// Keeps one output timeline across ingest reconnects. A reconnected source starts a new timeline (its PTS go back or
/// jump far ahead) while a recording or live session keeps running on the `MediaHub` subscription; the muxer (strictly
/// increasing decode times) and RTP timestamps need the old timeline to continue. At such a jump the offset is reset so
/// the next video frame follows the last one by one frame interval (recordings: fMP4 decode times close the gap) or, when
/// frames come with their arrival time (live view), by the time that passed between the two frames' arrivals (at least
/// a frame interval): RTP time keeps pace with real time, as the RTCP sender reports' RTP time does, across a camera's
/// outage or a step longer than `maximumForwardJump` (the restamped first keyframe → the next of a GOP over 10 s).
/// Audio (same source clock) uses the same offset. Without a jump every timestamp passes through unchanged.
///
/// Frames are compared by decode time when they carry one (which must increase), else by presentation time against the
/// latest one seen. Without decode times, B-frames step back a little: a frame other than a keyframe up to
/// `maximumReorder` behind is reordering and passes unchanged; a keyframe that does not move forward (a reconnected
/// source restarts at a keyframe: hub subscribers wait for one) or a larger step back is a new timeline.
struct TimelineRebaser: Sendable {
    /// Forward jumps beyond this count as a new timeline.
    static let maximumForwardJump = 10.0
    /// Backward steps of frames without decode times up to this (seconds) are frame reordering.
    static let maximumReorder = 1.0

    /// Seconds added to source timestamps.
    private(set) var offset = 0.0
    private(set) var discontinuities = 0
    private var lastVideo: Double?
    /// When the frame at `lastVideo` arrived (frames given with their arrival).
    private var lastArrival: ContinuousClock.Instant?
    private var frameInterval = 1.0 / 30

    /// `frame` on the output timeline; `arrival`: when it reached the bridge (live view), on a monotonic clock.
    mutating func video(_ frame: EncodedVideoFrame, arrival: ContinuousClock.Instant? = nil) -> EncodedVideoFrame {
        let raw = (frame.dts ?? frame.pts).seconds
        var adjusted = raw + offset
        if let last = lastVideo {
            let step = adjusted - last
            let reordered = frame.dts == nil && !frame.isKeyframe && step < 0 && step >= -Self.maximumReorder
            if !reordered, step <= 0 || step > Self.maximumForwardJump {
                var gap = frameInterval
                if let arrival, let lastArrival {
                    let elapsed = Double((arrival - lastArrival) / .milliseconds(1)) / 1000
                    if elapsed.isFinite { gap = max(frameInterval, elapsed) }
                }
                offset = last + gap - raw
                adjusted = raw + offset
                discontinuities += 1
            } else if step > 0, step < 1 {
                frameInterval = step
            }
        }
        if adjusted >= (lastVideo ?? -.infinity) { lastArrival = arrival }
        lastVideo = max(lastVideo ?? adjusted, adjusted)
        guard offset != 0 else { return frame }
        var shifted = frame
        shifted.pts = Self.shift(frame.pts, by: offset)
        shifted.dts = frame.dts.map { Self.shift($0, by: offset) }
        return shifted
    }

    /// `frame` on the output timeline with the current offset, without moving the rebaser: a frame of this source's timeline
    /// that was already seen (the hub's newest GOP again, for a rebuild). Frames of a reconnected source come first through
    /// `video`, which keeps the offset.
    func shifted(_ frame: EncodedVideoFrame) -> EncodedVideoFrame {
        guard offset != 0 else { return frame }
        var shifted = frame
        shifted.pts = Self.shift(frame.pts, by: offset)
        shifted.dts = frame.dts.map { Self.shift($0, by: offset) }
        return shifted
    }

    /// `frame` on the output timeline (same offset as video).
    func audio(_ frame: EncodedAudioFrame) -> EncodedAudioFrame {
        guard offset != 0 else { return frame }
        var shifted = frame
        shifted.pts = Self.shift(frame.pts, by: offset)
        return shifted
    }

    private static func shift(_ time: MediaTime, by seconds: Double) -> MediaTime {
        let ticks = (seconds * Double(time.timescale)).rounded()
        guard ticks.isFinite, abs(ticks) < 9e15 else { return time }
        return MediaTime(value: time.value &+ Int64(ticks), timescale: time.timescale)
    }
}
