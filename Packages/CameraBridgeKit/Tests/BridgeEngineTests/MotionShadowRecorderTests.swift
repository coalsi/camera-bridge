import BridgeSupport
import Foundation
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// Collects the log lines of one camera.
private final class CameraLines: LogSink {
    let cameraID: UUID
    private let lines = Mutex<[LogEntry]>([])

    init(cameraID: UUID) { self.cameraID = cameraID }

    func record(_ entry: LogEntry) {
        if entry.cameraID == cameraID { lines.withLock { $0.append(entry) } }
    }

    var entries: [LogEntry] { lines.withLock { $0 } }
    var messages: [String] { entries.map(\.message) }
}

/// One camera's shadow test on a manual clock: the INFO line per finished event, the hourly summary and the timer.
@Suite(.serialized) struct MotionShadowRecorderTests {
    private struct Fixture {
        let clock = TestClock()
        let cameraID = UUID()
        let lines: CameraLines
        let token: LogSinkToken
        let recorder: MotionShadowTest

        init(name: String = "Patio") {
            let cameraID = cameraID
            lines = CameraLines(cameraID: cameraID)
            token = LogHub.addSink(lines)
            recorder = MotionShadowTest(cameraName: name, log: Log(category: "Events", cameraID: cameraID), clock: clock)
        }

        func close() { LogHub.removeSink(token) }
    }

    @Test func everyFinishedEventGetsOneInfoLine() async {
        let fixture = Fixture()
        defer { fixture.close() }
        let (clock, recorder) = (fixture.clock, fixture.recorder)

        // Both saw it; built-in 0.75 s after the camera.
        await recorder.cameraMotion(true)
        clock.advance(by: .milliseconds(750))
        await recorder.builtInMotion(true)
        clock.advance(by: .seconds(5))
        await recorder.cameraMotion(false)
        await recorder.builtInMotion(false)
        #expect(fixture.lines.messages.isEmpty, "an event is logged when it is over, not while it runs")
        clock.advance(by: .seconds(3))
        await recorder.tickOnce()

        // The camera alone.
        clock.advance(by: .seconds(60))
        await recorder.cameraMotion(true)
        clock.advance(by: .seconds(4))
        await recorder.cameraMotion(false)
        clock.advance(by: .seconds(3))
        await recorder.tickOnce()

        // Built-in alone.
        clock.advance(by: .seconds(60))
        await recorder.builtInMotion(true)
        clock.advance(by: .seconds(11))
        await recorder.builtInMotion(false)
        clock.advance(by: .seconds(3))
        await recorder.tickOnce()

        let infoLines = fixture.lines.entries.filter { $0.level == .info && $0.message.hasPrefix("Motion shadow test: ") }
        #expect(infoLines.map(\.message) == [
            "Motion shadow test: Patio: both detected; built-in 0.8 s later",
            "Motion shadow test: Patio: camera only; built-in missed it",
            "Motion shadow test: Patio: built-in only; the camera reported nothing",
        ])
        let totals = await recorder.totals()
        #expect(totals.last24Hours == MotionShadowTotals(both: 1, cameraOnly: 1, builtInOnly: 1, medianDelaySeconds: 0.75))
        #expect(totals.sinceEnabled == totals.last24Hours)
        #expect(!totals.eventInProgress)
    }

    @Test func aRunningEventShowsAsInProgressAndIsNotCountedYet() async {
        let fixture = Fixture()
        defer { fixture.close() }
        await fixture.recorder.builtInMotion(true)
        let running = await fixture.recorder.totals()
        #expect(running.eventInProgress && running.last24Hours.events == 0)
    }

    @Test func aSummaryLineIsWrittenEveryHour() async {
        let fixture = Fixture(name: "Driveway")
        defer { fixture.close() }
        let (clock, recorder) = (fixture.clock, fixture.recorder)
        await recorder.tickOnce()
        clock.advance(by: .seconds(3_599))
        await recorder.tickOnce()
        #expect(fixture.lines.messages.isEmpty, "not before the hour is over")

        clock.advance(by: .seconds(1))
        await recorder.tickOnce()
        #expect(fixture.lines.messages == ["Motion shadow test: Driveway, last 24 h: 0 both, 0 camera only, 0 built-in only; no delay measured"])

        await recorder.cameraMotion(true)
        clock.advance(by: .seconds(1))
        await recorder.builtInMotion(true)
        clock.advance(by: .seconds(2))
        await recorder.cameraMotion(false)
        await recorder.builtInMotion(false)
        clock.advance(by: .seconds(3_600))
        await recorder.tickOnce()
        let summaries = fixture.lines.messages.filter { $0.contains("last 24 h") }
        #expect(summaries.count == 2)
        #expect(summaries.last == "Motion shadow test: Driveway, last 24 h: 1 both, 0 camera only, 0 built-in only; median delay 1.0 s later")
        #expect(fixture.lines.entries.filter { $0.message.contains("last 24 h") }.allSatisfy { $0.level == .info })
    }

    @Test(.timeLimit(.minutes(1))) func theTimerFinishesQuietEventsAndStopsWithTheTest() async {
        let fixture = Fixture()
        defer { fixture.close() }
        let (clock, recorder) = (fixture.clock, fixture.recorder)
        await recorder.start()
        #expect(await eventually(timeout: .seconds(5)) { clock.sleeperCount == 1 }, "the timer waits")
        await recorder.builtInMotion(true)
        await recorder.builtInMotion(false)
        for _ in 0..<4 {
            clock.advance(by: .seconds(1))
            #expect(await eventually(timeout: .seconds(5)) { clock.sleeperCount == 1 })
        }
        #expect(fixture.lines.messages == ["Motion shadow test: Patio: built-in only; the camera reported nothing"], "finished by the timer alone")

        // Stopping finishes what is open and ends the timer.
        await recorder.cameraMotion(true)
        await recorder.stop()
        #expect(fixture.lines.messages.last == "Motion shadow test: Patio: camera only; built-in missed it")
        #expect(await eventually(timeout: .seconds(5)) { clock.sleeperCount == 0 }, "the timer is gone")
    }

    @Test func theRecorderKeepsABoundedNumberOfEvents() async {
        let fixture = Fixture()
        defer { fixture.close() }
        var limits = MotionShadowComparator.Limits()
        limits.retainedEvents = 10
        limits.retainedDelays = 5
        let recorder = MotionShadowTest(cameraName: "Gate", log: Log(category: "Events", cameraID: fixture.cameraID), clock: fixture.clock, limits: limits)
        for _ in 0..<200 {
            await recorder.cameraMotion(true)
            await recorder.builtInMotion(true)
            fixture.clock.advance(by: .seconds(1))
            await recorder.cameraMotion(false)
            await recorder.builtInMotion(false)
            fixture.clock.advance(by: .seconds(5))
            await recorder.tickOnce()
        }
        let retained = await recorder.retained
        #expect(retained.events <= 10 && retained.delays <= 5)
        #expect(await recorder.totals().sinceEnabled.both == 200)
    }
}
