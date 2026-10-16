//
//  UndoLiveTests.swift
//  AnkiProtoBridgeTests
//
//  `undoStatus` / `undo` / `redo` against the real backend. The counters
//  matter beyond the menu titles: the RWKV undo frames are matched by them
//  (see RwkvLiveTests), so a mis-decoded counter breaks RWKV undo silently.
//

import Foundation
import Testing
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend

@Suite struct UndoLiveTests {
    @Test func freshCollection_hasNothingToUndoOrRedo() throws {
        try withScratchCollection("undo-empty") { backend, _ in
            let status = try backend.invoke(.undoStatus)
            #expect(!status.canUndo)
            #expect(!status.canRedo)
            #expect(throws: (any Error).self) { try backend.invoke(.undo) }
            #expect(throws: (any Error).self) { try backend.invoke(.redo) }
        }
    }

    @Test func undoThenRedo_ofAnAddedNote() throws {
        try withScratchCollection("undo-redo") { backend, _ in
            try addBasicNotes(backend, count: 1)
            #expect(try backend.invoke(.searchNoteIds(query: "deck:*")).count == 1)

            let before = try backend.invoke(.undoStatus)
            #expect(before.canUndo)
            #expect(!before.canRedo)
            #expect(before.undo == "Add Note")
            #expect(before.lastStep > 0)

            let undone = try backend.invoke(.undo)
            #expect(undone.operation == "Add Note")
            // The undone step's counter is the one the status named, and
            // the undo is a step of its own (whose counter a redo reports).
            #expect(undone.counter == before.lastStep)
            #expect(undone.newStatus.lastStep > undone.counter)
            #expect(try backend.invoke(.searchNoteIds(query: "deck:*")).isEmpty)
            // `new_status` is read inside the undo's own transaction, before
            // the redo step is pushed, so the redo shows in a fresh status.
            let afterUndo = try backend.invoke(.undoStatus)
            #expect(afterUndo.lastStep == undone.newStatus.lastStep)
            #expect(afterUndo.canRedo)
            #expect(afterUndo.redo == "Add Note")
            #expect(!afterUndo.canUndo)

            let redone = try backend.invoke(.redo)
            #expect(redone.operation == "Add Note")
            // A redo reverts the undo step, under the counter the undo got.
            #expect(redone.counter == undone.newStatus.lastStep)
            let afterRedo = try backend.invoke(.undoStatus)
            #expect(afterRedo.canUndo)
            #expect(afterRedo.undo == "Add Note")
            #expect(!afterRedo.canRedo)
            #expect(try backend.invoke(.searchNoteIds(query: "deck:*")).count == 1)
        }
    }

    @Test func undo_takesBackAnAnswer() throws {
        try withScratchCollection("undo-answer") { backend, _ in
            try addBasicNotes(backend, count: 1)
            let card = try #require(try answerQueued(backend, count: 1, rating: .good).first)
            #expect(try backend.invoke(.getCard(id: card)).reps == 1)

            let undone = try backend.invoke(.undo)
            #expect(undone.operation == "Answer Card")
            #expect(try backend.invoke(.getCard(id: card)).reps == 0)

            _ = try backend.invoke(.redo)
            #expect(try backend.invoke(.getCard(id: card)).reps == 1)
        }
    }
}
