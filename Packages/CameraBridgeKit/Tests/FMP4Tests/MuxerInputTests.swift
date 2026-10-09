import Foundation
import MediaCore
import Testing
@testable import FMP4

/// How the muxer treats imperfect input: glitched audio clocks, non-LC AAC, reordered or in-band parameter sets, empty frames.
@Suite struct MuxerInputTests {
    private let aac = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
    private let videoStart: Int64 = 90_000 * 1_000
    private let audioStart: Int64 = 32_000 * 1_000

    private func frames(_ format: VideoFormat, count: Int, from index: Int = 0) -> [EncodedVideoFrame] {
        (index..<index + count).map { i in
            Synthetic.videoFrame(format, index: i, isKeyframe: i % 30 == 0, pts: videoStart + Int64(i) * 3_000)
        }
    }

    private func audio(count: Int, from index: Int = 0) -> [EncodedAudioFrame] {
        (index..<index + count).map { Synthetic.audioFrame(aac, index: $0, pts: audioStart + Int64($0) * 1_024) }
    }

    // MARK: Audio timing

    @Test func oneGlitchedAudioTimestampDoesNotSilenceTheRestOfTheRecording() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac))
        // Fragment 1 (1 s of video) carries one AAC frame stamped 600 s ahead, as a misaligned-clock fallback passes it on.
        let glitch = Synthetic.audioFrame(aac, index: 99, pts: audioStart + 32_000 * 600)
        let first = try muxer.fragment(video: frames(format, count: 30), audio: audio(count: 31) + [glitch])
        #expect(try FragmentRuns(first).audio?.run.samples.count == 31)
        #expect(muxer.lastFragmentStatistics.outOfRangeAudioFrames == 1)
        #expect(muxer.lastFragmentStatistics.audioSamples == 31)

        let second = try muxer.fragment(video: frames(format, count: 30, from: 30), audio: audio(count: 31, from: 31))
        let run = try #require(try FragmentRuns(second).audio)
        #expect(run.run.samples.count == 31)
        #expect(run.decodeTime == 31 * 1_024)
        #expect(muxer.lastFragmentStatistics.outOfRangeAudioFrames == 0)
    }

    @Test func statisticsCountDroppedAudioAndReset() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac))
        #expect(muxer.lastFragmentStatistics == FMP4Muxer.FragmentStatistics())
        let early = Synthetic.audioFrame(aac, index: 0, pts: audioStart - 1_024)             // before the first video frame
        let sound = audio(count: 3)
        _ = try muxer.fragment(video: frames(format, count: 30), audio: [early] + sound + [sound[1]])   // plus a duplicate
        #expect(muxer.lastFragmentStatistics == FMP4Muxer.FragmentStatistics(videoSamples: 30, audioSamples: 3, droppedAudioFrames: 2))
        // A failed call leaves the statistics of the last fragment written.
        #expect(throws: FMP4Error.self) { try muxer.fragment(video: [], audio: []) }
        #expect(muxer.lastFragmentStatistics.videoSamples == 30)
    }

    // MARK: AAC-LC only

    @Test func rejectsAudioSpecificConfigsOtherThanAACLC() throws {
        let video = try Golden.h264Format
        let configs: [(String, AudioFormat)] = [
            ("HE-AAC (object type 5)", AudioFormat(codec: .aac, sampleRate: 44_100, channels: 2, audioSpecificConfig: Data([0x2B, 0x8A, 0x08, 0x00]))),
            ("AAC Main (1)", AudioFormat(codec: .aac, sampleRate: 44_100, channels: 2, audioSpecificConfig: Data([0x0A, 0x10]))),
            ("HE-AAC v2 (29)", AudioFormat(codec: .aac, sampleRate: 24_000, channels: 1, audioSpecificConfig: Data([0xEB, 0x09, 0x88, 0x00]))),
            ("AAC-ELD via the escape (39)", AudioFormat(codec: .aac, sampleRate: 16_000, channels: 1, audioSpecificConfig: Data([0xF8, 0xF0, 0x20, 0x00]))),
            ("truncated", AudioFormat(codec: .aac, sampleRate: 32_000, channels: 1, audioSpecificConfig: Data([0x12]))),
            ("reserved frequency index", AudioFormat(codec: .aac, sampleRate: 32_000, channels: 1, audioSpecificConfig: Data([0x16, 0x88]))),
            ("sample rate differs from the format", AudioFormat(codec: .aac, sampleRate: 32_000, channels: 1,
                                                               audioSpecificConfig: AudioFormat.aacLC(sampleRate: 48_000, channels: 1).audioSpecificConfig)),
        ]
        for (name, format) in configs {
            #expect(throws: FMP4Error.self, "\(name)") { try FMP4Muxer(configuration: FMP4Configuration(video: video, audio: format)) }
        }
    }

    /// Review finding: FMP4 and RTSP each parsed the AudioSpecificConfig and disagreed: RTSP rejected an explicit 24-bit
    /// sampling frequency outside 1…1 000 000 Hz, FMP4 accepted any value. MediaCore's single parser decides for both.
    @Test func rejectsExplicitFrequenciesOutsideTheSharedRange() throws {
        let video = try Golden.h264Format
        let format = AudioFormat.aacLC(sampleRate: 2_000_000, channels: 1)   // explicit frequency 2 MHz
        #expect(throws: FMP4Error.self) { try FMP4Muxer(configuration: FMP4Configuration(video: video, audio: format)) }
        // The top of the range is still accepted.
        _ = try FMP4Muxer(configuration: FMP4Configuration(video: video, audio: AudioFormat.aacLC(sampleRate: 1_000_000, channels: 1)))
    }

    @Test func acceptsAACLCConfigurations() throws {
        let video = try Golden.h264Format
        let formats = [
            AudioFormat(codec: .aac, sampleRate: 44_100, channels: 2, audioSpecificConfig: Data([0x12, 0x10])),
            AudioFormat.aacLC(sampleRate: 20_000, channels: 1),                  // explicit 24-bit frequency
            AudioFormat.aacLC(sampleRate: 48_000, channels: 8),                  // channel configuration 7
            AudioFormat(codec: .aac, sampleRate: 16_000, channels: 1, audioSpecificConfig: nil),
            // AAC-LC with backward-compatible explicit SBR signalling (sync extension 0x2B7): the core is LC.
            AudioFormat(codec: .aac, sampleRate: 24_000, channels: 2, audioSpecificConfig: Data([0x13, 0x10, 0x56, 0xE5, 0x98])),
        ]
        for format in formats {
            do {
                _ = try FMP4Muxer(configuration: FMP4Configuration(video: video, audio: format))
            } catch {
                Issue.record("\(format): \(error)")
            }
        }
    }

    @Test func audioFrameWithAnotherObjectTypeIsAFormatChange() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac))
        let heAAC = AudioFormat(codec: .aac, sampleRate: 32_000, channels: 1, audioSpecificConfig: Data([0x2B, 0x08, 0x88, 0x00]))
        #expect(throws: FMP4Error.audioFormatChanged) {
            try muxer.fragment(video: frames(format, count: 2), audio: [Synthetic.audioFrame(heAAC, index: 0, pts: audioStart)])
        }
        // The same AAC-LC config (or none) is fine.
        let bare = AudioFormat(codec: .aac, sampleRate: 32_000, channels: 1)
        _ = try muxer.fragment(video: frames(format, count: 2), audio: [Synthetic.audioFrame(bare, index: 0, pts: audioStart), audio(count: 2)[1]])
    }

    // MARK: Parameter sets

    @Test func parameterSetOrderAndDuplicatesAreNotAFormatChange() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        let reordered = VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [Golden.h264PPS, Golden.h264SPS, Golden.h264PPS])
        _ = try muxer.fragment(video: [Synthetic.videoFrame(reordered, index: 0, isKeyframe: true, pts: 0)], audio: [])

        var hevc = try FMP4Muxer(configuration: FMP4Configuration(video: try Golden.hevcFormat, audio: nil))
        let shuffled = VideoFormat(codec: .hevc, width: 640, height: 360, parameterSets: [Golden.hevcPPS, Golden.hevcVPS, Golden.hevcSPS])
        _ = try hevc.fragment(video: [Synthetic.videoFrame(shuffled, index: 0, isKeyframe: true, pts: 0)], audio: [])
    }

    @Test func inBandParameterSetsAndDelimitersAreRemovedFromSamples() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        let idr = Data([0x65, 0x88, 0x84, 0x00])
        let slice = Data([0x41, 0x9A, 0x02])
        let aud = Data([0x09, 0xF0])
        let sei = Data([0x06, 0x05, 0x01, 0x00, 0x80])
        let key = EncodedVideoFrame(format: format, nalUnits: [aud, Golden.h264SPS + Data([0]), Golden.h264PPS, sei, idr, Data([0x0C, 0xFF, 0xFF])],
                                    isKeyframe: true, pts: MediaTime(value: 0, timescale: 90_000), wallClock: Date())
        let delta = EncodedVideoFrame(format: format, nalUnits: [aud, slice, Data([0x0A]), Data([0x0B])], isKeyframe: false,
                                      pts: MediaTime(value: 3_000, timescale: 90_000), wallClock: Date())
        let fragment = try muxer.fragment(video: [key, delta], audio: [])
        let run = try #require(try FragmentRuns(fragment).video)
        #expect(run.run.samples.map(\.size) == [UInt32(8 + sei.count + idr.count), UInt32(4 + slice.count)])
        let expected = EncodedVideoFrame(format: format, nalUnits: [sei, idr], isKeyframe: true, pts: key.pts, wallClock: key.wallClock).lengthPrefixedData
            + EncodedVideoFrame(format: format, nalUnits: [slice], isKeyframe: false, pts: delta.pts, wallClock: delta.wallClock).lengthPrefixedData
        #expect(Bytes(fragment).slice(Int(run.run.dataOffset), expected.count) == expected)
        #expect(muxer.lastFragmentStatistics.removedNALUnits == 7)

        // HEVC: VPS/SPS/PPS (32/33/34), AUD (35), end of sequence/bitstream (36/37) and filler (38) go; SEI (39) stays.
        var hevc = try FMP4Muxer(configuration: FMP4Configuration(video: try Golden.hevcFormat, audio: nil))
        let hevcIDR = Data([0x26, 0x01, 0xAF, 0x00])
        let prefixSEI = Data([0x4E, 0x01, 0x05, 0x01, 0x00, 0x80])
        let hevcKey = EncodedVideoFrame(format: try Golden.hevcFormat,
                                        nalUnits: [Data([0x46, 0x01, 0x50]), Golden.hevcVPS, Golden.hevcSPS, Golden.hevcPPS, prefixSEI, hevcIDR,
                                                   Data([0x48, 0x01]), Data([0x4A, 0x01]), Data([0x4C, 0x01, 0xFF])],
                                        isKeyframe: true, pts: MediaTime(value: 0, timescale: 90_000), wallClock: Date())
        let hevcFragment = try hevc.fragment(video: [hevcKey], audio: [])
        #expect(try FragmentRuns(hevcFragment).video?.run.samples.map(\.size) == [UInt32(8 + prefixSEI.count + hevcIDR.count)])
        #expect(hevc.lastFragmentStatistics.removedNALUnits == 7)
    }

    @Test func inBandParameterSetThatDiffersIsAFormatChange() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        let otherPPS = Data([0x68, 0xEB, 0xC3, 0xCB, 0x22, 0xC1])
        let key = EncodedVideoFrame(format: format, nalUnits: [otherPPS, Data([0x65, 0x88])], isKeyframe: true,
                                    pts: MediaTime(value: 0, timescale: 90_000), wallClock: Date())
        #expect(throws: FMP4Error.videoFormatChanged) { try muxer.fragment(video: [key], audio: []) }
    }

    // MARK: Empty frames

    @Test func framesWithoutNALUnitsAreSkipped() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        func frame(_ nals: [Data], key: Bool = false, pts: Int64) -> EncodedVideoFrame {
            EncodedVideoFrame(format: format, nalUnits: nals, isKeyframe: key, pts: MediaTime(value: pts, timescale: 90_000), wallClock: Date())
        }
        let video = [frame([Data([0x65, 1])], key: true, pts: 0), frame([], pts: 3_000), frame([Data([0x41, 2])], pts: 6_000),
                     frame([Data(), Data([0x09, 0xF0])], pts: 9_000), frame([Data([0x41, 3]), Data()], pts: 12_000)]
        let fragment = try muxer.fragment(video: video, audio: [], nextDecodeTime: MediaTime(value: 15_000, timescale: 90_000))
        let run = try #require(try FragmentRuns(fragment).video)
        #expect(run.run.samples.map(\.duration) == [6_000, 6_000, 3_000])
        #expect(run.run.samples.map(\.size) == [6, 6, 6])
        #expect(muxer.lastFragmentStatistics.skippedVideoFrames == 2)
        #expect(muxer.lastFragmentStatistics.removedNALUnits == 3)

        var fresh = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        #expect(throws: FMP4Error.fragmentMustStartWithKeyframe) {
            try fresh.fragment(video: [frame([], key: true, pts: 0), frame([Data([0x41, 2])], pts: 3_000)], audio: [])
        }
        #expect(throws: FMP4Error.emptyFragment) { try fresh.fragment(video: [frame([Data()], key: true, pts: 0)], audio: []) }
    }
}
