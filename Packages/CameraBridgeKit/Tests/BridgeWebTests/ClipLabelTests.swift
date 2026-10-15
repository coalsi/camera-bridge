import BridgeEngine
import Foundation
import MediaCore
import Testing
@testable import BridgeWeb

/// The label burned into a saved clip: the time of every picture, exact across the gaps the clip skips.
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
        let gpu = WebApp.labelArguments(input: "/t/clip.mp4", textFiles: runs, style: TimestampOverlaySettings(), font: nil, vaapiDevice: "/dev/dri/renderD128")
        let filters = gpu[gpu.firstIndex(of: "-vf")! + 1]
        #expect(filters.contains("enable='between(t\\,0.000\\,20.000)'") && filters.contains("enable='gte(t\\,20.000)'"))
        #expect(filters.hasPrefix("scale='min(iw\\,3840)':-2,") && filters.hasSuffix("format=nv12,hwupload"))
        #expect(gpu.contains("h264_vaapi") && gpu.contains("-vaapi_device") && gpu.last == "pipe:1")
        let cpu = WebApp.labelArguments(input: "/t/clip.mp4", textFiles: runs, style: TimestampOverlaySettings(), font: nil, vaapiDevice: nil)
        #expect(cpu.contains("libx264") && !cpu.contains("-vaapi_device"))
    }
}
