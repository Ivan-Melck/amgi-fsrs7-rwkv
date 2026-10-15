//
//  FsrsSimulatorModel.swift
//  DecksFeature
//
//  Created by Vladimir Gusev on 27.06.2026.
//

import AnkiClients
import AnkiKit
import Dependencies
import Foundation

/// FSRS simulation I/O for the simulator sheet. Owns the `deckClient`
/// dependency plus the run flag and result rows so the view carries no
/// `@Dependency`; the editable simulation context and the days/additional
/// inputs stay on the view and are passed into `run`.
@Observable
@MainActor
final class FsrsSimulatorModel {
    var isRunning = false
    var summary: [(label: String, value: String)] = []
    var workloadRows: [(label: String, value: String)] = []
    var errorMessage: String?

    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.rwkvClient) private var rwkvClient
    @ObservationIgnored private var generation = 0

    func cancel() {
        generation &+= 1
        isRunning = false
        Task { await rwkvClient.cancelWorkload() }
    }

    func run(context: FsrsSimulatorContext, daysToSimulate: Int, additionalCards: Int) async {
        let generation = self.generation
        isRunning = true
        defer { if generation == self.generation { isRunning = false } }
        errorMessage = nil

        var request = FsrsSimulationRequest(
            weights: FsrsWeights(context.weights),
            desiredRetention: Float(context.desiredRetentionPercent / 100),
            additionalCards: max(0, additionalCards),
            daysToSimulate: max(1, daysToSimulate),
            newLimit: max(0, context.newCardsPerDay),
            reviewLimit: max(0, context.reviewsPerDay),
            maxIntervalDays: max(1, context.maxIntervalDays),
            search: context.search,
            newCardsIgnoreReviewLimit: context.ignoreNewLimit,
            historicalRetention: Float(context.historicalRetentionPercent / 100),
            learningStepCount: context.learningStepCount,
            relearningStepCount: context.relearningStepCount,
            suspendAfterLapseCount: context.suspendLeeches ? max(1, context.leechThreshold) : nil
        )
        request.easyDaysPercentages = context.easyDaysPercentages
        request.reviewOrder = context.reviewOrder
        request.reviewFuzz = context.reviewFuzz
        request.dynamicDesiredRetention = context.dynamicDesiredRetention
        request.dynamicDesiredRetentionClamp = context.dynamicDesiredRetentionClamp

        do {
            switch context.mode {
            case .review:
                let result = try await deckClient.simulateFsrsReview(request)
                guard generation == self.generation else { return }
                let totalNew = result.dailyNewCount.reduce(0, +)
                let totalReview = result.dailyReviewCount.reduce(0, +)
                let totalTime = result.dailyTimeCost.reduce(0, +)
                let memorized = result.accumulatedKnowledge.last ?? 0
                let days = max(result.dailyReviewCount.count, 1)
                summary = [
                    ("Total new", "\(totalNew)"),
                    ("Total reviews", "\(totalReview)"),
                    ("Avg reviews/day", String(format: "%.1f", Double(totalReview) / Double(days))),
                    ("Total time (s)", String(format: "%.1f", Double(totalTime))),
                    ("Memorized (end)", String(format: "%.1f", Double(memorized)))
                ]
                workloadRows = []
            case .workload:
                let result = try await deckClient.simulateFsrsWorkload(request)
                guard generation == self.generation else { return }
                guard context.compareWithRwkv else {
                    workloadRows = result.cost.keys.sorted().map { retention in
                        ("\(retention)%", Self.workloadText(result, retention))
                    }
                    summary = [("Points", "\(workloadRows.count)")]
                    return
                }
                var rwkvRequest = RwkvWorkloadRequest(
                    search: context.search,
                    daysToSimulate: max(1, daysToSimulate),
                    reviewLimit: max(0, context.reviewsPerDay),
                    newLimit: max(0, context.newCardsPerDay),
                    newCardsIgnoreReviewLimit: context.ignoreNewLimit,
                    maxInterval: max(1, context.maxIntervalDays),
                    reviewOrder: context.reviewOrder,
                    suspendAfterLapseCount: context.suspendLeeches ? max(1, context.leechThreshold) : nil
                )
                rwkvRequest.sampleLimit = 0
                let rwkv = try await rwkvClient.simulateWorkload(rwkvRequest)
                guard generation == self.generation else { return }
                // Desired retentions both engines simulated, as the
                // desktop's comparison chart overlays them.
                let retentions = Set(result.cost.keys).intersection(rwkv.cost.keys).sorted()
                workloadRows = retentions.map { retention in
                    (
                        "\(retention)%",
                        "FSRS \(Self.workloadText(result, retention))\nRWKV \(Self.workloadText(rwkv, retention))"
                    )
                }
                summary = [("Points", "\(workloadRows.count)")]
            }
        } catch {
            guard generation == self.generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    private static func workloadText(_ result: FsrsWorkloadSimulation, _ retention: Int) -> String {
        String(
            format: "cost %.2f · reviews %d · memorized %.0f",
            Double(result.cost[retention] ?? 0),
            result.reviewCount[retention] ?? 0,
            Double(result.memorized[retention] ?? 0)
        )
    }
}
