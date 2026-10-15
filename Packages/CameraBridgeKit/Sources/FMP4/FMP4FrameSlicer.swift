import Foundation
import MediaCore

/// Turns stored fragment bytes back into the frames the live path carries (`EncodedVideoFrame`, `EncodedAudioFrame`), with wall-clock times
/// (Mac spec 4.3 and 7). Task T01 builds it.
///
/// Times: sample `i`'s decode instant is `fragmentStart` plus (the sum of the durations of samples `0..<i`) / `videoTimescale`. `pts` is
/// `MediaTime(value: wall ticks since 2001-01-01 at 90 kHz, timescale: 90_000)` of that instant plus the composition offset; `dts` is set
/// only when a composition offset is not zero; `wallClock` is the `pts` instant. NAL units are split by `info.nalLengthSize`; `format` is
/// `info.video`; `isKeyframe` is the sync flag.
public enum FMP4FrameSlicer {
    /// The wall-clock ticks of video frames: 90 kHz since 2001-01-01 (`Date.timeIntervalSinceReferenceDate`), about 7.3e13 today, which fits `Int64`.
    static let wallTimescale: Int32 = 90_000

    /// The video samples `samples` of `header` (the video track's `TrackFragmentHeader`, chosen by `info.videoTrackID`). `bytes` holds the
    /// fragment; `bytesStart` is the index in `bytes` at which the `moof` box starts (the length of a `prft` before it, else 0), because
    /// sample data offsets count from the `moof`.
    public static func videoFrames(header: MovieFragmentHeader, bytes: Data, bytesStart: Int, info: FMP4InitInfo, fragmentStart: Date,
                                   samples: Range<Int>) throws -> [EncodedVideoFrame] {
        guard let track = header.tracks.first(where: { $0.trackID == info.videoTrackID }) else {
            throw FMP4Error.malformedBox(offset: bytesStart, reason: "the fragment has no video track")
        }
        guard info.videoTimescale > 0 else { throw FMP4Error.invalidTimescale(info.videoTimescale) }
        let base = wallTicks(fragmentStart, timescale: wallTimescale)
        var frames: [EncodedVideoFrame] = []
        try walk(track, bytes: bytes, bytesStart: bytesStart, samples: samples) { sample, decodeTicks, data in
            let decode = MediaTime(value: decodeTicks, timescale: info.videoTimescale).converted(to: wallTimescale).value
            let offset = MediaTime(value: Int64(sample.compositionOffset), timescale: info.videoTimescale).converted(to: wallTimescale).value
            let pts = MediaTime(value: base &+ decode &+ offset, timescale: wallTimescale)
            frames.append(EncodedVideoFrame(format: info.video, nalUnits: try nalUnits(of: data, lengthSize: info.nalLengthSize), isKeyframe: sample.isSync,
                                            pts: pts, dts: sample.compositionOffset == 0 ? nil : MediaTime(value: base &+ decode, timescale: wallTimescale),
                                            wallClock: date(ofTicks: pts.value, timescale: wallTimescale)))
        }
        return frames
    }

    /// As `videoFrames`, for the audio track (`info.audioTrackID`); empty when the file has none. An audio sample's instant is the video track's
    /// `fragmentStart` plus the distance of the two tracks' `tfdt`s plus the durations before it, in the audio timescale (the sample rate).
    public static func audioFrames(header: MovieFragmentHeader, bytes: Data, bytesStart: Int, info: FMP4InitInfo, fragmentStart: Date,
                                   samples: Range<Int>) throws -> [EncodedAudioFrame] {
        guard let format = info.audio, let audioID = info.audioTrackID, let track = header.tracks.first(where: { $0.trackID == audioID }) else { return [] }
        let rate = Int32(clamping: format.sampleRate)
        guard rate > 0 else { throw FMP4Error.unsupportedAudio("a sample rate of \(format.sampleRate) Hz") }
        var start = wallTicks(fragmentStart, timescale: rate)
        if let video = header.tracks.first(where: { $0.trackID == info.videoTrackID }), info.videoTimescale > 0 {
            let videoBase = MediaTime(value: Int64(clamping: video.baseDecodeTime), timescale: info.videoTimescale).converted(to: rate).value
            start = start &+ Int64(clamping: track.baseDecodeTime) &- videoBase
        }
        var frames: [EncodedAudioFrame] = []
        try walk(track, bytes: bytes, bytesStart: bytesStart, samples: samples) { sample, decodeTicks, data in
            frames.append(EncodedAudioFrame(format: format, data: Data(data), pts: MediaTime(value: start &+ decodeTicks, timescale: rate),
                                            sampleCount: Int(sample.duration), wallClock: date(ofTicks: start &+ decodeTicks, timescale: rate)))
        }
        return frames
    }

    /// The frame for a `.keyframe` read: `bytes` is the first video sample alone (length-prefixed NAL units); `start` is the fragment's start.
    public static func frame(fromKeyframeBytes bytes: Data, info: FMP4InitInfo, start: Date) throws -> EncodedVideoFrame {
        let units = try nalUnits(of: bytes, lengthSize: info.nalLengthSize)
        guard !units.isEmpty else { throw FMP4Error.malformedBox(offset: 0, reason: "an empty keyframe") }
        return EncodedVideoFrame(format: info.video, nalUnits: units, isKeyframe: true,
                                 pts: MediaTime(value: wallTicks(start, timescale: wallTimescale), timescale: wallTimescale), dts: nil, wallClock: start)
    }

    // MARK: Helpers

    /// Calls `body` for each sample of `samples` with its decode time (ticks of the track, counted from the fragment's first sample) and its bytes.
    private static func walk(_ track: TrackFragmentHeader, bytes: Data, bytesStart: Int, samples: Range<Int>,
                             _ body: (TrackSample, Int64, Data) throws -> Void) throws {
        guard samples.lowerBound >= 0, samples.upperBound <= track.samples.count else {
            throw FMP4Error.malformedBox(offset: bytesStart, reason: "samples \(samples) of \(track.samples.count)")
        }
        guard bytesStart >= 0, track.dataOffset >= 0, bytesStart <= bytes.count - track.dataOffset else {
            throw FMP4Error.malformedBox(offset: bytesStart, reason: "the sample data starts past the fragment")
        }
        var position = bytes.startIndex + bytesStart + track.dataOffset
        var decode: Int64 = 0
        for index in 0..<samples.upperBound {
            let sample = track.samples[index]
            let size = Int(sample.size)
            guard size >= 0, size <= bytes.endIndex - position else {
                throw FMP4Error.malformedBox(offset: position - bytes.startIndex, reason: "sample \(index) extends past the fragment")
            }
            if index >= samples.lowerBound { try body(sample, decode, bytes[position..<position + size]) }
            position += size
            decode += Int64(sample.duration)
        }
    }

    /// Splits `length | NAL | length | NAL ...`; a length that runs past the data throws. Each unit is a copy (its indices start at 0).
    static func nalUnits(of data: Data, lengthSize: Int) throws -> [Data] {
        guard (1...4).contains(lengthSize) else { throw FMP4Error.malformedBox(offset: 0, reason: "NAL length size \(lengthSize)") }
        var units: [Data] = []
        var position = data.startIndex
        while position < data.endIndex {
            guard data.endIndex - position >= lengthSize else { throw FMP4Error.malformedBox(offset: position - data.startIndex, reason: "truncated NAL length") }
            var length = 0
            for byte in data[position..<position + lengthSize] { length = length << 8 | Int(byte) }
            position += lengthSize
            guard length <= data.endIndex - position else { throw FMP4Error.malformedBox(offset: position - data.startIndex, reason: "NAL unit extends past the sample") }
            if length > 0 { units.append(Data(data[position..<position + length])) }
            position += length
        }
        guard !units.isEmpty else { throw FMP4Error.malformedBox(offset: 0, reason: "a sample without NAL units") }
        return units
    }

    private static func wallTicks(_ date: Date, timescale: Int32) -> Int64 {
        let ticks = (date.timeIntervalSinceReferenceDate * Double(timescale)).rounded()
        return Int64(exactly: ticks) ?? (ticks < 0 ? Int64.min : Int64.max)
    }

    private static func date(ofTicks ticks: Int64, timescale: Int32) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(ticks) / Double(timescale))
    }
}
