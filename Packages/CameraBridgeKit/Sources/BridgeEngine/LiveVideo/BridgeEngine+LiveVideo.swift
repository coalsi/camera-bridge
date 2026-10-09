import CameraAdapters
import Foundation
import MediaCore

extension BridgeEngine {
    /// Opens a live view of `cameraID` for the app's own viewer: the camera's encoded access units from the newest keyframe
    /// on (no transcoding; the app decodes them in hardware), with the camera's audio when `audio` is true.
    ///
    /// The subscription leases the camera's ingest the way a HomeKit viewer does: the sub stream starts on demand and is
    /// released when the subscription ends (`LiveVideoSubscription.cancel()`, the consumer finishing, or dropping its
    /// stream); the main stream runs anyway. HomeKit sessions are not affected, and app viewers are counted apart from
    /// them (`CameraStatus.appViewers`). `displayWidth` (pixels) tells `.automatic` how large the picture is shown.
    ///
    /// - Throws: `EngineError.unknownCamera`, or `.cameraNotRunning` while the camera is not running (disabled, the
    ///   bridge paused or stopped, still starting). An offline camera that runs does not throw: its stream starts when it
    ///   delivers a picture again.
    public func liveVideo(cameraID: UUID, stream: LiveVideoStream = .automatic, audio: Bool = false,
                          displayWidth: Int? = nil) async throws -> LiveVideoSubscription {
        guard configurations.contains(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
        if isPreview { return try await previewLiveVideo(cameraID: cameraID, stream: stream, audio: audio, displayWidth: displayWidth) }
        guard let runtime = runtimes[cameraID],
              let subscription = await runtime.openLiveVideo(stream: stream, audio: audio, displayWidth: displayWidth) else {
            throw EngineError.cameraNotRunning
        }
        return subscription
    }

    /// The preview engine's synthetic streams (moving test pattern, main or sub size of the sample camera), leased and
    /// counted like a real camera's.
    private func previewLiveVideo(cameraID: UUID, stream: LiveVideoStream, audio: Bool, displayWidth: Int?) async throws -> LiveVideoSubscription {
        guard let camera = cameras.first(where: { $0.id == cameraID }), camera.connection == .online else { throw EngineError.cameraNotRunning }
        var sub = stream == .sub
        if stream == .automatic, let size = PreviewLiveSources.size(of: camera) { sub = size.height > 1440 && (displayWidth ?? 0) <= 1280 }
        let lease = await previewLive.lease(camera: camera, sub: sub, codecs: environment.codecs)
        previewAppViewersChanged(cameraID, by: 1)
        return await LiveVideoPump.start(lease: lease, audio: audio) { [weak self] in
            await MainActor.run { self?.previewAppViewersChanged(cameraID, by: -1) }
        }
    }
}

/// Synthetic streams for the preview engine's `liveVideo`: a moving test pattern per camera and stream, started with the
/// first viewer and stopped with the last (so the preview shows the lease behaviour of the real engine).
///
/// The pattern is encoded once per picture size and frame rate (two keyframe intervals of real-time encoding, shared by every
/// camera of that size) and then replayed in a loop at real-time pace with continuing timestamps: a preview with a dozen
/// live tiles costs what a dozen real cameras' pictures cost to show, not a dozen encoders.
actor PreviewLiveSources {
    private struct Key: Hashable {
        var camera: UUID
        var sub: Bool
    }

    private struct Spec: Hashable {
        var width: Int
        var height: Int
        var fps: Int
        var audio: Bool
    }

    /// Two keyframe intervals of the synthetic stream, from a keyframe up to (not including) the third.
    private struct Loop: Sendable {
        var samples: [MediaSample]
        /// How long it plays, and what each round adds to the timestamps.
        var duration: Double
        var videoTicks: Int64
    }

    private final class Entry {
        let hub = MediaHub(retention: .seconds(4))
        var task: Task<Void, Never>?
        var users = 0
    }

    private var entries: [Key: Entry] = [:]
    private var loops: [Spec: Task<Loop?, Never>] = [:]

    /// The picture size of a sample camera ("H.264 2688×1520 · 20 fps"): its aspect ratio and frame rate are kept by the
    /// synthetic stream, its size is capped (the demo's encoder runs in real time on the Mac).
    static func size(of camera: CameraStatus) -> (width: Int, height: Int)? {
        guard let summary = camera.videoSummary else { return nil }
        let words = summary.split(separator: " ")
        guard let size = words.first(where: { $0.contains("×") }) else { return nil }
        let parts = size.split(separator: "×").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    private static func frameRate(of camera: CameraStatus) -> Int? {
        guard let summary = camera.videoSummary, let range = summary.range(of: "· ") else { return nil }
        return Int(summary[range.upperBound...].split(separator: " ").first ?? "")
    }

    func lease(camera: CameraStatus, sub: Bool, codecs: any MediaCodecs) -> HubLease {
        let key = Key(camera: camera.id, sub: sub)
        let entry: Entry
        if let existing = entries[key] {
            entry = existing
        } else {
            let size = Self.size(of: camera) ?? (1920, 1080)
            let fps = Self.frameRate(of: camera) ?? 15
            let width = (sub ? 640 : min(size.width, 1920)) & ~1
            let spec = Spec(width: width, height: (width * size.height / max(size.width, 1)) & ~1, fps: sub ? min(fps, 15) : fps, audio: !sub)
            entry = Entry()
            entries[key] = entry
            let hub = entry.hub
            let loop = loop(for: spec, name: camera.name, codecs: codecs)
            entry.task = Task {
                guard let loop = await loop.value else { return }
                await Self.play(loop, into: hub)
            }
        }
        entry.users += 1
        return HubLease(hub: entry.hub, isSubStream: sub, release: { [weak self] in await self?.release(key) })
    }

    private func release(_ key: Key) {
        guard let entry = entries[key] else { return }
        entry.users -= 1
        guard entry.users <= 0 else { return }
        entries[key] = nil
        entry.task?.cancel()
    }

    /// Tests: whether the camera's stream runs.
    func isRunning(camera: UUID, sub: Bool) -> Bool { entries[Key(camera: camera, sub: sub)] != nil }

    // MARK: Loop

    private func loop(for spec: Spec, name: String, codecs: any MediaCodecs) -> Task<Loop?, Never> {
        if let existing = loops[spec] { return existing }
        let task = Task { await Self.record(spec, name: name, codecs: codecs) }
        loops[spec] = task
        return task
    }

    /// Runs the synthetic source until its third keyframe and keeps what came from the first one on.
    private static func record(_ spec: Spec, name: String, codecs: any MediaCodecs) async -> Loop? {
        let source = codecs.makeSyntheticSource(displayName: name, width: spec.width, height: spec.height, fps: spec.fps, keyframeInterval: .seconds(2),
                                                audio: spec.audio ? .aac : nil, audioSampleRate: 32_000)
        var samples: [MediaSample] = []
        var keyframes = 0
        var first: EncodedVideoFrame?
        var third: EncodedVideoFrame?
        do {
            for try await sample in try await source.samples() {
                if case .video(let frame) = sample, frame.isKeyframe {
                    keyframes += 1
                    if keyframes == 1 { first = frame }
                    if keyframes == 3 {
                        third = frame
                        break
                    }
                }
                if keyframes >= 1 { samples.append(sample) }
            }
        } catch {}
        await source.stop()
        guard let first, let third, !Task.isCancelled else { return nil }
        let ticks = third.pts.converted(to: 90_000).value - first.pts.converted(to: 90_000).value
        return Loop(samples: samples, duration: third.wallClock.timeIntervalSince(first.wallClock), videoTicks: ticks)
    }

    /// Plays the loop into `hub` forever (until cancelled): timestamps continue from round to round, the pace is the original's.
    private static func play(_ loop: Loop, into hub: MediaHub) async {
        guard let origin = loop.samples.first?.wallClock else { return }
        let clock = ContinuousClock()
        let start = clock.now
        var round: Int64 = 0
        while !Task.isCancelled {
            let roundStart = start + .seconds(Double(round) * loop.duration)
            for sample in loop.samples {
                do {
                    try await clock.sleep(until: roundStart + .seconds(sample.wallClock.timeIntervalSince(origin)))
                } catch {
                    return
                }
                switch sample {
                case .video(var frame):
                    frame.pts = MediaTime(value: frame.pts.value + round * loop.videoTicks, timescale: frame.pts.timescale)
                    frame.dts = frame.dts.map { MediaTime(value: $0.value + round * loop.videoTicks, timescale: $0.timescale) }
                    frame.wallClock = Date()
                    await hub.ingest(.video(frame))
                case .audio(var frame):
                    let ticks = Int64((loop.duration * Double(frame.format.sampleRate)).rounded())
                    frame.pts = MediaTime(value: frame.pts.value + round * ticks, timescale: frame.pts.timescale)
                    frame.wallClock = Date()
                    await hub.ingest(.audio(frame))
                }
            }
            round += 1
        }
    }
}
