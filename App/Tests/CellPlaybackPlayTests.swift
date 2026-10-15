import BridgeEngine
import FMP4
import Foundation
import MediaCore
import Synchronization
import Testing

/// Playing at 1x: each frame when its time comes, read-ahead, being late, files and gaps, the end of the recordings, sound.
@Suite(.timeLimit(.minutes(2))) nonisolated struct CellPlaybackPlayTests {
    /// Starts playing at `offset` seconds into the timeline: the clock plays from there (starting 0.1 s from now) and the cell is told to.
    private func play(_ h: CellHarness, from offset: TimeInterval) async {
        h.clock.play(from: h.date(offset), startingIn: 0.1)
        h.request(offset, .exact, playing: true)
        // The exact still is shown first; wait for it without letting time pass.
        for _ in 0..<2_000 where h.sink.displayed.isEmpty { try? await Task.sleep(for: .microseconds(200)) }
    }

    private func harness(withSound: Bool = false, gop: Int = 5) -> CellHarness {
        CellHarness(FakeTimeline(fragments: 60, gopFragments: gop), withSound: withSound)
    }

    @Test func eachFrameIsShownWhenItsTimeComesAndNeverBefore() async {
        let h = harness()
        let started = h.time.now
        await play(h, from: 1.0)   // frame 25 is the still
        await h.run(for: 1.0)
        let frames = h.displayedFrames
        #expect(frames.prefix(2) == [0, 25] && frames.count > 15, "the keyframe preview, the exact still at frame 25, then one frame every 40 ms: \(frames.count)")
        #expect(zip(frames.dropFirst(), frames.dropFirst(2)).allSatisfy { $1 == $0 + 1 }, "no frame skipped, none out of order")
        for show in h.sink.displayed.dropFirst(2) {
            let due = started + 0.1 + (Double(h.frameNumber(show.pts)) - 25) / 25
            #expect(show.uptime >= due - 0.0001, "frame \(h.frameNumber(show.pts)) shown at \(show.uptime - started), due at \(due - started)")
            #expect(show.uptime - due < 0.05, "and not much later: the test steps time by 10 ms")
        }
        #expect(h.sink.shows.filter(\.decodeOnly).count == 24, "the exact still primed the decoder with 24 frames; playing gives only displayable ones")
        #expect(h.sink.shows.filter { !$0.decodeOnly && h.frameNumber($0.pts) > 25 }.allSatisfy { $0.uptime > started }, "after the still")
        await h.tearDown()
    }

    @Test func theNextFragmentIsReadAheadWithAtMostOneReadInFlight() async {
        let h = harness()
        await play(h, from: 1.0)   // one second of the first fragment is left: less than three
        await h.run(for: 0.3)
        #expect(h.source.ids(of: .fragment).contains(h.timeline.fragments[1].id), "read before it is needed")
        await h.run(for: 4.0)
        #expect(h.source.ids(of: .fragment).contains(h.timeline.fragments[2].id))
        #expect(h.source.peakInFlight == 1)
        let frames = h.displayedFrames.dropFirst()
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1 == $0 + 1 }, "across fragments without a hole")
        await h.tearDown()
    }

    @Test func aLateCellGivesDeltaFramesDecodeOnlyUntilItIsOnTime() async {
        let h = harness()
        await play(h, from: 1.0)
        await h.run(for: 0.3)
        let before = h.sink.shows.count, resets = h.sink.resets
        h.time.advance(by: 0.3)   // the cell was held up: it wakes 0.3 s late
        await h.run(for: 0.3)
        let after = Array(h.sink.shows.suffix(from: before))
        let skipped = after.prefix { $0.decodeOnly }.count
        #expect((3...8).contains(skipped), "the frames that are more than 120 ms late are decoded and not shown: \(skipped)")
        #expect(after.contains { !$0.decodeOnly }, "and it shows again when it is on time")
        #expect(h.sink.resets == resets, "late by less than half a second: no restart")
        let frames = h.allFrames
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1 == $0 + 1 }, "every frame still reached the decoder in order")
        await h.tearDown()
    }

    @Test func moreThanHalfASecondLateCatchesUpToThePlayhead() async {
        let h = harness()
        await play(h, from: 1.0)
        await h.run(for: 0.3)
        let before = h.sink.shows.count
        h.time.advance(by: 1.0)
        await h.run(for: 0.5)
        // The cell restarts at the playhead: an exact still there. The decoder is already on this GOP, so it is reached by priming, not by a flush.
        let after = Array(h.sink.shows.suffix(from: before))
        #expect(after.prefix { $0.decodeOnly }.count >= 20, "about a second of frames, decode-only")
        let stills = after.filter { !$0.decodeOnly }
        let firstStill = stills.first?.date ?? .distantPast
        let position = h.clock.position(atUptime: stills.first?.uptime ?? 0)
        #expect(abs(firstStill.timeIntervalSince(position)) < 0.05, "the still belongs to the playhead")
        #expect(zip(stills, stills.dropFirst()).allSatisfy { h.frameNumber($1.pts) == h.frameNumber($0.pts) + 1 }, "and it plays on from there")
        await h.tearDown()
    }

    @Test func aRendererThatRestartedByItselfRestartsPlaybackAtThePlayhead() async {
        let h = harness()
        await play(h, from: 1.0)
        await h.run(for: 0.3)
        let resets = h.sink.resets
        h.sink.setRestarts(1)
        await h.run(for: 0.3)
        #expect(h.sink.resets == resets + 1)
        let frames = h.displayedFrames
        #expect(frames.last ?? 0 > 30)
        await h.tearDown()
    }

    @Test func twoDecoderFailuresInOneGopSkipToTheNextGopAndTheNeighboursKeepPlaying() async {
        let h = harness()                                  // 2 s fragments, 10 s groups: the first group is 0...10 s, the next one starts at fragment 5
        await play(h, from: 1.0)
        await h.run(for: 0.3)
        h.sink.setRestarts(1)                              // the first failure in this group: the cell restarts at the playhead
        await h.run(for: 0.4)
        #expect(h.sink.resets >= 2 && h.cell.coverage != .unreadable, "one failure is a restart")
        h.sink.setRestarts(2)                              // the second failure of the same group: skip it
        await h.run(for: 0.3)
        #expect(h.cell.coverage == .unreadable, "the cell says the part cannot be read; the picture stays")
        let shownBefore = h.displayedFrames
        await h.run(for: 9.5)                              // the playhead reaches the next group at 10 s
        #expect(h.cell.coverage == .recorded, "and plays again at the next group")
        let after = h.displayedFrames.filter { !shownBefore.contains($0) }
        #expect(after.first == 250 && h.sink.shows.first { h.frameNumber($0.pts) == 250 }?.isKeyframe == true, "the next group's keyframe, frame 250")
        #expect(!h.displayedFrames.contains { $0 > 100 && $0 < 250 }, "nothing from the rest of the failing group is shown")
        await h.tearDown()
    }

    @Test func oneFailureInEachOfTwoGopsRestartsTwiceAndSkipsNothing() async {
        let h = harness()
        await play(h, from: 8.0)
        await h.run(for: 0.3)
        h.sink.setRestarts(1)                              // a failure in the first group (it ends at 10 s)
        await h.run(for: 2.5)                              // the restart at the playhead, then on into the second group
        #expect(h.displayedFrames.contains { $0 >= 250 }, "playing in the second group")
        h.sink.setRestarts(2)                              // a failure in another group is its first, not the second of one group
        await h.run(for: 1.0)
        #expect(h.cell.coverage != .unreadable)
        let frames = h.displayedFrames.drop { $0 < 250 }
        let shown = Set(frames)
        #expect((250...(frames.max() ?? 250)).allSatisfy(shown.contains), "no frame of the second group was skipped: the restart shows its keyframe again, then plays on from the playhead")
        await h.tearDown()
    }

    @Test func playingIntoAGapHoldsThePictureAndResumesWhenThePlayheadReachesTheNextRecording() async {
        let start = FakeTimeline.origin
        let h = CellHarness(FakeTimeline(camera: UUID(), runs: [.init(start: start, fragments: 5, gopFragments: 5), .init(start: start.addingTimeInterval(14), fragments: 5, gopFragments: 5)]))
        await play(h, from: 8.0)   // the first file ends at 10 s; the next begins at 14 s
        await h.run(for: 2.5)
        #expect(h.cell.coverage == .noRecording(next: h.date(14), recordingOff: false), "the end of the first file")
        let heldAt = h.sink.displayed.count
        #expect(h.displayedFrames.last == 249)
        await h.run(for: 2.0)
        #expect(h.sink.displayed.count == heldAt, "nothing is shown in the gap")
        await h.run(for: 2.5)
        #expect(h.cell.coverage == .recorded)
        let last = h.sink.displayed.last
        #expect(h.frameNumber(last?.pts ?? 0) >= 350, "frame 350 is the second file's first")
        #expect(h.sink.shows.first { h.frameNumber($0.pts) == 350 }?.isKeyframe == true)
        #expect(h.sink.resets == 1, "the new file begins with a keyframe: no flush needed")
        await h.tearDown()
    }

    @Test func playingToTheEndOfTheRecordingsReportsItAndStopsAsking() async {
        let h = CellHarness(FakeTimeline(fragments: 3, gopFragments: 3))   // six seconds
        await play(h, from: 4.0)
        await h.run(for: 3.0)
        #expect(h.cell.coverage == .noRecording(next: nil, recordingOff: false))
        let lookups = h.archive.lookups
        await h.run(for: 40.0, step: 0.25)
        #expect(h.cell.isIdle, "after \(CellPlayback.endPollLimit) quarter seconds it gives up")
        #expect(h.archive.lookups - lookups <= CellPlayback.endPollLimit * 2 + 10)
        await h.tearDown()
    }

    @Test func soundIsGivenToTheSinkAFifthOfASecondEarlyAndOnlyWhenItIsOn() async {
        let silent = harness(withSound: true)
        await play(silent, from: 1.0)
        await silent.run(for: 1.0)
        #expect(silent.sink.plays.isEmpty, "off by default")
        await silent.tearDown()

        let h = harness(withSound: true)
        h.cell.setAudio(true)
        let started = h.time.now
        await play(h, from: 1.0)
        await h.run(for: 1.0)
        let plays = h.sink.plays
        #expect(plays.count >= 10, "64 ms frames from the playhead on: \(plays.count)")
        // The frame whose time is `date` is due at started + 0.1 + (date - 1 s); it goes out `audioLead` earlier (the test steps time by 10 ms).
        for play in plays {
            let due = started + 0.1 + play.date.timeIntervalSince(h.date(1.0))
            #expect(play.uptime >= due - CellPlayback.audioLead - 0.0001 && play.uptime <= due - CellPlayback.audioLead + 0.03, "audio at \(play.date.timeIntervalSince(h.date(0)))")
        }
        #expect(zip(plays, plays.dropFirst()).allSatisfy { $1.date > $0.date })
        await h.tearDown()
    }

    @Test func aScrubAfterPlayingSilencesTheSound() async {
        let h = harness(withSound: true)
        h.cell.setAudio(true)
        await play(h, from: 1.0)
        await h.run(for: 0.5)
        let before = h.sink.events.filter { $0 == .silence }.count
        await h.scrub(30.0)
        #expect(h.sink.events.filter { $0 == .silence }.count > before)
        await h.tearDown()
    }
}
