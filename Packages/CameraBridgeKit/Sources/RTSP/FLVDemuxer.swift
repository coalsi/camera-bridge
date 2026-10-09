import BridgeSupport
import Foundation
import MediaCore

struct FLVVideoFrame: Sendable {
    /// No length prefixes; parameter sets and AUDs removed.
    var nalUnits: [Data]
    var isKeyframe: Bool
    /// Decode timestamp in milliseconds, unwrapped to 64 bits.
    var timestamp: Int64
    /// Composition time offset (pts − dts) in milliseconds.
    var compositionOffset: Int32
    var format: VideoFormat
}

struct FLVAudioFrame: Sendable {
    var data: Data
    var timestamp: Int64
    var format: AudioFormat
}

enum FLVSample: Sendable {
    case video(FLVVideoFrame)
    case audio(FLVAudioFrame)
}

/// Incremental FLV demuxer (Adobe FLV v10.1 Annex E) for HTTP-FLV camera streams: AVC (codec 7), HEVC as legacy
/// codec 12 or Enhanced RTMP `hvc1`/`avc1` FourCC video, AAC (format 10) and G.711 (formats 7/8) audio.
/// Frames before their sequence header are dropped; malformed tag bodies are skipped. Script and unknown tags are
/// ignored. Throws only for a stream that is not FLV or for an impossible tag size.
struct FLVDemuxer: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0
    private var headerParsed = false
    private var unwrapper = RTPTimestampUnwrapper()

    private var videoCodec: VideoCodec?
    private var videoFormat: VideoFormat?
    private var lengthSize = 4
    private var vps: Data?
    /// HEVC.
    private var sps: Data?
    private var pps: Data?
    /// H.264: the SPS / PPS of the configuration record (it may list several PPS).
    private var h264Sets = H264ParameterSetStore()
    private var audioFormat: AudioFormat?

    /// Tags larger than this are rejected (FLV allows 16 MiB; camera tags are far smaller).
    let maxTagSize = 8 * 1024 * 1024

    mutating func append(_ data: Data) throws -> [FLVSample] {
        if start > 0, start >= buffer.count / 2 {
            buffer.removeSubrange(0..<start)
            start = 0
        }
        buffer.append(contentsOf: data)
        var samples: [FLVSample] = []
        if !headerParsed {
            guard buffer.count - start >= 9 else {
                let available = min(3, buffer.count - start)
                if !buffer[start..<(start + available)].elementsEqual(Array("FLV".utf8).prefix(available)) {
                    throw RTSPError.protocolError("not an FLV stream")
                }
                return []
            }
            guard buffer[start] == 0x46, buffer[start + 1] == 0x4C, buffer[start + 2] == 0x56 else {
                throw RTSPError.protocolError("not an FLV stream")
            }
            let headerSize = Int(buffer[start + 5]) << 24 | Int(buffer[start + 6]) << 16 | Int(buffer[start + 7]) << 8 | Int(buffer[start + 8])
            guard headerSize >= 9, headerSize <= 1024 else { throw RTSPError.protocolError("invalid FLV header") }
            guard buffer.count - start >= headerSize + 4 else { return [] }
            start += headerSize + 4   // header + PreviousTagSize0
            headerParsed = true
        }
        while buffer.count - start >= 11 {
            let type = buffer[start] & 0x1F
            let encrypted = buffer[start] & 0x20 != 0
            let size = Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard size <= maxTagSize else { throw RTSPError.protocolError("FLV tag too large") }
            guard buffer.count - start >= 11 + size + 4 else { break }
            let timestamp = UInt32(buffer[start + 7]) << 24 | UInt32(buffer[start + 4]) << 16 | UInt32(buffer[start + 5]) << 8
                | UInt32(buffer[start + 6])
            let body = Array(buffer[(start + 11)..<(start + 11 + size)])
            start += 11 + size + 4
            guard !encrypted, !body.isEmpty else { continue }
            switch type {
            case 9:
                let dts = unwrapper.unwrap(timestamp)
                if let frame = parseVideo(body, timestamp: dts) { samples.append(.video(frame)) }
            case 8:
                let dts = unwrapper.unwrap(timestamp)
                if let frame = parseAudio(body, timestamp: dts) { samples.append(.audio(frame)) }
            default:
                continue   // script data and anything else
            }
        }
        return samples
    }

    // MARK: Video

    private mutating func parseVideo(_ body: [UInt8], timestamp: Int64) -> FLVVideoFrame? {
        let first = body[0]
        var index: Int
        var packetType: UInt8
        var compositionOffset: Int32 = 0
        if first & 0x80 != 0 {   // Enhanced RTMP ExHeader
            guard body.count >= 5 else { return nil }
            let frameType = (first >> 4) & 0x07
            packetType = first & 0x0F
            guard frameType != 5 else { return nil }   // command frame
            let fourCC = String(decoding: body[1..<5], as: UTF8.self)
            switch fourCC {
            case "hvc1": setVideoCodec(.hevc)
            case "avc1": setVideoCodec(.h264)
            default: return nil
            }
            index = 5
            switch packetType {
            case 0: return parseConfigurationRecord(body[index...])
            case 1:
                guard body.count >= index + 3 else { return nil }
                compositionOffset = Self.signed24(body[index], body[index + 1], body[index + 2])
                index += 3
            case 3: break
            default: return nil
            }
        } else {
            let codecID = first & 0x0F
            switch codecID {
            case 7: setVideoCodec(.h264)
            case 12: setVideoCodec(.hevc)
            default: return nil
            }
            guard body.count >= 5 else { return nil }
            packetType = body[1]
            compositionOffset = Self.signed24(body[2], body[3], body[4])
            index = 5
            switch packetType {
            case 0: return parseConfigurationRecord(body[index...])
            case 1: break
            default: return nil
            }
        }
        guard let codec = videoCodec else { return nil }

        var nalUnits: [Data] = []
        var hasIDR = false
        var changed = false
        while index < body.count {
            guard index + lengthSize <= body.count else { return nil }
            var length = 0
            for k in 0..<lengthSize { length = length << 8 | Int(body[index + k]) }
            index += lengthSize
            guard length > 0, index + length <= body.count else { return nil }
            let nal = Data(body[index..<(index + length)])
            index += length
            switch codec {
            case .h264:
                switch NALUnits.h264Type(nal) {
                case 7, 8: if h264Sets.add(nal) { changed = true }
                case 9, 10, 11, 12: break
                case 5: hasIDR = true; nalUnits.append(nal)
                default: nalUnits.append(nal)
                }
            case .hevc:
                switch NALUnits.hevcType(nal) {
                case 32: if vps != nal { vps = nal; changed = true }
                case 33: if sps != nal { sps = nal; changed = true }
                case 34: if pps != nal { pps = nal; changed = true }
                case 35, 36, 37, 38: break
                case 16...21: hasIDR = true; nalUnits.append(nal)
                default: nalUnits.append(nal)
                }
            }
        }
        if changed { rebuildVideoFormat() }
        guard let format = videoFormat, !nalUnits.isEmpty else { return nil }
        return FLVVideoFrame(nalUnits: nalUnits, isKeyframe: hasIDR, timestamp: timestamp,
                             compositionOffset: compositionOffset, format: format)
    }

    private mutating func setVideoCodec(_ codec: VideoCodec) {
        guard videoCodec != codec else { return }
        videoCodec = codec
        videoFormat = nil
        vps = nil
        sps = nil
        pps = nil
        h264Sets = H264ParameterSetStore()
    }

    /// AVCDecoderConfigurationRecord (ISO/IEC 14496-15 §5.3.3.1) or HEVCDecoderConfigurationRecord (§8.3.3.1).
    private mutating func parseConfigurationRecord(_ record: ArraySlice<UInt8>) -> FLVVideoFrame? {
        let bytes = Array(record)
        switch videoCodec {
        case .h264:
            guard bytes.count >= 7 else { return nil }
            lengthSize = Int(bytes[4] & 0x03) + 1
            var index = 5
            let spsCount = Int(bytes[index] & 0x1F)
            index += 1
            var spsList: [Data] = []
            for _ in 0..<spsCount {
                guard let (nal, next) = Self.lengthPrefixed16(bytes, at: index) else { return nil }
                spsList.append(nal)
                index = next
            }
            guard index < bytes.count else { return nil }
            let ppsCount = Int(bytes[index])
            index += 1
            var ppsList: [Data] = []
            for _ in 0..<ppsCount {
                guard let (nal, next) = Self.lengthPrefixed16(bytes, at: index) else { return nil }
                ppsList.append(nal)
                index = next
            }
            h264Sets = H264ParameterSetStore(parameterSets: spsList + ppsList)
        case .hevc:
            guard bytes.count >= 23 else { return nil }
            lengthSize = Int(bytes[21] & 0x03) + 1
            let arrays = Int(bytes[22])
            var index = 23
            for _ in 0..<arrays {
                guard index + 3 <= bytes.count else { return nil }
                let type = bytes[index] & 0x3F
                let count = Int(bytes[index + 1]) << 8 | Int(bytes[index + 2])
                index += 3
                for n in 0..<count {
                    guard let (nal, next) = Self.lengthPrefixed16(bytes, at: index) else { return nil }
                    index = next
                    guard n == 0 else { continue }
                    switch type {
                    case 32: vps = nal
                    case 33: sps = nal
                    case 34: pps = nal
                    default: break
                    }
                }
            }
        case nil:
            return nil
        }
        rebuildVideoFormat()
        return nil
    }

    private mutating func rebuildVideoFormat() {
        switch videoCodec {
        case .h264:
            guard let format = h264Sets.format else { return }
            videoFormat = format
        case .hevc:
            guard let vps, let sps, let pps else { return }
            videoFormat = RTSPSessionDescription.makeHEVCFormat(vps: vps, sps: sps, pps: pps)
        case nil:
            break
        }
    }

    // MARK: Audio

    private mutating func parseAudio(_ body: [UInt8], timestamp: Int64) -> FLVAudioFrame? {
        let soundFormat = body[0] >> 4
        let channels = body[0] & 0x01 == 1 ? 2 : 1
        switch soundFormat {
        case 10:   // AAC
            guard body.count >= 2 else { return nil }
            let payload = Data(body[2...])
            if body[1] == 0 {
                guard !payload.isEmpty else { return nil }
                let parsed = AudioSpecificConfig(payload)
                audioFormat = AudioFormat(codec: parsed?.objectType == AudioSpecificConfig.aacELD ? .aacELD : .aac, sampleRate: parsed?.sampleRate ?? 44_100,
                                          channels: parsed.map { $0.channels > 0 ? $0.channels : channels } ?? channels,
                                          audioSpecificConfig: payload)
                return nil
            }
            guard let format = audioFormat, !payload.isEmpty else { return nil }
            return FLVAudioFrame(data: payload, timestamp: timestamp, format: format)
        case 7, 8:   // G.711 A-law / µ-law, always 8 kHz
            let payload = Data(body[1...])
            guard !payload.isEmpty else { return nil }
            let format = AudioFormat(codec: soundFormat == 7 ? .pcma : .pcmu, sampleRate: 8000, channels: channels)
            return FLVAudioFrame(data: payload, timestamp: timestamp, format: format)
        default:
            return nil
        }
    }

    // MARK: Helpers

    private static func signed24(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Int32 {
        let raw = Int32(a) << 16 | Int32(b) << 8 | Int32(c)
        return raw & 0x80_0000 != 0 ? raw - 0x100_0000 : raw
    }

    private static func lengthPrefixed16(_ bytes: [UInt8], at index: Int) -> (Data, Int)? {
        guard index + 2 <= bytes.count else { return nil }
        let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        guard length > 0, index + 2 + length <= bytes.count else { return nil }
        return (Data(bytes[(index + 2)..<(index + 2 + length)]), index + 2 + length)
    }
}
