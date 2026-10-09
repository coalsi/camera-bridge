import Foundation
import MediaCore

/// Frame-differencing motion detector for cameras without an event API (pure Swift).
///
/// Luma thumbnails (from `DecodedVideoFrame.grayThumbnail`, re-downscaled here if wider than `analysisWidth`) are
/// sampled at ~4 fps and compared with a running-average background (α = 0.1). A pixel counts as changed when it differs
/// by more than 32 − 7·sensitivity levels (≥ 25, so the fading trace of a one-frame glitch never counts); a frame is a
/// hit when the changed fraction reaches a threshold that falls from 10 % (sensitivity 0) to 0.2 % (sensitivity 1).
/// Motion turns on after 2 consecutive hits and off after 10 s without hits. A frame where over half the picture
/// changes at once (IR switch, exposure jump) resets the background instead of counting as motion.
/// Motion is released only from `process(_:at:)`: if frames stop arriving while motion is on, the detector stays on,
/// so the caller must end motion itself when its decoded stream stops. Times should be monotonic; a time before the
/// last hit (a clock stepped back) starts the quiet period again from there instead of holding motion on for the step.
public actor SoftMotionDetector {
    static let minimumSampleInterval: TimeInterval = 0.23          // ~4 fps with jitter tolerance
    static let hitsToTurnOn = 2
    static let quietPeriodToTurnOff: TimeInterval = 10
    static let backgroundRate: Float = 0.1
    static let globalChangeFraction = 0.5

    private let sensitivity: Double
    private let analysisWidth: Int
    private let pixelThreshold: Float
    private let fractionThreshold: Double
    private var background: [Float] = []
    private var backgroundSize = (width: 0, height: 0)
    private var lastSample: Date?
    private var consecutiveHits = 0
    private var lastHit: Date?
    private var isMotion = false
    /// Frames analysed (after rate limiting).
    private(set) var sampledFrames = 0

    public init(sensitivity: Double /* 0...1 */, analysisWidth: Int = 320) {
        let clamped = sensitivity.isFinite ? min(max(sensitivity, 0), 1) : 0.5
        self.sensitivity = clamped
        self.analysisWidth = max(16, analysisWidth)
        self.pixelThreshold = Float(32 - 7 * clamped)
        self.fractionThreshold = Self.changedFractionThreshold(sensitivity: clamped)
    }

    /// Changed-pixel fraction needed for a hit: 10 % at sensitivity 0 … 0.2 % at 1 (geometric).
    static func changedFractionThreshold(sensitivity: Double) -> Double {
        let s = sensitivity.isFinite ? min(max(sensitivity, 0), 1) : 0.5
        return 0.10 * pow(0.02, s)
    }

    /// Feed luma thumbnails (from `DecodedVideoFrame.grayThumbnail`; any rate, internally sampled ~4 fps).
    /// Returns true/false on state transitions, nil otherwise.
    public func process(_ image: GrayImage, at time: Date) -> Bool? {
        guard image.width > 0, image.height > 0, image.width <= 16_384, image.height <= 16_384,
              image.pixels.count >= image.width * image.height else { return nil }
        if let lastSample {
            let elapsed = time.timeIntervalSince(lastSample)
            if elapsed >= 0 && elapsed < Self.minimumSampleInterval { return nil }
        }
        lastSample = time
        sampledFrames += 1
        let frame = image.width > analysisWidth ? Self.downscale(image, toWidth: analysisWidth) : image

        guard backgroundSize == (frame.width, frame.height), background.count == frame.width * frame.height else {
            resetBackground(frame)
            return releaseIfQuiet(at: time)
        }
        let count = frame.width * frame.height
        var changed = 0
        let rate = Self.backgroundRate
        frame.pixels.withUnsafeBufferPointer { pixels in
            background.withUnsafeMutableBufferPointer { average in
                for i in 0..<count {
                    let value = Float(pixels[i])
                    if abs(value - average[i]) > pixelThreshold { changed += 1 }
                    average[i] += (value - average[i]) * rate
                }
            }
        }
        let fraction = Double(changed) / Double(count)
        if fraction >= Self.globalChangeFraction {
            resetBackground(frame)
            consecutiveHits = 0
            return releaseIfQuiet(at: time)
        }
        if fraction >= fractionThreshold {
            consecutiveHits += 1
            if isMotion {
                lastHit = time
            } else if consecutiveHits >= Self.hitsToTurnOn {
                isMotion = true
                lastHit = time
                return true
            }
            return nil
        }
        consecutiveHits = 0
        return releaseIfQuiet(at: time)
    }

    private func resetBackground(_ frame: GrayImage) {
        background = frame.pixels.prefix(frame.width * frame.height).map(Float.init)
        backgroundSize = (frame.width, frame.height)
    }

    private func releaseIfQuiet(at time: Date) -> Bool? {
        guard isMotion, let lastHit else { return nil }
        if time < lastHit {
            self.lastHit = time   // the clock stepped back: the quiet period runs from here
            return nil
        }
        guard time.timeIntervalSince(lastHit) >= Self.quietPeriodToTurnOff else { return nil }
        isMotion = false
        consecutiveHits = 0
        return false
    }

    /// Box-filter downscale to `width` (height keeps the aspect ratio).
    static func downscale(_ image: GrayImage, toWidth width: Int) -> GrayImage {
        guard image.width > width, width > 0 else { return image }
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        var output = [UInt8](repeating: 0, count: width * height)
        for oy in 0..<height {
            let y0 = oy * image.height / height
            let y1 = max(y0 + 1, (oy + 1) * image.height / height)
            for ox in 0..<width {
                let x0 = ox * image.width / width
                let x1 = max(x0 + 1, (ox + 1) * image.width / width)
                var sum = 0
                for y in y0..<y1 {
                    let row = y * image.width
                    for x in x0..<x1 { sum += Int(image.pixels[row + x]) }
                }
                output[oy * width + ox] = UInt8(sum / ((y1 - y0) * (x1 - x0)))
            }
        }
        return GrayImage(width: width, height: height, pixels: output)
    }
}
