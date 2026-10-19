import BridgeSupport
import Foundation
import Synchronization

/// Where the describer gets an event's pictures: `CameraRuntime` (`gatherEventFrames(at:)` when the event starts, `eventPictures(from:)` when its
/// turn in the queue comes); tests stand in for it.
protocol EventFrameSource: Sendable {
    func gatherEventFrames(at date: Date) async -> EventFrames
    func eventPictures(from frames: EventFrames) async -> [LabeledPicture]
}

extension CameraRuntime: EventFrameSource {}

/// What the Settings card shows of the AI descriptions: the day's count and the week's (the bridge's time zone), whether today's limit is
/// reached, whether describing is paused after a refused key, the last failure in plain words and when it was, and whether descriptions wait for
/// a recordings folder (without one no event is kept, so none is described).
public struct AIStatus: Sendable, Equatable {
    public var today: Int
    /// Today and the six days before it.
    public var last7Days: Int
    public var limitReached: Bool
    /// The service refused the key: nothing is described until the key or the service changes, or Try it works again.
    public var paused: Bool
    /// `AIProviderError.sentence` of the last failure of the service and key in use; nil when there was none since they last changed.
    public var lastError: String?
    public var lastErrorAt: Date?
    public var needsRecordingsFolder: Bool

    public init(today: Int = 0, last7Days: Int = 0, limitReached: Bool = false, paused: Bool = false, lastError: String? = nil,
                lastErrorAt: Date? = nil, needsRecordingsFolder: Bool = false) {
        self.today = today
        self.last7Days = last7Days
        self.limitReached = limitReached
        self.paused = paused
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
        self.needsRecordingsFolder = needsRecordingsFolder
    }
}

/// Why Try it could not ask the service (the service's own failures are `AIProviderError`). `sentence` is the plain words for the person.
public enum AIDescriberError: Error, Equatable, Sendable {
    /// No service is chosen, or Claude has no key.
    case noService
    /// Today's limit (the number) is reached.
    case limitReached(Int)
    /// The camera does not run (turned off, or the bridge is paused).
    case cameraNotRunning
    /// Not one picture could be had from the camera.
    case noPictures
    /// Another Try it is under way (one at a time).
    case alreadyTrying

    public var sentence: String {
        switch self {
        case .noService: "Choose an AI service and save its key first."
        case .limitReached(let limit): "Today’s limit of \(limit) descriptions is reached."
        case .cameraNotRunning: "The camera isn’t running."
        case .noPictures: "No picture could be had from the camera."
        case .alreadyTrying: "A try is already running."
        }
    }
}

/// Describes camera events with the AI service the person chose, and keeps each description with its event (docs/superpowers/specs/
/// 2026-10-18-ai-event-descriptions-design.md, "How it works").
///
/// - **Which events.** `eventsStarted` gets the events the event log began (none while no recordings folder is chosen) from the engine's edge
///   handler and returns at once. An event is described when a service is set (`setService`), describing is not paused, today's limit is not
///   reached, its camera runs with its switch on, and its camera had no event described in the last `Timing.perCamera` (60 s). Of the events
///   of one camera that start together, only the most specific is (`kindOrder`); other kinds (tamper, sound, alarm inputs) never are. A skipped
///   event costs nothing: no picture is gathered. A more specific kind that starts on the camera within `Timing.upgradeWithin` (2 s) of the
///   admitted event, while that one's frames are still gathered or it still waits, takes its place: the frames are its, and the description
///   goes to its row (the camera's minute is still counted from the first).
/// - **The queue.** An event's frames are gathered as soon as it is admitted, for every camera at once (`EventFrameSource.gatherEventFrames`,
///   encoded data only), then it waits in a queue of width one: one event at a time has its pictures made and is sent. An event that waited
///   more than `Timing.staleAfter` (60 s) is dropped without its pictures being made; with one event per camera per minute, the queue never
///   holds more than one event per camera. When an event's turn comes, its camera is looked up again: one turned off or removed meanwhile
///   has nothing made or sent.
/// - **The request.** The camera's name, the kind the camera reported, the local time of the event in the bridge's time zone and the pictures.
///   A network error or a 5xx is tried once more after `Timing.retryDelay`, unless the event is stale by then; any other failure is not. The
///   description is handed to `record` (the event log), the failure is kept as `AIStatus.lastError`. A refused key (401) pauses describing
///   until the AI settings or the key change (`setService` with `fresh`) or Try it works again: one error, not one per event.
/// - **Looked at again before every send.** The pictures take a moment, and a failing call takes longer. Right before the first send and
///   again right before the retry, the camera's switch is read once more and the service must be the one the event's turn began with (a new
///   `serviceGeneration` means the owner changed the settings, the service or the key, or chose Off): if either changed, nothing is sent. An
///   event dropped before its first send is not counted; one dropped before its retry was counted for its first send only.
/// - **The count.** Each event sent counts once toward the day, retry or not; skipped and dropped events never do. Days are the bridge's
///   (`timeZone`) and the counts are kept in `usageFile` (`AIUsage`), so the limit holds across a restart.
/// - **Try it** (`tryNow`) describes the pictures around now of any running camera, its switch on or off (the person asked for it), counts
///   toward the day, and stores nothing; one at a time.
/// - **The last error** is only ever about the service and key in use: a late failure of one replaced since is not kept.
///
/// The key never reaches this type's logs or errors: it is inside the service (`AISecret`), and failures are `AIProviderError` sentences.
actor EventDescriber {
    /// A running camera, as the describer needs it.
    struct Camera: Sendable {
        var name: String
        /// The camera's switch (`CameraConfiguration.aiDescriptions`).
        var describes: Bool
        var frames: any EventFrameSource
    }

    struct Timing: Sendable, Equatable {
        /// At most one description per camera this often.
        var perCamera: TimeInterval = 60
        /// An event that waited longer than this is not described.
        var staleAfter: TimeInterval = 60
        /// Before the one retry of a network error or a 5xx.
        var retryDelay: Duration = .seconds(2)
        /// A more specific kind that starts this soon after an admitted event of its camera takes its place, while that one has not had its
        /// turn yet.
        var upgradeWithin: TimeInterval = 2
    }

    /// The running cameras among `ids`; one that does not run is left out.
    typealias Cameras = @Sendable (_ ids: Set<UUID>) async -> [UUID: Camera]
    /// Keeps a description with its event (`NVRCoordinator.recordDescription`).
    typealias Record = @Sendable (_ description: EventDescription, _ event: StartedEvent) -> Void

    /// The kinds that are described, the most specific first: of several that start together on one camera, the first in this list is.
    static let kindOrder = ["Person", "Package", "Vehicle", "Animal", "Face", "Doorbell ring", "Motion"]
    /// What Try it says the camera reported: nothing, it is a test.
    static let tryKind = "None (a test)"

    private struct Job: Sendable {
        /// The number its gather had.
        var number: Int
        var event: StartedEvent
        var camera: Camera
        var frames: EventFrames
    }

    /// What `eventsStarted` (nonisolated, on the event router's actor) and the setters read and change without waiting for the actor.
    private struct Gate {
        var service: (any AIVisionDescribing)?
        /// Bumped by every change of the AI settings, the service or its key (`setService` with `fresh`): a failure of what was in use before
        /// is not kept, and its refusal does not pause the new one. An event is not sent under another generation than its turn began with.
        var serviceGeneration = 0
        var dailyLimit = AIDescriptionSettings().dailyLimit
        /// A refused key: nothing is described until the service or its key changes.
        var paused = false
        var usage = AIUsage()
        var lastError: (error: AIProviderError, at: Date)?
        /// Where `eventsStarted` hands events over; nil while stopped.
        var admissions: AsyncStream<[StartedEvent]>.Continuation?
        /// Handed over and not taken in yet.
        var admissionsWaiting = 0
    }

    private nonisolated let gate = Mutex(Gate())
    private let usageFile: URL
    private let cameras: Cameras
    private let record: Record
    private nonisolated let now: @Sendable () -> Date
    private nonisolated let timeZone: @Sendable () -> TimeZone
    private let timing: Timing
    private let log: Log

    private var loaded = false
    private var running = false
    private var admitting: Task<Void, Never>?
    private var working: Task<Void, Never>?
    private var wake: AsyncStream<Void>.Continuation?
    /// Events whose frames are being gathered, by a number of their own.
    private var gathering: [Int: Task<Void, Never>] = [:]
    private var nextGather = 0
    private var queue: [Job] = []
    private var describing = false
    /// When each camera's last admitted event began.
    private var lastAdmitted: [UUID: Date] = [:]
    /// The admitted event of each camera that has not had its turn yet (its frames are gathered, or it waits), by its gather's number: a more
    /// specific kind that starts soon after takes its place.
    private var awaiting: [UUID: (number: Int, event: StartedEvent)] = [:]
    /// A Try it is under way.
    private var trying = false
    private var saveFailed = false

    /// `usageFile`: `<data>/ai/usage.json`. `now` is the bridge's clock (as the event router stamps events) and `timeZone` the bridge's zone.
    init(usageFile: URL, cameras: @escaping Cameras, record: @escaping Record, now: @escaping @Sendable () -> Date = Date.init,
         timeZone: @escaping @Sendable () -> TimeZone = { BridgeTime.zone }, timing: Timing = Timing(), log: Log = Log(category: "AI")) {
        self.usageFile = usageFile
        self.cameras = cameras
        self.record = record
        self.now = now
        self.timeZone = timeZone
        self.timing = timing
        self.log = log
    }

    // MARK: Start and stop

    /// Reads the day's count (once) and takes events from now on.
    func start() {
        loadUsage()
        guard !running else { return }
        running = true
        let (admissions, admissionsIn) = AsyncStream.makeStream(of: [StartedEvent].self)
        let (wakes, wakeIn) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wake = wakeIn
        gate.withLock { $0.admissions = admissionsIn }
        admitting = Task { await self.admit(admissions) }
        working = Task { await self.work(wakes) }
    }

    /// Takes no more events, ends what is gathered or sent (a call in flight is cancelled) and forgets what waits. Returns once it has ended.
    func stop() async {
        gate.withLock { gate in
            gate.admissions?.finish()
            gate.admissions = nil
            gate.admissionsWaiting = 0
        }
        guard running else { return }
        running = false
        wake?.finish()
        wake = nil
        let tasks = [admitting, working].compactMap { $0 } + Array(gathering.values)
        admitting = nil
        working = nil
        gathering = [:]
        queue = []
        awaiting = [:]
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    // MARK: The service

    /// The service that describes, and the day's limit; nil: no service is chosen (or Claude has no key), nothing is described. `fresh`: the AI
    /// settings (a new model or limit too), the service or its key changed, so a pause after a refused key may end, the last error, which was
    /// about what was in use before, is forgotten, and nothing already under way is sent to what replaced it. The engine says `fresh` for every
    /// change; only its first start, which changes nothing, says not. (Whether a saved key goes with a change of service is the engine's own
    /// rule, `AIDescriptionSettings.keepsKey(from:)`, apart from this.)
    nonisolated func setService(_ service: (any AIVisionDescribing)?, dailyLimit: Int, fresh: Bool) {
        gate.withLock { gate in
            gate.service = service
            gate.dailyLimit = dailyLimit
            if fresh {
                gate.serviceGeneration &+= 1
                gate.paused = false
                gate.lastError = nil
            }
        }
    }

    /// The service describing now (the engine's tests).
    nonisolated var service: (any AIVisionDescribing)? {
        gate.withLock { $0.service }
    }

    /// Which settings, service and key the describer is on: it changes with every `fresh` `setService` (the engine's tests).
    nonisolated var serviceGeneration: Int {
        gate.withLock { $0.serviceGeneration }
    }

    // MARK: Events

    /// The events the event log began (`NVRCoordinator.recordEvents`), from the engine's edge handler: returns at once. Nothing is done for
    /// them while no service is set, describing is paused, or today's limit is reached.
    nonisolated func eventsStarted(_ events: [StartedEvent]) {
        let describable = events.filter { Self.kindOrder.contains($0.kind) }
        guard !describable.isEmpty else { return }
        let now = now(), zone = timeZone()
        gate.withLock { gate in
            guard Self.mayDescribe(gate, at: now, in: zone), let admissions = gate.admissions else { return }
            gate.admissionsWaiting += 1
            admissions.yield(describable)
        }
    }

    /// Of the events that start together on one camera (the same camera and date), the one whose kind comes first in `kindOrder`, in the order
    /// the groups first appear. Kinds not in it are left out.
    static func mostSpecific(_ events: [StartedEvent]) -> [StartedEvent] {
        struct Together: Hashable {
            var camera: UUID
            var date: Date
        }
        var order: [Together] = []
        var best: [Together: (event: StartedEvent, rank: Int)] = [:]
        for event in events {
            guard let rank = kindOrder.firstIndex(of: event.kind) else { continue }
            let key = Together(camera: event.cameraID, date: event.date)
            if let current = best[key] {
                if rank < current.rank { best[key] = (event, rank) }
            } else {
                order.append(key)
                best[key] = (event, rank)
            }
        }
        return order.compactMap { best[$0]?.event }
    }

    /// Takes the events in the order they started: chooses which are described and starts gathering their frames.
    private func admit(_ admissions: AsyncStream<[StartedEvent]>) async {
        for await events in admissions {
            defer { gate.withLock { $0.admissionsWaiting = max(0, $0.admissionsWaiting - 1) } }
            let chosen = Self.mostSpecific(events)
            let running = await cameras(Set(chosen.map(\.cameraID)))
            for event in chosen {
                guard self.running, let camera = running[event.cameraID], camera.describes,
                      gate.withLock({ Self.mayDescribe($0, at: now(), in: timeZone()) }) else { continue }
                if let last = lastAdmitted[event.cameraID], abs(event.date.timeIntervalSince(last)) < timing.perCamera {
                    takeThePlaceOfTheWaitingEvent(event)
                    continue
                }
                lastAdmitted[event.cameraID] = event.date
                let number = nextGather
                nextGather += 1
                awaiting[event.cameraID] = (number, event)
                gathering[number] = Task {
                    let frames = await camera.frames.gatherEventFrames(at: event.date)
                    self.enqueue(Job(number: number, event: event, camera: camera, frames: frames))
                }
            }
        }
    }

    /// `event` takes the place of its camera's admitted event that has not had its turn yet, when it is of a more specific kind and started
    /// within `Timing.upgradeWithin` after the event that was admitted ("Motion", then "Person" a second later): the frames gathered for that
    /// one are its. The time is counted from the admitted event, so places are not taken one after another for longer.
    private func takeThePlaceOfTheWaitingEvent(_ event: StartedEvent) {
        guard let waiting = awaiting[event.cameraID], let admitted = lastAdmitted[event.cameraID],
              let rank = Self.kindOrder.firstIndex(of: event.kind), let waitingRank = Self.kindOrder.firstIndex(of: waiting.event.kind),
              rank < waitingRank else { return }
        let after = event.date.timeIntervalSince(admitted)
        guard after >= 0, after <= timing.upgradeWithin else { return }
        awaiting[event.cameraID] = (waiting.number, event)
        if let index = queue.firstIndex(where: { $0.number == waiting.number }) { queue[index].event = event }
    }

    private func enqueue(_ job: Job) {
        guard gathering.removeValue(forKey: job.number) != nil, running else { return }
        var job = job
        if let waiting = awaiting[job.event.cameraID], waiting.number == job.number { job.event = waiting.event }
        dropStale(at: now())
        queue.append(job)
        wake?.yield()
    }

    /// Forgets the events that waited too long (before their pictures are made).
    private func dropStale(at now: Date) {
        let stale = queue.filter { now.timeIntervalSince($0.event.date) > timing.staleAfter }
        guard !stale.isEmpty else { return }
        queue.removeAll { now.timeIntervalSince($0.event.date) > timing.staleAfter }
        for job in stale { leftAwaiting(job) }
        log.debug("\(stale.count) camera event(s) waited more than \(Int(timing.staleAfter)) s for the AI service and are not described")
    }

    /// `job` had its turn (or was dropped): no later event takes its place.
    private func leftAwaiting(_ job: Job) {
        if awaiting[job.event.cameraID]?.number == job.number { awaiting[job.event.cameraID] = nil }
    }

    private func work(_ wakes: AsyncStream<Void>) async {
        for await _ in wakes {
            while running, !Task.isCancelled {
                dropStale(at: now())
                guard !queue.isEmpty else { break }
                let job = queue.removeFirst()
                leftAwaiting(job)
                describing = true
                await describe(job)
                describing = false
            }
        }
    }

    private func describe(_ job: Job) async {
        let began = gate.withLock { gate in Self.mayDescribe(gate, at: now(), in: timeZone()) ? gate.serviceGeneration : nil }
        guard let generation = began else { return }
        // The switch may have been turned off, or the camera removed, while the event waited: then nothing is made or sent.
        guard let camera = await cameras([job.event.cameraID])[job.event.cameraID], camera.describes, !Task.isCancelled else {
            log.debug("An event of \(job.camera.name) is not described: its AI descriptions were turned off while it waited")
            return
        }
        let pictures = await job.camera.frames.eventPictures(from: job.frames)
        guard !Task.isCancelled else { return }
        guard !pictures.isEmpty else {
            log.info("No picture could be had of the \(job.event.kind) event of \(camera.name); it is not described")
            return
        }
        let request = DescriptionRequest(cameraName: camera.name, eventKind: job.event.kind,
                                         localTime: Self.localTime(job.event.date, in: timeZone()), pictures: pictures)
        do {
            let description = try await ask(request, eventDate: job.event.date, ignoringPause: false,
                                            sending: Sending(cameraID: job.event.cameraID, generation: generation))
            record(description, job.event)
        } catch let withdrawn as Withdrawn {
            log.debug("An event of \(camera.name) is not described: \(withdrawn.reason)")
        } catch {
            // Failures are kept and logged by `ask`; a skipped or cancelled event leaves nothing.
        }
    }

    // MARK: Asking the service

    /// Whether events may be described now: a service, no pause, and today's limit not reached.
    private static func mayDescribe(_ gate: Gate, at now: Date, in zone: TimeZone) -> Bool {
        gate.service != nil && !gate.paused && gate.usage.count(on: now, in: zone) < gate.dailyLimit
    }

    /// What an event's send depends on: its camera's switch, and the generation of the settings, service and key its turn began with.
    private struct Sending: Sendable {
        var cameraID: UUID
        var generation: Int
    }

    /// An event was dropped before it was sent: its camera's switch went off, or the service changed. Not a failure of the service.
    private struct Withdrawn: Error {
        var reason: String
    }

    /// Whether the camera `id` still runs with its switch on (read from the engine, which takes a hop).
    private func cameraStillDescribes(_ id: UUID) async -> Bool {
        guard !Task.isCancelled, let camera = await cameras([id])[id] else { return false }
        return camera.describes
    }

    /// Sends `request` to the service (counted once toward the day), and once more after a network error or a 5xx unless the event of
    /// `eventDate` is stale by then. A failure is kept as the last error (a refused key pauses describing) and thrown.
    ///
    /// `sending` is an event's: right before the first send, and again right before the retry, its camera's switch is read once more and the
    /// service must still be the one its turn began with (`Withdrawn` before the first send, nothing counted; the first failure is thrown
    /// instead of a retry). Try it has none: it was asked for.
    private func ask(_ request: DescriptionRequest, eventDate: Date?, ignoringPause: Bool, sending: Sending? = nil) async throws -> EventDescription {
        if let sending, !(await cameraStillDescribes(sending.cameraID)) {
            throw Withdrawn(reason: "its AI descriptions were turned off before it was sent")
        }
        // Nothing waits between this and the send but the file write: the service is read, checked and counted in one step.
        let at = now(), zone = timeZone()
        let chosen = gate.withLock { gate -> Result<(service: any AIVisionDescribing, generation: Int), any Error> in
            guard let service = gate.service else {
                return .failure(sending == nil ? AIDescriberError.noService : Withdrawn(reason: "the AI service was turned off before it was sent"))
            }
            if let sending, gate.serviceGeneration != sending.generation {
                return .failure(Withdrawn(reason: "the AI settings, service or key changed before it was sent"))
            }
            guard gate.usage.count(on: at, in: zone) < gate.dailyLimit else { return .failure(AIDescriberError.limitReached(gate.dailyLimit)) }
            guard ignoringPause || !gate.paused else { return .failure(AIDescriberError.noService) }
            gate.usage.add(at: at, in: zone)
            return .success((service, gate.serviceGeneration))
        }
        let (service, generation) = try chosen.get()
        saveUsage()
        do {
            do {
                return try await service.describe(request)
            } catch let error as AIProviderError where Self.isTriedAgain(error) {
                guard eventDate.map({ now().timeIntervalSince($0) <= timing.staleAfter }) ?? true else { throw error }
                try await Task.sleep(for: timing.retryDelay)
                // The owner may have turned the camera off, chosen Off, or changed the service or key (the old key is gone from the store
                // already, though this service still holds it) while the first call failed and the retry waited.
                if let sending, !(await cameraStillDescribes(sending.cameraID)) { throw error }
                let stillTheSame = gate.withLock { $0.service != nil && $0.serviceGeneration == generation && (ignoringPause || !$0.paused) }
                guard stillTheSame, !Task.isCancelled else { throw error }
                return try await service.describe(request)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = error as? AIProviderError ?? .badAnswer
            note(failure, of: request.cameraName, generation: generation, trying: eventDate == nil)
            throw failure
        }
    }

    private static func isTriedAgain(_ error: AIProviderError) -> Bool {
        switch error {
        case .unreachable, .serviceFailed: true
        default: false
        }
    }

    /// Keeps `failure` as the last error, unless the service or key it came from was replaced since (`generation`); a refused key pauses
    /// describing. `trying`: it was Try it's.
    private func note(_ failure: AIProviderError, of camera: String, generation: Int, trying: Bool) {
        let at = now()
        let (current, paused) = gate.withLock { gate -> (Bool, Bool) in
            guard gate.serviceGeneration == generation else { return (false, false) }
            gate.lastError = (failure, at)
            guard failure == .keyRefused, !gate.paused else { return (true, false) }
            gate.paused = true
            return (true, true)
        }
        guard current else {
            log.debug("A failure of the AI service or key that was replaced since is not kept: \(failure.sentence)")
            return
        }
        if paused { log.warning("The AI service refused the key; no event is described until the key or the service is changed") }
        if trying {
            log.info("Try it for \(camera) failed: \(failure.sentence)")
        } else if failure != .keyRefused {
            log.info("An event of \(camera) was not described: \(failure.sentence)")
        }
    }

    // MARK: Try it

    /// Describes the pictures around now of the running camera `cameraID` (its switch on or off), and stores nothing. It counts toward the
    /// day. One at a time. Throws `AIDescriberError` (another try under way, no service, the limit, a camera that does not run, no picture) or
    /// the service's `AIProviderError`. A try that works while describing is paused after a refused key ends the pause, and the refusal is no
    /// longer the last error: the key works again.
    func tryNow(cameraID: UUID) async throws -> EventDescription {
        guard !trying else { throw AIDescriberError.alreadyTrying }
        trying = true
        defer { trying = false }
        loadUsage()
        guard let camera = await cameras([cameraID])[cameraID] else { throw AIDescriberError.cameraNotRunning }
        let at = now(), zone = timeZone()
        try gate.withLock { gate in
            guard gate.service != nil else { throw AIDescriberError.noService }
            guard gate.usage.count(on: at, in: zone) < gate.dailyLimit else { throw AIDescriberError.limitReached(gate.dailyLimit) }
        }
        let frames = await camera.frames.gatherEventFrames(at: at)
        let pictures = await camera.frames.eventPictures(from: frames)
        try Task.checkCancellation()
        guard !pictures.isEmpty else { throw AIDescriberError.noPictures }
        let request = DescriptionRequest(cameraName: camera.name, eventKind: Self.tryKind, localTime: Self.localTime(at, in: zone), pictures: pictures)
        let generation = gate.withLock { $0.serviceGeneration }
        let description = try await ask(request, eventDate: nil, ignoringPause: true)
        let resumed = gate.withLock { gate -> Bool in
            guard gate.paused, gate.serviceGeneration == generation else { return false }
            gate.paused = false
            if gate.lastError?.error == .keyRefused { gate.lastError = nil }
            return true
        }
        if resumed { log.notice("The AI service accepts the key again; events are described again") }
        return description
    }

    // MARK: Status and the count

    var status: AIStatus {
        loadUsage()
        let at = now(), zone = timeZone()
        return gate.withLock { gate in
            let today = gate.usage.count(on: at, in: zone)
            return AIStatus(today: today, last7Days: gate.usage.lastSevenDays(at, in: zone), limitReached: today >= gate.dailyLimit,
                            paused: gate.paused, lastError: gate.lastError?.error.sentence, lastErrorAt: gate.lastError?.at)
        }
    }

    /// Nothing is gathered, waits or is described (tests).
    var isIdle: Bool { gate.withLock { $0.admissionsWaiting == 0 } && gathering.isEmpty && queue.isEmpty && !describing }

    /// Events gathered and waiting for their turn (tests).
    var waitingJobs: Int { queue.count }

    /// Batches handed over by `eventsStarted` and not taken in yet (tests).
    nonisolated var admissionsWaiting: Int { gate.withLock { $0.admissionsWaiting } }

    private func loadUsage() {
        guard !loaded else { return }
        loaded = true
        let usage = AIUsage.load(from: usageFile, log: log)
        gate.withLock { $0.usage = usage }
    }

    private func saveUsage() {
        let usage = gate.withLock { $0.usage }
        do {
            try usage.save(to: usageFile)
            saveFailed = false
        } catch {
            if !saveFailed { log.warning("The AI descriptions' daily count could not be saved (\(URLFreeErrors.describe(error)))") }
            saveFailed = true
        }
    }

    // MARK: Words

    /// "Sunday 18 October 2026, 9:19 PM": the event's local time in the bridge's zone, for the model.
    static func localTime(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "EEEE d MMMM yyyy, h:mm a"
        return formatter.string(from: date)
    }
}
