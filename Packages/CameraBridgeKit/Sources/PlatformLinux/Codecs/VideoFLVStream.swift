import Foundation
import MediaCore

/// What is remembered about a picture while it is inside ffmpeg: ffmpeg's timestamps are milliseconds, the engine's are 90 kHz
/// ticks with a wall clock, so the exact values wait here under the millisecond that went in.
struct PictureRecord: Sendable, Equatable {
    var pts: MediaTime
    var dts: MediaTime?
    var wallClock: Date
}

/// Writes the compressed pictures one ffmpeg process reads (FLV on its stdin) and maps its millisecond clock to the
/// engine's.
///
/// The millisecond clock starts at `margin` for the first picture (so nothing is negative). Decode times are strictly
/// increasing; a picture's presentation millisecond is **even** unless a keyframe was requested for it: ffmpeg's
/// `-force_key_frames` expression looks at that parity (`FFmpegArguments.keyframeRequestExpression`), which is the control
/// channel into a running encoder.
struct VideoFLVStream {
    static let margin: Int64 = 2_000

    let format: VideoFormat
    private(set) var origin: Int64?
    private var lastDtsMs: Int64 = -1
    /// Presentation millisecond → the exact picture times.
    private(set) var records: [Int64: PictureRecord] = [:]
    private(set) var framesWritten = 0
    /// The parameter sets the child has seen (the sequence header's, then those of the latest in-band ones).
    private var sentParameterSets: [Data]

    init(format: VideoFormat) {
        self.format = format
        sentParameterSets = format.parameterSets
    }

    /// The FLV file header and the sequence header for `format`. nil when the parameter sets cannot be described (an encoder
    /// would fail on the stream anyway).
    var header: Data? {
        guard let sequence = FLVWriter.videoSequenceHeader(format) else { return nil }
        return FLVWriter.fileHeader(video: true, audio: false) + sequence
    }

    /// The tag for `frame` and the presentation millisecond it carries. A keyframe carries the frame's parameter sets in band, and so
    /// does a delta frame whose sets differ from the last ones the child saw (a further PPS): ffmpeg's decoder takes sets from the
    /// stream as they come, the sequence header only describes the first ones.
    mutating func tag(for frame: EncodedVideoFrame, requestKeyframe: Bool) -> (data: Data, ptsMs: Int64) {
        let inBand = frame.isKeyframe || frame.format.parameterSets != sentParameterSets
        sentParameterSets = frame.format.parameterSets
        let pts90 = frame.pts.converted(to: 90_000).value
        let dts90 = (frame.dts ?? frame.pts).converted(to: 90_000).value
        let origin = self.origin ?? min(pts90, dts90)
        self.origin = origin
        let wantOdd = requestKeyframe
        var dtsMs: Int64
        var ptsMs: Int64
        if frame.dts == nil || frame.dts == frame.pts {
            var value = Self.margin + Self.rounded(pts90 - origin)
            value = max(value, lastDtsMs + 1)
            if (value & 1 == 1) != wantOdd { value += 1 }
            dtsMs = value
            ptsMs = value
        } else {
            dtsMs = max(Self.margin + Self.rounded(dts90 - origin), lastDtsMs + 1)
            ptsMs = Self.margin + Self.rounded(pts90 - origin)
            if (ptsMs & 1 == 1) != wantOdd { ptsMs += 1 }
            while ptsMs < dtsMs { ptsMs += 2 }
        }
        var guardCount = 0
        while records[ptsMs] != nil, guardCount < 64 {
            ptsMs += 2
            if frame.dts == nil || frame.dts == frame.pts { dtsMs = ptsMs }
            guardCount += 1
        }
        lastDtsMs = dtsMs
        records[ptsMs] = PictureRecord(pts: frame.pts, dts: frame.dts, wallClock: frame.wallClock)
        framesWritten += 1
        if records.count > 4_096, let oldest = records.keys.min() { records.removeValue(forKey: oldest) }
        let data = FLVWriter.videoFrame(format: frame.format, nalUnits: frame.nalUnits, isKeyframe: frame.isKeyframe, dtsMs: UInt32(clamping: dtsMs),
                                        ptsMs: UInt32(clamping: ptsMs), inBandParameterSets: inBand)
        return (data, ptsMs)
    }

    /// The exact times for an output picture at presentation millisecond `ptsMs` (removing older entries, which will not come:
    /// pictures the frame-rate limiter skipped).
    mutating func claim(ptsMs: Int64) -> PictureRecord? {
        let record = records.removeValue(forKey: ptsMs)
        if record != nil {
            for key in records.keys where key < ptsMs - 10_000 { records.removeValue(forKey: key) }
        }
        return record
    }

    /// The 90 kHz time for a millisecond when no record exists.
    func fallbackTime(ptsMs: Int64) -> MediaTime {
        MediaTime(value: (origin ?? 0) + (ptsMs - Self.margin) * 90, timescale: 90_000)
    }

    /// `ticks / 90` rounded to nearest, half up (also for negative values).
    static func rounded(_ ticks: Int64) -> Int64 {
        let (quotient, remainder) = (ticks / 90, ticks % 90)
        if remainder >= 45 { return quotient + 1 }
        if remainder < -45 { return quotient - 1 }
        return quotient
    }

    /// A time in seconds on the millisecond clock for `pts` (what the catch-up `select` compares with).
    func seconds(forPTSMs ms: Int64) -> Double { Double(ms) / 1000 }
}

/// Reads the H.264 FLV ffmpeg's encoder writes: the output format from the sequence header, then one packet per picture.
struct H264FLVOutput {
    struct Packet: Equatable {
        var ptsMs: Int64
        var isKeyframe: Bool
        var nalUnits: [Data]
    }

    private var reader = FLVReader()
    private(set) var format: VideoFormat?
    private var lengthSize = 4
    private let fallbackSize: (width: Int, height: Int)

    init(width: Int, height: Int) {
        fallbackSize = (width, height)
    }

    var isBroken: Bool { reader.failed }

    mutating func push(_ data: Data) -> [Packet] {
        var packets: [Packet] = []
        for tag in reader.push(data) {
            guard let parsed = FLVAVCPacket.parse(tag, lengthSize: lengthSize) else { continue }
            switch parsed {
            case .sequenceHeader(let record):
                guard let sets = FLVAVCPacket.parameterSets(avcC: record), let sps = sets.sps.first, let pps = sets.pps.first else { continue }
                lengthSize = sets.lengthSize
                format = VideoFormat.h264(sps: sps, pps: pps)
                    ?? VideoFormat(codec: .h264, width: fallbackSize.width, height: fallbackSize.height, parameterSets: [sps, pps])
            case .frame(let isKeyframe, let composition, let nalUnits):
                // The stream's parameter sets live in `format`; SEI (encoder banner), AUDs and in-band sets are not part of a frame.
                let slices = nalUnits.filter { ![6, 7, 8, 9, 10, 11, 12].contains(NALUnits.h264Type($0)) }
                guard !slices.isEmpty else { continue }
                packets.append(Packet(ptsMs: Int64(tag.timestamp) + Int64(composition), isKeyframe: isKeyframe, nalUnits: slices))
            case .endOfSequence:
                continue
            }
        }
        return packets
    }
}
