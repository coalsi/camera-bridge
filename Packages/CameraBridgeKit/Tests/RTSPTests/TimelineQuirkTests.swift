import BridgeSupport
import Foundation
import Testing
@testable import RTSP

/// RTP video timestamps that are not a clean presentation clock (a Tapo's): keyframes stamped ahead, repeated stamps.
@Suite struct TimelineQuirkTests {
    static let interval: Int64 = 4_500   // 20 fps
    static let start = Date(timeIntervalSince1970: 1000)

    /// A Tapo stamps each IDR about seven pictures ahead of its own P pictures' clock: the first P steps back, and the next
    /// IDR would put the timeline further ahead, by the same amount, for ever. The smoother learns it and places each IDR one
    /// interval after the picture before it.
    @Test func keyframesStampedAheadDoNotAccumulate() {
        var smoother = TimestampSmoother(clockRate: 90_000)
        var out: [Int64] = []
        for i in 0..<200 {
            let keyframe = i % 20 == 0
            let raw = 1_000_000 + Int64(i) * Self.interval + (keyframe ? 7 * Self.interval : 0)
            out.append(smoother.smooth(raw, arrival: Self.start + Double(i) / 20, isKeyframe: keyframe))
        }
        #expect(smoother.keyframesRunAhead)
        #expect(zip(out.dropFirst(), out).allSatisfy { $0 - $1 == Self.interval }, "every step is one interval, keyframes included")
        #expect(out.last == 199 * Self.interval)
    }

    /// A camera whose keyframes are on its clock keeps them: nothing is re-timed.
    @Test func keyframesOnTheClockAreLeftAlone() {
        var smoother = TimestampSmoother(clockRate: 90_000)
        var out: [Int64] = []
        for i in 0..<60 {
            let raw = Int64(i) * Self.interval + (i % 20 == 0 && i > 0 ? 400 : 0)   // a keyframe a little late, as encoders are
            out.append(smoother.smooth(raw, arrival: Self.start + Double(i) / 20, isKeyframe: i % 20 == 0))
        }
        #expect(!smoother.keyframesRunAhead)
        #expect(smoother.retimedCount == 0)
        #expect(out[20] == 20 * Self.interval + 400)
    }

    /// Two pictures stamped alike, the next one catching up: the repeat gets a full interval, and the catch-up gives it back,
    /// so the timeline keeps the camera's pace instead of gaining an interval at every repeat.
    @Test func repeatedTimestampsAreGivenBackByTheCatchUp() {
        var smoother = TimestampSmoother(clockRate: 90_000)
        var out: [Int64] = []
        for i in 0..<100 {
            // Every 5th picture repeats its predecessor's stamp; the one after it jumps two intervals.
            let raw = Int64(i) * Self.interval - (i % 5 == 4 ? Self.interval : 0)
            out.append(smoother.smooth(raw, arrival: Self.start + Double(i) / 20))
        }
        #expect(zip(out.dropFirst(), out).allSatisfy { $0 > $1 })
        #expect(abs(out[99] - 99 * Self.interval) <= Self.interval, "off by \(out[99] - 99 * Self.interval) ticks after 100 pictures")
    }
}

@Suite struct DecodeTimelineClosedGOPTests {
    static let frame: Int64 = 3_600

    /// An IDR starts a closed GOP: no later picture is presented before it, so units stamped behind it are mis-stamped (a
    /// Tapo's IDR runs ahead of the pictures after it), not reordered: no reordering is learned and no decode time is made up.
    @Test func unitsBehindAnIDRAreNotReordering() {
        var timeline = DecodeTimeline(clockRate: 90_000)
        let f = Self.frame
        var decode: [Int64] = [timeline.decodeTime(pts: 10 * f, isKeyframe: true, startsClosedGOP: true)]
        for i in 3..<9 { decode.append(timeline.decodeTime(pts: Int64(i) * f, isKeyframe: false)) }   // behind the IDR
        for i in 11..<14 { decode.append(timeline.decodeTime(pts: Int64(i) * f, isKeyframe: false)) }
        #expect(decode == [10 * f] + (3..<9).map { Int64($0) * f } + (11..<14).map { Int64($0) * f })
        #expect(timeline.reorderDepth == 0)
    }

    /// The same steps back behind a keyframe that may have leading pictures (CRA, BLA) are reordering.
    @Test func leadingPicturesOfAnOpenGOPAreStillReordering() {
        var timeline = DecodeTimeline(clockRate: 90_000)
        let f = Self.frame
        _ = timeline.decodeTime(pts: 10 * f, isKeyframe: true, startsClosedGOP: false)
        _ = timeline.decodeTime(pts: 8 * f, isKeyframe: false)
        _ = timeline.decodeTime(pts: 9 * f, isKeyframe: false)
        #expect(timeline.reorderDepth >= 1)
    }
}
