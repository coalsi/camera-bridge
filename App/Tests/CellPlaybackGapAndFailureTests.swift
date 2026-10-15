import BridgeEngine
import FMP4
import Foundation
import MediaCore
import Synchronization
import Testing

/// Gaps between recordings, failures of the drive and of single fragments, the renderer's back-pressure, and stopping.
@Suite(.timeLimit(.minutes(2))) nonisolated struct CellPlaybackGapAndFailureTests {
    /// Two files: 0 to 20 s and 30 to 50 s (a gap of ten seconds), a 10 s GOP each, 25 fps.
    private func gapped() -> CellHarness {
        let start = FakeTimeline.origin
        return CellHarness(FakeTimeline(camera: UUID(), runs: [.init(start: start, fragments: 10, gopFragments: 5), .init(start: start.addingTimeInterval(30), fragments: 10, gopFragments: 5)]))
    }

    @Test func aGapKeepsThePictureAndNamesTheNextRecording() async {
        let h = gapped()
        await h.scrub(15.0)
        let events = h.sink.events.count
        await h.scrub(25.0)   // nothing was recorded then
        #expect(h.cell.coverage == .noRecording(next: h.date(30), recordingOff: false))
        #expect(h.sink.events.count == events + 1, "only the silence call: no reset, no frame, nothing cleared")
        #expect(h.cell.hasPicture, "the last picture stays")
        await h.scrub(35.0)
        #expect(h.cell.coverage == .recorded && h.displayedFrames.last == 875)
        await h.tearDown()
    }

    @Test func beforeTheOldestAndAfterTheNewestThereIsNoRecording() async {
        let h = gapped()
        await h.scrub(-5)
        #expect(h.cell.coverage == .noRecording(next: h.date(0), recordingOff: false) && !h.cell.hasPicture)
        await h.scrub(500)
        #expect(h.cell.coverage == .noRecording(next: nil, recordingOff: false))
        #expect(h.sink.shows.isEmpty && h.source.reads.isEmpty)
        await h.tearDown()
    }

    @Test func aGapUnderASecondIsContinuous() async {
        let start = FakeTimeline.origin
        let h = CellHarness(FakeTimeline(camera: UUID(), runs: [.init(start: start, fragments: 10, gopFragments: 5),
                                                                .init(start: start.addingTimeInterval(20.4), fragments: 10, gopFragments: 5)]))
        await h.scrub(15.0)
        await h.scrub(20.2)   // between the files, 0.4 s apart
        #expect(h.cell.coverage == .recorded, "the picture is held: this is not a gap people should be told about")
        let fresh = CellHarness(FakeTimeline(camera: UUID(), runs: [.init(start: start, fragments: 10, gopFragments: 5),
                                                                    .init(start: start.addingTimeInterval(20.4), fragments: 10, gopFragments: 5)]))
        await fresh.scrub(20.2)
        #expect(fresh.cell.coverage == .recorded && fresh.cell.hasPicture, "with no picture yet, the last frame of the first file is shown")
        #expect(fresh.displayedFrames.last == 499)
        await h.tearDown()
        await fresh.tearDown()
    }

    @Test func aDriveThatIsNotThereKeepsThePictureAndSaysSo() async {
        let h = gapped()
        await h.scrub(5.0)
        h.source.failEverything(with: ArchiveError.fileGone)
        await h.scrub(35.0)
        #expect(h.cell.coverage == .driveMissing && h.cell.hasPicture && h.sink.clears == 0)
        h.source.failEverything(with: ArchiveError.timedOut)
        await h.scrub(36.0, .keyframe)
        #expect(h.cell.coverage == .driveMissing)
        h.source.failEverything(with: nil)
        await h.scrub(35.0)
        #expect(h.cell.coverage == .recorded, "it comes back with the drive")
        await h.tearDown()
    }

    @Test func aDamagedFragmentIsUnreadableAndItsNeighboursStillPlay() async {
        let h = gapped()
        h.source.fail(fragment: h.timeline.fragments[2].id, with: FMP4Error.malformedBox(offset: 12, reason: "test"))
        await h.scrub(5.0)   // frame 125 needs fragment 2
        #expect(h.cell.coverage == .unreadable)
        await h.scrub(11.0, .exact)   // fragment 5: a keyframe fragment of its own GOP
        #expect(h.cell.coverage == .recorded && h.displayedFrames.last == 275)
        await h.tearDown()
    }

    @Test func aRendererThatIsBehindMakesTheCellWaitInsteadOfOverflowing() async {
        // A 60 s GOP (30 fragments): the lead-in to 50 s is 1,250 frames, ten times the queue's limit.
        let h = CellHarness(FakeTimeline(fragments: 40, gopFragments: 30))
        h.sink.queueFrames(true)
        h.request(50.0)
        var guardCount = 0
        while !h.cell.isIdle, guardCount < 100_000 {
            guardCount += 1
            h.sink.drain(25)   // the renderer takes frames off the queue
            try? await Task.sleep(for: .microseconds(150))
            if let wake = h.time.nextWake { h.time.advance(to: wake) }
        }
        #expect(h.cell.isIdle)
        #expect(h.sink.peakQueued <= CellPlayback.maximumQueued, "never above 120: overflow would destroy the lead-in")
        #expect(h.sink.peakQueued >= CellPlayback.maximumQueued - 5, "and it did wait for room")
        #expect(h.displayedFrames == [0, 1_250] && h.allFrames == Array(0...1_250))
        #expect(h.sink.resets == 1)
        await h.tearDown()
    }

    @Test func aChangedRestartCountOfTheSinkMakesTheNextMoveStartOver() async {
        let h = CellHarness(FakeTimeline(fragments: 60, gopFragments: 5))
        await h.scrub(5.0)
        h.sink.setRestarts(1)   // the renderer lost its place by itself
        await h.scrub(5.4)
        #expect(h.sink.resets == 2, "no continuing from frames the renderer no longer has")
        #expect(h.displayedFrames == [0, 125, 0, 135])
        await h.scrub(5.8)
        #expect(h.sink.resets == 2, "and from there it continues again")
        await h.tearDown()
    }

    @Test func aRunThatIsSupersededDuringItsKeyframeReadStillShowsTheKeyframeItRead() async {
        let h = CellHarness(FakeTimeline(fragments: 60, gopFragments: 1))
        let time = h.time
        h.source.setLatency { kind in if kind == .keyframe { try await time.sleep(until: time.now + 0.04) } }
        h.request(10.0, .keyframe)
        while h.time.sleeperCount == 0 { await Task.yield() }   // inside the read
        h.request(50.0, .keyframe)   // a newer target while the read is in flight
        await h.settle()
        #expect(h.displayedFrames == [250, 1_250], "the first keyframe was read, so it is shown; then the newest target")
        #expect(h.sink.resets == 2)
        await h.tearDown()
    }

    @Test func idleWaitsForTheReadInFlightAndThenShowsNothingMore() async {
        let h = CellHarness(FakeTimeline(fragments: 60, gopFragments: 1))
        let time = h.time
        h.source.setLatency { kind in if kind == .keyframe { try await time.sleep(until: time.now + 0.5) } }
        h.request(10.0, .keyframe)
        while h.time.sleeperCount == 0 { await Task.yield() }
        let finished = Mutex(false)
        let cell = h.cell
        let waiting = Task {
            await cell.idle()
            finished.withLock { $0 = true }
        }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!finished.withLock { $0 }, "a read cannot be cancelled: idle waits for it")
        h.time.advance(by: 0.5)
        await waiting.value
        let shown = h.sink.shows.count
        #expect(h.cell.isIdle && !h.cell.hasPicture && h.cell.coverage == .loading, "an idle cell shows nothing of its own")
        h.request(40.0, .keyframe)   // and it can be used again
        await h.settle()
        #expect(h.sink.shows.count == shown + 1 && h.cell.hasPicture)
        await h.tearDown()
    }

    @Test func stopLeavesNoLateWriteToTheSink() async {
        let h = CellHarness(FakeTimeline(fragments: 60, gopFragments: 1))
        let time = h.time
        h.source.setLatency { kind in if kind == .keyframe { try await time.sleep(until: time.now + 10) } }
        h.request(10.0, .keyframe)
        while h.time.sleeperCount == 0 { await Task.yield() }
        let cell = h.cell
        let stopping = Task { await cell.stop() }
        try? await Task.sleep(for: .milliseconds(20))
        h.time.advance(by: 10)
        await stopping.value
        let shown = h.sink.shows.count
        h.request(20.0)   // a stopped cell ignores everything
        try? await Task.sleep(for: .milliseconds(30))
        #expect(h.sink.shows.count == shown && h.cell.isIdle)
    }
}
