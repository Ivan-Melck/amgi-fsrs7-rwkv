//
//  MemorisedHistoryTests.swift
//  AnkiKitTests
//
//  The Search Stats Extended add-on's Memorised chart series
//  (src/ts/MemorisedBar.svelte, LineGraph.ts, stores.ts).
//

import Foundation
import Testing
@testable import AnkiKit

@Suite("Memorised chart")
struct MemorisedHistoryTests {
    /// Two cards of one note reviewed from day 10; the period's load data
    /// starts on day 9.
    private let fsrs = FsrsMemorisedHistory(
        today: 13,
        retrievability: MemorisedDaySeries(firstDay: 10, values: [2, 1.8, 1.6, 1.5]),
        noteRetrievability: MemorisedDaySeries(firstDay: 10, values: [1, 0.9, 0.8, 0.75]),
        cardCount: MemorisedDaySeries(firstDay: 10, values: [2, 2, 2, 2]),
        stableRetrievability: MemorisedDaySeries(firstDay: 10, values: [0.1, 0.2, 0, 0]),
        burden: MemorisedDaySeries(firstDay: 9, values: [1, 0.5, 0.25, 0, 0.2])
    )

    /// The RWKV history of every card starts on day 8 and is computed
    /// through day 11; the searched cards enter on day 9.
    private let rwkv = RwkvMemorisedProgress(
        phase: "computing",
        current: 7,
        total: 20,
        firstDay: 8,
        completedThroughDay: 11,
        retrievability: [0, 1, 1.9, 1.7],
        noteRetrievability: [0, 0.5, 0.95, 0.85],
        cardCount: [0, 1, 2, 2]
    )

    private func makeChart(_ kind: MemorisedKind, _ source: MemorisedSource) -> MemorisedChart? {
        MemorisedChart.make(fsrs: fsrs, rwkv: rwkv, kind: kind, source: source)
    }

    @Test func fsrsCardsStartAtTheFirstNonZeroDay() throws {
        let chart = try #require(makeChart(.cards, .fsrs))
        #expect(chart.startDay == 10)
        #expect(chart.endDay == 13)
        #expect(chart.lines.count == 1)
        #expect(chart.lines[0].label == "Cards")
        #expect(chart.lines[0].color == .steelBlue)
        #expect(chart.lines[0].values == [2, 1.8, 1.6, 1.5])
        #expect(chart.tooltip(day: 11) == ["Cards: 1.8"])
        #expect(chart.maxValue == 2)
    }

    @Test func notesUseTheNoteSeries() throws {
        let chart = try #require(makeChart(.notes, .fsrs))
        #expect(chart.lines[0].label == "Notes")
        #expect(chart.lines[0].values == [1, 0.9, 0.8, 0.75])
    }

    @Test func cardsByBurdenDivideByTheDaysLoad() throws {
        let chart = try #require(makeChart(.cardsByBurden, .fsrs))
        #expect(chart.lines[0].label == "Cards/Load")
        #expect(chart.startDay == 10)
        // Day 12 has no load: 1.6 / 0 is infinite, drawn as a gap.
        #expect(chart.lines[0].values == [4, 7.2, .infinity, 7.5])
        #expect(chart.lines[0].plotted(2) == nil)
        #expect(chart.tooltip(day: 12).isEmpty)
        #expect(chart.tooltip(day: 13) == ["Cards/Load: 7.5"])
    }

    @Test func averageDividesByTheCardCount() throws {
        let chart = try #require(makeChart(.average, .fsrs))
        #expect(chart.lines[0].label == "Retrievability")
        #expect(chart.lines[0].values == [1, 0.9, 0.8, 0.75])
        #expect(chart.tooltip(day: 13) == ["Retrievability: 0.75"])
    }

    @Test func stableRetrievabilityIsFsrsOnly() throws {
        let chart = try #require(makeChart(.stable, .both))
        #expect(chart.lines.count == 1)
        #expect(chart.lines[0].label == "Stable cards")
        // Days nobody had stability are holes: drawn at 0, not in tooltips.
        #expect(chart.lines[0].values == [0.1, 0.2])
        #expect(chart.lines[0].plotted(1) == 0.2)
        #expect(chart.tooltip(day: 12).isEmpty)
        #expect(!MemorisedKind.stable.supportsRwkv)
    }

    @Test func rwkvIsAnchoredAtItsFirstDay() throws {
        let chart = try #require(makeChart(.cards, .rwkv))
        #expect(chart.startDay == 9)
        #expect(chart.lines.map(\.label) == ["RWKV"])
        #expect(chart.lines[0].color == .seaGreen)
        #expect(chart.lines[0].values == [1, 1.9, 1.7])
        #expect(chart.endDay == 11)
    }

    @Test func bothSourcesShareTheStartDay() throws {
        let chart = try #require(makeChart(.cards, .both))
        #expect(chart.startDay == 9)
        #expect(chart.lines.map(\.label) == ["FSRS", "RWKV"])
        // FSRS has no value on day 9: a hole, drawn at 0, not in tooltips.
        #expect(chart.lines[0].values == [nil, 2, 1.8, 1.6, 1.5])
        #expect(chart.lines[0].plotted(0) == 0)
        #expect(chart.tooltip(day: 9) == ["RWKV: 1.0"])
        #expect(chart.tooltip(day: 10) == ["FSRS: 2.0", "RWKV: 1.9"])
        // RWKV is computed through day 11.
        #expect(chart.tooltip(day: 13) == ["FSRS: 1.5"])
        #expect(chart.endDay == 13)
    }

    @Test func rwkvAverageIsZeroBeforeItsCards() throws {
        let chart = try #require(makeChart(.average, .both))
        #expect(chart.startDay == 9)
        // `_.zip` is dense: FSRS averages 0 on day 9; RWKV is 0 / 0 on day 8.
        #expect(chart.lines[0].values == [0, 1, 0.9, 0.8, 0.75])
        #expect(chart.lines[1].values == [1, 0.95, 0.85])
        let early = try #require(MemorisedChart.make(fsrs: nil, rwkv: rwkv, kind: .average, source: .rwkv))
        #expect(early.startDay == 9)
        #expect(early.tooltip(day: 8).isEmpty)
    }

    @Test func rwkvCardsByBurdenKeepsItsHoles() throws {
        let chart = try #require(makeChart(.cardsByBurden, .both))
        #expect(chart.startDay == 9)
        // FSRS: (undefined ?? 0) / 1 on day 9; RWKV: 1 / 1, 1.9 / 0.5, 1.7 / 0.25.
        #expect(chart.lines[0].values == [0, 4, 7.2, .infinity, 7.5])
        #expect(chart.lines[1].values == [1, 3.8, 6.8])
    }

    @Test func nothingToDrawWithoutData() {
        #expect(MemorisedChart.make(fsrs: nil, rwkv: nil, kind: .cards, source: .both) == nil)
        let empty = FsrsMemorisedHistory(today: 5)
        #expect(MemorisedChart.make(fsrs: empty, rwkv: nil, kind: .cards, source: .fsrs) == nil)
        let starting = RwkvMemorisedProgress(phase: "loading")
        #expect(MemorisedChart.make(fsrs: nil, rwkv: starting, kind: .cards, source: .rwkv) == nil)
    }

    @Test func tooltipValuesFollowTheAddOnsFormat() {
        #expect(MemorisedChart.format(1234.5) == "1235")
        #expect(MemorisedChart.format(10.5) == "11")
        #expect(MemorisedChart.format(10) == "10")
        #expect(MemorisedChart.format(9.96) == "10")
        #expect(MemorisedChart.format(9.94) == "9.9")
        #expect(MemorisedChart.format(1) == "1.0")
        #expect(MemorisedChart.format(0.5) == "0.50")
        #expect(MemorisedChart.format(0.123) == "0.12")
        #expect(MemorisedChart.format(0.125) == "0.13")
        #expect(MemorisedChart.format(0.0996) == "0.10")
        #expect(MemorisedChart.format(0.00001234) == "0.000012")
        #expect(MemorisedChart.format(1e-7) == "1.0e-7")
        #expect(MemorisedChart.format(0) == "0.0")
    }

    @Test func progressReportsRoundedPercent() {
        var progress = RwkvMemorisedProgress(phase: "computing", current: 1, total: 8)
        #expect(progress.percent == 13)
        #expect(progress.progressText == "Computing RWKV history: 1 / 8 predictions — 13%")
        progress.current = 9
        #expect(progress.percent == 100)
        progress.total = 0
        #expect(progress.percent == 0)
        progress.phase = "checkpointing"
        #expect(progress.progressText == "Saving resumable RWKV checkpoint…")
    }

    @Test func daysMapToDatesAfterTheRollover() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        let components = DateComponents(year: 2026, month: 3, day: 10, hour: 2)
        let beforeRollover = try #require(calendar.date(from: components))
        let dates = MemorisedDates(today: 100, rollover: 4, now: beforeRollover, calendar: calendar)
        // 2 am is still the scheduler's 9 March.
        let today = dates.date(for: 100, calendar: calendar)
        #expect(calendar.component(.day, from: today) == 9)
        let earlier = dates.date(for: 70, calendar: calendar)
        #expect(calendar.component(.month, from: earlier) == 2)
        #expect(calendar.component(.day, from: earlier) == 7)
        #expect(dates.day(for: earlier, calendar: calendar) == 70)
    }
}
