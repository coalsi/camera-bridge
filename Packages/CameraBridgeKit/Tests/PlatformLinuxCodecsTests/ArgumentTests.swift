import Foundation
import MediaCore
import Testing
@testable import PlatformLinux

@Suite struct ArgumentTests {
    private func spec(width: Int = 1280, height: Int = 720, fps: Int = 30, bitrate: Int = 2_000, backend: FFmpegVideoBackend = .software(preset: "veryfast"),
                      sourceWidth: Int = 1920, sourceHeight: Int = 1080, overlay: DrawTextOverlay? = nil) -> VideoPipelineSpec {
        VideoPipelineSpec(settings: VideoEncoderSettings(width: width, height: height, fps: fps, bitrateKbps: bitrate, profile: .main, level: .level4_0,
                                                         keyframeInterval: .seconds(4)),
                          bitrateKbps: bitrate, backend: backend, sourceWidth: sourceWidth, sourceHeight: sourceHeight, overlay: overlay)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    @Test func softwareTranscoderUsesX264Zerolatency() {
        let arguments = FFmpegArguments.transcoder(spec())
        #expect(value(after: "-c:v", in: arguments) == "libx264")
        #expect(value(after: "-preset", in: arguments) == "veryfast")
        #expect(value(after: "-tune", in: arguments) == "zerolatency")
        #expect(value(after: "-profile:v", in: arguments) == "main")
        #expect(value(after: "-level:v", in: arguments) == "4.0")
        #expect(value(after: "-b:v", in: arguments) == "2000k")
        #expect(value(after: "-maxrate", in: arguments) == "3000k")
        #expect(value(after: "-bufsize", in: arguments) == "3000k")
        #expect(value(after: "-g", in: arguments) == "120")   // 4 s at 30 fps
        #expect(value(after: "-bf", in: arguments) == "0")
        #expect(value(after: "-fps_mode", in: arguments) == "passthrough")
        #expect(value(after: "-enc_time_base", in: arguments) == "1/1000")
        #expect(value(after: "-force_key_frames", in: arguments) == "expr:mod(round(t*1000),2)")
        #expect(arguments.suffix(5) == ["-f", "flv", "-flush_packets", "1", "pipe:1"])
        #expect(arguments.contains("-nostdin") && arguments.contains("-nostats"))
        #expect(!arguments.contains("-vaapi_device"))
        // Input: FLV on stdin with the low-delay options, never -fflags nobuffer (it discards the packets read while probing).
        #expect(value(after: "-i", in: arguments) == "pipe:0")
        #expect(!arguments.contains("+nobuffer"))
        #expect(arguments.contains("+low_delay"))
    }

    @Test func filterChainScalesWithBarsOnlyWhenTheSizeDiffers() {
        let scaled = FFmpegArguments.videoFilters(spec())
        #expect(scaled.contains("scale=1280:720:force_original_aspect_ratio=decrease"))
        #expect(scaled.contains("pad=1280:720:(ow-iw)/2:(oh-ih)/2"))
        #expect(scaled.hasSuffix("format=yuv420p"))
        let same = FFmpegArguments.videoFilters(spec(width: 1920, height: 1080))
        #expect(!same.contains("scale=") && !same.contains("pad="))
    }

    @Test func frameRateLimiterIsASelectExpressionWithTheLimitersRule() throws {
        let select = try #require(FFmpegArguments.selectFilter(spec(fps: 15)))
        // interval 1/15 s; keep when t >= due - interval/4 or t < due - interval - 1; keyframe requests (odd ms) pass.
        #expect(select.hasPrefix("select='if(gt(gte(t,ld(1)-0.066667/4)+lt(t,ld(1)-0.066667-1)+mod(round(t*1000),2),0)"))
        #expect(select.contains("st(1,"))
        // The expression sits inside quotes, so its commas do not split the filter chain.
        let quoted = select.dropFirst("select='".count).dropLast()
        #expect(!quoted.contains("'"))
        var unlimited = spec()
        unlimited.limitFrameRate = false
        #expect(FFmpegArguments.selectFilter(unlimited) == nil)
    }

    @Test func catchUpSkipsEveryPictureBeforeTheNewest() throws {
        var catchUp = spec()
        catchUp.skipBeforeSeconds = 12.3455
        let select = try #require(FFmpegArguments.selectFilter(catchUp))
        #expect(select.hasPrefix("select='if(gte(t,12.3455),"))
        catchUp.limitFrameRate = false
        #expect(FFmpegArguments.selectFilter(catchUp) == "select='if(gte(t,12.3455),1,0)'")
    }

    @Test func vaapiPipelineUploadsToTheGPUAndUsesTheHardwareEncoder() {
        let arguments = FFmpegArguments.transcoder(spec(backend: .vaapi(device: "/dev/dri/renderD128", lowPower: false)))
        #expect(value(after: "-vaapi_device", in: arguments) == "/dev/dri/renderD128")
        #expect(value(after: "-c:v", in: arguments) == "h264_vaapi")
        #expect(value(after: "-vf", in: arguments)?.hasSuffix("format=nv12,hwupload") == true)
        #expect(value(after: "-level:v", in: arguments) == "40")
        #expect(!arguments.contains("-preset") && !arguments.contains("-tune"))
        #expect(value(after: "-b:v", in: arguments) == "2000k")
        #expect(value(after: "-bf", in: arguments) == "0")
        #expect(!arguments.contains("-low_power"))
    }

    @Test func lowPowerVAAPIAsksForTheFixedFunctionEncoder() {
        let arguments = FFmpegArguments.transcoder(spec(backend: .vaapi(device: "/dev/dri/renderD129", lowPower: true)))
        #expect(value(after: "-vaapi_device", in: arguments) == "/dev/dri/renderD129")
        #expect(value(after: "-low_power", in: arguments) == "1")
        #expect(FFmpegVideoBackend.vaapi(device: "/dev/dri/renderD128", lowPower: true).description == "h264_vaapi (/dev/dri/renderD128, low power)")
    }

    @Test func baselineProfileIsConstrainedBaselineOnVAAPI() {
        var baseline = spec(backend: .vaapi(device: "/dev/dri/renderD128", lowPower: false))
        baseline.settings.profile = .baseline
        #expect(value(after: "-profile:v", in: FFmpegArguments.transcoder(baseline)) == "constrained_baseline")
        var software = spec()
        software.settings.profile = .baseline
        #expect(value(after: "-profile:v", in: FFmpegArguments.transcoder(software)) == "baseline")
    }

    @Test func levelIsRaisedUntilThePictureFits() {
        // 1080p at 30 fps needs level 4.0 (hardware refuses 3.1), 4K at 30 needs 5.1.
        var settings = VideoEncoderSettings(width: 1920, height: 1080, fps: 30, bitrateKbps: 4_000, level: .level3_1)
        #expect(FFmpegArguments.h264Level(settings) == "4.0")
        settings = VideoEncoderSettings(width: 3840, height: 2160, fps: 30, bitrateKbps: 8_000, level: .level4_0)
        #expect(FFmpegArguments.h264Level(settings) == "5.1")
        settings.level = .auto
        #expect(FFmpegArguments.h264Level(settings) == nil)
    }

    @Test func keyframeIntervalFollowsTheExpectedFrameRate() {
        var settings = VideoEncoderSettings(width: 640, height: 360, fps: 30, bitrateKbps: 500, keyframeInterval: .seconds(2), expectedFrameRate: 10)
        var s = spec()
        s.settings = settings
        #expect(value(after: "-g", in: FFmpegArguments.transcoder(s)) == "20")
        settings.expectedFrameRate = nil
        s.settings = settings
        #expect(value(after: "-g", in: FFmpegArguments.transcoder(s)) == "60")
    }

    @Test func overlayIsADrawtextFilterReadingATextFile() {
        let overlay = DrawTextOverlay(fontFile: "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", textFile: "/tmp/cb/overlay.txt", position: .topRight, size: .medium)
        let filters = FFmpegArguments.videoFilters(spec(overlay: overlay))
        #expect(filters.contains("drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf:textfile=/tmp/cb/overlay.txt:reload=1:expansion=none"))
        #expect(filters.contains("fontsize=23"))   // 0.032 × 720
        #expect(filters.contains("x=w-tw-"))
        #expect(filters.contains(":y=") && !filters.contains("y=h-th"))
        let bottomLeft = FFmpegArguments.drawText(DrawTextOverlay(fontFile: "/f.ttf", textFile: "/t.txt", position: .bottomLeft, size: .large), outputHeight: 1080)
        #expect(bottomLeft.contains("y=h-th-") && !bottomLeft.contains("x=w-tw"))
        // The overlay is drawn after scaling and before the pixel format conversion.
        let chain = filters.components(separatedBy: ",")
        let draw = chain.firstIndex { $0.hasPrefix("drawtext") }
        let pad = chain.firstIndex { $0.hasPrefix("pad=") }
        let format = chain.firstIndex { $0.hasPrefix("format=") }
        #expect(pad != nil && draw != nil && format != nil && pad! < draw! && draw! < format!)
    }

    @Test func unusualPathsAreQuotedForTheFilterGraph() {
        #expect(FFmpegArguments.optionValue("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf") == "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf")
        #expect(FFmpegArguments.optionValue("/System/Library/Fonts/Supplemental/Arial Bold.ttf") == "'/System/Library/Fonts/Supplemental/Arial Bold.ttf'")
        #expect(FFmpegArguments.optionValue("/tmp/a:b,c.ttf") == "'/tmp/a:b,c.ttf'")
        #expect(FFmpegArguments.optionValue("/tmp/it's.ttf") == "'/tmp/it'\\''s.ttf'")
        let overlay = DrawTextOverlay(fontFile: "/fonts/Arial Bold.ttf", textFile: "/tmp/a b/overlay.txt", position: .topLeft, size: .small)
        #expect(FFmpegArguments.drawText(overlay, outputHeight: 720).hasPrefix("drawtext=fontfile='/fonts/Arial Bold.ttf':textfile='/tmp/a b/overlay.txt':reload=1"))
        #expect(FFmpegArguments.isUsablePath("/tmp/a b"))
        #expect(!FFmpegArguments.isUsablePath("/tmp/a\nb") && !FFmpegArguments.isUsablePath(""))
    }

    @Test func rawEncoderReadsRawPicturesAndDoesNotLimitTheRate() {
        let arguments = FFmpegArguments.rawEncoder(spec(sourceWidth: 640, sourceHeight: 360), inputWidth: 640, inputHeight: 360)
        #expect(value(after: "-video_size", in: arguments) == "640x360")
        #expect(value(after: "-framerate", in: arguments) == "30")
        #expect(value(after: "-pix_fmt", in: arguments) == "yuv420p")
        #expect(value(after: "-vf", in: arguments)?.contains("select") == false)
        #expect(!arguments.contains("-force_key_frames"))
    }

    @Test func decoderOutputsRawPicturesAtTheDeclaredSize() {
        let arguments = FFmpegArguments.decoder(width: 1920, height: 1080)
        #expect(value(after: "-vf", in: arguments) == "scale=1920:1080,format=yuv420p")
        #expect(arguments.suffix(5) == ["-f", "yuv4mpegpipe", "-pix_fmt", "yuv420p", "pipe:1"])
    }

    @Test func decoderUsesTheGPUWhenGivenARenderNode() {
        let arguments = FFmpegArguments.decoder(width: 1920, height: 1080, hardwareDevice: "/dev/dri/renderD128")
        #expect(value(after: "-hwaccel", in: arguments) == "vaapi")
        #expect(value(after: "-hwaccel_device", in: arguments) == "/dev/dri/renderD128")
        #expect(arguments.firstIndex(of: "-hwaccel")! < arguments.firstIndex(of: "-i")!, "an input option: before -i")
        #expect(value(after: "-hwaccel_output_format", in: arguments) == "vaapi")
        #expect(value(after: "-vf", in: arguments)?.hasPrefix("scale_vaapi=w=1920:h=1080") == true, "scaled on the GPU, then copied back")
        #expect(FFmpegVideoDecoder.outputSize(width: 3840, height: 2160, maxWidth: 640) == (640, 360))
        #expect(FFmpegVideoDecoder.outputSize(width: 640, height: 480, maxWidth: 640) == (640, 480))
        #expect(!FFmpegArguments.decoder(width: 1920, height: 1080).contains("-hwaccel"))
    }

    @Test func audioEncoderChoice() {
        let all: Set<String> = ["aac", "libopus", "pcm_alaw", "pcm_mulaw"]
        #expect(FFmpegArguments.audioEncoderOptions(AudioEncoderSettings(codec: .opus, sampleRate: 16_000), available: all)?.prefix(2) == ["-c:a", "libopus"])
        #expect(FFmpegArguments.audioEncoderOptions(AudioEncoderSettings(codec: .aac, sampleRate: 16_000), available: all)?.prefix(2) == ["-c:a", "aac"])
        #expect(FFmpegArguments.audioEncoderOptions(AudioEncoderSettings(codec: .aacELD, sampleRate: 16_000), available: all) == nil)
        #expect(FFmpegArguments.audioEncoderOptions(AudioEncoderSettings(codec: .aacELD, sampleRate: 16_000), available: all.union(["libfdk_aac"]))?.contains("aac_eld") == true)
        #expect(FFmpegArguments.audioEncoderOptions(AudioEncoderSettings(codec: .opus, sampleRate: 16_000), available: ["aac"]) == nil)
        #expect(FFmpegArguments.audioEncoderOptions(AudioEncoderSettings(codec: .pcmu, sampleRate: 8_000), available: []) == ["-c:a", "pcm_mulaw"])
        #expect(FFmpegArguments.audioEncoderOptions(AudioEncoderSettings(codec: .aac, sampleRate: 16_000, bitrate: 40_000), available: all)?.contains("40000") == true)
    }

    @Test func audioWiresMatchTheCodecs() {
        #expect(FFmpegArguments.audioInputWire(.aac) == .flv && FFmpegArguments.audioInputWire(.aacELD) == .flv)
        #expect(FFmpegArguments.audioInputWire(.opus) == .ogg)
        #expect(FFmpegArguments.audioInputWire(.pcmu) == .raw("mulaw") && FFmpegArguments.audioInputWire(.pcma) == .raw("alaw"))
        #expect(FFmpegArguments.audioInputWire(.linearPCM) == .raw("s16le"))
        let arguments = FFmpegArguments.audioTranscoder(input: AudioFormat(codec: .pcma, sampleRate: 8_000, channels: 1), output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000),
                                                        encoder: ["-c:a", "libopus"])
        #expect(value(after: "-f", in: arguments) == "alaw")
        #expect(arguments.contains("-ar") && arguments.contains("16000"))
        #expect(arguments.suffix(3) == ["-flush_packets", "1", "pipe:1"])
        #expect(arguments.contains("ogg"))
    }

    // MARK: Straighten the picture

    /// Whether `run` appears in `arguments` as consecutive elements.
    private func contains(_ run: [String], in arguments: [String]) -> Bool {
        guard run.count <= arguments.count else { return false }
        return (0...(arguments.count - run.count)).contains { Array(arguments[$0..<($0 + run.count)]) == run }
    }

    private func corrected(_ base: VideoPipelineSpec, width: Int, height: Int) -> VideoPipelineSpec {
        var spec = base
        spec.correction = RemapStage(xMap: "/s/x.pgm", yMap: "/s/y.pgm", chromaXMap: "/s/cx.pgm", chromaYMap: "/s/cy.pgm", width: width, height: height)
        return spec
    }

    @Test func aCorrectedTranscoderReadsTheMapsAndUsesAFilterGraph() throws {
        let arguments = FFmpegArguments.transcoder(corrected(spec(width: 1920, height: 1080, sourceWidth: 1920, sourceHeight: 1080), width: 1920, height: 1080))
        #expect(contains(["-f", "flv", "-i", "pipe:0", "-i", "/s/x.pgm", "-i", "/s/y.pgm", "-i", "/s/cx.pgm", "-i", "/s/cy.pgm"], in: arguments))
        #expect(!arguments.contains("-vf"))
        #expect(contains(["-map", "[cbv]"], in: arguments) && !arguments.contains("0:v:0"))
        let graph = try #require(value(after: "-filter_complex", in: arguments))
        // The frame-rate limit first, then the warp (each 4:2:0 plane as gray, maps 1:v…4:v), then the pixel format the encoder takes.
        #expect(graph.hasPrefix("[0:v:0]select='"))
        #expect(graph.contains("'[cbsel];" + PictureCorrection.ffmpegRemapChain(input: "cbsel", width: 1920, height: 1080, xMap: "1:v", yMap: "2:v",
                                                                               chromaXMap: "3:v", chromaYMap: "4:v", output: "cbw")
            + ";[cbw]format=yuv420p[cbv]"))
        #expect(graph.contains("[cbsel]scale=1920:2160:flags=bicubic,format=yuv420p,extractplanes=y+u+v[cbpy][cbpu][cbpv];[1:v]format=gray16[cbx];"
            + "[2:v]format=gray16[cby];[3:v]format=gray16,split[cbcx1][cbcx2];[4:v]format=gray16,split[cbcy1][cbcy2];"))
        #expect(graph.contains("mergeplanes=map0s=0:map0p=0:map1s=1:map1p=0:map2s=2:map2p=0:format=yuv420p,scale=1920:1080:flags=area[cbw]"))
        #expect(graph.hasSuffix("[cbw]format=yuv420p[cbv]"))
        // Same size in and out: no bars.
        #expect(!graph.contains("pad=") && !graph.contains("setsar"))
        // Everything else is as without the correction.
        #expect(arguments.contains("-copyts") && contains(["-an", "-sn", "-dn"], in: arguments))
        #expect(value(after: "-fps_mode", in: arguments) == "passthrough")
        #expect(value(after: "-force_key_frames", in: arguments) == "expr:mod(round(t*1000),2)")
        #expect(value(after: "-c:v", in: arguments) == "libx264")
        #expect(arguments.suffix(5) == ["-f", "flv", "-flush_packets", "1", "pipe:1"])
        // Without a frame-rate limit or catch-up there is no select: the chain reads the camera's picture itself.
        var unlimited = corrected(spec(width: 1920, height: 1080, sourceWidth: 1920, sourceHeight: 1080), width: 1920, height: 1080)
        unlimited.limitFrameRate = false
        let plain = try #require(value(after: "-filter_complex", in: FFmpegArguments.transcoder(unlimited)))
        #expect(plain.hasPrefix("[0:v:0]scale=1920:2160:flags=bicubic,format=yuv420p,extractplanes=y+u+v[cbpy][cbpu][cbpv];") && !plain.contains("select"))
        // The raw encoder (the Mac-style encode of decoded pictures) never warps.
        let raw = corrected(spec(sourceWidth: 640, sourceHeight: 360), width: 640, height: 360)
        #expect(FFmpegArguments.rawEncoder(raw, inputWidth: 640, inputHeight: 360) == FFmpegArguments.rawEncoder(spec(sourceWidth: 640, sourceHeight: 360), inputWidth: 640, inputHeight: 360))
    }

    @Test func aLetterboxedPictureIsStraightenedBeforeItIsPadded() throws {
        let fitted = FFmpegArguments.fittedSize(sourceWidth: 4256, sourceHeight: 1888, width: 1920, height: 1080)
        #expect(fitted.width == 1920 && fitted.height == 852)
        let arguments = FFmpegArguments.transcoder(corrected(spec(width: 1920, height: 1080, sourceWidth: 4256, sourceHeight: 1888), width: fitted.width, height: fitted.height))
        let graph = try #require(value(after: "-filter_complex", in: arguments))
        let warp = try #require(graph.range(of: "scale=1920:1704:flags=bicubic"))
        let shrink = try #require(graph.range(of: "scale=1920:852:flags=area"))
        let pad = try #require(graph.range(of: "pad=1920:1080:(ow-iw)/2:(oh-ih)/2"))
        let square = try #require(graph.range(of: "setsar=1"))
        #expect(warp.lowerBound < shrink.lowerBound && shrink.lowerBound < pad.lowerBound && pad.lowerBound < square.lowerBound)
        #expect(!graph.contains("force_original_aspect_ratio"))
        // The fitted size is the one force_original_aspect_ratio=decrease gives (rounded to the nearest pixel), made even.
        func size(_ sw: Int, _ sh: Int, _ w: Int, _ h: Int) -> [Int] {
            let s = FFmpegArguments.fittedSize(sourceWidth: sw, sourceHeight: sh, width: w, height: h)
            return [s.width, s.height]
        }
        #expect(size(1920, 1080, 1920, 1080) == [1920, 1080])
        #expect(size(1920, 1080, 1280, 720) == [1280, 720])
        #expect(size(640, 360, 320, 320) == [320, 180])
        #expect(size(1080, 1920, 1920, 1080) == [608, 1080])   // 607.5 rounds up
        #expect(size(1919, 1080, 1920, 1080) == [1918, 1080])  // odd width made even
        #expect(size(4000, 10, 1920, 1080) == [1920, 4])
        #expect(size(10_000, 2, 320, 180) == [320, 2])           // never below 2
    }

    @Test func theLabelIsDrawnAfterTheWarp() throws {
        let overlay = DrawTextOverlay(fontFile: "/f.ttf", textFile: "/t/overlay.txt", position: .bottomLeft, size: .medium)
        let arguments = FFmpegArguments.transcoder(corrected(spec(width: 1920, height: 1080, sourceWidth: 4256, sourceHeight: 1888, overlay: overlay), width: 1920, height: 852))
        let graph = try #require(value(after: "-filter_complex", in: arguments))
        let remap = try #require(graph.range(of: "remap"))
        let pad = try #require(graph.range(of: "pad="))
        let draw = try #require(graph.range(of: "drawtext=fontfile=/f.ttf:textfile=/t/overlay.txt"))
        let format = try #require(graph.range(of: "format=yuv420p[cbv]"))
        #expect(remap.lowerBound < pad.lowerBound && pad.lowerBound < draw.lowerBound && draw.lowerBound < format.lowerBound)
        // The label's size follows the output picture, as without the correction.
        #expect(graph.contains("fontsize=35"))   // 0.032 × 1080
    }

    @Test func withoutACorrectionTheArgumentsAreUnchanged() {
        // Goldens of the arguments before the correction existed (2026-10-18).
        var labelled = spec(overlay: DrawTextOverlay(fontFile: "/f.ttf", textFile: "/t/overlay.txt", position: .topRight, size: .medium))
        labelled.skipBeforeSeconds = 12.3455
        #expect(FFmpegArguments.transcoder(labelled) == [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error", "-copyts", "-flags", "+low_delay", "-analyzeduration", "1", "-probesize", "2048",
            "-f", "flv", "-i", "pipe:0", "-map", "0:v:0", "-an", "-sn", "-dn",
            "-vf", "select='if(gte(t,12.3455),if(gt(gte(t,ld(1)-0.033333/4)+lt(t,ld(1)-0.033333-1)+mod(round(t*1000),2),0),st(1,if(gt(between(t,ld(1)-0.033333,ld(1)+0.033333)*gt(ld(1),0),0),ld(1)+0.033333,t+0.033333))*0+1,0),0)',"
                + "scale=1280:720:force_original_aspect_ratio=decrease:flags=bicubic,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,"
                + "drawtext=fontfile=/f.ttf:textfile=/t/overlay.txt:reload=1:expansion=none:fontsize=23:fontcolor=white:box=1:boxcolor=black@0.42:boxborderw=8"
                + ":shadowcolor=black@0.5:shadowx=1:shadowy=1:x=w-tw-29:y=29,format=yuv420p",
            "-fps_mode", "passthrough", "-enc_time_base", "1/1000", "-force_key_frames", "expr:mod(round(t*1000),2)",
            "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency", "-profile:v", "main", "-level:v", "4.0", "-x264-params", "scenecut=0:keyint=120:min-keyint=30",
            "-b:v", "2000k", "-maxrate", "3000k", "-bufsize", "3000k", "-g", "120", "-bf", "0", "-f", "flv", "-flush_packets", "1", "pipe:1",
        ])
        #expect(FFmpegArguments.transcoder(spec(width: 1920, height: 1080, backend: .vaapi(device: "/dev/dri/renderD128", lowPower: true))) == [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error", "-vaapi_device", "/dev/dri/renderD128", "-copyts", "-flags", "+low_delay",
            "-analyzeduration", "1", "-probesize", "2048", "-f", "flv", "-i", "pipe:0", "-map", "0:v:0", "-an", "-sn", "-dn",
            "-vf", "select='if(gt(gte(t,ld(1)-0.033333/4)+lt(t,ld(1)-0.033333-1)+mod(round(t*1000),2),0),st(1,if(gt(between(t,ld(1)-0.033333,ld(1)+0.033333)*gt(ld(1),0),0),ld(1)+0.033333,t+0.033333))*0+1,0)',"
                + "format=nv12,hwupload",
            "-fps_mode", "passthrough", "-enc_time_base", "1/1000", "-force_key_frames", "expr:mod(round(t*1000),2)",
            "-c:v", "h264_vaapi", "-profile:v", "main", "-level:v", "40", "-async_depth", "1", "-g", "120", "-bf", "0", "-low_power", "1",
            "-b:v", "2000k", "-maxrate", "3000k", "-bufsize", "3000k", "-f", "flv", "-flush_packets", "1", "pipe:1",
        ])
        // nil is the default.
        #expect(spec().correction == nil)
    }

    @Test func vaapiStillUploadsLast() throws {
        let arguments = FFmpegArguments.transcoder(corrected(spec(width: 1920, height: 1080, backend: .vaapi(device: "/dev/dri/renderD128", lowPower: false),
                                                                  sourceWidth: 4256, sourceHeight: 1888), width: 1920, height: 852))
        #expect(value(after: "-vaapi_device", in: arguments) == "/dev/dri/renderD128")
        #expect(value(after: "-c:v", in: arguments) == "h264_vaapi")
        let graph = try #require(value(after: "-filter_complex", in: arguments))
        #expect(graph.hasSuffix(",format=nv12,hwupload[cbv]"))
        #expect(graph.contains("remap"))
    }

    @Test func jpegQualityMapsToTheMJPEGScale() {
        func q(_ quality: Double) -> String? {
            let arguments = FFmpegArguments.jpeg(inputWidth: 640, inputHeight: 360, width: 640, height: 360, quality: quality)
            return arguments.firstIndex(of: "-q:v").map { arguments[$0 + 1] }
        }
        #expect(q(1) == "2")
        #expect(q(0) == "31")
        #expect(q(0.8) == "8")
        let scaled = FFmpegArguments.jpeg(inputWidth: 1920, inputHeight: 1080, width: 640, height: 360, quality: 0.8)
        #expect(scaled.contains { $0.hasPrefix("scale=640:360:flags=lanczos") })
        // A resize takes the quality asked on the same scale, and keeps -q:v 5 without one.
        func resizeQ(_ quality: Double?) -> String? {
            let arguments = FFmpegArguments.resizeImage(width: 768, height: 432, quality: quality)
            return arguments.firstIndex(of: "-q:v").map { arguments[$0 + 1] }
        }
        #expect(resizeQ(nil) == "5")
        #expect(resizeQ(0.7) == "11")
        #expect(resizeQ(0.8) == "8")
    }
}
