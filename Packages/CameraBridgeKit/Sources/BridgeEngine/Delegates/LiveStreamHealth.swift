import BridgeSupport
import Dispatch
import Foundation
import MediaCore
import RTP
import Synchronization

/// Every timing of a live stream's health ladder and of the transcoder's failure ladder. Injectable (`LiveStreamPipeline.Context.timing`):
/// the tests shorten them, a tuned build may lengthen them.
///
/// The pipeline recovers first (a keyframe at `recoverAfter`, a rebuilt transcoder with it); the session's own hard limits
/// (`LiveStreamSession`: no video 10 s after the start, none for 8 s mid-session) are the backstop, and `endAtStart` /
/// `endAtStall` are this layer's own, later, backstop for a session that has no such limits.
struct LiveStreamTiming: Sendable {
    /// How often the health check looks (1 Hz).
    var tick: Duration = .seconds(1)
    /// No video packet for this long while the camera delivers: force a keyframe and rebuild the transcoder.
    var recoverAfter: Duration = .seconds(4)
    /// Still nothing after this long since the start / for this long mid-session: end the stream (Home then retries).
    var endAtStart: Duration = .seconds(12)
    var endAtStall: Duration = .seconds(10)
    /// The camera counts as delivering when its newest frame is this young.
    var hubOnlineWindow: Duration = .seconds(2)
    /// Recoveries per stall before the stream is left to end.
    var maximumRecoveries = 3
    /// A transcoding stream without a keyframe for this long (3 × the 2 s keyframe interval) gets one forced; with none for
    /// `keyframeCadenceEnd` it ends.
    var keyframeCadence: Duration = .seconds(6)
    var keyframeCadenceEnd: Duration = .seconds(10)
    /// One transcode call, and the catch-up over a whole GOP, may take this long before the transcoder is abandoned.
    var transcodeDeadline: Duration = .seconds(2)
    var catchUpDeadline: Duration = .seconds(10)
    /// Making a transcoder (VTCompressionSessionCreate) may take this long.
    var creationDeadline: Duration = .seconds(5)
    /// Pauses before the retries of a transcoder that could not be made; after the last one the stream ends.
    var creationBackoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]
    /// A transcoder failing like this without a single frame out is given up on: the stream ends.
    var failureEnd: Duration = .seconds(3)
    /// Failures rebuild the transcoder at most this often.
    var rebuildSpacing: Duration = .milliseconds(500)
    /// Self-check: the first `probeCount` keyframes, then one GOP per `probeInterval`; one probe may take `probeDeadline`.
    var probeCount = 3
    var probeInterval: Duration = .seconds(60)
    var probeDeadline: Duration = .seconds(5)
    /// A passthrough stream whose controller asks for keyframes this many times in this window switches to transcoding.
    var passthroughKeyframeRequests = 2
    var passthroughKeyframeWindow: Duration = .seconds(10)
    /// A replay of more frames than this, or a measured GOP longer than this, makes the camera be asked for a keyframe.
    var longGOPFrames = 60
    var longGOP: Duration = .seconds(2)
    /// The camera is asked for a keyframe at most this often by one stream.
    var cameraKeyframeSpacing: Duration = .seconds(10)

    static let standard = LiveStreamTiming()
}

/// At most one yes per `interval` (a log line or a request that may be wanted many times a second).
final class RateLimiter: Sendable {
    private let interval: Duration
    private let last = Mutex<ContinuousClock.Instant?>(nil)

    init(interval: Duration) {
        self.interval = interval
    }

    func allow(now: ContinuousClock.Instant = .now) -> Bool {
        last.withLock { last in
            if let previous = last, now - previous < interval { return false }
            last = now
            return true
        }
    }
}

/// What a live stream's health check sees at one tick.
struct LiveStreamMetrics: Sendable {
    /// Since the stream started.
    var elapsed: Duration
    /// Video packets the session has sent, and how long ago the count last grew (nil: never).
    var videoPackets: Int
    var sinceVideoPacket: Duration?
    /// How long ago the camera's hub received its newest video frame (nil: never since it last reconnected).
    var hubAge: Duration?
    var transcoding: Bool
    /// How long ago the pipeline last produced a keyframe (nil: none yet).
    var sinceKeyframeOut: Duration?
    var hubFrameRate: Double?
    /// "decoder hardware, encoder software" and the like, for the log lines.
    var codecs: String = ""
}

/// The health ladder of one live stream (audit 2 F3, section C): force an IDR, rebuild the transcoder, end the stream, one
/// plain log line each. A pure state machine over `LiveStreamMetrics`: the pipeline asks it once per tick and carries out
/// what it says; the tests drive it with a virtual clock.
struct LiveStreamHealth: Sendable {
    enum Action: Equatable, Sendable {
        case info(String)
        case warning(String)
        case forceKeyframe
        /// Abandon the transcoder and rebuild it from the camera's newest GOP.
        case rebuild(String)
        /// End the stream (the controller then starts it again); the text is the reason, already logged.
        case end(String)
    }

    let timing: LiveStreamTiming
    /// "starting", "ok", "recovering: ...", "ended: ..."; shown with the session's status.
    private(set) var summary = "starting"

    private var recoveredAtStart = false
    private var recoveries = 0
    private var lastRecovery: Duration?
    private var announcedOffline = false
    private var lastCadenceForce: Duration?
    private var ended = false
    private var probeFailures = 0
    private var blankFailures = 0

    init(timing: LiveStreamTiming) {
        self.timing = timing
    }

    mutating func evaluate(_ metrics: LiveStreamMetrics) -> [Action] {
        guard !ended else { return [] }
        let hubDelivering = metrics.hubAge.map { $0 <= timing.hubOnlineWindow } ?? false
        var actions: [Action] = []

        if metrics.videoPackets == 0 {
            // Start: nothing has gone out yet.
            if !hubDelivering {
                if metrics.elapsed >= timing.recoverAfter, !announcedOffline {
                    announcedOffline = true
                    summary = "waiting for the camera"
                    actions.append(.info("\(Self.seconds(metrics.elapsed)) s after the start no picture has gone out and the camera is not delivering "
                                         + "(\(metrics.hubAge.map { "its last frame was \(Self.seconds($0)) s ago" } ?? "no frame since it connected")); waiting for it"))
                }
                if metrics.elapsed >= timing.endAtStart { return end("the camera delivered no picture for \(Self.seconds(metrics.elapsed)) s after the start", into: &actions) }
                return actions
            }
            announcedOffline = false
            if metrics.elapsed >= timing.endAtStart {
                return end("no picture was produced in \(Self.seconds(metrics.elapsed)) s although the camera delivers (\(Self.rate(metrics.hubFrameRate)); "
                           + "\(metrics.codecs.isEmpty ? "codecs unknown" : metrics.codecs)); recovery did not help", into: &actions)
            }
            if metrics.elapsed >= timing.recoverAfter, !recoveredAtStart {
                recoveredAtStart = true
                summary = "recovering: no picture after \(Self.seconds(metrics.elapsed)) s"
                actions.append(.warning("no picture \(Self.seconds(metrics.elapsed)) s after the start although the camera delivers (\(Self.rate(metrics.hubFrameRate)); "
                                        + "\(metrics.codecs.isEmpty ? "codecs unknown" : metrics.codecs)); "
                                        + (metrics.transcoding ? "forcing a keyframe and rebuilding the transcoder" : "asking the camera for a keyframe and rebuilding the video path")))
                actions.append(.forceKeyframe)
                actions.append(.rebuild("no picture \(Self.seconds(metrics.elapsed)) s after the start"))
            }
            return actions
        }

        // Mid-session.
        let silent = metrics.sinceVideoPacket ?? .zero
        if silent >= timing.recoverAfter {
            if !hubDelivering {
                if !announcedOffline {
                    announcedOffline = true
                    summary = "camera stopped delivering"
                    actions.append(.info("no video for \(Self.seconds(silent)) s and the camera stopped delivering "
                                         + "(\(metrics.hubAge.map { "its last frame was \(Self.seconds($0)) s ago" } ?? "no frame since it reconnected")); waiting for it"))
                }
                if silent >= timing.endAtStall { return end("the camera stopped delivering for \(Self.seconds(silent)) s", into: &actions) }
                return actions
            }
            announcedOffline = false
            if silent >= timing.endAtStall {
                return end("no video went out for \(Self.seconds(silent)) s although the camera delivers (\(Self.rate(metrics.hubFrameRate)); "
                           + "\(metrics.codecs.isEmpty ? "codecs unknown" : metrics.codecs)); recovery did not help", into: &actions)
            }
            if recoveries < timing.maximumRecoveries, lastRecovery.map({ metrics.elapsed - $0 >= timing.recoverAfter }) ?? true {
                recoveries += 1
                lastRecovery = metrics.elapsed
                summary = "recovering: no video for \(Self.seconds(silent)) s"
                actions.append(.warning("no video for \(Self.seconds(silent)) s although the camera delivers (\(Self.rate(metrics.hubFrameRate)); "
                                        + "\(metrics.codecs.isEmpty ? "codecs unknown" : metrics.codecs)); "
                                        + (metrics.transcoding ? "forcing a keyframe and rebuilding the transcoder" : "asking the camera for a keyframe")
                                        + " (attempt \(recoveries))"))
                actions.append(.forceKeyframe)
                if metrics.transcoding { actions.append(.rebuild("no video for \(Self.seconds(silent)) s")) }
            }
            return actions
        }
        announcedOffline = false
        if silent < .seconds(1) {   // video is flowing: whatever was recovered worked
            recoveries = 0
            recoveredAtStart = true
            summary = "ok"
        }

        // Keyframe cadence: a transcoding stream whose encoder stopped producing keyframes cannot be joined or repaired.
        if metrics.transcoding, let sinceKeyframe = metrics.sinceKeyframeOut {
            if sinceKeyframe >= timing.keyframeCadenceEnd {
                return end("the encoder produced no keyframe for \(Self.seconds(sinceKeyframe)) s", into: &actions)
            }
            if sinceKeyframe >= timing.keyframeCadence, lastCadenceForce.map({ metrics.elapsed - $0 >= timing.recoverAfter }) ?? true {
                lastCadenceForce = metrics.elapsed
                actions.append(.warning("the encoder produced no keyframe for \(Self.seconds(sinceKeyframe)) s (it makes one every 2 s); forcing one"))
                actions.append(.forceKeyframe)
            }
        }
        return actions
    }

    /// The self-check's verdict on a sample of the outgoing stream.
    mutating func noteProbe(_ outcome: LiveSelfCheck.Outcome) -> [Action] {
        guard !ended else { return [] }
        var actions: [Action] = []
        switch outcome {
        case .passed:
            probeFailures = 0
            blankFailures = 0
        case .inconclusive:
            break
        case .failed(let reason, let definitive):
            probeFailures += 1
            if definitive || probeFailures >= 2 {
                actions.append(.warning("live self-check FAILED: \(reason)"))
                return end("the self-check of the outgoing video failed: \(reason)", into: &actions)
            }
            actions.append(.warning("live self-check failed: \(reason); rebuilding the transcoder and checking again"))
            actions.append(.rebuild("the self-check failed: \(reason)"))
        case .blank(let reason):
            blankFailures += 1
            if blankFailures >= 2 {
                actions.append(.warning("live self-check FAILED: \(reason)"))
                return end("the picture sent is blank although the camera's is not: \(reason)", into: &actions)
            }
            actions.append(.warning("live self-check: \(reason); rebuilding the transcoder and checking again"))
            actions.append(.rebuild("the picture sent was blank: \(reason)"))
        }
        return actions
    }

    /// The pipeline ended the stream (for this or another reason): nothing more to check.
    mutating func noteEnded(_ reason: String) {
        ended = true
        summary = "ended: \(reason)"
    }

    private mutating func end(_ reason: String, into actions: inout [Action]) -> [Action] {
        ended = true
        summary = "ended: \(reason)"
        actions.append(.warning("ending it (\(reason)); Home will start it again"))
        actions.append(.end(reason))
        return actions
    }

    static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f", duration / .seconds(1))
    }

    static func rate(_ fps: Double?) -> String {
        fps.map { String(format: "%.0f fps in", $0) } ?? "frames in"
    }
}

/// What the transcoder's failures lead to (audit 2 F2): the first failure drops the frame, the next rebuilds the transcoder (at
/// most every `rebuildSpacing`; the retry uses a software decoder when the failing frame was a keyframe), and failures for
/// `failureEnd` without a frame out end the stream.
struct TranscodeFailureLadder: Sendable {
    enum Step: Equatable, Sendable {
        case drop
        case rebuild(software: Bool)
        case end(String)
    }

    private let timing: LiveStreamTiming
    private(set) var consecutive = 0
    private(set) var rebuilds = 0
    private var firstFailure: ContinuousClock.Instant?
    private var lastRebuild: ContinuousClock.Instant?
    /// A keyframe failed since the last rebuild or success.
    private var keyframeFailed = false

    init(timing: LiveStreamTiming) {
        self.timing = timing
    }

    /// Whether this is the first failure of an incident (the one the log line is for).
    var isFirstOfIncident: Bool { consecutive == 1 && rebuilds == 0 }

    mutating func failed(keyframe: Bool, at now: ContinuousClock.Instant, error: String) -> Step {
        consecutive += 1
        keyframeFailed = keyframeFailed || keyframe
        firstFailure = firstFailure ?? now
        if let first = firstFailure, now - first >= timing.failureEnd {
            return .end("the transcoder failed for \(LiveStreamHealth.seconds(now - first)) s without producing a frame (\(rebuilds) rebuilds; last error: \(error))")
        }
        guard consecutive >= 2, lastRebuild.map({ now - $0 >= timing.rebuildSpacing }) ?? true else { return .drop }
        consecutive = 0
        rebuilds += 1
        lastRebuild = now
        defer { keyframeFailed = false }
        return .rebuild(software: keyframeFailed)
    }

    mutating func succeeded(at now: ContinuousClock.Instant) {
        consecutive = 0
        keyframeFailed = false
        firstFailure = nil
        if let last = lastRebuild, now - last >= .seconds(10) { rebuilds = 0 }
    }
}

/// Blocking codec work (a VideoToolbox session's creation or teardown) off Swift concurrency's cooperative threads, which a
/// wedged call would otherwise take for good: with as many wedged calls as the Mac has cores the whole runtime, HomeKit's
/// handlers included, stops. A call that overruns its deadline is abandoned, left to finish on its own thread.
enum CodecOffload {
    private static let queue = DispatchQueue(label: "CameraBridge.LiveCodecOffload", qos: .userInitiated, attributes: .concurrent)

    /// `work` on its own thread; throws `DeadlineExceeded` once `deadline` passes, however long `work` goes on.
    /// `discard` receives what `work` returns after the deadline passed (nobody uses it: tear it down).
    static func run<Value: Sendable>(deadline: Duration, discard: (@Sendable (Value) -> Void)? = nil,
                                     _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withDeadline(deadline) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                queue.async { continuation.resume(with: Result { try work() }) }
            }
        } late: { result in
            if case .success(let value) = result { discard?(value) }
        }
    }

    /// `work` on its own thread; nobody waits for it (tearing down a transcoder).
    static func fireAndForget(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}

// MARK: - Self-check

/// The live view's self-check (audit 2 section C): takes the first keyframes of the stream, then one GOP a minute, and sees
/// them as the controller does: the access units are packetized the way the session does it, the packets checked (sequence
/// numbers, marker bits, parameter sets ahead of the keyframe, nothing lost in reassembly), and the access units decoded by a
/// separate low-priority decoder (one probe at a time in the whole process). A stream that fails in a way no controller could
/// show — a keyframe that does not decode, a picture of another size than its SPS says, a blank or all-zero (green) picture
/// while the camera's is real — ends, and Home starts it again. A probe that cannot run (no decoder, too slow) says nothing:
/// it never affects the stream.
enum LiveSelfCheck {
    enum Outcome: Sendable, Equatable {
        case passed(String)
        /// Something is wrong with the stream. `definitive`: no controller could show this picture.
        case failed(String, definitive: Bool)
        /// The picture is blank or uninitialised although the camera's is not.
        case blank(String)
        /// The probe could not decide (no decoder, a decode that took too long, resources busy).
        case inconclusive(String)
    }

    /// What the frames are checked against.
    struct Expectation: Sendable {
        var width: Int
        var height: Int
        /// The rank of the highest H.264 profile the controller selected (`MediaFit.rank`); nil for passthrough.
        var maximumProfileRank: Int?
        var payloadType: UInt8
        /// Largest SRTP packet (the packetizer gets this minus the authentication tag).
        var maxPacketSize: Int
        /// The camera's own picture (a transcoder's decoded input), when sampled.
        var inputPicture: PictureStatistics?
        /// The transcoder's stream (its output size and profile are known).
        var transcoded: Bool
    }

    /// Frames in one probe: a keyframe and up to this many deltas that follow it.
    static let framesPerProbe = 16
    /// Pictures above this many pixels are not probed (4K passthrough: decoding is the Mac's biggest job already).
    static let maximumPixels = 1920 * 1088

    private static let running = Mutex(false)

    /// Claims the process-wide probe slot; whoever got it calls `release()`.
    static func tryAcquire() -> Bool {
        running.withLock { running in
            guard !running else { return false }
            running = true
            return true
        }
    }

    static func release() {
        running.withLock { $0 = false }
    }

    /// Runs one probe (the slot is the caller's). Never throws.
    static func run(frames: [EncodedVideoFrame], expectation: Expectation, codecs: any MediaCodecs, deadline: Duration) async -> Outcome {
        guard let first = frames.first, first.isKeyframe else { return .inconclusive("no keyframe to check") }
        if first.format.width * first.format.height > maximumPixels { return .inconclusive("the picture is too large to check") }
        if let reason = structuralFailure(frames: frames, expectation: expectation) {
            return .failed(reason, definitive: true)
        }
        do {
            return try await withDeadline(deadline) { try await decode(frames: frames, expectation: expectation, codecs: codecs) }
        } catch is DeadlineExceeded {
            return .inconclusive("decoding the sample took more than \(LiveStreamHealth.seconds(deadline)) s")
        } catch is CancellationError {
            return .inconclusive("cancelled")
        } catch {
            return .inconclusive("no decoder for the sample (\(error))")
        }
    }

    /// Everything that needs no decoder: profile, packetization and reassembly.
    static func structuralFailure(frames: [EncodedVideoFrame], expectation: Expectation) -> String? {
        guard let first = frames.first else { return nil }
        if first.format.codec != .h264 { return "the keyframe is \(first.format.codec.rawValue), live video is H.264 only" }
        if expectation.transcoded {
            if first.format.width != expectation.width || first.format.height != expectation.height {
                return "the keyframe is \(first.format.width)×\(first.format.height), not the \(expectation.width)×\(expectation.height) the controller selected"
            }
            if let limit = expectation.maximumProfileRank {
                guard let rank = MediaFit.profileRank(first.format.profile) else { return "the stream's H.264 profile \(first.format.profile) is not Baseline, Main or High" }
                if rank > limit { return "the stream's H.264 profile (\(first.format.profile)) is above the one the controller selected" }
            }
        }
        guard first.nalUnits.contains(where: { NALUnits.h264Type($0) == 5 }) || first.nalUnits.contains(where: { NALUnits.h264Type($0) == 1 }) else {
            return "the keyframe holds no picture data"
        }
        var packetizer = H264Packetizer(payloadType: expectation.payloadType, ssrc: 0x5E1F_C4EC, maxPacketSize: max(300, expectation.maxPacketSize - 10),
                                        initialSequence: 1000)
        var expectedSequence: UInt16?
        for (index, frame) in frames.enumerated() {
            let packets = packetizer.packetize(frame, rtpTimestamp: UInt32(truncatingIfNeeded: frame.pts.value))
            guard !packets.isEmpty else { return "frame \(index) produced no packets" }
            for (position, packet) in packets.enumerated() {
                if let expectedSequence, packet.sequenceNumber != expectedSequence { return "packet sequence numbers are not contiguous at frame \(index)" }
                expectedSequence = packet.sequenceNumber &+ 1
                if packet.marker != (position == packets.count - 1) { return "frame \(index) has the marker bit on the wrong packet" }
                if packet.payload.count + 12 > max(300, expectation.maxPacketSize - 10) { return "a packet of frame \(index) is larger than the negotiated size" }
            }
            guard let rebuilt = reassemble(packets) else { return "the packets of frame \(index) cannot be reassembled" }
            if frame.isKeyframe {
                // The parameter sets come first, then the picture.
                guard rebuilt.count >= 3, NALUnits.h264Type(rebuilt[0]) == 7, NALUnits.h264Type(rebuilt[1]) == 8 else {
                    return "the keyframe's packets do not start with its SPS and PPS"
                }
            }
            let body = rebuilt.filter { ![7, 8].contains(NALUnits.h264Type($0)) }
            let original = frame.nalUnits.filter { ![7, 8, 9].contains(NALUnits.h264Type($0)) }
            guard body == original else { return "frame \(index) does not survive packetization (\(body.count) NAL units back, \(original.count) sent)" }
        }
        return nil
    }

    /// The NAL units of one access unit's packets (STAP-A, FU-A and single NAL units), or nil when they do not fit together.
    static func reassemble(_ packets: [RTPPacket]) -> [Data]? {
        var nals: [Data] = []
        var fragment: Data?
        for packet in packets {
            let payload = packet.payload
            guard let header = payload.first else { return nil }
            switch header & 0x1F {
            case 24:
                var offset = payload.startIndex + 1
                while offset + 2 <= payload.endIndex {
                    let size = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                    offset += 2
                    guard size > 0, offset + size <= payload.endIndex else { return nil }
                    nals.append(Data(payload[offset..<(offset + size)]))
                    offset += size
                }
            case 28:
                guard payload.count >= 2 else { return nil }
                let indicator = header
                let fu = payload[payload.startIndex + 1]
                let body = payload.dropFirst(2)
                if fu & 0x80 != 0 {
                    guard fragment == nil else { return nil }
                    fragment = Data([(indicator & 0xE0) | (fu & 0x1F)]) + body
                } else {
                    guard fragment != nil else { return nil }
                    fragment?.append(body)
                }
                if fu & 0x40 != 0, let done = fragment {
                    nals.append(done)
                    fragment = nil
                }
            case 1...23:
                nals.append(Data(payload))
            default:
                return nil
            }
        }
        return fragment == nil ? nals : nil
    }

    private static func decode(frames: [EncodedVideoFrame], expectation: Expectation, codecs: any MediaCodecs) async throws -> Outcome {
        guard let first = frames.first else { return .inconclusive("no frames") }
        let decoder = try codecs.makeProbeDecoder(format: first.format)
        defer { decoder.invalidate() }
        // What the Mac's decoder makes of the camera's own stream (passthrough) says nothing about the controller's: it decides
        // nothing, however it ends. A stream our own encoder made is judged.
        func verdict(_ reason: String, definitive: Bool) -> Outcome {
            expectation.transcoded ? .failed(reason, definitive: definitive)
                                   : .inconclusive("\(reason); the camera's own stream is passed through, so this decoder's answer is not held against it")
        }
        var decoded = 0
        var firstPicture: (any DecodedVideoFrame)?
        for (index, frame) in frames.enumerated() {
            let picture: (any DecodedVideoFrame)?
            do {
                picture = try await decoder.decode(frame)
            } catch {
                if index == 0 { return verdict("the keyframe does not decode (\(error))", definitive: false) }
                return verdict("frame \(index) after the keyframe does not decode (\(error))", definitive: false)
            }
            if let picture {
                decoded += 1
                if firstPicture == nil { firstPicture = picture }
            }
        }
        guard let firstPicture else { return verdict("the keyframe decoded to no picture", definitive: false) }
        if firstPicture.width != first.format.width || firstPicture.height != first.format.height {
            return verdict("the keyframe's SPS says \(first.format.width)×\(first.format.height) but it decodes to \(firstPicture.width)×\(firstPicture.height)", definitive: true)
        }
        if let statistics = firstPicture.pictureStatistics(), statistics.isBlank {
            guard expectation.transcoded else { return .inconclusive("the decoded picture of the camera's own stream is blank") }
            let input = expectation.inputPicture
            if let input, !input.isBlank {
                return .blank(statistics.isUninitialized ? "the picture sent is all zero (it would show green) while the camera's picture is real"
                                                         : "the picture sent is black while the camera's picture is real")
            }
            if input == nil, statistics.isUninitialized {
                return .blank("the picture sent is all zero (it would show green)")
            }
            // Both blank: a dark camera (night, covered lens), nothing to fix.
            return .passed("the camera's own picture is black")
        }
        return .passed("\(frames.count) frames, \(decoded) pictures, \(first.format.width)×\(first.format.height)")
    }
}

/// When the self-check takes a sample: the first `count` keyframes, then one per `interval` (a keyframe and the frames after it).
struct LiveSelfCheckPlan: Sendable {
    private let count: Int
    private let interval: Duration
    private var taken = 0
    private var lastTaken: ContinuousClock.Instant?
    private var previousTaken: ContinuousClock.Instant?
    private var collecting: [EncodedVideoFrame]?

    init(count: Int, interval: Duration) {
        self.count = count
        self.interval = interval
    }

    /// The sample `offer` returned was not taken (the probe slot was busy): it does not count against the first `count`.
    mutating func declined() {
        taken = max(0, taken - 1)
        lastTaken = previousTaken
    }

    /// The frames that follow come from another transcoder or path: a sample in the making would mix two streams.
    mutating func restart() {
        collecting = nil
    }

    /// Offers the next outgoing frame; returns a sample when one is complete.
    mutating func offer(_ frame: EncodedVideoFrame, at now: ContinuousClock.Instant) -> [EncodedVideoFrame]? {
        if frame.isKeyframe {
            let finished = collecting
            collecting = nil
            if taken < count || lastTaken.map({ now - $0 >= interval }) ?? true {
                taken += 1
                previousTaken = lastTaken
                lastTaken = now
                collecting = [frame]
            }
            return finished
        }
        guard collecting != nil else { return nil }
        collecting?.append(frame)
        if let sample = collecting, sample.count >= LiveSelfCheck.framesPerProbe {
            collecting = nil
            return sample
        }
        return nil
    }
}
