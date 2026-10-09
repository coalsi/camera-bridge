#if os(macOS)
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import MediaCore

/// JPEG snapshots: CoreImage (Lanczos downscale + JPEG encode) from pixel buffers, ImageIO thumbnails for resizing
/// camera JPEGs. Sizes keep the aspect ratio within the bounds and never upscale.
enum JPEGSnapshot {
    /// One shared context (CIContext is thread-safe; creating one per snapshot is expensive).
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// The largest size ≤ the bounds with the source aspect ratio (rounded, ≥ 1); nil or non-positive bounds are ignored.
    static func fittedSize(width: Int, height: Int, maxWidth: Int?, maxHeight: Int?) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        var scale = 1.0
        if let maxWidth, maxWidth > 0 { scale = min(scale, Double(maxWidth) / Double(width)) }
        if let maxHeight, maxHeight > 0 { scale = min(scale, Double(maxHeight) / Double(height)) }
        guard scale < 1 else { return (width, height) }
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    static func jpeg(from pixelBuffer: CVPixelBuffer, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let target = fittedSize(width: width, height: height, maxWidth: maxWidth, maxHeight: maxHeight)
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if target.width != width || target.height != height {
            let scaleY = Double(target.height) / Double(height)
            let scaleX = Double(target.width) / Double(width)
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY])
        }
        // Exact integral extent (the filter's extent can be fractional); edges clamp instead of fading to clear.
        let extent = CGRect(x: 0, y: 0, width: target.width, height: target.height)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y)).clampedToExtent().cropped(to: extent)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.jpegRepresentation(of: image, colorSpace: colorSpace,
                                                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): min(max(quality, 0), 1)])
        else { throw MediaCodecError.unsupported("CoreImage could not encode a JPEG") }
        return data
    }

    /// Downscales an image (JPEG or anything ImageIO reads) to fit the bounds as JPEG (quality 0.8); returns the input
    /// unchanged when it already fits. Throws `MediaCodecError.unsupported` for data ImageIO cannot read.
    static func resize(_ data: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw MediaCodecError.unsupported("not an image") }
        let target = fittedSize(width: width, height: height, maxWidth: maxWidth, maxHeight: maxHeight)
        if target.width == width && target.height == height { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MediaCodecError.unsupported("ImageIO could not decode the image")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            throw MediaCodecError.unsupported("ImageIO has no JPEG encoder")
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaCodecError.unsupported("ImageIO could not encode a JPEG") }
        return output as Data
    }
}
#endif
