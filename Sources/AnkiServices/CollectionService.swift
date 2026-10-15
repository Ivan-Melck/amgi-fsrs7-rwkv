//
//  CollectionService.swift
//  AnkiServices
//
//  Created by Vladimir Gusev on 01.04.2026.
//

import AnkiBackend
import AnkiProtoBridge
public import AnkiKit
public import Dependencies
import DependenciesMacros

@DependencyClient
public struct CollectionService: Sendable {
    public var checkDatabase: @Sendable () throws -> [String]
    /// What undo and redo would revert, for the Undo/Redo buttons.
    public var undoStatus: @Sendable () throws -> UndoStatus
    /// Undoes the newest undoable step and reconciles RWKV's state with it
    /// (`aqt.operations.collection.undo`).
    public var undo: @Sendable () throws -> UndoOutcome
    /// Redoes the newest undone step and reconciles RWKV's state with it
    /// (`aqt.operations.collection.redo`).
    public var redo: @Sendable () throws -> UndoOutcome
}

extension CollectionService: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend
        @Dependency(\.schedulerService) var scheduler
        return Self(
            checkDatabase: {
                try backend.invoke(.checkDatabase)
            },
            undoStatus: {
                try backend.invoke(.undoStatus)
            },
            undo: {
                let outcome: UndoOutcome = try backend.invoke(.undo)
                // Best effort, like the desktop's: a failure leaves the
                // state to be revalidated against the collection.
                try? scheduler.didUndo(outcome)
                return outcome
            },
            redo: {
                let outcome: UndoOutcome = try backend.invoke(.redo)
                try? scheduler.didRedo(outcome)
                return outcome
            }
        )
    }()
}

extension CollectionService: TestDependencyKey {
    public static let testValue = CollectionService()
}

extension DependencyValues {
    public var collectionService: CollectionService {
        get { self[CollectionService.self] }
        set { self[CollectionService.self] = newValue }
    }
}
