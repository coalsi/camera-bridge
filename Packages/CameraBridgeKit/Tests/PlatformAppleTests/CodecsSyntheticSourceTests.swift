#if os(macOS)
import Foundation
import MediaCore
import Synchronization
import Testing
@testable import PlatformApple

@Suite(.timeLimit(.minutes(1))) struct CodecsSyntheticSourceTests {
    let codecs = CodecFixtures.codecs

    /// Collects samples for `seconds` of wall-clock time, then stops the source and drains the stream.
    private func record(_ source: any MediaSource, seconds: Double) async throws -> (samples: [MediaSample], endedAfterStop: Bool) {
        let stream = try await source.samples()
        let consumer = Task {
            var collected: [MediaSample] = []
            for try await sample in stream { collected.append(sample) }
            return collected
        }
        try await Task.sleep(for: .seconds(seconds))
        await source.stop()
        // The consumer only returns once the stream has finished.
        let samples = try await consumer.value
        return (samples, true)
    }

    @Test func producesH264AtTheConfiguredFrameRateAndGOPWithAACTone() async throws {
        let source = codecs.makeSyntheticSource(displayName: "Demo Camera", width: 640, height: 360, fps: 30, keyframeInterval: .seconds(1),
                                                audio: .aac, audioSampleRate: 16_000)
        #expect(source.displayName == "Demo Camera")
        let (samples, ended) = try await record(source, seconds: 2.2)
        #expect(ended)
        let video = samples.compactMap { if case .video(let frame) = $0 { frame } else { nil } }
        let audio = samples.compactMap { if case .audio(let frame) = $0 { frame } else { nil } }

        #expect(video.count >= 55 && video.count <= 70)
        let first = try #require(video.first)
        #expect(first.isKeyframe && first.format.codec == .h264 && first.format.width == 640 && first.format.height == 360)
        if case .video = samples.first {} else { Issue.record("the first sample is not video") }
        for (previous, next) in zip(video, video.dropFirst()) { #expect(next.pts.value - previous.pts.value == 3_000) }
        #expect(video.indices.filter { video[$0].isKeyframe } == Array(stride(from: 0, to: video.count, by: 30)))
        let span = try #require(video.last).wallClock.timeIntervalSince(first.wallClock)
        #expect(abs(span - Double(video.count - 1) / 30) < 0.25)   // paced in real time

        #expect(audio.count >= 25)
        #expect(audio.allSatisfy { $0.format == AudioFormat.aacLC(sampleRate: 16_000, channels: 1) && $0.sampleCount == 1024 })
        CodecFixtures.expectContiguous(audio)
        let decoded = try CodecFixtures.decodeToPCM(audio, sampleRate: 16_000)
        #expect(CodecFixtures.rms(decoded.dropFirst(4_096).prefix(8_000)) > 500)   // an audible tone
    }

    @Test func pcmuToneAndMovingPicture() async throws {
        let source = codecs.makeSyntheticSource(displayName: "Demo", width: 320, height: 240, fps: 15, keyframeInterval: .seconds(2),
                                                audio: .pcmu, audioSampleRate: 8_000)
        let (samples, _) = try await record(source, seconds: 1.2)
        let audio = samples.compactMap { if case .audio(let frame) = $0 { frame } else { nil } }
        #expect(audio.count >= 40)
        #expect(audio.allSatisfy { $0.format == AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1) && $0.sampleCount == 160 && $0.data.count == 160 })
        CodecFixtures.expectContiguous(audio)
        #expect(CodecFixtures.rms(G711.decodeMuLaw(audio.reduce(into: Data()) { $0.append($1.data) })) > 500)

        let video = samples.compactMap { if case .video(let frame) = $0 { frame } else { nil } }
        #expect(video.count >= 14)
        let decoder = try codecs.makeVideoDecoder(format: video[0].format)
        defer { decoder.invalidate() }
        var thumbnails: [GrayImage] = []
        for frame in video.prefix(10) {
            if let thumbnail = try await decoder.decode(frame)?.grayThumbnail(maxWidth: 160) { thumbnails.append(thumbnail) }
        }
        try #require(thumbnails.count == 10)
        #expect(CodecFixtures.meanDifference(thumbnails[0], thumbnails[9]) > 1)   // the pattern moves
    }

    @Test func videoOnlyAndRestartAfterStop() async throws {
        let source = codecs.makeSyntheticSource(displayName: "Demo", width: 320, height: 180, fps: 20, keyframeInterval: .seconds(1),
                                                audio: nil, audioSampleRate: 0)
        let (first, _) = try await record(source, seconds: 0.5)
        #expect(!first.isEmpty && first.allSatisfy { if case .video = $0 { true } else { false } })
        // samples() again reconnects: a new session starting with a keyframe.
        let (second, ended) = try await record(source, seconds: 0.5)
        #expect(ended)
        if case .video(let frame) = second.first { #expect(frame.isKeyframe) } else { Issue.record("no video after restart") }
    }

    @Test func stopEndsTheStreamPromptly() async throws {
        let source = codecs.makeSyntheticSource(displayName: "Demo", width: 320, height: 180, fps: 30, keyframeInterval: .seconds(1),
                                                audio: .aac, audioSampleRate: 32_000)
        let stream = try await source.samples()
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() != nil)
        let stopped = ContinuousClock.now
        await source.stop()
        while try await iterator.next() != nil {}
        #expect(ContinuousClock.now - stopped < .seconds(1))
    }

    /// Whether `stream` finishes (normally or with an error) within `limit`.
    private func finishes(_ stream: AsyncThrowingStream<MediaSample, any Error>, within limit: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { for try await _ in stream {} } catch {}
                return !Task.isCancelled
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let finished = await group.next() ?? false
            group.cancelAll()
            return finished
        }
    }

    @Test func overlappingSamplesCallsLeaveNoProducerRunning() async throws {
        let source = codecs.makeSyntheticSource(displayName: "Demo", width: 320, height: 180, fps: 30, keyframeInterval: .seconds(1),
                                                audio: nil, audioSampleRate: 0)
        for _ in 0..<5 {
            async let first = source.samples()
            async let second = source.samples()
            let streams = try await [first, second]
            // The later call replaced the earlier session, which must have been stopped rather than left running.
            await source.stop()
            for stream in streams { #expect(await finishes(stream, within: .seconds(2))) }
        }
    }

    @Test func patternDrawsAFrameCounter() throws {
        let pattern = TestPattern(width: 640, height: 360)
        let a = try #require(try pattern.makeFrame(index: 1, pts: MediaTime(value: 0, timescale: 90_000)).grayThumbnail(maxWidth: 640))
        let b = try #require(try pattern.makeFrame(index: 2, pts: MediaTime(value: 0, timescale: 90_000)).grayThumbnail(maxWidth: 640))
        let counter = TestPattern.counterRect(width: 640, height: 360)
        var differs = false
        for y in counter.y..<(counter.y + counter.height) {
            for x in counter.x..<(counter.x + counter.width) where a.pixels[y * 640 + x] != b.pixels[y * 640 + x] { differs = true }
        }
        #expect(differs)
    }
}
#endif
