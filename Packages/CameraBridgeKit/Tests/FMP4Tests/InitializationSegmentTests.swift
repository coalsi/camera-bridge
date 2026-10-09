import Foundation
import MediaCore
import Testing
@testable import FMP4

@Suite struct InitializationSegmentTests {
    private let aac = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)

    @Test func ftypAndTopLevelLayout() throws {
        let muxer = try FMP4Muxer(configuration: FMP4Configuration(video: Golden.h264Format, audio: aac))
        let segment = muxer.initializationSegment()
        let boxes = try MP4BoxReader.parse(segment)
        #expect(boxes.map(\.type) == ["ftyp", "moov"])
        let ftyp = Bytes(boxes[0].payload(in: segment))
        #expect(ftyp.fourCC(0) == "isom")
        #expect(ftyp.u32(4) == 0x200)
        #expect(stride(from: 8, to: ftyp.data.count, by: 4).map { ftyp.fourCC($0) } == ["isom", "iso5", "iso6", "mp41"])
        #expect(boxes[1].children.map(\.type) == ["mvhd", "trak", "trak", "mvex"])
        #expect(boxes.last.map { $0.offset + $0.size } == segment.count)
        // Stable: the same bytes every call.
        #expect(muxer.initializationSegment() == segment)
    }

    @Test func movieHeader() throws {
        let segment = try FMP4Muxer(configuration: FMP4Configuration(video: Golden.h264Format, audio: aac)).initializationSegment()
        let boxes = try MP4BoxReader.parse(segment)
        let mvhd = try #require(MP4BoxReader.box(atPath: "moov/mvhd", in: boxes))
        let bytes = Bytes(mvhd.payload(in: segment))
        #expect(mvhd.size == 108)
        #expect(bytes.u8(0) == 0)                    // version 0
        #expect(bytes.u32(12) == 1000)               // movie timescale
        #expect(bytes.u32(16) == 0)                  // duration unknown (empty moov)
        #expect(bytes.u32(20) == 0x0001_0000)        // rate 1.0
        #expect(bytes.u16(24) == 0x0100)             // volume 1.0
        #expect(bytes.u32(36) == 0x0001_0000 && bytes.u32(52) == 0x0001_0000 && bytes.u32(68) == 0x4000_0000)   // identity matrix
        #expect(bytes.u32(96) == 3)                  // next_track_ID

        let videoOnly = try FMP4Muxer(configuration: FMP4Configuration(video: Golden.h264Format, audio: nil)).initializationSegment()
        let videoOnlyBoxes = try MP4BoxReader.parse(videoOnly)
        #expect(videoOnlyBoxes[1].children.map(\.type) == ["mvhd", "trak", "mvex"])
        let nextTrack = try #require(MP4BoxReader.box(atPath: "moov/mvhd", in: videoOnlyBoxes))
        #expect(Bytes(nextTrack.payload(in: videoOnly)).u32(96) == 2)
    }

    @Test func h264VideoTrack() throws {
        let segment = try FMP4Muxer(configuration: FMP4Configuration(video: Golden.h264Format, audio: aac)).initializationSegment()
        let moov = try #require(try MP4BoxReader.parse(segment).last)
        let trak = try #require(moov.children(ofType: "trak").first)
        #expect(trak.children.map(\.type) == ["tkhd", "mdia"])

        let tkhd = try #require(trak.child("tkhd"))
        let tkhdBytes = Bytes(tkhd.payload(in: segment))
        #expect(tkhd.fullBoxHeader(in: segment) == (0, 3))          // enabled | in movie
        #expect(tkhdBytes.u32(12) == 1)                             // track_ID
        #expect(tkhdBytes.u32(20) == 0)                             // duration
        #expect(tkhdBytes.u16(34) == 0)                             // alternate_group
        #expect(tkhdBytes.u16(36) == 0)                             // volume (video)
        #expect(tkhdBytes.u32(76) == 640 << 16)                     // width 16.16
        #expect(tkhdBytes.u32(80) == 360 << 16)                     // height 16.16

        let mdia = try #require(trak.child("mdia"))
        #expect(mdia.children.map(\.type) == ["mdhd", "hdlr", "minf"])
        let mdhd = Bytes(try #require(mdia.child("mdhd")).payload(in: segment))
        #expect(mdhd.u32(12) == 90_000)                             // timescale
        #expect(mdhd.u32(16) == 0)                                  // duration
        #expect(mdhd.u16(20) == 0x55C4)                             // language "und"
        let hdlr = Bytes(try #require(mdia.child("hdlr")).payload(in: segment))
        #expect(hdlr.fourCC(8) == "vide")

        let minf = try #require(mdia.child("minf"))
        #expect(minf.children.map(\.type) == ["vmhd", "dinf", "stbl"])
        #expect(try #require(minf.child("vmhd")).fullBoxHeader(in: segment) == (0, 1))
        let dref = try #require(minf.descendant(atPath: "dinf/dref"))
        #expect(Bytes(dref.payload(in: segment)).u32(4) == 1)
        #expect(try #require(dref.child("url ")).fullBoxHeader(in: segment) == (0, 1))   // self-contained

        let stbl = try #require(minf.child("stbl"))
        #expect(stbl.children.map(\.type) == ["stsd", "stts", "stsc", "stsz", "stco"])
        for type in ["stts", "stsc", "stco"] {
            #expect(Bytes(try #require(stbl.child(type)).payload(in: segment)).u32(4) == 0, "\(type) is empty")
        }
        let stsz = Bytes(try #require(stbl.child("stsz")).payload(in: segment))
        #expect(stsz.u32(4) == 0 && stsz.u32(8) == 0)

        let stsd = try #require(stbl.child("stsd"))
        #expect(Bytes(stsd.payload(in: segment)).u32(4) == 1)
        let avc1 = try #require(stsd.child("avc1"))
        let entry = Bytes(avc1.payload(in: segment))
        #expect(entry.u16(6) == 1)                                  // data_reference_index
        #expect(entry.u16(24) == 640 && entry.u16(26) == 360)
        #expect(entry.u32(28) == 0x0048_0000 && entry.u32(32) == 0x0048_0000)   // 72 dpi
        #expect(entry.u16(40) == 1)                                 // frame_count
        #expect(entry.u16(74) == 0x0018)                            // depth
        #expect(entry.u16(76) == 0xFFFF)                            // pre_defined −1
        #expect(avc1.children.map(\.type) == ["avcC", "pasp"])
        #expect(try #require(avc1.child("avcC")).payload(in: segment) == Golden.avcC)
        let pasp = Bytes(try #require(avc1.child("pasp")).payload(in: segment))
        #expect(pasp.u32(0) == 1 && pasp.u32(4) == 1)
    }

    @Test func aacAudioTrackWithESDescriptor() throws {
        let segment = try FMP4Muxer(configuration: FMP4Configuration(video: Golden.h264Format, audio: aac)).initializationSegment()
        let moov = try #require(try MP4BoxReader.parse(segment).last)
        let trak = try #require(moov.children(ofType: "trak").last)

        let tkhd = try #require(trak.child("tkhd"))
        let tkhdBytes = Bytes(tkhd.payload(in: segment))
        #expect(tkhd.fullBoxHeader(in: segment) == (0, 3))
        #expect(tkhdBytes.u32(12) == 2)                             // track_ID
        #expect(tkhdBytes.u16(34) == 1)                             // alternate_group
        #expect(tkhdBytes.u16(36) == 0x0100)                        // volume 1.0
        #expect(tkhdBytes.u32(76) == 0 && tkhdBytes.u32(80) == 0)

        let mdhd = Bytes(try #require(trak.descendant(atPath: "mdia/mdhd")).payload(in: segment))
        #expect(mdhd.u32(12) == 32_000)                             // timescale = sample rate
        #expect(Bytes(try #require(trak.descendant(atPath: "mdia/hdlr")).payload(in: segment)).fourCC(8) == "soun")
        let minf = try #require(trak.descendant(atPath: "mdia/minf"))
        #expect(minf.children.map(\.type) == ["smhd", "dinf", "stbl"])

        let mp4a = try #require(minf.descendant(atPath: "stbl/stsd/mp4a"))
        let entry = Bytes(mp4a.payload(in: segment))
        #expect(entry.u16(6) == 1)                                  // data_reference_index
        #expect(entry.u16(8) == 0)                                  // version 0 sound sample entry
        #expect(entry.u16(16) == 1)                                 // channelcount
        #expect(entry.u16(18) == 16)                                // samplesize
        #expect(entry.u32(24) == 32_000 << 16)                      // samplerate 16.16
        #expect(mp4a.children.map(\.type) == ["esds"])

        let esds = try #require(mp4a.child("esds"))
        #expect(esds.fullBoxHeader(in: segment) == (0, 0))
        let descriptors = try ESDescriptorParser.parse(Bytes(esds.payload(in: segment)).slice(4, esds.size - 12))
        #expect(descriptors.tag == 0x03)
        #expect(descriptors.objectTypeIndication == 0x40)           // MPEG-4 Audio
        #expect(descriptors.streamType == 0x15)                     // audio stream, reserved bit set
        #expect(descriptors.decoderSpecificInfo == aac.audioSpecificConfig)
        #expect(descriptors.slConfig == Data([0x02]))
    }

    @Test func movieExtendsWithOneTrexPerTrack() throws {
        let segment = try FMP4Muxer(configuration: FMP4Configuration(video: Golden.h264Format, audio: aac)).initializationSegment()
        let mvex = try #require(MP4BoxReader.box(atPath: "moov/mvex", in: try MP4BoxReader.parse(segment)))
        let trex = mvex.children(ofType: "trex")
        #expect(trex.count == 2)
        for (index, box) in trex.enumerated() {
            let bytes = Bytes(box.payload(in: segment))
            #expect(box.size == 32)
            #expect(bytes.u32(4) == UInt32(index + 1))              // track_ID
            #expect(bytes.u32(8) == 1)                              // default_sample_description_index
            #expect(bytes.u32(12) == 0 && bytes.u32(16) == 0 && bytes.u32(20) == 0)
        }
    }

    @Test func hevcUsesHvc1WithHvcC() throws {
        let segment = try FMP4Muxer(configuration: FMP4Configuration(video: Golden.hevcFormat, audio: nil, writeProducerReferenceTime: true))
            .initializationSegment()
        let stsd = try #require(MP4BoxReader.box(atPath: "moov/trak/mdia/minf/stbl/stsd", in: try MP4BoxReader.parse(segment)))
        #expect(stsd.children.map(\.type) == ["hvc1"])
        let hvc1 = try #require(stsd.child("hvc1"))
        let entry = Bytes(hvc1.payload(in: segment))
        #expect(entry.u16(24) == 640 && entry.u16(26) == 360)
        #expect(try #require(hvc1.child("hvcC")).payload(in: segment) == Golden.hvcC)
    }

    @Test func decoderConfigurationRecordsMatchFFmpeg() throws {
        #expect(try AVCDecoderConfigurationRecord.make(parameterSets: [Golden.h264SPS, Golden.h264PPS]) == Golden.avcC)
        // Order of the input does not matter: sets are classified by NAL type.
        #expect(try AVCDecoderConfigurationRecord.make(parameterSets: [Golden.h264PPS, Golden.h264SPS]) == Golden.avcC)
        #expect(try HEVCDecoderConfigurationRecord.make(parameterSets: [Golden.hevcVPS, Golden.hevcSPS, Golden.hevcPPS]) == Golden.hvcC)
    }

    @Test func baselineAVCCHasNoHighProfileExtension() throws {
        // libx264 Baseline 1.3 (profile_idc 66): the avcC ends after the PPS array (ffmpeg 8.1 golden).
        let sps = hex("6742c00dd90141fb0110000003001000000303c0f142a480")
        let pps = hex("68cb83cb20")
        let record = try AVCDecoderConfigurationRecord.make(parameterSets: [sps, pps])
        #expect(record == hex("0142c00dffe10018" + "6742c00dd90141fb0110000003001000000303c0f142a480" + "010005" + "68cb83cb20"))
    }

    @Test func rejectsUnusableConfigurations() throws {
        let h264 = try Golden.h264Format
        #expect(throws: FMP4Error.self) {
            try FMP4Muxer(configuration: FMP4Configuration(video: VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [Golden.h264SPS]), audio: nil))
        }
        #expect(throws: FMP4Error.self) {
            try FMP4Muxer(configuration: FMP4Configuration(video: VideoFormat(codec: .hevc, width: 640, height: 360,
                                                                               parameterSets: [Golden.hevcSPS, Golden.hevcPPS]), audio: nil))
        }
        #expect(throws: FMP4Error.self) {
            try FMP4Muxer(configuration: FMP4Configuration(video: VideoFormat(codec: .h264, width: 0, height: 0, parameterSets: []), audio: nil))
        }
        #expect(throws: FMP4Error.self) {
            try FMP4Muxer(configuration: FMP4Configuration(video: h264, audio: AudioFormat(codec: .opus, sampleRate: 48_000, channels: 1)))
        }
        #expect(throws: FMP4Error.self) {
            try FMP4Muxer(configuration: FMP4Configuration(video: h264, audio: AudioFormat(codec: .aac, sampleRate: 0, channels: 1)))
        }
        #expect(throws: FMP4Error.self) { try FMP4Muxer(configuration: FMP4Configuration(video: h264, audio: nil, videoTimescale: 0)) }
    }

    @Test func derivesSizeFromTheSPSWhenTheFormatHasNone() throws {
        let format = VideoFormat(codec: .h264, width: 0, height: 0, parameterSets: [Golden.h264SPS, Golden.h264PPS])
        let segment = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil)).initializationSegment()
        let avc1 = try #require(MP4BoxReader.box(atPath: "moov/trak/mdia/minf/stbl/stsd/avc1", in: try MP4BoxReader.parse(segment)))
        let entry = Bytes(avc1.payload(in: segment))
        #expect(entry.u16(24) == 640 && entry.u16(26) == 360)
    }

    @Test func aacWithoutAudioSpecificConfigGetsTheLCConfig() throws {
        let format = AudioFormat(codec: .aac, sampleRate: 16_000, channels: 1)
        let segment = try FMP4Muxer(configuration: FMP4Configuration(video: Golden.h264Format, audio: format)).initializationSegment()
        let boxes = try MP4BoxReader.parse(segment)
        let trak = try #require(boxes.last?.children(ofType: "trak").last)
        let esds = try #require(trak.descendant(atPath: "mdia/minf/stbl/stsd/mp4a/esds"))
        let descriptors = try ESDescriptorParser.parse(Bytes(esds.payload(in: segment)).slice(4, esds.size - 12))
        #expect(descriptors.decoderSpecificInfo == AudioFormat.aacLC(sampleRate: 16_000, channels: 1).audioSpecificConfig)
    }
}

/// Minimal ISO/IEC 14496-1 ES_Descriptor reader for the test assertions.
enum ESDescriptorParser {
    struct Result { var tag: UInt8; var objectTypeIndication: UInt8; var streamType: UInt8; var decoderSpecificInfo: Data; var slConfig: Data }
    struct Failure: Error {}

    static func parse(_ data: Data) throws -> Result {
        let bytes = [UInt8](data)
        var cursor = 0
        func descriptor() throws -> (tag: UInt8, body: Range<Int>) {
            guard cursor < bytes.count else { throw Failure() }
            let tag = bytes[cursor]
            cursor += 1
            var size = 0
            for _ in 0..<4 {
                guard cursor < bytes.count else { throw Failure() }
                let byte = bytes[cursor]
                cursor += 1
                size = size << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            guard cursor + size <= bytes.count else { throw Failure() }
            return (tag, cursor..<cursor + size)
        }
        let es = try descriptor()
        guard es.tag == 0x03 else { throw Failure() }
        cursor += 3                                          // ES_ID + flags (no optional fields)
        let decoderConfig = try descriptor()
        guard decoderConfig.tag == 0x04 else { throw Failure() }
        let objectType = bytes[cursor]
        let streamType = bytes[cursor + 1]
        cursor += 13
        let specific = try descriptor()
        guard specific.tag == 0x05 else { throw Failure() }
        let asc = Data(bytes[specific.body])
        cursor = specific.body.upperBound
        let sl = try descriptor()
        guard sl.tag == 0x06 else { throw Failure() }
        guard sl.body.upperBound == bytes.count, es.body.upperBound == bytes.count else { throw Failure() }
        return Result(tag: es.tag, objectTypeIndication: objectType, streamType: streamType, decoderSpecificInfo: asc, slConfig: Data(bytes[sl.body]))
    }
}
