#if os(macOS)
import AudioToolbox
import CoreMedia
import Foundation
import MediaCore

// CoreMedia format descriptions for the portable MediaCore formats (CoreMedia is not portable, so these live here).

extension VideoFormat {
    /// H.264 (avcC from `[SPS, PPS]`) or HEVC (hvcC from `[VPS, SPS, PPS]`), 4-byte NAL length prefixes.
    /// Throws `MediaCodecError.unsupported` for missing parameter sets, `.sessionFailed(status)` if CoreMedia rejects them.
    public func makeFormatDescription() throws -> CMVideoFormatDescription {
        let required = codec == .h264 ? 2 : 3
        guard parameterSets.count >= required, parameterSets.allSatisfy({ !$0.isEmpty }) else {
            throw MediaCodecError.unsupported("\(codec) format description needs \(required) parameter sets, got \(parameterSets.count)")
        }
        let contiguous = parameterSets.reduce(into: [UInt8]()) { $0.append(contentsOf: $1) }
        let sizes = parameterSets.map(\.count)
        var description: CMFormatDescription?
        let status: OSStatus = contiguous.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for size in sizes {
                pointers.append(base + offset)
                offset += size
            }
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: pointers.count,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: pointers.count,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { throw MediaCodecError.sessionFailed(status) }
        return description
    }
}

extension AudioFormat {
    /// AAC / AAC-ELD (magic cookie = MPEG-4 ES_Descriptor wrapping `audioSpecificConfig`), Opus (20 ms packets),
    /// PCMU/PCMA (8-bit) or LPCM (16-bit signed, packed, native endian).
    /// Throws `MediaCodecError.unsupported` for invalid parameters, `.sessionFailed(status)` if CoreMedia rejects them.
    public func makeFormatDescription() throws -> CMAudioFormatDescription {
        guard sampleRate > 0, channels > 0, channels <= 8 else {
            throw MediaCodecError.unsupported("\(codec) audio with \(sampleRate) Hz / \(channels) channels")
        }
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = Float64(sampleRate)
        asbd.mChannelsPerFrame = UInt32(channels)
        var cookie = Data()
        switch codec {
        case .aac, .aacELD:
            guard let config = audioSpecificConfig, !config.isEmpty else {
                throw MediaCodecError.unsupported("\(codec) format description needs an AudioSpecificConfig")
            }
            asbd.mFormatID = codec == .aac ? kAudioFormatMPEG4AAC : kAudioFormatMPEG4AAC_ELD
            asbd.mFramesPerPacket = UInt32(samplesPerFrame)
            cookie = MPEG4ESDescriptor.make(audioSpecificConfig: config)
        case .opus:
            asbd.mFormatID = kAudioFormatOpus
            asbd.mFramesPerPacket = UInt32(max(1, sampleRate / 50))
        case .pcmu, .pcma:
            asbd.mFormatID = codec == .pcmu ? kAudioFormatULaw : kAudioFormatALaw
            asbd.mFramesPerPacket = 1
            asbd.mBytesPerFrame = UInt32(channels)
            asbd.mBytesPerPacket = UInt32(channels)
            asbd.mBitsPerChannel = 8
        case .linearPCM:
            asbd.mFormatID = kAudioFormatLinearPCM
            asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            asbd.mFramesPerPacket = 1
            asbd.mBytesPerFrame = UInt32(2 * channels)
            asbd.mBytesPerPacket = UInt32(2 * channels)
            asbd.mBitsPerChannel = 16
        }
        var description: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: bytes.count,
                                           magicCookie: bytes.isEmpty ? nil : bytes.baseAddress, extensions: nil,
                                           formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { throw MediaCodecError.sessionFailed(status) }
        return description
    }
}

/// MPEG-4 Systems (ISO/IEC 14496-1 §7.2.6.5) ES_Descriptor for an AAC stream: the payload of an `esds` box and the
/// AudioToolbox magic cookie for AAC.
enum MPEG4ESDescriptor {
    static func make(audioSpecificConfig: Data) -> Data {
        var decoderSpecificInfo = Data([0x05])
        decoderSpecificInfo.append(expandableSize(audioSpecificConfig.count))
        decoderSpecificInfo.append(audioSpecificConfig)

        var decoderConfig = Data([0x40,                // objectTypeIndication: MPEG-4 Audio
                                  0x15,                // streamType 5 (audio) << 2 | upStream 0 | reserved 1
                                  0x00, 0x00, 0x00,    // bufferSizeDB
                                  0x00, 0x00, 0x00, 0x00,   // maxBitrate
                                  0x00, 0x00, 0x00, 0x00])  // avgBitrate
        decoderConfig.append(decoderSpecificInfo)
        var decoderConfigDescriptor = Data([0x04])
        decoderConfigDescriptor.append(expandableSize(decoderConfig.count))
        decoderConfigDescriptor.append(decoderConfig)

        let slConfigDescriptor = Data([0x06, 0x01, 0x02])   // predefined = 2 (MP4 file)

        var body = Data([0x00, 0x00, 0x00])                // ES_ID 0, no dependency/URL/OCR flags, priority 0
        body.append(decoderConfigDescriptor)
        body.append(slConfigDescriptor)
        var descriptor = Data([0x03])
        descriptor.append(expandableSize(body.count))
        descriptor.append(body)
        return descriptor
    }

    /// The AudioSpecificConfig (DecoderSpecificInfo, tag 5) inside an ES_Descriptor (tag 3 → DecoderConfigDescriptor,
    /// tag 4 → tag 5), e.g. an AudioToolbox encoder's magic cookie. Data that does not start with tag 3 is taken to be a
    /// bare AudioSpecificConfig (whose first byte is never 0x03: audio object type 0 is invalid). Nil if malformed.
    static func audioSpecificConfig(in cookie: Data) -> Data? {
        let bytes = [UInt8](cookie)
        guard let first = bytes.first else { return nil }
        guard first == 0x03 else { return Data(bytes) }
        return decoderSpecificInfo(bytes, from: 0, to: bytes.count)
    }

    private static func decoderSpecificInfo(_ bytes: [UInt8], from start: Int, to end: Int) -> Data? {
        var index = start
        while index < end {
            let tag = bytes[index]
            index += 1
            var size = 0
            for _ in 0..<4 {
                guard index < end else { return nil }
                let byte = bytes[index]
                index += 1
                size = size << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            guard size <= end - index else { return nil }
            let bodyEnd = index + size
            switch tag {
            case 0x03:   // ES_ID (2), flags (1), optional dependsOn_ES_ID (2), URL (length-prefixed), OCR_ES_ID (2)
                var body = index + 2
                guard body < bodyEnd else { return nil }
                let flags = bytes[body]
                body += 1
                if flags & 0x80 != 0 { body += 2 }
                if flags & 0x40 != 0 {
                    guard body < bodyEnd else { return nil }
                    body += 1 + Int(bytes[body])
                }
                if flags & 0x20 != 0 { body += 2 }
                guard body <= bodyEnd else { return nil }
                return decoderSpecificInfo(bytes, from: body, to: bodyEnd)
            case 0x04:   // objectType, streamType, bufferSizeDB (3), maxBitrate (4), avgBitrate (4), then descriptors
                guard index + 13 <= bodyEnd else { return nil }
                return decoderSpecificInfo(bytes, from: index + 13, to: bodyEnd)
            case 0x05:
                return size > 0 ? Data(bytes[index..<bodyEnd]) : nil
            default:
                index = bodyEnd
            }
        }
        return nil
    }

    /// Descriptor size in 7-bit groups, high bit = more bytes follow.
    static func expandableSize(_ size: Int) -> Data {
        var groups = [UInt8(size & 0x7F)]
        var remaining = size >> 7
        while remaining > 0 {
            groups.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
            remaining >>= 7
        }
        return Data(groups)
    }
}
#endif
