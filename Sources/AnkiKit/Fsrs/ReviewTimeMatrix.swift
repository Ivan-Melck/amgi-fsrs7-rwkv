//
//  ReviewTimeMatrix.swift
//  AnkiKit
//
//  The workload simulator's answer-time breakdown: the response fields
//  (`SimulateFsrsWorkloadResponse.review_time_*`), a port of the fork
//  desktop's ts/routes/deck-options/review-time-matrix.ts, and the derived
//  values SimulatorModal.svelte shows.
//

import Foundation

/// The answer-time model a workload simulation used. Matrices are row-major
/// by retrievability bucket (5% bands, highest first) then stability bucket.
public struct FsrsReviewTime: Sendable, Hashable {
    public var rBucketCount: Int
    public var sBucketCount: Int
    public var againSeconds: [Float]
    public var hardSeconds: [Float]
    public var goodSeconds: [Float]
    public var easySeconds: [Float]
    public var sampleCounts: [Int]
    /// `time = a + b * (1 - R) + c * S + d * reps + e * D`, as `[a, b, c, d, e]`.
    public var againCoeffs: [Float]
    public var hardCoeffs: [Float]
    public var goodCoeffs: [Float]
    public var easyCoeffs: [Float]
    /// Again, Hard, Good, Easy shares.
    public var gradeWeights: [Float]
    /// Previous grade by next grade, row-major (4 x 4).
    public var transitionProbs: [Float]
    public var transitionCounts: [Int]
    /// Hard, Good, Easy shares of successes per R bucket (R x 3).
    public var successGradeProbs: [Float]
    public var successGradeCounts: [Int]

    public init(
        rBucketCount: Int = 0,
        sBucketCount: Int = 0,
        againSeconds: [Float] = [],
        hardSeconds: [Float] = [],
        goodSeconds: [Float] = [],
        easySeconds: [Float] = [],
        sampleCounts: [Int] = [],
        againCoeffs: [Float] = [],
        hardCoeffs: [Float] = [],
        goodCoeffs: [Float] = [],
        easyCoeffs: [Float] = [],
        gradeWeights: [Float] = [],
        transitionProbs: [Float] = [],
        transitionCounts: [Int] = [],
        successGradeProbs: [Float] = [],
        successGradeCounts: [Int] = []
    ) {
        self.rBucketCount = rBucketCount
        self.sBucketCount = sBucketCount
        self.againSeconds = againSeconds
        self.hardSeconds = hardSeconds
        self.goodSeconds = goodSeconds
        self.easySeconds = easySeconds
        self.sampleCounts = sampleCounts
        self.againCoeffs = againCoeffs
        self.hardCoeffs = hardCoeffs
        self.goodCoeffs = goodCoeffs
        self.easyCoeffs = easyCoeffs
        self.gradeWeights = gradeWeights
        self.transitionProbs = transitionProbs
        self.transitionCounts = transitionCounts
        self.successGradeProbs = successGradeProbs
        self.successGradeCounts = successGradeCounts
    }
}

// MARK: - review-time-matrix.ts

public enum ReviewTimeMatrix {
    /// `matrixCellIndex`.
    public static func cellIndex(rIndex: Int, sIndex: Int, sBucketCount: Int) -> Int {
        rIndex * sBucketCount + sIndex
    }

    /// `matrixCellValue`: 0 outside the array.
    public static func cellValue(_ values: [Double], rIndex: Int, sIndex: Int, sBucketCount: Int) -> Double {
        element(values, cellIndex(rIndex: rIndex, sIndex: sIndex, sBucketCount: sBucketCount)) ?? 0
    }

    /// `rBucketLabel`: 5% bands, highest first.
    public static func rBucketLabel(_ index: Int) -> String {
        let upper = 100 - index * 5
        let lower = max(0, upper - 5)
        return "\(lower)-\(upper)%"
    }

    /// `sBucketBounds`: log-spaced stability bounds.
    public static func sBucketBounds(
        _ index: Int,
        sBucketCount: Int,
        min: Double = 0.001,
        max: Double = 36500
    ) -> (lower: Double, upper: Double) {
        let ratioLo = Double(index) / Double(sBucketCount)
        let ratioHi = Double(index + 1) / Double(sBucketCount)
        let logMin = Foundation.log(min)
        let logMax = Foundation.log(max)
        let lo = exp(logMin + (logMax - logMin) * ratioLo)
        let hi = exp(logMin + (logMax - logMin) * ratioHi)
        return (lo, hi)
    }

    /// `sBucketLabel`.
    public static func sBucketLabel(_ index: Int, sBucketCount: Int) -> String {
        if sBucketCount <= 1 {
            return "All S"
        }
        let (lo, hi) = sBucketBounds(index, sBucketCount: sBucketCount)
        return "\(JSNumberFormat.toPrecision(lo, 2))-\(JSNumberFormat.toPrecision(hi, 2))"
    }

    /// `buildSLineSeries`: one line per S bucket, over the R buckets.
    public static func sLineSeries(_ values: [Double], rBucketCount: Int, sBucketCount: Int) -> [[Double]] {
        (0..<max(0, sBucketCount)).map { sIndex in
            (0..<max(0, rBucketCount)).map { rIndex in
                cellValue(values, rIndex: rIndex, sIndex: sIndex, sBucketCount: sBucketCount)
            }
        }
    }

    /// `buildFailPassRatioSeries`: fail / pass per cell, 0 when pass is 0.
    public static func failPassRatioSeries(
        fail: [Double],
        pass: [Double],
        rBucketCount: Int,
        sBucketCount: Int
    ) -> [[Double]] {
        let ratios = fail.enumerated().map { index, failValue in
            let passValue = element(pass, index) ?? 0
            // JS truthiness: 0 and NaN are false.
            return passValue != 0 && !passValue.isNaN ? failValue / passValue : 0
        }
        return sLineSeries(ratios, rBucketCount: rBucketCount, sBucketCount: sBucketCount)
    }

    /// `seriesMinMax`: [0, 1] when empty or not finite, widened by 1 when flat.
    public static func seriesMinMax(_ series: [[Double]]) -> (min: Double, max: Double) {
        var minValue = Double.infinity
        var maxValue = -Double.infinity
        for value in series.joined() {
            // Math.min / Math.max propagate NaN.
            if value.isNaN || minValue.isNaN {
                minValue = .nan
                maxValue = .nan
                continue
            }
            minValue = Swift.min(minValue, value)
            maxValue = Swift.max(maxValue, value)
        }
        if !minValue.isFinite || !maxValue.isFinite {
            return (0, 1)
        }
        if minValue == maxValue {
            return (Swift.max(0, minValue - 1), maxValue + 1)
        }
        return (minValue, maxValue)
    }

    /// `median`; 0 when empty.
    public static func median(_ values: [Double]) -> Double {
        if values.isEmpty {
            return 0
        }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// `values[index] ?? fallback`.
    static func element<T>(_ values: [T], _ index: Int) -> T? {
        values.indices.contains(index) ? values[index] : nil
    }
}

// MARK: - SimulatorModal.svelte

extension FsrsReviewTime {
    /// `HELP_ME_DECIDE_TRANSITION_BLEND_ALPHA_DEFAULT`, which the simulator
    /// request always sends.
    public static let defaultTransitionBlendAlpha: Double = 0

    public enum Grade: Int, CaseIterable, Sendable {
        case again, hard, good, easy

        /// `gradeLabel`.
        public var label: String { ["Again", "Hard", "Good", "Easy"][rawValue] }
    }

    /// The per-grade seconds matrix.
    public func seconds(_ grade: Grade) -> [Double] {
        let values: [Float] = switch grade {
        case .again: againSeconds
        case .hard: hardSeconds
        case .good: goodSeconds
        case .easy: easySeconds
        }
        return values.map(Double.init)
    }

    /// The per-grade `[a, b, c, d, e]`.
    public func coeffs(_ grade: Grade) -> [Double] {
        let values: [Float] = switch grade {
        case .again: againCoeffs
        case .hard: hardCoeffs
        case .good: goodCoeffs
        case .easy: easyCoeffs
        }
        return values.map(Double.init)
    }

    /// `coeff`: `(values[index] ?? 0).toFixed(4)`.
    public func coeffText(_ grade: Grade, _ index: Int) -> String {
        JSNumberFormat.toFixed(ReviewTimeMatrix.element(coeffs(grade), index) ?? 0, 4)
    }

    /// `(reviewTimeGradeWeights[index] ?? 0).toFixed(3)`.
    public func gradeWeightText(_ grade: Grade) -> String {
        JSNumberFormat.toFixed(gradeWeight(grade.rawValue) ?? 0, 3)
    }

    public func cellSeconds(_ grade: Grade, rIndex: Int, sIndex: Int) -> Double {
        ReviewTimeMatrix.cellValue(seconds(grade), rIndex: rIndex, sIndex: sIndex, sBucketCount: sBucketCount)
    }

    public func cellSampleCount(rIndex: Int, sIndex: Int) -> Int {
        ReviewTimeMatrix.element(
            sampleCounts,
            ReviewTimeMatrix.cellIndex(rIndex: rIndex, sIndex: sIndex, sBucketCount: sBucketCount)
        ) ?? 0
    }

    /// `reviewTimeSampleMedian`; a cell's count shows as high above it.
    public var sampleMedian: Double {
        ReviewTimeMatrix.median(sampleCounts.map(Double.init))
    }

    /// `transitionProb`.
    public func transitionProb(from: Int, to: Int) -> Double {
        ReviewTimeMatrix.element(transitionProbs, from * 4 + to).map(Double.init) ?? 0
    }

    /// `transitionCount`.
    public func transitionCount(from: Int, to: Int) -> Int {
        ReviewTimeMatrix.element(transitionCounts, from * 4 + to) ?? 0
    }

    /// `successGradeProb`: 0 = Hard, 1 = Good, 2 = Easy.
    public func successGradeProb(rIndex: Int, successGrade: Int) -> Double {
        ReviewTimeMatrix.element(successGradeProbs, rIndex * 3 + successGrade).map(Double.init) ?? 0
    }

    /// `successGradeCount`.
    public func successGradeCount(rIndex: Int) -> Int {
        ReviewTimeMatrix.element(successGradeCounts, rIndex) ?? 0
    }

    private func gradeWeight(_ index: Int) -> Double? {
        ReviewTimeMatrix.element(gradeWeights, index).map(Double.init)
    }

    /// `transitionSuccessPrior`: the overall Hard/Good/Easy shares.
    public func transitionSuccessPrior(_ successGrade: Int) -> Double {
        let again = min(1, max(0, gradeWeight(0) ?? 0.25))
        let successMass = max(1e-6, 1 - again)
        let hard = (gradeWeight(1) ?? 0.25) / successMass
        let good = (gradeWeight(2) ?? 0.25) / successMass
        let easy = (gradeWeight(3) ?? 0.25) / successMass
        let vals = [hard, good, easy]
        let sum = max(1e-6, vals[0] + vals[1] + vals[2])
        return vals[successGrade] / sum
    }

    /// `blendedSuccessGradeProb`: the bucket's success shares blended
    /// geometrically with the overall ones.
    public func blendedSuccessGradeProb(
        rIndex: Int,
        successGrade: Int,
        alpha: Double = defaultTransitionBlendAlpha
    ) -> Double {
        let alpha = min(1, max(0, alpha))
        // `value || 1 / 3`: 0 and NaN fall back.
        func orThird(_ value: Double) -> Double { value == 0 || value.isNaN ? 1.0 / 3.0 : value }
        let scores = (0..<3).map { grade in
            pow(max(1e-6, orThird(successGradeProb(rIndex: rIndex, successGrade: grade))), 1 - alpha)
                * pow(max(1e-6, orThird(transitionSuccessPrior(grade))), alpha)
        }
        let sum = max(1e-6, scores[0] + scores[1] + scores[2])
        return scores[successGrade] / sum
    }

    /// `finalGradeProb`: Again at the bucket's midpoint, then its successes.
    public func finalGradeProb(rIndex: Int, grade: Int, alpha: Double = defaultTransitionBlendAlpha) -> Double {
        let again = 1 - Self.bucketRetrievability(rIndex)
        if grade == 0 {
            return again
        }
        let successMass = max(0, 1 - again)
        return successMass * blendedSuccessGradeProb(rIndex: rIndex, successGrade: grade - 1, alpha: alpha)
    }

    /// `bucketRetrievability`: the midpoint of the 5% bucket.
    public static func bucketRetrievability(_ rIndex: Int) -> Double {
        max(0, min(1, 1 - (Double(rIndex) * 0.05 + 0.025)))
    }

    /// `formatSeconds`.
    public static func secondsText(_ seconds: Double) -> String {
        "\(JSNumberFormat.toFixed(seconds, 1))s"
    }

    /// `(probability * 100).toFixed(1)%`.
    public static func percentText(_ probability: Double) -> String {
        "\(JSNumberFormat.toFixed(probability * 100, 1))%"
    }
}

// MARK: - Graph

/// The desktop's answer-time graph: per S bucket, one line per grade plus
/// the grade-weighted average, over the R buckets.
public struct ReviewTimeGraph: Sendable, Hashable {
    public enum Kind: String, CaseIterable, Sendable {
        case again, hard, good, easy, weighted

        /// The grade whose seconds the line shows; nil for the average.
        public var grade: FsrsReviewTime.Grade? {
            switch self {
            case .again: .again
            case .hard: .hard
            case .good: .good
            case .easy: .easy
            case .weighted: nil
            }
        }

        /// The desktop's legend text.
        public var legend: String {
            switch self {
            case .again: "Again time"
            case .hard: "Hard time"
            case .good: "Good time"
            case .easy: "Easy time"
            case .weighted: "Weighted average time"
            }
        }
    }

    public struct Line: Sendable, Hashable {
        public let sIndex: Int
        public let kind: Kind
        /// Seconds per R bucket.
        public let values: [Double]
    }

    public struct XTick: Sendable, Hashable {
        public let rIndex: Int
        public let label: String
    }

    public let lines: [Line]
    public let yMin: Double
    public let yMax: Double
    public let xTicks: [XTick]
    public let yTicks: [Double]
}

extension FsrsReviewTime {
    /// The `$: if (reviewTimeMatrix)` block of SimulatorModal.svelte.
    public func graph(alpha: Double = defaultTransitionBlendAlpha) -> ReviewTimeGraph {
        let lines = Grade.allCases.map {
            ReviewTimeMatrix.sLineSeries(seconds($0), rBucketCount: rBucketCount, sBucketCount: sBucketCount)
        }
        let weighted = lines[0].indices.map { sIndex in
            lines[0][sIndex].indices.map { rIndex in
                Grade.allCases.reduce(0.0) { total, grade in
                    total + finalGradeProb(rIndex: rIndex, grade: grade.rawValue, alpha: alpha)
                        * lines[grade.rawValue][sIndex][rIndex]
                }
            }
        }
        let yMin = 0.0
        let yMax = ([60.0] + (lines + [weighted]).map { ReviewTimeMatrix.seriesMinMax($0).max }).max() ?? 60

        var graphLines: [ReviewTimeGraph.Line] = []
        for sIndex in 0..<max(0, sBucketCount) {
            for kind in ReviewTimeGraph.Kind.allCases {
                let series = kind.grade.map { lines[$0.rawValue] } ?? weighted
                graphLines.append(.init(sIndex: sIndex, kind: kind, values: series[sIndex]))
            }
        }

        let xTickStep = max(1, rBucketCount / 6)
        let xTicks = (0..<max(0, rBucketCount))
            .filter { $0 % xTickStep == 0 || $0 == rBucketCount - 1 }
            .map { ReviewTimeGraph.XTick(rIndex: $0, label: ReviewTimeMatrix.rBucketLabel($0)) }
        let yTicks = (0..<5).map { yMin + Double($0) / 4 * (yMax - yMin) }
        return ReviewTimeGraph(lines: graphLines, yMin: yMin, yMax: yMax, xTicks: xTicks, yTicks: yTicks)
    }
}
