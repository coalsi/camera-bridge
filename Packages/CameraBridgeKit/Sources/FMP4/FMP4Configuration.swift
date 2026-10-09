import Foundation
import MediaCore

public struct FMP4Configuration: Sendable {
    public var video: VideoFormat
    /// AAC-LC only (esds from ES_Descriptor). nil: video-only recording (HKSV `RecordingAudioActive` = 0).
    public var audio: AudioFormat?
    /// 90000
    public var videoTimescale: Int32
    /// prft before moof, flags 0 (HEVC/HKSV3; off for classic).
    public var writeProducerReferenceTime: Bool

    public init(video: VideoFormat, audio: AudioFormat?, videoTimescale: Int32 = 90_000, writeProducerReferenceTime: Bool = false) {
        self.video = video
        self.audio = audio
        self.videoTimescale = videoTimescale
        self.writeProducerReferenceTime = writeProducerReferenceTime
    }
}
