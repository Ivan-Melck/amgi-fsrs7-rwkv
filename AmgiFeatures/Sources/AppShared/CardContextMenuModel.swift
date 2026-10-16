//
//  CardContextMenuModel.swift
//  AppShared
//
//  Created by Vladimir Gusev on 27.06.2026.
//

import AnkiClients
import AnkiKit
import Dependencies
import Foundation
public import Observation

/// Card-operation I/O for `CardContextMenu`. Owns the card/note/tag clients
/// and the loaded display state (marked, current flag, undo availability)
/// plus the error-alert state so the menu carries no `@Dependency`.
///
/// `cardId`/`noteId` are **not** captured — the menu is a reused leaf whose
/// ids vary per use, so every action takes them as parameters and returns
/// `shouldAdvance` (`nil` on failure, with the error surfaced on the model);
/// the view forwards `onSuccess`/`onActionSuccess`.
@Observable
@MainActor
public final class CardContextMenuModel {
    var isMarkedNote = false
    public var currentFlag: UInt32 = 0
    /// The collection's undo queue, for the Undo/Redo items' titles.
    var undoStatus = UndoStatus()
    var isUndoing = false
    var errorMessage: String?
    var showError = false
    var showSetDueDate = false
    var dueDateSpec = ""

    @ObservationIgnored @Dependency(\.cardClient) private var cardClient
    @ObservationIgnored @Dependency(\.noteClient) private var noteClient
    @ObservationIgnored @Dependency(\.tagClient) private var tagClient

    public init() {}

    // MARK: - Actions (return shouldAdvance on success, nil on failure)

    func suspend(_ cardId: CardID) async -> Bool? {
        await run("Suspend failed") { try await cardClient.suspend(cardId); return true }
    }

    func bury(_ cardId: CardID) async -> Bool? {
        await run("Bury failed") { try await cardClient.bury(cardId); return true }
    }

    func resetToNew(_ cardId: CardID) async -> Bool? {
        await run("Forget failed") { try await cardClient.resetToNew(cardId); return true }
    }

    func setDueDate(_ cardId: CardID, _ spec: String) async -> Bool? {
        let spec = spec.trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty else { return nil }
        return await run("Set due date failed") {
            try await cardClient.setDueDate(cardId, spec)
            return true
        }
    }

    func deleteNote(_ noteId: NoteID) async -> Bool? {
        await run("Delete note failed") { try await noteClient.delete(noteId); return true }
    }

    func toggleMarked(_ noteId: NoteID) async -> Bool? {
        await run("Mark note failed") {
            if isMarkedNote {
                try await tagClient.removeTagFromNotes(markedTag, [noteId])
            } else {
                try await tagClient.addTagToNotes(markedTag, [noteId])
            }
            isMarkedNote.toggle()
            return false
        }
    }

    func suspendNote(_ noteId: NoteID) async -> Bool? {
        await noteAction(noteId, "Suspend note failed") { try await cardClient.suspend($0) }
    }

    func buryNote(_ noteId: NoteID) async -> Bool? {
        await noteAction(noteId, "Bury note failed") { try await cardClient.bury($0) }
    }

    func flag(_ cardId: CardID, _ value: UInt32) async -> Bool? {
        await run("Flag failed") {
            try await cardClient.flag(cardId, value)
            currentFlag = value
            return false
        }
    }

    /// The browser's Edit > Undo (`aqt.operations.collection.undo`).
    func undo(_ cardId: CardID) async -> Bool? {
        guard !isUndoing, undoStatus.canUndo else { return nil }
        return await undoOrRedo("Undo failed") { try await cardClient.undo() }
    }

    /// The browser's Edit > Redo (`aqt.operations.collection.redo`).
    func redo(_ cardId: CardID) async -> Bool? {
        guard !isUndoing, undoStatus.canRedo else { return nil }
        return await undoOrRedo("Redo failed") { try await cardClient.redo() }
    }

    private func undoOrRedo(_ prefix: String, _ body: () async throws -> UndoOutcome) async -> Bool? {
        isUndoing = true
        defer { isUndoing = false }
        do {
            undoStatus = try await body().newStatus
            // The outcome's status is taken before the step lands on the
            // other stack (no redo right after an undo); re-read it, as the
            // desktop's `undo_actions_info` does.
            await refreshUndoAvailability()
            return true
        } catch {
            setError("\(prefix): \(error.localizedDescription)")
            await refreshUndoAvailability()
            return nil
        }
    }

    // MARK: - Load

    func load(cardId: CardID, noteId: NoteID?) async {
        await loadMarkedState(noteId)
        currentFlag = (try? await cardClient.getCardFlags(cardId)) ?? 0
        await refreshUndoAvailability()
    }

    // MARK: - Helpers

    private func run(_ prefix: String, _ body: () async throws -> Bool) async -> Bool? {
        do {
            let shouldAdvance = try await body()
            // The action is now the step Undo reverts.
            await refreshUndoAvailability()
            return shouldAdvance
        } catch {
            setError("\(prefix): \(error.localizedDescription)")
            return nil
        }
    }

    private func noteAction(_ noteId: NoteID, _ prefix: String, _ action: (CardID) async throws -> Void) async -> Bool? {
        await run(prefix) {
            let cards = try await cardClient.fetchByNote(noteId)
            for card in cards {
                try await action(card.id)
            }
            return true
        }
    }

    private func loadMarkedState(_ noteId: NoteID?) async {
        guard let noteId else {
            isMarkedNote = false
            return
        }
        do {
            let note = try await noteClient.fetch(noteId)
            isMarkedNote = note.map {
                $0.tags
                    .split(separator: " ")
                    .contains { $0.caseInsensitiveCompare(markedTag) == .orderedSame }
            } ?? false
        } catch {
            isMarkedNote = false
        }
    }

    func refreshUndoAvailability() async {
        undoStatus = (try? await cardClient.undoStatus()) ?? UndoStatus()
    }

    private func setError(_ message: String) {
        errorMessage = message
        showError = true
    }
}

private let markedTag = "marked"
