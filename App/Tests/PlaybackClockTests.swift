import Foundation
import Synchronization
import Testing

/// Time the test moves by hand: the clock's `uptime` (stops in sleep) and the Mac's wall clock (can be stepped) are separate.
nonisolated final class ManualTime: Sendable {
    private let state: Mutex<(uptime: TimeInterval, wall: Date)>

    init(uptime: TimeInterval = 1_000, wall: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) {
        state = Mutex((uptime, wall))
    }

    var uptime: TimeInterval { state.withLock { $0.uptime } }
    var wall: Date { state.withLock { $0.wall } }

    /// Real time passing: both clocks move.
    func advance(_ seconds: TimeInterval) {
        state.withLock {
            $0.uptime += seconds
            $0.wall = $0.wall.addingTimeInterval(seconds)
        }
    }

    /// The wall clock is set to another time (an NTP step, a changed time zone), uptime does not move.
    func stepWall(by seconds: TimeInterval) { state.withLock { $0.wall = $0.wall.addingTimeInterval(seconds) } }

    func makeClock() -> PlaybackClock {
        PlaybackClock(uptime: { [self] in uptime }, wall: { [self] in wall })
    }
}

@Suite struct PlaybackClockTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 790_000_000)

    @Test func aNewClockIsLiveAndFollowsTheMacsClock() {
        let time = ManualTime()
        let clock = time.makeClock()
        #expect(clock.state.mode == .live && clock.isLive)
        #expect(clock.position() == time.wall)
        time.advance(3)
        #expect(clock.position() == time.wall)
    }

    @Test func scrubbingPausesAtTheDateAndHoldsIt() {
        let time = ManualTime()
        let clock = time.makeClock()
        clock.scrub(to: t0)
        time.advance(10)
        #expect(clock.state.mode == .paused && clock.position() == t0)
        clock.scrub(to: t0.addingTimeInterval(-30))
        #expect(clock.position() == t0.addingTimeInterval(-30), "a plain store: the newest scrub wins at once")
    }

    @Test func playingRunsAtOneTimesFromTheDate() {
        let time = ManualTime()
        let clock = time.makeClock()
        clock.play(from: t0)
        #expect(clock.isPlaying && clock.position() == t0)
        time.advance(2.5)
        #expect(clock.position() == t0.addingTimeInterval(2.5))
        #expect(clock.position(atUptime: time.uptime + 10) == t0.addingTimeInterval(12.5), "any instant, for a cell that sleeps until a frame is due")
    }

    @Test func aStartDelayHoldsThePositionUntilItsInstantAndIsCappedAtOneTenthOfASecond() {
        let time = ManualTime()
        let clock = time.makeClock()
        clock.play(from: t0, startingIn: 0.1)
        time.advance(0.04)
        #expect(clock.position() == t0, "not started yet: the cells are still priming")
        time.advance(0.16)
        #expect(clock.position() == t0.addingTimeInterval(0.1))
        clock.play(from: t0, startingIn: 5)
        #expect(clock.state.since == time.uptime + PlaybackClock.maximumStartDelay)
        clock.play(from: t0, startingIn: -1)
        #expect(clock.state.since == time.uptime)
    }

    @Test func aSteppedWallClockDoesNotMoveAPlayingClock() {
        let time = ManualTime()
        let clock = time.makeClock()
        clock.play(from: t0)
        time.advance(4)
        time.stepWall(by: 3_600)   // the time zone changed, or NTP stepped the clock
        #expect(clock.position() == t0.addingTimeInterval(4))
        clock.pause()
        #expect(clock.position() == t0.addingTimeInterval(4))
    }

    @Test func pausingFreezesWhereThePositionIs() {
        let time = ManualTime()
        let clock = time.makeClock()
        clock.play(from: t0)
        time.advance(7)
        clock.pause()
        time.advance(100)
        #expect(clock.state.mode == .paused && clock.position() == t0.addingTimeInterval(7))

        let live = time.makeClock()
        live.pause()
        let pausedAt = time.wall
        time.advance(20)
        #expect(live.position() == pausedAt, "pausing a live clock pauses at the Mac's time")
    }

    @Test func goingLiveFollowsTheWallClockAgain() {
        let time = ManualTime()
        let clock = time.makeClock()
        clock.play(from: t0)
        clock.goLive()
        time.advance(9)
        #expect(clock.isLive && clock.position() == time.wall)
    }

    @Test func aReleaseWithinFiveSecondsOfNowOrAfterItGoesLive() {
        let time = ManualTime()
        let clock = time.makeClock()
        let now = time.wall
        #expect(PlaybackClock.liveSnap == 5)
        #expect(clock.shouldGoLive(releasingAt: now))
        #expect(clock.shouldGoLive(releasingAt: now.addingTimeInterval(30)), "after now: live")
        #expect(clock.shouldGoLive(releasingAt: now.addingTimeInterval(-5)), "exactly 5 s behind is still live")
        #expect(!clock.shouldGoLive(releasingAt: now.addingTimeInterval(-5.001)))
        time.advance(60)
        #expect(!clock.shouldGoLive(releasingAt: now), "the question is asked against the wall clock now")
    }

    @Test func aFrameIsDueWhenTheClockReachesItsTime() {
        let time = ManualTime()
        let clock = time.makeClock()
        clock.play(from: t0, startingIn: 0.1)
        let state = clock.state
        #expect(PlaybackClock.uptime(of: t0, in: state) == time.uptime + 0.1)
        #expect(PlaybackClock.uptime(of: t0.addingTimeInterval(2), in: state) == time.uptime + 2.1)
        #expect(PlaybackClock.uptime(of: t0.addingTimeInterval(-1), in: state) < time.uptime, "a frame before the start is already late")
    }
}
