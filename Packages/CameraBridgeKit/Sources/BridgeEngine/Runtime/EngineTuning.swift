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
    /// Replaces `CameraDrivers.detect` in `probeCamera` (tests).
    var detectVendor: (@Sendable (_ endpoint: CameraEndpoint, _ credentials: HTTPCredentials?) async -> VendorDetection?)?
    /// Replaces `CameraDrivers.onvifPort` in `probeCamera` (tests).
    var findONVIFPort: (@Sendable (_ endpoint: CameraEndpoint) async -> Int?)?
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
    var runtimeHeartbeatDeadline: Duration = .seconds(3)
    var runtimeHeartbeatStrikes = 3
    /// Called (tests) at the start of a camera's reconnect after a network change or wake.
    var beforeRuntimeRefresh: (@Sendable (_ cameraID: UUID) async -> Void)?
    /// Replaces a runtime's heartbeat (tests: a runtime that does not answer).
    var runtimeHeartbeat: (@Sendable (_ cameraID: UUID) async -> Void)?

    /// Whether this Mac is on a VPN (`NetworkNotice.Kind.macOnVPN`); tests replace it.
    var macVPNProbe: @Sendable () -> MacVPNStatus? = { MacVPNDetector.current() }
    /// How often the status loop asks `macVPNProbe` (a network change asks at once).
    var macVPNCheckInterval: Duration = .seconds(30)

    static let standard = EngineTuning()
}
