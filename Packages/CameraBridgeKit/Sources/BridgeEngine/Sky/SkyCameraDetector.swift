import BridgeSupport
import Foundation
import MediaCore

// MARK: - The camera's status

/// A sky camera's Sky Watcher as its card shows it (`CameraStatus.sky`; nil while the Sky Watcher is off for the camera): whether its pictures
/// are being looked at now (`running`: one came in the last 10 s), which of its streams (`main` or `sub`), at what width and how many a second,
/// where they are decoded (`gpu` or `software`), the aim, what the box has learned of this sky, what keeps it from watching (`problem`, a
/// sentence for the person: no place, no recordings folder, a battery camera, the flight feed's trouble) and the camera profile it is on
/// (`profile`, the night-sky profile's, later).
public struct SkyCameraStatus: Sendable, Equatable {
    public var running: Bool
    public var stream: String?
    public var analysisWidth: Int?
    public var picturesPerSecond: Double?
    public var decoding: String?
    public var aim: SkyAimStatus
    public var learning: SkyLearning
    public var problem: String?
    public var profile: String?

    public init(running: Bool, stream: String? = nil, analysisWidth: Int? = nil, picturesPerSecond: Double? = nil, decoding: String? = nil,
                aim: SkyAimStatus, learning: SkyLearning, problem: String? = nil, profile: String? = nil) {
        self.running = running
        self.stream = stream
        self.analysisWidth = analysisWidth
        self.picturesPerSecond = picturesPerSecond
        self.decoding = decoding
        self.aim = aim
        self.learning = learning
        self.problem = problem
        self.profile = profile
    }

    /// Wanted, but not watching: `problem` says why (nil when the reason is the camera's own, turned off or the bridge paused).
    static func stopped(_ problem: String?) -> SkyCameraStatus {
        SkyCameraStatus(running: false, aim: .unaimed(), learning: SkyLearning(ready: false, planes: 0, satellites: 0), problem: problem)
    }
}

// MARK: - The detector

/// One sky camera's Sky Watcher at work (Task 7): it takes the camera's pictures (`SkyFrameSink`, from `CameraRuntime.startSky`), finds and
/// follows the lights in them, and logs every light that crossed the sky (`SkyLogStore`), explained by a flight or not, with a picture of what
/// nothing explains.
///
/// **Each picture** (on the actor, a few milliseconds): the mask (the ground, the horizon below 1° once the aim is good, the Sun within 15°
/// while it is up: worked out again once a minute, as is whether it is night), the analyzer, then the tracker (`update(_:at:wallClock:dropped:)`
/// on the box's clock: the picture's own wall clock plus `SkyFrame.clockOffset`). A whole-picture change (`SkyFrameResult.globalChange`: the
/// IR-cut filter, an exposure step) is a camera event: every open track ends unlogged (`endAll(dropped:)`, its drops thrown away too) and no
/// track begins for `quietAfterChange` (3 s, measured on the stream's clock; the analyzer's own pause is 2 s): on the owner's camera one such
/// jump made 49 lights that were not there. The tracks the tracker drops (barely moved, on something fixed) go to `droppedTrack(_:)`, which
/// Tasks 9 and 10 fill. Once a minute the background is judged for how much sky is visible (`SkyVisibility`), and the conditions are written.
///
/// **Each ended track** (off the picture path, one at a time in order, on a queue of its own: a picture never waits for one): measured with
/// the current aim; a stationary one is left for Task 10; then `classify` (Phase 1: the flight feed) and, when nothing explains it, a picture
/// of its middle (`Context.still`; a camera keeps at most 30 an hour, the later lights being logged without one); then the entry, filed by
/// `SkyNight.logName` (a night by its sunset's date, a day by its own: Ruling S4), its path at most 64 points evenly picked. A light that
/// nothing explains and that crawls (under 0.05°/s while the aim is good, under 0.5 analysed pixels a second while it is rough: a star) is no
/// entry and has no picture: it is counted, and the journal gets one line an hour with the count (Ruling S24, `SkyLightFilter`). A match's
/// correspondences go to the aim in one `SkyAimStore.add` (the store thins each call per aircraft): the fit runs on the store, never on a
/// picture.
///
/// **An aim far off** (Ruling S18): once a minute the aircraft of the feed that the aim puts in the view (within 60 km, 2° up, above the ground)
/// are noted (`SkyMatchWatch`). When planes have been in view for 2 hours (5 aircraft at least) and lights were followed (5 at least) but none
/// matched, the status says "Planes are flying through the view but none match: check which way the camera faces" (also the sign of a camera
/// that moved). While the aim is still rough then, once an hour, the card is searched wide (`SkyAimSearch`: facing ±45° in 15° steps, tilt
/// ±30° in 10° steps, on the unexplained tracks of the last 2 hours with the aircraft around them), off the picture path; a clear winner
/// becomes the aim's start, kept beside the aim until the person changes the card, and the status says how far off the card was.
///
/// **A camera that moved** (Ruling S25): the aim starts again from the card, rough, as a camera just added does (so that the wide search can
/// run), when the card's facing, tilt or lenses change (`update(context:)`: the ground and the night profile change nothing of where the camera
/// looks), or when the aim is good or precise and the planes' stretch above has held for its 2 hours: the journal and the status say so.
///
/// **Kept per camera** in `directory` (`<data>/sky/<camera-uuid>/`, beside the aim's own files): `detector.json` with the visibility's memory,
/// the open conditions span, the planes matched with a good aim (the learning) and the card the search found. Nothing in it is the place.
/// Nothing is logged with the place in it.
actor SkyCameraDetector: SkyFrameSink {
    /// What the detector needs to know of its camera and the box. `pictureWidth` and `pictureHeight`: the camera's picture, when known
    /// before its first picture (0: the first picture says). `folder`: the recordings folder the log is kept in. `still`: a JPEG of the
    /// camera's own picture at a time on the camera's timeline (`SkyFrame.wallClock`'s, not the box's). `roomForStills`: whether the recordings
    /// drive has room for a picture now (`SkyLightFilter.stillsHaveRoom`): a light is logged without one while it has not.
    struct Context: Sendable {
        var cameraID: UUID
        var cameraName: String
        var settings: SkyDetectorSettings
        var observer: SkyObserver
        var zone: TimeZone
        var pictureWidth: Int
        var pictureHeight: Int
        var folder: @Sendable () -> URL?
        var still: @Sendable (Date) async -> (jpeg: Data, at: Date)?
        var roomForStills: @Sendable () async -> Bool = { true }
    }

    // MARK: Values

    /// After a whole-picture change no track begins for this long (stream seconds).
    static let quietAfterChange: TimeInterval = 3
    /// The detector is running while a picture came within this.
    static let runningWithin: Duration = .seconds(10)
    /// `stop` waits this long for the light the queue is at work on (its picture may be a keyframe's decode that stalls), and no longer.
    static let stopPatience: Duration = .seconds(1)
    /// How fast is measured over the last this many pictures (since the last break).
    static let rateSamples = 25
    /// The Sun's circles and whether it is night are worked out again this often (the Sun moves a quarter of a degree a minute).
    static let skyRefresh: TimeInterval = 60
    /// The planes in view, the wide search and the state file are looked at this often.
    static let tickInterval: Duration = .seconds(60)
    /// The state file is written at least this often while something in it changed.
    static let saveInterval: TimeInterval = 600
    /// Ended tracks waiting for the queue: beyond this a light is not logged (the box is far behind).
    static let maximumPending = 200
    static let stateFileName = "detector.json"
    /// An aircraft counts as in the view within this range and above this elevation.
    static let inViewRange = 60_000.0
    static let inViewElevation = 2.0

    // MARK: State

    private var context: Context
    private let directory: URL
    private let flights: FlightHistory
    private let log: SkyLogStore
    private let now: @Sendable () -> Date
    private let seed: UInt64?
    private let logger: Log
    private var started = false
    private var stopped = false

    /// The aim: its store (opened once the picture's size is known) and what was last read of it, so that a picture never waits for it.
    private var aimStore: SkyAimStore?
    private var aimSize: PictureSize?
    private var model: SkyCameraModel
    private var quality: SkyAimQuality = .rough
    private var aimStatus = SkyAimStatus.unaimed()
    /// How far from the person's card the wide search found the camera to look (kept with `cardFor`, the card it was found for).
    private var cardOffset = SkyAimSearch.Card.zero

    private var analyzer: SkyFrameAnalyzer?
    private var tracker: SkyTracker?
    private var sunCircles: [SkyMask.Circle] = []
    private var isNight = true
    private var skyChecked: Date?
    private var skyCheckedModel: SkyCameraModel?
    /// After a whole-picture change: the stream time it came at, and until when no track begins.
    private var quietFrom: TimeInterval?
    private var quietUntil: TimeInterval?

    private var lastPicture: ContinuousClock.Instant?
    private var recentTimes: [TimeInterval] = []
    private var analysisWidth: Int?
    private var analysisHeight: Int?
    private var pictureWidth: Int
    private var stream: SkyStreamChoice.Stream?
    private var decoding: DecodingPlace?
    private var clockOffset: TimeInterval = 0

    private var visibility = SkyVisibility()
    private var visibilityChecked: Date?
    private var latestVisibility: Double?
    private var conditions = SkyConditionsRecorder()

    private var learnedPlanes = 0
    /// The slow lights skipped and the pictures asked for, by the clock hour of the light (Ruling S24: `SkyLightFilter`).
    private var slowLights = SkyHourCounts()
    private var picturesAsked = SkyHourCounts()
    private var watch = SkyMatchWatch()
    private var records: [SkyAimSearch.Record] = []
    private var lastSearch: Date?
    private var lastSave: Date?
    private var dirty = false
    private var saveFailureLogged = false
    private var behindLogged = false

    private enum Work: Sendable {
        case ended(SkyTrack, analysisWidth: Int, analysisHeight: Int, pictureWidth: Int)
        case setStart
        /// The card changed (Ruling S25): the aim starts again from it.
        case restartAim
        case barrier(CheckedContinuation<Void, Never>)
    }

    private let work: AsyncStream<Work>.Continuation
    private let works: AsyncStream<Work>
    private var pending = 0
    private var worker: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?

    private struct PictureSize: Equatable, Sendable {
        var width: Int
        var height: Int
    }

    /// `directory`: the camera's own folder in the data directory (`SkyService.directory(of:in:)`). `seed` makes the aim's fits repeatable
    /// (tests).
    init(context: Context, directory: URL, flights: FlightHistory, log: SkyLogStore, now: @escaping @Sendable () -> Date = { Date() },
         seed: UInt64? = nil) {
        self.context = context
        self.directory = directory
        self.flights = flights
        self.log = log
        self.now = now
        self.seed = seed
        logger = Log(category: "Sky", cameraID: context.cameraID)
        pictureWidth = max(0, context.pictureWidth)
        model = Self.card(context.settings, offset: .zero, width: max(1, context.pictureWidth), height: max(1, context.pictureHeight))
        (works, work) = AsyncStream.makeStream(of: Work.self)
    }

    /// Reads what was kept, opens the aim when the picture's size is known, and starts the queue and the minute's look.
    func start() async {
        guard !started, !stopped else { return }
        started = true
        loadState()
        if context.pictureWidth > 0, context.pictureHeight > 0 {
            openAim(width: context.pictureWidth, height: context.pictureHeight)
            await refreshAim()
        }
        saveState(at: now())
        let works = works
        worker = Task { [weak self] in
            for await item in works {
                guard let self else { return }
                await self.perform(item)
            }
        }
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled, let self else { return }
                await self.tick(at: self.now())
            }
        }
        logger.info("Sky Watcher watches the sky for \(context.cameraName)")
    }

    /// Takes no more pictures and starts no more work, writes the conditions span that was open and what is kept. The lights that wait in the
    /// queue are dropped (the last seconds of the sky), and the light the queue is at work on gets `stopPatience` to finish: the engine stops
    /// the detectors with its locks held, and the daemon gives the whole engine ten seconds (Ruling S27). What it leaves unfinished ends on its
    /// own, and can write nothing of the aim (`SkyAimStore.close`).
    func stop() async {
        guard !stopped else { return }
        stopped = true
        maintenance?.cancel()
        maintenance = nil
        work.finish()
        if let worker { _ = try? await withDeadline(Self.stopPatience, followsCancellation: false) { await worker.value } }
        worker = nil
        aimStore?.close()
        if let span = conditions.close() { record(span) }
        sayHowManySlowLightsWereSkipped(before: .distantFuture)
        if started { saveState(at: now()) }
        if started { logger.info("Sky Watcher stopped for \(context.cameraName)") }
    }

    /// Waits until everything queued before it is done (tests).
    func settle() async {
        guard worker != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            switch work.yield(.barrier(continuation)) {
            case .enqueued: break
            default: continuation.resume()
            }
        }
    }

    // MARK: Changes

    /// New settings of the camera (its card, its ground, its lenses): applied in place.
    func update(_ settings: SkyDetectorSettings) {
        var changed = context
        changed.settings = settings
        update(context: changed)
    }

    /// A new context (the camera renamed, the place, the zone or the folder changed, new settings).
    func update(context new: Context) {
        let old = context
        context = new
        if new.observer != old.observer {
            skyChecked = nil
            records.removeAll()
        }
        guard new.settings != old.settings else { return }
        // Where the camera looks is the card's facing, tilt and lenses; the ground and the night profile are not (Ruling S25).
        guard old.settings.facing != new.settings.facing || old.settings.tilt != new.settings.tilt
            || old.settings.lensLayout != new.settings.lensLayout else { return }
        // The camera was pointed again, or its lenses set again: its aim starts from the new card, rough, as a camera just added does (what
        // the wide search found for the old card, the planes' stretch and the lights kept for the search go with it).
        logger.info("Sky Watcher, \(new.cameraName): the camera's card changed; starting the aim again")
        forgetWhatWasFound()
        enqueue(.restartAim)
    }

    /// Back to the card: nothing found for an earlier aim (the wide search's offset, the stretch of planes that matched nothing, the lights kept
    /// for the search) applies to the aim that starts again.
    private func forgetWhatWasFound() {
        cardOffset = .zero
        watch.restart()
        records.removeAll()
        lastSearch = nil
        dirty = true
    }

    /// The camera's pictures start again (a new runtime): what was open is cut off, as at a gap.
    func restarted() {
        cut()
    }

    // MARK: The pictures

    func frame(_ frame: SkyFrame) async {
        guard started, !stopped, frame.image.width > 0, frame.image.height > 0, frame.image.pixels.count >= frame.image.width * frame.image.height else { return }
        let width = frame.pictureWidth > 0 ? frame.pictureWidth : frame.image.width
        let height = frame.pictureHeight > 0 ? frame.pictureHeight : frame.image.height
        if aimStore == nil {
            openAim(width: width, height: height)
            await refreshAim()
            guard !stopped else { return }
        } else if aimSize != PictureSize(width: width, height: height) {
            aimSize = PictureSize(width: width, height: height)
            enqueue(.setStart)
        }
        analyse(frame, pictureWidth: width, pictureHeight: height)
    }

    func gap(at date: Date, reason: String) async {
        cut()
    }

    /// What was open ends unlogged (a gap is never a track, and a track cut by one is not logged); the background starts again.
    private func cut() {
        if let tracker {
            var dropped: [SkyDroppedTrack] = []
            _ = tracker.endAll(dropped: &dropped)
            for track in dropped { droppedTrack(track) }
        }
        analyzer?.reset()
        quietFrom = nil
        quietUntil = nil
        recentTimes.removeAll()
    }

    /// A track the tracker dropped (barely moved, or on something fixed): the flashes and stationary points of Tasks 9 and 10. Nothing yet.
    func droppedTrack(_ dropped: SkyDroppedTrack) {}

    /// One picture's work, on the actor.
    private func analyse(_ frame: SkyFrame, pictureWidth: Int, pictureHeight: Int) {
        let offset = frame.clockOffset.isFinite ? frame.clockOffset : 0
        let wallClock = frame.wallClock.addingTimeInterval(offset)   // the box's clock: the flight feed's and the Sun's
        clockOffset = offset
        note(frame, pictureWidth: pictureWidth)
        let image = frame.image
        let analyzer: SkyFrameAnalyzer, tracker: SkyTracker
        if let current = self.analyzer, let following = self.tracker, current.width == image.width, current.height == image.height,
           following.width == image.width, following.height == image.height {
            analyzer = current
            tracker = following
        } else {
            if let old = self.tracker {
                var dropped: [SkyDroppedTrack] = []
                _ = old.endAll(dropped: &dropped)   // another size: what was open is cut off
            }
            analyzer = SkyFrameAnalyzer(width: image.width, height: image.height)
            tracker = SkyTracker(width: image.width, height: image.height)
            tracker.model = model
            tracker.aimQuality = quality
            self.analyzer = analyzer
            self.tracker = tracker
            quietFrom = nil
            quietUntil = nil
        }
        refreshSky(at: wallClock, pictureWidth: pictureWidth, pictureHeight: pictureHeight)
        let mask = SkyMask(groundPercent: context.settings.groundPercent, belowElevation: quality == .rough ? nil : 1, excluded: sunCircles, model: model)
        let result = analyzer.process(image, mask: mask, isNight: isNight)
        var dropped: [SkyDroppedTrack] = []
        if result.globalChange {
            _ = tracker.endAll(dropped: &dropped)
            dropped.removeAll()   // nothing open before the camera's picture jumped is trusted
            quietFrom = frame.time
            quietUntil = frame.time + Self.quietAfterChange
        } else {
            if let from = quietFrom, let until = quietUntil, frame.time < from || frame.time >= until {
                quietFrom = nil
                quietUntil = nil
            }
            let ended = tracker.update(quietUntil == nil ? result.detections : [], at: frame.time, wallClock: wallClock, dropped: &dropped)
            for track in ended { receive(track, analysisWidth: image.width, analysisHeight: image.height, pictureWidth: pictureWidth) }
        }
        for track in dropped { droppedTrack(track) }
        sampleVisibility(analyzer, mask: mask, at: wallClock)
    }

    /// The status's numbers of a picture.
    private func note(_ frame: SkyFrame, pictureWidth: Int) {
        lastPicture = .now
        analysisWidth = frame.image.width
        analysisHeight = frame.image.height
        self.pictureWidth = pictureWidth
        if let shown = frame.stream { stream = shown }
        if let place = frame.decoding { decoding = place }
        if let last = recentTimes.last, frame.time <= last { recentTimes.removeAll() }
        recentTimes.append(frame.time)
        if recentTimes.count > Self.rateSamples { recentTimes.removeFirst(recentTimes.count - Self.rateSamples) }
    }

    /// The Sun's circles and whether it is night, once a minute (and when the aim changed).
    private func refreshSky(at date: Date, pictureWidth: Int, pictureHeight: Int) {
        if let checked = skyChecked, date >= checked, date.timeIntervalSince(checked) < Self.skyRefresh, skyCheckedModel == model { return }
        skyChecked = date
        skyCheckedModel = model
        isNight = SunEphemeris.direction(at: date, observer: context.observer).elevation < SunEphemeris.darkElevation
        sunCircles = SkyMask.sunCircles(at: date, observer: context.observer, model: model, pictureWidth: pictureWidth, pictureHeight: pictureHeight)
    }

    /// How much of the sky is visible, once a minute: the conditions follow it.
    private func sampleVisibility(_ analyzer: SkyFrameAnalyzer, mask: SkyMask, at date: Date) {
        if let checked = visibilityChecked, date >= checked, date.timeIntervalSince(checked) < SkyVisibility.interval { return }
        visibilityChecked = date
        let visible = visibility.sample(analyzer.background, mask: mask, at: date, isNight: isNight)
        latestVisibility = visible   // kept with the state at the next save (every `saveInterval`, and at the stop)
        if let span = conditions.note(visible, at: date) { record(span) }
    }

    private func record(_ span: SkyConditions) {
        log.recordConditions(span, camera: context.cameraID, night: SkyNight.logName(for: span.from, observer: context.observer, zone: context.zone),
                             folder: context.folder())
    }

    // MARK: The status

    var status: SkyCameraStatus {
        let running = lastPicture.map { ContinuousClock.now - $0 < Self.runningWithin } ?? false
        var aim = aimStatus
        if watch.holds(at: now()) { aim.note = SkyMatchWatch.note }
        return SkyCameraStatus(running: running, stream: stream?.rawValue, analysisWidth: analysisWidth, picturesPerSecond: picturesPerSecond,
                               decoding: decoding?.rawValue, aim: aim, learning: learning)
    }

    /// Pictures a second over the last ones since the last break, to a tenth.
    private var picturesPerSecond: Double? {
        guard recentTimes.count >= 2, let first = recentTimes.first, let last = recentTimes.last, last > first else { return nil }
        return (Double(recentTimes.count - 1) / (last - first) * 10).rounded() / 10
    }

    /// The planes matched with a good aim (the baseline's, Task 11); ready at 30. No orbits are loaded in this phase, so satellites are not needed.
    private var learning: SkyLearning {
        SkyLearning(ready: learnedPlanes >= SkyLearning.planesNeeded, planes: learnedPlanes, satellites: 0)
    }

    // MARK: The queue

    /// A track that ended, from the tracker (`analyse` hands them over here; a test hands in the ones the tracker did not make), to the queue.
    func receive(_ track: SkyTrack, analysisWidth: Int, analysisHeight: Int, pictureWidth: Int) {
        enqueue(.ended(track, analysisWidth: analysisWidth, analysisHeight: analysisHeight, pictureWidth: pictureWidth))
    }

    private func enqueue(_ item: Work) {
        guard !stopped else { return }
        if case .ended = item {
            guard pending < Self.maximumPending else {
                if !behindLogged {
                    behindLogged = true
                    logger.warning("Sky Watcher for \(context.cameraName) is behind: lights it followed are not logged")
                }
                return
            }
            pending += 1
        }
        work.yield(item)
    }

    private func perform(_ item: Work) async {
        switch item {
        case .ended(let track, let analysisWidth, let analysisHeight, let pictureWidth):
            pending -= 1
            guard !stopped else { return }   // told to stop while it waited: dropped
            await handle(track, analysisWidth: analysisWidth, analysisHeight: analysisHeight, pictureWidth: pictureWidth)
        case .setStart:
            guard !stopped, let store = aimStore, let size = aimSize else { return }
            await store.setStart(card(width: size.width, height: size.height), pictureWidth: size.width, pictureHeight: size.height)
            await refreshAim()
        case .restartAim:
            guard !stopped else { return }
            await startAimAgain(reason: nil, quietly: true)   // before the first picture there is no aim to start again: it opens from the new card
        case .barrier(let continuation):
            continuation.resume()
        }
    }

    /// An ended track to the log (or, when it is a slow light that nothing explains, to the hour's count of them: Ruling S24). Internal for the
    /// tests, which hand it tracks without the tracker.
    func handle(_ track: SkyTrack, analysisWidth: Int, analysisHeight: Int, pictureWidth: Int) async {
        let measures = TrackMeasurer.measure(track, model: model, analysisWidth: analysisWidth, pictureWidth: pictureWidth)
        guard !TrackMeasurer.isStationary(measures) else { return }   // a light that stood still: Task 10's
        let verdict = await classified(track, measures: measures, analysisWidth: analysisWidth, analysisHeight: analysisHeight,
                                       pictureWidth: pictureWidth)
        var entry = verdict.entry
        let hour = SkyLightFilter.clockHour(of: entry.start, in: context.zone)
        guard !verdict.skipped else {
            slowLights.add(in: hour)   // a star, most likely: no entry, no picture, one line in the journal for the hour
            return
        }
        let night = SkyNight.logName(for: entry.start, observer: context.observer, zone: context.zone)
        let folder = context.folder()
        // A camera keeps at most `SkyLightFilter.stillsPerHour` pictures in a clock hour (of the light's start): each costs a software decode of a
        // keyframe and a file. Asking counts, whether or not the picture comes: a camera whose pictures fail would otherwise ask for every light.
        // Nor one once the detector is told to stop, nor while the drive is short of room (Ruling S27).
        if entry.label == .unexplained, !stopped, picturesAsked.count(in: hour) < SkyLightFilter.stillsPerHour, await context.roomForStills(), !stopped {
            picturesAsked.add(in: hour)
            let middle = entry.start.addingTimeInterval(entry.end.timeIntervalSince(entry.start) / 2)
            if let still = await context.still(middle.addingTimeInterval(-clockOffset)), !still.jpeg.isEmpty,
               still.jpeg.count <= SkyLogStore.maximumStillBytes {
                log.writeStill(still.jpeg, entryID: entry.id, camera: entry.camera, night: night, folder: folder)
                entry.hasStill = true
            }
        }
        log.record(entry, night: night, folder: folder)
    }

    /// The line the journal gets for each clock hour in which slow lights were skipped, once the hour is over (or the detector stops): how many.
    /// It names the camera and no place.
    private func sayHowManySlowLightsWereSkipped(before hour: Date) {
        for finished in slowLights.drain(before: hour) where finished.count > 0 {
            let lights = finished.count == 1 ? "1 slow light skipped this hour (likely a star)" : "\(finished.count) slow lights skipped this hour (likely stars)"
            logger.info("Sky Watcher, \(context.cameraName): \(lights)")
        }
    }

    // MARK: Classification

    /// What the classification pipeline makes of an ended track: the log's entry, and whether it is to be skipped (a light that nothing explains
    /// and that moved too slowly: Ruling S24, `SkyLightFilter`). A skipped light has left no trace in the aim, the planes' stretch or the search.
    private struct Classified {
        var entry: SkyEntry
        var skipped = false
    }

    /// The classification pipeline of an ended track: what explains it, as the log's entry (not written here). Phase 1: the flight feed (a match
    /// is `.plane`, or `.probablePlane` while the aim is rough, by `.flight`, with the flight's call sign and height; its correspondences go to
    /// the aim in one call); later tasks insert orbits, the rules, the local model and the AI after it, in this order. Nothing explains it:
    /// `.unexplained`, and a candidate while the camera is still learning its sky; unless it was slow, which `handle` does not log.
    func classify(_ track: SkyTrack, measures: SkyMeasures) async -> SkyEntry {
        let width = analysisWidth ?? min(max(1, pictureWidth), SkyStreamChoice.maximumAnalysisWidth)
        let height = analysisHeight ?? aimSize.map { max(1, Int((Double(width) * Double($0.height) / Double(max(1, $0.width))).rounded())) } ?? width
        return await classified(track, measures: measures, analysisWidth: width, analysisHeight: height, pictureWidth: pictureWidth).entry
    }

    private func classified(_ track: SkyTrack, measures: SkyMeasures, analysisWidth: Int, analysisHeight: Int, pictureWidth: Int) async -> Classified {
        var entry = Self.entry(of: track, measures: measures, camera: context.cameraID)
        let times = track.samples.map(\.wallClock).filter { $0.timeIntervalSince1970.isFinite }
        guard let from = times.min(), let to = times.max() else { return Classified(entry: entry) }
        let nearby = await flights.tracks(overlapping: from...to)
        let model = model, quality = quality, observer = context.observer
        var match: FlightMatch?
        if !nearby.isEmpty {
            match = await Task.detached(priority: .utility) {
                FlightMatcher.match(track, measures: measures, model: model, aim: quality, observer: observer, flights: nearby)
            }.value
        }
        if let match {
            entry.label = match.label
            entry.by = .flight
            entry.detail = match.detail
            watch.matched()
            if match.label == .plane {
                learnedPlanes += 1
                dirty = true
            }
            if let store = aimStore, !match.correspondences.isEmpty {
                _ = await store.add(match.correspondences)   // one pass in one call: the store thins it per aircraft
                await refreshAim()
            }
        } else if SkyLightFilter.isSlow(measures, pixelsPerSecond: SkyLightFilter.pixelSpeed(of: track, analysisWidth: analysisWidth, analysisHeight: analysisHeight),
                                        aimIsGood: aimIsGood(for: track))
                    || SkyLightFilter.wandersInPlace(track, analysisWidth: analysisWidth, analysisHeight: analysisHeight) {
            return Classified(entry: entry, skipped: true)   // nothing explains it, and it crawls or only wanders in place: not a light worth an entry
        } else {
            entry.candidate = !learning.ready
            watch.noteUnexplained()
            if quality == .rough, let kept = SkyAimSearch.record(of: track, analysisWidth: analysisWidth, pictureWidth: pictureWidth, flights: nearby,
                                                               observer: observer) {
                records.append(kept)
                if records.count > SkyAimSearch.maximumRecords { records.removeFirst(records.count - SkyAimSearch.maximumRecords) }
            }
        }
        return Classified(entry: entry)
    }

    /// Whether the aim of every lens that `track` was seen through is good or precise (a lens that has no fit yet, or none the status knows of,
    /// is not): then its speed in degrees can be trusted; else it is judged in pixels.
    private func aimIsGood(for track: SkyTrack) -> Bool {
        let lenses = Set(track.samples.map(\.lens))
        return !lenses.isEmpty && lenses.allSatisfy { aimStatus.lenses.indices.contains($0) && aimStatus.lenses[$0].quality != .rough }
    }

    /// `track` as an unexplained entry: its times (the box's), its path (at most 64 points, evenly picked, the first and the last among them; in
    /// the original picture, 0…1) and `measures`.
    static func entry(of track: SkyTrack, measures: SkyMeasures, camera: UUID) -> SkyEntry {
        let samples = track.samples.filter { $0.wallClock.timeIntervalSince1970.isFinite }.sorted { $0.wallClock < $1.wallClock }
        let start = samples.first?.wallClock ?? Date(timeIntervalSince1970: 0)
        let end = max(start, samples.last?.wallClock ?? start)
        let path = SkyAimSearch.evenly(samples, SkyPathPoint.maximumPerEntry).map {
            SkyPathPoint(t: $0.wallClock.timeIntervalSince(start), x: $0.point.x, y: $0.point.y)
        }
        return SkyEntry(id: newID(at: start), camera: camera, kind: .track, start: start, end: end, path: path, measures: measures, label: .unexplained)
    }

    /// An entry's id: its start in milliseconds and a random part, in hex ("19a1b2c3d4e-0f1e2d3c"): safe in a path, and unique.
    static func newID(at date: Date) -> String {
        let milliseconds = date.timeIntervalSince1970.isFinite ? UInt64(max(0, (date.timeIntervalSince1970 * 1_000).rounded())) : 0
        return String(format: "%llx-%08x", milliseconds, UInt32.random(in: .min ... .max))
    }

    // MARK: The aim

    private func openAim(width: Int, height: Int) {
        aimSize = PictureSize(width: width, height: height)
        pictureWidth = width
        model = card(width: width, height: height)
        aimStore = SkyAimStore(directory: directory, log: logger, start: model, pictureWidth: width, pictureHeight: height, now: now, seed: seed)
    }

    /// The card the aim starts from: the person's facing and tilt, moved by what the wide search found, and the lenses they set (else by the
    /// picture's shape: 2:1 and wider is two).
    private func card(width: Int, height: Int) -> SkyCameraModel {
        Self.card(context.settings, offset: cardOffset, width: width, height: height)
    }

    static func card(_ settings: SkyDetectorSettings, offset: SkyAimSearch.Card, width: Int, height: Int) -> SkyCameraModel {
        SkyCameraModel.initial(facing: settings.facing + offset.facing, tilt: min(90, max(0, settings.tilt + offset.tilt)), pictureWidth: width,
                               pictureHeight: height, layout: layout(settings.lensLayout))
    }

    static func layout(_ layout: SkyLensLayout?) -> SkyCameraModel.LensLayout? {
        switch layout {
        case .single?: .single
        case .dual?: .dual
        case nil: nil
        }
    }

    /// What the store says now: the model to match with, the card's status.
    private func refreshAim() async {
        guard let store = aimStore else { return }
        let model = await store.model(), status = await store.status()
        self.model = model
        quality = status.quality
        aimStatus = status
        tracker?.model = model
        tracker?.aimQuality = status.quality
    }

    // MARK: The minute's look

    /// The aircraft the aim puts in the view now, the wide search when it is due, and the state file. Called once a minute (and by tests).
    func tick(at date: Date) async {
        guard started, !stopped, aimStore != nil else { return }
        sayHowManySlowLightsWereSkipped(before: SkyLightFilter.clockHour(of: date, in: context.zone))
        let nearby = await flights.tracks(overlapping: date.addingTimeInterval(-60)...date)
        let seen = Self.aircraftInView(nearby, at: date, model: model, groundPercent: context.settings.groundPercent, observer: context.observer)
        // A plane the sky hides (cloud) is not one the camera could have matched.
        if latestVisibility.map({ $0 >= SkyVisibility.visibleShare }) ?? true { watch.saw(seen, at: date) }
        records.removeAll { date.timeIntervalSince($0.end) > SkyAimSearch.window || $0.end > date.addingTimeInterval(SkyAimSearch.window) }
        if watch.holds(at: date) {
            if quality != .rough {
                await startAimAgainForWantOfMatches()
            } else if !records.isEmpty, lastSearch.map({ date < $0 || date.timeIntervalSince($0) >= SkyAimSearch.interval }) ?? true {
                lastSearch = date
                await searchTheCard()
            }
        }
        if dirty || lastSave.map({ date < $0 || date.timeIntervalSince($0) >= Self.saveInterval }) ?? true { saveState(at: date) }
    }

    /// The aircraft of `flights` whose report nearest `date` (within a minute) puts them in the view of `model`: within `inViewRange`,
    /// `inViewElevation` up, and in a lens's part of the picture above the ground.
    static func aircraftInView(_ flights: [String: [AircraftReport]], at date: Date, model: SkyCameraModel, groundPercent: Int,
                               observer: SkyObserver) -> Set<String> {
        let ground = 1 - Double(min(100, max(0, groundPercent))) / 100
        var seen = Set<String>()
        for (hex, reports) in flights {
            guard let report = reports.filter(FlightMatcher.isUsable).min(by: {
                abs($0.positionTime.timeIntervalSince(date)) < abs($1.positionTime.timeIntervalSince(date))
            }), abs(report.positionTime.timeIntervalSince(date)) <= 60 else { continue }
            let there = SkyMath.direction(from: observer, toLatitude: report.latitude, longitude: report.longitude, altitudeMeters: report.altitudeMeters)
            guard there.rangeMeters <= inViewRange, there.direction.elevation >= inViewElevation else { continue }
            if model.project(there.direction).contains(where: { $0.point.y <= ground }) { seen.insert(hex) }
        }
        return seen
    }

    /// The wide search of the card (off the picture path and off the actor), and a clear winner adopted.
    private func searchTheCard() async {
        guard let size = aimSize else { return }
        let records = records, settings = context.settings, observer = context.observer
        let from = SkyAimSearch.Card(facing: settings.facing + cardOffset.facing, tilt: settings.tilt + cardOffset.tilt)
        let layout = Self.layout(settings.lensLayout)
        let found = await Task.detached(priority: .utility) {
            SkyAimSearch.search(records, from: from, layout: layout, pictureWidth: size.width, pictureHeight: size.height, observer: observer)
        }.value
        guard let found else {
            logger.info("Sky Watcher for \(context.cameraName): planes in view match no card near the one set")
            return
        }
        guard !stopped, quality == .rough, context.settings == settings, aimStore != nil else { return }
        cardOffset = SkyAimSearch.Card(facing: SkyAimSearch.difference(found.card.facing, settings.facing), tilt: found.card.tilt - settings.tilt)
        let note = SkyAimSearch.note(facing: cardOffset.facing, tilt: cardOffset.tilt)
        logger.notice("Sky Watcher for \(context.cameraName): \(note) (\(found.aircraft) aircraft)")
        self.records.removeAll()
        watch.restart()
        dirty = true
        saveState(at: now())
        await startAimAgain(reason: note)
    }

    /// Planes have flown through the view for the whole stretch (`SkyMatchWatch`) and none matched while the aim was good or precise: the camera
    /// has moved, or the aim was never right. The aim starts again from the card, rough, as a camera just added does, so that the wide search can
    /// run; the card says why until the aim is good again (Ruling S25).
    private func startAimAgainForWantOfMatches() async {
        guard aimStore != nil else { return }
        let quality = quality
        logger.info("Sky Watcher, \(context.cameraName): \(SkyMatchWatch.restartReason(for: quality))")
        forgetWhatWasFound()
        await startAimAgain(reason: SkyMatchWatch.restartNote(for: quality), quietly: true)
    }

    /// The aim starts again from the card as it is now: the fit and the matches go, `reason` is what the card says (nil: nothing), and the
    /// detector reads the aim afresh. `quietly`: the journal has been told already, in words of the detector's, so the store adds no line.
    private func startAimAgain(reason: String?, quietly: Bool = false) async {
        guard let store = aimStore, let size = aimSize else { return }
        await store.reset(reason: reason, quietly: quietly)
        await store.setStart(card(width: size.width, height: size.height), pictureWidth: size.width, pictureHeight: size.height)
        await refreshAim()
    }

    // MARK: What is kept

    /// `detector.json`. The visibility's memory and the conditions span are the sky's (no place); the card is the person's facing and tilt.
    private struct Saved: Codable {
        var v = 1
        var visibility: SkyVisibility?
        var conditions: SkyConditionsRecorder?
        var learnedPlanes: Int?
        var cardOffset: SkyAimSearch.Card?
        var cardFor: SkyAimSearch.Card?
    }

    private var stateURL: URL {
        directory.appending(path: Self.stateFileName, directoryHint: .notDirectory)
    }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (encoder, decoder)
    }

    private func loadState() {
        guard PrivateFiles.exists(stateURL) else { return }
        guard let data = try? Data(contentsOf: stateURL), let saved = try? Self.coder().1.decode(Saved.self, from: data) else {
            logger.warning("Sky Watcher's state for \(context.cameraName) (\(Self.stateFileName)) could not be read; it starts afresh")
            return
        }
        visibility = saved.visibility ?? SkyVisibility()
        conditions = saved.conditions ?? SkyConditionsRecorder()
        learnedPlanes = max(0, saved.learnedPlanes ?? 0)
        let person = SkyAimSearch.Card(facing: context.settings.facing, tilt: context.settings.tilt)
        if let offset = saved.cardOffset, saved.cardFor == person, offset.facing.isFinite, offset.tilt.isFinite { cardOffset = offset }
    }

    private func saveState(at date: Date) {
        lastSave = date
        dirty = false
        let person = SkyAimSearch.Card(facing: context.settings.facing, tilt: context.settings.tilt)
        let saved = Saved(visibility: visibility, conditions: conditions, learnedPlanes: learnedPlanes,
                          cardOffset: cardOffset == .zero ? nil : cardOffset, cardFor: cardOffset == .zero ? nil : person)
        do {
            try PrivateFiles.prepareDirectory(directory)
            try PrivateFiles.write(try Self.coder().0.encode(saved), to: stateURL)
            saveFailureLogged = false
        } catch {
            if !saveFailureLogged {
                saveFailureLogged = true
                logger.warning("Sky Watcher's state for \(context.cameraName) (\(Self.stateFileName)) could not be saved; it is kept in memory")
            }
        }
    }
}

// MARK: - The conditions

/// How the sky was, as spans for the log (`SkyConditions`), from the visible share a minute (`SkyVisibility`): clear at 0.6 or more, not visible
/// below 0.3, cloudy between, unknown when it is not known (by day, and before three nights). A span is written when the state changes, or once
/// it has lasted an hour; a silence of more than 5 minutes (no pictures) ends it at the last look. Kept with the detector's state, so a restart
/// loses nothing of the open span.
struct SkyConditionsRecorder: Codable, Sendable, Equatable {
    static let interval: TimeInterval = 3_600
    static let silence: TimeInterval = 300
    static let clearShare = 0.6
    static let visibleShare = 0.3

    private(set) var from: Date?
    private(set) var state: SkyConditionState?
    private(set) var last: Date?

    static func state(_ visibility: Double?) -> SkyConditionState {
        guard let visibility, visibility.isFinite else { return .unknown }
        if visibility >= clearShare { return .clear }
        return visibility < visibleShare ? .notVisible : .cloudy
    }

    /// The visible share at `date`; the span to write, when one ends.
    mutating func note(_ visibility: Double?, at date: Date) -> SkyConditions? {
        let now = Self.state(visibility)
        guard let from, let state, let last, date >= last, date.timeIntervalSince1970.isFinite else {
            self.from = date
            self.state = now
            self.last = date
            return nil
        }
        if date.timeIntervalSince(last) > Self.silence {
            self.from = date
            self.state = now
            self.last = date
            return SkyConditions(from: from, to: last, state: state)
        }
        self.last = date
        guard now != state || date.timeIntervalSince(from) >= Self.interval else { return nil }
        self.from = date
        self.state = now
        return SkyConditions(from: from, to: date, state: state)
    }

    /// The open span, to its last look (the detector stops); nil when none is open.
    mutating func close() -> SkyConditions? {
        defer {
            from = nil
            state = nil
            last = nil
        }
        guard let from, let state, let last else { return nil }
        return SkyConditions(from: from, to: last, state: state)
    }
}

// MARK: - Planes that match nothing

/// Whether planes have flown through the view for two hours and matched nothing (Ruling S18): the sign of a card whose facing or tilt is far off,
/// or of a camera that moved. The stretch begins with the first aircraft seen in view after the last match (or the start, or a new card), and
/// holds once it has lasted `window` with `minimumAircraft` aircraft in view and `minimumUnexplained` lights followed that nothing explained (a
/// camera that sees nothing, in fog, says nothing about its aim).
struct SkyMatchWatch: Sendable, Equatable {
    static let window: TimeInterval = 7_200
    static let minimumAircraft = 5
    static let minimumUnexplained = 5
    static let note = "Planes are flying through the view but none match: check which way the camera faces"

    /// What a good or precise aim does when this holds (Ruling S25), in the journal's words and, capitalised with a full stop, the card's note.
    static func restartReason(for quality: SkyAimQuality) -> String {
        "no planes matched for \(Int(window / 3_600)) hours with the aim \(quality.rawValue); starting the aim again"
    }

    static func restartNote(for quality: SkyAimQuality) -> String {
        let reason = restartReason(for: quality)
        return reason.prefix(1).uppercased() + reason.dropFirst() + "."
    }
    /// More aircraft than this need not be told apart.
    private static let keptAircraft = 32

    private(set) var since: Date?
    private(set) var aircraft: Set<String> = []
    private(set) var unexplained = 0

    mutating func saw(_ hexes: Set<String>, at date: Date) {
        guard !hexes.isEmpty else { return }
        if let since, date < since { self = SkyMatchWatch() }   // the clock went back: start again
        if since == nil { since = date }
        for hex in hexes.sorted() where aircraft.count < Self.keptAircraft { aircraft.insert(hex) }
    }

    mutating func noteUnexplained() {
        unexplained = min(unexplained + 1, 1_000_000)
    }

    mutating func matched() {
        self = SkyMatchWatch()
    }

    mutating func restart() {
        self = SkyMatchWatch()
    }

    func holds(at date: Date) -> Bool {
        guard let since else { return false }
        return date.timeIntervalSince(since) >= Self.window && aircraft.count >= Self.minimumAircraft && unexplained >= Self.minimumUnexplained
    }
}
