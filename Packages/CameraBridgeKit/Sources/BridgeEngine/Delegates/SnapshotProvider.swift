import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import MediaCore

/// Camera snapshots (plan W3-1 item 4, integration brief §5.4): the camera's JPEG API when it has one (resized to the
/// request), else the hub's newest picture: the decoder decodes forward from the newest keyframe through the frames after it
/// (a camera with a GOP of tens of seconds, or H.264+ stretching it, would otherwise give a picture as old as its keyframe),
/// or waits for the next keyframe when none is held. Periodic (and reason-less) requests are served from a 10 s cache of the
/// same size; event snapshots are always fresh. A picture is decoded at most once: asked again while the hub holds no newer
/// frame (a camera that is paused, or whose stream is idle) the provider hands out the JPEG it made without decoding.
/// The decoding goes through one decoder session kept for `decoderIdleLifetime` after its last use
/// (`SnapshotDecoderPool`), not a new VideoToolbox session per snapshot. Concurrent requests share one fetch from the camera
/// (a Hikvision camera answers 503 to parallel snapshot requests) and one decode. An event snapshot finishes within 3 s and
/// any other within 4 s (hubs warn at 8 s and fail at 25 s, and a request that waits holds up the accessory's events): past the
/// budget the last picture made is served instead, when it is not older than `maximumStaleAge` (5 min); a camera API that fails is skipped for 30 s, one
/// that rejects the credentials for `unauthorizedRetry` (10 min, as the ingest, the event channels and the stream-address
/// probe wait: every request is a login, and cameras lock the account after a few failed ones — Hikvision for 30 min,
/// RTSP included, even once the password is corrected); one that answers "unsupported" (nil) is not asked again.
///
/// While the camera is known to be unreachable (`isOffline`) nothing is fetched and nothing waits: the last picture
/// made, of whatever age, is served at once (resized to the request), so a Home tile shows the last picture instead of
/// waiting out the budget for one that cannot come.
actor SnapshotProvider {
    struct Timing: Sendable, Equatable {
        var cacheLifetime: Duration = .seconds(10)
        /// Hub and periodic requests; `eventBudget` for event snapshots. Past it the last picture is served (`maximumStaleAge`).
        var budget: Duration = .seconds(4)
        var eventBudget: Duration = .seconds(3)
        /// The last picture is served in place of a fresh one (the camera is offline, or slower than the budget) up to this age.
        var maximumStaleAge: Duration = .seconds(300)
        /// Longest wait for the camera's API before falling back to a keyframe.
        var cameraAPITimeout: Duration = .seconds(5)
        /// How long a failing camera API is skipped.
        var cameraAPIRetry: Duration = .seconds(30)
        /// How long a camera API that rejected the credentials is skipped (lockout safety: the ingest's wait).
        var unauthorizedRetry: Duration = IngestSupervisor.Timing().unauthorizedRetry
        /// How long the snapshot decoder session is kept after its last use (a 4K session holds tens of MB).
        var decoderIdleLifetime: Duration = .seconds(60)
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case noPicture
        /// The last picture is older than `Timing.maximumStaleAge` and no fresh one could be had.
        case stale
        var description: String {
            switch self {
            case .noPicture: "no picture from the camera yet"
            case .stale: "the camera's last picture is more than 5 minutes old"
            }
        }
    }

    typealias CameraSnapshot = @Sendable () async throws -> Data?
    typealias Resize = @Sendable (_ jpeg: Data, _ maxWidth: Int?, _ maxHeight: Int?) throws -> Data
    typealias KeyframeJPEG = @Sendable (_ keyframe: EncodedVideoFrame, _ maxWidth: Int?, _ maxHeight: Int?) async throws -> Data
    /// The newest picture of a GOP (a keyframe and the frames after it) as JPEG, decoding no later than `until` (the keyframe always).
    typealias NewestJPEG = @Sendable (_ gop: [EncodedVideoFrame], _ maxWidth: Int?, _ maxHeight: Int?, _ until: ContinuousClock.Instant) async throws -> Data

    private var cameraSnapshot: CameraSnapshot?
    private let resize: Resize
    private let keyframeJPEG: KeyframeJPEG
    private let newestJPEG: NewestJPEG?
    private let hub: MediaHub
    private let timing: Timing
    private let log: Log
    private let now: @Sendable () -> ContinuousClock.Instant
    private let isOffline: @Sendable () -> Bool
    private var cache: (width: Int, height: Int, jpeg: Data, at: ContinuousClock.Instant)?
    /// The JPEG last made from a keyframe, and which keyframe (and size) it was made from.
    private var keyframeCache: (keyframe: KeyframeIdentity, width: Int?, height: Int?, jpeg: Data)?
    private var cameraAPIRetryAt: ContinuousClock.Instant?

    /// `newestJPEG`: decodes forward through a GOP (nil: the newest keyframe is decoded alone, as the test doubles do).
    init(cameraSnapshot: CameraSnapshot?, resize: @escaping Resize, keyframeJPEG: @escaping KeyframeJPEG, newestJPEG: NewestJPEG? = nil, hub: MediaHub,
         timing: Timing = Timing(), log: Log, isOffline: @escaping @Sendable () -> Bool = { false },
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.isOffline = isOffline
        self.cameraSnapshot = cameraSnapshot
        self.resize = resize
        self.keyframeJPEG = keyframeJPEG
        self.newestJPEG = newestJPEG
        self.hub = hub
        self.timing = timing
        self.log = log
        self.now = now
    }

    init(cameraSnapshot: CameraSnapshot?, codecs: any MediaCodecs, hub: MediaHub, timing: Timing = Timing(), log: Log,
         isOffline: @escaping @Sendable () -> Bool = { false }, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        let decoders = SnapshotDecoderPool(codecs: codecs, idleLifetime: timing.decoderIdleLifetime)
        self.init(cameraSnapshot: cameraSnapshot, resize: { try codecs.resizeJPEG($0, maxWidth: $1, maxHeight: $2) },
                  keyframeJPEG: { try await decoders.jpeg(fromKeyframe: $0, maxWidth: $1, maxHeight: $2) },
                  newestJPEG: { try await decoders.jpeg(fromGOP: $0, maxWidth: $1, maxHeight: $2, until: $3) }, hub: hub, timing: timing, log: log,
                  isOffline: isOffline, now: now)
    }

    /// Identifies a keyframe: two of them with the same identity are the same picture.
    private struct KeyframeIdentity: Equatable {
        var pts: MediaTime
        var dts: MediaTime?
        var wallClock: Date
        var width: Int
        var height: Int
        var nalCount: Int
        var byteCount: Int

        init(_ frame: EncodedVideoFrame) {
            pts = frame.pts
            dts = frame.dts
            wallClock = frame.wallClock
            width = frame.format.width
            height = frame.format.height
            nalCount = frame.nalUnits.count
            byteCount = frame.nalUnits.reduce(0) { $0 + $1.count }
        }
    }

    private struct SizeKey: Hashable {
        var width: Int
        var height: Int
    }

    /// What one fetch from the camera's API came to (the bookkeeping of a failure is done once, whoever waited for it).
    private enum CameraOutcome: Sendable {
        case jpeg(Data)
        /// The camera has no snapshot API.
        case unsupported
        /// Failed, or skipped; the video stream stands in.
        case unavailable
    }

    /// Requests for the same size that arrive while one is being answered wait for it (a Hikvision camera answers 503 to two
    /// snapshot requests at once), and requests of any size share one fetch from the camera's API.
    private var productions: [SizeKey: Task<Data, any Error>] = [:]
    private var cameraFetch: Task<CameraOutcome, Never>?
    private var lastStaleLog: ContinuousClock.Instant?

    func snapshot(_ request: SnapshotRequest) async throws -> Data {
        let width = request.width, height = request.height
        if request.reason != .event, let cache, cache.width == width, cache.height == height, now() - cache.at < timing.cacheLifetime {
            return cache.jpeg
        }
        if isOffline(), let cache {
            // Nothing can be fetched from a camera that answers nothing, and nothing may wait for it: the last picture is served
            // at once (resized to the request), up to `maximumStaleAge`; a picture older than that would pass for the camera's
            // view of now, so the request fails instead (Home shows the camera as not responding).
            guard now() - cache.at <= timing.maximumStaleAge else { throw Failure.stale }
            return stale(cache, width: width, height: height)
        }
        let started = now()
        let budget = request.reason == .event ? min(timing.budget, timing.eventBudget) : timing.budget
        let key = SizeKey(width: width, height: height)
        let production: Task<Data, any Error>
        if let running = productions[key] {
            production = running
        } else {
            production = Task { [self] in
                do {
                    let jpeg = try await produce(width: width, height: height, started: started, budget: budget)
                    await finished(key)
                    return jpeg
                } catch {
                    await finished(key)
                    throw error
                }
            }
            productions[key] = production
        }
        do {
            let jpeg = try await withDeadline(budget) { try await production.value }
            cache = (width, height, jpeg, now())
            return jpeg
        } catch let error as DeadlineExceeded {
            // Slower than the budget (a camera that hangs, a long GOP to decode): the last picture stands in rather than a request
            // that holds up the accessory's events, when there is one that is not too old.
            guard let cache, now() - cache.at <= timing.maximumStaleAge else { throw error }
            let age = now() - cache.at
            if lastStaleLog.map({ now() - $0 >= .seconds(30) }) ?? true {
                lastStaleLog = now()
                log.info("A snapshot took more than \(MediaFit.seconds(budget)) s; serving the last picture (\(MediaFit.seconds(age)) s old)")
            }
            return stale(cache, width: width, height: height)
        }
    }

    private func finished(_ key: SizeKey) {
        productions[key] = nil
    }

    private func stale(_ cache: (width: Int, height: Int, jpeg: Data, at: ContinuousClock.Instant), width: Int, height: Int) -> Data {
        if cache.width == width && cache.height == height { return cache.jpeg }
        if let resized = try? resize(cache.jpeg, width > 0 ? width : nil, height > 0 ? height : nil) { return resized }
        return cache.jpeg
    }

    private var cameraAPIFailures = 0

    private func produce(width: Int, height: Int, started: ContinuousClock.Instant, budget: Duration) async throws -> Data {
        let maxWidth = width > 0 ? width : nil
        let maxHeight = height > 0 ? height : nil
        if let cameraSnapshot, cameraAPIRetryAt.map({ now() >= $0 }) ?? true {
            let limit = min(timing.cameraAPITimeout, budget - (now() - started))
            switch await fetchFromCamera(cameraSnapshot, limit: limit) {
            case .jpeg(let jpeg): return try resize(jpeg, maxWidth, maxHeight)
            case .unsupported, .unavailable: break
            }
        }
        var gop = newestJPEG == nil ? [] : await hub.newestGOP()
        if gop.isEmpty {
            if let last = await hub.lastKeyframe { gop = [last] } else { gop = [try await nextKeyframe()] }
        }
        // The picture is of the newest frame decoded forward (`newestJPEG`), else of the keyframe alone.
        let identity = KeyframeIdentity(newestJPEG == nil ? gop[0] : gop[gop.count - 1])
        // The stream has not produced a newer frame since the last picture was made: it is the same picture.
        if let keyframeCache, keyframeCache.keyframe == identity, keyframeCache.width == maxWidth, keyframeCache.height == maxHeight,
           !keyframeCache.jpeg.isEmpty {
            return keyframeCache.jpeg
        }
        let jpeg: Data
        if let newestJPEG {
            let left = max(.zero, budget - (now() - started) - .milliseconds(400))
            jpeg = try await newestJPEG(gop, maxWidth, maxHeight, ContinuousClock.now + left)
        } else {
            jpeg = try await keyframeJPEG(gop[0], maxWidth, maxHeight)
        }
        keyframeCache = (identity, maxWidth, maxHeight, jpeg)
        return jpeg
    }

    /// One fetch from the camera's API shared by every request that arrives while it runs; its failure is counted once.
    private func fetchFromCamera(_ fetch: @escaping CameraSnapshot, limit: Duration) async -> CameraOutcome {
        if let running = cameraFetch { return await running.value }
        let task = Task { [self] () -> CameraOutcome in
            let outcome = await cameraOutcome(fetch, limit: limit)
            cameraFetch = nil
            return outcome
        }
        cameraFetch = task
        return await task.value
    }

    private func cameraOutcome(_ fetch: @escaping CameraSnapshot, limit: Duration) async -> CameraOutcome {
        do {
            if let jpeg = try await withDeadline(limit, fetch), !jpeg.isEmpty {
                if cameraAPIFailures > 0 { log.info("Camera snapshot is working again") }
                cameraAPIFailures = 0
                return .jpeg(jpeg)
            }
            log.debug("The camera has no snapshot API; using the video stream")
            self.cameraSnapshot = nil
            return .unsupported
        } catch is CancellationError {
            return .unavailable
        } catch is CameraOfflineError {
            // Nothing was sent (the camera is unreachable): not a failure of its snapshot API; the stream stands in.
            return .unavailable
        } catch {
            // Never the raw error: a URLError carries the failing URL (a Reolink token, a password in a query).
            let rejected = IngestSupervisor.isUnauthorized(error)
            // Back off on repeated failures (some cameras always answer 503) and log only the first one.
            cameraAPIFailures += 1
            let base = rejected ? timing.unauthorizedRetry : timing.cameraAPIRetry
            let skip = min(base * (1 << min(cameraAPIFailures - 1, 6)), .seconds(1800))
            if cameraAPIFailures > 1 {
                log.debug("Camera snapshot failed again (\(URLFreeErrors.describe(error))); next try in \(MediaFit.seconds(skip)) s")
            } else if rejected {
                log.warning("The camera rejected the username or password for its snapshot; using the video stream for "
                            + "\(MediaFit.seconds(skip)) s (no new login before then)")
            } else {
                log.info("Camera snapshot failed (\(URLFreeErrors.describe(error))); using the video stream for \(MediaFit.seconds(skip)) s")
            }
            cameraAPIRetryAt = now() + skip
            return .unavailable
        }
    }

    /// The next keyframe the hub receives (the caller's deadline bounds the wait).
    private func nextKeyframe() async throws -> EncodedVideoFrame {
        let subscription = await hub.subscribe(from: .nextKeyframe, bufferLimit: 4)
        defer { subscription.cancel() }
        for await sample in subscription.samples {
            if case .video(let frame) = sample, frame.isKeyframe { return frame }
        }
        try Task.checkCancellation()
        throw Failure.noPicture
    }
}
