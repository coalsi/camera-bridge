import Foundation

/// Sanitizers for numbers that cameras report. A buggy or hostile device must never make the bridge trap
/// (`Int(Double)` on NaN/∞/huge values, `Int` overflow), so every camera-reported quantity passes through here and is
/// dropped (nil) when it is not plausible.
enum CameraNumbers {
    /// Largest accepted video width or height.
    static let maximumDimension = 16_384
    /// Accepted audio sample rates, Hz.
    static let sampleRates: ClosedRange<Double> = 1_000...768_000

    /// An audio sample rate in Hz from a camera value in Hz or kHz (`8`, `16.0`, `44.1`, `8000`); nil unless finite and
    /// within `sampleRates`.
    static func sampleRate(_ text: String?) -> Int? {
        guard let text, let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite, value > 0 else { return nil }
        let hertz = value < 1000 ? value * 1000 : value
        guard sampleRates.contains(hertz) else { return nil }
        return Int(hertz.rounded())
    }

    /// A video width or height (1…`maximumDimension`), nil otherwise.
    static func dimension(_ text: String?) -> Int? {
        dimension(text.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    static func dimension(_ value: Int?) -> Int? {
        guard let value, (1...maximumDimension).contains(value) else { return nil }
        return value
    }

    /// A frame rate (finite, 0 < fps ≤ 1000), nil otherwise.
    static func frameRate(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= 1000 else { return nil }
        return value
    }
}
