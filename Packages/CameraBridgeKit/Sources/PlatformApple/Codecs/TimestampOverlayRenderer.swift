#if os(macOS)
import CoreGraphics
import CoreText
import Foundation
import MediaCore

/// The timestamp overlay drawn once for one output size and text: a capsule pill (black at 42 %), the optional camera name
/// and date in regular weight and the time in semibold, all SF Pro (system font) in white with a soft shadow, the way the
/// Home app draws its own camera chrome. Everything is rendered at the output's pixel size (never scaled), so the text
/// is crisp, and sized from the output height so it looks alike at 360p and at 1080p.
///
/// The picture is NV12 (the encoder's pixel format) and the overlay is neutral gray, so it reduces to three planes the
/// compositor blends per frame: premultiplied luma and alpha (full resolution), alpha for the chroma plane (2×2 averages;
/// the overlay's chroma is neutral 128) and the pill's coverage, which masks the frosted blur of the picture behind it.
struct OverlayBitmap: Equatable {
    /// Size in pixels (even).
    let width: Int
    let height: Int
    /// Top-left corner in the output picture (even).
    let originX: Int
    let originY: Int
    /// Overlay luma (video range, 16…235) times its alpha, 0…255 scale: `out = src × (255 − alpha) / 255 + this`.
    let lumaPremultiplied: [UInt8]
    let alpha: [UInt8]
    /// `(width / 2) × (height / 2)`: mean alpha of each 2×2 block.
    let chromaAlpha: [UInt8]
    /// Coverage of the pill's shape, 0…255.
    let pillCoverage: [UInt8]
    /// Odd box-blur size for the picture behind the pill (0: no blur).
    let blurKernel: Int
}

enum TimestampOverlayRenderer {
    /// Alpha of the pill's black fill: the Home app's translucent dark material over video.
    static let pillAlpha = 0.42

    /// The overlay for `text` on a `width`×`height` picture, nil for a picture too small to carry one.
    static func render(_ text: TimestampOverlayText, width: Int, height: Int, position: OverlayPosition, size: OverlaySize) -> OverlayBitmap? {
        guard width >= 64, height >= 48 else { return nil }
        var fontSize = max(10, (Double(height) * size.fontHeightFraction).rounded())
        var layout = Layout(text: text, fontSize: fontSize)
        // A pill wider than the picture (a long name on a small picture): shrink, and in the end drop the name.
        var attempts = 0
        while layout.pillWidth > Int(Double(width) * 0.94), attempts < 8 {
            attempts += 1
            fontSize = max(7, (fontSize * 0.88).rounded(.down))
            var shown = text
            if attempts >= 5 { shown.name = nil }
            layout = Layout(text: shown, fontSize: fontSize)
        }
        let pillWidth = min(layout.pillWidth, width), pillHeight = layout.pillHeight
        guard pillHeight <= height else { return nil }
        let inset = evenDown(max(6, Int((Double(pillHeight) * 0.45).rounded())))
        let originX = evenDown(position.isLeft ? inset : width - inset - pillWidth)
        let originY = evenDown(position.isTop ? inset : height - inset - pillHeight)
        guard originX >= 0, originY >= 0, originX + pillWidth <= width, originY + pillHeight <= height else { return nil }
        guard let drawn = draw(layout, width: pillWidth, height: pillHeight) else { return nil }
        let kernel = max(3, Int((fontSize * 0.45).rounded())) | 1
        return OverlayBitmap(width: pillWidth, height: pillHeight, originX: originX, originY: originY, lumaPremultiplied: drawn.luma, alpha: drawn.alpha,
                             chromaAlpha: drawn.chromaAlpha, pillCoverage: drawn.coverage, blurKernel: kernel)
    }

    // MARK: Layout

    /// The pill's geometry for one font size.
    struct Layout {
        let text: TimestampOverlayText
        let fontSize: Double
        let regular: CTFont
        let semibold: CTFont
        let pillHeight: Int
        let pillWidth: Int
        let padding: Double
        let nameWidth: Double
        let dateWidth: Double
        let timeWidth: Double
        let dividerGap: Double
        let dividerWidth: Double
        let dateGap: Double

        init(text: TimestampOverlayText, fontSize: Double) {
            self.text = text
            self.fontSize = fontSize
            let regularFont = Self.font(size: fontSize, weight: 0.0, tabularDigits: false)
            let semiboldFont = Self.font(size: fontSize, weight: 0.3, tabularDigits: true)
            regular = regularFont
            semibold = semiboldFont
            pillHeight = evenDown(Int((fontSize * 2.05).rounded()))
            padding = (fontSize * 0.9).rounded()
            dividerGap = (fontSize * 0.55).rounded()
            dividerWidth = max(1, (fontSize * 0.07).rounded())
            dateGap = (fontSize * 0.5).rounded()
            nameWidth = text.name.map { Self.width($0, font: regularFont) } ?? 0
            dateWidth = text.date.map { Self.width($0, font: regularFont) } ?? 0
            timeWidth = Self.width(text.time, font: semiboldFont)
            var content = timeWidth
            if text.date != nil { content += dateWidth + dateGap }
            if text.name != nil { content += nameWidth + dividerGap * 2 + dividerWidth }
            pillWidth = evenDown(Int((content + padding * 2).rounded(.up)))
        }

        /// SF Pro (the system UI font) at `weight` (NSFont/UIFont scale: 0 regular, 0.3 semibold); tabular digits keep the
        /// pill's width from changing with the digits it shows.
        static func font(size: Double, weight: Double, tabularDigits: Bool) -> CTFont {
            let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            var attributes: [CFString: Any] = [kCTFontTraitsAttribute: [kCTFontWeightTrait: weight] as CFDictionary]
            if tabularDigits {
                attributes[kCTFontFeatureSettingsAttribute] = [[kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                                                                kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector]] as CFArray
            }
            let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
            return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
        }

        static func line(_ string: String, font: CTFont) -> CTLine {
            let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
            return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary))
        }

        static func width(_ string: String, font: CTFont) -> Double {
            CTLineGetTypographicBounds(line(string, font: font), nil, nil, nil)
        }
    }

    // MARK: Drawing

    private struct Drawn {
        var luma: [UInt8]
        var alpha: [UInt8]
        var chromaAlpha: [UInt8]
        var coverage: [UInt8]
    }

    private static func draw(_ layout: Layout, width: Int, height: Int) -> Drawn? {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let pill = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)

        // Coverage of the pill alone (masks the blur behind it).
        var coverage = [UInt8](repeating: 0, count: width * height)
        let drewCoverage = coverage.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.addPath(pill)
            context.fillPath()
            return true
        }
        guard drewCoverage else { return nil }

        // The overlay: gray + alpha, premultiplied.
        var pixels = [UInt8](repeating: 0, count: width * height * 2)
        let drew = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 2,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.addPath(pill)
            context.setFillColor(gray: 0, alpha: pillAlpha)
            context.fillPath()
            drawContent(layout, in: context, width: width, height: height)
            return true
        }
        guard drew else { return nil }

        var luma = [UInt8](repeating: 0, count: width * height)
        var alpha = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let g = Int(pixels[index * 2]), a = Int(pixels[index * 2 + 1])
            alpha[index] = UInt8(a)
            luma[index] = UInt8(min(255, (16 * a + 219 * g + 127) / 255))
        }
        var chroma = [UInt8](repeating: 0, count: (width / 2) * (height / 2))
        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                let i = 2 * y * width + 2 * x
                chroma[y * (width / 2) + x] = UInt8((Int(alpha[i]) + Int(alpha[i + 1]) + Int(alpha[i + width]) + Int(alpha[i + width + 1]) + 2) / 4)
            }
        }
        return Drawn(luma: luma, alpha: alpha, chromaAlpha: chroma, coverage: coverage)
    }

    /// Name, divider, date and time left to right, vertically centred on the capital height; the text carries a soft shadow.
    private static func drawContent(_ layout: Layout, in context: CGContext, width: Int, height: Int) {
        let capHeight = Double(CTFontGetCapHeight(layout.semibold))
        let baseline = (Double(height) - capHeight) / 2
        var x = layout.padding
        func drawText(_ string: String, font: CTFont) {
            context.setFillColor(gray: 1, alpha: 1)
            context.setShadow(offset: CGSize(width: 0, height: -layout.fontSize * 0.05), blur: layout.fontSize * 0.14,
                              color: CGColor(gray: 0, alpha: 0.5))
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(Layout.line(string, font: font), context)
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
        if let name = layout.text.name {
            drawText(name, font: layout.regular)
            x += layout.nameWidth + layout.dividerGap
            context.setFillColor(gray: 1, alpha: 0.4)
            let dividerHeight = layout.fontSize * 1.05
            context.fill(CGRect(x: x, y: (Double(height) - dividerHeight) / 2, width: layout.dividerWidth, height: dividerHeight))
            x += layout.dividerWidth + layout.dividerGap
        }
        if let date = layout.text.date {
            drawText(date, font: layout.regular)
            x += layout.dateWidth + layout.dateGap
        }
        drawText(layout.text.time, font: layout.semibold)
    }
}

/// `value` rounded down to an even number (NV12 chroma is subsampled 2×2).
func evenDown(_ value: Int) -> Int { value - (value & 1) }
#endif
