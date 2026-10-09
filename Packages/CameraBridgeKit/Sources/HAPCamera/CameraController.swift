// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// Service layout, operating-mode handling, snapshot policy and recording-state persistence follow HAP-NodeJS
// lib/controller/CameraController.ts, lib/controller/DoorbellController.ts, lib/camera/RecordingManagement.ts and
// lib/datastream/DataStreamManagement.ts (research brief §3.5, §3.7, §3.8).

import BridgeSupport
import Foundation
import HAP
import HAPCore
import HDS
import Synchronization

/// Camera / video doorbell HAP services, HKSV recording management and HDS dataSend. (Wave 2 task W2-1.)
///
/// Services are created by `init` and added to the accessory by `install(on:server:)`, which also restores the
/// persisted state (`AccessoryServer.store(extra:)`), reports it to the recording delegate, registers the snapshot
/// (`/resource`) and `dataSend` handlers and factory-resets the camera whenever the server reports `.unpaired`
/// (`factoryReset(because:)`). Writes that change the recording or operating-mode state run one at a time
/// (delegate calls included, in order) and are persisted before the controller is answered, so the recording delegate's
/// `updateRecording*` methods must return promptly (schedule heavy work such as restarting a producer; a call over 1 s
/// is logged, and one near 9 s makes the hub's write fail with -70408).
public final class CameraController: Sendable {
    /// `HAPPersistentState.extras` key of the persisted state (`PersistedCameraState` JSON).
    static let persistenceKey = "camera"

    private struct State {
        var installed = false
        var server: AccessoryServer?
        var recordingActive = false
        var recordingAudioActive = false
        var homeKitCameraActive = true
        var eventSnapshotsActive = true
        var periodicSnapshotsActive = true
        var nightVision = true
        var indicatorEnabled = true
        var selected: (raw: Data, parsed: CameraRecordingConfiguration)?
        /// `setSensorStatus(active:)`; StatusActive is this AND HomeKitCameraActive.
        var sensorActive = true
        var sensorFault = false
        var sensorTampered = false
        var recordingStream: RecordingStream?
        /// The stream that held the slot last, now ended or ending: the next stream waits for its delegate notification
        /// (`RecordingStream.predecessor`).
        var releasedRecordingStream: RecordingStream?
        /// Last value yielded to `operatingStateChanges`.
        var publishedState: CameraOperatingState?
        /// SetupDataStreamTransport read value (the last write response without the accessory key salt).
        var lastDataStreamSetup = Data()
        /// HDS connections with a close handler: one per connection, however many recordings it carries.
        var watchedConnections: Set<UUID> = []
        /// Watches the server for `.unpaired` (→ `factoryReset`).
        var serverEvents: Task<Void, Never>?
    }

    /// A recording delegate call slower than this is logged (it holds up the hub's write and every later state write).
    static let slowRecordingDelegateCall: Duration = .seconds(1)

    private let configuration: CameraControllerConfiguration
    private let streamingDelegate: any CameraStreamingDelegate
    private let recordingDelegate: (any CameraRecordingDelegate)?
    private let dataStreamServer: DataStreamServer
    private let timings: CameraControllerTimings
    private let stateBroadcaster = AsyncBroadcaster<CameraOperatingState>()
    private let state = Mutex(State())
    /// Serializes state-changing writes, their delegate calls and persistence.
    private let writeLock = AsyncSerialLock()
    /// Category "camera", tagged with the camera's ID when the owner passes one (`init(…, log:)`): the camera's own log
    /// then shows these lines, its stream managements' and its recording streams' included.
    private let log: Log

    private let streams: [RTPStreamManagement]
    private let microphone: Service
    private let speaker: Service?
    private let recordingManagement: Service?
    private let operatingMode: Service?
    private let dataStreamManagement: Service?
    private let motion: Service
    private let doorbell: Service?
    /// SHA-256 (hex) of the Supported*RecordingConfiguration values; a persisted selection made against other values is dropped.
    private let recordingConfigurationHash: String?

    public convenience init(configuration: CameraControllerConfiguration, streamingDelegate: any CameraStreamingDelegate,
                            recordingDelegate: (any CameraRecordingDelegate)?, dataStreamServer: DataStreamServer) {
        self.init(configuration: configuration, streamingDelegate: streamingDelegate, recordingDelegate: recordingDelegate,
                  dataStreamServer: dataStreamServer, timings: .standard)
    }

    /// `timings` shortens the recording timers in tests. `log`: the camera's logger (`Log(category: "camera", cameraID:)`),
    /// used by the controller, its stream managements and its recording streams.
    public init(configuration: CameraControllerConfiguration, streamingDelegate: any CameraStreamingDelegate,
                recordingDelegate: (any CameraRecordingDelegate)?, dataStreamServer: DataStreamServer, timings: CameraControllerTimings,
                log: Log = Log(category: "camera")) {
        self.configuration = configuration
        self.streamingDelegate = streamingDelegate
        self.recordingDelegate = recordingDelegate
        self.dataStreamServer = dataStreamServer
        self.timings = timings
        self.log = log

        streams = (0..<max(1, configuration.streamCount)).map {
            RTPStreamManagement(index: $0, options: configuration.streaming, delegate: streamingDelegate,
                                delegateTimeout: timings.streamingDelegateTimeout,
                                preparedSessionTimeout: timings.preparedSessionTimeout,
                                staleUnstartedSessionAge: timings.staleUnstartedSessionAge, log: log)
        }

        microphone = Service(.microphone)
        microphone.characteristic(.volume).update(.uint(100))
        if configuration.streaming.twoWayAudio {
            let speaker = Service(.speaker)
            speaker.characteristic(.volume).update(.uint(100))
            self.speaker = speaker
        } else {
            speaker = nil
        }

        motion = Service(.motionSensor)
        motion.characteristic(.statusActive).update(.bool(true))
        motion.characteristic(.statusFault).update(.uint(0))
        motion.characteristic(.statusTampered).update(.uint(0))

        if configuration.isDoorbell {
            let doorbell = Service(.doorbell)
            doorbell.isPrimary = true
            doorbell.characteristic(.programmableSwitchEvent).validValuesOverride = [0]
            self.doorbell = doorbell
        } else {
            doorbell = nil
        }

        if let options = configuration.recording {
            let triggers = CameraTLV.eventTriggers(isDoorbell: configuration.isDoorbell)
            let supportedCamera = CameraTLV.supportedCameraRecordingConfiguration(options, eventTriggers: triggers)
            let supportedVideo = CameraTLV.supportedVideoRecordingConfiguration(options)
            let supportedAudio = CameraTLV.supportedAudioRecordingConfiguration(options)
            // HAP-NodeJS hashes the three base64 values the same way.
            let hashInput = Data((supportedCamera.base64EncodedString() + supportedVideo.base64EncodedString()
                                  + supportedAudio.base64EncodedString()).utf8)
            recordingConfigurationHash = HAPCrypto.sha256(hashInput).hexString

            let recording = Service(.cameraRecordingManagement)
            recording.characteristic(.active).update(.uint(0))
            recording.characteristic(.recordingAudioActive).update(.uint(0))
            recording.characteristic(.supportedCameraRecordingConfiguration).update(.data(supportedCamera))
            recording.characteristic(.supportedVideoRecordingConfiguration).update(.data(supportedVideo))
            recording.characteristic(.supportedAudioRecordingConfiguration).update(.data(supportedAudio))
            recording.characteristic(.selectedCameraRecordingConfiguration)

            let dataStream = Service(.dataStreamTransportManagement)
            dataStream.characteristic(.supportedDataStreamTransportConfiguration).update(.data(CameraTLV.supportedDataStreamTransportConfiguration))
            dataStream.characteristic(.version).update(.string("1.0"))
            dataStream.characteristic(.setupDataStreamTransport)

            recording.addLinkedService(dataStream)
            recording.addLinkedService(motion)
            recordingManagement = recording
            dataStreamManagement = dataStream
        } else {
            recordingConfigurationHash = nil
            recordingManagement = nil
            dataStreamManagement = nil
        }

        if configuration.recording != nil || configuration.supportsNightVisionControl || configuration.supportsIndicatorControl {
            let mode = Service(.cameraOperatingMode)
            mode.characteristic(.eventSnapshotsActive).update(.uint(1))
            mode.characteristic(.homeKitCameraActive).update(.uint(1))
            mode.characteristic(.periodicSnapshotsActive).update(.uint(1))
            if configuration.supportsNightVisionControl { mode.characteristic(.nightVision).update(.bool(true)) }
            if configuration.supportsIndicatorControl { mode.characteristic(.cameraOperatingModeIndicator).update(.bool(true)) }
            operatingMode = mode
        } else {
            operatingMode = nil
        }

        state.withLock { $0.publishedState = Self.operatingState(of: $0, configuration: configuration) }
        wireHandlers()
    }

    deinit {
        state.withLock { $0.serverEvents }?.cancel()
    }

    // MARK: - Public API

    /// Adds all services (RTP mgmt ×N, Microphone, Speaker if twoWayAudio, recording mgmt, operating mode,
    /// data stream transport, MotionSensor linked to recording, Doorbell primary if isDoorbell) and wires handlers,
    /// including the accessory's /resource snapshot handler.
    public func install(on accessory: Accessory, server: AccessoryServer) async {
        let first = state.withLock { state -> Bool in
            guard !state.installed else { return false }
            state.installed = true
            state.server = server
            return true
        }
        guard first else {
            log.warning("CameraController is already installed; ignoring install(on:) for \(accessory.info.name)")
            return
        }
        if let doorbell { accessory.addService(doorbell) }
        for stream in streams { accessory.addService(stream.service) }
        accessory.addService(microphone)
        if let speaker { accessory.addService(speaker) }
        if let recordingManagement { accessory.addService(recordingManagement) }
        if let operatingMode { accessory.addService(operatingMode) }
        if let dataStreamManagement { accessory.addService(dataStreamManagement) }
        accessory.addService(motion)

        accessory.onResourceRequest { [weak self] request, _ async throws(HAPStatus) -> Data in
            guard let self else { throw .serviceCommunicationFailure }
            return try await self.snapshot(request)
        }
        if recordingManagement != nil {
            await dataStreamServer.setHandler(protocol: RecordingStream.protocolName) { [weak self] message, connection in
                await self?.handleDataSend(message, connection: connection)
            }
        }
        // HAP-NodeJS `handleAccessoryUnpairedForControllers`: the last pairing gone (removed by the last admin, or
        // `resetPairings`) factory-resets the camera. Subscribed before `restore`, which the reset then waits for.
        let events = server.events
        let watcher = Task { [weak self] in
            for await event in events where event == .unpaired {
                await self?.factoryReset(because: "the accessory was unpaired")
            }
        }
        state.withLock { $0.serverEvents = watcher }
        await restore(from: server)
    }

    public func setMotionDetected(_ detected: Bool) {
        motion.characteristic(.motionDetected).update(.bool(detected))
    }

    /// ProgrammableSwitchEvent 0 (+ caller also pulses motion). No-op for a camera that is not a doorbell.
    public func ringDoorbell() {
        guard let doorbell else {
            log.debug("ringDoorbell() on a camera that is not a doorbell")
            return
        }
        doorbell.characteristic(.programmableSwitchEvent).sendEvent(.uint(0))
    }

    /// `false`: every idle stream service reports StreamingStatus unavailable (2) and refuses setups.
    public func setStreamingAvailable(_ available: Bool) {
        for stream in streams { stream.setStreamingAvailable(available) }
    }

    /// Ends the live session `sessionID` from the accessory side (HAP-NodeJS `forceStopStreamingSession`), e.g. after
    /// 30 s without controller RTCP (brief §3.6): its stream service reports available again and the streaming delegate
    /// gets the session's single `.stop` shortly afterwards (after a setup or command in progress; it is never sent
    /// twice). Does not wait, so it is safe to call from inside a streaming delegate method. False if no stream service
    /// has that session (never prepared, or already ended).
    @discardableResult
    public func stopStreamingSession(_ sessionID: UUID) -> Bool {
        guard let stream = streams.first(where: { $0.hasSession(sessionID) }) else { return false }
        log.notice("Ending live stream session on stream \(stream.index) from the accessory side")
        return stream.forceStop(sessionID, reason: "the accessory ended it")
    }

    /// Ends every live stream session that was prepared and never started (the controller gave up, or the Mac slept in
    /// between), returning how many. Started sessions are left to their own liveness checks.
    @discardableResult
    public func stopUnstartedStreamingSessions(because reason: String) -> Int {
        streams.filter { $0.forceStopUnstarted(reason: reason) }.count
    }

    /// MotionSensor StatusActive (combined with HomeKitCameraActive), StatusFault and StatusTampered.
    public func setSensorStatus(active: Bool, fault: Bool, tampered: Bool) {
        state.withLock { state in
            state.sensorActive = active
            state.sensorFault = fault
            state.sensorTampered = tampered
        }
        syncStatusActive()
        motion.characteristic(.statusFault).mirror { .uint(self.state.withLock { $0.sensorFault } ? 1 : 0) }
        motion.characteristic(.statusTampered).mirror { .uint(self.state.withLock { $0.sensorTampered } ? 1 : 0) }
    }

    public var operatingState: CameraOperatingState {
        state.withLock { Self.operatingState(of: $0, configuration: configuration) }
    }

    /// Yields each new operating state after a controller changed it (not the current one on subscription).
    public nonisolated var operatingStateChanges: AsyncStream<CameraOperatingState> { stateBroadcaster.subscribe() }

    public var motionService: Service? { motion }

    public var activeRecordingStreams: Int { state.withLock { $0.recordingStream == nil ? 0 : 1 } }

    /// HDS connections with a close handler (tests).
    var watchedConnectionCount: Int { state.withLock { $0.watchedConnections.count } }

    /// Stream services (tests).
    var streamManagements: [RTPStreamManagement] { streams }

    /// Started (not only prepared) live streams.
    public var activeLiveStreams: Int { streams.filter(\.isStreaming).count }

    // MARK: - Handlers

    private func wireHandlers() {
        for stream in streams {
            let index = stream.index
            stream.activeCharacteristic.onWrite { [weak self] value, context async throws(HAPStatus) -> HAPValue? in
                guard let self else { throw .serviceCommunicationFailure }
                try Self.requireAdmin(context)
                await self.setStreamActive(index: index, value.boolValue ?? false)
                return nil
            }
        }
        if let recordingManagement {
            recordingManagement.characteristic(.active).onWrite { [weak self] value, context async throws(HAPStatus) -> HAPValue? in
                guard let self else { throw .serviceCommunicationFailure }
                try Self.requireAdmin(context)
                await self.setRecordingActive(value.boolValue ?? false)
                return nil
            }
            recordingManagement.characteristic(.recordingAudioActive).onWrite { [weak self] value, _ async throws(HAPStatus) -> HAPValue? in
                guard let self else { throw .serviceCommunicationFailure }
                await self.setRecordingAudioActive(value.boolValue ?? false)
                return nil
            }
            let selected = recordingManagement.characteristic(.selectedCameraRecordingConfiguration)
            selected.onRead { [weak self] _ async throws(HAPStatus) -> HAPValue in
                guard let raw = self?.state.withLock({ $0.selected?.raw }) else { throw .serviceCommunicationFailure }
                return .data(raw)
            }
            selected.onWrite { [weak self] value, context async throws(HAPStatus) -> HAPValue? in
                guard let self else { throw .serviceCommunicationFailure }
                try Self.requireAdmin(context)
                try await self.selectRecordingConfiguration(value)
                return nil
            }
        }
        if let operatingMode {
            wireFlag(operatingMode.characteristic(.homeKitCameraActive), adminOnly: true) { controller, enabled in
                await controller.setHomeKitCameraActive(enabled)
            }
            wireFlag(operatingMode.characteristic(.eventSnapshotsActive), adminOnly: true) { controller, enabled in
                await controller.updateFlag(\.eventSnapshotsActive, enabled)
            }
            wireFlag(operatingMode.characteristic(.periodicSnapshotsActive), adminOnly: true) { controller, enabled in
                await controller.updateFlag(\.periodicSnapshotsActive, enabled)
            }
            if configuration.supportsNightVisionControl {
                wireFlag(operatingMode.characteristic(.nightVision), adminOnly: false) { controller, enabled in
                    await controller.updateFlag(\.nightVision, enabled)
                }
            }
            if configuration.supportsIndicatorControl {
                wireFlag(operatingMode.characteristic(.cameraOperatingModeIndicator), adminOnly: false) { controller, enabled in
                    await controller.updateFlag(\.indicatorEnabled, enabled)
                }
            }
        }
        if let dataStreamManagement {
            let setup = dataStreamManagement.characteristic(.setupDataStreamTransport)
            setup.onRead { [weak self] _ async throws(HAPStatus) -> HAPValue in
                .data(self?.state.withLock { $0.lastDataStreamSetup } ?? Data())
            }
            setup.onWrite { [weak self] value, context async throws(HAPStatus) -> HAPValue? in
                guard let self else { throw .serviceCommunicationFailure }
                return try await self.setUpDataStream(value, context: context)
            }
        }
    }

    private func wireFlag(_ characteristic: Characteristic, adminOnly: Bool,
                          _ apply: @escaping @Sendable (CameraController, Bool) async -> Void) {
        characteristic.onWrite { [weak self] value, context async throws(HAPStatus) -> HAPValue? in
            guard let self else { throw .serviceCommunicationFailure }
            if adminOnly { try Self.requireAdmin(context) }
            await apply(self, value.boolValue ?? false)
            return nil
        }
    }

    /// HAP-NodeJS `adminOnlyAccess: [WRITE]`.
    private static func requireAdmin(_ context: HAPRequestContext) throws(HAPStatus) {
        guard context.session.isAdmin else { throw .insufficientPrivileges }
    }

    // MARK: - Operating mode and recording state

    private func setHomeKitCameraActive(_ enabled: Bool) async {
        await writeLock.withLock {
            let changed = state.withLock { state -> Bool in
                defer { state.homeKitCameraActive = enabled }
                return state.homeKitCameraActive != enabled
            }
            guard changed else { return }
            log.notice("HomeKit camera turned \(enabled ? "on" : "off")")
            applyHomeKitCameraActive(enabled)
            await persist()
            publishOperatingState()
        }
    }

    /// Mirrors HomeKitCameraActive into StatusActive and the stream services; turning it off closes the recording
    /// (`.notAllowed`) and stops live streams.
    private func applyHomeKitCameraActive(_ enabled: Bool) {
        syncStatusActive()
        for stream in streams { stream.setOperatingModeEnabled(enabled) }
        guard !enabled else { return }
        if let recording = state.withLock({ $0.recordingStream }) {
            Task { await recording.close(reason: .notAllowed, because: "HomeKit camera was turned off") }
        }
        for stream in streams {
            Task { await stream.stopSession(nil, reason: "HomeKit camera was turned off") }
        }
    }

    private func updateFlag(_ keyPath: WritableKeyPath<State, Bool> & Sendable, _ value: Bool) async {
        await writeLock.withLock {
            let changed = state.withLock { state -> Bool in
                defer { state[keyPath: keyPath] = value }
                return state[keyPath: keyPath] != value
            }
            guard changed else { return }
            await persist()
            publishOperatingState()
        }
    }

    private func setRecordingActive(_ active: Bool) async {
        await writeLock.withLock {
            let (changed, recording) = state.withLock { state -> (Bool, RecordingStream?) in
                defer { state.recordingActive = active }
                return (state.recordingActive != active, state.recordingStream)
            }
            guard changed else { return }
            log.notice("Recording turned \(active ? "on" : "off")")
            await timedRecordingDelegateCall("updateRecordingActive") { await $0.updateRecordingActive(active) }
            if !active, let recording {
                Task { await recording.close(reason: .notAllowed, because: "recording was turned off") }
            }
            await persist()
            publishOperatingState()
        }
    }

    private func setRecordingAudioActive(_ active: Bool) async {
        await writeLock.withLock {
            let changed = state.withLock { state -> Bool in
                defer { state.recordingAudioActive = active }
                return state.recordingAudioActive != active
            }
            guard changed else { return }
            await timedRecordingDelegateCall("updateRecordingAudioActive") { await $0.updateRecordingAudioActive(active) }
            await persist()
            publishOperatingState()
        }
    }

    private func selectRecordingConfiguration(_ value: HAPValue) async throws(HAPStatus) {
        guard let raw = value.dataValue else { throw .invalidValue }
        let parsed: CameraRecordingConfiguration
        do {
            parsed = try CameraTLV.parseSelectedRecordingConfiguration(raw)
        } catch {
            log.warning("Ignoring a malformed SelectedCameraRecordingConfiguration write (\(error))")
            throw .invalidValue
        }
        await writeLock.withLock {
            let changed = state.withLock { state -> Bool in
                guard state.selected?.raw != raw else { return false }
                state.selected = (raw, parsed)
                return true
            }
            guard changed else { return }
            log.info("The hub selected recording at \(parsed.resolution.width)×\(parsed.resolution.height)@\(parsed.resolution.fps), "
                     + "\(parsed.videoBitrateKbps) kbps, IDR every \(parsed.iFrameIntervalMs) ms, fragments of \(parsed.fragmentLengthMs) ms")
            await timedRecordingDelegateCall("updateRecordingConfiguration") { await $0.updateRecordingConfiguration(parsed) }
            await persist()
        }
    }

    private func setStreamActive(index: Int, _ active: Bool) async {
        await writeLock.withLock {
            let stream = streams[index]
            guard stream.isActive != active else { return }
            stream.setActive(active)
            if !active {
                Task { await stream.stopSession(nil, reason: "its stream management was deactivated") }
            }
            await persist()
        }
    }

    /// HAP-NodeJS `CameraController.handleFactoryReset` (→ `RTPStreamManagement` / `RecordingManagement`
    /// `handleFactoryReset`), run once the accessory has no pairing left, so the next Home does not inherit the previous
    /// hub's choices: the recording selection is dropped, recording and its audio turn off, HomeKitCameraActive and
    /// event / periodic snapshots turn back on (StatusActive follows), every stream management is active again, the
    /// microphone and speaker are unmuted at volume 100, a running recording is closed (`.notAllowed`) and live sessions
    /// end. Night vision and the indicator are camera settings and stay (as in HAP-NodeJS). The recording delegate hears
    /// each change (active, configuration, audio active), then the state is persisted.
    func factoryReset(because explanation: String) async {
        await writeLock.withLock {
            let (wasRecording, hadSelection, wasRecordingAudio, recording) = state.withLock { state in
                defer {
                    state.selected = nil
                    state.recordingActive = false
                    state.recordingAudioActive = false
                    state.homeKitCameraActive = true
                    state.eventSnapshotsActive = true
                    state.periodicSnapshotsActive = true
                }
                return (state.recordingActive, state.selected != nil, state.recordingAudioActive, state.recordingStream)
            }
            log.notice("Camera state reset to its defaults: \(explanation)")
            if let recordingManagement {
                recordingManagement.characteristic(.active).update(.uint(0))
                recordingManagement.characteristic(.recordingAudioActive).update(.uint(0))
                recordingManagement.characteristic(.selectedCameraRecordingConfiguration).update(.data(Data()))
            }
            if let operatingMode {
                for type in [CharacteristicType.homeKitCameraActive, .eventSnapshotsActive, .periodicSnapshotsActive] {
                    operatingMode.characteristic(type).update(.uint(1))
                }
            }
            for service in [microphone, speaker].compactMap({ $0 }) {
                service.characteristic(.mute).update(.bool(false))
                service.characteristic(.volume).update(.uint(100))
            }
            for stream in streams {
                stream.setOperatingModeEnabled(true)
                stream.factoryReset(because: explanation)
            }
            syncStatusActive()
            if let recording {
                Task { await recording.close(reason: .notAllowed, because: explanation) }
            }
            if wasRecording {
                await timedRecordingDelegateCall("updateRecordingActive") { await $0.updateRecordingActive(false) }
            }
            if hadSelection {
                await timedRecordingDelegateCall("updateRecordingConfiguration") { await $0.updateRecordingConfiguration(nil) }
            }
            if wasRecordingAudio {
                await timedRecordingDelegateCall("updateRecordingAudioActive") { await $0.updateRecordingAudioActive(false) }
            }
            await persist()
            publishOperatingState()
        }
    }

    /// Runs a recording delegate update (under `writeLock`) and logs it when it is slow.
    private func timedRecordingDelegateCall(_ name: String, _ call: (any CameraRecordingDelegate) async -> Void) async {
        guard let recordingDelegate else { return }
        let start = ContinuousClock.now
        await call(recordingDelegate)
        let elapsed = ContinuousClock.now - start
        if elapsed > Self.slowRecordingDelegateCall {
            log.warning("The recording delegate took \(elapsed) in \(name); it must return promptly and do heavy work in the background")
        }
    }

    private func syncStatusActive() {
        motion.characteristic(.statusActive).mirror {
            .bool(self.state.withLock { $0.sensorActive && $0.homeKitCameraActive })
        }
    }

    private func publishOperatingState() {
        let (current, changed) = state.withLock { state -> (CameraOperatingState, Bool) in
            let current = Self.operatingState(of: state, configuration: configuration)
            defer { state.publishedState = current }
            return (current, state.publishedState != current)
        }
        if changed { stateBroadcaster.yield(current) }
    }

    private static func operatingState(of state: State, configuration: CameraControllerConfiguration) -> CameraOperatingState {
        let recording = configuration.recording != nil
        return CameraOperatingState(homeKitCameraActive: state.homeKitCameraActive, eventSnapshotsActive: state.eventSnapshotsActive,
                                    periodicSnapshotsActive: state.periodicSnapshotsActive,
                                    recordingActive: recording && state.recordingActive, recordingAudioActive: recording && state.recordingAudioActive,
                                    nightVision: configuration.supportsNightVisionControl ? state.nightVision : nil,
                                    indicatorEnabled: configuration.supportsIndicatorControl ? state.indicatorEnabled : nil)
    }

    // MARK: - Persistence

    /// Loads the persisted state (dropping a selection made against other supported configurations), mirrors it into the
    /// characteristics, reports it to the recording delegate and saves it back (with the current hash). The state
    /// belongs to the pairing: an accessory without pairings starts from the factory state (pairings cleared while the
    /// camera was not running, or state that outlived an unpairing; HAP-NodeJS purges it when the accessory is unpaired).
    private func restore(from server: AccessoryServer) async {
        await writeLock.withLock {
            var persisted: PersistedCameraState?
            if let data = await server.extra(forKey: Self.persistenceKey) {
                do {
                    persisted = try JSONDecoder().decode(PersistedCameraState.self, from: data)
                } catch {
                    log.warning("Ignoring unreadable saved camera state (\(error))")
                }
            }
            if let saved = persisted, await !server.isPaired {
                let reset = saved.afterFactoryReset()
                if reset != saved { log.notice("The accessory has no pairing: its saved camera state was reset to the defaults") }
                persisted = reset
            }
            var selected: (raw: Data, parsed: CameraRecordingConfiguration)?
            if let persisted, let raw = persisted.selectedConfiguration, recordingManagement != nil {
                if persisted.configurationHash == recordingConfigurationHash, let parsed = try? CameraTLV.parseSelectedRecordingConfiguration(raw) {
                    selected = (raw, parsed)
                } else {
                    log.notice("The supported recording configuration changed; the hub's previous recording selection was discarded")
                }
            }
            let hasRecording = recordingManagement != nil
            let hasOperatingMode = operatingMode != nil
            let restored = state.withLock { state -> State in
                if let persisted {
                    if hasRecording {
                        state.recordingActive = persisted.recordingActive
                        state.recordingAudioActive = persisted.recordingAudioActive
                    }
                    if hasOperatingMode {
                        state.homeKitCameraActive = persisted.homeKitCameraActive
                        state.eventSnapshotsActive = persisted.eventSnapshotsActive
                        state.periodicSnapshotsActive = persisted.periodicSnapshotsActive
                        state.nightVision = persisted.nightVision ?? state.nightVision
                        state.indicatorEnabled = persisted.indicatorEnabled ?? state.indicatorEnabled
                    }
                }
                state.selected = selected
                return state
            }
            if let persisted {
                for (index, active) in persisted.streamActive.enumerated() where index < streams.count { streams[index].setActive(active) }
            }

            recordingManagement?.characteristic(.active).update(.uint(restored.recordingActive ? 1 : 0))
            recordingManagement?.characteristic(.recordingAudioActive).update(.uint(restored.recordingAudioActive ? 1 : 0))
            if let raw = restored.selected?.raw { recordingManagement?.characteristic(.selectedCameraRecordingConfiguration).update(.data(raw)) }
            if let operatingMode {
                operatingMode.characteristic(.homeKitCameraActive).update(.uint(restored.homeKitCameraActive ? 1 : 0))
                operatingMode.characteristic(.eventSnapshotsActive).update(.uint(restored.eventSnapshotsActive ? 1 : 0))
                operatingMode.characteristic(.periodicSnapshotsActive).update(.uint(restored.periodicSnapshotsActive ? 1 : 0))
                if configuration.supportsNightVisionControl { operatingMode.characteristic(.nightVision).update(.bool(restored.nightVision)) }
                if configuration.supportsIndicatorControl {
                    operatingMode.characteristic(.cameraOperatingModeIndicator).update(.bool(restored.indicatorEnabled))
                }
            }
            for stream in streams { stream.setOperatingModeEnabled(restored.homeKitCameraActive) }
            syncStatusActive()

            if hasRecording, let recordingDelegate {
                await recordingDelegate.updateRecordingConfiguration(restored.selected?.parsed)
                await recordingDelegate.updateRecordingActive(restored.recordingActive)
                await recordingDelegate.updateRecordingAudioActive(restored.recordingAudioActive)
            }
            await persist()
            publishOperatingState()
        }
    }

    /// Holds `writeLock`.
    private func persist() async {
        guard let server = state.withLock({ $0.server }) else { return }
        let streamActive = streams.map(\.isActive)
        let snapshot = state.withLock { state in
            PersistedCameraState(configurationHash: recordingConfigurationHash, selectedConfiguration: state.selected?.raw,
                                 recordingActive: state.recordingActive, recordingAudioActive: state.recordingAudioActive,
                                 homeKitCameraActive: state.homeKitCameraActive, eventSnapshotsActive: state.eventSnapshotsActive,
                                 periodicSnapshotsActive: state.periodicSnapshotsActive,
                                 nightVision: configuration.supportsNightVisionControl ? state.nightVision : nil,
                                 indicatorEnabled: configuration.supportsIndicatorControl ? state.indicatorEnabled : nil,
                                 streamActive: streamActive)
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try await server.store(extra: try encoder.encode(snapshot), forKey: Self.persistenceKey)
        } catch {
            log.error("Could not save the camera state: \(error)")
        }
    }

    // MARK: - Snapshots

    /// Research brief §3.5 snapshot policy (HAP-NodeJS `handleSnapshotRequest`).
    private func snapshot(_ request: HAPResourceRequest) async throws(HAPStatus) -> Data {
        guard streams.contains(where: \.isActive) else { throw .notAllowedInCurrentState }
        if operatingMode != nil {
            let (cameraActive, eventActive, periodicActive) = state.withLock {
                ($0.homeKitCameraActive, $0.eventSnapshotsActive, $0.periodicSnapshotsActive)
            }
            guard cameraActive else { throw .notAllowedInCurrentState }
            if !eventActive {
                guard let reason = request.reason else { throw .insufficientPrivileges }
                if reason == SnapshotReason.event.rawValue { throw .notAllowedInCurrentState }
            }
            if !periodicActive {
                guard let reason = request.reason else { throw .insufficientPrivileges }
                if reason == SnapshotReason.periodic.rawValue { throw .notAllowedInCurrentState }
            }
        }
        let snapshotRequest = SnapshotRequest(width: request.width, height: request.height, reason: request.reason.flatMap(SnapshotReason.init(rawValue:)))
        let jpeg: Data
        do {
            jpeg = try await streamingDelegate.snapshot(snapshotRequest)
        } catch let status as HAPStatus {
            throw status
        } catch {
            log.warning("Snapshot failed: \(error)")
            throw .serviceCommunicationFailure
        }
        guard !jpeg.isEmpty else {
            log.warning("The streaming delegate returned an empty snapshot")
            throw .serviceCommunicationFailure
        }
        return jpeg
    }

    // MARK: - Data stream

    /// SetupDataStreamTransport write (`"r":true`): prepares an HDS session for this HAP session and answers
    /// `{status, {port}, accessoryKeySalt}`.
    private func setUpDataStream(_ value: HAPValue, context: HAPRequestContext) async throws(HAPStatus) -> HAPValue? {
        guard let data = value.dataValue, let request = try? CameraTLV.SetupDataStreamTransportRequest(parsing: data) else { throw .invalidValue }
        guard request.command == 0, request.transportType == 0, request.controllerKeySalt.count == 32 else {
            log.warning("Refusing SetupDataStreamTransport (command \(request.command), transport \(request.transportType), "
                        + "salt of \(request.controllerKeySalt.count) bytes)")
            throw .invalidValue
        }
        let prepared: (port: UInt16, accessoryKeySalt: Data)
        do {
            prepared = try await dataStreamServer.prepareSession(controllerKeySalt: request.controllerKeySalt, session: context.session)
        } catch {
            log.error("Could not prepare a data stream session: \(error)")
            throw .serviceCommunicationFailure
        }
        let response = CameraTLV.SetupDataStreamTransportResponse(status: .success, port: prepared.port, accessoryKeySalt: prepared.accessoryKeySalt)
        state.withLock { $0.lastDataStreamSetup = response.encodedWithoutSalt }
        return .data(response.encoded)
    }

    private func handleDataSend(_ message: HDSMessage, connection: DataStreamConnection) async {
        switch message.kind {
        case .request:
            if message.topic == "open" {
                await open(message, connection: connection)
            } else {
                await reject(message, .unsupported, on: connection)
            }
        case .event:
            guard let stream = state.withLock({ $0.recordingStream }), stream.connection === connection else { return }
            if let streamID = Self.int(message.body["streamId"]), streamID != stream.streamID { return }
            // The slot is freed before the next message on this connection is handled: a hub may send its next `open`
            // right behind (e.g. continuing an event after the 3-minute cap), which must not be refused as busy
            // (HAP-NodeJS clears the stream synchronously). The stream itself ends in the background.
            switch message.topic {
            case "ack":
                recordingStreamFinished(stream)
                Task { await stream.acknowledge() }
            case "close":
                let reason = Self.int(message.body["reason"]).flatMap { HDSProtocolReason(rawValue: Int64($0)) }
                recordingStreamFinished(stream)
                Task { await stream.hubClosed(reason: reason) }
            default:
                break
            }
        case .response:
            break
        }
    }

    /// Research brief §3.8 step 2 (HAP-NodeJS `handleDataSendOpen`).
    private func open(_ request: HDSMessage, connection: DataStreamConnection) async {
        let body = request.body
        guard body["target"] == .string("controller"), body["type"] == .string("ipcamera.recording"),
              let streamID = Self.int(body["streamId"]) else {
            log.warning("Refusing a dataSend open with an unexpected target, type or stream id")
            await reject(request, .unexpectedFailure, on: connection)
            return
        }
        let delegate = recordingDelegate
        let timings = self.timings
        let log = self.log
        var preempted: RecordingStream?
        let outcome = state.withLock { state -> Result<RecordingStream, HDSProtocolReason> in
            guard state.recordingActive, state.homeKitCameraActive else { return .failure(.notAllowed) }
            // The same connection asking again is a real conflict (busy). Another connection can only be the hub that came
            // back after losing the old one (a reconnect after Wi-Fi or sleep) while the old connection is not known to be
            // dead yet, whose stream would hold the slot for minutes: it is cancelled and the new one admitted.
            let holder = state.recordingStream
            if let holder, holder.connection.id == connection.id { return .failure(.busy) }
            guard let selected = state.selected else { return .failure(.invalidConfiguration) }
            guard let delegate else { return .failure(.unexpectedFailure) }
            if let holder {
                preempted = holder
                state.releasedRecordingStream = holder
                state.recordingStream = nil
            }
            // The delegate's last fragment can end up to one fragment after the cap: the backstop waits that long too.
            let stream = RecordingStream(streamID: streamID, connection: connection, delegate: delegate, timings: timings,
                                         fragmentLength: .milliseconds(max(0, selected.parsed.fragmentLengthMs)),
                                         predecessor: state.releasedRecordingStream, log: log) { [weak self] finished in
                self?.recordingStreamFinished(finished)
            }
            state.recordingStream = stream
            return .success(stream)
        }
        if let preempted {
            log.warning("Recording stream \(preempted.streamID) of another connection was still open when the hub opened stream \(streamID); "
                        + "cancelling it so the new one is not refused as busy")
            Task { await preempted.close(reason: .cancelled, because: "a new recording connection took over the camera") }
        }
        switch outcome {
        case .success(let stream):
            watch(connection)
            await stream.start(open: request)
        case .failure(let reason):
            log.info("Refusing recording stream \(streamID) with reason \(reason.rawValue)")
            await reject(request, reason, on: connection)
        }
    }

    private func reject(_ request: HDSMessage, _ reason: HDSProtocolReason, on connection: DataStreamConnection) async {
        do {
            try await connection.sendResponse(to: request, status: .protocolSpecificError, body: HDSDictionary([("status", .int(reason.rawValue))]))
        } catch {
            log.debug("Could not answer a dataSend request: \(error)")
        }
    }

    /// One close handler per HDS connection (not one per recording): it ends the recording running on it.
    private func watch(_ connection: DataStreamConnection) {
        let connectionID = connection.id
        guard state.withLock({ $0.watchedConnections.insert(connectionID).inserted }) else { return }
        connection.onClose { [weak self] in
            guard let self else { return }
            let stream = self.state.withLock { state -> RecordingStream? in
                state.watchedConnections.remove(connectionID)
                guard let stream = state.recordingStream, stream.connection.id == connectionID else { return nil }
                state.recordingStream = nil
                state.releasedRecordingStream = stream
                return stream
            }
            if let stream { Task { await stream.connectionClosed() } }
        }
    }

    private func recordingStreamFinished(_ stream: RecordingStream) {
        state.withLock { state in
            if state.recordingStream === stream {
                state.recordingStream = nil
                state.releasedRecordingStream = stream
            }
        }
    }

    private static func int(_ value: HDSValue?) -> Int? {
        guard case .int(let number)? = value else { return nil }
        return Int(exactly: number)
    }
}
