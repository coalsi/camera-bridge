import BridgeSupport
import Foundation
import Synchronization
import Testing
@testable import BridgeEngine

/// The motion shadow test's classifier: periods of the camera's own events and of built-in motion detection are grouped into
/// events and classed as both / camera only / built-in only, with the start delay of the ones both saw.
@Suite struct MotionShadowComparatorTests {
    typealias Comparator = MotionShadowComparator

    private func at(_ seconds: Double) -> Duration { .seconds(seconds) }

    /// Feeds `(source, active, seconds)` steps, then lets time pass to `end` seconds; returns the finished events.
    private func run(_ steps: [(Comparator.Source, Bool, Double)], until end: Double, limits: Comparator.Limits = .init()) -> (Comparator, [Comparator.Event]) {
        var comparator = Comparator(limits: limits)
        var events: [Comparator.Event] = []
        for (source, active, seconds) in steps { events += comparator.record(source, active: active, at: at(seconds)) }
        events += comparator.advance(to: at(end))
        return (comparator, events)
    }

    @Test func overlappingPeriodsAreOneEventBothSawWithTheStartDifference() {
        let (comparator, events) = run([(.camera, true, 10), (.builtIn, true, 10.75), (.camera, false, 30), (.builtIn, false, 40)], until: 60)
        #expect(events.map(\.outcome) == [.both(delay: .milliseconds(750))], "built-in minus camera")
        #expect(events.first?.started == at(10) && events.first?.ended == at(40))
        #expect(comparator.rolling(at: at(60)) == MotionShadowTotals(both: 1, cameraOnly: 0, builtInOnly: 0, medianDelaySeconds: 0.75))
    }

    @Test func aBuiltInPeriodThatStartsFirstHasANegativeDelay() {
        let (_, events) = run([(.builtIn, true, 5), (.camera, true, 6.5), (.builtIn, false, 20), (.camera, false, 20)], until: 40)
        #expect(events.map(\.outcome) == [.both(delay: .milliseconds(-1_500))])
    }

    @Test func aCameraPeriodWithoutABuiltInPeriodIsCameraOnly() {
        let (comparator, events) = run([(.camera, true, 10), (.camera, false, 25)], until: 40)
        #expect(events.map(\.outcome) == [.cameraOnly], "built-in missed it")
        #expect(comparator.rolling(at: at(40)) == MotionShadowTotals(both: 0, cameraOnly: 1, builtInOnly: 0, medianDelaySeconds: nil))
    }

    @Test func aBuiltInPeriodWithoutACameraPeriodIsBuiltInOnly() {
        let (comparator, events) = run([(.builtIn, true, 10), (.builtIn, false, 20)], until: 40)
        #expect(events.map(\.outcome) == [.builtInOnly], "an extra trigger")
        #expect(comparator.sinceStart().builtInOnly == 1)
    }

    @Test func periodsFarApartAreSeparateEvents() {
        let (_, events) = run([(.camera, true, 10), (.camera, false, 15), (.builtIn, true, 100), (.builtIn, false, 110),
                               (.camera, true, 200), (.builtIn, true, 201), (.camera, false, 210), (.builtIn, false, 211)], until: 300)
        #expect(events.map(\.outcome) == [.cameraOnly, .builtInOnly, .both(delay: .seconds(1))])
    }

    /// A camera whose events are short can end before built-in detection (which needs two hits) has confirmed the motion:
    /// periods within the slack are still one event.
    @Test func aPeriodThatStartsJustAfterTheOtherEndedStillPairs() {
        let (_, events) = run([(.camera, true, 10), (.camera, false, 11), (.builtIn, true, 12.5), (.builtIn, false, 25)], until: 60)
        #expect(events.map(\.outcome) == [.both(delay: .milliseconds(2_500))])
        let (_, apart) = run([(.camera, true, 10), (.camera, false, 11), (.builtIn, true, 13.5), (.builtIn, false, 25)], until: 60)
        #expect(apart.map(\.outcome) == [.cameraOnly, .builtInOnly], "more than the slack apart")
    }

    @Test func severalBuiltInPeriodsInsideOneCameraPeriodAreOneEvent() {
        let (_, events) = run([(.camera, true, 10), (.builtIn, true, 11), (.builtIn, false, 14), (.builtIn, true, 18), (.builtIn, false, 22),
                               (.camera, false, 30)], until: 60)
        #expect(events.map(\.outcome) == [.both(delay: .seconds(1))], "the first start of each source counts")
    }

    @Test func aRepeatedStartAndAStrayEndChangeNothing() {
        let (_, events) = run([(.camera, false, 1), (.camera, true, 10), (.camera, true, 12), (.builtIn, false, 13), (.camera, false, 20)], until: 40)
        #expect(events.map(\.outcome) == [.cameraOnly])
        #expect(events.first?.started == at(10), "the first start counts")
    }

    @Test func anEventIsFinishedOnlyOnceBothSourcesAreQuietForTheSlack() {
        var comparator = Comparator()
        _ = comparator.record(.camera, active: true, at: at(10))
        _ = comparator.record(.camera, active: false, at: at(20))
        #expect(comparator.advance(to: at(21.9)).isEmpty, "inside the slack a built-in period may still join")
        #expect(comparator.isEventOpen)
        #expect(comparator.rolling(at: at(21.9)).events == 0, "not counted before it ends")
        #expect(comparator.advance(to: at(22.1)).count == 1)
        #expect(!comparator.isEventOpen)
        #expect(comparator.rolling(at: at(22.1)).cameraOnly == 1)
    }

    @Test func aSourceThatNeverEndsDoesNotHoldAnEventOpenForever() {
        var limits = Comparator.Limits()
        limits.maximumEventLength = .seconds(600)
        var comparator = Comparator(limits: limits)
        _ = comparator.record(.camera, active: true, at: at(0))
        #expect(comparator.advance(to: at(599)).isEmpty)
        let finished = comparator.advance(to: at(601))
        #expect(finished.map(\.outcome) == [.cameraOnly])
        #expect(comparator.record(.camera, active: false, at: at(700)).isEmpty, "its late end is ignored")
        #expect(!comparator.isEventOpen)
    }

    @Test func closingFinishesWhatIsOpen() {
        var comparator = Comparator()
        _ = comparator.record(.builtIn, active: true, at: at(5))
        let events = comparator.close(at: at(9))
        #expect(events.map(\.outcome) == [.builtInOnly])
        #expect(comparator.close(at: at(10)).isEmpty)
    }

    @Test func theMedianOfAnOddAndAnEvenNumberOfDelays() {
        #expect(Comparator.median([]) == nil)
        #expect(Comparator.median([.seconds(3), .seconds(1), .seconds(2)]) == 2)
        #expect(Comparator.median([.seconds(1), .seconds(4), .seconds(2), .seconds(3)]) == 2.5)
        #expect(Comparator.median([.seconds(-1), .seconds(1), .seconds(3)]) == 1)
    }

    @Test func theRollingTotalsCoverTheWindowAndTheTotalsSinceStartCoverEverything() {
        var limits = Comparator.Limits()
        limits.window = .seconds(1_000)
        var comparator = Comparator(limits: limits)
        func event(at start: Double, delay: Double) {
            _ = comparator.record(.camera, active: true, at: at(start))
            _ = comparator.record(.builtIn, active: true, at: at(start + delay))
            _ = comparator.record(.camera, active: false, at: at(start + 5))
            _ = comparator.record(.builtIn, active: false, at: at(start + 5))
            _ = comparator.advance(to: at(start + 10))
        }
        event(at: 0, delay: 1)
        event(at: 100, delay: 3)
        _ = comparator.record(.builtIn, active: true, at: at(200))
        _ = comparator.record(.builtIn, active: false, at: at(205))
        _ = comparator.advance(to: at(220))
        #expect(comparator.rolling(at: at(300)) == MotionShadowTotals(both: 2, cameraOnly: 0, builtInOnly: 1, medianDelaySeconds: 2))
        // At 1,106 s the first two events (ended at 5 s and 105 s) are older than 1,000 s; the third (205 s) is not.
        _ = comparator.advance(to: at(1_106))
        #expect(comparator.rolling(at: at(1_106)) == MotionShadowTotals(both: 0, cameraOnly: 0, builtInOnly: 1, medianDelaySeconds: nil))
        #expect(comparator.retainedEventCount == 1, "expired events are forgotten")
        #expect(comparator.sinceStart() == MotionShadowTotals(both: 2, cameraOnly: 0, builtInOnly: 1, medianDelaySeconds: 2))
    }

    /// A source that flaps forever must not grow memory: events and delays are rings, the open event is a few numbers.
    @Test func memoryStaysBoundedWhateverTheSourcesDo() {
        var limits = Comparator.Limits()
        limits.retainedEvents = 50
        limits.retainedDelays = 20
        var comparator = Comparator(limits: limits)
        var clock = 0.0
        for index in 0..<3_000 {
            _ = comparator.record(.camera, active: true, at: at(clock))
            if index % 2 == 0 { _ = comparator.record(.builtIn, active: true, at: at(clock + 0.5)) }
            _ = comparator.record(.camera, active: false, at: at(clock + 3))
            _ = comparator.record(.builtIn, active: false, at: at(clock + 3))
            _ = comparator.advance(to: at(clock + 10))
            clock += 20
        }
        #expect(comparator.retainedEventCount <= 50)
        #expect(comparator.retainedDelayCount <= 20)
        let total = comparator.sinceStart()
        #expect(total.both == 1_500 && total.cameraOnly == 1_500, "the counters still count every event")
        #expect(total.medianDelaySeconds == 0.5)
        // 24 hours of one event every 20 s would be 4,320 events: the ring caps what the rolling totals can see.
        #expect(comparator.rolling(at: at(clock)).events <= 50)
    }

    @Test func eventsOlderThanTheWindowStopCountingEvenWithoutAnAdvance() {
        var limits = Comparator.Limits()
        limits.window = .seconds(100)
        var comparator = Comparator(limits: limits)
        _ = comparator.record(.camera, active: true, at: at(0))
        _ = comparator.record(.camera, active: false, at: at(5))
        _ = comparator.advance(to: at(10))
        #expect(comparator.rolling(at: at(50)).cameraOnly == 1)
        #expect(comparator.rolling(at: at(106)).cameraOnly == 0)
    }

    @Test func offsetsAreDescribedInWords() {
        #expect(MotionShadowTest.describeOffset(0.8) == "0.8 s later")
        #expect(MotionShadowTest.describeOffset(-1.24) == "1.2 s earlier")
        #expect(MotionShadowTest.describeOffset(0.04) == "at the same time")
        #expect(MotionShadowTest.describe(.both(delay: .milliseconds(800))) == "both detected; built-in 0.8 s later")
        #expect(MotionShadowTest.describe(.cameraOnly) == "camera only; built-in missed it")
        #expect(MotionShadowTest.describe(MotionShadowTotals(both: 5, cameraOnly: 1, builtInOnly: 2, medianDelaySeconds: 0.9))
                == "5 both, 1 camera only, 2 built-in only; median delay 0.9 s later")
        #expect(MotionShadowTest.describe(MotionShadowTotals()) == "0 both, 0 camera only, 0 built-in only; no delay measured")
    }
}
