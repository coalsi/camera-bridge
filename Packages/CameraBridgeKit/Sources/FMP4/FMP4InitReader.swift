import Foundation
import MediaCore

/// What an initialization segment (`ftyp` + `moov`) says about the tracks.
public struct FMP4InitInfo: Sendable, Equatable {
    /// Parameter sets in live order: [SPS, PPS] for H.264, [VPS, SPS, PPS] for HEVC.
    public var video: VideoFormat
    public var videoTimescale: Int32
    /// 1...4: the size of the length prefix of each NAL unit in a sample.
    public var nalLengthSize: Int
    public var videoTrackID: UInt32
    public var audio: AudioFormat?
    public var audioTrackID: UInt32?
    /// Bytes of `ftyp` + `moov` (where the first fragment starts).
    public var byteCount: Int

    public init(video: VideoFormat, videoTimescale: Int32, nalLengthSize: Int, videoTrackID: UInt32, audio: AudioFormat?, audioTrackID: UInt32?,
                byteCount: Int) {
        self.video = video
        self.videoTimescale = videoTimescale
        self.nalLengthSize = nalLengthSize
        self.videoTrackID = videoTrackID
        self.audio = audio
        self.audioTrackID = audioTrackID
        self.byteCount = byteCount
    }
}

/// Reads the initialization segment `FMP4Muxer` writes: the codec configuration (`avc1`/`avc3` + `avcC`, `hvc1`/`hev1` + `hvcC`), the track timescales
/// and ids, and the AAC `mp4a` + `esds` when the file has sound. Parameter sets come back in live order ([SPS, PPS] for H.264, [VPS, SPS, PPS] for
/// HEVC; an H.264 SPS extension follows the PPS), so `info.video == the VideoFormat the muxer was given` for a format whose width and height are set.
/// `data` may hold more than the init segment (a whole file, a prefix of one): `byteCount` says where `ftyp` + `moov` end. Every failure is
/// `FMP4Error.malformedBox`; it never traps.
public enum FMP4InitReader {
    public static func parse(_ data: Data) throws -> FMP4InitInfo {
        let byteCount = try initializationLength(of: data)
        let initialization = data.prefix(byteCount)
        let boxes = try MP4BoxReader.parse(Data(initialization))
        guard let moov = boxes.first(where: { $0.type == "moov" }) else { throw FMP4Error.malformedBox(offset: 0, reason: "no moov box") }
        return try Data(initialization).withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> FMP4InitInfo in
            var video: (format: VideoFormat, timescale: Int32, nalLengthSize: Int, trackID: UInt32)?
            var audio: (format: AudioFormat, trackID: UInt32)?
            for trak in moov.children(ofType: "trak") {
                guard let handler = trak.descendant(atPath: "mdia/hdlr"), let header = trak.child("tkhd"), let media = trak.descendant(atPath: "mdia/mdhd"),
                      let entry = trak.descendant(atPath: "mdia/minf/stbl/stsd") else {
                    continue
                }
                var handlerFields = Fields(raw, handler.payloadOffset + 8, handler.offset + handler.size)
                let kind = try handlerFields.u32()
                let trackID = try trackID(of: header, raw: raw)
                let timescale = try timescale(of: media, raw: raw)
                if kind == 0x7669_6465, video == nil {            // 'vide'
                    guard let sample = entry.children.first(where: { ["avc1", "avc3", "hvc1", "hev1"].contains($0.type) }) else { continue }
                    let parsed = try videoFormat(of: sample, raw: raw)
                    video = (parsed.format, timescale, parsed.nalLengthSize, trackID)
                } else if kind == 0x736F_756E, audio == nil {     // 'soun'
                    guard let sample = entry.children.first(where: { $0.type == "mp4a" }) else { continue }
                    audio = (try audioFormat(of: sample, raw: raw), trackID)
                }
            }
            guard let video else { throw FMP4Error.malformedBox(offset: moov.offset, reason: "no video track") }
            guard video.timescale > 0 else { throw FMP4Error.invalidTimescale(video.timescale) }
            return FMP4InitInfo(video: video.format, videoTimescale: video.timescale, nalLengthSize: video.nalLengthSize, videoTrackID: video.trackID,
                                audio: audio?.format, audioTrackID: audio?.trackID, byteCount: byteCount)
        }
    }

    /// The end of the first `moov`: walks the top-level box headers only, so a file that goes on with fragments (or is torn after the init) is fine.
    static func initializationLength(of data: Data) throws -> Int {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Int in
            var position = 0
            while position < raw.count {
                var fields = Fields(raw, position, raw.count)
                guard fields.remaining >= 8 else { throw FMP4Error.malformedBox(offset: position, reason: "truncated box header") }
                let size32 = try fields.u32()
                let type = try fields.u32()
                var size = Int(size32)
                if size32 == 1 {
                    let large = try fields.u64()
                    guard large >= 16, large <= UInt64(Int.max) else { throw FMP4Error.malformedBox(offset: position, reason: "bad 64-bit size") }
                    size = Int(large)
                } else if size32 == 0 {
                    size = raw.count - position
                }
                guard size >= 8, size <= raw.count - position else { throw FMP4Error.malformedBox(offset: position, reason: "box extends past the data") }
                position += size
                if type == 0x6D6F_6F76 { return position }         // 'moov'
            }
            throw FMP4Error.malformedBox(offset: position, reason: "no moov box")
        }
    }

    private static func trackID(of tkhd: MP4Box, raw: UnsafeRawBufferPointer) throws -> UInt32 {
        var fields = Fields(raw, tkhd.payloadOffset, tkhd.offset + tkhd.size)
        let version = try fields.u8()
        try fields.skip(3)
        try fields.skip(version == 1 ? 16 : 8)                      // creation and modification time
        return try fields.u32()
    }

    private static func timescale(of mdhd: MP4Box, raw: UnsafeRawBufferPointer) throws -> Int32 {
        var fields = Fields(raw, mdhd.payloadOffset, mdhd.offset + mdhd.size)
        let version = try fields.u8()
        try fields.skip(3)
        try fields.skip(version == 1 ? 16 : 8)
        let value = try fields.u32()
        guard value > 0, value <= UInt32(Int32.max) else { throw FMP4Error.invalidTimescale(Int32(truncatingIfNeeded: value)) }
        return Int32(value)
    }

    // MARK: Video

    private static func videoFormat(of entry: MP4Box, raw: UnsafeRawBufferPointer) throws -> (format: VideoFormat, nalLengthSize: Int) {
        var dimensions = Fields(raw, entry.payloadOffset + 24, entry.offset + entry.size)
        let width = Int(try dimensions.u16()), height = Int(try dimensions.u16())
        let isH264 = entry.type == "avc1" || entry.type == "avc3"
        guard let configuration = entry.child(isH264 ? "avcC" : "hvcC") else {
            throw FMP4Error.malformedBox(offset: entry.offset, reason: "sample entry without \(isH264 ? "avcC" : "hvcC")")
        }
        var fields = Fields(raw, configuration.payloadOffset, configuration.offset + configuration.size)
        guard try fields.u8() == 1 else { throw FMP4Error.malformedBox(offset: configuration.offset, reason: "unknown configuration version") }
        if isH264 {
            let profile = try fields.u8(), compatibility = try fields.u8(), level = try fields.u8()
            let lengthSize = Int(try fields.u8() & 0x03) + 1
            var sets: [Data] = []
            let spsCount = Int(try fields.u8() & 0x1F)
            for _ in 0..<spsCount { sets.append(try parameterSet(&fields, raw: raw)) }
            let ppsCount = Int(try fields.u8())
            for _ in 0..<ppsCount { sets.append(try parameterSet(&fields, raw: raw)) }
            if [100, 110, 122, 144].contains(profile), fields.remaining >= 4 {            // chroma, bit depths, SPS extensions
                try fields.skip(3)
                let extensionCount = Int(try fields.u8())
                for _ in 0..<extensionCount { sets.append(try parameterSet(&fields, raw: raw)) }
            }
            return (VideoFormat(codec: .h264, width: width, height: height, parameterSets: sets, profile: profile,
                                profileCompatibility: compatibility, level: level), lengthSize)
        }
        let profile = try { () throws -> UInt8 in var copy = fields; return try copy.u8() & 0x1F }()
        try fields.skip(11)                                             // profile byte .. general_constraint_indicator_flags
        let level = try fields.u8()
        try fields.skip(8)                                              // min_spatial_segmentation .. avgFrameRate
        let lengthSize = Int(try fields.u8() & 0x03) + 1
        let arrayCount = Int(try fields.u8())
        var byType: [UInt8: [Data]] = [:]
        for _ in 0..<arrayCount {
            let type = try fields.u8() & 0x3F
            let count = Int(try fields.u16())
            for _ in 0..<count { byType[type, default: []].append(try parameterSet(&fields, raw: raw)) }
        }
        let sets = (byType[32] ?? []) + (byType[33] ?? []) + (byType[34] ?? [])
        return (VideoFormat(codec: .hevc, width: width, height: height, parameterSets: sets, profile: profile, profileCompatibility: 0, level: level),
                lengthSize)
    }

    /// `u16 length | bytes`.
    private static func parameterSet(_ fields: inout Fields, raw: UnsafeRawBufferPointer) throws -> Data {
        let length = Int(try fields.u16())
        let start = fields.position
        try fields.skip(length)
        return Data(UnsafeRawBufferPointer(rebasing: raw[start..<start + length]))
    }

    // MARK: Audio

    private static func audioFormat(of entry: MP4Box, raw: UnsafeRawBufferPointer) throws -> AudioFormat {
        guard let esds = entry.child("esds") else { throw FMP4Error.malformedBox(offset: entry.offset, reason: "mp4a without esds") }
        var fields = Fields(raw, esds.payloadOffset + 4, esds.offset + esds.size)
        guard try fields.u8() == 0x03 else { throw FMP4Error.malformedBox(offset: esds.offset, reason: "esds without an ES_Descriptor") }
        _ = try descriptorLength(&fields)
        try fields.skip(2)                                              // ES_ID
        let flags = try fields.u8()
        if flags & 0x80 != 0 { try fields.skip(2) }                     // streamDependenceFlag: dependsOn_ES_ID
        if flags & 0x40 != 0 { try fields.skip(Int(try fields.u8())) }  // URL_Flag
        if flags & 0x20 != 0 { try fields.skip(2) }                     // OCRstreamFlag
        guard try fields.u8() == 0x04 else { throw FMP4Error.malformedBox(offset: esds.offset, reason: "esds without a DecoderConfigDescriptor") }
        _ = try descriptorLength(&fields)
        try fields.skip(13)                                             // objectTypeIndication, streamType, bufferSizeDB, maxBitrate, avgBitrate
        guard try fields.u8() == 0x05 else { throw FMP4Error.malformedBox(offset: esds.offset, reason: "esds without an AudioSpecificConfig") }
        let length = try descriptorLength(&fields)
        let start = fields.position
        try fields.skip(length)
        let config = Data(UnsafeRawBufferPointer(rebasing: raw[start..<start + length]))
        guard let parsed = AudioSpecificConfig(config), parsed.objectType == AudioSpecificConfig.aacLC || parsed.objectType == AudioSpecificConfig.aacELD else {
            throw FMP4Error.unsupportedAudio("an AudioSpecificConfig that is not AAC")
        }
        return AudioFormat(codec: parsed.objectType == AudioSpecificConfig.aacLC ? .aac : .aacELD, sampleRate: parsed.sampleRate,
                           channels: parsed.channels, audioSpecificConfig: config)
    }

    /// An expandable size: seven bits per byte, the high bit says another byte follows (at most four).
    private static func descriptorLength(_ fields: inout Fields) throws -> Int {
        var length = 0
        for _ in 0..<4 {
            let byte = try fields.u8()
            length = length << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 { return length }
        }
        throw FMP4Error.malformedBox(offset: fields.position, reason: "descriptor size of more than four bytes")
    }
}
