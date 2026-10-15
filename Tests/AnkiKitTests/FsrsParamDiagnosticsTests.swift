//
//  FsrsParamDiagnosticsTests.swift
//  AnkiKitTests
//
//  Ports the fork desktop's ts/routes/deck-options/fsrs-param-diagnostics.test.ts,
//  plus the optimize error feedback of FsrsOptions.svelte.
//

import Foundation
import Testing
@testable import AnkiKit

@Suite("FSRS parameter diagnostics")
struct FsrsParamDiagnosticsTests {
    @Test func acceptsDefaultAndKnownFsrsParameterCounts() {
        for count in [0, 17, 19, 21, 34] {
            #expect(FsrsParamDiagnostics(Array(repeating: 1, count: count)).valid)
        }
    }

    @Test func rejectsUnexpectedFsrsParameterCounts() {
        let diagnostics = FsrsParamDiagnostics([1, 2, 3])
        #expect(!diagnostics.valid)
        #expect(!diagnostics.validCount)
        #expect(diagnostics.count == 3)
        #expect(!diagnostics.outdatedFsrs7PreviewParams)
        #expect(diagnostics.details == "Expected 0, 17, 19, 21, or 34 values, but found 3.")
    }

    @Test func flagsOutdated35ParameterFsrs7PreviewParams() {
        let diagnostics = FsrsParamDiagnostics(Array(repeating: 1, count: 35))
        #expect(!diagnostics.valid)
        #expect(!diagnostics.validCount)
        #expect(diagnostics.outdatedFsrs7PreviewParams)
        #expect(FsrsParamDiagnostics.outdatedFsrs7PreviewParamsWarning.contains("35 values"))
        #expect(FsrsParamDiagnostics.outdatedFsrs7PreviewParamsWarning.contains("34 values"))
        #expect(diagnostics.details == FsrsParamDiagnostics.outdatedFsrs7PreviewParamsWarning)
    }

    @Test func reportsNonFiniteFsrsParameterIndexesAndValues() {
        var params = [Float](repeating: 1, count: 21)
        params[2] = .nan
        params[5] = .infinity
        let diagnostics = FsrsParamDiagnostics(params)
        #expect(!diagnostics.valid)
        #expect(diagnostics.validCount)
        #expect(diagnostics.nonFiniteIndexes == [2, 5])
        #expect(diagnostics.nonFiniteValues == ["NaN", "Infinity"])
        #expect(diagnostics.details == "Non-finite value at position 3, 6.")
    }

    @Test func sameDayEvaluationIsOnlySupportedForFsrs7ParameterSets() {
        #expect(FsrsParamDiagnostics.supportsSameDayEvaluation(Array(repeating: 1, count: 34)))
        for count in [0, 17, 19, 21] {
            #expect(!FsrsParamDiagnostics.supportsSameDayEvaluation(Array(repeating: 1, count: count)))
        }
    }

    @Test func comparisonExcludesSameDayTargetsUnlessBothParameterSetsSupportThem() {
        let fsrs6: [Float] = Array(repeating: 1, count: 21)
        let fsrs7: [Float] = Array(repeating: 1, count: 34)
        typealias D = FsrsParamDiagnostics
        #expect(D.sameDayEvaluationOverrideForComparison(current: fsrs6, optimized: fsrs7, requested: true) == false)
        #expect(D.sameDayEvaluationOverrideForComparison(current: fsrs7, optimized: fsrs7, requested: true) == true)
        #expect(D.sameDayEvaluationOverrideForComparison(current: fsrs6, optimized: fsrs7, requested: false) == false)
        #expect(D.sameDayEvaluationOverrideForComparison(current: fsrs6, optimized: fsrs7, requested: nil) == nil)
    }

    // MARK: Feedback (FsrsOptions.svelte)

    @Test func invalidCurrentParamsSuggestClearingTheField() {
        let text = FsrsOptimizationFeedback.invalidParams(role: .current, diagnostics: FsrsParamDiagnostics([1, 2, 3]))
        #expect(text == [
            "Anki cannot evaluate the current FSRS parameters, so it cannot compare them with the optimized parameters.",
            "Expected 0, 17, 19, 21, or 34 values, but found 3.",
            "Leave the FSRS parameters field blank to use the default values, then optimize again.",
            "Details have been logged to the console.",
        ].joined(separator: "\n\n"))
    }

    @Test func outdatedCurrentParamsHaveNoExtraNextStep() {
        let text = FsrsOptimizationFeedback.invalidParams(
            role: .current,
            diagnostics: FsrsParamDiagnostics(Array(repeating: 1, count: 35)),
            rejectedByBackend: true
        )
        #expect(text == [
            "Anki cannot evaluate the current FSRS parameters, so it cannot compare them with the optimized parameters.",
            FsrsParamDiagnostics.outdatedFsrs7PreviewParamsWarning + "\nFSRS rejected these parameters during evaluation.",
            "Details have been logged to the console.",
        ].joined(separator: "\n\n"))
    }

    @Test func invalidOptimizedParamsAskForAReport() {
        let text = FsrsOptimizationFeedback.invalidParams(role: .optimized, diagnostics: FsrsParamDiagnostics([]), rejectedByBackend: true)
        #expect(text == [
            "Anki cannot evaluate the optimized FSRS parameters, so it cannot show the optimization comparison.",
            "FSRS rejected these parameters during evaluation.",
            "Please report this with the console details.",
            "Details have been logged to the console.",
        ].joined(separator: "\n\n"))
    }

    @Test func requireValidThrowsFeedbackOnlyForInvalidParams() throws {
        try FsrsOptimizationFeedback.requireValid(role: .current, params: [])
        #expect(throws: FsrsOptimizationFeedbackError.self) {
            try FsrsOptimizationFeedback.requireValid(role: .optimized, params: [1])
        }
    }

    private struct BackendFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Test func failureFeedbackPassesThroughFeedbackErrors() {
        let error = FsrsOptimizationFeedbackError("shown as is")
        #expect(FsrsOptimizationFeedback.failure(error, params: [], dynamicDesiredRetentionHint: true) == "shown as is")
    }

    @Test func failureFeedbackExplainsBackendRejectedInvalidParams() {
        let error = BackendFailure(message: FsrsOptimizationFeedback.invalidParametersMessage)
        #expect(
            FsrsOptimizationFeedback.failure(error, params: [1, 2, 3], dynamicDesiredRetentionHint: false)
                == FsrsOptimizationFeedback.invalidParams(
                    role: .current,
                    diagnostics: FsrsParamDiagnostics([1, 2, 3]),
                    rejectedByBackend: true
                )
        )
        // Valid params: the generic message.
        #expect(
            FsrsOptimizationFeedback.failure(error, params: [], dynamicDesiredRetentionHint: false)
                == "FSRS optimization failed. Details have been logged to the console.\n\n"
                + FsrsOptimizationFeedback.invalidParametersMessage
        )
    }

    @Test func failureFeedbackHintsAtDynamicDesiredRetention() {
        let error = BackendFailure(message: "boom")
        #expect(
            FsrsOptimizationFeedback.failure(error, params: [], dynamicDesiredRetentionHint: true)
                == "FSRS optimization failed. Details have been logged to the console.\n\n"
                + "Dynamic DR (ADR) is enabled. Try disabling it and optimizing again to check whether it is involved.\n\nboom"
        )
    }
}
