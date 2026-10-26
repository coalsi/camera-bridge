import BridgeSupport
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

// The sky detector at work (Task 7): one camera's pipeline from its pictures to the sky log (`SkyCameraDetector`): lights found and followed,
// matched to the flight feed or kept as unexplained with a still, the aim fed with the matches, the conditions of the sky, a gap and a camera's
// own brightness jump, the status the card reads, and the help for an aim that is far off (Ruling S18: planes that match nothing for 2 h, and
// the wide search of the card). All made up: the place is 40.0000, −100.0000, the aircraft are the fixtures', nothing is downloaded.

// MARK: - Made-up nights

/// Lights in a made-up sky as a camera sees them: pictures of `width` × `height` (the analysed size of a `pictureWidth` × `pictureHeight`
/// picture), five a second from `start`, a sky of 30 with noise σ 3 and a dot of amplitude 60 wherever a light is.
struct SkyScene {
    var model: SkyCameraModel
    var width = 640
    var height = 284
    var pictureWidth = 4256
    var pictureHeight = 1888
    var start: Date
    var lights: [@Sendable (Date) -> SkyDirection?] = []
    /// From this picture on, every pixel 60 levels brighter (the IR-cut filter, an exposure step).
    var brightenFrom: Int?
    var stream: SkyStreamChoice.Stream = .main

    /// Picture `index`: at `start + index / 5` on the box's clock, at `100 + index / 5` s on the stream's.
    func frame(_ index: Int, using random: inout SkyRandom) -> SkyFrame {
        let seconds = Double(index) / 5
        let wallClock = start.addingTimeInterval(seconds)
        var picture = SkyPicture(width: width, height: height, sky: 30, noise: 3, using: &random)
        if let brightenFrom, index >= brightenFrom { picture.brighten(by: 60) }
        for light in lights {
            guard let direction = light(wallClock), let hit = model.project(direction).first else { continue }
            picture.dot(x: hit.point.x * Double(width), y: hit.point.y * Double(height), amplitude: 60)
        }
        return SkyFrame(image: picture.image, time: 100 + seconds, wallClock: wallClock, clockOffset: 0, pictureWidth: pictureWidth,
                        pictureHeight: pictureHeight, stream: stream, decoding: .software)
    }

    /// A light along `path` from `from` seconds after `start` for as long as the path lasts.
    func along(_ path: SkyPath, from offset: Double) -> @Sendable (Date) -> SkyDirection? {
        let begins = start.addingTimeInterval(offset), duration = path.duration
        return { date in
            let into = date.timeIntervalSince(begins)
            return into >= 0 && into <= duration ? path.direction(at: into) : nil
        }
    }
}

/// A sky camera's detector in a test: folders of its own for the aim and the recordings, a flight history, the log, a clock the test sets and
/// stills that say when they were asked for.
final class SkyDetectorRig: Sendable {
    static let zone = TimeZone(identifier: "America/Chicago")!
    static let camera = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    /// The camera's id: `SkyDetectorRig.camera` unless a test that reads the journal gives it one of its own (the log is shared by tests that
    /// run side by side, and a detector logs with its camera's id).
    let camera: UUID
    let data: TemporaryDirectory
    let recordings: TemporaryDirectory
    let flights = FlightHistory()
    let log = SkyLogStore(log: .silent)
    let clock: Box<Date>
    let stillsAsked = Box<[Date]>([])
    /// How far after the time asked for the camera's ring answers with a picture (s): its keyframes are the last 12 s or so, so a light whose middle is
    /// older than that gets the oldest it holds; a test sets it.
    let stillLate = Box<TimeInterval>(0)
    /// Whether the recordings drive has room for a picture (`Context.roomForStills`); a test sets it.
    let room = Box(true)
    /// What the camera's recording gives for a picture made later (`Context.recordedStill`, Ruling S31), and the times it was asked for.
    let recorded = Box(SkyRecordedStill.gone)
    let recordedAsked = Box<[Date]>([])
    /// The pictures the detector said it wrote (`Context.stillWritten`, for their thumbnails), as "<night>/<id>".
    let stillsWritten = Box<[String]>([])
    let context: SkyCameraDetector.Context
    let detector: SkyCameraDetector
    let observer: SkyObserver

    init(settings: SkyDetectorSettings, pictureWidth: Int, pictureHeight: Int, observer: SkyObserver = SkyFixtures.observer,
         start: Date = SkyFixtures.aimEpoch, data: TemporaryDirectory? = nil, camera: UUID = SkyDetectorRig.camera,
         stillDelay: Duration = .zero) throws {
        let data = try data ?? TemporaryDirectory()
        let recordings = try TemporaryDirectory()
        let clock = Box(start)
        let asked = stillsAsked, late = stillLate, room = room, recorded = recorded, recordedAsked = recordedAsked, logStore = log, written = stillsWritten
        self.camera = camera
        self.data = data
        self.recordings = recordings
        self.clock = clock
        self.observer = observer
        let folder = recordings.url
        context = SkyCameraDetector.Context(cameraID: camera, cameraName: "North Sky", settings: settings, observer: observer, zone: Self.zone,
                                            pictureWidth: pictureWidth, pictureHeight: pictureHeight, folder: { folder },
                                            still: { date in
                                                asked.update { $0.append(date) }
                                                if stillDelay > .zero { try? await Task.sleep(for: stillDelay) }   // a keyframe that takes its time to decode
                                                return (SkyLogStoreTests.jpeg("still"), date.addingTimeInterval(late.value))
                                            },
                                            roomForStills: { room.value },
                                            recordedStill: { date in
                                                recordedAsked.update { $0.append(date) }
                                                return recorded.value
                                            },
                                            readLog: { night in
                                                await logStore.flush()
                                                return logStore.read(camera: camera, night: night, folder: folder).entries
                                            },
                                            stillWritten: { id, night in written.update { $0.append("\(night)/\(id)") } })
        detector = SkyCameraDetector(context: context, directory: data.url.appending(path: "sky/\(camera.uuidString)", directoryHint: .isDirectory),
                                     flights: flights, log: log, now: { clock.value }, seed: 7)
    }

    /// The same camera's detector again, on the same folders (a restart); with `settings`, its card as it was changed while it was off.
    func again(settings: SkyDetectorSettings? = nil) -> SkyCameraDetector {
        let clock = clock
        var context = context
        if let settings { context.settings = settings }
        return SkyCameraDetector(context: context, directory: data.url.appending(path: "sky/\(camera.uuidString)", directoryHint: .isDirectory),
                                 flights: flights, log: log, now: { clock.value }, seed: 7)
    }

    /// The camera's aim file (`aim.json`).
    var aimFile: URL {
        data.url.appending(path: "sky/\(camera.uuidString)/\(SkyAimStore.aimFileName)", directoryHint: .notDirectory)
    }

    func night(_ date: Date) -> String { SkyNight.logName(for: date, observer: observer, zone: Self.zone) }

    /// What the log holds for the night of `date`, once everything queued is written.
    func logged(_ date: Date = SkyFixtures.aimEpoch) async -> (entries: [SkyEntry], conditions: [SkyConditions]) {
        await detector.settle()
        await log.flush()
        return log.read(camera: camera, night: night(date), folder: recordings.url)
    }

    /// Plays pictures `range` of `scene` to the detector.
    func play(_ scene: SkyScene, _ range: Range<Int>, seed: UInt64 = 0x5EED, gapAfter: Int? = nil) async {
        var random = SkyRandom(seed: seed)
        for index in range {
            let frame = scene.frame(index, using: &random)
            clock.set(frame.wallClock)
            await detector.frame(frame)
            if index == gapAfter { await detector.gap(at: frame.wallClock, reason: "the camera's stream was reconnected") }
        }
    }

    func remove() {
        data.remove()
        recordings.remove()
    }
}

@Suite(.timeLimit(.minutes(3))) struct SkyDetectorTests {
    static let start = SkyFixtures.aimEpoch
    static let observer = SkyFixtures.observer
    /// A stitched dual camera facing north-north-west, 15° up (4256 × 1888, analysed 640 wide): the fixtures' TEST123 crosses its left lens.
    static let dualCard = SkyDetectorSettings(enabled: true, facing: 330, tilt: 15)
    static var dualModel: SkyCameraModel { SkyCameraModel.initial(facing: 330, tilt: 15, pictureWidth: 4256, pictureHeight: 1888) }
    /// A light with no aircraft: up in the north-north-east, going east at 1°/s for 8 s (the right lens), bending right as it goes (12°/s), so
    /// that the rules leave it unexplained (a straight steady light at night is a probable plane or satellite).
    static let stray = SkyPath(start: SkyDirection(azimuth: 20, elevation: 35), bearing: Double.pi / 2,
                               legs: [SkyPath.Leg(duration: 8, speed: 1, turnRate: 12)])

    // MARK: Lights to the log

    @Test func aMatchedPlaneIsLoggedAsAPlane() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        let flight = SkyFixtures.Flight()
        await rig.flights.add(flight.reports(from: Self.start.addingTimeInterval(-10), to: Self.start.addingTimeInterval(30)))
        await rig.detector.start()
        var scene = SkyScene(model: Self.dualModel, start: Self.start)
        scene.lights = [{ date in
            let into = date.timeIntervalSince(Self.start)
            return into >= 1 && into <= 13 ? flight.direction(at: date) : nil
        }, scene.along(Self.stray, from: 2)]
        await rig.play(scene, 0..<85)

        let entries = await rig.logged().entries
        #expect(entries.count == 2, "\(entries.map { ($0.label, $0.start.timeIntervalSince(Self.start)) })")
        let plane = try #require(entries.first { $0.by == .flight })
        #expect(plane.label == .probablePlane, "a match while the aim is rough")
        #expect(plane.detail == "TEST123 · 35,000 ft" && plane.kind == .track && !plane.hasStill && !plane.candidate)
        #expect(plane.camera == SkyDetectorRig.camera && plane.start >= Self.start.addingTimeInterval(1) && plane.end <= Self.start.addingTimeInterval(13.5))
        #expect((2...SkyPathPoint.maximumPerEntry).contains(plane.path.count) && plane.path.first?.t == 0)
        #expect(plane.path.allSatisfy { $0.x > 0 && $0.x < 0.5 && $0.y > 0 && $0.y < 1 }, "the left lens, in the original picture's 0…1")
        #expect(abs(plane.measures.azimuth - flight.direction(at: plane.start).azimuth) < 2, "\(plane.measures.azimuth)")
        // The match went to the aim, in one pass: the aim's matches are the aircraft's.
        let store = SkyAimStore(directory: rig.data.url.appending(path: "sky/\(SkyDetectorRig.camera.uuidString)", directoryHint: .isDirectory),
                                log: Log(category: "SkyTest"), start: Self.dualModel, pictureWidth: 4256, pictureHeight: 1888)
        let matches = await store.correspondences()
        #expect(!matches.isEmpty && matches.allSatisfy { $0.object == flight.hex && $0.source == .plane })
        #expect(rig.stillsAsked.value.count == 1, "only the unexplained light's picture is asked for")
        await rig.detector.stop()
    }

    @Test func anUnmatchedTrackIsUnexplainedWithAStill() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.flights.add(SkyFixtures.Flight().reports(from: Self.start.addingTimeInterval(-10), to: Self.start.addingTimeInterval(30)))
        await rig.detector.start()
        var scene = SkyScene(model: Self.dualModel, start: Self.start)
        scene.lights = [scene.along(Self.stray, from: 2)]
        await rig.play(scene, 0..<70)

        let entries = await rig.logged().entries
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.label == .unexplained && entry.by == nil && entry.detail == nil && entry.hasStill && !entry.candidate,
                "unexplained, with its picture; nothing unusual about it, so no candidate (Task 11)")
        #expect(entry.priority == .low && entry.reasons == ["Nothing unusual about it"] && !entry.doubtful, "\(String(describing: entry.priority)) \(entry.reasons)")
        #expect(entry.path.allSatisfy { $0.x > 0.5 }, "the right lens")
        // The still is the one asked for the track's middle, and it is beside the log.
        let asked = try #require(rig.stillsAsked.value.first)
        let middle = entry.start.addingTimeInterval(entry.end.timeIntervalSince(entry.start) / 2)
        #expect(abs(asked.timeIntervalSince(middle)) < 0.01, "the middle of the track: \(asked.timeIntervalSince(middle)) s off")
        let still = rig.log.still(camera: SkyDetectorRig.camera, night: rig.night(entry.start), entryID: entry.id, folder: rig.recordings.url)
        #expect(still == SkyLogStoreTests.jpeg("still"))
        #expect(SkyEntry.isValidID(entry.id))
        await rig.detector.stop()
    }

    @Test func matchesImproveTheAim() async throws {
        // A single-lens camera whose card is right: twelve planes, each its own pass, make the aim good, and it is there after a restart.
        let card = SkyDetectorSettings(enabled: true, facing: 315, tilt: 25)
        let model = SkyCameraModel.initial(facing: 315, tilt: 25, pictureWidth: 1920, pictureHeight: 1080)
        let rig = try SkyDetectorRig(settings: card, pictureWidth: 1920, pictureHeight: 1080)
        defer { rig.remove() }
        await rig.detector.start()
        #expect(await rig.detector.status.aim.quality == .rough)
        var random = SkyRandom(seed: 12)
        var labels: [SkyLabel] = []
        for index in 0..<12 {
            let pass = Self.pass(index, at: Self.start.addingTimeInterval(Double(index) * 60), seenBy: model, using: &random)
            await rig.flights.add(pass.reports)
            rig.clock.set(pass.track.samples.last?.wallClock ?? Self.start)
            let measures = TrackMeasurer.measure(pass.track, model: model, analysisWidth: 1920, pictureWidth: 1920)
            let entry = await rig.detector.classify(pass.track, measures: measures)
            #expect(entry.by == .flight && entry.detail?.hasPrefix("TEST456") == true, "pass \(index): \(entry.label)")
            labels.append(entry.label)
        }
        let status = await rig.detector.status
        #expect(status.aim.quality == .good && status.aim.planes == 12, "\(status.aim)")
        #expect(labels.first == .probablePlane && labels.last == .plane, "probable planes until the aim is good: \(labels)")
        let planes = labels.filter { $0 == .plane }.count
        #expect(status.learning == SkyLearning(ready: false, planes: planes, satellites: 0), "the planes matched with a good aim count")
        await rig.detector.stop()

        // A restart: the aim and the learning are where they were.
        let again = rig.again()
        await again.start()
        let restarted = await again.status
        #expect(restarted.aim.quality == .good && restarted.aim.planes == 12 && restarted.learning.planes == planes)
        await again.stop()
    }

    @Test func aGapEndsOpenTracksWithoutEntries() async throws {
        // A light followed for 4 s, then a gap: the track it was ends, and nothing is logged; nor is the gap itself. It goes at 2°/s, so that in
        // its 4 s it gets well past the 12 analysed pixels a light must reach to be kept (`SkyLightFilter.wandersInPlace`), wherever the card
        // puts it (at the stray's 1°/s it got 12.4 px through the card as it was until the 2026-10-25 beta, 12.1 through the level lenses).
        let quick = SkyPath(start: Self.stray.start, bearing: Self.stray.bearing, legs: [SkyPath.Leg(duration: 8, speed: 2)])
        var scene = SkyScene(model: Self.dualModel, start: Self.start)
        scene.lights = [{ date in
            let into = date.timeIntervalSince(Self.start)
            return into >= 1 && into <= 5 ? quick.direction(at: into - 1) : nil
        }]
        let gapped = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { gapped.remove() }
        await gapped.detector.start()
        await gapped.play(scene, 0..<50, gapAfter: 25)
        #expect(await gapped.logged().entries.isEmpty)
        await gapped.detector.stop()

        // The same light without the gap is logged.
        let control = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { control.remove() }
        await control.detector.start()
        await control.play(scene, 0..<50)
        #expect(await control.logged().entries.count == 1)
        await control.detector.stop()
    }

    @Test func aBrightnessJumpEndsTracksAndStartsNoneFor3Seconds() async throws {
        // The camera's own picture jumps (the IR-cut filter) while a light crosses: what was open is dropped, and nothing new is followed for
        // 3 s (the analyzer's own pause is 2 s); the light after that is.
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        var scene = SkyScene(model: Self.dualModel, start: Self.start)
        let long = SkyPath(start: SkyDirection(azimuth: 5, elevation: 35), bearing: Double.pi / 2, legs: [SkyPath.Leg(duration: 19, speed: 1.2)])
        scene.lights = [scene.along(long, from: 1)]
        scene.brightenFrom = 30   // 6 s
        await rig.play(scene, 0..<115)
        let entries = await rig.logged().entries
        #expect(entries.count == 1, "\(entries.map { $0.start.timeIntervalSince(Self.start) })")
        let after = try #require(entries.first)
        #expect(after.start.timeIntervalSince(Self.start) >= 9, "no track begins within 3 s of the jump: \(after.start.timeIntervalSince(Self.start))")
        #expect(after.start.timeIntervalSince(Self.start) < 10.5, "and the light is followed again after them")
        await rig.detector.stop()
    }

    // MARK: The status

    @Test func statusSaysWhichStreamAndHowFast() async throws {
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        let before = await rig.detector.status
        #expect(!before.running && before.stream == nil && before.analysisWidth == nil && before.picturesPerSecond == nil && before.decoding == nil)
        #expect(before.problem == nil && before.aim.quality == .rough && before.learning == SkyLearning(ready: false, planes: 0, satellites: 0))
        let flat = GrayImage(width: 1920, height: 852, pixels: [UInt8](repeating: 30, count: 1920 * 852))
        for index in 0..<12 {
            let wallClock = Self.start.addingTimeInterval(Double(index) * 0.2)
            await rig.detector.frame(SkyFrame(image: flat, time: 50 + Double(index) * 0.2, wallClock: wallClock, clockOffset: 0, pictureWidth: 4256,
                                              pictureHeight: 1888, stream: .main, decoding: .software))
        }
        let status = await rig.detector.status
        #expect(status.running && status.stream == "main" && status.analysisWidth == 1920 && status.decoding == "software")
        #expect(status.picturesPerSecond == 5, "\(status.picturesPerSecond ?? -1)")
        // A gap: how fast is counted afresh.
        await rig.detector.gap(at: Self.start.addingTimeInterval(3), reason: "no picture for 5 s")
        #expect(await rig.detector.status.picturesPerSecond == nil)
        await rig.detector.stop()
    }

    // MARK: The conditions

    @Test func conditionsAreRecordedOnChange() {
        #expect(SkyConditionsRecorder.state(nil) == .unknown && SkyConditionsRecorder.state(0.6) == .clear && SkyConditionsRecorder.state(1) == .clear)
        #expect(SkyConditionsRecorder.state(0.59) == .cloudy && SkyConditionsRecorder.state(0.3) == .cloudy && SkyConditionsRecorder.state(0.29) == .notVisible)
        // 0.8 for an hour, 0.1 for an hour, 0.8 again: clear, sky not visible, clear (the last once its hour is up).
        var recorder = SkyConditionsRecorder()
        var spans: [SkyConditions] = []
        for minute in 0...180 {
            let visibility = minute < 60 ? 0.8 : minute < 120 ? 0.1 : 0.8
            if let span = recorder.note(visibility, at: Self.start.addingTimeInterval(Double(minute) * 60)) { spans.append(span) }
        }
        #expect(spans.map(\.state) == [.clear, .notVisible, .clear])
        #expect(spans.map { $0.from.timeIntervalSince(Self.start) } == [0, 3_600, 7_200] && spans.map { $0.to.timeIntervalSince(Self.start) } == [3_600, 7_200, 10_800])
        #expect(spans.allSatisfy { $0.cloudCover == nil })
        // Nothing for longer than 5 minutes (the camera was away): the span ends at the last look, and a new one begins.
        var paused = SkyConditionsRecorder()
        #expect(paused.note(0.8, at: Self.start) == nil && paused.note(0.8, at: Self.start.addingTimeInterval(60)) == nil)
        let cut = paused.note(0.8, at: Self.start.addingTimeInterval(1_260))
        #expect(cut == SkyConditions(from: Self.start, to: Self.start.addingTimeInterval(60), state: .clear))
        #expect(paused.close() == SkyConditions(from: Self.start.addingTimeInterval(1_260), to: Self.start.addingTimeInterval(1_260), state: .clear))
        #expect(paused.close() == nil)
    }

    @Test func theConditionsReachTheLog() async throws {
        // A picture a minute for 70 minutes: the sky's state (unknown: no clear nights have been seen yet) is written once its hour is up.
        let rig = try SkyDetectorRig(settings: Self.dualCard, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        let flat = GrayImage(width: 640, height: 284, pixels: [UInt8](repeating: 30, count: 640 * 284))
        for minute in 0..<70 {
            let wallClock = Self.start.addingTimeInterval(Double(minute) * 60)
            rig.clock.set(wallClock)
            await rig.detector.frame(SkyFrame(image: flat, time: 10 + Double(minute) * 0.2, wallClock: wallClock, pictureWidth: 4256, pictureHeight: 1888))
        }
        let conditions = await rig.logged().conditions
        #expect(conditions == [SkyConditions(from: Self.start, to: Self.start.addingTimeInterval(3_600), state: .unknown)], "\(conditions)")
        await rig.detector.stop()
        // Stopping writes what was open.
        let closed = await rig.logged().conditions
        #expect(closed.count == 2 && closed.last?.from == Self.start.addingTimeInterval(3_600) && closed.last?.to == Self.start.addingTimeInterval(69 * 60))
    }

    // MARK: An aim far off (Ruling S18)

    @Test func planesInViewThatMatchNothingForTwoHoursSaySo() async throws {
        let card = SkyDetectorSettings(enabled: true, facing: 330, tilt: 20)
        let model = SkyCameraModel.initial(facing: 330, tilt: 20, pictureWidth: 1920, pictureHeight: 1080)
        let rig = try SkyDetectorRig(settings: card, pictureWidth: 1920, pictureHeight: 1080)
        defer { rig.remove() }
        await rig.detector.start()
        var random = SkyRandom(seed: 3)
        // Every 15 minutes a plane crosses the view, and a light the camera follows goes straight up: no card makes it the plane.
        for index in 0..<8 {
            let at = Self.start.addingTimeInterval(Double(index) * 900)
            let pass = Self.pass(index, at: at, seenBy: model, using: &random)
            await rig.flights.add(pass.reports)
            let climbing = SkyPath(start: SkyDirection(azimuth: 300 + Double(index) * 5, elevation: 15), bearing: 0, legs: [SkyPath.Leg(duration: 10, speed: 1)])
            let track = Self.track(along: climbing, at: at, seenBy: model, using: &random)
            rig.clock.set(at.addingTimeInterval(10))
            let entry = await rig.detector.classify(track, measures: TrackMeasurer.measure(track, model: model, analysisWidth: 1920, pictureWidth: 1920))
            #expect(entry.by != .flight, "no plane explains it")
            await rig.detector.tick(at: at.addingTimeInterval(8))
            #expect(await rig.detector.status.aim.note == nil, "not before two hours: \(index)")
        }
        let later = Self.start.addingTimeInterval(7_260)
        rig.clock.set(later)
        await rig.detector.tick(at: later)
        let status = await rig.detector.status
        #expect(status.aim.note == SkyMatchWatch.note && status.aim.note == "Planes are flying through the view but none match: check which way the camera faces")
        #expect(status.aim.quality == .rough, "no card explains these lights: the search adopted nothing")

        // A plane that matches clears it.
        let at = later.addingTimeInterval(60)
        let pass = Self.pass(9, at: at, seenBy: model, using: &random)
        await rig.flights.add(pass.reports)
        rig.clock.set(at.addingTimeInterval(16))
        let entry = await rig.detector.classify(pass.track, measures: TrackMeasurer.measure(pass.track, model: model, analysisWidth: 1920, pictureWidth: 1920))
        #expect(entry.label == .probablePlane)
        #expect(await rig.detector.status.aim.note == nil)
        await rig.detector.stop()
    }

    @Test func theWideSearchFindsACardFarOffAndOnlyAClearOne() throws {
        // The camera really faces 30° further right and 10° higher than its card says.
        let truth = SkyCameraModel.initial(facing: 0, tilt: 30, pictureWidth: 1920, pictureHeight: 1080)
        var random = SkyRandom(seed: 5)
        let records = try (0..<8).map { index in
            let pass = Self.pass(index, at: Self.start.addingTimeInterval(Double(index) * 600), seenBy: truth, using: &random)
            return try #require(SkyAimSearch.record(of: pass.track, analysisWidth: 1920, pictureWidth: 1920, flights: Self.history(pass.reports),
                                                    observer: Self.observer))
        }
        #expect(records.allSatisfy { $0.track.samples.count <= SkyAimSearch.samplesPerRecord && $0.flights.count == 1 })
        let card = SkyAimSearch.Card(facing: 330, tilt: 20)
        let found = try #require(SkyAimSearch.search(records, from: card, layout: nil, pictureWidth: 1920, pictureHeight: 1080, observer: Self.observer))
        #expect(found.card == SkyAimSearch.Card(facing: 0, tilt: 30), "\(found)")
        #expect(found.aircraft == 8 && found.aircraft >= 2 * found.runnerUp, "\(found)")
        #expect(SkyAimSearch.cards(around: card).count == 7 * 6, "facing ±45° in 15° steps; tilt ±30° in 10° steps, kept within 0…90°")
        // Too few aircraft is no winner; nor is the card the camera already has.
        #expect(SkyAimSearch.search(Array(records.prefix(4)), from: card, layout: nil, pictureWidth: 1920, pictureHeight: 1080, observer: Self.observer) == nil)
        #expect(SkyAimSearch.search(records, from: SkyAimSearch.Card(facing: 0, tilt: 30), layout: nil, pictureWidth: 1920, pictureHeight: 1080,
                                    observer: Self.observer) == nil)
        // The note says how the card is off, in words a person can act on.
        #expect(SkyAimSearch.note(facing: 30, tilt: 10) == "The planes fit the camera facing about 30° further right and tilted 10° higher than set: it aims from there now.")
        #expect(SkyAimSearch.note(facing: -45, tilt: 0) == "The planes fit the camera facing about 45° further left than set: it aims from there now.")
        #expect(SkyAimSearch.note(facing: 0, tilt: -20) == "The planes fit the camera tilted 20° lower than set: it aims from there now.")
    }

    @Test func theWideSearchAimsFromTheCardThePlanesFit() async throws {
        let card = SkyDetectorSettings(enabled: true, facing: 330, tilt: 20)
        let model = SkyCameraModel.initial(facing: 330, tilt: 20, pictureWidth: 1920, pictureHeight: 1080)
        let truth = SkyCameraModel.initial(facing: 0, tilt: 30, pictureWidth: 1920, pictureHeight: 1080)
        let rig = try SkyDetectorRig(settings: card, pictureWidth: 1920, pictureHeight: 1080)
        defer { rig.remove() }
        await rig.detector.start()
        var random = SkyRandom(seed: 9)
        for index in 0..<8 {
            let at = Self.start.addingTimeInterval(Double(index) * 900)
            let pass = Self.pass(index, at: at, seenBy: truth, using: &random)
            await rig.flights.add(pass.reports)
            rig.clock.set(at.addingTimeInterval(16))
            let entry = await rig.detector.classify(pass.track, measures: TrackMeasurer.measure(pass.track, model: model, analysisWidth: 1920, pictureWidth: 1920))
            #expect(entry.by != .flight, "the card is 30° off: no match")
            await rig.detector.tick(at: at.addingTimeInterval(8))
        }
        let later = Self.start.addingTimeInterval(7_260)
        rig.clock.set(later)
        await rig.detector.tick(at: later)
        let status = await rig.detector.status
        #expect(status.aim.note == "The planes fit the camera facing about 30° further right and tilted 10° higher than set: it aims from there now.",
                "\(status.aim.note ?? "no note")")
        // The next plane matches through the card the search found.
        let at = later.addingTimeInterval(60)
        let pass = Self.pass(8, at: at, seenBy: truth, using: &random)
        await rig.flights.add(pass.reports)
        rig.clock.set(at.addingTimeInterval(16))
        let entry = await rig.detector.classify(pass.track, measures: TrackMeasurer.measure(pass.track, model: truth, analysisWidth: 1920, pictureWidth: 1920))
        #expect(entry.label == .probablePlane && entry.by == .flight)
        await rig.detector.stop()

        // The card it found outlives a restart…
        let again = rig.again()
        await again.start()
        let pass2 = Self.pass(9, at: at.addingTimeInterval(120), seenBy: truth, using: &random)
        await rig.flights.add(pass2.reports)
        rig.clock.set(at.addingTimeInterval(136))
        #expect(await again.classify(pass2.track, measures: TrackMeasurer.measure(pass2.track, model: truth, analysisWidth: 1920, pictureWidth: 1920)).label
                == .probablePlane)
        // …and a new card from the person replaces it: facing east, these planes are no match.
        var east = card
        east.facing = 90
        await again.update(east)
        await again.settle()
        let pass3 = Self.pass(10, at: at.addingTimeInterval(240), seenBy: truth, using: &random)
        await rig.flights.add(pass3.reports)
        rig.clock.set(at.addingTimeInterval(256))
        #expect(await again.classify(pass3.track, measures: TrackMeasurer.measure(pass3.track, model: truth, analysisWidth: 1920, pictureWidth: 1920)).by
                != .flight)
        await again.stop()
    }

    // MARK: Helpers

    /// One plane's pass of 15 s seen through `model`: its reports (one a second, `TEST456` at 3 km, hex c0ff0N) and the track of its light
    /// (five pictures a second, each direction off by up to 0.05°). The passes cross the view at different places: four across, three up.
    static func pass(_ index: Int, at start: Date, seenBy model: SkyCameraModel, using random: inout SkyRandom) -> (track: SkyTrack, reports: [AircraftReport]) {
        let facing = model.lenses[0].yaw, tilt = model.lenses[0].pitch
        let across = [-35.0, -15, 5, 25][index % 4], up = [-12.0, 2, 14][(index / 4) % 3]
        let east = index % 4 < 2
        let path = SkyPath(start: SkyDirection(azimuth: SkyMath.normalizedDegrees(facing + across), elevation: tilt + up),
                           bearing: east ? Double.pi / 2 : -Double.pi / 2, legs: [SkyPath.Leg(duration: 15, speed: 0.8)])
        let reports = SkyFixtures.reports(along: path, beginningAt: start, altitudeMeters: 3_000, from: start.addingTimeInterval(-2),
                                          to: start.addingTimeInterval(17), hex: String(format: "c0ff%02x", index))
        return (track(along: path, at: start, seenBy: model, using: &random), reports)
    }

    /// The track of a light along `path` from `start`, five pictures a second, seen through `model`.
    static func track(along path: SkyPath, at start: Date, seenBy model: SkyCameraModel, using random: inout SkyRandom) -> SkyTrack {
        var samples: [SkyTrackSample] = []
        for (time, direction) in path.directions() {
            let wallClock = start.addingTimeInterval(time)
            if let sample = SkyFixtures.sample(at: wallClock, since: start, direction: SkyFixtures.noisy(direction, upTo: 0.05, using: &random),
                                               through: model) {
                samples.append(sample)
            }
        }
        return SkyTrack(id: UUID(), samples: samples, streakBorn: false)
    }

    static func history(_ reports: [AircraftReport]) -> [String: [AircraftReport]] {
        Dictionary(grouping: reports, by: \.hex)
    }
}
