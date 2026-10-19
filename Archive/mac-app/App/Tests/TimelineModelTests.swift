import BridgeEngine
import CoreGraphics
import Foundation
import Testing

@MainActor @Suite struct TimelineModelTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func limits(recorded: TimeInterval, now: Date? = nil) -> TimelineLimits {
        let now = now ?? self.now
        return TimelineLimits(oldest: now.addingTimeInterval(-recorded), now: now)
    }

    @Test func aPresetFromLiveFollowsLiveAndFromThePastCentresOnThePlayhead() {
        let model = TimelineModel(viewport: .live(duration: 3_600, now: now))
        model.select(.sixHours, playhead: now, isLive: true, limits: limits(recorded: 200_000))
        #expect(model.followsLive && model.preset == .sixHours && model.viewport == .live(duration: 21_600, now: now))
        let playhead = now.addingTimeInterval(-50_000)
        model.select(.hour, playhead: playhead, isLive: false, limits: limits(recorded: 200_000))
        #expect(!model.followsLive && model.viewport.start == playhead.addingTimeInterval(-1_800) && model.preset == .hour)
        model.select(.all, playhead: playhead, isLive: false, limits: limits(recorded: 200_000))
        #expect(model.followsLive, "All always follows")
    }

    @Test func zoomingAndPanningLeaveThePresetAndFollowLiveOnlyAtTheEdge() {
        let model = TimelineModel(viewport: .live(duration: 3_600, now: now))
        model.select(.hour, playhead: now, isLive: true, limits: limits(recorded: 200_000))
        model.zoom(by: 2, aroundX: 800, width: 1_000, limits: limits(recorded: 200_000))   // near the right edge: x = 800 of 1000
        #expect(model.preset == nil && model.viewport.duration == 1_800)
        #expect(!model.followsLive, "the window moved away from the edge")
        model.zoom(by: 0.5, aroundX: 1_000, width: 1_000, limits: limits(recorded: 200_000))   // zoom out about the live edge
        #expect(model.viewport.duration == 3_600)
        model.pan(byPoints: 10_000, width: 1_000, limits: limits(recorded: 200_000))   // as far later as it goes
        #expect(model.followsLive && model.viewport == .live(duration: 3_600, now: now))
        model.pan(byPoints: -300, width: 1_000, limits: limits(recorded: 200_000))
        #expect(!model.followsLive && abs(model.viewport.start.timeIntervalSince(TimelineViewport.live(duration: 3_600, now: now).start) + 1_080) < 0.001)
    }

    @Test func aLiveViewportKeepsFollowingNowAndAFrozenOneStaysPut() {
        let model = TimelineModel(viewport: .live(duration: 600, now: now))
        model.select(.tenMinutes, playhead: now, isLive: true, limits: limits(recorded: 100_000))
        let later = now.addingTimeInterval(30)
        model.tick(now: later, playhead: later, limits: limits(recorded: 100_000, now: now))
        #expect(model.viewport == .live(duration: 600, now: later), "the right edge moves with now, whatever `limits` said about now")

        model.pan(byPoints: -500, width: 1_000, limits: limits(recorded: 100_000, now: later))
        let frozen = model.viewport
        model.tick(now: later.addingTimeInterval(60), playhead: later.addingTimeInterval(-400), limits: limits(recorded: 100_000, now: later))
        #expect(model.viewport == frozen, "a window the person moved away stays where it is while the playhead is inside it")
    }

    @Test func aPlayheadThatLeavesTheWindowPagesIt() {
        let model = TimelineModel(viewport: TimelineViewport(start: now.addingTimeInterval(-7_200), duration: 600))
        model.select(.tenMinutes, playhead: now.addingTimeInterval(-7_000), isLive: false, limits: limits(recorded: 100_000))
        let end = model.viewport.end
        model.tick(now: now, playhead: end.addingTimeInterval(30), limits: limits(recorded: 100_000))   // played past the right edge
        #expect(model.viewport.start == end.addingTimeInterval(30 - 150), "the playhead at a quarter of the window")
        let start = model.viewport.start
        model.tick(now: now, playhead: start.addingTimeInterval(-20), limits: limits(recorded: 100_000))   // jumped back before the left edge
        #expect(model.viewport.start == start.addingTimeInterval(-20 - 450), "the playhead at three quarters")
    }

    @Test func allKeepsGrowingWithTheRecordings() {
        let model = TimelineModel(viewport: .live(duration: 600, now: now))
        model.select(.all, playhead: now, isLive: true, limits: limits(recorded: 1_000))
        let later = now.addingTimeInterval(960)
        model.tick(now: later, playhead: later, limits: TimelineLimits(oldest: now.addingTimeInterval(-1_000), now: later))
        #expect(model.viewport.start == now.addingTimeInterval(-1_000) && abs(model.viewport.duration - 1_960 / 0.96) < 0.001)
    }
}
