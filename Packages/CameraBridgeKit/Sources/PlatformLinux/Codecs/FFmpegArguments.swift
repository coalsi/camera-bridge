import Foundation
import MediaCore

/// Which H.264 encoder a pipeline uses.
public enum FFmpegVideoBackend: Sendable, Equatable {
    /// libx264, `-preset <preset> -tune zerolatency`.
    case software(preset: String)
    /// `h264_vaapi` on a render node (Intel and AMD GPUs). `lowPower`: the GPU's fixed-function encoder (`-low_power 1`, VDEnc), which
    /// recent Intel chips (Alder Lake-N and newer) offer for H.264 instead of the shader-based one.
    case vaapi(device: String, lowPower: Bool)

    var isHardware: Bool {
        if case .vaapi = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .software(let preset): "libx264 (\(preset))"
        case .vaapi(let device, let lowPower): "h264_vaapi (\(device)\(lowPower ? ", low power" : ""))"
        }
    }
}

/// The timestamp overlay as ffmpeg's `drawtext` filter draws it: everything that is part of the filter graph (a change restarts
/// the pipeline), the words themselves are in a text file that `reload=1` re-reads for every picture.
struct DrawTextOverlay: Equatable, Sendable {
    var fontFile: String
    var textFile: String
    var position: OverlayPosition
    var size: OverlaySize
}

/// Everything the video pipeline's ffmpeg command line depends on. Pure value: `FFmpegArguments` turns it into arguments.
struct VideoPipelineSpec: Equatable, Sendable {
    var settings: VideoEncoderSettings
    var bitrateKbps: Int
    var backend: FFmpegVideoBackend
    /// The decoded picture's size, when it differs the picture is scaled to fit `settings.width × settings.height` with bars.
    var sourceWidth: Int
    var sourceHeight: Int
    var overlay: DrawTextOverlay?
    /// Limit the output to `settings.fps` (the same rule as `FrameRateLimiter`: pictures ahead of schedule are skipped).
    var limitFrameRate = true
    /// Catch-up: skip every picture presented before this time (seconds on the pipeline's millisecond clock).
    var skipBeforeSeconds: Double?
    /// Honour the odd-millisecond keyframe request in this pipeline (the transcoder's way to force an IDR).
    var keyframeRequestsByTimestamp = true
    /// Straighten the picture with these maps (the transcoder only; nil: the picture as the camera sent it).
    var correction: RemapStage?
}

enum FFmpegArguments {
    /// What every invocation starts with: no banner, no progress, no terminal reading, errors only on stderr (kept for error messages).
    static let common = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error"]

    /// Input options that keep the decoder from holding pictures back and probing short. (`-fflags +nobuffer` would drop the packets read while probing.)
    static let lowLatencyInput = ["-flags", "+low_delay", "-analyzeduration", "1", "-probesize", "2048"]

    // MARK: Video

    /// compressed H.264/HEVC in (FLV on stdin) → H.264 out (FLV on stdout): decode, limit rate, scale, straighten, overlay, encode.
    /// With a correction the four maps are more inputs (images, read once: `remap` keeps the last picture of each for the whole
    /// stream) and the filters are a graph (`correctedFilterGraph`) whose output pad `cbv` is the one mapped.
    static func transcoder(_ spec: VideoPipelineSpec) -> [String] {
        var arguments = common
        if case .vaapi(let device, _) = spec.backend { arguments += ["-vaapi_device", device] }
        // -copyts: ffmpeg would otherwise subtract the stream's first timestamp (decided while probing, so it varies); the
        // transcoder maps output timestamps back by their exact millisecond value and needs them unchanged.
        arguments += ["-copyts"]
        arguments += lowLatencyInput
        if let correction = spec.correction {
            arguments += ["-f", "flv", "-i", "pipe:0"] + remapInputs(correction)
            arguments += ["-filter_complex", correctedFilterGraph(spec, correction), "-map", "[cbv]", "-an", "-sn", "-dn"]
        } else {
            arguments += ["-f", "flv", "-i", "pipe:0", "-map", "0:v:0", "-an", "-sn", "-dn"]
            arguments += ["-vf", videoFilters(spec)]
        }
        arguments += ["-fps_mode", "passthrough", "-enc_time_base", "1/1000"]
        if spec.keyframeRequestsByTimestamp { arguments += ["-force_key_frames", "expr:\(keyframeRequestExpression)"] }
        arguments += encoderOptions(spec)
        arguments += ["-f", "flv", "-flush_packets", "1", "pipe:1"]
        return arguments
    }

    /// raw yuv420p pictures in → H.264 out (FLV on stdout).
    static func rawEncoder(_ spec: VideoPipelineSpec, inputWidth: Int, inputHeight: Int) -> [String] {
        var arguments = common
        if case .vaapi(let device, _) = spec.backend { arguments += ["-vaapi_device", device] }
        arguments += ["-f", "rawvideo", "-pix_fmt", "yuv420p", "-video_size", "\(inputWidth)x\(inputHeight)",
                      "-framerate", "\(max(1, spec.settings.inputFrameRate))", "-i", "pipe:0", "-an"]
        var filtered = spec
        filtered.limitFrameRate = false
        filtered.skipBeforeSeconds = nil
        filtered.correction = nil
        arguments += ["-vf", videoFilters(filtered)]
        arguments += encoderOptions(spec)
        arguments += ["-f", "flv", "-flush_packets", "1", "pipe:1"]
        return arguments
    }

    /// compressed video in (FLV on stdin) → raw yuv420p pictures at `width × height` out (Y4M: `rawvideo` holds a picture back).
    /// With `hardwareDevice` (a VA-API render node) the GPU decodes and scales and ffmpeg copies the scaled pictures back. Only for
    /// streams the GPU's decoder takes (`FFmpegVideoDecoder.fitsHardware`): the pictures must stay on the GPU for `scale_vaapi`, so there is
    /// no CPU fallback inside the command (a session that fails is replaced by a software one, without a device, by `FFmpegVideoDecoder`).
    ///
    /// With `keepEvery` N above 1 only every Nth picture comes out (`select='not(mod(n\,N))'`: pictures 0, N, 2N, … from the first the
    /// child is given): on the GPU after the scaling and before `hwdownload`, so a dropped picture is never copied back; on the CPU before the
    /// scaling, so it is never scaled either. `highQualityScaling` asks for a good downscale filter (the GPU's `mode=hq` scaler, `flags=area`
    /// on the CPU): the sky detector looks at single-pixel speckle, which looks different under every filter.
    static func decoder(width: Int, height: Int, hardwareDevice: String? = nil, keepEvery: Int = 1, highQualityScaling: Bool = false) -> [String] {
        // On the GPU the pictures stay there for the scaling (`scale_vaapi`), and only the scaled picture is copied back: copying a 4K
        // picture back and scaling it on the CPU cost as much as the decoding saved (2026-10-16).
        let hardware = hardwareDevice.map { ["-hwaccel", "vaapi", "-hwaccel_device", $0, "-hwaccel_output_format", "vaapi"] } ?? []
        let select = keepEvery > 1 ? "select='not(mod(n\\,\(keepEvery)))'" : nil
        let filters: String
        if hardwareDevice == nil {
            let scale = "scale=\(width):\(height)" + (highQualityScaling ? ":flags=area" : "")
            filters = [select, scale, "format=yuv420p"].compactMap { $0 }.joined(separator: ",")
        } else {
            let scale = "scale_vaapi=w=\(width):h=\(height):format=nv12" + (highQualityScaling ? ":mode=hq" : "")
            filters = [scale, select, "hwdownload", "format=nv12", "format=yuv420p"].compactMap { $0 }.joined(separator: ",")
        }
        return common + hardware + lowLatencyInput + ["-f", "flv", "-i", "pipe:0", "-map", "0:v:0", "-an", "-sn", "-dn",
                                    "-vf", filters, "-fps_mode", "passthrough",
                                    "-f", "yuv4mpegpipe", "-pix_fmt", "yuv420p", "pipe:1"]
    }

    /// The `-force_key_frames` expression: an odd millisecond timestamp asks for an IDR. `FFmpegVideoTranscoder` gives every
    /// ordinary picture an even timestamp and the picture a keyframe was requested for an odd one.
    static let keyframeRequestExpression = "mod(round(t*1000),2)"

    /// The filter chain of a pipeline without a correction (`spec.correction` is not looked at).
    static func videoFilters(_ spec: VideoPipelineSpec) -> String {
        var filters: [String] = []
        if let select = selectFilter(spec) { filters.append(select) }
        let width = spec.settings.width, height = spec.settings.height
        if spec.sourceWidth != width || spec.sourceHeight != height {
            filters.append("scale=\(width):\(height):force_original_aspect_ratio=decrease:flags=bicubic")
            filters.append("pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2")
            filters.append("setsar=1")
        }
        filters += labelAndFormat(spec)
        return filters.joined(separator: ",")
    }

    /// The filter graph of a pipeline that straightens the picture: the frame-rate limit first (on the camera's picture, as
    /// without the correction), then the warp at `correction`'s size (the picture fitted inside the output: a letterboxed picture
    /// is straightened before its bars are added, so the bars stay plain and the horizon lands on the picture's line, not the
    /// frame's), then the bars, the label (drawn upright on the straightened picture) and the encoder's pixel format, on pad `cbv`.
    /// The maps are inputs 1 to 4 (luma x, luma y, chroma x, chroma y).
    static func correctedFilterGraph(_ spec: VideoPipelineSpec, _ correction: RemapStage) -> String {
        var graph = ""
        var input = "0:v:0"
        if let select = selectFilter(spec) {
            graph += "[0:v:0]\(select)[cbsel];"
            input = "cbsel"
        }
        graph += remapChain(correction, input: input, output: "cbw")
        let width = spec.settings.width, height = spec.settings.height
        var filters: [String] = []
        if correction.width != width || correction.height != height { filters.append("pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2") }
        // Square pixels whenever the picture was scaled, as without the correction.
        if spec.sourceWidth != width || spec.sourceHeight != height { filters.append("setsar=1") }
        filters += labelAndFormat(spec)
        return graph + ";[cbw]" + filters.joined(separator: ",") + "[cbv]"
    }

    /// The correction's four maps as more inputs (1 to 4 after the picture, in the order `remapChain` reads them).
    static func remapInputs(_ correction: RemapStage) -> [String] {
        ["-i", correction.xMap, "-i", correction.yMap, "-i", correction.chromaXMap, "-i", correction.chromaYMap]
    }

    /// The per-plane warp of pad `input` at `correction`'s size with the maps of inputs 1 to 4 (`remapInputs`), onto pad `output`.
    static func remapChain(_ correction: RemapStage, input: String, output: String) -> String {
        PictureCorrection.ffmpegRemapChain(input: input, width: correction.width, height: correction.height, xMap: "1:v", yMap: "2:v",
                                           chromaXMap: "3:v", chromaYMap: "4:v", output: output)
    }

    /// The end of every chain: the timestamp label, then the pixel format the encoder takes (on the GPU for VA-API).
    private static func labelAndFormat(_ spec: VideoPipelineSpec) -> [String] {
        var filters: [String] = []
        if let overlay = spec.overlay { filters.append(drawText(overlay, outputHeight: spec.settings.height)) }
        switch spec.backend {
        case .software: filters.append("format=yuv420p")
        case .vaapi: filters += ["format=nv12", "hwupload"]
        }
        return filters
    }

    /// The size a `sourceWidth × sourceHeight` picture is scaled to inside `width × height` with its shape kept: the size ffmpeg's
    /// `force_original_aspect_ratio=decrease` gives (each side rounded to the nearest pixel, as `av_rescale` does), made even
    /// (4:2:0) and at least 2 × 2.
    static func fittedSize(sourceWidth: Int, sourceHeight: Int, width: Int, height: Int) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (max(2, width & ~1), max(2, height & ~1)) }
        let keptWidth = (height * sourceWidth + sourceHeight / 2) / sourceHeight
        let keptHeight = (width * sourceHeight + sourceWidth / 2) / sourceWidth
        return (max(2, min(width, keptWidth) & ~1), max(2, min(height, keptHeight) & ~1))
    }

    /// The frame-rate limiter as a `select` expression (`FrameRateLimiter`'s rule, with state in the expression's variable 1:
    /// the next due time): a picture is kept once its time reaches the due time less a quarter interval, the due time then advances
    /// by one interval (restarting at the picture when it is far off the schedule), and a keyframe request is never skipped.
    static func selectFilter(_ spec: VideoPipelineSpec) -> String? {
        var body: String?
        if spec.limitFrameRate {
            let interval = 1.0 / Double(max(1, spec.settings.fps))
            let i = number(interval)
            var keep = "gte(t,ld(1)-\(i)/4)+lt(t,ld(1)-\(i)-1)"
            if spec.keyframeRequestsByTimestamp { keep += "+\(keyframeRequestExpression)" }
            body = "if(gt(\(keep),0),st(1,if(gt(between(t,ld(1)-\(i),ld(1)+\(i))*gt(ld(1),0),0),ld(1)+\(i),t+\(i)))*0+1,0)"
        }
        if let skip = spec.skipBeforeSeconds {
            body = "if(gte(t,\(number(skip))),\(body ?? "1"),0)"
        }
        return body.map { "select='\($0)'" }
    }

    static func drawText(_ overlay: DrawTextOverlay, outputHeight: Int) -> String {
        let fontSize = max(10, Int((Double(outputHeight) * overlay.size.fontHeightFraction).rounded()))
        let border = max(3, Int((Double(fontSize) * 0.35).rounded()))
        let margin = max(6, Int((Double(fontSize) * 0.9).rounded()))
        let x = overlay.position.isLeft ? "\(margin + border)" : "w-tw-\(margin + border)"
        let y = overlay.position.isTop ? "\(margin + border)" : "h-th-\(margin + border)"
        return "drawtext=fontfile=\(optionValue(overlay.fontFile)):textfile=\(optionValue(overlay.textFile)):reload=1:expansion=none:fontsize=\(fontSize)"
            + ":fontcolor=white:box=1:boxcolor=black@0.42:boxborderw=\(border):shadowcolor=black@0.5:shadowx=1:shadowy=1:x=\(x):y=\(y)"
    }

    /// A string as a filter option value: as it is when it holds only letters, digits and `/ . _ - + @`, otherwise in single quotes
    /// (the filter graph parser takes everything in them literally; a quote inside becomes `'\''`).
    static func optionValue(_ text: String) -> String {
        let plain = !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "/._-+@".unicodeScalars.contains($0) }
        return plain ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether a path can be given to a filter at all (no line breaks or NULs).
    static func isUsablePath(_ path: String) -> Bool {
        !path.isEmpty && !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    static func encoderOptions(_ spec: VideoPipelineSpec) -> [String] {
        let settings = spec.settings
        let frameRate = max(1, settings.inputFrameRate)
        let keyframeSeconds = max(settings.keyframeInterval / .seconds(1), 1.0 / Double(max(1, settings.fps)))
        let gop = max(1, Int((keyframeSeconds * Double(frameRate)).rounded()))
        let bitrate = max(1, spec.bitrateKbps)
        let maxrate = bitrate * 3 / 2
        let level = h264Level(settings)
        var options: [String] = []
        switch spec.backend {
        case .software(let preset):
            options += ["-c:v", "libx264", "-preset", preset, "-tune", "zerolatency", "-profile:v", profileName(settings.profile, hardware: false)]
            if let level { options += ["-level:v", level] }
            options += ["-x264-params", "scenecut=0:keyint=\(gop):min-keyint=\(max(1, min(gop, frameRate)))"]
        case .vaapi(_, let lowPower):
            options += ["-c:v", "h264_vaapi", "-profile:v", profileName(settings.profile, hardware: true)]
            if let idc = levelIDC(settings) { options += ["-level:v", "\(idc)"] }
            options += ["-async_depth", "1", "-g", "\(gop)", "-bf", "0"]
            if lowPower { options += ["-low_power", "1"] }
        }
        options += ["-b:v", "\(bitrate)k", "-maxrate", "\(maxrate)k", "-bufsize", "\(maxrate)k"]
        if case .software = spec.backend { options += ["-g", "\(gop)", "-bf", "0"] }
        return options
    }

    static func profileName(_ profile: VideoEncoderSettings.EncoderProfile, hardware: Bool) -> String {
        switch profile {
        case .baseline: hardware ? "constrained_baseline" : "baseline"
        case .main: "main"
        case .high: "high"
        }
    }

    /// The lowest level at or above the requested one that fits the picture and frame rate (`H264LevelLimits`); nil: let the encoder choose.
    static func levelIDC(_ settings: VideoEncoderSettings) -> Int? {
        let minimum: Int? = switch settings.level {
        case .level3_1: 31
        case .level3_2: 32
        case .level4_0: 40
        case .level4_1: 41
        case .level5_1: 51
        case .auto: nil
        }
        guard let minimum else { return nil }
        return H264LevelLimits.lowestLevel(width: settings.width, height: settings.height, fps: Double(max(1, settings.fps)), atLeast: minimum)
    }

    static func h264Level(_ settings: VideoEncoderSettings) -> String? {
        levelIDC(settings).map { idc in idc == 9 ? "1b" : "\(idc / 10).\(idc % 10)" }
    }

    /// A decimal without exponent or locale, for ffmpeg expressions.
    static func number(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0"), text.contains(".") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "0" : text
    }

    // MARK: Audio

    /// What ffmpeg reads on stdin for audio of this codec.
    enum AudioWire: Equatable, Sendable {
        case flv       // AAC / AAC-ELD access units behind a sequence header
        case ogg       // Opus packets
        case raw(String)   // headerless samples: the ffmpeg format name (`mulaw`, `alaw`, `s16le`)
    }

    static func audioInputWire(_ codec: AudioCodec) -> AudioWire {
        switch codec {
        case .aac, .aacELD: .flv
        case .opus: .ogg
        case .pcmu: .raw("mulaw")
        case .pcma: .raw("alaw")
        case .linearPCM: .raw("s16le")
        }
    }

    static func audioOutputWire(_ codec: AudioCodec) -> AudioWire { audioInputWire(codec) }

    /// ffmpeg encoder options for an audio output codec; nil when ffmpeg cannot produce it (`available` lists its encoders).
    static func audioEncoderOptions(_ output: AudioEncoderSettings, available: Set<String>) -> [String]? {
        let bitrate = output.bitrate ?? defaultAudioBitrate(output)
        switch output.codec {
        case .aac:
            // libfdk_aac (non-free) is better when present; ffmpeg's own AAC-LC encoder is the baseline.
            if available.contains("aac") { return ["-c:a", "aac", "-b:a", "\(bitrate)"] }
            if available.contains("libfdk_aac") { return ["-c:a", "libfdk_aac", "-b:a", "\(bitrate)"] }
            return nil
        case .aacELD:
            // Only libfdk_aac encodes AAC-ELD, and it is not in Debian's ffmpeg (non-free licence).
            guard available.contains("libfdk_aac") else { return nil }
            return ["-c:a", "libfdk_aac", "-profile:a", "aac_eld", "-b:a", "\(bitrate)"]
        case .opus:
            guard available.contains("libopus") else { return nil }
            return ["-c:a", "libopus", "-b:a", "\(bitrate)", "-application", "voip", "-frame_duration", "20", "-vbr", "on"]
        case .pcmu: return ["-c:a", "pcm_mulaw"]
        case .pcma: return ["-c:a", "pcm_alaw"]
        case .linearPCM: return ["-c:a", "pcm_s16le"]
        }
    }

    static func defaultAudioBitrate(_ output: AudioEncoderSettings) -> Int {
        let perChannel = switch output.codec {
        case .opus: output.sampleRate <= 16_000 ? 24_000 : 32_000
        default: output.sampleRate <= 16_000 ? 32_000 : output.sampleRate <= 24_000 ? 48_000 : 64_000
        }
        return perChannel * max(1, output.channels)
    }

    /// Audio in on stdin (framed per `audioInputWire`) → audio out on stdout (framed per `audioOutputWire`).
    static func audioTranscoder(input: AudioFormat, output: AudioEncoderSettings, encoder: [String], decoder: [String] = []) -> [String] {
        var arguments = common
        arguments += lowLatencyInput
        arguments += decoder
        switch audioInputWire(input.codec) {
        case .flv: arguments += ["-f", "flv"]
        case .ogg: arguments += ["-f", "ogg"]
        case .raw(let format): arguments += ["-f", format, "-ar", "\(input.sampleRate)", "-ac", "\(input.channels)"]
        }
        arguments += ["-i", "pipe:0", "-vn", "-sn", "-dn", "-map", "0:a:0"]
        arguments += ["-ar", "\(output.sampleRate)", "-ac", "\(output.channels)"]
        arguments += encoder
        switch audioOutputWire(output.codec) {
        case .flv: arguments += ["-f", "flv"]
        case .ogg: arguments += ["-f", "ogg", "-page_duration", "20000"]
        case .raw(let format): arguments += ["-f", format]
        }
        arguments += ["-flush_packets", "1", "pipe:1"]
        return arguments
    }

    // MARK: Pictures

    /// One raw yuv420p picture in → one JPEG out, scaled to `width × height`.
    static func jpeg(inputWidth: Int, inputHeight: Int, width: Int, height: Int, quality: Double) -> [String] {
        let q = mjpegScale(quality)
        var filters = ""
        if width != inputWidth || height != inputHeight { filters = "scale=\(width):\(height):flags=lanczos," }
        filters += "scale=out_range=pc,format=yuvj420p"
        return common + ["-f", "rawvideo", "-pix_fmt", "yuv420p", "-video_size", "\(inputWidth)x\(inputHeight)", "-i", "pipe:0",
                         "-vf", filters, "-frames:v", "1", "-c:v", "mjpeg", "-q:v", "\(q)", "-f", "mjpeg", "pipe:1"]
    }

    /// A JPEG or PNG in → a JPEG out, scaled to `width × height`, at `quality` (0…1; nil: `-q:v 5`).
    static func resizeImage(width: Int, height: Int, quality: Double? = nil) -> [String] {
        common + ["-f", "image2pipe", "-i", "pipe:0", "-vf", "scale=\(width):\(height):flags=lanczos,scale=out_range=pc,format=yuvj420p",
                  "-frames:v", "1", "-c:v", "mjpeg", "-q:v", "\(quality.map(mjpegScale) ?? 5)", "-f", "mjpeg", "pipe:1"]
    }

    /// One dark picture of `width × height` as a JPEG on stdout: a camera (body and lens) from boxes, and with a `font` the words of the
    /// camera-off still. The texts are quoted filter values read literally (`expansion=none`), so a camera name cannot change the graph.
    static func cameraOff(width: Int, height: Int, name: String, font: String?) -> [String] {
        let unit = Double(min(width, height * 16 / 9))
        func px(_ fraction: Double) -> Int { max(2, Int((unit * fraction).rounded())) }
        let iconWidth = px(0.16), iconHeight = Int(Double(iconWidth) * 0.7), lens = max(4, iconHeight / 2)
        let x = (width - iconWidth) / 2, y = Int(Double(height) * 0.30), thick = max(2, px(0.008))
        var filters = ["drawbox=x=\(x):y=\(y):w=\(iconWidth):h=\(iconHeight):color=0x9e9eab:t=\(thick)",
                       "drawbox=x=\((width - lens) / 2):y=\(y + (iconHeight - lens) / 2):w=\(lens):h=\(lens):color=0x9e9eab:t=\(thick)"]
        if let font, isUsablePath(font) {
            func text(_ line: String, size: Double, color: String, at fraction: Double) -> String {
                "drawtext=fontfile=\(optionValue(font)):text=\(optionValue(String(line.prefix(80)).replacingOccurrences(of: "\n", with: " "))):expansion=none"
                    + ":fontsize=\(px(size)):fontcolor=\(color):x=(w-tw)/2:y=h*\(fraction)"
            }
            filters += [text("Camera off", size: 0.052, color: "white", at: 0.50), text("Turn it on in Camera Bridge", size: 0.028, color: "0xd1d1d1", at: 0.62),
                        text(name, size: 0.026, color: "0x9e9eab", at: 0.70)]
        }
        return common + ["-f", "lavfi", "-i", "color=c=0x171719:s=\(width)x\(height):d=1", "-vf", (filters + ["format=yuvj420p"]).joined(separator: ","),
                         "-frames:v", "1", "-c:v", "mjpeg", "-q:v", "3", "-f", "mjpeg", "pipe:1"]
    }

    /// A quality of 0…1 on mjpeg's `-q:v` scale (2 best, 31 worst).
    static func mjpegScale(_ quality: Double) -> Int {
        min(31, max(2, Int(((1 - min(max(quality, 0), 1)) * 29).rounded()) + 2))
    }

    /// A JPEG (or PNG) of `width × height` in, with the correction's maps for `correction` (`remapInputs`) → the straightened picture as a
    /// JPEG of `width × height`. The warp works at `correction`'s size (its width even: a picture of an odd width is warped one pixel
    /// wider and scaled back). The decoder's full-range picture goes into the warp's `format=yuv420p` and comes out full range, as
    /// `resizeImage` writes it.
    static func correctImage(_ correction: RemapStage, width: Int, height: Int) -> [String] {
        var filters = correction.width != width || correction.height != height ? "scale=\(width):\(height):flags=lanczos," : ""
        filters += "scale=out_range=pc,format=yuvj420p"
        return common + ["-f", "image2pipe", "-i", "pipe:0"] + remapInputs(correction)
            + ["-filter_complex", remapChain(correction, input: "0:v:0", output: "cbw") + ";[cbw]\(filters)[cbv]", "-map", "[cbv]",
               "-frames:v", "1", "-c:v", "mjpeg", "-q:v", "5", "-f", "mjpeg", "pipe:1"]
    }

    /// Digital silence, encoded as AAC-LC (FLV on stdout).
    static func silentAAC(sampleRate: Int, channelLayout: String, seconds: Double) -> [String] {
        common + ["-f", "lavfi", "-i", "anullsrc=r=\(sampleRate):cl=\(channelLayout)", "-t", number(seconds), "-c:a", "aac", "-b:a", "48k",
                  "-f", "flv", "pipe:1"]
    }
}
