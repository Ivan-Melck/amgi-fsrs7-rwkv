//
//  MemorisedTrend.swift
//  AnkiKit
//
//  The rest of the Search Stats Extended add-on's Memorised graph: its
//  B-W matrix (MemorisedBar.svelte, matrix.ts), the "Trend" candlestick
//  view (LineOrCandlestick.svelte, Candlestick.svelte / .ts) and the trend
//  lines with their "remembered per day" text (trend.ts, trendAxis.ts,
//  TrendValue.svelte).
//

import Foundation

// MARK: - B-W matrix

/// One `bw_matrix` cell: the reviews of cards at this difficulty.
public struct MemorisedBwCell: Sendable, Hashable {
    public var dBin: Int
    public var predicted: Double
    public var real: Double
    public var count: Int

    public init(dBin: Int, predicted: Double, real: Double, count: Int) {
        self.dBin = dBin
        self.predicted = predicted
        self.real = real
        self.count = count
    }
}

/// One `bw_matrix` row: cards whose stability falls in `rBin`.
public struct MemorisedBwRow: Sendable, Hashable {
    public var rBin: Double
    public var cells: [MemorisedBwCell]

    public init(rBin: Double, cells: [MemorisedBwCell]) {
        self.rBin = rBin
        self.cells = cells
    }
}

/// The matrix `matrix()` draws: difficulty columns 1-10, stability rows
/// from the largest bin (bottom) to the smallest (top).
public struct MemorisedBwMatrix: Sendable, Hashable {
    public struct Cell: Sendable, Hashable {
        public let rBin: Double
        public let column: Int
        /// `(real - predicted) / count`.
        public let value: Double
        public let bin: MemorisedBwCell

        /// `${(value * 100).toFixed(1)}%`.
        public var text: String { "\(JSNumberFormat.toFixed(value * 100, 1))%" }

        /// `hoverTooltip`.
        public var tooltip: [String] {
            let predicted = JSNumberFormat.toFixed(bin.predicted, 2)
            let real = JSNumberFormat.toFixed(bin.real, 0)
            let count = JSNumberFormat.toFixed(Double(bin.count), 0)
            let percent = JSNumberFormat.toFixed(100 * (bin.predicted - bin.real) / Double(bin.count), 1)
            return [
                "Predicted: \(predicted)",
                "Actual: \(real)",
                "Total: \(count)",
                "(\(predicted)-\(real))/\(count)=\(percent)%",
            ]
        }

        /// The red-white-blue scale over -0.2...0.2 (RGB, 0...1).
        public var color: (red: Double, green: Double, blue: Double) {
            let t = (value + 0.2) / 0.4
            if t <= 0.5 {
                // red to white
                let f = min(max(t / 0.5, 0), 1)
                return (1, f, f)
            }
            // white to blue
            let f = min(max((t - 0.5) / 0.5, 0), 1)
            return (1 - f, 1 - f, 1)
        }
    }

    /// The x bands, "1" to "10".
    public static let columns = Array(1...10)

    /// Row labels top to bottom.
    public let rows: [Double]
    public let cells: [Cell]

    /// `bw_matrix` as the graph shows it: cells with more than 50 reviews,
    /// in the first ten difficulty slots (`new_row.length = 10`), only those
    /// with a column band (difficulty 1-9 here, as d >= 1).
    public init(rows source: [MemorisedBwRow]) {
        rows = source.map(\.rBin).sorted()
        cells = source.flatMap { row in
            row.cells.compactMap { bin -> Cell? in
                guard bin.count > 50, bin.dBin < 10, Self.columns.contains(bin.dBin) else { return nil }
                return Cell(
                    rBin: row.rBin,
                    column: bin.dBin,
                    value: (bin.real - bin.predicted) / Double(bin.count),
                    bin: bin
                )
            }
        }
    }
}

// MARK: - Trend lines

/// `TrendDatum`.
public struct TrendDatum: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var rangeStart: Double?
    public var rangeEnd: Double?

    public init(x: Double, y: Double, rangeStart: Double? = nil, rangeEnd: Double? = nil) {
        self.x = x
        self.y = y
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
    }

    var start: Double { rangeStart ?? x }
    var end: Double { rangeEnd ?? x }
}

/// `TrendModel`: `y = yStart + slope * x`.
public struct TrendModel: Sendable, Hashable {
    public var slope: Double
    public var yStart: Double

    public func calcY(_ x: Double) -> Double { yStart + slope * x }
}

/// `TrendMode`.
public enum TrendMode: String, Sendable, Hashable {
    case fitted
    case endpoints

    /// `toggleTrendMode`.
    public var toggled: TrendMode { self == .fitted ? .endpoints : .fitted }
}

/// `TrendRange`.
public struct TrendRange: Sendable, Hashable {
    public var startX: Double
    public var endX: Double

    public init(startX: Double, endX: Double) {
        self.startX = startX
        self.endX = endX
    }
}

public enum MemorisedTrend {
    /// `filteredTrendData`: finite points with a non-zero y.
    public static func filtered(_ data: [TrendDatum]) -> [TrendDatum] {
        data.filter { $0.x.isFinite && $0.y.isFinite && $0.y != 0 }
    }

    /// `trendDataInRange`: points (or bins) overlapping the range, in
    /// either direction.
    public static func inRange(_ data: [TrendDatum], _ startX: Double, _ endX: Double) -> [TrendDatum] {
        let minX = min(startX, endX)
        let maxX = max(startX, endX)
        return data.filter { $0.end >= minX && $0.start <= maxX }
    }

    /// `createTrendFromData`: the least-squares line (the `trendline`
    /// package) through at least two valid points.
    public static func fitted(_ data: [TrendDatum]) -> TrendModel? {
        let valid = filtered(data)
        guard valid.count >= 2 else { return nil }
        let n = Double(valid.count)
        let xMean = valid.map(\.x).reduce(0, +) / n
        let yMean = valid.map(\.y).reduce(0, +) / n
        let xy = valid.map { ($0.x - xMean) * ($0.y - yMean) }.reduce(0, +)
        let xx = valid.map { pow($0.x - xMean, 2) }.reduce(0, +)
        let slope = xy / xx
        return TrendModel(slope: slope, yStart: yMean - slope * xMean)
    }

    /// `trendEndPoints`: the points starting first and ending last.
    private static func endPoints(_ data: [TrendDatum]) -> (TrendDatum, TrendDatum)? {
        guard let leftmost = data.min(by: { $0.start < $1.start }),
              let rightmost = data.max(by: { $0.end < $1.end }) else { return nil }
        return (leftmost, rightmost)
    }

    private static func finiteRange(_ data: [TrendDatum]) -> [TrendDatum] {
        filtered(data).filter { $0.start.isFinite && $0.end.isFinite }
    }

    /// `createEndpointTrendFromData`: the line through the first point's
    /// start and the last point's end.
    public static func endpoints(_ data: [TrendDatum]) -> TrendModel? {
        guard let (left, right) = endPoints(finiteRange(data)) else { return nil }
        let deltaX = right.end - left.start
        let slope = deltaX == 0 ? 0 : (right.y - left.y) / deltaX
        return TrendModel(slope: slope, yStart: left.y - slope * left.start)
    }

    /// `createTrendForMode`.
    public static func make(_ data: [TrendDatum], mode: TrendMode) -> TrendModel? {
        mode == .endpoints ? endpoints(data) : fitted(data)
    }

    /// `defaultTrendRange`: from the first valid point to the last.
    public static func defaultRange(_ data: [TrendDatum]) -> TrendRange? {
        guard let (left, right) = endPoints(finiteRange(data)) else { return nil }
        return TrendRange(startX: left.start, endX: right.end)
    }

    /// A drawn trend: its line and the part of its range on screen.
    public struct Drawn: Sendable, Hashable {
        public let model: TrendModel
        public let drawStartX: Double
        public let drawEndX: Double
    }

    /// `applyTrendForRange`: the trend of the points in a range, clipped
    /// to the visible range; nil when it can't be drawn (fewer than two
    /// points, or its start is off screen).
    public static func apply(
        _ points: [TrendDatum],
        range: TrendRange,
        mode: TrendMode,
        visible: TrendRange?
    ) -> Drawn? {
        let points = filtered(points)
        guard let model = make(inRange(points, range.startX, range.endX), mode: mode) else { return nil }
        guard let visible else {
            return Drawn(model: model, drawStartX: range.startX, drawEndX: range.endX)
        }
        let visibleMin = min(visible.startX, visible.endX)
        let visibleMax = max(visible.startX, visible.endX)
        // `isTrendStartVisible`
        guard range.startX >= visibleMin, range.startX <= visibleMax else { return nil }
        let clippedMin = max(min(range.startX, range.endX), visibleMin)
        let clippedMax = min(max(range.startX, range.endX), visibleMax)
        guard clippedMin <= clippedMax else { return nil }
        return range.startX <= range.endX
            ? Drawn(model: model, drawStartX: clippedMin, drawEndX: clippedMax)
            : Drawn(model: model, drawStartX: clippedMax, drawEndX: clippedMin)
    }

    /// `trendColours` (light) and `trendColoursNight`, cycled by the
    /// number of custom trends before.
    public static let colours = ["#e63946", "#1d3557", "#2a9d8f", "#f4a261", "#6a4c93", "#457b9d"]
    public static let nightColours = ["#ff9aa2", "#a9def9", "#b8f2e6", "#ffd6a5", "#d0bfff", "#bde0fe"]

    /// `valueFromTrend` and `trendSummary` with the memorised graph's
    /// `remembered-per-day` / `forgotten-per-day` patterns (absolute
    /// values; `n` is the candlestick bar width).
    public static func summary(_ trend: TrendModel, n: Int) -> String {
        let value = abs(trend.calcY(Double(n)) - trend.yStart)
        let verb = trend.slope > 0 ? "remembered" : "forgotten"
        func pattern(_ value: Double, _ n: Int) -> String {
            // `{$value}` is text, so the plural selector falls back to
            // "cards"; `{$n}` is a number.
            "\(display(value)) cards \(verb) per \(n == 1 ? "day" : "\(n) days")"
        }
        if n <= 1 {
            return pattern(value, n)
        }
        return "\(pattern(value / Double(n), 1)) | \(pattern(value, n))"
    }

    /// `display`: `value > 1 ? value.toFixed(2) : value.toPrecision(2)`.
    public static func display(_ value: Double) -> String {
        value > 1 ? JSNumberFormat.toFixed(value, 2) : JSNumberFormat.toPrecision(value, 2)
    }
}

// MARK: - Candlestick

/// The "Trend" view of a single series: `bins` bars of `binSize` days'
/// changes ending `offset` days before the series' last day, on top of the
/// value just before them.
public struct MemorisedCandlestick: Sendable, Hashable {
    public struct Bar: Sendable, Hashable, Identifiable {
        /// `candlestickDisplayLabelFromIndex`: days relative to the end.
        public let label: Int
        public let delta: Double
        /// The total before and after the bar, lowest first.
        public let begin: Double
        public let end: Double
        public let positive: Bool
        /// The data days the bar covers (`trendStart` / `trendEnd`).
        public let trendStart: Int
        public let trendEnd: Int

        public var id: Int { label }

        /// The tooltip's change and total lines.
        public var tooltip: [String] {
            let change = (end - begin) * (positive ? 1 : -1)
            let total = positive ? end : begin
            return [
                "Change: \(JSNumberFormat.toFixed(change, 2))",
                "Total: \(JSNumberFormat.toFixed(total, 2))",
            ]
        }
    }

    public let start: Double
    public let bars: [Bar]
    public let binSize: Int

    /// `LineOrCandlestick`'s `candlestick_data` and `Candlestick.svelte`'s
    /// bars. `values` are the series from `firstDay` (nil where it has
    /// none); the series ends at `firstDay + values.count - 1`.
    public init(firstDay: Int, values: [Double?], bins: Int = 30, binSize: Int = 1, offset: Int = 0) {
        let binSize = max(binSize, 1)
        let length = firstDay + values.count
        func element(_ index: Int) -> Double? {
            let i = index - firstDay
            return values.indices.contains(i) ? values[i] : nil
        }
        // `x || 0`
        func orZero(_ value: Double?) -> Double {
            guard let value, value != 0, !value.isNaN else { return 0 }
            return value
        }
        // `DeltaIfy`: undefined - previous is NaN.
        func delta(_ index: Int) -> Double {
            (element(index) ?? .nan) - orZero(index > 0 ? element(index - 1) : nil)
        }
        let scroll = abs(offset)
        let window = bins * binSize
        start = orZero(element(length - window - scroll - 1))
        let realOffset = -scroll
        let leftmost = -window + realOffset
        // `_.range(leftmost, realOffset, binSize)`
        var labels: [Int] = []
        var i = leftmost
        while i < realOffset {
            labels.append(i)
            i += binSize
        }
        var deltas = labels.map { _ in 0.0 }
        var trendEnds = labels.map { length + $0 }
        // `data.data.slice(leftmost, realOffset || undefined)`
        let sliceStart = max(length + leftmost, 0)
        let sliceEnd = max(length + realOffset, 0)
        if sliceStart < sliceEnd {
            for (j, day) in (sliceStart..<sliceEnd).enumerated() {
                let bin = j / binSize
                guard deltas.indices.contains(bin) else { continue }
                deltas[bin] += orZero(delta(day))
                trendEnds[bin] = day
            }
        }
        var total = start
        bars = labels.indices.map { index in
            let begin = total
            total += deltas[index]
            let positive = deltas[index] > 0
            return Bar(
                label: labels[index] + 1,
                delta: deltas[index],
                begin: positive ? begin : total,
                end: positive ? total : begin,
                positive: positive,
                trendStart: length + labels[index],
                trendEnd: trendEnds[index]
            )
        }
        self.binSize = binSize
    }

    /// The default trend's points: each bar's running total at its days'
    /// midpoint.
    public var trendPoints: [TrendDatum] {
        var total = start
        return bars.map { bar in
            total += bar.delta
            return TrendDatum(
                x: Double(bar.trendStart + bar.trendEnd) / 2,
                y: total,
                rangeStart: Double(bar.trendStart),
                rangeEnd: Double(bar.trendEnd)
            )
        }
    }

    /// The trend drawn by default: fitted over every bar.
    public var defaultTrend: TrendModel? {
        guard let range = MemorisedTrend.defaultRange(trendPoints) else { return nil }
        return MemorisedTrend.fitted(MemorisedTrend.inRange(MemorisedTrend.filtered(trendPoints), range.startX, range.endX))
    }

    /// The y extent of the bars.
    public var minValue: Double { bars.map(\.begin).min() ?? 0 }
    public var maxValue: Double { bars.map(\.end).max() ?? 0 }
}
