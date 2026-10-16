//
//  RwkvRequests.swift
//  AnkiProtoBridge
//
//  RWKV scheduling for the FSRS7/RWKV Anki fork, implemented in
//  anki-bridge-rs/src/rwkv. JSON over the aux service, like findDuplicates;
//  scheduling-state bytes travel base64-encoded.
//

import Foundation
public import AnkiBackend
public import AnkiKit
import AnkiProto
import SwiftProtobuf

private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
}()

private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()

private struct PrepareBody: Encodable {
    let modelPath: String
    let cacheDir: String?
    let precision: String
}

private struct PrepareResponse: Decodable {
    let active: Bool
    let ready: Bool
    let source: String
}

private struct ScoreDeckBody: Encodable {
    let deckId: Int64
    let newSession: Bool
}

private struct SchedulingStatesBody: Encodable {
    let cardId: Int64
    let states: String
}

private struct SchedulingStatesResponse: Decodable {
    let states: String
    let active: Bool
    let curve: Bool
}

private struct UndoBody: Encodable {
    let counter: UInt32
    let nextCounter: UInt32
}

private struct AnswerCardBody: Encodable {
    let cardId: Int64
    let rating: Int16
    let millisecondsTaken: UInt32
    let currentState: String
    let newState: String
}

// MARK: - prepare

extension Request where Response == RwkvPrepareResult {
    /// Loads the model and makes its resident state match the collection's
    /// review history: revalidated, restored from `cacheDir`, or replayed.
    /// Long-running on first use, so it bypasses the global call lock.
    public static func rwkvPrepare(modelPath: String, cacheDir: String?, precision: String) -> Self {
        prepare(AuxMethod.rwkvPrepare, modelPath: modelPath, cacheDir: cacheDir, precision: precision)
    }

    /// The deck options' "Build Cache": replays the whole review history,
    /// ignoring the resident and saved states, and saves the result.
    public static func rwkvRebuildState(modelPath: String, cacheDir: String?, precision: String) -> Self {
        prepare(AuxMethod.rwkvRebuildState, modelPath: modelPath, cacheDir: cacheDir, precision: precision)
    }

    private static func prepare(_ methodId: UInt32, modelPath: String, cacheDir: String?, precision: String) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: methodId,
            bypassesCallLock: true,
            encode: {
                try encoder.encode(PrepareBody(modelPath: modelPath, cacheDir: cacheDir, precision: precision))
            },
            decode: { data in
                let response = try decoder.decode(PrepareResponse.self, from: data)
                return RwkvPrepareResult(active: response.active, ready: response.ready, source: response.source)
            }
        )
    }
}

// MARK: - per-card states

extension Request where Response == QueuedReviewCard {
    /// The card as the answer buttons should show it: unchanged, or with
    /// RWKV-Curve's states and intervals when its preset uses Curve.
    public static func rwkvShownCard(_ queued: QueuedReviewCard, showFuzzDelta: Bool = false) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvSchedulingStates,
            bypassesCallLock: true,
            encode: {
                var states = Anki_Scheduler_SchedulingStates()
                states.current = try Anki_Scheduler_SchedulingState(serializedBytes: queued.states.current.bytes)
                states.again = try Anki_Scheduler_SchedulingState(serializedBytes: queued.states.again.bytes)
                states.hard = try Anki_Scheduler_SchedulingState(serializedBytes: queued.states.hard.bytes)
                states.good = try Anki_Scheduler_SchedulingState(serializedBytes: queued.states.good.bytes)
                states.easy = try Anki_Scheduler_SchedulingState(serializedBytes: queued.states.easy.bytes)
                let bytes: Data = try states.serializedBytes()
                return try encoder.encode(SchedulingStatesBody(
                    cardId: queued.card.id.rawValue,
                    states: bytes.base64EncodedString()
                ))
            },
            decode: { data in
                let response = try decoder.decode(SchedulingStatesResponse.self, from: data)
                guard response.curve, let bytes = Data(base64Encoded: response.states) else {
                    return queued
                }
                let states = try Anki_Scheduler_SchedulingStates(serializedBytes: bytes)
                return QueuedReviewCard(
                    card: queued.card,
                    states: ReviewSchedulingStates(
                        current: SchedulingStateToken(try states.current.serializedBytes()),
                        again: SchedulingStateToken(try states.again.serializedBytes()),
                        hard: SchedulingStateToken(try states.hard.serializedBytes()),
                        good: SchedulingStateToken(try states.good.serializedBytes()),
                        easy: SchedulingStateToken(try states.easy.serializedBytes())
                    ),
                    nextIntervals: [
                        .again: intervalLabel(states.again, showFuzzDelta: showFuzzDelta),
                        .hard: intervalLabel(states.hard, showFuzzDelta: showFuzzDelta),
                        .good: intervalLabel(states.good, showFuzzDelta: showFuzzDelta),
                        .easy: intervalLabel(states.easy, showFuzzDelta: showFuzzDelta),
                    ]
                )
            }
        )
    }
}

// MARK: - session, answers, persistence

extension Request where Response == Void {
    /// Installs RWKV-Instant queue scores for the deck about to be studied
    /// (or clears them when its preset doesn't use Instant).
    public static func rwkvScoreDeck(deckId: DeckID, newSession: Bool) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvScoreDeck,
            bypassesCallLock: true,
            encode: { try encoder.encode(ScoreDeckBody(deckId: deckId.rawValue, newSession: newSession)) },
            decode: { _ in () }
        )
    }

    /// Answers like `answerReviewCard`, adding the RWKV answer metadata and
    /// advancing the model's state when the card's preset uses RWKV.
    public static func rwkvAnswerCard(
        cardId: CardID,
        rating: Rating,
        timeSpentMs: UInt32,
        states: ReviewSchedulingStates
    ) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvAnswerCard,
            bypassesCallLock: true,
            encode: {
                let newState: Data = switch rating {
                case .again: states.again.bytes
                case .hard: states.hard.bytes
                case .good: states.good.bytes
                case .easy: states.easy.bytes
                }
                return try encoder.encode(AnswerCardBody(
                    cardId: cardId.rawValue,
                    rating: rating.rawValue,
                    millisecondsTaken: timeSpentMs,
                    currentState: states.current.bytes.base64EncodedString(),
                    newState: newState.base64EncodedString()
                ))
            },
            decode: { _ in () }
        )
    }

    /// `record_collection_undo`: call after every collection undo. When it
    /// took back an RWKV answer, the model's state goes back to before it.
    public static func rwkvUndoAnswer(_ outcome: UndoOutcome) -> Self {
        undoOrRedo(AuxMethod.rwkvUndoAnswer, outcome)
    }

    /// `record_collection_redo`: call after every collection redo. When it
    /// applied an RWKV answer again, the model's state advances as it did.
    public static func rwkvRedoAnswer(_ outcome: UndoOutcome) -> Self {
        undoOrRedo(AuxMethod.rwkvRedoAnswer, outcome)
    }

    private static func undoOrRedo(_ methodId: UInt32, _ outcome: UndoOutcome) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: methodId,
            bypassesCallLock: true,
            encode: {
                try encoder.encode(UndoBody(
                    counter: outcome.counter,
                    nextCounter: outcome.newStatus.lastStep
                ))
            },
            decode: { _ in () }
        )
    }

    /// Stops a running `rwkvSimulateWorkload`, which then throws.
    public static var rwkvCancelWorkload: Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvCancelWorkload,
            bypassesCallLock: true,
            encode: { Data("{}".utf8) },
            decode: { _ in () }
        )
    }

    /// The collection changed in a way that may touch review history.
    public static var rwkvInvalidate: Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvInvalidate,
            bypassesCallLock: true,
            encode: { Data("{}".utf8) },
            decode: { _ in () }
        )
    }

    /// Persists the model state, so the next launch restores instead of
    /// replaying the whole history.
    public static var rwkvSave: Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvSave,
            bypassesCallLock: true,
            encode: { Data("{}".utf8) },
            decode: { _ in () }
        )
    }
}

// MARK: - scores outside the review screen

private struct SearchScoresBody: Encodable {
    let search: String
    let wait: Bool
}

private struct DeckIdBody: Encodable {
    let deckId: Int64
}

private struct OptionalDeckIdBody: Encodable {
    let deckId: Int64?
}

private struct CardIdBody: Encodable {
    let cardId: Int64
}

private struct CardInfoResponse: Decodable {
    struct Row: Decodable {
        let label: String
        let value: String
    }

    let rows: [Row]
}

private struct RescheduleResponse: Decodable {
    let built: Bool
    let predicted: Int
    let updated: Int
}

extension Request where Response == Void {
    /// RWKV-Instant decks' counts include the cards RWKV would admit today.
    /// Call before fetching the deck tree; a no-op until the model is ready.
    public static var rwkvDeckCounts: Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvDeckCounts,
            bypassesCallLock: true,
            encode: { Data("{}".utf8) },
            decode: { _ in () }
        )
    }
}

private struct SearchScoresResponse: Decodable {
    let status: String
}

extension Request where Response == Bool {
    /// RWKV scores for `search`, read by the graphs and by searches using
    /// `prop:rwkv:r` / `is:rwkv:due`. `wait` rebuilds the model state if
    /// needed; graphs don't wait. True while the scores are pending (a
    /// history replay is running, so the graphs show FSRS values for now):
    /// the desktop's `X-Anki-Rwkv-Stats-Pending`.
    public static func rwkvSearchScores(search: String, wait: Bool) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvSearchScores,
            bypassesCallLock: true,
            encode: { try encoder.encode(SearchScoresBody(search: search, wait: wait)) },
            decode: { data in try decoder.decode(SearchScoresResponse.self, from: data).status == "pending" }
        )
    }
}

private struct SearchBody: Encodable {
    let search: String
}

private struct NoteIdsResponse: Decodable {
    let ids: [Int64]
}

private struct CountResponse: Decodable {
    let count: Int
}

extension Request where Response == [NoteID] {
    /// A note search using `prop:rwkv*:r` / `is:rwkv*:due`: RWKV scores are
    /// prepared and the search runs in one bridge call, so no other scoring
    /// can replace the scores in between.
    public static func rwkvSearchNoteIds(query: String) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvSearchNoteIds,
            bypassesCallLock: true,
            encode: { try encoder.encode(SearchBody(search: query.isEmpty ? "deck:*" : query)) },
            decode: { data in
                try decoder.decode(NoteIdsResponse.self, from: data).ids.map { NoteID($0) }
            }
        )
    }
}

extension Request where Response == Int {
    /// Rebuilds a filtered deck after preparing the RWKV scores its terms
    /// order or filter by; fails, like the desktop, when they aren't ready.
    public static func rwkvRebuildFilteredDeck(deckId: DeckID) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvRebuildFilteredDeck,
            bypassesCallLock: true,
            encode: { try encoder.encode(DeckIdBody(deckId: deckId.rawValue)) },
            decode: { data in try decoder.decode(CountResponse.self, from: data).count }
        )
    }
}

extension Request where Response == [RwkvCardInfoRow] {
    /// The desktop's RWKV Card Info rows; empty when the card's preset
    /// doesn't use RWKV.
    public static func rwkvCardInfo(cardId: CardID) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvCardInfo,
            bypassesCallLock: true,
            encode: { try encoder.encode(CardIdBody(cardId: cardId.rawValue)) },
            decode: { data in
                try decoder.decode(CardInfoResponse.self, from: data)
                    .rows
                    .map { RwkvCardInfoRow(label: $0.label, value: $0.value) }
            }
        )
    }
}

extension Request where Response == RwkvRescheduleResult {
    /// Writes RWKV-Curve's current interval and S90 to the review cards of
    /// RWKV-Curve presets, in `deckId` and its subdecks or (nil) everywhere.
    public static func rwkvReschedule(deckId: DeckID?) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvReschedule,
            bypassesCallLock: true,
            encode: { try encoder.encode(OptionalDeckIdBody(deckId: deckId?.rawValue)) },
            decode: { data in
                let response = try decoder.decode(RescheduleResponse.self, from: data)
                return RwkvRescheduleResult(
                    built: response.built,
                    predicted: response.predicted,
                    updated: response.updated
                )
            }
        )
    }
}

// MARK: - workload

private struct WorkloadBody: Encodable {
    let search: String
    let daysToSimulate: UInt32
    let reviewLimit: UInt32
    let newLimit: UInt32
    let newCardsIgnoreReviewLimit: Bool
    let maxInterval: UInt32
    let reviewOrder: Int
    let suspendAfterLapseCount: UInt32?
    let sampleLimit: UInt32
    let targetStep: UInt32
    let stateUpdateInterval: UInt32
}

private struct WorkloadResponse: Decodable {
    struct Point: Decodable {
        let dr: Int
        let memorized: Float
        let cost: Float
        let reviewCount: Int
    }

    let points: [Point]
    // `review_time_*`, as `_apply_rwkv_review_time_model` fills them.
    let reviewTimeRBucketCount: Int
    let reviewTimeSBucketCount: Int
    let reviewTimeAgainSeconds: [Float]
    let reviewTimeHardSeconds: [Float]
    let reviewTimeGoodSeconds: [Float]
    let reviewTimeEasySeconds: [Float]
    let reviewTimeSampleCounts: [Int]
    let reviewTimeAgainCoeffs: [Float]
    let reviewTimeHardCoeffs: [Float]
    let reviewTimeGoodCoeffs: [Float]
    let reviewTimeEasyCoeffs: [Float]
    let reviewTimeGradeWeights: [Float]
    let reviewTimeTransitionProbs: [Float]
    let reviewTimeTransitionCounts: [Int]
    let reviewTimeSuccessGradeProbs: [Float]
    let reviewTimeSuccessGradeCounts: [Int]
}

extension Request where Response == FsrsWorkloadSimulation {
    /// The RWKV workload for desired retentions 30–99%, simulated on the
    /// resident state (which it leaves unchanged). Long-running.
    public static func rwkvSimulateWorkload(_ input: RwkvWorkloadRequest) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvSimulateWorkload,
            bypassesCallLock: true,
            encode: {
                func count(_ value: Int) -> UInt32 { UInt32(clamping: max(0, value)) }
                return try encoder.encode(WorkloadBody(
                    search: input.search,
                    daysToSimulate: count(input.daysToSimulate),
                    reviewLimit: count(input.reviewLimit),
                    newLimit: count(input.newLimit),
                    newCardsIgnoreReviewLimit: input.newCardsIgnoreReviewLimit,
                    maxInterval: count(input.maxInterval),
                    reviewOrder: Anki_DeckConfig_DeckConfig.Config.ReviewCardOrder(input.reviewOrder).rawValue,
                    suspendAfterLapseCount: input.suspendAfterLapseCount.map(count),
                    sampleLimit: count(input.sampleLimit),
                    targetStep: count(input.targetStep),
                    stateUpdateInterval: count(input.stateUpdateInterval)
                ))
            },
            decode: { data in
                let response = try decoder.decode(WorkloadResponse.self, from: data)
                return FsrsWorkloadSimulation(
                    cost: Dictionary(response.points.map { ($0.dr, $0.cost) }, uniquingKeysWith: { _, last in last }),
                    memorized: Dictionary(response.points.map { ($0.dr, $0.memorized) }, uniquingKeysWith: { _, last in last }),
                    reviewCount: Dictionary(response.points.map { ($0.dr, $0.reviewCount) }, uniquingKeysWith: { _, last in last }),
                    reviewTime: FsrsReviewTime(
                        rBucketCount: response.reviewTimeRBucketCount,
                        sBucketCount: response.reviewTimeSBucketCount,
                        againSeconds: response.reviewTimeAgainSeconds,
                        hardSeconds: response.reviewTimeHardSeconds,
                        goodSeconds: response.reviewTimeGoodSeconds,
                        easySeconds: response.reviewTimeEasySeconds,
                        sampleCounts: response.reviewTimeSampleCounts,
                        againCoeffs: response.reviewTimeAgainCoeffs,
                        hardCoeffs: response.reviewTimeHardCoeffs,
                        goodCoeffs: response.reviewTimeGoodCoeffs,
                        easyCoeffs: response.reviewTimeEasyCoeffs,
                        gradeWeights: response.reviewTimeGradeWeights,
                        transitionProbs: response.reviewTimeTransitionProbs,
                        transitionCounts: response.reviewTimeTransitionCounts,
                        successGradeProbs: response.reviewTimeSuccessGradeProbs,
                        successGradeCounts: response.reviewTimeSuccessGradeCounts
                    )
                )
            }
        )
    }
}
