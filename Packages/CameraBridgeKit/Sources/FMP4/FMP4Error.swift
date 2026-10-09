import Foundation
import MediaCore

/// Errors thrown by `FMP4Muxer` and `MP4BoxReader`. FMP4 has no logging dependency (contract graph: MediaCore only),
/// so every failure is reported by throwing one of these.
public enum FMP4Error: Error, Equatable, Sendable {
    /// The video format lacks a parameter set the sample entry needs, or one is malformed.
    case invalidParameterSets(String)
    /// Neither the format nor its SPS gives a usable picture size (1…65535).
    case invalidVideoDimensions(width: Int, height: Int)
    /// A track timescale must be positive.
    case invalidTimescale(Int32)
    /// Only AAC-LC with a positive sample rate and 1…8 channels can be muxed.
    case unsupportedAudio(String)
    /// A fragment needs at least one video frame.
    case emptyFragment
    /// `video.first` of a fragment is not a keyframe.
    case fragmentMustStartWithKeyframe
    /// A video frame's codec or parameter sets differ from the initialization segment's; start a new muxer.
    case videoFormatChanged
    /// An audio frame's codec, sample rate or channel count differs from the initialization segment's.
    case audioFormatChanged
    /// Video decode times must increase strictly, within a fragment and across fragments of one muxer.
    case nonMonotonicTimestamps(String)
    /// A duration, composition offset or decode time does not fit its box field.
    case timestampOutOfRange(String)
    /// The fragment's media data would not fit a 32-bit `mdat` / `trun` data offset.
    case fragmentTooLarge(Int)
    /// `MP4BoxReader`: the bytes are not a well-formed box sequence at `offset`.
    case malformedBox(offset: Int, reason: String)
}
