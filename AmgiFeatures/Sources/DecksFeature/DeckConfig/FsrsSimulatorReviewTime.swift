//
//  FsrsSimulatorReviewTime.swift
//  DecksFeature
//
//  The workload simulator's answer-time breakdown: the fork desktop's
//  `review-time-matrix` details in SimulatorModal.svelte (same tables,
//  labels and number formatting; the SVG graph as a Swift Chart).
//

import SwiftUI
import Charts
import Theme
import AnkiKit

struct FsrsSimulatorReviewTimeSection: View {
    let reviewTime: FsrsReviewTime

    @Environment(\.palette) private var palette

    private typealias Grade = FsrsReviewTime.Grade
    private var rIndices: Range<Int> { 0..<max(0, reviewTime.rBucketCount) }
    private var sIndices: Range<Int> { 0..<max(0, reviewTime.sBucketCount) }

    var body: some View {
        Section {
            // `tr.statisticsReviewsTimeCheckbox()` is "Time".
            DisclosureGroup("Time Matrix (R/S, Again/Hard/Good/Easy)") {
                table { matrix }
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "time = a + b * (1 - R) + c * S + d * reps + e * D")
                        .font(.caption.monospaced())
                    table { coefficients }
                }
                table { transitions }
                table { successShares }
                table { finalSuccessShares }
                FsrsSimulatorReviewTimeChart(reviewTime: reviewTime)
            }
        }
    }

    private func table(@ViewBuilder _ content: () -> some View) -> some View {
        let rows = content()
        return ScrollView(.horizontal) {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                rows
            }
            .font(.caption.monospacedDigit())
            .padding(.vertical, 4)
        }
    }

    private func header(_ titles: [String]) -> some View {
        GridRow {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                Text(verbatim: title).fontWeight(.semibold)
            }
        }
    }

    /// `review-time-samples high/low`.
    private func samples(_ text: String, high: Bool) -> some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(high ? palette.positive : palette.danger)
    }

    // MARK: Tables

    @ViewBuilder private var matrix: some View {
        // The desktop's markup escapes the backslash twice, so it shows two.
        header(["R \\\\ S"] + sIndices.map { ReviewTimeMatrix.sBucketLabel($0, sBucketCount: reviewTime.sBucketCount) })
        let median = reviewTime.sampleMedian
        ForEach(rIndices, id: \.self) { rIndex in
            GridRow {
                Text(verbatim: ReviewTimeMatrix.rBucketLabel(rIndex)).fontWeight(.semibold)
                ForEach(sIndices, id: \.self) { sIndex in
                    VStack(alignment: .trailing, spacing: 1) {
                        ForEach(Grade.allCases, id: \.self) { grade in
                            let seconds = reviewTime.cellSeconds(grade, rIndex: rIndex, sIndex: sIndex)
                            Text(verbatim: "\(grade.label.prefix(1)) \(FsrsReviewTime.secondsText(seconds))")
                        }
                        let count = reviewTime.cellSampleCount(rIndex: rIndex, sIndex: sIndex)
                        samples("n \(count)", high: Double(count) > median)
                    }
                }
            }
        }
    }

    @ViewBuilder private var coefficients: some View {
        header(["Model", "a", "b", "c", "d", "e"])
        ForEach(Grade.allCases, id: \.self) { grade in
            GridRow {
                Text(verbatim: grade.label).fontWeight(.semibold)
                ForEach(0..<5, id: \.self) { index in
                    Text(verbatim: reviewTime.coeffText(grade, index))
                }
            }
        }
        GridRow {
            Text("Weights").fontWeight(.semibold)
            ForEach(Grade.allCases, id: \.self) { grade in
                Text(verbatim: "\(grade.label.prefix(1)) \(reviewTime.gradeWeightText(grade))")
            }
            Text(verbatim: "")
        }
    }

    @ViewBuilder private var transitions: some View {
        header(["Prev \\\\ Next"] + Grade.allCases.map(\.label))
        ForEach(Grade.allCases, id: \.self) { from in
            GridRow {
                Text(verbatim: from.label).fontWeight(.semibold)
                ForEach(Grade.allCases, id: \.self) { to in
                    let count = reviewTime.transitionCount(from: from.rawValue, to: to.rawValue)
                    VStack(alignment: .trailing, spacing: 1) {
                        let probability = reviewTime.transitionProb(from: from.rawValue, to: to.rawValue)
                        Text(verbatim: FsrsReviewTime.percentText(probability))
                        samples("n \(count)", high: count > 0)
                    }
                }
            }
        }
    }

    @ViewBuilder private var successShares: some View {
        header(["R Bucket", "P(Hard | R)", "P(Good | R)", "P(Easy | R)", "n"])
        ForEach(rIndices, id: \.self) { rIndex in
            successRow(rIndex, (0..<3).map { reviewTime.successGradeProb(rIndex: rIndex, successGrade: $0) })
        }
    }

    @ViewBuilder private var finalSuccessShares: some View {
        header(["R Bucket", "Final P(Hard | success)", "Final P(Good | success)", "Final P(Easy | success)", "n"])
        ForEach(rIndices, id: \.self) { rIndex in
            successRow(rIndex, (0..<3).map { reviewTime.blendedSuccessGradeProb(rIndex: rIndex, successGrade: $0) })
        }
    }

    /// A row of Hard, Good, Easy shares and the bucket's success count.
    private func successRow(_ rIndex: Int, _ probabilities: [Double]) -> some View {
        let count = reviewTime.successGradeCount(rIndex: rIndex)
        return GridRow {
            Text(verbatim: ReviewTimeMatrix.rBucketLabel(rIndex)).fontWeight(.semibold)
            ForEach(Array(probabilities.enumerated()), id: \.offset) { _, probability in
                Text(verbatim: FsrsReviewTime.percentText(probability))
            }
            samples("\(count)", high: count > 0)
        }
    }
}

// MARK: - Graph

/// Seconds per R bucket for each grade and the grade-weighted average.
struct FsrsSimulatorReviewTimeChart: View {
    let reviewTime: FsrsReviewTime

    @Environment(\.palette) private var palette

    private typealias Kind = ReviewTimeGraph.Kind

    private func color(_ kind: Kind) -> Color {
        switch kind {
        case .again: Color(red: 0xe5 / 255, green: 0x48 / 255, blue: 0x4d / 255)
        case .hard: Color(red: 0xf7 / 255, green: 0x90 / 255, blue: 0x09 / 255)
        case .good: Color(red: 0x2b / 255, green: 0xb2 / 255, blue: 0x4c / 255)
        case .easy: Color(red: 0x6f / 255, green: 0xd1 / 255, blue: 0x7e / 255)
        // The desktop's white, which needs a dark background.
        case .weighted: palette.textPrimary
        }
    }

    private func stroke(_ kind: Kind) -> StrokeStyle {
        switch kind {
        case .hard: StrokeStyle(lineWidth: 1.6, dash: [6, 4])
        case .easy: StrokeStyle(lineWidth: 1.6, dash: [2.5, 3])
        case .weighted: StrokeStyle(lineWidth: 2)
        case .again, .good: StrokeStyle(lineWidth: 1.6)
        }
    }

    var body: some View {
        let graph = reviewTime.graph()
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(Array(graph.lines.enumerated()), id: \.offset) { lineIndex, line in
                    ForEach(Array(line.values.enumerated()), id: \.offset) { rIndex, seconds in
                        LineMark(
                            x: .value("R", rIndex),
                            y: .value("Seconds", seconds),
                            series: .value("Line", lineIndex)
                        )
                        .foregroundStyle(color(line.kind))
                        .lineStyle(stroke(line.kind))
                    }
                }
            }
            .chartXScale(domain: 0...max(1, reviewTime.rBucketCount - 1))
            .chartYScale(domain: graph.yMin...graph.yMax)
            .chartXAxis {
                AxisMarks(values: graph.xTicks.map(\.rIndex)) { value in
                    AxisTick()
                    AxisValueLabel {
                        if let rIndex = value.as(Int.self) {
                            Text(verbatim: ReviewTimeMatrix.rBucketLabel(rIndex))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: graph.yTicks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let seconds = value.as(Double.self) {
                            Text(verbatim: "\(JSNumberFormat.toFixed(seconds, 1))s")
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 220)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(Kind.allCases, id: \.self) { kind in
                    HStack(spacing: 6) {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 1))
                            path.addLine(to: CGPoint(x: 16, y: 1))
                        }
                        .stroke(color(kind), style: StrokeStyle(lineWidth: 2, dash: stroke(kind).dash))
                        .frame(width: 16, height: 2)
                        Text(verbatim: kind.legend)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
