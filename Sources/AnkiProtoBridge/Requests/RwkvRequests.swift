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
    public static func rwkvPrepare(modelPath: String, cacheDir: String?) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvPrepare,
            bypassesCallLock: true,
            encode: { try encoder.encode(PrepareBody(modelPath: modelPath, cacheDir: cacheDir)) },
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
    public static func rwkvShownCard(_ queued: QueuedReviewCard) -> Self {
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
                        .again: formatInterval(scheduledSecs(states.again)),
                        .hard: formatInterval(scheduledSecs(states.hard)),
                        .good: formatInterval(scheduledSecs(states.good)),
                        .easy: formatInterval(scheduledSecs(states.easy)),
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

    /// Call after the collection's undo removed the most recent answer.
    public static var rwkvUndoAnswer: Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvUndoAnswer,
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
