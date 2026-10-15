import Foundation
import MediaCore

/// The camera's audio as a browser plays it in MP4: AAC-LC as it is, anything else (G.711 µ-law or A-law, AAC-ELD, Opus, PCM) converted to AAC-LC,
/// 16 kHz mono, through the platform's transcoder (ffmpeg on Linux). A converter is made for the first frame of each format and kept while the
/// format stays; audio no converter can be made for is dropped (the video plays on).
struct LiveAudioConverter {
    static let sampleRate = 16_000
    static let bitrate = 32_000

    private let codecs: any MediaCodecs
    private var input: AudioFormat?
    private var converter: (any AudioTranscoding)?

    init(codecs: any MediaCodecs) {
        self.codecs = codecs
    }

    /// AAC with an AudioSpecificConfig of object type 2 (AAC-LC), which `FMP4Muxer` and every browser take as it is.
    static func isAACLC(_ format: AudioFormat) -> Bool {
        guard format.codec == .aac, let first = format.audioSpecificConfig?.first else { return false }
        return first >> 3 == 2
    }

    mutating func convert(_ frame: EncodedAudioFrame) -> [EncodedAudioFrame] {
        if Self.isAACLC(frame.format) { return [frame] }
        if input != frame.format {
            _ = try? converter?.flush()
            input = frame.format
            converter = try? codecs.makeAudioTranscoder(input: frame.format, output: AudioEncoderSettings(
                codec: .aac, sampleRate: Self.sampleRate, channels: 1, bitrate: Self.bitrate))
        }
        guard let converter else { return [] }
        return (try? converter.transcode(frame)) ?? []
    }

    /// Ends the converter (its ffmpeg child).
    mutating func finish() {
        _ = try? converter?.flush()
        converter = nil
        input = nil
    }
}
