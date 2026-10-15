import BridgeEngine
import FMP4
import Foundation
import MediaCore
import Synchronization
import Testing

/// A cell over a described timeline, a recording sink, a frame source and a clock that all run on virtual time. Not main-actor: these tests poll
/// and yield a lot, and must not hold up the main-actor tests that measure real time.
nonisolated final class CellHarness {
    let camera: UUID
    let time = VirtualTime()
    let sink: FakeArchiveSink
    let source: FakeFrameSource
    let archive: FakeArchiveReader
    let timeline: FakeTimeline
    let clock: PlaybackClock
    let cell: CellPlayback
    let fps: Double
    private let epoch = Mutex(0)

    init(_ timeline: FakeTimeline, fps: Double = 25, withSound: Bool = false, width: Int = 640) {
        camera = timeline.camera
        self.timeline = timeline
        self.fps = fps
        let time = time
        sink = FakeArchiveSink(uptime: { time.now })
        source = FakeFrameSource(fps: fps, withSound: withSound, width: width)
        archive = FakeArchiveReader(timeline)
        let wall = timeline.end.addingTimeInterval(3_600)
        let start = time.now
        clock = PlaybackClock(uptime: { time.now }, wall: { wall.addingTimeInterval(time.now - start) })
        cell = CellPlayback(sink: sink, archive: archive, camera: timeline.camera, clock: clock, now: { time.now }, sleep: { try await time.sleep(until: $0) },
                            frames: source)
    }

    func date(_ offset: TimeInterval) -> Date { timeline.start.addingTimeInterval(offset) }

    /// The number of the frame at `pts`, counted from the timeline's start.
    func frameNumber(_ pts: Int64) -> Int {
        Int(((Double(pts) / 90_000 - timeline.start.timeIntervalSinceReferenceDate) * fps).rounded())
    }

    var displayedFrames: [Int] { sink.displayed.map { frameNumber($0.pts) } }
    var allFrames: [Int] { sink.shows.map { frameNumber($0.pts) } }

    @discardableResult
    func request(_ offset: TimeInterval, _ precision: ScrubPrecision = .exact, playing: Bool = false) -> PlaybackDesire {
        let number = epoch.withLock { value -> Int in
            value += 1
            return value
        }
        let desire = PlaybackDesire(target: date(offset), precision: precision, playing: playing, epoch: number)
        cell.request(desire)
        return desire
    }

    /// Lets the cell finish what it was asked: virtual time passes only while the cell waits for it (the dwell, a read's latency).
    func settle() async {
        for _ in 0..<50_000 {
            if cell.isIdle { return }
            if time.sleeperCount > 0 {
                try? await Task.sleep(for: .microseconds(150))
                if !cell.isIdle, let wake = time.nextWake { time.advance(to: wake) }
            } else {
                await Task.yield()
            }
        }
    }

    func scrub(_ offset: TimeInterval, _ precision: ScrubPrecision = .exact) async {
        request(offset, precision)
        await settle()
    }

    /// Waits until the cell has nothing left to do without time passing: it is idle, or asleep until a time that has not come.
    func quiesce() async {
        var stable = 0
        for _ in 0..<20_000 {
            await Task.yield()
            if cell.isIdle || time.sleeperCount > 0 {
                stable += 1
                if stable >= 3 { return }
                try? await Task.sleep(for: .microseconds(60))
            } else {
                stable = 0
            }
        }
    }

    /// Lets time pass in small steps while a playing cell runs.
    func run(for seconds: TimeInterval, step: TimeInterval = 0.01) async {
        let end = time.now + seconds
        while time.now < end {
            try? await Task.sleep(for: .microseconds(200))
            time.advance(by: step)
        }
        try? await Task.sleep(for: .milliseconds(2))
    }

    func tearDown() async { await cell.stop() }
}

@Suite(.timeLimit(.minutes(2))) nonisolated struct CellPlaybackScrubTests {
    /// 120 s of video: 2 s fragments, a 10 s GOP (five fragments), 25 fps. Frame 0 is at the timeline's start.
    private func harness(gop: Int = 5, fragments: Int = 60) -> CellHarness {
        CellHarness(FakeTimeline(fragments: fragments, gopFragments: gop))
    }

    @Test func aKeyframeDesireShowsTheGopsKeyframeAndNothingElse() async {
        let h = harness()
        await h.scrub(7.0, .keyframe)
        #expect(h.sink.events.filter { $0 != .silence }.count == 2)
        #expect(h.sink.resets == 1 && h.displayedFrames == [0] && h.sink.shows.count == 1)
        #expect(h.sink.shows[0].isKeyframe && !h.sink.shows[0].decodeOnly)
        #expect(h.source.ids(of: .keyframe) == [h.timeline.fragments[0].id] && h.source.ids(of: .fragment).isEmpty, "one positioned read of the keyframe")
        #expect(h.source.ids(of: .initialization) == [h.timeline.fragments[0].id])
        #expect(h.cell.coverage == .recorded && h.cell.hasPicture)
        await h.tearDown()
    }

    @Test func anExactDesireWithALongLeadInShowsTheKeyframeFirstThenPrimesAndShowsTheTarget() async {
        let h = harness()
        await h.scrub(5.0)   // frame 125, in the third fragment of the GOP
        #expect(h.displayedFrames == [0, 125], "the keyframe, then the frame asked for: nothing in between is ever shown")
        #expect(h.allFrames == Array(0...125), "every frame in decode order, once: the keyframe is not given twice")
        #expect(h.sink.shows.filter(\.decodeOnly).count == 124)
        #expect(h.sink.resets == 1)
        #expect(h.source.ids(of: .keyframe) == [h.timeline.fragments[0].id])
        #expect(h.source.ids(of: .fragment) == h.timeline.fragments[0...2].map(\.id), "the fragments are read one at a time")
        #expect(h.source.peakInFlight == 1)
        #expect(h.cell.coverage == .recorded)
        await h.tearDown()
    }

    @Test func aShortLeadInGoesStraightToTheExactFrame() async {
        let h = harness()
        await h.scrub(0.2)   // frame 5: five frames after the keyframe, within the budget of twelve
        #expect(h.displayedFrames == [5])
        #expect(h.allFrames == Array(0...5))
        #expect(h.sink.shows[0].isKeyframe && h.sink.shows[0].decodeOnly, "the keyframe primes the decoder and is not shown")
        #expect(h.source.ids(of: .keyframe).isEmpty, "no preview: the exact frame is as quick")
        #expect(h.source.ids(of: .fragment) == [h.timeline.fragments[0].id])
        await h.tearDown()
    }

    @Test func aTargetOnTheKeyframeShowsItAtOnce() async {
        let h = harness()
        await h.scrub(10.0)   // frame 250: the first frame of the second GOP
        #expect(h.displayedFrames == [250] && h.sink.shows.count == 1 && h.sink.shows[0].isKeyframe && !h.sink.shows[0].decodeOnly)
        await h.tearDown()
    }

    @Test func aForwardMoveInTheSameGopNeedsNoResetAndNoKeyframeRead() async {
        let h = harness()
        await h.scrub(5.0)
        let eventsBefore = h.sink.events.count, keyReads = h.source.ids(of: .keyframe).count, fragmentReads = h.source.ids(of: .fragment).count
        await h.scrub(5.4)   // frame 135: still in the third fragment
        let added = Array(h.sink.shows.suffix(from: h.sink.shows.count - (h.sink.events.count - eventsBefore - 1)))
        #expect(h.displayedFrames == [0, 125, 135])
        #expect(added.map { h.frameNumber($0.pts) } == Array(126...135), "the frames in between, then the target")
        #expect(added.dropLast().allSatisfy(\.decodeOnly) && !added.last!.decodeOnly)
        #expect(h.sink.resets == 1, "no flush")
        #expect(h.source.ids(of: .keyframe).count == keyReads && h.source.ids(of: .fragment).count == fragmentReads, "nothing read")
        await h.tearDown()
    }

    @Test func aForwardMoveIntoTheNextFragmentOfTheGopReadsOnlyThatFragment() async {
        let h = harness()
        await h.scrub(5.0)
        await h.scrub(7.0)   // frame 175: the fourth fragment, same GOP
        #expect(h.displayedFrames == [0, 125, 175])
        #expect(h.allFrames == Array(0...175), "the decode order is unbroken")
        #expect(h.sink.resets == 1)
        #expect(h.source.ids(of: .fragment) == h.timeline.fragments[0...3].map(\.id), "only the fragment after the last one is read")
        await h.tearDown()
    }

    @Test func aBackwardMoveRestartsAtTheKeyframe() async {
        let h = harness()
        await h.scrub(5.0)
        await h.scrub(3.0)   // frame 75
        #expect(h.sink.resets == 2)
        #expect(h.displayedFrames == [0, 125, 0, 75])
        await h.tearDown()
    }

    /// Seconds of virtual time between the keyframe of the first group of pictures and the one of the second, scrubbed to straight after.
    private func gapBetweenTwoKeyframes(width: Int) async -> TimeInterval {
        let h = CellHarness(FakeTimeline(fragments: 60, gopFragments: 5), width: width)
        await h.scrub(5.0, .keyframe)
        await h.scrub(12.0, .keyframe)
        let shows = h.sink.shows.filter { $0.isKeyframe }
        await h.tearDown()
        return shows.count == 2 ? shows[1].uptime - shows[0].uptime : -1
    }

    @Test func aPictureTooWideForTheHardwareDecoderGetsTimeToDecodeBeforeTheNextStepOfADrag() async {
        let hardware = await gapBetweenTwoKeyframes(width: 2_688)
        let software = await gapBetweenTwoKeyframes(width: 4_256)
        #expect(hardware >= 0 && hardware < CellPlayback.softwareDecodeDwell, "hardware sized: the short dwell (\(hardware) s)")
        #expect(software >= CellPlayback.softwareDecodeDwell - 0.001, "4256 wide: the long one (\(software) s) vs hardware \(hardware)")
    }

    @Test func aMoveToAnotherGopRestarts() async {
        let h = harness()
        await h.scrub(5.0)
        await h.scrub(12.0)   // frame 300, in the second GOP: key at frame 250, 50 frames after it
        #expect(h.sink.resets == 2)
        #expect(h.displayedFrames == [0, 125, 250, 300])
        #expect(h.source.ids(of: .keyframe) == [h.timeline.fragments[0].id, h.timeline.fragments[5].id])
        await h.tearDown()
    }

    @Test func aKeyframeMoveInsideTheGopThatIsOnScreenReadsNothing() async {
        let h = harness()
        await h.scrub(7.0, .keyframe)
        let reads = h.source.reads.count, resets = h.sink.resets
        await h.scrub(3.0, .keyframe)   // the same GOP: its keyframe is what is showing
        await h.scrub(9.0, .keyframe)
        #expect(h.source.reads.count == reads && h.sink.resets == resets && h.displayedFrames == [0])
        await h.tearDown()
    }

    @Test func aFarForwardKeyframeMoveInTheSameGopPrefersTheKeyframeToADeepLeadIn() async {
        let h = harness()
        await h.scrub(7.0, .keyframe)
        await h.scrub(9.0, .exact)   // exact: the cursor continues from the keyframe (no reset) up to frame 225
        #expect(h.sink.resets == 1 && h.displayedFrames == [0, 225])
        await h.tearDown()
    }

    @Test func theFirstFrameAfterEveryResetIsAKeyframeAndNothingIsEverCleared() async {
        let h = harness(gop: 3)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<60 {
            await h.scrub(Double.random(in: 0..<119, using: &generator), Bool.random(using: &generator) ? .keyframe : .exact)
        }
        var afterReset = false
        for event in h.sink.events {
            switch event {
            case .reset: afterReset = true
            case .show(let show):
                if afterReset { #expect(show.isKeyframe, "a delta frame after a reset has no reference") }
                afterReset = false
            default: break
            }
        }
        #expect(h.sink.clears == 0, "a scrub never removes the picture from the layer")
        #expect(!h.sink.displayed.isEmpty)
        await h.tearDown()
    }

    @Test func aTargetBetweenFramesShowsTheFrameBeforeIt() async {
        let h = harness()
        await h.scrub(5.03)   // frame 125 is at 5.00 s, frame 126 at 5.04 s
        #expect(h.displayedFrames.last == 125)
        await h.scrub(5.04)
        #expect(h.displayedFrames.last == 126)
        await h.tearDown()
    }

    @Test func aStateWithoutReadinessShowsLoadingAndReadsNothing() async {
        let h = harness()
        h.archive.setReady(false)
        await h.scrub(5.0)
        #expect(h.cell.coverage == .loading && h.source.reads.isEmpty && h.sink.shows.isEmpty && !h.cell.hasPicture)
        h.archive.setReady(true)
        await h.scrub(5.0)
        #expect(h.cell.coverage == .recorded)
        await h.tearDown()
    }
}
