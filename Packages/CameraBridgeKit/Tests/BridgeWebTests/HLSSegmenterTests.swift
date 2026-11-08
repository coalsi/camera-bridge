import BridgeEngine
import Foundation
import Testing
@testable import BridgeWeb

@Suite(.timeLimit(.minutes(1))) struct HLSSegmenterTests {
    private static let mime = #"video/mp4; codecs="hvc1.1.6.L93.B0,mp4a.40.2""#
    private static let frame: Int64 = 3_000 // 30 fps in 90 kHz ticks

    private static func initPart(_ tag: UInt8 = 0) -> LiveMP4Remuxer.Part {
        .initialization(Data([0xAA, tag]), mime: mime, width: 1280, height: 720)
    }

    private static func media(_ key: Bool, bytes: Int = 10) -> LiveMP4Remuxer.Part {
        .media(Data(repeating: key ? 1 : 2, count: bytes), keyframe: key, duration: frame)
    }

    /// Feeds `seconds` of 30 fps video with a key frame every `keyEvery` seconds.
    private static func feed(_ s: inout HLSSegmenter, seconds: Int, keyEvery: Int, bytes: Int = 10) {
        for i in 0..<(seconds * 30) {
            s.add(media(i % (keyEvery * 30) == 0, bytes: bytes))
        }
    }

    @Test func cutsAtTheFirstKeyFrameTwoSecondsIn() {
        var s = HLSSegmenter()
        s.add(Self.initPart())
        Self.feed(&s, seconds: 7, keyEvery: 1)
        s.add(Self.media(true))
        #expect(s.published.count == 3)
        #expect(s.published.allSatisfy { $0.duration == 2.0 })
        #expect(s.published.map(\.number) == [0, 1, 2])
        #expect(s.resolution?.0 == 1280)
        #expect(s.codecs == #"hvc1.1.6.L93.B0,mp4a.40.2"#)
    }

    @Test func neverCutsOffAKeyFrame() {
        var s = HLSSegmenter()
        s.add(Self.initPart())
        Self.feed(&s, seconds: 30, keyEvery: 10)
        s.add(Self.media(true))
        #expect(s.published.map(\.duration) == [10.0, 10.0, 10.0])
        #expect(s.targetDuration == 15)
        // Each segment starts with a key fragment.
        #expect(s.published.allSatisfy { $0.data.first == 1 })
    }

    @Test func targetDurationNeverChanges() {
        var s = HLSSegmenter()
        s.add(Self.initPart())
        Self.feed(&s, seconds: 2, keyEvery: 2)
        Self.feed(&s, seconds: 8, keyEvery: 8)
        s.add(Self.media(true))
        #expect(s.published.last?.duration == 8.0)
        #expect(s.targetDuration == 6)
    }

    @Test func slidesOverSixAndCountsTheSequence() {
        var s = HLSSegmenter()
        s.add(Self.initPart())
        Self.feed(&s, seconds: 18, keyEvery: 2)
        s.add(Self.media(true))
        #expect(s.published.count == 6)
        #expect(s.mediaSequence == 3)
        #expect(s.published.first?.number == 3)
        #expect(s.segment(2) == nil)
        #expect(s.segment(3) != nil)
    }

    @Test func dropsOldestPastTheByteCap() {
        var s = HLSSegmenter(maximumBytes: 1_000)
        s.add(Self.initPart())
        Self.feed(&s, seconds: 8, keyEvery: 2, bytes: 5) // 300 bytes per segment
        s.add(Self.media(true, bytes: 5))
        #expect(s.published.count == 3)
        #expect(s.published.map(\.number) == [1, 2, 3])
        #expect(s.mediaSequence == 1)
    }

    @Test func anInitBeforePublishingReplacesIt() {
        var s = HLSSegmenter()
        s.add(Self.initPart(0xA))
        s.add(Self.media(true))
        s.add(Self.media(false))
        s.add(Self.initPart(0xB))
        Self.feed(&s, seconds: 4, keyEvery: 2)
        s.add(Self.media(true))
        #expect(s.initSegment(0) == Data([0xAA, 0xB]))
        #expect(s.published.count == 2)
        #expect(s.published.allSatisfy { !$0.startsDiscontinuity && $0.initNumber == 0 })
        #expect(s.published.first?.number == 0)
        #expect(s.published.first?.duration == 2.0)
    }

    @Test func anInitAfterPublishingIsADiscontinuity() {
        var s = HLSSegmenter()
        s.add(Self.initPart(1))
        Self.feed(&s, seconds: 4, keyEvery: 2)
        s.add(Self.media(true)) // publishes two; a started third is dropped by the new init
        s.add(Self.initPart(2))
        Self.feed(&s, seconds: 4, keyEvery: 2)
        s.add(Self.media(true))
        let all = s.published
        #expect(all.map(\.number) == [0, 1, 2, 3])
        #expect(all.map(\.initNumber) == [0, 0, 1, 1])
        #expect(all.map(\.startsDiscontinuity) == [false, false, true, false])
        #expect(s.initSegment(1) == Data([0xAA, 2]))
        #expect(s.discontinuitySequence == 0)
        // Slide the discontinuity out.
        Self.feed(&s, seconds: 12, keyEvery: 2)
        s.add(Self.media(true))
        #expect(s.published.first?.number == 4)
        #expect(s.discontinuitySequence == 1)
        #expect(s.initSegment(0) == nil)
        #expect(s.initSegment(1) != nil)
    }

    private static func segmenter(seconds: Int, keyEvery: Int) -> HLSSegmenter {
        var s = HLSSegmenter()
        s.add(initPart())
        feed(&s, seconds: seconds, keyEvery: keyEvery)
        s.add(media(true))
        return s
    }

    /// AVPlayer starts on the first segment it is given, and a new segment can take two and a half segments' length to reach it (`hasFirstSegments`).
    /// On two it froze: five cold starts of six at 2 s, every one at 4 s and 10 s. Measured on the demo camera at each of these key intervals.
    @Test(arguments: [2, 3, 4, 10])
    func aPlayerStartsOnThreeSegments(keyEvery: Int) {
        let two = Self.segmenter(seconds: keyEvery * 2, keyEvery: keyEvery)
        #expect(two.published.count == 2 && !two.hasFirstSegments)
        #expect(HLSPlaylist.live(two) == nil)
        let three = Self.segmenter(seconds: keyEvery * 3, keyEvery: keyEvery)
        #expect(three.published.count == 3 && three.hasFirstSegments)
        #expect(HLSPlaylist.live(three) != nil)
    }

    @Test func bandwidthIsThePeakBitsPerSecond() {
        var s = HLSSegmenter()
        s.add(Self.initPart())
        Self.feed(&s, seconds: 2, keyEvery: 2, bytes: 10) // 600 bytes in 2 s
        Self.feed(&s, seconds: 2, keyEvery: 2, bytes: 20) // 1200 bytes in 2 s
        s.add(Self.media(true))
        #expect(s.bandwidth == 4_800)
    }

    @Test func theOpenSegmentCountsAgainstTheCap() {
        var s = HLSSegmenter(maximumBytes: 1_000)
        s.add(Self.initPart())
        Self.feed(&s, seconds: 6, keyEvery: 2, bytes: 5) // 300 bytes per segment
        s.add(Self.media(true, bytes: 5))
        #expect(s.published.map(\.number) == [0, 1, 2])
        for _ in 0..<20 { s.add(Self.media(false, bytes: 5)) } // open grows to 105: 1005 in all
        #expect(s.published.map(\.number) == [1, 2])
    }

    @Test func anOpenSegmentPastTheCapIsDroppedAndResyncsAtAKeyFrame() {
        var s = HLSSegmenter(maximumBytes: 1_000)
        s.add(Self.initPart())
        Self.feed(&s, seconds: 4, keyEvery: 2, bytes: 5)
        s.add(Self.media(true, bytes: 5))
        #expect(s.published.count == 2)
        for _ in 0..<3 { s.add(Self.media(false, bytes: 400)) } // the open segment alone passes the cap
        s.add(Self.media(false, bytes: 5)) // ignored: waiting for a key frame
        #expect(s.published.last?.number == 1)
        Self.feed(&s, seconds: 4, keyEvery: 2, bytes: 5)
        s.add(Self.media(true, bytes: 5))
        let resumed = s.published.filter { $0.number >= 2 }
        #expect(resumed.count >= 1)
        #expect(resumed.first?.startsDiscontinuity == true)
        #expect(resumed.dropFirst().allSatisfy { !$0.startsDiscontinuity })
        #expect(resumed.allSatisfy { $0.initNumber == 0 && $0.data.first == 1 })
    }
}
