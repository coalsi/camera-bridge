import BridgeSupport
import Foundation
import Testing
@testable import MediaCore
#if canImport(VideoToolbox)
import CoreMedia
import VideoToolbox
#endif

@Suite struct MediaTimeTests {
    @Test func secondsAndConversion() {
        let t = MediaTime.seconds(1.5)
        #expect(t.value == 135_000 && t.timescale == 90_000)
        #expect(t.seconds == 1.5)
        #expect(t.converted(to: 48_000) == MediaTime(value: 72_000, timescale: 48_000))
        #expect(MediaTime(value: 1, timescale: 3).converted(to: 90_000).value == 30_000)
        // Rounds to nearest.
        #expect(MediaTime(value: 2, timescale: 3).converted(to: 10).value == 7)
        #expect(MediaTime(value: -2, timescale: 3).converted(to: 10).value == -7)
    }

    @Test func conversionDoesNotOverflow() {
        let large = MediaTime(value: Int64.max / 1000, timescale: 1000)
        #expect(large.converted(to: 1000).value == Int64.max / 1000)
        let ntp = MediaTime(value: 9_000_000_000_000, timescale: 90_000)
        #expect(ntp.converted(to: 48_000).value == 4_800_000_000_000)
    }

    @Test func arithmeticUsesLeftTimescale() {
        let a = MediaTime(value: 90_000, timescale: 90_000)
        let b = MediaTime(value: 24_000, timescale: 48_000)
        #expect(a - b == MediaTime(value: 45_000, timescale: 90_000))
        #expect((a + b).timescale == 90_000)
        #expect((a + b).value == 135_000)
        #expect((b - a).timescale == 48_000)
        #expect((b - a).value == -24_000)
    }

    @Test func comparisonAndEqualityAcrossTimescales() {
        let one90k = MediaTime(value: 90_000, timescale: 90_000)
        let one48k = MediaTime(value: 48_000, timescale: 48_000)
        #expect(one90k == one48k)
        #expect(one90k.hashValue == one48k.hashValue)
        #expect(MediaTime(value: 1, timescale: 48_000) > MediaTime(value: 1, timescale: 90_000))
        #expect([MediaTime(value: 3, timescale: 1), .seconds(0.5), .seconds(2, timescale: 1000)].sorted().map(\.seconds) == [0.5, 2, 3])
    }

    @Test func codableRoundTrip() throws {
        let t = MediaTime(value: 12_345, timescale: 90_000)
        let back = try JSONDecoder().decode(MediaTime.self, from: JSONEncoder().encode(t))
        #expect(back.value == 12_345 && back.timescale == 90_000)
    }
}

@Suite struct NALUnitsTests {
    @Test func splitsAnnexBWithThreeAndFourByteStartCodes() throws {
        let stream = try #require(Data(hex: "00000001 6742 000001 68ce 00000001 6588 8400 00 000001 0601"))
        let nals = NALUnits.splitAnnexB(stream)
        #expect(nals == [Data([0x67, 0x42]), Data([0x68, 0xCE]), Data([0x65, 0x88, 0x84]), Data([0x06, 0x01])])
        #expect(nals.map(NALUnits.h264Type) == [7, 8, 5, 6])
    }

    @Test func annexBIgnoresLeadingGarbageAndEmptyUnits() throws {
        let stream = try #require(Data(hex: "ffff 000001 000001 41aa"))
        #expect(NALUnits.splitAnnexB(stream) == [Data([0x41, 0xAA])])
        #expect(NALUnits.splitAnnexB(Data([0x65, 0x01])) == [])
        #expect(NALUnits.splitAnnexB(Data()) == [])
    }

    @Test func splitsLengthPrefixed() throws {
        let four = try #require(Data(hex: "00000002 6742 00000003 65aabb"))
        #expect(NALUnits.splitLengthPrefixed(four) == [Data([0x67, 0x42]), Data([0x65, 0xAA, 0xBB])])
        let two = try #require(Data(hex: "0001 41 0002 4142"))
        #expect(NALUnits.splitLengthPrefixed(two, lengthSize: 2) == [Data([0x41]), Data([0x41, 0x42])])
        let truncated = try #require(Data(hex: "00000002 6742 00000009 65"))
        #expect(NALUnits.splitLengthPrefixed(truncated) == [Data([0x67, 0x42])])
    }

    @Test func nalTypes() {
        #expect(NALUnits.h264Type(Data([0x65])) == 5)
        #expect(NALUnits.h264Type(Data()) == 0)
        #expect(NALUnits.hevcType(Data([0x40, 0x01])) == 32)   // VPS
        #expect(NALUnits.hevcType(Data([0x42, 0x01])) == 33)   // SPS
        #expect(NALUnits.hevcType(Data([0x26, 0x01])) == 19)   // IDR_W_RADL
    }

    @Test func removesEmulationPrevention() throws {
        #expect(NALUnits.removeEmulationPrevention(try #require(Data(hex: "000003 01"))) == Data([0, 0, 1]))
        #expect(NALUnits.removeEmulationPrevention(try #require(Data(hex: "000003 03 000003"))) == Data([0, 0, 3, 0, 0]))
        let expected = try #require(Data(hex: "0003 00 0000 00"))
        #expect(NALUnits.removeEmulationPrevention(try #require(Data(hex: "0003 00 000003 00"))) == expected)
        let untouched = try #require(Data(hex: "6742001f"))
        #expect(NALUnits.removeEmulationPrevention(untouched) == untouched)
    }
}

@Suite struct FrameTests {
    private let format = VideoFormat(codec: .h264, width: 2, height: 2, parameterSets: [Data([0x67]), Data([0x68])])

    @Test func lengthPrefixedAndAnnexB() {
        let frame = EncodedVideoFrame(format: format, nalUnits: [Data([0x65, 0x01]), Data([0x65, 0x02, 0x03])], isKeyframe: true,
                                      pts: .seconds(1), wallClock: Date(timeIntervalSince1970: 5))
        #expect(frame.lengthPrefixedData.hexString == "000000026501" + "00000003650203")
        #expect(frame.annexBData.hexString == "000000016501" + "00000001650203")
        #expect(frame.dts == nil)
        #expect(MediaSample.video(frame).wallClock == Date(timeIntervalSince1970: 5))
    }

    @Test func audioFrameAndSamplesPerFrame() {
        let aac = AudioFormat(codec: .aac, sampleRate: 32_000, channels: 1, audioSpecificConfig: Data([0x12, 0x88]))
        let frame = EncodedAudioFrame(format: aac, data: Data([1, 2, 3]), pts: MediaTime(value: 1024, timescale: 32_000), sampleCount: 1024,
                                      wallClock: Date(timeIntervalSince1970: 9))
        #expect(MediaSample.audio(frame).wallClock == Date(timeIntervalSince1970: 9))
        #expect(aac.samplesPerFrame == 1024)
        #expect(AudioFormat(codec: .aacELD, sampleRate: 16_000, channels: 1).samplesPerFrame == 480)
        #expect(AudioFormat(codec: .opus, sampleRate: 24_000, channels: 1).samplesPerFrame == 960)
        #expect(AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1).samplesPerFrame == 0)
        #expect(AudioFormat(codec: .linearPCM, sampleRate: 8_000, channels: 1).samplesPerFrame == 0)
    }

    @Test func streamInfoIsCodable() throws {
        let info = StreamInfo(url: try #require(URL(string: "rtsp://10.0.0.2:554/Streaming/Channels/101")), videoCodec: .h264, width: 1920, height: 1080, fps: 20,
                              audioCodec: .pcmu, audioSampleRate: 8000, audioChannels: 1)
        #expect(try JSONDecoder().decode(StreamInfo.self, from: JSONEncoder().encode(info)) == info)
    }
}

@Suite(.timeLimit(.minutes(1))) struct H264SPSTests {
    #if canImport(VideoToolbox)
    @Test func parsesVideoToolbox1080pHigh40() throws {
        let sets = try encoderParameterSets(codec: kCMVideoCodecType_H264, width: 1920, height: 1080, profileLevel: kVTProfileLevel_H264_High_4_0)
        #expect(sets.count == 2)
        let sps = try #require(H264SPS.parse(sets[0]))
        #expect(sps.width == 1920)
        #expect(sps.height == 1080)
        #expect(sps.profileIDC == 100)
        #expect(sps.levelIDC == 40)
        #expect(sps.constraintFlags == sets[0][2])

        let format = try #require(VideoFormat.h264(sps: sets[0], pps: sets[1]))
        #expect(format.codec == .h264)
        #expect(format.width == 1920 && format.height == 1080)
        #expect(format.profile == 100 && format.level == 40)
        #expect(format.profileCompatibility == sets[0][2])
        #expect(format.parameterSets == [sets[0], sets[1]])
    }

    enum ProfileLevel: Sendable { case baseline31, main31, main40
        var key: CFString {
            switch self {
            case .baseline31: kVTProfileLevel_H264_Baseline_3_1
            case .main31: kVTProfileLevel_H264_Main_3_1
            case .main40: kVTProfileLevel_H264_Main_4_0
            }
        }
    }

    @Test(arguments: [(1280, 720, ProfileLevel.main31, UInt8(77), UInt8(31)),
                      (640, 360, ProfileLevel.baseline31, UInt8(66), UInt8(31)),
                      (1280, 960, ProfileLevel.main40, UInt8(77), UInt8(40))])
    func parsesOtherProfilesAndCropping(width: Int, height: Int, profileLevel: ProfileLevel, profile: UInt8, level: UInt8) throws {
        let sets = try encoderParameterSets(codec: kCMVideoCodecType_H264, width: width, height: height, profileLevel: profileLevel.key)
        let sps = try #require(H264SPS.parse(sets[0]))
        #expect(sps.width == width && sps.height == height)
        #expect(sps.profileIDC == profile && sps.levelIDC == level)
    }

    @Test func parsesWithoutNALHeaderByte() throws {
        let sets = try encoderParameterSets(codec: kCMVideoCodecType_H264, width: 1280, height: 720, profileLevel: kVTProfileLevel_H264_Main_3_1)
        let sps = try #require(H264SPS.parse(sets[0].dropFirst()))
        #expect(sps.width == 1280 && sps.height == 720)
    }
    #endif

    @Test func rejectsGarbage() {
        #expect(H264SPS.parse(Data()) == nil)
        #expect(H264SPS.parse(Data([0x67])) == nil)
        #expect(H264SPS.parse(Data([0x67, 0x64, 0x00, 0x28])) == nil)
        #expect(H264SPS.parse(Data(repeating: 0xFF, count: 12)) == nil)
        #expect(VideoFormat.h264(sps: Data([0x67, 0x42]), pps: Data([0x68])) == nil)
    }
}

#if canImport(VideoToolbox)
@Suite(.enabled(if: hevcEncoderAvailable(), "requires a VideoToolbox HEVC encoder"), .timeLimit(.minutes(1)))
struct HEVCSPSTests {
    @Test func parsesVideoToolbox1080pMain() throws {
        let sets = try encoderParameterSets(codec: kCMVideoCodecType_HEVC, width: 1920, height: 1080, profileLevel: kVTProfileLevel_HEVC_Main_AutoLevel)
        #expect(sets.count == 3)
        #expect(sets.map(NALUnits.hevcType) == [32, 33, 34])
        let sps = try #require(HEVCSPS.parse(sets[1]))
        #expect(sps.width == 1920 && sps.height == 1080)
        #expect(sps.generalProfileIDC == 1)
        #expect(sps.generalLevelIDC > 0)

        let format = try #require(VideoFormat.hevc(vps: sets[0], sps: sets[1], pps: sets[2]))
        #expect(format.codec == .hevc && format.width == 1920 && format.height == 1080)
        #expect(format.parameterSets.count == 3)
        #expect(format.profile == 1 && format.level == sps.generalLevelIDC)
    }

    @Test func parsesSmallFrame() throws {
        let sets = try encoderParameterSets(codec: kCMVideoCodecType_HEVC, width: 640, height: 360, profileLevel: kVTProfileLevel_HEVC_Main_AutoLevel)
        let sps = try #require(HEVCSPS.parse(sets[1]))
        #expect(sps.width == 640 && sps.height == 360)
    }
}
#endif

/// Needs no encoder, so it runs everywhere (split from `HEVCSPSTests`).
@Suite struct HEVCSPSRejectionTests {
    @Test func rejectsGarbage() {
        #expect(HEVCSPS.parse(Data()) == nil)
        #expect(HEVCSPS.parse(Data([0x42, 0x01, 0x01])) == nil)
    }
}

@Suite struct MediaTimeEdgeCaseTests {
    @Test func hashingExtremeValuesDoesNotTrap() {
        var set = Set<MediaTime>()
        set.insert(MediaTime(value: .min, timescale: -1))            // +2^63 s
        set.insert(MediaTime(value: .min, timescale: 90_000))
        set.insert(MediaTime(value: .max, timescale: .min))
        set.insert(MediaTime(value: 5, timescale: 0))                // time 0
        #expect(set.count == 4)
        #expect(MediaTime(value: .min, timescale: -1) > MediaTime(value: .max, timescale: 1))
        let zero = MediaTime(value: 0, timescale: 1)
        #expect(MediaTime(value: .max, timescale: .min) < zero && MediaTime(value: .min, timescale: 90_000) < zero)
    }

    /// Every zero time is equal and hashes identically, whatever its timescale (0 included).
    @Test func zeroTimesAreOneValue() {
        let zeros = [MediaTime(value: 5, timescale: 0), MediaTime(value: 0, timescale: 0), MediaTime(value: 0, timescale: 1),
                     MediaTime(value: 0, timescale: 90_000), MediaTime(value: 0, timescale: -7), MediaTime(value: .min, timescale: 0)]
        for a in zeros {
            for b in zeros {
                #expect(a == b)
                #expect(a.hashValue == b.hashValue)
            }
        }
        #expect(Set(zeros).count == 1)
    }

    /// A negative timescale negates the time for ==, hash and < alike.
    @Test func negativeTimescalesAreSignNormalised() {
        #expect(MediaTime(value: 1, timescale: -1) < MediaTime(value: 0, timescale: 1))
        #expect(MediaTime(value: 1, timescale: -1) == MediaTime(value: -1, timescale: 1))
        #expect(MediaTime(value: 1, timescale: -1).hashValue == MediaTime(value: -1, timescale: 1).hashValue)
        #expect(MediaTime(value: -2, timescale: -4) == MediaTime(value: 1, timescale: 2))
        #expect(MediaTime(value: -3, timescale: -1) > MediaTime(value: 2, timescale: 1))
        #expect(MediaTime(value: 3, timescale: -1) < MediaTime(value: -2, timescale: 1))
        let sorted = [MediaTime(value: 3, timescale: -2), MediaTime(value: 1, timescale: 1), MediaTime(value: -1, timescale: -4), .seconds(0)].sorted()
        #expect(sorted.map(\.seconds) == [-1.5, 0, 0.25, 1])
    }

    /// Randomised laws: `==` ⇒ equal hashes, `<` is a strict total order that agrees with exact rational order.
    @Test func equalityHashAndOrderingAreConsistent() {
        var rng = SplitMix64(state: 7)
        let timescales: [Int32] = [0, 1, -1, 2, -2, 3, 1000, -1000, 48_000, 90_000, -90_000, .max, .min]
        let values: [Int64] = [0, 1, -1, 2, -2, 3, 6, 1000, -3000, 90_000, 180_000, .max, .min, .max - 1, .min + 1]
        func random() -> MediaTime {
            MediaTime(value: values[Int.random(in: 0..<values.count, using: &rng)], timescale: timescales[Int.random(in: 0..<timescales.count, using: &rng)])
        }
        for _ in 0..<20_000 {
            let a = random(), b = random(), c = random()
            if a == b { #expect(a.hashValue == b.hashValue, "\(a) \(b)") }
            #expect([a < b, a == b, b < a].filter { $0 }.count == 1, "trichotomy \(a) \(b)")
            if a < b && b < c { #expect(a < c, "transitivity \(a) \(b) \(c)") }
            if a.timescale != 0 && b.timescale != 0 {
                // Exact rational order via cross-multiplication with the denominators' signs folded in.
                let lhs = Double(a.value) * Double(b.timescale) * Double(a.timescale.signum()) * Double(b.timescale.signum())
                let rhs = Double(b.value) * Double(a.timescale) * Double(a.timescale.signum()) * Double(b.timescale.signum())
                if abs(lhs - rhs) > 1e-3 * max(abs(lhs), abs(rhs)) { #expect((a < b) == (lhs < rhs), "order \(a) \(b)") }
            }
        }
    }
}
