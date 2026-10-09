import BridgeSupport
import Foundation
import Testing
@testable import RTSP

@Suite struct TimelineTests {
    @Test func unwrapperExtendsAcrossWrap() {
        var unwrapper = RTPTimestampUnwrapper()
        #expect(unwrapper.unwrap(UInt32.max - 1000) == Int64(UInt32.max) - 1000)
        #expect(unwrapper.unwrap(500) == Int64(UInt32.max) + 501)
        #expect(unwrapper.unwrap(400) == Int64(UInt32.max) + 401)     // small step back stays in the same era
        #expect(unwrapper.unwrap(UInt32.max / 2) == Int64(UInt32.max) + 1 + Int64(UInt32.max / 2))
    }

    @Test func regularTimestampsArePreserved() {
        var smoother = TimestampSmoother(clockRate: 90_000)
        let start = Date(timeIntervalSince1970: 1000)
        var out: [Int64] = []
        for i in 0..<10 {
            out.append(smoother.smooth(Int64(1_000_000 + i * 3000), arrival: start + Double(i) / 30))
        }
        #expect(out == (0..<10).map { Int64($0 * 3000) })
        #expect(smoother.retimedCount == 0)
    }

    @Test func burstyArrivalKeepsSourceTimestamps() {
        // A cached GOP delivered all at once must keep its spacing.
        var smoother = TimestampSmoother(clockRate: 90_000)
        let start = Date(timeIntervalSince1970: 1000)
        let out = (0..<60).map { smoother.smooth(Int64($0 * 3000), arrival: start) }
        #expect(out == (0..<60).map { Int64($0 * 3000) })
    }

    @Test func lowFrameRateBurstKeepsSpacing() {
        // A 1 fps sub stream whose cached frames arrive together.
        var smoother = TimestampSmoother(clockRate: 90_000)
        let start = Date(timeIntervalSince1970: 1000)
        let out = (0..<5).map { smoother.smooth(Int64($0 * 90_000), arrival: start + Double($0) * 0.001) }
        #expect(out == (0..<5).map { Int64($0 * 90_000) })
        #expect(smoother.retimedCount == 0)
    }

    @Test func bogusForwardJumpIsRetimed() {
        // Reolink-style: the RTP clock jumps ~1.6 s after a keyframe while packets keep arriving at 30 fps.
        var smoother = TimestampSmoother(clockRate: 90_000)
        let start = Date(timeIntervalSince1970: 1000)
        var raw: Int64 = 0
        var out: [Int64] = []
        for i in 0..<20 {
            raw += i == 10 ? 3000 + 144_000 : (i == 0 ? 0 : 3000)
            out.append(smoother.smooth(raw, arrival: start + Double(i) / 30))
        }
        let deltas = zip(out.dropFirst(), out).map { $0 - $1 }
        #expect(deltas.allSatisfy { $0 == 3000 })
        #expect(smoother.retimedCount == 1)
    }

    @Test func realGapIsPreserved() {
        // The camera really paused: the arrival clock shows the same gap.
        var smoother = TimestampSmoother(clockRate: 90_000)
        let start = Date(timeIntervalSince1970: 1000)
        _ = smoother.smooth(0, arrival: start)
        _ = smoother.smooth(3000, arrival: start + 1.0 / 30)
        let afterGap = smoother.smooth(3000 + 5 * 90_000, arrival: start + 1.0 / 30 + 5)
        #expect(afterGap == 3000 + 5 * 90_000)
        #expect(smoother.retimedCount == 0)
    }

    @Test func backwardsAndRepeatedTimestampsStayMonotonic() {
        var smoother = TimestampSmoother(clockRate: 8000)
        let start = Date(timeIntervalSince1970: 1000)
        var out: [Int64] = []
        let raw: [Int64] = [0, 160, 320, 320, 100, 260, 420]
        for (i, value) in raw.enumerated() {
            out.append(smoother.smooth(value, arrival: start + Double(i) * 0.02))
        }
        #expect(zip(out.dropFirst(), out).allSatisfy { $0 > $1 })
        #expect(out[3] == 480)       // repeated timestamp → typical spacing
        #expect(out[4] == 640)       // backwards → typical spacing, then follows the new base
        #expect(out[5] == 800)
        #expect(out[6] == 960)
    }

    @Test func senderReportParsing() throws {
        var writer = ByteWriter()
        // Receiver report (PT 201, no blocks) followed by a sender report (PT 200).
        writer.write(0x80); writer.write(201); writer.writeUInt16BE(1); writer.writeUInt32BE(0xAAAA_AAAA)
        writer.write(0x80); writer.write(200); writer.writeUInt16BE(6); writer.writeUInt32BE(0x1234_5678)
        writer.writeUInt64BE(0xE8F0_0000_8000_0000); writer.writeUInt32BE(90_000); writer.writeUInt32BE(10); writer.writeUInt32BE(1000)
        let reports = RTCPSenderReport.parse(writer.data)
        #expect(reports.count == 1)
        #expect(reports.first?.ssrc == 0x1234_5678)
        #expect(reports.first?.ntp == 0xE8F0_0000_8000_0000)
        #expect(reports.first?.rtpTimestamp == 90_000)
        #expect(RTCPSenderReport.parse(Data([0x80, 200, 0x00])).isEmpty)
        #expect(RTCPSenderReport.parse(Data([0x80, 200, 0x00, 0x06, 0x00])).isEmpty)
    }

    @Test func wallClockFromSenderReport() {
        var clock = TrackWallClock(clockRate: 90_000)
        let now = Date()
        // SR says RTP 90_000 corresponds to (now - 1 s).
        clock.update(senderReport: RTCPSenderReport(ssrc: 1, ntp: NTPTime.timestamp(for: now - 1), rtpTimestamp: 90_000))
        let wall = clock.wallClock(rtpTimestamp: 90_000 + 45_000, arrival: now)
        #expect(abs(wall.timeIntervalSince(now - 0.5)) < 0.001)
        #expect(clock.usingSenderReport)
    }

    @Test func implausibleSenderReportFallsBackToArrival() {
        var clock = TrackWallClock(clockRate: 90_000)
        let now = Date()
        clock.update(senderReport: RTCPSenderReport(ssrc: 1, ntp: NTPTime.timestamp(for: now - 3600), rtpTimestamp: 0))
        let wall = clock.wallClock(rtpTimestamp: 3000, arrival: now)
        #expect(wall == now)
        #expect(!clock.usingSenderReport)
    }

    @Test func wallClockIsMonotonic() {
        var clock = TrackWallClock(clockRate: 8000)
        let now = Date()
        let first = clock.wallClock(rtpTimestamp: 0, arrival: now)
        let second = clock.wallClock(rtpTimestamp: 160, arrival: now - 0.5)
        #expect(second >= first)
    }

    @Test func senderReportTimeMapsAnyTimestampWithoutClamping() {
        var clock = TrackWallClock(clockRate: 8000)
        let now = Date()
        #expect(clock.senderReportTime(rtpTimestamp: 0, arrival: now) == nil)
        clock.update(senderReport: RTCPSenderReport(ssrc: 2, ntp: NTPTime.timestamp(for: now + 2), rtpTimestamp: 8000))
        _ = clock.wallClock(rtpTimestamp: 16_000, arrival: now)   // later units do not move an earlier unit's mapping
        let earlier = clock.senderReportTime(rtpTimestamp: 0, arrival: now)
        #expect(abs((earlier ?? .distantPast).timeIntervalSince(now + 1)) < 0.001)
        #expect(clock.senderReportTime(rtpTimestamp: 0, arrival: now + 5) == nil, "more than 3 s from arrival")
    }
}

/// Review finding (B-frames over RTSP): RTP timestamps are presentation times, which step back in decode order when a
/// camera sends B-frames. `DecodeTimeline` gives each unit an increasing decode time instead of re-timing the step.
@Suite struct DecodeTimelineTests {
    /// One frame at 25 fps on the 90 kHz clock.
    static let frame: Int64 = 3_600

    private func decodeTimes(_ display: [Int], keyframes: Set<Int> = [0], timeline: inout DecodeTimeline) -> [Int64] {
        display.enumerated().map { timeline.decodeTime(pts: Int64($1) * Self.frame, isKeyframe: keyframes.contains($0)) }
    }

    /// VideoToolbox's B-pyramid in decode order (I0 P4 B2 b1 b3 P8 B6 b5 b7 …): decode times increase strictly, settle
    /// two frames behind (its reorder depth) and from then on never pass the presentation time.
    @Test func bPyramidGetsIncreasingDecodeTimesAtTheFrameRate() {
        var timeline = DecodeTimeline(clockRate: 90_000)
        let groups: [Int] = (1..<10).flatMap { (group: Int) -> [Int] in [4 * group + 4, 4 * group + 2, 4 * group + 1, 4 * group + 3] }
        let display: [Int] = [0, 4, 2, 1, 3] + groups
        let decode = decodeTimes(display, timeline: &timeline)
        let f = Self.frame
        // The first anchor went out before the stream showed it reorders; decode times stay just above it until the
        // depth's worth of later pictures arrived.
        #expect(Array(decode.prefix(7)) == [0, 4 * f, 4 * f + 1, 4 * f + 2, 4 * f + 3, 4 * f + 4, 4 * f + 5])
        #expect(Array(decode.dropFirst(7)) == (7..<display.count).map { Int64($0 - 2) * f })
        #expect(zip(decode.dropFirst(7), display.dropFirst(7)).allSatisfy { $0 <= Int64($1) * f })
        #expect(timeline.reorderDepth == 2)
    }

    /// Classic IBBP (I0 P3 B1 B2 P6 B4 B5 …) reorders one frame deep.
    @Test func ibbpReordersOneFrameDeep() {
        var timeline = DecodeTimeline(clockRate: 90_000)
        let groups: [Int] = (1..<10).flatMap { (group: Int) -> [Int] in [3 * group + 3, 3 * group + 1, 3 * group + 2] }
        let display: [Int] = [0, 3, 1, 2] + groups
        let decode = decodeTimes(display, timeline: &timeline)
        #expect(zip(decode.dropFirst(), decode).allSatisfy { $0 > $1 })
        #expect(timeline.reorderDepth == 1)
        #expect(zip(decode.dropFirst(5), display.dropFirst(5)).allSatisfy { $0 <= Int64($1) * Self.frame })
        #expect(decode.last == Int64(display.count - 2) * Self.frame)
    }

    /// Cameras without B-frames: the decode time is the presentation time (no decode time is set downstream).
    @Test func inOrderStreamsKeepTheirTimes() {
        var timeline = DecodeTimeline(clockRate: 90_000)
        let pts = (0..<100).map { Int64($0) * 3_000 }
        #expect(pts.enumerated().map { timeline.decodeTime(pts: $1, isKeyframe: $0 % 30 == 0) } == pts)
        #expect(timeline.reorderDepth == 0)
    }

    /// A small step back (clock jitter) or a repeated timestamp is not reordering: it comes back unchanged (the smoother
    /// re-times it, as before) and the stream stays in order.
    @Test func jitterAndRepeatsAreNotReordering() {
        var timeline = DecodeTimeline(clockRate: 90_000)
        let pts: [Int64] = [0, 3_000, 6_000, 5_700, 9_000, 9_000, 12_000]
        #expect(pts.map { timeline.decodeTime(pts: $0, isKeyframe: false) } == pts)
        #expect(timeline.reorderDepth == 0)
    }

    /// A keyframe that steps back, or a step back of more than 1 s, starts a new timeline (a restarted sender): its time
    /// comes back unchanged for the smoother to re-time, and the depth learned so far stays.
    @Test func keyframesAndLongStepsBackStartANewTimeline() {
        var timeline = DecodeTimeline(clockRate: 90_000)
        let f = Self.frame
        _ = decodeTimes([0, 4, 2, 1, 3, 8, 6, 5, 7], timeline: &timeline)
        #expect(timeline.reorderDepth == 2)
        #expect(timeline.decodeTime(pts: 2 * f, isKeyframe: true) == 2 * f)
        #expect(timeline.decodeTime(pts: 6 * f, isKeyframe: false) == 2 * f + 1)
        #expect(timeline.decodeTime(pts: -100 * f, isKeyframe: false) == -100 * f)
        #expect(timeline.decodeTime(pts: -99 * f, isKeyframe: false) == -100 * f + 1)
        #expect(timeline.reorderDepth == 2)
    }
}
