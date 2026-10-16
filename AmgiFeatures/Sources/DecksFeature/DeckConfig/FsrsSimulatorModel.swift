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
    /// The FSRS workload's answer-time model; the desktop shows it for a
    /// plain workload run only, not in review mode or the RWKV comparison.
    var reviewTime: FsrsReviewTime?
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
                reviewTime = nil
            case .workload:
                // `simulateWorkload`: one sweep per preset in the deck's
                // subtree, FSRS for every preset first, then RWKV.
                let presets: [DeckConfig] = context.workloadPresets
                var fsrsRuns: [FsrsWorkloadPresets.Run] = []
                for preset in presets {
                    let presetRequest = FsrsWorkloadPresets.request(
                        base: request,
                        deckName: context.workloadDeckName,
                        preset: preset
                    )
                    let result = try await deckClient.simulateFsrsWorkload(presetRequest)
                    guard generation == self.generation else { return }
                    fsrsRuns.append(FsrsWorkloadPresets.Run(presetName: preset.name, result: result))
                }
                guard context.compareWithRwkv else {
                    showRows(FsrsWorkloadPresets.rows(fsrsRuns))
                    reviewTime = FsrsWorkloadPresets.reviewTime(fsrsRuns)
                    return
                }
                var rwkvRuns: [FsrsWorkloadPresets.Run] = []
                for preset in presets {
                    var rwkvRequest = RwkvWorkloadRequest(
                        search: FsrsWorkloadPresets.search(
                            deckName: context.workloadDeckName,
                            presetName: preset.name
                        ),
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
                    rwkvRuns.append(FsrsWorkloadPresets.Run(presetName: preset.name, result: rwkv))
                }
                // Desired retentions both engines simulated for a preset,
                // as the desktop's comparison chart overlays them.
                showRows(FsrsWorkloadPresets.comparisonRows(fsrs: fsrsRuns, rwkv: rwkvRuns))
                reviewTime = nil
            }
        } catch {
            guard generation == self.generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func showRows(_ rows: [FsrsWorkloadPresets.Row]) {
        workloadRows = rows.map { (row: FsrsWorkloadPresets.Row) -> (label: String, value: String) in
            (label: row.label, value: row.value)
        }
        summary = [("Points", "\(workloadRows.count)")]
    }
}
