#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import MediaCore
import PlatformApple
import RTP
import Synchronization
import Testing
import TestSupport
@testable import BridgeEngine

/// What a scripted transcoder does instead of (or before) the real one.
final class ScriptedTranscoder: VideoTranscoding {
    struct Script: Sendable {
        var transcode: @Sendable (_ call: Int, _ frame: EncodedVideoFrame, _ real: any VideoTranscoding) async throws -> [EncodedVideoFrame]
        var catchUp: @Sendable (_ frames: [EncodedVideoFrame], _ real: any VideoTranscoding) async throws -> [EncodedVideoFrame]
        var invalidate: @Sendable (_ real: any VideoTranscoding) -> Void

        static let real = Script(transcode: { _, frame, real in try await real.transcode(frame) },
                                 catchUp: { frames, real in try await real.catchUp(frames) }, invalidate: { $0.invalidate() })
    }

    let real: any VideoTranscoding
    let script: Script
    let calls = Box(0)
    let softwareRequests = Box(0)
    let invalidations = Box(0)

    init(real: any VideoTranscoding, script: Script) {
        self.real = real
        self.script = script
    }

    func transcode(_ frame: EncodedVideoFrame) async throws -> [EncodedVideoFrame] {
        let call = calls.value + 1
        calls.set(call)
        return try await script.transcode(call, frame, real)
    }

    func catchUp(_ frames: [EncodedVideoFrame]) async throws -> [EncodedVideoFrame] { try await script.catchUp(frames, real) }
    func requestKeyframe() { real.requestKeyframe() }
    func updateBitrate(kbps: Int) { real.updateBitrate(kbps: kbps) }
    func invalidate() {
        invalidations.update { $0 += 1 }
        script.invalidate(real)
    }
    var diagnostics: TranscoderDiagnostics { real.diagnostics }
    func preferSoftwareDecoding() {
        softwareRequests.update { $0 += 1 }
        real.preferSoftwareDecoding()
    }
}

/// `AppleMediaCodecs` whose video transcoders are made by `make` (creation index from 0; `real` makes the real one) and whose
/// probe decoder may be replaced.
struct ScriptedCodecs: MediaCodecs {
    struct Injected: Error {}

    let base = AppleMediaCodecs()
    let creations = Box(0)
    let made = Box<[ScriptedTranscoder]>([])
    var make: @Sendable (_ index: Int, _ settings: VideoEncoderSettings, _ real: () throws -> any VideoTranscoding) throws -> any VideoTranscoding
    var probeDecoder: (@Sendable (VideoFormat) throws -> any VideoDecoding)?

    init(make: @escaping @Sendable (Int, VideoEncoderSettings, () throws -> any VideoTranscoding) throws -> any VideoTranscoding) {
        self.make = make
    }

    /// Every transcoder is the real one wrapped in `script`.
    static func scripted(_ script: ScriptedTranscoder.Script) -> ScriptedCodecs {
        ScriptedCodecs { _, _, real in ScriptedTranscoder(real: try real(), script: script) }
    }

    func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding { try base.makeVideoDecoder(format: format) }
    func makeProbeDecoder(format: VideoFormat) throws -> any VideoDecoding {
        if let probeDecoder { return try probeDecoder(format) }
        return try base.makeProbeDecoder(format: format)
    }
    func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { try base.makeVideoEncoder(settings: settings) }
    func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding {
        let index = creations.value
        creations.set(index + 1)
        let transcoder = try make(index, output) { try base.makeVideoTranscoder(output: output) }
        if let scripted = transcoder as? ScriptedTranscoder { made.update { $0.append(scripted) } }
        return transcoder
    }
    func makeVideoTranscoder(output: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)?) throws -> any VideoTranscoding {
        let index = creations.value
        creations.set(index + 1)
        let transcoder = try make(index, output) { try base.makeVideoTranscoder(output: output, overlay: overlay) }
        if let scripted = transcoder as? ScriptedTranscoder { made.update { $0.append(scripted) } }
        return transcoder
    }
    func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding {
        try base.makeAudioTranscoder(input: input, output: output)
    }
    func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data {
        try base.jpeg(from: frame, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality)
    }
    func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data { try base.resizeJPEG(jpeg, maxWidth: maxWidth, maxHeight: maxHeight) }
    func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] {
        try base.silentAACFrames(duration: duration, sampleRate: sampleRate, channels: channels, startPTS: startPTS, wallClock: wallClock)
    }
    func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration, audio: AudioCodec?,
                             audioSampleRate: Int) -> any MediaSource {
        base.makeSyntheticSource(displayName: displayName, width: width, height: height, fps: fps, keyframeInterval: keyframeInterval,
                                 audio: audio, audioSampleRate: audioSampleRate)
    }
}

/// Log lines of the sessions under test (the sink sees every test's lines; `lines(of:)` keeps one session's).
final class LiveLogCapture: LogSink {
    private let entries = Mutex<[LogEntry]>([])
    private let token = Mutex<LogSinkToken?>(nil)

    init() {
        token.withLock { $0 = LogHub.addSink(self) }
    }

    func stop() {
        if let existing = token.withLock({ value -> LogSinkToken? in defer { value = nil }; return value }) { LogHub.removeSink(existing) }
    }

    func record(_ entry: LogEntry) {
        entries.withLock { $0.append(entry) }
    }

    /// Warning-or-worse lines of `category` that contain `text`.
    func matching(category: String, containing text: String, minimum: LogLevel = .warning) -> [String] {
        entries.withLock { $0.filter { $0.category == category && $0.level >= minimum && $0.message.contains(text) }.map(\.message) }
    }

    /// Every line of at least `minimum` level that contains `text` (lines the session's tag is not on).
    func lines(containing text: String, minimum: LogLevel = .info) -> [String] {
        entries.withLock { $0.filter { $0.level >= minimum && $0.message.contains(text) }.map(\.message) }
    }

    /// Lines that mention the session (the pipeline tags its own with the first 8 characters of its id).
    func lines(of session: UUID, minimum: LogLevel = .debug) -> [String] {
        let tag = String(session.uuidString.prefix(8))
        return entries.withLock { $0.filter { $0.level >= minimum && $0.message.contains(tag) }.map { "\($0.level): \($0.message)" } }
    }
}

/// Live view failures that used to break it silently (audit 2 F1-F9): each ends in one clear log line and a stream that
/// recovers or ends, so Home retries instead of spinning or freezing. Timings are shortened; the ladders are the production ones.
@Suite(.serialized) struct RuntimeLiveFailureTests {
    /// Recovery at 0.6 s, end at 2 s, tick 100 ms.
    static let fast: LiveStreamTiming = {
        var timing = LiveStreamTiming()
        timing.tick = .milliseconds(100)
        timing.recoverAfter = .milliseconds(600)
        timing.endAtStart = .seconds(2)
        timing.endAtStall = .seconds(2)
        timing.creationBackoff = [.milliseconds(30), .milliseconds(30), .milliseconds(30)]
        timing.failureEnd = .seconds(1)
        timing.rebuildSpacing = .milliseconds(100)
        timing.transcodeDeadline = .milliseconds(600)
        timing.catchUpDeadline = .seconds(5)
        timing.probeDeadline = .seconds(3)
        timing.cameraKeyframeSpacing = .seconds(30)
        return timing
    }()

    /// A stream the pipeline ended, as `StreamingHandler` reports it to HAP (`sessionEnder`).
    final class Ended: Sendable {
        let sessions = Box<[UUID]>([])
        func record(_ id: UUID) { sessions.update { $0.append(id) } }
    }

    struct Run {
        let setup: RuntimeLiveStreamTests.Setup
        let receiver: SRTPTestReceiver
        let sessionID: UUID
        let ended: Ended
        let logs: LiveLogCapture

        var lines: [String] { logs.lines(of: sessionID) }

        func finish() async {
            await setup.handler.stopAll()
            await receiver.stop()
            await setup.feeder.stop()
            logs.stop()
        }
    }

    /// Prepares and starts one session on `source` (`video` is the request).
    static func run(source: any MediaSource, codecs: any MediaCodecs, video: SelectedVideoParameters, timing: LiveStreamTiming = fast,
                    hub: MediaHub = MediaHub(), cameraKeyframe: (@Sendable (Bool) async -> Void)? = nil, selfCheck: Bool = false,
                    overlay: TimestampOverlayControl? = nil, waitUntilReady: Bool = true) async throws -> Run {
        let logs = LiveLogCapture()
        let setup = RuntimeLiveStreamTests.setup(source: source, hub: hub, controllerWait: .zero, codecs: codecs, overlay: overlay, timing: timing,
                                                 cameraKeyframe: cameraKeyframe, selfCheck: selfCheck)
        if waitUntilReady { #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15))) }
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await RuntimeLiveStreamTests.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await RuntimeLiveStreamTests.connect(receiver, to: response)
        let ended = Ended()
        await setup.handler.setSessionEnder { id in
            ended.record(id)
            return true
        }
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: video, audio: nil))
        return Run(setup: setup, receiver: receiver, sessionID: sessionID, ended: ended, logs: logs)
    }

    // MARK: F2: the transcoder ladder

    /// HEVC cannot go to a controller as it is (the session drops it): a transcoder that cannot be made ends the stream.
    @Test(.timeLimit(.minutes(2))) func transcoderCreationFailureNeverPassesThroughHEVC() async throws {
        let hevc = VideoFormat(codec: .hevc, width: 1920, height: 1080, parameterSets: [Data([0x40, 1, 1]), Data([0x42, 1, 1]), Data([0x44, 1])])
        var frames: [EncodedVideoFrame] = []
        for index in 0..<45 {
            let header: [UInt8] = [index == 0 ? 0x26 : 0x02, 1, UInt8(index)]
            let nal = Data(header + [UInt8](repeating: 7, count: 500))
            frames.append(EncodedVideoFrame(format: hevc, nalUnits: [nal], isKeyframe: index == 0, pts: MediaTime(value: Int64(index * 6_000), timescale: 90_000),
                                            wallClock: Date()))
        }
        let codecs = ScriptedCodecs { _, _, _ in throw ScriptedCodecs.Injected() }
        let run = try await Self.run(source: PacedFrameSource(frames: frames, fps: 15), codecs: codecs, video: RuntimeLiveStreamTests.video(1280, 720), waitUntilReady: false)
        #expect(await eventually(timeout: .seconds(8)) { run.ended.sessions.value.contains(run.sessionID) }, "the stream ends: \(run.lines)")
        let pipeline = await run.setup.handler.pipeline(run.sessionID)
        #expect(pipeline?.endedByPipelineReason?.contains("could not be built after 4 attempts") == true, "\(pipeline?.endedByPipelineReason ?? "no reason")")
        #expect(codecs.creations.value == 4, "one try and three retries with a backoff: \(codecs.creations.value)")
        let stats = await run.receiver.statistics
        #expect(stats.videoFrames == 0, "no HEVC went out as if it were H.264")
        #expect(run.lines.contains { $0.contains("could not be made") && $0.contains("trying again") })
        #expect(run.lines.filter { $0.hasPrefix("error") }.count >= 2, "the give-up and the ending are each one line: \(run.lines)")
        await run.finish()
    }

    @Test(.timeLimit(.minutes(2))) func anOverlayStreamWhoseTranscoderCannotBeMadeEndsInsteadOfSendingThePlainPicture() async throws {
        let codecs = ScriptedCodecs { _, _, _ in throw ScriptedCodecs.Injected() }
        let overlay = TimestampOverlayControl(settings: RuntimeTimestampOverlayTests.on, cameraName: "Porch")
        let run = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), codecs: codecs,
                                     video: RuntimeLiveStreamTests.video(1280, 720), overlay: overlay)
        #expect(await eventually(timeout: .seconds(8)) { run.ended.sessions.value.contains(run.sessionID) })
        #expect(await run.receiver.statistics.videoFrames == 0, "the picture without its overlay was not sent")
        await run.finish()
    }

    /// The camera's own stream stands in only when it fits what the controller asked for and nothing has to be drawn on it:
    /// here the transcode was only for a long GOP (150+ frames since the camera's last keyframe).
    @Test(.timeLimit(.minutes(2))) func aTranscodeChosenOnlyForALongGOPFallsBackToThePassthroughThatFits() async throws {
        let codecs = ScriptedCodecs { _, _, _ in throw ScriptedCodecs.Injected() }
        let hub = MediaHub()
        let feeder = HubFeeder(source: syntheticSource(width: 640, height: 360, fps: 30, gop: .seconds(20), audio: nil), hub: hub)
        let ready = await eventually(timeout: .seconds(30)) { await hub.lastKeyframe != nil }
        #expect(ready)
        // Wait until the newest GOP is longer than a passthrough bursts (90 frames).
        let longGOP = await eventually(timeout: .seconds(20)) {
            let probe = await hub.subscribe(from: .prebuffer(.zero), bufferLimit: 1)
            defer { probe.cancel() }
            return probe.replayCount > LiveStreamPipeline.maximumPassthroughReplayFrames
        }
        #expect(longGOP)
        let run = try await Self.run(source: PacedFrameSource(frames: [], fps: 1), codecs: codecs, video: RuntimeLiveStreamTests.video(1280, 720), hub: hub,
                                     waitUntilReady: false)
        #expect(await eventually(timeout: .seconds(10)) { await run.receiver.statistics.videoFrames > 0 })
        let pipeline = try #require(await run.setup.handler.pipeline(run.sessionID))
        #expect(pipeline.endedByPipelineReason == nil)
        #expect(pipeline.videoPath == .passthrough)
        #expect(run.lines.contains { $0.contains("cannot be transcoded") && $0.contains("sent as it is") }, "\(run.lines)")
        #expect(codecs.creations.value == 4, "the transcoder was tried with the backoff first")
        await feeder.stop()
        await run.finish()
    }

    @Test(.timeLimit(.minutes(2))) func aTranscoderThatThrowsEveryFrameIsRebuiltThenTheSessionEnds() async throws {
        let failing = ScriptedTranscoder.Script(transcode: { _, _, _ in throw ScriptedCodecs.Injected() },
                                                catchUp: { frames, real in try await real.catchUp(frames) }, invalidate: { $0.invalidate() })
        let codecs = ScriptedCodecs.scripted(failing)
        let run = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), codecs: codecs,
                                     video: RuntimeLiveStreamTests.video(320, 240, fps: 15, bitrate: 200))
        // The catch-up gives a first picture; every later frame fails.
        #expect(await eventually(timeout: .seconds(10)) { run.ended.sessions.value.contains(run.sessionID) }, "ends: \(run.lines)")
        #expect(codecs.creations.value >= 2, "rebuilt at least once before it gave up: \(codecs.creations.value) transcoders")
        #expect(codecs.creations.value <= 12, "not a transcoder per frame: \(codecs.creations.value)")
        let warnings = run.lines.filter { $0.hasPrefix("warning") }
        #expect(warnings.contains { $0.contains("failed for a frame") }, "\(warnings)")
        #expect(warnings.filter { $0.contains("failed for a frame") }.count == 1, "the per-frame failure is one line, not one per frame")
        #expect(run.lines.contains { $0.contains("without producing a frame") }, "\(run.lines)")
        await run.finish()
    }

    /// A GOP of one frame makes every frame a keyframe: the failing frames are keyframes, so the rebuilt transcoder is told
    /// to decode in software.
    @Test(.timeLimit(.minutes(2))) func aKeyframeDecodeFailureRebuildsWithASoftwareDecoder() async throws {
        let codecs = ScriptedCodecs { index, _, real in
            let script = ScriptedTranscoder.Script(transcode: { _, frame, real in
                if index == 0 { throw ScriptedCodecs.Injected() }
                return try await real.transcode(frame)
            }, catchUp: { frames, real in try await real.catchUp(frames) }, invalidate: { $0.invalidate() })
            return ScriptedTranscoder(real: try real(), script: script)
        }
        let run = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .milliseconds(60), audio: nil), codecs: codecs,
                                     video: RuntimeLiveStreamTests.video(320, 240, fps: 15, bitrate: 200))
        #expect(await eventually(timeout: .seconds(8)) { codecs.made.value.count >= 2 })
        let second = codecs.made.value[1]
        #expect(second.softwareRequests.value >= 1, "the transcoder made after a keyframe failure decodes in software")
        #expect(await eventually(timeout: .seconds(8)) { await run.receiver.statistics.videoFrames >= 10 }, "and the stream carries on")
        #expect(run.ended.sessions.value.isEmpty)
        await run.finish()
    }

    // MARK: F3: the watchdog

    /// The transcoder returns nothing for ever (a dropped-frame encoder, a decoder waiting for a keyframe) while the camera
    /// delivers: the pipeline forces a keyframe and rebuilds the transcoder at the recovery time, then ends the stream.
    @Test(.timeLimit(.minutes(2))) func aTranscoderThatReturnsNothingIsRecoveredThenTheSessionEnds() async throws {
        let silent = ScriptedTranscoder.Script(transcode: { _, _, _ in [] }, catchUp: { _, _ in [] }, invalidate: { $0.invalidate() })
        let codecs = ScriptedCodecs.scripted(silent)
        let run = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), codecs: codecs,
                                     video: RuntimeLiveStreamTests.video(320, 240, fps: 15, bitrate: 200))
        let began = ContinuousClock.now
        #expect(await eventually(timeout: .seconds(10)) { run.ended.sessions.value.contains(run.sessionID) }, "ends: \(run.lines)")
        let took = ContinuousClock.now - began
        #expect(took >= .milliseconds(1_500) && took < .seconds(6), "ended after the start limit (2 s): \(took)")
        #expect(codecs.creations.value >= 2, "the transcoder was rebuilt first")
        #expect(run.lines.contains { $0.contains("no picture") && $0.contains("forcing a keyframe and rebuilding the transcoder") }, "\(run.lines)")
        #expect(run.lines.contains { $0.contains("rebuilding the video path") })
        #expect(run.lines.contains { $0.contains("ending it") && $0.contains("Home will start it again") })
        #expect(await run.receiver.statistics.videoFrames == 0)
        let pipeline = try #require(await run.setup.handler.pipeline(run.sessionID))
        #expect(pipeline.healthSummary.hasPrefix("ended"))
        await run.finish()
    }

    /// A camera that never delivers a frame: the stream ends within the start limit with its own reason.
    @Test(.timeLimit(.minutes(2))) func aHubThatNeverGetsAFrameEndsTheSessionWithinTheStartLimit() async throws {
        let run = try await Self.run(source: PacedFrameSource(frames: [], fps: 1), codecs: AppleMediaCodecs(), video: RuntimeLiveStreamTests.video(320, 240),
                                     waitUntilReady: false)
        let began = ContinuousClock.now
        #expect(await eventually(timeout: .seconds(8)) { run.ended.sessions.value.contains(run.sessionID) })
        #expect(ContinuousClock.now - began < .seconds(4))
        let pipeline = try #require(await run.setup.handler.pipeline(run.sessionID))
        #expect(pipeline.endedByPipelineReason?.contains("camera delivered no picture") == true)
        #expect(run.lines.contains { $0.contains("waiting for it") }, "told that it waits for the camera: \(run.lines)")
        await run.finish()
    }

    /// A transcoder that never answers a call: abandoned after the deadline, a new one is built, the stream goes on.
    @Test(.timeLimit(.minutes(2))) func aWedgedTranscoderIsAbandonedAndTheStreamGoesOnWithANewOne() async throws {
        let codecs = ScriptedCodecs { index, _, real in
            let script = ScriptedTranscoder.Script(transcode: { call, frame, real in
                if index == 0, call >= 4 {   // a VideoToolbox call that never returns, ignoring cancellation
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                }
                return try await real.transcode(frame)
            }, catchUp: { frames, real in try await real.catchUp(frames) }, invalidate: { $0.invalidate() })
            return ScriptedTranscoder(real: try real(), script: script)
        }
        let run = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), codecs: codecs,
                                     video: RuntimeLiveStreamTests.video(320, 240, fps: 15, bitrate: 200))
        #expect(await eventually(timeout: .seconds(8)) { codecs.creations.value >= 2 }, "\(run.lines)")
        let frames = await run.receiver.statistics.videoFrames
        #expect(await eventually(timeout: .seconds(8)) { await run.receiver.statistics.videoFrames >= frames + 15 }, "video goes on after the wedge")
        #expect(run.lines.contains { $0.contains("did not answer") && $0.contains("abandoning it") })
        #expect(run.ended.sessions.value.isEmpty)
        await run.finish()
    }

    /// F7: tearing a transcoder down can block for as long as a call inside it does: `stop()` never waits for it.
    @Test(.timeLimit(.minutes(2))) func stopDoesNotWaitForATranscoderWhoseInvalidateBlocks() async throws {
        let blocking = ScriptedTranscoder.Script(transcode: { _, frame, real in try await real.transcode(frame) },
                                                 catchUp: { frames, real in try await real.catchUp(frames) },
                                                 invalidate: { real in
                                                     Thread.sleep(forTimeInterval: 5)
                                                     real.invalidate()
                                                 })
        let codecs = ScriptedCodecs.scripted(blocking)
        let run = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), codecs: codecs,
                                     video: RuntimeLiveStreamTests.video(320, 240, fps: 15, bitrate: 200))
        #expect(await run.receiver.waitFor(timeout: .seconds(5)) { $0.videoFrames >= 5 })
        let began = ContinuousClock.now
        try await run.setup.handler.handleStreamRequest(.stop(sessionID: run.sessionID))
        let took = ContinuousClock.now - began
        #expect(took < .milliseconds(500), "stop took \(took)")
        #expect(await eventually(timeout: .seconds(2)) { codecs.made.value.first?.invalidations.value == 1 }, "the teardown was started anyway")
        await run.finish()
    }

    // MARK: F8, F6

    /// F8: a new picture size takes effect from the hub's newest GOP at once, not at the camera's next keyframe, which a 10 s
    /// GOP puts seconds away.
    @Test(.timeLimit(.minutes(3))) func aReconfiguredSizeReachesTheControllerWithinASecondWhateverTheCamerasGOP() async throws {
        let run = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(10), audio: nil), codecs: AppleMediaCodecs(),
                                     video: RuntimeLiveStreamTests.video(480, 270, fps: 15, bitrate: 400), timing: .standard)
        let sizes = RuntimeLiveStreamTests.SPSSizes(run.receiver)
        #expect(await run.receiver.waitFor(timeout: .seconds(10)) { $0.keyframes >= 1 && $0.videoFrames >= 5 })
        // Let the camera's GOP run a few seconds so the next source keyframe is far off.
        try await Task.sleep(for: .seconds(3))
        let asked = ContinuousClock.now
        try await run.setup.handler.handleStreamRequest(.reconfigure(sessionID: run.sessionID, video: RuntimeLiveStreamTests.video(320, 180, fps: 15, bitrate: 200)))
        #expect(await eventually(timeout: .seconds(4)) { sizes.sizes.value.last == "320×180" }, "sizes seen: \(sizes.sizes.value)")
        #expect(ContinuousClock.now - asked < .seconds(1.5), "the new size took \(ContinuousClock.now - asked)")
        sizes.stop()
        await run.finish()
    }

    /// F6: a passthrough stream cannot make a keyframe: the controller's second PLI in 10 s switches it to transcoding, and
    /// the camera is asked for a keyframe through the adapter's call.
    @Test(.timeLimit(.minutes(3))) func aPassthroughStreamSwitchesToTranscodingAfterTwoKeyframeRequests() async throws {
        let asked = Box<[Bool]>([])
        let run = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(8), audio: nil), codecs: AppleMediaCodecs(),
                                     video: RuntimeLiveStreamTests.video(1280, 720, fps: 15), timing: .standard, cameraKeyframe: { isSub in asked.update { $0.append(isSub) } })
        let pipeline = try #require(await run.setup.handler.pipeline(run.sessionID))
        #expect(await run.receiver.waitFor(timeout: .seconds(10)) { $0.keyframes >= 1 })
        #expect(pipeline.videoPath == .passthrough && !pipeline.isTranscoding)
        await run.receiver.requestKeyframe()
        #expect(await eventually(timeout: .seconds(3)) { !asked.value.isEmpty }, "the first request asks the camera")
        #expect(pipeline.videoPath == .passthrough, "one request is not enough")
        try await Task.sleep(for: .milliseconds(300))
        await run.receiver.requestKeyframe()
        #expect(await eventually(timeout: .seconds(8)) { pipeline.isTranscoding }, "two requests in 10 s: transcoding now")
        let keyframes = await run.receiver.statistics.keyframes
        #expect(await run.receiver.waitFor(timeout: .seconds(5)) { $0.keyframes > keyframes }, "and the transcoder answers with a keyframe of its own")
        #expect(asked.value == [false], "the camera was asked once (the main stream)")
        #expect(run.lines.contains { $0.contains("switching to transcoding") })
        await run.finish()
    }

    /// F6: a camera GOP longer than ~60 frames or 2 s is worked around: the stream starts from the replay at once and the camera
    /// is asked for a keyframe, once.
    @Test(.timeLimit(.minutes(3))) func aLongCameraGOPAsksTheCameraForAKeyframeOnce() async throws {
        let asked = Box<[Bool]>([])
        let hub = MediaHub()
        let feeder = HubFeeder(source: syntheticSource(width: 640, height: 360, fps: 30, gop: .seconds(6), audio: nil), hub: hub)
        #expect(await feeder.waitUntilReady(timeout: .seconds(20)))
        // Let the GOP grow past 60 frames.
        _ = await eventually(timeout: .seconds(10)) { await hub.measuredFrameRate != nil }
        try await Task.sleep(for: .seconds(3))
        let logs = LiveLogCapture()
        let setup = RuntimeLiveStreamTests.setup(source: syntheticSource(width: 320, height: 180, fps: 5, gop: .seconds(10), audio: nil), hub: hub,
                                                 controllerWait: .zero, timing: .standard, cameraKeyframe: { isSub in asked.update { $0.append(isSub) } })
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await RuntimeLiveStreamTests.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await RuntimeLiveStreamTests.connect(receiver, to: response)
        let began = ContinuousClock.now
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: RuntimeLiveStreamTests.video(320, 240, fps: 15, bitrate: 300), audio: nil))
        #expect(await receiver.waitFor(timeout: .seconds(8)) { $0.keyframes >= 1 })
        #expect(ContinuousClock.now - began < .seconds(3), "the first picture does not wait for the camera's next keyframe")
        #expect(asked.value == [false], "asked once: \(asked.value)")
        #expect(logs.lines(of: sessionID).contains { $0.contains("asking the camera for a fresh keyframe") && $0.contains("long") })
        await setup.handler.stopAll()
        await receiver.stop()
        await feeder.stop()
        await setup.feeder.stop()
        logs.stop()
    }

    /// A driver that answers keyframe requests as scripted.
    final class KeyframeDriver: CameraDriver {
        let vendor: CameraVendor = .hikvision
        let requests = Box<[Bool]>([])
        let answer: Box<(any Error)?>
        init(answer: (any Error)? = nil) { self.answer = Box(answer) }
        func probe() async throws -> CameraProbeResult { throw CameraAdapterError.unsupported("not probed") }
        func makeEventSource() -> (any CameraEventSource)? { nil }
        func snapshot() async throws -> Data? { nil }
        func makeTalkbackSink() -> (any TalkbackSink)? { nil }
        func requestKeyframe(subStream: Bool) async throws {
            requests.update { $0.append(subStream) }
            if let error = answer.value { throw error }
        }
    }

    @Test func theCameraKeyframeHelperAsksOnceAndStaysQuietWhenTheCameraCannotOrIsAway() async {
        let working = KeyframeDriver()
        let ask = LiveStreamPipeline.cameraKeyframeRequest(driver: working, log: Self.logForHelper)
        await ask(false)
        await ask(true)
        #expect(working.requests.value == [false, true])

        let away = KeyframeDriver()
        await LiveStreamPipeline.cameraKeyframeRequest(driver: away, isOffline: { true }, log: Self.logForHelper)(false)
        #expect(away.requests.value.isEmpty, "nothing is sent to a camera that answers nothing")

        // Neither an unsupported call nor a refused login is retried by the helper, and neither escapes it.
        for error in [CameraAdapterError.unsupported("none"), CameraAdapterError.unauthorized, CameraAdapterError.lockedOut(until: Date().addingTimeInterval(60))] {
            let refusing = KeyframeDriver(answer: error)
            await LiveStreamPipeline.cameraKeyframeRequest(driver: refusing, log: Self.logForHelper)(false)
            #expect(refusing.requests.value == [false], "\(error): asked once")
        }
    }

    private static let logForHelper = Log(category: "KeyframeHelperTest")

    // MARK: Self-check

    @Test(.timeLimit(.minutes(2))) func theSelfCheckPassesAHealthyStreamAndSaysSoOnce() async throws {
        let run = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), codecs: AppleMediaCodecs(),
                                     video: RuntimeLiveStreamTests.video(320, 240, fps: 15, bitrate: 300), timing: .standard, selfCheck: true)
        #expect(await eventually(timeout: .seconds(15)) { run.lines.contains { $0.contains("self-check passed") } }, "\(run.lines)")
        #expect(run.lines.filter { $0.hasPrefix("info") && $0.contains("self-check passed") }.count == 1, "later passes are debug lines")
        #expect(run.ended.sessions.value.isEmpty)
        let pipeline = try #require(await run.setup.handler.pipeline(run.sessionID))
        #expect(pipeline.healthSummary == "ok")
        await run.finish()
    }

    /// Keyframes whose slice data is garbage: the stream is useless to a controller. Two probes in a row fail and it ends.
    @Test(.timeLimit(.minutes(2))) func aStreamOfBrokenKeyframesFailsTheSelfCheckAndEnds() async throws {
        let tampering = ScriptedTranscoder.Script(transcode: { _, frame, real in try await real.transcode(frame).map(Self.corrupted) },
                                                  catchUp: { frames, real in try await real.catchUp(frames).map(Self.corrupted) }, invalidate: { $0.invalidate() })
        let codecs = ScriptedCodecs.scripted(tampering)
        let run = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), codecs: codecs,
                                     video: RuntimeLiveStreamTests.video(320, 240, fps: 15, bitrate: 300), timing: Self.slowRecovery, selfCheck: true)
        #expect(await eventually(timeout: .seconds(25)) { run.ended.sessions.value.contains(run.sessionID) }, "\(run.lines)")
        #expect(run.lines.contains { $0.contains("live self-check FAILED") }, "\(run.lines)")
        let pipeline = try #require(await run.setup.handler.pipeline(run.sessionID))
        #expect(pipeline.endedByPipelineReason?.contains("self-check") == true)
        await run.finish()
    }

    /// A keyframe whose SPS says another size than the controller selected: no controller could show it: the stream ends at once.
    @Test(.timeLimit(.minutes(2))) func aKeyframeOfTheWrongSizeEndsTheStreamAtOnce() async throws {
        let wrong = ScriptedTranscoder.Script(transcode: { _, frame, real in try await real.transcode(frame).map(Self.resized) },
                                              catchUp: { frames, real in try await real.catchUp(frames).map(Self.resized) }, invalidate: { $0.invalidate() })
        let run = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), codecs: ScriptedCodecs.scripted(wrong),
                                     video: RuntimeLiveStreamTests.video(320, 240, fps: 15, bitrate: 300), timing: Self.slowRecovery, selfCheck: true)
        #expect(await eventually(timeout: .seconds(25)) { run.ended.sessions.value.contains(run.sessionID) }, "\(run.lines)")
        let pipeline = try #require(await run.setup.handler.pipeline(run.sessionID))
        #expect(pipeline.endedByPipelineReason?.contains("not the 320×240 the controller selected") == true, "\(pipeline.endedByPipelineReason ?? "")")
        await run.finish()
    }

    /// The probe itself failing or being slow never touches the stream: no decoder → inconclusive; a decoder that takes ten
    /// times the deadline → inconclusive; video flows throughout.
    @Test(.timeLimit(.minutes(2))) func aProbeThatCannotRunOrIsSlowNeverAffectsTheStream() async throws {
        var codecs = ScriptedCodecs.scripted(.real)
        codecs.probeDecoder = { _ in throw ScriptedCodecs.Injected() }
        let broken = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), codecs: codecs,
                                        video: RuntimeLiveStreamTests.video(320, 240, fps: 15, bitrate: 300), timing: .standard, selfCheck: true)
        #expect(await broken.receiver.waitFor(timeout: .seconds(10)) { $0.videoFrames >= 60 })
        #expect(broken.ended.sessions.value.isEmpty)
        #expect(!broken.lines.contains { $0.contains("FAILED") })
        await broken.finish()

        var slow = ScriptedCodecs.scripted(.real)
        slow.probeDecoder = { format in SlowDecoder(base: try AppleMediaCodecs().makeVideoDecoder(format: format), delay: .seconds(10)) }
        var timing = LiveStreamTiming.standard
        timing.probeDeadline = .milliseconds(300)
        let sluggish = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), codecs: slow,
                                          video: RuntimeLiveStreamTests.video(320, 240, fps: 15, bitrate: 300), timing: timing, selfCheck: true)
        #expect(await sluggish.receiver.waitFor(timeout: .seconds(10)) { $0.videoFrames >= 60 })
        #expect(sluggish.ended.sessions.value.isEmpty)
        #expect(await eventually(timeout: .seconds(5)) { sluggish.lines.contains { $0.contains("inconclusive") && $0.contains("took more than") } }, "\(sluggish.lines)")
        await sluggish.finish()
    }

    /// A decoder whose every decode fails.
    final class FailingDecoder: VideoDecoding {
        func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? { throw ScriptedCodecs.Injected() }
        func invalidate() {}
    }

    /// What the Mac's decoder makes of the camera's own stream says nothing about the controller's decoder: a passthrough stream is never
    /// ended by a probe that cannot decode it (only by broken packetization, which is ours). The same failure on a stream our own
    /// encoder made ends it.
    @Test(.timeLimit(.minutes(2))) func aProbeThatCannotDecodePassedThroughVideoLeavesItAloneButJudgesOurOwnEncoder() async throws {
        var codecs = ScriptedCodecs.scripted(.real)
        codecs.probeDecoder = { _ in FailingDecoder() }
        let passthrough = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), codecs: codecs,
                                             video: RuntimeLiveStreamTests.video(1280, 720, fps: 15), timing: .standard, selfCheck: true)
        let pipeline = try #require(await passthrough.setup.handler.pipeline(passthrough.sessionID))
        #expect(await eventually(timeout: .seconds(15)) { passthrough.lines.contains { $0.contains("self-check inconclusive") && $0.contains("passed through") } }, "\(passthrough.lines)")
        try await Task.sleep(for: .seconds(4))
        #expect(passthrough.ended.sessions.value.isEmpty && pipeline.videoPath == .passthrough)
        #expect(await passthrough.receiver.statistics.videoFrames >= 30)
        await passthrough.finish()

        let transcoded = try await Self.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), codecs: codecs,
                                            video: RuntimeLiveStreamTests.video(320, 240, fps: 15, bitrate: 300), timing: .standard, selfCheck: true)
        #expect(await eventually(timeout: .seconds(25)) { transcoded.ended.sessions.value.contains(transcoded.sessionID) }, "\(transcoded.lines)")
        #expect(transcoded.lines.contains { $0.contains("self-check FAILED") })
        await transcoded.finish()
    }

    // MARK: Helpers

    /// Recovery far away, so a self-check verdict is what ends the stream.
    static let slowRecovery: LiveStreamTiming = {
        var timing = LiveStreamTiming.standard
        timing.probeDeadline = .seconds(5)
        return timing
    }()

    /// A keyframe's slice data replaced by garbage (the parameter sets and size stay right).
    @Sendable static func corrupted(_ frame: EncodedVideoFrame) -> EncodedVideoFrame {
        guard frame.isKeyframe else { return frame }
        var bad = frame
        bad.nalUnits = [Data([0x65] + [UInt8](repeating: 0x5A, count: 600))]
        return bad
    }

    /// A frame whose format claims another size than the one asked for.
    @Sendable static func resized(_ frame: EncodedVideoFrame) -> EncodedVideoFrame {
        var other = frame
        other.format.width = 160
        other.format.height = 90
        return other
    }

    final class SlowDecoder: VideoDecoding {
        let base: any VideoDecoding
        let delay: Duration
        init(base: any VideoDecoding, delay: Duration) {
            self.base = base
            self.delay = delay
        }
        func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? {
            await Task.detached { try? await Task.sleep(for: self.delay) }.value
            return try await base.decode(frame)
        }
        func invalidate() { base.invalidate() }
    }
}
#endif
