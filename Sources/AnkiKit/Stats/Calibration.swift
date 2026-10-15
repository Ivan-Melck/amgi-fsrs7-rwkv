//
//  Calibration.swift
//  AnkiKit
//
//  The calibration graph (predicted vs actual recall for FSRS and RWKV)
//  that the Search Stats Extended add-on draws on the desktop: binning from
//  `MemorisedBar.ts` (`LossBin`, `buildCalibrationBins`), the graph's
//  geometry and tooltips from `FSRScalibration.ts`, and the FSRS / RWKV /
//  Both choice of `categories/FSRSCategory.svelte`. The bridge supplies the
//  samples and predictions (anki-bridge-rs/src/rwkv/calibration.rs).
//

import Foundation

/// `CalibrationSample`: a review the graph counts.
public struct CalibrationSample: Sendable, Hashable {
    public let revlogId: Int64
    public let cardId: Int64
    /// 1 when recalled (Hard or better), else 0.
    public let actual: Double

    public init(revlogId: Int64, cardId: Int64, actual: Double) {
        self.revlogId = revlogId
        self.cardId = cardId
        self.actual = actual
    }
}

/// `LossBin`: sums over a bin's reviews.
public struct LossBin: Sendable, Hashable {
    public var real: Double
    public var predicted: Double
    public var count: Int
    public var confidenceInterval: CalibrationInterval?

    public init(real: Double = 0, predicted: Double = 0, count: Int = 0, confidenceInterval: CalibrationInterval? = nil) {
        self.real = real
        self.predicted = predicted
        self.count = count
        self.confidenceInterval = confidenceInterval
    }
}

public enum Calibration {
    /// `CALIBRATION_BIN_COUNT`.
    public static let binCount = 20

    /// `isValidProbability`.
    static func isValidProbability(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value.isFinite && value >= 0 && value <= 1
    }

    /// `calibrationBinIndex`: bins widen logarithmically towards 0%.
    public static func binIndex(predicted: Double, binCount: Int = binCount) -> Int {
        let raw = (exp(log(Double(binCount + 1)) * predicted)).rounded(.down)
        return max(0, min(binCount - 1, Int(raw) - 1))
    }

    /// `addCalibrationSample`.
    @discardableResult
    public static func addSample(_ bins: inout [LossBin?], predicted: Double?, actual: Double) -> Bool {
        guard let predicted, isValidProbability(predicted), isValidProbability(actual) else {
            return false
        }
        let bin = binIndex(predicted: predicted, binCount: bins.isEmpty ? binCount : bins.count)
        while bins.count <= bin {
            bins.append(nil)
        }
        // `incrementLoss`.
        var loss = bins[bin] ?? LossBin()
        loss.predicted += predicted
        loss.real += actual
        loss.count += 1
        bins[bin] = loss
        return true
    }

    /// `buildCalibrationBins`: the samples with a valid prediction, binned,
    /// with card-bootstrap intervals.
    public static func buildBins(
        samples: [CalibrationSample],
        predictions: [Int64: Double],
        iterations: Int = CalibrationBootstrap.iterations
    ) -> [LossBin?] {
        var bins = [LossBin?](repeating: nil, count: binCount)
        var observations: [CalibrationBootstrapObservation] = []
        for sample in samples {
            let predicted = predictions[sample.revlogId]
            if addSample(&bins, predicted: predicted, actual: sample.actual), let predicted {
                observations.append(CalibrationBootstrapObservation(
                    cardId: sample.cardId,
                    bin: binIndex(predicted: predicted),
                    actual: sample.actual
                ))
            }
        }
        let intervals = CalibrationBootstrap.cardBootstrapConfidenceIntervals(
            observations,
            binCount: binCount,
            iterations: iterations
        )
        for bin in bins.indices where bins[bin] != nil {
            if let interval = intervals[bin] {
                bins[bin]?.confidenceInterval = interval
            }
        }
        return bins
    }

    /// Total reviews in `bins`.
    public static func count(_ bins: [LossBin?]) -> Int {
        bins.reduce(0) { $0 + ($1?.count ?? 0) }
    }

    /// `binWidth`: a bin's horizontal extent as predicted-recall fractions.
    public static func binBounds(index: Int, binCount: Int) -> ClosedRange<Double> {
        let scale = log(Double(binCount + 1))
        return (log(Double(index + 1)) / scale)...(log(Double(index + 2)) / scale)
    }

    /// `percentify`, the axes' labels.
    public static func percent(_ value: Double) -> String {
        "\(JSNumber.toFixed(value * 100, 0))%"
    }
}

/// A bin as the graph draws it (`normalizedData`): proportions.
public struct CalibrationPoint: Sendable, Hashable, Identifiable {
    public let index: Int
    public let predicted: Double
    public let real: Double
    public let count: Int
    public let confidenceInterval: CalibrationInterval?

    public var id: Int { index }

    public init(index: Int, bin: LossBin) {
        self.index = index
        predicted = bin.predicted / Double(bin.count)
        real = bin.real / Double(bin.count)
        count = bin.count
        confidenceInterval = bin.confidenceInterval
    }
}

/// The model a calibration series shows.
public enum CalibrationModel: String, Sendable, Hashable, CaseIterable {
    case fsrs
    case rwkv
}

/// `CalibrationSeries`.
public struct CalibrationSeries: Sendable, Hashable, Identifiable {
    public let model: CalibrationModel
    public let label: String
    public let bins: [LossBin?]

    public var id: CalibrationModel { model }

    public init(model: CalibrationModel, bins: [LossBin?]) {
        self.model = model
        // `calibration-legend-*`.
        label = model == .fsrs ? "Actual FSRS R" : "Actual RWKV R"
        self.bins = bins
    }

    /// The drawn points, by bin.
    public var points: [CalibrationPoint] {
        bins.enumerated().compactMap { index, bin in
            bin.map { CalibrationPoint(index: index, bin: $0) }
        }
    }

    /// The line's runs: `d3.line().defined()` breaks it at empty bins.
    public var segments: [[CalibrationPoint]] {
        var segments: [[CalibrationPoint]] = []
        var current: [CalibrationPoint] = []
        for (index, bin) in bins.enumerated() {
            if let bin {
                current.append(CalibrationPoint(index: index, bin: bin))
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }
}

/// `calibrationMode`: the source picker above the graph.
public enum CalibrationMode: String, Sendable, Hashable, CaseIterable {
    case fsrs
    case rwkv
    case both

    /// `calibration-source-*`.
    public var label: String {
        switch self {
        case .fsrs: "FSRS"
        case .rwkv: "RWKV"
        case .both: "Both"
        }
    }

    /// The graph's title (`fsrs-calibration` and friends).
    public var title: String {
        switch self {
        case .fsrs: "FSRS Calibration"
        case .rwkv: "RWKV Calibration"
        case .both: "FSRS + RWKV Calibration"
        }
    }

    /// Shown without data (`calibration-no-data` /
    /// `rwkv-calibration-no-data`).
    public var noDataMessage: String {
        switch self {
        case .fsrs:
            "Not enough eligible review history to draw calibration yet."
        case .rwkv, .both:
            "No complete persisted RWKV review retrievability state was found for this search and date range."
        }
    }
}

/// Everything the FSRS category's calibration and UM+ graphs need for one
/// search: the add-on's `fsrsCalibrationStats` and `rwkvCalibrationStats`.
public struct CalibrationReport: Sendable, Hashable {
    public let samples: [CalibrationSample]
    public let fsrsPredictions: [Int64: Double]
    public let rwkvPredictions: [Int64: Double]
    public let fsrsWarnings: [String]
    public let rwkvWarnings: [String]
    public let fsrsBins: [LossBin?]
    public let rwkvBins: [LossBin?]
    public let umPlus: UmPlusData

    /// Bins every source (with the bootstrap's 500 resamples); build it off
    /// the main thread.
    public init(
        samples: [CalibrationSample],
        fsrsPredictions: [Int64: Double],
        rwkvPredictions: [Int64: Double],
        fsrsWarnings: [String] = [],
        rwkvWarnings: [String] = []
    ) {
        self.samples = samples
        self.fsrsPredictions = fsrsPredictions
        self.rwkvPredictions = rwkvPredictions
        self.fsrsWarnings = fsrsWarnings
        self.rwkvWarnings = rwkvWarnings
        // The stores bin nothing without samples.
        fsrsBins = samples.isEmpty ? [] : Calibration.buildBins(samples: samples, predictions: fsrsPredictions)
        rwkvBins = samples.isEmpty ? [] : Calibration.buildBins(samples: samples, predictions: rwkvPredictions)
        umPlus = UmPlus.build(samples: samples, fsrsPredictions: fsrsPredictions, rwkvPredictions: rwkvPredictions)
    }

    /// `calibrationSeries` (the FSRS default when unset).
    public func series(for mode: CalibrationMode) -> [CalibrationSeries] {
        switch mode {
        case .fsrs: [CalibrationSeries(model: .fsrs, bins: fsrsBins)]
        case .rwkv: [CalibrationSeries(model: .rwkv, bins: rwkvBins)]
        case .both: [CalibrationSeries(model: .fsrs, bins: fsrsBins), CalibrationSeries(model: .rwkv, bins: rwkvBins)]
        }
    }

    /// `calibrationCount`: draw the graph only when positive.
    public func count(for mode: CalibrationMode) -> Int {
        series(for: mode).reduce(0) { $0 + Calibration.count($1.bins) }
    }

    /// `calibrationWarnings`.
    public func warnings(for mode: CalibrationMode) -> [String] {
        switch mode {
        case .fsrs: fsrsWarnings
        case .rwkv: rwkvWarnings
        case .both: fsrsWarnings + rwkvWarnings
        }
    }

    /// `umPlusWarnings`: both sources', each once.
    public var umPlusWarnings: [String] {
        var seen = Set<String>()
        return (fsrsWarnings + rwkvWarnings).filter { seen.insert($0).inserted }
    }

    /// The hover tooltip of bin `index` (`hoverData` and the `mouseover`
    /// lines); empty when no series has the bin.
    public static func tooltip(series: [CalibrationSeries], index: Int) -> [String] {
        let entries = series.compactMap { item -> (String, CalibrationPoint)? in
            guard index < item.bins.count, let bin = item.bins[index] else { return nil }
            return (item.label, CalibrationPoint(index: index, bin: bin))
        }
        func interval(_ point: CalibrationPoint) -> [String] {
            guard let ci = point.confidenceInterval else { return [] }
            // `calibration-confidence-interval`.
            return ["Card bootstrap 95% CI: \(JSNumber.toFixed(ci.lower * 100, 1))%–\(JSNumber.toFixed(ci.upper * 100, 1))%"]
        }
        if entries.count == 1, let (_, point) = entries.first {
            return [
                "Predicted \(JSNumber.toFixed(point.predicted * 100, 1))%:",
                "Actual: \(JSNumber.toFixed(point.real * 100, 1))%",
            ] + interval(point) + ["Count: \(point.count)"]
        }
        return entries.flatMap { label, point in
            [
                "\(label): \(JSNumber.toFixed(point.predicted * 100, 1))% Predicted",
                "Actual: \(JSNumber.toFixed(point.real * 100, 1))%, Count: \(point.count)",
            ] + interval(point)
        }
    }
}
