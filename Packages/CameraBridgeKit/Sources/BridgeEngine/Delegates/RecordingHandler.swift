import BridgeSupport
import Foundation
import HAPCamera
import HDS
import MediaCore

/// The camera's `CameraRecordingDelegate` (plan W3-1 item 5): keeps the hub's recording state (active, selected
/// configuration, RecordingAudioActive — each update returns at once, as HAPCamera requires) and runs one
/// `RecordingProducer` per `recordingStream(streamID:)`. One stream per camera: a new stream cancels a producer that is
/// still running (HAPCamera already answers a second open with BUSY; this only covers a producer that outlives its
/// stream). `acknowledgeStream` / `closeRecordingStream` cancel the producer, which stops within one sample.
/// Without a selected configuration a stream is refused with `invalidConfiguration`.
actor RecordingHandler: CameraRecordingDelegate {
    private let hub: MediaHub
    private let traits: StreamTraits
    private let codecs: any MediaCodecs
    private let cameraAudioEnabled: Bool
    private let timing: RecordingTiming
    private let log: Log
    private let onChange: @Sendable () -> Void
    /// Recording stream/quality preferences (`CameraConfiguration.recordingStreamMode` / `.recordingQualityMode`).
    private let hubs: HubProvider?
    private let streamMode: RecordingStreamMode
    private let qualityMode: RecordingQualityMode
    private let overlay: TimestampOverlayControl?

    private(set) var isActive = false
    private(set) var configuration: CameraRecordingConfiguration?
    private(set) var audioActive = false
    private var current: RecordingProducer?
    private var currentLease: HubLease?
    /// The running stream's phases for the diagnostics bundle.
    private var currentTrace: SessionTrace?

    /// `traits`: what the main hub's ingest learned about the stream (B-frames, longest GOP); used for `.main`
    /// recording and whenever `hubs` is nil (tests). `hubs`: the same provider `StreamingHandler` leases live views
    /// through, used when `streamMode` asks for the sub stream (`.sub`; `.automatic` keeps the main stream, matching
    /// the engine's long-standing recording behaviour).
    init(hub: MediaHub, traits: StreamTraits = StreamTraits(), codecs: any MediaCodecs, cameraAudioEnabled: Bool,
         timing: RecordingTiming = RecordingTiming(), log: Log, onChange: @escaping @Sendable () -> Void = {},
         hubs: HubProvider? = nil, streamMode: RecordingStreamMode = .automatic, qualityMode: RecordingQualityMode = .matchHubRequest,
         overlay: TimestampOverlayControl? = nil) {
        self.hub = hub
        self.traits = traits
        self.codecs = codecs
        self.cameraAudioEnabled = cameraAudioEnabled
        self.timing = timing
        self.log = log
        self.onChange = onChange
        self.hubs = hubs
        self.streamMode = streamMode
        self.qualityMode = qualityMode
        self.overlay = overlay
    }

    /// A recording stream is being produced.
    var isRecording: Bool { current != nil }

    func updateRecordingActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        log.info("HomeKit recording \(active ? "enabled" : "disabled")")
        onChange()
    }

    func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?) {
        self.configuration = configuration
        if let configuration {
            let resolution = configuration.resolution
            log.info("Recording configuration: \(resolution.width)×\(resolution.height)@\(resolution.fps) \(configuration.videoProfile) "
                     + "level \(H264Levels.idc(configuration.videoLevel)), \(configuration.videoBitrateKbps) kbit/s, "
                     + "I-frame \(configuration.iFrameIntervalMs) ms, prebuffer \(configuration.prebufferLengthMs) ms, "
                     + "fragments \(configuration.fragmentLengthMs) ms")
        }
    }

    func updateRecordingAudioActive(_ active: Bool) {
        audioActive = active
    }

    func recordingStream(streamID: Int) async throws -> AsyncThrowingStream<RecordingPacket, any Error> {
        guard let configuration else {
            log.warning("Recording stream \(streamID) refused: no recording configuration was selected")
            throw HDSProtocolReason.invalidConfiguration
        }
        if let previous = current {
            log.notice("Recording stream \(streamID) replaces stream \(previous.streamID), which was still producing")
            previous.cancel()
            currentTrace?.finish("replaced by stream \(streamID)")
        }
        await currentLease?.release()
        currentLease = nil
        var recordingHub = hub
        var recordingTraits = traits
        var usesSubStream = false
        if streamMode == .sub, let hubs {
            let lease = await hubs(true)
            if lease.isSubStream {
                recordingHub = lease.hub
                recordingTraits = lease.traits
                usesSubStream = true
                currentLease = lease
            } else {
                log.notice("Recording stream \(streamID): the sub stream is unavailable; recording the main stream instead")
                await lease.release()
            }
        }
        let producer = RecordingProducer(streamID: streamID, configuration: configuration, audioActive: audioActive,
                                         cameraAudioEnabled: cameraAudioEnabled, hub: recordingHub, traits: recordingTraits, codecs: codecs,
                                         timing: timing, log: log, qualityMode: qualityMode, usesSubStream: usesSubStream, overlay: overlay)
        current = producer
        let resolution = configuration.resolution
        let trace = DiagnosticsCenter.shared.begin(kind: "recording", id: UUID(), cameraID: log.cameraID,
                                                   summary: "stream \(streamID) \(resolution.width)×\(resolution.height)@\(resolution.fps), "
                                                       + "\(configuration.videoBitrateKbps) kbit/s, \(usesSubStream ? "sub" : "main") stream")
        trace.mark("start", "audio \(audioActive ? "on" : "off")")
        currentTrace = trace
        log.info("Recording stream \(streamID) started (audio \(audioActive ? "on" : "off"))\(usesSubStream ? " from the sub stream" : "")")
        onChange()
        return producer.start()
    }

    /// The running producer's status, for `CameraStatus`.
    func recordingSessionStatus() -> RecordingSessionStatus? {
        current.map { RecordingSessionStatus(usesSubStream: $0.usesSubStream, isPassthrough: nil, resolution: configuration?.resolution,
                                              bitrateKbps: configuration?.videoBitrateKbps) }
    }

    /// `acknowledgeStream` / `closeRecordingStream` name the stream by its ID only, and a hub may reuse an ID. HAPCamera
    /// delivers the end of a stream to the delegate before it asks for the next stream's packets (`RecordingStream`'s
    /// predecessor), so an end can never reach a newer producer that has the same ID.
    func acknowledgeStream(streamID: Int) {
        log.info("Recording stream \(streamID) acknowledged")
        end(streamID, reason: "acknowledged by the controller")
    }

    func closeRecordingStream(streamID: Int, reason: HDSProtocolReason?) {
        let why = reason.map { "\($0)" } ?? "connection closed"
        log.info("Recording stream \(streamID) closed (\(why))")
        end(streamID, reason: "closed (\(why))")
    }

    /// Cancels the running producer (runtime stopping).
    func stopAll() async {
        current?.cancel()
        current = nil
        currentTrace?.finish("the camera stopped")
        currentTrace = nil
        await currentLease?.release()
        currentLease = nil
    }

    private func end(_ streamID: Int, reason: String) {
        guard let producer = current, producer.streamID == streamID else { return }
        producer.cancel()
        current = nil
        currentTrace?.finish(reason)
        currentTrace = nil
        let lease = currentLease
        currentLease = nil
        Task { await lease?.release() }
        onChange()
    }
}
