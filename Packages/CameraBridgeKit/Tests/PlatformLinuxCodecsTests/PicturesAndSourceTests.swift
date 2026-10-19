import Foundation
import MediaCore
import Testing
@testable import PlatformLinux

@Suite struct ImageSizeTests {
    @Test func fittedSizeKeepsAspectAndNeverUpscales() {
        #expect(FFmpegPictures.fittedSize(width: 1920, height: 1080, maxWidth: 640, maxHeight: nil) == (640, 360))
        #expect(FFmpegPictures.fittedSize(width: 1920, height: 1080, maxWidth: nil, maxHeight: 270) == (480, 270))
        #expect(FFmpegPictures.fittedSize(width: 1920, height: 1080, maxWidth: 640, maxHeight: 100) == (178, 100))
        #expect(FFmpegPictures.fittedSize(width: 640, height: 360, maxWidth: 1920, maxHeight: 1080) == (640, 360))
        #expect(FFmpegPictures.fittedSize(width: 640, height: 360, maxWidth: 0, maxHeight: -5) == (640, 360))
        #expect(FFmpegPictures.fittedSize(width: 3, height: 1000, maxWidth: nil, maxHeight: 10) == (1, 10))
    }

    @Test func pngSizeComesFromTheHeader() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        png += Data([0, 0, 0x05, 0x00, 0, 0, 0x02, 0xD0])   // 1280 × 720
        png += Data(count: 10)
        let size = FFmpegPictures.imageSize(png)
        #expect(size?.width == 1280 && size?.height == 720)
    }

    @Test func jpegSizeComesFromTheStartOfFrameMarker() {
        // SOI, an APP0 segment, a DQT-like segment, then SOF0 with 480 × 640.
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) + Data(count: 14)
        jpeg += Data([0xFF, 0xDB, 0x00, 0x05, 1, 2, 3])
        jpeg += Data([0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x02, 0x80, 0x01, 0xE0, 0x01, 0x01, 0x11, 0x00])
        let size = FFmpegPictures.imageSize(jpeg)
        #expect(size?.height == 640 && size?.width == 480)
    }

    @Test func otherDataHasNoSize() {
        #expect(FFmpegPictures.imageSize(Data("GIF89a".utf8)) == nil)
        #expect(FFmpegPictures.imageSize(Data()) == nil)
        #expect(FFmpegPictures.imageSize(Data([0xFF, 0xD8, 0xFF])) == nil)
        #expect(FFmpegPictures.imageSize(Data([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x04, 0, 0])) == nil)   // start of scan before any frame header
    }
}

@Suite(.serialized, .enabled(if: FFmpegTesting.available)) struct PicturesTests {
    private let pattern = YUVTestPattern(width: 640, height: 360)

    private func picture(_ index: Int = 3) -> RawVideoFrame { pattern.frame(index: index, pts: MediaTime(value: 0, timescale: 90_000)) }

    @Test func aPictureBecomesAJPEGOfTheRightSize() throws {
        let codecs = FFmpegTesting.makeCodecs()
        let jpeg = try codecs.jpeg(from: picture(), maxWidth: nil, maxHeight: nil, quality: 0.8)
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]) && jpeg.suffix(2) == Data([0xFF, 0xD9]))
        let size = try #require(FFmpegPictures.imageSize(jpeg))
        #expect(size.width == 640 && size.height == 360)
        // Bounds scale it down keeping the aspect, never up.
        let small = try codecs.jpeg(from: picture(), maxWidth: 160, maxHeight: 120, quality: 0.8)
        let smallSize = try #require(FFmpegPictures.imageSize(small))
        #expect(smallSize.width == 160 && smallSize.height == 90)
        let notUp = try codecs.jpeg(from: picture(), maxWidth: 4_000, maxHeight: 4_000, quality: 0.8)
        #expect(FFmpegPictures.imageSize(notUp)?.width == 640)
        #expect(small.count < jpeg.count)
    }

    @Test func qualityChangesTheSize() throws {
        let codecs = FFmpegTesting.makeCodecs()
        let low = try codecs.jpeg(from: picture(), maxWidth: nil, maxHeight: nil, quality: 0.2)
        let high = try codecs.jpeg(from: picture(), maxWidth: nil, maxHeight: nil, quality: 0.95)
        #expect(low.count < high.count, "\(low.count) vs \(high.count)")
    }

    @Test func oddSizesWork() throws {
        let odd = YUVTestPattern(width: 322, height: 182).frame(index: 1, pts: MediaTime(value: 0, timescale: 90_000))
        let jpeg = try FFmpegTesting.makeCodecs().jpeg(from: odd, maxWidth: 161, maxHeight: nil, quality: 0.8)
        let size = try #require(FFmpegPictures.imageSize(jpeg))
        #expect(size.width == 161 && size.height == 91, "\(size)")
    }

    @Test func theJPEGShowsThePicture() async throws {
        // Decode the JPEG again with ffmpeg through the decoder-free path: compare brightness of the left and right halves.
        let codecs = FFmpegTesting.makeCodecs()
        let jpeg = try codecs.jpeg(from: picture(), maxWidth: nil, maxHeight: nil, quality: 0.9)
        let runtime = FFmpegTesting.makeRuntime()
        let raw = try FFmpegOneShot.run(runtime: runtime, label: "test decode", arguments: FFmpegArguments.common + ["-f", "image2pipe", "-i", "pipe:0", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1"],
                                        input: jpeg, timeout: .seconds(10))
        #expect(raw.count == 640 * 360)
        // The pattern's background gets brighter to the right.
        let left = raw[(640 * 100)..<(640 * 100 + 100)].reduce(0) { $0 + Int($1) } / 100
        let right = raw[(640 * 100 + 540)..<(640 * 101)].reduce(0) { $0 + Int($1) } / 100
        #expect(right > left + 30, "left \(left) right \(right)")
    }

    @Test func aPictureThatIsNotARawVideoFrameIsRefused() {
        struct Foreign: DecodedVideoFrame {
            var width = 2, height = 2, pts = MediaTime(value: 0, timescale: 90_000)
            func grayThumbnail(maxWidth: Int) -> GrayImage? { nil }
        }
        #expect(throws: MediaCodecError.self) { _ = try FFmpegTesting.makeCodecs().jpeg(from: Foreign(), maxWidth: nil, maxHeight: nil, quality: 0.8) }
        #expect(throws: MediaCodecError.self) {
            _ = try FFmpegTesting.makeCodecs().jpeg(from: RawVideoFrame(width: 64, height: 64, pts: MediaTime(value: 0, timescale: 90_000), pixels: Data(count: 100)),
                                                    maxWidth: nil, maxHeight: nil, quality: 0.8)
        }
    }

    @Test func resizeJPEGShrinksAndLeavesSmallImagesAlone() throws {
        let codecs = FFmpegTesting.makeCodecs()
        let original = try codecs.jpeg(from: picture(), maxWidth: nil, maxHeight: nil, quality: 0.9)
        #expect(try codecs.resizeJPEG(original, maxWidth: 1_000, maxHeight: 1_000) == original)
        #expect(try codecs.resizeJPEG(original, maxWidth: nil, maxHeight: nil) == original)
        let smaller = try codecs.resizeJPEG(original, maxWidth: 320, maxHeight: nil)
        #expect(smaller.prefix(2) == Data([0xFF, 0xD8]))
        let size = try #require(FFmpegPictures.imageSize(smaller))
        #expect(size.width == 320 && size.height == 180)
    }

    /// The pictures of an AI description are resized at quality 0.7: the quality is the one asked, and a picture that fits is left as it is.
    @Test func resizeJPEGEncodesAtTheQualityAsked() throws {
        let codecs = FFmpegTesting.makeCodecs()
        let original = try codecs.jpeg(from: picture(), maxWidth: nil, maxHeight: nil, quality: 0.95)
        let low = try codecs.resizeJPEG(original, maxWidth: 320, maxHeight: nil, quality: 0.1)
        let high = try codecs.resizeJPEG(original, maxWidth: 320, maxHeight: nil, quality: 0.95)
        #expect(FFmpegPictures.imageSize(low)?.width == 320 && FFmpegPictures.imageSize(high)?.width == 320)
        #expect(low.count < high.count, "\(low.count) bytes at 0.1, \(high.count) at 0.95")
        #expect(try codecs.resizeJPEG(original, maxWidth: 640, maxHeight: nil, quality: 0.1) == original)
    }

    @Test func resizeJPEGAcceptsPNGAndRefusesOtherData() throws {
        let codecs = FFmpegTesting.makeCodecs()
        let runtime = FFmpegTesting.makeRuntime()
        let png = try FFmpegOneShot.run(runtime: runtime, label: "test png", arguments: FFmpegArguments.common + ["-f", "rawvideo", "-pix_fmt", "yuv420p", "-video_size", "640x360", "-i", "pipe:0", "-frames:v", "1", "-f", "image2pipe", "-c:v", "png", "pipe:1"],
                                        input: picture().pixels, timeout: .seconds(10))
        #expect(FFmpegPictures.imageSize(png)?.width == 640)
        let fromPNG = try codecs.resizeJPEG(png, maxWidth: 200, maxHeight: nil)
        #expect(fromPNG.prefix(2) == Data([0xFF, 0xD8]) && FFmpegPictures.imageSize(fromPNG)?.width == 200)
        #expect(throws: MediaCodecError.self) { _ = try codecs.resizeJPEG(Data("not an image".utf8), maxWidth: 10, maxHeight: 10) }
        #expect(throws: MediaCodecError.self) { _ = try codecs.resizeJPEG(Data(), maxWidth: 10, maxHeight: 10) }
    }

    // MARK: Straighten the picture (snapshots)

    private static let backyard = PictureCorrection(straighten: 0.4, level: 0.15)

    /// A video-range picture: luma `background` everywhere (neutral colour), and `line` 3 pixels tall along the horizon `correction`
    /// describes (rows ⌊h·H⌋ − 1 to ⌊h·H⌋ + 1 of each column).
    private func horizonPicture(width: Int, height: Int, background: UInt8 = 16, line: UInt8 = 235, along correction: PictureCorrection?) -> RawVideoFrame {
        let chroma = RawVideoFrame.chromaSize(width: width, height: height)
        var pixels = [UInt8](repeating: background, count: width * height) + [UInt8](repeating: 128, count: 2 * chroma.width * chroma.height)
        if let correction {
            for column in 0..<width {
                let row = Int((correction.horizon(across: (Double(column) + 0.5) / Double(width)) * Double(height)).rounded(.down))
                for y in (row - 1)...(row + 1) where (0..<height).contains(y) { pixels[y * width + column] = line }
            }
        }
        return RawVideoFrame(width: width, height: height, pts: MediaTime(value: 0, timescale: 90_000), pixels: Data(pixels))
    }

    /// The JPEG's luma, decoded by ffmpeg.
    private func gray(_ jpeg: Data) throws -> [UInt8] {
        [UInt8](try FFmpegOneShot.run(runtime: FFmpegTesting.makeRuntime(), label: "test decode",
                                      arguments: FFmpegArguments.common + ["-f", "image2pipe", "-i", "pipe:0", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1"],
                                      input: jpeg, timeout: .seconds(10)))
    }

    /// The row of the brightest pixel in each column.
    private func brightestRows(_ pixels: [UInt8], width: Int, height: Int) -> [Int] {
        (0..<width).map { column in (0..<height).max { pixels[$0 * width + column] < pixels[$1 * width + column] } ?? 0 }
    }

    /// 641 wide too: a camera's picture fitted inside 1280 × 720 can be 1273 × 720, and the warp needs an even width (it is warped one
    /// pixel wider and scaled back); and a small picture odd both ways (161 × 91, a 4:2:0 picture with half-filled colour samples).
    @Test(arguments: [(640, 284), (641, 284), (161, 91)]) func aCurvedHorizonComesOutFlat(width: Int, height: Int) throws {
        let runtime = FFmpegTesting.makeRuntime()
        let jpeg = try FFmpegPictures.jpeg(from: horizonPicture(width: width, height: height, along: Self.backyard), maxWidth: nil, maxHeight: nil,
                                           quality: 0.9, runtime: runtime)
        #expect(FFmpegPictures.imageSize(jpeg).map { [$0.width, $0.height] } == [width, height])
        let landing = Self.backyard.landing * Double(height)
        let columns = (width / 20)..<(width - width / 20)   // 5 % to 95 %
        // The camera's picture: the line follows the bent horizon, far from the landing line in most columns.
        let before = brightestRows(try gray(jpeg), width: width, height: height)
        #expect(columns.filter { abs(Double(before[$0]) - landing) > 3 }.count > columns.count / 2)

        let straightened = try FFmpegTesting.makeCodecs().correctJPEG(jpeg, correction: Self.backyard)
        #expect(straightened.prefix(2) == Data([0xFF, 0xD8]))
        let size = try #require(FFmpegPictures.imageSize(straightened))
        #expect(size.width == width && size.height == height)
        let pixels = try gray(straightened)
        #expect(pixels.count == width * height)
        let after = brightestRows(pixels, width: width, height: height)
        let off = columns.filter { abs(Double(after[$0]) - landing) > 3 }.map { "column \($0): row \(after[$0])" }
        #expect(off.isEmpty, "the horizon lands on row \(landing): \(off.prefix(12))")
        // Full range kept: the black above the line is still black, the line still white (in video range they would be 16 and 235).
        #expect(pixels[(10 * width)..<(11 * width)].allSatisfy { $0 < 8 }, "\(pixels[(10 * width)..<(10 * width + 8)])")
        let peaks = columns.map { Int(pixels[after[$0] * width + $0]) }
        #expect(peaks.allSatisfy { $0 > 220 } && peaks.reduce(0, +) / peaks.count > 245, "the line's brightest pixels: \(peaks.min() ?? 0) at least")
    }

    @Test func theStraightenedPictureKeepsTheJPEGsColourRange() throws {
        // A plain grey stays the same grey (the warp moves rows, never changes a plain picture): neither squeezed into video range
        // nor stretched out of it by the decoder's full-range JPEG picture going through the 4:2:0 warp.
        let runtime = FFmpegTesting.makeRuntime()
        let codecs = FFmpegTesting.makeCodecs()
        for level in [40, 128, 200] as [UInt8] {
            let jpeg = try FFmpegPictures.jpeg(from: horizonPicture(width: 320, height: 180, background: level, along: nil), maxWidth: nil, maxHeight: nil,
                                               quality: 0.9, runtime: runtime)
            let before = try gray(jpeg), after = try gray(codecs.correctJPEG(jpeg, correction: Self.backyard))
            #expect(after.count == before.count)
            let mean = { (pixels: [UInt8]) in Double(pixels.reduce(0) { $0 + Int($1) }) / Double(max(1, pixels.count)) }
            #expect(abs(mean(after) - mean(before)) < 1.5, "level \(level): \(mean(before)) before, \(mean(after)) after")
        }
    }

    @Test func theStraighteningChildHasTheEnginesSnapshotLimit() {
        // The engine gives up on a snapshot's correction a little after this (CorrectedSnapshots.deadline): one number, in MediaCore.
        #expect(FFmpegPictures.straightenTimeout == PictureCorrection.snapshotTimeout)
    }

    /// The remap sets (`camera-bridge-remap-…` directories) in `scratch` and the identity of each one's four map files.
    private func mapSets(in scratch: URL) throws -> [String: [FileIdentity]] {
        var sets: [String: [FileIdentity]] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: scratch.path) where name.hasPrefix("camera-bridge-remap-") {
            let directory = scratch.appendingPathComponent(name)
            sets[name] = try ["x.pgm", "y.pgm", "cx.pgm", "cy.pgm"].map { try FileIdentity(path: directory.appendingPathComponent($0).path) }
        }
        return sets
    }

    @Test func snapshotsOfOneSizeAndCorrectionReuseTheirMapsAndTheyGoWithTheCodecs() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cb-snapshot-maps-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var codecs: FFmpegMediaCodecs? = FFmpegTesting.makeCodecs(FFmpegCodecsConfiguration(scratchDirectory: scratch))
        let jpeg = try #require(codecs).jpeg(from: picture(), maxWidth: nil, maxHeight: nil, quality: 0.8)
        let first = try #require(codecs).correctJPEG(jpeg, correction: Self.backyard)
        let written = try mapSets(in: scratch)
        #expect(written.count == 1 && written.values.first?.count == 4, "one set of maps after the first snapshot: \(written.keys)")
        for _ in 0..<3 { #expect(try #require(codecs).correctJPEG(jpeg, correction: Self.backyard) == first) }
        #expect(try mapSets(in: scratch) == written, "the next snapshots use the same files, none rewritten")
        // Another correction (the setting was saved) or another size gets its own set; the first is still there for its camera.
        let flatter = PictureCorrection(straighten: -0.2, level: 0.05)
        _ = try #require(codecs).correctJPEG(jpeg, correction: flatter)
        _ = try #require(codecs).correctJPEG(try #require(codecs).resizeJPEG(jpeg, maxWidth: 320, maxHeight: nil), correction: Self.backyard)
        let sets = try mapSets(in: scratch)
        #expect(sets.count == 3 && written.allSatisfy { sets[$0.key] == $0.value })
        // The maps stay as long as the codecs do, and go with them.
        codecs = nil
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "the maps' directories are removed with the codecs")
    }

    @Test func correctJPEGLeavesAnOffPictureAloneAndRefusesOtherData() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cb-snapshot-maps-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let codecs = FFmpegTesting.makeCodecs(FFmpegCodecsConfiguration(scratchDirectory: scratch))
        let jpeg = try codecs.jpeg(from: picture(), maxWidth: nil, maxHeight: nil, quality: 0.8)
        #expect(try codecs.correctJPEG(jpeg, correction: .off) == jpeg)
        #expect(throws: MediaCodecError.self) { _ = try codecs.correctJPEG(Data("not an image".utf8), correction: Self.backyard) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "an off picture and a refused one write no maps")
    }
}

@Suite(.serialized, .enabled(if: FFmpegTesting.available)) struct SyntheticSourceTests {
    @Test func theDemoCameraDeliversTimedVideoAndAudio() async throws {
        let source = FFmpegTesting.makeCodecs().makeSyntheticSource(displayName: "Demo", width: 320, height: 180, fps: 15, keyframeInterval: .seconds(1), audio: .aac, audioSampleRate: 16_000)
        #expect(source.displayName == "Demo")
        let stream = try await source.samples()
        var video: [EncodedVideoFrame] = []
        var audio: [EncodedAudioFrame] = []
        let began = ContinuousClock.now
        for try await sample in stream {
            switch sample {
            case .video(let frame): video.append(frame)
            case .audio(let frame): audio.append(frame)
            }
            if video.count >= 40 || ContinuousClock.now - began > .seconds(10) { break }
        }
        await source.stop()
        #expect(video.count >= 40)
        #expect(video[0].isKeyframe && video[0].pts.value == 0 && video[0].format.width == 320 && video[0].format.height == 180)
        // Real time: 40 pictures at 15 fps take about 2.6 s.
        #expect(ContinuousClock.now - began > .seconds(2))
        #expect(zip(video, video.dropFirst()).allSatisfy { $1.pts.value - $0.pts.value == 6_000 })
        #expect(video.enumerated().filter { $0.element.isKeyframe }.map(\.offset).prefix(3) == [0, 15, 30])
        #expect(audio.count >= 25 && audio.allSatisfy { $0.format == AudioFormat.aacLC(sampleRate: 16_000, channels: 1) })
        #expect(zip(audio, audio.dropFirst()).allSatisfy { $1.pts.value - $0.pts.value == 1_024 })
    }

    @Test func stopEndsTheStreamAndKillsTheChildren() async throws {
        let source = FFmpegTesting.makeCodecs().makeSyntheticSource(displayName: "Demo", width: 162, height: 92, fps: 10, keyframeInterval: .seconds(1), audio: nil, audioSampleRate: 0)
        let stream = try await source.samples()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        #expect(ChildProcesses.count(commandContaining: "162x92") == 1)
        await source.stop()
        var ended = false
        for _ in 0..<100 {
            if try await iterator.next() == nil { ended = true; break }
        }
        #expect(ended)
        let gone = try await FFmpegTesting.eventually(timeout: .seconds(5)) { ChildProcesses.count(commandContaining: "162x92") == 0 ? true : nil }
        #expect(gone == true)
    }

    @Test func aSecondSamplesCallReplacesTheFirst() async throws {
        let source = FFmpegTesting.makeCodecs().makeSyntheticSource(displayName: "Demo", width: 160, height: 90, fps: 10, keyframeInterval: .seconds(1), audio: nil, audioSampleRate: 0)
        let first = try await source.samples()
        var firstIterator = first.makeAsyncIterator()
        _ = try await firstIterator.next()
        let second = try await source.samples()
        var secondIterator = second.makeAsyncIterator()
        guard case .video(let frame)? = try await secondIterator.next() else { Issue.record("no video from the second stream"); return }
        #expect(frame.isKeyframe && frame.pts.value == 0)
        // The first stream ended.
        var ended = false
        for _ in 0..<50 {
            if try await firstIterator.next() == nil { ended = true; break }
        }
        #expect(ended)
        await source.stop()
    }
}

/// Needs no ffmpeg.
@Suite struct SyntheticPatternTests {
    @Test func tinyOrInvalidSizesAreRefused() async {
        let source = FFmpegTesting.makeCodecs().makeSyntheticSource(displayName: "Demo", width: 1, height: 1, fps: 10, keyframeInterval: .seconds(1), audio: nil, audioSampleRate: 0)
        await #expect(throws: MediaCodecError.self) { _ = try await source.samples() }
    }

    @Test func theTestPatternMovesAndKeepsItsSize() {
        let pattern = YUVTestPattern(width: 64, height: 48)
        let a = pattern.frame(index: 0, pts: MediaTime(value: 0, timescale: 90_000)), b = pattern.frame(index: 5, pts: MediaTime(value: 0, timescale: 90_000))
        #expect(a.isComplete && b.isComplete && a.width == 64 && a.height == 48)
        #expect(a.pixels != b.pixels)
        #expect(YUVTestPattern(width: 65, height: 49).width == 64)
    }
}
