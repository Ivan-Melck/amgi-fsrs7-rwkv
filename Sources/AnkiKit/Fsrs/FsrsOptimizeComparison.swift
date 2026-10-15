//
//  FsrsOptimizeComparison.swift
//  AnkiKit
//
//  The fork desktop's ts/routes/deck-options/optimize-comparison.ts and
//  the Optimization Result popup state of FsrsOptions.svelte.
//

public import Foundation

/// The metric helpers of `optimize-comparison.ts`. Values are doubles, as
/// in the desktop's JavaScript; smaller metrics are better.
public enum FsrsMetricComparison {
    public enum DeltaClass: Sendable, Hashable {
        case better
        case worse
        case equal
    }

    /// `metricDelta`: new minus old.
    public static func delta(_ old: Double, _ new: Double) -> Double {
        new - old
    }

    /// `metricDeltaPercent`; nil when old is 0 but new isn't.
    public static func deltaPercent(_ old: Double, _ new: Double) -> Double? {
        if old == 0 {
            return new == 0 ? 0 : nil
        }
        return ((new - old) / old) * 100
    }

    /// `deltaClass`.
    public static func deltaClass(_ delta: Double) -> DeltaClass {
        if delta < 0 { return .better }
        if delta > 0 { return .worse }
        return .equal
    }

    /// `formatMetric`.
    public static func formatMetric(_ value: Double) -> String {
        toFixed(value, 4)
    }

    /// `formatDelta`.
    public static func formatDelta(_ delta: Double) -> String {
        if delta == 0 { return "0.0000" }
        return "\(delta > 0 ? "+" : "")\(toFixed(delta, 4))"
    }

    /// `formatPercentDelta`.
    public static func formatPercentDelta(_ deltaPercent: Double?) -> String {
        guard let deltaPercent else { return "n/a" }
        if deltaPercent == 0 { return "0.00%" }
        return "\(deltaPercent > 0 ? "+" : "")\(toFixed(deltaPercent, 2))%"
    }

    /// JavaScript's `Number.prototype.toFixed`: rounds the exact binary
    /// value half away from zero (printf rounds exact ties to even, so
    /// 0.125 would give "0.12" instead of "0.13"), and -0 prints as "0".
    public static func toFixed(_ value: Double, _ digits: Int) -> String {
        JSNumberFormat.toFixed(value, digits)
    }
}

/// `OptimizationComparison`: current vs optimized parameters, scored on
/// the evaluation search, for the user to keep or apply.
public struct FsrsOptimizationComparison: Sendable, Hashable {
    public let optimizedParams: [Float]
    /// ADR model fitted with the parameters; applied with them.
    public let dynamicDesiredRetention: FsrsDynamicDesiredRetention?
    public let search: String
    public let ignoreRevlogsBefore: Date?
    public let includeSameDayReviews: Bool?
    public let current: FsrsEvaluation
    public let optimized: FsrsEvaluation
    /// What the desktop alerts while the popup is open (the health check).
    public let notice: String?

    public init(
        optimizedParams: [Float],
        dynamicDesiredRetention: FsrsDynamicDesiredRetention?,
        search: String,
        ignoreRevlogsBefore: Date?,
        includeSameDayReviews: Bool?,
        current: FsrsEvaluation,
        optimized: FsrsEvaluation,
        notice: String? = nil
    ) {
        self.optimizedParams = optimizedParams
        self.dynamicDesiredRetention = dynamicDesiredRetention
        self.search = search
        self.ignoreRevlogsBefore = ignoreRevlogsBefore
        self.includeSameDayReviews = includeSameDayReviews
        self.current = current
        self.optimized = optimized
        self.notice = notice
    }

    public var logLossDelta: Double {
        FsrsMetricComparison.delta(Double(current.logLoss), Double(optimized.logLoss))
    }

    public var rmseDelta: Double {
        FsrsMetricComparison.delta(Double(current.rmseBins), Double(optimized.rmseBins))
    }

    public var logLossDeltaPercent: Double? {
        FsrsMetricComparison.deltaPercent(Double(current.logLoss), Double(optimized.logLoss))
    }

    public var rmseDeltaPercent: Double? {
        FsrsMetricComparison.deltaPercent(Double(current.rmseBins), Double(optimized.rmseBins))
    }

    /// The Custom Decay Table button is disabled for FSRS-7 parameters.
    public var supportsCustomDecayTable: Bool {
        FsrsCustomDecayTable.supports(optimizedParams)
    }

    /// The requests `loadCustomDecayTable` sends, one per candidate decay.
    public func customDecayRequests() -> [(decay: Double, request: FsrsEvaluateLegacyRequest)] {
        FsrsCustomDecayTable.candidates.map { decay in
            (decay, FsrsEvaluateLegacyRequest(
                params: FsrsCustomDecayTable.withLastParam(optimizedParams, Float(decay)),
                search: search,
                ignoreRevlogsBefore: ignoreRevlogsBefore,
                includeSameDayReviews: includeSameDayReviews
            ))
        }
    }

    /// `loadCustomDecayTable`'s rows: the optimized decay first, then each
    /// candidate compared with it.
    public func customDecayRows(_ results: [(decay: Double, evaluation: FsrsEvaluation)]) -> [FsrsDecayRow] {
        let baselineLogLoss = Double(optimized.logLoss)
        let baselineRmse = Double(optimized.rmseBins)
        let baseline = FsrsDecayRow(
            decay: optimizedParams.last.map(Double.init) ?? 0,
            isBaseline: true,
            logLoss: baselineLogLoss,
            rmseBins: baselineRmse,
            logLossDelta: 0,
            logLossDeltaPercent: 0,
            rmseDelta: 0,
            rmseDeltaPercent: 0
        )
        return [baseline] + results.map { decay, evaluation in
            let logLoss = Double(evaluation.logLoss)
            let rmse = Double(evaluation.rmseBins)
            return FsrsDecayRow(
                decay: decay,
                isBaseline: false,
                logLoss: logLoss,
                rmseBins: rmse,
                logLossDelta: FsrsMetricComparison.delta(baselineLogLoss, logLoss),
                logLossDeltaPercent: FsrsMetricComparison.deltaPercent(baselineLogLoss, logLoss),
                rmseDelta: FsrsMetricComparison.delta(baselineRmse, rmse),
                rmseDeltaPercent: FsrsMetricComparison.deltaPercent(baselineRmse, rmse)
            )
        }
    }
}

/// `DecayRow`.
public struct FsrsDecayRow: Sendable, Hashable {
    public let decay: Double
    public let isBaseline: Bool
    public let logLoss: Double
    public let rmseBins: Double
    public let logLossDelta: Double
    public let logLossDeltaPercent: Double?
    public let rmseDelta: Double
    public let rmseDeltaPercent: Double?

    public init(
        decay: Double,
        isBaseline: Bool,
        logLoss: Double,
        rmseBins: Double,
        logLossDelta: Double,
        logLossDeltaPercent: Double?,
        rmseDelta: Double,
        rmseDeltaPercent: Double?
    ) {
        self.decay = decay
        self.isBaseline = isBaseline
        self.logLoss = logLoss
        self.rmseBins = rmseBins
        self.logLossDelta = logLossDelta
        self.logLossDeltaPercent = logLossDeltaPercent
        self.rmseDelta = rmseDelta
        self.rmseDeltaPercent = rmseDeltaPercent
    }
}

/// The fork desktop's ts/routes/deck-options/custom-decay-table.ts.
public enum FsrsCustomDecayTable {
    /// `customDecayCandidates`.
    public static let candidates: [Double] = [0.1, 0.15, 0.2, 0.25, 0.35, 0.4]

    /// `supportsCustomDecayTable`: not for FSRS-7 (34 parameters).
    public static func supports(_ params: [Float]) -> Bool {
        !params.isEmpty && params.count < 34
    }

    /// `withLastParam`: the decay is the last parameter.
    public static func withLastParam(_ params: [Float], _ value: Float) -> [Float] {
        guard !params.isEmpty else { return [] }
        var next = params
        next[next.count - 1] = value
        return next
    }

    /// `formatDecay`.
    public static func formatDecay(_ decay: Double) -> String {
        FsrsMetricComparison.toFixed(decay, 2)
    }
}

/// The parts of the desktop's `computeParams` that decide what to show
/// after an optimization.
public enum FsrsOptimizeOutcome {
    /// `deck-config-fsrs-good-fit`.
    public static let goodFitMessage = "Health Check:\nFSRS can adapt to your memory well."
    /// `deck-config-fsrs-params-optimal`.
    public static let paramsOptimalMessage =
        "The FSRS parameters are currently optimal. This is expected once parameters are well-fitted to your review history. You can try optimizing again after doing more reviews."
    /// `deck-config-fsrs-params-no-reviews`.
    public static let noReviewsMessage =
        "No reviews found. Make sure this preset is assigned to all decks (including subdecks) that you want to optimize, and try again."

    /// `alreadyOptimal`: the optimizer returned nothing, or the current
    /// parameters already match to 4 decimals. (The desktop compares index
    /// by index and would throw if the optimized list were shorter; that
    /// counts as a change here.)
    public static func alreadyOptimal(current: [Float], optimized: [Float]) -> Bool {
        if optimized.isEmpty { return true }
        guard !current.isEmpty, current.count <= optimized.count else { return false }
        return zip(current, optimized).allSatisfy { old, new in
            FsrsMetricComparison.toFixed(Double(old), 4) == FsrsMetricComparison.toFixed(Double(new), 4)
        }
    }

    /// The message the desktop alerts after optimizing; nil when silent.
    /// A failed health check adds nothing, as in the fork.
    public static func notice(
        alreadyOptimal: Bool,
        trainingItemCount: Int,
        healthCheck: FsrsOptimizeResult.HealthCheck?
    ) -> String? {
        let healthCheckMessage = healthCheck == .passed ? goodFitMessage : ""
        let alreadyOptimalMessage = alreadyOptimal
            ? (trainingItemCount != 0 ? paramsOptimalMessage : noReviewsMessage)
            : ""
        let message = [alreadyOptimalMessage, healthCheckMessage]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return message.isEmpty ? nil : message
    }
}
