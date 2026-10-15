//
//  JSNumber.swift
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
        JSNumberFormat.toFixed(value, digits)
    }

    /// `Math.round`: halves round towards +∞.
    public static func round(_ value: Double) -> Double {
        let floor = value.rounded(.down)
        return value - floor >= 0.5 ? floor + 1 : floor
    }
}
