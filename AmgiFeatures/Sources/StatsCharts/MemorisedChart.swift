//
//  MemorisedChart.swift
//  StatsCharts
//
//  The fork desktop's "Memorised" graph (Search Stats Extended add-on,
//  MemorisedBar.svelte): cards known each day by FSRS, RWKV or both, as
//  cards, notes, cards per load, average per card, or retrievability
//  weighted by stability.
//

public import SwiftUI
import Charts
import Theme
import UI
public import AnkiKit

/// Where the FSRS series is (`memorised_stats` and the Calculator).
public enum MemorisedCardPhase: Equatable, Sendable {
    /// Not computed yet: "Show?".
    case hidden
    case loading
    case failed(String)
    case loaded
}

public struct MemorisedCard: View {
    let phase: MemorisedCardPhase
    let fsrs: FsrsMemorisedHistory?
    let rwkv: RwkvMemorisedProgress?
    let rwkvAvailable: Bool
    /// The stats period isn't the whole history.
    let truncated: Bool
    @Binding var source: MemorisedSource
    @Binding var kind: MemorisedKind
    let onShow: () -> Void
    let onIncreaseRange: () -> Void
    let onCancelRwkv: () -> Void

    public init(
        phase: MemorisedCardPhase,
        fsrs: FsrsMemorisedHistory?,
        rwkv: RwkvMemorisedProgress?,
        rwkvAvailable: Bool,
        truncated: Bool,
        source: Binding<MemorisedSource>,
        kind: Binding<MemorisedKind>,
        onShow: @escaping () -> Void,
        onIncreaseRange: @escaping () -> Void,
        onCancelRwkv: @escaping () -> Void
    ) {
        self.phase = phase
        self.fsrs = fsrs
        self.rwkv = rwkv
        self.rwkvAvailable = rwkvAvailable
        self.truncated = truncated
        _source = source
        _kind = kind
        self.onShow = onShow
        self.onIncreaseRange = onIncreaseRange
        self.onCancelRwkv = onCancelRwkv
    }

    @Environment(\.palette) private var palette
    /// `binSize` and `scroll`, shared by the trend views and their text.
    @State private var binSize = 1
    @State private var scroll = 0

    public var body: some View {
        AmgiCard(
            background: .surface,
            cornerRadius: AmgiRadius.inset,
            contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        ) {
            VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                Text("Memorised")
                    .amgiFont(.sectionHeading)
                    .foregroundStyle(palette.textPrimary)

                if phase == .loaded, let fsrs {
                    graph(fsrs)
                } else {
                    calculator
                }

                if truncated {
                    warning("It is heavily advised you use \"All history\" for this graph\n\nThis graph re-simulates your review history, leaving the beginning out can greatly affect the results.")
                }
                Text(Self.help)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `memorised-help` and `memorised-help2`.
    private static let help = """
        An FSRS estimate of how many cards you knew at that given time. This depends on FSRS's current parameters and will use the defaults if none are found (Even if you are using SM-2).
        This graph will not work properly with an incomplete review history and will not respect "ignore reviews before".

        In FSRS, each card has a percentage chance of being recalled known as retrievability. This is a sum of those percentages over time.

        Retrievability & Stability multiplies the retrievability of the card by (1-e^(-((8/365)*stability))). The intention here is to see how much knowledge you can maintain in the long term, for example, if you've stopped doing reviews.
        """

    // MARK: - Calculator

    /// `MemorisedCalculator.svelte`: the replay runs on request.
    @ViewBuilder
    private var calculator: some View {
        Group {
            switch phase {
            case .loading, .loaded:
                ProgressView("Loading...")
            case .failed(let message):
                VStack(spacing: AmgiSpacing.sm) {
                    Text(message)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.danger)
                    Button("Show?", action: onShow)
                }
            case .hidden:
                if truncated {
                    VStack(spacing: AmgiSpacing.sm) {
                        Button("Increase date range", action: onIncreaseRange)
                            .buttonStyle(.borderedProminent)
                        Button("Show?", action: onShow)
                    }
                } else {
                    Button("Show?", action: onShow)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    // MARK: - Graph

    @ViewBuilder
    private func graph(_ fsrs: FsrsMemorisedHistory) -> some View {
        if rwkvAvailable {
            Picker("Memorised source", selection: $source) {
                ForEach(MemorisedSource.allCases, id: \.self) { source in
                    Text(source.label).tag(source)
                }
            }
            .pickerStyle(.segmented)
        }
        if !kind.supportsRwkv && source != .fsrs {
            warning("Retrievability & Stability is FSRS-only. The FSRS series is shown for this view.")
        }
        if source != .fsrs, let rwkv {
            if let error = rwkv.error {
                warning(error)
            } else if !rwkv.done {
                rwkvProgress(rwkv)
            }
        }

        let chart = MemorisedChart.make(
            fsrs: fsrs,
            rwkv: source == .fsrs ? nil : rwkv,
            kind: kind,
            source: source
        )
        if let chart {
            MemorisedTrendGraph(
                chart: chart,
                dates: MemorisedDates(today: fsrs.today, rollover: fsrs.rollover),
                binSize: $binSize,
                scroll: $scroll
            )
            // A new series starts a new trend session.
            .id("\(kind)-\(source)")
        } else {
            Text("No memorised data")
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 180)
        }

        Picker("Series", selection: $kind) {
            ForEach(MemorisedKind.allCases, id: \.self) { kind in
                Text(kind.label).tag(kind)
            }
        }
        .pickerStyle(.menu)

        DisclosureGroup("B-W Matrix") {
            MemorisedBwMatrixView(matrix: MemorisedBwMatrix(rows: fsrs.bwMatrix))
        }
        .amgiFont(.caption)
    }

    private func rwkvProgress(_ rwkv: RwkvMemorisedProgress) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
            Text(rwkv.progressText)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
            HStack(spacing: AmgiSpacing.sm) {
                ProgressView(value: Double(rwkv.current), total: Double(max(rwkv.total, 1)))
                    .accessibilityLabel("RWKV Memorised history progress")
                    .frame(maxWidth: .infinity)
                Button("Cancel", action: onCancelRwkv)
                    .disabled(rwkv.phase == "checkpointing")
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .amgiFont(.caption)
            .foregroundStyle(palette.warning)
    }
}

/// `renderLineChart`: one line per series, a tooltip for the touched day,
/// and the trends drawn on it.
struct MemorisedLineChart: View {
    let chart: MemorisedChart
    let dates: MemorisedDates
    var trends: [(Color, MemorisedTrend.Drawn)] = []
    var preview: (Color, MemorisedTrend.Drawn)?
    var onHover: (Int) -> Void = { _ in }
    var onTap: (Int) -> Void = { _ in }

    init(
        chart: MemorisedChart,
        dates: MemorisedDates,
        trends: [(Color, MemorisedTrend.Drawn)] = [],
        preview: (Color, MemorisedTrend.Drawn)? = nil,
        onHover: @escaping (Int) -> Void = { _ in },
        onTap: @escaping (Int) -> Void = { _ in }
    ) {
        self.chart = chart
        self.dates = dates
        self.trends = trends
        self.preview = preview
        self.onHover = onHover
        self.onTap = onTap
    }

    @Environment(\.palette) private var palette
    @State private var selectedDay: Int?

    private struct Point: Identifiable {
        let line: String
        /// Lines break where a value is missing or not finite.
        let segment: Int
        let date: Date
        let value: Double

        var id: String { "\(line)-\(date.timeIntervalSince1970)" }
    }

    private var points: [Point] {
        chart.lines.flatMap { line in
            var segment = 0
            var points: [Point] = []
            for index in line.values.indices {
                guard let value = line.plotted(index) else {
                    segment += 1
                    continue
                }
                points.append(Point(
                    line: line.label,
                    segment: segment,
                    date: dates.date(for: chart.startDay + index),
                    value: value
                ))
            }
            return points
        }
    }

    private func color(_ color: MemorisedLineColor) -> Color {
        switch color {
        case .steelBlue: Color(red: 0x46 / 255, green: 0x82 / 255, blue: 0xb4 / 255)
        case .seaGreen: Color(red: 0x2e / 255, green: 0x8b / 255, blue: 0x57 / 255)
        }
    }

    private var yAxisMax: Double { StatsDualAxisSupport.niceUpperBound(chart.maxValue) }

    /// A trend's y, clamped to the plot like `drawTrendLine`.
    private func trendY(_ drawn: MemorisedTrend.Drawn, _ x: Double) -> Double {
        min(max(drawn.model.calcY(x), 0), yAxisMax)
    }

    @ChartContentBuilder
    private func trendMarks(_ line: MemorisedTrendLine) -> some ChartContent {
        let series = "trend-\(line.id)"
        LineMark(
            x: .value("Date", dates.date(for: Int(line.drawn.drawStartX)), unit: .day),
            y: .value("Trend", trendY(line.drawn, line.drawn.drawStartX)),
            series: .value("Series", series)
        )
        .foregroundStyle(line.color)
        .lineStyle(line.style)
        LineMark(
            x: .value("Date", dates.date(for: Int(line.drawn.drawEndX)), unit: .day),
            y: .value("Trend", trendY(line.drawn, line.drawn.drawEndX)),
            series: .value("Series", series)
        )
        .foregroundStyle(line.color)
        .lineStyle(line.style)
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value("Memorised", point.value),
                    series: .value("Series", "\(point.line)-\(point.segment)")
                )
                .foregroundStyle(by: .value("Source", point.line))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.linear)
            }
            ForEach(MemorisedTrendLine.lines(trends, preview: preview)) { line in
                trendMarks(line)
            }
            if let selectedDay {
                RuleMark(x: .value("Selected", dates.date(for: selectedDay), unit: .day))
                    .foregroundStyle(palette.accent.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit, y: .fit)) {
                        StatsChartTooltip(
                            title: "\(dates.date(for: selectedDay).formatted(date: .numeric, time: .omitted)):",
                            lines: chart.tooltip(day: selectedDay)
                        )
                    }
            }
        }
        .chartForegroundStyleScale(
            domain: chart.lines.map(\.label),
            range: chart.lines.map { color($0.color) }
        )
        .chartLegend(chart.lines.count > 1 ? .visible : .hidden)
        .chartYScale(domain: 0...yAxisMax)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                    .foregroundStyle(palette.textTertiary.opacity(0.25))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(palette.textTertiary.opacity(0.25))
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
                                guard let day = day(at: value.location, proxy: proxy, geometry: geometry) else { return }
                                selectedDay = day
                                onHover(day)
                            }
                            .onEnded { value in
                                guard abs(value.translation.width) < 8, abs(value.translation.height) < 8,
                                      let day = day(at: value.location, proxy: proxy, geometry: geometry) else { return }
                                onTap(day)
                            }
                    )
            }
        }
        .frame(height: 200)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memorised")
        .accessibilityValue(chart.tooltip(day: chart.endDay).joined(separator: ", "))
    }

    /// The hovered day (`hoverData`), within the drawn days.
    private func day(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Int? {
        guard let frame = proxy.plotFrame else { return nil }
        let x = location.x - geometry[frame].origin.x
        guard let date = proxy.value(atX: x, as: Date.self) else { return nil }
        let day = dates.day(for: date)
        return min(max(day, chart.startDay), max(chart.startDay, chart.endDay))
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    @Previewable @State var source = MemorisedSource.both
    @Previewable @State var kind = MemorisedKind.cards
    let days = 60
    let values = (0..<days).map { 40 + Double($0) - 5 * sin(Double($0) / 4) }
    MemorisedCard(
        phase: .loaded,
        fsrs: FsrsMemorisedHistory(
            today: 100,
            retrievability: MemorisedDaySeries(firstDay: 100 - days + 1, values: values),
            cardCount: MemorisedDaySeries(firstDay: 100 - days + 1, values: values.map { $0 + 10 }),
            burden: MemorisedDaySeries(firstDay: 100 - days + 1, values: values.map { $0 / 10 })
        ),
        rwkv: RwkvMemorisedProgress(
            phase: "computing",
            current: 400,
            total: 1_000,
            firstDay: 100 - days + 1,
            completedThroughDay: 80,
            retrievability: values.prefix(40).map { $0 * 1.05 },
            cardCount: values.prefix(40).map { $0 + 10 }
        ),
        rwkvAvailable: true,
        truncated: false,
        source: $source,
        kind: $kind,
        onShow: {},
        onIncreaseRange: {},
        onCancelRwkv: {}
    )
    .padding()
}
#endif
