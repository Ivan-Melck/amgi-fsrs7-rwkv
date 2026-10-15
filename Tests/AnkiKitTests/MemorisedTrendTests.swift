//
//  MemorisedTrendTests.swift
//  AnkiKitTests
//
//  Ports the Search Stats Extended add-on's trendSelection.test.ts,
//  candlestickBinning.test.ts and cumulativeCandlestick.test.ts cases the
//  Memorised graph relies on, plus its B-W matrix and trend text.
//

import Foundation
import Testing
@testable import AnkiKit

@Suite("Memorised trends")
struct MemorisedTrendTests {
    @Test func filtersInvalidAndZeroYPoints() {
        let points = MemorisedTrend.filtered([
            TrendDatum(x: 0, y: 0),
            TrendDatum(x: 1, y: 2),
            TrendDatum(x: .nan, y: 2),
            TrendDatum(x: 2, y: .infinity),
            TrendDatum(x: 3, y: -1),
        ])
        #expect(points == [TrendDatum(x: 1, y: 2), TrendDatum(x: 3, y: -1)])
    }

    @Test func selectsTrendPointsInclusivelyRegardlessOfOrder() {
        let points = [1.0, 2, 3, 4].map { TrendDatum(x: $0, y: $0 * $0) }
        #expect(MemorisedTrend.inRange(points, 2, 4) == Array(points[1...]))
        #expect(MemorisedTrend.inRange(points, 4, 2) == Array(points[1...]))
    }

    @Test func includesBinsThatOverlapTheRange() {
        let points = [
            TrendDatum(x: 1, y: 1, rangeStart: 0, rangeEnd: 2),
            TrendDatum(x: 4, y: 4, rangeStart: 3, rangeEnd: 5),
            TrendDatum(x: 7, y: 7, rangeStart: 6, rangeEnd: 8),
        ]
        #expect(MemorisedTrend.inRange(points, 2, 3) == Array(points[..<2]))
    }

    @Test func defaultRangeUsesFirstAndLastValidPoints() {
        let range = MemorisedTrend.defaultRange([
            TrendDatum(x: 1, y: 0, rangeStart: 0, rangeEnd: 2),
            TrendDatum(x: 4, y: 10, rangeStart: 3, rangeEnd: 5),
            TrendDatum(x: 6, y: 9, rangeStart: 6, rangeEnd: 8),
            TrendDatum(x: 9, y: 0, rangeStart: 9, rangeEnd: 11),
        ])
        #expect(range == TrendRange(startX: 3, endX: 8))
    }

    @Test func fitsTheSlopeOfValidPoints() throws {
        let trend = try #require(MemorisedTrend.fitted([
            TrendDatum(x: 0, y: 0), TrendDatum(x: 1, y: 2), TrendDatum(x: 2, y: 4), TrendDatum(x: 3, y: 6),
        ]))
        #expect(abs(trend.calcY(3) - trend.calcY(2) - 2) < 1e-9)
        // y = 0 isn't a valid point: two points remain, so no trend.
        #expect(MemorisedTrend.fitted([TrendDatum(x: 0, y: 0), TrendDatum(x: 1, y: 2)]) == nil)
    }

    @Test func endpointTrendJoinsTheRangesEnds() throws {
        let trend = try #require(MemorisedTrend.endpoints([
            TrendDatum(x: 1, y: 2, rangeStart: 0, rangeEnd: 2),
            TrendDatum(x: 4, y: 8, rangeStart: 3, rangeEnd: 5),
        ]))
        #expect(abs(trend.calcY(0) - 2) < 1e-9)
        #expect(abs(trend.calcY(5) - 8) < 1e-9)
        let data = [TrendDatum(x: 0, y: 1), TrendDatum(x: 2, y: 5), TrendDatum(x: 4, y: 9)]
        #expect(abs((MemorisedTrend.make(data, mode: .fitted)?.slope ?? 0) - 2) < 1e-9)
        #expect(abs((MemorisedTrend.make(data, mode: .endpoints)?.calcY(0) ?? 0) - 1) < 1e-9)
        #expect(TrendMode.fitted.toggled == .endpoints)
        #expect(TrendMode.endpoints.toggled == .fitted)
    }

    @Test func summaryUsesTheRememberedAndForgottenPatterns() {
        let up = TrendModel(slope: 2.5, yStart: 10)
        #expect(MemorisedTrend.summary(up, n: 1) == "2.50 cards remembered per day")
        #expect(MemorisedTrend.summary(up, n: 7) == "2.50 cards remembered per day | 17.50 cards remembered per 7 days")
        let down = TrendModel(slope: -0.25, yStart: 10)
        #expect(MemorisedTrend.summary(down, n: 1) == "0.25 cards forgotten per day")
        #expect(MemorisedTrend.display(1.005) == "1.00")
        #expect(MemorisedTrend.display(0.05) == "0.050")
    }

    @Test func appliedTrendsClipToTheVisibleRange() throws {
        let points = (0..<10).map { TrendDatum(x: Double($0), y: Double($0) + 1) }
        let visible = TrendRange(startX: 2, endX: 8)
        let drawn = try #require(MemorisedTrend.apply(points, range: TrendRange(startX: 3, endX: 12), mode: .fitted, visible: visible))
        #expect(drawn.drawStartX == 3 && drawn.drawEndX == 8)
        #expect(abs(drawn.model.slope - 1) < 1e-9)
        // Drawn right to left when picked that way.
        let reversed = try #require(MemorisedTrend.apply(points, range: TrendRange(startX: 7, endX: 0), mode: .endpoints, visible: visible))
        #expect(reversed.drawStartX == 7 && reversed.drawEndX == 2)
        // A start off screen isn't drawn.
        #expect(MemorisedTrend.apply(points, range: TrendRange(startX: 0, endX: 5), mode: .fitted, visible: visible) == nil)
        #expect(MemorisedTrend.apply(points, range: TrendRange(startX: 3, endX: 3), mode: .fitted, visible: nil) == nil)
    }

    // MARK: Candlestick

    /// [1, 3, 6, 10, ..., 55]: running totals of 1...10 from day 0.
    private let cumulative: [Double?] = (1...10).map { n in Double(n * (n + 1) / 2) }

    private func finalTotal(bins: Int, binSize: Int, scroll: Int) -> Double {
        let chart = MemorisedCandlestick(firstDay: 0, values: cumulative, bins: bins, binSize: binSize, offset: scroll)
        return chart.start + chart.bars.map(\.delta).reduce(0, +)
    }

    @Test func candlesticksEndAtTheLastVisibleTotal() {
        #expect(finalTotal(bins: 10, binSize: 1, scroll: 0) == 55)
        #expect(finalTotal(bins: 5, binSize: 2, scroll: 0) == 55)
        #expect(finalTotal(bins: 4, binSize: 3, scroll: 0) == 55)
        #expect(finalTotal(bins: 5, binSize: 1, scroll: -2) == 36)
        #expect(finalTotal(bins: 3, binSize: 2, scroll: -1) == 45)
        #expect(finalTotal(bins: 20, binSize: 1, scroll: 0) == 55)
    }

    @Test func thereAreAlwaysBinsBars() {
        for binSize in [1, 10, 11, 12] {
            let chart = MemorisedCandlestick(firstDay: 0, values: cumulative, binSize: binSize)
            #expect(chart.bars.count == 30)
        }
    }

    @Test func barsCarryLabelsRangesAndTooltips() throws {
        let chart = MemorisedCandlestick(firstDay: 0, values: cumulative, bins: 5, binSize: 2)
        #expect(chart.start == 0)
        #expect(chart.bars.map(\.label) == [-9, -7, -5, -3, -1])
        #expect(chart.bars.map(\.delta) == [3, 7, 11, 15, 19])
        #expect(chart.bars.map(\.trendStart) == [0, 2, 4, 6, 8])
        #expect(chart.bars.map(\.trendEnd) == [1, 3, 5, 7, 9])
        let last = try #require(chart.bars.last)
        #expect(last.positive && last.begin == 36 && last.end == 55)
        #expect(last.tooltip == ["Change: 19.00", "Total: 55.00"])
        // A straight cumulative rise of 2 days' worth per bar.
        let points = chart.trendPoints
        #expect(points.first == TrendDatum(x: 0.5, y: 3, rangeStart: 0, rangeEnd: 1))
        #expect(chart.defaultTrend != nil)
    }

    @Test func fallingBarsAndHolesInTheSeries() throws {
        // nil before the series starts; a NaN day adds nothing, and the day
        // after it changes by its whole value.
        let chart = MemorisedCandlestick(firstDay: 2, values: [5, 4, .nan, 3], bins: 6)
        #expect(chart.bars.map(\.delta) == [0, 0, 5, -1, 0, 3])
        let falling = try #require(chart.bars.first { $0.delta < 0 })
        #expect(!falling.positive && falling.begin == 4 && falling.end == 5)
        #expect(falling.tooltip == ["Change: -1.00", "Total: 4.00"])
    }

    // MARK: B-W matrix

    @Test func bwMatrixShowsWellFilledCells() throws {
        let matrix = MemorisedBwMatrix(rows: [
            MemorisedBwRow(rBin: 5.38, cells: [
                MemorisedBwCell(dBin: 3, predicted: 45.5, real: 48, count: 51),
                MemorisedBwCell(dBin: 4, predicted: 40, real: 40, count: 50),
                MemorisedBwCell(dBin: 10, predicted: 60, real: 55, count: 60),
            ]),
            MemorisedBwRow(rBin: 1.96, cells: [
                MemorisedBwCell(dBin: 9, predicted: 70, real: 50, count: 100),
            ]),
        ])
        #expect(matrix.rows == [1.96, 5.38])
        // 50 reviews are too few; difficulty 10 falls outside the 10 slots.
        #expect(matrix.cells.map(\.column) == [3, 9])
        let cell = try #require(matrix.cells.first)
        #expect(cell.text == "4.9%")
        #expect(cell.tooltip == ["Predicted: 45.50", "Actual: 48", "Total: 51", "(45.50-48)/51=-4.9%"])
        let blue = cell.color
        #expect(blue.blue == 1 && blue.red < 1)
        let red = try #require(matrix.cells.last).color
        #expect(red.red == 1 && red.green == 0 && red.blue == 0)
    }
}
