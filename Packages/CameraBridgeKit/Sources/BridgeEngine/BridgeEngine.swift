import BridgeSupport
import CameraAdapters
import Foundation
import HAP
import HAPCore
import Observation
import RTSP
import Synchronization

/// Facade used by the app (plan W3-1 item 7). State is published on the main actor; the work happens in actors
/// (`CameraRuntime` per camera, `SensorsBridge`, `EventRouter`, `WebhookServer`). (Preview data W1-8.)
///
/// - `start()` loads `config.json` (`ConfigurationStore.loadOrRecover`), resolves HAP ports, starts the event router, the
///   sensors bridge, the webhook (when enabled) and one runtime per enabled camera, holds a background activity and —
///   with `keepMacAwake` — the keep-awake assertion. `pause()` stops bridging and keeps the configuration; `resume()`
///   starts again; `stop()` also drops the log sink. Lifecycle and configuration operations run one at a time.
/// - The sensors bridge runs only while at least one camera is configured (`sensorsBridge` is nil until then): a
///   fresh install publishes nothing on the LAN until a camera is added, and removing the last camera stops it.
/// - `cameras` / `sensorsBridge` / `recentLogs` are refreshed at most four times a second (on change, and every 2 s
///   for frame-rate summaries).
/// - `systemDidWake()` (from the app) and `PlatformServices.networkChanges` reconnect every camera's ingest and event
///   channel and re-advertise, once per burst of wakes and changes, `networkSettle` after the last (one at a time with
///   the lifecycle and configuration operations).
/// - Local Network: `checkLocalNetworkAccess(host:)` connects to a camera (or the router); until an answer is known it
///   retries a denial for up to `localNetworkAnswerWait`, since connections are blocked while the system's alert waits
///   for the person. Denied connections, refused Bonjour registrations and successful LAN connections from the
///   runtimes update `localNetworkAccess` too.
/// - Secrets (Keychain) and `config.json` are read and written off the main actor (`offMain`): `SecItemCopyMatching`
///   blocks its caller, and a slow securityd or a Keychain prompt must not freeze the app. Only the state assignments
///   happen on the main actor.
///
/// State setters are `private(set)` exactly as in the contract; `BridgeEngine+Preview.swift` seeds fixed state through the
/// internal `init(environment:snapshot:)` (a preview engine never starts and its operations do nothing).
@MainActor @Observable
public final class BridgeEngine {
    @ObservationIgnored let environment: BridgeEnvironment
    @ObservationIgnored let tuning: EngineTuning

    public private(set) var state: EngineState = .stopped
    public private(set) var cameras: [CameraStatus] = []
    public private(set) var configurations: [CameraConfiguration] = []
    public private(set) var sensorsBridge: SensorsBridgeStatus?
    public private(set) var localNetworkAccess: LocalNetworkAccess = .unknown
    /// Newest last, capped at 1000.
    public private(set) var recentLogs: [LogEntry] = []
    /// What the network is doing to Apple Home devices that watch live video: a controller on a VPN (its advertised address
    /// is on no network of this Mac) and this Mac being on a VPN (`NetworkNotice`). A controller notice clears an hour
    /// after it was last seen, the Mac's when the VPN is gone. At most one per device (`NetworkNotice.id`).
    public private(set) var recentNetworkNotices: [NetworkNotice] = []
    /// The VPN this Mac is connected to, nil when there is none (or it was not checked yet).
    public private(set) var macVPN: MacVPNStatus?
    /// Camera Bridge OS's internet guard: what needs the person (a camera seen trying the internet for the first time, a camera it can no
    /// longer watch); empty on a bridge without the guard. Set by `pollGuardReport` (BridgeEngine+InternetGuard.swift).
    public internal(set) var internetGuardAlerts: [InternetGuardAlert] = []
    /// Which cameras may be published to HomeKit (their accessory is advertised and their sensors are bridged); nil: every
    /// camera. A camera outside the set still runs for the app's own viewers (live view, snapshots, events) but has no
    /// accessory, so Home shows it as not responding. Not persisted: the host sets it before `start()` (a host that never
    /// sets it publishes everything) and again whenever its rule changes (`setHomeKitAllowlist(_:)`).
    public private(set) var homeKitAllowlist: Set<UUID>?
    private var storedSettings = BridgeSettings()

    @ObservationIgnored let isPreview: Bool
    @ObservationIgnored private let store: ConfigurationStore
    @ObservationIgnored let credentials: CredentialStore
    @ObservationIgnored private let power: PowerController
    @ObservationIgnored private let changes = ChangeSignal()
    @ObservationIgnored private let logs: LogCollector
    @ObservationIgnored let operations = AsyncSerialLock()
    @ObservationIgnored private let registry = ControllerRegistry()
    @ObservationIgnored let router = EventRouter()
    /// The go2rtc helper that turns cloud and console cameras into local RTSP (`Go2RTCManager`); it starts with the first camera
    /// that uses it and ends with the last. Tests replace what the runtimes talk to (`EngineTuning.go2rtc`).
    @ObservationIgnored let go2rtcManager: Go2RTCManager
    @ObservationIgnored var go2rtc: any Go2RTCStreamProviding { tuning.go2rtc ?? go2rtcManager }
    /// The synthetic streams the preview engine's `liveVideo` serves.
    @ObservationIgnored let previewLive = PreviewLiveSources()
    @ObservationIgnored let log = Log(category: "Engine")
    /// Set while the last read of the AI key failed, so one failure is logged once (`aiKeyStatus()`).
    @ObservationIgnored private var aiKeyReadFailed = false
    /// The AI descriptions of events (`aiDescriber`), made at first use.
    @ObservationIgnored private var describer: EventDescriber?
    /// Bumped by every change of the describer's service: a read of the key that a newer change overtook is not applied.
    @ObservationIgnored private var aiServiceGeneration = 0
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private(set) var runtimes: [UUID: CameraRuntime] = [:]
    /// The cameras that are turned off keep only their HomeKit accessory, showing a "Camera off" picture (`CameraOffAccessory`).
    @ObservationIgnored private(set) var offAccessories: [UUID: CameraOffAccessory] = [:]
    /// The pre-optimization encoder/smart-codec values `optimizeForHomeKit` can still undo, per camera.
    @ObservationIgnored var homeKitOptimizationSnapshots: [UUID: HomeKitOptimizationSnapshot] = [:]
    /// The cameras' security checks: the last result of each camera (in memory only), those under way and those scheduled.
    @ObservationIgnored let securityChecks = CameraSecurityChecks()
    /// The internet guard's side in the engine: the list of watched cameras sent to the box and the box's last report.
    @ObservationIgnored let internetGuard = InternetGuardState()
    /// The camera profiles feed (`setCameraProfiles`): seeds the method tried first for a camera with no remembered one
    /// and replaces built-in manual steps. Never persisted into a camera's configuration.
    @ObservationIgnored var cameraProfiles = CameraProfileFeed.empty
    @ObservationIgnored private(set) var bridge: SensorsBridge?
    @ObservationIgnored private var bridgeFollow: Task<Void, Never>?
    @ObservationIgnored private(set) var webhook: WebhookServer?
    @ObservationIgnored private var webhookTask: Task<Void, Never>?
    /// Follows the webhook's listener (`watchWebhook`).
    @ObservationIgnored private var webhookStateTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// Publishes the log sink's entries while it is installed (`startLogLoop`).
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var networkNoticeLog = NetworkNoticeLog()
    /// When the Mac's VPN was last looked for (`refreshNetworkNotices`); nil: at the next status refresh.
    @ObservationIgnored private var lastMacVPNCheck: ContinuousClock.Instant?
    /// The reconnect a wake or network change scheduled (`scheduleReconnect`), and what it is for.
    @ObservationIgnored private var pendingReconnect: (task: Task<Void, Never>, start: PendingStart, woke: Bool, networkChanged: Bool,
                                                      since: ContinuousClock.Instant)?
    /// When the Mac last went to sleep (`systemWillSleep`), for the wake path.
    @ObservationIgnored private var sleepBegan: ContinuousClock.Instant?
    /// Answers a runtime's heartbeat every `runtimeHeartbeatInterval` (`startHeartbeat`).
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    /// Deletes removed cameras' Apple Home pairings kept 30 days or longer: at the start, then every `removedPairingSweepInterval`.
    @ObservationIgnored private var removedPairingSweepTask: Task<Void, Never>?
    /// Consecutive heartbeats a runtime did not answer in time.
    @ObservationIgnored private var heartbeatStrikes: [UUID: Int] = [:]
    @ObservationIgnored private var logToken: LogSinkToken?
    /// Cameras whose accessory could not start: their next try (`retryAccessory`) and its backoff.
    @ObservationIgnored private var accessoryRetries: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var accessoryBackoffs: [UUID: Backoff] = [:]
    /// Setup code, URI and pairing of cameras without a running runtime (from their HAP store); nil: unreadable (not
    /// read again until the entry is invalidated, so a failing Keychain is not asked at every status tick).
    @ObservationIgnored private var storedIdentities: [UUID: StoredIdentity?] = [:]
    /// Bumped by every invalidation: a read that started before it does not cache its (stale) answer.
    @ObservationIgnored private var identityGeneration = 0
    /// Identity reads run one at a time (off the main actor), and so does the removal of a camera's secrets: the value
    /// is the cameras removed by this engine, whose identity a read that was already under way must not create again.
    /// (Creation itself is atomic per Keychain account across every store, the accessory servers' included:
    /// `HAPStore.loadOrCreateIdentity()`.)
    private nonisolated let identityAccess = Mutex(Set<UUID>())
    /// The NVR behind its one handle (`NVRCoordinator`): the store and the recorders. The hook points below are its only callers.
    @ObservationIgnored let nvr: NVRCoordinator
    /// Where recorded video is read from (the app's player, the web interface's routes). Not ready until the store has loaded its catalog
    /// after `start()`; `ArchiveReading.isReady`.
    public nonisolated let archive: any ArchiveReading
    /// The recordings folder as numbers, nil before the first measurement (refreshed with the cameras' status, at most every 5 s).
    public private(set) var nvrStorage: ArchiveStorageStatus?
    /// The Sky Watcher's detectors and its flight feed (`BridgeEngine+Sky.swift`); nil for a preview engine.
    @ObservationIgnored let skyService: SkyService?
    /// The detectors running, by camera, as the service last said; and the runtime whose pictures each one is given (`startSkyIfWanted`).
    @ObservationIgnored var skyDetectors: [UUID: SkyCameraDetector] = [:]
    @ObservationIgnored var skyLinks: [UUID: SkyLink] = [:]
    /// The decoder of the sky log's pictures made later from the recordings (Ruling S31), and the lock that makes them one at a time for all the
    /// cameras (`skyRecordedStill`).
    @ObservationIgnored let skyRecordingDecoders: SnapshotDecoderPool
    @ObservationIgnored let skyRecordingPictures = AsyncSerialLock()
    /// The small pictures of the Sky Watcher's grid, made when the page asks and kept beside the log's pictures (`skyStillThumbnail`).
    @ObservationIgnored let skyThumbnails: SkyThumbnails
    /// Bumped by every operation that changes what `refreshStatus` reads (cameras, runtimes, the sensors bridge, the
    /// state): a refresh that read before it publishes nothing (the operation refreshes again).
    @ObservationIgnored private var statusGeneration = 0

    struct StoredIdentity: Sendable {
        var code: String
        var uri: String
        var paired: Bool
    }

    /// Runs blocking I/O (Keychain, files) on a background thread; the main actor waits without blocking.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    public convenience init(environment: BridgeEnvironment) {
        self.init(environment: environment, tuning: .standard)
    }

    /// `tuning` shortens timers and shrinks the demo camera in tests.
    init(environment: BridgeEnvironment, tuning: EngineTuning) {
        self.environment = environment
        self.tuning = tuning
        isPreview = false
        store = ConfigurationStore(directory: environment.dataDirectory)
        credentials = CredentialStore(secrets: environment.platform.secrets)
        power = PowerController(power: environment.platform.power)
        logs = LogCollector(signal: changes)
        go2rtcManager = Go2RTCManager.standard(launcher: environment.platform.helpers, transport: environment.platform.transport,
                                               dataDirectory: environment.dataDirectory)
        let coordinator = NVRCoordinator(environment: environment, signal: changes)
        nvr = coordinator
        archive = coordinator.reader
        skyService = SkyService(dataDirectory: environment.dataDirectory, http: tuning.skyHTTP ?? URLSessionSkyHTTP(), logStore: coordinator.store.skyLog,
                                pollInterval: tuning.skyPollInterval)
        skyRecordingDecoders = SnapshotDecoderPool(codecs: environment.codecs, idleLifetime: EventPictures.decoderIdleLifetime,
                                                   blockingWork: SnapshotDecoderPool.offCooperativePool)
        skyThumbnails = SkyThumbnails(store: coordinator.store, log: coordinator.store.skyLog, codecs: environment.codecs, maximumWaiting: tuning.skyThumbnailWaiting,
                                      deadline: tuning.skyThumbnailDeadline, failureMemory: tuning.skyThumbnailFailureMemory,
                                      hasRoom: tuning.skyThumbnailRoom ?? { SkyLightFilter.stillsHaveRoom(coordinator.storageStatus()) })
        // Settings and cameras are shown before the first start (a missing or unreadable file is handled by `start`).
        if let configuration = try? store.load() {
            storedSettings = configuration.settings
            configurations = Self.movingStreamCredentials(of: configuration, to: credentials, store: store, log: log)
            loaded = true
            Self.useBridgeTimeZone(configuration.settings.timeZone)
        }
        // A damaged configuration set aside on an earlier launch and not dismissed yet.
        configurationRecoveredFrom = store.recoveryNotice()
    }

    /// Fixed engine state for `preview()`; the engine never starts networking with it.
    struct Snapshot {
        var state: EngineState = .stopped
        var cameras: [CameraStatus] = []
        var configurations: [CameraConfiguration] = []
        var sensorsBridge: SensorsBridgeStatus?
        var localNetworkAccess: LocalNetworkAccess = .unknown
        var recentLogs: [LogEntry] = []
        var settings = BridgeSettings()
        var webhookProblem: String?
        var configurationRecoveredFrom: URL?
        var networkNotices: [NetworkNotice] = []
        var macVPN: MacVPNStatus?
        /// A preview engine's synthetic archive and storage numbers (`-demoScenario nvr`).
        var archive: (any ArchiveReading)?
        var nvrStorage: ArchiveStorageStatus?
    }

    /// An engine that shows `snapshot` (SwiftUI previews); its operations do nothing.
    init(environment: BridgeEnvironment, snapshot: Snapshot) {
        self.environment = environment
        tuning = .standard
        isPreview = true
        store = ConfigurationStore(directory: environment.dataDirectory)
        credentials = CredentialStore(secrets: environment.platform.secrets)
        power = PowerController(power: environment.platform.power)
        logs = LogCollector(signal: changes)
        go2rtcManager = Go2RTCManager.standard(launcher: environment.platform.helpers, transport: environment.platform.transport,
                                               dataDirectory: environment.dataDirectory)
        let coordinator = NVRCoordinator(environment: environment, signal: changes, previewArchive: snapshot.archive)
        nvr = coordinator
        archive = coordinator.reader
        skyService = nil
        skyRecordingDecoders = SnapshotDecoderPool(codecs: environment.codecs, idleLifetime: EventPictures.decoderIdleLifetime)
        skyThumbnails = SkyThumbnails(store: coordinator.store, log: coordinator.store.skyLog, codecs: environment.codecs, hasRoom: { false })
        nvrStorage = snapshot.nvrStorage
        state = snapshot.state
        cameras = snapshot.cameras
        configurations = snapshot.configurations
        sensorsBridge = snapshot.sensorsBridge
        localNetworkAccess = snapshot.localNetworkAccess
        recentLogs = Array(snapshot.recentLogs.suffix(1000))
        storedSettings = snapshot.settings
        webhookProblem = snapshot.webhookProblem
        configurationRecoveredFrom = snapshot.configurationRecoveredFrom
        recentNetworkNotices = snapshot.networkNotices
        macVPN = snapshot.macVPN
    }

    public var settings: BridgeSettings { storedSettings }

    /// Why the enabled webhook is not listening although the bridge runs ("The webhook cannot listen on port 8090
    /// (another app uses the port)."), e.g. another app took its port before a start or resume, or after its listener
    /// stopped on its own (sleep/wake, an interface change) while it tries to listen again; nil when it listens, is off,
    /// or the bridge is paused or stopped. Settings shows it with Try Again (`retryWebhook()`).
    public private(set) var webhookProblem: String?

    /// Where a damaged `config.json` was set aside when the engine loaded it (`config.corrupt-<time>.json`): the bridge
    /// started with the defaults, without the cameras, and the app says so (a banner, the menu bar) until the person
    /// dismisses it (`acknowledgeConfigurationRecovery()`), also across relaunches: the notice is saved next to
    /// `config.json` (`config.recovered`) and read at `init`, since the configuration saved after the recovery loads
    /// normally. nil when nothing was set aside or the person dismissed it.
    public private(set) var configurationRecoveredFrom: URL?

    /// The person saw that the configuration was set aside: `configurationRecoveredFrom` becomes nil, now and at the next
    /// launch (the saved notice is removed; the damaged file stays).
    public func acknowledgeConfigurationRecovery() async {
        configurationRecoveredFrom = nil
        guard !isPreview else { return }
        let store = store
        do {
            try await Self.offMain { try store.clearRecoveryNotice() }
        } catch {
            log.error("The notice about the damaged configuration could not be removed: \(error)")
        }
    }

    /// Running or starting (paused and stopped engines bridge nothing).
    var isActive: Bool { state == .running || state == .starting }

    /// Whether `cameraID`'s accessory may be published (`homeKitAllowlist`).
    func mayPublish(_ cameraID: UUID) -> Bool { homeKitAllowlist?.contains(cameraID) ?? true }

    /// The cameras whose sensors the sensors bridge publishes: those that may be published.
    private var bridgedConfigurations: [CameraConfiguration] { configurations.filter { mayPublish($0.id) } }

    // MARK: - HomeKit publishing

    /// Sets which cameras may be published to HomeKit (nil: all). Running cameras follow at once, without a restart and
    /// without touching their connection to the camera: an accessory that is no longer allowed goes down (live views and
    /// recordings end, Home shows it as not responding) and one that is allowed again comes back with the identity and
    /// pairings it had, so the Home app finds the accessory it knew. The sensors bridge follows (it publishes the allowed
    /// cameras' sensors only). Cameras outside the set keep running for the app's own viewers. A paused or stopped
    /// engine applies the set at its next start. Every camera that is not in the set when the engine starts, a camera
    /// added later included, starts unpublished.
    ///
    /// `cause` says why the host changed it (a camera switched off for Home, a camera added); it goes into the log line
    /// of every change, so "why did Home lose my camera" always has an answer in the log.
    public func setHomeKitAllowlist(_ allowed: Set<UUID>?, because cause: String = "the host changed it") async {
        guard !isPreview else { return }
        await operations.withLock {
            guard allowed != homeKitAllowlist else { return }
            homeKitAllowlist = allowed
            statusInputsChanged()
            if let allowed {
                log.notice("HomeKit publishing is limited to \(allowed.count) camera\(allowed.count == 1 ? "" : "s") (\(cause))")
            } else {
                log.notice("HomeKit publishing is open to every camera (\(cause))")
            }
            guard isActive else { return }
            var toPublish: [CameraConfiguration] = [], toUnpublish: [CameraConfiguration] = []
            for camera in configurations where camera.isEnabled {
                guard let runtime = runtimes[camera.id] else { continue }   // starts (or is retried) with the allowlist applied
                let published = await runtime.isPublished
                if mayPublish(camera.id), !published { toPublish.append(camera) }
                if !mayPublish(camera.id), published { toUnpublish.append(camera) }
            }
            await withTaskGroup(of: Void.self) { group in
                for camera in toUnpublish {
                    guard let runtime = runtimes[camera.id] else { continue }
                    group.addTask { await runtime.unpublish() }
                }
            }
            for camera in toUnpublish {
                log.notice("\(camera.name) is no longer published to HomeKit (\(cause))")
                invalidateStoredIdentity(camera.id)
            }
            await publishRuntimes(toPublish, cause: cause)
            await bridge?.update(cameras: bridgedConfigurations)
            await refreshStatus()
        }
    }

    /// Brings the accessories of running cameras up (concurrently). One that cannot start is handled like a runtime whose
    /// accessory could not start (`startRuntimes`): the camera stops, is offline with the reason, and is tried again with
    /// backoff.
    private func publishRuntimes(_ cameras: [CameraConfiguration], cause: String? = nil) async {
        let results = await withTaskGroup(of: (UUID, Result<UInt16, any Error>).self) { group in
            for camera in cameras {
                guard let runtime = runtimes[camera.id] else { continue }
                let id = camera.id, port = camera.hapPort, reserved = reservedPorts(excluding: camera.id)
                group.addTask {
                    do {
                        return (id, .success(try await runtime.publish(port: port, reserved: reserved)))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            var results: [(UUID, Result<UInt16, any Error>)] = []
            for await result in group { results.append(result) }
            return results
        }
        var moved = false
        for (id, result) in results {
            guard let index = configurations.firstIndex(where: { $0.id == id }) else { continue }
            invalidateStoredIdentity(id)
            switch result {
            case .success(let port):
                log.notice("\(configurations[index].name) is published to HomeKit" + (cause.map { " (\($0))" } ?? ""))
                accessoryBackoffs[id] = nil
                accessoryRetries.removeValue(forKey: id)?.cancel()
                await runtimes[id]?.reportStreamConnection()
                if port != configurations[index].hapPort, port != 0 {
                    log.notice("\(configurations[index].name) listens on HAP port \(port) (\(configurations[index].hapPort) was taken)")
                    configurations[index].hapPort = port
                    moved = true
                }
            case .failure(let error):
                if error is CancellationError { continue }
                let name = configurations[index].name
                // The camera keeps running (its stream, events and the app's viewers); only the accessory is tried again.
                let delay = scheduleAccessoryRetry(id)
                log.error("The HomeKit accessory of \(name) could not start: \(error); trying again in \(MediaFit.seconds(delay)) s")
                await router.setStreamConnection(.offline("the Apple Home accessory could not start (\(Self.readableReason(error)))"), for: id)
            }
        }
        if moved { await persist() }
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !isPreview else { return }
        await operations.withLock {
            switch state {
            case .running, .starting: return
            case .stopped, .failed, .paused:
                // The eufy helper (started by the eufy plugin) runs with the engine's helpers and keeps its session in the data directory.
                WyzeHelpers.configure(launcher: environment.platform.helpers)
                await EufyBridge.shared.configure(launcher: environment.platform.helpers,
                                                  stateDirectory: environment.dataDirectory.appendingPathComponent("plugins/eufy", isDirectory: true))
                await startServices()
            }
        }
    }

    public func stop() async {
        guard !isPreview else { return }
        await operations.withLock {
            await stopServices(then: .stopped)
            if let logToken {
                LogHub.removeSink(logToken)
                self.logToken = nil
            }
            logTask?.cancel()
            logTask = nil
            drainLogs()
        }
    }

    public func pause() async {
        guard !isPreview else { return }
        await operations.withLock {
            guard isActive else { return }
            log.notice("Pausing the bridge")
            await stopServices(then: .paused)
        }
    }

    public func resume() async {
        guard !isPreview else { return }
        await operations.withLock {
            guard state == .paused || state == .stopped else { return }
            await startServices()
        }
    }

    // MARK: - Configuration

    /// A webhook that is turned on, moved or given a new token must be able to listen: otherwise nothing changes and
    /// `EngineError.invalidSettings` says why (e.g. another app holds the port). While the bridge runs the new webhook
    /// listens before anything is saved; while it is paused or stopped its port is bound once and let go (the webhook
    /// listens from the next start or resume).
    public func updateSettings(_ settings: BridgeSettings) async throws {
        guard !isPreview else { return }
        try await operations.withLock {
            try await applySettings(settings)
        }
    }

    /// Applies `change` to the settings as they are when this operation's turn comes (after any lifecycle or
    /// configuration operation under way, including another settings change), then saves them like
    /// `updateSettings(_:)`. Two changes made while the engine is busy therefore both stick, where two whole settings
    /// values copied before either was applied would undo one another. A change that changes nothing saves nothing.
    public func updateSettings(_ change: (inout BridgeSettings) -> Void) async throws {
        guard !isPreview else { return }
        try await operations.withLock {
            try await ensureLoaded()
            var settings = storedSettings
            change(&settings)
            guard settings != storedSettings else { return }
            try await applySettings(settings)
        }
    }

    /// `updateSettings`'s work; the caller holds `operations`.
    private func applySettings(_ settings: BridgeSettings) async throws {
        try Self.validate(settings)
        try await ensureLoaded()
        let old = storedSettings
        let webhookChanged = old.webhookEnabled != settings.webhookEnabled || old.webhookPort != settings.webhookPort
            || old.webhookToken != settings.webhookToken
        if isActive, webhookChanged {
            // The new webhook listens before anything is saved; the old one comes back when it cannot.
            await stopWebhook()
            do {
                try await startWebhook(settings)
                webhookProblem = nil
            } catch {
                await startWebhookReporting(old)
                throw Self.webhookCannotListen(settings.webhookPort, error)
            }
        } else if webhookChanged, settings.webhookEnabled {
            do {
                try await checkWebhookCanListen(settings)
            } catch {
                throw Self.webhookCannotListen(settings.webhookPort, error)
            }
        }
        let sameService = settings.ai.keepsKey(from: old.ai)
        var removedKey = false, keyDeleted = false
        do {
            // A saved key is for one service: before the settings name another, it goes (a failure to delete it stops the change). The card
            // then asks for the key of the new service, and the old one is never sent there.
            if !sameService {
                removedKey = try await forgetAIKey()
                keyDeleted = true
            }
            try await save(BridgeConfiguration(settings: settings, cameras: configurations))
        } catch {
            if isActive, webhookChanged {
                await stopWebhook()
                await startWebhookReporting(old)
            }
            // The settings stay as they were, but the key is gone: the describer must not go on sending it.
            if keyDeleted { await refreshAIService(fresh: true) }
            throw error
        }
        if removedKey { log.notice("The AI key was removed: the AI service changed to \(settings.ai.serviceForLog)") }
        storedSettings = settings
        Self.applyTimeZone(settings.timeZone)
        if old.timeZone != settings.timeZone { BridgeTime.use(settings.timeZone) }
        if old.logLevel != settings.logLevel { applyLogLevel() }
        // Every change to the AI settings starts a new generation of the describer: the last error was about what was in use before, and a
        // call under way for it is not kept as the current one nor sent again (a new model included). Whether the key goes (`sameService`,
        // above) is a separate rule.
        if old.ai != settings.ai { await refreshAIService(fresh: true) }
        guard isActive else { return }
        await nvr.settingsChanged(from: old, to: settings)   // a new folder reloads the catalog, new limits run the janitor
        if old.keepMacAwake != settings.keepMacAwake { power.setKeepAwake(settings.keepMacAwake) }
        if old.motionShadowTest != settings.motionShadowTest {
            for runtime in Array(runtimes.values) { await runtime.setMotionShadowTest(settings.motionShadowTest) }
        }
        if old.sensorsBridgePort != settings.sensorsBridgePort {
            await stopSensorsBridge()
            await startSensorsBridge()
        }
        if Self.skyChanged(old, settings) { await applySky() }   // the plugin, the place, the feed, the folder or the zone
        changes.notify()
    }

    public func addCamera(_ configuration: CameraConfiguration, password: String?) async throws {
        guard !isPreview else { return }
        try await operations.withLock {
            try await ensureLoaded()
            guard !configurations.contains(where: { $0.id == configuration.id }) else { throw EngineError.duplicateCamera }
            let credentials = credentials, id = configuration.id
            if let password { try await Self.offMain { try credentials.setPassword(password, for: id) } }
            // The stream URLs' credentials (query or path) go to the secret store; the camera is kept and saved without them.
            let stored: CameraConfiguration
            do {
                stored = try await Self.offMain { try credentials.storeStreamCredentials(of: configuration) }
            } catch {
                if password != nil { _ = try? await Self.offMain { try credentials.setPassword(nil, for: id) } }
                throw error
            }
            var updated = configurations + [stored]
            updated = PortAllocator.assignPorts(to: updated, settings: storedSettings)
            if isActive {
                updated = await PortAllocator(transport: environment.platform.transport)
                    .resolvePorts(for: updated, settings: storedSettings, listening: await listeningPorts())
            }
            do {
                try await save(BridgeConfiguration(settings: storedSettings, cameras: updated))
            } catch {
                if password != nil { _ = try? await Self.offMain { try credentials.setPassword(nil, for: id) } }
                _ = try? await Self.offMain { try credentials.forgetStreamCredentials(for: id) }
                throw error
            }
            configurations = updated
            statusInputsChanged()
            // A camera added again after it was removed has an identity again (off the main actor: a read may hold the lock): the same
            // camera removed less than 30 days ago gets its Apple Home identity and pairings back, so Home sees the old accessory.
            let dataDirectory = environment.dataDirectory, serial = stored.serialNumber
            let restored: RemovedHAPIdentity?
            do {
                restored = try await Self.offMain { [self] in
                    try identityAccess.withLock { removed throws -> RemovedHAPIdentity? in
                        removed.remove(id)
                        return try credentials.restoreHomePairing(for: id, serialNumber: serial, dataDirectory: dataDirectory)
                    }
                }
            } catch {
                restored = nil
                log.warning("Could not give \(stored.name) the Apple Home pairing it had when it was removed: \(error)")
            }
            if restored != nil {
                invalidateStoredIdentity(id)
                log.notice("\(stored.name) was removed less than 30 days ago: it keeps its Apple Home pairing")
            }
            guard let camera = updated.first(where: { $0.id == configuration.id }) else { return }
            log.notice("Added camera \(camera.name) (\(camera.vendor.rawValue))")
            await router.register(camera)
            await bridge?.update(cameras: bridgedConfigurations)
            if isActive { await startSensorsBridge() }   // the first camera starts it
            if isActive { if camera.isEnabled { await startRuntimes([camera]) } else { await startOffAccessories([camera]) } }
            if isActive { await applySky() }
            await refreshStatus()
        }
    }

    /// `password` nil = unchanged.
    public func updateCamera(_ configuration: CameraConfiguration, password: String?) async throws {
        guard !isPreview else { return }
        try await operations.withLock {
            try await ensureLoaded()
            guard let index = configurations.firstIndex(where: { $0.id == configuration.id }) else { throw EngineError.unknownCamera }
            let old = configurations[index]
            clockUnsupported[configuration.id] = nil
            onvifRefusals[configuration.id] = nil   // new settings (a new password, an ONVIF user added): ask again
            var updated = configurations
            let credentials = credentials
            // Query credentials typed into a stream URL replace the stored ones (a restart below sends them); an address the form left
            // as shown keeps them.
            let typedStreamCredentials = configuration.mainStreamURL?.hasStreamCredentials == true
                || configuration.subStreamURL?.hasStreamCredentials == true
            var camera = try await Self.offMain { try credentials.storeStreamCredentials(of: configuration) }
            if camera.hapPort == 0 { camera.hapPort = old.hapPort }
            camera.hiddenCameraClock = old.hiddenCameraClock   // the engine owns it (`setCameraClockHidden`); a form never carries it back
            camera.cleanPictureBackup = old.cleanPictureBackup   // and this one (`setCleanPicture`)
            camera.setupBackup = old.setupBackup               // and "Set up for Camera Bridge" owns these two
            camera.setupState = old.setupState
            camera.dnsWatch = old.dnsWatch                     // and the Internet guard's DNS reads this one
            camera.nvrEnabled = old.nvrEnabled                 // and `setNVR` owns these two: an edit made from a stale copy never undoes Record
            camera.nvrRecordSound = old.nvrRecordSound
            updated[index] = camera
            updated = PortAllocator.assignPorts(to: updated, settings: storedSettings)
            let id = camera.id
            if let password { try await Self.offMain { try credentials.setPassword(password, for: id) } }
            try await save(BridgeConfiguration(settings: storedSettings, cameras: updated))
            configurations = updated
            statusInputsChanged()
            camera = updated[index]
            if (old.skyDetector?.enabled ?? false) != (camera.skyDetector?.enabled ?? false) {
                log.notice("Sky Watcher turned \(camera.skyDetector?.enabled == true ? "on" : "off") for \(camera.name)")
            }
            await router.register(camera)
            await bridge?.update(cameras: bridgedConfigurations)
            if isActive {
                let paired = await runtimes[camera.id]?.isPaired ?? false
                if password != nil || typedStreamCredentials || Self.needsRestart(old, camera, paired: paired) {
                    log.notice("Restarting \(camera.name) with its new settings")
                    await stopRuntime(camera.id)
                    if camera.isEnabled { await startRuntimes([camera]) } else { await startOffAccessories([camera]) }
                } else {
                    if old.motionSensitivity != camera.motionSensitivity, let runtime = runtimes[camera.id] {
                        await runtime.updateMotionSensitivity(camera.motionSensitivity)
                    }
                    if old.name != camera.name { offAccessories[camera.id]?.rename(camera.name) }
                    if old.timestampOverlay != camera.timestampOverlay || old.name != camera.name, let runtime = runtimes[camera.id] {
                        runtime.updateTimestampOverlay(camera.timestampOverlay, cameraName: camera.name)
                    }
                    if old.pictureCorrection != camera.pictureCorrection, let runtime = runtimes[camera.id] {
                        await runtime.updatePictureCorrection(camera.pictureCorrection)
                    }
                }
                await applySky()   // its switch, its card, its name; a restarted runtime was given to its detector already
            }
            invalidateStoredIdentity(camera.id)
            await refreshStatus()
        }
    }

    /// Saves the configuration first: when it cannot be saved the camera stays (running, with its password and HomeKit
    /// identity) and the failure is logged — `config.json` would bring it back at the next launch without them. A camera whose Watch
    /// is done gets its own DNS servers back first (`giveDNSBackOnRemoval`): the box no longer answers it once it is gone.
    public func removeCamera(id: UUID) async {
        guard !isPreview else { return }
        await operations.withLock {
            guard (try? await ensureLoaded()) != nil, let camera = configurations.first(where: { $0.id == id }) else { return }
            let remaining = configurations.filter { $0.id != id }
            do {
                try await save(BridgeConfiguration(settings: storedSettings, cameras: remaining))
            } catch {
                log.error("\(camera.name) was not removed: the configuration could not be saved (\(error))")
                return
            }
            await giveDNSBackOnRemoval(camera)
            await stopRuntime(id)
            await removeSky(id)   // its aim goes with it
            onvifRefusals[id] = nil
            clockUnsupported[id] = nil
            forgetSecurity(id)
            await router.unregister(cameraID: id)
            configurations = remaining
            statusInputsChanged()
            do {
                // Under the identity lock: a status refresh already reading this camera's identity must not create it
                // again once it is deleted.
                // Its Apple Home identity and pairings are kept for 30 days: the same camera added again keeps its place in Home.
                let credentials = credentials, dataDirectory = environment.dataDirectory, serial = camera.serialNumber
                try await Self.offMain { [self] in
                    try identityAccess.withLock { removed throws in
                        removed.insert(id)
                        try credentials.forgetCamera(id, dataDirectory: dataDirectory, keepingHomePairing: true, serialNumber: serial)
                    }
                }
            } catch {
                log.warning("Could not delete the stored secrets of \(camera.name), or keep its Apple Home pairing: \(error)")
            }
            invalidateStoredIdentity(id)
            await bridge?.update(cameras: bridgedConfigurations)
            if configurations.isEmpty {
                // Nothing to bridge: stop publishing until a camera is added again.
                await stopSensorsBridge()
                sensorsBridge = nil
                statusInputsChanged()
            }
            log.notice("Removed camera \(camera.name)")
            await refreshStatus()
        }
    }

    /// Turns the NVR recording of a camera on or off and/or its sound, in place: the camera is never restarted (its HomeKit accessory, live views
    /// and ingest are untouched). The one place `nvrEnabled` and `nvrRecordSound` change; `updateCamera` carries them forward. Allowed without a
    /// recordings folder (the camera then shows `paused(.noFolder)`); asking for the folder is the caller's job. A change of the sound switch
    /// replaces the camera's recorder (a new file starts). Waits behind other configuration operations, a HomeKit optimization included.
    public func setNVR(cameraID: UUID, enabled: Bool? = nil, recordSound: Bool? = nil) async throws {
        guard !isPreview else { return }
        try await operations.withLock {
            try await ensureLoaded()
            guard let index = configurations.firstIndex(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
            let old = configurations[index]
            var camera = old
            if let enabled { camera.nvrEnabled = enabled }
            if let recordSound { camera.nvrRecordSound = recordSound }
            guard camera != old else { return }
            var updated = configurations
            updated[index] = camera
            try await save(BridgeConfiguration(settings: storedSettings, cameras: updated))
            configurations = updated
            statusInputsChanged()
            if camera.nvrEnabled != old.nvrEnabled {
                log.notice("Recording \(camera.nvrEnabled ? "turned on" : "turned off") for \(camera.name)")
            }
            if isActive, let runtime = runtimes[cameraID] { await nvr.apply(camera, previous: old, hub: runtime.hub) }
            await refreshStatus()
        }
    }

    /// Removes every pairing and gives the camera a new HomeKit identity (device ID, key, setup code and setup ID): the
    /// old setup code pairs nothing afterwards (a code that was shared or seen on screen), and Home sees a new accessory,
    /// to be added with the new code. A running camera's accessory restarts with it (live views and recordings end).
    public func resetPairing(cameraID: UUID) async throws {
        guard !isPreview else { return }
        try await operations.withLock {
            try await ensureLoaded()
            guard let camera = configurations.first(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
            let store = HAPStorage.store(for: cameraID, dataDirectory: environment.dataDirectory, secrets: environment.platform.secrets)
            let wasRunning = runtimes[cameraID] != nil || offAccessories[cameraID] != nil
            if wasRunning { await stopRuntime(cameraID) }
            do {
                _ = try await Self.offMain { try store.replaceIdentity() }
            } catch {
                log.error("The HomeKit pairing of \(camera.name) could not be reset: \(error)")
                if wasRunning, isActive { if camera.isEnabled { await startRuntimes([camera]) } else { await startOffAccessories([camera]) } }
                throw error
            }
            invalidateStoredIdentity(cameraID)
            log.notice("HomeKit pairing of \(camera.name) was reset; it has a new setup code")
            if wasRunning, isActive { if camera.isEnabled { await startRuntimes([camera]) } else { await startOffAccessories([camera]) } }
            await refreshStatus()
        }
    }

    /// `resetPairing(cameraID:)` for the sensors bridge (a running bridge restarts with its new identity).
    // MARK: Plugin helpers

    /// Whether `host` answers on TCP `port` within `timeout`: `.answers` (it accepted), `.refused` (the host is there but nothing listens),
    /// `.silent` (no answer). A plugin uses it to see whether a camera's RTSP is on and, sweeping a subnet, to make the system learn each
    /// host's MAC address (its neighbour table).
    public func portAnswer(host: String, port: UInt16, timeout: Duration) async -> PortAnswer {
        do {
            let connection = try await environment.platform.transport.connect(host: host, port: port, timeout: timeout)
            connection.close()
            return .answers
        } catch TransportError.connectionRefused {
            return .refused
        } catch {
            return .silent
        }
    }

    /// This machine's IPv4 addresses on interfaces that are up (not loopback), for a plugin that sweeps its local network.
    public nonisolated func localIPv4Addresses() -> [String] {
        StreamAddress.interfaceAddresses().map(\.address).filter { !$0.contains(":") && !$0.hasPrefix("127.") }
    }

    // MARK: Plugin secrets

    /// A plugin's secret (its account tokens and keys), kept in the platform `SecretStore` as `plugin.<id>`: never in `config.json`, logs or
    /// the page. nil when none is stored. `id` is the plugin's id: lowercase letters, digits and dashes.
    public func pluginSecret(id: String) throws -> Data? {
        try environment.platform.secrets.read(account: try Self.pluginAccount(id))
    }

    /// Stores (or with nil deletes) a plugin's secret.
    public func setPluginSecret(id: String, _ data: Data?) throws {
        try environment.platform.secrets.write(data, account: try Self.pluginAccount(id))
    }

    // MARK: The AI key

    /// The secret store account of the AI service's key: never `config.json`, logs, diagnostics, errors or any answer of the web API.
    static let aiKeyAccount = "ai.key"

    /// Saves the key of the AI service (`BridgeSettings.ai`) in the platform `SecretStore`, trimmed of the spaces, tabs and line breaks a paste
    /// brings along (`AIDescriptionSettings.cleanedKey`); nil or an empty string deletes it. Throws `EngineError.invalidSettings` for a key that
    /// is not 1 to `AIDescriptionSettings.maximumKeyLength` characters of visible ASCII once trimmed (a space or a control character inside it,
    /// anything that is not ASCII, only blanks), and then changes nothing. The key is write-only: the engine hands it to the describer's
    /// service and nobody else (`aiKey()`); everything the page can know of it is `aiKeySaved` and `aiKeyHint`. The describer takes the new key
    /// at once, and a pause after a refused key ends.
    public func setAIKey(_ key: String?) throws {
        guard let key, !key.isEmpty else {
            try environment.platform.secrets.write(nil, account: Self.aiKeyAccount)
            log.notice("The AI key was removed")
            setAIService(key: nil, fresh: true)
            return
        }
        guard let cleaned = AIDescriptionSettings.cleanedKey(key) else {
            throw EngineError.invalidSettings("the key must be 1 to \(AIDescriptionSettings.maximumKeyLength) characters of letters, digits and punctuation, with no spaces")
        }
        try environment.platform.secrets.write(Data(cleaned.utf8), account: Self.aiKeyAccount)
        log.notice("An AI key was saved")
        setAIService(key: cleaned, fresh: true)
    }

    /// The saved key; nil when none. For the engine and the describer only: not part of the web API.
    func aiKey() throws -> String? {
        try environment.platform.secrets.read(account: Self.aiKeyAccount).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Whether a key is saved (one that cannot be read counts as none).
    public var aiKeySaved: Bool { (try? aiKey()) != nil }

    /// The last four characters of the saved key, so the page can say which key is there; nil when none is saved, or the key is too short
    /// (under eight characters) for four of them to hide the rest.
    public var aiKeyHint: String? { (try? aiKey()).flatMap(AIDescriptionSettings.hint(forKey:)) }

    /// Whether a key is saved and its hint (`aiKeyHint`), from one read of the secret store made off the main actor: what the web API asks on
    /// every settings answer. A read that fails counts as no key, and is logged once (by the name of the secret, `ai.key`, never its value) until
    /// a read works again.
    public func aiKeyStatus() async -> (saved: Bool, hint: String?) {
        let secrets = environment.platform.secrets, account = Self.aiKeyAccount
        do {
            let data = try await Self.offMain { try secrets.read(account: account) }
            aiKeyReadFailed = false
            guard let data else { return (false, nil) }
            return (true, AIDescriptionSettings.hint(forKey: String(decoding: data, as: UTF8.self)))
        } catch {
            if !aiKeyReadFailed {
                aiKeyReadFailed = true
                log.warning("The AI key (\(account)) could not be read from the secret store")
            }
            return (false, nil)
        }
    }

    /// Deletes the saved key, off the main actor; whether there was one (as far as a read could tell). The key is for the service it was saved
    /// for (`keepsKey(from:)`). A key that cannot be read is deleted all the same: a failing read must not keep the settings on the old service,
    /// nor the key for the new one. Only a failure to delete throws.
    private func forgetAIKey() async throws -> Bool {
        let secrets = environment.platform.secrets, account = Self.aiKeyAccount
        return try await Self.offMain {
            let had = (try? secrets.read(account: account)) != nil
            try secrets.write(nil, account: account)
            return had
        }
    }

    // MARK: AI descriptions

    /// The describer of camera events (`EventDescriber`), made at first use: the engine starts and stops it with the bridge, hands it the
    /// events the event log began, and sets its service from the settings and the key whenever either changes.
    var aiDescriber: EventDescriber {
        if let describer { return describer }
        let nvr = nvr
        let made = EventDescriber(usageFile: environment.dataDirectory.appending(path: "ai/usage.json", directoryHint: .notDirectory),
                                  cameras: { [weak self] ids in await self?.describedCameras(ids) ?? [:] },
                                  record: { description, event in nvr.recordDescription(description, for: event) },
                                  now: tuning.aiNow)
        describer = made
        return made
    }

    /// What the Settings card shows of the AI descriptions: the day's and the week's counts, the limit, the last failure, and whether a
    /// recordings folder is needed first (without one no event is kept, so none is described).
    public func aiStatus() async -> AIStatus {
        guard !isPreview else { return AIStatus() }
        var status = await aiDescriber.status
        status.needsRecordingsFolder = storedSettings.nvrFolder == nil
        return status
    }

    /// Try it: describes the pictures around now of the camera `cameraID` with the chosen service and stores nothing (it counts toward the
    /// day). Throws `EngineError.unknownCamera`, `AIDescriberError` (no service, the limit, a camera that does not run, no picture) or the
    /// service's `AIProviderError`; both have a `sentence` for the page.
    public func tryAIDescription(cameraID: UUID) async throws -> EventDescription {
        guard !isPreview else { throw AIDescriberError.noService }
        guard configurations.contains(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
        return try await aiDescriber.tryNow(cameraID: cameraID)
    }

    /// The running cameras among `ids`, with their names and switches, for the describer.
    private func describedCameras(_ ids: Set<UUID>) -> [UUID: EventDescriber.Camera] {
        var described: [UUID: EventDescriber.Camera] = [:]
        for camera in configurations where ids.contains(camera.id) {
            guard let runtime = runtimes[camera.id] else { continue }
            described[camera.id] = EventDescriber.Camera(name: camera.name, describes: camera.aiDescriptions, frames: runtime)
        }
        return described
    }

    /// The service the settings name with `key`: Claude (which needs a key) or an OpenAI-compatible service (whose key may be none); nil when
    /// none is chosen or Claude has no key.
    nonisolated static func aiService(_ settings: AIDescriptionSettings, key: String?, transport: any AITransport,
                                      now: @escaping @Sendable () -> Date) -> (any AIVisionDescribing)? {
        switch settings.provider {
        case nil:
            return nil
        case .anthropic:
            guard let key, !key.isEmpty else { return nil }
            return AnthropicVision(key: key, model: settings.model, transport: transport, now: now)
        case .openAICompatible:
            guard let address = settings.baseURL, let url = URL(string: address) else { return nil }
            return OpenAICompatibleVision(baseURL: url, key: key, model: settings.model, transport: transport, now: now)
        }
    }

    /// Gives the describer the service the settings name, with the key read again (off the main actor). `fresh`: the AI settings, the service or
    /// its key changed (`EventDescriber.setService`).
    private func refreshAIService(fresh: Bool) async {
        aiServiceGeneration &+= 1
        let generation = aiServiceGeneration
        let secrets = environment.platform.secrets, account = Self.aiKeyAccount
        let key: String?
        do {
            key = try await Self.offMain { try secrets.read(account: account) }.map { String(decoding: $0, as: UTF8.self) }
        } catch {
            log.warning("The AI key (\(account)) could not be read; no event is described until it can be")
            key = nil
        }
        guard generation == aiServiceGeneration else { return }   // a key saved meanwhile already gave the describer its service
        setAIService(key: key, fresh: fresh)
    }

    /// Gives the describer the service the settings name with `key`, and the day's limit.
    private func setAIService(key: String?, fresh: Bool) {
        aiServiceGeneration &+= 1
        let settings = storedSettings.ai
        let service = Self.aiService(settings, key: key, transport: tuning.aiTransport ?? URLSessionAITransport(), now: tuning.aiNow)
        aiDescriber.setService(service, dailyLimit: settings.dailyLimit, fresh: fresh)
    }

    static func pluginAccount(_ id: String) throws -> String {
        guard !id.isEmpty, id.count <= 32, id.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else {
            throw EngineError.invalidSettings("not a plugin id")
        }
        return "plugin.\(id)"
    }

    public func resetSensorsBridgePairing() async throws {
        guard !isPreview else { return }
        try await operations.withLock {
            try await ensureLoaded()
            let store = HAPStorage.sensorsBridgeStore(dataDirectory: environment.dataDirectory, secrets: environment.platform.secrets)
            let wasRunning = bridge != nil
            if wasRunning { await stopSensorsBridge() }
            let identity: HAPIdentity
            do {
                identity = try await Self.offMain { try store.replaceIdentity() }
            } catch {
                log.error("The HomeKit pairing of the sensors bridge could not be reset: \(error)")
                if wasRunning, isActive { await startSensorsBridge() }
                throw error
            }
            log.notice("HomeKit pairing of the sensors bridge was reset; it has a new setup code")
            if wasRunning, isActive {
                await startSensorsBridge()
            } else if let shown = sensorsBridge {
                // Not running (paused): the status shown until it runs again names the new code.
                sensorsBridge = SensorsBridgeStatus(isPaired: false, setupCode: identity.setupCode.formatted,
                                                    setupURI: SetupPayload.uri(code: identity.setupCode, setupID: identity.setupID, category: .bridge),
                                                    accessoryCount: shown.accessoryCount, publishedSensors: shown.publishedSensors)
                statusInputsChanged()
            }
            await refreshStatus()
        }
    }

    // MARK: - Helpers for the app

    /// The Add Camera wizard's check. `vendor` nil detects it (`CameraDrivers.detect`), falling back to `.rtsp` when a
    /// main stream URL is given, else throws `EngineError.noCameraAPI`. An ONVIF device service found on another port
    /// than the HTTP port (detected, or searched for an ONVIF camera without `onvifPort`) is used and reported in
    /// `CameraProbeResult.onvifPort`. When the camera couldn't be reached, Local Network access is checked (waiting for
    /// the answer to the system's alert while none is known): denied → `TransportError.localNetworkDenied` (and
    /// `localNetworkAccess` follows); allowed just now → the probe runs once more.
    public func probeCamera(vendor: CameraVendor?, endpoint: CameraEndpoint, username: String, password: String,
                            mainStreamURL: URL?, subStreamURL: URL?) async throws -> CameraProbeResult {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        let credentials = username.isEmpty && password.isEmpty ? nil : HTTPCredentials(username: username, password: password)
        return try await probe(vendor: vendor, endpoint: endpoint, username: username, credentials: credentials,
                               mainStreamURL: mainStreamURL, subStreamURL: subStreamURL)
    }

    /// Probes a configured camera as `configuration` describes it (its type, endpoint, stream URLs and user name) with
    /// `password`, or with its stored password when nil. Saves nothing: the camera's Connection sheet checks a changed
    /// address this way before `updateCamera`, so the camera keeps its identity and pairing.
    public func probeCamera(_ configuration: CameraConfiguration, password: String?) async throws -> CameraProbeResult {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        let credentials = credentials
        let secrets: HTTPCredentials?
        if let password {
            secrets = configuration.username.isEmpty && password.isEmpty ? nil : HTTPCredentials(username: configuration.username, password: password)
        } else {
            secrets = try await Self.offMain { try credentials.credentials(for: configuration) }
        }
        // The stored credentials of its stream URLs, for the addresses it still has (a typed address brings its own). One that
        // cannot be read is left out: the check then tells whether the address works without them.
        let streamCredentials = (try? await Self.offMain { try credentials.streamCredentials(for: configuration) }) ?? .none
        return try await probe(vendor: configuration.vendor, endpoint: configuration.endpoint, username: configuration.username, credentials: secrets,
                               mainStreamURL: configuration.mainStreamURL, subStreamURL: configuration.subStreamURL,
                               integration: configuration.integration, streamCredentials: streamCredentials)
    }

    /// The Add Camera wizard's check of a camera behind a service (`CameraVendor.go2rtc`, `.unifi`): `secret` is the service's
    /// token, key or source address (what is saved as the camera's Keychain password). Saves nothing.
    public func probeIntegration(vendor: CameraVendor, integration: IntegrationSettings, endpoint: CameraEndpoint, username: String,
                                 secret: String) async throws -> CameraProbeResult {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        let credentials = username.isEmpty && secret.isEmpty ? nil : HTTPCredentials(username: username, password: secret)
        return try await probe(vendor: vendor, endpoint: endpoint, username: username, credentials: credentials, mainStreamURL: nil,
                               subStreamURL: nil, integration: integration)
    }

    /// Whether the go2rtc helper is part of this installation (cloud cameras need it).
    public var isStreamingHelperInstalled: Bool { go2rtcManager.isInstalled }

    /// Starts go2rtc's own sign-in pages on this Mac and returns the address to open in a browser (Ring, Wyze, Tuya, Nest accounts:
    /// the person types their credentials into go2rtc's page, never into Camera Bridge, and copies the source address it shows).
    /// The page closes after 20 minutes, with `endIntegrationSetup()` and when the bridge stops.
    public func beginIntegrationSetup() async throws -> URL {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        return try await go2rtcManager.beginSetupSession()
    }

    public func endIntegrationSetup() async {
        guard !isPreview else { return }
        await go2rtcManager.endSetupSession()
    }

    /// What the camera page was told when a camera's ONVIF service refused the stored credentials (or locked logins), kept
    /// so that opening the page again does not ask: every ask is a failed login, and a camera locks the account after a few
    /// (Hikvision for 30 minutes, RTSP included). Forgotten when the camera's settings change, after
    /// `EngineTuning.onvifRefusalMemory` (10 minutes), and when the person asks to check again.
    private struct ONVIFRefusal {
        var snapshot: CameraSettingsSnapshot
        var at: ContinuousClock.Instant
        var username: String
        var endpoint: CameraEndpoint
    }

    private var onvifRefusals: [UUID: ONVIFRefusal] = [:]

    /// Cameras that answered that they cannot turn their own on-screen clock off (every method said "unsupported"): the
    /// answer is repeated without asking again (a Reolink doorbell with no such ability keeps having none). Forgotten when
    /// the camera's settings change.
    private var clockUnsupported: [UUID: CameraClockChange] = [:]

    /// The remembered refusal for `camera`, when it still holds.
    private func rememberedONVIFRefusal(for camera: CameraConfiguration) -> CameraSettingsSnapshot? {
        guard let refusal = onvifRefusals[camera.id] else { return nil }
        let stillHolds = refusal.username == camera.username && refusal.endpoint == camera.endpoint
            && ContinuousClock.now - refusal.at < tuning.onvifRefusalMemory
            && (refusal.snapshot.onvifLoginPausedUntil.map { $0 > Date() } ?? true)
        if !stillHolds { onvifRefusals[camera.id] = nil }
        return stillHolds ? refusal.snapshot : nil
    }

    /// The camera's own ONVIF video/imaging settings and its web page address, for the Camera Settings sheet and the
    /// HomeKit Readiness card. Uses the camera's stored credentials. Throws `EngineError.unknownCamera` for an
    /// unconfigured camera; a camera that answers but has no ONVIF service still returns a snapshot
    /// (`supportsONVIF == false`, `webPageURL` set) rather than throwing, so the sheet can still offer the web page link.
    ///
    /// After ONVIF refused the credentials (or locked logins) the same answer is returned, without asking the camera,
    /// for 10 minutes (`recheck: false`, what opening the page does); `recheck: true` (the person asked to check again)
    /// asks now (the ONVIF login guard still pauses logins to a camera that just rejected one).
    public func cameraSettings(cameraID: UUID, recheck: Bool = false) async throws -> CameraSettingsSnapshot {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        guard let camera = configurations.first(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
        if !recheck, let remembered = rememberedONVIFRefusal(for: camera) { return remembered }
        if runtimes[cameraID]?.isUnreachable == true { throw CameraOfflineError() }   // nothing is sent to a camera that answers nothing
        let credentials = credentials
        let secrets = try await Self.offMain { try credentials.credentials(for: camera) }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: secrets, cameraID: cameraID)
        let snapshot = try await service.fetchSnapshot()
        if !snapshot.supportsONVIF, snapshot.onvifLoginRejected == true || snapshot.onvifLoginPausedUntil != nil {
            onvifRefusals[cameraID] = ONVIFRefusal(snapshot: snapshot, at: .now, username: camera.username, endpoint: camera.endpoint)
        } else {
            onvifRefusals[cameraID] = nil
        }
        return snapshot
    }

    /// Applies `change` to the camera's ONVIF video encoder and/or imaging settings, then — when an encoder changed —
    /// restarts the camera's ingest (its HomeKit accessory keeps its pairing and port) so the new stream parameters
    /// take effect. Changing resolution can require re-enabling HomeKit Secure Video recording for the camera in the
    /// Home app; the caller shows that note.
    public func applyCameraSettings(cameraID: UUID, _ change: CameraSettingsChange) async throws {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        try await operations.withLock {
            guard let camera = configurations.first(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
            let credentials = credentials
            let secrets = try await Self.offMain { try credentials.credentials(for: camera) }
            let service = Self.encoderService(camera, secrets, profiles: cameraProfiles)
            do { try await service.apply(change) } catch {
                await rememberConfigMethod(cameraID: cameraID, service.memoryUpdate)
                throw error
            }
            await rememberConfigMethod(cameraID: cameraID, service.memoryUpdate)
            let encoderChanged = change.mainEncoder != nil || change.subEncoder != nil
            if encoderChanged, isActive, runtimes[cameraID] != nil {
                log.notice("Restarting \(camera.name)'s ingest after a camera settings change")
                await stopRuntime(cameraID)
                if camera.isEnabled { await startRuntimes([camera]) }
                await refreshStatus()
            }
        }
    }

    /// A settings service for changing this camera's video encoders: its vendor picks the methods to try and the method
    /// that worked last time goes first (`CameraConfigMethod.attemptOrder`).
    /// A camera with no remembered method falls back to the profiles feed's suggestion; a method that already worked is
    /// never overridden.
    static func encoderService(_ camera: CameraConfiguration, _ secrets: HTTPCredentials?, profiles: CameraProfileFeed = .empty) -> CameraSettingsService {
        CameraSettingsService(endpoint: camera.endpoint, credentials: secrets, cameraID: camera.id, vendor: camera.vendor,
                              mainStreamURL: camera.mainStreamURL,
                              preferredMethod: camera.preferredConfigMethod ?? profileMatch(profiles, camera: camera).preferredConfigMethod,
                              subStreamURL: camera.subStreamURL)
    }

    /// What the profiles feed says about this camera (brand, model and firmware as the configuration remembers them).
    static func profileMatch(_ profiles: CameraProfileFeed, camera: CameraConfiguration) -> CameraProfileMatch {
        profiles.match(vendor: camera.vendor, manufacturer: camera.manufacturer, model: camera.model, firmware: camera.firmware)
    }

    /// Installs the camera profiles feed (fetched or bundled by the app). Takes effect on the next encoder change or
    /// readiness check.
    public func setCameraProfiles(_ feed: CameraProfileFeed) {
        cameraProfiles = feed
    }

    func manualStepOverrides(for camera: CameraConfiguration, deviceInfo: CameraDeviceInfo?) -> [String: [String]] {
        cameraProfiles.match(vendor: camera.vendor, manufacturer: deviceInfo?.manufacturer ?? camera.manufacturer,
                             model: deviceInfo?.model ?? camera.model, firmware: deviceInfo?.firmwareVersion ?? camera.firmware).manualSteps
    }

    /// Stores (or clears) the camera's remembered encoder method after a settings service call, when it changed.
    func rememberConfigMethod(cameraID: UUID, _ update: CameraConfigMemoryUpdate?) async {
        guard let update, let index = configurations.firstIndex(where: { $0.id == cameraID }) else { return }
        let method: CameraConfigMethod?
        switch update {
        case .remember(let winner): method = winner
        case .forget: method = nil
        }
        guard configurations[index].preferredConfigMethod != method else { return }
        configurations[index].preferredConfigMethod = method
        log.info("\(configurations[index].name): \(method.map { "changes to its video settings go through \($0.displayName) first" } ?? "no remembered way to change its video settings")")
        await persist()
    }

    /// Whether an ONVIF or ISAPI encoding name is H.264 ("H264", "H.264").
    nonisolated static func isH264(_ encoding: String) -> Bool {
        encoding.uppercased().replacingOccurrences(of: ".", with: "") == "H264"
    }

    /// A codec's name as people read it: "H.264", "H.265" (HEVC), else as given.
    nonisolated static func codecDisplayName(_ codec: String) -> String {
        let cleaned = codec.uppercased().filter { $0 != "." && $0 != "-" && $0 != " " }
        switch cleaned {
        case "H264", "AVC": return "H.264"
        case "H265", "HEVC": return "H.265"
        default: return codec
        }
    }

    /// The measured codec's name when the camera's settings name another one (a camera whose ONVIF says H.264 while it sends H.265);
    /// nil when they agree or nothing was measured.
    nonisolated static func measuredCodecMismatch(reported: String, measured: String?) -> String? {
        guard let measured else { return nil }
        let real = codecDisplayName(measured), said = codecDisplayName(reported)
        return real == said ? nil : real
    }

    /// After the setup changed the streams and the bridge started receiving them again: a sentence when a stream the setup set to H.264
    /// still arrives as something else (the camera took the setting but kept its codec), nil when it is right or not measured yet.
    nonisolated static func streamsStillWrong(planned: [PlannedEncoderFix], measuredMain: String?, measuredSub: String?) -> String? {
        var wrong: [(name: String, codec: String)] = []
        for plan in planned where isH264(plan.edit.desired.encoding) {
            guard let measured = plan.isSub ? measuredSub : measuredMain, !isH264(measured) else { continue }
            wrong.append((plan.isSub ? "sub" : "main", codecDisplayName(measured)))
        }
        guard !wrong.isEmpty else { return nil }
        let codecs = Set(wrong.map(\.codec))
        let names = wrong.map(\.name).joined(separator: " and ")
        let streams = wrong.count == 1 ? "its \(names) stream is" : "its \(names) streams are"
        return "The camera says \(streams) H.264 but still sends \(codecs.count == 1 ? codecs.first! : codecs.sorted().joined(separator: " and "))."
    }

    /// Reboots the camera (ONVIF `SystemReboot`). The app confirms with the person before calling this.
    public func rebootCamera(cameraID: UUID) async throws {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        guard let camera = configurations.first(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
        let credentials = credentials
        let secrets = try await Self.offMain { try credentials.credentials(for: camera) }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: secrets, cameraID: cameraID)
        try await service.reboot()
    }

    /// Turns the camera's own on-screen date and time off (`hidden`) or back on, so only the CameraBridge timestamp shows.
    /// Tries the vendor's API (Hikvision ISAPI `DateTimeOverlay`, Reolink `SetOsd`), then ONVIF's OSD service, and
    /// remembers how it was hidden (`CameraConfiguration.hiddenCameraClock`: the method, and what the camera showed before)
    /// so turning it back on puts it as it was. A camera that cannot do it is reported in the result (`isUnsupported`),
    /// not thrown; a rejected login or a locked-out camera ends the attempt (the ONVIF login guard is respected). Throws
    /// `EngineError.unknownCamera` for an unconfigured camera and `CancellationError`.
    public func setCameraClockHidden(cameraID: UUID, hidden: Bool) async throws -> CameraClockChange {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        if runtimes[cameraID]?.isUnreachable == true { throw CameraOfflineError() }
        return try await operations.withLock {
            guard let camera = configurations.first(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
            if hidden, camera.hiddenCameraClock != nil { return CameraClockChange(succeeded: true, method: nil, backup: camera.hiddenCameraClock) }
            // Shown, but not hidden by the bridge: a Hikvision or Reolink camera can still turn its clock on through its own API (it may have been
            // off from the factory or the camera's own page). Others are left as they are.
            let showOwn: HiddenCameraClock? = switch camera.vendor {
            case .hikvision: HiddenCameraClock(method: .hikvisionISAPI, wasShown: true)
            case .reolink: HiddenCameraClock(method: .reolinkAPI, wasShown: true)
            default: nil
            }
            if !hidden, camera.hiddenCameraClock == nil, showOwn == nil { return CameraClockChange(succeeded: true, method: nil) }
            if hidden, let known = clockUnsupported[cameraID] { return known }
            let credentials = credentials
            let secrets = try await Self.offMain { try credentials.credentials(for: camera) }
            let service = CameraSettingsService(endpoint: camera.endpoint, credentials: secrets, cameraID: cameraID, vendor: camera.vendor,
                                                mainStreamURL: camera.mainStreamURL, preferredMethod: camera.preferredConfigMethod)
            let change: CameraClockChange
            if hidden {
                change = try await service.hideCameraClock()
            } else if let backup = camera.hiddenCameraClock ?? showOwn {
                change = try await service.restoreCameraClock(backup)
            } else {
                return CameraClockChange(succeeded: true, method: nil)
            }
            if hidden, change.isUnsupported {
                clockUnsupported[cameraID] = change
                log.info("\(camera.name): the camera cannot turn its own clock off (\(change.summary)); not asking again")
            }
            guard change.succeeded, let index = configurations.firstIndex(where: { $0.id == cameraID }) else { return change }
            configurations[index].hiddenCameraClock = hidden ? change.backup : nil
            log.info("\(camera.name): the camera's own clock is \(hidden ? "hidden" : "shown again") (\(change.summary))")
            await persist()
            return change
        }
    }

    /// "Clean picture": every label the camera draws itself (clock, name, text lines, logo) off (`clean`), so the bridge's own timestamp and name
    /// are the only ones, the same on every camera; or back as they were. The backup is kept in `CameraConfiguration.cleanPictureBackup`, which
    /// only the engine writes. Throws `EngineError.unknownCamera`, `CameraOfflineError` for an unreachable camera, and `CancellationError`.
    /// Moves a pan/tilt camera (`pan`, `tilt` in -1…1; both 0 stops it). A move ends by itself 1.5 s after the last ask, so the page
    /// repeats it while a button is held. Throws `EngineError.cameraNotRunning` for a camera that isn't running or can't pan and tilt.
    /// Sets a camera's night vision mode and/or its lamp (`CameraStatus.nightVision` says what it offers). Throws
    /// `EngineError.cameraNotRunning` for a camera that isn't running or can't do it.
    public func setNightVision(cameraID: UUID, mode: NightVisionMode?, light: Bool?) async throws {
        guard !isPreview, let runtime = runtimes[cameraID] else { throw EngineError.cameraNotRunning }
        try await runtime.setNightVision(mode: mode, light: light)
    }

    public func panTilt(cameraID: UUID, pan: Double, tilt: Double, zoom: Double = 0) async throws {
        guard !isPreview, let runtime = runtimes[cameraID] else { throw EngineError.cameraNotRunning }
        try await runtime.panTilt(pan: pan, tilt: tilt, zoom: zoom)
    }

    public func setCleanPicture(cameraID: UUID, clean: Bool) async throws -> CleanPictureChange {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        if runtimes[cameraID]?.isUnreachable == true { throw CameraOfflineError() }
        return try await operations.withLock {
            guard let camera = configurations.first(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
            // "Set up for Camera Bridge" keeps its clean-picture backup in its own (one backup, one way back); this switch turns it back too.
            let saved = camera.cleanPictureBackup ?? camera.setupBackup?.cleanPicture
            if clean, saved != nil { return CleanPictureChange(succeeded: true, summary: "already clean") }
            if !clean, saved == nil { return CleanPictureChange(succeeded: true, summary: "already as the camera had it") }
            let credentials = credentials
            let secrets = try await Self.offMain { try credentials.credentials(for: camera) }
            let service = CameraSettingsService(endpoint: camera.endpoint, credentials: secrets, cameraID: cameraID, vendor: camera.vendor,
                                                mainStreamURL: camera.mainStreamURL, preferredMethod: camera.preferredConfigMethod)
            let change = if clean { try await service.cleanPicture() } else { try await service.restorePicture(saved!) }
            guard change.succeeded, let index = configurations.firstIndex(where: { $0.id == cameraID }) else { return change }
            configurations[index].cleanPictureBackup = clean ? change.backup : nil
            if !clean, let setup = configurations[index].setupBackup, setup.cleanPicture != nil {
                let rest = setup.clearing(.cleanPicture)
                configurations[index].setupBackup = rest.isEmpty ? nil : rest
                if rest.isEmpty { configurations[index].setupState = nil }
            }
            log.info("\(camera.name): the camera's own labels are \(clean ? "off" : "back") (\(change.summary))")
            await persist()
            return change
        }
    }

    /// The HomeKit Readiness advisor's grading of a camera that isn't configured yet (the Add Camera wizard, right
    /// after `probeCamera`): reads the ONVIF snapshot directly with a throwaway `CameraSettingsService`, the same way
    /// `probeCamera` builds a throwaway driver. No measured stream facts (the camera has no runtime yet).
    public func homeKitReadiness(vendor: CameraVendor, endpoint: CameraEndpoint, credentials: HTTPCredentials?) async throws -> HomeKitReadinessReport {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        let service = CameraSettingsService(endpoint: endpoint, credentials: credentials)
        let snapshot = try await service.fetchSnapshot()
        let overrides = cameraProfiles.match(vendor: vendor, manufacturer: snapshot.deviceInfo?.manufacturer, model: snapshot.deviceInfo?.model,
                                             firmware: snapshot.deviceInfo?.firmwareVersion).manualSteps
        return HomeKitReadinessAdvisor.evaluate(vendor: vendor, deviceInfo: snapshot.deviceInfo, snapshot: snapshot, manualStepOverrides: overrides)
    }

    /// The HomeKit Readiness advisor's grading of this camera right now: its ONVIF encoder settings plus, when the
    /// camera is running, the runtime's own measured stream facts (codec/size/rate/GOP/B-frames). Throws
    /// `EngineError.unknownCamera` for an unconfigured camera.
    public func homeKitReadiness(cameraID: UUID, recheck: Bool = false) async throws -> HomeKitReadinessReport {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        guard let camera = configurations.first(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
        let snapshot = try await cameraSettings(cameraID: cameraID, recheck: recheck)
        let facts = await runtimes[cameraID]?.readinessFacts()
        let report = Self.reflectingConfiguredSubStream(
            HomeKitReadinessAdvisor.evaluate(vendor: camera.vendor, deviceInfo: snapshot.deviceInfo, snapshot: snapshot,
                                             mainStreamFacts: facts?.main, subStreamFacts: facts?.sub,
                                             manualStepOverrides: manualStepOverrides(for: camera, deviceInfo: snapshot.deviceInfo)),
            camera: camera, measured: facts?.sub != nil)
        guard camera.vendor == .hikvision else { return report }
        let credentials = credentials
        guard let secrets = try? await Self.offMain({ try credentials.credentials(for: camera) }) else { return report }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: secrets, cameraID: cameraID)
        return await Self.reflectingHikvisionSmartCodec(report, camera: camera, service: service)
    }

    /// When ONVIF can't list profiles and the sub stream hasn't been pulled yet (it's only opened on demand), the
    /// advisor has nothing to judge; a configured sub stream URL is still a sub stream, so don't warn it's missing.
    static func reflectingConfiguredSubStream(_ report: HomeKitReadinessReport, camera: CameraConfiguration,
                                              measured: Bool) -> HomeKitReadinessReport {
        guard !measured, camera.subStreamURL != nil,
              let index = report.checks.firstIndex(where: { $0.id == "subStream" }),
              report.checks[index].status != .ok,
              report.checks[index].explanation.hasPrefix("No second") else { return report }
        var report = report
        report.checks[index].status = .ok
        report.checks[index].explanation = "A sub stream is set up for Apple Watch and remote viewing. Its size is checked "
            + "once it's in use."
        report.checks[index].fixMethod = .none
        return report
    }

    /// The advisor can't see vendor smart codecs over ONVIF, so it always warns. Hikvision exposes the real state over
    /// ISAPI: read it so the check says OK once H.264+/H.265+ is off (or not offered) and only offers a fix when it's on.
    static func reflectingHikvisionSmartCodec(_ report: HomeKitReadinessReport, camera: CameraConfiguration,
                                              service: CameraSettingsService) async -> HomeKitReadinessReport {
        guard camera.vendor == .hikvision,
              let index = report.checks.firstIndex(where: { $0.id == "smartCodec" }) else { return report }
        let channel = CameraDrivers.hikvisionChannelID(mainStreamURL: camera.mainStreamURL, sub: false)
        guard let state = try? await service.hikvisionSmartCodecEnabled(channelID: channel) else { return report }
        var report = report
        var check = report.checks[index]
        if state == true {
            check.status = .problem
            check.explanation = "H.264+/H.265+ is on. It stretches the keyframe interval on quiet scenes, which delays and breaks "
                + "HomeKit recordings. Optimize turns it off."
            check.fixMethod = .automatic
        } else {
            check.status = .ok
            check.explanation = state == false ? "H.264+/H.265+ is off." : "This camera doesn't offer H.264+/H.265+."
            check.fixMethod = .none
        }
        report.checks[index] = check
        return report
    }

    /// Applies every automatic HomeKit Readiness fix it can (ONVIF main/sub encoder settings; Hikvision's own
    /// "H.264+"/"H.265+" smart codec over ISAPI), snapshotting the previous values first (`undoHomeKitOptimization`),
    /// restarts the camera's ingest, waits for the reconnected stream and re-measures for a few seconds, then returns
    /// a before/after report. Never touches a setting this call didn't decide to change. Throws
    /// `EngineError.unknownCamera` for an unconfigured camera; a failure applying one fix is recorded in
    /// `failedFixes` rather than aborting the others.
    @discardableResult
    public func optimizeForHomeKit(cameraID: UUID) async throws -> HomeKitOptimizationResult {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        return try await operations.withLock {
            guard let camera = configurations.first(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
            let credentials = credentials
            let secrets = try await Self.offMain { try credentials.credentials(for: camera) }
            let service = Self.encoderService(camera, secrets, profiles: cameraProfiles)

            let before = try await service.fetchSnapshot()
            let beforeFacts = await runtimes[cameraID]?.readinessFacts()
            let beforeReport = await Self.reflectingHikvisionSmartCodec(
                HomeKitReadinessAdvisor.evaluate(vendor: camera.vendor, deviceInfo: before.deviceInfo, snapshot: before,
                                                 mainStreamFacts: beforeFacts?.main, subStreamFacts: beforeFacts?.sub,
                                                 manualStepOverrides: manualStepOverrides(for: camera, deviceInfo: before.deviceInfo)),
                camera: camera, service: service)

            var undo = HomeKitOptimizationSnapshot()
            var appliedFixes: [String] = []
            var failedFixes: [HomeKitOptimizationFailure] = []
            var fixMethods: [String: CameraConfigMethod] = [:]
            var resolutionOrCodecChanged = false
            var streamChanged = false

            // Hikvision's smart codec ("H.264+") stretches the keyframe interval; it is turned off first, over ISAPI (it has
            // no ONVIF equivalent), so the encoder changes below can take effect.
            if camera.vendor == .hikvision {
                let mainChannel = CameraDrivers.hikvisionChannelID(mainStreamURL: camera.mainStreamURL, sub: false)
                let subChannel = CameraDrivers.hikvisionChannelID(mainStreamURL: camera.mainStreamURL, sub: true)
                do {
                    if let enabled = try await service.hikvisionSmartCodecEnabled(channelID: mainChannel), enabled {
                        undo.hikvisionMainSmartCodec = true
                        try await service.setHikvisionSmartCodec(enabled: false, channelID: mainChannel)
                        if !appliedFixes.contains("smartCodec") { appliedFixes.append("smartCodec") }
                        fixMethods["smartCodec"] = .hikvisionISAPI
                        streamChanged = true
                    }
                    if let enabled = try await service.hikvisionSmartCodecEnabled(channelID: subChannel), enabled {
                        undo.hikvisionSubSmartCodec = true
                        try await service.setHikvisionSmartCodec(enabled: false, channelID: subChannel)
                        if !appliedFixes.contains("smartCodec") { appliedFixes.append("smartCodec") }
                        fixMethods["smartCodec"] = .hikvisionISAPI
                        streamChanged = true
                    }
                } catch {
                    failedFixes.append(HomeKitOptimizationFailure(checkID: "smartCodec", reason: "ISAPI: " + Self.readableReason(error)))
                }
            }

            // Each stream's current settings: ONVIF's, or (Hikvision) ISAPI's when ONVIF can't list its profiles.
            var main = before.mainProfile?.settings
            var sub = before.subProfile?.settings
            if camera.vendor == .hikvision {
                if main == nil { main = try? await service.hikvisionEncoderSettings(isSub: false) }
                if sub == nil { sub = try? await service.hikvisionEncoderSettings(isSub: true) }
            }

            let planned = Self.plannedEncoderFixes(main: main, mainProfile: before.mainProfile, sub: sub, subProfile: before.subProfile,
                                                   mainHasBFrames: beforeFacts?.main?.hasBFrames == true,
                                                   mainMeasuredCodec: beforeFacts?.main?.codec, subMeasuredCodec: beforeFacts?.sub?.codec)

            // Each stream is changed through the first method that works (the camera's remembered one first) and read back.
            if !planned.isEmpty {
                let results = try await service.applyEncoder(planned.map(\.edit))
                for (plan, result) in zip(planned, results) {
                    if result.succeeded {
                        guard let method = result.method else { continue }   // already as wanted: nothing changed
                        appliedFixes.append(contentsOf: plan.fixes)
                        for fix in plan.fixes { fixMethods[fix] = method }
                        if plan.isSub {
                            undo.subEncoder = plan.before
                            undo.subOptions = plan.options
                        } else {
                            undo.mainEncoder = plan.before
                            undo.mainOptions = plan.options
                        }
                        if plan.fixes.contains("codec") { resolutionOrCodecChanged = true }
                        streamChanged = true
                    } else {
                        failedFixes.append(HomeKitOptimizationFailure(checkID: plan.fixes.first ?? "encoder", reason: result.summary,
                                                                      attempts: result.failures))
                    }
                }
                await rememberConfigMethod(cameraID: cameraID, service.memoryUpdate)
            }

            if !undo.isEmpty { homeKitOptimizationSnapshots[cameraID] = undo } else { homeKitOptimizationSnapshots[cameraID] = nil }

            let encoderChanged = streamChanged
            if encoderChanged, isActive, runtimes[cameraID] != nil {
                log.notice("Restarting \(camera.name)'s ingest after a HomeKit optimization")
                await stopRuntime(cameraID)
                if camera.isEnabled { await startRuntimes([camera]) }
                await refreshStatus()
            }

            var afterFacts: (main: MeasuredStreamFacts?, sub: MeasuredStreamFacts?) = (nil, nil)
            if isActive, let runtime = runtimes[cameraID] {
                let deadline = ContinuousClock.now.advanced(by: tuning.homeKitOptimizationMeasureWait)
                while true {
                    afterFacts = await runtime.readinessFacts()
                    if afterFacts.main?.codec != nil || ContinuousClock.now >= deadline { break }
                    try? await Task.sleep(for: tuning.homeKitOptimizationPollInterval)
                }
            }

            let after = (try? await service.fetchSnapshot()) ?? before
            let afterReport = await Self.reflectingHikvisionSmartCodec(
                HomeKitReadinessAdvisor.evaluate(vendor: camera.vendor, deviceInfo: after.deviceInfo, snapshot: after,
                                                 mainStreamFacts: afterFacts.main, subStreamFacts: afterFacts.sub,
                                                 manualStepOverrides: manualStepOverrides(for: camera, deviceInfo: after.deviceInfo)),
                camera: camera, service: service)

            return HomeKitOptimizationResult(before: beforeReport, after: afterReport, appliedFixes: appliedFixes, failedFixes: failedFixes,
                                             fixMethods: fixMethods, canUndo: !undo.isEmpty, mayNeedRecordingReEnabled: resolutionOrCodecChanged)
        }
    }

    /// The HomeKit optimizer's encoder changes for a camera's two streams (`optimizeForHomeKit`, and the streams step of "Set up for Camera
    /// Bridge"): the main stream H.264 at 15 to 25 fps, a keyframe every 2 seconds, 2 to 6 Mbit/s (8 for 4K: `HomeKitReadinessAdvisor.maximumMainBitrateKbps`), no B-frames; the sub stream H.264 at the
    /// same rate and keyframe interval, 360 to 720 lines high. Empty when both are right already. Only H.264/H.265 streams are planned.
    /// `mainMeasuredCodec` / `subMeasuredCodec` are the codecs the bridge really receives (`MeasuredStreamFacts.codec`, nil when not
    /// measured): a camera whose settings say H.264 while it sends H.265 (a Jennov's ONVIF did) is planned as a codec change too.
    static func plannedEncoderFixes(main: CameraVideoEncoderSettings?, mainProfile: CameraVideoProfile?, sub: CameraVideoEncoderSettings?,
                                    subProfile: CameraVideoProfile?, mainHasBFrames: Bool, mainMeasuredCodec: String? = nil,
                                    subMeasuredCodec: String? = nil) -> [PlannedEncoderFix] {
        var planned: [PlannedEncoderFix] = []
        // Only streams: a JPEG/MJPEG encoder (a camera's snapshot profile) is never planned or written as one.
        let main = main.flatMap { CameraSettingsService.isStreamCodec($0.encoding) ? $0 : nil }
        let sub = sub.flatMap { CameraSettingsService.isStreamCodec($0.encoding) ? $0 : nil }
        if let main {
            let options = mainProfile?.options ?? []
            let current = options.first { $0.encoding.caseInsensitiveCompare(main.encoding) == .orderedSame }
            let fps = main.frameRate ?? 15
            let targetFPS = min(25, max(15, fps))
            let targetGOP = max(1, Int((targetFPS * 2).rounded()))
            let maxBitrate = HomeKitReadinessAdvisor.maximumMainBitrateKbps(width: main.resolution?.width, height: main.resolution?.height)
            let targetBitrate = main.bitrate.map { min(maxBitrate, max(2000, $0)) } ?? 4096
            let h264Offered = options.isEmpty || options.contains { Self.isH264($0.encoding) }
            let needsCodec = (!Self.isH264(main.encoding) || mainMeasuredCodec.map { !Self.isH264($0) } == true) && h264Offered
            let needsGOP = main.iFrameInterval != targetGOP
            let baseline = current?.h264ProfilesSupported.first { $0.lowercased().hasPrefix("base") }
            let needsBFrames = mainHasBFrames && Self.isH264(main.encoding) && baseline != nil
                && main.h264Profile?.lowercased().hasPrefix("base") != true
            let needsFPS = !(15...25).contains(fps)
            // 5 % above the cap is left alone: cameras take only some values (a 4K PTZ at 8.2 Mbit/s refused 8.0), and that little more
            // costs nothing.
            let needsBitrate = main.bitrate.map { !(2000...(maxBitrate + maxBitrate / 20)).contains($0) } ?? false
            if needsCodec || needsGOP || needsBFrames || needsFPS || needsBitrate {
                var fixed = main
                var fixes: [String] = []
                if needsCodec { fixed.encoding = "H264"; fixes.append("codec") }
                if needsGOP { fixed.iFrameInterval = targetGOP; fixes.append("keyframeInterval") }
                if needsBFrames { fixed.h264Profile = baseline; fixes.append("bFrames") }
                if needsFPS { fixed.frameRate = targetFPS; fixes.append("frameRate") }
                if needsBitrate { fixed.bitrate = targetBitrate; fixes.append("bitrate") }
                // A camera that already reports H.264 while it sends something else gets the codec written anyway.
                planned.append(PlannedEncoderFix(isSub: false, before: main, options: options, fixes: fixes,
                                                 edit: CameraEncoderEdit(isSub: false, desired: fixed, options: options,
                                                                         rewriteCodec: needsCodec && Self.isH264(main.encoding))))
            }
        }
        if let sub {
            let options = subProfile?.options ?? []
            let fps = sub.frameRate ?? 15
            let targetFPS = min(25, max(15, fps))
            let targetGOP = max(1, Int((targetFPS * 2).rounded()))
            let height = sub.resolution?.height ?? 0
            let sizeOK = (360...720).contains(height)
            let h264Offered = options.isEmpty || options.contains { Self.isH264($0.encoding) }
            let needsCodec = (!Self.isH264(sub.encoding) || subMeasuredCodec.map { !Self.isH264($0) } == true) && h264Offered
            let needsGOP = sub.iFrameInterval != targetGOP
            let better = subProfile?.currentEncodingOptions?.resolutions.min { abs($0.height - 480) < abs($1.height - 480) }
            let needsSize = !sizeOK && better != nil
            if needsCodec || needsGOP || needsSize {
                var fixed = sub
                if needsCodec { fixed.encoding = "H264" }
                fixed.iFrameInterval = targetGOP
                fixed.frameRate = targetFPS
                if needsSize, let better { fixed.resolution = better }
                planned.append(PlannedEncoderFix(isSub: true, before: sub, options: options, fixes: ["subStream"],
                                                 edit: CameraEncoderEdit(isSub: true, desired: fixed, options: options,
                                                                         rewriteCodec: needsCodec && Self.isH264(sub.encoding))))
            }
        }
        return planned
    }

    /// Restores the encoder/smart-codec values `optimizeForHomeKit(cameraID:)` last changed for this camera, then
    /// restarts its ingest. Throws `EngineError.cameraNotRunning` when there's nothing to undo (no optimization ran,
    /// it already failed completely, or undo already consumed the snapshot).
    public func undoHomeKitOptimization(cameraID: UUID) async throws {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        try await operations.withLock {
            guard let undo = homeKitOptimizationSnapshots[cameraID], !undo.isEmpty else { throw EngineError.cameraNotRunning }
            guard let camera = configurations.first(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
            let credentials = credentials
            let secrets = try await Self.offMain { try credentials.credentials(for: camera) }
            // The camera's remembered method (the one the optimization used) goes first.
            let service = Self.encoderService(camera, secrets, profiles: cameraProfiles)

            var edits: [CameraEncoderEdit] = []
            if let main = undo.mainEncoder { edits.append(CameraEncoderEdit(isSub: false, desired: main, options: undo.mainOptions)) }
            if let sub = undo.subEncoder { edits.append(CameraEncoderEdit(isSub: true, desired: sub, options: undo.subOptions)) }
            var streamRestored = false
            if !edits.isEmpty {
                let results: [CameraEncoderEditResult]
                do { results = try await service.applyEncoder(edits) } catch {
                    await rememberConfigMethod(cameraID: cameraID, service.memoryUpdate)
                    throw error
                }
                await rememberConfigMethod(cameraID: cameraID, service.memoryUpdate)
                let failed = results.filter { !$0.succeeded }
                if !failed.isEmpty { throw CameraConfigError(attempts: failed.flatMap(\.failures)) }
                streamRestored = results.contains { $0.method != nil }
            }
            if undo.hikvisionMainSmartCodec == true {
                let channel = CameraDrivers.hikvisionChannelID(mainStreamURL: camera.mainStreamURL, sub: false)
                try await service.setHikvisionSmartCodec(enabled: true, channelID: channel)
                streamRestored = true
            }
            if undo.hikvisionSubSmartCodec == true {
                let channel = CameraDrivers.hikvisionChannelID(mainStreamURL: camera.mainStreamURL, sub: true)
                try await service.setHikvisionSmartCodec(enabled: true, channelID: channel)
                streamRestored = true
            }
            homeKitOptimizationSnapshots[cameraID] = nil

            if streamRestored, isActive, runtimes[cameraID] != nil {
                log.notice("Restoring \(camera.name)'s pre-optimization settings")
                await stopRuntime(cameraID)
                if camera.isEnabled { await startRuntimes([camera]) }
                await refreshStatus()
            }
        }
    }

    private func probe(vendor: CameraVendor?, endpoint: CameraEndpoint, username: String, credentials: HTTPCredentials?,
                       mainStreamURL: URL?, subStreamURL: URL?, integration: IntegrationSettings? = nil,
                       streamCredentials: StreamURLCredentials = .none) async throws -> CameraProbeResult {
        let accessBefore = localNetworkAccess
        do {
            return try await probeOnce(vendor: vendor, endpoint: endpoint, username: username, credentials: credentials,
                                       mainStreamURL: mainStreamURL, subStreamURL: subStreamURL, integration: integration,
                                       streamCredentials: streamCredentials)
        } catch {
            guard !Task.isCancelled, Self.mayNotHaveReachedTheCamera(error) else { throw error }
            // Local Network privacy blocks connections without telling URLSession or detection why (TN3179): ask the
            // transport, which knows. The probe may have raised the system's alert; wait for its answer then.
            let usesRTSP = vendor == .rtsp || (vendor == nil && mainStreamURL != nil)
            let port = UInt16(clamping: usesRTSP ? (mainStreamURL?.port ?? endpoint.rtspPort) : endpoint.httpPort)
            let wait = localNetworkAccess == .unknown ? tuning.localNetworkAnswerWait : .zero
            let access = await LocalNetworkCheck.check(host: endpoint.host, port: port, transport: environment.platform.transport,
                                                       answerWait: wait, retryInterval: tuning.localNetworkRetryInterval)
            if access != .unknown { noteLocalNetwork(access) }
            if access == .denied { throw TransportError.localNetworkDenied }
            guard access == .granted, accessBefore != .granted, !Task.isCancelled else { throw error }
            log.info("Local Network access is allowed; checking \(endpoint.host) again")
            return try await probeOnce(vendor: vendor, endpoint: endpoint, username: username, credentials: credentials,
                                       mainStreamURL: mainStreamURL, subStreamURL: subStreamURL, integration: integration,
                                       streamCredentials: streamCredentials)
        }
    }

    private func probeOnce(vendor: CameraVendor?, endpoint: CameraEndpoint, username: String, credentials: HTTPCredentials?,
                           mainStreamURL: URL?, subStreamURL: URL?, integration: IntegrationSettings? = nil,
                           streamCredentials: StreamURLCredentials = .none) async throws -> CameraProbeResult {
        var endpoint = endpoint
        var chosen = vendor
        if chosen == nil {
            let detection: VendorDetection?
            if let detect = tuning.detectVendor {
                detection = await detect(endpoint, credentials)
            } else {
                detection = await CameraDrivers.detect(endpoint: endpoint, credentials: credentials)
            }
            chosen = detection?.vendor
            if let port = detection?.onvifPort { endpoint.onvifPort = port }
        } else if chosen == .onvif, endpoint.onvifPort == nil {
            let port: Int?
            if let find = tuning.findONVIFPort {
                port = await find(endpoint)
            } else {
                port = await CameraDrivers.onvifPort(endpoint: endpoint)
            }
            if let port { endpoint.onvifPort = port }
        }
        if chosen == nil, mainStreamURL != nil { chosen = .rtsp }
        guard let chosen else { throw EngineError.noCameraAPI(host: endpoint.host) }
        let onvifPort = chosen == .onvif ? endpoint.onvifPort.flatMap { $0 == endpoint.httpPort ? nil : $0 } : nil
        func makeDriver(_ vendor: CameraVendor) -> any CameraDriver {
            var camera = CameraConfiguration(name: endpoint.host, kind: .camera, vendor: vendor, endpoint: endpoint, username: username)
            camera.mainStreamURL = mainStreamURL
            camera.subStreamURL = subStreamURL
            camera.integration = integration
            return tuning.driverFactory?(camera, credentials, environment.platform.transport)
                ?? CameraDrivers.make(vendor: vendor, endpoint: endpoint, credentials: credentials, mainStreamURL: mainStreamURL, subStreamURL: subStreamURL,
                                      transport: environment.platform.transport, cameraID: nil, integration: integration, go2rtc: go2rtc,
                                      helpers: environment.platform.helpers, streamCredentials: streamCredentials)
        }
        let driver = makeDriver(chosen)
        log.info("Probing \(endpoint.host) as \(chosen.rawValue)\(onvifPort.map { " (ONVIF port \($0))" } ?? "")")
        // The check's camera session ends with it (Reolink: a login holds one of the camera's few API sessions for an
        // hour otherwise); closed in the background, so the answer does not wait for the camera.
        defer { Task { await driver.close() } }
        guard chosen == .onvif, credentials != nil else {
            var result = try await driver.probe()
            result.onvifPort = onvifPort
            return result
        }
        // ONVIF can't read or change UPnP or the maker's cloud, so a camera that also answers its maker's own interface (Hikvision's ISAPI:
        // also ANNKE, LTS and other OEMs; Reolink; Dahua and Amcrest) is added as that. ONVIF is asked first: a wrong password stops there
        // as one failed login, and the maker's interface is asked only with credentials ONVIF accepted, or when ONVIF itself did not answer.
        var onvif: CameraProbeResult?
        var onvifFailure: (any Error)?
        do {
            onvif = try await driver.probe()
        } catch {
            if Task.isCancelled || Self.isLoginFailure(error) { throw error }
            onvifFailure = error
        }
        let check: OwnInterfaceCheck
        if let find = tuning.findOwnInterface {
            check = await find(endpoint, credentials)
        } else {
            check = await CameraDrivers.ownInterface(endpoint: endpoint, credentials: credentials)
        }
        if case .found(let own) = check, own.vendor != .onvif {
            let ownDriver = makeDriver(own.vendor)
            defer { Task { await ownDriver.close() } }
            if var result = try? await ownDriver.probe() {
                if let maker = own.manufacturer ?? onvif?.manufacturer, !maker.isEmpty { result.manufacturer = maker }
                if result.model.isEmpty, let model = own.model ?? onvif?.model { result.model = model }
                if result.serialNumber.isEmpty, let serial = onvif?.serialNumber { result.serialNumber = serial }
                if result.mainStream == nil { result.mainStream = onvif?.mainStream }
                if result.subStream == nil { result.subStream = onvif?.subStream }
                result.usedOwnInterface = true
                log.info("\(endpoint.host): \(own.vendor.rawValue)'s own interface answered; using it instead of ONVIF")
                return result
            }
        }
        guard var result = onvif else { throw onvifFailure ?? EngineError.noCameraAPI(host: endpoint.host) }
        result.onvifPort = onvifPort
        return result
    }

    /// The camera refused the login, or logins to it are paused: asking anything else with the same credentials would be one more failure.
    private static func isLoginFailure(_ error: any Error) -> Bool {
        switch error {
        case CameraAdapterError.unauthorized, CameraAdapterError.lockedOut, CameraAdapterError.loginsPaused: true
        case let rtsp as RTSPError: rtsp == .unauthorized
        default: false
        }
    }

    /// Errors after which the camera may never have seen the request (no answer, connection failures), as opposed to a
    /// camera that answered (wrong password, HTTP or RTSP error, unsupported stream).
    static func mayNotHaveReachedTheCamera(_ error: any Error) -> Bool {
        switch error {
        case EngineError.noCameraAPI: return true
        case is TransportError, is URLError: return true
        case let rtsp as RTSPError: return rtsp == .timeout
        case is CameraAdapterError, is EngineError, is CancellationError: return false
        default:
            let domain = (error as NSError).domain
            return domain == NSURLErrorDomain || domain == NSPOSIXErrorDomain
        }
    }

    /// ONVIF WS-Discovery and Hikvision's SADP on the LAN, at once (none in loopback-only environments: tests never multicast), merged
    /// (`mergedDiscovery`).
    public func discoverCameras() async -> [DiscoveredCamera] {
        guard !isPreview, !environment.loopbackOnly else { return [] }
        async let onvif = ONVIFDiscovery.discover()
        async let sadp = SADPDiscovery.discover()
        return Self.mergedDiscovery(onvif: await onvif, sadp: await sadp,
                                    interfaces: tuning.interfaceAddresses?() ?? StreamAddress.interfaceAddresses())
    }

    /// WS-Discovery's cameras, then SADP's: one SADP found at the same address adds whether it is set up (`activated`) and its web page's
    /// port to that entry; another is listed after them, marked `onAnotherNetwork` when its address is on none of the bridge's IPv4 networks
    /// (`interfaces` without loopback or tunnels, `SADPDevice.isOnNetwork(of:)`). Its MAC and serial number go no further.
    nonisolated static func mergedDiscovery(onvif: [DiscoveredCamera], sadp: [SADPDevice], interfaces: [InterfaceAddress]) -> [DiscoveredCamera] {
        var cameras = onvif
        // The bridge's own IPv4 networks: no loopback or tunnel (a VPN's network is not the home network).
        let networks = interfaces.filter { !$0.isIPv6 && !StreamAddress.isLoopback($0.address) && !MacVPNDetector.isTunnelName($0.interface) }
            .map { (address: $0.address, prefixLength: $0.prefixLength) }
        for device in sadp {
            if let index = cameras.firstIndex(where: { $0.host == device.ipv4Address }) {
                cameras[index].activated = cameras[index].activated ?? device.activated
                cameras[index].httpPort = cameras[index].httpPort ?? device.httpPort
                if cameras[index].hardware == nil { cameras[index].hardware = device.model }
                continue
            }
            let away = !device.isOnNetwork(of: networks)
            cameras.append(DiscoveredCamera(host: device.ipv4Address, hardware: device.model, activated: device.activated,
                                            onAnotherNetwork: away ? true : nil, httpPort: device.httpPort))
        }
        return cameras
    }

    /// The preview engine's sample status of the viewers in the app's own window (`liveVideo`); a real engine counts them in
    /// its runtimes.
    func previewAppViewersChanged(_ cameraID: UUID, by delta: Int) {
        guard isPreview, let index = cameras.firstIndex(where: { $0.id == cameraID }) else { return }
        cameras[index].appViewers = max(0, cameras[index].appViewers + delta)
    }

    /// A 1280×720 snapshot of the camera, straightened by its picture correction unless `original` (the camera's own picture: the
    /// web's camera page straightens that itself while its sliders move).
    public func snapshot(cameraID: UUID, original: Bool = false) async -> Data? {
        guard !isPreview, let runtime = runtimes[cameraID] else { return nil }
        return await runtime.snapshot(width: 1280, height: 720, original: original)
    }

    /// How long `checkLocalNetworkAccess(host:)` waits for the answer to the system's Local Network alert.
    public nonisolated static let localNetworkAnswerWait: Duration = .seconds(20)

    public func checkLocalNetworkAccess(host: String?) async -> LocalNetworkAccess {
        await checkLocalNetworkAccess(host: host, answerWait: Self.localNetworkAnswerWait)
    }

    /// While no answer is known yet (`localNetworkAccess == .unknown`) the system's Local Network alert may be on
    /// screen, and connections are blocked until the person answers it: a denial is retried for up to `answerWait`
    /// before it counts (and before `localNetworkAccess` changes). Once an answer is known, one attempt decides.
    public func checkLocalNetworkAccess(host: String?, answerWait: Duration) async -> LocalNetworkAccess {
        guard !isPreview, let host, !host.isEmpty else { return localNetworkAccess }
        let port = configurations.first { $0.endpoint.host == host }.map { UInt16(clamping: $0.endpoint.rtspPort) } ?? 80
        let wait = localNetworkAccess == .unknown ? answerWait : .zero
        let result = await LocalNetworkCheck.check(host: host, port: port, transport: environment.platform.transport,
                                                   answerWait: wait, retryInterval: tuning.localNetworkRetryInterval)
        if result != .unknown { noteLocalNetwork(result) }
        return result
    }

    /// Developer/demo aid: a motion pulse (held for the camera's motion hold).
    public func triggerTestMotion(cameraID: UUID) async {
        guard !isPreview else { return }
        await router.triggerMotion(for: cameraID)
    }

    /// The app forwards `NSWorkspace.didWakeNotification` (AppKit stays in the app target): restart ingest and
    /// re-advertise, `networkSettle` after the wake and the network changes it brings (a Mac rejoining Wi-Fi reports a
    /// path update with it): one reconnect for both (`scheduleReconnect`). Runs in turn with the lifecycle and
    /// configuration operations, so a reconnect never overlaps a pause, stop or camera change.
    public func systemDidWake() async {
        guard !isPreview else { return }
        let slept = sleepBegan.map { ContinuousClock.now - $0 }
        sleepBegan = nil
        guard isActive else { return }
        log.info("The Mac woke up" + (slept.map { " after \(Self.describeSleep($0))" } ?? ""))
        await purgeAfterWake(slept: slept)
        scheduleReconnect(woke: true)
    }

    /// The app forwards `NSWorkspace.willSleepNotification`: the Mac is going to sleep (logged, so a gap in the log and a camera
    /// that was "not responding" in Home have a visible cause; the wake path uses how long it slept).
    public func systemWillSleep() {
        guard !isPreview else { return }
        sleepBegan = .now
        guard isActive else { return }
        log.info("The Mac is going to sleep; Apple Home cannot reach the cameras until it wakes")
    }

    /// "37 s", "12 min", "8 h 5 min".
    static func describeSleep(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        if seconds < 90 { return "\(seconds) s" }
        if seconds < 5400 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \((seconds % 3600) / 60) min"
    }

    /// What a sleep leaves behind: HAP connections the controllers no longer hold (silent since before the sleep: closed, so the
    /// controllers connect and verify again instead of talking into a dead socket) and live views that were prepared and never
    /// started (ended, so the camera is not left "in use"). Done at once on wake, before the network settles and the cameras
    /// reconnect. A sleep of under half a minute leaves the connections alone (the network is the same).
    private func purgeAfterWake(slept: Duration?) async {
        // An unknown sleep time uses the server's own limit; a short one leaves the connections alone.
        let dropConnections = slept.map { $0 >= .seconds(30) } ?? true
        let running = Array(runtimes.values)
        await withTaskGroup(of: Void.self) { group in
            for runtime in running { group.addTask { await runtime.purgeAfterWake(dropConnections: dropConnections, inactiveFor: slept) } }
        }
        if dropConnections { await bridge?.server.dropStaleConnections(inactiveFor: slept) }
    }

    // MARK: - Services

    /// The Log Level setting is what the in-app log keeps (`recentLogs`). While a diagnostics log is installed
    /// (`DiagnosticsCenter.install`) every entry is produced regardless, at debug level, for the diagnostics bundle.
    private func applyLogLevel() {
        logs.minimumLevel = storedSettings.logLevel
        LogHub.minimumLevel = DiagnosticsCenter.shared.log == nil ? storedSettings.logLevel : .debug
    }

    private func startServices() async {
        state = .starting
        statusInputsChanged()
        if logToken == nil { logToken = LogHub.addSink(logs) }
        startLogLoop()
        // One copy per configuration: a second one would advertise the same cameras (same identities) and take the next ports.
        if let refusal = environment.platform.instanceLock.acquire(directory: environment.dataDirectory) {
            log.error(refusal)
            state = .failed(refusal)
            statusInputsChanged()
            return
        }
        do {
            try await ensureLoaded()
        } catch {
            log.error("The configuration could not be loaded: \(error)")
            state = .failed(Self.startFailure(error))   // shown by the app: a sentence, the raw error is in the log
            return
        }
        applyLogLevel()
        power.bridgeStarted(keepAwake: storedSettings.keepMacAwake)
        noteSleepRisk()
        let resolved = await PortAllocator(transport: environment.platform.transport).resolvePorts(for: configurations, settings: storedSettings)
        if resolved != configurations {
            configurations = resolved
            await persist()
        }
        for camera in configurations { await router.register(camera) }
        let registry = registry, changes = changes
        await router.setOutputHandler { output in
            registry.apply(output)
            changes.notify()
        }
        let nvr = nvr, describer = aiDescriber
        await describer.start()
        await refreshAIService(fresh: false)
        // The event log beside the recordings, and the events it began to the describer (it returns at once).
        await router.setEdgeHandler { edges in describer.eventsStarted(nvr.recordEvents(edges)) }
        startStatusLoop()
        await startSensorsBridge()
        await startWebhookReporting(storedSettings)
        nvr.start(settings: storedSettings)   // returns at once: repair and catalog load run in the background (the daemon waits for this function)
        await startRuntimes(configurations.filter(\.isEnabled))
        await startOffAccessories(configurations.filter { !$0.isEnabled })
        await applySky()
        startNetworkMonitoring()
        startHeartbeat()
        startDailySecurityChecks()
        startRemovedPairingSweep()
        startInternetGuard()
        state = .running
        statusInputsChanged()
        log.notice("Bridge running with \(configurations.count) camera\(configurations.count == 1 ? "" : "s")")
        await refreshStatus()
    }

    private func stopServices(then target: EngineState) async {
        networkTask?.cancel()
        networkTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        removedPairingSweepTask?.cancel()
        removedPairingSweepTask = nil
        heartbeatStrikes.removeAll()
        stopSecurityChecks()
        stopInternetGuardPoll()
        pendingReconnect?.task.cancel()   // monitoring stopped (pause, stop); one that began finds the bridge inactive
        pendingReconnect = nil
        cancelAccessoryRetries()
        await describer?.stop()   // before the runtimes it gathers pictures from
        await stopWebhook()
        webhookProblem = nil
        await nvr.detachAll()   // recorders flush and close while the hubs still deliver (`stopServices` clears `runtimes` without `stopRuntime`)
        await stopAllSky()   // the detectors write what they keep; nothing more is fetched for them. After the recordings, which come first (Ruling S27)
        let running = Array(runtimes.values)
        runtimes.removeAll()
        let off = Array(offAccessories.values)
        offAccessories.removeAll()
        statusInputsChanged()
        await withTaskGroup(of: Void.self) { group in
            for runtime in running { group.addTask { await runtime.stop() } }
            for accessory in off { group.addTask { await accessory.stop() } }
        }
        await nvr.stop()
        await stopSensorsBridge()
        await go2rtcManager.stop()   // the helper and its sign-in page end with the bridge
        storedIdentities.removeAll()
        identityGeneration &+= 1
        power.bridgeStopped()
        environment.platform.instanceLock.release()
        statusTask?.cancel()
        statusTask = nil
        state = target
        statusInputsChanged()
        if !running.isEmpty || target == .paused { log.notice(target == .paused ? "Bridge paused" : "Bridge stopped") }
        await refreshStatus()
    }

    /// Brings up the "Camera off" accessory of each camera in `cameras` (turned off, allowed to publish, none yet): no connection to the
    /// camera, only Apple Home's view of it. A camera whose accessory moved to another port keeps that port; a failure is logged (the
    /// next start of the bridge, or turning the camera on and off, tries again).
    func startOffAccessories(_ cameras: [CameraConfiguration]) async {
        for camera in cameras where !camera.isEnabled && offAccessories[camera.id] == nil && mayPublish(camera.id) {
            let accessory = CameraOffAccessory(configuration: camera, dependencies: .init(environment: environment, tuning: tuning,
                                                                                         onChange: { [changes] in changes.notify() }))
            offAccessories[camera.id] = accessory
            do {
                let port = try await accessory.start(port: camera.hapPort, reserved: reservedPorts(excluding: camera.id))
                if port != camera.hapPort, port != 0, let index = configurations.firstIndex(where: { $0.id == camera.id }) {
                    configurations[index].hapPort = port
                    await persist()
                }
            } catch {
                offAccessories[camera.id] = nil
                await accessory.stop()
                log.error("The HomeKit accessory of \(camera.name) (turned off) could not start: \(error)")
            }
        }
        statusInputsChanged()
    }

    /// Starts the runtimes of `cameras` concurrently; a camera whose accessory moved to another port keeps that port. A
    /// camera whose accessory could not start is offline with the reason and tried again with backoff (and at once on
    /// a wake or network change).
    func startRuntimes(_ cameras: [CameraConfiguration]) async {
        var started: [(CameraConfiguration, CameraRuntime, Set<UInt16>)] = []
        let wanted = cameras.filter { runtimes[$0.id] == nil }
        for camera in wanted { accessoryRetries.removeValue(forKey: camera.id)?.cancel() }   // starting now
        let credentials = credentials
        let passwords = await Self.offMainResults(wanted) { try credentials.credentials(for: $0) }
        let streamURLs = await Self.offMainResults(wanted) { try credentials.streamCredentials(for: $0) }
        for ((camera, password), stream) in zip(zip(wanted, passwords), streamURLs) where runtimes[camera.id] == nil {
            let secrets: HTTPCredentials?
            switch password {
            case .success(let value):
                secrets = value
            case .failure(let error):
                log.warning("The password of \(camera.name) could not be read (\(error)); connecting without it")
                secrets = camera.username.isEmpty ? nil : HTTPCredentials(username: camera.username, password: "")
            }
            let streamCredentials: StreamURLCredentials
            switch stream {
            case .success(let value):
                streamCredentials = value
            case .failure(let error):
                log.warning("The credentials of the stream addresses of \(camera.name) could not be read (\(error)); connecting without them")
                streamCredentials = .none
            }
            let runtime = CameraRuntime(configuration: camera, credentials: secrets, streamCredentials: streamCredentials,
                                        dependencies: runtimeDependencies())
            runtimes[camera.id] = runtime
            await nvr.attach(camera, hub: runtime.hub)   // the recorder subscribes to the main stream's hub; samples arrive once the ingest runs
            started.append((camera, runtime, reservedPorts(excluding: camera.id)))
            scheduleSecurityCheck(camera.id, after: tuning.securityCheckDelay, skipIfFresh: true)
        }
        if !started.isEmpty { statusInputsChanged() }
        let results = await withTaskGroup(of: (UUID, Result<UInt16, any Error>).self) { group in
            for (camera, runtime, reserved) in started {
                let publishing = mayPublish(camera.id)   // a camera outside the allowlist runs for the app's own viewers only
                group.addTask {
                    do {
                        return (camera.id, .success(try await runtime.start(port: camera.hapPort, reserved: reserved, publishing: publishing)))
                    } catch {
                        return (camera.id, .failure(error))
                    }
                }
            }
            var results: [(UUID, Result<UInt16, any Error>)] = []
            for await result in group { results.append(result) }
            return results
        }
        var moved = false
        for (id, result) in results {
            guard let index = configurations.firstIndex(where: { $0.id == id }) else { continue }
            switch result {
            case .success(let port):
                accessoryBackoffs[id] = nil
                if port != configurations[index].hapPort, port != 0 {
                    log.notice("\(configurations[index].name) listens on HAP port \(port) (\(configurations[index].hapPort) was taken)")
                    configurations[index].hapPort = port
                    moved = true
                }
            case .failure(let error):
                guard let runtime = started.first(where: { $0.0.id == id })?.1, runtimes[id] === runtime else { continue }
                if error is CameraRuntime.AccessoryStartFailure, await runtime.isRunning {
                    // The camera itself runs (stream, events, the app's viewers); only its accessory is tried again, with backoff.
                    let reason = (error as? CameraRuntime.AccessoryStartFailure)?.underlying ?? error
                    let delay = scheduleAccessoryRetry(id)
                    log.error("The HomeKit accessory of \(configurations[index].name) could not start: \(reason); trying again in \(MediaFit.seconds(delay)) s")
                    await router.setStreamConnection(.offline("the Apple Home accessory could not start (\(Self.readableReason(reason)))"), for: id)
                    continue
                }
                runtimes[id] = nil
                await nvr.detach(id)
                statusInputsChanged()
                let delay = scheduleAccessoryRetry(id)
                log.error("The HomeKit accessory of \(configurations[index].name) could not start: \(error); trying again in \(MediaFit.seconds(delay)) s")
                await router.setStreamConnection(.offline("the Apple Home accessory could not start (\(Self.readableReason(error)))"), for: id)
            }
        }
        if moved { await persist() }
        for (camera, runtime, _) in started where runtimes[camera.id] === runtime { await startSkyIfWanted(camera.id) }
    }

    /// Tries the camera's accessory again after its backoff; returns the delay.
    private func scheduleAccessoryRetry(_ cameraID: UUID) -> Duration {
        var backoff = accessoryBackoffs[cameraID] ?? Backoff(initial: tuning.ingest.initialBackoff, maximum: tuning.ingest.maximumBackoff)
        let delay = backoff.next()
        accessoryBackoffs[cameraID] = backoff
        accessoryRetries[cameraID]?.cancel()
        accessoryRetries[cameraID] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.retryAccessory(cameraID)
        }
        return delay
    }

    /// The next try of a camera whose accessory could not start (in turn with the other operations).
    private func retryAccessory(_ cameraID: UUID) async {
        _ = await operations.withLockUnlessCancelled {
            accessoryRetries[cameraID] = nil   // this try (never cancelled by the start it makes)
            guard isActive, let camera = configurations.first(where: { $0.id == cameraID }), camera.isEnabled else {
                accessoryBackoffs[cameraID] = nil
                return
            }
            if let runtime = runtimes[cameraID] {
                // The camera runs, only its accessory is down: bring the accessory up on it.
                guard mayPublish(cameraID), await !runtime.isPublished else {
                    accessoryBackoffs[cameraID] = nil
                    return
                }
                log.info("Starting the HomeKit accessory of \(camera.name) again")
                await publishRuntimes([camera], cause: "retry after it could not start")
                await bridge?.update(cameras: bridgedConfigurations)
                await refreshStatus()
                return
            }
            log.info("Starting the HomeKit accessory of \(camera.name) again")
            await startRuntimes([camera])
            await refreshStatus()
        }
    }

    /// Drops the pending tries of `cameraID`'s accessory (nil: every camera's).
    private func cancelAccessoryRetries(_ cameraID: UUID? = nil) {
        if let cameraID {
            accessoryRetries.removeValue(forKey: cameraID)?.cancel()
            accessoryBackoffs[cameraID] = nil
        } else {
            accessoryRetries.values.forEach { $0.cancel() }
            accessoryRetries.removeAll()
            accessoryBackoffs.removeAll()
        }
    }

    /// `limit`: wait at most this long for the runtime to stop (a runtime that does not answer may never).
    func stopRuntime(_ cameraID: UUID, within limit: Duration? = nil) async {
        cancelAccessoryRetries(cameraID)
        await nvr.detach(cameraID)   // before the runtime stops: the recorder flushes its group and closes the file
        if let off = offAccessories.removeValue(forKey: cameraID) { await off.stop(); invalidateStoredIdentity(cameraID) }
        guard let runtime = runtimes.removeValue(forKey: cameraID) else { return }
        if let limit {
            _ = try? await withDeadline(limit, followsCancellation: false) { await runtime.stop() }
        } else {
            await runtime.stop()
        }
        invalidateStoredIdentity(cameraID)
    }

    private func runtimeDependencies() -> CameraRuntime.Dependencies {
        let changes = changes
        return CameraRuntime.Dependencies(environment: environment, router: router, registry: registry, tuning: tuning,
                                          motionShadowTest: storedSettings.motionShadowTest,
                                          onChange: { changes.notify() },
                                          onLocalNetwork: { [weak self] access in
                                              Task { @MainActor in self?.noteLocalNetwork(access) }
                                          },
                                          onNetworkNotice: { [weak self] notice in
                                              Task { @MainActor in self?.recordNetworkNotice(notice) }
                                          },
                                          go2rtc: go2rtc)
    }

    /// Runs only while at least one camera is configured, so a bridge without cameras publishes nothing on the LAN.
    private func startSensorsBridge() async {
        guard bridge == nil, !configurations.isEmpty else { return }
        let settings = storedSettings
        let environment = environment
        let cameras = bridgedConfigurations
        let reserved = reservedPorts(excluding: nil).subtracting([settings.sensorsBridgePort])
        do {
            let (port, bridge) = try await PortAllocator.bind(from: settings.sensorsBridgePort, avoiding: reserved) { @Sendable port in
                let bridge = SensorsBridge(environment: environment, port: port)
                await bridge.update(cameras: cameras)
                try await bridge.start()
                return bridge
            }
            self.bridge = bridge
            statusInputsChanged()
            if port != settings.sensorsBridgePort, settings.sensorsBridgePort != 0 {
                log.notice("The sensors bridge listens on port \(port) (\(settings.sensorsBridgePort) was taken)")
                storedSettings.sensorsBridgePort = port
                await persist()
            }
            bridgeFollow = await bridge.follow(router: router)   // subscribes before it catches up
            sensorsBridge = try? await bridge.status()
        } catch {
            log.error("The sensors bridge could not start: \(error)")
        }
    }

    private func stopSensorsBridge() async {
        bridgeFollow?.cancel()
        bridgeFollow = nil
        guard let bridge else { return }
        self.bridge = nil
        statusInputsChanged()
        await bridge.stop()
    }

    /// How long a webhook start retries a port that is in use: a listener closed just before (the old webhook, or the
    /// check while paused) lets its port go asynchronously.
    static let webhookListenRetry: Duration = .seconds(1)

    /// Starts the webhook `settings` describe (nothing when it is off); throws when it cannot listen.
    private func startWebhook(_ settings: BridgeSettings) async throws {
        guard settings.webhookEnabled, webhook == nil else { return }
        let server = try await Self.listeningWebhook(settings, environment: environment, router: router)
        webhook = server
        webhookTask = router.consumeWebhook(server.events)
        webhookStateTask = watchWebhook(server, port: settings.webhookPort)
    }

    /// A webhook whose listener stopped on its own (sleep/wake, an interface change) and cannot listen again (another
    /// app took its port meanwhile) is published as `webhookProblem` while it retries; the problem clears once it
    /// listens again.
    private func watchWebhook(_ server: WebhookServer, port: UInt16) -> Task<Void, Never> {
        let states = server.listenerStates
        return Task { [weak self] in
            for await state in states {
                guard let self, self.webhook === server else { return }
                switch state {
                case .listening:
                    if self.webhookProblem != nil {
                        self.log.notice("The webhook listens on port \(port) again")
                        self.webhookProblem = nil
                    }
                case .relistenFailed(let error):
                    let problem = Self.webhookProblemText(port, error)
                    if self.webhookProblem != problem {
                        self.log.error("The webhook stopped listening and cannot listen on port \(port) again: \(Self.readableReason(error))")
                        self.webhookProblem = problem
                    }
                case .stopped:
                    return
                }
            }
        }
    }

    /// `webhookProblem`'s text for a webhook that cannot listen on `port`.
    nonisolated static func webhookProblemText(_ port: UInt16, _ error: any Error) -> String {
        "The webhook cannot listen on port \(port) (\(readableReason(error)))."
    }

    /// `EngineState.failed`'s reason when the configuration could not be loaded: a sentence the app shows as it is (the
    /// raw error goes to the log).
    nonisolated static func startFailure(_ error: any Error) -> String {
        switch error {
        case ConfigurationStoreError.unsupportedSchemaVersion:
            "The configuration was saved by a newer version of Camera Bridge. Update Camera Bridge to use it."
        case ConfigurationStoreError.corrupt:
            "The configuration file is damaged."
        default:
            EngineError.configurationUnavailable(readableReason(error)).description
        }
    }

    /// The one wording of an error for the screen: a reason phrase ("the connection timed out") that engine state strings
    /// embed (`EngineState.failed`, a camera's offline reason, `webhookProblem`) and the app turns into a sentence for its
    /// alerts and sheets, adding what to do. Words, never a Swift case name, an NSError dump or the platform's text
    /// (`TransportError.failed` carries POSIX and URLError codes: those go to the log), and redacted like the log.
    /// `IngestSupervisor.describe` uses it too, for every error that isn't the stream's own.
    public nonisolated static func readableReason(_ error: any Error) -> String {
        switch error {
        case let store as ConfigurationStoreError:
            switch store {
            case .unsupportedSchemaVersion: return "the configuration was saved by a newer version of Camera Bridge"
            case .corrupt: return "the configuration file is damaged"
            }
        case let ports as PortAllocationError:
            switch ports {
            case .noFreePort(let start): return "no free network port was found from port \(start) upward"
            }
        case is CameraOfflineError:
            return "the camera isn’t answering right now; Camera Bridge keeps checking and uses it again as soon as it does"
        case let transport as TransportError:
            switch transport {
            case .addressInUse: return "another app uses the port"
            case .localNetworkDenied: return "Local Network access is denied"
            case .connectionRefused: return "the connection was refused"
            case .timedOut: return "the connection timed out"
            case .closed: return "the connection closed unexpectedly"
            case .failed: return "a network error occurred"   // its text is the platform's (POSIX and URLError codes): the log has it
            }
        case let rtsp as RTSPError:
            switch rtsp {
            case .unauthorized: return "the camera rejected the user name or password for its video stream"
            case .notFound: return "the camera has no video stream at this address"
            case .badStatus(let status): return "the camera’s video stream answered with an error (RTSP \(status))"
            case .protocolError: return "the camera’s video stream couldn’t be read"
            case .timeout: return "the camera’s video stream didn’t answer in time"
            case .noVideoTrack: return "the camera’s stream has no video"
            case .unsupportedCodec(let codec): return "the camera’s stream uses \(Redact.string(codec)), which Camera Bridge can’t use"
            }
        case let adapter as CameraAdapterError:
            switch adapter {
            case .unauthorized: return "the camera rejected the user name or password"
            case .httpStatus(let status): return "the camera answered with an error (HTTP \(status))"
            case .invalidResponse: return "the camera sent an answer Camera Bridge couldn’t read"
            case .soapFault(let reason): return "the camera’s ONVIF service reported an error: \(Redact.string(reason))"
            case .apiError(let command, let code): return "the camera’s Reolink interface reported error \(code) for \(Redact.string(command))"
            case .unsupported(let reason): return Redact.string(reason)
            // The times are the bridge's (`BridgeTime`: its settings' zone), not the process's (UTC on the box).
            case .lockedOut(let until):
                return "the camera locked its logins after too many wrong passwords; Camera Bridge waits until \(BridgeTime.clock(until)) "
                    + "before it tries again"
            case .loginsPaused(let until):
                return "the camera refused the username or password Camera Bridge has, so Camera Bridge waits until \(BridgeTime.clock(until)) "
                    + "before it logs in again, so the camera doesn’t lock the account"
            // The camera signed the account in, then refused it a change: no password to check, an administrator account to use.
            case .notPermitted: return CameraAdapterError.notPermittedReason
            }
        case let config as CameraConfigError:
            return "the camera wouldn’t change its video settings (\(Redact.string(config.summary)))"
        case is HTTPClientError:
            return "the camera’s answer wasn’t a web page Camera Bridge could read"
        case is CredentialStoreError:
            return "a saved password couldn’t be read"
        case is CancellationError:
            return "the operation was cancelled"
        case let engine as EngineError:
            return Redact.string(engine.description)
        default:
            if let localized = error as? any LocalizedError, let description = localized.errorDescription {
                return Redact.string(description)
            }
            // A plain Swift error bridges to an NSError named after its type; its text would be the case name.
            let bridged = error as NSError
            guard bridged.domain != String(reflecting: type(of: error)) else { return "an unexpected error (the log has the details)" }
            return Redact.string(bridged.localizedDescription)
        }
    }

    /// Starts the webhook `settings` describe and publishes `webhookProblem` when it cannot listen (start, resume, Try
    /// Again, rollbacks).
    private func startWebhookReporting(_ settings: BridgeSettings) async {
        do {
            try await startWebhook(settings)
            webhookProblem = nil
        } catch {
            log.error("The webhook could not listen on port \(settings.webhookPort): \(error)")
            webhookProblem = Self.webhookProblemText(settings.webhookPort, error)
        }
    }

    /// Paused or stopped: binds the webhook's port once and lets it go, so a webhook that could not listen is refused now
    /// rather than found out at the next start.
    private func checkWebhookCanListen(_ settings: BridgeSettings) async throws {
        let server = try await Self.listeningWebhook(settings, environment: environment, router: router)
        await server.stop()
    }

    /// A started `WebhookServer` for `settings`, retrying a port in use for `webhookListenRetry`. It asks `router` about
    /// each event's camera: 404 for an ID no configured camera has, 409 for a disabled camera (the router would drop both).
    private static func listeningWebhook(_ settings: BridgeSettings, environment: BridgeEnvironment, router: EventRouter) async throws -> WebhookServer {
        let deadline = ContinuousClock.now + webhookListenRetry
        while true {
            let server = WebhookServer(port: settings.webhookPort, token: settings.webhookToken, loopbackOnly: environment.loopbackOnly,
                                       transport: environment.platform.transport) { [weak router] cameraID in
                await router?.webhookCameraState(cameraID) ?? .unknown
            }
            do {
                try await server.start()
                return server
            } catch let error as TransportError where error == .addressInUse && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// `readableReason` words the error (one mapping for every engine string the app shows).
    nonisolated static func webhookCannotListen(_ port: UInt16, _ error: any Error) -> EngineError {
        .invalidSettings("the webhook cannot listen on port \(port) (\(readableReason(error)))")
    }

    /// Settings' Try Again for `webhookProblem`: starts the enabled webhook again while the bridge runs (a webhook that
    /// is still trying to listen again is replaced by a fresh start).
    public func retryWebhook() async {
        guard !isPreview else { return }
        await operations.withLock {
            guard isActive, storedSettings.webhookEnabled else { return }
            if webhook != nil, webhookProblem != nil { await stopWebhook() }
            guard webhook == nil else { return }
            await startWebhookReporting(storedSettings)
        }
    }

    private func stopWebhook() async {
        webhookTask?.cancel()
        webhookTask = nil
        webhookStateTask?.cancel()
        webhookStateTask = nil
        guard let webhook else { return }
        self.webhook = nil
        await webhook.stop()
    }

    /// How long the network must stay unchanged (and no further wake come) before the cameras reconnect.
    nonisolated static let networkSettle: Duration = .seconds(2)

    private func startNetworkMonitoring() {
        guard networkTask == nil else { return }
        let changes = environment.platform.networkChanges.changes
        networkTask = Task { [weak self] in
            for await _ in changes { self?.scheduleReconnect(woke: false) }
        }
    }

    /// Interfaces change in bursts (one Wi-Fi rejoin reports several paths), and a wake brings one of its own (the Mac
    /// rejoins its network): the cameras reconnect once, `networkSettle` after the last wake or change of a burst (a
    /// trailing-edge debounce), whatever their order. Every reconnect drops healthy streams, marks streaming unavailable
    /// and restarts event channels, so a burst must not cause two. A wake or change that comes while a reconnect is under
    /// way schedules another one; a reconnect that began is never cancelled by a later one.
    ///
    /// A burst that keeps flapping (a VPN reconnecting every few seconds, a Wi-Fi that comes and goes) would postpone the
    /// reconnect for as long as it lasts, with the cameras unreachable in Home meanwhile: the reconnect starts at the latest
    /// `networkSettleCap` after the burst's first change.
    private func scheduleReconnect(woke: Bool) {
        lastMacVPNCheck = nil   // a VPN connecting or dropping is a network change: look at once
        var cause = (woke: woke, networkChanged: !woke)
        var since = ContinuousClock.now
        if let pending = pendingReconnect, pending.start.cancel() {
            pending.task.cancel()
            cause = (cause.woke || pending.woke, cause.networkChanged || pending.networkChanged)
            since = pending.since
        }
        let start = PendingStart()
        let settle = min(tuning.networkSettle, max(.zero, tuning.networkSettleCap - (ContinuousClock.now - since)))
        let task = Task { [weak self, cause] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled, start.begin() else { return }
            await self?.reconnect(woke: cause.woke, networkChanged: cause.networkChanged)
        }
        pendingReconnect = (task, start, cause.woke, cause.networkChanged, since)
    }

    private func reconnect(woke: Bool, networkChanged: Bool) async {
        await operations.withLock {
            guard isActive else { return }
            let what = woke ? (networkChanged ? "The Mac woke up and the network changed" : "The Mac woke up") : "The network changed"
            log.info("\(what); reconnecting cameras")
            await refreshConnections(woke: woke)
        }
    }

    /// Reconnects every running camera and re-advertises the sensors bridge; accessories that could not start (a camera's,
    /// the sensors bridge's) are tried again at once. Each camera's reconnect has `runtimeRefreshDeadline`: one that hangs is
    /// left behind (logged) instead of holding the engine's operations for every other camera, and their Bonjour records are
    /// registered `advertisingStagger` apart.
    private func refreshConnections(woke: Bool) async {
        // The sensors bridge's accessory first: it is one listener and one record, and it should not wait behind a camera that
        // is slow to answer.
        await bridge?.server.relistenNow()
        await bridge?.server.restartAdvertising()
        let running = Array(runtimes.values)
        let (deadline, stagger, log) = (tuning.runtimeRefreshDeadline, tuning.advertisingStagger, log)
        await withTaskGroup(of: Void.self) { group in
            for (index, runtime) in running.enumerated() {
                let delay = stagger * index
                group.addTask {
                    do {
                        try await withDeadline(deadline + delay, followsCancellation: false) { await runtime.refresh(woke: woke, advertiseAfter: delay) }
                    } catch {
                        log.error("Reconnecting \(runtime.configuration.name) took longer than \(MediaFit.seconds(deadline + delay)) s; moving on without it")
                    }
                }
            }
        }
        let waiting = configurations.filter { accessoryRetries[$0.id] != nil && $0.isEnabled }
        let toStart = waiting.filter { runtimes[$0.id] == nil }
        let toPublish = waiting.filter { runtimes[$0.id] != nil }
        if !toStart.isEmpty || !toPublish.isEmpty {
            log.info("Starting the HomeKit accessories that could not start again")
            if !toStart.isEmpty { await startRuntimes(toStart) }
            if !toPublish.isEmpty { await publishRuntimes(toPublish, cause: "the network changed") }
        }
        if bridge == nil {
            await startSensorsBridge()   // it could not start (nothing when no camera is configured)
        }
    }

    /// A Mac that sleeps cannot answer Home: say so in the log at every start while Keep Mac Awake is off (a laptop's lid or the
    /// battery puts it to sleep whatever the assertion says).
    private func noteSleepRisk() {
        guard !storedSettings.keepMacAwake else { return }
        let laptop = environment.platform.power.hasBattery
        log.notice("Keep Mac Awake is off: while this Mac sleeps, Apple Home shows the cameras as not responding"
                   + (laptop ? " (a laptop also sleeps when its lid is closed, which only a display attached with power prevents)." : "."))
    }

    // MARK: - Removed cameras' Apple Home pairings

    /// At the start and then daily (`EngineTuning.removedPairingSweepInterval`): removed cameras' Apple Home pairings kept 30 days or longer
    /// are deleted (`RemovedHAPIdentities.sweep`).
    private func startRemovedPairingSweep() {
        guard removedPairingSweepTask == nil else { return }
        let interval = tuning.removedPairingSweepInterval, credentials = credentials, dataDirectory = environment.dataDirectory, log = log
        removedPairingSweepTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let deleted = credentials.sweepRemovedHomePairings(dataDirectory: dataDirectory)
                if deleted > 0 { log.info("Deleted the Apple Home pairing\(deleted == 1 ? "" : "s") of \(deleted) camera\(deleted == 1 ? "" : "s") removed 30 days ago") }
                try? await Task.sleep(for: interval)
            }
        }
    }

    // MARK: - Heartbeat

    /// Every `runtimeHeartbeatInterval` each running camera is asked to answer within `runtimeHeartbeatDeadline`. A runtime
    /// (or the accessory server behind it) that misses `runtimeHeartbeatStrikes` heartbeats in a row is restarted, that camera
    /// only: Home would show it as not responding for as long as it hangs, with nothing else to say why.
    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        let interval = tuning.runtimeHeartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.heartbeatRound()
            }
        }
    }

    /// One round of heartbeats (internal: tests call it directly).
    func heartbeatRound() async {
        guard isActive else { return }
        let deadline = tuning.runtimeHeartbeatDeadline
        let results = await withTaskGroup(of: (UUID, Bool).self) { group in
            for (id, runtime) in runtimes {
                group.addTask {
                    do {
                        _ = try await withDeadline(deadline, followsCancellation: false) { await runtime.heartbeat() }
                        return (id, true)
                    } catch {
                        return (id, false)
                    }
                }
            }
            var results: [(UUID, Bool)] = []
            for await result in group { results.append(result) }
            return results
        }
        var unresponsive: [UUID] = []
        for (id, answered) in results {
            guard runtimes[id] != nil else { continue }
            if answered {
                heartbeatStrikes[id] = nil
                continue
            }
            let strikes = (heartbeatStrikes[id] ?? 0) + 1
            heartbeatStrikes[id] = strikes
            let name = configurations.first { $0.id == id }?.name ?? "A camera"
            log.warning("\(name) did not answer within \(MediaFit.seconds(deadline)) s (\(strikes) of \(tuning.runtimeHeartbeatStrikes))")
            if strikes >= tuning.runtimeHeartbeatStrikes { unresponsive.append(id) }
        }
        for id in unresponsive { await restartUnresponsiveRuntime(id) }
    }

    private func restartUnresponsiveRuntime(_ cameraID: UUID) async {
        await operations.withLock {
            guard isActive, let runtime = runtimes[cameraID], heartbeatStrikes[cameraID] ?? 0 >= tuning.runtimeHeartbeatStrikes,
                  let camera = configurations.first(where: { $0.id == cameraID }), camera.isEnabled else { return }
            heartbeatStrikes[cameraID] = nil
            log.error("\(camera.name) did not answer \(tuning.runtimeHeartbeatStrikes) heartbeats in a row; restarting that camera")
            // The stop is bounded: a runtime that does not answer may never finish stopping.
            await stopRuntime(cameraID, within: .seconds(5))
            _ = runtime
            await startRuntimes([camera])
            await bridge?.update(cameras: bridgedConfigurations)
            await refreshStatus()
        }
    }

    // MARK: - Status

    private func startStatusLoop() {
        guard statusTask == nil else { return }
        let interval = tuning.statusInterval
        let changes = changes
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus(publishingLogs: false)   // the log loop publishes the log, at the same rate
                try? await Task.sleep(for: interval)
                await changes.wait(timeout: .seconds(2))
            }
        }
    }

    /// Publishes what the log sink buffered (`recentLogs`) for as long as it is installed (from the first start until
    /// `stop()`), at most at the status rate: also while the bridge is paused or could not start, when the status loop
    /// does not run — the messages people see then ("The log in Settings has the details", a failed start) send them to
    /// the log.
    private func startLogLoop() {
        guard logTask == nil else { return }
        let logged = logs.logged
        let interval = tuning.statusInterval
        logTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }   // never kept alive by this loop
                self?.drainLogs()
                try? await Task.sleep(for: interval)
                await logged.wait(timeout: .seconds(2))
            }
        }
    }

    /// Rebuilds `cameras`, `sensorsBridge` and `recentLogs` (only assigned when they changed). What it read before an
    /// operation changed the cameras, runtimes, sensors bridge or state (`statusGeneration`) is not published: the
    /// status loop runs outside the operations, and a removed camera's row or a stopped bridge's code would come back.
    /// The status loop's refreshes leave `recentLogs` to the log loop (`publishingLogs` false): both loops publishing it, out of
    /// step (a refresh that takes a while), published it up to twice per `statusInterval`. An operation's refresh publishes it
    /// at once, with the operation's outcome.
    func refreshStatus(publishingLogs: Bool = true) async {
        let generation = statusGeneration
        defer { if publishingLogs { drainLogs() } }
        await refreshNetworkNotices()
        var statuses: [CameraStatus] = []
        for camera in configurations {
            var status = CameraStatus(id: camera.id, name: camera.name, kind: camera.kind, vendor: camera.vendor)
            status.nvr = nvr.status(for: camera, folderChosen: storedSettings.nvrFolder != nil)
            status.security = securityChecks.records[camera.id]?.security
            status.sky = await skyCameraStatus(camera)
            if let sensor = await router.state(for: camera.id) { sensor.apply(to: &status) }
            if let runtime = runtimes[camera.id] {
                let runtimeStatus = await runtime.status()
                status.videoSummary = runtimeStatus.videoSummary
                status.isPaired = runtimeStatus.isPaired
                status.setupCode = runtimeStatus.setupCode
                status.setupURI = runtimeStatus.setupURI
                status.hapPort = runtimeStatus.hapPort
                status.recordingEnabled = runtimeStatus.recordingEnabled
                status.recordingNow = runtimeStatus.recordingNow
                status.liveViewers = runtimeStatus.liveViewers
                status.appViewers = runtimeStatus.appViewers
                status.panTilt = runtimeStatus.panTilt
                status.zoom = runtimeStatus.zoom
                status.nightVision = runtimeStatus.nightVision
                status.battery = runtimeStatus.battery
                status.subStreamProblem = runtimeStatus.subStreamProblem
                status.liveSessions = runtimeStatus.liveSessions
                status.recordingSession = runtimeStatus.recordingSession
                status.mainStreamInfo = runtimeStatus.mainStreamInfo
                status.subStreamInfo = runtimeStatus.subStreamInfo
                status.eventsNote = runtimeStatus.eventsNote
                status.homeKitNote = runtimeStatus.homeKitNote
                status.motionShadow = runtimeStatus.motionShadow
                if !mayPublish(camera.id), let identity = await storedIdentity(for: camera) {
                    // Held back from HomeKit: no accessory runs, but the camera's code and pairing are the stored ones (Home
                    // shows it as not responding while it is paired).
                    status.setupCode = identity.code
                    status.setupURI = identity.uri
                    status.isPaired = identity.paired
                }
            } else {
                if let identity = await storedIdentity(for: camera) {
                    status.setupCode = identity.code
                    status.setupURI = identity.uri
                    status.isPaired = identity.paired
                }
                status.hapPort = await offAccessories[camera.id]?.hapPort
                if !camera.isEnabled {
                    status.connection = .disabled
                } else if !isActive, status.lastError == nil {
                    status.connection = .idle
                }
            }
            statuses.append(status)
        }
        var bridgeStatus: SensorsBridgeStatus?
        let bridge = bridge
        if let bridge {
            bridgeStatus = try? await bridge.status()
            await tuning.afterSensorsBridgeStatus?()
        }
        guard generation == statusGeneration else { return }   // an operation changed what was read: it refreshes again
        let storage = nvr.storageStatus()
        if storage != nvrStorage { nvrStorage = storage }
        if statuses != cameras { cameras = statuses }
        if let bridge, bridge === self.bridge, let bridgeStatus, bridgeStatus != sensorsBridge { sensorsBridge = bridgeStatus }
        noteGuardConnections(statuses)   // a camera back online has its DNS read again (BridgeEngine+InternetGuard.swift)
    }

    /// A live view's controller on a VPN (`NetworkNotice`), from a camera's streaming delegate: kept (and refreshed) per
    /// device.
    func recordNetworkNotice(_ notice: NetworkNotice) {
        var notice = notice
        if notice.cameraName == nil, let id = notice.cameraID { notice.cameraName = configurations.first { $0.id == id }?.name }
        let now = Date()
        if networkNoticeLog.record(notice, now: now) { publishNetworkNotices(now: now) }
    }

    /// Looks for this Mac's VPN (at most every `macVPNCheckInterval`, at once after a network change) and drops the notices
    /// that expired.
    private func refreshNetworkNotices() async {
        let now = Date()
        var changed = networkNoticeLog.prune(now: now)
        if !isPreview, lastMacVPNCheck.map({ ContinuousClock.now - $0 >= tuning.macVPNCheckInterval }) ?? true {
            lastMacVPNCheck = .now
            let probe = tuning.macVPNProbe
            let vpn = try? await Self.offMain { probe() }
            if let vpn {
                changed = networkNoticeLog.record(NetworkNotice(kind: .macOnVPN, interfaceName: vpn.interface, date: now), now: now) || changed
            } else {
                changed = networkNoticeLog.remove(.macOnVPN) || changed
            }
            if macVPN != vpn { macVPN = vpn }
        }
        if changed { publishNetworkNotices(now: now) }
    }

    private func publishNetworkNotices(now: Date) {
        let notices = networkNoticeLog.notices.filter { $0.isActive(at: now) }
        if notices != recentNetworkNotices { recentNetworkNotices = notices }
    }

    private func drainLogs() {
        let entries = logs.drain()
        if !entries.isEmpty {
            var combined = recentLogs + entries
            if combined.count > LogCollector.capacity { combined.removeFirst(combined.count - LogCollector.capacity) }
            recentLogs = combined
        }
    }

    /// An operation changed what `refreshStatus` reads.
    private func statusInputsChanged() {
        statusGeneration &+= 1
    }

    /// The setup code, URI and pairing of a camera that is not running, from its HAP store. A camera that will not run
    /// (disabled, or the bridge is paused or stopped) gets its identity created and stored the first time, exactly as
    /// the accessory server would (`HAPStore.loadOrCreateIdentity()`, which also removes pairings left behind by a lost
    /// identity). A camera that runs or is about to (an enabled camera of a running bridge) only reads it: its accessory
    /// server creates it. A camera removed meanwhile gets nothing (its identity was deleted for good), and a missing
    /// identity is not cached (the server creates it shortly).
    private func storedIdentity(for camera: CameraConfiguration) async -> StoredIdentity? {
        if let cached = storedIdentities[camera.id] { return cached }
        let store = HAPStorage.store(for: camera.id, dataDirectory: environment.dataDirectory, secrets: environment.platform.secrets)
        let category: AccessoryCategory = camera.kind == .doorbell ? .videoDoorbell : .ipCamera
        let generation = identityGeneration
        let mayCreate = !(isActive && camera.isEnabled && mayPublish(camera.id))   // a held-back camera's accessory never creates it
        let id = camera.id
        do {
            let (entry, discarded) = try await Self.offMain { [self] in
                try identityAccess.withLock { removed throws -> (StoredIdentity?, Int) in
                    guard !removed.contains(id) else { return (nil, 0) }
                    let identity: HAPIdentity?
                    var discarded = 0
                    if mayCreate {
                        let loaded = try store.loadOrCreateIdentity()
                        identity = loaded.identity
                        discarded = loaded.discardedPairings
                    } else {
                        identity = try store.loadIdentity()
                    }
                    guard let identity else { return (nil, 0) }
                    let paired = !((try? store.loadState())?.pairings.isEmpty ?? true)
                    let entry = StoredIdentity(code: identity.setupCode.formatted,
                                               uri: SetupPayload.uri(code: identity.setupCode, setupID: identity.setupID, category: category),
                                               paired: paired)
                    return (entry, discarded)
                }
            }
            if discarded > 0 {
                log.error("The HomeKit identity of \(camera.name) was missing (its Keychain item was lost or reset), so it got a new one "
                          + "and its pairings with the old one were removed. Remove \(camera.name) from the Home app and add it again "
                          + "with its setup code.")
            }
            guard let entry, configurations.contains(where: { $0.id == id }) else { return nil }
            if generation == identityGeneration { storedIdentities[camera.id] = entry }
            return entry
        } catch {
            log.warning("The HomeKit identity of \(camera.name) could not be read: \(error)")
            if generation == identityGeneration { storedIdentities[camera.id] = .some(nil) }
            return nil
        }
    }

    private func invalidateStoredIdentity(_ cameraID: UUID) {
        storedIdentities[cameraID] = nil
        identityGeneration &+= 1
        statusInputsChanged()
    }

    /// `work` for each element, off the main actor, in order.
    nonisolated static func offMainResults<Element: Sendable, T: Sendable>(_ elements: [Element], _ work: @escaping @Sendable (Element) throws -> T) async
        -> [Result<T, any Error>] {
        guard !elements.isEmpty else { return [] }
        return (try? await offMain { elements.map { element in Result { try work(element) } } }) ?? []
    }

    private func noteLocalNetwork(_ access: LocalNetworkAccess) {
        guard access != localNetworkAccess else { return }
        if access == .denied { log.warning("Local Network access is denied: allow Camera Bridge in System Settings › Privacy & Security › Local Network") }
        localNetworkAccess = access
    }

    // MARK: - Configuration helpers

    private func ensureLoaded() async throws {
        guard !loaded else { return }
        let store = store, credentials = credentials, log = log
        let (existed, loadedConfiguration) = try await Self.offMain {
            let existed = FileManager.default.fileExists(atPath: store.fileURL.path(percentEncoded: false))
            var (configuration, recovered) = try store.loadOrRecover()
            configuration.cameras = Self.movingStreamCredentials(of: configuration, to: credentials, store: store, log: log)
            return (existed, (configuration, recovered))
        }
        let (configuration, recovered) = loadedConfiguration
        guard !loaded else { return }
        storedSettings = configuration.settings
        Self.applyTimeZone(storedSettings.timeZone)
        Self.useBridgeTimeZone(storedSettings.timeZone)
        configurations = configuration.cameras
        loaded = true
        if !existed, !environment.platform.power.hasBattery {
            // A new install on a desktop Mac (no battery): keep it awake, so Home reaches the cameras at night too. Never applied
            // to a saved configuration, whatever it says (or does not say) about keeping the Mac awake.
            storedSettings.keepMacAwake = true
            log.notice("Keep Mac Awake is on for this new installation: this Mac has no battery, and a Mac that sleeps shows every "
                       + "camera as not responding in Apple Home. It can be turned off in Settings.")
        }
        if let recovered {
            log.error("The configuration was unreadable and was set aside as \(recovered.lastPathComponent); starting without cameras")
            configurationRecoveredFrom = recovered
        }
        if !existed || recovered != nil { await persist() }
    }

    /// Writes `configuration` to `config.json` off the main actor. The internet guard's list follows what was saved (a Watch done or
    /// restored, a camera removed or moved: `syncInternetGuard`).
    private func save(_ configuration: BridgeConfiguration) async throws {
        let store = store
        try await Self.offMain { try store.save(configuration) }
        syncInternetGuard(configuration.cameras)
    }

    /// `configuration`'s cameras with the credentials in their stream URLs moved to the secret store (`storeStreamCredentials`),
    /// saved that way when any moved: `config.json` of a build that kept them in the URL is rewritten when it is loaded. A camera whose
    /// credentials the secret store cannot take keeps its URLs as they are (it still connects) and is tried again at the next load; one
    /// whose move was stored but whose file could not be saved is kept without them (the next load finds them stored already). Logs
    /// name the camera, never a URL.
    nonisolated static func movingStreamCredentials(of configuration: BridgeConfiguration, to credentials: CredentialStore,
                                                    store: ConfigurationStore, log: Log) -> [CameraConfiguration] {
        var cameras = configuration.cameras
        var moved = false
        for index in cameras.indices
        where cameras[index].mainStreamURL?.hasStreamCredentials == true || cameras[index].subStreamURL?.hasStreamCredentials == true {
            let name = cameras[index].name
            do {
                cameras[index] = try credentials.storeStreamCredentials(of: cameras[index])
                moved = true
                log.notice("\(name): the credentials in its stream address are now kept in the secret store with its password; "
                           + "config.json has the address without them")
            } catch {
                log.warning("\(name): the credentials in its stream address could not be moved to the secret store (\(error)); "
                            + "they stay in config.json, and the next start tries again")
            }
        }
        guard moved else { return configuration.cameras }
        do {
            try store.save(BridgeConfiguration(settings: configuration.settings, cameras: cameras))
        } catch {
            log.error("The configuration without the stream address credentials could not be saved: \(error)")
        }
        return cameras
    }

    func persist() async {
        do {
            try await save(BridgeConfiguration(settings: storedSettings, cameras: configurations))
        } catch {
            log.error("Could not save the configuration: \(error)")
        }
    }

    /// Changes one camera's engine-owned fields in place (`setupBackup`, `setupState`, `cleanPictureBackup`) and saves. Nothing when the camera
    /// is gone. `configurations` keeps its private setter: this is the one way other files of the engine write a camera.
    func changeConfiguration(_ cameraID: UUID, _ change: (inout CameraConfiguration) -> Void) async {
        guard let index = configurations.firstIndex(where: { $0.id == cameraID }) else { return }
        change(&configurations[index])
        await persist()
    }

    /// Ports the HAP servers already listen on (kept by `resolvePorts`).
    private func listeningPorts() async -> Set<UInt16> {
        var ports: Set<UInt16> = []
        for runtime in runtimes.values {
            if let port = await runtime.hapPort { ports.insert(port) }
        }
        return ports
    }

    /// Ports a camera must not take: the sensors bridge's, the webhook's and every other camera's.
    private func reservedPorts(excluding cameraID: UUID?) -> Set<UInt16> {
        var ports = PortAllocator.reservedPorts(for: storedSettings)
        for camera in configurations where camera.id != cameraID && camera.hapPort != 0 { ports.insert(camera.hapPort) }
        ports.remove(0)
        return ports
    }

    /// The loaded configuration's zone for the clock times the bridge words for people and the zone it hands the box (`BridgeTime`). The
    /// process's own zone is left as it is at launch (the recorder names its folders in it; `applyTimeZone` runs when settings are saved).
    /// Without a zone the bridge already uses the process's.
    private static func useBridgeTimeZone(_ identifier: String?) {
        if let identifier { BridgeTime.use(identifier) }
    }

    /// Makes `identifier` the process's time zone (the timestamp overlay and the dates formatted in the process's zone follow it; ffmpeg
    /// children inherit `TZ`). nil leaves the system's. Clock times worded for people follow `BridgeTime` instead.
    static func applyTimeZone(_ identifier: String?) {
        guard let identifier, TimeZone(identifier: identifier) != nil else { return }
        setenv("TZ", identifier, 1)
        NSTimeZone.resetSystemTimeZone()
        if let zone = TimeZone(identifier: identifier) { NSTimeZone.default = zone }
    }

    /// Sets the camera's clock to the bridge's time zone (`BridgeSettings.timeZone`, else the system's), so the date and time the camera draws on its
    /// picture is local. Returns the POSIX zone it was given; throws `EngineError` for an unknown camera or a zone the system cannot describe, and
    /// `EngineError.invalidSettings` with the camera's answer when it refused.
    public func setCameraTimeZone(cameraID: UUID) async throws -> String {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        guard let camera = configurations.first(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
        let identifier = storedSettings.timeZone ?? TimeZone.current.identifier
        guard let posix = PosixTimeZone.string(for: identifier) else {
            throw EngineError.invalidSettings("this system has no description of the time zone \(identifier)")
        }
        let credentials = credentials
        let secrets = try await Self.offMain { try credentials.credentials(for: camera) }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: secrets, cameraID: cameraID, vendor: camera.vendor,
                                            mainStreamURL: camera.mainStreamURL, preferredMethod: camera.preferredConfigMethod)
        if let failure = try await service.setCameraTimeZone(posix: posix) {
            throw EngineError.invalidSettings("the camera did not take the time zone: \(failure)")
        }
        log.info("\(camera.name): the camera's clock is in \(identifier) now (\(posix))")
        return posix
    }

    private static func validate(_ settings: BridgeSettings) throws {
        if settings.webhookPort != 0, settings.webhookPort == settings.sensorsBridgePort {
            throw EngineError.invalidSettings("the webhook and the sensors bridge need different ports")
        }
        if let zone = settings.timeZone, TimeZone(identifier: zone) == nil {
            throw EngineError.invalidSettings("\(zone) is not a time zone")
        }
        if settings.webhookEnabled, settings.webhookToken.count < 16 {
            throw EngineError.invalidSettings("the webhook token must have at least 16 characters")
        }
        let days = BridgeSettings.nvrKeepDaysRange, size = BridgeSettings.nvrMaxSizeGBRange
        if !days.contains(settings.nvrKeepDays) {
            throw EngineError.invalidSettings("recordings are kept for \(days.lowerBound) to \(days.upperBound) days")
        }
        if !size.contains(settings.nvrMaxSizeGB) {
            throw EngineError.invalidSettings("the recordings limit is \(size.lowerBound) to \(size.upperBound) GB")
        }
        if let folder = settings.nvrFolder, !BridgeSettings.isValidNVRFolder(folder) {
            throw EngineError.invalidSettings("the recordings folder must be a full path")
        }
        if let problem = settings.ai.validationProblem {
            throw EngineError.invalidSettings(problem.message)
        }
        if let problem = settings.sky.validationProblem {
            throw EngineError.invalidSettings(problem.message)
        }
    }

    /// A delayed piece of work that either begins or is cancelled, never both (`begin()` / `cancel()` race safely).
    private final class PendingStart: Sendable {
        private enum Phase { case waiting, begun, cancelled }
        private let phase = Mutex(Phase.waiting)

        /// Begins unless cancelled first.
        func begin() -> Bool {
            phase.withLock { phase in
                guard phase == .waiting else { return false }
                phase = .begun
                return true
            }
        }

        /// Cancels unless it began first.
        func cancel() -> Bool {
            phase.withLock { phase in
                guard phase == .waiting else { return false }
                phase = .cancelled
                return true
            }
        }
    }

    /// Whether a configuration change needs the camera's runtime restarted. The sensors and the motion hold do not
    /// (router and sensors bridge), soft motion's sensitivity, the timestamp overlay's look and the picture correction are
    /// applied in place, and a paired camera's name does not either (Home keeps its own; the accessory takes the new one at
    /// its next start). The camera detail form sends every pause in typing or dragging: each restart would cut live views and
    /// HKSV recordings and close the camera's NVR file.
    static func needsRestart(_ old: CameraConfiguration, _ new: CameraConfiguration, paired: Bool) -> Bool {
        var comparable = new
        comparable.sensors = old.sensors
        comparable.motionHoldSeconds = old.motionHoldSeconds
        comparable.motionSensitivity = old.motionSensitivity
        // The overlay's look is applied in place; turning it on or off changes the video path (passthrough or transcode).
        if comparable.timestampOverlay.enabled == old.timestampOverlay.enabled { comparable.timestampOverlay = old.timestampOverlay }
        // Applied in place (`updatePictureCorrection`): a restart would close the camera's NVR file.
        comparable.pictureCorrection = old.pictureCorrection
        comparable.hiddenCameraClock = old.hiddenCameraClock
        comparable.cleanPictureBackup = old.cleanPictureBackup
        comparable.setupBackup = old.setupBackup
        comparable.setupState = old.setupState
        comparable.dnsWatch = old.dnsWatch
        comparable.nvrEnabled = old.nvrEnabled               // Record and Record sound are applied in place (`setNVR`): never a restart
        comparable.nvrRecordSound = old.nvrRecordSound
        comparable.aiDescriptions = old.aiDescriptions       // the describer reads the switch when an event starts: never a restart
        comparable.skyDetector = old.skyDetector             // the Sky Watcher takes its settings in place: never a restart
        if paired { comparable.name = old.name }
        return comparable != old
    }
}

/// `BridgeEngine.portAnswer(host:port:timeout:)`.
public enum PortAnswer: String, Sendable {
    case answers, refused, silent
}
