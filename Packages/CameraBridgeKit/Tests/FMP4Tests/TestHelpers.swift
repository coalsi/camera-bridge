import Foundation
import MediaCore
import Testing
@testable import FMP4

/// Golden vectors. Parameter sets come from streams encoded locally (libx264 High@3.0 and hevc_videotoolbox Main,
/// 640×360); the decoder configuration records are what ffmpeg 8.1 wrote for them with
/// `-movflags frag_keyframe+empty_moov+default_base_moof` (and `-tag:v hvc1` for HEVC).
enum Golden {
    static let h264SPS = hex("6764001eacb201405ff2e022000003000200000300781e2c5c90")
    static let h264PPS = hex("68ebc3cb22c0")
    static let avcC = hex("0164001effe1001a" + "6764001eacb201405ff2e022000003000200000300781e2c5c90" + "010006" + "68ebc3cb22c0" + "fdf8f800")

    static let hevcVPS = hex("40010c01ffff016000000300b0000003000003003f1b0240")
    static let hevcSPS = hex("420101016000000300b0000003000003003fa005020171f2e206ee45914bff2e7f13fac05a8101010040")
    static let hevcPPS = hex("4401c072f05324")
    static let hvcC = hex("010160000000b000000000003ff000fcfdf8f800000f03"
        + "a00001" + "0018" + "40010c01ffff016000000300b0000003000003003f1b0240"
        + "a10001" + "002a" + "420101016000000300b0000003000003003fa005020171f2e206ee45914bff2e7f13fac05a8101010040"
        + "a20001" + "0007" + "4401c072f05324")

    static var h264Format: VideoFormat {
        get throws { try #require(VideoFormat.h264(sps: h264SPS, pps: h264PPS)) }
    }

    static var hevcFormat: VideoFormat {
        get throws { try #require(VideoFormat.hevc(vps: hevcVPS, sps: hevcSPS, pps: hevcPPS)) }
    }
}

func hex(_ string: String) -> Data {
    var data = Data()
    var iterator = string.makeIterator()
    while let high = iterator.next(), let low = iterator.next() {
        guard let byte = UInt8(String([high, low]), radix: 16) else { continue }
        data.append(byte)
    }
    return data
}

/// Big-endian field access into a byte buffer at offsets relative to its start.
struct Bytes {
    let data: Data

    init(_ data: Data) { self.data = data }

    func u8(_ offset: Int) -> UInt8 { data[data.startIndex + offset] }
    func u16(_ offset: Int) -> UInt16 { UInt16(u8(offset)) << 8 | UInt16(u8(offset + 1)) }
    func u24(_ offset: Int) -> UInt32 { UInt32(u8(offset)) << 16 | UInt32(u16(offset + 1)) }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) << 16 | UInt32(u16(offset + 2)) }
    func i32(_ offset: Int) -> Int32 { Int32(bitPattern: u32(offset)) }
    func u64(_ offset: Int) -> UInt64 { UInt64(u32(offset)) << 32 | UInt64(u32(offset + 4)) }
    func fourCC(_ offset: Int) -> String { String(decoding: slice(offset, 4), as: UTF8.self) }
    func slice(_ offset: Int, _ count: Int) -> Data { data.subdata(in: data.startIndex + offset..<data.startIndex + offset + count) }
}

extension MP4Box {
    /// The box payload (after the header) within `data`.
    func payload(in data: Data) -> Data {
        data.subdata(in: data.startIndex + offset + headerSize..<data.startIndex + offset + size)
    }

    /// (version, flags) of a full box.
    func fullBoxHeader(in data: Data) -> (version: UInt8, flags: UInt32) {
        let bytes = Bytes(payload(in: data))
        return (bytes.u8(0), bytes.u24(1))
    }
}

/// Synthetic frames with recognisable NAL payloads. Each NAL unit starts with a slice header of the format's codec (H.264
/// IDR 0x65 / non-IDR 0x41; HEVC IDR_W_RADL 0x26 0x01 / TRAIL_R 0x02 0x01); the muxer only looks at the NAL type.
enum Synthetic {
    static func videoFrame(_ format: VideoFormat, index: Int, isKeyframe: Bool, pts: Int64, dts: Int64? = nil, nalSizes: [Int] = [12, 30],
                           wallClock: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> EncodedVideoFrame {
        let header: [UInt8] = switch format.codec {
        case .h264: [isKeyframe ? 0x65 : 0x41]
        case .hevc: isKeyframe ? [0x26, 0x01] : [0x02, 0x01]
        }
        let nals = nalSizes.enumerated().map { position, size in
            Data(header + (0..<max(0, size - header.count)).map { UInt8(truncatingIfNeeded: index &* 31 &+ position &* 7 &+ $0) })
        }
        return EncodedVideoFrame(format: format, nalUnits: nals, isKeyframe: isKeyframe, pts: MediaTime(value: pts, timescale: 90_000),
                                 dts: dts.map { MediaTime(value: $0, timescale: 90_000) }, wallClock: wallClock)
    }

    static func audioFrame(_ format: AudioFormat, index: Int, pts: Int64, size: Int = 9,
                           wallClock: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> EncodedAudioFrame {
        EncodedAudioFrame(format: format, data: Data((0..<size).map { UInt8(truncatingIfNeeded: 0xA0 &+ index &+ $0) }),
                          pts: MediaTime(value: pts, timescale: Int32(format.sampleRate)), sampleCount: 1024, wallClock: wallClock)
    }
}

/// One parsed `trun`.
struct TrackRun {
    struct Sample: Equatable { var duration: UInt32; var size: UInt32; var flags: UInt32; var compositionOffset: Int32? }
    var version: UInt8
    var flags: UInt32
    var dataOffset: Int32
    var samples: [Sample]

    init(_ box: MP4Box, in data: Data) throws {
        let bytes = Bytes(box.payload(in: data))
        version = bytes.u8(0)
        flags = bytes.u24(1)
        let count = Int(bytes.u32(4))
        var cursor = 8
        #expect(flags & 0x1 != 0, "data-offset-present")
        dataOffset = bytes.i32(cursor)
        cursor += 4
        #expect(flags & 0x4 == 0, "no first-sample-flags")
        samples = []
        for _ in 0..<count {
            var sample = Sample(duration: 0, size: 0, flags: 0, compositionOffset: nil)
            if flags & 0x100 != 0 { sample.duration = bytes.u32(cursor); cursor += 4 }
            if flags & 0x200 != 0 { sample.size = bytes.u32(cursor); cursor += 4 }
            if flags & 0x400 != 0 { sample.flags = bytes.u32(cursor); cursor += 4 }
            if flags & 0x800 != 0 { sample.compositionOffset = bytes.i32(cursor); cursor += 4 }
            samples.append(sample)
        }
        #expect(cursor == bytes.data.count, "trun has no trailing bytes")
    }
}

/// SplitMix64: a deterministic generator, so any input a fuzz or property test produces can be regenerated from its seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// tfdt and trun of each `traf` in a fragment, keyed by track ID.
struct FragmentRuns {
    struct Run { var decodeTime: UInt64; var run: TrackRun }
    var sequenceNumber: UInt32
    var tracks: [UInt32: Run]

    init(_ fragment: Data) throws {
        let moof = try #require(try MP4BoxReader.parse(fragment).first { $0.type == "moof" })
        sequenceNumber = Bytes(try #require(moof.child("mfhd")).payload(in: fragment)).u32(4)
        tracks = [:]
        for traf in moof.children(ofType: "traf") {
            let trackID = Bytes(try #require(traf.child("tfhd")).payload(in: fragment)).u32(4)
            let decodeTime = Bytes(try #require(traf.child("tfdt")).payload(in: fragment)).u64(4)
            tracks[trackID] = Run(decodeTime: decodeTime, run: try TrackRun(try #require(traf.child("trun")), in: fragment))
        }
    }

    var video: Run? { tracks[1] }
    var audio: Run? { tracks[2] }
}
