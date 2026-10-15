//
//  SchedulerService.swift
//  AnkiServices
//
//  Created by Vladimir Gusev on 01.04.2026.
//

import AnkiBackend
import AnkiProtoBridge
public import AnkiKit
public import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
public struct SchedulerService: Sendable {
    /// Full queue fetch including scheduling states and pre-computed next intervals.
    public var getQueuedCards: @Sendable (_ fetchLimit: Int32) throws -> QueuedCardsResult
    /// Answer with scheduling states previously returned by getQueuedCards.
    public var answerReviewCard: @Sendable (_ cardId: CardID, _ rating: Rating, _ timeSpent: UInt32, _ states: ReviewSchedulingStates) throws -> Void

    // RWKV scheduling (the FSRS7/RWKV fork's RWKV-Curve and RWKV-Instant
    // presets). No-ops when the app bundles no RWKV model or no preset uses
    // RWKV; `getQueuedCards` and `answerReviewCard` then behave as upstream.

    /// Readies the model for the open collection; slow only the first time.
    public var prepareRwkv: @Sendable () throws -> RwkvPrepareResult? = { nil }
    /// Before the first `getQueuedCards` of a review session.
    public var beginSession: @Sendable (_ deckId: DeckID) throws -> Void = { _ in }
    /// After `undoLast()`; `wasAnswer` when the undone operation was an answer.
    public var didUndo: @Sendable (_ wasAnswer: Bool) throws -> Void = { _ in }
    /// Persists the model state, e.g. when the app goes to the background.
    public var saveRwkvState: @Sendable () throws -> Void = {}
}

extension SchedulerService: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend
        let modelPath = RwkvEnvironment.modelPath
        let prepare: @Sendable () throws -> RwkvPrepareResult? = {
            guard let modelPath else { return nil }
            return try backend.invoke(.rwkvPrepare(
                modelPath: modelPath,
                cacheDir: RwkvEnvironment.cacheDir(backend),
                precision: RwkvEnvironment.precision
            ))
        }
        return Self(
            getQueuedCards: { fetchLimit in
                // The fork's synced "Show fuzz delta next to answer button
                // intervals" (BoolKey SHOW_FUZZ_DELTA_ABOVE_ANSWER_BUTTONS).
                let fuzzDeltaSetting: Bool? = try? backend.getConfigJSONValue(for: fuzzDeltaConfigKey)
                let showFuzzDelta = fuzzDeltaSetting ?? false
                let result = try backend.invoke(.getQueuedCards(
                    fetchLimit: UInt32(max(0, fetchLimit)),
                    showFuzzDelta: showFuzzDelta
                ))
                guard modelPath != nil, let head = result.cards.first else { return result }
                // The head is the card about to be shown: give RWKV-Curve the
                // chance to supply its states and button intervals. Like the
                // desktop, a failed prediction leaves the upstream states.
                let shown = (try? backend.invoke(.rwkvShownCard(head, showFuzzDelta: showFuzzDelta))) ?? head
                return QueuedCardsResult(
                    cards: [shown] + result.cards.dropFirst(),
                    newCount: result.newCount,
                    learningCount: result.learningCount,
                    reviewCount: result.reviewCount
                )
            },
            answerReviewCard: { cardId, rating, timeSpent, states in
                if modelPath != nil {
                    try backend.invoke(.rwkvAnswerCard(
                        cardId: cardId, rating: rating, timeSpentMs: timeSpent, states: states
                    ))
                } else {
                    try backend.invoke(.answerReviewCard(
                        cardId: cardId, rating: rating, timeSpentMs: timeSpent, states: states
                    ))
                }
            },
            prepareRwkv: prepare,
            beginSession: { deckId in
                guard let result = try prepare(), result.active else { return }
                try backend.invoke(.rwkvScoreDeck(deckId: deckId, newSession: true))
            },
            didUndo: { wasAnswer in
                guard modelPath != nil else { return }
                if wasAnswer {
                    try backend.invoke(Request<Void>.rwkvUndoAnswer)
                } else {
                    try backend.invoke(Request<Void>.rwkvInvalidate)
                }
            },
            saveRwkvState: {
                guard modelPath != nil else { return }
                try backend.invoke(.rwkvSave)
            }
        )
    }()
}

/// Collection config key of the fork's fuzz-delta label setting.
public let fuzzDeltaConfigKey = "showFuzzDeltaAboveAnswerButtons"

extension SchedulerService: TestDependencyKey {
    public static let testValue = SchedulerService()
}

extension DependencyValues {
    public var schedulerService: SchedulerService {
        get { self[SchedulerService.self] }
        set { self[SchedulerService.self] = newValue }
    }
}
