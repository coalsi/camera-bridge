import Foundation
import Testing
@testable import BridgeWeb
#if canImport(CoreImage) && canImport(CoreGraphics)
import CoreGraphics
import CoreImage
#endif

@Suite struct QRCodeTests {
    @Test func aHomeSetupCodeFitsVersionTwo() throws {
        let code = try QRCode(text: "X-HM://00GW95DQA7OSX")
        #expect(code.version == 2)
        #expect(code.size == 25)
        #expect(code.modules.count == 625)
        #expect((0..<8).contains(code.mask))
    }

    @Test func theThreeFinderPatternsAreInPlace() throws {
        let code = try QRCode(text: "X-HM://0081YCYEP3QXO")
        for (originX, originY) in [(0, 0), (code.size - 7, 0), (0, code.size - 7)] {
            for y in 0..<7 {
                for x in 0..<7 {
                    let ring = max(abs(x - 3), abs(y - 3))
                    let expected = ring != 2   // 3: the outer ring is dark, 2 is light, the 3x3 centre is dark
                    #expect(code.isDark(x: originX + x, y: originY + y) == expected, "finder at \(originX),\(originY) module \(x),\(y)")
                }
            }
        }
        // The timing patterns alternate between the finders; the module above the lower-left finder's quiet area is always dark.
        for index in 8..<(code.size - 8) {
            #expect(code.isDark(x: index, y: 6) == (index % 2 == 0))
            #expect(code.isDark(x: 6, y: index) == (index % 2 == 0))
        }
        #expect(code.isDark(x: 8, y: code.size - 8))
    }

    @Test func versionGrowsWithTheMessageAndStopsAtTen() throws {
        #expect(try QRCode(text: "a").version == 1)
        #expect(try QRCode(text: String(repeating: "a", count: 14)).version == 1)
        #expect(try QRCode(text: String(repeating: "a", count: 15)).version == 2)
        #expect(try QRCode(text: String(repeating: "a", count: 213)).version == 10)
        #expect(throws: QRCode.Failure.tooLong) { try QRCode(text: String(repeating: "a", count: 214)) }
        #expect(try QRCode(text: String(repeating: "a", count: 17), errorCorrection: .low).version == 1)
        #expect(try QRCode(text: String(repeating: "a", count: 17), errorCorrection: .medium).version == 2)
    }

    @Test func theSameMessageGivesTheSameCode() throws {
        #expect(try QRCode(text: "X-HM://00GW95DQA7OSX") == QRCode(text: "X-HM://00GW95DQA7OSX"))
        #expect(try QRCode(text: "X-HM://00GW95DQA7OSX") != QRCode(text: "X-HM://00GW95DQA7OSY"))
    }

    @Test func theSVGIsSelfContained() throws {
        let svg = try QRCode(text: "X-HM://00GW95DQA7OSX").svg()
        #expect(svg.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 33 33\""))
        #expect(svg.hasSuffix("</svg>"))
        #expect(svg.contains("fill=\"#fff\""))
        #expect(svg.contains("<path d=\"M"))
        #expect(!svg.contains("<script") && !svg.contains("href"))
        #expect(svg.count < 6_000)
        // The path covers exactly the dark modules.
        let code = try QRCode(text: "X-HM://00GW95DQA7OSX")
        let darkCount = code.modules.filter { $0 }.count
        var pathArea = 0
        for match in svg.matches(of: /h(\d+)v1h-\d+z/) { pathArea += Int(match.output.1) ?? 0 }
        #expect(pathArea == darkCount)
        #expect(try QRCode(text: "X-HM://00GW95DQA7OSX").svg(quietZone: 0).contains("viewBox=\"0 0 25 25\""))
    }

    #if canImport(CoreImage) && canImport(CoreGraphics)
    /// Draws the code the way a phone would see it (black on white with a quiet zone) and lets Core Image read it.
    private func decode(_ code: QRCode, scale: Int = 8) -> String? {
        let quiet = 4
        let side = (code.size + 2 * quiet) * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for y in 0..<code.size {
            for x in 0..<code.size where code.isDark(x: x, y: y) {
                for dy in 0..<scale {
                    for dx in 0..<scale { pixels[((y + quiet) * scale + dy) * side + (x + quiet) * scale + dx] = 0 }
                }
            }
        }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: side, size: CGSize(width: side, height: side), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: image) as? [CIQRCodeFeature])?.first?.messageString
    }

    @Test(arguments: [
        "X-HM://00GW95DQA7OSX", "X-HM://0081YCYEP3QXO", "A", "https://example.invalid/a?b=c", "héllo wörld ✓",
        String(repeating: "0123456789", count: 6), String(repeating: "The quick brown fox. ", count: 7), String(repeating: "x", count: 150),
    ])
    func aPhonesDecoderReadsWhatWasEncoded(message: String) throws {
        for level in [QRCode.ErrorCorrection.low, .medium] {
            let code = try QRCode(text: message, errorCorrection: level)
            #expect(decode(code) == message, "version \(code.version), level \(level), mask \(code.mask)")
        }
    }

    @Test func everyVersionFromOneToTenDecodes() throws {
        for version in 1...10 {
            // The longest message that still needs this version at level M.
            let capacity = [1: 14, 2: 26, 3: 42, 4: 62, 5: 84, 6: 106, 7: 122, 8: 152, 9: 180, 10: 213][version] ?? 1
            let message = String((0..<capacity).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement() ?? "a" })
            let code = try QRCode(text: message)
            #expect(code.version == version)
            #expect(decode(code, scale: 6) == message, "version \(version)")
        }
    }
    #endif
}
