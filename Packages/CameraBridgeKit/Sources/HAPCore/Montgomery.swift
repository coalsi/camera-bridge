import BigInt

/// Montgomery arithmetic for a fixed odd modulus (the SRP group prime).
///
/// BigInt's generic `power(_:modulus:)` is correct but, like every SwiftPM dependency, it is compiled without
/// optimization in Debug builds, which made one SRP exchange take tens of seconds. This implementation works on
/// flat `UInt64` limb buffers (CIOS Montgomery multiplication, 4-bit fixed window) and stays fast unoptimized.
///
/// Side channels (best effort — Swift gives no constant-time guarantee, but nothing here branches on or indexes
/// memory by secret data): the exponent is scanned in fixed 4-bit windows over all of its 64-bit words (no
/// skipping of zero windows or leading zeros inside the top word), every window does 4 squarings and one
/// multiplication, the window table is read with a masked scan of all 16 entries, and the final Montgomery
/// subtraction and the modular reduction/addition helpers select results with masks. Only the exponent's
/// word count (64-bit granularity) is observable.
struct MontgomeryContext: Sendable {
    let limbCount: Int
    private let modulus: [UInt64]        // little-endian limbs
    private let n0inv: UInt64            // -modulus⁻¹ mod 2⁶⁴
    private let rSquared: [UInt64]       // R² mod modulus, R = 2^(64·limbCount)
    private let oneMont: [UInt64]        // R mod modulus
    private let one: [UInt64]            // 1
    private let modulusBig: BigUInt

    init(modulus: BigUInt) {
        precondition(modulus > 1 && (modulus.words.first ?? 0) & 1 == 1, "Montgomery modulus must be odd")
        modulusBig = modulus
        limbCount = modulus.words.count
        self.modulus = Self.limbs(modulus, count: limbCount)
        // Newton iteration for the inverse of modulus[0] modulo 2^64.
        var inverse: UInt64 = 1
        for _ in 0..<6 { inverse = inverse &* (2 &- self.modulus[0] &* inverse) }
        n0inv = 0 &- inverse
        let r = BigUInt(1) << (64 * limbCount)
        oneMont = Self.limbs(r % modulus, count: limbCount)
        rSquared = Self.limbs((r * r) % modulus, count: limbCount)
        var one = [UInt64](repeating: 0, count: limbCount)
        one[0] = 1
        self.one = one
    }

    /// base^exponent mod modulus.
    func power(_ base: BigUInt, _ exponent: BigUInt) -> BigUInt {
        let baseMont = multiply(reduced(base), rSquared)
        // Window table: base^0 … base^15 in Montgomery form.
        var table = [oneMont, baseMont]
        for i in 2..<16 { table.append(multiply(table[i - 1], baseMont)) }
        var result = oneMont
        for word in exponent.words.reversed() {
            for nibbleIndex in stride(from: 15, through: 0, by: -1) {
                for _ in 0..<4 { result = multiply(result, result) }
                let nibble = (UInt64(word) >> UInt64(nibbleIndex * 4)) & 0xF
                result = multiply(result, select(table, index: nibble))
            }
        }
        return Self.bigUInt(multiply(result, one))
    }

    /// (a · b) mod modulus.
    func multiply(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        let aMont = multiply(reduced(a), rSquared)                 // a·R
        return Self.bigUInt(multiply(aMont, reduced(b)))           // a·R·b·R⁻¹ = a·b
    }

    /// (a + b) mod modulus.
    func add(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        let x = reduced(a), y = reduced(b)
        var sum = [UInt64](repeating: 0, count: limbCount + 1)
        var carry: UInt64 = 0
        for j in 0..<limbCount {
            let wide = UInt128(x[j]) &+ UInt128(y[j]) &+ UInt128(carry)
            sum[j] = UInt64(truncatingIfNeeded: wide)
            carry = UInt64(truncatingIfNeeded: wide >> 64)
        }
        sum[limbCount] = carry
        conditionalSubtract(&sum)
        return Self.bigUInt(Array(sum[0..<limbCount]))
    }

    /// `value` as `limbCount` limbs, fully reduced. Values below 2^(64·limbCount) need at most one subtraction
    /// when modulus > 2^(64·limbCount − 1) (true for the SRP prime); anything else falls back to BigInt division.
    private func reduced(_ value: BigUInt) -> [UInt64] {
        guard value.words.count <= limbCount, modulus[limbCount - 1] >> 63 == 1 else {
            return Self.limbs(value % modulusBig, count: limbCount)
        }
        var t = Self.limbs(value, count: limbCount + 1)
        conditionalSubtract(&t)
        return Array(t[0..<limbCount])
    }

    /// Masked scan of every table entry; returns `table[index]`.
    private func select(_ table: [[UInt64]], index: UInt64) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: limbCount)
        for (i, entry) in table.enumerated() {
            let difference = UInt64(i) ^ index
            let mask = ((difference | (0 &- difference)) >> 63) &- 1   // all ones iff i == index
            for j in 0..<limbCount { out[j] |= entry[j] & mask }
        }
        return out
    }

    /// For `t` with `limbCount + 1` limbs and t < 2·modulus: t ← t − modulus if t ≥ modulus, selected by mask.
    /// Afterwards `t[limbCount] == 0`.
    private func conditionalSubtract(_ t: inout [UInt64]) {
        let count = limbCount
        var difference = [UInt64](repeating: 0, count: count)
        var borrow: UInt64 = 0
        for j in 0..<count {
            let wide = UInt128(t[j]) &- UInt128(modulus[j]) &- UInt128(borrow)
            difference[j] = UInt64(truncatingIfNeeded: wide)
            borrow = UInt64(truncatingIfNeeded: wide >> 127)
        }
        // t − modulus is negative iff the top limb cannot absorb the borrow.
        let top = UInt128(t[count]) &- UInt128(borrow)
        let keepMask = 0 &- UInt64(truncatingIfNeeded: top >> 127)     // all ones → t < modulus, keep t
        for j in 0..<count { t[j] = (t[j] & keepMask) | (difference[j] & ~keepMask) }
        t[count] = 0
    }

    /// Montgomery product a·b·R⁻¹ mod modulus (CIOS). Inputs and output are fully reduced.
    private func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let count = limbCount
        var t = [UInt64](repeating: 0, count: count + 2)
        t.withUnsafeMutableBufferPointer { t in
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    modulus.withUnsafeBufferPointer { n in
                        for i in 0..<count {
                            var carry: UInt64 = 0
                            let ai = a[i]
                            for j in 0..<count {
                                let (hi, lo) = ai.multipliedFullWidth(by: b[j])
                                let (s1, c1) = t[j].addingReportingOverflow(lo)
                                let (s2, c2) = s1.addingReportingOverflow(carry)
                                t[j] = s2
                                carry = hi &+ Self.bit(c1) &+ Self.bit(c2)
                            }
                            let (s, c) = t[count].addingReportingOverflow(carry)
                            t[count] = s
                            t[count + 1] = Self.bit(c)

                            let m = t[0] &* n0inv
                            let (hi0, lo0) = m.multipliedFullWidth(by: n[0])
                            let (_, c0) = t[0].addingReportingOverflow(lo0)
                            carry = hi0 &+ Self.bit(c0)
                            for j in 1..<count {
                                let (hi, lo) = m.multipliedFullWidth(by: n[j])
                                let (s1, c1) = t[j].addingReportingOverflow(lo)
                                let (s2, c2) = s1.addingReportingOverflow(carry)
                                t[j - 1] = s2
                                carry = hi &+ Self.bit(c1) &+ Self.bit(c2)
                            }
                            let (s3, c3) = t[count].addingReportingOverflow(carry)
                            t[count - 1] = s3
                            t[count] = t[count + 1] &+ Self.bit(c3)
                            t[count + 1] = 0
                        }
                    }
                }
            }
        }
        // Result < 2·modulus: one masked subtraction reduces it.
        var reducedT = Array(t[0...count])
        conditionalSubtract(&reducedT)
        return Array(reducedT[0..<count])
    }

    /// 0 or 1 without a data-dependent branch (Bool's storage is 0/1).
    @inline(__always) private static func bit(_ flag: Bool) -> UInt64 {
        UInt64(unsafeBitCast(flag, to: UInt8.self))
    }

    private static func limbs(_ value: BigUInt, count: Int) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: count)
        for (i, word) in value.words.enumerated() where i < count { out[i] = UInt64(word) }
        return out
    }

    private static func bigUInt(_ limbs: [UInt64]) -> BigUInt {
        BigUInt(words: limbs.map { UInt($0) })
    }
}
