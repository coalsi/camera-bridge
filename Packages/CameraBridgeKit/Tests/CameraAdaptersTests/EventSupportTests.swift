import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

@Suite(.timeLimit(.minutes(1))) struct EventHoldStateTests {
    private func makeState(ringDedupe: Duration = .milliseconds(300)) -> (EventHoldState, Box<[CameraEvent]>) {
        let box = Box<[CameraEvent]>([])
        let state = EventHoldState(ringDedupe: ringDedupe) { event in box.update { $0.append(event) } }
        return (state, box)
    }

    @Test func pulseHoldsUntilQuietThenReleases() async {
        let (state, box) = makeState()
        await state.apply(.activate(.motion, source: "vmd", hold: .milliseconds(150)))
        await state.apply(.activate(.motion, source: "vmd", hold: .milliseconds(150)))
        #expect(box.value == [.motion(true)])
        try? await Task.sleep(for: .milliseconds(80))
        await state.apply(.activate(.motion, source: "vmd", hold: .milliseconds(150)))   // re-arms
        try? await Task.sleep(for: .milliseconds(100))
        #expect(box.value == [.motion(true)])                                              // 180 ms after first pulse, still held
        #expect(await eventually(timeout: .seconds(2)) { box.value == [.motion(true), .motion(false)] })
    }

    @Test func levelSourcesCombineWithOr() async {
        let (state, box) = makeState()
        await state.apply(.activate(.tamper, source: "GlobalSceneChange", hold: nil))
        await state.apply(.activate(.tamper, source: "ImageTooDark", hold: nil))
        await state.apply(.deactivate(.tamper, source: "GlobalSceneChange"))
        #expect(box.value == [.tamper(true)])
        await state.apply(.deactivate(.tamper, source: "ImageTooDark"))
        #expect(box.value == [.tamper(true), .tamper(false)])
        await state.apply(.deactivate(.tamper, source: "ImageTooDark"))   // already off: no event
        #expect(box.value.count == 2)
    }

    @Test func explicitStopEndsAPulseEarly() async {
        let (state, box) = makeState()
        await state.apply(.activate(.motion, source: "cell", hold: .seconds(20)))
        await state.apply(.deactivate(.motion, source: "cell"))
        #expect(box.value == [.motion(true), .motion(false)])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(box.value.count == 2)
    }

    @Test func keysAreIndependent() async {
        let (state, box) = makeState()
        await state.apply(.activate(.digitalInput("1"), source: "", hold: nil))
        await state.apply(.activate(.digitalInput("2"), source: "", hold: nil))
        await state.apply(.activate(.object(.person), source: "", hold: nil))
        await state.apply(.deactivate(.digitalInput("1"), source: ""))
        #expect(box.value == [.digitalInput(id: "1", active: true), .digitalInput(id: "2", active: true), .object(.person, true),
                              .digitalInput(id: "1", active: false)])
        #expect(await state.activeKeys() == [.digitalInput("2"), .object(.person)])
    }

    @Test func ringsAreDeduplicatedWithinTheWindow() async {
        let (state, box) = makeState(ringDedupe: .milliseconds(200))
        await state.apply(.ring)
        await state.apply(.ring)
        #expect(box.value == [.doorbellPressed])
        try? await Task.sleep(for: .milliseconds(250))
        await state.apply(.ring)
        #expect(box.value == [.doorbellPressed, .doorbellPressed])
    }

    @Test func releasingLevelSourcesKeepsPulses() async {
        let (state, box) = makeState()
        await state.apply(.activate(.motion, source: "MotionAlarm", hold: nil))
        await state.apply(.activate(.motion, source: "cell", hold: .seconds(20)))
        await state.apply(.activate(.object(.person), source: "people", hold: nil))
        await state.apply(.activate(.tamper, source: "shelter", hold: .seconds(20)))
        await state.releaseLevelSources()
        // Motion stays on (its pulse source is still held); the level-only person state ends.
        #expect(box.value == [.motion(true), .object(.person, true), .tamper(true), .object(.person, false)])
        #expect(await state.activeKeys() == [.motion, .tamper])
        await state.apply(.deactivate(.motion, source: "cell"))
        #expect(box.value.last == .motion(false))
    }

    @Test func passthroughEvents() async {
        let (state, box) = makeState()
        await state.apply([.event(.dayNight(isNight: true)), .event(.temperature(celsius: 21.5))])
        #expect(box.value == [.dayNight(isNight: true), .temperature(celsius: 21.5)])
    }
}

@Suite(.timeLimit(.minutes(1))) struct SupervisedEventSourceTests {
    private static let fastPolicy = ReconnectPolicy(backoff: Backoff(initial: .milliseconds(20), maximum: .milliseconds(50), jitter: 0),
                                                     healthyAfter: .seconds(30), minimumDelayAfterFailure: .zero)

    @Test func reportsConnectionStateAndReconnects() async {
        let sessions = Box(0)
        let source = SupervisedEventSource(label: "test", policy: Self.fastPolicy) { context in
            let n = sessions.update { $0 += 1; return $0 }
            context.connected()
            await context.apply([.event(.temperature(celsius: Double(n)))])
            try await Task.sleep(for: .milliseconds(20))
            // session ends (connection closed by the camera)
        }
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.filter { $0 == .eventChannel(connected: true) }.count >= 2 })
        await source.stop()
        let values = recorder.values
        #expect(values.first == .eventChannel(connected: true))
        #expect(values.contains(.temperature(celsius: 1)))
        #expect(values.contains(.eventChannel(connected: false)))
        let count = sessions.value
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sessions.value == count, "no sessions after stop")
    }

    @Test func levelStatesAreReleasedWhenTheChannelDrops() async {
        let sessions = Box(0)
        let source = SupervisedEventSource(label: "test", policy: Self.fastPolicy) { context in
            let n = sessions.update { $0 += 1; return $0 }
            context.connected()
            await context.apply([.activate(.motion, source: "MotionAlarm", hold: nil), .activate(.tamper, source: "pulse", hold: .seconds(30))])
            if n == 1 { throw CameraAdapterError.httpStatus(503) }   // the camera drops the channel while motion is on
            try await Task.sleep(for: .seconds(30))
        }
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.filter { $0 == .motion(true) }.count >= 2 })
        await source.stop()
        let values = recorder.values
        // The level state ends before the channel reports the drop; the reconnected session re-asserts it.
        #expect(Array(values.prefix(6)) == [.eventChannel(connected: true), .motion(true), .tamper(true), .motion(false),
                                            .eventChannel(connected: false), .eventChannel(connected: true)])
        #expect(values.dropFirst(6).first == .motion(true))
        #expect(!values.contains(.tamper(false)), "pulses are not released by a drop (they expire on their own)")
    }

    @Test func sessionsCanReportRepeatedDisconnects() async {
        let source = SupervisedEventSource(label: "test", policy: Self.fastPolicy) { context in
            context.connected()
            await context.apply([.activate(.object(.person), source: "people", hold: nil)])
            await context.disconnected()
            await context.disconnected()   // idempotent
            context.connected()
            try await Task.sleep(for: .seconds(30))
        }
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.count >= 5 })
        await source.stop()
        #expect(Array(recorder.values.prefix(5)) == [.eventChannel(connected: true), .object(.person, true), .object(.person, false),
                                                     .eventChannel(connected: false), .eventChannel(connected: true)])
    }

    @Test func rejectedCredentialsWaitTheLongDelay() async throws {
        let starts = Box<[ContinuousClock.Instant]>([])
        var policy = Self.fastPolicy
        policy.delayAfterUnauthorized = .milliseconds(400)
        let source = SupervisedEventSource(label: "test", policy: policy) { _ in
            starts.update { $0.append(.now) }
            throw CameraAdapterError.unauthorized
        }
        _ = source.events()
        #expect(await eventually { starts.value.count >= 2 })
        await source.stop()
        let times = starts.value
        try #require(times.count >= 2)
        #expect(times[1] - times[0] >= .milliseconds(390))
        #expect(ReconnectPolicy().delayAfterUnauthorized >= .seconds(300), "production: minutes, not seconds (camera login lockouts)")
    }

    @Test func rejectedCredentialsAreReportedAsAnEvent() async {
        let attempts = Box(0)
        var policy = Self.fastPolicy
        policy.delayAfterUnauthorized = .milliseconds(50)
        let source = SupervisedEventSource(label: "test", policy: policy) { context in
            let n = attempts.update { $0 += 1; return $0 }
            if n <= 2 { throw CameraAdapterError.unauthorized }
            context.connected()
            try await Task.sleep(for: .seconds(30))
        }
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.eventChannel(connected: true)) })
        await source.stop()
        // One `.authenticationFailed` per rejected attempt; the channel never counted as connected before the login worked.
        #expect(Array(recorder.values.prefix(3)) == [.authenticationFailed, .authenticationFailed, .eventChannel(connected: true)])
    }

    @Test func otherFailuresAreNotReportedAsRejectedCredentials() async {
        let attempts = Box(0)
        let source = SupervisedEventSource(label: "test", policy: Self.fastPolicy) { _ in
            attempts.update { $0 += 1 }
            throw CameraAdapterError.httpStatus(503)
        }
        let recorder = Recorder(source.events())
        #expect(await eventually { attempts.value >= 3 })
        await source.stop()
        #expect(!recorder.values.contains(.authenticationFailed))
    }

    @Test func unauthorizedFailuresDoNotResetTheBackoff() {
        var policy = ReconnectPolicy(backoff: Backoff(initial: .seconds(1), maximum: .seconds(60), jitter: 0), healthyAfter: .seconds(10),
                                     minimumDelayAfterFailure: .zero, delayAfterUnauthorized: .seconds(600))
        #expect(policy.delay(connected: true, lasted: .seconds(100), error: CameraAdapterError.unauthorized) == .seconds(600))
        #expect(policy.delay(connected: false, lasted: .zero, error: CameraAdapterError.httpStatus(500)) == .seconds(2))
        #expect(policy.delay(connected: true, lasted: .seconds(100), error: nil) == .zero)
        #expect(policy.delay(connected: false, lasted: .zero, error: nil) == .seconds(1))
    }

    @Test func stopHookRunsOnceAfterTheSessionEnds() async {
        let log = Box<[String]>([])
        let source = SupervisedEventSource(label: "test", policy: Self.fastPolicy, onStop: { log.update { $0.append("stop hook") } }) { context in
            context.connected()
            do { try await Task.sleep(for: .seconds(30)) } catch { log.update { $0.append("session cancelled") }; throw error }
        }
        _ = source.events()
        try? await Task.sleep(for: .milliseconds(50))
        await source.stop()
        await source.stop()
        #expect(log.value == ["session cancelled", "stop hook"])
    }

    @Test func stopHookRunsWhenTheSourceIsDropped() async {
        let hooked = Box(0)
        var source: SupervisedEventSource? = SupervisedEventSource(label: "test", policy: Self.fastPolicy, onStop: { hooked.update { $0 += 1 } }) {
            context in
            context.connected()
            try await Task.sleep(for: .seconds(30))
        }
        _ = source?.events()
        try? await Task.sleep(for: .milliseconds(50))
        source = nil
        #expect(await eventually { hooked.value == 1 })
    }

    @Test func failedAttemptsWaitAtLeastTheMinimumDelay() async throws {
        let starts = Box<[ContinuousClock.Instant]>([])
        let policy = ReconnectPolicy(backoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(10), jitter: 0),
                                     healthyAfter: .seconds(30), minimumDelayAfterFailure: .milliseconds(200))
        let source = SupervisedEventSource(label: "test", policy: policy) { _ in
            starts.update { $0.append(.now) }
            throw CameraAdapterError.httpStatus(503)
        }
        _ = source.events()
        #expect(await eventually { starts.value.count >= 2 })
        await source.stop()
        let times = starts.value
        try #require(times.count >= 2)
        #expect(times[1] - times[0] >= .milliseconds(190))
        // Never connected: no eventChannel(false) is invented.
    }

    @Test func healthySessionsReconnectImmediately() async {
        let starts = Box<[ContinuousClock.Instant]>([])
        let policy = ReconnectPolicy(backoff: Backoff(initial: .seconds(5), maximum: .seconds(5), jitter: 0),
                                     healthyAfter: .milliseconds(50), minimumDelayAfterFailure: .seconds(5))
        let source = SupervisedEventSource(label: "test", policy: policy) { context in
            starts.update { $0.append(.now) }
            context.connected()
            try await Task.sleep(for: .milliseconds(80))
        }
        _ = source.events()
        #expect(await eventually { starts.value.count >= 3 })
        await source.stop()
    }

    @Test func droppingTheSourceWithoutStopEndsTheSessions() async {
        let sessions = Box(0)
        let cancelled = Box(false)
        var source: SupervisedEventSource? = SupervisedEventSource(label: "test", policy: Self.fastPolicy) { context in
            sessions.update { $0 += 1 }
            context.connected()
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.set(true); throw error }
        }
        let stream = source?.events()
        #expect(await eventually { sessions.value == 1 })
        source = nil
        #expect(await eventually { cancelled.value })
        _ = stream
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sessions.value == 1)
    }

    @Test func stopFinishesTheStream() async {
        let source = SupervisedEventSource(label: "test", policy: Self.fastPolicy) { context in
            context.connected()
            try await Task.sleep(for: .seconds(30))
        }
        let stream = source.events()
        let finished = Box(false)
        let consumer = Task {
            for await _ in stream {}
            finished.set(true)
        }
        try? await Task.sleep(for: .milliseconds(50))
        await source.stop()
        #expect(await eventually { finished.value })
        consumer.cancel()
        // After stop, new subscribers get a finished stream and no session restarts.
        var iterator = source.events().makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}
