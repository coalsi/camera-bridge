import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

/// Where the box cuts a card's thumbnail (`SkyCloseUp`): the rule is the page's own (`closeUpRect` and `thumbRect` in linux/web/js/screens/sky-model.js),
/// so that the path the page draws over the thumbnail lies where the light was, to the pixel. And how the box reads a still's size
/// (`JPEGHeader`).
@Suite(.timeLimit(.minutes(1))) struct SkyCloseUpTests {
    static func points(_ pairs: [(Double, Double)]) -> [SkyPathPoint] {
        pairs.enumerated().map { SkyPathPoint(t: Double($0.offset), x: $0.element.0, y: $0.element.1) }
    }

    @Test func theRuleIsTheSameAsThePagesCaseByCase() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/sky-closeup-vectors.json")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        #expect(cases.count >= 150)
        var withCloseUp = 0, without = 0
        func numbers(_ value: Any?) -> [Double]? { (value as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } }
        /// A rectangle of the cases as [x, y, width, height]; nil for null.
        func rect(_ value: Any?) -> [Double]? {
            guard let object = value as? [String: Any] else { return nil }
            let sides = ["x", "y", "width", "height"].compactMap { (object[$0] as? NSNumber)?.doubleValue }
            return sides.count == 4 ? sides : nil
        }
        for (index, one) in cases.enumerated() {
            let path = Self.points(try #require(one["path"] as? [[Any]]).map { pair in
                let both = numbers(pair) ?? []
                return (both[0], both[1])
            })
            let picture = try #require(numbers(one["picture"]))
            let (width, height) = (Int(picture[0]), Int(picture[1]))
            let closeUp = SkyCloseUp.rect(path: path, width: width, height: height).map { [$0.x, $0.y, $0.width, $0.height] }
            #expect(closeUp == rect(one["closeUp"]), "case \(index): \(path) in \(width)×\(height): \(String(describing: closeUp)) against \(String(describing: rect(one["closeUp"])))")
            let thumb = SkyCloseUp.pixels(path: path, width: width, height: height).map { [Double($0.x), Double($0.y), Double($0.width), Double($0.height)] }
            #expect(thumb == rect(one["thumb"]), "case \(index): thumb \(String(describing: thumb)) against \(String(describing: rect(one["thumb"])))")
            if thumb != nil { withCloseUp += 1 } else { without += 1 }
        }
        #expect(withCloseUp > 50 && without > 10, "\(withCloseUp) with a close-up, \(without) without")
    }

    @Test func theRuleOnTheOwnersPicture() {
        // 1920 × 852, the owner's stitched camera as the box keeps it: the page's tests have the same cases.
        let width = 1920, height = 852
        let middle = Self.points([(0.45, 0.4), (0.5, 0.42), (0.55, 0.45)])
        let a = SkyCloseUp.rect(path: middle, width: width, height: height)
        #expect(a?.x == 768 && a?.y == 254.1 && a?.width == 384 && a?.height == 216, "the path’s box, half as much more on every side, 16:9: \(String(describing: a))")
        #expect(SkyCloseUp.pixels(path: middle, width: width, height: height) == ImageCrop(x: 768, y: 254, width: 384, height: 216))
        // The smallest close-up is 160 × 90, moved in from an edge or a corner so that it is never cut.
        #expect(SkyCloseUp.pixels(path: Self.points([(0.98, 0.97), (0.995, 0.99)]), width: width, height: height) == ImageCrop(x: 1760, y: 762, width: 160, height: 90))
        #expect(SkyCloseUp.pixels(path: Self.points([(0.01, 0.5), (0.03, 0.52)]), width: width, height: height) == ImageCrop(x: 0, y: 390, width: 160, height: 90))
        #expect(SkyCloseUp.pixels(path: Self.points([(0.5, 0.3)]), width: width, height: height) == ImageCrop(x: 880, y: 211, width: 160, height: 90), "a single point")
        // A light that crossed more of the sky than a close-up holds: the whole picture is its view.
        #expect(SkyCloseUp.rect(path: Self.points([(0.05, 0.1), (0.95, 0.9)]), width: width, height: height) == nil)
        #expect(SkyCloseUp.pixels(path: Self.points([(0.05, 0.1), (0.95, 0.9)]), width: width, height: height) == nil)
    }

    @Test func thereIsNothingToCutWithoutAPointOrAPictureSize() {
        let path = Self.points([(0.5, 0.5)])
        #expect(SkyCloseUp.pixels(path: [], width: 1920, height: 852) == nil)
        #expect(SkyCloseUp.pixels(path: path, width: 0, height: 852) == nil)
        #expect(SkyCloseUp.pixels(path: path, width: 1920, height: 0) == nil)
        #expect(SkyCloseUp.pixels(path: path, width: -5, height: 10) == nil)
        // Points that are not numbers are left out, as the page leaves them.
        let broken = [SkyPathPoint(t: 0, x: .nan, y: 0.5), SkyPathPoint(t: 1, x: 0.5, y: .infinity)]
        #expect(SkyCloseUp.pixels(path: broken, width: 1920, height: 852) == nil)
        #expect(SkyCloseUp.pixels(path: broken + path, width: 1920, height: 852) == SkyCloseUp.pixels(path: path, width: 1920, height: 852))
    }

    @Test func aCloseUpIsAlwaysWholePixelsInsideThePicture() {
        for (width, height) in [(1920, 852), (1921, 853), (400, 177), (640, 360), (1920, 540), (2559, 1439)] {
            for x in stride(from: 0.0, through: 1.0, by: 0.05) {
                for y in stride(from: 0.0, through: 1.0, by: 0.1) {
                    for spread in [0.0, 0.01, 0.08, 0.2] {
                        let path = Self.points([(x, y), (min(1, x + spread), min(1, y + spread / 2))])
                        guard let crop = SkyCloseUp.pixels(path: path, width: width, height: height) else { continue }
                        #expect(crop.x >= 0 && crop.y >= 0 && crop.width > 0 && crop.height > 0 && crop.x + crop.width <= width && crop.y + crop.height <= height,
                                "\(crop) in \(width)×\(height)")
                    }
                }
            }
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct JPEGHeaderTests {
    /// A JPEG as far as its header goes: start of image, an application segment, a table, the frame header (`marker`: 0xC0 baseline, 0xC2 progressive).
    static func header(_ width: Int, _ height: Int, marker: UInt8 = 0xC0) -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) + Data(count: 14)
        data += Data([0xFF, 0xDB, 0x00, 0x05, 1, 2, 3])
        data += Data([0xFF, marker, 0x00, 0x0B, 0x08, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 0x01, 0x01, 0x11, 0x00])
        return data + Data(count: 20) + Data([0xFF, 0xD9])
    }

    @Test func theSizeComesFromTheFrameHeader() {
        #expect(JPEGHeader.size(of: Self.header(1920, 852)) == SkyPictureSize(width: 1920, height: 852))
        #expect(JPEGHeader.size(of: Self.header(480, 640, marker: 0xC2)) == SkyPictureSize(width: 480, height: 640), "progressive too")
        #expect(JPEGHeader.size(of: Self.header(65_535, 1)) == SkyPictureSize(width: 65_535, height: 1))
    }

    @Test func otherDataHasNoSize() {
        #expect(JPEGHeader.size(of: Data()) == nil)
        #expect(JPEGHeader.size(of: Data("GIF89a".utf8)) == nil)
        #expect(JPEGHeader.size(of: Data([0xFF, 0xD8, 0xFF])) == nil)
        #expect(JPEGHeader.size(of: Data([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x04, 0, 0])) == nil, "the start of the scan before any frame header")
        #expect(JPEGHeader.size(of: Self.header(0, 100)) == nil, "no width")
        #expect(JPEGHeader.size(of: Self.header(100, 0)) == nil, "no height (a height set after the scan is not looked for)")
        #expect(JPEGHeader.size(of: Self.header(100, 100).prefix(20)) == nil, "cut short")
        #expect(JPEGHeader.size(of: Data([0x89, 0x50, 0x4E, 0x47]) + Data(count: 30)) == nil, "a PNG is not a still")
    }

    @Test func aBigApplicationSegmentIsSkippedNotRead() {
        // The frame header of a picture with a big application segment (a thumbnail in its Exif) is further in than a few hundred bytes.
        let big = Data([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFE]) + Data(count: 0xFFFC)
        let data = big + Self.header(1920, 1080).dropFirst(2)
        #expect(JPEGHeader.size(of: data) == SkyPictureSize(width: 1920, height: 1080))
    }
}
