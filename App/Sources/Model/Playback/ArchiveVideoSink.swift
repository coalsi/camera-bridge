import Foundation
import MediaCore

/// A sink that also takes decode-only frames and reports its backlog: the renderer of a cell serves both its live feed and its playback.
nonisolated protocol ArchiveVideoSink: LiveVideoSink {
    /// `decodeOnly`: the frame only primes the decoder (`kCMSampleAttachmentKey_DoNotDisplay`); the picture on screen does not change.
    func show(_ frame: EncodedVideoFrame, decodeOnly: Bool)
    /// Frames accepted by `show` that the layer has not been given yet (never above 120 from a cell; a cell waits below 60).
    var queued: Int { get }
    /// +1 each time the renderer discarded its queue and waits for a keyframe by itself (decoder reset, failure, frames lost to a full queue);
    /// `reset()` and `clear()` asked for by the caller do not count.
    var restarts: Int { get }
}
