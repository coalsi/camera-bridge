import BridgeEngine
import BridgeSupport
import Foundation
import MediaCore
import Synchronization

// A saved clip that ffmpeg re-encodes (`GET /nvr/cameras/:id/clip?…&labels=1` and/or `&straighten=1`); without either it is copied as recorded
// (`WebApp+NVRClip.swift`). The clip is written as usual (`ClipExporter`) to a temporary file, then ffmpeg re-encodes it and the result is streamed
// as fragmented MP4 while it is made (the size is not known in advance). Encoding is on the GPU (VA-API) where there is one, else x264, at most
// 3840 pixels wide (the H.264 encoder's limit is 4096).
// At most `maximumClipConversions` (2) conversions run at once box-wide (`ConversionSlots`: a further one waits for a place, its answer begun and
// empty), and on Linux ffmpeg runs under `nice -n 10`, so the live video keeps the box's cores.
//
// Straightened (Straighten the picture, docs/superpowers/specs/2026-10-18-straighten-the-picture-design.md): the camera's picture correction,
// warped by the same per-plane `remap` chain as Apple Home's transcoder (`PictureCorrection.ffmpegRemapChain`), with maps made at the size the
// clip is written (`MediaFit.cappedEvenSize`, the rule the live transcoders use too) in the clip's private temporary folder. The chain takes the recording's picture to that size itself.
//
// Labelled: the camera's name and the date and time of every picture, in the camera's label style (`CameraConfiguration.timestampOverlay`:
// corner, size, name, date, seconds, 24-hour), the same words the bridge draws on Apple Home's video and the page draws on the Monitor, drawn
// after the warp so it stays upright. The time of a picture is exact across the clip: within a run of recording the picture at media time t was
// taken at run start + t; a gap the clip skips (`ClipGap.held == false`) starts a new run whose wall time jumps by the gap. ffmpeg's
// `%{pts:localtime:offset:format}` draws it in the bridge's time zone (`BridgeSettings.timeZone`, ffmpeg's `TZ`).
extension WebApp {
    /// One stretch of continuous time in a clip part: media seconds from `mediaStart` show wall time `wallBase + media seconds`.
    struct LabelRun: Equatable {
        var mediaStart: Double
        var mediaEnd: Double?
        var wallBase: Double
    }

    /// The runs of `part`: a new one after each gap the clip skipped.
    static func labelRuns(part: ClipPart, gaps: [ClipGap]) -> [LabelRun] {
        let start = part.start.timeIntervalSince1970
        var runs = [LabelRun(mediaStart: 0, mediaEnd: nil, wallBase: start)]
        var skipped = 0.0
        for gap in gaps.filter({ !$0.held && $0.from >= part.start && $0.from < part.end }).sorted(by: { $0.from < $1.from }) {
            let mediaAtGap = gap.from.timeIntervalSince1970 - start - skipped
            runs[runs.count - 1].mediaEnd = mediaAtGap
            skipped += gap.to.timeIntervalSince(gap.from)
            runs.append(LabelRun(mediaStart: mediaAtGap, mediaEnd: nil, wallBase: start + skipped))
        }
        return runs
    }

    /// The strftime format of the label's date and time for `style` ("%a, %b %-d  %-I:%M:%S %p").
    static func labelTimeFormat(_ style: TimestampOverlaySettings) -> String {
        let time = style.use24Hour ? (style.showSeconds ? "%H:%M:%S" : "%H:%M") : (style.showSeconds ? "%-I:%M:%S %p" : "%-I:%M %p")
        return style.showDate ? "%a, %b %-d  " + time : time
    }

    /// The text of one run for drawtext's `textfile` (its expansion: `\:` is a colon inside the `%{}` arguments, `\\` a backslash).
    static func labelText(name: String?, style: TimestampOverlaySettings, wallBase: Double) -> String {
        let format = labelTimeFormat(style).replacingOccurrences(of: ":", with: "\\:")
        let clock = "%{pts:localtime:\(String(format: "%.3f", wallBase)):\(format)}"
        guard style.showCameraName, let name, !name.isEmpty else { return clock }
        let shown = name.count > TimestampOverlayText.maximumNameLength ? String(name.prefix(TimestampOverlayText.maximumNameLength - 1)) + "…" : name
        let literal = shown.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "%%")
        return literal + "  |  " + clock
    }

    /// The straightening's four maps on disk (made by `PictureCorrection.remapMaps`) and the picture size they were made for: the clip's.
    typealias ClipCorrectionMaps = (xMap: String, yMap: String, chromaXMap: String, chromaYMap: String, width: Int, height: Int)

    /// Writes the four maps of `correction` for a `width × height` clip (`width` even) into `folder`.
    static func writeCorrectionMaps(_ correction: PictureCorrection, width: Int, height: Int, in folder: URL) throws -> ClipCorrectionMaps {
        let maps = correction.remapMaps(width: width, height: height)
        let paths = ["x", "y", "chroma-x", "chroma-y"].map { folder.appendingPathComponent("map-\($0).pgm").path }
        for (data, path) in zip([maps.x, maps.y, maps.chromaX, maps.chromaY], paths) { try data.write(to: URL(fileURLWithPath: path)) }
        return (xMap: paths[0], yMap: paths[1], chromaXMap: paths[2], chromaYMap: paths[3], width: width, height: height)
    }

    /// The ffmpeg arguments: read `input`, straighten it with `correction`'s maps (inputs 1 to 4, at the clip's size), draw one label per run
    /// in `style` (each only while its run is on screen; nil: no label), encode, fragmented MP4 to stdout. Without a correction the picture is
    /// scaled to at most 3840 wide in a plain `-vf` chain, as labelled clips always were.
    static func clipArguments(input: String, textFiles: [(LabelRun, String)], style: TimestampOverlaySettings?, font: String?,
                              correction: ClipCorrectionMaps?, vaapiDevice: String?) -> [String] {
        let label = style.map { labelFilters(textFiles: textFiles, style: $0, font: font) } ?? []
        // The pixel format the encoder takes: uploaded to the GPU for VA-API (x264 is also told by -pix_fmt).
        let encoderFormat = vaapiDevice == nil ? ["format=yuv420p"] : ["format=nv12", "hwupload"]
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin"] + (vaapiDevice.map { ["-vaapi_device", $0] } ?? []) + ["-i", input]
        if let correction {
            arguments += ["-i", correction.xMap, "-i", correction.yMap, "-i", correction.chromaXMap, "-i", correction.chromaYMap]
            let warp = PictureCorrection.ffmpegRemapChain(input: "0:v:0", width: correction.width, height: correction.height, xMap: "1:v", yMap: "2:v",
                                                          chromaXMap: "3:v", chromaYMap: "4:v", output: "cbw")
            arguments += ["-filter_complex", warp + ";[cbw]" + (label + encoderFormat).joined(separator: ",") + "[cbv]",
                          "-map", "[cbv]", "-map", "0:a:0?", "-sn", "-dn"]
        } else {
            let filters = ["scale='min(iw\\,\(MediaFit.maximumOutputWidth))':-2"] + label + (vaapiDevice == nil ? [] : encoderFormat)
            arguments += ["-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn", "-vf", filters.joined(separator: ",")]
        }
        if vaapiDevice != nil {
            arguments += ["-c:v", "h264_vaapi", "-rc_mode", "CQP", "-qp", "23"]
        } else {
            arguments += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p"]
        }
        // The recording's sound (AAC, when Record sound is on) is kept as it is.
        arguments += ["-c:a", "copy", "-movflags", "frag_keyframe+empty_moov+default_base_moof", "-f", "mp4", "pipe:1"]
        return arguments
    }

    /// One `drawtext` per run, each only while its run is on screen.
    private static func labelFilters(textFiles: [(LabelRun, String)], style: TimestampOverlaySettings, font: String?) -> [String] {
        let fraction = style.size.fontHeightFraction
        let margin = "(h*\(fraction)*0.9+h*\(fraction)*0.35)"
        let x = style.position.isLeft ? margin : "w-tw-\(margin)"
        let y = style.position.isTop ? margin : "h-th-\(margin)"
        let fontOption = font.map { "fontfile=\(FilterText.value($0)):" } ?? ""
        return textFiles.map { run, file -> String in
            let window = run.mediaEnd.map { "between(t\\,\(String(format: "%.3f", run.mediaStart))\\,\(String(format: "%.3f", $0)))" }
                ?? "gte(t\\,\(String(format: "%.3f", run.mediaStart)))"
            return "drawtext=\(fontOption)textfile=\(FilterText.value(file)):expansion=normal:fontsize=h*\(fraction):fontcolor=white:box=1:boxcolor=black@0.42"
                + ":boxborderw=6:shadowcolor=black@0.5:shadowx=1:shadowy=1:x=\(x):y=\(y):enable='\(window)'"
        }
    }

    /// How many saved clips are converted at once, box-wide (`ConversionSlots`): the clip bar starts a download for each camera ticked, and
    /// the live transcoders share the box's four cores with the conversions.
    static let maximumClipConversions = 2

    /// The priority a conversion runs at: `nice -n 10` on Linux (Camera Bridge OS), so the live video and Apple Home's recordings come
    /// first; as it is elsewhere (the Mac's tests).
    static let conversionNiceness: Int? = {
        #if os(Linux)
        10
        #else
        nil
        #endif
    }()

    /// `nice` where the system has it.
    static func nicePath() -> String? {
        ["/usr/bin/nice", "/bin/nice"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The program and arguments that run a conversion: `ffmpeg` itself, or under `nice -n <niceness>` (`nice` runs the program in its own
    /// process, so the child stopped by `runStreaming` is ffmpeg). Without a `nice` program the conversion runs as it is, rather than not.
    static func conversionCommand(ffmpeg: String, arguments: [String], niceness: Int? = WebApp.conversionNiceness,
                                  nice: String? = WebApp.nicePath()) -> (executable: String, arguments: [String]) {
        guard let niceness, let nice, FileManager.default.isExecutableFile(atPath: nice) else { return (ffmpeg, arguments) }
        return (nice, ["-n", String(niceness), ffmpeg] + arguments)
    }

    /// ffmpeg, as Camera Bridge OS installs it (or `CAMERABRIDGE_FFMPEG`, or the first on `PATH`).
    static func ffmpegPath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        var candidates = [environment["CAMERABRIDGE_FFMPEG"]].compactMap { $0 }
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/ffmpeg" }
        candidates += ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func labelFont() -> String? {
        ["/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/dejavu/DejaVuSans.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// The clip of `part` of `plan` re-encoded and streamed: with the bridge's label burned in (`labels`), straightened by `correction` (the
    /// camera's, when it is on and the person asked for it), or both. The archive slot is the caller's: `release` runs once the answer ended.
    func processedClip(plan: ClipPlan, part: Int, exporter: ClipExporter, cameraID: UUID, name: String, labels: Bool, correction: PictureCorrection?,
                       release: @escaping @Sendable () -> Void) async throws -> HTTPResponse {
        guard let ffmpeg = Self.ffmpegPath() else {
            release()
            throw APIError(status: 501, code: "unsupported", message: "This bridge has no video converter for \(labels ? "labelled" : "straightened") clips.")
        }
        let overview = await backend.overview()
        let configuration = overview.configurations.first { $0.id == cameraID }
        let zone = overview.settings.timeZone ?? TimeZone.current.identifier
        let style = labels ? (configuration?.timestampOverlay ?? TimestampOverlaySettings()) : nil
        let clipPart = plan.parts[part - 1]
        let runs = Self.labelRuns(part: clipPart, gaps: plan.gaps)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("camera-bridge-clip-\(UUID().uuidString.prefix(8))", isDirectory: true)
        var headers = HTTPHeaders()
        headers["Cache-Control"] = "no-store"
        headers["Content-Disposition"] = Self.attachment(clipPart.fileName)
        let vaapi = FileManager.default.fileExists(atPath: "/dev/dri/renderD128") ? "/dev/dri/renderD128" : nil
        let how = [correction == nil ? nil : "straightened", labels ? "with its label" : nil].compactMap { $0 }.joined(separator: ", ")
        log.notice("a clip of \(name) is being sent \(how)")
        return HTTPResponse.stream(contentType: "video/mp4", headers: headers) { stream in
            defer {
                release()
                try? FileManager.default.removeItem(at: folder)
            }
            do {
                // At most `maximumClipConversions` convert at once: the others wait here, with the answer's head sent and nothing written (the
                // browser shows the download as started), before they copy the clip or make any map. A browser that leaves ends the wait.
                try await self.archiveState.conversions.run {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let input = folder.appendingPathComponent("clip.mp4")
                    FileManager.default.createFile(atPath: input.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: input)
                    try await exporter.export(plan, part: part, to: FileClipSink(handle: handle)) { _ in }
                    try handle.close()
                    var files: [(LabelRun, String)] = []
                    if let style {
                        for (index, run) in runs.enumerated() {
                            let file = folder.appendingPathComponent("label-\(index).txt")
                            try Data(Self.labelText(name: name, style: style, wallBase: run.wallBase).utf8).write(to: file)
                            files.append((run, file.path))
                        }
                    }
                    var maps: ClipCorrectionMaps?
                    if let correction {
                        let recorded = try await exporter.pictureSize(plan, part: part)
                        let size = MediaFit.cappedEvenSize(width: recorded.width, height: recorded.height)
                        // Some 13 million map pixels for a 3840-wide clip: on a thread of their own, not the cooperative pool the live video runs on.
                        maps = try await Self.offThePool { try Self.writeCorrectionMaps(correction, width: size.width, height: size.height, in: folder) }
                    }
                    let arguments = Self.clipArguments(input: input.path, textFiles: files, style: style, font: style == nil ? nil : Self.labelFont(),
                                                       correction: maps, vaapiDevice: vaapi)
                    let command = Self.conversionCommand(ffmpeg: ffmpeg, arguments: arguments)
                    try await Self.runStreaming(executable: command.executable, arguments: command.arguments, timeZone: zone, into: stream)
                }
            } catch where Task.isCancelled || error is ClipDownloadStopped {
                self.log.notice("a clip download was stopped")
            } catch {
                self.log.warning("sending a converted clip failed: \(Redact.string(String(describing: error)))")
            }
        }
    }

    /// `work` on a thread of its own (it would hold a thread of Swift's small cooperative pool for its whole run).
    private static func offThePool<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Runs `executable` in `timeZone` (its `TZ`) and writes its standard output to `stream` as it comes. When the browser goes away (the task
    /// is cancelled, or a write fails) the child is stopped: SIGTERM, then SIGKILL once `stopGrace` has passed, and whatever it still writes
    /// meanwhile is read and thrown away, so it never blocks on a full pipe. Returns, or throws (`ClipDownloadStopped` for a download that was
    /// stopped), only once the child has exited and its output has ended: the caller's temporary files are no longer open.
    static func runStreaming(executable: String, arguments: [String], timeZone: String, into stream: ResponseStream,
                             stopGrace: TimeInterval = 5) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // ffmpeg draws the label's time in its own local time: the bridge's zone, given explicitly (the daemon's own TZ is set with setenv, which
        // a child's environment built from ProcessInfo does not see).
        var environment = ProcessInfo.processInfo.environment
        environment["TZ"] = timeZone
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // The exit is awaited, not waited for: `waitUntilExit()` runs the current thread's run loop, which on a thread of Swift's cooperative
        // pool can sleep for good (seen on macOS in the tests, the child long gone), and it holds that thread meanwhile.
        let child = ConversionChild()
        process.terminationHandler = { finished in child.exited(finished.terminationStatus) }
        try process.run()
        // The child owns the pipe's write end now; ours, kept open, would stop end-of-file from ever arriving.
        try? output.fileHandleForWriting.close()
        let reader = output.fileHandleForReading
        // Back-pressure: the reader takes a slot before it hands a chunk on and the writer gives it back once the chunk is sent, so ffmpeg waits
        // for a slow network instead of anything being dropped (a dropped chunk breaks the MP4). Once stopped, the reader drains instead.
        let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let slots = DispatchSemaphore(value: 16)
        let pid = process.processIdentifier
        let stop: @Sendable () -> Void = {
            guard child.stop() else { return }
            slots.signal()   // a reader waiting for a slot wakes, sees the stop and drains from then on
            guard !child.hasExited else { return }
            process.terminate()
            // ffmpeg ends on SIGTERM once it has flushed its last fragment; one that is still there after the grace is killed.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + stopGrace) {
                if !child.hasExited, pid > 0 { kill(pid, SIGKILL) }
            }
        }
        let readQueue = DispatchQueue(label: "camera-bridge.clip-label-reader")
        readQueue.async {
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                if child.isStopped { continue }   // nobody sends it any more: read on so the child is never blocked
                slots.wait()
                if child.isStopped {
                    slots.signal()
                    continue
                }
                child.lend()
                continuation.yield(data)
            }
            continuation.finish()
            child.outputEnded()
        }
        var failure: (any Error)?
        do {
            try await withTaskCancellationHandler {
                for await chunk in chunks {
                    defer {
                        child.giveBack()
                        slots.signal()
                    }
                    do { try await stream.write(chunk) } catch { throw ClipDownloadStopped() }
                }
            } onCancel: {
                stop()
            }
        } catch {
            failure = error
            stop()
        }
        await child.ended()
        // The slots of chunks read but never sent come back (a semaphore freed below its starting value is a crash in libdispatch).
        for _ in 0..<child.lent { slots.signal() }
        if let failure { throw failure }
        if Task.isCancelled { throw ClipDownloadStopped() }
        guard child.status == 0 else { throw APIError(status: 502, code: "unreadable", message: "The clip couldn’t be converted.") }
    }
}

/// The browser stopped a converted clip's download (it went away, or stopped reading).
struct ClipDownloadStopped: Error {}

/// One conversion's child as `runStreaming` follows it: stopped or not, its exit status, the end of its output, the one caller waiting
/// for both, and how many of the reader's slots are lent to chunks not yet sent.
private final class ConversionChild: Sendable {
    private struct State {
        var stopped = false
        var status: Int32?
        var outputEnded = false
        var lent = 0
        var waiter: CheckedContinuation<Void, Never>?
        var isOver: Bool { status != nil && outputEnded }
    }

    private let state = Mutex(State())

    var isStopped: Bool { state.withLock { $0.stopped } }
    var hasExited: Bool { state.withLock { $0.status != nil } }
    var status: Int32? { state.withLock { $0.status } }
    var lent: Int { state.withLock { $0.lent } }

    func lend() { state.withLock { $0.lent += 1 } }
    func giveBack() { state.withLock { $0.lent -= 1 } }

    /// Marks it stopped; true the first time only.
    func stop() -> Bool {
        state.withLock { state in
            defer { state.stopped = true }
            return !state.stopped
        }
    }

    func exited(_ status: Int32) { change { $0.status = status } }
    func outputEnded() { change { $0.outputEnded = true } }

    /// Returns once the child has exited and its output has ended. Not cancellable: the caller cleans up after the child.
    func ended() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let over = state.withLock { state -> Bool in
                if !state.isOver { state.waiter = continuation }
                return state.isOver
            }
            if over { continuation.resume() }
        }
    }

    private func change(_ update: (inout State) -> Void) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            update(&state)
            guard state.isOver else { return nil }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}

/// drawtext option values: a path or text in single quotes (a quote inside becomes `'\''`).
enum FilterText {
    static func value(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Where the clip writer's bytes go before ffmpeg re-encodes them: a temporary file.
private struct FileClipSink: ClipSink {
    let handle: FileHandle

    func write(_ bytes: Data) async throws { try handle.write(contentsOf: bytes) }
}
