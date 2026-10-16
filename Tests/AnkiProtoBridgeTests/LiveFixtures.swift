//
//  LiveFixtures.swift
//  AnkiProtoBridgeTests
//
//  Collection setup shared by the live probes: notes, answers, presets and
//  the RWKV model's location.
//

import Foundation
import AnkiProto
import SwiftProtobuf
import Testing
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend

/// Adds `count` Basic notes ("front 0" … ) to `deckId`; returns their ids.
@discardableResult
func addBasicNotes(_ backend: AnkiBackend, count: Int, deckId: DeckID = DeckID(1)) throws -> [NoteID] {
    let names = try backend.invoke(.notetypeNames)
    let basic = try #require(names.first { $0.name == "Basic" })
    for i in 0..<count {
        var template = try backend.invoke(.newNote(notetypeId: basic.id))
        template.fields[0] = "front \(i)"
        template.fields[1] = "back \(i)"
        try backend.invoke(.addNote(template: template, deckId: deckId))
    }
    return try backend.invoke(.searchNoteIds(query: "deck:*"))
}

/// Answers the top of the queue `count` times with `rating` through the
/// plain scheduler; returns the answered card ids in order.
@discardableResult
func answerQueued(_ backend: AnkiBackend, count: Int, rating: Rating) throws -> [CardID] {
    var answered: [CardID] = []
    for _ in 0..<count {
        let queued: QueuedCardsResult = try backend.invoke(.getQueuedCards(fetchLimit: 1))
        let entry = try #require(queued.cards.first)
        try backend.invoke(.answerReviewCard(
            cardId: entry.card.id,
            rating: rating,
            timeSpentMs: 4_000,
            states: entry.states
        ))
        answered.append(entry.card.id)
    }
    return answered
}

/// Turns on FSRS for the Default preset, and RWKV-Curve / RWKV-Instant as asked.
func configureDefaultPreset(_ backend: AnkiBackend, curve: Bool, instant: Bool) throws {
    let context = try backend.invoke(.deckConfigsForUpdate(deckId: DeckID(1)))
    var preset = try #require(context.allConfig.first?.config)
    preset.config.rwkvReviewEnabled = curve
    preset.config.rwkvReviewInstantOrderEnabled = instant
    try backend.invoke(.updateDeckConfigs(
        UpdateDeckConfigsRequest(targetDeckID: DeckID(1), configs: [preset], fsrs: true)
    ))
}

enum RwkvModel {
    /// The weights the app bundles: `RWKV_MODEL`, else the copy in the
    /// `anki-upstream` checkout (as the bridge's Rust tests look for it).
    /// Nil when neither exists, so model-dependent probes skip.
    static let path: String? = {
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["RWKV_MODEL"],
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // AnkiProtoBridgeTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // repo root
                .appendingPathComponent("anki-upstream/qt/aqt/rwkv_inference/RWKV_trained_on_5000_10000.bin")
                .path,
        ]
        return candidates
            .compactMap { $0 }
            .first { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
    }()

    static var isAvailable: Bool { path != nil }
}

/// Answers `cardId` as if `daysAgo` days ago: the revlog entry is dated
/// then, so FSRS sees a multi-day history. The states come from
/// `GetSchedulingStates`, which has no factory (the app reads them from the
/// queue), so this goes straight to the scheduler service.
func answerBackdated(_ backend: AnkiBackend, cardId: CardID, rating: Rating, daysAgo: Double) throws {
    let states = try backend.invoke(Request<Anki_Scheduler_SchedulingStates>(
        serviceId: ServiceID.scheduler,
        methodId: 26,   // SchedulerService.GetSchedulingStates, after the backend's five
        encode: { try Anki_Cards_CardId.with { $0.cid = cardId.rawValue }.serializedData() },
        decode: { try Anki_Scheduler_SchedulingStates(serializedBytes: $0) }
    ))
    var answer = Anki_Scheduler_CardAnswer()
    answer.cardID = cardId.rawValue
    answer.currentState = states.current
    switch rating {
    case .again: answer.newState = states.again; answer.rating = .again
    case .hard: answer.newState = states.hard; answer.rating = .hard
    case .good: answer.newState = states.good; answer.rating = .good
    case .easy: answer.newState = states.easy; answer.rating = .easy
    }
    answer.answeredAtMillis = Int64((Date().timeIntervalSince1970 - daysAgo * 86_400) * 1000)
    answer.millisecondsTaken = 5_000
    let body = answer
    try backend.invoke(Request<Void>(
        serviceId: ServiceID.scheduler,
        methodId: SchedulerMethod.answerCard,
        encode: { try body.serializedData() },
        decode: { _ in () }
    ))
}

/// `cards` Basic cards, each with six weeks of history: learnt 40 days ago,
/// reviewed at 30, lapsed and relearnt at 15, reviewed again 5 days ago.
@discardableResult
func addStudiedCards(_ backend: AnkiBackend, count: Int) throws -> [CardID] {
    // Card ids from the notes, not the queue: answering a card that isn't
    // at the top of a built queue is refused, and these answers skip it.
    let cards = try addBasicNotes(backend, count: count)
        .flatMap { try backend.invoke(.cardIDsOfNote(id: $0)) }
    try #require(cards.count == count)
    let schedule: [(Double, Rating)] = [
        (40, .good), (39.99, .good), (30, .good), (15, .again), (14.99, .good), (5, .good),
    ]
    for (index, card) in cards.enumerated() {
        // A second apart per card, so revlog ids never collide.
        let offset = Double(index) / 86_400
        for (daysAgo, rating) in schedule {
            try answerBackdated(backend, cardId: card, rating: rating, daysAgo: daysAgo - offset)
        }
    }
    return cards
}
