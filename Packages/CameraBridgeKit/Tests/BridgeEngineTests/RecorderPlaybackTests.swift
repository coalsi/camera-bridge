#if canImport(Darwin) && canImport(AVFoundation)
import AVFoundation
import BridgeSupport
import CameraAdapters
import FMP4
import Foundation
import MediaCore
import PlatformApple
import TestSupport
import Testing
@testable import BridgeEngine

/// The files the recorder writes, played by AVFoundation (the gate for continuation fragments, Mac spec 17), from real encoded video.
@Suite(.serialized) struct RecorderPlaybackTests {
    struct Report {
        var videoFrames = 0
        var audioTracks = 0
        var audioSamples = 0
        var completed = false
    }

    static func decode(_ url: URL) async throws -> Report {
        let asset = AVURLAsset(url: url)
        var report = Report()
        let video = try await asset.loadTracks(withMediaType: .video)
        report.audioTracks = try await asset.loadTracks(withMediaType: .audio).count
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try #require(video.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        while let sample = output.copyNextSampleBuffer() { report.videoFrames += CMSampleBufferGetImageBuffer(sample) != nil ? 1 : 0 }
        report.completed = reader.status == .completed
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let audioReader = try AVAssetReader(asset: asset)
            let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            audioReader.add(audioOutput)
            guard audioReader.startReading() else { throw audioReader.error ?? CocoaError(.fileReadUnknown) }
            while let sample = audioOutput.copyNextSampleBuffer() { report.audioSamples += CMSampleBufferGetNumSamples(sample) }
        }
        return report
    }

    @Test(.timeLimit(.minutes(2))) func aCameraWithALongGroupRecordsFilesThatDecodeCompletely() async throws {
        let rig = try RecorderRig(camera: RecorderFixtures.camera(recordSound: true))
        defer { rig.root.remove() }
        var tuning = rig.tuning(tick: .milliseconds(100))
        tuning.now = { Date() }                                                                // real frames carry real wall clocks
        tuning.timeZone = .current
        let recorder = CameraArchiveRecorder(camera: rig.camera, hub: rig.hub, target: rig.target, codecs: AppleMediaCodecs(), naming: .cameraID, signal: rig.signal, tuning: tuning)
        await recorder.start()
        // 640x360 at 15 fps with a keyframe every 6 s and AAC sound: groups the recorder cuts into 2.5 s fragments.
        let feeder = HubFeeder(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(6), audio: .aac, audioRate: 32_000), hub: rig.hub)
        try await Task.sleep(for: .seconds(14))
        await feeder.stop()
        await recorder.stop()
        let segment = try #require(rig.target.openedSegments.first)
        let file = try RecordedFile(rig, segment: segment)
        let continuations = file.index.fragments.filter { $0.keyLength == 0 }.count
        #expect(file.index.fragments.count >= 5 && continuations >= 3, "fragments of 2.5 s: K C C K C ...")
        #expect(file.index.fragments.allSatisfy { $0.durationTicks <= 225_000 + 6_000 })
        let report = try await Self.decode(rig.files(segment).mp4)
        let recorded = file.index.fragments.reduce(0) { $0 + Int($1.samples) }
        #expect(report.videoFrames == recorded && report.completed, "every recorded frame decodes: \(report.videoFrames) of \(recorded)")
        #expect(report.audioTracks == 1 && report.audioSamples > 32_000 * 8)
        #expect(try file.rescanned() == file.index)
        // The copy a crash leaves (no sidecar, cut inside a fragment) decodes up to its last whole fragment.
        let ends = file.index.fragments.map { Int($0.offset) + Int($0.length) }
        // A feeder starved by a busy machine records fewer fragments: fail saying so, not with an index out of range that ends the whole run.
        try #require(ends.count >= 3, "only \(ends.count) fragment(s) recorded in 14 s (the feeder fell behind?); the crash copy is cut after the third")
        let cut = ends[2] + 5_000
        let scanned = try RecordedFile.scan(file.mp4.prefix(cut))
        let repaired = rig.root.url.appending(path: "repaired.mp4")
        try Data(file.mp4.prefix(Int(try #require(scanned.records.last).offset) + Int(try #require(scanned.records.last).length))).write(to: repaired)
        let after = try await Self.decode(repaired)
        #expect(scanned.records.count == 3 && after.videoFrames == scanned.records.reduce(0) { $0 + Int($1.samples) } && after.completed)
    }

    @MainActor @Test(.timeLimit(.minutes(3))) func theDemoCameraOfARunningEngineWritesFilesThatDecode() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Garage")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let hub = try #require(engine.runtimes[camera.id]).hub
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let target = FakeWriteTarget(folder: folder.url)
        let host = RecorderHost(target: target, environment: fixture.environment, signal: ChangeSignal(), tuning: RecorderTuning())
        var recorded = camera
        recorded.nvrEnabled = true
        await host.attach(recorded, hub: hub)
        try await Task.sleep(for: .seconds(8))
        #expect(host.status(for: camera.id)?.state == .recording)
        await host.detachAll()
        let segment = try #require(target.openedSegments.first)
        let mp4 = folder.url.appending(path: "\(segment).mp4")
        let index = try CBIndexFile.decode(try Data(contentsOf: folder.url.appending(path: "\(segment).cbidx")), mp4Size: UInt64(try Data(contentsOf: mp4).count))
        let frames = index.fragments.reduce(0) { $0 + Int($1.samples) }
        #expect(frames > 40)
        let report = try await Self.decode(mp4)
        #expect(report.videoFrames == frames && report.completed)
        await fixture.tearDown()
    }
}
#endif
