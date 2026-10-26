import BridgeSupport
import CameraAdapters
import Foundation
import HAP
import HAPCamera

/// Knobs of the engine and its runtimes; tests shorten or shrink them.
struct EngineTuning: Sendable {
    typealias DriverFactory = @Sendable (_ camera: CameraConfiguration, _ credentials: HTTPCredentials?, _ transport: any NetworkTransport) -> any CameraDriver

    var demoMain = DemoStream(width: 1920, height: 1080, fps: 30, keyframeInterval: .seconds(2))
    var demoSub = DemoStream(width: 640, height: 360, fps: 15, keyframeInterval: .seconds(2))
    /// How long a camera seen for the first time (no remembered picture size) waits for its first picture before its
    /// accessory is published (to learn the aspect ratio and the live sizes).
    var aspectWait: Duration = .seconds(5)
    var ingest = IngestSupervisor.Timing()
    var recording = RecordingTiming()
    var controller = CameraControllerTimings.standard
    var snapshots = SnapshotProvider.Timing()
    /// How a camera that stops answering is probed and when it counts as offline (`CameraReachability`).
    var reachability = CameraReachability.Timing()
    /// After ONVIF refused a camera's credentials the camera page does not ask again for this long (every ask is another
    /// failed login, and cameras lock the account after a few).
    var onvifRefusalMemory: Duration = .seconds(600)
    /// Live sessions end after this long without controller RTCP (research brief §3.6).
    var liveControllerTimeout: Duration = .seconds(30)
    /// The live pipeline's health ladder, failure ladders and camera keyframe spacing (`LiveStreamTiming`; tests shorten them).
    var liveStreamTiming = LiveStreamTiming.standard
    /// An unused sub stream disconnects after this long.
    var subStreamIdleStop: Duration = .seconds(10)
    /// A camera that streams on demand (`CameraDriver.streamsOnDemand`, a battery camera) disconnects after this long unused.
    var onDemandIdleStop: Duration = .seconds(15)
    /// How long a live view, recording or motion event waits for an on-demand camera to wake and send its first picture.
    var onDemandWakeWait: Duration = .seconds(25)
    /// How often a camera whose driver reports a battery (`CameraDriver.batteryStatus`) is asked for it.
    var batteryPollInterval: Duration = BatteryStatus.pollInterval
    /// A live view waits this long for the sub stream's first picture before using the main stream.
    var subStreamStartWait: Duration = .seconds(3)
    /// Status is aggregated at most this often (contract: ≤ 4 Hz).
    var statusInterval: Duration = .milliseconds(250)
    /// Soft motion uses the main stream while the sub stream has had no picture for this long.
    var softMotionSubStreamWait: Duration = .seconds(10)
    /// Called (tests) right before a starting runtime connects its accessory to the event router (registers its
    /// controller and applies the camera's current state).
    var beforeControllerRegistration: (@Sendable (_ cameraID: UUID) async -> Void)?
    /// Called (tests) by a status refresh after it read the sensors bridge's status, before it publishes anything.
    var afterSensorsBridgeStatus: (@Sendable () async -> Void)?
    /// Replaces `CameraDrivers.make` (tests).
    var driverFactory: DriverFactory?
    /// Replaces the engine's go2rtc helper manager (tests: a fake that serves a local RTSP source).
    var go2rtc: (any Go2RTCStreamProviding)?
    /// Replaces the Sky Watcher's downloads (`URLSessionSkyHTTP`: the flight feed) (tests: a fake feed, so nothing leaves the machine).
    var skyHTTP: (any SkyHTTP)?
    /// How often the Sky Watcher asks the flight feed (`SkyService.pollInterval`; tests shorten it).
    var skyPollInterval: Duration = SkyService.pollInterval
    /// The Sky Watcher's small pictures (`SkyThumbnails`): how long one may take, how long one that could not be made is left alone, and how many requests
    /// may wait for a place before the oldest are answered with the whole picture (tests shorten and shrink them).
    var skyThumbnailDeadline: Duration = SkyThumbnails.deadline
    var skyThumbnailFailureMemory: Duration = SkyThumbnails.failureMemory
    var skyThumbnailWaiting = SkyThumbnails.maximumWaiting
    /// Whether the recordings drive has room for a thumbnail to be kept (nil: the real rule, `SkyLightFilter.stillsHaveRoom` of the drive’s measured space; tests say).
    var skyThumbnailRoom: (@Sendable () -> Bool)?
    /// Replaces this machine's interface addresses where "Set up for Camera Bridge" looks for the bridge's own (tests: documentation
    /// addresses, never the machine's real LAN address).
    var interfaceAddresses: (@Sendable () -> [InterfaceAddress])?
    /// Replaces the running ingest's measured stream facts (`CameraRuntime.readinessFacts`) where "Set up for Camera Bridge" plans and checks
    /// the streams (tests: a camera whose settings name another codec than the one it sends).
    var measuredStreamFacts: (@Sendable (_ cameraID: UUID) async -> (main: MeasuredStreamFacts?, sub: MeasuredStreamFacts?))?
    /// How long "Set up for Camera Bridge" waits, after it changed a stream's codec, for the restarted ingest to receive H.264.
    var cameraSetupMeasureWait: Duration = .seconds(15)
    /// The cameras' security checks (`BridgeEngine+Security.swift`) at their runtime's start, daily and after "Set up for Camera Bridge";
    /// tests turn them off (`EngineTuning.testing`) so no test sees camera requests it did not ask for. A check on demand always runs.
    var securityChecks = true
    /// How long after a camera's runtime starts its check runs (the camera settles first).
    var securityCheckDelay: Duration = .seconds(60)
    /// How often every camera is checked again.
    var securityCheckInterval: Duration = .seconds(86_400)
    /// A check on demand waits this long after the camera's last one (`CameraSecurityCheckTooSoon`).
    var securityCheckCooldown: Duration = .seconds(60)
    /// A runtime start does not check a camera checked this recently.
    var securityCheckFreshness: Duration = .seconds(600)
    /// A check skipped because the camera did not answer (unreachable at its time, or it stopped answering during the check) is tried again
    /// after this long, then twice as long each time, up to `securityCheckRetryCap`.
    var securityCheckRetry: Duration = .seconds(600)
    var securityCheckRetryCap: Duration = .seconds(7200)
    /// Replaces a camera's readings (`CameraSettingsService.readRemoteAccess()`) in a security check (tests); nil from it: the camera did not
    /// answer.
    var securityReading: (@Sendable (_ camera: CameraConfiguration, _ credentials: HTTPCredentials?) async -> [RemoteAccessFinding]?)?
    /// Replaces the read of a camera's DNS servers (`CameraSettingsService.readDNS()`) in a security check and in the guard's own reads
    /// (tests); nil from it: not readable; what it throws, the read's error (a login pause, a refused login).
    var securityDNS: (@Sendable (_ camera: CameraConfiguration, _ credentials: HTTPCredentials?) async throws -> CameraDNSReading?)?
    /// Replaces the security check's read of whether a camera has IPv6 on (`CameraSettingsService.readIPv6()`, for a camera whose DNS it read
    /// through ONVIF) in tests; nil from it: the camera did not say.
    var securityIPv6: (@Sendable (_ camera: CameraConfiguration, _ credentials: HTTPCredentials?) async -> Bool?)?
    /// Removing a camera whose DNS servers the setup kept gives them back first (tests turn it off: `EngineTuning.testing`).
    var restoresWatchOnRemoval = true
    /// Replaces the RTSP check (`RTSPAccessProbe`) of a camera's stream address (tests).
    var rtspAccessProbe: (@Sendable (_ url: URL) async -> RemoteAccessState)?
    /// What the Internet guard saw of a camera (tests; on Camera Bridge OS the guard's own evidence). nil: no guard.
    var guardEvidence: (@Sendable (_ camera: CameraConfiguration) async -> GuardEvidence?)?
    /// Replaces the camera's address on the local network as the internet guard knows it (tests: the loopback fake camera stands for one
    /// at 192.168.77.x); nil: the camera's own host when it is a local IPv4 address (`BridgeEngine.guardAddress`).
    var guardCameraAddress: (@Sendable (_ camera: CameraConfiguration) -> String?)?
    /// How often the box's report is read while the bridge runs on Camera Bridge OS (a small file).
    var guardPollInterval: Duration = .seconds(60)
    /// A list the box refused is sent again after this long, then twice as long each time, up to `guardSyncRetryCap`.
    var guardSyncRetry: Duration = .seconds(5)
    var guardSyncRetryCap: Duration = .seconds(300)
    /// A report not updated for this long (the box's collector writes it every minute) is no evidence.
    var guardReportStaleAfter: Duration = .seconds(600)
    /// The day's notice changes its figures at most this often.
    /// The guard's own reads of the cameras' DNS servers (BridgeEngine+InternetGuard.swift; while `securityChecks` is on): every camera
    /// the guard can watch is read once each `guardDNSInterval`, one after the other; `guardDNSReconnectDelay` after a camera comes back
    /// online; `guardDNSPauseMargin` after a login pause a read met ends; those two no sooner than `guardDNSSpacing` after the camera's last
    /// read.
    var guardDNSInterval: Duration = .seconds(1800)
    var guardDNSReconnectDelay: Duration = .seconds(120)
    var guardDNSPauseMargin: Duration = .seconds(5)
    var guardDNSSpacing: Duration = .seconds(300)
    /// Replaces `CameraDrivers.detect` in `probeCamera` (tests).
    var detectVendor: (@Sendable (_ endpoint: CameraEndpoint, _ credentials: HTTPCredentials?) async -> VendorDetection?)?
    /// Replaces `CameraDrivers.onvifPort` in `probeCamera` (tests).
    var findONVIFPort: (@Sendable (_ endpoint: CameraEndpoint) async -> Int?)?
    /// Replaces `CameraDrivers.ownInterface` in `probeCamera` (tests).
    var findOwnInterface: (@Sendable (_ endpoint: CameraEndpoint, _ credentials: HTTPCredentials?) async -> OwnInterfaceCheck)?
    /// A Local Network check that is denied before any answer is known tries again this often (the system's alert may
    /// still be waiting for the person).
    var localNetworkRetryInterval: Duration = .milliseconds(500)
    /// How long a probe that couldn't reach the camera waits for the answer to the system's Local Network alert
    /// (`BridgeEngine.localNetworkAnswerWait`: one value for the probe and `checkLocalNetworkAccess`).
    var localNetworkAnswerWait: Duration = BridgeEngine.localNetworkAnswerWait
    /// `optimizeForHomeKit`: how long it waits for the reconnected stream to deliver video and settle, re-measuring
    /// at `homeKitOptimizationPollInterval`, before reporting the "after" checks with whatever it measured.
    var homeKitOptimizationMeasureWait: Duration = .seconds(15)
    var homeKitOptimizationPollInterval: Duration = .seconds(1)

    /// How long the network must stay unchanged (and no further wake come) before the cameras reconnect.
    var networkSettle: Duration = BridgeEngine.networkSettle
    /// A burst of network changes that keeps flapping postpones the reconnect by at most this long after its first change.
    var networkSettleCap: Duration = .seconds(15)
    /// A reconnect's work on one camera (its stream, events and advertisement) is given this long; a camera that hangs in it
    /// no longer holds every other camera, and the engine's operations, with it.
    var runtimeRefreshDeadline: Duration = .seconds(20)
    /// Cameras re-register their Bonjour record this far apart after a network change or wake (all at once, the goodbye and
    /// probing packets of one race the next one's and a camera comes back as "Driveway (2)").
    var advertisingStagger: Duration = .milliseconds(400)
    /// A network change leaves a camera's main stream connected when it delivered video this recently (a wake always
    /// reconnects).
    var healthyIngestWindow: Duration = .seconds(2)
    /// How each accessory is checked while it runs (`HAPHealthMonitor`).
    var accessoryHealth = HAPHealthMonitor.Timing()
    /// A runtime that does not answer a heartbeat within `runtimeHeartbeatDeadline` three times in a row (checked every
    /// `runtimeHeartbeatInterval`) is restarted, that camera only.
    var runtimeHeartbeatInterval: Duration = .seconds(10)
    /// How often removed cameras' Apple Home pairings kept 30 days or longer are deleted (`RemovedHAPIdentities.sweep`).
    var removedPairingSweepInterval: Duration = .seconds(86_400)
    var runtimeHeartbeatDeadline: Duration = .seconds(3)
    var runtimeHeartbeatStrikes = 3
    /// Called (tests) at the start of a camera's reconnect after a network change or wake.
    var beforeRuntimeRefresh: (@Sendable (_ cameraID: UUID) async -> Void)?
    /// Replaces a runtime's heartbeat (tests: a runtime that does not answer).
    var runtimeHeartbeat: (@Sendable (_ cameraID: UUID) async -> Void)?

    /// Replaces the AI service's transport (`URLSessionAITransport`; tests: a fake that answers from memory, never a real service).
    var aiTransport: (any AITransport)?
    /// The AI descriptions' clock: the describer's (staleness, the one-a-minute rule, the day's count) and the descriptions' time (tests: a
    /// clock they move).
    var aiNow: @Sendable () -> Date = Date.init

    /// Whether this Mac is on a VPN (`NetworkNotice.Kind.macOnVPN`); tests replace it.
    var macVPNProbe: @Sendable () -> MacVPNStatus? = { MacVPNDetector.current() }
    /// How often the status loop asks `macVPNProbe` (a network change asks at once).
    var macVPNCheckInterval: Duration = .seconds(30)

    static let standard = EngineTuning()
}
