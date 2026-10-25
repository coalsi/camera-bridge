import Foundation
import HAPCamera
import MediaCore

/// Which of a camera's streams the sky detector watches, and how (Task 6, spec "Stream"): the sub stream when it is at least 1280 pixels wide,
/// else the main stream, which is decoded on the GPU where the GPU takes it and scaled down to at most 1920 wide, only every `keepEvery`th picture
/// made so that about five a second are looked at (`MediaCodecs.makeSkyDecoder`). Chosen at run time by `CameraRuntime`, from what the camera's two
/// streams show (the sub stream's size is not known until it has run), and chosen again when the picture's format changes.
struct SkyStreamChoice: Sendable, Equatable {
    enum Stream: String, Sendable, Codable {
        case sub, main
    }

    var stream: Stream
    /// The width the pictures are analysed at: the stream's, at most `maximumAnalysisWidth`. It is what the decoder is asked to scale to
    /// (`maxOutputWidth`) and what the monitor asks the picture's thumbnail for.
    var analysisWidth: Int
    /// The decoder makes a picture of every Nth frame: `max(1, round(frames per second / analysisRate))`.
    var keepEvery: Int

    /// A sub stream narrower than this is no use for finding lights: the main stream is watched instead.
    static let minimumSubWidth = 1280
    static let maximumAnalysisWidth = 1920
    /// Pictures a second the analyzer is tuned for (at most).
    static let analysisRate = 5.0

    /// The stream to watch from what the camera's streams show now, nil while there is no picture to choose from: no stream that can be watched
    /// has shown one (a sub stream under `minimumSubWidth` is no help while the main stream has not). `subFrameRate` and `mainFrameRate` are
    /// the rates measured on the hubs; one that is not known (nil) is the rate the resolution carries, and when neither is known every picture is
    /// asked for (the monitor still analyses at most five a second).
    static func choose(sub: VideoResolution?, subFrameRate: Double?, main: VideoResolution?, mainFrameRate: Double?) -> SkyStreamChoice? {
        if let sub, sub.width >= minimumSubWidth {
            return SkyStreamChoice(stream: .sub, analysisWidth: min(sub.width, maximumAnalysisWidth),
                                   keepEvery: keepEvery(rate: subFrameRate ?? Double(sub.fps)))
        }
        guard let main, main.width > 0 else { return nil }
        return SkyStreamChoice(stream: .main, analysisWidth: min(main.width, maximumAnalysisWidth), keepEvery: keepEvery(rate: mainFrameRate ?? Double(main.fps)))
    }

    /// `max(1, round(rate / 5))`; 1 for a rate that is not a number above zero.
    static func keepEvery(rate: Double) -> Int {
        guard rate.isFinite, rate > 0 else { return 1 }
        return max(1, Int((rate / analysisRate).rounded()))
    }
}

/// One picture for the sky detector: luma at the analysis width, never straightened (`PictureCorrection` is not applied anywhere on this path).
struct SkyFrame: Sendable {
    var image: GrayImage
    /// Seconds from the stream's own presentation time of the picture (its clock starts wherever the camera's does; only differences count).
    var time: TimeInterval
    /// The wall clock of the encoded frame the picture shows, as the camera's stream stamps it (the camera's clock when its RTCP says so,
    /// within 3 s of the bridge's).
    var wallClock: Date
    /// What to add to `wallClock` to get the bridge's own clock at the picture's capture (`MediaHub.wallClockOffset`): 0 for a stream stamped
    /// on arrival. A match against a flight feed, whose times are the bridge's, wants `wallClock + clockOffset`.
    var clockOffset: TimeInterval = 0
    /// The size of the stream's own picture, before it was scaled down to `image` (what the camera model is about: the original picture).
    var pictureWidth: Int = 0
    var pictureHeight: Int = 0
    /// The stream the picture is of, and where its decoder decodes (what the card says, `SkyCameraStatus`); nil where the sender does not say.
    var stream: SkyStreamChoice.Stream?
    var decoding: DecodingPlace?
}

/// Where the sky monitor's pictures go (the camera's sky detector).
protocol SkyFrameSink: Sendable {
    func frame(_ frame: SkyFrame) async
    /// The pictures are not continuous from here: whatever was being followed ends and the background starts again. Told once for a break
    /// (a stream that was reconnected, a picture time that jumped, the picture's format that changed, five seconds without a picture), also
    /// when several of them happen together. `at`: the wall clock of the frame that showed it (as `SkyFrame.wallClock`), or now for a silence.
    func gap(at: Date, reason: String) async
}
