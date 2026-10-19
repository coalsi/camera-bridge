#if DEBUG
import AVFoundation
import AppKit
import CoreVideo
import Foundation
import MediaCore
import PlatformApple
import Testing

/// What the probe (`NVRProbe`) relies on, measured on the Mac it runs on: a `LiveVideoRenderer` whose layer is in a window gives its displayed picture back
/// (`displayedPicture()`), at the synchronizer's normal rate 1 and with its clock stopped (`setProbeMode`), and the demo camera's frame counter can be read
/// from it. A layer that is in no window gives nothing back. The picture comes in a lossless compressed format ('&8v0'), so `DemoCounterReader` reads it
/// through CoreImage. Needs a window server: not run on CI (`CI` is set there).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil)) struct RendererReadbackTests {
    private func demoFrames(count: Int) async throws -> [EncodedVideoFrame] {
        let source = AppleMediaCodecs().makeSyntheticSource(displayName: "Readback", width: 1_920, height: 1_080, fps: 30, keyframeInterval: .seconds(1), audio: nil, audioSampleRate: 0)
        var frames: [EncodedVideoFrame] = []
        for try await sample in try await source.samples() {
            if case .video(let frame) = sample { frames.append(frame) }
            if frames.count >= count { break }
        }
        await source.stop()
        return frames
    }

    /// A renderer whose layer is in a small window that is on screen (or in none).
    private func hostedRenderer(inWindow: Bool) -> (LiveVideoRenderer, NSWindow?) {
        let renderer = LiveVideoRenderer()
        guard inWindow else { return (renderer, nil) }
        let window = NSWindow(contentRect: NSRect(x: 40, y: 80, width: 480, height: 270), styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        content.wantsLayer = true
        window.contentView = content
        renderer.layer.frame = content.bounds
        content.layer?.addSublayer(renderer.layer)
        window.orderFrontRegardless()
        return (renderer, window)
    }

    /// The counter of the displayed picture: the first readable one, or, with `until`, the one that equals it (the pictures are shown one after the other,
    /// so the first readable one of a burst is an early frame); nil when none is readable within `seconds`, the last one seen when `until` never came.
    private func displayedCounter(_ renderer: LiveVideoRenderer, until target: Int? = nil, within seconds: Double = 2) async throws -> Int? {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var last: Int?
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let picture = renderer.displayedPicture(), let value = DemoCounterReader.read(pixelBuffer: picture) {
                last = value
                if target == nil || value == target { return value }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return last
    }

    @Test(arguments: [false, true]) func aRendererInAWindowGivesItsDisplayedPictureBack(probeMode: Bool) async throws {
        let (renderer, window) = hostedRenderer(inWindow: true)
        defer { window?.orderOut(nil) }
        if probeMode { renderer.setProbeMode(true) }
        let frames = try await demoFrames(count: 40)
        for frame in frames { renderer.show(frame) }
        let counter = try await displayedCounter(renderer, until: 39)
        #expect(counter == 39, "the last of 40 pictures is the one on screen (probe mode \(probeMode)): \(String(describing: counter))")
    }

    @Test func aLayerInNoWindowGivesNothingBack() async throws {
        guard #available(macOS 27, *) else { return }   // measured on macOS 27; the macOS 15 and 26 path is the owner's to run
        let (renderer, _) = hostedRenderer(inWindow: false)
        for frame in try await demoFrames(count: 40) { renderer.show(frame) }
        #expect(try await displayedCounter(renderer, within: 1) == nil, "the probe's Stage must put the layer in a window")
    }

    @Test func aKeyframeIsOnTheLayerWithinTensOfMilliseconds() async throws {
        let (renderer, window) = hostedRenderer(inWindow: true)
        defer { window?.orderOut(nil) }
        let frames = try await demoFrames(count: 130)
        let keyframes = frames.enumerated().filter { $0.element.isKeyframe }.map(\.offset)
        try await Task.sleep(for: .milliseconds(300))
        var milliseconds: [Double] = []
        for trial in 0..<40 {
            let index = keyframes[trial % keyframes.count]
            renderer.reset()
            try await Task.sleep(for: .milliseconds(150))
            let start = ProcessInfo.processInfo.systemUptime
            renderer.show(frames[index])
            var seen: Double?
            while seen == nil, ProcessInfo.processInfo.systemUptime - start < 1 {
                if let picture = renderer.displayedPicture(), DemoCounterReader.read(pixelBuffer: picture) == index { seen = (ProcessInfo.processInfo.systemUptime - start) * 1_000 }
                try await Task.sleep(for: .milliseconds(1))
            }
            milliseconds.append(seen ?? 1_000)
        }
        let summary = try #require(ProbeStatistics.summary(milliseconds))
        print("keyframe on the layer after \(summary.p50) ms (median), \(summary.p95) ms (p95), \(summary.max) ms (worst), 1080p H.264, hosted layer")
        #expect(summary.p50 < 50 && summary.p95 < 100, "a keyframe handed to the renderer reaches the layer in about 10 ms on an M4 Max: p50 \(summary.p50), p95 \(summary.p95)")
    }
}
#endif
