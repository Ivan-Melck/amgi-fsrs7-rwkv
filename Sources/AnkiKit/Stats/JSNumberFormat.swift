//
//  JSNumberFormat.swift
//  AnkiKit
//
//  JavaScript's number formatting and rounding, for text and values ported
//  from the desktop's TypeScript (graphs drawn by Search Stats Extended).
//

import Foundation

public enum JSNumber {
    /// `Number.prototype.toFixed`: the exact value rounded half up (away
    /// from zero after taking the sign), so `(6.25).toFixed(1)` is "6.3"
    /// where `%.1f` gives "6.2"; negative values keep their sign ("-0.0").
    public static func toFixed(_ value: Double, _ digits: Int) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value < 0 ? "-Infinity" : "Infinity") }
        if value < 0 {
            return "-" + toFixed(-value, digits)
        }
        // printf prints the double's exact decimal expansion (to this many
        // places, enough for every value these graphs format).
        let exact = String(format: "%.80f", value)
        guard let point = exact.firstIndex(of: ".") else { return exact }
        let integer = Array(exact[..<point])
        let fraction = Array(exact[exact.index(after: point)...])
        var kept = integer + fraction.prefix(digits)
        if fraction.count > digits, let next = fraction[digits].wholeNumberValue, next >= 5 {
            var index = kept.count - 1
            while index >= 0 {
                if kept[index] == "9" {
                    kept[index] = "0"
                    index -= 1
                } else {
                    kept[index] = Character(String((kept[index].wholeNumberValue ?? 0) + 1))
                    break
                }
            }
            if index < 0 {
                kept.insert("1", at: 0)
            }
        }
        let integerCount = kept.count - digits
        let integerPart = String(kept[..<integerCount])
        guard digits > 0 else { return integerPart }
        return integerPart + "." + String(kept[integerCount...])
    }

    /// `Math.round`: halves round towards +∞.
    public static func round(_ value: Double) -> Double {
        let floor = value.rounded(.down)
        return value - floor >= 0.5 ? floor + 1 : floor
    }
}
