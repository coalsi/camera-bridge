import BridgeEngine
import BridgeSupport
import Foundation
import MediaCore

// A saved clip with the bridge's label burned in (`GET /nvr/cameras/:id/clip?…&labels=1`): the camera's name and the date and time of every
// picture, in the camera's label style (`CameraConfiguration.timestampOverlay`: corner, size, name, date, seconds, 24-hour), the same words the
// bridge draws on Apple Home's video and the page draws on the Monitor. The clip is written as usual (`ClipExporter`) to a temporary file, then
// ffmpeg re-encodes it with `drawtext` and the result is streamed as fragmented MP4 while it is made (the size is not known in advance).
//
// The time of a picture is exact across the clip: within a run of recording the picture at media time t was taken at run start + t; a gap the
// clip skips (`ClipGap.held == false`) starts a new run whose wall time jumps by the gap. ffmpeg's `%{pts:localtime:offset:format}` draws it in
// the bridge's time zone (`BridgeSettings.timeZone`, ffmpeg's `TZ`). Encoding is on the GPU (VA-API) where there is one, scaled to at most 3840 pixels wide
// (the H.264 encoder's limit is 4096), else x264.
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

    /// The ffmpeg arguments: read `input`, draw one label per run (each only while its run is on screen), encode, fragmented MP4 to stdout.
    static func labelArguments(input: String, textFiles: [(LabelRun, String)], style: TimestampOverlaySettings, font: String?, vaapiDevice: String?) -> [String] {
        let fraction = style.size.fontHeightFraction
        let margin = "(h*\(fraction)*0.9+h*\(fraction)*0.35)"
        let x = style.position.isLeft ? margin : "w-tw-\(margin)"
        let y = style.position.isTop ? margin : "h-th-\(margin)"
        let fontOption = font.map { "fontfile=\(FilterText.value($0)):" } ?? ""
        let draws = textFiles.map { run, file -> String in
            let window = run.mediaEnd.map { "between(t\\,\(String(format: "%.3f", run.mediaStart))\\,\(String(format: "%.3f", $0)))" }
                ?? "gte(t\\,\(String(format: "%.3f", run.mediaStart)))"
            return "drawtext=\(fontOption)textfile=\(FilterText.value(file)):expansion=normal:fontsize=h*\(fraction):fontcolor=white:box=1:boxcolor=black@0.42"
                + ":boxborderw=6:shadowcolor=black@0.5:shadowx=1:shadowy=1:x=\(x):y=\(y):enable='\(window)'"
        }
        var filters = ["scale='min(iw\\,3840)':-2"] + draws
        // The recording's sound (AAC, when Record sound is on) is kept as it is.
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", input, "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn"]
        if let vaapiDevice {
            filters += ["format=nv12", "hwupload"]
            arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-vaapi_device", vaapiDevice] + Array(arguments.dropFirst(4))
            arguments += ["-vf", filters.joined(separator: ","), "-c:v", "h264_vaapi", "-rc_mode", "CQP", "-qp", "23"]
        } else {
            arguments += ["-vf", filters.joined(separator: ","), "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p"]
        }
        arguments += ["-c:a", "copy", "-movflags", "frag_keyframe+empty_moov+default_base_moof", "-f", "mp4", "pipe:1"]
        return arguments
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

    /// The labelled clip of `part` of `plan`, streamed. The archive slot is the caller's: `release` runs once the answer ended.
    func labelledClip(plan: ClipPlan, part: Int, exporter: ClipExporter, cameraID: UUID, name: String, release: @escaping @Sendable () -> Void) async throws -> HTTPResponse {
        guard let ffmpeg = Self.ffmpegPath() else {
            release()
            throw APIError(status: 501, code: "unsupported", message: "This bridge has no video converter for labelled clips.")
        }
        let overview = await backend.overview()
        let configuration = overview.configurations.first { $0.id == cameraID }
        let zone = overview.settings.timeZone ?? TimeZone.current.identifier
        let style = configuration?.timestampOverlay ?? TimestampOverlaySettings()
        let clipPart = plan.parts[part - 1]
        let runs = Self.labelRuns(part: clipPart, gaps: plan.gaps)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("camera-bridge-clip-\(UUID().uuidString.prefix(8))", isDirectory: true)
        var headers = HTTPHeaders()
        headers["Cache-Control"] = "no-store"
        headers["Content-Disposition"] = Self.attachment(clipPart.fileName)
        let vaapi = FileManager.default.fileExists(atPath: "/dev/dri/renderD128") ? "/dev/dri/renderD128" : nil
        log.notice("a clip of \(name) is being sent with its label")
        return HTTPResponse.stream(contentType: "video/mp4", headers: headers) { stream in
            defer {
                release()
                try? FileManager.default.removeItem(at: folder)
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let input = folder.appendingPathComponent("clip.mp4")
                FileManager.default.createFile(atPath: input.path, contents: nil)
                let handle = try FileHandle(forWritingTo: input)
                try await exporter.export(plan, part: part, to: FileClipSink(handle: handle)) { _ in }
                try handle.close()
                var files: [(LabelRun, String)] = []
                for (index, run) in runs.enumerated() {
                    let file = folder.appendingPathComponent("label-\(index).txt")
                    try Data(Self.labelText(name: name, style: style, wallBase: run.wallBase).utf8).write(to: file)
                    files.append((run, file.path))
                }
                let arguments = Self.labelArguments(input: input.path, textFiles: files, style: style, font: Self.labelFont(), vaapiDevice: vaapi)
                try await Self.runStreaming(executable: ffmpeg, arguments: arguments, timeZone: zone, into: stream)
            } catch {
                self.log.warning("sending a labelled clip failed: \(Redact.string(String(describing: error)))")
            }
        }
    }

    /// Runs `executable` in `timeZone` (its `TZ`) and writes its standard output to `stream` as it comes; ends it when the browser goes away.
    static func runStreaming(executable: String, arguments: [String], timeZone: String, into stream: ResponseStream) async throws {
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
        try process.run()
        let reader = output.fileHandleForReading
        // Back-pressure: the reader takes a slot before it hands a chunk on and the writer gives it back once the chunk is sent, so ffmpeg waits
        // for a slow network instead of anything being dropped (a dropped chunk breaks the MP4).
        let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let slots = DispatchSemaphore(value: 16)
        let readQueue = DispatchQueue(label: "camera-bridge.clip-label-reader")
        readQueue.async {
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                slots.wait()
                continuation.yield(data)
            }
            continuation.finish()
        }
        do {
            try await withTaskCancellationHandler {
                for await chunk in chunks {
                    defer { slots.signal() }
                    try await stream.write(chunk)
                }
            } onCancel: {
                process.terminate()
                for _ in 0..<16 { slots.signal() }
            }
        } catch {
            process.terminate()
            for _ in 0..<16 { slots.signal() }   // a reader waiting for a slot ends too
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw APIError(status: 502, code: "unreadable", message: "The clip couldn’t be converted.") }
    }
}

/// drawtext option values: a path or text in single quotes (a quote inside becomes `'\''`).
enum FilterText {
    static func value(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Where the clip writer's bytes go before the label is burned in: a temporary file.
private struct FileClipSink: ClipSink {
    let handle: FileHandle

    func write(_ bytes: Data) async throws { try handle.write(contentsOf: bytes) }
}
