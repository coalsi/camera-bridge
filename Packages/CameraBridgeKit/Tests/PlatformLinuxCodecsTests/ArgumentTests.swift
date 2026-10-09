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
    }
}
