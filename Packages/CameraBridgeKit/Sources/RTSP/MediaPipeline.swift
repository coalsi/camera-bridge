import BridgeSupport
import Foundation
import MediaCore
import RTP
import Synchronization

/// Delivers samples to a consumer through a stream with a bounded buffer (`.bufferingOldest(bufferLimit)`): a consumer
/// that falls `bufferLimit` samples behind loses the newest samples instead of letting memory grow at the camera's
/// bitrate. Video frames after a dropped one are held back until the next keyframe, so the output stays decodable;
/// dropped audio just leaves a gap.
struct SampleDelivery: Sendable {
    /// About 10 s of 30 fps video plus 50 audio frames per second.
    static let bufferLimit = 1024
    static let bufferingPolicy = AsyncThrowingStream<MediaSample, any Error>.Continuation.BufferingPolicy.bufferingOldest(bufferLimit)

    private let log: Log
    private var videoNeedsKeyframe = false
    private(set) var droppedCount = 0

    init(log: Log) {
        self.log = log
    }

    mutating func deliver(_ sample: MediaSample, to continuation: AsyncThrowingStream<MediaSample, any Error>.Continuation) {
        var isVideo = false
        if case .video(let frame) = sample {
            isVideo = true
            if videoNeedsKeyframe, !frame.isKeyframe {
                droppedCount += 1
                return
            }
        }
        switch continuation.yield(sample) {
        case .enqueued:
            if isVideo { videoNeedsKeyframe = false }
        case .dropped:
            if droppedCount == 0 { log.warning("Sample consumer is too slow; dropping samples (video resumes at the next keyframe)") }
            droppedCount += 1
            if isVideo { videoNeedsKeyframe = true }
        case .terminated:
            break
        @unknown default:
            break
        }
    }
}

/// Turns interleaved RTP/RTCP packets of the PLAYing tracks into `MediaSample`s.
///
/// Timing per track: RTP timestamps are unwrapped to 64 bits and smoothed (`TimestampSmoother`: strictly increasing,
/// bogus jumps re-timed); `pts` = track origin + smoothed ticks, where the origin aligns tracks on one session timeline
/// (the offset of the track's first unit from the session's first unit; see `origin`). Video RTP timestamps are
/// presentation times, which B-frames make step back in decode order: `DecodeTimeline` gives each video unit an
/// increasing decode time, the smoother runs on that, and the unit's own offset from it is added back, so `pts` keeps
/// the camera's presentation order and `dts` (set when it differs) increases strictly. Units stamped behind their GOP's
/// IDR are not taken for B-frames (a Tapo stamps its IDRs ahead of the pictures after them: `DecodeTimeline`,
/// `TimestampSmoother.keyframesRunAhead`), so a camera's timestamp quirks never push the video timeline away from the
/// audio's. Access units come from `VideoDepacketizer`, which ends them at picture boundaries, so pictures that share an
/// RTP timestamp are separate units with separate, increasing times. Video times use 90 kHz, audio
/// pts the sample rate. Wall clock: `TrackWallClock` (RTCP sender report mapping when plausible, else arrival).
/// Samples reach the stream through `SampleDelivery` (bounded buffer).
final class MediaPipeline: Sendable {
    struct TrackPlan: Sendable {
        var track: RTSPTrack
        var rtpChannel: UInt8
        var rtcpChannel: UInt8
        var videoFormat: VideoFormat?
        var audioFormat: AudioFormat?
    }

    /// What the stall watchdog looks at. `videoPacket`: the last RTP packet of the video track (of any track when the
    /// session has no video); RTCP and audio do not count, so a frozen video encoder is noticed while audio flows.
    /// `videoFrame`: the last delivered video frame (the pipeline's start before the first), which also catches video
    /// that arrives but can never be decoded (no keyframe, unsupported packetization).
    struct Progress: Sendable {
        var videoPacket: ContinuousClock.Instant
        var videoFrame: ContinuousClock.Instant
    }

    private struct TrackState {
        var plan: TrackPlan
        var video: VideoDepacketizer?
        var audio: AudioDepacketizer?
        var unwrapper = RTPTimestampUnwrapper()
        var decodeTimeline: DecodeTimeline
        var smoother: TimestampSmoother
        var wallClock: TrackWallClock
        var originTicks: Int64?
        var loggedParseFailure = false
    }

    /// The session's first unit (of whichever track delivered first): 0 on the session timeline.
    private struct SessionAnchor {
        var channel: UInt8
        var rtpTimestamp: UInt32
        var arrival: Date
    }

    private struct State {
        var tracks: [UInt8: TrackState] = [:]
        var rtcpChannels: [UInt8: UInt8] = [:]
        var anchor: SessionAnchor?
        var progress: Progress
        var hasVideo = false
        var delivery: SampleDelivery
        var finished = false
    }

    private let state: Mutex<State>
    private let continuation: AsyncThrowingStream<MediaSample, any Error>.Continuation
    private let log: Log

    /// Create `continuation`'s stream with `SampleDelivery.bufferingPolicy` for bounded buffering.
    init(plans: [TrackPlan], continuation: AsyncThrowingStream<MediaSample, any Error>.Continuation, log: Log) {
        self.continuation = continuation
        self.log = log
        let now = ContinuousClock.now
        var initial = State(progress: Progress(videoPacket: now, videoFrame: now), delivery: SampleDelivery(log: log))
        for plan in plans {
            let clockRate = max(1, plan.track.clockRate)
            var track = TrackState(plan: plan, decodeTimeline: DecodeTimeline(clockRate: clockRate), smoother: TimestampSmoother(clockRate: clockRate),
                                   wallClock: TrackWallClock(clockRate: clockRate))
            switch plan.track.kind {
            case .video:
                let codec: VideoCodec = plan.track.encoding == "H265" ? .hevc : .h264
                let don = Int(plan.track.fmtp["sprop-max-don-diff"] ?? "0") ?? 0
                track.video = VideoDepacketizer(codec: codec, format: plan.videoFormat, hevcDONPresent: don > 0, log: log)
                initial.hasVideo = true
            case .audio:
                track.audio = AudioDepacketizer(track: plan.track)
            case .backchannel:
                continue
            }
            initial.tracks[plan.rtpChannel] = track
            initial.rtcpChannels[plan.rtcpChannel] = plan.rtpChannel
        }
        state = Mutex(initial)
    }

    var progress: Progress { state.withLock { $0.progress } }

    /// Samples the consumer was too slow to take (see `SampleDelivery`).
    var droppedSampleCount: Int { state.withLock { $0.delivery.droppedCount } }

    func handle(channel: UInt8, payload: Data, arrival: Date) {
        state.withLock { s in
            guard !s.finished else { return }
            if let rtpChannel = s.rtcpChannels[channel] {
                for report in RTCPSenderReport.parse(payload) {
                    s.tracks[rtpChannel]?.wallClock.update(senderReport: report)
                }
                return
            }
            guard var track = s.tracks[channel] else { return }
            let now = ContinuousClock.now
            if track.video != nil || !s.hasVideo { s.progress.videoPacket = now }
            let packet: RTPPacket
            do {
                packet = try RTPPacket(parsing: payload)
            } catch {
                if !track.loggedParseFailure {
                    track.loggedParseFailure = true
                    s.tracks[channel] = track
                    log.warning("Dropping malformed RTP packet on channel \(channel): \(error)")
                }
                return
            }
            var samples: [MediaSample] = []
            if var depacketizer = track.video {
                for unit in depacketizer.push(packet) {
                    let (ticks, decodeTicks, wall) = timing(&track, channel: channel, rtpTimestamp: unit.rtpTimestamp, isKeyframe: unit.isKeyframe,
                                                            isIDR: unit.isIDR, arrival: arrival, state: &s)
                    let clockRate = Int32(clamping: track.smoother.clockRate)
                    let pts = MediaTime(value: ticks, timescale: clockRate).converted(to: 90_000)
                    let dts = MediaTime(value: decodeTicks, timescale: clockRate).converted(to: 90_000)
                    samples.append(.video(EncodedVideoFrame(format: unit.format, nalUnits: unit.nalUnits, isKeyframe: unit.isKeyframe, pts: pts,
                                                            dts: dts == pts ? nil : dts, wallClock: wall)))
                }
                if !samples.isEmpty { s.progress.videoFrame = now }
                track.video = depacketizer
            } else if var depacketizer = track.audio, let format = track.plan.audioFormat {
                for unit in depacketizer.push(packet) {
                    let (ticks, wall) = timing(&track, channel: channel, rtpTimestamp: unit.rtpTimestamp, arrival: arrival, state: &s)
                    let clockRate = Int32(clamping: track.smoother.clockRate)
                    var pts = MediaTime(value: ticks, timescale: clockRate)
                    if format.sampleRate > 0, Int32(clamping: format.sampleRate) != clockRate {
                        pts = pts.converted(to: Int32(clamping: format.sampleRate))
                    }
                    samples.append(.audio(EncodedAudioFrame(format: format, data: unit.data, pts: pts, sampleCount: unit.sampleCount, wallClock: wall)))
                }
                track.audio = depacketizer
            }
            s.tracks[channel] = track
            // Yielding under the lock keeps delivery state and stream order consistent; `yield` never calls back into
            // the pipeline.
            for sample in samples { s.delivery.deliver(sample, to: continuation) }
        }
    }

    /// Ends the sample stream (normally when `error` is nil). Later calls and packets are ignored.
    func finish(throwing error: (any Error)?) {
        let first = state.withLock { s in
            defer { s.finished = true }
            return !s.finished
        }
        guard first else { return }
        continuation.finish(throwing: error)
    }

    /// Presentation and decode ticks of a video unit (decode order) on the session timeline, and its wall clock.
    private func timing(_ track: inout TrackState, channel: UInt8, rtpTimestamp: UInt32, isKeyframe: Bool, isIDR: Bool,
                        arrival: Date, state: inout State) -> (Int64, Int64, Date) {
        let raw = track.unwrapper.unwrap(rtpTimestamp)
        let decode = track.decodeTimeline.decodeTime(pts: raw, isKeyframe: isKeyframe, startsClosedGOP: isIDR)
        let smoothed = track.smoother.smooth(decode, arrival: arrival, isKeyframe: isKeyframe)
        let wall = track.wallClock.wallClock(rtpTimestamp: rtpTimestamp, arrival: arrival)
        let origin = self.origin(&track, channel: channel, rtpTimestamp: rtpTimestamp, arrival: arrival, state: &state)
        let decodeTicks = origin.clampedAdding(smoothed)
        return (decodeTicks.clampedAdding(raw.clampedSubtracting(decode)), decodeTicks, wall)
    }

    /// Ticks of an audio unit on the session timeline, and its wall clock.
    private func timing(_ track: inout TrackState, channel: UInt8, rtpTimestamp: UInt32, arrival: Date, state: inout State) -> (Int64, Date) {
        let raw = track.unwrapper.unwrap(rtpTimestamp)
        let smoothed = track.smoother.smooth(raw, arrival: arrival)
        let wall = track.wallClock.wallClock(rtpTimestamp: rtpTimestamp, arrival: arrival)
        return (origin(&track, channel: channel, rtpTimestamp: rtpTimestamp, arrival: arrival, state: &state).clampedAdding(smoothed), wall)
    }

    /// The track's offset on the session timeline, fixed by its first unit. The session's first unit (`anchor`) is at
    /// 0. A later track's first unit is placed by the camera's capture times when this track and the anchor's both have
    /// a plausible RTCP sender report mapping (`TrackWallClock.senderReportTime`; the anchor's first timestamp is mapped
    /// by its track's current report), else by its arrival relative to the anchor's. Both ends of the difference always
    /// come from one clock, so a camera clock offset never becomes an A/V offset (as it would if one track's first unit
    /// were timed by the camera's clock and the other's by arrival: audio flows before the first report, video's first
    /// keyframe often comes after it). Never negative: a track whose first unit was captured before the anchor's
    /// starts at 0 — and when that track is video and the anchor audio (a camera that starts with the keyframe it kept,
    /// captured seconds before audio began to flow), the anchor's own origin moves forward by the difference instead, so
    /// the audio that follows is placed where the camera captured it relative to that video (kept at 0, it would trail
    /// the video by the age of that keyframe, and a recording would drop all of it as older than its first picture).
    /// Audio before the first video frame is never delivered to anything that needs its time (hub subscribers start at a
    /// keyframe), so moving its origin is safe. How each later track was placed is logged once.
    private func origin(_ track: inout TrackState, channel: UInt8, rtpTimestamp: UInt32, arrival: Date, state: inout State) -> Int64 {
        if let existing = track.originTicks { return existing }
        var seconds = 0.0
        var method = "arrival"
        if let anchor = state.anchor {
            seconds = arrival.timeIntervalSince(anchor.arrival)
            if let anchorCapture = state.tracks[anchor.channel]?.wallClock.senderReportTime(rtpTimestamp: anchor.rtpTimestamp, arrival: anchor.arrival),
               let capture = track.wallClock.senderReportTime(rtpTimestamp: rtpTimestamp, arrival: arrival) {
                seconds = capture.timeIntervalSince(anchorCapture)
                method = "sender reports"
            }
            if seconds < 0, track.plan.track.kind == .video, var anchorTrack = state.tracks[anchor.channel], anchorTrack.plan.track.kind == .audio {
                let shift = Int64(saturating: min(-seconds, 1e6) * Double(anchorTrack.smoother.clockRate))
                anchorTrack.originTicks = (anchorTrack.originTicks ?? 0).clampedAdding(shift)
                state.tracks[anchor.channel] = anchorTrack
                log.notice("RTSP: the video's first picture was captured \(String(format: "%.2f", -seconds)) s before the audio began (by \(method)): "
                           + "audio is placed that much later on the session timeline, so it stays aligned with that video")
                seconds = 0
            } else if state.tracks[anchor.channel] != nil {
                log.info("RTSP: \(track.plan.track.kind) starts \(String(format: "%.2f", max(0, seconds))) s after the \(anchorKind(state, anchor)) (by \(method))")
            }
        } else {
            state.anchor = SessionAnchor(channel: channel, rtpTimestamp: rtpTimestamp, arrival: arrival)
        }
        let origin = Int64(saturating: min(max(0, seconds), 1e6) * Double(track.smoother.clockRate))
        track.originTicks = origin
        return origin
    }

    private func anchorKind(_ state: State, _ anchor: SessionAnchor) -> String {
        state.tracks[anchor.channel].map { "\($0.plan.track.kind)" } ?? "first track"
    }
}
