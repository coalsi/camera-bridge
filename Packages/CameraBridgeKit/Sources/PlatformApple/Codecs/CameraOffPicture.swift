#if os(macOS)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MediaCore

/// The still for a camera that is turned off (`MediaCodecs.cameraOffJPEG`): a dark picture with a camera-off icon (a camera with a slash),
/// "Camera off", "Turn it on in Camera Bridge" and the camera's name, drawn at the exact size asked for.
enum CameraOffPicture {
    static func jpeg(cameraName: String, width: Int, height: Int) throws -> Data {
        guard width >= 16, height >= 16, width <= 8_192, height <= 8_192,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw MediaCodecError.unsupported("cannot draw a \(width)×\(height) picture") }
        let w = Double(width), h = Double(height), unit = min(w, h * 16 / 9)   // text and icon scale with the picture
        context.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.105, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // The icon: body, lens and a slash, in grey, centred above the words.
        let grey = CGColor(red: 0.62, green: 0.62, blue: 0.67, alpha: 1)
        let iconWidth = unit * 0.16, iconHeight = iconWidth * 0.7
        let iconX = (w - iconWidth) / 2, iconY = h * 0.56
        context.setStrokeColor(grey)
        context.setLineWidth(max(2, unit * 0.008))
        context.setLineCap(.round)
        context.addPath(CGPath(roundedRect: CGRect(x: iconX, y: iconY, width: iconWidth, height: iconHeight), cornerWidth: iconWidth * 0.12,
                               cornerHeight: iconWidth * 0.12, transform: nil))
        context.strokePath()
        context.strokeEllipse(in: CGRect(x: w / 2 - iconHeight * 0.22, y: iconY + iconHeight * 0.28, width: iconHeight * 0.44, height: iconHeight * 0.44))
        context.move(to: CGPoint(x: iconX - iconWidth * 0.1, y: iconY + iconHeight * 1.12))
        context.addLine(to: CGPoint(x: iconX + iconWidth * 1.1, y: iconY - iconHeight * 0.12))
        context.strokePath()

        draw("Camera off", size: unit * 0.052, weight: 0.4, color: CGColor(gray: 1, alpha: 1), centreY: h * 0.44, width: w, in: context)
        draw("Turn it on in Camera Bridge", size: unit * 0.028, weight: 0, color: CGColor(gray: 0.82, alpha: 1), centreY: h * 0.34, width: w, in: context)
        draw(cameraName, size: unit * 0.026, weight: 0, color: grey, centreY: h * 0.26, width: w, in: context)

        guard let image = context.makeImage() else { throw MediaCodecError.unsupported("cannot make the camera-off picture") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            throw MediaCodecError.unsupported("ImageIO has no JPEG encoder")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaCodecError.unsupported("ImageIO could not encode a JPEG") }
        return output as Data
    }

    /// One centred line, shrunk until it fits 90 % of the width and cut with an ellipsis past that.
    private static func draw(_ text: String, size: Double, weight: Double, color: CGColor, centreY: Double, width: Double, in context: CGContext) {
        var fontSize = max(8, size)
        func line(_ text: String, _ size: Double) -> CTLine {
            let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let styled = weight > 0 ? (CTFontCreateCopyWithSymbolicTraits(font, size, nil, .boldTrait, .boldTrait) ?? font) : font
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): styled,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]))
        }
        var ctLine = line(text, fontSize)
        while CTLineGetTypographicBounds(ctLine, nil, nil, nil) > width * 0.9, fontSize > 8 {
            fontSize = max(8, fontSize * 0.9)
            ctLine = line(text, fontSize)
        }
        if CTLineGetTypographicBounds(ctLine, nil, nil, nil) > width * 0.9 {
            let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, fontSize, nil),
                                                                          NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…"))
            ctLine = CTLineCreateTruncatedLine(CTLineCreateWithAttributedString(attributed), width * 0.9, .end, token) ?? ctLine
        }
        let lineWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        context.textPosition = CGPoint(x: (width - lineWidth) / 2, y: centreY - fontSize * 0.3)
        CTLineDraw(ctLine, context)
    }
}
#endif
