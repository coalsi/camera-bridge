import BridgeSupport
import FMP4
import Foundation
import MediaCore
import Synchronization

/// One camera's recorder (Mac spec 4.2, 4.3, 5, 13): a `MediaHub.subscribe(from: .prebuffer(.zero))` subscription cut into fragments of at most
/// 2.5 s of decode time (every keyframe, 900 frames and 16 MiB too), muxed with `FMP4Muxer` (`continuation: true` for a fragment that starts on a delta
/// frame) and appended to plain fragmented MP4 files through an `ArchiveFileWriter`; the store hears about every file and fragment through its
/// `ArchiveWriteTarget`. The actor never waits for the disk and never touches it: the writer's own queue does.
///
/// Time: a file has one anchor, the first frame's `wallClock + hub.wallClockOffset` (the host's clock instead when that is more than 60 s from it).
/// Inside the file time is media time: a fragment starts at `anchor + (decode time - the file's first decode time) / 90 kHz`, and that derived time
/// is what `prft` and the index carry. If a fragment's measured wall time differs from the derived one by more than 1 s twice in a row, the file ends.
///
/// One continuity rule: any break writes out the open group (without `nextDecodeTime`, so its last frame is not stretched), writes the sidecar,
/// closes the file, and the next keyframe opens a new one. Breaks: `hub.discontinuityCount` changed; a decode time at or before the last, or a
/// forward step above max(1.5 s, 4 frame intervals); a parameter-set change or a muxer error; a change of the camera's audio format; a frame over
/// 16 MiB; 15 s without video (found by the tick); the wall divergence. A planned roll at a keyframe (900 s or 2 GiB) is not a break: the open group
/// ends exactly at that keyframe.
actor CameraArchiveRecorder {
    private enum CloseReason: String {
        case roll, idle, discontinuity, divergence, formatChanged, audioChanged, muxFailure, tooLarge, sessionEnded, stopped, clockJump
    }

    /// The video frames waiting for the next cut.
    private struct Group {
        var video: [EncodedVideoFrame] = []
        var bytes = 0
        var firstDecode: Int64 = 0
    }

    /// The state of one file from its first keyframe on. The writer (and so the file) exists from the first fragment.
    private final class FileRun {
        let anchor: Date
        let fromCamera: Bool
        let format: VideoFormat
        let formatKey: FormatKey
        let firstDecode: Int64
        var lastDecode: Int64
        var lastInterval: Int64 = 3_000
        var group = Group()
        var plan: AudioPlan?
        /// Camera audio seen before the plan is decided.
        var rawAudio: [EncodedAudioFrame] = []
        /// Audio in the track's format waiting for the cut that takes it.
        var audio: [EncodedAudioFrame] = []
        var muxer: FMP4Muxer?
        var writer: ArchiveFileWriter?
        var fileBytes: UInt64 = 0
        var fragments = 0
        var previousBackToKey: Int?
        var divergentStreak = 0
        var lastSyncAt: TimeInterval
        var rollRequested = false

        init(anchor: Date, fromCamera: Bool, format: VideoFormat, firstDecode: Int64, uptime: TimeInterval) {
            self.anchor = anchor
            self.fromCamera = fromCamera
            self.format = format
            formatKey = FormatKey(format)
            self.firstDecode = firstDecode
            lastDecode = firstDecode
            lastSyncAt = uptime
        }

        /// Seconds from the file's first frame to a frame with this decode time.
        func seconds(_ decode: Int64) -> Double { Double(decode - firstDecode) / 90_000 }
    }

    /// Video formats compared the way the muxer compares them: the codec and the parameter sets, without trailing zero bytes, as a set.
    private struct FormatKey: Equatable {
        var codec: VideoCodec
        var sets: Set<Data>

        init(_ format: VideoFormat) {
            codec = format.codec
            sets = Set(format.parameterSets.map { set in
                var trimmed = set
                while trimmed.last == 0 { trimmed.removeLast() }
                return trimmed
            })
        }

        func matches(_ other: FormatKey) -> Bool {
            codec == other.codec && (sets.isEmpty || other.sets.isEmpty || sets == other.sets)
        }
    }

    // MARK: State

    private let cameraID: UUID
    private let wantsSound: Bool
    private let audioEnabled: Bool
    private let hub: MediaHub
    private let target: any ArchiveWriteTarget
    private let codecs: any MediaCodecs
    private let directory: ArchiveCameraDirectory
    private let signal: ChangeSignal
    private let tuning: RecorderTuning
    private let writeQueue: DispatchQueue
    private let log: Log

    private let published = Mutex(CameraArchiveStatus(state: .waiting("waiting for the camera")))

    private var stopped = false
    private var tickTask: Task<Void, Never>?
    private var consumer: Task<Void, Never>?
    private var subscription: MediaSubscription?
    private var session = 0
    private var sessionGeneration = -1
    private var seenDiscontinuities = 0
    private var lastVideoAt: TimeInterval?
    private var run: FileRun?
    private var closing: [ArchiveFileWriter] = []
    private var abandoned: [ArchiveFileWriter] = []
    private var ownPause: ArchivePause?
    private var failureSentence: String?
    private var failures = 0
    private var retryNotBefore: TimeInterval?
    private var freshFailures = 0
    private var unrecordable: String?
    private var unrecordableUntil: TimeInterval?
    private var keyframeNote = KeyframeIntervalNote()
    private var soundNote: ArchiveNote?
    /// Samples taken in so far (a counter, for tests to wait on).
    private(set) var samplesHandled = 0

    /// `writeQueue`: the serial queue of this camera's disk work; every recorder of one camera uses the same one (`RecorderHost` keeps it).
    init(camera: CameraConfiguration, hub: MediaHub, target: any ArchiveWriteTarget, codecs: any MediaCodecs,
         naming: ArchivePlatformPolicy.DirectoryNaming, signal: ChangeSignal, tuning: RecorderTuning,
         writeQueue: DispatchQueue = DispatchQueue(label: "CameraBridge.NVR.writer", qos: .utility)) {
        cameraID = camera.id
        wantsSound = camera.nvrRecordSound
        audioEnabled = camera.audioEnabled
        self.hub = hub
        self.target = target
        self.codecs = codecs
        self.signal = signal
        self.tuning = tuning
        self.writeQueue = writeQueue
        directory = ArchiveCameraDirectory(naming: naming, cameraID: camera.id, cameraName: camera.name, fileSystem: tuning.fileSystem)
        log = Log(category: "NVR", cameraID: camera.id)
        soundNote = camera.nvrRecordSound && !camera.audioEnabled ? RecorderNotes.soundCameraAudioOff : nil
    }

    /// The recorder's status, readable from any thread (`CameraStatus.nvr`).
    nonisolated var status: CameraArchiveStatus { published.withLock { $0 } }

    // MARK: Lifecycle

    /// Subscribes when the store allows writing (so the hub's newest group is replayed from now on), then keeps watching the store on a tick.
    /// Does no disk I/O.
    func start() async {
        guard tickTask == nil, !stopped else { return }
        await tick()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let period = await self?.tickPeriod() else { return }
                try? await Task.sleep(for: period)
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    /// Writes out what is open and closes the file, within `RecorderTuning.closeDeadline` whatever the drive does.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        tickTask?.cancel()
        tickTask = nil
        consumer?.cancel()
        consumer = nil
        subscription?.cancel()
        subscription = nil
        session += 1
        closeFile(.stopped)
        // Every file that is closing finishes (or the deadline passes and the drive is declared dead).
        let writers = closing
        let finished = OneShot()
        let remaining = Mutex(writers.count)
        if writers.isEmpty { finished.fire() }
        for writer in writers {
            writer.drain {
                if remaining.withLock({ value -> Bool in
                    value -= 1
                    return value == 0
                }) { finished.fire() }
            }
        }
        _ = try? await withDeadline(tuning.closeDeadline, followsCancellation: false) { await finished.wait() }
        for writer in writers where !writer.isIdle {
            writer.abandon()
            log.warning("The recordings drive did not answer while the file was closing")
        }
        publish(CameraArchiveStatus(state: .waiting("waiting for the camera"), notes: []))
    }

    private func tickPeriod() -> Duration {
        run != nil ? tuning.recordingTick : tuning.waitingTick
    }

    /// Everything that is not a sample: the store's say, an idle camera, a stalled drive.
    private func tick() async {
        guard !stopped else { return }
        let now = tuning.uptime()
        checkDiscontinuity()
        evaluateStall(now)
        if run != nil, let last = lastVideoAt, now - last >= ArchiveConstants.idleCloseAfter {
            closeFile(.idle)
        }
        closing.removeAll { $0.isIdle }
        if ownPause != nil, abandoned.allSatisfy(\.isIdle) {
            abandoned.removeAll()
            ownPause = nil
        }
        let state = target.writeState
        if state.folder == nil || state.pause != nil || !state.isReady || ownPause != nil {
            if subscription != nil { endSession(reason: .sessionEnded) }
        } else if subscription != nil, state.generation != sessionGeneration {
            endSession(reason: .sessionEnded)
            await subscribe(state, now)
        } else if subscription == nil {
            await subscribe(state, now)
        }
        publishStatus(state)
    }

    private func subscribe(_ state: ArchiveWriteState, _ now: TimeInterval) async {
        if let retry = retryNotBefore, now < retry { return }
        let new = await hub.subscribe(from: .prebuffer(.zero), bufferLimit: 900)
        guard !stopped, subscription == nil else {
            new.cancel()
            return
        }
        subscription = new
        sessionGeneration = state.generation
        seenDiscontinuities = hub.discontinuityCount
        session += 1
        let mine = session
        consumer = Task { [weak self] in
            for await sample in new.samples {
                guard let self else { return }
                await self.handle(sample, session: mine)
            }
        }
    }

    /// Stops reading the hub and closes the file; frames still queued for the old subscription are ignored.
    private func endSession(reason: CloseReason) {
        consumer?.cancel()
        consumer = nil
        subscription?.cancel()
        subscription = nil
        session += 1
        closeFile(reason)
    }

    // MARK: Samples

    private func handle(_ sample: MediaSample, session mine: Int) {
        guard mine == session, !stopped else { return }
        samplesHandled += 1
        switch sample {
        case .video(let frame): processVideo(frame)
        case .audio(let frame): processAudio(frame)
        }
    }

    private static func decode(_ frame: EncodedVideoFrame) -> Int64 {
        (frame.dts ?? frame.pts).converted(to: ArchiveConstants.videoTimescale).value
    }

    private static func payloadBytes(_ frame: EncodedVideoFrame) -> Int {
        frame.nalUnits.reduce(0) { $0 + $1.count + 4 }
    }

    private func checkDiscontinuity() {
        let count = hub.discontinuityCount
        guard count != seenDiscontinuities else { return }
        seenDiscontinuities = count
        keyframeNote.restart()
        closeFile(.discontinuity)
    }

    private func processVideo(_ frame: EncodedVideoFrame) {
        let now = tuning.uptime()
        checkDiscontinuity()
        lastVideoAt = now
        let decode = Self.decode(frame)
        let size = Self.payloadBytes(frame)
        if frame.isKeyframe, keyframeNote.observe(keyframeAt: decode) { publishStatus(target.writeState) }

        if let run {
            if let reason = breakReason(run, frame, decode, size) {
                closeFile(reason)
            } else if frame.isKeyframe, run.rollRequested || run.seconds(decode) >= tuning.fileMaximumDuration || run.fileBytes + UInt64(run.group.bytes) >= tuning.fileMaximumBytes {
                // A planned roll: the open group ends exactly at this keyframe.
                _ = flushGroup(nextDecode: decode)
                closeFile(.roll, flush: false)
            } else if shouldCut(run, frame, decode, size), let reason = flushGroup(nextDecode: decode) {
                closeFile(reason, flush: false)
            }
        }
        if let run {
            add(frame, decode, size, to: run)
            return
        }
        // No open file: a keyframe starts one (anything else is dropped).
        guard frame.isKeyframe, size <= Self.maximumGroupBytes, mayStartFile(now) else { return }
        let measured = frame.wallClock.addingTimeInterval(hub.wallClockOffset)
        let host = tuning.now()
        let fromCamera = abs(measured.timeIntervalSince(host)) <= ArchiveConstants.anchorSkewLimit
        let new = FileRun(anchor: fromCamera ? measured : host, fromCamera: fromCamera, format: frame.format, firstDecode: decode, uptime: now)
        run = new
        add(frame, decode, size, to: new)
    }

    /// 16 MiB less room for the box headers and the sample table of up to 900 samples.
    private static let maximumGroupBytes = ArchiveConstants.fragmentMaximumBytes - 64 * 1_024

    private func add(_ frame: EncodedVideoFrame, _ decode: Int64, _ size: Int, to run: FileRun) {
        if run.group.video.isEmpty { run.group.firstDecode = decode }
        run.group.video.append(frame)
        run.group.bytes += size
        if decode > run.lastDecode { run.lastInterval = max(1, decode - run.lastDecode) }
        run.lastDecode = decode
    }

    private func shouldCut(_ run: FileRun, _ frame: EncodedVideoFrame, _ decode: Int64, _ size: Int) -> Bool {
        guard !run.group.video.isEmpty else { return false }
        return frame.isKeyframe
            || Double(decode - run.group.firstDecode) / 90_000 >= ArchiveConstants.fragmentMaximumDuration
            || run.group.video.count >= ArchiveConstants.fragmentMaximumFrames
            || run.group.bytes + size > Self.maximumGroupBytes
    }

    private func breakReason(_ run: FileRun, _ frame: EncodedVideoFrame, _ decode: Int64, _ size: Int) -> CloseReason? {
        if frame.format != run.format, !run.formatKey.matches(FormatKey(frame.format)) { return .formatChanged }
        if size > Self.maximumGroupBytes { return .tooLarge }
        if decode <= run.lastDecode { return .clockJump }
        let step = decode - run.lastDecode
        let limit = max(Int64(ArchiveConstants.forwardStepFloor * 90_000), Int64(ArchiveConstants.forwardStepFrameIntervals) * run.lastInterval)
        if step > limit { return .clockJump }
        return nil
    }

    private func mayStartFile(_ now: TimeInterval) -> Bool {
        let state = target.writeState
        guard state.isReady, state.pause == nil, state.folder != nil, state.generation == sessionGeneration, ownPause == nil else { return false }
        if let retry = retryNotBefore, now < retry { return false }
        if let until = unrecordableUntil, now < until { return false }
        return abandoned.allSatisfy(\.isIdle)
    }

    // MARK: Audio

    private func processAudio(_ frame: EncodedAudioFrame) {
        checkDiscontinuity()
        guard let run, wantsSound, audioEnabled else { return }
        guard let plan = run.plan else {
            if run.rawAudio.count < 2_000 { run.rawAudio.append(frame) }
            return
        }
        switch plan {
        case .none(let reason):
            if reason == .noSound, wantsSound, audioEnabled, run.writer != nil { run.rollRequested = true }
        case .passthrough(let format):
            if frame.format == format { appendAudio(frame, to: run) } else { closeFile(.audioChanged) }
        case .transcode(let source, let converter, _):
            guard frame.format == source else {
                closeFile(.audioChanged)
                return
            }
            do {
                for converted in try converter.transcode(frame) { appendAudio(converted, to: run) }
            } catch {
                run.plan = .none(.failed)
                soundNote = RecorderNotes.soundFailed
                log.warning("Camera audio could not be converted; recording without sound")
                publishStatus(target.writeState)
            }
        }
    }

    private func appendAudio(_ frame: EncodedAudioFrame, to run: FileRun) {
        if run.audio.count < 2_000 { run.audio.append(frame) }
    }

    // MARK: Fragments

    /// Muxes the open group and queues it. `nextDecode`: the decode time of the frame that closes the group (nil at a break, so the last frame is not
    /// stretched). Returns why the file must end now, nil to go on.
    private func flushGroup(nextDecode: Int64?) -> CloseReason? {
        guard let run, !run.group.video.isEmpty else { return nil }
        let frames = run.group.video
        let firstDecode = run.group.firstDecode
        let state = target.writeState
        guard let root = state.folder else { return .sessionEnded }
        if run.writer == nil, state.pause != nil || !state.isReady {
            run.group = Group()                                    // nothing was written yet and the store says not now: do not create a file for it
            return .sessionEnded
        }

        if run.plan == nil {
            let plan = AudioPlan.choose(video: run.format, firstAudio: run.rawAudio.first?.format, wantsSound: wantsSound, audioEnabled: audioEnabled, codecs: codecs)
            run.plan = plan
            soundNote = plan.note
            if plan.trackFormat != nil {
                let source = plan.sourceFormat
                for raw in run.rawAudio where raw.format == source {
                    if case .transcode(_, let converter, _) = plan {
                        if let converted = try? converter.transcode(raw) { converted.forEach { appendAudio($0, to: run) } }
                    } else {
                        appendAudio(raw, to: run)
                    }
                }
            }
            run.rawAudio = []
        }
        if run.muxer == nil {
            do {
                run.muxer = try FMP4Muxer(configuration: FMP4Configuration(video: run.format, audio: run.plan?.trackFormat, videoTimescale: ArchiveConstants.videoTimescale,
                                                                          writeProducerReferenceTime: true))
            } catch {
                return muxFailed(error, first: true)
            }
        }
        guard var muxer = run.muxer else { return nil }

        let boundary = nextDecode.map { MediaTime(value: $0, timescale: ArchiveConstants.videoTimescale) }
        var audio: [EncodedAudioFrame] = []
        if let boundary {
            audio = run.audio.filter { $0.pts < boundary }
            run.audio.removeAll { $0.pts < boundary }
        } else {
            audio = run.audio
            run.audio = []
        }
        let stamped = frames.map { frame -> EncodedVideoFrame in
            var copy = frame
            copy.wallClock = run.anchor.addingTimeInterval(run.seconds(Self.decode(frame)))
            return copy
        }
        let fragment: Data
        let record: CBIndexFragmentRecord
        let offset: UInt64
        let initialization = muxer.initializationSegment()
        do {
            fragment = try muxer.fragment(video: stamped, audio: audio, nextDecodeTime: boundary, continuation: !frames[0].isKeyframe)
            offset = run.writer == nil ? UInt64(initialization.count) : run.fileBytes
            record = try FragmentIndexer.record(try FragmentIndexer.measure(fragment), offset: offset, firstMediaTime: 0, previousBackToKey: run.previousBackToKey)
        } catch {
            return muxFailed(error, first: run.writer == nil)
        }
        run.muxer = muxer
        freshFailures = 0

        let startWallMs = Int64((run.anchor.timeIntervalSince1970 * 1_000).rounded())
        let writer: ArchiveFileWriter
        if let existing = run.writer {
            writer = existing
        } else {
            let request = ArchiveFileWriter.Request(root: root, directory: directory, anchor: run.anchor, timeZone: tuning.timeZone)
            let created = ArchiveFileWriter(camera: cameraID, queue: writeQueue, request: request, fileSystem: tuning.fileSystem, target: target, uptime: tuning.uptime, log: log,
                                            onOpened: { [weak self] id in Task { await self?.writerOpened(id) } },
                                            onFailure: { [weak self] id, sentence in Task { await self?.writerFailed(id, sentence) } })
            created.open(initialization: initialization, startWallMs: startWallMs, hasAudio: run.plan?.trackFormat != nil)
            run.writer = created
            run.fileBytes = UInt64(initialization.count)
            writer = created
        }
        let now = tuning.uptime()
        let sync = now - run.lastSyncAt >= ArchiveConstants.syncInterval
        if sync { run.lastSyncAt = now }
        writer.append(fragment, record: record, synchronize: sync)
        run.fileBytes += UInt64(fragment.count)
        run.fragments += 1
        run.previousBackToKey = Int(record.backToKey)
        run.group = Group()

        var reason: CloseReason?
        if run.fromCamera {
            let derived = run.anchor.addingTimeInterval(run.seconds(firstDecode))
            let measured = frames[0].wallClock.addingTimeInterval(hub.wallClockOffset)
            run.divergentStreak = abs(measured.timeIntervalSince(derived)) > ArchiveConstants.wallDivergenceLimit ? run.divergentStreak + 1 : 0
            if run.divergentStreak >= 2 { reason = .divergence }
        }
        evaluateStall(now)
        publishStatus(state)
        return self.run === run ? reason : nil
    }

    /// The muxer refused the group. Three failures in a row on the first fragment of fresh files stop the attempts for a minute.
    private func muxFailed(_ error: any Error, first: Bool) -> CloseReason {
        let sentence = Self.sentence(for: error)
        log.warning("Cannot record this stream: \(sentence)")
        if first {
            freshFailures += 1
            if freshFailures >= 3 {
                unrecordable = sentence
                unrecordableUntil = tuning.uptime() + tuning.unrecordableRetry
                freshFailures = 0
            }
        }
        run?.group = Group()
        return .muxFailure
    }

    static func sentence(for error: any Error) -> String {
        switch error as? FMP4Error {
        case .invalidParameterSets(let reason)?: return reason
        case .invalidVideoDimensions?: return "the picture size is not usable"
        case .unsupportedAudio(let reason)?: return reason
        case .videoFormatChanged?: return "the video format changed"
        case .nonMonotonicTimestamps?: return "the video times do not increase"
        case .fragmentTooLarge?: return "a fragment is too large"
        case .some: return "the video cannot be stored"
        case nil: return "the video cannot be stored"
        }
    }

    // MARK: Closing

    /// Ends the open file: writes out the open group first (unless `flush` is false), then queues the sidecar and the close.
    private func closeFile(_ reason: CloseReason, flush: Bool = true) {
        guard let run else { return }
        if flush { _ = flushGroup(nextDecode: nil) }
        self.run = nil
        guard let writer = run.writer else { return }
        closing.append(writer)
        writer.close()
        if reason != .roll { keyframeNote.restart() }
        log.info("Closed a recording file (\(reason.rawValue)); \(run.fragments) fragments")
    }

    /// The writer created its file and wrote the initialization segment: the drive works.
    private func writerOpened(_ id: UUID) {
        guard run?.writer?.id == id || closing.contains(where: { $0.id == id }) else { return }
        failures = 0
        if failureSentence != nil {
            failureSentence = nil
            publishStatus(target.writeState)
        }
    }

    /// The writer lost the file (a failed create or write). It cut the file back and closed it; the recorder waits before it tries again.
    private func writerFailed(_ id: UUID, _ sentence: String) {
        guard !stopped, run?.writer?.id == id || closing.contains(where: { $0.id == id }) else { return }
        failures += 1
        let delays = tuning.retryDelays
        retryNotBefore = tuning.uptime() + delays[min(failures - 1, delays.count - 1)]
        failureSentence = sentence
        if run?.writer?.id == id { run = nil }
        publishStatus(target.writeState)
    }

    // MARK: Stall

    /// A write pending for 15 s, or 256 MiB, means the drive is not answering: every file of the camera is abandoned (they share one queue, which the
    /// blocked write holds), the subscription is dropped and no new file opens until that queue has run out.
    private func evaluateStall(_ now: TimeInterval) {
        guard ownPause == nil else { return }
        let writers = [run?.writer].compactMap { $0 } + closing
        let stalled = writers.contains { writer in
            let pending = writer.pending
            return pending.bytes >= tuning.stallPendingBytes || (pending.oldest.map { now - $0 >= ArchiveConstants.stallPendingAge } ?? false)
        }
        guard stalled else { return }
        log.warning("The recordings drive is not answering; recording is paused")
        for writer in writers { writer.abandon() }
        abandoned += writers
        closing = []
        run = nil
        ownPause = .notWritable(ArchiveFolderError.notAnswering.errorDescription ?? "The drive isn’t answering.")
        consumer?.cancel()
        consumer = nil
        subscription?.cancel()
        subscription = nil
        session += 1
    }

    // MARK: Status

    private func publishStatus(_ state: ArchiveWriteState) {
        var notes: [ArchiveNote] = []
        if let soundNote { notes.append(soundNote) }
        if let keyframe = keyframeNote.note { notes.append(keyframe) }
        let recordingState: ArchiveRecordingState
        if state.folder == nil {
            recordingState = .paused(.noFolder)
        } else if let pause = state.pause {
            recordingState = .paused(pause)
        } else if let ownPause {
            recordingState = .paused(ownPause)
        } else if !state.isReady {
            recordingState = .waiting("loading the recordings")
        } else if let failureSentence {
            recordingState = .paused(.notWritable(failureSentence))
        } else if let unrecordable, let until = unrecordableUntil, tuning.uptime() < until {
            recordingState = .waiting("This stream cannot be recorded: \(unrecordable)")
        } else if run?.writer != nil {
            recordingState = .recording
        } else {
            recordingState = .waiting("waiting for the camera")
        }
        publish(CameraArchiveStatus(state: recordingState, notes: notes))
    }

    private func publish(_ new: CameraArchiveStatus) {
        let changed = published.withLock { current -> Bool in
            guard current != new else { return false }
            current = new
            return true
        }
        if changed { signal.notify() }
    }
}

/// An event that happens once and that any number of tasks can wait for.
final class OneShot: Sendable {
    private struct State {
        var fired = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var isFired: Bool { state.withLock { $0.fired } }

    func fire() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.fired = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.fired { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
