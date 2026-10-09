import BridgeSupport
import Foundation

// The motion shadow test (docs/CONTRACT_CHANGES.md 2026-10-04): built-in motion detection runs next to a camera's own
// motion events, on the sub stream, and the two are compared. The built-in detector's transitions go only to
// `MotionShadowTest` — never to the `EventRouter`, so they cannot move HomeKit motion or start a recording.

/// What the shadow test counted for one camera over a span of time. Each *event* is one stretch of motion in which the
/// camera's own periods and the built-in detector's periods overlap (or come within `MotionShadowComparator.pairingSlack`
/// of each other) — or a stretch only one of them saw.
public struct MotionShadowTotals: Sendable, Equatable {
    /// Both saw it.
    public var both = 0
    /// The camera reported it and built-in motion detection missed it.
    public var cameraOnly = 0
    /// Built-in motion detection triggered and the camera reported nothing (an extra trigger).
    public var builtInOnly = 0
    /// The median of "built-in start minus camera start" over the events both saw, in seconds (positive: built-in came
    /// later); nil before there is one.
    public var medianDelaySeconds: Double?

    public init(both: Int = 0, cameraOnly: Int = 0, builtInOnly: Int = 0, medianDelaySeconds: Double? = nil) {
        self.both = both
        self.cameraOnly = cameraOnly
        self.builtInOnly = builtInOnly
        self.medianDelaySeconds = medianDelaySeconds
    }

    /// Every event counted.
    public var events: Int { both + cameraOnly + builtInOnly }
}

/// How the shadow test is doing for one camera (`CameraStatus.motionShadow`; nil when the test is off or does not apply to
/// the camera: it applies to cameras whose motion source is the camera's own events).
public struct MotionShadowStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Built-in motion detection is analysing the sub stream next to the camera's events.
        case comparing
        /// Not comparing right now, with the reason in words ("The camera has no sub stream").
        case paused(String)
    }

    public var state: State
    /// The motion sensitivity the built-in detector uses (0...1, the camera's own setting).
    public var sensitivity: Double
    /// When the test was turned on (or the camera started with it on).
    public var enabledSince: Date
    /// The last 24 hours (only events that finished in that time).
    public var last24Hours: MotionShadowTotals
    /// Everything since `enabledSince`.
    public var sinceEnabled: MotionShadowTotals
    /// A stretch of motion is being compared right now (not counted until it ends).
    public var eventInProgress: Bool

    public init(state: State, sensitivity: Double, enabledSince: Date, last24Hours: MotionShadowTotals = MotionShadowTotals(),
                sinceEnabled: MotionShadowTotals = MotionShadowTotals(), eventInProgress: Bool = false) {
        self.state = state
        self.sensitivity = sensitivity
        self.enabledSince = enabledSince
        self.last24Hours = last24Hours
        self.sinceEnabled = sinceEnabled
        self.eventInProgress = eventInProgress
    }
}

/// Pairs the camera's motion periods with the built-in detector's and classifies each stretch of motion. A pure value (the
/// caller supplies the times as durations on one clock), portable and bounded in memory whatever happens:
/// - one stretch ("event") is open at a time, kept as a handful of numbers, not as a list of periods: a period that starts
///   while the event is open, or within `pairingSlack` of its end, joins it; the event ends once both sources are quiet for
///   `pairingSlack` (or it ran `maximumEventLength`, whatever is still open then counts as ended);
/// - finished events are kept for `window` and at most `retainedEvents` of them; the delays since enabled in a ring of
///   `retainedDelays`, and plain counters.
struct MotionShadowComparator: Sendable {
    enum Source: Sendable { case camera, builtIn }

    enum Outcome: Sendable, Equatable {
        /// Both saw it; `delay` is the built-in start minus the camera start (negative: built-in came first).
        case both(delay: Duration)
        case cameraOnly
        case builtInOnly
    }

    struct Event: Sendable, Equatable {
        var outcome: Outcome
        /// When the first period of the event started and when the last ended.
        var started: Duration
        var ended: Duration
    }

    struct Limits: Sendable {
        /// Periods whose gap is at most this long belong to one event: the built-in detector needs a moment to confirm
        /// motion, and a camera whose events are short ends before it does.
        var pairingSlack: Duration = .seconds(2)
        /// How long finished events count towards the rolling totals.
        var window: Duration = .seconds(24 * 3_600)
        var retainedEvents = 2_000
        var retainedDelays = 1_000
        /// An event that goes on this long is finished (a source that never reported its end).
        var maximumEventLength: Duration = .seconds(30 * 60)
    }

    private struct Open {
        var cameraStart: Duration?
        var builtInStart: Duration?
        var cameraActive = false
        var builtInActive = false
        var started: Duration
        var last: Duration

        var isActive: Bool { cameraActive || builtInActive }
    }

    let limits: Limits
    private var current: Open?
    private var finished: [Event] = []
    private var delays: [Duration] = []
    private var counted = MotionShadowTotals()

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Finished events kept for the rolling window (never more than `Limits.retainedEvents`).
    var retainedEventCount: Int { finished.count }
    /// Delays kept for the median since enabled (never more than `Limits.retainedDelays`).
    var retainedDelayCount: Int { delays.count }
    /// A stretch of motion is open.
    var isEventOpen: Bool { current != nil }

    /// A period of `source` starts (`active`) or ends at `now`. Returns the event this finished, if any. A repeated start and
    /// an end without a start change nothing.
    mutating func record(_ source: Source, active: Bool, at now: Duration) -> [Event] {
        var result: [Event] = []
        if active {
            if let open = current, !open.isActive, now - open.last > limits.pairingSlack {
                result.append(finish(open))
                current = nil
            }
            var open = current ?? Open(started: now, last: now)
            switch source {
            case .camera:
                open.cameraStart = open.cameraStart ?? now
                open.cameraActive = true
            case .builtIn:
                open.builtInStart = open.builtInStart ?? now
                open.builtInActive = true
            }
            open.last = max(open.last, now)
            current = open
        } else if var open = current {
            switch source {
            case .camera where open.cameraActive: open.cameraActive = false
            case .builtIn where open.builtInActive: open.builtInActive = false
            default: return result
            }
            open.last = max(open.last, now)
            current = open
        }
        return result
    }

    /// Time has reached `now`: finishes the event once both sources have been quiet for the slack (or it ran too long) and
    /// forgets events older than the window. Returns the event this finished, if any.
    mutating func advance(to now: Duration) -> [Event] {
        var result: [Event] = []
        if var open = current {
            if now - open.started > limits.maximumEventLength {
                open.cameraActive = false
                open.builtInActive = false
                open.last = max(open.last, now)
                result.append(finish(open))
                current = nil
            } else if !open.isActive, now - open.last > limits.pairingSlack {
                result.append(finish(open))
                current = nil
            }
        }
        prune(at: now)
        return result
    }

    /// Ends whatever is open right now (the test stops).
    mutating func close(at now: Duration) -> [Event] {
        guard var open = current else { return [] }
        open.cameraActive = false
        open.builtInActive = false
        open.last = max(open.last, now)
        current = nil
        return [finish(open)]
    }

    /// The totals of the events that finished in the last `window`.
    func rolling(at now: Duration) -> MotionShadowTotals {
        var totals = MotionShadowTotals()
        var delays: [Duration] = []
        for event in finished where now - event.ended <= limits.window {
            switch event.outcome {
            case .both(let delay):
                totals.both += 1
                delays.append(delay)
            case .cameraOnly: totals.cameraOnly += 1
            case .builtInOnly: totals.builtInOnly += 1
            }
        }
        totals.medianDelaySeconds = Self.median(delays)
        return totals
    }

    /// Everything counted since the comparator was made (the median over the newest `retainedDelays`).
    func sinceStart() -> MotionShadowTotals {
        var totals = counted
        totals.medianDelaySeconds = Self.median(delays)
        return totals
    }

    private mutating func finish(_ open: Open) -> Event {
        let outcome: Outcome
        switch (open.cameraStart, open.builtInStart) {
        case (let camera?, let builtIn?):
            let delay = builtIn - camera
            outcome = .both(delay: delay)
            counted.both += 1
            delays.append(delay)
            if delays.count > limits.retainedDelays { delays.removeFirst(delays.count - limits.retainedDelays) }
        case (.some, nil):
            outcome = .cameraOnly
            counted.cameraOnly += 1
        default:
            outcome = .builtInOnly
            counted.builtInOnly += 1
        }
        let event = Event(outcome: outcome, started: open.started, ended: open.last)
        finished.append(event)
        if finished.count > limits.retainedEvents { finished.removeFirst(finished.count - limits.retainedEvents) }
        return event
    }

    private mutating func prune(at now: Duration) {
        let expired = finished.prefix { now - $0.ended > limits.window }.count
        if expired > 0 { finished.removeFirst(expired) }
    }

    /// The median in seconds; nil for none.
    static func median(_ durations: [Duration]) -> Double? {
        guard !durations.isEmpty else { return nil }
        let seconds = durations.map(\.timeInterval).sorted()
        let middle = seconds.count / 2
        return seconds.count % 2 == 1 ? seconds[middle] : (seconds[middle - 1] + seconds[middle]) / 2
    }
}

/// One camera's shadow test: takes the camera's own motion and the built-in detector's, compares them
/// (`MotionShadowComparator`), logs every finished event at INFO and a summary every hour, and answers the status's numbers.
/// It has no way to reach the event router: nothing it receives can become motion for HomeKit.
actor MotionShadowTest {
    static let tickInterval: Duration = .seconds(1)
    static let summaryInterval: Duration = .seconds(3_600)

    private let cameraName: String
    private let log: Log
    private let clock: ElapsedClock
    private let tick: Duration
    private let summaryEvery: Duration
    private var comparator: MotionShadowComparator
    private var ticker: Task<Void, Never>?
    private var lastSummary: Duration

    /// `clock` is a manual clock in tests; `limits` shrinks the comparator's windows.
    init(cameraName: String, log: Log, clock: any Clock<Duration> = ContinuousClock(), limits: MotionShadowComparator.Limits = .init(),
         tickInterval: Duration = MotionShadowTest.tickInterval, summaryInterval: Duration = MotionShadowTest.summaryInterval) {
        self.cameraName = cameraName
        self.log = log
        let clock = ElapsedClock(clock)
        self.clock = clock
        tick = tickInterval
        summaryEvery = summaryInterval
        comparator = MotionShadowComparator(limits: limits)
        lastSummary = clock.now()
    }

    /// Starts the timer that finishes quiet events and writes the hourly summary.
    func start() {
        guard ticker == nil else { return }
        let clock = clock, interval = tick
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(clock.now() + interval) } catch { return }
                guard let self else { return }
                await self.tickOnce()
            }
        }
    }

    /// Stops the timer and finishes what is open.
    func stop() {
        ticker?.cancel()
        ticker = nil
        report(comparator.close(at: clock.now()))
    }

    /// The camera's own event channel reported motion on or off.
    func cameraMotion(_ active: Bool) {
        report(comparator.record(.camera, active: active, at: clock.now()))
    }

    /// The built-in detector (running on the sub stream, reporting to nobody else) switched motion on or off.
    func builtInMotion(_ active: Bool) {
        report(comparator.record(.builtIn, active: active, at: clock.now()))
    }

    /// Finishes quiet events, forgets expired ones and writes the hourly summary when it is due.
    func tickOnce() {
        let now = clock.now()
        report(comparator.advance(to: now))
        if now - lastSummary >= summaryEvery {
            lastSummary = now
            let totals = comparator.rolling(at: now)
            log.info("Motion shadow test: \(cameraName), last 24 h: \(Self.describe(totals))")
        }
    }

    func totals() -> (last24Hours: MotionShadowTotals, sinceEnabled: MotionShadowTotals, eventInProgress: Bool) {
        let now = clock.now()
        return (comparator.rolling(at: now), comparator.sinceStart(), comparator.isEventOpen)
    }

    /// Tests: finished events kept, delays kept.
    var retained: (events: Int, delays: Int) { (comparator.retainedEventCount, comparator.retainedDelayCount) }

    private func report(_ events: [MotionShadowComparator.Event]) {
        for event in events { log.info("Motion shadow test: \(cameraName): \(Self.describe(event.outcome))") }
    }

    /// "both detected; built-in 0.8 s later", "camera only; built-in missed it", "built-in only; the camera reported nothing".
    static func describe(_ outcome: MotionShadowComparator.Outcome) -> String {
        switch outcome {
        case .both(let delay): "both detected; built-in \(describeOffset(delay.timeInterval))"
        case .cameraOnly: "camera only; built-in missed it"
        case .builtInOnly: "built-in only; the camera reported nothing"
        }
    }

    /// "5 both, 1 camera only, 2 built-in only; median delay 0.9 s later" (the built-in detector's start against the camera's).
    static func describe(_ totals: MotionShadowTotals) -> String {
        let median = totals.medianDelaySeconds.map { "median delay \(describeOffset($0))" } ?? "no delay measured"
        return "\(totals.both) both, \(totals.cameraOnly) camera only, \(totals.builtInOnly) built-in only; \(median)"
    }

    /// "0.8 s later", "1.2 s earlier", "at the same time".
    static func describeOffset(_ seconds: Double) -> String {
        let rounded = (abs(seconds) * 10).rounded() / 10
        if rounded == 0 { return "at the same time" }
        return String(format: "%.1f s", rounded) + (seconds > 0 ? " later" : " earlier")
    }
}
