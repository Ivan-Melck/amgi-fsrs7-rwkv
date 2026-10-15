//
//  DeckConfigModel+Parsing.swift
//  DecksFeature
//
//  Created by Vladimir Gusev on 20.08.2026.
//

import AnkiClients
import AnkiKit
import Dependencies
import Foundation

extension DeckConfigModel {
    /// The desktop's `stringToSteps` (ts/routes/deck-options/steps.ts):
    /// whole numbers with an s/m/h/d suffix (minutes when absent); zeros and
    /// unparsable entries are dropped.
    func parseSteps(_ text: String) -> [Float] {
        text
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" })
            .map { Self.stepMinutes(String($0).lowercased()) }
            .filter { $0 != 0 }
    }

    /// `stringToMinutes`.
    nonisolated static func stepMinutes(_ token: String) -> Float {
        let digits = token.prefix(while: \.isNumber)
        guard let number = Double(digits) else { return 0 }
        let unitSeconds: Double = switch token.dropFirst(digits.count) {
        case "s": 1
        case "h": 3600
        case "d": 86_400
        default: 60
        }
        // Representable as negative i32 seconds in a revlog.
        return Float(min(number * unitSeconds, 2_147_483_648) / 60)
    }

    /// The desktop's `stepsToString`: each step in the largest unit it is a
    /// whole number of, so 30s and 90s survive a round trip.
    func formatSteps(_ values: [Float]) -> String {
        values.map(Self.stepString).joined(separator: " ")
    }

    /// `minutesToString` / `naturalWholeUnit`, capped at days.
    nonisolated static func stepString(_ minutes: Float) -> String {
        let seconds = Double(minutes) * 60
        let units: [(Double, String)] = [(86_400, "d"), (3600, "h"), (60, "m"), (1, "s")]
        let natural = units.firstIndex { abs(seconds) >= $0.0 } ?? units.count - 1
        for (unitSeconds, suffix) in units[natural...] {
            let amount = (seconds / unitSeconds).rounded()
            if abs(seconds - amount * unitSeconds) < .ulpOfOne || suffix == "s" {
                return "\(Int(amount))\(suffix)"
            }
        }
        return "\(Int(seconds.rounded()))s"
    }

    func parseFloats(_ text: String) -> [Float] {
        text
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" })
            .compactMap { Float($0) }
    }

    func formatWeights(_ values: [Float]) -> String {
        values.map { String(format: "%.4f", $0) }.joined(separator: ", ")
    }

    /// Working params for `version`: edits parked by a scheduler switch,
    /// else the loaded preset's stored array.
    func fsrsParams(for version: FsrsVersion) -> [Float] {
        parkedFsrsParams[version] ?? loaded?.config.config.fsrsParams(for: version) ?? []
    }

    /// Params of the active FSRS version as edited: the stored array while
    /// the text field still shows it unchanged (so a save doesn't round it
    /// to the displayed precision), else the parsed text. Empty means the
    /// backend's defaults.
    func activeFsrsParams() -> [Float] {
        let stored = fsrsParams(for: schedulerSelection.fsrsVersion)
        return fsrsWeightsText == formatWeights(stored) ? stored : parseFloats(fsrsWeightsText)
    }

    /// "FSRS-7 parameters" etc. for the active version.
    var fsrsParamsLabel: String {
        switch schedulerSelection.fsrsVersion {
        case .seven: "FSRS-7 parameters"
        case .six: "FSRS-6 parameters"
        case .five: "FSRS-5 parameters"
        case .four: "FSRS-4 parameters"
        }
    }

    func effectiveParamSearch() -> String {
        let trimmed = fsrsParamSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultParamSearch : trimmed
    }

    /// Heuristic mirrored from upstream Anki: only relearning steps that fit
    /// inside one day are passed to the optimizer, so a "10m 1d" relearn
    /// schedule contributes 1, not 2.
    func relearningStepsInDay(_ steps: [Float]) -> UInt32 {
        var count: UInt32 = 0
        var accumulated: Float = 0
        for step in steps {
            accumulated += step
            if accumulated >= 1440 { break }
            count += 1
        }
        return count
    }

    // MARK: - Preset CRUD
}
