#if os(macOS)
import Foundation
import ImageIO
import MediaCore
import PlatformApple
import Testing

/// MediaHub fed by the real synthetic source (VideoToolbox H.264 + AAC) through the portable `MediaCodecs` protocol.
@Suite(.timeLimit(.minutes(1))) struct MediaHubLiveSourceTests {
    @Test func hubMeasuresTheSyntheticSourceAndServesPrebufferAndSnapshots() async throws {
        let codecs: any MediaCodecs = AppleMediaCodecs()
        let source = codecs.makeSyntheticSource(displayName: "Demo", width: 640, height: 360, fps: 30, keyframeInterval: .seconds(1),
                                                audio: .aac, audioSampleRate: 32_000)
        let hub = MediaHub(retention: .seconds(4))
        let stream = try await source.samples()
        let pump = Task {
            for try await sample in stream { await hub.ingest(sample) }
        }
        try await Task.sleep(for: .seconds(2.5))

        let fps = try #require(await hub.measuredFrameRate)
        #expect(abs(fps - 30) < 0.5)
        let gop = try #require(await hub.measuredGOPDuration)
        #expect(abs(gop / .seconds(1) - 1) < 0.05)
        #expect(await hub.videoFormat?.width == 640)
        #expect(await hub.audioFormat == AudioFormat.aacLC(sampleRate: 32_000, channels: 1))

        // A 1 s prebuffer starts on a keyframe about 1–2 s old, then continues live.
        let subscription = await hub.subscribe(from: .prebuffer(.seconds(1)))
        var iterator = subscription.samples.makeAsyncIterator()
        guard case .video(let first)? = await iterator.next() else { Issue.record("prebuffer did not start with video"); return }
        #expect(first.isKeyframe)
        let age = Date().timeIntervalSince(first.wallClock)
        #expect(age >= 1 && age < 2.2)
        subscription.cancel()

        let keyframe = try #require(await hub.lastKeyframe)
        let jpeg = try await codecs.jpeg(fromKeyframe: keyframe, maxWidth: 320, maxHeight: nil)
        let image = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 320 && image.height == 180)

        await source.stop()
        try await pump.value
    }
}
#endif
