//
//  UndoTypes.swift
//  AnkiKit
//
//  The collection's undo/redo queue, as the desktop's Edit menu and
//  reviewer use it (`aqt/undo.py`, `aqt/operations/collection.py`).
//

/// The collection's `UndoStatus`: the operations an undo and a redo would
/// revert (empty when there are none) and the newest step's counter.
public struct UndoStatus: Sendable, Hashable {
    public var undo: String
    public var redo: String
    public var lastStep: UInt32

    public init(undo: String = "", redo: String = "", lastStep: UInt32 = 0) {
        self.undo = undo
        self.redo = redo
        self.lastStep = lastStep
    }

    // `UndoActionsInfo.from_undo_status`.

    public var canUndo: Bool { !undo.isEmpty }
    public var canRedo: Bool { !redo.isEmpty }

    /// "Undo Answer Card" (`undo-undo-action`), or "Undo" (`undo-undo`).
    public var undoTitle: String { undo.isEmpty ? "Undo" : "Undo \(undo)" }

    /// "Redo Answer Card" (`undo-redo-action`), or "Redo" (`undo-redo`).
    public var redoTitle: String { redo.isEmpty ? "Redo" : "Redo \(redo)" }

    /// Redo is shown once the collection has had an undoable step
    /// (`show_redo`).
    public var showsRedo: Bool { lastStep > 0 }
}

/// The collection's `OpChangesAfterUndo`: what an undo or redo reverted.
public struct UndoOutcome: Sendable, Hashable {
    /// The reverted operation, e.g. "Answer Card".
    public var operation: String
    /// The reverted step's counter.
    public var counter: UInt32
    /// The queue afterwards; its `lastStep` is the step that reverts this
    /// one (the redo of an undo, the undo of a redo).
    public var newStatus: UndoStatus

    public init(operation: String, counter: UInt32, newStatus: UndoStatus) {
        self.operation = operation
        self.counter = counter
        self.newStatus = newStatus
    }

    /// "Answer Card undone" (`undo-action-undone`).
    public var undoneMessage: String { "\(operation) undone" }

    /// "Answer Card redone" (`undo-action-redone`).
    public var redoneMessage: String { "\(operation) redone" }
}

/// A review session's own answers on the collection's undo queue, so an
/// undo or redo of one rolls the session's counts back or forward. Keyed by
/// undo step like the desktop's RWKV rollback frames: recorded under the
/// answer's step (`_save_rollback_frame`), matched by the reverted step's
/// counter and moved under the step that reverts it (`answer_undone`,
/// `answer_redone`).
public struct ReviewUndoLedger: Sendable, Equatable {
    public struct Answer: Sendable, Equatable {
        public var counter: UInt32
        public var cardId: CardID
        public var rating: Rating
        public var timeMs: Int

        public init(counter: UInt32, cardId: CardID, rating: Rating, timeMs: Int) {
            self.counter = counter
            self.cardId = cardId
            self.rating = rating
            self.timeMs = timeMs
        }
    }

    /// `_RWKV_REVIEW_UNDO_LIMIT`, the collection's own undo limit.
    public static let limit = 30

    public private(set) var undoable: [Answer] = []
    public private(set) var redoable: [Answer] = []

    public init() {}

    /// After an answer, under the collection's `lastStep`; a new answer
    /// can't be followed by a redo.
    public mutating func answered(_ answer: Answer) {
        redoable.removeAll()
        Self.append(answer, to: &undoable)
    }

    /// After the collection's undo: the answer it took back, if it was one
    /// of this session's.
    public mutating func undone(_ outcome: UndoOutcome) -> Answer? {
        Self.move(outcome, from: &undoable, to: &redoable)
    }

    /// After the collection's redo: the answer it applied again, if it was
    /// one of this session's.
    public mutating func redone(_ outcome: UndoOutcome) -> Answer? {
        Self.move(outcome, from: &redoable, to: &undoable)
    }

    private static func move(
        _ outcome: UndoOutcome,
        from source: inout [Answer],
        to destination: inout [Answer]
    ) -> Answer? {
        guard let index = source.lastIndex(where: { $0.counter == outcome.counter }) else {
            return nil
        }
        var answer = source.remove(at: index)
        answer.counter = outcome.newStatus.lastStep
        append(answer, to: &destination)
        return answer
    }

    /// `_append_bounded`.
    private static func append(_ answer: Answer, to answers: inout [Answer]) {
        answers.append(answer)
        if answers.count > limit {
            answers.removeFirst(answers.count - limit)
        }
    }
}

extension SessionStats {
    /// Counts an answer of this session.
    public mutating func add(_ rating: Rating, timeMs: Int) {
        reviewed += 1
        if rating != .again { correct += 1 }
        totalTimeMs += timeMs
    }

    /// Takes back an answer `add` counted.
    public mutating func remove(_ rating: Rating, timeMs: Int) {
        reviewed = max(0, reviewed - 1)
        if rating != .again { correct = max(0, correct - 1) }
        totalTimeMs = max(0, totalTimeMs - timeMs)
    }
}
