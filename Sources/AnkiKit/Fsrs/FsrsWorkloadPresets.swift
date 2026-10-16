//
//  FsrsWorkloadPresets.swift
//  AnkiKit
//
//  The desktop's ts/routes/deck-options/simulator-workload.ts and the
//  workload runs of SimulatorModal.svelte: the workload sweep (and its RWKV
//  comparison) runs once per preset used in the deck's subtree, over that
//  preset's cards in the deck, with that preset's parameters.
//

import Foundation

/// `workloadRequests` / `workloadRequestForPreset`.
public enum FsrsWorkloadPresets {
    /// `workloadSearchForPreset`.
    public static func search(deckName: String, presetName: String) -> String {
        "deck:\"\(DeckSearch.escape(deckName))\" preset:\"\(DeckSearch.escape(presetName))\" -is:suspended"
    }

    /// `subtreeConfigs()` sorted by name: the presets of the deck and its
    /// descendants, `current` (the preset as edited) in place of its stored
    /// copy. Only `current` when the backend reported no subtree.
    public static func subtreeConfigs(
        _ context: DeckConfigsForUpdate,
        current: DeckConfig
    ) -> [DeckConfig] {
        var seen: Set<DeckConfigID> = []
        var configs: [DeckConfig] = []
        for id in context.currentDeck?.subtreeConfigIds ?? [] where seen.insert(id).inserted {
            if id == current.id {
                configs.append(current)
            } else if let stored = context.allConfig.first(where: { $0.config.id == id }) {
                configs.append(stored.config)
            }
        }
        if configs.isEmpty {
            configs = [current]
        }
        return configs.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// `workloadRequestForPreset`: `base` with the preset's parameters,
    /// retentions, step counts and Dynamic DR model, over its cards in the
    /// deck.
    public static func request(
        base: FsrsSimulationRequest,
        deckName: String,
        preset: DeckConfig
    ) -> FsrsSimulationRequest {
        let inner = preset.config
        var request = FsrsSimulationRequest(
            weights: FsrsWeights(inner.activeFsrsParams),
            desiredRetention: inner.desiredRetention,
            additionalCards: base.additionalCards,
            daysToSimulate: base.daysToSimulate,
            newLimit: base.newLimit,
            reviewLimit: base.reviewLimit,
            maxIntervalDays: base.maxIntervalDays,
            search: search(deckName: deckName, presetName: preset.name),
            newCardsIgnoreReviewLimit: base.newCardsIgnoreReviewLimit,
            historicalRetention: inner.historicalRetention,
            learningStepCount: inner.learnSteps.count,
            relearningStepCount: inner.relearnSteps.count,
            suspendAfterLapseCount: base.suspendAfterLapseCount
        )
        request.easyDaysPercentages = base.easyDaysPercentages
        request.reviewOrder = base.reviewOrder
        request.reviewFuzz = base.reviewFuzz
        request.dynamicDesiredRetention = inner.fsrsDynamicDesiredRetention
        request.dynamicDesiredRetentionClamp = inner.fsrsDynamicDesiredRetentionClamp
        return request
    }

    /// One preset's workload sweep.
    public struct Run: Sendable, Hashable {
        public var presetName: String
        public var result: FsrsWorkloadSimulation

        public init(presetName: String, result: FsrsWorkloadSimulation) {
            self.presetName = presetName
            self.result = result
        }
    }

    /// A desired retention's results, one line per preset (and engine).
    public struct Row: Sendable, Hashable {
        public var label: String
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// The FSRS sweeps by desired retention. Lines are named as the
    /// desktop's series (`<preset> (Fixed DR)`) when there is more than one.
    public static func rows(_ runs: [Run]) -> [Row] {
        let retentions = Set(runs.flatMap { $0.result.cost.keys }).sorted()
        return retentions.map { retention in
            let lines = runs.compactMap { run -> String? in
                guard run.result.cost[retention] != nil else { return nil }
                let text = workloadText(run.result, retention)
                return runs.count > 1 ? "\(run.presetName) (Fixed DR): \(text)" : text
            }
            return Row(label: "\(retention)%", value: lines.joined(separator: "\n"))
        }
    }

    /// FSRS and RWKV overlaid per preset, at the desired retentions both
    /// simulated for it; `rwkv` holds the same presets in the same order.
    public static func comparisonRows(fsrs: [Run], rwkv: [Run]) -> [Row] {
        let pairs: [(name: String, fsrs: FsrsWorkloadSimulation, rwkv: FsrsWorkloadSimulation)] =
            zip(fsrs, rwkv).map { (fsrsRun: Run, rwkvRun: Run) in
                (name: fsrsRun.presetName, fsrs: fsrsRun.result, rwkv: rwkvRun.result)
            }
        let shared = pairs.map { pair in Set(pair.fsrs.cost.keys).intersection(pair.rwkv.cost.keys) }
        let retentions = shared.reduce(into: Set<Int>()) { $0.formUnion($1) }.sorted()
        return retentions.map { retention in
            var lines: [String] = []
            for (index, pair) in pairs.enumerated() where shared[index].contains(retention) {
                let prefix = pairs.count > 1 ? "\(pair.name) · " : ""
                lines.append("\(prefix)FSRS \(workloadText(pair.fsrs, retention))")
                lines.append("\(prefix)RWKV \(workloadText(pair.rwkv, retention))")
            }
            return Row(label: "\(retention)%", value: lines.joined(separator: "\n"))
        }
    }

    /// The answer-time model shown under the sweep: the first run's that
    /// has samples, else the first run's.
    public static func reviewTime(_ runs: [Run]) -> FsrsReviewTime? {
        runs.first(where: { !$0.result.reviewTime.sampleCounts.isEmpty })?.result.reviewTime
            ?? runs.first?.result.reviewTime
    }

    static func workloadText(_ result: FsrsWorkloadSimulation, _ retention: Int) -> String {
        String(
            format: "cost %.2f · reviews %d · memorized %.0f",
            Double(result.cost[retention] ?? 0),
            result.reviewCount[retention] ?? 0,
            Double(result.memorized[retention] ?? 0)
        )
    }
}
