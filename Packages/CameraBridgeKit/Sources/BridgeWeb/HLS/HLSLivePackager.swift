import BridgeEngine
import Foundation

/// One camera's live video as HLS: its subscription, cut into segments held in memory, for every ticket of the same camera, stream and sound.
///
/// It holds one live slot and the subscription from its start until it stops: `idleLimit` (or two target durations, if longer) after its last request, or when it is told to. A stop
/// on any path gives the slot back once and ends the subscription, so an on-demand sub stream can stop; a stopped packager answers nothing and
/// never starts again (the next ticket starts a new one).
actor HLSLivePackager {
    /// What a packager is shared by.
    struct Key: Hashable, Sendable {
        var camera: UUID
        var stream: LiveVideoStream
        var audio: Bool
    }

    /// How long a packager goes on without a request, at least: a player reloads its playlist about once a target duration, so a camera with long
    /// key intervals is given two targets (`idleLimit(targetDuration:)`).
    static let idleLimit = Duration.seconds(30)

    /// The idle time that stops a packager whose segments have this target duration (nil until the first key interval is known).
    static func idleLimit(targetDuration: Int?) -> Duration {
        max(idleLimit, .seconds(2 * (targetDuration ?? 0)))
    }
    private static let idleCheck = Duration.seconds(1)

    let key: Key
    /// Tells this packager from any other of the same key: each numbers its segments from 0, so a ticket plays only the one it was minted against.
    let id = UUID()
    private let backend: any BridgeBackend
    private let uptime: @Sendable () -> ContinuousClock.Instant
    private let slot: ReleaseOnce
    private let onStop: @Sendable (HLSLivePackager) async -> Void

    private var segmenter = HLSSegmenter()
    private var lastRequest: ContinuousClock.Instant
    private var stopped = false
    private var pump: Task<Void, Never>?
    private var idleWatch: Task<Void, Never>?
    /// The requests waiting for the first three segments.
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiting = 0

    /// `uptime` measures how long it has been idle, so setting the time of day changes nothing. `slot` gives back the live slot the caller took for
    /// this packager; `onStop` hears of the stop once.
    init(key: Key, backend: any BridgeBackend, uptime: @escaping @Sendable () -> ContinuousClock.Instant, slot: ReleaseOnce,
         onStop: @escaping @Sendable (HLSLivePackager) async -> Void) {
        self.key = key
        self.backend = backend
        self.uptime = uptime
        self.slot = slot
        self.onStop = onStop
        lastRequest = uptime()
    }

    deinit {
        pump?.cancel()
        idleWatch?.cancel()
        slot()
    }

    /// The requests under way that wait for the first three segments.
    var waitingRequests: Int { waiting.count }

    /// The target duration of the segments, once the first key interval is known.
    var targetDuration: Int? { segmenter.targetDuration }

    func start() {
        guard !stopped, pump == nil else { return }
        let (key, backend) = (key, backend)
        let sink: @Sendable (WebApp.LiveCameraOutput) async -> Void = { [weak self] output in await self?.take(output) }
        let soundSwitch: (@Sendable () async -> Bool)? = key.audio ? { @Sendable [weak self] in await self?.keepsItsSound() ?? false } : nil
        // Nothing queues here, so nothing is ever backlogged: the sink awaits this actor, and a packager that falls behind leaves the frames in the
        // subscription, whose own bounded queue drops whole key intervals for a slow reader.
        pump = Task {
            await WebApp.pumpLiveCamera(id: key.camera, stream: key.stream, width: nil, audio: key.audio, soundSwitch: soundSwitch, backend: backend,
                                        backlogged: { false }, sink: sink)
        }
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.idleCheck)
                guard let self else { return }
                await self.stopIfIdle()
            }
        }
    }

    /// Before a packager with sound subscribes again after its camera restarted: true while the camera's "Camera audio" switch is still on. Turning
    /// it off restarts the camera; the packager then stops instead of going on without the sound its playlist promises, so the player asks for a
    /// new ticket, which has none (a ticket's sound is the switch's at mint).
    func keepsItsSound() async -> Bool {
        if await WebApp.soundSwitch(of: key.camera, backend: backend) { return true }
        await stop()
        return false
    }

    /// Takes what the camera's live loop hands on. Only the video counts: after a restart, its new init segment starts the discontinuity by itself.
    func take(_ output: WebApp.LiveCameraOutput) {
        guard !stopped, case .part(let part, _) = output else { return }
        segmenter.add(part)
        if segmenter.hasFirstSegments { wakeEveryone() }
    }

    // MARK: - Requests

    /// Counts as a request. False when this packager has stopped: the caller needs a new one.
    func noteRequest() -> Bool {
        guard !stopped else { return false }
        lastRequest = uptime()
        return true
    }

    /// The live media playlist, once three segments are out; nil if they are not out `limit` later.
    func playlist(waitingUpTo limit: Duration) async -> String? {
        await waitForFirstSegments(upTo: limit)
        return HLSPlaylist.live(segmenter)
    }

    /// The master playlist, once three segments are out, or `limit` later if at least one is; nil if none is. It waits for them as the media playlist
    /// does because AVPlayer gives each playlist 20 s of its own, so a camera with long key intervals spends both on its three segments; one is
    /// all it takes to write. (The media playlist never starts a player on fewer, or it freezes.)
    func master(waitingUpTo limit: Duration) async -> String? {
        await waitForFirstSegments(upTo: limit)
        guard let codecs = segmenter.codecs, let (width, height) = segmenter.resolution, let bandwidth = segmenter.bandwidth else { return nil }
        return HLSPlaylist.master(codecs: codecs, width: width, height: height, bandwidth: bandwidth)
    }

    func initSegment(_ number: Int) -> Data? {
        _ = noteRequest()
        return segmenter.initSegment(number)
    }

    func segment(_ number: Int) -> Data? {
        _ = noteRequest()
        return segmenter.segment(number)
    }

    /// Returns once three segments are out, `limit` has passed, the packager stopped or the request was cancelled. The wait is a request from its
    /// start to its end: the idle time counts from the answer.
    private func waitForFirstSegments(upTo limit: Duration) async {
        _ = noteRequest()
        guard !stopped, !segmenter.hasFirstSegments, limit > .zero else { return }
        let id = nextWaiting
        nextWaiting += 1
        let timer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.wake(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiting[id] = $0 }
        } onCancel: {
            Task { await self.wake(id) }
        }
        timer.cancel()
        _ = noteRequest()
    }

    private func wake(_ id: Int) {
        waiting.removeValue(forKey: id)?.resume()
    }

    private func wakeEveryone() {
        let all = waiting.values
        waiting.removeAll()
        for request in all { request.resume() }
    }

    // MARK: - Stopping

    func stopIfIdle() async {
        if waiting.isEmpty, uptime() - lastRequest >= Self.idleLimit(targetDuration: segmenter.targetDuration) { await stop() }
    }

    /// Ends the subscription and gives the slot back. Later calls do nothing.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        pump?.cancel()
        idleWatch?.cancel()
        segmenter = HLSSegmenter()
        wakeEveryone()
        slot()
        await onStop(self)
    }
}

/// The running packagers, one per key, each with the viewers that minted a ticket for it. A viewer's tickets may be gone while it is still listed
/// here (they expire on their own): that only leaves its packager to the idle stop.
actor HLSLivePackagers {
    private struct Entry {
        var packager: HLSLivePackager
        var users: Set<String>
    }

    private var entries: [HLSLivePackager.Key: Entry] = [:]

    /// The packager that runs for `key`, counted as requested, with `viewer` among its users; or a new one from `start`. Nil when `start` gives
    /// none (no live slot). `start` is handed what the packager must call when it stops.
    func packager(for key: HLSLivePackager.Key, viewer: String,
                  start: @Sendable (_ onStop: @escaping @Sendable (HLSLivePackager) async -> Void) -> HLSLivePackager?) async -> HLSLivePackager? {
        while let found = entries[key]?.packager {
            // Named before the await: a user who leaves meanwhile does not leave this packager with nobody.
            entries[key]?.users.insert(viewer)
            if await found.noteRequest() { return found }
            forget(found)   // it stopped on its own just now; a stop always gets here, but maybe not before this request
        }
        guard let packager = start({ [weak self] in await self?.forget($0) }) else { return nil }
        entries[key] = Entry(packager: packager, users: [viewer])
        await packager.start()
        return packager
    }

    func running(_ key: HLSLivePackager.Key) -> HLSLivePackager? {
        entries[key]?.packager
    }

    /// `viewer` no longer holds a ticket for the packager `id` (the ninth ticket pushed its last one out): it is no longer one of its users, and the
    /// packager stops now if nobody else uses it. A packager that already stopped, or a newer one of the same key, is left alone.
    func release(_ id: UUID, viewer: String) async {
        guard let found = entries.first(where: { $0.value.packager.id == id }) else { return }
        entries[found.key]?.users.remove(viewer)
        guard found.value.users.subtracting([viewer]).isEmpty else { return }
        entries[found.key] = nil   // before the await: from here on a new ticket starts a new packager
        await found.value.packager.stop()
    }

    /// `viewer` is gone (a device removed, a browser signed out): the packagers only it used stop now, the others go on.
    func viewerLeft(_ viewer: String) async {
        var unused: [HLSLivePackager] = []
        for (key, entry) in entries where entry.users.contains(viewer) {
            entries[key]?.users.remove(viewer)
            if entry.users.count == 1 {
                entries[key] = nil   // before the await: from here on a new ticket starts a new packager
                unused.append(entry.packager)
            }
        }
        for packager in unused { await packager.stop() }
    }

    func stopAll() async {
        let all = entries.values.map(\.packager)
        entries.removeAll()
        for packager in all { await packager.stop() }
    }

    private func forget(_ packager: HLSLivePackager) {
        if entries[packager.key]?.packager === packager { entries[packager.key] = nil }
    }
}
