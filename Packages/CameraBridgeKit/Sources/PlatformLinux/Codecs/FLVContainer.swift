import Foundation
import MediaCore

// FLV is the framing between this process and ffmpeg for compressed video and AAC: every tag carries its own size and a
// timestamp, so a frame is complete the moment its bytes arrive (no demuxer or parser waits for the next frame), and the
// writer and the reader are small. Timestamps are milliseconds; callers keep a table from the millisecond value back to
// the exact 90 kHz time (`FFmpegVideoTranscoder`).

/// One FLV tag read from ffmpeg's output.
struct FLVTag: Sendable, Equatable {
    enum Kind: UInt8, Sendable { case audio = 8, video = 9, script = 18 }
    var kind: Kind
    /// Milliseconds (the tag's timestamp, extended to 32 bits).
    var timestamp: UInt32
    var payload: Data
}

enum FLVWriter {
    static func fileHeader(video: Bool, audio: Bool) -> Data {
        var data = Data("FLV".utf8)
        data.append(1)
        data.append((audio ? 0x04 : 0) | (video ? 0x01 : 0))
        data.append(contentsOf: [0, 0, 0, 9])
        data.append(contentsOf: [0, 0, 0, 0])   // PreviousTagSize0
        return data
    }

    static func tag(_ kind: FLVTag.Kind, timestamp: UInt32, payload: Data) -> Data {
        var data = Data(capacity: payload.count + 15)
        data.append(kind.rawValue)
        data.appendUInt24(UInt32(payload.count))
        data.appendUInt24(timestamp & 0xFF_FFFF)
        data.append(UInt8(truncatingIfNeeded: timestamp >> 24))
        data.appendUInt24(0)   // stream id
        data.append(payload)
        data.appendUInt32(UInt32(payload.count + 11))
        return data
    }

    // MARK: Video

    /// The sequence header tag: avcC for H.264, hvcC (Enhanced FLV, FourCC `hvc1`) for HEVC.
    static func videoSequenceHeader(_ format: VideoFormat) -> Data? {
        switch format.codec {
        case .h264:
            guard let record = avcDecoderConfigurationRecord(format) else { return nil }
            return tag(.video, timestamp: 0, payload: Data([0x17, 0, 0, 0, 0]) + record)
        case .hevc:
            guard let record = hevcDecoderConfigurationRecord(format) else { return nil }
            return tag(.video, timestamp: 0, payload: Data([0x80 | 0x10 | 0]) + Data("hvc1".utf8) + record)
        }
    }

    /// One access unit as a video tag. `dtsMs` is the tag timestamp, `ptsMs - dtsMs` the composition offset. `nalUnits` are
    /// written length-prefixed (4 bytes); a keyframe gets the format's parameter sets in front, so a decoder that missed the
    /// sequence header (a further PPS) still has them.
    static func videoFrame(format: VideoFormat, nalUnits: [Data], isKeyframe: Bool, dtsMs: UInt32, ptsMs: UInt32, inBandParameterSets: Bool) -> Data {
        var body = Data()
        if inBandParameterSets {
            for set in format.parameterSets {
                body.appendUInt32(UInt32(set.count))
                body.append(set)
            }
        }
        for nal in nalUnits {
            body.appendUInt32(UInt32(nal.count))
            body.append(nal)
        }
        let composition = Int64(ptsMs) - Int64(dtsMs)
        let payload: Data
        switch format.codec {
        case .h264:
            var header = Data([isKeyframe ? 0x17 : 0x27, 1])
            header.appendInt24(Int32(clamping: composition))
            payload = header + body
        case .hevc:
            // PacketType 1: CodedFrames (with composition time).
            var header = Data([0x80 | (isKeyframe ? 0x10 : 0x20) | 1])
            header.append(Data("hvc1".utf8))
            header.appendInt24(Int32(clamping: composition))
            payload = header + body
        }
        return tag(.video, timestamp: dtsMs, payload: payload)
    }

    // MARK: Audio

    static func aacSequenceHeader(audioSpecificConfig: Data) -> Data {
        tag(.audio, timestamp: 0, payload: Data([0xAF, 0]) + audioSpecificConfig)
    }

    static func aacFrame(_ accessUnit: Data, timestamp: UInt32) -> Data {
        tag(.audio, timestamp: timestamp, payload: Data([0xAF, 1]) + accessUnit)
    }

    // MARK: Decoder configuration records

    static func avcDecoderConfigurationRecord(_ format: VideoFormat) -> Data? {
        let sps = format.parameterSets.filter { NALUnits.h264Type($0) == 7 }
        let pps = format.parameterSets.filter { NALUnits.h264Type($0) == 8 }
        guard let first = sps.first, first.count >= 4, !pps.isEmpty else { return nil }
        let bytes = [UInt8](first)
        var record = Data([1, bytes[1], bytes[2], bytes[3], 0xFF, 0xE0 | UInt8(sps.count)])
        for set in sps {
            record.appendUInt16(UInt16(set.count))
            record.append(set)
        }
        record.append(UInt8(pps.count))
        for set in pps {
            record.appendUInt16(UInt16(set.count))
            record.append(set)
        }
        return record
    }

    /// hvcC with the parameter-set arrays ffmpeg's decoder reads; the profile fields come from `VideoFormat` (the decoder parses the SPS itself).
    static func hevcDecoderConfigurationRecord(_ format: VideoFormat) -> Data? {
        guard format.parameterSets.count >= 3 else { return nil }
        var record = Data([1, format.profile & 0x1F])
        record.appendUInt32(0)                       // general_profile_compatibility_flags
        record.append(contentsOf: [UInt8](repeating: 0, count: 6))   // constraint indicator flags
        record.append(format.level)
        record.appendUInt16(0xF000)                  // min_spatial_segmentation_idc
        record.append(0xFC)                          // parallelismType
        record.append(0xFD)                          // chroma_format_idc 1 (4:2:0)
        record.append(0xF8)                          // bit depth luma 8
        record.append(0xF8)                          // bit depth chroma 8
        record.appendUInt16(0)                       // avgFrameRate
        record.append(0x0B)                          // constantFrameRate 0, 1 temporal layer, nested, lengthSizeMinusOne 3
        let types: [UInt8] = [32, 33, 34]
        record.append(UInt8(types.count))
        for (index, type) in types.enumerated() {
            record.append(0x80 | type)
            record.appendUInt16(1)
            record.appendUInt16(UInt16(format.parameterSets[index].count))
            record.append(format.parameterSets[index])
        }
        return record
    }
}

/// Reads FLV from ffmpeg's stdout incrementally: `push` bytes as they arrive, get the complete tags.
struct FLVReader {
    private var buffer = Data()
    private var sawHeader = false
    /// Set when the bytes are not FLV.
    private(set) var failed = false

    mutating func push(_ data: Data) -> [FLVTag] {
        guard !failed else { return [] }
        buffer.append(data)
        var tags: [FLVTag] = []
        var offset = buffer.startIndex
        if !sawHeader {
            guard buffer.count >= 13 else { return [] }
            guard buffer.prefix(3) == Data("FLV".utf8) else {
                failed = true
                buffer = Data()
                return []
            }
            let headerSize = Int(buffer.readUInt32(at: buffer.startIndex + 5))
            guard headerSize >= 9 else {
                failed = true
                buffer = Data()
                return []
            }
            guard buffer.count >= headerSize + 4 else { return [] }
            offset = buffer.startIndex + headerSize + 4
            sawHeader = true
        }
        while buffer.endIndex - offset >= 11 {
            let size = Int(buffer.readUInt24(at: offset + 1))
            guard buffer.endIndex - offset >= 11 + size + 4 else { break }
            let timestamp = buffer.readUInt24(at: offset + 4) | UInt32(buffer[offset + 7]) << 24
            if let kind = FLVTag.Kind(rawValue: buffer[offset] & 0x1F) {
                tags.append(FLVTag(kind: kind, timestamp: timestamp, payload: Data(buffer[(offset + 11)..<(offset + 11 + size)])))
            }
            offset += 11 + size + 4
        }
        buffer = Data(buffer[offset...])
        return tags
    }

    var bufferedBytes: Int { buffer.count }
}

/// A decoded video tag of an AVC (H.264) stream.
enum FLVAVCPacket: Equatable {
    case sequenceHeader(Data)
    case frame(isKeyframe: Bool, compositionMs: Int32, nalUnits: [Data])
    case endOfSequence

    /// nil for a payload that is not AVC video.
    static func parse(_ tag: FLVTag, lengthSize: Int = 4) -> FLVAVCPacket? {
        guard tag.kind == .video, tag.payload.count >= 5 else { return nil }
        let bytes = tag.payload
        let start = bytes.startIndex
        guard bytes[start] & 0x0F == 7 else { return nil }
        let isKeyframe = bytes[start] >> 4 == 1
        switch bytes[start + 1] {
        case 0: return .sequenceHeader(Data(bytes.dropFirst(5)))
        case 1:
            return .frame(isKeyframe: isKeyframe, compositionMs: bytes.readInt24(at: start + 2),
                          nalUnits: NALUnits.splitLengthPrefixed(Data(bytes.dropFirst(5)), lengthSize: lengthSize))
        case 2: return .endOfSequence
        default: return nil
        }
    }

    /// SPS and PPS of an avcC record, and its NAL length size.
    static func parameterSets(avcC record: Data) -> (sps: [Data], pps: [Data], lengthSize: Int)? {
        let bytes = [UInt8](record)
        guard bytes.count >= 7, bytes[0] == 1 else { return nil }
        var index = 5
        let spsCount = Int(bytes[index] & 0x1F)
        index += 1
        var sps: [Data] = []
        for _ in 0..<spsCount {
            guard index + 2 <= bytes.count else { return nil }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            index += 2
            guard index + length <= bytes.count else { return nil }
            sps.append(Data(bytes[index..<(index + length)]))
            index += length
        }
        guard index < bytes.count else { return nil }
        let ppsCount = Int(bytes[index])
        index += 1
        var pps: [Data] = []
        for _ in 0..<ppsCount {
            guard index + 2 <= bytes.count else { return nil }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            index += 2
            guard index + length <= bytes.count else { return nil }
            pps.append(Data(bytes[index..<(index + length)]))
            index += length
        }
        return (sps, pps, Int(bytes[4] & 3) + 1)
    }
}

/// A decoded audio tag of an AAC stream.
enum FLVAACPacket: Equatable {
    case sequenceHeader(Data)
    case frame(Data)

    static func parse(_ tag: FLVTag) -> FLVAACPacket? {
        guard tag.kind == .audio, tag.payload.count >= 2 else { return nil }
        let start = tag.payload.startIndex
        guard tag.payload[start] >> 4 == 10 else { return nil }
        let body = Data(tag.payload.dropFirst(2))
        switch tag.payload[start + 1] {
        case 0: return .sequenceHeader(body)
        case 1: return .frame(body)
        default: return nil
        }
    }
}

// MARK: - Byte helpers

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt24(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendInt24(_ value: Int32) {
        appendUInt24(UInt32(bitPattern: value) & 0xFF_FFFF)
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    func readUInt24(at index: Index) -> UInt32 {
        UInt32(self[index]) << 16 | UInt32(self[index + 1]) << 8 | UInt32(self[index + 2])
    }

    /// Sign-extended 24-bit value.
    func readInt24(at index: Index) -> Int32 {
        let value = readUInt24(at: index)
        return value & 0x80_0000 != 0 ? Int32(bitPattern: value | 0xFF00_0000) : Int32(value)
    }

    func readUInt32(at index: Index) -> UInt32 {
        UInt32(self[index]) << 24 | UInt32(self[index + 1]) << 16 | UInt32(self[index + 2]) << 8 | UInt32(self[index + 3])
    }
}
