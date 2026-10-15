//
//  DeckConfigDynamicDesiredRetentionTests.swift
//  DecksFeatureTests
//
//  The Dynamic DR plot reads the edited preset's model and saves into the
//  desired retention the page shows, as the desktop's FsrsOptions.svelte.
//

import AnkiKit
import XCTest
@testable import DecksFeature

final class DeckConfigDynamicDesiredRetentionTests: XCTestCase {
    @MainActor
    func testPlotsTheEditedPresetsModel() {
        let model = DeckConfigModel(deckId: DeckID(1), deckName: "Deck")
        XCTAssertTrue(model.editedDynamicDesiredRetention.isEmpty)

        var config = DeckConfig(id: DeckConfigID(1), name: "Default", config: .init())
        config.config.fsrsDynamicDesiredRetention = FsrsDynamicDesiredRetention(params: [1], minimum: 0.7)
        model.loaded = .init(config: config, context: DeckConfigsForUpdate())
        XCTAssertEqual(model.editedDynamicDesiredRetention.params, [1])

        // An unsaved optimization's model, as it will be saved.
        model.optimizedDynamicDesiredRetention = FsrsDynamicDesiredRetention(params: [2], minimum: 0.8)
        XCTAssertEqual(model.editedDynamicDesiredRetention.params, [2])
        XCTAssertEqual(model.dynamicDesiredRetentionPlot.retentionMin, Double(Float(0.8)))
    }

    @MainActor
    func testSavingATargetEditsTheEffectiveDesiredRetention() {
        let model = DeckConfigModel(deckId: DeckID(1), deckName: "Deck")
        model.desiredRetentionPercent = 90
        XCTAssertEqual(model.effectiveDesiredRetention, 0.9, accuracy: 1e-12)

        model.saveDynamicDesiredRetentionPlotTarget(0.875)
        XCTAssertEqual(model.desiredRetentionPercent, 87.5)
        XCTAssertNil(model.deckDesiredRetentionPercent)

        // With this deck's own DR, that one is edited instead.
        model.deckDesiredRetentionPercent = 85
        XCTAssertEqual(model.effectiveDesiredRetention, 0.85, accuracy: 1e-12)
        model.saveDynamicDesiredRetentionPlotTarget(0.9)
        XCTAssertEqual(model.deckDesiredRetentionPercent, 90)
        XCTAssertEqual(model.desiredRetentionPercent, 87.5)
    }

    @MainActor
    func testStatusNeedsAFittedModel() {
        let model = DeckConfigModel(deckId: DeckID(1), deckName: "Deck")
        model.dynamicDesiredRetentionEnabled = true
        XCTAssertFalse(model.dynamicDesiredRetentionStatus.ready)
        XCTAssertEqual(
            model.dynamicDesiredRetentionStatus.warning,
            "Dynamic DR requires 15 ADR policy parameters and matching calibration arrays."
        )
    }
}
