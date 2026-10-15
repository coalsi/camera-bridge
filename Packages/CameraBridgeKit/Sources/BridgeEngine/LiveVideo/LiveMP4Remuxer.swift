import FMP4
import Foundation
import MediaCore

/// Turns a live subscription's video access units (`BridgeEngine.liveVideo`) into what a browser's Media Source Extensions play: an init
/// segment, with its mime type and picture size, whenever the video starts, changes format or its timing restarts (a reconnected ingest), then
/// one small fragment per frame, so the picture is at most a frame behind the camera. No video transcoding. With `audio`, the camera's sound
/// (AAC-LC, as `BridgeEngine.browserLiveVideo` delivers it) is a second track: the init that follows the first audio frame (at the next keyframe)
/// has it, and each fragment carries the audio up to its video's end. Lives in BridgeEngine because BridgeWeb may not import FMP4.
package struct LiveMP4Remuxer: Sendable {
    package enum Part: Sendable, Equatable {
        /// A new init segment: everything after it belongs to it (a browser starts a new decoder for it).
        case initialization(Data, mime: String, width: Int, height: Int)
        /// One frame as a `moof` + `mdat`; `keyframe` lets a reader that fell behind skip to the next one.
        case media(Data, keyframe: Bool)
    }

    private var muxer: FMP4Muxer?
    /// The frame waiting for its successor: a fragment's last sample lasts until the next frame's decode time, known only once that frame arrives.
    private var pending: EncodedVideoFrame?
    private let wantsAudio: Bool
    /// The sound's format, from its first frame; a change starts a new init at the next keyframe.
    private var audioFormat: AudioFormat?
    private var audioTrackStale = false
    /// Sound not yet in a fragment (oldest first).
    private var audio: [EncodedAudioFrame] = []
    /// Most sound frames held for the video (about 6 s of AAC at 16 kHz).
    private static let audioBacklog = 96

    package init(audio: Bool = false) {
        wantsAudio = audio
    }

    /// Feeds one sound frame: it goes into the fragment of the video it plays with.
    package mutating func push(audio frame: EncodedAudioFrame) {
        guard wantsAudio else { return }
        if audioFormat != frame.format {
            audioFormat = frame.format
            audioTrackStale = true
            audio.removeAll()
        }
        guard let muxer, muxer.accepts(audio: frame.format) else { return }
        audio.append(frame)
        if audio.count > Self.audioBacklog { audio.removeFirst(audio.count - Self.audioBacklog) }
    }

    /// Feeds one frame and returns what is ready: the previous frame's fragment, preceded by an init segment when one starts. Frames before the
    /// first keyframe (and after a restart, before the next one) return nothing.
    package mutating func push(_ frame: EncodedVideoFrame) throws -> [Part] {
        var parts: [Part] = []
        if let current = muxer, !current.accepts(video: frame.format) { restart() }
        // The sound started or changed format: the next keyframe begins an init with its track.
        if audioTrackStale, frame.isKeyframe, muxer != nil { restart() }
        if muxer == nil {
            guard frame.isKeyframe else { return [] }
            audioTrackStale = false
            var started = try FMP4Muxer(configuration: FMP4Configuration(video: frame.format, audio: nil))
            var hasAudio = false
            if let audioFormat, let withAudio = try? FMP4Muxer(configuration: FMP4Configuration(video: frame.format, audio: audioFormat)) {
                started = withAudio
                hasAudio = true
            }
            let initialization = started.initializationSegment()
            var mime = try ArchiveMedia.mime(forInit: initialization)
            if hasAudio, mime.hasSuffix("\"") { mime = String(mime.dropLast()) + ",mp4a.40.2\"" }
            parts.append(.initialization(initialization, mime: mime, width: frame.format.width, height: frame.format.height))
            muxer = started
            pending = frame
            return parts
        }
        guard let previous = pending, var current = muxer else {
            pending = frame
            return parts
        }
        // Decode time not after the previous frame's: the ingest reconnected and its clock started again. A new timeline needs a new init, from a
        // keyframe on.
        if Self.decodeTime(frame).converted(to: 90_000).value <= Self.decodeTime(previous).converted(to: 90_000).value {
            restart()
            return frame.isKeyframe ? try push(frame) : []
        }
        // The sound that plays before the next frame goes with this one.
        let end = Self.decodeTime(frame).converted(to: 90_000).value
        let split = audio.firstIndex { $0.pts.converted(to: 90_000).value >= end } ?? audio.endIndex
        let sound = Array(audio[..<split])
        do {
            let data = try current.fragment(video: [previous], audio: sound, nextDecodeTime: Self.decodeTime(frame),
                                            continuation: !previous.isKeyframe)
            audio.removeFirst(split)
            muxer = current
            parts.append(.media(data, keyframe: previous.isKeyframe))
            pending = frame
        } catch FMP4Error.emptyFragment {
            pending = frame                     // a frame with nothing to show (only filler or delimiters): skipped
        } catch {
            // Timing that went backwards (the ingest reconnected) or anything else this muxer cannot continue with: start again at the next keyframe,
            // with a new init segment (a reader starts a new decoder for it).
            restart()
            if frame.isKeyframe { parts += try push(frame) }
        }
        return parts
    }

    /// Forgets the muxer: the next keyframe starts a new init segment.
    package mutating func restart() {
        muxer = nil
        pending = nil
        audio.removeAll()
    }

    private static func decodeTime(_ frame: EncodedVideoFrame) -> MediaTime { frame.dts ?? frame.pts }
}
