import Foundation

/// One sample of a `trun` after the track-fragment defaults (`tfhd`, `trex`) and the first-sample flags are applied.
public struct TrackSample: Sendable, Equatable {
    public var duration: UInt32
    public var size: UInt32
    public var flags: UInt32
    /// 0 when the `trun` has no composition offsets. Signed for `trun` version 1.
    public var compositionOffset: Int32
    /// `sample_is_non_sync_sample` (bit 16 of `flags`) is clear.
    public var isSync: Bool

    public init(duration: UInt32, size: UInt32, flags: UInt32, compositionOffset: Int32, isSync: Bool) {
        self.duration = duration
        self.size = size
        self.flags = flags
        self.compositionOffset = compositionOffset
        self.isSync = isSync
    }
}

public struct TrackFragmentHeader: Sendable, Equatable {
    public var trackID: UInt32
    /// `tfdt`.
    public var baseDecodeTime: UInt64
    /// Where the first sample's data starts, in bytes from the start of the `moof` box (`default-base-is-moof`), i.e. the `trun` data offset.
    public var dataOffset: Int
    /// All samples of all `trun`s of this `traf`, in order.
    public var samples: [TrackSample]

    public init(trackID: UInt32, baseDecodeTime: UInt64, dataOffset: Int, samples: [TrackSample]) {
        self.trackID = trackID
        self.baseDecodeTime = baseDecodeTime
        self.dataOffset = dataOffset
        self.samples = samples
    }
}

public struct MovieFragmentHeader: Sendable, Equatable {
    public var sequenceNumber: UInt32
    public var tracks: [TrackFragmentHeader]

    public init(sequenceNumber: UInt32, tracks: [TrackFragmentHeader]) {
        self.sequenceNumber = sequenceNumber
        self.tracks = tracks
    }
}

/// The `prft` box FMP4Muxer writes before a `moof` (`writeProducerReferenceTime`): version 1, flags 0, track ID, NTP time, media time.
public struct ProducerReferenceTime: Sendable, Equatable {
    public var trackID: UInt32
    /// 32.32 fixed point, seconds since 1900 (era-relative), as `FMP4Muxer.ntpTimestamp` writes it.
    public var ntpTimestamp: UInt64
    /// The video `tfdt` of the fragment.
    public var mediaTime: UInt64

    public init(trackID: UInt32, ntpTimestamp: UInt64, mediaTime: UInt64) {
        self.trackID = trackID
        self.ntpTimestamp = ntpTimestamp
        self.mediaTime = mediaTime
    }

    /// `ntpTimestamp` as a date (to the nearest microsecond).
    public var wallClock: Date {
        let seconds = Double(ntpTimestamp >> 32) - 2_208_988_800
        let fraction = Double(ntpTimestamp & 0xFFFF_FFFF) / 4_294_967_296
        return Date(timeIntervalSince1970: seconds + fraction)
    }
}

/// Reads the fragment headers `FMP4Muxer` writes (and any `moof` of the same shape): one parser for the recovery scanner, the player and
/// the web routes. Never traps and never allocates more than the declared bytes; every failure is `FMP4Error.malformedBox`.
///
/// What it accepts: a `moof` whose track fragments use `default-base-is-moof` (`tfhd` flag 0x020000, which `FMP4Muxer` always writes) and no
/// explicit base data offset, with `tfdt` version 0 or 1 and one or more `trun`s. Defaults a `tfhd` does not give are 0: the `trex` boxes
/// of every file this package writes carry zeros (`InitializationSegment.trackExtends`), and `parse(moof:)` has no init segment to ask.
public enum MovieFragmentReader {
    /// One sample at most (a 4K intra picture is about 2 MB).
    static let maximumSampleSize: UInt32 = 256 << 20
    /// Track fragments in one `moof` (this package writes two).
    static let maximumTracks = 16

    private static let tfhdDefaultBaseIsMoof: UInt32 = 0x02_0000
    private static let tfhdBaseDataOffset: UInt32 = 0x01
    private static let tfhdSampleDescriptionIndex: UInt32 = 0x02
    private static let tfhdDefaultDuration: UInt32 = 0x08
    private static let tfhdDefaultSize: UInt32 = 0x10
    private static let tfhdDefaultFlags: UInt32 = 0x20
    private static let trunDataOffset: UInt32 = 0x001
    private static let trunFirstSampleFlags: UInt32 = 0x004
    private static let trunDuration: UInt32 = 0x100
    private static let trunSize: UInt32 = 0x200
    private static let trunFlags: UInt32 = 0x400
    private static let trunCompositionOffset: UInt32 = 0x800

    /// `moof`: the bytes of one `moof` box, header included. `mdatPayloadSize`: when known, sample sizes and offsets must lie inside it.
    /// Guards: `sample_count` at most the moof's size / 4, one sample at most 256 MB, offsets and sizes inside the `mdat`. Handles `tfhd`
    /// defaults, first-sample flags, several `trun`s and signed version-1 offsets.
    public static func parse(moof: Data, mdatPayloadSize: Int? = nil) throws -> MovieFragmentHeader {
        let boxes = try MP4BoxReader.parse(moof)
        guard boxes.count == 1, let box = boxes.first, box.type == "moof", box.size == moof.count else {
            throw FMP4Error.malformedBox(offset: 0, reason: "expected exactly one moof box")
        }
        return try moof.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> MovieFragmentHeader in
            guard let mfhd = box.child("mfhd"), mfhd.payloadSize >= 8 else {
                throw FMP4Error.malformedBox(offset: box.offset, reason: "moof without mfhd")
            }
            var header = Fields(raw, mfhd.payloadOffset + 4, mfhd.offset + mfhd.size)
            let sequence = try header.u32()
            let trafs = box.children(ofType: "traf")
            guard trafs.count <= maximumTracks else { throw FMP4Error.malformedBox(offset: box.offset, reason: "\(trafs.count) track fragments") }
            let tracks = try trafs.map { try parseTrackFragment($0, raw: raw, moofSize: moof.count, mdatPayloadSize: mdatPayloadSize) }
            return MovieFragmentHeader(sequenceNumber: sequence, tracks: tracks)
        }
    }

    /// `prft`: the bytes of one `prft` box, header included.
    public static func producerReferenceTime(prft: Data) throws -> ProducerReferenceTime {
        let boxes = try MP4BoxReader.parse(prft)
        guard boxes.count == 1, let box = boxes.first, box.type == "prft", box.size == prft.count, box.payloadSize >= 4 else {
            throw FMP4Error.malformedBox(offset: 0, reason: "expected exactly one prft box")
        }
        return try prft.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> ProducerReferenceTime in
            var fields = Fields(raw, box.payloadOffset, box.offset + box.size)
            let version = try fields.u8()
            guard version <= 1 else { throw FMP4Error.malformedBox(offset: box.offset, reason: "prft version \(version)") }
            try fields.skip(3)
            let trackID = try fields.u32()
            let ntp = try fields.u64()
            let media = version == 1 ? try fields.u64() : UInt64(try fields.u32())
            return ProducerReferenceTime(trackID: trackID, ntpTimestamp: ntp, mediaTime: media)
        }
    }

    // MARK: - Track fragment

    private static func parseTrackFragment(_ traf: MP4Box, raw: UnsafeRawBufferPointer, moofSize: Int,
                                           mdatPayloadSize: Int?) throws -> TrackFragmentHeader {
        guard let tfhd = traf.child("tfhd"), let tfdt = traf.child("tfdt") else {
            throw FMP4Error.malformedBox(offset: traf.offset, reason: "track fragment without tfhd or tfdt")
        }
        var head = Fields(raw, tfhd.payloadOffset, tfhd.offset + tfhd.size)
        _ = try head.u8()
        let headFlags = try head.u24()
        let trackID = try head.u32()
        guard headFlags & tfhdBaseDataOffset == 0, headFlags & tfhdDefaultBaseIsMoof != 0 else {
            throw FMP4Error.malformedBox(offset: tfhd.offset, reason: "tfhd without default-base-is-moof (or with a base data offset)")
        }
        if headFlags & tfhdSampleDescriptionIndex != 0 { try head.skip(4) }
        let defaultDuration = headFlags & tfhdDefaultDuration != 0 ? try head.u32() : 0
        let defaultSize = headFlags & tfhdDefaultSize != 0 ? try head.u32() : 0
        let defaultFlags = headFlags & tfhdDefaultFlags != 0 ? try head.u32() : 0

        var time = Fields(raw, tfdt.payloadOffset, tfdt.offset + tfdt.size)
        let timeVersion = try time.u8()
        try time.skip(3)
        let baseDecodeTime: UInt64
        switch timeVersion {
        case 0: baseDecodeTime = UInt64(try time.u32())
        case 1: baseDecodeTime = try time.u64()
        default: throw FMP4Error.malformedBox(offset: tfdt.offset, reason: "tfdt version \(timeVersion)")
        }

        let runs = traf.children(ofType: "trun")
        guard !runs.isEmpty else { throw FMP4Error.malformedBox(offset: traf.offset, reason: "track fragment without trun") }
        var samples: [TrackSample] = []
        var firstDataOffset: Int?
        var nextData = 0
        for run in runs {
            var fields = Fields(raw, run.payloadOffset, run.offset + run.size)
            let version = try fields.u8()
            let flags = try fields.u24()
            guard version <= 1 else { throw FMP4Error.malformedBox(offset: run.offset, reason: "trun version \(version)") }
            let count = Int(try fields.u32())
            guard count <= moofSize / 4 else { throw FMP4Error.malformedBox(offset: run.offset, reason: "sample_count \(count) cannot fit in the moof") }
            var offset: Int?
            if flags & trunDataOffset != 0 { offset = Int(try fields.i32()) }
            let firstFlags = flags & trunFirstSampleFlags != 0 ? try fields.u32() : nil
            let perSample = [trunDuration, trunSize, trunFlags, trunCompositionOffset].filter { flags & $0 != 0 }.count * 4
            guard fields.remaining == count * perSample else {
                throw FMP4Error.malformedBox(offset: run.offset, reason: "trun of \(count) samples does not match its size")
            }
            if firstDataOffset == nil {
                guard let offset, offset >= 0 else { throw FMP4Error.malformedBox(offset: run.offset, reason: "first trun without a data offset") }
                firstDataOffset = offset
                nextData = offset
            } else if let offset, offset != nextData {
                throw FMP4Error.malformedBox(offset: run.offset, reason: "trun data is not contiguous with the previous trun")
            }
            samples.reserveCapacity(samples.count + count)
            for index in 0..<count {
                let duration = flags & trunDuration != 0 ? try fields.u32() : defaultDuration
                let size = flags & trunSize != 0 ? try fields.u32() : defaultSize
                var sampleFlags = defaultFlags
                if flags & trunFlags != 0 {
                    sampleFlags = try fields.u32()
                } else if index == 0, let firstFlags {
                    sampleFlags = firstFlags
                }
                var composition: Int32 = 0
                if flags & trunCompositionOffset != 0 {
                    let value = try fields.u32()
                    if version == 1 {
                        composition = Int32(bitPattern: value)
                    } else {
                        guard value <= UInt32(Int32.max) else { throw FMP4Error.timestampOutOfRange("composition offset") }
                        composition = Int32(value)
                    }
                }
                guard size <= maximumSampleSize else { throw FMP4Error.malformedBox(offset: run.offset, reason: "sample of \(size) bytes") }
                let (end, overflow) = nextData.addingReportingOverflow(Int(size))
                guard !overflow else { throw FMP4Error.malformedBox(offset: run.offset, reason: "sample data overflows") }
                nextData = end
                samples.append(TrackSample(duration: duration, size: size, flags: sampleFlags, compositionOffset: composition,
                                           isSync: sampleFlags & 0x0001_0000 == 0))
            }
        }
        let dataOffset = firstDataOffset ?? 0
        if let mdatPayloadSize {
            let dataStart = moofSize + 8
            guard dataOffset >= dataStart, nextData - dataStart <= mdatPayloadSize else {
                throw FMP4Error.malformedBox(offset: traf.offset, reason: "samples lie outside the mdat")
            }
        }
        return TrackFragmentHeader(trackID: trackID, baseDecodeTime: baseDecodeTime, dataOffset: dataOffset, samples: samples)
    }
}

/// Big-endian reads inside `[position, end)` of a buffer; a read past `end` throws `FMP4Error.malformedBox` (it never traps).
struct Fields {
    private let raw: UnsafeRawBufferPointer
    private(set) var position: Int
    private let end: Int

    init(_ raw: UnsafeRawBufferPointer, _ position: Int, _ end: Int) {
        self.raw = raw
        self.position = position
        self.end = min(end, raw.count)
    }

    var remaining: Int { max(0, end - position) }

    private mutating func take(_ count: Int) throws -> Int {
        guard count >= 0, count <= remaining else { throw FMP4Error.malformedBox(offset: position, reason: "truncated box") }
        defer { position += count }
        return position
    }

    mutating func skip(_ count: Int) throws { _ = try take(count) }

    mutating func u8() throws -> UInt8 { raw[try take(1)] }

    mutating func u16() throws -> UInt16 {
        let at = try take(2)
        return UInt16(raw[at]) << 8 | UInt16(raw[at + 1])
    }

    mutating func u24() throws -> UInt32 {
        let at = try take(3)
        return UInt32(raw[at]) << 16 | UInt32(raw[at + 1]) << 8 | UInt32(raw[at + 2])
    }

    mutating func u32() throws -> UInt32 {
        let at = try take(4)
        return UInt32(raw[at]) << 24 | UInt32(raw[at + 1]) << 16 | UInt32(raw[at + 2]) << 8 | UInt32(raw[at + 3])
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func u64() throws -> UInt64 {
        let high = try u32()
        return UInt64(high) << 32 | UInt64(try u32())
    }
}
