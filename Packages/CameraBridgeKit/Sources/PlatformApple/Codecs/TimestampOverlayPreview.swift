#if os(macOS)
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import MediaCore

/// The timestamp overlay on a still picture, for the app's live preview and for sample images: the very renderer and
/// compositor the transcoder uses on live and recorded video (`TimestampOverlayCompositor` blending into an NV12
/// picture of the output's size), so what the preview shows is what the video carries. The picture is converted to the
/// encoder's NV12 first and back to RGB after, so even the chroma subsampling matches.
public enum TimestampOverlayPreview {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// The height a preview is rendered at when none is given: HomeKit's usual 720p live view.
    public static let defaultOutputHeight = 720

    /// `image` scaled to `outputHeight` lines (aspect kept, width even, never above `image`'s own height unless
    /// `allowUpscaling`) with `overlay` drawn on it at the Mac time `date`. nil when the picture cannot be converted.
    public static func render(image: CGImage, overlay: TimestampOverlay, at date: Date, outputHeight: Int = defaultOutputHeight,
                              allowUpscaling: Bool = false, locale: Locale = .current, timeZone: TimeZone = .current) -> CGImage? {
        let height = evenDown(max(2, allowUpscaling ? outputHeight : min(outputHeight, image.height)))
        let width = evenDown(max(2, Int((Double(image.width) * Double(height) / Double(image.height)).rounded())))
        return render(image: image, overlay: overlay, at: date, width: width, height: height, locale: locale, timeZone: timeZone)
    }

    /// As above at an exact output size (stretching `image` to it).
    public static func render(image: CGImage, overlay: TimestampOverlay, at date: Date, width: Int, height: Int, locale: Locale = .current,
                              timeZone: TimeZone = .current) -> CGImage? {
        guard width >= 2, height >= 2, width % 2 == 0, height % 2 == 0, let picture = makePicture(image, width: width, height: height) else { return nil }
        let words = overlay.text(for: date, locale: locale, timeZone: timeZone)
        TimestampOverlayCompositor().apply(words, settings: overlay.settings, to: picture)
        let result = CIImage(cvPixelBuffer: picture)
        return context.createCGImage(result, from: result.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// `render(image:…)` for encoded image data (JPEG, PNG, anything ImageIO reads).
    public static func render(imageData: Data, overlay: TimestampOverlay, at date: Date, outputHeight: Int = defaultOutputHeight,
                              allowUpscaling: Bool = false, locale: Locale = .current, timeZone: TimeZone = .current) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return render(image: image, overlay: overlay, at: date, outputHeight: outputHeight, allowUpscaling: allowUpscaling, locale: locale, timeZone: timeZone)
    }

    /// PNG data of an image.
    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// `image` as an NV12 (video range, BT.709) picture of `width`×`height`.
    private static func makePicture(_ image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        var source = CIImage(cgImage: image)
        source = source.transformed(by: CGAffineTransform(scaleX: Double(width) / source.extent.width, y: Double(height) / source.extent.height))
        context.render(source, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }
}
#endif
