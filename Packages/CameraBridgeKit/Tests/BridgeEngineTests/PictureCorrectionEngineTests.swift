@testable import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import MediaCore
import Testing
import TestSupport
@testable import BridgeEngine
#if canImport(Darwin)
import PlatformApple
#endif

/// The per-camera "Straighten the picture" setting: its configuration (backward compatible), that a change to it never restarts
/// the camera (the running camera takes it in place), Apple Home's live view and HKSV recordings transcoding with it, and the
/// snapshots (Apple Home's tiles and notifications, the web's stills) straightened unless the camera's own picture is asked for.
@Suite(.serialized) struct PictureCorrectionEngineTests {
    /// The owner's Backyard camera: Straighten 40, Level 15.
    static let backyard = PictureCorrection(straighten: 0.40, level: 0.15)

    private func camera() -> CameraConfiguration {
        CameraConfiguration(name: "Porch", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.20"), username: "admin")
    }

    // MARK: Configuration

    @Test func aConfigurationWrittenBeforeTheSettingExistedLoadsWithItOff() throws {
        // The keys of a camera saved by an earlier build: nothing about the picture correction.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Porch","kind":"camera","vendor":"hikvision","endpoint":{"host":"192.0.2.20","httpPort":80,"rtspPort":554,"useHTTPS":false},
         "username":"admin","liveQualityMode":"originalQuality","preferredConfigMethod":"onvifFull"}
        """
        let decoded = try JSONDecoder().decode(CameraConfiguration.self, from: Data(json.utf8))
        #expect(decoded.pictureCorrection == .off)
        #expect(decoded.pictureCorrection.isOff)
        #expect(decoded.liveQualityMode == .originalQuality && decoded.preferredConfigMethod == .onvifFull)   // the rest still reads
        #expect(camera().pictureCorrection == .off, "a new camera starts with the picture as it sends it")
    }

    @Test func theSettingRoundTrips() throws {
        var config = camera()
        config.pictureCorrection = PictureCorrection(straighten: 0.40, level: 0.15)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CameraConfiguration.self, from: data)
        #expect(decoded == config)
        #expect(decoded.pictureCorrection.straighten == 0.40 && decoded.pictureCorrection.level == 0.15)
        let written = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let value = try #require(written["pictureCorrection"] as? [String: Any], "the key is pictureCorrection")
        #expect(value["straighten"] as? Double == 0.40 && value["level"] as? Double == 0.15)
    }

    @Test func anUnreadableSettingReadsAsOffAndTheRestStillLoads() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Porch","kind":"camera","vendor":"hikvision","endpoint":{"host":"192.0.2.20","httpPort":80,"rtspPort":554,"useHTTPS":false},
         "username":"admin","pictureCorrection":"sideways","liveQualityMode":"originalQuality"}
        """
        let decoded = try JSONDecoder().decode(CameraConfiguration.self, from: Data(json.utf8))
        #expect(decoded.pictureCorrection == .off)
        #expect(decoded.liveQualityMode == .originalQuality)
    }

    // MARK: Restarts

    @MainActor @Test func changingOnlyTheCorrectionNeverRestartsTheRuntime() {
        let old = camera()
        var new = old
        new.pictureCorrection = PictureCorrection(straighten: 0.4, level: 0.15)
        #expect(!BridgeEngine.needsRestart(old, new, paired: true) && !BridgeEngine.needsRestart(new, old, paired: false))
        #expect(!BridgeEngine.needsRestart(old, new, paired: false) && !BridgeEngine.needsRestart(new, old, paired: true))
        // Another change still restarts, correction or not.
        var other = new
        other.endpoint.host = "192.0.2.21"
        #expect(BridgeEngine.needsRestart(new, other, paired: true))
    }

    // MARK: MediaFit

    private static let source = RuntimeMediaFitTests.h264(1920, 1080)

    @Test func theCorrectionForcesALiveTranscodeThatWouldOtherwisePassThrough() {
        let requested = RuntimeMediaFitTests.live(1920, 1080)
        #expect(MediaFit.live(source: Self.source, frameRate: 25, requested: requested) == .passthrough)
        #expect(MediaFit.live(source: Self.source, frameRate: 25, requested: requested, pictureCorrection: true) == .transcode(MediaFit.pictureCorrectionReason))
        #expect(MediaFit.pictureCorrectionReason == "straightened picture")
        // Original quality passes the camera's stream through untouched, until its picture has to be straightened.
        #expect(MediaFit.live(source: Self.source, frameRate: 25, requested: RuntimeMediaFitTests.live(640, 360), qualityMode: .originalQuality,
                              pictureCorrection: true) == .transcode(MediaFit.pictureCorrectionReason))
        // Both on: the overlay's reason is the one given.
        #expect(MediaFit.live(source: Self.source, frameRate: 25, requested: requested, timestampOverlay: true, pictureCorrection: true)
            == .transcode(MediaFit.timestampOverlayReason))
    }

    @Test func theCorrectionForcesARecordingTranscodeThatWouldOtherwisePassThrough() {
        let configuration = RuntimeMediaFitTests.recording(1920, 1080)
        #expect(MediaFit.recording(source: Self.source, frameRate: 25, gop: .seconds(2), configuration: configuration) == .passthrough)
        #expect(MediaFit.recording(source: Self.source, frameRate: 25, gop: .seconds(2), configuration: configuration, pictureCorrection: true)
            == .transcode(MediaFit.pictureCorrectionReason))
        #expect(MediaFit.recording(source: Self.source, frameRate: 25, gop: .seconds(2), configuration: configuration, qualityMode: .originalWhenPossible,
                                   pictureCorrection: true) == .transcode(MediaFit.pictureCorrectionReason))
        #expect(MediaFit.recording(source: Self.source, frameRate: 25, gop: .seconds(2), configuration: configuration, timestampOverlay: true,
                                   pictureCorrection: true) == .transcode(MediaFit.timestampOverlayReason))
    }

    // MARK: The camera's own size (Original quality)

    /// The owner's panorama: wider than the H.264 encoder takes (4096), so its own size is capped at 3840 wide, the height in proportion and
    /// even: 3840 × 1888 / 4256 = 1703.4, the nearest even height is 1704.
    private static let panorama = RuntimeMediaFitTests.h264(4256, 1888)

    @Test func theCorrectionAloneAtTheCamerasOwnSizeIsCappedAt3840Wide() {
        // `timestampOverlay` is "either the label or the correction asked for this transcode" (LiveStreamPipeline, RecordingProducer).
        let live = MediaFit.liveEncoderSettings(for: RuntimeMediaFitTests.live(1280, 720), source: Self.panorama, sourceFrameRate: 25,
                                                qualityMode: .originalQuality, timestampOverlay: true)
        #expect(live.width == 3840 && live.height == 1704, "\(live.width)×\(live.height)")
        #expect(live.width % 2 == 0 && live.height % 2 == 0)
        #expect(live.bitrateKbps >= 500 && live.bitrateKbps <= 12_000)
        #expect(live.level == .auto)
        let recording = MediaFit.recordingEncoderSettings(for: RuntimeMediaFitTests.recording(1280, 720), source: Self.panorama, sourceFrameRate: 25,
                                                          qualityMode: .originalWhenPossible, timestampOverlay: true)
        #expect(recording.width == 3840 && recording.height == 1704, "\(recording.width)×\(recording.height)")
    }

    @Test func theLabelAloneAtTheCamerasOwnSizeIsCappedTheSameWay() {
        // The overlay (correction off) and the correction (overlay off) reach MediaFit as the same flag: one size either way.
        let overlay = MediaFit.liveEncoderSettings(for: RuntimeMediaFitTests.live(640, 360), source: Self.panorama, sourceFrameRate: 15,
                                                   qualityMode: .originalQuality, timestampOverlay: true)
        let correction = MediaFit.liveEncoderSettings(for: RuntimeMediaFitTests.live(1920, 1080), source: Self.panorama, sourceFrameRate: 15,
                                                      qualityMode: .originalQuality, timestampOverlay: true)
        #expect(overlay.width == 3840 && overlay.height == 1704)
        #expect(correction.width == overlay.width && correction.height == overlay.height)
        // The bit rate is what pictures of the size written need, not of the size the camera sends: 3840 × 1704 at 15 fps, 0.07 bit per pixel.
        #expect(overlay.bitrateKbps == Int(Double(3840 * 1704) * 15 * 0.07 / 1000))
    }

    @Test func aSourceAtOrBelow3840WideKeepsItsOwnSizeUnchanged() {
        for (width, height, wanted) in [(1920, 1080, (1920, 1080)), (3840, 2160, (3840, 2160)), (2560, 1440, (2560, 1440)), (1921, 1081, (1920, 1080))] {
            let live = MediaFit.liveEncoderSettings(for: RuntimeMediaFitTests.live(1280, 720), source: RuntimeMediaFitTests.h264(width, height), sourceFrameRate: 25,
                                                    qualityMode: .originalQuality, timestampOverlay: true)
            #expect(live.width == wanted.0 && live.height == wanted.1, "\(width)×\(height) -> \(live.width)×\(live.height)")
            let recording = MediaFit.recordingEncoderSettings(for: RuntimeMediaFitTests.recording(1280, 720), source: RuntimeMediaFitTests.h264(width, height),
                                                              sourceFrameRate: 25, qualityMode: .originalWhenPossible, timestampOverlay: true)
            #expect(recording.width == wanted.0 && recording.height == wanted.1)
        }
        // Not an original-size transcode: the size asked for, however wide the camera is.
        let matched = MediaFit.liveEncoderSettings(for: RuntimeMediaFitTests.live(1280, 720), source: Self.panorama, sourceFrameRate: 25,
                                                   qualityMode: .matchHomeKitRequest, timestampOverlay: true)
        #expect(matched.width == 1280 && matched.height == 720)
    }

    @Test func theClipsAndTheTranscodersShareOneRule() {
        // WebApp's saved clips cap a recording at the same width the same way.
        let size = MediaFit.cappedEvenSize(width: 4256, height: 1888)
        #expect(size.width == 3840 && size.height == 1704)
        let kept = MediaFit.cappedEvenSize(width: 1920, height: 852)
        #expect(kept.width == 1920 && kept.height == 852)
        let odd = MediaFit.cappedEvenSize(width: 1281, height: 721)
        #expect(odd.width == 1280 && odd.height == 720, "an odd size is made even (4:2:0)")
        #expect(MediaFit.maximumOutputWidth == 3840)
    }

    // MARK: The control the streams read

    @Test func theControlHandsStreamsTheCurrentCorrectionOrNothingWhenOffOrUnsupported() {
        let control = PictureCorrectionControl(.off, supported: true)
        #expect(control.current == nil && !control.isOn)
        let tilted = PictureCorrection(straighten: 0.40, level: 0.15)
        #expect(control.update(tilted), "turned on")
        #expect(control.current == tilted && control.isOn)
        #expect(!control.update(PictureCorrection(straighten: 0.10)), "a new value while on is not a switch")
        #expect(control.current == PictureCorrection(straighten: 0.10))
        #expect(control.update(.off), "turned off")
        #expect(control.current == nil && !control.isOn)
        #expect(!control.update(.off))

        // Codecs that cannot straighten a picture: off everywhere, whatever the camera's setting says, and never switched.
        let unsupported = PictureCorrectionControl(tilted, supported: false)
        #expect(unsupported.current == nil && !unsupported.isOn)
        #expect(!unsupported.update(.off) && !unsupported.update(PictureCorrection(straighten: -0.20)))
        #expect(unsupported.current == nil && !unsupported.isOn)
    }
}

#if canImport(Darwin)
/// `AppleMediaCodecs` that says whether it can straighten pictures and remembers every transcoder it makes with the correction it was
/// handed (the Apple codecs themselves leave the picture as it is: what the engine asked for is what is checked).
struct CorrectionCapturingCodecs: MediaCodecs {
    struct Made: Sendable {
        var settings: VideoEncoderSettings
        var correction: (any PictureCorrectionProviding)?
    }

    let base = AppleMediaCodecs()
    let made = Box<[Made]>([])
    /// The corrections `correctJPEG` was asked for.
    let straightened = Box<[PictureCorrection]>([])
    /// The label of the dispatch queue each call of `correctJPEG` ran on.
    let straightenedOn = Box<[String]>([])
    static let straightenedMark = Data(" straightened".utf8)
    let supportsPictureCorrection: Bool

    init(supportsPictureCorrection: Bool) {
        self.supportsPictureCorrection = supportsPictureCorrection
    }

    func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding { try base.makeVideoDecoder(format: format) }
    func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { try base.makeVideoEncoder(settings: settings) }
    func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding {
        made.update { $0.append(Made(settings: output, correction: nil)) }
        return try base.makeVideoTranscoder(output: output)
    }
    func makeVideoTranscoder(output: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)?) throws -> any VideoTranscoding {
        made.update { $0.append(Made(settings: output, correction: nil)) }
        return try base.makeVideoTranscoder(output: output, overlay: overlay)
    }
    func makeVideoTranscoder(output: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)?,
                             correction: (any PictureCorrectionProviding)?) throws -> any VideoTranscoding {
        made.update { $0.append(Made(settings: output, correction: correction)) }
        return try base.makeVideoTranscoder(output: output, overlay: overlay)
    }
    func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding {
        try base.makeAudioTranscoder(input: input, output: output)
    }
    func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data {
        try base.jpeg(from: frame, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality)
    }
    func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data { try base.resizeJPEG(jpeg, maxWidth: maxWidth, maxHeight: maxHeight) }
    /// Appends `straightenedMark` to the JPEG and remembers the correction.
    func correctJPEG(_ jpeg: Data, correction: PictureCorrection) throws -> Data {
        straightened.update { $0.append(correction) }
        straightenedOn.update { $0.append(String(cString: __dispatch_queue_get_label(nil))) }
        return jpeg + Self.straightenedMark
    }
    func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] {
        try base.silentAACFrames(duration: duration, sampleRate: sampleRate, channels: channels, startPTS: startPTS, wallClock: wallClock)
    }
    func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration, audio: AudioCodec?,
                             audioSampleRate: Int) -> any MediaSource {
        base.makeSyntheticSource(displayName: displayName, width: width, height: height, fps: fps, keyframeInterval: keyframeInterval,
                                 audio: audio, audioSampleRate: audioSampleRate)
    }
}

/// Apple Home's live view on a running camera (the demo camera's 640×360 H.264 main stream, which a 1280×720 request takes as it is).
extension PictureCorrectionEngineTests {
    struct RunningCamera {
        let fixture: EngineFixture
        let camera: CameraConfiguration
        let runtime: CameraRuntime
        let handler: StreamingHandler
    }

    /// `configure` changes the camera before it is added.
    @MainActor static func runningCamera(codecs: CorrectionCapturingCodecs,
                                         configure: (inout CameraConfiguration) -> Void) async throws -> RunningCamera {
        let fixture = try await EngineFixture(adjust: { $0.codecs = codecs })
        var camera = EngineFixture.demoCamera(name: "Backyard")
        configure(&camera)
        try await fixture.engine.addCamera(camera, password: nil)
        await fixture.engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        return try await attach(fixture, camera)
    }

    /// The camera's runtime and its live view handler, once the handler is there.
    @MainActor static func attach(_ fixture: EngineFixture, _ camera: CameraConfiguration) async throws -> RunningCamera {
        let runtime = try #require(fixture.engine.runtimes[camera.id])
        #expect(await fixture.until(.seconds(10)) { await runtime.streamingHandler != nil })
        return RunningCamera(fixture: fixture, camera: camera, runtime: runtime, handler: try #require(await runtime.streamingHandler))
    }

    /// Prepares and starts one live session asking for 1280×720; the receiver plays Apple Home.
    @MainActor static func startSession(_ handler: StreamingHandler) async throws -> (receiver: SRTPTestReceiver, sessionID: UUID) {
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await RuntimeLiveStreamTests.prepare(handler, receiver: receiver, sessionID: sessionID)
        await RuntimeLiveStreamTests.connect(receiver, to: response)
        try await handler.handleStreamRequest(.start(sessionID: sessionID, video: RuntimeLiveStreamTests.video(1280, 720), audio: nil))
        return (receiver, sessionID)
    }

    // MARK: Live view

    @MainActor @Test(.timeLimit(.minutes(2))) func aCameraWithTheCorrectionOnHandsItToTheTranscoder() async throws {
        let codecs = CorrectionCapturingCodecs(supportsPictureCorrection: true)
        let run = try await Self.runningCamera(codecs: codecs) { $0.pictureCorrection = Self.backyard }
        let session = try await Self.startSession(run.handler)
        let pipeline = try #require(await run.handler.pipeline(session.sessionID))
        #expect(await eventually(timeout: .seconds(10)) { pipeline.isTranscoding })
        #expect(pipeline.videoPath == .transcode("straightened picture"), "a stream that would pass through is transcoded to straighten it")
        #expect(await session.receiver.waitFor(timeout: .seconds(8)) { $0.keyframes >= 1 && $0.videoFrames >= 10 })
        let made = try #require(codecs.made.value.first)
        #expect(made.correction?.current == Self.backyard)
        #expect(made.settings.width == 1280 && made.settings.height == 720, "the size Apple Home asked for")
        await session.receiver.stop()
        await run.fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func withOriginalQualityTheTranscodeKeepsTheCamerasSize() async throws {
        let codecs = CorrectionCapturingCodecs(supportsPictureCorrection: true)
        let run = try await Self.runningCamera(codecs: codecs) {
            $0.pictureCorrection = Self.backyard
            $0.liveQualityMode = .originalQuality
        }
        let session = try await Self.startSession(run.handler)
        let pipeline = try #require(await run.handler.pipeline(session.sessionID))
        #expect(await eventually(timeout: .seconds(10)) { pipeline.isTranscoding })
        let made = try #require(codecs.made.value.first)
        #expect(made.settings.width == 640 && made.settings.height == 360, "the camera's own size, not the 1280×720 asked for")
        #expect(made.settings.level == .auto)
        #expect(made.correction?.current == Self.backyard)
        await session.receiver.stop()
        await run.fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(3))) func onCodecsWithoutSupportTheCorrectionIsOff() async throws {
        let codecs = CorrectionCapturingCodecs(supportsPictureCorrection: false)
        let run = try await Self.runningCamera(codecs: codecs) { $0.pictureCorrection = Self.backyard }
        let session = try await Self.startSession(run.handler)
        let pipeline = try #require(await run.handler.pipeline(session.sessionID))
        #expect(await session.receiver.waitFor(timeout: .seconds(8)) { $0.keyframes >= 1 })
        #expect(pipeline.videoPath == .passthrough && !pipeline.isTranscoding && codecs.made.value.isEmpty,
                "nothing here can straighten it: the camera's stream passes through as if the correction were off")
        await session.receiver.stop()

        // A transcode for another reason (the timestamp overlay) is not handed the correction either.
        var edited = try #require(run.fixture.engine.configurations.first)
        edited.timestampOverlay.enabled = true
        try await run.fixture.engine.updateCamera(edited, password: nil)
        #expect(await run.fixture.waitFor { run.fixture.status(edited.id)?.connection == .online })
        let restarted = try await Self.attach(run.fixture, edited)
        let second = try await Self.startSession(restarted.handler)
        let transcoded = try #require(await restarted.handler.pipeline(second.sessionID))
        #expect(await eventually(timeout: .seconds(10)) { transcoded.isTranscoding })
        #expect(transcoded.videoPath == .transcode(MediaFit.timestampOverlayReason))
        let made = try #require(codecs.made.value.first)
        #expect(made.correction?.current == nil)
        await second.receiver.stop()
        await run.fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func changingTheCorrectionReachesARunningStreamWithoutARestart() async throws {
        let codecs = CorrectionCapturingCodecs(supportsPictureCorrection: true)
        let run = try await Self.runningCamera(codecs: codecs) { $0.pictureCorrection = Self.backyard }
        let engine = run.fixture.engine
        let logs = LiveLogCapture()
        defer { logs.stop() }
        let ingest = await run.runtime.ingestAttempts
        let session = try await Self.startSession(run.handler)
        let pipeline = try #require(await run.handler.pipeline(session.sessionID))
        #expect(await eventually(timeout: .seconds(10)) { pipeline.isTranscoding })
        let provider = try #require(codecs.made.value.first?.correction)
        #expect(provider.current == Self.backyard)

        // The edits the camera page sends while the slider moves (PATCH /api/v1/cameras/:id → updateCamera): new values, still on.
        var edited = try #require(engine.configurations.first)
        let flatter = PictureCorrection(straighten: -0.20, level: 0.05)
        edited.pictureCorrection = flatter
        try await engine.updateCamera(edited, password: nil)
        #expect(provider.current == flatter, "the running stream's next picture is straightened by the new value")
        edited.pictureCorrection = PictureCorrection(straighten: 0.10)
        try await engine.updateCamera(edited, password: nil)
        #expect(provider.current == PictureCorrection(straighten: 0.10))
        #expect(codecs.made.value.count == 1, "the same transcoder: a new value is not a rebuild")
        #expect(logs.lines(of: session.sessionID).filter { $0.contains("picture correction") }.isEmpty, "\(logs.lines(of: session.sessionID))")

        #expect(engine.runtimes[run.camera.id] === run.runtime, "the camera was not restarted (a restart closes its NVR file)")
        #expect(await run.handler.pipeline(session.sessionID) === pipeline && pipeline.isTranscoding, "the live view went on")
        #expect(await run.runtime.ingestAttempts.main == ingest.main, "the camera's stream never reconnected")
        let frames = await session.receiver.statistics.videoFrames
        #expect(await session.receiver.waitFor(timeout: .seconds(8)) { $0.videoFrames > frames + 10 }, "video still reaches Apple Home")
        await session.receiver.stop()
        await run.fixture.tearDown()
    }

    /// Every transcoder holds the camera's correction, also one made for another reason while the correction is off: turned on later, it
    /// reaches that stream at its next picture.
    @MainActor @Test(.timeLimit(.minutes(2))) func aTranscodeForAnotherReasonHoldsTheCorrectionAndTakesItWhenTurnedOn() async throws {
        let codecs = CorrectionCapturingCodecs(supportsPictureCorrection: true)
        let run = try await Self.runningCamera(codecs: codecs) { $0.timestampOverlay.enabled = true }
        let engine = run.fixture.engine
        let session = try await Self.startSession(run.handler)
        let pipeline = try #require(await run.handler.pipeline(session.sessionID))
        #expect(await eventually(timeout: .seconds(10)) { pipeline.isTranscoding })
        #expect(pipeline.videoPath == .transcode(MediaFit.timestampOverlayReason))
        let provider = try #require(codecs.made.value.first?.correction, "handed the control although the correction is off")
        #expect(provider.current == nil, "off: nothing to straighten")

        var edited = try #require(engine.configurations.first)
        edited.pictureCorrection = Self.backyard
        try await engine.updateCamera(edited, password: nil)
        #expect(provider.current == Self.backyard, "the stream that already transcodes straightens its next picture")
        #expect(engine.runtimes[run.camera.id] === run.runtime, "not restarted")
        #expect(await run.handler.pipeline(session.sessionID) === pipeline)
        await session.receiver.stop()
        await run.fixture.tearDown()
    }

    /// A live view that passes the camera's stream through decides its path again as soon as the correction is turned on: it transcodes
    /// to straighten, in the same session, without a restart.
    @MainActor @Test(.timeLimit(.minutes(2))) func turningTheCorrectionOnRebuildsAPassthroughLiveViewOntoTheTranscode() async throws {
        let codecs = CorrectionCapturingCodecs(supportsPictureCorrection: true)
        let run = try await Self.runningCamera(codecs: codecs) { _ in }
        let engine = run.fixture.engine
        let logs = LiveLogCapture()
        defer { logs.stop() }
        let session = try await Self.startSession(run.handler)
        let pipeline = try #require(await run.handler.pipeline(session.sessionID))
        #expect(await session.receiver.waitFor(timeout: .seconds(8)) { $0.keyframes >= 1 })
        #expect(pipeline.videoPath == .passthrough && codecs.made.value.isEmpty)

        var edited = try #require(engine.configurations.first)
        edited.pictureCorrection = Self.backyard
        try await engine.updateCamera(edited, password: nil)
        #expect(await eventually(timeout: .seconds(10)) { pipeline.isTranscoding }, "\(logs.lines(of: session.sessionID))")
        #expect(pipeline.videoPath == .transcode("straightened picture"))
        #expect(codecs.made.value.last?.correction?.current == Self.backyard)
        #expect(logs.lines(of: session.sessionID).contains { $0.contains("rebuilding the video path") && $0.contains("picture correction was turned on") },
                "\(logs.lines(of: session.sessionID))")
        #expect(engine.runtimes[run.camera.id] === run.runtime, "the camera was not restarted")
        #expect(await run.handler.pipeline(session.sessionID) === pipeline, "the same session")
        let frames = await session.receiver.statistics.videoFrames
        #expect(await session.receiver.waitFor(timeout: .seconds(8)) { $0.videoFrames > frames + 10 }, "video still reaches Apple Home")
        await session.receiver.stop()
        await run.fixture.tearDown()
    }

    /// A transcode that was there only for the correction goes back to passing the camera's stream through when it is turned off.
    @MainActor @Test(.timeLimit(.minutes(2))) func turningTheCorrectionOffSendsACorrectionOnlyTranscodeBackToPassthrough() async throws {
        let codecs = CorrectionCapturingCodecs(supportsPictureCorrection: true)
        let run = try await Self.runningCamera(codecs: codecs) { $0.pictureCorrection = Self.backyard }
        let engine = run.fixture.engine
        let session = try await Self.startSession(run.handler)
        let pipeline = try #require(await run.handler.pipeline(session.sessionID))
        #expect(await eventually(timeout: .seconds(10)) { pipeline.isTranscoding })

        var edited = try #require(engine.configurations.first)
        edited.pictureCorrection = .off
        try await engine.updateCamera(edited, password: nil)
        #expect(await eventually(timeout: .seconds(10)) { pipeline.videoPath == .passthrough && !pipeline.isTranscoding })
        #expect(engine.runtimes[run.camera.id] === run.runtime, "the camera was not restarted")
        #expect(await run.handler.pipeline(session.sessionID) === pipeline, "the same session")
        let frames = await session.receiver.statistics.videoFrames
        #expect(await session.receiver.waitFor(timeout: .seconds(8)) { $0.videoFrames > frames + 10 }, "video still reaches Apple Home")
        await session.receiver.stop()
        await run.fixture.tearDown()
    }

    /// A switch while the live view's path is still being made is not lost: the decision checks the correction again once it is done.
    @Test(.timeLimit(.minutes(2))) func turningTheCorrectionOffWhileThePathIsBeingMadeIsNotLost() async throws {
        let correction = PictureCorrectionControl(Self.backyard, supported: true)
        let making = Box(false)
        let codecs = ScriptedCodecs { _, _, real in
            making.set(true)
            Thread.sleep(forTimeInterval: 1)   // off the cooperative threads (`CodecOffload`), as a slow ffmpeg start would be
            return try real()
        }
        let run = try await RuntimeLiveFailureTests.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil),
                                                        codecs: codecs, video: RuntimeLiveStreamTests.video(1280, 720), timing: .standard,
                                                        correction: correction)
        #expect(await eventually(timeout: .seconds(5)) { making.value }, "the transcoder for the correction is being made")
        // What `CameraRuntime.updatePictureCorrection` does. The path is not made yet, so the switch itself has nothing to rebuild.
        #expect(correction.update(.off))
        await run.setup.handler.pictureCorrectionSwitched()
        let pipeline = try #require(await run.setup.handler.pipeline(run.sessionID))
        #expect(await eventually(timeout: .seconds(10)) { pipeline.videoPath == .passthrough && !pipeline.isTranscoding }, "\(run.lines)")
        #expect(run.lines.contains { $0.contains("picture correction was turned off while the path was being made") }, "\(run.lines)")
        #expect(await run.receiver.waitFor(timeout: .seconds(8)) { $0.keyframes >= 1 }, "video reaches the controller")
        await run.finish()
    }

    // MARK: Snapshots of a running camera

    @MainActor @Test(.timeLimit(.minutes(2))) func theAppsTheWebsAndAppleHomesSnapshotsAreStraightened() async throws {
        let codecs = CorrectionCapturingCodecs(supportsPictureCorrection: true)
        let run = try await Self.runningCamera(codecs: codecs) { $0.pictureCorrection = Self.backyard }
        let mark = CorrectionCapturingCodecs.straightenedMark
        let engine = run.fixture.engine
        let straightened = try #require(await engine.snapshot(cameraID: run.camera.id))
        #expect(straightened.prefix(2) == Data([0xFF, 0xD8]) && straightened.suffix(mark.count) == mark, "the stills are straightened by default")
        let original = try #require(await engine.snapshot(cameraID: run.camera.id, original: true))
        #expect(original.prefix(2) == Data([0xFF, 0xD8]) && original.suffix(mark.count) != mark, "the camera's own picture when it is asked for")
        // Apple Home's tiles and notifications (the accessory's snapshot requests).
        let home = try await run.handler.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event))
        #expect(home.suffix(mark.count) == mark)
        #expect(!codecs.straightened.value.isEmpty && codecs.straightened.value.allSatisfy { $0 == Self.backyard })
        #expect(codecs.straightenedOn.value.count == codecs.straightened.value.count
                && codecs.straightenedOn.value.allSatisfy { $0 == CodecOffload.queueLabel }, "off the cooperative pool: \(codecs.straightenedOn.value)")
        await run.fixture.tearDown()
    }

    // MARK: HKSV recording

    @Test(.timeLimit(.minutes(3))) func aRecordingWithTheCorrectionOnTranscodesWithIt() async throws {
        let codecs = CorrectionCapturingCodecs(supportsPictureCorrection: true)
        let control = PictureCorrectionControl(Self.backyard, supported: true)
        let feeder = HubFeeder(source: syntheticSource(audio: nil))
        #expect(await feeder.waitUntilReady())
        try await Task.sleep(for: .seconds(1))
        let handler = RecordingHandler(hub: feeder.hub, codecs: codecs, cameraAudioEnabled: false, log: RuntimeRecordingTests.log, correction: control)
        // A 1280×720 Main selection: the 640×360 Main source fits and would pass through.
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(fragmentMs: 1000))
        await handler.updateRecordingAudioActive(true)
        let (packets, error) = await collect(try await handler.recordingStream(streamID: 5), limit: 4)
        #expect(error == nil)
        _ = try RuntimeRecordingTests.validate(packets, fragmentMs: 1000, expectAudio: true)
        let made = try #require(codecs.made.value.first)
        #expect(made.settings.width == 1280 && made.settings.height == 720)
        #expect(made.correction?.current == Self.backyard)
        await handler.closeRecordingStream(streamID: 5, reason: .normal)
        await feeder.stop()
    }

    /// Original When Possible with the correction on (the overlay off): the recording is transcoded at the camera's own size, not the
    /// smaller selection.
    @Test(.timeLimit(.minutes(3))) func aRecordingWithOriginalWhenPossibleKeepsTheCamerasSize() async throws {
        let codecs = CorrectionCapturingCodecs(supportsPictureCorrection: true)
        let control = PictureCorrectionControl(Self.backyard, supported: true)
        let feeder = HubFeeder(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil))
        #expect(await feeder.waitUntilReady())
        try await Task.sleep(for: .seconds(1))
        let handler = RecordingHandler(hub: feeder.hub, codecs: codecs, cameraAudioEnabled: false, log: RuntimeRecordingTests.log,
                                       qualityMode: .originalWhenPossible, correction: control)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(fragmentMs: 1000))
        await handler.updateRecordingAudioActive(true)
        let (packets, error) = await collect(try await handler.recordingStream(streamID: 6), limit: 3)
        #expect(error == nil && packets.count == 3)
        let made = try #require(codecs.made.value.first)
        #expect(made.settings.width == 640 && made.settings.height == 360, "the camera's own size, not the 1280×720 selection")
        #expect(made.settings.level == .auto)
        #expect(made.correction?.current == Self.backyard)
        await handler.closeRecordingStream(streamID: 6, reason: .normal)
        await feeder.stop()
    }
}
#endif

// MARK: Snapshots

/// `CorrectedSnapshots` over a `SnapshotProvider` whose camera API hands out `cameraPicture` as it is (no resizing, unless `sizeMarks`),
/// straightened by a stand-in for the codecs' `correctJPEG` that marks the bytes with the correction it was given and records every call.
extension PictureCorrectionEngineTests {
    final class SnapshotRig: Sendable {
        let cameraPicture = Box(Data([0xFF, 0xD8, 1]))
        /// How long the camera's snapshot API takes.
        let cameraDelay = Box(Duration.zero)
        /// Every call of the correction: the JPEG it was handed and the correction.
        let corrections = Box<[(jpeg: Data, correction: PictureCorrection)]>([])
        /// The correction throws while this is true.
        let fails = Box(false)
        /// The correction waits while this is true.
        let held = Box(false)
        /// The clock of the warnings' interval (it moves only when a test says so).
        let clock = Box(ContinuousClock.now)
        let control: PictureCorrectionControl
        let sink = RuntimeSnapshotTests.CapturingSink()
        let snapshots: CorrectedSnapshots

        /// `sizeMarks`: the provider's resizing appends "@W×H" (the pictures of two sizes differ, as a camera's do).
        init(_ correction: PictureCorrection, supported: Bool = true, timing: SnapshotProvider.Timing = SnapshotProvider.Timing(), sizeMarks: Bool = false) {
            control = PictureCorrectionControl(correction, supported: supported)
            let router = LogRouter()
            router.addSink(sink)
            let log = Log(category: "Snapshot", router: router)
            let picture = cameraPicture, delay = cameraDelay, corrections = corrections, fails = fails, held = held, clock = clock
            let provider = SnapshotProvider(cameraSnapshot: {
                try await Task.sleep(for: delay.value, tolerance: .zero)
                return picture.value
            }, resize: { jpeg, width, height in sizeMarks ? jpeg + Self.sizeMark(width ?? 0, height ?? 0) : jpeg },
                                            keyframeJPEG: { _, _, _ in throw SnapshotProvider.Failure.noPicture }, hub: MediaHub(), timing: timing, log: log)
            snapshots = CorrectedSnapshots(provider: provider, correction: control, log: log, now: { clock.value }) { jpeg, correction in
                corrections.update { $0.append((jpeg, correction)) }
                while held.value { try await Task.sleep(for: .milliseconds(5)) }
                if fails.value { throw MediaCodecError.unsupported("ffmpeg (snapshot straighten) exited with status 1") }
                return jpeg + Self.mark(correction)
            }
        }

        /// What the stand-in appends to a JPEG it straightened by `correction`.
        static func mark(_ correction: PictureCorrection) -> Data { Data(" straightened \(correction.straighten) \(correction.level)".utf8) }
        static func sizeMark(_ width: Int, _ height: Int) -> Data { Data("@\(width)x\(height)".utf8) }

        var warnings: [String] { sink.entries.value.filter { $0.level == .warning }.map(\.message) }
    }

    /// An event snapshot: the provider asks the camera again (no 10 s cache).
    static let event = SnapshotRequest(width: 1280, height: 720, reason: .event)

    @Test func snapshotsAreCorrectedUnlessTheOriginalIsAskedFor() async throws {
        let rig = SnapshotRig(Self.backyard)
        #expect(try await rig.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, 1]) + SnapshotRig.mark(Self.backyard))
        #expect(rig.corrections.value.map(\.jpeg) == [Data([0xFF, 0xD8, 1])] && rig.corrections.value.map(\.correction) == [Self.backyard])
        // The camera page asks for the camera's own picture (`?original=1`): it straightens it itself while its sliders move.
        #expect(try await rig.snapshots.snapshot(Self.event, original: true) == Data([0xFF, 0xD8, 1]))
        #expect(rig.corrections.value.count == 1, "the original runs no correction")
        #expect(try await rig.snapshots.snapshot(SnapshotRequest(width: 640, height: 360)) == Data([0xFF, 0xD8, 1]) + SnapshotRig.mark(Self.backyard))
        #expect(rig.warnings.isEmpty)
    }

    @Test func aCachedPictureIsNotReusedAfterTheCorrectionChanges() async throws {
        let rig = SnapshotRig(Self.backyard)
        let first = try await rig.snapshots.snapshot(Self.event)
        // The provider hands out the same JPEG (the camera has no newer picture): it is not straightened again.
        #expect(try await rig.snapshots.snapshot(Self.event) == first)
        #expect(rig.corrections.value.count == 1)
        // A new correction while it stays on (the slider moved): the same picture is straightened again, by the new value.
        let flatter = PictureCorrection(straighten: -0.20, level: 0.05)
        rig.control.update(flatter)
        #expect(try await rig.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, 1]) + SnapshotRig.mark(flatter))
        #expect(rig.corrections.value.count == 2 && rig.corrections.value.last?.jpeg == Data([0xFF, 0xD8, 1]) && rig.corrections.value.last?.correction == flatter)
        // A new picture from the camera is straightened too.
        rig.cameraPicture.set(Data([0xFF, 0xD8, 2]))
        #expect(try await rig.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, 2]) + SnapshotRig.mark(flatter))
        #expect(rig.corrections.value.count == 3)
    }

    @Test func eachSizeKeepsItsStraightenedPicture() async throws {
        // Apple Home's tiles (640×360) and the web (1280×720) ask for different sizes: neither pushes the other's picture out.
        let rig = SnapshotRig(Self.backyard, sizeMarks: true)
        let home = SnapshotRequest(width: 640, height: 360, reason: .event), web = SnapshotRequest(width: 1280, height: 720, reason: .event)
        for _ in 0..<3 {
            #expect(try await rig.snapshots.snapshot(home) == Data([0xFF, 0xD8, 1]) + SnapshotRig.sizeMark(640, 360) + SnapshotRig.mark(Self.backyard))
            #expect(try await rig.snapshots.snapshot(web) == Data([0xFF, 0xD8, 1]) + SnapshotRig.sizeMark(1280, 720) + SnapshotRig.mark(Self.backyard))
        }
        #expect(rig.corrections.value.count == 2)
        // A third size takes the place of the oldest (Apple Home's).
        _ = try await rig.snapshots.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event))
        _ = try await rig.snapshots.snapshot(web)
        #expect(rig.corrections.value.count == 3)
        _ = try await rig.snapshots.snapshot(home)
        #expect(rig.corrections.value.count == 4)
    }

    @Test func aFailedCorrectionServesTheOriginal() async throws {
        let rig = SnapshotRig(Self.backyard)
        rig.fails.set(true)
        #expect(try await rig.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, 1]), "the camera's picture rather than none")
        #expect(try await rig.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, 1]))
        #expect(rig.corrections.value.count == 2, "a failure is not kept: the next snapshot tries again")
        #expect(rig.warnings.count == 1, "\(rig.warnings)")
        #expect(rig.warnings.first?.contains("straighten") == true, "\(rig.warnings)")
        // Working again, then failing again within 30 s: no second warning (at most one every 30 s).
        rig.fails.set(false)
        #expect(try await rig.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, 1]) + SnapshotRig.mark(Self.backyard))
        rig.fails.set(true)
        rig.cameraPicture.set(Data([0xFF, 0xD8, 2]))
        #expect(try await rig.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, 2]))
        #expect(rig.warnings.count == 1, "\(rig.warnings)")
        rig.clock.update { $0 += .seconds(31) }
        rig.cameraPicture.set(Data([0xFF, 0xD8, 3]))
        #expect(try await rig.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, 3]))
        #expect(rig.warnings.count == 2, "\(rig.warnings)")
    }

    @Test func theBudgetIsTheProvidersOwn() {
        let timing = SnapshotProvider.Timing()
        #expect(timing.limit(for: .event) == .seconds(3) && timing.limit(for: .periodic) == .seconds(4) && timing.limit(for: nil) == .seconds(4))
        #expect(SnapshotProvider.Timing(budget: .seconds(2), eventBudget: .seconds(3)).limit(for: .event) == .seconds(2))
    }

    @Test(.timeLimit(.minutes(1))) func theCorrectionFitsInsideTheSnapshotsBudget() async throws {
        // An event snapshot answers within the provider's limit however long the camera took: the correction gets what is left, less
        // the margin. A 1 s event budget (Apple Home's is 3 s) keeps the margins far above the timers' slack.
        let timing = SnapshotProvider.Timing(eventBudget: .seconds(1))
        let limit = timing.limit(for: .event)
        let rig = SnapshotRig(Self.backyard, timing: timing)
        rig.cameraDelay.set(.milliseconds(500))
        rig.held.set(true)
        var started = ContinuousClock.now
        #expect(try await rig.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, 1]), "the camera's picture rather than a request held up")
        var took = ContinuousClock.now - started
        #expect(took >= .milliseconds(500) && took < limit, "\(took)")
        #expect(rig.corrections.value.count == 1, "the correction ran in what the camera left of the budget")
        #expect(rig.warnings.count == 1, "\(rig.warnings)")
        // A correction that finished meanwhile is handed out at once, even with nothing of the budget left: the camera is slower than
        // the provider's limit, which then serves its last picture (the same JPEG) at the limit.
        rig.held.set(false)
        rig.cameraDelay.set(.seconds(5))
        started = ContinuousClock.now
        #expect(try await rig.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, 1]) + SnapshotRig.mark(Self.backyard))
        took = ContinuousClock.now - started
        #expect(took >= limit && took < limit + .milliseconds(250), "\(took): the provider's answer, handed on at once")
        #expect(rig.corrections.value.count == 1, "nothing ran again")
    }

    @Test func oneCorrectionRunsAtATimeForACamera() async throws {
        // Each correction holds a thread while its ffmpeg runs: a camera never runs a second one beside it. A request for another
        // picture waits for the one running, within its budget, then gets the camera's picture.
        let rig = SnapshotRig(Self.backyard, timing: SnapshotProvider.Timing(budget: .milliseconds(500), eventBudget: .milliseconds(500)))
        rig.held.set(true)
        for picture in [1, 2, 3] as [UInt8] {
            rig.cameraPicture.set(Data([0xFF, 0xD8, picture]))
            let started = ContinuousClock.now
            #expect(try await rig.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, picture]))
            #expect(ContinuousClock.now - started < .milliseconds(500))
        }
        #expect(rig.corrections.value.count == 1, "\(rig.corrections.value.map(\.jpeg))")
        rig.held.set(false)
        #expect(await eventually { (try? await rig.snapshots.snapshot(Self.event)) == Data([0xFF, 0xD8, 3]) + SnapshotRig.mark(Self.backyard) })
        #expect(rig.corrections.value.map(\.jpeg) == [Data([0xFF, 0xD8, 1]), Data([0xFF, 0xD8, 3])])
        // A request that waited for another picture's correction gets its own picture straightened, never the other one.
        rig.held.set(true)
        rig.cameraPicture.set(Data([0xFF, 0xD8, 4]))
        let first = Task { try await rig.snapshots.snapshot(Self.event) }
        #expect(await eventually { rig.corrections.value.count == 3 })
        rig.cameraPicture.set(Data([0xFF, 0xD8, 5]))
        let second = Task { try await rig.snapshots.snapshot(Self.event) }
        try await Task.sleep(for: .milliseconds(50))
        rig.held.set(false)
        #expect(try await first.value == Data([0xFF, 0xD8, 4]) + SnapshotRig.mark(Self.backyard))
        #expect(try await second.value == Data([0xFF, 0xD8, 5]) + SnapshotRig.mark(Self.backyard))
        #expect(rig.corrections.value.count == 4)
    }

    @Test func aPictureMadeWithOldValuesIsNotHandedOutAfterAnEdit() async throws {
        let rig = SnapshotRig(Self.backyard)
        rig.held.set(true)
        let request = Task { try await rig.snapshots.snapshot(Self.event) }
        #expect(await eventually { rig.corrections.value.count == 1 })
        // The slider moves while the picture is being straightened by the old values: it is straightened once more, by the new ones.
        let flatter = PictureCorrection(straighten: -0.20, level: 0.05)
        rig.control.update(flatter)
        rig.held.set(false)
        #expect(try await request.value == Data([0xFF, 0xD8, 1]) + SnapshotRig.mark(flatter))
        #expect(rig.corrections.value.map(\.correction) == [Self.backyard, flatter])
    }

    @Test func aRequestGivenUpOnWhileItWaitsNeitherWarnsNorDropsTheRunningCorrection() async throws {
        let rig = SnapshotRig(Self.backyard)
        rig.held.set(true)
        let request = Task { try await rig.snapshots.snapshot(Self.event) }
        #expect(await eventually { rig.corrections.value.count == 1 })
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        rig.held.set(false)
        #expect(try await rig.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, 1]) + SnapshotRig.mark(Self.backyard))
        #expect(rig.corrections.value.count == 1 && rig.warnings.isEmpty, "\(rig.warnings)")
    }

    @Test(.timeLimit(.minutes(1))) func theCorrectionBlocksNoThreadOfTheCooperativePool() async throws {
        // The codecs' correctJPEG waits for an ffmpeg child. As many waiting corrections as the cooperative pool has threads (the box's four
        // also serve HomeKit and RTP) would leave nothing to run anything else on until they end; on threads of their own, other work goes on.
        let count = max(4, ProcessInfo.processInfo.activeProcessorCount)
        let entered = Box(0)
        let release = DispatchSemaphore(value: 0)
        let correct = CorrectedSnapshots.offloaded(deadline: .seconds(30)) { jpeg, _ in
            entered.update { $0 += 1 }
            _ = release.wait(timeout: .now() + 4)      // the ffmpeg child's stand-in; it ends by itself if the test fails
            return jpeg
        }
        let began = ContinuousClock.now
        let calls = (0..<count).map { _ in Task { try await correct(Data([0xFF, 0xD8, 1]), Self.backyard) } }
        let allInside = await eventually(timeout: .seconds(15)) { entered.value == count }
        let ranAt = await Task { ContinuousClock.now }.value      // any other work on the cooperative pool, while the corrections wait
        for _ in 0..<count { release.signal() }
        for call in calls { #expect(try await call.value == Data([0xFF, 0xD8, 1])) }
        #expect(allInside, "\(entered.value) of \(count) corrections were waiting at once")
        // On the pool, this test's own wait and the other work could only go on once the stand-ins gave up (4 s).
        #expect(ranAt - began < .seconds(3), "other work waited \(ranAt - began) for a thread of the cooperative pool")
    }

    @Test(.timeLimit(.minutes(1))) func aCorrectionPastItsDeadlineIsAbandoned() async throws {
        let release = DispatchSemaphore(value: 0)
        let correct = CorrectedSnapshots.offloaded(deadline: .milliseconds(200)) { jpeg, _ in
            release.wait()
            return jpeg
        }
        let started = ContinuousClock.now
        await #expect(throws: DeadlineExceeded.self) { _ = try await correct(Data([0xFF, 0xD8, 1]), Self.backyard) }
        #expect(ContinuousClock.now - started < .seconds(3), "given up at the deadline, not when the thread is free")
        release.signal()
        // The ffmpeg child is stopped at the codecs' own limit; the engine gives up on the call a little later.
        #expect(CorrectedSnapshots.deadline > PictureCorrection.snapshotTimeout && CorrectedSnapshots.deadline < PictureCorrection.snapshotTimeout + .seconds(3))
    }

    @Test func offNeverRunsTheCorrection() async throws {
        let off = SnapshotRig(.off)
        #expect(try await off.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, 1]))
        // Codecs that cannot straighten (the Mac's): off everywhere, snapshots included.
        let unsupported = SnapshotRig(Self.backyard, supported: false)
        #expect(try await unsupported.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, 1]))
        // Turned off after it was on.
        let turnedOff = SnapshotRig(Self.backyard)
        _ = try await turnedOff.snapshots.snapshot(Self.event)
        turnedOff.control.update(.off)
        #expect(try await turnedOff.snapshots.snapshot(Self.event) == Data([0xFF, 0xD8, 1]))
        #expect(off.corrections.value.isEmpty && unsupported.corrections.value.isEmpty && turnedOff.corrections.value.count == 1)
    }
}
