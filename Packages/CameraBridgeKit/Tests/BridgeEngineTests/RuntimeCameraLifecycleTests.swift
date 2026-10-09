#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import HAP
import HAPCamera
import MediaCore
import PlatformApple
import Synchronization
import Testing
import TestSupport
@testable import BridgeEngine

/// A driver whose event source the test drives; counts the event sources made and stopped.
final class ScriptedEventDriver: CameraDriver {
    final class Source: CameraEventSource {
        let stream: AsyncStream<CameraEvent>
        let continuation: AsyncStream<CameraEvent>.Continuation
        let stopped: Box<Int>

        init(stopped: Box<Int>) {
            (stream, continuation) = AsyncStream.makeStream(of: CameraEvent.self)
            self.stopped = stopped
        }

        func events() -> AsyncStream<CameraEvent> { stream }

        func stop() async {
            stopped.update { $0 += 1 }
            continuation.finish()
        }
    }

    let vendor: CameraVendor = .demo
    let sourcesMade = Box(0)
    let sourcesStopped = Box(0)
    private let current = Mutex<Source?>(nil)

    func emit(_ event: CameraEvent) {
        current.withLock { $0 }?.continuation.yield(event)
    }

    func probe() async throws -> CameraProbeResult { throw CameraAdapterError.unsupported("scripted driver") }

    func makeEventSource() -> (any CameraEventSource)? {
        sourcesMade.update { $0 += 1 }
        let source = Source(stopped: sourcesStopped)
        current.withLock { $0 = source }
        return source
    }

    func snapshot() async throws -> Data? { nil }
    func makeTalkbackSink() -> (any TalkbackSink)? { nil }
}

/// Records the names of every advertisement and advertises nothing (never touches DNS-SD: nothing reaches the LAN).
final class CountingAdvertiser: ServiceAdvertiser {
    let names = Box<[String]>([])

    func advertise(_ advertisement: ServiceAdvertisement) async throws -> any AdvertisedService {
        names.update { $0.append(advertisement.name) }
        return try await NullServiceAdvertiser().advertise(advertisement)
    }

    func count(_ name: String) -> Int { names.value.filter { $0 == name }.count }
}

/// Opens once; every `wait()` before and after returns then.
final class Gate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
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

/// Camera runtimes across restarts, pairing, on-demand sub streams, driver events, wake and network changes, and stops
/// that race other work (plan W3-1 items 1, 2, 6 and 7; review findings on the first W3-1 implementation).
@Suite(.serialized) struct RuntimeCameraLifecycleTests {
    static func rtspCamera(_ name: String, server: RTSPTestServer) -> CameraConfiguration {
        var camera = CameraConfiguration(name: name, kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "127.0.0.1", rtspPort: Int(server.port)),
                                         username: "")
        camera.mainStreamURL = server.url
        camera.motionSource = .webhook
        return camera
    }

    static func fourByThreeServer() async throws -> RTSPTestServer {
        let server = RTSPTestServer(source: syntheticSource(width: 640, height: 480, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        try await server.start()
        return server
    }

    /// Live and recording resolutions of the paired camera accessory.
    static func options(_ controller: HAPTestController, _ ids: CameraAccessoryIDs) async throws
        -> (live: [ControllerTLV.Resolution], recording: [ControllerTLV.Resolution]) {
        let live = try await controller.supportedStreamingConfiguration(ids.streams[0]).video.codecs.first?.resolutions ?? []
        let recording = try await controller.supportedRecordingConfiguration(try #require(ids.recording)).video.codecs.first?.resolutions ?? []
        return (live, recording)
    }

    /// Review finding: after a restart the accessory was built before the stream delivered a picture, and the live
    /// options fell back to 16:9 up to 1080p (4:3 and 4K sizes disappeared on every launch after the first).
    @MainActor @Test(.timeLimit(.minutes(2))) func liveOptionsFollowTheSourceOnEveryStart() async throws {
        let server = try await Self.fourByThreeServer()
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let camera = Self.rtspCamera("Porch", server: server)
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        let status = try #require(fixture.status(camera.id))
        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        let ids = try await controller.cameraIDs()
        let first = try await Self.options(controller, ids)
        #expect(first.live == [ControllerTLV.Resolution(1600, 1200, 30), ControllerTLV.Resolution(1920, 1080, 30), ControllerTLV.Resolution(1280, 960, 30),
                               ControllerTLV.Resolution(1280, 720, 30), ControllerTLV.Resolution(1024, 768, 30), ControllerTLV.Resolution(960, 540, 30),
                               ControllerTLV.Resolution(640, 480, 30), ControllerTLV.Resolution(640, 360, 30), ControllerTLV.Resolution(320, 240, 15)])
        #expect(first.recording.contains(ControllerTLV.Resolution(1280, 960, 30)) && first.recording.contains(ControllerTLV.Resolution(1600, 1200, 30)))
        await controller.close()
        await engine.stop()

        // At the next launch the camera is unreachable: the accessory still offers the source's sizes, without waiting.
        await server.stop()
        let started = ContinuousClock.now
        await engine.start()
        #expect(ContinuousClock.now - started < EngineTuning.testing.aspectWait, "a remembered picture size needs no wait")
        let again = try await controller.reconnect()
        try await again.pairVerify()
        let second = try await Self.options(again, ids)
        #expect(second.live == first.live)
        #expect(second.recording == first.recording)
        await again.close()
        await fixture.tearDown()
    }

    /// Review finding: options published without a picture were never frozen, so a pairing made with them could see
    /// them change at a later start (the hub's recording selection is then dropped).
    @MainActor @Test(.timeLimit(.minutes(2))) func recordingOptionsFreezeOnceAControllerPairsEvenWithoutAPicture() async throws {
        // The 3 s picture wait lets the restart below see the 4:3 picture before the accessory is built.
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        var camera = CameraConfiguration(name: "Shed", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "127.0.0.1", rtspPort: 1), username: "")
        camera.mainStreamURL = URL(string: "rtsp://127.0.0.1:1/unreachable")
        camera.motionSource = .webhook
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        let store = HAPStorage.store(for: camera.id, dataDirectory: fixture.directory.url, secrets: fixture.environment.platform.secrets)
        #expect(try AccessoryOptions.frozenAspect(in: store) == nil, "no picture and nobody paired: nothing is frozen yet")
        let status = try #require(fixture.status(camera.id))
        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        let ids = try await controller.cameraIDs()
        let before = try await Self.options(controller, ids)
        #expect(before.recording == [ControllerTLV.Resolution(1280, 720, 30), ControllerTLV.Resolution(1920, 1080, 30)])
        #expect(await fixture.waitFor(.seconds(5)) { (try? AccessoryOptions.frozenAspect(in: store)) == .wide }, "pairing freezes what was advertised")
        await controller.close()
        await engine.stop()

        // The camera now delivers a 4:3 picture: the paired recording options stay; the picture size is remembered.
        let server = try await Self.fourByThreeServer()
        var updated = try #require(engine.configurations.first)
        updated.endpoint.rtspPort = Int(server.port)
        updated.mainStreamURL = server.url
        try await engine.updateCamera(updated, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let again = try await controller.reconnect()
        try await again.pairVerify()
        let after = try await Self.options(again, ids)
        #expect(after.recording == before.recording)
        #expect(after.live.contains(ControllerTLV.Resolution(640, 480, 30)), "live options follow the 4:3 picture")
        #expect(await fixture.waitFor { AccessoryOptions.sourceSize(in: store) == AccessoryOptions.SourceSize(width: 640, height: 480) })
        await again.close()
        await fixture.tearDown()
        await server.stop()
    }

    /// Review finding (W4 round 4): a camera slower than the Mac after a power cut has its accessory published before its
    /// first picture; the runtime then remembers the picture size once it comes (`watchFormat`), so the next start offers
    /// live options that fit the camera. No test reached that path: a 4:3 camera late at its first start would have kept
    /// advertising 16:9 live sizes at every later start, and every suite passed without the remembering.
    @MainActor @Test(.timeLimit(.minutes(1))) func aPictureSizeLearnedAfterPublishingIsRememberedForTheNextStart() async throws {
        let server = try await Self.fourByThreeServer()
        let transport = ScriptedTransport()
        transport.connectFailures.set([server.port: .connectionRefused])   // the camera is still booting
        var tuning = EngineTuning.testing
        tuning.aspectWait = .milliseconds(300)
        tuning.ingest.initialBackoff = .milliseconds(200)
        tuning.ingest.maximumBackoff = .milliseconds(400)
        let fixture = try await EngineFixture(tuning: tuning, transport: transport)
        let engine = fixture.engine
        let camera = Self.rtspCamera("Shed", server: server)
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor {
            guard fixture.status(camera.id)?.hapPort != nil, case .offline = fixture.status(camera.id)?.connection else { return false }
            return true
        }, "published without a picture")
        let store = HAPStorage.store(for: camera.id, dataDirectory: fixture.directory.url, secrets: fixture.environment.platform.secrets)
        #expect(AccessoryOptions.sourceSize(in: store) == nil)

        // The camera comes up while the accessory runs: its size is remembered without a restart.
        transport.connectFailures.set([:])
        #expect(await fixture.waitFor(.seconds(10)) { AccessoryOptions.sourceSize(in: store) == AccessoryOptions.SourceSize(width: 640, height: 480) })
        #expect(await fixture.waitFor { engine.recentLogs.contains { $0.message.contains("delivers 640×480") } })

        // The next start offers live sizes that fit the 4:3 camera.
        await engine.stop()
        await engine.start()
        let status = try #require(fixture.status(camera.id))
        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        let ids = try await controller.cameraIDs()
        let options = try await Self.options(controller, ids)
        #expect(options.live.contains(ControllerTLV.Resolution(640, 480, 30)) && options.live.contains(ControllerTLV.Resolution(1280, 960, 30)),
                "\(options.live)")
        await controller.close()
        await fixture.tearDown()
        await server.stop()
    }

    /// Plan W3-1 item 1 at runtime level: the sub stream connects for small live views only, stops after the idle
    /// delay, keeps running for a user that arrives around that deadline (review finding: check-then-act race), and the
    /// main stream serves a view when the sub stream has no picture in time.
    @MainActor @Test(.timeLimit(.minutes(2))) func subStreamRunsOnDemandAndStopsWhenIdle() async throws {
        var tuning = EngineTuning.testing
        tuning.subStreamIdleStop = .milliseconds(500)
        tuning.subStreamStartWait = .milliseconds(1500)
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        try await server.start()
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        let demo = EngineFixture.demoCamera()
        var gate = Self.rtspCamera("Gate", server: server)
        gate.subStreamURL = URL(string: "rtsp://127.0.0.1:1/sub")   // never answers
        try await engine.addCamera(demo, password: nil)
        try await engine.addCamera(gate, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(demo.id)?.connection == .online && fixture.status(gate.id)?.connection == .online })

        let runtime = try #require(engine.runtimes[demo.id])
        #expect(!(await runtime.isSubStreamRunning), "connected only on demand")
        let main = await runtime.lease(preferSub: false)
        #expect(!main.isSubStream && main.hub === runtime.hub)
        #expect(!(await runtime.isSubStreamRunning))
        let sub = await runtime.lease(preferSub: true)
        #expect(sub.isSubStream)
        #expect(await sub.hub.videoFormat?.width == 320)
        await sub.release()
        #expect(await runtime.isSubStreamRunning, "kept for the idle delay")
        #expect(await fixture.until(.seconds(5)) { !(await runtime.isSubStreamRunning) })

        for offset in [-60, -20, 0, 20, 60] {
            let first = await runtime.lease(preferSub: true)
            #expect(first.isSubStream)
            await first.release()
            try await Task.sleep(for: tuning.subStreamIdleStop + .milliseconds(offset))
            let held = await runtime.lease(preferSub: true)
            #expect(held.isSubStream)
            try await Task.sleep(for: tuning.subStreamIdleStop + .milliseconds(300))
            #expect(await runtime.isSubStreamRunning, "a held sub stream stays connected (user arrived \(offset) ms around the idle stop)")
            await held.release()
        }

        let fallbackRuntime = try #require(engine.runtimes[gate.id])
        let started = ContinuousClock.now
        let fallback = await fallbackRuntime.lease(preferSub: true)
        #expect(!fallback.isSubStream && fallback.hub === fallbackRuntime.hub)
        // Refused at once: the view stops waiting as soon as the sub stream is offline (review W4 round 4).
        #expect(ContinuousClock.now - started < tuning.subStreamStartWait)
        #expect(await fixture.until(.seconds(5)) { !(await fallbackRuntime.isSubStreamRunning) }, "the unused sub stream is let go")
        await fixture.tearDown()
        await server.stop()
    }

    /// Review finding (W4 round 3): a live view on the sub stream (small tiles, remote viewers, the Watch) froze for the
    /// rest of the session when the sub stream alone went away (turned off on the camera, a connection limit): the hub
    /// waited for a keyframe that never came and the controller's RTCP kept the session alive, while the main stream was
    /// healthy. It ends through HAP once the sub stream stayed offline, and starts again on the main stream.
    @MainActor @Test(.timeLimit(.minutes(1))) func aLiveViewOnASubStreamThatGoesAwayRestartsOnTheMainStream() async throws {
        var tuning = EngineTuning.testing
        tuning.subStreamStartWait = .milliseconds(1_500)
        let main = RTSPTestServer(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        let sub = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        try await main.start()
        try await sub.start()
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        var camera = Self.rtspCamera("Porch", server: main)
        camera.subStreamURL = sub.url
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online && fixture.status(camera.id)?.hapPort != nil })
        let status = try #require(fixture.status(camera.id))
        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        let ids = try await controller.cameraIDs()
        let small = LiveStreamOptions(resolution: ControllerTLV.Resolution(320, 240, 15), maxBitrateKbps: 300)
        let live = try await controller.startLiveStream(ids.streams[0], options: small)
        #expect(await live.receiver.waitFor(timeout: .seconds(8)) { $0.keyframes >= 1 && $0.videoFrames >= 10 })
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(await runtime.isSubStreamRunning, "the small view reads the sub stream")

        await sub.stop()   // only the sub stream goes away
        #expect(await live.receiver.waitFor(timeout: .seconds(10)) { $0.byes >= 1 }, "the frozen live view ends")
        #expect(await fixture.waitFor(.seconds(5)) { fixture.status(camera.id)?.liveViewers == 0 })
        // Home starts it again: on the main stream at once.
        let again = try await controller.startLiveStream(ids.streams[0], options: small)
        #expect(await again.receiver.waitFor(timeout: .seconds(8)) { $0.keyframes >= 1 && $0.videoFrames >= 10 })
        try await again.stop()
        await controller.close()
        await fixture.tearDown()
        await main.stop()
    }

    /// Plan W3-1 item 6: the driver's event source reaches the controller; camera motion counts only when the camera's
    /// motion source is `.cameraEvents`; a doorbell press rings and pulses motion.
    @MainActor @Test(.timeLimit(.minutes(1))) func driverEventsReachTheControllerAndCameraMotionOnlyWhenChosen() async throws {
        let drivers = Box<[UUID: ScriptedEventDriver]>([:])
        var tuning = EngineTuning.testing
        tuning.driverFactory = { camera, _, _ in
            let fresh = ScriptedEventDriver()
            return drivers.update { map in
                if let existing = map[camera.id] { return existing }
                map[camera.id] = fresh
                return fresh
            }
        }
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        var door = EngineFixture.demoCamera(name: "Front Door", kind: .doorbell)
        door.motionSource = .webhook
        var yard = EngineFixture.demoCamera(name: "Yard")
        yard.motionSource = .cameraEvents
        try await engine.addCamera(door, password: nil)
        try await engine.addCamera(yard, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(door.id)?.hapPort != nil && fixture.status(yard.id)?.hapPort != nil })
        let doorDriver = try #require(drivers.value[door.id])
        let yardDriver = try #require(drivers.value[yard.id])
        #expect(doorDriver.sourcesMade.value == 1 && yardDriver.sourcesMade.value == 1)

        yardDriver.emit(.motion(true))
        #expect(await fixture.waitFor { fixture.status(yard.id)?.motionActive == true }, "camera motion counts for .cameraEvents")

        doorDriver.emit(.motion(true))
        doorDriver.emit(.eventChannel(connected: true))   // processed after the motion event
        #expect(await fixture.waitFor { fixture.status(door.id)?.eventChannelConnected == true })
        #expect(fixture.status(door.id)?.motionActive == false, "camera motion is ignored when the motion source is the webhook")

        let status = try #require(fixture.status(door.id))
        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        let ids = try await controller.cameraIDs()
        let ring = try #require(ids.programmableSwitchEvent)
        let motion = try #require(ids.motionDetected)
        try await controller.subscribe([ring, motion])
        doorDriver.emit(.doorbellPressed)
        #expect(try await controller.nextEvent(for: ring).value == .int(0))
        #expect(try await controller.nextEvent(for: motion).value.hapBool == true)
        await controller.close()
        await fixture.tearDown()
    }

    /// Plan W3-1 item 7: wake and network changes reconnect the ingest, restart the event channel and re-advertise;
    /// a camera stopped while a reconnect is under way stays stopped (review finding: the reconnect resurrected it).
    @MainActor @Test(.timeLimit(.minutes(1))) func wakeAndNetworkChangesReconnectIngestEventsAndAdvertising() async throws {
        let driver = ScriptedEventDriver()
        var tuning = EngineTuning.testing
        tuning.driverFactory = { _, _, _ in driver }
        let advertiser = CountingAdvertiser()
        let fixture = try await EngineFixture(tuning: tuning, advertiser: advertiser)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Lobby")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let runtime = try #require(engine.runtimes[camera.id])
        let attempts = await runtime.ingestAttempts.main ?? 0
        #expect(attempts >= 1 && driver.sourcesMade.value == 1)
        #expect(await fixture.until { advertiser.count("Lobby") == 1 })

        await engine.systemDidWake()
        #expect(await fixture.waitFor { engine.recentLogs.contains { $0.message.contains("woke up") } })
        #expect(await fixture.until { await (runtime.ingestAttempts.main ?? 0) > attempts }, "the ingest connected again")
        #expect(driver.sourcesMade.value == 2 && driver.sourcesStopped.value == 1, "the event channel restarted")
        #expect(await fixture.until { advertiser.count("Lobby") == 2 }, "advertised again")
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })

        let afterWake = await runtime.ingestAttempts.main ?? 0
        try await Task.sleep(for: .milliseconds(400))   // the reconnected stream is delivering video again
        fixture.networkChanges.fire()
        #expect(await fixture.waitFor(.seconds(10)) { engine.recentLogs.contains { $0.message.contains("network changed") } })
        #expect(await fixture.until { advertiser.count("Lobby") == 3 }, "advertised again")
        // Field report 2026-10-04: router advertisements flipped an address's state every 10-60 s, and every flip restarted
        // every camera's event channel (a camera login each time). A network change now keeps the event channel of a camera
        // whose video still arrives.
        // Re-advertising runs alongside the rest of the refresh and can finish before the event channel's turn comes.
        #expect(await fixture.waitFor(.seconds(10)) { engine.recentLogs.contains { $0.message.contains("keeping the event channel connected") } })
        #expect(driver.sourcesMade.value == 2, "the event channel of a camera whose video still arrives is kept")
        // A network change alone leaves a stream that is delivering video connected (hardening plan WS-C 5; the wake above
        // reconnected it, and `RuntimeRecoveryTests` covers the rest).
        #expect(await runtime.ingestAttempts.main == afterWake, "a healthy stream is not reconnected by a network change")

        // A refresh racing a pause: nothing may feed the stopped camera afterwards.
        let refresh = Task { await runtime.refresh() }
        await engine.pause()
        await refresh.value
        try await Task.sleep(for: .milliseconds(1500))   // > the demo stream's 1 s keyframe interval
        #expect(await runtime.hub.lastKeyframe == nil, "no ingest feeds the stopped camera's hub")
        let leftover = await runtime.ingestAttempts.main
        #expect(leftover == nil)
        #expect(!(await runtime.isSubStreamRunning))
        await fixture.tearDown()
    }

    /// Field report: a Tapo's ONVIF event channel connects and drops every 11 s. After the source reports the channel
    /// unreliable the camera moves to built-in motion detection and its status says so; pausing clears both.
    @MainActor @Test(.timeLimit(.minutes(1))) func anUnreliableEventChannelFallsBackToBuiltInMotionDetection() async throws {
        let driver = ScriptedEventDriver()
        var tuning = EngineTuning.testing
        tuning.driverFactory = { _, _, _ in driver }
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Patio")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(await !runtime.isSoftMotionRunning)
        #expect(fixture.status(camera.id)?.eventsNote == nil)

        driver.emit(.eventChannelUnreliable(shortSessions: 5))
        #expect(await fixture.until { await runtime.isSoftMotionRunning }, "built-in motion detection takes over")
        #expect(await fixture.waitFor { fixture.status(camera.id)?.eventsNote == "Camera events unreliable; using built-in motion detection" })
        #expect(engine.recentLogs.contains { $0.level == .warning && $0.message.contains("unreliable") })
        await engine.pause()
        await fixture.tearDown()
    }

    /// Review finding (W4 round 3): network changes were delayed by 2 s but not debounced: the first change of a burst
    /// started the wait, the changes during it made a second reconnect after it. One Wi-Fi rejoin (three path updates)
    /// dropped every camera's streams, events and advertising twice. Now once, 2 s after the last change.
    @MainActor @Test(.timeLimit(.minutes(1))) func aBurstOfNetworkChangesReconnectsOnce() async throws {
        let driver = ScriptedEventDriver()
        var tuning = EngineTuning.testing
        tuning.driverFactory = { _, _, _ in driver }
        let advertiser = CountingAdvertiser()
        let fixture = try await EngineFixture(tuning: tuning, advertiser: advertiser)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Hall")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        #expect(await fixture.until { advertiser.count("Hall") == 1 })
        let started = ContinuousClock.now
        for index in 0..<3 {
            if index > 0 { try await Task.sleep(for: .milliseconds(500)) }
            fixture.networkChanges.fire()
        }
        #expect(await fixture.until(.seconds(6)) { advertiser.count("Hall") == 2 }, "one reconnect")
        #expect(ContinuousClock.now - started >= .milliseconds(2_900), "2 s after the last change, not the first")
        try await Task.sleep(for: .seconds(3))
        #expect(advertiser.count("Hall") == 2, "\(advertiser.count("Hall") - 1) reconnects for one burst")
        #expect(driver.sourcesMade.value == 1, "the event channel of a camera whose video still arrives is kept")
        let reconnects = engine.recentLogs.filter { $0.message.contains("network changed") }.count
        #expect(reconnects == 1)
        await fixture.tearDown()
    }

    /// Review finding (W4 round 4): a wake reconnected at once and the path update that comes with it (a Mac rejoining
    /// Wi-Fi after sleep) reconnected again about 2 s later: live views and recordings that had resumed were cut twice,
    /// event channels logged in twice, every accessory re-registered twice. A wake goes through the same settle as the
    /// network changes, in either order: one reconnect.
    @MainActor @Test(.timeLimit(.minutes(1)), arguments: [true, false]) func aWakeAndItsPathUpdateReconnectOnce(wakeFirst: Bool) async throws {
        let driver = ScriptedEventDriver()
        var tuning = EngineTuning.testing
        tuning.driverFactory = { _, _, _ in driver }
        let advertiser = CountingAdvertiser()
        let fixture = try await EngineFixture(tuning: tuning, advertiser: advertiser)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Hall")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        #expect(await fixture.until { advertiser.count("Hall") == 1 })
        if wakeFirst {
            await engine.systemDidWake()
            try await Task.sleep(for: .milliseconds(300))
            fixture.networkChanges.fire()
        } else {
            fixture.networkChanges.fire()
            try await Task.sleep(for: .milliseconds(300))
            await engine.systemDidWake()
        }
        #expect(await fixture.until(.seconds(6)) { advertiser.count("Hall") == 2 && driver.sourcesMade.value == 2 }, "a reconnect")
        try await Task.sleep(for: .seconds(3))
        #expect(advertiser.count("Hall") == 2 && driver.sourcesMade.value == 2,
                "\(advertiser.count("Hall") - 1) reconnects, \(driver.sourcesMade.value - 1) event channel restarts for one wake and its path update")
        let reconnects = engine.recentLogs.filter { $0.message.hasSuffix("reconnecting cameras") }
        #expect(reconnects.count == 1, "\(reconnects.map(\.message))")
        await fixture.tearDown()
    }

    /// Review finding (W4 round 2): soft motion ran only on the sub stream. A sub stream that never connected (a wrong
    /// path, a 404, rejected credentials, an unsupported codec) silently disabled motion — and with it every HKSV
    /// recording — while the camera showed online, with one info line in the log. Soft motion now falls back to the main
    /// stream while the sub stream has no picture, the sub stream's trouble shows in the camera's status and in the log
    /// at warning level, and a live view does not wait for a sub stream that is known to be down.
    @MainActor @Test(.timeLimit(.minutes(1))) func softMotionUsesTheMainStreamWhileTheSubStreamHasNoPicture() async throws {
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        try await server.start()
        var tuning = EngineTuning.testing
        tuning.softMotionSubStreamWait = .seconds(1)
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        var camera = Self.rtspCamera("Yard", server: server)
        camera.subStreamURL = URL(string: "rtsp://127.0.0.1:1/sub")   // refused
        camera.motionSource = .softMotion
        camera.motionSensitivity = 1
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor(.seconds(20)) { fixture.status(camera.id)?.motionActive == true }, "motion from the main stream's picture")
        #expect(fixture.status(camera.id)?.connection == .online)
        #expect(fixture.status(camera.id)?.subStreamProblem?.contains("connection was refused") == true,
                "\(String(describing: fixture.status(camera.id)?.subStreamProblem))")
        #expect(engine.recentLogs.contains { $0.level == .warning && $0.message.contains("sub stream") })
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(await runtime.isSoftMotionRunning)
        let usesSub = await runtime.softMotionUsesSubStream
        #expect(!usesSub)
        let started = ContinuousClock.now
        let lease = await runtime.lease(preferSub: true)
        #expect(!lease.isSubStream && ContinuousClock.now - started < .seconds(1), "no wait for a sub stream that is down")
        await lease.release()
        await fixture.tearDown()
        await server.stop()
    }

    /// Soft motion moves back to the sub stream once it delivers pictures.
    @MainActor @Test(.timeLimit(.minutes(1))) func softMotionReturnsToTheSubStreamOnceItHasAPicture() async throws {
        let main = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        try await main.start()
        var subConfiguration = RTSPTestServer.Configuration()
        subConfiguration.faults.stall = RTSPTestServer.Stall(after: .zero, duration: .seconds(3))   // no picture for its first 3 s
        let sub = RTSPTestServer(source: syntheticSource(width: 160, height: 90, fps: 10, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport(),
                                 configuration: subConfiguration)
        try await sub.start()
        var tuning = EngineTuning.testing
        tuning.softMotionSubStreamWait = .milliseconds(800)
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        var camera = Self.rtspCamera("Yard", server: main)
        camera.subStreamURL = sub.url
        camera.motionSource = .softMotion
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(await fixture.until(.seconds(5)) {
            let running = await runtime.isSoftMotionRunning
            let usesSub = await runtime.softMotionUsesSubStream
            return running && !usesSub
        }, "the main stream while the sub stream has no picture")
        #expect(await fixture.until(.seconds(10)) { await runtime.softMotionUsesSubStream }, "back on the sub stream")
        #expect(await fixture.waitFor { fixture.status(camera.id)?.subStreamProblem == nil })
        await fixture.tearDown()
        await main.stop()
        await sub.stop()
    }

    /// Review finding (W4 round 4): the round-2 fix (a live view does not wait for a sub stream known to be down) held
    /// only while the broken sub stream still ran. Unused, it is stopped after `subStreamIdleStop`, and its stop made the
    /// runtime forget the failure: every later small live view (Home's grid, the Watch, remote viewing) started it again
    /// and waited the whole `subStreamStartWait` for a picture although the connection was refused at once. The failure
    /// is kept across the idle stop (and shown) until the sub stream delivers again, and a live view stops waiting as
    /// soon as the sub stream is offline.
    @MainActor @Test(.timeLimit(.minutes(1))) func aSubStreamKnownToBeDownIsNotWaitedForAfterItsIdleStop() async throws {
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        try await server.start()
        var tuning = EngineTuning.testing
        tuning.subStreamIdleStop = .milliseconds(300)
        tuning.subStreamStartWait = .seconds(3)
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        var camera = Self.rtspCamera("Yard", server: server)
        camera.subStreamURL = URL(string: "rtsp://127.0.0.1:1/sub")   // refused
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let runtime = try #require(engine.runtimes[camera.id])
        for round in 0..<3 {
            let started = ContinuousClock.now
            let lease = await runtime.lease(preferSub: true)
            let waited = ContinuousClock.now - started
            #expect(!lease.isSubStream && waited < .seconds(1), "round \(round): the live view waited \(waited) for a sub stream that is down")
            await lease.release()
            #expect(await fixture.waitFor { fixture.status(camera.id)?.subStreamProblem?.contains("connection was refused") == true },
                    "round \(round): \(String(describing: fixture.status(camera.id)?.subStreamProblem))")
            #expect(await fixture.until { await !runtime.isSubStreamRunning }, "round \(round): the unused sub stream stops")
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(fixture.status(camera.id)?.subStreamProblem?.contains("connection was refused") == true, "the problem stays shown while it is stopped")
        await fixture.tearDown()
        await server.stop()
    }

    /// Review finding (W4 round 2): the runtime read the router's state before it registered the camera's controller,
    /// so a router change in between (a motion start, the ingest going online) never reached the accessory and the older
    /// snapshot was applied instead: MotionDetected or StreamingStatus stayed wrong until the next change.
    @MainActor @Test(.timeLimit(.minutes(1))) func aRouterChangeWhileTheAccessoryRegistersReachesIt() async throws {
        let router = Box<EventRouter?>(nil)
        var tuning = EngineTuning.testing
        tuning.beforeControllerRegistration = { cameraID in await router.value?.triggerMotion(for: cameraID) }
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        router.set(engine.router)
        var camera = EngineFixture.demoCamera(name: "Hall")
        camera.motionSource = .webhook
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.hapPort != nil && fixture.status(camera.id)?.motionActive == true })
        let status = try #require(fixture.status(camera.id))
        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        let ids = try await controller.cameraIDs()
        #expect(try await controller.readValue(try #require(ids.motionDetected)).hapBool == true, "MotionDetected follows the router")
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        #expect(try await controller.streamingStatus(ids.streams[0]) == .available, "StreamingStatus follows the router")
        await controller.close()
        await fixture.tearDown()
    }

    /// Review finding (W4 round 3): nothing tested that the camera's health reaches its own accessory (StreamingStatus,
    /// the MotionSensor's StatusActive / StatusFault / StatusTampered): removing that wiring left the defaults, which
    /// look healthy, and passed every suite. Home decides from them whether the camera shows "No Response" or tries to
    /// stream an offline camera.
    @MainActor @Test(.timeLimit(.minutes(1))) func cameraHealthReachesTheCameraAccessory() async throws {
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        try await server.start()
        let transport = ScriptedTransport()
        transport.connectFailures.set([server.port: .connectionRefused])   // the camera is off
        var tuning = EngineTuning.testing
        tuning.aspectWait = .milliseconds(300)
        tuning.ingest.initialBackoff = .milliseconds(200)
        tuning.ingest.maximumBackoff = .milliseconds(400)
        let fixture = try await EngineFixture(tuning: tuning, transport: transport)
        let engine = fixture.engine
        let camera = Self.rtspCamera("Shed", server: server)
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor {
            guard fixture.status(camera.id)?.hapPort != nil, case .offline = fixture.status(camera.id)?.connection else { return false }
            return true
        })
        let status = try #require(fixture.status(camera.id))
        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        let ids = try await controller.cameraIDs()
        let database = try await controller.accessories()
        let active = try database.characteristic(.statusActive, in: .motionSensor)
        let fault = try database.characteristic(.statusFault, in: .motionSensor)
        let tampered = try database.characteristic(.statusTampered, in: .motionSensor)
        func health() async throws -> (streaming: ControllerTLV.StreamingStatus, active: Bool?, fault: Bool?, tampered: Bool?) {
            (try await controller.streamingStatus(ids.streams[0]), try await controller.readValue(active).hapBool,
             try await controller.readValue(fault).hapBool, try await controller.readValue(tampered).hapBool)
        }

        // Offline: streaming unavailable, the sensor inactive and at fault.
        var now = try await health()
        #expect(now.streaming == .unavailable && now.active == false && now.fault == true && now.tampered == false, "\(now)")

        // The camera comes up: available, active, no fault.
        transport.connectFailures.set([:])
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        #expect(await fixture.until {
            guard let health = try? await health() else { return false }
            return health.streaming == .available && health.active == true && health.fault == false
        })

        // Tampering, and its end.
        await engine.router.handle(.tamper(true), for: camera.id, origin: .camera)
        #expect(await fixture.until { (try? await controller.readValue(tampered).hapBool) == true })
        await engine.router.handle(.tamper(false), for: camera.id, origin: .camera)
        #expect(await fixture.until { (try? await controller.readValue(tampered).hapBool) == false })
        now = try await health()
        #expect(now.streaming == .available && now.active == true && now.fault == false, "\(now)")
        await controller.close()
        await fixture.tearDown()
        await server.stop()
    }

    /// Review finding (W4 round 2): every wake and network change reconnected the ingest and rebuilt the event source,
    /// both of which logged in again at once although the camera had rejected the password minutes before — a wake
    /// (with a path change or two) was enough failed logins to lock a Hikvision account, which then also refuses the
    /// corrected password. Rejected credentials now wait their 10 minutes through wakes and network changes.
    @MainActor @Test(.timeLimit(.minutes(1))) func wakeAndNetworkChangesNeverRetryRejectedCredentials() async throws {
        var serverConfiguration = RTSPTestServer.Configuration()
        serverConfiguration.credentials = HTTPCredentials(username: "admin", password: "s3cret")
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 10, gop: .seconds(1), audio: nil),
                                    transport: AppleNetworkTransport(), configuration: serverConfiguration)
        try await server.start()
        let driver = ScriptedEventDriver()
        var tuning = EngineTuning.testing
        tuning.aspectWait = .milliseconds(300)
        tuning.driverFactory = { _, _, _ in driver }
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        var camera = Self.rtspCamera("Porch", server: server)
        camera.username = "admin"
        try await engine.addCamera(camera, password: "wrong")
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.lastError == SensorState.credentialsRejectedMessage })
        #expect(await fixture.until { driver.sourcesMade.value == 1 })
        driver.emit(.authenticationFailed)   // the event channel's login was rejected too
        #expect(await fixture.until { await engine.router.state(for: camera.id)?.credentialsRejected == true })
        let runtime = try #require(engine.runtimes[camera.id])
        let attempts = await runtime.ingestAttempts.main
        #expect(attempts == 1)
        let describes = server.requests.filter { $0.method == "DESCRIBE" }.count

        await engine.systemDidWake()
        fixture.networkChanges.fire()
        #expect(await fixture.waitFor(.seconds(10)) { engine.recentLogs.contains { $0.message.contains("network changed") } })
        await engine.systemDidWake()
        // A wake reconnects once the network settled (`networkSettle`): wait for that reconnect.
        #expect(await fixture.waitFor(.seconds(10)) { engine.recentLogs.filter { $0.message.hasSuffix("reconnecting cameras") }.count >= 2 })
        try await Task.sleep(for: .milliseconds(500))
        let after = await runtime.ingestAttempts.main
        #expect(after == 1, "no new stream login before the unauthorized wait is over (\(String(describing: after)) attempts)")
        #expect(server.requests.filter { $0.method == "DESCRIBE" }.count == describes)
        #expect(driver.sourcesMade.value == 1, "the rejected event channel keeps waiting (\(driver.sourcesMade.value) sources made)")
        #expect(fixture.status(camera.id)?.lastError == SensorState.credentialsRejectedMessage)
        await fixture.tearDown()
        await server.stop()
    }

    /// A driver whose probe always reports rejected credentials (ONVIF `NotAuthorized`, HTTP 401).
    final class RejectingProbeDriver: CameraDriver {
        let vendor: CameraVendor = .onvif
        let probes = Box(0)

        func probe() async throws -> CameraProbeResult {
            probes.update { $0 += 1 }
            throw CameraAdapterError.unauthorized
        }

        func makeEventSource() -> (any CameraEventSource)? { nil }
        func snapshot() async throws -> Data? { nil }
        func makeTalkbackSink() -> (any TalkbackSink)? { nil }
    }

    /// Review finding (W4 round 2): a camera without stream addresses asks the camera for them in a loop that retried
    /// rejected credentials every 1–60 s (a failed login each time: lockout) and reported "no stream address (stream
    /// error)" instead of the rejected password.
    @MainActor @Test(.timeLimit(.minutes(1))) func aStreamAddressProbeWithRejectedCredentialsWaitsAndSaysSo() async throws {
        let driver = RejectingProbeDriver()
        var tuning = EngineTuning.testing
        tuning.aspectWait = .milliseconds(300)
        tuning.ingest.initialBackoff = .milliseconds(50)
        tuning.ingest.maximumBackoff = .milliseconds(200)
        tuning.driverFactory = { _, _, _ in driver }
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        var camera = CameraConfiguration(name: "Garage", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "127.0.0.1"), username: "admin")
        camera.motionSource = .webhook
        try await engine.addCamera(camera, password: "wrong")
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.lastError == SensorState.credentialsRejectedMessage },
                "status: \(String(describing: fixture.status(camera.id)?.lastError))")
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(driver.probes.value == 1, "rejected credentials wait the unauthorized retry (\(driver.probes.value) probes)")
        await engine.systemDidWake()   // a wake asks again only after a failure that was not a rejected login
        #expect(await fixture.waitFor(.seconds(10)) { engine.recentLogs.contains { $0.message.hasPrefix("The Mac woke up") } })
        try await Task.sleep(for: .milliseconds(500))
        #expect(driver.probes.value == 1, "a wake never shortens the wait after rejected credentials (\(driver.probes.value) probes)")
        await fixture.tearDown()
    }

    /// An ONVIF-style driver whose probe fails (no answer) until `reachable`, then reports `streamURL`.
    final class UnreachableUntilDriver: CameraDriver {
        let vendor: CameraVendor = .onvif
        let streamURL: URL
        let reachable = Box(false)
        let probes = Box(0)

        init(streamURL: URL) { self.streamURL = streamURL }

        func probe() async throws -> CameraProbeResult {
            probes.update { $0 += 1 }
            guard reachable.value else { throw TransportError.timedOut }
            return CameraProbeResult(vendor: .onvif, manufacturer: "Acme", model: "Cam", serialNumber: "SN1", firmware: "1.0",
                                     mainStream: StreamInfo(url: streamURL, videoCodec: .h264))
        }

        func makeEventSource() -> (any CameraEventSource)? { nil }
        func snapshot() async throws -> Data? { nil }
        func makeTalkbackSink() -> (any TalkbackSink)? { nil }
    }

    /// Review finding (W4 round 3): a wake or network change reconnected only cameras whose ingest existed. An ONVIF
    /// camera still waiting for its stream addresses (the Mac woke before the camera's network was up) waited out its
    /// probe backoff, up to a minute, offline. It is asked again at once.
    @MainActor @Test(.timeLimit(.minutes(1))) func aWakeAsksACameraWaitingForItsStreamAddressesAgainAtOnce() async throws {
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        try await server.start()
        let driver = UnreachableUntilDriver(streamURL: server.url)
        var tuning = EngineTuning.testing
        tuning.aspectWait = .milliseconds(300)
        tuning.ingest.initialBackoff = .seconds(20)
        tuning.ingest.maximumBackoff = .seconds(60)
        tuning.driverFactory = { _, _, _ in driver }
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        var camera = CameraConfiguration(name: "Garage", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "127.0.0.1"), username: "")
        camera.motionSource = .webhook
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { if case .offline = fixture.status(camera.id)?.connection { true } else { false } })
        #expect(driver.probes.value == 1)
        driver.reachable.set(true)   // the camera's network is up now
        await engine.systemDidWake()
        // Once the network settled after the wake (`networkSettle`, 2 s), not after the 20 s backoff.
        #expect(await fixture.waitFor(.seconds(10)) { fixture.status(camera.id)?.connection == .online }, "asked again at once, not after the 20 s backoff")
        #expect(driver.probes.value == 2)
        await fixture.tearDown()
        await server.stop()
    }

    /// An ONVIF-style driver whose probe answers only when the test opens `gate` (ignoring cancellation, as slow
    /// cameras do), with an error.
    final class GatedProbeDriver: CameraDriver {
        let vendor: CameraVendor = .onvif
        let gate = Gate()
        let probes = Box(0)

        func probe() async throws -> CameraProbeResult {
            probes.update { $0 += 1 }
            await gate.wait()
            throw CameraAdapterError.unsupported("no answer")
        }

        func makeEventSource() -> (any CameraEventSource)? { nil }
        func snapshot() async throws -> Data? { nil }
        func makeTalkbackSink() -> (any TalkbackSink)? { nil }
    }

    /// The ONVIF probe task outlives `stop()` when the camera ignores cancellation: its late answer must not change
    /// the stopped camera's state (or start anything).
    @MainActor @Test(.timeLimit(.minutes(1))) func aProbeAnsweringAfterTheStopLeavesTheCameraIdle() async throws {
        let driver = GatedProbeDriver()
        var tuning = EngineTuning.testing
        tuning.aspectWait = .milliseconds(300)
        tuning.driverFactory = { _, _, _ in driver }
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        var camera = CameraConfiguration(name: "Garage", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "127.0.0.1"), username: "")
        camera.motionSource = .webhook
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.until { driver.probes.value == 1 })
        let runtime = try #require(engine.runtimes[camera.id])
        await engine.pause()
        #expect(await engine.router.state(for: camera.id)?.streamConnection == .idle)
        driver.gate.open()
        try await Task.sleep(for: .milliseconds(500))
        #expect(await engine.router.state(for: camera.id)?.streamConnection == .idle, "a late probe answer reports nothing")
        let attempts = await runtime.ingestAttempts.main
        #expect(attempts == nil)
        #expect(driver.probes.value == 1)
        await fixture.tearDown()
    }
}
#endif
