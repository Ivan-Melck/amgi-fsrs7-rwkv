//
//  CalibrationTests.swift
//  AnkiKitTests
//
//  The Search Stats Extended add-on's calibration tests
//  (`calibrationBootstrap.test.ts`, the calibration cases of
//  `memorised.test.ts`), plus values its TypeScript computes for a fixed
//  dataset, so the graph matches the desktop's.
//

import Testing
@testable import AnkiKit

@Suite struct CalibrationBootstrapTests {
    @Test func card_bootstrap_keeps_reviews_from_the_same_card_clustered() {
        let observations =
            Array(repeating: CalibrationBootstrapObservation(cardId: 1, bin: 0, actual: 1), count: 10)
            + Array(repeating: CalibrationBootstrapObservation(cardId: 2, bin: 0, actual: 0), count: 10)

        let intervals = CalibrationBootstrap.cardBootstrapConfidenceIntervals(observations, binCount: 1, iterations: 1_000)

        #expect(intervals[0] == CalibrationInterval(lower: 0, upper: 1))
    }

    @Test func card_bootstrap_is_deterministic_for_stable_graph_rendering() {
        let observations = [
            CalibrationBootstrapObservation(cardId: 1, bin: 0, actual: 1),
            CalibrationBootstrapObservation(cardId: 2, bin: 0, actual: 0),
            CalibrationBootstrapObservation(cardId: 3, bin: 0, actual: 1),
        ]

        #expect(
            CalibrationBootstrap.cardBootstrapConfidenceIntervals(observations, binCount: 1, iterations: 100)
                == CalibrationBootstrap.cardBootstrapConfidenceIntervals(observations, binCount: 1, iterations: 100)
        )
    }

    @Test func card_bootstrap_returns_sparse_intervals_for_populated_bins() {
        let intervals = CalibrationBootstrap.cardBootstrapConfidenceIntervals(
            [
                CalibrationBootstrapObservation(cardId: 1, bin: 1, actual: 1),
                CalibrationBootstrapObservation(cardId: 2, bin: 1, actual: 0),
            ],
            binCount: 3,
            iterations: 100
        )

        #expect(intervals[0] == nil)
        #expect(intervals[1] == CalibrationInterval(lower: 0, upper: 1))
        #expect(intervals[2] == nil)
    }

    @Test func no_observations_or_iterations_give_no_intervals() {
        #expect(CalibrationBootstrap.cardBootstrapConfidenceIntervals([], binCount: 2) == [nil, nil])
        let one = [CalibrationBootstrapObservation(cardId: 1, bin: 0, actual: 1)]
        #expect(CalibrationBootstrap.cardBootstrapConfidenceIntervals(one, binCount: 1, iterations: 0) == [nil])
    }

    @Test func seeded_generator_matches_javascript() {
        // `seededRandom(0x5f3759df)` in the add-on (V8).
        var random = CalibrationBootstrap.SeededRandom(seed: CalibrationBootstrap.seed)
        #expect(random.next() == 0.8006246744189411)
        #expect(random.next() == 0.06993603962473571)
        #expect(random.next() == 0.6627159540075809)
    }
}

@Suite struct CalibrationBinsTests {
    @Test func alternate_calibration_bins_ignore_missing_and_invalid_predictions() {
        let bins = Calibration.buildBins(
            samples: [
                CalibrationSample(revlogId: 1, cardId: 1, actual: 1),
                CalibrationSample(revlogId: 2, cardId: 2, actual: 0),
                CalibrationSample(revlogId: 3, cardId: 3, actual: 1),
            ],
            predictions: [1: 0.25, 2: 1.5]
        )
        let entries = bins.compactMap { $0 }.filter { $0.count > 0 }

        #expect(entries.count == 1)
        #expect(entries[0].count == 1)
        #expect(abs(entries[0].predicted - 0.25) < 1e-6)
        #expect(entries[0].real == 1)
    }

    @Test func calibration_samples_can_be_reused_with_alternate_predictions() {
        let samples = [CalibrationSample(revlogId: 2, cardId: 0, actual: 1)]
        let rwkv = Calibration.buildBins(samples: samples, predictions: [2: 0.42])
        let entry = rwkv.compactMap { $0 }.first { $0.count > 0 }

        #expect(entry?.count == 1)
        #expect(abs((entry?.predicted ?? 0) - 0.42) < 1e-6)
        #expect(entry?.real == 1)
    }

    @Test func bins_widen_logarithmically() {
        #expect(Calibration.binIndex(predicted: 0) == 0)
        #expect(Calibration.binIndex(predicted: 1) == 19)
        // e^(ln 21 · p) - 1 crosses 1 at p = ln 2 / ln 21.
        #expect(Calibration.binIndex(predicted: 0.2276) == 0)
        #expect(Calibration.binIndex(predicted: 0.2277) == 1)
        let bounds = Calibration.binBounds(index: 0, binCount: 20)
        #expect(bounds.lowerBound == 0)
        #expect(abs(bounds.upperBound - 0.22767) < 1e-5)
        #expect(Calibration.binBounds(index: 19, binCount: 20).upperBound == 1)
    }

    /// The add-on's TypeScript on 60 cards with 1–4 reviews each.
    @Test func bins_and_intervals_match_the_add_on() {
        var samples: [CalibrationSample] = []
        var predictions: [Int64: Double] = [:]
        var id: Int64 = 1
        for card in 0..<60 {
            for k in 0..<(1 + card % 4) {
                samples.append(CalibrationSample(
                    revlogId: id,
                    cardId: Int64(1000 + card),
                    actual: (card * 7 + k * 3) % 10 < 7 ? 1 : 0
                ))
                predictions[id] = Double((card * 37 + k * 11) % 100) / 100
                id += 1
            }
        }
        let bins = Calibration.buildBins(samples: samples, predictions: predictions)
        let expected: [(Double, Double, Int, Double, Double)] = [
            (4.26, 25, 33, 0.6106942496493689, 0.8823529411764706),
            (7.7600000000000025, 18, 26, 0.5249999999999999, 0.8393870967741935),
            (4.549999999999999, 8, 11, 0.4361111111111111, 1),
            (3.86, 5, 8, 0.25, 1),
            (3.9299999999999997, 5, 7, 0.3333333333333333, 1),
            (3.6599999999999997, 5, 6, 0.5, 1),
            (4.63, 4, 7, 0.16666666666666666, 1),
            (6.349999999999999, 7, 9, 0.48250000000000004, 1),
            (2.93, 3, 4, 0, 1),
            (5.35, 4, 7, 0.18250000000000005, 1),
            (5.63, 7, 7, 1, 1),
            (4.1899999999999995, 4, 5, 0.3333333333333333, 1),
            (1.7, 1, 2, 0, 1),
            (4.39, 3, 5, 0, 1),
            (0.91, 1, 1, 1, 1),
            (3.68, 3, 4, 0.04500000000000029, 1),
            (0.94, 1, 1, 1, 1),
            (3.83, 3, 4, 0, 1),
            (1.96, 1, 2, 0, 1),
            (0.99, 0, 1, 0, 0),
        ]
        #expect(bins.count == 20)
        for (bin, want) in zip(bins, expected) {
            #expect(bin?.predicted == want.0)
            #expect(bin?.real == want.1)
            #expect(bin?.count == want.2)
            #expect(bin?.confidenceInterval == CalibrationInterval(lower: want.3, upper: want.4))
        }
    }
}

@Suite struct CalibrationReportTests {
    private func report() -> CalibrationReport {
        CalibrationReport(
            samples: [
                CalibrationSample(revlogId: 1, cardId: 1, actual: 1),
                CalibrationSample(revlogId: 2, cardId: 2, actual: 0),
                CalibrationSample(revlogId: 3, cardId: 2, actual: 1),
            ],
            fsrsPredictions: [1: 0.9, 2: 0.8, 3: 0.05],
            rwkvPredictions: [1: 0.95],
            fsrsWarnings: ["a"],
            rwkvWarnings: ["a", "b"]
        )
    }

    @Test func modes_pick_their_series_titles_and_counts() {
        let report = report()
        #expect(report.series(for: .fsrs).map(\.label) == ["Actual FSRS R"])
        #expect(report.series(for: .rwkv).map(\.label) == ["Actual RWKV R"])
        #expect(report.series(for: .both).map(\.model) == [.fsrs, .rwkv])
        #expect(report.count(for: .fsrs) == 3)
        #expect(report.count(for: .rwkv) == 1)
        #expect(report.count(for: .both) == 4)
        #expect(CalibrationMode.both.title == "FSRS + RWKV Calibration")
        #expect(CalibrationMode.fsrs.noDataMessage.hasPrefix("Not enough"))
        #expect(CalibrationMode.both.noDataMessage.hasPrefix("No complete persisted RWKV"))
        #expect(report.warnings(for: .both) == ["a", "a", "b"])
        #expect(report.umPlusWarnings == ["a", "b"])
        #expect(report.umPlus.count == 1)
    }

    @Test func no_samples_bin_nothing() {
        let empty = CalibrationReport(samples: [], fsrsPredictions: [1: 0.5], rwkvPredictions: [:])
        #expect(empty.fsrsBins.isEmpty)
        #expect(empty.count(for: .both) == 0)
    }

    @Test func lines_break_at_empty_bins() {
        let series = CalibrationSeries(model: .fsrs, bins: [
            LossBin(real: 1, predicted: 0.1, count: 1), nil,
            LossBin(real: 1, predicted: 0.5, count: 1), LossBin(real: 2, predicted: 1.2, count: 2),
        ])
        #expect(series.segments.map { $0.map(\.index) } == [[0], [2, 3]])
        #expect(series.points.map(\.predicted) == [0.1, 0.5, 0.6])
    }

    @Test func tooltips_match_the_add_on() {
        let fsrs = CalibrationSeries(model: .fsrs, bins: [
            LossBin(real: 80, predicted: 75, count: 100, confidenceInterval: CalibrationInterval(lower: 0.7125, upper: 0.875)),
        ])
        #expect(CalibrationReport.tooltip(series: [fsrs], index: 0) == [
            "Predicted 75.0%:",
            "Actual: 80.0%",
            "Card bootstrap 95% CI: 71.3%–87.5%",
            "Count: 100",
        ])
        let rwkv = CalibrationSeries(model: .rwkv, bins: [LossBin(real: 1, predicted: 0.5, count: 2)])
        #expect(CalibrationReport.tooltip(series: [fsrs, rwkv], index: 0) == [
            "Actual FSRS R: 75.0% Predicted",
            "Actual: 80.0%, Count: 100",
            "Card bootstrap 95% CI: 71.3%–87.5%",
            "Actual RWKV R: 25.0% Predicted",
            "Actual: 50.0%, Count: 2",
        ])
        #expect(CalibrationReport.tooltip(series: [rwkv], index: 3).isEmpty)
        #expect(Calibration.percent(0.3) == "30%")
    }
}

@Suite struct JSNumberTests {
    @Test func to_fixed_rounds_the_exact_value_half_up() {
        // Values from V8.
        let cases: [(Double, [String])] = [
            (6.25, ["6.3", "6.25", "6"]),
            (0.125, ["0.1", "0.13", "0"]),
            (-0.04, ["-0.0", "-0.04", "-0"]),
            (1.005, ["1.0", "1.00", "1"]),
            (2.5, ["2.5", "2.50", "3"]),
            (12.345, ["12.3", "12.35", "12"]),
        ]
        for (value, expected) in cases {
            #expect([JSNumber.toFixed(value, 1), JSNumber.toFixed(value, 2), JSNumber.toFixed(value, 0)] == expected)
        }
        #expect(JSNumber.toFixed(99.96, 1) == "100.0")
        #expect(JSNumber.toFixed(0, 4) == "0.0000")
    }

    @Test func round_takes_halves_towards_positive_infinity() {
        #expect([-2.5, 2.5, -0.5, 0.49999999999999994, -1.5].map(JSNumber.round) == [-2, 3, 0, 0, -1])
    }
}
