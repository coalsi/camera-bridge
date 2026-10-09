#if os(macOS)
import FMP4
import Foundation
import MediaCore
import Testing
import TestSupport

extension EndToEndTests {
    /// Self-tests of the keyframe check behind the ffprobe oracle (`FFmpegOracle.ffprobeAndFFmpegReadTheRecording`). They
    /// always run and need no ffprobe: fragments come from the real `FMP4Muxer`, ffprobe's packet flags are written by
    /// hand. The expected keyframes come from each sample's NAL units (not the trun flags the in-house box walk reads), and
    /// every disagreement counts: a later fragment starting without a keyframe, a keyframe anywhere else, a lost packet.
    @Suite struct KeyframeOracle {
        private static let sps = Data([0x67, 0x4D, 0x00, 0x28, 0x95, 0xA0, 0x14, 0x01, 0x6E, 0x40])
        private static let pps = Data([0x68, 0xEE, 0x3C, 0x80])
        private static let format = VideoFormat(codec: .h264, width: 1280, height: 720, parameterSets: [sps, pps])

        /// One sample: whether the muxer is told it is a keyframe (sync sample flags) and whether its NAL unit is an IDR slice.
        private struct Sample {
            var sync: Bool
            var idr: Bool
            static let idr = Sample(sync: true, idr: true)
            static let delta = Sample(sync: false, idr: false)
        }

        /// A recording muxed by `FMP4Muxer`, one fragment per element of `layout`, parsed back by the end-to-end box walk.
        private static func recording(_ layout: [[Sample]]) throws -> (video: InitSegmentInfo.Track, fragments: [FragmentInfo]) {
            var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
            let video = try #require(try InitSegmentInfo(muxer.initializationSegment()).video)
            var fragments: [FragmentInfo] = []
            var index = 0
            for (number, samples) in layout.enumerated() {
                let frames = samples.map { sample in
                    defer { index += 1 }
                    return EncodedVideoFrame(format: format,
                                             nalUnits: [SyntheticNALSource.videoNAL(index: index, isKeyframe: sample.idr, size: 64, codec: .h264)],
                                             isKeyframe: sample.sync, pts: MediaTime(value: Int64(index) * 3_000, timescale: 90_000), wallClock: Date())
                }
                let next = number == layout.count - 1 ? nil : MediaTime(value: Int64(index) * 3_000, timescale: 90_000)
                fragments.append(try FragmentInfo(try muxer.fragment(video: frames, audio: [], nextDecodeTime: next)))
            }
            return (video, fragments)
        }

        /// ffprobe's `-show_entries packet=flags -of csv=p=0` lines for `keyframes` ("K__" / "___"; ffmpeg 4 printed "K_" / "__").
        private static func ffprobeFlags(_ keyframes: [Bool], width: Int = 3) -> [String] {
            keyframes.map { ($0 ? "K" : "_") + String(repeating: "_", count: width - 1) }
        }

        /// Two-GOP first fragment (a 2 s GOP in a 4 s fragment), then two one-GOP fragments.
        private static let layout: [[Sample]] = [[.idr, .delta, .delta, .idr, .delta], [.idr, .delta, .delta], [.idr, .delta]]
        private static let keyframes = [true, false, false, true, false, true, false, false, true, false]

        @Test func expectedKeyframesAreTheIDRSamplesOfEveryFragment() throws {
            let (video, fragments) = try Self.recording(Self.layout)
            let expected = try ExpectedKeyframes(fragments: fragments, video: video)
            #expect(expected == ExpectedKeyframes(keyframes: Self.keyframes, fragmentStarts: [0, 5, 8]))
        }

        @Test func expectedKeyframesComeFromTheBitstreamNotTheTrunFlags() throws {
            // A writer bug: sample 1 is a P slice flagged as a sync sample, and the in-house trun parser reads it as one.
            let (video, fragments) = try Self.recording([[.idr, Sample(sync: true, idr: false), .delta], [.idr, .delta]])
            #expect(fragments[0].run(track: video.id)?.flags[1] == 0x0200_0000)
            let expected = try ExpectedKeyframes(fragments: fragments, video: video)
            #expect(expected == ExpectedKeyframes(keyframes: [true, false, false, true, false], fragmentStarts: [0, 3]))
            // ffprobe takes K from those same trun flags, so the oracle reports the sample.
            let mismatches = keyframeMismatches(ffprobeFlags: Self.ffprobeFlags([true, true, false, true, false]), expected: expected)
            #expect(mismatches.count == 1 && mismatches.first?.contains("packet 1") == true, "\(mismatches)")
        }

        @Test(arguments: [3, 2])
        func flagsThatAgreePass(width: Int) {
            let expected = ExpectedKeyframes(keyframes: Self.keyframes, fragmentStarts: [0, 5, 8])
            #expect(keyframeMismatches(ffprobeFlags: Self.ffprobeFlags(Self.keyframes, width: width), expected: expected).isEmpty)
            // Discard / corrupt markers after K do not matter here (ffmpeg's decode check catches corruption).
            var marked = Self.ffprobeFlags(Self.keyframes, width: width)
            marked[1] = "_D_"
            marked[5] = "KD_"
            #expect(keyframeMismatches(ffprobeFlags: marked, expected: expected).isEmpty)
        }

        @Test func aLaterFragmentStartingWithoutAKeyframeIsReported() {
            let expected = ExpectedKeyframes(keyframes: Self.keyframes, fragmentStarts: [0, 5, 8])
            var keyframes = Self.keyframes
            keyframes[5] = false          // the first packet is still K: the old check saw nothing wrong
            let mismatches = keyframeMismatches(ffprobeFlags: Self.ffprobeFlags(keyframes), expected: expected)
            #expect(mismatches.contains { $0.contains("fragment 1") && $0.contains("packet 5") }, "\(mismatches)")
        }

        @Test func aKeyframeAnywhereElseIsReported() {
            let expected = ExpectedKeyframes(keyframes: Self.keyframes, fragmentStarts: [0, 5, 8])
            var keyframes = Self.keyframes
            keyframes[2] = true
            keyframes[9] = true
            let mismatches = keyframeMismatches(ffprobeFlags: Self.ffprobeFlags(keyframes), expected: expected)
            #expect(mismatches.count == 2, "\(mismatches)")
            #expect(mismatches.contains { $0.contains("packet 2") } && mismatches.contains { $0.contains("packet 9") }, "\(mismatches)")
        }

        @Test func aMidFragmentKeyframeThatFFprobeMissesIsReported() {
            let expected = ExpectedKeyframes(keyframes: Self.keyframes, fragmentStarts: [0, 5, 8])
            var keyframes = Self.keyframes
            keyframes[3] = false
            let mismatches = keyframeMismatches(ffprobeFlags: Self.ffprobeFlags(keyframes), expected: expected)
            #expect(mismatches.count == 1 && mismatches.first?.contains("packet 3") == true, "\(mismatches)")
        }

        @Test func aLostOrExtraPacketIsReported() {
            let expected = ExpectedKeyframes(keyframes: Self.keyframes, fragmentStarts: [0, 5, 8])
            #expect(!keyframeMismatches(ffprobeFlags: Self.ffprobeFlags(Array(Self.keyframes.dropLast())), expected: expected).isEmpty)
            #expect(!keyframeMismatches(ffprobeFlags: Self.ffprobeFlags(Self.keyframes + [false]), expected: expected).isEmpty)
            #expect(!keyframeMismatches(ffprobeFlags: [], expected: expected).isEmpty)
        }
    }
}
#endif
