import Foundation
import MediaCore
import Testing
@testable import FMP4

@Suite struct FragmentTests {
    private let aac = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
    /// Source timeline far from zero, to prove the rebasing.
    private let videoStart: Int64 = 90_000 * 1_000
    private var audioStart: Int64 { 32_000 * 1_000 }

    private func frames(_ format: VideoFormat, count: Int, from index: Int = 0, keyframeEvery: Int = 1_000) -> [EncodedVideoFrame] {
        (index..<index + count).map { i in
            Synthetic.videoFrame(format, index: i, isKeyframe: i % keyframeEvery == 0, pts: videoStart + Int64(i) * 3_000,
                                 nalSizes: [10 + i, 20], wallClock: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) / 30))
        }
    }

    private func audio(count: Int, from index: Int = 0) -> [EncodedAudioFrame] {
        (index..<index + count).map { Synthetic.audioFrame(aac, index: $0, pts: audioStart + Int64($0) * 1_024, size: 6 + $0 % 5) }
    }

    @Test func moofLayoutWithOneTrunPerTraf() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac))
        let video = frames(format, count: 3)
        let sound = audio(count: 4)
        let fragment = try muxer.fragment(video: video, audio: sound)
        let boxes = try MP4BoxReader.parse(fragment)
        #expect(boxes.map(\.type) == ["moof", "mdat"])
        let moof = boxes[0]
        #expect(moof.children.map(\.type) == ["mfhd", "traf", "traf"])
        #expect(Bytes(try #require(moof.child("mfhd")).payload(in: fragment)).u32(4) == 1)
        for traf in moof.children(ofType: "traf") {
            #expect(traf.children.map(\.type) == ["tfhd", "tfdt", "trun"])
        }
        #expect(boxes[1].offset + boxes[1].size == fragment.count)
    }

    @Test func videoTrafFields() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac))
        let video = frames(format, count: 3)
        let fragment = try muxer.fragment(video: video, audio: audio(count: 2))
        let boxes = try MP4BoxReader.parse(fragment)
        let traf = try #require(boxes[0].children(ofType: "traf").first)

        let tfhd = try #require(traf.child("tfhd"))
        #expect(tfhd.fullBoxHeader(in: fragment) == (0, 0x02_0000))    // default-base-is-moof only
        #expect(tfhd.size == 16)
        #expect(Bytes(tfhd.payload(in: fragment)).u32(4) == 1)

        let tfdt = try #require(traf.child("tfdt"))
        #expect(tfdt.fullBoxHeader(in: fragment) == (1, 0))
        #expect(Bytes(tfdt.payload(in: fragment)).u64(4) == 0)          // rebased

        let trun = try TrackRun(try #require(traf.child("trun")), in: fragment)
        #expect(trun.version == 0)
        #expect(trun.flags == 0x00_0701)                                // data offset, duration, size, flags
        #expect(Int(trun.dataOffset) == boxes[0].size + 8)
        #expect(trun.samples.map(\.duration) == [3_000, 3_000, 3_000])  // last one: previous frame's duration
        #expect(trun.samples.map(\.flags) == [0x0200_0000, 0x0101_0000, 0x0101_0000])
        #expect(trun.samples.map { Int($0.size) } == video.map { $0.lengthPrefixedData.count })

        // mdat: length-prefixed NALs of every video frame, in order, at the data offset.
        let expected = video.reduce(into: Data()) { $0.append($1.lengthPrefixedData) }
        #expect(Bytes(fragment).slice(Int(trun.dataOffset), expected.count) == expected)
    }

    @Test func audioTrafFollowsVideoInMdat() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac))
        let video = frames(format, count: 3)
        let sound = audio(count: 4)
        let fragment = try muxer.fragment(video: video, audio: sound)
        let boxes = try MP4BoxReader.parse(fragment)
        let trafs = boxes[0].children(ofType: "traf")
        let videoRun = try TrackRun(try #require(trafs[0].child("trun")), in: fragment)
        let audioTraf = trafs[1]

        let tfhd = try #require(audioTraf.child("tfhd"))
        #expect(tfhd.fullBoxHeader(in: fragment) == (0, 0x02_0000))
        #expect(Bytes(tfhd.payload(in: fragment)).u32(4) == 2)
        #expect(Bytes(try #require(audioTraf.child("tfdt")).payload(in: fragment)).u64(4) == 0)

        let run = try TrackRun(try #require(audioTraf.child("trun")), in: fragment)
        #expect(run.flags == 0x00_0701)
        #expect(run.samples.map(\.duration) == [1_024, 1_024, 1_024, 1_024])
        #expect(run.samples.map(\.flags) == Array(repeating: 0x0200_0000, count: 4))
        #expect(run.samples.map { Int($0.size) } == sound.map(\.data.count))
        let videoBytes = videoRun.samples.reduce(0) { $0 + Int($1.size) }
        #expect(Int(run.dataOffset) == Int(videoRun.dataOffset) + videoBytes)
        let expected = sound.reduce(into: Data()) { $0.append($1.data) }
        #expect(Bytes(fragment).slice(Int(run.dataOffset), expected.count) == expected)
        let mdat = boxes[1]
        #expect(mdat.size == 8 + videoBytes + expected.count)
    }

    @Test func tfdtIsRebasedAndContinuousAcrossFragments() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac))
        _ = try muxer.fragment(video: frames(format, count: 30), audio: audio(count: 30))
        let second = try muxer.fragment(video: frames(format, count: 30, from: 30, keyframeEvery: 30), audio: audio(count: 30, from: 30))
        let boxes = try MP4BoxReader.parse(second)
        #expect(Bytes(try #require(boxes[0].child("mfhd")).payload(in: second)).u32(4) == 2)
        let trafs = boxes[0].children(ofType: "traf")
        #expect(Bytes(try #require(trafs[0].child("tfdt")).payload(in: second)).u64(4) == 90_000)
        #expect(Bytes(try #require(trafs[1].child("tfdt")).payload(in: second)).u64(4) == 30 * 1_024)
    }

    @Test func audioKeepsItsOffsetFromTheFirstVideoFrame() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac))
        // Audio starts 100 ms after the video; one frame starts before the video and is dropped.
        let early = Synthetic.audioFrame(aac, index: 0, pts: audioStart - 1_024)
        let late = [Synthetic.audioFrame(aac, index: 1, pts: audioStart + 3_200), Synthetic.audioFrame(aac, index: 2, pts: audioStart + 4_224)]
        let fragment = try muxer.fragment(video: frames(format, count: 5), audio: [early] + late)
        let trafs = try MP4BoxReader.parse(fragment)[0].children(ofType: "traf")
        #expect(Bytes(try #require(trafs[1].child("tfdt")).payload(in: fragment)).u64(4) == 3_200)
        #expect(try TrackRun(try #require(trafs[1].child("trun")), in: fragment).samples.count == 2)
    }

    @Test func audioTrafIsOmittedWithoutAudioSamples() throws {
        let format = try Golden.h264Format
        var withAudioTrack = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac))
        let fragment = try withAudioTrack.fragment(video: frames(format, count: 2), audio: [])
        #expect(try MP4BoxReader.parse(fragment)[0].children.map(\.type) == ["mfhd", "traf"])

        // No audio track configured: audio frames are ignored.
        var videoOnly = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        let ignored = try videoOnly.fragment(video: frames(format, count: 2), audio: audio(count: 3))
        let boxes = try MP4BoxReader.parse(ignored)
        #expect(boxes[0].children.map(\.type) == ["mfhd", "traf"])
        let run = try TrackRun(try #require(boxes[0].descendant(atPath: "traf/trun")), in: ignored)
        #expect(boxes[1].size == 8 + run.samples.reduce(0) { $0 + Int($1.size) })
    }

    @Test func compositionOffsetsWhenDTSDiffersFromPTS() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        // Decode order I P B with pts 0, 9000, 3000 (dts 0, 3000, 6000) shifted by one frame.
        let video = [
            Synthetic.videoFrame(format, index: 0, isKeyframe: true, pts: 3_000, dts: 0),
            Synthetic.videoFrame(format, index: 1, isKeyframe: false, pts: 12_000, dts: 3_000),
            Synthetic.videoFrame(format, index: 2, isKeyframe: false, pts: 6_000, dts: 6_000),
        ]
        let fragment = try muxer.fragment(video: video, audio: [])
        let run = try TrackRun(try #require(try MP4BoxReader.parse(fragment)[0].descendant(atPath: "traf/trun")), in: fragment)
        #expect(run.flags == 0x00_0F01)
        #expect(run.samples.map(\.compositionOffset) == [3_000, 9_000, 0])
        #expect(run.samples.map(\.duration) == [3_000, 3_000, 3_000])
    }

    @Test func producerReferenceTimeBeforeEachMoof() throws {
        let format = try Golden.hevcFormat
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil, writeProducerReferenceTime: true))
        _ = try muxer.fragment(video: frames(format, count: 30), audio: [])
        let fragment = try muxer.fragment(video: frames(format, count: 30, from: 30, keyframeEvery: 30), audio: [])
        let boxes = try MP4BoxReader.parse(fragment)
        #expect(boxes.map(\.type) == ["prft", "moof", "mdat"])
        let prft = boxes[0]
        #expect(prft.size == 32)
        #expect(prft.fullBoxHeader(in: fragment) == (1, 0))                 // version 1, flags MUST be 0
        let bytes = Bytes(prft.payload(in: fragment))
        #expect(bytes.u32(4) == 1)                                          // reference_track_ID = video
        // NTP time of the first frame's wall clock: 1_800_000_001 s Unix + 2_208_988_800.
        #expect(bytes.u64(8) >> 32 == 1_800_000_001 + 2_208_988_800)
        #expect(bytes.u64(8) & 0xFFFF_FFFF == 0)
        #expect(bytes.u64(16) == 90_000)                                    // media_time = video tfdt
        let trun = try TrackRun(try #require(boxes[1].descendant(atPath: "traf/trun")), in: fragment)
        #expect(Int(trun.dataOffset) == boxes[1].size + 8)                  // offsets stay relative to moof
    }

    @Test func rejectsInvalidFragments() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac))
        #expect(throws: FMP4Error.emptyFragment) { try muxer.fragment(video: [], audio: audio(count: 2)) }
        #expect(throws: FMP4Error.fragmentMustStartWithKeyframe) {
            try muxer.fragment(video: frames(format, count: 3, from: 1), audio: [])
        }
        let backwards = [frames(format, count: 1)[0], Synthetic.videoFrame(format, index: 1, isKeyframe: false, pts: videoStart - 3_000)]
        #expect(throws: FMP4Error.self) { try muxer.fragment(video: backwards, audio: []) }
        let hevc = try Golden.hevcFormat
        #expect(throws: FMP4Error.videoFormatChanged) {
            try muxer.fragment(video: [Synthetic.videoFrame(hevc, index: 0, isKeyframe: true, pts: videoStart)], audio: [])
        }
        let otherSPS = VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [Golden.h264SPS + Data([0x01]), Golden.h264PPS])
        #expect(throws: FMP4Error.videoFormatChanged) {
            try muxer.fragment(video: [Synthetic.videoFrame(otherSPS, index: 0, isKeyframe: true, pts: videoStart)], audio: [])
        }
        let pcmu = AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1)
        #expect(throws: FMP4Error.audioFormatChanged) {
            try muxer.fragment(video: frames(format, count: 1), audio: [Synthetic.audioFrame(pcmu, index: 0, pts: 8_000 * 1_000)])
        }
        // Failed calls leave the muxer untouched: the next fragment is still sequence 1 at time 0.
        let fragment = try muxer.fragment(video: frames(format, count: 2), audio: [])
        let moof = try MP4BoxReader.parse(fragment)[0]
        #expect(Bytes(try #require(moof.child("mfhd")).payload(in: fragment)).u32(4) == 1)
        #expect(Bytes(try #require(moof.descendant(atPath: "traf/tfdt")).payload(in: fragment)).u64(4) == 0)
        // A later fragment may not start at or before a sample already written.
        #expect(throws: FMP4Error.self) { try muxer.fragment(video: frames(format, count: 2), audio: []) }
    }

    @Test func parameterSetsWithTrailingZerosAreTheSameFormat() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        let padded = VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [Golden.h264SPS + Data([0, 0]), Golden.h264PPS])
        _ = try muxer.fragment(video: [Synthetic.videoFrame(padded, index: 0, isKeyframe: true, pts: 0)], audio: [])
    }

    @Test func singleFrameFragmentsReuseTheLastKnownDuration() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        _ = try muxer.fragment(video: [Synthetic.videoFrame(format, index: 0, isKeyframe: true, pts: 0),
                                       Synthetic.videoFrame(format, index: 1, isKeyframe: false, pts: 3_750)], audio: [])
        let fragment = try muxer.fragment(video: [Synthetic.videoFrame(format, index: 2, isKeyframe: true, pts: 7_500)], audio: [])
        let run = try TrackRun(try #require(try MP4BoxReader.parse(fragment)[0].descendant(atPath: "traf/trun")), in: fragment)
        #expect(run.samples.map(\.duration) == [3_750])
    }

    @Test func customVideoTimescale() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil, videoTimescale: 30_000))
        let segment = muxer.initializationSegment()
        let mdhd = try #require(MP4BoxReader.box(atPath: "moov/trak/mdia/mdhd", in: try MP4BoxReader.parse(segment)))
        #expect(Bytes(mdhd.payload(in: segment)).u32(12) == 30_000)
        let fragment = try muxer.fragment(video: frames(format, count: 3), audio: [])
        let run = try TrackRun(try #require(try MP4BoxReader.parse(fragment)[0].descendant(atPath: "traf/trun")), in: fragment)
        #expect(run.samples.map(\.duration) == [1_000, 1_000, 1_000])
    }
}
