//
//  UndoTypesTests.swift
//  AnkiKitTests
//

import Testing
@testable import AnkiKit

@Suite("UndoStatus")
struct UndoStatusTests {
    @Test func titlesNameTheOperation() {
        let status = UndoStatus(undo: "Answer Card", redo: "Set Flag", lastStep: 7)
        #expect(status.canUndo && status.canRedo)
        #expect(status.undoTitle == "Undo Answer Card")
        #expect(status.redoTitle == "Redo Set Flag")
        #expect(status.showsRedo)
    }

    @Test func emptyQueueHasPlainTitles() {
        let status = UndoStatus()
        #expect(!status.canUndo && !status.canRedo)
        #expect(status.undoTitle == "Undo")
        #expect(status.redoTitle == "Redo")
        #expect(!status.showsRedo)
    }

    @Test func redoShowsOnceAStepWasUndoable() {
        // `show_redo`: visible but disabled until something is undone.
        let status = UndoStatus(undo: "Answer Card", lastStep: 3)
        #expect(status.showsRedo)
        #expect(!status.canRedo)
        #expect(status.redoTitle == "Redo")
    }

    @Test func outcomeMessages() {
        let outcome = UndoOutcome(operation: "Answer Card", counter: 3, newStatus: UndoStatus())
        #expect(outcome.undoneMessage == "Answer Card undone")
        #expect(outcome.redoneMessage == "Answer Card redone")
    }
}

@Suite("ReviewUndoLedger")
struct ReviewUndoLedgerTests {
    private func answer(_ counter: UInt32, _ card: Int64, _ rating: Rating = .good) -> ReviewUndoLedger.Answer {
        .init(counter: counter, cardId: CardID(card), rating: rating, timeMs: 1_000 * Int(card))
    }

    private func outcome(_ counter: UInt32, next: UInt32) -> UndoOutcome {
        UndoOutcome(operation: "Answer Card", counter: counter, newStatus: UndoStatus(lastStep: next))
    }

    @Test func undoAndRedoFollowRenumberedSteps() {
        var ledger = ReviewUndoLedger()
        ledger.answered(answer(1, 10))
        ledger.answered(answer(2, 20))
        ledger.answered(answer(3, 30))

        // The collection's undo of step 3 creates redo step 4.
        #expect(ledger.undone(outcome(3, next: 4))?.cardId == CardID(30))
        #expect(ledger.undone(outcome(2, next: 5))?.cardId == CardID(20))
        #expect(ledger.undoable.map(\.counter) == [1])
        #expect(ledger.redoable.map(\.counter) == [4, 5])

        // Redo pops the newest redo step (5), creating undo step 6.
        #expect(ledger.redone(outcome(5, next: 6))?.cardId == CardID(20))
        #expect(ledger.undoable.map(\.counter) == [1, 6])
        #expect(ledger.undone(outcome(6, next: 7))?.cardId == CardID(20))
        #expect(ledger.redoable.map(\.counter) == [4, 7])
    }

    @Test func otherStepsAreNotAnswers() {
        var ledger = ReviewUndoLedger()
        ledger.answered(answer(1, 10))
        // Step 2 was e.g. a flag change.
        #expect(ledger.undone(outcome(2, next: 3)) == nil)
        #expect(ledger.undoable.map(\.counter) == [1])
        #expect(ledger.redoable.isEmpty)
        #expect(ledger.redone(outcome(3, next: 4)) == nil)
        #expect(ledger.undone(outcome(1, next: 5))?.cardId == CardID(10))
    }

    @Test func aNewAnswerClearsRedo() {
        var ledger = ReviewUndoLedger()
        ledger.answered(answer(1, 10))
        _ = ledger.undone(outcome(1, next: 2))
        #expect(ledger.redoable.count == 1)
        ledger.answered(answer(3, 20))
        #expect(ledger.redoable.isEmpty)
        #expect(ledger.redone(outcome(2, next: 4)) == nil)
    }

    @Test func keepsTheNewestThirtySteps() {
        var ledger = ReviewUndoLedger()
        for step in 1...35 {
            ledger.answered(answer(UInt32(step), Int64(step)))
        }
        #expect(ledger.undoable.count == ReviewUndoLedger.limit)
        #expect(ledger.undoable.first?.counter == 6)
        #expect(ledger.undone(outcome(5, next: 36)) == nil)
    }

    @Test func sessionStatsRollBackAndForward() {
        var stats = SessionStats()
        stats.add(.good, timeMs: 4_000)
        stats.add(.again, timeMs: 6_000)
        #expect(stats == SessionStats(reviewed: 2, correct: 1, totalTimeMs: 10_000))
        stats.remove(.again, timeMs: 6_000)
        #expect(stats == SessionStats(reviewed: 1, correct: 1, totalTimeMs: 4_000))
        stats.remove(.good, timeMs: 4_000)
        stats.remove(.good, timeMs: 4_000)
        #expect(stats == SessionStats())
    }
}
