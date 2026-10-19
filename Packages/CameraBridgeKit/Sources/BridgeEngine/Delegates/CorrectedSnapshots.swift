import BridgeSupport
import Foundation
import HAPCamera
import MediaCore

/// Snapshots as every viewer sees the camera ("Straighten the picture", docs/superpowers/specs/2026-10-18-straighten-the-picture-design.md):
/// Apple Home's tiles and notifications and the web's stills are the `SnapshotProvider`'s JPEG straightened by the camera's correction
/// (`PictureCorrectionControl.current`, asked at every snapshot), unless the caller asks for the original: the camera page straightens
/// that itself while its sliders move. While the correction is off, or the codecs cannot apply one, nothing runs.
///
/// - **Within the provider's budget**: a request answers within the provider's own limit (`SnapshotProvider.Timing.limit(for:)`: 3 s
///   for an event snapshot, else 4 s; hubs warn at 8 s, and a request that waits holds up the accessory's events). The correction gets
///   what the provider left of it, less `margin`; past that the camera's own picture is served.
/// - **One at a time**: a camera runs one correction at a time (each holds a thread while its ffmpeg runs, up to
///   `PictureCorrection.snapshotTimeout`; the thread is one of `CodecOffload`'s, never one of the cooperative pool's, which the box's
///   HomeKit and RTP work shares: `offloaded`). A request for the picture being straightened waits for it; one for another picture
///   waits for it to end, then runs its own, within its budget. A correction past a request's budget keeps running, and the next
///   request for the same picture takes its result.
/// - **Kept**: the newest straightened picture of each of the last two sizes asked for (Apple Home's tiles and the web ask for
///   different ones), by input JPEG and correction: the provider hands out the same JPEG while the camera has no newer picture, and
///   that is not straightened again, but it is under a new correction. A kept picture is handed out at once, budget or not.
/// - **Current**: a picture straightened by values that changed meanwhile (the slider moved) is straightened once more by the new
///   ones, within the budget; otherwise the camera's own picture is served, never one made with the old values.
/// - **Failures**: a correction that fails or is late serves the camera's own picture (a picture rather than none), warned at most
///   once every 30 s; a failed one is not kept, so the next snapshot tries again.
actor CorrectedSnapshots {
    /// Straightens a JPEG by a correction (the codecs' `correctJPEG`).
    typealias Correct = @Sendable (_ jpeg: Data, _ correction: PictureCorrection) async throws -> Data

    /// How long the engine waits for one correction: the codecs' own limit and a margin for the child to be stopped and reaped.
    static let deadline = PictureCorrection.snapshotTimeout + .seconds(1)

    /// A `Correct` that runs `work` (blocking: the codecs' `correctJPEG` starts an ffmpeg child and waits for its exit) on a thread of
    /// `CodecOffload`'s, not on the cooperative pool, and gives up on it after `deadline` (`DeadlineExceeded`; the call is left to end on
    /// its own thread). Every correction of every camera goes through this.
    static func offloaded(deadline: Duration = deadline, _ work: @escaping @Sendable (_ jpeg: Data, _ correction: PictureCorrection) throws -> Data) -> Correct {
        { jpeg, correction in try await CodecOffload.run(deadline: deadline) { try work(jpeg, correction) } }
    }

    /// What is kept of a request's budget for handing its picture on.
    static let margin = Duration.milliseconds(150)
    /// The shortest time between two warnings.
    static let warningInterval = Duration.seconds(30)
    /// How many sizes keep their straightened picture.
    static let keptSizes = 2

    private struct Picture: Equatable {
        var input: Data
        var correction: PictureCorrection
    }

    private struct Size: Equatable {
        var width: Int
        var height: Int
    }

    /// The original pictures underneath (AI descriptions use the camera's own picture, never the straightened one).
    let provider: SnapshotProvider
    private let correction: PictureCorrectionControl
    private let correct: Correct
    private let log: Log
    private let now: @Sendable () -> ContinuousClock.Instant
    /// The newest straightened picture of each size, oldest first.
    private var kept: [(size: Size, picture: Picture, output: Data)] = []
    /// The camera's one correction running.
    private var running: (id: Int, picture: Picture, task: Task<Data, any Error>)?
    private var runs = 0
    private var lastWarning: ContinuousClock.Instant?

    /// `now`: the clock of the warnings' interval (tests); the budget is measured on the real clock, as the provider's is.
    init(provider: SnapshotProvider, correction: PictureCorrectionControl, log: Log, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         correct: @escaping Correct) {
        self.provider = provider
        self.correction = correction
        self.log = log
        self.now = now
        self.correct = correct
    }

    /// The provider's snapshot, straightened unless `original` (or while the correction is off).
    func snapshot(_ request: SnapshotRequest, original: Bool = false) async throws -> Data {
        let deadline = ContinuousClock.now + provider.timing.limit(for: request.reason) - Self.margin
        let jpeg = try await provider.snapshot(request)
        guard !original else { return jpeg }
        let size = Size(width: request.width, height: request.height)
        var straightened = 0
        while let wanted = correction.current {
            let picture = Picture(input: jpeg, correction: wanted)
            if let output = kept.last(where: { $0.picture == picture })?.output { return output }
            // Straightened once already, by values that changed meanwhile: the camera's picture rather than a stale one.
            guard straightened < 2 else { return jpeg }
            let left = deadline - ContinuousClock.now
            guard left > .zero else {
                warn("no time was left of the snapshot's \(MediaFit.seconds(provider.timing.limit(for: request.reason))) s")
                return jpeg
            }
            do {
                if let running, running.picture != picture {
                    // One correction at a time: wait for the one running to end (whatever its result), then run this one.
                    try await withDeadline(left) { _ = await running.task.result }
                    continue
                }
                let task = running?.task ?? start(picture, size: size)
                let output = try await withDeadline(left) { try await task.value }
                straightened += 1
                if correction.current == wanted { return output }
            } catch is CancellationError {
                throw CancellationError()   // the request was given up on (the correction, still running, is kept)
            } catch {
                warn(URLFreeErrors.describe(error))
                return jpeg
            }
        }
        return jpeg
    }

    /// Starts the camera's one correction; its end is recorded whoever waits for it (or nobody: every request gave up on it).
    private func start(_ picture: Picture, size: Size) -> Task<Data, any Error> {
        runs += 1
        let id = runs, correct = correct
        let task = Task {
            do {
                let output = try await correct(picture.input, picture.correction)
                finished(id, picture: picture, size: size, output: output)
                return output
            } catch {
                finished(id, picture: picture, size: size, output: nil)
                throw error
            }
        }
        running = (id, picture, task)
        return task
    }

    private func finished(_ id: Int, picture: Picture, size: Size, output: Data?) {
        if running?.id == id { running = nil }
        guard let output else { return }
        kept.removeAll { $0.size == size }
        kept.append((size, picture, output))
        if kept.count > Self.keptSizes { kept.removeFirst(kept.count - Self.keptSizes) }
    }

    private func warn(_ reason: String) {
        let time = now()
        guard lastWarning.map({ time - $0 >= Self.warningInterval }) ?? true else { return }
        lastWarning = time
        log.warning("A snapshot could not be straightened (\(reason)); serving the camera's picture as it is")
    }
}
