//
//  DeckConfigStepsTests.swift
//  DecksFeatureTests
//
//  Learning steps follow the desktop's ts/routes/deck-options/steps.ts, so a
//  save never changes a step it didn't edit.
//

import AnkiKit
import XCTest
@testable import DecksFeature

final class DeckConfigStepsTests: XCTestCase {
    func testFormatsInTheLargestWholeUnit() {
        XCTAssertEqual(DeckConfigModel.stepString(0.5), "30s")
        XCTAssertEqual(DeckConfigModel.stepString(1.5), "90s")
        XCTAssertEqual(DeckConfigModel.stepString(10), "10m")
        XCTAssertEqual(DeckConfigModel.stepString(90), "90m")
        XCTAssertEqual(DeckConfigModel.stepString(120), "2h")
        XCTAssertEqual(DeckConfigModel.stepString(1440), "1d")
        XCTAssertEqual(DeckConfigModel.stepString(2880), "2d")
    }

    func testParsesLikeTheDesktop() {
        XCTAssertEqual(DeckConfigModel.stepMinutes("30s"), 0.5)
        XCTAssertEqual(DeckConfigModel.stepMinutes("10"), 10)
        XCTAssertEqual(DeckConfigModel.stepMinutes("10m"), 10)
        XCTAssertEqual(DeckConfigModel.stepMinutes("2h"), 120)
        XCTAssertEqual(DeckConfigModel.stepMinutes("1d"), 1440)
        // Whole numbers only, as on the desktop.
        XCTAssertEqual(DeckConfigModel.stepMinutes("1.5m"), 1)
        XCTAssertEqual(DeckConfigModel.stepMinutes("abc"), 0)
    }

    func testStoredStepsRoundTrip() {
        for minutes: Float in [0.5, 1, 1.5, 10, 90, 120, 1440, 4320] {
            let text = DeckConfigModel.stepString(minutes)
            XCTAssertEqual(DeckConfigModel.stepMinutes(text), minutes, text)
        }
    }

    func testIgnoreRevlogsBeforeIsUtcMidnightLikeTheDesktop() {
        XCTAssertNil(DeckConfigModel.ignoreRevlogsBefore(""))
        XCTAssertEqual(DeckConfigModel.ignoreRevlogsBefore("1970-01-01")?.ankiMillis, 0)
        XCTAssertEqual(
            DeckConfigModel.ignoreRevlogsBefore("2024-03-01")?.ankiMillis,
            1_709_251_200_000
        )
    }
}
