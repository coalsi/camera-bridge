import Foundation

/// One ISO/IEC 14496-12 box. `offset` is where its header starts, relative to the start of the parsed data; `size` includes
/// the header. `children` is filled for the container boxes `MP4BoxReader` descends into.
public struct MP4Box: Sendable {
    public var type: String
    public var offset: Int
    public var size: Int
    public var children: [MP4Box]
    /// 8, or 16 with a 64-bit size, plus 16 for `uuid` boxes.
    public var headerSize: Int

    public init(type: String, offset: Int, size: Int, children: [MP4Box] = [], headerSize: Int = 8) {
        self.type = type
        self.offset = offset
        self.size = size
        self.children = children
        self.headerSize = headerSize
    }

    /// First byte after the header.
    public var payloadOffset: Int { offset + headerSize }
    public var payloadSize: Int { size - headerSize }

    /// First direct child of the given type.
    public func child(_ type: String) -> MP4Box? { children.first { $0.type == type } }

    /// Direct children of the given type, in file order.
    public func children(ofType type: String) -> [MP4Box] { children.filter { $0.type == type } }

    /// Follows first matches below this box, e.g. `"mdia/minf/stbl"`.
    public func descendant(atPath path: String) -> MP4Box? {
        MP4BoxReader.box(atPath: path, in: children)
    }
}

/// Parses a box sequence (a whole file, an init segment, a fragment…) without copying payloads.
public enum MP4BoxReader {
    /// Deepest container nesting accepted (the deepest real path, `moov/trak/mdia/minf/stbl/stsd/hvc1/hvcC`, is 8).
    public static let maximumDepth = 32

    /// Recursive for container boxes: `moov trak mdia minf stbl mvex moof traf dinf edts udta mfra tref sinf schi`, the full
    /// boxes `stsd dref meta`, and the sample entries `avc1 avc3 hvc1 hev1 encv mp4v mp4a enca`. Throws
    /// `FMP4Error.malformedBox` when a size is inconsistent or data is truncated; empty data yields no boxes.
    public static func parse(_ data: Data) throws -> [MP4Box] {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> [MP4Box] in
            try parseSequence(raw, from: 0, to: raw.count, depth: 0, lenientTerminator: false)
        }
    }

    /// First match of a slash-separated path of box types, starting at `boxes` (e.g. `"moov/trak/mdia/mdhd"`).
    public static func box(atPath path: String, in boxes: [MP4Box]) -> MP4Box? {
        var level = boxes
        var found: MP4Box?
        for component in path.split(separator: "/") {
            guard let next = level.first(where: { $0.type == component }) else { return nil }
            found = next
            level = next.children
        }
        return found
    }

    private static func parseSequence(_ raw: UnsafeRawBufferPointer, from start: Int, to end: Int, depth: Int,
                                      lenientTerminator: Bool) throws -> [MP4Box] {
        guard depth <= maximumDepth else { throw FMP4Error.malformedBox(offset: start, reason: "nested deeper than \(maximumDepth) levels") }
        var boxes: [MP4Box] = []
        var cursor = start
        while cursor < end {
            let remaining = end - cursor
            if remaining < 8 {
                // QuickTime allows a 32-bit zero terminator at the end of a container's children.
                if lenientTerminator, (cursor..<end).allSatisfy({ raw[$0] == 0 }) { break }
                throw FMP4Error.malformedBox(offset: cursor, reason: "truncated box header (\(remaining) bytes left)")
            }
            let size32 = readU32(raw, cursor)
            let type = fourCC(raw, cursor + 4)
            var headerSize = 8
            var size: Int
            switch size32 {
            case 0:
                size = remaining
            case 1:
                guard remaining >= 16 else { throw FMP4Error.malformedBox(offset: cursor, reason: "truncated 64-bit size") }
                let large = UInt64(readU32(raw, cursor + 8)) << 32 | UInt64(readU32(raw, cursor + 12))
                guard large >= 16 else { throw FMP4Error.malformedBox(offset: cursor, reason: "64-bit size \(large) below its header") }
                guard large <= UInt64(remaining) else { throw FMP4Error.malformedBox(offset: cursor, reason: "'\(type)' extends past its parent") }
                size = Int(large)
                headerSize = 16
            default:
                guard size32 >= 8 else { throw FMP4Error.malformedBox(offset: cursor, reason: "size \(size32) below the header size") }
                size = Int(size32)
            }
            guard size <= remaining else { throw FMP4Error.malformedBox(offset: cursor, reason: "'\(type)' extends past its parent") }
            if type == "uuid" {
                headerSize += 16
                guard size >= headerSize else { throw FMP4Error.malformedBox(offset: cursor, reason: "uuid box without its extended type") }
            }
            var box = MP4Box(type: type, offset: cursor, size: size, headerSize: headerSize)
            let payloadStart = cursor + headerSize
            let payloadEnd = cursor + size
            if let skip = childrenOffset(type: type, raw: raw, payloadStart: payloadStart, payloadEnd: payloadEnd) {
                guard payloadStart + skip <= payloadEnd else {
                    throw FMP4Error.malformedBox(offset: cursor, reason: "'\(type)' shorter than its fixed fields")
                }
                box.children = try parseSequence(raw, from: payloadStart + skip, to: payloadEnd, depth: depth + 1, lenientTerminator: true)
            }
            boxes.append(box)
            cursor += size
        }
        return boxes
    }

    /// Bytes between a container's header and its first child, or nil for leaf boxes.
    private static func childrenOffset(type: String, raw: UnsafeRawBufferPointer, payloadStart: Int, payloadEnd: Int) -> Int? {
        switch type {
        case "moov", "trak", "mdia", "minf", "stbl", "mvex", "moof", "traf", "dinf", "edts", "udta", "mfra", "tref", "sinf", "schi":
            return 0
        case "stsd", "dref":
            return 8                                            // version/flags + entry_count
        case "meta":
            // ISO full box (version/flags first) unless it is QuickTime's plain container, whose first child is 'hdlr'.
            let quickTime = payloadEnd - payloadStart >= 8 && fourCC(raw, payloadStart + 4) == "hdlr"
            return quickTime ? 0 : 4
        case "avc1", "avc3", "hvc1", "hev1", "encv", "mp4v":
            return 78                                           // VisualSampleEntry fixed fields
        case "mp4a", "enca":
            // AudioSampleEntry: 28 bytes; QuickTime sound description versions 1 and 2 add 16 / 36 bytes.
            guard payloadEnd - payloadStart >= 10 else { return 28 }
            switch UInt16(raw[payloadStart + 8]) << 8 | UInt16(raw[payloadStart + 9]) {
            case 1: return 44
            case 2: return 64
            default: return 28
            }
        default:
            return nil
        }
    }

    private static func readU32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(raw[offset]) << 24 | UInt32(raw[offset + 1]) << 16 | UInt32(raw[offset + 2]) << 8 | UInt32(raw[offset + 3])
    }

    /// Four bytes as ISO Latin-1 (so types like `©nam` survive).
    private static func fourCC(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for index in offset..<offset + 4 { scalars.append(Unicode.Scalar(raw[index])) }
        return String(scalars)
    }
}
