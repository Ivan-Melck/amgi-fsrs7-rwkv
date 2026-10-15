//
//  FsrsSameDayDecision.swift
//  AnkiKit
//
//  The fork desktop's same-day reviews Help Me Decide (FsrsOptions.svelte
//  `checkSameDayDecision`): FSRS-7 optimized with and without same-day
//  reviews, each scored on all targets and on long-term targets only.
//

/// `SameDayDecisionRow`.
public struct FsrsSameDayDecisionRow: Sendable, Hashable {
    public let label: String
    /// Training targets the optimizer used.
    public let fsrsItems: Int
    public let allTargets: FsrsEvaluation
    public let longTermTargets: FsrsEvaluation

    public init(label: String, fsrsItems: Int, allTargets: FsrsEvaluation, longTermTargets: FsrsEvaluation) {
        self.label = label
        self.fsrsItems = fsrsItems
        self.allTargets = allTargets
        self.longTermTargets = longTermTargets
    }
}

/// `SameDayDecisionComparison`.
public struct FsrsSameDayDecisionComparison: Sendable, Hashable {
    public let withSameDay: FsrsSameDayDecisionRow
    public let withoutSameDay: FsrsSameDayDecisionRow

    public static let withSameDayLabel = "Optimized with same-day reviews"
    public static let withoutSameDayLabel = "Optimized without same-day reviews"
    public static let notEnoughHistoryMessage = "Not enough review history to compare same-day settings."

    public init(withSameDay: FsrsSameDayDecisionRow, withoutSameDay: FsrsSameDayDecisionRow) {
        self.withSameDay = withSameDay
        self.withoutSameDay = withoutSameDay
    }

    public var rows: [FsrsSameDayDecisionRow] { [withSameDay, withoutSameDay] }

    /// The row a metric cell is compared with.
    public func other(than row: FsrsSameDayDecisionRow) -> FsrsSameDayDecisionRow {
        row == withSameDay ? withoutSameDay : withSameDay
    }

    /// `sameDayMetricClass`: a cell is better when lower than the other
    /// row's.
    public static func metricClass(_ value: Float, other: Float) -> FsrsMetricComparison.DeltaClass {
        FsrsMetricComparison.deltaClass(FsrsMetricComparison.delta(Double(other), Double(value)))
    }

    /// `SameDayRecommendation`.
    public struct Recommendation: Sendable, Hashable {
        public let tone: FsrsMetricComparison.DeltaClass
        public let text: String
    }

    /// `sameDayRecommendation`: decided on log loss.
    public var recommendation: Recommendation {
        let allLogLossDelta = FsrsMetricComparison.delta(
            Double(withoutSameDay.allTargets.logLoss),
            Double(withSameDay.allTargets.logLoss)
        )
        let longTermLogLossDelta = FsrsMetricComparison.delta(
            Double(withoutSameDay.longTermTargets.logLoss),
            Double(withSameDay.longTermTargets.logLoss)
        )
        let allText = FsrsMetricComparison.formatDelta(allLogLossDelta)
        let longTermText = FsrsMetricComparison.formatDelta(longTermLogLossDelta)

        if allLogLossDelta == 0 && longTermLogLossDelta == 0 {
            return Recommendation(
                tone: .equal,
                text: "No clear winner: both options have the same log loss on all targets and long-term-only targets."
            )
        }
        if longTermLogLossDelta <= 0
            || (allLogLossDelta < 0 && abs(allLogLossDelta) >= longTermLogLossDelta) {
            return Recommendation(
                tone: .better,
                text: "Recommended: include same-day reviews. "
                    + "All-target log loss changes by \(allText), "
                    + "and long-term-only log loss changes by \(longTermText)."
            )
        }
        return Recommendation(
            tone: .worse,
            text: "Recommended: exclude same-day reviews. "
                + "All-target log loss changes by \(allText), "
                + "but long-term-only log loss changes by \(longTermText)."
        )
    }
}
