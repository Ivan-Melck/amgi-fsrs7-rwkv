//
//  LearningSteps.swift
//  AnkiKit
//
//  The desktop's ts/routes/deck-options/steps.ts: learning and relearning
//  steps as the "1m 10m 1d" text the deck options edit, stored as minutes.
//

/// `stringToSteps` / `stepsToString`.
public enum LearningSteps {
    /// `stringToSteps`: split on spaces only, each entry read by
    /// `stringToMinutes`, zeros dropped.
    public static func parse(_ text: String) -> [Float] {
        text
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { minutes(String($0)) }
            .filter { $0 != 0 }
    }

    /// `stringToMinutes`: the first run of ASCII digits, in the unit its
    /// suffix names. The suffix is the rest of the line after the digits
    /// (`/(\d+)(.*)/`) and must be exactly `s`, `h` or `d`; anything else,
    /// including upper case, means minutes. 0 when there are no digits.
    public static func minutes(_ text: String) -> Float {
        let scalars = Array(text.unicodeScalars)
        guard let start = scalars.firstIndex(where: isAsciiDigit) else { return 0 }
        var end = start
        while end < scalars.count, isAsciiDigit(scalars[end]) { end += 1 }
        var suffix = String.UnicodeScalarView()
        for scalar in scalars[end...] {
            // `.` stops at a line terminator.
            if isLineTerminator(scalar) { break }
            suffix.append(scalar)
        }
        var number: Double = 0
        for scalar in scalars[start..<end] {
            number = number * 10 + Double(scalar.value - 48)
        }
        let unit: TimeUnit = switch String(suffix) {
        case "s": .seconds
        case "h": .hours
        case "d": .days
        default: .minutes
        }
        // Representable as negative i32 seconds in a revlog.
        let seconds = min(unit.unitSeconds * number, 2_147_483_648)
        return Float(seconds / 60)
    }

    /// `stepsToString`.
    public static func format(_ steps: [Float]) -> String {
        steps.map(string).joined(separator: " ")
    }

    /// `minutesToString`: the largest unit the step is a whole number of
    /// (`naturalWholeUnit`), months and years shown as days.
    public static func string(_ minutes: Float) -> String {
        let secs = Double(minutes) * 60
        var unit = naturalWholeUnit(secs)
        if unit == .months || unit == .years {
            unit = .days
        }
        let amount = mathRound(secs / unit.unitSeconds)
        return JSNumberFormat.toFixed(amount, 0) + unit.suffix
    }

    /// `TimespanUnit` of ts/lib/tslib/time.ts.
    enum TimeUnit: Int {
        case seconds
        case minutes
        case hours
        case days
        case months
        case years

        var unitSeconds: Double {
            switch self {
            case .seconds: 1
            case .minutes: 60
            case .hours: 3600
            case .days: 86_400
            case .years: 365 * 86_400
            case .months: 365 * 86_400 / 12
            }
        }

        /// `unitSuffix`; months and years never reach it.
        var suffix: String {
            switch self {
            case .seconds: "s"
            case .minutes: "m"
            case .hours: "h"
            case .days: "d"
            case .months, .years: ""
            }
        }
    }

    /// `naturalUnit`.
    static func naturalUnit(_ secs: Double) -> TimeUnit {
        let secs = abs(secs)
        if secs < TimeUnit.minutes.unitSeconds { return .seconds }
        if secs < TimeUnit.hours.unitSeconds { return .minutes }
        if secs < TimeUnit.days.unitSeconds { return .hours }
        if secs < TimeUnit.months.unitSeconds { return .days }
        if secs < TimeUnit.years.unitSeconds { return .months }
        return .years
    }

    /// `naturalWholeUnit`: the largest unit `secs` divides without a
    /// remainder.
    static func naturalWholeUnit(_ secs: Double) -> TimeUnit {
        var unit = naturalUnit(secs)
        while unit != .seconds {
            let amount = mathRound(secs / unit.unitSeconds)
            if abs(secs - amount * unit.unitSeconds) < Double.ulpOfOne {
                return unit
            }
            unit = TimeUnit(rawValue: unit.rawValue - 1) ?? .seconds
        }
        return unit
    }

    /// `Math.round`: halves round towards +∞.
    static func mathRound(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        let floor = x.rounded(.down)
        return x - floor >= 0.5 ? floor + 1 : floor
    }

    private static func isAsciiDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }

    /// JavaScript's LineTerminator, which `.` doesn't match.
    private static func isLineTerminator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0D, 0x2028, 0x2029: true
        default: false
        }
    }
}
