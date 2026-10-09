import BridgeSupport
import TestSupport
@testable import CameraAdapters
import Foundation
import Synchronization
import Testing
@testable import BridgeEngine

/// Collects router outputs (handler) and lets tests advance a manual clock and a fake wall clock together.
private final class RouterHarness: Sendable {
    let clock = TestClock()
    let wallClock = Box(Date(timeIntervalSince1970: 1_800_000_000))
    let outputs = Box<[EventRouterOutput]>([])
    let router: EventRouter
    let cameraID = UUID()

    init(hold: Int = 20, kind: CameraKind = .camera, vendor: CameraVendor = .hikvision) async {
        let wallClock = wallClock
        router = EventRouter(clock: clock, date: { wallClock.value })
        let outputs = outputs
        await router.setOutputHandler { output in outputs.update { $0.append(output) } }
        var camera = CameraConfiguration(id: cameraID, name: "Driveway", kind: kind, vendor: vendor, endpoint: CameraEndpoint(host: "192.0.2.1"),
                                         username: "admin")
        camera.motionHoldSeconds = hold
        await router.register(camera)
    }

    func advance(_ seconds: Double) {
        let duration = Duration.milliseconds(Int64(seconds * 1000))
        wallClock.update { $0 = $0.addingTimeInterval(seconds) }
        clock.advance(by: duration)
    }

    func send(_ event: CameraEvent, _ origin: EventOrigin = .camera) async {
        await router.handle(event, for: cameraID, origin: origin)
    }

    func state() async -> SensorState {
        await router.state(for: cameraID) ?? SensorState(id: UUID())
    }

    /// Motion outputs so far (true/false in order).
    var motion: [Bool] {
        outputs.value.compactMap { if case .motion(_, let active) = $0 { active } else { nil } }
    }

    var rings: Int {
        outputs.value.filter { if case .doorbell = $0 { true } else { false } }.count
    }
}

@Suite(.timeLimit(.minutes(1))) struct EventRouterMotionTests {
    @Test func pulsesHoldMotionForTheHoldAfterTheLastPulse() async {
        let h = await RouterHarness(hold: 20)
        await h.send(.motion(true), .webhook)
        #expect(await h.state().motion)
        h.advance(19)
        #expect(await h.state().motion)
        await h.send(.motion(true), .webhook)   // re-arms the hold
        h.advance(19)
        #expect(await h.state().motion)
        h.advance(1)
        #expect(await !h.state().motion)
        #expect(h.motion == [true, false], "one transition each way")
    }

    @Test func anExplicitStopEndsAPulseAtOnce() async {
        let h = await RouterHarness(hold: 20)
        await h.send(.motion(true), .webhook)
        h.advance(5)
        await h.send(.motion(false), .webhook)
        #expect(await !h.state().motion)
        #expect(h.motion == [true, false])
    }

    @Test func hikvisionEndsAlreadyTrailTheLastPulseByTwentySeconds() async {
        // CameraAdapters reports a Hikvision event's end 20 s after its last pulse: with the default hold nothing is
        // added (never 40 s), a longer hold adds the rest.
        let h = await RouterHarness(hold: 20, vendor: .hikvision)
        await h.send(.motion(true))
        h.advance(60)
        #expect(await h.state().motion, "a long camera event is never cut by the hold")
        await h.send(.motion(false))
        #expect(await !h.state().motion, "the last pulse was 20 s ago")
        await h.send(.motion(true))
        h.advance(3)
        await h.send(.motion(false))
        #expect(await h.state().motion, "a short camera event still lasts the hold")
        h.advance(16.9)
        #expect(await h.state().motion)
        h.advance(0.1)
        #expect(await !h.state().motion)
        #expect(h.motion == [true, false, true, false])

        let long = await RouterHarness(hold: 60, vendor: .hikvision)
        await long.send(.motion(true))
        long.advance(300)
        await long.send(.motion(false))
        long.advance(39.9)
        #expect(await long.state().motion, "60 s after the last pulse (280 s)")
        long.advance(0.1)
        #expect(await !long.state().motion)
        #expect(long.motion == [true, false])
    }

    @Test(arguments: [CameraVendor.onvif, .reolink, .demo, .rtsp])
    func levelCameraEventsAreHeldAfterTheCameraEndsThem(_ vendor: CameraVendor) async {
        let h = await RouterHarness(hold: 20, vendor: vendor)
        await h.send(.motion(true))
        h.advance(60)
        await h.send(.motion(false))
        #expect(await h.state().motion, "the hold follows the end of a long level")
        h.advance(19.9)
        #expect(await h.state().motion)
        h.advance(0.1)
        #expect(await !h.state().motion)

        await h.send(.motion(true))
        h.advance(3)
        await h.send(.motion(false))
        h.advance(19.9)
        #expect(await h.state().motion, "20 s after the end of a short level too")
        h.advance(0.1)
        #expect(await !h.state().motion)
        #expect(h.motion == [true, false, true, false])

        let long = await RouterHarness(hold: 60, vendor: vendor)
        await long.send(.motion(true))
        long.advance(300)
        await long.send(.motion(false))
        long.advance(1)
        #expect(await long.state().motion, "a raised hold applies after a 300 s event")
        long.advance(58.9)
        #expect(await long.state().motion)
        long.advance(0.1)
        #expect(await !long.state().motion)
    }

    @Test func softMotionIsHeldForTheHoldAfterTheLastMovement() async {
        // SoftMotionDetector reports the end 10 s after the last movement; the hold counts from that movement.
        let h = await RouterHarness(hold: 20)
        await h.send(.motion(true), .softMotion)
        h.advance(30)
        await h.send(.motion(false), .softMotion)
        #expect(await h.state().motion, "motion does not end with the detector's report")
        h.advance(9.9)
        #expect(await h.state().motion)
        h.advance(0.1)
        #expect(await !h.state().motion, "20 s after the last movement (20 s)")

        let long = await RouterHarness(hold: 60)
        await long.send(.motion(true), .softMotion)
        long.advance(30)
        await long.send(.motion(false), .softMotion)
        long.advance(49.9)
        #expect(await long.state().motion)
        long.advance(0.1)
        #expect(await !long.state().motion)

        let short = await RouterHarness(hold: 5)
        await short.send(.motion(true), .softMotion)
        short.advance(30)
        await short.send(.motion(false), .softMotion)
        #expect(await !short.state().motion, "the detector's quiet period already exceeds a 5 s hold")
    }

    @Test func streamMotionIsALevelHeldAfterItsEnd() async {
        let h = await RouterHarness(hold: 20)
        await h.send(.motion(true), .stream)
        h.advance(45)
        #expect(await h.state().motion)
        await h.send(.motion(false), .stream)
        h.advance(19.9)
        #expect(await h.state().motion)
        h.advance(0.1)
        #expect(await !h.state().motion)
    }

    @Test func aStopWithoutAStartAddsNoHold() async {
        let h = await RouterHarness(hold: 20, vendor: .onvif)
        await h.send(.motion(false))
        await h.send(.motion(false), .softMotion)
        #expect(await !h.state().motion)
        #expect(h.motion.isEmpty)
    }

    @Test func levelsFromSeveralOriginsCombine() async {
        let h = await RouterHarness(hold: 5)   // Hikvision: its ends already trail the last pulse by more than 5 s
        await h.send(.motion(true), .camera)
        await h.send(.motion(true), .softMotion)
        h.advance(10)
        await h.send(.motion(false), .camera)
        #expect(await h.state().motion, "soft motion still reports motion")
        await h.send(.motion(false), .webhook)   // an explicit stop from another origin does not end a level
        #expect(await h.state().motion)
        await h.send(.motion(false), .softMotion)
        #expect(await !h.state().motion)
        #expect(h.motion == [true, false])
    }

    @Test func userTriggeredMotionIsAPulse() async {
        let h = await RouterHarness(hold: 10)
        await h.router.triggerMotion(for: h.cameraID)
        #expect(await h.state().motion)
        h.advance(10)
        #expect(await !h.state().motion)
    }

    @Test func holdIsReadFromTheConfigurationAndAtLeastOneSecond() async {
        let h = await RouterHarness(hold: 0)
        await h.send(.motion(true), .webhook)
        h.advance(0.9)
        #expect(await h.state().motion)
        h.advance(0.1)
        #expect(await !h.state().motion)
        var camera = CameraConfiguration(id: h.cameraID, name: "Driveway", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "x"),
                                         username: "")
        camera.motionHoldSeconds = 45
        await h.router.register(camera)
        await h.send(.motion(true), .webhook)
        h.advance(44)
        #expect(await h.state().motion)
        h.advance(1)
        #expect(await !h.state().motion)
    }

    @Test func timersEmitWithoutBeingAsked() async {
        let h = await RouterHarness(hold: 20)
        await h.send(.motion(true), .webhook)
        #expect(await eventually { h.clock.sleeperCount == 1 })
        h.advance(20)
        #expect(await eventually { h.motion == [true, false] })
    }

    @Test func disconnectingTheEventChannelDoesNotResetMotion() async {
        // CameraAdapters ends level states itself before it reports the drop; the router must not second-guess it.
        let h = await RouterHarness(hold: 20)
        await h.send(.motion(true))
        await h.send(.eventChannel(connected: false))
        #expect(await h.state().motion)
    }

    @Test func resettingAnOriginEndsItsLevelsAfterTheHold() async {
        let h = await RouterHarness(hold: 20)
        await h.send(.eventChannel(connected: true))
        await h.send(.motion(true))
        await h.send(.object(.person, true))
        await h.send(.tamper(true))
        await h.send(.audioAlarm(true))
        await h.send(.digitalInput(id: "1", active: true))
        h.advance(30)
        await h.router.resetOrigin(.camera, for: h.cameraID)
        var state = await h.state()
        #expect(state.motion && state.objects == [.person], "the last activity may have been just now: held from the reset")
        #expect(!state.tampered && !state.audioAlarm && state.digitalInputs["1"] == false)
        #expect(state.eventChannelConnected == nil, "no channel any more: not a fault")
        h.advance(19.9)
        #expect(await h.state().motion)
        h.advance(0.1)
        state = await h.state()
        #expect(!state.motion && state.objects == [.person])
        h.advance(40)
        #expect(await h.state().objects.isEmpty)
        await h.router.resetOrigin(.camera, for: h.cameraID)
        #expect(await !h.state().motion, "nothing was on: nothing to hold")
    }

    @Test func resettingSoftMotionOrTheStreamEndsOnlyTheirs() async {
        // SoftMotionDetector keeps motion on while frames stop arriving; the engine resets the origin when its stream goes.
        let h = await RouterHarness(hold: 20)
        await h.send(.motion(true), .softMotion)
        await h.send(.motion(true), .stream)
        await h.send(.authenticationFailed, .stream)
        await h.send(.authenticationFailed)
        h.advance(100)
        await h.router.resetOrigin(.softMotion, for: h.cameraID)
        h.advance(30)
        var state = await h.state()
        #expect(state.motion, "the stream still reports motion")
        #expect(state.credentialsRejected)
        await h.router.resetOrigin(.stream, for: h.cameraID)
        state = await h.state()
        #expect(state.motion && state.credentialsRejected, "held after the reset; the event channel's rejection stays")
        h.advance(20)
        #expect(await !h.state().motion)
        await h.router.resetOrigin(.camera, for: h.cameraID)
        #expect(await !h.state().credentialsRejected)
        #expect(h.motion == [true, false])
    }
}

@Suite(.timeLimit(.minutes(1))) struct EventRouterSignalTests {
    @Test func doorbellRingsAreDeduplicatedAndPulseMotion() async {
        let h = await RouterHarness(hold: 20, kind: .doorbell)
        await h.send(.doorbellPressed)
        #expect(h.rings == 1 && h.motion == [true])
        let firstRing = h.outputs.value.firstIndex { if case .doorbell = $0 { true } else { false } }
        let firstMotion = h.outputs.value.firstIndex { if case .motion = $0 { true } else { false } }
        #expect(firstRing.map { ring in firstMotion.map { ring < $0 } ?? false } == true, "ring first, then the motion pulse")
        h.advance(2.9)
        await h.send(.doorbellPressed, .webhook)
        #expect(h.rings == 1, "a second source reporting the same press")
        h.advance(0.2)
        await h.send(.doorbellPressed)
        #expect(h.rings == 2)
        h.advance(19.9)
        #expect(await h.state().motion)
        h.advance(0.1)
        #expect(await !h.state().motion)
        let ringDate = await h.state().lastRingDate?.timeIntervalSince1970 ?? 0
        #expect(abs(ringDate - 1_800_000_003.1) < 0.001, "the second accepted ring")
    }

    @Test func aWebhookStopEndsOnlyTheWebhooksOwnHold() async {
        // A Home Assistant automation sending motion/stop must not swallow the doorbell's recording trigger.
        let h = await RouterHarness(hold: 20, kind: .doorbell)
        await h.send(.doorbellPressed)
        h.advance(0.5)
        await h.send(.motion(false), .webhook)
        #expect(await h.state().motion, "the ring's motion pulse stays")
        h.advance(19.4)
        #expect(await h.state().motion)
        h.advance(0.1)
        #expect(await !h.state().motion)

        await h.router.triggerMotion(for: h.cameraID)
        await h.send(.motion(true), .webhook)
        await h.send(.motion(false), .webhook)
        #expect(await h.state().motion, "a user pulse is not the webhook's")
        h.advance(20)
        #expect(await !h.state().motion)

        let level = await RouterHarness(hold: 20, vendor: .reolink)
        await level.send(.motion(true))
        level.advance(40)
        await level.send(.motion(false))
        await level.send(.motion(true), .webhook)
        await level.send(.motion(false), .webhook)
        #expect(await level.state().motion, "the hold after the camera's end stays")
        level.advance(20)
        #expect(await !level.state().motion)
    }

    @Test func longLevelDetectionsAreHeldAfterTheirEnd() async {
        let reolink = await RouterHarness(vendor: .reolink)
        await reolink.send(.object(.person, true))
        reolink.advance(120)
        await reolink.send(.object(.person, false))
        reolink.advance(59.9)
        #expect(await reolink.state().objects == [.person], "occupancy lasts 60 s after a long detection ends")
        reolink.advance(0.1)
        #expect(await reolink.state().objects.isEmpty)

        let hikvision = await RouterHarness(vendor: .hikvision)
        await hikvision.send(.object(.vehicle, true))
        hikvision.advance(120)
        await hikvision.send(.object(.vehicle, false))
        hikvision.advance(39.9)
        #expect(await hikvision.state().objects == [.vehicle], "60 s after the last smart-event pulse (100 s)")
        hikvision.advance(0.1)
        #expect(await hikvision.state().objects.isEmpty)
    }

    @Test func holdLagsMatchCameraAdapters() {
        #expect(EventRouter.cameraPulseHold == HikvisionEventTiming().pulseHold)
        #expect(EventRouter.softMotionQuietPeriod == .seconds(SoftMotionDetector.quietPeriodToTurnOff))
    }

    @Test func detectionsHoldSixtySeconds() async {
        let h = await RouterHarness()
        await h.send(.object(.person, true))
        await h.send(.object(.vehicle, true), .webhook)
        h.advance(5)
        await h.send(.object(.person, false))
        #expect(await h.state().objects == [.person, .vehicle])
        h.advance(54.9)
        #expect(await h.state().objects == [.person, .vehicle])
        h.advance(0.1)
        #expect(await h.state().objects.isEmpty)
        await h.send(.object(.animal, true), .webhook)
        await h.send(.object(.animal, false), .webhook)
        #expect(await h.state().objects.isEmpty, "explicit webhook stop")
        #expect(EventRouter.objectHold == .seconds(60))
    }

    @Test func tamperAudioAndInputsAreLevels() async {
        let h = await RouterHarness()
        await h.send(.tamper(true))
        await h.send(.audioAlarm(true))
        await h.send(.digitalInput(id: "1", active: true))
        await h.send(.digitalInput(id: "2", active: false))
        var state = await h.state()
        #expect(state.tampered && state.audioAlarm && state.digitalInputs == ["1": true, "2": false])
        await h.send(.tamper(false))
        await h.send(.audioAlarm(false))
        await h.send(.digitalInput(id: "1", active: false))
        state = await h.state()
        #expect(!state.tampered && !state.audioAlarm && state.digitalInputs == ["1": false, "2": false])
        await h.send(.tamper(true), .webhook)
        h.advance(3_600)
        #expect(await h.state().tampered, "a webhook tamper lasts until tamper/stop")
        await h.send(.tamper(false), .webhook)
        #expect(await !h.state().tampered)
    }

    @Test func alarmInputsAreBounded() async {
        final class Sink: LogSink {
            let messages = Box<[String]>([])
            func record(_ entry: LogEntry) { if entry.category == "Camera", entry.level == .warning { messages.update { $0.append(entry.message) } } }
        }
        let sink = Sink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let h = await RouterHarness()
        await h.send(.digitalInput(id: String(repeating: "x", count: EventRouter.maximumInputIDLength + 1), active: true))
        await h.send(.digitalInput(id: "", active: true))
        await h.send(.digitalInput(id: "in\n1", active: true))
        await h.send(.digitalInput(id: String(repeating: "y", count: EventRouter.maximumInputIDLength), active: true))
        for index in 0..<5_000 { await h.send(.digitalInput(id: "io\(index)", active: index.isMultiple(of: 2))) }
        var state = await h.state()
        #expect(state.digitalInputs.count == EventRouter.maximumInputsPerCamera)
        #expect(state.digitalInputs[String(repeating: "y", count: EventRouter.maximumInputIDLength)] == true)
        #expect(state.digitalInputs["io0"] == true && state.digitalInputs["io4999"] == nil)
        await h.send(.digitalInput(id: "io0", active: false))
        state = await h.state()
        #expect(state.digitalInputs["io0"] == false, "known inputs still change")
        #expect(sink.messages.value.filter { $0.contains("alarm inputs") && $0.hasPrefix("Driveway") }.count == 1, "warned once")
        #expect(EventRouter.maximumInputsPerCamera == 2 * SensorsBridge.maximumInputsPerCamera)
    }

    @Test func dayNightTemperatureAndHumidity() async {
        let h = await RouterHarness()
        #expect(await h.state().isNight == nil)
        await h.send(.dayNight(isNight: true))
        await h.send(.temperature(celsius: 21.5))
        await h.send(.humidity(percent: 40))
        await h.send(.temperature(celsius: .nan))
        await h.send(.humidity(percent: .infinity))
        let state = await h.state()
        #expect(state.isNight == true && state.temperature == 21.5 && state.humidity == 40)
    }

    @Test func lastEventRecordsRisingEdges() async {
        let h = await RouterHarness(kind: .doorbell)
        #expect(await h.state().lastEvent == nil)
        await h.send(.motion(true))
        #expect(await h.state().lastEvent == "Motion")
        #expect(await h.state().lastEventDate == Date(timeIntervalSince1970: 1_800_000_000))
        h.advance(4)
        await h.send(.object(.package, true))
        #expect(await h.state().lastEvent == "Package")
        h.advance(4)
        await h.send(.doorbellPressed)
        #expect(await h.state().lastEvent == "Doorbell ring")
        #expect(await h.state().lastEventDate == Date(timeIntervalSince1970: 1_800_000_008))
        await h.send(.motion(false))
        await h.send(.tamper(true))
        #expect(await h.state().lastEvent == "Tamper")
        await h.send(.digitalInput(id: "2", active: true))
        #expect(await h.state().lastEvent == "Alarm input 2")
    }

    /// The camera page's "Recent Events" come from this history, not from the log: a log level of Notice or above drops
    /// the router's Info entries before any sink sees them, and the event history must not go empty with it. (The
    /// level is global, so this test doesn't change it; the history never goes through `Log`.)
    @Test func recentEventsAreKeptWhateverTheLogLevel() async {
        let h = await RouterHarness(kind: .doorbell)
        #expect(await h.state().recentEvents.isEmpty)
        await h.send(.motion(true))
        h.advance(4)
        await h.send(.doorbellPressed)
        await h.send(.motion(false))   // ends are not events
        h.advance(4)
        await h.send(.object(.person, true))
        let events = await h.state().recentEvents
        #expect(events.map(\.name) == ["Motion", "Doorbell ring", "Person"], "oldest first")
        #expect(events.map(\.date) == [Date(timeIntervalSince1970: 1_800_000_000), Date(timeIntervalSince1970: 1_800_000_004),
                                       Date(timeIntervalSince1970: 1_800_000_008)])
        #expect(Set(events.map(\.id)).count == 3)

        var status = CameraStatus(id: h.cameraID, name: "Driveway", kind: .doorbell, vendor: .hikvision)
        await h.state().apply(to: &status)
        #expect(status.recentEvents == events)
    }

    @Test func recentEventsKeepTheNewestOnly() async {
        let h = await RouterHarness()
        for index in 0..<(EventRouter.recentEventLimit + 5) {
            await h.send(.digitalInput(id: "\(index)", active: true))
        }
        let events = await h.state().recentEvents
        #expect(events.count == EventRouter.recentEventLimit)
        #expect(events.last?.name == "Alarm input \(EventRouter.recentEventLimit + 4)")
    }

    @Test func stateSnapshotsAreEmittedOnChangeOnly() async {
        let h = await RouterHarness()
        let before = h.outputs.value.count
        await h.send(.temperature(celsius: 20))
        await h.send(.temperature(celsius: 20))
        let states = h.outputs.value.dropFirst(before).compactMap { if case .state(let state) = $0 { state } else { nil } }
        #expect(states.count == 1 && states.first?.temperature == 20 && states.first?.id == h.cameraID)
    }
}

@Suite(.timeLimit(.minutes(1))) struct EventRouterHealthTests {
    @Test func eventChannelConnectivityDrivesTheFault() async {
        let h = await RouterHarness()
        var state = await h.state()
        #expect(state.eventChannelConnected == nil && !state.isFault && state.isActive && state.isReachable)
        await h.send(.eventChannel(connected: true))
        state = await h.state()
        #expect(state.eventChannelConnected == true && !state.isFault)
        await h.send(.eventChannel(connected: false))
        state = await h.state()
        #expect(state.eventChannelConnected == true && !state.isFault, "a drop is a fault only after the reconnect grace")
        h.advance(5)
        state = await h.state()
        #expect(state.eventChannelConnected == false && state.isFault && !state.isActive && state.isReachable)
        #expect(state.connection == .idle)
    }

    /// Review finding (W4): every routine event-channel reconnect (a subscription that expired, a camera that closed its
    /// alert stream) blipped StatusFault 1 → 0 to every controller, although the channel was back at once.
    @Test func aQuickEventChannelReconnectRaisesNoFault() async {
        let h = await RouterHarness()
        await h.send(.eventChannel(connected: true))
        await h.send(.eventChannel(connected: false))
        h.advance(2)
        await h.send(.eventChannel(connected: true))
        h.advance(10)
        #expect(!(await h.state()).isFault)
        let faults = h.outputs.value.filter { if case .state(let state) = $0 { state.isFault } else { false } }
        #expect(faults.isEmpty, "no StatusFault blip")

        // A channel that stays down is a fault once the grace ran out, without anyone asking.
        await h.send(.eventChannel(connected: false))
        #expect(await eventually { h.clock.sleeperCount >= 1 })
        h.advance(5)
        #expect(await eventually {
            h.outputs.value.contains { if case .state(let state) = $0 { state.isFault } else { false } }
        })
        // A channel that never connected is a fault at once (nothing to wait for).
        let fresh = await RouterHarness()
        await fresh.send(.eventChannel(connected: false))
        #expect(await fresh.state().isFault)
    }

    @Test func rejectedCredentialsTakeTheCameraOffline() async {
        let h = await RouterHarness()
        await h.router.setStreamConnection(.online, for: h.cameraID)
        await h.send(.authenticationFailed)
        var state = await h.state()
        #expect(state.connection == .offline("Camera rejected the username or password"))
        #expect(state.lastError == "Camera rejected the username or password" && state.lastError == SensorState.credentialsRejectedMessage)
        #expect(state.credentialsRejected && state.isFault && !state.isActive && !state.isReachable)
        await h.router.setStreamConnection(.online, for: h.cameraID)
        #expect(await h.state().credentialsRejected, "the stream working does not mean the event channel's login does")
        await h.send(.eventChannel(connected: true))
        state = await h.state()
        #expect(!state.credentialsRejected && state.connection == .online && state.lastError == nil && state.isActive)
    }

    @Test func rejectedStreamCredentialsClearWhenTheStreamComesBack() async {
        let h = await RouterHarness()
        await h.send(.authenticationFailed, .stream)
        #expect(await h.state().connection == .offline(SensorState.credentialsRejectedMessage))
        await h.send(.eventChannel(connected: true))
        #expect(await h.state().credentialsRejected, "the event channel's login says nothing about RTSP")
        await h.router.setStreamConnection(.online, for: h.cameraID)
        #expect(await !h.state().credentialsRejected)
    }

    @Test func anOfflineStreamIsUnreachableWithItsReason() async {
        let h = await RouterHarness()
        await h.router.setStreamConnection(.connecting, for: h.cameraID)
        #expect(await h.state().isReachable)
        await h.router.setStreamConnection(.offline("Connection timed out"), for: h.cameraID)
        let state = await h.state()
        #expect(!state.isReachable && state.isFault && !state.isActive && state.lastError == "Connection timed out")
    }

    @Test func disabledCamerasIgnoreEventsAndAreInactive() async {
        let h = await RouterHarness()
        await h.send(.motion(true))
        #expect(h.motion == [true])
        var camera = CameraConfiguration(id: h.cameraID, name: "Driveway", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "x"),
                                         username: "")
        camera.isEnabled = false
        await h.router.register(camera)
        #expect(h.motion == [true, false], "disabling ends motion")
        await h.send(.motion(true))
        let state = await h.state()
        #expect(!state.motion && state.connection == .disabled && !state.isActive && !state.isReachable && !state.isFault)
    }

    @Test func unknownCamerasAreIgnoredAndUnregisteringForgets() async {
        let h = await RouterHarness()
        await h.router.handle(.motion(true), for: UUID(), origin: .camera)
        #expect(h.outputs.value.isEmpty || h.motion.isEmpty)
        await h.send(.motion(true))
        await h.router.unregister(cameraID: h.cameraID)
        #expect(await h.router.state(for: h.cameraID) == nil)
        #expect(h.motion == [true, false], "a removed camera's motion ends")
        #expect(await h.router.states.isEmpty)
    }

    @Test func statusProjection() async {
        let h = await RouterHarness()
        await h.router.setStreamConnection(.online, for: h.cameraID)
        await h.send(.eventChannel(connected: true))
        await h.send(.motion(true))
        let state = await h.state()
        var status = CameraStatus(id: h.cameraID, name: "Driveway", kind: .camera, vendor: .hikvision, lastError: "old")
        state.apply(to: &status)
        #expect(status.connection == .online && status.eventChannelConnected && status.motionActive)
        #expect(status.lastEvent == "Motion" && status.lastEventDate == Date(timeIntervalSince1970: 1_800_000_000) && status.lastError == nil)
    }
}

@Suite(.timeLimit(.minutes(1))) struct EventRouterPlumbingTests {
    @Test func outputsReachStreamSubscribersToo() async {
        let h = await RouterHarness()
        let received = Box<[EventRouterOutput]>([])
        let stream = h.router.outputs
        let task = Task { for await output in stream { received.update { $0.append(output) } } }
        await h.send(.doorbellPressed)
        #expect(await eventually { received.value.contains(.doorbell(cameraID: h.cameraID)) })
        #expect(await eventually { received.value.contains(.motion(cameraID: h.cameraID, active: true)) })
        task.cancel()
    }

    @Test func consumeForwardsCameraAndWebhookStreams() async {
        let h = await RouterHarness()
        let (events, continuation) = AsyncStream.makeStream(of: CameraEvent.self)
        let task = h.router.consume(events, for: h.cameraID, origin: .camera)
        continuation.yield(.eventChannel(connected: true))
        continuation.yield(.object(.person, true))
        continuation.finish()
        await task.value
        #expect(await h.state().objects == [.person])
        #expect(await h.state().eventChannelConnected == true)

        let (webhook, webhookContinuation) = AsyncStream.makeStream(of: (cameraID: UUID, event: CameraEvent).self)
        let webhookTask = h.router.consumeWebhook(webhook)
        webhookContinuation.yield((h.cameraID, .motion(true)))
        webhookContinuation.yield((UUID(), .motion(true)))
        webhookContinuation.finish()
        await webhookTask.value
        #expect(await h.state().motion)
        h.advance(20)
        #expect(await !h.state().motion, "webhook motion is a pulse")
    }

    @Test func eventsAreLoggedUnderTheEventsCategory() async {
        final class Sink: LogSink {
            let entries = Box<[LogEntry]>([])
            func record(_ entry: LogEntry) { entries.update { $0.append(entry) } }
        }
        let sink = Sink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let h = await RouterHarness(kind: .doorbell)
        await h.send(.motion(true))
        await h.send(.doorbellPressed)
        await h.send(.object(.person, true))
        await h.send(.authenticationFailed)
        let mine = sink.entries.value.filter { $0.cameraID == h.cameraID }
        let events = mine.filter { $0.category == "Events" }.map(\.message)
        #expect(events.contains("Driveway motion detected"))
        #expect(events.contains("Driveway doorbell ring"))
        #expect(events.contains("Driveway person detected"))
        #expect(mine.contains { $0.category == "Camera" && $0.level == .warning && $0.message.contains("rejected the username or password") })
    }
}
