//
//  CollectionOpsRequestsTests.swift
//  AnkiProtoBridgeTests
//
//  Created by Vladimir Gusev on 13.05.2026.
//

import Foundation
import Testing
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend
import AnkiProto
import SwiftProtobuf

@Suite struct CollectionOpsRequestsTests {
    @Test func checkDatabase_dispatches_and_decodes_problems() throws {
        var proto = Anki_Collection_CheckDatabaseResponse()
        proto.problems = ["Fixed invalid card properties", "Fixed missing deck"]

        let request: Request<[String]> = .checkDatabase
        #expect(request.serviceId == 3)
        #expect(request.methodId == 6)
        #expect(try request.body.isEmpty)
        #expect(try request.decode(proto.serializedData()) == proto.problems)
    }

    @Test func undoLastAction_dispatches_with_empty_body() throws {
        let envelope: Request<Void> = .undoLastAction
        #expect(envelope.serviceId == 3)
        #expect(envelope.methodId == 8)
        #expect(try envelope.body.isEmpty)
    }

    @Test func hasUndoableAction_dispatches_with_empty_body() throws {
        let envelope: Request<Bool> = .hasUndoableAction
        #expect(envelope.serviceId == 3)
        #expect(envelope.methodId == 7)
        #expect(try envelope.body.isEmpty)
    }

    @Test func hasUndoableAction_returns_true_when_undo_label_present() throws {
        var resp = Anki_Collection_UndoStatus()
        resp.undo = "Answer Card"
        let bytes = try resp.serializedData()
        let envelope: Request<Bool> = .hasUndoableAction
        #expect(try envelope.decode(bytes) == true)
    }

    @Test func hasUndoableAction_returns_false_when_undo_label_empty() throws {
        var resp = Anki_Collection_UndoStatus()
        resp.undo = ""
        let bytes = try resp.serializedData()
        let envelope: Request<Bool> = .hasUndoableAction
        #expect(try envelope.decode(bytes) == false)
    }
    @Test func undoStatus_decodes_both_labels_and_the_last_step() throws {
        var resp = Anki_Collection_UndoStatus()
        resp.undo = "Answer Card"
        resp.redo = "Set Flag"
        resp.lastStep = 12
        let envelope: Request<UndoStatus> = .undoStatus
        #expect(envelope.serviceId == 3)
        #expect(envelope.methodId == 7)
        #expect(try envelope.body.isEmpty)
        #expect(try envelope.decode(resp.serializedData())
            == UndoStatus(undo: "Answer Card", redo: "Set Flag", lastStep: 12))
    }

    @Test func undo_and_redo_decode_the_reverted_step() throws {
        var resp = Anki_Collection_OpChangesAfterUndo()
        resp.operation = "Answer Card"
        resp.counter = 5
        resp.newStatus.redo = "Answer Card"
        resp.newStatus.lastStep = 6
        let undo: Request<UndoOutcome> = .undo
        let redo: Request<UndoOutcome> = .redo
        #expect(undo.serviceId == 3 && undo.methodId == 8)
        #expect(redo.serviceId == 3 && redo.methodId == 9)
        let expected = UndoOutcome(
            operation: "Answer Card",
            counter: 5,
            newStatus: UndoStatus(redo: "Answer Card", lastStep: 6)
        )
        #expect(try undo.decode(resp.serializedData()) == expected)
        #expect(try redo.decode(resp.serializedData()) == expected)
    }

    @Test func rwkv_undo_and_redo_send_both_counters() throws {
        let outcome = UndoOutcome(operation: "Answer Card", counter: 5, newStatus: UndoStatus(lastStep: 6))
        let undo: Request<Void> = .rwkvUndoAnswer(outcome)
        let redo: Request<Void> = .rwkvRedoAnswer(outcome)
        #expect(undo.serviceId == 200 && undo.methodId == 104)
        #expect(redo.serviceId == 200 && redo.methodId == 118)
        for request in [undo, redo] {
            let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Int]
            #expect(body == ["counter": 5, "next_counter": 6])
        }
    }
}
