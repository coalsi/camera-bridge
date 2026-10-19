import BridgeSupport
import Foundation
import MediaCore

/// Gathers what the pictures of an AI description are made from, when the event starts (`CameraRuntime.gatherEventFrames(at:)`): encoded data
/// only, nothing is decoded or resized here, so gathering for several cameras at once costs no more than reading their rings and waiting.
/// The pictures are made later, one set at a time (`EventFrames.pictures(decoders:log:)`, through `CameraRuntime.eventPictures(from:)`).
///
/// At most five pictures, in time order, each the camera's own picture (never the straightened one):
/// - **"4 s before", "2 s before"**: keyframes the camera's live ring holds (`MediaHub.recentKeyframes()`, at least the last 12 s of the main
///   stream), each within `window` of its moment and used once: the two closest to their moments together when two can be had, else one, for
///   the moment it is closer to (the one nearer the event on a tie). A camera that streams on demand holds none when the event starts.
/// - **"At the event"**: the camera's own JPEG as it sent it, fetched within `eventWindow` of the event (`SnapshotProvider.cameraJPEG(within:)`:
///   Home's one fetch, never Home's caches, never the last picture in its place); else the stream's picture nearest the event, from the newest
///   GOP of the ring (`eventFrames(_:at:offset:)`), else the first keyframe that arrives within `eventWindow`. Nothing fresh: no event picture.
/// - **"2 s after", "4 s after"**: keyframes after the event (and after the stream's event picture), chosen as the ones before it, from the ring
///   and then as they arrive: the wait ends at the first keyframe 4 s or more after the event, or `afterWait` after the call.
///
/// Times: `date` is the event's start on the bridge's clock (the event router stamps it so). A frame's time is its `wallClock` plus the hub's
/// `wallClockOffset`, the bridge's clock again: an RTSP camera's own clock may run seconds off, which would put a picture on the wrong side of
/// the event (the recordings place their frames the same way).
struct EventPictures: Sendable {
    static let maxWidth = 768
    static let quality = 0.7
    /// How far a keyframe may be from its moment (4 s or 2 s before or after the event).
    static let window: TimeInterval = 1.5
    /// How far the event picture may be from the event (the snapshot path's budget for an event snapshot).
    static let eventWindow: TimeInterval = 3
    /// A fetch from the camera's API already under way may have begun this long before the event and still give the event picture.
    static let fetchLeeway: TimeInterval = 0.5
    /// The event picture's frames from the stream: at most this many, and this many bytes.
    static let maximumEventFrames = 150
    static let maximumEventBytes = 8 << 20
    /// Decoding forward to the event picture stops after this (the picture is then of the last frame decoded).
    static let eventDecodeBudget: Duration = .seconds(3)
    /// The pictures' decoder is kept for one event's pictures, not between events (a camera's events are described once a minute at most).
    static let decoderIdleLifetime: Duration = .seconds(10)

    static let fourBefore = "4 s before"
    static let twoBefore = "2 s before"
    static let atTheEvent = "At the event"
    static let twoAfter = "2 s after"
    static let fourAfter = "4 s after"

    let hub: MediaHub
    let snapshots: SnapshotProvider
    /// The longest wait for the keyframes after the event, from the call.
    let afterWait: Duration

    init(hub: MediaHub, snapshots: SnapshotProvider, afterWait: Duration = .seconds(6)) {
        self.hub = hub
        self.snapshots = snapshots
        self.afterWait = afterWait
    }

    /// The frames for the pictures of the event that began at `date` (the bridge's clock). A cancelled call ends at once with what it has.
    func gather(at date: Date) async -> EventFrames {
        var frames = EventFrames(date: date)
        let deadline = ContinuousClock.now + afterWait
        // Subscribed before the ring is read, so a keyframe arriving meanwhile is not missed (one seen twice is used once).
        let subscription = await hub.subscribe(from: .nextKeyframe)
        defer { subscription.cancel() }
        let offset = hub.wallClockOffset
        let held = await hub.recentKeyframes().map { Candidate(frame: $0, time: Self.seconds($0, from: date, offset: offset)) }
        frames.before = Self.choose(held.filter { $0.time < 0 }, (Moment(Self.fourBefore, -4), Moment(Self.twoBefore, -2)))
        let stream = Self.eventFrames(await hub.newestGOP(), at: date, offset: offset)
        guard !Task.isCancelled else { return frames }

        async let camera = cameraJPEG(at: date)
        var later = held.filter { $0.time > 0 }
        var firstArrival: Candidate?
        if !later.contains(where: { $0.time >= 4 }) {
            let timer = Task {
                // Its own tolerance: the default let a 6 s sleep end a quarter of a second late on macOS.
                try? await Task.sleep(until: deadline, tolerance: .milliseconds(50), clock: .continuous)
                subscription.cancel()
            }
            defer { timer.cancel() }
            for await sample in subscription.samples {
                guard case .video(let frame) = sample, frame.isKeyframe else { continue }
                let arrived = Candidate(frame: frame, time: Self.seconds(frame, from: date, offset: hub.wallClockOffset))
                if firstArrival == nil { firstArrival = arrived }
                if arrived.time > 0, !later.contains(where: { $0.time == arrived.time }) { later.append(arrived) }
                if arrived.time >= 4 { break }   // nothing later can be nearer 4 s after the event
            }
        }

        var eventTime = -TimeInterval.infinity
        if let jpeg = await camera {
            frames.event = .cameraJPEG(jpeg.jpeg, fetchedAt: jpeg.at)
        } else if let last = stream.last {
            frames.event = .stream(stream)
            eventTime = Self.seconds(last, from: date, offset: offset)
        } else if let firstArrival, abs(firstArrival.time) <= Self.eventWindow {
            frames.event = .stream([firstArrival.frame])
            eventTime = firstArrival.time
        }
        guard !Task.isCancelled else { return frames }
        frames.after = Self.choose(later.filter { $0.time > eventTime }, (Moment(Self.twoAfter, 2), Moment(Self.fourAfter, 4)))
        return frames
    }

    /// The camera's JPEG, when it comes within `eventWindow` of the event from a fetch that began at the event (`fetchLeeway` before it at
    /// most); a cancelled call stops waiting for it at once. The wait is this call's own: the fetch keeps Home's limit.
    private func cameraJPEG(at date: Date) async -> (jpeg: Data, at: Date)? {
        let left = Self.eventWindow - Date().timeIntervalSince(date)
        guard left > 0,
              let read = await snapshots.cameraJPEG(within: .seconds(left), startedAfter: date.addingTimeInterval(-Self.fetchLeeway)),
              read.at.timeIntervalSince(date) <= Self.eventWindow else { return nil }
        return read
    }

    /// The event picture's frames from the newest GOP: its keyframe and the frames after it up to the one nearest the event, at most
    /// `maximumEventFrames` and `maximumEventBytes` (in a longer GOP the picture is of the last frame kept). None when that frame is more than
    /// `eventWindow` from the event: a camera that stopped sending, or a GOP too long to decode that far.
    static func eventFrames(_ gop: [EncodedVideoFrame], at date: Date, offset: TimeInterval) -> [EncodedVideoFrame] {
        guard let keyframe = gop.first, keyframe.isKeyframe else { return [] }
        let times = gop.map { seconds($0, from: date, offset: offset) }
        let nearest = times.indices.min { abs(times[$0]) < abs(times[$1]) } ?? 0
        var end = 0
        var bytes = 0
        for index in 0...nearest {
            let size = gop[index].nalUnits.reduce(0) { $0 + $1.count }
            guard index == 0 || (index < maximumEventFrames && bytes + size <= maximumEventBytes) else { break }
            bytes += size
            end = index
        }
        guard abs(times[end]) <= eventWindow else { return [] }
        return Array(gop[0...end])
    }

    struct Candidate: Sendable {
        var frame: EncodedVideoFrame
        /// Seconds from the event on the bridge's clock.
        var time: TimeInterval
    }

    struct Moment: Sendable {
        var label: String
        var seconds: TimeInterval

        init(_ label: String, _ seconds: TimeInterval) {
            self.label = label
            self.seconds = seconds
        }
    }

    /// The keyframes for two moments (`moments.0` earlier), each within `window` of its moment and used once: the pair in time order closest to
    /// their moments together when there is one, else the single keyframe nearest either moment (the one nearer the event on a tie).
    static func choose(_ candidates: [Candidate], _ moments: (Moment, Moment)) -> [EventFrames.Labeled] {
        let sorted = candidates.sorted { $0.time < $1.time }
        func distance(_ candidate: Candidate, _ moment: Moment) -> TimeInterval? {
            let distance = abs(candidate.time - moment.seconds)
            return distance <= window ? distance : nil
        }
        var pair: (first: Int, second: Int, distance: TimeInterval)?
        for second in sorted.indices {
            guard let toSecond = distance(sorted[second], moments.1) else { continue }
            for first in 0..<second {
                guard let toFirst = distance(sorted[first], moments.0) else { continue }
                if toFirst + toSecond < pair?.distance ?? .infinity { pair = (first, second, toFirst + toSecond) }
            }
        }
        if let pair {
            return [EventFrames.Labeled(label: moments.0.label, frame: sorted[pair.first].frame),
                    EventFrames.Labeled(label: moments.1.label, frame: sorted[pair.second].frame)]
        }
        let nearerFirst = abs(moments.0.seconds) <= abs(moments.1.seconds) ? [moments.0, moments.1] : [moments.1, moments.0]
        var single: (picked: EventFrames.Labeled, distance: TimeInterval)?
        for candidate in sorted {
            for moment in nearerFirst {
                guard let toMoment = distance(candidate, moment), toMoment < single?.distance ?? .infinity else { continue }
                single = (EventFrames.Labeled(label: moment.label, frame: candidate.frame), toMoment)
            }
        }
        return single.map { [$0.picked] } ?? []
    }

    /// Seconds from `date` to the frame on the bridge's clock.
    static func seconds(_ frame: EncodedVideoFrame, from date: Date, offset: TimeInterval) -> TimeInterval {
        frame.wallClock.addingTimeInterval(offset).timeIntervalSince(date)
    }
}

/// What an event's pictures are made from (`EventPictures.gather(at:)`): encoded data only. At most `EventPictures.maximumEventFrames` frames
/// and `maximumEventBytes` for the event picture, plus up to four keyframes (a 4K keyframe is a few hundred KB): about 10 MiB at most. The
/// describer keeps few of them waiting (it drops an event older than 60 s, and describes a camera once a minute at most).
struct EventFrames: Sendable {
    struct Labeled: Sendable {
        var label: String
        var frame: EncodedVideoFrame
    }

    /// Where the event picture comes from.
    enum Event: Sendable {
        /// The camera's own JPEG as it sent it, and when it came (the bridge's clock).
        case cameraJPEG(Data, fetchedAt: Date)
        /// From the stream: a keyframe and the frames after it in decode order; the picture is of the last one.
        case stream([EncodedVideoFrame])
    }

    /// The event's start, on the bridge's clock.
    var date: Date
    var before: [Labeled] = []
    var event: Event?
    var after: [Labeled] = []

    init(date: Date) {
        self.date = date
    }

    /// The pictures, in time order, each a JPEG at most `EventPictures.maxWidth` wide at `EventPictures.quality` (the camera's own JPEG when it
    /// already fits, as it came). They are made one at a time on `decoders`, whose blocking JPEG work runs off the cooperative pool
    /// (`SnapshotDecoderPool.offCooperativePool`); decoding forward to the event picture stops after `EventPictures.eventDecodeBudget`. A
    /// picture that cannot be made is left out (logged at debug level); a cancelled call makes no more.
    func pictures(decoders: SnapshotDecoderPool, log: Log) async -> [LabeledPicture] {
        let width = EventPictures.maxWidth, quality = EventPictures.quality
        var jobs: [(label: String, make: @Sendable () async throws -> Data)] = []
        for labeled in before {
            jobs.append((labeled.label, { try await decoders.jpeg(fromKeyframe: labeled.frame, maxWidth: width, maxHeight: nil, quality: quality) }))
        }
        switch event {
        case .cameraJPEG(let jpeg, _):
            jobs.append((EventPictures.atTheEvent, { try await decoders.resizedJPEG(jpeg, maxWidth: width, maxHeight: nil, quality: quality) }))
        case .stream(let frames):
            jobs.append((EventPictures.atTheEvent, {
                try await decoders.jpeg(fromGOP: frames, maxWidth: width, maxHeight: nil, until: .now + EventPictures.eventDecodeBudget, quality: quality)
            }))
        case nil:
            break
        }
        for labeled in after {
            jobs.append((labeled.label, { try await decoders.jpeg(fromKeyframe: labeled.frame, maxWidth: width, maxHeight: nil, quality: quality) }))
        }
        var pictures: [LabeledPicture] = []
        for job in jobs {
            guard !Task.isCancelled else { break }
            do {
                pictures.append(LabeledPicture(label: job.label, jpeg: try await job.make()))
            } catch {
                log.debug("No picture \"\(job.label)\" for the event's description: \(URLFreeErrors.describe(error))")
            }
        }
        return pictures
    }
}
