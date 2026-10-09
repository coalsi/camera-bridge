import BridgeSupport
import CameraAdapters
import Foundation

/// Who keeps a signal on: an origin (its level or its hold), or the motion pulse of a doorbell press.
enum HoldOwner: Hashable, Sendable {
    case origin(EventOrigin)
    /// No stop from any origin ends it (a webhook `motion/stop` must not swallow a ring's recording trigger).
    case doorbell
}

/// A true/false signal fed by several origins: on while an origin that reports ends says so (a level), and while any
/// owner's hold lasts. Every owner has its own hold:
/// - a start holds the signal for `hold` from that start (pulses: webhook, user, doorbell);
/// - an origin that reports ends holds it `hold` after its last activity, which it saw `lag` before it reported the
///   end (the delay that origin already adds itself: CameraAdapters' pulse hold, SoftMotionDetector's quiet period);
/// - a stop from an origin that does not report ends (webhook, user) is explicit: it ends that origin's own hold at
///   once, while other owners' levels and holds stay.
/// Without a hold every origin is a level (tamper: on until its stop).
struct HeldSignal: Sendable, Equatable {
    private(set) var levels: Set<EventOrigin> = []
    private(set) var holds: [HoldOwner: Duration] = [:]

    func isActive(at now: Duration) -> Bool {
        !levels.isEmpty || holds.values.contains { now < $0 }
    }

    /// The earliest hold end still ahead.
    func deadline(after now: Duration) -> Duration? {
        holds.values.filter { $0 > now }.min()
    }

    mutating func start(from owner: HoldOwner, at now: Duration, hold: Duration) {
        if case .origin(let origin) = owner, origin.reportsEnds || hold <= .zero { levels.insert(origin) }
        extend(owner, until: now + hold, now: now)
    }

    /// `origin` reports the end. An origin that reports ends keeps the signal on until `hold` after its last activity
    /// (`now - lag`); any other origin's stop ends its own hold at once.
    mutating func stop(from origin: EventOrigin, at now: Duration, hold: Duration, lag: Duration) {
        let wasLevel = levels.remove(origin) != nil
        if origin.reportsEnds {
            if wasLevel { extend(.origin(origin), until: now - lag + hold, now: now) }
        } else {
            holds[.origin(origin)] = nil
        }
    }

    /// `origin`'s source went away while its levels were on: they end now and are held for `hold` from now (its last
    /// activity may have been just now).
    mutating func endLevels(from origin: EventOrigin, at now: Duration, hold: Duration) {
        if levels.remove(origin) != nil { extend(.origin(origin), until: now + hold, now: now) }
    }

    private mutating func extend(_ owner: HoldOwner, until end: Duration, now: Duration) {
        holds = holds.filter { $0.value > now }   // holds that ran out are forgotten
        guard end > now else { return }
        holds[owner] = max(holds[owner] ?? end, end)
    }
}

/// Turns each camera's `CameraEvent`s into debounced state (spec §3.3/§3.4, integration brief §3–§5):
///
/// - motion: on while an origin that reports ends (camera event channel, soft motion, stream) reports it, and for
///   `motionHoldSeconds` (≥ 1 s) after the last activity: after each start, and after each end those origins report.
///   Where the origin's end already trails the last activity, only the rest of the hold is added: Hikvision's event
///   channel reports the end `cameraPulseHold` (20 s) after the last pulse (CameraAdapters holds them), soft motion
///   `softMotionQuietPeriod` (10 s) after the last movement. Other vendors' camera events end when the camera says so
///   (ONVIF MotionAlarm, Reolink, demo) and get the whole hold after that. Webhook/user starts are pulses; a webhook
///   stop ends the webhook's own hold at once (other origins' levels and holds, and the doorbell pulse, stay).
/// - detections (person, vehicle, …): the same with a 60 s hold (occupancy sensors).
/// - doorbell: presses within 3 s of the last accepted one are dropped; an accepted press is `.doorbell` followed by a
///   motion pulse (HKSV records it even when hubs ignore doorbell triggers) that no stop ends.
/// - tamper, audio alarm, alarm inputs: levels (at most `maximumInputsPerCamera` alarm inputs per camera, ids up to
///   `maximumInputIDLength` characters without control characters; others are dropped with one warning). Day/night,
///   temperature, humidity: latest (finite) value.
/// - event channel: `.eventChannel(connected: false)` is a fault — after `eventChannelGrace` (5 s) when the channel was
///   connected, so a routine reconnect (a subscription that expired, a closed alert stream) raises none;
///   `.authenticationFailed` takes the camera offline
///   ("Camera rejected the username or password") until the same side (event channel, or stream via
///   `setStreamConnection(.online)`) succeeds again. Level states are not reset on a disconnect (CameraAdapters ends them).
///
/// Every change is reported as `EventRouterOutput` to the handler (synchronously, on the actor) and to `outputs`
/// subscribers; `.state` carries the new `SensorState`. Hold timers use the injected clock; reads (`state(for:)`,
/// `states`) also apply expired holds, so a manual test clock needs no waiting. Motion, doorbell and detection
/// transitions are logged under category "Events" with the camera's id; connection and credential changes and dropped
/// alarm inputs under "Camera".
/// Events for unknown or disabled cameras are ignored.
public actor EventRouter {
    public static let objectHold: Duration = .seconds(60)
    public static let ringDedupe: Duration = .seconds(3)
    /// Holds shorter than this are raised to it.
    public static let minimumMotionHold: Duration = .seconds(1)
    /// Alarm inputs kept per camera (twice what the sensors bridge publishes, so it can still choose).
    public static let maximumInputsPerCamera = 2 * SensorsBridge.maximumInputsPerCamera
    public static let maximumInputIDLength = SensorsBridge.maximumInputIDLength
    /// Events kept per camera in `SensorState.recentEvents` (the newest).
    public static let recentEventLimit = 20
    /// How long CameraAdapters holds a pulse event (Hikvision alertStream VMD and smart events) before it reports the end.
    static let cameraPulseHold: Duration = .seconds(20)
    /// How long SoftMotionDetector waits without movement before it reports the end.
    static let softMotionQuietPeriod: Duration = .seconds(10)
    /// How long a connected event channel may be down before it counts as a fault (adapters reconnect at once after a
    /// routine end).
    static let eventChannelGrace: Duration = .seconds(5)

    private struct Camera {
        var name: String
        var vendor: CameraVendor
        var motionHold: Duration
        var isEnabled: Bool
        var motion = HeldSignal()
        var objects: [DetectedObjectKind: HeldSignal] = [:]
        var tamper = HeldSignal()
        var audioAlarm = HeldSignal()
        var inputs: [String: Bool] = [:]
        var isNight: Bool?
        var temperature: Double?
        var humidity: Double?
        var eventChannelConnected: Bool?
        /// When a connected event channel went down (cleared when it is back): not a fault for `eventChannelGrace`.
        var eventChannelDownSince: Duration?
        var streamConnection: ConnectionState = .idle
        /// `.camera` for the event channel's login, `.stream` for the ingest's.
        var rejectedBy: Set<EventOrigin> = []
        var lastRing: Duration?
        var lastRingDate: Date?
        var ringPending = false
        var lastEvent: String?
        var lastEventDate: Date?
        var recentEvents: [CameraEventRecord] = []
        var published: SensorState?
        var timer: (deadline: Duration, task: Task<Void, Never>)?
        /// Alarm inputs were dropped (over the limit or an unusable id); warned once.
        var droppedInputs = false

        init(_ configuration: CameraConfiguration) {
            name = configuration.name
            vendor = configuration.vendor
            motionHold = EventRouter.motionHold(configuration)
            isEnabled = configuration.isEnabled
        }

        /// How long after the last activity `origin` reports an end (see `HeldSignal.stop`).
        func endLag(_ origin: EventOrigin) -> Duration {
            switch origin {
            // Every Hikvision motion and detection event is a pulse that CameraAdapters holds; other vendors' motion
            // and detections are mostly levels the camera ends itself.
            case .camera: vendor == .hikvision ? EventRouter.cameraPulseHold : .zero
            case .softMotion: EventRouter.softMotionQuietPeriod
            case .webhook, .stream, .user: .zero
            }
        }

        /// The event channel as published: a connected channel that went down still reads connected for the grace.
        func publishedEventChannel(at now: Duration) -> Bool? {
            if eventChannelConnected == false, let since = eventChannelDownSince, now - since < EventRouter.eventChannelGrace { return true }
            return eventChannelConnected
        }

        func snapshot(id: UUID, at now: Duration) -> SensorState {
            SensorState(id: id, motion: motion.isActive(at: now), objects: Set(objects.filter { $0.value.isActive(at: now) }.keys),
                        tampered: tamper.isActive(at: now), audioAlarm: audioAlarm.isActive(at: now), isNight: isNight,
                        digitalInputs: inputs, temperature: temperature, humidity: humidity, eventChannelConnected: publishedEventChannel(at: now),
                        streamConnection: streamConnection, credentialsRejected: !rejectedBy.isEmpty, isEnabled: isEnabled,
                        lastEvent: lastEvent, lastEventDate: lastEventDate, lastRingDate: lastRingDate, recentEvents: recentEvents)
        }

        func nextDeadline(after now: Duration) -> Duration? {
            let channel = eventChannelDownSince.map { $0 + EventRouter.eventChannelGrace }.flatMap { $0 > now ? $0 : nil }
            return ([motion.deadline(after: now), tamper.deadline(after: now), audioAlarm.deadline(after: now), channel]
                + objects.values.map { $0.deadline(after: now) }).compactMap { $0 }.min()
        }

        /// Ends every signal (camera disabled).
        mutating func resetAll() {
            motion = HeldSignal()
            objects = [:]
            tamper = HeldSignal()
            audioAlarm = HeldSignal()
            for id in inputs.keys { inputs[id] = false }
            eventChannelConnected = nil
            eventChannelDownSince = nil
            rejectedBy = []
            ringPending = false
        }
    }

    private let clock: ElapsedClock
    private let date: @Sendable () -> Date
    private let broadcaster = AsyncBroadcaster<EventRouterOutput>(bufferingNewest: 1024)
    private var handler: (@Sendable (EventRouterOutput) -> Void)?
    private var cameras: [UUID: Camera] = [:]

    /// `clock` drives hold timers (a manual clock in tests); `date` stamps `lastEventDate` / `lastRingDate`.
    public init(clock: any Clock<Duration> = ContinuousClock(), date: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = ElapsedClock(clock)
        self.date = date
    }

    deinit {
        for camera in cameras.values { camera.timer?.task.cancel() }
        broadcaster.finish()
    }

    /// Every output, for each subscriber from the moment it subscribes (buffers the newest 1024).
    public nonisolated var outputs: AsyncStream<EventRouterOutput> { broadcaster.subscribe() }

    /// Called synchronously on the router for every output, before `outputs` subscribers see it. Keep it short.
    public func setOutputHandler(_ handler: (@Sendable (EventRouterOutput) -> Void)?) {
        self.handler = handler
    }

    /// Adds a camera or applies a changed configuration (name, hold, enabled). Disabling ends every state.
    public func register(_ configuration: CameraConfiguration) {
        let id = configuration.id
        if var camera = cameras[id] {
            camera.name = configuration.name
            camera.vendor = configuration.vendor
            camera.motionHold = Self.motionHold(configuration)
            if camera.isEnabled != configuration.isEnabled {
                camera.isEnabled = configuration.isEnabled
                camera.resetAll()
                camera.streamConnection = .idle
            }
            cameras[id] = camera
        } else {
            cameras[id] = Camera(configuration)
        }
        publish(id)
    }

    /// Forgets a camera (its motion ends).
    public func unregister(cameraID: UUID) {
        guard let camera = cameras.removeValue(forKey: cameraID) else { return }
        camera.timer?.task.cancel()
        if camera.published?.motion == true { emit(.motion(cameraID: cameraID, active: false)) }
    }

    public func handle(_ event: CameraEvent, for cameraID: UUID, origin: EventOrigin = .camera) {
        guard var camera = cameras[cameraID], camera.isEnabled else { return }
        let now = clock.now()
        let lag = camera.endLag(origin)
        let log = Log(category: "Camera", cameraID: cameraID)
        switch event {
        case .motion(true):
            camera.motion.start(from: .origin(origin), at: now, hold: camera.motionHold)
        case .motion(false):
            camera.motion.stop(from: origin, at: now, hold: camera.motionHold, lag: lag)
        case .object(let kind, true):
            camera.objects[kind, default: HeldSignal()].start(from: .origin(origin), at: now, hold: Self.objectHold)
        case .object(let kind, false):
            camera.objects[kind]?.stop(from: origin, at: now, hold: Self.objectHold, lag: lag)
        case .doorbellPressed:
            if let last = camera.lastRing, now - last < Self.ringDedupe { break }
            camera.lastRing = now
            camera.lastRingDate = date()
            camera.ringPending = true
            camera.motion.start(from: .doorbell, at: now, hold: camera.motionHold)
        case .tamper(let active):
            if active {
                camera.tamper.start(from: .origin(origin), at: now, hold: .zero)
            } else {
                camera.tamper.stop(from: origin, at: now, hold: .zero, lag: .zero)
            }
        case .audioAlarm(let active):
            if active {
                camera.audioAlarm.start(from: .origin(origin), at: now, hold: .zero)
            } else {
                camera.audioAlarm.stop(from: origin, at: now, hold: .zero, lag: .zero)
            }
        case .digitalInput(let id, let active):
            if camera.inputs[id] != nil || (Self.isUsableInputID(id) && camera.inputs.count < Self.maximumInputsPerCamera) {
                camera.inputs[id] = active
            } else if !camera.droppedInputs {
                camera.droppedInputs = true
                log.warning(
                    "\(camera.name) reported more than \(Self.maximumInputsPerCamera) alarm inputs or an unusable input id "
                        + "(empty, longer than \(Self.maximumInputIDLength) characters or with control characters); those inputs are ignored")
            }
        case .dayNight(let isNight):
            if camera.isNight != isNight { Log(category: "Events", cameraID: cameraID).info("\(camera.name) switched to \(isNight ? "night" : "day")") }
            camera.isNight = isNight
        case .temperature(let celsius):
            if celsius.isFinite { camera.temperature = celsius }
        case .humidity(let percent):
            if percent.isFinite { camera.humidity = percent }
        case .eventChannel(let connected):
            if camera.eventChannelConnected != connected {
                log.info("\(camera.name) event channel \(connected ? "connected" : "disconnected")")
            }
            if connected {
                camera.eventChannelDownSince = nil
            } else if camera.eventChannelConnected == true {
                camera.eventChannelDownSince = now
            }
            camera.eventChannelConnected = connected
            if connected { camera.rejectedBy.remove(.camera) }
        case .eventChannelUnreliable(let shortSessions):
            log.warning("\(camera.name): the camera's event channel ended \(shortSessions) times in a row right after connecting; its events are unreliable")
        case .authenticationFailed:
            let side: EventOrigin = origin == .stream ? .stream : .camera
            if camera.rejectedBy.insert(side).inserted {
                log.warning("\(camera.name): the camera rejected the username or password (\(side == .stream ? "stream" : "event channel"))")
            }
        }
        cameras[cameraID] = camera
        publish(cameraID)
    }

    /// A motion pulse from the app (`BridgeEngine.triggerTestMotion`).
    public func triggerMotion(for cameraID: UUID) {
        handle(.motion(true), for: cameraID, origin: .user)
    }

    /// The ingest's connection state (from `CameraRuntime`). `.online` clears rejected stream credentials.
    public func setStreamConnection(_ state: ConnectionState, for cameraID: UUID) {
        guard var camera = cameras[cameraID] else { return }
        if camera.streamConnection != state, case .offline(let reason) = state {
            Log(category: "Camera", cameraID: cameraID).notice("\(camera.name) is offline: \(reason)")
        }
        camera.streamConnection = state
        if state == .online { camera.rejectedBy.remove(.stream) }
        cameras[cameraID] = camera
        publish(cameraID)
    }

    /// `origin`'s source stopped (camera reconfigured, event source replaced, decoded stream for soft motion gone): its
    /// motion and detection levels end and are held for the whole hold from now (holds already running continue),
    /// tamper and sound end at once, and for `.camera` its alarm inputs read inactive and the event channel is gone
    /// (not a fault).
    public func resetOrigin(_ origin: EventOrigin, for cameraID: UUID) {
        guard var camera = cameras[cameraID] else { return }
        let now = clock.now()
        camera.motion.endLevels(from: origin, at: now, hold: camera.motionHold)
        for kind in Array(camera.objects.keys) { camera.objects[kind]?.endLevels(from: origin, at: now, hold: Self.objectHold) }
        camera.tamper.endLevels(from: origin, at: now, hold: .zero)
        camera.audioAlarm.endLevels(from: origin, at: now, hold: .zero)
        if origin == .camera {
            for id in camera.inputs.keys { camera.inputs[id] = false }
            camera.eventChannelConnected = nil
            camera.eventChannelDownSince = nil
            camera.rejectedBy.remove(.camera)
        }
        if origin == .stream { camera.rejectedBy.remove(.stream) }
        cameras[cameraID] = camera
        publish(cameraID)
    }

    /// The camera's current state (expired holds applied first); nil for an unknown camera.
    public func state(for cameraID: UUID) -> SensorState? {
        guard cameras[cameraID] != nil else { return nil }
        publish(cameraID)
        return cameras[cameraID]?.published
    }

    /// Runs `body` with the camera's current state (nil for an unknown camera) on the router, so no output is emitted
    /// between the read and `body`: a runtime registers its controller and applies the state in one step, and every
    /// later output reaches the controller through the output handler.
    func withCurrentState(for cameraID: UUID, _ body: @Sendable (SensorState?) -> Void) {
        body(state(for: cameraID))
    }

    /// Whether `origin`'s side (`.camera`: the event channel's login, `.stream`: the ingest's) has the camera's
    /// rejection of the credentials on record.
    func credentialsRejected(by origin: EventOrigin, for cameraID: UUID) -> Bool {
        cameras[cameraID]?.rejectedBy.contains(origin) ?? false
    }

    /// Every registered camera's current state.
    public var states: [SensorState] {
        Array(cameras.keys).compactMap { state(for: $0) }
    }

    /// Feeds `events` (a camera's event source, soft motion, …) into the router until the stream ends.
    public nonisolated func consume(_ events: AsyncStream<CameraEvent>, for cameraID: UUID, origin: EventOrigin) -> Task<Void, Never> {
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event, for: cameraID, origin: origin)
            }
        }
    }

    /// What a webhook's camera ID names, by the rule `handle` drops events with: `.unknown` when no registered camera has
    /// the ID, `.disabled` when it is turned off. The engine's `WebhookServer` answers 404 / 409 for those (publishing
    /// nothing) instead of a 204 for an event that would be dropped here.
    func webhookCameraState(_ cameraID: UUID) -> WebhookServer.CameraState {
        guard let camera = cameras[cameraID] else { return .unknown }
        return camera.isEnabled ? .enabled : .disabled
    }

    /// Feeds `WebhookServer.events` into the router (origin `.webhook`) until the stream ends.
    public nonisolated func consumeWebhook(_ events: AsyncStream<(cameraID: UUID, event: CameraEvent)>) -> Task<Void, Never> {
        Task { [weak self] in
            for await (cameraID, event) in events {
                guard let self else { return }
                await self.handle(event, for: cameraID, origin: .webhook)
            }
        }
    }

    // MARK: - Private

    static func motionHold(_ configuration: CameraConfiguration) -> Duration {
        max(minimumMotionHold, .seconds(max(0, configuration.motionHoldSeconds)))
    }

    /// Non-empty, at most `maximumInputIDLength` characters, no control characters (ids reach logs and Home names).
    static func isUsableInputID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= maximumInputIDLength
            && !id.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }
    }

    /// Emits what changed since the last publication (ring, motion, state), records rising edges as the last event,
    /// logs transitions and re-arms the camera's timer.
    private func publish(_ id: UUID) {
        guard var camera = cameras[id] else { return }
        let now = clock.now()
        var state = camera.snapshot(id: id, at: now)
        let previous = camera.published ?? SensorState(id: id, isEnabled: camera.isEnabled)
        let events = Log(category: "Events", cameraID: id)
        let name = camera.name
        var risingEdges: [String] = []   // most specific first

        if camera.ringPending {
            events.info("\(name) doorbell ring")
            risingEdges.append("Doorbell ring")
        }
        for kind in DetectedObjectKind.allCases where state.objects.contains(kind) != previous.objects.contains(kind) {
            let active = state.objects.contains(kind)
            events.info("\(name) \(kind.rawValue) \(active ? "detected" : "cleared")")
            if active { risingEdges.append(kind.rawValue.capitalized) }
        }
        if state.motion != previous.motion {
            events.info("\(name) motion \(state.motion ? "detected" : "ended")")
            if state.motion { risingEdges.append("Motion") }
        }
        if state.tampered != previous.tampered {
            events.info("\(name) tamper \(state.tampered ? "detected" : "cleared")")
            if state.tampered { risingEdges.append("Tamper") }
        }
        for (input, active) in state.digitalInputs.sorted(by: { $0.key < $1.key }) where active != (previous.digitalInputs[input] ?? false) {
            events.info("\(name) alarm input \(input) \(active ? "active" : "inactive")")
            if active { risingEdges.append("Alarm input \(input)") }
        }
        if state.audioAlarm != previous.audioAlarm {
            events.info("\(name) sound \(state.audioAlarm ? "detected" : "ended")")
            if state.audioAlarm { risingEdges.append("Sound") }
        }
        if let latest = risingEdges.first {
            let stamp = date()
            camera.lastEvent = latest
            camera.lastEventDate = stamp
            // The history the camera page shows (not derived from the log, which the log level may filter): the most
            // specific edge last, so it reads first newest-first.
            camera.recentEvents += risingEdges.reversed().map { CameraEventRecord(name: $0, date: stamp) }
            if camera.recentEvents.count > Self.recentEventLimit { camera.recentEvents.removeFirst(camera.recentEvents.count - Self.recentEventLimit) }
            state.lastEvent = camera.lastEvent
            state.lastEventDate = camera.lastEventDate
            state.recentEvents = camera.recentEvents
        }

        let ring = camera.ringPending
        camera.ringPending = false
        let motionChanged = state.motion != previous.motion
        let stateChanged = camera.published != state
        camera.published = state
        cameras[id] = camera
        schedule(id, now: now)

        if ring { emit(.doorbell(cameraID: id)) }
        if motionChanged { emit(.motion(cameraID: id, active: state.motion)) }
        if stateChanged { emit(.state(state)) }
    }

    private func schedule(_ id: UUID, now: Duration) {
        guard var camera = cameras[id] else { return }
        let next = camera.nextDeadline(after: now)
        if let timer = camera.timer, timer.deadline == next { return }
        camera.timer?.task.cancel()
        camera.timer = nil
        if let next {
            let sleep = clock.sleep
            let task = Task { [weak self] in
                do { try await sleep(next) } catch { return }
                await self?.timerFired(id, deadline: next)
            }
            camera.timer = (next, task)
        }
        cameras[id] = camera
    }

    private func timerFired(_ id: UUID, deadline: Duration) {
        guard cameras[id]?.timer?.deadline == deadline else { return }
        cameras[id]?.timer = nil
        publish(id)
    }

    private func emit(_ output: EventRouterOutput) {
        handler?(output)
        broadcaster.yield(output)
    }
}
