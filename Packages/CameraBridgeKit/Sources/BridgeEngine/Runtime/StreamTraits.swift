import Foundation
import MediaCore
import Synchronization

/// What ingest learns about a stream beyond its format, for the passthrough decisions (integration brief §5.6: clips
/// are dropped for B-frames and for H.264+ / smart-codec GOPs):
/// - `usesBFrames`: the camera sends B-frames — an H.264 B slice, or a decode time that differs from the presentation
///   time (the RTSP ingest and HTTP-FLV set one for reordered frames). Presentation order then differs from decode
///   order, which HomeKit does not take in a passthrough stream; the transcoder puts pictures back in presentation
///   order. Sticky across reconnects (the first keyframe after one comes before the connection's first B slice, and
///   passing reordered frames through drops the clip), until one connection delivered `bFrameClearGOPs` whole GOPs
///   without a reordered frame: the user turned B-frames off, as the log advises, and passthrough comes back without a
///   restart of the bridge.
/// - `longestGOP`: the longest of the last `gopWindow` keyframe intervals. Smart codecs stretch single GOPs far beyond
///   their average, which `MediaHub.measuredGOPDuration` (a mean over 4 keyframes) hides.
///
/// Fed by `IngestSupervisor` with every sample (`restart()` at every reconnect: a new timeline); read by the recording
/// and live paths when they choose between passthrough and transcoding.
final class StreamTraits: Sendable {
    /// Keyframe intervals remembered for `longestGOP`.
    static let gopWindow = 8
    /// Whole GOPs of one connection without a reordered frame that clear `usesBFrames`.
    static let bFrameClearGOPs = 3

    private struct State {
        var bFrames = false
        /// Keyframes of this connection since its last reordered frame (while `bFrames`).
        var cleanKeyframes = 0
        var lastKeyframe: Double?
        var gops: [Double] = []
    }

    private let state = Mutex(State())

    init() {}

    var usesBFrames: Bool { state.withLock { $0.bFrames } }

    /// nil until two keyframes of one connection were seen.
    var longestGOP: Duration? { state.withLock { $0.gops.max().map { .seconds($0) } } }

    func observe(_ sample: MediaSample) {
        guard case .video(let frame) = sample else { return }
        let reordered = frame.dts.map { $0 != frame.pts } == true
            || (frame.format.codec == .h264 && !frame.isKeyframe && Self.hasBSlice(frame.nalUnits))
        let time = frame.pts.seconds
        state.withLock { state in
            if reordered {
                state.bFrames = true
                state.cleanKeyframes = 0
            } else if frame.isKeyframe, state.bFrames {
                // The keyframe after `bFrameClearGOPs` whole GOPs without a reordered frame.
                state.cleanKeyframes += 1
                if state.cleanKeyframes > Self.bFrameClearGOPs {
                    state.bFrames = false
                    state.cleanKeyframes = 0
                }
            }
            guard frame.isKeyframe, time.isFinite else { return }
            if let last = state.lastKeyframe, time > last {
                state.gops.append(time - last)
                if state.gops.count > Self.gopWindow { state.gops.removeFirst(state.gops.count - Self.gopWindow) }
            }
            state.lastKeyframe = time
        }
    }

    /// The source reconnected (a new timeline): the next keyframe starts counting again (GOPs, and the clean GOPs that
    /// clear `usesBFrames`, are counted within one connection).
    func restart() {
        state.withLock { state in
            state.lastKeyframe = nil
            state.cleanKeyframes = 0
        }
    }

    /// Whether the access unit's first coded slice (NAL type 1 or 5) is a B slice: `slice_type` 1 or 6 (ITU-T H.264
    /// §7.3.3, Table 7-6), read by MediaCore's `NALUnits.h264SliceType`. A slice header that does not parse is not one.
    static func hasBSlice(_ nalUnits: [Data]) -> Bool {
        for nal in nalUnits {
            let type = NALUnits.h264Type(nal)
            guard type == 1 || type == 5 else { continue }
            return NALUnits.h264SliceType(nal).map { $0 % 5 == 1 } ?? false
        }
        return false
    }
}
