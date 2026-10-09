import Foundation

/// Tells "alive but receiving nothing" from a healthy controller, with the evidence in its receiver reports (RFC 3550 §6.4).
/// A controller whose packets never reach it keeps sending RTCP (that is all the session's keepalive looks at), but its
/// receiver reports do not mention our video SSRC, or report the same highest sequence number again and again while we send,
/// or report (nearly) everything lost. This was a live-view spinner that never ended.
///
/// A judgement needs a symptom that held for `blindAfter`, at least `minimumReports` reports since our first video packet,
/// enough video packets sent meanwhile (a stalled source is a different failure), a session of `minimumSessionAge`, and a
/// recent report (when reports stop, the controller timeout takes over). Reports before any video was sent say nothing.
struct ControllerReceptionMonitor {
    enum Symptom: String, Equatable {
        /// Every receiver report since our first video packet lacks a block for our video SSRC: it has received none.
        case noReportBlock = "the controller's receiver reports do not mention our video"
        /// The reports repeat one highest sequence number while we keep sending: nothing new arrives.
        case nothingNew = "the controller's receiver reports show no new video arriving"
        /// The reports say (nearly) every packet was lost.
        case heavyLoss = "the controller's receiver reports say nearly every video packet was lost"
    }

    struct Verdict: Equatable {
        var symptom: Symptom
        /// When the symptom began (the report that started it).
        var since: ContinuousClock.Instant
        var reports: Int
        var packetsSentSince: Int
    }

    private struct Run {
        var since: ContinuousClock.Instant
        var sentAtStart: Int
        var reports = 1
        var sequence: UInt32?
    }

    private let timings: LiveStreamTimings
    private let videoSSRC: UInt32
    private let startedAt: ContinuousClock.Instant

    private var packetsSent = 0
    private var firstVideoAt: ContinuousClock.Instant?
    private var lastReportAt: ContinuousClock.Instant?
    private(set) var reportsSinceFirstVideo = 0
    /// The newest block about our video.
    private(set) var lastBlock: RTCPReportBlock?
    private var missing: Run?
    private var frozen: Run?
    private var lossy: Run?

    init(videoSSRC: UInt32, timings: LiveStreamTimings, startedAt: ContinuousClock.Instant) {
        self.videoSSRC = videoSSRC
        self.timings = timings
        self.startedAt = startedAt
    }

    /// `total` video packets have been sent so far (successful sends).
    mutating func videoSent(total: Int, at now: ContinuousClock.Instant) {
        packetsSent = total
        if firstVideoAt == nil, total > 0 { firstVideoAt = now }
    }

    /// A receiver or sender report from the controller with these blocks (on any of the session's sockets); blocks about
    /// other sources are ignored, a report without a block about our video counts as lacking it.
    mutating func report(blocks: [RTCPReportBlock], at now: ContinuousClock.Instant) {
        guard let firstVideoAt, now >= firstVideoAt else { return }
        reportsSinceFirstVideo += 1
        lastReportAt = now
        guard let block = blocks.first(where: { $0.ssrc == videoSSRC }) else {
            if missing == nil { missing = Run(since: now, sentAtStart: packetsSent) } else { missing?.reports += 1 }
            frozen = nil
            lossy = nil
            return
        }
        missing = nil
        lastBlock = block
        if var run = frozen, run.sequence == block.extendedHighestSequence {
            run.reports += 1
            frozen = run
        } else {
            frozen = Run(since: now, sentAtStart: packetsSent, sequence: block.extendedHighestSequence)
        }
        if block.fractionLost >= timings.heavyLossFraction {
            if lossy == nil { lossy = Run(since: now, sentAtStart: packetsSent) } else { lossy?.reports += 1 }
        } else {
            lossy = nil
        }
    }

    /// Whether the controller counts as not receiving our video at `now`, and why; nil when it is fine (or nothing can be told).
    func verdict(at now: ContinuousClock.Instant) -> Verdict? {
        guard now - startedAt >= timings.minimumSessionAge, reportsSinceFirstVideo >= timings.minimumReports,
              let lastReportAt, now - lastReportAt <= timings.staleReportAfter else { return nil }
        func judged(_ run: Run?, _ symptom: Symptom, reports: Int, packets: Int) -> Verdict? {
            guard let run, now - run.since >= timings.blindAfter, run.reports >= reports, packetsSent - run.sentAtStart >= packets else { return nil }
            return Verdict(symptom: symptom, since: run.since, reports: run.reports, packetsSentSince: packetsSent - run.sentAtStart)
        }
        return judged(missing, .noReportBlock, reports: timings.minimumReports, packets: timings.minimumPacketsSent)
            ?? judged(frozen, .nothingNew, reports: 2, packets: timings.minimumPacketsSentWhileFrozen)
            ?? judged(lossy, .heavyLoss, reports: 2, packets: timings.minimumPacketsSent)
    }
}
