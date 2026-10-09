import Foundation
import HAPCamera
import MediaCore
import Testing
@testable import BridgeEngine

/// B-frames and smart-codec GOPs (integration brief §5.6: both drop HKSV clips): what ingest learns about a stream
/// (`StreamTraits`), the passthrough rules that use it, and `TimelineRebaser` telling reordering from a new timeline.
@Suite(.timeLimit(.minutes(1))) struct RuntimeStreamTraitsTests {
    static let format = VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [], profile: 77, level: 31)

    /// A frame of 1/30 s units; `slice` is the slice NAL (header + payload).
    static func frame(_ ticks: Int64, keyframe: Bool = false, dts: Int64? = nil, slice: [UInt8]? = nil) -> EncodedVideoFrame {
        let nal = slice ?? (keyframe ? [0x65, 0x88] : [0x41, 0xC0])
        return EncodedVideoFrame(format: format, nalUnits: [Data(nal)], isKeyframe: keyframe, pts: MediaTime(value: ticks * 3_000, timescale: 90_000),
                                 dts: dts.map { MediaTime(value: $0 * 3_000, timescale: 90_000) }, wallClock: Date())
    }

    // Slice headers: first_mb_in_slice ue(v), slice_type ue(v) (H.264 §7.3.3).
    static let pSlice: [UInt8] = [0x41, 0xC0]            // mb 0, type 0 (P)
    static let pSliceAll: [UInt8] = [0x41, 0x98]         // mb 0, type 5 (P, all slices)
    static let bSlice: [UInt8] = [0x01, 0xA0]            // mb 0, type 1 (B)
    static let bSliceAll: [UInt8] = [0x01, 0x9C]         // mb 0, type 6 (B, all slices)
    static let bSliceLater: [UInt8] = [0x01, 0x03, 0x2A] // mb 100, type 1 (B)

    @Test func bSlicesAreFoundInTheSliceHeader() {
        #expect(!StreamTraits.hasBSlice([Data(Self.pSlice)]))
        #expect(!StreamTraits.hasBSlice([Data(Self.pSliceAll)]))
        #expect(!StreamTraits.hasBSlice([Data([0x65, 0x88])]), "I slice")
        #expect(StreamTraits.hasBSlice([Data(Self.bSlice)]))
        #expect(StreamTraits.hasBSlice([Data(Self.bSliceAll)]))
        #expect(StreamTraits.hasBSlice([Data([0x06, 0x05, 0x01]), Data(Self.bSliceLater)]), "SEI first, then the slice")
        #expect(!StreamTraits.hasBSlice([Data([0x01])]), "a truncated slice header is not a B slice")
        #expect(!StreamTraits.hasBSlice([Data([0x01, 0x00, 0x00, 0x00])]), "an over-long code is ignored")
        #expect(!StreamTraits.hasBSlice([]))
    }

    @Test func traitsReportBFramesAndTheLongestRecentGOP() {
        let traits = StreamTraits()
        #expect(!traits.usesBFrames && traits.longestGOP == nil)
        // A smart codec: 2 s GOPs on average with one of 8 s.
        var time: Int64 = 0
        for gop in [60, 60, 240, 60, 60] as [Int64] {
            traits.observe(.video(Self.frame(time, keyframe: true)))
            traits.observe(.video(Self.frame(time + 1, slice: Self.pSlice)))
            time += gop
        }
        traits.observe(.video(Self.frame(time, keyframe: true)))
        #expect(traits.longestGOP == .seconds(8))
        #expect(!traits.usesBFrames, "P slices only")
        // The window forgets old GOPs.
        for _ in 0..<StreamTraits.gopWindow {
            time += 60
            traits.observe(.video(Self.frame(time, keyframe: true)))
        }
        #expect(traits.longestGOP == .seconds(2))
        // A reconnect starts a new timeline: its first keyframe does not end a GOP.
        traits.restart()
        traits.observe(.video(Self.frame(5, keyframe: true)))
        #expect(traits.longestGOP == .seconds(2))

        traits.observe(.video(Self.frame(time + 2, slice: Self.bSlice)))
        #expect(traits.usesBFrames)
        traits.restart()
        #expect(traits.usesBFrames, "B-frames are a property of the camera's encoder: sticky across a reconnect")

        // HTTP-FLV carries decode times: one that differs from the presentation time is reordering.
        let flv = StreamTraits()
        flv.observe(.video(Self.frame(4, keyframe: true, dts: 4)))
        #expect(!flv.usesBFrames)
        flv.observe(.video(Self.frame(7, dts: 5)))
        #expect(flv.usesBFrames)
    }

    /// Review finding (W4 round 3): B-frame detection never reset, so a user who turned B-frames off as the log advises
    /// kept every recording and live view transcoding (with the same advice logged) until the bridge restarted. A
    /// connection that delivers whole GOPs without a reordered frame clears it; a B-frame camera stays flagged across a
    /// reconnect (the first keyframe comes before its first B slice).
    @Test func bFramesTurnedOffOnTheCameraBringPassthroughBack() {
        let traits = StreamTraits()
        traits.observe(.video(Self.frame(0, keyframe: true)))
        traits.observe(.video(Self.frame(2, slice: Self.bSlice)))
        #expect(traits.usesBFrames)
        // A B-frame camera reconnects: its first GOPs still count as B-frames, the next B slice keeps the flag.
        traits.restart()
        var time: Int64 = 0
        func gop(bFrames: Bool) {
            traits.observe(.video(Self.frame(time, keyframe: true)))
            for index in 1..<30 { traits.observe(.video(Self.frame(time + Int64(index), slice: bFrames && index % 3 == 2 ? Self.bSlice : Self.pSlice))) }
            time += 30
        }
        gop(bFrames: true)
        gop(bFrames: true)
        #expect(traits.usesBFrames)

        // B-frames turned off on the camera: it restarts its encoder (the ingest reconnects), then only I and P frames.
        traits.restart()
        for _ in 0..<StreamTraits.bFrameClearGOPs { gop(bFrames: false) }
        #expect(traits.usesBFrames, "not before whole GOPs without reordering went by")
        traits.observe(.video(Self.frame(time, keyframe: true)))
        #expect(!traits.usesBFrames, "\(StreamTraits.bFrameClearGOPs) whole GOPs without a B slice: passthrough again")

        // Clean GOPs are counted within one connection: a reconnect in between starts again.
        let interrupted = StreamTraits()
        interrupted.observe(.video(Self.frame(0, keyframe: true, dts: 0)))
        interrupted.observe(.video(Self.frame(3, dts: 1)))   // decode time ≠ presentation time: reordering
        #expect(interrupted.usesBFrames)
        interrupted.observe(.video(Self.frame(30, keyframe: true)))
        interrupted.observe(.video(Self.frame(60, keyframe: true)))
        interrupted.restart()
        interrupted.observe(.video(Self.frame(0, keyframe: true)))
        interrupted.observe(.video(Self.frame(30, keyframe: true)))
        #expect(interrupted.usesBFrames)
    }

    @Test func passthroughRefusesBFramesAndUsesTheGOPItIsGiven() {
        let recording = CameraRecordingConfiguration(prebufferLengthMs: 4000, eventTriggers: 1, fragmentLengthMs: 4000, videoProfile: .main,
                                                     videoLevel: .level4_0, videoBitrateKbps: 2000, iFrameIntervalMs: 4000,
                                                     resolution: VideoResolution(1280, 720, 30), audioCodec: .aacLC, audioChannels: 1,
                                                     audioSampleRate: .khz32, audioMaxBitrateKbps: 24)
        #expect(MediaFit.recording(source: Self.format, frameRate: 30, gop: .seconds(2), configuration: recording) == .passthrough)
        #expect(MediaFit.recording(source: Self.format, frameRate: 30, gop: .seconds(2), bFrames: true, configuration: recording)
                == .transcode(MediaFit.bFramesReason))
        // The longest recent GOP (not the mean) decides.
        if case .transcode = MediaFit.recording(source: Self.format, frameRate: 30, gop: .seconds(8), configuration: recording) {} else {
            Issue.record("an 8 s GOP must not pass through 4 s fragments")
        }
        let live = SelectedVideoParameters(profile: .main, level: .level4_0, resolution: VideoResolution(1280, 720, 30), payloadType: 99, controllerSSRC: 1,
                                           maxBitrateKbps: 299, rtcpIntervalSeconds: 0.5, mtu: 1378)
        #expect(MediaFit.live(source: Self.format, frameRate: 30, requested: live) == .passthrough)
        #expect(MediaFit.live(source: Self.format, frameRate: 30, bFrames: true, requested: live) == .transcode(MediaFit.bFramesReason))
    }

    @Test func rebaserPassesReorderedFramesAndRebasesNewTimelines() {
        var rebaser = TimelineRebaser()
        // Decode order of I P B B P B B I without decode times (presentation times step back for B-frames).
        let order: [(Int64, Bool)] = [(0, true), (3, false), (1, false), (2, false), (6, false), (4, false), (5, false), (9, true)]
        for (ticks, keyframe) in order {
            let out = rebaser.video(Self.frame(ticks, keyframe: keyframe))
            #expect(out.pts == MediaTime(value: ticks * 3_000, timescale: 90_000), "reordered frames keep their presentation times")
        }
        #expect(rebaser.discontinuities == 0)
        // The source reconnected: its first keyframe goes back to 0 — a new timeline that continues after the last one.
        let restarted = rebaser.video(Self.frame(0, keyframe: true))
        #expect(rebaser.discontinuities == 1)
        #expect(restarted.pts > MediaTime(value: 9 * 3_000, timescale: 90_000))
        // A frame far behind (more than `maximumReorder`) is a new timeline too.
        var far = TimelineRebaser()
        _ = far.video(Self.frame(300, keyframe: true))
        _ = far.video(Self.frame(301))
        _ = far.video(Self.frame(240))
        #expect(far.discontinuities == 1)
        // Frames with decode times must move forward: a step back is a new timeline (as before).
        var decoded = TimelineRebaser()
        _ = decoded.video(Self.frame(10, keyframe: true, dts: 10))
        _ = decoded.video(Self.frame(12, dts: 11))
        let back = decoded.video(Self.frame(11, dts: 10))
        #expect(decoded.discontinuities == 1)
        #expect(back.dts.map { $0 > MediaTime(value: 11 * 3_000, timescale: 90_000) } == true)
    }
}
