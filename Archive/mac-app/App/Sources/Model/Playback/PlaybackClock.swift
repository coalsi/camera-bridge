import Foundation
import Synchronization

/// One clock for every cell. Counted in `TimeInterval` of a clock that stops in sleep (`ProcessInfo.systemUptime`), never in `Duration`:
/// `Duration.timeInterval` is `package` to BridgeSupport and PortabilityTests forbids inline attosecond arithmetic in App/Sources.
///
/// Three modes. `live`: the position is the Mac's clock now. `paused`: the position is a date. `playing`: the position is a date plus the
/// time that passed since it was set, so it runs at 1x and does not follow the wall clock when that is stepped (a changed time zone or an NTP step).
nonisolated final class PlaybackClock: Sendable {
    enum Mode: Sendable, Equatable { case live, paused, playing }

    struct State: Sendable, Equatable {
        var mode: Mode
        /// `live`: unused. `paused`: the position. `playing`: the position at `since`.
        var wall: Date
        /// `systemUptime` when `wall` was set (`playing` may be up to 0.1 s in the future: `play(from:startingIn:)`).
        var since: TimeInterval
    }

    /// A release within this many seconds of now, or after it, goes live.
    static let liveSnap: TimeInterval = 5
    /// The longest start delay `play(from:startingIn:)` honours: time for the cells to prime their decoders.
    static let maximumStartDelay: TimeInterval = 0.1

    private let uptime: @Sendable () -> TimeInterval
    private let wall: @Sendable () -> Date
    private let storage: Mutex<State>

    init(uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, wall: @escaping @Sendable () -> Date = { Date() }) {
        self.uptime = uptime
        self.wall = wall
        storage = Mutex(State(mode: .live, wall: wall(), since: uptime()))
    }

    var state: State { storage.withLock { $0 } }
    var isPlaying: Bool { state.mode == .playing }
    var isLive: Bool { state.mode == .live }

    /// live: `wall()`; playing: `state.wall` plus `max(0, uptime - since)`; paused: `state.wall`. `uptime` nil: now.
    func position(atUptime uptime: TimeInterval? = nil) -> Date {
        let state = storage.withLock { $0 }
        return Self.position(of: state, uptime: uptime ?? self.uptime(), wall: wall)
    }

    /// Paused at `date`: a plain store (no epoch), so a drag can never starve a cell.
    func scrub(to date: Date) {
        let since = uptime()
        storage.withLock { $0 = State(mode: .paused, wall: date, since: since) }
    }

    /// Plays from `date`, starting `delay` seconds from now (at most 0.1) so cells can prime.
    func play(from date: Date, startingIn delay: TimeInterval = 0) {
        let since = uptime() + min(max(delay, 0), Self.maximumStartDelay)
        storage.withLock { $0 = State(mode: .playing, wall: date, since: since) }
    }

    /// Paused where the position is now (a live clock pauses at the Mac's time).
    func pause() {
        let now = uptime(), wall = wall
        storage.withLock { state in
            state = State(mode: .paused, wall: Self.position(of: state, uptime: now, wall: wall), since: now)
        }
    }

    func goLive() {
        let now = uptime(), date = wall()
        storage.withLock { $0 = State(mode: .live, wall: date, since: now) }
    }

    /// Whether releasing at `date` goes live: `date >= wall() - liveSnap`.
    func shouldGoLive(releasingAt date: Date) -> Bool {
        date >= wall().addingTimeInterval(-Self.liveSnap)
    }

    /// `uptime` for the moment the clock's position is `date` while it plays from `state`: what a cell sleeps until to show a frame of that time.
    static func uptime(of date: Date, in state: State) -> TimeInterval {
        state.since + date.timeIntervalSince(state.wall)
    }

    private static func position(of state: State, uptime: TimeInterval, wall: @Sendable () -> Date) -> Date {
        switch state.mode {
        case .live: wall()
        case .paused: state.wall
        case .playing: state.wall.addingTimeInterval(max(0, uptime - state.since))
        }
    }
}
