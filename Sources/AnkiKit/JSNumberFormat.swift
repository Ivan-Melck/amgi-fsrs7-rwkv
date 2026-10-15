//
//  JSNumberFormat.swift
//  AnkiKit
//
//  JavaScript's `Number.prototype.toFixed` / `toPrecision`, so ported
//  desktop views print numbers exactly as the desktop does. Unlike printf,
//  they round exact ties up (`(0.25).toFixed(1)` is "0.3").
//

public enum JSNumberFormat {
    /// `x.toFixed(digits)`.
    public static func toFixed(_ x: Double, _ digits: Int) -> String {
        if x.isNaN { return "NaN" }
        var sign = ""
        var x = x
        if x < 0 {
            sign = "-"
            x = -x
        }
        if x.isInfinite { return sign + "Infinity" }
        if x >= 1e21 {
            // Number::toString; not reached by the ported views.
            return sign + "\(x)"
        }
        let (decimal, point) = x == 0 ? ([], 0) : exactDecimal(x)
        // n = round-half-up(x * 10^digits), from the exact digits.
        let integerCount = point + digits
        var n: [UInt8] = integerCount > 0
            ? (0..<integerCount).map { $0 < decimal.count ? decimal[$0] : 0 }
            : []
        if integerCount >= 0, integerCount < decimal.count, decimal[integerCount] >= 5 {
            n = incremented(n)
        }
        while n.count > 1, n.first == 0 { n.removeFirst() }
        var m = n.isEmpty ? "0" : String(n.map { Character(String($0)) })
        if digits != 0 {
            var k = m.count
            if k <= digits {
                m = String(repeating: "0", count: digits + 1 - k) + m
                k = digits + 1
            }
            m = "\(m.prefix(k - digits)).\(m.suffix(digits))"
        }
        return sign + m
    }

    /// `x.toPrecision(precision)`.
    public static func toPrecision(_ x: Double, _ precision: Int) -> String {
        if x.isNaN { return "NaN" }
        var sign = ""
        var x = x
        if x < 0 {
            sign = "-"
            x = -x
        }
        if x.isInfinite { return sign + "Infinity" }
        let p = max(1, precision)
        var n: [UInt8]
        var e: Int
        if x == 0 {
            n = Array(repeating: 0, count: p)
            e = 0
        } else {
            let (decimal, point) = exactDecimal(x)
            e = point - 1
            n = (0..<p).map { $0 < decimal.count ? decimal[$0] : 0 }
            if p < decimal.count, decimal[p] >= 5 {
                n = incremented(n)
                if n.count > p {
                    n.removeLast()
                    e += 1
                }
            }
        }
        let m = String(n.map { Character(String($0)) })
        if e < -6 || e >= p {
            let a = m.prefix(1)
            let b = m.dropFirst()
            let mantissa = p == 1 ? String(a) : "\(a).\(b)"
            return sign + mantissa + "e" + (e >= 0 ? "+" : "-") + "\(abs(e))"
        }
        if e == p - 1 {
            return sign + m
        }
        if e >= 0 {
            return sign + "\(m.prefix(e + 1)).\(m.dropFirst(e + 1))"
        }
        return sign + "0." + String(repeating: "0", count: -(e + 1)) + m
    }

    /// A decimal digit string plus one, carrying into a new leading digit.
    private static func incremented(_ digits: [UInt8]) -> [UInt8] {
        var digits = digits
        var index = digits.count - 1
        while index >= 0 {
            if digits[index] < 9 {
                digits[index] += 1
                return digits
            }
            digits[index] = 0
            index -= 1
        }
        return [1] + digits
    }

    /// The exact decimal expansion of a finite x > 0: its significant
    /// digits, most significant first, and the count of digits before the
    /// decimal point (x = 0.d1d2… × 10^point).
    static func exactDecimal(_ x: Double) -> (digits: [UInt8], point: Int) {
        precondition(x > 0 && x.isFinite)
        var significand = x.significandBitPattern
        var exponent: Int
        if x.exponentBitPattern == 0 {
            exponent = -1074
        } else {
            significand |= 1 << 52
            exponent = Int(x.exponentBitPattern) - 1075
        }
        while significand & 1 == 0 {
            significand >>= 1
            exponent += 1
        }
        // Little-endian decimal digits of the integer significand × 2^exponent,
        // or of significand × 5^-exponent with -exponent decimal places.
        var digits: [UInt8] = []
        var value = significand
        while value > 0 {
            digits.append(UInt8(value % 10))
            value /= 10
        }
        func multiply(by factor: UInt64, times: Int) {
            for _ in 0..<times {
                var carry: UInt64 = 0
                for index in digits.indices {
                    let product = UInt64(digits[index]) * factor + carry
                    digits[index] = UInt8(product % 10)
                    carry = product / 10
                }
                while carry > 0 {
                    digits.append(UInt8(carry % 10))
                    carry /= 10
                }
            }
        }
        let places: Int
        if exponent >= 0 {
            multiply(by: 1 << 20, times: exponent / 20)
            multiply(by: 2, times: exponent % 20)
            places = 0
        } else {
            let fives = -exponent
            multiply(by: 1_220_703_125, times: fives / 13) // 5^13
            multiply(by: 5, times: fives % 13)
            places = fives
        }
        let point = digits.count - places
        var mostSignificantFirst = Array(digits.reversed())
        while mostSignificantFirst.last == 0 { mostSignificantFirst.removeLast() }
        return (mostSignificantFirst, point)
    }
}
