#if canImport(Darwin)
import BridgeSupport
import Foundation
import HAPCamera
import MediaCore
import PlatformApple
import TestSupport
import Testing
@testable import BridgeEngine

/// `AppleMediaCodecs` that remembers every transcoder it makes and the overlay it was given.
struct OverlayCapturingCodecs: MediaCodecs {
    struct Made: Sendable {
        var settings: VideoEncoderSettings
        var overlay: (any TimestampOverlayProviding)?
    }

    let base = AppleMediaCodecs()
    let made = Box<[Made]>([])

    func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding { try base.makeVideoDecoder(format: format) }
    func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { try base.makeVideoEncoder(settings: settings) }
    func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding {
        made.update { $0.append(Made(settings: output, overlay: nil)) }
        return try base.makeVideoTranscoder(output: output)
    }
    func makeVideoTranscoder(output: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)?) throws -> any VideoTranscoding {
        made.update { $0.append(Made(settings: output, overlay: overlay)) }
        return try base.makeVideoTranscoder(output: output, overlay: overlay)
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

/// With the timestamp overlay on, live view and HKSV recording leave the passthrough path and transcode with the overlay
/// (a source that would otherwise pass through untouched).
@Suite(.serialized) struct RuntimeTimestampOverlayTests {
    static let on = TimestampOverlaySettings(enabled: true, position: .bottomLeft, showCameraName: true, showDate: true, showSeconds: true, use24Hour: true, size: .large)

    @Test(.timeLimit(.minutes(3))) func liveViewTranscodesWithTheOverlayWhereItWouldOtherwisePassThrough() async throws {
        let codecs = OverlayCapturingCodecs()
        let control = TimestampOverlayControl(settings: Self.on, cameraName: "Porch")
        let setup = RuntimeLiveStreamTests.setup(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(2), audio: nil), codecs: codecs,
                                                 overlay: control)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await RuntimeLiveStreamTests.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await RuntimeLiveStreamTests.connect(receiver, to: response)
        // The same request the passthrough test makes (1280×720 for a 640×360 H.264 source).
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: RuntimeLiveStreamTests.video(1280, 720), audio: nil))
        let pipeline = try #require(await setup.handler.pipeline(sessionID))
        #expect(await eventually(timeout: .seconds(10)) { pipeline.isTranscoding })
        #expect(pipeline.videoPath == .transcode(MediaFit.timestampOverlayReason))
        #expect(await receiver.waitFor(timeout: .seconds(8)) { $0.keyframes >= 1 && $0.videoFrames >= 10 })

        let made = try #require(codecs.made.value.first)
        #expect(made.settings.width == 1280 && made.settings.height == 720)
        let overlay = try #require(made.overlay?.current)
        #expect(overlay.settings == Self.on && overlay.cameraName == "Porch")
        // Edits reach the running stream without restarting it.
        control.update(settings: TimestampOverlaySettings(enabled: true, position: .topLeft), cameraName: "Porch 2")
        #expect(made.overlay?.current?.settings.position == .topLeft && made.overlay?.current?.cameraName == "Porch 2")

        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test(.timeLimit(.minutes(3))) func withoutTheOverlayTheSameSourceStillPassesThrough() async throws {
        let codecs = OverlayCapturingCodecs()
        let control = TimestampOverlayControl(settings: TimestampOverlaySettings(enabled: false), cameraName: "Porch")
        let setup = RuntimeLiveStreamTests.setup(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(2), audio: nil), codecs: codecs,
                                                 overlay: control)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await RuntimeLiveStreamTests.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
        await RuntimeLiveStreamTests.connect(receiver, to: response)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: RuntimeLiveStreamTests.video(1280, 720), audio: nil))
        let pipeline = try #require(await setup.handler.pipeline(sessionID))
        #expect(await receiver.waitFor(timeout: .seconds(5)) { $0.keyframes >= 1 })
        #expect(pipeline.videoPath == .passthrough && !pipeline.isTranscoding && codecs.made.value.isEmpty)
        try await setup.handler.handleStreamRequest(.stop(sessionID: sessionID))
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test(.timeLimit(.minutes(3))) func recordingTranscodesWithTheOverlayWhereItWouldOtherwisePassThrough() async throws {
        let codecs = OverlayCapturingCodecs()
        let control = TimestampOverlayControl(settings: Self.on, cameraName: "Porch")
        let feeder = HubFeeder(source: syntheticSource(audio: nil))
        #expect(await feeder.waitUntilReady())
        try await Task.sleep(for: .seconds(1))
        let handler = RecordingHandler(hub: feeder.hub, codecs: codecs, cameraAudioEnabled: false, log: RuntimeRecordingTests.log, overlay: control)
        // A 1280×720 Main selection: the 640×360 Main source fits and would pass through.
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(fragmentMs: 1000))
        await handler.updateRecordingAudioActive(true)
        let (packets, error) = await collect(try await handler.recordingStream(streamID: 3), limit: 4)
        #expect(error == nil)
        _ = try RuntimeRecordingTests.validate(packets, fragmentMs: 1000, expectAudio: true)
        let made = try #require(codecs.made.value.first)
        #expect(made.settings.width == 1280 && made.settings.height == 720)
        #expect(made.overlay?.current?.settings == Self.on)
        await handler.closeRecordingStream(streamID: 3, reason: .normal)
        await feeder.stop()
    }

    @Test(.timeLimit(.minutes(3))) func recordingWithoutTheOverlayPassesThroughAsBefore() async throws {
        let codecs = OverlayCapturingCodecs()
        let feeder = HubFeeder(source: syntheticSource(audio: nil))
        #expect(await feeder.waitUntilReady())
        try await Task.sleep(for: .seconds(1))
        let handler = RecordingHandler(hub: feeder.hub, codecs: codecs, cameraAudioEnabled: false, log: RuntimeRecordingTests.log,
                                       overlay: TimestampOverlayControl(settings: TimestampOverlaySettings(), cameraName: "Porch"))
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(fragmentMs: 1000))
        await handler.updateRecordingAudioActive(true)
        let (packets, error) = await collect(try await handler.recordingStream(streamID: 4), limit: 3)
        #expect(error == nil && packets.count == 3)
        #expect(codecs.made.value.isEmpty, "passthrough: no transcoder")
        await handler.closeRecordingStream(streamID: 4, reason: .normal)
        await feeder.stop()
    }
}
#endif
