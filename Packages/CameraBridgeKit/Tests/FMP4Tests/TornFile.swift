import Foundation

/// What a repair keeps of a file that may be torn anywhere: the init segment and the `[prft] moof mdat` units that are whole.
enum TornFile {
    struct Whole {
        /// The end of the last whole unit (the init segment's end when no fragment is whole, 0 when the init segment itself is torn).
        var end: Int
        /// The byte range of each whole fragment (`prft` through the end of `mdat`).
        var fragments: [Range<Int>]
    }

    static func wholeFragments(in data: Data) -> Whole {
        var position = 0
        var whole = Whole(end: 0, fragments: [])
        var unitStart: Int?
        var sawMoof = false
        let bytes = Bytes(data)
        while data.count - position >= 8 {
            let size = Int(bytes.u32(position))
            let type = bytes.fourCC(position + 4)
            guard size >= 8, size <= data.count - position else { break }
            switch type {
            case "ftyp", "moov": whole.end = position + size
            case "prft": unitStart = position
            case "moof":
                sawMoof = true
                unitStart = unitStart ?? position
            case "mdat" where sawMoof:
                whole.fragments.append((unitStart ?? position)..<position + size)
                whole.end = position + size
                sawMoof = false
                unitStart = nil
            default: break
            }
            position += size
        }
        return whole
    }
}
