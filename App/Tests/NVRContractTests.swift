import BridgeEngine
import CoreGraphics
import Foundation
import MediaCore
import Testing

/// T00 D.1 is the contract of the Mac app's NVR seams: names, labels, access and isolation. This test calls every member it declares in the form
/// it declares it, so a rename or a changed label is a compile error here and not in another task's code. (Behavior is the other suites' business.)
@MainActor @Suite(.timeLimit(.minutes(1))) struct NVRContractTests {
    @Test func theClockHasTheDeclaredSurface() {
        let clock = PlaybackClock(uptime: { 100 }, wall: { Date(timeIntervalSinceReferenceDate: 1_000) })
        let state: PlaybackClock.State = clock.state
        #expect(state.mode == .live && PlaybackClock.liveSnap == 5)
        let date = Date(timeIntervalSinceReferenceDate: 500)
        clock.scrub(to: date)
        #expect(clock.position(atUptime: 101) == date && clock.state.mode == .paused)
        clock.play(from: date, startingIn: 0.1)
        clock.pause()
        clock.goLive()
        #expect(clock.shouldGoLive(releasingAt: Date(timeIntervalSinceReferenceDate: 1_000)))
        let modes: [PlaybackClock.Mode] = [.live, .paused, .playing]
        #expect(modes.count == 3)
    }

    @Test func theCellTypesHaveTheDeclaredSurface() async {
        let sink = FakeArchiveSink()
        let reader = FakeArchiveReader(FakeTimeline(fragments: 4, gopFragments: 2))
        let clock = PlaybackClock()
        let playback = CellPlayback(sink: sink, archive: reader, camera: UUID(), clock: clock, now: { 0 }, sleep: { _ in })
        playback.request(PlaybackDesire(target: Date(), precision: .keyframe, playing: false, epoch: 1))
        let coverage: CellCoverage = playback.coverage
        let cases: [CellCoverage] = [.live, .recorded, .loading, .noRecording(next: nil, recordingOff: true), .driveMissing, .unreadable]
        #expect(cases.contains(coverage))
        _ = playback.hasPicture
        await playback.stop()
        let cell = NVRCell(cameraID: UUID(), sink: sink, playback: playback)
        #expect(!cell.showsPicture && cell.coverage == .loading)
        let precisions: [ScrubPrecision] = [.keyframe, .exact]
        #expect(precisions.count == 2)
    }

    @Test func theSessionHasTheDeclaredSurface() {
        let session = NVRSession(archive: FakeArchiveReader(FakeTimeline(fragments: 4, gopFragments: 2)), clock: PlaybackClock(), makeSink: { FakeArchiveSink() },
                                 now: { 0 }, sleep: { _ in })
        #expect(NVRSession.maximumCells == 9 && session.isMuted && session.focused == nil)
        session.setCameras([])
        #expect(session.cell(for: UUID()) == nil)
        session.beginScrub()
        session.scrub(to: Date())
        session.endScrub()
        session.play()
        session.pause()
        session.togglePlay()
        session.goLive()
        session.seek(by: 1)
        session.focus(nil)
        session.suspend()
        session.resume()
        session.isMuted = false
        _ = session.position
        _ = session.clock
    }

    @Test func theTimelineTypesHaveTheDeclaredSurface() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let limits = TimelineLimits(oldest: now.addingTimeInterval(-86_400), now: now)
        #expect(limits.minDuration == 60 && limits.maxDuration == 86_400)
        let viewport = TimelineViewport(start: now.addingTimeInterval(-600), duration: 600)
        #expect(viewport.end == now && viewport.x(for: now, width: 600) == 600 && viewport.time(atX: 0, width: 600) == viewport.start)
        _ = viewport.zoomed(by: 2, anchor: now, limits: limits)
        _ = viewport.panned(by: 10, limits: limits)
        #expect(ZoomPreset.allCases.map(\.duration) == [600, 3_600, 21_600, 86_400, nil])
        let ticks: [TimelineTicks.Tick] = TimelineTicks.make(viewport: viewport, width: 800, calendar: Calendar(identifier: .gregorian), minSpacing: 80)
        #expect(!ticks.isEmpty && ticks.allSatisfy { !$0.label.isEmpty })
        let model = TimelineModel(viewport: viewport)
        model.select(.hour, playhead: now, isLive: true, limits: limits)
        model.zoom(by: 2, aroundX: 100, width: 800, limits: limits)
        model.pan(byPoints: 10, width: 800, limits: limits)
        model.tick(now: now, playhead: now, limits: limits)
        _ = (model.viewport, model.preset, model.followsLive)
        let columns = WaveformColumns(coverage: [1], level: [1])
        #expect(columns.coverage == [1])
        #expect(WaveformScale.reference(typical: nil, visibleLevels: []) == 1_000)
        #expect(WaveformScale.height(level: 4, reference: 4) == 1)
        let start = ViewerStart(time: nil, playing: false)
        #expect(start.time == nil)
    }
}
