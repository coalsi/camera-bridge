import BridgeEngine
import Foundation
import Synchronization
import Testing

/// A small deterministic generator, so a failure can be replayed.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// The key new test of the player (Mac spec 15): a target that never stops moving must not starve the picture, and whatever the order and timing of
/// scrubs, the last picture is the last request.
@Suite(.timeLimit(.minutes(3))) nonisolated struct CellPlaybackStarvationTests {
    @Test func aTargetThatMovesEveryEightMillisecondsStillGetsAPictureEveryEightyMilliseconds() async {
        // 300 s of one-fragment GOPs: nearly every move lands in another GOP. A keyframe read takes 40 ms; the dwell is 30 ms.
        let h = CellHarness(FakeTimeline(fragments: 150, gopFragments: 1))
        let time = h.time
        h.source.setLatency { kind in if kind == .keyframe { try await time.sleep(until: time.now + 0.040) } }
        var offset = 0.0
        for step in 0..<300 {   // 2.4 s of the pointer moving
            offset = 10 + Double(step) * 0.9
            h.request(offset, .keyframe)
            await h.quiesce()
            h.time.advance(by: 0.008)
            await h.quiesce()
        }
        let movingUntil = h.time.now
        await h.settle()
        let pictures = h.sink.displayed
        #expect(pictures.count >= 25, "at least one picture per 80 ms for 2.4 s: \(pictures.count)")
        let gaps = zip(pictures, pictures.dropFirst()).map { $1.uptime - $0.uptime }
        #expect((gaps.max() ?? 0) <= 0.09, "the longest wait for a picture: \(gaps.max() ?? 0) s")
        #expect(h.sink.resets == pictures.count, "every flush is followed by exactly one picture: no run was superseded before its picture was enqueued")
        #expect(pictures.last.map { h.frameNumber($0.pts) } == Int(offset / 2) * 50, "and the last picture is the keyframe of the last target's GOP")
        #expect(h.sink.clears == 0)
        _ = movingUntil
        await h.tearDown()
    }

    @Test func tenThousandRandomScrubsEndOnTheLastRequest() async {
        var random = SeededGenerator(seed: 20_261_010)
        let h = CellHarness(FakeTimeline(fragments: 150, gopFragments: 1))   // GOPs of 50 frames
        var last: (frame: Int, precision: ScrubPrecision) = (0, .exact)
        for _ in 0..<10_000 {
            // A target that is not within a millisecond of a frame time, so "the frame at or before it" is not a rounding question.
            let frame = Int.random(in: 0..<7_499, using: &random)
            let precision: ScrubPrecision = Int.random(in: 0..<3, using: &random) == 0 ? .keyframe : .exact
            h.request((Double(frame) + 0.4) / 25, precision)
            last = (frame, precision)
            switch Int.random(in: 0..<4, using: &random) {
            case 0: await h.settle()
            case 1:
                h.time.advance(by: Double.random(in: 0...0.05, using: &random))
                await Task.yield()
            default: await Task.yield()
            }
        }
        await h.settle()
        let key = last.frame / 50 * 50
        let shown = h.sink.displayed.last.map { h.frameNumber($0.pts) }
        switch last.precision {
        case .exact: #expect(shown == last.frame, "the last picture is the frame at the last target: \(String(describing: shown)) for \(last.frame)")
        case .keyframe: #expect(shown.map { (key...last.frame).contains($0) } == true, "a keyframe request ends on its GOP's keyframe, or on a frame after it that was reached by continuing")
        }
        var afterReset = false
        for event in h.sink.events {
            switch event {
            case .reset: afterReset = true
            case .show(let show):
                if afterReset { #expect(show.isKeyframe, "the first frame after a flush is a keyframe") }
                afterReset = false
            default: break
            }
        }
        #expect(h.sink.clears == 0)
        await h.tearDown()
    }
}
