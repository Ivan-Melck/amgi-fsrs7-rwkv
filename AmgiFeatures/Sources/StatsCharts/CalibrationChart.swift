//
//  CalibrationChart.swift
//  StatsCharts
//
//  The FSRS category's calibration and "FSRS vs RWKV UM+" graphs, which the
//  Search Stats Extended add-on draws on the desktop
//  (`categories/FSRSCategory.svelte`, `FSRScalibration.ts`,
//  `UMPlusGraph.ts`). The numbers come from AnkiKit's `CalibrationReport`.
//

public import SwiftUI
import Charts
import Theme
import UI
public import AnkiKit

/// The graphs' data. Like the add-on's FSRS graphs, it loads on request
/// ("Show?"), then follows the search and period.
public enum CalibrationLoadState: Sendable, Equatable {
    case notRequested
    case loading(RwkvCalibrationProgress?)
    case loaded(CalibrationReport)
    case failed(String)
}

private enum CalibrationColors {
    /// d3's `steelblue`, `green`, `seagreen` and `orange`.
    static let fsrs = Color(red: 70 / 255, green: 130 / 255, blue: 180 / 255)
    static let rwkv = Color(red: 0, green: 128 / 255, blue: 0)
    static let umPlusRwkv = Color(red: 46 / 255, green: 139 / 255, blue: 87 / 255)
    static let perfect = Color(red: 1, green: 165 / 255, blue: 0)

    static func color(_ model: CalibrationModel) -> Color {
        model == .fsrs ? fsrs : rwkv
    }
}

/// The add-on's `MemorisedCalculator`: "Show?", or first "Increase date
/// range" when the period is truncated.
private struct CalibrationRequestView: View {
    let state: CalibrationLoadState
    let isTruncated: Bool
    let onShow: () -> Void
    let onIncreaseDateRange: () -> Void
    let onCancel: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: AmgiSpacing.sm) {
            switch state {
            case .notRequested:
                if isTruncated {
                    Button("Increase date range", action: onIncreaseDateRange)
                        .buttonStyle(.borderedProminent)
                    Button("Show?", action: onShow)
                } else {
                    Button("Show?", action: onShow)
                        .buttonStyle(.borderedProminent)
                }
            case .loading(let progress):
                ProgressView()
                Text("Loading...")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                if let progress, progress.running {
                    Text(progress.label)
                        .amgiFont(.micro)
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.center)
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                    }
                    Button("Cancel", role: .cancel, action: onCancel)
                }
            case .failed(let message):
                Text(message)
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
            case .loaded:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

private struct CalibrationWarnings: View {
    let warnings: [String]

    @Environment(\.palette) private var palette

    var body: some View {
        if !warnings.isEmpty {
            Label(warnings.joined(separator: " "), systemImage: "exclamationmark.triangle")
                .amgiFont(.caption)
                .foregroundStyle(palette.warning)
        }
    }
}

// MARK: - Calibration

public struct CalibrationChart: View {
    let state: CalibrationLoadState
    let isTruncated: Bool
    let onShow: () -> Void
    let onIncreaseDateRange: () -> Void
    let onCancel: () -> Void

    public init(
        state: CalibrationLoadState,
        isTruncated: Bool,
        onShow: @escaping () -> Void,
        onIncreaseDateRange: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.state = state
        self.isTruncated = isTruncated
        self.onShow = onShow
        self.onIncreaseDateRange = onIncreaseDateRange
        self.onCancel = onCancel
    }

    @Environment(\.palette) private var palette
    @State private var mode: CalibrationMode = .fsrs

    public var body: some View {
        AmgiCard(
            background: .surface,
            cornerRadius: AmgiRadius.inset,
            contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        ) {
            VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                Text(mode.title)
                    .amgiFont(.sectionHeading)
                    .foregroundStyle(palette.textPrimary)
                if case .loaded(let report) = state {
                    Picker("Calibration source", selection: $mode) {
                        ForEach(CalibrationMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    CalibrationWarnings(warnings: report.warnings(for: mode))
                    if report.count(for: mode) > 0 {
                        CalibrationPlot(series: report.series(for: mode))
                    } else {
                        Text(mode.noDataMessage)
                            .amgiFont(.body)
                            .foregroundStyle(palette.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                } else {
                    CalibrationRequestView(
                        state: state,
                        isTruncated: isTruncated,
                        onShow: onShow,
                        onIncreaseDateRange: onIncreaseDateRange,
                        onCancel: onCancel
                    )
                }
                // `fsrs-calibration-help`.
                Text("This compares the average retention the selected source predicts you should have on cards (Perfect/orange line) to the retention you actually have (Actual/blue line).")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// `fsrsCalibrationGraph`: actual vs predicted recall per bin with card
/// bootstrap intervals, the perfect diagonal, and each bin's review volume
/// (right axis) over its logarithmic span.
private struct CalibrationPlot: View {
    let series: [CalibrationSeries]

    @Environment(\.palette) private var palette
    @State private var selectedX: Double?

    private struct Bar: Identifiable {
        let model: CalibrationModel
        let index: Int
        let bounds: ClosedRange<Double>
        let height: Double

        var id: String { "\(model.rawValue)-\(index)" }
    }

    private var binCount: Int { series.map(\.bins.count).max() ?? 0 }

    private var maxCount: Int {
        series.flatMap { $0.points.map(\.count) }.filter { $0 > 0 }.max() ?? 0
    }

    private var bars: [Bar] {
        let maxCount = Double(maxCount)
        guard maxCount > 0 else { return [] }
        return series.flatMap { item in
            item.points.map { point in
                Bar(
                    model: item.model,
                    index: point.index,
                    bounds: Calibration.binBounds(index: point.index, binCount: binCount),
                    height: Double(point.count) / maxCount
                )
            }
        }
    }

    /// The volume axis, on the bars' 0…1 scale.
    private var countTicks: [StatsAxisTick] {
        let maxCount = Double(maxCount)
        guard maxCount > 0 else { return [] }
        let tickMax = StatsDualAxisSupport.niceUpperBound(maxCount)
        return StatsDualAxisSupport.ticks(
            domainMax: maxCount,
            plottedMax: tickMax / maxCount,
            formatter: StatsDualAxisSupport.formatCount
        )
        .filter { $0.plottedValue <= 1 + 1e-9 }
    }

    private var selectedIndex: Int? {
        guard let selectedX, binCount > 0 else { return nil }
        let index = (0..<binCount).first { Calibration.binBounds(index: $0, binCount: binCount).contains(selectedX) }
        guard let index, !CalibrationReport.tooltip(series: series, index: index).isEmpty else { return nil }
        return index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
            chart
                .frame(height: 240)
            legend
        }
    }

    private var chart: some View {
        Chart {
            ForEach(bars) { bar in
                RectangleMark(
                    xStart: .value("Predicted", bar.bounds.lowerBound),
                    xEnd: .value("Predicted", bar.bounds.upperBound),
                    yStart: .value("Actual", 0),
                    yEnd: .value("Actual", bar.height)
                )
                .foregroundStyle(CalibrationColors.color(bar.model).opacity(series.count > 1 ? 0.3 : 0.5))
            }
            ForEach([0.0, 1.0], id: \.self) { value in
                LineMark(x: .value("Predicted", value), y: .value("Actual", value), series: .value("Line", "perfect"))
                    .foregroundStyle(CalibrationColors.perfect)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(series) { item in
                ForEach(Array(item.segments.enumerated()), id: \.offset) { segment, points in
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Predicted", point.predicted),
                            y: .value("Actual", point.real),
                            series: .value("Line", "\(item.model.rawValue)-\(segment)")
                        )
                        .foregroundStyle(CalibrationColors.color(item.model))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                ForEach(item.points) { point in
                    if let interval = point.confidenceInterval {
                        RuleMark(
                            x: .value("Predicted", point.predicted),
                            yStart: .value("Actual", interval.lower),
                            yEnd: .value("Actual", interval.upper)
                        )
                        .foregroundStyle(CalibrationColors.color(item.model))
                        .lineStyle(StrokeStyle(lineWidth: 1.25))
                        PointMark(x: .value("Predicted", point.predicted), y: .value("Actual", point.real))
                            .foregroundStyle(CalibrationColors.color(item.model))
                            .symbolSize(20)
                    }
                }
            }
            if let selectedIndex {
                let bounds = Calibration.binBounds(index: selectedIndex, binCount: binCount)
                let lines = CalibrationReport.tooltip(series: series, index: selectedIndex)
                RuleMark(x: .value("Selected", (bounds.lowerBound + bounds.upperBound) / 2))
                    .foregroundStyle(palette.accent.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit, y: .fit)) {
                        StatsChartTooltip(title: lines.first ?? "", lines: Array(lines.dropFirst()))
                    }
            }
        }
        .chartXScale(domain: 0...1)
        .chartYScale(domain: 0...1)
        .chartXSelection(value: $selectedX)
        .chartXAxisLabel("Predicted", alignment: .center)
        .chartYAxisLabel("Actual", position: .leading)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0.0, through: 1.0, by: 0.2))) { value in
                AxisGridLine()
                    .foregroundStyle(palette.textTertiary.opacity(0.25))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Calibration.percent(v))
                            .amgiFont(.micro)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(stride(from: 0.0, through: 1.0, by: 0.2))) { value in
                AxisGridLine()
                    .foregroundStyle(palette.textTertiary.opacity(0.25))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Calibration.percent(v))
                            .amgiFont(.micro)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
            AxisMarks(position: .trailing, values: countTicks.map(\.plottedValue)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(StatsDualAxisSupport.label(for: v, in: countTicks))
                            .amgiFont(.micro)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
        }
    }

    /// The series, and the bars' right axis ("Count").
    private var legend: some View {
        HStack(spacing: AmgiSpacing.md) {
            ForEach(series) { item in
                HStack(spacing: AmgiSpacing.xxs) {
                    Capsule()
                        .fill(CalibrationColors.color(item.model))
                        .frame(width: 18, height: 2)
                    Text(item.label)
                        .amgiFont(.micro)
                        .foregroundStyle(palette.textSecondary)
                }
            }
            HStack(spacing: AmgiSpacing.xxs) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(CalibrationColors.color(series.first?.model ?? .fsrs).opacity(0.4))
                    .frame(width: 10, height: 10)
                Text("Count")
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }
}

// MARK: - UM+

public struct UmPlusChart: View {
    let state: CalibrationLoadState
    let isTruncated: Bool
    let onShow: () -> Void
    let onIncreaseDateRange: () -> Void
    let onCancel: () -> Void

    public init(
        state: CalibrationLoadState,
        isTruncated: Bool,
        onShow: @escaping () -> Void,
        onIncreaseDateRange: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.state = state
        self.isTruncated = isTruncated
        self.onShow = onShow
        self.onIncreaseDateRange = onIncreaseDateRange
        self.onCancel = onCancel
    }

    @Environment(\.palette) private var palette
    @State private var showSmallBuckets = false

    public var body: some View {
        AmgiCard(
            background: .surface,
            cornerRadius: AmgiRadius.inset,
            contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        ) {
            VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                Text("FSRS vs RWKV UM+")
                    .amgiFont(.sectionHeading)
                    .foregroundStyle(palette.textPrimary)
                if case .loaded(let report) = state {
                    CalibrationWarnings(warnings: report.umPlusWarnings)
                    if report.umPlus.count > 0 {
                        Toggle("Show Small Buckets (<200 reviews)", isOn: $showSmallBuckets)
                            .amgiFont(.caption)
                        UmPlusPlot(data: report.umPlus, showSmallBuckets: showSmallBuckets)
                    } else {
                        Text("No reviews have both an eligible FSRS prediction and an eligible RWKV prediction in this search and date range.")
                            .amgiFont(.body)
                            .foregroundStyle(palette.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                } else {
                    CalibrationRequestView(
                        state: state,
                        isTruncated: isTruncated,
                        onShow: onShow,
                        onIncreaseDateRange: onIncreaseDateRange,
                        onCancel: onCancel
                    )
                }
                VStack(alignment: .leading, spacing: AmgiSpacing.xxs) {
                    ForEach(Self.help, id: \.self) { line in
                        Text("• \(line)")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `um-plus-help-*`.
    private static let help = [
        "Closer to 0% is better: above zero means a model overestimated recall, while below zero means it underestimated it.",
        "Right of center, FSRS predicted higher recall than RWKV; left of center, RWKV predicted higher.",
        "Larger bubbles and bars mean more reviews.",
        "Lower UM+ and a slope closer to zero are better.",
        "Buckets under 200 reviews are hidden unless “Show Small Buckets” is enabled.",
    ]
}

/// `renderUmPlusGraph`: each model's mean error against the FSRS − RWKV
/// disagreement, with bucket volume (right axis) behind.
private struct UmPlusPlot: View {
    let data: UmPlusData
    let showSmallBuckets: Bool

    @Environment(\.palette) private var palette
    @State private var selectedX: Double?

    private var visible: [UmPlusBin] { UmPlus.visibleBins(data.bins, showSmallBuckets: showSmallBuckets) }
    private var xDomain: ClosedRange<Double> { UmPlus.disagreementDomain(visible) }
    private var yDomain: ClosedRange<Double> { UmPlus.errorDomain(visible) }
    private var maxCount: Int { visible.map(\.count).max() ?? 0 }

    private struct Series: Identifiable {
        let model: CalibrationModel
        let color: Color
        let error: @Sendable (UmPlusBin) -> Double

        var id: CalibrationModel { model }
    }

    private let series = [
        Series(model: .fsrs, color: CalibrationColors.fsrs, error: { $0.fsrsError }),
        Series(model: .rwkv, color: CalibrationColors.umPlusRwkv, error: { $0.rwkvError }),
    ]

    /// A count on the error axis, as the volume bars and right axis draw it.
    private func volumeY(_ count: Double) -> Double {
        let maxCount = Double(maxCount)
        guard maxCount > 0 else { return yDomain.lowerBound }
        return yDomain.lowerBound + count / maxCount * (yDomain.upperBound - yDomain.lowerBound)
    }

    private var countTicks: [StatsAxisTick] {
        let maxCount = Double(maxCount)
        guard maxCount > 0 else { return [] }
        let span = yDomain.upperBound - yDomain.lowerBound
        let tickMax = StatsDualAxisSupport.niceUpperBound(maxCount)
        return StatsDualAxisSupport.ticks(
            domainMax: maxCount,
            plottedMax: span * tickMax / maxCount,
            formatter: StatsDualAxisSupport.formatCount
        )
        .map { StatsAxisTick(plottedValue: yDomain.lowerBound + $0.plottedValue, label: $0.label) }
        .filter { $0.plottedValue <= yDomain.upperBound + 1e-9 }
    }

    private var selected: UmPlusBin? {
        guard let selectedX else { return nil }
        return visible.first { UmPlus.binBounds($0, domain: xDomain).contains(selectedX) }
    }

    /// `pointRadius` in the add-on's 600-unit graph, as a symbol area on a
    /// phone-width one.
    private func symbolSize(_ bin: UmPlusBin) -> Double {
        let radius = UmPlus.pointRadius(bin, total: data.count) * 0.5
        return Double.pi * radius * radius
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
            chart
                .frame(height: 240)
            ForEach(series) { item in
                HStack(spacing: AmgiSpacing.xxs) {
                    Capsule()
                        .fill(item.color)
                        .frame(width: 18, height: 2)
                    Text(UmPlus.legend(model: item.model, data: data, visibleBins: visible))
                        .amgiFont(.micro)
                        .foregroundStyle(palette.textSecondary)
                }
            }
            // The bars' right axis.
            HStack(spacing: AmgiSpacing.xxs) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(palette.textPrimary.opacity(0.12))
                    .frame(width: 10, height: 10)
                Text("Paired reviews")
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(visible) { bin in
                let bounds = UmPlus.binBounds(bin, domain: xDomain)
                RectangleMark(
                    xStart: .value("Disagreement", bounds.lowerBound),
                    xEnd: .value("Disagreement", bounds.upperBound),
                    yStart: .value("Error", yDomain.lowerBound),
                    yEnd: .value("Error", volumeY(Double(bin.count)))
                )
                .foregroundStyle(palette.textPrimary.opacity(UmPlus.isSmall(bin) ? 0.04 : 0.12))
            }
            RuleMark(y: .value("Error", 0))
                .foregroundStyle(palette.textPrimary)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            if xDomain.contains(0) {
                RuleMark(x: .value("Disagreement", 0))
                    .foregroundStyle(palette.textPrimary.opacity(0.35))
            }
            ForEach(series) { item in
                ForEach(Array(UmPlus.segments(visible).enumerated()), id: \.offset) { index, segment in
                    ForEach([segment.from, segment.to]) { bin in
                        LineMark(
                            x: .value("Disagreement", bin.disagreement),
                            y: .value("Error", item.error(bin)),
                            series: .value("Segment", "\(item.model.rawValue)-\(index)")
                        )
                        .foregroundStyle(item.color.opacity(segment.small ? 0.35 : 1))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: segment.small ? [3, 3] : []))
                    }
                }
                ForEach(visible) { bin in
                    PointMark(x: .value("Disagreement", bin.disagreement), y: .value("Error", item.error(bin)))
                        .foregroundStyle(item.color.opacity(UmPlus.isSmall(bin) ? 0.2 : 0.45))
                        .symbolSize(symbolSize(bin))
                }
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.disagreement))
                    .foregroundStyle(palette.accent.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit, y: .fit)) {
                        let lines = UmPlus.tooltip(selected, total: data.count)
                        StatsChartTooltip(title: lines.first ?? "", lines: Array(lines.dropFirst()))
                    }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXSelection(value: $selectedX)
        .chartXAxisLabel("Difference in predicted p(recall): FSRS minus RWKV", alignment: .center)
        .chartYAxisLabel("B-W Metric", position: .leading)
        .chartXAxis {
            AxisMarks(values: UmPlus.ticksByTenth(xDomain)) { value in
                AxisGridLine()
                    .foregroundStyle(palette.textTertiary.opacity(0.25))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(UmPlus.signedPercent(v))
                            .amgiFont(.micro)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: UmPlus.ticksByTenth(yDomain)) { value in
                AxisGridLine()
                    .foregroundStyle(palette.textTertiary.opacity(0.25))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(UmPlus.signedPercent(v))
                            .amgiFont(.micro)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
            AxisMarks(position: .trailing, values: countTicks.map(\.plottedValue)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(StatsDualAxisSupport.label(for: v, in: countTicks))
                            .amgiFont(.micro)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Calibration") {
    ScrollView {
        CalibrationChart(
            state: .loaded(.sample), isTruncated: false,
            onShow: {}, onIncreaseDateRange: {}, onCancel: {}
        )
        UmPlusChart(
            state: .loaded(.sample), isTruncated: false,
            onShow: {}, onIncreaseDateRange: {}, onCancel: {}
        )
        CalibrationChart(
            state: .notRequested, isTruncated: true,
            onShow: {}, onIncreaseDateRange: {}, onCancel: {}
        )
    }
    .padding()
}
#endif
