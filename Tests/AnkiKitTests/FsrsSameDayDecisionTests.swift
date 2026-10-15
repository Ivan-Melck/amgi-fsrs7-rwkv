//
//  FsrsSameDayDecisionTests.swift
//  AnkiKitTests
//
//  The same-day reviews Help Me Decide of the fork desktop's
//  FsrsOptions.svelte (`sameDayRecommendation`, `sameDayMetricClass`).
//

import Testing
@testable import AnkiKit

@Suite("FSRS same-day Help Me Decide")
struct FsrsSameDayDecisionTests {
    private func comparison(
        withAll: Float, withLong: Float, withoutAll: Float, withoutLong: Float
    ) -> FsrsSameDayDecisionComparison {
        FsrsSameDayDecisionComparison(
            withSameDay: FsrsSameDayDecisionRow(
                label: FsrsSameDayDecisionComparison.withSameDayLabel,
                fsrsItems: 120,
                allTargets: FsrsEvaluation(logLoss: withAll, rmseBins: 0.05),
                longTermTargets: FsrsEvaluation(logLoss: withLong, rmseBins: 0.04)
            ),
            withoutSameDay: FsrsSameDayDecisionRow(
                label: FsrsSameDayDecisionComparison.withoutSameDayLabel,
                fsrsItems: 100,
                allTargets: FsrsEvaluation(logLoss: withoutAll, rmseBins: 0.06),
                longTermTargets: FsrsEvaluation(logLoss: withoutLong, rmseBins: 0.04)
            )
        )
    }

    @Test func equalLogLossHasNoClearWinner() {
        let recommendation = comparison(withAll: 0.3, withLong: 0.25, withoutAll: 0.3, withoutLong: 0.25).recommendation
        #expect(recommendation.tone == .equal)
        #expect(recommendation.text == "No clear winner: both options have the same log loss on all targets and long-term-only targets.")
    }

    @Test func includesSameDayWhenLongTermLogLossDoesNotGetWorse() {
        let recommendation = comparison(withAll: 0.35, withLong: 0.25, withoutAll: 0.3, withoutLong: 0.25).recommendation
        #expect(recommendation.tone == .better)
        #expect(recommendation.text == "Recommended: include same-day reviews. All-target log loss changes by +0.0500, and long-term-only log loss changes by 0.0000.")
    }

    @Test func includesSameDayWhenTheAllTargetGainOutweighsTheLongTermLoss() {
        // All targets: -0.05; long term: +0.01.
        let recommendation = comparison(withAll: 0.25, withLong: 0.26, withoutAll: 0.3, withoutLong: 0.25).recommendation
        #expect(recommendation.tone == .better)
        #expect(recommendation.text.hasPrefix("Recommended: include same-day reviews. All-target log loss changes by -0.0500, "))
    }

    @Test func excludesSameDayWhenTheLongTermLossOutweighsTheGain() {
        // All targets: -0.01; long term: +0.05.
        let recommendation = comparison(withAll: 0.29, withLong: 0.3, withoutAll: 0.3, withoutLong: 0.25).recommendation
        #expect(recommendation.tone == .worse)
        #expect(recommendation.text == "Recommended: exclude same-day reviews. All-target log loss changes by -0.0100, but long-term-only log loss changes by +0.0500.")
    }

    @Test func metricClassComparesEachCellWithTheOtherRow() {
        let result = comparison(withAll: 0.29, withLong: 0.3, withoutAll: 0.3, withoutLong: 0.25)
        let with = result.withSameDay
        let without = result.withoutSameDay
        #expect(result.other(than: with) == without)
        #expect(result.other(than: without) == with)
        typealias C = FsrsSameDayDecisionComparison
        #expect(C.metricClass(with.allTargets.logLoss, other: without.allTargets.logLoss) == .better)
        #expect(C.metricClass(without.allTargets.logLoss, other: with.allTargets.logLoss) == .worse)
        #expect(C.metricClass(with.longTermTargets.rmseBins, other: without.longTermTargets.rmseBins) == .equal)
    }
}
