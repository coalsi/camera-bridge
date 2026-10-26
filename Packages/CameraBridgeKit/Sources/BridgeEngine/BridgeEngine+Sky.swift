import BridgeSupport
import CameraAdapters
import FMP4
import Foundation
import MediaCore

// The Sky Watcher's face on the engine: its detectors started and stopped with the bridge, the plugin, each camera's switch and the settings
// they need (`applySky`), each camera's status (`CameraStatus.sky`), the sky log of a night or a day with its corrections and pictures, the flight
// feeds on the home network, and the facts about a camera it needs. The log is kept beside the recordings (`SkyLogStore`, in `ArchiveStore`);
// the detectors and the flight feed are the service's (`SkyService`).

extension CameraConfiguration {
    /// The camera streams only while something wants its picture (a battery camera that sleeps between views: `CameraDriver.streamsOnDemand`).
    /// The Sky Watcher cannot watch such a camera: it would keep it awake all night. Decided from the configuration, without making a driver
    /// (a test keeps it equal to what every driver says).
    public var streamsOnDemand: Bool {
        vendor == .go2rtc && integration?.service == .eufy
    }
}

extension ArchiveStore {
    /// Runs blocking reads of the sky log on the read queue, with its deadline: a drive that does not answer is `ArchiveError.timedOut` (and the
    /// reads that follow fail at once until a probe hears from the drive), one that is away `ArchiveUnavailable.folderMissing`. The sky log
    /// does not wait for the catalog to load: it is a few files, and the folder is all it needs.
    func skyRead<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try state.withLock { state in
            if state.running, state.pause == .folderMissing { throw ArchiveUnavailable.folderMissing }
            if state.readsStalled { throw ArchiveError.timedOut }
        }
        do {
            return try await reads.run(work)
        } catch let error as ArchiveError {
            if error == .timedOut { markReadsStalled() }
            throw error
        }
    }
}

extension BridgeEngine {
    /// The sky log (`nvr.store.skyLog`): the detector writes it, `skyNightLog` reads it.
    var skyLog: SkyLogStore { nvr.store.skyLog }

    /// The recordings folder the log is kept in; nil while none is chosen.
    var skyFolder: URL? {
        settings.nvrFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The log of one camera's night or day. `night` is the log's name (`SkyNight.logName`: the local date of the night's sunset, a day's own
    /// date, in the bridge's time zone), nil for the latest: the night in progress or the one that ended this morning, or for the day view the day
    /// `now` is in. `view` picks what is shown of it: the night from sunset to sunrise, the day from sunrise to sunset. Times and nights are the
    /// sun's at the place the box is. The lights the log kept in pieces are one entry each (`SkyStitch.joined`), and the lights logged before the
    /// rules are sorted by them now (`SkySortLater`, a joined light as one: shown as if logged so, marked `sortedLater`); the log is not written.
    /// Throws `EngineError.unknownCamera`, `SkyLogError` (no place, no recordings folder, a night that is not a date) and, while the drive cannot be
    /// read, `ArchiveUnavailable` or `ArchiveError.timedOut`.
    public func skyNightLog(cameraID: UUID, night: String?, view: SkyLogView) async throws -> SkyNightLog {
        try await skyNightLog(cameraID: cameraID, night: night, view: view, now: Date())
    }

    func skyNightLog(cameraID: UUID, night: String?, view: SkyLogView, now: Date) async throws -> SkyNightLog {
        guard !isPreview else { throw SkyLogError.unavailable }
        guard configurations.contains(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
        if let night { try Self.checkNight(night) }
        guard let location = settings.sky.location else { throw SkyLogError.noLocation }
        guard let folder = skyFolder else { throw SkyLogError.noFolder }
        let observer = SkyObserver(latitude: location.latitude, longitude: location.longitude, heightMeters: location.heightMeters)
        let zone = BridgeTime.zone
        let name = night ?? SkyNight.latestLogName(view: view, now: now, observer: observer, zone: zone)
        let span = SkyNight.logSpan(named: name, view: view, observer: observer, zone: zone)
        let log = skyLog
        let stored = try await nvr.store.skyRead { try Self.readNight(log, camera: cameraID, night: name, folder: folder) }
        let inView = stored.entries.filter { $0.start >= span.lowerBound && $0.start < span.upperBound }
        let conditions = stored.conditions.filter { $0.to > span.lowerBound && $0.from < span.upperBound }
        let capped = stored.capped.filter { $0.hour.addingTimeInterval(3_600) > span.lowerBound && $0.hour < span.upperBound }
        let status = await skyStatus(of: cameraID)
        let picture = await skyPictureSize(of: inView, camera: cameraID, night: name, folder: folder)
        // The lights the log kept in pieces are joined first (`SkyStitch.joined`); then the lights logged before the rules are sorted by them
        // (`SkySortLater`: a joined light as one), and the lights that moved together are found among them (`SkyFormations`), as the log is read: a
        // person's word on one counts at once. Off the main actor: a night can hold thousands.
        let joined = await skyJoined(inView, cameraID: cameraID, observer: observer, stills: picture, corrected: stored.corrected)
        let sorter = joined.contains(where: SkySortLater.needsSorting)
            ? SkySortLater(observer: observer, camera: await skySortingCamera(cameraID, stills: picture)) : nil
        let night = stored.entries
        let entries = await Task.detached(priority: .userInitiated) { SkyFormations.mark(sorter?.sort(joined, night: night) ?? joined) }.value
        return SkyNightLog(camera: cameraID, night: name, view: view, from: span.lowerBound, to: span.upperBound, entries: entries, conditions: conditions,
                           counts: SkyCounts(counting: entries), aim: status.aim, learning: status.learning, capped: capped, picture: picture)
    }

    /// `entries` (a night's, in their order) with the lights the log kept in pieces joined into one entry each (`SkyStitch.joined`), off the main actor (a
    /// night can hold thousands): in the camera's picture as the joining reads it (`skyStitchPicture`), by day where the Sun was at −6° or above at
    /// `observer` (the box's place; with none, never by day), the latest correction of a joined light's parts showing (`corrected`).
    func skyJoined(_ entries: [SkyEntry], cameraID: UUID, observer: SkyObserver?, stills: SkyPictureSize?, corrected: [String: Date]) async -> [SkyEntry] {
        guard entries.count >= 2 else { return entries }
        let picture = skyStitchPicture(cameraID, stills: stills)
        return await Task.detached(priority: .userInitiated) {
            SkyStitch.joined(entries, picture: picture, isDay: { date in
                observer.map { SunEphemeris.direction(at: date, observer: $0).elevation >= SunEphemeris.darkElevation } ?? false
            }, corrected: corrected)
        }.value
    }

    /// A camera's picture as the joining reads it: the analysed size (the picture's, at most `SkyStreamChoice.maximumAnalysisWidth` wide, from the camera's
    /// main stream as last seen, else from the night's `stills`, else 1,920 × 1,080) and, for two lenses side by side (as the camera is set, else 2:1 and
    /// wider), the seam.
    func skyStitchPicture(_ cameraID: UUID, stills: SkyPictureSize?) -> SkyStitch.Picture {
        let stream = cameras.first { $0.id == cameraID }?.mainStreamInfo.flatMap { info -> SkyPictureSize? in
            info.width > 0 && info.height > 0 ? SkyPictureSize(width: info.width, height: info.height) : nil
        }
        let size = stream ?? stills
        let width = Double(size?.width ?? SkyStreamChoice.maximumAnalysisWidth), height = Double(size?.height ?? 1_080)
        let analysed = min(width, Double(SkyStreamChoice.maximumAnalysisWidth))
        let layout = configurations.first { $0.id == cameraID }?.skyDetector?.lensLayout
        let dual = layout.map { $0 == .dual } ?? (width / height >= 2)
        return SkyStitch.Picture(width: analysed, height: analysed * height / width, seam: dual ? SkyCameraModel.defaultSeam : nil)
    }

    /// What the log's reader knows of a camera to sort the lights logged before the rules (`SkySortLater`): its detector's while it runs (the aim
    /// now, the width it analyses at, the picture's size, its pace and what it learned); otherwise, or while its detector has seen no picture,
    /// the card (its facing, tilt and lenses) over the picture's size as last seen (the camera's stream, else `stills`: the night's pictures'),
    /// with what the camera learned (the detector's, else its `baseline.json`, else the defaults).
    func skySortingCamera(_ cameraID: UUID, stills: SkyPictureSize?) async -> SkySortLater.Camera {
        var running: SkySortLater.Camera?
        if let detector = skyDetectors[cameraID] {
            let camera = await detector.sortingCamera
            if camera.model != nil { return camera }
            running = camera
        }
        let settings = configurations.first { $0.id == cameraID }?.skyDetector ?? SkyDetectorSettings()
        let stream = cameras.first { $0.id == cameraID }?.mainStreamInfo.flatMap { $0.width > 0 && $0.height > 0 ? SkyPictureSize(width: $0.width, height: $0.height) : nil }
        let size = stream ?? stills
        var baseline = running?.baseline
        if baseline == nil {
            let directory = SkyService.directory(of: cameraID, in: environment.dataDirectory)
            baseline = await Task.detached(priority: .userInitiated) { SkyCameraDetector.readBaseline(in: directory) }.value
        }
        let model = size.map { SkyCameraDetector.card(settings, offset: .zero, width: $0.width, height: $0.height) }
        return SkySortLater.Camera(model: model, analysisWidth: min(max(1, size?.width ?? 1), SkyStreamChoice.maximumAnalysisWidth), picture: size,
                                   baseline: baseline ?? SkyBaseline(), picturesPerSecond: running?.picturesPerSecond ?? SkyStreamChoice.analysisRate)
    }

    /// How big the pictures of a night are, for the page to draw a light's path over a thumbnail of it (the thumbnail is cut where the page's close-up is,
    /// and that depends on the picture's size): from the newest of `entries` with a picture that can be read; nil when none can (no picture, or the drive
    /// does not answer: the page then asks for the whole pictures).
    private func skyPictureSize(of entries: [SkyEntry], camera: UUID, night: String, folder: URL) async -> SkyPictureSize? {
        let ids = entries.filter(\.hasStill).suffix(SkyLogStore.pictureProbeLimit).reversed().map(\.id)
        guard !ids.isEmpty else { return nil }
        let log = skyLog
        return try? await nvr.store.skyRead { log.pictureSize(ofStills: Array(ids), camera: camera, night: night, folder: folder) }
    }

    /// Records the person's word on an entry ("That was a bird") in the log of `night` and answers the entry as it reads now: a light the log kept in
    /// pieces is one entry (`SkyStitch.joined`, within the view the entry began in, as `skyNightLog` shows it), and the word goes to every part of it
    /// (one line each, append-only); one logged before the rules is sorted by them (`SkySortLater`, a joined light as one). The word counts most to what
    /// the box learns; the last one of an entry wins, and "not sure" takes the doubt back. Throws `EngineError.unknownCamera` and `SkyLogError`
    /// (`unknownNight` for a name that is not a date, `unknownEntry` for one the night's log does not hold, `noFolder`).
    public func correctSkyEntry(cameraID: UUID, entryID: String, night: String, label: SkyCorrection) async throws -> SkyEntry {
        guard !isPreview else { throw SkyLogError.unavailable }
        guard configurations.contains(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
        try Self.checkNight(night)
        guard SkyEntry.isValidID(entryID) else { throw SkyLogError.unknownEntry }
        guard let folder = skyFolder else { throw SkyLogError.noFolder }
        let log = skyLog
        let stored = try await nvr.store.skyRead { try Self.readNight(log, camera: cameraID, night: night, folder: folder) }
        guard let said = stored.entries.first(where: { $0.id == entryID }) else { throw SkyLogError.unknownEntry }
        let observer = settings.sky.location.map { SkyObserver(latitude: $0.latitude, longitude: $0.longitude, heightMeters: $0.heightMeters) }
        // Joined as the page showed it: within the view (the night or the day) the entry began in, as `skyNightLog` joins it.
        let spans = observer.map { observer in
            [SkyLogView.night, .day].map { SkyNight.logSpan(named: night, view: $0, observer: observer, zone: BridgeTime.zone) }
        } ?? []
        let inView = spans.first { said.start >= $0.lowerBound && said.start < $0.upperBound }.map { span in
            stored.entries.filter { $0.start >= span.lowerBound && $0.start < span.upperBound }
        } ?? stored.entries
        let stills = await skyPictureSize(of: inView, camera: cameraID, night: night, folder: folder)
        let joined = await skyJoined(inView, cameraID: cameraID, observer: observer, stills: stills, corrected: stored.corrected)
        var entry = joined.first { $0.id == entryID || $0.parts.contains(entryID) } ?? said
        let at = Date()
        for part in entry.parts.isEmpty ? [entryID] : entry.parts {
            log.recordCorrection(label, entryID: part, camera: cameraID, night: night, folder: folder, at: at)
        }
        entry.correction = label
        // The answer is the entry as the log reads it: one logged before the rules sorted by them, a joined light as one, as `skyNightLog` sorts it.
        if SkySortLater.needsSorting(entry), let observer {
            let sorter = SkySortLater(observer: observer, camera: await skySortingCamera(cameraID, stills: stills))
            let one = entry, all = stored.entries
            entry = await Task.detached(priority: .userInitiated) { sorter.sort([one], night: all).first ?? one }.value
        }
        return entry
    }

    /// The JPEG of an entry (the camera's original picture, as it was when the light crossed). Throws `EngineError.unknownCamera`, `SkyLogError`
    /// (`noStill` for an entry without a picture or one that is not there any more, `unknownNight`, `noFolder`).
    public func skyStill(cameraID: UUID, night: String, entryID: String) async throws -> Data {
        guard !isPreview else { throw SkyLogError.unavailable }
        guard configurations.contains(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
        try Self.checkNight(night)
        guard SkyEntry.isValidID(entryID) else { throw SkyLogError.noStill }
        guard let folder = skyFolder else { throw SkyLogError.noFolder }
        let log = skyLog
        let jpeg = try await nvr.store.skyRead { () throws -> Data? in
            guard SkyLogStore.folderExists(folder) else { throw ArchiveUnavailable.folderMissing }
            return log.still(camera: cameraID, night: night, entryID: entryID, folder: folder)
        }
        guard let jpeg else { throw SkyLogError.noStill }
        return jpeg
    }

    /// The small picture of an entry for the Sky Watcher's grid (`GET sky/cameras/:id/entries/:eid/still?size=thumb`): the close-up of the light around its
    /// path, at most 480 pixels wide, or all of the picture, small, for a light that crossed more of the sky than a close-up holds (`SkyThumbnails`). Made when
    /// the picture is written (`skyContext`'s `stillWritten`), else when the page first asks, and kept beside the picture; the whole picture (`isThumbnail`
    /// false) when a small one cannot be made. Throws what `skyStill` throws.
    public func skyStillThumbnail(cameraID: UUID, night: String, entryID: String) async throws -> SkyStillPicture {
        guard !isPreview else { throw SkyLogError.unavailable }
        guard configurations.contains(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
        try Self.checkNight(night)
        guard SkyEntry.isValidID(entryID) else { throw SkyLogError.noStill }
        guard let folder = skyFolder else { throw SkyLogError.noFolder }
        return try await skyThumbnails.picture(camera: cameraID, night: night, entryID: entryID, folder: folder)
    }

    /// A night's name that is a real date ("2026-10-24"; not "2026-02-30" or "tonight").
    nonisolated static func checkNight(_ name: String) throws {
        guard SkyLogStore.isValidNight(name), SkyNight.localDay(named: name, zone: BridgeTime.zone) != nil else { throw SkyLogError.unknownNight }
    }

    nonisolated static func readNight(_ log: SkyLogStore, camera: UUID, night: String, folder: URL) throws -> SkyLogContents {
        guard SkyLogStore.folderExists(folder) else { throw ArchiveUnavailable.folderMissing }
        return log.contents(camera: camera, night: night, folder: folder)
    }

    /// The camera's aim and learning for the log: its detector's while it runs; otherwise not fitted, with nothing matched.
    func skyStatus(of cameraID: UUID) async -> (aim: SkyAimStatus, learning: SkyLearning) {
        if let detector = skyDetectors[cameraID] {
            let status = await detector.status
            return (status.aim, status.learning)
        }
        return (SkyAimStatus.unaimed(), SkyLearning(ready: false, planes: 0, satellites: 0))
    }

    // MARK: The detectors

    /// Why a camera whose Sky Watcher is on cannot watch the sky now, in the person's words; nil when it can.
    func skyProblem(_ camera: CameraConfiguration) -> String? {
        if camera.streamsOnDemand { return Self.skyBatteryProblem }
        guard let location = settings.sky.location, location.isValid else { return SkyLogError.noLocation.description }
        guard skyFolder != nil else { return SkyLogError.noFolder.description }
        return nil
    }

    nonisolated static let skyBatteryProblem = "Battery cameras can’t watch the sky: it would keep them awake."

    /// Whether a change of the settings changes what the Sky Watcher runs: the plugin, the place, the feed, the recordings folder, the zone.
    nonisolated static func skyChanged(_ old: BridgeSettings, _ new: BridgeSettings) -> Bool {
        old.skyPluginOn != new.skyPluginOn || old.sky != new.sky || old.nvrFolder != new.nvrFolder || old.timeZone != new.timeZone
    }

    /// Runs a detector for every camera that can watch the sky now and none for the others (Ruling S21: only while the plugin is on and the
    /// camera's switch is on; and only with a place and a recordings folder, else its status says why), gives each running camera's pictures to
    /// its detector and takes them back from one that stopped. The flight feed is asked only while a detector runs (`SkyService`). Called with
    /// the operations held: at the start, and whenever the plugin, the settings it needs or a camera change.
    func applySky() async {
        guard !isPreview, let service = skyService else { return }
        var contexts: [UUID: SkyCameraDetector.Context] = [:]
        if isActive, settings.skyPluginOn {
            for camera in configurations where camera.isEnabled && camera.skyDetector?.enabled == true && skyProblem(camera) == nil {
                if let context = skyContext(camera) { contexts[camera.id] = context }
            }
        }
        let running = await service.update(settings: settings.sky, cameras: contexts)
        skyDetectors = running
        for (id, link) in skyLinks where running[id] !== link.detector {
            skyLinks[id] = nil
            if let runtime = link.runtime, runtime === runtimes[id] { await runtime.stopSky() }
        }
        for id in running.keys.sorted(by: { $0.uuidString < $1.uuidString }) { await startSkyIfWanted(id) }
    }

    /// Gives the camera's running runtime's pictures to its detector, unless they go to it already (a runtime that started again is new: the
    /// detector cuts what it was following).
    func startSkyIfWanted(_ cameraID: UUID) async {
        guard let detector = skyDetectors[cameraID], let runtime = runtimes[cameraID] else { return }
        if let link = skyLinks[cameraID], link.runtime === runtime, link.detector === detector { return }
        await detector.restarted()
        guard await runtime.startSky(sink: detector) else { return }   // an on-demand camera, or one that is not running
        skyLinks[cameraID] = SkyLink(runtime: runtime, detector: detector)
    }

    /// The bridge pauses or stops: every detector writes what it keeps, and nothing more is fetched. Bounded (Ruling S27): the detectors stop
    /// in about a second at the most, and the sky is the least of what a restart must save in the ten seconds it has.
    func stopAllSky() async {
        skyLinks.removeAll()
        skyDetectors.removeAll()
        guard let service = skyService else { return }
        _ = try? await withDeadline(Self.skyStopLimit, followsCancellation: false) { await service.stop() }
    }

    nonisolated static let skyStopLimit: Duration = .seconds(2)

    /// The camera is removed: its detector stops and its aim is deleted.
    func removeSky(_ cameraID: UUID) async {
        skyLinks[cameraID] = nil
        skyDetectors[cameraID] = nil
        await skyService?.remove(cameraID)
    }

    /// The camera's Sky Watcher for its card: nil while it is off (the plugin or the camera's switch); its detector's status while one runs (with
    /// the flight feed's trouble when it has none of its own); else not watching, and why.
    func skyCameraStatus(_ camera: CameraConfiguration) async -> SkyCameraStatus? {
        guard settings.skyPluginOn, camera.skyDetector?.enabled == true else { return nil }
        guard let detector = skyDetectors[camera.id] else { return .stopped(isActive && camera.isEnabled ? skyProblem(camera) : nil) }
        var status = await detector.status
        if status.problem == nil, let feed = await skyService?.feedProblem { status.problem = feed }
        return status
    }

    /// What a camera's detector is told of it: its settings, the place as an observer (kept on the box), the bridge's zone, the picture's size
    /// when the camera has shown one, the recordings folder, its stills, and for the lights logged without one a picture of its recording and
    /// its logs (Ruling S31: read on the store's read queue, and the pictures made one at a time for all the cameras, off the main actor, at
    /// utility priority); and, once a picture is handed to the log, its small one for the grid made then (`SkyThumbnails.prepare`: at background
    /// priority, once the log's queue has written the picture and its line, in the thumbnails' own places after the page's requests).
    func skyContext(_ camera: CameraConfiguration) -> SkyCameraDetector.Context? {
        guard let location = settings.sky.location, location.isValid, let detectorSettings = camera.skyDetector else { return nil }
        let id = camera.id, folder = skyFolder
        let size = cameras.first { $0.id == id }?.mainStreamInfo
        let archive = archive, store = nvr.store, log = skyLog, codecs = environment.codecs, thumbnails = skyThumbnails
        let decoders = skyRecordingDecoders, oneAtATime = skyRecordingPictures
        return SkyCameraDetector.Context(cameraID: id, cameraName: camera.name, settings: detectorSettings,
                                         observer: SkyObserver(latitude: location.latitude, longitude: location.longitude, heightMeters: location.heightMeters),
                                         zone: BridgeTime.zone, pictureWidth: size?.width ?? 0, pictureHeight: size?.height ?? 0, folder: { folder },
                                         still: { [weak self] date in await self?.skyStillPicture(cameraID: id, around: date) },
                                         roomForStills: { [weak self] in await self?.skyStillsHaveRoom() ?? false },
                                         recordedStill: { date in
                                             await Task.detached(priority: .utility) {
                                                 await oneAtATime.withLock {
                                                     await Self.skyRecordedStill(camera: id, at: date, archive: archive, decoders: decoders, codecs: codecs)
                                                 }
                                             }.value
                                         },
                                         readLog: { night in
                                             guard let folder else { return nil }
                                             return try? await store.skyRead { try Self.readNight(log, camera: id, night: night, folder: folder).entries }
                                         },
                                         stillWritten: { entryID, night in
                                             guard let folder else { return }
                                             Task.detached(priority: .background) {
                                                 await log.flush()
                                                 await thumbnails.prepare(camera: id, night: night, entryID: entryID, folder: folder)
                                             }
                                         })
    }

    /// A time this long after the newest recording that holds nothing is a camera that does not record now (rather than a fragment not written
    /// yet): its picture is not to be had from the recordings.
    nonisolated static let skyRecordingLag: TimeInterval = 600

    /// A picture of the camera's recording at `date` (the box's clock, which the recordings keep too) for a light of the sky log that has none
    /// (Ruling S31): the keyframe of the group of pictures that holds the time, or the next keyframe when that is nearer, made as a live one is
    /// (`CameraRuntime.skyStill`: the camera's own picture, never straightened, at full size and quality 0.8; then at most 1920 wide,
    /// `skyStillJPEG`). `.gone` when nothing was recorded then or it is gone (before the oldest recording, in a gap, a camera with none, a time
    /// `skyRecordingLag` past the newest, a file that went); `.later` while the recordings load, the time is not written yet or the drive does
    /// not answer; `.failed` when no picture could be made of it.
    nonisolated static func skyRecordedStill(camera: UUID, at date: Date, archive: any ArchiveReading, decoders: SnapshotDecoderPool,
                                             codecs: any MediaCodecs) async -> SkyRecordedStill {
        guard archive.isReady else { return .later }
        guard date.timeIntervalSince1970.isFinite, let extent = archive.extent(camera: camera), date >= extent.oldest else { return .gone }
        guard date < extent.newest else { return date.timeIntervalSince(extent.newest) > skyRecordingLag ? .gone : .later }
        guard let target = await archive.fragment(camera: camera, containing: date) else { return .gone }
        var key = target
        if target.backToKey > 0 {
            let id = ArchiveIdentity.fragmentID(fileKey: target.fileKey, index: target.index - target.backToKey)
            guard let governing = await archive.fragment(camera: camera, id: id) else { return .gone }
            key = governing
        }
        guard key.hasKeyframe else { return .gone }
        if let next = await nextKeyframe(after: target, camera: camera, before: date.addingTimeInterval(date.timeIntervalSince(key.start)), archive: archive) {
            key = next
        }
        do {
            let bytes = try await archive.read(key, .keyframe)
            let info = try FMP4InitReader.parse(try await archive.read(key, .initialization))
            let frame = try FMP4FrameSlicer.frame(fromKeyframeBytes: bytes, info: info, start: key.start)
            let picture = try await decoders.jpeg(fromKeyframe: frame, maxWidth: nil, maxHeight: nil, quality: 0.8)
            guard let smaller = await skyStillJPEG(picture, codecs: codecs) else { return .failed }
            return .made(smaller)
        } catch ArchiveError.fileGone {
            return .gone
        } catch ArchiveError.timedOut {
            return .later
        } catch {
            return .failed
        }
    }

    /// The first fragment after `fragment` that starts on a keyframe and begins before `deadline` (one after it is no nearer than the keyframe
    /// already found); nil when there is none.
    nonisolated private static func nextKeyframe(after fragment: ArchiveFragment, camera: UUID, before deadline: Date,
                                                 archive: any ArchiveReading) async -> ArchiveFragment? {
        var last = fragment
        for _ in 0..<64 {
            guard let next = await archive.fragment(camera: camera, startingAfter: last.start), next.start > last.start, next.start < deadline else { return nil }
            if next.hasKeyframe { return next }
            last = next
        }
        return nil
    }

    /// Whether the recordings drive has room for a picture of the sky: at least twice its floor free (Ruling S27, `SkyLightFilter`). Pictures
    /// are not worth a drive that is close to pausing every camera's recording.
    func skyStillsHaveRoom() -> Bool {
        SkyLightFilter.stillsHaveRoom(nvr.storageStatus())
    }

    /// A still for the sky log: the camera's own picture nearest `date` (`CameraRuntime.skyStill`), at most `skyStillWidth` wide (a stitched
    /// camera's full picture is about 1 MB; the log keeps one for each light nothing explains, at most 30 an hour). nil when the picture cannot
    /// be made smaller: a full-size one is not kept.
    func skyStillPicture(cameraID: UUID, around date: Date) async -> (jpeg: Data, at: Date)? {
        guard let runtime = runtimes[cameraID], let still = await runtime.skyStill(around: date),
              let smaller = await Self.skyStillJPEG(still.jpeg, codecs: environment.codecs) else { return nil }
        return (smaller, still.at)
    }

    /// `jpeg` made at most `skyStillWidth` wide, off the main actor; nil when `codecs` cannot (or answers nothing).
    nonisolated static func skyStillJPEG(_ jpeg: Data, codecs: any MediaCodecs) async -> Data? {
        let smaller = try? await offMain { try codecs.resizeJPEG(jpeg, maxWidth: skyStillWidth, maxHeight: nil) }
        guard let smaller, !smaller.isEmpty else { return nil }
        return smaller
    }

    nonisolated static let skyStillWidth = 1920

    // MARK: Flight feeds

    /// How long "Find a feed" looks before it answers with what it has.
    nonisolated static let feedSearchLimit: Duration = .seconds(20)

    /// The flight feeds on the box's own network (dump1090, readsb, tar1090 and PiAware's SkyAware), for Settings to offer: the first place that
    /// answers on each host, in the finder's own order, so one Pi shows up once. It asks only the hosts in the box's neighbour table, a few
    /// places each (`FlightFeedFinder`), for at most 20 s. Where the box has no neighbour table (not Linux) it finds nothing.
    public func findFlightFeeds() async -> [URL] {
        await Self.findFeeds(http: URLSessionSkyHTTP(), neighbours: { NeighborTable.read() ?? "" })
    }

    func findFlightFeeds(http: any SkyHTTP, neighbours: String) async -> [URL] {
        await Self.findFeeds(http: http, neighbours: { neighbours })
    }

    nonisolated private static func findFeeds(http: any SkyHTTP, neighbours: @escaping @Sendable () -> String) async -> [URL] {
        let table = neighbours()
        let search = Task { await FlightFeedFinder.find(http: http, neighbours: table) }
        let limit = Task {
            try? await Task.sleep(for: feedSearchLimit)
            search.cancel()
        }
        let found = await search.value
        limit.cancel()
        return onePerHost(found)
    }

    /// `urls` with only the first of each host (a Pi serves its feed at `/skyaware/…`, on `:8080` and at `/tar1090/…`), in their order.
    nonisolated static func onePerHost(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            guard let host = url.host?.lowercased() else { return false }
            return seen.insert(host).inserted
        }
    }
}

/// A camera runtime whose pictures go to a detector (`BridgeEngine.startSkyIfWanted`): the runtime is held weakly (it is replaced when the camera
/// starts again).
struct SkyLink {
    weak var runtime: CameraRuntime?
    let detector: SkyCameraDetector
}
