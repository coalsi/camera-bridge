import Foundation

/// A small QR Code encoder (ISO/IEC 18004, byte mode, versions 1 to 10, error correction L or M) that draws SVG, so the server can
/// show Apple Home setup codes (`X-HM://…`, 20 characters: version 2) without an image library. After Project Nayuki's reference
/// implementation (MIT): the same steps (data bits, Reed-Solomon over GF(256)/0x11D, interleaving, zig-zag placement, the eight
/// masks scored by the standard penalty rules, format and version information).
public struct QRCode: Sendable, Equatable {
    public enum ErrorCorrection: Int, Sendable { case low = 0, medium = 1 }

    public enum Failure: Error, Equatable, Sendable { case tooLong }

    public let version: Int
    public let size: Int
    public let mask: Int
    /// Row-major, `true` = dark.
    public let modules: [Bool]

    public func isDark(x: Int, y: Int) -> Bool {
        x >= 0 && x < size && y >= 0 && y < size && modules[y * size + x]
    }

    // Tables for versions 1...10 (index 0 unused), per error correction level.
    private static let eccCodewordsPerBlock: [[Int]] = [
        [0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18],
        [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26],
    ]
    private static let blockCount: [[Int]] = [
        [0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4],
        [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5],
    ]
    /// Format bits' error correction field (L = 01, M = 00).
    private static let formatBits = [1, 0]
    static let maximumVersion = 10

    public init(text: String, errorCorrection: ErrorCorrection = .medium) throws {
        let data = Array(text.utf8)
        let level = errorCorrection.rawValue
        var version = 1
        var capacityBits = 0
        while true {
            let countBits = version < 10 ? 8 : 16
            capacityBits = Self.dataCodewords(version: version, level: level) * 8
            if 4 + countBits + data.count * 8 <= capacityBits { break }
            version += 1
            if version > Self.maximumVersion { throw Failure.tooLong }
        }
        // Data bits: mode 0100 (bytes), character count, the bytes, terminator, padding.
        var bits: [Bool] = []
        func append(_ value: Int, _ count: Int) {
            for shift in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> shift) & 1 == 1) }
        }
        append(0b0100, 4)
        append(data.count, version < 10 ? 8 : 16)
        for byte in data { append(Int(byte), 8) }
        append(0, min(4, capacityBits - bits.count))
        append(0, (8 - bits.count % 8) % 8)
        var pad = 0xEC
        while bits.count < capacityBits {
            append(pad, 8)
            pad ^= 0xEC ^ 0x11
        }
        var codewords = [UInt8](repeating: 0, count: bits.count / 8)
        for (index, bit) in bits.enumerated() where bit { codewords[index / 8] |= 1 << (7 - UInt8(index % 8)) }

        let all = Self.addErrorCorrectionAndInterleave(codewords, version: version, level: level)
        let size = version * 4 + 17
        var grid = Grid(size: size)
        grid.drawFunctionPatterns(version: version, formatBits: Self.formatBits[level])
        grid.drawCodewords(all)
        var bestMask = 0
        var bestPenalty = Int.max
        for candidate in 0..<8 {
            grid.applyMask(candidate)
            grid.drawFormatBits(mask: candidate, formatBits: Self.formatBits[level])
            let penalty = grid.penaltyScore()
            if penalty < bestPenalty {
                bestPenalty = penalty
                bestMask = candidate
            }
            grid.applyMask(candidate)   // undo (xor)
        }
        grid.applyMask(bestMask)
        grid.drawFormatBits(mask: bestMask, formatBits: Self.formatBits[level])
        self.version = version
        self.size = size
        self.mask = bestMask
        self.modules = grid.modules
    }

    /// The code as a standalone SVG (black modules on a white square, with the quiet zone the standard asks for). Run-length
    /// merged into one path, so a version 2 code is a few hundred bytes.
    public func svg(quietZone: Int = 4, dark: String = "#000", light: String = "#fff") -> String {
        let total = size + 2 * quietZone
        var path = ""
        for y in 0..<size {
            var x = 0
            while x < size {
                guard isDark(x: x, y: y) else {
                    x += 1
                    continue
                }
                var end = x
                while end < size, isDark(x: end, y: y) { end += 1 }
                path += "M\(x + quietZone),\(y + quietZone)h\(end - x)v1h-\(end - x)z"
                x = end
            }
        }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(total) \(total)\" role=\"img\" aria-label=\"QR code\" shape-rendering=\"crispEdges\">"
            + "<rect width=\"\(total)\" height=\"\(total)\" fill=\"\(light)\"/><path d=\"\(path)\" fill=\"\(dark)\"/></svg>"
    }

    // MARK: Capacity

    private static func rawModules(version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let alignments = version / 7 + 2
            result -= (25 * alignments - 10) * alignments - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    private static func dataCodewords(version: Int, level: Int) -> Int {
        rawModules(version: version) / 8 - eccCodewordsPerBlock[level][version] * blockCount[level][version]
    }

    private static func addErrorCorrectionAndInterleave(_ data: [UInt8], version: Int, level: Int) -> [UInt8] {
        let blocks = blockCount[level][version]
        let eccLength = eccCodewordsPerBlock[level][version]
        let rawCodewords = rawModules(version: version) / 8
        let shortBlocks = blocks - rawCodewords % blocks
        let shortLength = rawCodewords / blocks
        let divisor = reedSolomonDivisor(degree: eccLength)
        var result = [[UInt8]]()
        var offset = 0
        for index in 0..<blocks {
            let length = shortLength - eccLength + (index < shortBlocks ? 0 : 1)
            let chunk = Array(data[offset..<(offset + length)])
            offset += length
            let ecc = reedSolomonRemainder(chunk, divisor)
            var block = chunk
            if index < shortBlocks { block.append(0) }   // placeholder keeps blocks the same length while interleaving
            block.append(contentsOf: ecc)
            result.append(block)
        }
        var interleaved: [UInt8] = []
        for column in 0..<result[0].count {
            for (index, block) in result.enumerated() {
                // Skip the placeholder of a short block.
                if column == shortLength - eccLength, index < shortBlocks { continue }
                interleaved.append(block[column])
            }
        }
        return interleaved
    }

    // MARK: Reed-Solomon

    private static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for bit in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> bit) & 1) * Int(x)
        }
        return UInt8(z & 0xFF)
    }

    private static func reedSolomonDivisor(degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = multiply(result[j], root)
                if j + 1 < degree { result[j] ^= result[j + 1] }
            }
            root = multiply(root, 0x02)
        }
        return result
    }

    private static func reedSolomonRemainder(_ data: [UInt8], _ divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for (index, coefficient) in divisor.enumerated() { result[index] ^= multiply(coefficient, factor) }
        }
        return result
    }

    // MARK: Drawing

    private struct Grid {
        let size: Int
        var modules: [Bool]
        var function: [Bool]

        init(size: Int) {
            self.size = size
            modules = [Bool](repeating: false, count: size * size)
            function = [Bool](repeating: false, count: size * size)
        }

        mutating func set(_ x: Int, _ y: Int, _ dark: Bool, function isFunction: Bool = true) {
            modules[y * size + x] = dark
            if isFunction { function[y * size + x] = true }
        }

        mutating func drawFunctionPatterns(version: Int, formatBits: Int) {
            for i in 0..<size {
                set(6, i, i % 2 == 0)
                set(i, 6, i % 2 == 0)
            }
            drawFinder(3, 3)
            drawFinder(size - 4, 3)
            drawFinder(3, size - 4)
            let positions = Self.alignmentPositions(version: version)
            for (i, x) in positions.enumerated() {
                for (j, y) in positions.enumerated() {
                    if (i == 0 && j == 0) || (i == 0 && j == positions.count - 1) || (i == positions.count - 1 && j == 0) { continue }
                    drawAlignment(x, y)
                }
            }
            drawFormatBits(mask: 0, formatBits: formatBits)
            drawVersion(version)
        }

        private mutating func drawFinder(_ cx: Int, _ cy: Int) {
            for dy in -4...4 {
                for dx in -4...4 {
                    let x = cx + dx, y = cy + dy
                    guard x >= 0, x < size, y >= 0, y < size else { continue }
                    let distance = max(abs(dx), abs(dy))
                    set(x, y, distance != 2 && distance != 4)
                }
            }
        }

        private mutating func drawAlignment(_ cx: Int, _ cy: Int) {
            for dy in -2...2 {
                for dx in -2...2 { set(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1) }
            }
        }

        static func alignmentPositions(version: Int) -> [Int] {
            if version == 1 { return [] }
            let count = version / 7 + 2
            let size = version * 4 + 17
            let step = version == 32 ? 26 : (version * 4 + count * 2 + 1) / (count * 2 - 2) * 2
            var result = [6]
            var position = size - 7
            while result.count < count {
                result.insert(position, at: 1)
                position -= step
            }
            return result
        }

        mutating func drawFormatBits(mask: Int, formatBits: Int) {
            let data = formatBits << 3 | mask
            var remainder = data
            for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
            let bits = (data << 10 | remainder) ^ 0x5412
            func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }
            for i in 0...5 { set(8, i, bit(i)) }
            set(8, 7, bit(6))
            set(8, 8, bit(7))
            set(7, 8, bit(8))
            for i in 9..<15 { set(14 - i, 8, bit(i)) }
            for i in 0..<8 { set(size - 1 - i, 8, bit(i)) }
            for i in 8..<15 { set(8, size - 15 + i, bit(i)) }
            set(8, size - 8, true)
        }

        private mutating func drawVersion(_ version: Int) {
            guard version >= 7 else { return }
            var remainder = version
            for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
            let bits = version << 12 | remainder
            for i in 0..<18 {
                let dark = (bits >> i) & 1 == 1
                let a = size - 11 + i % 3, b = i / 3
                set(a, b, dark)
                set(b, a, dark)
            }
        }

        mutating func drawCodewords(_ data: [UInt8]) {
            var index = 0
            var right = size - 1
            while right >= 1 {
                if right == 6 { right = 5 }
                for vertical in 0..<size {
                    for j in 0..<2 {
                        let x = right - j
                        let upward = ((right + 1) & 2) == 0
                        let y = upward ? size - 1 - vertical : vertical
                        if !function[y * size + x], index < data.count * 8 {
                            modules[y * size + x] = data[index / 8] & (0x80 >> UInt8(index % 8)) != 0
                            index += 1
                        }
                    }
                }
                right -= 2
            }
        }

        mutating func applyMask(_ mask: Int) {
            for y in 0..<size {
                for x in 0..<size where !function[y * size + x] {
                    let invert: Bool
                    switch mask {
                    case 0: invert = (x + y) % 2 == 0
                    case 1: invert = y % 2 == 0
                    case 2: invert = x % 3 == 0
                    case 3: invert = (x + y) % 3 == 0
                    case 4: invert = (x / 3 + y / 2) % 2 == 0
                    case 5: invert = x * y % 2 + x * y % 3 == 0
                    case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0
                    default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
                    }
                    if invert { modules[y * size + x].toggle() }
                }
            }
        }

        func penaltyScore() -> Int {
            var result = 0
            func dark(_ x: Int, _ y: Int) -> Bool { modules[y * size + x] }
            // Rows, then columns: runs of five or more, and finder-like 1:1:3:1:1 patterns.
            for pass in 0..<2 {
                for a in 0..<size {
                    var runColor = false
                    var runLength = 0
                    var history = [Int](repeating: 0, count: 7)
                    for b in 0..<size {
                        let color = pass == 0 ? dark(b, a) : dark(a, b)
                        if color == runColor {
                            runLength += 1
                            if runLength == 5 { result += 3 } else if runLength > 5 { result += 1 }
                        } else {
                            addHistory(runLength, &history)
                            if !runColor { result += patternCount(history) * 40 }
                            runColor = color
                            runLength = 1
                        }
                    }
                    var length = runLength
                    if runColor {   // end the dark run
                        addHistory(length, &history)
                        length = 0
                    }
                    length += size   // the light border after the row
                    addHistory(length, &history)
                    result += patternCount(history) * 40
                }
            }
            // 2x2 blocks of one color.
            for y in 0..<(size - 1) {
                for x in 0..<(size - 1) {
                    let color = dark(x, y)
                    if color == dark(x + 1, y), color == dark(x, y + 1), color == dark(x + 1, y + 1) { result += 3 }
                }
            }
            // Balance of dark and light modules.
            let darkCount = modules.filter { $0 }.count
            let total = size * size
            let k = (abs(darkCount * 20 - total * 10) + total - 1) / total - 1
            result += max(0, k) * 10
            return result
        }

        private func addHistory(_ runLength: Int, _ history: inout [Int]) {
            var length = runLength
            if history[0] == 0 { length += size }   // the light border before the row
            history.removeLast()
            history.insert(length, at: 0)
        }

        private func patternCount(_ history: [Int]) -> Int {
            let n = history[1]
            let core = n > 0 && history[2] == n && history[3] == n * 3 && history[4] == n && history[5] == n
            return (core && history[0] >= n * 4 && history[6] >= n ? 1 : 0) + (core && history[6] >= n * 4 && history[0] >= n ? 1 : 0)
        }
    }
}
