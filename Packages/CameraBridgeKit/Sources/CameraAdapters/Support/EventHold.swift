import Foundation

/// A stateful camera signal (true/false) tracked by `EventHoldState`.
enum HoldKey: Hashable, Sendable {
    case motion
    case object(DetectedObjectKind)
    case tamper
    case audioAlarm
    case digitalInput(String)

    func event(active: Bool) -> CameraEvent {
        switch self {
        case .motion: .motion(active)
        case .object(let kind): .object(kind, active)
        case .tamper: .tamper(active)
        case .audioAlarm: .audioAlarm(active)
        case .digitalInput(let id): .digitalInput(id: id, active: active)
        }
    }
}

/// What a vendor event parser produced, before hold/dedupe logic.
enum EventSignal: Sendable, Equatable {
    /// `source` turns `key` on. With `hold`, the source turns itself off after `hold` without another activation
    /// (pulse semantics, e.g. Hikvision VMD every ~1 s); without, it stays on until `deactivate`.
    case activate(HoldKey, source: String, hold: Duration?)
    case deactivate(HoldKey, source: String)
    /// A doorbell press (deduplicated across sources).
    case ring
    /// Passed through unchanged (day/night, temperature, …).
    case event(CameraEvent)
}

/// The level sources (activated without a hold) that one signal stream turned on and has not turned off yet, so
/// whoever runs a stream that can end on its own (e.g. a side channel inside a longer session) can end them with it.
struct ActiveLevels: Sendable {
    private var sources: [(key: HoldKey, source: String)] = []

    mutating func track(_ signals: [EventSignal]) {
        for signal in signals {
            switch signal {
            case .activate(let key, let source, let hold):
                sources.removeAll { $0.key == key && $0.source == source }
                if hold == nil { sources.append((key, source)) }   // a held activation replaces the level
            case .deactivate(let key, let source):
                sources.removeAll { $0.key == key && $0.source == source }
            case .ring, .event:
                break
            }
        }
    }

    /// Deactivations for every tracked level source, in activation order; forgets them.
    mutating func releaseAll() -> [EventSignal] {
        defer { sources = [] }
        return sources.map { .deactivate($0.key, source: $0.source) }
    }
}

/// Turns signals into balanced `CameraEvent`s: a key is on while any of its sources is on (OR), each transition is
/// emitted once, pulses expire after their hold, and rings within `ringDedupe` of the previous ring are dropped.
actor EventHoldState {
    private struct SourceState {
        var generation: UInt64
        /// The hold's expiry; nil for a level source (on until deactivated).
        var timer: Task<Void, Never>?
        var isLevel: Bool { timer == nil }
    }

    private let emit: @Sendable (CameraEvent) -> Void
    private let ringDedupe: Duration
    private var sources: [HoldKey: [String: SourceState]] = [:]
    private var generation: UInt64 = 0
    private var lastRing: ContinuousClock.Instant?

    init(ringDedupe: Duration = .seconds(3), emit: @escaping @Sendable (CameraEvent) -> Void) {
        self.ringDedupe = ringDedupe
        self.emit = emit
    }

    func apply(_ signals: [EventSignal]) {
        for signal in signals { apply(signal) }
    }

    func apply(_ signal: EventSignal) {
        switch signal {
        case .activate(let key, let source, let hold):
            activate(key, source: source, hold: hold)
        case .deactivate(let key, let source):
            deactivate(key, source: source)
        case .ring:
            let now = ContinuousClock.now
            if let lastRing, now - lastRing < ringDedupe { return }
            lastRing = now
            emit(.doorbellPressed)
        case .event(let event):
            emit(event)
        }
    }

    func activeKeys() -> Set<HoldKey> {
        Set(sources.compactMap { $0.value.isEmpty ? nil : $0.key })
    }

    /// Ends every level source (activated without a hold), emitting the resulting transitions; pulses keep their hold.
    /// Called when the event channel drops: nothing would ever report the end of a level state it carried.
    func releaseLevelSources() {
        for key in Array(sources.keys) {
            guard let states = sources[key] else { continue }
            for (source, state) in states where state.isLevel { deactivate(key, source: source) }
        }
    }

    /// Cancels pending hold timers without emitting (the source is stopping).
    func cancelAll() {
        for (_, states) in sources { for (_, state) in states { state.timer?.cancel() } }
        sources.removeAll()
    }

    private func activate(_ key: HoldKey, source: String, hold: Duration?) {
        let wasActive = !(sources[key]?.isEmpty ?? true)
        sources[key]?[source]?.timer?.cancel()
        generation &+= 1
        let current = generation
        var timer: Task<Void, Never>?
        if let hold {
            timer = Task { [weak self] in
                do { try await Task.sleep(for: hold) } catch { return }
                await self?.expire(key, source: source, generation: current)
            }
        }
        sources[key, default: [:]][source] = SourceState(generation: current, timer: timer)
        if !wasActive { emit(key.event(active: true)) }
    }

    private func deactivate(_ key: HoldKey, source: String) {
        guard let state = sources[key]?.removeValue(forKey: source) else { return }
        state.timer?.cancel()
        if sources[key]?.isEmpty ?? true {
            sources[key] = nil
            emit(key.event(active: false))
        }
    }

    private func expire(_ key: HoldKey, source: String, generation: UInt64) {
        guard sources[key]?[source]?.generation == generation else { return }
        deactivate(key, source: source)
    }
}
