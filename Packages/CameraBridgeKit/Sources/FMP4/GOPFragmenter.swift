import Foundation
import MediaCore

/// One keyframe-aligned group of samples for `FMP4Muxer.fragment(_:)`.
public struct FragmentGroup: Sendable {
    public var video: [EncodedVideoFrame]
    public var audio: [EncodedAudioFrame]
    /// Decode time (`dts ?? pts`) of the keyframe that closed the group, where the next group starts. The muxer ends the
    /// group's last video sample there, so each fragment's tfdt equals the previous tfdt plus its sample durations. nil when
    /// no successor is known (a flushed or cut-off group, or a timeline that jumped backwards).
    public var nextDecodeTime: MediaTime?

    public init(video: [EncodedVideoFrame], audio: [EncodedAudioFrame], nextDecodeTime: MediaTime? = nil) {
        self.video = video
        self.audio = audio
        self.nextDecodeTime = nextDecodeTime
    }
}

/// Groups samples into keyframe-aligned fragments.
///
/// Closing rule, evaluated at each keyframe K of an open fragment that started at S (elapsed e = K − S, last GOP g = K − the
/// previous keyframe, tolerance t = target / 20, jitter allowance a = min(t, 50 ms)):
/// - e ≥ target − t: the fragment is full (covers "GOP ≥ target → every keyframe" and absorbs a GOP a frame short of target);
/// - e + g > target + a: another GOP of the same length would overflow the target (HKSV: a fragment is no longer than
///   `fragmentLength`), so 3 s or 2.1 s GOPs with a 4 s target give one-GOP fragments rather than 6 s or 4.2 s ones; `a`
///   only absorbs timestamp jitter;
/// - K before the fragment's latest keyframe: the source timeline jumped backwards; the old fragment is closed as is.
/// So 2 s GOPs with a 4 s target give 2-GOP fragments, 4 s GOPs one GOP per fragment.
///
/// Otherwise K joins the fragment as its pending GOP. The guess that the next GOP is as long as the last one fails when the
/// GOP length varies (a frame-rate drop at night, a GOP cut short by a reconnect, irregular IDR spacing), so the merge only
/// stands while the fragment, measured in decode time (`dts ?? pts`) as the muxer writes it, stays within target + a. As
/// soon as a frame of the pending GOP starts past that, or the next keyframe comes later than that, [S, K) is returned
/// (ending at K's decode time) and [K, …) stays open on its own; `flushGroups()` splits the same way when the flushed tail
/// would end past it. So a fragment of more than one GOP is never longer than target + a; only a single GOP longer than the
/// target, which cannot be split, makes a longer fragment. No latency is added: [S, K) goes out no later than the next
/// keyframe, where it would have closed anyway.
///
/// Bounds: an open fragment that would span more than `max(4 × target, 30 s)` of video, or hold more than
/// `maximumFragmentFrames` video frames, `maximumFragmentAudioFrames` audio frames or `maximumFragmentBytes` of NAL data
/// (a lost IDR, a smart-codec GOP far beyond HKSV's 4 s) is returned as is, without `nextDecodeTime`; the fragmenter then
/// drops delta frames until the next keyframe, holding audio as before the first keyframe.
///
/// Audio goes to the fragment whose video span [S, next S) covers its pts: audio that arrives before the keyframe closing its
/// fragment but belongs after it moves on with the next fragment. Audio pushed before the first keyframe is held (bounded) and
/// kept only if it does not precede that keyframe. Audio that arrives after its fragment was returned goes into the open
/// fragment (the muxer still times it by its own pts). Audio further than `max(target, 2 s)` ahead of the boundary is treated
/// as a misaligned clock and stays in arrival order. Video delta frames before the first keyframe are dropped.
public struct GOPFragmenter: Sendable {
    /// Target, tolerance, jitter allowance, audio horizon and maximum fragment span in seconds.
    private let target: Double
    private let tolerance: Double
    private let overflowAllowance: Double
    private let audioHorizon: Double
    private let maximumDuration: Double
    private var open: Fragment?
    /// Audio received while no fragment is open (before the first keyframe, or after a cut-off).
    private var pendingAudio: [EncodedAudioFrame] = []

    /// Bound on `pendingAudio` (≈ 20 s of 1024-sample AAC at 48 kHz).
    static let pendingAudioLimit = 1_024
    /// Bounds on an open fragment (30 s at 60 fps is 1 800 frames; 30 s of 48 kHz AAC is 1 407 frames).
    static let maximumFragmentFrames = 4_096
    static let maximumFragmentAudioFrames = 4_096
    static let maximumFragmentBytes = 64 << 20

    /// The longest video span an open fragment may reach, in seconds.
    static func maximumFragmentDuration(target: Double) -> Double { max(4 * target, 30) }

    private struct Fragment: Sendable {
        var start: MediaTime
        var video: [EncodedVideoFrame]
        var audio: [EncodedAudioFrame]
        /// Length-prefixed video bytes held.
        var bytes: Int
        /// The last GOP while it is not known to fit (type doc): it starts at `video[index]`, after `bytes` of video.
        var pending: (index: Int, bytes: Int)?

        /// Presentation time of the latest keyframe held.
        var latestKeyframe: MediaTime { pending.map { video[$0.index].pts } ?? start }
    }

    public init(targetDuration: Duration) {
        let components = targetDuration.components
        let seconds = max(0, Double(components.seconds) + Double(components.attoseconds) * 1e-18)
        self.target = seconds
        self.tolerance = seconds / 20
        self.overflowAllowance = min(seconds / 20, 0.05)
        self.audioHorizon = max(seconds, 2)
        self.maximumDuration = Self.maximumFragmentDuration(target: seconds)
    }

    /// Returns completed fragments (each starts with a keyframe). A fragment closes at the next keyframe once ≥ targetDuration,
    /// or at every keyframe if GOP ≥ targetDuration — and early when one more GOP would overflow the target, or when the GOP
    /// that joined it turns out not to fit (then before that GOP, possibly at one of its delta frames; type doc).
    public mutating func push(_ sample: MediaSample) -> [(video: [EncodedVideoFrame], audio: [EncodedAudioFrame])] {
        pushGroups(sample).map { ($0.video, $0.audio) }
    }

    /// The open fragment (nil if none), after which the fragmenter starts over and waits for a keyframe. It is returned whole
    /// even when its pending GOP makes it, muxed, up to one frame interval longer than target + allowance; `flushGroups()`
    /// splits it then.
    public mutating func flush() -> (video: [EncodedVideoFrame], audio: [EncodedAudioFrame])? {
        flushGroup().map { ($0.video, $0.audio) }
    }

    /// `push(_:)` with each group's `nextDecodeTime`; pass the groups to `FMP4Muxer.fragment(_:)`.
    public mutating func pushGroups(_ sample: MediaSample) -> [FragmentGroup] {
        switch sample {
        case .video(let frame):
            return pushVideo(frame)
        case .audio(let frame):
            guard open != nil else {
                holdPending(frame)
                return []
            }
            if (open?.audio.count ?? 0) >= Self.maximumFragmentAudioFrames {
                let cut = cutOff()
                holdPending(frame)
                return cut
            }
            open?.audio.append(frame)
            return []
        }
    }

    /// `flush()` as a group (without `nextDecodeTime`).
    public mutating func flushGroup() -> FragmentGroup? {
        let tail = open
        open = nil
        pendingAudio = []
        return tail.map { FragmentGroup(video: $0.video, audio: $0.audio) }
    }

    /// The open fragment as groups (empty if none), after which the fragmenter starts over: one group (as `flushGroup()`),
    /// or two when its pending GOP would make it, muxed as a tail (the last frame repeats the previous frame's duration),
    /// longer than target + allowance — the fragment up to that GOP (ending at its keyframe), then the GOP without
    /// `nextDecodeTime`. Use this to end a recording, so its last fragments stay within the target too.
    public mutating func flushGroups() -> [FragmentGroup] {
        var groups: [FragmentGroup] = []
        if pendingTailWouldOverflow, let confirmed = splitOffPending() { groups.append(confirmed) }
        if let tail = flushGroup() { groups.append(tail) }
        return groups
    }

    private mutating func pushVideo(_ frame: EncodedVideoFrame) -> [FragmentGroup] {
        let size = frame.nalUnits.reduce(0) { $0 + 4 + $1.count }
        guard frame.isKeyframe else {
            guard open != nil else { return [] }                          // no keyframe yet: undecodable, dropped
            var groups: [FragmentGroup] = []
            if pendingWouldOverflow(with: frame), let confirmed = splitOffPending() { groups.append(confirmed) }
            if wouldExceedBounds(adding: frame, size: size) { return groups + cutOff() }   // this delta frame is dropped too
            open?.video.append(frame)
            open?.bytes += size
            return groups
        }
        guard let latest = open?.latestKeyframe else {
            // Audio preceding the first keyframe belongs to no fragment and is dropped.
            let kept = split(pendingAudio, at: frame.pts).after
            pendingAudio = []
            open = Fragment(start: frame.pts, video: [frame], audio: kept, bytes: size)
            return []
        }
        if frame.pts < latest, let closed = open {
            // The timeline jumped backwards: the old fragment is closed as is.
            open = Fragment(start: frame.pts, video: [frame], audio: [], bytes: size)
            return [FragmentGroup(video: closed.video, audio: closed.audio)]
        }
        var groups: [FragmentGroup] = []
        // The pending GOP ends here: it stays in the fragment only while the fragment fits.
        if let first = open?.video.first, open?.pending != nil {
            if (Self.decodeTime(frame) - Self.decodeTime(first)).seconds > limit {
                if let confirmed = splitOffPending() { groups.append(confirmed) }
            } else {
                open?.pending = nil
            }
        }
        guard let start = open?.start else { return groups }
        let elapsed = (frame.pts - start).seconds
        let gop = (frame.pts - latest).seconds
        let closes = elapsed >= target - tolerance || elapsed + gop > limit
        guard closes || wouldExceedBounds(adding: frame, size: size), let closed = open else {
            // Another GOP of the last one's length would fit: this one joins as the pending GOP.
            let index = open?.video.count ?? 0, bytes = open?.bytes ?? 0
            open?.pending = (index: index, bytes: bytes)
            open?.video.append(frame)
            open?.bytes += size
            return groups
        }
        let (kept, carried) = split(closed.audio, at: frame.pts)
        open = Fragment(start: frame.pts, video: [frame], audio: carried, bytes: size)
        return groups + [FragmentGroup(video: closed.video, audio: kept, nextDecodeTime: Self.decodeTime(frame))]
    }

    /// target + jitter allowance: the longest a fragment of more than one GOP may be.
    private var limit: Double { target + overflowAllowance }

    private static func decodeTime(_ frame: EncodedVideoFrame) -> MediaTime { frame.dts ?? frame.pts }

    /// Whether the open fragment would certainly run past `limit` with `frame` (a delta frame of its pending GOP) in it: the
    /// frame itself starts past it. (Predicting its end from the last frame interval would split needlessly after a dropped
    /// frame; the next keyframe and `flushGroups()` measure exactly.) Non-mutating, like `wouldExceedBounds`.
    private func pendingWouldOverflow(with frame: EncodedVideoFrame) -> Bool {
        guard let open, open.pending != nil, let first = open.video.first else { return false }
        return (Self.decodeTime(frame) - Self.decodeTime(first)).seconds > limit
    }

    /// Whether the open fragment, muxed as a flushed tail (its last frame repeats the previous frame's duration), would run
    /// past `limit` with its pending GOP in it.
    private var pendingTailWouldOverflow: Bool {
        guard let open, open.pending != nil, open.video.count >= 2, let first = open.video.first, let last = open.video.last else { return false }
        let end = Self.decodeTime(last), previous = Self.decodeTime(open.video[open.video.count - 2])
        return (end - Self.decodeTime(first)).seconds + max(0, (end - previous).seconds) > limit
    }

    /// Returns the open fragment up to its pending GOP (ending at the pending keyframe's decode time); the pending GOP stays
    /// open as a fragment of its own, with the audio from its keyframe on.
    private mutating func splitOffPending() -> FragmentGroup? {
        guard let fragment = open, let pending = fragment.pending else { return nil }
        let keyframe = fragment.video[pending.index]
        let (kept, carried) = split(fragment.audio, at: keyframe.pts)
        open = Fragment(start: keyframe.pts, video: Array(fragment.video[pending.index...]), audio: carried,
                        bytes: fragment.bytes - pending.bytes)
        return FragmentGroup(video: Array(fragment.video[..<pending.index]), audio: kept, nextDecodeTime: Self.decodeTime(keyframe))
    }

    /// Whether adding `frame` would take the open fragment past a bound. Non-mutating, so the copy of `open` it reads is
    /// released before the caller appends in place.
    private func wouldExceedBounds(adding frame: EncodedVideoFrame, size: Int) -> Bool {
        guard let open else { return false }
        return open.video.count >= Self.maximumFragmentFrames
            || open.bytes + size > Self.maximumFragmentBytes
            || (frame.pts - open.start).seconds > maximumDuration
    }

    /// Returns the open fragment as is and waits for the next keyframe.
    private mutating func cutOff() -> [FragmentGroup] {
        guard let fragment = open else { return [] }
        open = nil
        return [FragmentGroup(video: fragment.video, audio: fragment.audio)]
    }

    private mutating func holdPending(_ frame: EncodedAudioFrame) {
        pendingAudio.append(frame)
        if pendingAudio.count > Self.pendingAudioLimit { pendingAudio.removeFirst(pendingAudio.count - Self.pendingAudioLimit) }
    }

    /// Splits audio at a fragment boundary: (pts < boundary or implausibly far ahead, boundary ≤ pts < boundary + horizon).
    private func split(_ audio: [EncodedAudioFrame], at boundary: MediaTime) -> (before: [EncodedAudioFrame], after: [EncodedAudioFrame]) {
        var before: [EncodedAudioFrame] = []
        var after: [EncodedAudioFrame] = []
        for frame in audio {
            // Exact cross-timescale comparison at the boundary; the horizon only needs to be approximate.
            if frame.pts >= boundary, frame.pts.seconds - boundary.seconds < audioHorizon { after.append(frame) } else { before.append(frame) }
        }
        return (before, after)
    }
}
