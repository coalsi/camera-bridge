import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore

/// Two-way audio for one camera (plan W3-1 item 3, integration brief §5.4): the controllers' return audio (Opus) →
/// `AudioTranscoding` into the talkback sink's `inputFormat` (read after `open()`, e.g. PCMU 8 kHz) → `TalkbackSink.send`.
///
/// A camera has one talkback channel (Hikvision closes any other session when one opens), so every live session of the
/// camera shares this bridge and its one sink: the session that talks holds it, and other sessions' return audio is
/// dropped until the holder's session ends or it stays silent for `handoverIdle`. The sink is opened on the first
/// return packet and closed when the last session that used it ends (`release(_:)`) or on `close()`. A sink that fails
/// to open, or fails while sending, is closed and retried after `retryDelay` (packets meanwhile are dropped).
///
/// The open is single-flight and runs on its own: the packet that starts it returns at once. While it is in flight (slow
/// cameras and NVRs take over a second) every return packet is dropped, the opener's included, and the holder stays — a
/// second open would end the first session on the camera's single channel, and closing the redundant sink would close
/// the channel the bridge kept. (The opener's packets queued behind an open it waited for would reach the camera in one
/// burst once it returned, and the camera would play everything late by the open time for as long as the viewer talks.)
/// Once open, the holder keeps the channel for `handoverIdle` as if it had just spoken. Closing a sink (camera-facing:
/// an HTTP request for Hikvision) waits at most `closeLimit` (`CameraRuntime.stopLimit`) and is then left to finish on
/// its own, so it never holds up a live stream's stop or a camera stop.
actor TalkbackBridge {
    private let makeSink: @Sendable () -> (any TalkbackSink)?
    private let codecs: any MediaCodecs
    private let retryDelay: Duration
    private let handoverIdle: Duration
    private let closeLimit: Duration
    private let log: Log
    private var sink: (any TalkbackSink)?
    /// A sink's `open()` is in flight.
    private var opening = false
    /// Bumped whenever a sink is opened or dropped: a send that failed on an older sink leaves the current one alone.
    private var sinkGeneration = 0
    private var transcoder: (converter: any AudioTranscoding, input: AudioFormat)?
    private var retryAt: ContinuousClock.Instant?
    private var unsupported = false
    private var closed = false
    /// The session whose audio reaches the camera, and when it last sent some.
    private var holder: (session: UUID, lastSent: ContinuousClock.Instant)?
    /// Sessions that sent return audio (held or dropped) and have not ended yet.
    private var users: Set<UUID> = []
    /// Recently ended sessions: a send still in flight when its session ended must not make it a user again.
    private var ended: [UUID] = []
    private(set) var framesSent = 0

    init(makeSink: @escaping @Sendable () -> (any TalkbackSink)?, codecs: any MediaCodecs, retryDelay: Duration = .seconds(5),
         handoverIdle: Duration = .seconds(1), closeLimit: Duration = CameraRuntime.stopLimit, log: Log) {
        self.makeSink = makeSink
        self.codecs = codecs
        self.retryDelay = retryDelay
        self.handoverIdle = handoverIdle
        self.closeLimit = closeLimit
        self.log = log
    }

    var isOpen: Bool { sink != nil }

    /// Return audio from `session`'s controller. A cancelled caller (its session ending) sends nothing: its cancellation
    /// would reach the camera-facing send and break the sink other sessions share. The packet that finds no sink starts
    /// the camera-facing open and returns: the open runs on its own, apart from the caller and its cancellation (cancelled
    /// half-way, it would leave the camera's two-way session open — Hikvision: busy for every other client until the
    /// camera times it out), and that packet and every one until the channel is open are dropped.
    func send(_ frame: EncodedAudioFrame, from session: UUID) async {
        guard !Task.isCancelled, !closed, !unsupported, !frame.data.isEmpty, !ended.contains(session) else { return }
        let now = ContinuousClock.now
        users.insert(session)
        if opening { return }   // the sink is being opened: dropped, nothing changes hands, and no second open starts
        if let holder, holder.session != session, now - holder.lastSent < handoverIdle { return }   // another viewer talks
        if holder?.session != session { log.debug("Talkback goes to live session \(session)") }
        holder = (session, now)
        if sink == nil {
            if let retryAt, now < retryAt { return }
            guard let created = makeSink() else {
                unsupported = true
                log.notice("This camera cannot play audio from Home (no talkback channel)")
                return
            }
            opening = true
            Task { await self.open(created) }   // neither awaited by nor cancelled with the caller
            return
        }
        guard let sink else { return }
        let generation = sinkGeneration
        do {
            if transcoder?.input != frame.format {
                let output = sink.inputFormat
                transcoder = (try codecs.makeAudioTranscoder(input: frame.format,
                                                             output: AudioEncoderSettings(codec: output.codec, sampleRate: output.sampleRate,
                                                                                          channels: output.channels)), frame.format)
            }
            guard let converter = transcoder?.converter else { return }
            for converted in try converter.transcode(frame) {
                try await sink.send(converted)
                framesSent += 1
            }
        } catch {
            log.warning("Talkback failed (\(Redact.string(String(describing: error)))); retrying in \(MediaFit.seconds(retryDelay)) s")
            guard sinkGeneration == generation, self.sink != nil else { return }   // closed or replaced meanwhile
            self.sink = nil
            sinkGeneration &+= 1
            transcoder = nil
            retryAt = .now + retryDelay
            await closeBounded(sink)
        }
    }

    /// Opens `created` (camera-facing) for `send`. Once open, a sink no session wants any more (or the camera stopped
    /// meanwhile) is closed; otherwise it carries the holder's next packet, and the holder keeps it for `handoverIdle`.
    private func open(_ created: any TalkbackSink) async {
        do {
            try await created.open()
        } catch {
            opening = false
            log.warning("Talkback could not be opened (\(Redact.string(String(describing: error)))); retrying in \(MediaFit.seconds(retryDelay)) s")
            retryAt = .now + retryDelay
            return
        }
        opening = false
        guard !closed, !users.isEmpty else {   // every session that used it ended (or the camera stopped) meanwhile
            await closeBounded(created)
            return
        }
        sink = created
        sinkGeneration &+= 1
        if let holder { self.holder = (holder.session, .now) }
        log.info("Talkback opened (\(created.inputFormat.codec.rawValue) \(created.inputFormat.sampleRate) Hz)")
    }

    /// `session` ended: it no longer holds the channel, and the sink closes once no session that used it is left.
    func release(_ session: UUID) async {
        ended.append(session)
        if ended.count > 64 { ended.removeFirst(ended.count - 64) }
        users.remove(session)
        if holder?.session == session { holder = nil }
        guard users.isEmpty else { return }
        await closeSink()
    }

    /// The camera stops: closes the sink for good.
    func close() async {
        closed = true
        users.removeAll()
        holder = nil
        await closeSink()
    }

    private func closeSink() async {
        transcoder = nil
        guard let sink else { return }
        self.sink = nil
        sinkGeneration &+= 1
        await closeBounded(sink)
        log.info("Talkback closed after \(framesSent) frames")
    }

    /// Closes `sink`, waiting at most `closeLimit`: a camera that does not answer its close request (Hikvision: up to
    /// the HTTP timeout) must not hold up a stop. The close is then cancelled and left to finish on its own.
    private func closeBounded(_ sink: any TalkbackSink) async {
        do {
            try await withDeadline(closeLimit, followsCancellation: false) { await sink.close() }
        } catch {
            log.warning("Talkback channel close not answered within \(MediaFit.seconds(closeLimit)) s; leaving it")
        }
    }
}
