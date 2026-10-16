import AppKit
import BridgeEngine
import SwiftUI

/// The timeline: a ruler, the activity waveform (non-keyframe bytes per second against the camera's normal) and the playhead. Drag anywhere to look
/// at that moment, let go to play; pinch or scroll to zoom and pan. One track serves the camera page (one camera) and the NVR page (all of them).
///
/// The track is a `Canvas` whose inputs do not include the clock, so it is redrawn only when the viewport, the data or the size change; the playhead
/// is a separate layer driven by a `TimelineView` while the clock moves. Dragging calls `NVRSession.scrub(to:)` at event rate (O(1)); nothing here
/// waits for a picture.
struct TimelineScrubber: View {
    let panel: NVRPanelModel
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDragging = false
    @State private var hoverX: CGFloat?
    @State private var lastMagnification: CGFloat = 1

    static let trackHeight: CGFloat = 78
    static let rulerHeight: CGFloat = 22

    var body: some View {
        let timeline = panel.timeline, activity = panel.activity
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                TimelineTrack(viewport: timeline.viewport, columns: activity.columns, answered: activity.answered, normalIsKnown: activity.normalIsKnown,
                              hasRecordings: panel.hasRecordings, oldest: panel.oldest, now: Date(), calendar: calendar)
                    .equatable()
                    .drawingGroup()
                if panel.isChoosingClip { ClipBand(panel: panel, width: width) }
                Playhead(panel: panel, width: width, isScrubbing: isDragging)
                if let x = isDragging ? panel.playheadX() : hoverX, panel.hasRecordings {
                    TimeBubble(panel: panel, x: x, width: width)
                }
            }
            .frame(width: width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(drag(width: width))
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    let factor = value.magnification / lastMagnification
                    lastMagnification = value.magnification
                    panel.zoom(by: Double(factor), aroundX: value.startAnchor.x * width)
                }
                .onEnded { _ in lastMagnification = 1 })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
            .background { ScrollZoomMonitor(panel: panel) }
            .onChange(of: width, initial: true) { _, width in panel.setWidth(width) }
        }
        .frame(height: Self.trackHeight + Self.rulerHeight)
        .opacity(panel.hasRecordings ? 1 : 0.55)
        .overlay {
            if !panel.hasRecordings {
                Text("Nothing recorded yet. Turn on Record to build a timeline.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Timeline"))
        .accessibilityValue(Text(Self.spokenPosition(panel.session, calendar: calendar)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: panel.session.seek(by: 10)
            case .decrement: panel.session.seek(by: -10)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Go Live")) { panel.goLive() }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard panel.hasRecordings else { return }
                if !isDragging {
                    isDragging = true
                    panel.beginScrub(atX: value.location.x)
                } else {
                    panel.scrub(toX: value.location.x)
                }
            }
            .onEnded { _ in
                guard isDragging else { return }
                isDragging = false
                panel.endScrub()
            }
    }

    /// "Live", or the time of day the playhead is at, in words a screen reader can say.
    static func spokenPosition(_ session: NVRSession, calendar: Calendar) -> String {
        guard !session.clock.isLive else { return String(localized: "Live") }
        return session.position.formatted(date: .abbreviated, time: .standard, in: calendar)
    }
}

// MARK: - The track

/// Ruler, gaps, waveform and normal line. `Equatable`: it is redrawn when these change, and never because the clock moved.
private struct TimelineTrack: View, Equatable {
    let viewport: TimelineViewport
    let columns: WaveformColumns
    let answered: ActivityRequest?
    let normalIsKnown: Bool
    let hasRecordings: Bool
    let oldest: Date?
    /// Rounded to the second so the "now" edge does not make every frame different.
    let now: Date
    let calendar: Calendar

    static func == (lhs: TimelineTrack, rhs: TimelineTrack) -> Bool {
        lhs.viewport == rhs.viewport && lhs.columns == rhs.columns && lhs.answered == rhs.answered && lhs.normalIsKnown == rhs.normalIsKnown
            && lhs.hasRecordings == rhs.hasRecordings && lhs.oldest == rhs.oldest && lhs.calendar == rhs.calendar
            && Int(lhs.now.timeIntervalSinceReferenceDate / 5) == Int(rhs.now.timeIntervalSinceReferenceDate / 5)
    }

    var body: some View {
        Canvas { context, size in
            let trackRect = CGRect(x: 0, y: 0, width: size.width, height: TimelineScrubber.trackHeight)
            context.fill(Path(roundedRect: trackRect, cornerRadius: 10), with: .color(Brand.card))
            guard hasRecordings else { return }

            // What is outside the recordings: before the oldest and after now is plain; gaps are hatched.
            let reference = WaveformScale.reference(typical: 1, visibleLevels: [])
            let middle = trackRect.midY
            let half = trackRect.height / 2 - 6
            if let answered, !columns.coverage.isEmpty {
                let bin = answered.binDuration
                let barWidth = max(2, CGFloat(bin / viewport.duration) * size.width)
                for index in columns.coverage.indices {
                    let time = answered.range.lowerBound.addingTimeInterval(Double(index) * bin)
                    let x = viewport.x(for: time, width: size.width)
                    guard x + barWidth >= 0, x <= size.width else { continue }
                    let coverage = columns.coverage[index]
                    if coverage <= 0 {
                        // A gap between recordings is hatched; before the oldest recording and after now the track is plain.
                        if time >= (oldest ?? .distantFuture), time.addingTimeInterval(bin) <= now {
                            drawHatching(&context, rect: CGRect(x: x, y: trackRect.minY + 1, width: barWidth, height: trackRect.height - 2), clip: trackRect)
                        }
                        continue
                    }
                    let level = columns.level[index]
                    let height = max(1.5, CGFloat(WaveformScale.height(level: level, reference: reference)) * half)
                    let high = normalIsKnown && level > WaveformScale.highActivity
                    let bar = CGRect(x: x, y: middle - height, width: max(1, barWidth - 0.5), height: height * 2)
                    context.fill(Path(roundedRect: bar.intersection(trackRect), cornerRadius: min(1.5, barWidth / 2)),
                                 with: .color((high ? Brand.accent : Color.white.opacity(0.55)).opacity(0.35 + 0.65 * coverage)))
                }
            }
            // Normal: a dashed line at the height a typical level reaches (half, under the square root).
            if normalIsKnown {
                let normalHeight = CGFloat(WaveformScale.height(level: 1, reference: reference)) * half
                var dashed = Path()
                for y in [middle - normalHeight, middle + normalHeight] {
                    dashed.move(to: CGPoint(x: 0, y: y))
                    dashed.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(dashed, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            // The ruler.
            for tick in TimelineTicks.make(viewport: viewport, width: size.width, calendar: calendar) {
                let x = viewport.x(for: tick.time, width: size.width)
                var line = Path()
                line.move(to: CGPoint(x: x, y: TimelineScrubber.trackHeight))
                line.addLine(to: CGPoint(x: x, y: TimelineScrubber.trackHeight + (tick.isMajor ? 8 : 5)))
                context.stroke(line, with: .color(.white.opacity(tick.isMajor ? 0.7 : 0.4)), lineWidth: 1)
                let label = Text(tick.label).font(.system(size: 10.5, weight: tick.isMajor ? .semibold : .regular, design: .rounded)).foregroundStyle(.white.opacity(tick.isMajor ? 0.85 : 0.6))
                context.draw(label, at: CGPoint(x: x, y: TimelineScrubber.trackHeight + 15), anchor: .center)
            }
        }
        .frame(height: TimelineScrubber.trackHeight + TimelineScrubber.rulerHeight)
    }

    private func drawHatching(_ context: inout GraphicsContext, rect: CGRect, clip: CGRect) {
        var lines = Path()
        var offset = -rect.height
        while offset < rect.width {
            lines.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            lines.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += 5
        }
        var inner = context
        inner.clip(to: Path(rect.intersection(clip)))
        inner.stroke(lines, with: .color(.white.opacity(0.10)), lineWidth: 1)
    }
}

// MARK: - The playhead

/// The playhead line and handle. A `TimelineView` redraws it while the clock moves; paused, it is drawn once.
private struct Playhead: View {
    let panel: NVRPanelModel
    let width: CGFloat
    let isScrubbing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(panel.session.clock.isPlaying || panel.session.clock.isLive))) { _ in
            let x = min(max(panel.playheadX(), 0), width)
            let isLive = panel.session.clock.isLive
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(isLive ? Brand.recording : Brand.accent)
                    .frame(width: 2, height: TimelineScrubber.trackHeight)
                Circle()
                    .fill(isLive ? Brand.recording : Brand.accent)
                    .frame(width: 10, height: 10)
                    .offset(y: -5)
            }
            .frame(width: 10, height: TimelineScrubber.trackHeight, alignment: .top)
            .position(x: x, y: TimelineScrubber.trackHeight / 2)
            .allowsHitTesting(false)
            .opacity(panel.hasRecordings || isLive ? 1 : 0)
        }
    }
}

/// The time under the pointer (or the playhead while dragging).
private struct TimeBubble: View {
    let panel: NVRPanelModel
    let x: CGFloat
    let width: CGFloat
    @Environment(\.calendar) private var calendar

    var body: some View {
        let time = panel.time(atX: x)
        Text(time.formatted(date: .omitted, time: .standard, in: calendar))
            .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .glass(in: Capsule())
            .position(x: min(max(x, 36), max(36, width - 36)), y: -2)
            .allowsHitTesting(false)
    }
}

// MARK: - Scrolling and zooming

/// Horizontal scroll pans the timeline and vertical scroll zooms it around the pointer, while the pointer is over the track: a local event monitor, as
/// the Overview's page turner does (a `Canvas` has no scroll handling of its own).
private struct ScrollZoomMonitor: NSViewRepresentable {
    let panel: NVRPanelModel

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.panel = panel
    }

    final class MonitorView: NSView {
        weak var panel: NVRPanelModel?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                self?.route(event) ?? event
            }
        }

        private func route(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, let panel else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), MainActor.assumeIsolated({ panel.hasRecordings }) else { return event }
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            MainActor.assumeIsolated {
                if abs(dx) > abs(dy) {
                    panel.pan(byPoints: -dx)
                } else if dy != 0 {
                    panel.zoom(by: exp(Double(dy) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08)), aroundX: point.x)
                }
            }
            return nil
        }
    }
}
