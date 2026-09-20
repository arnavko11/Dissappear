import Foundation

/// Minimal arbitrary-precision unsigned integer, enough for the 2048-bit
/// modular arithmetic SRP needs. Limbs are 32-bit, little-endian, with no
/// trailing zeros.
///
/// The algorithms here (schoolbook multiply, Knuth algorithm D division,
/// square-and-multiply modular exponentiation) were validated against a
/// reference implementation before being written in Swift.
struct BigUInt: Equatable, Comparable {
    private(set) var limbs: [UInt32]

    private static let base = UInt64(1) << 32
    private static let mask = UInt64(UInt32.max)

    init() { limbs = [] }

    init(_ value: UInt32) {
        limbs = value == 0 ? [] : [value]
    }

    private init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    /// Big-endian bytes, as every SRP value is transmitted.
    init(bytes: [UInt8]) {
        var limbs: [UInt32] = []
        var index = bytes.count
        while index > 0 {
            let low = max(0, index - 4)
            var limb: UInt32 = 0
            for byte in bytes[low..<index] {
                limb = (limb << 8) | UInt32(byte)
            }
            limbs.append(limb)
            index = low
        }
        self.init(limbs: limbs)
    }

    init(data: Data) { self.init(bytes: [UInt8](data)) }

    init?(hex: String) {
        let cleaned = hex.filter { !$0.isWhitespace }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        if cleaned.count % 2 == 1 {
            guard let value = UInt8(String(cleaned[index]), radix: 16) else { return nil }
            bytes.append(value)
            index = cleaned.index(after: index)
        }
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let value = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(value)
            index = next
        }
        self.init(bytes: bytes)
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    private mutating func normalize() {
        while limbs.last == 0 { limbs.removeLast() }
    }

    /// Big-endian bytes, optionally zero-padded to a fixed width.
    func serialize(paddedTo width: Int? = nil) -> Data {
        var bytes: [UInt8] = []
        for limb in limbs.reversed() {
            bytes.append(UInt8(truncatingIfNeeded: limb >> 24))
            bytes.append(UInt8(truncatingIfNeeded: limb >> 16))
            bytes.append(UInt8(truncatingIfNeeded: limb >> 8))
            bytes.append(UInt8(truncatingIfNeeded: limb))
        }
        while bytes.first == 0 { bytes.removeFirst() }
        if let width {
            if bytes.count > width { bytes.removeFirst(bytes.count - width) }
            while bytes.count < width { bytes.insert(0, at: 0) }
        }
        return Data(bytes)
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt32(index % 32)) & 1 == 1
    }

    // MARK: - Comparison

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool { compare(lhs, rhs) < 0 }

    private static func compare(_ a: BigUInt, _ b: BigUInt) -> Int {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count ? -1 : 1 }
        for index in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[index] != b.limbs[index] {
            return a.limbs[index] < b.limbs[index] ? -1 : 1
        }
        return 0
    }

    // MARK: - Arithmetic

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var out: [UInt32] = []
        out.reserveCapacity(max(lhs.limbs.count, rhs.limbs.count) + 1)
        var carry: UInt64 = 0
        for index in 0..<max(lhs.limbs.count, rhs.limbs.count) {
            let total = UInt64(index < lhs.limbs.count ? lhs.limbs[index] : 0)
                + UInt64(index < rhs.limbs.count ? rhs.limbs[index] : 0) + carry
            out.append(UInt32(truncatingIfNeeded: total))
            carry = total >> 32
        }
        if carry > 0 { out.append(UInt32(truncatingIfNeeded: carry)) }
        return BigUInt(limbs: out)
    }

    /// Requires lhs >= rhs.
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var out: [UInt32] = []
        out.reserveCapacity(lhs.limbs.count)
        var borrow: Int64 = 0
        for index in 0..<lhs.limbs.count {
            let diff = Int64(lhs.limbs[index])
                - Int64(index < rhs.limbs.count ? rhs.limbs[index] : 0) - borrow
            if diff < 0 {
                out.append(UInt32(truncatingIfNeeded: diff + Int64(base)))
                borrow = 1
            } else {
                out.append(UInt32(truncatingIfNeeded: diff))
                borrow = 0
            }
        }
        return BigUInt(limbs: out)
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        guard !lhs.isZero, !rhs.isZero else { return BigUInt() }
        var out = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            let a = UInt64(lhs.limbs[i])
            for j in 0..<rhs.limbs.count {
                let current = UInt64(out[i + j]) + a * UInt64(rhs.limbs[j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: current)
                carry = current >> 32
            }
            var index = i + rhs.limbs.count
            while carry > 0 {
                let current = UInt64(out[index]) + carry
                out[index] = UInt32(truncatingIfNeeded: current)
                carry = current >> 32
                index += 1
            }
        }
        return BigUInt(limbs: out)
    }

    func shiftedLeft(_ bits: Int) -> BigUInt {
        guard bits > 0, !isZero else { return self }
        let limbShift = bits / 32
        let bitShift = bits % 32
        var out = [UInt32](repeating: 0, count: limbs.count + limbShift + 1)
        for index in 0..<limbs.count {
            let value = UInt64(limbs[index]) << UInt64(bitShift)
            out[index + limbShift] |= UInt32(truncatingIfNeeded: value)
            out[index + limbShift + 1] |= UInt32(truncatingIfNeeded: value >> 32)
        }
        return BigUInt(limbs: out)
    }

    func shiftedRight(_ bits: Int) -> BigUInt {
        guard bits > 0, !isZero else { return self }
        let limbShift = bits / 32
        let bitShift = bits % 32
        guard limbShift < limbs.count else { return BigUInt() }
        var out = [UInt32](repeating: 0, count: limbs.count - limbShift)
        for index in 0..<out.count {
            var value = UInt64(limbs[index + limbShift]) >> UInt64(bitShift)
            if bitShift > 0, index + limbShift + 1 < limbs.count {
                value |= UInt64(limbs[index + limbShift + 1]) << UInt64(32 - bitShift)
            }
            out[index] = UInt32(truncatingIfNeeded: value)
        }
        return BigUInt(limbs: out)
    }

    /// Knuth algorithm D.
    func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "division by zero")
        if self < divisor { return (BigUInt(), self) }

        if divisor.limbs.count == 1 {
            let d = UInt64(divisor.limbs[0])
            var quotient = [UInt32](repeating: 0, count: limbs.count)
            var remainder: UInt64 = 0
            for index in stride(from: limbs.count - 1, through: 0, by: -1) {
                let current = (remainder << 32) | UInt64(limbs[index])
                quotient[index] = UInt32(truncatingIfNeeded: current / d)
                remainder = current % d
            }
            return (BigUInt(limbs: quotient), BigUInt(limbs: [UInt32(truncatingIfNeeded: remainder)]))
        }

        // Normalise so the divisor's top limb has its high bit set.
        let shift = divisor.limbs[divisor.limbs.count - 1].leadingZeroBitCount
        var u = shiftedLeft(shift).limbs
        let v = divisor.shiftedLeft(shift).limbs
        let n = v.count
        while u.count < limbs.count + 1 { u.append(0) }
        if u.count < n + 1 { u.append(contentsOf: [UInt32](repeating: 0, count: n + 1 - u.count)) }
        let m = u.count - n - 1

        var quotient = [UInt32](repeating: 0, count: m + 1)
        for j in stride(from: m, through: 0, by: -1) {
            let numerator = (UInt64(u[j + n]) << 32) | UInt64(u[j + n - 1])
            var qhat = min(numerator / UInt64(v[n - 1]), BigUInt.mask)
            var rhat = numerator - qhat * UInt64(v[n - 1])
            while rhat <= BigUInt.mask,
                  qhat * UInt64(v[n - 2]) > ((rhat << 32) | UInt64(u[j + n - 2])) {
                qhat -= 1
                rhat += UInt64(v[n - 1])
            }

            var borrow: Int64 = 0
            var carry: UInt64 = 0
            for i in 0..<n {
                let product = qhat * UInt64(v[i]) + carry
                carry = product >> 32
                let diff = Int64(u[i + j]) - Int64(product & BigUInt.mask) - borrow
                if diff < 0 {
                    u[i + j] = UInt32(truncatingIfNeeded: diff + Int64(BigUInt.base))
                    borrow = 1
                } else {
                    u[i + j] = UInt32(truncatingIfNeeded: diff)
                    borrow = 0
                }
            }
            let finalDiff = Int64(u[j + n]) - Int64(carry) - borrow
            if finalDiff < 0 {
                u[j + n] = UInt32(truncatingIfNeeded: finalDiff + Int64(BigUInt.base))
                borrow = 1
            } else {
                u[j + n] = UInt32(truncatingIfNeeded: finalDiff)
                borrow = 0
            }

            if borrow == 1 {           // qhat was one too large: add the divisor back
                qhat -= 1
                var addCarry: UInt64 = 0
                for i in 0..<n {
                    let total = UInt64(u[i + j]) + UInt64(v[i]) + addCarry
                    u[i + j] = UInt32(truncatingIfNeeded: total)
                    addCarry = total >> 32
                }
                u[j + n] = UInt32(truncatingIfNeeded: UInt64(u[j + n]) + addCarry)
            }
            quotient[j] = UInt32(truncatingIfNeeded: qhat)
        }

        let remainder = BigUInt(limbs: Array(u[0..<n])).shiftedRight(shift)
        return (BigUInt(limbs: quotient), remainder)
    }

    static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.quotientAndRemainder(dividingBy: rhs).remainder
    }

    func power(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        guard !modulus.isZero else { return BigUInt() }
        var result = BigUInt(1)
        var factor = self % modulus
        for index in 0..<exponent.bitWidth {
            if exponent.bit(index) {
                result = (result * factor) % modulus
            }
            factor = (factor * factor) % modulus
        }
        return result
    }
}
