import Foundation

/// Exponential backoff with symmetric jitter, capped at `maximum`.
public struct Backoff: Sendable {
    private let initial: Double
    private let maximum: Double
    private let multiplier: Double
    private let jitter: Double
    private var attempt = 0

    public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(60), multiplier: Double = 2, jitter: Double = 0.2) {
        self.initial = max(0, initial.timeInterval)
        self.maximum = max(0, maximum.timeInterval)
        self.multiplier = max(1, multiplier)
        self.jitter = min(max(0, jitter), 1)
    }

    /// The delay before the next attempt. Each call advances the attempt counter.
    public mutating func next() -> Duration {
        let exponent = Double(attempt)
        attempt = min(attempt + 1, 1_000)
        var base = initial * pow(multiplier, exponent)
        if !base.isFinite || base > maximum { base = maximum }
        var delay = base
        if jitter > 0 && base > 0 {
            delay = base * (1 + Double.random(in: -jitter...jitter))
        }
        return .seconds(min(max(0, delay), maximum))
    }

    public mutating func reset() {
        attempt = 0
    }
}

extension Duration {
    /// The duration in (fractional) seconds (`package`: shared by every module of the package).
    package var timeInterval: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
