//
//  FsrsParamsInput.swift
//  AnkiKit
//
//  The desktop's ts/routes/deck-options/ParamsInput.svelte: the FSRS
//  parameters text field, its rendering and the check made when it loses
//  focus.
//

import Foundation

/// `ParamsInput.svelte`.
public enum FsrsParamsInput {
    /// `tr.deckConfigInvalidParameters()`, alerted when an edit is rejected.
    public static let invalidParametersMessage = FsrsOptimizationFeedback.invalidParametersMessage

    /// `render`: each value with four decimals, comma separated.
    public static func render(_ params: [Float]) -> String {
        params.map { JSNumberFormat.toFixed(Double($0), 4) }.joined(separator: ", ")
    }

    /// `update`: spaces removed, split on commas, empty entries dropped and
    /// each entry read with JavaScript's `Number`. `nil` unless the count is
    /// one FSRS accepts (0 meaning the defaults) and every value is finite.
    public static func parse(_ text: String) -> [Float]? {
        let values = text
            .replacingOccurrences(of: " ", with: "")
            .split(separator: ",")
            .map { javaScriptNumber(String($0)) }
        guard FsrsParamDiagnostics.validCounts.contains(values.count),
              values.allSatisfy(\.isFinite)
        else { return nil }
        let params = values.map { Float($0) }
        // Also finite once narrowed to the stored float32.
        guard params.allSatisfy(\.isFinite) else { return nil }
        return params
    }

    /// JavaScript's `Number(string)`: surrounding whitespace ignored, empty
    /// is 0, decimal and exponent notation, `Infinity`, unsigned `0x`/`0o`/
    /// `0b` integers; NaN otherwise.
    static func javaScriptNumber(_ text: String) -> Double {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !isJavaScriptWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isJavaScriptWhitespace($0) })
        else { return 0 }
        let body = Array(scalars[first...last])
        var literal = String.UnicodeScalarView()
        literal.append(contentsOf: body)
        let string = String(literal)

        switch string {
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }

        if body.count > 2, body[0] == "0" {
            let radix: Double? = switch body[1] {
            case "x", "X": 16
            case "o", "O": 8
            case "b", "B": 2
            default: nil
            }
            if let radix {
                var value: Double = 0
                for scalar in body[2...] {
                    guard let digit = digitValue(scalar), digit < radix else { return .nan }
                    value = value * radix + digit
                }
                return value
            }
        }

        guard isDecimalLiteral(body) else { return .nan }
        return Double(string) ?? .nan
    }

    /// StrDecimalLiteral without `Infinity`:
    /// `[+-]? (digits [. digits?] | . digits) ([eE] [+-]? digits)?`.
    private static func isDecimalLiteral(_ scalars: [Unicode.Scalar]) -> Bool {
        var index = 0
        func digits() -> Int {
            let start = index
            while index < scalars.count, isAsciiDigit(scalars[index]) { index += 1 }
            return index - start
        }
        if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
        var mantissaDigits = digits()
        if index < scalars.count, scalars[index] == "." {
            index += 1
            mantissaDigits += digits()
        }
        guard mantissaDigits > 0 else { return false }
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            index += 1
            if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
            guard digits() > 0 else { return false }
        }
        return index == scalars.count
    }

    private static func isAsciiDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }

    private static func digitValue(_ scalar: Unicode.Scalar) -> Double? {
        switch scalar.value {
        case 48...57: Double(scalar.value - 48)
        case 65...70: Double(scalar.value - 55)
        case 97...102: Double(scalar.value - 87)
        default: nil
        }
    }

    /// JavaScript's WhiteSpace and LineTerminator: Unicode White_Space
    /// without U+0085, plus U+FEFF.
    private static func isJavaScriptWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0xFEFF { return true }
        if scalar.value == 0x85 { return false }
        return scalar.properties.isWhitespace
    }
}
