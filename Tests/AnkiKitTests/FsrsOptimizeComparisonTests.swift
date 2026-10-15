//
//  FsrsOptimizeComparisonTests.swift
//  AnkiKitTests
//
//  Ports the fork desktop's ts/routes/deck-options/optimize-comparison.test.ts,
//  custom-decay-table.test.ts and help-me-decide-defaults.test.ts, plus the
//  optimize popup logic of FsrsOptions.svelte.
//

import Foundation
import Testing
@testable import AnkiKit

@Suite("FSRS optimize comparison")
struct FsrsOptimizeComparisonTests {
    typealias M = FsrsMetricComparison

    // MARK: optimize-comparison.test.ts

    @Test func metricDeltaComputesNewMinusOld() {
        #expect(abs(M.delta(0.2, 0.15) - -0.05) < 1e-10)
        #expect(abs(M.delta(0.2, 0.25) - 0.05) < 1e-10)
    }

    @Test func deltaClassMarksLowerValuesAsBetter() {
        #expect(M.deltaClass(-0.01) == .better)
        #expect(M.deltaClass(0.01) == .worse)
        #expect(M.deltaClass(0) == .equal)
    }

    @Test func formatHelpersUseConsistentPrecision() {
        #expect(M.formatMetric(0.123456) == "0.1235")
        #expect(M.formatDelta(-0.123456) == "-0.1235")
        #expect(M.formatDelta(0.123456) == "+0.1235")
        #expect(M.formatDelta(0) == "0.0000")
    }

    @Test func metricDeltaPercentComputesRelativeChange() throws {
        #expect(abs(try #require(M.deltaPercent(2, 1.5)) - -25) < 1e-10)
        #expect(abs(try #require(M.deltaPercent(2, 2.5)) - 25) < 1e-10)
        #expect(M.deltaPercent(0, 0) == 0)
        #expect(M.deltaPercent(0, 1) == nil)
    }

    @Test func formatPercentDeltaHandlesSignsAndUndefined() {
        #expect(M.formatPercentDelta(-12.3456) == "-12.35%")
        #expect(M.formatPercentDelta(12.3456) == "+12.35%")
        #expect(M.formatPercentDelta(0) == "0.00%")
        #expect(M.formatPercentDelta(nil) == "n/a")
    }

    // MARK: JavaScript toFixed

    @Test func toFixedRoundsExactTiesAwayFromZeroLikeJavaScript() {
        // (0.125).toFixed(2) === "0.13"; printf would give "0.12".
        #expect(M.toFixed(0.125, 2) == "0.13")
        #expect(M.toFixed(-0.125, 2) == "-0.13")
        #expect(M.toFixed(0.03125, 4) == "0.0313")
        #expect(M.toFixed(2.5, 0) == "3")
        // Not exact ties: the binary value decides, as in JavaScript.
        #expect(M.toFixed(1.005, 2) == "1.00")
        #expect(M.toFixed(0.15, 1) == "0.1")
    }

    @Test func toFixedMatchesJavaScriptEdgeCases() {
        #expect(M.toFixed(-0.0, 4) == "0.0000")
        #expect(M.toFixed(-0.00001, 4) == "-0.0000")
        #expect(M.toFixed(9.99996, 4) == "10.0000")
        #expect(M.toFixed(.nan, 4) == "NaN")
        #expect(M.toFixed(-.infinity, 2) == "-Infinity")
        #expect(M.toFixed(123.456, 0) == "123")
    }

    // MARK: custom-decay-table.test.ts

    @Test func customDecayCandidatesAreTheRequestedValues() {
        #expect(FsrsCustomDecayTable.candidates == [0.1, 0.15, 0.2, 0.25, 0.35, 0.4])
    }

    @Test func withLastParamOnlyUpdatesFinalParameter() {
        #expect(FsrsCustomDecayTable.withLastParam([1, 2, 3], 0.25) == [1, 2, 0.25])
        #expect(FsrsCustomDecayTable.withLastParam([], 0.25) == [])
    }

    @Test func customDecayTableIsDisabledForFsrs7ParameterSets() {
        #expect(FsrsCustomDecayTable.supports((0..<21).map(Float.init)))
        #expect(!FsrsCustomDecayTable.supports((0..<34).map(Float.init)))
        #expect(!FsrsCustomDecayTable.supports([]))
    }

    @Test func formatDecayKeepsTwoDecimals() {
        #expect(FsrsCustomDecayTable.formatDecay(0.1) == "0.10")
        #expect(FsrsCustomDecayTable.formatDecay(0.25) == "0.25")
    }

    // MARK: help-me-decide-defaults.test.ts

    @Test func helpMeDecideUsesROnlyBlendByDefault() {
        #expect(FsrsHelpMeDecideDefaults.transitionBlendAlpha == 0)
    }

    @Test func helpMeDecideLeavesMonotonicGradeConstraintsDisabledByDefault() {
        #expect(FsrsHelpMeDecideDefaults.enforceMonotonicSuccessGradeProbs == false)
    }

    // MARK: Optimization Result popup

    private func comparison(params: [Float]) -> FsrsOptimizationComparison {
        FsrsOptimizationComparison(
            optimizedParams: params,
            dynamicDesiredRetention: nil,
            search: "deck:x",
            ignoreRevlogsBefore: Date(timeIntervalSince1970: 86_400),
            includeSameDayReviews: false,
            current: FsrsEvaluation(logLoss: 0.4, rmseBins: 0.05),
            optimized: FsrsEvaluation(logLoss: 0.3, rmseBins: 0.04)
        )
    }

    @Test func comparisonDeltasAreOptimizedMinusCurrent() throws {
        let result = comparison(params: Array(repeating: 1, count: 21))
        #expect(abs(result.logLossDelta - (Double(Float(0.3)) - Double(Float(0.4)))) < 1e-12)
        #expect(M.deltaClass(result.logLossDelta) == .better)
        #expect(M.formatDelta(result.rmseDelta) == "-0.0100")
        #expect(M.formatPercentDelta(result.logLossDeltaPercent) == "-25.00%")
        #expect(M.formatPercentDelta(result.rmseDeltaPercent) == "-20.00%")
        #expect(result.supportsCustomDecayTable)
        #expect(!comparison(params: Array(repeating: 1, count: 34)).supportsCustomDecayTable)
    }

    @Test func customDecayRequestsReplaceTheDecayAndKeepTheComparisonSearch() {
        let result = comparison(params: [1, 2, 0.5])
        let requests = result.customDecayRequests()
        #expect(requests.map(\.decay) == FsrsCustomDecayTable.candidates)
        #expect(requests.map(\.request.params) == FsrsCustomDecayTable.candidates.map { [1, 2, Float($0)] })
        for (_, request) in requests {
            #expect(request.search == "deck:x")
            #expect(request.ignoreRevlogsBefore == Date(timeIntervalSince1970: 86_400))
            #expect(request.includeSameDayReviews == false)
        }
    }

    @Test func customDecayRowsStartWithTheOptimizedBaseline() {
        let result = comparison(params: [1, 2, 0.5])
        let rows = result.customDecayRows([
            (0.1, FsrsEvaluation(logLoss: 0.33, rmseBins: 0.04)),
            (0.2, FsrsEvaluation(logLoss: 0.3, rmseBins: 0)),
        ])
        #expect(rows.count == 3)
        #expect(rows[0].isBaseline)
        #expect(FsrsCustomDecayTable.formatDecay(rows[0].decay) == "0.50")
        #expect(rows[0].logLoss == Double(Float(0.3)))
        #expect(rows[0].logLossDelta == 0 && rows[0].logLossDeltaPercent == 0)
        #expect(!rows[1].isBaseline)
        #expect(rows[1].decay == 0.1)
        #expect(M.formatDelta(rows[1].logLossDelta) == "+0.0300")
        #expect(M.deltaClass(rows[1].logLossDelta) == .worse)
        #expect(rows[1].rmseDelta == 0 && rows[1].rmseDeltaPercent == 0)
        #expect(rows[2].logLossDelta == 0)
        #expect(M.formatPercentDelta(rows[2].rmseDeltaPercent) == "-100.00%")
    }

    @Test func alreadyOptimalComparesToFourDecimals() {
        #expect(FsrsOptimizeOutcome.alreadyOptimal(current: [1, 2], optimized: []))
        #expect(FsrsOptimizeOutcome.alreadyOptimal(current: [], optimized: []))
        #expect(!FsrsOptimizeOutcome.alreadyOptimal(current: [], optimized: [1, 2]))
        #expect(FsrsOptimizeOutcome.alreadyOptimal(current: [1.00001, 2], optimized: [1, 2]))
        #expect(!FsrsOptimizeOutcome.alreadyOptimal(current: [1.0002, 2], optimized: [1, 2]))
        #expect(!FsrsOptimizeOutcome.alreadyOptimal(current: [1, 2, 3], optimized: [1, 2]))
    }

    @Test func noticeCombinesTheOptimalAndHealthCheckMessages() {
        typealias O = FsrsOptimizeOutcome
        #expect(O.notice(alreadyOptimal: false, trainingItemCount: 10, healthCheck: nil) == nil)
        #expect(O.notice(alreadyOptimal: false, trainingItemCount: 10, healthCheck: .failed) == nil)
        #expect(O.notice(alreadyOptimal: false, trainingItemCount: 10, healthCheck: .passed) == O.goodFitMessage)
        #expect(O.notice(alreadyOptimal: true, trainingItemCount: 0, healthCheck: nil) == O.noReviewsMessage)
        #expect(
            O.notice(alreadyOptimal: true, trainingItemCount: 5, healthCheck: .passed)
                == O.paramsOptimalMessage + "\n\n" + O.goodFitMessage
        )
    }
}
