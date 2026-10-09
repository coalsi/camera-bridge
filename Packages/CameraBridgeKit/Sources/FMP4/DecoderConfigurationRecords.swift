import Foundation
import MediaCore

// Sample-entry configuration payloads: ISO/IEC 14496-15 §5.3.3.1 (AVCDecoderConfigurationRecord, 'avcC') and §8.3.3.1
// (HEVCDecoderConfigurationRecord, 'hvcC'); ISO/IEC 14496-1 §7.2.6.5 ES_Descriptor ('esds', ISO/IEC 14496-14 §3.1.2).
// Parameter sets are classified by NAL unit type, so their order in `VideoFormat.parameterSets` does not matter. SPS fields
// come from MediaCore's `H264SPS` / `HEVCSPS` parsers.

enum AVCDecoderConfigurationRecord {
    /// profile_idc values whose avcC carries chroma format / bit depth / SPS-extension fields.
    private static let extendedProfiles: Set<UInt8> = [100, 110, 122, 144]

    /// avcC payload with 4-byte NAL length prefixes (lengthSizeMinusOne = 3).
    static func make(parameterSets: [Data]) throws -> Data {
        let sps = parameterSets.filter { $0.first.map { $0 & 0x1F == 7 } ?? false }
        let pps = parameterSets.filter { $0.first.map { $0 & 0x1F == 8 } ?? false }
        let spsExtensions = parameterSets.filter { $0.first.map { $0 & 0x1F == 13 } ?? false }
        guard let first = sps.first, first.count >= 4 else { throw FMP4Error.invalidParameterSets("H.264 needs an SPS") }
        guard !pps.isEmpty else { throw FMP4Error.invalidParameterSets("H.264 needs a PPS") }
        guard sps.count <= 31, pps.count <= 255, spsExtensions.count <= 255 else {
            throw FMP4Error.invalidParameterSets("too many H.264 parameter sets")
        }
        let bytes = [UInt8](first)
        var writer = BoxWriter()
        writer.u8(1)                                  // configurationVersion
        writer.u8(bytes[1])                           // AVCProfileIndication
        writer.u8(bytes[2])                           // profile_compatibility
        writer.u8(bytes[3])                           // AVCLevelIndication
        writer.u8(0xFC | 3)                           // reserved '111111' + lengthSizeMinusOne
        writer.u8(0xE0 | UInt8(sps.count))            // reserved '111' + numOfSequenceParameterSets
        for set in sps { try appendSized(set, to: &writer) }
        writer.u8(UInt8(pps.count))
        for set in pps { try appendSized(set, to: &writer) }
        if extendedProfiles.contains(bytes[1]) {
            // chroma_format_idc and bit depths; 4:2:0 8-bit when the SPS does not parse.
            let parsed = H264SPS.parse(first)
            writer.u8(0xFC | (parsed?.chromaFormatIDC ?? 1))
            writer.u8(0xF8 | (parsed?.bitDepthLumaMinus8 ?? 0))
            writer.u8(0xF8 | (parsed?.bitDepthChromaMinus8 ?? 0))
            writer.u8(UInt8(spsExtensions.count))
            for set in spsExtensions { try appendSized(set, to: &writer) }
        }
        return writer.data
    }
}

enum HEVCDecoderConfigurationRecord {
    /// hvcC payload with 4-byte NAL length prefixes, array_completeness = 1 for VPS/SPS/PPS (required by `hvc1`).
    static func make(parameterSets: [Data]) throws -> Data {
        func units(_ type: UInt8) -> [Data] {
            parameterSets.filter { $0.count >= 2 && ($0[$0.startIndex] >> 1) & 0x3F == type }
        }
        let vps = units(32), sps = units(33), pps = units(34)
        guard !vps.isEmpty, !sps.isEmpty, !pps.isEmpty else { throw FMP4Error.invalidParameterSets("HEVC needs a VPS, an SPS and a PPS") }
        // The hvcC needs the SPS up to its bit depths, each within the record's 3-bit field.
        guard let first = sps.first, let info = HEVCSPS.parse(first), let luma = info.bitDepthLumaMinus8, let chroma = info.bitDepthChromaMinus8,
              luma <= 7, chroma <= 7 else {
            throw FMP4Error.invalidParameterSets("unparsable HEVC SPS")
        }

        var writer = BoxWriter()
        writer.u8(1)                                                        // configurationVersion
        writer.u8(info.generalProfileSpace << 6 | (info.generalTierFlag ? 0x20 : 0) | info.generalProfileIDC)
        writer.u32(info.generalProfileCompatibilityFlags)
        writer.u16(UInt16(truncatingIfNeeded: info.generalConstraintIndicatorFlags >> 32))
        writer.u32(UInt32(truncatingIfNeeded: info.generalConstraintIndicatorFlags))
        writer.u8(info.generalLevelIDC)
        writer.u16(0xF000)                                                  // reserved + min_spatial_segmentation_idc 0
        writer.u8(0xFC)                                                     // reserved + parallelismType 0 (unknown)
        writer.u8(0xFC | info.chromaFormatIDC)
        writer.u8(0xF8 | luma)
        writer.u8(0xF8 | chroma)
        writer.u16(0)                                                       // avgFrameRate unknown
        // constantFrameRate 0 | numTemporalLayers(3) | temporalIdNested(1) | lengthSizeMinusOne 3
        writer.u8(((info.maxSubLayersMinus1 + 1) & 0x07) << 3 | (info.temporalIDNesting ? 0x04 : 0) | 0x03)
        let arrays: [(type: UInt8, complete: Bool, units: [Data])] = [
            (32, true, vps), (33, true, sps), (34, true, pps), (39, false, units(39)), (40, false, units(40)),
        ].filter { !$0.units.isEmpty }
        writer.u8(UInt8(arrays.count))
        for array in arrays {
            guard array.units.count <= 0xFFFF else { throw FMP4Error.invalidParameterSets("too many HEVC NAL units of type \(array.type)") }
            writer.u8((array.complete ? 0x80 : 0) | array.type)
            writer.u16(UInt16(array.units.count))
            for unit in array.units { try appendSized(unit, to: &writer) }
        }
        return writer.data
    }
}

enum ElementaryStreamDescriptor {
    /// ES_Descriptor for an MPEG-4 audio stream: DecoderConfigDescriptor (objectTypeIndication 0x40, streamType audio)
    /// wrapping the AudioSpecificConfig as DecoderSpecificInfo, plus SLConfigDescriptor predefined = 2. ES_ID is 0 as
    /// stored in a file (ISO/IEC 14496-14 §3.1.2); buffer size and bitrates are 0 (unknown / variable).
    static func make(audioSpecificConfig: Data) -> Data {
        var decoderSpecificInfo = BoxWriter()
        descriptor(tag: 0x05, body: [UInt8](audioSpecificConfig), into: &decoderSpecificInfo)

        var decoderConfig = BoxWriter()
        decoderConfig.u8(0x40)                  // objectTypeIndication: Audio ISO/IEC 14496-3
        decoderConfig.u8(0x05 << 2 | 0x01)      // streamType 5 (audio), upStream 0, reserved 1
        decoderConfig.u24(0)                    // bufferSizeDB
        decoderConfig.u32(0)                    // maxBitrate
        decoderConfig.u32(0)                    // avgBitrate
        decoderConfig.append(decoderSpecificInfo.bytes)

        var body = BoxWriter()
        body.u16(0)                             // ES_ID
        body.u8(0)                              // streamDependenceFlag, URL_Flag, OCRstreamFlag, streamPriority
        descriptor(tag: 0x04, body: decoderConfig.bytes, into: &body)
        descriptor(tag: 0x06, body: [0x02], into: &body)

        var es = BoxWriter()
        descriptor(tag: 0x03, body: body.bytes, into: &es)
        return es.data
    }

    /// `tag | expandable size (7 bits per byte, high bit = more) | body`.
    private static func descriptor(tag: UInt8, body: [UInt8], into writer: inout BoxWriter) {
        writer.u8(tag)
        var groups = [UInt8(body.count & 0x7F)]
        var remaining = body.count >> 7
        while remaining > 0 {
            groups.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
            remaining >>= 7
        }
        writer.append(groups)
        writer.append(body)
    }
}

private func appendSized(_ unit: Data, to writer: inout BoxWriter) throws {
    guard unit.count <= 0xFFFF else { throw FMP4Error.invalidParameterSets("parameter set of \(unit.count) bytes") }
    writer.u16(UInt16(unit.count))
    writer.append(unit)
}
