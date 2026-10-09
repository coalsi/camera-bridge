#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import PlatformApple
import TestSupport
import Testing
@testable import BridgeEngine

/// Built-in motion detection (plan W3-1 item 6): the decoded stream is analysed about four times a second and
/// transitions reach the `EventRouter` as origin `.softMotion`; a picture that stops arriving ends motion.
@Suite struct RuntimeSoftMotionTests {
    static let log = Log(category: "SoftMotionTest")

    /// Review finding (W4 round 4): the monitor gave the detector the wall clock (`Date()`), so a clock stepped back while
    /// motion was on (an NTP correction after wake, a manual change) held motion — and with it HKSV recording — on for
    /// the size of the step while still pictures kept coming. The detector's times come from the monotonic clock.
    @Test func theDetectorRunsOnTheMonotonicClock() {
        let origin = ContinuousClock.now
        let start = SoftMotionMonitor.detectorTime(origin, origin: origin)
        let later = SoftMotionMonitor.detectorTime(origin + .milliseconds(10_250), origin: origin)
        #expect(later.timeIntervalSince(start) == 10.25)
        #expect(abs(start.timeIntervalSince(Date(timeIntervalSinceReferenceDate: 0))) < 0.001, "measured from the monitor's start, not the wall clock")
    }

    @Test(.timeLimit(.minutes(1))) func analysesAboutFourPicturesASecondAndReportsMotion() async throws {
        // The synthetic pattern's box moves every frame: at full sensitivity that is motion.
        let feeder = HubFeeder(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil))
        let router = EventRouter()
        var camera = CameraConfiguration(name: "Yard", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.5"), username: "")
        camera.motionSource = .softMotion
        await router.register(camera)
        let monitor = SoftMotionMonitor(hub: feeder.hub, codecs: AppleMediaCodecs(), sensitivity: 1, router: router, cameraID: camera.id, log: Self.log)
        await monitor.start()
        let started = ContinuousClock.now
        #expect(await eventually(timeout: .seconds(10)) { await monitor.analysed >= 8 })
        let elapsed = (ContinuousClock.now - started) / .seconds(1)
        #expect(Double(await monitor.analysed) / elapsed <= 4.6, "analysis is rate-limited to about 4 per second")
        #expect(await eventually(timeout: .seconds(10)) { await router.state(for: camera.id)?.motion == true })

        // The monitor stops: the origin is reset, and motion holds for its hold time (pictures that stop while the monitor
        // runs: `motionEndsWhenThePicturesStop`).
        await feeder.stop()
        await monitor.stop()
        let state = try #require(await router.state(for: camera.id))
        #expect(state.motion, "a reset origin still holds motion for the hold time")
    }

    /// A decoded picture whose thumbnail is a 64×64 image with a bright band at row `index × 4`.
    struct BandPicture: DecodedVideoFrame {
        let index: Int
        var width: Int { 64 }
        var height: Int { 64 }
        var pts: MediaTime { MediaTime(value: Int64(index), timescale: 90_000) }
        func grayThumbnail(maxWidth: Int) -> GrayImage? {
            var pixels = [UInt8](repeating: 0, count: 64 * 64)
            let row = (index * 4) % 60
            for y in row..<(row + 4) { for x in 0..<64 { pixels[y * 64 + x] = 255 } }
            return GrayImage(width: 64, height: 64, pixels: pixels)
        }
    }

    /// Decodes frame n (its pts value) to `BandPicture(n)`; the frame `slowIndex` takes `delay`, ignoring cancellation
    /// (as VideoToolbox does: a decode already submitted returns its picture).
    final class SlowBandDecoder: VideoDecoding {
        let slowIndex: Int
        let delay: Duration
        /// The slow decode began / returned.
        let slowStarted: Box<Bool>
        let slowFinished: Box<Bool>
        init(slowIndex: Int, delay: Duration, slowStarted: Box<Bool>, slowFinished: Box<Bool>) {
            self.slowIndex = slowIndex
            self.delay = delay
            self.slowStarted = slowStarted
            self.slowFinished = slowFinished
        }
        func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? {
            let index = Int(frame.pts.value)
            if index == slowIndex {
                slowStarted.set(true)
                let delay = delay
                await Task.detached { try? await Task.sleep(for: delay) }.value
                slowFinished.set(true)
            }
            return BandPicture(index: index)
        }
        func invalidate() {}
    }

    struct SlowBandCodecs: MediaCodecs {
        let base = AppleMediaCodecs()
        let slowIndex: Int
        let delay: Duration
        let slowStarted = Box(false)
        let slowFinished = Box(false)
        func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding {
            SlowBandDecoder(slowIndex: slowIndex, delay: delay, slowStarted: slowStarted, slowFinished: slowFinished)
        }
        func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { try base.makeVideoEncoder(settings: settings) }
        func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding { try base.makeVideoTranscoder(output: output) }
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

    /// A keyframe showing band `index` (the `BandPicture` decoders read the index from the presentation time).
    static func bandKeyframe(_ index: Int) -> MediaSample {
        .video(EncodedVideoFrame(format: VideoFormat(codec: .h264, width: 64, height: 64, parameterSets: []), nalUnits: [Data([0x65, 0])],
                                 isKeyframe: true, pts: MediaTime(value: Int64(index), timescale: 90_000), wallClock: Date()))
    }

    /// Review finding (W4 round 3): the stall check (pictures stopped while motion is on: the detector only releases motion
    /// from new pictures) never ran in a test; with it gone, MotionDetected stayed on after a camera reboot or a network
    /// drop, the HKSV event stayed open and no new motion was reported.
    @Test(.timeLimit(.minutes(1))) func motionEndsWhenThePicturesStop() async throws {
        let hub = MediaHub()
        let router = EventRouter()
        var camera = CameraConfiguration(name: "Yard", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.5"), username: "")
        camera.motionSource = .softMotion
        camera.motionHoldSeconds = 1
        await router.register(camera)
        let monitor = SoftMotionMonitor(hub: hub, codecs: SlowBandCodecs(slowIndex: -1, delay: .zero), sensitivity: 1, router: router,
                                        cameraID: camera.id, log: Self.log)
        await monitor.start()
        var index = 0
        while await router.state(for: camera.id)?.motion != true, index < 40 {   // the band moves: motion
            await hub.ingest(Self.bandKeyframe(index))
            index += 1
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(await router.state(for: camera.id)?.motion == true)
        // The camera goes away: no more pictures. Motion ends after the stall timeout and the hold.
        let stopped = ContinuousClock.now
        #expect(await eventually(timeout: SoftMotionMonitor.stallTimeout + .seconds(4)) { await router.state(for: camera.id)?.motion == false },
                "motion stays latched without pictures")
        #expect(ContinuousClock.now - stopped >= SoftMotionMonitor.stallTimeout, "not before the stall timeout")
        await monitor.stop()
    }

    /// Decodes frame n to `BandPicture(n)`, except that the frame `failIndex` fails and breaks the decoder (as a
    /// VideoToolbox session can): it fails every frame after that. Only the first decoder made fails.
    struct BreakingBandCodecs: MediaCodecs {
        final class Decoder: VideoDecoding {
            let failIndex: Int?
            let broken = Box(false)
            init(failIndex: Int?) { self.failIndex = failIndex }
            func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? {
                let index = Int(frame.pts.value)
                if index == failIndex { broken.set(true) }
                if broken.value { throw MediaCodecError.unsupported("broken decoder") }
                return BandPicture(index: index)
            }
            func invalidate() {}
        }

        let base = AppleMediaCodecs()
        let failIndex: Int
        let decodersMade = Box(0)
        func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding {
            Decoder(failIndex: decodersMade.update { $0 += 1; return $0 } == 1 ? failIndex : nil)
        }
        func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { try base.makeVideoEncoder(settings: settings) }
        func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding { try base.makeVideoTranscoder(output: output) }
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

    /// Review finding (W4 round 3): the recovery from a decode failure (a new decoder at the next keyframe) never ran in a
    /// test; without it, one broken decode ended motion detection for good.
    @Test(.timeLimit(.minutes(1))) func aDecodeFailureStartsAgainAtTheNextKeyframe() async throws {
        let hub = MediaHub()
        let router = EventRouter()
        var camera = CameraConfiguration(name: "Yard", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.5"), username: "")
        camera.motionSource = .softMotion
        await router.register(camera)
        let codecs = BreakingBandCodecs(failIndex: 2)
        let monitor = SoftMotionMonitor(hub: hub, codecs: codecs, sensitivity: 1, router: router, cameraID: camera.id, log: Self.log)
        await monitor.start()
        for index in 0..<4 {
            await hub.ingest(Self.bandKeyframe(index))
            try await Task.sleep(for: .milliseconds(300))
        }
        let afterFailure = await monitor.analysed
        #expect(afterFailure == 2, "pictures 0 and 1; 2 failed and broke the decoder")
        for index in 4..<8 {
            await hub.ingest(Self.bandKeyframe(index))
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(await monitor.analysed >= afterFailure + 3, "a new decoder from the next keyframe on")
        #expect(codecs.decodersMade.value >= 2)
        await monitor.stop()
    }

    /// Review finding (W4): `stop()` did not wait for the analysis task, so a motion start computed from a picture that was
    /// still decoding reached the router after `resetOrigin(.softMotion)` — a level nothing would ever end.
    @Test(.timeLimit(.minutes(1))) func aMotionStartStillDecodingWhenStoppedNeverReachesTheRouter() async throws {
        let hub = MediaHub()
        let router = EventRouter()
        var camera = CameraConfiguration(name: "Yard", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.5"), username: "")
        camera.motionSource = .softMotion
        camera.motionHoldSeconds = 1
        await router.register(camera)
        // Frames 0 (background), 1 (first hit), 2 (second hit: motion starts) — frame 2 decodes for 1.5 s.
        let codecs = SlowBandCodecs(slowIndex: 2, delay: .milliseconds(1_500))
        let monitor = SoftMotionMonitor(hub: hub, codecs: codecs, sensitivity: 1, router: router, cameraID: camera.id, log: Self.log)
        await monitor.start()
        let format = VideoFormat(codec: .h264, width: 64, height: 64, parameterSets: [])
        for index in 0..<3 {
            if index > 0 { try await Task.sleep(for: .milliseconds(400)) }   // past the 250 ms analysis interval
            await hub.ingest(.video(EncodedVideoFrame(format: format, nalUnits: [Data([0x65, 0])], isKeyframe: true,
                                                      pts: MediaTime(value: Int64(index), timescale: 90_000), wallClock: Date())))
        }
        #expect(await eventually(timeout: .seconds(5)) { codecs.slowStarted.value })
        #expect(!codecs.slowFinished.value, "frame 2 is still decoding at the stop")
        await monitor.stop()
        let atStop = await monitor.analysed
        try await Task.sleep(for: .milliseconds(2_500))   // the decode finishes; longer than the 1 s hold
        #expect(codecs.slowFinished.value)
        #expect(await monitor.analysed == atStop, "the picture still decoding at the stop is never analysed")
        #expect(await router.state(for: camera.id)?.motion == false, "no motion level outlives the monitor")
    }
}
#endif
