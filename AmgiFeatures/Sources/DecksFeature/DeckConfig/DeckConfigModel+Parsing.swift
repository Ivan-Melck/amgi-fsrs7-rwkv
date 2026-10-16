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
    /// The desktop's `stringToSteps` (ts/routes/deck-options/steps.ts).
    func parseSteps(_ text: String) -> [Float] {
        LearningSteps.parse(text)
    }

    /// `stringToMinutes`.
    nonisolated static func stepMinutes(_ token: String) -> Float {
        LearningSteps.minutes(token)
    }

    /// The desktop's `stepsToString`: each step in the largest unit it is a
    /// whole number of, so 30s and 90s survive a round trip.
    func formatSteps(_ values: [Float]) -> String {
        LearningSteps.format(values)
    }

    /// `minutesToString`.
    nonisolated static func stepString(_ minutes: Float) -> String {
        LearningSteps.string(minutes)
    }

    /// `ParamsInput`'s `render`.
    func formatWeights(_ values: [Float]) -> String {
        FsrsParamsInput.render(values)
    }

    /// Working params for `version`: edits parked by a scheduler switch,
    /// else the loaded preset's stored array.
    func fsrsParams(for version: FsrsVersion) -> [Float] {
        parkedFsrsParams[version] ?? loaded?.config.config.fsrsParams(for: version) ?? []
    }

    /// Params of the active FSRS version as edited: the stored array while
    /// the text field still shows it unchanged (so a save doesn't round it
    /// to the displayed precision), else the parsed text. Text the desktop
    /// would reject leaves the last accepted params. Empty means the
    /// backend's defaults.
    func activeFsrsParams() -> [Float] {
        let stored = fsrsParams(for: schedulerSelection.fsrsVersion)
        if fsrsWeightsText == formatWeights(stored) {
            return stored
        }
        return FsrsParamsInput.parse(fsrsWeightsText) ?? stored
    }

    /// `ParamsInput`'s `update`, run when the field loses focus and before a
    /// save: accepted text becomes the version's params (shown rendered, as
    /// the desktop re-renders them); anything else is reverted with the
    /// desktop's alert. Returns whether the text was accepted.
    @discardableResult
    func commitFsrsWeightsText() -> Bool {
        let version = schedulerSelection.fsrsVersion
        let stored = fsrsParams(for: version)
        let rendered = formatWeights(stored)
        guard fsrsWeightsText != rendered else { return true }
        guard let parsed = FsrsParamsInput.parse(fsrsWeightsText) else {
            fsrsWeightsText = rendered
            destination = .alert(.notice(
                title: "Invalid FSRS parameters",
                message: FsrsParamsInput.invalidParametersMessage
            ))
            return false
        }
        parkedFsrsParams[version] = parsed
        fsrsWeightsText = formatWeights(parsed)
        return true
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
