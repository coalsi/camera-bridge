import BridgeSupport
import Foundation
import MediaCore
import Synchronization
import Testing
@testable import PlatformLinux

/// Plays the part of the transcoder's ffmpeg: reads the FLV written to its stdin and answers each picture with an encoded one
/// (a keyframe for the first, and for any picture with an odd millisecond, as `-force_key_frames` would), skipping pictures
/// before the catch-up threshold in its arguments.
final class ScriptedVideoFFmpeg: @unchecked Sendable {
    private let lock = NSLock()
    private var inputFrames: [(ptsMs: UInt32, key: Bool)] = []
    let output: FakeEncoderOutput
    /// Answer nothing (a wedged child).
    var silent = false

    init(format: VideoFormat = TestFormats.h264) {
        output = FakeEncoderOutput(format: format)
    }

    private final class ChildState: @unchecked Sendable {
        var reader = FLVReader()
        var answered = 0
    }

    func attach(to child: FakeFFmpegLauncher.Child) {
        guard child.spec.label == "video transcoder" else { return }
        let skip = Self.skipThreshold(in: child.arguments)
        let state = ChildState()
        child.onWrite = { [self] child, data in
            lock.lock()
            let tags = state.reader.push(data)
            lock.unlock()
            for tag in tags where tag.kind == .video {
                guard case .frame(let key, let composition, _)? = FLVAVCPacket.parse(tag) else { continue }
                let ptsMs = tag.timestamp + UInt32(max(0, composition))
                lock.lock()
                inputFrames.append((ptsMs, key))
                lock.unlock()
                if let skip, Double(ptsMs) / 1000 < skip { continue }
                if silent { continue }
                let first = state.answered == 0
                state.answered += 1
                if first { child.emit(output.header()) }
                child.emit(output.frame(ptsMs: ptsMs, keyframe: first || ptsMs & 1 == 1))
            }
        }
    }

    /// Input pictures as the children saw them.
    var inputs: [(ptsMs: UInt32, key: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return inputFrames
    }

    static func skipThreshold(in arguments: [String]) -> Double? {
        guard let index = arguments.firstIndex(where: { $0 == "-vf" || $0 == "-filter_complex" }), index + 1 < arguments.count else { return nil }
        let chain = arguments[index + 1]
        guard let range = chain.range(of: "if(gte(t,") else { return nil }
        let rest = chain[range.upperBound...]
        return Double(rest.prefix { $0 != ")" && $0 != "," })
    }
}

@Suite(.serialized) struct FakeTranscoderTests {
    private func settings(width: Int = 320, height: Int = 180, bitrate: Int = 1_000) -> VideoEncoderSettings {
        VideoEncoderSettings(width: width, height: height, fps: 25, bitrateKbps: bitrate, profile: .main, level: .level3_1, keyframeInterval: .seconds(2))
    }

    private struct Rig {
        let launcher: FakeFFmpegLauncher
        let codecs: FFmpegMediaCodecs
        let script: ScriptedVideoFFmpeg

        var transcoderChildren: [FakeFFmpegLauncher.Child] { launcher.children.filter { $0.spec.label == "video transcoder" } }
    }

    private func rig(configuration: FFmpegCodecsConfiguration = FFmpegCodecsConfiguration(fontFile: TestFonts.path), vaapi: Bool = false) -> Rig {
        let launcher = FakeFFmpegLauncher()
        let script = ScriptedVideoFFmpeg()
        let codecs = FFmpegMediaCodecs.fake(launcher, configuration: configuration)
        let probe = launcher.onLaunch
        launcher.onLaunch = { child in
            probe?(child)
            script.attach(to: child)
            if vaapi, child.arguments.contains("h264_vaapi"), child.arguments.contains("-f"), child.arguments.contains("null") {
                child.exit(status: 0)
            }
        }
        return Rig(launcher: launcher, codecs: codecs, script: script)
    }

    @Test func noChildUntilTheFirstKeyframe() async throws {
        let rig = rig()
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        #expect(try await transcoder.transcode(TestFormats.frame(0, key: false)).isEmpty)
        #expect(try await transcoder.transcode(TestFormats.frame(1, key: false)).isEmpty)
        #expect(rig.transcoderChildren.isEmpty)
        let out = try await transcoder.transcode(TestFormats.frame(2, key: true))
        #expect(rig.transcoderChildren.count == 1)
        #expect(out.count == 1 && out[0].isKeyframe)
    }

    @Test func startsOneChildWithTheHeaderAndTheKeyframe() async throws {
        let rig = rig()
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        _ = try await transcoder.transcode(TestFormats.frame(0, key: true))
        let child = try #require(rig.transcoderChildren.first)
        var reader = FLVReader()
        let tags = reader.push(child.input)
        #expect(tags.count == 2)
        guard case .sequenceHeader(let record)? = FLVAVCPacket.parse(tags[0]) else { Issue.record("no sequence header first"); return }
        #expect(FLVAVCPacket.parameterSets(avcC: record)?.sps == [TestFormats.sps])
        guard case .frame(let key, _, let nals)? = FLVAVCPacket.parse(tags[1]) else { Issue.record("no frame"); return }
        // A keyframe carries the parameter sets in band, then its slice.
        #expect(key && nals.first == TestFormats.sps && nals.dropFirst().first == TestFormats.pps && nals.count == 3)
        #expect(child.arguments.contains("libx264") && child.arguments.contains("1000k"))
        #expect(tags[1].timestamp == UInt32(VideoFLVStream.margin))
    }

    @Test func outputsCarryTheExactSourceTimesAndWallClocks() async throws {
        let rig = rig()
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        var out: [EncodedVideoFrame] = []
        for index in 0..<10 { out += try await transcoder.transcode(TestFormats.frame(index, key: index == 0)) }
        #expect(out.count == 10)
        for (index, frame) in out.enumerated() {
            let source = TestFormats.frame(index, key: false)
            #expect(frame.pts == source.pts, "picture \(index)")
            #expect(frame.wallClock == source.wallClock)
            #expect(frame.dts == nil)
            #expect(frame.isKeyframe == (index == 0))
        }
    }

    @Test func aKeyframeRequestMakesTheNextPictureOdd() async throws {
        let rig = rig()
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        for index in 0..<5 { _ = try await transcoder.transcode(TestFormats.frame(index, key: index == 0)) }
        transcoder.requestKeyframe()
        var out: [EncodedVideoFrame] = []
        for index in 5..<9 { out += try await transcoder.transcode(TestFormats.frame(index, key: false)) }
        // Exactly the first picture after the request is an IDR; the request is used up.
        #expect(out.map(\.isKeyframe) == [true, false, false, false])
        let inputs = rig.script.inputs
        #expect(inputs.map { $0.ptsMs & 1 == 1 } == [false, false, false, false, false, true, false, false, false])
    }

    @Test func aChildThatDiesSurfacesAsAnErrorAndAnotherStartsAtTheNextKeyframe() async throws {
        let rig = rig()
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        _ = try await transcoder.transcode(TestFormats.frame(0, key: true))
        let child = try #require(rig.transcoderChildren.first)
        child.exit(status: 1, stderr: ["[libx264 @ 0x1] broken", "Conversion failed!"])
        let error = await #expect(throws: MediaCodecError.self) { _ = try await transcoder.transcode(TestFormats.frame(1, key: false)) }
        let message = "\(try #require(error))"
        #expect(message.contains("status 1") && message.contains("Conversion failed!"), "\(message)")
        // Delta frames wait for a keyframe; the keyframe starts a new child.
        #expect(try await transcoder.transcode(TestFormats.frame(2, key: false)).isEmpty)
        #expect(rig.transcoderChildren.count == 1)
        let out = try await transcoder.transcode(TestFormats.frame(3, key: true))
        #expect(rig.transcoderChildren.count == 2)
        #expect(out.first?.isKeyframe == true)
    }

    @Test func aChildThatCannotBeWrittenToSurfacesAsAnError() async throws {
        let rig = rig()
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        _ = try await transcoder.transcode(TestFormats.frame(0, key: true))
        let child = try #require(rig.transcoderChildren.first)
        child.failWrites = true
        await #expect(throws: MediaCodecError.self) { _ = try await transcoder.transcode(TestFormats.frame(1, key: false)) }
    }

    @Test func invalidateTerminatesTheChildAndLaterCallsDoNothing() async throws {
        let rig = rig()
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings())
        _ = try await transcoder.transcode(TestFormats.frame(0, key: true))
        let child = try #require(rig.transcoderChildren.first)
        #expect(!child.terminated)
        transcoder.invalidate()
        #expect(child.terminated)
        #expect(try await transcoder.transcode(TestFormats.frame(1, key: false)).isEmpty)
        #expect(try await transcoder.transcode(TestFormats.frame(2, key: true)).isEmpty)
        #expect(rig.transcoderChildren.count == 1)
    }

    @Test func releasingTheTranscoderKillsTheChild() async throws {
        let rig = rig()
        var transcoder: (any VideoTranscoding)? = try rig.codecs.makeVideoTranscoder(output: settings())
        _ = try await transcoder?.transcode(TestFormats.frame(0, key: true))
        let child = try #require(rig.transcoderChildren.first)
        transcoder = nil
        #expect(child.terminated)
    }

    @Test func aBitrateChangeRestartsTheChildFromTheCurrentGOP() async throws {
        let rig = rig()
        let transcoder = try FFmpegVideoTranscoder(runtime: rig.codecs.runtime, output: settings(bitrate: 1_000), overlay: nil, minimumRunTime: .zero)
        defer { transcoder.invalidate() }
        for index in 0..<4 { _ = try await transcoder.transcode(TestFormats.frame(index, key: index == 0)) }
        // A small change does nothing; a large one restarts.
        transcoder.updateBitrate(kbps: 1_050)
        _ = try await transcoder.transcode(TestFormats.frame(4, key: false))
        #expect(rig.transcoderChildren.count == 1)
        transcoder.updateBitrate(kbps: 600)
        let out = try await transcoder.transcode(TestFormats.frame(5, key: false))
        #expect(rig.transcoderChildren.count == 2)
        let second = rig.transcoderChildren[1]
        #expect(second.arguments.contains("600k") && rig.transcoderChildren[0].terminated)
        // The new child got the whole GOP (the six pictures so far) but its filter keeps only the newest, which comes out as a keyframe of that picture.
        #expect(rig.script.inputs.count == 5 + 6)
        #expect(out.count == 1 && out[0].isKeyframe)
        #expect(out[0].pts == TestFormats.frame(5, key: false).pts)
        // And the stream goes on from there on the new child.
        let next = try await transcoder.transcode(TestFormats.frame(6, key: false))
        #expect(next.count == 1 && !next[0].isKeyframe && next[0].pts == TestFormats.frame(6, key: false).pts)
    }

    @Test func aFormatChangeOnAKeyframeStartsANewChild() async throws {
        let rig = rig()
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        _ = try await transcoder.transcode(TestFormats.frame(0, key: true))
        let other = VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [Data([0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40, 0x50]), TestFormats.pps])
        // A delta frame of an unknown stream is not decodable: dropped, the child kept until its keyframe.
        #expect(try await transcoder.transcode(TestFormats.frame(1, key: false, format: other)).isEmpty)
        #expect(rig.transcoderChildren.count == 1)
        _ = try await transcoder.transcode(TestFormats.frame(2, key: true, format: other))
        #expect(rig.transcoderChildren.count == 2)
        #expect(rig.transcoderChildren[0].terminated)
        // The new child scales 640×360 to the 320×180 output.
        #expect(rig.transcoderChildren[1].arguments.contains { $0.contains("scale=320:180") })
    }

    @Test func catchUpStartsAChildOnTheNewestGOPAndReturnsOneKeyframeOfTheNewestPicture() async throws {
        let rig = rig()
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        // Two GOPs: only the last keyframe and what follows it are replayed.
        let frames = (0..<8).map { TestFormats.frame($0, key: $0 == 0 || $0 == 4) }
        let out = try await transcoder.catchUp(frames)
        let child = try #require(rig.transcoderChildren.first)
        #expect(rig.script.inputs.count == 4)
        #expect(ScriptedVideoFFmpeg.skipThreshold(in: child.arguments) != nil)
        #expect(out.count == 1 && out[0].isKeyframe && out[0].pts == frames[7].pts)
        // Live frames continue on the same child.
        let next = try await transcoder.transcode(TestFormats.frame(8, key: false))
        #expect(rig.transcoderChildren.count == 1 && next.count == 1 && !next[0].isKeyframe && next[0].pts == TestFormats.frame(8, key: false).pts)
    }

    @Test func catchUpWithoutAKeyframeReturnsNothing() async throws {
        let rig = rig()
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        #expect(try await transcoder.catchUp([TestFormats.frame(1, key: false), TestFormats.frame(2, key: false)]).isEmpty)
        #expect(rig.transcoderChildren.isEmpty)
    }

    @Test func catchUpFailsWhenTheChildDiesBeforeAnswering() async throws {
        let rig = rig()
        rig.script.silent = true
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        let launcher = rig.launcher
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            launcher.children.first { $0.spec.label == "video transcoder" }?.exit(status: 234, stderr: ["Invalid data found when processing input"])
        }
        let error = await #expect(throws: MediaCodecError.self) { _ = try await transcoder.catchUp([TestFormats.frame(0, key: true), TestFormats.frame(1, key: false)]) }
        #expect("\(try #require(error))".contains("Invalid data found"))
    }

    @Test func unusableSettingsAreRefusedAtCreation() {
        let rig = rig()
        #expect(throws: MediaCodecError.self) { _ = try rig.codecs.makeVideoTranscoder(output: VideoEncoderSettings(width: 0, height: 100, fps: 30, bitrateKbps: 100)) }
        #expect(throws: MediaCodecError.self) { _ = try rig.codecs.makeVideoTranscoder(output: VideoEncoderSettings(width: 100, height: 100, fps: 0, bitrateKbps: 100)) }
        #expect(throws: MediaCodecError.self) { _ = try rig.codecs.makeVideoTranscoder(output: VideoEncoderSettings(width: 100, height: 100, fps: 30, bitrateKbps: 0)) }
    }

    @Test func withoutFFmpegEveryMakeThrows() {
        let codecs = FFmpegMediaCodecs(configuration: FFmpegCodecsConfiguration(executable: URL(fileURLWithPath: "/nonexistent/ffmpeg")))
        #expect(!codecs.isAvailable)
        #expect(throws: MediaCodecError.self) { _ = try codecs.makeVideoTranscoder(output: settings()) }
        #expect(throws: MediaCodecError.self) { _ = try codecs.makeVideoDecoder(format: TestFormats.h264) }
        #expect(throws: MediaCodecError.self) { _ = try codecs.makeVideoEncoder(settings: settings()) }
        #expect(throws: MediaCodecError.self) { _ = try codecs.makeAudioTranscoder(input: AudioFormat(codec: .pcma, sampleRate: 8_000, channels: 1), output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000)) }
        // A rate and layout no other test uses: silence is cached per rate and layout, so a cached one is served without ffmpeg.
        #expect(throws: MediaCodecError.self) { _ = try codecs.silentAACFrames(duration: .seconds(1), sampleRate: 12_000, channels: 1, startPTS: MediaTime(value: 0, timescale: 12_000), wallClock: Date()) }
    }

    @Test func theTimestampOverlayIsADrawtextFilterAndRestartsWhenItsLayoutChanges() async throws {
        let rig = rig()
        let overlay = MutableOverlay(TimestampOverlay(settings: TimestampOverlaySettings(enabled: true, position: .topRight, showCameraName: true, showDate: true, showSeconds: true, use24Hour: true),
                                                      cameraName: "Front Door", clock: FixedOverlayClock(Date(timeIntervalSince1970: 1_800_000_000))))
        let transcoder = try FFmpegVideoTranscoder(runtime: rig.codecs.runtime, output: settings(), overlay: overlay, minimumRunTime: .zero)
        defer { transcoder.invalidate() }
        _ = try await transcoder.transcode(TestFormats.frame(0, key: true))
        let first = try #require(rig.transcoderChildren.first)
        let filter = try #require(first.arguments.firstIndex(of: "-vf").map { first.arguments[$0 + 1] })
        #expect(filter.contains("drawtext=fontfile=\(TestFonts.path):textfile="))
        let textFile = try #require(filter.components(separatedBy: "textfile=").last?.components(separatedBy: ":").first)
        let text = try String(contentsOfFile: textFile, encoding: .utf8)
        #expect(text.hasPrefix("Front Door  |  "))
        // Same layout, new words: the file changes, the child stays.
        overlay.set(TimestampOverlay(settings: overlay.snapshot().settings, cameraName: "Garage", clock: FixedOverlayClock(Date(timeIntervalSince1970: 1_800_000_100))))
        _ = try await transcoder.transcode(TestFormats.frame(1, key: false))
        #expect(rig.transcoderChildren.count == 1)
        #expect(try String(contentsOfFile: textFile, encoding: .utf8).hasPrefix("Garage  |  "))
        // A new position restarts the child with the GOP replayed.
        var moved = overlay.snapshot().settings
        moved.position = .bottomLeft
        overlay.set(TimestampOverlay(settings: moved, cameraName: "Garage", clock: overlay.snapshot().clock))
        _ = try await transcoder.transcode(TestFormats.frame(2, key: false))
        #expect(rig.transcoderChildren.count == 2)
        let secondFilter = try #require(rig.transcoderChildren[1].arguments.firstIndex(of: "-vf").map { rig.transcoderChildren[1].arguments[$0 + 1] })
        #expect(secondFilter.contains("y=h-th-"))
        // Turning it off restarts once more, without drawtext.
        var off = moved
        off.enabled = false
        overlay.set(TimestampOverlay(settings: off, cameraName: "Garage"))
        _ = try await transcoder.transcode(TestFormats.frame(3, key: false))
        #expect(rig.transcoderChildren.count == 3)
        #expect(rig.transcoderChildren[2].arguments.allSatisfy { !$0.contains("drawtext") })
        transcoder.invalidate()
        #expect(!FileManager.default.fileExists(atPath: textFile))
    }

    @Test func withoutAFontTheOverlayIsLeftOutAndTheStreamStillRuns() async throws {
        let rig = rig(configuration: FFmpegCodecsConfiguration(fontFile: "/nonexistent/font.ttf"))
        let overlay = MutableOverlay(TimestampOverlay(settings: TimestampOverlaySettings(enabled: true), cameraName: "x"))
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings(), overlay: overlay)
        defer { transcoder.invalidate() }
        let out = try await transcoder.transcode(TestFormats.frame(0, key: true))
        #expect(out.count == 1)
        #expect(rig.transcoderChildren[0].arguments.allSatisfy { !$0.contains("drawtext") })
    }

    @Test func anOverlayWithoutAScratchDirectoryIsLeftOutWithoutRestartingTheChild() async throws {
        // The scratch "directory" is a file, so the overlay's text file cannot be made.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("camera-bridge-test-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let rig = rig(configuration: FFmpegCodecsConfiguration(fontFile: TestFonts.path, scratchDirectory: blocker))
        let overlay = MutableOverlay(TimestampOverlay(settings: TimestampOverlaySettings(enabled: true), cameraName: "x"))
        let transcoder = try FFmpegVideoTranscoder(runtime: rig.codecs.runtime, output: settings(), overlay: overlay, minimumRunTime: .zero)
        defer { transcoder.invalidate() }
        for index in 0..<6 { _ = try await transcoder.transcode(TestFormats.frame(index, key: index == 0)) }
        #expect(rig.transcoderChildren.count == 1)
        #expect(rig.transcoderChildren[0].arguments.allSatisfy { !$0.contains("drawtext") })
    }

    @Test func aRunningTranscoderRestartsOnceWhenTheCorrectionChanges() async throws {
        let rig = rig()
        let correction = MutableCorrection(nil)
        let transcoder = try FFmpegVideoTranscoder(runtime: rig.codecs.runtime, output: settings(), overlay: nil, correction: correction, minimumRunTime: .zero)
        defer { transcoder.invalidate() }
        var out: [EncodedVideoFrame] = []
        for index in 0..<4 { out += try await transcoder.transcode(TestFormats.frame(index, key: index == 0)) }
        #expect(rig.transcoderChildren.count == 1)
        #expect(rig.transcoderChildren[0].arguments.allSatisfy { !$0.contains("remap") })
        // Turned on between two GOPs: the next keyframe starts one new child that warps.
        correction.set(PictureCorrection(straighten: 0.4, level: 0.15))
        for index in 4..<8 { out += try await transcoder.transcode(TestFormats.frame(index, key: index == 4)) }
        #expect(rig.transcoderChildren.count == 2)
        #expect(rig.transcoderChildren[0].terminated)
        let second = rig.transcoderChildren[1].arguments
        let graph = try #require(second.firstIndex(of: "-filter_complex").map { second[$0 + 1] })
        #expect(graph.contains("remap") && second.contains("[cbv]"))
        // The maps it reads exist: luma x and y twice as tall as the output, chroma x and y half as wide (the 4:2:0 planes).
        let inputs = second.indices.filter { second[$0] == "-i" }.map { second[$0 + 1] }
        #expect(inputs.count == 5 && inputs[0] == "pipe:0")
        for (map, header) in zip(inputs.dropFirst(), ["P5\n320 360\n65535\n", "P5\n320 360\n65535\n", "P5\n160 180\n65535\n", "P5\n160 180\n65535\n"]) {
            let data = try Data(contentsOf: URL(fileURLWithPath: map))
            #expect(data.starts(with: Data(header.utf8)), "\(map)")
        }
        // The same value again changes nothing.
        correction.set(PictureCorrection(straighten: 0.4, level: 0.15))
        for index in 8..<12 { out += try await transcoder.transcode(TestFormats.frame(index, key: index == 8)) }
        #expect(rig.transcoderChildren.count == 2)
        // No picture was lost over the restart.
        #expect(out.count == 12, "\(out.count) pictures")
        transcoder.invalidate()
        #expect(inputs.dropFirst().allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    @Test func turningTheCorrectionOffRestartsOnceWithoutTheWarp() async throws {
        let rig = rig()
        let correction = MutableCorrection(PictureCorrection(straighten: 0.4, level: 0.15))
        let transcoder = try FFmpegVideoTranscoder(runtime: rig.codecs.runtime, output: settings(), overlay: nil, correction: correction, minimumRunTime: .zero)
        defer { transcoder.invalidate() }
        var out: [EncodedVideoFrame] = []
        for index in 0..<4 { out += try await transcoder.transcode(TestFormats.frame(index, key: index == 0)) }
        #expect(rig.transcoderChildren.count == 1 && rig.transcoderChildren[0].arguments.contains { $0.contains("remap") })
        // Both sliders back at 0: the next keyframe starts one child that only transcodes.
        correction.set(.off)
        for index in 4..<8 { out += try await transcoder.transcode(TestFormats.frame(index, key: index == 4)) }
        #expect(rig.transcoderChildren.count == 2 && rig.transcoderChildren[0].terminated)
        let second = rig.transcoderChildren[1].arguments
        #expect(second.allSatisfy { !$0.contains("remap") && $0 != "-filter_complex" } && second.contains("-vf"))
        #expect(second.filter { $0 == "-i" }.count == 1)
        // nil is off as well: no further restart.
        correction.set(nil)
        for index in 8..<12 { out += try await transcoder.transcode(TestFormats.frame(index, key: index == 8)) }
        #expect(rig.transcoderChildren.count == 2)
        #expect(out.count == 12, "\(out.count) pictures")
    }

    @Test func aBitrateRestartWhileCorrectedReusesTheMaps() async throws {
        let rig = rig()
        let correction = StaticPictureCorrection(PictureCorrection(straighten: 0.4, level: 0.15))
        let transcoder = try FFmpegVideoTranscoder(runtime: rig.codecs.runtime, output: settings(bitrate: 1_000), overlay: nil, correction: correction, minimumRunTime: .zero)
        defer { transcoder.invalidate() }
        for index in 0..<4 { _ = try await transcoder.transcode(TestFormats.frame(index, key: index == 0)) }
        let first = rig.transcoderChildren[0].arguments
        let maps = first.indices.filter { first[$0] == "-i" }.map { first[$0 + 1] }.dropFirst()
        #expect(maps.count == 4)
        let before = try maps.map(FileIdentity.init(path:))
        transcoder.updateBitrate(kbps: 600)
        _ = try await transcoder.transcode(TestFormats.frame(4, key: false))
        #expect(rig.transcoderChildren.count == 2)
        let second = rig.transcoderChildren[1].arguments
        #expect(second.contains("600k") && Array(second.indices.filter { second[$0] == "-i" }.map { second[$0 + 1] }.dropFirst()) == Array(maps))
        // Not one of the four files was written again (each write replaces the file, so it would be a new file).
        #expect(try maps.map(FileIdentity.init(path:)) == before)
    }

    @Test func withoutTheWarpFiltersTheCorrectionIsUnavailable() async throws {
        let warnings = WarningLines()
        let token = LogHub.addSink(warnings)
        defer { LogHub.removeSink(token) }
        let launcher = FakeFFmpegLauncher()
        let script = ScriptedVideoFFmpeg()
        let codecs = FFmpegMediaCodecs.fake(launcher, filters: FakeListings.filtersWithoutTheWarp)
        let probe = launcher.onLaunch
        launcher.onLaunch = { child in
            probe?(child)
            script.attach(to: child)
        }
        #expect(!codecs.supportsPictureCorrection)
        let transcoder = try codecs.makeVideoTranscoder(output: settings(), overlay: nil, correction: StaticPictureCorrection(PictureCorrection(straighten: 0.4, level: 0.15)))
        defer { transcoder.invalidate() }
        var out: [EncodedVideoFrame] = []
        for index in 0..<8 { out += try await transcoder.transcode(TestFormats.frame(index, key: index % 4 == 0)) }
        #expect(out.count == 8)
        let children = launcher.children.filter { $0.spec.label == "video transcoder" }
        #expect(children.count == 1 && children[0].arguments.allSatisfy { !$0.contains("remap") && $0 != "-filter_complex" })
        #expect(warnings.matching("straighten").count == 1, "\(warnings.matching("straighten"))")
        #expect(try codecs.capabilitySummary().contains("picture correction unavailable"))
        #expect(try rig().codecs.capabilitySummary().contains("picture correction available"))
    }

    @Test func withoutAScratchDirectoryTheTranscoderRunsUncorrected() async throws {
        // The scratch "directory" is a file, so the maps cannot be written.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("camera-bridge-test-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let warnings = WarningLines()
        let token = LogHub.addSink(warnings)
        defer { LogHub.removeSink(token) }
        let rig = rig(configuration: FFmpegCodecsConfiguration(fontFile: TestFonts.path, scratchDirectory: blocker))
        let correction = StaticPictureCorrection(PictureCorrection(straighten: 0.4, level: 0.15))
        let transcoder = try FFmpegVideoTranscoder(runtime: rig.codecs.runtime, output: settings(), overlay: nil, correction: correction, minimumRunTime: .zero)
        defer { transcoder.invalidate() }
        var out: [EncodedVideoFrame] = []
        for index in 0..<12 { out += try await transcoder.transcode(TestFormats.frame(index, key: index % 4 == 0)) }
        #expect(out.count == 12)
        #expect(rig.transcoderChildren.count == 1)
        #expect(rig.transcoderChildren[0].arguments.allSatisfy { !$0.contains("remap") && $0 != "-filter_complex" })
        #expect(warnings.matching("straighten").count == 1, "\(warnings.matching("straighten"))")
    }

    @Test func theThreeArgumentTranscoderWarpsAndTheCodecsSayTheyCan() async throws {
        let rig = rig()
        #expect(rig.codecs.supportsPictureCorrection)
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings(), overlay: nil, correction: StaticPictureCorrection(PictureCorrection(straighten: -0.2)))
        defer { transcoder.invalidate() }
        #expect(try await transcoder.transcode(TestFormats.frame(0, key: true)).count == 1)
        #expect(rig.transcoderChildren.count == 1 && rig.transcoderChildren[0].arguments.contains { $0.contains("remap") })
        // Off is no correction at all.
        let plain = try rig.codecs.makeVideoTranscoder(output: settings(), overlay: nil, correction: StaticPictureCorrection(.off))
        defer { plain.invalidate() }
        _ = try await plain.transcode(TestFormats.frame(0, key: true))
        #expect(rig.transcoderChildren.count == 2 && rig.transcoderChildren[1].arguments.allSatisfy { !$0.contains("remap") })
    }

    @Test func aVAAPIPipelineThatDiesAtStartFallsBackToSoftware() async throws {
        let launcher = FakeFFmpegLauncher()
        let script = ScriptedVideoFFmpeg()
        let codecs = FFmpegMediaCodecs.fake(launcher, configuration: FFmpegCodecsConfiguration(fontFile: TestFonts.path), deviceExists: { _ in true })
        let probe = launcher.onLaunch
        launcher.onLaunch = { child in
            probe?(child)
            if child.arguments.contains("-t"), child.arguments.contains("h264_vaapi") {
                child.exit(status: 0)   // the probe encode works
            } else if child.spec.label == "video transcoder", child.arguments.contains("h264_vaapi") {
                child.exit(status: 1, stderr: ["Failed to initialise VAAPI connection: -1 (unknown libva error)."])
            } else {
                script.attach(to: child)
            }
        }
        let transcoder = try codecs.makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        #expect(transcoder.diagnostics.encoderIsHardware == true)
        let error = await #expect(throws: MediaCodecError.self) { _ = try await transcoder.transcode(TestFormats.frame(0, key: true)) }
        #expect("\(try #require(error))".contains("libva"))
        // The next keyframe starts a software child.
        let out = try await transcoder.transcode(TestFormats.frame(1, key: true))
        #expect(out.count == 1)
        let children = launcher.children.filter { $0.spec.label == "video transcoder" }
        #expect(children.count == 2 && children[1].arguments.contains("libx264"))
        #expect(transcoder.diagnostics.encoderIsHardware == false)
    }

    @Test func vaapiIsProbedWithTheLowPowerEncoderWhenTheDefaultOneFails() async throws {
        // Alder Lake-N and newer offer H.264 encoding only through the fixed-function (low power) entrypoint.
        let launcher = FakeFFmpegLauncher()
        let script = ScriptedVideoFFmpeg()
        let codecs = FFmpegMediaCodecs.fake(launcher, configuration: FFmpegCodecsConfiguration(fontFile: TestFonts.path), deviceExists: { _ in true })
        let probe = launcher.onLaunch
        launcher.onLaunch = { child in
            probe?(child)
            if child.arguments.contains("-t"), child.arguments.contains("h264_vaapi") {
                if child.arguments.contains("-low_power") {
                    child.exit(status: 0)
                } else {
                    child.exit(status: 234, stderr: ["No usable encoding entrypoint found for profile VAProfileH264High (7)."])
                }
            } else {
                script.attach(to: child)
            }
        }
        let transcoder = try codecs.makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        _ = try await transcoder.transcode(TestFormats.frame(0, key: true))
        let probes = launcher.children.filter { $0.arguments.contains("-t") && $0.arguments.contains("h264_vaapi") }
        #expect(probes.count == 2 && !probes[0].arguments.contains("-low_power") && probes[1].arguments.contains("-low_power"))
        let child = try #require(launcher.children.first { $0.spec.label == "video transcoder" })
        #expect(child.arguments.contains("h264_vaapi") && child.arguments.contains("-low_power"))
        #expect(try codecs.capabilitySummary().contains("h264_vaapi (/dev/dri/renderD128, low power)"))
    }

    @Test func noRenderNodeMeansNoProbeAndSoftware() async throws {
        let rig = rig()   // the fake says no device exists
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        #expect(rig.launcher.children.allSatisfy { !$0.arguments.contains("h264_vaapi") || $0.arguments.contains("-encoders") })
        #expect(transcoder.diagnostics.encoderIsHardware == false)
        #expect(try rig.codecs.capabilitySummary().contains("libx264"))
    }

    @Test func forcingSoftwareSkipsTheProbe() async throws {
        let launcher = FakeFFmpegLauncher()
        let codecs = FFmpegMediaCodecs.fake(launcher, configuration: FFmpegCodecsConfiguration(videoEncoder: .software, fontFile: TestFonts.path), deviceExists: { _ in true })
        try codecs.prepare()
        #expect(launcher.children.allSatisfy { !($0.arguments.contains("-t") && $0.arguments.contains("h264_vaapi")) })
        #expect(try codecs.capabilitySummary().contains("libx264"))
    }

    @Test func theKeyframeSizeIsReportedInTheDiagnostics() async throws {
        let rig = rig()
        let transcoder = try rig.codecs.makeVideoTranscoder(output: settings())
        defer { transcoder.invalidate() }
        _ = try await transcoder.transcode(TestFormats.frame(0, key: true))
        let diagnostics = transcoder.diagnostics
        #expect(diagnostics.lastKeyframeBytes != nil && diagnostics.lastKeyframeWidth != nil)
        #expect(diagnostics.encoderIsHardware == false && diagnostics.decoderIsHardware == false)
        #expect(diagnostics.codecDescription == "decoder software, encoder software")
    }
}

/// An overlay the test changes while a transcoder runs.
final class MutableOverlay: TimestampOverlayProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var overlay: TimestampOverlay

    init(_ overlay: TimestampOverlay) { self.overlay = overlay }

    func set(_ overlay: TimestampOverlay) {
        lock.lock()
        self.overlay = overlay
        lock.unlock()
    }

    func snapshot() -> TimestampOverlay {
        lock.lock()
        defer { lock.unlock() }
        return overlay
    }

    var current: TimestampOverlay? { snapshot() }
}

/// A correction the test changes while a transcoder runs.
final class MutableCorrection: PictureCorrectionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var correction: PictureCorrection?

    init(_ correction: PictureCorrection?) { self.correction = correction }

    func set(_ correction: PictureCorrection?) {
        lock.lock()
        self.correction = correction
        lock.unlock()
    }

    var current: PictureCorrection? {
        lock.lock()
        defer { lock.unlock() }
        return correction
    }
}

/// A file's identity: a map written again is a new file (written to a temporary name, then renamed over the old one).
struct FileIdentity: Equatable {
    var number: Int
    var modified: Date

    init(path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        number = (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? -1
        modified = attributes[.modificationDate] as? Date ?? .distantPast
    }
}

/// The scratch directory of the correction's maps on its own.
@Suite struct RemapScratchTests {
    private let a = PictureCorrection(straighten: 0.4, level: 0.15)
    private let b = PictureCorrection(straighten: -0.2, level: 0.05)

    private func identities(_ stage: RemapStage) throws -> [FileIdentity] {
        try [stage.xMap, stage.yMap, stage.chromaXMap, stage.chromaYMap].map(FileIdentity.init(path:))
    }

    @Test func theFourMapsAreWrittenOnceAndOnlyWhatChangedIsWrittenAgain() throws {
        // RemapScratch makes its parent directory.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("camera-bridge-test-remap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var scratch: RemapScratch? = try RemapScratch(parent: base)
        let directory = try #require(scratch?.directory)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        let stage = try #require(try scratch?.stage(for: a, width: 64, height: 32))
        #expect(stage.width == 64 && stage.height == 32)
        #expect(Set([stage.xMap, stage.yMap, stage.chromaXMap, stage.chromaYMap]).count == 4)
        let maps = a.remapMaps(width: 64, height: 32)
        #expect(try [stage.xMap, stage.yMap, stage.chromaXMap, stage.chromaYMap].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
            == [maps.x, maps.y, maps.chromaX, maps.chromaY])
        let first = try identities(stage)
        // The same correction and size: nothing is written.
        #expect(try scratch?.stage(for: a, width: 64, height: 32) == stage)
        #expect(try identities(stage) == first)
        // Another correction: the y maps only (the x maps depend on the size alone).
        _ = try scratch?.stage(for: b, width: 64, height: 32)
        let second = try identities(stage)
        #expect(second[0] == first[0] && second[2] == first[2])
        #expect(second[1] != first[1] && second[3] != first[3])
        #expect(try Data(contentsOf: URL(fileURLWithPath: stage.chromaYMap)) == b.remapMaps(width: 64, height: 32).chromaY)
        // A file removed behind its back (a temporary-files cleaner) is written again.
        try FileManager.default.removeItem(atPath: stage.yMap)
        _ = try scratch?.stage(for: b, width: 64, height: 32)
        #expect(FileManager.default.fileExists(atPath: stage.yMap))
        #expect(try Data(contentsOf: URL(fileURLWithPath: stage.yMap)) == b.remapMaps(width: 64, height: 32).y)
        #expect(try identities(stage)[0] == second[0])
        // So is the whole directory.
        try FileManager.default.removeItem(at: directory)
        _ = try scratch?.stage(for: b, width: 64, height: 32)
        #expect(try identities(stage).count == 4)
        // A new size: all four.
        let before = try identities(stage)
        let larger = try #require(try scratch?.stage(for: b, width: 128, height: 64))
        #expect(zip(try identities(larger), before).allSatisfy { $0 != $1 })
        #expect(try Data(contentsOf: URL(fileURLWithPath: larger.chromaXMap)).starts(with: Data("P5\n64 64\n65535\n".utf8)))
        // Released: the directory goes with it.
        scratch = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func aFailedRenameSaysWhy() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("camera-bridge-test-remap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let scratch = try RemapScratch(parent: base)
        // A directory (not empty) where the y map goes: rename(2) refuses with EISDIR.
        try FileManager.default.createDirectory(atPath: scratch.yMap.path + "/inside", withIntermediateDirectories: true)
        let error = #expect(throws: (any Error).self) { _ = try scratch.stage(for: a, width: 16, height: 8) }
        let message = (error as? LocalizedError)?.errorDescription ?? "\(String(describing: error))"
        #expect(message.contains("y.pgm") && message.contains("Is a directory"), "\(message)")
        #expect(!FileManager.default.fileExists(atPath: scratch.directory.appendingPathComponent("y.tmp").path))
    }
}

/// The maps of the snapshots' straightening, kept between snapshots for each picture size and correction.
@Suite struct SnapshotMapCacheTests {
    private let a = PictureCorrection(straighten: 0.4, level: 0.15)
    private let b = PictureCorrection(straighten: -0.2, level: 0.05)
    private let c = PictureCorrection(straighten: 0.1)

    private func scratchParent() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("camera-bridge-test-snapshot-maps-\(UUID().uuidString)", isDirectory: true)
    }

    private func sets(in parent: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).filter { $0.hasPrefix("camera-bridge-remap-") }
    }

    private func identities(_ stage: RemapStage) throws -> [FileIdentity] {
        try [stage.xMap, stage.yMap, stage.chromaXMap, stage.chromaYMap].map(FileIdentity.init(path:))
    }

    @Test func aSizeAndCorrectionKeepTheirMapsFromOneSnapshotToTheNext() throws {
        let parent = scratchParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let cache = SnapshotMapCache(parent: parent, capacity: 6)
        let first = try cache.withMaps(for: a, width: 64, height: 32) { stage in (stage, try identities(stage)) }
        let maps = a.remapMaps(width: 64, height: 32)
        #expect(try [first.0.xMap, first.0.yMap, first.0.chromaXMap, first.0.chromaYMap].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
            == [maps.x, maps.y, maps.chromaX, maps.chromaY])
        for _ in 0..<3 {
            let again = try cache.withMaps(for: a, width: 64, height: 32) { stage in (stage, try identities(stage)) }
            #expect(again.0 == first.0 && again.1 == first.1, "the same files, not written again")
        }
        #expect(cache.count == 1 && sets(in: parent).count == 1)
        // Another correction and another size each have their own set (the cameras take turns, no set is rewritten for the next).
        let other = try cache.withMaps(for: b, width: 64, height: 32) { stage in (stage, try identities(stage)) }
        let larger = try cache.withMaps(for: a, width: 128, height: 64) { $0 }
        #expect(other.0.xMap != first.0.xMap && larger.xMap != first.0.xMap)
        #expect(cache.count == 3 && sets(in: parent).count == 3)
        #expect(try cache.withMaps(for: a, width: 64, height: 32) { try identities($0) } == first.1, "and the first is still as it was")
    }

    @Test func theLeastRecentlyUsedSetIsRemovedPastTheCapacity() throws {
        let parent = scratchParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let cache = SnapshotMapCache(parent: parent, capacity: 2)
        let first = try cache.withMaps(for: a, width: 64, height: 32) { $0 }
        let second = try cache.withMaps(for: b, width: 64, height: 32) { $0 }
        _ = try cache.withMaps(for: a, width: 64, height: 32) { $0 }      // a is the newest now
        let third = try cache.withMaps(for: c, width: 64, height: 32) { $0 }   // pushes b out
        #expect(cache.count == 2 && sets(in: parent).count == 2)
        #expect(FileManager.default.fileExists(atPath: first.yMap) && FileManager.default.fileExists(atPath: third.yMap))
        #expect(!FileManager.default.fileExists(atPath: second.yMap), "the evicted set's files are removed")
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: second.yMap).deletingLastPathComponent().path))
    }

    @Test func aSetInUseOutlivesItsEvictionUntilItsSnapshotEnds() throws {
        let parent = scratchParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let cache = SnapshotMapCache(parent: parent, capacity: 1)
        var running: RemapStage?
        try cache.withMaps(for: a, width: 64, height: 32) { stage in
            running = stage
            // Another camera's snapshot pushes this set out while its ffmpeg child is still starting up: the files stay until it is done.
            _ = try cache.withMaps(for: b, width: 64, height: 32) { _ in }
            #expect(FileManager.default.fileExists(atPath: stage.yMap) && FileManager.default.fileExists(atPath: stage.xMap))
        }
        let stage = try #require(running)
        #expect(!FileManager.default.fileExists(atPath: stage.yMap), "removed once nobody uses it")
        #expect(cache.count == 1 && sets(in: parent).count == 1)
    }

    @Test func aFailureToWriteMapsLeavesNoSetBehindAndTheNextSnapshotTriesAgain() throws {
        let parent = scratchParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let cache = SnapshotMapCache(parent: parent, capacity: 2)
        let made = try cache.withMaps(for: a, width: 64, height: 32) { $0 }
        // The set's directory is gone and a file stands in its place (a full disk, a cleaner that went wrong): the maps cannot be written.
        let directory = URL(fileURLWithPath: made.yMap).deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        FileManager.default.createFile(atPath: directory.path, contents: Data())
        #expect(throws: (any Error).self) { try cache.withMaps(for: a, width: 64, height: 32) { _ in } }
        #expect(cache.count == 0 && sets(in: parent).isEmpty, "the broken set is dropped")
        let fresh = try cache.withMaps(for: a, width: 64, height: 32) { $0 }
        #expect(FileManager.default.fileExists(atPath: fresh.yMap) && cache.count == 1)
    }

    @Test func snapshotsAtTheSameTimeWriteASetOnce() async throws {
        let parent = scratchParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let cache = SnapshotMapCache(parent: parent, capacity: 2)
        let stages = try await withThrowingTaskGroup(of: RemapStage.self) { group in
            for _ in 0..<6 { group.addTask { try cache.withMaps(for: self.a, width: 256, height: 128) { $0 } } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(stages.map(\.yMap)).count == 1 && cache.count == 1 && sets(in: parent).count == 1)
    }

    @Test func releasingTheCacheRemovesEveryMap() throws {
        let parent = scratchParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        var cache: SnapshotMapCache? = SnapshotMapCache(parent: parent, capacity: 4)
        _ = try cache?.withMaps(for: a, width: 64, height: 32) { $0 }
        _ = try cache?.withMaps(for: b, width: 64, height: 32) { $0 }
        #expect(sets(in: parent).count == 2)
        cache = nil
        #expect(sets(in: parent).isEmpty)
    }
}

/// The warnings logged while it is registered.
final class WarningLines: LogSink {
    private let lines = Mutex<[String]>([])
    func record(_ entry: LogEntry) {
        guard entry.level == .warning else { return }
        lines.withLock { $0.append(entry.message) }
    }
    func matching(_ text: String) -> [String] { lines.withLock { $0.filter { $0.contains(text) } } }
}
