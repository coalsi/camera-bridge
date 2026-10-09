#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// The app's own viewer (`BridgeEngine.liveVideo`): keyframe-first delivery from the hub, the lease and its release, the
/// viewers counted apart from HomeKit's, and the preview engine's synthetic streams.
@Suite(.serialized) struct LiveVideoTests {
    private static let format = VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [Data([0x67, 1, 2, 3]), Data([0x68, 4])], profile: 77, level: 31)

    private static func video(_ index: Int, key: Bool) -> MediaSample {
        .video(EncodedVideoFrame(format: format, nalUnits: [Data([key ? 0x65 : 0x41, UInt8(index & 0xFF)])], isKeyframe: key,
                                 pts: MediaTime(value: Int64(index) * 3_000, timescale: 90_000), wallClock: Date()))
    }

    private static func audio(_ index: Int) -> MediaSample {
        .audio(EncodedAudioFrame(format: .aacLC(sampleRate: 32_000, channels: 1), data: Data([UInt8(index & 0xFF), 1]),
                                 pts: MediaTime(value: Int64(index) * 1_024, timescale: 32_000), sampleCount: 1_024, wallClock: Date()))
    }

    private static func tag(_ sample: MediaSample) -> String {
        switch sample {
        case .video(let frame): frame.isKeyframe ? "K" : "P"
        case .audio: "A"
        }
    }

    /// The next `count` samples of `stream` (fewer when it ends or `timeout` passes).
    private static func take(_ count: Int, from stream: AsyncStream<MediaSample>, timeout: Duration = .seconds(3)) async -> [MediaSample] {
        await withTaskGroup(of: [MediaSample].self) { group in
            group.addTask {
                var samples: [MediaSample] = []
                for await sample in stream {
                    samples.append(sample)
                    if samples.count == count { break }
                }
                return samples
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    /// Everything `stream` delivers in `duration`.
    private static func collect(for duration: Duration, from stream: AsyncStream<MediaSample>) async -> [MediaSample] {
        let collected = Box<[MediaSample]>([])
        let reader = Task {
            for await sample in stream { collected.update { $0.append(sample) } }
        }
        try? await Task.sleep(for: duration)
        reader.cancel()
        await reader.value
        return collected.value
    }

    private final class Lease: Sendable {
        let releases = Mutex(0)
        let ended = Mutex(0)
    }

    @Test func aViewerJoiningMidGOPStartsAtTheNewestKeyframeAndFollowsLive() async throws {
        let hub = MediaHub()
        await hub.ingest(Self.video(0, key: true))
        await hub.ingest(Self.video(1, key: false))
        await hub.ingest(Self.video(2, key: true))   // the newest GOP starts here
        await hub.ingest(Self.audio(0))              // replayed audio is not delivered: it would play late
        await hub.ingest(Self.video(3, key: false))
        let lease = Lease()
        let subscription = await LiveVideoPump.start(lease: HubLease(hub: hub, isSubStream: false, release: { lease.releases.withLock { $0 += 1 } }),
                                                     audio: true, onEnd: { lease.ended.withLock { $0 += 1 } })
        #expect(subscription.stream == .main)
        await hub.ingest(Self.audio(1))
        await hub.ingest(Self.video(4, key: false))
        let samples = await Self.take(4, from: subscription.samples)
        #expect(samples.map(Self.tag) == ["K", "P", "A", "P"], "the newest keyframe first, no replayed audio, live audio and video after it")
        if case .video(let first) = samples.first { #expect(first.pts == MediaTime(value: 6_000, timescale: 90_000)) } else { Issue.record("no video") }
        subscription.cancel()
    }

    /// Audit 2 F1: a viewer that stops reading for more than `bufferLimit` samples loses whole GOPs, never the keyframe a
    /// later delta depends on: what it reads after a gap is a keyframe.
    @Test func aSlowViewerSeesEveryGapEndOnAKeyframe() async throws {
        let hub = MediaHub()
        let subscription = await LiveVideoPump.start(lease: HubLease(hub: hub, isSubStream: false, release: {}), audio: false, onEnd: {})
        // Deliver 5 GOPs of 400 frames while the consumer reads nothing: the pump's queue (600) overflows twice.
        let count = 2_000
        for index in 0..<count { await hub.ingest(Self.video(index, key: index % 400 == 0)) }
        #expect(await eventually(timeout: .seconds(5)) { await hub.subscriberCount == 1 })
        try await Task.sleep(for: .milliseconds(500))
        let reader = Task { () -> [(Int, Bool)] in
            var seen: [(Int, Bool)] = []
            for await sample in subscription.samples {
                guard case .video(let frame) = sample else { continue }
                seen.append((Int(frame.pts.value / 3_000), frame.isKeyframe))
                if seen.count >= 400 { break }
            }
            return seen
        }
        let read = await reader.value
        subscription.cancel()
        #expect(read.first?.1 == true)
        for (previous, next) in zip(read, read.dropFirst()) where next.0 != previous.0 + 1 {
            #expect(next.1, "frame \(next.0) follows a gap after frame \(previous.0)")
        }
    }

    @Test func aViewerJoiningBeforeAnyKeyframeWaitsForOneAndNeverSeesADeltaFrameFirst() async throws {
        let hub = MediaHub()
        let subscription = await LiveVideoPump.start(lease: HubLease(hub: hub, isSubStream: false, release: {}), audio: false, onEnd: {})
        await hub.ingest(Self.video(0, key: false))
        await hub.ingest(Self.video(1, key: false))
        await hub.ingest(Self.audio(0))
        await hub.ingest(Self.video(2, key: true))
        await hub.ingest(Self.video(3, key: false))
        let samples = await Self.take(2, from: subscription.samples)
        #expect(samples.map(Self.tag) == ["K", "P"])
        subscription.cancel()
    }

    @Test func audioIsLeftOutUnlessAsked() async throws {
        let hub = MediaHub()
        await hub.ingest(Self.video(0, key: true))
        let subscription = await LiveVideoPump.start(lease: HubLease(hub: hub, isSubStream: false, release: {}), audio: false, onEnd: {})
        await hub.ingest(Self.audio(0))
        await hub.ingest(Self.video(1, key: false))
        let samples = await Self.take(2, from: subscription.samples)
        #expect(samples.map(Self.tag) == ["K", "P"])
        subscription.cancel()
    }

    @Test func theLeaseIsReleasedOnceHoweverTheSubscriptionEnds() async throws {
        // cancel()
        let hub = MediaHub()
        await hub.ingest(Self.video(0, key: true))
        let first = Lease()
        let cancelled = await LiveVideoPump.start(lease: HubLease(hub: hub, isSubStream: true, release: { first.releases.withLock { $0 += 1 } }),
                                                  audio: false, onEnd: { first.ended.withLock { $0 += 1 } })
        #expect(cancelled.stream == .sub)
        #expect(await eventually(timeout: .seconds(3)) { await hub.subscriberCount == 1 })
        cancelled.cancel()
        cancelled.cancel()
        #expect(await eventually(timeout: .seconds(3)) { first.ended.withLock { $0 } == 1 })
        #expect(first.releases.withLock { $0 } == 1)
        #expect(await eventually(timeout: .seconds(3)) { await hub.subscriberCount == 0 })

        // The consumer stops reading and its task ends (the stream is dropped with it).
        let second = Lease()
        let consumer = Task {
            let subscription = await LiveVideoPump.start(lease: HubLease(hub: hub, isSubStream: false, release: { second.releases.withLock { $0 += 1 } }),
                                                         audio: false, onEnd: { second.ended.withLock { $0 += 1 } })
            for await _ in subscription.samples { break }
        }
        await consumer.value
        #expect(await eventually(timeout: .seconds(3)) { second.ended.withLock { $0 } == 1 })
        #expect(second.releases.withLock { $0 } == 1)
        #expect(await eventually(timeout: .seconds(3)) { await hub.subscriberCount == 0 })
    }

    // MARK: Engine

    @MainActor @Test(.timeLimit(.minutes(2))) func aSubStreamViewerLeasesTheSubStreamCountsApartFromHomeKitAndReleasesIt() async throws {
        var tuning = EngineTuning.testing
        tuning.subStreamIdleStop = .milliseconds(500)
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Porch")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(!(await runtime.isSubStreamRunning), "the sub stream connects on demand")

        let sub = try await engine.liveVideo(cameraID: camera.id, stream: .sub)
        #expect(sub.stream == .sub)
        #expect(await runtime.isSubStreamRunning)
        let first = await Self.take(1, from: sub.samples, timeout: .seconds(10))
        guard case .video(let frame) = try #require(first.first) else { Issue.record("the first sample is not video"); return }
        #expect(frame.isKeyframe && frame.format.width == 320, "keyframe first, from the sub stream")
        #expect(await fixture.waitFor { fixture.status(camera.id)?.appViewers == 1 })
        #expect(fixture.status(camera.id)?.liveViewers == 0, "an app viewer is not a HomeKit viewer")

        let main = try await engine.liveVideo(cameraID: camera.id, stream: .main, audio: true)
        #expect(main.stream == .main)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.appViewers == 2 })
        let mainSamples = await Self.take(40, from: main.samples, timeout: .seconds(10))
        if case .video(let frame) = mainSamples.first { #expect(frame.isKeyframe && frame.format.width == 640) } else { Issue.record("no main video") }
        #expect(mainSamples.contains { if case .audio = $0 { true } else { false } }, "the main stream's audio is delivered when asked for")

        sub.cancel()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.appViewers == 1 })
        #expect(await fixture.until(.seconds(5)) { !(await runtime.isSubStreamRunning) }, "the sub stream is let go after the idle delay")
        main.cancel()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.appViewers == 0 })
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func anAppViewerSharesTheSubStreamWithAHomeKitLeaseAndOutlivesItsRelease() async throws {
        var tuning = EngineTuning.testing
        tuning.subStreamIdleStop = .milliseconds(300)
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Gate")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let runtime = try #require(engine.runtimes[camera.id])

        let homeKit = await runtime.lease(preferSub: true)   // what a HomeKit live view takes
        let app = try await engine.liveVideo(cameraID: camera.id, stream: .sub)
        await homeKit.release()
        try await Task.sleep(for: .seconds(1))   // longer than the idle delay: the app viewer still holds the stream
        #expect(await runtime.isSubStreamRunning, "the sub stream stays while the app viewer reads it")
        #expect(await Self.take(1, from: app.samples, timeout: .seconds(5)).count == 1)
        app.cancel()
        #expect(await fixture.until(.seconds(5)) { !(await runtime.isSubStreamRunning) })
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func automaticChoosesTheSubStreamOnlyForATallMainStreamShownSmall() async throws {
        var tuning = EngineTuning.testing
        tuning.demoMain = DemoStream(width: 2560, height: 1920, fps: 5, keyframeInterval: .seconds(1))
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Tall")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(await fixture.until(.seconds(15)) { await runtime.hub.videoFormat?.height == 1920 })
        let small = try await engine.liveVideo(cameraID: camera.id, stream: .automatic, displayWidth: 640)
        let large = try await engine.liveVideo(cameraID: camera.id, stream: .automatic, displayWidth: 2400)
        #expect(small.stream == .sub && large.stream == .main)
        small.cancel()
        large.cancel()
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func unknownAndStoppedCamerasThrowAndStoppingACameraEndsItsViewers() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        await #expect(throws: EngineError.unknownCamera) { _ = try await engine.liveVideo(cameraID: UUID()) }
        var disabled = EngineFixture.demoCamera(name: "Off")
        disabled.isEnabled = false
        let running = EngineFixture.demoCamera(name: "On")
        try await engine.addCamera(disabled, password: nil)
        try await engine.addCamera(running, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(running.id)?.connection == .online })
        await #expect(throws: EngineError.cameraNotRunning) { _ = try await engine.liveVideo(cameraID: disabled.id) }

        let subscription = try await engine.liveVideo(cameraID: running.id, stream: .main)
        #expect(await fixture.waitFor { fixture.status(running.id)?.appViewers == 1 })
        await engine.pause()
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in subscription.samples {}
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(ended, "the viewers end with the camera's runtime")
        await fixture.tearDown()
    }

    // MARK: Preview engine

    /// The preview's synthetic stream is a recorded loop: its timestamps keep increasing across the loop's end, and a keyframe
    /// comes every two seconds, so a viewer that joins at any time starts at a keyframe.
    @MainActor @Test(.timeLimit(.minutes(1))) func thePreviewStreamLoopsWithContinuingTimestampsAndPeriodicKeyframes() async throws {
        let engine = BridgeEngine.preview(scenario: .fleet)
        let camera = try #require(engine.cameras.first { $0.connection == .online })
        let subscription = try await engine.liveVideo(cameraID: camera.id, stream: .sub)
        let samples = await Self.collect(for: .seconds(11), from: subscription.samples)   // 4 s to record, then 7 s of loop
        subscription.cancel()
        let frames = samples.compactMap { sample -> EncodedVideoFrame? in if case .video(let frame) = sample { frame } else { nil } }
        #expect(frames.count > 15 * 6, "about 15 pictures a second for six seconds or more")
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.1.pts > $0.0.pts }, "timestamps continue through the loop's end")
        #expect(frames.first?.isKeyframe == true)
        #expect(frames.filter(\.isKeyframe).count >= 3)
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func thePreviewEngineServesSyntheticStreamsAndCountsItsViewers() async throws {
        let engine = BridgeEngine.preview(scenario: .fleet)
        let online = try #require(engine.cameras.first { $0.connection == .online })
        let offline = try #require(engine.cameras.first { if case .offline = $0.connection { true } else { false } })
        await #expect(throws: EngineError.cameraNotRunning) { _ = try await engine.liveVideo(cameraID: offline.id) }

        let before = engine.cameras.first { $0.id == online.id }?.appViewers ?? 0
        let subscription = try await engine.liveVideo(cameraID: online.id, stream: .sub)
        let first = await Self.take(1, from: subscription.samples, timeout: .seconds(10))
        guard case .video(let frame) = try #require(first.first) else { Issue.record("no video"); return }
        #expect(frame.isKeyframe && frame.format.width == 640)
        #expect(engine.cameras.first { $0.id == online.id }?.appViewers == before + 1)
        #expect(await engine.previewLive.isRunning(camera: online.id, sub: true))
        subscription.cancel()
        #expect(await eventually(timeout: .seconds(5), every: .milliseconds(20)) { await engine.previewLive.isRunning(camera: online.id, sub: true) == false })
        #expect(await eventually(timeout: .seconds(5), every: .milliseconds(20)) { engine.cameras.first { $0.id == online.id }?.appViewers == before })
    }
}
#endif
