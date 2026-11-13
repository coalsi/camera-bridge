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
    /// Draws a code of `size` by `size` modules (row by row, `true` = dark) the way a phone would see it (black on white with a quiet zone) and
    /// lets Core Image read it. It takes the modules rather than a `QRCode`, so the page's codes are read the same way.
    private func decode(size: Int, modules: [Bool], scale: Int = 8) -> String? {
        let quiet = 4
        let side = (size + 2 * quiet) * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for y in 0..<size {
            for x in 0..<size where modules[y * size + x] {
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
            #expect(decode(size: code.size, modules: code.modules) == message, "version \(code.version), level \(level), mask \(code.mask)")
        }
    }

    @Test func everyVersionFromOneToTenDecodes() throws {
        for version in 1...10 {
            // The longest message that still needs this version at level M.
            let capacity = [1: 14, 2: 26, 3: 42, 4: 62, 5: 84, 6: 106, 7: 122, 8: 152, 9: 180, 10: 213][version] ?? 1
            let message = String((0..<capacity).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement() ?? "a" })
            let code = try QRCode(text: message)
            #expect(code.version == version)
            #expect(decode(size: code.size, modules: code.modules, scale: 6) == message, "version \(version)")
        }
    }

    /// The longest message for each version from 11 to 20 at level M, which only the page's encoder makes, then a WireGuard configuration as the
    /// box writes it for a device (44-character keys, the box's address as the endpoint).
    @Test(.enabled(if: QRCodeTests.node != nil, "node is not on the PATH"))
    func aPhonesDecoderReadsThePagesLargerCodes() throws {
        let capacities = [251, 287, 331, 362, 412, 450, 504, 560, 624, 666]
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        // Fixed messages, so a code Core Image can't read is the same code the next time.
        var messages = capacities.enumerated().map { index, length in String((0..<length).map { letters[($0 * 7 + index) % letters.count] }) }
        messages.append(AwayRules.wireGuardConfig(privateKey: Self.countingKey(from: 0), address: "10.123.45.2", boxPublicKey: Self.countingKey(from: 32),
                                                  endpoint: "[2001:db8:4:7000:1a2b:3c4d:5e6f:7a8b]:51820", allowedIPs: ["10.123.45.1/32", "192.0.2.10/32"]))
        let codes = try pageCodes(messages.map { (text: $0, level: "M") })
        try #require(codes.count == messages.count)
        for (index, message) in messages.enumerated() {
            let code = codes[index]
            if index < capacities.count { #expect(code.version == 11 + index, "\(message.count) characters") }
            #expect(decode(size: code.size, modules: code.dark) == message, "version \(code.version), mask \(code.mask)")
        }
        #expect((codes.last?.version ?? 99) <= 14, "the configuration fits version 14")
    }
    #endif

    // MARK: The page's encoder

    /// The page's own encoder (`linux/web/js/qr.js`), a port of this one extended to version 20: Settings shows a WireGuard device's
    /// configuration with it, once.
    private static let pageEncoder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // Packages/CameraBridgeKit
        .deletingLastPathComponent().deletingLastPathComponent()                             // the repository
        .appending(path: "linux/web/js/qr.js")

    /// `node` on the PATH, which runs the page's encoder. Without it (the Linux container, a bare machine) the page's codes are not compared.
    static let node: String? = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        .map { "\($0)/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }

    /// A code the page's encoder made.
    private struct PageCode: Decodable {
        var version: Int
        var size: Int
        var mask: Int
        /// Row by row, "1" for a dark module.
        var modules: String
        var dark: [Bool] { modules.map { $0 == "1" } }
    }

    /// A key-shaped value, the base64 of 32 counting bytes: the length of a WireGuard key, and nobody's key.
    private static func countingKey(from start: Int) -> String {
        Data((0..<32).map { UInt8(start + $0) }).base64EncodedString()
    }

    /// The page's codes for `cases` (a message and its level, "L" or "M"), made by `node` running `qr.js` from this checkout.
    private func pageCodes(_ cases: [(text: String, level: String)]) throws -> [PageCode] {
        let node = try #require(Self.node)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // The module's address is a JSON string, which is a JavaScript string too. The messages go as base64 of their JSON: on macOS, Process
        // hands a program its arguments in the file system's Unicode form, which decomposes "é" into "e" and a combining accent, so the page
        // would encode other bytes than this encoder does.
        let module = String(decoding: try encoder.encode(Self.pageEncoder.absoluteString), as: UTF8.self)
        let list = try encoder.encode(cases.map { [$0.text, $0.level] }).base64EncodedString()
        let script = """
        import { encodeQR } from \(module);
        const cases = JSON.parse(Buffer.from('\(list)', 'base64').toString('utf8'));
        const codes = cases.map(([text, level]) => encodeQR(text, { level }));
        process.stdout.write(JSON.stringify(codes.map(({ version, size, mask, modules }) => ({ version, size, mask, modules: modules.join('') }))));
        """
        // ClipTools.run (ClipLabelTests) runs a program with its output in files, which hold the larger codes a pipe's buffer would not.
        let run = try ClipTools.run(node, ["--input-type=module", "-e", script], timeout: 60)
        try #require(run.status == 0, "node: \(run.errors)")
        return try JSONDecoder().decode([PageCode].self, from: run.data)
    }

    /// The page's encoder gives exactly this one's codes: the same version, the same mask and every module the same, at L and M.
    @Test(.enabled(if: QRCodeTests.node != nil, "node is not on the PATH"))
    func thePagesEncoderMatchesThisOne() throws {
        let messages = ["X-HM://00GW95DQA7OSX", "A", String(repeating: "x", count: 150), "héllo wörld ✓"]
        let cases = messages.flatMap { text in [(text: text, level: "L"), (text: text, level: "M")] }
        let codes = try pageCodes(cases)
        try #require(codes.count == cases.count)
        for (index, item) in cases.enumerated() {
            let code = try QRCode(text: item.text, errorCorrection: item.level == "L" ? .low : .medium)
            let page = codes[index]
            #expect(page.version == code.version, "\(item.level): \(item.text)")
            #expect(page.size == code.size, "\(item.level): \(item.text)")
            #expect(page.mask == code.mask, "\(item.level): \(item.text)")
            #expect(page.dark == code.modules, "\(item.level): \(item.text), version \(code.version)")
        }
    }
}
