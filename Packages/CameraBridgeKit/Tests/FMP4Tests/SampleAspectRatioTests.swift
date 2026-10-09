import Foundation
import MediaCore
import Testing
@testable import FMP4

/// Parameter sets with a VUI sample aspect ratio, parsed by MediaCore's `H264SPS` / `HEVCSPS` (the FMP4 muxer's only SPS
/// parsers). The encoder streams were made with ffmpeg 8.1.1
/// (`-vf setsar=…`, libx264 / libx265 / hevc_videotoolbox); `ffprobe` reports the SAR listed, and ffmpeg's own
/// `frag_keyframe+empty_moov+default_base_moof` remux wrote `pasp` = SAR and `tkhd` width = width × SAR (704×576 at 12:11
/// → 768, 640×360 at 7:5 → 896). The two synthetic SPSs exercise every branch before the VUI (H.264: High profile scaling
/// matrices, POC type 1, field coding, cropping; HEVC: two sub-layers, scaling_list_data, PCM, inter-predicted short-term
/// RPSs, long-term pictures); ffmpeg's `trace_headers` parses them to the end with the SAR shown.
enum SARGolden {
    struct Stream: Sendable, CustomTestStringConvertible {
        var name: String
        var codec: VideoCodec
        var parameterSets: [Data]
        var width: Int
        var height: Int
        var sar: (UInt32, UInt32)?
        var testDescription: String { name }
    }

    static let streams: [Stream] = [
        Stream(name: "x264 High 704×576 12:11", codec: .h264,
               parameterSets: [hex("6764001eacb2016024d810800000030080000019078b1724"), hex("68ebc3cb22c0")], width: 704, height: 576, sar: (12, 11)),
        Stream(name: "x264 Main 640×360 7:5 (extended SAR)", codec: .h264,
               parameterSets: [hex("674d401ed900a02ff97ff000700051000003000100000300320f162e48"), hex("68ebc3cb20")], width: 640, height: 360, sar: (7, 5)),
        Stream(name: "x264 High 704×480 10:11", codec: .h264,
               parameterSets: [hex("6764001eacb201607b6062000003000200000300781e2c5c90"), hex("68ebc3cb3002c0")], width: 704, height: 480, sar: (10, 11)),
        Stream(name: "x264 High 1920×1080 1:1", codec: .h264,
               parameterSets: [hex("67640028acb200f0044fcb8088000003000800000301e078c19240"), hex("68ebc3cb22c0")], width: 1920, height: 1080, sar: (1, 1)),
        Stream(name: "VideoToolbox H.264 without VUI aspect ratio", codec: .h264,
               parameterSets: [hex("2764001fac562c0b012640"), hex("28ee3cb0")], width: 704, height: 576, sar: nil),
        Stream(name: "synthetic H.264 704×576 16:15", codec: .h264,
               parameterSets: [hex("6764001fadba74e9d3a64225d3a74e9d3a74e9d3a74e9d3a74e9d3a74e9d350a6646502c093fffe0020001e010"), hex("68ebc3cb22c0")],
               width: 704, height: 576, sar: (16, 15)),
        Stream(name: "x265 704×576 12:11", codec: .hevc,
               parameterSets: [hex("40010c01ffff01600000030090000003000003005a928090"),
                               hex("42010101600000030090000003000003005aa0058200905964a924caf0268080000003008000000c84"), hex("4401c172b46240")],
               width: 704, height: 576, sar: (12, 11)),
        Stream(name: "x265 640×360 7:5 (extended SAR)", codec: .hevc,
               parameterSets: [hex("40010c01ffff01600000030090000003000003003f959809"),
                               hex("42010101600000030090000003000003003fa00502016965959a4932bffc001c0015a02000000300200000030321"), hex("4401c172b46240")],
               width: 640, height: 360, sar: (7, 5)),
        Stream(name: "x265 1920×1080 4:3", codec: .hevc,
               parameterSets: [hex("40010c01ffff016000000300900000030000030078959809"),
                               hex("420101016000000300900000030000030078a003c08010e596566924caf0e68080000003008000000f04"), hex("4401c172b46240")],
               width: 1920, height: 1080, sar: (4, 3)),
        Stream(name: "hevc_videotoolbox 704×576 12:11 (four short-term RPSs)", codec: .hevc,
               parameterSets: [hex("40010c01ffff016000000300b0000003000003005a08c090"),
                               hex("420101016000000300b0000003000003005aa00582009058808ee45914bff2e7f13fac09a810101004"), hex("4401c072f05324")],
               width: 704, height: 576, sar: (12, 11)),
        Stream(name: "synthetic HEVC 704×576 15:11", codec: .hevc,
               parameterSets: [hex("40010c03ffff01600000030090000003000003005dc00001600000030090000003000003005a972e0480"),
                               hex("42010301600000030090000003000003005dc00001600000030090000003000003005aa005a20090652f965cbc9225cae8857442ba214a57442ba2"
                                   + "15d10a52ba215d10ae8852657442ba215d10ae8857442ba215d10ae8857442ba215d10ae8857452ba215d10ae8857442ba215d10ae8857442ba2"
                                   + "15d10ae8857442ba295d10ae8857442ba215d10ae8857442ba215d10ae8857442ba215d42057442ba215d10ae8857442ba215d10ae8857442ba2"
                                   + "15d10ae8857450815d10ae8857442ba215d10ae8857442ba215d10ae8857442ba215d142057442ba215d10ae8857442ba215d10ae8857442ba2"
                                   + "15d10ae885744c2057442ba215d10ae8857442ba215d10ae8857442ba215d10ae88575dde846b54f995ec4790fff000f000b002"),
                               hex("4401c172b46240")],
               width: 704, height: 576, sar: (15, 11)),
        Stream(name: "hevc_videotoolbox 640×360 (aspect_ratio_idc 1)", codec: .hevc,
               parameterSets: [Golden.hevcVPS, Golden.hevcSPS, Golden.hevcPPS], width: 640, height: 360, sar: (1, 1)),
    ]

    static func sps(of stream: Stream) -> Data? {
        stream.parameterSets.first { data in
            guard let first = data.first else { return false }
            return stream.codec == .h264 ? first & 0x1F == 7 : (first >> 1) & 0x3F == 33
        }
    }
}

@Suite struct SampleAspectRatioTests {
    @Test(arguments: SARGolden.streams) func parsesTheVUIAspectRatio(stream: SARGolden.Stream) throws {
        let sps = try #require(SARGolden.sps(of: stream))
        let parsed = stream.codec == .h264 ? H264SPS.parse(sps)?.sampleAspectRatio : HEVCSPS.parse(sps)?.sampleAspectRatio
        #expect(parsed.map { [$0.horizontal, $0.vertical] } == stream.sar.map { [$0.0, $0.1] })
        // The SPS parses whole: its size is the stream's (the walk to the VUI goes through every branch before it).
        let size = stream.codec == .h264 ? H264SPS.parse(sps).map { [$0.width, $0.height] } : HEVCSPS.parse(sps).map { [$0.width, $0.height] }
        #expect(size == [stream.width, stream.height])
    }

    @Test(arguments: SARGolden.streams) func sampleEntryAndTrackHeaderFollowTheSAR(stream: SARGolden.Stream) throws {
        let format = VideoFormat(codec: stream.codec, width: stream.width, height: stream.height, parameterSets: stream.parameterSets)
        let segment = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil)).initializationSegment()
        let boxes = try MP4BoxReader.parse(segment)
        let entry = try #require(MP4BoxReader.box(atPath: "moov/trak/mdia/minf/stbl/stsd/\(stream.codec == .h264 ? "avc1" : "hvc1")", in: boxes))
        let pasp = Bytes(try #require(entry.child("pasp")).payload(in: segment))
        let (horizontal, vertical) = stream.sar ?? (1, 1)
        #expect([pasp.u32(0), pasp.u32(4)] == [horizontal, vertical])
        #expect(Bytes(entry.payload(in: segment)).u16(24) == UInt16(stream.width))          // coded width stays
        let tkhd = Bytes(try #require(MP4BoxReader.box(atPath: "moov/trak/tkhd", in: boxes)).payload(in: segment))
        #expect(tkhd.u32(76) == UInt32(UInt64(stream.width) << 16 * UInt64(horizontal) / UInt64(vertical)))
        #expect(tkhd.u32(80) == UInt32(stream.height) << 16)
    }

    @Test func matchesFFmpegsRemuxOfA12To11Stream() throws {
        // ffmpeg 8.1.1 -c copy -movflags frag_keyframe+empty_moov+default_base_moof of the x264 704×576 12:11 stream.
        let stream = SARGolden.streams[0]
        let format = VideoFormat(codec: .h264, width: 704, height: 576, parameterSets: stream.parameterSets)
        let segment = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil)).initializationSegment()
        let boxes = try MP4BoxReader.parse(segment)
        let tkhd = Bytes(try #require(MP4BoxReader.box(atPath: "moov/trak/tkhd", in: boxes)).payload(in: segment))
        #expect(tkhd.u32(76) == 50_331_648 && tkhd.u32(80) == 37_748_736)
        let pasp = try #require(MP4BoxReader.box(atPath: "moov/trak/mdia/minf/stbl/stsd/avc1/pasp", in: boxes))
        #expect(pasp.payload(in: segment) == hex("0000000c0000000b"))
    }

    @Test func tableAndReduction() {
        #expect(SampleAspectRatio(horizontal: 24, vertical: 22) == SampleAspectRatio(horizontal: 12, vertical: 11))
        #expect(SampleAspectRatio(horizontal: 0, vertical: 1) == nil)
        #expect(SampleAspectRatio(horizontal: 1, vertical: 0) == nil)
        #expect(SampleAspectRatio.predefined(16) == SampleAspectRatio(horizontal: 2, vertical: 1))
        #expect(SampleAspectRatio.predefined(0) == nil)                  // unspecified
        #expect(SampleAspectRatio.predefined(17) == nil)                 // reserved
    }

    /// Byte and bit mutations of every golden SPS: the parsers return a value or nil, never trap or hang. Deterministic seeds.
    @Test(arguments: [11, 12, 13] as [UInt64]) func mutatedParameterSetsNeverTrap(seed: UInt64) throws {
        var random = SeededGenerator(seed: seed)
        for stream in SARGolden.streams {
            let sps = try #require(SARGolden.sps(of: stream))
            for _ in 0..<600 {
                var bytes = [UInt8](sps)
                for _ in 0..<Int.random(in: 1...4, using: &random) {
                    switch Int.random(in: 0..<4, using: &random) {
                    case 0: bytes[Int.random(in: 0..<bytes.count, using: &random)] ^= UInt8(1) << UInt8.random(in: 0...7, using: &random)
                    case 1: bytes[Int.random(in: 0..<bytes.count, using: &random)] = UInt8.random(in: 0...255, using: &random)
                    case 2: bytes = Array(bytes.prefix(Int.random(in: 1...bytes.count, using: &random)))
                    default: bytes.insert(contentsOf: [0xFF, 0x00, 0x00, 0x00], at: Int.random(in: 1...bytes.count, using: &random))
                    }
                }
                let data = Data(bytes)
                _ = H264SPS.parse(data)
                _ = HEVCSPS.parse(data)
                let format = VideoFormat(codec: stream.codec, width: 0, height: 0,
                                         parameterSets: stream.parameterSets.map { $0 == sps ? data : $0 })
                _ = try? FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
            }
        }
    }
}
