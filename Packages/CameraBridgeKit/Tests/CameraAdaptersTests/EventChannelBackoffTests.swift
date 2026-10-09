#if os(macOS)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// Field report: a Tapo's ONVIF event channel "connected" and "disconnected" every 11 s forever, a warning each time. The camera
/// drops a PullMessages request after 10 s of idle time (measured: its HTTP server closes an idle connection at 10.3 s), the
/// session counted as healthy (>= 10 s), so the backoff reset and the loop reconnected at once.
@Suite(.timeLimit(.minutes(1))) struct EventChannelBackoffTests {
    final class RecordingLog: EventChannelLog {
        let lines = Box<[(String, String)]>([])
        func debug(_ message: @autoclosure () -> String) { lines.update { $0.append(("debug", message())) } }
        func info(_ message: @autoclosure () -> String) { lines.update { $0.append(("info", message())) } }
        func warning(_ message: @autoclosure () -> String) { lines.update { $0.append(("warning", message())) } }
        func count(_ level: String) -> Int { lines.value.filter { $0.0 == level }.count }
    }

    @Test func aSessionThatConnectedButEndedQuicklyBacksOffExponentiallyUpToFiveMinutes() {
        var policy = ReconnectPolicy(backoff: Backoff(initial: .seconds(1), maximum: .seconds(60), jitter: 0), healthyAfter: .seconds(30),
                                     shortSessionBackoff: Backoff(initial: .seconds(5), maximum: .seconds(300), jitter: 0))
        // 10.3 s: the Tapo's session. It used to count as healthy (>= 10 s) and reconnect at once.
        let delays = (0..<8).map { _ in policy.delay(connected: true, lasted: .milliseconds(10_300), error: TransportError.closed) }
        #expect(delays == [5, 10, 20, 40, 80, 160, 300, 300].map { Duration.seconds($0) })
        #expect(policy.consecutiveShortSessions == 8)
        // A healthy session resets everything.
        #expect(policy.delay(connected: true, lasted: .seconds(45), error: nil) == .zero)
        #expect(policy.consecutiveShortSessions == 0)
        #expect(policy.delay(connected: true, lasted: .seconds(1), error: nil) == .seconds(5))
        // Attempts that never connected keep the ordinary backoff (a camera that is switched off).
        #expect(policy.delay(connected: false, lasted: .zero, error: TransportError.connectionRefused) == .seconds(1))
    }

    @Test func productionPoliciesBackOffOnShortSessions() {
        let onvif = ONVIFEventTiming()
        #expect(onvif.policy.healthyAfter == .seconds(30))
        #expect(onvif.policy.shortSessionBackoff != nil)
        #expect(onvif.unreliableAfterShortSessions == 5)
        #expect(ReolinkEventTiming().policy.shortSessionBackoff != nil)
    }

    @Test func theFirstFailureOfAStreakIsAWarningTheRestAreDebugWithAPeriodicSummary() {
        var failures = ReconnectLoop.FailureLog()
        let log = RecordingLog()
        let start = ContinuousClock.now
        for index in 0..<6 {
            failures.record("camera: event channel failed: closed", next: .seconds(30), label: "camera", log: log,
                            now: start + .seconds(index * 200))   // a summary every 600 s
        }
        #expect(log.count("warning") == 1)
        #expect(log.count("debug") == 5)
        #expect(log.count("info") == 1, "one summary after 600 s: \(log.lines.value)")
        failures.recovered(label: "camera", log: log)
        #expect(log.count("info") == 2, "the recovery is reported once")
        failures.record("camera: event channel failed: closed", next: .seconds(30), label: "camera", log: log, now: start)
        #expect(log.count("warning") == 2, "a new streak warns again")
    }

    @Test func aChannelThatKeepsDroppingIsReportedUnreliableOnceAndNotRetriedQuickly() async {
        let sessions = Box<[ContinuousClock.Instant]>([])
        let policy = ReconnectPolicy(backoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(10), jitter: 0), healthyAfter: .seconds(30),
                                     shortSessionBackoff: Backoff(initial: .milliseconds(30), maximum: .milliseconds(200), multiplier: 2, jitter: 0))
        let source = SupervisedEventSource(label: "test", policy: policy, unreliableAfterShortSessions: 3) { context in
            sessions.update { $0.append(.now) }
            context.connected()
            try await Task.sleep(for: .milliseconds(5))
            throw TransportError.closed
        }
        let recorder = EventRecorder(source.events())
        #expect(await eventually { sessions.value.count >= 5 })
        await source.stop()
        let unreliable = recorder.values.filter { if case .eventChannelUnreliable = $0 { true } else { false } }
        #expect(unreliable == [.eventChannelUnreliable(shortSessions: 3)], "once per streak, at the threshold")
        let times = sessions.value
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(gaps[1] > gaps[0] && gaps[2] > gaps[1], "the pause grows: \(gaps)")
    }

    @Test func healthySessionsNeverReportTheChannelUnreliable() async {
        let policy = ReconnectPolicy(backoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(10), jitter: 0), healthyAfter: .milliseconds(10),
                                     shortSessionBackoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(10), jitter: 0))
        let sessions = Box(0)
        let source = SupervisedEventSource(label: "test", policy: policy, unreliableAfterShortSessions: 2) { context in
            sessions.update { $0 += 1 }
            context.connected()
            try await Task.sleep(for: .milliseconds(30))
        }
        let recorder = EventRecorder(source.events())
        #expect(await eventually { sessions.value >= 5 })
        await source.stop()
        #expect(!recorder.values.contains { if case .eventChannelUnreliable = $0 { true } else { false } })
    }

    @Test func aCameraThatDropsALongPollEarlyGetsAShorterOne() {
        // Tapo: the connection is closed after ~10.3 s whatever Timeout says (PT1M asked).
        #expect(ONVIFPullPoint.shorterPullSeconds(droppedAfter: 10.3, current: 60) == 7)
        // Dropped almost at once: nothing to learn, the subscription is probably gone.
        #expect(ONVIFPullPoint.shorterPullSeconds(droppedAfter: 0.4, current: 60) == nil)
        #expect(ONVIFPullPoint.shorterPullSeconds(droppedAfter: 2.0, current: 60) == nil)
        #expect(ONVIFPullPoint.shorterPullSeconds(droppedAfter: 3.0, current: 60) == 2)
        // Already pulling for less than that: no change (the loop then ends the session instead of retrying forever).
        #expect(ONVIFPullPoint.shorterPullSeconds(droppedAfter: 10.3, current: 7) == nil)
        #expect(ONVIFPullPoint.shorterPullSeconds(droppedAfter: .nan, current: 60) == nil)
    }
}

/// Collects a source's events.
final class EventRecorder: Sendable {
    let box = Box<[CameraEvent]>([])
    private let task: Task<Void, Never>

    var values: [CameraEvent] { box.value }

    init(_ events: AsyncStream<CameraEvent>) {
        let box = box
        task = Task { for await event in events { box.update { $0.append(event) } } }
    }

    deinit { task.cancel() }
}
#endif
