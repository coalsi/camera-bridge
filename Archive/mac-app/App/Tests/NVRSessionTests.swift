import BridgeEngine
import Foundation
import MediaCore
import Synchronization
import Testing

/// A session over fake cameras: an archive with one timeline each, recording sinks (one per cell, in camera order), a live source, and virtual time.
@MainActor final class SessionHarness {
    let time = VirtualTime()
    let cameras: [UUID]
    let timelines: [FakeTimeline]
    let archive: FakeArchiveReader
    let source = FakeFrameSource()
    let live = FakeLiveSource()
    let clock: PlaybackClock
    let session: NVRSession
    private(set) var sinks: [FakeArchiveSink] = []
    /// The Mac's clock: `wallOffset` seconds after the recordings end.
    let wallStart: Date

    init(cameraCount: Int = 2, gap: TimeInterval? = nil, wallOffset: TimeInterval = 3_600, withLive: Bool = true) {
        let start = FakeTimeline.origin
        let cameras = (0..<cameraCount).map { _ in UUID() }
        self.cameras = cameras
        timelines = cameras.map { id in
            if let gap {
                return FakeTimeline(camera: id, runs: [.init(start: start, fragments: 10, gopFragments: 5), .init(start: start.addingTimeInterval(20 + gap), fragments: 10, gopFragments: 5)])
            }
            return FakeTimeline(camera: id, start: start, fragments: 60, gopFragments: 5)
        }
        archive = FakeArchiveReader(timelines)
        wallStart = (timelines.first?.end ?? start).addingTimeInterval(wallOffset)
        let time = time
        let wall = wallStart, base = time.now
        wallBase = base
        clock = PlaybackClock(uptime: { time.now }, wall: { wall.addingTimeInterval(time.now - base) })
        let box = SinkList()
        session = NVRSession(archive: archive, clock: clock, makeSink: {
            let sink = FakeArchiveSink(uptime: { time.now })
            box.append(sink)
            return sink
        }, now: { time.now }, sleep: { try await time.sleep(until: $0) }, liveOpener: withLive ? live.opener : nil, liveStream: .sub, frames: source)
        sinkList = box
    }

    private let sinkList: SinkList
    private let wallBase: TimeInterval
    /// The Mac's clock now.
    var wallNow: Date { wallStart.addingTimeInterval(time.now - wallBase) }
    /// The same, for code that wants a `@Sendable` closure.
    var wallClosure: @Sendable () -> Date {
        let time = time, start = wallStart, base = wallBase
        return { start.addingTimeInterval(time.now - base) }
    }
    var sinkOrder: [FakeArchiveSink] { sinkList.sinks }
    func sink(_ index: Int) -> FakeArchiveSink { sinkList.sinks[index] }

    func date(_ offset: TimeInterval) -> Date { timelines[0].start.addingTimeInterval(offset) }
    func frameNumber(_ pts: Int64) -> Int { Int(((Double(pts) / 90_000 - timelines[0].start.timeIntervalSinceReferenceDate) * 25).rounded()) }

    /// Waits (in real time, up to three seconds) for `condition`. With `advancing`, virtual time passes while a cell waits for it (the dwell, a
    /// read's latency, a frame that is not due yet), but never because only the session's own timer is pending.
    @discardableResult
    func until(advancing: Bool = true, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<3_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
            if advancing, session.cells.contains(where: { !$0.playback.isIdle }), let wake = time.nextWake { time.advance(to: wake) }
        }
        return condition()
    }

    /// Every cell has finished what it was asked (not playing: a playing cell is never idle).
    func settle() async {
        await until { session.cells.allSatisfy { $0.playback.isIdle } && !session.cells.contains { $0.isHandingOff } }
        try? await Task.sleep(for: .milliseconds(3))
    }

    /// The feeds have opened their streams and show a first picture.
    func startLive() async {
        session.setCameras(cameras)
        _ = await settles { live.opens.count == cameras.count }
        for index in 0..<cameras.count { live.send(FakeLiveSource.video(key: true), to: index) }
        _ = await settles { session.cells.allSatisfy { $0.feed?.hasPicture == true } }
    }
}

nonisolated final class SinkList: Sendable {
    private let list = Mutex<[FakeArchiveSink]>([])
    func append(_ sink: FakeArchiveSink) { list.withLock { $0.append(sink) } }
    var sinks: [FakeArchiveSink] { list.withLock { $0 } }
}

@MainActor @Suite(.timeLimit(.minutes(2))) struct NVRSessionTests {
    @Test func cellsFollowTheCameraListUpToNineAndLeaveWhenTheirCameraDoes() async {
        let h = SessionHarness(cameraCount: 3)
        h.session.setCameras(h.cameras)
        #expect(h.session.cells.map(\.cameraID) == h.cameras)
        #expect(await settles { h.live.opens.count == 3 })
        #expect(h.live.opens.map(\.stream) == [.sub, .sub, .sub], "the grid reads sub streams")
        let first = h.session.cells[0]
        h.session.setCameras([h.cameras[0], h.cameras[2]])
        #expect(h.session.cells.map(\.cameraID) == [h.cameras[0], h.cameras[2]] && h.session.cells[0] === first, "a cell that stays is the same cell")
        #expect(await settles { h.live.cancelled.value == 1 }, "the lease of the camera that left is released")
        h.session.setCameras((0..<12).map { _ in UUID() })
        #expect(h.session.cells.count == NVRSession.maximumCells)
        h.session.stopAll()
        #expect(h.session.cells.isEmpty)
    }

    @Test func aScrubFromLiveHandsTheRendererToRecordedVideoWithoutABlankFrame() async {
        let h = SessionHarness(cameraCount: 1)
        await h.startLive()
        let cell = h.session.cells[0], sink = h.sink(0)
        #expect(cell.owner == .live && cell.coverage == .live && cell.showsPicture)

        var blank = false
        h.session.beginScrub()
        h.session.scrub(to: h.date(5.0))
        await h.until(advancing: false) {
            if !cell.showsPicture { blank = true }
            return sink.displayed.contains { $0.pts > 1_000_000_000_000 }
        }
        #expect(!blank, "the picture is there at every moment of the handoff")
        #expect(cell.owner == .recorded && h.live.cancelled.value == 1)
        #expect(cell.feed?.hasPicture == true && sink.clears == 0, "the live feed kept its picture; nothing removed it")
        let firstRecorded = sink.shows.firstIndex { $0.pts > 1_000_000_000_000 } ?? 0
        #expect(sink.shows[firstRecorded].isKeyframe, "the first recorded frame is a keyframe")
        #expect(sink.shows.suffix(from: firstRecorded).allSatisfy { $0.pts > 1_000_000_000_000 }, "no live picture after the first recorded one: one producer at a time")
        h.session.stopAll()
    }

    @Test func scrubbingIsOneStepForEveryCellWhateverTheReadsTake() async {
        let h = SessionHarness(cameraCount: 3, withLive: false)
        let time = h.time
        h.source.setLatency { kind in if kind == .keyframe { try await time.sleep(until: time.now + 5) } }
        h.session.setCameras(h.cameras)
        h.session.beginScrub()
        for step in 0..<1_000 { h.session.scrub(to: h.date(Double(step % 100) / 2)) }   // would hang if it waited for a read
        #expect(h.clock.state.mode == .paused && h.clock.position() == h.date(49.5))
        h.time.advance(by: 10)
        await h.until { h.session.cells.allSatisfy { $0.coverage == .recorded } }
        #expect(h.session.cells.allSatisfy { $0.coverage == .recorded })
        h.session.stopAll()
    }

    @Test func theExactFrameIsAskedForWhenThePointerHasRestedAndTheHoveredTileComesFirst() async {
        let h = SessionHarness(cameraCount: 3, withLive: false)
        h.session.setCameras(h.cameras)
        h.session.focus(h.cameras[2])
        #expect(h.session.ordered().map(\.cameraID) == [h.cameras[2], h.cameras[0], h.cameras[1]])
        h.session.focus(nil)
        h.session.beginScrub()
        h.session.scrub(to: h.date(5.0))
        await h.until(advancing: false) { (0..<3).allSatisfy { h.sink($0).displayed.count == 1 } }
        #expect((0..<3).allSatisfy { h.sink($0).displayed.map { h.frameNumber($0.pts) } == [0] }, "while the pointer moves: the keyframe")
        h.time.advance(by: 0.05)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.sink(0).displayed.map { h.frameNumber($0.pts) } == [0], "50 ms is not long enough")
        h.time.advance(by: 0.04)
        await h.until(advancing: false) { (0..<3).allSatisfy { h.sink($0).displayed.count == 2 } }
        for index in 0..<3 { #expect(h.sink(index).displayed.map { h.frameNumber($0.pts) } == [0, 125], "camera \(index): then the exact frame") }
        h.session.stopAll()
    }

    @Test func aMoveCancelsTheExactFrameOfTheOneBefore() async {
        let h = SessionHarness(cameraCount: 1, withLive: false)
        h.session.setCameras(h.cameras)
        h.session.beginScrub()
        h.session.scrub(to: h.date(5.0))
        await h.until(advancing: false) { h.sink(0).displayed.count == 1 }
        h.time.advance(by: 0.05)
        h.session.scrub(to: h.date(9.0))   // moved again before the delay ran out (the same GOP: its keyframe is on screen, nothing to do)
        await h.until(advancing: false) { h.session.cells[0].playback.isIdle }
        h.time.advance(by: 0.05)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!h.sink(0).displayed.contains { h.frameNumber($0.pts) == 125 }, "frame 125 was never wanted by then")
        h.time.advance(by: 0.05)
        await h.until(advancing: false) { h.sink(0).displayed.last.map { h.frameNumber($0.pts) } == 225 }
        #expect(h.sink(0).displayed.last.map { h.frameNumber($0.pts) } == 225)
        h.session.stopAll()
    }

    @Test func releasePlaysFromTheTargetAndAReleaseNearNowGoesLive() async {
        let h = SessionHarness(cameraCount: 1)
        await h.startLive()
        h.session.beginScrub()
        h.session.scrub(to: h.date(8.0))
        h.session.endScrub()
        #expect(h.clock.isPlaying && h.clock.state.wall == h.date(8.0), "release always plays")
        await h.until(advancing: false) { h.session.cells[0].owner == .recorded && h.sink(0).displayed.count >= 2 }
        #expect(h.session.cells[0].owner == .recorded)

        h.session.beginScrub()
        h.session.scrub(to: h.wallStart.addingTimeInterval(-3))   // 3 s behind the Mac's clock
        h.session.endScrub()
        #expect(h.clock.isLive, "within five seconds of now: live")
        #expect(await settles { h.session.cells[0].owner == .live && h.live.opens.count == 2 })
        h.session.stopAll()
    }

    @Test func goingLiveGivesTheRendererBackWithoutClearingIt() async {
        let h = SessionHarness(cameraCount: 1)
        await h.startLive()
        h.session.beginScrub()
        h.session.scrub(to: h.date(8.0))
        await h.until(advancing: false) { h.session.cells[0].owner == .recorded && h.sink(0).displayed.contains { $0.pts > 1_000_000_000_000 } }
        let resets = h.sink(0).resets
        h.session.goLive()
        #expect(await settles { h.session.cells[0].owner == .live && h.live.opens.count == 2 })
        h.live.send(FakeLiveSource.video(key: true), to: 1)
        #expect(await settles { h.session.cells[0].feed?.phase == .live })
        #expect(h.sink(0).resets > resets, "the feed resets the renderer, which keeps the picture")
        #expect(h.sink(0).clears == 0 && h.session.cells[0].showsPicture && h.session.cells[0].coverage == .live)
        #expect(h.session.cells[0].playback.isIdle)
        h.session.stopAll()
    }

    @Test func pauseHoldsThePictureAndPlayContinues() async {
        let h = SessionHarness(cameraCount: 1, withLive: false)
        h.session.setCameras(h.cameras)
        h.session.beginScrub()
        h.session.scrub(to: h.date(8.0))
        h.session.endScrub()
        await h.until(advancing: false) { h.sink(0).displayed.count >= 2 }
        h.time.advance(by: 1.0)
        h.session.pause()
        let paused = h.clock.position()
        #expect(h.clock.state.mode == .paused && abs(paused.timeIntervalSince(h.date(8.9))) < 0.01, "one second of time minus the 0.1 s start delay")
        h.time.advance(by: 5)
        #expect(h.clock.position() == paused)
        h.session.togglePlay()
        #expect(h.clock.isPlaying && h.clock.position() == paused)
        h.session.togglePlay()
        #expect(h.clock.state.mode == .paused)
        h.session.stopAll()
    }

    @Test func pausingLiveVideoStopsOnTheNewestRecordedFrame() async {
        let h = SessionHarness(cameraCount: 1, wallOffset: 2.5)   // the Mac's clock is 2.5 s after the newest recording
        await h.startLive()
        h.session.pause()
        // The keyframe of the last group comes first (a long lead-in), the frame itself after it: wait for the frame, not for the first picture.
        await h.until { h.sink(0).displayed.last.map { h.frameNumber($0.pts) } == 2_999 }
        #expect(h.clock.state.mode == .paused && h.clock.position() < h.timelines[0].end)
        #expect(h.session.cells[0].owner == .recorded)
        #expect(h.sink(0).displayed.last.map { h.frameNumber($0.pts) } == 2_999, "the last recorded frame")
        h.session.stopAll()
    }

    @Test func pausingLiveVideoOfACameraWithoutRecordingsFreezesTheLivePicture() async {
        let h = SessionHarness(cameraCount: 1)
        h.session.setCameras([UUID()])   // a camera the archive knows nothing about
        _ = await settles { h.live.opens.count == 1 }
        h.live.send(FakeLiveSource.video(key: true))
        _ = await settles { h.session.cells[0].feed?.hasPicture == true }
        h.session.pause()
        #expect(await settles { h.session.cells[0].isLiveFrozen && h.session.cells[0].feed?.isWanted == false })
        #expect(h.session.cells[0].showsPicture && h.session.cells[0].owner == .live, "the picture stays")
        h.session.togglePlay()
        #expect(await settles { h.session.cells[0].feed?.isWanted == true && !h.session.cells[0].isLiveFrozen }, "play from a frozen picture goes live")
        h.session.stopAll()
    }

    @Test func suspendReleasesEveryLeaseAndResumeGoesLiveAgain() async {
        let h = SessionHarness(cameraCount: 2)
        await h.startLive()
        h.session.suspend()
        #expect(await settles { h.live.cancelled.value == 2 }, "the leases are released")
        #expect(h.session.isSuspended)
        h.session.resume()
        #expect(await settles { h.live.opens.count == 4 }, "live cells go live again")
        h.session.stopAll()
    }

    @Test func suspendHoldsTheClockAndResumeShowsTheStillWithoutPlaying() async {
        let h = SessionHarness(cameraCount: 1, withLive: false)
        h.session.setCameras(h.cameras)
        h.session.beginScrub()
        h.session.scrub(to: h.date(8.0))
        h.session.endScrub()
        await h.until(advancing: false) { h.sink(0).displayed.count >= 2 }
        h.time.advance(by: 1)
        h.session.suspend()
        #expect(h.clock.state.mode == .paused, "the clock holds where it is while the viewer covers the page")
        let held = h.clock.position()
        await h.until(advancing: false) { h.session.cells[0].playback.isIdle && h.sink(0).clears == 1 }
        #expect(h.sink(0).clears == 1 && !h.session.cells[0].showsPicture, "the covered page lets go of its pictures")
        h.time.advance(by: 30)
        #expect(h.clock.position() == held)
        h.session.resume()
        await h.until(advancing: false) { h.session.cells[0].showsPicture && h.session.cells[0].playback.isIdle }
        #expect(h.clock.state.mode == .paused, "it does not start playing")
        #expect(abs((h.sink(0).displayed.last?.date ?? .distantPast).timeIntervalSince(held)) < 0.05, "an exact still at the position")
        h.session.stopAll()
    }

    @Test func theDriveLeavingWhileTheClockPlaysStopsTheClockAndItsReturnPlaysOnWithinFiveSeconds() async {
        let h = SessionHarness(cameraCount: 2, withLive: false)
        h.session.setCameras(h.cameras)
        h.session.beginScrub()
        h.session.scrub(to: h.date(8.0))
        h.session.endScrub()
        await h.until(advancing: false) { h.sink(0).displayed.count >= 2 && h.sink(1).displayed.count >= 2 }
        h.time.advance(by: 1.0)
        #expect(h.clock.isPlaying)
        h.source.failEverything(with: ArchiveError.fileGone)                  // the drive is pulled
        await h.until { h.session.driveHold != nil }                         // the cells run out of what they have read and find nothing more
        guard let held = h.session.driveHold?.position else {
            Issue.record("the session did not hold for the drive")
            h.session.stopAll()
            return
        }
        #expect(h.clock.state.mode == .paused, "the clock stands still")
        #expect(h.clock.position() == held)
        h.time.advance(by: 30)
        #expect(h.clock.position() == held, "and stays there however long the drive is gone")
        h.session.recheckDrive(driveBack: false)                              // 30 s since the last try: the cells ask again; the drive is still gone
        await h.settle()
        #expect(h.session.driveHold != nil && h.clock.state.mode == .paused)
        h.source.failEverything(with: nil)                                    // the drive is plugged in again
        h.session.recheckDrive(driveBack: false)                              // too soon after the last try: nothing is asked yet
        #expect(h.session.driveHold != nil)
        h.time.advance(by: NVRSession.driveRetryInterval + 0.1)               // within five seconds the cells read again
        h.session.recheckDrive(driveBack: false)
        await h.until { h.clock.isPlaying }
        #expect(h.clock.isPlaying && h.session.driveHold == nil, "playing goes on")
        #expect(abs(h.clock.position().timeIntervalSince(held)) < 1.0, "from where it stopped")
        h.session.stopAll()
    }

    @Test func aPersonWhoActsWhileTheDriveIsGoneCancelsTheHoldAndAReturnOfTheDriveAtOnceAsksAtOnce() async {
        let h = SessionHarness(cameraCount: 1, withLive: false)
        h.session.setCameras(h.cameras)
        h.session.beginScrub()
        h.session.scrub(to: h.date(8.0))
        h.session.endScrub()
        await h.until(advancing: false) { h.sink(0).displayed.count >= 2 }
        h.time.advance(by: 1.0)
        h.source.failEverything(with: ArchiveError.fileGone)
        await h.until { h.session.driveHold != nil }
        h.session.pause()                                                     // the person pauses: no automatic play when the drive returns
        #expect(h.session.driveHold == nil)
        h.source.failEverything(with: nil)
        h.session.recheckDrive(driveBack: true)
        await h.settle()
        #expect(h.clock.state.mode == .paused, "it stays paused")
        // The engine says recording works again: the cells are asked at once, without waiting for the retry period.
        h.session.play()
        h.source.failEverything(with: ArchiveError.fileGone)
        await h.until { h.session.driveHold != nil }
        h.source.failEverything(with: nil)
        h.session.recheckDrive(driveBack: true)
        await h.until { h.clock.isPlaying }
        #expect(h.clock.isPlaying && h.session.driveHold == nil, "driveBack asks at once")
        h.session.stopAll()
    }

    @Test func whenEveryCellIsInAGapTheClockJumpsToTheNextRecording() async {
        let h = SessionHarness(cameraCount: 2, gap: 15, withLive: false)   // 0...20 s and 35...55 s
        h.session.setCameras(h.cameras)
        h.session.beginScrub()
        h.session.scrub(to: h.date(25.0))
        h.session.endScrub()
        await h.until(advancing: false) { h.clock.state.wall == h.date(35.0) }
        #expect(h.clock.isPlaying && h.clock.state.wall == h.date(35.0), "release in a gap: jump to the next recording and play")
        await h.until(advancing: false) { h.session.cells.allSatisfy { $0.coverage == .recorded } }
        #expect(h.session.cells.allSatisfy { $0.coverage == .recorded })
        h.session.stopAll()
    }

    @Test func whenNothingFollowsTheGapTheClockGoesLive() async {
        let h = SessionHarness(cameraCount: 1, gap: 15, withLive: false)
        h.session.setCameras(h.cameras)
        h.session.beginScrub()
        h.session.scrub(to: h.date(500.0))   // after the newest recording, and long before now
        h.session.endScrub()
        await h.until(advancing: false) { h.clock.isLive }
        #expect(h.clock.isLive, "nothing follows: live")
        h.session.stopAll()
    }

    @Test func seekingMovesThePlayheadByTheStepAndKeepsPlayingIfItPlayed() async {
        let h = SessionHarness(cameraCount: 1, withLive: false)
        h.session.setCameras(h.cameras)
        h.session.beginScrub()
        h.session.scrub(to: h.date(33.0))
        h.session.endScrub()
        await h.until(advancing: false) { h.sink(0).displayed.count >= 2 }
        h.session.seek(by: -10)
        #expect(h.clock.isPlaying && abs(h.clock.position().timeIntervalSince(h.date(23.0))) < 0.2)
        h.session.pause()
        let at = h.clock.position()
        h.session.seek(by: 1)
        #expect(h.clock.state.mode == .paused && h.clock.position() == at.addingTimeInterval(1))
        h.session.stopAll()
    }
}
