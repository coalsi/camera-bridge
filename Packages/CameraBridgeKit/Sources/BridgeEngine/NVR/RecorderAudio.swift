import FMP4
import Foundation
import MediaCore

/// How a file records sound, decided once at its first fragment (the init segment names the tracks): the camera's AAC-LC as it is, any other
/// camera audio converted to AAC-LC at its own sample rate (the call `RecordingProducer` makes, without HomeKit's rate), or no sound track.
enum AudioPlan {
    enum Reason: Equatable {
        /// Record sound is off for the camera.
        case notWanted
        /// Record sound is on but the camera's own audio switch is off.
        case cameraAudioOff
        /// No audio frame arrived with the first fragment.
        case noSound
        /// The audio cannot be put in an MP4 as AAC-LC (no converter, or it threw).
        case failed
    }

    case none(Reason)
    case passthrough(AudioFormat)
    case transcode(source: AudioFormat, converter: any AudioTranscoding, output: AudioFormat)

    /// The format of the audio track, nil without one.
    var trackFormat: AudioFormat? {
        switch self {
        case .none: nil
        case .passthrough(let format): format
        case .transcode(_, _, let output): output
        }
    }

    /// The format camera audio must have to be recorded in this file.
    var sourceFormat: AudioFormat? {
        switch self {
        case .none: nil
        case .passthrough(let format): format
        case .transcode(let source, _, _): source
        }
    }

    var note: ArchiveNote? {
        guard case .none(let reason) = self else { return nil }
        switch reason {
        case .notWanted: return nil
        case .cameraAudioOff: return RecorderNotes.soundCameraAudioOff
        case .noSound: return RecorderNotes.soundMissing
        case .failed: return RecorderNotes.soundFailed
        }
    }

    /// `firstAudio`: the format of the first audio frame seen since the file's keyframe, nil when none arrived.
    static func choose(video: VideoFormat, firstAudio: AudioFormat?, wantsSound: Bool, audioEnabled: Bool, codecs: any MediaCodecs,
                       reusing kept: (source: AudioFormat, converter: any AudioTranscoding)? = nil) -> AudioPlan {
        guard wantsSound else { return .none(.notWanted) }
        guard audioEnabled else { return .none(.cameraAudioOff) }
        guard let source = firstAudio else { return .none(.noSound) }
        func fits(_ format: AudioFormat) -> Bool {
            (try? FMP4Muxer(configuration: FMP4Configuration(video: video, audio: format))) != nil
        }
        if fits(source) { return .passthrough(source) }
        if let kept, kept.source == source, fits(kept.converter.outputFormat) {
            return .transcode(source: source, converter: kept.converter, output: kept.converter.outputFormat)
        }
        guard let converter = try? codecs.makeAudioTranscoder(input: source, output: AudioEncoderSettings(codec: .aac, sampleRate: source.sampleRate,
                                                                                                            channels: max(1, source.channels))),
              fits(converter.outputFormat) else {
            return .none(.failed)
        }
        return .transcode(source: source, converter: converter, output: converter.outputFormat)
    }
}
