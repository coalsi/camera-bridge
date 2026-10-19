import BridgeEngine
import Foundation
import MediaCore
import Synchronization
import TestSupport
import Testing
@testable import BridgeWeb

/// How many clip conversions run at once on the box (at most two, box-wide: a third waits for a place), and at what priority (ffmpeg under
/// `nice -n 10` on Linux, where the live transcoders share the same four cores).
@Suite struct ClipConversionTests {
    // MARK: The places

    /// A conversion that has been given its place and waits to be told to end.
    private final class Held: Sendable {
        let started = Mutex(false)
        let ended = Mutex(false)
        private let release: AsyncStream<Void>.Continuation
        private let signal: AsyncStream<Void>

        init() { (signal, release) = AsyncStream<Void>.makeStream() }
        func finish() { release.yield() }
        func wait() async { for await _ in signal { return } }
    }

    private func start(_ places: ConversionSlots, _ held: Held) -> Task<Void, any Error> {
        Task {
            try await places.run {
                held.started.withLock { $0 = true }
                await held.wait()
            }
            held.ended.withLock { $0 = true }
        }
    }

    @Test(.timeLimit(.minutes(1))) func atMostTwoConversionsRunAndTheThirdWaitsForAPlace() async throws {
        #expect(WebApp.maximumClipConversions == 2)
        let places = ConversionSlots(limit: WebApp.maximumClipConversions)
        let (first, second, third) = (Held(), Held(), Held())
        let tasks = [start(places, first), start(places, second)]
        #expect(await eventually { first.started.withLock { $0 } && second.started.withLock { $0 } })
        let late = start(places, third)
        #expect(await eventually { places.waiting == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(places.running == 2 && places.waiting == 1 && !third.started.withLock { $0 }, "the third waits: \(places.running) running")

        // A place is free once one ends; the third takes it, and never more than two ran at once.
        first.finish()
        try await tasks[0].value
        #expect(await eventually { third.started.withLock { $0 } })
        #expect(places.running == 2 && places.waiting == 0)
        second.finish()
        third.finish()
        try await tasks[1].value
        try await late.value
        #expect(places.running == 0 && places.waiting == 0)
        #expect(places.mostRunning == 2, "\(places.mostRunning) ran at once")
    }

    @Test(.timeLimit(.minutes(1))) func waitingConversionsTakeTheirPlacesInTheOrderTheyAsked() async throws {
        let places = ConversionSlots(limit: 1)
        let order = Mutex<[Int]>([])
        let first = Held()
        let holder = start(places, first)
        #expect(await eventually { first.started.withLock { $0 } })
        var waiting: [Task<Void, any Error>] = []
        for index in 1...3 {
            waiting.append(Task { try await places.run { order.withLock { $0.append(index) } } })
            #expect(await eventually { places.waiting == index })
        }
        first.finish()
        try await holder.value
        for task in waiting { try await task.value }
        #expect(order.withLock { $0 } == [1, 2, 3])
    }

    @Test(.timeLimit(.minutes(1))) func aConversionWhoseBrowserLeftWhileItWaitedLeavesTheQueueAndTakesNoPlace() async throws {
        let places = ConversionSlots(limit: 1)
        let held = Held()
        let holder = start(places, held)
        #expect(await eventually { held.started.withLock { $0 } })
        let ran = Mutex(false)
        let leaving = Task { try await places.run { ran.withLock { $0 = true } } }
        #expect(await eventually { places.waiting == 1 })
        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }
        #expect(places.waiting == 0 && places.running == 1 && !ran.withLock { $0 })
        // The place it never had is not lost or given twice: the next conversion gets the one the holder frees.
        held.finish()
        try await holder.value
        #expect(places.running == 0)
        try await places.run { #expect(places.running == 1) }
        #expect(places.running == 0)
    }

    @Test func aConversionThatFailsGivesItsPlaceBack() async throws {
        let places = ConversionSlots(limit: 1)
        struct Failure: Error {}
        await #expect(throws: Failure.self) { try await places.run { throw Failure() } }
        #expect(places.running == 0)
        // A task cancelled before it asked never takes one.
        let ran = Mutex(false)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await places.run { ran.withLock { $0 = true } }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(places.running == 0 && places.waiting == 0 && !ran.withLock { $0 })
    }

    // MARK: Priority

    @Test func ffmpegIsNicedOnLinuxOnly() {
        #if os(Linux)
        #expect(WebApp.conversionNiceness == 10)
        #else
        #expect(WebApp.conversionNiceness == nil)
        #endif
        let plain = WebApp.conversionCommand(ffmpeg: "/usr/bin/ffmpeg", arguments: ["-i", "in.mp4"], niceness: nil)
        #expect(plain.executable == "/usr/bin/ffmpeg" && plain.arguments == ["-i", "in.mp4"])
        let niced = WebApp.conversionCommand(ffmpeg: "/usr/bin/ffmpeg", arguments: ["-i", "in.mp4"], niceness: 10, nice: "/usr/bin/nice")
        #expect(niced.executable == "/usr/bin/nice" && niced.arguments == ["-n", "10", "/usr/bin/ffmpeg", "-i", "in.mp4"])
        // No nice program on this system: ffmpeg as it is, rather than no clip.
        let missing = WebApp.conversionCommand(ffmpeg: "/usr/bin/ffmpeg", arguments: ["-i", "in.mp4"], niceness: 10, nice: "/nonexistent/nice")
        #expect(missing.executable == "/usr/bin/ffmpeg" && missing.arguments == ["-i", "in.mp4"])
    }

    /// What a child run as `conversionCommand` says its niceness is (a shell that prints its own, in place of ffmpeg).
    private func niceness(_ requested: Int?) async throws -> Int? {
        #if os(Linux)
        let script = "cut -d' ' -f19 /proc/$$/stat"     // the 19th field of /proc/<pid>/stat is the niceness
        #else
        let script = "ps -o nice= -p $$"
        #endif
        let command = WebApp.conversionCommand(ffmpeg: "/bin/sh", arguments: ["-c", script], niceness: requested)
        let collected = Box(Data())
        try await WebApp.runStreaming(executable: command.executable, arguments: command.arguments, timeZone: "UTC",
                                      into: ResponseStream { data in collected.update { $0.append(data) } })
        return Int(String(decoding: collected.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test(.timeLimit(.minutes(1))) func theChildRunsAtTheNicenessAskedFor() async throws {
        let normal = try #require(try await niceness(nil))
        let low = try #require(try await niceness(10))
        #expect(low == normal + 10, "\(normal) as it is, \(low) niced")
    }

    // MARK: The route

    private func rig() async throws -> NVRRig {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file(fragments: 8, gopFragments: 2)]
        rig.backend.write {
            $0.configurations[0].name = "Cap"
            $0.configurations[0].pictureCorrection = PictureCorrection(straighten: 0.4, level: 0.15)
        }
        return rig
    }

    @Test(.timeLimit(.minutes(1))) func aThirdSavedClipWaitsForAPlaceAndLeavesWhenItsBrowserDoes() async throws {
        guard WebApp.ffmpegPath() != nil else { return }   // no converter on this machine: the route answers 501 before it waits
        let rig = try await rig()
        let app = rig.harness.app
        // Two conversions are running (the test holds their places).
        try await app.archiveState.conversions.acquire()
        try await app.archiveState.conversions.acquire()
        let response = await rig.harness.raw("GET", "/api/v1/nvr/cameras/\(rig.cameraID)/clip?from=\(rig.ms(1_500))&to=\(rig.ms(6_000))&tz=UTC&part=1&straighten=1",
                                             cookie: rig.session.cookie)
        guard case .stream(let body) = response.body else {
            Issue.record("a stream was expected, not \(response.status)")
            return
        }
        #expect(response.status == 200 && app.archiveSlotsInUse == 1, "the archive slot is held from the request on")
        let collected = Box(Data())
        let download = Task { try await body(ResponseStream { data in collected.update { $0.append(data) } }) }
        #expect(await eventually { app.archiveState.conversions.waiting == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(app.archiveState.conversions.running == 2 && app.archiveState.conversions.waiting == 1 && collected.value.isEmpty,
                "it sent nothing and started no third conversion")
        // The browser goes away: the download leaves the queue and gives its archive slot back.
        download.cancel()
        _ = try? await download.value
        #expect(app.archiveState.conversions.waiting == 0 && app.archiveState.conversions.running == 2)
        #expect(await eventually { app.archiveSlotsInUse == 0 })

        // Another is asked for; a place frees; it converts (the fixture's pictures are not real H.264, so ffmpeg ends the stream with an error).
        let second = await rig.harness.raw("GET", "/api/v1/nvr/cameras/\(rig.cameraID)/clip?from=\(rig.ms(1_500))&to=\(rig.ms(6_000))&tz=UTC&part=1&straighten=1",
                                           cookie: rig.session.cookie)
        guard case .stream(let secondBody) = second.body else {
            Issue.record("a stream was expected, not \(second.status)")
            return
        }
        let again = Task { try await secondBody(ResponseStream { _ in }) }
        #expect(await eventually { app.archiveState.conversions.waiting == 1 })
        app.archiveState.conversions.release()
        _ = try? await again.value
        #expect(app.archiveState.conversions.waiting == 0 && app.archiveState.conversions.running == 1, "it took the place that was freed and gave it back")
        #expect(await eventually { app.archiveSlotsInUse == 0 })
        app.archiveState.conversions.release()
        #expect(app.archiveState.conversions.running == 0)
    }
}
