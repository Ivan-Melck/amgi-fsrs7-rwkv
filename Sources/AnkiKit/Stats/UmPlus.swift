//
//  UmPlus.swift
//  AnkiKit
//
//  "FSRS vs RWKV UM+", drawn next to the calibration graph by the Search
//  Stats Extended add-on on the desktop: `umPlusData.ts` and the axes,
//  legend and tooltip of `UMPlusGraph.ts`.
//

import Foundation

/// `UmPlusBin`: reviews whose FSRS-minus-RWKV disagreement rounds to the
/// same 5% step, with each model's mean error (prediction minus outcome).
public struct UmPlusBin: Sendable, Hashable, Identifiable {
    public let index: Int
    public let disagreement: Double
    public let fsrsError: Double
    public let rwkvError: Double
    public let count: Int

    public var id: Int { index }

    public init(index: Int, disagreement: Double, fsrsError: Double, rwkvError: Double, count: Int) {
        self.index = index
        self.disagreement = disagreement
        self.fsrsError = fsrsError
        self.rwkvError = rwkvError
        self.count = count
    }
}

/// `UmPlusData`.
public struct UmPlusData: Sendable, Hashable {
    public let bins: [UmPlusBin]
    public let fsrsScore: Double
    public let rwkvScore: Double
    public let count: Int

    public init(bins: [UmPlusBin], fsrsScore: Double, rwkvScore: Double, count: Int) {
        self.bins = bins
        self.fsrsScore = fsrsScore
        self.rwkvScore = rwkvScore
        self.count = count
    }
}

public enum UmPlus {
    /// `UM_PLUS_BINS_PER_UNIT`, `UM_PLUS_BIN_COUNT`,
    /// `UM_PLUS_SMALL_BUCKET_THRESHOLD`.
    public static let binsPerUnit = 20
    public static let binCount = 2 * binsPerUnit + 1
    public static let smallBucketThreshold = 200

    /// `visibleUmPlusBins`.
    public static func visibleBins(_ bins: [UmPlusBin], showSmallBuckets: Bool) -> [UmPlusBin] {
        showSmallBuckets ? bins : bins.filter { $0.count >= smallBucketThreshold }
    }

    /// `roundedTenthDomain`.
    static func roundedTenthDomain(_ values: [Double], fallback: ClosedRange<Double>) -> ClosedRange<Double> {
        guard let min = values.min(), let max = values.max() else { return fallback }
        let step = 0.1
        let tolerance = 1e-10
        var lower = Swift.max(-1, ((min + tolerance) / step).rounded(.down) * step)
        var upper = Swift.min(1, ((max - tolerance) / step).rounded(.up) * step)
        if abs(upper - lower) < tolerance {
            lower = Swift.max(-1, lower - step)
            upper = Swift.min(1, upper + step)
        }
        return tenth(lower)...tenth(upper)
    }

    /// `Number(value.toFixed(1))`.
    private static func tenth(_ value: Double) -> Double {
        Double(JSNumber.toFixed(value, 1)) ?? value
    }

    /// `umPlusDisagreementDomain`.
    public static func disagreementDomain(_ bins: [UmPlusBin]) -> ClosedRange<Double> {
        roundedTenthDomain(bins.map(\.disagreement), fallback: -1...1)
    }

    /// `umPlusErrorDomain`: always includes 0 strictly inside.
    public static func errorDomain(_ bins: [UmPlusBin]) -> ClosedRange<Double> {
        guard !bins.isEmpty else { return -0.1...0.1 }
        let domain = roundedTenthDomain(
            [0] + bins.flatMap { [$0.fsrsError, $0.rwkvError] },
            fallback: -0.1...0.1
        )
        let lower = domain.lowerBound == 0 ? -0.1 : domain.lowerBound
        let upper = domain.upperBound == 0 ? 0.1 : domain.upperBound
        return lower...upper
    }

    /// `weightedRmse`.
    static func weightedRmse(_ bins: [UmPlusBin], count: Int, error: (UmPlusBin) -> Double) -> Double {
        guard count > 0 else { return 0 }
        let sum = bins.reduce(0.0) { $0 + Double($1.count) * error($1) * error($1) }
        return (sum / Double(count)).squareRoot()
    }

    /// `weightedRegressionSlope`: error against disagreement, weighted by
    /// reviews; nil without disagreement variation.
    public static func weightedRegressionSlope(_ bins: [UmPlusBin], value: (UmPlusBin) -> Double) -> Double? {
        let count = Double(bins.reduce(0) { $0 + $1.count })
        guard count > 0 else { return nil }
        let meanX = bins.reduce(0.0) { $0 + Double($1.count) * $1.disagreement } / count
        let meanY = bins.reduce(0.0) { $0 + Double($1.count) * value($1) } / count
        let covariance = bins.reduce(0.0) {
            $0 + Double($1.count) * ($1.disagreement - meanX) * (value($1) - meanY)
        }
        let variance = bins.reduce(0.0) {
            $0 + Double($1.count) * ($1.disagreement - meanX) * ($1.disagreement - meanX)
        }
        return variance > 1e-12 ? covariance / variance : nil
    }

    /// `buildUmPlusData`: paired predictions grouped by their signed
    /// disagreement (FSRS minus RWKV), with each model's mean error per bin.
    public static func build(
        samples: [CalibrationSample],
        fsrsPredictions: [Int64: Double],
        rwkvPredictions: [Int64: Double]
    ) -> UmPlusData {
        var sumDisagreement = Array(repeating: 0.0, count: binCount)
        var sumFsrsError = Array(repeating: 0.0, count: binCount)
        var sumRwkvError = Array(repeating: 0.0, count: binCount)
        var counts = Array(repeating: 0, count: binCount)
        for sample in samples {
            guard let fsrs = fsrsPredictions[sample.revlogId],
                  let rwkv = rwkvPredictions[sample.revlogId],
                  Calibration.isValidProbability(fsrs),
                  Calibration.isValidProbability(rwkv),
                  Calibration.isValidProbability(sample.actual)
            else { continue }
            let disagreement = fsrs - rwkv
            let index = max(0, min(binCount - 1, Int(JSNumber.round(disagreement * Double(binsPerUnit))) + binsPerUnit))
            sumDisagreement[index] += disagreement
            sumFsrsError[index] += fsrs - sample.actual
            sumRwkvError[index] += rwkv - sample.actual
            counts[index] += 1
        }
        let bins = counts.indices.compactMap { index -> UmPlusBin? in
            let count = counts[index]
            guard count > 0 else { return nil }
            return UmPlusBin(
                index: index,
                disagreement: sumDisagreement[index] / Double(count),
                fsrsError: sumFsrsError[index] / Double(count),
                rwkvError: sumRwkvError[index] / Double(count),
                count: count
            )
        }
        let count = counts.reduce(0, +)
        return UmPlusData(
            bins: bins,
            fsrsScore: weightedRmse(bins, count: count) { $0.fsrsError },
            rwkvScore: weightedRmse(bins, count: count) { $0.rwkvError },
            count: count
        )
    }

    // MARK: - Graph (`UMPlusGraph.ts`)

    /// `signedPercent`.
    public static func signedPercent(_ value: Double, digits: Int = 0) -> String {
        let normalized = abs(value) < 1e-12 ? 0 : value
        return "\(normalized > 0 ? "+" : "")\(JSNumber.toFixed(normalized * 100, digits))%"
    }

    /// `ticksByTenth`: every 10 percentage points in the domain.
    public static func ticksByTenth(_ domain: ClosedRange<Double>) -> [Double] {
        let first = Int((domain.lowerBound * 10 - 1e-10).rounded(.up))
        let last = Int((domain.upperBound * 10 + 1e-10).rounded(.down))
        guard last >= first else { return [] }
        return (first...last).map { tenth(Double($0) / 10) }
    }

    /// `formatSlope` (`um-plus-slope-unavailable` when nil).
    public static func formatSlope(_ slope: Double?) -> String {
        guard let slope else { return "n/a" }
        let normalized = abs(slope) < 5e-4 ? 0 : slope
        return "\(normalized > 0 ? "+" : "")\(JSNumber.toFixed(normalized, 3))"
    }

    /// The legend entry (`um-plus-legend`).
    public static func legend(model: CalibrationModel, data: UmPlusData, visibleBins: [UmPlusBin]) -> String {
        let name = model == .fsrs ? "FSRS" : "RWKV"
        let score = model == .fsrs ? data.fsrsScore : data.rwkvScore
        let slope = weightedRegressionSlope(visibleBins) { model == .fsrs ? $0.fsrsError : $0.rwkvError }
        return "\(name), UM+=\(JSNumber.toFixed(score, 4)), slope=\(formatSlope(slope))"
    }

    /// Whether a bucket is drawn faint and dashed.
    public static func isSmall(_ bin: UmPlusBin) -> Bool {
        bin.count < smallBucketThreshold
    }

    /// `binBounds`: the bucket's span, clipped to the domain.
    public static func binBounds(_ bin: UmPlusBin, domain: ClosedRange<Double>) -> ClosedRange<Double> {
        let half = 0.5 / Double(binsPerUnit)
        let center = Double(bin.index - binsPerUnit) / Double(binsPerUnit)
        let lower = max(domain.lowerBound, center - half)
        let upper = min(domain.upperBound, center + half)
        return lower...max(lower, upper)
    }

    /// `pointRadius`, in the add-on's 600-unit-wide graph.
    public static func pointRadius(_ bin: UmPlusBin, total: Int) -> Double {
        max(2.5, ((Double(bin.count) / Double(total)) * 1024 / Double.pi).squareRoot())
    }

    /// A line between neighbouring visible buckets, small when either is.
    public struct Segment: Sendable, Hashable {
        public let from: UmPlusBin
        public let to: UmPlusBin
        public let small: Bool
    }

    /// `d3.pairs(visibleBins)`.
    public static func segments(_ visibleBins: [UmPlusBin]) -> [Segment] {
        zip(visibleBins, visibleBins.dropFirst()).map { from, to in
            Segment(from: from, to: to, small: isSmall(from) || isSmall(to))
        }
    }

    /// The hover tooltip.
    public static func tooltip(_ bin: UmPlusBin, total: Int) -> [String] {
        [
            "FSRS − RWKV disagreement: \(signedPercent(bin.disagreement, digits: 1))",
            "FSRS prediction error: \(signedPercent(bin.fsrsError, digits: 1))",
            "RWKV prediction error: \(signedPercent(bin.rwkvError, digits: 1))",
            "Paired FSRS/RWKV reviews: \(bin.count) (\(JSNumber.toFixed(Double(bin.count) / Double(total) * 100, 1))% of paired reviews)",
        ]
    }
}
