import Foundation

/// How big a picture is, in pixels.
public struct SkyPictureSize: Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// An entry's picture as the grid of the Sky Watcher's log asks for it (`BridgeEngine.skyStillThumbnail`): the small one the box keeps beside the
/// still (`isThumbnail`), or, when a small one could not be made, the whole still, which is what the card then shows instead.
public struct SkyStillPicture: Sendable, Equatable {
    public var jpeg: Data
    public var isThumbnail: Bool

    public init(jpeg: Data, isThumbnail: Bool) {
        self.jpeg = jpeg
        self.isThumbnail = isThumbnail
    }
}

/// What the box reads of a JPEG without decoding it.
enum JPEGHeader {
    /// The width and height in the frame header of `data` (a JPEG, baseline or progressive), or nil when it is not one, is cut off before its frame
    /// header, or says a side is 0. The segments before the frame header are stepped over by their lengths, so a big application segment is no
    /// obstacle; what follows the header is not looked at.
    static func size(of data: Data) -> SkyPictureSize? {
        data.withUnsafeBytes { raw -> SkyPictureSize? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            guard count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
            var index = 2
            while index + 4 <= count {
                guard bytes[index] == 0xFF else {
                    index += 1
                    continue
                }
                let marker = bytes[index + 1]
                if marker == 0xFF {   // a fill byte
                    index += 1
                    continue
                }
                if marker == 0x00 || marker == 0x01 || marker == 0xD8 || (0xD0...0xD7).contains(marker) {   // markers with no length
                    index += 2
                    continue
                }
                if marker == 0xD9 || marker == 0xDA { return nil }   // the end, or the scan before any frame header
                let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
                // The start of a frame: SOF0…SOF15 except the tables that share their numbers (DHT, JPG, DAC).
                if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                    guard index + 9 <= count else { return nil }
                    let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                    let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
                    return width > 0 && height > 0 ? SkyPictureSize(width: width, height: height) : nil
                }
                guard length >= 2 else { return nil }
                index += 2 + length
            }
            return nil
        }
    }
}
