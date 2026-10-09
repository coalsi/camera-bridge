import Foundation
import HAPCamera
import MediaCore
import Testing
@testable import BridgeEngine

/// Passthrough-or-transcode decisions (plan W3-1 items 3 and 5; integration brief §5.2–§5.4).
@Suite struct RuntimeMediaFitTests {
    static func h264(_ width: Int, _ height: Int, profile: UInt8 = 77, level: UInt8 = 40) -> VideoFormat {
        VideoFormat(codec: .h264, width: width, height: height, parameterSets: [], profile: profile, level: level)
    }

    static func recording(_ width: Int, _ height: Int, profile: H264Profile = .main, level: H264Level = .level4_0,
                          fragmentMs: Int = 4000) -> CameraRecordingConfiguration {
        CameraRecordingConfiguration(prebufferLengthMs: 4000, eventTriggers: 1, fragmentLengthMs: fragmentMs, videoProfile: profile, videoLevel: level,
                                     videoBitrateKbps: 2000, iFrameIntervalMs: 4000, resolution: VideoResolution(width, height, 30),
                                     audioCodec: .aacLC, audioChannels: 1, audioSampleRate: .khz32, audioMaxBitrateKbps: 24)
    }

    static func live(_ width: Int, _ height: Int, fps: Int = 30, level: H264Level = .level4_0) -> SelectedVideoParameters {
        SelectedVideoParameters(profile: .main, level: level, resolution: VideoResolution(width, height, fps), payloadType: 99, controllerSSRC: 1,
                                maxBitrateKbps: 299, rtcpIntervalSeconds: 0.5, mtu: 1378)
    }

    // MARK: Levels

    /// HAP's levels as level_idc; their Table A-1 limits are MediaCore's `H264LevelLimits` (tested in MediaCoreTests).
    @Test func levelLimitsFollowTableA1() {
        #expect(H264Levels.idc(.level3_1) == 31 && H264Levels.idc(.level3_2) == 32 && H264Levels.idc(.level4_0) == 40)
        #expect(H264LevelLimits.fits(width: 1920, height: 1080, fps: 30, levelIDC: Int(H264Levels.idc(.level4_0))))
        #expect(!H264LevelLimits.fits(width: 1920, height: 1080, fps: 30, levelIDC: Int(H264Levels.idc(.level3_1))))
        #expect(H264LevelLimits.fits(width: 1280, height: 720, fps: 30, levelIDC: Int(H264Levels.idc(.level3_1))))
    }

    // MARK: Recording

    @Test func recordingPassesThroughAFittingH264Source() {
        let decision = MediaFit.recording(source: Self.h264(1920, 1080), frameRate: 25, gop: .seconds(2), configuration: Self.recording(1920, 1080))
        #expect(decision == .passthrough)
        // A smaller picture fits a larger selection; Baseline fits Main.
        #expect(MediaFit.recording(source: Self.h264(1280, 720, profile: 66, level: 31), frameRate: 30, gop: .seconds(4),
                                   configuration: Self.recording(1920, 1080)) == .passthrough)
        // An over-declared level whose picture still fits the selected level (cameras often write 5.1 for 1080p).
        #expect(MediaFit.recording(source: Self.h264(1920, 1080, level: 51), frameRate: 25, gop: .seconds(2),
                                   configuration: Self.recording(1920, 1080)) == .passthrough)
        // Unknown GOP (only one keyframe seen yet) is not a reason to transcode.
        #expect(MediaFit.recording(source: Self.h264(1920, 1080), frameRate: nil, gop: nil, configuration: Self.recording(1920, 1080)) == .passthrough)
    }

    @Test func recordingTranscodesWhatDoesNotFit() {
        func transcodes(_ source: VideoFormat, fps: Double? = 25, gop: Duration? = .seconds(2), _ configuration: CameraRecordingConfiguration) -> Bool {
            if case .transcode = MediaFit.recording(source: source, frameRate: fps, gop: gop, configuration: configuration) { return true }
            return false
        }
        #expect(transcodes(Self.h264(2560, 1440), Self.recording(1920, 1080)))                        // too large
        #expect(transcodes(Self.h264(1920, 1080), Self.recording(1280, 720, level: .level3_1)))      // too large for the selection
        #expect(transcodes(Self.h264(1920, 1080), gop: .seconds(8), Self.recording(1920, 1080)))       // GOP longer than a fragment
        #expect(transcodes(Self.h264(1920, 1080, profile: 100), Self.recording(1920, 1080, profile: .main)))   // High into Main
        #expect(transcodes(Self.h264(1920, 1080, profile: 122), Self.recording(1920, 1080, profile: .high)))   // 4:2:2
        #expect(transcodes(Self.h264(1920, 1080), fps: 60, Self.recording(1920, 1080)))               // 60 fps into 30
        #expect(transcodes(VideoFormat(codec: .hevc, width: 1920, height: 1080, parameterSets: []), Self.recording(1920, 1080)))
        // High is fine when High was selected.
        #expect(!transcodes(Self.h264(1920, 1080, profile: 100), Self.recording(1920, 1080, profile: .high)))
        // A GOP a little over the fragment length is jitter (the fragmenter's allowance: min(5 %, 50 ms)).
        #expect(!transcodes(Self.h264(1920, 1080), gop: .milliseconds(4040), Self.recording(1920, 1080)))
        #expect(!transcodes(Self.h264(1920, 1080), gop: .milliseconds(1040), Self.recording(1920, 1080, fragmentMs: 1000)))
    }

    /// Review finding (W4): a 5 % GOP tolerance let single-GOP passthrough fragments reach 4.2 s for a 4000 ms
    /// fragmentLength (research brief §3.9: no fragment longer than fragmentLength); only timestamp jitter may pass.
    @Test func recordingTranscodesGOPsLongerThanTheFragmentBeyondJitter() {
        func transcodes(gop: Duration, fragmentMs: Int = 4000) -> Bool {
            if case .transcode = MediaFit.recording(source: Self.h264(1920, 1080), frameRate: 24, gop: gop,
                                                    configuration: Self.recording(1920, 1080, fragmentMs: fragmentMs)) { return true }
            return false
        }
        #expect(transcodes(gop: .milliseconds(4100)), "100 ms is 2.5 frames, not jitter")
        #expect(transcodes(gop: .milliseconds(4167)), "a 24 fps camera with a keyframe every 100 frames")
        #expect(transcodes(gop: .milliseconds(4200)))
        #expect(!transcodes(gop: .milliseconds(4050)))
        #expect(transcodes(gop: .milliseconds(1060), fragmentMs: 1000), "the allowance is 5 % of short fragments")
        #expect(MediaFit.recordingGOPAllowance(fragmentLengthMs: 4000) == .milliseconds(50))
        #expect(MediaFit.recordingGOPAllowance(fragmentLengthMs: 600) == .milliseconds(30))
    }

    @Test func recordingAudioPlan() {
        let config = Self.recording(1920, 1080)
        #expect(MediaFit.recordingAudio(source: nil, audioActive: false, configuration: config) == .none)
        #expect(MediaFit.recordingAudio(source: .aacLC(sampleRate: 32_000, channels: 1), audioActive: false, configuration: config) == .none)
        #expect(MediaFit.recordingAudio(source: nil, audioActive: true, configuration: config) == .silent)
        #expect(MediaFit.recordingAudio(source: .aacLC(sampleRate: 32_000, channels: 1), audioActive: true, configuration: config) == .passthrough)
        #expect(MediaFit.recordingAudio(source: .aacLC(sampleRate: 16_000, channels: 1), audioActive: true, configuration: config) == .transcode)
        #expect(MediaFit.recordingAudio(source: .aacLC(sampleRate: 32_000, channels: 2), audioActive: true, configuration: config) == .transcode)
        #expect(MediaFit.recordingAudio(source: AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1), audioActive: true,
                                        configuration: config) == .transcode)
        // AAC-ELD claims codec .aacELD; plain .aac with an ELD config (object type 39) is not AAC-LC either.
        let eld = AudioFormat(codec: .aac, sampleRate: 32_000, channels: 1, audioSpecificConfig: Data([0xF8, 0xE8, 0x50, 0x00]))
        #expect(MediaFit.recordingAudio(source: eld, audioActive: true, configuration: config) == .transcode)
    }

    // MARK: Live

    @Test func livePassesThroughWhenTheSourceFitsTheRequest() {
        #expect(MediaFit.live(source: Self.h264(1280, 720, level: 31), frameRate: 25, requested: Self.live(1280, 720, level: .level3_1)) == .passthrough)
        #expect(MediaFit.live(source: Self.h264(640, 360, profile: 100, level: 30), frameRate: 15, requested: Self.live(1280, 720)) == .passthrough)
        #expect(MediaFit.live(source: Self.h264(1920, 1080, level: 42), frameRate: 20, requested: Self.live(1920, 1080)) == .passthrough)
    }

    @Test func liveTranscodesLargerOrUnsupportedSources() {
        func transcodes(_ source: VideoFormat, fps: Double? = 25, _ requested: SelectedVideoParameters) -> Bool {
            if case .transcode = MediaFit.live(source: source, frameRate: fps, requested: requested) { return true }
            return false
        }
        #expect(transcodes(Self.h264(1920, 1080), Self.live(1280, 720)))
        #expect(transcodes(Self.h264(640, 360), Self.live(320, 240, fps: 15)))
        #expect(transcodes(Self.h264(1280, 720, level: 40), fps: 60, Self.live(1280, 720, level: .level3_1)))
        #expect(transcodes(VideoFormat(codec: .hevc, width: 1280, height: 720, parameterSets: []), Self.live(1920, 1080)))
        #expect(transcodes(Self.h264(1280, 720, profile: 244), Self.live(1920, 1080)))
    }

    /// Review finding: BridgeEngine's copy of Table A-1 left out the per-dimension limit (PicWidthInMbs and
    /// FrameHeightInMbs ≤ √(8 × MaxFS), §A.3.1) that PlatformApple's copy enforced. 2720×240 fits level 3.1's frame size
    /// and macroblock rate, but 170 macroblocks across is more than √(8 × 3600) = 169: it is not a level 3.1 picture.
    /// (The selection, 168 macroblocks across, fits level 3.1 itself: a selection no offered level carries skips the gate.)
    @Test func levelFitIncludesThePerDimensionLimit() {
        let requested = Self.live(2688, 240, level: .level3_1)
        let wide = MediaFit.live(source: Self.h264(2720, 240, level: 0), frameRate: 30, requested: requested)   // no declared level
        #expect(wide != .passthrough)
        #expect(MediaFit.live(source: Self.h264(2704, 240, level: 0), frameRate: 30, requested: requested) == .passthrough)   // 169 across
    }

    /// Review finding (W4): sizes no offered level (≤ 4.0) can carry — 1440p, 4K — were always transcoded at the same size
    /// (and the encoder raised the level anyway), and measured frame-rate jitter just above 30 fps made 1080p transcode.
    @Test func liveLevelGateIgnoresSizesNoOfferedLevelCarriesAndFrameRateJitter() {
        #expect(MediaFit.live(source: Self.h264(3840, 2160, level: 51), frameRate: 30, requested: Self.live(3840, 2160)) == .passthrough)
        #expect(MediaFit.live(source: Self.h264(3840, 2160, level: 51), frameRate: 20, requested: Self.live(3840, 2160, fps: 20)) == .passthrough)
        #expect(MediaFit.live(source: Self.h264(2560, 1440, level: 50), frameRate: 30, requested: Self.live(2560, 1440)) == .passthrough)
        #expect(MediaFit.live(source: Self.h264(2560, 1440, level: 51), frameRate: 15, requested: Self.live(2560, 1440, fps: 15)) == .passthrough)
        // 1080p30 sits 0.4 % under level 4.0's macroblock rate: timestamps measuring 30.15 fps are jitter.
        #expect(MediaFit.live(source: Self.h264(1920, 1080, level: 51), frameRate: 30.15, requested: Self.live(1920, 1080)) == .passthrough)
        #expect(MediaFit.live(source: Self.h264(1920, 1080, level: 41), frameRate: 30.2, requested: Self.live(1920, 1080)) == .passthrough)
        // Size and frame rate still decide.
        #expect(MediaFit.live(source: Self.h264(3840, 2160, level: 51), frameRate: 30, requested: Self.live(2560, 1440)) != .passthrough)
        #expect(MediaFit.live(source: Self.h264(1920, 1080, level: 51), frameRate: 60, requested: Self.live(1920, 1080)) != .passthrough)
    }

    @Test func liveUsesTheSubStreamForSmallRequests() {
        #expect(MediaFit.prefersSubStream(for: Self.live(640, 360), audio: nil))
        #expect(MediaFit.prefersSubStream(for: Self.live(320, 240, fps: 15), audio: nil))
        #expect(MediaFit.prefersSubStream(for: Self.live(960, 540), audio: Self.audio(packetTime: 20)))
        #expect(!MediaFit.prefersSubStream(for: Self.live(1280, 720), audio: Self.audio(packetTime: 20)))
        #expect(!MediaFit.prefersSubStream(for: Self.live(1920, 1080), audio: Self.audio(packetTime: 30)))
        #expect(!MediaFit.prefersSubStream(for: Self.live(1920, 1080), audio: nil))
    }

    static func audio(packetTime: Int) -> SelectedAudioParameters {
        SelectedAudioParameters(codec: .opus, channels: 1, sampleRate: .khz16, packetTimeMs: packetTime, payloadType: 110, controllerSSRC: 2,
                                maxBitrateKbps: 24, rtcpIntervalSeconds: 0.5)
    }

    /// Review finding (W4): remote viewers (packet time ≥ 60 ms, integration brief §5.4) got the main stream at 720p and
    /// 1080p — the camera's full bit rate through the hub's relay, or a needless transcode.
    @Test func remoteRequestsUseTheSubStream() {
        #expect(MediaFit.prefersSubStream(for: Self.live(1280, 720), audio: Self.audio(packetTime: 60)))
        #expect(MediaFit.prefersSubStream(for: Self.live(1920, 1080), audio: Self.audio(packetTime: 60)))
        #expect(MediaFit.prefersSubStream(for: Self.live(1920, 1080), audio: Self.audio(packetTime: 80)))
    }

    // MARK: Stream/quality overrides (docs/CONTRACT_CHANGES.md 2026-10-01)

    @Test func streamModeOverridesTheAutomaticSubStreamChoice() {
        // Automatic keeps the existing size/remote heuristic.
        #expect(MediaFit.prefersSubStream(for: Self.live(1920, 1080), audio: nil, mode: .automatic) == false)
        #expect(MediaFit.prefersSubStream(for: Self.live(320, 240), audio: nil, mode: .automatic) == true)
        // alwaysMain/alwaysSub override it regardless of the request.
        #expect(MediaFit.prefersSubStream(for: Self.live(320, 240), audio: nil, mode: .alwaysMain) == false)
        #expect(MediaFit.prefersSubStream(for: Self.live(1920, 1080), audio: Self.audio(packetTime: 80), mode: .alwaysMain) == false)
        #expect(MediaFit.prefersSubStream(for: Self.live(1920, 1080), audio: nil, mode: .alwaysSub) == true)
    }

    @Test func originalQualityLivePassesThroughIgnoringTheSmallerRequest() {
        // A request far smaller than the source would normally transcode; originalQuality passes it through instead.
        let path = MediaFit.live(source: Self.h264(1920, 1080), frameRate: 25, requested: Self.live(640, 360), qualityMode: .originalQuality)
        #expect(path == .passthrough)
    }

    @Test func originalQualityLiveFallsBackToTranscodeForHEVCOrBFrames() {
        let hevc = VideoFormat(codec: .hevc, width: 1920, height: 1080, parameterSets: [])
        guard case .transcode = MediaFit.live(source: hevc, frameRate: 25, requested: Self.live(640, 360), qualityMode: .originalQuality) else {
            Issue.record("HEVC must fall back to transcode even in originalQuality")
            return
        }
        guard case .transcode(let reason) = MediaFit.live(source: Self.h264(1920, 1080), frameRate: 25, bFrames: true,
                                                           requested: Self.live(640, 360), qualityMode: .originalQuality) else {
            Issue.record("B-frames must fall back to transcode even in originalQuality")
            return
        }
        #expect(reason == MediaFit.bFramesReason)
    }

    @Test func originalWhenPossibleRecordingPassesThroughIgnoringTheSmallerSelectionButKeepsGOPAndProfileChecks() {
        let path = MediaFit.recording(source: Self.h264(1920, 1080), frameRate: 25, gop: .seconds(2), configuration: Self.recording(1280, 720),
                                      qualityMode: .originalWhenPossible)
        #expect(path == .passthrough)
        // GOP longer than the fragment still falls back to transcode.
        guard case .transcode = MediaFit.recording(source: Self.h264(1920, 1080), frameRate: 25, gop: .seconds(8),
                                                    configuration: Self.recording(1280, 720), qualityMode: .originalWhenPossible) else {
            Issue.record("A GOP longer than the fragment must still transcode")
            return
        }
        // HEVC and B-frames still fall back.
        let hevc = VideoFormat(codec: .hevc, width: 1920, height: 1080, parameterSets: [])
        guard case .transcode = MediaFit.recording(source: hevc, frameRate: 25, gop: .seconds(2), configuration: Self.recording(1280, 720),
                                                    qualityMode: .originalWhenPossible) else {
            Issue.record("HEVC must fall back to transcode")
            return
        }
        guard case .transcode(let reason) = MediaFit.recording(source: Self.h264(1920, 1080), frameRate: 25, gop: .seconds(2), bFrames: true,
                                                                configuration: Self.recording(1280, 720), qualityMode: .originalWhenPossible) else {
            Issue.record("B-frames must fall back to transcode")
            return
        }
        #expect(reason == MediaFit.bFramesReason)
    }

    @Test func maxBitrateOverrideKbps() {
        #expect(MaxBitrateOverride.auto.kbps == nil)
        #expect(MaxBitrateOverride.mbps1.kbps == 1_000)
        #expect(MaxBitrateOverride.mbps2.kbps == 2_000)
        #expect(MaxBitrateOverride.mbps4.kbps == 4_000)
        #expect(MaxBitrateOverride.mbps6.kbps == 6_000)
        #expect(MaxBitrateOverride.mbps8.kbps == 8_000)
    }

    @Test func encoderSettingsFollowTheSelection() {
        let recording = MediaFit.encoderSettings(for: Self.recording(1920, 1080, profile: .high, level: .level4_0), sourceFrameRate: 20)
        #expect(recording == VideoEncoderSettings(width: 1920, height: 1080, fps: 30, bitrateKbps: 2000, profile: .high, level: .level4_0,
                                                  keyframeInterval: .seconds(4), realtime: true, expectedFrameRate: 20))
        let live = MediaFit.encoderSettings(for: Self.live(1280, 720, fps: 30, level: .level3_1), sourceFrameRate: nil)
        #expect(live == VideoEncoderSettings(width: 1280, height: 720, fps: 30, bitrateKbps: 299, profile: .main, level: .level3_1,
                                             keyframeInterval: .seconds(2), realtime: true))
        // The keyframe interval never exceeds the fragment length.
        var long = Self.recording(1280, 720)
        long.iFrameIntervalMs = 10_000
        #expect(MediaFit.encoderSettings(for: long, sourceFrameRate: 30).keyframeInterval == .seconds(4))
    }

    /// Review finding (W4 round 3): the measured frame rate (a mean over the last 90 frames, rounded) capped the output
    /// for the whole stream: a 25 fps camera that skipped two frames before motion measured 24.45 and was recorded at
    /// 24 fps, a picture lost every second for up to 3 minutes. The selection is the limit; the measurement is a hint,
    /// rounded up.
    @Test func aFrameRateMeasuredLowIsOnlyAHint() {
        for measured in [24.45, 24.72, 18.69] {
            let recording = MediaFit.encoderSettings(for: Self.recording(640, 360, profile: .baseline, level: .level3_1), sourceFrameRate: measured)
            #expect(recording.fps == 30, "the selected rate limits the output (measured \(measured))")
            #expect(recording.expectedFrameRate == Int(measured.rounded(.up)))
            let live = MediaFit.encoderSettings(for: Self.live(640, 360, fps: 30), sourceFrameRate: measured)
            #expect(live.fps == 30 && live.expectedFrameRate == Int(measured.rounded(.up)))
        }
        // At or above the selection (or unknown): no hint, the selected rate.
        #expect(MediaFit.encoderSettings(for: Self.live(640, 360, fps: 15), sourceFrameRate: 29.97).expectedFrameRate == nil)
        #expect(MediaFit.encoderSettings(for: Self.live(640, 360, fps: 15), sourceFrameRate: nil).fps == 15)
        #expect(VideoEncoderSettings(width: 640, height: 360, fps: 30, bitrateKbps: 500, expectedFrameRate: 25).inputFrameRate == 25)
        #expect(VideoEncoderSettings(width: 640, height: 360, fps: 15, bitrateKbps: 500, expectedFrameRate: 25).inputFrameRate == 15)
    }
}
