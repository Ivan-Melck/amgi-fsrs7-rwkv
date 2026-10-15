//
//  MemorisedTrends.swift
//  StatsCharts
//
//  The Memorised graph's "Total" / "Trend" views with their trend lines
//  (LineOrCandlestick.svelte, LineGraph.ts, Candlestick.svelte,
//  selectableTrendLine in trend.ts, TrendValue.svelte) and its B-W matrix
//  (matrix.ts). Tapping picks a trend's start, a second tap its end, as
//  clicks do on the desktop; dragging shows the tooltip.
//

import SwiftUI
import Charts
import Theme
import UI
import AnkiKit

/// A trend the user drew, or the candlestick's default one.
struct MemorisedTrendLine: Identifiable, Equatable {
    let id: Int
    var range: TrendRange
    var mode: TrendMode
    /// Index into `MemorisedTrend.colours`; nil for the default trend.
    let colourIndex: Int?

    var isDefault: Bool { colourIndex == nil }
}

extension Color {
    /// "#rrggbb".
    init(memorisedHex hex: String) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}

/// `LineOrCandlestick` plus `TrendValue` for one series choice.
struct MemorisedTrendGraph: View {
    let chart: MemorisedChart
    let dates: MemorisedDates
    @Binding var binSize: Int
    @Binding var scroll: Int

    init(chart: MemorisedChart, dates: MemorisedDates, binSize: Binding<Int>, scroll: Binding<Int>) {
        self.chart = chart
        self.dates = dates
        _binSize = binSize
        _scroll = scroll
    }

    private enum GraphType: Hashable { case total, trend }

    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @State private var type: GraphType = .total
    @State private var trends: [MemorisedTrendLine] = []
    @State private var anchor: Double?
    @State private var previewEnd: Double?
    @State private var nextId = 1
    @State private var defaultTrendEnabled = true

    /// The selector only shows for a single series; two always draw lines.
    private var showsCandlestick: Bool { chart.lines.count <= 1 && type == .trend }

    private var candlestick: MemorisedCandlestick? {
        guard showsCandlestick, let line = chart.lines.first else { return nil }
        return MemorisedCandlestick(firstDay: chart.startDay, values: line.values, binSize: binSize, offset: scroll)
    }

    /// The points trends fit, and the range they may be drawn in.
    private var trendData: (points: [TrendDatum], visible: TrendRange?) {
        if let candlestick {
            let bars = candlestick.bars
            guard let first = bars.first, let last = bars.last else { return ([], nil) }
            // `visibleTrendRangeFromAxisData`
            let visible = TrendRange(
                startX: Double(min(first.trendStart, first.trendEnd)),
                endX: Double(max(last.trendStart, last.trendEnd))
            )
            return (candlestick.trendPoints, visible)
        }
        // `date_values`: the first series with points, missing values at 0.
        guard let line = chart.lines.first(where: { !$0.values.isEmpty }) else { return ([], nil) }
        let points = line.values.enumerated().map { index, value in
            TrendDatum(x: Double(chart.startDay + index), y: value ?? 0)
        }
        let visible = TrendRange(startX: Double(chart.startDay), endX: Double(chart.startDay + line.values.count - 1))
        return (points, visible)
    }

    private var allTrends: [MemorisedTrendLine] {
        var lines = trends
        // `drawDefaultTrend` for the candlestick, unless it was removed.
        if showsCandlestick, defaultTrendEnabled,
           let range = MemorisedTrend.defaultRange(trendData.points) {
            lines.insert(MemorisedTrendLine(id: 0, range: range, mode: .fitted, colourIndex: nil), at: 0)
        }
        return lines
    }

    private func drawn(_ line: MemorisedTrendLine) -> MemorisedTrend.Drawn? {
        let data = trendData
        return MemorisedTrend.apply(data.points, range: line.range, mode: line.mode, visible: data.visible)
    }

    private var preview: MemorisedTrend.Drawn? {
        guard let anchor, let previewEnd else { return nil }
        let data = trendData
        return MemorisedTrend.apply(
            data.points,
            range: TrendRange(startX: anchor, endX: previewEnd),
            mode: .fitted,
            visible: data.visible
        )
    }

    func colour(_ line: MemorisedTrendLine) -> Color {
        guard let index = line.colourIndex else { return palette.textPrimary }
        let colours = colorScheme == .dark ? MemorisedTrend.nightColours : MemorisedTrend.colours
        return Color(memorisedHex: colours[index % colours.count])
    }

    private var previewColour: Color {
        colour(MemorisedTrendLine(id: -1, range: .init(startX: 0, endX: 0), mode: .fitted, colourIndex: trends.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            if chart.lines.count <= 1 {
                Picker("Graph", selection: $type) {
                    Text("Total").tag(GraphType.total)
                    Text("Trend").tag(GraphType.trend)
                }
                .pickerStyle(.segmented)
            }
            let drawnTrends = allTrends.compactMap { line in drawn(line).map { (line, $0) } }
            let previewLine = preview.map { (previewColour, $0) }
            if let candlestick {
                MemorisedCandlestickChart(
                    candlestick: candlestick,
                    dates: dates,
                    trends: drawnTrends.map { (colour($0.0), $0.1) },
                    preview: previewLine,
                    onHover: { bar in hover(TrendRange(startX: Double(bar.trendStart), endX: Double(bar.trendEnd))) },
                    onTap: { bar in tap(TrendRange(startX: Double(bar.trendStart), endX: Double(bar.trendEnd))) }
                )
                candlestickOptions
            } else {
                MemorisedLineChart(
                    chart: chart,
                    dates: dates,
                    trends: drawnTrends.map { (colour($0.0), $0.1) },
                    preview: previewLine,
                    onHover: { day in hover(TrendRange(startX: Double(day), endX: Double(day))) },
                    onTap: { day in tap(TrendRange(startX: Double(day), endX: Double(day))) }
                )
            }
            legend(drawnTrends)
        }
        .onChange(of: type) {
            trends = []
            anchor = nil
            previewEnd = nil
            defaultTrendEnabled = true
        }
    }

    // MARK: Selection

    private func hover(_ range: TrendRange) {
        guard anchor != nil else { return }
        previewEnd = range.endX
    }

    /// `click.trend`: the first tap anchors, the second draws.
    private func tap(_ range: TrendRange) {
        guard let start = anchor else {
            anchor = range.startX
            previewEnd = nil
            return
        }
        let line = MemorisedTrendLine(
            id: nextId,
            range: TrendRange(startX: start, endX: range.endX),
            mode: .fitted,
            colourIndex: trends.count
        )
        nextId += 1
        anchor = nil
        previewEnd = nil
        if drawn(line) != nil {
            trends.append(line)
        }
    }

    private func remove(_ line: MemorisedTrendLine) {
        if line.isDefault {
            defaultTrendEnabled = false
        } else {
            trends.removeAll { $0.id == line.id }
        }
    }

    private func toggleMode(_ line: MemorisedTrendLine) {
        guard let index = trends.firstIndex(where: { $0.id == line.id }) else { return }
        trends[index].mode = trends[index].mode.toggled
    }

    // MARK: Views

    private var candlestickOptions: some View {
        HStack(spacing: AmgiSpacing.md) {
            Stepper("Bar Width: \(binSize)", value: $binSize, in: 1...365)
            Stepper("Scroll: \(-abs(scroll))", value: $scroll, in: 0...36_500, step: max(binSize, 1))
        }
        .amgiFont(.caption)
    }

    /// `TrendValue.svelte`.
    @ViewBuilder
    private func legend(_ drawn: [(MemorisedTrendLine, MemorisedTrend.Drawn)]) -> some View {
        if anchor != nil || !drawn.isEmpty {
            VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
                if let preview {
                    legendRow(colour: previewColour, text: "Trend (preview): \(MemorisedTrend.summary(preview.model, n: binSize))")
                }
                if anchor != nil {
                    HStack {
                        Text("Tap the trend's last day.")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                        Button("Cancel") {
                            anchor = nil
                            previewEnd = nil
                        }
                        .amgiFont(.caption)
                    }
                }
                // `compareTrendsByStart`
                let sorted = drawn.sorted { a, b in
                    let (ra, rb) = (a.0.range, b.0.range)
                    let (sa, sb) = (min(ra.startX, ra.endX), min(rb.startX, rb.endX))
                    if sa != sb { return sa < sb }
                    let (ea, eb) = (max(ra.startX, ra.endX), max(rb.startX, rb.endX))
                    if ea != eb { return ea < eb }
                    return a.0.id < b.0.id
                }
                ForEach(Array(sorted.enumerated()), id: \.element.0.id) { index, item in
                    HStack(spacing: AmgiSpacing.xs) {
                        legendRow(
                            colour: colour(item.0),
                            text: "Trend \(index + 1): \(MemorisedTrend.summary(item.1.model, n: binSize))"
                        )
                        Spacer(minLength: 0)
                        if !item.0.isDefault {
                            Button {
                                toggleMode(item.0)
                            } label: {
                                Image(systemName: item.0.mode == .fitted ? "line.diagonal" : "chart.line.uptrend.xyaxis")
                            }
                            .accessibilityLabel(item.0.mode == .fitted
                                ? "switch trend to endpoint line"
                                : "switch trend to fitted line")
                        }
                        Button {
                            remove(item.0)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("remove trend")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func legendRow(colour: Color, text: String) -> some View {
        HStack(spacing: AmgiSpacing.xs) {
            RoundedRectangle(cornerRadius: 2)
                .fill(colour)
                .frame(width: 12, height: 4)
            Text(text)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }
}

// MARK: - Candlestick

/// `plotCandlestick`: green rises, red falls, the change and total in the
/// tooltip.
struct MemorisedCandlestickChart: View {
    let candlestick: MemorisedCandlestick
    let dates: MemorisedDates
    let trends: [(Color, MemorisedTrend.Drawn)]
    let preview: (Color, MemorisedTrend.Drawn)?
    let onHover: (MemorisedCandlestick.Bar) -> Void
    let onTap: (MemorisedCandlestick.Bar) -> Void

    init(
        candlestick: MemorisedCandlestick,
        dates: MemorisedDates,
        trends: [(Color, MemorisedTrend.Drawn)],
        preview: (Color, MemorisedTrend.Drawn)?,
        onHover: @escaping (MemorisedCandlestick.Bar) -> Void,
        onTap: @escaping (MemorisedCandlestick.Bar) -> Void
    ) {
        self.candlestick = candlestick
        self.dates = dates
        self.trends = trends
        self.preview = preview
        self.onHover = onHover
        self.onTap = onTap
    }

    @Environment(\.palette) private var palette
    @State private var selected: MemorisedCandlestick.Bar?

    private func label(_ bar: MemorisedCandlestick.Bar) -> String { "\(bar.label)" }

    /// The bar whose days contain `x` (`xToPixel`).
    private func bar(containing x: Double) -> MemorisedCandlestick.Bar? {
        candlestick.bars.first { bar in
            x >= Double(min(bar.trendStart, bar.trendEnd)) && x <= Double(max(bar.trendStart, bar.trendEnd))
        }
    }

    @ChartContentBuilder
    private func trendMarks(_ line: MemorisedTrendStroke) -> some ChartContent {
        if let start = bar(containing: line.drawn.drawStartX), let end = bar(containing: line.drawn.drawEndX) {
            let series = "trend-\(line.id)"
            LineMark(
                x: .value("Days", label(start)),
                y: .value("Trend", line.drawn.model.calcY(line.drawn.drawStartX)),
                series: .value("Trend", series)
            )
            .foregroundStyle(line.color)
            .lineStyle(line.style)
            LineMark(
                x: .value("Days", label(end)),
                y: .value("Trend", line.drawn.model.calcY(line.drawn.drawEndX)),
                series: .value("Trend", series)
            )
            .foregroundStyle(line.color)
            .lineStyle(line.style)
        }
    }

    /// `tooltipDate`: the bar's days, relative to today.
    private func title(_ bar: MemorisedCandlestick.Bar) -> String {
        let left = dates.date(for: dates.today + bar.label).formatted(date: .numeric, time: .omitted)
        guard candlestick.binSize > 1 else { return "\(left):" }
        let right = dates.date(for: dates.today + bar.label + candlestick.binSize - 1)
            .formatted(date: .numeric, time: .omitted)
        return "\(left)-\(right):"
    }

    var body: some View {
        Chart {
            ForEach(candlestick.bars) { bar in
                BarMark(
                    x: .value("Days", label(bar)),
                    yStart: .value("From", bar.begin),
                    yEnd: .value("To", bar.end)
                )
                .foregroundStyle(bar.positive ? Color.green : Color.red)
            }
            ForEach(MemorisedTrendStroke.lines(trends, preview: preview)) { line in
                trendMarks(line)
            }
            if let selected {
                RuleMark(x: .value("Selected", label(selected)))
                    .foregroundStyle(palette.accent.opacity(0.35))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit, y: .fit)) {
                        StatsChartTooltip(title: title(selected), lines: selected.tooltip)
                    }
            }
        }
        .chartYScale(domain: candlestick.minValue...max(candlestick.maxValue, candlestick.minValue + 1e-9))
        .chartXAxis {
            AxisMarks(values: candlestick.bars.enumerated().filter { $0.offset % 5 == 0 }.map { label($0.element) }) { _ in
                AxisValueLabel()
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let bar = bar(at: value.location, proxy: proxy, geometry: geometry) else { return }
                                selected = bar
                                onHover(bar)
                            }
                            .onEnded { value in
                                guard abs(value.translation.width) < 8, abs(value.translation.height) < 8,
                                      let bar = bar(at: value.location, proxy: proxy, geometry: geometry) else { return }
                                onTap(bar)
                            }
                    )
            }
        }
        .frame(height: 200)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memorised trend")
    }

    private func bar(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> MemorisedCandlestick.Bar? {
        guard let frame = proxy.plotFrame else { return nil }
        let x = location.x - geometry[frame].origin.x
        guard let label = proxy.value(atX: x, as: String.self) else { return nil }
        return candlestick.bars.first { self.label($0) == label }
    }
}

// MARK: - B-W matrix

/// `matrix()`: actual minus predicted recall per stability and difficulty
/// bin, red where FSRS overestimates, blue where it underestimates.
struct MemorisedBwMatrixView: View {
    let matrix: MemorisedBwMatrix

    init(matrix: MemorisedBwMatrix) {
        self.matrix = matrix
    }

    @Environment(\.palette) private var palette
    @State private var selected: MemorisedBwMatrix.Cell?

    /// A JavaScript number's text: "1" for 1, "1.96" for 1.96.
    private func label(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : "\(value)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(matrix.rows, id: \.self) { row in
                    GridRow {
                        Text(label(row))
                            .amgiFont(.micro)
                            .foregroundStyle(palette.textSecondary)
                            .gridColumnAlignment(.trailing)
                        ForEach(MemorisedBwMatrix.columns, id: \.self) { column in
                            cell(matrix.cells.first { $0.rBin == row && $0.column == column })
                        }
                    }
                }
                GridRow {
                    Text("")
                    ForEach(MemorisedBwMatrix.columns, id: \.self) { column in
                        Text("\(column)")
                            .amgiFont(.micro)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
            if let selected {
                ForEach(selected.tooltip, id: \.self) { line in
                    Text(line)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ cell: MemorisedBwMatrix.Cell?) -> some View {
        if let cell {
            let colour = cell.color
            Text(cell.text)
                .font(.system(size: 9))
                .foregroundStyle(Color.black)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, minHeight: 24)
                .background(Color(red: colour.red, green: colour.green, blue: colour.blue))
                .overlay(Rectangle().stroke(Color.black, lineWidth: 0.5))
                .onTapGesture { selected = cell }
                .accessibilityLabel(cell.tooltip.joined(separator: ", "))
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 24)
        }
    }
}

/// A trend (or the pending one, dashed) as the charts draw it.
struct MemorisedTrendStroke: Identifiable {
    let id: Int
    let color: Color
    let drawn: MemorisedTrend.Drawn
    let isPreview: Bool

    static func lines(
        _ trends: [(Color, MemorisedTrend.Drawn)],
        preview: (Color, MemorisedTrend.Drawn)?
    ) -> [Self] {
        var lines = trends.enumerated().map { index, trend in
            Self(id: index, color: trend.0, drawn: trend.1, isPreview: false)
        }
        if let preview {
            lines.append(Self(id: trends.count, color: preview.0, drawn: preview.1, isPreview: true))
        }
        return lines
    }

    var style: StrokeStyle {
        StrokeStyle(lineWidth: 1.5, dash: isPreview ? [4, 2] : [])
    }
}
