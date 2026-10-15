//
//  FsrsOptimizationSheets.swift
//  DecksFeature
//
//  The desktop FsrsOptions.svelte popups: Optimization Result (with the
//  custom decay table) and the Same-Day Review Comparison. Tables scroll
//  sideways on narrow screens so they keep the desktop's columns.
//

import AnkiKit
import SwiftUI
import Theme

struct OptimizationComparisonSheet: View {
    let comparison: FsrsOptimizationComparison
    let onLoadCustomDecayTable: (FsrsOptimizationComparison) async throws -> [FsrsDecayRow]
    let onKeep: () -> Void
    let onApply: () -> Void

    @State private var decayRows: [FsrsDecayRow] = []
    @State private var isLoadingDecayTable = false
    @State private var decayTableError: String?
    @Environment(\.palette) private var palette

    private typealias M = FsrsMetricComparison

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FsrsTable {
                        GridRow {
                            FsrsTableHeader("Metric")
                            FsrsTableHeader("Current")
                            FsrsTableHeader("Optimized")
                            FsrsTableHeader("Delta")
                        }
                        metricRow(
                            "Log loss",
                            current: comparison.current.logLoss,
                            optimized: comparison.optimized.logLoss,
                            delta: comparison.logLossDelta,
                            deltaPercent: comparison.logLossDeltaPercent
                        )
                        metricRow(
                            "RMSE (bins)",
                            current: comparison.current.rmseBins,
                            optimized: comparison.optimized.rmseBins,
                            delta: comparison.rmseDelta,
                            deltaPercent: comparison.rmseDeltaPercent
                        )
                    }
                } footer: {
                    if let notice = comparison.notice {
                        Text(notice)
                    }
                }

                Section {
                    Button(decayButtonTitle) {
                        Task { await loadDecayTable() }
                    }
                    .disabled(isLoadingDecayTable || !comparison.supportsCustomDecayTable)
                    if let decayTableError {
                        Text(decayTableError)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.danger)
                    }
                    if !decayRows.isEmpty {
                        decayTable
                    }
                }
            }
            .navigationTitle("Optimization Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep Current", action: onKeep)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Optimized", action: onApply)
                }
            }
        }
        // The desktop popup closes only through its two buttons.
        .interactiveDismissDisabled()
    }

    private var decayButtonTitle: String {
        if !comparison.supportsCustomDecayTable {
            return "Custom Decay Table (FSRS-7 unsupported)"
        }
        return isLoadingDecayTable ? "Processing..." : "Load Custom Decay Table"
    }

    private func metricRow(
        _ title: String,
        current: Float,
        optimized: Float,
        delta: Double,
        deltaPercent: Double?
    ) -> some View {
        GridRow {
            Text(title).fontWeight(.semibold)
            Text(M.formatMetric(Double(current)))
            Text(M.formatMetric(Double(optimized)))
            FsrsDeltaText(delta: delta, deltaPercent: deltaPercent)
        }
    }

    private var decayTable: some View {
        FsrsTable {
            GridRow {
                FsrsTableHeader("Decay")
                FsrsTableHeader("Log loss")
                FsrsTableHeader("Delta")
                FsrsTableHeader("RMSE (bins)")
                FsrsTableHeader("Delta")
            }
            ForEach(Array(decayRows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(FsrsCustomDecayTable.formatDecay(row.decay) + (row.isBaseline ? " (optimized)" : ""))
                        .fontWeight(.semibold)
                    Text(M.formatMetric(row.logLoss))
                    FsrsDeltaText(delta: row.logLossDelta, deltaPercent: row.logLossDeltaPercent)
                    Text(M.formatMetric(row.rmseBins))
                    FsrsDeltaText(delta: row.rmseDelta, deltaPercent: row.rmseDeltaPercent)
                }
            }
        }
    }

    private func loadDecayTable() async {
        guard !isLoadingDecayTable, comparison.supportsCustomDecayTable else { return }
        isLoadingDecayTable = true
        decayTableError = nil
        defer { isLoadingDecayTable = false }
        do {
            decayRows = try await onLoadCustomDecayTable(comparison)
        } catch {
            decayTableError = error.localizedDescription
        }
    }
}

struct SameDayDecisionSheet: View {
    let comparison: FsrsSameDayDecisionComparison

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    private typealias M = FsrsMetricComparison
    private typealias C = FsrsSameDayDecisionComparison

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FsrsTable {
                        GridRow {
                            FsrsTableHeader("Candidate")
                            FsrsTableHeader("Training targets")
                            FsrsTableHeader("All log loss")
                            FsrsTableHeader("All RMSE")
                            FsrsTableHeader("Long-term log loss")
                            FsrsTableHeader("Long-term RMSE")
                        }
                        ForEach(comparison.rows, id: \.label) { row in
                            let other = comparison.other(than: row)
                            GridRow {
                                Text(row.label).fontWeight(.semibold)
                                Text("\(row.fsrsItems)")
                                metricCell(row.allTargets.logLoss, other: other.allTargets.logLoss)
                                metricCell(row.allTargets.rmseBins, other: other.allTargets.rmseBins)
                                metricCell(row.longTermTargets.logLoss, other: other.longTermTargets.logLoss)
                                metricCell(row.longTermTargets.rmseBins, other: other.longTermTargets.rmseBins)
                            }
                        }
                    }
                }

                Section {
                    let recommendation = comparison.recommendation
                    Text(recommendation.text)
                        .foregroundStyle(fsrsDeltaColor(recommendation.tone, palette: palette))
                        .fontWeight(recommendation.tone == .equal ? .regular : .semibold)
                }
            }
            .navigationTitle("Same-Day Review Comparison")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    /// `sameDayMetricClass`.
    private func metricCell(_ value: Float, other: Float) -> some View {
        let tone = C.metricClass(value, other: other)
        return Text(M.formatMetric(Double(value)))
            .foregroundStyle(fsrsDeltaColor(tone, palette: palette))
            .fontWeight(tone == .equal ? .regular : .semibold)
    }
}

// MARK: - Table pieces

/// A sideways-scrolling grid with the desktop table's columns.
private struct FsrsTable<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                content
            }
            .amgiFont(.caption, .monospacedDigits)
            .padding(.vertical, 4)
        }
    }
}

private struct FsrsTableHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    @Environment(\.palette) private var palette

    var body: some View {
        Text(title).foregroundStyle(palette.textSecondary)
    }
}

/// `optimize-delta`: "-0.0123 (-4.56%)", green when lower, red when higher.
private struct FsrsDeltaText: View {
    let delta: Double
    let deltaPercent: Double?

    @Environment(\.palette) private var palette

    var body: some View {
        let tone = FsrsMetricComparison.deltaClass(delta)
        Text("\(FsrsMetricComparison.formatDelta(delta)) (\(FsrsMetricComparison.formatPercentDelta(deltaPercent)))")
            .foregroundStyle(fsrsDeltaColor(tone, palette: palette))
            .fontWeight(tone == .equal ? .regular : .semibold)
    }
}

private func fsrsDeltaColor(_ tone: FsrsMetricComparison.DeltaClass, palette: Palette) -> Color {
    switch tone {
    case .better: palette.positive
    case .worse: palette.danger
    case .equal: palette.textPrimary
    }
}
