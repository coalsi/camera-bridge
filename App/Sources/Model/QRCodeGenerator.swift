import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Apple Home setup QR codes (`X-HM://…` setup URIs) rendered with Core Image's `CIQRCodeGenerator`.
enum QRCodeGenerator {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The generator draws a one-module white margin itself.
    private static let generatorMargin = 1

    /// Black-on-white QR code, `moduleScale` pixels per module, scaled with nearest-neighbour sampling so edges stay
    /// crisp, with a white quiet zone of `quietZone` modules on every side (ISO/IEC 18004 asks for 4). Nil for an empty
    /// message or when Core Image fails.
    static func image(for message: String, moduleScale: Int = 12, quietZone: Int = 4, correctionLevel: String = "M") -> CGImage? {
        guard !message.isEmpty, moduleScale > 0 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(message.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }
        let pad = CGFloat(max(quietZone - generatorMargin, 0))
        let code = output.transformed(by: CGAffineTransform(translationX: pad - output.extent.minX, y: pad - output.extent.minY))
        let canvas = CGRect(x: 0, y: 0, width: output.extent.width + 2 * pad, height: output.extent.height + 2 * pad)
        let padded = code.composited(over: CIImage(color: .white).cropped(to: canvas))
        let scale = CGFloat(moduleScale)
        let scaled = padded.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = scaled.extent.integral
        return context.createCGImage(scaled, from: extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }
}
