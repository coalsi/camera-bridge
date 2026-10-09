#if os(macOS)
import CoreGraphics
import CoreVideo
import Foundation
import MediaCore
import Testing
@testable import PlatformApple

enum OverlayFixtures {
    /// A synthetic scene (sky gradient, ground, bright and dark blocks) as a CGImage, no real footage.
    static func scene(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(red: 0.30, green: 0.50, blue: 0.75, alpha: 1), CGColor(red: 0.75, green: 0.85, blue: 0.95, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: Double(height)), end: CGPoint(x: 0, y: Double(height) * 0.4), options: [])
        context.setFillColor(CGColor(red: 0.18, green: 0.30, blue: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height * 2 / 5))
        context.setFillColor(CGColor(gray: 0.92, alpha: 1))
        context.fill(CGRect(x: width / 10, y: height / 3, width: width / 6, height: height / 3))
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: width * 6 / 10, y: height / 5, width: width / 4, height: height / 4))
        context.setFillColor(CGColor(red: 0.85, green: 0.25, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: width * 4 / 10, y: height / 2, width: height / 5, height: height / 5))
        return context.makeImage()!
    }

    /// One flat colour (no edges for the NV12 round trip to move).
    static func flatImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.45, green: 0.55, blue: 0.65, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A flat NV12 (video range) picture: every luma byte `luma`, every chroma byte 128.
    static func flatPicture(width: Int, height: Int, luma: UInt8) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary] as CFDictionary
        precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer) == kCVReturnSuccess)
        let picture = buffer!
        CVPixelBufferLockBaseAddress(picture, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(picture, plane)!.assumingMemoryBound(to: UInt8.self)
            memset(base, plane == 0 ? Int32(luma) : 128, CVPixelBufferGetBytesPerRowOfPlane(picture, plane) * CVPixelBufferGetHeightOfPlane(picture, plane))
        }
        CVPixelBufferUnlockBaseAddress(picture, [])
        return picture
    }

    /// The luma plane as rows of bytes (row stride removed).
    static func lumaRows(_ picture: CVPixelBuffer) -> [[UInt8]] {
        CVPixelBufferLockBaseAddress(picture, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(picture, 0)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(picture, 0)
        return (0..<CVPixelBufferGetHeight(picture)).map { y in Array(UnsafeBufferPointer(start: base + y * rowBytes, count: CVPixelBufferGetWidth(picture))) }
    }

    static let moment = Date(timeIntervalSince1970: 1_790_970_135)
    static let text = TimestampOverlayText(name: nil, date: "Fri, Oct 2", time: "7:42:15 PM")
    static func settings(_ position: OverlayPosition = .topRight, size: OverlaySize = .medium) -> TimestampOverlaySettings {
        TimestampOverlaySettings(enabled: true, position: position, showCameraName: false, showDate: true, showSeconds: true, use24Hour: false, size: size)
    }
}

/// The renderer and compositor: a pill of the right size in the right corner, drawn at the output's own resolution.
@Suite struct TimestampOverlayRendererTests {
    @Test(arguments: [(640, 360), (1280, 720), (1920, 1080)])
    func drawsAnOverlayInTheTopRightCornerSizedFromTheOutputHeight(width: Int, height: Int) throws {
        let bitmap = try #require(TimestampOverlayRenderer.render(OverlayFixtures.text, width: width, height: height, position: .topRight, size: .medium))
        // Height: 2.05 × the font size (3.2 % of the picture height, 10 px at least), even.
        let font = max(10, (Double(height) * OverlaySize.medium.fontHeightFraction).rounded())
        #expect(abs(Double(bitmap.height) - font * 2.05) <= 2, "pill height \(bitmap.height) for font \(font)")
        #expect(bitmap.width > bitmap.height * 3 && bitmap.width < Int(Double(width) * 0.5), "pill width \(bitmap.width)")
        // Top right, inset from both edges by the same small margin.
        let rightInset = width - (bitmap.originX + bitmap.width)
        #expect(bitmap.originY > 0 && abs(bitmap.originY - rightInset) <= 2)
        #expect(bitmap.originX % 2 == 0 && bitmap.originY % 2 == 0 && bitmap.width % 2 == 0 && bitmap.height % 2 == 0)
        #expect(bitmap.originY + bitmap.height < height / 4)

        // On a mid-gray frame the overlay changes the pill's pixels (dark fill, bright text) and nothing outside.
        let picture = OverlayFixtures.flatPicture(width: width, height: height, luma: 120)
        #expect(TimestampOverlayCompositor().apply(OverlayFixtures.text, settings: OverlayFixtures.settings(), to: picture))
        let rows = OverlayFixtures.lumaRows(picture)
        var changedOutside = 0
        var darkInside = 0
        var brightInside = 0
        for y in 0..<height {
            for x in 0..<width {
                let inside = x >= bitmap.originX && x < bitmap.originX + bitmap.width && y >= bitmap.originY && y < bitmap.originY + bitmap.height
                if !inside, rows[y][x] != 120 { changedOutside += 1 }
                if inside, rows[y][x] < 90 { darkInside += 1 }
                if inside, rows[y][x] >= (width >= 1280 ? 225 : 190) { brightInside += 1 }
            }
        }
        #expect(changedOutside == 0)
        #expect(darkInside > bitmap.width * bitmap.height / 3, "the translucent pill darkens most of its area")
        #expect(brightInside > 40, "glyph interiors are bright white (crisp text, not blurred away): \(brightInside)")
    }

    @Test func eachCornerSitsAtItsOwnInset() throws {
        let (width, height) = (1280, 720)
        var origins: [OverlayPosition: (Int, Int, Int, Int)] = [:]
        for position in OverlayPosition.allCases {
            let bitmap = try #require(TimestampOverlayRenderer.render(OverlayFixtures.text, width: width, height: height, position: position, size: .medium))
            origins[position] = (bitmap.originX, bitmap.originY, width - bitmap.originX - bitmap.width, height - bitmap.originY - bitmap.height)
        }
        let inset = try #require(origins[.topLeft]).0
        #expect(inset > 6)
        #expect(origins[.topLeft].map { $0.0 == inset && $0.1 == inset } == true)
        #expect(origins[.topRight].map { abs($0.2 - inset) <= 2 && $0.1 == inset } == true)
        #expect(origins[.bottomLeft].map { $0.0 == inset && abs($0.3 - inset) <= 2 } == true)
        #expect(origins[.bottomRight].map { abs($0.2 - inset) <= 2 && abs($0.3 - inset) <= 2 } == true)
    }

    @Test func sizesGrowAndScaleWithTheOutputHeight() throws {
        func pill(_ size: OverlaySize, _ height: Int) throws -> OverlayBitmap {
            try #require(TimestampOverlayRenderer.render(OverlayFixtures.text, width: height * 16 / 9, height: height, position: .topLeft, size: size))
        }
        let small = try pill(.small, 720), medium = try pill(.medium, 720), large = try pill(.large, 720)
        #expect(small.height < medium.height && medium.height < large.height && small.width < medium.width && medium.width < large.width)
        // The same look at every resolution: the pill takes the same share of the picture.
        let low = try pill(.medium, 360), high = try pill(.medium, 1080)
        let shares = [low, medium, high].map { Double($0.height) / Double([360, 720, 1080][[low, medium, high].firstIndex(of: $0)!]) }
        #expect((shares.max() ?? 0) - (shares.min() ?? 0) < 0.012, "pill height share \(shares)")
    }

    @Test func aCameraNameAndTheDateWidenThePill() throws {
        func width(_ text: TimestampOverlayText) throws -> Int {
            try #require(TimestampOverlayRenderer.render(text, width: 1280, height: 720, position: .topRight, size: .medium)).width
        }
        let timeOnly = try width(TimestampOverlayText(time: "7:42:15 PM"))
        let withDate = try width(OverlayFixtures.text)
        let withName = try width(TimestampOverlayText(name: "Front Door", date: "Fri, Oct 2", time: "7:42:15 PM"))
        #expect(timeOnly < withDate && withDate < withName)
    }

    @Test func aLongNameOnASmallPictureShrinksTheTextToFit() throws {
        let text = TimestampOverlayText(name: String(repeating: "W", count: 28), date: "Wed, Sep 30", time: "10:42:15 PM")
        let bitmap = try #require(TimestampOverlayRenderer.render(text, width: 320, height: 240, position: .bottomLeft, size: .large))
        #expect(bitmap.originX >= 0 && bitmap.originX + bitmap.width <= 320 && bitmap.originY + bitmap.height <= 240)
        #expect(TimestampOverlayRenderer.render(text, width: 40, height: 30, position: .topLeft, size: .medium) == nil, "no room: no overlay")
    }

    @Test func digitsKeepTheSamePillWidthSecondToSecond() throws {
        // Tabular figures: 1 and 8 take the same room, so a corner pill does not jitter as the seconds change.
        func width(_ time: String) throws -> Int {
            try #require(TimestampOverlayRenderer.render(TimestampOverlayText(time: time), width: 1280, height: 720, position: .topRight, size: .medium)).width
        }
        #expect(try width("11:11:11 AM") == width("08:08:08 AM"))
    }

    @Test func theCompositorRendersOncePerDistinctTextAndSize() throws {
        let compositor = TimestampOverlayCompositor()
        let picture = OverlayFixtures.flatPicture(width: 640, height: 360, luma: 100)
        for _ in 0..<30 { compositor.apply(OverlayFixtures.text, settings: OverlayFixtures.settings(), to: picture) }
        #expect(compositor.renderCount == 1)
        compositor.apply(TimestampOverlayText(date: "Fri, Oct 2", time: "7:42:16 PM"), settings: OverlayFixtures.settings(), to: picture)
        #expect(compositor.renderCount == 2)
        compositor.apply(OverlayFixtures.text, settings: OverlayFixtures.settings(.bottomLeft), to: picture)
        #expect(compositor.renderCount == 3)
    }

    @Test func aPictureThatIsNotVideoRangeNV12IsLeftAlone() {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer)
        #expect(buffer.map { TimestampOverlayCompositor().apply(OverlayFixtures.text, settings: OverlayFixtures.settings(), to: $0) } == false)
    }

    @Test func theTimestampBlendIsCheapEnoughForEveryFrame() throws {
        let compositor = TimestampOverlayCompositor()
        let picture = OverlayFixtures.flatPicture(width: 1920, height: 1080, luma: 110)
        compositor.apply(OverlayFixtures.text, settings: OverlayFixtures.settings(), to: picture)   // renders the bitmap
        // The best of several batches (other tests run alongside): a gross inefficiency shows in every batch.
        var best = Duration.seconds(10)
        for _ in 0..<5 {
            let started = ContinuousClock.now
            for _ in 0..<20 { compositor.apply(OverlayFixtures.text, settings: OverlayFixtures.settings(), to: picture) }
            best = min(best, (ContinuousClock.now - started) / 20)
        }
        let perFrame = best
        if ProcessInfo.processInfo.environment["CB_PRINT_TIMING"] != nil { print("overlay blend per 1080p picture:", perFrame) }
        // Debug build, 1080p: well inside one 30 fps frame (33 ms).
        #expect(perFrame < .milliseconds(20), "blend took \(perFrame) per 1080p frame")
    }
}

/// The overlay on real encodes, and the preview that uses the very same renderer.
@Suite(.timeLimit(.minutes(1))) struct TimestampOverlayEncodeTests {
    private func encode(_ picture: CVPixelBuffer, width: Int, height: Int, overlay: (any TimestampOverlayProviding)?) throws -> PixelBufferFrame {
        let settings = VideoEncoderSettings(width: width, height: height, fps: 30, bitrateKbps: 4_000, profile: .main, level: .auto, keyframeInterval: .seconds(1), realtime: false)
        let encoder = try AppleVideoEncoder(settings: settings, codec: .h264, overlay: overlay)
        defer { encoder.invalidate() }
        let wall = OverlayFixtures.moment
        let frames = try encoder.encodeNow(PixelBufferFrame(pixelBuffer: picture, pts: MediaTime(value: 0, timescale: 90_000)), wallClock: wall, forceKeyframe: true)
        let frame = try #require(frames.first)
        let decoder = try AppleVideoDecoder(format: frame.format)
        defer { decoder.invalidate() }
        return try #require(try decoder.decodeAllNow(frame).first)
    }

    private func meanLuma(_ rows: [[UInt8]], x: Range<Int>, y: Range<Int>) -> Double {
        var sum = 0, count = 0
        for row in y { for column in x { sum += Int(rows[row][column]); count += 1 } }
        return Double(sum) / Double(max(1, count))
    }

    @Test func theEncoderDrawsTheOverlayAndLeavesTheDecodersPictureAlone() throws {
        let (width, height) = (640, 360)
        let picture = OverlayFixtures.flatPicture(width: width, height: height, luma: 150)
        let before = OverlayFixtures.lumaRows(picture)
        let overlay = StaticTimestampOverlay(TimestampOverlay(settings: OverlayFixtures.settings(.topLeft), cameraName: "", clock: FixedOverlayClock(OverlayFixtures.moment)))
        let withOverlay = OverlayFixtures.lumaRows(try encode(picture, width: width, height: height, overlay: overlay).pixelBuffer)
        let plain = OverlayFixtures.lumaRows(try encode(picture, width: width, height: height, overlay: nil).pixelBuffer)

        #expect(OverlayFixtures.lumaRows(picture) == before, "the source picture is shared with the decoder: never drawn on")
        let words = try #require(overlay.current).text(for: OverlayFixtures.moment)
        let bitmap = try #require(TimestampOverlayRenderer.render(words, width: width, height: height, position: .topLeft, size: .medium))
        let x = (bitmap.originX + 4)..<(bitmap.originX + bitmap.width - 4), y = (bitmap.originY + 2)..<(bitmap.originY + bitmap.height - 2)
        #expect(meanLuma(plain, x: x, y: y) > 140, "no overlay: the flat picture")
        #expect(meanLuma(withOverlay, x: x, y: y) < 110, "the dark pill is in the encoded picture: \(meanLuma(withOverlay, x: x, y: y))")
        // Far from the pill the two encodes agree.
        let far = (width / 2)..<(width - 20), farY = (height / 2)..<(height - 20)
        #expect(abs(meanLuma(withOverlay, x: far, y: farY) - meanLuma(plain, x: far, y: farY)) < 2)
    }

    @Test func aDisabledOverlayLeavesTheVideoUntouched() throws {
        let picture = OverlayFixtures.flatPicture(width: 640, height: 360, luma: 150)
        var settings = OverlayFixtures.settings()
        settings.enabled = false
        let overlay = StaticTimestampOverlay(TimestampOverlay(settings: settings, clock: FixedOverlayClock(OverlayFixtures.moment)))
        #expect(overlay.current?.settings.enabled == false)
        let off = OverlayFixtures.lumaRows(try encode(picture, width: 640, height: 360, overlay: overlay).pixelBuffer)
        let plain = OverlayFixtures.lumaRows(try encode(picture, width: 640, height: 360, overlay: nil).pixelBuffer)
        #expect(off == plain)
    }

    @Test func theTranscoderCarriesTheOverlayThroughTheFactory() async throws {
        let codecs = CodecFixtures.codecs
        let overlay = StaticTimestampOverlay(TimestampOverlay(settings: OverlayFixtures.settings(.bottomRight), cameraName: "Porch", clock: FixedOverlayClock(OverlayFixtures.moment)))
        let output = VideoEncoderSettings(width: 640, height: 360, fps: 30, bitrateKbps: 1_500, profile: .main, level: .level3_1, keyframeInterval: .seconds(1))
        let input = try CodecFixtures.encodedStream(width: 1280, height: 720, count: 3, bitrateKbps: 3_000, keyframeInterval: .seconds(1))
        let withOverlay = try codecs.makeVideoTranscoder(output: output, overlay: overlay)
        let without = try codecs.makeVideoTranscoder(output: output)
        defer { withOverlay.invalidate(); without.invalidate() }
        let framesA = try await withOverlay.transcode(try #require(input.first))
        let framesB = try await without.transcode(try #require(input.first))
        let a = try #require(framesA.first), b = try #require(framesB.first)
        let decoderA = try AppleVideoDecoder(format: a.format), decoderB = try AppleVideoDecoder(format: b.format)
        defer { decoderA.invalidate(); decoderB.invalidate() }
        let decodedA = try #require(try decoderA.decodeAllNow(a).first), decodedB = try #require(try decoderB.decodeAllNow(b).first)
        let pictureA = OverlayFixtures.lumaRows(decodedA.pixelBuffer), pictureB = OverlayFixtures.lumaRows(decodedB.pixelBuffer)
        let words = try #require(overlay.current).text(for: OverlayFixtures.moment)
        let bitmap = try #require(TimestampOverlayRenderer.render(words, width: 640, height: 360, position: .bottomRight, size: .medium))
        let x = bitmap.originX..<(bitmap.originX + bitmap.width), y = bitmap.originY..<(bitmap.originY + bitmap.height)
        #expect(abs(meanLuma(pictureA, x: x, y: y) - meanLuma(pictureB, x: x, y: y)) > 8, "the pill region differs from the plain transcode")
        #expect(abs(meanLuma(pictureA, x: 0..<200, y: 0..<100) - meanLuma(pictureB, x: 0..<200, y: 0..<100)) < 2)
    }

    @Test func thePreviewUsesTheTranscodersRenderer() throws {
        // The preview's changed region is exactly the renderer's pill for that size and text.
        let (width, height) = (1280, 720)
        let flat = OverlayFixtures.flatImage(width: width, height: height)
        let settings = OverlayFixtures.settings(.bottomLeft, size: .large)
        let overlay = TimestampOverlay(settings: settings, cameraName: "Porch", clock: FixedOverlayClock(OverlayFixtures.moment))
        let locale = Locale(identifier: "en_US"), zone = TimeZone(identifier: "UTC")!
        let image = try #require(TimestampOverlayPreview.render(image: flat, overlay: overlay, at: OverlayFixtures.moment, width: width, height: height, locale: locale, timeZone: zone))
        #expect(image.width == width && image.height == height)
        let words = overlay.text(for: OverlayFixtures.moment, locale: locale, timeZone: zone)
        let bitmap = try #require(TimestampOverlayRenderer.render(words, width: width, height: height, position: .bottomLeft, size: .large))
        // Pixel rows of both images (RGBA).
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            data.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return data
        }
        let drawn = pixels(image), original = pixels(flat)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let delta = abs(Int(drawn[i]) - Int(original[i])) + abs(Int(drawn[i + 1]) - Int(original[i + 1])) + abs(Int(drawn[i + 2]) - Int(original[i + 2]))
                if delta > 24 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        // The NV12 round trip of the picture itself changes colours a little (below the threshold); the pill is the changed block.
        #expect(minX >= bitmap.originX - 1 && maxX <= bitmap.originX + bitmap.width && minY >= bitmap.originY - 1 && maxY <= bitmap.originY + bitmap.height)
        #expect(maxX - minX > bitmap.width * 8 / 10 && maxY - minY > bitmap.height * 8 / 10, "the pill is drawn where the renderer puts it")
    }

    @Test func thePreviewScalesToTheRequestedOutputHeight() throws {
        let overlay = TimestampOverlay(settings: OverlayFixtures.settings(), clock: FixedOverlayClock(OverlayFixtures.moment))
        let source = OverlayFixtures.scene(width: 1920, height: 1080)
        let image = try #require(TimestampOverlayPreview.render(image: source, overlay: overlay, at: OverlayFixtures.moment, outputHeight: 360))
        #expect(image.width == 640 && image.height == 360)
        let noUpscale = try #require(TimestampOverlayPreview.render(image: OverlayFixtures.scene(width: 320, height: 180), overlay: overlay, at: OverlayFixtures.moment))
        #expect(noUpscale.width == 320 && noUpscale.height == 180)
        let data = try #require(TimestampOverlayPreview.png(source))
        #expect(TimestampOverlayPreview.render(imageData: data, overlay: overlay, at: OverlayFixtures.moment, outputHeight: 720)?.height == 720)
        #expect(TimestampOverlayPreview.render(imageData: Data([1, 2, 3]), overlay: overlay, at: OverlayFixtures.moment) == nil)
    }

    /// `CB_OVERLAY_SAMPLES=<dir>` writes sample frames (a synthetic scene, no footage) for the docs.
    @Test func writesSampleFramesWhenAsked() throws {
        guard let directory = ProcessInfo.processInfo.environment["CB_OVERLAY_SAMPLES"] else { return }
        let date = Date(timeIntervalSince1970: 1_790_970_135)
        for (w, h) in [(1920, 1080), (1280, 720), (640, 360)] {
            for position in OverlayPosition.allCases {
                var settings = OverlayFixtures.settings(position)
                settings.showCameraName = true
                let overlay = TimestampOverlay(settings: settings, cameraName: "Front Door", clock: FixedOverlayClock(date))
                let image = try #require(TimestampOverlayPreview.render(image: OverlayFixtures.scene(width: w, height: h), overlay: overlay, at: date, width: w, height: h,
                                                                        locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "America/New_York")!))
                try #require(TimestampOverlayPreview.png(image)).write(to: URL(fileURLWithPath: directory).appending(path: "\(w)x\(h)-\(position.rawValue).png"))
            }
        }
    }
}
#endif
