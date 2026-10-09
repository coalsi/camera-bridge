import TestSupport
@testable import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import MediaCore
import Synchronization
import Testing
@testable import BridgeEngine

/// The hero snapshot (10 s) and the sidebar thumbnail (30 s) of every camera whose snapshot API answers 503 are
/// served from the video stream: one keyframe decoded per request. Before the fix each request built a new
/// VTDecompressionSession and decoded a 4K keyframe (log: "decoder session created for H.264 4256×1888", every 10 s,
/// for hours, even with nobody watching). These tests count the decoders and decodes a minute of those requests cost.
@Suite(.timeLimit(.minutes(1))) struct SnapshotDecodeRateTests {
    static let log = Log(category: "SnapshotDecodeRateTest")

    /// Counts the decoders made and the pictures decoded; everything else is unused by the snapshot path.
    final class CountingCodecs: MediaCodecs {
        let decodersMade = Box(0)
        let snapshotDecodersMade = Box(0)
        let decodes = Box(0)
        let decodersInvalidated = Box(0)

        struct Picture: DecodedVideoFrame {
            var width = 4256
            var height = 1888
            var pts = MediaTime(value: 0, timescale: 90_000)
            func grayThumbnail(maxWidth: Int) -> GrayImage? { nil }
        }

        final class Decoder: VideoDecoding {
            let owner: CountingCodecs
            init(owner: CountingCodecs) { self.owner = owner }
            func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? {
                owner.decodes.update { $0 += 1 }
                return Picture()
            }
            func invalidate() { owner.decodersInvalidated.update { $0 += 1 } }
        }

        func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding {
            decodersMade.update { $0 += 1 }
            return Decoder(owner: self)
        }
        func makeSnapshotDecoder(format: VideoFormat) throws -> any VideoDecoding {
            snapshotDecodersMade.update { $0 += 1 }
            return try makeVideoDecoder(format: format)
        }
        func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { throw MediaCodecError.unsupported("test") }
        func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding { throw MediaCodecError.unsupported("test") }
        func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding { throw MediaCodecError.unsupported("test") }
        func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data { Data([0xFF, 0xD8, 0x4B]) }
        func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data { jpeg }
        func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] { [] }
        func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration,
                                 audio: AudioCodec?, audioSampleRate: Int) -> any MediaSource { fatalError("unused") }
    }

    static func keyframe(at index: Int) -> EncodedVideoFrame {
        EncodedVideoFrame(format: VideoFormat(codec: .h264, width: 4256, height: 1888, parameterSets: []), nalUnits: [Data([0x65, UInt8(index & 0xFF)])],
                          isKeyframe: true, pts: MediaTime(value: Int64(index) * 360_000, timescale: 90_000),
                          wallClock: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 4))
    }

    /// Simulates `seconds` of the app's refresh timers (hero every 10 s, sidebar thumbnail every 30 s; both the engine's
    /// 1280×720 periodic snapshot) against a camera whose snapshot API answers 503, a keyframe arriving on the hub every
    /// `keyframeEvery` seconds (nil: the hub holds one keyframe throughout).
    static func simulate(seconds: Int, keyframeEvery: Int?, codecs: CountingCodecs) async throws {
        let hub = MediaHub()
        let clock = Box(ContinuousClock.now)
        await hub.ingest(.video(keyframe(at: 0)))
        let failing: SnapshotProvider.CameraSnapshot = { throw TransportError.timedOut }
        let snapshots = SnapshotProvider(cameraSnapshot: failing, codecs: codecs, hub: hub, log: log, now: { clock.value })
        for second in 0..<seconds {
            if let keyframeEvery, second > 0, second % keyframeEvery == 0 { await hub.ingest(.video(keyframe(at: second))) }
            if second % 10 == 0 { _ = try await snapshots.snapshot(SnapshotRequest(width: 1280, height: 720, reason: .periodic)) }
            if second % 30 == 0 { _ = try await snapshots.snapshot(SnapshotRequest(width: 1280, height: 720, reason: .periodic)) }
            clock.update { $0 += .seconds(1) }
        }
    }

    /// Before the fix (measured with the same simulation): 6 decoders made and 6 keyframes decoded per minute per camera
    /// in both scenarios (a new VideoToolbox session for each 10 s refresh; the 30 s thumbnail hit the 4 s cache).
    @Test func aMinuteOfRefreshesOnAStaticKeyframeDecodesOnceAndMakesOneDecoder() async throws {
        let codecs = CountingCodecs()
        try await Self.simulate(seconds: 60, keyframeEvery: nil, codecs: codecs)
        print("DECODE-RATE (after) static keyframe, 60 s: decoders made \(codecs.decodersMade.value), decodes \(codecs.decodes.value)")
        #expect(codecs.decodes.value == 1, "the same keyframe is decoded once")
        #expect(codecs.decodersMade.value == 1)
        #expect(codecs.snapshotDecodersMade.value == 1, "snapshot decoders are asked for as such (their session logs at debug level)")
    }

    @Test func aMinuteOfRefreshesWithAFreshKeyframeEveryFourSecondsReusesOneDecoder() async throws {
        let codecs = CountingCodecs()
        try await Self.simulate(seconds: 60, keyframeEvery: 4, codecs: codecs)
        print("DECODE-RATE (after) live keyframes every 4 s, 60 s: decoders made \(codecs.decodersMade.value), decodes \(codecs.decodes.value)")
        #expect(codecs.decodersMade.value == 1, "one decoder session serves every snapshot")
        #expect(codecs.decodes.value <= 6, "at most one decode per 10 s refresh")
    }

    @Test func aCameraNobodyAsksForHoldsNoDecoderAfterTheIdleLifetime() async throws {
        let codecs = CountingCodecs()
        let pool = SnapshotDecoderPool(codecs: codecs, idleLifetime: .milliseconds(150))
        _ = try await pool.jpeg(fromKeyframe: Self.keyframe(at: 0), maxWidth: 1280, maxHeight: 720)
        #expect(pool.isHoldingDecoder)
        _ = try await pool.jpeg(fromKeyframe: Self.keyframe(at: 4), maxWidth: 1280, maxHeight: 720)
        #expect(codecs.decodersMade.value == 1)
        #expect(await eventually { !pool.isHoldingDecoder })
        #expect(codecs.decodersInvalidated.value == 1)
        _ = try await pool.jpeg(fromKeyframe: Self.keyframe(at: 8), maxWidth: 1280, maxHeight: 720)
        #expect(codecs.decodersMade.value == 2, "a new session once the idle one was released")
    }

    @Test func aNewFormatGetsANewDecoderAndAFailedDecodeDropsTheOne() async throws {
        let codecs = CountingCodecs()
        let pool = SnapshotDecoderPool(codecs: codecs, idleLifetime: .seconds(60))
        _ = try await pool.jpeg(fromKeyframe: Self.keyframe(at: 0), maxWidth: nil, maxHeight: nil)
        var smaller = Self.keyframe(at: 1)
        smaller.format.width = 2688
        smaller.format.height = 1520
        _ = try await pool.jpeg(fromKeyframe: smaller, maxWidth: nil, maxHeight: nil)
        #expect(codecs.decodersMade.value == 2 && codecs.decodersInvalidated.value == 1)

        var delta = Self.keyframe(at: 2)
        delta.isKeyframe = false
        await #expect(throws: MediaCodecError.self) { _ = try await pool.jpeg(fromKeyframe: delta, maxWidth: nil, maxHeight: nil) }
    }
}
