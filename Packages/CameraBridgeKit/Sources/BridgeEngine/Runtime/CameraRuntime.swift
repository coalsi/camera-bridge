import BridgeSupport
import CameraAdapters
import Foundation
import HAP
import HAPCamera
import HAPCore
import HDS
import MediaCore
import Synchronization

/// Maps `EventRouter` outputs to each running camera's `CameraController` (motion, doorbell, sensor status, streaming
/// availability). Called synchronously on the router.
final class ControllerRegistry: Sendable {
    private let controllers = Mutex<[UUID: CameraController]>([:])

    func register(_ controller: CameraController, for cameraID: UUID) {
        controllers.withLock { $0[cameraID] = controller }
    }

    func remove(_ cameraID: UUID, ifMatching controller: CameraController? = nil) {
        controllers.withLock { controllers in
            if let controller, controllers[cameraID] !== controller { return }
            controllers[cameraID] = nil
        }
    }

    func apply(_ output: EventRouterOutput) {
        switch output {
        case .motion(let cameraID, let active):
            controllers.withLock { $0[cameraID] }?.setMotionDetected(active)
        case .doorbell(let cameraID):
            controllers.withLock { $0[cameraID] }?.ringDoorbell()
        case .state(let state):
            guard let controller = controllers.withLock({ $0[state.id] }) else { return }
            Self.apply(state, to: controller)
        }
    }

    static func apply(_ state: SensorState, to controller: CameraController) {
        controller.setSensorStatus(active: state.isActive, fault: state.isFault, tampered: state.tampered)
        controller.setStreamingAvailable(state.isEnabled && state.streamConnection == .online)
    }
}

/// What a runtime contributes to `CameraStatus`.
struct RuntimeStatus: Sendable, Equatable {
    var videoSummary: String?
    var isPaired = false
    var setupCode = ""
    var setupURI = ""
    var hapPort: UInt16?
    var recordingEnabled = false
    var recordingNow = false
    var liveViewers = 0
    /// Viewers in CameraBridge's own window (`BridgeEngine.liveVideo`), apart from the HomeKit viewers.
    var appViewers = 0
    /// Why the sub stream is offline while it should run (`CameraStatus.subStreamProblem`).
    var subStreamProblem: String?
    /// `CameraStatus.eventsNote`.
    var eventsNote: String?
    /// `CameraStatus.homeKitNote`.
    var homeKitNote: String?
    var liveSessions: [LiveSessionStatus] = []
    var recordingSession: RecordingSessionStatus?
    var mainStreamInfo: SourceStreamInfo?
    var subStreamInfo: SourceStreamInfo?
    /// `CameraStatus.motionShadow`.
    var motionShadow: MotionShadowStatus?
}

/// One camera's bridge (plan W3-1 items 1, 2, 6, 8): media ingest (main stream always, sub stream on demand) into
/// `MediaHub`s, the HAP accessory (`CameraController` + `AccessoryServer` on the camera's port, `FileHAPStore` in
/// `hap/<uuid>/`), the streaming / recording / snapshot delegates, and the event path (the driver's event source, or
/// soft motion on the decoded sub stream; the webhook is routed by the engine) into the shared `EventRouter`.
///
/// Reentrancy: `start`, `stop`, `refresh`, the ONVIF probe task and the sub stream's idle stop interleave at every
/// suspension. Work begun under one `epoch` (bumped by every start and stop) re-checks it after each suspension and
/// undoes what it started once the runtime stopped, so nothing keeps running after `stop()` returned.
actor CameraRuntime {
    struct Dependencies: Sendable {
        var environment: BridgeEnvironment
        var router: EventRouter
        var registry: ControllerRegistry
        var tuning: EngineTuning
        /// `BridgeSettings.motionShadowTest` when the runtime is made (`setMotionShadowTest` changes it while it runs).
        var motionShadowTest = false
        /// Runtime status changed (engine refreshes `cameras`).
        var onChange: @Sendable () -> Void
        /// A connection revealed the Local Network permission state.
        var onLocalNetwork: @Sendable (LocalNetworkAccess) -> Void
        /// A live view's controller advertised an address that looks like a VPN's (`NetworkNotice`), or the outcome of one.
        var onNetworkNotice: @Sendable (NetworkNotice) -> Void = { _ in }
        /// The go2rtc helper, for the cameras that use it (`CameraVendor.go2rtc`, `.unifi`).
        var go2rtc: (any Go2RTCStreamProviding)?
    }

    private struct Stack: Sendable {
        var accessory: Accessory
        var controller: CameraController
        var server: AccessoryServer
        var dataStream: DataStreamServer
        /// The server's events, subscribed before it started: a Bonjour registration that Local Network privacy refused
        /// during the start is reported too (it is not retried: the engine advertises again once access is granted).
        var events: AsyncStream<AccessoryServerEvent>
    }

    nonisolated let id: UUID
    nonisolated let configuration: CameraConfiguration
    private let credentials: HTTPCredentials?
    private let dependencies: Dependencies
    private let log: Log
    private let store: FileHAPStore
    private let driver: any CameraDriver
    /// Whether the camera answers at all, shared by the ingest, the camera API, the event channel and the snapshots (nil for
    /// the demo camera): while it does not, they send nothing and one probe waits for it on a growing delay.
    private let reachability: CameraReachability?
    private let mainHub = MediaHub()
    /// The timestamp overlay live views and recordings draw (changed in place by `updateTimestampOverlay`).
    private let overlay: TimestampOverlayControl
    private let subHub = MediaHub(retention: .seconds(4))
    private let mainTraits = StreamTraits()
    private let subTraits = StreamTraits()
    private var mainIngest: IngestSupervisor?
    private var subIngest: IngestSupervisor?
    private var subUsers = 0
    /// Subscriptions of the app's own viewers (`openLiveVideo`); never counted as HomeKit viewers.
    private var appViewers = 0
    private var appSubscriptions: [UUID: @Sendable () -> Void] = [:]
    private var subPermanent = false
    /// Bumped by every `acquireSub`: an idle stop scheduled before a later user arrived does not apply.
    private var subGeneration = 0
    private var subIdleStop: Task<Void, Never>?
    private var sourceTask: Task<Void, Never>?
    /// What the stream-address probe loop (`sourceTask`, before `mainIngest` exists) waits for; nil: probing.
    private var probeWait: ProbeWait?
    /// Bumped by every probe loop started: an older loop's waits do not count.
    private var probeGeneration = 0
    /// Remembers the main stream's picture size when the accessory was published before it was known.
    private var formatTask: Task<Void, Never>?
    /// Recording options published without a picture: frozen as soon as a controller pairs with them.
    private var pendingFreeze: AccessoryOptions.Aspect?
    /// Bumped by every start and stop (see the type's documentation).
    private var epoch = 0
    private var stack: Stack?
    private var streaming: StreamingHandler?
    private var recording: RecordingHandler?
    private var snapshots: SnapshotProvider?
    private var eventSource: (any CameraEventSource)?
    private var eventTask: Task<Void, Never>?
    private var softMotion: SoftMotionMonitor?
    /// The motion shadow test is on (`BridgeSettings.motionShadowTest`).
    private var motionShadowWanted: Bool
    /// When the test was turned on (or the runtime made with it on).
    private var motionShadowSince = Date()
    /// The test's recorder and the built-in detector feeding it (on the sub stream, reporting to the recorder only), while
    /// they run. The detector holds one user of the sub stream.
    private var motionShadow: MotionShadowTest?
    private var motionShadowMonitor: SoftMotionMonitor?
    private var motionShadowHoldsSub = false
    /// "Skipped" was logged since the test was turned on.
    private var motionShadowSkipLogged = false
    /// Why the test is not comparing (shown in the status), nil while it is or has not been tried.
    private var motionShadowPause: String?
    /// Soft motion analyses the sub stream (else the main stream).
    private var softMotionOnSub = false
    /// Moves soft motion between the sub and the main stream (`chooseSoftMotionStream`).
    private var softMotionWatch: Task<Void, Never>?
    /// The sub stream's state, as its supervisor reports it.
    private var subState: IngestSupervisor.State = .idle
    /// Since when the sub stream has had no picture while soft motion wants it (nil: it delivers).
    private var subPictureMissingSince: ContinuousClock.Instant?
    /// Why the sub stream is offline while it should run, or was when it last ran: kept across its idle stop until it
    /// delivers a picture again (nil: fine, never failed, or no sub stream).
    private var subStreamProblem: String?
    /// The camera's event channel connected and dropped again and again: soft motion stands in for its motion events.
    private var eventsUnreliable = false
    static let eventsUnreliableNote = "Camera events unreliable; using built-in motion detection"
    private var subEvents: Task<Void, Never>?
    /// Ends the live views on the sub stream once it stayed offline for `subStreamStartWait` (`subStreamWentOffline`).
    private var subOfflineFallback: Task<Void, Never>?
    private var serverEvents: Task<Void, Never>?
    private var ingestEvents: Task<Void, Never>?
    private var operatingEvents: Task<Void, Never>?
    private var cachedSetup: (code: String, uri: String)?
    private var paired = false
    private var running = false
    /// Checks the running accessory's listener, Bonjour record and controller (`HAPHealthMonitor`).
    private var healthMonitor: HAPHealthMonitor?
    /// Soft motion's sensitivity (changed in place by `updateMotionSensitivity`).
    private var motionSensitivity: Double

    init(configuration: CameraConfiguration, credentials: HTTPCredentials?, dependencies: Dependencies) {
        id = configuration.id
        self.configuration = configuration
        self.credentials = credentials
        self.dependencies = dependencies
        log = Log(category: "Camera", cameraID: configuration.id)
        motionSensitivity = configuration.motionSensitivity
        motionShadowWanted = dependencies.motionShadowTest
        overlay = TimestampOverlayControl(settings: configuration.timestampOverlay, cameraName: configuration.name)
        let environment = dependencies.environment
        store = HAPStorage.store(for: configuration.id, dataDirectory: environment.dataDirectory, secrets: environment.platform.secrets)
        if configuration.vendor == .demo || configuration.vendor == .go2rtc {
            reachability = nil   // the demo camera has no network; a go2rtc camera is reached on this Mac, through the helper
        } else {
            let endpoint = configuration.endpoint
            reachability = CameraReachability(host: endpoint.host, ports: [UInt16(clamping: endpoint.httpPort), UInt16(clamping: endpoint.rtspPort)],
                                              transport: environment.platform.transport, timing: dependencies.tuning.reachability, log: log)
        }
        if let factory = dependencies.tuning.driverFactory {
            driver = factory(configuration, credentials, environment.platform.transport)
        } else {
            // Tagged with the camera: its event channel, camera API, RTSP probe and two-way audio lines reach its log.
            driver = CameraDrivers.make(vendor: configuration.vendor, endpoint: configuration.endpoint, credentials: credentials,
                                        mainStreamURL: configuration.mainStreamURL, subStreamURL: configuration.subStreamURL,
                                        transport: environment.platform.transport, cameraID: configuration.id, reachability: reachability,
                                        integration: configuration.integration, go2rtc: dependencies.go2rtc)
        }
    }

    /// `start` / `publish` could not bring the accessory up, but the camera itself (ingest, events, snapshots, the app's
    /// viewers) runs on: only the accessory is tried again, with backoff (`BridgeEngine`), while the stream stays connected.
    struct AccessoryStartFailure: Error, CustomStringConvertible {
        let underlying: any Error

        var description: String { "\(underlying)" }
    }

    /// The camera answers nothing (`CameraReachability.isOffline`): the settings and readiness pages send it nothing.
    nonisolated var isUnreachable: Bool { reachability?.isOffline ?? false }

    /// The HAP port the accessory listens on (nil before `start`).
    var hapPort: UInt16? { get async { await stack?.server.port } }

    var controller: CameraController? { stack?.controller }

    var server: AccessoryServer? { stack?.server }

    /// The main stream's hub (tests, snapshots).
    nonisolated var hub: MediaHub { mainHub }

    /// Tests: whether the sub stream's supervisor runs.
    var isSubStreamRunning: Bool {
        get async { await subIngest?.isRunning ?? false }
    }

    /// Tests: connection attempts of the main and sub stream supervisors (nil before they exist).
    var ingestAttempts: (main: Int?, sub: Int?) {
        get async { (await mainIngest?.attempts, await subIngest?.attempts) }
    }

    /// Work begun at `epoch` may go on: the runtime runs and was not stopped (or restarted) since.
    private func isCurrent(_ epoch: Int) -> Bool {
        running && self.epoch == epoch
    }

    // MARK: - Lifecycle

    /// Starts ingest, the event path and, when `publishing`, the HAP accessory (on `port`, or the next free port while it is
    /// in use, never in `reserved`). Returns the port the accessory listens on (`port` itself while it is not published).
    ///
    /// A camera that is not published still runs for the app's own viewers (live view, snapshots, events); it has no
    /// accessory, so nothing is advertised and Home shows it as not responding. `publish` and `unpublish` switch that
    /// while the camera runs, without touching its connection to the camera or its HomeKit identity.
    @discardableResult
    func start(port: UInt16, reserved: Set<UInt16>, publishing: Bool = true) async throws -> UInt16 {
        guard !running else { return await stack?.server.port ?? port }
        running = true
        epoch &+= 1
        let epoch = epoch
        let name = configuration.name
        log.info("Starting \(name) (\(configuration.vendor.rawValue), \(configuration.kind.rawValue))")
        await dependencies.router.setStreamConnection(.connecting, for: id)
        await startIngest(epoch)
        makeSnapshots()
        var listening = port
        if publishing {
            do {
                listening = try await bringUpAccessory(port: port, reserved: reserved, epoch: epoch)
            } catch is CancellationError {
                throw CancellationError()   // stopped meanwhile: nothing is left to undo
            } catch {
                // The accessory could not start (a refused Keychain, a listener failure): the camera keeps running, its stream stays
                // connected for the app's own viewers and soft motion, and the engine tries the accessory again.
                log.error("\(name): the HomeKit accessory could not start, the camera keeps running without it (\(error))")
                startEvents()
                dependencies.onChange()
                throw AccessoryStartFailure(underlying: error)
            }
        } else {
            log.info("\(name) runs for Camera Bridge's own viewers only: its accessory is not published")
        }
        startEvents()
        dependencies.onChange()
        return listening
    }

    /// Whether the accessory is up (published and advertised).
    var isPublished: Bool { stack != nil }

    /// Started and not stopped since.
    var isRunning: Bool { running }

    /// Brings the accessory up on a running camera that has none (it was held back, `BridgeEngine.homeKitAllowlist`). Its
    /// identity and pairings are the ones in the camera's HAP store, so Home finds the accessory it knew. Returns the port.
    /// Throws when the accessory could not start; the camera then still runs unpublished.
    @discardableResult
    func publish(port: UInt16, reserved: Set<UInt16>) async throws -> UInt16 {
        guard running else { throw EngineError.cameraNotRunning }
        if let stack { return await stack.server.port ?? port }
        return try await bringUpAccessory(port: port, reserved: reserved, epoch: epoch)
    }

    /// Takes the accessory down (live views and recordings end, the Bonjour record is withdrawn) and keeps everything else
    /// running: the ingest, events, snapshots and the app's viewers. The HAP store is untouched, so `publish` brings back
    /// the same accessory. Idempotent.
    func unpublish() async {
        guard running, let stack else { return }
        log.info("Unpublishing the HomeKit accessory of \(configuration.name)")
        serverEvents?.cancel()
        serverEvents = nil
        operatingEvents?.cancel()
        operatingEvents = nil
        formatTask?.cancel()
        formatTask = nil
        pendingFreeze = nil
        await stopHealthMonitor()
        dependencies.registry.remove(id, ifMatching: stack.controller)
        self.stack = nil
        let streaming = streaming, recording = recording
        self.streaming = nil
        self.recording = nil
        await streaming?.stopAll()
        await recording?.stopAll()
        await stack.server.stop()
        await stack.dataStream.stop()
        dependencies.onChange()
    }

    /// The snapshot provider behind the app's own pictures and the accessory's snapshot requests.
    private func makeSnapshots() {
        let driver = driver, reachability = reachability
        var snapshotAPI: SnapshotProvider.CameraSnapshot?
        if configuration.capabilities?.snapshotAPI != false {
            snapshotAPI = {
                if reachability?.isOffline == true { throw CameraOfflineError() }   // nothing is sent to a camera that answers nothing
                return try await driver.snapshot()
            }
        }
        snapshots = SnapshotProvider(cameraSnapshot: snapshotAPI, codecs: dependencies.environment.codecs, hub: mainHub,
                                     timing: dependencies.tuning.snapshots, log: log,
                                     isOffline: { [reachability] in reachability?.isOffline ?? false })
    }

    /// Builds the delegates and the accessory, starts its server and registers its controller on the router. Throws
    /// `CancellationError` when the runtime stopped meanwhile (nothing is left running), else the start's failure.
    private func bringUpAccessory(port: UInt16, reserved: Set<UInt16>, epoch: Int) async throws -> UInt16 {
        let name = configuration.name
        // Recording options are frozen per camera; live options follow the source: the picture when it is already
        // there, else the size remembered at an earlier start. Only a camera seen for the first time waits for a picture.
        let frozen = try? AccessoryOptions.frozenAspect(in: store)
        let remembered = AccessoryOptions.sourceSize(in: store)
        var format = await mainHub.videoFormat
        if format == nil, remembered == nil { format = await waitForFormat() }
        guard isCurrent(epoch) else { throw CancellationError() }   // stopped while waiting
        let seen = format.map { AccessoryOptions.SourceSize(width: $0.width, height: $0.height) }.flatMap { $0.isPlausible ? $0 : nil }
        let size = seen ?? remembered
        let aspect = frozen ?? size?.aspect ?? .wide
        let hubs: HubProvider = { [weak self] preferSub in
            guard let self else { return HubLease(hub: MediaHub(), isSubStream: false, release: {}) }
            return await self.lease(preferSub: preferSub)
        }
        let environment = dependencies.environment
        let codecs = environment.codecs
        guard let snapshots else { throw CancellationError() }
        let talkbackAvailable = configuration.twoWayAudio && configuration.capabilities?.twoWayAudio != false && driver.makeTalkbackSink() != nil
        var makeSink: (@Sendable () -> (any TalkbackSink)?)?
        if talkbackAvailable {
            makeSink = { [driver] in driver.makeTalkbackSink() }
        }
        let onChange = dependencies.onChange
        var liveContext = LiveStreamPipeline.Context(codecs: codecs, cameraAudioEnabled: configuration.audioEnabled, talkback: makeSink,
                                                     controllerTimeout: dependencies.tuning.liveControllerTimeout, log: log,
                                                     qualityMode: configuration.liveQualityMode, overlay: overlay)
        liveContext.timing = dependencies.tuning.liveStreamTiming
        // A live view that starts inside the camera's long GOP asks the camera for a keyframe: through the adapter's own guarded call
        // (`CameraDriver.requestKeyframe`: spacing, no repeat after a refused login, nothing while logins are paused), once per
        // need, and nothing at all while the camera is known to be offline.
        liveContext.cameraKeyframe = LiveStreamPipeline.cameraKeyframeRequest(driver: driver, isOffline: { [reachability] in reachability?.isOffline ?? false },
                                                                              log: log)
        liveContext.subStreamSize = { [subHub] in await Self.pictureSize(of: subHub) }
        let streaming = StreamingHandler(hubs: hubs, snapshots: snapshots, context: liveContext,
                                         loopbackOnly: environment.loopbackOnly, streamMode: configuration.liveStreamMode,
                                         maxBitrateOverride: configuration.liveMaxBitrateOverride,
                                         networkNotices: dependencies.onNetworkNotice, onChange: onChange)
        let recording = RecordingHandler(hub: mainHub, traits: mainTraits, codecs: codecs, cameraAudioEnabled: configuration.audioEnabled,
                                         timing: dependencies.tuning.recording, log: log, onChange: onChange, hubs: hubs,
                                         streamMode: configuration.recordingStreamMode, qualityMode: configuration.recordingQualityMode,
                                         overlay: overlay)
        let controllerConfiguration = AccessoryOptions.controllerConfiguration(for: configuration, aspect: aspect, sourceWidth: size?.width,
                                                                                sourceHeight: size?.height, talkback: talkbackAvailable)
        let bound: (port: UInt16, value: Stack)
        do {
            bound = try await PortAllocator.bind(from: port, avoiding: reserved) { @Sendable [self] candidate in
                try await makeStack(port: candidate, configuration: controllerConfiguration, streaming: streaming, recording: recording)
            }
        } catch {
            log.error("\(name): the HomeKit accessory could not start (\(error))")
            throw error
        }
        let stack = bound.value
        guard isCurrent(epoch) else {   // stopped while the server started
            await stack.server.stop()
            await stack.dataStream.stop()
            throw CancellationError()
        }
        self.streaming = streaming
        self.recording = recording
        self.stack = stack
        watch(stack)   // pairing events from here on (they freeze pending recording options)
        await streaming.setSessionEnder { [weak controller = stack.controller] sessionID in
            controller?.stopStreamingSession(sessionID) ?? false
        }
        await cacheSetup(stack.server)
        if frozen == nil {
            // What a picture showed (now or at an earlier start) is frozen at once. Without one the 16:9 default is
            // frozen only once a controller pairs with it: unpaired, a later start may still offer the real aspect;
            // paired, the advertised options never change (the hub's selection would be dropped).
            if size != nil || paired {
                await freezeRecordingOptions(aspect, on: stack.server)
            } else {
                pendingFreeze = aspect
            }
        }
        if let seen, seen != remembered { await rememberSourceSize(seen, on: stack.server) }
        await dependencies.tuning.beforeControllerRegistration?(id)
        guard isCurrent(epoch), self.stack != nil else { throw CancellationError() }   // stop() or unpublish() already closed the stack
        // Registered and brought up to date on the router in one step: an output emitted in between (soft motion, the
        // ingest going online) would otherwise find no controller, and an older snapshot would be applied after it.
        let controller = stack.controller, registry = dependencies.registry, cameraID = id
        await dependencies.router.withCurrentState(for: cameraID) { state in
            registry.register(controller, for: cameraID)
            if let state {
                controller.setMotionDetected(state.motion)
                ControllerRegistry.apply(state, to: controller)
            }
        }
        guard isCurrent(epoch), self.stack != nil else {   // stop() ran meanwhile (and may have unregistered before the router registered)
            registry.remove(cameraID, ifMatching: controller)
            throw CancellationError()
        }
        if seen == nil { watchFormat(epoch) }
        startHealthMonitor(stack)
        dependencies.onChange()
        return bound.port
    }

    private func startHealthMonitor(_ stack: Stack) {
        let monitor = HAPHealthMonitor(server: stack.server, name: configuration.name, browser: dependencies.environment.platform.browser,
                                       timing: dependencies.tuning.accessoryHealth, log: Log(category: "hap", cameraID: id))
        healthMonitor = monitor
        Task { await monitor.start() }
    }

    private func stopHealthMonitor() async {
        guard let monitor = healthMonitor else { return }
        healthMonitor = nil
        await monitor.stop()
    }

    /// The wake path (`BridgeEngine.systemDidWake`): closes the HAP connections that are silent since before the sleep
    /// (`dropConnections`; `inactiveFor`: how long the Mac slept, nil: the server's default) and ends live views that were
    /// prepared and never started.
    func purgeAfterWake(dropConnections: Bool, inactiveFor: Duration?) async {
        guard running, let stack else { return }
        let dropped = dropConnections ? await stack.server.dropStaleConnections(inactiveFor: inactiveFor) : 0
        let ended = stack.controller.stopUnstartedStreamingSessions(because: "the Mac woke up")
        if dropped > 0 || ended > 0 {
            log.info("\(configuration.name): after the wake, closed \(dropped) silent HAP connection\(dropped == 1 ? "" : "s") and ended "
                     + "\(ended) live view\(ended == 1 ? "" : "s") that never started")
        }
    }

    /// Answers while this runtime's actor and its accessory server's actor are scheduled (`BridgeEngine`'s heartbeat: a runtime
    /// that does not answer three times in a row is restarted). The number of verified HAP connections.
    func heartbeat() async -> Int {
        await dependencies.tuning.runtimeHeartbeat?(id)
        return await stack?.server.sessionCount ?? 0
    }

    /// Tells the router what the main stream is doing now: after an accessory that could not start made the camera read as
    /// offline, once it is up the stream's own state is the truth again.
    func reportStreamConnection() async {
        guard running, let ingest = mainIngest else { return }
        let router = dependencies.router
        switch await ingest.state {
        case .online: await router.setStreamConnection(.online, for: id)
        case .connecting: await router.setStreamConnection(.connecting, for: id)
        case .offline(let reason): await router.setStreamConnection(.offline(reason), for: id)
        case .idle: break
        }
        dependencies.onChange()
    }

    /// Stops the accessory, ingest and events; the camera's router state goes idle. Idempotent.
    func stop() async {
        guard running else { return }
        running = false
        epoch &+= 1
        sourceTask?.cancel()
        sourceTask = nil
        probeWait = nil
        probeGeneration &+= 1
        formatTask?.cancel()
        formatTask = nil
        pendingFreeze = nil
        serverEvents?.cancel()
        operatingEvents?.cancel()
        await stopHealthMonitor()
        if let stack { dependencies.registry.remove(id, ifMatching: stack.controller) }
        await stopEvents()
        softMotionWatch?.cancel()
        softMotionWatch = nil
        if let softMotion {
            self.softMotion = nil
            await softMotion.stop()
        }
        await stopMotionShadow()
        await streaming?.stopAll()
        await recording?.stopAll()
        for cancel in appSubscriptions.values { cancel() }   // the app's viewers end with the camera
        if let stack {
            await stack.server.stop()
            await stack.dataStream.stop()
        }
        stack = nil
        subIdleStop?.cancel()
        subIdleStop = nil
        await mainIngest?.stop()
        await subIngest?.stop()
        if let holder = driver as? any StreamHoldingDriver { await holder.releaseStreams() }   // the go2rtc helper ends with its last stream
        if let ingestEvents {
            // No connection state may land after the camera went idle.
            ingestEvents.cancel()
            await ingestEvents.value
            self.ingestEvents = nil
        }
        subEvents?.cancel()
        subEvents = nil
        subOfflineFallback?.cancel()
        subOfflineFallback = nil
        mainIngest = nil
        subIngest = nil
        subUsers = 0
        subPermanent = false
        subState = .idle
        subPictureMissingSince = nil
        subStreamProblem = nil
        softMotionOnSub = false
        eventsUnreliable = false
        motionShadowPause = nil
        // The next start (often with a new password) learns about the credentials afresh: a stream rejection that
        // outlived its ingest would blame the new password while the camera is merely unreachable.
        reachability?.reset()   // nothing is probed for a stopped camera
        await dependencies.router.resetOrigin(.stream, for: id)
        await dependencies.router.setStreamConnection(.idle, for: id)
        log.info("Stopped \(configuration.name)")
        dependencies.onChange()
    }

    /// Brings the camera back after a wake from sleep or a network change: the accessory first (listening and advertising,
    /// what Home sees), then the camera's stream and event channel. Rejected credentials are not tried again before their
    /// wait is over (cameras lock the account after a few failed logins): the ingest keeps its wait
    /// (`IngestSupervisor.reconnect()`), and an event channel whose login the camera rejected keeps its source, which waits
    /// `delayAfterUnauthorized` (a new source would log in at once).
    ///
    /// `woke`: the Mac slept, so the connections to the camera are certainly dead and the stream always reconnects; after a
    /// network change alone a stream that delivered video within `healthyIngestWindow` is left connected (the change did
    /// not reach the camera's path). `advertiseAfter`: this camera's turn in the engine's staggered re-registration.
    func refresh(woke: Bool = false, advertiseAfter: Duration = .zero) async {
        guard running else { return }
        let epoch = epoch
        log.info("Reconnecting \(configuration.name) after a system or network change")
        await dependencies.tuning.beforeRuntimeRefresh?(id)
        guard isCurrent(epoch) else { return }
        if woke { await healthMonitor?.systemDidWake() }
        // Home hears from the accessory first, whatever the camera's own connection does next: a listener that is down listens
        // again at once (not after its backoff), and the Bonjour record is registered again (staggered between cameras).
        await stack?.server.relistenNow()
        let advertising = Task { [weak self] in
            if advertiseAfter > .zero { try? await Task.sleep(for: advertiseAfter) }
            guard !Task.isCancelled else { return }
            await self?.restartAdvertising(epoch)
        }
        defer { advertising.cancel() }
        // The live-view transport remembers, per controller, which sending strategy worked (StreamingHandler's per-peer
        // ladder); a network change or wake invalidates what it learned.
        await streaming?.networkChanged()
        reachability?.reset()   // the network changed: what was learned about a camera that answered nothing no longer holds
        if mainIngest == nil, probeWait == .backoff {
            // Still waiting for its stream addresses (the Mac woke or joined the network before the camera's network
            // was up): ask again now with a fresh backoff instead of waiting out up to a minute. Never after rejected
            // credentials (lockout safety), and never while a probe is under way.
            log.info("\(configuration.name): asking the camera for its stream addresses again")
            sourceTask?.cancel()
            startProbing(epoch)
        }
        let healthyWindow: Duration? = woke ? nil : dependencies.tuning.healthyIngestWindow
        await mainIngest?.reconnect(unlessDeliveringWithin: healthyWindow)
        guard isCurrent(epoch) else { return }
        await subIngest?.reconnect(unlessDeliveringWithin: healthyWindow)
        guard isCurrent(epoch) else { return }
        if eventSource != nil {
            if await dependencies.router.credentialsRejected(by: .camera, for: id) {
                log.info("\(configuration.name): the event channel keeps waiting after rejected credentials")
            } else if let healthyWindow, await mainIngest?.isDelivering(within: healthyWindow) == true {
                // The camera's video still arrives over the same network: its event connection does too. Restarting it on every
                // network change logs in to the camera again each time (lockout-prone on some cameras) and loses events while
                // it reconnects; a channel that really dropped reconnects on its own.
                log.info("\(configuration.name): keeping the event channel connected (the camera's video is still arriving)")
            } else {
                guard isCurrent(epoch) else { return }
                await stopEvents()
                guard isCurrent(epoch) else { return }
                startEvents()
            }
        }
        guard isCurrent(epoch) else { return }
        await advertising.value
    }

    private func restartAdvertising(_ epoch: Int) async {
        guard isCurrent(epoch) else { return }
        await stack?.server.restartAdvertising()
    }

    func status() async -> RuntimeStatus {
        var status = RuntimeStatus()
        status.videoSummary = StreamSources.summary(await mainHub.videoFormat, frameRate: await mainHub.measuredFrameRate)
        status.isPaired = paired
        status.appViewers = appViewers
        status.subStreamProblem = running ? subStreamProblem : nil
        status.eventsNote = running && eventsUnreliable ? Self.eventsUnreliableNote : nil
        status.homeKitNote = running ? await healthMonitor?.controllerSilenceNote : nil
        status.setupCode = cachedSetup?.code ?? ""
        status.setupURI = cachedSetup?.uri ?? ""
        if let stack {
            status.hapPort = await stack.server.port
            let operating = stack.controller.operatingState
            status.recordingEnabled = operating.recordingActive && operating.homeKitCameraActive
            status.recordingNow = stack.controller.activeRecordingStreams > 0
            status.liveViewers = stack.controller.activeLiveStreams
        }
        status.motionShadow = await motionShadowStatus()
        if let streaming { status.liveSessions = await streaming.liveSessionStatuses() }
        if let recording { status.recordingSession = await recording.recordingSessionStatus() }
        if let format = await mainHub.videoFormat {
            status.mainStreamInfo = SourceStreamInfo(codec: format.codec.rawValue, width: format.width, height: format.height,
                                                      fps: await mainHub.measuredFrameRate)
        }
        if let format = await subHub.videoFormat {
            status.subStreamInfo = SourceStreamInfo(codec: format.codec.rawValue, width: format.width, height: format.height,
                                                     fps: await subHub.measuredFrameRate)
        }
        return status
    }

    /// Measured facts about the main/sub streams for the HomeKit Readiness advisor (`BridgeEngine.homeKitReadiness`):
    /// codec/size/rate from each hub, longest recent GOP and B-frame detection from `StreamTraits`. nil fields mean
    /// "not measured yet" (no picture) rather than a known-bad value.
    func readinessFacts() async -> (main: MeasuredStreamFacts?, sub: MeasuredStreamFacts?) {
        var main: MeasuredStreamFacts?
        if let format = await mainHub.videoFormat {
            main = MeasuredStreamFacts(codec: format.codec.rawValue.uppercased(), width: format.width, height: format.height,
                                       fps: await mainHub.measuredFrameRate, measuredGOPSeconds: mainTraits.longestGOP.map { $0.timeInterval },
                                       hasBFrames: mainTraits.usesBFrames, audioCodec: await mainHub.audioFormat?.codec.rawValue)
        }
        var sub: MeasuredStreamFacts?
        if let format = await subHub.videoFormat {
            sub = MeasuredStreamFacts(codec: format.codec.rawValue.uppercased(), width: format.width, height: format.height,
                                      fps: await subHub.measuredFrameRate, measuredGOPSeconds: subTraits.longestGOP.map { $0.timeInterval },
                                      hasBFrames: subTraits.usesBFrames, audioCodec: await subHub.audioFormat?.codec.rawValue)
        }
        return (main, sub)
    }

    func snapshot(width: Int, height: Int) async -> Data? {
        guard let snapshots else { return nil }
        do {
            return try await snapshots.snapshot(SnapshotRequest(width: width, height: height, reason: nil))
        } catch {
            log.debug("Snapshot for the app failed: \(URLFreeErrors.describe(error))")
            return nil
        }
    }

    /// Whether a controller is paired with the accessory.
    var isPaired: Bool { paired }

    /// Tests: soft motion's sensitivity and whether its monitor runs.
    var softMotionSensitivity: Double { motionSensitivity }
    var isSoftMotionRunning: Bool { softMotion != nil }
    /// Tests: soft motion analyses the sub stream (not the main stream).
    var softMotionUsesSubStream: Bool { softMotion != nil && softMotionOnSub }

    /// Soft motion's sensitivity changed: only the monitor restarts with it (the accessory, live views and recordings
    /// keep running).
    func updateMotionSensitivity(_ sensitivity: Double) async {
        motionSensitivity = sensitivity
        let epoch = epoch
        if running, let shadow = motionShadowMonitor, let recorder = motionShadow {
            motionShadowMonitor = nil
            await shadow.stop()   // reports the end of a built-in period to the recorder, which keeps its numbers
            await resumeMotionShadowMonitor(recorder, epoch: epoch)
        }
        guard running, let monitor = softMotion else { return }
        softMotion = nil
        await monitor.stop()
        await startSoftMotion(epoch)
    }

    /// The timestamp overlay's settings or the camera's name changed while the overlay stays on (or off): the next picture
    /// of every live view and recording draws the new ones. Turning it on or off restarts the runtime instead (the video
    /// path changes).
    nonisolated func updateTimestampOverlay(_ settings: TimestampOverlaySettings, cameraName: String) {
        overlay.update(settings: settings, cameraName: cameraName)
    }

    // MARK: - HAP

    private nonisolated func makeStack(port: UInt16, configuration controllerConfiguration: CameraControllerConfiguration, streaming: StreamingHandler,
                           recording: RecordingHandler) async throws -> Stack {
        let environment = dependencies.environment
        let info = AccessoryOptions.accessoryInfo(for: configuration)
        let accessory = Accessory(info: info, category: configuration.kind == .doorbell ? .videoDoorbell : .ipCamera)
        // Every layer logs with the camera's ID, so the camera's own log shows pairing, recording and HDS lines too.
        let cameraID = configuration.id
        let dataStream = DataStreamServer(transport: environment.platform.transport, loopbackOnly: environment.loopbackOnly,
                                          log: Log(category: "HDS", cameraID: cameraID))
        let controller = CameraController(configuration: controllerConfiguration, streamingDelegate: streaming, recordingDelegate: recording,
                                          dataStreamServer: dataStream, timings: dependencies.tuning.controller,
                                          log: Log(category: "camera", cameraID: cameraID))
        let server = AccessoryServer(accessory: accessory,
                                     configuration: AccessoryServerConfiguration(port: port, advertise: environment.advertise, serviceName: info.name,
                                                                                 loopbackOnly: environment.loopbackOnly),
                                     store: store, transport: environment.platform.transport, advertiser: environment.platform.advertiser,
                                     log: Log(category: "hap", cameraID: cameraID))
        await controller.install(on: accessory, server: server)
        let events = server.events
        do {
            try await server.start()
        } catch {
            await dataStream.stop()
            throw error
        }
        return Stack(accessory: accessory, controller: controller, server: server, dataStream: dataStream, events: events)
    }

    private func cacheSetup(_ server: AccessoryServer) async {
        do {
            cachedSetup = (try await server.setupCode.formatted, try await server.setupURI)
        } catch {
            log.warning("The HomeKit setup code could not be read: \(error)")
        }
        paired = await server.isPaired
    }

    private func watch(_ stack: Stack) {
        let events = stack.events
        let onChange = dependencies.onChange
        let onLocalNetwork = dependencies.onLocalNetwork
        serverEvents = Task { [weak self] in
            for await event in events {
                switch event {
                case .paired:
                    await self?.setPaired(true)
                case .unpaired:
                    await self?.setPaired(false)
                case .advertisingFailed(_, let denied):
                    if denied { onLocalNetwork(.denied) }
                case .listening, .advertising, .sessionsChanged:
                    onChange()
                }
            }
        }
        let changes = stack.controller.operatingStateChanges
        operatingEvents = Task {
            for await _ in changes { onChange() }
        }
    }

    private func setPaired(_ value: Bool) async {
        paired = value
        if value, let aspect = pendingFreeze, let server = stack?.server {
            log.info("\(configuration.name) was paired: its recording options are kept from now on")
            await freezeRecordingOptions(aspect, on: server)
        }
        dependencies.onChange()
    }

    private func freezeRecordingOptions(_ aspect: AccessoryOptions.Aspect, on server: AccessoryServer) async {
        pendingFreeze = nil
        do {
            try await server.store(extra: try AccessoryOptions.encodeFrozen(aspect), forKey: AccessoryOptions.frozenKey)
        } catch {
            log.warning("Could not save the recording options: \(error)")
        }
    }

    private func rememberSourceSize(_ size: AccessoryOptions.SourceSize, on server: AccessoryServer) async {
        do {
            try await server.store(extra: try AccessoryOptions.encode(size), forKey: AccessoryOptions.sourceSizeKey)
        } catch {
            log.warning("Could not save the picture size: \(error)")
        }
    }

    /// The accessory was published before the main stream delivered a picture: remember its size once it does, for
    /// the live (and, while unpaired and not yet frozen, recording) options of the next start.
    private func watchFormat(_ epoch: Int) {
        let hub = mainHub
        formatTask = Task { [weak self] in
            while !Task.isCancelled {
                if let format = await hub.videoFormat {
                    await self?.formatSeen(format, epoch: epoch)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func formatSeen(_ format: VideoFormat, epoch: Int) async {
        let size = AccessoryOptions.SourceSize(width: format.width, height: format.height)
        guard isCurrent(epoch), let server = stack?.server, size.isPlausible, size != AccessoryOptions.sourceSize(in: store) else { return }
        log.info("\(configuration.name) delivers \(size.width)×\(size.height): its HomeKit options follow at the next start")
        await rememberSourceSize(size, on: server)
    }

    // MARK: - Ingest

    private func startIngest(_ epoch: Int) async {
        let camera = configuration
        let environment = dependencies.environment
        let tuning = dependencies.tuning
        if camera.vendor == .demo {
            await makeIngest(main: StreamSources.demo(tuning.demoMain, codecs: environment.codecs, displayName: camera.name, audio: camera.audioEnabled),
                             sub: StreamSources.demo(tuning.demoSub, codecs: environment.codecs, displayName: camera.name, audio: false), fallback: nil,
                             epoch: epoch)
            return
        }
        let urls = StreamSources.urls(for: camera)
        if urls.main != nil {
            await startRTSP(urls, epoch: epoch)
        } else {
            startProbing(epoch)
        }
    }

    /// What the stream-address probe loop is waiting for between attempts.
    private enum ProbeWait {
        /// Its backoff after a failure: a wake or network change asks again at once (`refresh()`).
        case backoff
        /// `unauthorizedRetry` after rejected credentials: nothing shortens it (lockout safety).
        case rejectedCredentials
    }

    /// ONVIF (and cameras added without URLs): asks the camera for its stream addresses, with backoff, then connects.
    /// Rejected credentials are reported like the stream's and wait `unauthorizedRetry` (every probe is a login: lockout
    /// safety).
    private func startProbing(_ epoch: Int) {
        let camera = configuration
        let tuning = dependencies.tuning
        probeGeneration &+= 1
        let generation = probeGeneration
        probeWait = nil
        sourceTask = Task { [weak self, driver, log] in
            var backoff = Backoff(initial: tuning.ingest.initialBackoff, maximum: tuning.ingest.maximumBackoff)
            while !Task.isCancelled {
                do {
                    if let holder = driver as? any StreamHoldingDriver {
                        // Behind the go2rtc helper: its address is all the ingest needs (the helper dials the service when the
                        // ingest connects; asking for the stream first would dial it twice).
                        let main = try await holder.attachStreams()
                        await self?.startRTSP(StreamSources.URLs(main: main, sub: nil), epoch: epoch)
                        return
                    }
                    let probe = try await driver.probe()
                    guard let main = probe.mainStream?.url else { throw CameraAdapterError.unsupported("the camera reports no stream") }
                    await self?.startRTSP(StreamSources.URLs(main: main, sub: probe.subStream?.url), epoch: epoch)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    let reason = IngestSupervisor.describe(error, watchdog: tuning.ingest.watchdog)
                    let rejected = IngestSupervisor.isUnauthorized(error)
                    let delay = rejected ? tuning.ingest.unauthorizedRetry : backoff.next()
                    log.info("\(camera.name): stream addresses not available yet (\(reason)); asking again in \(MediaFit.seconds(delay)) s")
                    await self?.reportOffline("no stream address (\(reason))", rejectedCredentials: rejected, epoch: epoch)
                    await self?.setProbeWait(rejected ? .rejectedCredentials : .backoff, generation: generation)
                    try? await Task.sleep(for: delay)
                    await self?.setProbeWait(nil, generation: generation)
                }
            }
        }
    }

    private func setProbeWait(_ wait: ProbeWait?, generation: Int) {
        guard generation == probeGeneration else { return }
        probeWait = wait
    }

    private func startRTSP(_ urls: StreamSources.URLs, epoch: Int) async {
        guard isCurrent(epoch), mainIngest == nil, let main = urls.main else { return }
        let transport = dependencies.environment.platform.transport
        let name = configuration.name
        let mainSource = StreamSources.rtsp(url: main, credentials: credentials, displayName: name, cameraID: id, transport: transport)
        let subSource = urls.sub.map { StreamSources.rtsp(url: $0, credentials: credentials, displayName: name, cameraID: id, transport: transport) }
        await makeIngest(main: mainSource, sub: subSource,
                         fallback: (StreamSources.reolinkFLV(camera: configuration, credentials: credentials, main: true, displayName: name),
                                    StreamSources.reolinkFLV(camera: configuration, credentials: credentials, main: false, displayName: name)),
                         epoch: epoch)
    }

    /// Creates the supervisors and starts them (and soft motion). Both supervisors are assigned before the first
    /// suspension so a concurrent `stop()` stops them; whatever started after that stop is stopped again here.
    private func makeIngest(main: IngestSupervisor.Source, sub: IngestSupervisor.Source?,
                            fallback: (main: IngestSupervisor.Source?, sub: IngestSupervisor.Source?)?, epoch: Int) async {
        guard isCurrent(epoch), mainIngest == nil else { return }
        let timing = dependencies.tuning.ingest
        let (events, continuation) = AsyncStream.makeStream(of: IngestSupervisor.Event.self)
        let mainIngest = IngestSupervisor(name: "\(configuration.name) main stream", hub: mainHub, primary: main, fallback: fallback?.main,
                                          timing: timing, traits: mainTraits, log: log, reachability: reachability) { continuation.yield($0) }
        // The sub stream's events reach the runtime (its status, soft motion's choice of stream, Local Network).
        let (subEventStream, subContinuation) = AsyncStream.makeStream(of: IngestSupervisor.Event.self)
        let subIngest = sub.map {
            IngestSupervisor(name: "\(configuration.name) sub stream", hub: subHub, primary: $0, fallback: fallback?.sub, timing: timing,
                             traits: subTraits, log: log, reachability: reachability) { subContinuation.yield($0) }
        }
        self.mainIngest = mainIngest
        self.subIngest = subIngest
        if subIngest != nil {
            subEvents = Task { [weak self] in
                for await event in subEventStream { await self?.subStreamEvent(event, epoch: epoch) }
            }
        } else {
            subContinuation.finish()
        }
        let router = dependencies.router
        let cameraID = id
        let onChange = dependencies.onChange
        let onLocalNetwork = dependencies.onLocalNetwork
        let remote = !Self.isLoopback(configuration.endpoint.host) && configuration.vendor != .demo
        ingestEvents = Task {
            for await event in events {
                switch event {
                case .state(.idle):
                    break
                case .state(.connecting):
                    await router.setStreamConnection(.connecting, for: cameraID)
                case .state(.online):
                    await router.setStreamConnection(.online, for: cameraID)
                    if remote { onLocalNetwork(.granted) }
                case .state(.offline(let reason)):
                    await router.setStreamConnection(.offline(reason), for: cameraID)
                case .unauthorized:
                    await router.handle(.authenticationFailed, for: cameraID, origin: .stream)
                case .localNetworkDenied:
                    onLocalNetwork(.denied)
                }
                onChange()
            }
        }
        await mainIngest.start()
        if let subIngest, subPermanent || subUsers > 0 { await subIngest.start() }
        if configuration.motionSource == .softMotion { await startSoftMotion(epoch) }
        await startMotionShadow(epoch)
        guard isCurrent(epoch) else {
            // stop() ran meanwhile; it may have reached these before they started.
            await mainIngest.stop()
            await subIngest?.stop()
            return
        }
    }

    private func reportOffline(_ reason: String, rejectedCredentials: Bool = false, epoch: Int) async {
        guard isCurrent(epoch) else { return }   // no state may land after the camera went idle
        await dependencies.router.setStreamConnection(.offline(reason), for: id)
        if rejectedCredentials, isCurrent(epoch) { await dependencies.router.handle(.authenticationFailed, for: id, origin: .stream) }
        dependencies.onChange()
    }

    /// The main stream's format, waiting up to `aspectWait` for its first picture (nil when none arrives).
    private func waitForFormat() async -> VideoFormat? {
        let deadline = ContinuousClock.now + dependencies.tuning.aspectWait
        while ContinuousClock.now < deadline, !Task.isCancelled, running {
            if let format = await mainHub.videoFormat { return format }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await mainHub.videoFormat
    }

    /// The picture size a hub's stream delivers, nil before it ever delivered one (the sub stream's size is remembered across its
    /// idle stops, so a later live view knows what the sub stream covers before it starts it).
    private static func pictureSize(of hub: MediaHub) async -> VideoResolution? {
        guard let format = await hub.videoFormat, format.width > 0, format.height > 0 else { return nil }
        let fps = await hub.measuredFrameRate.map { Int($0.rounded()) } ?? 0
        return VideoResolution(format.width, format.height, fps)
    }

    /// Tests: the HomeKit live view handler (nil until the accessory is up).
    var streamingHandler: StreamingHandler? { streaming }

    /// A hub for a live view: the sub stream when preferred and it delivers a picture in time, else the main stream — at
    /// once while the sub stream is known to be down (offline while it runs, or when it last ran: it was stopped unused
    /// since, and is then given a try in the background so it is used again once it delivers), and as soon as it goes
    /// offline while the live view waits for its first picture.
    func lease(preferSub: Bool) async -> HubLease {
        let main = HubLease(hub: mainHub, isSubStream: false, release: {}, traits: mainTraits)
        guard preferSub, let subIngest else { return main }
        if case .offline = subState, await subIngest.isRunning {
            log.debug("The sub stream is offline; the live view uses the main stream")
            return main
        }
        if let problem = subStreamProblem, await !subIngest.isRunning {
            log.debug("The sub stream was offline when it last ran (\(problem)); the live view uses the main stream while it tries again")
            await acquireSub()
            releaseSub()   // stopped again after `subStreamIdleStop` unless a live view or soft motion uses it
            return main
        }
        await acquireSub()
        let release: @Sendable () async -> Void = { [weak self] in await self?.releaseSub() }
        let deadline = ContinuousClock.now + dependencies.tuning.subStreamStartWait
        while ContinuousClock.now < deadline, !Task.isCancelled {   // an abandoned start must not spin on a cancelled sleep
            if await subHub.lastKeyframe != nil { return HubLease(hub: subHub, isSubStream: true, release: release, traits: subTraits) }
            if case .offline = subState { break }   // refused, rejected credentials, …: no picture is coming soon
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !Task.isCancelled { log.info("The sub stream has no picture yet; the live view uses the main stream") }
        releaseSub()
        return main
    }

    // MARK: - App viewers

    /// An in-app viewer's subscription (`BridgeEngine.liveVideo`): the hub of the stream it asks for, leased as a HomeKit
    /// viewer leases it (the sub stream starts on demand and is released when the subscription ends), read from the
    /// newest keyframe on. Counted in `RuntimeStatus.appViewers`, never in the HomeKit viewers. nil while the camera is
    /// not running. Ends by itself when the camera stops.
    func openLiveVideo(stream: LiveVideoStream, audio: Bool, displayWidth: Int?) async -> LiveVideoSubscription? {
        guard running else { return nil }
        var preferSub = stream == .sub
        if stream == .automatic, let format = await mainHub.videoFormat {
            preferSub = format.height > 1440 && (displayWidth ?? 0) <= 1280
        }
        let lease = await lease(preferSub: preferSub)
        guard running else {
            await lease.release()
            return nil
        }
        let viewer = UUID()
        appViewers += 1
        appSubscriptions[viewer] = {}   // registered before the subscription exists: its end may come first
        dependencies.onChange()
        let subscription = await LiveVideoPump.start(lease: lease, audio: audio) { [weak self] in await self?.appViewerEnded(viewer) }
        if appSubscriptions[viewer] != nil { appSubscriptions[viewer] = subscription.cancel }
        if !running { subscription.cancel() }   // stopped meanwhile
        return subscription
    }

    private func appViewerEnded(_ viewer: UUID) {
        guard appSubscriptions.removeValue(forKey: viewer) != nil else { return }
        appViewers = max(0, appViewers - 1)
        dependencies.onChange()
    }

    private func acquireSub() async {
        subUsers += 1
        subGeneration &+= 1
        subIdleStop?.cancel()
        subIdleStop = nil
        await subIngest?.start()
    }

    private func releaseSub() {
        subUsers = max(0, subUsers - 1)
        guard subUsers == 0, !subPermanent, subIngest != nil else { return }
        let delay = dependencies.tuning.subStreamIdleStop
        let generation = subGeneration
        subIdleStop?.cancel()
        subIdleStop = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.stopIdleSub(generation)
        }
    }

    /// Stops the unused sub stream: the check and the stop happen here (on the runtime), and a live view or soft
    /// motion that took the sub stream while it was stopping gets it started again.
    private func stopIdleSub(_ generation: Int) async {
        guard generation == subGeneration, subUsers == 0, !subPermanent, let subIngest else { return }
        log.debug("The sub stream is unused; disconnecting it")
        await subIngest.stop()
        if subIngest === self.subIngest, running, subUsers > 0 || subPermanent { await subIngest.start() }
    }

    // MARK: - Events

    private func startEvents() {
        guard running else { return }
        let router = dependencies.router
        let cameraID = id
        let usesCameraMotion = configuration.motionSource == .cameraEvents
        if let source = driver.makeEventSource() {
            eventSource = source
            let events = source.events()
            let epoch = epoch
            eventTask = Task { [weak self] in
                for await event in events {
                    if case .eventChannelUnreliable = event { await self?.eventChannelBecameUnreliable(epoch) }
                    if case .motion(let active) = event {
                        if !usesCameraMotion { continue }
                        await self?.shadowCameraMotion(active)   // the camera's own period, for the shadow test
                    }
                    await router.handle(event, for: cameraID, origin: .camera)
                }
            }
        }
    }

    /// The camera's event channel keeps ending right after it connects (Tapo's PullPoint, most often): its motion events are
    /// not to be relied on, so the built-in motion detection (decoding the stream) takes over for this camera, and the
    /// status says so. The camera's own events still count while they arrive.
    private func eventChannelBecameUnreliable(_ epoch: Int) async {
        guard isCurrent(epoch), !eventsUnreliable else { return }
        eventsUnreliable = true
        log.warning("\(configuration.name): camera events are unreliable; using built-in motion detection instead")
        if configuration.motionSource == .cameraEvents, softMotion == nil, mainIngest != nil {
            // Built-in motion detection is live now (it is the camera's motion): a second detector would only repeat it.
            await stopMotionShadow()
            motionShadowPause = "Built-in motion detection is already in use for this camera"
            await startSoftMotion(epoch)
        }
        dependencies.onChange()
    }

    private func stopEvents() async {
        eventTask?.cancel()
        eventTask = nil
        if let source = eventSource {
            eventSource = nil
            // A source's stop hook may talk to the camera (Reolink logout): never let it hold up a stop for long.
            _ = try? await withDeadline(Self.stopLimit) { await source.stop() }
            await dependencies.router.resetOrigin(.camera, for: id)
        }
    }

    /// Soft motion runs with the ingest: on the sub stream (kept connected) while it delivers pictures, on the main stream
    /// when there is none or it has had no picture for `softMotionSubStreamWait` (a wrong path, rejected credentials, an
    /// unsupported codec must not silently disable motion — and with it HKSV recording); back on the sub stream once it
    /// delivers again.
    private func startSoftMotion(_ epoch: Int) async {
        guard isCurrent(epoch), softMotion == nil else { return }
        var onSub = false
        if let subIngest {
            subPermanent = true
            await subIngest.start()
            guard isCurrent(epoch), softMotion == nil else { return }   // the caller stops the ingest again
            onSub = wantsSubStreamForSoftMotion()
            if softMotionWatch == nil { watchSoftMotionStream(epoch) }
        }
        await runSoftMotion(onSub: onSub, epoch: epoch)
    }

    /// Starts a monitor on the sub or the main stream (none may run).
    private func runSoftMotion(onSub: Bool, epoch: Int) async {
        let monitor = SoftMotionMonitor(hub: onSub ? subHub : mainHub, codecs: dependencies.environment.codecs, sensitivity: motionSensitivity,
                                        router: dependencies.router, cameraID: id, log: log)
        softMotion = monitor
        softMotionOnSub = onSub
        await monitor.start()
        if !isCurrent(epoch) { await monitor.stop() }   // stop() may have stopped it before it started
    }

    /// Whether soft motion should analyse the sub stream now: it delivers pictures, or has not been without them for
    /// `softMotionSubStreamWait` yet.
    private func wantsSubStreamForSoftMotion() -> Bool {
        guard subIngest != nil else { return false }
        if subState == .online {
            subPictureMissingSince = nil
            return true
        }
        let since = subPictureMissingSince ?? .now
        subPictureMissingSince = since
        return ContinuousClock.now - since < dependencies.tuning.softMotionSubStreamWait
    }

    /// Checks soft motion's stream a few times a second while it runs (the sub stream's wait runs out without an event).
    private func watchSoftMotionStream(_ epoch: Int) {
        let interval = min(.milliseconds(250), dependencies.tuning.softMotionSubStreamWait / 4)
        softMotionWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.chooseSoftMotionStream(epoch)
            }
        }
    }

    /// Moves soft motion to the stream it should analyse (`wantsSubStreamForSoftMotion`).
    private func chooseSoftMotionStream(_ epoch: Int) async {
        guard isCurrent(epoch), let monitor = softMotion else { return }
        let onSub = wantsSubStreamForSoftMotion()
        guard onSub != softMotionOnSub else { return }
        if onSub {
            log.notice("\(configuration.name): motion detection uses the sub stream again")
        } else {
            log.warning("\(configuration.name): the sub stream has had no picture for \(MediaFit.seconds(dependencies.tuning.softMotionSubStreamWait)) s"
                        + (subStreamProblem.map { " (\($0))" } ?? "") + "; motion detection uses the main stream")
        }
        softMotion = nil
        await monitor.stop()
        guard isCurrent(epoch), softMotion == nil else { return }   // stopped, or restarted meanwhile
        await runSoftMotion(onSub: onSub, epoch: epoch)
    }

    // MARK: - Motion shadow test

    /// The motion shadow test (`BridgeSettings.motionShadowTest`): for a camera whose motion comes from its own events, built-in
    /// motion detection runs on the SUB stream next to them and reports to `MotionShadowTest` only — never to the router, so
    /// HomeKit motion and recordings are untouched. The camera's own motion periods are copied to the recorder from the event
    /// task. A camera without a sub stream is skipped (logged once): the main stream is never decoded for the test.
    func setMotionShadowTest(_ on: Bool) async {
        guard on != motionShadowWanted else { return }
        motionShadowWanted = on
        motionShadowSkipLogged = false
        motionShadowPause = nil
        if on {
            motionShadowSince = Date()
            guard running, mainIngest != nil else { return }   // `makeIngest` starts it once the ingest exists
            await startMotionShadow(epoch)
        } else {
            await stopMotionShadow()
        }
        dependencies.onChange()
    }

    private func startMotionShadow(_ epoch: Int) async {
        guard motionShadowWanted, isCurrent(epoch), motionShadow == nil, configuration.motionSource == .cameraEvents else { return }
        guard softMotion == nil else {
            motionShadowPause = "Built-in motion detection is already in use for this camera"
            return
        }
        guard subIngest != nil else {
            motionShadowPause = "The camera has no sub stream"
            if !motionShadowSkipLogged {
                motionShadowSkipLogged = true
                log.info("Motion shadow test: \(configuration.name): skipped, the camera has no sub stream (the main stream is not analysed for the test, to keep the load low)")
            }
            dependencies.onChange()
            return
        }
        motionShadowPause = nil
        let recorder = MotionShadowTest(cameraName: configuration.name, log: Log(category: "Events", cameraID: id))
        motionShadow = recorder   // claimed before the first suspension: a stop in between finds it
        await recorder.start()
        motionShadowHoldsSub = true   // one user of the sub stream while the test runs (`acquireSub` counts it at once)
        await acquireSub()
        await resumeMotionShadowMonitor(recorder, epoch: epoch)
        dependencies.onChange()
    }

    /// Starts the built-in detector for `recorder` on the sub stream (none may run).
    private func resumeMotionShadowMonitor(_ recorder: MotionShadowTest, epoch: Int) async {
        guard isCurrent(epoch), motionShadowWanted, motionShadow === recorder, motionShadowMonitor == nil else { return }
        let monitor = SoftMotionMonitor(hub: subHub, codecs: dependencies.environment.codecs, sensitivity: motionSensitivity,
                                        shadow: { [recorder] active in await recorder.builtInMotion(active) }, cameraID: id, log: log)
        motionShadowMonitor = monitor
        await monitor.start()
        if !isCurrent(epoch) || motionShadowMonitor !== monitor { await monitor.stop() }   // stopped before it started
    }

    /// Stops the detector, lets the recorder finish what is open and gives the sub stream back.
    private func stopMotionShadow() async {
        let monitor = motionShadowMonitor, recorder = motionShadow
        motionShadowMonitor = nil
        motionShadow = nil
        if motionShadowHoldsSub {
            motionShadowHoldsSub = false
            releaseSub()
        }
        await monitor?.stop()   // reports the end of a built-in period first
        await recorder?.stop()
    }

    private func shadowCameraMotion(_ active: Bool) async {
        await motionShadow?.cameraMotion(active)
    }

    private func motionShadowStatus() async -> MotionShadowStatus? {
        guard running, motionShadowWanted, configuration.motionSource == .cameraEvents else { return nil }
        guard let recorder = motionShadow else {
            return MotionShadowStatus(state: .paused(motionShadowPause ?? "Starting"), sensitivity: motionSensitivity, enabledSince: motionShadowSince)
        }
        let totals = await recorder.totals()
        var state = MotionShadowStatus.State.comparing
        if case .offline = subState { state = .paused("The sub stream is offline") }
        return MotionShadowStatus(state: state, sensitivity: motionSensitivity, enabledSince: motionShadowSince, last24Hours: totals.last24Hours,
                                  sinceEnabled: totals.sinceEnabled, eventInProgress: totals.eventInProgress)
    }

    /// Tests: the shadow test's detector runs (on the sub stream), and the recorder it reports to.
    var isMotionShadowRunning: Bool { motionShadowMonitor != nil }
    var motionShadowRecorder: MotionShadowTest? { motionShadow }

    /// The sub stream's supervisor reported `event`: its state (status, soft motion), Local Network.
    private func subStreamEvent(_ event: IngestSupervisor.Event, epoch: Int) async {
        guard isCurrent(epoch) else { return }
        switch event {
        case .state(let state):
            subState = state
            switch state {
            case .online:
                if subStreamProblem != nil { log.notice("\(configuration.name): the sub stream is back") }
                subStreamProblem = nil
                subPictureMissingSince = nil
                subOfflineFallback?.cancel()
                subOfflineFallback = nil
            case .offline(let reason):
                if subStreamProblem != reason {
                    log.warning("\(configuration.name): the sub stream is offline (\(reason))"
                                + (softMotion != nil ? "; motion detection falls back to the main stream while it has no picture" : ""))
                }
                subStreamProblem = reason
                subStreamWentOffline(epoch)
            case .idle:
                // Stopped when unused: a failure from its last run stays known (and shown) until it delivers again, so
                // live views do not wait for it at every start.
                subPictureMissingSince = nil
                subOfflineFallback?.cancel()
                subOfflineFallback = nil
            case .connecting:
                break
            }
            if state != .online, softMotion != nil, subPictureMissingSince == nil { subPictureMissingSince = .now }
            dependencies.onChange()
            await chooseSoftMotionStream(epoch)
        case .unauthorized:
            break   // the offline state that follows names it
        case .localNetworkDenied:
            dependencies.onLocalNetwork(.denied)
        }
    }

    /// The sub stream went offline. A live view leased on it froze (the hub waits for a keyframe that does not come, and
    /// the controller's RTCP keeps the session alive): once the sub stream stayed offline for `subStreamStartWait` while
    /// the main stream delivers, its live views end through HAP, and the controller starts them again on the main stream
    /// (`lease` takes it at once while the sub stream is offline). A short drop that reconnects in time ends nothing.
    private func subStreamWentOffline(_ epoch: Int) {
        guard subOfflineFallback == nil else { return }
        let wait = dependencies.tuning.subStreamStartWait
        subOfflineFallback = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self else { return }
                if await self.endLiveViewsOnOfflineSubStream(epoch) { return }
            }
        }
    }

    /// Ends the live views on the sub stream if it is still offline; false: the main stream is not delivering either
    /// (ask again later).
    private func endLiveViewsOnOfflineSubStream(_ epoch: Int) async -> Bool {
        guard isCurrent(epoch), case .offline = subState, let streaming else {
            subOfflineFallback = nil
            return true
        }
        guard await mainIngest?.state == .online else { return false }
        guard isCurrent(epoch), case .offline = subState else { return true }
        subOfflineFallback = nil
        let ended = await streaming.endSubStreamSessions()
        if ended > 0 {
            log.warning("\(configuration.name): the sub stream is still offline; \(ended == 1 ? "its live view ends" : "\(ended) live views on it end") "
                        + "so Home starts \(ended == 1 ? "it" : "them") again on the main stream")
        }
        return true
    }

    /// Longest wait for a camera-facing stop: the event source's (Reolink logout), the ingest source's (RTSP TEARDOWN,
    /// HTTP-FLV: `IngestSupervisor.Timing.sourceStopLimit`) and the talkback channel's close (`TalkbackBridge`).
    static let stopLimit: Duration = .seconds(3)

    static func isLoopback(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "localhost" || lowered == "::1" || lowered == "[::1]" || lowered.hasPrefix("127.")
    }
}
