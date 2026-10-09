import Foundation
import MediaCore
import Testing
@testable import CameraAdapters

@Suite struct SoftMotionDetectorTests {
    /// Dark background with mild deterministic sensor noise and an optional bright square.
    private func frame(width: Int = 320, height: Int = 180, square: (x: Int, y: Int)? = nil, size: Int = 40, seed: Int = 0) -> GrayImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let noise = (x &* 31 &+ y &* 17 &+ seed &* 13) % 7   // 0…6
                pixels[y * width + x] = UInt8(40 + noise)
            }
        }
        if let square {
            for y in max(0, square.y)..<min(height, square.y + size) {
                for x in max(0, square.x)..<min(width, square.x + size) { pixels[y * width + x] = 220 }
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func staticSceneNeverTriggers() async {
        let detector = SoftMotionDetector(sensitivity: 1.0)
        for i in 0..<200 {
            let result = await detector.process(frame(seed: i), at: start.addingTimeInterval(Double(i) * 0.25))
            #expect(result != true)
        }
    }

    @Test func movingSquareTurnsMotionOnThenOffAfterTenQuietSeconds() async throws {
        let detector = SoftMotionDetector(sensitivity: 0.5)
        var t = 0.0
        var onAt: Double?
        // 4 s of a static scene, then a square moving 12 px per sample.
        for i in 0..<16 {
            #expect(await detector.process(frame(seed: i), at: start.addingTimeInterval(t)) == nil)
            t += 0.25
        }
        for step in 0..<20 {
            if await detector.process(frame(square: (x: 10 + step * 12, y: 60)), at: start.addingTimeInterval(t)) == true, onAt == nil { onAt = t }
            t += 0.25
        }
        let on = try #require(onAt)
        #expect(on <= 4.0 + 0.25 * 3, "motion must start within a few samples")
        // The square stops: the scene is static again (with the square parked).
        let lastMovement = t - 0.25
        var offAt: Double?
        for _ in 0..<160 {
            if await detector.process(frame(square: (x: 10 + 19 * 12, y: 60)), at: start.addingTimeInterval(t)) == false { offAt = t; break }
            t += 0.25
        }
        let off = try #require(offAt)
        #expect(off - lastMovement >= 10, "held at least 10 s after the last change")
        #expect(off - lastMovement <= 30)
    }

    /// Review finding (W4 round 4): the 10 s quiet period was measured on the times it is given, and a clock that stepped
    /// back while motion was on (an NTP correction after wake, a manual change) held motion — and with it HKSV recording
    /// — on for the size of the step while still pictures kept arriving. A step back starts the quiet period again
    /// from the new time. (`SoftMotionMonitor` gives it monotonic times; this guards any other caller.)
    @Test func aClockSteppingBackNeverLatchesMotionOn() async throws {
        let detector = SoftMotionDetector(sensitivity: 0.5)
        var t = 0.0
        for i in 0..<16 {
            _ = await detector.process(frame(seed: i), at: start.addingTimeInterval(t))
            t += 0.25
        }
        var on = false
        for step in 0..<20 {
            if await detector.process(frame(square: (x: 10 + step * 12, y: 60)), at: start.addingTimeInterval(t)) == true { on = true }
            t += 0.25
        }
        #expect(on)
        // 6 s of still pictures, then the clock steps back an hour; still pictures go on.
        for _ in 0..<24 {
            #expect(await detector.process(frame(square: (x: 10 + 19 * 12, y: 60)), at: start.addingTimeInterval(t)) != false)
            t += 0.25
        }
        t -= 3600
        var offAfter: Double?
        for index in 0..<160 {
            if await detector.process(frame(square: (x: 10 + 19 * 12, y: 60)), at: start.addingTimeInterval(t)) == false {
                offAfter = Double(index) * 0.25
                break
            }
            t += 0.25
        }
        let off = try #require(offAfter, "motion never ended after a clock step back")
        #expect(off >= 9.5 && off <= 10.5, "ended \(off) s after the step")
    }

    @Test func singleGlitchFrameDoesNotTrigger() async {
        let detector = SoftMotionDetector(sensitivity: 1.0)
        var t = 0.0
        for i in 0..<12 {
            _ = await detector.process(frame(seed: i), at: start.addingTimeInterval(t))
            t += 0.25
        }
        #expect(await detector.process(frame(square: (x: 100, y: 60)), at: start.addingTimeInterval(t)) == nil)   // one hit only
        t += 0.25
        for i in 0..<20 {
            #expect(await detector.process(frame(seed: i), at: start.addingTimeInterval(t)) != true)
            t += 0.25
        }
    }

    @Test func framesFasterThanFourPerSecondAreSkipped() async {
        let detector = SoftMotionDetector(sensitivity: 1.0)
        #expect(await detector.process(frame(), at: start) == nil)
        #expect(await detector.sampledFrames == 1)
        _ = await detector.process(frame(square: (x: 0, y: 0)), at: start.addingTimeInterval(0.05))
        _ = await detector.process(frame(square: (x: 50, y: 0)), at: start.addingTimeInterval(0.10))
        #expect(await detector.sampledFrames == 1)
        _ = await detector.process(frame(), at: start.addingTimeInterval(0.26))
        #expect(await detector.sampledFrames == 2)
    }

    @Test func sensitivityControlsTheThreshold() {
        #expect(SoftMotionDetector.changedFractionThreshold(sensitivity: 1) < SoftMotionDetector.changedFractionThreshold(sensitivity: 0.5))
        #expect(SoftMotionDetector.changedFractionThreshold(sensitivity: 0.5) < SoftMotionDetector.changedFractionThreshold(sensitivity: 0))
        #expect(SoftMotionDetector.changedFractionThreshold(sensitivity: -3) == SoftMotionDetector.changedFractionThreshold(sensitivity: 0))
    }

    @Test func downscalesWideImagesAndRejectsInvalidOnes() async {
        let wide = frame(width: 1280, height: 720)
        let small = SoftMotionDetector.downscale(wide, toWidth: 320)
        #expect(small.width == 320 && small.height == 180 && small.pixels.count == 320 * 180)
        #expect(small.pixels[0] >= 40 && small.pixels[0] <= 46)
        let detector = SoftMotionDetector(sensitivity: 0.5)
        #expect(await detector.process(GrayImage(width: 10, height: 10, pixels: [1, 2, 3]), at: start) == nil)
        #expect(await detector.process(GrayImage(width: 0, height: 0, pixels: []), at: start) == nil)
        #expect(await detector.sampledFrames == 0)
    }

    @Test func globalBrightnessChangeIsNotMotion() async {
        // e.g. IR cut filter switching: the whole picture changes at once.
        let detector = SoftMotionDetector(sensitivity: 1.0)
        var t = 0.0
        for i in 0..<8 {
            _ = await detector.process(frame(seed: i), at: start.addingTimeInterval(t))
            t += 0.25
        }
        let bright = GrayImage(width: 320, height: 180, pixels: [UInt8](repeating: 200, count: 320 * 180))
        for _ in 0..<8 {
            #expect(await detector.process(bright, at: start.addingTimeInterval(t)) != true)
            t += 0.25
        }
    }
}
