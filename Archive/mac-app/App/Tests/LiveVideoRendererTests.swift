import AVFoundation
import CoreMedia
import CoreVideo
import MediaCore
import PlatformApple
import Testing

/// The live picture's two outputs: the display layer's own renderer (macOS 15 and 26) and the render-synchronizer receiver
/// (macOS 27). Real H.264 pictures from the app's encoder go through each; neither may fail.
@Suite(.serialized) struct LiveVideoRendererTests {
    private static func pictures(count: Int) async throws -> [EncodedVideoFrame] {
        let encoder = try AppleMediaCodecs().makeVideoEncoder(settings: VideoEncoderSettings(
            width: 320, height: 180, fps: 15, bitrateKbps: 800, profile: .main, level: .level4_0, keyframeInterval: .seconds(1)))
        var frames: [EncodedVideoFrame] = []
        for index in 0..<count {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
                for row in 0..<180 {
                    let line = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                    for column in 0..<320 {
                        line[column * 4] = UInt8((column + index * 7) & 0xFF)   // blue
                        line[column * 4 + 1] = UInt8((row + index * 3) & 0xFF)  // green
                        line[column * 4 + 2] = 90                               // red
                        line[column * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let picture = PixelBufferFrame(pixelBuffer: pixels, pts: MediaTime(value: Int64(index) * 6_000, timescale: 90_000))
            frames += try await encoder.encode(picture, wallClock: Date(), forceKeyframe: index == 0)
        }
        return frames
    }

    private func show(_ frames: [EncodedVideoFrame], on output: any VideoOutput, layer: AVSampleBufferDisplayLayer) async throws {
        let builder = LiveVideoSampleBuilder()
        var enqueued = 0
        for frame in frames {
            guard let sample = try builder.sampleBuffer(for: frame) else { continue }
            if case .enqueued = try await output.enqueue(sample) { enqueued += 1 }
        }
        #expect(enqueued == frames.count, "every picture was accepted")
        #expect(layer.sampleBufferRenderer.status != .failed, "the renderer did not fail: \(String(describing: layer.sampleBufferRenderer.error))")
        await output.flush(removingDisplayedImage: true)
        #expect(layer.sampleBufferRenderer.status != .failed)
    }

    @MainActor @Test func theLayersOwnRendererShowsPictures() async throws {
        let frames = try await Self.pictures(count: 40)
        #expect(frames.first?.isKeyframe == true && frames.count == 40)
        let layer = AVSampleBufferDisplayLayer()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(layer.sampleBufferRenderer)
        synchronizer.rate = 1
        try await show(frames, on: ClassicVideoOutput(renderer: layer.sampleBufferRenderer), layer: layer)
    }

    @MainActor @Test func theReceiverShowsPicturesOnMacOS27() async throws {
        guard #available(macOS 27, *) else { return }
        let frames = try await Self.pictures(count: 40)
        let layer = AVSampleBufferDisplayLayer()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        let output = ReceiverVideoOutput(receiver: synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer))
        synchronizer.rate = 1
        try await show(frames, on: output, layer: layer)
    }

    @Test func audioGoesToTheClassicOutputToo() throws {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        let renderer = AVSampleBufferAudioRenderer()
        synchronizer.addRenderer(renderer)
        let output = ClassicAudioOutput(renderer: renderer)
        output.flush()
        #expect(renderer.status != .failed)
    }
}
