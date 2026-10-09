import Foundation

/// What a `sendto` error means for a live stream.
enum SendFailure {
    enum Kind: Equatable {
        /// The kernel's send queue is full or the call was interrupted: sending again a moment later works.
        case transient
        /// The address, route or network is gone (or the system refuses us): nothing sent after this succeeds until it
        /// comes back, so a failure that lasts ends the session.
        case fatal
        /// Anything else (a message too long, …): the packet is lost.
        case other
    }

    static func classify(_ code: Int32) -> Kind {
        switch code {
        case ENOBUFS, EAGAIN, EINTR, ENOMEM: .transient
        case EADDRNOTAVAIL, ENETDOWN, ENETUNREACH, EHOSTUNREACH, EPERM: .fatal
        default: .other
        }
    }

    /// The errno behind `error`, nil for an error that is not a failed system call (a closed socket, a bad address).
    static func code(of error: any Error) -> Int32? {
        if case .system(_, let code)? = error as? UDPSocketError { return code }
        return nil
    }

    /// "ENOBUFS (No buffer space available)".
    static func describe(_ code: Int32) -> String {
        let name: String
        switch code {
        case ENOBUFS: name = "ENOBUFS"
        case EAGAIN: name = "EAGAIN"
        case EINTR: name = "EINTR"
        case ENOMEM: name = "ENOMEM"
        case EADDRNOTAVAIL: name = "EADDRNOTAVAIL"
        case ENETDOWN: name = "ENETDOWN"
        case ENETUNREACH: name = "ENETUNREACH"
        case EHOSTUNREACH: name = "EHOSTUNREACH"
        case EPERM: name = "EPERM"
        case EMSGSIZE: name = "EMSGSIZE"
        default: name = "errno \(code)"
        }
        return "\(name) (\(String(cString: strerror(code))))"
    }

    static func describe(_ codes: [Int32]) -> String {
        codes.map { describe($0) }.joined(separator: ", ")
    }

    /// Whether the person may have denied this app the Local Network permission (macOS answers EHOSTUNREACH for the LAN, a
    /// firewall EPERM).
    static func suggestsLocalNetworkDenied(_ code: Int32) -> Bool {
        code == EHOSTUNREACH || code == EPERM
    }
}

/// Sends a frame's datagrams in paced chunks and retries the transient errors, without holding an actor: the caller
/// passes how to send one datagram and how to wait. Spreading a keyframe of 100–300 kB (85–250 packets) over a few
/// milliseconds keeps it inside the kernel's send queue, which a back-to-back burst overruns (`ENOBUFS`, silently lost
/// packets, a frame the decoder never completes).
struct PacedTransmission {
    struct Outcome: Equatable {
        var sent = 0
        /// Datagrams that never went out (a failure that was not transient, or one that outlived the retries).
        var lost = 0
        /// Times a datagram was sent again.
        var retries = 0
        /// How many datagrams each chunk held.
        var chunkSizes: [Int] = []
        /// Every failed attempt by errno (a retried attempt counts too).
        var failures: [Int32: Int] = [:]
        /// The socket was closed: nothing more can be sent.
        var closed = false
        /// The task was cancelled before everything went out.
        var cancelled = false
    }

    /// Chunk sizes for `count` datagrams: at most `pacingChunkPackets` each, except that the gaps between them must not add
    /// up to more than `maximumFrameDelay` (bigger chunks then).
    static func chunkSizes(count: Int, timings: LiveStreamTimings) -> [Int] {
        guard count > 0 else { return [] }
        let chunk = max(1, timings.pacingChunkPackets)
        var chunks = (count + chunk - 1) / chunk
        if timings.pacingGap > .zero {
            let gapsAllowed = max(0, Int(timings.maximumFrameDelay / timings.pacingGap))
            chunks = min(chunks, gapsAllowed + 1)
        }
        let base = count / chunks, extra = count % chunks
        return (0..<chunks).map { base + ($0 < extra ? 1 : 0) }
    }

    /// Sends datagrams `0..<count` in order through `send(index)`, waiting `pause(duration)` between chunks and before a retry.
    static func run(count: Int, timings: LiveStreamTimings, send: (Int) throws -> Void, pause: (Duration) async -> Void) async -> Outcome {
        var outcome = Outcome()
        var index = 0
        let sizes = chunkSizes(count: count, timings: timings)
        for (chunkNumber, size) in sizes.enumerated() {
            if chunkNumber > 0, timings.pacingGap > .zero {
                await pause(timings.pacingGap)
                if Task.isCancelled {
                    outcome.cancelled = true
                    outcome.lost += count - index
                    return outcome
                }
            }
            outcome.chunkSizes.append(size)
            for _ in 0..<size {
                var attempt = 0
                while true {
                    do {
                        try send(index)
                        outcome.sent += 1
                        break
                    } catch UDPSocketError.closed {
                        outcome.closed = true
                        outcome.lost += count - index
                        return outcome
                    } catch {
                        let code = SendFailure.code(of: error) ?? -1
                        outcome.failures[code, default: 0] += 1
                        if SendFailure.classify(code) == .transient, attempt < timings.sendRetries {
                            attempt += 1
                            outcome.retries += 1
                            await pause(timings.sendRetryDelay)
                            if Task.isCancelled {
                                outcome.cancelled = true
                                outcome.lost += count - index
                                return outcome
                            }
                            continue
                        }
                        outcome.lost += 1
                        break
                    }
                }
                index += 1
            }
        }
        return outcome
    }
}

/// Send failures of one socket: which errnos were seen (each is logged once), and whether a fatal one persists.
struct SendFailureTracker {
    private(set) var counts: [Int32: Int] = [:]
    private(set) var successes = 0
    private var fatalSince: ContinuousClock.Instant?
    private var fatalCode: Int32?

    /// Notes a send burst (or one RTCP packet): its successes and failures by errno. Returns the errnos never seen before.
    /// Any success breaks a run of fatal failures; a burst of only fatal ones starts (or goes on with) one.
    @discardableResult
    mutating func record(successes sent: Int, failures: [Int32: Int], at now: ContinuousClock.Instant) -> [Int32] {
        successes += sent
        var fresh: [Int32] = []
        for (code, count) in failures.sorted(by: { $0.key < $1.key }) {
            if counts[code] == nil { fresh.append(code) }
            counts[code, default: 0] += count
        }
        if sent > 0 {
            fatalSince = nil
            fatalCode = nil
        } else if let code = failures.keys.sorted().first(where: { SendFailure.classify($0) == .fatal }) {
            if fatalSince == nil { fatalSince = now }
            fatalCode = code
        }
        return fresh
    }

    /// The fatal errno that has gone on for `duration` with no send succeeding, nil otherwise.
    func persistentFatal(at now: ContinuousClock.Instant, after duration: Duration) -> Int32? {
        guard let fatalSince, let fatalCode, now - fatalSince >= duration else { return nil }
        return fatalCode
    }
}

/// Spreads a replay (the newest GOP, handed over as fast as the pipeline can) at `factor` times the negotiated bit rate.
/// A token bucket (a tenth of a second of that rate) is spent by every frame; a frame that finds it empty waits for the
/// deficit only when it is a catch-up frame: its media time is ahead of the wall clock (replayed frames are packed closer
/// than real time), so waiting costs the viewer nothing. A live frame, which cannot be ahead, never waits (a stream above the
/// negotiated bit rate must not queue up latency), and its debt is forgiven.
struct CatchUpPacer {
    /// How far (seconds) a frame's media time must run ahead of the wall clock to count as catch-up.
    static let leadThreshold = 0.03

    private let rate: Double?
    private let capacity: Double
    private var tokens: Double
    private var refilled: ContinuousClock.Instant?
    private var origin: (arrival: ContinuousClock.Instant, pts: Double)?

    /// `maxBitrateKbps` nil (or zero): no pacing.
    init(maxBitrateKbps: Int?, factor: Double) {
        let bytesPerSecond = maxBitrateKbps.map { Double($0) * 1_000 / 8 * factor }.flatMap { $0 > 0 ? $0 : nil }
        rate = bytesPerSecond
        capacity = (bytesPerSecond ?? 0) / 10
        tokens = capacity
    }

    /// How long to wait before sending a frame of `bytes` that reached the session at `now` with presentation time `pts` (seconds).
    mutating func delay(bytes: Int, pts: Double, now: ContinuousClock.Instant) -> Duration {
        guard let rate else { return .zero }
        let start = origin ?? (now, pts)
        origin = start
        if let refilled { tokens = min(capacity, tokens + rate * ((now - refilled) / .seconds(1))) }
        refilled = now
        tokens -= Double(bytes)
        guard tokens < 0 else { return .zero }
        let lead = (pts - start.pts) - (now - start.arrival) / .seconds(1)
        guard lead > Self.leadThreshold else {
            tokens = 0
            return .zero
        }
        return .seconds(-tokens / rate)
    }
}
