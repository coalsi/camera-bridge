import TestSupport
@testable import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import MediaCore
import Synchronization
import Testing
@testable import BridgeEngine
#if canImport(Darwin)
import PlatformApple
#endif

/// Snapshots show the camera's picture of now (audit 3 A7, A8, B8): decoded forward through the GOP, never older than 5 minutes
/// when the camera is away, shorter budgets that fall back to the last picture, and one fetch for concurrent requests.
@Suite(.timeLimit(.minutes(2))) struct RuntimeSnapshotFreshnessTests {
    static let log = Log(category: "SnapshotFreshnessTest")

    private static func frame(_ index: Int, keyframe: Bool) -> EncodedVideoFrame {
        EncodedVideoFrame(format: VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: []), nalUnits: [Data([keyframe ? 0x65 : 0x41, UInt8(index)])],
                          isKeyframe: keyframe, pts: MediaTime(value: Int64(index * 3_000), timescale: 90_000), wallClock: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index) / 30))
    }

    /// A provider whose GOP decoder double records the frames it was given.
    private final class Recorder: Sendable {
        let gops = Box<[Int]>([])
        let keyframeCalls = Box(0)
        let apiCalls = Box(0)
        let clock = Box(ContinuousClock.now)

        func provider(hub: MediaHub, api: SnapshotProvider.CameraSnapshot? = nil, timing: SnapshotProvider.Timing = SnapshotProvider.Timing(),
                      isOffline: @escaping @Sendable () -> Bool = { false }) -> SnapshotProvider {
            SnapshotProvider(cameraSnapshot: api, resize: { jpeg, width, _ in jpeg + Data([UInt8(truncatingIfNeeded: width ?? 0)]) },
                             keyframeJPEG: { [self] _, _, _ in
                                 keyframeCalls.update { $0 += 1 }
                                 return Data([0xFF, 0xD8, 0x4B])
                             }, newestJPEG: { [self] gop, _, _, _ in
                                 gops.update { $0.append(gop.count) }
                                 return Data([0xFF, 0xD8, UInt8(gop.count)])
                             }, hub: hub, timing: timing, log: RuntimeSnapshotFreshnessTests.log, isOffline: isOffline, now: { [self] in clock.value })
        }
    }

    @Test func theSnapshotIsOfTheNewestFrameDecodedForwardFromTheKeyframe() async throws {
        let recorder = Recorder()
        let hub = MediaHub()
        await hub.ingest(.video(Self.frame(0, keyframe: true)))
        for index in 1...5 { await hub.ingest(.video(Self.frame(index, keyframe: false))) }
        let provider = recorder.provider(hub: hub)
        let first = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event))
        #expect(recorder.gops.value == [6], "the keyframe and the five frames after it")
        #expect(first == Data([0xFF, 0xD8, 6]))
        // Nothing newer arrived: the same picture, no decoding.
        _ = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event))
        #expect(recorder.gops.value == [6])
        // A newer frame arrived: the picture moves on.
        await hub.ingest(.video(Self.frame(6, keyframe: false)))
        let second = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event))
        #expect(second == Data([0xFF, 0xD8, 7]) && recorder.gops.value == [6, 7])
        // A new GOP: its keyframe alone.
        await hub.ingest(.video(Self.frame(30, keyframe: true)))
        let third = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event))
        #expect(third == Data([0xFF, 0xD8, 1]))
        #expect(recorder.keyframeCalls.value == 0, "the keyframe-only decoder is not used when a GOP decoder is")
    }

    @Test func aPictureOlderThanFiveMinutesIsNotServedForAnOfflineCamera() async throws {
        let recorder = Recorder()
        let offline = Box(false)
        let api: SnapshotProvider.CameraSnapshot = {
            if offline.value { throw CameraOfflineError() }
            return Data([0xFF, 0xD8, 7])
        }
        let provider = recorder.provider(hub: MediaHub(), api: api, isOffline: { offline.value })
        let live = try await provider.snapshot(SnapshotRequest(width: 1280, height: 720, reason: .periodic))
        offline.set(true)
        recorder.clock.update { $0 += .seconds(290) }
        #expect(try await provider.snapshot(SnapshotRequest(width: 1280, height: 720, reason: .periodic)) == live, "the last picture, while it is recent enough")
        recorder.clock.update { $0 += .seconds(20) }   // 310 s
        await #expect(throws: SnapshotProvider.Failure.stale) { _ = try await provider.snapshot(SnapshotRequest(width: 1280, height: 720, reason: .periodic)) }
        await #expect(throws: SnapshotProvider.Failure.stale) { _ = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event)) }
    }

    @Test func aSnapshotPastItsBudgetServesTheLastPictureInsteadOfFailing() async throws {
        let recorder = Recorder()
        let slow = Box(false)
        let api: SnapshotProvider.CameraSnapshot = {
            if slow.value { try await Task.sleep(for: .seconds(30)) }
            return Data([0xFF, 0xD8, 9])
        }
        var timing = SnapshotProvider.Timing()
        timing.eventBudget = .milliseconds(300)
        timing.budget = .milliseconds(300)
        timing.cameraAPITimeout = .seconds(30)
        let provider = recorder.provider(hub: MediaHub(), api: api, timing: timing)
        let live = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .periodic))
        slow.set(true)
        let began = ContinuousClock.now
        let served = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event))
        #expect(served == live, "the last picture stands in")
        #expect(ContinuousClock.now - began < .seconds(2), "within the event budget, not the camera's 30 s")
        // Another size is the last picture resized.
        let other = try await provider.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event))
        #expect(other == live + Data([64]))
    }

    @Test func theBudgetsAreThreeSecondsForEventsAndFourForTheRest() {
        let timing = SnapshotProvider.Timing()
        #expect(timing.eventBudget == .seconds(3) && timing.budget == .seconds(4) && timing.maximumStaleAge == .seconds(300))
    }

    /// Hikvision answers 503 to snapshot requests that arrive together: concurrent requests share one fetch (any size) and one decode.
    @Test func concurrentRequestsShareOneCameraFetch() async throws {
        let recorder = Recorder()
        let api: SnapshotProvider.CameraSnapshot = { [recorder] in
            recorder.apiCalls.update { $0 += 1 }
            try await Task.sleep(for: .milliseconds(300))
            return Data([0xFF, 0xD8, 5])
        }
        let provider = recorder.provider(hub: MediaHub(), api: api)
        let results = await withTaskGroup(of: Data?.self) { group in
            for index in 0..<6 {
                group.addTask { try? await provider.snapshot(SnapshotRequest(width: index % 2 == 0 ? 640 : 320, height: 360, reason: .event)) }
            }
            var all: [Data?] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(results.allSatisfy { $0 != nil })
        #expect(recorder.apiCalls.value == 1, "\(recorder.apiCalls.value) requests reached the camera")
    }

    @Test func concurrentRequestsShareOneDecode() async throws {
        let recorder = Recorder()
        let hub = MediaHub()
        await hub.ingest(.video(Self.frame(0, keyframe: true)))
        await hub.ingest(.video(Self.frame(1, keyframe: false)))
        let provider = recorder.provider(hub: hub)
        _ = await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<6 { group.addTask { try? await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event)) } }
            var all: [Data?] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(recorder.gops.value.count == 1, "\(recorder.gops.value.count) decodes")
    }

    #if canImport(Darwin)
    /// A decoder that counts the frames it decodes.
    final class CountingDecoder: VideoDecoding {
        let base: any VideoDecoding
        let decoded: Box<Int>
        init(base: any VideoDecoding, decoded: Box<Int>) {
            self.base = base
            self.decoded = decoded
        }
        func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? {
            decoded.update { $0 += 1 }
            return try await base.decode(frame)
        }
        func invalidate() { base.invalidate() }
    }

    struct CountingCodecs: MediaCodecs {
        let base = AppleMediaCodecs()
        let decoded = Box(0)
        func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding { try base.makeVideoDecoder(format: format) }
        func makeSnapshotDecoder(format: VideoFormat) throws -> any VideoDecoding { CountingDecoder(base: try base.makeSnapshotDecoder(format: format), decoded: decoded) }
        func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { try base.makeVideoEncoder(settings: settings) }
        func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding { try base.makeVideoTranscoder(output: output) }
        func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding { try base.makeAudioTranscoder(input: input, output: output) }
        func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data {
            try base.jpeg(from: frame, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality)
        }
        func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data { try base.resizeJPEG(jpeg, maxWidth: maxWidth, maxHeight: maxHeight) }
        func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] {
            try base.silentAACFrames(duration: duration, sampleRate: sampleRate, channels: channels, startPTS: startPTS, wallClock: wallClock)
        }
        func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration, audio: AudioCodec?,
                                 audioSampleRate: Int) -> any MediaSource {
            base.makeSyntheticSource(displayName: displayName, width: width, height: height, fps: fps, keyframeInterval: keyframeInterval, audio: audio,
                                     audioSampleRate: audioSampleRate)
        }
    }

    /// A camera whose GOP is long: the snapshot is of the newest frame, and the next one continues the GOP on the same decoder
    /// instead of decoding it again from its keyframe.
    @Test(.timeLimit(.minutes(2))) func aLongGOPSnapshotIsOfNowAndContinuesTheGOPOnTheSameDecoder() async throws {
        let codecs = CountingCodecs()
        let feeder = HubFeeder(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(30), audio: nil))
        let ready = await eventually(timeout: .seconds(30)) { await feeder.hub.lastKeyframe != nil }
        #expect(ready)
        let provider = SnapshotProvider(cameraSnapshot: nil, codecs: codecs, hub: feeder.hub, log: Self.log)
        try await Task.sleep(for: .seconds(2))
        let first = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event))
        let afterFirst = codecs.decoded.value
        #expect(afterFirst >= 20, "decoded forward through the GOP: \(afterFirst) frames")
        try await Task.sleep(for: .seconds(2))
        let second = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event))
        let added = codecs.decoded.value - afterFirst
        #expect(added > 0 && added < afterFirst, "only the frames since the last snapshot were decoded: \(added) after \(afterFirst)")
        #expect(first != second, "the picture moved on (a keyframe-only snapshot would be the same picture)")
        #expect(first.prefix(2) == Data([0xFF, 0xD8]) && second.prefix(2) == Data([0xFF, 0xD8]))
        await feeder.stop()
    }
    #endif
}

/// `MediaFit.prefersSubStream`: a request the sub stream's picture covers is read from it (audit 2 R3).
@Suite struct SubStreamPreferenceTests {
    private func request(_ width: Int, _ height: Int) -> SelectedVideoParameters {
        SelectedVideoParameters(profile: .main, level: .level4_0, resolution: VideoResolution(width, height, 30), payloadType: 99, controllerSSRC: 1,
                                maxBitrateKbps: 1_000, rtcpIntervalSeconds: 1, mtu: 1378)
    }

    @Test func aRequestTheSubStreamCoversUsesTheSubStream() {
        let sub = VideoResolution(1280, 720, 15)
        #expect(MediaFit.prefersSubStream(for: request(1280, 720), audio: nil, subStreamSize: sub), "a 720p request is not decoded from 8 MP")
        #expect(!MediaFit.prefersSubStream(for: request(1920, 1080), audio: nil, subStreamSize: sub), "the sub stream is smaller than the request")
        #expect(!MediaFit.prefersSubStream(for: request(1280, 720), audio: nil, subStreamSize: VideoResolution(640, 360, 15)))
        #expect(!MediaFit.prefersSubStream(for: request(1280, 720), audio: nil), "without a known sub stream size it stays as it was")
    }

    @Test func theExistingRulesStandAndTheModeStillForcesOneStream() {
        #expect(MediaFit.prefersSubStream(for: request(640, 360), audio: nil))
        #expect(!MediaFit.prefersSubStream(for: request(1280, 720), audio: nil, mode: .alwaysMain, subStreamSize: VideoResolution(1280, 720, 15)))
        #expect(MediaFit.prefersSubStream(for: request(1920, 1080), audio: nil, mode: .alwaysSub))
    }
}
