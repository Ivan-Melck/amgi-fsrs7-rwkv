//
//  UmPlusTests.swift
//  AnkiKitTests
//
//  The Search Stats Extended add-on's `umPlus.test.ts`, and the parts of
//  `umPlusGraph.test.ts` that don't depend on SVG.
//

import Testing
@testable import AnkiKit

@Suite struct UmPlusDataTests {
    private func groupedSamples(_ count: Int, recalled: Int, firstRevlogId: Int64) -> [CalibrationSample] {
        (0..<count).map { index in
            CalibrationSample(
                revlogId: firstRevlogId + Int64(index),
                cardId: firstRevlogId + Int64(index),
                actual: index < recalled ? 1 : 0
            )
        }
    }

    private func close(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 0.005
    }

    @Test func groups_paired_reviews_by_model_disagreement() {
        let lowerFsrs = groupedSamples(10, recalled: 5, firstRevlogId: 1)
        let higherFsrs = groupedSamples(10, recalled: 8, firstRevlogId: 11)
        var fsrs: [Int64: Double] = [:]
        var rwkv: [Int64: Double] = [:]
        for sample in lowerFsrs {
            fsrs[sample.revlogId] = 0.5
            rwkv[sample.revlogId] = 0.7
        }
        for sample in higherFsrs {
            fsrs[sample.revlogId] = 0.8
            rwkv[sample.revlogId] = 0.6
        }

        let data = UmPlus.build(samples: lowerFsrs + higherFsrs, fsrsPredictions: fsrs, rwkvPredictions: rwkv)

        #expect(data.count == 20)
        #expect(data.bins.count == 2)
        #expect(data.bins[0].count == 10)
        #expect(close(data.bins[0].disagreement, -0.2))
        #expect(close(data.bins[0].fsrsError, 0))
        #expect(close(data.bins[0].rwkvError, 0.2))
        #expect(close(data.bins[1].disagreement, 0.2))
        #expect(close(data.bins[1].fsrsError, 0))
        #expect(close(data.bins[1].rwkvError, -0.2))
        #expect(close(data.fsrsScore, 0))
        #expect(close(data.rwkvScore, 0.2))
    }

    @Test func includes_only_reviews_with_valid_paired_predictions() {
        let data = UmPlus.build(
            samples: [
                CalibrationSample(revlogId: 1, cardId: 1, actual: 1),
                CalibrationSample(revlogId: 2, cardId: 2, actual: 0),
                CalibrationSample(revlogId: 3, cardId: 3, actual: 1),
            ],
            fsrsPredictions: [1: 0.8, 2: 0.5, 3: 1.2],
            rwkvPredictions: [1: 0.6, 3: 0.4]
        )

        #expect(data.count == 1)
        #expect(data.bins.count == 1)
        #expect(close(data.bins[0].disagreement, 0.2))
    }

    @Test func paired_bin_errors_differ_by_the_bin_disagreement() {
        let samples = groupedSamples(4, recalled: 3, firstRevlogId: 1)
        let data = UmPlus.build(
            samples: samples,
            fsrsPredictions: [1: 0.9, 2: 0.8, 3: 0.7, 4: 0.8],
            rwkvPredictions: [1: 0.7, 2: 0.6, 3: 0.5, 4: 0.6]
        )

        #expect(data.bins.count == 1)
        let bin = data.bins[0]
        #expect(close(bin.fsrsError - bin.rwkvError, bin.disagreement))
    }

    @Test func disagreement_domain_rounds_observed_values_outward_to_10_percent() {
        #expect(UmPlus.disagreementDomain([
            UmPlusBin(index: 15, disagreement: -0.23, fsrsError: 0, rwkvError: 0, count: 1),
            UmPlusBin(index: 23, disagreement: 0.17, fsrsError: 0, rwkvError: 0, count: 1),
        ]) == -0.3...0.2)
    }

    @Test func disagreement_domain_expands_a_single_rounded_value() {
        #expect(UmPlus.disagreementDomain([
            UmPlusBin(index: 24, disagreement: 0.2, fsrsError: 0, rwkvError: 0, count: 1),
        ]) == 0.1...0.3)
    }

    @Test func error_domain_covers_both_models_and_rounds_outward() {
        #expect(UmPlus.errorDomain([
            UmPlusBin(index: 16, disagreement: -0.2, fsrsError: -0.12, rwkvError: 0.08, count: 200),
            UmPlusBin(index: 24, disagreement: 0.2, fsrsError: 0.16, rwkvError: -0.04, count: 200),
        ]) == -0.2...0.2)
    }

    @Test func error_domain_keeps_zero_inside_when_errors_share_a_sign() {
        #expect(UmPlus.errorDomain([
            UmPlusBin(index: 20, disagreement: 0, fsrsError: 0.04, rwkvError: 0.16, count: 200),
        ]) == -0.1...0.2)
        #expect(UmPlus.errorDomain([]) == -0.1...0.1)
    }

    private func volumeBin(_ index: Int, _ count: Int) -> UmPlusBin {
        UmPlusBin(index: index, disagreement: Double(index - 20) / 20, fsrsError: 0, rwkvError: 0, count: count)
    }

    @Test func hides_buckets_with_fewer_than_200_reviews_by_default() {
        let bins = [volumeBin(1, 199), volumeBin(20, 200), volumeBin(39, 201)]
        #expect(UmPlus.visibleBins(bins, showSmallBuckets: false) == [volumeBin(20, 200), volumeBin(39, 201)])
    }

    @Test func can_show_buckets_with_fewer_than_200_reviews() {
        let bins = [volumeBin(1, 199), volumeBin(20, 200), volumeBin(39, 201)]
        #expect(UmPlus.visibleBins(bins, showSmallBuckets: true) == bins)
    }

    @Test func calculates_review_weighted_regression_slopes() {
        let bins = [
            UmPlusBin(index: 16, disagreement: -0.2, fsrsError: -0.05, rwkvError: 0.15, count: 200),
            UmPlusBin(index: 20, disagreement: 0, fsrsError: 0, rwkvError: 0, count: 400),
            UmPlusBin(index: 24, disagreement: 0.2, fsrsError: 0.05, rwkvError: -0.15, count: 200),
        ]
        #expect(close(UmPlus.weightedRegressionSlope(bins) { $0.fsrsError } ?? .nan, 0.25))
        #expect(close(UmPlus.weightedRegressionSlope(bins) { $0.rwkvError } ?? .nan, -0.75))
    }

    @Test func regression_slope_is_unavailable_without_disagreement_variation() {
        #expect(UmPlus.weightedRegressionSlope([volumeBin(20, 200)]) { $0.fsrsError } == nil)
    }
}

@Suite struct UmPlusGraphTests {
    private let data = UmPlusData(
        bins: [
            UmPlusBin(index: 16, disagreement: -0.2, fsrsError: 0, rwkvError: 0.2, count: 200),
            UmPlusBin(index: 24, disagreement: 0.2, fsrsError: 0, rwkvError: -0.2, count: 400),
        ],
        fsrsScore: 0,
        rwkvScore: 0.2,
        count: 600
    )

    @Test func legend_shows_scores_and_slopes() {
        let visible = UmPlus.visibleBins(data.bins, showSmallBuckets: false)
        #expect(UmPlus.legend(model: .fsrs, data: data, visibleBins: visible) == "FSRS, UM+=0.0000, slope=0.000")
        #expect(UmPlus.legend(model: .rwkv, data: data, visibleBins: visible) == "RWKV, UM+=0.2000, slope=-1.000")
        #expect(UmPlus.formatSlope(nil) == "n/a")
        #expect(UmPlus.formatSlope(0.0004) == "0.000")
        #expect(UmPlus.formatSlope(0.25) == "+0.250")
    }

    @Test func bubbles_grow_with_volume() {
        let small = UmPlus.pointRadius(data.bins[0], total: data.count)
        let large = UmPlus.pointRadius(data.bins[1], total: data.count)
        #expect(large > small)
        #expect(UmPlus.pointRadius(UmPlusBin(index: 0, disagreement: 0, fsrsError: 0, rwkvError: 0, count: 1), total: 10_000) == 2.5)
    }

    @Test func small_buckets_are_faint_dotted_data_only_when_requested() {
        let bins = [
            UmPlusBin(index: 16, disagreement: -0.2, fsrsError: 0, rwkvError: 0.2, count: 100),
            UmPlusBin(index: 20, disagreement: 0, fsrsError: 0, rwkvError: 0, count: 300),
            UmPlusBin(index: 24, disagreement: 0.2, fsrsError: 0, rwkvError: -0.2, count: 100),
        ]
        let hidden = UmPlus.visibleBins(bins, showSmallBuckets: false)
        #expect(hidden.count == 1)
        #expect(UmPlus.segments(hidden).isEmpty)
        let shown = UmPlus.visibleBins(bins, showSmallBuckets: true)
        let segments = UmPlus.segments(shown)
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { $0.small })
    }

    @Test func axes_use_10_percentage_point_ticks() {
        let visible = UmPlus.visibleBins(data.bins, showSmallBuckets: false)
        let x = UmPlus.ticksByTenth(UmPlus.disagreementDomain(visible)).map { UmPlus.signedPercent($0) }
        let y = UmPlus.ticksByTenth(UmPlus.errorDomain(visible)).map { UmPlus.signedPercent($0) }
        #expect(x == ["-20%", "-10%", "0%", "+10%", "+20%"])
        #expect(y == ["-20%", "-10%", "0%", "+10%", "+20%"])
    }

    @Test func y_axis_covers_only_visible_bucket_errors() {
        let bins = [
            UmPlusBin(index: 16, disagreement: -0.2, fsrsError: -0.7, rwkvError: -0.5, count: 100),
            UmPlusBin(index: 20, disagreement: 0, fsrsError: 0.04, rwkvError: 0.16, count: 300),
        ]
        let ticks = { (show: Bool) in
            UmPlus.ticksByTenth(UmPlus.errorDomain(UmPlus.visibleBins(bins, showSmallBuckets: show)))
                .map { UmPlus.signedPercent($0) }
        }
        #expect(ticks(false) == ["-10%", "0%", "+10%", "+20%"])
        #expect(ticks(true) == ["-70%", "-60%", "-50%", "-40%", "-30%", "-20%", "-10%", "0%", "+10%", "+20%"])
    }

    @Test func tooltip_lines() {
        #expect(UmPlus.tooltip(data.bins[1], total: data.count) == [
            "FSRS − RWKV disagreement: +20.0%",
            "FSRS prediction error: 0.0%",
            "RWKV prediction error: -20.0%",
            "Paired FSRS/RWKV reviews: 400 (66.7% of paired reviews)",
        ])
        let bounds = UmPlus.binBounds(data.bins[0], domain: -0.2...0.2)
        #expect(bounds.lowerBound == -0.2)
        #expect(abs(bounds.upperBound + 0.175) < 1e-12)
    }
}
