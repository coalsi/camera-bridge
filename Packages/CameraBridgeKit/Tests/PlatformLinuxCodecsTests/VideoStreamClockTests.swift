import Foundation
import MediaCore
import Testing
@testable import PlatformLinux

@Suite struct VideoStreamClockTests {
    private func reading(_ data: Data) -> [FLVTag] {
        var reader = FLVReader()
        return reader.push(FLVWriter.fileHeader(video: true, audio: false) + data)
    }

    @Test func headerHasTheFileHeaderAndTheSequenceHeader() throws {
        let stream = VideoFLVStream(format: TestFormats.h264)
        let header = try #require(stream.header)
        var reader = FLVReader()
        let tags = reader.push(header)
        #expect(tags.count == 1)
        guard case .sequenceHeader? = FLVAVCPacket.parse(tags[0]) else { Issue.record("no sequence header"); return }
    }

    @Test func ordinaryPicturesGetEvenMillisecondsKeyframeRequestsOdd() {
        var stream = VideoFLVStream(format: TestFormats.h264)
        var milliseconds: [Int64] = []
        for index in 0..<12 {
            let (_, ptsMs) = stream.tag(for: TestFormats.frame(index, key: index == 0), requestKeyframe: index == 5)
            milliseconds.append(ptsMs)
        }
        for (index, ms) in milliseconds.enumerated() { #expect((ms & 1 == 1) == (index == 5), "picture \(index) at \(ms) ms") }
        // The first picture sits at the margin, later ones follow the 40 ms spacing to within the parity adjustment.
        #expect(milliseconds[0] == VideoFLVStream.margin)
        for (index, ms) in milliseconds.enumerated() { #expect(abs(ms - (VideoFLVStream.margin + Int64(index) * 40)) <= 2) }
    }

    @Test func decodeTimesIncreaseStrictlyEvenForPicturesCloserThanAMillisecond() throws {
        var stream = VideoFLVStream(format: TestFormats.h264)
        var last: UInt32 = 0
        for index in 0..<20 {
            var frame = TestFormats.frame(index, key: index == 0)
            frame.pts = MediaTime(value: 90_000 + Int64(index) * 10, timescale: 90_000)   // 0.11 ms apart
            let (data, _) = stream.tag(for: frame, requestKeyframe: false)
            let tag = try #require(reading(data).first)
            #expect(index == 0 || tag.timestamp > last)
            last = tag.timestamp
        }
    }

    @Test func bFramesKeepTheirCompositionOffset() throws {
        var stream = VideoFLVStream(format: TestFormats.h264)
        // Decode order I P B: pts 0, 120, 40 ms; dts 0, 40, 80 ms? Use dts 0, 40, 80 and pts 80, 200, 120 (a 2-frame delay).
        let spec: [(pts: Int64, dts: Int64)] = [(80, 0), (200, 40), (120, 80)]
        var assigned: [(dts: UInt32, composition: Int32)] = []
        for (index, entry) in spec.enumerated() {
            var frame = TestFormats.frame(index, key: index == 0)
            frame.pts = MediaTime(value: entry.pts * 90, timescale: 90_000)
            frame.dts = MediaTime(value: entry.dts * 90, timescale: 90_000)
            let (data, _) = stream.tag(for: frame, requestKeyframe: false)
            let tag = try #require(reading(data).first)
            guard case .frame(_, let composition, _)? = FLVAVCPacket.parse(tag) else { Issue.record("no frame"); return }
            assigned.append((tag.timestamp, composition))
        }
        #expect(assigned.map(\.dts) == [2_000, 2_040, 2_080])
        #expect(assigned.map { Int64($0.dts) + Int64($0.composition) } == [2_080, 2_200, 2_120])
        #expect(assigned.allSatisfy { $0.composition >= 0 })
    }

    @Test func claimReturnsTheExactTimesAndForgetsSkippedPictures() {
        var stream = VideoFLVStream(format: TestFormats.h264)
        var milliseconds: [Int64] = []
        for index in 0..<4 {
            milliseconds.append(stream.tag(for: TestFormats.frame(index, key: index == 0), requestKeyframe: false).ptsMs)
        }
        let record = stream.claim(ptsMs: milliseconds[2])
        #expect(record?.pts == TestFormats.frame(2, key: false).pts)
        #expect(record?.wallClock == TestFormats.frame(2, key: false).wallClock)
        #expect(stream.claim(ptsMs: milliseconds[2]) == nil)   // only once
        #expect(stream.claim(ptsMs: 99_999) == nil)
        #expect(stream.fallbackTime(ptsMs: VideoFLVStream.margin + 400) == MediaTime(value: 36_000, timescale: 90_000))
    }

    @Test func timestampsAreRebasedOntoTheMargin() throws {
        var stream = VideoFLVStream(format: TestFormats.h264)
        var frame = TestFormats.frame(0, key: true)
        frame.pts = MediaTime(value: 3_000_000_000, timescale: 90_000)   // a long-running source
        let (data, ms) = stream.tag(for: frame, requestKeyframe: false)
        #expect(ms == VideoFLVStream.margin)
        let tag = try #require(reading(data).first)
        #expect(tag.timestamp == UInt32(VideoFLVStream.margin))
    }

    @Test func roundingIsToNearestMillisecond() {
        #expect(VideoFLVStream.rounded(89) == 1)
        #expect(VideoFLVStream.rounded(44) == 0)
        #expect(VideoFLVStream.rounded(45) == 1)
        #expect(VideoFLVStream.rounded(-44) == 0)
        #expect(VideoFLVStream.rounded(-46) == -1)
        #expect(VideoFLVStream.rounded(-90) == -1)
    }

    @Test func parameterSetsTravelInBandWhenTheyChange() throws {
        var stream = VideoFLVStream(format: TestFormats.h264)
        func nals(_ frame: EncodedVideoFrame) throws -> [Data] {
            let (data, _) = stream.tag(for: frame, requestKeyframe: false)
            let tag = try #require(reading(data).first)
            guard case .frame(_, _, let units)? = FLVAVCPacket.parse(tag) else { throw TestFailure("no frame") }
            return units
        }
        // A delta frame with the sets the sequence header holds carries slices only; a keyframe adds the sets.
        #expect(try nals(TestFormats.frame(0, key: false)).count == 1)
        #expect(try nals(TestFormats.frame(1, key: true)).count == 3)
        // A second PPS arrives with a delta frame: it goes in front once, then the new sets are the known ones.
        let further = VideoFormat(codec: .h264, width: TestFormats.h264.width, height: TestFormats.h264.height,
                                  parameterSets: TestFormats.h264.parameterSets + [Data([0x68, 0xCE, 0x31, 0x53])])
        #expect(try nals(TestFormats.frame(2, key: false, format: further)).count == 4)
        #expect(try nals(TestFormats.frame(3, key: false, format: further)).count == 1)
        // A keyframe whose PPS changed carries its own sets, not the stream's first ones.
        let changed = VideoFormat(codec: .h264, width: TestFormats.h264.width, height: TestFormats.h264.height, parameterSets: [TestFormats.sps, Data([0x68, 0xAA, 0xBB])])
        let units = try nals(TestFormats.frame(4, key: true, format: changed))
        #expect(units.count == 3 && units[1] == Data([0x68, 0xAA, 0xBB]))
    }

    @Test func outputReaderTurnsFLVIntoFramesWithoutSideData() throws {
        let format = TestFormats.h264
        let fake = FakeEncoderOutput(format: format)
        var output = H264FLVOutput(width: 320, height: 180)
        // An SEI and an AUD in the access unit are dropped; the slice stays.
        let withSEI = FLVWriter.videoFrame(format: format, nalUnits: [Data([0x09, 0xF0]), Data([0x06, 5, 5]), Data([0x65, 1, 2, 3])], isKeyframe: true, dtsMs: 2_000,
                                           ptsMs: 2_000, inBandParameterSets: true)
        let packets = output.push(fake.header() + withSEI + fake.frame(ptsMs: 2_040, keyframe: false))
        #expect(output.format?.width == format.width)
        #expect(packets.count == 2)
        #expect(packets[0].ptsMs == 2_000 && packets[0].isKeyframe && packets[0].nalUnits == [Data([0x65, 1, 2, 3])])
        #expect(packets[1].ptsMs == 2_040 && !packets[1].isKeyframe)
    }
}
