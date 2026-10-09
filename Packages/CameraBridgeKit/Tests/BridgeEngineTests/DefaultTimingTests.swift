import Foundation
import HAP
import HAPCamera
import Testing
@testable import BridgeEngine

/// The normative defaults of the engine's timers. Every runtime test shortens them (`EngineTuning`), so a debug value
/// left in a default (an 18 s recording cap, a 3 s RTCP timeout) would otherwise pass the suite.
@Suite struct DefaultTimingTests {
    /// Integration brief §5.3 / research brief §3.8: recordings are capped at 3 minutes (the next fragment is the last);
    /// the prebuffer is paced at one fragment per 250 ms instead of bursting ("HAP will terminate the connection if too
    /// much prebuffer is sent too quickly").
    @Test func recordingStreams() {
        #expect(RecordingTiming() == RecordingTiming(maximumDuration: .seconds(180), fragmentPacing: .milliseconds(250)))
        // One cap value (review finding W4 round 4): the producer's default is the controller's.
        #expect(RecordingTiming().maximumDuration == CameraControllerTimings.standard.maximumRecordingDuration)
    }

    /// Research brief §3.6 / integration brief §5.4: a live session ends after 30 s without controller RTCP. The engine
    /// runs the controller and the recording and snapshot paths with their standard timers.
    @Test func engineTuning() {
        let standard = EngineTuning.standard
        #expect(standard.liveControllerTimeout == .seconds(30))
        #expect(standard.controller == .standard)
        #expect(standard.controller == CameraControllerTimings(recordingAcknowledgeTimeout: .seconds(12), recordingStopTimeout: .seconds(10),
                                                               maximumRecordingDuration: .seconds(180), recordingCapGrace: .seconds(5),
                                                               streamingDelegateTimeout: .seconds(8)))
        #expect(standard.recording == RecordingTiming())
        // One cap: the producer's; the controller's backstop counts from the same 3 minutes (review finding W4 round 3).
        #expect(standard.controller.maximumRecordingDuration == standard.recording.maximumDuration)
        #expect(standard.snapshots == SnapshotProvider.Timing())
        #expect(standard.ingest == IngestSupervisor.Timing())
        // An unused sub stream disconnects after 10 s; a live view waits up to 3 s for its first picture; status is
        // aggregated at most 4 times a second (plan W3-1 item 7); soft motion waits 10 s for a sub stream picture before
        // it uses the main stream.
        #expect(standard.subStreamIdleStop == .seconds(10))
        #expect(standard.subStreamStartWait == .seconds(3))
        #expect(standard.statusInterval == .milliseconds(250))
        #expect(standard.softMotionSubStreamWait == .seconds(10))
        #expect(standard.beforeControllerRegistration == nil)
        #expect(standard.afterSensorsBridgeStatus == nil)
        // Review finding (W4 round 3): the probe's wait for the Local Network answer was a second literal of the public
        // constant `checkLocalNetworkAccess` uses; changing one left the other behind.
        #expect(standard.localNetworkAnswerWait == BridgeEngine.localNetworkAnswerWait)
        #expect(BridgeEngine.networkSettle == .seconds(2), "network changes settle 2 s before the cameras reconnect")
        #expect(StreamTraits.bFrameClearGOPs == 3)
    }

    /// Hardening plan WS-C: the recovery timings (every test shortens them, so a debug value in a default would pass the suite).
    @Test func recovery() {
        let standard = EngineTuning.standard
        #expect(standard.networkSettle == .seconds(2) && standard.networkSettleCap == .seconds(15))
        #expect(standard.runtimeRefreshDeadline == .seconds(20))
        #expect(standard.advertisingStagger == .milliseconds(400))
        #expect(standard.healthyIngestWindow == .seconds(2))
        #expect(standard.runtimeHeartbeatInterval == .seconds(10) && standard.runtimeHeartbeatDeadline == .seconds(3))
        #expect(standard.runtimeHeartbeatStrikes == 3)
        #expect(standard.accessoryHealth == HAPHealthMonitor.Timing(interval: .seconds(30), probeTimeout: .seconds(1), browseTimeout: .seconds(3),
                                                                    bonjourMissesBeforeRestart: 2, controllerSilence: .seconds(600)))
        #expect(standard.controller.preparedSessionTimeout == .seconds(20))
        #expect(standard.controller.staleUnstartedSessionAge == .seconds(15))
        #expect(IngestSupervisor.Timing().closeGrace == .seconds(2))
        #expect(standard.beforeRuntimeRefresh == nil && standard.runtimeHeartbeat == nil)
    }

    /// Plan W3-1 item 1 / spec §7 (review finding W4 round 2: these were never pinned): no video for 15 s reconnects;
    /// backoff 1 s → 60 s; rejected credentials wait 10 minutes (cameras lock the account after a few failed logins:
    /// Hikvision after 5–7); Reolink switches to HTTP-FLV after three failed attempts; a connection gets 30 s.
    @Test func ingest() {
        let timing = IngestSupervisor.Timing()
        #expect(timing.watchdog == .seconds(15))
        #expect(timing.initialBackoff == .seconds(1))
        #expect(timing.maximumBackoff == .seconds(60))
        #expect(timing.unauthorizedRetry == .seconds(600))
        #expect(timing.fallbackAfterFailures == 3)
        #expect(timing.connectTimeout == .seconds(30))
    }

    /// Camera-facing stops (event source logout, RTSP TEARDOWN, the talkback channel's close) wait at most 3 s — one
    /// value (review finding W4 round 4: the ingest's source stop had a literal of its own).
    @Test func cameraFacingStops() {
        #expect(CameraRuntime.stopLimit == .seconds(3))
        #expect(IngestSupervisor.Timing().sourceStopLimit == CameraRuntime.stopLimit)
    }

    /// Integration brief §5.4: periodic snapshots are served from a cache of 10 s (the app refreshes every 10 s; a keyframe
    /// is decoded once, on a decoder kept 60 s); an event snapshot finishes within 3 s and any other within 4 s, past which the last
    /// picture (up to 5 minutes old) stands in (hubs warn at 8 s and fail at 25 s, and a slow request holds up the accessory's events:
    /// live-view hardening, audit 3 A7).
    @Test func snapshots() {
        let timing = SnapshotProvider.Timing()
        #expect(timing.cacheLifetime == .seconds(10))
        #expect(timing.decoderIdleLifetime == .seconds(60))
        #expect(timing.budget == .seconds(4) && timing.eventBudget == .seconds(3))
        #expect(timing.maximumStaleAge == .seconds(300))
        #expect(timing.cameraAPIRetry == .seconds(30))
        // A camera API that rejects the credentials waits as long as the ingest (review finding W4 round 4: lockouts).
        #expect(timing.unauthorizedRetry == IngestSupervisor.Timing().unauthorizedRetry)
    }
}
