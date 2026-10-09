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
        guard let index = arguments.firstIndex(of: "-vf"), index + 1 < arguments.count else { return nil }
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
