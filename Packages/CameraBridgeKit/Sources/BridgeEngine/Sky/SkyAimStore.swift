import BridgeSupport
import Foundation
import Synchronization

/// A sky camera's aim and the matches it is fitted to, kept in the data directory, in the camera's own folder `<data>/sky/<camera-uuid>/`
/// (`directory`): `aim.json` (the accepted fit and the store's own counts) and `matches.jsonl` (one match a line), each mode 0600 in folders
/// of 0700. **They stay on the box**: the matches' sky directions with their times tell where the box is (stars' directions at known times
/// fix its latitude and longitude), so these files are never logged, sent or exported, the diagnostics and any backup included. What the
/// store logs names no direction, time or place.
///
/// - **Matches.** One pass of an aircraft (its samples in one `add`) keeps at most 12 samples, each at least 1° from the others: the samples
///   of an aircraft lie on one great circle, so a long track would otherwise outweigh many aircraft. The latest 2,000 matches of each
///   source (planes, stars) are kept, which then cover many aircraft, and plane matches older than 30 days are dropped.
/// - **Refits.** At most once per 10 new matches, or once an hour when fewer than that arrived (`AimFitter`, from the current aim; the
///   card's model before there is one). `add` hands back a fit that was accepted. One that was not is logged once, until a fit is accepted
///   again.
/// - **A moved camera.** 10 plane matches in a row, each further off the aim than 3 × the RMS of the fit's plane matches and than half its
///   lens's match tolerance (the samples of one aircraft in a row count as one match, by their median), mean that the camera has moved.
///   The aim starts again (`reset(reason:)`): rough, with no matches, and the card says "The camera seems to have moved; aiming again."
///   until the aim is good again. A fit with no plane matches (from stars alone) judges none: a star's residual says nothing of a plane's.
/// - **The card** the aim started from (`Card`: facing, tilt, lenses) is kept with it (Ruling S25b). Opened with another, the store starts the
///   aim again from it (`cardChanged`), as the detector does when the card changes while it runs (Ruling S25): the card was changed while the
///   detector was off. A state saved before the card was kept has none: its fit stays, and the card is kept from then on.
///
/// A fit takes a few seconds at most on the box for a few thousand matches. It runs on a thread of its own, outside Swift's cooperative pool,
/// so the store answers meanwhile (with the aim it had) and no thread of the pool is held; one runs at a time, and one under way when the aim
/// starts again is not taken. A line of `matches.jsonl` that does not parse (a crash mid-write, a later version) is skipped, and the next one
/// starts on a line of its own.
actor SkyAimStore {
    static let aimFileName = "aim.json"
    static let matchesFileName = "matches.jsonl"
    static let version = 1
    static let keptPerSource = 2_000
    static let planeLifetime: TimeInterval = 30 * 86_400
    static let refitMatches = 10
    static let refitInterval: TimeInterval = 3_600
    static let movedMatches = 10
    static let movedFactor = 3.0
    static let movedNote = "The camera seems to have moved; aiming again."
    /// One pass of an aircraft keeps at most this many samples, each at least `planeSpacing` degrees from the others kept.
    static let planeSamplesPerPass = 12
    static let planeSpacing = 1.0

    /// The card an aim starts from, as the person set it: which way the camera faces (degrees from true north), how far it is tilted up, and
    /// its lenses (nil: by the picture's shape).
    struct Card: Codable, Sendable, Equatable {
        var facing: Double
        var tilt: Double
        var lensLayout: SkyLensLayout?
    }

    /// What `aim.json` holds.
    private struct State: Codable {
        var v = SkyAimStore.version
        var fit: AimFit?
        /// When `fit` was made.
        var fitted: Date?
        /// When a refit was last tried.
        var attempted: Date?
        /// New matches since then.
        var pending = 0
        /// Plane matches in a row that were further off the aim than a moved camera's threshold.
        var run = 0
        var note: String?
        /// The card the aim started from (Ruling S25b); nil in a state saved before it was kept.
        var card: Card?
    }

    private let directory: URL
    private let log: Log
    private let now: @Sendable () -> Date
    private var seeded: SkyRandom?
    private var start: SkyCameraModel
    private var pictureWidth: Int
    private var pictureHeight: Int
    private var state: State
    private var matches: [AimCorrespondence]
    private var rejectionLogged = false
    private var saveFailureLogged = false
    /// Set by `close()`, from outside the actor: a fit that is running (a few seconds) must not hold it up.
    private nonisolated let closedFlag = Mutex(false)
    /// One more each time the aim starts again or its start changes lenses: a fit under way then is of what was dropped, and is not taken.
    private var generation = 0
    /// The generation whose refit is under way, if one is.
    private var fitting: Int?

    /// Whether the store was opened with another card than the aim's (it was changed while the detector was off): the aim has started again
    /// from it, with no fit, no matches and no note (Ruling S25b). The caller tells the journal.
    nonisolated let cardChanged: Bool

    /// The store of `directory`, with what it holds there. `start` is the card's model (facing and tilt, the picture's size and layout), and
    /// `card` the card it is made from (nil: not known, and nothing kept of it); `pictureWidth` and `pictureHeight` are the original
    /// picture's, in pixels. `seed` makes the fits repeatable (tests); without it they draw from `SystemRandomNumberGenerator`.
    init(directory: URL, log: Log, start: SkyCameraModel, card: Card? = nil, pictureWidth: Int, pictureHeight: Int,
         now: @escaping @Sendable () -> Date = { Date() }, seed: UInt64? = nil) {
        self.directory = directory
        self.log = log
        self.now = now
        seeded = seed.map(SkyRandom.init(seed:))
        self.start = start
        self.pictureWidth = pictureWidth
        self.pictureHeight = pictureHeight
        let aimURL = directory.appending(path: Self.aimFileName, directoryHint: .notDirectory)
        let matchesURL = directory.appending(path: Self.matchesFileName, directoryHint: .notDirectory)
        var state = Self.loadState(from: aimURL, log: log)
        var startedAgain = false, cardIsNew = false
        if let card, state.card != card {
            if state.card != nil {
                // The card was changed while the detector was off (Ruling S25b): the aim starts again from it, as when it is changed while the
                // detector runs (Ruling S25), quietly: no fit, no matches, no note.
                state = State()
                startedAgain = true
            }
            // A state saved before the card was kept has none: its fit stays (nothing says which card it was made from), and this card is kept.
            state.card = card
            cardIsNew = true
        }
        if let fit = state.fit, !Self.fits(fit.model, start) {
            // The card's layout changed while the bridge was off: the fit's lenses no longer apply (the matches still do).
            state.fit = nil
            state.fitted = nil
            state.pending = max(state.pending, Self.refitMatches)
        }
        self.state = state
        cardChanged = startedAgain
        let loaded = startedAgain ? [] : Self.loadMatches(from: matchesURL)
        let kept = Self.trimmed(loaded, now: now())
        matches = kept
        if startedAgain || kept.count != loaded.count, (try? Self.write(kept, to: matchesURL, directory: directory)) == nil {
            log.warning("The sky aim's matches (\(Self.matchesFileName)) could not be saved")
        }
        if cardIsNew, (try? Self.write(state, to: aimURL, directory: directory)) == nil {
            log.warning("The sky aim (\(Self.aimFileName)) could not be saved; it is kept in memory and saved again with the next change")
        }
    }

    /// The store's detector has stopped (and its folder may be deleted with the camera, or a new detector may be reading it): nothing is written
    /// again, wherever a fit or a match that was under way ends up. The store goes on in memory. Quick, and not on the actor, so that stopping the
    /// detector never waits for a fit.
    nonisolated func close() {
        closedFlag.withLock { $0 = true }
    }

    private var isClosed: Bool { closedFlag.withLock { $0 } }

    // MARK: Reading

    /// The accepted fit; nil before there is one (or after the aim started again).
    func current() -> AimFit? {
        state.fit
    }

    /// The model to match with: the fit's, or the card's before there is one.
    func model() -> SkyCameraModel {
        state.fit?.model ?? start
    }

    /// What the card shows.
    func status() -> SkyAimStatus {
        state.fit?.status(updated: state.fitted, note: state.note) ?? .unaimed(note: state.note)
    }

    /// The matches kept.
    func correspondences() -> [AimCorrespondence] {
        matches
    }

    /// When a refit was last tried.
    func lastAttempt() -> Date? {
        state.attempted
    }

    /// Whether a refit is under way (on its own thread).
    func isFitting() -> Bool {
        fitting != nil
    }

    // MARK: Changing

    /// Adds new matches (those that cannot be used are left out, and each aircraft's samples are thinned: `thinned`) and refits when it is
    /// due. `new` is one pass: a flight match's samples, say, or a star pass. Returns the new fit when one was accepted.
    func add(_ new: [AimCorrespondence]) async -> AimFit? {
        let usable = Self.thinned(new.filter(AimFitter.usable))
        guard !usable.isEmpty else { return nil }
        if cameraMoved(usable) {
            reset(reason: Self.movedNote)
            return nil
        }
        let all = matches + usable
        matches = Self.trimmed(all, now: now())
        if matches.count == all.count { append(usable) } else { saveMatches() }
        state.pending += usable.count
        defer { saveState() }
        let time = now()
        let due = state.pending >= Self.refitMatches
            || state.attempted.map { time.timeIntervalSince($0) >= Self.refitInterval || $0 > time } ?? true
        return due ? await refit() : nil
    }

    /// Starts aiming again: the fit and the matches are dropped, the quality is rough, and `reason` is what the card says
    /// (`status().note`) until the aim is good again; nil says nothing (the person moved the card themselves: it is a camera just added).
    /// `quietly`: the caller has told the journal itself, in words that name the camera. The card stays the aim's.
    func reset(reason: String?, quietly: Bool = false) {
        if !quietly { log.notice(reason.map { "The sky aim starts again: \($0)" } ?? "The sky aim starts again") }
        generation += 1
        state = State(note: reason, card: state.card)
        matches = []
        rejectionLogged = false
        saveMatches()
        saveState()
    }

    /// A new card model (its facing and tilt, the picture's size and layout) and the original picture's size. A new layout (one lens or
    /// two) drops the fit, whose lenses no longer apply, and fits the matches again from the new start; otherwise the fit stays, since once
    /// there is one the matches, not the card, say where the camera looks. `card`: the card the aim starts from now, kept with it (Ruling
    /// S25b; nil keeps the one it has).
    func setStart(_ model: SkyCameraModel, pictureWidth: Int, pictureHeight: Int, card: Card? = nil) async {
        self.pictureWidth = pictureWidth
        self.pictureHeight = pictureHeight
        let changed = !Self.fits(model, start)
        start = model
        if let card, card != state.card {
            state.card = card
            saveState()
        }
        guard changed, state.fit != nil || !matches.isEmpty else { return }
        generation += 1   // a fit under way is of the old lenses
        state.fit = nil
        state.fitted = nil
        _ = await refit()
        saveState()
    }

    // MARK: Fitting

    /// Fits the matches from the current aim and keeps the fit when it is accepted. The fit runs on a thread of its own (`onItsOwnThread`), so
    /// the store answers meanwhile; one at a time (matches that come while one is under way wait for the next), and when the aim starts again
    /// meanwhile, the fit of what it dropped is not taken.
    private func refit() async -> AimFit? {
        guard fitting != generation else { return nil }
        let mine = generation
        fitting = mine
        defer { if fitting == mine { fitting = nil } }
        state.pending = 0
        state.attempted = now()
        let matches = matches, starting = state.fit?.model ?? start, previous = state.fit, seeded = seeded
        let width = pictureWidth, height = pictureHeight
        let (attempt, generator) = await Self.onItsOwnThread { () -> (AimFitter.Attempt, SkyRandom?) in
            if var generator = seeded {
                let attempt = AimFitter.attempt(matches, starting: starting, pictureWidth: width, pictureHeight: height, previous: previous,
                                                using: &generator)
                return (attempt, generator)
            }
            var generator = SystemRandomNumberGenerator()
            return (AimFitter.attempt(matches, starting: starting, pictureWidth: width, pictureHeight: height, previous: previous, using: &generator),
                    nil)
        }
        guard mine == generation else { return nil }   // the aim started again meanwhile: this is the fit of what it dropped
        if let generator { self.seeded = generator }
        guard attempt.accepted else {
            if !rejectionLogged && !attempt.notes.isEmpty {
                log.info("The sky aim was not refined (\(attempt.notes.joined(separator: "; "))); the aim it had is kept")
                rejectionLogged = true
            }
            return nil
        }
        rejectionLogged = false
        let earlier = state.fit?.quality
        let fit = attempt.fit
        state.fit = fit
        state.fitted = now()
        if fit.quality != .rough { state.note = nil }
        let summary = "\(fit.quality.rawValue), stage \(fit.stage), \(String(format: "%.1f", fit.residualPixels)) px, "
            + "\(fit.planes) planes and \(fit.stars) stars matched"
        if earlier != fit.quality { log.info("The sky aim is \(summary)") } else { log.debug("The sky aim is \(summary)") }
        if !attempt.notes.isEmpty { log.debug("Part of the sky aim was kept: \(attempt.notes.joined(separator: "; "))") }
        return fit
    }

    /// Whether `new` completes a run of `movedMatches` plane matches in a row that are each further off the aim than `movedFactor` × the
    /// fit's plane RMS and than half the match tolerance of the sample's lens: the samples of one aircraft in a row count as one match, by
    /// their median (as parts of their thresholds). Matches in a lens that is not fitted count neither way, and a fit with no plane matches
    /// judges none. The run is counted as it goes, and kept across restarts.
    private func cameraMoved(_ new: [AimCorrespondence]) -> Bool {
        guard let fit = state.fit, let planeResidual = fit.planeResidualDegrees, fit.lenses.contains(where: { $0.stage > 0 }) else {
            state.run = 0   // nothing to judge against: an old count must not carry over to the next fit with planes
            return false
        }
        let planes = new.filter { $0.source == .plane }
        var first = 0
        while first < planes.count {
            var end = first + 1
            while end < planes.count && planes[end].object == planes[first].object { end += 1 }
            let parts = planes[first..<end].compactMap { match -> Double? in
                let lens = fit.model.lens(at: match.point)
                guard lens < fit.lenses.count, fit.lenses[lens].stage > 0 else { return nil }
                let threshold = max(Self.movedFactor * planeResidual, AimFitter.matchTolerance(fit.lenses[lens].quality) / 2)
                return fit.model.direction(at: match.point, lens: lens).map { SkyMath.separation($0, match.direction) / threshold } ?? .infinity
            }.sorted()
            first = end
            guard !parts.isEmpty else { continue }
            state.run = parts[parts.count / 2] > 1 ? state.run + 1 : 0
            if state.run >= Self.movedMatches { return true }
        }
        return false
    }

    /// `matches` (one pass) with each aircraft's samples thinned: in the order given, a sample is kept when it is at least `planeSpacing`
    /// degrees from every sample kept of that aircraft; of more than `planeSamplesPerPass` so kept, that many, spread evenly along them (the
    /// first and the last included). Star matches are all kept. The order stays.
    static func thinned(_ matches: [AimCorrespondence]) -> [AimCorrespondence] {
        var kept: [String: [Int]] = [:]
        var stars: [Int] = []
        for (index, match) in matches.enumerated() {
            guard match.source == .plane else {
                stars.append(index)
                continue
            }
            let others = kept[match.object] ?? []
            if others.allSatisfy({ SkyMath.separation(matches[$0].direction, match.direction) >= planeSpacing }) {
                kept[match.object] = others + [index]
            }
        }
        var keep = Set(stars)
        for samples in kept.values {
            guard samples.count > planeSamplesPerPass else {
                keep.formUnion(samples)
                continue
            }
            let last = Double(samples.count - 1), steps = Double(planeSamplesPerPass - 1)
            for step in 0..<planeSamplesPerPass { keep.insert(samples[Int((Double(step) * last / steps).rounded())]) }
        }
        return matches.indices.filter(keep.contains).map { matches[$0] }
    }

    /// Whether a fit of `model`'s lenses applies to `start`'s: the same layout and lenses.
    private static func fits(_ model: SkyCameraModel, _ start: SkyCameraModel) -> Bool {
        model.layout == start.layout && model.lensCount == start.lensCount && model.lenses.count == start.lenses.count
    }

    /// `matches` without plane matches older than `planeLifetime` and with only the latest `keptPerSource` of each source (by their time;
    /// of two at the same time, the one added later), in their order.
    static func trimmed(_ matches: [AimCorrespondence], now: Date) -> [AimCorrespondence] {
        let oldest = now.addingTimeInterval(-planeLifetime)
        var keep = matches.indices.filter { matches[$0].source != .plane || matches[$0].at >= oldest }
        for source in [AimCorrespondence.Source.plane, .star] {
            let own = keep.filter { matches[$0].source == source }
            guard own.count > keptPerSource else { continue }
            let latest = Set(own.sorted { (matches[$0].at, $0) > (matches[$1].at, $1) }.prefix(keptPerSource))
            keep = keep.filter { matches[$0].source != source || latest.contains($0) }
        }
        return keep.map { matches[$0] }
    }

    // MARK: The files

    private var aimURL: URL {
        directory.appending(path: Self.aimFileName, directoryHint: .notDirectory)
    }

    private var matchesURL: URL {
        directory.appending(path: Self.matchesFileName, directoryHint: .notDirectory)
    }

    /// Keys sorted and slashes plain (a stable file); times in milliseconds.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    /// The state in `url`; a fresh one when there is no file, or (logged by the file's name) when it cannot be read.
    private static func loadState(from url: URL, log: Log) -> State {
        guard PrivateFiles.exists(url) else { return State() }
        do {
            return try makeDecoder().decode(State.self, from: Data(contentsOf: url))
        } catch {
            log.warning("The sky aim (\(aimFileName)) could not be read; it is fitted again from its matches")
            return State(pending: refitMatches)
        }
    }

    /// The matches in `url`, a line each; lines that do not parse are skipped.
    private static func loadMatches(from url: URL) -> [AimCorrespondence] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = makeDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(AimCorrespondence.self, from: Data($0)) }
    }

    /// `matches` as lines.
    private static func lines(_ matches: [AimCorrespondence]) throws -> Data {
        let encoder = makeEncoder()
        var data = Data()
        for match in matches {
            data.append(try encoder.encode(match))
            data.append(0x0A)
        }
        return data
    }

    /// Replaces `url` with `matches` (atomically).
    private static func write(_ matches: [AimCorrespondence], to url: URL, directory: URL) throws {
        try PrivateFiles.prepareDirectory(directory)
        try PrivateFiles.write(try lines(matches), to: url)
    }

    /// Replaces `url` with `state` (atomically).
    private static func write(_ state: State, to url: URL, directory: URL) throws {
        try PrivateFiles.prepareDirectory(directory)
        try PrivateFiles.write(try makeEncoder().encode(state), to: url)
    }

    private func saveState() {
        guard !isClosed else { return }
        do {
            try Self.write(state, to: aimURL, directory: directory)
            saveFailureLogged = false
        } catch {
            saveFailed(Self.aimFileName)
        }
    }

    /// Runs `work` on a thread of its own, at a low priority, and waits for it without holding a thread of Swift's cooperative pool: a fit of
    /// a few thousand matches takes seconds on the box, and would otherwise hold one of the pool's few threads (one a core) all that time.
    private static func onItsOwnThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: work()) }
            thread.name = "Sky aim fit"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    private func saveMatches() {
        guard !isClosed else { return }
        do {
            try Self.write(matches, to: matchesURL, directory: directory)
        } catch {
            saveFailed(Self.matchesFileName)
        }
    }

    /// Appends `new` to the matches file, on a line of its own after a torn last line.
    private func append(_ new: [AimCorrespondence]) {
        guard !isClosed else { return }
        do {
            var data = try Self.lines(new)
            guard PrivateFiles.exists(matchesURL) else { return saveMatches() }
            let handle = try FileHandle(forUpdating: matchesURL)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data([0x0A]) { data.insert(0x0A, at: data.startIndex) }
                _ = try handle.seekToEnd()
            }
            try handle.write(contentsOf: data)
        } catch {
            saveFailed(Self.matchesFileName)
        }
    }

    /// Logs a file that could not be written, once until a save succeeds.
    private func saveFailed(_ name: String) {
        guard !saveFailureLogged else { return }
        saveFailureLogged = true
        log.warning("The sky aim (\(name)) could not be saved; it is kept in memory and saved again with the next change")
    }
}
