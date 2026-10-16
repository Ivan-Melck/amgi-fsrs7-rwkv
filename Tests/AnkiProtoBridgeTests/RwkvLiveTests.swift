//
//  RwkvLiveTests.swift
//  AnkiProtoBridgeTests
//
//  Round trips of the RWKV scheduling aux requests (service 200, JSON) and
//  the Memorised chart's RWKV history against the real bridge. The replay
//  and prediction logic itself is tested in anki-bridge-rs/src/rwkv/tests.rs;
//  these catch a wrong method id or a JSON shape that drifted from the Rust
//  serde structs, which nothing else would.
//
//  Probes that need the weights run when `RWKV_MODEL` names them, or the
//  `anki-upstream` checkout has them; otherwise they are skipped and only
//  the model-free behaviour (inactive presets, "unavailable" answers) is
//  checked.
//
//  Serialized: the bridge's replay flag, the workload's cancel flag and the
//  Memorised history job are process-wide.
//

import Foundation
import Testing
import AnkiKit
import AnkiProto
import SwiftProtobuf
@testable import AnkiProtoBridge
@testable import AnkiBackend

@Suite(.serialized) struct RwkvLiveTests {
    private static let missingModel = "/nonexistent/RWKV_trained_on_5000_10000.bin"
    private static let modelSkip = Comment(rawValue: "set RWKV_MODEL to the RWKV weights to run")
    /// `cache.rs`'s file name for the persisted model state.
    private static let stateFile = "rwkv-state.bin"

    // MARK: - helpers

    private func queuedCard(_ backend: AnkiBackend) throws -> QueuedReviewCard {
        let queued: QueuedCardsResult = try backend.invoke(.getQueuedCards(fetchLimit: 1))
        return try #require(queued.cards.first)
    }

    private func prepare(_ backend: AnkiBackend, model: String, cacheDir: URL?) throws -> RwkvPrepareResult {
        try backend.invoke(.rwkvPrepare(modelPath: model, cacheDir: cacheDir?.path, precision: "int8"))
    }

    private func workloadRequest() -> RwkvWorkloadRequest {
        var request = RwkvWorkloadRequest(
            search: "deck:*",
            daysToSimulate: 3,
            reviewLimit: 100,
            newLimit: 5,
            newCardsIgnoreReviewLimit: false,
            maxInterval: 36_500,
            reviewOrder: .day,
            suspendAfterLapseCount: nil
        )
        request.targetStep = 23   // 30, 53, 76, 99: four points keep it quick
        return request
    }

    /// A filtered deck over the Default deck, built by the backend
    /// (`GetOrCreateFilteredDeck` + `AddOrUpdateFilteredDeck`, which have no
    /// factory: the app only rebuilds filtered decks).
    private func addFilteredDeck(
        _ backend: AnkiBackend,
        name: String,
        search: String,
        order: Anki_Decks_Deck.Filtered.SearchTerm.Order
    ) throws -> DeckID {
        var filtered = try backend.invoke(Request<Anki_Decks_FilteredDeckForUpdate>(
            serviceId: ServiceID.decks,
            methodId: 19,
            encode: { try Anki_Decks_DeckId.with { $0.did = 0 }.serializedData() },
            decode: { try Anki_Decks_FilteredDeckForUpdate(serializedBytes: $0) }
        ))
        filtered.name = name
        filtered.allowEmpty = true
        filtered.config.searchTerms = [.with {
            $0.search = search
            $0.limit = 100
            $0.order = order
        }]
        let deck = filtered
        let id = try backend.invoke(Request<Int64>(
            serviceId: ServiceID.decks,
            methodId: 20,
            encode: { try deck.serializedData() },
            decode: { try Anki_Collection_OpChangesWithId(serializedBytes: $0).id }
        ))
        return DeckID(id)
    }

    // MARK: - without an RWKV preset (no model needed)

    @Test func inactiveCollection_prepareAndRebuildNeverLoadTheModel() throws {
        try withScratchCollection("rwkv-inactive") { backend, dir in
            try addBasicNotes(backend, count: 2)
            // A path that doesn't exist: with no RWKV preset it is never read.
            let prepared = try prepare(backend, model: Self.missingModel, cacheDir: dir)
            #expect(prepared == RwkvPrepareResult(active: false, ready: false, source: "inactive"))

            let rebuilt = try backend.invoke(.rwkvRebuildState(
                modelPath: Self.missingModel, cacheDir: dir.path, precision: "int8"
            ))
            #expect(rebuilt == RwkvPrepareResult(active: false, ready: false, source: "inactive"))
        }
    }

    @Test func inactiveCollection_reviewPathsMatchThePlainScheduler() throws {
        try withScratchCollection("rwkv-inactive-review") { backend, _ in
            try addBasicNotes(backend, count: 2)
            let countsBefore = try backend.invoke(.deckCounts(for: DeckID(1)))
            try backend.invoke(.rwkvScoreDeck(deckId: DeckID(1), newSession: true))
            try backend.invoke(.rwkvDeckCounts)
            #expect(try backend.invoke(.deckCounts(for: DeckID(1))) == countsBefore)

            let entry = try queuedCard(backend)
            // Not an RWKV preset: the card comes back exactly as shown.
            let shown = try backend.invoke(.rwkvShownCard(entry))
            #expect(shown.card.id == entry.card.id)
            #expect(shown.states.good.bytes == entry.states.good.bytes)
            #expect(shown.nextIntervals == entry.nextIntervals)
            #expect(try backend.invoke(.rwkvCardInfo(cardId: entry.card.id)).isEmpty)

            try backend.invoke(.rwkvAnswerCard(
                cardId: entry.card.id, rating: .good, timeSpentMs: 2_500, states: shown.states
            ))
            let answered = try backend.invoke(.getCard(id: entry.card.id))
            #expect(answered.reps == 1)
            #expect(answered.type != 0, "the answer went through the scheduler")
            #expect(try backend.invoke(.graphs(search: "deck:*", days: 1)).today.answerCount == 1)

            // Undo / redo hooks are no-ops without RWKV frames, and must not
            // get in the way of the collection's own undo.
            let undone = try backend.invoke(.undo)
            try backend.invoke(.rwkvUndoAnswer(undone))
            #expect(try backend.invoke(.getCard(id: entry.card.id)).reps == 0)
            let redone = try backend.invoke(.redo)
            try backend.invoke(.rwkvRedoAnswer(redone))
            #expect(try backend.invoke(.getCard(id: entry.card.id)).reps == 1)

            try backend.invoke(.rwkvInvalidate)
            try backend.invoke(.rwkvSave)
        }
    }

    @Test func inactiveCollection_searchesRunWithoutScores() throws {
        try withScratchCollection("rwkv-inactive-search") { backend, _ in
            let all = try addBasicNotes(backend, count: 3)
            // "unavailable" (no RWKV preset), not "pending".
            #expect(try backend.invoke(.rwkvSearchScores(search: "deck:*", wait: false)) == false)
            #expect(try backend.invoke(.rwkvSearchScores(search: "deck:*", wait: true)) == false)

            let sorted = { (ids: [NoteID]) in ids.map(\.rawValue).sorted() }
            #expect(sorted(try backend.invoke(.rwkvSearchNoteIds(query: "deck:*"))) == sorted(all))
            #expect(sorted(try backend.invoke(.rwkvSearchNoteIds(query: ""))) == sorted(all))
            #expect(try backend.invoke(.rwkvSearchNoteIds(query: "front 1")).count == 1)
            // No RWKV preset: nothing has an RWKV retrievability.
            #expect(try backend.invoke(.rwkvSearchNoteIds(query: "prop:rwkv:r<2")).isEmpty)
        }
    }

    @Test func inactiveCollection_rebuildsAFilteredDeck() throws {
        try withScratchCollection("rwkv-inactive-filtered") { backend, _ in
            try addBasicNotes(backend, count: 3)
            let filtered = try addFilteredDeck(
                backend, name: "Filtered", search: "deck:Default", order: .due
            )
            #expect(try backend.invoke(.rwkvRebuildFilteredDeck(deckId: filtered)) == 3)
            #expect(try backend.invoke(.deckCounts(for: filtered))?.newCount == 3)

            // Not a filtered deck: the backend refuses, as for a plain rebuild.
            #expect(throws: (any Error).self) {
                try backend.invoke(.rwkvRebuildFilteredDeck(deckId: DeckID(1)))
            }
        }
    }

    @Test func noModel_rescheduleWorkloadAndMemorisedReportUnavailable() throws {
        try withScratchCollection("rwkv-no-model") { backend, dir in
            try configureDefaultPreset(backend, curve: true, instant: true)
            try addBasicNotes(backend, count: 2)
            try answerQueued(backend, count: 2, rating: .easy)

            #expect(try backend.invoke(.rwkvReschedule(deckId: nil))
                == RwkvRescheduleResult(built: false, predicted: 0, updated: 0))
            #expect(try backend.invoke(.rwkvReschedule(deckId: DeckID(1)))
                == RwkvRescheduleResult(built: false, predicted: 0, updated: 0))

            // Cancelling with nothing running is harmless; simulating needs the model.
            try backend.invoke(.rwkvCancelWorkload)
            #expect(throws: (any Error).self) {
                try backend.invoke(.rwkvSimulateWorkload(workloadRequest()))
            }

            try backend.invoke(.rwkvCancelMemorised)
            let idle = try backend.invoke(.rwkvMemorisedProgress)
            #expect(idle.phase == "idle" || idle.done, "no Memorised build is running: \(idle)")
            // With reviews to replay but no model, the build ends as a
            // "failed" progress rather than an error, as the desktop's does.
            let failed = try backend.invoke(.rwkvMemorisedHistory(
                search: "deck:*", modelPath: Self.missingModel, precision: "int8", cacheDir: dir.path
            ))
            #expect(failed.phase == "failed")
            #expect(failed.done)
            #expect(failed.error == "RWKV model is unavailable")
        }
    }

    @Test func activePreset_withAMissingModel_failsToPrepare_andCardInfoSaysSo() throws {
        try withScratchCollection("rwkv-missing-model") { backend, dir in
            try configureDefaultPreset(backend, curve: true, instant: true)
            try addBasicNotes(backend, count: 2)
            let card = try #require(try answerQueued(backend, count: 1, rating: .easy).first)

            #expect(throws: (any Error).self) {
                try prepare(backend, model: Self.missingModel, cacheDir: dir)
            }
            // The desktop's rows, with FSRS standing in for RWKV; no model
            // was loaded, so the backend itself is unavailable.
            let rows = try backend.invoke(.rwkvCardInfo(cardId: card))
            let row = { (label: String) in rows.first { $0.label == label }?.value }
            #expect(row("RWKV computed R") == "Unavailable")
            #expect(row("Retrievability source") == "FSRS (RWKV backend unavailable)")
            #expect(row("FSRS Next S90")?.hasPrefix("Again:") == true)

            // Graph scores and deck counts fall back without the model.
            // No model: "unavailable", not "pending".
            #expect(try backend.invoke(.rwkvSearchScores(search: "deck:*", wait: true)) == false)
            try backend.invoke(.rwkvDeckCounts)
            #expect(try backend.invoke(.rwkvSearchNoteIds(query: "prop:rwkv:r<2")).isEmpty)
        }
    }

    // MARK: - with the model

    @Test(.enabled(if: RwkvModel.isAvailable, modelSkip))
    func model_prepareReplays_staysResident_andRestoresFromItsCache() throws {
        let model = try #require(RwkvModel.path)
        try withScratchCollection("rwkv-model-prepare") { backend, dir in
            try configureDefaultPreset(backend, curve: true, instant: true)
            try addBasicNotes(backend, count: 4)
            try answerQueued(backend, count: 4, rating: .easy)
            let cache = dir.appendingPathComponent("rwkv-state-cache", isDirectory: true)

            let first = try prepare(backend, model: model, cacheDir: cache)
            #expect(first.active && first.ready)
            #expect(first.source == "replayed")
            let second = try prepare(backend, model: model, cacheDir: cache)
            #expect(second == RwkvPrepareResult(active: true, ready: true, source: "resident"))

            // A full replay persists its state beside the collection.
            #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent(Self.stateFile).path))

            // Invalidating only makes the next prepare check the history again.
            try backend.invoke(.rwkvInvalidate)
            let revalidated = try prepare(backend, model: model, cacheDir: cache)
            #expect(revalidated.source == "revalidated")

            let rebuilt = try backend.invoke(.rwkvRebuildState(
                modelPath: model, cacheDir: cache.path, precision: "int8"
            ))
            #expect(rebuilt == RwkvPrepareResult(active: true, ready: true, source: "replayed"))

            // Another backend on the same collection restores the saved state.
            let paths = (
                collection: dir.appendingPathComponent("collection.anki2").path,
                media: dir.appendingPathComponent("media").path,
                mediaDb: dir.appendingPathComponent("media.db").path
            )
            try backend.closeCollection()
            do {
                let other = try AnkiBackend()
                try other.openCollection(
                    collectionPath: paths.collection, mediaFolderPath: paths.media, mediaDbPath: paths.mediaDb
                )
                defer { try? other.closeCollection() }
                let restored = try prepare(other, model: model, cacheDir: cache)
                #expect(restored == RwkvPrepareResult(active: true, ready: true, source: "restored"))
            }
            try backend.openCollection(
                collectionPath: paths.collection, mediaFolderPath: paths.media, mediaDbPath: paths.mediaDb
            )
        }
    }

    @Test(.enabled(if: RwkvModel.isAvailable, modelSkip))
    func model_answerUndoRedo_keepTheResidentStateInStep() throws {
        let model = try #require(RwkvModel.path)
        try withScratchCollection("rwkv-model-answer") { backend, dir in
            try configureDefaultPreset(backend, curve: true, instant: true)
            try addBasicNotes(backend, count: 3)
            try answerQueued(backend, count: 2, rating: .easy)
            let cache = dir.appendingPathComponent("rwkv-state-cache", isDirectory: true)
            let stateFile = cache.appendingPathComponent(Self.stateFile).path
            #expect(try prepare(backend, model: model, cacheDir: cache).source == "replayed")
            try backend.invoke(.rwkvScoreDeck(deckId: DeckID(1), newSession: true))

            let entry = try queuedCard(backend)
            let shown = try backend.invoke(.rwkvShownCard(entry))
            #expect(shown.card.id == entry.card.id)
            #expect(Set(shown.nextIntervals.keys) == Set(Rating.allCases))
            // RWKV-Curve replaced the FSRS answer states with its own.
            let tokens = { (s: ReviewSchedulingStates) in [s.again.bytes, s.hard.bytes, s.good.bytes, s.easy.bytes] }
            #expect(tokens(shown.states) != tokens(entry.states))

            try backend.invoke(.rwkvAnswerCard(
                cardId: entry.card.id, rating: .good, timeSpentMs: 3_000, states: shown.states
            ))
            #expect(try backend.invoke(.getCard(id: entry.card.id)).reps == 1)

            // The live answer left the state ahead of its saved copy: a save
            // writes it again.
            try FileManager.default.removeItem(atPath: stateFile)
            try backend.invoke(.rwkvSave)
            #expect(FileManager.default.fileExists(atPath: stateFile))

            // The answer advanced the state live: nothing to replay. (From
            // here on no cache dir, so nothing is restored from disk either.)
            #expect(try prepare(backend, model: model, cacheDir: nil).source == "resident")

            // The undo frame is found by the outcome's counters, so the state
            // steps back with the collection and stays trusted ("resident").
            // A frame that isn't found distrusts it, and the answer the
            // collection took back then forces a replay.
            let undone = try backend.invoke(.undo)
            try backend.invoke(.rwkvUndoAnswer(undone))
            #expect(try backend.invoke(.getCard(id: entry.card.id)).reps == 0)
            #expect(try prepare(backend, model: model, cacheDir: nil).source == "resident")

            let redone = try backend.invoke(.redo)
            try backend.invoke(.rwkvRedoAnswer(redone))
            #expect(try backend.invoke(.getCard(id: entry.card.id)).reps == 1)
            #expect(try prepare(backend, model: model, cacheDir: nil).source == "resident")

            // Control: an undo the bridge isn't told about leaves the state
            // ahead of the collection, which the next prepare must replay.
            _ = try backend.invoke(.undo)
            #expect(try prepare(backend, model: model, cacheDir: nil).source == "replayed")
        }
    }

    @Test(.enabled(if: RwkvModel.isAvailable, modelSkip))
    func model_scoresFeedCardInfoSearchesFilteredDecksAndReschedule() throws {
        let model = try #require(RwkvModel.path)
        try withScratchCollection("rwkv-model-views") { backend, _ in
            try configureDefaultPreset(backend, curve: true, instant: true)
            try addBasicNotes(backend, count: 4)
            let reviewed = try answerQueued(backend, count: 3, rating: .easy)
            #expect(try prepare(backend, model: model, cacheDir: nil).ready)

            let rows = try backend.invoke(.rwkvCardInfo(cardId: reviewed[0]))
            #expect(!rows.isEmpty)
            #expect(rows.contains { $0.label == "RWKV : R After Review" })

            try backend.invoke(.rwkvDeckCounts)
            // Ready: the scores are installed, not pending.
            #expect(try backend.invoke(.rwkvSearchScores(search: "deck:*", wait: true)) == false)
            let scored = try backend.invoke(.rwkvSearchNoteIds(query: "prop:rwkv:r<2"))
            #expect(scored.count == 3, "the three reviewed cards have an RWKV R")

            let filtered = try addFilteredDeck(
                backend, name: "By R", search: "deck:Default", order: .retrievabilityAscending
            )
            #expect(try backend.invoke(.rwkvRebuildFilteredDeck(deckId: filtered)) == 4)

            let rescheduled = try backend.invoke(.rwkvReschedule(deckId: nil))
            #expect(rescheduled.built)
            #expect(rescheduled.predicted == 3)
        }
    }

    @Test(.enabled(if: RwkvModel.isAvailable, modelSkip))
    func model_simulatesTheWorkload_andBuildsTheMemorisedHistory() throws {
        let model = try #require(RwkvModel.path)
        try withScratchCollection("rwkv-model-workload") { backend, dir in
            try configureDefaultPreset(backend, curve: true, instant: true)
            try addBasicNotes(backend, count: 3)
            try answerQueued(backend, count: 3, rating: .easy)
            #expect(try prepare(backend, model: model, cacheDir: nil).ready)

            // A cancel before the run doesn't stick: each run clears it.
            try backend.invoke(.rwkvCancelWorkload)
            let workload = try backend.invoke(.rwkvSimulateWorkload(workloadRequest()))
            // 30–99% in steps of `targetStep` (23), always ending at 99.
            #expect(Set(workload.cost.keys) == [30, 53, 76, 99])
            #expect(Set(workload.memorized.keys) == [30, 53, 76, 99])
            #expect(Set(workload.reviewCount.keys) == [30, 53, 76, 99])
            #expect(workload.memorized.values.allSatisfy { $0 > 0 && $0 <= 3 })

            let history = try backend.invoke(.rwkvMemorisedHistory(
                search: "deck:*", modelPath: model, precision: "int8", cacheDir: dir.path
            ))
            #expect(history.done)
            #expect(history.error == nil)
            #expect(history.phase == "complete")
            #expect(history.cardCount.last == 3)
            #expect(history.firstDay != nil)
            #expect(history.retrievability.count == history.cardCount.count)
            let progress = try backend.invoke(.rwkvMemorisedProgress)
            #expect(progress.done)
            #expect(progress.phase == "complete")

            // Cancelling a finished build changes nothing; the next request
            // is served from the history cached in `cacheDir`.
            try backend.invoke(.rwkvCancelMemorised)
            let cached = try backend.invoke(.rwkvMemorisedHistory(
                search: "deck:*", modelPath: model, precision: "int8", cacheDir: dir.path
            ))
            #expect(cached.done && cached.error == nil)
            #expect(cached.cardCount == history.cardCount)
        }
    }
}
