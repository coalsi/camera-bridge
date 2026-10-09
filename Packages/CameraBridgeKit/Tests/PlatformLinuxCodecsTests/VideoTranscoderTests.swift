import Foundation
import MediaCore
import Testing
@testable import PlatformLinux

/// The transcoder against a real ffmpeg (skipped without one).
@Suite(.serialized, .enabled(if: FFmpegTesting.available)) struct VideoTranscoderTests {
    private func settings(width: Int = 320, height: Int = 180, fps: Int = 25, bitrate: Int = 500, keyframe: Int = 2) -> VideoEncoderSettings {
        VideoEncoderSettings(width: width, height: height, fps: fps, bitrateKbps: bitrate, profile: .main, level: .level3_1, keyframeInterval: .seconds(keyframe))
    }

    /// Feeds `frames` one every `interval` and returns everything that came out, the tail still inside ffmpeg included (waited for,
    /// bounded: until nothing new came for 0.3 s).
    private func feed(_ transcoder: any VideoTranscoding, _ frames: [EncodedVideoFrame], interval: Duration = .milliseconds(30)) async throws -> [EncodedVideoFrame] {
        var out: [EncodedVideoFrame] = []
        for frame in frames {
            out += try await transcoder.transcode(frame)
            try await Task.sleep(for: interval)
        }
        return out + (try await drain(transcoder, started: !out.isEmpty))
    }

    /// Waits (at most 5 s) until nothing new has come for 0.3 s; while nothing at all has come yet (a slow start) quiet does not count.
    private func drain(_ transcoder: any VideoTranscoding, started: Bool) async throws -> [EncodedVideoFrame] {
        guard let transcoder = transcoder as? FFmpegVideoTranscoder else { return [] }
        var out: [EncodedVideoFrame] = []
        var quiet = 0
        var seen = started
        for _ in 0..<100 where quiet < 6 {
            try await Task.sleep(for: .milliseconds(50))
            let more = transcoder.collectAvailable()
            if more.isEmpty {
                if seen { quiet += 1 }
            } else {
                seen = true
                quiet = 0
                out += more
            }
        }
        return out
    }

    /// Decodes `frames` (starting at a keyframe) and returns the pictures.
    private func decode(_ frames: [EncodedVideoFrame]) async throws -> [RawVideoFrame] {
        let codecs = FFmpegTesting.makeCodecs()
        let decoder = try codecs.makeVideoDecoder(format: try #require(frames.first).format)
        defer { decoder.invalidate() }
        var pictures: [RawVideoFrame] = []
        for frame in frames {
            if let picture = try await decoder.decode(frame) as? RawVideoFrame { pictures.append(picture) }
        }
        return pictures
    }

    @Test func transcodesH264ToTheRequestedSizeProfileAndLevel() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 640, height: 360, fps: 25, seconds: 3, gop: 25)
        let transcoder = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        let begun = ContinuousClock.now
        var firstOutput: Duration?
        var out: [EncodedVideoFrame] = []
        for frame in source {
            let produced = try await transcoder.transcode(frame)
            if !produced.isEmpty, firstOutput == nil { firstOutput = ContinuousClock.now - begun }
            out += produced
            try await Task.sleep(for: .milliseconds(30))
        }
        out += try await drain(transcoder, started: !out.isEmpty)
        #expect(try #require(firstOutput) < .seconds(3))
        #expect(out.count == source.count, "\(out.count) of \(source.count)")
        let first = try #require(out.first)
        #expect(first.isKeyframe && first.format.codec == .h264)
        #expect(first.format.width == 320 && first.format.height == 180)
        #expect(first.format.profile == 77 && first.format.level == 31)   // main, 3.1
        // Every output has the exact PTS and wall clock of the picture it came from, in order, without decode times.
        let times = Set(source.map(\.pts))
        #expect(out.allSatisfy { times.contains($0.pts) && $0.dts == nil })
        #expect(zip(out, out.dropFirst()).allSatisfy { $0.pts < $1.pts })
        let wallClocks = Dictionary(uniqueKeysWithValues: source.map { ($0.pts, $0.wallClock) })
        #expect(out.allSatisfy { wallClocks[$0.pts] == $0.wallClock })
        // The keyframe cadence follows the setting (2 s at 25 fps), not scene cuts.
        let keyframes = out.enumerated().filter { $0.element.isKeyframe }.map(\.offset)
        #expect(keyframes.first == 0 && keyframes.dropFirst().allSatisfy { $0 % 50 == 0 || $0 % 25 == 0 })
        // Frames carry slices only: the parameter sets live in the format.
        #expect(out.allSatisfy { frame in frame.nalUnits.allSatisfy { ![6, 7, 8, 9].contains(NALUnits.h264Type($0)) } })
        #expect(first.format.parameterSets.count == 2)
    }

    @Test func theOutputDecodesToTheSamePictures() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 2, gop: 25)
        let transcoder = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: settings(bitrate: 800))
        defer { transcoder.invalidate() }
        let out = try await feed(transcoder, source)
        let pictures = try await decode(out)
        #expect(pictures.count >= out.count - 1)
        let original = try await decode(source)
        // Same pictures (the test pattern), within coding noise: compare mean luma of the first keyframe.
        let a = try #require(original.first?.pictureStatistics()), b = try #require(pictures.first?.pictureStatistics())
        #expect(abs(a.meanLuma - b.meanLuma) < 6, "\(a.meanLuma) vs \(b.meanLuma)")
        #expect(pictures.first?.width == 320 && pictures.first?.height == 180)
    }

    @Test func aKeyframeRequestMakesOneIDRRightAway() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 4, gop: 100)
        let transcoder = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: settings(keyframe: 60))
        defer { transcoder.invalidate() }
        var out = try await feed(transcoder, Array(source[0..<30]))
        #expect(out.filter(\.isKeyframe).count == 1)
        transcoder.requestKeyframe()
        let before = out.count
        out += try await feed(transcoder, Array(source[30..<60]))
        // The picture sent after the request (and any delay of the pipeline) is the keyframe; none else is.
        let keyframes = out[before...].enumerated().filter { $0.element.isKeyframe }.map(\.offset)
        #expect(keyframes.count == 1, "keyframes at \(keyframes)")
        #expect(try #require(keyframes.first) <= 3)
        // Requests are repeatable.
        transcoder.requestKeyframe()
        let again = out.count
        out += try await feed(transcoder, Array(source[60..<80]))
        #expect(out[again...].filter(\.isKeyframe).count == 1)
    }

    @Test func theFrameRateLimitKeepsAtMostFPSPicturesPerSecond() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 4, gop: 50)
        let transcoder = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: settings(fps: 10))
        defer { transcoder.invalidate() }
        let out = try await feed(transcoder, source, interval: .milliseconds(10))
        // 4 s at 10 fps ≈ 40 (the tail may still be inside ffmpeg).
        #expect((38...41).contains(out.count), "\(out.count) pictures")
        let gaps = zip(out, out.dropFirst()).map { ($1.pts - $0.pts).seconds }
        #expect(gaps.allSatisfy { $0 >= 0.07 }, "gaps \(gaps.min() ?? 0)")
        #expect(out.first?.isKeyframe == true)
        // An input at or below the limit loses nothing.
        let slow = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: settings(fps: 25))
        defer { slow.invalidate() }
        let all = try await feed(slow, Array(source[0..<50]), interval: .milliseconds(10))
        #expect(all.count == 50, "\(all.count)")
    }

    @Test func aKeyframeRequestIsNotLostToTheFrameRateLimit() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 4, gop: 100)
        let transcoder = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: settings(fps: 10, keyframe: 60))
        defer { transcoder.invalidate() }
        var out = try await feed(transcoder, Array(source[0..<40]), interval: .milliseconds(15))
        let before = out.count
        // Every second picture would be skipped by the limiter; ask for a keyframe on each parity in turn.
        for offset in 0..<4 {
            transcoder.requestKeyframe()
            out += try await feed(transcoder, Array(source[(40 + offset * 10)..<(50 + offset * 10)]), interval: .milliseconds(15))
        }
        let keyframes = out[before...].filter(\.isKeyframe).count
        #expect(keyframes == 4, "\(keyframes) keyframes for 4 requests")
    }

    @Test func aBitrateChangeRestartsAndTheStreamContinuesWithAnIDR() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 6, gop: 150)
        let transcoder = try FFmpegTransocderForTests.make(settings: settings(bitrate: 800, keyframe: 20), minimumRunTime: .zero)
        defer { transcoder.invalidate() }
        var out = try await feed(transcoder, Array(source[0..<40]))
        #expect(out.filter(\.isKeyframe).count == 1)
        transcoder.updateBitrate(kbps: 300)
        out += try await feed(transcoder, Array(source[40..<100]))
        // The restart produced an IDR of the picture sent with the change, and no picture was lost or repeated around it.
        let keyframes = out.enumerated().filter { $0.element.isKeyframe }.map(\.offset)
        #expect(keyframes.count == 2, "keyframes at \(keyframes)")
        #expect(zip(out, out.dropFirst()).allSatisfy { $0.pts < $1.pts })
        let gap = zip(out, out.dropFirst()).map { ($1.pts - $0.pts).seconds }.max() ?? 0
        #expect(gap <= 0.2, "largest gap \(gap) s")
        // The second half is encoded at the lower rate: its frames are smaller on average.
        let half = keyframes[1]
        func bytes(_ frames: ArraySlice<EncodedVideoFrame>) -> Int { frames.reduce(0) { $0 + $1.nalUnits.reduce(0) { $0 + $1.count } } }
        let delta = out[(half + 1)...].filter { !$0.isKeyframe }
        #expect(!delta.isEmpty)
        // Everything after the restart decodes from its keyframe.
        let pictures = try await decode(Array(out[half...]))
        #expect(pictures.count >= out.count - half - 1)
    }

    @Test func catchUpDecodesTheGOPAndEncodesOneKeyframeOfTheNewestPicture() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 3, gop: 75)
        let transcoder = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        let gop = Array(source[0..<60])
        let begun = ContinuousClock.now
        let out = try await transcoder.catchUp(gop)
        #expect(ContinuousClock.now - begun < .seconds(5))
        #expect(out.count == 1 && out[0].isKeyframe)
        #expect(out[0].pts == gop[59].pts)
        // Live frames follow on the same child as deltas.
        let next = try await feed(transcoder, Array(source[60..<75]))
        #expect(!next.isEmpty && next.allSatisfy { !$0.isKeyframe })
        #expect(next.first.map { $0.pts > gop[59].pts } == true)
        let pictures = try await decode(out + next)
        #expect(pictures.count >= next.count)
    }

    @Test(.enabled(if: FFmpegTesting.canEncodeHEVC))
    func hevcInputIsTranscodedToH264() async throws {
        let source = try FFmpegTesting.sourceFrames(codec: .hevc, width: 320, height: 180, fps: 25, seconds: 2, gop: 25)
        let transcoder = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        let out = try await feed(transcoder, source)
        #expect(out.count == source.count)
        #expect(out.first?.format.codec == .h264 && out.first?.isKeyframe == true)
    }

    @Test func sourcesWithBFramesKeepTheirPresentationTimes() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 2, gop: 25, bFrames: true)
        #expect(source.contains { $0.dts != nil }, "the test source has no B-frames")
        let transcoder = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        let out = try await feed(transcoder, source)
        // The decoder holds back as many pictures as the stream reorders (two) until the next ones arrive.
        #expect(out.count >= source.count - 3 && out.count <= source.count, "\(out.count) of \(source.count)")
        let times = Set(source.map(\.pts))
        #expect(out.allSatisfy { times.contains($0.pts) })
        #expect(zip(out, out.dropFirst()).allSatisfy { $0.pts < $1.pts })
    }

    @Test func aDifferentAspectRatioGetsBars() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 640, height: 360, fps: 25, seconds: 1, gop: 25)
        let transcoder = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: settings(width: 320, height: 320))
        defer { transcoder.invalidate() }
        let out = try await feed(transcoder, source)
        let pictures = try await decode(out)
        let picture = try #require(pictures.first)
        #expect(picture.width == 320 && picture.height == 320)
        // 16:9 inside a square: 320×180 of picture, 70 rows of black bar at the top and the bottom.
        let top = picture.pixels.prefix(320 * 60)
        let middle = picture.pixels[(320 * 150)..<(320 * 170)]
        #expect(top.allSatisfy { $0 <= 20 }, "top bar is not black")
        #expect(middle.contains { $0 > 60 })
    }

    @Test(.enabled(if: FFmpegTesting.canDrawOverlay))
    func theTimestampOverlayIsDrawnOnTheOutput() async throws {
        let codecs = FFmpegTesting.makeCodecs()
        let source = try FFmpegTesting.sourceFrames(width: 640, height: 360, fps: 25, seconds: 1, gop: 25)
        func run(overlay: (any TimestampOverlayProviding)?) async throws -> RawVideoFrame {
            let transcoder = try codecs.makeVideoTranscoder(output: settings(width: 640, height: 360, bitrate: 2_000), overlay: overlay)
            defer { transcoder.invalidate() }
            let out = try await feed(transcoder, source)
            return try #require(try await decode(out).first)
        }
        let enabled = TimestampOverlay(settings: TimestampOverlaySettings(enabled: true, position: .topRight, showCameraName: true, showDate: true, showSeconds: true, use24Hour: true,
                                                                          size: .large), cameraName: "Front Door", clock: FixedOverlayClock(Date(timeIntervalSince1970: 1_800_000_000)))
        let plain = try await run(overlay: nil)
        let drawn = try await run(overlay: StaticTimestampOverlay(enabled))
        func difference(x: Range<Int>, y: Range<Int>) -> Double {
            var total = 0
            for row in y { for column in x { total += abs(Int(plain.pixels[row * 640 + column]) - Int(drawn.pixels[row * 640 + column])) } }
            return Double(total) / Double(x.count * y.count)
        }
        // Changed in the top right corner, unchanged on the opposite side.
        #expect(difference(x: 360..<630, y: 10..<60) > 8)
        #expect(difference(x: 10..<200, y: 250..<350) < 3)
        // Disabled settings draw nothing.
        var off = enabled
        off.settings.enabled = false
        let notDrawn = try await run(overlay: StaticTimestampOverlay(off))
        #expect(zip(plain.pixels, notDrawn.pixels).filter { abs(Int($0) - Int($1)) > 6 }.count < plain.pixels.count / 200)
    }

    @Test func killingFFmpegSurfacesAnErrorAndTheNextKeyframeRecovers() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 4, gop: 25)
        let transcoder = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: settings(bitrate: 744))
        defer { transcoder.invalidate() }
        let out = try await feed(transcoder, Array(source[0..<20]))
        #expect(!out.isEmpty)
        #expect(ChildProcesses.kill(commandContaining: "744k") >= 1)
        var thrown: MediaCodecError?
        var index = 20
        while index < 25, thrown == nil {
            do { _ = try await transcoder.transcode(source[index]) } catch let error as MediaCodecError { thrown = error }
            index += 1
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(thrown != nil, "no error after the child was killed")
        // Delta frames are dropped until the next keyframe (frame 25, 50, 75), which starts a new child.
        let recovered = try await feed(transcoder, Array(source[25..<60]))
        #expect(recovered.first?.isKeyframe == true)
        #expect(recovered.count >= 30)
    }

    @Test func invalidateKillsTheChildAndLeavesNothingBehind() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 1, gop: 25)
        let transcoder = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: settings(bitrate: 733))
        _ = try await feed(transcoder, Array(source[0..<5]))
        #expect(ChildProcesses.count(commandContaining: "733k") == 1)
        transcoder.invalidate()
        let gone = try await FFmpegTesting.eventually(timeout: .seconds(5)) { ChildProcesses.count(commandContaining: "733k") == 0 ? true : nil }
        #expect(gone == true, "the ffmpeg child outlived invalidate()")
        let reaped = try await FFmpegTesting.eventually(timeout: .seconds(5)) { ChildProcesses.zombies(commandContaining: "ffmpeg").isEmpty ? true : nil }
        #expect(reaped == true, "zombies: \(ChildProcesses.zombies(commandContaining: "ffmpeg"))")
    }

    @Test func releasingTheTranscoderKillsTheChild() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 1, gop: 25)
        var transcoder: (any VideoTranscoding)? = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: settings(bitrate: 722))
        _ = try await feed(try #require(transcoder), Array(source[0..<5]))
        #expect(ChildProcesses.count(commandContaining: "722k") == 1)
        transcoder = nil
        let gone = try await FFmpegTesting.eventually(timeout: .seconds(5)) { ChildProcesses.count(commandContaining: "722k") == 0 ? true : nil }
        #expect(gone == true, "the ffmpeg child outlived its transcoder")
    }

    @Test func aParameterSetChangeOnAKeyframeStartsANewChildAtTheNewSize() async throws {
        let small = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 1, gop: 25)
        let large = try FFmpegTesting.sourceFrames(width: 480, height: 270, fps: 25, seconds: 1, gop: 25, startPTS: 100_000)
        let transcoder = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: settings(width: 320, height: 180))
        defer { transcoder.invalidate() }
        let out = try await feed(transcoder, small + large)
        #expect(out.count >= small.count + large.count - 6)
        #expect(out.allSatisfy { $0.format.width == 320 && $0.format.height == 180 })
        let pictures = try await decode(out)
        #expect(pictures.allSatisfy { $0.width == 320 && $0.height == 180 })
        // The switch happened at the keyframe of the new stream.
        let index = try #require(out.firstIndex { $0.pts >= large[0].pts })
        #expect(out[index].isKeyframe)
    }

    @Test func severalTranscodersRunAtOnceAndLeaveNothingBehind() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 2, gop: 25)
        let codecs = FFmpegTesting.makeCodecs()
        let counts = try await withThrowingTaskGroup(of: Int.self) { group -> [Int] in
            for index in 0..<6 {
                group.addTask {
                    let transcoder = try codecs.makeVideoTranscoder(output: VideoEncoderSettings(width: 320, height: 180, fps: 25, bitrateKbps: 400 + index,
                                                                                                 profile: .main, level: .level3_1, keyframeInterval: .seconds(1)))
                    defer { transcoder.invalidate() }
                    var produced = 0
                    for frame in source {
                        produced += try await transcoder.transcode(frame).count
                        try await Task.sleep(for: .milliseconds(30))
                    }
                    return produced
                }
            }
            var all: [Int] = []
            for try await count in group { all.append(count) }
            return all
        }
        #expect(counts.count == 6 && counts.allSatisfy { $0 >= source.count - 8 }, "outputs \(counts) of \(source.count)")
        let gone = try await FFmpegTesting.eventually(timeout: .seconds(5)) { (0..<6).allSatisfy { ChildProcesses.count(commandContaining: "\(400 + $0)k") == 0 } ? true : nil }
        #expect(gone == true)
    }

    @Test func diagnosticsNameTheCodecs() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 1, gop: 25)
        let transcoder = try FFmpegTesting.makeCodecs(FFmpegCodecsConfiguration(videoEncoder: .software)).makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        _ = try await feed(transcoder, source)
        let diagnostics = transcoder.diagnostics
        #expect(diagnostics.encoderIsHardware == false && diagnostics.decoderIsHardware == false)
        #expect((diagnostics.lastKeyframeBytes ?? 0) > 100 && diagnostics.lastKeyframeWidth == 320 && diagnostics.lastKeyframeHeight == 180)
    }
}

enum FFmpegTransocderForTests {
    static func make(settings: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)? = nil, minimumRunTime: Duration) throws -> FFmpegVideoTranscoder {
        try FFmpegVideoTranscoder(runtime: FFmpegTesting.makeCodecs().runtime, output: settings, overlay: overlay, minimumRunTime: minimumRunTime)
    }
}
