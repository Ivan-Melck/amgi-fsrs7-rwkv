//
//  FsrsWorkloadPresetsTests.swift
//  AnkiKitTests
//
//  The workload simulator's per-preset runs (ts/routes/deck-options/
//  simulator-workload.ts and SimulatorModal.svelte), the deck options'
//  search escaping (lib.ts's `escapeSearchText`) and the limits sent with a
//  preset action.
//

import Testing
@testable import AnkiKit

@Suite("FSRS workload presets")
struct FsrsWorkloadPresetsTests {
    private func preset(_ id: Int64, _ name: String, params: [Float] = [1, 2]) -> DeckConfig {
        var config = DeckConfig(id: DeckConfigID(id), name: name)
        config.config.activeFsrsParams = params
        return config
    }

    private func context(_ presets: [DeckConfig], subtree: [Int64]) -> DeckConfigsForUpdate {
        DeckConfigsForUpdate(
            allConfig: presets.map { DeckConfigsForUpdate.ConfigWithExtra(config: $0) },
            currentDeck: DeckConfigsForUpdate.CurrentDeck(
                name: "Parent",
                configID: DeckConfigID(1),
                subtreeConfigIds: subtree.map { DeckConfigID($0) }
            )
        )
    }

    private func baseRequest() -> FsrsSimulationRequest {
        var request = FsrsSimulationRequest(
            weights: FsrsWeights([9]),
            desiredRetention: 0.8,
            additionalCards: 10,
            daysToSimulate: 365,
            newLimit: 20,
            reviewLimit: 9999,
            maxIntervalDays: 36500,
            search: "preset:\"Current\" -is:suspended",
            newCardsIgnoreReviewLimit: true,
            historicalRetention: 0.9,
            learningStepCount: 5,
            relearningStepCount: 5,
            suspendAfterLapseCount: 8
        )
        request.easyDaysPercentages = [1, 1, 1, 1, 1, 0.5, 0]
        request.reviewOrder = .random
        return request
    }

    // MARK: - Searches

    @Test func escapesBackslashesAndQuotesLikeEscapeSearchText() {
        #expect(DeckSearch.escape(#"a\b"c"#) == #"a\\b\"c"#)
        #expect(DeckSearch.presetSearch(#"My "A\B""#) == #"preset:"My \"A\\B\"" -is:suspended"#)
        #expect(DeckSearch.term(#"Deck\One"#) == #"deck:"Deck\\One""#)
    }

    @Test func searchesThePresetsCardsInTheDeck() {
        #expect(
            FsrsWorkloadPresets.search(deckName: #"Lang::"JP""#, presetName: #"A\B"#)
                == #"deck:"Lang::\"JP\"" preset:"A\\B" -is:suspended"#
        )
    }

    // MARK: - Subtree presets

    @Test func runsEverySubtreePresetSortedByNameWithTheCurrentOneAsEdited() {
        let stored = [preset(1, "Current", params: [1]), preset(2, "Beta"), preset(3, "Alpha"), preset(4, "Unused")]
        let edited = preset(1, "Current", params: [7])
        let configs = FsrsWorkloadPresets.subtreeConfigs(context(stored, subtree: [1, 2, 3, 2]), current: edited)
        #expect(configs.map(\.name) == ["Alpha", "Beta", "Current"])
        #expect(configs.last?.config.activeFsrsParams == [7])
    }

    @Test func fallsBackToTheCurrentPresetWithoutASubtree() {
        let edited = preset(1, "Current")
        #expect(FsrsWorkloadPresets.subtreeConfigs(context([edited], subtree: []), current: edited) == [edited])
    }

    // MARK: - Requests

    @Test func requestUsesThePresetsOwnSettings() {
        var other = preset(2, "Other", params: [3, 4, 5])
        other.config.desiredRetention = 0.85
        other.config.historicalRetention = 0.75
        other.config.learnSteps = [1, 10]
        other.config.relearnSteps = [10]
        other.config.fsrsDynamicDesiredRetentionClamp = true
        let request = FsrsWorkloadPresets.request(base: baseRequest(), deckName: "Parent", preset: other)
        #expect(request.weights == FsrsWeights([3, 4, 5]))
        #expect(request.desiredRetention == 0.85)
        #expect(request.historicalRetention == 0.75)
        #expect(request.learningStepCount == 2)
        #expect(request.relearningStepCount == 1)
        #expect(request.search == #"deck:"Parent" preset:"Other" -is:suspended"#)
        #expect(request.dynamicDesiredRetentionClamp)
        // The rest is the simulator's.
        #expect(request.additionalCards == 10)
        #expect(request.daysToSimulate == 365)
        #expect(request.newLimit == 20)
        #expect(request.reviewLimit == 9999)
        #expect(request.maxIntervalDays == 36500)
        #expect(request.newCardsIgnoreReviewLimit)
        #expect(request.suspendAfterLapseCount == 8)
        #expect(request.easyDaysPercentages == [1, 1, 1, 1, 1, 0.5, 0])
        #expect(request.reviewOrder == .random)
    }

    // MARK: - Rows

    private func workload(_ cost: [Int: Float]) -> FsrsWorkloadSimulation {
        FsrsWorkloadSimulation(
            cost: cost,
            memorized: cost.mapValues { $0 * 10 },
            reviewCount: cost.mapValues { Int($0) }
        )
    }

    @Test func oneRowPerRetentionAndALinePerPreset() {
        let single = FsrsWorkloadPresets.rows([.init(presetName: "A", result: workload([80: 1, 90: 2]))])
        #expect(single.map(\.label) == ["80%", "90%"])
        #expect(single[1].value == "cost 2.00 · reviews 2 · memorized 20")

        let several = FsrsWorkloadPresets.rows([
            .init(presetName: "A", result: workload([80: 1, 90: 2])),
            .init(presetName: "B", result: workload([90: 3]))
        ])
        #expect(several.map(\.label) == ["80%", "90%"])
        #expect(several[0].value == "A (Fixed DR): cost 1.00 · reviews 1 · memorized 10")
        #expect(several[1].value.split(separator: "\n").count == 2)
        #expect(several[1].value.hasSuffix("B (Fixed DR): cost 3.00 · reviews 3 · memorized 30"))
    }

    @Test func comparisonOverlaysEachPresetsEngines() {
        let fsrs: [FsrsWorkloadPresets.Run] = [
            .init(presetName: "A", result: workload([80: 1, 90: 2])),
            .init(presetName: "B", result: workload([90: 3]))
        ]
        let rwkv: [FsrsWorkloadPresets.Run] = [
            .init(presetName: "A", result: workload([90: 4])),
            .init(presetName: "B", result: workload([80: 5, 90: 6]))
        ]
        let rows = FsrsWorkloadPresets.comparisonRows(fsrs: fsrs, rwkv: rwkv)
        // 80% was simulated by both engines for no preset.
        #expect(rows.map(\.label) == ["90%"])
        #expect(rows[0].value.split(separator: "\n").map(String.init) == [
            "A · FSRS cost 2.00 · reviews 2 · memorized 20",
            "A · RWKV cost 4.00 · reviews 4 · memorized 40",
            "B · FSRS cost 3.00 · reviews 3 · memorized 30",
            "B · RWKV cost 6.00 · reviews 6 · memorized 60"
        ])

        let single = FsrsWorkloadPresets.comparisonRows(fsrs: [fsrs[0]], rwkv: [rwkv[0]])
        #expect(single.map(\.value) == [
            "FSRS cost 2.00 · reviews 2 · memorized 20\nRWKV cost 4.00 · reviews 4 · memorized 40"
        ])
    }

    @Test func reviewTimeComesFromTheFirstRunWithSamples() {
        var sampled = workload([90: 1])
        sampled.reviewTime.sampleCounts = [3]
        let runs: [FsrsWorkloadPresets.Run] = [
            .init(presetName: "A", result: workload([90: 1])),
            .init(presetName: "B", result: sampled)
        ]
        #expect(FsrsWorkloadPresets.reviewTime(runs)?.sampleCounts == [3])
        #expect(FsrsWorkloadPresets.reviewTime([]) == nil)
    }

    // MARK: - Limits sent with a preset action

    @Test func leavesOutATodayLimitFromAPastDay() {
        let past = DeckConfigsForUpdate.CurrentDeck.Limits(
            review: 100, new: 10, reviewToday: 50, newToday: 5,
            reviewTodayActive: false, newTodayActive: false, desiredRetention: 0.9
        )
        let sent = past.forUpdate
        #expect(sent.newToday == nil)
        #expect(sent.reviewToday == nil)
        #expect(sent.review == 100)
        #expect(sent.new == 10)
        #expect(sent.desiredRetention == 0.9)

        var today = past
        today.newTodayActive = true
        #expect(today.forUpdate.newToday == 5)
        #expect(today.forUpdate.reviewToday == nil)
    }
}
