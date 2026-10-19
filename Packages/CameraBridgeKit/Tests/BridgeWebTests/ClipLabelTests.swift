import BridgeEngine
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeWeb

/// The label burned into a saved clip: the time of every picture, exact across the gaps the clip skips. And the straightened clip: the camera's
/// picture correction warped in before the label is drawn, at the size the clip is written.
@Suite struct ClipLabelTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func part(_ seconds: Double) -> ClipPart {
        ClipPart(index: 1, count: 1, start: t0, end: t0.addingTimeInterval(seconds), leadIn: 0, byteCount: 1, sampleCount: 1, fileName: "x.mp4")
    }

    @Test func oneRunWithoutSkippedGapsAndAHeldGapKeepsTheClockRunning() {
        let held = ClipGap(from: Self.t0.addingTimeInterval(10), to: Self.t0.addingTimeInterval(14), held: true)
        #expect(WebApp.labelRuns(part: Self.part(60), gaps: [held]) == [.init(mediaStart: 0, mediaEnd: nil, wallBase: 1_800_000_000)])
    }

    @Test func aSkippedGapStartsANewRunWhoseClockJumpsByTheGap() {
        let skipped = ClipGap(from: Self.t0.addingTimeInterval(20), to: Self.t0.addingTimeInterval(320), held: false)
        let later = ClipGap(from: Self.t0.addingTimeInterval(400), to: Self.t0.addingTimeInterval(460), held: false)
        let runs = WebApp.labelRuns(part: Self.part(500), gaps: [later, skipped])
        #expect(runs == [
            .init(mediaStart: 0, mediaEnd: 20, wallBase: 1_800_000_000),
            .init(mediaStart: 20, mediaEnd: 100, wallBase: 1_800_000_300),     // media 20 s shows wall t0 + 320 s
            .init(mediaStart: 100, mediaEnd: nil, wallBase: 1_800_000_360),    // media 100 s shows wall t0 + 460 s
        ])
    }

    @Test func theTimeFormatFollowsTheStyle() {
        var style = TimestampOverlaySettings(showDate: true, showSeconds: true, use24Hour: false)
        #expect(WebApp.labelTimeFormat(style) == "%a, %b %-d  %-I:%M:%S %p")
        style.use24Hour = true; style.showSeconds = false; style.showDate = false
        #expect(WebApp.labelTimeFormat(style) == "%H:%M")
    }

    @Test func theTextEscapesColonsInTheClockAndPercentSignsInTheName() {
        let style = TimestampOverlaySettings(showCameraName: true, showDate: false, showSeconds: false, use24Hour: true)
        #expect(WebApp.labelText(name: "Gate 100%", style: style, wallBase: 1_800_000_000.25)
                == "Gate 100%%  |  %{pts:localtime:1800000000.250:%H\\:%M}")
        var noName = style
        noName.showCameraName = false
        #expect(WebApp.labelText(name: "Gate", style: noName, wallBase: 0) == "%{pts:localtime:0.000:%H\\:%M}")
    }

    @Test func theArgumentsDrawEveryRunOnlyWhileItIsOnScreenAndEncodeOnTheGPUWhenThereIsOne() {
        let runs: [(WebApp.LabelRun, String)] = [(.init(mediaStart: 0, mediaEnd: 20, wallBase: 0), "/t/a.txt"), (.init(mediaStart: 20, mediaEnd: nil, wallBase: 9), "/t/b.txt")]
        let gpu = WebApp.clipArguments(input: "/t/clip.mp4", textFiles: runs, style: TimestampOverlaySettings(), font: nil, correction: nil, vaapiDevice: "/dev/dri/renderD128")
        let filters = gpu[gpu.firstIndex(of: "-vf")! + 1]
        #expect(filters.contains("enable='between(t\\,0.000\\,20.000)'") && filters.contains("enable='gte(t\\,20.000)'"))
        #expect(filters.hasPrefix("scale='min(iw\\,3840)':-2,") && filters.hasSuffix("format=nv12,hwupload"))
        #expect(gpu.contains("h264_vaapi") && gpu.contains("-vaapi_device") && gpu.last == "pipe:1")
        let cpu = WebApp.clipArguments(input: "/t/clip.mp4", textFiles: runs, style: TimestampOverlaySettings(), font: nil, correction: nil, vaapiDevice: nil)
        #expect(cpu.contains("libx264") && !cpu.contains("-vaapi_device"))
    }

    // MARK: Straightened clips

    static let runs: [(WebApp.LabelRun, String)] = [(.init(mediaStart: 0, mediaEnd: 20, wallBase: 0), "/t/a.txt"), (.init(mediaStart: 20, mediaEnd: nil, wallBase: 9), "/t/b.txt")]
    static func maps(_ width: Int, _ height: Int) -> WebApp.ClipCorrectionMaps {
        (xMap: "/t/x.pgm", yMap: "/t/y.pgm", chromaXMap: "/t/cx.pgm", chromaYMap: "/t/cy.pgm", width: width, height: height)
    }

    /// The value of `option` in `arguments` (the argument after it).
    static func value(_ option: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: option).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    /// `arguments` holds `run` as consecutive arguments.
    static func contains(_ arguments: [String], _ run: [String]) -> Bool {
        arguments.count >= run.count && (0...(arguments.count - run.count)).contains { Array(arguments[$0 ..< $0 + run.count]) == run }
    }

    @Test func aStraightenedClipWarpsThenLabels() throws {
        let arguments = WebApp.clipArguments(input: "/t/clip.mp4", textFiles: Self.runs, style: TimestampOverlaySettings(), font: nil,
                                             correction: Self.maps(1920, 852), vaapiDevice: nil)
        // The recording, then the four maps in the order the chain reads them (inputs 1 to 4).
        #expect(Self.contains(arguments, ["-i", "/t/clip.mp4", "-i", "/t/x.pgm", "-i", "/t/y.pgm", "-i", "/t/cx.pgm", "-i", "/t/cy.pgm", "-filter_complex"]))
        #expect(!arguments.contains("-vf"))
        let graph = try #require(Self.value("-filter_complex", in: arguments))
        let chain = PictureCorrection.ffmpegRemapChain(input: "0:v:0", width: 1920, height: 852, xMap: "1:v", yMap: "2:v", chromaXMap: "3:v",
                                                       chromaYMap: "4:v", output: "cbw")
        // The warp first, then the label (upright on the straightened picture: both runs, each while it is on screen), then the encoder's format.
        #expect(graph.hasPrefix(chain + ";[cbw]drawtext="), "\(graph)")
        #expect(graph.contains("enable='between(t\\,0.000\\,20.000)'") && graph.contains("enable='gte(t\\,20.000)'"))
        #expect(graph.hasSuffix(",format=yuv420p[cbv]"))
        #expect(!graph.contains("min(iw"), "the chain makes the clip's size; nothing scales after it")
        #expect(Self.contains(arguments, ["-map", "[cbv]", "-map", "0:a:0?", "-sn", "-dn"]))
        #expect(arguments.contains("libx264") && arguments.last == "pipe:1")

        let gpu = WebApp.clipArguments(input: "/t/clip.mp4", textFiles: Self.runs, style: TimestampOverlaySettings(), font: nil,
                                       correction: Self.maps(1920, 852), vaapiDevice: "/dev/dri/renderD128")
        #expect(Self.contains(gpu, ["-nostdin", "-vaapi_device", "/dev/dri/renderD128", "-i", "/t/clip.mp4", "-i", "/t/x.pgm"]))
        #expect(Self.value("-filter_complex", in: gpu)?.hasSuffix(",format=nv12,hwupload[cbv]") == true && gpu.contains("h264_vaapi"))

        // Straightened without the label: the warp and the format only.
        let plain = WebApp.clipArguments(input: "/t/clip.mp4", textFiles: [], style: nil, font: nil, correction: Self.maps(1920, 852), vaapiDevice: nil)
        #expect(Self.value("-filter_complex", in: plain) == chain + ";[cbw]format=yuv420p[cbv]")
    }

    @Test func aStraightenedClipWiderThan3840IsShrunkFirst() throws {
        // The owner's panorama (4256 × 1888) is written 3840 wide (the H.264 encoder's limit is 4096), its height in proportion and even,
        // as `scale='min(iw\,3840)':-2` writes it.
        let size = MediaFit.cappedEvenSize(width: 4256, height: 1888)
        #expect(size.width == 3840 && size.height == 1704)
        let kept = MediaFit.cappedEvenSize(width: 1920, height: 852)
        #expect(kept.width == 1920 && kept.height == 852)
        let odd = MediaFit.cappedEvenSize(width: 1281, height: 721)
        #expect(odd.width == 1280 && odd.height == 720, "an odd size is made even (4:2:0)")
        let arguments = WebApp.clipArguments(input: "/t/clip.mp4", textFiles: Self.runs, style: TimestampOverlaySettings(), font: nil,
                                             correction: Self.maps(size.width, size.height), vaapiDevice: nil)
        let graph = try #require(Self.value("-filter_complex", in: arguments))
        // The chain's first step takes the camera's picture to the clip's width (twice the height: the warp's supersampling); its last makes the clip's size.
        #expect(graph.hasPrefix("[0:v:0]scale=3840:3408:flags=bicubic,"))
        #expect(graph.contains(",scale=3840:1704:flags=area[cbw];[cbw]drawtext="))
        #expect(!graph.contains("min(iw"))
    }

    @Test func labelsAloneAreUnchanged() {
        // Today's labelled clip, argument for argument (a bottom-right label, a font whose path has a quote).
        var style = TimestampOverlaySettings()
        style.position = .bottomRight
        let draw = { (file: String, window: String) in
            #"drawtext=fontfile='/f/Deja'\''Vu.ttf':textfile='"# + file + #"':expansion=normal:fontsize=h*0.032:fontcolor=white:box=1:boxcolor=black@0.42:boxborderw=6:shadowcolor=black@0.5:shadowx=1:shadowy=1:x=w-tw-(h*0.032*0.9+h*0.032*0.35):y=h-th-(h*0.032*0.9+h*0.032*0.35):enable='"# + window + "'"
        }
        let filters = #"scale='min(iw\,3840)':-2,"# + draw("/t/a.txt", #"between(t\,0.000\,20.000)"#) + "," + draw("/t/b.txt", #"gte(t\,20.000)"#)
        let tail = ["-c:a", "copy", "-movflags", "frag_keyframe+empty_moov+default_base_moof", "-f", "mp4", "pipe:1"]
        let gpu = WebApp.clipArguments(input: "/t/clip.mp4", textFiles: Self.runs, style: style, font: "/f/Deja'Vu.ttf", correction: nil, vaapiDevice: "/dev/dri/renderD128")
        #expect(gpu == ["-hide_banner", "-loglevel", "error", "-nostdin", "-vaapi_device", "/dev/dri/renderD128", "-i", "/t/clip.mp4", "-map", "0:v:0", "-map", "0:a:0?",
                        "-sn", "-dn", "-vf", filters + ",format=nv12,hwupload", "-c:v", "h264_vaapi", "-rc_mode", "CQP", "-qp", "23"] + tail)
        let cpu = WebApp.clipArguments(input: "/t/clip.mp4", textFiles: Self.runs, style: style, font: "/f/Deja'Vu.ttf", correction: nil, vaapiDevice: nil)
        #expect(cpu == ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", "/t/clip.mp4", "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn", "-vf", filters,
                        "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p"] + tail)
    }

    // MARK: The route

    /// A camera named `name` (each route test its own: the log lines they look for are everyone's) with recordings and `correction`.
    private func rig(_ name: String, correction: PictureCorrection = .off) async throws -> NVRRig {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file(fragments: 8, gopFragments: 2)]
        rig.backend.write {
            $0.configurations[0].name = name
            $0.configurations[0].pictureCorrection = correction
        }
        return rig
    }

    private func clip(_ rig: NVRRig, _ extra: String) async throws -> (response: HTTPResponse, body: Data) {
        let response = await rig.harness.raw("GET", "/api/v1/nvr/cameras/\(rig.cameraID)/clip?from=\(rig.ms(1_500))&to=\(rig.ms(6_000))&tz=UTC&part=1" + extra,
                                             cookie: rig.session.cookie)
        guard case .stream(let body) = response.body else { return (response, Data()) }
        let collected = Box(Data())
        try await body(ResponseStream { data in collected.update { $0.append(data) } })
        return (response, collected.value)
    }

    @Test(.timeLimit(.minutes(1))) func straightenWithTheCorrectionOffIsACopy() async throws {
        let rig = try await rig("Gate")
        let planned = try #require(jsonInt(await rig.get("nvr/cameras/\(rig.cameraID)/clip-plan?from=\(rig.ms(1_500))&to=\(rig.ms(6_000))&tz=UTC").json["bytes"]))
        let log = LogCapture()
        defer { log.stop() }
        let (response, file) = try await clip(rig, "&straighten=1")
        #expect(response.status == 200)
        #expect(Int64(file.count) == planned, "the recording's bytes as they are, no converter")
        #expect(log.text.contains { $0.hasSuffix(": a clip of Gate is being sent") })
        #expect(!log.text.contains { $0.contains("a clip of Gate is being sent straightened") })
    }

    @Test(.timeLimit(.minutes(1))) func straightenWithTheCorrectionOnGoesThroughTheConverter() async throws {
        let rig = try await rig("Backyard", correction: PictureCorrection(straighten: 0.4, level: 0.15))
        let log = LogCapture()
        defer { log.stop() }
        let (alone, _) = try await clip(rig, "&straighten=1")
        let (both, _) = try await clip(rig, "&straighten=1&labels=1")
        guard WebApp.ffmpegPath() != nil else {
            #expect(alone.status == 501 && both.status == 501, "no converter on this machine")
            return
        }
        // The fixture's pictures are not real H.264, so the converter's answer is not looked at here (the real-ffmpeg test plays one).
        #expect(alone.status == 200 && both.status == 200)
        #expect(log.text.contains { $0.hasSuffix(": a clip of Backyard is being sent straightened") })
        #expect(log.text.contains { $0.hasSuffix(": a clip of Backyard is being sent straightened, with its label") })
        // Without straighten=1 the correction does not apply (the person unticked Straightened): a copy.
        let (copy, file) = try await clip(rig, "")
        #expect(copy.status == 200 && Array(file.prefix(8).suffix(4)) == Array("ftyp".utf8))
        #expect(log.text.contains { $0.hasSuffix(": a clip of Backyard is being sent") })
    }

    @Test func thePictureSizeIsTheRecordingsOwn() async throws {
        let rig = try await rig("Porch")
        let archive = try #require(rig.backend.archive)
        let exporter = ClipExporter(archive: archive)
        let request = ClipRequest(camera: rig.camera.id, cameraName: "Porch", start: WebApp.date(milliseconds: rig.ms(1_500)),
                                  end: WebApp.date(milliseconds: rig.ms(6_000)), timeZone: TimeZone(identifier: "UTC")!)
        let plan = try await exporter.plan(request)
        let size = try await exporter.pictureSize(plan, part: 1)
        #expect(size.width == 640 && size.height == 360, "the fixture's H.264 is 640 × 360")
        await #expect(throws: ClipError.notReady) { try await exporter.pictureSize(plan, part: 2) }
        let fake = ClipPlan(request: request, parts: plan.parts, gaps: [], soundOmitted: false)
        await #expect(throws: ClipError.notReady) { try await exporter.pictureSize(fake, part: 1) }
    }

    // MARK: A stopped download

    /// Runs `script` (sh) as the converter into a browser that takes the first chunk and then stops reading, stops the download once that
    /// chunk came, and answers the child's pid (the script's first line), what `runStreaming` threw and how long it took to return.
    private func stopped(_ script: String, grace: TimeInterval) async throws -> (pid: Int32, error: (any Error)?, after: Duration) {
        let (firsts, first) = AsyncStream<Data>.makeStream()
        let browser = ResponseStream { data in
            first.yield(data)
            try await Task.sleep(for: .seconds(3_600))   // a browser that stopped reading
        }
        let conversion = Task {
            try await WebApp.runStreaming(executable: "/bin/sh", arguments: ["-c", script], timeZone: "UTC", into: browser, stopGrace: grace)
        }
        var chunks = firsts.makeAsyncIterator()
        let chunk = try #require(await chunks.next())
        let pid = try #require(Int32(String(decoding: chunk.prefix { $0 != 0x0A }, as: UTF8.self)))
        let clock = ContinuousClock()
        let start = clock.now
        conversion.cancel()
        let result = await conversion.result
        let after = clock.now - start
        guard case .failure(let error) = result else { return (pid, nil, after) }
        return (pid, error, after)
    }

    /// The process has exited and been reaped.
    private func isGone(_ pid: Int32) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

    @Test(.timeLimit(.minutes(1))) func aStoppedDownloadDrainsAChildThatWritesOnAfterSIGTERM() async throws {
        // Like ffmpeg after SIGTERM: it writes its last fragment and the encoder's delayed pictures, here 40 MB (far more than the pipe and the
        // 16 chunks the reader may hold), then ends by itself. Nobody reads it any more, so the reader throws it away.
        let (pid, error, after) = try await stopped("echo $$; trap 'head -c 40000000 /dev/zero; exit 0' TERM; while :; do echo picture; sleep 0.01; done",
                                                    grace: 5)
        #expect(error is ClipDownloadStopped)
        #expect(isGone(pid), "the child is gone when runStreaming returns")
        #expect(after < .seconds(4), "drained, not killed after the grace: \(after)")
    }

    @Test(.timeLimit(.minutes(1))) func aStoppedDownloadKillsAChildThatIgnoresSIGTERM() async throws {
        // A child that ignores SIGTERM and writes for ever: killed once the grace has passed, and its pipe read to the end.
        let (pid, error, after) = try await stopped("echo $$; trap '' TERM; exec yes", grace: 0.5)
        #expect(error is ClipDownloadStopped)
        #expect(isGone(pid), "the child is gone when runStreaming returns")
        #expect(after >= .milliseconds(450) && after < .seconds(4), "killed after the grace: \(after)")
    }

    // MARK: With a real ffmpeg

    /// The first picture of `file` as 8-bit grey, decoded by ffmpeg.
    private func firstPicture(_ file: URL) throws -> [UInt8] {
        let decoded = try ClipTools.run(ClipTools.ffmpeg, ["-hide_banner", "-loglevel", "error", "-i", file.path, "-frames:v", "1", "-f", "rawvideo",
                                                           "-pix_fmt", "gray", "pipe:1"])
        try #require(decoded.status == 0, "\(decoded.errors)")
        return [UInt8](decoded.data)
    }

    /// The row of the brightest pixel of each column at or below `top`.
    private func brightestRows(_ pixels: [UInt8], width: Int, height: Int, from top: Int) -> [Int] {
        (0..<width).map { column in (top..<height).max { pixels[$0 * width + column] < pixels[$1 * width + column] } ?? 0 }
    }

    @Test(.enabled(if: ClipTools.available, "ffmpeg and ffprobe not found; set CB_FFMPEG and CB_FFPROBE"), .timeLimit(.minutes(1)))
    func aStraightenedLabelledClipIsAPlayableMP4OfTheClipsSizeWithItsHorizonFlat() async throws {
        let folder = try TemporaryDirectory(prefix: "cb-clip-straighten")
        defer { folder.remove() }
        // A recording like the dev archive's fixtures (linux/web-dev/make-fixtures.sh: H.264 in fragmented MP4 at 90 kHz), two seconds of a
        // panorama's shape whose picture is a white line 3 pixels tall along Backyard's bent horizon, on black.
        let backyard = PictureCorrection(straighten: 0.4, level: 0.15)
        let (width, height) = (640, 284)
        let u = "(2*(X+0.5)/W-1)"
        let horizon = "H*(0.5+\(backyard.straighten)*(1-\(u)*\(u))+\(backyard.level)*\(u))"
        let recording = folder.file("recording.mp4")
        let made = try ClipTools.run(ClipTools.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                                                        "-i", "color=c=black:s=\(width)x\(height):r=25:d=2,format=yuv420p,geq=lum='if(lte(abs(Y-\(horizon)),1.5),235,16)':cb=128:cr=128",
                                                        "-c:v", "libx264", "-preset", "veryfast", "-qp", "10", "-pix_fmt", "yuv420p", "-bf", "0", "-g", "25",
                                                        "-movflags", "+frag_keyframe+empty_moov+default_base_moof", "-video_track_timescale", "90000", "-an",
                                                        recording.path])
        try #require(made.status == 0, "\(made.errors)")
        let size = MediaFit.cappedEvenSize(width: width, height: height)
        let maps = try WebApp.writeCorrectionMaps(backyard, width: size.width, height: size.height, in: folder.url)
        let label = folder.file("label-0.txt")
        let style = TimestampOverlaySettings(showCameraName: true)
        try Data(WebApp.labelText(name: "Backyard", style: style, wallBase: 1_800_000_000).utf8).write(to: label)
        let arguments = WebApp.clipArguments(input: recording.path, textFiles: [(WebApp.LabelRun(mediaStart: 0, mediaEnd: nil, wallBase: 1_800_000_000), label.path)],
                                             style: style, font: WebApp.labelFont(), correction: maps, vaapiDevice: nil)
        let collected = Box(Data())
        try await WebApp.runStreaming(executable: try #require(ClipTools.ffmpeg), arguments: arguments, timeZone: "UTC",
                                      into: ResponseStream { data in collected.update { $0.append(data) } })
        let clip = folder.file("clip.mp4")
        try collected.value.write(to: clip)
        let probe = try ClipTools.run(ClipTools.ffprobe, ["-v", "error", "-count_frames", "-select_streams", "v:0",
                                                          "-show_entries", "stream=codec_name,width,height,nb_read_frames", "-of", "default=noprint_wrappers=1", clip.path])
        #expect(probe.status == 0, "\(probe.errors)")
        let fields = Dictionary(probe.text.split(separator: "\n").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }.filter { $0.count == 2 }.map { ($0[0], $0[1]) },
                                uniquingKeysWith: { first, _ in first })
        #expect(fields == ["codec_name": "h264", "width": "640", "height": "284", "nb_read_frames": "50"], "\(probe.text)")

        // The warp, compared with the recording (an identity map leaves the line where it was, and fails): below the label (top 40 rows),
        // in the middle 90 % of the columns, the recording's line follows the bent horizon, the clip's lies on the landing row.
        let landing = backyard.landing * Double(height)
        let columns = (width / 20)..<(width - width / 20)
        let before = brightestRows(try firstPicture(recording), width: width, height: height, from: 40)
        #expect(columns.filter { abs(Double(before[$0]) - landing) > 3 }.count > columns.count / 2, "the recording's horizon is bent")
        let straightened = try firstPicture(clip)
        try #require(straightened.count == width * height)
        let after = brightestRows(straightened, width: width, height: height, from: 40)
        let off = columns.filter { abs(Double(after[$0]) - landing) > 3 }.map { "column \($0): row \(after[$0])" }
        #expect(off.isEmpty, "the horizon lands on row \(landing): \(off.prefix(12))")
        // The label is drawn on the clip (top right, white on its box), where the recording is black.
        #expect((0..<36).contains { row in (width / 2..<width).contains { straightened[row * width + $0] > 180 } }, "the label is on the clip")
    }
}

/// ffmpeg and ffprobe, found as the other real-ffmpeg tests find them (`CB_FFMPEG` / `CB_FFPROBE`, then Homebrew's, then the system's).
enum ClipTools {
    static let ffmpeg = locate("ffmpeg", variable: "CB_FFMPEG")
    static let ffprobe = locate("ffprobe", variable: "CB_FFPROBE")
    static var available: Bool { ffmpeg != nil && ffprobe != nil }

    private static func locate(_ name: String, variable: String) -> String? {
        [ProcessInfo.processInfo.environment[variable], "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Output {
        var status: Int32
        var data: Data
        var errors: String
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    /// Runs `tool` with its output in temporary files, and stops it after `timeout` seconds.
    static func run(_ tool: String?, _ arguments: [String], timeout: TimeInterval = 50) throws -> Output {
        let tool = try #require(tool, "ffmpeg tools not found; set CB_FFMPEG and CB_FFPROBE")
        let scratch = try TemporaryDirectory(prefix: "cb-clip-tool")
        defer { scratch.remove() }
        let standardOutput = scratch.file("out.txt"), standardError = scratch.file("err.txt")
        FileManager.default.createFile(atPath: standardOutput.path, contents: nil)
        FileManager.default.createFile(atPath: standardError.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: standardOutput)
        process.standardError = try FileHandle(forWritingTo: standardError)
        // A semaphore, not `waitUntilExit()` (it runs the thread's run loop, which can sleep for good on a thread of the cooperative pool).
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            exited.wait()
        }
        return Output(status: process.terminationStatus, data: try Data(contentsOf: standardOutput),
                      errors: String(decoding: try Data(contentsOf: standardError), as: UTF8.self))
    }
}
