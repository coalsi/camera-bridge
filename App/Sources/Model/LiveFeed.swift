import BridgeEngine
import CoreGraphics
import Foundation
import MediaCore
import Observation
import Synchronization

/// Where a live feed's pictures and sound go (the app's `LiveVideoRenderer`; tests use a fake). Called from the feed's
/// reader task, off the main thread, so implementations are thread-safe.
nonisolated protocol LiveVideoSink: AnyObject, Sendable {
    /// One video access unit (a keyframe first), shown at once.
    func show(_ frame: EncodedVideoFrame)
    /// One audio access unit; only sent while the feed is unmuted.
    func play(_ frame: EncodedAudioFrame)
    /// A new connection starts: drop what is queued, show the next keyframe first. The last picture stays on screen.
    func reset()
    /// Silence the sound (muted, or the feed ended); the picture stays.
    func silence()
    /// The feed ended: remove the picture (the snapshot shows again) and silence the sound.
    func clear()
}

/// Opens the engine's live video (`BridgeEngine.liveVideo`; tests inject a fake).
typealias LiveVideoOpener = @MainActor (_ cameraID: UUID, _ stream: LiveVideoStream, _ audio: Bool, _ displayWidth: Int?) async throws -> LiveVideoSubscription

/// One camera's live picture in the app: a subscription to the engine's encoded video, fed to a `LiveVideoSink`, kept
/// alive across reconnects and gone as soon as nobody wants it.
///
/// The feed runs while it is wanted (`isWanted`: somebody asked for the picture) and not suspended (`isSuspended`: the window
/// cannot be seen, or the page is gone), and holds its lease on the camera's stream only while it runs. A camera that is
/// not running (offline, disabled, the bridge paused) or a stream that ends is tried again every `retryDelay`; the feed shows
/// `.unavailable` meanwhile (the last picture stays under it) and `.stalled` when the camera runs but sends no pictures.
@MainActor
@Observable
final class LiveFeed {
    enum Phase: Equatable {
        /// Not running (not wanted, or suspended): the snapshot shows.
        case stopped
        /// Asking the engine for the stream, waiting for the first picture.
        case connecting
        /// Pictures arrive.
        case live
        /// The stream is open but no picture arrived for `stallTime`: the camera is reconnecting.
        case stalled
        /// The engine has no stream to give (the camera is offline or not running); trying again.
        case unavailable
    }

    let cameraID: UUID
    private(set) var phase: Phase = .stopped
    /// A picture is on screen (from the first keyframe of this run on; the last one stays while the stream reconnects).
    private(set) var hasPicture = false
    /// The stream the engine actually reads (nil until it answered).
    private(set) var activeStream: LiveVideoStream?
    /// The picture's size in pixels, from the latest keyframe.
    private(set) var pictureSize: CGSize?

    /// Somebody wants the picture (a play button, the Overview's plan).
    var isWanted = false {
        didSet { if isWanted != oldValue { reconcile() } }
    }
    /// The picture cannot be seen (window hidden or minimised, page gone): the feed stops and keeps `isWanted`.
    var isSuspended = false {
        didSet { if isSuspended != oldValue { reconcile() } }
    }
    /// Which stream to read; changing it while running reconnects.
    var stream: LiveVideoStream {
        didSet { if stream != oldValue, isRunning { restart() } }
    }
    /// Sound is on. Always muted at first: the camera's audio is read only for feeds that `wantsAudio`, and played only
    /// while this is false.
    var isMuted = true {
        didSet {
            shared.isMuted.withLock { $0 = isMuted }
            if isMuted { sink.silence() }
        }
    }
    /// How large the picture is shown, in pixels: `.automatic` picks the sub stream for a tall main stream shown small.
    var displayWidth: Int?

    let wantsAudio: Bool
    var isRunning: Bool { isWanted && !isSuspended }

    @ObservationIgnored private let open: LiveVideoOpener
    /// Where the pictures go (the view hosting the picture asks for it).
    @ObservationIgnored let sink: any LiveVideoSink
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private let stallTime: Duration
    /// A stream that stays silent this long is opened again (a sub stream that went away is replaced by the main stream).
    @ObservationIgnored private var silenceLimit: Duration { stallTime * 2 }
    @ObservationIgnored private let shared = Shared()
    @ObservationIgnored private var task: Task<Void, Never>?

    /// What the reader task and the main actor share.
    private nonisolated final class Shared: Sendable {
        let isMuted = Mutex(true)
        /// Video frames delivered by the current connection.
        let frames = Mutex(0)
        let size = Mutex<CGSize?>(nil)
        /// The reader task finished: the subscription ended.
        let ended = Mutex(false)
    }

    init(cameraID: UUID, stream: LiveVideoStream = .sub, wantsAudio: Bool = false, displayWidth: Int? = nil, sink: any LiveVideoSink,
         retryDelay: Duration = .seconds(3), stallTime: Duration = .seconds(5), open: @escaping LiveVideoOpener) {
        self.cameraID = cameraID
        self.stream = stream
        self.wantsAudio = wantsAudio
        self.displayWidth = displayWidth
        self.sink = sink
        self.retryDelay = retryDelay
        self.stallTime = stallTime
        self.open = open
    }

    deinit {
        task?.cancel()
    }

    /// Stops the feed for good (`isWanted` false).
    func stop() { isWanted = false }

    private func reconcile() {
        if isRunning {
            guard task == nil else { return }
            task = Task { [weak self] in await self?.run() }
        } else {
            endRun()
        }
    }

    private func restart() {
        task?.cancel()
        task = nil
        sink.reset()
        reconcile()
    }

    private func endRun() {
        task?.cancel()
        task = nil
        guard phase != .stopped || hasPicture else { return }
        phase = .stopped
        hasPicture = false
        activeStream = nil
        sink.clear()
    }

    // MARK: Running

    private func run() async {
        phase = .connecting
        while !Task.isCancelled {
            do {
                let subscription = try await open(cameraID, stream, wantsAudio, displayWidth)
                if Task.isCancelled {
                    subscription.cancel()
                    return
                }
                activeStream = subscription.stream
                let ending = await read(subscription)
                subscription.cancel()
                if Task.isCancelled { return }
                if ending == .silent {
                    phase = .connecting   // ask the engine again at once: it picks a stream that delivers
                    continue
                }
                phase = .unavailable   // the stream ended under us: the camera or the engine stopped it
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                phase = .unavailable
            }
            try? await Task.sleep(for: retryDelay)
        }
    }

    private enum Ending { case ended, silent, cancelled }

    /// Reads one subscription to its end: the samples go to the sink off the main thread, a watchdog here turns the pictures'
    /// arrival into `phase`. `.silent`: no picture for `silenceLimit`.
    private func read(_ subscription: LiveVideoSubscription) async -> Ending {
        shared.frames.withLock { $0 = 0 }
        shared.ended.withLock { $0 = false }
        sink.reset()
        phase = .connecting
        let shared = shared
        let sink = sink
        let wantsAudio = wantsAudio
        let reader = Task.detached(priority: .userInitiated) {
            for await sample in subscription.samples {
                switch sample {
                case .video(let frame):
                    if frame.isKeyframe { shared.size.withLock { $0 = CGSize(width: frame.format.width, height: frame.format.height) } }
                    sink.show(frame)
                    shared.frames.withLock { $0 += 1 }
                case .audio(let frame):
                    if wantsAudio, !shared.isMuted.withLock({ $0 }) { sink.play(frame) }
                }
            }
            shared.ended.withLock { $0 = true }
        }
        // Watchdog: first picture, stalls, and the end of the stream.
        var lastCount = 0
        var quiet = Duration.zero
        var ending = Ending.cancelled
        while !Task.isCancelled {
            let tick = phase == .live ? Duration.milliseconds(500) : .milliseconds(100)   // quick to show the first picture, then cheap
            try? await Task.sleep(for: tick)
            if Task.isCancelled { break }
            let count = shared.frames.withLock { $0 }
            if count != lastCount {
                lastCount = count
                quiet = .zero
                if phase != .live { phase = .live }
                if !hasPicture { hasPicture = true }
                let size = shared.size.withLock { $0 }
                if size != pictureSize { pictureSize = size }
            } else {
                quiet += tick
                if phase == .live, quiet >= stallTime { phase = .stalled }
                if quiet >= silenceLimit {
                    ending = .silent
                    break
                }
            }
            if shared.ended.withLock({ $0 }) {
                ending = .ended
                break
            }
        }
        reader.cancel()
        return ending
    }
}
