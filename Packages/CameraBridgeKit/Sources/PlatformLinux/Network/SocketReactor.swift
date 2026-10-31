#if os(Linux)
import BridgeSupport
import CEpoll
import Foundation
import Glibc
import Synchronization

/// Every TCP socket wait on Linux, through one epoll instance and one thread, instead of a libdispatch read or write source per wait.
///
/// A source per wait (create, register, fire, cancel, free) cost the daemon half a CPU core in libdispatch's manager thread with ten
/// cameras streaming, and libdispatch's epoll backend finalizes a source a second time when the descriptor hangs up while the source is
/// being cancelled ("Source finalized twice", an illegal-instruction crash that stopped the daemon every one to three days, 2026-10).
/// Here a socket is added to the epoll set once, with its own token (never its descriptor number, which is reused after a close), and
/// each wait only re-arms it (`EPOLLONESHOT`, so an event is taken once and the socket stays quiet until someone waits again).
///
/// A socket is closed here too, after `EPOLL_CTL_DEL`: `close(token:)` fails the waits, then reads and drops what the peer still sends
/// until its FIN or `SocketDescriptor.lingerLimit` (a server's orderly close: closing at once would answer the peer's last segments
/// with a reset), then closes the descriptor.
final class SocketReactor: Sendable {
    static let shared = SocketReactor()

    enum Outcome: Sendable { case ready, timedOut, closed }
    enum Interest: Sendable { case readable, writable }
    typealias Handler = @Sendable (Outcome) -> Void

    private struct Waiter {
        var id: UInt64
        var interest: Interest
        var handler: Handler
    }

    private struct Registration {
        var descriptor: Int32
        var waiters: [Waiter] = []
        /// In the epoll set (added on the first wait).
        var added = false
        /// The event mask it is armed with; nil once an event (or nothing yet) disarmed it.
        var armed: UInt32?
        /// Closing: the waits are failed and the peer's last data is dropped until this time, then the descriptor is closed.
        var lingerUntil: ContinuousClock.Instant?
    }

    private struct Deadline: Comparable {
        var time: ContinuousClock.Instant
        var token: UInt64
        /// 0: the registration's linger.
        var waiter: UInt64
        static func < (lhs: Deadline, rhs: Deadline) -> Bool { lhs.time < rhs.time }
    }

    private struct State {
        var registrations: [UInt64: Registration] = [:]
        var nextToken: UInt64 = 1
        var nextWaiter: UInt64 = 1
        var deadlines = MinHeap<Deadline>()
        /// When the loop's `epoll_wait` returns by itself; a deadline before it wakes the loop through the pipe.
        var plannedWake: ContinuousClock.Instant?
    }

    private let epoll: Int32
    /// A pipe whose read end is in the epoll set (token 0): a byte written wakes the loop for an earlier deadline.
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let state = Mutex(State())

    // The kernel's epoll flags (<sys/epoll.h>; Swift's Glibc module does not import them).
    private static let epollIn: UInt32 = 0x001
    private static let epollOut: UInt32 = 0x004
    private static let epollErr: UInt32 = 0x008
    private static let epollHup: UInt32 = 0x010
    private static let epollRDHup: UInt32 = 0x2000
    private static let oneShot: UInt32 = 1 << 30

    private static let readMask = epollIn | epollRDHup
    private static let writeMask = epollOut
    /// What wakes a reader: data, the peer's FIN, or an error or hang-up (the reader's system call then says which).
    private static let readReady = epollIn | epollRDHup | epollHup | epollErr
    private static let writeReady = epollOut | epollHup | epollErr

    /// The daemon uses `shared`; tests make their own (each has its own thread, for the life of the process).
    init() {
        epoll = epoll_create1(Int32(EPOLL_CLOEXEC))
        var ends: [Int32] = [-1, -1]
        if pipe(&ends) != 0 { ends = [-1, -1] }
        wakeRead = ends[0]
        wakeWrite = ends[1]
        for end in ends where end >= 0 {
            _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
        }
        if epoll < 0 || wakeRead < 0 {
            Log(category: "transport").error("The socket reactor could not start (errno \(errno)); network waits will time out")
        } else {
            var event = epoll_event(events: Self.epollIn, data: epoll_data_t(u64: 0))
            _ = epoll_ctl(epoll, EPOLL_CTL_ADD, wakeRead, &event)
        }
        let thread = Thread { [self] in run() }
        thread.name = "socket-reactor"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Sockets registered and not yet closed (tests).
    var registrationCount: Int { state.withLock { $0.registrations.count } }

    // MARK: Registering, waiting, closing

    /// Takes over `descriptor` (the reactor closes it, through `close(token:)`); nothing is watched until the first wait.
    func register(_ descriptor: Int32) -> UInt64 {
        state.withLock { state in
            let token = state.nextToken
            state.nextToken += 1
            state.registrations[token] = Registration(descriptor: descriptor)
            return token
        }
    }

    /// Calls `handler` once: `.ready` when the socket is readable or writable (or has an error or hang-up), `.timedOut` at `deadline`,
    /// `.closed` when `close(token:)` comes first. False (and no call) when the socket is already closed.
    func wait(_ token: UInt64, for interest: Interest, until deadline: ContinuousClock.Instant?, handler: @escaping Handler) -> Bool {
        let (accepted, wake) = state.withLock { state -> (Bool, Bool) in
            guard var registration = state.registrations[token], registration.lingerUntil == nil else { return (false, false) }
            let id = state.nextWaiter
            state.nextWaiter += 1
            registration.waiters.append(Waiter(id: id, interest: interest, handler: handler))
            arm(token, &registration)
            state.registrations[token] = registration
            guard let deadline else { return (true, false) }
            state.deadlines.insert(Deadline(time: deadline, token: token, waiter: id))
            return (true, state.plannedWake.map { deadline < $0 } ?? true)
        }
        if wake { wakeLoop() }
        return accepted
    }

    /// Fails the waits with `.closed`, then lingers (reading and dropping, until the peer's FIN or `linger`) and closes the descriptor.
    func close(token: UInt64, linger: Duration) {
        let (failed, wake) = state.withLock { state -> ([Handler], Bool) in
            guard var registration = state.registrations[token], registration.lingerUntil == nil else { return ([], false) }
            let failed = registration.waiters.map(\.handler)
            registration.waiters = []
            let until = ContinuousClock.now + linger
            registration.lingerUntil = until
            guard linger > .zero, armForLinger(token, &registration) else {
                finish(token, registration, &state)
                return (failed, false)
            }
            state.registrations[token] = registration
            state.deadlines.insert(Deadline(time: until, token: token, waiter: 0))
            return (failed, state.plannedWake.map { until < $0 } ?? true)
        }
        if wake { wakeLoop() }
        for handler in failed { handler(.closed) }
    }

    // MARK: Arming (under the lock)

    /// Arms the registration for what its waiters want (the read and write masks together), unless it already is.
    private func arm(_ token: UInt64, _ registration: inout Registration) {
        var mask: UInt32 = 0
        for waiter in registration.waiters { mask |= waiter.interest == .readable ? Self.readMask : Self.writeMask }
        guard mask != 0, registration.armed != mask else { return }
        if control(token, &registration, events: mask | Self.oneShot) {
            registration.armed = mask
        } else {
            // epoll refused the descriptor: let the waiters retry their system call, which reports the real error.
            registration.armed = nil
            let ready = registration.waiters
            registration.waiters = []
            DispatchQueue.global().async { for waiter in ready { waiter.handler(.ready) } }
        }
    }

    /// Arms a closing socket for its last data (the waiters are gone, so only reading is watched).
    private func armForLinger(_ token: UInt64, _ registration: inout Registration) -> Bool {
        guard control(token, &registration, events: Self.readMask | Self.oneShot) else { return false }
        registration.armed = Self.readMask
        return true
    }

    /// `EPOLL_CTL_ADD` the first time, `EPOLL_CTL_MOD` after (either one falling back to the other).
    private func control(_ token: UInt64, _ registration: inout Registration, events: UInt32) -> Bool {
        guard epoll >= 0 else { return false }
        var event = epoll_event(events: events, data: epoll_data_t(u64: token))
        let first = registration.added ? EPOLL_CTL_MOD : EPOLL_CTL_ADD
        if epoll_ctl(epoll, first, registration.descriptor, &event) == 0 {
            registration.added = true
            return true
        }
        let code = errno
        let other = first == EPOLL_CTL_ADD ? EPOLL_CTL_MOD : EPOLL_CTL_ADD
        guard (first == EPOLL_CTL_ADD && code == EEXIST) || (first == EPOLL_CTL_MOD && code == ENOENT) else { return false }
        guard epoll_ctl(epoll, other, registration.descriptor, &event) == 0 else { return false }
        registration.added = true
        return true
    }

    /// Removes the registration and closes its descriptor (out of the epoll set first, so a reused number is never watched by mistake).
    private func finish(_ token: UInt64, _ registration: Registration, _ state: inout State) {
        if registration.added, epoll >= 0 {
            var unused = epoll_event()
            _ = epoll_ctl(epoll, EPOLL_CTL_DEL, registration.descriptor, &unused)
        }
        _ = Glibc.close(registration.descriptor)
        state.registrations[token] = nil
    }

    private func wakeLoop() {
        guard wakeWrite >= 0 else { return }
        var byte: UInt8 = 1
        _ = Glibc.write(wakeWrite, &byte, 1)
    }

    // MARK: The loop

    private func run() {
        guard epoll >= 0 else { return }
        let capacity = 256
        let events = UnsafeMutablePointer<epoll_event>.allocate(capacity: capacity)
        defer { events.deallocate() }
        while true {
            let timeout = state.withLock { state -> Int32 in
                let next = state.deadlines.peek?.time
                state.plannedWake = next
                guard let next else { return -1 }
                let remaining = next - ContinuousClock.now
                guard remaining > .zero else { return 0 }
                let (seconds, attoseconds) = remaining.components
                // Rounded up, so a deadline is never woken for a millisecond early and slept on again.
                return Int32(clamping: seconds * 1000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000)
            }
            let count = epoll_wait(epoll, events, Int32(capacity), timeout)
            if count < 0, errno != EINTR {
                Log(category: "transport").error("epoll_wait failed (errno \(errno))")
                usleep(10_000)
            }
            var calls: [(Handler, Outcome)] = []
            state.withLock { state in
                for index in 0..<max(0, Int(count)) {
                    let token = events[index].data.u64
                    if token == 0 {
                        drainWakePipe()
                    } else {
                        dispatch(token, events[index].events, &state, &calls)
                    }
                }
                expire(&state, &calls)
                // The loop is awake: a wait added from now until the next `epoll_wait` is seen when the timeout is computed.
                state.plannedWake = ContinuousClock.now
            }
            for (handler, outcome) in calls { handler(outcome) }
        }
    }

    private func drainWakePipe() {
        var buffer = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        while withUnsafeMutableBytes(of: &buffer, { read(wakeRead, $0.baseAddress, $0.count) }) > 0 {}
    }

    /// One event for `token`: wakes the waiters it satisfies and re-arms for the others, or drains a lingering socket.
    private func dispatch(_ token: UInt64, _ events: UInt32, _ state: inout State, _ calls: inout [(Handler, Outcome)]) {
        guard var registration = state.registrations[token] else { return }   // closed since the event was taken
        registration.armed = nil   // one-shot: the event disarmed it
        if registration.lingerUntil != nil {
            if Self.drain(registration.descriptor) || !armForLinger(token, &registration) {
                finish(token, registration, &state)
            } else {
                state.registrations[token] = registration
            }
            return
        }
        var remaining: [Waiter] = []
        for waiter in registration.waiters {
            let wanted = waiter.interest == .readable ? Self.readReady : Self.writeReady
            if events & wanted != 0 { calls.append((waiter.handler, .ready)) } else { remaining.append(waiter) }
        }
        registration.waiters = remaining
        arm(token, &registration)
        state.registrations[token] = registration
    }

    /// Reads and drops what is waiting; true at the peer's FIN or an error (the linger is over).
    private static func drain(_ descriptor: Int32) -> Bool {
        withUnsafeTemporaryAllocation(byteCount: 4096, alignment: 1) { buffer in
            for _ in 0..<64 {
                let count = recv(descriptor, buffer.baseAddress, buffer.count, Int32(MSG_DONTWAIT))
                if count > 0 { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return false }
                return true
            }
            return false
        }
    }

    /// Times out the waits whose deadline passed, and closes the sockets whose linger ended.
    private func expire(_ state: inout State, _ calls: inout [(Handler, Outcome)]) {
        let now = ContinuousClock.now
        while let next = state.deadlines.peek, next.time <= now {
            state.deadlines.removeFirst()
            guard var registration = state.registrations[next.token] else { continue }
            if next.waiter == 0 {
                if registration.lingerUntil != nil { finish(next.token, registration, &state) }
                continue
            }
            guard let index = registration.waiters.firstIndex(where: { $0.id == next.waiter }) else { continue }
            calls.append((registration.waiters.remove(at: index).handler, .timedOut))
            state.registrations[next.token] = registration
        }
    }
}

/// A binary min-heap (the reactor's deadlines).
struct MinHeap<Element: Comparable> {
    private var items: [Element] = []

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var peek: Element? { items.first }

    mutating func insert(_ element: Element) {
        items.append(element)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child] < items[parent] else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    @discardableResult
    mutating func removeFirst() -> Element? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let first = items.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1, right = left + 1
            var smallest = parent
            if left < items.count, items[left] < items[smallest] { smallest = left }
            if right < items.count, items[right] < items[smallest] { smallest = right }
            guard smallest != parent else { break }
            items.swapAt(parent, smallest)
            parent = smallest
        }
        return first
    }
}
#endif
