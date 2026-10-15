//
//  CollectionOpsRequests.swift
//  AnkiProtoBridge
//
//  Created by Vladimir Gusev on 13.05.2026.
//

import Foundation
public import AnkiBackend
public import AnkiKit
import AnkiProto
import SwiftProtobuf

// MARK: - checkDatabase

extension Request where Response == [String] {
    public static var checkDatabase: Self {
        .empty(
            serviceId: ServiceID.collection,
            methodId: CollectionOpsMethod.checkDatabase,
            decode: { bytes in
                try Anki_Collection_CheckDatabaseResponse(serializedBytes: bytes).problems
            }
        )
    }
}

// MARK: - undo / hasUndoableAction

extension Request where Response == Void {
    /// Undoes the last user-visible operation. No-op if the undo stack
    /// is empty (the backend returns an `undoEmpty` error which the
    /// service-level code is free to swallow).
    public static var undoLastAction: Self {
        .empty(
            serviceId: ServiceID.collection,
            methodId: CollectionOpsMethod.undo,
            decode: { _ in () }
        )
    }
}

extension Request where Response == Bool {
    /// Returns true when the next call to `.undoLastAction` would have
    /// something to undo. Surfaces `!UndoStatus.undo.isEmpty`.
    public static var hasUndoableAction: Self {
        .empty(
            serviceId: ServiceID.collection,
            methodId: CollectionOpsMethod.getUndoStatus,
            decode: { bytes in
                let proto = try Anki_Collection_UndoStatus(serializedBytes: bytes)
                return !proto.undo.isEmpty
            }
        )
    }
}

// MARK: - undo status / undo / redo

extension UndoStatus {
    init(_ proto: Anki_Collection_UndoStatus) {
        self.init(undo: proto.undo, redo: proto.redo, lastStep: proto.lastStep)
    }
}

extension UndoOutcome {
    init(_ proto: Anki_Collection_OpChangesAfterUndo) {
        self.init(
            operation: proto.operation,
            counter: proto.counter,
            newStatus: UndoStatus(proto.newStatus)
        )
    }
}

extension Request where Response == UndoStatus {
    /// What undo and redo would revert (`col.undo_status()`).
    public static var undoStatus: Self {
        .empty(
            serviceId: ServiceID.collection,
            methodId: CollectionOpsMethod.getUndoStatus,
            decode: { bytes in
                UndoStatus(try Anki_Collection_UndoStatus(serializedBytes: bytes))
            }
        )
    }
}

extension Request where Response == UndoOutcome {
    /// Undoes the newest undoable step (`col.undo()`); throws `undoEmpty`
    /// when there is none.
    public static var undo: Self {
        .empty(
            serviceId: ServiceID.collection,
            methodId: CollectionOpsMethod.undo,
            decode: { bytes in
                UndoOutcome(try Anki_Collection_OpChangesAfterUndo(serializedBytes: bytes))
            }
        )
    }

    /// Redoes the newest undone step (`col.redo()`); throws `undoEmpty`
    /// when there is none.
    public static var redo: Self {
        .empty(
            serviceId: ServiceID.collection,
            methodId: CollectionOpsMethod.redo,
            decode: { bytes in
                UndoOutcome(try Anki_Collection_OpChangesAfterUndo(serializedBytes: bytes))
            }
        )
    }
}
