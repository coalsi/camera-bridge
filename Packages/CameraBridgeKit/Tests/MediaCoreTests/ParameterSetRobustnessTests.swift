import Foundation
import Testing
@testable import MediaCore
#if canImport(VideoToolbox)
import VideoToolbox
#endif

/// MSB-first bit writer with Exp-Golomb coding, used to craft parameter sets bit by bit (independent of the
/// parser's `BitReader`).
struct TestBitWriter {
    private(set) var bytes: [UInt8] = []
    private var used = 8   // bits used in the last byte

    mutating func bit(_ value: Bool) {
        if used == 8 { bytes.append(0); used = 0 }
        if value { bytes[bytes.count - 1] |= 0x80 >> UInt8(used) }
        used += 1
    }

    mutating func bits(_ value: UInt64, _ count: Int) {
        for i in stride(from: count - 1, through: 0, by: -1) { bit((value >> UInt64(i)) & 1 == 1) }
    }

    /// ue(v): codeNum = value.
    mutating func ue(_ value: UInt32) {
        let code = UInt64(value) + 1
        let length = 64 - code.leadingZeroBitCount
        bits(0, length - 1)
        bits(code, length)
    }

    /// se(v): k > 0 → 2k − 1, k ≤ 0 → −2k.
    mutating func se(_ value: Int32) {
        let k = Int64(value)
        ue(UInt32(k > 0 ? 2 * k - 1 : -2 * k))
    }

    /// rbsp_trailing_bits.
    mutating func trailing() {
        bit(true)
        while used != 8 { bit(false) }
    }

    /// NAL unit: header bytes + payload with emulation-prevention bytes inserted.
    func nal(header: [UInt8]) -> Data {
        var out = Data(header)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte <= 3 { out.append(3); zeros = 0 }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }
}

/// Builds H.264 SPS NAL units (ITU-T H.264 §7.3.2.1.1, VUI up to timing_info).
struct H264SPSBuilder {
    var profile: UInt8 = 100
    var constraints: UInt8 = 0
    var level: UInt8 = 40
    var chromaFormat: UInt32 = 1
    /// nil → seq_scaling_matrix_present_flag = 0. Otherwise one entry per list (8 for 4:2:0); nil entry → list
    /// not present; array → the delta_scale values written for that list.
    var scalingLists: [[Int32]?]?
    var widthInMbs: UInt32 = 120
    var heightInMapUnits: UInt32 = 68
    var frameMbsOnly = true
    var crop: (left: UInt32, right: UInt32, top: UInt32, bottom: UInt32)? = (0, 0, 0, 4)
    var vui = true
    var extendedSAR = true
    var videoSignal = true
    var chromaLocation = true
    var timing: (unitsInTick: UInt32, timeScale: UInt32)? = (1001, 60_000)

    func build() -> Data {
        var w = TestBitWriter()
        w.bits(UInt64(profile), 8)
        w.bits(UInt64(constraints), 8)
        w.bits(UInt64(level), 8)
        w.ue(0)                                     // seq_parameter_set_id
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            w.ue(chromaFormat)
            if chromaFormat == 3 { w.bit(false) }   // separate_colour_plane_flag
            w.ue(0); w.ue(0)                        // bit depths
            w.bit(false)                            // qpprime_y_zero_transform_bypass_flag
            w.bit(scalingLists != nil)
            if let scalingLists {
                for list in scalingLists {
                    w.bit(list != nil)
                    for delta in list ?? [] { w.se(delta) }
                }
            }
        }
        w.ue(0)                                     // log2_max_frame_num_minus4
        w.ue(0)                                     // pic_order_cnt_type
        w.ue(0)                                     // log2_max_pic_order_cnt_lsb_minus4
        w.ue(1)                                     // max_num_ref_frames
        w.bit(false)                                // gaps_in_frame_num_value_allowed_flag
        w.ue(widthInMbs - 1)
        w.ue(heightInMapUnits - 1)
        w.bit(frameMbsOnly)
        if !frameMbsOnly { w.bit(false) }
        w.bit(true)                                 // direct_8x8_inference_flag
        w.bit(crop != nil)
        if let crop { w.ue(crop.left); w.ue(crop.right); w.ue(crop.top); w.ue(crop.bottom) }
        w.bit(vui)
        if vui {
            w.bit(extendedSAR)
            if extendedSAR { w.bits(255, 8); w.bits(1, 16); w.bits(1, 16) }
            w.bit(false)                            // overscan_info_present_flag
            w.bit(videoSignal)
            if videoSignal { w.bits(5, 3); w.bit(false); w.bit(true); w.bits(0x010101, 24) }
            w.bit(chromaLocation)
            if chromaLocation { w.ue(0); w.ue(0) }
            w.bit(timing != nil)
            if let timing { w.bits(UInt64(timing.unitsInTick), 32); w.bits(UInt64(timing.timeScale), 32); w.bit(true) }
            w.bit(false); w.bit(false); w.bit(false); w.bit(false)   // HRD, pic_struct, bitstream_restriction
        }
        w.trailing()
        return w.nal(header: [0x67])
    }
}

/// Deterministic generator for reproducible fuzzing (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Byte-level mutations of a valid unit: bit flips, byte overwrites, truncation, extension with random bytes.
func mutations(of seed: Data, count: Int, rng: inout SplitMix64) -> [Data] {
    (0..<count).map { _ in
        var bytes = [UInt8](seed)
        switch Int.random(in: 0..<4, using: &rng) {
        case 0:
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let index = Int.random(in: 1..<bytes.count, using: &rng)
                bytes[index] ^= 1 << UInt8.random(in: 0...7, using: &rng)
            }
        case 1:
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                bytes[Int.random(in: 1..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
        case 2:
            bytes = Array(bytes.prefix(Int.random(in: 1...bytes.count, using: &rng)))
        default:
            bytes += (0..<Int.random(in: 1...16, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        }
        return Data(bytes)
    }
}

@Suite(.timeLimit(.minutes(1))) struct H264SPSRobustnessTests {
    @Test func craftedSPSExercisesVUIAndCropping() throws {
        let sps = try #require(H264SPS.parse(H264SPSBuilder().build()))
        #expect(sps.profileIDC == 100 && sps.levelIDC == 40 && sps.constraintFlags == 0)
        #expect(sps.width == 1920 && sps.height == 1080)                 // 1088 − 2·4 crop rows
        #expect(try #require(sps.frameRate) == 60_000.0 / 2002.0)          // 29.97
    }

    @Test(arguments: [(UInt32(1), UInt32(50), 25.0), (UInt32(1), UInt32(60), 30.0), (UInt32(1000), UInt32(120_000), 60.0),
                      (UInt32(1001), UInt32(48_000), 48_000.0 / 2002.0)])
    func frameRateFromTimingInfo(unitsInTick: UInt32, timeScale: UInt32, expected: Double) throws {
        var builder = H264SPSBuilder()
        builder.timing = (unitsInTick, timeScale)
        let sps = try #require(H264SPS.parse(builder.build()))
        #expect(sps.frameRate == expected)
    }

    @Test func frameRateAbsentOrInvalid() throws {
        var noTiming = H264SPSBuilder()
        noTiming.timing = nil
        #expect(try #require(H264SPS.parse(noTiming.build())).frameRate == nil)

        var noVUI = H264SPSBuilder()
        noVUI.vui = false
        let bare = try #require(H264SPS.parse(noVUI.build()))
        #expect(bare.frameRate == nil && bare.width == 1920 && bare.height == 1080)

        var zeroUnits = H264SPSBuilder()
        zeroUnits.timing = (0, 60_000)
        #expect(try #require(H264SPS.parse(zeroUnits.build())).frameRate == nil)

        var minimalVUI = H264SPSBuilder()
        (minimalVUI.extendedSAR, minimalVUI.videoSignal, minimalVUI.chromaLocation) = (false, false, false)
        minimalVUI.timing = (1, 40)
        #expect(try #require(H264SPS.parse(minimalVUI.build())).frameRate == 20)
    }

    #if canImport(VideoToolbox)
    @Test func frameRateMatchesVideoToolboxWhenSignalled() throws {
        let sets = try encoderParameterSets(codec: kCMVideoCodecType_H264, width: 1280, height: 720, profileLevel: kVTProfileLevel_H264_Main_3_1)
        let sps = try #require(H264SPS.parse(sets[0]))
        // VideoToolbox may omit VUI timing; when present it must be a plausible rate.
        if let rate = sps.frameRate { #expect(rate > 0 && rate <= 240) }
    }
    #endif

    @Test func validScalingMatricesParse() throws {
        var builder = H264SPSBuilder()
        // List 0: full 16 deltas including both range limits; list 1: delta −8 makes nextScale 0 (use default)
        // after one coefficient; list 6 (8×8): 64 deltas that never reach 0; others absent.
        let full4x4: [Int32] = [127, -128] + Array(repeating: 1, count: 14)
        let full8x8: [Int32] = (0..<64).map { $0 % 2 == 0 ? 1 : -1 }
        builder.scalingLists = [full4x4, [-8], nil, nil, nil, nil, full8x8, nil]
        let sps = try #require(H264SPS.parse(builder.build()))
        #expect(sps.width == 1920 && sps.height == 1080 && sps.frameRate != nil)
    }

    /// Verifier repro: delta_scale = +2³¹−1 overflowed Int32 arithmetic in skipScalingList and trapped.
    @Test(arguments: [Int32.max, Int32.min + 1, 128, -129, 1_000_000])
    func outOfRangeScalingDeltaIsRejected(delta: Int32) {
        var builder = H264SPSBuilder()
        builder.scalingLists = [[delta], nil, nil, nil, nil, nil, nil, nil]
        let nal = builder.build()
        #expect(H264SPS.parse(nal) == nil)
        #expect(VideoFormat.h264(sps: nal, pps: Data([0x68, 0xCE, 0x3C, 0x80])) == nil)
    }

    @Test func extremeExpGolombFieldsAreRejectedWithoutTrapping() {
        let maxUE = UInt32.max - 1                                       // largest codeNum with 31 leading zeros
        var hugeWidth = H264SPSBuilder()
        hugeWidth.widthInMbs = maxUE
        #expect(H264SPS.parse(hugeWidth.build()) == nil)

        var hugeCrop = H264SPSBuilder()
        hugeCrop.crop = (maxUE, maxUE, maxUE, maxUE)
        #expect(H264SPS.parse(hugeCrop.build()) == nil)

        var interlacedHuge = H264SPSBuilder()
        interlacedHuge.frameMbsOnly = false
        interlacedHuge.heightInMapUnits = maxUE
        #expect(H264SPS.parse(interlacedHuge.build()) == nil)

        var hugeTiming = H264SPSBuilder()
        hugeTiming.timing = (1, UInt32.max)
        #expect(H264SPS.parse(hugeTiming.build())?.frameRate == Double(UInt32.max) / 2)

        // 32 leading zeros is not a valid ue(v) code.
        #expect(H264SPS.parse(Data([0x67, 0x64, 0x00, 0x28, 0x00, 0x00, 0x00, 0x00, 0x80])) == nil)
    }

    @Test func fuzzedHighProfileSPSNeverTraps() throws {
        var builder = H264SPSBuilder()
        builder.scalingLists = [[-8], nil, [2, -10], nil, nil, [-8], (0..<64).map { $0 % 2 == 0 ? 3 : -3 }, nil]
        var seeds = [builder.build(), H264SPSBuilder().build()]
        #if canImport(VideoToolbox)
        seeds.append(try encoderParameterSets(codec: kCMVideoCodecType_H264, width: 1920, height: 1080, profileLevel: kVTProfileLevel_H264_High_4_0)[0])
        #endif
        var rng = SplitMix64(state: 0xCB_5B5)
        var parsed = 0
        for seed in seeds {
            for candidate in mutations(of: seed, count: 3_000, rng: &rng) {
                if let sps = H264SPS.parse(candidate) {
                    parsed += 1
                    #expect(sps.width > 0 && sps.width <= 16_384 && sps.height > 0 && sps.height <= 16_384)
                }
                _ = VideoFormat.h264(sps: candidate, pps: Data([0x68]))
            }
        }
        for _ in 0..<3_000 {
            let random = Data([0x67] + (0..<Int.random(in: 0...64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            _ = H264SPS.parse(random)
        }
        #expect(parsed > 0)   // mutations that keep the SPS valid still parse
    }
}

@Suite(.timeLimit(.minutes(1))) struct HEVCSPSRobustnessTests {
    /// HEVC SPS up to the conformance window (ITU-T H.265 §7.3.2.2, profile_tier_level §7.3.3).
    static func build(maxSubLayersMinus1: UInt64 = 0, subLayerFlags: Bool = false, chromaFormat: UInt32 = 1,
                      width: UInt32 = 1920, height: UInt32 = 1088, window: (UInt32, UInt32, UInt32, UInt32)? = (0, 0, 0, 4)) -> Data {
        var w = TestBitWriter()
        w.bits(0, 4)                                 // sps_video_parameter_set_id
        w.bits(maxSubLayersMinus1, 3)
        w.bit(true)                                  // sps_temporal_id_nesting_flag
        w.bits(0, 2); w.bit(false); w.bits(1, 5)     // profile space, tier, general_profile_idc = Main
        w.bits(0x6000_0000, 32)                      // compatibility flags
        w.bits(0x9000_0000_0000, 48)                 // constraint flags
        w.bits(123, 8)                               // general_level_idc (4.1)
        for _ in 0..<maxSubLayersMinus1 { w.bit(subLayerFlags); w.bit(subLayerFlags) }
        if maxSubLayersMinus1 > 0 { for _ in maxSubLayersMinus1..<8 { w.bits(0, 2) } }
        if subLayerFlags { for _ in 0..<maxSubLayersMinus1 { w.bits(0, 88); w.bits(0, 8) } }
        w.ue(0)                                      // sps_seq_parameter_set_id
        w.ue(chromaFormat)
        if chromaFormat == 3 { w.bit(false) }
        w.ue(width); w.ue(height)
        w.bit(window != nil)
        if let window { w.ue(window.0); w.ue(window.1); w.ue(window.2); w.ue(window.3) }
        w.bits(0, 16)                                // remaining fields (not parsed)
        w.trailing()
        return w.nal(header: [0x42, 0x01])
    }

    @Test func craftedSPSParses() throws {
        let sps = try #require(HEVCSPS.parse(Self.build()))
        #expect(sps.width == 1920 && sps.height == 1080)
        #expect(sps.generalProfileIDC == 1 && sps.generalLevelIDC == 123)
        let layered = try #require(HEVCSPS.parse(Self.build(maxSubLayersMinus1: 2, subLayerFlags: true)))
        #expect(layered.width == 1920 && layered.height == 1080)
    }

    @Test func extremeFieldsAreRejectedWithoutTrapping() {
        let maxUE = UInt32.max - 1
        #expect(HEVCSPS.parse(Self.build(width: maxUE, height: maxUE, window: nil)) == nil)
        #expect(HEVCSPS.parse(Self.build(window: (maxUE, maxUE, maxUE, maxUE))) == nil)
        #expect(HEVCSPS.parse(Self.build(chromaFormat: 7)) == nil)
        #expect(HEVCSPS.parse(Self.build(maxSubLayersMinus1: 7, subLayerFlags: true)) != nil)
    }

    @Test func fuzzedSPSNeverTraps() {
        var rng = SplitMix64(state: 0x4E_5C)
        let seeds = [Self.build(), Self.build(maxSubLayersMinus1: 3, subLayerFlags: true), Self.build(chromaFormat: 3)]
        var parsed = 0
        for seed in seeds {
            for candidate in mutations(of: seed, count: 3_000, rng: &rng) {
                if let sps = HEVCSPS.parse(candidate) {
                    parsed += 1
                    #expect(sps.width > 0 && sps.width <= 16_384 && sps.height > 0 && sps.height <= 16_384)
                }
                _ = VideoFormat.hevc(vps: Data([0x40, 0x01]), sps: candidate, pps: Data([0x44, 0x01]))
            }
        }
        for _ in 0..<3_000 {
            _ = HEVCSPS.parse(Data([0x42, 0x01] + (0..<Int.random(in: 0...64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        }
        #expect(parsed > 0)
    }
}

@Suite struct MediaTimeSaturationTests {
    /// Verifier repro: `Int64(Double)` trapped on NaN / ±∞ / out-of-range values.
    @Test func secondsNeverTraps() {
        #expect(MediaTime.seconds(.nan) == MediaTime(value: 0, timescale: 90_000))
        #expect(MediaTime.seconds(.infinity).value == .max)
        #expect(MediaTime.seconds(-.infinity).value == .min)
        #expect(MediaTime.seconds(1e300).value == .max)
        #expect(MediaTime.seconds(-1e300).value == .min)
        #expect(MediaTime.seconds(.greatestFiniteMagnitude, timescale: 1).value == .max)
        #expect(MediaTime.seconds(0x1p63, timescale: 1).value == .max)          // 2⁶³ is just outside Int64
        #expect(MediaTime.seconds(-0x1p63, timescale: 1).value == .min)         // −2⁶³ is exactly Int64.min
        #expect(MediaTime.seconds(.infinity, timescale: 0).value == 0)          // ∞ · 0 = NaN
        #expect(MediaTime.seconds(.nan, timescale: 0).timescale == 0)
    }

    @Test func secondsStillRoundsNormalValues() {
        #expect(MediaTime.seconds(1.5).value == 135_000)
        #expect(MediaTime.seconds(-0.5, timescale: 3).value == -2)             // −1.5 rounds away from zero
        #expect(MediaTime.seconds(1 / 3, timescale: 48_000).value == 16_000)
        #expect(MediaTime.seconds(-.leastNonzeroMagnitude).value == 0)
    }

    @Test func arithmeticOnSaturatedValuesDoesNotTrap() {
        let huge = MediaTime.seconds(.infinity)
        #expect((huge + MediaTime(value: 1, timescale: 90_000)).value == .min)   // wraps, never traps
        #expect((MediaTime.seconds(-.infinity) - MediaTime(value: 1, timescale: 1)).timescale == 90_000)
        #expect(huge.converted(to: 1).value == Int64.max / 90_000 + 1)          // 102481911520608.62 rounds up
        #expect(huge > MediaTime.seconds(1e6))
    }
}
