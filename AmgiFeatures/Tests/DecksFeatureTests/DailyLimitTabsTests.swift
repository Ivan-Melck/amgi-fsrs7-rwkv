//
//  DailyLimitTabsTests.swift
//  DecksFeatureTests
//
//  The daily-limit tabs follow the desktop's TabbedValue.svelte.
//

import XCTest
@testable import DecksFeature

final class DailyLimitTabsTests: XCTestCase {
    func testOpensOnTheLastTabHoldingAValue() {
        XCTAssertEqual(DailyLimitTabs(deck: nil, today: nil, todayActive: false).scope, .preset)
        XCTAssertEqual(DailyLimitTabs(deck: 5, today: nil, todayActive: false).scope, .deck)
        XCTAssertEqual(DailyLimitTabs(deck: 5, today: 3, todayActive: true).scope, .today)
        // A today-only limit from an earlier day is not active.
        XCTAssertEqual(DailyLimitTabs(deck: nil, today: 3, todayActive: false).scope, .preset)
    }

    func testAStaleTodayLimitIsNotSentBack() {
        // Sending a today-only limit makes it today's, so it must be cleared.
        let tabs = DailyLimitTabs(deck: 7, today: 3, todayActive: false)
        XCTAssertEqual(tabs.saved.deck, 7)
        XCTAssertNil(tabs.saved.today)
    }

    func testChoosingATabStartsFromItsLastValue() {
        var tabs = DailyLimitTabs(deck: nil, today: 3, todayActive: false)
        tabs.select(.today, showing: 20)
        XCTAssertEqual(tabs.value(preset: 20), 3)
        tabs.select(.deck, showing: 3)
        // No deck value yet: start from the value on screen.
        XCTAssertEqual(tabs.value(preset: 20), 3)
    }

    func testSavedFollowsTheActiveTab() {
        var preset = 20
        var tabs = DailyLimitTabs(deck: 7, today: nil, todayActive: false)
        tabs.set(9, preset: &preset)
        XCTAssertEqual(preset, 20)
        XCTAssertEqual(tabs.saved.deck, 9)

        tabs.select(.today, showing: 9)
        tabs.set(4, preset: &preset)
        // Today only keeps the stored deck limit underneath.
        XCTAssertEqual(tabs.saved.deck, 7)
        XCTAssertEqual(tabs.saved.today, 4)

        tabs.select(.preset, showing: 4)
        tabs.set(30, preset: &preset)
        XCTAssertEqual(preset, 30)
        XCTAssertNil(tabs.saved.deck)
        XCTAssertNil(tabs.saved.today)
    }
}
