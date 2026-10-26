import BridgeSupport
import Foundation
import MediaCore
import Synchronization

/// The small pictures of the Sky Watcher's grid. A night can hold hundreds of lights with a picture each (up to 1920 pixels wide), and the page asks for
/// them as the person scrolls: a phone downloading all of them would be downloading a gigabyte to look at postage stamps. `GET …/still?size=thumb`
/// answers a picture at most `width` pixels wide instead: the close-up of the light (`SkyCloseUp`, the rectangle the page draws its path in), or all of
/// the picture, small, for a light that crossed more of the sky than a close-up holds.
///
/// A thumbnail is made once, the first time the page asks, and kept beside the picture (`SkyLogStore.storeThumbnail`); from then on it is read from
/// there. It is made from the picture it is kept for (a picture written again makes it go), at low priority and off the request: on a thread of its own
/// under `nice`, at most `concurrent` at a time however many ask, in the order they came (the cards of the first screen are asked for first), and a request
/// that waits holds nothing: the picture is read, and the light's path looked up, only when its turn comes. When more than `maximumWaiting` are waiting,
/// one that finds the queue full is answered with the whole picture at once rather than left to pile up.
///
/// A drive that is close to pausing the recording gets no new thumbnails (`hasRoom`), as it gets no new pictures: the whole picture is answered, which is on it already.
///
/// It never fails the grid. A thumbnail that cannot be made, now or for a while, because there is no way to make one, the picture cannot be read, the entry
/// is not in the log, the codecs refused or took too long, or the queue is full, is answered with the whole picture (`SkyStillPicture.isThumbnail` false),
/// which the card then shows as it always did; what went wrong is remembered for `failureMemory` so that a picture that cannot be made is not tried at every
/// request. Only a picture that is not there at all is `SkyLogError.noStill`.
final class SkyThumbnails: Sendable {
    /// A thumbnail is at most this wide, in pixels (`THUMB_WIDTH` in the page).
    static let width = 480
    /// How well the JPEG is encoded (0 to 1): a faint light in a dark sky must survive it, so a little better than the pictures of an AI description.
    static let quality = 0.8
    /// How many are made at once.
    static let concurrent = 2
    /// How many may wait for a place before the next to ask is answered with the whole picture.
    static let maximumWaiting = 128
    /// How long one may take before it is given up on (the codecs' own limit is 15 s; a call that overruns this is left to finish on its thread).
    static let deadline: Duration = .seconds(30)
    /// How long a thumbnail that could not be made is not tried again, and how many such failures are remembered.
    static let failureMemory: Duration = .seconds(300)
    static let rememberedFailures = 256

    /// Why a thumbnail was not made, when it is not the codecs' doing: the picture is gone or was replaced meanwhile (nothing to remember: the next request starts
    /// again), or the box cannot cut one for it (the picture's size cannot be read, the entry is not in the log).
    private enum Trouble: Error { case gone, cannot }

    private let store: ArchiveStore
    private let log: SkyLogStore
    private let codecs: any MediaCodecs
    private let gate: SkyThumbnailGate
    private let deadline: Duration
    private let failureMemory: Duration
    private let hasRoom: @Sendable () -> Bool
    private let failures = Mutex<[String: ContinuousClock.Instant]>([:])
    /// The threads the work runs on: concurrent, at a low priority, not Swift concurrency's cooperative ones (a call that hangs must not take one).
    private let queue = DispatchQueue(label: "CameraBridge.SkyThumbnails", qos: .utility, attributes: .concurrent)

    /// `hasRoom`: whether the recordings drive has room for one more picture of the sky (`SkyLightFilter.stillsHaveRoom`); a thumbnail is made and kept only
    /// then, as the pictures themselves are taken only then (Ruling S27: the Sky Watcher never pushes the recorder into pausing).
    init(store: ArchiveStore, log: SkyLogStore, codecs: any MediaCodecs, maximumWaiting: Int = SkyThumbnails.maximumWaiting,
         deadline: Duration = SkyThumbnails.deadline, failureMemory: Duration = SkyThumbnails.failureMemory, hasRoom: @escaping @Sendable () -> Bool) {
        self.store = store
        self.log = log
        self.codecs = codecs
        gate = SkyThumbnailGate(places: Self.concurrent, maximumWaiting: maximumWaiting)
        self.deadline = deadline
        self.failureMemory = failureMemory
        self.hasRoom = hasRoom
    }

    /// Requests waiting for a place (tests).
    var waitingCount: Int { gate.waitingCount }

    /// The entry's picture for the grid: its thumbnail (kept, or made now), or the whole picture when none can be had. Throws `SkyLogError.noStill` when the
    /// entry has no picture, and what the store's reads throw while the drive is away (`ArchiveUnavailable`, `ArchiveError.timedOut`).
    func picture(camera: UUID, night: String, entryID: String, folder: URL) async throws -> SkyStillPicture {
        let log = log
        let found = try await store.skyRead { () throws -> SkyThumbnailLookup in
            guard SkyLogStore.folderExists(folder) else { throw ArchiveUnavailable.folderMissing }
            return log.thumbnailLookup(camera: camera, night: night, entryID: entryID, folder: folder)
        }
        switch found {
        case .none:
            throw SkyLogError.noStill
        case .thumbnail(let jpeg):
            return SkyStillPicture(jpeg: jpeg, isThumbnail: true)
        case .still(let stamp):
            let key = "\(camera.uuidString)/\(night)/\(entryID)"
            if !hasFailedLately(key), hasRoom(), let jpeg = await make(stamp: stamp, key: key, camera: camera, night: night, entryID: entryID, folder: folder) {
                return SkyStillPicture(jpeg: jpeg, isThumbnail: true)
            }
            // The whole picture, read now (a waiting request held nothing until its turn).
            let whole = try await store.skyRead { () throws -> Data? in
                guard SkyLogStore.folderExists(folder) else { throw ArchiveUnavailable.folderMissing }
                return log.still(camera: camera, night: night, entryID: entryID, folder: folder)
            }
            guard let whole else { throw SkyLogError.noStill }
            return SkyStillPicture(jpeg: whole, isThumbnail: false)
        }
    }

    /// Makes and keeps the thumbnail, when its turn comes; nil when it could not be made (and why is remembered, unless the picture was only gone or replaced),
    /// or when so many wait that this one was left out.
    private func make(stamp: SkyStillStamp, key: String, camera: UUID, night: String, entryID: String, folder: URL) async -> Data? {
        let (log, codecs) = (log, codecs)
        do {
            return try await gate.run { () async throws -> Data in
                try await self.offload {
                    // Another request for the same picture may have made it while this one waited for its place.
                    let current = log.thumbnailLookup(camera: camera, night: night, entryID: entryID, folder: folder)
                    switch current {
                    case .none: throw Trouble.gone
                    case .thumbnail(let kept): return kept
                    case .still: break
                    }
                    guard let still = log.readStill(stamp: stamp, entryID: entryID, camera: camera, night: night, folder: folder) else { throw Trouble.gone }
                    // The light's path says where to cut, and the picture's size what the cut is: a picture or an entry the box cannot read is not guessed at.
                    guard let size = JPEGHeader.size(of: still), let path = log.path(ofEntry: entryID, camera: camera, night: night, folder: folder) else { throw Trouble.cannot }
                    let crop = SkyCloseUp.pixels(path: path, width: size.width, height: size.height)
                    let jpeg = try codecs.croppedJPEG(still, crop: crop, maxWidth: Self.width, quality: Self.quality)
                    guard Self.isThumbnail(jpeg, of: size, crop: crop) else { throw MediaCodecError.unsupported("the codecs made no thumbnail") }
                    log.storeThumbnail(jpeg, madeFrom: stamp, entryID: entryID, camera: camera, night: night, folder: folder)
                    return jpeg
                }
            }
        } catch is CancellationError {
            return nil
        } catch Trouble.gone {
            return nil
        } catch {
            noteFailure(key)
            return nil
        }
    }

    /// Whether `jpeg` is what was asked for: at most `width` wide, and the shape of the close-up (or of the picture, when it is all of it), to a pixel or two.
    static func isThumbnail(_ jpeg: Data, of picture: SkyPictureSize, crop: ImageCrop?) -> Bool {
        guard let made = JPEGHeader.size(of: jpeg), made.width <= width else { return false }
        let part = crop.map { SkyPictureSize(width: $0.width, height: $0.height) } ?? picture
        guard made.width <= part.width else { return false }
        let shape = Double(made.width) / Double(made.height), wanted = Double(part.width) / Double(part.height)
        return abs(shape - wanted) <= 0.03 * wanted
    }

    /// `work` on a low-priority thread of its own, given up on after the deadline (it finishes there, and a thumbnail it makes late is kept all the same).
    private func offload(_ work: @escaping @Sendable () throws -> Data) async throws -> Data {
        let queue = queue
        return try await withDeadline(deadline) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                queue.async { continuation.resume(with: Result { try work() }) }
            }
        }
    }

    // MARK: What went wrong

    private func hasFailedLately(_ key: String) -> Bool {
        failures.withLock { failures in
            guard let at = failures[key] else { return false }
            if ContinuousClock.now - at < failureMemory { return true }
            failures[key] = nil
            return false
        }
    }

    private func noteFailure(_ key: String) {
        failures.withLock { failures in
            failures[key] = .now
            if failures.count > Self.rememberedFailures, let oldest = failures.min(by: { $0.value < $1.value }) { failures[oldest.key] = nil }
        }
    }
}

/// At most `places` pieces of work at a time, in the order they were asked for. A caller that finds no place waits (and holds nothing meanwhile). When
/// `maximumWaiting` callers are waiting already, the next to come gives up at once (`run` answers nil) instead of joining a queue that is seconds long; a waiter
/// whose task is cancelled leaves the queue.
final class SkyThumbnailGate: Sendable {
    private enum Outcome { case granted, overflowed, cancelled }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Outcome, Never>
    }

    private struct State {
        var running = 0
        var nextID: UInt64 = 0
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())
    private let places: Int
    private let maximumWaiting: Int

    init(places: Int, maximumWaiting: Int) {
        self.places = max(1, places)
        self.maximumWaiting = max(0, maximumWaiting)
    }

    /// Callers waiting for a place (tests).
    var waitingCount: Int { state.withLock { $0.waiters.count } }

    /// Runs `body` when a place is free and gives the place back after it. nil, without running it, when the queue was full; throws `CancellationError` when
    /// the caller's task is cancelled while it waits.
    func run<T: Sendable>(_ body: () async throws -> T) async throws -> T? {
        switch await enter() {
        case .granted:
            defer { leave() }
            return try await body()
        case .overflowed:
            return nil
        case .cancelled:
            throw CancellationError()
        }
    }

    private func enter() async -> Outcome {
        let id = state.withLock { state -> UInt64 in
            state.nextID &+= 1
            return state.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                let outcome = state.withLock { state -> Outcome? in
                    // Checked under the mutex, so a cancellation either sees this waiter or is seen here.
                    if Task.isCancelled { return .cancelled }
                    if state.running < places {
                        state.running += 1
                        return .granted
                    }
                    if state.waiters.count >= maximumWaiting { return .overflowed }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(returning: outcome) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(returning: .cancelled)
        }
    }

    /// The place goes to the one that has waited longest, if there is one.
    private func leave() {
        let next = state.withLock { state -> Waiter? in
            guard !state.waiters.isEmpty else {
                state.running -= 1
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.continuation.resume(returning: .granted)
    }
}
