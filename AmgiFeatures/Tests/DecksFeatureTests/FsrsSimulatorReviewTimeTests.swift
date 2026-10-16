//
//  FsrsSimulatorReviewTimeTests.swift
//  DecksFeatureTests
//
//  The simulator keeps the answer-time breakdown only where the desktop
//  shows it: a plain workload run.
//

import AnkiClients
import AnkiKit
import Dependencies
import Foundation
import Testing
@testable import DecksFeature

private let reviewTime = FsrsReviewTime(
    rBucketCount: 20,
    sBucketCount: 1,
    againSeconds: Array(repeating: 8, count: 20),
    sampleCounts: Array(repeating: 1, count: 20)
)

@MainActor
@Suite struct FsrsSimulatorReviewTimeTests {
    private func context(_ mode: FsrsSimulatorMode, compare: Bool = false) -> FsrsSimulatorContext {
        var context = FsrsSimulatorContext(
            mode: mode,
            weights: [0.4, 0.6, 2.4, 5.8],
            desiredRetentionPercent: 90,
            historicalRetentionPercent: 90,
            newCardsPerDay: 20,
            reviewsPerDay: 200,
            maxIntervalDays: 36500,
            search: "deck:current",
            ignoreNewLimit: false,
            suspendLeeches: false,
            leechThreshold: 8,
            learningStepCount: 2,
            relearningStepCount: 1
        )
        context.rwkvAvailable = compare
        context.compareWithRwkv = compare
        context.workloadDeckName = "Current"
        context.workloadPresets = [DeckConfig(id: DeckConfigID(1), name: "Default")]
        return context
    }

    private func makeModel() -> FsrsSimulatorModel {
        withDependencies {
            $0.deckClient.simulateFsrsWorkload = { _ in
                FsrsWorkloadSimulation(
                    cost: [90: 1],
                    memorized: [90: 2],
                    reviewCount: [90: 3],
                    reviewTime: reviewTime
                )
            }
            $0.deckClient.simulateFsrsReview = { _ in
                FsrsReviewSimulation(accumulatedKnowledge: [1], dailyNewCount: [1], dailyReviewCount: [1], dailyTimeCost: [1])
            }
            $0.rwkvClient.simulateWorkload = { _ in
                FsrsWorkloadSimulation(cost: [90: 1], memorized: [90: 2], reviewCount: [90: 3], reviewTime: reviewTime)
            }
        } operation: {
            FsrsSimulatorModel()
        }
    }

    @Test func workloadKeepsTheBreakdown() async {
        let model = makeModel()
        await model.run(context: context(.workload), daysToSimulate: 30, additionalCards: 0)
        #expect(model.reviewTime == reviewTime)
    }

    @Test func comparisonAndReviewModeDropIt() async {
        let model = makeModel()
        await model.run(context: context(.workload), daysToSimulate: 30, additionalCards: 0)
        await model.run(context: context(.workload, compare: true), daysToSimulate: 30, additionalCards: 0)
        #expect(model.reviewTime == nil)

        await model.run(context: context(.workload), daysToSimulate: 30, additionalCards: 0)
        await model.run(context: context(.review), daysToSimulate: 30, additionalCards: 0)
        #expect(model.reviewTime == nil)
    }
}
