//
//  CalibrationBootstrap.swift
//  AnkiKit
//
//  The calibration graph's confidence intervals: a port of the Search
//  Stats Extended add-on's `calibrationBootstrap.ts`, which draws them on
//  the desktop. Reviews of one card are resampled together, with the
//  add-on's seeded generator, so the intervals match the desktop's.
//

/// A 95% interval for a bin's actual recall, as proportions.
public struct CalibrationInterval: Sendable, Hashable {
    public let lower: Double
    public let upper: Double

    public init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }
}

/// `CalibrationBootstrapObservation`.
public struct CalibrationBootstrapObservation: Sendable, Hashable {
    public let cardId: Int64
    public let bin: Int
    public let actual: Double

    public init(cardId: Int64, bin: Int, actual: Double) {
        self.cardId = cardId
        self.bin = bin
        self.actual = actual
    }
}

public enum CalibrationBootstrap {
    /// `CALIBRATION_BOOTSTRAP_ITERATIONS`.
    public static let iterations = 500
    /// `BOOTSTRAP_SEED`.
    public static let seed: UInt32 = 0x5f37_59df
    static let lowerPercentile = 0.025
    static let upperPercentile = 0.975

    /// `seededRandom` (mulberry32), in the 32-bit arithmetic of
    /// `Math.imul` and `>>>`.
    struct SeededRandom {
        var state: UInt32

        init(seed: UInt32) {
            state = seed
        }

        mutating func next() -> Double {
            state = state &+ 0x6d2b_79f5
            var value = state
            value = (value ^ (value >> 15)) &* (value | 1)
            value ^= value &+ ((value ^ (value >> 7)) &* (value | 61))
            return Double(value ^ (value >> 14)) / 4_294_967_296
        }
    }

    /// `quantileSorted`.
    static func quantileSorted(_ values: [Double], _ percentile: Double) -> Double {
        let position = Double(values.count - 1) * percentile
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        let weight = position - Double(lowerIndex)
        return values[lowerIndex] * (1 - weight) + values[upperIndex] * weight
    }

    private struct Contribution {
        let bin: Int
        var successes: Double
        var count: Double
    }

    /// `cardBootstrapConfidenceIntervals`: one interval per bin, nil for
    /// bins without observations.
    public static func cardBootstrapConfidenceIntervals(
        _ observations: [CalibrationBootstrapObservation],
        binCount: Int,
        iterations: Int = iterations,
        seed: UInt32 = seed
    ) -> [CalibrationInterval?] {
        // Cards, and each card's bins, in first-seen order like the add-on's
        // Maps.
        var cardIndex: [Int64: Int] = [:]
        var cards: [[Contribution]] = []
        for observation in observations {
            let index: Int
            if let existing = cardIndex[observation.cardId] {
                index = existing
            } else {
                index = cards.count
                cardIndex[observation.cardId] = index
                cards.append([])
            }
            if let bin = cards[index].firstIndex(where: { $0.bin == observation.bin }) {
                cards[index][bin].successes += observation.actual
                cards[index][bin].count += 1
            } else {
                cards[index].append(Contribution(bin: observation.bin, successes: observation.actual, count: 1))
            }
        }

        guard !cards.isEmpty, iterations > 0 else {
            return Array(repeating: nil, count: binCount)
        }

        var estimates = Array(repeating: [Double](), count: binCount)
        var random = SeededRandom(seed: seed)
        for _ in 0..<iterations {
            var successes = Array(repeating: 0.0, count: binCount)
            var counts = Array(repeating: 0.0, count: binCount)
            for _ in 0..<cards.count {
                let card = cards[Int((random.next() * Double(cards.count)).rounded(.down))]
                for contribution in card {
                    successes[contribution.bin] += contribution.successes
                    counts[contribution.bin] += contribution.count
                }
            }
            for bin in 0..<binCount where counts[bin] > 0 {
                estimates[bin].append(successes[bin] / counts[bin])
            }
        }

        return estimates.map { values in
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return CalibrationInterval(
                lower: quantileSorted(sorted, lowerPercentile),
                upper: quantileSorted(sorted, upperPercentile)
            )
        }
    }
}
