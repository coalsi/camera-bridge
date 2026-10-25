import BridgeSupport
import Foundation
import MediaCore
import Synchronization
import Testing
@testable import PlatformLinux

/// Plays the part of ffmpeg for the sky detector's decoder: reads nothing, counts the frames written to its stdin and answers with
/// Y4M, one picture for every `keepEvery`th frame (frames 0, 4, 8, … as `select='not(mod(n\,4))'` keeps them), each `delay` frames
/// after the frame it shows (a decoder that holds pictures back).
final class ScriptedSkyFFmpeg: @unchecked Sendable {
    let width: Int
    let height: Int
    let keepEvery: Int
    let delay: Int

    init(width: Int, height: Int, keepEvery: Int, delay: Int = 0) {
        self.width = width
        self.height = height
        self.keepEvery = keepEvery
        self.delay = delay
    }

    private final class ChildState: @unchecked Sendable {
        var written = 0
        var sentHeader = false
    }

    func attach(to child: FakeFFmpegLauncher.Child) {
        guard child.spec.label == "video decoder" else { return }
        let state = ChildState()
        child.onWrite = { [self] child, data in
            if data.starts(with: Array("FLV".utf8)) { return }   // the file header and the sequence header
            let index = state.written
            state.written += 1
            let shown = index - delay
            guard shown >= 0, shown % keepEvery == 0 else { return }
            var out = Data()
            if !state.sentHeader {
                state.sentHeader = true
                out.append(Data("YUV4MPEG2 W\(width) H\(height) F25:1 Ip A1:1 C420jpeg\n".utf8))
            }
            out.append(Data("FRAME\n".utf8))
            out.append(Data(repeating: UInt8(truncatingIfNeeded: shown), count: RawVideoFrame.byteCount(width: width, height: height)))
            child.emit(out)
        }
    }
}

/// A clock a test moves (the failure of a GPU session is remembered for a while).
private final class TestClock: @unchecked Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// How the GPU's decoder sessions end just now (nil: they work), changed by a test.
private final class GPUWeather: @unchecked Sendable {
    private let death = Mutex<GPUDeath?>(nil)
    var current: GPUDeath? { death.withLock { $0 } }
    func set(_ value: GPUDeath?) { death.withLock { $0 = value } }
}

/// Counts the writes a fake child gets.
private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

/// How a GPU session ends before it shows a picture.
enum GPUDeath: CaseIterable, Sendable {
    /// Gone when it is launched (the driver cannot be opened).
    case atLaunch
    /// Gone when the stream's header reaches it (the size is refused).
    case atTheHeader
    /// Gone after the first frame, with no picture.
    case afterTheFirstFrame
}

/// The sky detector's decoder (`MediaCodecs.makeSkyDecoder`): pictures at most `maxOutputWidth` wide, one in `keepEvery` of them made (the
/// others dropped on the GPU, before they are copied back, where the GPU decodes), the child at low priority. What the arguments say and how
/// the pictures are paired with their times are tested with a fake ffmpeg (no GPU is reachable from the Mac or its containers); the quoting of
/// the select filter and the whole path against a real ffmpeg, where there is one.
@Suite(.serialized) struct SkyDecoderTests {
    private func chain(_ arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: "-vf"), arguments.indices.contains(index + 1) else { return "" }
        return arguments[index + 1]
    }

    private func offset(of needle: String, in text: String) -> Int? {
        text.range(of: needle).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
    }

    private struct Rig {
        let launcher: FakeFFmpegLauncher
        let codecs: FFmpegMediaCodecs
        var decoderChildren: [FakeFFmpegLauncher.Child] { launcher.children.filter { $0.spec.label == "video decoder" } }
    }

    private static let renderNode = "/dev/dri/renderD128"
    private static let refusal = "Hardware does not support image size 3840x2160 (constraints: width 0-1920 height 0-1080)"

    /// Codecs over a fake ffmpeg that answers the decoders with `ScriptedSkyFFmpeg` pictures of `width` × `height`. With `vaapi` a render
    /// node exists and the probe encode works, so the GPU is usable; `gpuDies` ends every GPU decoder session as described.
    private func rig(width: Int, height: Int, keepEvery: Int, delay: Int = 0, vaapi: Bool = false, gpuDies: GPUDeath? = nil,
                     weather: GPUWeather? = nil, now: @escaping @Sendable () -> Date = { Date() }) -> Rig {
        let launcher = FakeFFmpegLauncher()
        let script = ScriptedSkyFFmpeg(width: width, height: height, keepEvery: keepEvery, delay: delay)
        let codecs = FFmpegMediaCodecs.fake(launcher, deviceExists: { _ in vaapi }, now: now)
        let probe = launcher.onLaunch
        let refusal = Self.refusal
        launcher.onLaunch = { child in
            probe?(child)
            if child.arguments.contains("-t"), child.arguments.contains("h264_vaapi") {
                child.exit(status: 0)   // the probe encode works
                return
            }
            guard child.spec.label == "video decoder" else { return }
            if child.arguments.contains("-hwaccel"), let death = weather?.current ?? gpuDies {
                switch death {
                case .atLaunch:
                    child.exit(status: 1, stderr: [refusal])
                case .atTheHeader:
                    child.onWrite = { child, _ in child.exit(status: 1, stderr: [refusal]) }
                case .afterTheFirstFrame:
                    let writes = WriteCounter()
                    child.onWrite = { child, _ in
                        if writes.next() == 2 { child.exit(status: 1, stderr: [refusal]) }
                    }
                }
                return
            }
            script.attach(to: child)
        }
        return Rig(launcher: launcher, codecs: codecs)
    }

    private func format(_ codec: VideoCodec = .h264, _ width: Int, _ height: Int) -> VideoFormat {
        var format = TestFormats.h264
        format.codec = codec
        format.width = width
        format.height = height
        return format
    }

    // MARK: Arguments

    @Test func skyDecoderArgumentsKeepEveryNth() throws {
        let gpu = chain(FFmpegArguments.decoder(width: 1920, height: 852, hardwareDevice: Self.renderNode, keepEvery: 4))
        let scale = try #require(offset(of: "scale_vaapi=w=1920:h=852", in: gpu))
        let select = try #require(offset(of: "select='not(mod(n\\,4))'", in: gpu))
        let download = try #require(offset(of: "hwdownload", in: gpu))
        #expect(scale < select && select < download, "scaled on the GPU, dropped there, then copied back: \(gpu)")

        // Every picture: no select filter at all, and that is the default.
        let every = FFmpegArguments.decoder(width: 1920, height: 852, hardwareDevice: Self.renderNode, keepEvery: 1)
        #expect(!chain(every).contains("select"))
        #expect(every == FFmpegArguments.decoder(width: 1920, height: 852, hardwareDevice: Self.renderNode))
        #expect(!chain(FFmpegArguments.decoder(width: 1920, height: 852, hardwareDevice: Self.renderNode, keepEvery: 0)).contains("select"))

        // On the CPU a dropped picture is dropped before it is scaled.
        let cpu = chain(FFmpegArguments.decoder(width: 1920, height: 852, keepEvery: 4))
        let cpuSelect = try #require(offset(of: "select='not(mod(n\\,4))'", in: cpu))
        let cpuScale = try #require(offset(of: "scale=1920:852", in: cpu))
        #expect(cpuSelect < cpuScale, "\(cpu)")
        #expect(!chain(FFmpegArguments.decoder(width: 1920, height: 852, keepEvery: 1)).contains("select"))

        // The output side does not change.
        let arguments = FFmpegArguments.decoder(width: 1920, height: 852, hardwareDevice: Self.renderNode, keepEvery: 4)
        #expect(arguments.suffix(5) == ["-f", "yuv4mpegpipe", "-pix_fmt", "yuv420p", "pipe:1"] && arguments.contains("passthrough"))
    }

    @Test func theSkyScalesWithAGoodFilter() {
        // Single-pixel speckle looks different under every filter: an area average on the CPU, the GPU's high-quality scaler on the GPU.
        let gpu = chain(FFmpegArguments.decoder(width: 1920, height: 852, hardwareDevice: Self.renderNode, keepEvery: 4, highQualityScaling: true))
        #expect(gpu.hasPrefix("scale_vaapi=w=1920:h=852:format=nv12:mode=hq,select="), "\(gpu)")
        let cpu = chain(FFmpegArguments.decoder(width: 1920, height: 852, keepEvery: 4, highQualityScaling: true))
        #expect(cpu.contains("scale=1920:852:flags=area"), "\(cpu)")
        // Motion detection and the others scale as they did.
        #expect(chain(FFmpegArguments.decoder(width: 1920, height: 1080)) == "scale=1920:1080,format=yuv420p")
        #expect(chain(FFmpegArguments.decoder(width: 1920, height: 1080, hardwareDevice: Self.renderNode))
            == "scale_vaapi=w=1920:h=1080:format=nv12,hwdownload,format=nv12,format=yuv420p")
    }

    // MARK: Pictures and their times

    @Test func keptPicturesPairWithEveryNthPTS() async throws {
        let format = TestFormats.h264
        let output = FFmpegVideoDecoder.outputSize(width: format.width, height: format.height, maxWidth: 160)
        let rig = rig(width: output.width, height: output.height, keepEvery: 4)
        let decoder = try rig.codecs.makeSkyDecoder(format: format, maxOutputWidth: 160, keepEvery: 4)
        defer { decoder.invalidate() }
        let begun = ContinuousClock.now
        var kept: [MediaTime] = []
        for index in 0..<12 {
            let frame = TestFormats.frame(index, key: index == 0)
            let picture = try await decoder.decode(frame)
            if index % 4 == 0 {
                let raw = try #require(picture as? RawVideoFrame, "frame \(index) is kept")
                #expect(raw.pts == frame.pts && raw.width == output.width && raw.height == output.height, "frame \(index)")
                kept.append(raw.pts)
            } else {
                #expect(picture == nil, "frame \(index) is dropped")
            }
        }
        #expect(kept == [0, 4, 8].map { TestFormats.frame($0, key: false).pts })
        #expect(ContinuousClock.now - begun < .milliseconds(200), "a dropped picture is not waited for (0.4 s each)")
        let args = try #require(rig.decoderChildren.first).arguments
        #expect(chain(args).contains("select='not(mod(n\\,4))'") && chain(args).contains("scale=\(output.width):\(output.height)"))
    }

    @Test func aPictureThatComesOutLateStillCarriesTheTimeOfItsFrame() async throws {
        // A stream with reordering (frames carry a decode time before their presentation time): the picture of frame 0 comes out
        // when frame 2 has gone in. The decoder does not wait for it, and the call that brings it hands it over with frame 0's time.
        let format = TestFormats.h264
        let output = FFmpegVideoDecoder.outputSize(width: format.width, height: format.height, maxWidth: 160)
        let rig = rig(width: output.width, height: output.height, keepEvery: 4, delay: 2)
        let decoder = try rig.codecs.makeSkyDecoder(format: format, maxOutputWidth: 160, keepEvery: 4)
        defer { decoder.invalidate() }
        let begun = ContinuousClock.now
        var calls: [Int] = []
        var times: [MediaTime] = []
        for index in 0..<12 {
            var frame = TestFormats.frame(index, key: index == 0)
            frame.dts = MediaTime(value: frame.pts.value - 7_200, timescale: 90_000)
            if let picture = try await decoder.decode(frame) {
                calls.append(index)
                times.append(picture.pts)
            }
        }
        #expect(calls == [2, 6, 10], "each picture comes with the call that brought it")
        #expect(times == [0, 4, 8].map { TestFormats.frame($0, key: false).pts })
        #expect(ContinuousClock.now - begun < .milliseconds(400))
    }

    @Test func everyPictureIsKeptWhenAskedForEveryPicture() async throws {
        let format = TestFormats.h264
        let output = FFmpegVideoDecoder.outputSize(width: format.width, height: format.height, maxWidth: 160)
        for keepEvery in [1, 0, -3] {
            let rig = rig(width: output.width, height: output.height, keepEvery: 1)
            let decoder = try rig.codecs.makeSkyDecoder(format: format, maxOutputWidth: 160, keepEvery: keepEvery)
            defer { decoder.invalidate() }
            for index in 0..<6 {
                let frame = TestFormats.frame(index, key: index == 0)
                let picture = try #require(try await decoder.decode(frame) as? RawVideoFrame, "keepEvery \(keepEvery), frame \(index)")
                #expect(picture.pts == frame.pts)
            }
            let args = try #require(rig.decoderChildren.first).arguments
            #expect(!chain(args).contains("select"), "keepEvery \(keepEvery)")
        }
    }

    @Test func aThumbnailOfThePicturesOwnSizeIsItsLuma() throws {
        let width = 8, height = 6
        let luma = (0..<(width * height)).map { UInt8($0 * 5) }
        let chroma = [UInt8](repeating: 128, count: 2 * (width / 2) * (height / 2))
        let picture = RawVideoFrame(width: width, height: height, pts: MediaTime(value: 0, timescale: 90_000), pixels: Data(luma + chroma))
        let same = try #require(picture.grayThumbnail(maxWidth: width))
        #expect(same.width == width && same.height == height && same.pixels == luma)
        let wider = try #require(picture.grayThumbnail(maxWidth: 1920))
        #expect(wider == same, "a picture is never made larger")
        let half = try #require(picture.grayThumbnail(maxWidth: 4))
        #expect(half.width == 4 && half.height == 3)
    }

    // MARK: Priority

    @Test func theSkyDecoderAsksForALowPriorityChild() async throws {
        let format = TestFormats.h264
        let rig = rig(width: 160, height: 90, keepEvery: 4)
        let sky = try rig.codecs.makeSkyDecoder(format: format, maxOutputWidth: 160, keepEvery: 4)
        defer { sky.invalidate() }
        _ = try await sky.decode(TestFormats.frame(0, key: true))
        let child = try #require(rig.decoderChildren.first)
        #expect(child.spec.niceness == 10 && child.spec.niceness == FFmpegVideoDecoder.skyNiceness)
        // The other decoders keep the priority they had.
        let plain = self.rig(width: format.width, height: format.height, keepEvery: 1)
        let motion = try plain.codecs.makeVideoDecoder(format: format)
        defer { motion.invalidate() }
        _ = try await motion.decode(TestFormats.frame(0, key: true))
        #expect(try #require(plain.decoderChildren.first).spec.niceness == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aChildWithANicenessRunsAtThatNiceness() throws {
        // A shell that says its own niceness in place of ffmpeg, started by the real process layer.
        func niceness(_ requested: Int?) throws -> Int {
            #if os(Linux)
            let script = "exec cut -d' ' -f19 /proc/$$/stat"   // the 19th field of /proc/<pid>/stat is the niceness
            #else
            let script = "exec ps -o nice= -p $$"
            #endif
            let spec = FFmpegProcessSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], label: "nice test", niceness: requested)
            let session = try FFmpegSession(launcher: SystemFFmpegLauncher(), spec: spec)
            session.closeInput()
            let exit = try #require(session.waitForExit(timeout: .seconds(10)))
            #expect(exit.status == 0, "\(exit.summary)")
            let text = String(decoding: session.drain(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return try #require(Int(text), "the niceness read: \(text)")
        }
        let normal = try niceness(nil)
        let low = try niceness(10)
        #expect(low == min(19, normal + 10), "\(normal) as it is, \(low) niced")
    }

    // MARK: The GPU

    @Test func fitsHardwareFollowsTheGPUsLimits() {
        #expect(!FFmpegVideoDecoder.fitsHardware(format(.h264, 4256, 1888)), "Intel's H.264 decoder stops at 4096")
        #expect(FFmpegVideoDecoder.fitsHardware(format(.h264, 3840, 2160)))
        #expect(FFmpegVideoDecoder.fitsHardware(format(.hevc, 4256, 1888)), "HEVC goes up to 8192")
        #expect(FFmpegVideoDecoder.fitsHardware(format(.h264, 4096, 4096)))
        #expect(!FFmpegVideoDecoder.fitsHardware(format(.h264, 4097, 2160)) && !FFmpegVideoDecoder.fitsHardware(format(.h264, 2160, 4098)))
        #expect(FFmpegVideoDecoder.fitsHardware(format(.hevc, 8192, 8192)))
        #expect(!FFmpegVideoDecoder.fitsHardware(format(.hevc, 8194, 4320)) && !FFmpegVideoDecoder.fitsHardware(format(.hevc, 4320, 8196)))
    }

    @Test func aHeavyStreamThatFitsIsDecodedAndScaledOnTheGPUAndOnlyKeptPicturesComeBack() async throws {
        let big = format(.h264, 3840, 2160)
        let rig = rig(width: 1920, height: 1080, keepEvery: 4, vaapi: true)
        let decoder = try rig.codecs.makeSkyDecoder(format: big, maxOutputWidth: 1920, keepEvery: 4)
        defer { decoder.invalidate() }
        var pictures = 0
        for index in 0..<8 {
            let picture = try await decoder.decode(TestFormats.frame(index, key: index == 0, format: big)) as? RawVideoFrame
            #expect((picture != nil) == (index % 4 == 0), "frame \(index)")
            if let picture { #expect(picture.width == 1920 && picture.height == 1080); pictures += 1 }
        }
        #expect(pictures == 2)
        let arguments = try #require(rig.decoderChildren.first).arguments
        let filters = chain(arguments)
        #expect(arguments.contains("-hwaccel") && arguments.contains("-hwaccel_device") && arguments.contains(Self.renderNode))
        #expect(filters.hasPrefix("scale_vaapi=w=1920:h=1080:format=nv12:mode=hq,select='not(mod(n\\,4))',hwdownload"), "\(filters)")
        #expect(decoder.decodingPlace == .gpu)
    }

    @Test func aStreamTheGPUCannotTakeIsDecodedInSoftwareFromTheStart() async throws {
        let warnings = WarningLines()
        let token = LogHub.addSink(warnings)
        defer { LogHub.removeSink(token) }
        let big = format(.h264, 4256, 1888)   // wider than Intel's H.264 decoder takes
        let output = FFmpegVideoDecoder.outputSize(width: 4256, height: 1888, maxWidth: 1920)
        #expect(output.width == 1920 && output.height == 852)
        let rig = rig(width: output.width, height: output.height, keepEvery: 4, vaapi: true)
        let decoder = try rig.codecs.makeSkyDecoder(format: big, maxOutputWidth: 1920, keepEvery: 4)
        defer { decoder.invalidate() }
        let picture = try #require(try await decoder.decode(TestFormats.frame(0, key: true, format: big)) as? RawVideoFrame)
        #expect(picture.width == 1920 && picture.height == 852)
        let arguments = try #require(rig.decoderChildren.first).arguments
        #expect(!arguments.contains("-hwaccel") && !chain(arguments).contains("vaapi"), "no GPU for a picture it cannot take")
        #expect(chain(arguments).hasPrefix("select='not(mod(n\\,4))',scale=1920:852:flags=area"), "\(chain(arguments))")
        #expect(decoder.decodingPlace == .software)
        #expect(warnings.matching("GPU").isEmpty, "nothing failed: it was never tried")
    }

    @Test(arguments: GPUDeath.allCases)
    func aGPUThatDiesBeforeItsFirstPictureFallsBackToSoftware(death: GPUDeath) async throws {
        let warnings = WarningLines()
        let token = LogHub.addSink(warnings)
        defer { LogHub.removeSink(token) }
        let big = format(.h264, 3840, 2160)   // the GPU takes it, and here fails
        let rig = rig(width: 1920, height: 1080, keepEvery: 4, vaapi: true, gpuDies: death)
        let decoder = try rig.codecs.makeSkyDecoder(format: big, maxOutputWidth: 1920, keepEvery: 4)
        defer { decoder.invalidate() }
        #expect(decoder.decodingPlace == nil || decoder.decodingPlace == .gpu)

        // The GPU session ends without a picture: the call fails, as every decoder's does.
        var failed = false
        for index in 0..<2 where !failed {
            do { _ = try await decoder.decode(TestFormats.frame(index, key: index == 0, format: big)) } catch { failed = true }
        }
        #expect(failed, "\(death)")
        let first = try #require(rig.decoderChildren.first).arguments
        #expect(first.contains("-hwaccel") && chain(first).contains("scale_vaapi"))

        // The next keyframe starts a pipeline with no hardware device, and the pictures come.
        let again = try #require(try await decoder.decode(TestFormats.frame(25, key: true, format: big)) as? RawVideoFrame)
        #expect(again.pts == TestFormats.frame(25, key: true, format: big).pts && again.width == 1920)
        #expect(rig.decoderChildren.count == 2)
        let second = rig.decoderChildren[1].arguments
        #expect(!second.contains("-hwaccel") && !second.contains("-hwaccel_device") && !chain(second).contains("vaapi"), "\(second)")
        #expect(decoder.decodingPlace == .software)

        // It is said once, and it holds for that stream whatever decoder asks next; another stream gets its own try.
        let line = "the GPU could not decode H.264 3840×2160; decoding in software"
        #expect(warnings.matching(line).count == 1, "\(warnings.matching("GPU"))")
        let other = try rig.codecs.makeSkyDecoder(format: big, maxOutputWidth: 1920, keepEvery: 4)
        defer { other.invalidate() }
        _ = try await other.decode(TestFormats.frame(0, key: true, format: big))
        #expect(rig.decoderChildren.count == 3 && !rig.decoderChildren[2].arguments.contains("-hwaccel"))
        #expect(warnings.matching(line).count == 1)
        let third = try rig.codecs.makeSkyDecoder(format: format(.h264, 3000, 2000), maxOutputWidth: 1920, keepEvery: 4)
        defer { third.invalidate() }
        _ = try? await third.decode(TestFormats.frame(0, key: true, format: format(.h264, 3000, 2000)))
        #expect(rig.decoderChildren.count == 4 && rig.decoderChildren[3].arguments.contains("-hwaccel"), "a stream of another size is tried on the GPU")
    }

    @Test func aGPUThatFailedIsTriedAgainAfterTenMinutes() async throws {
        // One GPU session that dies before its first picture used to send that kind of stream to software until the daemon restarted: a hiccup
        // of the GPU cost a core for good. Now the software holds for 10 minutes, and the GPU is tried again.
        let warnings = WarningLines()
        let token = LogHub.addSink(warnings)
        defer { LogHub.removeSink(token) }
        let clock = TestClock()
        let weather = GPUWeather()
        weather.set(.atLaunch)
        let big = format(.h264, 3840, 2160)
        let rig = rig(width: 1920, height: 1080, keepEvery: 4, vaapi: true, weather: weather, now: { clock.now })
        let line = "the GPU could not decode H.264 3840×2160; decoding in software"
        var decoders: [any VideoDecoding] = []
        defer { decoders.forEach { $0.invalidate() } }

        /// A new decoder is given keyframes until a picture comes. Whether its first child was started on the GPU, and the decoder.
        func newDecoder() async throws -> (triedGPU: Bool, decoder: any VideoDecoding) {
            let before = rig.decoderChildren.count
            let decoder = try rig.codecs.makeSkyDecoder(format: big, maxOutputWidth: 1920, keepEvery: 4)
            decoders.append(decoder)
            var picture: RawVideoFrame?
            for index in 0..<4 where picture == nil {
                picture = try? await decoder.decode(TestFormats.frame(index * 25, key: true, format: big)) as? RawVideoFrame
            }
            _ = try #require(picture, "a picture comes, on the GPU or in software")
            return (rig.decoderChildren[before].arguments.contains("-hwaccel"), decoder)
        }

        let first = try await newDecoder()
        #expect(first.triedGPU && warnings.matching(line).count == 1, "the GPU is tried, dies, and the stream goes to software: \(warnings.matching("GPU"))")
        clock.advance(599)
        let early = try await newDecoder()
        #expect(!early.triedGPU && warnings.matching(line).count == 1, "ten minutes less a second on: still software, for every decoder")
        clock.advance(1)
        let due = try await newDecoder()
        #expect(due.triedGPU, "ten minutes after the failure the GPU is tried again")
        #expect(warnings.matching(line).count == 2, "it failed again, and that is said again")

        // The new failure starts the ten minutes afresh.
        clock.advance(599)
        let again = try await newDecoder()
        #expect(!again.triedGPU && warnings.matching(line).count == 2)

        // The GPU is itself again: the next try keeps it, and nothing is said.
        weather.set(nil)
        clock.advance(1)
        let back = try await newDecoder()
        #expect(back.triedGPU && back.decoder.decodingPlace == .gpu && warnings.matching(line).count == 2, "\(warnings.matching("GPU"))")
        let after = try await newDecoder()
        #expect(after.triedGPU && after.decoder.decodingPlace == .gpu, "no failure is held against it any more")
        #expect(FFmpegRuntime.hardwareDecodeRetryAfter == 600)
    }

    // MARK: A real ffmpeg

    @Test(.enabled(if: FFmpegTesting.available), .timeLimit(.minutes(2)))
    func aRealStreamKeepsEveryNthPictureWithItsOwnTime() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 2, gop: 25)
        let decoder = try FFmpegTesting.makeCodecs().makeSkyDecoder(format: source[0].format, maxOutputWidth: 160, keepEvery: 4)
        defer { decoder.invalidate() }
        var pictures: [RawVideoFrame] = []
        let begun = ContinuousClock.now
        for frame in source {
            if let picture = try await decoder.decode(frame) as? RawVideoFrame { pictures.append(picture) }
        }
        #expect(pictures.count == (source.count + 3) / 4, "frames 0, 4, 8, …: \(pictures.count) of \(source.count)")
        #expect(pictures.map(\.pts) == stride(from: 0, to: source.count, by: 4).map { source[$0].pts })
        #expect(pictures.allSatisfy { $0.width == 160 && $0.height == 90 })
        #expect(pictures[0].pixels != pictures[6].pixels, "the test pattern moves")
        #expect(ContinuousClock.now - begun < .seconds(10), "dropped pictures cost no waiting")
        #expect(decoder.decodingPlace == .software)
    }
}
