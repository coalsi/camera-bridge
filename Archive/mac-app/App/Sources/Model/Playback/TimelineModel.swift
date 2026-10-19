import CoreGraphics
import Foundation
import Observation

/// What the timeline shows and how it follows: the viewport, the zoom preset and whether the right edge follows live. Pure logic over
/// `TimelineViewport`; the views read it and call these methods (the mouse, trackpad, keys and the refresh loop).
@MainActor @Observable final class TimelineModel {
    private(set) var viewport: TimelineViewport
    /// The right edge follows now (a live viewport at [now - N, now + 4%]).
    private(set) var followsLive = true
    /// The preset the viewport was made by; nil after a free zoom or pan.
    private(set) var preset: ZoomPreset?

    init(viewport: TimelineViewport) { self.viewport = viewport }

    /// From live a preset shows [now - N, now + 4%]; from the past it centres on the playhead. All is oldest to now and keeps following.
    func select(_ preset: ZoomPreset, playhead: Date, isLive: Bool, limits: TimelineLimits) {
        self.preset = preset
        viewport = .make(preset, playhead: playhead, isLive: isLive, limits: limits)
        followsLive = isLive || preset == .all
    }

    /// Pinch or wheel: `factor` above 1 zooms in around the time under `x`.
    func zoom(by factor: Double, aroundX x: CGFloat, width: CGFloat, limits: TimelineLimits) {
        viewport = viewport.zoomed(by: factor, anchor: viewport.time(atX: x, width: width), limits: limits)
        preset = nil
        followsLive = viewport.isLive(now: limits.now)
    }

    /// Horizontal scroll: positive points move the window later.
    func pan(byPoints points: CGFloat, width: CGFloat, limits: TimelineLimits) {
        guard width > 0 else { return }
        viewport = viewport.panned(by: Double(points / width) * viewport.duration, limits: limits)
        preset = nil
        followsLive = viewport.isLive(now: limits.now)
    }

    /// Called by the page's refresh loop: keeps a live viewport at [now - N, now + 4%], All at oldest to now, and any other window around the
    /// playhead (a playhead that has left the window pages it: to a quarter of the window from the left when it ran off the right, to
    /// three quarters when it ran off the left).
    func tick(now: Date, playhead: Date, limits: TimelineLimits) {
        let limits = TimelineLimits(oldest: limits.oldest, now: now, minDuration: limits.minDuration)
        if preset == .all {
            viewport = .make(.all, playhead: playhead, isLive: true, limits: limits)
        } else if followsLive {
            viewport = .live(duration: viewport.duration, now: now).clamped(to: limits)
        } else if playhead > viewport.end {
            viewport = TimelineViewport(start: playhead.addingTimeInterval(-viewport.duration * 0.25), duration: viewport.duration).clamped(to: limits)
            followsLive = viewport.isLive(now: now)
        } else if playhead < viewport.start {
            viewport = TimelineViewport(start: playhead.addingTimeInterval(-viewport.duration * 0.75), duration: viewport.duration).clamped(to: limits)
        }
    }
}
