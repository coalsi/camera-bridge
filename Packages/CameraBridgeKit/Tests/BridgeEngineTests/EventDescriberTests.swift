import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// The describer (AI descriptions plan, Task 5): which events are described (the camera's switch, a service, the daily limit, one per camera
/// per minute, the most specific of those that start together), its queue of width one that drops what waited more than a minute, the retry,
/// the pause after a refused key, the daily count in the bridge's time zone kept across restarts, and Try it. A fake service, fake pictures and
/// a clock the test moves; the engine's side (the service built from the settings and the key, the events from the edge handler) at the end.
@Suite(.timeLimit(.minutes(1))) struct EventDescriberTests {
    static let zone = TimeZone(identifier: "America/Los_Angeles")!
    /// Sunday 18 October 2026, 9:19 PM in Los Angeles (PDT): 2026-10-19 04:19 UTC.
    static let evening = Date(timeIntervalSince1970: 1_792_383_540)
    static let picture = LabeledPicture(label: "At the event", jpeg: Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9]))

    static func answer(_ summary: String = "A person walks up to the front door", kind: EventDescription.Kind = .person,
                       concern: EventDescription.Concern = .routine) -> EventDescription {
        EventDescription(summary: summary, kind: kind, concern: concern, model: "fake-model", at: evening)
    }

    /// Opens once; until then every `wait()` waits.
    final class Latch: Sendable {
        private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

        func wait() async {
            await withCheckedContinuation { continuation in
                let passes = state.withLock { state -> Bool in
                    if state.open { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if passes { continuation.resume() }
            }
        }

        func open() {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.open = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    /// A camera's frames and pictures as the describer gets them from the runtime: it notes each gather (at what date) and each decode.
    /// `holdGather`: gathering ends only once it opens. `holdPictures`: making the pictures (a decode, counted when it starts) ends only once
    /// it opens.
    final class FakeFrames: EventFrameSource {
        let gathers = Box<[Date]>([])
        let decodes = Box(0)
        let pictures: [LabeledPicture]
        let holdGather: Latch?
        let holdPictures: Latch?

        init(pictures: [LabeledPicture] = [EventDescriberTests.picture], holdGather: Latch? = nil, holdPictures: Latch? = nil) {
            self.pictures = pictures
            self.holdGather = holdGather
            self.holdPictures = holdPictures
        }

        func gatherEventFrames(at date: Date) async -> EventFrames {
            gathers.update { $0.append(date) }
            await holdGather?.wait()
            return EventFrames(date: date)
        }

        func eventPictures(from frames: EventFrames) async -> [LabeledPicture] {
            decodes.update { $0 += 1 }
            await holdPictures?.wait()
            return pictures
        }
    }

    /// An AI service that answers from a script (the last answer again once the script runs out) and notes every request.
    final class ScriptedService: AIVisionDescribing {
        let model = "fake-model"
        let requests = Box<[DescriptionRequest]>([])
        private let script: Box<[Result<EventDescription, AIProviderError>]>

        init(_ script: [Result<EventDescription, AIProviderError>] = [.success(EventDescriberTests.answer())]) {
            self.script = Box(script)
        }

        func describe(_ request: DescriptionRequest) async throws -> EventDescription {
            requests.update { $0.append(request) }
            let next = script.update { script -> Result<EventDescription, AIProviderError> in
                script.count > 1 ? script.removeFirst() : script[0]
            }
            return try next.get()
        }
    }

    /// An AI service that hangs: each call waits until the test answers it (`answer(_:)`), or until it is cancelled.
    final class HeldService: AIVisionDescribing {
        let model = "held-model"
        let calls = Box(0)
        let mostInFlight = Box(0)
        private let inFlight = Box(0)
        private let held = Mutex<[(id: UUID, continuation: CheckedContinuation<EventDescription, any Error>)]>([])

        var waiting: Int { held.withLock { $0.count } }

        func describe(_ request: DescriptionRequest) async throws -> EventDescription {
            calls.update { $0 += 1 }
            let now = inFlight.update { count -> Int in
                count += 1
                return count
            }
            mostInFlight.update { $0 = max($0, now) }
            defer { inFlight.update { $0 -= 1 } }
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.held.withLock { $0.append((id, continuation)) }
                    if Task.isCancelled { self.take(id)?.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                self.take(id)?.resume(throwing: CancellationError())
            }
        }

        /// Answers the call that has waited longest.
        func answer(_ result: Result<EventDescription, AIProviderError>) {
            let first = held.withLock { $0.isEmpty ? nil : $0.removeFirst().continuation }
            first?.resume(with: result.mapError { $0 as any Error })
        }

        private func take(_ id: UUID) -> CheckedContinuation<EventDescription, any Error>? {
            held.withLock { held in held.firstIndex { $0.id == id }.map { held.remove(at: $0).continuation } }
        }
    }

    /// A describer over cameras the test makes, a clock it moves (Los Angeles time) and a usage file in a folder of its own.
    final class Rig: Sendable {
        let directory: TemporaryDirectory
        let clock: Box<Date>
        let cameras = Box<[UUID: EventDescriber.Camera]>([:])
        let recorded = Box<[(description: EventDescription, event: StartedEvent)]>([])
        let describer: EventDescriber
        /// The describer's log category, this rig's own (tests run side by side).
        let category = "AI-\(UUID().uuidString.prefix(8))"

        var usageFile: URL { directory.url.appending(path: "ai/usage.json") }

        init(now: Date = EventDescriberTests.evening, directory: TemporaryDirectory? = nil, start: Bool = true, retryDelay: Duration = .zero) async throws {
            let directory = try directory ?? TemporaryDirectory()
            self.directory = directory
            let clock = Box(now)
            self.clock = clock
            describer = Self.describer(directory: directory, clock: clock, cameras: cameras, recorded: recorded, log: Log(category: category),
                                       retryDelay: retryDelay)
            if start { await describer.start() }
        }

        static func describer(directory: TemporaryDirectory, clock: Box<Date>, cameras: Box<[UUID: EventDescriber.Camera]>,
                              recorded: Box<[(description: EventDescription, event: StartedEvent)]>, log: Log = Log(category: "AI"),
                              retryDelay: Duration = .zero) -> EventDescriber {
            var timing = EventDescriber.Timing()
            timing.retryDelay = retryDelay
            return EventDescriber(usageFile: directory.url.appending(path: "ai/usage.json"),
                                  cameras: { ids in cameras.value.filter { ids.contains($0.key) } },
                                  record: { description, event in recorded.update { $0.append((description, event)) } },
                                  now: { clock.value }, timeZone: { EventDescriberTests.zone }, timing: timing, log: log)
        }

        /// A running camera; `describes`: its switch.
        @discardableResult
        func camera(_ name: String = "Front Door", describes: Bool = true, frames: FakeFrames = FakeFrames()) -> (id: UUID, frames: FakeFrames) {
            let id = UUID()
            cameras.update { $0[id] = EventDescriber.Camera(name: name, describes: describes, frames: frames) }
            return (id, frames)
        }

        func event(_ camera: UUID, _ kind: String = "Person", at date: Date? = nil) -> StartedEvent {
            StartedEvent(cameraID: camera, kind: kind, id: String(UUID().uuidString.prefix(12)), date: date ?? clock.value)
        }

        func advance(_ seconds: TimeInterval) {
            clock.update { $0 = $0.addingTimeInterval(seconds) }
        }

        /// Waits until nothing is gathered, waits or is described.
        func settle() async -> Bool {
            await eventually { await describer.isIdle }
        }

        deinit {
            directory.remove()
        }
    }

    // MARK: What is described

    @Test func aPersonEventGetsOneDescriptionStoredWithIt() async throws {
        let rig = try await Rig()
        let service = ScriptedService()
        rig.describer.setService(service, dailyLimit: 200, fresh: true)
        let (camera, frames) = rig.camera("Front Door")
        let event = rig.event(camera, "Person")
        rig.describer.eventsStarted([event])
        #expect(await rig.settle())

        #expect(rig.recorded.value.map(\.event) == [event], "stored with the event it describes")
        #expect(rig.recorded.value.map(\.description) == [Self.answer()])
        #expect(frames.gathers.value == [event.date], "the pictures are gathered around the event's own date")
        let request = try #require(service.requests.value.first)
        #expect(service.requests.value.count == 1)
        #expect(request.cameraName == "Front Door" && request.eventKind == "Person")
        #expect(request.localTime == "Sunday 18 October 2026, 9:19 PM", "the local time in the bridge's time zone")
        #expect(request.pictures == [Self.picture])
        let status = await rig.describer.status
        #expect(status.today == 1 && status.last7Days == 1 && !status.limitReached && status.lastError == nil)
    }

    @Test func ofSimultaneousStartsTheMostSpecificIsDescribed() async throws {
        let rig = try await Rig()
        let service = ScriptedService()
        rig.describer.setService(service, dailyLimit: 200, fresh: true)
        let porch = rig.camera("Porch").id, doorbell = rig.camera("Doorbell").id, garage = rig.camera("Garage")
        let motion = rig.event(porch, "Motion"), person = rig.event(porch, "Person")
        let ring = rig.event(doorbell, "Doorbell ring"), doorbellMotion = rig.event(doorbell, "Motion")
        // As the router hands them over: the most general first. Tamper, sound and alarm inputs are never described.
        rig.describer.eventsStarted([motion, person, doorbellMotion, ring, rig.event(garage.id, "Tamper"), rig.event(garage.id, "Sound")])
        #expect(await rig.settle())
        let described = rig.recorded.value.map(\.event)
        #expect(described.count == 2 && described.contains(person) && described.contains(ring), "one description per camera, on Person and on the ring")
        #expect(service.requests.value.map(\.eventKind).sorted() == ["Doorbell ring", "Person"])
        #expect(garage.frames.gathers.value.isEmpty)

        // The whole order: Person > Package > Vehicle > Animal > Face > Doorbell ring > Motion.
        let order = ["Person", "Package", "Vehicle", "Animal", "Face", "Doorbell ring", "Motion"]
        #expect(EventDescriber.kindOrder == order)
        for (index, kind) in order.enumerated() {
            let camera = rig.camera().id
            let together = order[index...].reversed().map { rig.event(camera, $0) }
            #expect(EventDescriber.mostSpecific(together).map(\.kind) == [kind])
        }
    }

    @Test func oneDescriptionPerCameraPerMinute() async throws {
        let rig = try await Rig()
        let service = ScriptedService()
        rig.describer.setService(service, dailyLimit: 200, fresh: true)
        let (porch, porchFrames) = rig.camera("Porch")
        let garage = rig.camera("Garage").id
        let first = rig.event(porch, "Motion")
        rig.describer.eventsStarted([first])
        #expect(await rig.settle())
        rig.advance(30)
        rig.describer.eventsStarted([rig.event(porch, "Person")])   // half a minute later: not described, nothing gathered
        let other = rig.event(garage, "Vehicle")
        rig.describer.eventsStarted([other])                       // another camera has its own minute
        #expect(await rig.settle())
        #expect(porchFrames.gathers.value.count == 1)
        rig.advance(30.5)
        let later = rig.event(porch, "Person")
        rig.describer.eventsStarted([later])
        #expect(await rig.settle())
        #expect(rig.recorded.value.map(\.event) == [first, other, later])
        #expect(service.requests.value.count == 3)
    }

    /// Motion first, then a more specific kind of the same camera a moment later in a publish of its own (the camera's person detection
    /// lags its motion): the later one takes the waiting event's place, frames and all, so the description lands on its row.
    @Test func aMoreSpecificKindSoonAfterTakesThePlaceOfTheWaitingEvent() async throws {
        let rig = try await Rig()
        let service = ScriptedService()
        rig.describer.setService(service, dailyLimit: 200, fresh: true)
        // Its frames are still being gathered.
        let latch = Latch()
        let (porch, porchFrames) = rig.camera("Porch", frames: FakeFrames(holdGather: latch))
        let motion = rig.event(porch, "Motion")
        rig.describer.eventsStarted([motion])
        #expect(await eventually { porchFrames.gathers.value.count == 1 })
        rig.advance(1)
        let person = rig.event(porch, "Person")
        rig.describer.eventsStarted([person])
        #expect(await eventually { rig.describer.admissionsWaiting == 0 })
        latch.open()
        #expect(await rig.settle())
        #expect(rig.recorded.value.map(\.event) == [person], "one description, on the Person row")
        #expect(service.requests.value.map(\.eventKind) == ["Person"])
        #expect(porchFrames.gathers.value == [motion.date], "the frames gathered for Motion are Person's")

        // It waits its turn: a more specific kind still takes its place within 2 s of the admitted event, a less specific one or a later one
        // does not, and the camera's minute still counts from the first.
        let held = HeldService()
        rig.describer.setService(held, dailyLimit: 200, fresh: true)
        let busy = rig.camera("Busy").id
        let (yard, yardFrames) = rig.camera("Yard")
        rig.describer.eventsStarted([rig.event(busy)])
        #expect(await eventually { held.waiting == 1 })
        let yardMotion = rig.event(yard, "Motion")
        rig.describer.eventsStarted([yardMotion])
        #expect(await eventually { await rig.describer.waitingJobs == 1 })
        rig.advance(1)
        rig.describer.eventsStarted([rig.event(yard, "Animal")])
        rig.advance(1)
        let vehicle = rig.event(yard, "Vehicle")                     // 2 s after Motion: still in time
        rig.describer.eventsStarted([vehicle])
        rig.advance(0.5)
        rig.describer.eventsStarted([rig.event(yard, "Doorbell ring")])   // less specific than Vehicle
        rig.describer.eventsStarted([rig.event(yard, "Person")])          // 2.5 s after Motion: too late
        rig.advance(30)
        rig.describer.eventsStarted([rig.event(yard, "Person")])          // within the minute of the first: nothing
        #expect(await eventually { rig.describer.admissionsWaiting == 0 })
        held.answer(.success(Self.answer()))
        #expect(await eventually { held.waiting == 1 })
        held.answer(.success(Self.answer("A van stops in the yard", kind: .vehicle)))
        #expect(await rig.settle())
        #expect(rig.recorded.value.last?.event == vehicle && rig.recorded.value.filter { $0.event.cameraID == yard }.count == 1)
        #expect(yardFrames.gathers.value == [yardMotion.date] && yardFrames.decodes.value == 1)
    }

    /// The switch is read again when the event's turn comes: a camera turned off, or removed, while its event waited has no picture made and
    /// nothing sent.
    @Test func aCameraTurnedOffOrRemovedWhileItsEventWaitsSendsNothing() async throws {
        let rig = try await Rig()
        let service = HeldService()
        rig.describer.setService(service, dailyLimit: 200, fresh: true)
        let porch = rig.camera("Porch").id, garage = rig.camera("Garage"), shed = rig.camera("Shed")
        rig.describer.eventsStarted([rig.event(porch)])
        #expect(await eventually { service.waiting == 1 })
        rig.describer.eventsStarted([rig.event(garage.id), rig.event(shed.id)])
        #expect(await eventually { await rig.describer.waitingJobs == 2 })
        rig.cameras.update { cameras in
            cameras[garage.id]?.describes = false   // the owner turned its switch off
            cameras[shed.id] = nil                  // and removed this one
        }
        service.answer(.success(Self.answer()))
        #expect(await rig.settle())
        #expect(garage.frames.decodes.value == 0 && shed.frames.decodes.value == 0, "no picture is made")
        #expect(service.calls.value == 1 && rig.recorded.value.map(\.event.cameraID) == [porch], "nothing is sent or stored for them")
    }

    @Test func camerasWithTheSwitchOffSendNothing() async throws {
        let rig = try await Rig()
        let service = ScriptedService()
        let (off, offFrames) = rig.camera("Back Yard", describes: false)
        let (on, onFrames) = rig.camera("Front Door")
        // No service yet: nothing is gathered for any camera.
        rig.describer.eventsStarted([rig.event(on, "Person")])
        #expect(await rig.settle())
        #expect(onFrames.gathers.value.isEmpty)

        rig.describer.setService(service, dailyLimit: 200, fresh: true)
        rig.describer.eventsStarted([rig.event(off, "Person"), rig.event(off, "Motion")])
        rig.advance(120)
        rig.describer.eventsStarted([rig.event(off, "Doorbell ring")])
        #expect(await rig.settle())
        #expect(service.requests.value.isEmpty, "the service is never called for it")
        #expect(offFrames.gathers.value.isEmpty && offFrames.decodes.value == 0, "and no picture is taken")
        #expect(rig.recorded.value.isEmpty)
        #expect(await rig.describer.status.today == 0)

        // A camera that is not running (removed, disabled) is skipped the same way.
        rig.describer.eventsStarted([rig.event(UUID(), "Person")])
        #expect(await rig.settle())
        #expect(service.requests.value.isEmpty)
    }

    // MARK: Looked at again before every send (final review I2)

    /// A camera whose pictures take a moment: the event is under way (its pictures are being made) when the test acts.
    private func eventUnderWay(_ rig: Rig, service: any AIVisionDescribing) async -> (camera: UUID, frames: FakeFrames, latch: Latch) {
        let latch = Latch()
        let (camera, frames) = rig.camera("Porch", frames: FakeFrames(holdPictures: latch))
        rig.describer.setService(service, dailyLimit: 200, fresh: true)
        rig.describer.eventsStarted([rig.event(camera)])
        #expect(await eventually { frames.decodes.value == 1 })
        return (camera, frames, latch)
    }

    @Test func aSwitchTurnedOffWhileThePicturesAreMadeSendsNothingAndCountsNothing() async throws {
        let rig = try await Rig()
        let service = ScriptedService()
        let (camera, _, latch) = await eventUnderWay(rig, service: service)
        rig.cameras.update { $0[camera]?.describes = false }
        latch.open()
        #expect(await rig.settle())
        #expect(service.requests.value.isEmpty, "nothing reached the service")
        #expect(rig.recorded.value.isEmpty)
        let status = await rig.describer.status
        #expect(status.today == 0 && status.lastError == nil, "it was dropped, not counted and not a failure")
    }

    @Test func aServiceTurnedOffOrChangedWhileThePicturesAreMadeGetsNothing() async throws {
        for change in ["off", "another service", "a new model"] {
            let rig = try await Rig()
            let old = ScriptedService()
            let (_, _, latch) = await eventUnderWay(rig, service: old)
            let new = ScriptedService()
            switch change {
            case "off": rig.describer.setService(nil, dailyLimit: 200, fresh: true)
            default: rig.describer.setService(new, dailyLimit: 200, fresh: true)
            }
            latch.open()
            #expect(await rig.settle())
            #expect(old.requests.value.isEmpty && new.requests.value.isEmpty, "\(change): the pictures were made for a service that is gone")
            #expect(rig.recorded.value.isEmpty)
            #expect(await rig.describer.status.today == 0, "\(change): not counted")
        }
    }

    /// The first call fails (a network error) and the retry waits its delay; the owner acts meanwhile. The retry goes nowhere.
    @Test func aSwitchTurnedOffWhileTheRetryWaitsSendsNoSecondRequest() async throws {
        let rig = try await Rig(retryDelay: .milliseconds(300))
        let service = HeldService()
        rig.describer.setService(service, dailyLimit: 200, fresh: true)
        let camera = rig.camera("Porch").id
        rig.describer.eventsStarted([rig.event(camera)])
        #expect(await eventually { service.waiting == 1 })
        service.answer(.failure(.unreachable))
        rig.cameras.update { $0[camera]?.describes = false }   // while the retry waits
        #expect(await rig.settle())
        #expect(service.calls.value == 1, "the retry was not sent")
        #expect(rig.recorded.value.isEmpty)
        let status = await rig.describer.status
        #expect(status.today == 1, "the first request was sent, and counted once")
        #expect(status.lastError == AIProviderError.unreachable.sentence, "and its failure is the service's, still true")
    }

    @Test func aServiceTurnedOffOrChangedWhileTheRetryWaitsSendsNoSecondRequest() async throws {
        for change in ["off", "another service", "a new model"] {
            let rig = try await Rig(retryDelay: .milliseconds(300))
            let old = HeldService()
            rig.describer.setService(old, dailyLimit: 200, fresh: true)
            rig.describer.eventsStarted([rig.event(rig.camera("Porch").id)])
            #expect(await eventually { old.waiting == 1 })
            let new = ScriptedService()
            old.answer(.failure(.serviceFailed(503)))
            switch change {
            case "off": rig.describer.setService(nil, dailyLimit: 200, fresh: true)
            default: rig.describer.setService(new, dailyLimit: 200, fresh: true)
            }
            #expect(await rig.settle())
            #expect(old.calls.value == 1 && new.requests.value.isEmpty, "\(change): no second request, to the old service or the new")
            #expect(rig.recorded.value.isEmpty)
            let status = await rig.describer.status
            #expect(status.lastError == nil, "\(change): the failure belonged to the service that is gone")
        }
    }

    /// Nothing changed: the retry is still sent (the check is not a way to lose events).
    @Test func aRetryWithNothingChangedIsStillSent() async throws {
        let rig = try await Rig(retryDelay: .milliseconds(50))
        let service = ScriptedService([.failure(.unreachable), .success(Self.answer())])
        rig.describer.setService(service, dailyLimit: 200, fresh: true)
        let event = rig.event(rig.camera().id)
        rig.describer.eventsStarted([event])
        #expect(await rig.settle())
        #expect(service.requests.value.count == 2 && rig.recorded.value.map(\.event) == [event])
    }

    // MARK: A service that is slow or down

    /// Review focus 2: ten cameras fire while every call hangs (30 s each, then the network error a timeout is): at most one call is in flight,
    /// a waiting event older than 60 s is dropped before its pictures are made, and `eventsStarted` returns at once every time.
    @Test func aStalledProviderDropsStaleEventsAndNeverBlocks() async throws {
        let rig = try await Rig()
        let service = HeldService()
        rig.describer.setService(service, dailyLimit: 200, fresh: true)
        let cameras = (0..<10).map { rig.camera("Camera \($0)") }
        var slowest = Duration.zero
        func fire(_ camera: UUID) {
            let event = rig.event(camera, "Motion")
            let started = ContinuousClock.now
            rig.describer.eventsStarted([event])
            slowest = max(slowest, ContinuousClock.now - started)
        }
        fire(cameras[0].id)
        #expect(await eventually { service.waiting == 1 })
        rig.advance(10)
        for camera in cameras.dropFirst() { fire(camera.id) }   // while the first call hangs
        #expect(await eventually { await rig.describer.waitingJobs == 9 })
        #expect(slowest < .milliseconds(250), "eventsStarted returned at once every time, the call in flight hanging (slowest \(slowest))")
        #expect(service.calls.value == 1)

        rig.advance(20)                                  // 30 s: the first call times out
        service.answer(.failure(.unreachable))
        #expect(await eventually { service.calls.value == 2 && service.waiting == 1 }, "a network error is tried once more")
        rig.advance(30)                                  // 60 s
        service.answer(.failure(.unreachable))
        #expect(await eventually { service.calls.value == 3 && service.waiting == 1 }, "the next event waited 50 s: it is still sent")
        rig.advance(30)                                  // 90 s: that event is 80 s old, too old for its retry
        service.answer(.failure(.unreachable))
        #expect(await rig.settle())

        #expect(service.calls.value == 3 && service.mostInFlight.value == 1, "never more than one call at a time")
        #expect(cameras.map(\.frames.decodes.value) == [1, 1, 0, 0, 0, 0, 0, 0, 0, 0], "the eight that waited 80 s were dropped before decoding")
        #expect(rig.recorded.value.isEmpty)
        let status = await rig.describer.status
        #expect(status.lastError == AIProviderError.unreachable.sentence && status.lastErrorAt == rig.clock.value)
        #expect(status.today == 2, "only what was sent counts")
    }

    @Test func aNetworkErrorOr5xxIsTriedOnceMoreAndAnyOtherFailureIsNot() async throws {
        let rig = try await Rig()
        let cases: [([Result<EventDescription, AIProviderError>], calls: Int, described: Bool)] = [
            ([.failure(.unreachable), .success(Self.answer())], 2, true),
            ([.failure(.serviceFailed(529)), .success(Self.answer())], 2, true),
            ([.failure(.serviceFailed(500)), .failure(.serviceFailed(503))], 2, false),
            ([.failure(.notFound), .success(Self.answer())], 1, false),
            ([.failure(.rateLimited), .success(Self.answer())], 1, false),
            ([.failure(.notAllowed), .success(Self.answer())], 1, false),
            ([.failure(.badAnswer), .success(Self.answer())], 1, false),
        ]
        for (script, calls, described) in cases {
            let service = ScriptedService(script)
            rig.describer.setService(service, dailyLimit: 200, fresh: true)
            let event = rig.event(rig.camera().id)
            rig.describer.eventsStarted([event])
            #expect(await rig.settle())
            #expect(service.requests.value.count == calls, "\(script)")
            #expect(rig.recorded.value.contains { $0.event == event } == described, "\(script)")
        }
        let status = await rig.describer.status
        #expect(status.today == cases.count, "a retry is the same description: counted once")
        #expect(status.lastError == AIProviderError.badAnswer.sentence)
    }

    // MARK: The daily limit

    /// Review focus 4: limit 2 (the third is skipped without work); the count starts again at local midnight, on the day Los Angeles leaves
    /// daylight saving time (a 25-hour day, all of it one day); a new describer reading the same file sees today's count.
    @Test func theDailyCountResetsAtLocalMidnightAndSurvivesRestart() async throws {
        // Saturday 31 October 2026, 11 PM PDT: 06:00 UTC on 1 November, the day a UTC count would already be in.
        let rig = try await Rig(now: Date(timeIntervalSince1970: 1_793_512_800))
        rig.describer.setService(ScriptedService(), dailyLimit: 2, fresh: true)
        let cameras = (0..<5).map { rig.camera("Camera \($0)") }
        rig.describer.eventsStarted([rig.event(cameras[0].id), rig.event(cameras[1].id)])
        #expect(await rig.settle())
        rig.describer.eventsStarted([rig.event(cameras[2].id)])
        #expect(await rig.settle())
        #expect(rig.recorded.value.count == 2)
        #expect(cameras[2].frames.gathers.value.isEmpty, "the third is skipped without work")
        var status = await rig.describer.status
        #expect(status.today == 2 && status.limitReached)

        rig.clock.set(Date(timeIntervalSince1970: 1_793_518_200))   // Sunday 1 November, 12:30 AM PDT (still 1 November in UTC)
        status = await rig.describer.status
        #expect(status.today == 0 && !status.limitReached && status.last7Days == 2, "a new day in Los Angeles")
        rig.describer.eventsStarted([rig.event(cameras[2].id)])
        #expect(await rig.settle())
        rig.clock.set(Date(timeIntervalSince1970: 1_793_604_600))   // 11:30 PM PST, 24 hours later and still 1 November
        rig.describer.eventsStarted([rig.event(cameras[3].id)])
        #expect(await rig.settle())
        status = await rig.describer.status
        #expect(rig.recorded.value.count == 4)
        #expect(status.today == 2 && status.limitReached && status.last7Days == 4)

        let saved = try String(contentsOf: rig.usageFile, encoding: .utf8)
        #expect(saved.contains(#""2026-10-31":2"#) && saved.contains(#""2026-11-01":2"#), "\(saved)")
        #expect(Self.mode(rig.usageFile) == 0o600 && Self.mode(rig.usageFile.deletingLastPathComponent()) == 0o700)

        // A restart: a new describer reads the same file.
        await rig.describer.stop()
        let cameraStore = Box<[UUID: EventDescriber.Camera]>([cameras[4].id: EventDescriber.Camera(name: "Camera 4", describes: true, frames: cameras[4].frames)])
        let again = Rig.describer(directory: rig.directory, clock: rig.clock, cameras: cameraStore, recorded: rig.recorded)
        await again.start()
        again.setService(ScriptedService(), dailyLimit: 2, fresh: true)
        status = await again.status
        #expect(status.today == 2 && status.limitReached && status.last7Days == 4)
        again.eventsStarted([rig.event(cameras[4].id)])
        #expect(await eventually { await again.isIdle })
        #expect(cameras[4].frames.gathers.value.isEmpty, "the limit holds after the restart")
        await again.stop()
    }

    @Test func aMissingOrUnreadableUsageFileStartsAtZero() async throws {
        let rig = try await Rig(start: false)
        try FileManager.default.createDirectory(at: rig.usageFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: rig.usageFile)
        await rig.describer.start()
        #expect(await rig.describer.status.today == 0)
        rig.describer.setService(ScriptedService(), dailyLimit: 200, fresh: true)
        rig.describer.eventsStarted([rig.event(rig.camera().id)])
        #expect(await rig.settle())
        #expect(await rig.describer.status.today == 1 && rig.recorded.value.count == 1)
    }

    // MARK: A refused key

    @Test func aRefusedKeyPausesUntilTheKeyChanges() async throws {
        let capture = LiveLogCapture()
        defer { capture.stop() }
        let rig = try await Rig()
        let refused = ScriptedService([.failure(.keyRefused)])
        rig.describer.setService(refused, dailyLimit: 200, fresh: true)
        let cameras = (0..<4).map { rig.camera("Camera \($0)") }
        rig.describer.eventsStarted([rig.event(cameras[0].id)])
        #expect(await rig.settle())
        var status = await rig.describer.status
        #expect(status.lastError == "The key was refused." && status.lastErrorAt == rig.clock.value && status.paused)
        #expect(refused.requests.value.count == 1, "a 401 is not tried again")

        rig.advance(5)
        rig.describer.eventsStarted([rig.event(cameras[1].id)])
        // Told that nothing about the service changed (`fresh: false`, as at the engine's start): still paused.
        rig.describer.setService(refused, dailyLimit: 300, fresh: false)
        rig.describer.eventsStarted([rig.event(cameras[2].id)])
        #expect(await rig.settle())
        #expect(refused.requests.value.count == 1 && cameras[1].frames.gathers.value.isEmpty && cameras[2].frames.gathers.value.isEmpty,
                "paused: nothing is gathered or sent")
        status = await rig.describer.status
        #expect(status.lastErrorAt == rig.clock.value.addingTimeInterval(-5), "one error, not one per event")
        let said = capture.matching(category: rig.category, containing: "refused")
        #expect(said.count == 1, "logged once: \(said)")

        // A new key (or service): describing goes on, and the old error is gone.
        let working = ScriptedService()
        rig.describer.setService(working, dailyLimit: 300, fresh: true)
        status = await rig.describer.status
        #expect(status.lastError == nil && status.lastErrorAt == nil && !status.paused)
        let event = rig.event(cameras[3].id)
        rig.describer.eventsStarted([event])
        #expect(await rig.settle())
        #expect(rig.recorded.value.map(\.event) == [event] && working.requests.value.count == 1)
    }

    @Test func aLateRefusalOfAnOldKeyDoesNotPauseTheNewOne() async throws {
        let rig = try await Rig()
        let old = HeldService()
        rig.describer.setService(old, dailyLimit: 200, fresh: true)
        let first = rig.camera()
        rig.describer.eventsStarted([rig.event(first.id)])
        #expect(await eventually { old.waiting == 1 })
        let new = ScriptedService()
        rig.describer.setService(new, dailyLimit: 200, fresh: true)   // the key changed while the old one's request was out
        old.answer(.failure(.keyRefused))
        #expect(await rig.settle())
        var status = await rig.describer.status
        #expect(!status.paused && status.lastError == nil, "the old key's refusal is not the new one's error")
        let event = rig.event(rig.camera().id)
        rig.describer.eventsStarted([event])
        #expect(await rig.settle())
        #expect(rig.recorded.value.map(\.event) == [event], "the new key is not paused by the old one's 401")

        // Told that nothing about the service changed (`fresh: false`): its refusal still counts. (The engine says `fresh` for every change.)
        let same = HeldService()
        rig.describer.setService(same, dailyLimit: 200, fresh: true)
        rig.describer.eventsStarted([rig.event(rig.camera().id)])
        #expect(await eventually { same.waiting == 1 })
        rig.describer.setService(same, dailyLimit: 300, fresh: false)
        same.answer(.failure(.keyRefused))
        #expect(await rig.settle())
        status = await rig.describer.status
        #expect(status.paused && status.lastError == AIProviderError.keyRefused.sentence)
    }

    // MARK: No place for recordings

    /// Review focus 5: without a recordings folder no event is kept, so the event log hands out no started events and nothing is described;
    /// the engine's status says why, for the card.
    @MainActor @Test func withoutARecordingsFolderNothingIsDescribed() async throws {
        let harness = try ArchiveStoreHarness { _ in }
        var settings = harness.settings()
        settings.nvrFolder = nil
        await harness.start(settings)
        let rig = try await Rig()
        let service = ScriptedService()
        rig.describer.setService(service, dailyLimit: 200, fresh: true)
        let (camera, frames) = rig.camera()
        let started = harness.store.recordEvents([EventEdge(cameraID: camera, kind: "Person", date: rig.clock.value, began: true)], video: { _ in false })
        rig.describer.eventsStarted(started)   // what the engine's edge handler does
        #expect(await rig.settle())
        #expect(started.isEmpty && service.requests.value.isEmpty && frames.gathers.value.isEmpty)

        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let engine = BridgeEngine(environment: .inert(directory: directory.url))
        #expect(await engine.aiStatus().needsRecordingsFolder, "no folder chosen: the card says descriptions need one")
        try await engine.updateSettings { $0.nvrFolder = directory.url.path(percentEncoded: false) }
        #expect(await engine.aiStatus().needsRecordingsFolder == false)
    }

    /// With a folder, the engine's composition: the event log's started events go to the describer, and its description comes back with the
    /// event when the events are read.
    @Test func aDescriptionGoesIntoTheEventLogBesideItsEvent() async throws {
        let harness = try ArchiveStoreHarness { _ in }
        await harness.start()
        let start: Int64 = 1_760_101_200_000
        harness.clock.set(ArchiveTime.date(ms: start + 1_000))
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(ArchiveTime.date(ms: start + 1_000))
        let camera = UUID()
        let frames = FakeFrames()
        let store = harness.store
        var timing = EventDescriber.Timing()
        timing.retryDelay = .zero
        let describer = EventDescriber(usageFile: directory.url.appending(path: "ai/usage.json"),
                                       cameras: { _ in [camera: EventDescriber.Camera(name: "Porch", describes: true, frames: frames)] },
                                       record: { store.recordDescription($0, for: $1) }, now: { clock.value }, timeZone: { Self.zone }, timing: timing)
        await describer.start()
        // The model's clock has a fraction of a millisecond: the file keeps whole milliseconds like every other time in it.
        let answer = EventDescription(summary: "A cat crosses the porch", kind: .animal, concern: .routine, model: "fake-model",
                                      at: ArchiveTime.date(ms: start + 4_000).addingTimeInterval(0.000_4))
        describer.setService(ScriptedService([.success(answer)]), dailyLimit: 200, fresh: true)
        let started = store.recordEvents([EventEdge(cameraID: camera, kind: "Motion", date: ArchiveTime.date(ms: start), began: true)], video: { _ in false })
        describer.eventsStarted(started)
        #expect(await eventually { await describer.isIdle })
        await store.eventLog.flush()
        let page = try await store.events(cameras: [camera], range: ArchiveTime.date(ms: start - 1_000)..<ArchiveTime.date(ms: start + 1_000), limit: 5)
        var stored = answer
        stored.at = ArchiveTime.date(ms: start + 4_000)
        #expect(page.events.map(\.description) == [stored])
        await describer.stop()
    }

    // MARK: Try it

    @Test func tryNowAnswersWithoutStoring() async throws {
        let capture = LiveLogCapture()
        defer { capture.stop() }
        let rig = try await Rig()
        let (camera, frames) = rig.camera("Garage", describes: false)   // Try it works before any camera's switch is on
        await #expect(throws: AIDescriberError.noService) { try await rig.describer.tryNow(cameraID: camera) }
        let service = ScriptedService([.success(Self.answer("A car is parked in the driveway", kind: .vehicle))])
        rig.describer.setService(service, dailyLimit: 2, fresh: true)

        let description = try await rig.describer.tryNow(cameraID: camera)
        #expect(description.summary == "A car is parked in the driveway" && description.kind == .vehicle)
        #expect(rig.recorded.value.isEmpty, "nothing is stored")
        #expect(frames.gathers.value == [rig.clock.value], "the pictures around now")
        let request = try #require(service.requests.value.first)
        #expect(request.cameraName == "Garage" && request.pictures == [Self.picture])
        #expect(await rig.describer.status.today == 1, "it counts toward the day")

        await #expect(throws: AIDescriberError.cameraNotRunning) { try await rig.describer.tryNow(cameraID: UUID()) }
        let blind = rig.camera("Blind", frames: FakeFrames(pictures: [])).id
        await #expect(throws: AIDescriberError.noPictures) { try await rig.describer.tryNow(cameraID: blind) }
        #expect(await rig.describer.status.today == 1, "nothing was sent")

        rig.describer.setService(ScriptedService([.failure(.notFound)]), dailyLimit: 2, fresh: true)
        await #expect(throws: AIProviderError.notFound) { try await rig.describer.tryNow(cameraID: camera) }
        #expect(await rig.describer.status.lastError == AIProviderError.notFound.sentence)
        #expect(capture.matching(category: rig.category, containing: "Try it for Garage failed: \(AIProviderError.notFound.sentence)", minimum: .info).count == 1)
        #expect(capture.matching(category: rig.category, containing: "was not described", minimum: .debug).isEmpty)
        await #expect(throws: AIDescriberError.limitReached(2)) { try await rig.describer.tryNow(cameraID: camera) }
        #expect(AIDescriberError.limitReached(2).sentence == "Today’s limit of 2 descriptions is reached.")
    }

    @Test func aTryThatWorksAfterARefusedKeyLetsDescribingGoOn() async throws {
        let capture = LiveLogCapture()
        defer { capture.stop() }
        let rig = try await Rig()
        let service = ScriptedService([.failure(.keyRefused), .success(Self.answer())])
        rig.describer.setService(service, dailyLimit: 200, fresh: true)
        let camera = rig.camera("Front Door").id
        await #expect(throws: AIProviderError.keyRefused) { try await rig.describer.tryNow(cameraID: camera) }
        var status = await rig.describer.status
        #expect(status.paused && status.lastError == "The key was refused.")
        #expect(capture.matching(category: rig.category, containing: "Try it for Front Door failed: The key was refused.", minimum: .info).count == 1)
        let paused = rig.event(rig.camera().id)
        rig.describer.eventsStarted([paused])
        #expect(await rig.settle())
        #expect(rig.recorded.value.isEmpty, "a refused key pauses describing, from Try it too")
        _ = try await rig.describer.tryNow(cameraID: camera)   // the owner fixed the key at the service, and Try it works
        status = await rig.describer.status
        #expect(!status.paused && status.lastError == nil, "the refusal is no longer the last error")
        let event = rig.event(rig.camera().id)
        rig.describer.eventsStarted([event])
        #expect(await rig.settle())
        #expect(rig.recorded.value.map(\.event) == [event])
    }

    @Test func oneTryAtATime() async throws {
        let rig = try await Rig()
        let held = HeldService()
        rig.describer.setService(held, dailyLimit: 200, fresh: true)
        let camera = rig.camera().id
        let first = Task { try await rig.describer.tryNow(cameraID: camera) }
        #expect(await eventually { held.waiting == 1 })
        await #expect(throws: AIDescriberError.alreadyTrying) { try await rig.describer.tryNow(cameraID: camera) }
        #expect(AIDescriberError.alreadyTrying.sentence == "A try is already running.")
        held.answer(.failure(.notFound))
        await #expect(throws: AIProviderError.notFound) { try await first.value }
        rig.describer.setService(ScriptedService(), dailyLimit: 200, fresh: true)
        #expect(try await rig.describer.tryNow(cameraID: camera) == Self.answer(), "a try that failed lets the next one run")
        #expect(held.calls.value == 1)
    }

    // MARK: Stopping

    @Test func stoppingEndsAHangingCallAndIgnoresLaterEvents() async throws {
        let rig = try await Rig()
        let service = HeldService()
        rig.describer.setService(service, dailyLimit: 200, fresh: true)
        rig.describer.eventsStarted([rig.event(rig.camera().id)])
        #expect(await eventually { service.waiting == 1 })
        let stopping = ContinuousClock.now
        await rig.describer.stop()
        #expect(ContinuousClock.now - stopping < .seconds(2), "the call in flight was cancelled")
        let (camera, frames) = rig.camera()
        rig.describer.eventsStarted([rig.event(camera)])
        try await Task.sleep(for: .milliseconds(100))
        #expect(frames.gathers.value.isEmpty && service.calls.value == 1)
    }

    // MARK: The engine's side

    @MainActor @Test func theEngineBuildsTheServiceFromTheSettingsAndTheKey() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let engine = BridgeEngine(environment: .inert(directory: directory.url))
        #expect(engine.aiDescriber.service == nil, "no service chosen")
        try await engine.updateSettings { $0.ai = AIDescriptionSettings(provider: .anthropic, dailyLimit: 40) }
        #expect(engine.aiDescriber.service == nil, "Claude needs its key")
        try engine.setAIKey("sk-test-0000")
        #expect(engine.aiDescriber.service is AnthropicVision && engine.aiDescriber.service?.model == "claude-haiku-5-5")
        #expect(!String(describing: engine.aiDescriber.service as Any).contains("sk-test"))
        try await engine.updateSettings { $0.ai.model = "claude-sonnet-5-5" }
        #expect(engine.aiDescriber.service?.model == "claude-sonnet-5-5", "a new model: a new service, the key read again")
        try await engine.updateSettings {
            $0.ai = AIDescriptionSettings(provider: .openAICompatible, model: "llava:13b", baseURL: "http://192.168.77.10:11434/v1")
        }
        #expect(engine.aiDescriber.service is OpenAICompatibleVision && engine.aiDescriber.service?.model == "llava:13b",
                "a home server needs no key (the Claude key went with the change of service)")
        try await engine.updateSettings { $0.ai.provider = nil }
        #expect(engine.aiDescriber.service == nil)
    }

    /// Final review M1: every change to the AI settings (a new model or daily limit too, not only another service or key) starts a new
    /// generation, so the last error is forgotten and a late failure of what was in use before is not kept as the current one.
    @MainActor @Test func everyChangeToTheAISettingsStartsANewGeneration() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let engine = BridgeEngine(environment: .inert(directory: directory.url))
        try await engine.updateSettings { $0.ai = AIDescriptionSettings(provider: .anthropic, dailyLimit: 40) }
        try engine.setAIKey("sk-test-0000")
        var generation = engine.aiDescriber.serviceGeneration
        func next(_ what: String, _ change: (inout BridgeSettings) -> Void) async throws {
            try await engine.updateSettings(change)
            #expect(engine.aiDescriber.serviceGeneration > generation, "\(what) starts a new generation")
            generation = engine.aiDescriber.serviceGeneration
        }
        try await next("a new model") { $0.ai.model = "claude-sonnet-5-5" }
        try await next("a new daily limit") { $0.ai.dailyLimit = 60 }
        try await next("another service") {
            $0.ai = AIDescriptionSettings(provider: .openAICompatible, model: "llava", baseURL: "http://192.168.77.10:11434/v1")
        }
        try await next("a new model of that service") { $0.ai.model = "llava:13b" }
        // The key rule is its own: the Claude key went with the service, and a new model of the home server has none to forget.
        #expect(!engine.aiKeySaved)
        // Settings that are not the AI's leave it alone.
        try await engine.updateSettings { $0.logLevel = .debug }
        #expect(engine.aiDescriber.serviceGeneration == generation, "a change elsewhere is no new generation")
    }

    /// A change of service deletes the key before the settings are saved; when the save then fails, the settings stay but the key is gone, and
    /// the describer must not go on with it.
    @MainActor @Test func aSaveThatFailsAfterTheKeyWentStopsTheServiceThatUsedIt() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let engine = BridgeEngine(environment: .inert(directory: directory.url))
        try await engine.updateSettings { $0.ai = AIDescriptionSettings(provider: .anthropic) }
        try engine.setAIKey("sk-test-0000")
        #expect(engine.aiDescriber.service is AnthropicVision)
        let file = directory.url.appending(path: ConfigurationStore.fileName)   // a newer build wrote it since: this one cannot save over it
        var contents = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        contents["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: contents).write(to: file)
        await #expect(throws: (any Error).self) {
            try await engine.updateSettings { $0.ai = AIDescriptionSettings(provider: .openAICompatible, baseURL: "http://192.168.77.10:11434/v1") }
        }
        #expect(engine.settings.ai.provider == .anthropic && engine.aiDescriber.service == nil, "Claude is not asked with a key that is gone")
    }

    @MainActor @Test func theEngineMapsATryForACameraItDoesNotKnow() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let engine = BridgeEngine(environment: .inert(directory: directory.url))
        await #expect(throws: EngineError.unknownCamera) { try await engine.tryAIDescription(cameraID: UUID()) }
    }

    static func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

#if canImport(Darwin)
/// The engine end to end with the demo camera: a motion event of a camera with the switch on is described by the service the settings name,
/// with the saved key, and the description is read back with the event.
extension EventDescriberTests {
    /// Answers every request as Claude would, and notes the requests.
    final class ClaudeTransport: AITransport {
        let requests = Box<[URLRequest]>([])

        func send(_ request: URLRequest) async throws -> (body: Data, status: Int) {
            requests.update { $0.append(request) }
            let body = #"{"content":[{"type":"tool_use","name":"describe_event","input":{"summary":"Nobody is in view","kind":"other","concern":"routine"}}]}"#
            return (Data(body.utf8), 200)
        }
    }

    @MainActor static func engine(transport: ClaudeTransport, recordings: URL?, data: TemporaryDirectory) async throws -> (BridgeEngine, UUID) {
        var environment = BridgeEnvironment.testing(directory: data.url)
        environment.archivePolicy = ArchiveStoreEngineTests.policy()
        var tuning = EngineTuning.testing
        tuning.aiTransport = transport
        let engine = BridgeEngine(environment: environment, tuning: tuning)
        try await engine.updateSettings {
            $0.basePort = UInt16.random(in: 22_000...28_000)
            $0.sensorsBridgePort = 0
            $0.webhookPort = 0
            $0.nvrFolder = recordings?.path(percentEncoded: false)
            $0.ai = AIDescriptionSettings(provider: .anthropic)
        }
        try engine.setAIKey("sk-test-0000")
        var camera = EngineFixture.demoCamera(name: "Porch")
        camera.aiDescriptions = true
        try await engine.addCamera(camera, password: nil)
        return (engine, camera.id)
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func theEngineDescribesARealEventAndKeepsTheDescription() async throws {
        let data = try TemporaryDirectory(), recordings = try TemporaryDirectory()
        defer { data.remove(); recordings.remove() }
        let transport = ClaudeTransport()
        let (engine, camera) = try await Self.engine(transport: transport, recordings: recordings.url, data: data)
        await engine.start()
        #expect(await eventually(timeout: archiveStorePatience) { engine.archive.isReady && engine.cameras.first?.connection == .online })
        let before = Date()
        await engine.triggerTestMotion(cameraID: camera)
        let range = before.addingTimeInterval(-60)..<Date().addingTimeInterval(60)
        var page = ArchiveEventPage(events: [], isTruncated: false)
        #expect(await eventually(timeout: .seconds(30)) {
            page = (try? await engine.archive.events(cameras: [camera], range: range, limit: 10)) ?? page
            return page.events.first?.description != nil
        })
        #expect(page.events.first?.description?.summary == "Nobody is in view")
        let sent = try #require(transport.requests.value.first)
        #expect(transport.requests.value.count == 1)
        #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages" && sent.value(forHTTPHeaderField: "x-api-key") == "sk-test-0000")
        let body = try #require(sent.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let content = (body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]] ?? []
        #expect(content.contains { $0["type"] as? String == "image" }, "the demo camera's pictures went with it")
        let status = await engine.aiStatus()
        #expect(status.today == 1 && !status.needsRecordingsFolder)
        await engine.stop()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func theEngineDescribesNothingWithoutARecordingsFolder() async throws {
        let data = try TemporaryDirectory()
        defer { data.remove() }
        let transport = ClaudeTransport()
        let (engine, camera) = try await Self.engine(transport: transport, recordings: nil, data: data)
        await engine.start()
        #expect(await eventually(timeout: .seconds(15)) { engine.cameras.first?.connection == .online })
        await engine.triggerTestMotion(cameraID: camera)
        try await Task.sleep(for: .seconds(8))   // longer than a gather (6 s at most) and a decode of the demo camera
        #expect(transport.requests.value.isEmpty)
        let status = await engine.aiStatus()
        #expect(status.needsRecordingsFolder && status.today == 0)
        await engine.stop()
    }
}
#endif
