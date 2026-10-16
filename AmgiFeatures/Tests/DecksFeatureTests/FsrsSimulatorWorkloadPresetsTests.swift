//
//  FsrsSimulatorWorkloadPresetsTests.swift
//  DecksFeatureTests
//
//  A workload run simulates each preset of the deck's subtree over its own
//  cards in the deck, with its own parameters, as the desktop's
//  SimulatorModal.svelte does — FSRS for every preset, then RWKV.
//

import AnkiClients
import AnkiKit
import ConcurrencyExtras
import Dependencies
import Foundation
import Testing
@testable import DecksFeature

@MainActor
@Suite struct FsrsSimulatorWorkloadPresetsTests {
    private func preset(_ id: Int64, _ name: String, params: [Float]) -> DeckConfig {
        var config = DeckConfig(id: DeckConfigID(id), name: name)
        config.config.activeFsrsParams = params
        return config
    }

    private func context(compare: Bool) -> FsrsSimulatorContext {
        var context = FsrsSimulatorContext(
            mode: .workload,
            weights: [0.4, 0.6, 2.4, 5.8],
            desiredRetentionPercent: 90,
            historicalRetentionPercent: 90,
            newCardsPerDay: 20,
            reviewsPerDay: 9999,
            maxIntervalDays: 36500,
            search: "preset:\"Beta\" -is:suspended",
            ignoreNewLimit: false,
            suspendLeeches: false,
            leechThreshold: 8,
            learningStepCount: 2,
            relearningStepCount: 1
        )
        context.rwkvAvailable = compare
        context.compareWithRwkv = compare
        context.workloadDeckName = "Lang"
        context.workloadPresets = [
            preset(2, "Alpha", params: [1]),
            preset(1, "Beta", params: [2])
        ]
        return context
    }

    @Test func runsEachPresetOverItsCardsInTheDeck() async {
        let fsrsRequests = LockIsolated<[FsrsSimulationRequest]>([])
        let rwkvSearches = LockIsolated<[String]>([])
        let model = withDependencies {
            $0.deckClient.simulateFsrsWorkload = { request in
                fsrsRequests.withValue { $0.append(request) }
                return FsrsWorkloadSimulation(cost: [90: 1], memorized: [90: 2], reviewCount: [90: 3])
            }
            $0.rwkvClient.simulateWorkload = { request in
                rwkvSearches.withValue { $0.append(request.search) }
                return FsrsWorkloadSimulation(cost: [90: 4], memorized: [90: 5], reviewCount: [90: 6])
            }
        } operation: {
            FsrsSimulatorModel()
        }

        await model.run(context: context(compare: true), daysToSimulate: 30, additionalCards: 0)

        #expect(fsrsRequests.value.map(\.search) == [
            "deck:\"Lang\" preset:\"Alpha\" -is:suspended",
            "deck:\"Lang\" preset:\"Beta\" -is:suspended"
        ])
        #expect(fsrsRequests.value.map(\.weights) == [FsrsWeights([1]), FsrsWeights([2])])
        #expect(rwkvSearches.value == fsrsRequests.value.map(\.search))
        #expect(model.workloadRows.count == 1)
        #expect(model.workloadRows.first?.value.contains("Alpha · RWKV") == true)
        #expect(model.errorMessage == nil)
    }
}
