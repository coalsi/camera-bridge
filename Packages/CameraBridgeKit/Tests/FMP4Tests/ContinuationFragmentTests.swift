import Foundation
import MediaCore
import Testing
@testable import FMP4

/// `FMP4Muxer.fragment(video:audio:nextDecodeTime:continuation:)`: the second and later pieces of a long group of pictures.
@Suite struct ContinuationFragmentTests {
    static func frames(_ range: Range<Int>, keyframeAt keyIndex: Int?, format: VideoFormat) -> [EncodedVideoFrame] {
        range.map { Synthetic.videoFrame(format, index: $0, isKeyframe: $0 == keyIndex, pts: Int64($0) * 3_000) }
    }

    @Test func aContinuationFragmentStartsOnADeltaFrameAndChainsTheTimes() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        let first = try muxer.fragment(video: Self.frames(0..<3, keyframeAt: 0, format: format), audio: [], nextDecodeTime: MediaTime(value: 9_000, timescale: 90_000),
                                       continuation: false)
        let second = try muxer.fragment(video: Self.frames(3..<6, keyframeAt: nil, format: format), audio: [], nextDecodeTime: MediaTime(value: 18_000, timescale: 90_000),
                                        continuation: true)
        let firstRuns = try FragmentRuns(first), secondRuns = try FragmentRuns(second)
        let firstVideo = try #require(firstRuns.video), secondVideo = try #require(secondRuns.video)
        #expect(firstVideo.decodeTime == 0 && secondVideo.decodeTime == 9_000, "tfdt continues where the first fragment's durations end")
        #expect(firstVideo.run.samples.first?.flags == FMP4Muxer.keyframeSampleFlags)
        #expect(secondVideo.run.samples.allSatisfy { $0.flags == FMP4Muxer.deltaSampleFlags }, "no sample of the continuation is a sync sample")
        #expect(secondRuns.sequenceNumber == firstRuns.sequenceNumber + 1)
    }

    @Test func withoutTheFlagADeltaFirstFragmentStillThrows() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        _ = try muxer.fragment(video: Self.frames(0..<3, keyframeAt: 0, format: format), audio: [])
        #expect(throws: FMP4Error.fragmentMustStartWithKeyframe) { _ = try muxer.fragment(video: Self.frames(3..<6, keyframeAt: nil, format: format), audio: []) }
        #expect(throws: FMP4Error.fragmentMustStartWithKeyframe) {
            _ = try muxer.fragment(video: Self.frames(3..<6, keyframeAt: nil, format: format), audio: [], nextDecodeTime: nil, continuation: false)
        }
    }

    @Test func theFirstFragmentOfAMuxerMustStillStartWithAKeyframe() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        #expect(throws: FMP4Error.fragmentMustStartWithKeyframe) {
            _ = try muxer.fragment(video: Self.frames(3..<6, keyframeAt: nil, format: format), audio: [], nextDecodeTime: nil, continuation: true)
        }
        _ = try muxer.fragment(video: Self.frames(0..<3, keyframeAt: 0, format: format), audio: [], nextDecodeTime: nil, continuation: true)   // a keyframe is fine
    }

    @Test func aContinuationMustStillMoveForwardInTime() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        _ = try muxer.fragment(video: Self.frames(0..<3, keyframeAt: 0, format: format), audio: [])
        #expect(throws: FMP4Error.self) {
            _ = try muxer.fragment(video: Self.frames(1..<3, keyframeAt: nil, format: format), audio: [], nextDecodeTime: nil, continuation: true)
        }
    }
}
