import Foundation
import MediaCore
import Synchronization

/// The decoder a camera's snapshots share. A snapshot from the video stream (a camera whose snapshot API answers 503,
/// or has none) decodes one keyframe; building a VideoToolbox session for it each time cost a full 4K session setup
/// every 10 s per camera. The pool makes the decoder at the first snapshot, reuses it for the next ones (a keyframe
/// decodes on a running session as on a new one) and invalidates it `idleLifetime` after the last use, so an idle camera
/// holds no decoder. A format change (another resolution or codec) replaces it; a decode that fails drops it, so the
/// next snapshot starts from a clean session.
final class SnapshotDecoderPool: Sendable {
    private struct State {
        var decoder: (any VideoDecoding)?
        var format: VideoFormat?
        /// The GOP the decoder is partway through: its keyframe, how many of its frames were decoded, and the newest picture
        /// (a snapshot asked again before another frame arrived needs no decoding).
        var gopKeyframe: GOPKey?
        var decodedFrames = 0
        var newestPicture: (any DecodedVideoFrame)?
        var idleTask: Task<Void, Never>?
        /// Bumped at every use: an idle timer that wakes up to a newer generation does nothing.
        var generation = 0
    }

    private let codecs: any MediaCodecs
    private let idleLifetime: Duration
    private let state = Mutex(State())

    init(codecs: any MediaCodecs, idleLifetime: Duration) {
        self.codecs = codecs
        self.idleLifetime = idleLifetime
    }

    deinit {
        let (decoder, idle) = state.withLock { state in (state.decoder, state.idleTask) }
        idle?.cancel()
        decoder?.invalidate()
    }

    /// Whether a decoder is being kept (tests).
    var isHoldingDecoder: Bool { state.withLock { $0.decoder != nil } }

    /// Decodes `frame` (a keyframe) and encodes the picture as JPEG within the bounds, like
    /// `MediaCodecs.jpeg(fromKeyframe:maxWidth:maxHeight:)` but on the pool's decoder.
    func jpeg(fromKeyframe frame: EncodedVideoFrame, maxWidth: Int?, maxHeight: Int?) async throws -> Data {
        guard frame.isKeyframe else { throw MediaCodecError.unsupported("snapshot source is not a keyframe") }
        let decoder = try checkout(for: frame.format)
        do {
            guard let picture = try await decoder.decode(frame) else { throw MediaCodecError.noFrame }
            let jpeg = try codecs.jpeg(from: picture, maxWidth: maxWidth, maxHeight: maxHeight, quality: 0.8)
            scheduleRelease()
            return jpeg
        } catch {
            discard(decoder)
            throw error
        }
    }

    /// Identifies a GOP by its keyframe.
    struct GOPKey: Equatable, Sendable {
        var pts: MediaTime
        var wallClock: Date
        var width: Int
        var height: Int
        var byteCount: Int

        init(_ frame: EncodedVideoFrame) {
            pts = frame.pts
            wallClock = frame.wallClock
            width = frame.format.width
            height = frame.format.height
            byteCount = frame.nalUnits.reduce(0) { $0 + $1.count }
        }
    }

    /// The newest picture of `gop` (a keyframe and the frames after it, in decode order) as JPEG: the pool's decoder decodes
    /// forward through the frames it has not decoded yet (a GOP it has already started is continued, not decoded again from
    /// its keyframe), so the picture is of the newest frame, not of the keyframe a camera with a GOP of tens of seconds sent
    /// long ago. Frames after `until` are left for the next snapshot (the keyframe is always decoded). A frame that fails to
    /// decode drops the decoder.
    func jpeg(fromGOP gop: [EncodedVideoFrame], maxWidth: Int?, maxHeight: Int?, until: ContinuousClock.Instant) async throws -> Data {
        guard let keyframe = gop.first, keyframe.isKeyframe else { throw MediaCodecError.unsupported("snapshot source does not start at a keyframe") }
        let decoder = try checkout(for: keyframe.format)
        let key = GOPKey(keyframe)
        let (start, previous): (Int, (any DecodedVideoFrame)?) = state.withLock { state in
            guard state.gopKeyframe == key, state.decodedFrames <= gop.count else { return (0, nil) }
            return (state.decodedFrames, state.newestPicture)
        }
        do {
            var newest = previous
            var decoded = start
            for index in start..<gop.count {
                if index > 0, newest != nil, ContinuousClock.now >= until { break }
                if let picture = try await decoder.decode(gop[index]) { newest = picture }
                decoded = index + 1
            }
            guard let newest else { throw MediaCodecError.noFrame }
            let jpeg = try codecs.jpeg(from: newest, maxWidth: maxWidth, maxHeight: maxHeight, quality: 0.8)
            state.withLock { state in
                state.gopKeyframe = key
                state.decodedFrames = decoded
                state.newestPicture = newest
            }
            scheduleRelease()
            return jpeg
        } catch {
            discard(decoder)
            throw error
        }
    }

    /// The kept decoder when it was made for this format, else a new one (the old one is invalidated).
    private func checkout(for format: VideoFormat) throws -> any VideoDecoding {
        let (kept, replaced): ((any VideoDecoding)?, (any VideoDecoding)?) = state.withLock { state in
            state.generation += 1
            state.idleTask?.cancel()
            state.idleTask = nil
            if let decoder = state.decoder, state.format == format { return (decoder, nil) }
            let old = state.decoder
            state.decoder = nil
            state.format = nil
            state.gopKeyframe = nil
            state.newestPicture = nil
            return (nil, old)
        }
        replaced?.invalidate()
        if let kept { return kept }
        let decoder = try codecs.makeSnapshotDecoder(format: format)
        state.withLock { state in
            state.decoder = decoder
            state.format = format
        }
        return decoder
    }

    private func discard(_ decoder: any VideoDecoding) {
        let dropped: Bool = state.withLock { state in
            guard let current = state.decoder, current === decoder else { return false }
            state.decoder = nil
            state.format = nil
            state.gopKeyframe = nil
            state.newestPicture = nil
            state.idleTask?.cancel()
            state.idleTask = nil
            return true
        }
        if dropped { decoder.invalidate() }
    }

    private func scheduleRelease() {
        let lifetime = idleLifetime
        state.withLock { state in
            state.generation += 1
            let generation = state.generation
            state.idleTask?.cancel()
            state.idleTask = Task { [weak self] in
                try? await Task.sleep(for: lifetime)
                guard !Task.isCancelled else { return }
                self?.release(ifGeneration: generation)
            }
        }
    }

    private func release(ifGeneration generation: Int) {
        let decoder: (any VideoDecoding)? = state.withLock { state in
            guard state.generation == generation else { return nil }
            let decoder = state.decoder
            state.decoder = nil
            state.format = nil
            state.gopKeyframe = nil
            state.newestPicture = nil
            state.idleTask = nil
            return decoder
        }
        decoder?.invalidate()
    }
}
