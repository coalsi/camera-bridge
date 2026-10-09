#if canImport(Darwin)
import BridgeSupport
import FMP4
import Foundation
import HAPCamera
import MediaCore
import PlatformApple
import Synchronization
import Testing
@testable import BridgeEngine

/// A video source with G.711 A-law audio added at real time on the same wall clock, its timestamps `audioLag` seconds behind
/// the video's (a camera whose audio and video the RTSP session timeline did not line up).
private final class LaggingAudioSource: MediaSource {
    let displayName = "Lagging audio"
    private let base: any MediaSource
    private let audioLag: Double

    init(base: any MediaSource, audioLag: Double) {
        self.base = base
        self.audioLag = audioLag
    }

    func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> {
        let inner = try await base.samples()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self)
        let lag = audioLag
        let task = Task {
            let start = Date()
            let audio = Task {
                let clock = ContinuousClock()
                let begun = clock.now
                let format = AudioFormat(codec: .pcma, sampleRate: 8_000, channels: 1)
                var frame = 0
                while !Task.isCancelled {
                    try? await clock.sleep(until: begun.advanced(by: .seconds(Double(frame) * 0.02)))
                    let pcm = (0..<160).map { Int16(3_000 * sin(2 * Double.pi * 440 * Double(frame * 160 + $0) / 8_000)) }
                    continuation.yield(.audio(EncodedAudioFrame(format: format, data: G711.encodeALaw(pcm),
                                                                pts: MediaTime(value: Int64(frame * 160) - Int64(lag * 8_000), timescale: 8_000),
                                                                sampleCount: 160, wallClock: start.addingTimeInterval(Double(frame) * 0.02))))
                    frame += 1
                }
            }
            do {
                for try await sample in inner { continuation.yield(sample) }
            } catch {}
            audio.cancel()
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func stop() async { await base.stop() }
}

private final class WarningLines: LogSink {
    let lines = Mutex<[String]>([])

    func record(_ entry: LogEntry) {
        if entry.category == "RecordingTest", entry.level >= .warning { lines.withLock { $0.append(entry.message) } }
    }
}

/// Field report (a Tapo, PCMA 8 kHz): "1 video / 0 audio samples, N audio dropped" in every fragment. The recorder drops camera audio
/// older than the recording's first picture; with the audio's timestamps behind the video's by more than a fragment, that is all
/// of it. The cause is on the RTSP timeline (see MediaPipelineEarlierVideoTests); the recording now says so.
@Suite(.serialized) struct RuntimeRecordingAudioAlignmentTests {
    @Test(.timeLimit(.minutes(3))) func aRecordingSaysWhenTheCamerasAudioDoesNotLineUpWithItsVideo() async throws {
        let sink = WarningLines()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let feeder = HubFeeder(source: LaggingAudioSource(base: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(2), audio: nil), audioLag: 8))
        #expect(await feeder.waitUntilReady())
        try await Task.sleep(for: .seconds(3))
        let handler = RuntimeRecordingTests.handler(feeder)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(width: 640, height: 360, prebufferMs: 1000, fragmentMs: 2000, bitrate: 800))
        await handler.updateRecordingAudioActive(true)
        let (packets, error) = await collect(try await handler.recordingStream(streamID: 41), limit: 3)
        #expect(error == nil && packets.count == 3)
        let fragments = try packets.dropFirst().map { try FragmentInfo($0.packet.data) }
        #expect(fragments.allSatisfy { ($0.audio?.durations.count ?? 0) == 0 }, "the audio is all older than the first picture")
        let warnings = sink.lines.withLock { $0 }.filter { $0.contains("camera audio frames were left out") }
        #expect(warnings.count == 1, "said once per stream: \(warnings)")
        #expect(warnings.first?.contains("not on one clock") == true)
        await handler.closeRecordingStream(streamID: 41, reason: nil)
        await feeder.stop()
    }

    @Test(.timeLimit(.minutes(3))) func alignedAudioIsNotWarnedAbout() async throws {
        let sink = WarningLines()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let feeder = HubFeeder(source: LaggingAudioSource(base: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(2), audio: nil), audioLag: 0))
        #expect(await feeder.waitUntilReady())
        try await Task.sleep(for: .seconds(3))
        let handler = RuntimeRecordingTests.handler(feeder)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(width: 640, height: 360, prebufferMs: 1000, fragmentMs: 2000, bitrate: 800))
        await handler.updateRecordingAudioActive(true)
        let (packets, _) = await collect(try await handler.recordingStream(streamID: 42), limit: 3)
        let fragments = try packets.dropFirst().map { try FragmentInfo($0.packet.data) }
        #expect(fragments.dropFirst().allSatisfy { ($0.audio?.durations.count ?? 0) > 0 })
        #expect(sink.lines.withLock { $0 }.filter { $0.contains("camera audio frames were left out") }.isEmpty)
        await handler.closeRecordingStream(streamID: 42, reason: nil)
        await feeder.stop()
    }
}
#endif
