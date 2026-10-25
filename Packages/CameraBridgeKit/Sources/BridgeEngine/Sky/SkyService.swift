import BridgeSupport
import Foundation

/// The Sky Watcher's side of the box (Task 7): a detector for each camera that watches the sky (`SkyCameraDetector`), one flight history they
/// share, and the flight feed's poller. **Nothing is fetched while no detector runs**: the poller runs only while at least one does and a feed
/// is set, and turning the last one off stops it (it returns when nothing is in flight). The engine gives it the cameras that can watch the sky
/// now (the plugin on, the camera's switch on, a place and a recordings folder known: `BridgeEngine.applySky`), every time any of that changes.
///
/// Each camera keeps its aim and the detector's own state in `<data>/sky/<camera-uuid>/` (`directory(of:in:)`): kept when the detector is
/// turned off, removed with the camera (`remove`). Those files stay on the box (the aim's matches, with their times, tell where it is).
actor SkyService {
    /// How often the feed is asked (`FlightFeedPoller`).
    static let pollInterval: Duration = .seconds(1)

    /// The aircraft the feed told of lately, for every detector.
    let flights = FlightHistory()
    private let dataDirectory: URL
    private let http: any SkyHTTP
    private let logStore: SkyLogStore
    private let now: @Sendable () -> Date
    private let pollInterval: Duration
    private let logger = Log(category: "Sky")
    private let changes = AsyncSerialLock()
    private var detectors: [UUID: SkyCameraDetector] = [:]
    private var poller: FlightFeedPoller?
    private var polled: URL?

    /// `dataDirectory`: the bridge's (each camera's folder is `sky/<camera-uuid>/` in it); `http`: the one client for the feed
    /// (`URLSessionSkyHTTP`); `logStore`: the sky log beside the recordings; `now`: the box's clock.
    init(dataDirectory: URL, http: any SkyHTTP, logStore: SkyLogStore, now: @escaping @Sendable () -> Date = { Date() },
         pollInterval: Duration = SkyService.pollInterval) {
        self.dataDirectory = dataDirectory
        self.http = http
        self.logStore = logStore
        self.now = now
        self.pollInterval = pollInterval
    }

    /// A camera's own folder: its aim and its detector's state.
    static func directory(of cameraID: UUID, in dataDirectory: URL) -> URL {
        dataDirectory.appending(path: "sky", directoryHint: .isDirectory).appending(path: cameraID.uuidString, directoryHint: .isDirectory)
    }

    /// Runs a detector for each of `cameras` (a new one starts; one already running takes the new context; one not in it stops) and polls the
    /// feed of `settings` while any runs. Returns the detectors running, by camera.
    @discardableResult
    func update(settings: SkySettings, cameras: [UUID: SkyCameraDetector.Context]) async -> [UUID: SkyCameraDetector] {
        await changes.withLock {
            let leaving = detectors.filter { cameras[$0.key] == nil }
            for id in leaving.keys { detectors[id] = nil }
            await Self.stop(Array(leaving.values))
            for id in cameras.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let context = cameras[id] else { continue }
                if let detector = detectors[id] {
                    await detector.update(context: context)
                } else {
                    let detector = SkyCameraDetector(context: context, directory: Self.directory(of: id, in: dataDirectory), flights: flights,
                                                     log: logStore, now: now)
                    detectors[id] = detector
                    await detector.start()
                }
            }
            let feed = settings.flightFeedURL.flatMap { SkySettings.isValidFeed($0) ? URL(string: $0) : nil }
            await poll(detectors.isEmpty ? nil : feed)
            return detectors
        }
    }

    /// The detector of a camera, while it runs.
    func detector(_ cameraID: UUID) -> SkyCameraDetector? {
        detectors[cameraID]
    }

    /// What is wrong with the flight feed now ("The flight feed answered 404."); nil while it answers, or while none is asked.
    var feedProblem: String? {
        get async { await poller?.problem }
    }

    /// Whether the feed is being asked (tests).
    var isPolling: Bool { poller != nil }

    /// The camera is gone: its detector stops and its folder (the aim, the state) is deleted.
    func remove(_ cameraID: UUID) async {
        await changes.withLock {
            if let detector = detectors.removeValue(forKey: cameraID) { await detector.stop() }
            if detectors.isEmpty { await poll(nil) }
            let folder = Self.directory(of: cameraID, in: dataDirectory)
            if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
                do {
                    try FileManager.default.removeItem(at: folder)
                } catch {
                    logger.warning("The Sky Watcher's aim of a removed camera could not be deleted: \(URLFreeErrors.describe(error))")
                }
            }
        }
    }

    /// Every detector stops, and the feed is not asked any more (the bridge pauses or stops).
    func stop() async {
        await changes.withLock {
            let running = detectors
            detectors = [:]
            await Self.stop(Array(running.values))
            await poll(nil)
        }
    }

    /// Stops `detectors` together: each takes a second at the most (`SkyCameraDetector.stop`), and the engine holds its locks meanwhile.
    private static func stop(_ detectors: [SkyCameraDetector]) async {
        await withTaskGroup(of: Void.self) { group in
            for detector in detectors { group.addTask { await detector.stop() } }
        }
    }

    /// Polls `url` (nil: nothing): a new address stops the old poller first.
    private func poll(_ url: URL?) async {
        guard url != polled || (url != nil) != (poller != nil) else { return }
        if let running = poller {
            poller = nil
            await running.stop()
        }
        polled = url
        guard let url else { return }
        let next = FlightFeedPoller(url: url, http: http, history: flights, interval: pollInterval, now: now)
        poller = next
        await next.start()
        logger.info("Sky Watcher asks the flight feed for the aircraft around")
    }
}
