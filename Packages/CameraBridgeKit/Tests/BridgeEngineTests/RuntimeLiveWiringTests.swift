#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import MediaCore
import PlatformApple
import RTP
import Testing
import TestSupport
@testable import CameraAdapters
@testable import BridgeEngine

/// The seams between the live view's layers, wired in `CameraRuntime`: the camera keyframe request (through the adapter's guard),
/// the sub stream's size in the choice of stream, the live pipeline's timing, and the pipeline's own end reason in the log and the status.
@Suite(.serialized) struct RuntimeLiveWiringTests {
    /// A driver whose keyframe request goes through the adapters' real `CameraKeyframeGuard` and `ONVIFLoginGuard`, as Hikvision's and
    /// ONVIF's do; `sent` is what would have reached the camera.
    final class GuardedKeyframeDriver: CameraDriver, Sendable {
        let vendor: CameraVendor = .hikvision
        let guardian = CameraKeyframeGuard(spacing: .seconds(60))
        /// "host:port" the login guard knows this camera by (unique per driver: the guards are process-wide).
        let loginHost = "keyframe-wiring-\(UUID().uuidString.prefix(8)):80"
        let endpoint = CameraEndpoint(host: "keyframe-wiring.invalid")
        /// Every call the runtime made, and the ones that went out.
        let asked = Box<[Bool]>([])
        let sent = Box<[Bool]>([])
        /// What each call threw.
        let failures = Box<[String]>([])

        func probe() async throws -> CameraProbeResult { throw CameraAdapterError.unsupported("not probed") }
        func makeEventSource() -> (any CameraEventSource)? { nil }
        func snapshot() async throws -> Data? { nil }
        func makeTalkbackSink() -> (any TalkbackSink)? { nil }

        func requestKeyframe(subStream: Bool) async throws {
            asked.update { $0.append(subStream) }
            do {
                try await guardedKeyframeRequest(endpoint: endpoint, key: "\(loginHost)/\(subStream ? 102 : 101)", loginHost: loginHost, guardian: guardian) {
                    self.sent.update { $0.append(subStream) }
                }
            } catch {
                failures.update { $0.append("\(error)") }
                throw error
            }
        }
    }

    /// Prepares and starts one live session on `handler`; the receiver plays the controller.
    @MainActor private static func startSession(_ handler: StreamingHandler, video: SelectedVideoParameters) async throws -> (receiver: SRTPTestReceiver, sessionID: UUID) {
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await RuntimeLiveStreamTests.prepare(handler, receiver: receiver, sessionID: sessionID)
        await RuntimeLiveStreamTests.connect(receiver, to: response)
        try await handler.handleStreamRequest(.start(sessionID: sessionID, video: video, audio: nil))
        return (receiver, sessionID)
    }

    // MARK: Camera keyframe request

    /// A live view that starts inside the camera's long GOP asks the camera for a keyframe through the driver (where the guard lives):
    /// each stream asks once, the guard lets one request per camera through, and a camera whose logins are paused is never sent
    /// anything (a refused login is not repeated; Hikvision locks the account after a few).
    @MainActor @Test(.timeLimit(.minutes(2))) func aLiveViewInsideALongGOPAsksTheCameraThroughTheGuard() async throws {
        let driver = GuardedKeyframeDriver()
        defer { ONVIFLoginGuard.shared.clear(host: driver.loginHost) }
        var tuning = EngineTuning.testing
        tuning.demoMain = DemoStream(width: 640, height: 360, fps: 30, keyframeInterval: .seconds(30))
        tuning.driverFactory = { _, _, _ in driver }
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Gate")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(await fixture.until(.seconds(10)) { await runtime.streamingHandler != nil })
        let handler = try #require(await runtime.streamingHandler)
        // Let the camera's GOP grow past what a replay bursts (more than 60 video frames; the replay counts the audio's samples too).
        let hub = runtime.hub
        let grown = await eventually(timeout: .seconds(20)) {
            let probe = await hub.subscribe(from: .prebuffer(.zero), bufferLimit: 1)
            defer { probe.cancel() }
            return probe.replayCount > 160
        }
        #expect(grown)
        let video = RuntimeLiveStreamTests.video(1280, 720)

        let first = try await Self.startSession(handler, video: video)
        #expect(await fixture.until(.seconds(8)) { driver.asked.value.count == 1 }, "the first live view asks the camera: \(driver.asked.value)")
        #expect(driver.asked.value == [false] && driver.sent.value == [false], "the main stream, once")

        // Another viewer is another stream with its own need; the guard keeps one request per camera and stream in its spacing.
        let second = try await Self.startSession(handler, video: video)
        #expect(await fixture.until(.seconds(8)) { driver.asked.value.count == 2 }, "\(driver.asked.value)")
        #expect(driver.sent.value == [false], "the second request is dropped by the guard, nothing reaches the camera")
        #expect(driver.failures.value.isEmpty)

        // Logins to the camera are paused (a rejected login): the next stream's request is refused up front, sends nothing, is not
        // repeated, and the live view itself carries on.
        ONVIFLoginGuard.shared.recordRejection(host: driver.loginHost)
        let third = try await Self.startSession(handler, video: video)
        #expect(await fixture.until(.seconds(8)) { driver.asked.value.count == 3 }, "\(driver.asked.value)")
        #expect(await fixture.until(.seconds(3)) { driver.failures.value.count == 1 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(driver.asked.value.count == 3, "a refusal is not asked again: \(driver.asked.value)")
        #expect(driver.sent.value == [false], "nothing was sent while the camera's logins are paused")
        #expect(await handler.runningSessionCount == 3)
        #expect(await third.receiver.waitFor(timeout: .seconds(8)) { $0.keyframes >= 1 }, "video still reaches the controller")

        for run in [first, second, third] { await run.receiver.stop() }
        await fixture.tearDown()
    }

    // MARK: Sub stream size

    /// The runtime tells the live view what the sub stream's picture covers once it has seen it: a 1280x720 request is then read from
    /// a 1280x720 sub stream (not decoded from the main stream). Before the sub stream was ever seen, the main stream serves it.
    @MainActor @Test(.timeLimit(.minutes(2))) func aRequestTheSubStreamCoversIsReadFromTheSubStreamOnceItsSizeIsKnown() async throws {
        var tuning = EngineTuning.testing
        tuning.demoMain = DemoStream(width: 1280, height: 720, fps: 15, keyframeInterval: .seconds(1))
        tuning.demoSub = DemoStream(width: 1280, height: 720, fps: 10, keyframeInterval: .seconds(1))
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Sub")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(await fixture.until(.seconds(10)) { await runtime.streamingHandler != nil })
        let handler = try #require(await runtime.streamingHandler)
        let video = RuntimeLiveStreamTests.video(1280, 720, fps: 15)

        let unknown = try await Self.startSession(handler, video: video)
        let before = try #require(await handler.pipeline(unknown.sessionID))
        #expect(!before.usesSubStream, "the sub stream's size is not known yet")
        try await handler.handleStreamRequest(.stop(sessionID: unknown.sessionID))
        await unknown.receiver.stop()

        // The sub stream runs once (a viewer leases it); its size is remembered after its idle stop.
        let lease = await runtime.lease(preferSub: true)
        #expect(lease.isSubStream)
        await lease.release()

        let known = try await Self.startSession(handler, video: video)
        let after = try #require(await handler.pipeline(known.sessionID))
        #expect(after.usesSubStream, "a 1280x720 sub stream covers a 1280x720 request")
        #expect(await known.receiver.waitFor(timeout: .seconds(10)) { $0.keyframes >= 1 })
        #expect(await fixture.waitFor { fixture.status(camera.id)?.liveSessions.first?.usesSubStream == true })
        #expect(fixture.status(camera.id)?.liveSessions.first?.health != nil, "the stream's health is in the status")
        await known.receiver.stop()
        await fixture.tearDown()
    }

    /// `StreamingHandler` passes the size on to `MediaFit.prefersSubStream`: covered, it asks for the sub stream; smaller or unknown, the
    /// main stream (a 1280-wide request is not a "small" one).
    @Test(.timeLimit(.minutes(2))) func theHandlerChoosesTheStreamFromTheSubStreamsSize() async throws {
        let cases: [(size: VideoResolution?, expectSub: Bool)] = [
            (VideoResolution(1280, 720, 15), true), (VideoResolution(1920, 1080, 15), true), (VideoResolution(640, 360, 15), false), (nil, false),
        ]
        for (size, expectSub) in cases {
            let setup = RuntimeLiveStreamTests.setup(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil),
                                                     controllerWait: .zero, subStreamSize: { size })
            #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
            let receiver = try await SRTPTestReceiver.start()
            let sessionID = UUID()
            let response = try await RuntimeLiveStreamTests.prepare(setup.handler, receiver: receiver, sessionID: sessionID)
            await RuntimeLiveStreamTests.connect(receiver, to: response)
            try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: RuntimeLiveStreamTests.video(1280, 720, fps: 15), audio: nil))
            #expect(setup.leases.value == [expectSub], "sub stream \(String(describing: size)): asked for the sub stream = \(setup.leases.value)")
            await setup.handler.stopAll()
            await receiver.stop()
            await setup.feeder.stop()
        }
    }

    // MARK: Timing

    @Test func theLivePipelineTimingDefaultsToTheStandardOneAndIsInjectable() {
        let standard = EngineTuning.standard.liveStreamTiming
        #expect(standard.recoverAfter == .seconds(4) && standard.endAtStart == .seconds(12) && standard.endAtStall == .seconds(10))
        #expect(standard.cameraKeyframeSpacing == .seconds(10) && standard.tick == .seconds(1))
        var tuning = EngineTuning.standard
        tuning.liveStreamTiming.recoverAfter = .milliseconds(10)
        #expect(tuning.liveStreamTiming.recoverAfter == .milliseconds(10) && EngineTuning.standard.liveStreamTiming.recoverAfter == .seconds(4))
    }

    // MARK: The real end reason

    /// A pipeline that gives up ends its session with its own reason: the log line of `StreamingHandler` and the live session's status
    /// say what happened, in words, where they used to say "stopped".
    @Test(.timeLimit(.minutes(2))) func aPipelineThatGivesUpIsLoggedWithItsRealReason() async throws {
        let codecs = ScriptedCodecs { _, _, _ in throw ScriptedCodecs.Injected() }
        let overlay = TimestampOverlayControl(settings: RuntimeTimestampOverlayTests.on, cameraName: "Porch")
        let run = try await RuntimeLiveFailureTests.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil), codecs: codecs,
                                                        video: RuntimeLiveStreamTests.video(1280, 720), overlay: overlay)
        #expect(await eventually(timeout: .seconds(8)) { run.ended.sessions.value.contains(run.sessionID) }, "the stream ends: \(run.lines)")
        let reason = try #require(await run.setup.handler.pipeline(run.sessionID)?.endedByPipelineReason)
        #expect(reason.contains("could not be built"))
        let status = try #require(await run.setup.handler.liveSessionStatuses().first)
        #expect(status.endReason == reason, "the status carries the pipeline's reason: \(String(describing: status.endReason))")
        #expect(status.health != nil)
        let ended = run.logs.lines(containing: "Live stream ended by itself")
        #expect(ended.contains { $0.contains("pipelineFailed: " + reason) }, "the log says why: \(ended)")
        #expect(!ended.contains { $0.contains("(stopped)") && $0.contains(reason) }, "not \"stopped\": \(ended)")
        await run.finish()
    }

    /// A stream that runs well has no end reason, and says how it is doing.
    @Test(.timeLimit(.minutes(2))) func aHealthyStreamsStatusHasAHealthAndNoEndReason() async throws {
        let run = try await RuntimeLiveFailureTests.run(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(1), audio: nil),
                                                        codecs: AppleMediaCodecs(), video: RuntimeLiveStreamTests.video(320, 240, fps: 15, bitrate: 300),
                                                        timing: .standard)
        #expect(await run.receiver.waitFor(timeout: .seconds(10)) { $0.keyframes >= 1 })
        let status = try #require(await run.setup.handler.liveSessionStatuses().first)
        #expect(status.endReason == nil)
        #expect(status.health != nil)
        await run.finish()
    }
}
#endif
