import CoreGraphics
import Foundation
import Testing

@Suite struct TimelineViewportTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func limits(recorded: TimeInterval) -> TimelineLimits { TimelineLimits(oldest: now.addingTimeInterval(-recorded), now: now) }

    @Test func pointsAndTimesConvertBothWays() {
        let viewport = TimelineViewport(start: now, duration: 600)
        #expect(viewport.x(for: now.addingTimeInterval(300), width: 1_000) == 500)
        #expect(viewport.time(atX: 250, width: 1_000) == now.addingTimeInterval(150))
        #expect(viewport.x(for: now.addingTimeInterval(-60), width: 1_000) == -100, "outside the window: off to the left")
        #expect(TimelineViewport(start: now, duration: 0).x(for: now, width: 100) == 0)
        #expect(viewport.time(atX: 5, width: 0) == now)
    }

    @Test func theLimitsNeverGoBelowTheNarrowestWindow() {
        #expect(limits(recorded: 20).maxDuration == 60)
        #expect(limits(recorded: 7_200).maxDuration == 7_200)
    }

    @Test func zoomingInKeepsThePointUnderThePointer() {
        let limits = limits(recorded: 86_400)
        let viewport = TimelineViewport(start: now.addingTimeInterval(-7_200), duration: 3_600)
        let anchor = viewport.start.addingTimeInterval(900)   // a quarter of the way in
        let zoomed = viewport.zoomed(by: 4, anchor: anchor, limits: limits)
        #expect(zoomed.duration == 900)
        #expect(abs(zoomed.x(for: anchor, width: 800) - viewport.x(for: anchor, width: 800)) < 0.001, "the anchor keeps its screen position")
    }

    @Test func zoomingStopsAtSixtySecondsAndAtTheRecordings() {
        let limits = limits(recorded: 3_000)
        let viewport = TimelineViewport(start: now.addingTimeInterval(-600), duration: 600)
        #expect(viewport.zoomed(by: 1_000, anchor: now.addingTimeInterval(-300), limits: limits).duration == 60)
        #expect(viewport.zoomed(by: 0.001, anchor: now.addingTimeInterval(-300), limits: limits).duration == 3_000, "zooming out ends at the oldest recording")
        #expect(viewport.zoomed(by: 0, anchor: now, limits: limits) == viewport)
        #expect(viewport.zoomed(by: .nan, anchor: now, limits: limits) == viewport)
    }

    @Test func zoomingOutNeverNarrowsTheWindow() {
        // A 24 h preset on 3 minutes of footage is wider than the recordings; a zoom-out must not snap it down to 3 minutes.
        let limits = limits(recorded: 180)
        let viewport = TimelineViewport.live(duration: 86_400, now: now)
        #expect(viewport.zoomed(by: 0.5, anchor: now, limits: limits).duration == 86_400)
        #expect(viewport.zoomed(by: 2, anchor: now, limits: limits).duration == 43_200)
    }

    @Test func panningStopsAtTheOldestRecordingAndAtTheLiveEdge() {
        let limits = limits(recorded: 7_200)
        let viewport = TimelineViewport(start: now.addingTimeInterval(-3_600), duration: 600)
        #expect(viewport.panned(by: -10_000, limits: limits).start == limits.oldest)
        let atEdge = viewport.panned(by: 10_000, limits: limits)
        #expect(atEdge == TimelineViewport.live(duration: 600, now: now), "the live edge, with its 4% margin")
        #expect(atEdge.end == now.addingTimeInterval(24))
        #expect(viewport.panned(by: 120, limits: limits).start == viewport.start.addingTimeInterval(120))
    }

    @Test func aWindowWiderThanTheRecordingsOnlyFitsAtTheLiveEdge() {
        let limits = limits(recorded: 180)
        let wide = TimelineViewport(start: now.addingTimeInterval(-50_000), duration: 86_400)
        #expect(wide.panned(by: 5_000, limits: limits).start == TimelineViewport.live(duration: 86_400, now: now).start)
        #expect(wide.panned(by: -5_000, limits: limits).start == TimelineViewport.live(duration: 86_400, now: now).start)
    }

    @Test func liveIsRecognisedWithinHalfASecond() {
        let live = TimelineViewport.live(duration: 600, now: now)
        #expect(live.isLive(now: now))
        #expect(TimelineViewport(start: live.start.addingTimeInterval(-0.4), duration: 600).isLive(now: now))
        #expect(!TimelineViewport(start: live.start.addingTimeInterval(-0.6), duration: 600).isLive(now: now))
        #expect(TimelineViewport(start: live.start.addingTimeInterval(5), duration: 600).isLive(now: now), "past the edge counts as live")
    }

    @Test func presetsFollowLiveOrCentreOnThePlayhead() {
        let limits = limits(recorded: 200_000)
        #expect(TimelineViewport.make(.hour, playhead: now, isLive: true, limits: limits) == .live(duration: 3_600, now: now))
        let playhead = now.addingTimeInterval(-40_000)
        let centred = TimelineViewport.make(.sixHours, playhead: playhead, isLive: false, limits: limits)
        #expect(centred.duration == 21_600 && centred.start == playhead.addingTimeInterval(-10_800))
        let nearTheEdge = TimelineViewport.make(.day, playhead: now.addingTimeInterval(-60), isLive: false, limits: limits)
        #expect(nearTheEdge.end == now.addingTimeInterval(86_400 * 0.04), "centring would pass the live edge: clamped to it")
    }

    @Test func allIsOldestToNowAndAtLeastTenMinutes() {
        let long = TimelineViewport.make(.all, playhead: now, isLive: true, limits: limits(recorded: 100_000))
        #expect(long.start == now.addingTimeInterval(-100_000) && long.end >= now)
        #expect(abs(long.duration - 100_000 / 0.96) < 0.001)
        let short = TimelineViewport.make(.all, playhead: now, isLive: true, limits: limits(recorded: 120))
        #expect(short.duration == 600 && short.end == now.addingTimeInterval(24), "two minutes of footage still gets a ten minute window")
    }

    @Test func thePresetIsRememberedUnderItsKey() {
        let suite = "com.coreysilvia.CameraBridgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(ZoomPreset.stored(in: defaults) == .hour, "the default")
        ZoomPreset.sixHours.store(in: defaults)
        #expect(ZoomPreset.stored(in: defaults) == .sixHours && defaults.string(forKey: "nvrZoomPreset") == "sixHours")
        defaults.set("nonsense", forKey: ZoomPreset.storageKey)
        #expect(ZoomPreset.stored(in: defaults) == .hour)
        #expect(ZoomPreset.allCases.map(\.duration) == [600, 3_600, 21_600, 86_400, nil])
    }
}
