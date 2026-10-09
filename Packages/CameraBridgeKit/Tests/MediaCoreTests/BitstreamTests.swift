import Foundation
import Testing
@testable import MediaCore

// Review finding: bitstream parsing was duplicated outside MediaCore — a second H.264/HEVC SPS walker in FMP4 only for
// the VUI sample aspect ratio (plus partial ones for the avcC/hvcC fields), AudioSpecificConfig parsers in FMP4 and RTSP,
// bit readers in MediaCore, FMP4 and RTSP, and H.264 Table A-1 in BridgeEngine and PlatformApple — and the copies had
// diverged. These pin the shared versions (package-visible) that FMP4, RTSP, BridgeEngine and PlatformApple now use.

private func bytes(_ hex: String) throws -> Data {
    try #require(Data(hex: hex))
}

@Suite struct SharedBitReaderTests {
    @Test func readsUpTo64BitsMSBFirst() throws {
        var r = BitReader(try bytes("0123456789abcdeff0"))
        #expect(try r.bits(4) == 0)
        #expect(try r.bits(48) == 0x1234_5678_9ABC)          // the hvcC constraint flags are 48 bits
        #expect(r.position == 52 && r.bitsRemaining == 20)
        #expect(try r.bits(20) == 0xDEFF0)
        #expect(throws: BitReader.Failure.exhausted) { try r.bits(1) }
        var full = BitReader(Data(repeating: 0xFF, count: 8))
        #expect(try full.bits(64) == .max)
        var tooWide = BitReader(Data(repeating: 0, count: 16))
        #expect(throws: BitReader.Failure.invalid) { try tooWide.bits(65) }
        #expect(tooWide.position == 0)
    }

    @Test func expGolombCodes() throws {
        // 1 | 010 | 011 | 00100 → ue 0, 1, 2, 3; the same codes as se(v) are 0, 1, −1, 2.
        let data = Data([0b1010_0110, 0b0100_0000])
        var unsigned = BitReader(data)
        #expect(try [unsigned.ue(), unsigned.ue(), unsigned.ue(), unsigned.ue()] == [0, 1, 2, 3])
        var signed = BitReader(data)
        #expect(try [signed.se(), signed.se(), signed.se(), signed.se()] == [0, 1, -1, 2])
        // 31 leading zeros is the longest code (2³² − 2); 32 is invalid.
        var longest = BitReader(Data([0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFE]))
        #expect(try longest.ue() == UInt32.max - 1)
        var invalid = BitReader(Data([0, 0, 0, 0, 0x80]))
        #expect(throws: BitReader.Failure.invalid) { try invalid.ue() }
    }
}

@Suite struct ParameterSetSampleAspectRatioTests {
    /// ffmpeg 8.1.1 `-vf setsar=…` streams (the same SPSs as FMP4Tests' `SARGolden`, which covers every SPS branch).
    @Test func h264StatesItsSampleAspectRatio() throws {
        let sps = try #require(H264SPS.parse(try bytes("6764001eacb2016024d810800000030080000019078b1724")))
        #expect(sps.width == 704 && sps.height == 576)
        #expect(sps.sampleAspectRatio == SampleAspectRatio(horizontal: 12, vertical: 11))
        let extended = try #require(H264SPS.parse(try bytes("674d401ed900a02ff97ff000700051000003000100000300320f162e48")))
        #expect(extended.width == 640 && extended.height == 360)
        #expect(extended.sampleAspectRatio == SampleAspectRatio(horizontal: 7, vertical: 5))
        #expect(try #require(H264SPS.parse(try bytes("2764001fac562c0b012640"))).sampleAspectRatio == nil)   // no VUI SAR
        // The VUI is read past the aspect ratio: Extended_SAR 1:1 and then the frame rate.
        let built = try #require(H264SPS.parse(H264SPSBuilder().build()))
        #expect(built.sampleAspectRatio == SampleAspectRatio(horizontal: 1, vertical: 1))
        #expect(built.frameRate == 60_000.0 / 2002.0)
    }

    @Test func h264ChromaFormatAndBitDepths() throws {
        let main = try #require(H264SPS.parse(try bytes("674d401ed900a02ff97ff000700051000003000100000300320f162e48")))
        #expect(main.chromaFormatIDC == 1 && main.bitDepthLumaMinus8 == 0 && main.bitDepthChromaMinus8 == 0)
        var builder = H264SPSBuilder()
        builder.chromaFormat = 2
        let fourTwoTwo = try #require(H264SPS.parse(builder.build()))
        #expect(fourTwoTwo.chromaFormatIDC == 2)
    }

    @Test func hevcStatesItsSampleAspectRatioAndConfigurationFields() throws {
        let sps = try #require(HEVCSPS.parse(try bytes("42010101600000030090000003000003005aa0058200905964a924caf0268080000003008000000c84")))
        #expect(sps.width == 704 && sps.height == 576 && sps.generalProfileIDC == 1 && sps.generalLevelIDC == 90)
        #expect(sps.sampleAspectRatio == SampleAspectRatio(horizontal: 12, vertical: 11))
        #expect(sps.maxSubLayersMinus1 == 0 && sps.temporalIDNesting)
        #expect(sps.generalProfileSpace == 0 && !sps.generalTierFlag)
        #expect(sps.generalProfileCompatibilityFlags == 0x6000_0000 && sps.generalConstraintIndicatorFlags == 0x9000_0000_0000)
        #expect(sps.chromaFormatIDC == 1 && sps.bitDepthLumaMinus8 == 0 && sps.bitDepthChromaMinus8 == 0)
        let hex = "42010101600000030090000003000003003fa00502016965959a4932bffc001c0015a02000000300200000030321"
        let extended = try #require(HEVCSPS.parse(try bytes(hex)))
        #expect(extended.width == 640 && extended.height == 360)
        #expect(extended.sampleAspectRatio == SampleAspectRatio(horizontal: 7, vertical: 5))
    }

    /// An SPS that ends after the conformance window still gives its size, profile and level; the fields after it
    /// (bit depths, the VUI aspect ratio) are absent rather than guessed.
    @Test func hevcSPSTruncatedAfterTheConformanceWindow() throws {
        let sps = try #require(HEVCSPS.parse(HEVCSPSRobustnessTests.build()))
        #expect(sps.width == 1920 && sps.height == 1080)
        #expect(sps.bitDepthLumaMinus8 == nil && sps.bitDepthChromaMinus8 == nil && sps.sampleAspectRatio == nil)
    }

    @Test func tableE1AndReduction() {
        #expect(SampleAspectRatio(horizontal: 24, vertical: 22) == SampleAspectRatio(horizontal: 12, vertical: 11))
        #expect(SampleAspectRatio(horizontal: 0, vertical: 1) == nil)
        #expect(SampleAspectRatio(horizontal: 1, vertical: 0) == nil)
        #expect(SampleAspectRatio.predefined(16) == SampleAspectRatio(horizontal: 2, vertical: 1))
        #expect(SampleAspectRatio.predefined(0) == nil)                  // unspecified
        #expect(SampleAspectRatio.predefined(17) == nil)                 // reserved
    }

    @Test func videoFormatFindsTheSPS() throws {
        let sps = try bytes("6764001eacb2016024d810800000030080000019078b1724")
        let format = VideoFormat(codec: .h264, width: 704, height: 576, parameterSets: [Data([0x68, 0xEB]), sps])
        #expect(format.sampleAspectRatio == SampleAspectRatio(horizontal: 12, vertical: 11))
        #expect(VideoFormat(codec: .h264, width: 704, height: 576, parameterSets: []).sampleAspectRatio == nil)
    }
}

@Suite struct SharedAudioSpecificConfigTests {
    @Test func parsesTheLeadingFields() throws {
        #expect(AudioSpecificConfig(Data([0x12, 0x10])) == AudioSpecificConfig(objectType: 2, sampleRate: 44_100, channelConfiguration: 2))
        #expect(AudioSpecificConfig(Data([0x17, 0x80, 0x1F, 0x40, 0x08]))?.sampleRate == 16_000)            // explicit frequency
        #expect(AudioSpecificConfig(Data([0xF8, 0xF0, 0x20, 0x00]))?.objectType == 39)                      // 31 escapes to 32 + 7
        let eightChannels = try #require(AudioFormat.aacLC(sampleRate: 48_000, channels: 8).audioSpecificConfig)
        let eight = try #require(AudioSpecificConfig(eightChannels))
        #expect(eight.channelConfiguration == 7 && eight.channels == 8)
        #expect(AudioSpecificConfig(Data([0x12, 0x08]))?.channels == 1)
    }

    /// RTSP's copy rejected explicit frequencies outside 1…1 000 000 Hz and FMP4's accepted any 24-bit value; the
    /// shared parser rejects them for both.
    @Test func rejectsReservedTruncatedAndOutOfRangeConfigurations() throws {
        #expect(AudioSpecificConfig(Data()) == nil)
        #expect(AudioSpecificConfig(Data([0x12])) == nil)                                    // truncated
        #expect(AudioSpecificConfig(Data([0x16, 0x88])) == nil)                              // reserved frequency index 13
        #expect(AudioSpecificConfig(Data([0x17, 0x80, 0x00, 0x00, 0x08])) == nil)            // explicit 0 Hz
        #expect(AudioSpecificConfig(Data([0x17, 0xFF, 0xFF, 0xFF, 0x88])) == nil)            // explicit 16 777 215 Hz
        let top = try #require(AudioFormat.aacLC(sampleRate: 1_000_000, channels: 1).audioSpecificConfig)
        #expect(AudioSpecificConfig(top)?.sampleRate == 1_000_000)
        let beyond = try #require(AudioFormat.aacLC(sampleRate: 1_000_001, channels: 1).audioSpecificConfig)
        #expect(AudioSpecificConfig(beyond) == nil)
    }

    /// Round-2 review finding: RTP wrote AAC-ELD configs with its own frequency table and bit packing, and
    /// `AudioFormat.aacLC` packed AAC-LC ones with another. Both now use the one writer, `encoded`.
    @Test func writesAACLCAndELDConfigurations() throws {
        func config(_ objectType: Int, _ sampleRate: Int, _ channelConfiguration: Int) -> AudioSpecificConfig {
            AudioSpecificConfig(objectType: objectType, sampleRate: sampleRate, channelConfiguration: channelConfiguration)
        }
        // AAC-LC: GASpecificConfig all zero (1024-sample frames); 2 bytes for table rates.
        #expect(config(2, 32_000, 1).encoded == Data([0x12, 0x88]))
        #expect(config(2, 44_100, 2).encoded == Data([0x12, 0x10]))
        #expect(config(2, 16_000, 7).encoded == Data([0x14, 0x38]))
        // Explicit 24-bit frequency for other rates: 5 bytes.
        #expect(config(2, 16_000 + 1, 1).encoded?.count == 5)
        #expect(config(2, 12_345, 1).encoded == Data([0x17, 0x80, 0x18, 0x1C, 0x88]))
        // AAC-ELD: object type 31 + 7, ELDSpecificConfig (480-sample frames, no resilience, no LD-SBR, ELDEXT_TERM),
        // epConfig 0 — HomeKit's live-audio configs.
        #expect(config(39, 16_000, 1).encoded == Data([0xF8, 0xF0, 0x30, 0x00]))
        #expect(config(39, 24_000, 1).encoded == Data([0xF8, 0xEC, 0x30, 0x00]))
        #expect(config(39, 16_000, 2).encoded == Data([0xF8, 0xF0, 0x50, 0x00]))
        // What it writes, the parser reads back.
        for original in [config(2, 48_000, 2), config(2, 12_345, 1), config(39, 16_000, 1), config(39, 12_345, 3)] {
            let data = try #require(original.encoded)
            #expect(AudioSpecificConfig(data) == original, "\(original)")
        }
        // `AudioFormat.aacLC` is this writer (8 channels → configuration 7).
        #expect(AudioFormat.aacLC(sampleRate: 22_050, channels: 2).audioSpecificConfig == config(2, 22_050, 2).encoded)
        #expect(AudioFormat.aacLC(sampleRate: 48_000, channels: 8).audioSpecificConfig == config(2, 48_000, 7).encoded)
        // Nothing it cannot represent: object types without a known specific config, 4-bit channel configurations,
        // 24-bit explicit frequencies.
        #expect(config(5, 16_000, 1).encoded == nil)                // SBR
        #expect(config(2, 16_000, 16).encoded == nil)
        #expect(config(2, 16_000, -1).encoded == nil)
        #expect(config(2, -1, 1).encoded == nil)
        #expect(config(2, 1 << 24, 1).encoded == nil)
        #expect(config(2, (1 << 24) - 1, 1).encoded?.count == 5)
    }
}

/// Round-2 review finding: BridgeEngine's B-slice check (`StreamTraits.hasBSlice`) kept its own Exp-Golomb bit reader
/// for H.264 slice headers after the first consolidation; the slice header is now read here, on `BitReader`.
@Suite struct H264SliceTypeTests {
    @Test func sliceTypeIsTheSecondCodeOfTheSliceHeader() {
        // first_mb_in_slice ue(v), slice_type ue(v) (H.264 §7.3.3).
        #expect(NALUnits.h264SliceType(Data([0x41, 0xC0])) == 0)                   // mb 0, P
        #expect(NALUnits.h264SliceType(Data([0x41, 0x98])) == 5)                   // mb 0, P (all slices)
        #expect(NALUnits.h264SliceType(Data([0x01, 0xA0])) == 1)                   // mb 0, B
        #expect(NALUnits.h264SliceType(Data([0x01, 0x9C])) == 6)                   // mb 0, B (all slices)
        #expect(NALUnits.h264SliceType(Data([0x01, 0x03, 0x2A])) == 1)             // mb 100, B
        #expect(NALUnits.h264SliceType(Data([0x65, 0x88, 0x84, 0x00])) == 7)       // IDR: mb 0, I (all slices)
        // The header is read as RBSP: `00 00 03` drops its emulation-prevention byte (RBSP 00 00 01 FF FF FE 80:
        // first_mb_in_slice 2²⁴ − 2, then slice_type 1).
        #expect(NALUnits.h264SliceType(Data([0x01, 0x00, 0x00, 0x03, 0x01, 0xFF, 0xFF, 0xFE, 0x80])) == 1)
    }

    @Test func otherUnitsAndBrokenHeadersHaveNoSliceType() {
        #expect(NALUnits.h264SliceType(Data()) == nil)
        #expect(NALUnits.h264SliceType(Data([0x06, 0x05, 0x01])) == nil, "SEI")
        #expect(NALUnits.h264SliceType(Data([0x67, 0x64, 0x00, 0x1F])) == nil, "SPS")
        #expect(NALUnits.h264SliceType(Data([0x01])) == nil, "no header")
        #expect(NALUnits.h264SliceType(Data([0x01, 0x80])) == nil, "slice_type cut off")
        #expect(NALUnits.h264SliceType(Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x80])) == nil, "a code longer than 32 bits")
    }
}

@Suite struct H264LevelLimitsTests {
    @Test func frameSizeAndMacroblockRate() {
        #expect(H264LevelLimits.fits(width: 1920, height: 1080, fps: 30, levelIDC: 40))
        #expect(!H264LevelLimits.fits(width: 1920, height: 1080, fps: 30, levelIDC: 31))
        #expect(H264LevelLimits.fits(width: 1280, height: 720, fps: 30, levelIDC: 31))
        #expect(!H264LevelLimits.fits(width: 1280, height: 720, fps: 60, levelIDC: 31))
        #expect(!H264LevelLimits.fits(width: 2560, height: 1440, fps: 20, levelIDC: 40))
        #expect(!H264LevelLimits.fits(width: 1920, height: 1080, fps: 30, levelIDC: 7))     // not a level
        #expect(!H264LevelLimits.fits(width: 0, height: 1080, fps: 30, levelIDC: 52))
    }

    /// §A.3.1: PicWidthInMbs and FrameHeightInMbs ≤ √(8 × MaxFS) — 169 macroblocks at level 3.1.
    @Test func perDimensionLimit() {
        #expect(H264LevelLimits.fits(width: 2704, height: 240, fps: 30, levelIDC: 31))
        #expect(!H264LevelLimits.fits(width: 2720, height: 240, fps: 30, levelIDC: 31))
        #expect(!H264LevelLimits.fits(width: 240, height: 2720, fps: 30, levelIDC: 31))
        #expect(H264LevelLimits.fits(width: 2720, height: 240, fps: 30, levelIDC: 32))   // √(8 × 5120) = 202
    }

    @Test func lowestFittingLevel() {
        #expect(H264LevelLimits.lowestLevel(width: 1920, height: 1080, fps: 30, atLeast: 31) == 40)
        #expect(H264LevelLimits.lowestLevel(width: 1280, height: 720, fps: 30, atLeast: 31) == 31)
        #expect(H264LevelLimits.lowestLevel(width: 2720, height: 240, fps: 30, atLeast: 31) == 32)
        #expect(H264LevelLimits.lowestLevel(width: 320, height: 240, fps: 30, atLeast: 51) == 51)      // never lowered
        #expect(H264LevelLimits.lowestLevel(width: 7680, height: 4320, fps: 30, atLeast: 40) == nil)   // beyond 5.2
    }
}
